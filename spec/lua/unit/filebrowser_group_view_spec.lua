describe("file browser group views", function()
    local SortFixtures = require("sort_fixtures")
    local api
    local config
    local menus
    local shown
    local closed
    local dialogs
    local metadata
    local statuses
    local saved
    local opened
    local file_dialog_args
    local sort_dialog_args
    local legacy_tbr_calls
    local tbr_collection_changes
    local tbr_get_options
    local select_menu_calls
    local home_rebuilds
    local saved_modules
    local replaced_modules = {
        "gettext",
        "config/manager",
        "common/book_status",
        "common/history_index",
        "common/inline_icon_map",
        "common/language_name",
        "common/paths",
        "common/shared_state",
        "modules/filebrowser/patches/standalone_page",
        "common/db_bookinfo",
        "common/tbr_index",
        "bookinfomanager",
        "covermenu",
        "listmenu",
        "common/cover_utils",
        "ui/widget/menu",
        "ui/uimanager",
        "ui/widget/buttondialog",
        "device",
        "ui/gesturerange",
        "ui/geometry",
        "libs/libkoreader-lfs",
        "util",
        "apps/filemanager/filemanagerutil",
        "apps/filemanager/filemanager",
        "ui/widget/filechooser",
        "ui/widget/booklist",
    }

    local function find_menu(name)
        for _i, menu in ipairs(menus) do
            if menu.name == name then return menu end
        end
    end

    local function install_group_view(groups)
        config = {
            features = { browser_hide_up_folder = true },
            browser_hide_up_folder = { hide_up_folder = true },
            group_view = { display_mode = {} },
        }
        menus, shown, closed, dialogs = {}, {}, {}, {}
        metadata, statuses, opened = {}, {}, {}
        saved, file_dialog_args, sort_dialog_args = 0, nil, nil
        legacy_tbr_calls = 0
        tbr_collection_changes = 0
        tbr_get_options = nil
        select_menu_calls = 0
        home_rebuilds = 0

        local plugin = {
            config = config,
            saveConfig = function()
                saved = saved + 1
            end,
        }

        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("config/manager", {
            load = function() return config end,
            save = function(cfg) config = cfg end,
        })
        ZenSpec.replace("common/book_status", {
            getEffectiveStatusFromFile = function(path) return statuses[path] end,
            includeNewInTBREnabled = function() return false end,
        })
        ZenSpec.replace("common/history_index", {
            load = function() return groups.history or {} end,
            fileTime = function(index, path) return index[path] end,
        })
        ZenSpec.replace("common/inline_icon_map", { filename = "filename" })
        ZenSpec.replace("common/language_name", {
            get = function(language)
                return language == "en" and "English" or language
            end,
        })
        ZenSpec.replace("common/paths", { normPath = function(path) return path end })
        ZenSpec.replace("common/shared_state", {
            registerLoader = function() end,
            register = function(_, exports)
                api = exports.group_view
                return {}
            end,
            restore = function() return {} end,
            get = function(_, key)
                if key == "home" then
                    return { rebuildActive = function() home_rebuilds = home_rebuilds + 1 end }
                end
            end,
        })
        ZenSpec.replace("modules/filebrowser/patches/standalone_page", {
            create_menu = function(spec)
                spec.page = spec.page or 1
                spec.update_count = 0
                spec.updateItems = function(self)
                    self.update_count = self.update_count + 1
                end
                table.insert(menus, spec)
                return spec
            end,
            prepare_shell = function() end,
            hide_page_arrow = function() end,
            suppress_page_info_tap = function() end,
            apply_status_row = function(menu, options)
                menu._test_back_callback = options.back_callback
            end,
        })
        ZenSpec.replace("common/db_bookinfo", {
            getGroupedByAuthor = function() return groups.authors or {} end,
            getGroupedBySeries = function() return groups.series or {} end,
            getGroupedByLanguage = function() return groups.languages or {} end,
            getGroupedByTags = function() return groups.tags or {} end,
            getLightMetadata = function() return metadata end,
            getTBRBooks = function()
                legacy_tbr_calls = legacy_tbr_calls + 1
                return groups.tbr or {}
            end,
        })
        ZenSpec.replace("common/tbr_index", {
            getAll = function(options)
                tbr_get_options = options
                return groups.tbr or {}
            end,
            collectionChanged = function() tbr_collection_changes = tbr_collection_changes + 1 end,
            collectionName = function() return "To Be Read" end,
            isExplicit = function() return false end,
            isAuditComplete = function() return true end,
        })
        ZenSpec.replace("bookinfomanager", {
            getSetting = function() return nil end,
            getBookInfo = function(_, path) return metadata[path] end,
        })
        ZenSpec.replace("covermenu", {
            updateItems = function(self)
                self.update_count = self.update_count + 1
            end,
            onCloseWidget = function() end,
        })
        ZenSpec.replace("listmenu", {
            _recalculateDimen = function() end,
            _updateItemsBuildUI = function() end,
        })
        ZenSpec.replace("common/cover_utils", {
            getFilesPerPage = function() return 10 end,
        })
        ZenSpec.replace("ui/widget/menu", {
            updateItems = function(self)
                self.update_count = self.update_count + 1
            end,
        })
        ZenSpec.replace("ui/uimanager", {
            show = function(_, widget) table.insert(shown, widget) end,
            isWidgetShown = function(_, widget) return widget._test_shown ~= false end,
            close = function(_, widget)
                table.insert(closed, widget)
                if widget.onCloseWidget then widget:onCloseWidget() end
            end,
            nextTick = function(_, callback) callback() end,
            isShown = function() return true end,
        })
        ZenSpec.replace("ui/widget/buttondialog", {
            new = function(_, spec)
                table.insert(dialogs, spec)
                return spec
            end,
        })
        ZenSpec.replace("device", {
            isTouchDevice = function() return false end,
            screen = { getWidth = function() return 600 end, getHeight = function() return 800 end },
        })
        ZenSpec.replace("ui/gesturerange", {
            new = function(_, spec) return spec end,
        })
        ZenSpec.replace("ui/geometry", {
            new = function(_, spec) return spec end,
        })
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function(path, field)
                if field == "access" then return metadata[path] and metadata[path].access or 0 end
                return { size = metadata[path] and metadata[path].size or 0 }
            end,
        })
        ZenSpec.replace("util", {
            getFriendlySize = function(size) return tostring(size) .. " B" end,
        })
        ZenSpec.replace("apps/filemanager/filemanagerutil", {
            openFile = function(_, path) table.insert(opened, path) end,
        })
        ZenSpec.replace("apps/filemanager/filemanager", {
            instance = {
                onShowPlusMenu = function() select_menu_calls = select_menu_calls + 1 end,
                file_chooser = {
                    showFileDialog = function(_, args) file_dialog_args = args end,
                    showSortOrderDialog = function(_, args) sort_dialog_args = args end,
                    refreshPath = function() end,
                },
            },
        })
        ZenSpec.replace("ui/widget/filechooser", { show_filter = {} })
        ZenSpec.replace("ui/widget/booklist", { collates = SortFixtures.collates(metadata) })

        _G.__ZEN_UI_PLUGIN = plugin
        _G.__ZEN_UI_LIBRARY_STATE = nil
        ZenSpec.unload("modules/filebrowser/patches/group_view")
        require("modules/filebrowser/patches/group_view")()
        _G.__ZEN_UI_PLUGIN = nil
    end

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(replaced_modules) do
            saved_modules[name] = package.loaded[name] or false
        end
    end)

    after_each(function()
        _G.__ZEN_UI_PLUGIN = nil
        _G.__ZEN_UI_LIBRARY_STATE = nil
        ZenSpec.unload("modules/filebrowser/patches/group_view")
        for _i, name in ipairs(replaced_modules) do
            package.loaded[name] = saved_modules[name] or nil
        end
    end)

    it("normalizes last-name sort keys", function()
        install_group_view({})
        local author_sort = require("common/author_sort")
        assert.are.equal("Me", author_sort.key("Test Me (Test company)", "authors_last"))
        assert.are.equal("Martinez", author_sort.key("Miguel Rodrigo Martinez&#x20;", "authors_last"))
    end)

    it("builds author, series, language, and tag pages from database groups", function()
        install_group_view({
            authors = {
                { author = "Ada\nLovelace", files = { "/a.epub", "/b.epub" } },
            },
            series = {
                { series = "Earthsea", items = { { file = "/e1.epub" }, { file = "/e2.epub" } } },
            },
            languages = {
                { language = "en", files = { "/en.epub" } },
            },
            tags = {
                { tag = "Science", files = { "/s.epub" } },
            },
        })

        api.showAuthorsView()
        api.showSeriesView()
        api.showLanguagesView()
        api.showTagsView()

        local authors = assert(find_menu("authors"))
        local series = assert(find_menu("series"))
        local languages = assert(find_menu("languages"))
        local tags = assert(find_menu("tags"))
        assert.are.equal("Ada, Lovelace", authors.item_table[1].text)
        assert.are.equal("2 \u{F016}", authors.item_table[1].mandatory)
        assert.are.same({ "/e1.epub", "/e2.epub" }, series.item_table[1]._zen_files)
        assert.are.equal("English", languages.item_table[1].text)
        assert.are.equal("Science", tags.item_table[1].text)
        assert.are.equal(1, authors.update_count)
        assert.are.equal(1, series.update_count)
        assert.are.equal(1, tags.update_count)
    end)

    it("uses the tag-group context menu for external group folders", function()
        install_group_view({})

        assert.is_true(api.showGroupContextMenu(
            "Focus", { "/focus.epub" }, "tags"))
        assert.are.equal("Focus", file_dialog_args._zen_group_name)
        assert.are.same({ "/focus.epub" }, file_dialog_args._zen_group_files)
        assert.is_function(file_dialog_args._zen_sort_cb)
        assert.is_function(file_dialog_args._zen_display_cb)
    end)

    it("persists display modes and opens another group after backing out", function()
        install_group_view({
            authors = {
                { author = "Ada", files = { "/ada.epub" } },
                { author = "Grace", files = { "/grace.epub" } },
            },
        })
        config.group_view.display_mode.authors = "list_image_filename"
        package.loaded.device.isTouchDevice = function() return true end

        api.showAuthorsView()
        local root = assert(find_menu("authors"))
        root.onMenuSelect(root, root.item_table[1])
        local ada = assert(find_menu("authors_detail"))
        assert.is_true(ada._do_filename_only)

        ada:onZenDetailBlankHold()
        file_dialog_args._zen_display_cb()
        dialogs[#dialogs].buttons[2][1].callback()

        assert.are.equal(
            "list_image_meta",
            config.group_view.detail_display_mode.authors.Ada)
        assert.are.equal("list_image_filename", config.group_view.display_mode.authors)
        assert.is_true(root._do_filename_only)
        assert.are.equal(1, saved)
        assert.is_false(ada._do_filename_only)
        ada._test_back_callback()

        root.onMenuSelect(root, root.item_table[2])
        local grace = assert(menus[#menus])
        assert.are.equal("Grace", grace._zen_group_name)
        assert.is_true(grace._do_filename_only)
    end)

    it("omits context actions for Home strip group folders", function()
        install_group_view({})

        assert.is_true(api.showGroupContextMenu(
            "Focus", { "/focus.epub" }, "tags", nil, { hide_actions = true }))
        assert.are.equal("Focus", file_dialog_args._zen_group_name)
        assert.are.same({ "/focus.epub" }, file_dialog_args._zen_group_files)
        assert.is_nil(file_dialog_args._zen_sort_cb)
        assert.is_nil(file_dialog_args._zen_display_cb)
    end)

    it("opens root and TBR section context menus without opening their pages", function()
        install_group_view({
            authors = { { author = "Ada", files = { "/a.epub" } } },
            tbr = { "/later.epub", "/next.epub" },
        })

        assert.is_true(api.showSourceContextMenu("authors"))
        assert.are.equal("Authors", file_dialog_args._zen_group_name)
        assert.are.equal("1 author", file_dialog_args._zen_group_subtitle)
        assert.is_function(file_dialog_args._zen_sort_cb)
        assert.is_function(file_dialog_args._zen_display_cb)
        assert.are.equal(0, #menus)

        assert.is_true(api.showSourceContextMenu("to_be_read"))
        assert.are.equal("To Be Read", file_dialog_args._zen_group_name)
        assert.are.equal("2 books", file_dialog_args._zen_group_subtitle)
        assert.are.same({ "/later.epub", "/next.epub" },
            file_dialog_args._zen_group_files)
        assert.are.equal(0, #menus)
    end)

    it("reuses an open group page", function()
        install_group_view({
            authors = {
                { author = "Ada", files = { "/a.epub" } },
            },
        })

        local first = api.showAuthorsView()
        local second = api.showAuthorsView()

        assert.are.equal(first, second)
        assert.are.equal(1, #menus)
        assert.are.equal(1, #shown)

        first.close_callback()
        local reopened = api.showAuthorsView()
        assert.are_not.equal(first, reopened)
        assert.are.equal(2, #menus)
        assert.are.equal(2, #shown)
    end)

    it("names the missing metadata in an empty group page", function()
        install_group_view({})

        api.showAuthorsView()
        api.showSeriesView()
        api.showTagsView()

        local empty_messages = {
            authors = "No books with author metadata found",
            series = "No books with series metadata found",
            tags = "No books with tags metadata found",
        }
        for tab_id, message in pairs(empty_messages) do
            local item = assert(find_menu(tab_id)).item_table[1]
            assert.are.equal(message, item.text)
            assert.is_true(item.dim)
            assert.is_function(item.callback)
            assert.is_true(item._zen_empty_placeholder)
        end
    end)

    it("names an empty TBR page", function()
        install_group_view({ tbr = {} })

        api.showTBRView()

        local item = assert(find_menu("to_be_read")).item_table[1]
        assert.are.equal("No TBR books found", item.text)
        assert.is_true(item.dim)
        assert.is_true(item._zen_empty_placeholder)
        assert.is_true(find_menu("to_be_read")._zen_group_view)
        assert.are.equal(0, legacy_tbr_calls)
    end)

    it("rebuilds a stale TBR page so navbar taps can reopen it", function()
        install_group_view({ tbr = {} })

        local first = api.showTBRView()
        first._test_shown = false
        local reopened = api.showTBRView()

        assert.are_not.equal(first, reopened)
        assert.are.equal(2, #shown)
    end)

    it("refreshes an open TBR page with the current shared order", function()
        install_group_view({ tbr = { "/a.epub" } })
        config.group_view.detail_collate = {
            to_be_read = { to_be_read = "title" },
        }
        api.showTBRView()

        config.group_view.detail_collate.to_be_read.to_be_read = "manual"
        assert.is_true(api.refreshTBRView())

        assert.are.equal("manual", tbr_get_options.collate)
        assert.is_false(tbr_get_options.reverse)
        assert.are.equal(1, tbr_collection_changes)
        assert.are.equal(2, find_menu("to_be_read").update_count)
    end)

    it("names the group metadata when a detail page has no books", function()
        install_group_view({
            authors = { { author = "Ada", files = {} } },
            series = { { series = "Earthsea", items = {} } },
            tags = { { tag = "Science", files = {} } },
        })

        api.showAuthorsView()
        api.showSeriesView()
        api.showTagsView()

        local empty_messages = {
            authors = "No books with author metadata found",
            series = "No books with series metadata found",
            tags = "No books with tags metadata found",
        }
        for tab_id, message in pairs(empty_messages) do
            local root = assert(find_menu(tab_id))
            root.onMenuSelect(root, root.item_table[1])
            local item = assert(find_menu(tab_id .. "_detail")).item_table[1]
            assert.are.equal(message, item.text)
            assert.is_true(item.dim)
        end
    end)

    it("persists author name and direction sorting and rebuilds the open page", function()
        install_group_view({
            authors = {
                { author = "Octavia Butler", files = { "/o.epub" } },
                { author = "Jane Austen", files = { "/j.epub" } },
                { author = "Alice Klein", files = { "/a.epub" } },
                { author = "Gabriel García Márquez", files = { "/g.epub" } },
            },
        })
        package.loaded.device.isTouchDevice = function() return true end
        api.showAuthorsView()
        local menu = assert(find_menu("authors"))
        menu:onZenGroupBlankHold()
        assert.is_function(file_dialog_args._zen_sort_cb)
        file_dialog_args._zen_sort_cb()
        local author_dialog = dialogs[#dialogs]
        assert.is_truthy(author_dialog.buttons[1][1].text:find("\u{F04BB}", 1, true))
        assert.is_truthy(author_dialog.buttons[1][1].text:find("First name", 1, true))
        assert.is_truthy(author_dialog.buttons[2][1].text:find("Last name", 1, true))
        author_dialog.buttons[2][1].callback()

        assert.are.equal("authors_last", config.group_view.authors_collate)
        assert.are.equal(1, home_rebuilds)
        assert.are.same({ "Jane Austen", "Octavia Butler", "Alice Klein", "Gabriel García Márquez" }, {
            menu.item_table[1].text,
            menu.item_table[2].text,
            menu.item_table[3].text,
            menu.item_table[4].text,
        })

        menu:onZenGroupBlankHold()
        file_dialog_args._zen_sort_cb()
        author_dialog = dialogs[#dialogs]
        author_dialog.buttons[3][1].callback()
        sort_dialog_args.on_select(true)

        assert.is_true(config.group_view.group_reverse.authors)
        assert.are.equal(2, home_rebuilds)
        assert.are.equal(2, saved)
        assert.are.same({ "Gabriel García Márquez", "Alice Klein", "Octavia Butler", "Jane Austen" }, {
            menu.item_table[1].text,
            menu.item_table[2].text,
            menu.item_table[3].text,
            menu.item_table[4].text,
        })
        assert.are.equal(3, menu.update_count)
    end)

    it("sorts series names without articles and persists natural title sorting", function()
        install_group_view({
            series = {
                { series = "The Saga 10", items = { { file = "/ten.epub" } } },
                { series = "Saga 2", items = { { file = "/two.epub" } } },
                { series = "An Alpha", items = { { file = "/alpha.epub" } } },
            },
        })
        package.loaded.device.isTouchDevice = function() return true end

        api.showSeriesView()
        local menu = assert(find_menu("series"))
        assert.are.same({ "An Alpha", "The Saga 10", "Saga 2" }, {
            menu.item_table[1].text,
            menu.item_table[2].text,
            menu.item_table[3].text,
        })

        menu:onZenGroupBlankHold()
        file_dialog_args._zen_sort_cb()
        local sort_dialog = dialogs[#dialogs]
        assert.is_false(sort_dialog.buttons[1][1].enabled)
        assert.is_truthy(sort_dialog.buttons[2][1].text:find("Title natural", 1, true))
        sort_dialog.buttons[2][1].callback()

        assert.are.equal("title_natural", config.group_view.group_collate.series)
        assert.are.same({ "An Alpha", "Saga 2", "The Saga 10" }, {
            menu.item_table[1].text,
            menu.item_table[2].text,
            menu.item_table[3].text,
        })
        assert.are.equal(1, saved)
        assert.are.equal(1, home_rebuilds)
    end)

    it("opens series detail pages sorted by numeric series index", function()
        install_group_view({
            series = {
                { series = "Saga", items = {
                    { file = "/third.epub" }, { file = "/first.epub" }, { file = "/second.epub" },
                } },
            },
        })
        metadata["/first.epub"] = { series_index = "3", size = 10 }
        metadata["/second.epub"] = { series_index = 1, size = 20 }
        metadata["/third.epub"] = { series_index = 2, size = 30 }

        api.showSeriesView()
        local root = assert(find_menu("series"))
        root.onMenuSelect(root, root.item_table[1])

        local detail = assert(find_menu("series_detail"))
        assert.are.same({ "second", "third", "first" }, {
            detail.item_table[1].text,
            detail.item_table[2].text,
            detail.item_table[3].text,
        })
        assert.are.equal("20 B", detail.item_table[1].mandatory)
        assert.are.same({ group_name = "Saga", tab_id = "series", page = 1 }, api.getActiveDetail())
    end)

    it("sorts detail books by batched library metadata", function()
        install_group_view({
            series = {
                { series = "Saga", items = {
                    { file = "/zeta.epub" }, { file = "/alpha.epub" },
                } },
            },
        })
        config.group_view.detail_collate = { series = { Saga = "title" } }
        metadata["/alpha.epub"] = { title = "Mystery", size = 1 }
        metadata["/zeta.epub"] = { title = "Anthology", size = 2 }

        api.showSeriesView()
        local root = assert(find_menu("series"))
        root.onMenuSelect(root, root.item_table[1])

        local detail = assert(find_menu("series_detail"))
        assert.are.same({ "zeta", "alpha" }, {
            detail.item_table[1].text,
            detail.item_table[2].text,
        })
    end)

    it("sorts recently read detail books from read history", function()
        local groups = {
            history = { ["/older.epub"] = 100, ["/newer.epub"] = 200 },
            authors = {
                { author = "Writer", files = { "/older.epub", "/newer.epub" } },
            },
        }
        install_group_view(groups)
        config.group_view.detail_collate = { authors = { Writer = "access" } }
        metadata["/older.epub"] = { access = 300 }
        metadata["/newer.epub"] = { access = 100 }

        api.showAuthorsView()
        local root = assert(find_menu("authors"))
        root.onMenuSelect(root, root.item_table[1])

        local detail = assert(find_menu("authors_detail"))
        assert.are.same({ "newer", "older" }, {
            detail.item_table[1].text,
            detail.item_table[2].text,
        })
    end)

    it("applies saved title sort, reverse state, and status filtering to author details", function()
        install_group_view({
            authors = {
                { author = "Writer", files = { "/the-zebra.epub", "/apple.epub", "/beta.epub" } },
            },
        })
        config.group_view.detail_collate = { authors = { Writer = "title" } }
        config.group_view.detail_reverse = { authors = { Writer = true } }
        metadata["/the-zebra.epub"] = { title = "The Zebra" }
        metadata["/apple.epub"] = { title = "Apple" }
        metadata["/beta.epub"] = { title = "Beta" }
        statuses["/the-zebra.epub"] = "complete"
        statuses["/apple.epub"] = "reading"
        statuses["/beta.epub"] = "complete"
        package.loaded["ui/widget/filechooser"].show_filter.status = { complete = true }

        api.showAuthorsView()
        local root = assert(find_menu("authors"))
        root.onMenuSelect(root, root.item_table[1])

        local detail = assert(find_menu("authors_detail"))
        assert.are.same({ "the-zebra", "beta" }, {
            detail.item_table[1].text,
            detail.item_table[2].text,
        })
    end)

    it("saves per-series detail sorting and rebuilds the visible book page", function()
        install_group_view({
            series = {
                { series = "Saga", items = { { file = "/z.epub" }, { file = "/a.epub" } } },
            },
        })
        metadata["/z.epub"] = { title = "Zulu", series_index = 1 }
        metadata["/a.epub"] = { title = "Alpha", series_index = 2 }
        package.loaded.device.isTouchDevice = function() return true end

        api.showSeriesView()
        local root = assert(find_menu("series"))
        root.onMenuSelect(root, root.item_table[1])
        local detail = assert(find_menu("series_detail"))
        assert.are.same({ "z", "a" }, { detail.item_table[1].text, detail.item_table[2].text })

        detail:onZenDetailBlankHold()
        file_dialog_args._zen_sort_cb()
        local sort_dialog = dialogs[#dialogs]
        sort_dialog.buttons[2][1].callback()

        assert.are.equal("title", config.group_view.detail_collate.series.Saga)
        assert.are.same({ "a", "z" }, { detail.item_table[1].text, detail.item_table[2].text })
        assert.are.equal(1, saved)
    end)

    it("offers filename sorting and rebuilds detail pages by filesystem name", function()
        install_group_view({
            authors = {
                { author = "Writer", files = { "/zeta.epub", "/alpha.epub" } },
            },
        })
        metadata["/zeta.epub"] = { title = "Alpha" }
        metadata["/alpha.epub"] = { title = "Zulu" }
        package.loaded.device.isTouchDevice = function() return true end

        api.showAuthorsView()
        local root = assert(find_menu("authors"))
        root.onMenuSelect(root, root.item_table[1])
        local detail = assert(find_menu("authors_detail"))
        assert.are.same({ "zeta", "alpha" }, {
            detail.item_table[1].text,
            detail.item_table[2].text,
        })

        detail:onZenDetailBlankHold()
        file_dialog_args._zen_sort_cb()
        local sort_dialog = dialogs[#dialogs]
        assert.is_truthy(sort_dialog.buttons[4][1].text:find("Filename", 1, true))
        sort_dialog.buttons[4][1].callback()

        assert.are.equal("strcoll", config.group_view.detail_collate.authors.Writer)
        assert.are.same({ "alpha", "zeta" }, {
            detail.item_table[1].text,
            detail.item_table[2].text,
        })
    end)

    it("applies every detail sort method in ascending and descending order", function()
        local fixture = SortFixtures.new()
        install_group_view({
            history = fixture.access,
            authors = { { author = "Writer", files = SortFixtures.paths_from_entries(fixture.entries) } },
        })
        for path, props in pairs(fixture.metadata) do metadata[path] = props end

        local methods = { "series_index", "strcoll", "title", "title_natural", "access" }
        for _i, method in ipairs(methods) do
            for _j, reverse in ipairs({ false, true }) do
                config.group_view.detail_collate = { authors = { Writer = method } }
                config.group_view.detail_reverse = { authors = { Writer = reverse } }
                api.closeAll()
                menus = {}
                api.showAuthorsView()
                local root = assert(find_menu("authors"))
                root.onMenuSelect(root, root.item_table[1])
                local detail = assert(find_menu("authors_detail"))
                local actual = {}
                for _k, item in ipairs(detail.item_table) do
                    actual[#actual + 1] = item.path
                end
                local expected = reverse and SortFixtures.reversed(fixture.expected[method])
                    or fixture.expected[method]
                assert.are.same(expected, actual, method .. " reverse=" .. tostring(reverse))
            end
        end
    end)

    it("keeps the Tags page sort limited to tag names", function()
        install_group_view({
            tags = { { tag = "Classics", files = { "/book.epub" } } },
        })
        package.loaded.device.isTouchDevice = function() return true end
        api.showTagsView()
        local menu = assert(find_menu("tags"))

        menu:onZenGroupBlankHold()
        file_dialog_args._zen_sort_cb()
        local sort_dialog = dialogs[#dialogs]
        assert.are.equal(3, #sort_dialog.buttons)
        assert.is_truthy(sort_dialog.buttons[1][1].text:find("Title", 1, true))
        assert.is_truthy(sort_dialog.buttons[2][1].text:find("Title natural", 1, true))
        assert.is_truthy(sort_dialog.buttons[3][1].text:find("Order", 1, true))
    end)

    it("restores root and detail pages after returning from the reader", function()
        install_group_view({
            tags = {
                { tag = "Later", files = { "/later.epub" } },
                { tag = "Focus", files = { "/focus.epub" } },
            },
        })
        metadata["/focus.epub"] = { title = "Focus" }
        _G.__ZEN_UI_LIBRARY_STATE = {
            tab = "tags",
            page = 4,
            detail_group = "Focus",
            detail_page = 3,
        }

        api.showTagsView()

        local root = assert(find_menu("tags"))
        local detail = assert(find_menu("tags_detail"))
        assert.are.equal(4, root.page)
        assert.are.equal("Focus", detail._zen_group_name)
        assert.are.equal(3, detail.page)
        assert.is_nil(_G.__ZEN_UI_LIBRARY_STATE)
        assert.are.equal(4, api.getActivePage("tags"))
    end)

    it("opens books, navigates up, and closes every group-view layer", function()
        install_group_view({
            authors = { { author = "Writer", files = { "/book.epub" } } },
        })
        metadata["/book.epub"] = { title = "Book" }

        api.showAuthorsView()
        local root = assert(find_menu("authors"))
        root.onMenuSelect(root, root.item_table[1])
        local detail = assert(find_menu("authors_detail"))
        detail.onMenuSelect(detail, detail.item_table[1])
        assert.are.same({ "/book.epub" }, opened)

        detail.close_callback()
        assert.are.equal(detail, closed[#closed])
        assert.is_nil(api.getActiveDetail())

        root.onMenuSelect(root, { is_go_up = true })
        assert.are.equal(root, closed[#closed])
        assert.is_nil(api.getActivePage("authors"))

        api.showAuthorsView()
        local second_root = assert(menus[#menus])
        second_root.onMenuSelect(second_root, second_root.item_table[1])
        local second_detail = assert(menus[#menus])
        api.closeAll()
        assert.are.equal(second_root, closed[#closed])
        assert.is_nil(api.getActiveDetail())
        assert.is_nil(api.getActivePage("authors"))
        assert.is_true(#closed >= 4)
        assert.are.equal("authors_detail", second_detail.name)
    end)

    it("selects group-detail books without opening them", function()
        install_group_view({
            authors = { { author = "Writer", files = { "/book.epub" } } },
        })
        local file_manager = package.loaded["apps/filemanager/filemanager"].instance
        file_manager.selected_files = {}

        api.showAuthorsView()
        local root = assert(find_menu("authors"))
        root.onMenuSelect(root, root.item_table[1])
        local detail = assert(find_menu("authors_detail"))
        local book = detail.item_table[1]

        detail.onMenuSelect(detail, book)
        assert.is_true(book.dim)
        assert.is_true(file_manager.selected_files["/book.epub"])
        assert.are.equal(0, #opened)

        detail.onMenuSelect(detail, book)
        assert.is_nil(book.dim)
        assert.is_nil(file_manager.selected_files["/book.epub"])
        assert.are.equal(0, #opened)

        detail.onMenuHold(detail, book)
        assert.are.equal(1, select_menu_calls)
        assert.is_nil(file_dialog_args)
    end)

    it("marks the held group-detail book when Select enters selection mode", function()
        install_group_view({
            authors = { { author = "Writer", files = { "/book.epub" } } },
        })

        api.showAuthorsView()
        local root = assert(find_menu("authors"))
        root.onMenuSelect(root, root.item_table[1])
        local detail = assert(find_menu("authors_detail"))
        local book = detail.item_table[1]

        detail.onMenuHold(detail, book)
        assert.is_function(file_dialog_args._zen_select_cb)

        local file_manager = package.loaded["apps/filemanager/filemanager"].instance
        file_manager.selected_files = {}
        assert.is_true(file_dialog_args._zen_select_cb())
        assert.is_true(book.dim)
        assert.is_true(file_manager.selected_files["/book.epub"])
        assert.are.equal(0, #opened)
    end)
end)
