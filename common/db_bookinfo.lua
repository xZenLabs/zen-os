-- common/db_bookinfo.lua
-- Queries KOReader's bookinfo_cache.sqlite3 to group books by metadata.
-- Used by the Authors, Series, Tags, and Languages navbar tabs.

local zen_logger = require("common/zen_logger")
local logger = zen_logger.new("db_bookinfo")
local now = zen_logger.now
local lfs = require("libs/libkoreader-lfs")
local iso_ok, IsoLanguage = pcall(require, "ui/data/isolanguage")
local paths = require("common/paths")
local MemoryPolicy = require("common/memory_policy")
local bimOk, BookInfoManager = pcall(require, "bookinfomanager")

local M = {}
local GROUP_CACHE_TTL_S = 300
local DIRECTORY_METADATA_CACHE_MAX = 32
local DIRECTORY_METADATA_CACHE_MAX_CONSTRAINED = 4
local group_cache = {}
local kindle_metadata_cache
local cache_hits = 0
local cache_misses = 0

local function file_signature(path)
    if not path then return "nil" end
    local attr = lfs.attributes(path)
    return table.concat({
        tostring(attr and attr.size),
        tostring(attr and attr.modification),
    }, ":")
end

local function cache_generation()
    local db_path = BookInfoManager and BookInfoManager.db_location
    return table.concat({
        tostring(paths.getHomeDir()),
        file_signature(db_path),
        file_signature(db_path and (db_path .. "-wal")),
    }, "|")
end

local function get_cached(kind)
    if MemoryPolicy.limitGroupCache() then
        for cached_kind in pairs(group_cache) do
            if cached_kind ~= kind then group_cache[cached_kind] = nil end
        end
    end
    local entry = group_cache[kind]
    if entry and entry.generation == cache_generation() and entry.expires_at > now() then
        cache_hits = cache_hits + 1
        return entry.value
    end
    group_cache[kind] = nil
    cache_misses = cache_misses + 1
end

local function save_cached(kind, value)
    if MemoryPolicy.limitGroupCache() then
        group_cache = {}
    end
    group_cache[kind] = {
        generation = cache_generation(),
        expires_at = now() + GROUP_CACHE_TTL_S,
        value = value,
    }
end

function M.invalidate()
    group_cache = {}
    kindle_metadata_cache = nil
end

function M.getCacheStats()
    return { hits = cache_hits, misses = cache_misses }
end

-- Returns the authors string as-is (no splitting) so multi-author books
-- are grouped under their combined author string.
local function splitAuthors(authors_str)
    if not authors_str or authors_str == "" then return {} end
    local trimmed = authors_str:match("^%s*(.-)%s*$")
    if trimmed == "" then return {} end
    return { trimmed }
end

local function get_kindle_metadata()
    local ok_kindle, Kindle = pcall(require,
        "modules/filebrowser/patches/kindle_virtual_library")
    if not ok_kindle or type(Kindle.getBookPaths) ~= "function" then return {} end
    local ok_paths, book_paths = pcall(Kindle.getBookPaths)
    if not ok_paths or type(book_paths) ~= "table" then return {} end

    local generation = cache_generation() .. "|" .. table.concat(book_paths, "\0")
    if kindle_metadata_cache and kindle_metadata_cache.generation == generation
            and kindle_metadata_cache.expires_at > now() then
        return kindle_metadata_cache.value
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
            else
                ok_info, info = pcall(BookInfoManager.getBookInfo,
                    BookInfoManager, filepath, false)
            end
            if ok_info and type(info) == "table" then
                books[#books + 1] = { file = filepath, info = info }
            end
        end
    end
    kindle_metadata_cache = not MemoryPolicy.limitGroupCache() and {
        generation = generation,
        expires_at = now() + GROUP_CACHE_TTL_S,
        value = books,
    } or nil
    return books
end

local function add_unseen_file(seen, filepath)
    local normalized = paths.normPath(filepath)
    if seen[filepath] or seen[normalized] then return false end
    seen[filepath] = true
    seen[normalized] = true
    return true
end

local function get_valid_book_path(home_dir, directory, filename)
    if not directory or not filename then return nil end
    local raw_filepath = directory .. filename
    local normalized_filepath = paths.normPath(raw_filepath)
    if home_dir and not paths.isInHomeDir(normalized_filepath) then return nil end
    if lfs.attributes(normalized_filepath, "mode") ~= "file" then return nil end
    -- Keep the database key: BookInfoManager and DocSettings may not use the
    -- normalized path on Android symlinked storage.
    return raw_filepath
end

local function for_each_valid_book_row(conn, sql, callback)
    local result = conn:exec(sql)
    if not result then return 0 end
    local directories = result[1] or {}
    local filenames = result[2] or {}
    local home_dir = paths.getHomeDir()
    for index = 1, #directories do
        local raw_filepath = get_valid_book_path(home_dir, directories[index], filenames[index])
        if raw_filepath then
            callback(raw_filepath, filenames[index], result, index)
        end
    end
    return #directories
end

local function sorted_groups(group_map, group_key, files_key)
    local groups = {}
    for name, files in pairs(group_map) do
        groups[#groups + 1] = { [group_key] = name, [files_key] = files }
    end
    table.sort(groups, function(a, b) return a[group_key] < b[group_key] end)
    return groups
end

-- Returns a sorted list of author groups:
--   { { author="Name", files={"/abs/path", ...} }, ... }
-- Includes existing books within home_dir and the Kindle virtual library.
-- Each book appears under every author it has (multi-author support).
function M.getGroupedByAuthor()
    local started_at = now()
    if not bimOk then
        logger.warn("BookInfoManager not available")
        return {}
    end
    local cached = get_cached("authors")
    if cached then
        logger.measure("Author groups loaded", (now() - started_at) * 1000,
            "cache=hit", "groups=", #cached)
        return cached
    end
    BookInfoManager:openDbConnection()
    local conn = BookInfoManager.db_conn

    local author_map = {}  -- author -> { files }
    local seen_files = {}

    local row_count = 0
    local ok2, err = pcall(function()
        local sql = [[
            SELECT directory, filename, authors
            FROM bookinfo
            WHERE in_progress = 0
              AND authors IS NOT NULL
              AND authors != ''
            ORDER BY authors
        ]]
        row_count = for_each_valid_book_row(conn, sql, function(raw_filepath, _filename, result, index)
            add_unseen_file(seen_files, raw_filepath)
            local authors_str = result[3] and result[3][index]
            if authors_str then
                local author_list = splitAuthors(authors_str)
                for _i, author in ipairs(author_list) do
                    if not author_map[author] then
                        author_map[author] = {}
                    end
                    table.insert(author_map[author], raw_filepath)
                end
            end
        end)
        for _i, book in ipairs(get_kindle_metadata()) do
            if add_unseen_file(seen_files, book.file) then
                local authors = book.info.authors
                if type(authors) == "table" then authors = table.concat(authors, "\n") end
                for _j, author in ipairs(splitAuthors(authors)) do
                    if not author_map[author] then author_map[author] = {} end
                    table.insert(author_map[author], book.file)
                end
            end
        end
    end)

    if not ok2 then
        logger.warn("query error:", err)
        return {}
    end

    -- Build sorted list
    local groups = sorted_groups(author_map, "author", "files")
    save_cached("authors", groups)
    logger.measure("Author groups loaded", (now() - started_at) * 1000,
        "cache=miss", "rows=", row_count, "groups=", #groups)
    return groups
end

-- Returns a sorted list of language groups:
--   { { language="en", files={"/abs/path", ...} }, ... }
-- Includes existing books within home_dir and the Kindle virtual library.
function M.getGroupedByLanguage()
    local started_at = now()
    if not bimOk then
        logger.warn("BookInfoManager not available")
        return {}
    end
    local cached = get_cached("languages")
    if cached then
        logger.measure("Language groups loaded", (now() - started_at) * 1000,
            "cache=hit", "groups=", #cached)
        return cached
    end
    BookInfoManager:openDbConnection()
    local language_map = {}
    local seen_files = {}

    local function add_language(filepath, language)
        language = language and language:match("^%s*(.-)%s*$")
        if not language or language == "" then return end
        local code = language:gsub("-", "_"):match("^([^_]+)")
        if code and (#code == 2 or #code == 3) and code:match("^%a+$") then
            language = code:lower()
            if iso_ok and type(IsoLanguage.getBCPLanguageTag) == "function" then
                language = IsoLanguage:getBCPLanguageTag(language)
            end
        end
        if not language_map[language] then language_map[language] = {} end
        table.insert(language_map[language], filepath)
    end

    local row_count = 0
    local ok2, err = pcall(function()
        local sql = [[
            SELECT directory, filename, language
            FROM bookinfo
            WHERE in_progress = 0
              AND language IS NOT NULL
              AND language != ''
            ORDER BY language, filename
        ]]
        row_count = for_each_valid_book_row(BookInfoManager.db_conn, sql,
            function(raw_filepath, _filename, result, index)
                add_unseen_file(seen_files, raw_filepath)
                add_language(raw_filepath, result[3] and result[3][index])
            end)
        for _i, book in ipairs(get_kindle_metadata()) do
            if add_unseen_file(seen_files, book.file) then
                add_language(book.file, book.info.language)
            end
        end
    end)

    if not ok2 then
        logger.warn("language query error:", err)
        return {}
    end

    local groups = sorted_groups(language_map, "language", "files")
    save_cached("languages", groups)
    logger.measure("Language groups loaded", (now() - started_at) * 1000,
        "cache=miss", "rows=", row_count, "groups=", #groups)
    return groups
end

-- Returns a sorted list of series groups:
--   { { series="Name", items={ {file="/abs/path", series_index=N}, ... } }, ... }
-- Items within each series are sorted by series_index (then filename as tiebreak).
-- Includes existing books within home_dir and the Kindle virtual library.
function M.getGroupedBySeries()
    local started_at = now()
    if not bimOk then
        logger.warn("BookInfoManager not available")
        return {}
    end
    local cached = get_cached("series")
    if cached then
        logger.measure("Series groups loaded", (now() - started_at) * 1000,
            "cache=hit", "groups=", #cached)
        return cached
    end
    BookInfoManager:openDbConnection()
    local conn = BookInfoManager.db_conn
    local series_map = {}  -- series_name -> { {file, series_index, filename} }
    local seen_files = {}

    local function add_series(filepath, filename, series, series_index)
        if not series or series == "" then return end
        if not series_map[series] then series_map[series] = {} end
        table.insert(series_map[series], {
            file = filepath,
            series_index = tonumber(series_index),
            filename = filename,
        })
    end

    local row_count = 0
    local ok2, err = pcall(function()
        local sql = [[
            SELECT directory, filename, series, series_index
            FROM bookinfo
            WHERE in_progress = 0
              AND series IS NOT NULL
              AND series != ''
            ORDER BY series, series_index
        ]]
        row_count = for_each_valid_book_row(conn, sql, function(raw_filepath, filename, result, index)
            add_unseen_file(seen_files, raw_filepath)
            add_series(raw_filepath, filename, result[3] and result[3][index],
                result[4] and result[4][index])
        end)
        for _i, book in ipairs(get_kindle_metadata()) do
            if add_unseen_file(seen_files, book.file) then
                add_series(book.file, book.file:match("([^/]+)$"), book.info.series,
                    book.info.series_index)
            end
        end
    end)

    if not ok2 then
        logger.warn("query error:", err)
        return {}
    end

    local groups = {}
    for series, items in pairs(series_map) do
        -- Sort by series_index, then by filename as tiebreak
        table.sort(items, function(a, b)
            local ia = a.series_index or 0
            local ib = b.series_index or 0
            if ia ~= ib then return ia < ib end
            return (a.filename or "") < (b.filename or "")
        end)
        table.insert(groups, { series = series, items = items })
    end
    table.sort(groups, function(a, b)
        return a.series < b.series
    end)

    save_cached("series", groups)
    logger.measure("Series groups loaded", (now() - started_at) * 1000,
        "cache=miss", "rows=", row_count, "groups=", #groups)
    return groups
end

local LIGHT_METADATA_COLUMNS = [[
    directory, filename, title, authors, series, series_index, keywords
]]

local function light_metadata_info(result, index)
    return {
        title = result[3] and result[3][index],
        authors = result[4] and result[4][index],
        series = result[5] and result[5][index],
        series_index = tonumber(result[6] and result[6][index]),
        keywords = result[7] and result[7][index],
    }
end

local function put_metadata(metadata, filepath, info)
    metadata[filepath] = info
    metadata[paths.normPath(filepath)] = info
end

local function directory_variants(directory)
    if type(directory) ~= "string" or directory == "" then return nil end
    local function with_trailing_slash(path)
        path = path:gsub("/+$", "")
        return path == "" and "/" or path .. "/"
    end
    local raw = with_trailing_slash(directory)
    local normalized = with_trailing_slash(paths.normPath(raw))
    local legacy = normalized:gsub("^/storage/emulated/0/", "/sdcard/")
    return normalized, raw, legacy
end

local function get_directory_metadata_cache()
    local cache = get_cached("light_metadata_directories")
    if cache then return cache end
    cache = { values = {}, order = {} }
    save_cached("light_metadata_directories", cache)
    return cache
end

local function touch_directory_cache(cache, key)
    for index = #cache.order, 1, -1 do
        if cache.order[index] == key then
            table.remove(cache.order, index)
            break
        end
    end
    cache.order[#cache.order + 1] = key
end

local function cache_directory_metadata(key, metadata)
    local cache = get_directory_metadata_cache()
    cache.values[key] = metadata
    touch_directory_cache(cache, key)
    local limit = MemoryPolicy.limitGroupCache()
        and DIRECTORY_METADATA_CACHE_MAX_CONSTRAINED or DIRECTORY_METADATA_CACHE_MAX
    while #cache.order > limit do
        cache.values[table.remove(cache.order, 1)] = nil
    end
end

local function get_cached_directory_metadata(key)
    local cache = get_directory_metadata_cache()
    local metadata = cache.values[key]
    if metadata then touch_directory_cache(cache, key) end
    return metadata
end

local function load_directory_metadata(directory)
    local key, raw, legacy = directory_variants(directory)
    if not key then return {} end
    local cached = get_cached_directory_metadata(key)
    if cached then return cached end

    BookInfoManager:openDbConnection()
    local metadata = {}
    local home_dir = paths.getHomeDir()
    local stmt
    local ok_query, err = pcall(function()
        stmt = BookInfoManager.db_conn:prepare(([[
            SELECT %s
            FROM bookinfo
            WHERE directory = ? OR directory = ? OR directory = ?
        ]]):format(LIGHT_METADATA_COLUMNS))
        if not stmt then error("failed to prepare directory metadata query") end
        stmt:bind(raw, key, legacy)
        while true do
            local row = stmt:step()
            if not row then break end
            local filepath = row[1] and row[2] and (row[1] .. row[2])
            local normalized = filepath and paths.normPath(filepath)
            if normalized and (not home_dir or paths.isInHomeDir(normalized)) then
                put_metadata(metadata, filepath, {
                    title = row[3],
                    authors = row[4],
                    series = row[5],
                    series_index = tonumber(row[6]),
                    keywords = row[7],
                })
            end
        end
    end)
    if stmt then
        pcall(stmt.clearbind, stmt)
        pcall(stmt.reset, stmt)
        if type(stmt.close) == "function" then pcall(stmt.close, stmt) end
    end
    if not ok_query then
        logger.warn("directory metadata query error:", err)
        return {}
    end
    cache_directory_metadata(key, metadata)
    return metadata
end

-- Lightweight metadata for path-list sorting. With no directory this keeps the
-- existing whole-library result; a directory uses a bounded, parameterized query.
function M.getLightMetadata(directory)
    if not bimOk then return {} end
    if directory ~= nil then return load_directory_metadata(directory) end
    local cached = get_cached("light_metadata")
    if cached then return cached end

    BookInfoManager:openDbConnection()
    local metadata = {}
    local ok_query, err = pcall(function()
        local sql = [[
            SELECT directory, filename, title, authors, series, series_index, keywords
            FROM bookinfo
        ]]
        for_each_valid_book_row(BookInfoManager.db_conn, sql,
            function(filepath, _filename, result, index)
                put_metadata(metadata, filepath, light_metadata_info(result, index))
            end)
    end)
    if not ok_query then
        logger.warn("light metadata query error:", err)
        return {}
    end
    for _i, book in ipairs(get_kindle_metadata()) do
        local normalized = paths.normPath(book.file)
        if not metadata[book.file] and not metadata[normalized] then
            put_metadata(metadata, book.file, book.info)
        end
    end
    save_cached("light_metadata", metadata)
    return metadata
end

function M.groupPathsBySeries(files, metadata)
    local groups, result = {}, {}
    local series_count, ungrouped_count = 0, 0
    for _i, file in ipairs(files) do
        local info = metadata[file]
        local name = info and info.series
        if type(name) == "string" and name ~= "" then
            local group = groups[name]
            if not group then
                group = { series = name, files = {} }
                groups[name] = group
                result[#result + 1] = group
                series_count = series_count + 1
            end
            group.files[#group.files + 1] = file
        else
            result[#result + 1] = file
            ungrouped_count = ungrouped_count + 1
        end
    end
    if series_count == 1 and ungrouped_count == 0 then return files end
    for index, item in ipairs(result) do
        if type(item) == "table" then
            if #item.files == 1 then
                result[index] = item.files[1]
            else
                table.sort(item.files, function(a, b)
                    local a_info, b_info = metadata[a], metadata[b]
                    local a_index = tonumber(a_info and a_info.series_index) or 0
                    local b_index = tonumber(b_info and b_info.series_index) or 0
                    return a_index == b_index and a < b or a_index < b_index
                end)
            end
        end
    end
    return result
end

-- Returns a sorted list of tag groups from the keywords (Calibre tags) column:
--   { { tag="Name", files={"/abs/path", ...} }, ... }
-- Books may appear under multiple tags. Tags are split by comma and trimmed.
-- Includes existing books within home_dir and the Kindle virtual library.
function M.getGroupedByTags()
    local started_at = now()
    if not bimOk then
        logger.warn("BookInfoManager not available")
        return {}
    end
    local cached = get_cached("tags")
    if cached then
        logger.measure("Tag groups loaded", (now() - started_at) * 1000,
            "cache=hit", "groups=", #cached)
        return cached
    end
    BookInfoManager:openDbConnection()
    local conn = BookInfoManager.db_conn
    local tag_map = {}  -- tag_name -> { file_paths }
    local seen_files = {}

    local function add_tags(filepath, keywords)
        if not keywords then return end
        local normalized = keywords:gsub(",", "\n")
        for tag in normalized:gmatch("[^\n]+") do
            local trimmed = tag:match("^%s*(.-)%s*$")
            if trimmed and trimmed ~= "" then
                if not tag_map[trimmed] then tag_map[trimmed] = {} end
                table.insert(tag_map[trimmed], filepath)
            end
        end
    end

    local row_count = 0
    local ok2, err = pcall(function()
        local sql = [[
            SELECT directory, filename, keywords
            FROM bookinfo
            WHERE keywords IS NOT NULL
              AND keywords != ''
            ORDER BY filename
        ]]
        row_count = for_each_valid_book_row(conn, sql, function(raw_filepath, _filename, result, index)
            add_unseen_file(seen_files, raw_filepath)
            add_tags(raw_filepath, result[3] and result[3][index])
        end)
        for _i, book in ipairs(get_kindle_metadata()) do
            if add_unseen_file(seen_files, book.file) then
                add_tags(book.file, book.info.keywords)
            end
        end
    end)


    if not ok2 then
        logger.warn("getGroupedByTags query error:", err)
        return {}
    end

    local groups = sorted_groups(tag_map, "tag", "files")
    save_cached("tags", groups)
    logger.measure("Tag groups loaded", (now() - started_at) * 1000,
        "cache=miss", "rows=", row_count, "groups=", #groups)
    return groups
end

-- Returns the books for one exact Calibre tag. Reuses the cached tag groups so
-- Home widgets and tag tabs do not issue a second database query.
function M.getTagBooks(tag_name)
    if type(tag_name) ~= "string" or tag_name == "" then return {} end
    for _i, group in ipairs(M.getGroupedByTags()) do
        if group.tag == tag_name then
            return group.files or {}
        end
    end
    return {}
end

-- Returns the total number of fully-indexed books in the bookinfo cache,
-- across all directories. Uses a SQL COUNT so no lfs calls are made.
function M.getTotalBookCount()
    if not bimOk then
        logger.warn("BookInfoManager not available")
        return {}
    end
    BookInfoManager:openDbConnection()
    local conn = BookInfoManager.db_conn

    local count = 0
    local ok2, err = pcall(function()
        local row = conn:rowexec("SELECT COUNT(*) FROM bookinfo WHERE in_progress = 0;")
        count = tonumber(row) or 0
    end)
    if not ok2 then
        logger.warn("getTotalBookCount error:", err)
    end
    logger.info("total_book_count=", count)
    return count
end

return M
