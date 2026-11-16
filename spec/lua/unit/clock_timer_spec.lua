describe("clock timer", function()
    local scheduled
    local unscheduled
    local ClockTimer
    local date_stub

    before_each(function()
        scheduled = {}
        unscheduled = {}
        ZenSpec.replace("ui/uimanager", {
            scheduleIn = function(_, delay, callback)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end,
            unschedule = function(_, callback)
                unscheduled[#unscheduled + 1] = callback
            end,
        })
        ZenSpec.replace("common/zen_logger", {
            new = function()
                return { warn = function() end }
            end,
        })
        date_stub = stub(os, "date").returns({ sec = 42 })
        ZenSpec.unload("common/clock_timer")
        ClockTimer = require("common/clock_timer")
    end)

    after_each(function()
        date_stub:revert()
        ZenSpec.unload("common/clock_timer")
    end)

    it("aligns its first callback to the next minute and never double-schedules", function()
        ClockTimer.subscribe("library", function() end)
        ClockTimer.subscribe("status", function() end)
        assert.are.equal(1, #scheduled)
        assert.are.equal(19, scheduled[1].delay)
    end)

    it("runs all callbacks, removes invalid subscribers, and schedules the next tick", function()
        local calls = 0
        ClockTimer.subscribe("library", function(key)
            assert.are.equal("library", key)
            calls = calls + 1
        end)
        scheduled[1].callback()
        assert.are.equal(1, calls)
        assert.are.equal(2, #scheduled)
        ClockTimer.unsubscribe("library")
        assert.are.equal(1, #unscheduled)
    end)

    it("pauses and resumes without invoking subscribers while paused", function()
        local calls = 0
        ClockTimer.subscribe("library", function() calls = calls + 1 end)
        ClockTimer.pause()
        ClockTimer.refreshNow()
        assert.are.equal(0, calls)
        assert.are.equal(1, #unscheduled)
        ClockTimer.resume()
        assert.are.equal(2, #scheduled)
        ClockTimer.refreshNow()
        assert.are.equal(1, calls)
    end)
end)
