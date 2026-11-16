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

    it("signals status changes without changing the books revision", function()
        local books, statuses = BookSources.revision(), BookSources.statusRevision()
        BookSources.statusChanged()
        assert.are.equal(books, BookSources.revision())
        assert.is_true(BookSources.statusRevision() > statuses)
        local after_status = BookSources.statusRevision()
        BookSources.changed()
        assert.is_true(BookSources.statusRevision() > after_status)
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

    it("gives the first valid reading status a source has for a book", function()
        BookSources.register("broken", {
            books = function() return {} end,
            status = function() error("offline") end,
        })
        BookSources.register("odd", {
            books = function() return {} end,
            status = function(path)
                if path == "/c/odd.epub" then return { status = "loved" } end
            end,
        })
        BookSources.register("cloud", {
            books = function() return {} end,
            status = function(path)
                if path == "/c/read.epub" then return { status = "complete", extra = 1 } end
                if path == "/c/odd.epub" then return { status = "loved", percent_finished = 1.5 } end
            end,
        })

        assert.are.same({ status = "complete" }, BookSources.status("/c/read.epub"))
        assert.are.same({ percent_finished = 1 }, BookSources.status("/c/odd.epub"))
        assert.is_nil(BookSources.status("/c/unknown.epub"))
        BookSources.register("dated", {
            books = function() return {} end,
            status = function(path)
                if path == "/c/stamp.epub" then
                    return { status = "complete", finished_at = os.time({ year = 2026, month = 3, day = 4, hour = 12 }) }
                end
                if path == "/c/day.epub" then
                    return { status = "complete", finished_at = "2026-05-06 10:00:00" }
                end
                if path == "/c/junk.epub" then return { status = "complete", finished_at = "soon" } end
            end,
        })
        assert.are.equal("2026-03-04", BookSources.status("/c/stamp.epub").finished_at)
        assert.are.equal("2026-05-06", BookSources.status("/c/day.epub").finished_at)
        assert.are.same({ status = "complete" }, BookSources.status("/c/junk.epub"))
        assert.is_nil(BookSources.status(nil))
        assert.is_true(#warnings >= 1)
    end)

    it("gives a source's star rating, with or without a status", function()
        BookSources.register("cloud", {
            books = function() return {} end,
            status = function(path)
                if path == "/c/rated.epub" then return { rating = 3.6 } end
                if path == "/c/read.epub" then return { status = "complete", rating = 5 } end
                if path == "/c/odd.epub" then return { status = "reading", rating = 9 } end
                if path == "/c/zero.epub" then return { rating = 0 } end
            end,
        })

        assert.are.equal(4, BookSources.rating("/c/rated.epub"))
        assert.is_nil(BookSources.status("/c/rated.epub"))
        assert.are.equal(5, BookSources.rating("/c/read.epub"))
        assert.are.same({ status = "complete", rating = 5 }, BookSources.status("/c/read.epub"))
        assert.is_nil(BookSources.rating("/c/odd.epub"))
        assert.is_nil(BookSources.rating("/c/zero.epub"))
        assert.is_nil(BookSources.rating("/c/unknown.epub"))
    end)

    describe("history", function()
        local saved

        before_each(function()
            saved = G_reader_settings:readSetting("zen_book_sources_dismissed_history")
            G_reader_settings:delSetting("zen_book_sources_dismissed_history")
        end)

        after_each(function()
            G_reader_settings:saveSetting("zen_book_sources_dismissed_history", saved)
        end)

        local function register_cloud(entries)
            BookSources.register("broken", {
                books = function() return {} end,
                history = function() error("offline") end,
            })
            BookSources.register("cloud", {
                books = function() return {} end,
                history = function() return entries end,
            })
            BookSources.register("other", {
                books = function() return {} end,
                history = function() return { { file = "/c/b.epub", time = 999 } } end,
            })
        end

        it("lists the sources' history newest first, one entry per book", function()
            register_cloud({
                { file = "/c/a.epub", time = 100 },
                { file = "/c/b.epub", time = "300" },
                { file = "/c/bad.epub" }, { time = 5 }, "junk",
            })

            assert.are.same({
                { file = "/c/b.epub", time = 300 },
                { file = "/c/a.epub", time = 100 },
            }, BookSources.history())
        end)

        it("merges it into this device's history, which keeps its own entries", function()
            local hist = { { file = "/local/new.epub", time = 400 },
                { file = "/c/a.epub", time = 250 }, { file = "/local/old.epub", time = 50 } }
            assert.are.equal(hist, BookSources.mergeHistory(hist))

            register_cloud({ { file = "/c/a.epub", time = 500 }, { file = "/c/b.epub", time = 300 },
                { file = "/c/c.epub", time = 10 } })
            local files = {}
            for _i, entry in ipairs(BookSources.mergeHistory(hist)) do
                files[#files + 1] = entry.file .. "@" .. entry.time
            end
            assert.are.same({ "/local/new.epub@400", "/c/b.epub@300", "/c/a.epub@250",
                "/local/old.epub@50", "/c/c.epub@10" }, files)
            assert.are.equal(3, #BookSources.mergeHistory(nil))
        end)

        it("hides a removed entry until the source gives a later time", function()
            local entries = { { file = "/c/a.epub", time = 100 }, { file = "/c/gone.epub", time = 90 } }
            register_cloud(entries)
            assert.is_false(BookSources.dismissHistory("/c/unknown.epub"))
            assert.is_true(BookSources.dismissHistory("/c/gone.epub"))
            local statuses = BookSources.statusRevision()
            assert.is_true(BookSources.dismissHistory("/c/a.epub"))
            assert.is_true(BookSources.statusRevision() > statuses)
            assert.are.same({ { file = "/c/b.epub", time = 999 } }, BookSources.history())

            -- While a source's history fails, no dismissal is dropped: the
            -- failed source may still list the book.
            table.remove(entries, 2)
            assert.is_true(BookSources.dismissHistory("/c/b.epub"))
            assert.are.same({ ["/c/a.epub"] = 100, ["/c/b.epub"] = 999, ["/c/gone.epub"] = 90 },
                G_reader_settings:readSetting("zen_book_sources_dismissed_history"))

            -- Once every source lists its history, dismissals of books no
            -- source lists any more are dropped.
            BookSources.unregister("broken")
            entries[#entries + 1] = { file = "/c/d.epub", time = 200 }
            assert.is_true(BookSources.dismissHistory("/c/d.epub"))
            assert.are.same({ ["/c/a.epub"] = 100, ["/c/b.epub"] = 999, ["/c/d.epub"] = 200 },
                G_reader_settings:readSetting("zen_book_sources_dismissed_history"))

            entries[1].time = 150
            assert.are.same({ { file = "/c/a.epub", time = 150 } }, BookSources.history())
        end)
    end)

    it("tells which owned books have no file on the device", function()
        ZenSpec.replace("util", {
            fileExists = function(path) return path == "/c/downloaded.epub" end,
        })
        BookSources.register("cloud", {
            books = function() return {} end,
            owns = function(path) return path:sub(1, 3) == "/c/" end,
        })

        assert.is_true(BookSources.ownsWithoutFile("/c/catalog.epub"))
        assert.is_false(BookSources.ownsWithoutFile("/c/downloaded.epub"))
        assert.is_false(BookSources.ownsWithoutFile("/books/missing.epub"))
        assert.is_false(BookSources.ownsWithoutFile(nil))
    end)

    describe("metadata edits", function()
        local custom, saved_edited, source_info

        before_each(function()
            custom = {}
            saved_edited = G_reader_settings:readSetting("zen_book_sources_edited")
            G_reader_settings:delSetting("zen_book_sources_edited")
            ZenSpec.replace("docsettings", {
                findCustomMetadataFile = function(_self, path)
                    if custom[path] then return path .. ".sdr/custom_metadata.lua" end
                end,
                openSettingsFile = function(file)
                    local path = file:match("^(.*)%.sdr/")
                    return { readSetting = function(_self, key)
                        if key == "custom_props" then return custom[path] end
                    end }
                end,
            })
            source_info = { title = "Source", authors = "A", series = "S" }
            BookSources.register("cloud", {
                books = function() return { { file = "/c/book.epub", info = source_info } } end,
                bookInfo = function(path) if path == "/c/book.epub" then return source_info end end,
            })
        end)

        after_each(function()
            G_reader_settings:saveSetting("zen_book_sources_edited", saved_edited)
        end)

        it("shows edits made in ZenOS over a source's metadata", function()
            assert.is_true(BookSources.suppliesMetadata("/c/book.epub"))
            assert.is_false(BookSources.suppliesMetadata("/c/other.epub"))
            -- Custom metadata isn't looked up until it's announced (an edit
            -- in ZenOS, or InvalidateMetadataCache from KOReader or a plugin).
            custom["/c/book.epub"] = { title = "Edited", publisher = "P" }
            assert.are.equal("Source", BookSources.bookInfo("/c/book.epub").title)

            local revision = BookSources.revision()
            assert.is_true(BookSources.metadataEdited("/c/book.epub"))
            assert.is_false(BookSources.metadataEdited("/c/other.epub"))
            assert.is_true(BookSources.revision() > revision)

            local info = BookSources.bookInfo("/c/book.epub")
            assert.are.same({ title = "Edited", authors = "A", series = "S" }, info)
            assert.are.same({ title = "Edited", authors = "A", series = "S" },
                BookSources.books()[1].info)
            -- The source's own table is left alone.
            assert.are.equal("Source", source_info.title)

            -- Read on each lookup: a later change to the sidecar shows at once.
            custom["/c/book.epub"] = { authors = "B" }
            assert.are.same({ title = "Source", authors = "B", series = "S" },
                BookSources.bookInfo("/c/book.epub"))

            -- Edits cleared in the editor: shown no more, and the book leaves the list.
            custom["/c/book.epub"] = nil
            assert.is_true(BookSources.metadataEdited("/c/book.epub"))
            assert.are.equal("Source", BookSources.bookInfo("/c/book.epub").title)
            assert.are.same({}, G_reader_settings:readSetting("zen_book_sources_edited"))
        end)

        it("shows custom metadata written elsewhere once it's announced", function()
            -- Written by KOReader's Book information or a sync plugin, which
            -- send InvalidateMetadataCache for the book.
            custom["/c/book.epub"] = { title = "Synced" }
            assert.are.equal("Source", BookSources.bookInfo("/c/book.epub").title)
            local revision = BookSources.revision()
            assert.is_true(BookSources.customMetadataChanged("/c/book.epub"))
            assert.is_true(BookSources.revision() > revision)
            assert.are.equal("Synced", BookSources.bookInfo("/c/book.epub").title)
            assert.are.equal("Synced", BookSources.books()[1].info.title)
            -- Not a source's book: nothing kept, nothing rebuilt.
            custom["/elsewhere/book.epub"] = { title = "Mine" }
            revision = BookSources.revision()
            assert.is_false(BookSources.customMetadataChanged("/elsewhere/book.epub"))
            assert.are.equal(revision, BookSources.revision())
            assert.are.same({ ["/c/book.epub"] = true },
                G_reader_settings:readSetting("zen_book_sources_edited"))
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
