describe("Reading Wrapped", function()
    local Wrapped
    local shown, saves_at_show, queries, month
    local original_date, original_time
    local MONTHS = { "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December" }
    local names = {
        "gettext", "ffi/util", "datetime", "common/plugin_root", "common/utils", "common/db_stats",
        "common/db_library", "common/db_bookinfo", "common/ui/wrapped_screen", "ui/uimanager",
        "common/reading_wrapped",
    }
    local saved
    local data

    local function rich_year()
        return {
            year = 2026, pages = 4200, duration = 12000, books = 4,
            top_books = {
                { title = "Dune", authors = "Frank Herbert", series = "Dune #1", annotations = 5, duration = 6000, pages = 900 },
                { title = "Emma", authors = "Jane Austen", series = "N/A", annotations = 0, duration = 3000, pages = 800 },
            },
            authors = {
                { name = "Frank Herbert", duration = 7200, books = 2 },
                { name = "Jane Austen", duration = 3000, books = 3 },
            },
            series = { { name = "Dune", duration = 6000, books = 2 } },
            most_annotated = { title = "Dune", authors = "Frank Herbert", annotations = 5 },
            days = {}, longest_streak = 5, reading_days = 30,
            best_day = { date = "2026-03-14", duration = 7200, pages = 120 },
            best_pages_day = { date = "2026-03-14", duration = 7200, pages = 120 },
            best_month = { month = "2026-03", pages = 1500, duration = 40000 },
            hours = { [22] = 9000, [8] = 1000 },
        }
    end

    before_each(function()
        saved = {}
        for _i, name in ipairs(names) do saved[name] = package.loaded[name] or false end
        shown, saves_at_show, queries, month = nil, nil, 0, "11"
        data = rich_year()
        -- Deterministic clock: os.time encodes month/day, os.date decodes it.
        original_date, original_time = os.date, os.time
        rawset(os, "time", function(t) return t and t.month * 100 + t.day or 0 end)
        rawset(os, "date", function(fmt, ts)
            if fmt == "%m" then return month end
            if fmt == "%Y" then return "2026" end
            if fmt == "%B" then return MONTHS[math.floor(ts / 100)] end
            if fmt == "%b" then return MONTHS[math.floor(ts / 100)]:sub(1, 3) end
            if fmt == "*t" then return { day = ts % 100 } end
            return original_date(fmt, ts)
        end)
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ffi/util", { template = function(text, ...)
            local args = { ... }
            return (text:gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end))
        end })
        ZenSpec.replace("datetime", {
            secondsToClockDuration = function(_fmt, secs) return math.floor(secs / 60) .. "m" end,
            shortMonthTranslation = {}, longMonthTranslation = { March = "März" },
        })
        ZenSpec.replace("common/plugin_root", "/plugin")
        ZenSpec.replace("common/utils", { resolveIcon = function(_dir, name) return "/icons/" .. name .. ".svg" end })
        ZenSpec.replace("common/db_stats", { queryWrapped = function() queries = queries + 1; return data end })
        ZenSpec.replace("common/db_library", { getBookCounts = function() return { finished_this_year = 3 } end })
        ZenSpec.replace("common/db_bookinfo", { findPathByTitleAuthors = function() return nil end })
        ZenSpec.replace("common/ui/wrapped_screen", { new = function(_self, spec) return spec end })
        ZenSpec.unload("common/reading_wrapped")
        Wrapped = require("common/reading_wrapped")
    end)

    after_each(function()
        rawset(os, "date", original_date)
        rawset(os, "time", original_time)
        ZenSpec.unload("common/reading_wrapped")
        for _i, name in ipairs(names) do package.loaded[name] = saved[name] or nil end
    end)

    local function plugin(shown_for)
        local p = { config = { _meta = { wrapped_shown_for = shown_for } }, saves = 0 }
        function p:saveConfig() self.saves = self.saves + 1 end
        ZenSpec.replace("ui/uimanager", { show = function(_self, w) shown = w; saves_at_show = p.saves end })
        return p
    end

    local function stats(pages)
        local out = {}
        for _i, page in ipairs(pages) do out[#out + 1] = page.stat end
        return out
    end

    it("builds every slide for a rich year", function()
        local pages = Wrapped.buildPages(data, 3)
        assert.are.same({
            "2026", "200m", "4200", "4", "Dune", "Frank Herbert", "Jane Austen", "Dune", "Dune",
            "5", "120m", "März", "Bedtime reader", "That's a wrap",
        }, stats(pages))
        assert.are.equal("books read, 3 finished", pages[4].stat_label)
        assert.are.equal("3 books this year", pages[7].stat_label)
        assert.are.equal("5 highlights and notes", pages[9].stat_label)
        assert.are.equal("day streak", pages[10].stat_label)
        assert.are.equal("Mar 14, 120 pages", pages[11].stat_label)
        assert.are.equal("1500 pages", pages[12].stat_label)
        assert.are.equal("21:00 – 23:59", pages[13].stat_label)
        for _i, page in ipairs(pages) do
            assert.is_string(page.icon)
            assert.is_true(#page.description > 0)
            assert.is_nil(page.description:find("%1", 1, true))
        end
    end)

    it("skips empty slides and merges the author slides", function()
        data.authors = { { name = "Jane Austen", duration = 9000, books = 3 } }
        data.series, data.most_annotated, data.longest_streak, data.hours = {}, nil, 1, {}
        local pages = Wrapped.buildPages(data, nil)
        assert.are.same({ "2026", "200m", "4200", "4", "Dune", "Jane Austen", "120m", "März", "That's a wrap" }, stats(pages))
        assert.are.equal("books read", pages[4].stat_label)
    end)

    it("names the reading rhythm and falls back to all-day", function()
        assert.are.equal("Night owl", Wrapped.rhythm({ [1] = 100, [2] = 50 }).label)
        assert.are.equal("All-day reader", Wrapped.rhythm({ [1] = 10, [7] = 10, [10] = 10, [15] = 10, [19] = 10 }).label)
        assert.is_nil(Wrapped.rhythm({}))
    end)

    it("shows a single friendly page when the year is empty", function()
        data = { year = 2026, duration = 0, pages = 0, books = 0, top_books = {}, authors = {}, series = {}, days = {}, hours = {}, longest_streak = 0 }
        plugin(false)
        Wrapped.show()
        assert.are.equal(1, #shown.pages)
        assert.are.equal("No reading data for 2026 yet. Come back after a few good books.", shown.pages[1].description)
    end)

    it("auto-shows once on the intro boot and saves before showing", function()
        local p = plugin(false)
        assert.is_true(Wrapped.maybeAutoShow(p))
        assert.are.equal("2026", p.config._meta.wrapped_shown_for)
        assert.are.equal(1, saves_at_show)
        assert.are.equal(14, #shown.pages)
        shown = nil
        assert.is_false(Wrapped.maybeAutoShow(p))
        assert.is_nil(shown)
        assert.are.equal(1, queries)
    end)

    it("consumes the intro without showing when the year is too short", function()
        data.duration = 100
        local p = plugin(nil)
        assert.is_false(Wrapped.maybeAutoShow(p))
        assert.are.equal("", p.config._meta.wrapped_shown_for)
        assert.are.equal(1, p.saves)
        assert.is_nil(shown)
    end)

    it("shows again only in December of a new year", function()
        local p = plugin("2025")
        assert.is_false(Wrapped.maybeAutoShow(p))
        assert.are.equal(0, queries)
        month = "12"
        assert.is_true(Wrapped.maybeAutoShow(p))
        assert.are.equal("2026", p.config._meta.wrapped_shown_for)
        shown = nil
        assert.is_false(Wrapped.maybeAutoShow(p))
        assert.is_nil(shown)
    end)
end)
