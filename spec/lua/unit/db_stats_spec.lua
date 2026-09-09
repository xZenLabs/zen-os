describe("statistics database", function()
    local conn
    local row_values
    local sqls
    local flushes
    local week_settings
    local bound_values

    before_each(function()
        week_settings = {}
        ZenSpec.replace("config/preset_store", { getSettings = function() return week_settings end })
        row_values = {}
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
        ZenSpec.unload("common/db_stats")
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
end)
