local time = require("ui/time")

local M = {}

local last_path
local last_tap_at
local pending
-- Deferred single-tap open replays its tap; these let that replay through.
local armed_path
local armed_at

-- Single and double tap actions; single "open" moves the menu to double tap, else double tap opens.
function M.tapActions(dev)
    local single = type(dev) == "table" and dev.single_tap_action
    if single ~= "open" and single ~= "menu" then single = "none" end
    return single, single == "open" and "menu" or "open"
end

-- Same as tapActions, or nil when double tap is off.
function M.actions()
    local ok, ConfigManager = pcall(require, "config/manager")
    local config = ok and ConfigManager and ConfigManager.get and ConfigManager.get()
    local dev = type(config) == "table" and config.developer
    if type(dev) ~= "table" or dev.double_tap ~= true then return nil end
    return M.tapActions(dev)
end

local function double_tap_interval()
    local ok, GestureDetector = pcall(require, "device/gesturedetector")
    if ok and GestureDetector and GestureDetector.ges_double_tap_interval then
        return GestureDetector.ges_double_tap_interval
    end
    return time.ms(300)
end

function M.reset()
    if pending then
        require("ui/uimanager"):unschedule(pending)
        pending = nil
    end
    last_path = nil
    last_tap_at = nil
end

local function is_second_tap(path, tap_at)
    return last_path == path and last_tap_at ~= nil
        and tap_at >= last_tap_at
        and tap_at - last_tap_at < double_tap_interval()
end

local function is_armed(path, tap_at)
    return armed_path ~= nil and armed_path == path and armed_at == tap_at
end

local function is_book(path)
    return type(path) == "string" and path ~= ""
end

-- True when this tap opens the book right away.
function M.willOpen(path, tap_at)
    local single, double = M.actions()
    if not single or not is_book(path) or is_armed(path, tap_at) then return true end
    return double == "open" and is_second_tap(path, tap_at or time.now())
end

-- menu shows the context menu; open replays the tap to open after the double-tap window.
function M.shouldOpen(path, tap_at, menu, open)
    if is_armed(path, tap_at) then return true end
    local single, double = M.actions()
    if not single or not is_book(path) or (single == "open" and not menu) then
        M.reset()
        return true
    end

    local now = tap_at or time.now()
    if is_second_tap(path, now) then
        M.reset()
        if double == "open" then return true end
        menu()
        return false
    end

    M.reset()
    last_path = path
    last_tap_at = now
    local action = single == "menu" and menu or single == "open" and open
    if action then
        pending = function()
            M.reset()
            if M.actions() ~= single then return end
            armed_path, armed_at = path, now
            action()
            armed_path, armed_at = nil, nil
        end
        require("ui/uimanager"):scheduleIn(time.to_s(double_tap_interval()), pending)
    end
    return false
end

return M
