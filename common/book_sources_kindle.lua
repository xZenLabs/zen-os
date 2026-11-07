-- common/book_sources_kindle.lua
-- The Kindle virtual library as a book source (see common/book_sources.lua).

local lfs = require("libs/libkoreader-lfs")
local MemoryPolicy = require("common/memory_policy")
local now = require("common/zen_logger").now
local bimOk, BookInfoManager = pcall(require, "bookinfomanager")

local KINDLE = "modules/filebrowser/patches/kindle_virtual_library"
local CACHE_TTL_S = 300

local M = {}
local cache

local function kindle()
    local ok, Kindle = pcall(require, KINDLE)
    return ok and type(Kindle) == "table" and Kindle or nil
end

local function file_signature(path)
    if not path then return "nil" end
    local attr = lfs.attributes(path)
    return tostring(attr and attr.size) .. ":" .. tostring(attr and attr.modification)
end

-- Kindle metadata is read through BookInfoManager, so it changes with the
-- bookinfo database as well as with the library's book list.
local function generation(book_paths)
    local db_path = bimOk and BookInfoManager.db_location or nil
    return table.concat({
        file_signature(db_path),
        file_signature(db_path and (db_path .. "-wal")),
        table.concat(book_paths, "\0"),
    }, "|")
end

function M.books()
    local Kindle = kindle()
    if not Kindle or type(Kindle.getBookPaths) ~= "function" then return {} end
    local ok_paths, book_paths = pcall(Kindle.getBookPaths)
    if not ok_paths or type(book_paths) ~= "table" then return {} end

    local key = generation(book_paths)
    if cache and cache.generation == key and cache.expires_at > now() then
        return cache.value
    end

    local books = {}
    local seen = {}
    for _i, filepath in ipairs(book_paths) do
        if type(filepath) == "string" and filepath ~= "" and not seen[filepath]
                and lfs.attributes(filepath, "mode") == "file" then
            seen[filepath] = true
            local ok_info, info
            if type(Kindle.getBookMetadata) == "function" then
                ok_info, info = pcall(Kindle.getBookMetadata, filepath)
            elseif bimOk then
                ok_info, info = pcall(BookInfoManager.getBookInfo,
                    BookInfoManager, filepath, false)
            end
            if ok_info and type(info) == "table" then
                books[#books + 1] = { file = filepath, info = info }
            end
        end
    end
    cache = not MemoryPolicy.limitGroupCache() and {
        generation = key,
        expires_at = now() + CACHE_TTL_S,
        value = books,
    } or nil
    return books
end

function M.owns(path)
    local Kindle = kindle()
    return Kindle ~= nil and type(Kindle.isBookPath) == "function"
        and Kindle.isBookPath(path) == true
end

function M.showContextMenu(menu, item, after_change)
    local Kindle = kindle()
    return Kindle ~= nil and type(Kindle.showBookContextMenu) == "function"
        and Kindle.showBookContextMenu(menu, item, after_change) == true
end

function M.invalidate()
    cache = nil
end

return M
