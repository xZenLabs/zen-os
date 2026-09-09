local function apply_quick_settings()
    -- Quick settings tab (Wi-Fi, action buttons, sliders) for FileManager and Reader.
    -- Optional external plugin buttons: NotionSync (CezaryPukownik/notionsync.koplugin),
    -- Reading Streak (advokatb/readingstreak.koplugin), OPDS Catalog (built-in KOReader).

    local Blitbuffer = require("ffi/blitbuffer")
    local ffiUtil = require("ffi/util")
    local T = ffiUtil.template
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Device = require("device")
    local Event = require("ui/event")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Geom = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local IconWidget = require("ui/widget/iconwidget")
    local NetworkMgr = require("ui/network/manager")
    local ConfirmBox = require("ui/widget/confirmbox")
    local TextWidget = require("ui/widget/textwidget")
    local UIManager = require("ui/uimanager")
    local library_font = require("modules/filebrowser/patches/library_font")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local utils = require("common/utils")
    local shutdown = require("common/shutdown")
    local restart = require("common/restart")
    local SharedState = require("common/shared_state")
    local SettingsTransition = require("common/settings_transition")
    local ButtonLabelWidth = require("common/ui/button_label_width")
    local Bluetooth = require("common/bluetooth")
    local build_brightness_slider = require("modules/menu/patches/brightness_slider")
    local build_warmth_slider     = require("modules/menu/patches/warmth_slider")
    local _ = require("gettext")
    local Screen = Device.screen
    local Dispatcher = require("dispatcher")
    local DispatchAction = require("common/dispatch_action")
    local ButtonModel = require("common/nav_button_model")
    local NativeMenu = require("modules/menu/app_launcher/native_menu")
    local PluginScan = require("modules/menu/app_launcher/plugin_scan")

    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    if not zen_plugin or type(zen_plugin.config) ~= "table" then
        return
    end
    require("modules/menu/patches/touch_menu_panel").install(zen_plugin)

    local function get_shared(key)
        return SharedState.get(zen_plugin, key)
    end

    -- Resolve plugin icons/ dir from this file's path at apply-time.
    local _plugin_root
    local _icons_dir
    do
        _plugin_root = require("common/plugin_root")
        if _plugin_root then _icons_dir = _plugin_root .. "/icons/" end
    end

    local function is_enabled()
        local features = zen_plugin.config and zen_plugin.config.features
        return type(features) == "table" and features.quick_settings == true
    end

    local function getQuickSettingsTabIndex(touch_menu)
        local tab_table = touch_menu and touch_menu.tab_item_table
        if type(tab_table) ~= "table" then return 1 end
        for i, tab in ipairs(tab_table) do
            if tab.id == "quicksettings" then
                return i
            end
        end
        return 1
    end

    local function getLauncherTabIndex(touch_menu)
        for i, tab in ipairs((touch_menu and touch_menu.tab_item_table) or {}) do
            if tab.id == "app_launcher" then return i end
        end
    end

    local function launcher_opens_first()
        local features = zen_plugin.config and zen_plugin.config.features
        if type(features) ~= "table" or features.app_launcher ~= true then return false end
        local ok, Model = pcall(require, "modules/menu/app_launcher/model")
        return ok and Model.ensure().open_first == true
    end

    -- ============================================================
    -- Configuration
    -- ============================================================

    local config_default = {
        button_order = { "wifi", "night", "rotate", "zen", "restart", "sleep" },
        show_buttons = {
            wifi = true,
            bluetooth = false,
            night = true,
            frontlight = false,
            gyro = false,
            rotate = true,
            zen = true,
            lockdown = false,
            incognito = false,
            search = false,
            usb = false,
            quickrss = false,
            cloud = false,
            zlibrary = false,
            calibre = false,
            calibre_search = false,
            restart = true,
            exit = true,
            sleep = true,
            -- External plugin buttons (disabled by default; enable if plugin is installed)
            notion = false,
            streak = false,
            opds = false,
            filebrowser = false,
            tailscale = false,
            zenfm = false,
            puzzle = false,
            crossword = false,
            connections = false,
            stats_progress = false,
            stats_calendar = false,
            battery_stats = false,
            kosync = false,
            chess = false,
            casualchess = false,
            localsend = false,
            screenshot = false,
        },
        show_labels = true,
        show_frontlight = true,
        show_warmth = true,
        gyro_label = "",
        gyro_icon = "quick_rotate",
        rotate_action = "cycle",
        screenshot_timer_seconds = 3,
        custom_buttons = {},  -- array of { id, label, icon, action }
        next_custom_id = 0,
        layout_version = 2,
    }

    local filebrowser_slots = { "filebrowser", "FilebrowserPlus", "filebrowserplus" }
    local filebrowserplus_slots = { "FilebrowserPlus", "filebrowserplus" }

    local config

    local function loadConfig()
        config = zen_plugin.config.quick_settings or {}
        local legacy_layout = config.layout_version ~= 2
        for k, v in pairs(config_default) do
            if config[k] == nil then
                config[k] = utils.deepcopy(v)
            end
        end
        if type(config.show_buttons) == "table" then
            -- Track which buttons are being set for the first time (nil = never explicitly stored)
            local first_time = {}
            for k, v in pairs(config_default.show_buttons) do
                if config.show_buttons[k] == nil then
                    first_time[k] = true
                    config.show_buttons[k] = v
                end
            end
            -- Auto-enable plugin-dependent buttons on first run if the plugin is installed
            local function autoEnable(key, slots)
                if first_time[key] then
                    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
                    local ok_ru, ReaderUI    = pcall(require, "apps/reader/readerui")
                    local ui = (ok_fm and FileManager.instance) or (ok_ru and ReaderUI.instance)
                    if ui then
                        for _i, slot in ipairs(slots) do
                            if ui[slot] then
                                config.show_buttons[key] = true
                                break
                            end
                        end
                    end
                end
            end
            autoEnable("filebrowser", filebrowser_slots)
        else
            config.show_buttons = utils.deepcopy(config_default.show_buttons)
            -- Auto-enable plugin-dependent buttons on first ever config creation
            local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
            local ok_ru, ReaderUI    = pcall(require, "apps/reader/readerui")
            local ui = (ok_fm and FileManager.instance) or (ok_ru and ReaderUI.instance)
            if ui then
                for _i, slot in ipairs(filebrowser_slots) do
                    if ui[slot] then
                        config.show_buttons.filebrowser = true
                        break
                    end
                end
            end
        end
        if legacy_layout then
            local selected = {}
            local seen = {}
            local custom_ids = {}
            for _i, button in ipairs(config.custom_buttons or {}) do
                if type(button.id) == "string" then custom_ids[button.id] = true end
            end
            for _i, id in ipairs(config.button_order or {}) do
                if (config.show_buttons[id] == true or custom_ids[id]) and not seen[id] then
                    selected[#selected + 1] = id
                    seen[id] = true
                end
            end
            config.button_order = selected
            config.layout_version = 2
        elseif type(config.button_order) ~= "table" then
            config.button_order = utils.deepcopy(config_default.button_order)
        else
            local seen = {}
            local deduped = {}
            for _i, id in ipairs(config.button_order) do
                if not seen[id] then
                    seen[id] = true
                    table.insert(deduped, id)
                end
            end
            config.button_order = deduped
        end
        -- Sync custom button IDs into button_order and show_buttons
        if type(config.custom_buttons) ~= "table" then config.custom_buttons = {} end
        if type(config.next_custom_id) ~= "number" then config.next_custom_id = 0 end
        local cb_ids = {}
        for _i, cb in ipairs(config.custom_buttons) do
            if type(cb.id) == "string" then
                cb_ids[cb.id] = true
                if config.show_buttons[cb.id] == nil then
                    config.show_buttons[cb.id] = true
                end
            end
        end
        -- Remove stale cb_ entries (deleted custom buttons) from button_order
        local clean_order = {}
        for _i, id in ipairs(config.button_order) do
            if id:sub(1, 3) ~= "cb_" or cb_ids[id] then
                table.insert(clean_order, id)
            end
        end
        config.button_order = clean_order
        -- Remove stale cb_ entries from show_buttons
        for key in pairs(config.show_buttons) do
            if key:sub(1, 3) == "cb_" and not cb_ids[key] then
                config.show_buttons[key] = nil
            end
        end
        zen_plugin.config.quick_settings = config
        if legacy_layout and type(zen_plugin.saveConfig) == "function" then
            zen_plugin:saveConfig()
        end
    end

    loadConfig()

    local function isFileManagerMenu(touch_menu)
        local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
        local fm = ok_fm and FileManager and FileManager.instance
        return fm and fm.menu and touch_menu
            and touch_menu.show_parent == fm.menu.menu_container
    end

    local function setRotationMode(touch_menu, mode)
        if isFileManagerMenu(touch_menu) then
            G_reader_settings:saveSetting("fm_rotation_mode", mode)
        end
        if touch_menu and touch_menu.closeMenu then
            touch_menu:closeMenu()
        end
        UIManager:broadcastEvent(Event:new("SetRotationMode", mode))
    end

    local function toggleRotationTarget(target_mode)
        if Screen:getRotationMode() == target_mode then
            return Screen.DEVICE_ROTATED_UPRIGHT
        end
        return target_mode
    end

    local function nextCycleRotationMode()
        local current = Screen:getRotationMode()
        if current == Screen.DEVICE_ROTATED_CLOCKWISE then
            return Screen.DEVICE_ROTATED_UPSIDE_DOWN
        elseif current == Screen.DEVICE_ROTATED_UPSIDE_DOWN then
            return Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE
        elseif current == Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE then
            return Screen.DEVICE_ROTATED_UPRIGHT
        end
        return Screen.DEVICE_ROTATED_CLOCKWISE
    end

    -- Returns true if a plugin slot is loaded in the active UI; fails open if no UI yet.
    local function hasPlugin(slot)
        local ok_f, FM = pcall(require, "apps/filemanager/filemanager")
        local ok_r, RU = pcall(require, "apps/reader/readerui")
        local ui = (ok_f and FM.instance) or (ok_r and RU.instance)
        return ui == nil or ui[slot] ~= nil
    end

    local function hasAnyPlugin(slots)
        for _i, slot in ipairs(slots) do
            if hasPlugin(slot) then return true end
        end
        return false
    end

    local filebrowser_plugins = {
        {
            slots = { "filebrowser" },
            key = "filebrowser",
            pid_path = "/tmp/filebrowser_koreader.pid",
            toggle = "onToggleFilebrowser",
        },
        {
            slots = filebrowserplus_slots,
            key = "filebrowserplus",
            pid_path = "/tmp/filebrowserplus_koreader.pid",
            toggle = "onToggleFilebrowserPlusServer",
            event = "ToggleFilebrowserPlusServer",
        },
    }

    local function getActiveUI()
        local ok_f, FileManager = pcall(require, "apps/filemanager/filemanager")
        local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
        return (ok_f and FileManager.instance) or (ok_r and ReaderUI.instance)
    end

    local function hasLoadedPluginSlot(slots)
        local ui = getActiveUI()
        if not ui then return false end
        for _i, slot in ipairs(slots) do
            if ui[slot] ~= nil then return true end
        end
        return false
    end

    local function isCallable(value)
        if type(value) == "function" then return true end
        local mt = type(value) == "table" and getmetatable(value) or nil
        return type(mt) == "table" and type(mt.__call) == "function"
    end

    local function getLoadedPlugin(candidate)
        local ok_loader, loader = pcall(require, "pluginloader")
        if not ok_loader or not loader then return nil end
        local loaded = loader.loaded_plugins
        if type(loaded) == "table" then
            local plugin = loaded[candidate.key]
            for _i, slot in ipairs(candidate.slots) do
                plugin = plugin or loaded[slot]
            end
            if type(plugin) == "table" then return plugin end
        end
        if type(loader.getPluginInstance) == "function" then
            local ok_plugin, plugin = pcall(loader.getPluginInstance, loader, candidate.key)
            if ok_plugin and type(plugin) == "table" then return plugin end
        end
        return nil
    end

    local function getCandidatePlugin(candidate)
        local ui = getActiveUI()
        if ui then
            for _i, slot in ipairs(candidate.slots) do
                if ui[slot] then return ui[slot] end
            end
        end
        return getLoadedPlugin(candidate)
    end

    local tailscale_plugin = {
        slots = { "tailscale" },
        key = "tailscale",
        toggle = "onToggleTailscale",
    }

    local function getTailscalePlugin()
        local plugin = getCandidatePlugin(tailscale_plugin)
        if plugin and isCallable(plugin[tailscale_plugin.toggle]) then
            return plugin
        end
    end

    local zenfm_plugin = {
        slots = { "zenfm" },
        key = "zenfm",
    }

    local function getZenFMPlugin()
        local plugin = getCandidatePlugin(zenfm_plugin)
        if plugin and plugin.daemon and isCallable(plugin.daemon.status) then
            return plugin
        end
    end

    local function isZenFMRunning()
        local plugin = getZenFMPlugin()
        if not plugin then return false end
        local ok_running, running = pcall(plugin.daemon.status, plugin.daemon)
        return ok_running and running == true
    end

    local function getFilebrowserPlugin(prefer_running)
        local prefer_plus = hasLoadedPluginSlot(filebrowserplus_slots)
        local fallback
        local plus_fallback
        for _i, candidate in ipairs(filebrowser_plugins) do
            local plugin = getCandidatePlugin(candidate)
            if plugin then
                if prefer_running and type(plugin.isRunning) == "function" and plugin:isRunning() then
                    return plugin, candidate
                end
                if isCallable(plugin[candidate.toggle]) then
                    if candidate.key == "filebrowserplus" then
                        plus_fallback = plus_fallback or { plugin, candidate }
                    elseif fallback == nil then
                        fallback = { plugin, candidate }
                    end
                end
            end
        end
        if prefer_plus and plus_fallback then
            return plus_fallback[1], plus_fallback[2]
        end
        if fallback then
            return fallback[1], fallback[2]
        end
        if plus_fallback then
            return plus_fallback[1], plus_fallback[2]
        end
        return nil
    end

    local function toggleFilebrowserPlugin(plugin, candidate)
        if plugin and candidate and isCallable(plugin[candidate.toggle]) then
            plugin[candidate.toggle](plugin)
            return true
        end
        if candidate and candidate.event then
            UIManager:broadcastEvent(Event:new(candidate.event))
            return true
        end
        return false
    end

    local function showUnavailable()
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = _("Quick settings button is unavailable") })
    end

    local function getScreenshotTimerSeconds()
        local seconds = tonumber(config.screenshot_timer_seconds) or 3
        return math.max(0, math.min(10, math.floor(seconds)))
    end

    local function showScreenshotTimerDialog(touch_menu)
        local SpinWidget = require("ui/widget/spinwidget")
        UIManager:show(SpinWidget:new{
            title_text = _("Screenshot timer"),
            value = getScreenshotTimerSeconds(),
            value_min = 0,
            value_max = 10,
            default_value = 3,
            callback = function(spin)
                config.screenshot_timer_seconds = spin.value
                zen_plugin:saveConfig()
                if touch_menu and touch_menu.updateItems then touch_menu:updateItems(1) end
            end,
        })
    end

    local function refreshQuickSettings(touch_menu)
        if touch_menu and touch_menu.item_table and touch_menu.item_table.panel then
            touch_menu:updateItems(1)
        end
    end

    local function refreshWifiQuickSettings(touch_menu)
        refreshQuickSettings(touch_menu)
        UIManager:scheduleIn(1, function()
            refreshQuickSettings(touch_menu)
        end)
    end

    local function isWifiConnected()
        return NetworkMgr:isWifiOn()
            and (type(NetworkMgr.isConnected) ~= "function" or NetworkMgr:isConnected())
    end

    local function isWifiConnecting()
        return not isWifiConnected()
            and (NetworkMgr.pending_connection or NetworkMgr.pending_connectivity_check)
    end

    -- ============================================================
    -- Button definitions (data-driven)
    -- ============================================================

    local open_quick_setting_settings

    local function resolveConfiguredIcon(name, fallback)
        local path = utils.resolveIcon(_icons_dir, name)
        if path then return path end
        for _i, item in ipairs(utils.getIconPickerList(_plugin_root)) do
            if item.name == name then return item.file end
        end
        return utils.resolveLocalIcon(_icons_dir, fallback)
    end

    local button_defs = {
        bluetooth = {
            icon = "quick_bluetooth",
            label = _("Bluetooth"),
            visible_func = Bluetooth.isAvailable,
            active_func = Bluetooth.isEnabled,
            callback = function(touch_menu)
                if Bluetooth.toggle() then
                    UIManager:scheduleIn(0.5, function()
                        Bluetooth.logState("0.5 s after control toggle")
                        if touch_menu.item_table and touch_menu.item_table.panel then
                            touch_menu:updateItems(1)
                        end
                    end)
                end
            end,
        },
        wifi = {
            icon = "quick_wifi",
            label = _("Wi-Fi"),
            label_func = function()
                if isWifiConnected() then
                    local net = NetworkMgr.getCurrentNetwork and NetworkMgr:getCurrentNetwork()
                    if net and type(net.ssid) == "string" and net.ssid ~= "" then
                        return net.ssid
                    end
                end
                return _("Wi-Fi")
            end,
            active_func = isWifiConnected,
            dim_func = isWifiConnecting,
            callback = function(touch_menu)
                if isWifiConnecting() then return end
                -- Explicit toggles need KOReader's scan/DHCP flow; async restore is resume-only.
                local wifi_menu = NetworkMgr:getWifiMenuTable()
                wifi_menu.callback({
                    updateItems = function()
                        refreshWifiQuickSettings(touch_menu)
                    end,
                })
            end,
            hold_callback = function(touch_menu)
                -- Long-hold: (re)connect and show the AP picker.
                -- If Wi-Fi is currently on, turn it off first, then bring it
                -- back up with long_press=true so the network list appears.
                -- If already off, go straight to the long-press connect flow.
                local function do_connect()
                    NetworkMgr:toggleWifiOn(function()
                        refreshWifiQuickSettings(touch_menu)
                    end, true, true)
                end
                if NetworkMgr:isWifiOn() then
                    NetworkMgr:toggleWifiOff(function()
                        do_connect()
                    end, true)
                else
                    do_connect()
                end
            end,
        },
        night = {
            icon = "quick_nightmode",
            label = _("Night"),
            active_func = function() return G_reader_settings:isTrue("night_mode") end,
            callback = function(touch_menu)
                local night_mode = G_reader_settings:isTrue("night_mode")
                Screen:toggleNightMode()
                UIManager:ToggleNightMode(not night_mode)
                G_reader_settings:saveSetting("night_mode", not night_mode)
                touch_menu:updateItems(1)
                UIManager:setDirty("all", "full")
            end,
        },
        frontlight = {
            icon = "lightbulb",
            label = _("Light"),
            visible_func = function() return Device:hasFrontlight() end,
            active_func = function()
                local powerd = Device:getPowerDevice()
                if powerd and powerd.isFrontlightOn then
                    return powerd:isFrontlightOn()
                end
                return powerd and powerd.frontlightIntensity
                    and powerd:frontlightIntensity() > (powerd.fl_min or 0)
            end,
            callback = function(touch_menu)
                local powerd = Device:getPowerDevice()
                if not powerd then return end
                if powerd.isFrontlightOn and powerd:isFrontlightOn() then
                    if powerd.turnOffFrontlight then
                        powerd:turnOffFrontlight()
                    elseif powerd.setIntensity then
                        powerd:setIntensity(powerd.fl_min or 0)
                    end
                else
                    local target = powerd.fl_intensity
                    if type(target) ~= "number" or target <= (powerd.fl_min or 0) then
                        target = math.min(powerd.fl_max or 1, (powerd.fl_min or 0) + 1)
                    end
                    local turned_on = powerd.turnOnFrontlight and powerd:turnOnFrontlight()
                    if (not powerd.turnOnFrontlight or turned_on == false) and powerd.setIntensity then
                        powerd:setIntensity(target)
                    end
                end
                touch_menu:updateItems(1)
            end,
        },
        gyro = {
            icon = resolveConfiguredIcon(
                type(config.gyro_icon) == "string" and config.gyro_icon ~= ""
                    and config.gyro_icon or "quick_rotate", "quick_rotate"),
            label = type(config.gyro_label) == "string" and config.gyro_label ~= ""
                and config.gyro_label or _("Autorotate"),
            visible_func = function() return Device:hasGSensor() end,
            active_func = function()
                return G_reader_settings:nilOrFalse("input_ignore_gsensor")
            end,
            callback = function(touch_menu)
                UIManager:broadcastEvent(Event:new("ToggleGSensor"))
                touch_menu:updateItems(1)
            end,
        },
        rotate = {
            icon = "quick_rotate",
            label = _("Rotate"),
            callback = function(touch_menu)
                local action = config.rotate_action
                if action == "90" then
                    setRotationMode(touch_menu, toggleRotationTarget(Screen.DEVICE_ROTATED_CLOCKWISE))
                elseif action == "180" then
                    setRotationMode(touch_menu, toggleRotationTarget(Screen.DEVICE_ROTATED_UPSIDE_DOWN))
                elseif action == "270" then
                    setRotationMode(touch_menu, toggleRotationTarget(Screen.DEVICE_ROTATED_COUNTER_CLOCKWISE))
                else
                    setRotationMode(touch_menu, nextCycleRotationMode())
                end
            end,
        },
        usb = {
            icon = "quick_usb",
            label = _("USB"),
            callback = function()
                if Device.canToggleMassStorage and Device:canToggleMassStorage() then
                    UIManager:broadcastEvent(Event:new("RequestUSBMS"))
                end
            end,
        },
        restart = {
            icon = "quick_restart",
            label = _("Restart"),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Are you sure you want to restart KOReader?"),
                    ok_text = _("Restart"),
                    ok_callback = function()
                        restart.request()
                    end,
                })
            end,
        },
        exit = {
            icon = "quick_exit",
            label = _("Exit"),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Are you sure you want to exit KOReader?"),
                    ok_text = _("Exit"),
                    ok_callback = function()
                        shutdown.broadcastExit(zen_plugin)
                    end,
                })
            end,
        },
        sleep = {
            icon = "quick_sleep",
            label = _("Sleep"),
            callback = function(touch_menu)
                if touch_menu and touch_menu.closeMenu then
                    touch_menu:closeMenu()
                end
                if Device:canSuspend() then
                    UIManager:suspend()
                elseif Device:canPowerOff() then
                    UIManager:broadcastEvent(Event:new("RequestPowerOff"))
                end
            end,
        },
        search = {
            icon = "quick_search",
            label = _("Search"),
            callback = function()
                UIManager:broadcastEvent(Event:new("ShowFileSearch"))
            end,
        },
        quickrss = {
            icon = "quick_quickrss",
            label = _("QuickRSS"),
            visible_func = function() local ok = pcall(require, "modules/ui/feed_view"); return ok end,
            callback = function()
                local ok, QuickRSSUI = pcall(require, "modules/ui/feed_view")
                if ok and QuickRSSUI then
                    local view = QuickRSSUI:new{}
                    UIManager:show(view)
                    view:_fetch()
                else
                    local InfoMessage = require("ui/widget/infomessage")
                    UIManager:show(InfoMessage:new{
                        text = _("QuickRSS plugin is not installed."),
                    })
                end
            end,
        },
        cloud = {
            icon = "quick_cloud",
            label = _("Cloud"),
            callback = function()
                UIManager:broadcastEvent(Event:new("ShowCloudStorage"))
            end,
        },
        zlibrary = {
            icon = "quick_zlib",
            label = _("Z-Lib"),
            visible_func = function() return hasPlugin("zlibrary") end,
            callback = function()
                UIManager:broadcastEvent(Event:new("ZlibrarySearch"))
            end,
        },
        calibre_search = {
            icon = "quick_search",
            label = _("Search"),
            visible_func = function() return hasPlugin("calibre") end,
            callback = function(touch_menu)
                touch_menu:closeMenu()
                UIManager:broadcastEvent(Event:new("CalibreSearch"))
            end,
        },
        calibre = {
            icon = "quick_calibre",
            label = _("Calibre"),
            visible_func = function() return hasPlugin("calibre") end,
            active_func = function()
                local CW = package.loaded["wireless"]
                return CW ~= nil and CW.calibre_socket ~= nil
            end,
            callback = function(touch_menu)
                local CW = package.loaded["wireless"]
                if CW and CW.calibre_socket ~= nil then
                    UIManager:broadcastEvent(Event:new("CloseWirelessConnection"))
                else
                    UIManager:broadcastEvent(Event:new("StartWirelessConnection"))
                end
                UIManager:scheduleIn(1, function()
                    touch_menu:updateItems(1)
                end)
            end,
        },
        notion = {
            icon = "quick_notion",
            label = _("NotionSync"),
            visible_func = function() return hasPlugin("NotionSync") end,
            callback = function()
                local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
                local ok_f, FileManager = pcall(require, "apps/filemanager/filemanager")
                local ui = (ok_r and ReaderUI.instance) or (ok_f and FileManager.instance)
                if ui and ui.NotionSync then
                    ui.NotionSync:onSyncAllBooksRequested()
                end
            end,
        },
        streak = {
            icon = "quick_streak",
            label = _("Streak"),
            visible_func = function() return hasPlugin("readingstreak") end,
            callback = function()
                UIManager:broadcastEvent(Event:new("ShowReadingStreakCalendar"))
            end,
        },
        opds = {
            icon = "quick_opds",
            label = _("OPDS"),
            visible_func = function() return hasPlugin("opds") end,
            callback = function(touch_menu)
                touch_menu:closeMenu()
                UIManager:broadcastEvent(Event:new("ShowOPDSCatalog"))
            end,
        },
        localsend = {
            icon = "quick_localsend",
            label = _("LocalSend"),
            visible_func = function() return hasPlugin("localsend") end,
            active_func = function()
                local f = io.open("/tmp/localsend_koreader.pid", "r")
                if f then f:close(); return true end
                return false
            end,
            callback = function(touch_menu)
                UIManager:broadcastEvent(Event:new("ToggleLocalSend"))
                UIManager:scheduleIn(1.5, function()
                    if touch_menu._zen_panel_refs then
                        touch_menu:updateItems(1)
                    end
                end)
            end,
        },
        tailscale = {
            icon = utils.resolveLocalIcon(_icons_dir, "network"),
            label = _("Tailscale"),
            visible_func = function() return getTailscalePlugin() ~= nil end,
            active_func = function()
                local plugin = getTailscalePlugin()
                if not (plugin and isCallable(plugin.isRunning)) then return false end
                local ok, running = pcall(plugin.isRunning, plugin)
                return ok and running == true
            end,
            callback = function(touch_menu)
                local plugin = getTailscalePlugin()
                if not plugin then
                    showUnavailable()
                    return
                end
                plugin:onToggleTailscale(function()
                    refreshQuickSettings(touch_menu)
                end)
            end,
        },
        zenfm = {
            icon = utils.resolveLocalIcon(_icons_dir, "zenfm"),
            label = _("ZenFM"),
            visible_func = function() return getCandidatePlugin(zenfm_plugin) ~= nil end,
            active_func = isZenFMRunning,
            callback = function(touch_menu)
                local plugin = getCandidatePlugin(zenfm_plugin)
                if not (plugin and isCallable(plugin.onToggleZenFM)) then
                    showUnavailable()
                    return
                end
                plugin:onToggleZenFM()
                refreshQuickSettings(touch_menu)
            end,
            hold_callback = function(touch_menu)
                return open_quick_setting_settings("zenfm", touch_menu)
            end,
        },
        zen = {
            icon = utils.resolveLocalIcon(_icons_dir, "quick_zen"),
            label = _("Zen"),
            active_func = function()
                local features = zen_plugin.config and zen_plugin.config.features
                return type(features) == "table" and features.zen_mode == true
            end,
            -- Grayed out and inert while lockdown is active (lockdown requires zen mode).
            disabled_func = function()
                local features = zen_plugin.config and zen_plugin.config.features
                return type(features) == "table" and features.lockdown_mode == true
            end,
            callback = function(touch_menu)
                if zen_plugin.onToggleZenMode then
                    touch_menu:closeMenu()
                    zen_plugin:onToggleZenMode()
                end
            end,
        },
        lockdown = {
            icon = "quick_lockdown",
            label = _("Lockdown"),
            active_func = function()
                local features = zen_plugin.config and zen_plugin.config.features
                return type(features) == "table" and features.lockdown_mode == true
            end,
            callback = function(touch_menu)
                if zen_plugin.onToggleLockdownMode then
                    zen_plugin:onToggleLockdownMode()
                end
                if touch_menu and touch_menu.updateItems then
                    touch_menu:updateItems(1)
                end
            end,
        },
        incognito = {
            icon = "quick_incognito",
            label = _("Incognito"),
            active_func = function()
                local features = zen_plugin.config and zen_plugin.config.features
                return type(features) == "table" and features.incognito_mode == true
            end,
            callback = function(touch_menu)
                if zen_plugin.onToggleIncognitoMode then
                    zen_plugin:onToggleIncognitoMode()
                end
                if touch_menu and touch_menu.updateItems then
                    touch_menu:updateItems(1)
                end
            end,
        },
        connections = {
            icon = "quick_connections",
            label = _("Connections"),
            visible_func = function() return hasPlugin("nytconnections") end,
            callback = function(touch_menu)
                touch_menu:closeMenu()
                local ok_f, FileManager = pcall(require, "apps/filemanager/filemanager")
                local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
                local ui = (ok_f and FileManager.instance) or (ok_r and ReaderUI.instance)
                if ui and ui.nytconnections then
                    -- Extract the callback the plugin registered so we stay in sync with its implementation.
                    local items = {}
                    ui.nytconnections:addToMainMenu(items)
                    if items.nytconnections and items.nytconnections.callback then
                        items.nytconnections.callback()
                    end
                end
            end,
        },
        crossword = {
            icon = "quick_crossword",
            label = _("Crossword"),
            visible_func = function() return hasPlugin("crossword") end,
            callback = function(touch_menu)
                touch_menu:closeMenu()
                local ok_f, FileManager = pcall(require, "apps/filemanager/filemanager")
                local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
                local ui = (ok_f and FileManager.instance) or (ok_r and ReaderUI.instance)
                if ui and ui.crossword then
                    ui.crossword:showLibraryView()
                end
            end,
        },
        puzzle = {
            icon = "quick_puzzle",
            label = _("Puzzle"),
            visible_func = function() return hasPlugin("slidepuzzle") end,
            callback = function(touch_menu)
                touch_menu:closeMenu()
                UIManager:broadcastEvent(Event:new("SlidePuzzleOpen"))
            end,
        },
        stats_progress = {
            icon = "quick_stats_progress",
            label = _("Progress"),
            visible_func = function() return hasPlugin("statistics") end,
            callback = function(touch_menu)
                touch_menu:closeMenu()
                UIManager:broadcastEvent(Event:new("ShowReaderProgress"))
            end,
        },
        stats_calendar = {
            icon = "quick_stats_calendar",
            label = _("Calendar"),
            visible_func = function() return hasPlugin("statistics") end,
            callback = function(touch_menu)
                touch_menu:closeMenu()
                UIManager:broadcastEvent(Event:new("ShowCalendarView"))
            end,
        },
        battery_stats = {
            icon = "quick_battery",
            label = _("Battery"),
            visible_func = function() return hasPlugin("batterystat") end,
            callback = function(touch_menu)
                touch_menu:closeMenu()
                UIManager:broadcastEvent(Event:new("ShowBatteryStatistics"))
            end,
        },
        kosync = {
            icon = "quick_sync",
            label = _("Sync"),
            visible_func = function() return hasPlugin("kosync") end,
            callback = function(touch_menu)
                touch_menu:closeMenu()
                if zen_plugin.onZenUIKOSyncSync then
                    zen_plugin:onZenUIKOSyncSync()
                end
            end,
        },
        filebrowser = {
            icon = "quick_filebrowser",
            label = _("Filebrowser"),
            visible_func = function() return hasAnyPlugin(filebrowser_slots) end,
            active_func = function()
                for _i, candidate in ipairs(filebrowser_plugins) do
                    local f = io.open(candidate.pid_path, "r")
                    if f then f:close() return true end
                end
                return false
            end,
            callback = function(touch_menu)
                local plugin, candidate = getFilebrowserPlugin(true)
                SettingsTransition.close()
                if toggleFilebrowserPlugin(plugin, candidate) then
                    UIManager:scheduleIn(1.5, function()
                        if touch_menu.item_table and touch_menu.item_table.panel then
                            touch_menu:updateItems(1)
                        end
                    end)
                else
                    local InfoMessage = require("ui/widget/infomessage")
                    UIManager:show(InfoMessage:new{
                        text = _("Filebrowser plugin is not installed."),
                    })
                end
            end,
        },
        screenshot = {
            icon = "quick_screenshot",
            label = _("Screenshot"),
            callback = function(touch_menu)
                touch_menu:closeMenu()
                UIManager:scheduleIn(0.3, function()
                    require("modules/menu/patches/countdown_screenshot").run(getScreenshotTimerSeconds())
                end)
            end,
            hold_callback = showScreenshotTimerDialog,
        },
        chess = {
            icon = "quick_chess",
            label = _("Chess"),
            visible_func = function() return hasPlugin("kochess") end,
            callback = function(touch_menu)
                touch_menu:closeMenu()
                UIManager:broadcastEvent(Event:new("KochessStart"))
            end,
        },
        casualchess = {
            icon = "quick_chess",
            label = _("Chess"),
            visible_func = function() return hasPlugin("casualkochess") end,
            callback = function(touch_menu)
                touch_menu:closeMenu()
                UIManager:broadcastEvent(Event:new("CasualChessStart"))
            end,
        },

    }

    local function install_custom_button_defs()
        if type(config.custom_buttons) ~= "table" then return end
        for _i, cb in ipairs(config.custom_buttons) do
            if cb.type == "koreader_menu" and type(cb.koreader_menu) == "table" then
                local target = cb.koreader_menu
                button_defs[cb.id] = {
                    icon = cb.icon or "lightning",
                    label = (cb.label and cb.label ~= "") and cb.label
                        or target.title
                        or _("KOReader menu"),
                    disabled_func = function()
                        return not NativeMenu.exists(target.id, "active")
                    end,
                    callback = function(tm)
                        local launch = NativeMenu.resolve(target.id, "active")
                        if not launch then
                            showUnavailable()
                            return
                        end
                        tm:closeMenu()
                        SettingsTransition.close()
                        UIManager:nextTick(function()
                            pcall(launch)
                        end)
                    end,
                }
            elseif cb.type == "plugin" and type(cb.plugin) == "table" then
                local plugin = cb.plugin
                button_defs[cb.id] = {
                    icon = cb.icon or "lightning",
                    label = (cb.label and cb.label ~= "") and cb.label
                        or cb.plugin_title
                        or _("Plugin"),
                    visible_func = function()
                        return PluginScan.exists(plugin.key, plugin.method)
                    end,
                    callback = function(tm)
                        local launch = PluginScan.resolve(plugin.key, plugin.method)
                        if not launch then
                            showUnavailable()
                            return
                        end
                        tm:closeMenu()
                        SettingsTransition.close()
                        UIManager:nextTick(function()
                            pcall(launch)
                        end)
                    end,
                }
            elseif cb.type == "folder" or cb.type == "tag" then
                button_defs[cb.id] = {
                    icon = cb.icon or "lightning",
                    label = (cb.label and cb.label ~= "") and cb.label
                        or ButtonModel.label(nil, cb),
                    callback = function(tm)
                        tm:closeMenu()
                        SettingsTransition.close()
                        UIManager:nextTick(function()
                            ButtonModel.execute(cb, zen_plugin)
                        end)
                    end,
                }
            else
                local cb_action = cb.action
                button_defs[cb.id] = {
                    icon = cb.icon or "lightning",
                    label = (cb.label and cb.label ~= "") and cb.label
                        or (cb_action and next(cb_action) and Dispatcher:menuTextFunc(cb_action))
                        or _("Custom"),
                    active_func = function()
                        return DispatchAction.isActionActive(cb_action, zen_plugin)
                    end,
                    callback = function(tm)
                        tm:closeMenu()
                        SettingsTransition.close()
                        -- In the reader the touch menu sits above the bottom
                        -- ConfigDialog. UIManager:sendEvent (which Dispatcher:execute
                        -- uses for "none"-category actions) only reaches the topmost
                        -- window, so with the ConfigDialog still open the dispatched
                        -- event would be swallowed and never reach ReaderUI. Close it
                        -- before dispatching.
                        UIManager:broadcastEvent(Event:new("CloseConfigMenu"))
                        UIManager:nextTick(function()
                            if type(cb_action) == "table" and next(cb_action) then
                                Dispatcher:execute(cb_action)
                            end
                        end)
                    end,
                }
            end
        end
    end

    local function quick_setting_items()
        install_custom_button_defs()
        local items = {}
        for id, def in pairs(button_defs) do
            if not def.visible_func or def.visible_func() then
                local label = def.label
                items[#items + 1] = { id = id, text = label, label = label, icon = def.icon }
            end
        end
        table.sort(items, function(a, b)
            return ffiUtil.strcoll(a.label or "", b.label or "")
        end)
        return items
    end

    local function normalize_zenfm_settings(items)
        for _i, item in ipairs(type(items) == "table" and items or {}) do
            if type(item.checked_func) == "function"
                    and type(item.checkmark_callback) == "function"
                    and type(item.callback) == "function"
                    and item.sub_item_table == nil
                    and item.sub_item_table_func == nil then
                local open_callback = item.callback
                item.callback = item.checkmark_callback
                item.checkmark_callback = nil
                item.sub_item_table_func = function(touch_menu)
                    open_callback(touch_menu)
                    return {}
                end
            end
        end
        return items
    end

    local function quick_setting_config_items(id)
        if id == "rotate" then
            local items = {}
            for _i, item in ipairs({
                { id = "cycle", text = _("Cycle") },
                { id = "90", text = _("90°") },
                { id = "180", text = _("180°") },
                { id = "270", text = _("270°") },
            }) do
                local option = item
                items[#items + 1] = {
                    text = option.text,
                    radio = true,
                    checked_func = function()
                        return config.rotate_action == option.id
                    end,
                    callback = function()
                        config.rotate_action = option.id
                        zen_plugin:saveConfig()
                    end,
                }
            end
            return items
        end
        if id == "screenshot" then
            return {{
                text_func = function()
                    return T(_("Timer: %1 s"), getScreenshotTimerSeconds())
                end,
                keep_menu_open = true,
                callback = showScreenshotTimerDialog,
            }}
        end
        if id == "incognito" then
            return require("modules/global/patches/incognito_mode").timeoutMenuItems(zen_plugin)
        end
        if id == "zenfm" then
            local plugin = getCandidatePlugin(zenfm_plugin)
            if not (plugin and isCallable(plugin.settings_menu)) then return {} end
            local ok, items = pcall(plugin.settings_menu, plugin)
            if not ok or type(items) ~= "table" then return {} end
            return normalize_zenfm_settings(items)
        end
        return {}
    end

    open_quick_setting_settings = function(id, touch_menu)
        local items = quick_setting_config_items(id)
        if #items == 0 then
            showUnavailable()
            return false
        end
        if touch_menu and type(touch_menu.closeMenu) == "function" then
            touch_menu:closeMenu()
        end
        UIManager:nextTick(function()
            require("modules/menu/app_launcher/menu_host").show{
                title = button_defs[id] and button_defs[id].label or _("Control settings"),
                item_table = items,
                back_visible = false,
            }
        end)
        return true
    end

    rawset(_G, "__ZEN_UI_QUICK_SETTINGS", {
        getItems = quick_setting_items,
        getSettingsItems = quick_setting_config_items,
        hold = function(id, touch_menu)
            install_custom_button_defs()
            local def = button_defs[id]
            if not (def and type(def.hold_callback) == "function") then return false end
            return def.hold_callback(touch_menu) ~= false
        end,
        has = function(id)
            install_custom_button_defs()
            local def = button_defs[id]
            return def ~= nil and (not def.visible_func or def.visible_func())
        end,
        isActive = function(id)
            install_custom_button_defs()
            local def = button_defs[id]
            return def and (not def.disabled_func or not def.disabled_func())
                and def.active_func and def.active_func() or false
        end,
        isDisabled = function(id)
            install_custom_button_defs()
            local def = button_defs[id]
            return def and def.disabled_func and def.disabled_func() or false
        end,
        isDimmed = function(id)
            install_custom_button_defs()
            local def = button_defs[id]
            return def and def.dim_func and def.dim_func() or false
        end,
        activate = function(id, touch_menu)
            install_custom_button_defs()
            local def = button_defs[id]
            if not def or (def.visible_func and not def.visible_func()) then return false end
            local host = touch_menu or {
                closeMenu = function() end,
                updateItems = function() end,
                item_table = { panel = true },
                _zen_panel_refs = true,
            }
            if def.disabled_func and def.disabled_func() then return false end
            def.callback(host)
            return true
        end,
    })

    -- ============================================================
    -- Panel builder — returns panel widget + refs for tap handling
    -- ============================================================

    local function is_qs_hold_required()
        local features = zen_plugin.config and zen_plugin.config.features
        if not (type(features) == "table" and features.lockdown_mode == true) then return false end
        local lc = zen_plugin.config.lockdown
        return type(lc) == "table" and lc.require_hold_in_qs == true
    end

    local function createQuickSettingsPanel(touch_menu)
        local panel_width = touch_menu.item_width
        local padding = Screen:scaleBySize(10)
        local inner_width = panel_width - padding * 2
        local powerd = Device:getPowerDevice()
        local meta = zen_plugin.config and zen_plugin.config._meta
        local panel_config = type(meta) == "table"
                and meta.quickstart_menu_tour_pending == true
            and config_default or config

        local refs = {
            buttons = {},
            sliders = {},
            toggles = {},
            require_hold = is_qs_hold_required,
        }

        -- ----- Top row: action buttons -----

        -- Custom definitions are rebuilt on every render so edits are immediate.
        install_custom_button_defs()

        local visible_buttons = {}
        for _i, id in ipairs(panel_config.button_order) do
            if panel_config.show_buttons[id] and button_defs[id] then
                local def = button_defs[id]
                if not def.visible_func or def.visible_func() then
                    table.insert(visible_buttons, { id = id, def = def })
                end
            end
        end

        local num_buttons = #visible_buttons
        local action_btn_size = Screen:scaleBySize(64)
        local action_cell_width = ButtonLabelWidth.equalCellWidth(inner_width, num_buttons)
        local icon_size = math.floor(action_btn_size * 0.5)
        local label_size = Font.sizemap and Font.sizemap["xx_smallinfofont"] or 18
        local label_font = library_font.getFace(label_size)
        local label_side_padding = Screen:scaleBySize(ButtonLabelWidth.SIDE_PADDING)

        local normal_border = Screen:scaleBySize(2)

        local function makeActionButton(icon_name, label_text, active, disabled, dimmed)
            local icon_path = type(icon_name) == "string" and icon_name:sub(1, 1) == "/"
                and icon_name or (_icons_dir and utils.resolveIcon(_icons_dir, icon_name))
            local rendered_icon_size = math.floor(
                icon_size * utils.iconOpticalScale(icon_name) + 0.5)
            local icon = IconWidget:new{
                file   = icon_path or nil,
                icon   = icon_path and nil or icon_name,
                width  = rendered_icon_size,
                height = rendered_icon_size,
                -- alpha=false → BlitBuffer8 (opaque grayscale); invertRect flips
                -- pixel values so the icon renders white-on-black for active state.
                alpha  = not active,
            }
            if active then
                -- Force the cached buffer to be populated, then copy it before
                -- inverting so the shared cache entry is never mutated (otherwise
                -- invertRect would flip back on every second open).
                icon:_render()
                if icon._bb then
                    local bb_copy = icon._bb:copy()
                    bb_copy:invertRect(0, 0, bb_copy:getWidth(), bb_copy:getHeight())
                    icon._bb = bb_copy
                end
            end
            local border = active and 0 or normal_border
            local bg = active and Blitbuffer.COLOR_BLACK
                or disabled and Blitbuffer.COLOR_LIGHT_GRAY
                or dimmed and Blitbuffer.COLOR_GRAY
                or Blitbuffer.COLOR_WHITE
            local circle = FrameContainer:new{
                width      = action_btn_size,
                height     = action_btn_size,
                radius     = math.floor(action_btn_size / 2),
                bordersize = border,
                background = bg,
                padding    = 0,
                CenterContainer:new{
                    dimen = Geom:new{
                        w = action_btn_size - border * 2,
                        h = action_btn_size - border * 2,
                    },
                    icon,
                },
            }
            circle.onFocus = function(self)
                self.invert = true
                if self.dimen then
                    UIManager:setDirty(nil, "ui", self.dimen)
                end
                return true
            end
            circle.onUnfocus = function(self)
                self.invert = false
                if self.dimen then
                    UIManager:setDirty(nil, "ui", self.dimen)
                end
                return true
            end
            local group = VerticalGroup:new{
                align = "center",
                circle,
            }
            if panel_config.show_labels ~= false then
                local label_max_width = ButtonLabelWidth.maxWidth(action_cell_width, label_side_padding)
                group[#group + 1] = VerticalSpan:new{ width = Screen:scaleBySize(2) }
                group[#group + 1] = TextWidget:new{
                    text = label_text,
                    face = label_font,
                    max_width = label_max_width,
                }
            end
            return group, circle
        end

        local top_row = HorizontalGroup:new{ align = "center" }
        refs.button_layout_row = {}

        if num_buttons > 0 then
            for _i, entry in ipairs(visible_buttons) do
                local def = entry.def
                local label_text = def.label
                if def.label_func then
                    label_text = def.label_func()
                end
                local active   = def.active_func   and def.active_func()   or false
                local disabled = def.disabled_func and def.disabled_func() or false
                local dimmed   = def.dim_func      and def.dim_func()      or false
                -- Disabled takes priority: don't show active styling on a greyed-out button.
                local btn_widget, btn_circle = makeActionButton(
                    def.icon, label_text, active and not disabled, disabled, dimmed
                )

                table.insert(refs.buttons, {
                    id = entry.id,
                    widget = btn_circle,
                    callback = not disabled and function()
                        def.callback(touch_menu)
                    end or nil,
                    hold_callback = def.hold_callback and function()
                        def.hold_callback(touch_menu)
                    end or nil,
                })
                table.insert(refs.button_layout_row, btn_circle)

                table.insert(top_row, CenterContainer:new{
                    dimen = Geom:new{ w = action_cell_width, h = btn_widget:getSize().h },
                    btn_widget,
                })
            end
        end

        -- ----- Frontlight / warmth sliders -----

        local medium_size     = Font.sizemap and Font.sizemap["ffont"] or 24
        local medium_font     = library_font.getFace(medium_size)
        local small_btn_size  = Screen:scaleBySize(14)
        local small_btn_width = Screen:scaleBySize(56)
        local toggle_width    = Screen:scaleBySize(56)
        local slider_gap      = Screen:scaleBySize(4)
        local slider_width    = inner_width - 2 * small_btn_width - 2 * slider_gap

        local slider_opts = {
            inner_width     = inner_width,
            slider_width    = slider_width,
            small_btn_width = small_btn_width,
            toggle_width    = toggle_width,
            slider_gap      = slider_gap,
            medium_font     = medium_font,
            small_btn_size  = small_btn_size,
            powerd          = powerd,
            refs            = refs,
        }

        local fl_group = VerticalGroup:new{ align = "center" }
        if panel_config.show_frontlight and Device:hasFrontlight() then
            fl_group = build_brightness_slider(touch_menu, slider_opts)
        end

        local warmth_group = VerticalGroup:new{ align = "center" }
        if panel_config.show_warmth and Device:hasNaturalLight() then
            warmth_group = build_warmth_slider(touch_menu, slider_opts)
        end

        -- ----- Status bar row (reuses status_bar component when that feature is active) -----

        local buildStatusRow = get_shared("buildStatusRow")
        local status_row  = type(buildStatusRow) == "function"
            and buildStatusRow(panel_width, {
                padding   = Screen:scaleBySize(6),
                font_name = "x_smallinfofont",
            })

        -- ----- Assemble panel -----

        local panel = VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = Screen:scaleBySize(8) },
        }

        if status_row then
            table.insert(panel, status_row)
            table.insert(panel, VerticalSpan:new{ width = Screen:scaleBySize(8) })
        end

        if num_buttons > 0 then
            table.insert(panel, CenterContainer:new{
                dimen = Geom:new{ w = panel_width, h = top_row:getSize().h },
                top_row,
            })
            table.insert(panel, VerticalSpan:new{ width = Screen:scaleBySize(8) })
        end

        if #fl_group > 0 then
            table.insert(panel, fl_group)
        end
        if #warmth_group > 0 then
            table.insert(panel, warmth_group)
        end
        table.insert(panel, VerticalSpan:new{ width = Screen:scaleBySize(8) })

        touch_menu._zen_panel_refs = refs

        return panel
    end

    rawset(_G, "__ZEN_UI_BUILD_QUICK_SETTINGS_PREVIEW", function(item_width)
        local touch_menu = {
            item_width = item_width,
            closeMenu = function() end,
        }
        return createQuickSettingsPanel(touch_menu)
    end)

    local TouchMenu = require("ui/widget/touchmenu")

    -- Open launcher first when requested; otherwise Controls remains the default.
    local orig_init = TouchMenu.init
    function TouchMenu:init()
        if launcher_opens_first() then
            self.last_index = getLauncherTabIndex(self) or getQuickSettingsTabIndex(self)
        elseif is_enabled() then
            self.last_index = getQuickSettingsTabIndex(self)
        end
        orig_init(self)
    end

    -- Hook switchMenuTab to force quick settings tab on menu open
    local orig_switchMenuTab = TouchMenu.switchMenuTab

    function TouchMenu:switchMenuTab(tab_num)
        orig_switchMenuTab(self, tab_num)
        if not is_enabled() then
            return
        end
        self.last_index = launcher_opens_first()
            and (getLauncherTabIndex(self) or getQuickSettingsTabIndex(self))
            or getQuickSettingsTabIndex(self)
    end

    -- ============================================================
    -- Quick Settings tab definition
    -- ============================================================

    local quick_settings_tab = {
        id = "quicksettings",
        icon = "quicksettings",
        remember = true,
        panel = createQuickSettingsPanel,
    }

    -- ============================================================
    -- Inject tab into both FileManager and Reader menus
    -- ============================================================

    local FileManagerMenu = require("apps/filemanager/filemanagermenu")
    local ReaderMenu = require("apps/reader/modules/readermenu")

    local orig_fm_setUpdateItemTable = FileManagerMenu.setUpdateItemTable

    function FileManagerMenu:setUpdateItemTable()
        orig_fm_setUpdateItemTable(self)
        if is_enabled() and self.tab_item_table then
            table.insert(self.tab_item_table, 1, quick_settings_tab)
        end
    end

    local orig_reader_setUpdateItemTable = ReaderMenu.setUpdateItemTable

    function ReaderMenu:setUpdateItemTable()
        orig_reader_setUpdateItemTable(self)
        if is_enabled() and self.tab_item_table then
            table.insert(self.tab_item_table, 1, quick_settings_tab)
        end
    end
end

return apply_quick_settings
