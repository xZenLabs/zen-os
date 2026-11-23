-- common/book_sources.lua
-- Books that are not rows in KOReader's bookinfo cache but should still appear
-- in the Authors, Series, Languages and Tags views (and everything built on
-- db_bookinfo: Home rows, end-of-book suggestions, detail sorting).
--
-- The Kindle virtual library is the built-in source. Other plugins can
-- register their own, for example a catalog of books that are not on the
-- device yet:
--
--   require("common/book_sources").register("my_plugin", {
--       -- Required. Each book: { file = path, info = metadata }, where info
--       -- has the bookinfo fields db_bookinfo groups by: title, authors,
--       -- series, series_index, language, keywords (authors and keywords
--       -- joined with "\n", as in bookinfo). Called when db_bookinfo
--       -- rebuilds a grouping, so return a cached list if it is costly.
--       books = function() return { ... } end,
--       -- Optional: true for paths this source owns. Needed for open and
--       -- showContextMenu, and for its books to stay in the reading history
--       -- views (Home, book switcher) and To Be Read when their file is
--       -- missing.
--       owns = function(path) return ... end,
--       -- Optional: open a book. Return true when handled; ZenOS then skips
--       -- its own opening (and marking the book as reading).
--       open = function(path, ui) return true end,
--       -- Optional: long-press on a book in a group view or on Home. Return
--       -- true when handled. item may carry ZenOS context fields
--       -- (_zen_is_history, _zen_history_path); a source that shows
--       -- FileChooser:showFileDialog() should pass them through so the
--       -- dialog keeps rows such as "Remove from history".
--       showContextMenu = function(menu, item, after_change) return true end,
--       -- Optional: drop cached books (db_bookinfo.invalidate()).
--       invalidate = function() end,
--       -- Optional: CoverBrowser metadata for a book this source owns, in
--       -- the shape BookInfoManager:getBookInfo() returns (title, authors,
--       -- cover_fetched, has_cover, cover_bb when get_cover...). Return nil
--       -- for other paths. Answers getBookInfo() and getDocProps() for
--       -- the whole UI, so keep it cheap and don't block: without the
--       -- cover yet, return the metadata and call changed({ path }) once
--       -- the cover arrives. Calls to getBookInfo() for the same path from
--       -- inside it go to CoverBrowser's database. The book's custom
--       -- metadata (KOReader's custom_metadata.lua: edits made in ZenOS's
--       -- metadata editor or KOReader's Book information, or written by a
--       -- plugin such as a sync plugin) is shown over these fields (and
--       -- those books() gives), as KOReader shows it over a file's own; it
--       -- is never written back to the source. A plugin that writes custom
--       -- metadata announces it as KOReader does, with the
--       -- InvalidateMetadataCache event naming the book.
--       bookInfo = function(path, get_cover) return { ... } end,
--       -- Optional: for a source whose books appear in file browser
--       -- listings (it adds them itself, e.g. by wrapping
--       -- FileChooser:getList). Return a string for each folder whose
--       -- listing shows them (including parent folders that count them, or
--       -- show them in flat view), nil for others. It goes into the key of
--       -- ZenOS's cached listings, which are kept across restarts, so it
--       -- must change whenever the books shown there change (a catalog
--       -- version or hash, not a counter that restarts). Called for every
--       -- listing; keep it cheap.
--       listingKey = function(folder) return ... end,
--       -- Optional: reading status for a book that has no sidecar on this
--       -- device (e.g. a catalog book not downloaded yet), as
--       -- { status = "reading"|"complete"|"abandoned", percent_finished =
--       -- 0..1 } (either may be nil), or nil for books it knows nothing
--       -- of. A finished book may add finished_at (Unix time or
--       -- "YYYY-MM-DD"), counted in the books finished this month and
--       -- year. It may also give rating (1..5 stars, as KOReader rates),
--       -- shown in book details when this device has no rating for the
--       -- book; return a table with only rating for a book with no status.
--       -- Read-only: ZenOS never writes it back, and a sidecar on this
--       -- device wins. Asked for every book without a sidecar, so keep it
--       -- cheap (return nil early for paths it doesn't own), and call
--       -- statusChanged() when statuses change.
--       status = function(path) return { status = "complete" } end,
--       -- Optional: books read elsewhere (e.g. on another device), as
--       -- { { file = path, time = Unix time last read }, ... }. They join
--       -- this device's reading history on Home and in the book switcher.
--       -- A book in this device's history keeps its time from there.
--       -- Books without a file show only when owns() claims them.
--       -- Asked whenever those views rebuild, so return a cached list, and
--       -- call statusChanged() when it changes. "Remove from history"
--       -- hides an entry until the source gives it a later time.
--       history = function() return { ... } end,
--   })
--
-- Call changed() when a source's books change, so cached groupings are
-- rebuilt; changed(paths) also drops ZenOS's cached covers and metadata
-- for those books. Call statusChanged() when only their reading statuses
-- or history change: they are read again, groupings are kept. A source that errors is skipped; the views keep working.
-- Books whose path db_bookinfo already lists are not added again.

local logger = require("common/zen_logger").new("book_sources")

local M = {}

local BUILTIN = {
    kindle = "common/book_sources_kindle",
}

local sources = {}  -- id -> source
local order = {}    -- ids, in registration order
local revision = 0
local status_revision = 0
local builtins_loaded = false

local function load_builtins()
    if builtins_loaded then return end
    builtins_loaded = true
    for _i, id in ipairs({ "kindle" }) do
        if not sources[id] then
            local ok, source = pcall(require, BUILTIN[id])
            if ok and type(source) == "table" then
                M.register(id, source)
            elseif not ok then
                logger.warn("built-in book source failed to load", id, source)
            end
        end
    end
end

local function call(id, source, method, ...)
    local fn = source[method]
    if type(fn) ~= "function" then return nil end
    local ok, result = pcall(fn, ...)
    if ok then return result end
    logger.warn("book source failed", id, method, result)
    return nil
end

function M.register(id, source)
    if type(id) ~= "string" or id == "" or type(source) ~= "table"
            or type(source.books) ~= "function" then
        logger.warn("ignoring invalid book source", tostring(id))
        return false
    end
    load_builtins() -- built-in sources come first
    if not sources[id] then order[#order + 1] = id end
    sources[id] = source
    M.changed()
    return true
end

function M.unregister(id)
    if not sources[id] then return end
    sources[id] = nil
    for i, other in ipairs(order) do
        if other == id then table.remove(order, i) break end
    end
    M.changed()
end

local function drop_cached_covers(paths)
    local decode = package.loaded["common/cover_decode_cache"]
    local render = package.loaded["common/cover_render_cache"]
    for _i, path in ipairs(paths) do
        if type(path) == "string" then
            for _j, cache in ipairs({ decode, render }) do
                if type(cache) == "table" and type(cache.drop) == "function" then
                    pcall(cache.drop, cache, path)
                end
            end
        end
    end
end

--- Marks every source's books as changed (cached groupings are rebuilt).
-- With a list of paths, also drops ZenOS's cached covers and metadata for
-- them (call it when a book's metadata or cover changes).
function M.changed(paths)
    revision = revision + 1
    if type(paths) == "table" then drop_cached_covers(paths) end
end

--- Changes whenever a source is registered, removed or reports a change.
function M.revision()
    load_builtins()
    return revision
end

--- Marks every source's reading statuses as changed (books unchanged).
function M.statusChanged()
    status_revision = status_revision + 1
end

--- Changes whenever revision() does or a source reports a status change.
function M.statusRevision()
    return M.revision() + status_revision
end

-- ---- metadata edits ---------------------------------------------------
-- Sources' books that have custom metadata (path -> true), kept in
-- G_reader_settings, from ZenOS's editor, the InvalidateMetadataCache
-- events that announce custom metadata written elsewhere (see
-- customMetadataChanged), and sidecars found the first time a book's
-- cover is asked for in a session (see discover_edits). Only these have
-- their sidecar's custom metadata looked up in books(), so listing a
-- source's whole library doesn't stat sidecars for every book in it.
local EDITED_KEY = "zen_book_sources_edited"
-- Fields an edit may override (the bookinfo fields sources give).
local EDITABLE = { "title", "authors", "series", "series_index", "language",
    "keywords", "description" }

local function reader_settings()
    local settings = rawget(_G, "G_reader_settings")
    return type(settings) == "table" and settings or nil
end

local function edited_books()
    local settings = reader_settings()
    local edited = settings and settings:readSetting(EDITED_KEY)
    return type(edited) == "table" and edited or {}
end

-- The book's custom metadata file (KOReader's custom_metadata.lua), or nil.
local function custom_metadata_file(path)
    local ok, DocSettings = pcall(require, "docsettings")
    if not ok or type(DocSettings) ~= "table"
            or type(DocSettings.findCustomMetadataFile) ~= "function" then
        return nil
    end
    local ok_find, file = pcall(DocSettings.findCustomMetadataFile, DocSettings, path)
    return ok_find and type(file) == "string" and file or nil
end

-- The custom fields of a book in EDITED_KEY, read from its sidecar, or nil.
local function edits(path)
    local file = custom_metadata_file(path)
    local props
    local ok, DocSettings = pcall(require, "docsettings")
    if file and ok and type(DocSettings.openSettingsFile) == "function" then
        local ok_open, settings = pcall(DocSettings.openSettingsFile, file)
        local custom = ok_open and settings and type(settings.readSetting) == "function"
            and settings:readSetting("custom_props")
        if type(custom) == "table" then
            for _i, key in ipairs(EDITABLE) do
                if custom[key] ~= nil then
                    props = props or {}
                    props[key] = custom[key]
                end
            end
        end
    end
    return props
end

-- info with the book's edits over it (a copy), or info itself.
local function with_edits(path, info, edited)
    if not edited[path] then return info end
    local props = edits(path)
    if not props then return info end
    local copy = {}
    for key, value in pairs(info) do copy[key] = value end
    for key, value in pairs(props) do copy[key] = value end
    return copy
end

--- All sources' books, in registration order: { { file, info }, ... }.
function M.books()
    load_builtins()
    local out = {}
    local edited = edited_books()
    local any_edited = next(edited) ~= nil
    for _i, id in ipairs(order) do
        local books = call(id, sources[id], "books")
        if type(books) == "table" then
            for _j, book in ipairs(books) do
                if type(book) == "table" and type(book.file) == "string" and book.file ~= ""
                        and type(book.info) == "table" then
                    if any_edited and edited[book.file] then
                        local info = with_edits(book.file, book.info, edited)
                        if info ~= book.info then book = { file = book.file, info = info } end
                    end
                    out[#out + 1] = book
                end
            end
        end
    end
    return out
end

local function owner(path)
    if type(path) ~= "string" then return nil end
    load_builtins()
    for _i, id in ipairs(order) do
        if call(id, sources[id], "owns", path) == true then return id, sources[id] end
    end
end

--- True when a source owns this path (its book counts as present even
-- without a file).
function M.owns(path)
    return owner(path) ~= nil
end

--- True when a source owns this path and there is no file at it (e.g. a
-- catalog book not downloaded yet): nothing on the device to act on.
function M.ownsWithoutFile(path)
    if owner(path) == nil then return false end
    local ok, util = pcall(require, "util")
    return not (ok and type(util.fileExists) == "function" and util.fileExists(path))
end

--- Opens a source's book. Returns true when a source handled it.
function M.open(path, ui)
    local id, source = owner(path)
    return id ~= nil and call(id, source, "open", path, ui) == true
end

--- Long-press on a source's book. Returns true when a source handled it.
function M.showContextMenu(menu, item, after_change)
    local id, source = owner(type(item) == "table" and item.path or nil)
    return id ~= nil and call(id, source, "showContextMenu", menu, item, after_change) == true
end

local answering = {} -- paths whose bookInfo is being built (re-entry guard)

-- The sources' own metadata for a book, without edits. The second result
-- is true when the lookup couldn't be completed (a source's bookInfo
-- failed, or the book's lookup is already under way), so a nil info
-- doesn't mean that no source gives the book's metadata.
local function source_book_info(path, get_cover)
    if type(path) ~= "string" then return nil, false end
    if answering[path] then return nil, true end
    load_builtins()
    answering[path] = true
    local info, failed
    for _i, id in ipairs(order) do
        local source = sources[id]
        if type(source.bookInfo) == "function" then
            local ok, result = pcall(source.bookInfo, path, get_cover)
            if not ok then
                logger.warn("book source failed", id, "bookInfo", result)
                failed = true
            elseif type(result) == "table" then
                info = result
                break
            end
        end
    end
    answering[path] = nil
    return info, failed == true and not info
end

local discovered = {} -- paths whose sidecar was looked for this session

-- Adds a source's book to EDITED_KEY when it has custom metadata that was
-- never announced (written before this was tracked, or without the event),
-- looking once per book per session. Only asked when the book's cover is
-- (the book is being drawn), so metadata-only passes over a listing (sort,
-- series grouping, search) don't stat each book's sidecar. Returns the
-- edited list.
local function discover_edits(path)
    local edited = edited_books()
    if edited[path] or discovered[path] then return edited end
    discovered[path] = true
    local settings = reader_settings()
    if settings and custom_metadata_file(path) then
        local kept = {}
        for book in pairs(edited) do kept[book] = true end
        kept[path] = true
        settings:saveSetting(EDITED_KEY, kept)
        M.changed() -- rebuild groupings with the book's edits
        return kept
    end
    return edited
end

--- CoverBrowser metadata from the source that has it, with the edits made
-- in ZenOS over it, or nil.
function M.bookInfo(path, get_cover)
    local info = source_book_info(path, get_cover)
    if not info then return nil end
    return with_edits(path, info, get_cover and discover_edits(path) or edited_books())
end

--- True when a source gives this book's metadata, so ZenOS's metadata
-- editor keeps its edits in the sidecar (see metadataEdited) instead of
-- writing them into the book file.
-- When the lookup can't be completed (a source's bookInfo failed), any book
-- counts, so a passing failure never sends edits into a source's file; the
-- sidecar is the safe place for them either way.
function M.suppliesMetadata(path)
    local info, failed = source_book_info(path, false)
    return info ~= nil or failed == true
end

--- Tells the sources' views that a book's custom metadata changed (written
-- by ZenOS's editor, KOReader's Book information or another plugin): it is
-- shown over the source's metadata from now on, or no more once cleared.
-- Returns true when a source gives the book's metadata.
function M.customMetadataChanged(path)
    if not M.suppliesMetadata(path) then return false end
    local settings = reader_settings()
    if settings then
        -- Only this book's entry changes: others stay even when their
        -- sidecar can't be found right now (with_edits() copes with that).
        local kept = {}
        for book in pairs(edited_books()) do kept[book] = true end
        kept[path] = custom_metadata_file(path) and true or nil
        settings:saveSetting(EDITED_KEY, kept)
    end
    M.changed({ path })
    return true
end

--- Tells the sources' views that a book's metadata was edited in ZenOS's
-- metadata editor (see customMetadataChanged).
function M.metadataEdited(path)
    return M.customMetadataChanged(path)
end

local STATUSES = { reading = true, complete = true, abandoned = true }

-- finished_at as "YYYY-MM-DD" (the form of a sidecar's summary.modified).
local function finished_date(value)
    if type(value) == "number" and value > 0 then
        return os.date("%Y-%m-%d", math.floor(value))
    end
    if type(value) == "string" then
        return value:match("^(%d%d%d%d%-%d%d%-%d%d)")
    end
end

-- rating as whole stars, 1..5.
local function stars(value)
    value = tonumber(value)
    if not value then return nil end
    value = math.floor(value + 0.5)
    return value >= 1 and value <= 5 and value or nil
end

-- The status hook's answer from the first source that knows the book.
local function known_status(path)
    if type(path) ~= "string" or path == "" then return nil end
    load_builtins()
    for _i, id in ipairs(order) do
        local source = sources[id]
        if type(source.status) == "function" then
            local result = call(id, source, "status", path)
            if type(result) == "table" then
                local status = STATUSES[result.status] and result.status or nil
                local percent = tonumber(result.percent_finished)
                if percent then percent = math.max(0, math.min(1, percent)) end
                local rating = stars(result.rating)
                if status or percent or rating then
                    return { status = status, percent_finished = percent,
                        finished_at = finished_date(result.finished_at), rating = rating }
                end
            end
        end
    end
end

--- Reading status from the first source that knows the book:
-- { status, percent_finished, finished_at, rating } (any may be nil, but
-- not both status and percent_finished), or nil. finished_at is
-- "YYYY-MM-DD".
function M.status(path)
    local known = known_status(path)
    if known and (known.status or known.percent_finished) then return known end
end

--- Star rating (1..5) from the first source that knows the book, or nil.
function M.rating(path)
    local known = known_status(path)
    return known and known.rating
end

-- Source history entries the user removed: path -> the time removed. Kept
-- in G_reader_settings so they stay hidden across restarts.
local DISMISSED_KEY = "zen_book_sources_dismissed_history"

local function dismissed_history()
    local settings = reader_settings()
    local dismissed = settings and settings:readSetting(DISMISSED_KEY)
    return type(dismissed) == "table" and dismissed or {}
end

--- The sources' history: { { file, time }, ... }, newest first, one entry
-- per book (from the first source that has it), without removed entries.
function M.history()
    load_builtins()
    local dismissed = dismissed_history()
    local out, seen = {}, {}
    for _i, id in ipairs(order) do
        local source = sources[id]
        if type(source.history) == "function" then
            local entries = call(id, source, "history")
            if type(entries) == "table" then
                for _j, entry in ipairs(entries) do
                    local file = type(entry) == "table" and entry.file
                    local time = type(entry) == "table" and tonumber(entry.time)
                    if type(file) == "string" and file ~= "" and time and not seen[file] then
                        seen[file] = true
                        local removed = tonumber(dismissed[file])
                        if not (removed and time <= removed) then
                            out[#out + 1] = { file = file, time = time }
                        end
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.time ~= b.time then return a.time > b.time end
        return a.file < b.file
    end)
    return out
end

--- ReadHistory.hist with the sources' history merged in by time (newest
-- first). Books already in hist keep their entry there. Returns hist
-- itself when the sources add nothing.
function M.mergeHistory(hist)
    hist = type(hist) == "table" and hist or {}
    local extra = M.history()
    if #extra == 0 then return hist end
    local local_files = {}
    for _i, entry in ipairs(hist) do
        if type(entry) == "table" and entry.file then local_files[entry.file] = true end
    end
    local out, next_extra = {}, 1
    local function add_extra_until(time)
        while extra[next_extra] and (time == nil or extra[next_extra].time > time) do
            local entry = extra[next_extra]
            if not local_files[entry.file] then out[#out + 1] = entry end
            next_extra = next_extra + 1
        end
    end
    for _i, entry in ipairs(hist) do
        add_extra_until(type(entry) == "table" and tonumber(entry.time) or 0)
        out[#out + 1] = entry
    end
    add_extra_until(nil)
    return out
end

--- Hides a book's source history entry (its "Remove from history") until
-- a source gives it a later time. Returns true when there was one.
function M.dismissHistory(path)
    if type(path) ~= "string" or path == "" then return false end
    local time
    for _i, entry in ipairs(M.history()) do
        if entry.file == path then time = entry.time break end
    end
    local settings = reader_settings()
    if not (time and settings) then return false end
    local dismissed = dismissed_history()
    -- Drop entries whose book the sources no longer list, but only when
    -- every source listed its history (a failed one may still have them).
    local listed, complete = {}, true
    for _i, id in ipairs(order) do
        if type(sources[id].history) == "function" then
            local entries = call(id, sources[id], "history")
            if type(entries) == "table" then
                for _j, entry in ipairs(entries) do
                    if type(entry) == "table" and entry.file then listed[entry.file] = true end
                end
            else
                complete = false
            end
        end
    end
    local kept = {}
    for file, removed in pairs(dismissed) do
        if listed[file] or not complete then kept[file] = removed end
    end
    kept[path] = time
    settings:saveSetting(DISMISSED_KEY, kept)
    M.statusChanged()
    return true
end

-- getDocProps() returns these bookinfo fields (CoverBrowser columns 13-20).
local DOC_PROPS = { "pages", "title", "authors", "series", "series_index",
    "language", "keywords", "description" }

--- Routes CoverBrowser's getBookInfo() and getDocProps() through the
-- sources, once for all of them. Installed before ZenOS's own wrappers
-- (cover caches), so those see sources' books like any other.
function M.installMetadataIntegration()
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok or type(BookInfoManager) ~= "table"
            or type(BookInfoManager.getBookInfo) ~= "function" then
        return false
    end
    if BookInfoManager._zen_book_sources_patched then return true end
    BookInfoManager._zen_book_sources_patched = true

    local orig_getBookInfo = BookInfoManager.getBookInfo
    function BookInfoManager:getBookInfo(filepath, get_cover, ...)
        local info = M.bookInfo(filepath, get_cover)
        if info then return info end
        return orig_getBookInfo(self, filepath, get_cover, ...)
    end

    local orig_getDocProps = BookInfoManager.getDocProps
    if type(orig_getDocProps) == "function" then
        function BookInfoManager:getDocProps(filepath, ...)
            local info = M.bookInfo(filepath, false)
            local props = orig_getDocProps(self, filepath, ...)
            if not info then return props end
            -- A book with a CoverBrowser row (a Kindle book on disk) keeps
            -- the fields its source doesn't give.
            props = type(props) == "table" and props or {}
            for _i, key in ipairs(DOC_PROPS) do
                if info[key] ~= nil then props[key] = info[key] end
            end
            return props
        end
    end
    return true
end

--- Key for a folder's cached listing: the listing keys of the sources whose
-- books it shows ("" when none).
function M.listingKey(folder)
    load_builtins()
    local parts = {}
    for _i, id in ipairs(order) do
        local source = sources[id]
        if type(source.listingKey) == "function" then
            local key = call(id, source, "listingKey", folder)
            if type(key) == "string" or type(key) == "number" then
                parts[#parts + 1] = id .. "=" .. tostring(key)
            end
        end
    end
    return table.concat(parts, "\31")
end

--- Drops the sources' cached books.
function M.invalidate()
    for _i, id in ipairs(order) do call(id, sources[id], "invalidate") end
end

return M
