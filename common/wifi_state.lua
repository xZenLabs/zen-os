-- Cached Wi-Fi status ("on", "off", "searching") for status bars, so paints skip sysfs/getifaddrs.
-- Network events and resume invalidate it; TTLs bound changes upstream makes without an event.
local M = {}

local STABLE_TTL_S = 55 -- under a minute, so minute ticks re-probe
local SEARCHING_TTL_S = 2 -- transitional states settle quickly

local cached, checked_at

local function probe()
    local NetworkMgr = package.loaded["ui/network/manager"]
    if not NetworkMgr then
        local ok, mgr = pcall(require, "ui/network/manager")
        if not ok then return nil end
        NetworkMgr = mgr
    end
    if NetworkMgr.isWifiChanging and NetworkMgr:isWifiChanging() then return "searching" end
    -- Skip the connection check (getifaddrs) while the radio is off and idle.
    local wifi_on = NetworkMgr:isWifiOn()
    if (wifi_on or NetworkMgr.pending_connection or NetworkMgr.pending_connectivity_check)
            and not NetworkMgr:isConnected() then
        return "searching"
    end
    return wifi_on and "on" or "off"
end

function M.get()
    local now = os.time()
    if cached then
        local age = now - checked_at
        if age >= 0 and age < (cached == "searching" and SEARCHING_TTL_S or STABLE_TTL_S) then
            return cached
        end
    end
    cached, checked_at = probe(), now
    return cached
end

function M.invalidate()
    cached = nil
end

return M
