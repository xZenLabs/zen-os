describe("Bluetooth device adapters", function()
    local originals, popen_stub, execute_stub, commands, scheduled, unscheduled

    before_each(function()
        originals = {}
        for _i, name in ipairs({
            "ui/uimanager", "libopenlipclua", "common/zen_logger", "modules/menu/bluetooth_adapters/common",
            "modules/menu/bluetooth_adapters/kindle", "modules/menu/bluetooth_adapters/pocketbook",
            "device", "liblipclua", "modules/menu/bluetooth/bluetooth",
            "modules/menu/bluetooth/kobo_bluetooth", "modules/menu/bluetooth_switcher",
            "modules/menu/bluetooth/bluez", "common/hid_keys",
            "modules/menu/bluetooth_adapters/kindle_hid", "common/restart", "ui/event",
            "ui/widget/confirmbox", "ui/widget/infomessage",
        }) do originals[name] = package.loaded[name] or false end
        commands, scheduled, unscheduled = {}, {}, {}
        ZenSpec.replace("ui/uimanager", {
            broadcastEvent = function() end,
            forceRePaint = function() end,
            scheduleIn = function(_self, delay, callback)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end,
            unschedule = function(_self, callback) unscheduled[#unscheduled + 1] = callback end,
        })
        ZenSpec.unload("modules/menu/bluetooth_adapters/common")
        ZenSpec.unload("modules/menu/bluetooth_adapters/kindle")
        ZenSpec.unload("modules/menu/bluetooth_adapters/pocketbook")
    end)

    after_each(function()
        if popen_stub then popen_stub:revert(); popen_stub = nil end
        if execute_stub then execute_stub:revert(); execute_stub = nil end
        for name, module in pairs(originals) do package.loaded[name] = module or nil end
    end)

    it("manages PocketBook devices over D-Bus and pairs through bluetoothctl", function()
        local paired, queries = false, {}
        popen_stub = stub(io, "popen", function(command)
            queries[#queries + 1] = command
            local output = "method return time=0 sender=:1.1\n"
            if command:find("GetManagedObjects", 1, true) then
                output = output .. table.concat({
                    ' object path "/org/bluez/hci0/dev_11_22_33_44_55_66"', '  string "org.bluez.Device1"',
                    '   string "Address"', '    variant string "11:22:33:44:55:66"',
                    '   string "Name"', '    variant string "Page turner"',
                    '   string "Class"', '    variant uint32 9536',
                    '   string "Paired"', '    variant boolean ' .. tostring(paired),
                    '   string "Connected"', '    variant boolean ' .. tostring(paired),
                }, "\n")
            elseif command:find("Device1.Connect", 1, true) then
                output = "Error org.bluez.Error.AlreadyConnected: Already Connected"
            elseif command:find("RemoveDevice", 1, true) then
                paired = false
            end
            return { read = function() return output end, close = function() return 0 end }
        end)
        execute_stub = stub(os, "execute", function(command)
            commands[#commands + 1] = command
            if command:find(" pair '", 1, true) then paired = true end
            return 0
        end)
        local adapter = require("modules/menu/bluetooth_adapters/pocketbook").new()
        local devices = adapter.getDeviceList()
        assert.are.same({ "Page turner", false, true, false },
            { devices[1].name, devices[1].paired, devices[1].hid, devices[1].le })
        local results = {}
        local function record(ok) results[#results + 1] = ok end
        adapter.pair(devices[1], record)
        assert.is_truthy(commands[1]:find("--agent NoInputNoOutput", 1, true))
        assert.is_truthy(queries[#queries]:find("string:Trusted variant:boolean:true", 1, true))
        adapter.connect(devices[1], record)
        adapter.forget(devices[1], record)
        assert.are.same({ true, true, true }, results)
        local count = #queries
        adapter.connect({ address = "11:22:33:44:55:66'; reboot" }, record)
        assert.is_false(results[4])
        assert.are.same({ 1, count }, { #commands, #queries })
    end)

    it("falls back to bluetoothctl without D-Bus and rejects unsafe addresses", function()
        local paired = false
        popen_stub = stub(io, "popen", function(command)
            local output = command:find("dbus-send", 1, true) and "sh: dbus-send: not found"
                or command:find("devices", 1, true) and "Device 11:22:33:44:55:66 Page turner\n"
                or "Device 11:22:33:44:55:66 (random)\n\tAlias: Page turner\n\tIcon: input-keyboard\n\tPaired: "
                    .. (paired and "yes" or "no") .. "\n\tConnected: no\n"
            return { read = function() return output end, close = function() return 0 end }
        end)
        execute_stub = stub(os, "execute", function(command)
            commands[#commands + 1] = command
            if command:find(" pair '", 1, true) then paired = true end
            return 0
        end)
        local adapter = require("modules/menu/bluetooth_adapters/pocketbook").new()
        local devices = adapter.getDeviceList()
        assert.are.same({ "Page turner", false, true, true },
            { devices[1].name, devices[1].paired, devices[1].hid, devices[1].le })
        local result
        adapter.pair(devices[1], function(ok) result = ok end)
        assert.is_true(result)
        assert.is_truthy(commands[1]:find("--agent NoInputNoOutput", 1, true))
        assert.is_truthy(commands[2]:find("bluetoothctl trust '11:22:33:44:55:66'", 1, true))
        adapter.connect({ address = "11:22:33:44:55:66'; reboot" }, function(ok) result = ok end)
        assert.is_false(result)
        assert.are.equal(2, #commands)
        local scan_results = {}
        adapter.scan(function(ok) scan_results[#scan_results + 1] = ok end)
        assert.are.equal(10, scheduled[1].delay)
        adapter.close()
        assert.are.equal(scheduled[1].callback, unscheduled[1])
        assert.is_true(commands[#commands]:find("scan off", 1, true) ~= nil)
        scheduled[1].callback()
        assert.are.same({ false }, scan_results)
    end)

    it("merges Kindle LIPC lists and applies device actions", function()
        local paired = false
        local connected = false
        local address = "AA:BB:CC:DD:EE:FF"
        ZenSpec.replace("libopenlipclua", { open_no_name = function()
            return {
                new_hasharray = function() return { destroy = function() end } end,
                access_hash_property = function(_self, _service, property)
                    local values = property == "ListDiscovered"
                        and {{ Address = address:lower(), Name = "Speaker", RSSI = "-40" }}
                        or property == "ListPaired" and (paired and {{ mac = address }} or {})
                        or property == "ListConnected" and (connected and {{ address = address }} or {})
                    return { to_table = function() return values end, destroy = function() end }
                end,
                set_int_property = function(_self, _service, property)
                    commands[#commands + 1] = property
                    return 1
                end,
                set_string_property = function(_self, _service, property, value)
                    commands[#commands + 1] = property .. ":" .. value
                    if property == "Bond" then paired = true end
                    if property == "Connect" then connected = true end
                    return 1
                end,
                close = function() end,
            }
        end })
        ZenSpec.replace("liblipclua", { init = function(name)
            assert.are.equal("com.github.koreader.zenui.bluetooth.scan", name)
            local scanning = false
            return {
                set_int_property = function(_self, _service, property, value)
                    commands[#commands + 1] = property .. ":" .. value
                    if property == "DiscoverA2DP" then scanning = value == 1 end
                    return 0
                end,
                close = function() assert.is_false(scanning) end,
            }
        end })
        local adapter = require("modules/menu/bluetooth_adapters/kindle").new()
        assert.are.same({}, adapter.getDeviceList(true)) -- known only: no discoveries
        local devices = adapter.getDeviceList()
        assert.are.equal(1, #devices)
        assert.are.equal(address, devices[1].address)
        assert.are.equal(address, devices[1].id)
        assert.are.equal("Speaker", devices[1].name)
        assert.are.equal(-40, devices[1].rssi)
        local result
        adapter.pair(devices[1], function(ok) result = ok end)
        assert.is_true(result)
        adapter.connect(devices[1], function(ok) result = ok end)
        assert.is_true(result)
        assert.are.same({ "Bond:" .. address, "Connect:" .. address }, commands)
        local scan_results = {}
        adapter.scan(function(ok) scan_results[#scan_results + 1] = ok end)
        assert.are.equal("DiscoverA2DP:1", commands[3])
        assert.are.equal(10, scheduled[1].delay)
        adapter.close()
        assert.are.equal(scheduled[1].callback, unscheduled[1])
        assert.are.equal("DiscoverA2DP:0", commands[4])
        scheduled[1].callback()
        assert.are.same({ false }, scan_results)
        local next_adapter = require("modules/menu/bluetooth_adapters/kindle").new()
        next_adapter.scan(function(ok) scan_results[#scan_results + 1] = ok end)
        scheduled[2].callback()
        assert.are.same({ false, true }, scan_results)
        assert.are.same({ "DiscoverA2DP:1", "DiscoverA2DP:0" }, { commands[5], commands[6] })
        next_adapter.close()
    end)

    it("disconnects Kindle devices before powering off after a scan", function()
        local scanning, connected, powered, disconnect_requested = false, true, true, false
        ZenSpec.replace("device", { isKindle = function() return true end })
        ZenSpec.replace("modules/menu/bluetooth/kobo_bluetooth", {})
        ZenSpec.replace("modules/menu/bluetooth_switcher", {})
        ZenSpec.replace("libopenlipclua", { open_no_name = function()
            return {
                new_hasharray = function() return { destroy = function() end } end,
                access_hash_property = function(_self, _service, property)
                    return {
                        to_table = function()
                            if property == "ListDiscovered" and scanning then
                                return {{ Address = "AA:BB:CC:DD:EE:FF", Name = "Speaker" }}
                            end
                            if property == "ListConnected" and connected then
                                return {{ Address = "AA:BB:CC:DD:EE:FF", Name = "Speaker" }}
                            end
                            return {}
                        end,
                        destroy = function() end,
                    }
                end,
                set_string_property = function(_self, _service, property)
                    if property == "Disconnect" then disconnect_requested = true end
                end,
                close = function() end,
            }
        end })
        ZenSpec.replace("liblipclua", { init = function()
            return {
                get_int_property = function(_self, _service, property)
                    return property == "BTstate" and (powered and 1 or 0) or 0
                end,
                set_int_property = function(_self, _service, property, value)
                    if property == "DiscoverA2DP" then scanning = value == 1 end
                end,
                set_string_property = function(_self, _service, property, value)
                    if property == "BTenable" then
                        assert.is_false(scanning)
                        assert.is_false(connected)
                        powered = value == "1:1"
                    end
                end,
                close = function() end,
            }
        end })
        ZenSpec.unload("modules/menu/bluetooth/bluetooth")
        local Bluetooth = require("modules/menu/bluetooth/bluetooth")
        local adapter = require("modules/menu/bluetooth_adapters/kindle").new()
        local found
        adapter.scan(function(ok)
            assert.is_true(ok)
            local devices = adapter.getDeviceList()
            found = devices[1] and devices[1].name
        end)
        scheduled[1].callback()
        assert.are.equal("Speaker", found)
        assert.is_false(scanning)
        local result
        Bluetooth.setEnabled(false, function(ok) result = ok end)
        assert.is_true(disconnect_requested)
        assert.is_true(powered)
        assert.is_nil(result)
        connected = false
        scheduled[2].callback()
        assert.is_false(connected)
        assert.is_false(powered)
        assert.is_true(result)
    end)

    it("accepts empty Kindle hash replies alongside paired devices", function()
        ZenSpec.replace("libopenlipclua", { open_no_name = function()
            return {
                new_hasharray = function() return { destroy = function() end } end,
                access_hash_property = function(_self, _service, property)
                    if property ~= "ListPaired" then return nil end
                    return {
                        to_table = function() return {{ Address = "AA:BB:CC:DD:EE:FF" }} end,
                        destroy = function() end,
                    }
                end,
                close = function() end,
            }
        end })
        local devices, err = require("modules/menu/bluetooth_adapters/kindle").new().getDeviceList()
        assert.is_nil(err)
        assert.are.equal(1, #devices)
        assert.is_true(devices[1].paired)
    end)

    it("reads Kindle bd fields without treating every list entry as connected", function()
        ZenSpec.replace("libopenlipclua", { open_no_name = function()
            return {
                new_hasharray = function() return { destroy = function() end } end,
                access_hash_property = function()
                    return {
                        to_table = function() return {{
                            bd_address = "AA:BB:CC:DD:EE:FF", bd_name = "Page turner",
                            is_paired = 1, is_connected = 0,
                        }} end,
                        destroy = function() end,
                    }
                end,
                close = function() end,
            }
        end })
        local devices, err = require("modules/menu/bluetooth_adapters/kindle").new().getDeviceList()
        assert.is_nil(err)
        assert.are.equal(1, #devices)
        assert.are.equal("Page turner", devices[1].name)
        assert.is_true(devices[1].paired)
        assert.is_false(devices[1].connected)
    end)

    it("takes Kindle link state from the paired and connected lists, not stale discoveries", function()
        local gone, known = "AA:BB:CC:DD:EE:01", "AA:BB:CC:DD:EE:02"
        local replies = {
            ListDiscovered = {
                { bd_address = gone, bd_name = "Failed pair", is_paired = 1, is_connected = 1 },
                { bd_address = known, bd_name = "Speaker", is_paired = 1, is_connected = 1 },
            },
            ListPaired = {{ bd_address = known, bd_name = "Speaker", is_paired = 1, is_connected = 0 }},
        }
        ZenSpec.replace("libopenlipclua", { open_no_name = function()
            return {
                new_hasharray = function() return { destroy = function() end } end,
                access_hash_property = function(_self, _service, property)
                    if not replies[property] then return nil end
                    return { to_table = function() return replies[property] end, destroy = function() end }
                end,
                close = function() end,
            }
        end })
        local devices, err = require("modules/menu/bluetooth_adapters/kindle").new().getDeviceList()
        assert.is_nil(err)
        assert.are.equal(2, #devices)
        assert.are.equal("Failed pair", devices[1].name)
        assert.is_nil(devices[1].paired)
        assert.is_nil(devices[1].connected)
        assert.is_true(devices[2].paired)
        assert.is_false(devices[2].connected)
    end)

    it("keeps captured HID metadata for devices btfd also discovered", function()
        local address = "AA:BB:CC:DD:EE:FF"
        ZenSpec.replace("libopenlipclua", { open_no_name = function()
            return {
                new_hasharray = function() return { destroy = function() end } end,
                access_hash_property = function(_self, _service, property)
                    if property ~= "ListDiscovered" then return nil end
                    return {
                        to_table = function() return {{ Address = address, Name = "Remote" }} end,
                        destroy = function() end,
                    }
                end,
                close = function() end,
            }
        end })
        local adapter = require("modules/menu/bluetooth_adapters/kindle").new()
        adapter.hid_found = {{ address = address, hid = true, le = true }}
        local devices, err = adapter.getDeviceList()
        assert.is_nil(err)
        assert.are.equal(1, #devices)
        assert.are.equal("Remote", devices[1].name)
        assert.is_true(devices[1].hid)
        assert.is_true(devices[1].le)
    end)

    it("captures HID devices with every Kindle scan where supported", function()
        local address = "AA:BB:CC:DD:EE:FF"
        ZenSpec.replace("modules/menu/bluetooth_adapters/kindle_hid", {
            isSupported = function() return true end,
            startCapture = function() commands[#commands + 1] = "capture:1" end,
            finishCapture = function()
                commands[#commands + 1] = "capture:0"
                return {{ address = address, name = "Remote", hid = true, le = true }}
            end,
            bonded = function() return {} end,
        })
        ZenSpec.replace("libopenlipclua", { open_no_name = function()
            return {
                new_hasharray = function() return { destroy = function() end } end,
                access_hash_property = function() return nil end,
                close = function() end,
            }
        end })
        ZenSpec.replace("liblipclua", { init = function()
            return {
                set_int_property = function(_self, _service, property, value)
                    commands[#commands + 1] = property .. ":" .. value
                    return 0
                end,
                close = function() end,
            }
        end })
        local adapter = require("modules/menu/bluetooth_adapters/kindle").new()
        local devices
        adapter.scan(function(ok) devices = ok and adapter.getDeviceList() end)
        assert.are.same({ "capture:1" }, commands) -- live before the inquiry starts
        assert.are.equal(2, scheduled[1].delay)
        scheduled[1].callback()
        scheduled[2].callback()
        assert.are.same({ "capture:1", "DiscoverA2DP:1", "capture:0", "DiscoverA2DP:0" }, commands)
        assert.are.equal(1, #devices)
        assert.are.equal("Remote", devices[1].name)
        assert.is_true(devices[1].hid)
        adapter.scan(function() end) -- finds end with their scan, even if the next one is cancelled
        adapter.cancelScan()
        assert.are.same({}, adapter.getDeviceList())
    end)

    it("restarts the whole Kindle under the restart notice, without the sleep screen", function()
        local UIManager, action = package.loaded["ui/uimanager"], nil
        ZenSpec.replace("common/restart", { request = function(opts) action = opts.action end })
        ZenSpec.replace("ui/event", { new = function(_self, name) return name end })
        ZenSpec.replace("device", { saveSettings = function() commands[#commands + 1] = "save" end })
        UIManager.broadcastEvent = function(_self, event) commands[#commands + 1] = event end
        UIManager.quit = function() commands[#commands + 1] = "quit" end
        UIManager.reboot_action = function() error("sleep screen shown") end
        execute_stub = stub(os, "execute", function(command) commands[#commands + 1] = command end)
        require("modules/menu/bluetooth_adapters/kindle").new().reboot()
        assert.are.same({}, commands) -- nothing until the notice has painted
        action()
        assert.is_true(UIManager._entered_poweroff_stage) -- no "Restoring Kindle GUI" screen
        assert.are.same({ "Reboot", "Close", "save", "sleep 1 && reboot &", "quit" }, commands)
    end)

    it("uninstalls Kindle HID Passthrough on request and restarts only once it is gone", function()
        local shown, removed, rebooted, declined, gone = {}, 0, 0, 0, false
        local UIManager = package.loaded["ui/uimanager"]
        UIManager.show = function(_self, widget) shown[#shown + 1] = widget end
        UIManager.close = function(_self, widget) widget.closed = true end
        UIManager.tickAfterNext = function(_self, callback) callback() end
        ZenSpec.replace("ui/widget/confirmbox", { new = function(_self, spec) return spec end })
        ZenSpec.replace("ui/widget/infomessage", { new = function(_self, spec) return spec end })
        ZenSpec.replace("modules/menu/bluetooth_adapters/kindle_hid", {
            passthrough = function() return true end,
            removePassthrough = function() removed = removed + 1; return gone end,
            reboot = function() rebooted = rebooted + 1 end,
        })
        local Kindle = require("modules/menu/bluetooth_adapters/kindle")
        assert.is_true(Kindle.conflict() and Kindle.isAvailable())
        Kindle.resolveConflict(function() declined = declined + 1 end)
        shown[1].cancel_callback()
        assert.are.same({ 1, 0 }, { declined, removed })
        shown[1].ok_callback()
        assert.is_true(shown[2].closed) -- the "Uninstalling…" notice
        assert.is_truthy(shown[3].text:find("Could not uninstall", 1, true))
        assert.are.same({ 1, 0 }, { removed, rebooted })
        gone = true
        shown[1].ok_callback()
        assert.are.same({ 2, 1, 4 }, { removed, rebooted, #shown })
    end)

    it("confirms a Kindle HID connect from its input node and fails unconfirmed", function()
        local address, linked, rescans = "AA:BB:CC:DD:EE:FF", false, 0
        ZenSpec.replace("common/hid_keys", {
            rescan = function() rescans = rescans + 1 end,
            connected = function(candidate) return linked and candidate == address end,
        })
        ZenSpec.replace("libopenlipclua", { open_no_name = function()
            return {
                new_hasharray = function() return { destroy = function() end } end,
                access_hash_property = function(_self, _service, property)
                    if property ~= "ListPaired" then return nil end
                    return {
                        to_table = function() return {{ Address = address }} end,
                        destroy = function() end,
                    }
                end,
                set_string_property = function(_self, _service, property)
                    commands[#commands + 1] = property
                end,
                close = function() end,
            }
        end })
        local adapter = require("modules/menu/bluetooth_adapters/kindle").new()
        local results = {}
        local function done(ok) results[#results + 1] = ok end
        adapter.connect({ address = address, hid = true }, done)
        assert.are.same({}, results) -- btfd lists no link and no node is open yet
        linked = true
        scheduled[1].callback()
        assert.are.same({ true }, results)
        assert.are.equal(2, rescans)
        assert.are.same({}, commands) -- no A2DP Connect for HID
        linked = false
        adapter.connect({ address = address, hid = true }, done)
        for index = 2, 10 do scheduled[index].callback() end
        assert.are.same({ true, false }, results)
    end)

    it("reports unsupported Kindle hash properties", function()
        ZenSpec.replace("libopenlipclua", {})
        local adapter = require("modules/menu/bluetooth_adapters/kindle").new()
        local devices, err = adapter.getDeviceList()
        assert.is_nil(devices)
        assert.is_truthy(err:find("not supported", 1, true))
    end)

    it("rejects unknown Kindle device schemas instead of showing an empty list", function()
        local warnings = {}
        ZenSpec.replace("common/zen_logger", { new = function()
            return { info = function() end, warn = function(...)
                local parts = {}
                for _i, part in ipairs({ ... }) do parts[#parts + 1] = tostring(part) end
                warnings[#warnings + 1] = table.concat(parts, " ")
            end }
        end })
        ZenSpec.replace("libopenlipclua", { open_no_name = function()
            return {
                new_hasharray = function() return { destroy = function() end } end,
                access_hash_property = function(_self, _service, property)
                    return {
                        to_table = function()
                            return property == "ListDiscovered" and {{ unknown = "device" }} or {}
                        end,
                        destroy = function() end,
                    }
                end,
                close = function() end,
            }
        end })
        local devices, err = require("modules/menu/bluetooth_adapters/kindle").new().getDeviceList()
        assert.is_nil(devices)
        assert.is_truthy(err:find("not supported", 1, true))
        assert.is_truthy(warnings[1]:find("ListDiscovered reply shape", 1, true))
        assert.is_truthy(warnings[1]:find("unknown:string", 1, true))
    end)

    it("bounds state verification and cancels pending callbacks", function()
        local Common = require("modules/menu/bluetooth_adapters/common")
        local adapter = { getDeviceList = function()
            return {{ address = "11:22:33:44:55:66", connected = false }}
        end }
        local results = {}
        Common.verify(adapter, "11:22:33:44:55:66", "connected", true,
            function(ok) results[#results + 1] = ok end)
        assert.are.equal(0.5, scheduled[1].delay)
        Common.close(adapter)
        scheduled[1].callback()
        assert.are.same({ false }, results)
        assert.are.equal(1, #scheduled)
    end)
end)
