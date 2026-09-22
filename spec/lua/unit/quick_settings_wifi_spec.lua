describe("quick settings Wi-Fi", function()
    local original_modules
    local original_plugin
    local original_quick_settings
    local NetworkMgr
    local Device
    local UIManager
    local native_available
    local native_launches
    local transition_closes
    local switcher_calls

    local module_names = {
        "ffi/blitbuffer",
        "ffi/util",
        "ui/widget/container/centercontainer",
        "device",
        "ui/event",
        "ui/font",
        "ui/widget/container/framecontainer",
        "ui/geometry",
        "ui/widget/horizontalgroup",
        "ui/widget/horizontalspan",
        "ui/widget/iconwidget",
        "ui/network/manager",
        "ui/widget/confirmbox",
        "ui/widget/infomessage",
        "ui/widget/textwidget",
        "ui/uimanager",
        "modules/filebrowser/patches/library_font",
        "ui/widget/verticalgroup",
        "ui/widget/verticalspan",
        "common/utils",
        "common/shutdown",
        "common/restart",
        "common/shared_state",
        "common/bluetooth",
        "modules/menu/patches/brightness_slider",
        "modules/menu/patches/warmth_slider",
        "gettext",
        "dispatcher",
        "common/dispatch_action",
        "common/settings_transition",
        "modules/menu/app_launcher/native_menu",
        "modules/menu/app_launcher/plugin_scan",
        "common/plugin_root",
        "modules/menu/patches/touch_menu_panel",
        "modules/menu/network_switcher",
        "ui/widget/touchmenu",
        "apps/filemanager/filemanagermenu",
        "apps/reader/modules/readermenu",
        "apps/filemanager/filemanager",
        "apps/reader/readerui",
    }

    local function deepcopy(value)
        if type(value) ~= "table" then return value end
        local copy = {}
        for key, item in pairs(value) do
            copy[key] = deepcopy(item)
        end
        return copy
    end

    before_each(function()
        original_modules = {}
        for _i, name in ipairs(module_names) do
            original_modules[name] = package.loaded[name]
        end
        original_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        original_quick_settings = rawget(_G, "__ZEN_UI_QUICK_SETTINGS")
        native_available = true
        native_launches = {}
        transition_closes = 0
        switcher_calls = 0

        local no_op = {}
        ZenSpec.replace("ffi/blitbuffer", no_op)
        ZenSpec.replace("ffi/util", { template = function(text) return text end, strcoll = function(a, b) return a < b end })
        ZenSpec.replace("ui/widget/container/centercontainer", no_op)
        ZenSpec.replace("ui/font", no_op)
        ZenSpec.replace("ui/widget/container/framecontainer", no_op)
        ZenSpec.replace("ui/geometry", no_op)
        ZenSpec.replace("ui/widget/horizontalgroup", no_op)
        ZenSpec.replace("ui/widget/horizontalspan", no_op)
        ZenSpec.replace("ui/widget/iconwidget", no_op)
        ZenSpec.replace("ui/widget/confirmbox", no_op)
        ZenSpec.replace("ui/widget/infomessage", {
            new = function(_, options) return options end,
        })
        ZenSpec.replace("ui/widget/textwidget", no_op)
        ZenSpec.replace("modules/filebrowser/patches/library_font", no_op)
        ZenSpec.replace("ui/widget/verticalgroup", no_op)
        ZenSpec.replace("ui/widget/verticalspan", no_op)
        ZenSpec.replace("common/shutdown", no_op)
        ZenSpec.replace("common/restart", no_op)
        ZenSpec.replace("common/shared_state", { get = function() end })
        ZenSpec.replace("common/bluetooth", no_op)
        ZenSpec.replace("modules/menu/patches/brightness_slider", function() end)
        ZenSpec.replace("modules/menu/patches/warmth_slider", function() end)
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("dispatcher", no_op)
        ZenSpec.replace("common/dispatch_action", no_op)
        ZenSpec.replace("common/settings_transition", {
            close = function() transition_closes = transition_closes + 1 end,
        })
        ZenSpec.replace("modules/menu/app_launcher/native_menu", {
            exists = function(id, scope)
                return native_available and id == "network" and scope == "active"
            end,
            resolve = function(id, scope)
                if not native_available or id ~= "network" or scope ~= "active" then
                    return nil
                end
                return function()
                    native_launches[#native_launches + 1] = id .. ":" .. scope
                end
            end,
        })
        ZenSpec.replace("modules/menu/app_launcher/plugin_scan", no_op)
        ZenSpec.replace("common/plugin_root", "/tmp/zen-ui")
        ZenSpec.replace("common/utils", {
            deepcopy = deepcopy,
            resolveIcon = function() end,
            getIconPickerList = function() return {} end,
            resolveLocalIcon = function() end,
        })
        ZenSpec.replace("ui/event", { new = function(_, name) return { name = name } end })
        ZenSpec.replace("modules/menu/patches/touch_menu_panel", { install = function() end })
        ZenSpec.replace("modules/menu/network_switcher", {
            open = function(callback, settings_subpage, plugin)
                switcher_calls = switcher_calls + 1
                assert.is_function(callback)
                assert.is_false(settings_subpage)
                assert.are.equal(_G.__ZEN_UI_PLUGIN, plugin)
                return true
            end,
        })
        ZenSpec.replace("ui/widget/touchmenu", {
            init = function() end,
            switchMenuTab = function() end,
            updateItems = function() end,
            onTapCloseAllMenus = function() end,
            onHoldCloseAllMenus = function() end,
            onSetRotationMode = function() end,
        })
        ZenSpec.replace("apps/filemanager/filemanagermenu", { setUpdateItemTable = function() end })
        ZenSpec.replace("apps/reader/modules/readermenu", { setUpdateItemTable = function() end })
        ZenSpec.replace("apps/filemanager/filemanager", {})
        ZenSpec.replace("apps/reader/readerui", {})

        Device = {
            hasWifiRestore = function() return true end,
            isKindle = function() return true end,
            screen = {},
        }
        ZenSpec.replace("device", Device)

        UIManager = {
            events = {},
            scheduled = {},
            shown = {},
            broadcastEvent = function(self, event) self.events[#self.events + 1] = event end,
            show = function(self, widget) self.shown[#self.shown + 1] = widget end,
            scheduleIn = function(self, delay, callback)
                self.scheduled[#self.scheduled + 1] = { delay = delay, callback = callback }
            end,
            nextTick = function(_self, callback) callback() end,
        }
        ZenSpec.replace("ui/uimanager", UIManager)

        NetworkMgr = {
            wifi_on = false,
            connected = false,
            restore_calls = 0,
            connectivity_calls = 0,
            stock_calls = 0,
            current_ssid = nil,
            isWifiOn = function(self) return self.wifi_on end,
            isConnected = function(self) return self.connected end,
            getCurrentNetwork = function(self) return { ssid = self.current_ssid } end,
            restoreWifiAsync = function(self) self.restore_calls = self.restore_calls + 1 end,
            scheduleConnectivityCheck = function(self, callback, widget)
                self.connectivity_calls = self.connectivity_calls + 1
                self.connectivity_callback = callback
                self.connectivity_widget = widget
            end,
            getWifiMenuTable = function(self)
                return {
                    callback = function(touch_menu)
                        self.stock_calls = self.stock_calls + 1
                        self.stock_touch_menu = touch_menu
                    end,
                }
            end,
        }
        ZenSpec.replace("ui/network/manager", NetworkMgr)

        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { quick_settings = true },
                quick_settings = {
                    layout_version = 2,
                    button_order = { "wifi", "custom_1" },
                    show_buttons = { wifi = true, custom_1 = true },
                    custom_buttons = {
                        {
                            id = "custom_1",
                            type = "koreader_menu",
                            label = "Network",
                            koreader_menu = { id = "network", title = "Network" },
                        },
                    },
                    next_custom_id = 1,
                },
            },
        }
        ZenSpec.unload("modules/menu/patches/quick_settings")
        require("modules/menu/patches/quick_settings")()
    end)

    after_each(function()
        for _i, name in ipairs(module_names) do
            package.loaded[name] = original_modules[name]
        end
        ZenSpec.unload("modules/menu/patches/quick_settings")
        _G.__ZEN_UI_PLUGIN = original_plugin
        _G.__ZEN_UI_QUICK_SETTINGS = original_quick_settings
    end)

    it("restores Kindle Wi-Fi without guessing the network name", function()
        local updates = 0
        local touch_menu = {
            item_table = { panel = true },
            updateItems = function(_, page)
                assert.are.equal(1, page)
                updates = updates + 1
            end,
        }

        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.activate("wifi", touch_menu))

        assert.are.equal(1, NetworkMgr.restore_calls)
        assert.are.equal(1, NetworkMgr.connectivity_calls)
        assert.are.equal(0, NetworkMgr.stock_calls)
        assert.is_true(NetworkMgr.pending_connection)
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.isDimmed("wifi"))
        assert.is_false(_G.__ZEN_UI_QUICK_SETTINGS.isDisabled("wifi"))
        assert.is_false(_G.__ZEN_UI_QUICK_SETTINGS.isActive("wifi"))
        assert.are.equal("NetworkConnecting", UIManager.events[1].name)
        assert.are.equal("Connecting to Wi-Fi…", UIManager.shown[1].text)
        assert.are.equal(UIManager.shown[1], NetworkMgr.connectivity_widget)
        assert.are.equal(0, #UIManager.scheduled)

        NetworkMgr.wifi_on = true
        NetworkMgr.connected = true
        NetworkMgr.connectivity_callback()

        assert.are.equal(0, updates)
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.isActive("wifi"))
        assert.are.equal(1, #UIManager.scheduled)
        assert.are.equal(1, UIManager.scheduled[1].delay)

        NetworkMgr.current_ssid = "Home"
        UIManager.scheduled[1].callback()
        assert.are.equal(1, updates)
    end)

    it("keeps KOReader's normal Wi-Fi action as the fallback", function()
        Device.hasWifiRestore = function() return false end
        local touch_menu = { item_table = { panel = true }, updateItems = function() end }

        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.activate("wifi", touch_menu))

        assert.are.equal(0, NetworkMgr.restore_calls)
        assert.are.equal(1, NetworkMgr.stock_calls)
        assert.is_function(NetworkMgr.stock_touch_menu.updateItems)
    end)

    it("does not restart an active Wi-Fi connection attempt", function()
        NetworkMgr.pending_connection = true

        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.activate("wifi", {}))

        assert.are.equal(0, NetworkMgr.restore_calls)
        assert.are.equal(0, NetworkMgr.stock_calls)
    end)

    it("opens the Zen network switcher on hold", function()
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.hold("wifi", {}))
        assert.are.equal(1, switcher_calls)
        assert.are.equal(0, NetworkMgr.stock_calls)
    end)

    it("defers native menu controls and disables missing targets", function()
        local closes = 0
        local touch_menu = {
            closeMenu = function() closes = closes + 1 end,
        }

        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.has("custom_1"))
        assert.is_false(_G.__ZEN_UI_QUICK_SETTINGS.isDisabled("custom_1"))
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.activate("custom_1", touch_menu))
        assert.are.equal(1, closes)
        assert.are.equal(1, transition_closes)
        assert.are.same({ "network:active" }, native_launches)

        native_available = false
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.has("custom_1"))
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.isDisabled("custom_1"))
        assert.is_false(_G.__ZEN_UI_QUICK_SETTINGS.activate("custom_1", touch_menu))
        assert.are.same({ "network:active" }, native_launches)
    end)
end)
