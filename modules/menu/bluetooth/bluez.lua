-- BlueZ over dbus-send: Kobo (BlueZ, and the MTK service that mirrors it) and PocketBook.
local M = { ADAPTER = "/org/bluez/hci0" }
local DEVICE_PATH = "^" .. M.ADAPTER .. "/dev_[%x_]+$"
local METHODS = { pair = "Pair", connect = "Connect", disconnect = "Disconnect" }
local HID_UUIDS = { ["00001124"] = true, ["00001812"] = true } -- HID, HID over GATT

function M.command(destination, path, method, args)
    return "dbus-send --system --print-reply --reply-timeout=10000 --dest="
        .. destination .. " " .. path .. " " .. method .. (args or "")
end

function M.devicePath(address)
    return M.ADAPTER .. "/dev_" .. address:upper():gsub(":", "_")
end

-- nil plus a reason for an unknown action or a path that is not a device's.
function M.actionCommand(destination, action, path)
    if type(path) ~= "string" or not path:match(DEVICE_PATH) then return nil, "Invalid Bluetooth device." end
    if action == "forget" then
        return M.command(destination, M.ADAPTER, "org.bluez.Adapter1.RemoveDevice", " objpath:" .. path)
    elseif action == "trust" then
        return M.command(destination, path, "org.freedesktop.DBus.Properties.Set",
            " string:org.bluez.Device1 string:Trusted variant:boolean:true")
    elseif METHODS[action] then
        return M.command(destination, path, "org.bluez.Device1." .. METHODS[action])
    end
    return nil, "Unsupported Bluetooth action."
end

-- hid: HID service, input icon, peripheral class (major 5) or HID appearance (category 15).
-- le: only LE devices have a random address or lack a class; nil when neither property is there.
function M.classify(props, hid_uuid)
    local class, appearance = props.Class, props.Appearance
    local hid = hid_uuid or (props.Icon or ""):find("^input%-") ~= nil
        or class ~= nil and math.floor(class / 256) % 32 == 5
        or appearance ~= nil and math.floor(appearance / 64) == 15
    local le
    if props.AddressType == "random" or props.AddressType and not class then
        le = true
    elseif class then
        le = false
    end
    return hid or nil, le
end

-- Devices from ObjectManager.GetManagedObjects as dbus-send prints it. Only Device1 properties
-- count: child objects and other interfaces repeat names such as Connected and Name.
function M.parseDevices(output)
    local devices, props, path, key, in_device, hid_uuid = {}, {}, nil, nil, false, false
    local function finish()
        if not path then return end
        local address = (props.Address or path:match("/dev_(.+)$"):gsub("_", ":")):upper()
        local hid, le = M.classify(props, hid_uuid)
        devices[#devices + 1] = {
            id = path, path = path, address = address, name = props.Name or address,
            paired = props.Paired, connected = props.Connected, trusted = props.Trusted,
            rssi = props.RSSI, hid = hid, le = le,
        }
        path = nil
    end
    for line in (output or ""):gmatch("[^\r\n]+") do
        local object = line:match('^%s*object path "([^"]*)"')
        local name = not object and line:match('^%s*string "([^"]*)"%s*$')
        if object then
            finish()
            if object:match(DEVICE_PATH) then
                path, props, key, in_device, hid_uuid = object, {}, nil, true, false
            end
        elseif path and name then
            if key == "UUIDs" and name:find("^%x%x%x%x%x%x%x%x%-") then
                hid_uuid = hid_uuid or HID_UUIDS[name:sub(1, 8):lower()] == true
            elseif name:find(".", 1, true) then -- an interface name
                in_device, key = name:find("%.Device1$") ~= nil, nil
            else
                key = in_device and name or nil
            end
        elseif path and key then
            local value = line:match("^%s*variant%s+(.-)%s*$")
            local text = value and value:match('^string "(.*)"$')
            if text then
                props[key] = text
            elseif value and value:find("^boolean ") then
                props[key] = value == "boolean true"
            elseif value then
                props[key] = tonumber(value:match("^u?int%d+ (%-?%d+)$"))
            end
            -- an array's entries follow its variant line
            if value and key ~= "UUIDs" then key = nil end
        end
    end
    finish()
    return devices
end

return M
