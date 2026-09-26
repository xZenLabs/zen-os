local UIManager = require("ui/uimanager")

local M = {}

function M.validAddress(address)
    return type(address) == "string"
        and address:match("^%x%x:%x%x:%x%x:%x%x:%x%x:%x%x$") ~= nil
end

function M.verify(adapter, address, field, expected, done)
    local attempts = 0
    local poll
    poll = function()
        if adapter.closed then return end
        attempts = attempts + 1
        local devices, err = adapter.getDeviceList()
        if not devices then
            adapter.pending = nil
            adapter.pending_done = nil
            done(false, err)
            return
        end
        local actual = false
        for _i, device in ipairs(devices) do
            if device.address == address then
                actual = device[field] == true
                break
            end
        end
        if actual == expected then
            adapter.pending = nil
            adapter.pending_done = nil
            done(true)
        elseif attempts >= 10 then
            adapter.pending = nil
            adapter.pending_done = nil
            done(false, "Bluetooth device did not change state.")
        else
            adapter.pending = poll
            adapter.pending_done = done
            UIManager:scheduleIn(0.5, poll)
        end
    end
    poll()
end

function M.close(adapter)
    adapter.closed = true
    if adapter.pending then UIManager:unschedule(adapter.pending) end
    adapter.pending = nil
    local done = adapter.pending_done
    adapter.pending_done = nil
    if done then done(false, "Cancelled.") end
end

return M
