describe("library statistics", function()
    local open_calls

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

        ZenSpec.replace("common/zen_logger", {
            new = function() return { info = function() end, warn = function() end } end,
        })
        ZenSpec.replace("common/paths", {
            getHomeDir = function() return "/books" end,
            isInHomeDir = function() return true end,
        })
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function()
                return { modification = 1000, size = 128 }
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

    it("reuses parsed sidecar summaries on later scans", function()
        local LibraryDB = require("common/db_library")
        LibraryDB.getBookCounts()
        local parsed = open_calls

        LibraryDB.invalidateCache()
        LibraryDB.getBookCounts()

        assert.are.equal(parsed, open_calls)
    end)
end)
