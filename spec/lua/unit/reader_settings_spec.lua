describe("reader settings", function()
    local ReaderSettings
    local shown_dialog
    local dialog_input
    local reader_store
    local highlight_names_plugin

    local function find_item(items, text)
        for _i, item in ipairs(items) do
            if item.text == text then return item end
            local found = item.sub_item_table and find_item(item.sub_item_table, text)
            if found then return found end
        end
    end

    before_each(function()
        shown_dialog = nil
        dialog_input = nil
        reader_store = { settings = { footer = { existing = true } } }
        highlight_names_plugin = nil
        _G.G_reader_settings = ZenSpec.memorySettings()
        _G.G_reader_settings.has = function(self, key) return self.data[key] ~= nil end
        _G.G_reader_settings.nilOrTrue = function(self, key)
            return self.data[key] == nil or self.data[key] == true
        end
        ZenSpec.replace("gettext", setmetatable({
            pgettext = function(_context, text) return text end,
        }, { __call = function(_, text) return text end }))
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
                scaleBySize = function(_self, size) return size end,
                getDPI = function() return 160 end,
            },
            isKindle = function() return false end,
            hasSystemFonts = function() return false end,
            isTouchDevice = function() return true end
        })
        ZenSpec.replace("document/canvascontext", {
            isKindle = function() return false end,
            hasSystemFonts = function() return false end,
        })
        ZenSpec.replace("modules/menu/bluetooth/bluetooth", { isAvailable = function() return false end })
        ZenSpec.replace("ui/uimanager", {
            show = function(_, dialog) shown_dialog = dialog end,
            close = function() end,
            setDirty = function() end,
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
        ZenSpec.replace("common/plugin_root", ZenSpec.root)
        ZenSpec.replace("common/utils", {
            resolveLocalIcon = function(dir, name) return dir .. name .. ".svg" end,
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
        ZenSpec.replace("common/ui/color_wheel_widget", {
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

    it("groups appearance settings under the reader root", function()
        local config = { features = {}, reader_themes = {} }
        local items = ReaderSettings.build({ config = config, plugin = {}, save_and_apply = function() end })
        local labels = {}
        for _i, item in ipairs(items) do labels[#labels + 1] = item.text end
        assert.are.same({ "Appearance", "Highlight / Lookup", "Bottom swipe gesture", "Page Browser",
            "Footnotes and pinned pages", "Annotation viewer", "Restore library location on exit", "Reader controls",
            "End of book" }, labels)
        labels = {}
        for _i, item in ipairs(items[1].sub_item_table) do labels[#labels + 1] = item.text end
        assert.are.same({ "Top status bar", "Bottom status bar", "Align status bars with book margins",
            "Reader themes", "Flash on every CBZ page turn" }, labels)
        assert.is_nil(find_item(items, "Font"))
        local controls = items[#items - 1]
        assert.is_nil(find_item(controls.sub_item_table, "Enable"))
        assert.is_nil(controls.checked_func)
    end)

    it("shows popup settings directly in footnote options", function()
        local native_items
        local reader_ui = { instance = { rolling = {}, link = {
            getFootnoteSettingsMenuTable = function() return native_items end,
        } } }
        ZenSpec.replace("apps/reader/readerui", reader_ui)
        local items = ReaderSettings.build({ config = { features = {} }, plugin = {}, save_and_apply = function() end })
        local options = find_item(items, "Footnote options")
        local show_popup = { text = "Show footnotes in popup" }
        local popup_items = {
            { text = "Show more links as footnotes" },
            { text = "Use book font in popups", enabled_func = function() return false end },
            { text = "Footnote popup font size", callback = function() end, keep_menu_open = true },
            { text = "Justify text in popups" },
        }
        local expected = { show_popup, unpack(popup_items) }
        assert.is_true(options.enabled_func())
        for _i, menu in ipairs({
            { show_popup, { text = "Footnote popup settings", sub_item_table = popup_items } },
            expected,
        }) do
            native_items = menu
            local flattened = options.sub_item_table_func()
            assert.are.equal(#expected, #flattened)
            for index, item in ipairs(expected) do assert.are.equal(item, flattened[index]) end
        end
        reader_ui.instance.rolling = nil
        assert.is_false(options.enabled_func())
        reader_ui.instance = nil
        assert.is_true(options.enabled_func())
    end)

    it("edits pinned page defaults without an open book", function()
        local saved_settings, saved_defaults = G_reader_settings, G_defaults
        local pin_settings = package.loaded["modules/reader/pin_settings"]
        finally(function()
            _G.G_reader_settings, _G.G_defaults = saved_settings, saved_defaults
            package.loaded["modules/reader/pin_settings"] = pin_settings
        end)
        _G.G_reader_settings = ZenSpec.memorySettings{ copt_font_size = 24 }
        _G.G_defaults = ZenSpec.memorySettings{ DCREREADER_CONFIG_DEFAULT_FONT_SIZE = 22 }
        ZenSpec.replace("apps/reader/readerui", {})
        ZenSpec.unload("modules/reader/pin_settings")
        local config = { features = {}, reader_pins = {
            use_book_font = true, relative_font_size = 0, justify = true, side = "right",
        } }
        local saves = 0
        local items = ReaderSettings.build{ config = config, plugin = {
            config = config, saveConfig = function() saves = saves + 1 end,
        }, save_and_apply = function() end }
        local options = find_item(items, "Pinned page options")
        assert.is_nil(options.enabled_func)
        local pins = options.sub_item_table_func()
        for index = 1, 3 do assert.is_true(pins[index].enabled) end
        pins[1].callback()
        pins[3].callback()
        pins[4].sub_item_table[1].callback()
        assert.is_false(config.reader_pins.use_book_font)
        assert.is_false(config.reader_pins.justify)
        assert.are.equal("left", config.reader_pins.side)
        assert.is_falsy(pins[5].checked_func())
        pins[5].callback()
        assert.is_true(config.reader_pins.minimap)
        pins[2].callback()
        assert.are.equal(0, shown_dialog.value)
        shown_dialog.extra_callback()
        assert.are.equal(24, shown_dialog.value)
        shown_dialog.callback{ value = 30 }
        assert.are.equal(30, config.reader_pins.font_size)
        shown_dialog.extra_callback()
        shown_dialog.callback{ value = 2 }
        assert.is_nil(config.reader_pins.font_size)
        assert.are.equal(2, config.reader_pins.relative_font_size)
        assert.are.equal(6, saves)
        G_reader_settings:delSetting("copt_font_size")
        pins = options.sub_item_table_func()
        pins[2].callback()
        shown_dialog.extra_callback()
        assert.are.equal(22, shown_dialog.value)
    end)

    it("reuses the native footnote menu with font defaults when no book is open", function()
        local saved_settings = G_reader_settings
        local reader_link = package.loaded["apps/reader/modules/readerlink"]
        finally(function()
            _G.G_reader_settings = saved_settings
            package.loaded["apps/reader/modules/readerlink"] = reader_link
        end)
        _G.G_reader_settings = ZenSpec.memorySettings{ copt_font_size = 26 }
        ZenSpec.replace("apps/reader/readerui", {})
        local native_item = { text = "Show footnotes in popup", callback = function()
            G_reader_settings:saveSetting("footnote_link_in_popup", true)
        end }
        ZenSpec.replace("apps/reader/modules/readerlink", {
            getFootnoteSettingsMenuTable = function(link)
                assert.are.equal(26, link.document.configurable.font_size)
                return { native_item }
            end,
        })
        local items = ReaderSettings.build{ config = { features = {} }, plugin = {}, save_and_apply = function() end }
        local options = find_item(items, "Footnote options")
        assert.is_true(options.enabled_func())
        local footnotes = options.sub_item_table_func()
        assert.are.same({ native_item }, footnotes)
        footnotes[1].callback()
        assert.is_true(G_reader_settings:readSetting("footnote_link_in_popup"))
    end)

    it("selects mutually exclusive bottom swipe actions and reuses the launcher editor", function()
        local saved, editor_ctx = 0, nil
        local custom_items = { { text = "Action" } }
        ZenSpec.replace("modules/settings/sections/app_launcher_settings", {
            build = function(ctx)
                editor_ctx = ctx
                return { sub_item_table = custom_items }
            end,
        })
        local config = { features = { page_browser = true }, reader_themes = {} }
        local items = ReaderSettings.build({
            config = config, plugin = { saveConfig = function() saved = saved + 1 end },
            save_and_apply = function(feature)
                assert.are.equal("reader_controls", feature)
                saved = saved + 1
            end,
        })
        local choices = find_item(items, "Bottom swipe gesture").sub_item_table
        assert.is_true(choices[3].checked_func())
        assert.are.equal(5, #choices)
        for _i, choice in ipairs(choices) do
            assert.is_true(choice.radio)
            if choice.sub_item_table_func then
                assert.are.equal(custom_items, choice.sub_item_table_func())
                assert.is_true(choices[4].checked_func())
                assert.is_false(choice.checked_func())
            else
                choice.callback()
                for _j, other in ipairs(choices) do assert.are.equal(choice == other, other.checked_func()) end
            end
        end
        assert.are.equal("Bottom swipe gesture", choices[5].sub_title)
        assert.is_nil(choices[5].checkmark_callback)
        assert.are.equal(config.reader_bottom_swipe, editor_ctx.button_config)
        assert.are.equal("reader", editor_ctx.button_scope)
        assert.is_true(editor_ctx.button_single)
        assert.is_false(config.features.page_browser)
        assert.is_false(config.features.reader_bottom_menu)
        assert.are.equal(4, saved)
        editor_ctx.save_buttons()
        assert.are.equal(5, saved)
        assert.is_true(choices[4].checked_func())
        config.reader_bottom_swipe.entries = { { type = "action", action = {} } }
        editor_ctx.save_buttons()
        assert.is_true(choices[4].checked_func())
        config.reader_bottom_swipe.entries[1].action.show_menu = true
        editor_ctx.save_buttons()
        assert.is_true(choices[5].checked_func())
        assert.is_true(config.features.reader_bottom_menu)
        choices[3].callback()
        choices[5].sub_item_table_func()
        assert.is_true(choices[3].checked_func())
        editor_ctx.save_buttons()
        assert.is_true(choices[5].checked_func())
        assert.is_false(config.features.page_browser)
        config.reader_bottom_swipe.entries = {}
        editor_ctx.save_buttons()
        assert.is_true(choices[4].checked_func())
        assert.is_false(config.features.reader_bottom_menu)
        assert.is_false(config.features.page_browser)
    end)

    it("saves the CBZ page-turn flash toggle without requiring an open reader", function()
        local saved = 0
        local config = { features = {}, reader_themes = {} }
        local items = ReaderSettings.build({
            config = config,
            plugin = { saveConfig = function() saved = saved + 1 end },
            save_and_apply = function() error("no patch reapplication needed") end,
        })
        local toggle = find_item(items, "Flash on every CBZ page turn")
        assert.is_table(toggle)
        assert.is_false(toggle.checked_func())
        toggle.callback()
        assert.is_true(config.features.reader_flash_cbz)
        assert.is_true(toggle.checked_func())
        toggle.callback()
        assert.is_false(config.features.reader_flash_cbz)
        assert.is_false(toggle.checked_func())
        assert.are.equal(2, saved)
    end)

    it("places end-of-book settings last and keeps the margin toggle refreshing both bars", function()
        local saved, refreshed, dirty = 0, 0, 0
        local config = { features = { reader_status_bar_margins = true }, reader_themes = {} }
        local reader = { view = { footer = {
            refreshFooter = function(_self, refresh, signal)
                assert.is_true(refresh)
                assert.is_true(signal)
                refreshed = refreshed + 1
            end,
        } } }
        local ReaderUI = { instance = reader }
        ZenSpec.replace("apps/reader/readerui", ReaderUI)
        package.loaded["ui/uimanager"].setDirty = function(_self, widget, mode)
            assert.are.equal(reader, widget)
            assert.are.equal("ui", mode)
            dirty = dirty + 1
        end
        local items = ReaderSettings.build({
            config = config,
            plugin = { saveConfig = function() saved = saved + 1 end },
            save_and_apply = function() end,
        })
        assert.are.equal("End of book", items[#items].text)
        local toggle = find_item(items, "Align status bars with book margins")
        assert.are.equal("Align status bars with book margins", toggle.text)
        assert.is_true(toggle.checked_func())
        toggle.callback()
        assert.is_false(config.features.reader_status_bar_margins)
        assert.is_false(toggle.checked_func())
        toggle.callback()
        assert.is_true(config.features.reader_status_bar_margins)
        assert.is_true(toggle.checked_func())
        assert.are.equal(2, saved)
        assert.are.equal(2, refreshed)
        assert.are.equal(2, dirty)

        ReaderUI.instance = nil
        toggle.callback()
        assert.is_false(config.features.reader_status_bar_margins)
        assert.are.equal(3, saved)
        assert.are.equal(2, refreshed)
    end)

    it("edits and resets highlight names and colors from Highlight / Lookup", function()
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
            highlight_lookup = { color_names = {}, color_codes = {} },
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
        local highlights = lookup.sub_item_table[3].sub_item_table_func()
        assert.is_true(highlights[1]._zen_settings_submenu)
        assert.are.equal(4, #highlights)
        assert.are.equal("Menu items", highlights[1].text)
        assert.are.equal("Show labels", highlights[2].text)
        assert.is_false(highlights[2].checked_func())
        local invert = highlights[3]
        assert.are.equal("Invert colors in night mode", invert.text)
        local invert_key = "highlight_selection_invert_highlight_color"
        local prev_invert = G_reader_settings:readSetting(invert_key)
        G_reader_settings:delSetting(invert_key)
        assert.is_false(invert.checked_func())
        invert.callback()
        assert.is_true(G_reader_settings:isTrue(invert_key))
        assert.is_true(invert.checked_func())
        invert.callback()
        assert.is_false(G_reader_settings:isTrue(invert_key))
        G_reader_settings:saveSetting(invert_key, prev_invert)
        saved = 0
        assert.are.equal("Colors", highlights[4].text)
        local colors = highlights[4].sub_item_table
        assert.are.equal(10, #colors)
        local reset, red = colors[#colors], colors[1]
        assert.are.equal("Reset colors and names", reset.text)
        local name, color = red.sub_item_table[1], red.sub_item_table[2]
        local touchmenu = { updateItems = function() updates = updates + 1 end }

        assert.are.equal("Highlight", lookup.sub_item_table[3].text)
        assert.is_false(reset.enabled_func())
        assert.are.equal("Red", red.text_func())
        assert.are.equal("Name: Red", name.text_func())
        assert.are.equal("Color: #ff3300", color.text_func())

        dialog_input = "  Important  "
        name.callback(touchmenu)
        assert.are.equal("Red", shown_dialog.title)
        assert.are.equal("", shown_dialog.input)
        shown_dialog.buttons[1][2].callback()

        assert.are.equal("Important", config.highlight_lookup.color_names.red)
        assert.are.equal("Important", red.text_func())
        assert.are.equal("Name: Important", name.text_func())
        assert.is_true(reset.enabled_func())
        assert.are.equal(plugin, highlight_names_plugin)
        assert.are.equal(1, saved)
        assert.are.equal(1, updates)

        color.callback(touchmenu)
        assert.are.equal("Highlight color: Important", shown_dialog.title_text)
        assert.are.equal("#ff3300", shown_dialog.hex)
        shown_dialog.callback("#123456")
        assert.are.equal("#123456", config.highlight_lookup.color_codes.red)
        assert.are.equal("Color: #123456", color.text_func())
        assert.are.equal(2, saved)
        assert.are.equal(2, updates)

        color.callback(touchmenu)
        assert.are.equal("#123456", shown_dialog.hex)
        shown_dialog.callback("#abcdef")
        assert.are.equal("#abcdef", config.highlight_lookup.color_codes.red)
        assert.are.equal(3, saved)
        assert.are.equal(3, updates)

        reset.callback(touchmenu)
        assert.are.same({}, config.highlight_lookup.color_names)
        assert.are.same({}, config.highlight_lookup.color_codes)
        assert.are.equal("Red", red.text_func())
        assert.are.equal("Color: #ff3300", color.text_func())
        assert.are.equal(4, saved)
        assert.are.equal(4, updates)

        local lookup_labels = lookup.sub_item_table[4].sub_item_table[1]
        assert.is_false(lookup_labels.checked_func())
        highlights[2].callback()
        assert.is_true(config.highlight_lookup.show_labels)
        assert.is_false(lookup_labels.checked_func())
        lookup_labels.callback()
        assert.is_true(config.dict_quick_lookup.show_labels)
        highlights[2].callback()
        assert.is_false(config.highlight_lookup.show_labels)
    end)

    describe("default highlight color", function()
        local original_settings
        local ReaderUI
        local screen

        local function default_choices()
            local items = ReaderSettings.build({
                config = { features = {}, reader_themes = {} },
                plugin = {}, save_and_apply = function() end,
            })
            local choices = {}
            local highlights = find_item(items, "Highlight").sub_item_table_func()
            for _i, color in ipairs(find_item(highlights, "Colors").sub_item_table) do
                if color.sub_item_table then
                    choices[color.text_func()] = find_item(color.sub_item_table, "Set as default")
                end
            end
            return choices
        end

        local function assert_default(choices, name)
            for label, choice in pairs(choices) do
                assert.is_true(choice.radio)
                assert.are.equal(label == name, choice.checked_func())
            end
        end

        before_each(function()
            original_settings = G_reader_settings
            _G.G_reader_settings = ZenSpec.memorySettings()
            ReaderUI = { instance = nil }
            -- reader_settings captured device.screen at load; mutate it in place
            screen = package.loaded["device"].screen
            screen.isColorEnabled = function() return true end
            ZenSpec.replace("apps/reader/readerui", ReaderUI)
        end)

        after_each(function()
            _G.G_reader_settings = original_settings
        end)

        it("shows KOReader's screen-dependent default when none is saved", function()
            local choices = default_choices()
            assert_default(choices, "Yellow")
            screen.isColorEnabled = function() return false end
            assert_default(choices, "Gray")
        end)

        it("saves one default from the library and preserves it when reopening settings", function()
            local choices = default_choices()
            for _i, name in ipairs({ "Red", "Blue", "Blue" }) do
                choices[name].callback()
                assert.are.equal(name:lower(), G_reader_settings:readSetting("highlight_color"))
                assert_default(choices, name)
                assert_default(default_choices(), name)
            end
        end)

        it("uses the new default immediately in the active book and refreshes selection color", function()
            local selection_updates = 0
            local annotation = { color = "red" }
            ReaderUI.instance = {
                view = { highlight = { saved_color = "orange" } },
                annotation = { annotations = { annotation } },
                highlight = { setSelectionColor = function()
                    selection_updates = selection_updates + 1
                end },
            }
            default_choices().Green.callback()
            assert.are.equal("green", G_reader_settings:readSetting("highlight_color"))
            assert.are.equal("green", ReaderUI.instance.view.highlight.saved_color)
            assert.are.equal(1, selection_updates)
            assert.are.equal("red", annotation.color)
        end)
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
            plugin = { config = config, saveConfig = function() saved = saved + 1 end },
            save_and_apply = function() end,
            apply_feature = function() applied = applied + 1 end,
        })
        local themes = find_item(items, "Reader themes")
        local custom_items = themes.sub_item_table[3].sub_item_table_func()
        local dark_warm_gray = custom_items[2]

        dark_warm_gray.sub_item_table[1].callback()
        assert.are.equal("#1f1f1f", shown_dialog.hex)
        shown_dialog.callback("#1f1f1f")
        assert.is_nil(config.reader_themes.custom.custom_1)

        dark_warm_gray.sub_item_table[1].callback()
        shown_dialog.callback("#101010")
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

    it("copies built-in and custom themes into separately named custom themes", function()
        local saved = 0
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
            reader_themes = {
                dark_mode = "dark_warm_gray",
                light_mode = "default",
                custom = {
                    paper = {
                        name = "Paper",
                        text = "#30251b",
                        background = "#f5e7ce",
                        font_face = "Example.ttf",
                    },
                },
            },
        }
        local items = ReaderSettings.build({
            config = config,
            plugin = {
                config = config,
                saveConfig = function() saved = saved + 1 end,
            },
            save_and_apply = function() end,
            apply_feature = function() end,
        })
        local themes = find_item(items, "Reader themes")
        local touchmenu = {
            item_table_stack = { { text = "Reader themes" } },
            onMenuSelect = function(self, item)
                self.opened_item = item
                table.insert(self.item_table_stack, self.item_table)
                self.item_table = item.sub_item_table
            end,
            backToUpperMenu = function(self)
                self.item_table = table.remove(self.item_table_stack)
            end,
        }
        local custom_items = themes.sub_item_table[3].sub_item_table_func()
        local builtin_copy
        for _i, item in ipairs(custom_items[2].sub_item_table) do
            if item.text == "Copy theme" then builtin_copy = item end
        end
        assert.is_table(builtin_copy)
        touchmenu.item_table = custom_items
        touchmenu:onMenuSelect(custom_items[2])
        builtin_copy.callback(touchmenu)
        assert.are.equal("Copy theme", shown_dialog.title)
        dialog_input = "   "
        shown_dialog.buttons[1][2].callback()
        assert.is_nil(config.reader_themes.custom.custom_1)
        dialog_input = "  Warm copy  "
        shown_dialog.buttons[1][2].callback()

        local builtin_copy_theme = config.reader_themes.custom.custom_1
        assert.are.same({
            name = "Warm copy",
            text = "#dcdccc",
            background = "#1f1f1f",
            font_face = "default",
        }, builtin_copy_theme)
        assert.are.equal("dark_warm_gray", config.reader_themes.dark_mode)
        assert.are.equal("Warm copy", touchmenu.opened_item.text_func())
        assert.are.equal(2, #touchmenu.item_table_stack)
        touchmenu:backToUpperMenu()
        assert.are.equal(1, #touchmenu.item_table_stack)
        local found_warm_copy = false
        for _i, item in ipairs(touchmenu.item_table) do
            if item.text_func and item.text_func() == "Warm copy" then found_warm_copy = true end
        end
        assert.is_true(found_warm_copy)

        custom_items = themes.sub_item_table[3].sub_item_table_func()
        local paper_item
        for _i, item in ipairs(custom_items) do
            if item.text_func and item.text_func() == "Paper" then paper_item = item end
        end
        local custom_copy
        for _i, item in ipairs(paper_item.sub_item_table) do
            if item.text == "Copy theme" then custom_copy = item end
        end
        touchmenu.item_table = custom_items
        touchmenu:onMenuSelect(paper_item)
        custom_copy.callback(touchmenu)
        dialog_input = "Paper variation"
        shown_dialog.buttons[1][2].callback()

        local paper_copy = config.reader_themes.custom.custom_2
        assert.are.same({
            name = "Paper variation",
            text = "#30251b",
            background = "#f5e7ce",
            font_face = "Example.ttf",
        }, paper_copy)
        assert.are_not.equal(config.reader_themes.custom.paper, paper_copy)
        paper_copy.text = "#000000"
        assert.are.equal("#30251b", config.reader_themes.custom.paper.text)
        assert.are.equal(2, #touchmenu.item_table_stack)
        touchmenu:backToUpperMenu()
        assert.are.equal(1, #touchmenu.item_table_stack)
        local found_paper_variation = false
        for _i, item in ipairs(touchmenu.item_table) do
            if item.text_func and item.text_func() == "Paper variation" then found_paper_variation = true end
        end
        assert.is_true(found_paper_variation)
        assert.are.equal(2, saved)
    end)

    it("adds a color preview to every built-in and custom mode choice", function()
        local config = {
            features = { reader_themes = false },
            reader_themes = {
                dark_mode = "dark_warm_gray",
                light_mode = "default",
                custom = {
                    custom_1 = {
                        name = "Paper",
                        text = "#123456",
                        background = "#abcdef",
                    },
                },
            },
        }
        local items = ReaderSettings.build({
            config = config,
            plugin = { saveConfig = function() end },
            save_and_apply = function() end,
        })
        local reader_themes = find_item(items, "Reader themes")

        for _i, mode_item in ipairs(reader_themes.sub_item_table) do
            if mode_item.text == "Dark mode" or mode_item.text == "Light mode" then
                local choices = mode_item.sub_item_table_func()
                assert.are.equal(19, #choices)
                local names = {}
                for _j, choice in ipairs(choices) do
                    assert.is_function(choice._zen_settings_content_func)
                    names[choice.text] = true
                end
                for _j, name in ipairs({
                    "Sepia", "Darker Sepia", "Old Book", "Sage", "Fern", "Arctic",
                    "Midnight", "Nord", "Amber Night", "Sepia Night", "Dark Moss",
                    "Dark Sky", "Velvet",
                }) do
                    assert.is_true(names[name], name)
                end
            end
        end

        local custom_theme_list = reader_themes.sub_item_table[3].sub_item_table_func()
        assert.is_nil(custom_theme_list[1]._zen_settings_content_func)
        for index = 2, #custom_theme_list do
            assert.is_function(custom_theme_list[index]._zen_settings_content_func)
        end
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

    it("shows footer presets as radio choices with the save action last", function()
        local preset_module = "modules/reader/patches/reader_footer_presets"
        local saved_presets, saved_util = package.loaded[preset_module], package.loaded["util"]
        finally(function()
            package.loaded[preset_module] = saved_presets
            package.loaded["util"] = saved_util
        end)
        local custom = { name = "My footer", footer = {} }
        local builtins = { { name = "First preset", footer = {} }, { name = "Second preset", footer = {} } }
        ZenSpec.replace(preset_module, builtins)
        ZenSpec.replace("util", { tableDeepCopy = function(value) return value end })
        local active, loaded = custom.name, nil
        local store = package.loaded["config/preset_store"]
        store.list = function() return { custom } end
        store.getActivePreset = function() return active end
        store.setActivePreset = function(_kind, name) active = name end
        store.saveSettings = function() end
        store.save = function(_kind, name) active = name end
        ZenSpec.replace("apps/reader/readerui", { instance = { view = { footer = {
            settings = {},
            addToMainMenu = function() end,
            loadPreset = function(_self, preset) loaded = preset end,
        } } } })
        local config = { features = {}, reader_footer = {} }
        local items = ReaderSettings.build{
            config = config, plugin = { saveConfig = function() end }, save_and_apply = function() end,
        }
        local bottom = find_item(items, "Bottom status bar").sub_item_table_func()
        local options = find_item(bottom, "Zen Presets").sub_item_table_func()
        assert.are.equal(4, #options)
        assert.are.same({ "My footer", "First preset", "Second preset" },
            { options[1].text, options[2].text, options[3].text })
        for i = 1, 3 do
            assert.is_true(options[i].radio)
            assert.are.equal(i == 1, options[i].checked_func())
        end
        options[2].callback()
        assert.are.equal(builtins[1], loaded)
        assert.is_false(options[1].checked_func())
        assert.is_true(options[2].checked_func())
        assert.is_false(options[3].checked_func())
        options[1].callback()
        assert.are.equal(custom, loaded)
        assert.is_true(options[1].checked_func())
        assert.is_false(options[2].checked_func())
        local save = options[#options]
        assert.are.equal("Save current settings as preset", save.text)
        assert.is_nil(save.radio)
        assert.is_nil(save.checked_func)
        save.callback()
        assert.are.equal("Preset name", shown_dialog.title)
        dialog_input = "New footer"
        shown_dialog.buttons[1][2].callback()
        assert.are.equal("New footer", active)
    end)

    it("offers chapter time formats as radio choices", function()
        local saved, toggled = 0, 0
        local chapter_item = {
            text_func = function() return "Time left to finish chapter (TC:)" end,
            callback = function() toggled = toggled + 1 end,
        }
        ZenSpec.replace("apps/reader/readerui", { instance = { view = { footer = {
            addToMainMenu = function(_self, menu)
                menu.status_bar = { sub_item_table = {
                    { text = "Status bar items", sub_item_table = { chapter_item } },
                } }
            end,
            textOptionTitles = function() return "Time left to finish chapter (TC:)" end,
        } } } })
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

        local bottom_items = find_item(items, "Bottom status bar").sub_item_table_func()
        assert.are.equal(chapter_item, find_item(bottom_items, "Status bar items").sub_item_table[1])
        assert.is_nil(chapter_item.callback)
        chapter_item.checkmark_callback()
        assert.are.equal(1, toggled)
        local chapter_time = find_item(chapter_item.sub_item_table, "Time until chapter end")
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
        dispatch.isBottomStatusBarEnabled = function(actual_plugin)
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
        for _i, item in ipairs(find_item(items, "Appearance").sub_item_table) do by_text[item.text] = item end

        local top = by_text["Top status bar"]
        local themes = by_text["Reader themes"]
        local bottom = by_text["Bottom status bar"]

        assert.is_false(top.checked_func())
        assert.are.equal("Left items", top.sub_item_table[1].text)
        assert.is_false(themes.checked_func())
        assert.are.equal(3, #themes.sub_item_table)
        assert.is_nil(by_text["Zen page browser"])
        assert.is_true(bottom.checked_func())
        assert.is_nil(bottom.enabled_func)

        top.checkmark_callback()
        themes.checkmark_callback()
        bottom.checkmark_callback()

        assert.is_true(config.features.reader_top_status_bar)
        assert.is_true(config.features.reader_themes)
        assert.is_false(bottom.checked_func())
        assert.are.equal(1, bottom_toggles)
        assert.are.same({
            "reader_top_status_bar",
            "reader_themes",
        }, applied)

        local bottom_items = bottom.sub_item_table_func()
        for _i, item in ipairs(bottom_items) do
            assert.are_not.equal("Enable bottom status bar", item.text)
        end

        package.loaded["apps/reader/readerui"].instance = nil
        config.reader_footer.status_bar_enabled = true
        assert.is_true(bottom.checked_func())
        assert.is_nil(bottom.enabled_func)
        config.reader_footer.status_bar_enabled = false
        assert.is_false(bottom.checked_func())
    end)

    it("saves the page-browser status bar preference and respects the interface status bar toggle", function()
        local saved = 0
        local config = { features = { status_bar = true },
            status_bar = { left_order = { "time" } },
            page_browser = { toc_font_size = 20, bookmarks_font_size = 22 } }
        local items = ReaderSettings.build{
            config = config, plugin = { saveConfig = function() saved = saved + 1 end },
            save_and_apply = function() end,
        }
        local choices = find_item(items, "Bottom swipe gesture").sub_item_table
        assert.are.equal("Reader controls", choices[2].text)
        assert.are.equal("Zen page browser", choices[3].text)
        local status = find_item(items, "Page Browser").sub_item_table[1]
        assert.are.equal("Top status bar", status.text)
        assert.is_true(status.checked_func())
        assert.is_true(status.enabled_func())
        status.callback()
        assert.is_false(status.checked_func())
        status.callback()
        assert.is_true(status.checked_func())
        assert.are.equal(2, saved)
        config.status_bar.left_order = {}
        assert.is_false(status.enabled_func())
        config.status_bar.right_order = { "battery" }
        assert.is_true(status.enabled_func())
        config.features.status_bar = false
        assert.is_false(status.enabled_func())
        assert.are.same({ show_status_bar = true, toc_font_size = 20, bookmarks_font_size = 22 }, config.page_browser)
    end)

    it("places the shared tab arrange list in Page Browser settings", function()
        local received
        ZenSpec.replace("modules/reader/page_browser_tabs", { show = function(config, plugin, ui)
            received = { config, plugin, ui }
        end })
        local config, plugin = { features = {} }, {}
        local ui = { paging = {} }
        ZenSpec.replace("apps/reader/readerui", { instance = ui })
        local items = ReaderSettings.build{ config = config, plugin = plugin, save_and_apply = function() end }
        local tabs = find_item(items, "Page Browser").sub_item_table[2]
        assert.are.equal("Tabs", tabs.text)
        assert.is_true(tabs._zen_settings_submenu)
        tabs.callback()
        assert.same({ config, plugin, ui }, received)
        assert.is_nil(find_item(find_item(items, "Annotation viewer").sub_item_table, "Tabs"))
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
            plugin = { config = config, saveConfig = function() saved = saved + 1 end },
            save_and_apply = function() end,
            apply_feature = function() applied = applied + 1 end,
        })
        local themes = find_item(items, "Reader themes")
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
        assert.are.equal(9, #touchmenu.item_table)
        for index = 7, 9 do
            assert.are.equal("Theme preview", touchmenu.item_table[index].text)
            assert.is_function(touchmenu.item_table[index]._zen_settings_content_func)
        end
        assert.are.equal("Copy theme", touchmenu.item_table[5].text)
        assert.are.equal(1, saved)
        assert.are.equal(1, applied)

        touchmenu.item_table[6].callback(touchmenu)
        shown_dialog.ok_callback()

        assert.is_nil(config.reader_themes.custom.custom_1)
        assert.are.equal(0, #touchmenu.item_table_stack)
        assert.are.equal(18, #touchmenu.item_table)
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
            plugin = { config = config, saveConfig = function() saved = saved + 1 end },
            save_and_apply = function(feature) applied[#applied + 1] = feature end,
            apply_feature = function(feature) applied[#applied + 1] = feature end,
        })
        local themes = find_item(items, "Reader themes")

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
        local top = find_item(built, "Top status bar")

        local center_items = top.sub_item_table[2].sub_item_table
        local item_labels = {}
        for _i, item in ipairs(center_items) do item_labels[item.text] = item end
        assert.is_not_nil(item_labels["Battery icon"])
        assert.is_not_nil(item_labels["Battery percentage"])
        assert.is_not_nil(item_labels["Current page"])
        assert.is_not_nil(item_labels["Total pages"])
        assert.is_not_nil(item_labels["Pin"])
        assert.is_function(item_labels["Total pages"].callback)
        local page_settings = item_labels["Current / total pages"].sub_item_table
        assert.are.equal("Separator", page_settings[1].text)
        assert.are.equal("Total", page_settings[2].text)
        local page_separator = page_settings[1].sub_item_table
        assert.is_true(page_separator[1].radio)
        assert.is_true(page_separator[2].radio)
        assert.is_true(page_separator[1].checked_func())
        page_separator[2].callback()
        assert.are.equal("of", config.reader_top_status_bar.page_separator)
        assert.is_true(page_separator[2].checked_func())

        local page_scope = page_settings[2].sub_item_table
        assert.are.equal("Book", page_scope[1].text)
        assert.are.equal("Chapter", page_scope[2].text)
        assert.is_true(page_scope[1].radio)
        assert.is_true(page_scope[2].radio)
        assert.is_true(page_scope[1].checked_func())
        page_scope[2].callback()
        assert.are.equal("chapter", config.reader_top_status_bar.page_count_scope)
        assert.is_true(page_scope[2].checked_func())
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
        assert.are.equal(5, applies)
    end)
end)
