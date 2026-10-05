-- Keep native SQLite definitions loaded across Busted's file isolation.
expose("statistics reading day cutoff", function()
    require("ffi/loadlib")
    local SQ3 = require("lua-ljsqlite3/init")
    local db, StatsDB, stats_plugin, originals, original_time, original_date, original_settings, now

    local function timestamp(month, day, hour, minute)
        return original_time({
            year = month == 12 and 2025 or 2026, month = month, day = day,
            hour = hour, min = minute or 0, sec = 0,
        })
    end

    local function insert(book, page, ts, duration)
        db:exec(string.format("INSERT INTO page_stat_data VALUES (%d, %d, %d, %d);",
            book, page, ts, duration))
    end

    before_each(function()
        originals = {}
        for _i, name in ipairs({ "common/db_stats", "common/db_connection", "common/zen_logger",
                "pluginloader", "config/preset_store" }) do
            originals[name] = { value = package.loaded[name] }
        end
        original_time, original_date, original_settings = os.time, os.date, _G.G_reader_settings
        now = timestamp(1, 1, 4, 29)
        rawset(os, "time", function(t) return t and original_time(t) or now end)
        rawset(os, "date", function(format, ts) return original_date(format, ts or now) end)
        _G.G_reader_settings = ZenSpec.memorySettings()
        stats_plugin = {
            settings = {
                is_enabled = true, calendar_use_day_time_shift = true,
                calendar_day_start_hour = 4, calendar_day_start_minute = 30,
            },
            id_curr_book = 1,
            insertDB = function() end,
        }
        db = SQ3.open(":memory:")
        db:exec([[
            CREATE TABLE page_stat_data (id_book INTEGER, page INTEGER, start_time INTEGER, duration INTEGER);
            CREATE VIEW page_stat AS SELECT * FROM page_stat_data;
            CREATE TABLE book (id INTEGER, title TEXT, total_read_time INTEGER, total_read_pages INTEGER);
            INSERT INTO book VALUES (1, 'First book', 100, 2), (2, 'Second book', 50, 1);
        ]])
        insert(1, 1, timestamp(12, 30, 23), 10)
        insert(1, 1, timestamp(12, 31, 4, 29), 20)
        insert(1, 2, timestamp(12, 31, 4, 30), 30)
        insert(1, 2, timestamp(12, 31, 23), 40)
        insert(2, 3, timestamp(1, 1, 4, 29), 50)
        ZenSpec.replace("common/db_connection", {
            getStatsDbPath = function() return ":memory:" end,
            open = function()
                return {
                    exec = function(_self, sql) return db:exec(sql) end,
                    rowexec = function(_self, sql) return db:rowexec(sql) end,
                    close = function() end,
                }
            end,
        })
        ZenSpec.replace("common/zen_logger", {
            new = function() return { warn = function() end, info = function() end } end,
        })
        ZenSpec.replace("pluginloader", { getPluginInstance = function() return stats_plugin end })
        ZenSpec.replace("config/preset_store", { getSettings = function() return {} end })
        ZenSpec.unload("common/db_stats")
        StatsDB = require("common/db_stats")
    end)

    after_each(function()
        db:close()
        rawset(os, "time", original_time)
        rawset(os, "date", original_date)
        _G.G_reader_settings = original_settings
        for name, saved in pairs(originals) do package.loaded[name] = saved.value end
    end)

    it("groups after-midnight reading consistently across totals, streaks, charts, and records", function()
        local home = StatsDB.queryHomeStats({
            "today_pages", "today_duration", "week_pages", "week_duration",
            "month_pages", "month_duration", "year_pages", "year_duration", "streak",
        })
        assert.are.equal(2, home.today_pages)
        assert.are.equal(120, home.today_duration)
        assert.are.equal(150, home.week_duration)
        assert.are.equal(150, home.month_duration)
        assert.are.equal(150, home.year_duration)
        assert.are.equal(2, home.streak)
        local stats = StatsDB.queryStats()
        assert.are.equal(home.today_duration, stats.today_duration)
        assert.are.equal(home.streak, stats.streak)
        assert.are.same({ date = "2025-12-31", pages = 2, duration = 120 }, stats.week_daily[1])
        assert.are.equal(120, stats.peak_day_duration)
        assert.are.equal("2025-12-31", os.date("%Y-%m-%d", stats.peak_day_ts))
        assert.are.equal(150, stats.peak_month_duration)
        assert.are.equal("2025-12", os.date("%Y-%m", stats.peak_month_ts))
        local series = StatsDB.queryDailySeries(7)
        assert.are.equal(7, #series)
        assert.are.same({ date = "2025-12-31", pages = 2, duration = 120, books = 2 }, series[7])
        assert.are.same({ pages_today = 2, time_today = 120 },
            StatsDB.queryBookDetails(stats_plugin, { pages_today = true, time_today = true }))

        now = timestamp(1, 1, 4, 30)
        insert(2, 4, now, 60)
        stats = StatsDB.queryStats()
        assert.are.equal(60, stats.today_duration)
        assert.are.equal(60, stats.month_duration)
        assert.are.equal(60, stats.year_duration)
        assert.are.equal(3, stats.streak)
        series = StatsDB.queryDailySeries(7)
        assert.are.same({ date = "2026-01-01", pages = 1, duration = 60, books = 1 }, series[7])
        assert.are.equal(1, stats.books_this_month)
        assert.are.equal(1, stats.books_this_year)
    end)

    it("includes the exact cutoff in only the new day's popup", function()
        local begin = timestamp(12, 31, 4, 30)
        local ending = timestamp(1, 1, 4, 30)
        insert(2, 4, ending, 60)
        local books = StatsDB.queryBooksForPeriod(begin, ending)
        assert.are.equal(2, #books)
        assert.are.same({ title = "First book", pages = 1, duration = 70, book_id = 1 }, books[1])
        assert.are.same({ title = "Second book", pages = 1, duration = 50, book_id = 2 }, books[2])
        books = StatsDB.queryBooksForPeriod(ending, timestamp(1, 2, 4, 30))
        assert.are.same({ { title = "Second book", pages = 1, duration = 60, book_id = 2 } }, books)
    end)

    it("retains midnight days when the native shift switch is off", function()
        stats_plugin.settings.calendar_use_day_time_shift = false
        local stats = StatsDB.queryStats()
        assert.are.equal(50, stats.today_duration)
        assert.are.equal(50, stats.month_duration)
        assert.are.equal(50, stats.year_duration)
        assert.are.equal(3, stats.streak)
        assert.are.same({ date = "2026-01-01", pages = 1, duration = 50, books = 1 }, StatsDB.queryDailySeries(7)[7])
    end)
end)
