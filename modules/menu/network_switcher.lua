local M = {}

local VERIFY_ATTEMPTS = 60
local VERIFY_DELAY_US = 250 * 1000
local NETWORK_NAME_RETRIES = 8

function M.toggleWifi(touch_menu, on_connected, settings_subpage, plugin, show_networks)
    local UIManager = require("ui/uimanager")
    local NetworkMgr = require("ui/network/manager")
    local KindleNetworkAdapter = require("modules/menu/network_adapters/kindle")
    local KoboNetworkAdapter = require("modules/menu/network_adapters/kobo")
    local logger = require("common/zen_logger").new("network_switcher")
    local _ = require("gettext")
    local wifi_on = NetworkMgr:isWifiOn()
    local connected = wifi_on and NetworkMgr:isConnected()
    local Device = require("device")
    local kindle = KindleNetworkAdapter.isSupported(Device)
    local kobo = KoboNetworkAdapter.isSupported(Device)
    show_networks = show_networks or function()
        return M.open(on_connected, settings_subpage, plugin)
    end
    if not connected and (NetworkMgr.pending_connection or NetworkMgr.pending_connectivity_check) then
        logger.dbg("Wi-Fi toggle cancelling pending connection", "wifi_on=", wifi_on)
        if wifi_on then
            NetworkMgr:toggleWifiOff(function() touch_menu:updateItems() end, true)
            return
        end
        -- Background shutdowns can leave KOReader's connection checks pending.
        NetworkMgr:disableWifi(nil, true)
    end
    if Device.isPocketBook and Device:isPocketBook() then
        -- PocketBook reconnects using firmware-saved networks.
        logger.dbg("PocketBook Wi-Fi power toggle", "wifi_on=", wifi_on)
        local refresh = function() touch_menu:updateItems() end
        if wifi_on then
            return NetworkMgr:toggleWifiOff(refresh, true)
        end
        return NetworkMgr:toggleWifiOn(refresh, false, true)
    end
    if not connected then
        local no_saved = not kindle and not kobo and not wifi_on
            and next(NetworkMgr:getAllSavedNetworks().data) == nil
        logger.dbg("Wi-Fi toggle", "wifi_on=", wifi_on, "connected=", connected,
            "kindle=", kindle, "settings=", settings_subpage == true,
            "open_switcher=", no_saved)
        if no_saved then
            return show_networks()
        end
    end

    logger.dbg("Wi-Fi toggle using KOReader action", "wifi_on=", wifi_on,
        "connected=", connected, "kindle=", kindle)

    local shown_before = {}
    for widget in UIManager:topdown_widgets_iter() do shown_before[widget] = true end

    if kobo and NetworkMgr._zen_nonblocking_wifi and wifi_on and not connected then
        NetworkMgr:toggleWifiOff(function() touch_menu:updateItems() end, true)
    elseif (kindle or kobo and NetworkMgr._zen_nonblocking_wifi) and not connected then
        NetworkMgr:toggleWifiOn(function() touch_menu:updateItems() end, false, true, show_networks)
    else
        NetworkMgr:getWifiMenuTable().callback(touch_menu)
    end

    local NetworkSetting = package.loaded["ui/widget/networksetting"]
    local network_dialog, failure_notice
    for widget in UIManager:topdown_widgets_iter() do
        if not shown_before[widget] then
            if NetworkSetting and getmetatable(widget) == NetworkSetting then
                network_dialog = widget
            elseif widget.text == _("Connection failed") then
                failure_notice = widget
            end
        end
    end
    if kobo then
        local now_on = NetworkMgr:isWifiOn()
        logger.dbg("Kobo toggle result", "wifi_on=", now_on == true,
            "connected=", now_on and NetworkMgr:isConnected() or false,
            "picker=", network_dialog ~= nil,
            "pending_connection=", NetworkMgr.pending_connection == true,
            "pending_check=", NetworkMgr.pending_connectivity_check == true)
    end
    if not network_dialog then return end
    UIManager:close(network_dialog)
    if failure_notice then UIManager:close(failure_notice) end
    if kobo then
        logger.dbg("Kobo picker replaced", "pending_connection=",
            NetworkMgr.pending_connection == true)
    end
    return show_networks()
end

local function is_secured(network)
    local flags = type(network.flags) == "string" and network.flags or ""
    return flags:find("WPA", 1, true) ~= nil or flags:find("SAE", 1, true) ~= nil
end

local function verify_connection(NetworkMgr, ssid, old_ip, address_released, ffiutil, get_ip, reconnecting)
    local saw_released_address = old_ip == nil or address_released
    local last_ip
    local last_ssid
    local saw_target = false
    for _i = 1, VERIFY_ATTEMPTS do
        local ok_ip, ip = pcall(get_ip)
        if ok_ip then last_ip = ip end
        if ok_ip and not ip then saw_released_address = true end
        local ok_current, current = pcall(NetworkMgr.getCurrentNetwork, NetworkMgr)
        if ok_current and current then last_ssid = current.ssid end
        if ok_current and current and current.ssid == ssid then
            saw_target = true
            if ok_ip and ip and (saw_released_address or ip ~= old_ip) then
                return ip
            end
            local ok_route, has_route = pcall(NetworkMgr.hasDefaultRoute, NetworkMgr)
            -- Reconnecting can keep the same DHCP lease or static IP.
            if reconnecting and ok_ip and ip and ok_route and has_route then return ip end
            if saw_released_address and ok_route and has_route then return true end
        end
        ffiutil.usleep(VERIFY_DELAY_US)
    end
    return nil, saw_target and "no_address" or "wrong_network", last_ssid, last_ip
end

function M.open(on_connected, settings_subpage, plugin)
    local Device = require("device")
    local ConfirmBox = require("ui/widget/confirmbox")
    local ButtonDialog = require("ui/widget/buttondialog")
    local Event = require("ui/event")
    local InfoMessage = require("ui/widget/infomessage")
    local InputDialog = require("ui/widget/inputdialog")
    local Menu = require("ui/widget/menu")
    local NetworkMgr = require("ui/network/manager")
    local KindleNetworkAdapter = require("modules/menu/network_adapters/kindle")
    local KoboNetworkAdapter = require("modules/menu/network_adapters/kobo")
    local Size = require("ui/size")
    local UIManager = require("ui/uimanager")
    local IconItem = require("common/ui/icon_menu_item")
    local icons = require("common/inline_icon_map")
    local SettingsTitleBar = require("common/ui/zen_settings_titlebar")
    local utils = require("common/utils")
    local ffiutil = require("ffi/util")
    local logger = require("common/zen_logger").new("network_switcher")
    local get_ip = require("modules/settings/zen_settings_utils").get_device_ip_address
    local _ = require("gettext")
    local T = ffiutil.template
    local plugin_root = require("common/plugin_root")
    local more_icon = utils.resolveLocalIcon(plugin_root and plugin_root .. "/icons/",
        "app_menu")
    local adapter = KindleNetworkAdapter.isSupported(Device)
        and KindleNetworkAdapter.new(NetworkMgr) or nil
    local kobo_adapter = KoboNetworkAdapter.isSupported(Device)
        and KoboNetworkAdapter.new(NetworkMgr, logger) or nil
    local kobo = kobo_adapter ~= nil
    if kobo then
        logger.dbg("Kobo switcher opened", "wifi_on=", NetworkMgr:isWifiOn() == true,
            "connected=", NetworkMgr:isConnected() == true,
            "wifi_was_on=", G_reader_settings:isTrue("wifi_was_on"),
            "pending_connection=", NetworkMgr.pending_connection == true)
    end

    IconItem.installMenuPatch()

    if not adapter and not (Device.hasWifiManager and Device:hasWifiManager()) then
        if type(NetworkMgr.openSettings) == "function" then
            NetworkMgr:openSettings()
            return true
        end
        if Device.isPocketBook and Device:isPocketBook()
                and Device.hasWifiToggle and Device:hasWifiToggle() then
            require("ffi/inkview").OpenBook("/ebrmain/bin/settings.app", nil, 0)
            return true
        end
        UIManager:show(InfoMessage:new{text = _("Network selection is not supported on this device.")})
        return false
    end

    local previous_network
    local previous_ip
    local connected_network
    local restore_started = false
    local closed = false
    local restore_previous_network
    local network_list = {}
    local render_networks
    local show_network_actions
    local start_scan
    local refresh_networks
    local toggle_wifi
    local scanning = false
    local changing_power = false
    local refresh_attempts = 0
    local settings_font_size = IconItem.getSettingsFontSize()

    local function status_items(text)
        return {{
            text = text,
            _zen_settings_row = true,
            _zen_display_text = text,
            select_enabled = false,
        }}
    end

    local menu
    local function close_menu()
        if menu then return menu:onClose() end
    end
    local title_bar = SettingsTitleBar:new{
        back_callback = close_menu,
        back_hold_callback = close_menu,
        back_visible = settings_subpage == true,
        close_visible = settings_subpage ~= true,
        close_callback = close_menu,
        plugin = plugin,
        search_visible = false,
        title = _("Wi-Fi networks"),
        title_full_width = true,
        action = {
            file = utils.resolveLocalIcon(plugin_root and plugin_root .. "/icons/", "quick_sync"),
            callback = function() start_scan() end,
        },
        toggle = {
            value_func = function() return NetworkMgr:isWifiOn() end,
            callback = function() toggle_wifi() end,
        },
    }
    menu = Menu:new{
        name = "network_switcher",
        title = _("Wi-Fi networks"),
        custom_title_bar = title_bar,
        item_table = status_items(_("Searching for networks…")),
        items_per_page = 8,
        items_font_size = settings_font_size,
        items_mandatory_font_size = math.max(12, settings_font_size - 4),
        is_borderless = true,
        is_popout = false,
        close_callback = function()
            title_bar:clearStatusRefresh()
            closed = true
            UIManager:unschedule(refresh_networks)
            if adapter then adapter.close() end
        end,
    }
    title_bar:clearStatusRefresh()
    title_bar.show_parent = menu
    title_bar:clear()
    title_bar:init()
    title_bar.root_icon.skip_paint = true
    if settings_subpage then
        local menu_on_swipe = menu.onSwipe
        menu.onSwipe = function(self, arg, ges_ev)
            if ges_ev and ges_ev.direction == "east" and ges_ev.pos
                    and ges_ev.pos.x <= self.dimen.w * 0.33 then
                return self:onClose()
            end
            if menu_on_swipe then return menu_on_swipe(self, arg, ges_ev) end
        end
    end
    menu.onMenuSelect = function(self, item, pos)
        if item.select_enabled == false then return true end
        if item.network and pos and pos.x >= 0.8 then
            show_network_actions(item.network)
            return true
        end
        self:onMenuChoice(item)
        return true
    end
    menu.onMenuHold = function(self, item)
        if item and item.network then
            show_network_actions(item.network)
            return true
        end
        if item and item.hold_callback then item.hold_callback(self, item) end
        return true
    end

    local function show_status(text)
        if closed then return end
        menu:switchItemTable(nil, status_items(text))
        UIManager:forceRePaint()
    end

    local function turn_on_wifi()
        if NetworkMgr:isWifiOn() then return true end
        local reconnect = NetworkMgr.reconnectOrShowNetworkMenu
        NetworkMgr.reconnectOrShowNetworkMenu = function() return true end
        local ok_turn_on, status = pcall(NetworkMgr.turnOnWifi, NetworkMgr)
        NetworkMgr.reconnectOrShowNetworkMenu = reconnect
        if ok_turn_on and status ~= false then return true end
        return false, ok_turn_on and _("Could not turn on Wi-Fi.") or tostring(status)
    end

    local function run_async(action, callback, queued_only)
        if NetworkMgr.runWifiAsync then return NetworkMgr:runWifiAsync(action, callback, queued_only) end
        return callback(action())
    end

    local function disconnect_profile(network, preserve)
        if kobo_adapter then return kobo_adapter.disconnect(network, preserve) end
        return NetworkMgr:disconnectNetwork(network)
    end

    local disconnect_network
    local function forget_network(network)
        if kobo then
            local saved = NetworkMgr:getAllSavedNetworks():readSetting(network.ssid)
            logger.dbg("Kobo forget requested", "connected=", network.connected == true,
                "saved=", saved ~= nil,
                "supplicant_id=", network.wpa_supplicant_id ~= nil)
        end
        local kobo_removed
        if adapter then
            local deleted, delete_error = adapter.forgetNetwork(network)
            if not deleted then
                logger.warn("could not forget Wi-Fi profile", "error_present=", delete_error ~= nil)
                show_status(_("Could not forget the Wi-Fi network."))
                return false
            end
        elseif kobo then
            local deleted, delete_error
            deleted, delete_error, kobo_removed = kobo_adapter.forgetNetwork(network)
            if not deleted then
                logger.warn("could not forget Kobo Wi-Fi profile", "error_present=", delete_error ~= nil)
                UIManager:show(InfoMessage:new{text = _("Could not forget the Wi-Fi network.")})
                return false
            end
        end
        if not adapter and network.connected
                and not disconnect_network(network, true, kobo_removed) then
            return false
        end
        NetworkMgr:deleteNetwork(network)
        network.password = nil
        network.psk = nil
        network.saved = nil
        if kobo then network.kobo_configured = kobo_adapter.profileId(network.ssid) ~= nil end
        if previous_network and previous_network.ssid == network.ssid then
            previous_network = nil
        end
        if connected_network and connected_network.ssid == network.ssid then
            connected_network = nil
        end
        network.connected = false
        logger.dbg("Wi-Fi network forgotten")
        if kobo then
            logger.dbg("Kobo forget result",
                "saved=", NetworkMgr:getAllSavedNetworks():readSetting(network.ssid) ~= nil,
                "connected=", NetworkMgr:isConnected() == true)
        end
        render_networks(network.ssid)
        if on_connected then on_connected() end
        return true
    end

    restore_previous_network = function()
        if restore_started or not previous_network then return end
        local ok_current, current = pcall(NetworkMgr.getCurrentNetwork, NetworkMgr)
        if ok_current and current and current.ssid == previous_network.ssid then return end
        restore_started = true
        logger.dbg("restoring previous network")
        show_status(T(_("Restoring %1…"), previous_network.ssid))
        UIManager:broadcastEvent(Event:new("NetworkConnecting"))
        run_async(function()
            local authenticated
            if kobo_adapter then
                authenticated = kobo_adapter.connect(previous_network)
            else
                authenticated = NetworkMgr:authenticateNetwork(previous_network)
            end
            if authenticated then NetworkMgr:obtainIP() end
            return authenticated
        end, function(authenticated)
            if authenticated then
                if type(NetworkMgr.scheduleConnectivityCheck) == "function" then
                    NetworkMgr:scheduleConnectivityCheck(function()
                        show_status(T(_("Connected to %1."), previous_network.ssid))
                    end)
                end
            else
                logger.warn("could not restore previous network")
            end
        end)
    end

    local prompt_password
    local function perform_connection(network, use_password, switching)
        if adapter and use_password then
            local replaced = adapter.replaceNetwork(network)
            if not replaced then
                logger.warn("could not replace Wi-Fi profile")
                return { profile_error = true }
            end
        end
        local powered_on, power_error = turn_on_wifi()
        if not powered_on then
            logger.warn("could not turn on Wi-Fi for connection")
            return { power_error = power_error }
        end
        local ok_active, active = pcall(NetworkMgr.getCurrentNetwork, NetworkMgr)
        local reconnecting = ok_active and active and active.ssid == network.ssid
        local old_ip = previous_ip or get_ip()
        local address_released = get_ip() == nil

        if switching then
            disconnect_profile(connected_network, true)
            NetworkMgr:releaseIP()
            NetworkMgr.lease_ssid = nil
            address_released = get_ip() == nil
            reconnecting = false
        end

        local authenticated, auth_error
        if adapter then
            authenticated, auth_error = adapter.connect(network)
        elseif kobo_adapter then
            authenticated, auth_error = kobo_adapter.connect(network, use_password)
        else
            authenticated, auth_error = NetworkMgr:authenticateNetwork(network)
        end
        logger.dbg("authentication request completed", "accepted=", authenticated == true,
            "error_present=", authenticated ~= true and auth_error ~= nil)
        if authenticated then NetworkMgr:obtainIP() end
        local connection, failure, actual_ssid, actual_ip
        if authenticated then
            connection, failure, actual_ssid, actual_ip = verify_connection(
                NetworkMgr, network.ssid, old_ip, address_released, ffiutil, get_ip, reconnecting
            )
        else
            failure = "authentication"
        end
        return {
            connection = connection, failure = failure, auth_error = auth_error,
            actual_ssid = actual_ssid, actual_ip = actual_ip,
            psk = network.psk, wpa_supplicant_id = network.wpa_supplicant_id,
        }
    end

    local function complete_connection(network, switching, result, worker_error)
        if not result or result.power_error then
            local reason = worker_error or result and result.power_error or _("Connection failed")
            show_status(reason)
            return false, reason
        end
        if result.profile_error then
            local reason = _("Could not replace the saved Wi-Fi password.")
            if not closed then prompt_password(network, reason) end
            return false, reason
        end
        if switching then
            UIManager:broadcastEvent(Event:new("NetworkDisconnected"))
            UIManager:broadcastEvent(Event:new("NetworkConnecting"))
        end
        network.psk = result.psk or network.psk
        network.wpa_supplicant_id = result.wpa_supplicant_id or network.wpa_supplicant_id
        local connection, failure, actual_ssid, actual_ip = result.connection, result.failure,
            result.actual_ssid, result.actual_ip

        if not connection then
            if closed then return false end
            local reason = failure == "authentication" and result.auth_error
            if type(reason) ~= "string" or reason == "" then
                if failure == "no_address" then
                    reason = T(_("Connected to %1, but no IP address or default route was assigned."),
                        network.ssid)
                elseif actual_ssid and actual_ssid ~= "" then
                    reason = T(_("Connected to %1 instead of %2. The password may be incorrect."),
                        actual_ssid, network.ssid)
                else
                    reason = _("Authentication failed. The password may be incorrect.")
                end
            end
            logger.warn("connection failed", "reason=", failure,
                "target_matched=", actual_ssid == network.ssid, "ip_assigned=", actual_ip ~= nil)
            if is_secured(network) and failure ~= "no_address"
                    and (not kobo or result.auth_error == _("Failed to authenticate")) then
                prompt_password(network, reason)
            else
                restore_previous_network()
                show_status(reason)
            end
            return false, reason
        end

        NetworkMgr.lease_ssid = network.ssid
        if type(NetworkMgr.queryNetworkState) == "function" then NetworkMgr:queryNetworkState() end
        NetworkMgr.wifi_was_on = true
        G_reader_settings:saveSetting("wifi_was_on", true)
        UIManager:broadcastEvent(Event:new("NetworkConnected"))
        logger.dbg("connection verified", "ip_assigned=", type(connection) == "string")
        if kobo then
            local saved = NetworkMgr:getAllSavedNetworks():readSetting(network.ssid)
            logger.dbg("Kobo connection result",
                "saved=", saved ~= nil, "saved_password=", saved ~= nil and saved.password ~= nil,
                "saved_psk=", saved ~= nil and saved.psk ~= nil,
                "wifi_was_on=", G_reader_settings:isTrue("wifi_was_on"))
            if logger.isEnabled("dbg") then
                UIManager:scheduleIn(3, function()
                    local ok_current, current = pcall(NetworkMgr.getCurrentNetwork, NetworkMgr)
                    local ok_route, route = pcall(NetworkMgr.hasDefaultRoute, NetworkMgr)
                    logger.dbg("Kobo connection follow-up",
                        "wifi_on=", NetworkMgr:isWifiOn() == true,
                        "connected=", NetworkMgr:isConnected() == true,
                        "target_matched=", ok_current and current ~= nil and current.ssid == network.ssid,
                        "ip_assigned=", get_ip() ~= nil,
                        "route_check_ok=", ok_route, "default_route=", route == true,
                        "lease_matched=", NetworkMgr.lease_ssid == network.ssid)
                end)
            end
        end
        for _i, candidate in ipairs(network_list) do
            candidate.connected = candidate.ssid == network.ssid
        end
        connected_network = network
        previous_network = network
        previous_ip = type(connection) == "string" and connection or get_ip()
        restore_started = false
        render_networks(network.ssid)
        if on_connected then
            on_connected(network, type(connection) == "string" and connection or nil)
        end
        return true
    end

    local function connect(network, use_password)
        show_status(_("Connecting to ") .. network.ssid .. "…")
        logger.dbg("connection attempt", "saved_credentials=", network.password ~= nil)
        if kobo then
            local saved = NetworkMgr:getAllSavedNetworks():readSetting(network.ssid)
            logger.dbg("Kobo credentials before auth",
                "row_psk=", network.psk ~= nil,
                "stored_password=", saved ~= nil and saved.password ~= nil,
                "stored_psk=", saved ~= nil and saved.psk ~= nil)
        end
        if not NetworkMgr:isWifiOn() and NetworkMgr.showWifiStarting then NetworkMgr:showWifiStarting() end
        local switching = not adapter and connected_network
            and connected_network.ssid ~= network.ssid
        if switching then
            UIManager:broadcastEvent(Event:new("NetworkDisconnecting"))
            NetworkMgr.lease_ssid = nil
        else
            UIManager:broadcastEvent(Event:new("NetworkConnecting"))
        end
        return run_async(function()
            return perform_connection(network, use_password, switching)
        end, function(result, worker_error)
            local connected, reason = complete_connection(network, switching, result, worker_error)
            if connected and NetworkMgr.showWifiConnected then
                NetworkMgr:showWifiConnected(network.ssid)
            elseif NetworkMgr.showWifiNotice then
                NetworkMgr:showWifiNotice(connected and T(_("Connected to %1."):gsub("%.$", ""):gsub("。$", ""), network.ssid)
                    or reason or _("Error connecting to the network"), reason and 8 or 2)
            end
            return connected
        end)
    end

    prompt_password = function(network, reason)
        logger.dbg("password requested", "retry=", reason ~= nil)
        local dialog
        local buttons = {
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                    restore_previous_network()
                end,
            },
        }
        if network.password ~= nil or network.kobo_configured then
            buttons[#buttons + 1] = {
                text = _("Forget"),
                callback = function()
                    UIManager:close(dialog)
                    forget_network(network)
                end,
            }
        end
        buttons[#buttons + 1] = {
            text = _("Connect"),
            is_enter_default = true,
            callback = function()
                local password = dialog:getInputText() or ""
                if password == "" and is_secured(network) then
                    UIManager:show(InfoMessage:new{text = _("Password cannot be empty.")})
                    return
                end
                network.password = password
                network.psk = nil
                if not adapter then
                    NetworkMgr:saveNetwork(network)
                    if kobo then
                        logger.dbg("Kobo credentials saved",
                            "stored=", NetworkMgr:getAllSavedNetworks():readSetting(network.ssid) ~= nil)
                    end
                end
                UIManager:close(dialog)
                connect(network, true)
            end,
        }
        dialog = InputDialog:new{
            title = network.ssid,
            description = reason,
            input = network.password or "",
            input_hint = _("password (leave empty for open networks)"),
            input_type = "text",
            text_type = "password",
            buttons = {buttons},
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end

    local function show_network_info(network)
        local quality = tonumber(network.signal_quality)
        local flags = type(network.flags) == "string" and network.flags or ""
        local lines = {
            _("Network") .. ": " .. network.ssid,
            _("Status") .. ": " .. (network.connected and _("Connected")
                or (network.password ~= nil or network.kobo_configured) and _("Saved")
                or _("Available")),
            _("Signal") .. ": " .. (quality and tostring(math.floor(quality)) .. "%" or "—"),
            _("Security") .. ": " .. (flags ~= "" and flags or _("Open")),
        }
        if network.connected then
            lines[#lines + 1] = _("IP address") .. ": " .. (get_ip() or "—")
            local interface = NetworkMgr.interface
            if not interface and type(NetworkMgr.getNetworkInterfaceName) == "function" then
                local ok_interface, value = pcall(
                    NetworkMgr.getNetworkInterfaceName, NetworkMgr)
                if ok_interface then interface = value end
            end
            if interface then
                lines[#lines + 1] = _("Interface") .. ": " .. tostring(interface)
            end
            if type(NetworkMgr.hasDefaultRoute) == "function" then
                local ok_route, has_route = pcall(NetworkMgr.hasDefaultRoute, NetworkMgr)
                if ok_route then
                    lines[#lines + 1] = _("Default route") .. ": "
                        .. (has_route and _("Yes") or _("No"))
                end
            end
        end
        UIManager:show(InfoMessage:new{text = table.concat(lines, "\n")})
    end

    disconnect_network = function(network, quiet, profile_removed)
        UIManager:broadcastEvent(Event:new("NetworkDisconnecting"))
        local ok_disconnect, status, disconnect_error
        if adapter then
            ok_disconnect, status = adapter.disconnect(network)
        elseif profile_removed then
            ok_disconnect, status = true, true
        else
            ok_disconnect, status, disconnect_error = pcall(
                disconnect_profile, network, not quiet)
        end
        if not ok_disconnect or status == false or disconnect_error then
            local reason = disconnect_error or (ok_disconnect and _("Could not disconnect from the Wi-Fi network."))
                or tostring(status)
            logger.warn("could not disconnect Wi-Fi", "request_completed=", ok_disconnect,
                "accepted=", status == true, "error_present=", disconnect_error ~= nil)
            UIManager:show(InfoMessage:new{text = reason})
            return false
        end
        NetworkMgr:releaseIP()
        NetworkMgr.lease_ssid = nil
        for _i, candidate in ipairs(network_list) do candidate.connected = false end
        connected_network = nil
        previous_network = nil
        previous_ip = nil
        restore_started = true
        if type(NetworkMgr.queryNetworkState) == "function" then NetworkMgr:queryNetworkState() end
        UIManager:broadcastEvent(Event:new("NetworkDisconnected"))
        logger.dbg("Wi-Fi disconnected")
        if kobo then
            local saved = NetworkMgr:getAllSavedNetworks():readSetting(network.ssid)
            logger.dbg("Kobo disconnect result",
                "row_password=", network.password ~= nil,
                "saved_password=", saved ~= nil and saved.password ~= nil)
        end
        if not quiet then
            render_networks(network.ssid)
            if on_connected then on_connected() end
        end
        return true
    end

    show_network_actions = function(network)
        local dialog
        local buttons = {}
        local function add(text, callback)
            buttons[#buttons + 1] = {{
                text = text,
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    callback()
                end,
            }}
        end
        add(icons.details .. "  " .. _("Info"), function()
            show_network_info(network)
        end)
        if is_secured(network) then
            add(icons.edit .. "  " .. _("Edit"), function()
                prompt_password(network, _("Enter a new Wi-Fi password."))
            end)
        end
        if network.connected then
            add(icons.wifi_off .. "  " .. _("Disconnect"), function()
                disconnect_network(network)
            end)
        end
        if network.password ~= nil or network.saved or network.kobo_configured then
            add(icons.delete .. "  " .. _("Forget"), function()
                UIManager:show(ConfirmBox:new{
                    text = T(_("Forget Wi-Fi network %1?"), network.ssid),
                    ok_text = _("Forget"),
                    ok_callback = function() forget_network(network) end,
                })
            end)
        end
        dialog = ButtonDialog:new{
            title = network.ssid,
            buttons = buttons,
            width_factor = 0.5,
            anchor = function()
                for _i, row in ipairs(menu.item_group or {}) do
                    if row.entry and row.entry.network == network
                            and menu.dimen and menu.item_dimen then
                        local popup = dialog:getContentSize()
                        local inset = Size.padding.large + Size.padding.default
                        local border = menu.border_size or 0
                        local header_h = menu.title_bar
                            and menu.title_bar:getSize().h or 0
                        local row_x = (menu.dimen.x or 0) + border
                        local row_y = (menu.dimen.y or 0) + border + header_h
                            + (_i - 1) * menu.item_dimen.h
                        local icon_size = IconItem.SETTINGS_CARET_SIZE
                        local icon_x = row_x + menu.item_dimen.w - inset - icon_size
                        local icon_y = row_y
                            + math.floor((menu.item_dimen.h - icon_size) / 2)
                        return {
                            x = math.max(Size.padding.large,
                                icon_x + icon_size - popup.w - Size.padding.default),
                            y = icon_y,
                            w = icon_size,
                            h = icon_size,
                        }, true
                    end
                end
            end,
        }
        UIManager:show(dialog)
    end

    render_networks = function(selected_ssid)
        if closed then return end
        connected_network = nil
        local items = {}
        local selected_index
        for _i, network in ipairs(network_list) do
            if network.connected then connected_network = network end
            if type(network.ssid) == "string" and network.ssid ~= "" then
                local quality = tonumber(network.signal_quality)
                local status = network.connected and _("Connected")
                    or (network.password ~= nil or network.kobo_configured) and _("Saved") or nil
                local signal = quality and tostring(math.floor(quality)) .. "%" or nil
                local item = {
                    text = network.ssid,
                    network = network,
                    network_ssid = network.ssid,
                    _zen_settings_row = true,
                    _zen_display_text = network.ssid,
                    _zen_settings_breadcrumb = status and signal and status .. " · " .. signal
                        or status or signal or _("Available"),
                    _zen_value_black = true,
                    _zen_primary_bold = network.connected == true,
                    _zen_has_submenu = true,
                    _zen_caret_icon = more_icon,
                    icon_glyph = network.connected and icons.wifi_on or nil,
                    callback = function()
                        if type(network.flags) == "string"
                                and network.flags:find("WEP", 1, true) then
                            restore_previous_network()
                            show_status(_("Networks with WEP encryption are not supported."))
                        elseif network.connected then
                            show_network_actions(network)
                        elseif network.password == nil
                                and not (kobo_adapter and kobo_adapter.profileId(network.ssid)) then
                            prompt_password(network)
                        else
                            connect(network)
                        end
                    end,
                }
                items[#items + 1] = item
                if network.ssid == selected_ssid then selected_index = #items end
            end
        end
        if #items == 0 then
            restore_previous_network()
            show_status(_("No Wi-Fi networks found."))
            return
        end
        menu:switchItemTable(nil, items, selected_index)
    end

    local function scan_networks()
        if closed or not scanning then return end
        show_status(_("Searching for networks…"))

        if adapter and not previous_network then
            local ok_current, current = pcall(NetworkMgr.getCurrentNetwork, NetworkMgr)
            if ok_current and current and current.ssid and current.ssid ~= "" then
                previous_network = current
                previous_ip = get_ip()
                logger.dbg("remembering current Wi-Fi", "ip_assigned=", previous_ip ~= nil)
            end
        end

        logger.dbg("scan started", "adapter=", adapter and adapter.id)
        local function load_results(scanned, result, worker_error)
            if closed or not scanning then return end
            scanning = false
            if scanned == false then
                logger.warn("adapter scan failed")
                show_status(_("Scanning for Wi-Fi networks timed out."))
                return
            end
            local scanned_networks, scan_error
            if adapter then
                scanned_networks, scan_error = adapter.getNetworkList()
            elseif result then
                scanned_networks, scan_error = result.networks, result.error
            elseif worker_error then
                scan_error = worker_error
            elseif kobo_adapter then
                scanned_networks, scan_error = kobo_adapter.getNetworkList()
            else
                scanned_networks, scan_error = NetworkMgr:getNetworkList()
            end
            if closed then return end
            if not scanned_networks then
                logger.warn("scan failed")
                restore_previous_network()
                show_status(scan_error or _("Could not scan Wi-Fi networks."))
                return
            end
            network_list = scanned_networks
            table.sort(network_list, function(left, right)
                return (tonumber(left.signal_quality) or 0) > (tonumber(right.signal_quality) or 0)
            end)
            logger.dbg("scan complete", "networks=", #network_list)
            if kobo_adapter then network_list = kobo_adapter.annotateScan(network_list) end
            render_networks()
        end
        if adapter then
            adapter.scan(load_results)
        elseif kobo_adapter and NetworkMgr.runWifiAsync then
            run_async(function()
                local networks, err = kobo_adapter.getNetworkList()
                return { networks = networks, error = err }
            end, function(result, err)
                load_results(true, result, err or not result and _("Scanning for Wi-Fi networks timed out."))
            end, true)
        else
            load_results(true)
        end
    end

    start_scan = function()
        if closed or scanning or changing_power then return end
        UIManager:unschedule(refresh_networks)
        scanning = true
        if NetworkMgr:isWifiOn() then
            scan_networks()
            return
        end

        show_status(_("Turning on Wi-Fi…"))
        if NetworkMgr.showWifiStarting then NetworkMgr:showWifiStarting() end
        logger.dbg("turning on Wi-Fi for scan")
        run_async(function()
            local powered_on, reason = turn_on_wifi()
            return { powered_on = powered_on, reason = reason }
        end, function(result, worker_error)
            if closed or not scanning then return end
            if not result or not result.powered_on then
                scanning = false
                local reason = worker_error or result and result.reason or _("Could not turn on Wi-Fi.")
                logger.warn("could not turn on Wi-Fi for scan")
                show_status(reason)
                if NetworkMgr.showWifiNotice then NetworkMgr:showWifiNotice(_("Error connecting to the network")) end
                return
            end
            UIManager:nextTick(scan_networks)
        end)
    end

    toggle_wifi = function()
        if closed or changing_power then return end
        UIManager:unschedule(refresh_networks)
        scanning = false
        refresh_attempts = 0
        if not NetworkMgr:isWifiOn() then
            changing_power = true
            show_status(_("Turning on Wi-Fi…"))
            local refreshed = false
            local function refresh()
                refreshed = true
                changing_power = false
                if closed then return end
                refresh_networks()
                if on_connected then on_connected() end
            end
            M.toggleWifi({ updateItems = refresh }, on_connected, settings_subpage, plugin, refresh)
            changing_power = false
            if not refreshed and not NetworkMgr.pending_connection then
                if NetworkMgr:isWifiOn() then refresh() else show_status(_("Off")) end
            end
            return
        end
        changing_power = true
        if adapter then
            adapter.close()
            adapter = KindleNetworkAdapter.new(NetworkMgr)
        end
        NetworkMgr:toggleWifiOff(function()
            changing_power = false
            if closed then return end
            if NetworkMgr:isWifiOn() then
                render_networks()
            else
                network_list = {}
                previous_network, previous_ip, connected_network = nil, nil, nil
                restore_started = true
                show_status(_("Off"))
            end
            if menu._zen_status_refresh then menu:_zen_status_refresh() end
            if on_connected then on_connected() end
        end, true)
    end

    refresh_networks = function(external_change)
        if closed or scanning or changing_power then return end
        UIManager:unschedule(refresh_networks)
        if NetworkMgr:isWifiOn() then
            local has_connection_check = type(NetworkMgr.isConnected) == "function"
            local connected = has_connection_check and NetworkMgr:isConnected()
            local ok_current, current = pcall(NetworkMgr.getCurrentNetwork, NetworkMgr)
            local has_ssid = ok_current and current and type(current.ssid) == "string"
                and current.ssid ~= ""
            if connected or (not has_connection_check and has_ssid) then
                if has_ssid then
                    refresh_attempts = 0
                    if adapter then
                        previous_network = current
                        previous_ip = get_ip()
                    end
                    if external_change then
                        restore_started = false
                        local found = false
                        for _i, network in ipairs(network_list) do
                            network.connected = network.ssid == current.ssid
                            found = found or network.connected
                        end
                        if found then
                            render_networks(current.ssid)
                            return
                        end
                    end
                    local saved = adapter and adapter.getSavedNetwork(current.ssid)
                        or NetworkMgr:getAllSavedNetworks():readSetting(current.ssid)
                    if kobo then
                        logger.dbg("Kobo active network",
                            "saved=", saved ~= nil, "saved_password=", saved ~= nil and saved.password ~= nil,
                            "supplicant_id=", (current.wpa_supplicant_id or current.id) ~= nil)
                    end
                    network_list = {{
                        ssid = current.ssid,
                        connected = true,
                        flags = saved and saved.flags or current.flags,
                        password = saved and saved.password or current.password,
                        psk = saved and saved.psk or current.psk,
                        saved = saved ~= nil,
                        kobo_configured = kobo and kobo_adapter.profileId(current.ssid) ~= nil,
                        wpa_supplicant_id = current.wpa_supplicant_id or current.id,
                    }}
                    render_networks()
                else
                    if refresh_attempts == 0 then show_status(_("Connected")) end
                    -- Kindle can report an address before wifid publishes the SSID.
                    if adapter and refresh_attempts < NETWORK_NAME_RETRIES then
                        refresh_attempts = refresh_attempts + 1
                        UIManager:scheduleIn(5 / NETWORK_NAME_RETRIES, refresh_networks)
                    end
                end
                return
            end
        end
        if external_change then
            previous_network, previous_ip, connected_network = nil, nil, nil
            restore_started = true
            if not NetworkMgr:isWifiOn() then
                network_list = {}
                show_status(_("Off"))
            elseif #network_list > 0 then
                for _i, network in ipairs(network_list) do network.connected = false end
                render_networks()
            else
                menu:updateItems()
            end
            return
        end
        start_scan()
    end
    menu.onNetworkConnected = function()
        if closed then return end
        for widget in UIManager:topdown_widgets_iter() do
            if not widget.toast and not widget.invisible then
                if widget == menu then
                    UIManager:setDirty(menu, "ui", menu.dimen)
                    refresh_networks(true)
                end
                return
            end
        end
    end
    menu.onNetworkDisconnected = menu.onNetworkConnected
    menu.onNetworkStateChanged = menu.onNetworkConnected
    UIManager:show(menu)
    UIManager:forceRePaint()
    UIManager:tickAfterNext(refresh_networks)
    return true
end

return M
