describe("statistics database", function()
    local conn
    local row_values
    local sqls
    local flushes
    local week_settings
    local bound_values
    local original_time, original_date, original_settings, now, live_stats_plugin

    before_each(function()
        week_settings = {}
        original_time, original_date, original_settings = os.time, os.date, _G.G_reader_settings
        now = original_time({ year = 2026, month = 1, day = 1, hour = 4, min = 29, sec = 59 })
        rawset(os, "time", function(t) return t and original_time(t) or now end)
        rawset(os, "date", function(format, ts) return original_date(format, ts or now) end)
        _G.G_reader_settings = ZenSpec.memorySettings()
        live_stats_plugin = nil
        ZenSpec.replace("pluginloader", {
            getPluginInstance = function() return live_stats_plugin end,
        })
        ZenSpec.replace("config/preset_store", { getSettings = function() return week_settings end })
        row_values = { 0 }
        sqls = {}
        flushes = 0
        bound_values = nil
        conn = {
            rowexec = function(_self, sql)
                sqls[#sqls + 1] = sql
                return unpack(row_values)
            end,
            prepare = function(_self, sql)
                sqls[#sqls + 1] = sql
                local stmt = {}
                function stmt:reset() return self end
                function stmt:bind(...)
                    bound_values = { ... }
                    return self
                end
                function stmt:step() return row_values end
                function stmt:close() end
                return stmt
            end,
            close = function() end,
        }
        ZenSpec.replace("common/zen_logger", {
            new = function()
                return { warn = function() end, info = function() end }
            end,
        })
        ZenSpec.replace("common/db_connection", {
            getStatsDbPath = function() return "/stats.sqlite3" end,
            open = function() return conn end,
        })
        ZenSpec.unload("common/db_stats")
    end)

    after_each(function()
        rawset(os, "time", original_time)
        rawset(os, "date", original_date)
        _G.G_reader_settings = original_settings
        ZenSpec.unload("common/db_stats")
    end)

    it("uses live Statistics settings, falls back to saved settings, and respects the switch", function()
        local StatsDB = require("common/db_stats")
        assert.are.equal(0, StatsDB.dayShift())
        G_reader_settings:saveSetting("statistics", {
            calendar_use_day_time_shift = true,
            calendar_day_start_hour = 4,
            calendar_day_start_minute = 30,
        })
        assert.are.equal(16200, StatsDB.dayShift())
        live_stats_plugin = { settings = { calendar_use_day_time_shift = false, calendar_day_start_hour = 6 } }
        assert.are.equal(0, StatsDB.dayShift())
        live_stats_plugin.settings.calendar_use_day_time_shift = true
        assert.are.equal(21600, StatsDB.dayShift())
        live_stats_plugin.settings.calendar_day_start_minute = 10
        assert.are.equal(22200, StatsDB.dayShift())
    end)

    it("keeps all goal periods in the previous reading day until the cutoff", function()
        G_reader_settings:saveSetting("statistics", {
            calendar_use_day_time_shift = true,
            calendar_day_start_hour = 4,
            calendar_day_start_minute = 30,
        })
        local StatsDB = require("common/db_stats")
        local fields = { "today_pages", "week_pages", "month_pages", "year_pages" }
        StatsDB.queryHomeStats(fields)
        for i, date in ipairs({ { 2025, 12, 31 }, { 2025, 12, 28 }, { 2025, 12, 1 }, { 2025, 1, 1 } }) do
            local expected = original_time({
                year = date[1], month = date[2], day = date[3], hour = 4, min = 30, sec = 0,
            })
            assert.is_truthy(sqls[i]:find("start_time >= " .. expected, 1, true))
        end
        now = now + 1
        sqls = {}
        StatsDB.queryHomeStats(fields)
        for i, date in ipairs({ { 2026, 1, 1 }, { 2025, 12, 28 }, { 2026, 1, 1 }, { 2026, 1, 1 } }) do
            local expected = original_time({
                year = date[1], month = date[2], day = date[3], hour = 4, min = 30, sec = 0,
            })
            assert.is_truthy(sqls[i]:find("start_time >= " .. expected, 1, true))
        end
    end)

    it("uses the cutoff for both Sunday and Monday week starts", function()
        G_reader_settings:saveSetting("statistics", {
            calendar_use_day_time_shift = true, calendar_day_start_hour = 4,
        })
        local StatsDB = require("common/db_stats")
        for _i, case in ipairs({ { 1, 30, 23 }, { 2, 31, 24 } }) do
            week_settings.week_start_day = case[1]
            now = original_time({ year = 2026, month = 8, day = case[2], hour = 3 })
            sqls = {}
            StatsDB.queryHomeStats({ "week_pages" })
            local expected = original_time({ year = 2026, month = 8, day = case[3], hour = 4 })
            assert.is_truthy(sqls[1]:find("start_time >= " .. expected, 1, true))
        end
    end)

    it("builds one query containing only the requested book details", function()
        local StatsDB = require("common/db_stats")
        local stats_plugin = {
            settings = { is_enabled = true },
            id_curr_book = 42,
            insertDB = function() flushes = flushes + 1 end,
        }

        row_values = { 7260, 12, 1800 }
        local all = StatsDB.queryBookDetails(stats_plugin, {
            read_time = true,
            time_remaining = true,
            pages_today = true,
            time_today = true,
        })

        assert.are.equal(1, flushes)
        assert.are.equal(1, #sqls)
        assert.is_truthy(sqls[1]:find("book_stats AS", 1, true))
        assert.is_truthy(sqls[1]:find("today_stats AS", 1, true))
        assert.are.same({ read_time = 7260, pages_today = 12, time_today = 1800 }, all)

        row_values = { 9 }
        local daily_pages = StatsDB.queryBookDetails(stats_plugin, {
            time_remaining = true,
            pages_today = true,
        })

        assert.are.equal(2, flushes)
        assert.are.equal(2, #sqls)
        assert.is_nil(sqls[2]:find("book_stats AS", 1, true))
        assert.is_nil(sqls[2]:find("sum(duration) AS duration", 1, true))
        assert.are.same({ pages_today = 9 }, daily_pages)
    end)

    it("loads path-based average and total reading times together", function()
        local StatsDB = require("common/db_stats")
        row_values = { 10, 600, 900, 200 }

        local average, pages, read_time = StatsDB.queryBookAveragePageTime(
            "/books/test.epub", "book-hash")

        assert.are.equal(60, average)
        assert.are.equal(200, pages)
        assert.are.equal(900, read_time)
        assert.are.equal("book-hash", bound_values[1])
        assert.are.equal("book-hash", bound_values[3])
    end)

    it("starts weeks on the selected day across month and year boundaries", function()
        local StatsDB = require("common/db_stats")
        for _i, case in ipairs({
            { 2026, 8, 31, 2, 2026, 8, 30, 2026, 8, 31 },
            { 2026, 8, 30, 1, 2026, 8, 30, 2026, 8, 24 },
            { 2026, 1, 1, 5, 2025, 12, 28, 2025, 12, 29 },
            { 2026, 3, 9, 2, 2026, 3, 8, 2026, 3, 9 },
        }) do
            for day = 1, 2 do
                week_settings.week_start_day = day == 2 and 2 or nil
                local offset = day == 1 and 4 or 7
                local expected = os.time({
                    year = case[offset + 1], month = case[offset + 2], day = case[offset + 3],
                    hour = 0, min = 0, sec = 0,
                })
                assert.are.equal(expected, StatsDB.weekStart({
                    year = case[1], month = case[2], day = case[3], wday = case[4],
                }))
            end
        end
    end)

    it("excludes CBZ and CBR book hashes from goal totals", function()
        local cbz_hash = string.rep("a", 32)
        local cbr_hash = string.rep("b", 32)
        ZenSpec.replace("readhistory", {
            hist = {
                { file = "/books/comic.CBZ", time = 1 },
                { file = "/books/archive.cbr", time = 2 },
                { file = "/books/novel.epub", time = 3 },
            },
            reload = function() end,
        })
        ZenSpec.replace("docsettings", {
            findSidecarFile = function(_self, file) return file .. ".sdr" end,
            openSettingsFile = function(file)
                return { data = { partial_md5_checksum =
                    file:find("comic", 1, true) and cbz_hash or cbr_hash } }
            end,
        })

        row_values = { 4, 240 }
        local stats = require("common/db_stats").queryHomeStats({
            today_pages = true,
            today_duration = true,
        }, true)

        assert.are.equal(4, stats.today_pages)
        assert.are.equal(240, stats.today_duration)
        assert.is_truthy(sqls[1]:find("lower(md5) IN", 1, true))
        assert.is_truthy(sqls[1]:find("'" .. cbz_hash .. "'", 1, true))
        assert.is_truthy(sqls[1]:find("'" .. cbr_hash .. "'", 1, true))
    end)
end)
