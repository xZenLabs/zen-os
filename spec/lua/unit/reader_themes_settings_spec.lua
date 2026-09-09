describe("reader themes settings", function()
    local ReaderSettings
    local shown_dialog
    local dialog_input
    local reader_store
    local highlight_names_plugin

    before_each(function()
        shown_dialog = nil
        dialog_input = nil
        reader_store = { settings = { footer = { existing = true } } }
        highlight_names_plugin = nil
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/uimanager", {
            show = function(_, dialog) shown_dialog = dialog end,
            close = function() end,
        })
        ZenSpec.replace("ui/event", {})
        ZenSpec.replace("common/dispatch_action", {})
        ZenSpec.replace("modules/settings/zen_settings_utils", {
            make_enable_feature_item = function(feature, text, config, save_and_apply)
                return {
                    text = text,
                    checked_func = function() return config.features[feature] == true end,
                    callback = function()
                        config.features[feature] = config.features[feature] ~= true
                        save_and_apply(feature)
                    end,
                }
            end,
        })
        ZenSpec.replace("common/constants", { SEPARATOR_PRESETS = {} })
        ZenSpec.replace("config/preset_store", {
            loadStore = function() return reader_store end,
            saveStore = function(_, store)
                reader_store = store
                return true
            end,
        })
        ZenSpec.replace("common/inline_icon_map", {
            settings_status = "status",
            settings_background = "background",
            title = "title",
            search = "search",
        })
        ZenSpec.replace("common/ui/icon_menu_item", {
            decorate = function(item) return item end,
        })
        ZenSpec.replace("ui/widget/inputdialog", {
            new = function(_, spec)
                spec.getInputText = function() return dialog_input end
                spec.onShowKeyboard = function() end
                return spec
            end,
        })
        ZenSpec.replace("ui/widget/confirmbox", {
            new = function(_, spec) return spec end,
        })
        ZenSpec.replace("ui/widget/spinwidget", {
            new = function(_, spec) return spec end,
        })
        ZenSpec.replace("modules/reader/patches/highlight_names", function(plugin)
            highlight_names_plugin = plugin
        end)
        ZenSpec.unload("modules/settings/sections/reader_settings")
        ReaderSettings = require("modules/settings/sections/reader_settings")
    end)

    it("edits and resets highlight names from Highlight / Lookup", function()
        local saved, updates = 0, 0
        local config = {
            features = {
                reader_themes = false,
                reader_top_status_bar = false,
                dict_quick_lookup = true,
                highlight_lookup = true,
                reader_bottom_menu = false,
                page_browser = false,
                restore_library_view = false,
            },
            highlight_lookup = { color_names = {} },
            reader_themes = { dark_mode = "dark_warm_gray", light_mode = "default" },
        }
        local plugin = {
            saveConfig = function() saved = saved + 1 end,
        }
        local items = ReaderSettings.build({
            config = config,
            plugin = plugin,
            save_and_apply = function() end,
        })
        local lookup
        for _i, item in ipairs(items) do
            if item.text == "Highlight / Lookup" then lookup = item end
        end
        local names = lookup.sub_item_table[3].sub_item_table_func()
        local reset, red = names[1], names[2]
        local touchmenu = { updateItems = function() updates = updates + 1 end }

        assert.are.equal("Highlight names", lookup.sub_item_table[3].text)
        assert.is_false(reset.enabled_func())
        assert.are.equal("Red", red.text_func())

        dialog_input = "  Important  "
        red.callback(touchmenu)
        assert.are.equal("Red", shown_dialog.title)
        assert.are.equal("", shown_dialog.input)
        shown_dialog.buttons[1][2].callback()

        assert.are.equal("Important", config.highlight_lookup.color_names.red)
        assert.are.equal("Red: Important", red.text_func())
        assert.is_true(reset.enabled_func())
        assert.are.equal(plugin, highlight_names_plugin)
        assert.are.equal(1, saved)
        assert.are.equal(1, updates)

        reset.callback(touchmenu)
        assert.are.same({}, config.highlight_lookup.color_names)
        assert.are.equal("Red", red.text_func())
        assert.are.equal(2, saved)
        assert.are.equal(2, updates)
    end)

    it("creates a named custom copy only after a built-in theme changes", function()
        local saved, applied = 0, 0
        local config = {
            features = {
                reader_themes = true,
                reader_top_status_bar = false,
                dict_quick_lookup = false,
                highlight_lookup = false,
                reader_bottom_menu = false,
                page_browser = false,
                restore_library_view = false,
            },
            reader_themes = { dark_mode = "dark_warm_gray", light_mode = "default" },
        }
        local items = ReaderSettings.build({
            config = config,
            plugin = { saveConfig = function() saved = saved + 1 end },
            save_and_apply = function() end,
            apply_feature = function() applied = applied + 1 end,
        })
        local themes
        for _i, item in ipairs(items) do
            if item.text == "Reader themes" then themes = item end
        end
        local custom_items = themes.sub_item_table[3].sub_item_table_func()
        local dark_warm_gray = custom_items[2]

        dialog_input = "#1f1f1f"
        dark_warm_gray.sub_item_table[1].callback()
        shown_dialog.buttons[1][2].callback()
        assert.is_nil(config.reader_themes.custom.custom_1)

        dialog_input = "#101010"
        dark_warm_gray.sub_item_table[1].callback()
        shown_dialog.buttons[1][2].callback()
        local custom = config.reader_themes.custom.custom_1
        assert.are.equal("Custom Dark warm gray", custom.name)
        assert.are.equal("#101010", custom.background)
        assert.are.equal("#dcdccc", custom.text)
        assert.are.equal("dark_warm_gray", config.reader_themes.dark_mode)
        assert.are.equal(custom, reader_store.reader_themes.custom.custom_1)
        assert.is_nil(reader_store.settings.reader_themes)
        assert.is_true(reader_store.settings.footer.existing)
        assert.are.equal(1, saved)
        assert.are.equal(1, applied)
    end)

    it("shows default-on lookup toggles only for loaded companion plugins", function()
        ZenSpec.replace("apps/filemanager/filemanager", { instance = nil })
        ZenSpec.replace("apps/reader/readerui", {
            instance = { xray = {} },
        })
        ZenSpec.replace("pluginloader", { loaded_plugins = { koassistant = {} } })

        local saved = 0
        local items = ReaderSettings.build({
            config = {
                features = {
                    reader_themes = false,
                    reader_top_status_bar = false,
                    dict_quick_lookup = true,
                    highlight_lookup = true,
                    reader_bottom_menu = false,
                    page_browser = false,
                    restore_library_view = false,
                },
                highlight_lookup = {},
                reader_themes = { dark_mode = "dark_warm_gray", light_mode = "default" },
            },
            plugin = { saveConfig = function() saved = saved + 1 end },
            save_and_apply = function() end,
        })

        local lookup
        for _i, item in ipairs(items) do
            if item.text == "Highlight / Lookup" then lookup = item end
        end
        local by_text = {}
        for _i, item in ipairs(lookup.sub_item_table) do
            by_text[item.text] = item
        end

        assert.is_true(by_text["Show X-Ray"].show_func())
        assert.is_true(by_text["Show KOAssistant"].show_func())
        assert.is_false(by_text["Show AI assistant"].show_func())
        assert.is_true(by_text["Show X-Ray"].checked_func())

        by_text["Show X-Ray"].callback()
        assert.is_false(by_text["Show X-Ray"].checked_func())
        assert.are.equal(1, saved)
    end)

    it("offers chapter time formats as radio choices", function()
        local saved = 0
        local config = {
            features = {
                reader_themes = false,
                reader_top_status_bar = false,
                dict_quick_lookup = false,
                highlight_lookup = false,
                reader_bottom_menu = false,
                page_browser = false,
                restore_library_view = false,
            },
            reader_footer = { chapter_time_format = "full" },
            reader_themes = { dark_mode = "dark_warm_gray", light_mode = "default" },
        }
        local items = ReaderSettings.build({
            config = config,
            plugin = { saveConfig = function() saved = saved + 1 end },
            save_and_apply = function() end,
        })

        local chapter_time
        for _i, item in ipairs(items) do
            if item.text == "Time until chapter end" then chapter_time = item end
        end
        assert.are.equal(4, #chapter_time.sub_item_table)
        assert.are.same({ "5 min left in chapter", "5 min left", "5m", "hh:mm" }, {
            chapter_time.sub_item_table[1].text,
            chapter_time.sub_item_table[2].text,
            chapter_time.sub_item_table[3].text,
            chapter_time.sub_item_table[4].text,
        })
        assert.is_true(chapter_time.sub_item_table[1].radio)
        assert.is_true(chapter_time.sub_item_table[1].checked_func())

        chapter_time.sub_item_table[2].callback()
        assert.are.equal("compact", config.reader_footer.chapter_time_format)
        assert.is_true(chapter_time.sub_item_table[2].checked_func())
        assert.are.equal(1, saved)

        chapter_time.sub_item_table[4].callback()
        assert.are.equal("koreader", config.reader_footer.chapter_time_format)
        assert.is_true(chapter_time.sub_item_table[4].checked_func())
        assert.are.equal(2, saved)
    end)

    it("toggles expandable reader features from their parent rows", function()
        local bottom_visible = true
        local bottom_toggles = 0
        local dispatch = package.loaded["common/dispatch_action"]
        local plugin
        dispatch.isBottomStatusBarVisible = function(actual_plugin)
            assert.are.equal(plugin, actual_plugin)
            local ReaderUI = require("apps/reader/readerui")
            if ReaderUI.instance then return bottom_visible end
            return actual_plugin.config.reader_footer.status_bar_enabled ~= false
        end

        dispatch.setBottomStatusBar = function(actual_plugin, enabled)
            assert.are.equal(plugin, actual_plugin)
            bottom_visible = enabled
            bottom_toggles = bottom_toggles + 1
        end

        local footer = {
            settings = {},
            view = { footer_visible = true },
            addToMainMenu = function(_self, menu)
                menu.status_bar = { sub_item_table = {} }
            end,
        }
        ZenSpec.replace("apps/reader/readerui", {
            instance = { view = { footer = footer } },
        })

        local applied = {}
        local config = {
            features = {
                reader_themes = false,
                reader_top_status_bar = false,
                dict_quick_lookup = false,
                highlight_lookup = false,
                reader_bottom_menu = false,
                page_browser = false,
                restore_library_view = false,
            },
            reader_footer = {},
            reader_themes = { dark_mode = "dark_warm_gray", light_mode = "default" },
        }
        plugin = { config = config, saveConfig = function() end }
        local items = ReaderSettings.build({
            config = config,
            plugin = plugin,
            save_and_apply = function(feature) applied[#applied + 1] = feature end,
        })
        local by_text = {}
        for _i, item in ipairs(items) do by_text[item.text] = item end

        local top = by_text["Top status bar"]
        local themes = by_text["Reader themes"]
        local page_browser = by_text["Zen page browser"]
        local bottom = by_text["Bottom status bar"]

        assert.is_false(top.checked_func())
        assert.are.equal("Left items", top.sub_item_table[1].text)
        assert.is_false(themes.checked_func())
        assert.are.equal(3, #themes.sub_item_table)
        assert.is_false(page_browser.checked_func())
        assert.are.equal(2, #page_browser.sub_item_table)
        assert.is_nil(page_browser.enabled_func)
        assert.is_true(bottom.checked_func())
        assert.is_true(bottom.enabled_func())

        top.checkmark_callback()
        themes.checkmark_callback()
        page_browser.checkmark_callback()
        bottom.checkmark_callback()

        assert.is_true(config.features.reader_top_status_bar)
        assert.is_true(config.features.reader_themes)
        assert.is_true(config.features.page_browser)
        assert.is_false(bottom.checked_func())
        assert.are.equal(1, bottom_toggles)
        assert.are.same({
            "reader_top_status_bar",
            "reader_themes",
            "page_browser",
        }, applied)

        local bottom_items = bottom.sub_item_table_func()
        for _i, item in ipairs(bottom_items) do
            assert.are_not.equal("Enable bottom status bar", item.text)
        end

        package.loaded["apps/reader/readerui"].instance = nil
        config.reader_footer.status_bar_enabled = true
        assert.is_true(bottom.checked_func())
        assert.is_false(bottom.enabled_func())
        config.reader_footer.status_bar_enabled = false
        assert.is_false(bottom.checked_func())
    end)

    it("nests page-browser controls and persists separate overlay font sizes", function()
        local saved, updates = 0, 0
        local config = {
            features = {
                reader_themes = false,
                reader_top_status_bar = false,
                dict_quick_lookup = false,
                highlight_lookup = false,
                reader_bottom_menu = true,
                page_browser = true,
                restore_library_view = false,
            },
            page_browser = { toc_font_size = 20, bookmarks_font_size = 22 },
            reader_themes = { dark_mode = "dark_warm_gray", light_mode = "default" },
        }
        local items = ReaderSettings.build({
            config = config,
            plugin = { saveConfig = function() saved = saved + 1 end },
            save_and_apply = function() end,
        })

        local page_browser
        for _i, item in ipairs(items) do
            if item.text == "Zen page browser" then page_browser = item end
        end
        assert.are.equal(2, #page_browser.sub_item_table)
        assert.is_true(page_browser.checked_func())
        assert.are.equal("Table of contents — Font size: 20", page_browser.sub_item_table[1].text_func())
        assert.are.equal("Bookmarks — Font size: 22", page_browser.sub_item_table[2].text_func())

        local touchmenu = { updateItems = function() updates = updates + 1 end }
        page_browser.sub_item_table[1].callback(touchmenu)
        assert.are.equal("Table of contents — Font size", shown_dialog.title_text)
        shown_dialog.callback({ value = 26 })
        page_browser.sub_item_table[2].callback(touchmenu)
        assert.are.equal("Bookmarks — Font size", shown_dialog.title_text)
        shown_dialog.callback({ value = 24 })

        assert.are.equal(26, config.page_browser.toc_font_size)
        assert.are.equal(24, config.page_browser.bookmarks_font_size)
        assert.are.equal(2, saved)
        assert.are.equal(2, updates)
    end)

    it("creates a custom theme without using a built-in theme as its base", function()
        local saved, applied = 0, 0
        local config = {
            features = {
                reader_themes = true,
                reader_top_status_bar = false,
                dict_quick_lookup = false,
                highlight_lookup = false,
                reader_bottom_menu = false,
                page_browser = false,
                restore_library_view = false,
            },
            reader_themes = { dark_mode = "dark_warm_gray", light_mode = "default" },
        }
        local items = ReaderSettings.build({
            config = config,
            plugin = { saveConfig = function() saved = saved + 1 end },
            save_and_apply = function() end,
            apply_feature = function() applied = applied + 1 end,
        })
        local themes
        for _i, item in ipairs(items) do
            if item.text == "Reader themes" then themes = item end
        end
        local custom_items = themes.sub_item_table[3].sub_item_table_func()
        local new_theme = custom_items[1]

        assert.are.equal("New custom theme", new_theme.text)
        local opened_item, updates = nil, 0
        local touchmenu = {
            item_table_stack = {},
            updateItems = function() updates = updates + 1 end,
            onMenuSelect = function(self, item)
                opened_item = item
                table.insert(self.item_table_stack, self.item_table)
                self.item_table = item.sub_item_table
            end,
            backToUpperMenu = function(self)
                self.item_table = table.remove(self.item_table_stack)
                self:updateItems()
            end,
        }
        new_theme.callback(touchmenu)

        local custom = config.reader_themes.custom.custom_1
        assert.are.equal("Custom theme", custom.name)
        assert.are.equal("#ffffff", custom.background)
        assert.are.equal("#000000", custom.text)
        assert.are.equal("default", custom.font_face)
        assert.are.equal("dark_warm_gray", config.reader_themes.dark_mode)
        assert.are.equal("default", config.reader_themes.light_mode)
        assert.are.equal(custom, reader_store.reader_themes.custom.custom_1)
        assert.are.equal("Custom theme", opened_item.text_func())
        assert.are.equal("Theme name: Custom theme", touchmenu.item_table[1].text_func())
        assert.are.equal("Background color: #ffffff", touchmenu.item_table[2].text_func())
        assert.are.equal("Text color: #000000", touchmenu.item_table[3].text_func())
        assert.are.equal("New custom theme", touchmenu.item_table_stack[1][1].text)
        assert.are.equal(1, saved)
        assert.are.equal(1, applied)

        touchmenu.item_table[5].callback(touchmenu)
        shown_dialog.ok_callback()

        assert.is_nil(config.reader_themes.custom.custom_1)
        assert.are.equal(0, #touchmenu.item_table_stack)
        assert.are.equal(5, #touchmenu.item_table)
        assert.are.equal("New custom theme", touchmenu.item_table[1].text)
        assert.are.equal(1, updates)
        assert.are.equal(2, saved)
        assert.are.equal(2, applied)
    end)

    it("persists separate light and dark themes and immediately applies enabled themes", function()
        local saved, applied = 0, {}
        local config = {
            features = {
                reader_themes = false,
                reader_top_status_bar = false,
                dict_quick_lookup = false,
                highlight_lookup = false,
                reader_bottom_menu = false,
                page_browser = false,
                restore_library_view = false,
            },
            reader_themes = { dark_mode = "dark_warm_gray", light_mode = "default" },
        }
        local items = ReaderSettings.build({
            config = config,
            plugin = { saveConfig = function() saved = saved + 1 end },
            save_and_apply = function(feature) applied[#applied + 1] = feature end,
            apply_feature = function(feature) applied[#applied + 1] = feature end,
        })
        local themes
        for _i, item in ipairs(items) do
            if item.text == "Reader themes" then themes = item end
        end

        assert.is_table(themes)
        themes.checkmark_callback()
        assert.is_true(config.features.reader_themes)
        assert.is_true(themes.checked_func())
        assert.are.equal("reader_themes", applied[1])

        local dark_themes = themes.sub_item_table[1].sub_item_table_func()
        dark_themes[4].callback()
        assert.are.equal("light_sepia", config.reader_themes.dark_mode)
        local light_themes = themes.sub_item_table[2].sub_item_table_func()
        light_themes[1].callback()
        assert.are.equal("default", config.reader_themes.light_mode)

        config.reader_themes.custom = {
            custom_1 = {
                name = "Paper",
                text = "#30251b",
                background = "#f5e7ce",
                font_face = "default",
            },
        }
        dark_themes = themes.sub_item_table[1].sub_item_table_func()
        dark_themes[#dark_themes].callback()
        assert.are.equal("custom_1", config.reader_themes.dark_mode)
        assert.are.equal(3, saved)
        assert.are.equal("reader_themes", applied[4])
    end)

    it("offers shared granular items, custom text, and chapter marks for the reader top bar", function()
        local applies = 0
        local config = {
            features = {
                reader_themes = false,
                reader_top_status_bar = true,
                dict_quick_lookup = false,
                highlight_lookup = false,
                reader_bottom_menu = false,
                page_browser = false,
                restore_library_view = false,
            },
            reader_top_status_bar = {
                left_order = {}, center_order = { "time" }, right_order = {},
            },
            reader_footer = {},
            reader_themes = { dark_mode = "dark_warm_gray", light_mode = "default" },
        }
        local built = ReaderSettings.build({
            config = config,
            plugin = { config = config, saveConfig = function() end },
            save_and_apply = function(feature)
                assert.are.equal("reader_top_status_bar", feature)
                applies = applies + 1
            end,
        })
        local top
        for _i, item in ipairs(built) do
            if item.text == "Top status bar" then top = item end
        end

        local center_items = top.sub_item_table[2].sub_item_table
        local item_labels = {}
        for _i, item in ipairs(center_items) do item_labels[item.text] = item end
        assert.is_not_nil(item_labels["Battery icon"])
        assert.is_not_nil(item_labels["Battery percentage"])
        assert.is_not_nil(item_labels["Current page"])
        assert.is_not_nil(item_labels["Total pages"])
        assert.is_function(item_labels["Custom text"].checkmark_callback)
        assert.is_function(item_labels["Custom text"].sub_item_table[1].text_func)
        local wifi = item_labels["Wi-Fi"]
        local hide_wifi = wifi.sub_item_table[1]
        assert.is_function(wifi.checkmark_callback)
        assert.are.equal("Hide when off", hide_wifi.text)
        assert.is_false(hide_wifi.checked_func())
        hide_wifi.callback()
        assert.is_true(config.reader_top_status_bar.wifi_hide_when_off)

        local top_items = {}
        for _i, item in ipairs(top.sub_item_table) do
            if item.text then top_items[item.text] = item end
        end
        assert.is_nil(top_items["Items"])
        assert.is_nil(top_items["Display"])
        assert.is_nil(top_items["Settings"])
        assert.is_nil(top_items["Auto refresh"])

        local chapter_marks = top_items["Chapter marks"]
        chapter_marks.callback()
        assert.is_true(config.reader_top_status_bar.show_chapter_marks)
        assert.is_true(config.reader_top_status_bar.show_bottom_border)
        assert.is_true(config.reader_top_status_bar.bottom_border_progress)

        local colored = top_items["Colored status icons"]
        assert.is_false(colored.checked_func())
        colored.callback()
        assert.is_true(colored.checked_func())
        assert.are.equal(3, applies)
    end)
end)
