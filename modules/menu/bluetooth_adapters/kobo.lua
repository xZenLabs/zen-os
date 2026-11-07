local Kobo = require("modules/menu/bluetooth/kobo_bluetooth")
local Common = require("modules/menu/bluetooth_adapters/common")

local M = {}

function M.isSupported(Device)
    return Device.isKobo and Device:isKobo() and Kobo.isAvailable()
end

function M.isAvailable() return Kobo.isAvailable() end
function M.onSuspend() Kobo.onSuspend() end

function M.readState()
    local state = Kobo.getState()
    if state ~= nil then return state and 1 or 0 end
end

-- kobo_bluetooth verifies power itself.
function M.setPower(enabled, request)
    return Kobo.setEnabled(enabled, request.done)
end

function M.new()
    local adapter = { id = "kobo", getDeviceList = Kobo.getDeviceList }
    function adapter.scan(done) Kobo.startScan(done) end
    local function action(name, device, field, expected, done)
        local ok, err = Kobo.deviceAction(name, device)
        if not ok then done(false, err); return end
        Common.verify(adapter, device.address, field, expected, done)
    end
    function adapter.pair(device, done) action("pair", device, "paired", true, done) end
    function adapter.connect(device, done) action("connect", device, "connected", true, done) end
    function adapter.disconnect(device, done) action("disconnect", device, "connected", false, done) end
    function adapter.forget(device, done) action("forget", device, "paired", false, done) end
    function adapter.close()
        Common.close(adapter)
        Kobo.stopScan()
    end
    return adapter
end

return M
