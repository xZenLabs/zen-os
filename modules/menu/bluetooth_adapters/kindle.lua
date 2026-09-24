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
        if status ~= nil and status ~= 0 and status ~= true then error(UNSUPPORTED) end
        return true
    end)
    return result == true, err
end

local function normalize(raw)
    local address = raw.address or raw.Address or raw.addr or raw.mac or raw.MAC
        or raw.bdaddr or raw.BDAddr or raw.deviceAddress or raw.macAddress
    if not Common.validAddress(address) then return nil end
    local name = raw.name or raw.Name or raw.deviceName or raw.friendlyName
    return {
        id = address, address = address,
        name = type(name) == "string" and name ~= "" and name or address,
        rssi = tonumber(raw.rssi or raw.RSSI),
    }
end

function M.isSupported(Device)
    return Device.isKindle and Device:isKindle()
end

function M.new()
    local adapter = { id = "kindle" }
    local function finish_scan()
        -- Notify btfd before a subsequent power-off request.
        local ok = write_property("btPopupDone", "", false)
        logger.info("btPopupDone request:", tostring(ok))
    end

    function adapter.getDeviceList()
        local discovered, err = read_hash("ListDiscovered")
        if not discovered then return nil, err end
        local paired, pair_error = read_hash("ListPaired")
        if not paired then return nil, pair_error end
        local connected, connection_error = read_hash("ListConnected")
        if not connected then return nil, connection_error end
        local devices, by_address, invalid = {}, {}, false
        local function merge(list, field)
            if next(list) and #list == 0 then invalid = true end
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
                        if field then existing[field] = true end
                    else
                        invalid = true
                    end
                else
                    invalid = true
                end
            end
        end
        merge(discovered)
        merge(paired, "paired")
        merge(connected, "connected")
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
            local completed, callback_error = pcall(done, true)
            finish_scan()
            if not completed then error(callback_error) end
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
