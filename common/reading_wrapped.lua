-- common/reading_wrapped.lua
-- Yearly Reading Wrapped recap: turns StatsDB.queryWrapped() into WrappedScreen slides,
-- one stat and one quip each. Auto-shows once after the release that added it and once
-- per December; always available from Zen Settings > About.

local _ = require("gettext")
local T = require("ffi/util").template
local datetime = require("datetime")

local M = {}
M.MIN_DURATION = 600 -- seconds read this year below which auto-show is skipped

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

local function date_ts(date)
    local year, month, day = tostring(date or ""):match("^(%d+)%-(%d+)%-(%d+)$")
    return year and os.time({ year = tonumber(year), month = tonumber(month), day = tonumber(day), hour = 12 })
end

-- nil for empty or KOReader's "N/A" placeholder.
local function clean(text)
    text = tostring(text or ""):match("^%s*(.-)%s*$")
    if text == "" or text == "N/A" then return nil end
    return text
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

local TIME_QUIPS = { -- hours
    { 5, { _("A quiet year. The books are patient."), _("Short and sweet. Every page still counts."), _("Warm-up lap. Next year we sprint.") } },
    { 20, { _("A long weekend's worth of reading. Not bad at all."), _("That's a full binge-watch session, but with better dialogue.") } },
    { 50, { _("A whole work week lost in other worlds."), _("That's a lot of pages turned instead of doom-scrolled.") } },
    { 100, { _("Two full days of your life, spent entirely on purpose."), _("Your screen time report would be jealous.") } },
    { 250, { _("You could have watched every Lord of the Rings extended cut… 10 times. You chose books."), _("That's a transatlantic flight. Twelve of them. Round trip.") } },
    { 500, { _("Ten solid days of reading. Sleep is for people with fewer books."), _("At this point the library owes you a key.") } },
    { math.huge, { _("Three weeks, non-stop, nose in a book. Legendary."), _("You didn't read this year. You lived there.") } },
}

local PAGE_QUIPS = {
    { 500, { _("A solid start. Every page is a small win."), _("Pages add up. So does the habit.") } },
    { 2000, { _("That's a doorstopper and then some."), _("Enough pages to prop open every door in the house.") } },
    { 5000, { _("Thousands of pages. Your thumb deserves a medal."), _("A small library's worth of page turns.") } },
    { 10000, { _("Five figures are in sight. Keep turning."), _("That's a bookshelf you read, not just owned.") } },
    { math.huge, { _("Five digits. The paper industry sends its regards."), _("Ten thousand pages. Some people run marathons. You read them.") } },
}

local BOOK_QUIPS = {
    { 2, { _("One book. Chosen carefully, loved completely."), _("Quality over quantity. Very dignified.") } },
    { 6, { _("A handful of good ones. Your to-be-read pile trembles a little."), _("A small stack. A strong stack.") } },
    { 13, { _("About one a month. Textbook consistency."), _("A book per month keeps the algorithm away.") } },
    { 26, { _("Your to-be-read pile has started negotiating."), _("Two a month. Your ereader is well used.") } },
    { 51, { _("A book a week, who needs weekends?"), _("Your ereader called. It wants a raise.") } },
    { 101, { _("More than one a week. Do you… sleep?"), _("At this pace, publishers should be scared of you.") } },
    { math.huge, { _("Triple digits. We checked twice."), _("You are no longer reading books. You are consuming them.") } },
}

local TOP_BOOK_QUIPS = { _("Wow, you really couldn't put this one down."), _("This one owned your year.") }

local AUTHOR_QUIPS = { -- share of the year's reading time
    { 0.15, { _("You two had a nice thing going."), _("%1 made the shortlist. Fancy.") } },
    { 0.30, { _("Wow, you really must like their writing."), _("%1 took a solid slice of your year.") } },
    { 0.50, { _("A third of your year belonged to %1. Flattering, honestly."), _("You and %1: it's practically a book club of two.") } },
    { 0.75, { _("Half your reading year. Should we tell %1?"), _("At this point you're less a reader, more a devoted fan.") } },
    { math.huge, { _("Your year had one author. Their name is %1."), _("You didn't read %1. You moved in.") } },
}

local PROLIFIC_QUIPS = { -- books by one author
    { 3, { _("Two by %1. Once is curiosity. Twice is a pattern."), _("Came back for seconds. Fair.") } },
    { 5, { _("Starting a collection, are we?"), _("Three or four in. You're committed now.") } },
    { 10, { _("You're working through %1's backlist like it's a quest."), _("Their publisher should send you a card.") } },
    { math.huge, { _("Double digits. You're not a reader of %1. You're an archive."), _("At this point %1 should name a character after you.") } },
}

local SERIES_QUIPS = { -- books from the series this year
    { 2, { _("Just getting started. The rabbit hole says hi."), _("Book one down. We know how this ends.") } },
    { 4, { _("You got hooked. We saw it happen."), _("Just one more chapter, said nobody who ever finished a series.") } },
    { 7, { _("The series isn't finished with you yet."), _("Characters at this point are basically family.") } },
    { math.huge, { _("Marathon status unlocked. Catch your breath."), _("Seven plus. Is there anything left to read in that world?") } },
}

local ANNOTATION_QUIPS = { _("You and your highlighter: an unstoppable duo."), _("Margins were made for this.") }

local STREAK_QUIPS = { -- days
    { 7, { _("A streak is born. Protect it."), _("Back-to-back days. The habit is forming.") } },
    { 21, { _("A full week without missing a day. Routine unlocked."), _("Seven days straight is where habits start to stick.") } },
    { 60, { _("Three weeks in a row. That's not a streak, that's a lifestyle."), _("Weeks of daily pages. Your bookmark never got a break.") } },
    { math.huge, { _("Two months without a miss. Legendary discipline."), _("Day after day after day. The flame is earned.") } },
}

local BEST_DAY_QUIPS = { _("A whole day lost to a good book. No regrets."), _("Chores can wait. Chapters cannot.") }
local MONTH_QUIPS = { _("Peak reading season."), _("%1 was a good month.") }
local FINALE_QUIPS = { _("That's a wrap. See you next year."), _("The end. For now. Next chapter: next year.") }

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

function M.loadCover(book)
    local ok, bb = pcall(function()
        local path = require("common/db_bookinfo").findPathByTitleAuthors(book.title, book.authors)
        if not path then return nil end
        local info = require("bookinfomanager"):getBookInfo(path, true)
        if info and info.has_cover and info.cover_bb and info.cover_fetched and not info.ignore_cover then
            return info.cover_bb
        end
    end)
    return ok and bb or nil
end

-- Slides for a year with data; a slide is skipped when its datum is empty.
function M.buildPages(data, finished)
    local pages = {}
    local function add(page) pages[#pages + 1] = page end
    local year = tostring(data.year)

    add{ icon = icon("zen_ui"), stat = year, stat_label = _("Your year in books"), description = _("Swipe to begin.") }
    add{ icon = icon("timer"), stat = fmt_time(data.duration), stat_label = _("spent reading"),
        description = pick(TIME_QUIPS, data.duration / 3600) }
    add{ icon = icon("book_open"), stat = tostring(data.pages), stat_label = _("pages turned"),
        description = pick(PAGE_QUIPS, data.pages) }
    add{ icon = icon("bookshelf"), stat = tostring(data.books),
        stat_label = finished and T(_("books read, %1 finished"), finished) or _("books read"),
        description = pick(BOOK_QUIPS, data.books) }

    local top = data.top_books[1]
    if top and clean(top.title) then
        add{ icon = icon("settings_star"), image_bb = M.loadCover(top), stat = clean(top.title),
            stat_label = T(_("%1 of reading time"), fmt_time(top.duration)), description = any(TOP_BOOK_QUIPS) }
    end

    local author = data.authors[1]
    if author then
        local share = data.duration > 0 and author.duration / data.duration or 0
        add{ icon = icon("tab_authors"), stat = author.name,
            stat_label = T(_("%1 of reading time"), fmt_time(author.duration)),
            description = T(pick(AUTHOR_QUIPS, share), author.name) }
    end
    local prolific
    for _i, group in ipairs(data.authors) do
        if group.books >= 2 and (not prolific or group.books > prolific.books) then prolific = group end
    end
    if prolific and prolific ~= author then
        add{ icon = icon("library_shelves"), stat = prolific.name,
            stat_label = T(_("%1 books this year"), prolific.books),
            description = T(pick(PROLIFIC_QUIPS, prolific.books), prolific.name) }
    end

    local series = data.series[1]
    if series then
        add{ icon = icon("tab_series"), stat = series.name,
            stat_label = T(_("%1 of reading time"), fmt_time(series.duration)),
            description = pick(SERIES_QUIPS, series.books) }
    end

    local noted = data.most_annotated
    if noted and clean(noted.title) then
        add{ icon = icon("annotations"), stat = clean(noted.title),
            stat_label = noted.annotations == 1 and _("1 highlight or note")
                or T(_("%1 highlights and notes"), noted.annotations),
            description = any(ANNOTATION_QUIPS) }
    end

    if data.longest_streak >= 2 then
        add{ icon = icon("flame"), stat = tostring(data.longest_streak), stat_label = _("day streak"),
            description = pick(STREAK_QUIPS, data.longest_streak) }
    end

    local best = data.best_day
    if best and best.duration > 0 then
        local ts = date_ts(best.date)
        add{ icon = icon("lightning"), stat = fmt_time(best.duration),
            stat_label = ts and T(_("%1 %2, %3 pages"), month_name(ts), os.date("*t", ts).day, best.pages)
                or T(_("%1 pages"), best.pages),
            description = any(BEST_DAY_QUIPS) }
    end

    local month = data.best_month
    if month and month.pages > 0 then
        local ts = date_ts(month.month .. "-15")
        local name = ts and month_name(ts, true) or month.month
        add{ icon = icon("calendar"), stat = name, stat_label = T(_("%1 pages"), month.pages),
            description = T(any(MONTH_QUIPS), name) }
    end

    local band = M.rhythm(data.hours)
    if band then
        add{ icon = icon(band.icon), stat = band.label, stat_label = band.range, description = any(band.quips) }
    end

    add{ icon = icon("zen_ui"), stat = _("That's a wrap"), stat_label = year, description = any(FINALE_QUIPS) }
    return pages
end

function M.emptyPages(data)
    return { {
        icon = icon("zen_ui"), stat = tostring(data.year), stat_label = _("Reading Wrapped"),
        description = T(_("No reading data for %1 yet. Come back after a few good books."), data.year),
    } }
end

local function present(pages, on_close)
    local WrappedScreen = require("common/ui/wrapped_screen")
    require("ui/uimanager"):show(WrappedScreen:new{ pages = pages, on_close = on_close })
end

function M.load()
    local data = require("common/db_stats").queryWrapped()
    local finished
    if data.duration > 0 then
        local ok, counts = pcall(function() return require("common/db_library").getBookCounts() end)
        finished = ok and type(counts) == "table" and counts.finished_this_year or nil
    end
    return data, finished
end

function M.show(on_close)
    local data, finished = M.load()
    present(data.duration > 0 and M.buildPages(data, finished) or M.emptyPages(data), on_close)
    return true
end

-- Once after the release that added Wrapped (shown_for still false), then once per December.
function M.maybeAutoShow(plugin)
    local meta = plugin.config._meta
    local year = os.date("%Y")
    local shown = meta.wrapped_shown_for
    local intro = not shown
    if not intro and not (os.date("%m") == "12" and shown ~= year) then return false end
    local data, finished = M.load()
    if data.duration < M.MIN_DURATION then
        -- "" consumes the intro while leaving the December rule armed.
        meta.wrapped_shown_for = intro and "" or year
        plugin:saveConfig()
        return false
    end
    -- Persist before showing so a force-quit does not replay it.
    meta.wrapped_shown_for = year
    plugin:saveConfig()
    present(M.buildPages(data, finished))
    return true
end

return M
