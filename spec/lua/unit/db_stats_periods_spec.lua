-- Compares the combined period scan and probe-based streak against the previous queries.
expose("statistics period and streak equivalence", function()
    require("ffi/loadlib")
    local SQ3 = require("lua-ljsqlite3/init")
    local db, StatsDB, stats_settings, original_time, original_date, original_settings, now, seed

    local OLD_PERIOD_SQL = [[
        SELECT count(*), sum(sum_duration)
        FROM (
            SELECT sum(duration) AS sum_duration
            FROM page_stat
            WHERE start_time >= %d
            GROUP BY id_book, page
        );
    ]]

    local function rand(n)
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed % n
    end

    local function insert(book, page, ts, duration, total_pages)
        db:exec(string.format("INSERT OR IGNORE INTO page_stat_data VALUES (%d, %d, %d, %d, %d);",
            book, page, ts, duration, total_pages or 100))
    end

    local function day_ts(offset, hour)
        local t = original_date("*t", now)
        return original_time({ year = t.year, month = t.month, day = t.day - offset, hour = hour or 12 })
    end

    local function old_streak(shift)
        local result = db:exec(string.format([[
            SELECT DISTINCT strftime('%%Y-%%m-%%d', start_time - %d, 'unixepoch', 'localtime') AS day
            FROM page_stat_data WHERE duration > 0 ORDER BY day DESC;
        ]], shift))
        local days = result and result.day or {}
        local now_ts = now - shift
        local today_t = original_date("*t", now_ts)
        local today = original_date("%Y-%m-%d", now_ts)
        local yesterday = original_date("%Y-%m-%d", original_time({
            year = today_t.year, month = today_t.month, day = today_t.day - 1, hour = 12 }))
        if days[1] ~= today and days[1] ~= yesterday then return 0 end
        local streak, expected = 0, days[1]
        for i = 1, #days do
            if days[i] ~= expected then break end
            streak = streak + 1
            local y, mo, d = expected:match("(%d+)-(%d+)-(%d+)")
            expected = original_date("%Y-%m-%d", original_time({
                year = tonumber(y), month = tonumber(mo), day = tonumber(d), hour = 12 }) - 86400)
        end
        return streak
    end

    local STUBBED = { "common/db_connection", "common/zen_logger", "pluginloader", "config/preset_store" }
    local saved_modules

    before_each(function()
        seed = 42
        original_time, original_date, original_settings = os.time, os.date, _G.G_reader_settings
        now = original_time({ year = 2026, month = 3, day = 9, hour = 3, min = 15 })
        rawset(os, "time", function(t) return t and original_time(t) or now end)
        rawset(os, "date", function(format, ts) return original_date(format, ts or now) end)
        _G.G_reader_settings = ZenSpec.memorySettings()
        stats_settings = { is_enabled = true }
        db = SQ3.open(":memory:")
        db:exec([[
            CREATE TABLE book (id INTEGER PRIMARY KEY, title TEXT, md5 TEXT, pages INTEGER,
                total_read_time INTEGER, total_read_pages INTEGER);
            CREATE TABLE page_stat_data (id_book INTEGER, page INTEGER NOT NULL DEFAULT 0,
                start_time INTEGER NOT NULL DEFAULT 0, duration INTEGER NOT NULL DEFAULT 0,
                total_pages INTEGER NOT NULL DEFAULT 0, UNIQUE (id_book, page, start_time));
            CREATE INDEX page_stat_data_start_time ON page_stat_data(start_time);
            CREATE TABLE numbers (number INTEGER PRIMARY KEY);
            WITH RECURSIVE counter AS (SELECT 1 AS N UNION ALL SELECT N + 1 FROM counter WHERE N < 1000)
                INSERT INTO numbers SELECT N AS number FROM counter;
            CREATE VIEW page_stat AS
                SELECT id_book, first_page + idx - 1 AS page, start_time, duration / (last_page - first_page + 1) AS duration
                FROM (
                    SELECT id_book, page, total_pages, pages, start_time, duration,
                        ((page - 1) * pages) / total_pages + 1 AS first_page,
                        max(((page - 1) * pages) / total_pages + 1, (page * pages) / total_pages) AS last_page,
                        idx
                    FROM page_stat_data
                    JOIN book ON book.id = id_book
                    JOIN (SELECT number as idx FROM numbers) AS N ON idx <= (last_page - first_page + 1)
                );
            INSERT INTO book VALUES (1, 'Up', 'a', 250, 0, 0), (2, 'Down', 'b', 40, 0, 0), (3, 'Same', 'c', 100, 0, 0);
        ]])
        saved_modules = {}
        for _i, name in ipairs(STUBBED) do saved_modules[name] = package.loaded[name] end
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
        ZenSpec.replace("pluginloader", { getPluginInstance = function() return { settings = stats_settings } end })
        ZenSpec.replace("config/preset_store", { getSettings = function() return { week_start_day = 2 } end })
        ZenSpec.unload("common/db_stats")
        StatsDB = require("common/db_stats")
    end)

    after_each(function()
        db:close()
        rawset(os, "time", original_time)
        rawset(os, "date", original_date)
        _G.G_reader_settings = original_settings
        ZenSpec.unload("common/db_stats")
        -- Restore real modules so stubs don't leak into later specs.
        for _i, name in ipairs(STUBBED) do package.loaded[name] = saved_modules[name] end
    end)

    local function seed_history(days)
        for offset = 0, days do
            if rand(5) ~= 0 then
                for _j = 1, 1 + rand(6) do
                    local book = 1 + rand(3)
                    insert(book, 1 + rand(100), day_ts(offset, rand(24)) + rand(3600),
                        rand(4) == 0 and 0 or rand(300), 100)
                end
            end
        end
    end

    local function old_periods()
        local starts = {}
        local shift = StatsDB.dayShift()
        local t = original_date("*t", now - shift)
        starts.today = original_time({ year = t.year, month = t.month, day = t.day, hour = 0 }) + shift
        starts.week = StatsDB.weekStart(t) + shift
        starts.month = original_time({ year = t.year, month = t.month, day = 1, hour = 0 }) + shift
        starts.year = original_time({ year = t.year, month = 1, day = 1, hour = 0 }) + shift
        local out = {}
        for name, start in pairs(starts) do
            local pages, duration = db:rowexec(string.format(OLD_PERIOD_SQL, start))
            out[name .. "_pages"] = tonumber(pages) or 0
            out[name .. "_duration"] = tonumber(duration) or 0
        end
        return out
    end

    local FIELDS = { "today_pages", "today_duration", "week_pages", "week_duration",
        "month_pages", "month_duration", "year_pages", "year_duration", "streak" }

    for _i, shift_on in ipairs({ false, true }) do
        it("matches separate rescaled period scans and the day walk (shift " .. tostring(shift_on) .. ")", function()
            stats_settings.calendar_use_day_time_shift = shift_on
            stats_settings.calendar_day_start_hour = 4
            seed_history(120)
            local home = StatsDB.queryHomeStats(FIELDS)
            local expected = old_periods()
            expected.streak = old_streak(StatsDB.dayShift())
            assert.is_true(expected.year_pages > expected.month_pages and expected.week_pages > 0)
            for _k, field in ipairs(FIELDS) do
                assert.are.equal(expected[field], home[field], field)
            end
            local stats = StatsDB.queryStats()
            for _k, field in ipairs(FIELDS) do
                assert.are.equal(expected[field], stats[field], field)
            end
        end)
    end

    it("matches streak edge cases", function()
        local function check(label)
            assert.are.equal(old_streak(0), StatsDB.queryHomeStats({ "streak" }).streak, label)
        end
        check("empty")
        for offset = 1, 30 do insert(1, offset, day_ts(offset), 60) end
        check("through yesterday")
        assert.are.equal(30, StatsDB.queryHomeStats({ "streak" }).streak)
        insert(1, 99, day_ts(0, 1), 60)
        check("today")
        insert(2, 1, day_ts(40), 0)
        insert(2, 2, day_ts(31), 0)
        check("zero-duration day")
        db:exec("DELETE FROM page_stat_data WHERE page = 15;")
        check("gap")
        insert(3, 1, day_ts(-2), 60)
        check("future row")
        assert.are.equal(0, StatsDB.queryHomeStats({ "streak" }).streak)
    end)

    it("queries only the requested parts", function()
        seed_history(20)
        local stats = StatsDB.queryStats({ today = true })
        assert.are.equal(old_periods().today_pages, stats.today_pages)
        assert.are.equal(0, stats.year_pages)
        assert.are.equal(0, stats.streak)
        assert.are.equal(0, stats.peak_day_duration)
    end)
end)
