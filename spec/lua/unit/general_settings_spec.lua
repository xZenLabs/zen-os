describe("General settings", function()
    local wifi_on, bluetooth_available, bluetooth_on, bluetooth_cached
    local toggle_wifi, open_wifi, open_bluetooth, bluetooth_toggles, events, shown

    before_each(function()
        wifi_on, bluetooth_available, bluetooth_on, bluetooth_cached = false, false, false, nil
        toggle_wifi, open_wifi, open_bluetooth, bluetooth_toggles, events = nil, nil, nil, 0, 0
        shown = nil
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/network/manager", { isWifiOn = function() return wifi_on end })
        ZenSpec.replace("modules/menu/network_switcher", {
            toggleWifi = function(...) toggle_wifi = { ... } end,
            open = function(...) open_wifi = { ... } end,
        })
        ZenSpec.replace("modules/menu/bluetooth/bluetooth", {
            isAvailable = function() return bluetooth_available end,
            getCachedState = function() return bluetooth_cached end,
            isEnabled = function() return bluetooth_on end,
            toggle = function(callback)
                bluetooth_toggles = bluetooth_toggles + 1
                bluetooth_on = not bluetooth_on
                bluetooth_cached = bluetooth_on
                callback(true)
            end,
        })
        ZenSpec.replace("modules/menu/bluetooth_switcher", {
            open = function(...) open_bluetooth = { ... } end,
        })
        ZenSpec.replace("ui/event", { new = function(_self, name) return name end })
        ZenSpec.replace("ui/uimanager", {
            broadcastEvent = function(_self, event) events = events + 1 end,
            show = function(_self, widget) shown = widget end,
        })
        ZenSpec.replace("ui/widget/infomessage", { new = function(_self, spec) return spec end })
        ZenSpec.replace("modules/settings/sections/advanced_settings", {
            build = function() return {{ text = "Advanced option" }} end,
        })
        ZenSpec.replace("modules/settings/sections/updates_settings", {
            build = function() return {{ text = "Update option" }} end,
        })
        ZenSpec.replace("modules/settings/battery_stats_menu", { buildItems = function() return {} end })
        ZenSpec.replace("ui/language", {
            getLangMenuTable = function() return { text = "Language", sub_item_table = {} } end,
        })
        ZenSpec.replace("ui/elements/common_settings_menu_table", {
            time = { text = "Time and date" },
        })
        ZenSpec.replace("common/inline_icon_map", setmetatable({}, {
            __index = function(_self, key) return key end,
        }))
        ZenSpec.replace("common/ui/icon_menu_item", {
            decorate = function(item, icon) item.icon_glyph = icon; return item end,
        })
        ZenSpec.unload("modules/settings/sections/general_settings")
    end)

    after_each(function()
        ZenSpec.unload("modules/settings/sections/general_settings")
    end)

    it("builds General in menu order and takes schedules and sleep from Extras", function()
        local extras = {
            { text = "Zen Search" }, { text = "Schedules" }, { text = "Sleep" },
        }
        local items = require("modules/settings/sections/general_settings").build({ plugin = {} }, extras)
        local labels = {}
        for _i, item in ipairs(items) do labels[#labels + 1] = item.text end
        assert.are.same({ "Wi-Fi", "Schedules", "Sleep", "Battery", "Language", "Time and date", "Advanced", "Updates" }, labels)
        assert.are.same({ "Zen Search" }, { extras[1].text })
        assert.are.equal(1, #extras)
        assert.are.equal("wifi_on", items[1].icon_glyph)
        assert.are.equal("Advanced option", items[7].sub_item_table[1].text)
        assert.are.equal("Update option", items[8].sub_item_table[1].text)
    end)

    it("opens Wi-Fi management and refreshes after a power change", function()
        local plugin = {}
        local items = require("modules/settings/sections/general_settings").build({ plugin = plugin }, {})
        local wifi = items[1]
        local menu = { updateItems = function() end }
        local updates, status_refreshes = 0, 0
        menu.updateItems = function() updates = updates + 1 end
        menu._zen_status_refresh = function() status_refreshes = status_refreshes + 1 end
        assert.is_false(wifi.checked_func())
        assert.is_true(wifi._zen_settings_submenu)
        wifi.checkmark_callback(menu)
        assert.is_function(toggle_wifi[1].updateItems)
        assert.is_true(toggle_wifi[3])
        assert.are.equal(plugin, toggle_wifi[4])
        toggle_wifi[1]:updateItems()
        assert.are.same({ 1, 1 }, { updates, status_refreshes })
        wifi_on = true
        assert.is_true(wifi.checked_func())
        wifi.callback()
        assert.are.equal(plugin, open_wifi[3])
        assert.is_true(open_wifi[2])
    end)

    it("keeps the Settings context when Kindle reconnect needs network selection", function()
        local original_device = package.loaded["device"]
        local original_adapter = package.loaded["modules/menu/network_adapters/kindle"]
        local original_network_setting = package.loaded["ui/widget/networksetting"]
        local switcher_stub = package.loaded["modules/menu/network_switcher"]
        ZenSpec.replace("device", {})
        ZenSpec.replace("modules/menu/network_adapters/kindle", {
            isSupported = function() return true end,
        })
        local NetworkSetting = {}
        ZenSpec.replace("ui/widget/networksetting", NetworkSetting)
        local UIManager = require("ui/uimanager")
        UIManager.topdown_widgets_iter = function()
            local widget = shown
            return function()
                local current = widget
                widget = nil
                return current
            end
        end
        UIManager.nextTick = function(_self, callback) callback() end
        UIManager.close = function() shown = nil end
        package.loaded["ui/network/manager"].toggleWifiOn = function()
            wifi_on = true
            UIManager:show(setmetatable({}, NetworkSetting))
        end
        ZenSpec.unload("modules/menu/network_switcher")
        local switcher = require("modules/menu/network_switcher")
        local opened
        switcher.open = function(callback, subpage, plugin)
            opened = { callback, subpage, plugin }
            return true
        end
        local plugin = {}
        local wifi = require("modules/settings/sections/general_settings").build({ plugin = plugin }, {})[1]
        wifi.checkmark_callback({ updateItems = function() end })
        assert.is_function(opened[1])
        assert.is_true(opened[2])
        assert.are.equal(plugin, opened[3])
        ZenSpec.replace("modules/menu/network_switcher", switcher_stub)
        package.loaded["modules/menu/network_adapters/kindle"] = original_adapter
        package.loaded["ui/widget/networksetting"] = original_network_setting
        package.loaded["device"] = original_device
    end)

    it("shows Bluetooth only when available and keeps its power control", function()
        bluetooth_available = true
        local plugin = {}
        local items = require("modules/settings/sections/general_settings").build({ plugin = plugin }, {})
        local bluetooth = items[2]
        assert.are.equal("Bluetooth", bluetooth.text)
        assert.are.equal("bluetooth_on", bluetooth.icon_glyph)
        assert.is_false(bluetooth.checked_func())
        local updates = 0
        bluetooth.checkmark_callback({ updateItems = function() updates = updates + 1 end })
        assert.is_true(bluetooth.checked_func())
        assert.are.same({ 1, 1, 1 }, { bluetooth_toggles, updates, events })
        bluetooth.checkmark_callback({ updateItems = function() updates = updates + 1 end })
        bluetooth_on = true
        assert.is_false(bluetooth.checked_func())
        assert.are.same({ 2, 2, 2 }, { bluetooth_toggles, updates, events })
        package.loaded["modules/menu/bluetooth/bluetooth"].toggle = function(callback)
            callback(false, "Bluetooth power did not change.")
        end
        bluetooth.checkmark_callback({ updateItems = function() updates = updates + 1 end })
        assert.are.equal("Bluetooth power did not change.", shown.text)
        assert.are.same({ 2, 3, 2 }, { bluetooth_toggles, updates, events })
        bluetooth.callback()
        assert.is_true(open_bluetooth[2])
        assert.are.equal(plugin, open_bluetooth[3])
    end)
end)
