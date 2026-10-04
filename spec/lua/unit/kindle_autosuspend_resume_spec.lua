describe("Kindle AutoSuspend resume", function()
    local time = require("ui/time")
    local originals
    local Device, UIManager, AutoSuspend
    local scheduled, suspends, now, t1_resets
    local module_names = {
        "device", "ui/uimanager", "pluginloader", "ui/network/manager", "pluginshare",
        "modules/global/patches/kindle_autosuspend_resume",
    }

    before_each(function()
        originals = {}
        for _i, name in ipairs(module_names) do originals[name] = package.loaded[name] end
        scheduled, suspends, now, t1_resets = {}, 0, time.s(8094), 0
        local powerd = {
            isCharging = function() return false end,
            isCharged = function() return false end,
            resetT1Timeout = function() t1_resets = t1_resets + 1 end,
        }
        Device = {
            isKindle = function() return true end,
            canSuspend = function() return true end,
            canPowerOff = function() return false end,
            canStandby = function() return false end,
            hasAuxBattery = function() return false end,
            getPowerDevice = function() return powerd end,
        }
        UIManager = {
            getElapsedTimeSinceBoot = function() return now end,
            event_hook = require("ui/hook_container"):new(),
            scheduleIn = function(_self, delay, callback)
                assert.is_true(delay >= 0, "Only positive seconds allowed")
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end,
            unschedule = function(_self, callback)
                for index = #scheduled, 1, -1 do
                    if scheduled[index].callback == callback then table.remove(scheduled, index) end
                end
            end,
            suspend = function() suspends = suspends + 1 end,
        }
        ZenSpec.replace("device", Device)
        ZenSpec.replace("ui/uimanager", UIManager)
        ZenSpec.replace("ui/network/manager", {})
        ZenSpec.replace("pluginshare", {})
        AutoSuspend = dofile("plugins/autosuspend.koplugin/main.lua")
        ZenSpec.replace("pluginloader", { loadPlugins = function() return { AutoSuspend } end })
        ZenSpec.unload("modules/global/patches/kindle_autosuspend_resume")
    end)

    after_each(function()
        for _i, name in ipairs(module_names) do package.loaded[name] = originals[name] end
    end)

    it("stays awake when sleep accounting advances after the input hook", function()
        local autosuspend = setmetatable({
            auto_suspend_timeout_seconds = 900,
            auto_standby_timeout_seconds = -1,
            last_action_time = now,
            last_t1_reset_time = now,
        }, { __index = AutoSuspend })
        autosuspend.task = function() autosuspend:_schedule() end
        autosuspend.kindle_task = function() autosuspend:_schedule_kindle() end
        UIManager.event_hook:registerWidget("InputEvent", autosuspend)
        autosuspend:onSuspend()
        UIManager.event_hook:execute("InputEvent")
        now = now + time.s(16017)

        assert.has_error(function() autosuspend:onResume() end)
        assert.are.equal(1, suspends)
        suspends = 0

        require("modules/global/patches/kindle_autosuspend_resume")()
        autosuspend:onResume()

        assert.are.equal(0, suspends)
        assert.are.equal(now, autosuspend.last_action_time)
        assert.is_false(autosuspend.going_to_suspend)
        assert.are.equal(1, t1_resets)
        assert.are.equal(2, #scheduled)
        assert.are.equal(900, scheduled[1].delay)
        assert.are.equal(240, scheduled[2].delay)

        now = now + time.s(901)
        scheduled[1].callback()
        assert.are.equal(1, suspends)
    end)

    it("wraps sandboxed handlers once and preserves their arguments and results", function()
        local calls = 0
        AutoSuspend.onResume = setmetatable({}, { __call = function(_handler, self, arg)
            calls = calls + 1
            assert.are.equal(now, self.last_action_time)
            return arg, "resumed"
        end })
        local apply = require("modules/global/patches/kindle_autosuspend_resume")
        apply()
        local patched = AutoSuspend.onResume
        apply()
        assert.are.equal(patched, AutoSuspend.onResume)

        local result, state = AutoSuspend:onResume("argument")
        assert.are.equal(1, calls)
        assert.are.equal("argument", result)
        assert.are.equal("resumed", state)
    end)

    it("leaves other devices unchanged", function()
        Device.isKindle = function() return false end
        local original = AutoSuspend.onResume
        require("modules/global/patches/kindle_autosuspend_resume")()
        assert.are.equal(original, AutoSuspend.onResume)
    end)

    it("does nothing when AutoSuspend is disabled", function()
        ZenSpec.replace("pluginloader", { loadPlugins = function() return {} end })
        local original = AutoSuspend.onResume
        require("modules/global/patches/kindle_autosuspend_resume")()
        assert.are.equal(original, AutoSuspend.onResume)
    end)
end)
