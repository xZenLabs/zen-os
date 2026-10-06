-- ZenTocWidget: popup table-of-contents modal for the page browser.
--
-- Usage:
--   local ZenTocWidget = require("modules/reader/zen_toc_widget")
--   UIManager:show(ZenTocWidget:new{
--       ui         = pbw.ui,          -- ReaderUI instance
--       focus_page = pbw.focus_page,  -- current page for highlighting
--       on_goto    = function(page)   -- called when user taps a chapter
--           if pbw:updateFocusPage(page, false) then pbw:update() end
--       end,
--   })
--
-- Interaction:
--   Tap entry         → navigate to chapter, close modal
--   Tap outside / ‹   → close modal
--   Swipe left/right  → next / prev page of TOC entries
--   Zen scroll bar    → shows current position in TOC list

local InputContainer = require("ui/widget/container/inputcontainer")
local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local IconWidget     = require("ui/widget/iconwidget")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local lfs            = require("libs/libkoreader-lfs")
local Screen         = Device.screen
local pager          = require("common/ui/zen_pager")
local LibraryFont    = require("modules/filebrowser/patches/library_font")
local ReaderFont     = require("common/reader_font")
local TitleStyle     = require("common/ui/zen_title_style")
local utils          = require("common/utils")
local _              = require("gettext")

local function resolve_stock_icon(name)
    return utils.resolveLocalIcon(lfs.currentdir() .. "/resources/icons/mdlight/", name)
end

local BACK_ICON_PATH = resolve_stock_icon("chevron.left")
local CLOSE_ICON_PATH = resolve_stock_icon("close")

local function supports_hardware_focus()
    local has_dpad = type(Device.hasDPad) == "function" and Device:hasDPad()
    local has_keyboard = type(Device.hasKeyboard) == "function" and Device:hasKeyboard()
    return has_dpad or has_keyboard
end

-- ---------------------------------------------------------------------------
-- Title normalization: strips zero-width spaces and collapses whitespace.
-- Epub NCX parsers sometimes insert ZWSP (U+200B) between characters, which
-- later surfaces as visible spaces (e.g. "I NTRODUCTION").
-- ---------------------------------------------------------------------------
local function normalize_title(s)
    if not s or s == "" then return "" end
    -- Zero-width space / non-joiner / joiner (E2 80 8B/8C/8D)
    s = s:gsub("\xE2\x80[\x8B\x8C\x8D]", "")
    -- BOM / zero-width no-break space (EF BB BF)
    s = s:gsub("\xEF\xBB\xBF", "")
    -- Non-breaking space (C2 A0) → regular space
    s = s:gsub("\xC2\xA0", " ")
    -- Narrow no-break space (E2 80 AF) → regular space
    s = s:gsub("\xE2\x80\xAF", " ")
    -- Collapse runs of whitespace and trim
    s = s:gsub("%s+", " ")
    s = s:match("^%s*(.-)%s*$") or s
    return s
end

local function is_placeholder_title(title)
    local stripped = title:gsub("%s+", ""):gsub("%-", "")
        :gsub("\xE2\x80\x93", ""):gsub("\xE2\x80\x94", "")
    return stripped == ""
end

local function get_entry_title(ui, entry, page)
    local title = normalize_title(entry.title or "")
    local toc = ui and ui.toc
    if is_placeholder_title(title) and toc
            and type(toc.getTocTitleByPage) == "function" then
        local resolved = normalize_title(toc:getTocTitleByPage(page) or "")
        if not is_placeholder_title(resolved) then title = resolved end
    end
    return title
end

local function get_toc_page_label(ui, entry, fallback_page)
    local pagemap = ui and ui.pagemap
    if pagemap and type(pagemap.wantsPageLabels) == "function"
        and pagemap:wantsPageLabels()
        and entry and entry.xpointer
        and type(pagemap.getXPointerPageLabel) == "function" then
        local label = pagemap:getXPointerPageLabel(entry.xpointer)
        if label then
            return tostring(label)
        end
    end
    return tostring(fallback_page)
end

-- ---------------------------------------------------------------------------
-- ZenTocWidget
-- ---------------------------------------------------------------------------
local ZenTocWidget = InputContainer:extend{
    ui         = nil,   -- ReaderUI instance
    on_goto    = nil,   -- callback(page_num) when entry tapped
    close_all_callback = nil,
    focus_page = 1,     -- current page; used to highlight active chapter
    font_size  = nil,
}

function ZenTocWidget:init()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }

    -- Collect TOC entries, cap depth at 3 to avoid overwhelming the list.
    -- ReaderToc exposes the raw array as .toc (not a method).
    -- Entries sharing the same page are merged: titles joined with " · ".
    local raw = (self.ui and self.ui.toc and self.ui.toc.toc) or {}
    local entries = {}
    local page_to_idx = {}
    for _i, e in ipairs(raw) do
        local pg    = e.page or 1
        local depth = e.depth or 1
        if depth <= 3 then
            local title = get_entry_title(self.ui, e, pg)
            local idx   = page_to_idx[pg]
            if idx then
                -- Merge: append title only if it's not a duplicate string
                local existing = entries[idx].title
                if title ~= "" and is_placeholder_title(existing) then
                    entries[idx].title = title
                elseif title ~= "" and title ~= existing then
                    entries[idx].title = existing .. " · " .. title
                end
                -- Keep the shallowest (lowest) depth
                if depth < entries[idx].depth then
                    entries[idx].depth = depth
                end
            else
                page_to_idx[pg] = #entries + 1
                table.insert(entries, {
                    title      = title,
                    page       = pg,
                    page_label = get_toc_page_label(self.ui, e, pg),
                    depth      = depth,
                })
            end
        end
    end
    self._entries = entries

    local text_font_size = tonumber(self.font_size)
        or ReaderFont.getInfo(self.ui, 18).size
    self._text_face = LibraryFont.getFace(text_font_size)

    -- -----------------------------------------------------------------------
    -- Layout constants (all screen-scaled)
    -- -----------------------------------------------------------------------
    local MODAL_W     = sw
    local BORDER      = 0
    local PAD         = Screen:scaleBySize(16)   -- horizontal content padding
    local TITLE_H     = TitleStyle.HEADER_CONTENT_HEIGHT
    local SEP_H       = TitleStyle.DIVIDER_HEIGHT
    local row_sample  = TextWidget:new{ text = "Wg", face = self._text_face, padding = 0 }
    local ROW_H       = math.max(Screen:scaleBySize(48), row_sample:getSize().h + Screen:scaleBySize(16))
    row_sample:free()
    local BAR_PAD_V   = Screen:scaleBySize(7)
    local DOT_DIAM    = Screen:scaleBySize(10)
    local DOT_GAP     = Screen:scaleBySize(12)

    -- Fit rows into full screen height (minus title bar and optional scrollbar).
    local max_list_h_full = sh - TITLE_H - SEP_H
    local per_page_full   = math.max(1, math.floor(max_list_h_full / ROW_H))

    -- Footer style follows the library "Scroll bar" setting (bar/dots/page_number).
    -- page_number needs the taller strip to fit its chevron icons.
    local toc_style   = pager.getStyle()
    local needs_bar   = #entries > per_page_full
    local SCROLLBAR_H = needs_bar
        and (toc_style == "page_number" and pager.PN_FOOTER_H or pager.FOOTER_H)
        or 0

    local max_list_h = max_list_h_full - SCROLLBAR_H
    local per_page   = math.max(1, math.floor(max_list_h / ROW_H))
    local list_h     = per_page * ROW_H
    local MODAL_H    = sh
    local MODAL_X    = 0
    local MODAL_Y    = 0

    local BACK_W = TitleStyle.BUTTON_SIZE
    local BACK_X = TitleStyle.LEFT_PADDING
    local BACK_Y = MODAL_Y

    -- Y where entry rows start (absolute screen coords).
    local LIST_Y = MODAL_Y + TITLE_H + SEP_H

    -- Footer bar geometry (shared by paintTo and the page_number tap zones).
    local BAR_W = math.floor(MODAL_W * 0.78)
    local BAR_X = math.floor((MODAL_W - BAR_W) / 2)   -- offset from modal left
    local BAR_Y = pager.getCenteredFooterY(
        LIST_Y + list_h,
        MODAL_Y + MODAL_H - SCROLLBAR_H,
        SCROLLBAR_H,
        needs_bar
    )

    self._L = {
        sw = sw, sh = sh,
        modal_w = MODAL_W, modal_h = MODAL_H,
        modal_x = MODAL_X, modal_y = MODAL_Y,
        border  = BORDER,  pad     = PAD,
        title_h = TITLE_H, sep_h   = SEP_H,
        row_h   = ROW_H,   per_page = per_page,
        list_h  = list_h,  list_y   = LIST_Y,
        bar_pad_v = BAR_PAD_V,
        dot_diam = DOT_DIAM, dot_gap = DOT_GAP,
        scrollbar_h = SCROLLBAR_H,
        style   = toc_style,
        bar_w   = BAR_W,   bar_x   = BAR_X, bar_y = BAR_Y,
        back_x = BACK_X, back_y = BACK_Y,
        back_w = BACK_W, back_h = TITLE_H,
        close_all_x = MODAL_X + MODAL_W
            - TitleStyle.RIGHT_PADDING - TitleStyle.BUTTON_SIZE,
        close_all_w = TitleStyle.BUTTON_SIZE,
    }

    local nb_pages = math.max(1, math.ceil(#entries / per_page))
    self._nb_pages = nb_pages
    self._toc_page = 1

    -- Scroll to the page containing the active (current) chapter.
    self:_initActivePage()
    self._zen_focus_enabled = supports_hardware_focus()
    if self._zen_focus_enabled then
        self._zen_focus_area = "back"
        self._zen_focus_entry_idx = (self._toc_page - 1) * per_page + 1
    end

    -- -----------------------------------------------------------------------
    -- Touch zones
    -- -----------------------------------------------------------------------
    self:registerTouchZones({
        {
            id          = "zen_toc_swipe",
            ges         = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler     = function(ges) return self:_onSwipe(ges) end,
        },
        {
            id          = "zen_toc_tap",
            ges         = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler     = function(ges) return self:_onTap(ges) end,
        },
        {
            id          = "zen_toc_hold",
            ges         = "hold",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler     = function(ges) return self:_onHold(ges) end,
        },
    })
    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
            TocPageUp = {
                { Device.input.group.PgBack },
                event = "TocPage",
                args = -1,
            },
            TocPageDown = {
                { Device.input.group.PgFwd },
                event = "TocPage",
                args = 1,
            },
        }
    end
end

function ZenTocWidget:_visibleEntryBounds()
    local first = (self._toc_page - 1) * self._L.per_page + 1
    return first, math.min(first + self._L.per_page - 1, #self._entries)
end

function ZenTocWidget:_hasFooterButtons()
    return self._L.style == "page_number" and self._nb_pages > 1
end

function ZenTocWidget:_setFocus(area, entry_idx, footer_side)
    if not self._zen_focus_enabled then return end
    self._zen_focus_area = area
    if entry_idx then self._zen_focus_entry_idx = entry_idx end
    if footer_side then self._zen_footer_side = footer_side end
    UIManager:setDirty(self, "fast")
end

function ZenTocWidget:_moveFocus(dx, dy)
    local first, last = self:_visibleEntryBounds()
    if self._zen_focus_area == "back" then
        if dx > 0 then self:_setFocus("close") end
        if dy > 0 and first <= last then self:_setFocus("entry", first) end
        return true
    elseif self._zen_focus_area == "close" then
        if dx < 0 then self:_setFocus("back") end
        if dy > 0 and first <= last then self:_setFocus("entry", first) end
        return true
    elseif self._zen_focus_area == "footer" then
        if dy < 0 and first <= last then
            self:_setFocus("entry", last)
        elseif dx < 0 then
            self:_setFocus("footer", nil, "left")
        elseif dx > 0 then
            self:_setFocus("footer", nil, "right")
        end
        return true
    end

    local entry_idx = math.max(first, math.min(last, self._zen_focus_entry_idx or first))
    if dy < 0 then
        if entry_idx > first then
            self:_setFocus("entry", entry_idx - 1)
        else
            self:_setFocus("back")
        end
    elseif dy > 0 then
        if entry_idx < last then
            self:_setFocus("entry", entry_idx + 1)
        elseif self:_hasFooterButtons() then
            self:_setFocus("footer", nil, "left")
        end
    end
    return true
end

function ZenTocWidget:onPress()
    if self._zen_focus_area == "back" then
        self:_flashHeader(false)
        return self:onClose()
    end
    if self._zen_focus_area == "close" then
        self:_flashHeader(true)
        return self:onCloseAll()
    end
    if self._zen_focus_area == "footer" then
        local direction = self._zen_footer_side == "right" and 1 or -1
        self:_gotoTocPage(self._toc_page + direction)
        return true
    end
    local entry = self._entries[self._zen_focus_entry_idx]
    if not entry then return true end
    self:onClose()
    if self.on_goto then self.on_goto(entry.page) end
    return true
end

function ZenTocWidget:onTocPage(direction)
    self:_gotoTocPage(self._toc_page + direction)
    return true
end

local _orig_onKeyPress = InputContainer.onKeyPress
function ZenTocWidget:onKeyPress(key)
    if self._zen_focus_enabled and key and type(key.match) == "function" then
        if key:match({ "Up" }) then
            return self:_moveFocus(0, -1)
        elseif key:match({ "Right" })
                and (self._zen_focus_area == "back" or self._zen_focus_area == "footer") then
            return self:_moveFocus(1, 0)
        elseif key:match({ "Down" }) then
            return self:_moveFocus(0, 1)
        elseif key:match({ "Left" })
                and (self._zen_focus_area == "close" or self._zen_focus_area == "footer") then
            return self:_moveFocus(-1, 0)
        elseif key:match({ "Press" }) or key:match({ "Return" }) or key:match({ "Enter" }) then
            return self:onPress()
        end
    end
    return _orig_onKeyPress and _orig_onKeyPress(self, key)
end

local _orig_onKeyRepeat = InputContainer.onKeyRepeat
function ZenTocWidget:onKeyRepeat(key)
    if self._zen_focus_enabled and key and type(key.match) == "function" then
        if key:match({ "Up" }) then
            return self:_moveFocus(0, -1)
        elseif key:match({ "Right" })
                and (self._zen_focus_area == "back" or self._zen_focus_area == "footer") then
            return self:_moveFocus(1, 0)
        elseif key:match({ "Down" }) then
            return self:_moveFocus(0, 1)
        elseif key:match({ "Left" })
                and (self._zen_focus_area == "close" or self._zen_focus_area == "footer") then
            return self:_moveFocus(-1, 0)
        end
    end
    return _orig_onKeyRepeat and _orig_onKeyRepeat(self, key)
end

-- ---------------------------------------------------------------------------
-- Footer hit-test for the page_number style: returns "left"|"center"|"right"
-- when the point falls inside the chevron bar, else nil.
-- ---------------------------------------------------------------------------
function ZenTocWidget:_footerZone(p, extend_down)
    local L = self._L
    if L.style ~= "page_number" or self._nb_pages <= 1 then return nil end
    local bar_left  = L.modal_x + L.bar_x
    return pager.getPageNumberZone(
        p.x, p.y, bar_left, L.bar_y, L.bar_w, L.scrollbar_h,
        extend_down and L.sh or L.bar_y + L.scrollbar_h
    )
end

-- Navigate to a TOC page (clamped) and repaint.
function ZenTocWidget:_gotoTocPage(target)
    local L = self._L
    target = math.max(1, math.min(self._nb_pages, target))
    if target == self._toc_page then return end
    local old_first = (self._toc_page - 1) * L.per_page + 1
    local row_offset = math.max(0, (self._zen_focus_entry_idx or old_first) - old_first)
    self._toc_page = target
    if self._zen_focus_enabled and self._zen_focus_area == "entry" then
        local first, last = self:_visibleEntryBounds()
        self._zen_focus_entry_idx = math.min(first + row_offset, last)
    end
    UIManager:setDirty(self, function()
        return "ui", Geom:new{
            x = L.modal_x, y = L.modal_y, w = L.modal_w, h = L.modal_h,
        }
    end)
end

-- ---------------------------------------------------------------------------
-- Determine which TOC page contains the current chapter
-- ---------------------------------------------------------------------------
function ZenTocWidget:_initActivePage()
    local active_idx = 1
    for i, e in ipairs(self._entries) do
        if e.page <= self.focus_page then
            active_idx = i
        end
    end
    self._active_entry_idx = active_idx
    local L = self._L
    self._toc_page = math.max(1,
        math.min(self._nb_pages, math.ceil(active_idx / L.per_page)))
end

-- ---------------------------------------------------------------------------
-- paintTo: full custom rendering — no child widgets
-- ---------------------------------------------------------------------------
function ZenTocWidget:paintTo(bb, x, y)
    local L  = self._L

    -- Cover the full screen with white so the page browser beneath is hidden.
    bb:paintRect(x, y, L.sw, L.sh, Blitbuffer.COLOR_WHITE)

    -- Modal is full-screen: origin is (x, y).
    local mx = x + L.modal_x
    local my = y + L.modal_y

    -- -----------------------------------------------------------------------
    -- Title bar: aligned with Zen settings and arrange screens.
    -- -----------------------------------------------------------------------
    local title_tw = TextWidget:new{
        text    = _("Table of contents"),
        face    = TitleStyle.getTitleFace(),
        fgcolor = Blitbuffer.COLOR_BLACK,
        bold    = true,
        padding = 0,
    }
    local tsz = title_tw:getSize()
    local title_x = TitleStyle.getTitleX(mx)
    local title_y = my + TitleStyle.VERTICAL_PADDING
        + math.floor((TitleStyle.ROW_HEIGHT - tsz.h) / 2)
    self._title_hit = { x = title_x, y = title_y, w = tsz.w, h = tsz.h }
    title_tw:paintTo(bb, title_x, title_y)
    title_tw:free()

    -- Back icon (left chevron)
    local icon_sz    = TitleStyle.ICON_SIZE
    local back_icon = IconWidget:new{
        file   = BACK_ICON_PATH,
        width  = icon_sz,
        height = icon_sz,
    }
    local back_focused = self._zen_focus_enabled and self._zen_focus_area == "back"
    back_icon.invert = back_focused
    if back_focused then
        local focus_pad = Screen:scaleBySize(4)
        bb:paintRect(
            TitleStyle.getLeadingIconX(mx) - focus_pad,
            my + TitleStyle.VERTICAL_PADDING
                + math.floor((TitleStyle.ROW_HEIGHT - icon_sz) / 2) - focus_pad,
            icon_sz + 2 * focus_pad,
            icon_sz + 2 * focus_pad,
            Blitbuffer.COLOR_BLACK
        )
    end
    back_icon:paintTo(bb,
        TitleStyle.getLeadingIconX(mx),
        my + TitleStyle.VERTICAL_PADDING
            + math.floor((TitleStyle.ROW_HEIGHT - icon_sz) / 2))
    back_icon:free()

    -- Close-all icon (X)
    local close_icon = IconWidget:new{
        file   = CLOSE_ICON_PATH,
        width  = icon_sz,
        height = icon_sz,
    }
    local close_x = TitleStyle.getTrailingIconX(L.modal_w, mx)
    local close_y = my + TitleStyle.VERTICAL_PADDING
        + math.floor((TitleStyle.ROW_HEIGHT - icon_sz) / 2)
    local close_focused = self._zen_focus_enabled and self._zen_focus_area == "close"
    close_icon.invert = close_focused
    if close_focused then
        local focus_pad = Screen:scaleBySize(4)
        bb:paintRect(
            close_x - focus_pad,
            close_y - focus_pad,
            icon_sz + 2 * focus_pad,
            icon_sz + 2 * focus_pad,
            Blitbuffer.COLOR_BLACK
        )
    end
    close_icon:paintTo(bb, close_x, close_y)
    close_icon:free()

    -- Title separator line.
    bb:paintRect(mx, my + L.title_h, L.modal_w, L.sep_h, TitleStyle.DIVIDER_COLOR)

    -- -----------------------------------------------------------------------
    -- TOC entry rows
    -- -----------------------------------------------------------------------
    local start_i = (self._toc_page - 1) * L.per_page + 1
    local end_i   = math.min(start_i + L.per_page - 1, #self._entries)
    local ry      = y + L.list_y   -- absolute y of the first row

    if #self._entries == 0 then
        -- Empty state
        local etw = TextWidget:new{
            text    = _("No table of contents available."),
            face    = self._text_face,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            padding = 0,
        }
        local esz = etw:getSize()
        etw:paintTo(bb,
            mx + math.floor((L.modal_w - esz.w) / 2),
            ry + math.floor((L.list_h - esz.h) / 2))
        etw:free()
    else
        for i = start_i, end_i do
            local e        = self._entries[i]
            local row_top  = ry + (i - start_i) * L.row_h
            local is_active = (i == self._active_entry_idx)

            -- Row separator (above every row except the first)
            if i > start_i then
                bb:paintRect(mx, row_top, L.modal_w, 1, Blitbuffer.gray(220))
            end

            -- Active row highlight band
            if is_active then
                bb:paintRect(mx + L.border, row_top + 1,
                    L.modal_w - L.border * 2, L.row_h - 1,
                    Blitbuffer.gray(238))
            end

            -- Depth indent
            local indent = Screen:scaleBySize(14 * math.max(0, (e.depth or 1) - 1))
            local text_x = mx + L.pad + indent

            -- Page number (right-aligned)
            local page_str = e.page_label or tostring(e.page)
            local pn_tw    = TextWidget:new{
                text    = page_str,
                face    = self._text_face,
                fgcolor = Blitbuffer.COLOR_BLACK,
                bold    = is_active,
                padding = 0,
            }
            local pn_sz = pn_tw:getSize()
            local pn_x  = mx + L.modal_w - L.pad - pn_sz.w
            pn_tw:paintTo(bb, pn_x,
                row_top + math.floor((L.row_h - pn_sz.h) / 2))
            pn_tw:free()

            -- Chapter title (truncated to available width)
            local title_max_w = pn_x - text_x - Screen:scaleBySize(8)
            local title_tw2 = TextWidget:new{
                text      = e.title,
                face      = self._text_face,
                fgcolor   = Blitbuffer.COLOR_BLACK,
                bold      = is_active,
                max_width = title_max_w,
                padding   = 0,
            }
            local t_sz = title_tw2:getSize()
            title_tw2:paintTo(bb, text_x,
                row_top + math.floor((L.row_h - t_sz.h) / 2))
            title_tw2:free()

            if self._zen_focus_enabled and self._zen_focus_area == "entry"
                    and i == self._zen_focus_entry_idx then
                bb:invertRect(mx + L.border, row_top + 1,
                    L.modal_w - L.border * 2, L.row_h - 1)
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- Zen scroll bar (pill track + thumb) at modal bottom
    -- Only rendered when there is more than one page of entries.
    -- -----------------------------------------------------------------------
    if self._nb_pages > 1 then
        local scrollbar_top = y + L.bar_y
        pager.paint(bb, mx + L.bar_x, scrollbar_top, L.bar_w, L.scrollbar_h,
            self._toc_page, self._nb_pages)
        if self._zen_focus_enabled and self._zen_focus_area == "footer"
                and self:_hasFooterButtons() then
            local footer_x = self._zen_footer_side == "right"
                and mx + L.bar_x + L.bar_w - pager.CHEV_W or mx + L.bar_x
            bb:invertRect(footer_x, scrollbar_top, pager.CHEV_W, L.scrollbar_h)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Helper: get line-height of a font face for vertical centring
-- ---------------------------------------------------------------------------
function ZenTocWidget:_textH(face_name, size)
    local tw = TextWidget:new{ text = "Wg", face = Font:getFace(face_name, size), padding = 0 }
    local h  = tw:getSize().h
    tw:free()
    return h
end

-- ---------------------------------------------------------------------------
-- Gesture handlers
-- ---------------------------------------------------------------------------
function ZenTocWidget:_flashHeader(close_all)
    local L = self._L
    local region = Geom:new{
        x = close_all and TitleStyle.getTrailingIconX(L.modal_w, L.modal_x)
            or TitleStyle.getLeadingIconX(L.modal_x),
        y = L.modal_y + TitleStyle.VERTICAL_PADDING
            + math.floor((TitleStyle.ROW_HEIGHT - TitleStyle.ICON_SIZE) / 2),
        w = TitleStyle.ICON_SIZE, h = TitleStyle.ICON_SIZE,
    }
    if not close_all and self._title_hit then region = region:combine(self._title_hit) end
    require("common/ui/button_feedback").flashButton(region)
end

function ZenTocWidget:_onTap(ges)
    local p = ges.pos
    local L = self._L

    -- Tap on back button hit zone (top-left of title bar)
    if p.x >= L.back_x and p.x < L.back_x + L.back_w
    and p.y >= L.back_y and p.y < L.back_y + L.back_h then
        self:_flashHeader(false)
        self:onClose()
        return true
    end

    local title_hit = self._title_hit
    if title_hit and p.x >= title_hit.x and p.x < title_hit.x + title_hit.w
            and p.y >= title_hit.y and p.y < title_hit.y + title_hit.h then
        self:_flashHeader(false)
        return self:onClose()
    end

    if p.x >= L.close_all_x and p.x < L.close_all_x + L.close_all_w
            and p.y >= L.modal_y and p.y < L.modal_y + L.title_h then
        self:_flashHeader(true)
        return self:onCloseAll()
    end

    -- Tap on the page_number footer chevrons; center label is display-only.
    local zone = self:_footerZone(p, true)
    pager.flashChevron(zone, L.modal_x + L.bar_x, L.bar_y, L.bar_w, L.scrollbar_h)
    if zone == "left" then
        self:_gotoTocPage((self._toc_page or 1) - 1)
        return true
    elseif zone == "right" then
        self:_gotoTocPage((self._toc_page or 1) + 1)
        return true
    elseif zone == "center" then
        return true
    end

    -- Tap on an entry row
    if p.y >= L.list_y and p.y < L.list_y + L.list_h then
        local row_idx   = math.floor((p.y - L.list_y) / L.row_h)
        local entry_idx = (self._toc_page - 1) * L.per_page + row_idx + 1
        if entry_idx >= 1 and entry_idx <= #self._entries then
            local entry = self._entries[entry_idx]
            local page  = entry.page
            self:onClose()
            if self.on_goto then
                self.on_goto(page)
            end
            return true
        end
    end

    return true
end

-- Hold on a page_number footer chevron → skip back / forward (or to ends).
function ZenTocWidget:_onHold(ges)
    local zone = self:_footerZone(ges.pos, false)
    if zone == "center" then return true end
    if not zone then return false end
    local skip = pager.getHoldSkip()
    local page = self._toc_page or 1
    if zone == "left" then
        local target = skip == "ends" and 1 or (page - (tonumber(skip) or 10))
        self:_gotoTocPage(target)
    else -- right
        local target = skip == "ends" and self._nb_pages or (page + (tonumber(skip) or 10))
        self:_gotoTocPage(target)
    end
    return true
end

function ZenTocWidget:_onSwipe(ges)
    local L = self._L

    -- Top 14% south swipe → open reader menu
    if ges.direction == "south" and ges.pos.y < Device.screen:getHeight() * 0.14 then
        local ok_rui, RUI = pcall(require, "apps/reader/readerui")
        if ok_rui and RUI and RUI.instance then
            local reader_menu = RUI.instance.menu
            if reader_menu and reader_menu.activation_menu ~= "tap" then
                reader_menu:onShowMenu(reader_menu:_getTabIndexFromLocation(ges))
                return true
            end
        end
    end

    -- East/west: internal TOC page navigation.
    if ges.direction == "west" and self._toc_page < self._nb_pages then
        self._toc_page = self._toc_page + 1
        UIManager:setDirty(self, function()
            return "ui", Geom:new{
                x = L.modal_x, y = L.modal_y, w = L.modal_w, h = L.modal_h,
            }
        end)
        return true
    elseif ges.direction == "east" and self._toc_page > 1 then
        self._toc_page = self._toc_page - 1
        UIManager:setDirty(self, function()
            return "ui", Geom:new{
                x = L.modal_x, y = L.modal_y, w = L.modal_w, h = L.modal_h,
            }
        end)
        return true
    end

    -- Swallow all other swipes to prevent the underlying page browser from turning pages.
    return true
end

function ZenTocWidget:onClose()
    UIManager:close(self)
    return true
end

function ZenTocWidget:onCloseAll()
    self:onClose()
    if self.close_all_callback then self.close_all_callback() end
    return true
end

function ZenTocWidget:onShow()
    UIManager:setDirty(self, function()
        return "partial", self.dimen
    end)
end

function ZenTocWidget.set_plugin(p)
    pager.setPlugin(p)
end

return ZenTocWidget
