describe("About settings", function()
    local quickstart_spec
    local scheduled
    local time_setting
    local tour_starts
    local network_opens
    local network_plugin
    local network_settings_subpage
    local kindle_restore_callback
    local kindle_restore_calls
    local wifi_on
    local wifi_toggle_menu

    before_each(function()
        quickstart_spec = nil
        scheduled = {}
        time_setting = { text = "Time and date", sub_item_table = {} }
        tour_starts = 0
        network_opens = 0
        network_plugin = nil
        network_settings_subpage = nil
        kindle_restore_callback = nil
        kindle_restore_calls = 0
        wifi_on = false
        wifi_toggle_menu = nil

        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ffi/util", {
            template = function(text, value)
                return text:gsub("%%1", tostring(value))
            end,
        })
        ZenSpec.replace("ui/uimanager", {
            show = function(_self, widget) quickstart_spec = widget end,
            nextTick = function(_self, callback) callback() end,
            scheduleIn = function(_self, delay, callback)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end,
        })
        ZenSpec.replace("modules/settings/zen_settings_utils", {
            get_plugin_version = function() return "1.0.0" end,
            get_koreader_version = function() return "2026.08" end,
            get_device_model_name = function() return "Test device" end,
            get_device_firmware_display = function() return "Test firmware" end,
            get_device_ip_address = function() return nil end,
        })
        ZenSpec.replace("modules/settings/zen_bugreporter", {
            show_dialog = function() end,
        })
        ZenSpec.replace("modules/settings/sections/advanced_settings", {
            build = function() return {} end,
        })
        ZenSpec.replace("modules/menu/network_switcher", {
            open = function(_on_connected, settings_subpage, plugin)
                network_opens = network_opens + 1
                network_plugin = plugin
                network_settings_subpage = settings_subpage
            end,
        })
        ZenSpec.replace("modules/menu/network_adapters/kindle", {
            restoreWifi = function(_network_mgr, callback)
                kindle_restore_calls = kindle_restore_calls + 1
                kindle_restore_callback = callback
                return not wifi_on
            end,
        })
        ZenSpec.replace("ui/network/manager", {
            isWifiOn = function() return wifi_on end,
            getWifiMenuTable = function()
                return {
                    callback = function(touch_menu)
                        wifi_toggle_menu = touch_menu
                    end,
                }
            end,
        })
        ZenSpec.replace("ui/elements/common_settings_menu_table", {
            time = time_setting,
        })
        ZenSpec.replace("common/inline_icon_map", setmetatable({}, {
            __index = function(_self, key) return key end,
        }))
        ZenSpec.replace("common/ui/icon_menu_item", {
            decorate = function() end,
        })
        ZenSpec.replace("common/quickstart/quickstart_screen", {
            new = function(_self, spec) return spec end,
        })
        ZenSpec.replace("common/quickstart/quickstart_pages", {
            build_install_pages = function() return { { title = "Setup" } } end,
        })
        ZenSpec.replace("common/quickstart/menu_tour", {
            start = function() tour_starts = tour_starts + 1 end,
        })
        ZenSpec.replace("apps/filemanager/filemanager", {})
        ZenSpec.unload("modules/settings/sections/about_settings")
    end)

    after_each(function()
        ZenSpec.unload("modules/settings/sections/about_settings")
    end)

    it("starts the menu coach after a manually launched Setup Guide closes", function()
        local config = { _meta = {} }
        local saves = 0
        local plugin = {
            saveConfig = function() saves = saves + 1 end,
        }
        local items = require("modules/settings/sections/about_settings").build({
            config = config,
            plugin = plugin,
        })

        items[4].callback()
        assert.is_table(quickstart_spec)
        quickstart_spec.on_close()

        assert.is_true(config._meta.quickstart_completed)
        assert.is_true(config._meta.quickstart_menu_tour_pending)
        assert.is_true(config._meta.quickstart_reader_tour_pending)
        assert.are.equal(1, saves)
        assert.are.equal(1, #scheduled)
        assert.are.equal(0.35, scheduled[1].delay)

        scheduled[1].callback()
        assert.are.equal(1, tour_starts)
    end)

    it("puts language and KOReader's time and date menu at the bottom of Device", function()
        local items = require("modules/settings/sections/about_settings").build({
            config = {},
            plugin = {},
        })

        local device_items = items[3].sub_item_table
        assert.are.equal("Language", device_items[#device_items - 1].text)
        assert.are.equal(time_setting, device_items[#device_items])
    end)

    it("opens the network switcher", function()
        local plugin = {}
        local items = require("modules/settings/sections/about_settings").build({
            config = {},
            plugin = plugin,
        })

        assert.are.equal("Wi-Fi", items[2].text)
        assert.is_true(items[2].keep_menu_open)
        assert.is_true(items[2]._zen_settings_submenu)
        assert.is_false(items[2].checked_func())
        local updates = 0
        local status_refreshes = 0
        local touch_menu = {
            updateItems = function() updates = updates + 1 end,
            _zen_status_refresh = function() status_refreshes = status_refreshes + 1 end,
        }
        items[2].checkmark_callback(touch_menu)
        assert.are.equal(1, kindle_restore_calls)
        assert.is_function(kindle_restore_callback)
        assert.is_nil(wifi_toggle_menu)
        kindle_restore_callback()
        assert.are.equal(1, updates)
        assert.are.equal(1, status_refreshes)
        wifi_on = true
        assert.is_true(items[2].checked_func())
        items[2].checkmark_callback(touch_menu)
        assert.are.equal(touch_menu, wifi_toggle_menu)
        items[2].callback()
        assert.are.equal(1, network_opens)
        assert.are.equal(plugin, network_plugin)
        assert.is_true(network_settings_subpage)
    end)
end)
