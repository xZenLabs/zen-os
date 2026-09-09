local json = require("json")
local Http = require("modules/filebrowser/metadata/http")
local ISBN = require("modules/filebrowser/metadata/isbn")
local logger = require("common/zen_logger").new("google_books")
local util = require("util")

local M = {}
local API_HOST = "www.googleapis.com"
local API_URL = "https://www.googleapis.com/books/v1/volumes"
local COVER_HOST = "books.google.com"
local SEARCH_LIMIT = 10
local MAX_QUERY_LENGTH = 512
local SEARCH_FIELDS = "totalItems,items(id,volumeInfo("
    .. "title,subtitle,authors,categories,description,publishedDate,pageCount,"
    .. "language,publisher,industryIdentifiers(type,identifier),"
    .. "imageLinks(extraLarge,large,medium,small,thumbnail,smallThumbnail)))"

local function trim(value)
    return type(value) == "string" and (value:match("^%s*(.-)%s*$") or "") or ""
end

local function string_list(values)
    local result, seen = {}, {}
    if type(values) ~= "table" then return result end
    for _i, value in ipairs(values) do
        value = trim(value)
        if value ~= "" and not seen[value] then
            seen[value] = true
            result[#result + 1] = value
        end
    end
    return result
end

local function copy_list(values)
    local result = {}
    if type(values) == "table" then
        for _i, value in ipairs(values) do result[#result + 1] = value end
    end
    return result
end

local function query_value(input, ignore_isbn)
    local isbn = not ignore_isbn and ISBN.normalize(input)
    if isbn then return "isbn:" .. isbn, isbn end
    local title = trim(input.title):gsub('"', " ")
    local author = trim(input.author):gsub('"', " ")
    if author == "" and type(input.authors) == "table" then
        author = trim(input.authors[1]):gsub('"', " ")
    end
    if title == "" then return nil end
    local query = 'intitle:"' .. title .. '"'
    if author ~= "" then query = query .. ' inauthor:"' .. author .. '"' end
    if #query > MAX_QUERY_LENGTH then return nil end
    return query
end

local function identifier(info, kind)
    local values = type(info.industryIdentifiers) == "table"
        and info.industryIdentifiers or {}
    for _i, entry in ipairs(values) do
        if type(entry) == "table" and entry.type == kind then
            return trim(entry.identifier)
        end
    end
    return ""
end

local function normalized_cover_url(url)
    url = trim(url)
    if url:sub(1, 7) == "http://" then url = "https://" .. url:sub(8) end
    local legacy = "https://" .. COVER_HOST .. "/books?"
    if url:sub(1, #legacy) == legacy then
        url = "https://" .. COVER_HOST .. "/books/content?" .. url:sub(#legacy + 1)
    end
    return url:sub(1, #COVER_HOST + 9) == "https://" .. COVER_HOST .. "/"
        and url or ""
end

local function cover_url(info)
    local links = type(info.imageLinks) == "table" and info.imageLinks or {}
    for _i, key in ipairs({
        "extraLarge", "large", "medium", "small", "thumbnail", "smallThumbnail",
    }) do
        local url = normalized_cover_url(links[key])
        if url ~= "" then return url end
    end
    return ""
end

local function normalize(item, searched_isbn)
    if type(item) ~= "table" or type(item.volumeInfo) ~= "table" then return nil end
    local id, info = trim(item.id), item.volumeInfo
    local title, subtitle = trim(info.title), trim(info.subtitle)
    if id == "" or title == "" then return nil end
    if subtitle ~= "" and not title:find(subtitle, 1, true) then
        title = title .. ": " .. subtitle
    end
    local isbn_13, isbn_10 = identifier(info, "ISBN_13"), identifier(info, "ISBN_10")
    local year = tonumber(trim(info.publishedDate):match("^(%d%d%d%d)"))
    local edition = {
        id = id,
        work_id = id,
        title = title,
        isbn_10 = isbn_10,
        isbn_13 = isbn_13,
        language = trim(info.language),
        publisher = trim(info.publisher),
        edition_format = "",
        release_year = year,
        pages = tonumber(info.pageCount),
        image_url = cover_url(info),
        is_audio = false,
    }
    local work = {
        id = id,
        title = title,
        authors = string_list(info.authors),
        genres = string_list(info.categories),
        description = util.htmlToPlainTextIfHtml(trim(info.description)),
        release_year = year,
        pages = tonumber(info.pageCount),
        image_url = edition.image_url,
        _edition = edition,
    }
    if searched_isbn and (searched_isbn == isbn_13 or searched_isbn == isbn_10) then
        work.exact_edition = edition
    end
    return work
end

local function invalid_key_response(response)
    if type(response) ~= "table" or tonumber(response.status) ~= 400
            or type(response.body) ~= "string" then return false end
    local ok, decoded = pcall(json.decode, response.body)
    if not ok then return false end
    local function contains_reason(value)
        if type(value) ~= "table" then return false end
        for key, child in pairs(value) do
            if key == "reason" and (child == "API_KEY_INVALID" or child == "keyInvalid") then
                return true
            end
            if type(child) == "table" and contains_reason(child) then return true end
        end
        return false
    end
    return contains_reason(decoded)
end

function M.search(key, input, transport)
    if type(input) ~= "table" or trim(key) == "" then
        return nil, Http.failure("unauthorized")
    end
    local query, isbn = query_value(input)
    if not query then return nil, Http.failure("malformed") end
    local limit = math.max(1, math.min(40,
        math.floor(tonumber(input.limit) or SEARCH_LIMIT)))
    local function request(search_query, searched_isbn)
        local url = API_URL .. "?q=" .. util.urlEncode(search_query)
            .. "&maxResults=" .. limit
            .. "&printType=books&fields=" .. util.urlEncode(SEARCH_FIELDS)
            .. "&prettyPrint=false&key=" .. util.urlEncode(trim(key))
        local response, err = Http.get(url, API_HOST, {
            ["Accept"] = "application/json",
        }, transport, 2)
        if not response then return nil, err end
        if invalid_key_response(response) then
            return nil, Http.failure("unauthorized", 400)
        end
        local data
        data, err = Http.decodeJson(response)
        if not data then return nil, err end
        if type(data.items) ~= "table" then
            return nil, tonumber(data.totalItems) == 0
                and Http.failure("no_match") or Http.failure("malformed")
        end
        local works = {}
        for _i, item in ipairs(data.items) do
            local work = normalize(item, searched_isbn)
            if work then works[#works + 1] = work end
        end
        if #works == 0 then return nil, Http.failure("no_match") end
        logger.dbg("search complete works=", #works)
        return works
    end
    local works, err = request(query, isbn)
    if not works and isbn and err.kind == "no_match" then
        local fallback = query_value(input, true)
        if fallback then return request(fallback) end
    end
    return works, err
end

function M.editions(_key, work)
    if type(work) ~= "table" or type(work._edition) ~= "table" then
        return nil, Http.failure("malformed")
    end
    return { work._edition }
end

function M.downloadCover(url, destination, transport)
    url = normalized_cover_url(url)
    if url == "" then
        return nil, Http.failure("malformed")
    end
    return Http.download(url, destination, COVER_HOST, {
        ["Accept"] = "image/jpeg, image/png, image/webp, image/gif",
    }, transport)
end

function M.draft(work, edition)
    if type(work) ~= "table" or type(edition) ~= "table" then
        return nil, Http.failure("malformed")
    end
    return {
        title = trim(edition.title) ~= "" and trim(edition.title) or trim(work.title),
        authors = copy_list(work.authors),
        series_name = "",
        genres = copy_list(work.genres),
        language = trim(edition.language),
        publisher = trim(edition.publisher),
        description = trim(work.description),
        isbn = trim(edition.isbn_13) ~= "" and trim(edition.isbn_13)
            or trim(edition.isbn_10),
    }
end

return M
