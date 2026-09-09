local lfs = require("libs/libkoreader-lfs")
local PresetStore = require("config/preset_store")

local M = {}

local DEFAULT_QUOTES = require("modules/filebrowser/patches/home/quote_list")

local TEMPLATE = [[return {
    -- Add your quotes here, then enable Custom quotes in the Quotes widget settings.
    -- { text = "Quote text", author = "Author" },
    -- { text = "Quote text", author = "Author", title = "Book title" },
    -- "Plain quote without author",
}
]]

local annotation_cache
local quote_state
local hold_current_once = false

local function trim(value)
    if type(value) ~= "string" then return "" end
    return value:match("^%s*(.-)%s*$") or ""
end

local function ensure_dir(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    return lfs.mkdir(path) == true or lfs.attributes(path, "mode") == "directory"
end

local function quotes_path()
    local root = PresetStore.rootDir()
    ensure_dir(root)
    return root .. "/quotes.lua"
end

local function quotes_dir()
    local path = PresetStore.rootDir() .. "/quotes"
    ensure_dir(path)
    return path
end

local function state_store()
    if not quote_state then
        local LuaSettings = require("luasettings")
        quote_state = LuaSettings:open(PresetStore.rootDir() .. "/quote_state.lua")
    end
    return quote_state
end

local function ensure_template(path)
    if lfs.attributes(path, "mode") == "file" then return false end
    local f = io.open(path, "w")
    if not f then return false end
    f:write(TEMPLATE)
    f:close()
    return true
end

local function normalize(raw)
    local src = raw
    if type(raw) == "table" and type(raw.quotes) == "table" then src = raw.quotes end
    if type(src) ~= "table" then return {} end

    local out = {}
    for _i, item in ipairs(src) do
        local text, author, title
        if type(item) == "string" then
            text = item
            author = ""
        elseif type(item) == "table" then
            text = item.text or item[1]
            author = item.author or item[2] or ""
            title = item.title or item[3] or ""
        end
        if type(text) == "string" then
            text = trim(text)
            if text ~= "" then
                author = trim(type(author) == "string" and author or tostring(author or ""))
                title = trim(type(title) == "string" and title or tostring(title or ""))
                local attribution = author
                if title ~= "" then
                    attribution = attribution .. (attribution ~= "" and ",  " or "") .. title
                end
                out[#out + 1] = {
                    text = text,
                    author = author,
                    title = title,
                    attribution = attribution,
                }
            end
        end
    end
    return out
end

local function is_quote_filename(filename)
    return type(filename) == "string" and filename ~= ""
        and not filename:find("/", 1, true)
        and not filename:find("\\", 1, true)
        and filename:sub(-4) == ".lua"
end

local function quote_file_path(filename)
    return filename == "quotes.lua"
        and quotes_path() or quotes_dir() .. "/" .. filename
end

local function sort_filenames(files)
    table.sort(files)
    return files
end

local function selected_custom_files(config)
    local configured = type(config) == "table" and config.custom_files or nil
    if type(configured) ~= "table" then return { "quotes.lua" } end
    local files = {}
    for filename, selected in pairs(configured) do
        if selected == true and is_quote_filename(filename) then
            files[#files + 1] = filename
        end
    end
    return sort_filenames(files)
end

local function load_quote_file(filename)
    if not is_quote_filename(filename) then return {} end
    local ok, raw = pcall(dofile, quote_file_path(filename))
    return ok and normalize(raw) or {}
end

local function book_info(data, path)
    local props = type(data.doc_props) == "table" and data.doc_props or {}
    local filename = path:match("([^/\\]+)$") or path
    local title = trim(props.title)
    local authors = trim(props.authors)
    if title == "" then title = filename:gsub("%.[^.]+$", "") end
    return title, authors
end

-- Per-book annotation cache so a full-library rescan after an annotation
-- edit re-parses only the sidecars that actually changed.  The key is the
-- sidecar path plus its modification time and size, so an entry is reused
-- while the file on disk is byte-identical.  Bounded FIFO.
local book_annotation_cache = {}
local book_annotation_order = {}
local BOOK_ANNOTATION_CACHE_MAX = 4096

local function cache_book_annotations(key, items)
    book_annotation_cache[key] = items
    book_annotation_order[#book_annotation_order + 1] = key
    if #book_annotation_order > BOOK_ANNOTATION_CACHE_MAX then
        local oldest = table.remove(book_annotation_order, 1)
        book_annotation_cache[oldest] = nil
    end
end

-- Extracts one book's annotation quotes from its sidecar.  Uses the light
-- openSettingsFile() instead of DocSettings:open(), which stats up to ten
-- candidate paths before parsing.  Returns an array of quote tables, or nil
-- when the book has no usable sidecar.
local function book_annotations(path, perf)
    perf.annotation_books = perf.annotation_books + 1
    if type(path) ~= "string" or lfs.attributes(path, "mode") ~= "file" then
        return nil
    end
    local DocSettings = require("docsettings")
    local sidecar_file = DocSettings:findSidecarFile(path)
    if not sidecar_file then return nil end
    local attrs = lfs.attributes(sidecar_file)
    local mtime, size = attrs and attrs.modification, attrs and attrs.size
    if not mtime or not size or size <= 0 then return nil end
    local key = sidecar_file .. "\31" .. tostring(mtime) .. "\31" .. tostring(size)
    local cached = book_annotation_cache[key]
    if cached then
        perf.sidecar_cache_hits = perf.sidecar_cache_hits + 1
        return cached
    end
    perf.sidecar_cache_misses = perf.sidecar_cache_misses + 1

    local ok, doc_settings = pcall(DocSettings.openSettingsFile, sidecar_file)
    if not ok or not doc_settings or type(doc_settings.data) ~= "table" then
        return nil
    end

    local data = doc_settings.data
    local title, authors = book_info(data, path)
    local attribution = title
    if authors ~= "" then
        attribution = attribution .. (attribution ~= "" and ",  " or "") .. authors
    end

    local items = {}
    local function add(item, fallback_page)
        if type(item) ~= "table" or not item.drawer then return end
        local text = trim(item.text)
        if text == "" then return end
        items[#items + 1] = {
            text = text,
            author = authors,
            title = title,
            attribution = attribution,
            is_annotation = true,
            filepath = path,
            pos0 = item.pos0,
            page = item.page or item.pageno or tonumber(fallback_page),
        }
    end

    if type(data.annotations) == "table" and #data.annotations > 0 then
        for _i, item in ipairs(data.annotations) do add(item) end
    else
        for page, page_items in pairs(type(data.highlight) == "table" and data.highlight or {}) do
            if type(page_items) == "table" then
                for _i, item in ipairs(page_items) do add(item, page) end
            end
        end
    end

    cache_book_annotations(key, items)
    return items
end

local function append_annotations(quotes, path, seen_quotes, perf)
    local items = book_annotations(path, perf)
    if not items then return end
    for _i, item in ipairs(items) do
        local key = item.filepath .. "\0" .. item.text
        if not seen_quotes[key] then
            seen_quotes[key] = true
            quotes[#quotes + 1] = item
        end
    end
end

local function annotation_quotes(perf)
    local started_at = os.clock()
    if annotation_cache then
        perf.annotation_cache_hits = perf.annotation_cache_hits + 1
        perf.annotation_ms = (os.clock() - started_at) * 1000
        return annotation_cache
    end
    perf.annotation_cache_misses = perf.annotation_cache_misses + 1
    local quotes, seen_books, seen_quotes = {}, {}, {}

    local function add_book(path)
        if type(path) ~= "string" or seen_books[path] then return end
        seen_books[path] = true
        append_annotations(quotes, path, seen_quotes, perf)
    end

    local ReadHistory = require("readhistory")
    for _i, item in ipairs(ReadHistory.hist or {}) do
        add_book(item.file)
    end

    local DataStorage = require("datastorage")
    local db_path = DataStorage:getDataDir() .. "/bookinfo_cache.db"
    if lfs.attributes(db_path, "mode") == "file" then
        local ok_sq, SQ3 = pcall(require, "lua-ljsqlite3/init")
        local ok_db, db
        if ok_sq then ok_db, db = pcall(SQ3.open, db_path) end
        if ok_db and db then
            local ok_stmt, stmt = pcall(function()
                return db:prepare(
                    "SELECT directory, filename FROM bookinfo "
                    .. "WHERE directory IS NOT NULL AND filename IS NOT NULL"
                )
            end)
            if ok_stmt and stmt then
                pcall(function()
                    for row in stmt:nrows() do
                        local separator = row.directory:sub(-1) == "/" and "" or "/"
                        add_book(row.directory .. separator .. row.filename)
                    end
                end)
                pcall(function() stmt:close() end)
            end
            pcall(function() db:close() end)
        end
    end

    table.sort(quotes, function(a, b)
        if a.filepath ~= b.filepath then return a.filepath < b.filepath end
        local a_page, b_page = tonumber(a.page) or 0, tonumber(b.page) or 0
        if a_page ~= b_page then return a_page < b_page end
        return a.text < b.text
    end)
    annotation_cache = quotes
    perf.annotation_ms = (os.clock() - started_at) * 1000
    return quotes
end

local function selected_sources(config)
    local sources = type(config) == "table" and config.sources or nil
    if type(sources) ~= "table" then
        return true, false, false
    end
    local use_defaults = sources.default == true
    local use_custom = sources.custom == true
    local use_annotations = sources.annotations == true
    if not use_defaults and not use_custom and not use_annotations then
        use_defaults = true
    end
    return use_defaults, use_custom, use_annotations
end

function M.getQuotes(config)
    local use_defaults, use_custom, use_annotations = selected_sources(config)
    local perf = {
        annotation_ms = 0,
        annotation_books = 0,
        annotation_cache_hits = 0,
        annotation_cache_misses = 0,
        sidecar_cache_hits = 0,
        sidecar_cache_misses = 0,
    }
    local quotes = {}
    local function append(items)
        for _i, quote in ipairs(items) do quotes[#quotes + 1] = quote end
    end

    if use_defaults then append(DEFAULT_QUOTES) end

    if use_custom then
        ensure_template(quotes_path())
        for _i, filename in ipairs(selected_custom_files(config)) do
            append(load_quote_file(filename))
        end
    end

    if use_annotations then append(annotation_quotes(perf)) end
    if #quotes == 0 then append(DEFAULT_QUOTES) end
    return quotes, perf
end

function M.listFiles(config)
    local root = quotes_dir()
    ensure_template(quotes_path())
    local files, seen = {}, {}
    local function add(filename, allow_empty)
        if seen[filename] or not is_quote_filename(filename)
                or lfs.attributes(quote_file_path(filename), "mode") ~= "file"
                or (not allow_empty and #load_quote_file(filename) == 0) then
            return
        end
        seen[filename] = true
        files[#files + 1] = filename
    end

    add("quotes.lua", true)
    for _i, filename in ipairs(selected_custom_files(config)) do add(filename, true) end
    local ok, iter, dir_obj = pcall(lfs.dir, root)
    if ok then
        for filename in iter, dir_obj do add(filename, false) end
    end
    return sort_filenames(files)
end

local function quotes_signature(quotes)
    local hash = 5381
    for _i, quote in ipairs(quotes) do
        local value = table.concat({
            quote.text or "",
            quote.author or "",
            quote.title or "",
            quote.filepath or "",
            tostring(quote.pos0 or quote.page or ""),
        }, "\0")
        for i = 1, #value do
            hash = (hash * 33 + value:byte(i)) % 2147483647
        end
    end
    return tostring(#quotes) .. ":" .. tostring(hash)
end

local function shuffled_order(count)
    local order = {}
    for i = 1, count do order[i] = i end
    for i = count, 2, -1 do
        local j = math.random(i)
        order[i], order[j] = order[j], order[i]
    end
    return order
end

local function load_deck(quotes)
    local count = #quotes
    if count == 0 then return nil, nil, false end
    local store = state_store()
    local signature = quotes_signature(quotes)
    local raw = store:readSetting("deck_order")
    local position = tonumber(store:readSetting("deck_position"))
    local order, seen = {}, {}
    if type(raw) == "string" then
        for value in raw:gmatch("%d+") do
            local index = tonumber(value)
            if index and index >= 1 and index <= count and not seen[index] then
                seen[index] = true
                order[#order + 1] = index
            end
        end
    end
    local created = store:readSetting("deck_signature") ~= signature
        or #order ~= count or not position or position < 1 or position > count
    if created then
        order = shuffled_order(count)
        position = 1
    end
    return order, position, created, signature
end

local function save_deck(store, order, position, signature)
    store:saveSetting("deck_order", table.concat(order, ","))
    store:saveSetting("deck_position", position)
    store:saveSetting("deck_signature", signature)
    if store.flush then store:flush() end
end

local function advance(order, position)
    position = position + 1
    if position <= #order then return order, position end
    local previous = order[#order]
    order = shuffled_order(#order)
    if #order > 1 and order[1] == previous then
        order[1], order[2] = order[2], order[1]
    end
    return order, 1
end

function M.selectQuote(config, rotation)
    local quotes, perf = M.getQuotes(config)
    local order, position, created, signature = load_deck(quotes)
    if not order then return nil, perf end
    local store = state_store()
    local today = os.date("%Y-%j")
    local stored_day = store:readSetting("quote_day")
    local changed = created or stored_day ~= today

    if hold_current_once then
        hold_current_once = false
    elseif rotation == "refresh" then
        if not created then
            order, position = advance(order, position)
            changed = true
        end
    elseif stored_day ~= today then
        if not created then order, position = advance(order, position) end
    end

    if changed then
        store:saveSetting("quote_day", today)
        save_deck(store, order, position, signature)
        perf.state_writes = 1
    else
        perf.state_writes = 0
    end
    return quotes[order[position]], perf
end

function M.stepQuote(config, delta)
    local quotes = M.getQuotes(config)
    local order, position, _, signature = load_deck(quotes)
    if not order then return nil end
    if delta < 0 then
        position = position - 1
        if position < 1 then position = #order end
    else
        order, position = advance(order, position)
    end
    local store = state_store()
    store:saveSetting("quote_day", os.date("%Y-%j"))
    save_deck(store, order, position, signature)
    hold_current_once = true
    return quotes[order[position]]
end

function M.invalidateAnnotations()
    annotation_cache = nil
end

function M.ensureFile()
    quotes_dir()
    return ensure_template(quotes_path())
end

function M.path()
    return quotes_path()
end

return M
