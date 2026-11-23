-- Power is netagent's. Reads and device actions go to BlueZ over D-Bus; scanning needs a client that
-- stays on the bus and pairing an agent, which a one-shot dbus-send is neither, so bluetoothctl does those.
local UIManager = require("ui/uimanager")
local Bluez = require("modules/menu/bluetooth/bluez")
local Common = require("modules/menu/bluetooth_adapters/common")

local M = {}
local SERVICE = "org.bluez"
-- bluetoothd away or busy: says nothing about dbus-send itself
local TRANSIENT = { ServiceUnknown = true, NameHasNoOwner = true, NoReply = true, Timeout = true, UnknownObject = true }
-- The action is done or under way; the state poll confirms.
local SETTLED = { AlreadyConnected = true, InProgress = true, NotConnected = true, DoesNotExist = true }
local BLUETOOTHCTL = { forget = "remove" }
local dbus_broken -- dbus-send missing or refused: bluetoothctl for the rest of the session

local function succeeded(ok, code)
    return ok == true or ok == 0 or code == 0
end

-- Output of a command, and whether it exited cleanly.
local function query(command)
    local pipe = io.popen(command .. " 2>&1", "r")
    if not pipe then return "", false end
    local output = pipe:read("*a") or ""
    local ok, _how, code = pipe:close()
    return output, succeeded(ok, code)
end

local function run(command)
    local ok, _how, code = os.execute(command .. " >/dev/null 2>&1")
    return succeeded(ok, code)
end

function M.isSupported(Device)
    return Device.isPocketBook and Device:isPocketBook()
end

function M.readState()
    local output = query("netagent bt status 2>/dev/null")
    if output:find("BT_STATE_OFF", 1, true) then return 0 end
    if output:find("BT_STATE_", 1, true) then return 1 end
end

-- request: { done, verify } from bluetooth.setEnabled.
function M.setPower(enabled, request)
    if M.readState() == nil then request.done(false, "Bluetooth is unavailable."); return false end
    local ok, _how, code = os.execute("netagent bt " .. (enabled and "on" or "off") .. " >/dev/null 2>&1 &")
    if not succeeded(ok, code) then return false end
    request.verify()
    return true
end

-- Whether dbus-send got a reply. Any error but bluetoothd's own or an absent/busy bluetoothd
-- means D-Bus is unusable here (no dbus-send, access denied).
local function answered(output)
    if output:find("^method return") then return true end
    local err = output:match("Error ([%w%.]+)")
    if not (err and (err:find("^org%.bluez%.") or TRANSIENT[err:match("[^.]+$")])) then dbus_broken = true end
    return false
end

local function dbus_devices()
    local output = query(Bluez.command(SERVICE, "/", "org.freedesktop.DBus.ObjectManager.GetManagedObjects"))
    if answered(output) then return Bluez.parseDevices(output) end
    return nil, "Could not read Bluetooth devices."
end

local function bluetoothctl_devices()
    local output, ok = query("bluetoothctl devices")
    if not ok then return nil, output end
    local devices = {}
    for line in output:gmatch("[^\r\n]+") do
        local address, name = line:match("^Device (%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s*(.*)$")
        if address then
            local info, info_ok = query("bluetoothctl info '" .. address .. "'")
            if not info_ok then return nil, info end
            local hid, le = Bluez.classify({
                Icon = info:match("Icon: ([^\r\n]+)"),
                Class = tonumber(info:match("Class: (0x%x+)")),
                Appearance = tonumber(info:match("Appearance: (0x%x+)")),
                AddressType = info:match("^Device %S+ %((%a+)%)"),
            }, info:find("(00001124-", 1, true) ~= nil or info:find("(00001812-", 1, true) ~= nil)
            devices[#devices + 1] = {
                id = address, address = address,
                name = info:match("[\r\n]Alias: ([^\r\n]+)")
                    or info:match("[\r\n]Name: ([^\r\n]+)")
                    or (name ~= "" and name or address),
                paired = info:find("Paired: yes", 1, true) ~= nil,
                connected = info:find("Connected: yes", 1, true) ~= nil,
                rssi = tonumber(info:match("RSSI: (%-?%d+)")),
                hid = hid, le = le,
            }
        end
    end
    return devices
end

-- Runs a device action; the address is already validated.
local function act(name, address)
    if name ~= "pair" and not dbus_broken then
        local output = query(Bluez.actionCommand(SERVICE, name, Bluez.devicePath(address)))
        if answered(output) then return true end
        if not dbus_broken then return SETTLED[output:match("Error org%.bluez%.Error%.(%a+)")] == true end
    end
    return run((name == "pair" and "bluetoothctl --agent NoInputNoOutput --timeout 5 " or "bluetoothctl ")
        .. (BLUETOOTHCTL[name] or name) .. " '" .. address .. "'")
end

function M.new()
    local adapter = { id = "pocketbook" }

    function adapter.getDeviceList()
        if not dbus_broken then
            local devices, err = dbus_devices()
            if not dbus_broken then return devices, err end
        end
        return bluetoothctl_devices()
    end

    function adapter.scan(done)
        local started, _how, code = os.execute("bluetoothctl --timeout 10 scan on >/dev/null 2>&1 &")
        if not succeeded(started, code) then
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

    local function action(name, device, field, expected, done)
        if not Common.validAddress(device.address) then
            done(false, "Invalid Bluetooth address.")
            return
        end
        if not act(name, device.address) then
            done(false, "Bluetooth " .. name .. " failed.")
            return
        end
        Common.verify(adapter, device.address, field, expected, done)
    end
    function adapter.pair(device, done)
        action("pair", device, "paired", true, function(ok, err)
            if ok then act("trust", device.address) end -- untrusted devices cannot reconnect by themselves
            done(ok, err)
        end)
    end
    function adapter.connect(device, done) action("connect", device, "connected", true, done) end
    function adapter.disconnect(device, done) action("disconnect", device, "connected", false, done) end
    function adapter.forget(device, done) action("forget", device, "paired", false, done) end

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
