describe("Reading Wrapped", function()
    local Wrapped
    local shown, saves_at_show, queries, month, cover_paths, cached_titles, period_queries
    local original_date, original_time
    local MONTHS = { "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December" }
    local names = {
        "gettext", "ffi/util", "datetime", "common/plugin_root", "common/utils", "common/db_stats",
        "common/db_library", "common/db_bookinfo", "common/ui/wrapped_screen", "ui/uimanager",
        "bookinfomanager", "config/manager", "common/reading_wrapped",
    }
    local saved
    local data, counts

    local function rich_year()
        return {
            year = 2026, pages = 4200, duration = 12000, books = 4,
            top_books = {
                { id = 1, title = "Dune", authors = "Frank Herbert", series = "Dune #1", annotations = 5, duration = 6000, pages = 900 },
                { id = 2, title = "Emma", authors = "Jane Austen", series = "N/A", annotations = 0, duration = 3000, pages = 1200 },
                { id = 3, title = "Dune Messiah", authors = "Frank Herbert", series = "Dune #2", annotations = 0, duration = 1200, pages = 300 },
                { id = 4, title = "Persuasion", authors = "Jane Austen", series = "N/A", annotations = 0, duration = 900, pages = 200 },
            },
            authors = {
                { name = "Frank Herbert", duration = 7200, books = 2 },
                { name = "Jane Austen", duration = 3900, books = 3 },
            },
            series = { { name = "Dune", duration = 7200, books = 2 } },
            most_annotated = { id = 1, title = "Dune", authors = "Frank Herbert", annotations = 5 },
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
        shown, saves_at_show, queries, month, period_queries = nil, nil, 0, "11", {}
        data = rich_year()
        counts = { finished_this_year = 2, finished_books = {
            { file = "/books/emma.epub", modified = "2026-10-02 10:00:00" },
            { file = "/books/old.epub", modified = "2025-12-30 10:00:00" },
            { file = "/books/dune.epub", modified = "2026-04-01 10:00:00" },
        } }
        cover_paths = { Dune = "/books/dune.epub", Emma = "/books/emma.epub", ["Dune Messiah"] = "/books/messiah.epub" }
        cached_titles = { ["/books/emma.epub"] = "Emma" }
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
        ZenSpec.replace("common/db_stats", {
            queryWrapped = function() queries = queries + 1; return data end,
            dayShift = function() return 0 end,
            queryBooksForPeriod = function(from, to)
                period_queries[#period_queries + 1] = { from, to }
                return { { title = "Dune", book_id = 1 }, { title = "Emma", book_id = 2 }, { title = "Gone", book_id = 99 } }
            end,
        })
        ZenSpec.replace("common/db_library", { getBookCounts = function() return counts end })
        ZenSpec.replace("common/db_bookinfo", { findPathByTitleAuthors = function(title) return cover_paths[title] end })
        ZenSpec.replace("bookinfomanager", { getBookInfo = function(_self, path)
            return { has_cover = true, cover_fetched = true, cover_w = 200, cover_h = 300,
                title = cached_titles[path], cover_bb = { path = path, free = function() end } }
        end })
        ZenSpec.replace("config/manager", { get = function() return { features = { browser_cover_rounded_corners = true } } end })
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

    local function column(pages, key)
        local out = {}
        for _i, page in ipairs(pages) do out[#out + 1] = page[key] or false end
        return out
    end

    local function cover_paths_of(page)
        local out = {}
        for _i, cover in ipairs(page.covers or {}) do out[#out + 1] = cover.bb.path end
        return out
    end

    it("builds every slide for a rich year with covers", function()
        local pages, owned = Wrapped.buildPages(data, counts)
        assert.are.same({
            "Reading Wrapped", "Books read", "Recently finished", "Time spent reading", "Pages turned", "Top book",
            "Favorite author", "Most books by one author", "Top series", "Most highlighted", "Longest streak",
            "Biggest day", "Best month", "Reading rhythm", "That's a wrap",
        }, column(pages, "title"))
        -- Recently finished names the newest finished book.
        assert.are.same({
            "2026", "4", "Emma", "200m", "4200", "Dune", "Frank Herbert", "Jane Austen", "Dune", "Dune",
            "5 days", "120m", "März", "Bedtime reader", false,
        }, column(pages, "stat"))
        -- Coverflows of up to three books (two fall back to a grid), single covers elsewhere.
        assert.are.same({ "/books/dune.epub", "/books/emma.epub", "/books/messiah.epub" }, cover_paths_of(pages[2]))
        assert.are.equal("flow", pages[2].layout)
        assert.are.same({ "/books/emma.epub", "/books/dune.epub" }, cover_paths_of(pages[3]))
        assert.are.equal("grid", pages[3].layout)
        assert.are.equal("flow", pages[4].layout)
        assert.are.same({ "/books/emma.epub" }, cover_paths_of(pages[5]))
        assert.are.equal("Most in Emma (1200 pages)", pages[5].stat_label)
        assert.are.same({ "/books/dune.epub" }, cover_paths_of(pages[6]))
        assert.are.same({ "/books/dune.epub", "/books/messiah.epub" }, cover_paths_of(pages[7]))
        assert.are.same({ "/books/emma.epub" }, cover_paths_of(pages[8]))
        assert.are.equal("3 books this year", pages[8].stat_label)
        assert.are.same({ "/books/dune.epub", "/books/messiah.epub" }, cover_paths_of(pages[9]))
        assert.are.equal("5 highlights and notes", pages[10].stat_label)
        assert.are.same({ "/books/dune.epub" }, cover_paths_of(pages[10]))
        assert.is_nil(pages[11].stat_label)
        assert.are.equal("Mar 14, 120 pages", pages[12].stat_label)
        assert.are.same({ "/books/dune.epub", "/books/emma.epub" }, cover_paths_of(pages[12]))
        assert.are.same({ { 314, 314 + 86400 } }, period_queries)
        assert.are.equal("1500 pages, 666m", pages[13].stat_label)
        assert.are.equal("21:00 – 23:59", pages[14].stat_label)
        assert.are.equal("See you in 2027", pages[15].stat_label)
        -- One blitbuffer per distinct path, shared across slides.
        assert.are.equal(3, #owned)
        for _i, page in ipairs(pages) do
            assert.is_string(page.icon)
            assert.is_true(#page.description > 0)
            assert.is_nil(page.description:find("%1", 1, true))
        end
    end)

    it("skips empty slides, merges the author slides and drops icons-only pages gracefully", function()
        data.authors = { { name = "Jane Austen", duration = 9000, books = 3 } }
        data.series, data.most_annotated, data.longest_streak, data.hours = {}, nil, 1, {}
        cover_paths = {}
        local pages, owned = Wrapped.buildPages(data, nil)
        assert.are.same({
            "Reading Wrapped", "Books read", "Time spent reading", "Pages turned", "Top book",
            "Favorite author", "Biggest day", "Best month", "That's a wrap",
        }, column(pages, "title"))
        assert.are.equal(0, #owned)
        for _i, page in ipairs(pages) do assert.is_nil(page.covers) end
    end)

    it("fills quips with the exact numbers behind them", function()
        local original_random = math.random
        finally(function() rawset(math, "random", original_random) end)
        local function descriptions(choose)
            rawset(math, "random", choose)
            return column(Wrapped.buildPages(data, counts), "description")
        end
        local first = descriptions(function() return 1 end)
        assert.are.equal("60% of your reading year. Should we tell Frank Herbert?", first[7])
        assert.are.equal("5 days in a row. Your book started expecting you.", first[11])
        local last = descriptions(function(n) return n end)
        assert.are.equal("3 books in. You're committed now.", last[8])
        data.duration, data.books, data.pages = 151 * 3600, 30, 12345
        first = descriptions(function() return 1 end)
        assert.are.equal("30 books. Who needs weekends?", first[2])
        assert.are.equal("You could have watched every Lord of the Rings extended cut… 13 times. You chose books.", first[4])
        assert.are.equal("12345 pages. The paper industry sends its regards.", first[5])
        last = descriptions(function(n) return n end)
        assert.are.equal("That's a transatlantic flight. 9 of them. Round trip.", last[4])
    end)

    it("names a finished book after its file when the cover cache has no title", function()
        cached_titles = {}
        assert.are.equal("emma", Wrapped.buildPages(data, counts)[3].stat)
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
        assert.is_true(shown.rounded_covers)
    end)

    it("leaves cover corners square when the rounded corners setting is off", function()
        ZenSpec.replace("config/manager", { get = function() return { features = { browser_cover_rounded_corners = false } } end })
        plugin(false)
        Wrapped.show()
        assert.is_true(#shown.pages > 1)
        assert.is_false(shown.rounded_covers)
    end)

    it("auto-shows once on the intro boot and saves before showing", function()
        local p = plugin(false)
        assert.is_true(Wrapped.maybeAutoShow(p))
        assert.are.equal("2026", p.config._meta.wrapped_shown_for)
        assert.are.equal(1, saves_at_show)
        assert.are.equal(15, #shown.pages)
        assert.are.equal(3, #shown.covers_owned)
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
