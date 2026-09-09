local HistoryIndex = require("common/history_index")

describe("history index", function()
    it("normalizes only unresolved paths when normalized history exists", function()
        local index = { by_raw_path = {}, by_normalized_path = {} }
        local calls = 0
        local function normalize(path)
            calls = calls + 1
            return path:gsub("^/sdcard", "/storage/emulated/0")
        end
        assert.is_nil(HistoryIndex.fileTime(index, "/sdcard/book.epub", normalize))
        assert.are.equal(0, calls)
        index.by_raw_path["/sdcard/book.epub"] = 100
        index.by_normalized_path["/storage/emulated/0/book.epub"] = 100
        assert.are.equal(100, HistoryIndex.fileTime(index, "/sdcard/book.epub", normalize))
        assert.are.equal(0, calls)
        assert.are.equal(100, HistoryIndex.fileTime(index, "/storage/emulated/0/book.epub", normalize))
        assert.are.equal(1, calls)
        assert.is_nil(HistoryIndex.fileTime(index, "/sdcard/missing.epub", normalize))
        assert.are.equal(2, calls)
    end)

    it("maps raw and normalized paths and derives descendant directory times", function()
        ZenSpec.replace("readhistory", {
            hist = {
                { file = "/sdcard/Books/Series/book.epub", time = 100 },
                { file = "/sdcard/Books/other.epub", time = 90 },
            },
            reload = function() end,
        })
        local normalize = function(path)
            return path:gsub("^/sdcard", "/storage/emulated/0")
        end
        local index = HistoryIndex.load(normalize)
        assert.are.equal(100, HistoryIndex.fileTime(index, "/sdcard/Books/Series/book.epub", normalize))
        assert.are.same({
            ["/storage/emulated/0/Books"] = 100,
            ["/storage/emulated/0/Books/Series"] = 100,
        }, HistoryIndex.maxDescendantTimes(index, {
            "/storage/emulated/0/Books",
            "/storage/emulated/0/Books/Series",
        }))
    end)
end)
