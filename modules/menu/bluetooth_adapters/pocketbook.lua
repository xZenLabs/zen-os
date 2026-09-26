local UIManager = require("ui/uimanager")
local Common = require("modules/menu/bluetooth_adapters/common")

local M = {}

local function query(command)
    local pipe = io.popen(command .. " 2>&1", "r")
    if not pipe then return nil, "Could not run bluetoothctl." end
    local output = pipe:read("*a") or ""
    local ok, _, code = pipe:close()
    if ok ~= true and ok ~= 0 and code ~= 0 then return nil, output end
    return output
end

local function run(command)
    local ok, _, code = os.execute(command .. " >/dev/null 2>&1")
    return ok == true or ok == 0 or code == 0
end

function M.isSupported(Device)
    return Device.isPocketBook and Device:isPocketBook()
end

function M.new()
    local adapter = { id = "pocketbook" }

    function adapter.getDeviceList()
        local output, err = query("bluetoothctl devices")
        if not output then return nil, err end
        local devices = {}
        for line in output:gmatch("[^\r\n]+") do
            local address, name = line:match("^Device (%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s*(.*)$")
            if address then
                local info, info_error = query("bluetoothctl info '" .. address .. "'")
                if not info then return nil, info_error end
                devices[#devices + 1] = {
                    id = address, address = address,
                    name = info:match("[\r\n]Alias: ([^\r\n]+)")
                        or info:match("[\r\n]Name: ([^\r\n]+)")
                        or (name ~= "" and name or address),
                    paired = info:find("Paired: yes", 1, true) ~= nil,
                    connected = info:find("Connected: yes", 1, true) ~= nil,
                    rssi = tonumber(info:match("RSSI: (%-?%d+)")),
                }
            end
        end
        return devices
    end

    function adapter.scan(done)
        local started, _, code = os.execute("bluetoothctl --timeout 10 scan on >/dev/null 2>&1 &")
        if started ~= true and started ~= 0 and code ~= 0 then
            done(false, "Could not start Bluetooth discovery.")
            return
        end
        adapter.scanning = true
        adapter.scan_done = done
        adapter.scan_timer = function()
            adapter.scan_timer = nil
            adapter.scanning = false
            adapter.scan_done = nil
            run("bluetoothctl scan off")
            if not adapter.closed then done(true) end
        end
        UIManager:scheduleIn(10, adapter.scan_timer)
    end

    local function action(command, device, field, expected, done)
        if not Common.validAddress(device.address) then
            done(false, "Invalid Bluetooth address.")
            return
        end
        local prefix = command == "pair"
            and "bluetoothctl --agent NoInputNoOutput --timeout 5 " or "bluetoothctl "
        if not run(prefix .. command .. " '" .. device.address .. "'") then
            done(false, "Bluetooth " .. command .. " failed.")
            return
        end
        Common.verify(adapter, device.address, field, expected, done)
    end
    function adapter.pair(device, done) action("pair", device, "paired", true, done) end
    function adapter.connect(device, done) action("connect", device, "connected", true, done) end
    function adapter.disconnect(device, done) action("disconnect", device, "connected", false, done) end
    function adapter.forget(device, done) action("remove", device, "paired", false, done) end

    function adapter.close()
        Common.close(adapter)
        if adapter.scan_timer then UIManager:unschedule(adapter.scan_timer) end
        adapter.scan_timer = nil
        if adapter.scanning then run("bluetoothctl scan off") end
        adapter.scanning = false
        local done = adapter.scan_done
        adapter.scan_done = nil
        if done then done(false, "Cancelled.") end
    end
    return adapter
end

return M
