describe("CoverBrowser decoded cover cache patch", function()
    local BookInfoManager
    local Cache
    local apply
    local full_reads
    local metadata_reads
    local current_time
    local forced_info
    local statements_seen

    local function fake_bb(id)
        local bb = { stride = 4, h = 1, id = id }
        function bb:getHeight() return self.h end
        function bb:copy() return fake_bb(id .. ":copy") end
        function bb:free() self.freed = true end
        return bb
    end

    local function info(with_cover)
        return {
            filesize = 100,
            filemtime = 200,
            cover_fetched = "Y",
            has_cover = "Y",
            cover_sizetag = "100x150",
            cover_w = 50,
            cover_h = 75,
            cover_bb = with_cover and fake_bb("decoded") or nil,
        }
    end

    before_each(function()
        full_reads = 0
        metadata_reads = 0
        current_time = 100
        forced_info = nil
        statements_seen = {}
        BookInfoManager = {
            getBookInfo = function(self, _filepath, get_cover)
                if self.get_stmt then
                    statements_seen[#statements_seen + 1] = self.get_stmt.id
                end
                if get_cover then
                    full_reads = full_reads + 1
                else
                    metadata_reads = metadata_reads + 1
                end
                return forced_info or info(get_cover)
            end,
            deleteBookInfo = function() end,
            extractInBackground = function() end,
        }
        ZenSpec.replace("bookinfomanager", BookInfoManager)
        ZenSpec.replace("common/zen_logger", {
            now = function() return current_time end,
        })
        ZenSpec.unload("common/cover_decode_cache")
        Cache = require("common/cover_decode_cache")
        Cache:clear()
        Cache:setByteBudget(Cache.DEFAULT_BYTE_BUDGET)
        ZenSpec.unload("modules/filebrowser/patches/cover_decode_cache")
        apply = require("modules/filebrowser/patches/cover_decode_cache")
        apply()
    end)

    after_each(function()
        Cache:clear()
    end)

    it("decompresses and queries once, then serves recent copies from memory", function()
        local first = BookInfoManager:getBookInfo("/book.epub", true)
        local second = BookInfoManager:getBookInfo("/book.epub", true)

        assert.are.equal(1, full_reads)
        assert.are.equal(0, metadata_reads)
        assert.are_not.equal(first.cover_bb, second.cover_bb)
        assert.are.equal(1, Cache:stats().hits)
        assert.are.equal(1, Cache:stats().fast_hits)
    end)

    it("revalidates cached metadata after thirty seconds", function()
        BookInfoManager:getBookInfo("/book.epub", true)
        current_time = current_time + 31
        BookInfoManager:getBookInfo("/book.epub", true)

        assert.are.equal(1, full_reads)
        assert.are.equal(1, metadata_reads)
        assert.are.equal(1, Cache:stats().validation_reads)
    end)

    it("avoids 99 of 100 repeated decompressions", function()
        for _i = 1, 100 do
            local result = BookInfoManager:getBookInfo("/book.epub", true)
            result.cover_bb:free()
        end

        local stats = Cache:stats()
        assert.are.equal(1, full_reads)
        assert.are.equal(0, metadata_reads)
        assert.are.equal(99, stats.hits)
        assert.are.equal(99, stats.fast_hits)
        assert.are.equal(1, stats.decode_reads)
        assert.are.equal(99, stats.hits / (stats.hits + stats.decode_reads) * 100)
    end)

    it("remembers metadata for books without covers", function()
        forced_info = {
            title = "Placeholder",
            cover_fetched = "Y",
            has_cover = false,
        }

        BookInfoManager:getBookInfo("/placeholder.epub", true)
        local metadata = Cache:getFreshMetadata("/placeholder.epub", current_time, 30)

        assert.are.equal("Placeholder", metadata.title)
        assert.is_false(metadata.has_cover)
        assert.are.equal(1, full_reads)
        assert.are.equal(1, Cache:stats().metadata_count)
    end)

    it("reads metadata-only lookups through a blob-less statement", function()
        local stock_stmt, metadata_stmt = { id = "stock" }, {
            id = "metadata",
            clearbind = function() end,
            reset = function() end,
        }
        BookInfoManager.db_conn = {}
        BookInfoManager.get_stmt = stock_stmt
        ZenSpec.replace("common/db_bookinfo", {
            getMetadataStatement = function() return metadata_stmt end,
        })

        BookInfoManager:getBookInfo("/book.epub", false)
        BookInfoManager:getBookInfo("/book.epub", true)

        assert.are.same({ "metadata", "stock" }, statements_seen)
        assert.are.equal(stock_stmt, BookInfoManager.get_stmt)
    end)

    it("invalidates a book when CoverBrowser deletes its metadata", function()
        BookInfoManager:getBookInfo("/book.epub", true)
        assert.is_true(Cache:has("/book.epub"))

        BookInfoManager:deleteBookInfo("/book.epub")

        assert.is_false(Cache:has("/book.epub"))
    end)

    it("invalidates queued CoverBrowser extraction records", function()
        BookInfoManager:getBookInfo("/book.epub", true)
        assert.is_true(Cache:has("/book.epub"))

        BookInfoManager:extractInBackground({ { filepath = "/book.epub" } })

        assert.is_false(Cache:has("/book.epub"))
    end)

    it("keeps CoverBrowser's crash-loop guard for abandoned books", function()
        local deleted
        forced_info = {
            unsupported = "too many interruptions or crashes",
            cover_fetched = "Y",
        }
        BookInfoManager.deleteBookInfo = function(_self, path) deleted = path end

        local result = BookInfoManager:getBookInfo("/crashing.pdf", true)
        assert.are.equal("too many interruptions or crashes", result.unsupported)
        assert.is_nil(deleted)
    end)
end)
