local time = require("ui/time")

local M = {}

local last_path
local last_tap_at
local pending_menu

local function is_enabled(key)
    local ok, ConfigManager = pcall(require, "config/manager")
    local config = ok and ConfigManager and ConfigManager.get and ConfigManager.get()
    return type(config) == "table"
        and type(config.developer) == "table"
        and config.developer[key or "double_tap_to_open_books"] == true
end

local function double_tap_interval()
    local ok, GestureDetector = pcall(require, "device/gesturedetector")
    if ok and GestureDetector and GestureDetector.ges_double_tap_interval then
        return GestureDetector.ges_double_tap_interval
    end
    return time.ms(300)
end

function M.reset()
    if pending_menu then
        require("ui/uimanager"):unschedule(pending_menu)
        pending_menu = nil
    end
    last_path = nil
    last_tap_at = nil
end

local function is_second_tap(path, tap_at)
    return last_path == path and last_tap_at ~= nil
        and tap_at >= last_tap_at
        and tap_at - last_tap_at < double_tap_interval()
end

function M.willOpen(path, tap_at)
    if not is_enabled() then return true end
    if type(path) ~= "string" or path == "" then return true end
    return is_second_tap(path, tap_at or time.now())
end

function M.shouldOpen(path, tap_at, on_single_tap)
    if not is_enabled() then
        M.reset()
        return true
    end
    if type(path) ~= "string" or path == "" then
        M.reset()
        return true
    end

    local now = tap_at or time.now()
    local accepted = is_second_tap(path, now)

    if accepted then
        M.reset()
        return true
    end

    M.reset()
    last_path = path
    last_tap_at = now
    if on_single_tap and is_enabled("single_tap_to_open_context_menu") then
        pending_menu = function()
            M.reset()
            if is_enabled() and is_enabled("single_tap_to_open_context_menu") then
                on_single_tap()
            end
        end
        require("ui/uimanager"):scheduleIn(time.to_s(double_tap_interval()), pending_menu)
    end
    return false
end

return M
