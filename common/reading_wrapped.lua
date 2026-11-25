-- common/reading_wrapped.lua
-- Yearly Reading Wrapped recap: turns StatsDB.queryWrapped() into WrappedScreen slides,
-- one stat, covers where a book is involved, and a quip each. Auto-shows once after the
-- release that added it and once per December; always available from Zen Settings > About.

local _ = require("gettext")
local T = require("ffi/util").template
local datetime = require("datetime")

local M = {}
M.MIN_DURATION = 600 -- seconds read this year below which auto-show is skipped
M.MAX_FLOW = 3       -- covers in a coverflow

local _plugin_root = require("common/plugin_root") or ""

local function icon(name)
    return require("common/utils").resolveIcon(_plugin_root .. "/icons/", name)
end

local function fmt_time(secs)
    return datetime.secondsToClockDuration("letters", math.floor(secs or 0), true)
end

local function month_name(ts, long)
    local key = os.date(long and "%B" or "%b", ts)
    return (long and datetime.longMonthTranslation or datetime.shortMonthTranslation)[key] or key
end

local function date_parts(date)
    local year, month, day = tostring(date or ""):match("^(%d+)%-(%d+)%-(%d+)$")
    return tonumber(year), tonumber(month), tonumber(day)
end

local function date_ts(date)
    local year, month, day = date_parts(date)
    return year and os.time({ year = year, month = month, day = day, hour = 12 })
end

-- nil for empty or KOReader's "N/A" placeholder.
local function clean(text)
    text = tostring(text or ""):match("^%s*(.-)%s*$")
    if text == "" or text == "N/A" then return nil end
    return text
end

local function series_name(text)
    return clean((tostring(text or ""):gsub("%s+#%S+$", "")))
end

local function any(quips)
    return quips[math.random(#quips)]
end

-- tiers = { { upper_bound, { quips } }, ... }: the first tier whose bound exceeds value wins.
local function pick(tiers, value)
    for _i, tier in ipairs(tiers) do
        if value < tier[1] then return any(tier[2]) end
    end
end

-- Numbers in quips are template arguments, never literals, so they always match the data.
local LOTR_HOURS = 11.4  -- extended trilogy
local FLIGHT_HOURS = 16  -- transatlantic round trip

local TIME_QUIPS = { -- hours; %1 hours, %2 full days, %3 trilogy runs, %4 round trips
    { 5, { _("A quiet year. The books are patient."), _("Short and sweet. Every page still counts."), _("Warm-up lap. Next year we sprint.") } },
    { 20, { _("A long weekend's worth of reading. Not bad at all."), _("That's a full binge-watch session, but with better dialogue.") } },
    { 50, { _("%1 hours lost in other worlds. Worth every one."), _("That's a lot of pages turned instead of doom-scrolled.") } },
    { 100, { _("%2 full days of your life, spent entirely on purpose."), _("Your screen time report would be jealous.") } },
    { 250, { _("You could have watched every Lord of the Rings extended cut… %3 times. You chose books."), _("That's a transatlantic flight. %4 of them. Round trip.") } },
    { 500, { _("%2 solid days of reading. Sleep is for people with fewer books."), _("At this point the library owes you a key.") } },
    { math.huge, { _("%2 days, non-stop, nose in a book. Legendary."), _("You didn't read this year. You lived there.") } },
}

local PAGE_QUIPS = { -- %1 pages
    { 500, { _("A solid start. Every page is a small win."), _("Pages add up. So does the habit.") } },
    { 2000, { _("That's a doorstopper and then some."), _("Enough pages to prop open every door in the house.") } },
    { 5000, { _("Thousands of pages. Your thumb deserves a medal."), _("A small library's worth of page turns.") } },
    { 10000, { _("Five figures are in sight. Keep turning."), _("That's a bookshelf you read, not just owned.") } },
    { math.huge, { _("%1 pages. The paper industry sends its regards."), _("%1 pages. Some people run marathons. You read them.") } },
}

local BOOK_QUIPS = { -- %1 books
    { 2, { _("One book. Chosen carefully, loved completely."), _("Quality over quantity. Very dignified.") } },
    { 6, { _("A handful of good ones. Your to-be-read pile trembles a little."), _("A small stack. A strong stack.") } },
    { 13, { _("%1 books this year. Textbook consistency."), _("%1 books a year keeps the algorithm away.") } },
    { 26, { _("Your to-be-read pile has started negotiating."), _("%1 and counting. Your ereader is well used.") } },
    { 51, { _("%1 books. Who needs weekends?"), _("Your ereader called. It wants a raise.") } },
    { 101, { _("%1 books in one year. Do you… sleep?"), _("At this pace, publishers should be scared of you.") } },
    { math.huge, { _("%1 books. We checked twice."), _("You are no longer reading books. You are consuming them.") } },
}

local FINISHED_QUIPS = {
    _("Fresh off the last page. The book hangover is real."),
    _("The end. Now what are you supposed to do with your evenings?"),
    _("Finished. Did you read the acknowledgments, though? Be honest."),
}
local TOP_BOOK_QUIPS = { -- %1 percent of the year's reading time
    _("You two were inseparable. People talked."),
    _("The other books know. They've made their peace."),
    _("It wasn't a phase. It was %1% of your reading year."),
    _("Somewhere in here is a chapter you stayed up for. You know the one."),
}

local AUTHOR_QUIPS = { -- percent of the year's reading time; %1 author, %2 percent
    { 15, { _("You two had a nice thing going."), _("%1 made the shortlist. Fancy.") } },
    { 30, { _("Wow, you really must like their writing."), _("%1 took a solid slice of your year.") } },
    { 50, { _("%2% of your reading year belonged to %1. Flattering, honestly."), _("You and %1: it's practically a book club of two.") } },
    { 75, { _("%2% of your reading year. Should we tell %1?"), _("At this point you're less a reader, more a devoted fan.") } },
    { math.huge, { _("%2% of your year had one author. Their name is %1."), _("You didn't read %1. You moved in.") } },
}

local PROLIFIC_QUIPS = { -- books by one author; %1 author, %2 books
    { 3, { _("Two by %1. Once is curiosity. Twice is a pattern."), _("Came back for seconds. Fair.") } },
    { 5, { _("Starting a collection, are we?"), _("%2 books in. You're committed now.") } },
    { 10, { _("You're working through %1's backlist like it's a quest."), _("Their publisher should send you a card.") } },
    { math.huge, { _("%2 books. You're not a reader of %1. You're an archive."), _("At this point %1 should name a character after you.") } },
}

local SERIES_QUIPS = { -- books from the series this year; %1 series
    { 2, { _("One book in. The rest of the series is already watching you."), _("Just the one. That's what everyone says before book five."), _("One down. Your free time has been warned.") } },
    { 4, { _("You said you'd read something else in between. You did not."), _("Your other books waited politely. You didn't notice.") } },
    { 7, { _("You now have strong opinions about side characters."), _("You know these characters better than some of your relatives."), _("Your other books filed a missing person report.") } },
    { math.huge, { _("You don't visit %1. You pay rent there."), _("Somewhere, an author is nervously typing faster."), _("The real world called. It went to voicemail."), _("That's not a series anymore. That's a second address.") } },
}

local ANNOTATION_QUIPS = { -- highlights and notes in the book
    { 5, { _("Picky. Only the good stuff made the cut."), _("Something in here stopped you cold. Good lines do that.") } },
    { 25, { _("You came for the story and left with receipts."), _("Enough quotes to win any argument about this book.") } },
    { 100, { _("You didn't read this book. You interviewed it."), _("This book left a mark. You returned the favor.") } },
    { math.huge, { _("Quicker to highlight the parts you didn't like."), _("That's not highlighting. That's redecorating."), _("At this point you're a co-author.") } },
}

local STREAK_QUIPS = { -- days; %1 days
    { 7, { _("%1 days in a row. Your book started expecting you.") } },
    { 21, { _("%1 days straight. Your gym membership is jealous.") } },
    { 60, { _("%1 days without a miss. A certain green owl would be proud.") } },
    { math.huge, { _("It's no longer a streak. It's a personality trait."), _("Even your charger took more days off than you.") } },
}

local BEST_DAY_QUIPS = { -- %1 pages that day
    _("Whatever you had planned that day, the book won."),
    _("Someone texted you that day. They're still waiting."),
    _("You said \"one more page\" exactly %1 times."),
    _("That's not a reading session. That's a disappearance."),
}
local MONTH_QUIPS = {
    _("Nobody saw you in %1. The books did."),
    _("%1 understood the assignment."),
    _("Whatever else happened in %1, you read through it."),
}
local FINALE_QUIPS = {
    _("Thank you for reading with ZenOS. Here's to another year of good books."),
    _("Stories end, readers don't. Charge up, pick the next one, and we'll see you here next year."),
    _("Every page you turned this year was time well spent. Same time next year?"),
}

-- { first_hour, last_hour, label, icon, quips }; the band with the most time wins
-- unless no band holds more than ALL_DAY_SHARE of it.
local BANDS = {
    { 0, 4, _("Night owl"), "moon_outline", { _("Sleep is a suggestion. Pages are a priority."), _("Your best reading happens when the world is off.") } },
    { 5, 8, _("Early bird"), "sun", { _("Chapters before coffee. Respect."), _("You beat the sunrise to the good part.") } },
    { 9, 11, _("Morning reader"), "sun", { _("A fresh mind and a fresh chapter. Nice combo."), _("The day can wait. The book cannot.") } },
    { 12, 13, _("Lunch-break reader"), "sun", { _("Sandwich in one hand, plot twist in the other."), _("Lunch is a reading hour wearing a disguise.") } },
    { 14, 17, _("Afternoon reader"), "sun", { _("Golden light, golden hours."), _("The afternoon slump never stood a chance.") } },
    { 18, 20, _("Evening reader"), "moon_outline", { _("Dinner, then a chapter. Or three."), _("Your evenings have excellent taste.") } },
    { 21, 23, _("Bedtime reader"), "moon_outline", { _("One more chapter turns into midnight. Every time."), _("Your nightlight has seen things.") } },
}
local ALL_DAY = { label = _("All-day reader"), icon = "timer", range = _("spread across the day"),
    quips = { _("Any time is reading time. Any place is a library."), _("No schedule. Just books, whenever.") } }
local ALL_DAY_SHARE = 0.30

-- hours = { [0..23] = seconds }; nil without data.
function M.rhythm(hours)
    local total, best, best_sum = 0, nil, 0
    for _h, secs in pairs(hours or {}) do total = total + secs end
    if total <= 0 then return nil end
    for _i, band in ipairs(BANDS) do
        local sum = 0
        for hour = band[1], band[2] do sum = sum + (hours[hour] or 0) end
        if sum > best_sum then best, best_sum = band, sum end
    end
    if not best or best_sum / total <= ALL_DAY_SHARE then return ALL_DAY end
    return {
        label = best[3], icon = best[4], quips = best[5],
        range = string.format("%02d:00 – %02d:59", best[1], best[2]),
    }
end

-- Covers come from the CoverBrowser cache; one blitbuffer per path, all freed on close.
local function cover_loader()
    local cache, owned = {}, {}
    local loader = { owned = owned }
    function loader.from_path(path)
        if not path then return nil end
        if cache[path] == nil then
            local ok, cover = pcall(function()
                local info = require("bookinfomanager"):getBookInfo(path, true)
                if info and info.has_cover and info.cover_bb and info.cover_fetched and not info.ignore_cover then
                    return { bb = info.cover_bb, w = info.cover_w, h = info.cover_h }
                end
            end)
            cache[path] = ok and cover or false
            if cache[path] then owned[#owned + 1] = cache[path].bb end
        end
        return cache[path] or nil
    end
    -- Statistics rows carry no path; match the cached title and authors.
    function loader.for_book(book)
        if book.path == nil then
            local ok, path = pcall(function()
                return require("common/db_bookinfo").findPathByTitleAuthors(book.title, book.authors)
            end)
            book.path = ok and path or false
        end
        return loader.from_path(book.path or nil)
    end
    -- Title from the CoverBrowser cache, else the file name.
    function loader.title(path)
        local ok, info = pcall(function() return require("bookinfomanager"):getBookInfo(path, false) end)
        return ok and info and clean(info.title) or clean(path:match("([^/]+)%.[^./]+$") or path)
    end
    function loader.covers(books, limit)
        local covers = {}
        for _i, book in ipairs(books) do
            if #covers >= limit then break end
            local cover = loader.for_book(book)
            if cover then covers[#covers + 1] = cover end
        end
        return covers
    end
    return loader
end

local function books_by(data, match)
    local books = {}
    for _i, book in ipairs(data.top_books) do
        if match(book) then books[#books + 1] = book end
    end
    return books
end

local function author_books(data, name)
    return books_by(data, function(book)
        for author in (book.authors or ""):gmatch("[^\n]+") do
            if author:match("^%s*(.-)%s*$") == name then return true end
        end
    end)
end

-- Books with sessions on the best day, most time first.
local function day_books(data, best)
    local year, month, day = date_parts(best.date)
    if not year then return {} end
    local StatsDB = require("common/db_stats")
    local start = os.time({ year = year, month = month, day = day, hour = 0 }) + StatsDB.dayShift()
    local by_id = {}
    for _i, book in ipairs(data.top_books) do by_id[book.id] = book end
    local books = {}
    for _i, row in ipairs(StatsDB.queryBooksForPeriod(start, start + 86400)) do
        if by_id[row.book_id] then books[#books + 1] = by_id[row.book_id] end
    end
    return books
end

-- Returns pages and the cover blitbuffers they borrow (owned by the caller).
function M.buildPages(data, counts)
    local loader = cover_loader()
    local pages = {}
    local year = tostring(data.year)
    local function add(page) pages[#pages + 1] = page end
    local function percent(secs)
        return data.duration > 0 and math.floor(secs / data.duration * 100 + 0.5) or 0
    end
    local function with_covers(page, books, limit)
        local covers = loader.covers(books, limit)
        if #covers > 0 then
            page.covers = covers
            page.layout = #covers >= M.MAX_FLOW and "flow" or "grid"
        end
        return page
    end

    add{ title = _("Reading Wrapped"), icon = icon("zen_ui"), stat = year,
        stat_label = _("Your year in books"), description = _("Swipe to begin.") }

    add(with_covers({ title = _("Books read"), icon = icon("bookshelf"), stat = tostring(data.books),
        description = T(pick(BOOK_QUIPS, data.books), data.books) }, data.top_books, M.MAX_FLOW))

    local finished = counts and tonumber(counts.finished_this_year) or 0
    if finished > 0 then
        local recent = {}
        for _i, entry in ipairs(counts.finished_books or {}) do
            if #recent >= M.MAX_FLOW then break end
            if tostring(entry.modified):sub(1, 4) == year then recent[#recent + 1] = { path = entry.file } end
        end
        -- Name the book whose cover leads the layout: the newest one that has a cover.
        local latest = recent[1]
        for _i, book in ipairs(recent) do
            if loader.for_book(book) then latest = book; break end
        end
        add(with_covers({ title = _("Recently finished"), icon = icon("settings_book_check"),
            stat = latest and loader.title(latest.path), description = any(FINISHED_QUIPS) }, recent, M.MAX_FLOW))
    end

    local hours = data.duration / 3600
    add(with_covers({ title = _("Time spent reading"), icon = icon("timer"), stat = fmt_time(data.duration),
        description = T(pick(TIME_QUIPS, hours), math.floor(hours), math.floor(hours / 24),
            math.floor(hours / LOTR_HOURS), math.floor(hours / FLIGHT_HOURS)) }, data.top_books, M.MAX_FLOW))

    local most_pages
    for _i, book in ipairs(data.top_books) do
        if book.pages > 0 and (not most_pages or book.pages > most_pages.pages) then most_pages = book end
    end
    add(with_covers({ title = _("Pages turned"), icon = icon("book_open"), stat = tostring(data.pages),
        stat_label = most_pages and clean(most_pages.title)
            and T(_("Most in %1 (%2 pages)"), clean(most_pages.title), most_pages.pages) or nil,
        description = T(pick(PAGE_QUIPS, data.pages), data.pages) }, { most_pages }, 1))

    local top = data.top_books[1]
    if top and clean(top.title) then
        add(with_covers({ title = _("Top book"), icon = icon("settings_star"), stat = clean(top.title),
            stat_label = T(_("%1 of reading time"), fmt_time(top.duration)),
            description = T(any(TOP_BOOK_QUIPS), percent(top.duration)) }, { top }, 1))
    end

    local author = data.authors[1]
    if author then
        local share = percent(author.duration)
        add(with_covers({ title = _("Favorite author"), icon = icon("tab_authors"), stat = author.name,
            stat_label = T(_("%1 of reading time"), fmt_time(author.duration)),
            description = T(pick(AUTHOR_QUIPS, share), author.name, share) }, author_books(data, author.name), M.MAX_FLOW))
    end
    local prolific
    for _i, group in ipairs(data.authors) do
        if group.books >= 2 and (not prolific or group.books > prolific.books) then prolific = group end
    end
    if prolific and prolific ~= author then
        add(with_covers({ title = _("Most books by one author"), icon = icon("library_shelves"), stat = prolific.name,
            stat_label = T(_("%1 books this year"), prolific.books),
            description = T(pick(PROLIFIC_QUIPS, prolific.books), prolific.name, prolific.books) }, author_books(data, prolific.name), M.MAX_FLOW))
    end

    local series = data.series[1]
    if series then
        add(with_covers({ title = _("Top series"), icon = icon("tab_series"), stat = series.name,
            stat_label = T(_("%1 of reading time"), fmt_time(series.duration)),
            description = T(pick(SERIES_QUIPS, series.books), series.name) },
            books_by(data, function(book) return series_name(book.series) == series.name end), M.MAX_FLOW))
    end

    local noted = data.most_annotated
    if noted and clean(noted.title) then
        add(with_covers({ title = _("Most highlighted"), icon = icon("annotations"), stat = clean(noted.title),
            stat_label = noted.annotations == 1 and _("1 highlight or note")
                or T(_("%1 highlights and notes"), noted.annotations),
            description = pick(ANNOTATION_QUIPS, noted.annotations) }, { noted }, 1))
    end

    if data.longest_streak >= 2 then
        add{ title = _("Longest streak"), icon = icon("flame"), stat = T(_("%1 days"), data.longest_streak),
            description = T(pick(STREAK_QUIPS, data.longest_streak), data.longest_streak) }
    end

    local best = data.best_day
    if best and best.duration > 0 then
        local ts = date_ts(best.date)
        add(with_covers({ title = _("Biggest day"), icon = icon("lightning"), stat = fmt_time(best.duration),
            stat_label = ts and T(_("%1 %2, %3 pages"), month_name(ts), os.date("*t", ts).day, best.pages)
                or T(_("%1 pages"), best.pages),
            description = T(any(BEST_DAY_QUIPS), best.pages) }, day_books(data, best), M.MAX_FLOW))
    end

    local month = data.best_month
    if month and month.pages > 0 then
        local ts = date_ts(month.month .. "-15")
        local name = ts and month_name(ts, true) or month.month
        add{ title = _("Best month"), icon = icon("calendar"), stat = name,
            stat_label = T(_("%1 pages, %2"), month.pages, fmt_time(month.duration)),
            description = T(any(MONTH_QUIPS), name) }
    end

    local band = M.rhythm(data.hours)
    if band then
        add{ title = _("Reading rhythm"), icon = icon(band.icon), stat = band.label,
            stat_label = band.range, description = any(band.quips) }
    end

    add{ title = _("That's a wrap"), icon = icon("zen_ui"), stat_label = T(_("See you in %1"), data.year + 1),
        description = any(FINALE_QUIPS) }
    return pages, loader.owned
end

function M.emptyPages(data)
    return { {
        title = _("Reading Wrapped"), icon = icon("zen_ui"), stat = tostring(data.year), stat_label = _("Your year in books"),
        description = T(_("No reading data for %1 yet. Come back after a few good books."), data.year),
    } }, {}
end

local function rounded_covers()
    local config = require("config/manager").get()
    return type(config) == "table" and type(config.features) == "table"
        and config.features.browser_cover_rounded_corners == true
end

local function present(pages, owned, on_close)
    local WrappedScreen = require("common/ui/wrapped_screen")
    require("ui/uimanager"):show(WrappedScreen:new{
        pages = pages, covers_owned = owned, rounded_covers = rounded_covers(), on_close = on_close,
    })
end

function M.load()
    local data = require("common/db_stats").queryWrapped()
    local counts
    if data.duration > 0 then
        local ok, result = pcall(function() return require("common/db_library").getBookCounts() end)
        counts = ok and type(result) == "table" and result or nil
    end
    return data, counts
end

function M.show(on_close)
    local data, counts = M.load()
    local pages, owned
    if data.duration > 0 then pages, owned = M.buildPages(data, counts) else pages, owned = M.emptyPages(data) end
    present(pages, owned, on_close)
    return true
end

-- Once after the release that added Wrapped (shown_for still false), then once per December.
function M.maybeAutoShow(plugin)
    local meta = plugin.config._meta
    local year = os.date("%Y")
    local shown = meta.wrapped_shown_for
    local intro = not shown
    if not intro and not (os.date("%m") == "12" and shown ~= year) then return false end
    local data, counts = M.load()
    if data.duration < M.MIN_DURATION then
        -- "" consumes the intro while leaving the December rule armed.
        meta.wrapped_shown_for = intro and "" or year
        plugin:saveConfig()
        return false
    end
    -- Persist before showing so a force-quit does not replay it.
    meta.wrapped_shown_for = year
    plugin:saveConfig()
    present(M.buildPages(data, counts))
    return true
end

return M
