describe("Controls destination settings", function()
    local arrange_options
    local choose_folder
    local choose_tag
    local config
    local dispatcher_action
    local dispatcher_text
    local dispatcher_update
    local icon_picker_callback
    local icon_picker_current
    local input_text
    local shown_widget
    local suggested_label

    before_each(function()
        arrange_options = nil
        choose_folder = nil
        choose_tag = nil
        dispatcher_action = nil
        dispatcher_text = "Nothing"
        dispatcher_update = nil
        icon_picker_callback = nil
        icon_picker_current = nil
        input_text = ""
        shown_widget = nil
        suggested_label = nil
        config = {
            quick_settings = {
                button_order = {},
                show_buttons = {},
                custom_buttons = {},
                next_custom_id = 0,
                gyro_label = "",
                gyro_icon = "quick_rotate",
                zen_settings_label = "",
                zen_settings_icon = "zen_ui",
                launcher_label = "",
                launcher_icon = "app_launcher",
                unified_light_slider = true,
                unified_light_slider_centered = false,
                tailscale_toggle_wifi = false,
                background_hatching = false,
            },
        }
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ffi/util", {
            template = function(text, value) return text:gsub("%%1", tostring(value)) end,
        })
        ZenSpec.replace("device", {
            hasFrontlight = function() return false end,
            hasGSensor = function() return true end,
        })
        ZenSpec.replace("ui/uimanager", {
            show = function(_self, widget) shown_widget = widget end,
            close = function() end,
        })
        ZenSpec.replace("ui/widget/inputdialog", {
            new = function(_self, options)
                options.getInputText = function() return input_text end
                return options
            end,
        })
        ZenSpec.replace("config/defaults", { quick_settings = {
            button_order = {}, show_buttons = {},
            show_frontlight = true, show_warmth = true,
            gyro_label = "", gyro_icon = "quick_rotate",
            zen_settings_label = "", zen_settings_icon = "zen_ui",
            launcher_label = "", launcher_icon = "app_launcher",
            unified_light_slider = true,
            unified_light_slider_centered = false,
            tailscale_toggle_wifi = false,
            background_hatching = false,
        } })
        ZenSpec.replace("common/inline_icon_map", setmetatable({}, {
            __index = function(_self, key) return key end,
        }))
        ZenSpec.replace("common/ui/icon_menu_item", {
            decorate = function(item) return item end,
        })
        ZenSpec.replace("modules/menu/app_launcher/native_menu", { scan = function() return {} end })
        ZenSpec.replace("modules/menu/app_launcher/plugin_scan", { scan = function() return {} end })
        ZenSpec.replace("common/dispatcher_menu", {
            wrap = function(_items, _caller, on_update)
                dispatcher_update = on_update
            end,
        })
        ZenSpec.replace("common/utils", {
            deepcopy = function(value) return value end,
            stripZenPrefix = function(text)
                return text:gsub("^ZenOS%s*[:%-]%s*", "")
            end,
            suggestIcon = function(_root, label, _fallback, _strip, preferred)
                suggested_label = label
                return preferred or "lightning"
            end,
            getIconPickerList = function() return {} end,
            getIconDisplayName = function(name) return name end,
        })
        ZenSpec.replace("modules/menu/bluetooth/bluetooth", { isAvailable = function() return false end })
        ZenSpec.replace("common/library_destination", {
            folderLabel = function(path) return path:match("([^/]+)$") or path end,
            chooseFolder = function(callback) choose_folder = callback end,
            chooseTag = function(callback) choose_tag = callback end,
        })
        ZenSpec.replace("common/ui/zen_arrange_list", {
            show = function(opts) arrange_options = opts end,
        })
        ZenSpec.replace("common/ui/zen_icon_picker", function(_icons, current, callback)
            icon_picker_current = current
            icon_picker_callback = callback
        end)
        ZenSpec.replace("dispatcher", {
            addSubMenu = function(_self, _caller, _items, location, settings)
                if dispatcher_action then location[settings] = dispatcher_action end
            end,
            menuTextFunc = function() return dispatcher_text end,
        })
        ZenSpec.replace("apps/filemanager/filemanager", {})
        ZenSpec.replace("apps/reader/readerui", {})
        ZenSpec.unload("modules/settings/sections/menu_settings")
    end)

    it("adds multiple folders and one-tag destination buttons", function()
        local section = require("modules/settings/sections/menu_settings").build({
            config = config,
            plugin = {},
            save_and_apply = function() end,
        })
        section.sub_item_table[1].callback()
        local add_folder
        local add_tag
        for _i, item in ipairs(arrange_options.add_item_table) do
            if item.text == "Folder" then add_folder = item end
            if item.text == "Specific tag" then add_tag = item end
        end

        add_folder.callback()
        choose_folder("/library/Fiction")
        add_folder.callback()
        choose_folder("/library/Nonfiction")
        add_tag.callback()
        choose_tag("Science")

        assert.are.same({
            { id = "cb_1", type = "folder", folder = "/library/Fiction",
                label = "Fiction", label_auto = true, icon = "folder" },
            { id = "cb_2", type = "folder", folder = "/library/Nonfiction",
                label = "Nonfiction", label_auto = true, icon = "folder" },
            { id = "cb_3", type = "tag", tag = "Science",
                label = "Science", label_auto = true, icon = "tab_tags" },
        }, config.quick_settings.custom_buttons)
    end)

    it("strips the ZenOS prefix from a new action label and icon suggestion", function()
        dispatcher_action = { zen_ui_home = true }
        dispatcher_text = "ZenOS: Home"
        local section = require("modules/settings/sections/menu_settings").build({
            config = config,
            plugin = {},
            save_and_apply = function() end,
        })
        section.sub_item_table[1].callback()
        local add_action
        for _i, item in ipairs(arrange_options.add_item_table) do
            if item.text == "Action" then add_action = item; break end
        end
        local touch_menu = {
            item_table = {},
            item_table_stack = {},
            updateItems = function() end,
        }

        add_action.callback(touch_menu)
        dispatcher_update(touch_menu)

        assert.are.equal("Home", config.quick_settings.custom_buttons[1].label)
        assert.are.equal("Home", suggested_label)
    end)

    it("edits and resets the autorotate label and icon", function()
        config.quick_settings.button_order = { "gyro" }
        config.quick_settings.show_buttons.gyro = true
        local saves = 0
        local section = require("modules/settings/sections/menu_settings").build({
            config = config,
            plugin = {},
            save_and_apply = function() saves = saves + 1 end,
        })
        section.sub_item_table[1].callback()

        local autorotate
        for _i, item in ipairs(arrange_options.item_table) do
            if item.orig_item == "gyro" then autorotate = item end
        end
        local items = autorotate.sub_item_table_func()
        local touch_menu = { updateItems = function() end }

        assert.are.equal("Icon: quick_rotate", items[1].text_func())
        items[1].callback(touch_menu)
        assert.are.equal("quick_rotate", icon_picker_current)
        icon_picker_callback("atom")
        assert.are.equal("atom", config.quick_settings.gyro_icon)

        input_text = "Turn with device"
        items[2].callback(touch_menu)
        shown_widget.buttons[1][2].callback()
        assert.are.equal("Turn with device", config.quick_settings.gyro_label)
        assert.are.equal("Turn with device", autorotate.text_func())

        input_text = ""
        items[2].callback(touch_menu)
        shown_widget.buttons[1][2].callback()
        assert.are.equal("", config.quick_settings.gyro_label)
        assert.are.equal("Autorotate", autorotate.text_func())
        assert.are.equal(3, saves)
    end)

    it("configures linked Wi-Fi from the Tailscale control submenu", function()
        config.quick_settings.button_order = { "tailscale" }
        config.quick_settings.show_buttons.tailscale = true
        local saves = 0
        local section = require("modules/settings/sections/menu_settings").build({
            config = config,
            plugin = {},
            save_and_apply = function() saves = saves + 1 end,
        })
        section.sub_item_table[1].callback()

        local tailscale
        for _i, item in ipairs(arrange_options.item_table) do
            if item.orig_item == "tailscale" then tailscale = item end
        end
        local setting = tailscale.sub_item_table_func()[1]

        assert.are.equal("Tailscale \u{25B8}", tailscale.text_func())
        assert.are.equal("Toggle Wi-Fi with Tailscale", setting.text)
        assert.is_false(setting.checked_func())
        setting.callback()
        assert.is_true(setting.checked_func())
        assert.are.equal(1, saves)
    end)

    it("toggles Zen Settings outside the arranger but keeps it movable", function()
        local saves = 0
        local section = require("modules/settings/sections/menu_settings").build({
            config = config,
            plugin = {},
            save_and_apply = function() saves = saves + 1 end,
        })
        local setting
        for _i, item in ipairs(section.sub_item_table) do
            if item.text == "Show Zen Settings in Controls" then setting = item end
        end

        assert.is_table(setting)
        assert.are.equal(setting, section.sub_item_table[#section.sub_item_table - 1])
        assert.is_false(setting.checked_func())
        setting.callback()
        assert.is_true(setting.checked_func())
        assert.are.same({ "zen_settings" }, config.quick_settings.button_order)

        section.sub_item_table[1].callback()
        local movable
        for _i, item in ipairs(arrange_options.item_table) do
            if item.orig_item == "zen_settings" then movable = item end
        end
        assert.is_table(movable)
        assert.is_nil(movable.checked_func)
        assert.is_nil(movable.callback)
        assert.are.equal("Settings", movable.text_func())

        local items = movable.sub_item_table_func()
        local touch_menu = { updateItems = function() end }
        assert.are.equal(2, #items)
        assert.are.equal("Icon: zen_ui", items[1].text_func())
        items[1].callback(touch_menu)
        icon_picker_callback("atom")
        assert.are.equal("atom", config.quick_settings.zen_settings_icon)

        input_text = "Preferences"
        items[2].callback(touch_menu)
        shown_widget.buttons[1][2].callback()
        assert.are.equal("Preferences", config.quick_settings.zen_settings_label)
        assert.are.equal("Preferences", movable.text_func())

        setting.callback()
        assert.is_false(setting.checked_func())
        assert.are.equal(4, saves)
    end)

    it("edits the Launcher label and icon", function()
        config.quick_settings.button_order = { "launcher" }
        config.quick_settings.show_buttons.launcher = true
        local saves = 0
        local section = require("modules/settings/sections/menu_settings").build({
            config = config,
            plugin = {},
            save_and_apply = function() saves = saves + 1 end,
        })
        section.sub_item_table[1].callback()

        local launcher
        for _i, item in ipairs(arrange_options.item_table) do
            if item.orig_item == "launcher" then launcher = item end
        end
        assert.is_table(launcher)
        assert.are.equal("Launcher", launcher.text_func())

        local items = launcher.sub_item_table_func()
        local touch_menu = { updateItems = function() end }
        assert.are.equal(3, #items)
        assert.are.equal("Icon: app_launcher", items[1].text_func())
        items[1].callback(touch_menu)
        icon_picker_callback("grid")
        assert.are.equal("grid", config.quick_settings.launcher_icon)

        input_text = "Apps"
        items[2].callback(touch_menu)
        shown_widget.buttons[1][2].callback()
        assert.are.equal("Apps", config.quick_settings.launcher_label)
        assert.are.equal("Apps", launcher.text_func())
        assert.are.equal(2, saves)
    end)

    it("toggles background hatching", function()
        local saves = 0
        local section = require("modules/settings/sections/menu_settings").build({
            config = config,
            plugin = {},
            save_and_apply = function(feature)
                assert.are.equal("quick_settings", feature)
                saves = saves + 1
            end,
        })
        local hatching
        for _i, item in ipairs(section.sub_item_table) do
            if item.text == "Background hatching" then hatching = item end
        end

        assert.is_table(hatching)
        assert.are.equal("Background hatching", hatching.text)
        assert.is_false(hatching.checked_func())
        hatching.callback()
        assert.is_true(hatching.checked_func())
        assert.are.equal(1, saves)
    end)

    it("keeps unified controls in a submenu and restores them on reset", function()
        local device = require("device")
        device.hasFrontlight = function() return true end
        device.hasNaturalLight = function() return true end
        config.quick_settings.show_frontlight = false
        config.quick_settings.show_warmth = false
        ZenSpec.replace("ui/widget/confirmbox", {
            new = function(_self, options) return options end,
        })
        local saves = 0
        local section = require("modules/settings/sections/menu_settings").build({
            config = config,
            plugin = {},
            save_and_apply = function(feature)
                assert.are.equal("quick_settings", feature)
                saves = saves + 1
            end,
        })
        local setting, brightness, warmth, reset
        for _i, item in ipairs(section.sub_item_table) do
            if item.text == "Unified brightness/warmth slider" then setting = item end
            if item.text == "Show brightness slider" then brightness = item end
            if item.text == "Show warmth slider" then warmth = item end
            if item.text == "Reset to defaults" then reset = item end
        end
        assert.is_table(setting)
        local centered = setting.sub_item_table[1]
        assert.is_true(setting.show_func())
        assert.is_table(centered)
        assert.are.equal("Centered", centered.text)
        assert.is_true(setting.checked_func())
        assert.is_false(brightness.enabled_func())
        assert.is_false(warmth.enabled_func())
        assert.is_true(brightness.checked_func())
        assert.is_true(warmth.checked_func())
        assert.is_true(centered.enabled_func())
        assert.is_false(centered.checked_func())
        centered.callback()
        assert.is_true(centered.checked_func())
        assert.are.equal(1, saves)

        setting.checkmark_callback()
        assert.is_false(setting.checked_func())
        assert.is_true(brightness.enabled_func())
        assert.is_true(warmth.enabled_func())
        assert.is_false(brightness.checked_func())
        assert.is_false(warmth.checked_func())
        assert.is_false(centered.enabled_func())
        assert.are.equal(2, saves)

        reset.callback()
        shown_widget.ok_callback()
        assert.is_true(setting.checked_func())
        assert.is_false(brightness.enabled_func())
        assert.is_false(warmth.enabled_func())
        assert.is_true(centered.enabled_func())
        assert.is_false(centered.checked_func())
        assert.are.equal(3, saves)
    end)

    it("hides unified controls on brightness-only devices", function()
        local device = require("device")
        device.hasFrontlight = function() return true end
        device.hasNaturalLight = function() return false end
        local section = require("modules/settings/sections/menu_settings").build({
            config = config,
            plugin = {},
            save_and_apply = function() end,
        })
        local setting, brightness
        for _i, item in ipairs(section.sub_item_table) do
            if item.text == "Unified brightness/warmth slider" then setting = item end
            if item.text == "Show brightness slider" then brightness = item end
        end
        assert.is_false(setting.show_func())
        assert.is_true(brightness.enabled_func())
    end)
end)
