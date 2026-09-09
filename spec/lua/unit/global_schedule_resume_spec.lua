describe("global schedule resume hook", function()
    local global
    local device
    local ui_manager
    local scheduled
    local original_reader_settings
    local patched_modules = {
        "modules/global/patches/night_mode_schedule",
        "modules/global/patches/warmth_schedule",
        "modules/global/patches/brightness_schedule",
        "modules/global/patches/menu_top_swipe",
        "modules/global/patches/opds",
        "modules/global/patches/kindle_network_profile_guard",
        "modules/global/patches/lockdown_mode",
        "modules/global/patches/incognito_mode",
        "modules/global/patches/menu_font",
        "modules/global/patches/unified_title_style",
    }

    before_each(function()
        original_reader_settings = _G.G_reader_settings
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
        ZenSpec.unload("modules/global/global")
        global = require("modules/global/global")
    end)

    after_each(function()
        for _i, name in ipairs(patched_modules) do
            ZenSpec.unload(name)
        end
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

    it("does not reapply schedules for unrelated broadcasts", function()
        assert.is_true(global.init(nil, { config = { features = {} } }))

        ui_manager:broadcastEvent({ handler = "onCharging" })
        assert.are.equal(0, #scheduled)
        assert.is_nil(_G.night_reschedules)
        assert.is_nil(_G.brightness_reschedules)
        assert.is_nil(_G.warmth_reschedules)
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
