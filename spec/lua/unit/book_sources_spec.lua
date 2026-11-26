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

    it("cancels ZenOS's opening banner when a source opens its book", function()
        local cancels = 0
        local original_cancel = rawget(_G, "__ZEN_UI_CANCEL_OPENING_BANNER")
        _G.__ZEN_UI_CANCEL_OPENING_BANNER = function() cancels = cancels + 1 end
        local handles = true
        BookSources.register("cloud", {
            books = function() return {} end,
            owns = function(path) return path:find("/cloud-", 1, true) ~= nil end,
            open = function() return handles end,
        })

        assert.is_true(BookSources.open("/books/cloud-1.epub"))
        assert.are.equal(1, cancels)
        handles = false
        assert.is_false(BookSources.open("/books/cloud-1.epub"))
        assert.is_false(BookSources.open("/books/local.epub"))
        assert.are.equal(1, cancels)
        _G.__ZEN_UI_CANCEL_OPENING_BANNER = original_cancel
    end)

    it("lets a source's handler open files and show ZenOS's dialog as usual", function()
        local nested_open, nested_menu
        BookSources.register("cloud", {
            books = function() return {} end,
            owns = function(path) return path:find("/cloud-", 1, true) ~= nil end,
            open = function(path)
                -- e.g. opening the downloaded file, or the same path again
                nested_open = BookSources.open(path)
                return true
            end,
            showContextMenu = function(_menu, item)
                -- e.g. FileChooser:showFileDialog() for ZenOS's own dialog
                nested_menu = BookSources.showContextMenu(nil, item)
                return true
            end,
        })

        assert.is_true(BookSources.open("/books/cloud-1.epub"))
        assert.is_false(nested_open)
        assert.is_true(BookSources.showContextMenu(nil, { path = "/books/cloud-1.epub" }))
        assert.is_false(nested_menu)
        -- And again afterwards: the guard doesn't stick.
        assert.is_true(BookSources.open("/books/cloud-1.epub"))
    end)

    it("clears the re-entry guard when a source's handler fails", function()
        local fail = true
        BookSources.register("cloud", {
            books = function() return {} end,
            owns = function() return true end,
            open = function() if fail then error("boom") end return true end,
            showContextMenu = function() if fail then error("boom") end return true end,
        })

        assert.is_false(BookSources.open("/books/a.epub"))
        assert.is_false(BookSources.showContextMenu(nil, { path = "/books/a.epub" }))
        fail = false
        assert.is_true(BookSources.open("/books/a.epub"))
        assert.is_true(BookSources.showContextMenu(nil, { path = "/books/a.epub" }))
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

    it("lists a library source's owned books in the given folders", function()
        kindle_books = { { file = "/kindle/book.azw3", info = { title = "K" } } }
        BookSources.register("cloud", {
            library = true,
            books = function()
                return {
                    { file = "/books/a.epub", info = { title = "A" },
                      attr = { size = 12, modification = 100 } },
                    { file = "/books/sub/b.epub", info = { title = "B" } },
                    { file = "/books/c.epub", info = { title = "C" } },
                    { file = "/other/d.epub", info = { title = "D" } },
                    { file = "/books/unowned.epub", info = { title = "U" } },
                }
            end,
            owns = function(path) return path ~= "/books/unowned.epub" end,
        })

        local books = BookSources.booksWithoutFile(
            { ["/books"] = true, ["/books/sub"] = true, ["/kindle"] = true },
            { ["/books/c.epub"] = true, ["/kindle/book.azw3"] = true })
        table.sort(books, function(a, b) return a.file < b.file end)

        assert.are.equal(2, #books)
        assert.are.same({
            file = "/books/a.epub", name = "a.epub", folder = "/books",
            attr = { mode = "file", size = 12, modification = 100, access = 100, change = 100 },
        }, books[1])
        assert.are.same({
            file = "/books/sub/b.epub", name = "b.epub", folder = "/books/sub",
            attr = { mode = "file", size = 0, modification = 0, access = 0, change = 0 },
        }, books[2])
        assert.are.same({}, BookSources.booksWithoutFile({}, {}))
        assert.are.same({}, BookSources.booksWithoutFile(nil))
    end)

    it("lists only library sources' books, whether or not the files present are known", function()
        BookSources.register("cloud", {
            library = true,
            books = function() return { { file = "/books/c.epub", info = { title = "C" } } } end,
            owns = function(path) return path == "/books/c.epub" end,
        })
        BookSources.register("mixed", {
            books = function() return { { file = "/books/m.epub", info = { title = "M" } } } end,
            owns = function() return true end,
        })
        local folders = { ["/books"] = true }

        local counted = BookSources.booksWithoutFile(folders)
        assert.are.equal(1, #counted)
        assert.are.equal("/books/c.epub", counted[1].file)
        local listed = BookSources.booksWithoutFile(folders, {})
        assert.are.equal(1, #listed, "not the other source's book, though the scan didn't find it")
        assert.are.equal("/books/c.epub", listed[1].file)
        assert.are.equal(0, #BookSources.booksWithoutFile(folders, { ["/books/c.epub"] = true }))
    end)

    it("asks a source again after its books lookup fails", function()
        local fail = true
        BookSources.register("cloud", {
            library = true,
            books = function()
                if fail then error("offline") end
                return { { file = "/books/a.epub", info = {} } }
            end,
            owns = function() return true end,
        })
        local folders = { ["/books"] = true }

        assert.are.equal(0, #BookSources.booksWithoutFile(folders))
        fail = false
        assert.are.equal(1, #BookSources.booksWithoutFile(folders))
    end)

    it("looks books up by folder, until the sources' books change", function()
        local calls, owns_calls = 0, 0
        local catalog = { { file = "/books/a.epub", info = {}, attr = { size = 1 } },
            { file = "/books/sub/b.epub", info = {} } }
        BookSources.register("cloud", {
            library = true,
            books = function() calls = calls + 1 return catalog end,
            owns = function() owns_calls = owns_calls + 1 return true end,
        })
        for _i = 1, 5 do
            assert.are.equal(1, #BookSources.booksWithoutFile({ ["/books"] = true }))
            assert.are.equal(1, #BookSources.booksWithoutFile({ ["/books/sub"] = true }))
        end
        assert.are.equal(1, calls)
        assert.are.equal(2, owns_calls)

        local first = BookSources.booksWithoutFile({ ["/books"] = true })[1]
        first.attr.access = 99 -- a caller may change its copy (folder covers do)
        assert.are.equal(0, BookSources.booksWithoutFile({ ["/books"] = true })[1].attr.access)

        catalog = { { file = "/books/c.epub", info = {} } }
        BookSources.changed()
        assert.are.equal("/books/c.epub", BookSources.booksWithoutFile({ ["/books"] = true })[1].file)
        assert.are.equal(2, calls)
    end)

    it("lists a library source's books only where it owns them", function()
        BookSources.register("cloud", {
            library = true,
            books = function()
                return { { file = "/books/c.epub", info = {} }, { file = "/books/gone.epub", info = {} } }
            end,
            owns = function(path) return path == "/books/c.epub" end,
        })
        local books = BookSources.booksWithoutFile({ ["/books"] = true })
        assert.are.equal(1, #books)
        assert.are.equal("/books/c.epub", books[1].file)
    end)

    describe("file browser selection", function()
        local FileManager, FileChooser, FileSearcher

        before_each(function()
            BookSources.register("cloud", {
                library = true,
                books = function() return {} end,
                owns = function(path) return path:find("/cloud/", 1, true) ~= nil end,
            })
            FileManager = {
                onToggleSelectMode = function(self)
                    if self.selected_files then self.selected_files = nil else self.selected_files = {} end
                    return true
                end,
            }
            FileChooser = {
                selectAllFilesInFolder = function(self, do_select)
                    for _i, item in ipairs(self.item_table) do
                        if item.is_file then
                            if do_select then
                                self.ui.selected_files[item.path] = true
                                item.dim = true
                            else
                                item.dim = nil
                            end
                        end
                    end
                    self.updated = (self.updated or 0) + 1
                end,
                updateItems = function(self) self.updated = (self.updated or 0) + 1 end,
            }
            FileSearcher = {
                setSelectMode = function(self)
                    if not self.selected_files then self.selected_files = {} end
                end,
            }
            ZenSpec.replace("apps/filemanager/filemanager", FileManager)
            ZenSpec.replace("ui/widget/filechooser", FileChooser)
            ZenSpec.replace("apps/filemanager/filemanagerfilesearcher", FileSearcher)
            assert.is_true(BookSources.installSelectionGuard())
        end)

        after_each(function()
            ZenSpec.unload("apps/filemanager/filemanager")
            ZenSpec.unload("ui/widget/filechooser")
            ZenSpec.unload("apps/filemanager/filemanagerfilesearcher")
        end)

        it("keeps them out of file search's selection, which goes to the file browser", function()
            local menu = { item_table = {
                { is_file = true, path = "/nowhere/cloud/a.epub" },
                { is_file = true, path = "/nowhere/local/b.epub" },
            } }
            menu.updateItems = function(self) self.updated = (self.updated or 0) + 1 end
            local searcher = setmetatable({ booklist_menu = menu }, { __index = FileSearcher })
            searcher:setSelectMode()

            -- KOReader's "Select all": dims and selects every file, then updates.
            for _i, item in ipairs(menu.item_table) do
                item.dim = true
                searcher.selected_files[item.path] = true
            end
            menu:updateItems(1, true)

            assert.is_nil(searcher.selected_files["/nowhere/cloud/a.epub"])
            assert.is_true(searcher.selected_files["/nowhere/local/b.epub"])
            assert.is_nil(menu.item_table[1].dim)
            assert.is_true(menu.item_table[2].dim)
            assert.are.equal(1, menu.updated)
        end)

        it("keeps books without a file out of the selection", function()
            assert.is_false(BookSources.selectable("/nowhere/cloud/a.epub"))
            assert.is_true(BookSources.selectable("/nowhere/local/b.epub"))

            local fm = setmetatable({}, { __index = FileManager })
            fm:onToggleSelectMode()
            fm.selected_files["/nowhere/cloud/a.epub"] = true
            fm.selected_files["/nowhere/local/b.epub"] = true
            assert.is_nil(fm.selected_files["/nowhere/cloud/a.epub"])
            assert.is_true(fm.selected_files["/nowhere/local/b.epub"])
            fm.selected_files["/nowhere/local/b.epub"] = nil
            assert.is_nil(next(fm.selected_files))
            fm:onToggleSelectMode()
            assert.is_nil(fm.selected_files)
        end)

        it("leaves them unselected and not dimmed when selecting all", function()
            local fm = setmetatable({}, { __index = FileManager })
            fm:onToggleSelectMode()
            local chooser = setmetatable({ ui = fm, item_table = {
                { is_file = true, path = "/nowhere/cloud/a.epub" },
                { is_file = true, path = "/nowhere/local/b.epub" },
                { path = "/nowhere/folder" },
            } }, { __index = FileChooser })

            chooser:selectAllFilesInFolder(true)

            assert.is_nil(chooser.item_table[1].dim)
            assert.is_true(chooser.item_table[2].dim)
            assert.is_nil(fm.selected_files["/nowhere/cloud/a.epub"])
            assert.is_true(fm.selected_files["/nowhere/local/b.epub"])
            assert.are.equal(2, chooser.updated)
        end)

        it("guards a selection table set directly, dropping such books already in it", function()
            local selection = BookSources.guardSelection({
                ["/nowhere/cloud/a.epub"] = true, ["/nowhere/local/b.epub"] = true,
            })
            assert.is_nil(selection["/nowhere/cloud/a.epub"])
            assert.is_true(selection["/nowhere/local/b.epub"])
            selection["/nowhere/cloud/c.epub"] = true
            assert.is_nil(selection["/nowhere/cloud/c.epub"])
            assert.is_nil(BookSources.guardSelection(nil))
        end)

        it("doesn't let a false entry for such a book become selected later", function()
            local selection = BookSources.guardSelection({ ["/nowhere/cloud/a.epub"] = false })
            assert.is_nil(rawget(selection, "/nowhere/cloud/a.epub"))
            selection["/nowhere/cloud/a.epub"] = true
            assert.is_nil(selection["/nowhere/cloud/a.epub"])
            selection["/nowhere/cloud/c.epub"] = false
            assert.is_nil(rawget(selection, "/nowhere/cloud/c.epub"))
            selection["/nowhere/cloud/c.epub"] = true
            assert.is_nil(selection["/nowhere/cloud/c.epub"])
            selection["/nowhere/local/b.epub"] = false
            assert.is_false(selection["/nowhere/local/b.epub"])
        end)
    end)

    describe("file search", function()
        local matched, catalog, searcher

        before_each(function()
            matched = {}
            catalog = {
                { file = "/books/Moby Dick.epub", info = { title = "Moby Dick" }, attr = { size = 7, modification = 50 } },
                { file = "/books/sub/Moby Two.epub", info = { title = "Moby Two" } },
                { file = "/books/.hidden/Moby Hidden.epub", info = {} },
                { file = "/books/Emma.epub", info = { title = "Emma" } },
                { file = "/books/Moby Local.epub", info = {} },
                { file = "/other/Moby Elsewhere.epub", info = {} },
                { file = "/books/Moby.txt", info = {} },
                { file = "/books/Moby Excluded.epub", info = {} },
            }
            ZenSpec.replace("util", { stringLower = string.lower })
            ZenSpec.replace("ui/widget/filechooser", {
                show_hidden = false,
                show_dir = function() return true end,
                show_file = function(_self, name) return not name:find("Excluded", 1, true) end,
            })
            ZenSpec.replace("document/documentregistry", {
                hasProvider = function(_self, path) return path:match("%.epub$") ~= nil end,
            })
            BookSources.register("cloud", {
                library = true,
                books = function() return catalog end,
                owns = function() return true end,
            })
            BookSources.register("mixed", {
                books = function() return { { file = "/books/Moby Mixed.epub", info = {} } } end,
                owns = function() return true end,
            })
            searcher = {
                include_content = true,
                no_metadata_count = 2,
                isFileMatch = function(self, name, path, query, is_file)
                    matched[#matched + 1] = { path = path, query = query, is_file = is_file,
                        content = self.include_content }
                    self.no_metadata_count = self.no_metadata_count + 1
                    return name:lower():find(query, 1, true) ~= nil
                end,
            }
        end)

        after_each(function()
            for _i, name in ipairs({ "ui/widget/filechooser", "document/documentregistry", "util" }) do
                ZenSpec.unload(name)
            end
        end)

        local function paths(entries)
            local out = {}
            for _i, entry in ipairs(entries) do out[#out + 1] = entry[2] end
            table.sort(out)
            return out
        end

        it("finds the library sources' matching books in the folder searched", function()
            local found = { ["/books/Moby Local.epub"] = true }
            local entries = BookSources.searchResults(searcher, "/books", "Moby", found)

            assert.are.same({ { "Moby Dick.epub", "/books/Moby Dick.epub",
                { mode = "file", size = 7, modification = 50, access = 50, change = 50 } } }, entries)
            assert.are.equal(2, searcher.no_metadata_count)
            assert.is_true(searcher.include_content)
            assert.is_true(#matched > 0)
            for _i, call in ipairs(matched) do
                assert.are.equal("moby", call.query)
                assert.is_true(call.is_file)
                assert.is_false(call.content)
            end
        end)

        it("searches subfolders as KOReader walks them", function()
            searcher.include_subfolders = true
            assert.are.same({ "/books/Moby Dick.epub", "/books/Moby Local.epub", "/books/sub/Moby Two.epub" },
                paths(BookSources.searchResults(searcher, "/books", "moby")))
            assert.are.equal(4, #BookSources.searchResults(searcher, "/", "moby"))
            assert.are.same({ "/other/Moby Elsewhere.epub" },
                paths(BookSources.searchResults(searcher, "/other", "moby")))
            assert.are.same({}, BookSources.searchResults(searcher, nil, "moby"))
        end)

        it("prepares the search text as KOReader's getList does", function()
            searcher.use_patterns = true
            BookSources.searchResults(searcher, "/books", "Mo?y*.epub")
            assert.are.equal("mo.y.*%.epub", matched[1].query)
        end)

        it("prepares wildcards only with patterns on, or on a KOReader without the option", function()
            searcher.use_patterns = false
            BookSources.searchResults(searcher, "/books", "Mo?y*.epub")
            assert.are.equal("mo?y*.epub", matched[1].query)
            matched = {}
            searcher.use_patterns = nil
            BookSources.searchResults(searcher, "/books", "Mo?y*.epub")
            assert.are.equal("mo.y.*%.epub", matched[1].query)
        end)

        it("puts the searcher back when matching fails", function()
            searcher.isFileMatch = function() error("matching failed") end
            assert.has_error(function() BookSources.searchResults(searcher, "/books", "moby") end)
            assert.is_true(searcher.include_content)
            assert.are.equal(2, searcher.no_metadata_count)
        end)

        it("builds the folder index ahead of a search", function()
            local calls = 0
            BookSources.register("cloud", {
                library = true,
                books = function() calls = calls + 1 return catalog end,
                owns = function() return true end,
            })
            BookSources.prepareFolderIndex()
            assert.are.equal(1, calls)
            BookSources.searchResults(searcher, "/books", "moby")
            assert.are.equal(1, calls)
        end)
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

    describe("library sources' metadata", function()
        local queries

        before_each(function()
            queries = 0
            ZenSpec.replace("bookinfomanager", {
                getBookInfo = function() return nil end,
                getDocProps = function(_self, path)
                    queries = queries + 1
                    if path == "/books/local.epub" then return { title = "Local" } end
                end,
            })
            BookSources.register("cloud", {
                library = true,
                books = function() return { { file = "/books/c.epub", info = {} } } end,
                owns = function(path) return path == "/books/c.epub" end,
                bookInfo = function(path)
                    if path == "/books/c.epub" then
                        return { title = "Cloud", authors = "A", series = "S", series_index = 2 }
                    end
                end,
            })
            assert.is_true(BookSources.installMetadataIntegration())
        end)

        after_each(function()
            ZenSpec.unload("bookinfomanager")
        end)

        it("answers getDocProps without CoverBrowser's database", function()
            local BookInfoManager = require("bookinfomanager")
            local props = BookInfoManager:getDocProps("/books/c.epub")
            assert.are.equal("Cloud", props.title)
            assert.are.equal(0, queries)
            assert.are.equal("Local", BookInfoManager:getDocProps("/books/local.epub").title)
            assert.are.equal(1, queries)
        end)

        it("gives list items their metadata, with display_title", function()
            local props = BookSources.docProps("/books/c.epub")
            assert.are.same({ title = "Cloud", authors = "A", series = "S", series_index = 2,
                display_title = "Cloud" }, props)
            assert.is_nil(BookSources.docProps("/books/local.epub"))
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

    it("tells a library source's books without asking the file system", function()
        local looked = 0
        ZenSpec.replace("util", { fileExists = function() looked = looked + 1; return false end })
        BookSources.register("cloud", {
            library = true,
            books = function() return {} end,
            owns = function(path) return path:sub(1, 3) == "/c/" end,
        })
        BookSources.register("kindle", {
            books = function() return {} end,
            owns = function(path) return path:sub(1, 3) == "/k/" end,
        })

        assert.is_true(BookSources.isLibraryBook("/c/catalog.epub"))
        assert.is_false(BookSources.isLibraryBook("/k/owned.azw3"), "an owning source that isn't a library source")
        assert.is_false(BookSources.isLibraryBook("/books/local.epub"))
        assert.is_false(BookSources.isLibraryBook(nil))
        assert.are.equal(0, looked)
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

        it("keeps a book's attr when it shows edits over its metadata", function()
            BookSources.register("cloud", {
                library = true,
                books = function()
                    return { { file = "/c/book.epub", info = source_info, attr = { size = 7 } } }
                end,
                owns = function() return true end,
                bookInfo = function(path) if path == "/c/book.epub" then return source_info end end,
            })
            custom["/c/book.epub"] = { title = "Edited" }
            assert.is_true(BookSources.metadataEdited("/c/book.epub"))
            local book = BookSources.books()[1]
            assert.are.equal("Edited", book.info.title)
            assert.are.same({ size = 7 }, book.attr)
            assert.are.equal(7, BookSources.booksWithoutFile({ ["/c"] = true }, {})[1].attr.size)
        end)

        it("shows edits made in ZenOS over a source's metadata", function()
            assert.is_true(BookSources.suppliesMetadata("/c/book.epub"))
            assert.is_false(BookSources.suppliesMetadata("/c/other.epub"))
            -- Looked up once per session; later edits wait to be announced
            -- (an edit in ZenOS, or InvalidateMetadataCache).
            assert.are.equal("Source", BookSources.bookInfo("/c/book.epub", true).title)
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

        it("treats every book as source-supplied while a lookup fails", function()
            local fail = false
            BookSources.register("flaky", {
                books = function() return {} end,
                bookInfo = function(path)
                    if fail then error("offline") end
                    if path == "/f/seen.epub" then return { title = "Seen" } end
                end,
            })
            assert.is_true(BookSources.suppliesMetadata("/f/seen.epub"))
            -- A lookup that completes without a source keeps embedded editing.
            assert.is_false(BookSources.suppliesMetadata("/f/plain.epub"))
            fail = true
            -- A failed lookup can't rule a source out: edits stay in the sidecar,
            -- even for a book with no record of being a source's.
            assert.is_true(BookSources.suppliesMetadata("/f/seen.epub"))
            assert.is_true(BookSources.suppliesMetadata("/f/plain.epub"))
            BookSources.unregister("flaky")
        end)

        it("shows custom metadata written elsewhere once it's announced", function()
            -- Written by KOReader's Book information or a sync plugin, which
            -- send InvalidateMetadataCache for the book.
            assert.are.equal("Source", BookSources.bookInfo("/c/book.epub", true).title)
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

        it("finds custom metadata that was never announced", function()
            -- Written before ZenOS tracked it: found the first time the
            -- book's cover is asked for, and groupings are rebuilt.
            custom["/c/book.epub"] = { title = "Old edit" }
            assert.are.equal("Source", BookSources.books()[1].info.title)
            -- Metadata-only lookups (sort, grouping, search) don't look.
            assert.are.equal("Source", BookSources.bookInfo("/c/book.epub", false).title)
            assert.are.same({}, G_reader_settings:readSetting("zen_book_sources_edited") or {})
            local revision = BookSources.revision()
            -- A view is drawing the book with its edits: none is told.
            local told = 0
            BookSources.onChanged(function() told = told + 1 end)
            assert.are.equal("Old edit", BookSources.bookInfo("/c/book.epub", true).title)
            assert.is_true(BookSources.revision() > revision)
            assert.are.equal(0, told)
            assert.are.equal("Old edit", BookSources.books()[1].info.title)
            assert.are.same({ ["/c/book.epub"] = true },
                G_reader_settings:readSetting("zen_book_sources_edited"))
            -- Not looked for again this session.
            revision = BookSources.revision()
            BookSources.bookInfo("/c/book.epub", true)
            assert.are.equal(revision, BookSources.revision())
        end)
    end)

    describe("views", function()
        local reports
        before_each(function()
            reports = {}
            BookSources.revision() -- the built-in sources register first
            BookSources.onChanged(function(paths, kind)
                reports[#reports + 1] = { paths = paths, kind = kind }
            end)
        end)

        it("are told when sources report changes", function()
            local second = 0
            BookSources.onChanged(function() second = second + 1 end)
            BookSources.changed({ "/c/a.epub" })
            BookSources.changed()
            BookSources.statusChanged()
            BookSources.historyChanged({ "/c/b.epub" })
            BookSources.historyChanged()
            assert.are.same({
                { paths = { "/c/a.epub" }, kind = "books" },
                { kind = "books" },
                { kind = "status" },
                { paths = { "/c/b.epub" }, kind = "history" },
                { kind = "history" },
            }, reports)
            assert.are.equal(5, second)
        end)

        it("are told when a source comes or goes", function()
            BookSources.register("cloud", { books = function() return {} end })
            BookSources.unregister("cloud")
            assert.are.equal(2, #reports)
        end)

        it("doesn't move the revisions on a history change", function()
            local revision, status = BookSources.revision(), BookSources.statusRevision()
            BookSources.historyChanged({ "/c/a.epub" })
            assert.are.equal(revision, BookSources.revision())
            assert.are.equal(status, BookSources.statusRevision())
        end)

        it("keep working when one fails", function()
            BookSources.onChanged(function() error("boom") end)
            local revision = BookSources.revision()
            BookSources.changed({ "/c/a.epub" })
            assert.is_true(BookSources.revision() > revision)
            assert.are.equal(1, #warnings)
            -- The others are still told.
            assert.are.equal(1, #reports)
        end)

        it("tells whether Home is on top", function()
            local on_top = false
            BookSources.setHome({ isActiveOnTop = function() return on_top end })
            assert.is_false(BookSources.isHomeOnTop())
            on_top = true
            assert.is_true(BookSources.isHomeOnTop())
            BookSources.setHome(nil)
            assert.is_false(BookSources.isHomeOnTop())
        end)

        it("counts a start on Home behind a hidden file browser as on top", function()
            BookSources.setHome({ isActiveOnTop = function() return false end })
            local fm = { invisible = true, _zen_hidden_home_startup = true }
            local real = package.loaded["apps/filemanager/filemanager"]
            finally(function() package.loaded["apps/filemanager/filemanager"] = real end)
            ZenSpec.replace("apps/filemanager/filemanager", { instance = fm })
            assert.is_true(BookSources.isHomeOnTop())
            fm._zen_hidden_home_startup = nil -- hidden for another reason
            assert.is_false(BookSources.isHomeOnTop())
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
