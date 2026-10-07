local Geom = require("ui/geometry")
local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")

local M = {}

function M.paddedRegion(dimen)
    local padding = Screen:scaleBySize(4)
    return Geom:new{
        x = dimen.x - padding, y = dimen.y - padding,
        w = dimen.w + 2 * padding, h = dimen.h + 2 * padding,
    }
end

function M.invert(region, radius)
    -- These controllers may still read pixels after the short EPDC yield.
    if Screen:isColorScreen()
            or Device.isMTK and Device:isMTK()
            or Device.isSunxi and Device:isSunxi() then
        UIManager:waitForVSync()
    end
    local x, y, w, h = region.x, region.y, region.w, region.h
    radius = math.min(radius or Screen:scaleBySize(8), math.floor(math.min(w, h) / 2))
    Screen.bb:invertRect(x, y + radius, w, h - 2 * radius)
    for row = 0, radius - 1 do
        local dy = radius - row - 0.5
        local inset = math.ceil(radius - math.sqrt(radius * radius - dy * dy))
        Screen.bb:invertRect(x + inset, y + row, w - 2 * inset, 1)
        Screen.bb:invertRect(x + inset, y + h - row - 1, w - 2 * inset, 1)
    end
end

function M.flash(region, radius)
    if not region or not region.x or not region.y
            or G_reader_settings:isFalse("flash_ui") then return end
    M.invert(region, radius)
    -- Preserve gray backgrounds and antialiased edges during the highlight too.
    UIManager:setDirty(nil, "ui", region)
    UIManager:forceRePaint()
    UIManager:yieldToEPDC()
    M.invert(region, radius)
    -- Restore gray pixels with the same waveform as stock menu rows.
    UIManager:setDirty(nil, "ui", region)
end

function M.flashButton(dimen)
    if dimen and dimen.x and dimen.y then M.flash(dimen) end
end

return M
