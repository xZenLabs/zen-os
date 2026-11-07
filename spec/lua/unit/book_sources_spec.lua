describe("book sources", function()
    local BookSources, warnings, kindle_books

    before_each(function()
        warnings = {}
        kindle_books = {}
        ZenSpec.replace("common/zen_logger", {
            now = function() return 0 end,
            new = function()
                return { warn = function(...) warnings[#warnings + 1] = { ... } end }
            end,
        })
        ZenSpec.replace("common/book_sources_kindle", {
            books = function() return kindle_books end,
            owns = function(path) return path == "/kindle/book.azw3" end,
            showContextMenu = function() return true end,
        })
        ZenSpec.unload("common/book_sources")
        BookSources = require("common/book_sources")
    end)

    it("lists the built-in Kindle source first, then registered sources", function()
        kindle_books = { { file = "/kindle/book.azw3", info = { title = "K" } } }
        BookSources.register("cloud", {
            books = function()
                return { { file = "/books/cloud-1.epub", info = { title = "C" } } }
            end,
        })

        local books = BookSources.books()
        assert.are.equal(2, #books)
        assert.are.equal("/kindle/book.azw3", books[1].file)
        assert.are.equal("/books/cloud-1.epub", books[2].file)
    end)

    it("rejects invalid sources and skips malformed books", function()
        assert.is_false(BookSources.register("", { books = function() return {} end }))
        assert.is_false(BookSources.register("nobooks", {}))
        BookSources.register("messy", {
            books = function()
                return { { file = "" , info = {} }, { file = "/a.epub" }, "x",
                    { file = "/ok.epub", info = { title = "OK" } } }
            end,
        })

        local books = BookSources.books()
        assert.are.equal(1, #books)
        assert.are.equal("/ok.epub", books[1].file)
    end)

    it("keeps other sources working when one fails", function()
        BookSources.register("broken", {
            books = function() error("catalog unavailable") end,
            owns = function() error("owns failed") end,
        })
        BookSources.register("cloud", {
            books = function() return { { file = "/c.epub", info = {} } } end,
            owns = function(path) return path == "/c.epub" end,
            open = function() return true end,
        })

        assert.are.equal(1, #BookSources.books())
        assert.is_true(BookSources.open("/c.epub"))
        assert.is_true(#warnings >= 2)
    end)

    it("dispatches open and long-press to the source that owns the path", function()
        local opened, held
        BookSources.register("cloud", {
            books = function() return {} end,
            owns = function(path) return path:find("/cloud-", 1, true) ~= nil end,
            open = function(path, ui) opened = { path, ui } return true end,
            showContextMenu = function(_menu, item) held = item return true end,
        })

        assert.is_true(BookSources.open("/books/cloud-1.epub", "fm"))
        assert.are.same({ "/books/cloud-1.epub", "fm" }, opened)
        assert.is_false(BookSources.open("/books/local.epub"))

        local item = { path = "/books/cloud-2.epub" }
        assert.is_true(BookSources.showContextMenu("menu", item, function() end))
        assert.are.equal(item, held)
        assert.is_true(BookSources.showContextMenu("menu", { path = "/kindle/book.azw3" }))
        assert.is_false(BookSources.showContextMenu("menu", { path = "/books/local.epub" }))
    end)

    it("does not open books whose source has no open handler", function()
        BookSources.register("listed_only", {
            books = function() return {} end,
            owns = function() return true end,
        })
        assert.is_false(BookSources.open("/books/a.epub"))
    end)

    it("changes revision when sources change", function()
        local first = BookSources.revision()
        BookSources.register("cloud", { books = function() return {} end })
        local registered = BookSources.revision()
        BookSources.changed()
        local changed = BookSources.revision()
        BookSources.unregister("cloud")

        assert.is_true(registered > first)
        assert.is_true(changed > registered)
        assert.is_true(BookSources.revision() > changed)
    end)
end)
