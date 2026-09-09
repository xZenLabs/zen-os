describe("quick settings plugin controls", function()
    local original_modules
    local original_plugin
    local original_quick_settings
    local tailscale
    local zenfm
    local destination_entries
    local hosted_menu
    local FileManagerMenu

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
        ZenSpec.replace("ui/network/manager", {
            isWifiOn = function() return false end,
            isConnected = function() return false end,
        })
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
        ZenSpec.replace("dispatcher", { execute = function() end })
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
            onToggleZenFM = function(self)
                self.toggle_calls = self.toggle_calls + 1
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

    it("labels autorotate and resolves bundled control icons", function()
        local controls = {}
        for _i, item in ipairs(_G.__ZEN_UI_QUICK_SETTINGS.getItems()) do
            controls[item.id] = item
        end

        assert.are.equal("Autorotate", controls.gyro.label)
        assert.are.equal("/tmp/zen-ui/icons/quick_rotate.svg", controls.gyro.icon)
        assert.are.equal("/tmp/zen-ui/icons/quick_zen.svg", controls.zen.icon)
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

    it("uses the configured autorotate label and icon", function()
        local config = _G.__ZEN_UI_PLUGIN.config.quick_settings
        config.gyro_label = "Turn with device"
        config.gyro_icon = "atom"
        ZenSpec.unload("modules/menu/patches/quick_settings")
        require("modules/menu/patches/quick_settings")()

        local autorotate
        for _i, item in ipairs(_G.__ZEN_UI_QUICK_SETTINGS.getItems()) do
            if item.id == "gyro" then autorotate = item end
        end

        assert.are.equal("Turn with device", autorotate.label)
        assert.are.equal("/tmp/zen-ui/icons/atom.svg", autorotate.icon)
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
