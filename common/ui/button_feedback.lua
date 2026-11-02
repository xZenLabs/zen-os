local Geom = require("ui/geometry")
local Device = require("device")
local Screen = Device.screen
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")
local Accent = require("common/ui/accent")
local logger = require("common/zen_logger").new("button_feedback")

local M = {}
local submitted_marker, submitted_buffer
local pending_regions = {} -- color feedback rects whose next "ui" refresh uses the full waveform

function M.getRadius()
    return Screen:scaleBySize(8)
end

function M.getRefreshMode()
    return Screen:isColorScreen() and (Accent.isEnabled() or not Screen.night_mode) and "ui" or "fast"
end

-- Color screens: AUTO can flash the rectangle around color feedback, so only these refreshes get GC16.
function M.markRegion(region)
    if not region or not Screen:isColorScreen() then return end
    if #pending_regions >= 8 then table.remove(pending_regions, 1) end
    pending_regions[#pending_regions + 1] = { x = region.x, y = region.y, w = region.w, h = region.h }
end

-- True (and consumed) when a refresh rect overlaps a marked feedback region.
function M.consumeRegion(x, y, w, h)
    if #pending_regions == 0 or not (x and y and w and h) then return false end
    local hit = false
    for i = #pending_regions, 1, -1 do
        local r = pending_regions[i]
        if r.x < x + w and x < r.x + r.w and r.y < y + h and y < r.y + r.h then
            table.remove(pending_regions, i)
            hit = true
        end
    end
    return hit
end

function M.setDirty(widget, mode, region)
    M.markRegion(region)
    UIManager:setDirty(widget, mode, region)
end

function M.paddedRegion(dimen)
    local padding = Screen:scaleBySize(4)
    return Geom:new{
        x = dimen.x - padding, y = dimen.y - padding,
        w = dimen.w + 2 * padding, h = dimen.h + 2 * padding,
    }
end

local function wait_for_submission()
    -- Wait for the framebuffer copy; full-refresh fallback is monochrome-only.
    local marker = Screen.marker
    if Screen.mech_wait_update_submission and marker then
        if marker ~= 0 and marker ~= Screen.dont_wait_for_marker
                and (marker ~= submitted_marker or Screen.bb ~= submitted_buffer) then
            if Screen:mech_wait_update_submission(marker) == -1 then
                if not Screen:isColorScreen() then
                    logger.warn("Using VSync fallback: submission wait failed", "marker=", marker)
                    UIManager:waitForVSync()
                end
            else
                -- The same submitted frame is safe until another update is issued.
                submitted_marker, submitted_buffer = marker, Screen.bb
            end
        end
    elseif not Screen:isColorScreen() and Device.isMTK and Device:isMTK() then
        logger.warn("Using VSync fallback: update submission unavailable", "marker=", marker)
        UIManager:waitForVSync()
    end
end

local function each_span(region, radius, paint)
    local x, y, w, h = region.x, region.y, region.w, region.h
    radius = math.min(radius or M.getRadius(), math.floor(math.min(w, h) / 2))
    paint(x, y + radius, w, h - 2 * radius)
    for row = 0, radius - 1 do
        local dy = radius - row - 0.5
        local inset = math.ceil(radius - math.sqrt(radius * radius - dy * dy))
        paint(x + inset, y + row, w - 2 * inset, 1)
        paint(x + inset, y + h - row - 1, w - 2 * inset, 1)
    end
end

function M.invert(region, radius)
    wait_for_submission()
    each_span(region, radius, function(x, y, w, h) Screen.bb:invertRect(x, y, w, h) end)
end

function M.highlight(region, radius)
    if not Accent.isEnabled() then
        M.invert(region, radius)
        return
    end
    wait_for_submission()
    local x, y = math.max(0, region.x), math.max(0, region.y)
    local w = math.min(Screen.bb:getWidth(), region.x + region.w) - x
    local h = math.min(Screen.bb:getHeight(), region.y + region.h) - y
    if w <= 0 or h <= 0 then return end
    local saved = Blitbuffer.new(w, h, Screen.bb:getType())
    saved:blitFrom(Screen.bb, 0, 0, x, y, w, h)
    local mask = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
    mask:blitFrom(saved, 0, 0, 0, 0, w, h)
    mask:invertRect(0, 0, w, h)
    local color, foreground = Accent.color(), Accent.foreground()
    each_span(region, radius, function(sx, sy, sw, sh)
        Screen.bb:paintRectRGB32(sx, sy, sw, sh, color)
        Screen.bb:colorblitFromRGB32(mask, sx, sy, sx - x, sy - y, sw, sh, foreground)
    end)
    mask:free()
    return { bb = saved, x = x, y = y }
end

function M.restore(region, saved, radius)
    if saved then
        wait_for_submission()
        Screen.bb:blitFrom(saved.bb, saved.x, saved.y, 0, 0, saved.bb:getWidth(), saved.bb:getHeight())
        saved.bb:free()
    else
        M.invert(region, radius)
    end
end

function M.flash(region, radius)
    if not region or not region.x or not region.y
            or G_reader_settings:isFalse("flash_ui") then return end
    region = Geom:new{
        x = region.x, y = region.y, w = region.w, h = region.h,
    }
    local saved = M.highlight(region, radius)
    M.setDirty(nil, M.getRefreshMode(), region)
    UIManager:forceRePaint()
    UIManager:yieldToEPDC()
    M.restore(region, saved, radius)
    -- Restore gray pixels with the same waveform as stock menu rows.
    M.setDirty(nil, "ui", region)
end

function M.flashButton(dimen)
    if dimen and dimen.x and dimen.y then M.flash(dimen) end
end

return M
