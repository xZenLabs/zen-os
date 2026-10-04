describe("battery stats", function()
    local originals, original_time, now, level, charging, charged, stored, writes, scheduled, battery_path, log_path
    local BatteryStats, settings_path, history_path

    local function read_history()
        local summaries = {}
        local file = assert(io.open(history_path, "r"))
        for line in file:lines() do summaries[#summaries + 1] = require("json").decode(line) end
        file:close()
        return summaries
    end

    before_each(function()
        originals = {}
        for _i, name in ipairs({
            "device", "luasettings", "config/preset_store", "ui/uimanager", "common/battery_stats",
            "ffi/util", "common/zen_logger",
        }) do originals[name] = { value = package.loaded[name] } end
        original_time = os.time
        now, level, charging, stored, writes, scheduled = 1000000, 100, false, { events = {} }, 0, {}
        charged = false
        battery_path = nil
        settings_path = os.tmpname()
        os.remove(settings_path)
        assert.is_true(require("libs/libkoreader-lfs").mkdir(settings_path))
        log_path, history_path = settings_path .. "/battery.lua", settings_path .. "/battery_history"
        rawset(os, "time", function() return now end)
        ZenSpec.replace("device", {
            hasBattery = function() return true end,
            getPowerDevice = function()
                return {
                    getCapacityHW = function() return level end,
                    isCharging = function() return charging end,
                    isCharged = function() return charged end,
                    batt_capacity_file = battery_path and battery_path .. "/capacity",
                }
            end,
        })
        ZenSpec.replace("luasettings", {
            open = function()
                return {
                    file = log_path,
                    readSetting = function(_, key) return stored[key] end,
                    saveSetting = function(_, key, value) stored[key] = value end,
                    reset = function(_, value) stored = value end,
                    flush = function() writes = writes + 1 end,
                }
            end,
        })
        ZenSpec.replace("config/preset_store", { rootDir = function() return settings_path end })
        ZenSpec.replace("ui/uimanager", {
            scheduleIn = function(_, delay, callback)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end,
            unschedule = function() end,
        })
        ZenSpec.unload("common/battery_stats")
        BatteryStats = require("common/battery_stats")
    end)

    after_each(function()
        rawset(os, "time", original_time)
        os.remove(log_path)
        os.remove(log_path .. ".old")
        os.remove(history_path)
        require("libs/libkoreader-lfs").rmdir(settings_path)
        if battery_path then
            for _i, name in ipairs({
                "type", "charge_now", "charge_full", "charge_full_design", "charge_empty",
                "charge_empty_design", "energy_full", "energy_full_design",
            }) do os.remove(battery_path .. "/" .. name) end
            require("libs/libkoreader-lfs").rmdir(battery_path)
        end
        for name, saved in pairs(originals) do package.loaded[name] = saved.value end
    end)

    it("separates awake and sleep drain, and excludes charging and restart gaps", function()
        BatteryStats.start()
        assert.are.equal(1800, scheduled[1].delay)
        now, level = now + 1800, 95
        scheduled[#scheduled].callback()
        now, level = now + 1800, 90
        BatteryStats.suspend()
        now, level = now + 4 * 3600, 88
        BatteryStats.resume()

        local stats = BatteryStats.snapshot()
        assert.are.equal(10, stats.awake)
        assert.are.equal(0.5, stats.asleep)
        assert.are.equal(3600, stats.awake_time)
        assert.are.equal(4 * 3600, stats.asleep_time)
        assert.is_true(math.abs(stats.overall - 2.4) < 0.001)
        assert.is_true(math.abs(stats.remaining - 132000) < 1)
        assert.are.equal(4, writes)

        now, level, charging = now + 3600, 85, true
        BatteryStats.chargingChanged()
        assert.are.equal(4, writes)
        scheduled[#scheduled].callback()
        now, level, charging = now + 3600, 95, false
        BatteryStats.chargingChanged()
        scheduled[#scheduled].callback()
        stats = BatteryStats.snapshot()
        assert.are.equal(0, stats.since_charge)
        assert.are.equal(6.5, stats.awake)
        assert.are.equal(2 * 3600, stats.awake_time)
        assert.are.equal(4 * 3600, stats.asleep_time)

        BatteryStats.stop()
        now, level = now + 8 * 3600, 93
        BatteryStats.start()
        stats = BatteryStats.snapshot()
        assert.are.equal(6.5, stats.awake)
        assert.are.equal(0.5, stats.asleep)
        assert.are.equal(2 * 3600, stats.awake_time)
        assert.are.equal(4 * 3600, stats.asleep_time)
        assert.are.equal(8 * 3600, stats.since_charge)
        assert.is_true(stored.events[#stored.events].gap)

        BatteryStats.stop()
        now, level = now + 3600, 99
        BatteryStats.start()
        assert.is_nil(BatteryStats.snapshot().since_charge)
    end)

    it("waits for an hour of discharge data for used and awake rates", function()
        BatteryStats.start()
        now, level = now + 1800, 95
        scheduled[#scheduled].callback()
        local stats = BatteryStats.snapshot()
        assert.is_nil(stats.overall)
        assert.is_nil(stats.awake)
        assert.is_nil(stats.remaining)

        BatteryStats.suspend()
        now, level = now + 3600, 94
        BatteryStats.resume()
        stats = BatteryStats.snapshot()
        assert.are.equal(4, stats.overall)
        assert.is_nil(stats.awake)
        assert.are.equal(1, stats.asleep)

        now, level = now + 1800, 89
        scheduled[#scheduled].callback()
        stats = BatteryStats.snapshot()
        assert.are.equal(10, stats.awake)
    end)

    it("measures charging progress and freezes the completed full-charge duration", function()
        level = 20
        BatteryStats.start()
        charging = true
        BatteryStats.chargingChanged()
        scheduled[#scheduled].callback()
        assert.is_nil(BatteryStats.snapshot().charge_rate)
        assert.are.equal(0, BatteryStats.snapshot().charge_gain)
        assert.is_nil(BatteryStats.snapshot().time_to_full)

        now, level = now + 1800, 40
        local before = writes
        local stats = BatteryStats.snapshot()
        assert.are.equal(40, stats.charge_rate)
        assert.are.equal(20, stats.charge_gain)
        assert.are.equal(5400, stats.time_to_full)
        assert.are.equal(before, writes)
        assert.are.equal(20, stored.charge_session.level)
        scheduled[#scheduled].callback()

        now, level = now + 5400, 100
        scheduled[#scheduled].callback()
        stats = BatteryStats.snapshot()
        assert.are.equal(40, stats.charge_rate)
        assert.are.equal(80, stats.charge_gain)
        assert.are.equal(0, stats.time_to_full)
        assert.are.equal(7200, stats.full_charge_time)
        assert.are.equal(0, stats.since_full_charge)

        now = now + 3600
        scheduled[#scheduled].callback()
        stats = BatteryStats.snapshot()
        assert.are.equal(40, stats.charge_rate)
        assert.are.equal(80, stats.charge_gain)
        assert.are.equal(7200, stats.full_charge_time)
        assert.are.equal(3600, stats.since_full_charge)

        charging = false
        BatteryStats.chargingChanged()
        scheduled[#scheduled].callback()
        now, level = now + 3600, 95
        BatteryStats.stop()
        now = now + 3600
        BatteryStats.start()
        stats = BatteryStats.snapshot()
        assert.are.equal(40, stats.charge_rate)
        assert.are.equal(80, stats.charge_gain)
        assert.is_nil(stats.time_to_full)
        assert.are.equal(7200, stats.full_charge_time)
        assert.are.equal(10800, stats.since_full_charge)
        assert.are.equal(7200, stats.since_charge)
    end)

    it("keeps the rate of a partial charge and starts a fresh session on reconnect", function()
        level = 20
        BatteryStats.start()
        charging = true
        BatteryStats.chargingChanged()
        scheduled[#scheduled].callback()
        now, level, charging = now + 3600, 50, false
        BatteryStats.chargingChanged()
        scheduled[#scheduled].callback()
        local stats = BatteryStats.snapshot()
        assert.are.equal(30, stats.charge_rate)
        assert.are.equal(30, stats.charge_gain)
        assert.is_nil(stats.time_to_full)
        assert.is_nil(stats.full_charge_time)
        assert.is_nil(stats.since_full_charge)

        BatteryStats.stop()
        now, level = now + 1800, 48
        BatteryStats.start()
        stats = BatteryStats.snapshot()
        assert.are.equal(30, stats.charge_rate)
        assert.are.equal(30, stats.charge_gain)
        assert.is_nil(stats.time_to_full)

        now, level, charging = now + 3600, 45, true
        BatteryStats.chargingChanged()
        scheduled[#scheduled].callback()
        assert.is_nil(BatteryStats.snapshot().charge_rate)
        assert.are.equal(0, BatteryStats.snapshot().charge_gain)
        now, level = now + 1800, 55
        scheduled[#scheduled].callback()
        assert.are.equal(20, BatteryStats.snapshot().charge_rate)
        assert.are.equal(10, BatteryStats.snapshot().charge_gain)
        assert.are.equal(8100, BatteryStats.snapshot().time_to_full)
    end)

    it("keeps measured charging history across an unobserved unplug without extending it", function()
        level, charging = 20, true
        BatteryStats.start()
        now = now + 1800
        scheduled[#scheduled].callback()
        assert.is_nil(BatteryStats.snapshot().charge_rate)
        assert.is_nil(BatteryStats.snapshot().time_to_full)
        now, level = now + 1800, 40
        scheduled[#scheduled].callback()
        assert.are.equal(20, BatteryStats.snapshot().charge_rate)
        now, level, charging = now + 1800, 50, false
        local before = writes
        local stats = BatteryStats.snapshot()
        assert.are.equal(20, stats.charge_rate)
        assert.are.equal(20, stats.charge_gain)
        assert.is_nil(stats.time_to_full)
        assert.are.equal(before, writes)
        assert.are.equal(40, stored.charge_session.level)
        scheduled[#scheduled].callback()
        assert.are.equal(20, BatteryStats.snapshot().charge_rate)
        assert.are.equal(20, BatteryStats.snapshot().charge_gain)
        assert.is_nil(BatteryStats.snapshot().time_to_full)
        assert.is_nil(BatteryStats.snapshot().full_charge_time)
    end)

    it("recognizes the device full-charge state below 100 percent", function()
        level, charging = 80, true
        BatteryStats.start()
        now, level = now + 3600, 97
        scheduled[#scheduled].callback()
        charged = true
        BatteryStats.chargingChanged()
        scheduled[#scheduled].callback()
        local stats = BatteryStats.snapshot()
        assert.are.equal(3600, stats.full_charge_time)
        assert.are.equal(0, stats.time_to_full)
        assert.are.equal(0, stats.since_full_charge)
        now = now + 3600
        scheduled[#scheduled].callback()
        assert.are.equal(17, BatteryStats.snapshot().charge_rate)
        assert.are.equal(3600, BatteryStats.snapshot().since_full_charge)
    end)

    it("does not estimate charging across restart gaps, failed reads, or falling levels", function()
        level, charging = 20, true
        BatteryStats.start()
        now, level = now + 1800, 40
        scheduled[#scheduled].callback()
        assert.are.equal(40, BatteryStats.snapshot().charge_rate)

        BatteryStats.stop()
        now, level = now + 3600, 60
        BatteryStats.start()
        assert.is_nil(BatteryStats.snapshot().charge_rate)
        now, level = now + 1800, 70
        scheduled[#scheduled].callback()
        assert.are.equal(20, BatteryStats.snapshot().charge_rate)

        level = nil
        scheduled[#scheduled].callback()
        now, level = now + 1800, 80
        assert.is_nil(BatteryStats.snapshot().charge_rate)
        scheduled[#scheduled].callback()
        now, level = now + 1800, 90
        scheduled[#scheduled].callback()
        assert.are.equal(20, BatteryStats.snapshot().charge_rate)
        now, level = now + 1800, 85
        scheduled[#scheduled].callback()
        assert.is_nil(BatteryStats.snapshot().charge_rate)
        assert.is_nil(BatteryStats.snapshot().full_charge_time)
    end)

    it("measures charging during sleep without scheduling extra wakeups", function()
        level, charging = 20, true
        BatteryStats.start()
        BatteryStats.suspend()
        local before = #scheduled
        now, level = now + 4 * 3600, 100
        BatteryStats.resume()
        assert.are.equal(before + 1, #scheduled)
        local stats = BatteryStats.snapshot()
        assert.are.equal(20, stats.charge_rate)
        assert.are.equal(4 * 3600, stats.full_charge_time)
    end)

    it("archives an oversized log at startup and does not write when statistics are viewed", function()
        for i = 1, 520 do
            stored.events[i] = { time = now - (521 - i) * 1800, level = 80,
                charging = false, sleeping = false }
        end
        local reads = 0
        rawset(os, "time", function() reads = reads + 1; return now + reads - 1 end)
        BatteryStats.start()
        assert.are.equal(1, reads)
        assert.are.equal(1, #stored.events)
        local history = read_history()
        assert.are.equal(1, #history)
        assert.are.equal(521, history[1].samples)
        assert.are.equal(now - 520 * 1800, history[1].start_time)
        assert.are.equal(now, history[1].end_time)
        assert.are.equal(1, history[1].gaps)
        assert.are.equal(519 * 1800, history[1].awake_seconds)
        assert.are.equal(0, history[1].discharge_loss_pct)
        local before = writes
        BatteryStats.snapshot()
        assert.are.equal(before, writes)
        assert.are.equal(1, #read_history())
    end)

    it("appends drain and charging summaries while preserving consecutive window boundaries", function()
        BatteryStats.start()
        for i = 1, 505 do
            now = now + 1800
            scheduled[#scheduled].callback()
        end
        now, level = now + 3600, 90
        scheduled[#scheduled].callback()
        BatteryStats.suspend()
        now, level = now + 7200, 88
        BatteryStats.resume()
        charging = true
        BatteryStats.chargingChanged()
        scheduled[#scheduled].callback()
        now, level = now + 3600, 100
        scheduled[#scheduled].callback()
        charging = false
        BatteryStats.chargingChanged()
        scheduled[#scheduled].callback()
        assert.are.equal(512, #stored.events)
        assert.is_nil(io.open(history_path, "r"))

        now, level = now + 3600, 95
        scheduled[#scheduled].callback()
        local history = read_history()
        local first = history[1]
        assert.are.equal(1, #history)
        assert.are.equal(1, first.version)
        assert.are.equal(1000000, first.start_time)
        assert.are.equal(now, first.end_time)
        assert.are.equal(100, first.start_level_pct)
        assert.are.equal(95, first.end_level_pct)
        assert.are.equal(513, first.samples)
        assert.are.equal(0, first.gaps)
        assert.are.equal(505 * 1800 + 7200, first.awake_seconds)
        assert.are.equal(7200, first.asleep_seconds)
        assert.are.equal(first.awake_seconds, first.awake_discharge_seconds)
        assert.are.equal(first.asleep_seconds, first.asleep_discharge_seconds)
        assert.are.equal(first.awake_seconds + 7200, first.discharge_seconds)
        assert.are.equal(15, first.awake_loss_pct)
        assert.are.equal(2, first.asleep_loss_pct)
        assert.are.equal(17, first.discharge_loss_pct)
        assert.is_true(math.abs(15 * 3600 / first.awake_seconds - first.awake_pct_per_hour) < 1e-12)
        assert.are.equal(1, first.asleep_pct_per_hour)
        assert.is_true(math.abs(17 * 3600 / first.discharge_seconds - first.discharge_pct_per_hour) < 1e-12)
        assert.are.equal(12, first.last_charge_pct_per_hour)
        assert.are.equal(12, first.last_charge_gain_pct)
        assert.are.equal(3600, first.last_full_charge_seconds)
        assert.is_nil(first.health_pct)
        assert.are.equal(1, #stored.events)
        assert.are.equal(now, stored.events[1].time)
        assert.are.equal(12, BatteryStats.snapshot().charge_rate)

        for i = 1, 2 do
            now, level = now + 1800, level - 1
            scheduled[#scheduled].callback()
        end
        assert.are.equal(2, BatteryStats.snapshot().awake)
        assert.are.equal(1, #read_history())
        BatteryStats.stop()
        BatteryStats.start()
        for i = 1, 509 do
            now = now + 1800
            scheduled[#scheduled].callback()
        end
        history = read_history()
        assert.are.equal(2, #history)
        assert.are.same(first, history[1])
        assert.are.equal(first.end_time, history[2].start_time)
        assert.are.equal(2, history[2].awake_loss_pct)
        assert.are.equal(511 * 1800, history[2].awake_seconds)
        assert.are.equal(1, history[2].gaps)
        assert.are.equal(1, #stored.events)
        assert.is_true(BatteryStats.reset())
        assert.are.same(history, read_history())
    end)

    it("keeps samples if history cannot be opened, written, flushed, synced, or closed", function()
        local original_open = io.open
        ZenSpec.replace("common/zen_logger", { new = function() return { warn = function() end } end })
        BatteryStats.start()
        for i = 2, 512 do
            now = now + 1800
            scheduled[#scheduled].callback()
        end
        for _i, failure in ipairs({ "open", "write", "flush", "sync", "directory", "close" }) do
            local closed = false
            ZenSpec.replace("ffi/util", {
                fsyncOpenedFile = function() return failure ~= "sync" end,
                fsyncDirectory = function() return failure ~= "directory" end,
            })
            rawset(io, "open", function(path, mode)
                if path ~= history_path or mode ~= "a" then return original_open(path, mode) end
                if failure == "open" then return nil, "unavailable" end
                return {
                    write = function() return failure ~= "write" end,
                    flush = function() return failure ~= "flush" end,
                    close = function() closed = true; return failure ~= "close" end,
                }
            end)
            now = now + 1800
            local ok, err = pcall(scheduled[#scheduled].callback)
            rawset(io, "open", original_open)
            assert.is_true(ok, err)
            assert.are.equal(512 + _i, #stored.events)
            assert.are.equal(failure ~= "open", closed)
        end
        package.loaded["ffi/util"] = originals["ffi/util"].value
        now = now + 1800
        scheduled[#scheduled].callback()
        assert.are.equal(1, #stored.events)
        assert.are.equal(519, read_history()[1].samples)
    end)

    it("keeps old samples and counts intervals longer than 30 days", function()
        now, level = 10000000, 70
        stored.events = {
            { time = now - 50 * 86400, level = 80, charging = false, sleeping = false },
            { time = now - 10 * 86400, level = 70, charging = false, sleeping = false },
        }
        BatteryStats.start()
        local stats = BatteryStats.snapshot()
        assert.are.equal(3, stats.samples)
        assert.are.equal(40 * 86400, stats.awake_time)
        assert.are.equal(10 * 3600 / (40 * 86400), stats.overall)
    end)

    it("resets samples, charging measurements, unplug time, and the old log backup", function()
        BatteryStats.start()
        now, level = now + 1800, 95
        scheduled[#scheduled].callback()
        stored.last_unplug = now - 60
        stored.charge_session = { start_time = now - 3600, start_level = 50, time = now, level = 100, full = true }
        stored.last_full_charge = stored.charge_session
        local backup = assert(io.open(log_path .. ".old", "w"))
        backup:write("old battery log")
        backup:close()

        assert.is_true(BatteryStats.reset())
        assert.are.equal(0, BatteryStats.snapshot().samples)
        assert.are.equal(0, BatteryStats.snapshot().awake_time)
        assert.are.equal(0, BatteryStats.snapshot().asleep_time)
        assert.is_nil(BatteryStats.snapshot().since_charge)
        assert.is_nil(BatteryStats.snapshot().charge_rate)
        assert.is_nil(BatteryStats.snapshot().charge_gain)
        assert.is_nil(BatteryStats.snapshot().full_charge_time)
        assert.is_nil(BatteryStats.snapshot().since_full_charge)
        assert.is_nil(io.open(log_path .. ".old", "r"))

        now, level = now + 1800, 90
        scheduled[#scheduled].callback()
        assert.are.equal(1, BatteryStats.snapshot().samples)
    end)

    it("reads full charge and empty thresholds in microamp hours", function()
        local lfs = require("libs/libkoreader-lfs")
        battery_path = os.tmpname()
        os.remove(battery_path)
        assert.is_true(lfs.mkdir(battery_path))
        local function write(name, value)
            local file = assert(io.open(battery_path .. "/" .. name, "w"))
            assert(file:write(value))
            file:close()
        end
        write("type", "Battery")
        write("charge_full", "1500000")
        write("charge_now", "900000")
        write("charge_empty", "300000")
        write("charge_full_design", "1800000")
        write("charge_empty_design", "200000")

        BatteryStats.start()
        local stats = BatteryStats.snapshot()
        assert.are.equal(1200, stats.full_mah)
        assert.are.equal(600, stats.current_mah)
        assert.are.equal(1600, stats.design_mah)
        assert.are.equal(75, stats.health)

        os.remove(battery_path .. "/type")
        assert.are.equal(1200, BatteryStats.snapshot().full_mah)

        for i = 1, 512 do
            now = now + 1800
            scheduled[#scheduled].callback()
        end
        local summary = read_history()[1]
        assert.are.equal(1200, summary.full_capacity_mah)
        assert.are.equal(1600, summary.design_capacity_mah)
        assert.are.equal(75, summary.health_pct)

        os.remove(battery_path .. "/charge_now")
        level = 50
        stats = BatteryStats.snapshot()
        assert.is_nil(stats.current_mah)

        os.remove(battery_path .. "/charge_full_design")
        stats = BatteryStats.snapshot()
        assert.is_nil(stats.health)

        os.remove(battery_path .. "/charge_full")
        write("energy_full", "5000000")
        write("energy_full_design", "10000000")
        stats = BatteryStats.snapshot()
        assert.is_nil(stats.full_mah)
        assert.is_nil(stats.current_mah)
        assert.is_nil(stats.design_mah)
        assert.is_nil(stats.health)
    end)
end)
