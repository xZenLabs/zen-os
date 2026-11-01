describe("app launcher settings", function()
    local entry
    local launcher_cfg
    local original_quick_settings
    local picker_options
    local saves
    local shown_options
    local suggested_label
    local suggested_preferred
    local dispatcher_action
    local dispatcher_text
    local dispatcher_update
    local choose_folder
    local choose_tag

    before_each(function()
        original_quick_settings = rawget(_G, "__ZEN_UI_QUICK_SETTINGS")
        entry = {
            id = "al_1",
            type = "plugin",
            label = "Legacy",
            icon = "zen_ui",
            plugin = { key = "legacy", method = "open" },
        }
        shown_options = nil
        picker_options = nil
        suggested_label = nil
        suggested_preferred = nil
        dispatcher_action = nil
        dispatcher_text = "Nothing"
        dispatcher_update = nil
        choose_folder = nil
        choose_tag = nil
        saves = 0
        launcher_cfg = {
            entries = { entry },
            page_order = { "book_switcher", "buttons" },
        }

        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("device", { isTouchDevice = function() return true end })
        ZenSpec.replace("ffi/util", {
            template = function(text, value)
                return text:gsub("%%1", tostring(value))
            end,
        })
        ZenSpec.replace("ui/uimanager", {
            nextTick = function(_self, callback) callback() end,
        })
        ZenSpec.replace("common/inline_icon_map", setmetatable({}, {
            __index = function(_self, key) return key end,
        }))
        ZenSpec.replace("common/ui/icon_menu_item", {
            decorate = function(item, icon)
                item.test_icon = icon
                return item
            end,
        })
        ZenSpec.replace("common/utils", {
            getIconDisplayName = function(name)
                return name == "zen_ui" and "ZenOS" or name
            end,
            getIconPickerList = function() return {} end,
            stripZenPrefix = function(text)
                return text:gsub("^ZenOS%s*[:%-]%s*", "")
            end,
            suggestIcon = function(_root, label, _fallback, _strip_zen_prefix, preferred)
                suggested_label = label
                suggested_preferred = preferred
                return preferred and "approved_zenfm" or "lightning"
            end,
        })
        ZenSpec.replace("modules/menu/app_launcher/model", {
            ensure = function()
                return launcher_cfg
            end,
            display_label = function(item) return item.label or "Row break" end,
            next_id = function() return "al_2" end,
            save = function() saves = saves + 1 end,
        })
        ZenSpec.replace("modules/menu/app_launcher/native_menu", {
            scan = function() return {} end,
        })
        ZenSpec.replace("modules/menu/app_launcher/plugin_scan", {
            scan = function() return {} end,
        })
        ZenSpec.replace("common/dispatcher_menu", {
            addSubMenu = function(dispatcher, ...)
                return dispatcher:addSubMenu(...)
            end,
            wrap = function(_items, _caller, on_update)
                dispatcher_update = on_update
            end,
        })
        ZenSpec.replace("common/library_destination", {
            folderLabel = function(path) return path:match("([^/]+)$") or path end,
            chooseFolder = function(callback) choose_folder = callback end,
            chooseTag = function(callback) choose_tag = callback end,
        })
        local settingsList = { reader_action = { reader = true } }
        ZenSpec.replace("dispatcher", {
            registerAction = function() return settingsList end,
            addSubMenu = function(_self, _caller, _items, location, settings)
                if dispatcher_action then location[settings] = dispatcher_action end
            end,
            menuTextFunc = function() return dispatcher_text end,
        })
        ZenSpec.replace("common/plugin_root", "/plugin")
        ZenSpec.replace("common/ui/zen_arrange_list", {
            show = function(options) shown_options = options end,
        })
        ZenSpec.replace("common/ui/zen_menu_picker", function(options)
            picker_options = options
        end)
        ZenSpec.unload("modules/settings/sections/app_launcher_settings")
        ZenSpec.unload("modules/menu/app_launcher/action_filter")
    end)

    after_each(function()
        _G.__ZEN_UI_QUICK_SETTINGS = original_quick_settings
    end)

    it("displays ZenOS without rewriting the persisted legacy icon ID", function()
        local section = require(
            "modules/settings/sections/app_launcher_settings").build({
                config = { features = { app_launcher = true } },
                save_and_apply = function() end,
        })

        local search_items = section._zen_search_items_func()
        assert.is_true(search_items[1]._zen_search_open())
        local icon_label
        for _i, item in ipairs(shown_options.item_table) do
            if item.text_func and item.text_func():sub(1, 6) == "Icon: " then
                icon_label = item.text_func()
                break
            end
        end

        assert.are.equal("Icon: ZenOS", icon_label)
        assert.are.equal("zen_ui", entry.icon)
    end)

    it("toggles reader action classification for every button type", function()
        local section = require(
            "modules/settings/sections/app_launcher_settings").build({
                config = { features = { app_launcher = true } },
                save_and_apply = function() end,
        })
        local refreshes = 0
        local touch_menu = { updateItems = function() refreshes = refreshes + 1 end }
        for _i, entry_type in ipairs({
            "plugin", "quick_setting", "koreader_menu", "folder_shortcut", "tag", "folder", "action",
        }) do
            entry.type = entry_type
            entry.reader_action = nil
            entry.folder = "/library"
            entry.action = { reader_action = true }
            assert.is_true(section._zen_search_items_func()[1]._zen_search_open())
            local reader_item
            for _j, item in ipairs(shown_options.item_table) do
                if item.text == "Reader action" then reader_item = item end
            end
            assert.is_table(reader_item)
            assert.are.equal("When enabled, this action is hidden in the library.", reader_item.help_text)
            local default = entry_type == "action"
            assert.are.equal(default, reader_item.checked_func())
            reader_item.callback(touch_menu)
            assert.are.equal(not default, entry.reader_action)
            assert.are.equal(not default, reader_item.checked_func())
            reader_item.callback(touch_menu)
            assert.are.equal(default, entry.reader_action)
            assert.are.equal(default, reader_item.checked_func())
        end
        assert.are.equal(14, saves)
        assert.are.equal(14, refreshes)
    end)

    it("offers page visibility options and arranges their launcher order", function()
        local section = require(
            "modules/settings/sections/app_launcher_settings").build({
                config = { features = { app_launcher = true } },
                save_and_apply = function() end,
        })
        for _i, item in ipairs(section.sub_item_table) do
            assert.are_not.equal("Book details", item.text)
            assert.are_not.equal("Hide reader actions in library", item.text)
        end

        local switcher
        local order_item
        local order_index
        local open_menu_index
        for _i, item in ipairs(section.sub_item_table) do
            if item.text == "Book switcher" then switcher = item end
            if item.text and item.text:match("^Order") then
                order_item = item
                order_index = _i
            end
            if item.text == "Open menu to Launcher" then open_menu_index = _i end
        end
        assert.is_false(switcher.checked_func())
        switcher.checkmark_callback()
        assert.is_true(launcher_cfg.show_book_switcher)
        assert.are.equal(3, #switcher.sub_item_table)
        assert.are.equal("Only show while reading", switcher.sub_item_table[1].text)
        assert.are.equal(order_index + 1, open_menu_index)
        assert.are.equal("sort", order_item.icon_glyph)

        order_item.callback()
        assert.are.equal("Order", shown_options.title)
        assert.are.same({ "Book switcher", "Buttons" }, {
            shown_options.item_table[1].text,
            shown_options.item_table[2].text,
        })
        assert.is_nil(shown_options.item_table[3])
        shown_options.item_table[1], shown_options.item_table[2]
            = shown_options.item_table[2], shown_options.item_table[1]
        shown_options.callback()
        assert.are.same({ "buttons", "book_switcher" }, launcher_cfg.page_order)
        assert.are.equal(2, saves)
    end)

    it("sets the switcher limit and defaults to hiding finished books", function()
        local spin_options
        local refreshes = 0
        ZenSpec.replace("ui/widget/spinwidget", {
            new = function(_self, options) spin_options = options return options end,
        })
        ZenSpec.replace("ui/uimanager", { show = function() end })
        local section = require(
            "modules/settings/sections/app_launcher_settings").build({
                config = { features = { app_launcher = true } },
                save_and_apply = function() end,
        })
        local items = section.sub_item_table[3].sub_item_table
        assert.are.equal("Max books shown: 4", items[2].text_func())
        items[2].callback({ updateItems = function() refreshes = refreshes + 1 end })
        assert.are.equal(1, spin_options.value_min)
        assert.are.equal(8, spin_options.value_max)
        assert.are.equal(4, spin_options.default_value)
        spin_options.callback({ value = 8 })
        assert.are.equal(8, launcher_cfg.book_switcher_count)
        assert.are.equal("Max books shown: 8", items[2].text_func())
        assert.are.equal(1, refreshes)
        assert.are.equal("Hide finished books", items[3].text)
        assert.is_true(items[3].checked_func())
        items[3].callback()
        assert.is_false(items[3].checked_func())
        items[3].callback()
        assert.is_true(items[3].checked_func())
        assert.are.equal(3, saves)
    end)

    it("stores an approved icon name instead of a control's plugin path", function()
        _G.__ZEN_UI_QUICK_SETTINGS = {
            getItems = function()
                return {{
                    id = "zenfm",
                    label = "ZenFM",
                    icon = "/plugins/zenfm.koplugin/icons/zenfm.svg",
                }}
            end,
        }
        local section = require(
            "modules/settings/sections/app_launcher_settings").build({
                config = { features = { app_launcher = true } },
                save_and_apply = function() end,
        })

        section.sub_item_table[2].callback()
        local add_control
        for _i, item in ipairs(shown_options.add_item_table) do
            if item.text == "Control" then add_control = item end
        end
        add_control.callback()
        picker_options.on_select(picker_options.items[1])

        local added = launcher_cfg.entries[2]
        assert.are.equal("/plugins/zenfm.koplugin/icons/zenfm.svg", suggested_preferred)
        assert.are.equal("approved_zenfm", added.icon)
    end)

    it("omits control settings for ZenFM launcher buttons", function()
        entry.type = "quick_setting"
        entry.label = "ZenFM"
        entry.quick_setting_id = "zenfm"
        _G.__ZEN_UI_QUICK_SETTINGS = {
            getSettingsItems = function()
                return {{ text = "Timeout" }}
            end,
        }
        local section = require(
            "modules/settings/sections/app_launcher_settings").build({
                config = { features = { app_launcher = true } },
                save_and_apply = function() end,
        })

        assert.is_true(section._zen_search_items_func()[1]._zen_search_open())
        for _i, item in ipairs(shown_options.item_table) do
            assert.are_not.equal("Control settings", item.text)
        end
    end)

    it("keeps control settings for other launcher controls", function()
        entry.type = "quick_setting"
        entry.label = "Wi-Fi"
        entry.quick_setting_id = "wifi"
        _G.__ZEN_UI_QUICK_SETTINGS = {
            getSettingsItems = function()
                return {{ text = "Network settings" }}
            end,
        }
        local section = require(
            "modules/settings/sections/app_launcher_settings").build({
                config = { features = { app_launcher = true } },
                save_and_apply = function() end,
        })

        assert.is_true(section._zen_search_items_func()[1]._zen_search_open())
        local settings_item
        for _i, item in ipairs(shown_options.item_table) do
            if item.text == "Control settings" then settings_item = item end
        end
        assert.is_table(settings_item)
        assert.are.equal("Network settings", settings_item.sub_item_table[1].text)
    end)

    it("strips the ZenOS prefix from a new action label and icon suggestion", function()
        dispatcher_action = { zen_ui_home = true }
        dispatcher_text = "ZenOS: Home"
        local section = require(
            "modules/settings/sections/app_launcher_settings").build({
                config = { features = { app_launcher = true } },
                save_and_apply = function() end,
        })
        section.sub_item_table[2].callback()
        local add_action
        for _i, item in ipairs(shown_options.add_item_table) do
            if item.text == "Action" then add_action = item; break end
        end
        local touch_menu = {
            item_table = {},
            item_table_stack = {},
            updateItems = function() end,
        }

        add_action.callback(touch_menu)
        dispatcher_update(touch_menu)

        assert.are.equal("Home", launcher_cfg.entries[2].label)
        assert.are.equal("Home", suggested_label)
    end)

    it("adds multiple folder shortcuts and a specific tag", function()
        local next_id = 1
        package.loaded["modules/menu/app_launcher/model"].next_id = function()
            next_id = next_id + 1
            return "al_" .. next_id
        end
        local section = require(
            "modules/settings/sections/app_launcher_settings").build({
                config = { features = { app_launcher = true } },
                save_and_apply = function() end,
        })
        section.sub_item_table[2].callback()
        assert.are.same({
            "Action", "Control", "Plugin Menu", "KOReader menu",
            "Folder", "Open folder", "Specific tag", "Row break",
        }, {
            shown_options.add_item_table[1].text,
            shown_options.add_item_table[2].text,
            shown_options.add_item_table[3].text,
            shown_options.add_item_table[4].text,
            shown_options.add_item_table[5].text,
            shown_options.add_item_table[6].text,
            shown_options.add_item_table[7].text,
            shown_options.add_item_table[8].text,
        })
        local add_folder
        local add_tag
        for _i, item in ipairs(shown_options.add_item_table) do
            if item.text == "Open folder" then add_folder = item end
            if item.text == "Specific tag" then add_tag = item end
        end

        add_folder.callback()
        choose_folder("/library/Fiction")
        assert.are.equal("folder", suggested_preferred)
        add_folder.callback()
        choose_folder("/library/Nonfiction")
        assert.are.equal("folder", suggested_preferred)
        add_tag.callback()
        choose_tag("Science")

        assert.are.same({
            { id = "al_2", type = "folder_shortcut", folder = "/library/Fiction",
                label = "Fiction", label_auto = true, icon = "approved_zenfm" },
            { id = "al_3", type = "folder_shortcut", folder = "/library/Nonfiction",
                label = "Nonfiction", label_auto = true, icon = "approved_zenfm" },
            { id = "al_4", type = "tag", tag = "Science",
                label = "Science", label_auto = true, icon = "approved_zenfm" },
        }, { launcher_cfg.entries[2], launcher_cfg.entries[3], launcher_cfg.entries[4] })
    end)

    it("edits and clears an optional row-break title", function()
        entry.type = "break"
        entry.label = "Reading"
        entry.icon = nil
        entry.plugin = nil
        local dialog
        ZenSpec.replace("ui/widget/inputdialog", {
            new = function(_self, opts)
                opts.getInputText = function() return "" end
                opts.onShowKeyboard = function() end
                dialog = opts
                return opts
            end,
        })
        local UIManager = require("ui/uimanager")
        UIManager.show = function() end
        UIManager.close = function() end
        local section = require(
            "modules/settings/sections/app_launcher_settings").build({
                config = { features = { app_launcher = true } },
                save_and_apply = function() end,
        })

        assert.is_true(section._zen_search_items_func()[1]._zen_search_open())
        for _i, item in ipairs(shown_options.item_table) do
            assert.are_not.equal("Reader action", item.text)
        end
        local title_item = shown_options.item_table[1]
        assert.are.equal("Title: Reading", title_item.text_func())
        title_item.callback()
        dialog.buttons[1][2].callback()

        assert.is_nil(entry.label)
        assert.are.equal(1, saves)
    end)
    it("edits reader buttons independently and offers only the four supported entry types", function()
        local reader_cfg = { entries = { { id = "reader_1", type = "action", label = "Reader action", action = {} } }, next_id = 1 }
        local reader_saves = 0
        local section = require("modules/settings/sections/app_launcher_settings").build{
            config = { features = {} }, button_config = reader_cfg, button_scope = "reader",
            save_buttons = function() reader_saves = reader_saves + 1 end,
        }
        section.callback()
        local labels = {}
        for _i, item in ipairs(shown_options.add_item_table) do labels[#labels + 1] = item.text end
        assert.are.same({ "Action", "Control", "Plugin Menu", "KOReader menu" }, labels)
        shown_options.item_table[1].callback()
        assert.is_false(reader_cfg.entries[1].enabled)
        assert.are.equal(1, reader_saves)
        assert.are.equal(0, saves)
        assert.are.equal("Legacy", launcher_cfg.entries[1].label)
    end)

    it("replaces a custom swipe target through the launcher add picker", function()
        local cfg = { entries = { entry }, next_id = 0 }
        local saved, picker
        ZenSpec.replace("modules/menu/app_launcher/plugin_scan", {
            scan = function() return { { title = "Plugin", key = "test", method = "open" } } end,
        })
        ZenSpec.replace("common/ui/zen_menu_picker", function(options) picker = options end)
        local section = require("modules/settings/sections/app_launcher_settings").build{
            config = { features = {} }, button_config = cfg, button_scope = "reader", button_single = true,
            save_buttons = function() saved = true end,
        }
        assert.are.equal("Bottom swipe gesture", section.text)
        assert.is_nil(section.callback)
        local touch_menu = {
            updateItems = function() end,
            _pending_navigation_title = "Plugin Menu",
            _openSubmenu = function(_self, item, items)
                assert.are.equal("Bottom swipe gesture", item.sub_title)
                shown_options = items
            end,
        }
        section.sub_item_table[3].callback(touch_menu)
        picker.on_select(picker.items[1])
        assert.is_true(saved)
        assert.are.equal(1, #cfg.entries)
        assert.are.equal("Plugin", cfg.entries[1].label)
        assert.are.same({ key = "test", method = "open" }, cfg.entries[1].plugin)
        assert.are.equal(entry, launcher_cfg.entries[1])
        assert.are.equal(0, saves)
        assert.are.equal(2, #shown_options)
        assert.are.equal("Plugin: Plugin", shown_options[1].text_func())
        assert.are.equal("Delete", shown_options[2].text)
    end)

    it("edits an existing swipe action without button presentation settings or replacing its actions", function()
        entry.type = "action"
        entry.action = { reader_action = true }
        local cfg = { entries = { entry } }
        local saved = 0
        local section = require("modules/settings/sections/app_launcher_settings").build{
            config = { features = {} }, button_config = cfg, button_single = true,
            save_buttons = function() saved = saved + 1 end,
        }
        section.sub_item_table[1].callback{
            updateItems = function() end,
            _pending_navigation_title = "Action",
            _openSubmenu = function(_self, _item, items) shown_options = items end,
        }
        assert.are.equal(2, #shown_options)
        assert.is_truthy(shown_options[1].text_func():find("Action:", 1, true))
        assert.are.equal("Delete", shown_options[2].text)
        dispatcher_update()
        assert.are.equal(1, saved)
        assert.are.equal(entry, cfg.entries[1])
        assert.are.same({ reader_action = true }, entry.action)
        assert.is_nil(entry._zen_draft_commit)
    end)

    it("edits and disables built-in reader buttons without offering deletion", function()
        local config = { features = {} }
        local reader_saves = 0
        local section = require("modules/settings/sections/reader_controls_settings").build{
            config = config, save_and_apply = function() reader_saves = reader_saves + 1 end,
        }
        assert.are.equal("Buttons \u{25B8}", section.sub_item_table[1].text)
        assert.are.equal(1, #section.sub_item_table)
        assert.is_nil(config.reader_controls.open_first)
        section.sub_item_table[1].callback()
        assert.are.equal("Buttons", shown_options.title)
        assert.are.equal(14, #shown_options.item_table)
        assert.are.equal(4, #shown_options.add_item_table)
        assert.is_false(shown_options.open_add_on_show)
        local row = shown_options.item_table[2]
        assert.are.equal("Font", row.text_func())
        row.callback()
        assert.is_false(config.reader_controls.entries[2].enabled)
        local items = row.sub_item_table_func()
        assert.are.equal("Label: Font", items[1].text_func())
        assert.is_truthy(items[2].text_func():find("Icon:", 1, true))
        assert.are.equal(2, #items)
        local extra = { book_switcher = 2, book_info = 1 }
        for _i, button in ipairs(shown_options.item_table) do
            local settings = button.sub_item_table_func()
            assert.are.equal(2 + (extra[button.orig_entry.control] or 0), #settings)
            for _j, item in ipairs(settings) do assert.are_not.equal("Delete", item.text) end
        end
        local original = shown_options.item_table[2]
        shown_options.item_table[2] = shown_options.item_table[4]
        shown_options.item_table[4] = original
        shown_options.callback()
        assert.are.equal("page", config.reader_controls.entries[2].control)
        table.remove(config.reader_controls.entries, 4)
        section.sub_item_table[1].callback()
        assert.are.equal(13, #shown_options.item_table)
        assert.are.equal("Font", shown_options.add_item_table[5].text)
        shown_options.add_item_table[5].callback()
        assert.are.equal("font", config.reader_controls.entries[14].control)
        assert.are.equal(3, reader_saves)
        assert.are.equal(0, saves)
    end)

    it("shows current reader icon defaults and saves or clears manual overrides", function()
        local selected, select_icon
        ZenSpec.replace("common/ui/zen_icon_picker", function(_icons, current, callback)
            selected, select_icon = current, callback
        end)
        local config = { features = {} }
        local reader_saves = 0
        local section = require("modules/settings/sections/reader_controls_settings").build{
            config = config, save_and_apply = function() reader_saves = reader_saves + 1 end,
        }
        section.sub_item_table[1].callback()
        local row = shown_options.item_table[10]
        row.orig_entry.icon = "paint_palette"
        local item = row.sub_item_table_func()[2]
        assert.are.equal("Icon: settings_brush", item.text_func())
        item.callback()
        assert.are.equal("settings_brush", selected)
        select_icon("info")
        assert.are.equal("info", row.orig_entry.icon_override)
        assert.are.equal("Icon: info", item.text_func())
        item.callback()
        assert.are.equal("info", selected)
        select_icon("settings_brush")
        assert.is_nil(row.orig_entry.icon_override)
        assert.are.equal("Icon: settings_brush", item.text_func())
        assert.are.equal(2, reader_saves)
        assert.are.equal(0, saves)
    end)

    it("still deletes user-added reader buttons after confirmation", function()
        ZenSpec.replace("modules/menu/app_launcher/store", {})
        ZenSpec.unload("modules/menu/app_launcher/model")
        local confirmation
        package.loaded["ui/uimanager"].show = function(_self, widget) confirmation = widget end
        ZenSpec.replace("ui/widget/confirmbox", { new = function(_self, options) return options end })
        local reader_cfg = { entries = { entry } }
        local reader_saves, backs = 0, 0
        local section = require("modules/settings/sections/app_launcher_settings").build{
            config = { features = {} }, button_config = reader_cfg, button_scope = "reader",
            save_buttons = function() reader_saves = reader_saves + 1 end,
        }
        section.callback()
        local items = shown_options.item_table[1].sub_item_table_func()
        local delete = items[#items]
        assert.are.equal("Delete", delete.text)
        delete.callback{ backToUpperMenu = function() backs = backs + 1 end }
        assert.are.equal("Delete this button?", confirmation.text)
        assert.are.same({ entry }, reader_cfg.entries)
        assert.are.equal(0, reader_saves)
        confirmation.ok_callback()
        assert.are.same({}, reader_cfg.entries)
        assert.are.equal(1, reader_saves)
        assert.are.equal(1, backs)
        assert.are.equal(0, saves)
    end)

    it("lists menu buttons alongside reader controls instead of in the plus menu", function()
        local config = { features = {}, reader_controls = { entries = {}, buttons_initialized = true,
            annotations_merged = true, contrast_split = true } }
        local section = require("modules/settings/sections/reader_controls_settings").build{
            config = config, save_and_apply = function() end,
        }
        section.sub_item_table[1].callback()
        assert.are.equal(4, #shown_options.item_table)
        for i, label in ipairs({ "Vocabulary builder", "Page Browser", "KOReader reader menu", "Book switcher" }) do
            local row = shown_options.item_table[i]
            assert.are.equal(label, row.text_func())
            for _j, item in ipairs(shown_options.add_item_table) do assert.are_not.equal(label, item.text) end
            local checked = row.checked_func()
            row.callback()
            assert.are.equal(not checked, row.checked_func())
        end
    end)

    it("limits reader toggles and adds custom or built-in buttons disabled when full", function()
        local message
        package.loaded["ui/uimanager"].show = function(_self, widget) message = widget.text end
        ZenSpec.replace("ui/widget/infomessage", { new = function(_self, options) return options end })
        ZenSpec.replace("modules/menu/app_launcher/plugin_scan", {
            scan = function() return { { title = "Plugin", key = "test", method = "open" } } end,
        })
        local config = { features = {} }
        local reader_saves = 0
        local section = require("modules/settings/sections/reader_controls_settings").build{
            config = config, save_and_apply = function() reader_saves = reader_saves + 1 end,
        }
        local function open()
            section.sub_item_table[1].callback()
            local rows = {}
            for _i, row in ipairs(shown_options.item_table) do rows[row.orig_entry.control or row.orig_entry.id] = row end
            return rows
        end
        local rows = open()
        for _i, control in ipairs({ "vocabulary", "page_browser", "koreader_menu" }) do rows[control].callback() end
        rows.profiles.callback()
        assert.is_false(rows.profiles.checked_func())
        assert.are.equal("Maximum 8 reader controls per book", message)
        assert.are.equal(3, reader_saves)
        rows.font.callback()
        rows.profiles.callback()
        assert.is_false(rows.profiles.checked_func())
        rows.contrast.callback()
        rows.profiles.callback()
        assert.is_true(rows.profiles.checked_func())
        rows.font.callback()
        assert.is_false(rows.font.checked_func())

        table.remove(config.reader_controls.entries, 2)
        rows = open()
        for _i, item in ipairs(shown_options.add_item_table) do
            if item.text == "Font" then item.callback() end
        end
        assert.is_false(config.reader_controls.entries[#config.reader_controls.entries].enabled)

        shown_options.add_item_table[3].callback()
        picker_options.on_select(picker_options.items[1])
        local added = config.reader_controls.entries[#config.reader_controls.entries]
        assert.are.equal("plugin", added.type)
        assert.is_false(added.enabled)
        rows = open()
        rows[added.id].callback()
        assert.is_false(added.enabled)
        rows.profiles.callback()
        rows[added.id].callback()
        assert.is_true(added.enabled)
    end)

end)
