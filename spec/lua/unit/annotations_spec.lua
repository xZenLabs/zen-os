describe("annotation viewer model", function()
    local Model, modules, floating
    before_each(function()
        modules = {}
        for _i, name in ipairs({ "modules/reader/annotations", "modules/reader/book_note", "docsettings",
                "ui/uimanager", "readhistory", "libs/libkoreader-lfs", "ffi/util" }) do
            modules[name] = package.loaded[name] or false
        end
        floating = ""
        ZenSpec.replace("modules/reader/book_note", { read = function()
            return floating, nil, "/book.sdr/zen-note.txt", 1
        end })
        ZenSpec.unload("modules/reader/annotations")
        Model = require("modules/reader/annotations")
    end)
    after_each(function()
        for name, module in pairs(modules) do package.loaded[name] = module or nil end
    end)

    local function state()
        return { query = "", filters = {}, text_filters = {} }
    end

    local function doc_settings(data)
        return { data = data or {}, readSetting = function() end }
    end

    it("separates bookmarks, noted highlights, and floating notes without mutating source data", function()
        local source = {
            { page = 1, text = "bookmark", note = "page note" },
            { page = 2, text = "highlight", note = "my thought", drawer = "lighten", color = "red" },
        }
        floating = "A book-level thought"
        local records = Model.normalize("book.epub", source, { title = "Book" })
        assert.are.equal(3, #records)
        assert.is_true(Model.matches(records[1], state(), "bookmarks"))
        assert.is_false(Model.matches(records[2], state(), "bookmarks"))
        assert.is_true(Model.matches(records[2], state(), "highlights"))
        assert.is_false(Model.matches(records[3], state(), "highlights"))
        assert.is_true(Model.matches(records[3], state(), "annotations"))
        assert.are.equal("note", records[3].kind)
        assert.is_nil(records[3].annotation)
        assert.are.equal("", records[3].page_label)
        assert.is_nil(source[1].kind)
        assert.are.equal("highlight", source[2].text)
    end)

    it("combines facets, includes and excludes, and search across quote and note", function()
        local record = Model.normalize("book.epub", {
            { text = "Quiet words", note = "Personal thought", drawer = "lighten", color = "red", tags = "zen,reading" },
        }, {})[1]
        local filter = state()
        filter.query = "WORDS thought"
        filter.filters.color = { include = { red = true, blue = true }, exclude = {} }
        filter.filters.tags = { include = { zen = true }, exclude = { unrelated = true } }
        assert.is_true(Model.matches(record, filter, "highlights"))
        filter.filters.color.exclude.red = true
        assert.is_false(Model.matches(record, filter, "highlights"))
        filter.filters.color.exclude.red = nil
        filter.text_filters.note = { exclude = { text = "personal", mode = "phrase" } }
        assert.is_false(Model.matches(record, filter, "highlights"))
        filter.text_filters.note.exclude.case_sensitive = true
        assert.is_true(Model.matches(record, filter, "highlights"))
    end)

    it("matches literal Unicode text using any/all words or a phrase", function()
        assert.is_true(Model.textMatches("Été calme", { text = "ÉTÉ calme", mode = "all" }))
        assert.is_false(Model.textMatches("one two", { text = "two one", mode = "phrase" }))
        assert.is_true(Model.textMatches("one two", { text = "three two", mode = "any" }))
        assert.is_false(Model.textMatches("one two", { text = "three two", mode = "all" }))
        assert.is_true(Model.textMatches("[literal] 中文", { text = "[literal] 中文", mode = "phrase" }))
    end)

    it("resolves exact PDF and EPUB locations after list order changes", function()
        local a = { datetime = "a", page = "xp1", pos0 = "start", pos1 = "end" }
        local b = { datetime = "b", page = 2, pos0 = { x = 10, y = 20 }, pos1 = { x = 30, y = 40 } }
        local ui = { annotation = { annotations = { b, a } } }
        assert.are.equal(2, Model.resolve(ui, { annotation = a }))
        assert.are.equal(1, Model.resolve(ui, { annotation = {
            datetime = "b", page = 2, pos0 = { x = 10, y = 20 }, pos1 = { x = 30, y = 40 },
        } }))
        table.remove(ui.annotation.annotations, 2)
        assert.is_nil(Model.resolve(ui, { annotation = a }))
    end)

    it("keeps session scope and ordering separate from the live annotations", function()
        local source = { { page = 10, datetime = "b" }, { page = 2, datetime = "a" } }
        local session = Model.new({ document = { file = "current.epub" }, annotation = { annotations = source },
            doc_settings = doc_settings() })
        session:refreshCurrent()
        session.books["other.epub"] = Model.normalize("other.epub", { { page = 1 } }, { title = "Other" })
        assert.are.equal(2, #session:items("annotations"))
        assert.are.equal(10, session:items("annotations")[1].annotation.page)
        session.sort = "date"
        assert.are.equal(2, session:items("annotations")[1].annotation.page)
        session.scope = "all"
        assert.are.equal(3, #session:items("annotations"))
        assert.are.equal(10, source[1].page)
    end)

    it("loads other books once, reads legacy locations, and skips broken sidecars", function()
        local queue, reads = {}, {}
        local legacy = {
            bookmarks = { { page = "xp", pos0 = "xp", pos1 = "end", highlighted = true,
                notes = "Legacy quote", datetime = "old" } },
            highlight = { [99] = { { pos0 = "xp", pos1 = "end", drawer = "strikeout", color = "red" } } },
            pinned_page = 12,
        }
        ZenSpec.replace("docsettings", {
            findSidecarFile = function(_self, file) return file end,
            findCustomMetadataFile = function() end,
            openSettingsFile = function(file)
                reads[file] = (reads[file] or 0) + 1
                if file == "broken" then error("unreadable") end
                return { data = legacy }
            end,
        })
        ZenSpec.replace("libs/libkoreader-lfs", { attributes = function(file)
            if file ~= "missing" then return "file" end
        end })
        ZenSpec.replace("readhistory", { reload = function() end,
            hist = { { file = "other" }, { file = "alias" }, { file = "current" },
                { file = "missing" }, { file = "broken" } } })
        ZenSpec.replace("ffi/util", { realpath = function(file) return file == "alias" and "other" or file end })
        ZenSpec.replace("ui/uimanager", { nextTick = function(_self, cb) queue[#queue + 1] = cb end })
        ZenSpec.unload("modules/reader/annotations")
        Model = require("modules/reader/annotations")
        local session = Model.new({ document = { file = "current" }, annotation = { annotations = {} },
            doc_settings = doc_settings() })
        session:refreshCurrent()
        session.scope = "all"
        session:loadAll(function() end)
        assert.is_true(session.loading)
        assert.are.equal(0, #session:items("annotations"))
        queue[1]()
        assert.is_true(session.loaded)
        assert.are.equal(1, reads.other)
        assert.is_nil(reads.current)
        assert.is_nil(reads.missing)
        local items = session:items("highlights")
        assert.are.equal(1, #items)
        assert.are.equal("strikeout", items[1].style)
        assert.are.equal("red", items[1].color)
        assert.is_nil(legacy.bookmarks[1].drawer)
        local pins = session:items("pins")
        assert.are.equal(1, #pins)
        assert.are.equal("12", pins[1].page_label)
    end)

    it("lists pinned pages between the book note and annotations", function()
        floating = "Book note"
        local session = Model.new()
        session.books["book.pdf"] = Model.normalize("book.pdf", { { page = 4 } }, { title = "Book" },
            { { location = 7, page_label = "7", chapter = "Two" } })
        local items = session:items("annotations")
        assert.are.same({ "note", "pin", "bookmark" }, { items[1].kind, items[2].kind, items[3].kind })
        local pins = session:items("pins")
        assert.are.equal(1, #pins)
        assert.are.equal(7, pins[1].location)
        assert.are.equal("Two", pins[1].chapter)
        assert.is_false(Model.matches(pins[1], state(), "bookmarks"))
    end)

    it("cancels a queued all-books scan when the viewer closes", function()
        local queued, cancelled
        ZenSpec.replace("readhistory", { reload = function() end, hist = {} })
        ZenSpec.replace("ffi/util", { realpath = function(file) return file end })
        ZenSpec.replace("ui/uimanager", {
            nextTick = function(_self, callback) queued = callback end,
            unschedule = function(_self, callback) cancelled = callback end,
        })
        local session = Model.new({ document = { file = "current" } })
        session:loadAll(function() error("closed viewer updated") end)
        session:close()
        assert.are.equal(queued, cancelled)
        queued()
        assert.are.same({}, session.books)
    end)

    it("loads every history book when opened without a reader", function()
        ZenSpec.replace("docsettings", {
            findSidecarFile = function(_self, file) return file end,
            findCustomMetadataFile = function() end,
            openSettingsFile = function() return { data = { annotations = { { page = 1 } } } } end,
        })
        ZenSpec.replace("libs/libkoreader-lfs", { attributes = function() return "file" end })
        ZenSpec.replace("readhistory", { reload = function() end, hist = { { file = "first" }, { file = "second" } } })
        ZenSpec.replace("ffi/util", { realpath = function(file) return file end })
        ZenSpec.replace("ui/uimanager", { nextTick = function(_self, callback) callback() end })
        ZenSpec.unload("modules/reader/annotations")
        Model = require("modules/reader/annotations")
        local session = Model.new()
        session:refreshCurrent()
        session:loadAll(function() end)
        assert.are.equal("all", session.scope)
        assert.is_true(session.loaded)
        assert.are.equal(2, #session:items("annotations"))
    end)
end)
