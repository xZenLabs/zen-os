local logger = require("common/zen_logger").new("bluetooth")

local M = {}
local cached_state
local request_serial = 0
local changing = false
local platform

-- Power backend: bluetooth_adapters/<platform> exposes readState/setPower (+ optional isAvailable/onSuspend).
local function backend()
    if not platform then
        local Device = require("device")
        local name = Device.isKindle and Device:isKindle() and "kindle"
            or Device.isPocketBook and Device:isPocketBook() and "pocketbook" or "kobo"
        platform = require("modules/menu/bluetooth_adapters/" .. name)
    end
    return platform
end

local function cache_state(state)
    if state == nil then
        cached_state = nil
    else
        cached_state = state ~= 0
    end
    return cached_state
end

local function log_state(context)
    local state, source = backend().readState()
    cache_state(state)
    logger.info("state", context .. ":", state == nil and "unavailable" or tostring(state),
        "source=", source or "platform")
    return state
end

function M.getState()
    return cache_state(backend().readState())
end

function M.getCachedState()
    return cached_state
end

function M.isAvailable()
    local b = backend()
    return changing or (b.isAvailable ~= nil and b.isAvailable()) or M.getState() ~= nil
end

function M.isEnabled()
    if changing then return cached_state == true end
    return M.getState() == true
end

function M.isChanging()
    return changing
end

function M.setEnabled(enabled, complete)
    request_serial = request_serial + 1
    local request_id = request_serial
    local UIManager = require("ui/uimanager")
    local Event = require("ui/event")
    changing = true
    UIManager:broadcastEvent(Event:new("BluetoothStateChanged"))
    UIManager:forceRePaint()
    if not enabled then
        local switcher = package.loaded["modules/menu/bluetooth_switcher"]
        if switcher and switcher.cancelScan then switcher.cancelScan() end
    end
    local finished = false
    local function done(success, reason)
        if finished then return end
        finished = true
        logger.info("power request complete:", "request=", request_id,
            "success=", tostring(success), "reason=", reason or "none")
        if request_id == request_serial then
            changing = false
            if success then cached_state = enabled else cached_state = nil end
            UIManager:broadcastEvent(Event:new("BluetoothStateChanged"))
        end
        if complete then complete(success, reason) end
    end
    -- Polls readState until it matches; fallback fires on attempt 4, exhausted before failing.
    local function verify(delays, fallback, exhausted)
        local attempts = 0
        local check
        check = function()
            attempts = attempts + 1
            local raw_state, source = backend().readState()
            local state = cache_state(raw_state)
            logger.info("power confirmation:", "request=", request_id,
                "requested=", tostring(enabled), "observed=", tostring(state),
                "raw=", tostring(raw_state), "source=", source or "platform", "attempt=", attempts)
            if state == enabled then
                done(true)
            else
                if attempts == 4 and fallback then fallback() end
                local delay
                if delays then delay = delays[attempts]
                elseif attempts < 10 then delay = 0.5 end
                if delay then
                    UIManager:scheduleIn(delay, check)
                else
                    if exhausted then exhausted() end
                    done(false, "Could not confirm Bluetooth power state.")
                end
            end
        end
        check()
    end
    local accepted = backend().setPower(enabled, {
        id = request_id, done = done, verify = verify, logState = log_state,
    })
    if not accepted then done(false, "Could not change Bluetooth power.") end
    return accepted
end

function M.toggle(complete)
    local state = M.getState()
    if state == nil then
        if complete then complete(false, "Bluetooth is unavailable.") end
        return false
    end
    return M.setEnabled(not state, complete)
end

function M.onSuspend()
    local b = backend()
    if b.onSuspend then b.onSuspend() end
    request_serial = request_serial + 1
    changing = false
    cached_state = nil
end

return M
