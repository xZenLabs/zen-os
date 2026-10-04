local M = {}

function M.isSupported(Device)
    return Device.isKobo and Device:isKobo()
end

function M.install(NetworkMgr)
    if NetworkMgr._zen_kobo_authenticate then return end
    NetworkMgr._zen_kobo_authenticate = NetworkMgr.authenticateNetwork
    local logger = require("common/zen_logger").new("kobo")
    local adapter = M.new(NetworkMgr, logger)
    NetworkMgr.authenticateNetwork = function(_self, network)
        return adapter.connect(network, true)
    end
    local getCurrentNetwork = NetworkMgr.getCurrentNetwork
    NetworkMgr.getCurrentNetwork = function(self)
        local network, err = getCurrentNetwork(self)
        if not network or not network.flags then return network, err end
        -- KOReader's [CURRENT] fallback also returns profiles still associating.
        local wcli, client_error = require("lj-wpaclient/wpaclient").new(self.wpa_supplicant.ctrl_interface)
        if not wcli then return nil, client_error end
        local connected, state = wcli:getConnectedNetwork()
        wcli:close()
        if connected and tostring(connected.id) == tostring(network.id) then return network end
        return nil, state
    end
    local get_ip = require("modules/settings/zen_settings_utils").get_device_ip_address
    local isConnected, obtainIP = NetworkMgr.isConnected, NetworkMgr.obtainIP
    NetworkMgr.isConnected = function(self)
        -- Kobo also counts an IPv6 link-local address after DHCP fails.
        return isConnected(self) and (get_ip() ~= nil or self:hasDefaultRoute()) or false
    end
    NetworkMgr.obtainIP = function(self)
        obtainIP(self)
        if not self:isConnected() then
            logger.warn("Kobo DHCP did not assign a usable address; retrying once")
            obtainIP(self)
        end
    end
end

function M.new(NetworkMgr, logger)
    local ffiutil = require("ffi/util")
    local time = require("ui/time")
    local _ = require("gettext")
    local adapter = { id = "kobo" }
    local max_auth_failures = 2 -- Initial attempt plus one retry.

    local function auth_failure(event)
        local msg = event.msg or ""
        local wrong_key = msg:find("reason=WRONG_KEY", 1, true) ~= nil
            or msg:find("pre-shared key may be incorrect", 1, true) ~= nil
        -- Association timeouts and disconnects do not prove a bad password.
        return wrong_key
    end

    local function finish_auth(wcli, connected)
        local reply, err = wcli:sendCtrlCmd("ENABLE_NETWORK all")
        if not reply or reply:sub(1, 2) ~= "OK" then
            logger.warn("could not re-enable Kobo Wi-Fi profiles", "error_present=", err ~= nil)
        end
        if not connected then
            reply, err = wcli:sendCtrlCmd("DISCONNECT")
            logger.dbg("Kobo authentication stopped", "accepted=",
                reply ~= nil and reply:sub(1, 2) == "OK", "error_present=", err ~= nil)
        end
    end

    function adapter.profileId(ssid)
        if type(NetworkMgr.getConfiguredNetworks) ~= "function" then return end
        local profiles = NetworkMgr:getConfiguredNetworks()
        for _i, profile in ipairs(profiles or {}) do
            if profile.ssid == ssid and profile.id then return profile.id end
        end
    end

    local function use_profile(id, reconnect)
        local WpaClient = require("lj-wpaclient/wpaclient")
        local wcli, err = WpaClient.new(NetworkMgr.wpa_supplicant.ctrl_interface)
        if not wcli then return false, err end
        if reconnect then
            local attached
            attached, err = wcli:attach()
            if not attached then
                wcli:close()
                return false, err
            end
        end
        local reply
        reply, err = wcli:sendCtrlCmd(reconnect and "SELECT_NETWORK " .. tostring(id) or "DISCONNECT")
        local connected = false
        local failures = 0
        local rejected = false
        local reason = _("Timed out")
        local last_state
        if reconnect and reply and reply:sub(1, 2) == "OK" then
            for _i = 1, 120 do
                local current, state = wcli:getConnectedNetwork()
                local auth_state = current and "COMPLETED" or state
                if auth_state ~= last_state then
                    logger.dbg("Kobo authentication state", "profile_id=", id, "state=", auth_state)
                    last_state = auth_state
                end
                if current and tostring(current.id) == tostring(id) then
                    connected = true
                    break
                end
                for _j, event in ipairs(wcli:readAllEvents() or {}) do
                    local wrong_key = auth_failure(event)
                    if wrong_key then
                        failures = failures + 1
                        logger.dbg("Kobo authentication failure", "profile_id=", id,
                            "failures=", failures, "limit=", max_auth_failures,
                            "wrong_key=", wrong_key)
                        if failures >= max_auth_failures then
                            rejected = true
                            reason = _("Failed to authenticate")
                            break
                        end
                    end
                end
                if rejected then break end
                ffiutil.usleep(250 * 1000)
            end
        end
        if reconnect then finish_auth(wcli, connected) end
        wcli:close()
        if connected then return true, _("Authenticated") end
        if reply and reply:sub(1, 2) == "OK" then
            if reconnect then return false, reason end
            return true
        end
        return false, err or reply
    end

    function adapter.disconnect(network, preserve)
        local id = preserve and (network.wpa_supplicant_id or adapter.profileId(network.ssid))
        if not id then return NetworkMgr:disconnectNetwork(network) end
        local disconnected, err = use_profile(id, false)
        logger.dbg("Kobo configured profile disconnected", "profile_id=", id, "success=", disconnected)
        return disconnected, err
    end

    function adapter.forgetNetwork(network)
        if type(NetworkMgr.getConfiguredNetworks) ~= "function" then
            return false, "Kobo Wi-Fi profiles are unavailable"
        end
        local profiles, err = NetworkMgr:getConfiguredNetworks()
        if not profiles then return false, err or "Could not read Kobo Wi-Fi profiles" end
        local ids = {}
        for _i, profile in ipairs(profiles) do
            if profile.ssid == network.ssid then ids[#ids + 1] = profile.id end
        end
        if #ids == 0 then return true, nil, false end

        local WpaClient = require("lj-wpaclient/wpaclient")
        local wcli
        wcli, err = WpaClient.new(NetworkMgr.wpa_supplicant.ctrl_interface)
        if not wcli then return false, err end
        for _i, id in ipairs(ids) do
            local reply
            reply, err = wcli:sendCtrlCmd("REMOVE_NETWORK " .. tostring(id))
            if not reply or reply:sub(1, 2) ~= "OK" then
                wcli:sendCtrlCmd("RECONFIGURE")
                wcli:close()
                return false, err or reply
            end
        end
        local reply
        reply, err = wcli:sendCtrlCmd("SAVE_CONFIG")
        if not reply or reply:sub(1, 2) ~= "OK" then
            wcli:sendCtrlCmd("RECONFIGURE")
            wcli:close()
            return false, err or reply
        end
        wcli:close()
        logger.dbg("Kobo profiles forgotten", "profiles=", #ids)
        return true, nil, true
    end

    local function authenticate_password(network)
        local methods = require("lj-wpaclient/wpaclient").__index
        local enable = methods.enableNetworkByID
        local auth_client, close
        local failures = 0
        -- KOReader authenticates synchronously; SELECT_NETWORK clears an earlier DISCONNECT.
        methods.enableNetworkByID = function(wcli, id)
            auth_client = wcli
            close = wcli.close
            wcli.close = function() end -- Defer cleanup until the result is known.
            local attach = wcli.attach
            wcli.attach = function(self) return self.attached or attach(self) end
            local attached, attach_error = wcli:attach()
            if not attached then error(attach_error or _("Connection failed"), 0) end
            local events = {}
            wcli.readEvent = function(self)
                if #events == 0 then self:readAllEvents(events) end
                local event = table.remove(events, 1)
                if event then
                    local wrong_key = auth_failure(event)
                    event.isAuthFailed = function() return wrong_key end
                    if wrong_key then
                        failures = failures + 1
                        logger.dbg("Kobo authentication failure", "profile_id=", id,
                            "failures=", failures, "limit=", max_auth_failures,
                            "wrong_key=", wrong_key)
                        if failures >= max_auth_failures then
                            self:removeNetwork(id)
                            error(_("Failed to authenticate"), 0)
                        end
                    end
                end
                return event
            end
            local get_connected = wcli.getConnectedNetwork
            local last_state
            local deadline = time.now() + time.s(30)
            wcli.getConnectedNetwork = function(self)
                if time.now() >= deadline then
                    self:removeNetwork(id)
                    error(_("Timed out"), 0)
                end
                local current, state = get_connected(self)
                if current and tostring(current.id) ~= tostring(id) then current = nil end
                local auth_state = current and "COMPLETED" or state
                if auth_state ~= last_state then
                    logger.dbg("Kobo authentication state", "profile_id=", id, "state=", auth_state)
                    last_state = auth_state
                end
                return current, state
            end
            local reply, err = wcli:sendCtrlCmd("SELECT_NETWORK " .. tostring(id))
            logger.dbg("Kobo password profile selected", "profile_id=", id,
                "accepted=", reply ~= nil and reply:sub(1, 2) == "OK")
            if not reply or reply:sub(1, 2) ~= "OK" then
                wcli:removeNetwork(id)
                error(err or _("Connection failed"), 0)
            end
            return reply, err
        end
        local authenticate = NetworkMgr._zen_kobo_authenticate or NetworkMgr.authenticateNetwork
        local UIManager = require("ui/uimanager")
        local show, notice = UIManager.show
        UIManager.show = function(self, widget, ...)
            notice = widget
            return show(self, widget, ...)
        end
        local ok, authenticated, err = pcall(authenticate, NetworkMgr, network)
        UIManager.show = show
        if not ok and notice then UIManager:close(notice) end
        methods.enableNetworkByID = enable
        if auth_client then
            finish_auth(auth_client, ok and authenticated == true)
            close(auth_client)
        end
        if not ok then return false, tostring(authenticated) end
        return authenticated, err
    end

    function adapter.connect(network, use_password)
        local id = not use_password and
            (adapter.profileId(network.ssid) or network.wpa_supplicant_id)
        local authenticated, err
        if id then
            authenticated, err = use_profile(id, true)
            if authenticated then network.wpa_supplicant_id = id end
            logger.dbg("Kobo configured profile connection", "profile_id=", id, "accepted=", authenticated == true)
        else
            authenticated, err = authenticate_password(network)
        end
        if not authenticated and err == _("Timed out") and (network.password ~= nil or id) then
            logger.warn("Kobo association timed out; resetting Wi-Fi and retrying once")
            NetworkMgr:turnOffWifi()
            local reconnect = NetworkMgr.reconnectOrShowNetworkMenu
            NetworkMgr.reconnectOrShowNetworkMenu = function() return true end
            local ok, status = pcall(NetworkMgr.turnOnWifi, NetworkMgr)
            NetworkMgr.reconnectOrShowNetworkMenu = reconnect
            if not ok or status == false then return false, _("Could not turn on Wi-Fi.") end
            network.wpa_supplicant_id = nil
            if network.password ~= nil then
                authenticated, err = authenticate_password(network)
            else
                id = adapter.profileId(network.ssid)
                if not id then return false, _("Connection failed") end
                authenticated, err = use_profile(id, true)
                if authenticated then network.wpa_supplicant_id = id end
            end
        end
        return authenticated, err
    end

    function adapter.getNetworkList()
        local networks, err = NetworkMgr:getNetworkList()
        if networks and #networks == 0 then
            local wcli = require("lj-wpaclient/wpaclient").new(NetworkMgr.wpa_supplicant.ctrl_interface)
            if wcli then
                local status = wcli:getStatus()
                if status and status.wpa_state == "DISCONNECTED" then
                    local reply, reconnect_error = wcli:sendCtrlCmd("RECONNECT")
                    logger.dbg("Kobo empty scan recovery", "accepted=",
                        reply ~= nil and reply:sub(1, 2) == "OK", "error_present=", reconnect_error ~= nil)
                end
                wcli:close()
            end
            networks, err = NetworkMgr:getNetworkList()
        end
        return networks, err
    end

    function adapter.annotateScan(networks)
        local configured = type(NetworkMgr.getConfiguredNetworks) == "function"
            and NetworkMgr:getConfiguredNetworks() or {}
        local configured_ssids = {}
        for _i, profile in ipairs(configured) do
            configured_ssids[profile.ssid] = true
        end
        local saved_count = 0
        local unique, positions = {}, {}
        for _i, network in ipairs(networks) do
            network.kobo_configured = configured_ssids[network.ssid] == true
            if network.password ~= nil then saved_count = saved_count + 1 end
            logger.dbg("Kobo scan network", "scan_index=", _i,
                "quality=", network.signal_quality or "none",
                "raw_signal=", network.signal_level or "none",
                "frequency=", network.frequency or "none",
                "configured=", network.kobo_configured)
            if type(network.ssid) == "string" and network.ssid ~= "" then
                local index = positions[network.ssid]
                if not index then
                    unique[#unique + 1] = network
                    positions[network.ssid] = #unique
                elseif network.connected and not unique[index].connected then
                    unique[index] = network
                end
            end
        end
        logger.dbg("Kobo scan result", "networks=", #networks,
            "saved_credentials=", saved_count, "configured_profiles=", #configured)
        return unique
    end

    return adapter
end

return M
