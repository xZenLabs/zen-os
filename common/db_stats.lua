-- common/db_stats.lua
-- Queries KOReader's statistics.sqlite3 database.
-- Returns aggregated reading stats without touching library status,
-- which is handled by db_library.lua.

local logger = require("common/zen_logger").new("db_stats")
local DBConn = require("common/db_connection")

local StatsDB = {}

local FLUSH_MIN_INTERVAL_S = 10
local last_flush_at = 0
local STREAK_MAX_DAYS = 36600
local comic_md5_cache = {}

local function comic_hash(file, ok_docsettings, DocSettings, ok_util, util)
    local hash
    if ok_docsettings and DocSettings then
        local ok_hash, sidecar_hash = pcall(function()
            local sidecar = DocSettings:findSidecarFile(file)
            local settings = sidecar and DocSettings.openSettingsFile(sidecar)
            return settings and settings.data.partial_md5_checksum
        end)
        if ok_hash then hash = sidecar_hash end
    end
    if not hash and ok_util and util and type(util.partialMD5) == "function" then
        local ok_hash, computed = pcall(util.partialMD5, file)
        if ok_hash then hash = computed end
    end
    if type(hash) == "string" and #hash == 32 and hash:match("^%x+$") then
        return hash:lower()
    end
    return false
end

local function comic_filter_sql()
    -- ponytail: stats has no paths; persist a format index if cleared history must stay filterable.
    local ok_history, ReadHistory = pcall(require, "readhistory")
    local ok_docsettings, DocSettings = pcall(require, "docsettings")
    local ok_util, util = pcall(require, "util")
    if not ok_history or not ReadHistory then return "" end

    if type(ReadHistory.reload) == "function" then
        pcall(ReadHistory.reload, ReadHistory, false)
    end
    local hashes, live = {}, {}
    for _i, entry in ipairs(ReadHistory.hist or {}) do
        local file = entry and entry.file
        if type(file) == "string" and file:lower():match("%.cb[rz]$") then
            live[file] = true
            -- History time changes on every open; misses are cached too (false).
            local cached = comic_md5_cache[file]
            if not cached or cached.time ~= entry.time then
                cached = { time = entry.time,
                    hash = comic_hash(file, ok_docsettings, DocSettings, ok_util, util) }
                comic_md5_cache[file] = cached
            end
            if cached.hash then hashes[cached.hash] = true end
        end
    end
    for file in pairs(comic_md5_cache) do
        if not live[file] then comic_md5_cache[file] = nil end
    end

    local quoted = {}
    for hash in pairs(hashes) do quoted[#quoted + 1] = "'" .. hash .. "'" end
    if #quoted == 0 then return "" end
    table.sort(quoted)
    return " AND id_book NOT IN (SELECT id FROM book WHERE lower(md5) IN ("
        .. table.concat(quoted, ",") .. "))"
end

local function get_stats_plugin()
    local ok_loader, PluginLoader = pcall(require, "pluginloader")
    if not ok_loader or not PluginLoader or type(PluginLoader.getPluginInstance) ~= "function" then
        return nil
    end
    local stats_plugin = PluginLoader:getPluginInstance("statistics")
    if type(stats_plugin) ~= "table" then return nil end
    return stats_plugin
end

function StatsDB.dayShift(stats_plugin)
    stats_plugin = stats_plugin or get_stats_plugin()
    local settings = stats_plugin and stats_plugin.settings
        or G_reader_settings:readSetting("statistics") or {}
    if not settings.calendar_use_day_time_shift then return 0 end
    return (tonumber(settings.calendar_day_start_hour) or 0) * 3600
        + (tonumber(settings.calendar_day_start_minute) or 0) * 60
end

local function flush_pending_stats()
    local now_ts = os.time()
    if now_ts - last_flush_at < FLUSH_MIN_INTERVAL_S then return end
    last_flush_at = now_ts
    local stats_plugin = get_stats_plugin()
    if not stats_plugin or type(stats_plugin.insertDB) ~= "function" then return end
    if type(stats_plugin.isEnabled) == "function" and not stats_plugin:isEnabled() then return end
    pcall(stats_plugin.insertDB, stats_plugin)
end

function StatsDB.weekStart(now_t)
    now_t = now_t or os.date("*t")
    local settings = require("config/preset_store").getSettings("stats")
    local start_day = settings.week_start_day == 2 and 2 or 1
    return os.time({
        year = now_t.year, month = now_t.month,
        day = now_t.day - (now_t.wday - start_day) % 7,
        hour = 0, min = 0, sec = 0,
    }), start_day
end

local function period_starts(stats_plugin)
    local shift = StatsDB.dayShift(stats_plugin)
    local now_t = os.date("*t", os.time() - shift)
    local week_start, week_start_day = StatsDB.weekStart(now_t)
    local start_today = os.time({
        year = now_t.year, month = now_t.month, day = now_t.day,
        hour = 0, min = 0, sec = 0,
    })
    return {
        shift = shift,
        start_today = start_today + shift,
        period_begin = week_start + shift,
        week_start_day = week_start_day,
        start_month = os.time({
            year = now_t.year, month = now_t.month, day = 1,
            hour = 0, min = 0, sec = 0,
        }) + shift,
        start_year = os.time({
            year = now_t.year, month = 1, day = 1,
            hour = 0, min = 0, sec = 0,
        }) + shift,
    }
end

local PERIODS = {
    { name = "today", start = "start_today" },
    { name = "week", start = "period_begin" },
    { name = "month", start = "start_month" },
    { name = "year", start = "start_year" },
}

-- Nested periods share one scan of the rescaling page_stat view; per-period
-- page counts and durations match separate `start_time >= X` group-by queries.
local function query_period_stats(conn, starts, fields, book_filter, stats)
    local inner, outer, names, min_start = {}, {}, {}, nil
    for _i, period in ipairs(PERIODS) do
        local name = period.name
        if fields[name .. "_pages"] or fields[name .. "_duration"] then
            local start = starts[period.start]
            min_start = math.min(min_start or start, start)
            inner[#inner + 1] = string.format("max(start_time >= %d) AS n_%s, "
                .. "sum(CASE WHEN start_time >= %d THEN duration END) AS d_%s", start, name, start, name)
            outer[#outer + 1] = string.format("sum(n_%s), sum(d_%s)", name, name)
            names[#names + 1] = name
        end
    end
    if not min_start then return end
    local row = { conn:rowexec(string.format(
        "SELECT %s FROM (SELECT %s FROM page_stat WHERE start_time >= %d%s GROUP BY id_book, page);",
        table.concat(outer, ", "), table.concat(inner, ", "), min_start, book_filter or "")) }
    for i, name in ipairs(names) do
        if fields[name .. "_pages"] then stats[name .. "_pages"] = tonumber(row[i * 2 - 1]) or 0 end
        if fields[name .. "_duration"] then stats[name .. "_duration"] = tonumber(row[i * 2]) or 0 end
    end
end

-- Walks back one reading day at a time with indexed probes on page_stat_data(start_time).
-- (page_stat rescaling cannot zero a row with duration > 0, so the raw table suffices.)
local function query_streak(conn, starts)
    local t = os.date("*t", os.time() - starts.shift)
    local function day_start(offset)
        return os.time({
            year = t.year, month = t.month, day = t.day - offset,
            hour = 0, min = 0, sec = 0,
        }) + starts.shift
    end
    local function has_reading(from, to)
        local sql = "SELECT 1 FROM page_stat_data WHERE start_time >= " .. string.format("%d", from)
            .. (to and string.format(" AND start_time < %d", to) or "")
            .. " AND duration > 0 LIMIT 1;"
        return conn:rowexec(sql) ~= nil
    end
    local ok, streak = pcall(function()
        -- Future-dated rows (clock skew) make the latest day neither today nor yesterday.
        if has_reading(day_start(-1)) then return 0 end
        local offset = has_reading(day_start(0)) and 0
            or has_reading(day_start(1), day_start(0)) and 1
        if not offset then return 0 end
        local count = 0
        local upper = day_start(offset - 1)
        while count < STREAK_MAX_DAYS do
            local lower = day_start(offset + count)
            if not has_reading(lower, upper) then break end
            count = count + 1
            upper = lower
        end
        return count
    end)
    if not ok then
        logger.warn("streak query error:", streak)
        return 0
    end
    return streak
end

local function field_set(fields)
    local set = {}
    if type(fields) == "table" then
        for key, value in pairs(fields) do
            if type(key) == "string" and value == true then
                set[key] = true
            elseif type(value) == "string" then
                set[value] = true
            end
        end
    end
    if next(set) == nil then
        set.today_pages = true
        set.today_duration = true
        set.week_pages = true
        set.week_duration = true
        set.streak = true
    end
    return set
end

function StatsDB.queryBookAveragePageTime(path, md5)
    if type(md5) ~= "string" or md5 == "" then
        local ok_util, util = pcall(require, "util")
        if not ok_util or not util or type(util.partialMD5) ~= "function" then return nil end
        local ok_md5, computed_md5 = pcall(util.partialMD5, path)
        if not ok_md5 then return nil end
        md5 = computed_md5
    end
    if type(md5) ~= "string" or md5 == "" then return nil end

    flush_pending_stats()

    local db_path = DBConn.getStatsDbPath()
    local conn, err = DBConn.open(db_path)
    if not conn then
        logger.warn("cannot open DB:", err)
        return nil
    end

    local settings = G_reader_settings:readSetting("statistics")
    local max_sec = type(settings) == "table" and tonumber(settings.max_sec) or 120
    local stmt
    local ok, result = pcall(function()
        stmt = conn:prepare([[
            SELECT count(*), sum(page_duration), sum(read_duration), (
                SELECT pages FROM book
                WHERE md5 = ?
                ORDER BY last_open DESC
                LIMIT 1
            )
            FROM (
                SELECT min(sum(duration), ?) AS page_duration,
                       sum(duration) AS read_duration
                FROM page_stat
                WHERE id_book = (
                    SELECT id FROM book
                    WHERE md5 = ?
                    ORDER BY last_open DESC
                    LIMIT 1
                )
                GROUP BY page
            );
        ]])
        return stmt:reset():bind(md5, max_sec, md5):step()
    end)
    if stmt then stmt:close() end
    conn:close()

    if not ok then
        logger.warn("book timing query failed:", result)
        return nil
    end
    local pages = result and tonumber(result[1]) or 0
    local duration = result and tonumber(result[2]) or 0
    local read_time = result and tonumber(result[3]) or nil
    local total_pages = result and tonumber(result[4]) or nil
    if pages <= 0 or duration <= 0 then return nil, total_pages, read_time end
    return duration / pages, total_pages, read_time
end

function StatsDB.queryBookDetails(stats_plugin, fields)
    fields = type(fields) == "table" and fields or {}
    local needs_stats = fields.read_time == true or fields.time_remaining == true
        or fields.pages_today == true or fields.time_today == true
    if not needs_stats then return {} end
    if type(stats_plugin) ~= "table" or type(stats_plugin.insertDB) ~= "function"
            or not (stats_plugin.settings and stats_plugin.settings.is_enabled) then
        return nil
    end
    local book_id = tonumber(stats_plugin.id_curr_book)
    if not book_id or book_id < 1 or book_id >= math.huge
            or book_id ~= math.floor(book_id) then
        return nil
    end
    local ok_flush, flush_err = pcall(stats_plugin.insertDB, stats_plugin)
    if not ok_flush then
        logger.warn("book stats flush failed:", flush_err)
        return nil
    end

    local ctes, columns, keys = {}, {}, {}
    if fields.read_time == true then
        ctes[#ctes + 1] = string.format([[
            book_stats AS (
                SELECT sum(duration) AS read_time
                FROM page_stat
                WHERE id_book = %d
            )
        ]], book_id)
        columns[#columns + 1] = "COALESCE((SELECT read_time FROM book_stats), 0)"
        keys[#keys + 1] = "read_time"
    end
    if fields.pages_today == true or fields.time_today == true then
        local value_sql = fields.time_today == true
            and "sum(duration) AS duration" or "1 AS duration"
        ctes[#ctes + 1] = string.format([[
            today_stats AS (
                SELECT %s
                FROM page_stat
                WHERE start_time >= %d
                GROUP BY id_book, page
            )
        ]], value_sql, period_starts(stats_plugin).start_today)
        if fields.pages_today == true then
            columns[#columns + 1] = "(SELECT count(*) FROM today_stats)"
            keys[#keys + 1] = "pages_today"
        end
        if fields.time_today == true then
            columns[#columns + 1] = "COALESCE((SELECT sum(duration) FROM today_stats), 0)"
            keys[#keys + 1] = "time_today"
        end
    end
    if #columns == 0 then return {} end

    local conn, err = DBConn.open(DBConn.getStatsDbPath())
    if not conn then
        logger.warn("cannot open DB:", err)
        return nil
    end
    local values
    local ok_query, query_err = pcall(function()
        values = { conn:rowexec("WITH " .. table.concat(ctes, ",\n")
            .. "\nSELECT " .. table.concat(columns, ",\n") .. ";") }
    end)
    conn:close()
    if not ok_query then
        logger.warn("book details query failed:", query_err)
        return nil
    end

    local result = {}
    for i, key in ipairs(keys) do
        result[key] = tonumber(values[i]) or 0
    end
    return result
end

function StatsDB.queryHomeStats(fields, exclude_cbz_cbr)
    local stats = {
        today_pages = 0,
        today_duration = 0,
        week_pages = 0,
        week_duration = 0,
        month_pages = 0,
        month_duration = 0,
        year_pages = 0,
        year_duration = 0,
        streak = 0,
    }
    local requested = field_set(fields)

    flush_pending_stats()

    local db_path = DBConn.getStatsDbPath()
    local conn, err = DBConn.open(db_path)
    if not conn then
        logger.warn("cannot open DB:", err)
        return stats
    end

    local starts = period_starts()
    local book_filter = exclude_cbz_cbr == true and comic_filter_sql() or ""
    local ok, query_err = pcall(function()
        query_period_stats(conn, starts, requested, book_filter, stats)
        if requested.streak then
            stats.streak = query_streak(conn, starts)
        end
    end)
    if not ok then
        logger.warn("home query failed:", query_err)
    end

    conn:close()
    return stats
end

local SQL_PEAKS = [[
    WITH daily AS (
        SELECT strftime('%Y-%m-%d', start_time - DAY_SHIFT, 'unixepoch', 'localtime') AS day,
               SUM(duration) AS day_total,
               MIN(start_time - DAY_SHIFT) AS rep_ts
        FROM page_stat_data
        GROUP BY day
    )
    SELECT
        (SELECT day_total FROM daily ORDER BY day_total DESC LIMIT 1),
        (SELECT rep_ts FROM daily ORDER BY day_total DESC LIMIT 1),
        (SELECT week_total FROM (
            SELECT SUM(day_total) AS week_total, MIN(rep_ts) AS rep_ts
            FROM daily
            GROUP BY date(day, '-' || ((strftime('%w', day) - WEEK_START_DAY + 7) % 7) || ' days')
        ) ORDER BY week_total DESC LIMIT 1),
        (SELECT rep_ts FROM (
            SELECT SUM(day_total) AS week_total, MIN(rep_ts) AS rep_ts
            FROM daily
            GROUP BY date(day, '-' || ((strftime('%w', day) - WEEK_START_DAY + 7) % 7) || ' days')
        ) ORDER BY week_total DESC LIMIT 1),
        (SELECT month_total FROM (
            SELECT SUM(day_total) AS month_total, MIN(rep_ts) AS rep_ts
            FROM daily
            GROUP BY substr(day, 1, 7)
        ) ORDER BY month_total DESC LIMIT 1),
        (SELECT rep_ts FROM (
            SELECT SUM(day_total) AS month_total, MIN(rep_ts) AS rep_ts
            FROM daily
            GROUP BY substr(day, 1, 7)
        ) ORDER BY month_total DESC LIMIT 1);
]]

local ALL_PARTS = {
    today = true, week = true, month = true, year = true,
    streak = true, lifetime = true, peaks = true, books_year = true,
}

-- parts: set of today/week/month/year/streak/lifetime/peaks/books_year; nil = all.
function StatsDB.queryStats(parts)
    parts = type(parts) == "table" and parts or ALL_PARTS
    local stats = {
        today_pages         = 0,
        today_duration      = 0,
        week_pages          = 0,
        week_duration       = 0,
        month_pages         = 0,
        month_duration      = 0,
        year_pages          = 0,
        year_duration       = 0,
        streak              = 0,
        -- lifetime aggregates (from book table)
        lifetime_read_time  = 0,
        lifetime_pages      = 0,
        books_read          = 0,
        avg_time_per_book   = 0,
        -- personal records (peak durations + representative timestamps for date labels)
        peak_day_duration   = 0,
        peak_day_ts         = nil,
        peak_week_duration  = 0,
        peak_week_ts        = nil,
        peak_month_duration = 0,
        peak_month_ts       = nil,
        -- distinct books with any session this year
        books_this_year     = 0,
    }

    flush_pending_stats()

    local db_path = DBConn.getStatsDbPath()
    local conn, err = DBConn.open(db_path)
    if not conn then
        logger.warn("cannot open DB:", err)
        return stats
    end

    local ok, query_err = pcall(function()
        local starts = period_starts()

        local fields = {}
        for _i, period in ipairs(PERIODS) do
            if parts[period.name] then
                fields[period.name .. "_pages"] = true
                fields[period.name .. "_duration"] = true
            end
        end
        local ok_periods, period_err = pcall(query_period_stats, conn, starts, fields, "", stats)
        if not ok_periods then logger.warn("period query error:", period_err) end

        if parts.streak then stats.streak = query_streak(conn, starts) end

        if parts.lifetime then
            -- Total time, total pages, book count, average time over books with recorded time.
            local ok_lt, lt1, lt2, lt3, lt4 = pcall(conn.rowexec, conn, [[
                SELECT
                    COALESCE(SUM(total_read_time), 0),
                    COALESCE(SUM(total_read_pages), 0),
                    COUNT(*),
                    COALESCE(AVG(CASE WHEN total_read_time > 0
                                     THEN total_read_time END), 0)
                FROM book;
            ]])
            if ok_lt then
                stats.lifetime_read_time = tonumber(lt1) or 0
                stats.lifetime_pages     = tonumber(lt2) or 0
                stats.books_read         = tonumber(lt3) or 0
                stats.avg_time_per_book  = math.floor(tonumber(lt4) or 0)
            else
                logger.warn("lifetime query error:", lt1)
            end
        end

        if parts.peaks then
            -- One pass over page_stat_data (durations only, so no view): daily totals
            -- feed week/month peaks; ORDER BY + LIMIT 1 also yields a date-label timestamp.
            local ok_pk, pd_dur, pd_ts, pw_dur, pw_ts, pm_dur, pm_ts =
                pcall(conn.rowexec, conn, (SQL_PEAKS:gsub("WEEK_START_DAY", tostring(starts.week_start_day - 1))
                    :gsub("DAY_SHIFT", tostring(starts.shift))))
            if ok_pk then
                stats.peak_day_duration   = tonumber(pd_dur) or 0
                stats.peak_day_ts         = tonumber(pd_ts)
                stats.peak_week_duration  = tonumber(pw_dur) or 0
                stats.peak_week_ts        = tonumber(pw_ts)
                stats.peak_month_duration = tonumber(pm_dur) or 0
                stats.peak_month_ts       = tonumber(pm_ts)
            end
        end

        if parts.books_year then
            local ok_by, by_v = pcall(conn.rowexec, conn, string.format(
                "SELECT count(DISTINCT id_book) FROM page_stat_data WHERE start_time >= %d;",
                starts.start_year))
            stats.books_this_year = ok_by and (tonumber(by_v) or 0) or 0
        end

        logger.info("today=", stats.today_pages, "week=", stats.week_pages,
            "month=", stats.month_pages, "year=", stats.year_pages, "streak=", stats.streak)
    end)

    if not ok then
        logger.warn("query failed:", query_err)
    end

    conn:close()
    return stats
end

local function valid_series_days(days)
    days = tonumber(days) or 14
    if days == 7 or days == 14 or days == 30 or days == 90 then
        return days
    end
    return 14
end

function StatsDB.queryDailySeries(days)
    days = valid_series_days(days)
    local shift = StatsDB.dayShift()
    local today_t = os.date("*t", os.time() - shift)
    local start_time
    local series = {}
    local by_date = {}

    for offset = days - 1, 0, -1 do
        local day_ts = os.time({
            year = today_t.year, month = today_t.month, day = today_t.day - offset,
            hour = 0, min = 0, sec = 0,
        })
        start_time = start_time or day_ts + shift
        local date = os.date("%Y-%m-%d", day_ts)
        local row = { date = date, pages = 0, duration = 0, books = 0 }
        series[#series + 1] = row
        by_date[date] = row
    end

    flush_pending_stats()

    local db_path = DBConn.getStatsDbPath()
    local conn, err = DBConn.open(db_path)
    if not conn then
        logger.warn("cannot open DB:", err)
        return series
    end

    local ok, query_err = pcall(function()
        local sql = [[
            SELECT dates, count(*) AS pages, sum(sum_duration) AS durations,
                   count(DISTINCT id_book) AS books
            FROM (
                SELECT id_book, page,
                       strftime('%%Y-%%m-%%d', start_time - %d, 'unixepoch', 'localtime') AS dates,
                       sum(duration) AS sum_duration
                FROM page_stat
                WHERE start_time >= %d
                GROUP BY id_book, page, dates
            )
            GROUP BY dates
            ORDER BY dates;
        ]]
        local result = conn:exec(string.format(sql, shift, start_time))
        if not (result and result.dates) then return end
        for i = 1, #result.dates do
            local row = by_date[result.dates[i]]
            if row then
                row.pages = tonumber(result.pages and result.pages[i] or result[2] and result[2][i]) or 0
                row.duration = tonumber(result.durations and result.durations[i] or result[3] and result[3][i]) or 0
                row.books = tonumber(result.books and result.books[i] or result[4] and result[4][i]) or 0
            end
        end
    end)
    if not ok then
        logger.warn("daily series query failed:", query_err)
    end

    conn:close()
    return series
end

function StatsDB.queryBooksForPeriod(period_begin, period_end)
    period_begin = tonumber(period_begin) or 0
    period_end = tonumber(period_end) or period_begin

    flush_pending_stats()

    local db_path = DBConn.getStatsDbPath()
    local conn, err = DBConn.open(db_path)
    if not conn then
        logger.warn("cannot open DB:", err)
        return {}
    end

    local books = {}
    local ok, query_err = pcall(function()
        local sql = [[
            SELECT book_tbl.title AS title,
                   count(DISTINCT page_stat_tbl.page) AS pages,
                   sum(page_stat_tbl.duration) AS duration,
                   book_tbl.id AS book_id
            FROM page_stat AS page_stat_tbl, book AS book_tbl
            WHERE page_stat_tbl.id_book = book_tbl.id
              AND page_stat_tbl.start_time >= %d AND page_stat_tbl.start_time < %d
            GROUP BY book_tbl.id
            ORDER BY duration DESC, title;
        ]]
        local result = conn:exec(string.format(sql, period_begin, period_end))
        if not (result and result.title) then return end
        for i = 1, #result.title do
            books[#books + 1] = {
                title = tostring(result.title[i] or ""),
                pages = tonumber(result.pages and result.pages[i] or result[2] and result[2][i]) or 0,
                duration = tonumber(result.duration and result.duration[i] or result[3] and result[3][i]) or 0,
                book_id = tonumber(result.book_id and result.book_id[i] or result[4] and result[4][i]) or nil,
            }
        end
    end)
    if not ok then
        logger.warn("books for period query failed:", query_err)
    end

    conn:close()
    return books
end

return StatsDB
