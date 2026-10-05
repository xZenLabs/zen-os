local function settings(initial)
    local data = initial or {}
    return {
        data = { doc_path = "/books/book.epub" },
        readSetting = function(_self, key) return data[key] end,
        saveSetting = function(_self, key, value) data[key] = value end,
        delSetting = function(_self, key) data[key] = nil end,
    }, data
end

describe("book status", function()
    local clock

    before_each(function()
        clock = 0
        ZenSpec.unload("common/book_status")
        ZenSpec.replace("config/manager", {
            get = function() return { group_view = { file_updates_as_new = true } } end,
        })
        ZenSpec.replace("common/zen_logger", {
            now = function() return clock end,
            new = function()
                return { measure = function() end }
            end,
        })
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function(path, attribute)
                local values = {
                    ["/books/book.epub"] = { mode = "file", modification = 200 },
                    ["/books/book.sdr/metadata.lua"] = { mode = "file", modification = 150 },
                }
                local value = values[path]
                return attribute and value and value[attribute] or value
            end,
        })
        ZenSpec.replace("docsettings", {
            findSidecarFile = function() return "/books/book.sdr/metadata.lua" end,
            hasSidecarFile = function() return true end,
        })
    end)

    it("normalizes explicit, inferred, and image statuses", function()
        local BookStatus = require("common/book_status")
        assert.are.equal("new", BookStatus.getEffectiveStatus(nil, nil))
        assert.are.equal("reading", BookStatus.getEffectiveStatus(nil, 0))
        assert.are.equal("complete", BookStatus.getEffectiveStatus("complete", nil))
        assert.is_true(BookStatus.isImageFile("COVER.JPEG"))
        assert.is_false(BookStatus.isImageFile("book.epub"))
        assert.is_false(BookStatus.isImageFile(nil))
    end)

    it("derives the TBR display status from the collection or new-book setting", function()
        local include_new = false
        ZenSpec.replace("config/manager", {
            get = function()
                return { group_view = { include_new_in_tbr = include_new } }
            end,
        })
        ZenSpec.replace("common/tbr_index", {
            isExplicit = function(path) return path == "/books/queued.epub" end,
        })
        local BookStatus = require("common/book_status")

        assert.are.equal("tbr", BookStatus.getDisplayStatus("/books/queued.epub", "reading"))
        assert.are.equal("new", BookStatus.getDisplayStatus("/books/new.epub", "new"))

        include_new = true
        assert.are.equal("tbr", BookStatus.getDisplayStatus("/books/new.epub", "new"))
    end)

    it("detects a changed book from its sidecar or acknowledgment marker", function()
        local BookStatus = require("common/book_status")
        local doc, data = settings({ percent_finished = 0.5 })

        assert.are.equal("new", BookStatus.getComputedStatus(
            "/books/book.epub", nil, 0.5, doc
        ))
        data.zen_new_mtime = 200
        assert.are.equal("reading", BookStatus.getComputedStatus(
            "/books/book.epub", nil, 0.5, doc
        ))
        data.zen_new_mtime = 100
        assert.are.equal("new", BookStatus.getComputedStatus(
            "/books/book.epub", nil, 0.5, doc
        ))
        assert.are.equal("reading", BookStatus.getComputedStatus(
            "/books/cover.png", nil, 0.5, doc
        ))
    end)

    it("preserves updated books' status by default and marks them new only when enabled", function()
        local doc, data = settings({
            summary = { status = "complete" },
            percent_finished = 1,
        })
        ZenSpec.replace("docsettings", {
            findSidecarFile = function() return "/books/book.sdr/metadata.lua" end,
            open = function() return doc end,
        })
        local cfg = { group_view = {} }
        ZenSpec.replace("config/manager", { get = function() return cfg end })
        ZenSpec.replace("common/tbr_index", { isExplicit = function() return false end })
        local BookStatus = require("common/book_status")
        assert.is_false(require("config/defaults").group_view.file_updates_as_new)
        assert.is_false(BookStatus.fileUpdatesAsNewEnabled())
        assert.are.equal("complete", BookStatus.getComputedStatus(
            "/books/book.epub", "complete", nil, doc))

        for _i, marker in ipairs({ false, 100 }) do
            data.zen_new_mtime = marker or nil
            for _j, enabled in ipairs({ true, false, true }) do
                cfg.group_view.file_updates_as_new = enabled
                BookStatus.clearCache()
                local expected = enabled and "new" or "complete"
                assert.are.equal(expected, BookStatus.getComputedStatus(
                    "/books/book.epub", "complete", nil, doc))
                assert.are.equal(enabled and "new" or "reading", BookStatus.getComputedStatus(
                    "/books/book.epub", "reading", 0.5, doc))
                assert.are.equal("new", BookStatus.getComputedStatus(
                    "/books/book.epub", nil, nil, doc))
                local status = BookStatus.getFileStatusData("/books/book.epub", {
                    status = "reading", percent_finished = 0.5,
                })
                assert.are.equal("complete", status.status)
                assert.are.equal(expected, status.effective_status)
                assert.are.equal(expected, status.display_status)
                assert.are.equal(1, status.percent_finished)
                assert.are.equal(marker or nil, data.zen_new_mtime)
            end
        end
        BookStatus.acknowledgeNewVersion(doc)
        BookStatus.clearCache()
        assert.are.equal("complete", BookStatus.getEffectiveStatusFromFile("/books/book.epub"))
    end)

    it("acknowledges the current file version and removes the legacy marker", function()
        local BookStatus = require("common/book_status")
        local doc, data = settings({ zen_auto_tbr_mtime = 100 })

        assert.is_true(BookStatus.acknowledgeNewVersion(doc))
        assert.are.equal(200, data.zen_new_mtime)
        assert.is_nil(data.zen_auto_tbr_mtime)
        assert.is_false(BookStatus.acknowledgeNewVersion(doc))
    end)

    it("uses safe defaults for missing book information", function()
        local BookStatus = require("common/book_status")
        assert.are.equal("new", BookStatus.getEffectiveStatusFromInfo(nil))
        assert.are.equal("reading", BookStatus.getEffectiveStatusFromInfo({
            percent_finished = 0.25,
        }))
    end)

    it("reuses authoritative sidecar status until explicitly invalidated", function()
        local opens = 0
        local booklist_reads = 0
        local doc, data = settings({
            summary = { status = "reading" },
            percent_finished = 0.5,
            zen_new_mtime = 200,
        })
        ZenSpec.replace("docsettings", {
            findSidecarFile = function() return "/books/book.sdr/metadata.lua" end,
            hasSidecarFile = function() return true end,
            open = function()
                opens = opens + 1
                return doc
            end,
        })
        ZenSpec.replace("ui/widget/booklist", {
            getBookInfo = function()
                booklist_reads = booklist_reads + 1
                return { status = "complete", percent_finished = 1 }
            end,
        })
        local BookStatus = require("common/book_status")

        assert.are.equal("reading", BookStatus.getEffectiveStatusFromFile("/books/book.epub"))
        assert.are.equal(1, opens)
        assert.are.equal(0, booklist_reads)
        assert.are.equal("reading", BookStatus.getFileStatusData(
            "/books/book.epub", { status = "complete", percent_finished = 1 }
        ).effective_status)
        assert.are.equal(1, opens)

        data.zen_new_mtime = 100
        assert.are.equal("reading", BookStatus.getEffectiveStatusFromFile("/books/book.epub"))
        assert.are.equal(1, opens)
        BookStatus.invalidate("/books/book.epub")
        assert.are.equal("new", BookStatus.getEffectiveStatusFromFile("/books/book.epub"))
        assert.are.equal(2, opens)
        assert.are.equal(0, booklist_reads)
    end)

    it("refreshes cached status when the sidecar modification time changes", function()
        local sidecar_mtime = 150
        local opens = 0
        local stats = 0
        local sidecar_finds = 0
        local doc, data = settings({
            summary = { status = "reading" },
            percent_finished = 0.5,
            zen_new_mtime = 200,
        })
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function(path, attribute)
                stats = stats + 1
                local value = path == "/books/book.epub"
                    and { mode = "file", modification = 200 }
                    or { mode = "file", modification = sidecar_mtime }
                return attribute and value[attribute] or value
            end,
        })
        ZenSpec.replace("docsettings", {
            findSidecarFile = function()
                sidecar_finds = sidecar_finds + 1
                return "/books/book.sdr/metadata.lua"
            end,
            hasSidecarFile = function() return true end,
            open = function()
                opens = opens + 1
                return doc
            end,
        })
        local BookStatus = require("common/book_status")

        assert.are.equal("reading", BookStatus.getEffectiveStatusFromFile("/books/book.epub"))
        data.summary.status = "complete"
        clock = 4
        assert.are.equal("reading", BookStatus.getEffectiveStatusFromFile("/books/book.epub"))
        assert.are.equal(2, stats)
        assert.are.equal(1, sidecar_finds)
        assert.are.equal(1, opens)
        sidecar_mtime = 151
        clock = 6
        assert.are.equal("complete", BookStatus.getEffectiveStatusFromFile("/books/book.epub"))
        assert.are.equal(4, stats)
        assert.are.equal(2, sidecar_finds)
        assert.are.equal(2, opens)
    end)

    it("keeps the sidecar authoritative when its mtime cannot be read", function()
        local doc = settings({
            summary = { status = "reading" },
            percent_finished = 0.5,
            zen_new_mtime = 200,
        })
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function(path, attribute)
                local value = path == "/books/book.epub"
                    and { mode = "file", modification = 200 } or nil
                return attribute and value and value[attribute] or value
            end,
        })
        ZenSpec.replace("docsettings", {
            findSidecarFile = function() return "/books/book.sdr/metadata.lua" end,
            hasSidecarFile = function() return true end,
            open = function() return doc end,
        })
        ZenSpec.replace("ui/widget/booklist", {
            getBookInfo = function() return { status = "complete", percent_finished = 1 } end,
        })
        local BookStatus = require("common/book_status")

        assert.are.equal("reading", BookStatus.getEffectiveStatusFromFile("/books/book.epub"))
    end)

    it("consults BookList once when no sidecar is available", function()
        local booklist_reads = 0
        ZenSpec.replace("docsettings", {
            hasSidecarFile = function() return false end,
        })
        ZenSpec.replace("ui/widget/booklist", {
            getBookInfo = function()
                booklist_reads = booklist_reads + 1
                return { status = "complete", percent_finished = 1 }
            end,
        })
        local BookStatus = require("common/book_status")

        assert.are.equal("complete", BookStatus.getEffectiveStatusFromFile("/books/book.epub"))
        assert.are.equal("complete", BookStatus.getEffectiveStatusFromFile("/books/book.epub"))
        assert.are.equal(1, booklist_reads)

        local supplied = BookStatus.getFileStatusData("/books/book.epub", {
            status = "reading", percent_finished = 0.5,
        })
        assert.are.equal("reading", supplied.effective_status)
        assert.are.equal(1, booklist_reads)
    end)

    it("retains more than 32 visible statuses without reopening sidecars", function()
        local opens = 0
        local doc = settings({
            summary = { status = "reading" },
            percent_finished = 0.5,
            zen_new_mtime = 200,
        })
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function(path, attribute)
                local modification = path:find("metadata%.lua$", 1) and 150 or 200
                local value = { mode = "file", modification = modification }
                return attribute and value[attribute] or value
            end,
        })
        ZenSpec.replace("docsettings", {
            findSidecarFile = function(_, path)
                return path .. ".sdr/metadata.lua"
            end,
            open = function()
                opens = opens + 1
                return doc
            end,
        })
        local BookStatus = require("common/book_status")

        for index = 1, 40 do
            BookStatus.getEffectiveStatusFromFile("/books/book-" .. index .. ".epub")
        end
        assert.are.equal(40, opens)
        assert.are.equal("reading", BookStatus.getEffectiveStatusFromFile(
            "/books/book-1.epub"))
        assert.are.equal(40, opens)
    end)
end)
