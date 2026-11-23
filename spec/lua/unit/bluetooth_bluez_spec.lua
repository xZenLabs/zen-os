describe("BlueZ D-Bus helpers", function()
    local Bluez

    local function entry(key, value)
        return "                  dict entry(\n                     string \"" .. key .. "\"\n"
            .. "                     variant                         " .. value .. "\n                  )\n"
    end
    local function object(path, interfaces)
        local out = "      dict entry(\n         object path \"" .. path .. "\"\n         array [\n"
        for _i, interface in ipairs(interfaces) do
            out = out .. "            dict entry(\n               string \"" .. interface[1] .. "\"\n"
                .. "               array [\n" .. (interface[2] or "") .. "               ]\n            )\n"
        end
        return out .. "         ]\n      )\n"
    end
    local function reply(...)
        return "method return time=0 sender=:1.1 -> destination=:1.2 serial=1 reply_serial=2\n   array [\n"
            .. table.concat({ ... }) .. "   ]\n"
    end

    before_each(function()
        ZenSpec.unload("modules/menu/bluetooth/bluez")
        Bluez = require("modules/menu/bluetooth/bluez")
    end)

    it("reads Device1 properties, transport and HID class from managed objects", function()
        local output = reply(
            object("/org/bluez/hci0", {{ "org.bluez.Adapter1",
                entry("Address", 'string "00:11:22:33:44:01"') .. entry("Powered", "boolean true") }}),
            object("/org/bluez/hci0/dev_00_11_22_33_44_02", {
                { "org.freedesktop.DBus.Introspectable" },
                { "org.bluez.Device1", entry("Address", 'string "00:11:22:33:44:02"')
                    .. entry("AddressType", 'string "public"') .. entry("Name", 'string "Phone"')
                    .. entry("Class", "uint32 7995916") .. entry("Icon", 'string "phone"')
                    .. entry("Paired", "boolean true") .. entry("Connected", "boolean false")
                    .. entry("RSSI", "int16 -61")
                    .. entry("UUIDs", "array [\n   string \"0000110a-0000-1000-8000-00805f9b34fb\"\n]") },
                { "org.bluez.MediaControl1", entry("Connected", "boolean true") },
            }),
            object("/org/bluez/hci0/dev_00_11_22_33_44_02/sep1", {{ "org.bluez.MediaEndpoint1",
                entry("UUID", 'string "0000110a-0000-1000-8000-00805f9b34fb"') }}),
            object("/org/bluez/hci0/dev_00_11_22_33_44_03", {{ "org.bluez.Device1",
                entry("Address", 'string "00:11:22:33:44:03"') .. entry("AddressType", 'string "public"')
                .. entry("Name", 'string "Page turner"') .. entry("Paired", "boolean true")
                .. entry("Trusted", "boolean true")
                .. entry("UUIDs", "array [\n   string \"00001812-0000-1000-8000-00805f9b34fb\"\n]")
                .. entry("ServiceData", "array [\n   dict entry(\n      string \"0000fe9f-0000-1000-8000-00805f9b34fb\""
                    .. "\n      variant array of bytes [\n         00 01\n      ]\n   )\n]")
                .. entry("AdvertisingFlags", 'array of bytes "" + \\0')
                .. entry("Connected", "boolean true") }}),
            object("/org/bluez/hci0/dev_00_11_22_33_44_04", {{ "org.bluez.Device1",
                entry("Address", 'string "00:11:22:33:44:04"') .. entry("AddressType", 'string "public"')
                .. entry("Class", "uint32 9536") .. entry("Connected", "boolean false") }}),
            object("/org/bluez/hci0/dev_C0_11_22_33_44_05", {{ "org.bluez.Device1",
                entry("Address", 'string "C0:11:22:33:44:05"') .. entry("AddressType", 'string "random"')
                .. entry("Icon", 'string "input-gaming"') .. entry("Appearance", "uint16 964") }})
        )
        local devices = Bluez.parseDevices(output)
        assert.are.equal(4, #devices)
        local phone, remote, keyboard, pad = devices[1], devices[2], devices[3], devices[4]
        assert.are.same({ "Phone", true, false, -61 }, { phone.name, phone.paired, phone.connected, phone.rssi })
        assert.are.equal("/org/bluez/hci0/dev_00_11_22_33_44_02", phone.path)
        assert.is_nil(phone.hid)
        assert.is_false(phone.le)
        assert.are.same({ "Page turner", true, true, true, true }, {
            remote.name, remote.trusted, remote.connected, remote.hid, remote.le })
        assert.are.same({ "00:11:22:33:44:04", true, false }, { keyboard.name, keyboard.hid, keyboard.le })
        assert.are.same({ true, true }, { pad.hid, pad.le })
    end)

    it("builds device actions only for device paths", function()
        local path = Bluez.devicePath("aa:bb:cc:dd:ee:ff")
        assert.are.equal("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF", path)
        assert.is_truthy(Bluez.actionCommand("org.bluez", "connect", path):find(path .. " org.bluez.Device1.Connect", 1, true))
        assert.is_truthy(Bluez.actionCommand("org.bluez", "forget", path):find("RemoveDevice objpath:" .. path, 1, true))
        assert.is_truthy(Bluez.actionCommand("org.bluez", "trust", path):find("string:Trusted variant:boolean:true", 1, true))
        local command, err = Bluez.actionCommand("org.bluez", "connect", path .. ";reboot")
        assert.is_nil(command)
        assert.is_truthy(err:find("Invalid", 1, true))
        assert.is_nil(Bluez.actionCommand("org.bluez", "block", path))
    end)
end)
