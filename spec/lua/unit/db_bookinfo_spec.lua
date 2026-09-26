describe("book info grouping cache", function()
    local exec_calls
    local DbBookInfo
    local now_value
    local limit_group_cache
    local original_memory_policy
    local prepared_queries
    local kindle_paths
    local kindle_metadata

    before_each(function()
        exec_calls = 0
        now_value = 0
        limit_group_cache = false
        prepared_queries = {}
        kindle_paths = {}
        kindle_metadata = {}
        original_memory_policy = package.loaded["common/memory_policy"]
        ZenSpec.replace("common/memory_policy", {
            limitGroupCache = function() return limit_group_cache end,
        })
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function(path, key)
                local attr
                if path == "/settings/bookinfo.sqlite3" then
                    attr = { size = 100, modification = 200, mode = "file" }
                elseif path == "/settings/bookinfo.sqlite3-wal" then
                    attr = nil
                else
                    attr = { size = 10, modification = 20, mode = "file" }
                end
                return key and attr and attr[key] or attr
            end,
        })
        ZenSpec.replace("common/paths", {
            getHomeDir = function() return "/books" end,
            normPath = function(path) return path end,
            isInHomeDir = function() return true end,
        })
        ZenSpec.replace("ui/data/isolanguage", {
            getBCPLanguageTag = function(_self, code)
                return code == "eng" and "en" or code
            end,
        })
        ZenSpec.replace("modules/filebrowser/patches/kindle_virtual_library", {
            getBookPaths = function() return kindle_paths end,
        })
        ZenSpec.replace("bookinfomanager", {
            db_location = "/settings/bookinfo.sqlite3",
            db_conn = {
                prepare = function(_self, sql)
                    local query = { sql = sql, binds = {}, rows = {} }
                    prepared_queries[#prepared_queries + 1] = query
                    return {
                        bind = function(_stmt, ...)
                            query.binds = { ... }
                        end,
                        step = function()
                            return table.remove(query.rows, 1)
                        end,
                        clearbind = function() end,
                        reset = function() end,
                        close = function() end,
                    }
                end,
                exec = function(_self, sql)
                    exec_calls = exec_calls + 1
                    if sql:find("title, authors, series", 1, true) then
                        return {
                            { "/books/", "/books/" },
                            { "a.epub", "b.epub" },
                            { "Title A", "Title B" },
                            { "Author A", "Author B" },
                            { "Series A", "Series B" },
                            { 2, 1 },
                            { "Tag A", "Tag B" },
                        }
                    end
                    if sql:find("filename, language", 1, true) then
                        return {
                            { "/books/", "/books/", "/books/" },
                            { "a.epub", "b.epub", "c.epub" },
                            { " en ", "eng", "fr" },
                        }
                    end
                    return {
                        { "/books/", "/books/" },
                        { "a.epub", "b.epub" },
                        { "Author A", "Author B" },
                    }
                end,
            },
            openDbConnection = function() end,
            getBookInfo = function(_self, path) return kindle_metadata[path] end,
        })
        ZenSpec.replace("readhistory", {
            hist = { { file = "/books/b.epub" } },
        })
        ZenSpec.replace("common/zen_logger", {
            now = function() return now_value end,
            new = function()
                return {
                    measure = function() end,
                    warn = function() end,
                    info = function() end,
                    dbg = function() end,
                }
            end,
        })
        ZenSpec.unload("common/db_bookinfo")
        DbBookInfo = require("common/db_bookinfo")
    end)

    after_each(function()
        package.loaded["common/memory_policy"] = original_memory_policy
    end)

    it("reuses group shapes until explicitly invalidated", function()
        local first = DbBookInfo.getGroupedByAuthor()
        local second = DbBookInfo.getGroupedByAuthor()

        assert.are.equal(1, exec_calls)
        assert.are.equal(first, second)
        assert.are.same({ hits = 1, misses = 1 }, DbBookInfo.getCacheStats())

        DbBookInfo.invalidate()
        DbBookInfo.getGroupedByAuthor()

        assert.are.equal(2, exec_calls)
        assert.are.same({ hits = 1, misses = 2 }, DbBookInfo.getCacheStats())
    end)

    it("keeps unchanged group shapes warm across normal tab-switch intervals", function()
        local first = DbBookInfo.getGroupedByAuthor()
        now_value = 31
        local after_thirty_seconds = DbBookInfo.getGroupedByAuthor()

        assert.are.equal(first, after_thirty_seconds)
        assert.are.equal(1, exec_calls)

        now_value = 301
        DbBookInfo.getGroupedByAuthor()
        assert.are.equal(2, exec_calls)
    end)

    it("retains only the most recent full grouping on constrained devices", function()
        limit_group_cache = true
        DbBookInfo.getGroupedByAuthor()
        DbBookInfo.getGroupedBySeries()
        DbBookInfo.getGroupedByAuthor()

        assert.are.equal(3, exec_calls)
    end)

    it("returns one tag's books from the cached tag groups", function()
        local groups = DbBookInfo.getGroupedByTags()
        local files = DbBookInfo.getTagBooks(groups[1].tag)

        assert.are.same(groups[1].files, files)
        assert.are.equal(1, exec_calls)
    end)

    it("combines equivalent language codes", function()
        local groups = DbBookInfo.getGroupedByLanguage()

        assert.are.same({
            { language = "en", files = { "/books/a.epub", "/books/b.epub" } },
            { language = "fr", files = { "/books/c.epub" } },
        }, groups)
        assert.are.equal(1, exec_calls)
    end)

    it("includes Kindle virtual library metadata in every group view", function()
        local path = "/kindle-cache/book.epub"
        kindle_paths = { path }
        kindle_metadata[path] = {
            title = "Kindle Book",
            authors = "Kindle Author",
            series = "Kindle Saga",
            series_index = 2,
            language = "en-US",
            keywords = "Adventure, Fiction",
        }

        local authors = DbBookInfo.getGroupedByAuthor()
        local series = DbBookInfo.getGroupedBySeries()
        local languages = DbBookInfo.getGroupedByLanguage()
        local tags = DbBookInfo.getGroupedByTags()
        local metadata = DbBookInfo.getLightMetadata()

        assert.are.same({ path }, authors[#authors].files)
        assert.are.equal("Kindle Author", authors[#authors].author)
        assert.are.equal(path, series[#series].items[1].file)
        assert.are.equal("Kindle Saga", series[#series].series)
        assert.are.same({ "/books/a.epub", "/books/b.epub", path }, languages[1].files)
        assert.are.equal("en", languages[1].language)
        assert.are.same({ path }, tags[1].files)
        assert.are.equal("Adventure", tags[1].tag)
        assert.are.equal("Kindle Book", metadata[path].title)
    end)

    it("loads lightweight sorting metadata in one batch", function()
        local metadata = DbBookInfo.getLightMetadata()

        assert.are.equal("Title A", metadata["/books/a.epub"].title)
        assert.are.equal("Author A", metadata["/books/a.epub"].authors)
        assert.are.equal("Series B", metadata["/books/b.epub"].series)
        assert.are.equal(1, metadata["/books/b.epub"].series_index)
        assert.are.equal(1, exec_calls)
    end)

    it("loads and caches one directory with bound normalized paths", function()
        local conn = require("bookinfomanager").db_conn
        local original_prepare = conn.prepare
        conn.prepare = function(self, sql)
            local stmt = original_prepare(self, sql)
            local query = prepared_queries[#prepared_queries]
            query.rows = {
                { "/books/folder/", "a.epub", "Title A", "Author A", "Series A", 2, "Tag A" },
            }
            return stmt
        end

        local first = DbBookInfo.getLightMetadata("/books/folder")
        local second = DbBookInfo.getLightMetadata("/books/folder/")

        assert.are.equal("Title A", first["/books/folder/a.epub"].title)
        assert.are.equal("Author A", first["/books/folder/a.epub"].authors)
        assert.are.equal("Tag A", first["/books/folder/a.epub"].keywords)
        assert.are.equal(first, second)
        assert.are.equal(1, #prepared_queries)
        assert.matches("WHERE directory = %? OR directory = %? OR directory = %?",
            prepared_queries[1].sql)
        assert.are.same({ "/books/folder/", "/books/folder/", "/books/folder/" },
            prepared_queries[1].binds)
        assert.are.equal(0, exec_calls)
    end)

    it("binds directory text instead of interpolating it into SQL", function()
        DbBookInfo.getLightMetadata("/books/O'Brien")

        assert.are.equal(1, #prepared_queries)
        assert.is_nil(prepared_queries[1].sql:find("O'Brien", 1, true))
        assert.are.equal("/books/O'Brien/", prepared_queries[1].binds[1])
    end)

    it("queries raw and normalized Android directory aliases", function()
        require("common/paths").normPath = function(path)
            return path:gsub("^/sdcard/", "/storage/emulated/0/")
        end

        DbBookInfo.getLightMetadata("/sdcard/folder")

        assert.are.same({
            "/sdcard/folder/", "/storage/emulated/0/folder/", "/sdcard/folder/",
        }, prepared_queries[1].binds)
    end)

    it("bounds cached directories on constrained devices", function()
        limit_group_cache = true
        for index = 1, 5 do
            DbBookInfo.getLightMetadata("/books/folder-" .. index)
        end
        DbBookInfo.getLightMetadata("/books/folder-1")

        assert.are.equal(6, #prepared_queries)
    end)
end)
