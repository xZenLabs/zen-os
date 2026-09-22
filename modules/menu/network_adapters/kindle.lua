local ffiutil = require("ffi/util")
local UIManager = require("ui/uimanager")
local logger = require("common/zen_logger").new("kindle_network_adapter")

local M = {}

local function is_secured(network)
    local flags = type(network.flags) == "string" and network.flags or ""
    return flags:find("WPA", 1, true) ~= nil or flags:find("SAE", 1, true) ~= nil
end

local function lipc_handle()
    local ok_lipc, lipc = pcall(require, "liblipclua")
    if not ok_lipc or type(lipc.init) ~= "function" then
        return nil, "liblipclua unavailable"
    end
    local ok_handle, handle = pcall(lipc.init, "com.github.koreader.networkmgr")
    if not ok_handle or not handle then return nil, tostring(handle) end
    return handle
end

local function profile_handle()
    local ok_lipc, lipc = pcall(require, "libopenlipclua")
    if not ok_lipc or type(lipc) ~= "table"
            or type(lipc.open_no_name) ~= "function" then
        return nil, "libopenlipclua unavailable"
    end
    local ok_handle, handle = pcall(lipc.open_no_name)
    if not ok_handle or not handle then return nil, tostring(handle) end
    return handle
end

local function read_hash(property)
    local handle, handle_error = profile_handle()
    if not handle then return nil, handle_error end
    local input
    local result
    local profiles
    local read, read_error = pcall(function()
        input = handle:new_hasharray()
        result = handle:access_hash_property("com.lab126.wifid", property, input)
        profiles = result and result:to_table()
    end)
    if result then pcall(result.destroy, result) end
    if input then pcall(input.destroy, input) end
    pcall(handle.close, handle)
    if not read then return nil, read_error end
    return profiles or {}
end

local function get_profile(ssid)
    local profiles, profiles_error = read_hash("profileData")
    if not profiles then return nil, profiles_error end
    for _i, profile in ipairs(profiles) do
        if profile.essid == ssid then return profile end
    end
    return nil
end

local function wait_for_profile(ssid, expected)
    local last_error
    for _i = 1, 20 do
        local profile, profile_error = get_profile(ssid)
        if profile_error then
            last_error = profile_error
        elseif (profile ~= nil) == expected then
            return profile or true
        end
        ffiutil.usleep(100 * 1000)
    end
    return nil, last_error or "Kindle Wi-Fi profile did not update"
end

local function delete_profile(ssid)
    local profile, profile_error = get_profile(ssid)
    if profile_error then return false, profile_error end
    if not profile then return true end
    local profile_id = tonumber(profile.netid)
    if not profile_id then return false, "Kindle Wi-Fi profile has no netid" end

    local function request_delete(value, numeric)
        local handle, handle_error = profile_handle()
        if not handle then return false, handle_error end
        local setter = numeric and handle.set_int_property or handle.set_string_property
        local requested, request_error = pcall(setter, handle,
            "com.lab126.wifid", "deleteProfile", value)
        pcall(handle.close, handle)
        return requested, request_error
    end

    local requested, request_error = request_delete(profile_id, true)
    local deleted, delete_error
    if requested then deleted, delete_error = wait_for_profile(ssid, false) end
    if not deleted then
        requested, request_error = request_delete(ssid, false)
        if requested then deleted, delete_error = wait_for_profile(ssid, false) end
    end
    if not deleted then return false, delete_error or request_error end
    logger.dbg("Kindle Wi-Fi profile deleted", "ssid=", ssid,
        "profile_id=", profile_id)
    return true
end

local function derive_psk(network)
    if not is_secured(network) then return true end
    local password = network.password
    if type(password) ~= "string" then return false, "missing password" end
    if #password == 64 and password:match("^%x+$") then
        network.psk = password
        return true
    end
    if #password < 8 or #password > 63 then return false, "invalid password length" end
    local ok_crypto, crypto = pcall(require, "ffi/crypto")
    local ok_sha, sha = pcall(require, "ffi/sha2")
    if not ok_crypto or not ok_sha then return false, "WPA PSK support unavailable" end
    local ok_psk, psk = pcall(crypto.pbkdf2_hmac_sha1,
        password, network.ssid, 4096, 32)
    if not ok_psk then return false, psk end
    network.password = sha.bin_to_hex(psk)
    network.psk = network.password
    return true
end

local function create_profile(network)
    local derived, derive_error = derive_psk(network)
    if not derived then return false, derive_error end

    local flags = type(network.flags) == "string" and network.flags or ""
    local security_method
    if flags:find("WPA2", 1, true) then
        security_method = "wpa2"
    elseif flags:find("WPA", 1, true) then
        security_method = "wpa"
    elseif is_secured(network) then
        return false, "unsupported Kindle Wi-Fi security"
    else
        security_method = "open"
    end

    local handle, handle_error = profile_handle()
    if not handle then return false, handle_error end

    local profile_input
    local result
    local created, create_error = pcall(function()
        profile_input = handle:new_hasharray()
        profile_input:add_hash()
        profile_input:put_string(0, "essid", network.ssid)
        profile_input:put_string(0, "smethod", security_method)
        if is_secured(network) then
            profile_input:put_string(0, "secured", "yes")
            profile_input:put_string(0, "psk", network.psk)
            profile_input:put_int(0, "store_nw_user_pref", 0)
        else
            profile_input:put_string(0, "secured", "no")
        end
        result = handle:access_hash_property(
            "com.lab126.wifid", "createProfile", profile_input)
    end)
    if result then pcall(result.destroy, result) end
    if profile_input then pcall(profile_input.destroy, profile_input) end
    pcall(handle.close, handle)
    if not created then return false, create_error end

    local profile, profile_error = wait_for_profile(network.ssid, true)
    if not profile then return false, profile_error end
    logger.dbg("Kindle Wi-Fi profile created", "ssid=", network.ssid,
        "security=", network.flags, "method=", security_method,
        "profile_id=", profile.netid)
    return true
end

function M.isSupported(Device)
    return Device.isKindle and Device:isKindle()
end

function M.new(NetworkMgr)
    local adapter = { id = "kindle" }
    local closed = false
    local scan_handle
    local scan_poll

    function adapter.close()
        closed = true
        if scan_poll then UIManager:unschedule(scan_poll) end
        if scan_handle then pcall(scan_handle.close, scan_handle) end
        scan_poll = nil
        scan_handle = nil
    end

    function adapter.connect(network)
        local profile, profile_error = get_profile(network.ssid)
        if profile_error then return false, profile_error end
        if not profile then return false, "saved Kindle Wi-Fi profile not found" end
        local selector = profile.netid and tostring(profile.netid) or network.ssid
        local handle, handle_error = lipc_handle()
        if not handle then return false, handle_error end
        local connected, err = pcall(handle.set_string_property, handle,
            "com.lab126.wifid", "cmConnect", selector)
        pcall(handle.close, handle)
        if connected then
            logger.dbg("Kindle Wi-Fi connection requested", "ssid=", network.ssid,
                "selector=", selector)
        end
        return connected, err
    end

    function adapter.disconnect()
        return pcall(NetworkMgr.turnOffWifi, NetworkMgr)
    end

    function adapter.forgetNetwork(network)
        local ok_current, current = pcall(NetworkMgr.getCurrentNetwork, NetworkMgr)
        if ok_current and current and current.ssid == network.ssid then
            local powered_off, power_error = pcall(NetworkMgr.turnOffWifi, NetworkMgr)
            if not powered_off or power_error == false then
                logger.warn("could not turn off Wi-Fi before forgetting profile",
                    "ssid=", network.ssid, "error=", power_error)
                return false, power_error
            end
            NetworkMgr:releaseIP()
            NetworkMgr.lease_ssid = nil
        end
        return delete_profile(network.ssid)
    end

    function adapter.getNetworkList()
        local scan_list, scan_error = read_hash("scanList")
        if not scan_list then return nil, scan_error end
        local profiles, profiles_error = read_hash("profileData")
        if not profiles then return nil, profiles_error end

        local saved = {}
        for _i, profile in ipairs(profiles) do
            if profile.essid then saved[profile.essid] = profile end
        end
        local ok_current, current = pcall(NetworkMgr.getCurrentNetwork, NetworkMgr)
        local current_ssid = ok_current and current and current.ssid
        local networks = {}
        for _i, network in ipairs(scan_list) do
            local signal = tonumber(network.signal)
            local signal_max = tonumber(network.signal_max)
            local profile = saved[network.essid]
            networks[#networks + 1] = {
                connected = network.essid == current_ssid,
                flags = network.key_mgmt or "",
                password = profile and profile.psk,
                signal_quality = signal and signal_max and signal_max > 0
                    and math.floor(signal * 100 / signal_max) or nil,
                ssid = network.essid,
            }
        end
        return networks
    end

    function adapter.replaceNetwork(network)
        local derived, derive_error = derive_psk(network)
        if not derived then return false, derive_error end
        local deleted, delete_error = delete_profile(network.ssid)
        if not deleted then return false, delete_error end
        return create_profile(network)
    end

    function adapter.scan(callback)
        local handle, handle_error = lipc_handle()
        if not handle then
            callback(false, handle_error)
            return
        end
        local requested, scan_error = pcall(handle.set_string_property, handle,
            "com.lab126.wifid", "scan", "")
        if not requested then
            pcall(handle.close, handle)
            callback(false, scan_error)
            return
        end
        scan_handle = handle
        local started = false
        local idle_polls = 0
        local last_state
        local attempts = 0
        local function finish(scanned, err)
            local active_handle = scan_handle
            scan_handle = nil
            scan_poll = nil
            if active_handle then pcall(active_handle.close, active_handle) end
            if not closed then callback(scanned, err) end
        end
        scan_poll = function()
            if closed then return end
            attempts = attempts + 1
            local ok_state, state = pcall(handle.get_string_property, handle,
                "com.lab126.wifid", "scanState")
            if state ~= last_state then
                logger.dbg("Kindle Wi-Fi scan state", "state=", state)
                last_state = state
            end
            local scanning = type(state) == "string" and state ~= "idle" and state ~= ""
            idle_polls = scanning and 0 or idle_polls + 1
            if not ok_state then
                finish(false, state)
            elseif not scanning and (started or idle_polls >= 4) then
                logger.dbg("Kindle Wi-Fi scan completed")
                finish(true)
            elseif attempts >= 80 then
                finish(false, "scan timed out")
            else
                if scanning then started = true end
                UIManager:scheduleIn(0.25, scan_poll)
            end
        end
        scan_poll()
    end

    return adapter
end

return M
