describe("reader navbar dispatch", function()
    local Dispatch
    local reader
    local calls

    before_each(function()
        calls = {}
        reader = { document = { file = "/library/Book.epub" } }
        ZenSpec.replace("apps/reader/readerui", { instance = reader })
        ZenSpec.replace("common/library_navigation", {
            showFromReader = function(received_reader, plugin, opts)
                calls[#calls + 1] = {
                    reader = received_reader,
                    plugin = plugin,
                    opts = opts,
                }
                return true
            end,
        })
        ZenSpec.unload("common/dispatch_action")
        Dispatch = require("common/dispatch_action")
    end)

    it("returns from the reader to the requested navbar group tab", function()
        local plugin = { marker = "zen" }

        assert.is_true(Dispatch.onShowZenUIAuthors(plugin))
        assert.are.equal(reader, calls[1].reader)
        assert.are.equal(plugin, calls[1].plugin)
        assert.are.equal("authors", calls[1].opts.target_tab)
        assert.is_nil(calls[1].opts.open_home)

        assert.is_true(Dispatch.onShowZenUISeries(plugin))
        assert.are.equal("series", calls[2].opts.target_tab)

        assert.is_true(Dispatch.onShowZenUITags(plugin))
        assert.are.equal("tags", calls[3].opts.target_tab)

        assert.is_true(Dispatch.onShowZenUIStats(plugin))
        assert.are.equal("stats", calls[4].opts.target_tab)
    end)

    it("routes the reader Home action without replacing it with a tab target", function()
        local plugin = { marker = "zen" }

        assert.is_true(Dispatch.onShowZenUIHome(plugin))
        assert.are.equal(reader, calls[1].reader)
        assert.are.equal(plugin, calls[1].plugin)
        assert.is_true(calls[1].opts.open_home)
        assert.is_nil(calls[1].opts.target_tab)
    end)

    it("routes a specific tag from the reader", function()
        local plugin = { marker = "zen" }

        assert.is_true(Dispatch.onShowZenUITag(plugin, "Science"))

        assert.are.equal(reader, calls[1].reader)
        assert.are.equal(plugin, calls[1].plugin)
        assert.are.equal("Science", calls[1].opts.target_tag)
    end)

    it("registers Stats as a general dispatcher action", function()
        local actions = {}
        ZenSpec.replace("dispatcher", {
            registerAction = function(_self, name, spec) actions[name] = spec end,
            _addItem = function() end,
        })
        ZenSpec.replace("util", {})
        ZenSpec.replace("ui/uimanager", {})

        Dispatch.onDispatcherRegisterActions()

        local action = actions.zen_ui_show_stats
        assert.are.equal("ShowZenUIStats", action.event)
        assert.are.equal("ZenOS: Stats", action.title)
        assert.is_true(action.general)
        local battery_action = actions.zen_ui_show_battery_stats
        assert.are.equal("ShowZenUIBatteryStats", battery_action.event)
        assert.are.equal("ZenOS: Battery Stats", battery_action.title)
        assert.is_true(battery_action.general)
    end)

    it("opens battery stats through the dispatcher handler", function()
        local plugin = { marker = "zen" }
        local opened_plugin
        local original = package.loaded["modules/settings/battery_stats_menu"]
        ZenSpec.replace("modules/settings/battery_stats_menu", {
            open = function(value)
                opened_plugin = value
                return true
            end,
        })
        assert.is_true(Dispatch.onShowZenUIBatteryStats(plugin))
        assert.are.equal(plugin, opened_plugin)
        package.loaded["modules/settings/battery_stats_menu"] = original
    end)

    it("registers a global annotation viewer and reader destinations", function()
        local actions = {}
        ZenSpec.replace("dispatcher", {
            registerAction = function(_self, name, spec) actions[name] = spec end,
            _addItem = function() end,
        })
        Dispatch.onDispatcherRegisterActions()
        assert.is_true(actions.zen_ui_show_annotation_viewer.general)
        assert.are.equal("ShowZenUIAnnotationViewer", actions.zen_ui_show_annotation_viewer.event)
        local plugin = {}
        Dispatch.install(plugin)
        for _i, entry in ipairs({ { "page_browser", "PageBrowser" },
                { "annotations", "Annotations" }, { "bookmarks", "Bookmarks" },
                { "highlights", "Highlights" }, { "pinned_pages", "PinnedPages" },
                { "book_switcher", "BookSwitcher" } }) do
            local action = actions["zen_ui_show_" .. entry[1]]
            assert.is_true(action.reader)
            assert.is_nil(action.general)
            assert.are.equal("ShowZenUI" .. entry[2], action.event)
            assert.is_function(plugin["on" .. action.event])
        end
        assert.is_function(plugin.onShowZenUIAnnotationViewer)
        assert.are.equal("ZenOS: Book switcher", actions.zen_ui_show_book_switcher.title)
    end)

    it("opens the requested book tab or pinned preview and ignores reader actions in the library", function()
        local tabs, pinned = {}, nil
        reader.thumbnail = { onShowPageBrowser = function(_self, kind) tabs[#tabs + 1] = kind or false; return true end }
        local original = package.loaded["modules/reader/references"]
        ZenSpec.replace("modules/reader/references", { openPinned = function(ui) pinned = ui; return true end })
        finally(function() package.loaded["modules/reader/references"] = original end)
        assert.is_true(Dispatch.onShowZenUIPageBrowser())
        assert.is_true(Dispatch.onShowZenUIAnnotations())
        assert.is_true(Dispatch.onShowZenUIBookmarks())
        assert.is_true(Dispatch.onShowZenUIHighlights())
        assert.is_true(Dispatch.onShowZenUIBookSwitcher())
        assert.are.same({ false, "annotations", "bookmarks", "highlights", "book_switcher" }, tabs)
        assert.is_true(Dispatch.onShowZenUIPinnedPages())
        assert.are.equal(reader, pinned)
        require("apps/reader/readerui").instance = nil
        assert.is_false(Dispatch.onShowZenUIAnnotations())
        assert.is_false(Dispatch.onShowZenUIBookSwitcher())
        assert.is_false(Dispatch.onShowZenUIPinnedPages())
    end)

    it("opens current-book annotations in the reader and all books in the library", function()
        local opened
        local original = package.loaded["modules/reader/annotation_viewer"]
        ZenSpec.replace("modules/reader/annotation_viewer", { show = function(plugin, ui) opened = { plugin, ui } end })
        finally(function() package.loaded["modules/reader/annotation_viewer"] = original end)
        local plugin = { config = {} }
        assert.is_true(Dispatch.onShowZenUIAnnotationViewer(plugin))
        assert.are.equal(plugin, opened[1])
        assert.are.equal(reader, opened[2])
        require("apps/reader/readerui").instance = nil
        assert.is_true(Dispatch.onShowZenUIAnnotationViewer(plugin))
        assert.is_nil(opened[2])
    end)
end)
