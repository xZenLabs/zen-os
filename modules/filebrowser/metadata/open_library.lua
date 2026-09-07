local Http = require("modules/filebrowser/metadata/http")
local ISBN = require("modules/filebrowser/metadata/isbn")
local logger = require("common/zen_logger").new("open_library")
local util = require("util")

local M = {}
local API_HOST = "openlibrary.org"
local API_URL = "https://openlibrary.org"
local COVER_HOST = "covers.openlibrary.org"
local SEARCH_LIMIT = 10
local EDITION_LIMIT = 30
local MAX_QUERY_LENGTH = 512
local BASE_SEARCH_FIELDS = table.concat({
    "key", "title", "author_name", "description", "first_publish_year",
    "subject", "series_name", "series_position",
}, ",")
local EDITION_SEARCH_FIELDS = table.concat({
    "editions", "editions.key", "editions.title", "editions.subtitle",
    "editions.isbn", "editions.publish_date", "editions.publisher",
    "editions.language", "editions.cover_i", "editions.number_of_pages_median",
    "editions.format",
}, ",")

local function trim(value)
    return type(value) == "string" and (value:match("^%s*(.-)%s*$") or "") or ""
end

local function first(values)
    if type(values) == "table" then return values[1] end
    return values
end

local function string_list(values, limit)
    local result, seen = {}, {}
    if type(values) ~= "table" then return result end
    for _i, value in ipairs(values) do
        value = trim(value)
        if value ~= "" and not seen[value] then
            seen[value] = true
            result[#result + 1] = value
            if limit and #result >= limit then break end
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
    local query = 'title:"' .. title .. '"'
    if author ~= "" then query = query .. ' AND author:"' .. author .. '"' end
    return #query <= MAX_QUERY_LENGTH and query or nil
end

local function cover_url(id, size)
    id = tonumber(id)
    if not id or id <= 0 or id ~= math.floor(id) then return "" end
    return "https://" .. COVER_HOST .. "/b/id/" .. id .. "-"
        .. (size or "L") .. ".jpg?default=false"
end

local normalize_edition

local function header_value(headers, wanted)
    wanted = wanted:lower()
    for key, value in pairs(type(headers) == "table" and headers or {}) do
        if type(key) == "string" and key:lower() == wanted then return value end
    end
end

local function redirect_status(status)
    return status == 301 or status == 302 or status == 307 or status == 308
end

local function head(url, host)
    local response, err = Http.request{
        url = url,
        host = host,
        method = "HEAD",
        headers = { ["Accept"] = "image/jpeg" },
    }
    if not response then return nil, err end
    local status = tonumber(response.status)
    if status == 200 then return false end
    if redirect_status(status) then
        return header_value(response.headers, "location") or ""
    end
    if status == 404 then return nil, Http.failure("no_match", status) end
    if status == 429 then return nil, Http.failure("rate_limited", status) end
    if status and status >= 500 then return nil, Http.failure("server", status) end
    return nil, Http.failure("network", status)
end

local function resolved_cover(url)
    local redirect, err = head(url, COVER_HOST)
    if redirect == nil then return nil, nil, err end
    if redirect == false then return url, COVER_HOST end
    local archive_prefix = "https://archive.org/download/"
    if redirect:sub(1, #archive_prefix) ~= archive_prefix then
        return nil, nil, Http.failure("malformed")
    end
    local final, archive_err = head(redirect, "archive.org")
    if final == nil then return nil, nil, archive_err end
    if final == false then return redirect, "archive.org" end
    local host, path = final:match("^https://([^/]+)(/.*)$")
    local view_prefix = "/view_archive.php?archive=/"
    if not host or not host:match("^ia%d+%.us%.archive%.org$")
            or path:sub(1, #view_prefix) ~= view_prefix
            or not path:find("&file=", 1, true) then
        return nil, nil, Http.failure("malformed")
    end
    return final, host
end

local function normalize_work(row, searched_isbn)
    if type(row) ~= "table" then return nil end
    local id, title = trim(row.key), trim(row.title)
    if not id:match("^/works/OL%d+W$") or title == "" then return nil end
    local description = row.description
    if type(description) == "table" then
        description = description.value or description[1]
    end
    local work = {
        id = id,
        title = title,
        authors = string_list(row.author_name),
        series_name = trim(first(row.series_name)),
        series_index = tonumber(first(row.series_position)),
        genres = string_list(row.subject, 20),
        description = trim(description),
        release_year = tonumber(row.first_publish_year),
    }
    local edition_rows = type(row.editions) == "table"
        and type(row.editions.docs) == "table" and row.editions.docs or {}
    local exact = normalize_edition(edition_rows[1], id)
    if searched_isbn and exact
            and (exact.isbn_13 == searched_isbn or exact.isbn_10 == searched_isbn) then
        work.exact_edition = exact
    end
    return work
end

local function language_code(languages)
    local value = first(languages)
    local key = type(value) == "table" and value.key or value
    key = trim(key)
    return key:match("/languages/([%w_%-]+)$") or key
end

local function is_audio(format)
    format = trim(format):lower()
    return format:find("audio", 1, true) ~= nil
        or format:find("mp3", 1, true) ~= nil
        or format:find("compact disc", 1, true) ~= nil
        or format:match("%f[%w]cd%f[%W]") ~= nil
end

normalize_edition = function(row, work_id)
    if type(row) ~= "table" then return nil end
    local id, title = trim(row.key), trim(row.title)
    if not id:match("^/books/OL%d+M$") then return nil end
    local subtitle = trim(row.subtitle)
    if subtitle ~= "" and not title:find(subtitle, 1, true) then
        title = title ~= "" and title .. ": " .. subtitle or subtitle
    end
    local published = trim(first(row.publish_date))
    local format = trim(first(row.physical_format))
    if format == "" then format = trim(first(row.format)) end
    local isbn_10, isbn_13 = "", ""
    for _i, isbn in ipairs(type(row.isbn) == "table" and row.isbn or {}) do
        isbn = ISBN.normalize(isbn)
        if isbn and #isbn == 13 and isbn_13 == "" then isbn_13 = isbn end
        if isbn and #isbn == 10 and isbn_10 == "" then isbn_10 = isbn end
    end
    if isbn_10 == "" then isbn_10 = trim(first(row.isbn_10)) end
    if isbn_13 == "" then isbn_13 = trim(first(row.isbn_13)) end
    local cover_id = first(row.covers) or row.cover_i
    return {
        id = id,
        work_id = work_id,
        title = title,
        isbn_10 = isbn_10,
        isbn_13 = isbn_13,
        language = language_code(row.languages or row.language),
        publisher = trim(first(row.publishers or row.publisher)),
        edition_format = format,
        release_year = tonumber(published:match("(%d%d%d%d)")),
        pages = tonumber(row.number_of_pages or row.number_of_pages_median),
        image_url = cover_url(cover_id),
        preview_image_url = cover_url(cover_id, "M"),
        is_audio = is_audio(format),
    }
end

function M.search(_key, input, transport)
    if type(input) ~= "table" then return nil, Http.failure("malformed") end
    local query, searched_isbn = query_value(input)
    if not query then return nil, Http.failure("malformed") end
    local limit = math.max(1, math.min(100,
        math.floor(tonumber(input.limit) or SEARCH_LIMIT)))
    local function request(search_query, isbn)
        local fields = isbn and BASE_SEARCH_FIELDS .. "," .. EDITION_SEARCH_FIELDS
            or BASE_SEARCH_FIELDS
        local url = API_URL .. "/search.json?q=" .. util.urlEncode(search_query)
            .. "&fields=" .. fields .. "&limit=" .. limit
        local data, err = Http.getJson(url, API_HOST, {
            ["Accept"] = "application/json",
        }, transport)
        if not data then return nil, err end
        if type(data.docs) ~= "table" then return nil, Http.failure("malformed") end
        local works = {}
        for _i, row in ipairs(data.docs) do
            local work = normalize_work(row, isbn)
            if work then works[#works + 1] = work end
        end
        if #works == 0 then return nil, Http.failure("no_match") end
        logger.dbg("search complete works=", #works)
        return works
    end
    local works, err = request(query, searched_isbn)
    if not works and searched_isbn and err.kind == "no_match" then
        local fallback = query_value(input, true)
        if fallback then return request(fallback) end
    end
    return works, err
end

function M.editions(_key, work, transport)
    local work_id = type(work) == "table" and trim(work.id) or ""
    if not work_id:match("^/works/OL%d+W$") then
        return nil, Http.failure("malformed")
    end
    local url = API_URL .. work_id .. "/editions.json?limit=" .. EDITION_LIMIT
    local data, err = Http.getJson(url, API_HOST, {
        ["Accept"] = "application/json",
    }, transport)
    if not data then
        return type(work.exact_edition) == "table" and { work.exact_edition }
            or nil, err
    end
    if type(data.entries) ~= "table" then return nil, Http.failure("malformed") end
    local editions = {}
    for _i, row in ipairs(data.entries) do
        local edition = normalize_edition(row, work_id)
        if edition and (type(work.exact_edition) ~= "table"
                or edition.id ~= work.exact_edition.id) then
            editions[#editions + 1] = edition
        end
    end
    if type(work.exact_edition) == "table" then
        editions[#editions + 1] = work.exact_edition
    end
    table.sort(editions, function(left, right)
        if left.is_audio ~= right.is_audio then return not left.is_audio end
        local left_year = tonumber(left.release_year) or math.huge
        local right_year = tonumber(right.release_year) or math.huge
        if left_year ~= right_year then return left_year < right_year end
        return left.id < right.id
    end)
    if #editions == 0 then return nil, Http.failure("no_match") end
    return editions
end

function M.downloadCover(url, destination, transport)
    if type(url) ~= "string"
            or url:sub(1, #COVER_HOST + 9) ~= "https://" .. COVER_HOST .. "/" then
        return nil, Http.failure("malformed")
    end
    local host = COVER_HOST
    if not transport then
        local resolved, resolved_host, err = resolved_cover(url)
        if not resolved then return nil, err end
        url, host = resolved, resolved_host
    end
    return Http.download(url, destination, host, {
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
        series_name = trim(work.series_name),
        series_index = work.series_index,
        genres = copy_list(work.genres),
        language = trim(edition.language),
        publisher = trim(edition.publisher),
        description = trim(work.description),
        isbn = trim(edition.isbn_13) ~= "" and trim(edition.isbn_13)
            or trim(edition.isbn_10),
    }
end

return M
