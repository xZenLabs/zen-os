-- common/ui/wrapped_screen.lua
-- Paged ZenScreen for the yearly Reading Wrapped recap: no title bar; each slide stacks
-- a cover layout or icon and a white card with its heading, one stat, a label and a quip
-- over a decorative backdrop, then dot indicators and Back/Next buttons. The visual band
-- and the card keep one size and place on every slide, sized for the tallest text.
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
-- instead of `icon`.

local Blitbuffer    = require("ffi/blitbuffer")
local Device        = require("device")
local Font          = require("ui/font")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget    = require("ui/widget/textwidget")
local UIManager     = require("ui/uimanager")
local Backdrops     = require("common/ui/wrapped_backdrops")
local getFullRefreshMode = require("common/ui/refresh")
local ZenScreen     = require("common/ui/zen_screen")
local Screen        = Device.screen
local _             = require("gettext")

local ok_iw, ImageWidget = pcall(require, "ui/widget/imagewidget")
local ok_ico, IconWidget = pcall(require, "ui/widget/iconwidget")

local STAT_SIZE  = 48        -- every stat, number or name
local STAT_MAX_LINES = 2     -- longer names end in an ellipsis
local TITLE_SIZE = 36        -- slide heading
local LABEL_SIZE = 22        -- line under the stat
local QUIP_SIZE  = 20
local TEXT_GAP   = 10        -- between text lines, and between the visual and the card
local TEXT_MAX_SHARE = 0.5   -- most of the band the card may reserve
local ICON_SHARE = 0.35      -- icon width as a share of the content width
local FLOW_SIDE_SCALE = 0.78 -- side covers in a coverflow relative to the centre one
local CARD_PAD = 18          -- text card inner padding
local CARD_RADIUS = 14
local CARD_OPACITY = 0.75    -- white blended over the backdrop, leaving a hint of it

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
    local n = math.max(1, #self.pages)
    self._dot_r   = Screen:scaleBySize(5)
    self._dot_gap = Screen:scaleBySize(14)
    self._dot_h   = Screen:scaleBySize(36)
    self._dot_w   = n * self._dot_r * 2 + (n - 1) * self._dot_gap
    ZenScreen.init(self)
end

function WrappedScreen:_syncPage()
    self.later_button = self._page_idx > 1 and _("Back") or nil
    self.button = self._page_idx >= #self.pages and _("Done") or _("Next")
end

local function hasCovers(page)
    return page and page.covers and #page.covers > 0
end

function WrappedScreen:setPage(n)
    if n < 1 or n > #self.pages then return end
    -- Covers ghost on e-ink: flash when a slide with covers comes or goes.
    local clear = hasCovers(self.pages[self._page_idx]) or hasCovers(self.pages[n])
    self._page_idx = n
    self:_syncPage()
    self:_normalizeButtonFocus()
    UIManager:setDirty(self, function() return clear and getFullRefreshMode() or "ui", self.dimen end)
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

local function textLine(text, size, bold)
    return TextWidget:new{ text = text, face = Font:getFace("cfont", size), bold = bold, padding = 0 }
end

-- One line when the text fits, wrapped and centred otherwise, ending in an ellipsis past
-- `max_lines` when given. Caller frees the widget.
local function fitText(text, size, avail_w, bold, max_lines)
    local line = textLine(text, size, bold)
    if line:getSize().w <= avail_w then return line end
    line:free()
    local height
    local function box(fgcolor, bgcolor)
        return TextBoxWidget:new{
            text = text, face = Font:getFace("cfont", size), bold = bold, width = avail_w,
            alignment = "center", fgcolor = fgcolor, bgcolor = bgcolor,
            height = height, height_overflow_show_ellipsis = height ~= nil,
        }
    end
    -- TextBoxWidget blits an opaque box; rendered white on black its buffer is an alpha
    -- mask that blends over the card instead. Plain box when that buffer is not there.
    local widget = box(Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK)
    local ok, line_h = pcall(function() return widget:getLineHeight() end)
    if max_lines and ok and widget:getSize().h > max_lines * line_h then
        widget:free()
        height = max_lines * line_h
        widget = box(Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK)
    end
    local mask = widget._bb
    if not (mask and mask.getType and mask:getType() == Blitbuffer.TYPE_BB8) then
        widget:free()
        return box()
    end
    function widget:paintTo(bb, x, y)
        bb:colorblitFrom(mask, x, y, 0, 0, mask:getWidth(), mask:getHeight(), Blitbuffer.COLOR_BLACK)
    end
    return widget
end

-- A page's heading, stat, label and quip widgets and their stacked height. Caller frees
-- the widgets.
local function textWidgets(page, text_w)
    local widgets, text_h = {}, 0
    local gap = Screen:scaleBySize(TEXT_GAP)
    local function add(widget)
        widgets[#widgets + 1] = widget
        text_h = text_h + widget:getSize().h + (#widgets > 1 and gap or 0)
    end
    if page.title then add(fitText(page.title, TITLE_SIZE, text_w, true)) end
    if page.stat then add(fitText(page.stat, STAT_SIZE, text_w, true, STAT_MAX_LINES)) end
    if page.stat_label then add(fitText(page.stat_label, LABEL_SIZE, text_w)) end
    if page.description then add(fitText(page.description, QUIP_SIZE, text_w)) end
    return widgets, text_h
end

-- Every slide reserves the tallest slide's text height (capped), so the card and the
-- covers or icon above it never change size or place.
function WrappedScreen:_computeLayout()
    ZenScreen._computeLayout(self)
    local L = self._L
    L.band_h = L.content_h - self._dot_h - L.pad * 2
    L.text_w = L.sw - (L.pad + Screen:scaleBySize(CARD_PAD)) * 2
    local tallest = 0
    for _i, page in ipairs(self.pages) do
        local widgets, text_h = textWidgets(page, L.text_w)
        tallest = math.max(tallest, text_h)
        for _j, widget in ipairs(widgets) do widget:free() end
    end
    L.text_h = math.min(tallest, math.floor(L.band_h * TEXT_MAX_SHARE))
end

-- Pixels a corner of radius r cuts off each end of row j (0 at the rect's edge).
local function cornerCut(r, j)
    return math.ceil(r - math.sqrt(r * r - (r - j) * (r - j)))
end

-- Frosted rounded panel: blends white over the backdrop so a hint of it stays visible.
local function paintCard(bb, x, y, w, h)
    local r = Screen:scaleBySize(CARD_RADIUS)
    bb:lightenRect(x, y + r, w, h - r * 2, CARD_OPACITY)
    for j = 0, r - 1 do
        local cut = cornerCut(r, j)
        bb:lightenRect(x + cut, y + j, w - cut * 2, 1, CARD_OPACITY)
        bb:lightenRect(x + cut, y + h - 1 - j, w - cut * 2, 1, CARD_OPACITY)
    end
    bb:paintBorder(x, y, w, h, Screen:scaleBySize(1), Blitbuffer.COLOR_BLACK, r)
end

-- Runs paint() over a rect and, when `round` is set, rounds its corners on any backdrop
-- by putting back the pixels that were under the cut-outs.
local function paintRounded(bb, round, x, y, w, h, paint)
    local r = round and math.min(Screen:scaleBySize(8), math.floor((math.min(w, h) - 1) / 2)) or 0
    if r < 2 then return paint() end
    local saved = Blitbuffer.new(r * 2, r * 2, bb:getType())
    saved:blitFrom(bb, 0, 0, x, y, r, r)
    saved:blitFrom(bb, r, 0, x + w - r, y, r, r)
    saved:blitFrom(bb, 0, r, x, y + h - r, r, r)
    saved:blitFrom(bb, r, r, x + w - r, y + h - r, r, r)
    paint()
    for j = 0, r - 1 do
        local cut = cornerCut(r, j)
        if cut > 0 then
            local right, bottom = r * 2 - cut, r * 2 - 1 - j
            bb:blitFrom(saved, x, y + j, 0, j, cut, 1)
            bb:blitFrom(saved, x + w - cut, y + j, right, j, cut, 1)
            bb:blitFrom(saved, x, y + h - 1 - j, 0, bottom, cut, 1)
            bb:blitFrom(saved, x + w - cut, y + h - 1 - j, right, bottom, cut, 1)
        end
    end
    saved:free()
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
        paintRounded(bb, self.rounded_covers, x - o, y - o, w + o * 2, h + o * 2, function()
            bb:paintRect(x - o, y - o, w + o * 2, h + o * 2, Blitbuffer.COLOR_WHITE)
        end)
    end
    paintRounded(bb, self.rounded_covers, x, y, w, h, function()
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
    end)
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
    local gap      = Screen:scaleBySize(TEXT_GAP)
    local card_pad = Screen:scaleBySize(CARD_PAD)
    local avail_w  = L.sw - L.pad * 2
    local band_y   = y + L.content_y + L.pad

    -- Only text taller than the reserved height (past the cap) grows the card into the
    -- visual band above it.
    local widgets, text_h = textWidgets(page, L.text_w)
    local card_h   = math.max(L.text_h, text_h) + card_pad * 2
    local visual_h = math.max(0, L.band_h - card_h - gap)
    local covers   = page.covers and #page.covers > 0 and ok_iw and page.covers or nil
    local icon_sz  = not covers and math.min(visual_h, math.floor(avail_w * ICON_SHARE)) or 0
    local icon_x   = math.floor((L.sw - icon_sz) / 2)
    local icon_y   = band_y + math.floor((visual_h - icon_sz) / 2)

    -- The backdrop leaves the icon clear; dots and buttons keep a plain white footer.
    bb:paintRect(x, y, L.sw, L.sh, Blitbuffer.COLOR_WHITE)
    Backdrops.paint(bb, self._page_idx, #self.pages, x, y, L.sw, L.content_y + L.content_h - self._dot_h,
        icon_sz > 0 and { x = icon_x, y = icon_y - y, w = icon_sz, h = icon_sz } or nil)
    self:_paintTitleBar(bb, x, y)

    if covers then
        local layout = #covers == 1 and "single" or page.layout
        if layout == "flow" then
            self:_paintFlow(bb, covers, x + L.pad, band_y, avail_w, visual_h)
        elseif layout == "grid" or #covers > 1 then
            self:_paintGrid(bb, covers, x + L.pad, band_y, avail_w, visual_h)
        else
            self:_paintCover(bb, covers[1], x + L.pad, band_y, avail_w, visual_h)
        end
    elseif page.icon and ok_ico then
        pcall(function()
            local widget = IconWidget:new{ icon = page.icon, width = icon_sz, height = icon_sz, alpha = true }
            widget:paintTo(bb, x + icon_x, icon_y)
            widget:free()
        end)
    end

    -- The card keeps the text readable over the backdrop; the text sits centred in it.
    local card_y = band_y + visual_h + gap
    if #widgets > 0 then paintCard(bb, x + L.pad, card_y, avail_w, card_h) end
    local cur_y = card_y + math.floor((card_h - text_h) / 2)
    for _i, widget in ipairs(widgets) do
        local sz = widget:getSize()
        widget:paintTo(bb, x + math.floor((L.sw - sz.w) / 2), cur_y)
        widget:free()
        cur_y = cur_y + sz.h + gap
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
    package.loaded["common/ui/wrapped_backdrops"] = nil
    package.loaded["common/reading_wrapped"] = nil
    ZenScreen.onClose(self)
end

return WrappedScreen
