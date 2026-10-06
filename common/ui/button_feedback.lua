local Geom = require("ui/geometry")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")

local M = {}

function M.paddedRegion(dimen)
    local padding = Screen:scaleBySize(4)
    return Geom:new{
        x = dimen.x - padding, y = dimen.y - padding,
        w = dimen.w + 2 * padding, h = dimen.h + 2 * padding,
    }
end

function M.invert(region)
    local x, y, w, h = region.x, region.y, region.w, region.h
    local radius = math.min(Screen:scaleBySize(8), math.floor(math.min(w, h) / 2))
    Screen.bb:invertRect(x, y + radius, w, h - 2 * radius)
    for row = 0, radius - 1 do
        local dy = radius - row - 0.5
        local inset = math.ceil(radius - math.sqrt(radius * radius - dy * dy))
        Screen.bb:invertRect(x + inset, y + row, w - 2 * inset, 1)
        Screen.bb:invertRect(x + inset, y + h - row - 1, w - 2 * inset, 1)
    end
end

function M.refreshMode()
    -- Fast refresh loses background shades and antialiased edges on color panels.
    return Screen:isColorScreen() and "ui" or "fast"
end

function M.flash(region)
    if not region or not region.x or not region.y
            or G_reader_settings:isFalse("flash_ui") then return end
    local mode = M.refreshMode()
    M.invert(region)
    UIManager:setDirty(nil, mode, region)
    UIManager:forceRePaint()
    UIManager:yieldToEPDC()
    M.invert(region)
    UIManager:setDirty(nil, mode, region)
end

function M.flashButton(dimen)
    if dimen and dimen.x and dimen.y then M.flash(M.paddedRegion(dimen)) end
end

return M
