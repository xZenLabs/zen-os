local Device = require("device")
local Kobo = require("modules/menu/bluetooth/kobo_bluetooth")
local logger = require("common/zen_logger").new("bluetooth")

local M = {}
local cached_state

local SERVICE = "com.lab126.btfd"

local function is_kindle()
    return type(Device.isKindle) == "function" and Device:isKindle()
end

local function is_pocketbook()
    return type(Device.isPocketBook) == "function" and Device:isPocketBook()
end

local function pocketbook_state()
    local pipe = io.popen("netagent bt status 2>/dev/null", "r")
    if not pipe then return nil end
    local output = pipe:read("*a") or ""
    pipe:close()
    if output:find("BT_STATE_OFF", 1, true) then return 0 end
    if output:find("BT_STATE_", 1, true) then return 1 end
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
    if is_pocketbook() then return pocketbook_state() end
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
    if not enabled then
        local switcher = package.loaded["modules/menu/bluetooth_switcher"]
        if switcher and switcher.cancelScan then switcher.cancelScan() end
    end
    local finished = false
    local function done(success, reason)
        if finished then return end
        finished = true
        if success then cached_state = enabled else cached_state = nil end
        if complete then complete(success, reason) end
    end
    local function verify(delays, fallback)
        if not complete then return end
        local UIManager = require("ui/uimanager")
        local attempts = 0
        local check
        check = function()
            attempts = attempts + 1
            local state = M.getState()
            logger.info("power confirmation:", "requested=", tostring(enabled), "observed=", tostring(state),
                "attempt=", attempts)
            if state == enabled then
                done(true)
            else
                if attempts == 4 and fallback and not fallback() then
                    done(false, "Could not change Bluetooth power.")
                    return
                end
                local delay
                if delays then delay = delays[attempts]
                elseif attempts < 10 then delay = 0.5 end
                if delay then
                    UIManager:scheduleIn(delay, check)
                else
                    done(false, "Could not confirm Bluetooth power state.")
                end
            end
        end
        check()
    end
    if is_pocketbook() then
        if M.getState() == nil then done(false, "Bluetooth is unavailable."); return false end
        local ok, _, code = os.execute("netagent bt " .. (enabled and "on" or "off")
            .. " >/dev/null 2>&1 &")
        local accepted = ok == true or ok == 0 or code == 0
        if accepted then verify() else done(false, "Could not change Bluetooth power.") end
        return accepted
    end
    if not is_kindle() then
        local accepted = Kobo.setEnabled(enabled, done)
        if not accepted then done(false, "Could not change Bluetooth power.") end
        return accepted
    end
    local state = log_state("before request")
    if state == nil then
        logger.warn("toggle unavailable: could not read BTstate")
        done(false, "Bluetooth is unavailable.")
        return false
    end

    logger.info("toggle requested:", enabled and "on" or "off")
    local function set_kindle_property(property, value, numeric)
        local accepted = with_lipc(function(handle)
            local setter = numeric and handle.set_int_property or handle.set_string_property
            local ok, result = pcall(setter, handle, SERVICE, property, value)
            logger.info(property .. " LIPC:", tostring(ok), "result=",
                type(result) == "number" and tostring(result) or type(result))
            return ok
        end)
        if not accepted then
            local ok, _, code = os.execute("lipc-set-prop " .. (numeric and "-i " or "-s ") .. SERVICE
                .. " " .. property .. " " .. value .. " >/dev/null 2>&1")
            accepted = ok == true or ok == 0 or code == 0
            logger.info(property .. " command fallback:", tostring(accepted), "exit=", tostring(code))
        end
        logger.info(property .. " request:", tostring(value), tostring(accepted))
        return accepted
    end

    local accepted = set_kindle_property("BTenable", enabled and "1:1" or "0:1")
    log_state("immediately after power request")
    if accepted then
        verify({ 0.5, 0.5, 1, 2, 4, 8, 8 }, function()
            logger.info("BTenable state unchanged; trying BTflightMode")
            return set_kindle_property("BTflightMode", enabled and 0 or 1, true)
        end)
    else
        done(false, "Could not change Bluetooth power.")
    end
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

function M.logState(context)
    return log_state(context or "check")
end

function M.onSuspend()
    Kobo.onSuspend()
    cached_state = nil
end

return M
