describe("quick settings plugin controls", function()
    local original_modules
    local original_plugin
    local original_quick_settings
    local original_open_launcher
    local tailscale
    local zenfm
    local destination_entries
    local hosted_menu
    local FileManagerMenu
    local NetworkMgr
    local actions
    local dispatched_actions
    local launcher_apply_calls
    local launcher_opens
    local settings_shows
    local save_calls

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
        "ui/widget/textwidget",
        "ui/uimanager",
        "modules/filebrowser/patches/library_font",
        "ui/widget/verticalgroup",
        "ui/widget/verticalspan",
        "common/utils",
        "common/shutdown",
        "common/restart",
        "common/shared_state",
        "common/settings_transition",
        "common/ui/button_label_width",
        "common/bluetooth",
        "modules/menu/patches/brightness_slider",
        "modules/menu/patches/warmth_slider",
        "gettext",
        "dispatcher",
        "common/dispatch_action",
        "common/nav_button_model",
        "modules/menu/app_launcher/plugin_scan",
        "modules/menu/app_launcher/menu_host",
        "modules/menu/patches/app_launcher",
        "modules/settings/zen_settings_page",
        "common/plugin_root",
        "modules/menu/patches/touch_menu_panel",
        "ui/widget/touchmenu",
        "apps/filemanager/filemanagermenu",
        "apps/reader/modules/readermenu",
        "apps/filemanager/filemanager",
        "apps/reader/readerui",
        "pluginloader",
    }

    before_each(function()
        original_modules = {}
        for _i, name in ipairs(module_names) do
            original_modules[name] = package.loaded[name]
        end
        original_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        original_quick_settings = rawget(_G, "__ZEN_UI_QUICK_SETTINGS")
        original_open_launcher = rawget(_G, "__ZEN_UI_OPEN_APP_LAUNCHER")
        _G.__ZEN_UI_OPEN_APP_LAUNCHER = nil
        actions = {}
        dispatched_actions = {}
        launcher_apply_calls = 0
        launcher_opens = 0
        settings_shows = 0
        save_calls = 0

        local no_op = {}
        local function widget_class()
            local class = {}
            function class:new(values)
                local widget = values or {}
                function widget:getSize()
                    local dimen = self.dimen or {}
                    return {
                        w = self.width or dimen.w or 64,
                        h = self.height or dimen.h or 64,
                    }
                end
                function widget:_render() end
                return widget
            end
            return class
        end
        local Widget = widget_class()
        ZenSpec.replace("ffi/blitbuffer", no_op)
        ZenSpec.replace("ffi/util", { template = function(text) return text end, strcoll = function(a, b) return a < b end })
        ZenSpec.replace("ui/widget/container/centercontainer", Widget)
        ZenSpec.replace("device", {
            screen = { scaleBySize = function(_self, value) return value end },
            hasFrontlight = function() return false end,
            hasNaturalLight = function() return false end,
            hasGSensor = function() return true end,
            getPowerDevice = function() end,
        })
        ZenSpec.replace("ui/event", { new = function(_self, name) return { name = name } end })
        ZenSpec.replace("ui/font", { sizemap = { xx_smallinfofont = 18, ffont = 24 } })
        ZenSpec.replace("ui/widget/container/framecontainer", Widget)
        ZenSpec.replace("ui/geometry", Widget)
        ZenSpec.replace("ui/widget/horizontalgroup", Widget)
        ZenSpec.replace("ui/widget/horizontalspan", Widget)
        ZenSpec.replace("ui/widget/iconwidget", Widget)
        NetworkMgr = {
            wifi_on = true,
            connected = true,
            run_when_connected_calls = 0,
            toggle_on_calls = 0,
            toggle_off_calls = 0,
            isWifiOn = function(self) return self.wifi_on end,
            isConnected = function(self) return self.connected end,
            runWhenConnected = function(self, callback)
                self.run_when_connected_calls = self.run_when_connected_calls + 1
                self.connected_callback = callback
            end,
            toggleWifiOn = function(self, callback)
                self.toggle_on_calls = self.toggle_on_calls + 1
                self.wifi_on = true
                self.wifi_on_callback = callback
                actions[#actions + 1] = "wifi_on"
            end,
            toggleWifiOff = function(self, callback)
                self.toggle_off_calls = self.toggle_off_calls + 1
                self.wifi_on = false
                self.connected = false
                actions[#actions + 1] = "wifi_off"
                if callback then callback() end
            end,
        }
        ZenSpec.replace("ui/network/manager", NetworkMgr)
        ZenSpec.replace("ui/widget/confirmbox", no_op)
        ZenSpec.replace("ui/widget/textwidget", Widget)
        ZenSpec.replace("ui/uimanager", {
            broadcastEvent = function() end,
            nextTick = function(_self, callback) callback() end,
        })
        ZenSpec.replace("modules/filebrowser/patches/library_font", {
            getFace = function() return {} end,
        })
        ZenSpec.replace("ui/widget/verticalgroup", Widget)
        ZenSpec.replace("ui/widget/verticalspan", Widget)
        ZenSpec.replace("common/utils", {
            deepcopy = function(value)
                if type(value) ~= "table" then return value end
                local copy = {}
                for key, item in pairs(value) do copy[key] = item end
                return copy
            end,
            resolveLocalIcon = function(icons_dir, name)
                return icons_dir .. name .. ".svg"
            end,
            resolveIcon = function(icons_dir, name)
                return icons_dir .. name .. ".svg"
            end,
            iconOpticalScale = function() return 1 end,
            getIconPickerList = function() return {} end,
        })
        ZenSpec.replace("common/shutdown", no_op)
        ZenSpec.replace("common/restart", no_op)
        ZenSpec.replace("common/shared_state", { get = function() end })
        ZenSpec.replace("common/settings_transition", { close = function() end })
        ZenSpec.replace("common/ui/button_label_width", {
            equalCellWidth = function(width, count) return width / count end,
            maxWidth = function(width) return width end,
            SIDE_PADDING = 0,
        })
        ZenSpec.replace("common/bluetooth", {
            isAvailable = function() return false end,
        })
        ZenSpec.replace("modules/menu/patches/brightness_slider", function() end)
        ZenSpec.replace("modules/menu/patches/warmth_slider", function() end)
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("dispatcher", {
            execute = function(_self, action)
                dispatched_actions[#dispatched_actions + 1] = action
            end,
        })
        ZenSpec.replace("common/dispatch_action", no_op)
        destination_entries = {}
        hosted_menu = nil
        ZenSpec.replace("common/nav_button_model", {
            label = function(_controls, entry) return entry.label end,
            execute = function(entry)
                destination_entries[#destination_entries + 1] = entry
                return true
            end,
        })
        ZenSpec.replace("modules/menu/app_launcher/plugin_scan", no_op)
        ZenSpec.replace("modules/menu/app_launcher/menu_host", {
            show = function(options) hosted_menu = options end,
        })
        ZenSpec.replace("modules/menu/patches/app_launcher", function()
            launcher_apply_calls = launcher_apply_calls + 1
            _G.__ZEN_UI_OPEN_APP_LAUNCHER = function(touch_menu)
                launcher_opens = launcher_opens + 1
                touch_menu.opened_launcher = true
                return true
            end
        end)
        ZenSpec.replace("modules/settings/zen_settings_page", {
            show = function(plugin)
                assert.are.equal(_G.__ZEN_UI_PLUGIN, plugin)
                settings_shows = settings_shows + 1
            end,
        })
        ZenSpec.replace("common/plugin_root", "/tmp/zen-ui")
        ZenSpec.replace("modules/menu/patches/touch_menu_panel", { install = function() end })
        ZenSpec.replace("ui/widget/touchmenu", {
            init = function() end,
            switchMenuTab = function() end,
        })
        FileManagerMenu = {
            setUpdateItemTable = function(self) self.tab_item_table = {} end,
        }
        ZenSpec.replace("apps/filemanager/filemanagermenu", FileManagerMenu)
        ZenSpec.replace("apps/reader/modules/readermenu", { setUpdateItemTable = function() end })
        ZenSpec.replace("apps/filemanager/filemanager", {})
        ZenSpec.replace("apps/reader/readerui", {})

        tailscale = {
            running = false,
            toggle_calls = 0,
            isRunning = function(self) return self.running end,
            onToggleTailscale = function(self, callback)
                self.toggle_calls = self.toggle_calls + 1
                actions[#actions + 1] = self.running and "tailscale_off" or "tailscale_on"
                self.running = not self.running
                callback()
            end,
        }
        zenfm = {
            running = false,
            toggle_calls = 0,
            daemon = {
                is_android = function() return false end,
                status = function() return zenfm.running end,
            },
            onToggleZenFM = function(self, touch_menu)
                self.toggle_calls = self.toggle_calls + 1
                self.touch_menu = touch_menu
                self.running = not self.running
            end,
            settings_menu = function(self)
                return {{
                    text_func = function()
                        return "Inactivity timeout: " .. tostring(self.timeout_minutes or 30) .. " min"
                    end,
                    checked_func = function() return self.timeout_enabled == true end,
                    checkmark_callback = function()
                        self.timeout_enabled = not self.timeout_enabled
                    end,
                    callback = function() self.timeout_dialog_calls = (self.timeout_dialog_calls or 0) + 1 end,
                }}
            end,
        }
        ZenSpec.replace("pluginloader", {
            loaded_plugins = { tailscale = tailscale, zenfm = zenfm },
        })

        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { quick_settings = true },
                quick_settings = {
                    layout_version = 2,
                    button_order = { "tailscale" },
                    show_buttons = { tailscale = true, zenfm = false },
                    custom_buttons = {},
                    next_custom_id = 0,
                },
            },
            saveConfig = function() save_calls = save_calls + 1 end,
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
        _G.__ZEN_UI_OPEN_APP_LAUNCHER = original_open_launcher
    end)

    it("uses the plugin's toggle and running state", function()
        local updates = 0
        local touch_menu = {
            item_table = { panel = true },
            updateItems = function() updates = updates + 1 end,
        }

        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.has("tailscale"))
        assert.is_false(_G.__ZEN_UI_QUICK_SETTINGS.isActive("tailscale"))
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.activate("tailscale", touch_menu))
        assert.is_equal(1, tailscale.toggle_calls)
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.isActive("tailscale"))
        assert.is_equal(1, updates)
    end)

    it("prompts for Wi-Fi and waits for a connection before starting Tailscale", function()
        NetworkMgr.wifi_on = false
        NetworkMgr.connected = false

        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.activate("tailscale"))
        assert.are.equal(1, NetworkMgr.run_when_connected_calls)
        assert.are.equal(0, tailscale.toggle_calls)

        NetworkMgr.connected = true
        NetworkMgr.connected_callback()
        assert.are.same({ "tailscale_on" }, actions)
    end)

    it("turns Wi-Fi on before and off after Tailscale when linked", function()
        _G.__ZEN_UI_PLUGIN.config.quick_settings.tailscale_toggle_wifi = true
        NetworkMgr.wifi_on = false
        NetworkMgr.connected = false

        _G.__ZEN_UI_QUICK_SETTINGS.activate("tailscale")
        assert.are.same({ "wifi_on" }, actions)
        assert.are.equal(0, tailscale.toggle_calls)

        NetworkMgr.connected = true
        NetworkMgr.wifi_on_callback()
        assert.are.same({ "wifi_on", "tailscale_on" }, actions)

        _G.__ZEN_UI_QUICK_SETTINGS.activate("tailscale")
        assert.are.same({ "wifi_on", "tailscale_on", "tailscale_off", "wifi_off" }, actions)
    end)

    it("offers the off-by-default linked Wi-Fi setting without a hold action", function()
        local items = _G.__ZEN_UI_QUICK_SETTINGS.getSettingsItems("tailscale")
        assert.are.equal("Toggle Wi-Fi with Tailscale", items[1].text)
        assert.is_false(items[1].checked_func())

        items[1].callback()
        assert.is_true(items[1].checked_func())
        assert.are.equal(1, save_calls)
        assert.is_false(_G.__ZEN_UI_QUICK_SETTINGS.hold("tailscale"))
    end)

    it("labels autorotate and resolves bundled control icons", function()
        local controls = {}
        for _i, item in ipairs(_G.__ZEN_UI_QUICK_SETTINGS.getItems()) do
            controls[item.id] = item
        end

        assert.are.equal("Autorotate", controls.gyro.label)
        assert.are.equal("/tmp/zen-ui/icons/quick_rotate.svg", controls.gyro.icon)
        assert.are.equal("/tmp/zen-ui/icons/quick_zen.svg", controls.zen.icon)
        assert.are.equal("Settings", controls.zen_settings.label)
        assert.are.equal("/tmp/zen-ui/icons/zen_ui.svg", controls.zen_settings.icon)
        assert.are.equal("Launcher", controls.launcher.label)
        assert.are.equal("/tmp/zen-ui/icons/app_launcher.svg", controls.launcher.icon)
    end)

    it("renders default controls while the setup tour is pending", function()
        _G.__ZEN_UI_PLUGIN.config._meta = { quickstart_menu_tour_pending = true }
        local menu = {}
        FileManagerMenu.setUpdateItemTable(menu)
        local function rendered_ids()
            local touch_menu = { item_width = 600 }
            menu.tab_item_table[1].panel(touch_menu)
            local ids = {}
            for _i, ref in ipairs(touch_menu._zen_panel_refs.buttons) do
                ids[#ids + 1] = ref.id
            end
            return ids
        end

        assert.are.same({ "wifi", "night", "rotate", "zen", "restart", "sleep" }, rendered_ids())
        assert.are.same({ "tailscale" }, _G.__ZEN_UI_PLUGIN.config.quick_settings.button_order)

        _G.__ZEN_UI_PLUGIN.config._meta.quickstart_menu_tour_pending = false
        assert.are.same({ "tailscale" }, rendered_ids())
    end)

    it("uses configured labels and icons", function()
        local config = _G.__ZEN_UI_PLUGIN.config.quick_settings
        config.gyro_label = "Turn with device"
        config.gyro_icon = "atom"
        config.zen_settings_label = "Preferences"
        config.zen_settings_icon = "settings"
        config.launcher_label = "Apps"
        config.launcher_icon = "grid"
        ZenSpec.unload("modules/menu/patches/quick_settings")
        require("modules/menu/patches/quick_settings")()

        local autorotate, settings, launcher
        for _i, item in ipairs(_G.__ZEN_UI_QUICK_SETTINGS.getItems()) do
            if item.id == "gyro" then autorotate = item end
            if item.id == "zen_settings" then settings = item end
            if item.id == "launcher" then launcher = item end
        end

        assert.are.equal("Turn with device", autorotate.label)
        assert.are.equal("/tmp/zen-ui/icons/atom.svg", autorotate.icon)
        assert.are.equal("Preferences", settings.label)
        assert.are.equal("/tmp/zen-ui/icons/settings.svg", settings.icon)
        assert.are.equal("Apps", launcher.label)
        assert.are.equal("/tmp/zen-ui/icons/grid.svg", launcher.icon)
    end)

    it("lists and toggles ZenFM without closing the menu", function()
        local closes = 0
        local updates = 0
        local touch_menu = {
            closeMenu = function() closes = closes + 1 end,
            updateItems = function() updates = updates + 1 end,
            item_table = { panel = true },
        }
        local zenfm_item
        for _i, item in ipairs(_G.__ZEN_UI_QUICK_SETTINGS.getItems()) do
            if item.id == "zenfm" then zenfm_item = item end
        end

        assert.is_table(zenfm_item)
        assert.are.equal("/tmp/zen-ui/icons/zenfm.svg", zenfm_item.icon)
        assert.is_false(_G.__ZEN_UI_QUICK_SETTINGS.isActive("zenfm"))
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.activate("zenfm", touch_menu))
        assert.are.equal(0, closes)
        assert.are.equal(1, zenfm.toggle_calls)
        assert.are.equal(touch_menu, zenfm.touch_menu)
        assert.are.equal(1, updates)
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.isActive("zenfm"))
    end)

    it("lists ZenFM based on plugin presence without requiring its daemon API", function()
        package.loaded["pluginloader"].loaded_plugins.zenfm = {}

        local found = false
        for _i, item in ipairs(_G.__ZEN_UI_QUICK_SETTINGS.getItems()) do
            if item.id == "zenfm" then found = true end
        end

        assert.is_true(found)
    end)

    it("uses the startup plugin directory list for visibility", function()
        _G.__ZEN_UI_PLUGIN.config._meta = {
            installed_plugins = { localsend = true },
        }

        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.has("localsend"))
        assert.is_false(_G.__ZEN_UI_QUICK_SETTINGS.has("notion"))
    end)

    it("shows and dispatches Airplane mode only when its plugin is installed", function()
        _G.__ZEN_UI_PLUGIN.config._meta = { installed_plugins = {} }
        assert.is_false(_G.__ZEN_UI_QUICK_SETTINGS.has("airplanemode"))

        _G.__ZEN_UI_PLUGIN.config._meta.installed_plugins.airplanemode = true
        local closes = 0
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.activate("airplanemode", {
            closeMenu = function() closes = closes + 1 end,
            updateItems = function() end,
            item_table = { panel = true },
        }))

        assert.are.equal(1, closes)
        assert.are.same({ { airplanemode_toggle = true } }, dispatched_actions)
    end)

    it("opens Zen Settings from its control", function()
        local closes = 0
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.activate("zen_settings", {
            closeMenu = function() closes = closes + 1 end,
            updateItems = function() end,
            item_table = { panel = true },
        }))

        assert.are.equal(1, closes)
        assert.are.equal(1, settings_shows)
    end)

    it("keeps the Zen Settings control inert when Lockdown disables settings", function()
        _G.__ZEN_UI_PLUGIN.config.lockdown = { disable_settings_panel = true }
        _G.__ZEN_UI_PLUGIN.config.features.lockdown_mode = true

        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.isDisabled("zen_settings"))
        assert.is_false(_G.__ZEN_UI_QUICK_SETTINGS.activate("zen_settings"))
        assert.are.equal(0, settings_shows)
    end)

    it("opens Launcher inside Controls even when its patch was not loaded", function()
        local touch_menu = {
            closeMenu = function() error("Launcher should remain inside Controls") end,
            updateItems = function() end,
            item_table = { panel = true },
        }

        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.activate("launcher", touch_menu))
        assert.are.equal(1, launcher_apply_calls)
        assert.are.equal(1, launcher_opens)
        assert.is_true(touch_menu.opened_launcher)
    end)

    it("opens ZenFM settings on hold with a toggle and timeout submenu", function()
        local closes = 0
        local touch_menu = {
            closeMenu = function() closes = closes + 1 end,
        }

        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.hold("zenfm", touch_menu))
        assert.are.equal(1, closes)
        assert.are.equal("ZenFM", hosted_menu.title)
        assert.is_false(hosted_menu.back_visible)

        local timeout = hosted_menu.item_table[1]
        assert.is_function(timeout.checked_func)
        assert.is_function(timeout.callback)
        assert.is_nil(timeout.sub_item_table)
        assert.is_function(timeout.sub_item_table_func)

        timeout.callback()
        assert.is_true(zenfm.timeout_enabled)
        assert.are.same({}, timeout.sub_item_table_func())
        assert.are.equal(1, zenfm.timeout_dialog_calls)
    end)

    it("closes the menu before toggling Zen mode", function()
        local calls = {}
        _G.__ZEN_UI_PLUGIN.onToggleZenMode = function()
            calls[#calls + 1] = "toggle"
        end
        local touch_menu = {
            closeMenu = function() calls[#calls + 1] = "close" end,
            updateItems = function() end,
            item_table = { panel = true },
        }

        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.activate("zen", touch_menu))
        assert.are.same({ "close", "toggle" }, calls)
    end)

    it("runs independently configured folder and tag destination buttons", function()
        local config = _G.__ZEN_UI_PLUGIN.config.quick_settings
        config.custom_buttons = {
            { id = "cb_1", type = "folder", folder = "/library/Fiction",
                label = "Fiction", icon = "tab_folder" },
            { id = "cb_2", type = "folder", folder = "/library/Nonfiction",
                label = "Nonfiction", icon = "tab_folder" },
            { id = "cb_3", type = "tag", tag = "Science",
                label = "Science", icon = "tab_tags" },
        }
        local closes = 0
        local touch_menu = {
            closeMenu = function() closes = closes + 1 end,
            updateItems = function() end,
            item_table = { panel = true },
        }

        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.activate("cb_1", touch_menu))
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.activate("cb_2", touch_menu))
        assert.is_true(_G.__ZEN_UI_QUICK_SETTINGS.activate("cb_3", touch_menu))

        assert.are.equal(3, closes)
        assert.are.same(config.custom_buttons, destination_entries)
    end)
end)
