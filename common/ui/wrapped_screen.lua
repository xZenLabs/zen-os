-- common/ui/wrapped_screen.lua
-- Paged ZenScreen for the yearly Reading Wrapped recap: no title bar; each slide stacks
-- a cover layout or icon, its heading, one stat, a label and a quip, then dot
-- indicators and Back/Next buttons.
--
-- Usage:
--   UIManager:show(WrappedScreen:new{
--       pages = { { title = "Longest streak", icon = "/abs/flame.svg", stat = "12",
--                   stat_label = "days", description = "..." }, ... },
--       covers_owned = { bb, ... },  -- freed on close
--       rounded_covers = true,
--       on_close = function() ... end,
--   })
-- A page shows `covers = { { bb, w, h }, ... }` with `layout = "single" | "grid" | "flow"`
-- instead of `icon`; `stat_text = true` sizes a text stat (book, author) like the heading
-- and wraps it when still too wide; `unit` joins the stat on one line ("12h spent reading")
-- when it fits and drops below it otherwise.

local Blitbuffer    = require("ffi/blitbuffer")
local Device        = require("device")
local Font          = require("ui/font")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget    = require("ui/widget/textwidget")
local UIManager     = require("ui/uimanager")
local ZenScreen     = require("common/ui/zen_screen")
local Screen        = Device.screen
local _             = require("gettext")

local ok_iw, ImageWidget = pcall(require, "ui/widget/imagewidget")
local ok_ico, IconWidget = pcall(require, "ui/widget/iconwidget")

local STAT_FONT_MAX, STAT_FONT_MIN, STAT_FONT_STEP = 64, 24, 4
local TITLE_SIZE = 36        -- slide heading and text stats
local LABEL_SIZE = 22        -- units and subtitles
local ICON_SHARE = 0.35      -- icon width as a share of the content width
local FLOW_SIDE_SCALE = 0.78 -- side covers in a coverflow relative to the centre one

local WrappedScreen = ZenScreen:extend{
    pages          = nil,
    covers_owned   = nil,
    rounded_covers = false,
    hide_logo      = true,
    dismissable    = true,  -- Back/Home keys close; taps and swipes only navigate
}

function WrappedScreen:init()
    self.pages = self.pages or {}
    self._page_idx = 1
    self:_syncPage()
    ZenScreen.init(self)
    local n = math.max(1, #self.pages)
    self._dot_r   = Screen:scaleBySize(5)
    self._dot_gap = Screen:scaleBySize(14)
    self._dot_h   = Screen:scaleBySize(36)
    self._dot_w   = n * self._dot_r * 2 + (n - 1) * self._dot_gap
end

function WrappedScreen:_syncPage()
    self.later_button = self._page_idx > 1 and _("Back") or nil
    self.button = self._page_idx >= #self.pages and _("Done") or _("Next")
end

function WrappedScreen:setPage(n)
    if n < 1 or n > #self.pages then return end
    self._page_idx = n
    self:_syncPage()
    self:_normalizeButtonFocus()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

local function flash(rect)
    require("common/ui/button_feedback").flashButton(rect)
end

-- Back steps back, Next advances, Done (last page) closes.
function WrappedScreen:_activateButton(button)
    if button == "later" and self.later_button then
        flash(self._later_btn_rect)
        self:setPage(self._page_idx - 1)
    elseif button == "primary" then
        flash(self._btn_rect)
        if self._page_idx >= #self.pages then
            self:onClose()
        else
            self:setPage(self._page_idx + 1)
        end
    end
    return true
end

-- Shrinks the stat until it fits on one line; wraps at the minimum size when it still
-- does not. Caller frees the widget.
local function fitStat(text, avail_w, max_size)
    local size = math.min(STAT_FONT_MAX, max_size or STAT_FONT_MAX)
    while true do
        local widget = TextWidget:new{
            text    = text,
            face    = Font:getFace("cfont", size),
            bold    = true,
            padding = 0,
        }
        if widget:getSize().w <= avail_w then return widget end
        widget:free()
        if size <= STAT_FONT_MIN then break end
        size = math.max(STAT_FONT_MIN, size - STAT_FONT_STEP)
    end
    return TextBoxWidget:new{
        text      = text,
        face      = Font:getFace("cfont", STAT_FONT_MIN),
        bold      = true,
        width     = avail_w,
        alignment = "center",
    }
end

local function baseline(widget)
    local ok, value = pcall(function() return widget:getBaseline() end)
    return ok and tonumber(value) or widget:getSize().h
end

-- "<stat> <unit>" on one line, baselines aligned, when the stat fits beside the unit at
-- some size; nil otherwise. Caller frees the returned widget.
local function inlineStat(stat, unit, avail_w)
    local unit_w = TextWidget:new{ text = unit, face = Font:getFace("cfont", LABEL_SIZE), padding = 0 }
    local gap = Screen:scaleBySize(8)
    local room = avail_w - unit_w:getSize().w - gap
    local size = STAT_FONT_MAX
    while size >= STAT_FONT_MIN do
        local stat_w = TextWidget:new{ text = stat, face = Font:getFace("cfont", size), bold = true, padding = 0 }
        local ss, us = stat_w:getSize(), unit_w:getSize()
        if ss.w <= room then
            local sb, ub = baseline(stat_w), baseline(unit_w)
            local top = math.max(sb, ub)
            local h = top + math.max(ss.h - sb, us.h - ub)
            return {
                getSize = function() return { w = ss.w + gap + us.w, h = h } end,
                paintTo = function(_self, bb, x, y)
                    stat_w:paintTo(bb, x, y + top - sb)
                    unit_w:paintTo(bb, x + ss.w + gap, y + top - ub)
                end,
                free = function() stat_w:free(); unit_w:free() end,
            }
        end
        stat_w:free()
        size = size - STAT_FONT_STEP
    end
    unit_w:free()
    return nil
end

-- White corner cut-outs; the screen background is plain white.
local function roundCorners(bb, x, y, w, h)
    local r = math.min(Screen:scaleBySize(8), math.floor((math.min(w, h) - 1) / 2))
    if r < 2 then return end
    for j = 0, r - 1 do
        local cut = math.ceil(r - math.sqrt(r * r - (r - j) * (r - j)))
        if cut > 0 then
            bb:paintRect(x, y + j, cut, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x + w - cut, y + j, cut, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x, y + h - 1 - j, cut, 1, Blitbuffer.COLOR_WHITE)
            bb:paintRect(x + w - cut, y + h - 1 - j, cut, 1, Blitbuffer.COLOR_WHITE)
        end
    end
end

-- Scales a cover into max_w x max_h keeping its aspect ratio.
local function fitCover(cover, max_w, max_h)
    local w, h = cover.w or 2, cover.h or 3
    local scale = math.min(max_w / w, max_h / h)
    return math.max(1, math.floor(w * scale)), math.max(1, math.floor(h * scale))
end

-- Paints one cover centred in the given box; `outline` separates overlapping covers.
function WrappedScreen:_paintCover(bb, cover, box_x, box_y, box_w, box_h, outline)
    if not ok_iw then return end
    local w, h = fitCover(cover, box_w, box_h)
    local x = box_x + math.floor((box_w - w) / 2)
    local y = box_y + math.floor((box_h - h) / 2)
    if outline then
        local o = Screen:scaleBySize(3)
        bb:paintRect(x - o, y - o, w + o * 2, h + o * 2, Blitbuffer.COLOR_WHITE)
    end
    pcall(function()
        local widget = ImageWidget:new{
            image            = cover.bb,
            width            = w,
            height           = h,
            scale_factor     = 0,
            image_disposable = false,
        }
        widget:paintTo(bb, x, y)
        widget:free()
    end)
    if self.rounded_covers then roundCorners(bb, x, y, w, h) end
end

-- Covers side by side (up to 3 per row, 2 rows); one or two covers fill the band.
function WrappedScreen:_paintGrid(bb, covers, x, y, avail_w, avail_h)
    local n = #covers
    local cols = math.min(3, n)
    local rows = math.ceil(n / cols)
    local gap = Screen:scaleBySize(12)
    local cell_w = math.floor((avail_w - gap * (cols - 1)) / cols)
    local cell_h = math.floor((avail_h - gap * (rows - 1)) / rows)
    for i, cover in ipairs(covers) do
        local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
        -- Centre a short last row.
        local in_row = math.min(cols, n - row * cols)
        local row_x = x + math.floor((avail_w - in_row * cell_w - (in_row - 1) * gap) / 2)
        self:_paintCover(bb, cover, row_x + col * (cell_w + gap), y + row * (cell_h + gap), cell_w, cell_h)
    end
end

-- Centre cover in front, side covers smaller and tucked behind it.
function WrappedScreen:_paintFlow(bb, covers, x, y, avail_w, avail_h)
    if #covers < 3 then return self:_paintGrid(bb, covers, x, y, avail_w, avail_h) end
    local centre, left, right = covers[1], covers[2], covers[3]
    local cw, ch = fitCover(centre, avail_w, avail_h)
    local sw = 0
    for _i, side in ipairs({ left, right }) do
        sw = math.max(sw, (fitCover(side, avail_w, math.floor(avail_h * FLOW_SIDE_SCALE))))
    end
    -- Side covers peek out by 60% of their width; shrink everything if that overflows.
    local total = cw + sw * 1.2
    if total > avail_w then
        local scale = avail_w / total
        cw, ch, sw = math.floor(cw * scale), math.floor(ch * scale), math.floor(sw * scale)
    end
    local sh = math.floor(avail_h * FLOW_SIDE_SCALE)
    local cx = x + math.floor((avail_w - cw) / 2)
    local cy = y + math.floor((avail_h - ch) / 2)
    local side_y = y + math.floor((avail_h - sh) / 2)
    self:_paintCover(bb, left, cx - math.floor(sw * 0.6), side_y, sw, sh)
    self:_paintCover(bb, right, cx + cw - math.floor(sw * 0.4), side_y, sw, sh)
    self:_paintCover(bb, centre, cx, cy, cw, ch, true)
end

function WrappedScreen:paintTo(bb, x, y)
    local L = self._L
    local page = self.pages[self._page_idx] or {}
    bb:paintRect(x, y, L.sw, L.sh, Blitbuffer.COLOR_WHITE)
    self:_paintTitleBar(bb, x, y)

    local GAP     = Screen:scaleBySize(10)
    local avail_w = L.sw - L.pad * 2
    local band_y  = y + L.content_y + L.pad
    local band_h  = L.content_h - self._dot_h - L.pad * 2

    -- Text (heading, stat, label, quip) is measured first; the covers or icon above
    -- it take whatever height is left.
    local widgets, text_h = {}, 0
    local function measure(widget)
        widgets[#widgets + 1] = widget
        text_h = text_h + widget:getSize().h + GAP
    end
    local function label(text)
        measure(TextBoxWidget:new{
            text      = text,
            face      = Font:getFace("cfont", LABEL_SIZE),
            width     = avail_w,
            alignment = "center",
        })
    end
    if page.title then
        measure(TextBoxWidget:new{
            text      = page.title,
            face      = Font:getFace("cfont", TITLE_SIZE),
            bold      = true,
            width     = avail_w,
            alignment = "center",
        })
    end
    if page.stat then
        local line = page.unit and inlineStat(page.stat, page.unit, avail_w)
        measure(line or fitStat(page.stat, avail_w, page.stat_text and TITLE_SIZE or nil))
        if page.unit and not line then label(page.unit) end
    end
    if page.stat_label then label(page.stat_label) end
    if page.description then
        measure(TextBoxWidget:new{
            text      = page.description,
            face      = Font:getFace("cfont", 20),
            width     = avail_w,
            alignment = "center",
        })
    end

    local covers = page.covers and #page.covers > 0 and ok_iw and page.covers or nil
    local has_visual = covers or (page.icon and ok_ico)
    local visual_h = has_visual and math.max(0, band_h - text_h - GAP) or 0
    local total_h  = text_h + (has_visual and visual_h + GAP or 0)
    local cur_y    = band_y + math.max(0, math.floor((band_h - total_h) / 2))

    if visual_h > 0 then
        if covers then
            local layout = #covers == 1 and "single" or page.layout
            if layout == "flow" then
                self:_paintFlow(bb, covers, x + L.pad, cur_y, avail_w, visual_h)
            elseif layout == "grid" or #covers > 1 then
                self:_paintGrid(bb, covers, x + L.pad, cur_y, avail_w, visual_h)
            else
                self:_paintCover(bb, covers[1], x + L.pad, cur_y, avail_w, visual_h)
            end
        else
            pcall(function()
                local size = math.min(visual_h, math.floor(avail_w * ICON_SHARE))
                local widget = IconWidget:new{ icon = page.icon, width = size, height = size, alpha = true }
                local sz = widget:getSize()
                widget:paintTo(bb, x + math.floor((L.sw - sz.w) / 2), cur_y + math.floor((visual_h - sz.h) / 2))
                widget:free()
            end)
        end
        cur_y = cur_y + visual_h + GAP
    end

    for _i, widget in ipairs(widgets) do
        local sz = widget:getSize()
        widget:paintTo(bb, x + math.floor((L.sw - sz.w) / 2), cur_y)
        widget:free()
        cur_y = cur_y + sz.h + GAP
    end

    -- Dot indicators
    local dot_y  = y + L.content_y + L.content_h - self._dot_h
    local dot_x  = x + math.floor((L.sw - self._dot_w) / 2)
    local dot_cy = dot_y + math.floor(self._dot_h / 2)
    self._dot_rect = {
        x = dot_x - math.floor(self._dot_gap / 2), y = dot_y,
        w = self._dot_w + self._dot_gap, h = self._dot_h,
    }
    for i = 1, #self.pages do
        local cx = dot_x + (i - 1) * (self._dot_r * 2 + self._dot_gap) + self._dot_r
        local color = i == self._page_idx and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY
        for row = -self._dot_r, self._dot_r do
            local half = math.floor(math.sqrt(self._dot_r * self._dot_r - row * row) + 0.5)
            if half > 0 then bb:paintRect(cx - half, dot_cy + row, half * 2, 1, color) end
        end
    end

    self:_paintButtons(bb, x, y)
end

function WrappedScreen:_onSwipe(ges)
    if ges.direction == "west" then
        self:setPage(self._page_idx + 1)
    elseif ges.direction == "east" then
        self:setPage(self._page_idx - 1)
    end
    return true
end

function WrappedScreen:_onTap(ges)
    local p = ges.pos
    if self:_point_in_rect(p, self._later_btn_rect) then return self:_activateButton("later") end
    if self:_point_in_rect(p, self._btn_rect) then return self:_activateButton("primary") end
    if self:_point_in_rect(p, self._dot_rect) then
        local idx = math.floor((p.x - self._dot_rect.x) / (self._dot_r * 2 + self._dot_gap)) + 1
        self:setPage(idx)
    end
    return true
end

-- Page-back key steps back instead of dismissing.
function WrappedScreen:onZsDismiss()
    self:setPage(self._page_idx - 1)
    return true
end

function WrappedScreen:onClose()
    for _i, bb in ipairs(self.covers_owned or {}) do bb:free() end
    self.covers_owned = nil
    for _i, page in ipairs(self.pages) do page.covers = nil end
    package.loaded["common/ui/wrapped_screen"] = nil
    package.loaded["common/reading_wrapped"] = nil
    ZenScreen.onClose(self)
end

return WrappedScreen
