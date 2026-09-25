describe("Bluetooth device adapters", function()
    local originals, popen_stub, execute_stub, commands, scheduled, unscheduled

    before_each(function()
        originals = {}
        for _i, name in ipairs({
            "ui/uimanager", "libopenlipclua", "common/zen_logger", "modules/menu/bluetooth_adapters/common",
            "modules/menu/bluetooth_adapters/kindle", "modules/menu/bluetooth_adapters/pocketbook",
            "device", "liblipclua", "modules/menu/bluetooth/bluetooth",
            "modules/menu/bluetooth/kobo_bluetooth", "modules/menu/bluetooth_switcher",
        }) do originals[name] = package.loaded[name] or false end
        commands, scheduled, unscheduled = {}, {}, {}
        ZenSpec.replace("ui/uimanager", {
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

    it("reads PocketBook devices and rejects unsafe addresses", function()
        local paired = false
        popen_stub = stub(io, "popen", function(command)
            local output = command:find("devices", 1, true)
                and "Device 11:22:33:44:55:66 Page turner\n"
                or "Device 11:22:33:44:55:66\n\tAlias: Page turner\n\tPaired: "
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
        assert.are.equal("Page turner", devices[1].name)
        assert.is_false(devices[1].paired)
        local result
        adapter.pair(devices[1], function(ok) result = ok end)
        assert.is_true(result)
        assert.is_truthy(commands[1]:find("--agent NoInputNoOutput", 1, true))
        assert.is_true(commands[1]:find("'11:22:33:44:55:66'", 1, true) ~= nil)
        adapter.connect({ address = "11:22:33:44:55:66'; reboot" }, function(ok) result = ok end)
        assert.is_false(result)
        assert.are.equal(1, #commands)
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
                        and {{ Address = address, Name = "Speaker", RSSI = "-40" }}
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
        local devices = adapter.getDeviceList()
        assert.are.equal(1, #devices)
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
