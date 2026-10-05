describe("end of book", function()
    local saved, settings, default_settings, plugin, status, shown, native_calls, menu, top
    local names = {
        "modules/reader/patches/end_book", "modules/reader/end_book_data",
        "modules/reader/end_book", "apps/reader/modules/readerstatus", "ui/uimanager",
        "ui/quickstart", "ui/menusorter", "datetime",
        "config/preset_store", "modules/filebrowser/patches/home/home_presets",
        "modules/settings/sections/end_book_settings", "common/ui/zen_arrange_list",
        "ffi/util",
        "modules/filebrowser/patches/home/components/registry", "ui/widget/infomessage",
        "apps/reader/readerui", "modules/filebrowser/patches/home_page", "common/shared_state",
        "common/db_bookinfo", "common/book_status",
        "modules/settings/sections/library_settings/home_settings", "ui/widget/spinwidget",
        "device", "ffi/blitbuffer", "ui/widget/focusmanager", "ui/geometry", "ui/gesturerange",
        "ui/widget/container/centercontainer", "ui/widget/container/framecontainer", "ui/widget/container/topcontainer",
        "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/widget/textwidget",
        "ui/widget/verticalgroup", "ui/widget/verticalspan", "common/ui/zen_icon_button",
        "common/plugin_root", "libs/libkoreader-lfs", "common/archive_actions", "ui/event", "common/clock_timer",
        "common/library_navigation", "common/ui/zen_icon_picker", "common/icon_packs",
        "apps/filemanager/filemanager", "apps/filemanager/filemanagerutil", "common/tbr_index",
        "modules/menu/app_launcher/native_menu", "ui/widget/inputdialog",
    }

    before_each(function()
        saved = {}
        for _i, name in ipairs(names) do
            saved[name] = { package.loaded[name], _G[name] }
            ZenSpec.unload(name)
        end
        settings = G_reader_settings
        default_settings = G_defaults
        _G.G_reader_settings = ZenSpec.memorySettings()
        plugin = { config = { _meta = {} }, saves = 0 }
        function plugin:saveConfig() self.saves = self.saves + 1 end
        _G.__ZEN_UI_PLUGIN = plugin
        shown, native_calls, top = 0, 0, nil
        status = { onEndOfBook = function() native_calls = native_calls + 1 end }
        menu = { document_end_action = { sub_item_table = { { text = "Auto mark" } } } }
        ZenSpec.replace("modules/menu/app_launcher/native_menu", { settingsItems = function(scope, id)
            assert.equals("active", scope)
            assert.equals("document_end_action", id)
            return { menu.document_end_action }
        end })
        ZenSpec.replace("apps/reader/modules/readerstatus", status)
        ZenSpec.replace("ui/uimanager", { getTopmostVisibleWidget = function() return top end })
        ZenSpec.replace("ui/quickstart", { quickstart_filename = "/quickstart.epub" })
        ZenSpec.replace("modules/settings/sections/library_settings/home_settings", {
            buildTextStyleItems = function(_config, _key, _label, _defaults, save)
                return {{ text = "Shared font controls", callback = save }}
            end,
        })
        ZenSpec.replace("ui/menusorter", { mergeAndSort = function(_self, _prefix, items)
            local action = items.document_end_action
            items.document_end_action = nil
            return { action }
        end })
        ZenSpec.replace("modules/reader/end_book", { show = function() shown = shown + 1 end })
        ZenSpec.replace("datetime", { secondsToClockDuration = function(_format, seconds) return tostring(seconds) end })
    end)

    local function load_end_book()
        for _i, name in ipairs({
            "ffi/blitbuffer", "ui/geometry", "ui/gesturerange", "device",
            "ui/widget/container/centercontainer", "ui/widget/container/framecontainer", "ui/widget/container/topcontainer",
            "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/widget/textwidget",
            "ui/widget/verticalgroup", "ui/widget/verticalspan", "common/ui/zen_icon_button",
        }) do ZenSpec.replace(name, {}) end
        ZenSpec.replace("ui/widget/focusmanager", { extend = function(_self, definition)
            definition.new = function(_class, opts) return opts end
            return definition
        end })
        ZenSpec.replace("common/plugin_root", "/plugin")
        ZenSpec.replace("libs/libkoreader-lfs", { currentdir = function() return "/koreader" end })
        ZenSpec.replace("modules/filebrowser/patches/home/components/registry", {})
        ZenSpec.unload("modules/reader/end_book")
        return require("modules/reader/end_book")
    end

    it("registers and releases the strip cover-ready listener", function()
        local EndBook = load_end_book()
        local page = setmetatable({}, { __index = EndBook })
        local notified = {}
        local unregister = page:registerStripCoverListener(function(path)
            notified[#notified + 1] = path
        end)
        page:_zen_home_notify_strip_cover("/library/pending.epub")
        assert.same({ "/library/pending.epub" }, notified)
        page.closed = true
        page:_zen_home_notify_strip_cover("/library/pending.epub")
        assert.equals(1, #notified)
        page.closed = false
        unregister()
        page:_zen_home_notify_strip_cover("/library/pending.epub")
        assert.equals(1, #notified)
    end)

    it("reuses the Home book menu in the reader and opens end-of-book strip settings", function()
        local EndBook = load_end_book()
        local item, owner, settings_id, settings_plugin, refreshes = nil, nil, nil, nil, 0
        local FileManager = { setupZenContextMenu = function(self)
            owner = self
            self.file_chooser.showFileDialog = function(_self, held) item = held; return true end
        end }
        ZenSpec.replace("apps/filemanager/filemanager", FileManager)
        ZenSpec.replace("common/tbr_index", {
            isExplicit = function(path) return path == "/library/tbr.epub" end,
            collectionName = function() return "To Be Read" end,
        })
        ZenSpec.replace("modules/settings/sections/end_book_settings", {
            openWidgetSettings = function(id, settings_owner)
                settings_id, settings_plugin = id, settings_owner
                return true
            end,
        })
        require("common/shared_state").get = function() return {
            invalidateBookCache = function() end, invalidateLibraryCache = function() end,
        } end
        plugin.config.end_book = { edit_mode = true }
        local page = setmetatable({ plugin = plugin, ui = { bookinfo = {} },
            data = { invalidateRecommendations = function() end },
            rebuild = function() refreshes = refreshes + 1 end,
        }, { __index = EndBook })
        assert.is_true(page:showBookMenu("/library/tbr.epub", "to_be_read"))
        assert.equals(page.ui.bookinfo, owner.bookinfo)
        assert.equals("/library/tbr.epub", item.path)
        assert.is_true(item.is_file)
        assert.is_true(item._zen_home_context)
        assert.is_true(item._zen_disable_select)
        assert.is_true(item._zen_hide_edit)
        assert.equals("To Be Read", item._zen_collection_name)
        assert.is_true(item._zen_widget_settings())
        assert.equals("strip", settings_id)
        assert.equals(plugin, settings_plugin)
        item._zen_after_status_change(item.path)
        assert.equals(1, refreshes)
        owner:onRefresh()
        assert.equals(2, refreshes)
        item._zen_collection_refresh()
        assert.equals(3, refreshes)
        plugin.config.end_book.edit_mode = false
        assert.is_true(page:showBookMenu("/library/recent.epub", "recently_read"))
        assert.is_true(item._zen_is_history)
        assert.is_nil(item._zen_collection_name)
        assert.is_nil(item._zen_widget_settings)
        item._zen_after_history_change()
        assert.equals(4, refreshes)
    end)

    it("lets book covers consume holds before whole-widget settings", function()
        local EndBook = load_end_book()
        local handled = false
        require("ui/widget/focusmanager").handleEvent = function(_self, event)
            assert.equals("hold", event.args[1].ges)
            handled = true
            return true
        end
        local page = setmetatable({ onGesture = function() error("whole-widget hold intercepted the cover") end },
            { __index = EndBook })
        assert.is_true(page:handleEvent({ handler = "onGesture", args = {{ ges = "hold" }} }))
        assert.is_true(handled)
    end)

    it("closes and flushes before restarting at page one, including last-read sort", function()
        local EndBook = load_end_book()
        local calls, next_tick = {}, nil
        local page = setmetatable({ ui = { doc_settings = {
            flush = function() calls[#calls + 1] = "flush" end,
        } }, onClose = function() calls[#calls + 1] = "close" end }, { __index = EndBook })
        ZenSpec.replace("ui/event", { new = function(_self, name, value) return { name, value } end })
        local manager = require("ui/uimanager")
        manager.nextTick = function(_self, callback) next_tick = callback end
        manager.broadcastEvent = function(_self, event) calls[#calls + 1] = event end
        G_reader_settings:saveSetting("collate", "access")
        local restart = require("modules/reader/end_book_data").actions[7]
        page:onFeaturedAction(restart)
        assert.same({ "flush", "close" }, calls)
        next_tick()
        assert.same({ "flush", "close", { "GotoPage", 1 } }, calls)
        page.preview = true
        assert.is_false(page:isActionAvailable(restart))
        page:onFeaturedAction(restart)
        assert.equals(3, #calls)
    end)

    it("renders default and customized action icons from plugin, stock, and active-pack files", function()
        load_end_book()
        local pack_dir
        ZenSpec.replace("common/icon_packs", { getActivePackDirectory = function() return pack_dir end })
        require("libs/libkoreader-lfs").attributes = function(path)
            if path == "/plugin/icons/restart.svg" or path == "/plugin/icons/atom.svg"
                    or path == "/pack/atom.svg" or path == "/koreader/resources/icons/mdlight/alarm.svg" then
                return "file"
            end
        end
        ZenSpec.replace("device", { screen = { scaleBySize = function(_self, size) return size end } })
        ZenSpec.replace("ui/geometry", { new = function(_self, opts) return opts end })
        local widget = { new = function(_self, opts)
            opts.image = {}
            opts.getSize = function(self)
                return self.dimen or { w = self.width or 0, h = self.height or 0 }
            end
            return opts
        end }
        for _i, name in ipairs({ "common/ui/zen_icon_button", "ui/widget/container/centercontainer",
                "ui/widget/verticalgroup", "ui/widget/horizontalgroup", "ui/widget/horizontalspan" }) do
            ZenSpec.replace(name, widget)
        end
        ZenSpec.unload("modules/reader/end_book")
        local EndBook = require("modules/reader/end_book")
        _G.G_defaults = ZenSpec.memorySettings({ DGENERIC_ICON_SIZE = 32 })
        local featured = { navigation_actions = { "restart", "library", "home" },
            navigation_icons = { library = "atom", home = "alarm" },
            show_navigation_labels = false, text_styles = { navigation = {} } }
        plugin.config.end_book = { modules = { featured = featured } }
        local page = setmetatable({ plugin = plugin, preview = true }, { __index = EndBook })
        for _i, active in ipairs({ false, true }) do
            pack_dir = active and "/pack" or nil
            page:buildNavigationRow(600, 200)
            assert.equals("/plugin/icons/restart.svg", page.featured_navigation_buttons[1].file)
            assert.equals(active and "/pack/atom.svg" or "/plugin/icons/atom.svg", page.featured_navigation_buttons[2].file)
            assert.equals("/koreader/resources/icons/mdlight/alarm.svg", page.featured_navigation_buttons[3].file)
        end
        assert.equals("library", require("modules/reader/end_book_data").actions[1].icon)
    end)

    it("restores the library location from the Library button and page-forward key when enabled", function()
        local EndBook = load_end_book()
        local Navigation = require("common/library_navigation")
        local next_tick, destination, closed
        local ui = { document = { file = "/library/book.epub" } }
        local page = setmetatable({ ui = ui, plugin = plugin,
            onClose = function() closed = true end,
        }, { __index = EndBook })
        Navigation.showFromReader = function(owner, owner_plugin, options)
            assert.equals(ui, owner)
            assert.equals(plugin, owner_plugin)
            destination = options
        end
        require("ui/uimanager").nextTick = function(_self, callback) next_tick = callback end
        plugin.config.features = {}
        local actions = require("modules/reader/end_book_data").actions
        for _i, restore in ipairs({ false, true }) do
            plugin.config.features.restore_library_view = restore
            for _j, activate in ipairs({
                function() page:onFeaturedAction(actions[1]) end,
                function() page:onLibrary() end,
            }) do
                destination, closed = nil, nil
                activate()
                assert.is_nil(closed)
                assert.is_nil(destination)
                next_tick()
                assert.is_true(closed)
                assert.same(restore and {} or { target_tab = "books" }, destination)
            end
        end
        for index = 2, 4 do
            destination, closed = nil, nil
            page:onFeaturedAction(actions[index])
            assert.is_nil(closed)
            assert.is_nil(destination)
            next_tick()
            assert.is_true(closed)
            assert.same(actions[index].destination, destination)
        end
        assert.same({ target_tab = "books" }, actions[1].destination)
        page.ui = nil
        local open_tab = _G.__ZEN_UI_NAVBAR_OPEN_TAB
        _G.__ZEN_UI_NAVBAR_OPEN_TAB = function(tab) destination = tab end
        destination, closed = nil, nil
        page:onLibrary()
        assert.is_nil(closed)
        next_tick()
        _G.__ZEN_UI_NAVBAR_OPEN_TAB = open_tab
        assert.is_true(closed)
        assert.equals("books", destination)
    end)

    it("keeps the strip visible until a book open is confirmed and leaves Preview read-only", function()
        local EndBook = load_end_book()
        local next_tick, open_callback, closed, cover
        local ui = {}
        local page = setmetatable({ ui = ui, data = { file = "/library/current.epub" },
            onClose = function() closed = true end,
            showCover = function(_self, path) cover = path; return true end,
        }, { __index = EndBook })
        require("ui/uimanager").nextTick = function(_self, callback) next_tick = callback end
        ZenSpec.replace("apps/filemanager/filemanagerutil", { openFile = function(owner, path, before_open)
            assert.equals(ui, owner)
            assert.equals("/library/next.epub", path)
            assert.is_nil(closed)
            open_callback = before_open
        end })

        page:openBook("/library/next.epub")
        assert.is_nil(closed)
        assert.is_nil(open_callback)
        next_tick()
        assert.is_nil(closed)
        assert.is_function(open_callback)
        open_callback()
        assert.is_true(closed)

        closed, next_tick = nil, nil
        page:openBook(page.data.file)
        assert.equals(page.data.file, cover)
        page.preview = true
        page:openBook("/library/next.epub")
        assert.equals("/library/next.epub", cover)
        assert.is_nil(closed)
        assert.is_nil(next_tick)
    end)

    it("pushes completed progress on close before freeing, using the Book Status KOSync guard", function()
        local EndBook = load_end_book()
        ZenSpec.replace("ui/event", { new = function(_self, name) return name end })
        ZenSpec.replace("common/clock_timer", { unbind = function() end })
        local manager = require("ui/uimanager")
        manager.setDirty = function() end
        local summary, sync_settings = { status = "complete" }, { auto_sync = true, username = "user", userkey = "key" }
        for _i, condition in ipairs({ "complete", "preview", "reading", "manual", "logged_out" }) do
            local calls = {}
            manager.broadcastEvent = function(_self, event) calls[#calls + 1] = event end
            summary.status = condition == "reading" and "reading" or "complete"
            sync_settings.auto_sync = condition ~= "manual"
            sync_settings.userkey = condition ~= "logged_out" and "key" or nil
            local page = setmetatable({ preview = condition == "preview",
                ui = { kosync = { settings = sync_settings }, doc_settings = { readSetting = function() return summary end } },
                free = function() calls[#calls + 1] = "free" end,
                data = { free = function() calls[#calls + 1] = "data" end },
            }, { __index = EndBook })
            page:onCloseWidget()
            assert.same(condition == "complete" and { "KOSyncPushProgress", "free", "data" } or { "free", "data" }, calls)
        end
    end)

    it("uses the Zen status header's Back button and refreshes only its region", function()
        local callback, latest_back, freed, dirty, closed
        local plugin_for_header = {}
        ZenSpec.replace("common/shared_state", { get = function(owner, key)
            assert.equals(plugin_for_header, owner)
            assert.equals("createStatusRowCustomBack", key)
            return function(back_callback)
                callback, latest_back = back_callback, {}
                return { getSize = function() return { w = 600, h = 20 } end,
                    free = function() freed = true end }, latest_back
            end
        end })
        local EndBook = load_end_book()
        local page = setmetatable({ plugin = plugin_for_header, layout = {},
            onClose = function() closed = true end }, { __index = EndBook })
        local header = page:buildStatusHeader()
        assert.same({ { latest_back } }, page.layout)
        assert.equals(page, latest_back.show_parent)
        callback()
        assert.is_true(closed)
        local region = { x = 0, y = 0, w = 600, h = 20 }
        page.header_widget = { header, dimen = region, getSize = function() return { h = 20 } end }
        require("ui/uimanager").setDirty = function(_self, owner, mode, bounds) dirty = { owner, mode, bounds } end
        page:_zen_status_refresh()
        assert.is_true(freed)
        assert.same({ { latest_back } }, page.layout)
        assert.equals(region, page.header_widget.dimen)
        assert.same({ page, "ui", region }, dirty)
    end)

    it("respects auto-mark before displaying a book and keeps Preview read-only", function()
        local EndBook = load_end_book()
        local summary, marks, flushes, displayed = { status = "reading" }, 0, 0
        local ui = { document = {}, doc_settings = {
            readSetting = function() return summary end,
            flush = function() flushes = flushes + 1 end,
        }, status = { markBook = function(_self, complete)
            assert.is_true(complete)
            summary.status = "complete"
            marks = marks + 1
        end } }
        require("ui/uimanager").show = function(_self, page) displayed = page end
        G_reader_settings:saveSetting("end_document_auto_mark", false)
        EndBook.show(ui, plugin, true)
        assert.are.equal("reading", summary.status)
        assert.are.equal(0, marks)
        assert.are.equal(0, flushes)
        assert.is_true(displayed.preview)
        EndBook.show(ui, plugin)
        assert.are.equal("reading", summary.status)
        assert.are.equal(0, marks)
        assert.are.equal(0, flushes)
        assert.is_nil(displayed.preview)
        G_reader_settings:saveSetting("end_document_auto_mark", true)
        EndBook.show(ui, plugin, true)
        assert.are.equal("reading", summary.status)
        assert.are.equal(0, marks)
        EndBook.show(ui, plugin)
        assert.are.equal("complete", summary.status)
        assert.are.equal(1, marks)
        assert.are.equal(1, flushes)
        assert.is_nil(displayed.preview)
        EndBook.show(ui, plugin)
        assert.are.equal(1, marks)
        EndBook.show(nil, plugin, true)
        assert.is_true(displayed.preview)
    end)

    it("reuses Archive confirmation and schedules Next file after closing the screen", function()
        local EndBook = load_end_book()
        local archive_call, next_tick, closed, flushed, opened, destination
        local ui = { doc_settings = { flush = function() flushed = true end },
            status = { onOpenNextOrPreviousFileInFolder = function() opened = true end } }
        local page = setmetatable({ ui = ui, data = { file = "book.epub" },
            onClose = function() closed = true end, leave = function(_self, options) destination = options end,
        }, { __index = EndBook })
        ZenSpec.replace("common/archive_actions", {
            canArchive = function(file) return file == "book.epub" end,
            markCompleteAndArchive = function(reader_status, screen) archive_call = { reader_status, screen } end,
        })
        require("ui/uimanager").nextTick = function(_self, callback) next_tick = callback end
        local actions = require("modules/reader/end_book_data").actions
        page:onFeaturedAction(actions[1])
        assert.same({ target_tab = "books" }, destination)
        page:onFeaturedAction(actions[5])
        assert.same({ ui.status, page }, archive_call)
        assert.is_nil(closed)
        page:onFeaturedAction(actions[6])
        assert.is_true(flushed)
        assert.is_true(closed)
        assert.is_nil(opened)
        next_tick()
        assert.is_true(opened)
        closed, flushed, opened, next_tick, archive_call = nil, nil, nil, nil, nil
        G_reader_settings:saveSetting("collate", "date")
        page:onFeaturedAction(actions[6])
        assert.is_nil(closed)
        page.preview = true
        page:onFeaturedAction(actions[5])
        page:onFeaturedAction(actions[6])
        assert.is_nil(archive_call)
        assert.is_nil(flushed)
        assert.is_nil(opened)
        assert.is_nil(next_tick)
    end)

    after_each(function()
        _G.G_reader_settings = settings
        _G.G_defaults = default_settings
        _G.__ZEN_UI_PLUGIN = nil
        for _i, name in ipairs(names) do
            package.loaded[name], _G[name] = saved[name][1], saved[name][2]
        end
    end)

    it("sets the default once and preserves subsequent native choices after reloading", function()
        local apply = require("modules/reader/patches/end_book")
        apply()
        assert.are.equal("zen_end_book", G_reader_settings:readSetting("end_document_action"))
        assert.is_true(G_reader_settings:readSetting("end_document_auto_mark"))
        assert.are.equal(1, plugin.saves)
        G_reader_settings:saveSetting("end_document_action", "nothing")
        G_reader_settings:saveSetting("end_document_auto_mark", false)
        ZenSpec.unload("modules/reader/patches/end_book")
        require("modules/reader/patches/end_book")()
        assert.are.equal("nothing", G_reader_settings:readSetting("end_document_action"))
        assert.is_false(G_reader_settings:readSetting("end_document_auto_mark"))
        assert.are.equal(1, plugin.saves)
        local actions = require("ui/menusorter"):mergeAndSort("reader", menu)[1].sub_item_table
        assert.are.equal(2, #actions)
        status:onEndOfBook()
        assert.are.equal(1, native_calls)
        assert.are.equal(0, shown)
        actions[2].callback()
        status:onEndOfBook()
        assert.are.equal(1, shown)
        top = { name = "zen_end_book" }
        status:onEndOfBook()
        assert.are.equal(1, shown)
        top = nil
        G_reader_settings:saveSetting("lastfile", "/quickstart.epub")
        status:onEndOfBook()
        assert.are.equal(1, shown)
    end)

    it("adds the Zen action to freshly built menus and preserves a saved action", function()
        G_reader_settings:saveSetting("end_document_action", "book_status")
        require("modules/reader/patches/end_book")()
        assert.are.equal("book_status", G_reader_settings:readSetting("end_document_action"))
        local sorter = require("ui/menusorter")
        for _i, prefix in ipairs({ "reader", "filemanager", "reader" }) do
            local items = { document_end_action = { sub_item_table = {
                { text = "Always mark as finished", separator = true },
                { text = "Do nothing", callback = function()
                    G_reader_settings:saveSetting("end_document_action", "nothing")
                end },
            } } }
            local actions = sorter:mergeAndSort(prefix, items)[1].sub_item_table
            assert.are.equal(3, #actions)
            assert.are.equal("Always mark as finished", actions[1].text)
            assert.are.equal("Zen end of book", actions[2].text)
            assert.is_true(actions[2].radio)
            actions[2].callback()
            assert.is_true(actions[2].checked_func())
            actions[3].callback()
            assert.is_false(actions[2].checked_func())
            actions[2].callback()
            assert.is_true(actions[2].checked_func())
        end
        assert.is_nil(sorter:mergeAndSort("other", {})[1])
        assert.are.equal(1, plugin.saves)
    end)

    it("does not change an explicit auto-mark preference on first initialization", function()
        G_reader_settings:saveSetting("end_document_auto_mark", false)
        require("modules/reader/patches/end_book")()
        assert.is_false(G_reader_settings:readSetting("end_document_auto_mark"))
    end)

    it("maps the End of book setting to the native document-end action menu", function()
        require("modules/reader/patches/end_book")()
        local action = menu.document_end_action
        require("ui/menusorter"):mergeAndSort("reader", menu)
        menu.document_end_action = action
        local items = require("modules/settings/sections/end_book_settings").build{ plugin = plugin }
        assert.are.equal(action, items[1])
        local zen = items[1].sub_item_table[2]
        assert.is_true(zen.checked_func())
        G_reader_settings:saveSetting("end_document_action", "book_status")
        assert.is_false(zen.checked_func())
        zen.callback()
        assert.are.equal("zen_end_book", G_reader_settings:readSetting("end_document_action"))
    end)

    it("uses only current-book statistics and handles missing or empty records", function()
        local gettext = require("gettext")
        local time_context = gettext.context.Time
        finally(function() gettext.context.Time = time_context end)
        gettext.context.Time = nil
        ZenSpec.unload("datetime")
        local Data = require("modules/reader/end_book_data")
        local thin_space, hair_space = "\u{2009}", "\u{200A}"
        assert.same({}, Data.stats(nil))
        local statistics = { getStatsBookStatus = function() return { days = 3, time = 7200, pages = 80 } end }
        assert.same({ book_days = "3", book_duration = "2h" .. thin_space .. "0m" .. thin_space .. "0s",
            book_page_minutes = "1m" .. hair_space .. "30s",
            book_daily_minutes = "40m" .. hair_space .. "0s" }, Data.stats(statistics))
        statistics.getStatsBookStatus = function() return { days = 1, time = 35, pages = 1 } end
        assert.equals("35s", Data.stats(statistics).book_page_minutes)
        assert.equals("35s", Data.stats(statistics).book_daily_minutes)
        statistics.getStatsBookStatus = function() return { days = 1, time = 5400, pages = 1 } end
        assert.equals("1h" .. hair_space .. "30m" .. hair_space .. "0s", Data.stats(statistics).book_page_minutes)
        assert.equals("1h" .. hair_space .. "30m" .. hair_space .. "0s", Data.stats(statistics).book_daily_minutes)
        gettext.context.Time = { h = "ч", m = "мин", s = "с", ["%1s"] = "%1с" }
        assert.equals("1ч" .. hair_space .. "30мин" .. hair_space .. "0с", Data.stats(statistics).book_page_minutes)
        assert.equals("1ч" .. hair_space .. "30мин" .. hair_space .. "0с", Data.stats(statistics).book_daily_minutes)
        statistics.getStatsBookStatus = function() return { days = 0, time = 0, pages = 0 } end
        assert.same({ book_days = "0", book_duration = "0с" }, Data.stats(statistics))
    end)

    it("includes highlight notes and display page labels without exporting xpointers as pages", function()
        local Data = require("modules/reader/end_book_data")
        local updated = false
        local ui = {
            doc_props = { title = "Book" },
            annotation = {
                updatePageNumbers = function() updated = true end,
                annotations = {
                    { page = "/xp/1", pageno = 7, text = "Quote", note = "Note", drawer = "lighten" },
                    { page = "/xp/2", text = "Page bookmark" },
                },
            },
            bookmark = { getBookmarkPageString = function() return "iv" end },
        }
        local quotes = Data.quotes(ui)
        assert.is_true(updated)
        assert.are.equal(1, #quotes)
        assert.are.equal("Quote\n\nNote", quotes[1].text)
        assert.are.equal("iv", quotes[1].page_label)
        assert.are.equal("/xp/1", quotes[1].page)
    end)

    it("includes unfinished books in the current series and only recommends other series already started", function()
        local Data = require("modules/reader/end_book_data")
        local function group(name, files)
            local items = {}
            for index, file in ipairs(files) do items[index] = { file = file, series_index = index } end
            return { series = name, items = items }
        end
        local states = { current = "complete", sequel = "complete", a = "complete", b = "reading",
            c = "complete", d = "complete", e = "complete" }
        local recommendations = Data.recommendations("current", {
            authors = "A\nB", series = "Main", series_index = 1,
        }, {
            { author = "A", files = { "current", "sequel" } },
            { author = "B", files = { "sequel", "another" } },
            { author = "Other", files = { "unrelated" } },
        }, {
            group("Main", { "current", "sequel", "third" }),
            group("Reading", { "a", "b", "later" }),
            group("Started", { "c", "next" }),
            group("Done", { "d", "e" }),
            group("Unstarted", { "new1", "new2" }),
        }, function(file) return states[file] end)
        assert.same({ author = { "sequel", "another" }, next_series = { "third" },
            other_series = { { series = "Reading", files = { "a", "b", "later" } },
                { series = "Started", files = { "c", "next" } } } }, recommendations)
    end)

    it("keeps unfinished current-series books in series order regardless of current index", function()
        local Data = require("modules/reader/end_book_data")
        local items = {
            { file = "z-first", series_index = 1 },
            { file = "prequel", series_index = 1.5 },
            { file = "current", series_index = 2 },
            { file = "a-last", series_index = 10 },
            { file = "unread", series_index = 11 },
        }
        local states = { ["z-first"] = "complete", prequel = "reading", ["a-last"] = "abandoned" }
        for _i, book in ipairs({ { series = "Series", series_index = 2 }, { series = "Series" } }) do
            local recommendations = Data.recommendations("current", book, {}, {
                { series = "Series", items = items },
            }, function(file) return states[file] end)
            assert.same({ "prequel", "a-last", "unread" }, recommendations.next_series)
        end
        local recommendations = Data.recommendations("current", { series = "Series" }, {}, {
            { series = "Series", items = items },
        }, function() return "complete" end)
        assert.same({}, recommendations.next_series)
    end)

    it("keeps the current series in series order when its strip is reversed", function()
        local Data = require("modules/reader/end_book_data")
        local home = require("modules/filebrowser/patches/home/home_presets").defaultHomePage()
        home.modules.strip.order = "reverse"
        ZenSpec.replace("config/preset_store", { getSettings = function() return home end })
        local config = { modules = { strip = { order = "reverse" } } }
        local recommendations = { next_series = { "first", "last" }, author = { "book" }, other_series = {} }
        local strip, source = Data.stripConfig(recommendations, "next_series", config)
        assert.equals("next_series", source)
        assert.equals("default", strip.order)
        assert.same({ kind = "custom", paths = recommendations.next_series }, strip.default_source)
        assert.equals("Next in series", require("common/nav_button_model").find(strip.controls, source).label)
        assert.equals("reverse", Data.stripConfig(recommendations, "author", config).order)
        assert.equals("default", Data.stripConfig(recommendations, "author").order)
        assert.equals("reverse", home.modules.strip.order)
    end)

    it("copies the Home appearance once and saves independent featured settings", function()
        local home = { modules = { featured = {
            show_author = false, show_progress = true, show_status_bar = true,
            progress_meta = { left = "percent", right = "current_total" },
            text_styles = { title = { font_size = 19, bold = false } },
        } } }
        ZenSpec.replace("config/preset_store", { getSettings = function(kind)
            assert.are.equal("home", kind)
            return home
        end })
        plugin.config.end_book = { modules = { featured = { show_status_bar = false, navigation_icon_size = 44,
            navigation_icons = { restart = "atom" } } } }
        local Data = require("modules/reader/end_book_data")
        local inherited = Data.featuredConfig(plugin)
        assert.is_false(inherited.show_author)
        assert.is_false(inherited.show_status_bar)
        assert.is_false(inherited.show_description)
        assert.same({ "library", "series", "to_be_read", "home" }, inherited.navigation_actions)
        assert.is_nil(home.modules.featured.navigation_actions)
        assert.are.equal(44, inherited.navigation_icon_size)
        assert.same({ restart = "atom" }, inherited.navigation_icons)
        assert.same(home.modules.featured.text_styles.title, inherited.text_styles.title)
        assert.is_nil(plugin.config.end_book.modules.featured.use_home_settings)
        assert.are.equal(1, plugin.saves)
        inherited.text_styles.title.font_size = 24
        plugin.config.end_book.modules.featured = inherited
        assert.are.equal(19, home.modules.featured.text_styles.title.font_size)
        assert.are.equal(24, Data.featuredConfig(plugin).text_styles.title.font_size)
        home.modules.featured.text_styles.title.font_size = 15
        assert.are.equal(24, Data.featuredConfig(plugin).text_styles.title.font_size)
        assert.are.equal(1, plugin.saves)
        plugin.config.end_book.modules.featured.use_home_settings = true
        plugin.config.end_book.modules.featured.navigation_actions = { "archive", "next_file" }
        assert.are.equal(15, Data.featuredConfig(plugin).text_styles.title.font_size)
        assert.same({ "archive", "next_file" }, Data.featuredConfig(plugin).navigation_actions)
        assert.same({ restart = "atom" }, Data.featuredConfig(plugin).navigation_icons)
        assert.is_nil(plugin.config.end_book.modules.featured.use_home_settings)
        assert.are.equal(2, plugin.saves)
        plugin.config.end_book.modules.featured.show_status_bar = true
        plugin.config.end_book.modules.featured.show_description = true
        local fixed = Data.featuredConfig(plugin)
        assert.is_false(fixed.show_status_bar)
        assert.is_false(fixed.show_description)
        assert.is_true(home.modules.featured.show_status_bar)
    end)

    it("caps featured actions at five unique known actions and allows an empty row", function()
        local Data = require("modules/reader/end_book_data")
        assert.are.equal(4, #Data.featuredActions({}))
        assert.same({}, Data.featuredActions({ navigation_actions = {} }))
        local actions = Data.featuredActions({ navigation_actions = {
            "unknown", "next_file", "next_file", "home", "archive", "series", "library", "to_be_read",
        } })
        local ids = {}
        for _i, entry in ipairs(actions) do ids[#ids + 1] = entry.id end
        assert.same({ "next_file", "home", "archive", "series", "library" }, ids)
    end)

    it("enlarges default end-screen styles once while preserving customized sizes and Home", function()
        local Presets = require("modules/filebrowser/patches/home/home_presets")
        local home = Presets.defaultHomePage()
        ZenSpec.replace("config/preset_store", { getSettings = function() return home end })
        plugin.config.end_book = require("common/utils").deepcopy(require("config/defaults").end_book)
        local Data = require("modules/reader/end_book_data")
        local featured = Data.featuredConfig(plugin)
        assert.same(Data.FEATURED_TEXT_STYLES.title, featured.text_styles.title)
        assert.equals(12, featured.text_styles.author.font_size)
        assert.equals(9, featured.text_styles.series.font_size)
        assert.equals(9, featured.text_styles.progress.font_size)
        assert.equals(featured.text_styles.progress.font_size, featured.text_styles.status.font_size)
        assert.equals(15, featured.text_styles.navigation.font_size)
        assert.equals(11, home.modules.featured.text_styles.title.font_size)
        plugin.config.end_book.modules.featured.text_styles.title.font_size = 11
        assert.equals(11, Data.featuredConfig(plugin).text_styles.title.font_size)
        assert.equals(1, plugin.saves)
    end)

    it("keeps strip settings independent of Home with only nonempty end-of-book sources", function()
        local Data = require("modules/reader/end_book_data")
        local Presets = require("modules/filebrowser/patches/home/home_presets")
        local home = Presets.defaultHomePage()
        local defaults = Presets.defaultHomePage().modules.strip
        local original = home.modules.strip
        original.count, original.two_rows, original.show_badges = 8, true, true
        original.center_books = true
        original.show_strip_titles, original.show_page_indicator, original.interactive = true, false, false
        original.order = "reverse"
        original.sources.recent.filter_finished = true
        original.controls.text_style = { font_face = "test", font_size = 13, bold = true }
        ZenSpec.replace("config/preset_store", { getSettings = function() return home end })
        local recommendations = { next_series = {}, author = { "book" }, other_series = {} }
        local strip, source = Data.stripConfig(recommendations, "next_series", nil, " Jane Austen\nMary Shelley ")
        assert.are.equal("author", source)
        local ButtonModel = require("common/nav_button_model")
        assert.are.equal("More by Jane Austen, Mary Shelley", ButtonModel.find(strip.controls, "author").label)
        for _key, key in ipairs({ "count", "show_badges", "show_strip_titles",
            "show_page_indicator", "interactive", "order" }) do
            assert.are.equal(defaults[key], strip[key])
        end
        assert.same(defaults.sources, strip.sources)
        assert.same(defaults.controls.text_style, strip.controls.text_style)
        assert.is_false(strip.two_rows)
        assert.is_true(original.two_rows)
        assert.is_false(strip.center_books)
        assert.is_true(original.center_books)
        assert.same({ "page_left", "next_series", "author", "continue", "other_series", "page_right" }, strip.controls.order)
        assert.same({ page_left = false, next_series = false, author = true,
            other_series = false, page_right = false, continue = false, to_be_read = false }, strip.controls.show_buttons)
        assert.same({ kind = "custom", paths = { "book" } }, strip.default_source)
        assert.same({ "page_left", "recent", "search", "tags", "page_right" }, original.controls.order)
        strip.controls.text_style.font_size = 20
        assert.are.equal(13, original.controls.text_style.font_size)
        recommendations.author = {}
        assert.is_nil(Data.stripConfig(recommendations, "author"))
        recommendations.other_series = { "series" }
        original.count = 6
        original.controls.text_style.font_size = 15
        local local_config = { modules = { strip = Data.stripConfig() } }
        local_config.modules.strip.controls.order = { "page_left", "next_series", "author", "other_series", "page_right" }
        local_config.modules.strip.controls.show_buttons.other_series = true
        strip, source = Data.stripConfig(recommendations, "author", local_config)
        assert.are.equal(defaults.count, strip.count)
        assert.are.equal(defaults.controls.text_style.font_size, strip.controls.text_style.font_size)
        assert.are.equal("other_series", source)
        assert.is_true(strip.controls.show_buttons.other_series)
        ButtonModel.find(local_config.modules.strip.controls, "author").label = "Same author"
        local_config.modules.strip.controls.show_buttons.page_right = true
        local_config.modules.strip.controls.text_style.font_size = 17
        local_config.modules.strip.count = 3
        local_config.modules.strip.center_books = true
        local_config.modules.strip.two_rows = true
        strip = Data.stripConfig(recommendations, "other_series", local_config)
        assert.is_true(strip.controls.show_buttons.page_right)
        assert.are.equal(17, strip.controls.text_style.font_size)
        assert.are.equal(3, strip.count)
        assert.is_true(strip.center_books)
        assert.is_true(strip.two_rows)
        local_config.modules.strip.center_books = false
        assert.is_false(Data.stripConfig(recommendations, "other_series", local_config).center_books)
        assert.are.equal(6, original.count)
        assert.are.equal("More by author", ButtonModel.find(strip.controls, "author").label)
        strip = Data.stripConfig(recommendations, "other_series", local_config, "New Author")
        assert.are.equal("More by New Author", ButtonModel.find(strip.controls, "author").label)
        local_config.modules.strip.controls.labels.author = "My label"
        strip = Data.stripConfig(recommendations, "other_series", local_config, "New Author")
        assert.are.equal("My label", ButtonModel.label(strip.controls, ButtonModel.find(strip.controls, "author")))
        assert.are.equal("Same author", ButtonModel.find(local_config.modules.strip.controls, "author").label)
    end)

    it("supports Continue and the existing Home sources without recommendation tabs", function()
        local home = require("modules/filebrowser/patches/home/home_presets").defaultHomePage()
        ZenSpec.replace("config/preset_store", { getSettings = function() return home end })
        local Data = require("modules/reader/end_book_data")
        local local_config = { modules = { strip = Data.stripConfig() } }
        local controls = local_config.modules.strip.controls
        assert.is_true(controls.show_buttons.continue)
        assert.is_false(controls.show_buttons.other_series)
        controls.labels.continue = "Continue reading"
        controls.order = { "continue", "recent", "favorites" }
        controls.show_buttons = { continue = true, recent = true, favorites = true }
        local recommendations = { next_series = {}, author = {}, other_series = {}, continue = { "reading" } }
        local strip, source = Data.stripConfig(recommendations, "continue", local_config)
        assert.are.equal("continue", source)
        assert.same({ kind = "continue" }, strip.default_source)
        assert.equals("Continue", require("common/nav_button_model").label(strip.controls,
            require("common/nav_button_model").find(strip.controls, "continue")))
        assert.equals("Continue", require("common/nav_button_model").find(nil, "continue").label)
        assert.is_nil(require("common/nav_button_model").find(nil, "continue").paths)
        controls.labels.continue = "My reading"
        recommendations.continue = {}
        strip, source = Data.stripConfig(recommendations, "continue", local_config)
        assert.are.equal("recent", source)
        assert.same({ kind = "recent" }, strip.default_source)
        assert.equals("My reading", strip.controls.labels.continue)
        assert.is_true(controls.show_buttons.continue)
    end)

    it("uses TBR when it is the first tab even without book recommendations", function()
        local home = require("modules/filebrowser/patches/home/home_presets").defaultHomePage()
        ZenSpec.replace("config/preset_store", { getSettings = function() return home end })
        local Data = require("modules/reader/end_book_data")
        local config = { modules = { strip = Data.stripConfig() } }
        config.modules.strip.controls.order = { "to_be_read", "continue", "author" }
        config.modules.strip.controls.show_buttons.to_be_read = true
        local strip, source = Data.stripConfig({ next_series = {}, author = {}, other_series = {} },
            nil, config)
        assert.are.equal("to_be_read", source)
        assert.same({ kind = "to_be_read" }, strip.default_source)
        assert.is_true(strip.controls.show_buttons.to_be_read)
        assert.is_nil(home.modules.strip.controls.show_buttons.to_be_read)
    end)

    it("opens on the first available tab in order and ignores a saved default source", function()
        local EndBook = load_end_book()
        require("device").hasKeys = function() return false end
        require("common/clock_timer").bind = function() end
        local Data = require("modules/reader/end_book_data")
        Data.new = function() return {} end
        local home = require("modules/filebrowser/patches/home/home_presets").defaultHomePage()
        ZenSpec.replace("config/preset_store", { getSettings = function() return home end })
        plugin.config.end_book = { strip_source = "other_series", modules = { strip = Data.stripConfig() } }
        local controls = plugin.config.end_book.modules.strip.controls
        controls.order = { "page_left", "next_series", "continue", "author", "other_series" }
        controls.show_buttons.page_left, controls.show_buttons.continue = true, true
        controls.show_buttons.other_series = true
        local recommendations = { next_series = {}, continue = { "reading" }, author = { "book" }, other_series = { "series" } }
        local function open_page()
            local page = setmetatable({ plugin = plugin, ui = { menu = {} }, rebuild = function(self)
                local strip
                strip, self.source = Data.stripConfig(recommendations, self.source, plugin.config.end_book)
                assert.is_table(strip)
            end }, { __index = EndBook })
            page:init()
            return page.source
        end
        assert.are.equal("continue", open_page())
        recommendations.continue = {}
        assert.are.equal("author", open_page())
        controls.show_buttons.author = false
        assert.are.equal("other_series", open_page())
        controls.order = { "other_series", "author" }
        controls.show_buttons.author = true
        assert.are.equal("other_series", open_page())
    end)

    it("enables Preview outside the reader without opening a book", function()
        ZenSpec.replace("apps/reader/readerui", {})
        local preview_args, closed
        ZenSpec.replace("modules/reader/end_book", { show = function(...) preview_args = { ... } end })
        local items = require("modules/settings/sections/end_book_settings").build{ plugin = plugin }
        local preview = items[4]
        assert.are.equal("Preview", preview.text)
        assert.is_nil(preview.enabled_func)
        preview.callback({ closeMenu = function() closed = true end })
        assert.is_true(closed)
        assert.is_nil(preview_args[1])
        assert.are.equal(plugin, preview_args[2])
        assert.is_true(preview_args[3])
    end)

    it("uses saved metadata for Preview without a reader document", function()
        ZenSpec.replace("modules/filebrowser/patches/home_page", {})
        local freed
        local book = { path = "/library/book.epub", title = "Book", authors = "Author", percent = 0.75,
            cover_bb = { copy = function() return "cover copy" end, free = function() freed = true end } }
        ZenSpec.replace("common/shared_state", { get = function() return {
            invalidateBookCache = function() end,
            newDataProvider = function() return { getContinuePaths = function() return {} end, getBook = function(_self, path)
                assert.are.equal(book.path, path)
                return book
            end } end,
        } end })
        ZenSpec.replace("common/db_bookinfo", { getGroupedByAuthor = function() return {} end,
            getGroupedBySeries = function() return {} end })
        ZenSpec.replace("common/book_status", { getEffectiveStatusFromFile = function() end })
        G_reader_settings:saveSetting("lastfile", book.path)
        local data = require("modules/reader/end_book_data").new(nil, plugin, {})
        assert.are.equal(book.path, data.file)
        assert.are.equal("Author", data.authors)
        assert.are.equal(0.75, data:getFeaturedBook().percent)
        assert.are.equal("cover copy", data:getFeaturedBook().cover_bb)
        assert.same({}, data.stats)
        assert.is_true(data:getCurrentQuote().is_empty)
        assert.same({ author = {}, next_series = {}, other_series = {} }, data:getRecommendations())
        data:free()
        assert.is_true(freed)
    end)

    it("excludes the current book opened through a symlink from recommendations", function()
        ZenSpec.replace("ffi/util", { realpath = function(path)
            return path == "alias" and "current" or path
        end })
        local Data = require("modules/reader/end_book_data")
        assert.same({ author = {}, next_series = {}, other_series = {} }, Data.recommendations("alias", {
            authors = "Author", series = "Series",
        }, { { author = "Author", files = { "current" } } }, {
            { series = "Series", items = { { file = "current" } } },
        }, function() return "complete" end))
    end)

    it("keeps the previous settings page open while arranging widgets", function()
        local arrange
        ZenSpec.replace("common/ui/zen_arrange_list", { show = function(opts) arrange = opts; return opts end })
        plugin.config.end_book = { rows = { order = { "featured" }, enabled = { featured = true } } }
        local Settings = require("modules/settings/sections/end_book_settings")
        local widgets = Settings.build({ plugin = plugin })[2]
        assert.is_true(widgets.keep_menu_open)
        assert.is_true(widgets._zen_settings_submenu)
        widgets.callback()
        assert.are.equal("End of book", arrange.title)
        assert.are.equal("featured", arrange.item_table[1].orig_item)
    end)

    it("enables edit mode by default and saves both toggle states", function()
        plugin.config.end_book = {}
        local edit = require("modules/settings/sections/end_book_settings").build({ plugin = plugin })[3]
        assert.is_true(require("config/defaults").end_book.edit_mode)
        assert.are.equal("Edit mode", edit.text)
        assert.is_true(edit.checked_func())
        edit.callback()
        assert.is_false(plugin.config.end_book.edit_mode)
        assert.is_false(edit.checked_func())
        edit.callback()
        assert.is_true(plugin.config.end_book.edit_mode)
        assert.is_true(edit.checked_func())
        assert.are.equal(2, plugin.saves)
    end)

    it("opens a widget's existing settings directly and saves its changes", function()
        local arrange
        ZenSpec.replace("common/ui/zen_arrange_list", { show = function(opts) arrange = opts end })
        plugin.config.end_book = require("common/utils").deepcopy(require("config/defaults").end_book)
        local Settings = require("modules/settings/sections/end_book_settings")
        assert.is_true(Settings.openWidgetSettings("stats_triplet", plugin))
        assert.are.equal("Reading statistics", arrange.title)
        assert.is_false(arrange.allow_arrange)
        assert.is_true(arrange.hide_footer_cancel)
        assert.are.equal(plugin, arrange.plugin)
        assert.are.equal(5, #arrange.item_table)
        arrange.item_table[1].sub_item_table[2].callback()
        assert.are.equal("book_duration", plugin.config.end_book.middle_stats_triplet[1])
        assert.are.equal(1, plugin.saves)
        local icons = arrange.item_table[4]
        local config = plugin.config.end_book.modules.stats_triplet
        assert.are.equal("Show icons", icons.text)
        assert.is_true(config.show_icons)
        config.show_icons = nil
        assert.is_true(icons.checked_func())
        icons.callback()
        assert.is_false(config.show_icons)
        assert.is_false(icons.checked_func())
        icons.callback()
        assert.is_true(config.show_icons)
        assert.is_true(icons.checked_func())
        assert.are.equal(3, plugin.saves)
    end)

    it("saves statistics label text, visibility, and the shared title font controls", function()
        local arrange, dialog, input, closed, keyboard, updates
        updates = 0
        ZenSpec.replace("common/ui/zen_arrange_list", { show = function(opts) arrange = opts end })
        ZenSpec.replace("ui/widget/inputdialog", { new = function(_self, opts)
            opts.getInputText = function() return input end
            opts.onShowKeyboard = function() keyboard = true end
            return opts
        end })
        ZenSpec.replace("ui/uimanager", {
            show = function(_self, opts) dialog = opts end,
            close = function(_self, opts) closed = opts end,
        })
        plugin.config.end_book = require("common/utils").deepcopy(require("config/defaults").end_book)
        require("modules/settings/sections/end_book_settings").openWidgetSettings("stats_triplet", plugin)
        local config = plugin.config.end_book.modules.stats_triplet
        local submenu = arrange.item_table[5]
        assert.equals("Label", submenu.text)
        local label_items = submenu.sub_item_table
        local show_label, label = submenu, label_items[1]
        assert.is_true(config.show_label)
        assert.is_true(show_label.checked_func())
        show_label.checkmark_callback()
        assert.is_false(config.show_label)
        show_label.checkmark_callback()
        assert.is_true(config.show_label)
        assert.equals("Label: Statistics", label.text_func())
        label.callback({ updateItems = function() updates = updates + 1 end })
        assert.equals("Statistics", dialog.input)
        assert.is_true(keyboard)
        input = "My reading"
        dialog.buttons[1][2].callback()
        assert.equals(dialog, closed)
        assert.equals("My reading", config.label)
        assert.equals("Label: My reading", label.text_func())
        label.callback()
        assert.equals("My reading", dialog.input)
        input = ""
        dialog.buttons[1][2].callback()
        assert.equals("", config.label)
        assert.equals("Label: Statistics", label.text_func())
        assert.equals(1, updates)
        assert.equals("Shared font controls", label_items[2].text)
        label_items[2].callback()
        assert.equals(5, plugin.saves)
    end)

    it("saves the navigation icon size alongside the shared featured settings", function()
        local arrange, spin
        _G.G_defaults = ZenSpec.memorySettings({ DGENERIC_ICON_SIZE = 32 })
        ZenSpec.replace("common/ui/zen_arrange_list", { show = function(opts) arrange = opts end })
        ZenSpec.replace("ui/widget/spinwidget", { new = function(_self, opts) return opts end })
        ZenSpec.replace("ui/uimanager", { show = function(_self, opts) spin = opts end })
        ZenSpec.replace("modules/reader/end_book_data", {
            featuredConfig = function() return require("common/utils").deepcopy(plugin.config.end_book.modules.featured) end,
            stripConfig = function() return {} end,
        })
        ZenSpec.replace("modules/settings/sections/library_settings/home_settings", { build = function(opts)
            return { { text = "Progress", callback = function()
                opts.widget_config.modules.featured.show_progress = false
                opts.save_widget_config()
            end } }
        end })
        plugin.config.end_book = {
            modules = { featured = { navigation_icon_size = 0, show_progress = true } },
            rows = { order = { "featured" }, enabled = { featured = true } },
        }
        require("modules/settings/sections/end_book_settings").showWidgets(plugin)
        local items = arrange.item_table[1].sub_item_table_func()
        assert.are.equal("Icon size: 40", items[1].text_func())
        items[1].callback()
        assert.are.equal(40, spin.value)
        assert.are.equal(40, spin.default_value)
        spin.callback({ value = 44 })
        assert.are.equal(44, plugin.config.end_book.modules.featured.navigation_icon_size)
        assert.are.equal("Icon size: 44", items[1].text_func())
        items[3].callback()
        assert.is_false(plugin.config.end_book.modules.featured.show_progress)
        assert.are.equal(44, plugin.config.end_book.modules.featured.navigation_icon_size)
        spin.callback({ value = 40 })
        assert.are.equal(0, plugin.config.end_book.modules.featured.navigation_icon_size)
        assert.is_false(plugin.config.end_book.modules.featured.show_progress)
        assert.are.equal(3, plugin.saves)
    end)

    it("selects and reorders featured buttons while enforcing the five-button limit", function()
        local arrange, message
        _G.G_defaults = ZenSpec.memorySettings({ DGENERIC_ICON_SIZE = 32 })
        ZenSpec.replace("common/ui/zen_arrange_list", { show = function(opts) arrange = opts end })
        ZenSpec.replace("ui/widget/infomessage", { new = function(_self, opts) return opts end })
        ZenSpec.replace("ui/uimanager", { show = function(_self, opts) message = opts.text end })
        local utils = require("common/utils")
        plugin.config.end_book = utils.deepcopy(require("config/defaults").end_book)
        local Data = require("modules/reader/end_book_data")
        Data.featuredConfig = function() return utils.deepcopy(plugin.config.end_book.modules.featured) end
        Data.stripConfig = function() return {} end
        ZenSpec.replace("modules/settings/sections/library_settings/home_settings", { build = function() return {} end })
        require("modules/settings/sections/end_book_settings").openWidgetSettings("featured", plugin)
        assert.is_true(arrange.item_table[2]._zen_settings_submenu)
        arrange.item_table[2].callback()
        assert.are.equal("Buttons", arrange.title)
        assert.are.equal(7, #arrange.item_table)
        assert.are.equal("Next file", arrange.item_table[6].text)
        assert.are.equal("Restart Book", arrange.item_table[7].text)
        assert.is_true(arrange.item_table[1].checked_func())
        assert.is_false(arrange.item_table[5].checked_func())
        arrange.item_table[5].callback()
        local featured = plugin.config.end_book.modules.featured
        assert.same({ "library", "series", "to_be_read", "home", "archive" }, featured.navigation_actions)
        arrange.item_table[6].callback()
        assert.are.equal("Maximum 5 buttons allowed", message)
        assert.is_false(arrange.item_table[6].checked_func())
        assert.are.equal(1, plugin.saves)
        arrange.item_table[2].callback()
        arrange.item_table[6].callback()
        table.insert(arrange.item_table, 1, table.remove(arrange.item_table, 6))
        arrange.callback()
        assert.same({ "next_file", "library", "to_be_read", "home", "archive" }, featured.navigation_actions)
        assert.are.equal(0, featured.navigation_icon_size)
        local current_icon, select_icon, updates = nil, nil, 0
        ZenSpec.replace("common/icon_packs", {
            getPickerDirectories = function(root) return { root .. "/icons" } end,
            getActivePackDirectory = function() end,
        })
        ZenSpec.replace("common/ui/zen_icon_picker", function(icon_list, current, callback)
            assert.is_true(#icon_list > 0)
            current_icon, select_icon = current, callback
        end)
        local saves = plugin.saves
        for _i, item in ipairs(arrange.item_table) do
            local icon_item = item.sub_item_table[1]
            icon_item.callback({ updateItems = function() updates = updates + 1 end })
            if item.orig_item == "restart" then assert.equals("restart", current_icon) end
            local icon = item.orig_item == "restart" and "home" or "atom"
            select_icon(icon)
            assert.equals("Icon: " .. icon, icon_item.text_func())
            assert.equals(icon, plugin.config.end_book.modules.featured.navigation_icons[item.orig_item])
        end
        assert.equals(saves + 7, plugin.saves)
        assert.equals(7, updates)
        for _i, item in ipairs(arrange.item_table) do
            if item.checked_func() then item.callback() end
        end
        assert.same({}, featured.navigation_actions)
        assert.equals("atom", featured.navigation_icons.library)
        assert.equals("home", featured.navigation_icons.restart)
    end)

    it("exposes and saves the shared strip settings without a default source option", function()
        local arrange
        ZenSpec.replace("common/ui/zen_arrange_list", { show = function(opts) arrange = opts end })
        plugin.config.end_book = require("common/utils").deepcopy(require("config/defaults").end_book)
        ZenSpec.replace("modules/reader/end_book_data", {
            featuredConfig = function() return {} end,
            stripConfig = function() return require("common/utils").deepcopy(plugin.config.end_book.modules.strip) end,
        })
        ZenSpec.replace("modules/settings/sections/library_settings/home_settings", { build = function(opts)
            return { { text = "Controls", callback = function()
                opts.widget_config.modules.strip.count = 3
                opts.save_widget_config()
            end } }
        end })
        local Settings = require("modules/settings/sections/end_book_settings")
        Settings.openWidgetSettings("strip", plugin)
        assert.are.equal(1, #arrange.item_table)
        assert.are.equal("Controls", arrange.item_table[1].text)
        arrange.item_table[1].callback()
        local config = plugin.config.end_book
        assert.is_nil(config.strip_source)
        assert.are.equal(3, config.modules.strip.count)
        assert.are.equal(1, plugin.saves)
    end)

    it("rejects enabling widgets beyond Home capacity, including a configured two-row strip", function()
        local home = require("modules/filebrowser/patches/home/home_presets").defaultHomePage()
        home.modules.strip.two_rows = true
        ZenSpec.replace("config/preset_store", { getSettings = function() return home end })
        ZenSpec.replace("modules/filebrowser/patches/home/components/registry", {
            get = function(id) return { id = id } end,
            sizeUnits = function(widget)
                return widget.id == "featured" and 3.5 or widget.id == "quotes" and 1.5 or 2
            end,
            capacityUnits = function() return 10 end,
            totalUnits = function(enabled, modules)
                assert.is_true(modules.strip.two_rows)
                return enabled.featured and 9.5 or 5
            end,
        })
        local arrange, message
        ZenSpec.replace("common/ui/zen_arrange_list", { show = function(opts) arrange = opts end })
        ZenSpec.replace("ui/widget/infomessage", { new = function(_self, opts) return opts end })
        ZenSpec.replace("ui/uimanager", { show = function(_self, opts) message = opts end })
        plugin.config.end_book = {
            modules = { strip = { two_rows = true } }, rows = { order = { "featured", "strip", "quotes" },
                enabled = { featured = true, strip = true, quotes = false } },
        }
        require("modules/settings/sections/end_book_settings").showWidgets(plugin)
        arrange.item_table[3].callback()
        assert.is_false(plugin.config.end_book.rows.enabled.quotes)
        assert.truthy(message.text:find("9.75/10", 1, true))
        assert.are.equal(0, plugin.saves)
        arrange.item_table[1].callback()
        arrange.item_table[3].callback()
        assert.is_true(plugin.config.end_book.rows.enabled.quotes)
        assert.are.equal(2, plugin.saves)
    end)
end)
