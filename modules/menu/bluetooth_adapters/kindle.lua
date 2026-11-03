local Common = require("modules/menu/bluetooth_adapters/common")
local UIManager = require("ui/uimanager")
local logger = require("common/zen_logger").new("bluetooth_kindle")

local M = {}
local SERVICE = "com.lab126.btfd"
local UNSUPPORTED = "Bluetooth device management is not supported by this Kindle firmware."
local next_scan_id = 0

local function with_handle(property, callback)
    local ok, lipc = pcall(require, "libopenlipclua")
    if not ok or type(lipc) ~= "table" or type(lipc.open_no_name) ~= "function" then
        logger.warn(property, "libopenlipclua unavailable:", ok and "open_no_name missing" or tostring(lipc))
        return nil, UNSUPPORTED
    end
    local opened, handle = pcall(lipc.open_no_name)
    if not opened or not handle then
        logger.warn(property, "LIPC handle unavailable:", tostring(handle))
        return nil, UNSUPPORTED
    end
    local success, result = pcall(callback, handle)
    pcall(handle.close, handle)
    if not success then
        logger.warn(property, "LIPC request failed:", tostring(result))
        return nil, UNSUPPORTED
    end
    return result
end

local function read_hash(property)
    return with_handle(property, function(handle)
        local input = handle:new_hasharray()
        local result
        local ok, values = pcall(function()
            result = handle:access_hash_property(SERVICE, property, input)
            return result and result:to_table()
        end)
        if result then pcall(result.destroy, result) end
        pcall(input.destroy, input)
        if not ok then error(values) end
        if values ~= nil and type(values) ~= "table" then error("non-table hash reply") end
        return values or {}
    end)
end

local function write_property(property, value, numeric)
    local result, err = with_handle(property, function(handle)
        local setter = numeric and handle.set_int_property or handle.set_string_property
        if type(setter) ~= "function" then error(UNSUPPORTED) end
        setter(handle, SERVICE, property, value)
        return true
    end)
    return result == true, err
end

local function normalize(raw)
    local address = raw.address or raw.Address or raw.addr or raw.mac or raw.MAC
        or raw.bdaddr or raw.BDAddr or raw.bd_address or raw.deviceAddress or raw.macAddress
    if not Common.validAddress(address) then return nil end
    local name = raw.name or raw.Name or raw.bd_name or raw.deviceName or raw.friendlyName
    local item = {
        id = address, address = address,
        name = type(name) == "string" and name ~= "" and name or address,
        rssi = tonumber(raw.rssi or raw.RSSI),
    }
    if raw.is_paired ~= nil then item.paired = raw.is_paired == 1 or raw.is_paired == true end
    if raw.is_connected ~= nil then item.connected = raw.is_connected == 1 or raw.is_connected == true end
    return item
end

local function log_reply_shape(property, list)
    local samples, count = {}, 0
    for key, value in pairs(list) do
        count = count + 1
        if #samples < 2 then
            local fields = {}
            if type(value) == "table" then
                for field, item in pairs(value) do
                    fields[#fields + 1] = (Common.validAddress(field) and "<address>" or tostring(field))
                        .. ":" .. type(item)
                end
                table.sort(fields)
            end
            samples[#samples + 1] = (Common.validAddress(key) and "<address>" or tostring(key))
                .. ":" .. type(value) .. "{" .. table.concat(fields, ",") .. "}"
        end
    end
    logger.warn(property, "reply shape:", "entries=", count, "array=", #list,
        "samples=", table.concat(samples, ";"))
end

function M.isSupported(Device)
    return Device.isKindle and Device:isKindle()
end

function M.logServiceState(context, handle)
    local function read(property)
        if type(handle.get_int_property) ~= "function" then return "unavailable" end
        local ok, value = pcall(handle.get_int_property, handle, SERVICE, property)
        return ok and tostring(value) or "error:" .. tostring(value)
    end
    logger.info("btfd", context,
        "BTstate=", read("BTstate"), "mode=", read("currentBTOperatingMode"),
        "btch_running=", read("isBtchRunning"),
        "btch_queued=", read("isBtchQueuedOrRunning"))
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

local function log_service(context)
    with_lipc(function(handle) M.logServiceState(context, handle) end)
end

local function read_state_from_command()
    local out = io.popen("lipc-get-prop -i " .. SERVICE .. " BTstate 2>/dev/null", "r")
    if not out then return nil end
    local value = out:read("*n")
    out:close()
    return value
end

function M.readState()
    local value = with_lipc(function(handle)
        local ok, state = pcall(handle.get_int_property, handle, SERVICE, "BTstate")
        return ok and state or nil
    end)
    local source = "LIPC"
    if type(value) ~= "number" then
        value = read_state_from_command()
        source = "command"
    end
    return type(value) == "number" and value or nil, source
end

-- request: { id, done, verify, logState } from bluetooth.setEnabled.
function M.setPower(enabled, request)
    local request_id, done = request.id, request.done
    local function log_state(context)
        local state = request.logState(context)
        log_service(context)
        return state
    end
    if log_state("before request") == nil then
        logger.warn("toggle unavailable: could not read BTstate")
        done(false, "Bluetooth is unavailable.")
        return false
    end

    logger.info("toggle requested:", enabled and "on" or "off", "request=", request_id)
    local function set_property(property, value, numeric)
        local accepted = with_lipc(function(handle)
            local setter = numeric and handle.set_int_property or handle.set_string_property
            local ok, result = pcall(setter, handle, SERVICE, property, value)
            logger.info(property .. " LIPC:", "request=", request_id, tostring(ok), "result=",
                type(result) == "number" and tostring(result) or type(result))
            return ok
        end)
        if not accepted then
            local ok, _r, code = os.execute("lipc-set-prop " .. (numeric and "-i " or "-s ") .. SERVICE
                .. " " .. property .. " " .. value .. " >/dev/null 2>&1")
            accepted = ok == true or ok == 0 or code == 0
            logger.info(property .. " command fallback:", "request=", request_id,
                tostring(accepted), "exit=", tostring(code))
        end
        logger.info(property .. " request:", "request=", request_id,
            tostring(value), tostring(accepted))
        return accepted
    end

    local function request_power()
        local btenable = set_property("BTenable", enabled and "1:1" or "0:1")
        local accepted = btenable or set_property("BTflightMode", enabled and 0 or 1, true)
        log_state("immediately after power request")
        if accepted then
            request.verify({ 0.5, 0.5, 1, 2, 4, 8, 8 }, btenable and function()
                logger.info("BTenable state unchanged; trying BTflightMode")
                return set_property("BTflightMode", enabled and 0 or 1, true)
            end, function()
                logger.warn("power confirmation exhausted:", "request=", request_id,
                    "command BTstate=", tostring(read_state_from_command()))
                log_service("power confirmation exhausted")
            end)
        else
            done(false, "Could not change Bluetooth power.")
        end
        return accepted
    end
    if enabled then return request_power() end

    local adapter = M.new()
    local devices, err = adapter.getDeviceList()
    if not devices then logger.warn("could not inspect devices before power-off:", err) end
    local connected = {}
    for _i, device in ipairs(devices or {}) do
        if device.connected then connected[#connected + 1] = device end
    end
    logger.info("power-off connections:", "request=", request_id, "connected=", #connected)
    if #connected == 0 then
        adapter.close()
        return request_power()
    end
    local index, accepted = 0, true
    local function disconnect_next()
        index = index + 1
        if index > #connected then
            adapter.close()
            accepted = request_power()
            return
        end
        adapter.disconnect(connected[index], function(ok, reason)
            if not ok then logger.warn("disconnect before power-off failed:", reason) end
            disconnect_next()
        end)
    end
    disconnect_next()
    return accepted
end

function M.new()
    local adapter = { id = "kindle" }
    local function finish_scan(reason)
        local handle = adapter.scan_handle
        if not handle then return end
        adapter.scan_handle = nil
        logger.info("scan", adapter.scan_id, "finishing:", reason)
        M.logServiceState("scan " .. adapter.scan_id .. " before DiscoverA2DP cancel", handle)
        local cancelled, cancel_result = pcall(handle.set_int_property, handle, SERVICE, "DiscoverA2DP", 0)
        logger.info("DiscoverA2DP cancel LIPC:", tostring(cancelled), "result=", tostring(cancel_result))
        M.logServiceState("scan " .. adapter.scan_id .. " after DiscoverA2DP cancel", handle)
        local closed, close_result = pcall(handle.close, handle)
        logger.info("scan", adapter.scan_id, "handle close:", tostring(closed), tostring(close_result))
    end

    function adapter.getDeviceList()
        local discovered, err = read_hash("ListDiscovered")
        if not discovered then return nil, err end
        local paired, pair_error = read_hash("ListPaired")
        if not paired then return nil, pair_error end
        local connected, connection_error = read_hash("ListConnected")
        if not connected then return nil, connection_error end
        logger.info("device list counts:", "scan=", tostring(adapter.scan_id),
            "discovered=", #discovered, "paired=", #paired, "connected=", #connected)
        local devices, by_address, invalid = {}, {}, false
        local function merge(list, field, property)
            local malformed = next(list) and #list == 0 or false
            for _i, raw in ipairs(list) do
                if type(raw) == "table" then
                    local item = normalize(raw)
                    if item then
                        local key = item.address:upper()
                        local existing = by_address[key]
                        if not existing then
                            existing = item
                            by_address[key] = item
                            devices[#devices + 1] = item
                        elseif existing.name == existing.address and item.name ~= item.address then
                            existing.name = item.name
                        end
                        if item.rssi then existing.rssi = item.rssi end
                        if item.paired ~= nil then existing.paired = item.paired end
                        if item.connected ~= nil then existing.connected = item.connected end
                        if field and item[field] == nil then existing[field] = true end
                    else
                        malformed = true
                    end
                else
                    malformed = true
                end
            end
            if malformed then
                invalid = true
                log_reply_shape(property, list)
            end
        end
        merge(discovered, nil, "ListDiscovered")
        merge(paired, "paired", "ListPaired")
        merge(connected, "connected", "ListConnected")
        if invalid then
            logger.warn("unsupported ListDiscovered/ListPaired/ListConnected reply shape")
            return nil, UNSUPPORTED
        end
        return devices
    end

    function adapter.scan(done)
        next_scan_id = next_scan_id + 1
        adapter.scan_id = next_scan_id
        logger.info("scan", adapter.scan_id, "starting")
        local available, lipc = pcall(require, "liblipclua")
        if not available or type(lipc) ~= "table" or type(lipc.init) ~= "function" then
            done(false, UNSUPPORTED)
            return
        end
        local opened, handle = pcall(lipc.init, "com.github.koreader.zenui.bluetooth.scan")
        if not opened or not handle then done(false, UNSUPPORTED); return end
        M.logServiceState("scan " .. adapter.scan_id .. " before DiscoverA2DP", handle)
        local ok, result = pcall(handle.set_int_property, handle, SERVICE, "DiscoverA2DP", 1)
        logger.info("scan", adapter.scan_id, "DiscoverA2DP LIPC:", tostring(ok),
            "result=", tostring(result))
        if not ok then
            pcall(handle.close, handle)
            done(false, UNSUPPORTED)
            return
        end
        M.logServiceState("scan " .. adapter.scan_id .. " after DiscoverA2DP", handle)
        adapter.scan_handle = handle
        adapter.scan_done = done
        local timer
        timer = function()
            if adapter.closed or adapter.scan_timer ~= timer then return end
            adapter.scan_timer = nil
            adapter.scan_done = nil
            logger.info("scan", adapter.scan_id, "timer elapsed; reading results")
            local completed, callback_error = pcall(done, true)
            finish_scan("timer")
            if not completed then error(callback_error) end
        end
        adapter.scan_timer = timer
        UIManager:scheduleIn(10, timer)
    end

    local function action(property, device, field, expected, done)
        if not Common.validAddress(device.address) then
            done(false, "Invalid Bluetooth address.")
            return
        end
        local ok, err = write_property(property, device.address, false)
        if not ok then done(false, err); return end
        Common.verify(adapter, device.address, field, expected, done)
    end
    function adapter.pair(device, done) action("Bond", device, "paired", true, done) end
    function adapter.connect(device, done) action("Connect", device, "connected", true, done) end
    function adapter.disconnect(device, done) action("Disconnect", device, "connected", false, done) end
    function adapter.forget(device, done) action("Unbond", device, "paired", false, done) end
    function adapter.cancelScan()
        if adapter.scan_timer then
            logger.info("scan", adapter.scan_id, "cancel requested")
            UIManager:unschedule(adapter.scan_timer)
            finish_scan("cancel")
        end
        adapter.scan_timer = nil
        local done = adapter.scan_done
        adapter.scan_done = nil
        if done then done(false, "Cancelled.") end
    end
    function adapter.close()
        Common.close(adapter)
        adapter.cancelScan()
    end
    return adapter
end

return M
