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
--       -- showContextMenu.
--       owns = function(path) return ... end,
--       -- Optional: open a book. Return true when handled; ZenOS then skips
--       -- its own opening (and marking the book as reading).
--       open = function(path, ui) return true end,
--       -- Optional: long-press on a book in a group view. Return true when
--       -- handled.
--       showContextMenu = function(menu, item, after_change) return true end,
--       -- Optional: drop cached books (db_bookinfo.invalidate()).
--       invalidate = function() end,
--   })
--
-- Call changed() when a source's books change, so cached groupings are
-- rebuilt. A source that errors is skipped; the views keep working.
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

--- Marks every source's books as changed (cached groupings are rebuilt).
function M.changed()
    revision = revision + 1
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

--- Drops the sources' cached books.
function M.invalidate()
    for _i, id in ipairs(order) do call(id, sources[id], "invalidate") end
end

return M
