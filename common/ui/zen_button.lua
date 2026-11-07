-- common/zen_button.lua
-- Stateless helpers for painting filled and outlined rounded-rect buttons.
-- Each function paints to an existing blitbuffer and returns a hit-rect table.

local Blitbuffer = require("ffi/blitbuffer")
local Accent     = require("common/ui/accent")
local Device     = require("device")
local Font       = require("ui/font")
local TextWidget = require("ui/widget/textwidget")
local Screen     = Device.screen

local function paintRoundedRect(bb, rx, ry, rw, rh, color, radius, bg_color)
    local paint = Blitbuffer.isColor8(color) and bb.paintRect or bb.paintRectRGB32
    paint(bb, rx, ry, rw, rh, color)
    local r = radius
    for dy = 0, r - 1 do
        local t   = r - dy
        local cut = math.ceil(r - math.sqrt(math.max(0, r * r - t * t)))
        if cut > 0 then
            bb:paintRect(rx,            ry + dy,          cut, 1, bg_color)
            bb:paintRect(rx + rw - cut, ry + dy,          cut, 1, bg_color)
            bb:paintRect(rx,            ry + rh - 1 - dy, cut, 1, bg_color)
            bb:paintRect(rx + rw - cut, ry + rh - 1 - dy, cut, 1, bg_color)
        end
    end
end

-- Per-row ring computation avoids corner gaps that the double-fill approach
-- produces (inner white fill overwrites border pixels in corner regions).
local function paintRoundedRectBorder(bb, rx, ry, rw, rh, color, radius, bg_color, border_w)
    local paint = Blitbuffer.isColor8(color) and bb.paintRect or bb.paintRectRGB32
    local R  = radius
    local bw = border_w
    local r2 = math.max(0, R - bw)
    if rw > R * 2 then
        paint(bb, rx + R,       ry,           rw - R * 2, bw, color)
        paint(bb, rx + R,       ry + rh - bw, rw - R * 2, bw, color)
    end
    if rh > R * 2 then
        paint(bb, rx,           ry + R,       bw, rh - R * 2, color)
        paint(bb, rx + rw - bw, ry + R,       bw, rh - R * 2, color)
    end
    for dy = 0, R - 1 do
        local T         = R - dy
        local outer_cut = math.ceil(R - math.sqrt(math.max(0, R * R - T * T)))
        if outer_cut > 0 then
            bb:paintRect(rx,                  ry + dy,          outer_cut, 1, bg_color)
            bb:paintRect(rx + rw - outer_cut, ry + dy,          outer_cut, 1, bg_color)
            bb:paintRect(rx,                  ry + rh - 1 - dy, outer_cut, 1, bg_color)
            bb:paintRect(rx + rw - outer_cut, ry + rh - 1 - dy, outer_cut, 1, bg_color)
        end
        local inner_cut
        local dy2 = dy - bw
        if dy2 < 0 or r2 == 0 then
            inner_cut = R
        else
            local T2 = r2 - dy2
            inner_cut = bw + math.ceil(r2 - math.sqrt(math.max(0, r2 * r2 - T2 * T2)))
            inner_cut = math.min(inner_cut, R)
        end
        local bpx = inner_cut - outer_cut
        if bpx > 0 then
            paint(bb, rx + outer_cut,      ry + dy,          bpx, 1, color)
            paint(bb, rx + rw - inner_cut, ry + dy,          bpx, 1, color)
            paint(bb, rx + outer_cut,      ry + rh - 1 - dy, bpx, 1, color)
            paint(bb, rx + rw - inner_cut, ry + rh - 1 - dy, bpx, 1, color)
        end
    end
end

local M = {}

--- Paint a filled rounded-rect button with a centered bold label.
--- Returns { x, y, w, h } for hit-testing.
function M.paintFilled(bb, bx, by, bw, bh, label, font_size, corner_r, max_text_width)
    corner_r  = corner_r  or Screen:scaleBySize(10)
    font_size = font_size or 22
    paintRoundedRect(bb, bx, by, bw, bh, Accent.color(), corner_r, Blitbuffer.COLOR_WHITE)
    local tw = TextWidget:new{
        text    = label,
        face    = Font:getFace("cfont", font_size),
        bold    = true,
        fgcolor = Accent.foreground(),
        max_width = max_text_width,
        padding = 0,
    }
    local tsz = tw:getSize()
    tw:paintTo(bb,
        bx + math.floor((bw - tsz.w) / 2),
        by + math.floor((bh - tsz.h) / 2))
    tw:free()
    return { x = bx, y = by, w = bw, h = bh }
end

--- Paint an outlined rounded-rect button with an accent border and black bold label.
--- Returns { x, y, w, h } for hit-testing.
function M.paintOutlined(bb, bx, by, bw, bh, label, font_size, corner_r, border_w,
        max_text_width)
    corner_r  = corner_r  or Screen:scaleBySize(10)
    border_w  = border_w  or Screen:scaleBySize(2)
    font_size = font_size or 22
    local color = Accent.color()
    paintRoundedRectBorder(bb, bx, by, bw, bh,
        color, corner_r, Blitbuffer.COLOR_WHITE, border_w)
    local tw = TextWidget:new{
        text    = label,
        face    = Font:getFace("cfont", font_size),
        bold    = true,
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = max_text_width,
        padding = 0,
    }
    local tsz = tw:getSize()
    tw:paintTo(bb,
        bx + math.floor((bw - tsz.w) / 2),
        by + math.floor((bh - tsz.h) / 2))
    tw:free()
    return { x = bx, y = by, w = bw, h = bh }
end

return M
