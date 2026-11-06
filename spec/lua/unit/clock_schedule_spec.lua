local ClockSchedule = require("common/clock_schedule")

describe("clock schedule", function()
    it("aligns every valid second just past the following minute", function()
        for second = 0, 59 do
            assert.are.equal(61 - second, ClockSchedule.nextMinuteDelay({ sec = second }))
        end
    end)

    it("falls back safely for missing, invalid, and out-of-range clocks", function()
        assert.are.equal(61, ClockSchedule.nextMinuteDelay())
        assert.are.equal(61, ClockSchedule.nextMinuteDelay({ sec = "bad" }))
        assert.are.equal(1, ClockSchedule.nextMinuteDelay({ sec = 60 }))
        assert.are.equal(61, ClockSchedule.nextMinuteDelay({ sec = -1 }))
        assert.are.equal(61, ClockSchedule.nextMinuteDelay({ sec = 61 }))
    end)
end)
