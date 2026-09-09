local JSON = require("json")
local util = require("util")

local function response(data, status, headers)
    return {
        status = status or 200,
        headers = headers or {},
        body = type(data) == "string" and data or JSON.encode(data),
    }
end

describe("Google Books metadata client", function()
    local GoogleBooks
    local original_sleep

    before_each(function()
        ZenSpec.unload("modules/filebrowser/metadata/google_books")
        GoogleBooks = require("modules/filebrowser/metadata/google_books")
    end)

    after_each(function()
        if original_sleep then require("socket").sleep = original_sleep end
        original_sleep = nil
    end)

    it("builds a title query and normalizes a volume and draft", function()
        local calls, requested_url, requested_headers = 0
        local transport = function(url, headers)
            calls = calls + 1
            requested_url, requested_headers = url, headers
            return response({ items = {
                {
                    id = "volume-1",
                    volumeInfo = {
                        title = " Dune ",
                        authors = { "Frank Herbert", "Frank Herbert", "" },
                        categories = { "Science Fiction", "Adventure" },
                        description = "Fear<br>is the mind-killer &amp; teacher",
                        publishedDate = "1965-08-01",
                        pageCount = 412,
                        language = "en",
                        publisher = "Ace",
                        industryIdentifiers = {
                            { type = "ISBN_10", identifier = "0441172717" },
                            { type = "ISBN_13", identifier = "9780441172719" },
                        },
                        imageLinks = {
                            extraLarge = "https://books.google.com.evil/cover.jpg",
                            thumbnail = "http://books.google.com/books/content?id=volume-1",
                        },
                    },
                },
                { id = "", volumeInfo = { title = "Ignored" } },
            } })
        end

        local works = assert(GoogleBooks.search("api key", {
            title = "Dune",
            authors = { "Frank Herbert" },
            limit = 99,
        }, transport))

        assert.are.equal(1, #works)
        local work = works[1]
        assert.are.equal("Dune", work.title)
        assert.are.same({ "Frank Herbert" }, work.authors)
        assert.are.same({ "Science Fiction", "Adventure" }, work.genres)
        assert.are.equal("Fear\nis the mind-killer & teacher", work.description)
        assert.are.equal(1965, work.release_year)
        assert.are.equal(412, work.pages)
        assert.are.equal(
            "https://books.google.com/books/content?id=volume-1", work.image_url)

        local query = util.urlEncode('intitle:"Dune" inauthor:"Frank Herbert"')
        assert.is_truthy(requested_url:find("?q=" .. query, 1, true))
        assert.is_truthy(requested_url:find("&maxResults=40", 1, true))
        local fields = "totalItems,items(id,volumeInfo("
            .. "title,subtitle,authors,categories,description,publishedDate,pageCount,"
            .. "language,publisher,industryIdentifiers(type,identifier),"
            .. "imageLinks(extraLarge,large,medium,small,thumbnail,smallThumbnail)))"
        assert.is_truthy(requested_url:find(
            "&fields=" .. util.urlEncode(fields), 1, true))
        assert.is_truthy(requested_url:find("&prettyPrint=false", 1, true))
        assert.is_nil(requested_url:find("projection=", 1, true))
        assert.is_truthy(requested_url:find("&key=" .. util.urlEncode("api key"), 1, true))
        assert.are.equal("application/json", requested_headers.Accept)
        assert.are.equal(1, calls)

        local edition = assert(GoogleBooks.editions(nil, work))[1]
        assert.are.equal("volume-1", edition.id)
        assert.are.equal("0441172717", edition.isbn_10)
        assert.are.equal("9780441172719", edition.isbn_13)
        assert.are.equal("Ace", edition.publisher)
        assert.are.equal("en", edition.language)

        local draft = assert(GoogleBooks.draft(work, edition))
        assert.are.equal("Dune", draft.title)
        assert.are.same({ "Frank Herbert" }, draft.authors)
        assert.are.same({ "Science Fiction", "Adventure" }, draft.genres)
        assert.are.equal("9780441172719", draft.isbn)
        draft.authors[1] = "Changed"
        draft.genres[1] = "Changed"
        assert.are.equal("Frank Herbert", work.authors[1])
        assert.are.equal("Science Fiction", work.genres[1])
    end)

    it("uses a normalized ISBN query and marks the exact edition", function()
        local requested_url
        local works = assert(GoogleBooks.search("key", {
            title = "Wrong title",
            isbn = "978-0-441-17271-9",
        }, function(url)
            requested_url = url
            return response({ items = {{
                id = "volume-1",
                volumeInfo = {
                    title = "Dune",
                    industryIdentifiers = {
                        { type = "ISBN_13", identifier = "9780441172719" },
                    },
                },
            }} })
        end))

        assert.is_truthy(requested_url:find(
            "?q=" .. util.urlEncode("isbn:9780441172719"), 1, true))
        assert.are.equal(works[1]._edition, works[1].exact_edition)
    end)

    it("falls back to title search after an ISBN miss", function()
        local calls = 0
        local works = assert(GoogleBooks.search("key", {
            title = "Dune",
            authors = { "Frank Herbert" },
            isbn = "9780441172719",
        }, function(url)
            calls = calls + 1
            if calls == 1 then
                assert.is_truthy(url:find(
                    "?q=" .. util.urlEncode("isbn:9780441172719"), 1, true))
                return response({ totalItems = 0 })
            end
            assert.is_truthy(url:find("?q=" .. util.urlEncode(
                'intitle:"Dune" inauthor:"Frank Herbert"'), 1, true))
            return response({ items = {{
                id = "volume-1",
                volumeInfo = { title = "Dune", authors = { "Frank Herbert" } },
            }} })
        end))

        assert.are.equal(2, calls)
        assert.are.equal("Dune", works[1].title)
        assert.is_nil(works[1].exact_edition)
    end)

    it("retries transient server responses three total attempts", function()
        local socket = require("socket")
        original_sleep = socket.sleep
        local slept, calls = 0, 0
        socket.sleep = function(seconds) slept = slept + seconds end
        local works = assert(GoogleBooks.search("key", { title = "Dune" }, function()
            calls = calls + 1
            if calls == 1 then return response({}, 502) end
            if calls == 2 then return response({}, 503) end
            return response({ items = {{
                id = "volume-1",
                volumeInfo = { title = "Dune" },
            }} })
        end))

        assert.are.equal(2, slept)
        assert.are.equal(3, calls)
        assert.are.equal("Dune", works[1].title)
    end)

    it("maps lookup errors without calling transport for invalid credentials", function()
        local called = false
        local works, err = GoogleBooks.search("", { title = "Dune" }, function()
            called = true
        end)
        assert.is_nil(works)
        assert.are.equal("unauthorized", err.kind)
        assert.is_false(called)

        works, err = GoogleBooks.search("key", { title = "Dune" }, function()
            return response({ totalItems = 0 })
        end)
        assert.is_nil(works)
        assert.are.equal("no_match", err.kind)

        works, err = GoogleBooks.search("key", { title = "Dune" }, function()
            return response({}, 429, { ["Retry-After"] = "7" })
        end)
        assert.is_nil(works)
        assert.are.equal("rate_limited", err.kind)
        assert.are.equal(429, err.status)
        assert.are.equal(7, err.retry_after)

        works, err = GoogleBooks.search("bad-key", { title = "Dune" }, function()
            return response({ error = { details = {{ reason = "API_KEY_INVALID" }} } }, 400)
        end)
        assert.is_nil(works)
        assert.are.equal("unauthorized", err.kind)
    end)

    it("downloads covers only from the Google Books cover host", function()
        local calls = 0
        local legacy_url = "https://books.google.com/books?id=volume-1"
        local canonical_url = "https://books.google.com/books/content?id=volume-1"
        local path = assert(GoogleBooks.downloadCover(legacy_url, "/tmp/google-cover.jpg",
            function(received_url, destination, host, headers)
                calls = calls + 1
                assert.are.equal(canonical_url, received_url)
                assert.are.equal("/tmp/google-cover.jpg", destination)
                assert.are.equal("books.google.com", host)
                assert.is_truthy(headers.Accept:find("image/jpeg", 1, true))
                return destination
            end))
        assert.are.equal("/tmp/google-cover.jpg", path)

        local rejected, err = GoogleBooks.downloadCover(
            "https://books.google.com.evil/cover.jpg", "/tmp/evil.jpg", function()
                calls = calls + 1
            end)
        assert.is_nil(rejected)
        assert.are.equal("malformed", err.kind)
        assert.are.equal(1, calls)
    end)
end)
