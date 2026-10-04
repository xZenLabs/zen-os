describe("global schedule resume hook", function()
    local global
    local device
    local ui_manager
    local scheduled
    local responsive_keyboard_applies
    local original_reader_settings
    local original_kobo_bluetooth
    local original_kobo_network
    local original_network_manager
    local kobo_network_installs
    local patched_modules = {
        "modules/global/patches/night_mode_schedule",
        "modules/global/patches/warmth_schedule",
        "modules/global/patches/brightness_schedule",
        "modules/global/patches/menu_top_swipe",
        "modules/global/patches/opds",
        "modules/global/patches/kindle_autosuspend_resume",
        "modules/global/patches/kindle_network_profile_guard",
        "modules/global/patches/nonblocking_wifi",
        "modules/global/patches/lockdown_mode",
        "modules/global/patches/incognito_mode",
        "modules/global/patches/menu_font",
        "modules/global/patches/unified_title_style",
        "modules/global/patches/responsive_keyboard",
    }

    before_each(function()
        original_reader_settings = _G.G_reader_settings
        original_kobo_bluetooth = package.loaded["modules/menu/bluetooth/kobo_bluetooth"]
        original_kobo_network = package.loaded["modules/menu/network_adapters/kobo"]
        original_network_manager = package.loaded["ui/network/manager"]
        ZenSpec.replace("ui/network/manager", {})
        kobo_network_installs = 0
        ZenSpec.replace("modules/menu/network_adapters/kobo", { install = function()
            kobo_network_installs = kobo_network_installs + 1
        end })
        _G.__ZEN_UI_NIGHT_SCHEDULE = { force_reschedule = function()
            _G.night_reschedules = (_G.night_reschedules or 0) + 1
        end }
        _G.__ZEN_UI_BRIGHTNESS_SCHEDULE = { force_reschedule = function()
            _G.brightness_reschedules = (_G.brightness_reschedules or 0) + 1
        end }
        _G.__ZEN_UI_WARMTH_SCHEDULE = { force_reschedule = function()
            _G.warmth_reschedules = (_G.warmth_reschedules or 0) + 1
        end }
        _G.night_reschedules = nil
        _G.brightness_reschedules = nil
        _G.warmth_reschedules = nil
        scheduled = {}
        responsive_keyboard_applies = 0

        ui_manager = {
            broadcastEvent = function(_, event)
                return event.handler == "onResume"
            end,
            setDirty = function() end,
            scheduleIn = function(_, delay, callback)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end,
            unschedule = function(_, callback)
                for index = #scheduled, 1, -1 do
                    if scheduled[index].callback == callback then table.remove(scheduled, index) end
                end
            end,
        }
        ZenSpec.replace("ui/uimanager", ui_manager)
        device = {
            canHWInvert = function() return false end,
        }
        ZenSpec.replace("device", device)
        for _i, name in ipairs(patched_modules) do
            ZenSpec.replace(name, function() end)
        end
        ZenSpec.replace("modules/global/patches/responsive_keyboard", function()
            responsive_keyboard_applies = responsive_keyboard_applies + 1
        end)
        ZenSpec.unload("modules/global/patches/kobo_bluetooth_fix")
        ZenSpec.unload("modules/global/global")
        global = require("modules/global/global")
    end)

    after_each(function()
        for _i, name in ipairs(patched_modules) do
            ZenSpec.unload(name)
        end
        ZenSpec.unload("modules/global/patches/kobo_bluetooth_fix")
        ZenSpec.unload("modules/global/global")
        ZenSpec.unload("ui/uimanager")
        ZenSpec.unload("device")
        _G.__ZEN_UI_NIGHT_SCHEDULE = nil
        _G.__ZEN_UI_BRIGHTNESS_SCHEDULE = nil
        _G.__ZEN_UI_WARMTH_SCHEDULE = nil
        _G.night_reschedules = nil
        _G.brightness_reschedules = nil
        _G.warmth_reschedules = nil
        _G.G_reader_settings = original_reader_settings
        package.loaded["modules/menu/bluetooth/kobo_bluetooth"] = original_kobo_bluetooth
        package.loaded["modules/menu/network_adapters/kobo"] = original_kobo_network
        package.loaded["ui/network/manager"] = original_network_manager
    end)

    it("leaves Kobo device shutdown unchanged", function()
        local calls = {}
        device.isKobo = function() return true end
        local exit = function(self, code)
            assert.are.equal(device, self)
            calls[#calls + 1] = "exit"
            return code, "finished"
        end
        device.exit = exit
        local plugin = { config = { features = {} } }
        assert.is_true(global.init(nil, plugin))
        assert.is_true(global.init(nil, plugin))
        assert.are.equal(1, kobo_network_installs)
        assert.is_nil(package.loaded["modules/global/patches/kobo_bluetooth_fix"])
        assert.are.equal(exit, device.exit)
        assert.are.same({}, calls)

        local code, result = device:exit(85)

        assert.are.same({ "exit" }, calls)
        assert.are.equal(85, code)
        assert.are.equal("finished", result)
    end)

    it("leaves non-Kobo device shutdown unchanged", function()
        device.isKobo = function() return false end
        device.isMTK = function() return true end
        local exit = function() return "finished" end
        device.exit = exit
        assert.is_true(global.init(nil, { config = { features = {} } }))

        assert.are.equal(0, kobo_network_installs)
        assert.is_nil(package.loaded["modules/global/patches/kobo_bluetooth_fix"])
        assert.are.equal(exit, device.exit)
        assert.are.equal("finished", device:exit())
    end)

    it("reboots on normal MTK exit after Bluetooth use without recursing", function()
        local used_bluetooth = false
        local quits, reboots = {}, 0
        device.isKobo = function() return true end
        device.isMTK = function() return true end
        device.exit = function() return "finished" end
        local exit = device.exit
        ui_manager.quit = function(_self, code, implicit)
            quits[#quits + 1] = { code, implicit }
            return code
        end
        ui_manager.reboot_action = function()
            reboots = reboots + 1
            ui_manager._entered_poweroff_stage = true
            ui_manager:scheduleIn(0, function() ui_manager:quit(88) end)
        end
        ZenSpec.replace("modules/menu/bluetooth/kobo_bluetooth", {
            needsRebootOnExit = function() return used_bluetooth end,
        })
        local plugin = { config = { features = {} } }
        assert.is_true(global.init(nil, plugin))
        assert.is_true(global.init(nil, plugin))
        assert.is_function(package.loaded["modules/global/patches/kobo_bluetooth_fix"])
        assert.are.equal(exit, device.exit)

        local patched_quit = ui_manager.quit
        require("modules/global/patches/kobo_bluetooth_fix")()
        assert.are.equal(patched_quit, ui_manager.quit)

        assert.are.equal(0, ui_manager:quit(0, true))
        assert.are.equal(0, reboots)
        used_bluetooth = true
        assert.is_nil(ui_manager:quit(nil, true))
        assert.are.equal(1, reboots)
        assert.are.same({ { 0, true } }, quits)
        scheduled[1].callback()
        assert.are.same({ { 0, true }, { 88 } }, quits)
        assert.are.equal("finished", device:exit())
    end)

    it("preserves special exit codes and an existing shutdown on MTK", function()
        device.isKobo = function() return true end
        device.isMTK = function() return true end
        device.exit = function() end
        ui_manager.quit = function(_self, code) return code end
        ui_manager.reboot_action = function() error("unexpected reboot") end
        ZenSpec.replace("modules/menu/bluetooth/kobo_bluetooth", {
            needsRebootOnExit = function() return true end,
        })
        assert.is_true(global.init(nil, { config = { features = {} } }))

        for _i, code in ipairs({ 85, 86, 88, false }) do
            assert.are.equal(code, ui_manager:quit(code))
        end
        ui_manager._exit_code = 85
        assert.is_nil(ui_manager:quit())
        ui_manager._entered_poweroff_stage = true
        assert.are.equal(0, ui_manager:quit(0))
    end)

    it("does not change normal exit on non-MTK Kobos", function()
        device.isKobo = function() return true end
        device.isMTK = function() return false end
        device.exit = function() end
        local quit = function() return 0 end
        ui_manager.quit = quit
        assert.is_true(global.init(nil, { config = { features = {} } }))

        assert.is_nil(package.loaded["modules/global/patches/kobo_bluetooth_fix"])
        assert.are.equal(quit, ui_manager.quit)
    end)

    it("retries frontlight schedules after Resume even when another widget handled it", function()
        assert.is_true(global.init(nil, { config = { features = {} } }))

        assert.is_true(ui_manager:broadcastEvent({ handler = "onResume" }))
        assert.are.equal(2, #scheduled)
        assert.are.equal(0.1, scheduled[1].delay)
        assert.are.equal(1.5, scheduled[2].delay)
        assert.is_nil(_G.night_reschedules)
        scheduled[1].callback()
        scheduled[2].callback()
        assert.are.equal(1, _G.night_reschedules)
        assert.are.equal(2, _G.brightness_reschedules)
        assert.are.equal(2, _G.warmth_reschedules)
    end)

    it("applies Zen Keyboard by default", function()
        assert.is_true(global.init(nil, { config = { features = {} } }))
        assert.are.equal(1, responsive_keyboard_applies)
    end)

    it("avoids redundant Kindle frontlight writes on resume but applies changed values", function()
        local intensity_writes, warmth_writes = 0, 0
        device.isKindle = function() return true end
        device.hasFrontlight = function() return true end
        device.hasNaturalLight = function() return true end
        device.screen = { night_mode = false }
        device.powerd = setmetatable({
            device = device,
            fl_max = 24,
            fl_intensity = 9,
            fl_warmth_max = 24,
            warmth_scale = 100 / 24,
            fl_warmth = 33,
            is_fl_on = true,
            setIntensityHW = function() intensity_writes = intensity_writes + 1 end,
            setWarmthHW = function() warmth_writes = warmth_writes + 1 end,
            stateChanged = function() end,
        }, { __index = require("device/generic/powerd") })
        _G.__ZEN_UI_BRIGHTNESS_SCHEDULE = nil
        _G.__ZEN_UI_WARMTH_SCHEDULE = nil
        ZenSpec.unload("modules/global/patches/brightness_schedule")
        ZenSpec.unload("modules/global/patches/warmth_schedule")
        local plugin = { config = {
            features = {},
            brightness_schedule = { use_mode_values = true, day_value = 9 },
            warmth_schedule = { use_mode_values = true, day_value = 8 },
        } }
        assert.is_true(global.init(nil, plugin))
        assert.are.equal(0, intensity_writes)
        assert.are.equal(0, warmth_writes)

        ui_manager:broadcastEvent({ handler = "onResume" })
        scheduled[1].callback()
        scheduled[2].callback()
        assert.are.equal(0, intensity_writes)
        assert.are.equal(0, warmth_writes)
        assert.are.equal(1, _G.night_reschedules)

        plugin.config.brightness_schedule.day_value = 12
        plugin.config.warmth_schedule.day_value = 10
        ui_manager:broadcastEvent({ handler = "onResume" })
        scheduled[1].callback()
        scheduled[2].callback()
        assert.are.equal(1, intensity_writes)
        assert.are.equal(1, warmth_writes)
        assert.are.equal(12, device.powerd.fl_intensity)
        assert.are.equal(42, device.powerd.fl_warmth)
    end)

    it("skips Zen Keyboard when disabled", function()
        assert.is_true(global.init(nil, {
            config = { features = { zen_keyboard = false } },
        }))
        assert.are.equal(0, responsive_keyboard_applies)
    end)

    it("does not reapply schedules for unrelated broadcasts", function()
        assert.is_true(global.init(nil, { config = { features = {} } }))

        ui_manager:broadcastEvent({ handler = "onCharging" })
        assert.are.equal(0, #scheduled)
        assert.is_nil(_G.night_reschedules)
        assert.is_nil(_G.brightness_reschedules)
        assert.is_nil(_G.warmth_reschedules)
    end)

    it("cancels pending resume retries on Suspend", function()
        assert.is_true(global.init(nil, { config = { features = {} } }))

        ui_manager:broadcastEvent({ handler = "onResume" })
        assert.are.equal(2, #scheduled)
        ui_manager:broadcastEvent({ handler = "onSuspend" })
        assert.are.equal(0, #scheduled)
    end)

    it("preserves KOReader's original hardware night mode for exit", function()
        local applied
        device.orig_hw_nightmode = true
        device.canHWInvert = function() return true end
        device.screen = {
            getHWNightmode = function() return true end,
            setHWNightmode = function(_, enabled) applied = enabled end,
        }

        assert.is_true(global.init(nil, { config = { features = {} } }))

        assert.is_false(applied)
        assert.is_true(device.orig_hw_nightmode)
    end)

    it("disables Zen OPDS when KOReader OPDS is disabled", function()
        local opds_applies = 0
        local config = { features = {} }
        local saved = 0
        _G.G_reader_settings = ZenSpec.memorySettings({
            plugins_disabled = { opds = true },
        })
        ZenSpec.replace("modules/global/patches/opds", function()
            opds_applies = opds_applies + 1
        end)

        assert.is_true(global.init(nil, {
            config = config,
            saveConfig = function() saved = saved + 1 end,
        }))

        assert.are.equal(0, opds_applies)
        assert.is_false(config.features.zen_opds)
        assert.are.equal(1, saved)
    end)
end)
