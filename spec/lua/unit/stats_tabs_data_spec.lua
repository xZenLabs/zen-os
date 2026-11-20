describe("stats tabs data", function()
    local Data

    before_each(function()
        -- the calendar maths needs the real clock functions; undo a stub
        -- another spec may have left behind
        for _i, name in ipairs({ "time", "date" }) do
            local fn = os[name]
            if type(fn) == "table" and type(fn.revert) == "function" then fn:revert() end
        end
        ZenSpec.unload("modules/filebrowser/patches/stats_tabs/data")
        Data = require("modules/filebrowser/patches/stats_tabs/data")
    end)

    -- page_stat_data rows: { id_book, start_time, duration, page, total_pages }
    local function make_fetch(books, stats)
        return function(sql)
            if sql:match("^select id, title") then return books end
            if sql:match("^select id_book, start_time") then return stats end
            local id = tonumber(sql:match("id_book = (%d+)"))
            local groups, out = {}, {}
            for _i, r in ipairs(stats) do
                if r[3] > 0 and (not id or r[1] == id) then
                    local day = os.date("%Y-%m-%d", r[2])
                    local key = id and table.concat({ r[5], day, r[4] }, "|")
                        or table.concat({ r[1], r[5], day }, "|")
                    local g = groups[key]
                    if not g then
                        g = id and { r[5], day, r[4] } or { r[1], r[5], day, {} }
                        groups[key] = g
                        out[#out + 1] = g
                    end
                    if not id then g[4][r[4]] = true end
                end
            end
            if not id then
                for _i, g in ipairs(out) do
                    local n = 0
                    for _p in pairs(g[4]) do n = n + 1 end
                    g[4] = n
                end
            end
            return out
        end
    end

    it("counts finished books, reading time and reading days", function()
        local now = os.time{ year = 2026, month = 10, day = 20, hour = 20 }
        local day1 = os.time{ year = 2026, month = 10, day = 13, hour = 20 }
        local day2 = os.time{ year = 2026, month = 10, day = 14, hour = 20 }
        local books = {
            { 1, "Finished Book", "Author A", 100, "aaa" },
            { 2, "Current Book", "Author B", 200, "bbb" },
        }
        local stats = {}
        for p = 1, 100 do
            stats[#stats + 1] = { 1, (p <= 50 and day1 or day2) + p * 60, 60, p, 100 }
        end
        for p = 1, 20 do stats[#stats + 1] = { 2, now - 3600 + p * 60, 60, p, 200 } end
        local meta = {
            { file = "/books/a.epub", md5 = "aaa", status = "complete", title = "Finished Book", pages = 100 },
            { file = "/books/b.epub", md5 = "bbb", status = "reading", title = "Current Book", pages = 200,
              percent = 0.1 },
        }
        local S = Data.compute(make_fetch(books, stats), meta, now)
        assert.are.equal(1, S.finished_total)
        assert.are.equal(120 * 60, S.total_sec)
        assert.are.equal(1, #S.reading)
        assert.are.equal("Current Book", S.reading[1].title)

        local C = Data.calendar(S, 2026, 10, true)
        assert.are.equal(31, C.days)
        assert.are.equal(3, C.days_read)
        -- 1 October 2026 is a Thursday
        assert.are.equal(3, C.lead)
        assert.are.equal(4, Data.calendar(S, 2026, 10, false).lead)
    end)

    it("counts a finished book without statistics in the month it was marked", function()
        local now = os.time{ year = 2026, month = 11, day = 19, hour = 20 }
        local meta = {
            { file = "/books/a.epub", status = "complete", title = "", modified = "2026-10-12" },
            { file = "/books/b.epub", status = "complete", title = "", modified = "2025-12-30" },
        }
        local S = Data.compute(make_fetch({}, {}), meta, now)
        assert.are.equal(2, S.finished_total)
        assert.are.equal(1, S.fin_this_year)
        assert.are.equal(1, S.finished_by_month["2026-10"])
        assert.are.equal(1, S.finished_by_month["2025-12"])
        assert.are.equal(0, S.fin_with_stats)
    end)

    it("lists a day's books, longest first, with time and pages", function()
        local now = os.time{ year = 2026, month = 10, day = 20, hour = 20 }
        local day = os.time{ year = 2026, month = 10, day = 13, hour = 12 }
        local books = {
            { 1, "Short Read", "Author A", 100, "aaa" },
            { 2, "Long Read", "Author B", 200, "bbb" },
        }
        local stats = {}
        for p = 1, 10 do stats[#stats + 1] = { 1, day + p * 60, 60, p, 100 } end
        for p = 1, 30 do stats[#stats + 1] = { 2, day + 3600 + p * 60, 60, p, 200 } end
        local S = Data.compute(make_fetch(books, stats), {}, now)
        assert.are.same({
            { title = "Long Read", duration = 30 * 60, pages = 30 },
            { title = "Short Read", duration = 10 * 60, pages = 10 },
        }, Data.dayBooks(S, 2026, 10, 13))
        assert.are.same({}, Data.dayBooks(S, 2026, 10, 14))
    end)

    it("steps back through months across the year", function()
        assert.are.same({ 2025, 12 }, { Data.monthsBack(2026, 1, 1) })
        assert.are.same({ 2026, 3 }, { Data.monthsBack(2026, 1, -2) })
    end)
end)
