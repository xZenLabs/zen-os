local Device = require("device")
local Kobo = require("common/kobo_bluetooth")
local logger = require("common/zen_logger").new("bluetooth")

local M = {}
local cached_state

local SERVICE = "com.lab126.btfd"

local function is_kindle()
    return type(Device.isKindle) == "function" and Device:isKindle()
end

local function with_lipc(callback)
    local ok, lipc = pcall(require, "liblipclua")
    if not ok or not lipc then return nil end

    local handle = lipc.init("com.github.koreader.zenui.bluetooth")
    if not handle then return nil end

    local result = callback(handle)
    pcall(handle.close, handle)
    return result
end

local function read_state_from_command()
    local out = io.popen("lipc-get-prop -i " .. SERVICE .. " BTstate 2>/dev/null", "r")
    if not out then return nil end
    local value = out:read("*n")
    out:close()
    return value
end

local function read_state()
    if not is_kindle() then
        local state = Kobo.getState()
        return state == nil and nil or (state and 1 or 0)
    end

    local value = with_lipc(function(handle)
        local ok, state = pcall(handle.get_int_property, handle, SERVICE, "BTstate")
        return ok and state or nil
    end)
    if type(value) ~= "number" then
        value = read_state_from_command()
    end
    return type(value) == "number" and value or nil
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
    local state = read_state()
    cache_state(state)
    logger.info("state", context .. ":", state == nil and "unavailable" or tostring(state))
    return state
end

function M.getState()
    return cache_state(read_state())
end

function M.getCachedState()
    return cached_state
end

function M.isAvailable()
    return Kobo.isAvailable() or M.getState() ~= nil
end

function M.isEnabled()
    return M.getState() == true
end

function M.setEnabled(enabled, complete)
    if not is_kindle() then
        local function finished(success)
            if success then cached_state = enabled else cached_state = nil end
            if complete then complete(success) end
        end
        local accepted = Kobo.setEnabled(enabled, finished)
        if accepted then cached_state = enabled end
        return accepted
    end
    local state = log_state("before request")
    if state == nil then
        logger.warn("toggle unavailable: could not read BTstate")
        return false
    end

    local request = enabled and "1:1" or "0:1"
    logger.info("toggle requested:", enabled and "on" or "off")
    local set = with_lipc(function(handle)
        local ok, result = pcall(handle.set_string_property, handle, SERVICE, "BTenable", request)
        logger.info("BTenable request:", request, ok and "accepted" or "failed", tostring(result))
        return ok
    end)
    if set ~= nil then
        log_state("immediately after LIPC request")
        return set
    end

    logger.warn("LIPC bindings unavailable; using lipc command fallback")
    local ok, _, code = os.execute("lipc-set-prop -s " .. SERVICE
        .. " BTenable " .. request .. " >/dev/null 2>&1")
    local success = ok == true or ok == 0 or code == 0
    logger.info("BTenable command:", request, tostring(ok), tostring(code))
    log_state("immediately after command request")
    return success
end

function M.toggle(complete)
    local state = M.getState()
    if state == nil then return false end
    return M.setEnabled(not state, complete)
end

function M.logState(context)
    return log_state(context or "check")
end

function M.onSuspend()
    Kobo.onSuspend()
    cached_state = nil
end

return M
