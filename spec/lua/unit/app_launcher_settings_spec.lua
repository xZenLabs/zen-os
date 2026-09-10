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
            page_order = { "book_details", "book_switcher", "buttons" },
            book_details_order = {
                "read_time", "time_remaining", "pages_today",
                "time_today", "pages", "progress",
            },
            book_details_enabled = {
                read_time = true,
                time_remaining = true,
                pages_today = false,
                time_today = false,
                pages = true,
                progress = true,
            },
        }

        ZenSpec.replace("gettext", function(text) return text end)
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
            wrap = function(_items, _caller, on_update)
                dispatcher_update = on_update
            end,
        })
        ZenSpec.replace("common/library_destination", {
            folderLabel = function(path) return path:match("([^/]+)$") or path end,
            chooseFolder = function(callback) choose_folder = callback end,
            chooseTag = function(callback) choose_tag = callback end,
        })
        ZenSpec.replace("dispatcher", {
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

    it("offers page visibility options and arranges their launcher order", function()
        local section = require(
            "modules/settings/sections/app_launcher_settings").build({
                config = { features = { app_launcher = true } },
                save_and_apply = function() end,
        })
        local details
        for _i, item in ipairs(section.sub_item_table) do
            if item.text == "Book details" then details = item end
        end

        assert.is_table(details)
        assert.is_false(details.checked_func())
        details.checkmark_callback()
        assert.is_true(launcher_cfg.show_book_details)
        assert.are.equal(1, #details.sub_item_table)
        assert.are.equal("Items \u{25B8}", details.sub_item_table[1].text)
        details.sub_item_table[1].callback()
        assert.are.equal("Book details", shown_options.title)
        assert.are.same({
            "Read time", "Time remaining", "Pages today",
            "Time today", "Pages", "Progress bar",
        }, {
            shown_options.item_table[1].text,
            shown_options.item_table[2].text,
            shown_options.item_table[3].text,
            shown_options.item_table[4].text,
            shown_options.item_table[5].text,
            shown_options.item_table[6].text,
        })
        assert.is_true(shown_options.item_table[1].checked_func())
        shown_options.item_table[1].callback()
        assert.is_false(launcher_cfg.book_details_enabled.read_time)
        shown_options.item_table[1], shown_options.item_table[6]
            = shown_options.item_table[6], shown_options.item_table[1]
        shown_options.callback()
        assert.are.same({
            "progress", "time_remaining", "pages_today",
            "time_today", "pages", "read_time",
        }, launcher_cfg.book_details_order)

        local switcher
        local order_item
        local order_index
        local open_menu_index
        for _i, item in ipairs(section.sub_item_table) do
            if item.text == "Book switcher" then switcher = item end
            if item.text:match("^Order") then
                order_item = item
                order_index = _i
            end
            if item.text == "Open menu to Launcher" then open_menu_index = _i end
        end
        assert.is_false(switcher.checked_func())
        switcher.checkmark_callback()
        assert.is_true(launcher_cfg.show_book_switcher)
        assert.are.equal(1, #switcher.sub_item_table)
        assert.are.equal("Only show while reading", switcher.sub_item_table[1].text)
        assert.are.equal(order_index + 1, open_menu_index)
        assert.are.equal("sort", order_item.test_icon)

        order_item.callback()
        assert.are.equal("Order", shown_options.title)
        assert.are.same({ "Book information", "Book switcher", "Buttons" }, {
            shown_options.item_table[1].text,
            shown_options.item_table[2].text,
            shown_options.item_table[3].text,
        })
        shown_options.item_table[1], shown_options.item_table[3]
            = shown_options.item_table[3], shown_options.item_table[1]
        shown_options.callback()
        assert.are.same({ "buttons", "book_switcher", "book_details" },
            launcher_cfg.page_order)
        assert.are.equal(5, saves)
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
        local title_item = shown_options.item_table[1]
        assert.are.equal("Title: Reading", title_item.text_func())
        title_item.callback()
        dialog.buttons[1][2].callback()

        assert.is_nil(entry.label)
        assert.are.equal(1, saves)
    end)
end)
