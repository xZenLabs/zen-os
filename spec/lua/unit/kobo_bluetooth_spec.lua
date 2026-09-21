describe("Kobo Bluetooth control", function()
    local saved_modules, saved_plugin
    local open_stub, popen_stub, execute_stub
    local device, bluetooth, scheduled, commands, events, wifi_restored, wifi_disabled
    local owner, powered, prevented, allowed, managed_objects

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs({
            "device", "common/zen_logger", "ui/uimanager", "ui/event",
            "ui/network/manager", "common/kobo_bluetooth",
        }) do
            saved_modules[name] = package.loaded[name] or false
        end
        saved_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        _G.__ZEN_UI_PLUGIN = nil
        owner, powered = false, false
        managed_objects = ""
        prevented, allowed = 0, 0
        wifi_restored, wifi_disabled = 0, 0
        scheduled, commands, events = {}, {}, {}
        device = {
            model = "Kobo_monza",
            isKobo = function() return true end,
            isMTK = function() return true end,
        }
        ZenSpec.replace("device", device)
        ZenSpec.replace("common/zen_logger", {
            new = function() return { info = function() end, warn = function() end } end,
        })
        ZenSpec.replace("ui/uimanager", {
            scheduleIn = function(_self, delay, callback)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end,
            unschedule = function() end,
            preventStandby = function() prevented = prevented + 1 end,
            allowStandby = function() allowed = allowed + 1 end,
            broadcastEvent = function(_self, event) events[#events + 1] = event end,
        })
        ZenSpec.replace("ui/event", {
            new = function(_self, name, data) return { name = name, data = data } end,
        })
        ZenSpec.replace("ui/network/manager", {
            isWifiOn = function() return false end,
            restoreWifiAsync = function() wifi_restored = wifi_restored + 1 end,
            disableWifi = function() wifi_disabled = wifi_disabled + 1 end,
        })
        open_stub = stub(io, "open", function(path)
            if path:find("com.kobo.mtk.bluedroid.service", 1, true) then
                return { close = function() end }
            end
        end)
        popen_stub = stub(io, "popen", function(command)
            if command:find("GetManagedObjects", 1, true) then
                return {
                    read = function() return managed_objects end,
                    close = function() end,
                }
            end
            local value = command:find("NameHasOwner", 1, true) and owner or powered
            return {
                read = function() return "   boolean " .. tostring(value) end,
                close = function() end,
            }
        end)
        execute_stub = stub(os, "execute", function(command)
            commands[#commands + 1] = command
            if command:find("BluedroidManager1.On", 1, true)
                    or command:find("bluetoothd", 1, true) then owner = true end
            if command:find("variant:boolean:true", 1, true) then powered = true end
            if command:find("variant:boolean:false", 1, true) then powered = false end
            return 0
        end)
        ZenSpec.unload("common/kobo_bluetooth")
        bluetooth = require("common/kobo_bluetooth")
    end)

    after_each(function()
        open_stub:revert()
        popen_stub:revert()
        execute_stub:revert()
        _G.__ZEN_UI_PLUGIN = saved_plugin
        for name, module in pairs(saved_modules) do
            package.loaded[name] = module or nil
        end
    end)

    it("reconnects paired devices after powering Bluetooth on", function()
        local discovered_devices = [[
 object path "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"
  string "Paired"
   variant boolean true
  string "Connected"
   variant boolean false
 object path "/org/bluez/hci0/dev_11_22_33_44_55_66"
  string "Paired"
   variant boolean true
  string "Connected"
   variant boolean true
 object path "/org/bluez/hci0/dev_77_88_99_AA_BB_CC"
  string "Paired"
   variant boolean false
  string "Connected"
   variant boolean false
]]

        assert.is_true(bluetooth.setEnabled(true))
        scheduled[1].callback()
        assert.are.equal(1, prevented)
        assert.are.equal(0, allowed)
        assert.is_true(table.concat(commands, "\n"):find("Adapter1.StartDiscovery", 1, true) ~= nil)
        assert.is_nil(table.concat(commands, "\n"):find("org.bluez.Device1.Connect", 1, true))

        managed_objects = discovered_devices
        assert.are.equal(1, scheduled[2].delay)
        scheduled[2].callback()

        local all_commands = table.concat(commands, "\n")
        assert.is_true(all_commands:find(
            "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF org.bluez.Device1.Connect", 1, true
        ) ~= nil)
        assert.is_nil(all_commands:find(
            "/org/bluez/hci0/dev_11_22_33_44_55_66 org.bluez.Device1.Connect", 1, true
        ))
        assert.is_nil(all_commands:find(
            "/org/bluez/hci0/dev_77_88_99_AA_BB_CC org.bluez.Device1.Connect", 1, true
        ))

        for _i = 3, 10 do scheduled[_i].callback() end
        assert.is_true(table.concat(commands, "\n"):find("Adapter1.StopDiscovery", 1, true) ~= nil)
        assert.are.equal(1, allowed)
        assert.is_true(bluetooth.getState())
    end)

    it("powers MTK Bluetooth after waking Wi-Fi, then restores Wi-Fi and suspends safely", function()
        assert.is_true(bluetooth.isAvailable())
        assert.is_false(bluetooth.getState())
        assert.is_true(bluetooth.setEnabled(true))
        assert.are.equal(1, wifi_restored)
        assert.are.equal(1, #scheduled)
        assert.are.equal(1, scheduled[1].delay)
        assert.are.equal(0, #commands)

        scheduled[1].callback()
        assert.is_true(commands[1]:find("BluedroidManager1.On", 1, true) ~= nil)
        assert.is_true(commands[2]:find("variant:boolean:true", 1, true) ~= nil)
        assert.is_true(bluetooth.getState())
        assert.are.equal(1, wifi_disabled)
        assert.are.equal(1, prevented)
        assert.are.equal("BluetoothStateChanged", events[1].name)
        assert.is_true(events[1].data.state)

        bluetooth.onSuspend()
        assert.is_false(bluetooth.getState())
        assert.are.equal(1, allowed)
        assert.is_false(events[2].data.state)
        assert.is_true(table.concat(commands, "\n"):find("Adapter1.StopDiscovery", 1, true) ~= nil)
    end)

    it("uses the Libra 2 BlueZ startup and shutdown path", function()
        device.model = "Kobo_io"
        managed_objects = [[
 object path "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF"
  string "Paired"
   variant boolean true
  string "Connected"
   variant boolean false
]]
        assert.is_true(bluetooth.isAvailable())
        assert.is_false(bluetooth.getState())
        assert.is_true(bluetooth.setEnabled(true))
        assert.is_true(bluetooth.getState())
        assert.are.equal(0, wifi_restored)
        assert.is_true(table.concat(commands, "\n"):find("rtk_hciattach", 1, true) ~= nil)
        assert.is_true(table.concat(commands, "\n"):find(
            "--dest=org.bluez /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF org.bluez.Device1.Connect", 1, true
        ) ~= nil)
        assert.is_true(bluetooth.setEnabled(false))
        assert.is_false(bluetooth.getState())
        assert.are.equal(1, allowed)
    end)

    it("uses the Clara 2E BlueZ startup and shutdown path", function()
        device.model = "Kobo_goldfinch"
        device.isMTK = function() return false end

        assert.is_true(bluetooth.isAvailable())
        assert.is_false(bluetooth.getState())
        assert.is_true(bluetooth.setEnabled(true))
        assert.is_true(bluetooth.getState())

        local all_commands = table.concat(commands, "\n")
        assert.is_true(all_commands:find(
            "/sbin/hciattach -p ttymxc1 any 1500000 flow -t 20", 1, true
        ) ~= nil)
        assert.is_nil(all_commands:find("rtk_hciattach", 1, true))
        assert.is_true(all_commands:find("--dest=org.bluez", 1, true) ~= nil)

        assert.is_true(bluetooth.setEnabled(false))
        assert.is_false(bluetooth.getState())
        assert.is_true(table.concat(commands, "\n"):find(
            "killall bluetoothd hciattach", 1, true
        ) ~= nil)
    end)

    it("uses the Sage Realtek BlueZ startup and shutdown path", function()
        device.model = "Kobo_cadmus"
        device.isMTK = function() return false end

        assert.is_true(bluetooth.isAvailable())
        assert.is_false(bluetooth.getState())
        assert.is_true(bluetooth.setEnabled(true))
        assert.is_true(bluetooth.getState())
        assert.are.equal(0, wifi_restored)

        local all_commands = table.concat(commands, "\n")
        assert.is_true(all_commands:find("rfkill/rfkill0/state", 1, true) ~= nil)
        assert.is_true(all_commands:find("rtk_hciattach -n -s 115200 /dev/ttyS1 rtk_h5", 1, true) ~= nil)
        assert.is_true(all_commands:find("--dest=org.bluez", 1, true) ~= nil)
        assert.is_nil(all_commands:find("--dest=com.kobo.mtk.bluedroid", 1, true))

        assert.is_true(bluetooth.setEnabled(false))
        assert.is_false(bluetooth.getState())
        assert.are.equal(1, allowed)
        assert.is_true(table.concat(commands, "\n"):find("echo 0 > "
            .. "/sys/devices/platform/bt/rfkill/rfkill0/state", 1, true) ~= nil)
    end)

    it("keeps the control off unsupported devices", function()
        device.isKobo = function() return false end
        assert.is_false(bluetooth.isAvailable())
        assert.is_nil(bluetooth.getState())
        assert.is_false(bluetooth.setEnabled(true))
        assert.are.equal(0, #commands)
    end)

    it("uses an active Kobo plugin for its Bluetooth lifecycle", function()
        local calls = {}
        _G.__ZEN_UI_PLUGIN = { ui = { kobo_plugin = { kobo_bluetooth = {
            isDeviceSupported = function() return true end,
            isBluetoothEnabled = function() return false end,
            turnBluetoothOn = function(_self, resume) calls[#calls + 1] = resume end,
        } } } }
        assert.is_true(bluetooth.setEnabled(true))
        assert.are.same({ false }, calls)
        assert.are.equal(0, #commands)
    end)
end)
