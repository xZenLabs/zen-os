describe("embedded page-browser lists", function()
    local Panels, saved_modules, saved_settings, saved_plugin
    local font_scopes, updates, closes, browser, focus_rebuilds
    local module_names = {
        "ui/widget/menu", "ui/widget/titlebar", "device", "common/reader_font",
        "modules/filebrowser/patches/library_font", "common/ui/zen_title_style",
        "modules/reader/zen_toc_widget", "modules/reader/page_browser_panels", "gettext",
        "modules/reader/annotation_viewer",
        "modules/reader/book_details", "modules/reader/book_info_widget",
        "modules/menu/app_launcher/book_switcher_page", "ui/uimanager",
        "ui/widget/container/centercontainer", "ui/geometry",
    }

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(module_names) do saved_modules[name] = package.loaded[name] or false end
        saved_settings, saved_plugin = G_reader_settings, rawget(_G, "__ZEN_UI_PLUGIN")
        _G.G_reader_settings = ZenSpec.memorySettings()
        _G.__ZEN_UI_PLUGIN = { config = { page_browser = { toc_font_size = 22, bookmarks_font_size = 24 } } }
        font_scopes, updates, closes, focus_rebuilds = 0, 0, 0, 0
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("device", { screen = { scaleBySize = function(_self, value) return value end } })
        ZenSpec.replace("common/reader_font", { getInfo = function() return { size = 18 } end })
        ZenSpec.replace("common/ui/zen_title_style", { getTitleFace = function() return "title face" end })
        ZenSpec.replace("modules/filebrowser/patches/library_font", {
            withMenuFaces = function(callback) font_scopes = font_scopes + 1; return callback() end,
        })
        ZenSpec.replace("ui/widget/titlebar", {
            new = function(_self, spec) spec.getHeight = function() return 50 end; return spec end,
        })
        ZenSpec.replace("ui/widget/menu", {
            new = function(_self, spec)
                spec.layout = { { "first row" } }
                spec.selected = { x = 1, y = 1 }
                spec.updateItems = function(_menu, number) updates = updates + number end
                return spec
            end,
        })
        ZenSpec.replace("modules/reader/zen_toc_widget", {
            getEntries = function()
                return {
                    { title = "First", page = 1, page_label = "i", depth = 1 },
                    { title = "Nested", page = 5, page_label = "v", depth = 2 },
                    { title = "Last", page = 10, page_label = "x", depth = 1 },
                }
            end,
            getCurrentPage = function(ui) return ui:getCurrentPage() end,
            getCurrentIndex = function(entries, page)
                local current
                for i, entry in ipairs(entries) do
                    if entry.page <= page then current = i end
                end
                return current
            end,
        })
        browser = {
            focus_page = 5,
            _zen_plugin = _G.__ZEN_UI_PLUGIN,
            _zenFocusedDocumentPage = function() return 5 end,
            _zenRebuildFocusLayout = function() focus_rebuilds = focus_rebuilds + 1 end,
            onClose = function() closes = closes + 1; return true end,
            ui = {
                getCurrentPage = function() return 5 end,
                annotation = {
                    annotations = {
                        { page = "xp1", text = "First marker", datetime = "2026-02", pos0 = "marker1" },
                        { page = "xp2", text = "Second marker", datetime = "2026-01", pos0 = "marker2" },
                    },
                },
                bookmark = {
                    getBookmarkType = function() return "bookmark" end,
                    getBookmarkItemText = function(_self, item) return "• " .. item.text_orig end,
                    getBookmarkPageNumber = function(_self, item) return item.page == "xp1" and 5 or 9 end,
                    getBookmarkPageString = function(_self, page) return page == "xp1" and "v" or "ix" end,
                },
            },
        }
        ZenSpec.unload("modules/reader/page_browser_panels")
        Panels = require("modules/reader/page_browser_panels")
    end)

    after_each(function()
        _G.G_reader_settings, _G.__ZEN_UI_PLUGIN = saved_settings, saved_plugin
        for _i, name in ipairs(module_names) do package.loaded[name] = saved_modules[name] or nil end
    end)

    it("keeps TOC navigation and paging inside the page-browser body", function()
        local selected_page, selected_item
        local menu = Panels.build(browser, "toc", 600, 700, function(page, item)
            selected_page, selected_item = page, item
        end)
        assert.are.equal("page_browser_toc", menu.name)
        assert.is_false(menu.is_popout)
        assert.is_true(menu.is_borderless)
        assert.are.equal(browser, menu.show_parent)
        assert.are.equal(700, menu.height)
        assert.are.equal("Table of contents", menu.custom_title_bar.title)
        assert.is_nil(menu.custom_title_bar.close_callback)
        assert.are.equal(22, menu.items_font_size)
        assert.are.equal(2, menu.item_table.current)
        assert.is_true(menu.item_table[2].bold)
        assert.are.equal("  Nested", menu.item_table[2].text)
        assert.are.equal("v", menu.item_table[2].mandatory)
        assert.is_true(menu:onMenuSelect(menu.item_table[2]))
        assert.are.equal(5, selected_page)
        assert.are.equal(menu.item_table[2], selected_item)
        assert.are.equal(0, closes)
        menu:updateItems(2)
        assert.are.equal(2, updates)
        assert.are.equal(2, font_scopes)
        assert.are.equal(1, focus_rebuilds)
        assert.are.same({ { "first row" } }, menu.layout)
    end)

    it("delegates all annotation kinds to the shared viewer", function()
        ZenSpec.replace("modules/reader/annotation_viewer", {
            build = function(parent, kind, width, height)
                return { parent = parent, kind = kind, width = width, height = height }
            end,
        })
        for _i, kind in ipairs({ "bookmarks", "highlights", "annotations" }) do
            local panel = Panels.build(browser, kind, 600, 700, function() end)
            assert.are.equal(browser, panel.parent)
            assert.are.equal(kind, panel.kind)
            assert.are.equal(600, panel.width)
            assert.are.equal(700, panel.height)
        end
    end)

    it("builds book details inside the body without its own title bar", function()
        ZenSpec.replace("modules/reader/book_details", {
            buildSpec = function(ui, opts)
                assert.are.equal(browser.ui, ui)
                assert.are.equal(browser._zen_plugin.config, opts.config)
                assert.are.equal(browser._zen_plugin, opts.plugin)
                return { description = "Book description" }
            end,
        })
        local frees = 0
        ZenSpec.replace("modules/reader/book_info_widget", {
            new = function(_self, spec)
                spec.free = function() frees = frees + 1 end
                return spec
            end,
        })
        local panel = Panels.build(browser, "book_details", 600, 700)
        assert.are.equal(600, panel.width)
        assert.are.equal(700, panel.height)
        assert.is_false(panel.show_title)
        assert.are.equal(browser, panel.show_parent)
        assert.are.equal("Book description", panel.description)
        assert.are.equal(panel, panel.layout[1][1])
        panel:onCloseWidget()
        assert.are.equal(1, frees)
        assert.are.equal(0, closes)
        assert.is_true(panel:onClose())
        assert.are.equal(1, closes)
    end)

    it("embeds the book switcher in the preview body and refreshes it in place", function()
        local options, paints, layouts
        local panel = { layout = { { "book cell" } } }
        ZenSpec.replace("modules/menu/app_launcher/book_switcher_page", {
            buildReader = function(opts) options = opts; return panel end,
        })
        ZenSpec.replace("ui/widget/container/centercontainer", { new = function(_self, spec) return spec end })
        ZenSpec.replace("ui/geometry", { new = function(_self, spec) return spec end })
        ZenSpec.replace("ui/uimanager", { setDirty = function(_self, widget, mode)
            assert.are.equal(browser, widget)
            assert.are.equal("ui", mode)
            paints = (paints or 0) + 1
        end })
        browser.updateLayout = function() layouts = (layouts or 0) + 1 end
        local container = Panels.build(browser, "book_switcher", 600, 700)
        assert.are.equal(panel, container[1])
        assert.are.equal(panel.layout, container.layout)
        assert.are.same({ w = 600, h = 700 }, container.dimen)
        assert.are.equal(browser.ui, options.ui)
        assert.are.equal(browser._zen_plugin, options.plugin)
        assert.are.equal(600, options.width)
        assert.are.equal(700, options.height)
        options.refresh()
        assert.are.equal(1, layouts)
        assert.are.equal(1, paints)
        assert.are.equal(0, closes)
        options.close()
        assert.are.equal(1, closes)
    end)

    it("routes Back to the browser", function()
        local menu = Panels.build(browser, "toc", 600, 700, function() end)
        assert.is_true(menu:onClose())
        assert.is_true(menu:onCloseAllMenus())
        assert.are.equal(2, closes)
    end)

    it("marks the reading position's chapter, not the browsed page, and keeps plugin config", function()
        _G.__ZEN_UI_PLUGIN = nil
        browser.focus_page = 10
        browser._zenFocusedDocumentPage = function() return 10 end
        browser.ui.getCurrentPage = function() return 12 end
        local menu = Panels.build(browser, "toc", 600, 700, function() end)
        assert.are.equal(3, menu.item_table.current)
        assert.is_true(menu.item_table[3].bold)
        assert.is_nil(menu.item_table[2].bold)
        assert.are.equal(22, menu.items_font_size)
    end)
end)
