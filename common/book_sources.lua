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
--       -- Optional: long-press on a book in a group view. Return true when
--       -- handled.
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
--       -- inside it go to CoverBrowser's database.
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
--   })
--
-- Call changed() when a source's books change, so cached groupings are
-- rebuilt; changed(paths) also drops ZenOS's cached covers and metadata
-- for those books. A source that errors is skipped; the views keep working.
-- Books whose path db_bookinfo already lists are not added again.

local logger = require("common/zen_logger").new("book_sources")

local M = {}

local BUILTIN = {
    kindle = "common/book_sources_kindle",
}

local sources = {}  -- id -> source
local order = {}    -- ids, in registration order
local revision = 0
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

--- All sources' books, in registration order: { { file, info }, ... }.
function M.books()
    load_builtins()
    local out = {}
    for _i, id in ipairs(order) do
        local books = call(id, sources[id], "books")
        if type(books) == "table" then
            for _j, book in ipairs(books) do
                if type(book) == "table" and type(book.file) == "string" and book.file ~= ""
                        and type(book.info) == "table" then
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

--- CoverBrowser metadata from the source that has it, or nil.
function M.bookInfo(path, get_cover)
    if type(path) ~= "string" or answering[path] then return nil end
    load_builtins()
    answering[path] = true
    local info
    for _i, id in ipairs(order) do
        local source = sources[id]
        if type(source.bookInfo) == "function" then
            local result = call(id, source, "bookInfo", path, get_cover)
            if type(result) == "table" then info = result break end
        end
    end
    answering[path] = nil
    return info
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
