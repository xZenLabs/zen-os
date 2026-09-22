local M = {}

local VERIFY_ATTEMPTS = 60
local VERIFY_DELAY_US = 250 * 1000

local function is_secured(network)
    local flags = type(network.flags) == "string" and network.flags or ""
    return flags:find("WPA", 1, true) ~= nil or flags:find("SAE", 1, true) ~= nil
end

local function verify_connection(NetworkMgr, ssid, old_ip, address_released, ffiutil, get_ip)
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

    IconItem.installMenuPatch()

    if not adapter and not (Device.hasWifiManager and Device:hasWifiManager()) then
        if type(NetworkMgr.openSettings) == "function" then
            NetworkMgr:openSettings()
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
        close_callback = close_menu,
        plugin = plugin,
        search_visible = false,
        title = _("Wi-Fi networks"),
        title_full_width = true,
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

    local function forget_network(network)
        if adapter then
            local deleted, delete_error = adapter.forgetNetwork(network)
            if not deleted then
                logger.warn("could not forget Wi-Fi profile",
                    "ssid=", network.ssid, "error=", delete_error)
                show_status(_("Could not forget the Wi-Fi network."))
                return false
            end
        end
        NetworkMgr:deleteNetwork(network)
        network.password = nil
        network.psk = nil
        if previous_network and previous_network.ssid == network.ssid then
            previous_network = nil
        end
        if connected_network and connected_network.ssid == network.ssid then
            connected_network = nil
        end
        network.connected = false
        logger.dbg("Wi-Fi network forgotten", "ssid=", network.ssid)
        render_networks(network.ssid)
        if on_connected then on_connected() end
        return true
    end

    restore_previous_network = function()
        if restore_started or not previous_network then return end
        local ok_current, current = pcall(NetworkMgr.getCurrentNetwork, NetworkMgr)
        if ok_current and current and current.ssid == previous_network.ssid then return end
        restore_started = true
        logger.dbg("restoring previous network", "ssid=", previous_network.ssid)
        show_status(T(_("Restoring %1…"), previous_network.ssid))
        UIManager:broadcastEvent(Event:new("NetworkConnecting"))
        local authenticated = NetworkMgr:authenticateNetwork(previous_network)
        if authenticated then
            NetworkMgr:obtainIP()
            if type(NetworkMgr.scheduleConnectivityCheck) == "function" then
                NetworkMgr:scheduleConnectivityCheck(function()
                    show_status(T(_("Connected to %1."), previous_network.ssid))
                end)
            end
        else
            logger.warn("could not restore previous network", "ssid=", previous_network.ssid)
        end
    end

    local prompt_password
    local function connect(network)
        show_status(_("Connecting to ") .. network.ssid .. "…")
        logger.dbg("connection attempt", "ssid=", network.ssid,
            "saved_credentials=", network.password ~= nil)
        local powered_on, power_error = turn_on_wifi()
        if not powered_on then
            logger.warn("could not turn on Wi-Fi for connection", power_error)
            show_status(power_error)
            return false
        end
        local old_ip = previous_ip or get_ip()
        local address_released = get_ip() == nil

        if not adapter and connected_network
                and connected_network.ssid ~= network.ssid then
            UIManager:broadcastEvent(Event:new("NetworkDisconnecting"))
            NetworkMgr:disconnectNetwork(connected_network)
            NetworkMgr:releaseIP()
            NetworkMgr.lease_ssid = nil
            address_released = get_ip() == nil
            UIManager:broadcastEvent(Event:new("NetworkDisconnected"))
        end

        UIManager:broadcastEvent(Event:new("NetworkConnecting"))
        local authenticated, auth_error
        if adapter then
            authenticated, auth_error = adapter.connect(network)
        else
            authenticated, auth_error = NetworkMgr:authenticateNetwork(network)
        end
        logger.dbg("authentication request completed", "ssid=", network.ssid,
            "accepted=", authenticated == true, "error=", auth_error)
        if authenticated then NetworkMgr:obtainIP() end
        local connection, failure, actual_ssid, actual_ip
        if authenticated then
            connection, failure, actual_ssid, actual_ip = verify_connection(
                NetworkMgr, network.ssid, old_ip, address_released, ffiutil, get_ip
            )
        else
            failure = "authentication"
        end

        if not connection then
            local reason = auth_error
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
            logger.warn("connection failed", "ssid=", network.ssid, "reason=", reason,
                "actual_ssid=", actual_ssid, "actual_ip=", actual_ip)
            if is_secured(network) and failure ~= "no_address" then
                prompt_password(network, reason)
            else
                restore_previous_network()
                show_status(reason)
            end
            return false
        end

        NetworkMgr.lease_ssid = network.ssid
        if type(NetworkMgr.queryNetworkState) == "function" then NetworkMgr:queryNetworkState() end
        UIManager:broadcastEvent(Event:new("NetworkConnected"))
        logger.dbg("connection verified", "ssid=", network.ssid,
            "ip=", type(connection) == "string" and connection or nil)
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

    prompt_password = function(network, reason)
        logger.dbg("password requested", "ssid=", network.ssid,
            "retry=", reason ~= nil)
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
        if network.password ~= nil then
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
                if adapter then
                    local replaced, replace_error = adapter.replaceNetwork(network)
                    if not replaced then
                        logger.warn("could not replace Wi-Fi profile",
                            "ssid=", network.ssid, "error=", replace_error)
                        UIManager:show(InfoMessage:new{
                            text = _("Could not replace the saved Wi-Fi password."),
                        })
                        return
                    end
                else
                    NetworkMgr:saveNetwork(network)
                end
                UIManager:close(dialog)
                connect(network)
            end,
        }
        dialog = InputDialog:new{
            title = network.ssid,
            description = reason,
            input = "",
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
                or network.password ~= nil and _("Saved") or _("Available")),
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

    local function disconnect_network(network)
        UIManager:broadcastEvent(Event:new("NetworkDisconnecting"))
        local ok_disconnect, status
        if adapter then
            ok_disconnect, status = adapter.disconnect(network)
        else
            ok_disconnect, status = pcall(NetworkMgr.disconnectNetwork, NetworkMgr, network)
        end
        if not ok_disconnect or status == false then
            local reason = ok_disconnect and _("Could not disconnect from the Wi-Fi network.")
                or tostring(status)
            logger.warn("could not disconnect Wi-Fi", "ssid=", network.ssid,
                "error=", reason)
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
        logger.dbg("Wi-Fi disconnected", "ssid=", network.ssid)
        render_networks(network.ssid)
        if on_connected then on_connected() end
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
        if network.password ~= nil then
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
                        }
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
                    or network.password ~= nil and _("Saved") or nil
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
                        elseif network.password == nil then
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

    local start_scan
    local function scan_networks()
        if closed then return end
        show_status(_("Searching for networks…"))

        if adapter and not previous_network then
            local ok_current, current = pcall(NetworkMgr.getCurrentNetwork, NetworkMgr)
            if ok_current and current and current.ssid and current.ssid ~= "" then
                previous_network = current
                previous_ip = get_ip()
                logger.dbg("remembering current Wi-Fi", "ssid=", current.ssid,
                    "ip=", previous_ip)
            end
        end

        logger.dbg("scan started", "adapter=", adapter and adapter.id)
        local function load_results(scanned, scan_error)
            if closed then return end
            if scanned == false then
                logger.warn("adapter scan failed", scan_error)
                show_status(_("Scanning for Wi-Fi networks timed out."))
                return
            end
            local scanned_networks
            if adapter then
                scanned_networks, scan_error = adapter.getNetworkList()
            else
                scanned_networks, scan_error = NetworkMgr:getNetworkList()
            end
            if closed then return end
            if not scanned_networks then
                logger.warn("scan failed", scan_error)
                restore_previous_network()
                show_status(scan_error or _("Could not scan Wi-Fi networks."))
                return
            end
            network_list = scanned_networks
            table.sort(network_list, function(left, right)
                return (tonumber(left.signal_quality) or 0) > (tonumber(right.signal_quality) or 0)
            end)
            logger.dbg("scan complete", "networks=", #network_list)
            render_networks()
        end
        if adapter then adapter.scan(load_results) else load_results(true) end
    end

    start_scan = function()
        if closed then return end
        if NetworkMgr:isWifiOn() then
            scan_networks()
            return
        end

        show_status(_("Turning on Wi-Fi…"))
        logger.dbg("turning on Wi-Fi for scan")
        local powered_on, reason = turn_on_wifi()
        if not powered_on then
            logger.warn("could not turn on Wi-Fi for scan", reason)
            show_status(reason)
            return
        end
        UIManager:nextTick(scan_networks)
    end

    UIManager:show(menu)
    UIManager:forceRePaint()
    UIManager:tickAfterNext(start_scan)
    return true
end

return M
