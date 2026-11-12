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
            bookInfo = function(path)
                if path == "/kindle/book.azw3" then return { title = "K", authors = "A" } end
            end,
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

    it("reports whether any source owns a path", function()
        BookSources.register("cloud", {
            books = function() return {} end,
            owns = function(path) return path == "/books/cloud-1.epub" end,
        })
        assert.is_true(BookSources.owns("/books/cloud-1.epub"))
        assert.is_true(BookSources.owns("/kindle/book.azw3"))
        assert.is_false(BookSources.owns("/books/local.epub"))
        assert.is_false(BookSources.owns(nil))
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

    describe("metadata", function()
        local BookInfoManager, db_rows, cover_drops

        before_each(function()
            db_rows = {
                ["/books/local.epub"] = { title = "Local", series = "S" },
                ["/kindle/book.azw3"] = { title = "Old", series = "KS", description = "D" },
            }
            BookInfoManager = {
                getBookInfo = function(_self, path, get_cover)
                    local row = db_rows[path]
                    return row and { title = row.title, from_db = true, get_cover = get_cover }
                end,
                getDocProps = function(_self, path)
                    local row = db_rows[path]
                    if not row then return nil end
                    local props = {}
                    for k, v in pairs(row) do props[k] = v end
                    return props
                end,
            }
            ZenSpec.replace("bookinfomanager", BookInfoManager)
            cover_drops = {}
            local function cache(name)
                return { drop = function(_self, path) cover_drops[#cover_drops + 1] = name .. ":" .. path end }
            end
            ZenSpec.replace("common/cover_decode_cache", cache("decode"))
            ZenSpec.replace("common/cover_render_cache", cache("render"))
        end)

        after_each(function()
            ZenSpec.unload("bookinfomanager")
            ZenSpec.unload("common/cover_decode_cache")
            ZenSpec.unload("common/cover_render_cache")
        end)

        it("answers getBookInfo for sources' books and falls through for others", function()
            local asked
            BookSources.register("cloud", {
                books = function() return {} end,
                bookInfo = function(path, get_cover)
                    asked = get_cover
                    if path == "/books/cloud-1.epub" then return { title = "Cloud" } end
                end,
            })
            assert.is_true(BookSources.installMetadataIntegration())
            assert.is_true(BookSources.installMetadataIntegration()) -- once only

            assert.are.equal("Cloud", BookInfoManager:getBookInfo("/books/cloud-1.epub", true).title)
            assert.is_true(asked)
            assert.are.equal("K", BookInfoManager:getBookInfo("/kindle/book.azw3").title)
            local info = BookInfoManager:getBookInfo("/books/local.epub", true)
            assert.is_true(info.from_db)
            assert.is_true(info.get_cover)
            assert.is_nil(BookInfoManager:getBookInfo("/books/missing.epub"))
        end)

        it("sends a source's own getBookInfo calls to the database", function()
            BookSources.register("wrapper", {
                books = function() return {} end,
                bookInfo = function(path)
                    if path ~= "/books/local.epub" then return nil end
                    local stored = BookInfoManager:getBookInfo(path)
                    return { title = stored.title .. "+" }
                end,
            })
            BookSources.installMetadataIntegration()
            assert.are.equal("Local+", BookInfoManager:getBookInfo("/books/local.epub").title)
        end)

        it("skips a failing source", function()
            BookSources.register("broken", {
                books = function() return {} end,
                bookInfo = function() error("no catalog") end,
            })
            BookSources.installMetadataIntegration()
            assert.is_true(BookInfoManager:getBookInfo("/books/local.epub").from_db)
            assert.is_true(#warnings >= 1)
        end)

        it("answers getDocProps, keeping database fields the source doesn't give", function()
            BookSources.register("cloud", {
                books = function() return {} end,
                bookInfo = function(path)
                    if path == "/books/cloud-1.epub" then
                        return { title = "Cloud", series = "CS", cover_bb = {} }
                    end
                end,
            })
            BookSources.installMetadataIntegration()

            assert.are.same({ title = "Cloud", series = "CS" },
                BookInfoManager:getDocProps("/books/cloud-1.epub"))
            assert.are.same({ title = "K", authors = "A", series = "KS", description = "D" },
                BookInfoManager:getDocProps("/kindle/book.azw3"))
            assert.are.same({ title = "Local", series = "S" },
                BookInfoManager:getDocProps("/books/local.epub"))
        end)

        it("drops cached covers for the paths passed to changed()", function()
            local before = BookSources.revision()
            BookSources.changed({ "/books/cloud-1.epub" })
            assert.is_true(BookSources.revision() > before)
            assert.are.same({ "decode:/books/cloud-1.epub", "render:/books/cloud-1.epub" }, cover_drops)
            BookSources.changed()
            assert.are.equal(2, #cover_drops)
        end)
    end)

    it("joins the listing keys of sources that show books in a folder", function()
        assert.are.equal("", BookSources.listingKey("/books"))
        BookSources.register("cloud", {
            books = function() return {} end,
            listingKey = function(folder) if folder == "/books" then return "v7" end end,
        })
        BookSources.register("other", {
            books = function() return {} end,
            listingKey = function(folder) if folder == "/books" then return 3 end end,
        })
        BookSources.register("broken", {
            books = function() return {} end,
            listingKey = function() error("boom") end,
        })
        assert.are.equal("cloud=v7\31other=3", BookSources.listingKey("/books"))
        assert.are.equal("", BookSources.listingKey("/elsewhere"))
    end)
end)
