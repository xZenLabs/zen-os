local json = require("json")
local logger = require("common/zen_logger").new("hardcover")
local Http = require("modules/filebrowser/metadata/http")
local isbn_value = require("modules/filebrowser/metadata/isbn").normalize

local M = {}

local API_URL = "https://api.hardcover.app/v1/graphql"
local API_HOST = "api.hardcover.app"
local COVER_HOST = "assets.hardcover.app"
local SEARCH_LIMIT = 10
local EDITION_LIMIT = 30
local MAX_QUERY_LENGTH = 512

local SEARCH_QUERY = [[
query ZenMetadataSearch($query: String!, $page: Int!, $perPage: Int!) {
  search(query: $query, query_type: "Book", page: $page, per_page: $perPage) {
    ids
    results
  }
}
]]

local ISBN_QUERY = [[
query ZenMetadataISBN($isbn: String!, $limit: Int!) {
  editions(
    where: {
      _or: [
        { isbn_10: { _eq: $isbn } }
        { isbn_13: { _eq: $isbn } }
      ]
    }
    order_by: { users_count: desc_nulls_last }
    limit: $limit
  ) {
    id
    book_id
    title
    isbn_10
    isbn_13
    edition_format
    physical_format
    reading_format_id
    pages
    release_date
    release_year
    users_count
    cached_image
    image { url width height }
    language { code2 code3 language }
    publisher { name }
    book {
      id
      title
      release_year
      contributions {
        contribution
        author { name }
      }
      book_series(order_by: { featured: desc }, limit: 1) {
        featured
        position
        series { name }
      }
    }
  }
}
]]

local EDITIONS_QUERY = [[
query ZenMetadataEditions($bookId: Int!, $limit: Int!) {
  book: books_by_pk(id: $bookId) {
    id
    title
    description
    release_year
    cached_tags(path: "Genre")
    contributions {
      contribution
      author { name }
    }
    book_series(order_by: { featured: desc }, limit: 1) {
      featured
      position
      series { name }
    }
  }
  editions(
    where: {
      book_id: { _eq: $bookId }
    }
    order_by: { users_count: desc_nulls_last }
    limit: $limit
  ) {
    id
    book_id
    title
    isbn_10
    isbn_13
    edition_format
    physical_format
    reading_format_id
    pages
    release_date
    release_year
    users_count
    cached_image
    image { url width height }
    language { code2 code3 language }
    publisher { name }
  }
}
]]

local READING_FORMATS = {
    [1] = "Physical Book",
    [2] = "Audiobook",
    [4] = "E-Book",
}

local failure = Http.failure

local function trim(value)
    if type(value) ~= "string" then return "" end
    return value:match("^%s*(.-)%s*$") or ""
end

local function token_value(token)
    token = trim(token)
    if token:sub(1, 7):lower() == "bearer " then
        token = trim(token:sub(8))
    end
    if token == "" then return nil end
    return token
end

local function default_transport(token, query, variables)
    local ok_payload, payload = pcall(json.encode, {
        query = query,
        variables = variables,
    })
    if not ok_payload then return nil, failure("malformed") end
    return Http.request{
        url = API_URL,
        host = API_HOST,
        method = "POST",
        headers = {
            ["Accept"] = "application/json",
            ["Authorization"] = "Bearer " .. token,
            ["Content-Type"] = "application/json",
        },
        body = payload,
    }
end

local function valid_cover_url(url)
    return type(url) == "string"
        and url:match("^https://assets%.hardcover%.app/[^%s]+$") ~= nil
end

local function image_url(row)
    local image = type(row.image) == "table" and row.image or row.cached_image
    local url = type(image) == "table" and trim(image.url) or ""
    return valid_cover_url(url) and url or ""
end

local function decode_response(response)
    local decoded, err = Http.decodeJson(response)
    if not decoded then return nil, err end
    if decoded.errors ~= nil or type(decoded.data) ~= "table" then
        return nil, failure("malformed", tonumber(response.status))
    end
    return decoded.data
end

local function request(token, query, variables, transport)
    local operation = query:match("query%s+([%w_]+)") or "unknown"
    token = token_value(token)
    if not token then return nil, failure("unauthorized") end
    if transport ~= nil and type(transport) ~= "function" then
        return nil, failure("malformed")
    end

    logger.dbg("request operation=", operation)
    local ok, response, err = pcall(transport or default_transport, token, query, variables)
    if not ok then
        logger.warn("transport crashed operation=", operation)
        return nil, failure("network")
    end
    if not response then
        err = Http.transportFailure(err)
        logger.warn("transport failed operation=", operation,
            " kind=", err.kind, " status=", tostring(err.status))
        return nil, err
    end
    local data, decode_err = decode_response(response)
    if not data then
        logger.warn("response rejected operation=", operation,
            " kind=", decode_err.kind, " status=", tostring(decode_err.status))
        return nil, decode_err
    end
    logger.dbg("request complete operation=", operation)
    return data
end

local function string_list(values, field)
    local result, seen = {}, {}
    if type(values) == "string" then values = { values } end
    if type(values) ~= "table" then return result end
    for _i, value in ipairs(values) do
        if type(value) == "table" then
            value = field and value[field] or value.name or value.tag
        end
        value = trim(value)
        if value ~= "" and not seen[value] then
            seen[value] = true
            result[#result + 1] = value
        end
    end
    return result
end

local function authors(contributions)
    local result, seen = {}, {}
    if type(contributions) ~= "table" then return result end
    for _i, contribution in ipairs(contributions) do
        if type(contribution) == "table" then
            local role = trim(contribution.contribution):lower()
            local author = contribution.author
            local name = type(author) == "table" and author.name or author
            name = trim(name)
            if (role == "" or role == "author") and name ~= "" and not seen[name] then
                seen[name] = true
                result[#result + 1] = name
            end
        end
    end
    return result
end

local function series(book_series)
    if type(book_series) ~= "table" then return nil, nil end
    local selected = book_series[1]
    for _i, entry in ipairs(book_series) do
        if type(entry) == "table" and entry.featured == true then
            selected = entry
            break
        end
    end
    if type(selected) ~= "table" then return nil, nil end
    local name = type(selected.series) == "table" and trim(selected.series.name) or ""
    return name ~= "" and name or nil, tonumber(selected.position)
end

local function normalize_work(row)
    if type(row) ~= "table" then return nil end
    local id = tonumber(row.id)
    local title = trim(row.title)
    if not id or id <= 0 or title == "" then return nil end
    local series_name, series_index = series(row.book_series)
    return {
        id = id,
        title = title,
        authors = authors(row.contributions),
        series_name = series_name,
        series_index = series_index,
        genres = string_list(row.cached_tags, "tag"),
        description = trim(row.description),
        release_year = tonumber(row.release_year),
    }
end

local function normalize_search_work(row, result_id)
    if type(row) ~= "table" then return nil end
    local id = tonumber(result_id)
    local title = trim(row.title)
    if not id or id <= 0 or title == "" then return nil end
    local series_names = string_list(row.series_names)

    return {
        id = id,
        title = title,
        authors = string_list(row.author_names),
        series_name = series_names[1],
        series_index = tonumber(row.featured_series_position),
        release_year = tonumber(row.release_year),
        image_url = image_url(row),
    }
end

local function search_results(search)
    if type(search) ~= "table" or type(search.ids) ~= "table"
            or type(search.results) ~= "table" then return nil end
    local works, seen = {}, {}
    for index, row in ipairs(search.results) do
        local work = normalize_search_work(row, search.ids[index])
        if work and not seen[work.id] then
            seen[work.id] = true
            works[#works + 1] = work
        end
    end
    return works
end

local function search_text(input)
    local title = trim(input.title)
    local author = trim(input.author)
    if author == "" and type(input.authors) == "table" then
        author = trim(input.authors[1])
    end
    if title == "" then return nil end
    local value = author == "" and title or title .. " " .. author
    if #value > MAX_QUERY_LENGTH then return nil end
    return value
end

local normalize_edition

local function is_audio_edition(row)
    if type(row) ~= "table" then return false end
    if tonumber(row.reading_format_id) == 2 then return true end
    local format = (trim(row.edition_format) .. " " .. trim(row.physical_format)):lower()
    return format:find("audio", 1, true) ~= nil
        or format:find("compact disc", 1, true) ~= nil
        or format:match("%f[%w]cd%f[%W]") ~= nil
end

local function prioritize_editions(editions)
    table.sort(editions, function(left, right)
        local left_audio = is_audio_edition(left)
        local right_audio = is_audio_edition(right)
        if left_audio ~= right_audio then return not left_audio end
        local left_count = tonumber(left.users_count) or -1
        local right_count = tonumber(right.users_count) or -1
        if left_count ~= right_count then return left_count > right_count end
        return (tonumber(left.id) or math.huge) < (tonumber(right.id) or math.huge)
    end)
end

function M.search(token, input, transport)
    if type(input) ~= "table" then return nil, failure("malformed") end
    local isbn = isbn_value(input)
    logger.dbg("search start isbn=", isbn and "yes" or "no")
    if isbn then
        local data, err = request(token, ISBN_QUERY, {
            isbn = isbn,
            limit = SEARCH_LIMIT,
        }, transport)
        if not data then return nil, err end
        if type(data.editions) ~= "table" then return nil, failure("malformed") end
        prioritize_editions(data.editions)
        local print_editions = {}
        for _i, row in ipairs(data.editions) do
            if not is_audio_edition(row) then
                print_editions[#print_editions + 1] = row
            end
        end
        if #data.editions > 0 and #print_editions == 0 then
            logger.dbg("ISBN match was audio-only; falling back to title search")
        end
        local works, seen = {}, {}
        for _i, row in ipairs(print_editions) do
            local work = normalize_work(row.book)
            local edition = normalize_edition(row)
            if work and edition and work.id == edition.work_id then
                if not seen[work.id] then
                    seen[work.id] = work
                    work.exact_edition = edition
                    works[#works + 1] = work
                end
            end
        end
        if #works > 0 then
            logger.dbg("ISBN search complete works=", #works)
            return works
        end
    end

    local query = search_text(input)
    if not query then
        return nil, failure(isbn and "no_match" or "malformed")
    end
    local limit = math.max(1, math.min(25, math.floor(tonumber(input.limit) or SEARCH_LIMIT)))
    local data, err = request(token, SEARCH_QUERY, {
        query = query,
        page = 1,
        perPage = limit,
    }, transport)
    if not data then return nil, err end
    if type(data.search) ~= "table" or type(data.search.ids) ~= "table" then
        return nil, failure("malformed")
    end
    if #data.search.ids == 0 then return nil, failure("no_match") end
    local works = search_results(data.search)
    if not works then return nil, failure("malformed") end
    if #works == 0 then return nil, failure("no_match") end
    logger.dbg("title search complete works=", #works)
    return works
end

local function language_code(language)
    if type(language) ~= "table" then return "" end
    for _i, key in ipairs({ "code2", "code3", "language" }) do
        local value = trim(language[key])
        if value ~= "" then return value end
    end
    return ""
end

normalize_edition = function(row)
    if type(row) ~= "table" then return nil end
    local id, work_id = tonumber(row.id), tonumber(row.book_id)
    if not id or not work_id then return nil end
    local publisher = type(row.publisher) == "table" and trim(row.publisher.name) or ""
    local format = trim(row.edition_format)
    if format == "" then format = trim(row.physical_format) end
    if format == "" then format = READING_FORMATS[tonumber(row.reading_format_id)] or "" end
    local release_year = tonumber(row.release_year)
    if not release_year and type(row.release_date) == "string" then
        release_year = tonumber(row.release_date:match("^(%d%d%d%d)"))
    end
    return {
        id = id,
        work_id = work_id,
        title = trim(row.title),
        isbn_10 = trim(row.isbn_10),
        isbn_13 = trim(row.isbn_13),
        language = language_code(row.language),
        publisher = publisher,
        edition_format = format,
        release_year = release_year,
        pages = tonumber(row.pages),
        users_count = tonumber(row.users_count),
        image_url = image_url(row),
        is_audio = is_audio_edition(row),
    }
end

function M.editions(token, work_or_id, transport)
    local work_id = tonumber(type(work_or_id) == "table" and work_or_id.id or work_or_id)
    if not work_id or work_id <= 0 or work_id ~= math.floor(work_id) then
        return nil, failure("malformed")
    end
    local data, err = request(token, EDITIONS_QUERY, {
        bookId = work_id,
        limit = EDITION_LIMIT,
    }, transport)
    if not data then return nil, err end
    if type(data.editions) ~= "table" then return nil, failure("malformed") end
    if type(work_or_id) == "table" then
        local work = normalize_work(data.book)
        if not work or work.id ~= work_id then return nil, failure("malformed") end
        work_or_id.series_name = work.series_name
        work_or_id.series_index = work.series_index
        for key, value in pairs(work) do work_or_id[key] = value end
    end
    prioritize_editions(data.editions)

    local editions = {}
    for _i, row in ipairs(data.editions) do
        local edition = normalize_edition(row)
        if edition then editions[#editions + 1] = edition end
    end
    if #editions == 0 then return nil, failure("no_match") end
    logger.dbg("edition lookup complete work_id=", work_id, " editions=", #editions)
    return editions
end

function M.downloadCover(url, destination, transport)
    if not valid_cover_url(url) or type(destination) ~= "string" or destination == ""
            or (transport ~= nil and type(transport) ~= "function") then
        return nil, failure("malformed")
    end
    logger.dbg("cover download start")
    return Http.download(url, destination, COVER_HOST, {
        ["Accept"] = "image/jpeg, image/png, image/webp, image/gif",
    }, transport)
end

local function copy_list(values)
    local result = {}
    if type(values) == "table" then
        for _i, value in ipairs(values) do result[#result + 1] = value end
    end
    return result
end

function M.draft(work, edition)
    if type(work) ~= "table" or (edition ~= nil and type(edition) ~= "table") then
        return nil, failure("malformed")
    end
    edition = edition or {}
    local title = trim(edition.title)
    if title == "" then title = trim(work.title) end
    return {
        title = title,
        authors = copy_list(work.authors),
        series_name = trim(work.series_name),
        series_index = work.series_index,
        genres = copy_list(work.genres),
        language = trim(edition.language),
        publisher = trim(edition.publisher),
        description = trim(work.description),
        isbn = trim(edition.isbn_13) ~= "" and trim(edition.isbn_13) or trim(edition.isbn_10),
    }
end

return M
