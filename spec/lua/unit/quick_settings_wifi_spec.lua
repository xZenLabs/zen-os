describe("quick settings Wi-Fi", function()
    local original_modules
    local original_plugin
    local original_quick_settings
    local original_settings
    local NetworkMgr
    local Device
    local UIManager
    local native_available
    local native_launches
    local transition_closes
    local switcher_calls
    local toggle_calls
    local bluetooth_changing

    local module_names = {
        "ffi/blitbuffer",
        "ffi/util",
        "ui/widget/container/centercontainer",
        "device",
        "device/devicelistener",
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
        "ui/widget/notification",
        "ui/widget/textwidget",
        "ui/uimanager",
        "modules/filebrowser/patches/library_font",
        "ui/widget/verticalgroup",
        "ui/widget/verticalspan",
        "common/utils",
        "common/shutdown",
        "common/restart",
        "common/shared_state",
        "modules/menu/bluetooth/bluetooth",
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
        "modules/menu/bluetooth_switcher",
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
        original_settings = G_reader_settings
        native_available = true
        native_launches = {}
        transition_closes = 0
        switcher_calls = 0
        toggle_calls = 0
        bluetooth_changing = false

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
        ZenSpec.replace("modules/menu/bluetooth/bluetooth", {
            isChanging = function() return bluetooth_changing end,
        })
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
            toggleWifi = function(touch_menu, callback, settings_subpage, plugin)
                toggle_calls = toggle_calls + 1
                assert.is_function(touch_menu.updateItems)
                assert.is_function(callback)
                assert.is_false(settings_subpage)
                assert.are.equal(_G.__ZEN_UI_PLUGIN, plugin)
                NetworkMgr.toggle_callback = callback
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
            isKindle = function() return true end,
            screen = {},
        }
        ZenSpec.replace("device", Device)

        UIManager = {
            scheduled = {},
            shown = {},
            broadcastEvent = function() end,
            show = function(self, widget) self.shown[#self.shown + 1] = widget end,
            scheduleIn = function(self, delay, callback)
                self.scheduled[#self.scheduled + 1] = { delay = delay, callback = callback }
            end,
            unschedule = function(self, callback)
                for index = #self.scheduled, 1, -1 do
                    if self.scheduled[index].callback == callback then table.remove(self.scheduled, index) end
                end
            end,
            nextTick = function(_self, callback) callback() end,
        }
        ZenSpec.replace("ui/uimanager", UIManager)

        NetworkMgr = {
            wifi_on = false,
            connected = false,
            current_ssid = nil,
            isWifiOn = function(self) return self.wifi_on end,
            isConnected = function(self) return self.connected end,
            getCurrentNetwork = function(self) return { ssid = self.current_ssid } end,
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
        _G.G_reader_settings = original_settings
    end)

    it("refreshes reader highlight colors and document caches when toggling night mode", function()
        _G.G_reader_settings = ZenSpec.memorySettings()
        ZenSpec.replace("ui/widget/notification", {})
        ZenSpec.unload("device/devicelistener")
        Device.hasFrontlight = function() return false end
        Device.hasGSensor = function() return false end
        Device.isAlwaysFullscreen = function() return true end
        local resets, selections, updates = 0, 0, 0
        local listener = require("device/devicelistener"):new{ ui = {
            document = { provider = "crengine", resetCallCache = function() resets = resets + 1 end },
            highlight = { setSelectionColor = function() selections = selections + 1 end },
        } }
        Device.screen.toggleNightMode = function(self) self.night_mode = not self.night_mode end
        UIManager.broadcastEvent = function(_self, event)
            assert.are.equal("ToggleNightMode", event.name)
            listener:onToggleNightMode()
        end
        UIManager.ToggleNightMode = function() end
        UIManager.setDirty = function() end
        local menu = { updateItems = function() updates = updates + 1 end }
        for i, night in ipairs({ true, false }) do
            assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.activate("night", menu))
            assert.are.equal(night, Device.screen.night_mode)
            assert.are.equal(night, G_reader_settings:isTrue("night_mode"))
            assert.are.equal(i, resets)
            assert.are.equal(i, selections)
            assert.are.equal(i, updates)
        end
    end)

    it("routes a Kindle Wi-Fi tap through the shared toggle", function()
        local updates = 0
        local touch_menu = {
            item_table = { panel = true },
            _zen_panel_refs = {},
            updateItems = function(_, page)
                assert.are.equal(1, page)
                updates = updates + 1
            end,
        }

        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.activate("wifi", touch_menu))

        assert.are.equal(1, toggle_calls)
        assert.is_false(_G.__ZEN_UI_QUICK_SETTINGS.isDimmed("wifi"))
        assert.are.equal(0, #UIManager.shown)
        assert.are.equal(0, #UIManager.scheduled)

        NetworkMgr.wifi_on = true
        NetworkMgr.connected = true
        NetworkMgr.toggle_callback()

        assert.are.equal(1, updates)
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.isActive("wifi"))
        assert.are.equal(1, #UIManager.scheduled)
        assert.are.equal(2, UIManager.scheduled[1].delay)

        NetworkMgr.current_ssid = "Home"
        UIManager.scheduled[1].callback()
        assert.are.equal(2, updates)
    end)

    it("keeps one SSID poll chain when the toggle refreshes twice", function()
        local updates = 0
        local touch_menu = {
            item_table = { panel = true },
            _zen_panel_refs = {},
            updateItems = function() updates = updates + 1 end,
        }
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.activate("wifi", touch_menu))
        NetworkMgr.wifi_on, NetworkMgr.connected = true, true
        NetworkMgr.toggle_callback()
        NetworkMgr.toggle_callback()
        assert.are.equal(2, updates)
        assert.are.equal(1, #UIManager.scheduled)
        table.remove(UIManager.scheduled, 1).callback()
        assert.are.equal(2, updates)
        assert.are.equal(1, #UIManager.scheduled)
        NetworkMgr.current_ssid = "Home"
        table.remove(UIManager.scheduled, 1).callback()
        assert.are.equal(3, updates)
        assert.are.equal(0, #UIManager.scheduled)
    end)

    it("rebuilds custom control definitions only when their config changes", function()
        local Dispatcher = package.loaded["dispatcher"]
        local labels = 0
        Dispatcher.menuTextFunc = function() labels = labels + 1; return "Action" end
        local buttons = _G.__ZEN_UI_PLUGIN.config.quick_settings.custom_buttons
        buttons[#buttons + 1] = { id = "cb_2", type = "action", action = { toggle_a = true } }
        for _j = 1, 3 do assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.has("cb_2")) end
        assert.are.equal(1, labels)
        buttons[#buttons].action = { toggle_b = true }
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.has("cb_2"))
        assert.are.equal(2, labels)
        package.loaded["ui/widget/touchmenu"].init({})
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.has("cb_2"))
        assert.are.equal(3, labels)
    end)

    it("reads cached Bluetooth state for the Controls tile", function()
        local Bluetooth = package.loaded["modules/menu/bluetooth/bluetooth"]
        local cached, live = true, 0
        Bluetooth.getCachedState = function() return cached end
        Bluetooth.isEnabled = function() live = live + 1; return false end
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.isActive("bluetooth"))
        assert.are.equal(0, live)
        cached = nil
        assert.is_false(_G.__ZEN_UI_QUICK_SETTINGS.isActive("bluetooth"))
        assert.are.equal(1, live)
    end)

    for _i, connected in ipairs({ false, true }) do
        it("does not query stalled Wi-Fi or refresh closed Controls with connected=" .. tostring(connected), function()
            NetworkMgr.wifi_on, NetworkMgr.connected = true, connected
            NetworkMgr.isWifiChanging = function() return connected end
            NetworkMgr.getCurrentNetwork = function() error("UI must not query stalled Wi-Fi") end
            local updates = 0
            local touch_menu = {
                item_table = { panel = true },
                _zen_panel_refs = {},
                updateItems = function() updates = updates + 1 end,
            }
            assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.activate("wifi", touch_menu))
            NetworkMgr.toggle_callback()
            assert.are.equal(1, updates)
            local pending = table.remove(UIManager.scheduled, 1)
            assert.is_truthy(pending)
            touch_menu._zen_panel_refs = nil
            pending.callback()
            assert.are.equal(1, updates)
            assert.are.equal(0, #UIManager.scheduled)
        end)
    end

    it("dims both radios during a toggle even while their old state is on", function()
        local Bluetooth = package.loaded["modules/menu/bluetooth/bluetooth"]
        local changing = true
        bluetooth_changing = true
        Bluetooth.isEnabled = function() return true end
        NetworkMgr.wifi_on, NetworkMgr.connected = true, true
        NetworkMgr.isWifiChanging = function() return changing end

        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.isDimmed("wifi"))
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.isDimmed("bluetooth"))
        assert.is_false(_G.__ZEN_UI_QUICK_SETTINGS.isDisabled("wifi"))
        assert.is_false(_G.__ZEN_UI_QUICK_SETTINGS.isDisabled("bluetooth"))

        local updates = 0
        local touch_menu = setmetatable({
            item_table = { panel = true },
            updateItems = function() updates = updates + 1 end,
        }, { __index = package.loaded["ui/widget/touchmenu"] })
        touch_menu:onNetworkStateChanged()
        touch_menu:onBluetoothStateChanged()
        assert.are.equal(2, updates)
        changing = false
        bluetooth_changing = false
        assert.is_false(_G.__ZEN_UI_QUICK_SETTINGS.isDimmed("wifi"))
        assert.is_false(_G.__ZEN_UI_QUICK_SETTINGS.isDimmed("bluetooth"))

        NetworkMgr.connected = false
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.isDimmed("wifi"))
        assert.is_false(_G.__ZEN_UI_QUICK_SETTINGS.isDisabled("wifi"))
        touch_menu:onNetworkDisconnected()
        assert.are.equal(3, updates)
        NetworkMgr.wifi_on = false
        assert.is_false(_G.__ZEN_UI_QUICK_SETTINGS.isDimmed("wifi"))
        NetworkMgr.wifi_on, NetworkMgr.connected = true, true
        touch_menu:onNetworkConnected()
        assert.are.equal(4, updates)
        assert.is_false(_G.__ZEN_UI_QUICK_SETTINGS.isDimmed("wifi"))
    end)

    it("keeps Bluetooth tap as power control and opens the manager on hold", function()
        local toggles, opens, updates = 0, 0, 0
        package.loaded["modules/menu/bluetooth/bluetooth"].toggle = function(callback)
            toggles = toggles + 1
            callback(true)
            return true
        end
        ZenSpec.replace("modules/menu/bluetooth_switcher", { open = function(callback, subpage)
            opens = opens + 1
            assert.is_false(subpage)
            callback()
            return true
        end })
        local touch_menu = {
            item_table = { panel = true },
            updateItems = function() updates = updates + 1 end,
        }
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.activate("bluetooth", touch_menu))
        assert.are.equal(1, toggles)
        assert.are.equal(0, opens)
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.hold("bluetooth", touch_menu))
        assert.are.equal(1, opens)
        assert.are.equal(2, updates)

        package.loaded["modules/menu/bluetooth/bluetooth"].toggle = function(callback)
            callback(false, "Bluetooth power did not change.")
        end
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.activate("bluetooth", touch_menu))
        assert.are.equal("Bluetooth power did not change.", UIManager.shown[#UIManager.shown].text)
        assert.are.equal(3, updates)
    end)

    it("routes taps during on-demand Wi-Fi restores through the shared toggle", function()
        NetworkMgr.pending_connection = true
        NetworkMgr.pending_connectivity_check = true

        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.isDimmed("wifi"))
        assert.is_false(_G.__ZEN_UI_QUICK_SETTINGS.isDisabled("wifi"))
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.activate("wifi", {}))

        assert.are.equal(1, toggle_calls)
    end)

    it("opens the Zen network switcher on hold", function()
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.hold("wifi", {}))
        assert.are.equal(1, switcher_calls)
        assert.are.equal(0, toggle_calls)
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
