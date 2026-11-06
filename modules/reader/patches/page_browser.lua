-- zen_ui: page_browser patch
-- Opens KOReader's native PageBrowserWidget from the bottom swipe zone
-- or a physical Menu-key hold.

local function apply_page_browser()

    -- -----------------------------------------------------------------------
    -- Dependencies
    -- -----------------------------------------------------------------------
    local UIManager    = require("ui/uimanager")
    local Event        = require("ui/event")
    local Device       = require("device")
    local ReaderThumbnail = require("apps/reader/modules/readerthumbnail")
    local PresetStore   = require("config/preset_store")
    local BottomSwipe  = require("common/reader_bottom_swipe")
    local PageBrowserTabs = require("modules/reader/page_browser_tabs")
    local utils        = require("common/utils")
    local lfs          = require("libs/libkoreader-lfs")
    local _stock_icons_dir = lfs.currentdir() .. "/resources/icons/mdlight/"
    local panel_height = 124 -- Two navigation rows with equal top and bottom padding.
    local preview_padding = 12
    local chapter_padding = 8
    local slider_gap = 0

    -- Chapter title + page progress, centred as one block in a panel row.
    local function format_progress(page_text, total_text, percent)
        return require("ffi/util").template(require("gettext")("Page %1 of %2"), page_text, total_text)
            .. " · " .. percent .. "%"
    end

    local function make_progress_label(text, max_width)
        return require("ui/widget/textwidget"):new{
            text = text, face = require("ui/font"):getFace("cfont", 16), max_width = max_width, padding = 0,
        }
    end

    local function add_chapter_rows(group, x, y, w, row_h, chapter, progress)
        local CenterContainer = require("ui/widget/container/centercontainer")
        local Geom = require("ui/geometry")
        local ch, ph = chapter:getSize().h, progress:getSize().h
        local top = y + math.floor((row_h - ch - ph) / 2)
        group[#group + 1] = CenterContainer:new{
            dimen = Geom:new{ w = w, h = ch }, chapter, overlap_offset = { x, top } }
        group[#group + 1] = CenterContainer:new{
            dimen = Geom:new{ w = w, h = ph }, progress, overlap_offset = { x, top + ch } }
    end

    local function reset_thumbnail_cache(thumbnail)
        -- A cancelled worker may still cache its result after the settings change.
        local request = thumbnail.req_in_progress
        if request then request.hash = "obsolete:" .. request.hash end
        thumbnail:cancelPageThumbnailRequests()
        thumbnail:resetCache()
    end

    if not ReaderThumbnail._zen_settings_preview_patch then
        ReaderThumbnail._zen_settings_preview_patch = true
        local orig_get_page_image = ReaderThumbnail._getPageImage
        ReaderThumbnail._getPageImage = function(self, page)
            if not self._zen_settings_preview then return orig_get_page_image(self, page) end
            -- Aa needs the reading view; stock PDF thumbnails discard crop, zoom and reflow.
            local preview = require("modules/reader/page_browser_preview"):new{
                ui = self.ui, page = page,
                bb_type = self.bb_type, -- Keep preview sizes within the thumbnail cache budget.
                width = Device.screen:getWidth(), height = Device.screen:getHeight(),
            }
            preview:render()
            return preview.bb
        end
    end

    if not ReaderThumbnail._zen_night_mode_patch then
        ReaderThumbnail._zen_night_mode_patch = true
        local orig_get_page_thumbnail = ReaderThumbnail.getPageThumbnail
        ReaderThumbnail.getPageThumbnail = function(self, ...)
            -- Highlights render differently in night mode; cached tiles are keyed by size only.
            local night_mode = Device.screen.night_mode == true
            if self._zen_night_mode ~= nil and self._zen_night_mode ~= night_mode then
                reset_thumbnail_cache(self)
            end
            self._zen_night_mode = night_mode
            return orig_get_page_thumbnail(self, ...)
        end
    end

    -- Boox Android aborts forked thumbnail workers inside ART; render in-process.
    if Device.isAndroid and Device:isAndroid() then
        local Blitbuffer = require("ffi/blitbuffer")
        local Geom = require("ui/geometry")
        local RenderImage = require("ui/renderimage")
        local TileCacheItem = require("document/tilecacheitem")
        local Screen = Device.screen
        local logger = require("logger")

        if not ReaderThumbnail._zen_android_sync_thumbnail_patch then
            ReaderThumbnail._zen_android_sync_thumbnail_patch = true
            local orig_check_tile_generation = ReaderThumbnail.checkTileGeneration

            ReaderThumbnail.startTileGeneration = function(self, request)
                local ui = self.ui
                local document = ui.document
                local saved_pos = ui.rolling and document:getCurrentPos()
                local configurable = document.configurable
                local saved_wrap, saved_trim, saved_straighten
                if ui.paging then
                    saved_wrap = configurable.text_wrap
                    saved_trim = configurable.trim_page
                    saved_straighten = configurable.auto_straighten
                end
                local bb, tile

                local ok, err = pcall(function()
                    -- _getPageImage mutates ReaderView and emits events meant only for a disposable worker.
                    local width, height = Screen:getWidth(), Screen:getHeight()
                    local zoom = 1
                    if ui.paging and not self._zen_settings_preview then
                        configurable.text_wrap = false
                        configurable.trim_page = 3
                        configurable.auto_straighten = 0
                        local dimen = document:getPageDimensions(request.page, 1, 0)
                        zoom = math.min(width / dimen.w, height / dimen.h)
                        width, height = math.floor(dimen.w * zoom), math.floor(dimen.h * zoom)
                    end
                    local rect = Geom:new{ w = width, h = height }
                    if self._zen_settings_preview then
                        bb = self:_getPageImage(request.page)
                    else
                        bb = Blitbuffer.new(width, height, self.bb_type)
                        if ui.rolling then
                            document:drawCurrentViewByPage(bb, 0, 0, rect, request.page)
                        else
                            local state = ui.view.state
                            document:drawPage(bb, 0, 0, rect, request.page, zoom, 0, state.gamma, state.saturation)
                        end
                    end
                    if not self._zen_settings_preview and ui.view.highlight_visible then
                        local view = setmetatable({
                            state = { page = request.page, zoom = zoom, rotation = 0, offset = Geom:new() },
                            page_scroll = false, visible_area = rect,
                            highlight = setmetatable({
                                page_boxes = {}, lighten_factor = math.max(ui.view.highlight.lighten_factor, 0.3),
                            }, { __index = ui.view.highlight }),
                        }, { __index = ui.view })
                        view:drawSavedHighlight(bb, 0, 0)
                    end
                    local dogear = ui.view.dogear
                    if not self._zen_settings_preview and dogear
                            and ui.bookmark:isPageBookmarked(ui.paging and request.page or document:getXPointer()) then
                        local icon_x = require("ui/bidi").mirroredUILayout() and 0 or width - dogear.icon:getWidth()
                        dogear.icon:paintTo(bb, icon_x, dogear.dogear_y_offset)
                    end
                    if ui.rolling then
                        local header_height = document:getHeaderHeight()
                        if header_height > 0 then
                            local cropped = bb:viewport(0, header_height, width, height - header_height):copy()
                            bb:free()
                            bb = cropped
                        end
                    end
                    local scale = math.min(request.width / bb:getWidth(), request.height / bb:getHeight())
                    bb = RenderImage:scaleBlitBuffer(bb,
                        math.floor(bb:getWidth() * scale),
                        math.floor(bb:getHeight() * scale), true)
                    tile = TileCacheItem:new{ bb = bb, pageno = request.page }
                    tile.size = tonumber(tile.bb.stride) * tile.bb.h
                end)

                if saved_pos then document:gotoPos(saved_pos) end
                if ui.paging then
                    configurable.text_wrap = saved_wrap
                    configurable.trim_page = saved_trim
                    configurable.auto_straighten = saved_straighten
                end
                if not ok then
                    if bb then bb:free() end
                    logger.warn("ZenOS Android synchronous thumbnail generation failed:", err)
                    return false
                end
                request._zen_sync_tile = tile
                return true
            end

            ReaderThumbnail.checkTileGeneration = function(self, request)
                local tile = request._zen_sync_tile
                if not tile then
                    return orig_check_tile_generation(self, request)
                end
                request._zen_sync_tile = nil
                if self.tile_cache then
                    self.tile_cache:insert(request.hash, tile)
                end
                if request.when_generated_callback then
                    request.when_generated_callback(tile, request.batch_id, true)
                end
                return false
            end
        end
    end

    local function key_matches_menu(key)
        if not key then return false end
        if type(key.match) ~= "function" then return key == "Menu" end
        local has_few_keys = type(Device.hasFewKeys) == "function" and Device:hasFewKeys()
        return key:match(has_few_keys and { { "Menu", "Right" } } or { "Menu" })
    end

    local function is_non_touch_device()
        return type(Device.isTouchDevice) == "function" and not Device:isTouchDevice()
    end

    local function supports_page_browser_focus()
        local has_dpad = type(Device.hasDPad) == "function" and Device:hasDPad()
        local has_keyboard = type(Device.hasKeyboard) == "function" and Device:hasKeyboard()
        return has_dpad or has_keyboard
    end

    -- -----------------------------------------------------------------------
    -- Resolve plugin icons/ dir from this file's path at apply-time
    -- -----------------------------------------------------------------------
    local _icons_dir
    do
        local root = require("common/plugin_root")
        if root then _icons_dir = root .. "/icons/" end
    end

    -- -----------------------------------------------------------------------
    -- Feature guard
    -- -----------------------------------------------------------------------
    -- Capture the plugin reference NOW (while __ZEN_UI_PLUGIN is set by
    -- run_patch). After apply_page_browser() returns the global is cleared,
    -- so reading it inside gesture handlers would always return nil.
    local _plugin_ref = rawget(_G, "__ZEN_UI_PLUGIN")

    local function is_page_browser_layout(layout)
        return layout == "single" or layout == "carousel" or layout == "grid"
    end

    local function get_page_browser_layout()
        local settings = PresetStore.getSettings("reader")
        local layout = type(settings) == "table" and settings.page_browser_layout
        if is_page_browser_layout(layout) then return layout end
        return "carousel"
    end

    local function set_page_browser_layout(layout)
        if not is_page_browser_layout(layout) then return end
        local store = PresetStore.loadStore("reader")
        if type(store) ~= "table" then return end
        if type(store.settings) ~= "table" then store.settings = {} end
        if store.settings.page_browser_layout == layout then return end
        store.settings.page_browser_layout = layout
        PresetStore.saveStore("reader", store)
    end

    local function is_enabled()
        local config = _plugin_ref and _plugin_ref.config
        return config and BottomSwipe.getMode(config) == "page_browser" and BottomSwipe.isEnabled(config)
    end

    local function is_substring_enabled()
        local cfg = _plugin_ref and _plugin_ref.config
        local search = type(cfg) == "table" and cfg.search
        return type(search) ~= "table" or search.substring ~= false
    end

    rawset(_G, "__ZEN_UI_BUILD_PAGE_BROWSER_PREVIEW", function(slot_w, slot_h)
        local Blitbuffer      = require("ffi/blitbuffer")
        local Font            = require("ui/font")
        local Geom            = require("ui/geometry")
        local IconWidget      = require("ui/widget/iconwidget")
        local TextWidget      = require("ui/widget/textwidget")
        local FrameContainer  = require("ui/widget/container/framecontainer")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local OverlapGroup    = require("ui/widget/overlapgroup")
        local ZenSlider       = require("common/ui/zen_slider")
        local ZenTabBar       = require("common/ui/zen_tab_bar")
        local Screen          = Device.screen

        local canvas = Blitbuffer.new(slot_w, slot_h, Blitbuffer.TYPE_BB8)
        canvas:fill(Blitbuffer.COLOR_WHITE)

        local function paint_icon(icon_name, file_path, x, y, size)
            local icon = IconWidget:new{
                file   = file_path,
                icon   = file_path and nil or icon_name,
                width  = size,
                height = size,
            }
            icon:paintTo(canvas, x, y)
            icon:free()
        end

        local header_pad = Screen:scaleBySize(16)
        local title_h = Screen:scaleBySize(54) + header_pad
        local btn_sz  = Screen:scaleBySize(32)
        local btn_pad = Screen:scaleBySize(11)
        local slot_btn_w = btn_sz + btn_pad * 2
        local title_y = header_pad + math.floor((title_h - header_pad - btn_sz) / 2)
        local stock_icons_dir = _stock_icons_dir
        local close_icon_path = utils.resolveIcon(_stock_icons_dir, "close")
        local close_size = require("common/ui/zen_title_style").ICON_SIZE
        local close_inset = math.floor((btn_sz - close_size) / 2)
        paint_icon(nil, close_icon_path, slot_w - slot_btn_w + btn_pad + close_inset, title_y + close_inset, close_size)
        paint_icon(nil, utils.resolveIcon(_icons_dir, "more_vertical"), btn_pad, title_y, btn_sz)
        local tab_items = {}
        local config = _plugin_ref and _plugin_ref.config or {}
        local ReaderUI = package.loaded["apps/reader/readerui"]
        for i, entry in ipairs(PageBrowserTabs.list(config, ReaderUI and ReaderUI.instance)) do
            tab_items[i] = { icon = utils.resolveIcon(_icons_dir, entry.icon) or utils.resolveIcon(_stock_icons_dir, entry.icon) }
        end
        local tabs = ZenTabBar:new{
            items = tab_items,
            selected = 1, icon_size = Screen:scaleBySize(24),
            width = math.min(math.floor(slot_w * 2 / 3), slot_w - slot_btn_w * 4),
            cell_height = Screen:scaleBySize(40),
        }
        local tabs_size = tabs:getSize()
        local tabs_y = header_pad + math.floor((title_h - header_pad - tabs_size.h) / 2)
        tabs:paintTo(canvas, math.floor((slot_w - tabs_size.w) / 2), tabs_y)
        tabs:free()

        local icon_size = Screen:scaleBySize(32)
        local icon_pad_v = Screen:scaleBySize(11)
        local panel_pad_top = Screen:scaleBySize(chapter_padding)
        local label_face = Font:getFace("cfont", 18)
        local panel_h = math.min(Screen:scaleBySize(panel_height), math.floor(slot_h * 0.45))

        local top_pad = Screen:scaleBySize(preview_padding)
        local grid_top = title_h + top_pad
        canvas:paintRect(0, math.floor((tabs_y + tabs_size.h + grid_top - 1) / 2), slot_w, 1, Blitbuffer.COLOR_LIGHT_GRAY)
        local panel_top = math.max(grid_top, slot_h - panel_h)
        local grid_h = math.max(Screen:scaleBySize(80), panel_top - grid_top)
        local layout = get_page_browser_layout()

        local badge_face = Font:getFace("cfont", 13)
        local function paint_pill(bx, by, bw, bh, color)
            local r = bh / 2
            for row = 0, bh - 1 do
                local dy = math.abs(row + 0.5 - r)
                local dx = math.sqrt(math.max(0, r * r - dy * dy))
                local x0 = math.ceil(bx + r - dx)
                local x1 = math.floor(bx + bw - r + dx)
                local w  = x1 - x0
                if w > 0 then canvas:paintRect(x0, by + row, w, 1, color) end
            end
        end
        local function paint_badge(page_num, bx, by, bw, bh)
            local label = TextWidget:new{
                text    = tostring(page_num),
                face    = badge_face,
                fgcolor = Blitbuffer.COLOR_WHITE,
                padding = 0,
            }
            local sz = label:getSize()
            local pv = Screen:scaleBySize(2)
            local ph = Screen:scaleBySize(4)
            local h = sz.h + 2 * pv
            local w = math.max(sz.w + 2 * ph, h)
            local x = bx + math.floor((bw - w) / 2)
            local y = by + bh - h - Screen:scaleBySize(3)
            paint_pill(x, y, w, h, Blitbuffer.gray(0x33))
            label:paintTo(canvas, x + math.floor((w - sz.w) / 2), y + math.floor((h - sz.h) / 2))
            label:free()
        end
        local function paint_page(page_num, cell_x, cell_y, cell_w, cell_h)
            local page_h = math.floor(cell_h * 0.92)
            local page_w = math.floor(page_h * 0.70)
            if page_w > cell_w * 0.86 then
                page_w = math.floor(cell_w * 0.86)
                page_h = math.floor(page_w / 0.70)
            end
            local x = cell_x + math.floor((cell_w - page_w) / 2)
            local y = cell_y + math.floor((cell_h - page_h) / 2)
            canvas:paintRect(x, y, page_w, page_h, Blitbuffer.COLOR_WHITE)
            canvas:paintBorder(x, y, page_w, page_h, Screen:scaleBySize(1), Blitbuffer.COLOR_DARK_GRAY, 0)
            local line_h = math.max(1, Screen:scaleBySize(2))
            local line_gap = Screen:scaleBySize(8)
            local text_w = math.floor(page_w * 0.62)
            local text_x = x + math.floor(page_w * 0.18)
            local text_y = y + math.floor(page_h * 0.18)
            for i = 0, 5 do
                local w = (i % 3 == 2) and math.floor(text_w * 0.72) or text_w
                canvas:paintRect(text_x, text_y + i * line_gap, w, line_h, Blitbuffer.COLOR_LIGHT_GRAY)
            end
            paint_badge(page_num, x, y, page_w, page_h)
        end

        if layout == "single" then
            paint_page(42, 0, grid_top, slot_w, grid_h)
        elseif layout == "carousel" then
            local gap = Screen:scaleBySize(8)
            local cell_w = math.floor(slot_w * 2 / 3)
            local center_x = math.floor((slot_w - cell_w) / 2)
            paint_page(41, center_x - cell_w - gap, grid_top, cell_w, grid_h)
            paint_page(42, center_x, grid_top, cell_w, grid_h)
            paint_page(43, center_x + cell_w + gap, grid_top, cell_w, grid_h)
        else
            local cols, rows = 3, 3
            local gap = Screen:scaleBySize(8)
            local margin_x = Screen:scaleBySize(14)
            local cell_w = math.floor((slot_w - 2 * margin_x - (cols - 1) * gap) / cols)
            local cell_h = math.floor((grid_h - (rows - 1) * gap) / rows)
            local first_page = 40
            for row = 0, rows - 1 do
                for col = 0, cols - 1 do
                    local idx = row * cols + col
                    paint_page(first_page + idx, margin_x + col * (cell_w + gap),
                        grid_top + row * (cell_h + gap), cell_w, cell_h)
                end
            end
        end

        local slider_w = math.floor(math.min(slot_w * 0.70,
            slot_w * 0.76 - icon_size - icon_pad_v * 2 - Screen:scaleBySize(16)))
        local chapter_label = TextWidget:new{
            text      = "Chapter 1",
            face      = label_face,
            max_width = math.floor(slot_w * 0.6),
            padding   = 0,
        }
        local slider = ZenSlider:new{
            width     = slider_w,
            value     = 42,
            value_min = 1,
            value_max = 240,
        }

        local function make_button(file_path)
            return FrameContainer:new{
                padding = icon_pad_v,
                bordersize = 0,
                background = Blitbuffer.COLOR_WHITE,
                IconWidget:new{
                    file = file_path,
                    width = icon_size,
                    height = icon_size,
                },
            }
        end
        local buttons = {
            make_button(utils.resolveIcon(_icons_dir, "grid")),
            make_button(utils.resolveIcon(stock_icons_dir, "chevron.left")),
            make_button(utils.resolveIcon(stock_icons_dir, "chevron.right")),
            make_button(utils.resolveIcon(_icons_dir, "quick_search")),
        }
        local button_size = buttons[1]:getSize()
        local row_h = button_size.h
        local slider_y = panel_pad_top + row_h + Screen:scaleBySize(slider_gap)
        local contents = OverlapGroup:new{
            dimen = Geom:new{ w = slot_w, h = panel_h }, allow_mirroring = false,
        }
        add_chapter_rows(contents, 0, panel_pad_top, slot_w, row_h, chapter_label,
            make_progress_label(format_progress(42, 240, 17), math.floor(slot_w * 0.6)))
        for i, button in ipairs(buttons) do
            local x = math.floor(slot_w * (i <= 2 and 0.12 or 0.88) - button_size.w / 2)
            local y = (i == 1 or i == 4) and panel_pad_top or slider_y
            button.overlap_offset = { x, y }
            contents[#contents + 1] = button
        end
        contents[#contents + 1] = CenterContainer:new{
            dimen = Geom:new{ w = slot_w, h = row_h }, slider,
            overlap_offset = { 0, slider_y },
        }
        local panel = FrameContainer:new{
            width = slot_w, height = panel_h, padding = 0, margin = 0, bordersize = 0,
            background = Blitbuffer.COLOR_WHITE, contents,
        }
        panel:paintTo(canvas, 0, panel_top)
        canvas:paintRect(0, panel_top, slot_w, Screen:scaleBySize(1), Blitbuffer.COLOR_LIGHT_GRAY)
        if panel.free then panel:free() end
        return canvas
    end)

    -- -----------------------------------------------------------------------
    -- ZenOS customisations applied once to PageBrowserWidget
    -- -----------------------------------------------------------------------
    local _zen_pbw_patched = false

    local function zen_patch_page_browser_widget()
        if _zen_pbw_patched then return end
        _zen_pbw_patched = true

        require("modules/reader/page_browser_widget"){
            plugin = _plugin_ref, icons_dir = _icons_dir, stock_icons_dir = _stock_icons_dir,
            panel_height = panel_height, preview_padding = preview_padding,
            chapter_padding = chapter_padding, slider_gap = slider_gap,
            format_progress = format_progress, make_progress_label = make_progress_label,
            add_chapter_rows = add_chapter_rows, reset_thumbnail_cache = reset_thumbnail_cache,
            key_matches_menu = key_matches_menu, supports_page_browser_focus = supports_page_browser_focus,
            get_page_browser_layout = get_page_browser_layout, set_page_browser_layout = set_page_browser_layout,
        }
    end

    -- -----------------------------------------------------------------------
    -- Open KOReader's native PageBrowserWidget (with ZenOS tweaks)
    -- -----------------------------------------------------------------------
    local function open_page_browser(ui, from_menu_hold, layout, tab)
        local PageBrowserWidget = require("ui/widget/pagebrowserwidget")
        local previous_layout = layout and get_page_browser_layout()
        if layout then set_page_browser_layout(layout) end
        zen_patch_page_browser_widget()
        local browser = PageBrowserWidget:new{ ui = ui, _zen_initial_tab = tab }
        browser._zen_ignore_opening_menu_key = from_menu_hold or nil
        UIManager:show(browser)
        if layout then
            return browser, function()
                set_page_browser_layout(previous_layout)
                browser:onClose()
            end
        end
        return browser
    end

    ReaderThumbnail.onShowPageBrowser = function(self_rt, tab)
        open_page_browser(self_rt.ui, nil, nil, tab)
        return true
    end

    local function start_reader_tour(ui)
        local ok, tour = pcall(require, "common/quickstart/reader_tour")
        if ok then
            tour.start(_plugin_ref, ui, function(layout)
                return open_page_browser(ui, nil, layout)
            end)
        end
    end

    -- Patch ReaderMenu.initGesListener to register the swipe-up zone
    -- -----------------------------------------------------------------------
    local ReaderMenu = require("apps/reader/modules/readermenu")
    local _orig_initGesListener = ReaderMenu.initGesListener

    ReaderMenu._zen_start_reader_tour = function(self_rm)
        if type(self_rm.onCloseReaderMenu) == "function" then
            self_rm:onCloseReaderMenu()
        end
        UIManager:scheduleIn(0, function() start_reader_tour(self_rm.ui) end)
    end

    local _orig_reader_menu_onKeyPress = ReaderMenu.onKeyPress
    local _orig_reader_menu_onKeyRepeat = ReaderMenu.onKeyRepeat
    local _orig_reader_menu_onKeyRelease = ReaderMenu.onKeyRelease
    local MENU_HOLD_DELAY = 0.5

    ReaderMenu.onKeyPress = function(self_rm, key)
        if is_non_touch_device() and is_enabled() and key_matches_menu(key) then
            if not self_rm._zen_page_browser_menu_hold_fn then
                self_rm._zen_page_browser_menu_hold_fn = function()
                    self_rm._zen_page_browser_menu_hold_fn = nil
                    if is_enabled() then open_page_browser(self_rm.ui, true) end
                end
                UIManager:scheduleIn(MENU_HOLD_DELAY, self_rm._zen_page_browser_menu_hold_fn)
            end
            return true
        end
        return _orig_reader_menu_onKeyPress and _orig_reader_menu_onKeyPress(self_rm, key)
    end

    ReaderMenu.onKeyRepeat = function(self_rm, key)
        if is_non_touch_device() and is_enabled() and key_matches_menu(key) then
            return true
        end
        return _orig_reader_menu_onKeyRepeat and _orig_reader_menu_onKeyRepeat(self_rm, key)
    end

    ReaderMenu.onKeyRelease = function(self_rm, key)
        if is_non_touch_device() and key_matches_menu(key) then
            local hold_fn = self_rm._zen_page_browser_menu_hold_fn
            if hold_fn then
                UIManager:unschedule(hold_fn)
                self_rm._zen_page_browser_menu_hold_fn = nil
                if is_enabled() and type(self_rm.onKeyPressShowMenu) == "function" then
                    return self_rm:onKeyPressShowMenu(nil, key)
                end
            end
            return true
        end
        return _orig_reader_menu_onKeyRelease and _orig_reader_menu_onKeyRelease(self_rm, key)
    end

    local function handle_bottom_swipe(ui, ges)
        local config = _plugin_ref and _plugin_ref.config
        if not config or not BottomSwipe.isEnabled(config) or ges.direction ~= "north" then return end
        local mode = BottomSwipe.getMode(config)
        if mode == "page_browser" then
            open_page_browser(ui)
        elseif mode == "reader_controls" then
            ui.menu:onShowReaderControls()
        elseif mode == "custom" then
            local entry = config.reader_bottom_swipe.entries[1]
            if entry then
                require("modules/menu/app_launcher/entry_action")(entry, nil, _plugin_ref, "reader")
            end
        else
            return
        end
        ui:handleEvent(Event:new("HandledAsSwipe"))
        return true
    end

    local function register_page_browser_zone(ui)
        ui:registerTouchZones({
            {
                id          = "zen_page_browser_reader",
                ges         = "swipe",
                screen_zone = {
                    ratio_x = 0, ratio_y = 0.86, ratio_w = 1, ratio_h = 0.14,
                },
                -- Override the config-menu and page-turn swipe zones so our
                -- north-swipe wins.  We deliberately do NOT override the tap
                -- zones (readerconfigmenu_tap etc.) — those cause unintended
                -- pan/brightness-slider interference via the zone sort order.
                overrides = {
                    "readerconfigmenu_swipe",
                    "readerconfigmenu_ext_swipe",
                    "paging_swipe",
                    "rolling_swipe",
                },
                handler = function(ges)
                    return handle_bottom_swipe(ui, ges)
                end,
            },
        })
    end

    ReaderMenu.initGesListener = function(self_rm)
        if _orig_initGesListener then
            _orig_initGesListener(self_rm)
        end
        register_page_browser_zone(self_rm.ui)
        -- One pending tour check per menu (also runs on rotation); skip once the book closed.
        if self_rm._zen_tour_timer then UIManager:unschedule(self_rm._zen_tour_timer) end
        self_rm._zen_tour_timer = function()
            self_rm._zen_tour_timer = nil
            if self_rm.ui and self_rm.ui.document then start_reader_tour(self_rm.ui) end
        end
        UIManager:scheduleIn(0.5, self_rm._zen_tour_timer)
    end

    -- onReaderReady is aliased to initGesListener in KOReader; keep in sync
    ReaderMenu.onReaderReady = ReaderMenu.initGesListener

    -- If a book is already open when this patch is applied (feature toggled
    -- at runtime), register the zone immediately.
    local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_rui and ReaderUI and ReaderUI.instance then
        pcall(register_page_browser_zone, ReaderUI.instance)
    end

    -- -----------------------------------------------------------------------
    -- ZenOS customisations for fulltext search dialog
    -- -----------------------------------------------------------------------
    local ok_rs, ReaderSearch = pcall(require, "apps/reader/modules/readersearch")
    local search_features = _plugin_ref and _plugin_ref.config
        and _plugin_ref.config.features
    if ok_rs and ReaderSearch
            and (type(search_features) ~= "table" or search_features.search ~= false) then
        local InputDialog = require("ui/widget/inputdialog")
        local Screen_s    = require("device").screen
        local BD          = require("ui/bidi")
        local ZenModalClose = require("common/ui/zen_modal_close")
        local _           = require("gettext")
        local logger_rs   = require("common/zen_logger").new("page_browser")

        local _orig_InputDialog_onTap = InputDialog.onTap

        local SEARCH_ICON = "\u{F002}"

        local function enable_search_dialog_close(dialog)
            local function close_dialog()
                UIManager:close(dialog)
                return true
            end

            dialog.onCloseDialog = close_dialog
            ZenModalClose.installDialog(dialog, close_dialog)

            -- The virtual keyboard otherwise consumes Back and only hides itself.
            local keyboard = dialog._input_widget and dialog._input_widget.keyboard
            local keyboard_back = keyboard and keyboard.key_events and keyboard.key_events.Close
            if keyboard_back then
                keyboard.key_events.Close = nil
                keyboard.key_events.ZenCloseSearchDialog = keyboard_back
                keyboard_back.event = "ZenCloseSearchDialog"
                keyboard.onZenCloseSearchDialog = close_dialog
            end
        end

        ReaderSearch.onShowFulltextSearchInput = function(self, search_string)
            local backward_text, forward_text = "◀", "▶"
            if BD.mirroredUILayout() then
                backward_text, forward_text = forward_text, backward_text
            end
            local arrow_width = Screen_s:scaleBySize(56)
            local search_btn = {
                text             = SEARCH_ICON .. " " .. _("Search"),
                is_enter_default = true,
                callback         = function()
                    self:searchCallback()
                end,
            }
            -- From page browser: results list only; prev/next would jump behind it.
            local button_row = self._zen_page_browser and { search_btn } or {
                {
                    text = backward_text,
                    width = arrow_width,
                    callback = function()
                        self:searchCallback(1)
                    end,
                },
                search_btn,
                {
                    text = forward_text,
                    width = arrow_width,
                    callback = function()
                        self:searchCallback(0)
                    end,
                },
            }
            self.input_dialog = InputDialog:new{
                title = _("Search Book"),
                width = math.floor(math.min(Screen_s:getWidth(), Screen_s:getHeight()) * 0.9),
                input = search_string
                    or self.last_search_text
                    or (self.ui.doc_settings
                        and self.ui.doc_settings:readSetting("fulltext_search_last_search_text")),
                buttons = { button_row },
            }
            enable_search_dialog_close(self.input_dialog)
            -- Always case insensitive, whole-word via regex
            self.case_insensitive = true
            self.check_button_case = { checked = false }
            self.check_button_regex = { checked = false }

            -- Tap outside = close keyboard + dialog together
            self.input_dialog.onTap = function(dialog_self, arg, ges)
                if dialog_self.deny_keyboard_hiding then return end
                if dialog_self:isKeyboardVisible() then
                    local kb = dialog_self._input_widget and dialog_self._input_widget.keyboard
                    if kb and kb.dimen
                       and ges.pos:notIntersectWith(kb.dimen)
                       and ges.pos:notIntersectWith(dialog_self.dialog_frame.dimen) then
                        dialog_self:onCloseKeyboard()
                        UIManager:close(dialog_self)
                        return true
                    end
                    return _orig_InputDialog_onTap(dialog_self, arg, ges)
                else
                    if ges.pos:notIntersectWith(dialog_self.dialog_frame.dimen) then
                        UIManager:close(dialog_self)
                        return true
                    end
                end
            end

            UIManager:show(self.input_dialog)
            self.input_dialog:onShowKeyboard()
        end

        -- Whole-word matching via \b word-boundary assertions.
        -- Note: \b is ASCII-only in ECMAScript/SRELL (matches [A-Za-z0-9_] boundaries),
        -- so it correctly handles the Latin-script case (e.g. "red" does not match "tired").
        -- Lookbehind/lookahead (?<!...) require SRELL 4+; older embedded SRELL versions
        -- silently ignore them, causing every pattern to match as a substring.
        local function make_whole_word_regex(text)
            local escaped = text:gsub("[%^%$%.%*%+%?%(%)%[%]%{%}%|\\]", "\\%0")
            return "\\b" .. escaped .. "\\b"
        end

        local function supports_regex_search(self)
            local document = self.ui and self.ui.document
            return document and type(document.checkRegex) == "function"
        end

        local function fixed_layout_whole_word(text)
            -- Kopt treats surrounding spaces as start/end word boundaries.
            return " " .. text .. " "
        end

        local _orig_rs_search = ReaderSearch.search
        local function regex_search_type(self, search_type)
            local source_type = search_type
            if type(source_type) ~= "table" then
                source_type = self.current_search_type or self.default_search_type
            end
            if type(source_type) ~= "table" then
                return true -- KOReader before search-type tables used a regex boolean.
            end
            local whole_word_type = {}
            for key, value in pairs(source_type) do
                whole_word_type[key] = value
            end
            whole_word_type.regex = true
            return whole_word_type
        end

        function ReaderSearch:search(pattern, origin, search_type, case_insensitive)
            if not is_substring_enabled() and supports_regex_search(self) then
                pattern = make_whole_word_regex(pattern)
                search_type = regex_search_type(self, search_type)
            elseif not is_substring_enabled() then
                pattern = fixed_layout_whole_word(pattern)
            end
            return _orig_rs_search(self, pattern, origin, search_type, case_insensitive)
        end

        local _orig_rs_findAllText = ReaderSearch.findAllText
        function ReaderSearch:findAllText(search_text)
            if not is_substring_enabled() and supports_regex_search(self) then
                search_text = make_whole_word_regex(search_text)
                if type(self.current_search_type) == "table" then
                    local saved_search_type = self.current_search_type
                    self.current_search_type = regex_search_type(self, saved_search_type)
                    local result = _orig_rs_findAllText(self, search_text)
                    self.current_search_type = saved_search_type
                    return result
                end
                self.use_regex = true
            elseif not is_substring_enabled() then
                search_text = fixed_layout_whole_word(search_text)
            end
            return _orig_rs_findAllText(self, search_text)
        end

        local function enable_search_results_focus(menu)
            if not supports_page_browser_focus() then return end

            menu.mergeTitleBarIntoLayout = function(menu_self)
                local title_layout = menu_self.title_bar
                    and menu_self.title_bar:generateHorizontalLayout() or {}
                for i, row in ipairs(title_layout) do
                    table.insert(menu_self.layout, i, row)
                end
                if menu_self.selected then
                    menu_self.selected.y = menu_self.selected.y + #title_layout
                end
            end

            local orig_on_key_press = menu.onKeyPress
            menu.onKeyPress = function(menu_self, key)
                if key and type(key.match) == "function" then
                    if key:match({ "Up" }) then
                        return menu_self:onFocusMove({ 0, -1 })
                    elseif key:match({ "Right" }) then
                        return menu_self:onFocusMove({ 1, 0 })
                    elseif key:match({ "Down" }) then
                        return menu_self:onFocusMove({ 0, 1 })
                    elseif key:match({ "Left" }) then
                        return menu_self:onFocusMove({ -1, 0 })
                    elseif key:match({ "Press" }) or key:match({ "Return" })
                            or key:match({ "Enter" }) then
                        return menu_self:onPress()
                    end
                end
                return orig_on_key_press and orig_on_key_press(menu_self, key)
            end

            local orig_on_key_repeat = menu.onKeyRepeat
            menu.onKeyRepeat = function(menu_self, key)
                if key and type(key.match) == "function" then
                    if key:match({ "Up" }) then
                        return menu_self:onFocusMove({ 0, -1 })
                    elseif key:match({ "Right" }) then
                        return menu_self:onFocusMove({ 1, 0 })
                    elseif key:match({ "Down" }) then
                        return menu_self:onFocusMove({ 0, 1 })
                    elseif key:match({ "Left" }) then
                        return menu_self:onFocusMove({ -1, 0 })
                    end
                end
                return orig_on_key_repeat and orig_on_key_repeat(menu_self, key)
            end

            menu:updateItems(1, true)
        end

        -- Patch onShowFindAllResults: fix reader-content ghosting at the bottom
        -- of the screen when search results are shown.
        --
        -- ROOT CAUSE: Menu:new{} runs while Screen:getHeight() is still reduced
        -- by the virtual keyboard (shown for our search InputDialog). This makes
        -- menu.dimen.h and the internal OverlapGroup dimen height equal to the
        -- keyboard-shrunk height (~1525 vs real 1696 on a Kobo). Menu:init()
        -- creates its FrameContainer WITHOUT an explicit height — so the FC's
        -- paintTo uses `self.height or my_size.h = nil or 1525 = 1525`, filling
        -- only 1525px of white background and leaving the bottom 171px untouched
        -- (showing through the reader content in the framebuffer).
        --
        -- By the time our wrapper runs (after UIManager:show(result_menu) returns),
        -- the keyboard has been dismissed and Screen:getHeight() is back to the
        -- real value. We patch menu.dimen.h (gesture hit range) and set an
        -- explicit menu[1].height (FrameContainer) so its background fill covers
        -- the full screen.  A flashui setDirty then schedules a full e-ink refresh.
        local _orig_onShowFindAllResults = ReaderSearch.onShowFindAllResults
        ReaderSearch.onShowFindAllResults = function(self, not_cached)
            _orig_onShowFindAllResults(self, not_cached)
            local menu = self.result_menu
            if not menu or not UIManager:isWidgetShown(menu) then return end

            enable_search_results_focus(menu)

            local page_browser = self._zen_page_browser
            if page_browser and menu.onMenuChoice then
                local orig_choice = menu.onMenuChoice
                menu.onMenuChoice = function(...)
                    page_browser:onClose(true)
                    return orig_choice(...)
                end
            end

            local real_h = Screen_s:getHeight()

            -- Fix outer dimen so gesture hit-testing covers the full screen.
            if menu.dimen and menu.dimen.h < real_h then
                logger_rs.info("fixing menu height:", menu.dimen.h, "→", real_h)
                menu.dimen.h = real_h
            end

            -- Force an explicit height on the FrameContainer so its white
            -- background fill (container_height = self.height or my_size.h)
            -- extends to the full screen rather than stopping at the
            -- keyboard-shrunk OverlapGroup height.
            local fc = menu[1]
            if fc then
                fc.height = real_h
            end

            UIManager:setDirty(menu, "flashui")

            -- Extend close_callback to mark the reader view dirty after the
            -- results menu is dismissed.  Without this the clock overlay drawn
            -- by ReaderView.paintTo may not be repainted because the guard in
            -- that patch skips drawing while a non-reader widget is on top, and
            -- the subsequent UIManager repaint cycle can miss re-invoking paintTo.
            if menu.close_callback then
                local orig_close_cb = menu.close_callback
                menu.close_callback = function()
                    orig_close_cb()
                    -- ReaderView is not a window; dirty ReaderUI so paintTo actually runs.
                    if self.ui then
                        UIManager:setDirty(self.ui, "partial")
                    end
                end
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- Primary intercept: patch ReaderConfig.onSwipeShowConfigMenu directly.
    -- More reliable than zone-override ordering since it does not depend on
    -- the dep-graph re-serialisation happening in the right order.
    -- -----------------------------------------------------------------------
    local function is_bottom_swipe_enabled()
        return _plugin_ref and _plugin_ref.config and BottomSwipe.isEnabled(_plugin_ref.config)
    end

    local ok_rc, ReaderConfig = pcall(require, "apps/reader/modules/readerconfig")
    if ok_rc and ReaderConfig then
        local _orig_onSwipeShowConfigMenu = ReaderConfig.onSwipeShowConfigMenu
        ReaderConfig.onSwipeShowConfigMenu = function(self_rc, ges)
            if handle_bottom_swipe(self_rc.ui, ges) then return true end
            -- suppress native config menu swipe when bottom swipe is disabled
            if not is_bottom_swipe_enabled() then return end
            if _orig_onSwipeShowConfigMenu then
                return _orig_onSwipeShowConfigMenu(self_rc, ges)
            end
        end

        -- suppress bottom tap opening the native config menu when Zen owns the zone
        local _orig_onTapShowConfigMenu = ReaderConfig.onTapShowConfigMenu
        ReaderConfig.onTapShowConfigMenu = function(self_rc)
            if is_bottom_swipe_enabled() then return end
            if _orig_onTapShowConfigMenu then
                return _orig_onTapShowConfigMenu(self_rc)
            end
        end
    end

end -- apply_page_browser

return apply_page_browser
