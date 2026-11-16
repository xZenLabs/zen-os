-- Shared bottom-sheet chrome: docked geometry and the drop shadow around a rounded frame.
local Geom = require("ui/geometry")
local Screen = require("device").screen

local M = {
    alpha = 0.3, -- Set as widget.alpha so UIManager repaints the page below before the shadow blends.
}

function M.shadowSize()
    return Screen:scaleBySize(4)
end

-- Side margin and width of a sheet docked on a w x h screen: right half in landscape.
function M.dock(w, h)
    local landscape = w > h
    local margin = Screen:scaleBySize(landscape and 8 or 2) -- Portrait: inset clears bezel.
    return margin, (landscape and math.floor(w / 2) or w) - 2 * margin
end

-- Refresh area covering a frame and its shadow, clipped to the screen.
function M.refreshArea(x, y, w, h)
    local shadow = M.shadowSize()
    return Geom:new{ x = x - shadow, y = y - shadow, w = w + 2 * shadow, h = h + 2 * shadow }
        :intersect(Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() })
end

local corner_cuts = {} -- per outer radius: row -> arc inset
local function cornerCuts(radius)
    local cuts = corner_cuts[radius]
    if cuts then return cuts end
    cuts = {}
    for row = 0, radius - 1 do
        local dy = radius - row - 0.5
        cuts[row] = math.ceil(radius - math.sqrt(radius * radius - dy * dy))
    end
    corner_cuts[radius] = cuts
    return cuts
end

-- Blend only the narrow perimeter; the opaque frame painted afterwards covers the inner corner pixels.
function M.paintShadow(bb, x, y, w, h, radius)
    local shadow, opacity = M.shadowSize(), M.alpha
    local shade = Screen.night_mode and bb.lightenRect or bb.darkenRect
    shade(bb, x + radius, y - shadow, w - 2 * radius, shadow, opacity)
    shade(bb, x + radius, y + h, w - 2 * radius, shadow, opacity)
    shade(bb, x - shadow, y + radius, shadow, h - 2 * radius, opacity)
    shade(bb, x + w, y + radius, shadow, h - 2 * radius, opacity)
    local outer_radius = radius + shadow
    local cuts = cornerCuts(outer_radius)
    for row = 0, outer_radius - 1 do
        local cut = cuts[row]
        local span = outer_radius - cut
        shade(bb, x - shadow + cut, y - shadow + row, span, 1, opacity)
        shade(bb, x + w - radius, y - shadow + row, span, 1, opacity)
        shade(bb, x - shadow + cut, y + h + shadow - row - 1, span, 1, opacity)
        shade(bb, x + w - radius, y + h + shadow - row - 1, span, 1, opacity)
    end
end

return M
