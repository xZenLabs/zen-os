-- Reads book information for the statistics. Which books are finished or
-- being read comes from the ZenOS status index (common/tbr_index, kept in the
-- DocPropsCache database); only those books' sidecars are opened, for page
-- counts and the md5 that links them to the statistics database. Parsed
-- sidecars are cached per path + mtime + size.

local logger = require("common/zen_logger").new("stats_books")

local M = {}

local cache = {}   -- key -> record (without file)
local order = {}
local CACHE_MAX = 2048

local function remember(key, rec)
    cache[key] = rec
    order[#order + 1] = key
    if #order > CACHE_MAX then
        local old = table.remove(order, 1)
        cache[old] = nil
    end
end

local function num(v)
    v = tonumber(v)
    return v and v > 0 and v or nil
end

--- Stable page count of a book: the user's configured page length first
--- (same priority as ZenOS utils.getStablePageCount).
local function stable_pages(data)
    if data.pagemap_use_page_labels == true then
        local p = num(data.pagemap_doc_pages) or num(data.pagemap_last_page_label)
        if p then return p, true end
    end
    local p = num(data.doc_pages)
    if p then return p end
    if type(data.stats) == "table" then p = num(data.stats.pages) end
    return p
end

local function record_from(data)
    local summary = type(data.summary) == "table" and data.summary or {}
    local props = type(data.doc_props) == "table" and data.doc_props or {}
    local authors = props.authors
    if type(authors) == "string" then authors = authors:gsub("\n", ", ") end
    local pages, printed = stable_pages(data)
    return {
        -- standard pages (KOReader synthetic page length, e.g. 1800 characters)
        std_pages = num(data.pagemap_doc_pages),
        status = summary.status,
        printed = printed or nil,   -- pages are publisher (printed) page labels
        title = props.title or "",
        authors = authors or "",
        md5 = data.partial_md5_checksum,
        percent = tonumber(data.percent_finished),
        pages = pages,
    }
end

--- Returns an array of records {file,status,title,authors,md5,percent,pages}.
function M.scan()
    local out = {}
    local ok, err = pcall(function()
        local DocSettings = require("docsettings")
        local lfs = require("libs/libkoreader-lfs")

        -- finished and started books in the home folders, from the status index
        local files, seen = {}, {}
        local function add(file)
            if file and not seen[file] then seen[file] = true; files[#files + 1] = file end
        end
        local ok_i, TBRIndex = pcall(require, "common/tbr_index")
        if ok_i and type(TBRIndex.getByStatuses) == "function" then
            local ok_s, list = pcall(TBRIndex.getByStatuses, { complete = true, reading = true })
            if ok_s and type(list) == "table" then
                for _i, file in ipairs(list) do add(file) end
            else
                logger.warn("status index failed:", list)
            end
        end
        -- books opened from outside the home folders are only in the history
        local ok_p, paths = pcall(require, "common/paths")
        local ok_rh, ReadHistory = pcall(require, "readhistory")
        if ok_rh and ReadHistory then
            for _i, entry in ipairs(ReadHistory.hist or {}) do
                local file = entry.file
                if file and not (ok_p and paths.isInHomeDir and paths.isInHomeDir(file)) then add(file) end
            end
        end

        for _i, file in ipairs(files) do
            local sidecar = DocSettings:findSidecarFile(file)
            if sidecar then
                local attrs = lfs.attributes(sidecar)
                local mtime, size = attrs and attrs.modification, attrs and attrs.size
                if mtime and size and size > 0 then
                    local key = sidecar .. "\31" .. tostring(mtime) .. "\31" .. tostring(size)
                    local rec = cache[key]
                    if rec == nil then
                        local ok_o, ds = pcall(DocSettings.openSettingsFile, sidecar)
                        rec = ok_o and ds and ds.data and record_from(ds.data) or false
                        remember(key, rec)
                    end
                    if rec then
                        local copy = {}
                        for k, v in pairs(rec) do copy[k] = v end
                        copy.file = file
                        out[#out + 1] = copy
                    end
                end
            end
        end
    end)
    if not ok then
        logger.warn("sidecar scan failed:", err)
    end
    return out
end

-- ---- page estimate for books that were never opened --------------------
-- Books only marked as finished have no page count in their sidecar. Their
-- size is estimated from the uncompressed size of the XHTML files in the EPUB,
-- calibrated with the user's own opened books (same font, margins, page
-- length). The text sizes are cached per file in the settings folder.

local FALLBACK_BYTES_PER_PAGE = 2700

local function html_bytes(Archiver, file)
    local reader = Archiver.Reader:new()
    if not reader:open(file) then return nil end
    local total = 0
    local ok = pcall(function()
        for entry in reader:iterate() do
            if entry.mode == "file" then
                local p = entry.path:lower()
                if p:match("%.x?html?$") then total = total + (tonumber(entry.size) or 0) end
            end
        end
    end)
    pcall(reader.close, reader)
    return ok and total > 0 and total or nil
end

--- Adds rec.est_pages to records without a page count (EPUB only).
--- Returns the number of estimated records.
function M.estimatePages(records)
    local need = false
    for _i, r in ipairs(records) do
        if (not r.pages and r.status == "complete") or not r.std_pages then need = true break end
    end
    if not need then return 0 end
    local ok_a, Archiver = pcall(require, "ffi/archiver")
    local lfs = require("libs/libkoreader-lfs")
    if not ok_a or not Archiver then return 0 end
    local store, cached
    local ok_s = pcall(function()
        local DataStorage = require("datastorage")
        local LuaSettings = require("luasettings")
        store = LuaSettings:open(DataStorage:getSettingsDir() .. "/zen_stats_cache.lua")
        cached = store:readSetting("html_bytes") or {}
    end)
    if not ok_s then cached = {} end
    local dirty = false
    local function bytes(file)
        if not file:lower():match("%.epub$") then return nil end
        local mtime = lfs.attributes(file, "modification")
        if not mtime then return nil end
        local c = cached[file]
        if c and c.mtime == mtime then return c.bytes end
        local b = html_bytes(Archiver, file)
        cached[file] = { mtime = mtime, bytes = b }
        dirty = true
        return b
    end
    -- calibration: bytes per page of the user's own opened books. Books with
    -- publisher page labels (printed pages) are preferred: never-opened books
    -- are best compared to a printed book, and screen-page counts depend on
    -- whatever font size was used when the book was last closed.
    local printed, screen = {}, {}
    for _i, r in ipairs(records) do
        if r.pages and r.file then
            local b = bytes(r.file)
            if b and b > 0 then
                local list = r.printed and printed or screen
                list[#list + 1] = b / r.pages
            end
        end
    end
    local ratios = #printed >= 2 and printed or (#printed + #screen > 0 and (function()
        local all = {}
        for _i, v in ipairs(printed) do all[#all + 1] = v end
        for _i, v in ipairs(screen) do all[#all + 1] = v end
        return all
    end)() or {})
    table.sort(ratios)
    local per_page = FALLBACK_BYTES_PER_PAGE
    if #ratios > 0 then per_page = ratios[math.floor((#ratios + 1) / 2)] end
    -- standard pages: calibrated with the books that already have them
    local std_ratios = {}
    for _i, r in ipairs(records) do
        if r.std_pages and r.file then
            local b = bytes(r.file)
            if b and b > 0 then std_ratios[#std_ratios + 1] = b / r.std_pages end
        end
    end
    table.sort(std_ratios)
    if #std_ratios > 0 then
        local per_std = std_ratios[math.floor((#std_ratios + 1) / 2)]
        M.bytes_per_std_page = per_std
        for _i, r in ipairs(records) do
            if not r.std_pages and r.file and (r.status == "complete" or r.status == "reading") then
                local b = bytes(r.file)
                if b then r.est_std = math.max(1, math.floor(b / per_std + 0.5)) end
            end
        end
    end
    local n = 0
    for _i, r in ipairs(records) do
        if not r.pages and r.status == "complete" and r.file then
            local b = bytes(r.file)
            if b then
                r.est_pages = math.max(1, math.floor(b / per_page + 0.5))
                n = n + 1
            end
        end
    end
    if dirty and store then
        pcall(function()
            store:saveSetting("html_bytes", cached)
            store:flush()
        end)
    end
    logger.info("page estimate bytes/page", math.floor(per_page), "calibration books", #ratios, "printed", #printed, "estimated", n)
    return n
end


-- ---- omnibus volumes ------------------------------------------------------
-- An omnibus (several novels in one file) is split into its works so that
-- every novel counts as a book of its own. The structure comes from the
-- top level of the table of contents; the size of each entry from the
-- uncompressed size of the spine files. Anything that is not clearly an
-- omnibus stays one book.

local OMNI_VERSION = 1
local OMNI_MIN_WORK = 150      -- standard pages: a work of its own
local OMNI_MIN_ENTRY = 10      -- below this a TOC entry is front/back matter
local OMNI_MIN_SHORTS = 30     -- short stories together below this: no book of their own
local FALLBACK_BYTES_PER_STD = 2400
local MAX_READ_BYTES = 1024 * 1024   -- largest OPF / TOC / chapter file read from an EPUB
local MAX_TOC_ENTRIES = 500          -- more top level entries: not looked at

local KEYWORDS = { "sammelband", "omnibus", "anthologie", "anthology", "trilogie", "trilogy",
    "gesamtausgabe", "in einem band", "sammlung" }
local FRONT = { "impressum", "copyright", "danksagung", "über den autor", "über die autor", "about the author",
    "glossar", "vorschau", "leseprobe", "inhalt", "widmung", "titel", "nachwort", "vorwort", "prolog",
    "epilog", "karte", "map", "dramatis", "anhang", "cover", "contents", "acknowledg", "publikation",
    "publication", "lizenz", "license" }
local BAD_WORDS = { "teil", "part", "buch", "book", "band", "akt", "kapitel", "chapter" }
local SMALL_WORDS = { der = 1, die = 1, das = 1, des = 1, dem = 1, den = 1, und = 1, oder = 1, von = 1,
    vom = 1, zu = 1, zur = 1, zum = 1, im = 1, ["in"] = 1, am = 1, an = 1, auf = 1, aus = 1, mit = 1,
    ["für"] = 1, of = 1, the = 1, ["and"] = 1, a = 1, on = 1, to = 1, at = 1 }

local function utf8char(n)
    if n < 0x80 then return string.char(n)
    elseif n < 0x800 then return string.char(0xC0 + math.floor(n / 64), 0x80 + n % 64)
    elseif n < 0x10000 then return string.char(0xE0 + math.floor(n / 4096), 0x80 + math.floor(n / 64) % 64, 0x80 + n % 64)
    end
    return "?"
end

local ENT = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " " }
local function clean(s)
    s = (s or ""):gsub("<[^>]+>", " ")
    s = s:gsub("&#[xX](%x+);", function(h) return utf8char(tonumber(h, 16)) end)
    s = s:gsub("&#(%d+);", function(d) return utf8char(tonumber(d)) end)
    s = s:gsub("&(%a+);", function(e) return ENT[e] or ("&" .. e .. ";") end)
    s = s:gsub("\194\173", ""):gsub("\194\160", " "):gsub("%s+", " ")
    return (s:gsub("^ ", ""):gsub(" $", ""))
end

local UP2LOW = { ["\195\132"] = "\195\164", ["\195\150"] = "\195\182", ["\195\156"] = "\195\188" }
local function lower(s) return (s:lower():gsub("\195[\132\150\156]", UP2LOW)) end

local function unesc(s) return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end
local function dirname(p) return p:match("^(.*)/[^/]*$") or "" end
local function join(dir, rel)
    local parts = {}
    for seg in ((dir ~= "" and dir .. "/" or "") .. unesc(rel)):gmatch("[^/]+") do
        if seg == ".." then table.remove(parts) elseif seg ~= "." then parts[#parts + 1] = seg end
    end
    return table.concat(parts, "/")
end
local function attrs(tag)
    local a = {}
    for k, v in tag:gmatch('([%w:_%-]+)%s*=%s*"([^"]*)"') do a[k] = v end
    for k, v in tag:gmatch("([%w:_%-]+)%s*=%s*'([^']*)'") do a[k] = v end
    return a
end

--- Top level entries of an NCX file: { {title=, href=}, ... }
local function ncxTop(x)
    local out, depth, cur, pos = {}, 0, nil, 1
    while true do
        local s, e, close, name, rest = x:find("<(/?)([%w:]+)([^>]*)>", pos)
        if not s then break end
        name = name:gsub("^.*:", "")
        if name == "navPoint" then
            if close == "/" then depth = depth - 1
            elseif not rest:match("/%s*$") then
                depth = depth + 1
                if depth == 1 then cur = {}; out[#out + 1] = cur end
            end
        elseif close == "" and depth == 1 and cur then
            if name == "text" and not cur.title then
                local te = x:find("</[%w:]*text>", e + 1)
                if te then cur.title = clean(x:sub(e + 1, te - 1)) end
            elseif name == "content" and not cur.href then
                cur.href = attrs(rest).src
            end
        end
        pos = e + 1
    end
    return out
end

--- Top level entries of an EPUB 3 navigation document.
local function navTop(x)
    local a = x:find("epub:type%s*=%s*[\"']toc[\"']")
    if a then x = x:sub(a) end
    local stop = x:find("</[%w:]*nav>")
    if stop then x = x:sub(1, stop) end
    local out, depth, cur, pos = {}, 0, nil, 1
    while true do
        local s, e, close, name, rest = x:find("<(/?)([%w:]+)([^>]*)>", pos)
        if not s then break end
        if name == "li" then
            if close == "/" then depth = depth - 1 else
                depth = depth + 1
                if depth == 1 then cur = {}; out[#out + 1] = cur end
            end
        elseif close == "" and depth == 1 and cur and not cur.title and (name == "a" or name == "span") then
            local te = x:find("</" .. name .. ">", e + 1)
            if te then cur.title = clean(x:sub(e + 1, te - 1)) end
            if name == "a" then cur.href = attrs(rest).href end
        end
        pos = e + 1
    end
    return out
end

--- Raw structure of an EPUB: total spine bytes and the top level TOC entries
--- with their byte position in the spine. nil if it cannot be read.
function M.epubStructure(Archiver, file)
    local r = Archiver.Reader:new()
    if not r:open(file) then return nil end
    local res
    local ok, err = pcall(function()
        local sizes = {}
        for entry in r:iterate() do
            if entry.mode == "file" then sizes[entry.path] = tonumber(entry.size) or 0 end
        end
        -- package and TOC files are small; anything larger is not read (a
        -- broken or crafted EPUB must not stall the UI) and the book stays one book
        local function read(p)
            if not sizes[p] or sizes[p] > MAX_READ_BYTES then return nil end
            return r:extractToMemory(p)
        end
        local cont = read("META-INF/container.xml")
        local opf = cont and cont:match("full%-path%s*=%s*[\"']([^\"']+)[\"']")
        local o = opf and read(opf)
        if not o then return end
        local base = dirname(opf)
        local items, spine = {}, {}
        local ncx, nav
        for tag in o:gmatch("<[%w:]*item%s+([^>]*)>") do
            local a = attrs(tag)
            if a.id and a.href then
                items[a.id] = { href = join(base, a.href), mt = a["media-type"], props = a.properties or "" }
                if a["media-type"] == "application/x-dtbncx+xml" then ncx = ncx or items[a.id].href end
                if (" " .. items[a.id].props .. " "):find(" nav ", 1, true) then nav = items[a.id].href end
            end
        end
        local sp = o:match("<[%w:]*spine%s+([^>]*)>")
        local tocid = sp and attrs(sp).toc
        if tocid and items[tocid] then ncx = items[tocid].href end
        for tag in o:gmatch("<[%w:]*itemref%s+([^>]*)>") do
            local it = items[attrs(tag).idref or ""]
            if it then spine[#spine + 1] = it.href end
        end
        local index, cum, total = {}, {}, 0
        for i, p in ipairs(spine) do
            if not index[p] then index[p] = i end
            cum[i] = total
            total = total + (sizes[p] or 0)
        end
        if total <= 0 then return end
        local tocfile = ncx and sizes[ncx] and ncx or nav
        local x = tocfile and read(tocfile)
        if not x then return end
        local top = (tocfile == ncx) and ncxTop(x) or navTop(x)
        if #top > MAX_TOC_ENTRIES then return end
        local tdir = dirname(tocfile)
        local entries = {}
        for _i, t in ipairs(top) do
            if t.href and t.href ~= "" then
                local f, frag = t.href:match("^([^#]*)#?(.*)$")
                local p = join(tdir, f)
                local i = index[p]
                if i then
                    local pos = cum[i]
                    if frag ~= "" then
                        local c = read(p)
                        if c and #c > 0 then
                            local q = frag:gsub("%p", "%%%0")
                            local at = c:find("id%s*=%s*[\"']" .. q .. "[\"']") or c:find("name%s*=%s*[\"']" .. q .. "[\"']")
                            if at then pos = pos + math.floor((sizes[p] or 0) * at / #c) end
                        end
                    end
                    entries[#entries + 1] = { title = t.title or "", pos = pos }
                end
            end
        end
        res = { total = total, entries = entries }
    end)
    pcall(r.close, r)
    if not ok then
        logger.warn("omnibus scan failed:", file, err)
    end
    return res
end

local function titleCase(s)
    if s:find("%l") then return s end
    local out, first = {}, true
    for w in s:gmatch("%S+") do
        local lw = lower(w)
        if not first and SMALL_WORDS[lw] then out[#out + 1] = lw
        else out[#out + 1] = lw:gsub("^\195([\164\182\188])", function(c) return "\195" .. string.char(c:byte() - 32) end)
            :gsub("^%l", string.upper) end
        first = false
    end
    return table.concat(out, " ")
end

local function hasAny(s, list)
    for _i, w in ipairs(list) do if s:find(w, 1, true) then return true end end
    return false
end

local function isBad(t)
    for _i, w in ipairs(BAD_WORDS) do
        if t == w or t:sub(1, #w + 1):match("^" .. w .. "[^%a]") then return true end
    end
    if t:match("^%d+[%s%.%-:]*$") or (#t <= 6 and t:match("^[ivxlc]+[%.:]?$")) then return true end
    if t:match("^%a+er teil") or t:match("^%a+es buch") or t:match("^%a+ part") or t:match("^%a+ book") then return true end
    return false
end

--- Applies the omnibus rules to a raw structure. Returns the parts
--- { {title=, kind="work"|"shorts", ranges={{a,b},...}, share=}, ... } or nil.
function M.omnibusParts(st, title, bytes_per_std)
    if not st or not st.entries or #st.entries < 2 or not st.total or st.total <= 0 then return nil end
    local bpp = bytes_per_std or FALLBACK_BYTES_PER_STD
    local list = {}
    for i, e in ipairs(st.entries) do
        local nxt = st.entries[i + 1]
        local stop = nxt and math.max(e.pos, nxt.pos) or st.total
        list[#list + 1] = { title = e.title, a = e.pos / st.total, b = stop / st.total,
            pages = (stop - e.pos) / bpp, lt = lower(e.title) }
    end
    local big, small = 0, 0
    for _i, e in ipairs(list) do
        e.bad = isBad(e.lt)
        if e.bad and e.pages >= OMNI_MIN_WORK then return nil end   -- a novel in parts
        e.front = e.pages < OMNI_MIN_ENTRY or hasAny(e.lt, FRONT)
        if not e.bad and not e.front then
            if e.pages >= OMNI_MIN_WORK then e.kind = "work"; big = big + 1
            else e.kind = "shorts"; small = small + 1 end
        end
    end
    if small > 0 then
        local sum = 0
        for _i, e in ipairs(list) do if e.kind == "shorts" then sum = sum + e.pages end end
        if sum < OMNI_MIN_SHORTS then
            for _i, e in ipairs(list) do if e.kind == "shorts" then e.kind = nil end end
            small = 0
        end
    end
    local kw = hasAny(lower(title or ""), KEYWORDS)
    if not (big >= 2 or (kw and big >= 1 and small >= 1)) then return nil end
    local parts, shorts, cur, pending = {}, nil, nil, {}
    local function addRange(p, e)
        local r = p.ranges[#p.ranges]
        if r and math.abs(r[2] - e.a) < 1e-9 then r[2] = e.b else p.ranges[#p.ranges + 1] = { e.a, e.b } end
    end
    for _i, e in ipairs(list) do
        local p
        if e.kind == "work" then
            p = { title = titleCase((e.title:gsub("%s+\226\128\148%s+.*$", ""))), kind = "work", ranges = {} }
            parts[#parts + 1] = p
        elseif e.kind == "shorts" then
            if not shorts then shorts = { kind = "shorts", ranges = {} }; parts[#parts + 1] = shorts end
            p = shorts
        else
            p = cur
        end
        if p then
            for _j, q in ipairs(pending) do addRange(p, q) end
            pending = {}
            addRange(p, e)
            if e.kind then cur = p end
        else
            pending[#pending + 1] = e
        end
    end
    for _i, p in ipairs(parts) do
        table.sort(p.ranges, function(x, y) return x[1] < y[1] end)
        local s = 0
        for _j, r in ipairs(p.ranges) do s = s + (r[2] - r[1]) end
        p.share = s
        p.first = p.ranges[1][1]
    end
    table.sort(parts, function(x, y) return x.first < y.first end)
    return parts
end

--- Sets rec.omni (parts) on records that are omnibus volumes. Only books that
--- count for the statistics (finished or being read) are looked at; the raw
--- structure is cached per file and modification time.
function M.detectOmnibus(records)
    local ok_a, Archiver = pcall(require, "ffi/archiver")
    if not ok_a or not Archiver then return 0 end
    local lfs = require("libs/libkoreader-lfs")
    local store, cached
    pcall(function()
        local DataStorage = require("datastorage")
        local LuaSettings = require("luasettings")
        store = LuaSettings:open(DataStorage:getSettingsDir() .. "/zen_stats_cache.lua")
        cached = store:readSetting("omnibus") or {}
    end)
    cached = cached or {}
    local dirty, found = false, 0
    local todo = {}
    for _i, r in ipairs(records) do
        if r.file and r.file:lower():match("%.epub$") and (r.status == "complete" or r.status == "reading") then
            local mtime = lfs.attributes(r.file, "modification")
            if mtime then
                local c = cached[r.file]
                if not (c and c.mtime == mtime and c.v == OMNI_VERSION) then
                    local st = M.epubStructure(Archiver, r.file)
                    c = { mtime = mtime, v = OMNI_VERSION, total = st and st.total, entries = st and st.entries }
                    cached[r.file] = c
                    dirty = true
                end
                if c.total and c.entries then todo[#todo + 1] = { r = r, st = c } end
            end
        end
    end
    -- bytes per standard page: the book's own count if known, else the median
    local ratios = {}
    for _i, t in ipairs(todo) do
        local std = t.r.std_pages
        if std and std > 0 then ratios[#ratios + 1] = t.st.total / std end
    end
    table.sort(ratios)
    local median = #ratios > 0 and ratios[math.floor((#ratios + 1) / 2)] or M.bytes_per_std_page
    for _i, t in ipairs(todo) do
        local std = t.r.std_pages
        local bpp = (std and std > 0) and t.st.total / std or median
        local parts = M.omnibusParts(t.st, t.r.title, bpp)
        if parts then t.r.omni = parts; found = found + 1 end
    end
    if dirty and store then
        pcall(function()
            store:saveSetting("omnibus", cached)
            store:flush()
        end)
    end
    return found
end

M._record_from = record_from   -- for tests

return M
