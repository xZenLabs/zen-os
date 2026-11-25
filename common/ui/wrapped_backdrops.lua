-- common/ui/wrapped_backdrops.lua
-- Decorative backdrops for the Reading Wrapped slides: flat light-gray shapes built from
-- clipped horizontal runs, so they need no dithering and stay cheap on e-ink.
--
-- Usage:
--   Backdrops.paint(bb, page_index, page_count, x, y, w, h, clear)
-- `clear` is an optional { x, y, w, h } box (relative to x, y) that confetti stays out of.
-- Every shape ends inside the box or bleeds off its top and sides, so nothing is cut
-- along the bottom edge. The first and last slides get confetti; the ones between cycle
-- through the rest, mirrored on every second pass, so neighbours never match.

local Blitbuffer = require("ffi/blitbuffer")
local Screen     = require("device").screen

local LIGHT, MID = Blitbuffer.COLOR_GRAY_E, Blitbuffer.COLOR_GRAY_D

local Canvas = {}
Canvas.__index = Canvas

-- Row segment [x0, x1) in canvas coordinates.
function Canvas:run(x0, x1, row, color)
    row = math.floor(row)
    if row < 0 or row >= self.h then return end
    if self.mirror then x0, x1 = self.w - x1, self.w - x0 end
    x0, x1 = math.max(0, math.floor(x0)), math.min(self.w, math.floor(x1))
    if x1 > x0 then self.bb:paintRect(self.x + x0, self.y + row, x1 - x0, 1, color) end
end

function Canvas:rect(x, y, w, h, color)
    for row = math.floor(y), math.floor(y + h) - 1 do self:run(x, x + w, row, color) end
end

-- Ring of outer radius r and thickness t; t >= r makes a disc.
function Canvas:ring(cx, cy, r, t, color)
    cy = math.floor(cy)
    local inner = math.max(0, r - t)
    for dy = math.max(-math.floor(r), -cy), math.min(math.floor(r), self.h - 1 - cy) do
        local outer_half = math.sqrt(r * r - dy * dy)
        local inner_half = math.abs(dy) < inner and math.sqrt(inner * inner - dy * dy) or 0
        self:run(cx - outer_half, cx - inner_half, cy + dy, color)
        self:run(cx + inner_half, cx + outer_half, cy + dy, color)
    end
end

function Canvas:disc(cx, cy, r, color)
    self:ring(cx, cy, r, r, color)
end

-- Rectangle of half-sizes a x b turned by `angle` about its centre; the angle must stay
-- off the axes.
function Canvas:slab(cx, cy, a, b, angle, color)
    local cos, sin = math.cos(angle), math.sin(angle)
    local reach = math.ceil(math.abs(a * sin) + math.abs(b * cos))
    for dy = -reach, reach do
        -- |dx cos + dy sin| <= a and |dy cos - dx sin| <= b
        local from_a, to_a = (-a - dy * sin) / cos, (a - dy * sin) / cos
        local from_b, to_b = (dy * cos - b) / sin, (dy * cos + b) / sin
        if from_b > to_b then from_b, to_b = to_b, from_b end
        self:run(cx + math.max(from_a, from_b), cx + math.min(to_a, to_b), cy + dy, color)
    end
end

-- Wavy ribbon centred on (cx, cy), leaning by `lean` px per row.
function Canvas:streamer(cx, cy, length, sway, thickness, lean, color)
    for t = -length / 2, length / 2 do
        local left = cx + t * lean + sway * math.sin(t / length * math.pi * 3)
        self:run(left, left + thickness, cy + t, color)
    end
end

-- True when a piece reaching `reach` px around (cx, cy) would touch the clear box.
function Canvas:blocked(cx, cy, reach)
    local box = self.clear
    return box and cx > box.x - reach and cx < box.x + box.w + reach
        and cy > box.y - reach and cy < box.y + box.h + reach
end

local PAINTERS = {}

function PAINTERS.orbs(c)
    local m = math.min(c.w, c.h)
    c:disc(c.w * 0.88, c.h * 0.14, m * 0.40, LIGHT)
    c:disc(c.w * 0.04, c.h * 0.66, m * 0.30, LIGHT)
    c:disc(c.w * 0.24, c.h * 0.10, m * 0.09, MID)
end

-- Bands parallel to the top-left to bottom-right diagonal, filling the corner above it.
function PAINTERS.stripes(c)
    local period, band = c.w * 0.22, c.w * 0.09
    for row = 0, c.h - 1 do
        for start = c.w * row / c.h, c.w, period do c:run(start, start + band, row, LIGHT) end
    end
end

function PAINTERS.rings(c)
    local step = math.min(c.w, c.h) * 0.16
    for i = 1, 6 do
        c:ring(c.w * 0.08, c.h * 0.02, step * i, step * 0.4, i % 2 == 0 and MID or LIGHT)
    end
end

-- Staggered dots that shrink away from the top-left corner.
function PAINTERS.halftone(c)
    local step = Screen:scaleBySize(30)
    for j = 0, math.floor(c.h / step) do
        for i = -1, math.floor(c.w / step) + 1 do
            local cx, cy = (i + (j % 2) * 0.5) * step, j * step
            local r = step * 0.46 * (1 - 1.15 * (cx / c.w + cy / c.h))
            if r >= 1 then c:disc(cx, cy, r, LIGHT) end
        end
    end
end

-- Rays fanning up from the middle of the bottom edge.
function PAINTERS.sunburst(c)
    local rays, spread, edges = 9, math.rad(156), {}
    local slice = spread / rays
    for i = 0, rays - 1 do
        local from = -spread / 2 + (i + 0.25) * slice
        edges[#edges + 1] = { math.tan(from), math.tan(from + slice * 0.5) }
    end
    for row = 0, c.h - 1 do
        local rise = c.h - row
        for _i, edge in ipairs(edges) do
            c:run(c.w / 2 + rise * edge[1], c.w / 2 + rise * edge[2], row, LIGHT)
        end
    end
end

function PAINTERS.bars(c)
    local heights = { 0.20, 0.34, 0.26, 0.48, 0.40, 0.62, 0.54, 0.80 }
    local slot = c.w / #heights
    for i, share in ipairs(heights) do
        local bar_h = c.h * share
        c:rect((i - 1) * slot + slot * 0.2, c.h - bar_h, slot * 0.6, bar_h, LIGHT)
    end
end

-- Two sine-edged drapes hanging from the top edge.
function PAINTERS.waves(c)
    local function drape(base, amp, length, phase, color)
        for row = 0, math.floor(base + amp) do
            local level = (row - base) / amp
            if level <= -1 then
                c:run(0, c.w, row, color)
            else
                -- sin(a) >= level between asin(level) and pi - asin(level).
                local dip = math.asin(math.min(1, level)) / (2 * math.pi)
                for turn = -1, math.ceil(c.w / length) do
                    local origin = turn - phase
                    c:run((origin + dip) * length, (origin + 0.5 - dip) * length, row, color)
                end
            end
        end
    end
    drape(c.h * 0.26, c.h * 0.07, c.w * 0.9, 0.15, LIGHT)
    drape(c.h * 0.10, c.h * 0.05, c.w * 0.6, 0.55, MID)
end

-- Tilted paper bits, streamers and dots, thinning out towards the bottom. The seed is
-- fixed so repaints match.
function PAINTERS.confetti(c)
    local seed = 20
    local function rnd()
        seed = seed * 16807 % 2147483647 -- minstd: stays exact in a double
        return seed / 2147483647
    end
    local unit = Screen:scaleBySize(9)
    for i = 1, 70 do
        local cx, cy = rnd() * c.w, rnd() ^ 1.6 * c.h
        local size, color = unit * (0.8 + rnd()), rnd() < 0.45 and MID or LIGHT
        local tilt = (0.3 + rnd() * 0.8) * (rnd() < 0.5 and -1 or 1)
        local streamer = i % 5 == 0
        if not c:blocked(cx, cy, size * (streamer and 4 or 1.7)) then
            if streamer then
                c:streamer(cx, cy, size * 7, size * 0.9, size * 0.5, tilt * 0.4, color)
            elseif i % 5 == 1 then
                c:disc(cx, cy, size * 0.6, color)
            else
                c:slab(cx, cy, size * 1.5, size * 0.6, tilt, color)
            end
        end
    end
end

local CYCLE = { "orbs", "stripes", "rings", "halftone", "sunburst", "bars", "waves" }

local M = {}

-- Painter name and whether it is mirrored, for a 1-based slide index.
function M.pick(index, count)
    if index <= 1 or index >= count then return "confetti", false end
    local slot = index - 2
    return CYCLE[slot % #CYCLE + 1], math.floor(slot / #CYCLE) % 2 == 1
end

function M.paint(bb, index, count, x, y, w, h, clear)
    if w <= 0 or h <= 0 then return end
    local name, mirror = M.pick(index, count)
    PAINTERS[name](setmetatable({ bb = bb, x = x, y = y, w = w, h = h, mirror = mirror, clear = clear }, Canvas))
end

return M
