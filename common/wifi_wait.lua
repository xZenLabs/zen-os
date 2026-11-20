-- Runs a callback once Wi-Fi is connected: prompts while the radio is off, waits while it comes up.
local _ = require("gettext")

local M = {}

local POLL_S = 0.5
local IDLE_WAIT_S = 10 -- radio on, nothing connecting: covers a reconnect after resume
local BUSY_WAIT_S = 45 -- connection attempt in flight: KOReader's own connectivity budget

local function connecting(NetworkMgr)
    if NetworkMgr.isWifiChanging then return NetworkMgr:isWifiChanging() end
    return NetworkMgr.pending_connection or NetworkMgr.pending_connectivity_check
end

function M.no_connection_text()
    return _("No internet connection.") .. "\n" .. _("Connect to a Wi-Fi network and try again.")
end

--- Calls on_connected once connected; returns a function that cancels a polling wait.
--- Radio off: KOReader prompts (or follows the user's Wi-Fi action setting).
--- Radio on: polls while it connects; on_waiting() fires once up front, on_failed() on timeout.
function M.run(on_connected, on_failed, on_waiting)
    local NetworkMgr = require("ui/network/manager")
    local UIManager = require("ui/uimanager")
    local function noop() end
    if NetworkMgr:isConnected() then
        on_connected()
        return noop
    end
    if not (NetworkMgr:isWifiOn() or connecting(NetworkMgr)) then
        -- KOReader drops this callback on EBUSY, which only happens while connecting.
        NetworkMgr:runWhenConnected(on_connected)
        return noop
    end
    if on_waiting then on_waiting() end
    local waited, waiting = 0, true
    local function poll()
        if not waiting then return end
        if NetworkMgr:isConnected() then
            waiting = false
            return on_connected()
        end
        waited = waited + POLL_S
        if waited >= (connecting(NetworkMgr) and BUSY_WAIT_S or IDLE_WAIT_S) then
            waiting = false
            if on_failed then on_failed() end
            return
        end
        UIManager:scheduleIn(POLL_S, poll)
    end
    UIManager:scheduleIn(POLL_S, poll)
    return function()
        if waiting then UIManager:unschedule(poll) end
        waiting = false
    end
end

return M
