describe("Bluetooth state cache", function()
    local originals
    local state
    local reads

    before_each(function()
        originals = {}
        for _i, name in ipairs({
            "device", "modules/menu/bluetooth/kobo_bluetooth", "common/zen_logger", "modules/menu/bluetooth/bluetooth",
            "modules/menu/bluetooth_switcher", "ui/uimanager", "liblipclua",
        }) do
            originals[name] = package.loaded[name] or false
        end
        state, reads = false, 0
        ZenSpec.replace("device", { isKindle = function() return false end })
        ZenSpec.replace("modules/menu/bluetooth/kobo_bluetooth", {
            getState = function()
                reads = reads + 1
                return state
            end,
            isAvailable = function() return true end,
            onSuspend = function() end,
        })
        ZenSpec.replace("common/zen_logger", {
            new = function() return { info = function() end, warn = function() end } end,
        })
        ZenSpec.unload("modules/menu/bluetooth/bluetooth")
    end)

    after_each(function()
        for name, module in pairs(originals) do package.loaded[name] = module or nil end
    end)

    it("serves paint-time reads without querying hardware", function()
        local Bluetooth = require("modules/menu/bluetooth/bluetooth")
        assert.is_nil(Bluetooth.getCachedState())
        assert.is_false(Bluetooth.getState())
        assert.is_false(Bluetooth.getCachedState())
        assert.are.equal(1, reads)

        state = true
        assert.is_false(Bluetooth.getCachedState())
        assert.are.equal(1, reads)
        assert.is_true(Bluetooth.getState())
        assert.are.equal(2, reads)
    end)

    it("verifies PocketBook power changes and completes once", function()
        ZenSpec.replace("device", {
            isKindle = function() return false end,
            isPocketBook = function() return true end,
        })
        local enabled = false
        ZenSpec.replace("ui/uimanager", { scheduleIn = function(_self, _delay, callback)
            callback()
        end })
        local popen_stub = stub(io, "popen", function()
            return {
                read = function() return enabled and "BT_STATE_READY" or "BT_STATE_OFF" end,
                close = function() return 0 end,
            }
        end)
        local execute_stub = stub(os, "execute", function()
            enabled = true
            return 0
        end)
        ZenSpec.unload("modules/menu/bluetooth/bluetooth")
        local Bluetooth = require("modules/menu/bluetooth/bluetooth")
        local calls = 0
        assert.is_true(Bluetooth.setEnabled(true, function(ok)
            assert.is_true(ok)
            calls = calls + 1
        end))
        assert.are.equal(1, calls)
        assert.is_true(Bluetooth.isEnabled())
        execute_stub:revert()
        popen_stub:revert()
    end)

    it("uses BTenable for Kindle power changes and verifies the resulting state", function()
        ZenSpec.replace("device", { isKindle = function() return true end })
        local scheduled, requests = {}, {}
        local cancelled = false
        ZenSpec.replace("modules/menu/bluetooth_switcher", { cancelScan = function()
            cancelled = true
        end })
        local request_ok = true
        state = true
        ZenSpec.replace("ui/uimanager", { scheduleIn = function(_self, _delay, callback)
            scheduled[#scheduled + 1] = callback
        end })
        ZenSpec.replace("liblipclua", { init = function()
            return {
                get_int_property = function() return state and 1 or 0 end,
                set_string_property = function(_self, _service, property, value)
                    if property == "btPopupDone" or value == "0:1" then assert.is_true(cancelled) end
                    requests[#requests + 1] = { property, value }
                    if not request_ok then return -1 end
                    if property == "BTenable" then state = value == "1:1" end
                    return 0
                end,
                close = function() end,
            }
        end })
        local Bluetooth = require("modules/menu/bluetooth/bluetooth")
        local results = {}
        assert.is_true(Bluetooth.setEnabled(false, function(ok) results[#results + 1] = ok end))
        assert.is_true(cancelled)
        assert.are.same({ { "btPopupDone", "" }, { "BTenable", "0:1" } }, requests)
        assert.are.same({ true }, results)
        assert.are.equal(0, #scheduled)
        assert.is_false(Bluetooth.getState())
        assert.is_true(Bluetooth.setEnabled(true, function(ok) results[#results + 1] = ok end))
        assert.are.same({ { "btPopupDone", "" }, { "BTenable", "0:1" },
            { "BTenable", "1:1" } }, requests)
        assert.are.same({ true, true }, results)
        assert.is_true(Bluetooth.getState())

        request_ok = false
        local shell_requests = {}
        local execute_stub = stub(os, "execute", function(command)
            shell_requests[#shell_requests + 1] = command
            return 1
        end)
        local accepted = Bluetooth.setEnabled(false, function(ok) results[#results + 1] = ok end)
        execute_stub:revert()
        assert.is_false(accepted)
        assert.is_truthy(shell_requests[1]:find("btPopupDone ''", 1, true))
        assert.are.same({ true, true, false }, results)
        assert.is_true(Bluetooth.getState())
    end)

    it("falls back to Kindle flight mode only when BTenable stalls during discovery", function()
        ZenSpec.replace("device", { isKindle = function() return true end })
        local scheduled, requests = {}, {}
        local radio_on, flight_mode = true, false
        ZenSpec.replace("ui/uimanager", { scheduleIn = function(_self, _delay, callback)
            scheduled[#scheduled + 1] = callback
        end })
        ZenSpec.replace("liblipclua", { init = function()
            return {
                get_int_property = function() return radio_on and 1 or 0 end,
                set_string_property = function(_self, _service, property, value)
                    requests[#requests + 1] = { property, value }
                    if value == "1:1" and not flight_mode then radio_on = true end
                    return 0
                end,
                set_int_property = function(_self, _service, property, value)
                    requests[#requests + 1] = { property, value }
                    flight_mode = value == 1
                    radio_on = not flight_mode
                    return 0
                end,
                close = function() end,
            }
        end })
        local Bluetooth = require("modules/menu/bluetooth/bluetooth")
        local results = {}
        local function check_delayed_result(expected)
            for _i = 1, 5 do
                local callback = table.remove(scheduled, 1)
                assert.is_function(callback)
                callback()
            end
            assert.are.equal(expected, results[#results])
            assert.are.equal(0, #scheduled)
        end

        Bluetooth.setEnabled(false, function(ok) results[#results + 1] = ok end)
        assert.are.same({ { "btPopupDone", "" }, { "BTenable", "0:1" } }, requests)
        check_delayed_result(true)
        assert.are.same({ { "btPopupDone", "" }, { "BTenable", "0:1" },
            { "BTflightMode", 1 } }, requests)

        Bluetooth.setEnabled(true, function(ok) results[#results + 1] = ok end)
        assert.are.same({ { "btPopupDone", "" }, { "BTenable", "0:1" },
            { "BTflightMode", 1 }, { "BTenable", "1:1" } }, requests)
        check_delayed_result(true)
        assert.are.same({ { "btPopupDone", "" }, { "BTenable", "0:1" },
            { "BTflightMode", 1 }, { "BTenable", "1:1" }, { "BTflightMode", 0 } }, requests)
    end)
end)
