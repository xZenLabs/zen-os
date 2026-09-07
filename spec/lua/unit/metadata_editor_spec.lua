describe("metadata editor from Book Details", function()
    local BookInfo
    local Editor
    local Service
    local shown
    local messages
    local saved
    local restored
    local confirmation
    local custom_cover
    local cover_chooser
    local cover_picker
    local previous_plugin

    before_each(function()
        shown = nil
        messages = {}
        saved = nil
        restored = nil
        confirmation = nil
        custom_cover = nil
        cover_chooser = nil
        cover_picker = nil
        previous_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        _G.__ZEN_UI_PLUGIN = { config = { metadata = {
            hardcover_enabled = true,
            google_books_enabled = false,
            open_library_enabled = false,
            hardcover_auto_match = false,
            epub_backup = false,
        } } }

        BookInfo = {
            show = function() return "stock details" end,
            ui = {
                showOpenWithDialog = function(_self, file)
                    assert.are.equal("/books/test.epub", file)
                end,
                renameFile = function(_self, file, basename)
                    local ffiUtil = require("ffi/util")
                    os.rename(file, ffiUtil.joinPath(ffiUtil.dirname(file), basename))
                end,
            },
            setCustomCoverFromImage = function(_self, file, image)
                assert.are.equal("/books/test.epub", file)
                custom_cover = image
            end,
        }
        Editor = {
            show = function(options)
                shown = options
                return { editor = true }
            end,
        }
        Service = {
            load = function(file)
                assert.are.equal("/books/test.epub", file)
                return {
                    title = "Test title",
                    authors = { "Test author" },
                    series_name = "Test series",
                    series_index = "2",
                }
            end,
            save = function(file, draft, options)
                saved = { file = file, draft = draft, options = options }
                return true
            end,
            restore = function(file)
                restored = file
                return true
            end,
            isEpub = function(file) return file:sub(-5) == ".epub" end,
            canRestore = function() return true end,
            moveEpubBackup = function() return true, false end,
        }

        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("apps/filemanager/filemanagerbookinfo", BookInfo)
        ZenSpec.replace("modules/filebrowser/metadata_editor", Editor)
        ZenSpec.replace("modules/filebrowser/metadata/service", Service)
        ZenSpec.replace("config/hardcover_token", { get = function() return "" end })
        ZenSpec.replace("docsettings", {
            findCustomCoverFile = function()
                return custom_cover and "/covers/cover.jpg" or nil
            end,
        })
        ZenSpec.replace("ui/widget/infomessage", {
            new = function(_self, options) return options end,
        })
        ZenSpec.replace("ui/widget/confirmbox", {
            new = function(_self, options)
                confirmation = options
                return options
            end,
        })
        ZenSpec.replace("ui/widget/pathchooser", {
            new = function(_self, options)
                cover_chooser = options
                return options
            end,
        })
        ZenSpec.replace("common/ui/zen_menu_picker", function(options)
            cover_picker = options
            return options
        end)
        ZenSpec.replace("document/documentregistry", {
            isImageFile = function(_self, filename)
                return filename:sub(-4) == ".jpg"
            end,
            openDocument = function()
                return {
                    getCoverPageImage = function()
                        return { free = function() end }
                    end,
                    close = function() end,
                }
            end,
        })
        ZenSpec.replace("ui/renderimage", {
            renderImageFile = function()
                return { free = function() end }
            end,
        })
        ZenSpec.replace("ui/uimanager", {
            show = function(_self, widget) messages[#messages + 1] = widget.text end,
            close = function() end,
            forceRePaint = function() end,
            nextTick = function(_self, callback) callback() end,
        })
        ZenSpec.unload("modules/filebrowser/patches/metadata_editor")
        require("modules/filebrowser/patches/metadata_editor")()
    end)

    after_each(function()
        _G.__ZEN_UI_PLUGIN = previous_plugin
        ZenSpec.unload("modules/filebrowser/patches/metadata_editor")
    end)

    it("opens the dedicated editor without changing stock BookInfo.show", function()
        local saved_callback = 0
        local restored_callback = 0
        local hardcover_callback = function() end
        local close_parent_callback = function() end
        local result = BookInfo:showFromBookDetails({
            readSetting = function(_self, key)
                assert.are.equal("doc_path", key)
                return "/books/test.epub"
            end,
        }, nil, {
            on_hardcover = hardcover_callback,
            close_parent_callback = close_parent_callback,
            on_saved = function(file, draft)
                assert.are.equal("/books/test.epub", file)
                assert.are.equal("Changed", draft.title)
                saved_callback = saved_callback + 1
            end,
            on_restored = function(file)
                assert.are.equal("/books/test.epub", file)
                restored_callback = restored_callback + 1
            end,
        })

        assert.is_true(result.editor)
        assert.are.equal("stock details", BookInfo:show("/books/test.epub"))
        assert.are.equal("/books/test.epub", shown.file)
        assert.are.equal("Test title", shown.metadata.title)
        assert.are.equal("Test series", shown.metadata.series_name)
        assert.is_true(shown.is_epub)
        assert.is_true(shown.can_restore)
        assert.is_false(shown.has_custom_cover)
        assert.are.equal(hardcover_callback, shown.on_hardcover)
        assert.are.equal(close_parent_callback, shown.on_close_all)
        assert.is_function(shown.on_open_with)
        assert.is_function(shown.on_cover)
        assert.is_function(shown.on_rename)

        local draft = { title = "Changed" }
        local completed
        local restore_available
        local editor = {
            file = "/books/test.epub",
            cancelSave = function() end,
            isMetadataDirty = function() return true end,
            getPendingCover = function() end,
            setRestoreAvailable = function(_self, available)
                restore_available = available
            end,
            completeSave = function(_self, ok, err) completed = { ok, err } end,
        }
        assert.is_nil(shown.on_save(draft, editor))
        assert.is_table(confirmation)
        confirmation.ok_callback()
        assert.are.same({
            file = "/books/test.epub",
            draft = draft,
            options = { keep_backup = false },
        }, saved)
        assert.is_true(completed[1])
        assert.is_false(restore_available)
        assert.are.equal("Save these changes inside the EPUB?", confirmation.text)
        assert.are.equal(1, saved_callback)
        assert.is_true(shown.on_restore({ file = "/books/test.epub" }))
        assert.are.equal("/books/test.epub", restored)
        assert.are.equal(1, restored_callback)
    end)

    it("uses KOReader's provider, rename, and custom-cover paths", function()
        BookInfo:showFromBookDetails("/books/test.epub")
        local fullscreen
        local close_all
        local editor = {
            file = "/books/test.epub",
            getDraft = function() return shown.metadata end,
            getPendingCover = function(self) return self.pending_cover end,
            setPendingCover = function(self, path) self.pending_cover = path end,
            clearPendingCover = function(self) self.pending_cover = nil end,
            getCoverComparisonHeight = function() return 150 end,
            paintCoverComparison = function() end,
            showCoverFullscreen = function(_self, x, width)
                fullscreen = { x, width }
            end,
            _requestClose = function(_self, value) close_all = value end,
            isMetadataDirty = function() return false end,
            showError = function(_self, err) error(err) end,
        }
        shown.on_open_with(editor)
        shown.on_cover(editor)
        assert.are.equal("Cover", cover_picker.title)
        assert.are.equal(150, cover_picker.header_height)
        assert.is_true(cover_picker.footer_buttons_under_header)
        assert.is_true(cover_picker.hide_header_divider)
        assert.matches("resources/icons/mdlight/close.svg$",
            cover_picker.title_action_icon)
        cover_picker.title_action_callback()
        assert.is_true(close_all)
        assert.is_function(cover_picker.paint_header)
        assert.is_function(cover_picker.on_header_tap)
        cover_picker.on_header_tap(400, 20, 600, 150)
        assert.are.same({ 400, 600 }, fullscreen)
        assert.is_true(cover_picker.footer_buttons[1].keep_open)
        assert.is_true(cover_picker.footer_buttons[2].keep_open)
        assert.is_false(cover_picker.footer_buttons[1].filled == true)
        assert.is_true(cover_picker.footer_buttons[2].filled)
        assert.are.equal(cover_picker, editor._cover_picker)
        cover_picker.on_select(cover_picker.footer_buttons[1])
        assert.is_table(cover_chooser)
        assert.is_true(cover_chooser.file_filter("cover.jpg"))
        cover_chooser.onConfirm("/images/cover.jpg")
        assert.are.equal("/images/cover.jpg", editor.pending_cover)
        assert.are.equal("Clear", cover_picker.footer_buttons[3].text)
        assert.is_false(cover_picker.footer_buttons[3].filled == true)
        assert.is_nil(custom_cover)
        assert.is_true(shown.on_save(shown.metadata, editor))
        assert.are.equal("/images/cover.jpg", custom_cover)
        cover_picker.on_select(cover_picker.footer_buttons[3])
        assert.is_nil(editor.pending_cover)

        local source = os.tmpname() .. ".epub"
        local handle = assert(io.open(source, "wb"))
        assert(handle:write("fixture"))
        handle:close()
        editor.file = source
        local basename = require("ffi/util").basename(source) .. ".renamed.epub"
        local destination = assert(shown.on_rename(basename, editor))
        assert.are.equal("file",
            require("libs/libkoreader-lfs").attributes(destination, "mode"))
        os.remove(destination)
    end)

    it("shows a friendly error when metadata cannot be loaded", function()
        Service.load = function() return nil, "open_book" end

        assert.is_false(BookInfo:showFromBookDetails("/books/test.epub"))
        assert.are.same({ "Close this book before editing its metadata." }, messages)
        assert.is_nil(shown)
    end)

    it("keeps only the cover dirty when it fails after metadata is saved", function()
        BookInfo.setCustomCoverFromImage = function() error("write failed") end
        BookInfo:showFromBookDetails("/books/test.epub")
        local marked = false
        local completed
        local editor = {
            file = "/books/test.epub",
            isMetadataDirty = function() return true end,
            getPendingCover = function() return "/images/cover.jpg" end,
            markMetadataSaved = function() marked = true end,
            cancelSave = function() end,
            setRestoreAvailable = function() end,
            completeSave = function(_self, ok, err) completed = { ok, err } end,
        }

        shown.on_save({ title = "Changed" }, editor)
        confirmation.ok_callback()

        assert.is_true(marked)
        assert.is_nil(completed[1])
        assert.matches("Metadata was saved", completed[2], 1, true)
    end)

    it("retains EPUB backups when enabled in metadata settings", function()
        _G.__ZEN_UI_PLUGIN.config.metadata.epub_backup = true
        BookInfo:showFromBookDetails("/books/test.epub")
        local restore_available
        local editor = {
            file = "/books/test.epub",
            isMetadataDirty = function() return true end,
            getPendingCover = function() end,
            cancelSave = function() end,
            setRestoreAvailable = function(_self, available)
                restore_available = available
            end,
            completeSave = function() end,
        }

        shown.on_save({ title = "Changed" }, editor)
        assert.matches("restorable backup", confirmation.text, 1, true)
        confirmation.ok_callback()

        assert.is_true(saved.options.keep_backup)
        assert.is_true(restore_available)
    end)
end)

describe("metadata editor Hardcover controller", function()
    local BookInfo
    local shown
    local shown_widgets
    local picker
    local cancelled
    local search_result
    local editions_result
    local search_error
    local search_query
    local previous_plugin
    local previous_utils
    local hardcover_token
    local google_key
    local google_search_result
    local open_library_search_result
    local open_library_editions_result
    local google_search_hook
    local open_library_search_hook
    local google_search_calls
    local open_library_search_calls
    local cover_download_calls
    local preview_refreshes
    local trapper_wrap_calls
    local scheduled_callbacks

    local function run_scheduled()
        while #scheduled_callbacks > 0 do
            table.remove(scheduled_callbacks, 1)()
        end
    end

    before_each(function()
        shown = nil
        shown_widgets = {}
        picker = nil
        cancelled = false
        search_error = nil
        search_query = nil
        hardcover_token = "catalog-token"
        google_key = "google-key"
        google_search_result = {}
        open_library_search_result = {}
        open_library_editions_result = {}
        google_search_hook = nil
        open_library_search_hook = nil
        google_search_calls = 0
        open_library_search_calls = 0
        cover_download_calls = 0
        preview_refreshes = 0
        trapper_wrap_calls = 0
        scheduled_callbacks = {}
        search_result = {{
            id = 7,
            title = "Remote title",
            authors = { "Remote author" },
            exact_edition = {
                id = 9,
                edition_format = "Paperback",
                release_year = 2024,
                publisher = "Orbit",
            },
        }}
        editions_result = {}
        previous_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        previous_utils = package.loaded["common/utils"]
        _G.__ZEN_UI_PLUGIN = {
            config = { metadata = {
                hardcover_enabled = true,
                google_books_enabled = false,
                open_library_enabled = false,
                hardcover_auto_match = false,
            } },
        }

        BookInfo = {}
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("apps/filemanager/filemanagerbookinfo", BookInfo)
        ZenSpec.replace("modules/filebrowser/metadata_editor", {
            show = function(options)
                shown = options
                return options
            end,
        })
        ZenSpec.replace("modules/filebrowser/metadata/service", {
            load = function()
                return { title = "Local title", authors = { "Local author" }, isbn = "123" }
            end,
            isEpub = function() return false end,
        })
        ZenSpec.replace("config/hardcover_token", {
            get = function() return hardcover_token end,
        })
        ZenSpec.replace("config/google_books_key", {
            get = function() return google_key end,
        })
        ZenSpec.replace("bookinfomanager", { getBookInfo = function() return {} end })
        ZenSpec.replace("ui/widget/infomessage", {
            new = function(_self, options) return options end,
        })
        ZenSpec.replace("ui/widget/confirmbox", {
            new = function(_self, options) return options end,
        })
        ZenSpec.replace("ui/uimanager", {
            show = function(_self, widget) shown_widgets[#shown_widgets + 1] = widget end,
            close = function(_self, widget) widget.closed = true end,
            forceRePaint = function() end,
            nextTick = function(_self, callback) callback() end,
            scheduleIn = function(_self, _delay, callback)
                scheduled_callbacks[#scheduled_callbacks + 1] = callback
            end,
        })
        local trapper_wrapped = false
        ZenSpec.replace("ui/trapper", {
            wrap = function(_self, callback)
                trapper_wrap_calls = trapper_wrap_calls + 1
                local was_wrapped = trapper_wrapped
                trapper_wrapped = true
                callback()
                trapper_wrapped = was_wrapped
            end,
            isWrapped = function() return trapper_wrapped end,
            dismissableRunInSubprocess = function(_self, task, trap_widget)
                if cancelled then return false end
                local dismissed = false
                if trap_widget then
                    trap_widget.dismiss_callback = function() dismissed = true end
                end
                local result, err = task()
                if dismissed then return false end
                return true, result, err
            end,
        })
        ZenSpec.replace("common/ui/zen_modal_close", {
            installDialog = function() end,
        })
        ZenSpec.replace("common/ui/zen_menu_picker", function(options)
            options.addItems = function(self, batch, title)
                if self.closed then return false end
                if #batch == 0 and title == nil then
                    preview_refreshes = preview_refreshes + 1
                end
                for _i, item in ipairs(batch) do self.items[#self.items + 1] = item end
                if title ~= nil then self.title = title end
                return true
            end
            options.onCancelOrClose = function(self)
                self.closed = true
                if self.on_close then self.on_close() end
            end
            picker = options
            return options
        end)
        ZenSpec.replace("common/language_name", {
            get = function(code) return code == "en" and "English" or code end,
        })
        ZenSpec.replace("common/utils", {
            resolveLocalIcon = function(directory, name)
                return directory .. name .. ".svg"
            end,
        })
        ZenSpec.replace("document/documentregistry", {
            openDocument = function()
                return {
                    getCoverPageImage = function()
                        return { free = function() end }
                    end,
                    close = function() end,
                }
            end,
        })
        ZenSpec.replace("ui/renderimage", {
            renderImageFile = function()
                return { free = function() end }
            end,
        })
        local function download_cover(_url, destination)
            cover_download_calls = cover_download_calls + 1
            local file = assert(io.open(destination, "wb"))
            assert(file:write("\255\216fixture"))
            file:close()
            return destination
        end
        ZenSpec.replace("modules/filebrowser/metadata/hardcover", {
            search = function(_token, query)
                search_query = query
                if search_error then return nil, search_error end
                return search_result
            end,
            editions = function() return editions_result end,
            draft = function(work, edition)
                return {
                    title = work.title,
                    authors = work.authors,
                    publisher = edition.publisher,
                }
            end,
            downloadCover = download_cover,
        })
        ZenSpec.replace("modules/filebrowser/metadata/google_books", {
            search = function()
                google_search_calls = google_search_calls + 1
                if google_search_hook then google_search_hook() end
                return google_search_result
            end,
            editions = function(_key, work) return { work.exact_edition or work._edition } end,
            draft = function(work, edition)
                return { title = work.title, publisher = edition.publisher }
            end,
            downloadCover = download_cover,
        })
        ZenSpec.replace("modules/filebrowser/metadata/open_library", {
            search = function()
                open_library_search_calls = open_library_search_calls + 1
                if open_library_search_hook then open_library_search_hook() end
                return open_library_search_result
            end,
            editions = function() return open_library_editions_result end,
            draft = function(work, edition)
                return { title = work.title, publisher = edition.publisher }
            end,
            downloadCover = download_cover,
        })
        ZenSpec.unload("modules/filebrowser/patches/metadata_editor")
        require("modules/filebrowser/patches/metadata_editor")()
        BookInfo:showFromBookDetails("/books/test.pdf")
    end)

    after_each(function()
        _G.__ZEN_UI_PLUGIN = previous_plugin
        package.loaded["common/utils"] = previous_utils
        ZenSpec.unload("modules/filebrowser/patches/metadata_editor")
    end)

    it("shows editions before applying an exact ISBN match", function()
        _G.__ZEN_UI_PLUGIN.config.metadata.hardcover_auto_match = true
        editions_result = {
            {
                id = 9,
                edition_format = "Paperback",
                release_year = 2024,
                publisher = "Orbit",
            },
            { id = 10, edition_format = "Hardcover", publisher = "Ace" },
        }
        local applied
        local editor = {
            applyHardcover = function(_self, metadata, summary)
                applied = { metadata = metadata, summary = summary }
                return 1
            end,
        }

        shown.on_hardcover(shown.metadata, editor)

        assert.are.equal("Choose an edition", picker.title)
        assert.are.equal(2, #picker.items)
        assert.is_nil(applied)
        picker.on_select(picker.items[2])
        assert.are.equal("Remote title", applied.metadata.title)
        assert.are.equal("Ace", applied.metadata.publisher)
        assert.are.equal("Hardcover · Ace", applied.summary)
        assert.are.equal(1, #shown_widgets)
        assert.are.equal("Searching metadata…", shown_widgets[1].text)
        assert.is_true(shown_widgets[1].closed)
        assert.are.equal(1, trapper_wrap_calls)
    end)

    it("always shows the results list in manual mode", function()
        search_result = {{
            id = 7,
            title = "Remote title",
            authors = { "Remote author" },
        }}
        editions_result = {{
            id = 9,
            edition_format = "Paperback",
            release_year = 2024,
        }}
        local editor = {
            applyHardcover = function() error("must wait for a selection") end,
        }

        shown.on_hardcover(shown.metadata, editor)

        assert.are.equal("Metadata results", picker.title)
        assert.are.equal(1, #picker.items)
        assert.are.equal("Paperback, 2024", picker.items[1].text)
        assert.matches("Hardcover", picker.items[1].secondary_text, 1, true)
        assert.are.equal("Local title", search_query.title)
        assert.is_nil(search_query.author)
        assert.are.equal("123", search_query.isbn)
        assert.is_nil(search_query.include_title_results)
        assert.is_true(picker.black_text)
        assert.matches("icons/quick_search.svg$",
            picker.title_action_icon)
        assert.is_true(picker.title_action_keep_open)
        assert.is_function(picker.title_action_callback)
    end)

    it("preserves every returned edition in the manual results list", function()
        search_result = {{ id = 1, title = "Remote title" }}
        editions_result = {}
        for item_index = 1, 10 do
            editions_result[item_index] = {
                id = item_index,
                edition_format = "Edition " .. tostring(item_index),
            }
        end

        shown.on_hardcover(shown.metadata, {})

        assert.are.equal(10, #picker.items)
        assert.are.equal("Edition 10", picker.items[10].text)
    end)

    it("merges provider editions into one progressive results list", function()
        _G.__ZEN_UI_PLUGIN.config.metadata.open_library_enabled = true
        search_result = {{
            id = 1,
            title = "Hardcover result",
            authors = { "A" },
            image_url = "https://assets.hardcover.app/book/1/cover.jpg",
        }}
        open_library_search_result = {{
            id = "/works/OL1W",
            title = "Open Library result",
            authors = { "C" },
            image_url = "https://covers.openlibrary.org/cover.jpg",
        }}
        editions_result = {}
        open_library_editions_result = {}
        for index = 1, 30 do
            editions_result[index] = {
                id = index,
                edition_format = "Hardcover " .. index,
                image_url = "https://assets.hardcover.app/edition/" .. index .. "/cover.jpg",
            }
            open_library_editions_result[index] = {
                id = "/books/OL" .. index .. "M",
                edition_format = "Paperback " .. index,
                image_url = "https://covers.openlibrary.org/b/id/" .. index .. "-L.jpg",
            }
        end
        local applied, pending_cover
        local editor = {
            applyHardcover = function(_self, metadata, _summary, source, source_label)
                applied = { metadata = metadata, source = source, label = source_label }
                return 0
            end,
            getPendingCoverSource = function() end,
            setPendingCover = function(_self, path) pending_cover = path end,
        }
        open_library_search_hook = function()
            assert.are.equal(30, #picker.items)
            assert.are.equal("Metadata results · 1 / 2 still loading", picker.title)
            assert.are.equal(0, cover_download_calls)
            run_scheduled()
            assert.are.equal(30, cover_download_calls)
            assert.are.equal(6, preview_refreshes)
            assert.is_truthy(picker.items[1].image_file:match("%.jpg$"))
        end

        shown.on_hardcover(shown.metadata, editor)

        assert.are.equal("Metadata results", picker.title)
        assert.are.equal(5, picker.rows_per_page)
        assert.are.equal(60, #picker.items)
        assert.are.equal(30, cover_download_calls)
        assert.is_nil(picker.items[31].image_file)
        run_scheduled()
        assert.are.equal(60, cover_download_calls)
        assert.are.equal(12, preview_refreshes)
        assert.is_truthy(picker.items[1].image_file:match("%.jpg$"))
        assert.is_truthy(picker.items[31].image_file:match("%.jpg$"))
        assert.matches("Hardcover", picker.items[1].secondary_text, 1, true)
        assert.matches("Open Library", picker.items[31].secondary_text, 1, true)
        picker.on_close(picker.items[31])
        picker.on_select(picker.items[31])
        assert.are.equal("Open Library result", applied.metadata.title)
        assert.are.equal("open_library", applied.source)
        assert.are.equal("Open Library", applied.label)
        assert.are.equal(0, google_search_calls)
        assert.are.equal(1, open_library_search_calls)
        assert.are.equal(3, trapper_wrap_calls)
        os.remove(pending_cover)
    end)

    it("stops progressive loading when the results picker closes", function()
        _G.__ZEN_UI_PLUGIN.config.metadata.google_books_enabled = true
        _G.__ZEN_UI_PLUGIN.config.metadata.open_library_enabled = true
        search_result = {{ id = 1, title = "Hardcover result" }}
        editions_result = {{ id = 11, edition_format = "Hardcover" }}
        google_search_result = {{ id = "google-1", title = "Google result" }}
        google_search_hook = function() picker:onCancelOrClose() end

        shown.on_hardcover(shown.metadata, {})

        assert.are.equal(1, #picker.items)
        assert.are.equal(1, google_search_calls)
        assert.are.equal(0, open_library_search_calls)
    end)

    it("auto-picks the first exact match without querying later providers", function()
        _G.__ZEN_UI_PLUGIN.config.metadata.google_books_enabled = true
        _G.__ZEN_UI_PLUGIN.config.metadata.open_library_enabled = true
        _G.__ZEN_UI_PLUGIN.config.metadata.hardcover_auto_match = true
        search_result = {{ id = 1, title = "Hardcover result" }}
        google_search_result = {{
            id = "google-1",
            title = "Google exact result",
            exact_edition = { id = "google-1", publisher = "Google publisher" },
        }}
        local applied
        local editor = {
            applyHardcover = function(_self, metadata, _summary, source)
                applied = { metadata = metadata, source = source }
                return 0
            end,
            getPendingCoverSource = function() end,
        }

        shown.on_hardcover(shown.metadata, editor)

        assert.is_nil(picker)
        assert.are.equal("Google exact result", applied.metadata.title)
        assert.are.equal("google_books", applied.source)
        assert.are.equal(1, google_search_calls)
        assert.are.equal(0, open_library_search_calls)
    end)

    it("skips a keyed provider without a key but keeps credential-free results", function()
        _G.__ZEN_UI_PLUGIN.config.metadata.hardcover_enabled = false
        _G.__ZEN_UI_PLUGIN.config.metadata.google_books_enabled = true
        _G.__ZEN_UI_PLUGIN.config.metadata.open_library_enabled = true
        google_key = ""
        open_library_search_result = {{
            id = "/works/OL1W",
            title = "Open Library result",
            authors = { "Author" },
        }}
        open_library_editions_result = {{
            id = "/books/OL1M",
            edition_format = "Paperback",
        }}

        shown.on_hardcover(shown.metadata, {})

        assert.are.equal(1, #picker.items)
        assert.are.equal("Paperback", picker.items[1].text)
        assert.matches("Open Library", picker.items[1].secondary_text, 1, true)
        assert.are.equal(0, google_search_calls)
        assert.are.equal(1, open_library_search_calls)
    end)

    it("opens an editable search when changing an existing match", function()
        local dialog_options
        ZenSpec.replace("ui/widget/multiinputdialog", {
            new = function(_self, options)
                dialog_options = options
                options.onShowKeyboard = function() end
                return options
            end,
        })
        local editor = {
            edition_summary = "Paperback, 2024 · Orbit",
            applyHardcover = function() error("must not reapply the same match") end,
        }

        shown.on_hardcover(shown.metadata, editor)

        assert.are.equal("Search metadata", dialog_options.title)
        assert.are.equal("Local title", dialog_options.fields[1].text)
        assert.are.equal("Local author", dialog_options.fields[2].text)
        assert.is_nil(picker)
    end)

    it("does not replace a manually selected cover during metadata autofill", function()
        _G.__ZEN_UI_PLUGIN.config.metadata.hardcover_auto_match = true
        search_result[1].exact_edition.image_url =
            "https://assets.hardcover.app/edition/9/cover.jpg"
        editions_result = { search_result[1].exact_edition }
        local editor = {
            applyHardcover = function() return 0 end,
            getPendingCoverSource = function() return "manual" end,
            setPendingCover = function() error("manual cover was replaced") end,
        }

        shown.on_hardcover(shown.metadata, editor)

        assert.is_nil(picker)
    end)

    it("opens an editable search when the draft title is blank", function()
        local dialog_options
        ZenSpec.replace("ui/widget/multiinputdialog", {
            new = function(_self, options)
                dialog_options = options
                options.onShowKeyboard = function() end
                return options
            end,
        })

        shown.on_hardcover({ title = "", authors = {}, isbn = "9780441013593" }, {})

        assert.are.equal("Search metadata", dialog_options.title)
        assert.are.equal("", dialog_options.fields[1].text)
        assert.is_nil(picker)
    end)

    it("offers metadata settings without making a request when the token is missing", function()
        hardcover_token = ""
        local editor = { applyHardcover = function() error("must not apply") end }

        shown.on_hardcover(shown.metadata, editor)

        assert.are.equal("Open settings", shown_widgets[1].ok_text)
        assert.is_nil(picker)
    end)

    it("keeps cancellation silent and maps authorization failures", function()
        cancelled = true
        shown.on_hardcover(shown.metadata, {})
        assert.are.equal(1, #shown_widgets)
        assert.are.equal("Searching metadata…", shown_widgets[1].text)
        assert.are.equal(1, trapper_wrap_calls)
        assert.is_true(shown_widgets[1].closed)

        cancelled = false
        search_error = { kind = "unauthorized" }
        shown.on_hardcover(shown.metadata, {})
        assert.are.equal("Open settings", shown_widgets[#shown_widgets].ok_text)
    end)

    it("renders edition choices directly in manual results", function()
        search_result = {{
            id = 1,
            title = "First",
            authors = { "A" },
            series_name = "Saga",
            series_index = 2,
        }}
        editions_result = {
            {
                id = 10,
                edition_format = "Hardcover",
                release_year = 2022,
                publisher = "Orbit",
                language = "en",
                pages = 500,
                image_url = "https://assets.hardcover.app/edition/10/cover.jpg",
            },
            { id = 11, edition_format = "Paperback", release_year = 2023 },
        }

        shown.on_hardcover(shown.metadata, {})
        assert.are.equal(1, #shown_widgets)
        assert.are.equal("Searching metadata…", shown_widgets[1].text)
        assert.are.equal("Metadata results", picker.title)
        assert.are.equal(5, picker.rows_per_page)
        assert.are.equal(2, #picker.items)
        assert.is_nil(picker.items[1].image_file)
        assert.are.equal(0, cover_download_calls)
        run_scheduled()
        assert.is_truthy(picker.items[1].image_file:match("%.jpg$"))
        assert.are.equal(1, cover_download_calls)
        assert.are.equal(1, preview_refreshes)
        assert.are.equal("Hardcover, 2022", picker.items[1].text)
        assert.matches("Hardcover", picker.items[1].secondary_text, 1, true)
        assert.matches("Orbit", picker.items[1].secondary_text, 1, true)
        assert.matches("500 pages", picker.items[1].secondary_text, 1, true)
        assert.are.equal(2, trapper_wrap_calls)
        local preview = picker.items[1].image_file
        picker.on_close()
        assert.is_nil(require("libs/libkoreader-lfs").attributes(preview, "mode"))
    end)

    it("loads cover previews after opening metadata results", function()
        search_result = {{ id = 1, title = "Remote title" }}
        editions_result = {}
        for index = 1, 7 do
            editions_result[index] = {
                id = index,
                edition_format = "Edition " .. index,
                image_url = "https://assets.hardcover.app/book/" .. index .. "/cover.jpg",
            }
        end
        shown.on_hardcover(shown.metadata, {})

        assert.are.equal(7, #picker.items)
        assert.are.equal(0, cover_download_calls)
        assert.is_nil(picker.items[1].image_file)
        run_scheduled()
        assert.are.equal(7, cover_download_calls)
        assert.are.equal(2, preview_refreshes)
        assert.is_truthy(picker.items[1].image_file:match("%.jpg$"))
        assert.is_truthy(picker.items[7].image_file:match("%.jpg$"))
        local preview = picker.items[1].image_file
        picker.on_close()
        assert.is_nil(require("libs/libkoreader-lfs").attributes(preview, "mode"))
    end)

    it("auto-picks the highest-ranked non-audio match", function()
        _G.__ZEN_UI_PLUGIN.config.metadata = {
            hardcover_enabled = true,
            google_books_enabled = false,
            open_library_enabled = false,
            hardcover_auto_match = true,
        }
        search_result = {
            { id = 1, title = "Best work", authors = { "A" } },
            { id = 2, title = "Other work", authors = { "B" } },
        }
        editions_result = {
            { id = 10, edition_format = "Audio CD", is_audio = true, publisher = "Audio" },
            { id = 11, edition_format = "Hardcover", publisher = "Print" },
        }
        local applied
        local editor = {
            edition_summary = "Old match",
            applyHardcover = function(_self, metadata)
                applied = metadata
                return 0
            end,
            getPendingCoverSource = function() end,
        }

        shown.on_hardcover(shown.metadata, editor)

        assert.is_nil(picker)
        assert.are.equal("123", search_query.isbn)
        assert.is_nil(search_query.include_title_results)
        assert.are.equal("Best work", applied.title)
        assert.are.equal("Print", applied.publisher)
    end)

    it("stages a selected Hardcover edition cover", function()
        _G.__ZEN_UI_PLUGIN.config.metadata.hardcover_auto_match = true
        editions_result = {{
            id = 10,
            edition_format = "Hardcover",
            image_url = "https://assets.hardcover.app/edition/10/cover.jpg",
        }}
        local pending
        local editor = {
            getDraft = function() return shown.metadata end,
            getPendingCover = function() end,
            setPendingCover = function(_self, path, temporary)
                pending = { path, temporary }
            end,
        }

        shown.on_cover(editor)
        assert.are.equal("Find metadata", picker.footer_buttons[2].text)
        picker.on_select(picker.footer_buttons[2])

        assert.is_truthy(pending[1]:match("%.jpg$"))
        assert.is_true(pending[2])
        assert.are.equal(1, cover_download_calls)
        os.remove(pending[1])
    end)

    it("shows exact ISBN editions and applies only the chosen cover", function()
        search_result[2] = { id = 8, title = "Unrelated book" }
        editions_result = {
            {
                id = 10,
                edition_format = "Hardcover",
                image_url = "https://assets.hardcover.app/edition/10/cover.jpg",
            },
            {
                id = 11,
                edition_format = "Paperback",
                image_url = "https://assets.hardcover.app/edition/11/cover.jpg",
            },
        }
        local pending
        local editor = {
            getDraft = function() return shown.metadata end,
            getPendingCover = function() end,
            applyHardcover = function() error("cover selection changed metadata") end,
            setPendingCover = function(_self, path) pending = path end,
        }

        shown.on_cover(editor)
        picker.on_select(picker.footer_buttons[2])

        assert.are.equal("Choose an edition", picker.title)
        assert.are.equal(2, #picker.items)
        local selected = picker.items[2]
        local discarded = picker.items[1].image_file
        assert.is_truthy(selected.image_file:match("%.jpg$"))
        assert.are.equal(2, cover_download_calls)
        picker.on_close(selected)
        picker.on_select(selected)
        assert.are.equal(selected.image_file, pending)
        assert.are.equal(2, cover_download_calls)
        assert.is_nil(require("libs/libkoreader-lfs").attributes(discarded, "mode"))
        os.remove(pending)
    end)

    it("requires an explicit choice before staging an audio cover", function()
        editions_result = {{
            id = 10,
            edition_format = "Audio CD",
            is_audio = true,
            image_url = "https://assets.hardcover.app/edition/10/cover.jpg",
        }}
        local pending
        local editor = {
            getDraft = function() return shown.metadata end,
            getPendingCover = function() end,
            setPendingCover = function(_self, path) pending = path end,
        }

        shown.on_cover(editor)
        picker.on_select(picker.footer_buttons[2])

        assert.is_nil(pending)
        assert.are.equal("Choose an edition", picker.title)
        assert.are.equal("Audio CD", picker.items[1].text)
        assert.are.equal(1, cover_download_calls)
        local selected = picker.items[1]
        picker.on_close(selected)
        picker.on_select(selected)
        assert.are.equal(selected.image_file, pending)
        assert.are.equal(1, cover_download_calls)
        os.remove(pending)
    end)
end)

describe("metadata editor Hardcover merge", function()
    local Editor
    local uniform_covers
    local cover_ratio

    before_each(function()
        uniform_covers = true
        cover_ratio = 2 / 3
        local function widget_stub()
            return { new = function(_self, options)
                options = options or {}
                options.getSize = options.getSize or function(self)
                    return { w = self.width or 0, h = self.height or 0 }
                end
                return options
            end }
        end
        local Menu = {}
        function Menu:extend()
            local class = {}
            setmetatable(class, { __index = self })
            return class
        end
        local InputContainer = {}
        function InputContainer:extend(definition)
            definition = definition or {}
            setmetatable(definition, { __index = self })
            function definition:new(options)
                options = options or {}
                setmetatable(options, { __index = self })
                if options.init then options:init() end
                return options
            end
            return definition
        end
        ZenSpec.replace("ui/bidi", { mirroredUILayout = function() return false end })
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_WHITE = 0,
            COLOR_BLACK = 1,
            COLOR_DARK_GRAY = 2,
            COLOR_LIGHT_GRAY = 3,
        })
        ZenSpec.replace("device", {
            isTouchDevice = function() return true end,
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
                scaleBySize = function(_self, value) return value end,
            },
        })
        ZenSpec.replace("ui/font", { getFace = function() return {} end })
        ZenSpec.replace("ui/geometry", { new = function(_self, value) return value end })
        ZenSpec.replace("ui/gesturerange", { new = function(_self, value) return value end })
        ZenSpec.replace("ui/size", {
            border = { thin = 1 },
            line = { thin = 1 },
        })
        ZenSpec.replace("ui/widget/menu", Menu)
        ZenSpec.replace("ui/widget/container/inputcontainer", InputContainer)
        ZenSpec.replace("common/ui/zen_solid_circle", {
            new = function(_self, options)
                options.getSize = function(self)
                    return { w = self.width or 0, h = self.height or 0 }
                end
                options.paintTo = function() end
                return options
            end,
        })
        ZenSpec.replace("common/ui/zen_button", {
            paintFilled = function() end,
            paintOutlined = function() end,
        })
        for _i, name in ipairs({
            "ui/widget/button",
            "ui/widget/confirmbox",
            "ui/widget/container/centercontainer",
            "ui/widget/container/framecontainer",
            "ui/widget/container/leftcontainer",
            "ui/widget/horizontalgroup",
            "ui/widget/horizontalspan",
            "ui/widget/iconwidget",
            "ui/widget/imagewidget",
            "ui/widget/infomessage",
            "ui/widget/inputdialog",
            "ui/widget/multiconfirmbox",
            "ui/widget/multiinputdialog",
            "ui/widget/textboxwidget",
            "ui/widget/textwidget",
            "ui/widget/verticalgroup",
            "ui/widget/verticalspan",
            "common/ui/zen_modal_close",
            "common/ui/zen_settings_titlebar",
        }) do
            ZenSpec.replace(name, widget_stub())
        end
        ZenSpec.replace("ui/uimanager", {
            setDirty = function(_self, widget) widget.dirtied = true end,
        })
        ZenSpec.replace("ffi/util", {
            template = function(text) return text end,
        })
        ZenSpec.replace("config/manager", {
            get = function()
                return { features = { browser_cover_mosaic_uniform = uniform_covers } }
            end,
        })
        local CoverUtils = { BORDER_SIZE = 1 }
        CoverUtils.getRatio = function() return cover_ratio end
        CoverUtils.calcDims = function(max_w, max_h)
            if max_h * cover_ratio <= max_w then
                return math.floor(max_h * cover_ratio), max_h
            end
            return max_w, math.floor(max_w / cover_ratio)
        end
        CoverUtils.fitDims = function(max_w, max_h, source_w, source_h)
            local scale = math.min(max_w / source_w, max_h / source_h)
            return math.floor(source_w * scale + 0.5),
                math.floor(source_h * scale + 0.5)
        end
        CoverUtils.loadExplicitCover = function(path)
            return { data = { file = path }, w = 100, h = 100 }
        end
        CoverUtils.drawSingle = function(cover, max_w, max_h, border, uniform)
            local width, height
            if uniform then
                width, height = CoverUtils.calcDims(max_w, max_h)
            else
                width, height = CoverUtils.fitDims(max_w, max_h, cover.w, cover.h)
            end
            return {
                cover = cover,
                uniform = uniform,
                width = width + 2 * border,
                height = height + 2 * border,
            }
        end
        ZenSpec.replace("common/cover_utils", CoverUtils)
        ZenSpec.replace("modules/filebrowser/patches/home/widgets/cover_common", {
            decorate_cover_frame = function(frame)
                frame.decorated = true
                frame.getSize = function(self)
                    return { w = self.width or 0, h = self.height or 0 }
                end
                frame.paintTo = function() end
                return frame
            end,
        })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("common/ui/icon_menu_item", {
            getSettingsFontSize = function() return 20 end,
            getSettingsRowHeight = function() return 60 end,
            getSettingsLeftPadding = function() return 16 end,
            installMenuPatch = function() end,
        })
        ZenSpec.unload("modules/filebrowser/metadata_editor")
        Editor = require("modules/filebrowser/metadata_editor")
    end)

    after_each(function()
        ZenSpec.unload("modules/filebrowser/metadata_editor")
    end)

    local function editor(metadata)
        local instance = {
            draft = Editor.normalizeDraft(metadata),
            original = Editor.normalizeDraft(metadata),
            manual_fields = {},
            is_epub = true,
            edition_summary = "",
            _refresh = function(self) self.refreshes = (self.refreshes or 0) + 1 end,
        }
        return setmetatable(instance, { __index = Editor.Widget })
    end

    it("protects manual fields while applying nonempty Hardcover metadata", function()
        local widget = editor({
            title = "Original",
            authors = { "Original author" },
            series_name = "Original series",
            series_index = "1",
            language = "en",
        })
        widget:_applyField("title", "Manual title")
        widget:_applyField("series", { "Manual series", "3" })

        local skipped = widget:applyHardcover({
            title = "Remote title",
            authors = { "Remote author" },
            series_name = "Remote series",
            series_index = "4",
            language = "",
            publisher = "Remote publisher",
        }, "2024 · E-book")

        assert.are.equal(2, skipped)
        assert.are.equal("Manual title", widget.draft.title)
        assert.are.equal("Manual series", widget.draft.series_name)
        assert.are.equal("3", widget.draft.series_index)
        assert.are.same({ "Remote author" }, widget.draft.authors)
        assert.are.equal("en", widget.draft.language)
        assert.are.equal("Remote publisher", widget.draft.publisher)
        assert.are.equal("2024 · E-book", widget.edition_summary)
    end)

    it("treats a staged cover as dirty without changing metadata", function()
        local widget = editor({ title = "Book" })
        widget.pending_cover = { path = "/tmp/cover.jpg" }

        assert.is_false(widget:isMetadataDirty())
        assert.is_true(widget:isDirty())
    end)

    it("updates the Hardcover action without a preview strip", function()
        local widget = editor({ title = "Changed", authors = { "New author" } })
        widget.edition_summary = "Paperback, 2024"
        local text
        widget._hardcover_button = {
            enabled = true,
            width = 200,
            setText = function(_self, value) text = value end,
        }

        widget:_updateMetadataHeader()

        assert.are.equal("%1 · %2", text)
        assert.is_nil(widget._strip_title)
    end)

    it("keeps filename inside the bookshelf details card", function()
        local widget = editor({ title = "Book" })
        widget.file = "/books/example.epub"
        widget.has_custom_cover = true
        widget.can_restore = true

        local items = widget:_buildItems()

        assert.are.equal("Book details", items[1].text)
        assert.is_function(items[1]._zen_settings_content_func)
        assert.is_true(items[1]._zen_focus_border_only)
        assert.is_false(items[1]._zen_has_submenu == true)
        assert.are.equal("Description", items[2].text)
        assert.is_function(items[2]._zen_settings_content_func)
        assert.is_true(items[2]._zen_focus_border_only)
        assert.are.equal(2, #items)
    end)

    it("places Restore directly beside the metadata footer actions", function()
        local restores = 0
        local widget = editor({ title = "Book" })
        widget.width = 600
        widget.can_restore = true
        widget.on_open_with = function() end
        widget.on_hardcover = function() end
        widget.on_restore = function() end
        widget._requestRestore = function() restores = restores + 1 end

        widget:_makeMetadataHeader()

        assert.are.equal(3, #widget._action_buttons)
        assert.are.equal("Open with…", widget._action_buttons[1].text)
        assert.are.equal("Find metadata", widget._action_buttons[2].text)
        assert.are.equal("Restore", widget._action_buttons[3].text)
        local focus_rects = 0
        local button = widget._action_buttons[1]
        button.dimen = { w = button.width, h = button.height }
        button:onFocus()
        button:paintTo({ invertRect = function() focus_rects = focus_rects + 1 end }, 0, 0)
        assert.are.equal(4, focus_rects)
        widget._restore_button.callback()
        assert.are.equal(1, restores)
    end)

    it("styles the dirty Save action as a larger filled Zen button", function()
        local action
        local widget = editor({ title = "Book" })
        widget.draft.title = "Changed"
        widget.title_bar = {
            setAction = function(_self, value) action = value end,
        }

        widget:_syncTitleAction()

        assert.is_true(action.zen_button)
        assert.is_true(action.filled)
        assert.are.equal(36, action.height)
        assert.are.equal(16, action.padding_h)
        assert.are.equal(22, action.text_font_size)
    end)

    it("opens rounded field modals from the bookshelf details card", function()
        local cover_taps = 0
        local edits = {}
        local widget = editor({
            title = "Book",
            authors = { "First Author" },
            series_name = "Series",
            series_index = "1",
            genres = { "Fantasy" },
            language = "en",
            publisher = "Orbit",
        })
        widget.on_cover = function() cover_taps = cover_taps + 1 end
        widget.file = "/books/example.epub"
        widget._editField = function(_self, key) edits[#edits + 1] = key end
        widget._editFilename = function() edits[#edits + 1] = "filename" end
        local content = widget:_bookDetailsContent(600, 330, {}, true)
        local details = content[1][4]
        local title = details[2][3]
        local authors = details[4][3]
        local series = details[6][3]
        local filename = details[14][3]
        local cover = content[1][2]
        local focus_rects = 0
        local focus_bounds
        local bb = {
            invertRect = function(_self, x, y, width, height)
                focus_rects = focus_rects + 1
                focus_bounds = focus_bounds or { x = x, y = y, w = width, h = height }
            end,
        }

        assert.are.equal(7, #widget._field_focus_rows)
        assert.are.equal(7, title[1].radius)
        assert.are.equal(1, title[1].bordersize)
        assert.are.equal("Book", title[1][1][1][2].text)
        widget.getFocusItem = function() return {} end
        assert.is_false(title:onFocus())
        assert.is_false(title.focused == true)
        widget.getFocusItem = function() return title end
        assert.is_true(title:onFocus())
        assert.is_true(title.focused)
        title:paintTo(bb, 0, 0)
        assert.are.equal(4, focus_rects)
        assert.are.same({ x = -2, y = -2, w = title.dimen.w + 4, h = 2 }, focus_bounds)
        widget.getFocusItem = function() return cover end
        assert.is_true(cover:onFocus())
        cover:paintTo(bb, 0, 0)
        assert.are.equal(8, focus_rects)
        title:onTapField()
        authors:onTapField()
        series:onTapField()
        filename:onTapField()
        cover:onTapCover()

        assert.are.same({ "title", "authors", "series", "filename" }, edits)
        assert.are.equal(1, cover_taps)
    end)

    it("focuses every editor control on touch-capable D-pad runtimes", function()
        local widget = editor({ title = "Book" })
        local back, close = {}, {}
        local details = {
            entry = { _metadata_key = "details" },
            onUnfocus = function(self) self.unfocused = true end,
        }
        local description = { entry = { _metadata_key = "description" } }
        local cover = { onFocus = function(self) self.focused = true end }
        local title = { _metadata_key = "title", onFocus = function() end }
        local authors = { _metadata_key = "authors", onFocus = function(self)
            self.focused = true
        end }
        local open_with, find_metadata = { enabled = true }, { enabled = true }
        widget.layout = { { details }, { description } }
        widget.selected = { x = 1, y = 1 }
        widget.title_bar = {
            installFocusLayout = function(_self, owner)
                table.insert(owner.layout, 1, { back, close })
                owner.selected.y = owner.selected.y + 1
            end,
        }
        widget._cover_focus = cover
        widget._field_focus_rows = { { title }, { authors } }
        widget._action_buttons = { open_with, find_metadata }
        widget._metadata_focus_key = "authors"

        widget:mergeTitleBarIntoLayout()

        assert.are.same({ back, close }, widget.layout[1])
        assert.are.equal(cover, widget.layout[2][1])
        assert.are.equal(title, widget.layout[3][1])
        assert.are.equal(authors, widget.layout[4][1])
        assert.are.equal(description, widget.layout[5][1])
        assert.are.same({ open_with, find_metadata }, widget.layout[6])
        assert.are.same({ x = 1, y = 4 }, widget.selected)
        assert.is_true(details.unfocused)
        assert.is_true(authors.focused)

        widget.getFocusItem = function(self)
            return self.layout[self.selected.y][self.selected.x]
        end
        widget.getFocusableWidgetXY = function(self, target)
            for y, row in ipairs(self.layout) do
                for x, item in ipairs(row) do
                    if item == target then return x, y end
                end
            end
        end
        widget.moveFocusTo = function(self, x, y)
            self.selected.x, self.selected.y = x, y
            return true
        end
        assert.is_true(widget:onFocusMove({ -1, 0 }))
        assert.are.same({ x = 1, y = 2 }, widget.selected)
        assert.is_true(widget:onFocusMove({ 1, 0 }))
        assert.are.same({ x = 1, y = 4 }, widget.selected)
    end)

    it("opens current and staged covers fullscreen", function()
        local shown_viewer
        package.loaded["ui/uimanager"].show = function(_self, viewer)
            shown_viewer = viewer
        end
        ZenSpec.replace("ui/widget/imageviewer", {
            new = function(_self, options)
                options.onClose = function(self) self.closed = true end
                return options
            end,
        })
        local current = { old = true }
        local widget = editor({ title = "Book" })
        widget.current_cover = current
        widget.pending_cover = { path = "/tmp/new-cover.jpg" }

        assert.are.equal(360, widget:getCoverComparisonHeight())
        local comparison = widget:_coverComparisonContent(600, 360)[1]
        assert.is_false(comparison.allow_mirroring)
        assert.are.equal(215, comparison[1].dimen.w)
        assert.is_true(comparison[1][1][1].bold)
        assert.are.equal(20, comparison[2].width)
        assert.are.equal(215, comparison[3].dimen.w)
        assert.is_true(comparison[3][1][1].bold)
        assert.is_true(widget:showCoverFullscreen(100, 600))
        assert.are.equal(current, shown_viewer.image)
        assert.is_false(shown_viewer.image_disposable)
        assert.is_true(shown_viewer.fullscreen)
        assert.is_false(shown_viewer.with_title_bar)
        assert.is_true(shown_viewer:onTap())
        assert.is_true(shown_viewer.closed)

        assert.is_true(widget:showCoverFullscreen(500, 600))
        assert.are.equal("/tmp/new-cover.jpg", shown_viewer.file)
    end)

    it("uses only Hardcover and Save actions in the description editor", function()
        local dialog_options
        package.loaded["ui/widget/inputdialog"].new = function(_self, options)
            dialog_options = options
            options.getInputText = function() return "Updated description" end
            options.onShowKeyboard = function() end
            return options
        end
        package.loaded["common/ui/zen_modal_close"].installDialog = function() end
        local UIManager = package.loaded["ui/uimanager"]
        UIManager.show = function() end
        UIManager.close = function() end
        UIManager.nextTick = function(_self, callback) callback() end
        local hardcover_calls = 0
        local widget = editor({ title = "Book", description = "Old description" })
        widget.on_hardcover = function()
            hardcover_calls = hardcover_calls + 1
        end

        widget:_editField("description")

        assert.is_false(dialog_options.add_nav_bar)
        assert.are.equal(2, #dialog_options.buttons[1])
        assert.are.equal("Find metadata", dialog_options.buttons[1][1].text)
        assert.are.equal("Save", dialog_options.buttons[1][2].text)
        dialog_options.buttons[1][1].callback()
        assert.are.equal(1, hardcover_calls)
        dialog_options.buttons[1][2].callback()
        assert.are.equal("Updated description", widget.draft.description)
    end)

    it("shows the staged cover in the bookshelf card", function()
        local widget = editor({ title = "Book" })
        widget.current_cover = { old = true }
        widget._cover_picker = {}
        widget:setPendingCover("/tmp/new-cover.jpg", false, "hardcover")

        local content = widget:_bookDetailsContent(400, 300, {}, true)
        local cover = content[1][2][1]

        assert.are.equal("/tmp/new-cover.jpg", cover.cover.data.file)
        assert.is_true(cover.uniform)
        assert.is_true(cover.decorated)
        assert.is_true(widget._cover_picker.dirtied)
    end)

    it("preserves a square staged cover when uniform covers are disabled", function()
        uniform_covers = false
        local widget = editor({ title = "Book" })
        widget.pending_cover = { path = "/tmp/square-cover.jpg" }

        local content = widget:_bookDetailsContent(400, 300, {}, true)
        local cover = content[1][2][1]

        assert.is_false(cover.uniform)
        assert.are.equal(120, cover.width)
        assert.are.equal(120, cover.height)
        assert.is_true(cover.decorated)
    end)

    it("preserves pagination across rotation", function()
        local widget = editor({ title = "Book" })
        widget.page = 2
        widget.init = function(self)
            self.page = 1
            self.page_num = 3
            self.item_table = { {}, {}, {} }
        end
        local selected, no_recalculate
        widget.updateItems = function(_self, value, no_recalc)
            selected, no_recalculate = value, no_recalc
        end

        assert.is_false(Editor.Widget.onScreenResize(widget))
        assert.are.equal(2, widget.page)
        assert.are.equal(1, selected)
        assert.is_true(no_recalculate)
    end)

    it("moves between horizontal actions in physical RTL direction", function()
        local widget = editor({ title = "Book" })
        local move
        widget.layout = { { "open", "save" } }
        widget.selected = { x = 2, y = 1 }
        widget.onFocusMove = function(_self, delta)
            move = delta
            return true
        end
        package.loaded["ui/bidi"].mirroredUILayout = function() return true end

        assert.is_true(widget:onZenMetadataFocusLeft())
        assert.are.same({ -1, 0 }, move)
        assert.is_true(widget:onZenMetadataFocusRight())
        assert.are.same({ 1, 0 }, move)
    end)
end)
