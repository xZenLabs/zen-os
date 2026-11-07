-- common/ui/wrapped_screen.lua
-- Paged ZenScreen for the yearly Reading Wrapped recap: one large icon or cover,
-- one stat, a label, a quip, dot indicators, Back/Next buttons.
--
-- Usage:
--   UIManager:show(WrappedScreen:new{
--       pages    = { { icon = "/abs/flame.svg", stat = "12", stat_label = "day streak", description = "..." }, ... },
--       on_close = function() ... end,
--   })
-- Pages may carry `image_bb` (a cover blitbuffer, freed on close) instead of `icon`.

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

local WrappedScreen = ZenScreen:extend{
    pages       = nil,
    title_icon  = true,
    hide_logo   = true,
    dismissable = true,  -- Back/Home keys close; taps and swipes only navigate
}

function WrappedScreen:init()
    self.title = self.title or _("Reading Wrapped")
    self.pages = self.pages or {}
    self._page_idx = 1
    self:_syncButtons()
    ZenScreen.init(self)
    local n = math.max(1, #self.pages)
    self._dot_r   = Screen:scaleBySize(5)
    self._dot_gap = Screen:scaleBySize(14)
    self._dot_h   = Screen:scaleBySize(36)
    self._dot_w   = n * self._dot_r * 2 + (n - 1) * self._dot_gap
end

function WrappedScreen:_syncButtons()
    self.later_button = self._page_idx > 1 and _("Back") or nil
    self.button = self._page_idx >= #self.pages and _("Done") or _("Next")
end

function WrappedScreen:setPage(n)
    if n < 1 or n > #self.pages then return end
    self._page_idx = n
    self:_syncButtons()
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

-- Measures the stat at decreasing sizes until it fits; caller frees the widget.
local function fitStat(text, avail_w)
    local size, widget = STAT_FONT_MAX, nil
    while true do
        widget = TextWidget:new{
            text      = text,
            face      = Font:getFace("cfont", size),
            bold      = true,
            padding   = 0,
            max_width = avail_w,
        }
        if widget:getSize().w <= avail_w or size <= STAT_FONT_MIN then return widget end
        widget:free()
        size = size - STAT_FONT_STEP
    end
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

    -- Text is measured first; the icon or cover takes whatever height is left.
    local widgets, text_h = {}, 0
    local function measure(widget)
        widgets[#widgets + 1] = widget
        text_h = text_h + widget:getSize().h + GAP
    end
    if page.stat then measure(fitStat(page.stat, avail_w)) end
    if page.stat_label then
        measure(TextBoxWidget:new{
            text      = page.stat_label,
            face      = Font:getFace("cfont", 22),
            fgcolor   = Blitbuffer.COLOR_DARK_GRAY,
            width     = avail_w,
            alignment = "center",
        })
    end
    if page.description then
        measure(TextBoxWidget:new{
            text      = page.description,
            face      = Font:getFace("cfont", 20),
            width     = avail_w,
            alignment = "center",
        })
    end

    local has_visual = (page.image_bb and ok_iw) or (page.icon and ok_ico)
    local visual_h = has_visual and math.max(0, band_h - text_h - GAP) or 0
    local total_h  = text_h + (has_visual and visual_h + GAP or 0)
    local cur_y    = band_y + math.max(0, math.floor((band_h - total_h) / 2))

    if visual_h > 0 then
        pcall(function()
            local widget
            if page.image_bb and ok_iw then
                widget = ImageWidget:new{
                    image            = page.image_bb,
                    width            = avail_w,
                    height           = visual_h,
                    scale_factor     = 0,
                    image_disposable = false,
                }
            else
                local size = math.min(visual_h, math.floor(avail_w * 0.6))
                widget = IconWidget:new{ icon = page.icon, width = size, height = size, alpha = true }
            end
            local sz = widget:getSize()
            widget:paintTo(bb, x + math.floor((L.sw - sz.w) / 2), cur_y + math.floor((visual_h - sz.h) / 2))
            widget:free()
        end)
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
    for _i, page in ipairs(self.pages) do
        if page.image_bb then
            page.image_bb:free()
            page.image_bb = nil
        end
    end
    package.loaded["common/ui/wrapped_screen"] = nil
    package.loaded["common/reading_wrapped"] = nil
    ZenScreen.onClose(self)
end

return WrappedScreen
