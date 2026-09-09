local JSON = require("json")
local util = require("util")

local function response(data, status, headers)
    return {
        status = status or 200,
        headers = headers or {},
        body = type(data) == "string" and data or JSON.encode(data),
    }
end

describe("Open Library metadata client", function()
    local OpenLibrary

    before_each(function()
        ZenSpec.unload("modules/filebrowser/metadata/open_library")
        OpenLibrary = require("modules/filebrowser/metadata/open_library")
    end)

    it("builds title and ISBN queries and normalizes works", function()
        local requested_url
        local works = assert(OpenLibrary.search(nil, {
            title = "Dune",
            authors = { "Frank Herbert" },
            limit = 150,
        }, function(url)
            requested_url = url
            return response({ docs = {
                {
                    key = "/works/OL893415W",
                    title = " Dune ",
                    author_name = { "Frank Herbert", "Frank Herbert" },
                    description = "A beginning is the time for care.",
                    first_publish_year = 1965,
                    subject = { "Science Fiction", "Adventure" },
                    series_name = { "Dune" },
                    series_position = { "1" },
                },
                { key = "/books/OL1M", title = "Ignored" },
            } })
        end))

        local query = util.urlEncode('title:"Dune" AND author:"Frank Herbert"')
        assert.is_truthy(requested_url:find("/search.json?q=" .. query, 1, true))
        assert.is_truthy(requested_url:find("&limit=100", 1, true))
        assert.is_truthy(requested_url:find("&fields=key,title,author_name", 1, true))
        assert.is_nil(requested_url:find("editions", 1, true))
        assert.are.equal(1, #works)
        assert.are.equal("/works/OL893415W", works[1].id)
        assert.are.equal("Dune", works[1].title)
        assert.are.same({ "Frank Herbert" }, works[1].authors)
        assert.are.equal("Dune", works[1].series_name)
        assert.are.equal(1, works[1].series_index)
        assert.are.same({ "Science Fiction", "Adventure" }, works[1].genres)
        assert.are.equal("A beginning is the time for care.", works[1].description)
        assert.is_nil(works[1].image_url)

        local exact_works = assert(OpenLibrary.search(nil, {
            title = "Ignored",
            isbn = "978-0-441-17271-9",
        }, function(url)
            requested_url = url
            return response({ docs = {{
                key = "/works/OL893415W",
                title = "Dune",
                editions = { docs = {{
                    key = "/books/OL2M",
                    title = "Dune Paperback",
                    isbn = { "9780441172719" },
                    publish_date = { "2005" },
                    publisher = { "Ace" },
                    language = { "eng" },
                    cover_i = 200,
                    format = { "paperback" },
                }} },
            }} })
        end))
        assert.is_truthy(requested_url:find(
            "/search.json?q=" .. util.urlEncode("isbn:9780441172719"), 1, true))
        assert.is_truthy(requested_url:find("editions.key", 1, true))
        assert.is_truthy(requested_url:find("editions.format", 1, true))
        assert.is_truthy(requested_url:find(
            "editions.number_of_pages_median", 1, true))
        assert.are.equal("/books/OL2M", exact_works[1].exact_edition.id)
        assert.are.equal("9780441172719", exact_works[1].exact_edition.isbn_13)
        assert.are.equal("eng", exact_works[1].exact_edition.language)
        assert.are.equal("paperback", exact_works[1].exact_edition.edition_format)

        local fallback = assert(OpenLibrary.editions(nil, exact_works[1], function()
            return response({}, 503)
        end))
        assert.are.equal(1, #fallback)
        assert.are.equal("/books/OL2M", fallback[1].id)
    end)

    it("falls back to title search after an ISBN miss", function()
        local calls = 0
        local works = assert(OpenLibrary.search(nil, {
            title = "Dune",
            authors = { "Frank Herbert" },
            isbn = "9780441172719",
        }, function(url)
            calls = calls + 1
            if calls == 1 then
                assert.is_truthy(url:find("/search.json?q="
                    .. util.urlEncode("isbn:9780441172719"), 1, true))
                assert.is_truthy(url:find("editions.key", 1, true))
                return response({ docs = {} })
            end
            assert.is_truthy(url:find("/search.json?q=" .. util.urlEncode(
                'title:"Dune" AND author:"Frank Herbert"'), 1, true))
            assert.is_nil(url:find("editions", 1, true))
            return response({ docs = {{
                key = "/works/OL893415W",
                title = "Dune",
                author_name = { "Frank Herbert" },
            }} })
        end))

        assert.are.equal(2, calls)
        assert.are.equal("Dune", works[1].title)
        assert.is_nil(works[1].exact_edition)
    end)

    it("parses and ranks work editions", function()
        local requested_url
        local editions = assert(OpenLibrary.editions(nil, {
            id = "/works/OL893415W",
            exact_edition = {
                id = "/books/OL4M",
                release_year = 2024,
                edition_format = "Audio CD",
                is_audio = true,
            },
        }, function(url)
            requested_url = url
            return response({ entries = {
                {
                    key = "/books/OL3M",
                    title = "Dune Audio",
                    physical_format = "Audio CD",
                    publish_date = "2020",
                    covers = { 300 },
                },
                {
                    key = "/books/OL2M",
                    title = "Dune Paperback",
                    physical_format = "Paperback",
                    publish_date = "2005-08-02",
                    isbn_13 = { "9780441013593" },
                    languages = { { key = "/languages/eng" } },
                    publishers = { "Ace" },
                    number_of_pages = 535,
                    covers = { 200 },
                },
                {
                    key = "/books/OL1M",
                    title = "",
                    physical_format = "Hardcover",
                    publish_date = "June 1965",
                    isbn_10 = { "0441172717" },
                    covers = { 100 },
                },
                {
                    key = "/books/OL5M",
                    title = "Dune MP3",
                    physical_format = "MP3",
                    publish_date = "2025",
                },
                { key = "/works/OL1W", title = "Ignored" },
            } })
        end))

        assert.are.equal(
            "https://openlibrary.org/works/OL893415W/editions.json?limit=30",
            requested_url)
        assert.are.equal(5, #editions)
        assert.are.equal("/books/OL1M", editions[1].id)
        assert.are.equal(1965, editions[1].release_year)
        assert.is_false(editions[1].is_audio)
        assert.are.equal("/books/OL2M", editions[2].id)
        assert.are.equal("9780441013593", editions[2].isbn_13)
        assert.are.equal("eng", editions[2].language)
        assert.are.equal("Ace", editions[2].publisher)
        assert.are.equal(535, editions[2].pages)
        assert.are.equal(
            "https://covers.openlibrary.org/b/id/200-L.jpg?default=false",
            editions[2].image_url)
        assert.are.equal(
            "https://covers.openlibrary.org/b/id/200-M.jpg?default=false",
            editions[2].preview_image_url)
        assert.is_true(editions[3].is_audio)
        assert.are.equal("/books/OL4M", editions[4].id)
        assert.is_true(editions[4].is_audio)
        assert.are.equal("/books/OL5M", editions[5].id)
        assert.is_true(editions[5].is_audio)

        local work = {
            title = "Dune",
            authors = { "Frank Herbert" },
            series_name = "Dune",
            series_index = 1,
            genres = { "Science Fiction" },
            description = "Spice.",
        }
        local draft = assert(OpenLibrary.draft(work, editions[2]))
        assert.are.equal("Dune Paperback", draft.title)
        assert.are.same({ "Frank Herbert" }, draft.authors)
        assert.are.equal("Dune", draft.series_name)
        assert.are.equal(1, draft.series_index)
        assert.are.equal("9780441013593", draft.isbn)
        draft.authors[1] = "Changed"
        draft.genres[1] = "Changed"
        assert.are.equal("Frank Herbert", work.authors[1])
        assert.are.equal("Science Fiction", work.genres[1])
    end)

    it("maps lookup failures and rejects malformed work IDs", function()
        local called = false
        local editions, err = OpenLibrary.editions(nil, { id = "/books/OL1M" }, function()
            called = true
        end)
        assert.is_nil(editions)
        assert.are.equal("malformed", err.kind)
        assert.is_false(called)

        local works
        works, err = OpenLibrary.search(nil, { title = "Dune" }, function()
            return response({ docs = {} })
        end)
        assert.is_nil(works)
        assert.are.equal("no_match", err.kind)

        works, err = OpenLibrary.search(nil, { title = "Dune" }, function()
            return response({}, 503)
        end)
        assert.is_nil(works)
        assert.are.equal("server", err.kind)
        assert.are.equal(503, err.status)
    end)

    it("downloads covers only from the Open Library cover host", function()
        local calls = 0
        local url = "https://covers.openlibrary.org/b/id/12345-L.jpg?default=false"
        local path = assert(OpenLibrary.downloadCover(url, "/tmp/open-library-cover.jpg",
            function(received_url, destination, host, headers)
                calls = calls + 1
                assert.are.equal(url, received_url)
                assert.are.equal("/tmp/open-library-cover.jpg", destination)
                assert.are.equal("covers.openlibrary.org", host)
                assert.is_truthy(headers.Accept:find("image/jpeg", 1, true))
                return destination
            end))
        assert.are.equal("/tmp/open-library-cover.jpg", path)

        local rejected, err = OpenLibrary.downloadCover(
            "https://covers.openlibrary.org.evil/cover.jpg", "/tmp/evil.jpg", function()
                calls = calls + 1
            end)
        assert.is_nil(rejected)
        assert.are.equal("malformed", err.kind)
        assert.are.equal(1, calls)
    end)

    it("follows only the pinned Open Library archive redirect chain", function()
        local Http = require("modules/filebrowser/metadata/http")
        local original_request, original_download = Http.request, Http.download
        local calls = 0
        Http.request = function(options)
            calls = calls + 1
            if calls == 1 then
                assert.are.equal("covers.openlibrary.org", options.host)
                return response({}, 302, {
                    Location = "https://archive.org/download/l_covers/l_covers.zip/123-L.jpg",
                })
            end
            assert.are.equal("archive.org", options.host)
            return response({}, 302, {
                Location = "https://ia800001.us.archive.org/view_archive.php?archive=/items/l_covers/l_covers.zip&file=123-L.jpg",
            })
        end
        Http.download = function(url, destination, host)
            assert.are.equal("ia800001.us.archive.org", host)
            assert.is_truthy(url:find("/view_archive.php?archive=/", 1, true))
            return destination
        end
        local ok, path = pcall(OpenLibrary.downloadCover,
            "https://covers.openlibrary.org/b/id/123-L.jpg?default=false",
            "/tmp/open-library-cover.jpg")
        Http.request, Http.download = original_request, original_download
        assert.is_true(ok)
        assert.are.equal("/tmp/open-library-cover.jpg", path)

        calls = 0
        Http.request = function()
            calls = calls + 1
            return response({}, 302, { Location = calls == 1
                and "https://archive.org/download/covers/covers.zip/123-L.jpg"
                or "https://evil.example/view_archive.php?archive=/covers.zip&file=123-L.jpg" })
        end
        Http.download = function() error("untrusted redirect was downloaded") end
        local rejected, err = OpenLibrary.downloadCover(
            "https://covers.openlibrary.org/b/id/123-L.jpg?default=false",
            "/tmp/evil.jpg")
        Http.request, Http.download = original_request, original_download
        assert.is_nil(rejected)
        assert.are.equal("malformed", err.kind)
    end)
end)
