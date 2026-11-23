describe("library statistics", function()
    local open_calls
    local mtime

    before_each(function()
        local today = os.date("%Y-%m-%d")
        local old_day = os.date("%Y-%m-%d", os.time() - 400 * 86400)
        local summaries = {
            ["/books/complete.epub"] = { status = "complete", modified = today },
            ["/books/old.epub"] = { status = "complete", modified = old_day },
            ["/books/reading.epub"] = { status = "reading" },
            ["/books/chapter.cbz"] = { status = "complete", modified = today },
            ["/books/comic.cbz"] = { status = "complete", modified = today },
            ["/books/archive.CBR"] = { status = "complete", modified = today },
        }
        open_calls = 0
        mtime = 1000

        ZenSpec.replace("common/zen_logger", {
            new = function() return { info = function() end, warn = function() end } end,
        })
        ZenSpec.replace("common/paths", {
            getHomeDir = function() return "/books" end,
            isInHomeDir = function() return true end,
        })
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function()
                return { modification = mtime, size = 128 }
            end,
        })
        ZenSpec.replace("modules/filebrowser/patches/rakuyomi", {
            isChapterFile = function(path) return path == "/books/chapter.cbz" end,
        })
        ZenSpec.replace("readhistory", {
            hist = {
                { file = "/books/complete.epub" },
                { file = "/books/old.epub" },
                { file = "/books/reading.epub" },
                { file = "/books/chapter.cbz" },
                { file = "/books/comic.cbz" },
                { file = "/books/archive.CBR" },
            },
            reload = function() end,
        })
        ZenSpec.replace("docsettings", {
            findSidecarFile = function(_, file)
                return file .. ".sdr/metadata.epub.lua"
            end,
            openSettingsFile = function(sidecar_file)
                open_calls = open_calls + 1
                local file = sidecar_file:match("^([^%s]+)%.sdr/")
                return { data = { summary = summaries[file] } }
            end,
        })
        ZenSpec.unload("common/db_library")
    end)

    after_each(function()
        package.loaded["common/book_sources"] = nil
        ZenSpec.unload("common/db_library")
        ZenSpec.unload("modules/filebrowser/patches/rakuyomi")
    end)

    it("counts completed books by date but excludes Rakuyomi chapters", function()
        local counts = require("common/db_library").getBookCounts()

        assert.are.equal(4, counts.finished)
        assert.are.equal(3, counts.finished_this_month)
        assert.are.equal(3, counts.finished_this_year)
    end)

    it("excludes every CBZ and CBR from goal completion counts", function()
        local counts = require("common/db_library").getBookCounts(true)

        assert.are.equal(2, counts.finished)
        assert.are.equal(1, counts.finished_this_month)
        assert.are.equal(1, counts.finished_this_year)
    end)

    it("counts a sidecar with progress but no status as reading", function()
        ZenSpec.replace("readhistory", {
            hist = { { file = "/books/legacy.epub" }, { file = "/books/blank.epub" } },
            reload = function() end,
        })
        ZenSpec.replace("docsettings", {
            findSidecarFile = function(_, file) return file .. ".sdr/metadata.epub.lua" end,
            openSettingsFile = function(sidecar_file)
                if sidecar_file:find("legacy", 1, true) then
                    return { data = { summary = {}, percent_finished = 0.4 } }
                end
                return { data = {} }
            end,
        })
        local counts = require("common/db_library").getBookCounts()

        assert.are.equal(1, counts.reading)
        assert.are.equal(0, counts.finished)
        assert.are.equal(2, counts.total)
    end)

    it("reuses parsed sidecar summaries on later scans", function()
        local LibraryDB = require("common/db_library")
        LibraryDB.getBookCounts()
        local parsed = open_calls

        LibraryDB.invalidateCache()
        LibraryDB.getBookCounts()

        assert.are.equal(parsed, open_calls)
    end)

    it("re-parses only changed sidecars and keeps one entry per sidecar", function()
        local LibraryDB = require("common/db_library")
        LibraryDB.getBookCounts()
        local parsed = open_calls

        mtime = 2000
        LibraryDB.invalidateCache()
        LibraryDB.getBookCounts()
        assert.are.equal(parsed * 2, open_calls)

        LibraryDB.invalidateCache()
        LibraryDB.getBookCounts()
        assert.are.equal(parsed * 2, open_calls)
    end)

    describe("book sources", function()
        local statuses, revision, source_books

        before_each(function()
            local today = os.date("%Y-%m-%d")
            statuses = {
                ["/cloud/done.epub"] = { status = "complete", finished_at = today },
                ["/cloud/undated.epub"] = { status = "complete" },
                ["/cloud/now.epub"] = { status = "reading" },
                ["/cloud/comic.cbz"] = { status = "complete", finished_at = today },
                -- Has a sidecar here (in history): the sidecar wins.
                ["/books/reading.epub"] = { status = "complete", finished_at = today },
            }
            revision = 1
            source_books = {}
            for _i, file in ipairs({ "/cloud/done.epub", "/cloud/undated.epub",
                    "/cloud/now.epub", "/cloud/comic.cbz", "/cloud/unknown.epub",
                    "/books/reading.epub" }) do
                source_books[#source_books + 1] = { file = file, info = {} }
            end
            ZenSpec.replace("docsettings", {
                findSidecarFile = function(_, file)
                    if file:sub(1, 7) == "/books/" then return file .. ".sdr/metadata.epub.lua" end
                end,
                openSettingsFile = function(sidecar_file)
                    local file = sidecar_file:match("^([^%s]+)%.sdr/")
                    local summaries = {
                        ["/books/complete.epub"] = { status = "complete", modified = today },
                        ["/books/reading.epub"] = { status = "reading" },
                    }
                    return { data = { summary = summaries[file] } }
                end,
            })
            ZenSpec.replace("readhistory", {
                hist = { { file = "/books/complete.epub" }, { file = "/books/reading.epub" } },
                reload = function() end,
            })
            package.loaded["common/book_sources"] = {
                statusRevision = function() return revision end,
                books = function() return source_books end,
                status = function(path) return statuses[path] end,
            }
        end)

        it("counts books without a sidecar by their source's status", function()
            local counts = require("common/db_library").getBookCounts()

            assert.are.equal(4, counts.finished)
            assert.are.equal(3, counts.finished_this_month)
            assert.are.equal(3, counts.finished_this_year)
            assert.are.equal(2, counts.reading)
            assert.are.equal(6, counts.total)
        end)

        it("counts a source book with progress but no status as reading", function()
            statuses["/cloud/progress.epub"] = { percent_finished = 0.3 }
            source_books[#source_books + 1] = { file = "/cloud/progress.epub", info = {} }
            local counts = require("common/db_library").getBookCounts()

            assert.are.equal(3, counts.reading)
            assert.are.equal(4, counts.finished)
            assert.are.equal(7, counts.total)
        end)

        it("leaves out the sources' comics when asked to", function()
            local counts = require("common/db_library").getBookCounts(true)

            assert.are.equal(3, counts.finished)
            assert.are.equal(2, counts.finished_this_month)
        end)

        it("recounts as soon as a source reports a change", function()
            local LibraryDB = require("common/db_library")
            assert.are.equal(2, LibraryDB.getBookCounts().reading)

            statuses["/cloud/now.epub"] = { status = "complete", finished_at = os.date("%Y-%m-%d") }
            assert.are.equal(2, LibraryDB.getBookCounts().reading)

            revision = 2
            local counts = LibraryDB.getBookCounts()
            assert.are.equal(1, counts.reading)
            assert.are.equal(4, counts.finished_this_month)
        end)
    end)
end)
