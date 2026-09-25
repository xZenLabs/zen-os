local Common = require("modules/menu/bluetooth_adapters/common")
local UIManager = require("ui/uimanager")
local logger = require("common/zen_logger").new("bluetooth_kindle")

local M = {}
local SERVICE = "com.lab126.btfd"
local UNSUPPORTED = "Bluetooth device management is not supported by this Kindle firmware."

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
        local status = setter(handle, SERVICE, property, value)
        if property == "triggerBTscan" then logger.info("triggerBTscan return:", tostring(status)) end
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

function M.new()
    local adapter = { id = "kindle" }
    local function finish_scan()
        -- Notify btfd before a subsequent power-off request.
        local ok, err = write_property("btPopupDone", "", false)
        logger.info("btPopupDone request:", tostring(ok))
        return ok, err or "Could not finish Bluetooth discovery."
    end

    function adapter.getDeviceList()
        local discovered, err = read_hash("ListDiscovered")
        if not discovered then return nil, err end
        local paired, pair_error = read_hash("ListPaired")
        if not paired then return nil, pair_error end
        local connected, connection_error = read_hash("ListConnected")
        if not connected then return nil, connection_error end
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
        local ok, err = write_property("triggerBTscan", 1, true)
        if not ok then done(false, err); return end
        adapter.scan_done = done
        adapter.scan_timer = function()
            if adapter.closed then return end
            adapter.scan_timer = nil
            adapter.scan_done = nil
            local finished, finish_error = finish_scan()
            done(finished, finished and nil or finish_error)
        end
        UIManager:scheduleIn(10, adapter.scan_timer)
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
    function adapter.close()
        Common.close(adapter)
        if adapter.scan_timer then
            UIManager:unschedule(adapter.scan_timer)
            finish_scan()
        end
        adapter.scan_timer = nil
        local done = adapter.scan_done
        adapter.scan_done = nil
        if done then done(false, "Cancelled.") end
    end
    return adapter
end

return M
