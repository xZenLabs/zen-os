-- Stores the screen dimen of the last tapped MosaicMenuItem so
-- showReaderCoroutine can position the banner over that specific cover cell.
local _last_cover_dimen = nil
-- _banner_active: true while a banner is on screen + doShowReader is running.
-- Blocks any showReaderCoroutine call that arrives BEFORE doShowReader finishes.
local _banner_active = false
-- _last_banner_seq: the _tap_seq value when the last banner was shown.
-- Blocks same-tap duplicate calls that arrive AFTER doShowReader finishes
-- (e.g. a DOM-version reload KOReader schedules during reader init).
-- Those calls are delegated to _orig so the reload happens without a banner.
-- Initialized to -1 so the very first call (e.g. from rakuyomi with no tap)
-- takes the banner path instead of being mistaken for a duplicate.
local _last_banner_seq = -1
-- Sequence counter: incremented on every onTapSelect call to correlate logs.
local _tap_seq = 0

-- Walk a widget tree (depth-first) to find the first rendered blitbuffer (_bb).
local function _find_cover_bb(w, depth)
    if depth > 5 or type(w) ~= "table" then return nil end
    local t = type(w._bb)
    if t == "userdata" or t == "cdata" then return w._bb end
    for i = 1, 8 do
        if not w[i] then break end
        local r = _find_cover_bb(w[i], depth + 1)
        if r then return r end
    end
    return nil
end

-- Sample the bottom 30 % of a blitbuffer and return the average luminance
-- (0 = black … 255 = white), or nil on failure.
local function _sample_bottom_luminance(bb)
    local w, h
    local ok = pcall(function() w = bb:getWidth(); h = bb:getHeight() end)
    if not ok or not w or w < 1 or not h or h < 1 then return nil end
    local y0 = math.max(0, math.floor(h * 0.70))
    local total, count = 0, 0
    local dx = math.max(1, math.floor(w / 12))
    local dy = math.max(1, math.floor(math.max(1, h - y0) / 4))
    pcall(function()
        for y = y0, h - 1, dy do
            for x = 0, w - 1, dx do
                local pix = bb:getPixel(x, y)
                local c8  = pix:getColor8()
                if c8 and c8.a then
                    total = total + c8.a
                    count = count + 1
                end
            end
        end
    end)
    if count == 0 then return nil end
    return total / count
end

local function apply_opening_banner()
    -- Replaces the default "Opening" InfoMessage with a slim strip pinned to
    -- the tapped cover cell; falls back to a full-width strip at the bottom
    -- of the screen when cover geometry is unknown (list mode, History, etc.).

    local ReaderUI = require("apps/reader/readerui")
    local UIManager = require("ui/uimanager")
    local Device = require("device")
    local Screen = Device.screen

    if type(ReaderUI.showReaderCoroutine) ~= "function" then
        return
    end

    -- Capture plugin reference while __ZEN_UI_PLUGIN is still set (it is cleared
    -- after patch application, so rawget at coroutine-time returns nil).
    local _plugin = rawget(_G, "__ZEN_UI_PLUGIN")

    local Blitbuffer = require("ffi/blitbuffer")
    local Font    = require("ui/font")
    local Geom    = require("ui/geometry")
    local TextWidget = require("ui/widget/textwidget")
    local Widget  = require("ui/widget/widget")
    local logger  = require("common/zen_logger").new("opening_banner")
    local BookOpenTap = require("common/book_open_tap")
    local _       = require("gettext")
    local pending_banner
    local pending_banner_seq
    local show_prepared_banner

    local function is_book_item(item)
        if not item or item.is_directory then return false end
        local entry = item.entry
        if type(entry) == "table" then
            if entry._zen_files or entry.series_items or entry.is_series_group
                    or entry.is_go_up or entry._zen_empty_placeholder then
                return false
            end
            local attr_mode = type(entry.attr) == "table" and entry.attr.mode or nil
            if entry.is_directory or entry.mode == "directory" or attr_mode == "directory" then
                return false
            end
            if entry.is_file == true or type(entry.file) == "string"
                    or type(entry.filepath) == "string" or attr_mode == "file" then
                return true
            end
        end
        return type(item.filepath) == "string" and item.filepath ~= ""
    end

    local function is_select_mode(item)
        local menu = item and item.menu
        if menu and menu.ui and menu.ui.selected_files ~= nil then return true end
        local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
        return ok and FileManager.instance and FileManager.instance.selected_files ~= nil
    end

    local function is_chooser_item(item)
        local menu = item and item.menu
        return menu and (menu.select_directory ~= nil or menu.select_file ~= nil)
    end

    local function should_prepare_for_tap(item, ...)
        local ges = select(2, ...)
        if not ges or ges.time == nil then return true end
        local entry = item and item.entry
        local path = type(entry) == "table"
            and (entry.path or entry.file or entry.filepath) or item and item.filepath
        return BookOpenTap.willOpen(path, ges.time)
    end

    local function set_opening_banner_dimen(dimen, cover_widget, is_list, advance_tap)
        if not (dimen and dimen.x and dimen.y and dimen.w and dimen.h
                and dimen.w > 0 and dimen.h > 0) then
            return false
        end
        if advance_tap ~= false then _tap_seq = _tap_seq + 1 end
        _last_cover_dimen = {
            x = dimen.x,
            y = dimen.y,
            w = dimen.w,
            h = dimen.h,
            is_list = is_list == true,
            border = is_list and 0 or math.max(0,
                math.floor(tonumber(cover_widget and cover_widget.bordersize) or 0)),
        }
        if is_list then
            local night_mode = G_reader_settings and G_reader_settings:isTrue("night_mode") or false
            _last_cover_dimen.dark_banner = not night_mode
        else
            local cover_bb = _find_cover_bb(cover_widget, 0)
            local lum = cover_bb and _sample_bottom_luminance(cover_bb) or nil
            _last_cover_dimen.dark_banner = lum == nil or lum >= 128
        end
        if show_prepared_banner then show_prepared_banner() end
        return true
    end

    local function set_opening_banner_cover(cover_widget)
        return set_opening_banner_dimen(cover_widget and cover_widget.dimen, cover_widget, false, true)
    end

    local ok_highlight, ReaderHighlight = pcall(require, "apps/reader/modules/readerhighlight")
    if ok_highlight and type(ReaderHighlight.onTap) == "function"
            and not ReaderHighlight._zen_visible_boxes_guard then
        ReaderHighlight._zen_visible_boxes_guard = true
        local orig_onTap = ReaderHighlight.onTap
        ReaderHighlight.onTap = function(self, arg, ges)
            local highlight = self.view and self.view.highlight
            if not self.hold_pos and ges and highlight and highlight.visible_boxes == nil then
                return
            end
            return orig_onTap(self, arg, ges)
        end
    end

    -- Hook MosaicMenuItem.onTapSelect to capture cover cell geometry
    local function try_hook_mosaic()
        local ok, MosaicMenu = pcall(require, "mosaicmenu")
        if not ok or type(MosaicMenu) ~= "table" then return end

        local function get_upvalue(fn, name)
            if type(fn) ~= "function" then return nil end
            for i = 1, 64 do
                local n, v = debug.getupvalue(fn, i)
                if not n then break end
                if n == name then return v end
            end
        end

        local MosaicMenuItem = get_upvalue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
        if not MosaicMenuItem then return end

        if type(MosaicMenuItem.onTapSelect) ~= "function" then return end

        -- Match browser_cover_mosaic_uniform constants (kept in sync).
        local CoverUtils = require("common/cover_utils")
        local _UNIFORM_BORDER = CoverUtils.BORDER_SIZE
        local _UNIFORM_UNDERLINE_RESERVE = 6
        local function _uniform_aspect()
            return CoverUtils.getRatio()
        end
        -- Compute the rect of the actual painted cover for a tapped MosaicMenuItem.
        -- Primary source: _zen_cover_dimen, a snapshot of the cover widget's .dimen
        -- taken inside our paintTo wrapper (the only moment it is guaranteed to be
        -- set for all variants). Falls back to flag+cell-math for items that have
        -- not been painted yet (e.g. still-loading covers).
        local function find_cover_frame(item)
            local t = item[1] and item[1][1] and item[1][1][1]
            if not t then return nil end
            if t.bordersize ~= nil then return t end
            local inner = t[2] and t[2][1] and t[2][1][1]
            if inner and inner.bordersize ~= nil then return inner end
            return nil
        end

        local function _cover_rect(self_item, strip_h)
            -- Primary: exact screen rect captured after paintTo.
            local snap = self_item._zen_cover_dimen
            if snap and snap.w and snap.w > 0 then
                return { x = snap.x, y = snap.y, w = snap.w, h = snap.h, variant = "from-dimen" }
            end

            local id = self_item.dimen
            if not id then return nil end
            strip_h = strip_h or 0
            local cell_w      = id.w
            local cell_h_inner = id.h - strip_h
            if cell_w <= 0 or cell_h_inner <= 0 then return nil end

            -- Secondary: read actual width/height from the cover widget's constructor
            -- fields. These are set at build time (no paintTo needed) and give the
            -- correct position for both FakeCover (7/8 width, full height) and real
            -- covers (image-sized FrameContainer). More accurate than the uniform
            -- computation for FakeCover, which is NOT a 2:3 aspect-ratio widget.
            local cover_widget = find_cover_frame(self_item)
            if cover_widget
               and cover_widget.width  and cover_widget.width  > 0
               and cover_widget.height and cover_widget.height > 0
            then
                local cw = cover_widget.width
                local ch = cover_widget.height
                local cx = id.x + math.floor((cell_w      - cw) / 2)
                local cy = id.y + math.floor((cell_h_inner - ch) / 2)
                return { x = cx, y = cy, w = cw, h = ch, variant = "from-widget" }
            end

            -- Tertiary: if uniform cover mode is active, compute the uniform rect.
            -- Correct for uniform-resized real covers; FakeCover should have been
            -- caught by the from-widget path above, so this is a last resort.
            if MosaicMenuItem._zen_mosaic_uniform_patched == true then
                local border    = _UNIFORM_BORDER
                local max_img_w = cell_w - 2 * border
                local max_img_h = cell_h_inner - 2 * border - _UNIFORM_UNDERLINE_RESERVE
                if max_img_w > 0 and max_img_h > 0 then
                    local ar = _uniform_aspect()
                    local cw, ch
                    if max_img_w / max_img_h > ar then
                        ch = max_img_h
                        cw = math.floor(max_img_h * ar)
                    else
                        cw = max_img_w
                        ch = math.floor(max_img_w / ar)
                    end
                    local frame_w = cw + 2 * border
                    local frame_h = ch + 2 * border
                    local vpad   = math.floor((cell_h_inner - frame_h) / 2)
                    return {
                        x = id.x + math.floor((cell_w - frame_w) / 2),
                        y = id.y + vpad,
                        w = frame_w,
                        h = frame_h,
                        variant = "uniform",
                    }
                end
            end

            -- No usable rect found.
            return nil
        end

        -- Wrap paintTo to snapshot the cover widget's actual screen rect.
        -- cover.dimen is only set during paintTo, so this is the only reliable
        -- moment to read exact position/size regardless of cover variant.
        local orig_paintTo = MosaicMenuItem.paintTo
        if type(orig_paintTo) == "function" then
            MosaicMenuItem.paintTo = function(self_item, bb, x, y)
                orig_paintTo(self_item, bb, x, y)
                local cover = find_cover_frame(self_item)
                local d = cover and cover.dimen
                if d and d.w and d.w > 0 then
                    self_item._zen_cover_dimen = { x = d.x, y = d.y, w = d.w, h = d.h }
                end
            end
        end

        local orig_tap = MosaicMenuItem.onTapSelect
        MosaicMenuItem.onTapSelect = function(self_item, ...)
            if is_chooser_item(self_item) then return orig_tap(self_item, ...) end
            _tap_seq = _tap_seq + 1
            if is_select_mode(self_item) then
                _last_cover_dimen = nil
                return orig_tap(self_item, ...)
            end
            -- Only book taps may prepare a banner. Virtual group rows do not
            -- always carry KOReader's is_directory marker.
            if is_book_item(self_item) and should_prepare_for_tap(self_item, ...) then
                local cover_frame = find_cover_frame(self_item)

                -- Use paintTo-snapshotted dimen if available (_zen_cover_dimen),
                -- with flag+cell-math as fallback for items not yet painted.
                local strip_h = self_item._zen_strip_h or 0
                local rect = _cover_rect(self_item, strip_h)
                if not set_opening_banner_dimen(rect, cover_frame or self_item, false, false) then
                    _last_cover_dimen = nil
                end
            else
                -- Navigating into a folder: discard any previously stored dimen
                -- so it cannot bleed into a subsequent book open in list mode.
                _last_cover_dimen = nil
            end
            return orig_tap(self_item, ...)
        end
    end

    -- Hook ListMenuItem.onTapSelect to capture list-item geometry
    -- (used when a folder profile forces list mode inside a mosaic browser)
    local function try_hook_list()
        local ok, ListMenu = pcall(require, "listmenu")
        if not ok or type(ListMenu) ~= "table" then return end

        local function get_upvalue(fn, name)
            if type(fn) ~= "function" then return nil end
            for i = 1, 64 do
                local n, v = debug.getupvalue(fn, i)
                if not n then break end
                if n == name then return v end
            end
        end

        local ListMenuItem = get_upvalue(ListMenu._updateItemsBuildUI, "ListMenuItem")
        if not ListMenuItem then return end
        if type(ListMenuItem.onTapSelect) ~= "function" then return end

        local orig_tap = ListMenuItem.onTapSelect
        ListMenuItem.onTapSelect = function(self_item, ...)
            if is_chooser_item(self_item) then return orig_tap(self_item, ...) end
            _tap_seq = _tap_seq + 1
            if is_select_mode(self_item) then
                _last_cover_dimen = nil
                return orig_tap(self_item, ...)
            end
            if is_book_item(self_item) and should_prepare_for_tap(self_item, ...) then
                if not set_opening_banner_dimen(self_item.dimen, self_item, true, false) then
                    _last_cover_dimen = nil
                end
            else
                _last_cover_dimen = nil
            end
            return orig_tap(self_item, ...)
        end
    end

    pcall(try_hook_mosaic)
    pcall(try_hook_list)

    -- Restore the covered pixels in the rounded bottom-corner cut-outs.
    local function _mask_bottom_corners(bb, x, y, w, h, r, background)
        for j = 0, r - 1 do
            local inner = math.sqrt(r * r - (r - j) * (r - j))
            local cut   = math.ceil(r - inner)
            if cut > 0 then
                local source_y = r - 1 - j
                bb:blitFrom(background, x, y + h - 1 - j, 0, source_y, cut, 1)
                bb:blitFrom(background, x + w - cut, y + h - 1 - j,
                    2 * r - cut, source_y, cut, 1)
            end
        end
    end

    -- Border that follows rounded bottom corners
    -- Must be called AFTER _mask_bottom_corners so the border is never overwritten.
    local function _draw_border(bb, x, y, w, h, r, color, top_color, top_border)
        if r > 0 then
            -- Left / right: straight down to where the arc begins
            bb:paintRect(x,         y, 1, h - r, color)
            bb:paintRect(x + w - 1, y, 1, h - r, color)
            -- Bottom straight segment between the two arc zones
            if w > 2 * r then
                bb:paintRect(x + r, y + h - 1, w - 2 * r, 1, color)
            end
            -- Bottom-left and bottom-right 1px arc borders
            local r_inner = r - 1
            for j = 0, r - 1 do
                for c = 0, r - 1 do
                    local dx   = r - c - 0.5
                    local dy   = r - j - 0.5
                    local dist = math.sqrt(dx * dx + dy * dy)
                    if dist >= r_inner and dist <= r then
                        bb:paintRect(x + c,           y + h - 1 - j, 1, 1, color)
                        bb:paintRect(x + w - 1 - c,   y + h - 1 - j, 1, 1, color)
                    end
                end
            end
        else
            -- Simple rectangular border (no rounding)
            bb:paintRect(x,         y + h - 1, w, 1, color)
            bb:paintRect(x,         y,         1, h, color)
            bb:paintRect(x + w - 1, y,         1, h, color)
        end
        -- The straight top edge owns the corner pixels.
        bb:paintRect(x, y, w, math.min(h, math.max(1, top_border or 1)),
            top_color)
    end

    -- Tiny inline widget: black rect + centred "Opening" text
    local OpeningBanner = Widget:extend{}
    OpeningBanner._zen_opening_banner = true

    function OpeningBanner:onShow()
        self._timeout_func = function()
            self._timeout_func = nil
            UIManager:close(self)
        end
        UIManager:scheduleIn(10, self._timeout_func)
    end

    function OpeningBanner:onCloseWidget()
        if self._timeout_func then
            UIManager:unschedule(self._timeout_func)
            self._timeout_func = nil
        end
        if pending_banner == self then
            pending_banner = nil
            pending_banner_seq = nil
        end
        UIManager:setDirty(nil, function()
            return "ui", self.dimen
        end)
    end

    function OpeningBanner:paintTo(bb, x, y)
        self.dimen.x = x
        self.dimen.y = y
        -- XOR dark_banner with night mode so colors are always visually correct.
        local night_mode = G_reader_settings and G_reader_settings:isTrue("night_mode") or false
        local use_dark = self.dark_banner ~= night_mode
        local bg = use_dark and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
        local fg = use_dark and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        local black = night_mode and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
        local w, h = self.dimen.w, self.dimen.h
        local r    = self.round_bottom_corners
            and math.max(0, Screen:scaleBySize(8) - (self.cover_border or 0)) or 0
        local background
        if r > 0 then
            background = Blitbuffer.new(r * 2, r, bb:getType())
            if background then
                background:blitFrom(bb, 0, 0, x, y + h - r, r, r)
                background:blitFrom(bb, r, 0, x + w - r, y + h - r, r, r)
            else
                r = 0
            end
        end

        -- 1. Fill background
        bb:paintRect(x, y, w, h, bg)
        -- 2. Clip bottom corners (before border so the border draws on top)
        if r > 0 then
            _mask_bottom_corners(bb, x, y, w, h, r, background)
        end
        -- 3. Only the top edge contrasts on dark banners.
        _draw_border(bb, x, y, w, h, r, black, fg, self.cover_border)

        local tw = TextWidget:new{
            text      = self.label or _("Opening"),
            face      = Font:getFace("cfont", Screen:scaleBySize(7)),
            fgcolor   = fg,
            bold      = true,
        }
        local tsz = tw:getSize()
        tw:paintTo(bb,
            x + math.floor((w - tsz.w) / 2),
            y + math.floor((h - tsz.h) / 2))
        tw:free()
        if background then background:free() end
    end

    local function build_banner(cover)
        local banner_h = Screen:scaleBySize(28)
        local bx, by, bw
        if cover then
            local border = cover.is_list and 0 or cover.border or 0
            by = cover.y + cover.h - border - banner_h
            if cover.is_list then
                bx = cover.x + cover.h
                bw = cover.w - cover.h
            else
                bx = cover.x + border
                bw = cover.w - 2 * border
            end
        else
            local bottom_margin = Screen:isColorScreen() and Screen:scaleBySize(8) or 0
            bx = 0
            by = Screen:getHeight() - banner_h - bottom_margin
            bw = Screen:getWidth()
            banner_h = banner_h + bottom_margin
        end

        local plug = _plugin or rawget(_G, "__ZEN_UI_PLUGIN")
        local round_bottom = cover and not cover.is_list
            and plug
            and type(plug.config) == "table"
            and type(plug.config.features) == "table"
            and plug.config.features.browser_cover_rounded_corners == true
        local night_mode = G_reader_settings and G_reader_settings:isTrue("night_mode") or false
        local dark_banner = cover and cover.dark_banner
        if dark_banner == nil then dark_banner = not night_mode end

        local dimen = Geom:new{ x = bx, y = by, w = bw, h = banner_h }
        return OpeningBanner:new{
            dimen                = dimen,
            dark_banner          = dark_banner,
            round_bottom_corners = round_bottom and true or false,
            cover_border         = cover and cover.border or 0,
        }, dimen
    end

    local function show_banner(banner, dimen)
        UIManager:show(banner, "ui", dimen, dimen.x, dimen.y)
        UIManager:forceRePaint()
    end

    local function clear_pending_banner()
        if pending_banner then UIManager:close(pending_banner) end
        pending_banner = nil
        pending_banner_seq = nil
    end

    rawset(_G, "__ZEN_UI_CANCEL_OPENING_BANNER", function(suppress_next_open)
        clear_pending_banner()
        _last_cover_dimen = nil
        if suppress_next_open == true then
            _last_banner_seq = _tap_seq
        end
    end)

    local ok_confirm, ConfirmBox = pcall(require, "ui/widget/confirmbox")
    if ok_confirm and type(ConfirmBox.new) == "function"
            and not ConfirmBox._zen_opening_banner_cancel_callback_patched then
        ConfirmBox._zen_opening_banner_cancel_callback_patched = true
        local orig_new = ConfirmBox.new
        local prompt_prefix = _("Open this file?") .. "\n\n"
        local open_text = _("Open")
        ConfirmBox.new = function(class, props, ...)
            if type(props) == "table" and type(props.text) == "string"
                    and props.text:sub(1, #prompt_prefix) == prompt_prefix
                    and props.ok_text == open_text
                    and G_reader_settings and G_reader_settings:isTrue("file_ask_to_open") then
                local orig_cancel = props.cancel_callback
                props.cancel_callback = function(...)
                    if orig_cancel then orig_cancel(...) end
                    local cancel_banner = rawget(_G, "__ZEN_UI_CANCEL_OPENING_BANNER")
                    if type(cancel_banner) == "function" then cancel_banner() end
                end
            end
            return orig_new(class, props, ...)
        end
    end

    show_prepared_banner = function()
        if _banner_active or not _last_cover_dimen then return end
        clear_pending_banner()
        local banner, dimen = build_banner(_last_cover_dimen)
        pending_banner = banner
        pending_banner_seq = _tap_seq
        show_banner(banner, dimen)
    end

    -- Home and Zen Mosaic book widgets bypass KOReader's stock item hooks.
    rawset(_G, "__ZEN_UI_SET_OPENING_BANNER_COVER", set_opening_banner_cover)

    local orig_show_reader = ReaderUI.showReader
    ReaderUI.showReader = function(self, ...)
        if not _last_cover_dimen then _tap_seq = _tap_seq + 1 end
        return orig_show_reader(self, ...)
    end

    -- Patch showReaderCoroutine.
    -- Do not show the stock opening message on duplicate opens, but preserve
    -- its next-tick transition: replacing ReaderUI during the current gesture
    -- lets that gesture reach the unpainted reader.
    local function _show_reader_no_banner(self, file, provider, seamless)
        logger.info("_show_reader_no_banner called, file=", tostring(file))
        -- Keep UIManager alive for callers that unwind their widget tree before
        -- the next tick (notably Rakuyomi), without displaying a second banner.
        local pending = Widget:new{ invisible = true }
        UIManager:show(pending)
        UIManager:nextTick(function()
            UIManager:close(pending)
            logger.info("_show_reader_no_banner creating doShowReader coroutine, file=", tostring(file), "provider=", tostring(provider))
            local co = coroutine.create(function()
                logger.info("_show_reader_no_banner doShowReader coroutine starting")
                local started_at = os.clock()
                local doc_ok, doc_err = pcall(function()
                    self:doShowReader(file, provider, seamless)
                end)
                if not doc_ok then
                    logger.err("_show_reader_no_banner doShowReader threw error:", tostring(doc_err))
                    logger.err("_show_reader_no_banner doShowReader traceback:", debug.traceback())
                end
                logger.info("_show_reader_no_banner doShowReader coroutine finished, ok=", tostring(doc_ok))
                logger.perf("Book open completed", (os.clock() - started_at) * 1000,
                    "file=", tostring(file), "ok=", tostring(doc_ok))
            end)
            logger.info("_show_reader_no_banner resuming doShowReader coroutine")
            local ok, err = coroutine.resume(co)
            logger.info("_show_reader_no_banner doShowReader coroutine resumed, ok=", tostring(ok), "err=", tostring(err))
            if err ~= nil or ok == false then
                logger.err("_show_reader_no_banner coroutine crashed, err=", tostring(err), "ok=", tostring(ok))
                logger.err("doShowReader coroutine crash traceback:", debug.traceback(co, err, 1))
                Device:setIgnoreInput(false)
                local Input = require("device/input")
                Input:inhibitInputUntil(0.2)
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{
                    text = _("No reader engine for this file or invalid file."),
                })
                self:showFileManager(file)
            end
        end)
    end

        ReaderUI.showReaderCoroutine = function(self, file, provider, seamless)
        logger.info("showReaderCoroutine called, file=", tostring(file), "provider=", tostring(provider), "seamless=", tostring(seamless))
        if seamless then
            -- Seamless reloads must keep KOReader's behavior (invisible InfoMessage).
            logger.info("seamless reload, delegating to _show_reader_no_banner")
            clear_pending_banner()
            return _show_reader_no_banner(self, file, provider, seamless)
        end
        -- While the banner is already on screen + doShowReader is running,
        -- skip entirely: the first call's nextTick will open the reader.
        if _banner_active then
            return
        end
        -- KOReader calls showReaderCoroutine more than once per tap in some
        -- cases (e.g. a DOM-version reload scheduled via nextTick during
        -- reader init). After the first banner for a given tap, run the
        -- reload via our InfoMessage-free path so no second banner appears.
        if _last_banner_seq == _tap_seq then
            return _show_reader_no_banner(self, file, provider, seamless)
        end
        _last_banner_seq = _tap_seq
        _banner_active = true

        local cover    = _last_cover_dimen
        _last_cover_dimen = nil     -- consume immediately
        local banner
        if pending_banner and pending_banner_seq == _tap_seq then
            banner = pending_banner
            pending_banner = nil
            pending_banner_seq = nil
        else
            clear_pending_banner()
            local dimen
            banner, dimen = build_banner(cover)
            show_banner(banner, dimen)
        end

        UIManager:nextTick(function()
            -- Close the banner before opening the reader: an orphaned banner
            -- prevents _gated_quit from firing (UIManager stack never empties),
            -- causing KOReader to hang when the user quits from any menu.
            UIManager:close(banner)
            logger.warn("nextTick fired, creating doShowReader coroutine")

            -- Keep _banner_active=true until doShowReader completes so any
            -- spurious second showReaderCoroutine call is blocked by the guard.
            logger.info("creating coroutine for doShowReader, file=", tostring(file), "provider=", tostring(provider))
            local co = coroutine.create(function()
                logger.info("doShowReader coroutine starting")
                local started_at = os.clock()
                local doc_ok, doc_err = pcall(function()
                    self:doShowReader(file, provider, seamless)
                end)
                if not doc_ok then
                    logger.err("doShowReader threw error:", tostring(doc_err))
                    logger.err("doShowReader traceback:", debug.traceback())
                end
                logger.info("doShowReader coroutine finished, ok=", tostring(doc_ok))
                logger.perf("Book open completed", (os.clock() - started_at) * 1000,
                    "file=", tostring(file), "ok=", tostring(doc_ok))
            end)
            logger.info("resuming doShowReader coroutine")
            local ok, err = coroutine.resume(co)
            -- Reset AFTER doShowReader finishes. Sync _last_banner_seq to the
            -- CURRENT _tap_seq (not just the value when the banner was shown) so
            -- any tap that arrived during loading (incrementing _tap_seq) doesn't
            -- bypass the same-seq guard for subsequent reloads. Also discard any
            -- stale _last_cover_dimen that a mid-load tap may have written.
            _banner_active = false
            _last_banner_seq = _tap_seq
            _last_cover_dimen = nil
            logger.info("doShowReader coroutine resumed, ok=", tostring(ok), "err=", tostring(err))
            if err ~= nil or ok == false then
                logger.err("doShowReader coroutine crashed in showReaderCoroutine, err=", tostring(err), "ok=", tostring(ok))
                logger.err("doShowReader coroutine crash traceback:", debug.traceback(co, err, 1))
                Device:setIgnoreInput(false)
                local Input = require("device/input")
                Input:inhibitInputUntil(0.2)
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{
                    text = _("No reader engine for this file or invalid file."),
                })
                self:showFileManager(file)
            end
        end)
    end
end

return apply_opening_banner
