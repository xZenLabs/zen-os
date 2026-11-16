-- Statistics computation. No UI and no KOReader dependencies except through
-- the two adapters handed in by the caller:
--   fetch(sql)  -> array of rows (each an array of column values)
--   books_meta  -> array of sidecar records (see books.lua)
-- This keeps the maths testable outside of KOReader.

local Data = {}

local DAY = 86400
local SESSION_GAP = 3600       -- pause longer than this starts a new session
local MIN_BOOK_SECONDS = 600   -- less than this: a book has no real statistics
local READING_DAYS = 14        -- "currently reading" = status reading + read within this many days
local MIN_READ_DAY_SEC = 300   -- "reading days per book": at least 5 minutes that day
local MIN_DAY_BOOK_SEC = 600   -- calendar: only books read at least 10 min that day
local CAL_BOOKS = 6            -- calendar: numbered books per month, the rest is "+"
local RECENT_DAYS = 14         -- "recently finished": a third book only if finished within this many days
local LIST_SLOTS = 5           -- rows shared by "currently reading" and "recently finished"
Data.OTHERS = 99

local function ymKey(y, m) return string.format("%04d-%02d", y, m) end

local function dayKey(ts) return os.date("%Y-%m-%d", ts) end

local function noon(y, m, d) return os.time({ year = y, month = m, day = d, hour = 12 }) end

local function num(v) return tonumber(v) or 0 end

local function normTitle(s)
    return (tostring(s or ""):lower():gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Short name of an omnibus for subtitles ("Sammelband VI").
local function omniName(title)
    title = tostring(title or "")
    return title:match("([Ss]ammelband.*)$") or title
end

local function shortsLabel()
    local ok, gettext = pcall(require, "gettext")
    return ok and gettext("Short stories") or "Short stories"
end

local function daysInMonth(y, m)
    return tonumber(os.date("%d", os.time({ year = y, month = m + 1, day = 0, hour = 12 })))
end
Data.daysInMonth = daysInMonth

--- Previous (y, m) pair, n months back.
function Data.monthsBack(y, m, n)
    local idx = y * 12 + (m - 1) - n
    return math.floor(idx / 12), idx % 12 + 1
end

function Data.compute(fetch, meta, now, legacy)
    now = now or os.time()
    local T = os.date("*t", now)
    local S = {
        now = now, year = T.year, month = T.month, day = T.day,
        ym = ymKey(T.year, T.month),
        months = {}, days = {}, finished_by_month = {},
        books = {}, by_id = {},
    }

    -- ---- books table ----------------------------------------------------
    for _i, r in ipairs(fetch("select id, title, authors, pages, md5 from book")) do
        local b = {
            id = r[1], title = r[2] or "", authors = (r[3] or ""):gsub("\n", ", "),
            pages = num(r[4]), md5 = r[5], dur = 0, dpages = 0,
        }
        S.books[#S.books + 1] = b
        S.by_id[b.id] = b
    end

    -- ---- sidecar records -> DB books -------------------------------------
    local by_md5, by_title = {}, {}
    for _i, b in ipairs(S.books) do
        if b.md5 and b.md5 ~= "" then by_md5[b.md5] = b end
        by_title[normTitle(b.title) .. "\31" .. normTitle(b.authors)] = b
    end
    local unique, seen_md5 = {}, {}
    for _i, m in ipairs(meta or {}) do
        if not (m.md5 and seen_md5[m.md5]) then
            if m.md5 then seen_md5[m.md5] = true end
            unique[#unique + 1] = m
        end
    end
    meta = unique
    S.meta_count = #meta
    for _i, m in ipairs(meta) do
        local b = (m.md5 and by_md5[m.md5])
            or by_title[normTitle(m.title) .. "\31" .. normTitle(m.authors)]
        m.book = b
        if b then b.meta = m end
    end
    -- standard pages per book (KOReader synthetic pages, e.g. 1800 characters):
    -- from the sidecar, else estimated from the EPUB text size
    for _i, b in ipairs(S.books) do
        local m = b.meta
        b.std = m and (m.std_pages or m.est_std) or nil
    end

    -- ---- omnibus volumes: every work counts as a book of its own ---------
    -- The sidecar record is replaced by one record per work; its reading rows
    -- are assigned by their position in the book (see the rows below).
    local omni_by_id = {}
    do
        local expanded = {}
        for _i, m in ipairs(meta) do
            local parts = m.omni
            if type(parts) == "table" and #parts >= 2 then
                local b = m.book
                local n = #parts
                local otitle = (m.title ~= "" and m.title) or (b and b.title ~= "" and b.title)
                    or tostring(m.file or ""):match("([^/]+)%.%w+$") or "?"
                local name = omniName(otitle)
                local pos = m.percent or 0
                local group = { title = otitle, name = name, n = n, file = m.file, metas = {} }
                local info = { parts = {}, ranges = {} }
                for k, part in ipairs(parts) do
                    local share = part.share or 0
                    local pm = {}
                    for key, v in pairs(m) do pm[key] = v end
                    pm.omni, pm.book = nil, nil
                    pm.title = part.kind == "shorts" and (shortsLabel() .. " · " .. name) or part.title
                    pm.list_title = part.kind == "shorts" and shortsLabel() or nil   -- the subtitle names the omnibus
                    pm.omni_k, pm.omni_n, pm.omni_name, pm.omni_group = k, n, name, group
                    pm.share = share
                    pm.ranges = part.ranges
                    local function sc(v) return v and math.max(1, math.floor(v * share + 0.5)) or nil end
                    pm.pages, pm.std_pages, pm.est_std, pm.est_pages = sc(m.pages), sc(m.std_pages), sc(m.est_std), sc(m.est_pages)
                    local len, done = 0, 0
                    for _j, r in ipairs(part.ranges) do
                        len = len + (r[2] - r[1])
                        done = done + math.max(0, math.min(pos, r[2]) - r[1])
                    end
                    local first, last = part.ranges[1][1], part.ranges[#part.ranges][2]
                    if m.status == "complete" or pos >= last - 0.002 then
                        pm.status, pm.percent = "complete", 1
                    elseif pos >= first then
                        pm.status, pm.percent = m.status, len > 0 and done / len or 0
                    else
                        pm.status, pm.percent = nil, 0
                    end
                    group.metas[k] = pm
                    if b then
                        local pb = { id = tostring(b.id) .. "#" .. k, title = pm.title, authors = b.authors,
                            pages = sc(b.pages) or 0, dur = 0, dpages = 0, meta = pm, part_of = b.id }
                        pb.std = pm.std_pages or pm.est_std
                        S.books[#S.books + 1] = pb
                        S.by_id[pb.id] = pb
                        pm.book = pb
                        info.parts[k] = pb
                        for _j, r in ipairs(part.ranges) do info.ranges[#info.ranges + 1] = { r[1], r[2], k } end
                    end
                    expanded[#expanded + 1] = pm
                end
                if b then
                    table.sort(info.ranges, function(x, y) return x[1] < y[1] end)
                    omni_by_id[b.id] = info
                    b.meta = nil
                end
            else
                expanded[#expanded + 1] = m
            end
        end
        meta = expanded
    end
    --- Book id a reading row belongs to: the work of an omnibus by position.
    local function rowBook(id, page, total)
        local info = omni_by_id[id]
        if not info then return id end
        local f = (total and total > 0) and (num(page) - 0.5) / total or 0
        local k = info.ranges[1][3]
        for _i, r in ipairs(info.ranges) do
            if f >= r[1] then k = r[3] else break end
        end
        return info.parts[k].id
    end

    -- ---- reading rows ---------------------------------------------------
    local rows = fetch("select id_book, start_time, duration, page, total_pages from page_stat_data order by start_time")
    local first_ts, total_sec = nil, 0
    local sessions, sess_sum, sess_cnt = 0, 0, 0
    local last_end, cur_len = nil, 0
    local function closeSession()
        if last_end then sess_sum = sess_sum + cur_len; sess_cnt = sess_cnt + 1 end
    end
    for _i, r in ipairs(rows) do
        local id, s, d = r[1], num(r[2]), num(r[3])
        if d > 0 then
            id = rowBook(id, r[4], num(r[5]))
            local b = S.by_id[id]
            if b then
                b.dur = b.dur + d
                b.first = b.first and math.min(b.first, s) or s
                b.last = b.last and math.max(b.last, s) or s
            end
            first_ts = first_ts or s
            total_sec = total_sec + d
            local dk = dayKey(s)
            local day = S.days[dk]
            if not day then day = { sec = 0, books = {} }; S.days[dk] = day end
            day.sec = day.sec + d
            day.books[id] = (day.books[id] or 0) + d
            local mk = dk:sub(1, 7)
            local mo = S.months[mk]
            if not mo then mo = { sec = 0, pages = 0, sessions = 0, days = 0 }; S.months[mk] = mo end
            mo.sec = mo.sec + d
            if last_end == nil or s - last_end > SESSION_GAP then
                closeSession()
                cur_len = 0
                mo.sessions = mo.sessions + 1
                sessions = sessions + 1
            end
            cur_len = cur_len + d
            last_end = s + d
        end
    end
    closeSession()

    -- ---- books read before the statistics (zen_stats_legacy.lua) ----------
    -- Estimated time and pages, spread evenly over the reading days.
    S.legacy_books = 0
    local by_file = {}
    for _i, m in ipairs(meta) do
        if m.file then
            by_file[m.file] = by_file[m.file] or {}
            table.insert(by_file[m.file], m)
        end
    end
    -- an omnibus gets its legacy time and pages split by the size of its works,
    -- one after the other in the reading period
    local legacy_items = {}
    for i, e in ipairs(type(legacy) == "table" and type(legacy.books) == "table" and legacy.books or {}) do
        local list = by_file[e.path] or {}
        local y1, m1, d1 = tostring(e.start or ""):match("^(%d+)-(%d+)-(%d+)$")
        local y2, m2, d2 = tostring(e.finish or ""):match("^(%d+)-(%d+)-(%d+)$")
        if y1 and y2 and #list > 0 then
            local t1, t2 = noon(tonumber(y1), tonumber(m1), tonumber(d1)), noon(tonumber(y2), tonumber(m2), tonumber(d2))
            local acc = 0
            for j, m in ipairs(list) do
                local share = #list > 1 and (m.share or 1 / #list) or 1
                local a = t1 + math.floor((t2 - t1) * acc / DAY + 0.5) * DAY
                acc = acc + share
                local z = t1 + math.floor((t2 - t1) * acc / DAY + 0.5) * DAY
                legacy_items[#legacy_items + 1] = { m = m, t1 = a, t2 = math.max(a, z),
                    sec = num(e.sec) * share, pages = num(e.pages) * share, id = "L" .. i .. (#list > 1 and ("#" .. j) or "") }
            end
        end
    end
    for _i, it in ipairs(legacy_items) do
        local m = it.m
        local real = m and m.book and m.book.dur >= MIN_BOOK_SECONDS
        if m and m.status == "complete" and not real then
            local t1, t2 = it.t1, it.t2
            local ndays = math.max(1, math.floor((t2 - t1) / DAY + 1.5))
            local sec, pages = it.sec, it.pages
            local id = it.id
            local title = (m.title ~= "" and m.title) or tostring(m.file or ""):match("([^/]+)%.%w+$") or "?"
            local lb = { id = id, title = title, authors = m.authors or "", pages = pages, dur = sec,
                dpages = pages, std = pages, first = t1, last = t2, legacy = true, meta = m }
            S.by_id[id] = lb
            m.legacy_book = lb
            S.legacy_books = S.legacy_books + 1
            for k = 0, ndays - 1 do
                local dk = dayKey(t1 + k * DAY)
                local day = S.days[dk]
                if not day then day = { sec = 0, books = {} }; S.days[dk] = day end
                day.sec = day.sec + sec / ndays
                day.books[id] = (day.books[id] or 0) + sec / ndays
                day.legacy_pages = (day.legacy_pages or 0) + pages / ndays
                local mk = dk:sub(1, 7)
                local mo = S.months[mk]
                if not mo then mo = { sec = 0, pages = 0, sessions = 0, days = 0 }; S.months[mk] = mo end
                mo.sec = mo.sec + sec / ndays
                mo.pages = mo.pages + pages / ndays
            end
            total_sec = total_sec + sec
            first_ts = first_ts and math.min(first_ts, t1) or t1
        end
    end
    S.total_sec = total_sec
    S.session_count = sessions
    S.avg_session_sec = sess_cnt > 0 and sess_sum / sess_cnt or 0
    for dk in pairs(S.days) do
        local mo = S.months[dk:sub(1, 7)]
        mo.days = mo.days + 1
    end
    S.first_ym = nil
    for mk in pairs(S.months) do
        if not S.first_ym or mk < S.first_ym then S.first_ym = mk end
    end

    -- ---- pages, in standard pages ----------------------------------------
    -- page_stat_data keeps the screen page and the screen page count of each
    -- reading row; screen pages depend on font and margins. Each group is
    -- converted with the book's standard page count. Books without one use
    -- the median ratio of the other books.
    local ratios = {}
    local groups = fetch("select id_book, total_pages, strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime'), "
        .. "count(distinct page) from page_stat_data where duration > 0 group by 1, 2, 3")
    for _i, r in ipairs(groups) do
        local b = S.by_id[r[1]]
        local tp = num(r[2])
        if b and b.std and tp > 0 then ratios[#ratios + 1] = b.std / tp end
    end
    table.sort(ratios)
    local fallback = #ratios > 0 and ratios[math.floor((#ratios + 1) / 2)] or 1
    S.total_pages = 0
    -- omnibus volumes: the pages of each work, by position
    for id, info in pairs(omni_by_id) do
        local whole = S.by_id[id]
        local pg = fetch("select total_pages, strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime'), page "
            .. "from page_stat_data where duration > 0 and id_book = " .. tonumber(id) .. " group by 1, 2, 3")
        for _i, r in ipairs(pg) do
            local tp = num(r[1])
            local factor = (whole and whole.std and tp > 0) and whole.std / tp or fallback
            local pb = S.by_id[rowBook(id, r[3], tp)]
            if pb then pb.dpages = pb.dpages + factor end
            S.total_pages = S.total_pages + factor
            local day = S.days[r[2]]
            if day then day.pages = (day.pages or 0) + factor end
            local mo = S.months[tostring(r[2]):sub(1, 7)]
            if mo then mo.pages = mo.pages + factor end
        end
    end
    for _i, r in ipairs(groups) do
        local b = S.by_id[r[1]]
        local tp = num(r[2])
        local factor = (b and b.std and tp > 0) and b.std / tp or fallback
        local n = omni_by_id[r[1]] and 0 or num(r[4]) * factor
        if b then b.dpages = b.dpages + n end
        S.total_pages = S.total_pages + n
        local day = S.days[r[3]]
        if day then day.pages = (day.pages or 0) + n end
        local mo = S.months[tostring(r[3]):sub(1, 7)]
        if mo then mo.pages = mo.pages + n end
    end
    for _dk, day in pairs(S.days) do
        if day.legacy_pages then
            day.pages = (day.pages or 0) + day.legacy_pages
            S.total_pages = S.total_pages + day.legacy_pages
        end
    end

    -- ---- reading days per book (at least five minutes that day) -------
    for _dk, day in pairs(S.days) do
        for id, sec in pairs(day.books) do
            local b = S.by_id[id]
            if b and not b.legacy and sec >= MIN_READ_DAY_SEC then b.read_days = (b.read_days or 0) + 1 end
        end
    end

    -- ---- finished books, legacy books -----------------------------------
    S.finished_total, S.legacy_count, S.legacy_pages, S.legacy_missing = 0, 0, 0, 0
    S.legacy_estimated = 0
    local fin_n, fin_days, fin_time = 0, 0, 0
    local finished = {}   -- finished books with real statistics
    for _i, m in ipairs(meta) do
        if m.status == "complete" then
            S.finished_total = S.finished_total + 1
            local b = m.book
            if m.legacy_book then
                local fd = os.date("*t", m.legacy_book.last)
                local k = ymKey(fd.year, fd.month)
                S.finished_by_month[k] = (S.finished_by_month[k] or 0) + 1
            elseif b and b.dur >= MIN_BOOK_SECONDS then
                local fd = os.date("*t", b.last)
                local k = ymKey(fd.year, fd.month)
                S.finished_by_month[k] = (S.finished_by_month[k] or 0) + 1
                fin_n = fin_n + 1
                -- reading days, not calendar days: several books are often read
                -- side by side, and pauses would stretch the span
                fin_days = fin_days + math.max(1, b.read_days or 0)
                fin_time = fin_time + b.dur
                finished[#finished + 1] = m
            else
                S.legacy_count = S.legacy_count + 1
                if m.pages and m.pages > 0 then
                    S.legacy_pages = S.legacy_pages + m.pages
                elseif m.est_pages and m.est_pages > 0 then
                    S.legacy_pages = S.legacy_pages + m.est_pages
                    S.legacy_estimated = S.legacy_estimated + 1
                else
                    S.legacy_missing = S.legacy_missing + 1
                end
            end
        end
    end
    S.fin_this_month = S.finished_by_month[S.ym] or 0
    S.fin_this_year = 0
    for k, n in pairs(S.finished_by_month) do
        if k:sub(1, 4) == string.format("%04d", S.year) then S.fin_this_year = S.fin_this_year + n end
    end
    S.fin_avg_days = fin_n > 0 and math.floor(fin_days / fin_n + 0.5) or nil
    S.fin_avg_sec = fin_n > 0 and fin_time / fin_n or nil
    S.fin_with_stats = fin_n

    -- ---- currently reading ----------------------------------------------
    local reading = {}
    for _i, m in ipairs(meta) do
        local b = m.book
        if m.status == "reading" and b and b.dur >= MIN_BOOK_SECONDS and b.last
                and (now - b.last) <= READING_DAYS * DAY then
            local total = m.std_pages or m.est_std or ((m.pages and m.pages > 0) and m.pages) or b.pages
            local pct = m.percent
            if not pct and total > 0 then pct = b.dpages / total end
            pct = math.max(0, math.min(1, pct or 0))
            reading[#reading + 1] = {
                id = b.id, title = m.list_title or b.title, author = (b.authors:match("^[^,]+") or ""),
                pct = pct, total = total, cur = math.floor(pct * total + 0.5),
                first = b.first, last = b.last, meta = m, file = m.file,
                omni_k = m.omni_k, omni_n = m.omni_n, omni_name = m.omni_name,
            }
        end
    end
    table.sort(reading, function(a, c) return a.last > c.last end)
    while #reading > 3 do table.remove(reading) end
    S.reading = reading
    S.reading_count = #reading

    -- ---- recently finished -----------------------------------------------
    -- One row per omnibus: the last finished work, or the whole volume once
    -- all of its works are finished.
    local recent, seen_group = {}, {}
    local function pagesOf(m, b)
        return m.std_pages or m.est_std or ((m.pages and m.pages > 0) and m.pages) or b.pages or 0
    end
    table.sort(finished, function(a, c) return a.book.last > c.book.last end)
    for _i, m in ipairs(finished) do
        local b = m.book
        local g = m.omni_group
        if g then
            if not seen_group[g] then
                seen_group[g] = true
                local all = true
                for _k, pm in ipairs(g.metas) do if pm.status ~= "complete" then all = false end end
                if all then
                    local pages, dur, last = 0, 0, 0
                    for _k, pm in ipairs(g.metas) do
                        local pb = pm.book
                        pages = pages + (pb and pagesOf(pm, pb) or pm.est_pages or pm.pages or 0)
                        if pb then dur = dur + pb.dur; last = math.max(last, pb.last or 0) end
                    end
                    recent[#recent + 1] = { id = b.part_of or b.id, title = g.title, author = (b.authors:match("^[^,]+") or ""),
                        last = last, dur = dur, pages = pages, file = g.file, omni_all = g.n }
                else
                    recent[#recent + 1] = { id = b.id, title = m.list_title or b.title, author = (b.authors:match("^[^,]+") or ""),
                        last = b.last, dur = b.dur, pages = pagesOf(m, b), file = m.file,
                        omni_k = m.omni_k, omni_n = m.omni_n, omni_name = m.omni_name }
                end
            end
        else
            recent[#recent + 1] = { id = b.id, title = b.title, author = (b.authors:match("^[^,]+") or ""),
                last = b.last, dur = b.dur, pages = pagesOf(m, b), file = m.file }
        end
    end
    table.sort(recent, function(a, c) return a.last > c.last end)
    local slots = math.max(2, math.min(3, LIST_SLOTS - #reading))
    S.recent = {}
    for i, r in ipairs(recent) do
        if i > slots then break end
        if i <= 2 or (now - r.last) <= RECENT_DAYS * DAY then S.recent[#S.recent + 1] = r end
    end

    -- ---- weekday averages, last 3 months (92 days) -----------------------
    local wd_sum, wd_n = {}, {}
    for i = 1, 7 do wd_sum[i], wd_n[i] = 0, 0 end
    for back = 0, 92 do
        local t = noon(S.year, S.month, S.day) - back * DAY
        local d = os.date("*t", t)
        local idx = (d.wday + 5) % 7 + 1
        local day = S.days[os.date("%Y-%m-%d", t)]
        wd_sum[idx] = wd_sum[idx] + (day and day.sec / 60 or 0)
        wd_n[idx] = wd_n[idx] + 1
    end
    S.weekday = {}
    for i = 1, 7 do S.weekday[i] = wd_n[i] > 0 and wd_sum[i] / wd_n[i] or 0 end

    -- ---- derived figures for page 1 -------------------------------------
    local cur = S.months[S.ym] or { sec = 0, pages = 0, sessions = 0, days = 0 }
    S.cur_month = cur
    S.daily_pages = cur.pages / math.max(1, S.day)
    S.daily_sec = cur.sec / math.max(1, S.day)
    local full_sec, full_pages, full_n = 0, 0, 0
    for k, mo in pairs(S.months) do
        if k < S.ym then full_sec = full_sec + mo.sec; full_pages = full_pages + mo.pages; full_n = full_n + 1 end
    end
    S.full_months = full_n
    local today = S.days[dayKey(now)]
    S.today_pages = today and today.pages or 0
    S.today_sec = today and today.sec or 0
    S.monthly_pages = full_n > 0 and full_pages / full_n or nil
    S.monthly_sec = full_n > 0 and full_sec / full_n or nil
    S.pages_all = S.total_pages + S.legacy_pages
    S.speed_all = S.total_pages > 0 and total_sec / 60 / S.total_pages or nil
    function S.speed(k)
        local mo = S.months[k]
        if mo and mo.pages > 0 and mo.sec > 0 then return mo.sec / 60 / mo.pages end
    end
    local py, pm = Data.monthsBack(S.year, S.month, 1)
    local ppy, ppm = Data.monthsBack(S.year, S.month, 2)
    local pmo = S.months[ymKey(py, pm)]
    S.prev = { y = py, m = pm, speed = S.speed(ymKey(py, pm)),
        pages = pmo and pmo.pages or 0, sec = pmo and pmo.sec or 0 }
    S.prev2 = { y = ppy, m = ppm, speed = S.speed(ymKey(ppy, ppm)) }
    S.cur_speed = S.speed(S.ym)

    -- forecast for the most recently read book
    local top = reading[1]
    if top then
        local sp = S.cur_speed or S.prev.speed or S.speed_all
        if sp and top.total > 0 then
            local rem_pages = math.max(0, top.total - top.cur)
            S.forecast = { title = top.title, sec = rem_pages * sp * 60 }
            local per_day = S.daily_sec
            S.forecast.days = per_day > 0 and math.max(1, math.floor(S.forecast.sec / per_day + 0.5)) or nil
        end
    end
    return S
end

--- Calendar model for one month.
--- monday_first: weeks start on Monday (else Sunday), as in the Stats settings.
function Data.calendar(S, y, m, monday_first)
    local n = daysInMonth(y, m)
    local first_wd = tonumber(os.date("%w", noon(y, m, 1)))   -- Sunday = 0
    if monday_first then first_wd = (first_wd + 6) % 7 end
    local per_book = {}
    local last_seen = {}
    for d = 1, n do
        local day = S.days[string.format("%04d-%02d-%02d", y, m, d)]
        if day then
            for id, sec in pairs(day.books) do
                if sec >= MIN_DAY_BOOK_SEC then
                    per_book[id] = (per_book[id] or 0) + sec
                    last_seen[id] = d
                end
            end
        end
    end
    local order = {}
    for id in pairs(per_book) do order[#order + 1] = id end
    table.sort(order, function(a, b)
        if per_book[a] ~= per_book[b] then return per_book[a] > per_book[b] end
        if last_seen[a] ~= last_seen[b] then return last_seen[a] > last_seen[b] end
        return tostring(a) < tostring(b)
    end)
    local number = {}
    local legend = {}
    for i = 1, math.min(CAL_BOOKS, #order) do
        number[order[i]] = i
        legend[#legend + 1] = { n = i, title = S.by_id[order[i]] and S.by_id[order[i]].title or "?" }
    end
    local cells = {}
    local today_ym = ymKey(S.year, S.month) == ymKey(y, m)
    local month_sec, days_read = 0, 0
    for d = 1, n do
        local key = string.format("%04d-%02d-%02d", y, m, d)
        local day = S.days[key]
        local c = { d = d, sec = day and day.sec or 0, marks = {} }
        c.future = today_ym and d > S.day or (ymKey(y, m) > ymKey(S.year, S.month))
        c.today = today_ym and d == S.day
        if day then
            month_sec = month_sec + day.sec
            if day.sec >= 60 then days_read = days_read + 1 end
            local set = {}
            for id, sec in pairs(day.books) do
                if sec >= MIN_DAY_BOOK_SEC then set[#set + 1] = number[id] or Data.OTHERS end
            end
            table.sort(set)
            local seen = {}
            for _i, v in ipairs(set) do
                if not seen[v] then seen[v] = true; c.marks[#c.marks + 1] = v end
            end
        end
        local mins = c.sec / 60
        c.shade = (c.sec < 60 and 0) or (mins < 30 and 1) or (mins < 60 and 2) or (mins < 100 and 3) or 4
        cells[d] = c
    end
    local others = false
    for _i, id in ipairs(order) do if not number[id] then others = true end end
    local mo = S.months[ymKey(y, m)]
    return {
        y = y, m = m, days = n, lead = first_wd, cells = cells, legend = legend, others = others,
        sec = month_sec, days_read = days_read,
        days_total = today_ym and S.day or n,
        sessions = mo and mo.sessions or 0,
    }
end

return Data
