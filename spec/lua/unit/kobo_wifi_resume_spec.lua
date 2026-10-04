describe("Kobo background Wi-Fi restore", function()
    local originals
    local Device, NetworkMgr, UIManager, ffiutil
    local scheduled, standby, requests, aborts
    local module_names = {
        "device", "ui/network/manager", "ui/uimanager", "common/zen_logger",
        "modules/global/patches/nonblocking_wifi",
    }

    before_each(function()
        originals = {}
        for _i, name in ipairs(module_names) do originals[name] = package.loaded[name] end
        ffiutil = require("ffi/util")
        scheduled, standby, requests, aborts = {}, 0, 0, 0
        Device = {
            isKobo = function() return true end,
            isKindle = function() return false end,
        }
        UIManager = {
            scheduleIn = function(_self, delay, callback)
                assert.are.equal(0.25, delay)
                scheduled[#scheduled + 1] = callback
            end,
            preventStandby = function() standby = standby + 1 end,
            allowStandby = function() standby = standby - 1 end,
            broadcastEvent = function(_self, event) return event.handler end,
        }
        NetworkMgr = {
            restoreWifiAsync = function() error("Shell restore cannot use KOReader's saved networks") end,
            requestToTurnOnWifi = function(self, callback, interactive)
                requests = requests + 1
                assert.is_false(interactive)
                if self.pending_connection then return 16 end
                self.pending_connection = true
                return self:turnOnWifi(callback, interactive)
            end,
            turnOnWifi = function(self, callback, interactive)
                assert.is_false(interactive)
                assert.is_true(self.pending_connection)
                self.lease_ssid = "KOReader-only network"
                callback()
                return true
            end,
            turnOffWifi = function(_self, callback) if callback then callback() end end,
            disableWifi = function(self)
                self.pending_connection = false
                self.lease_ssid = nil
            end,
            _abortWifiConnection = function(self)
                aborts = aborts + 1
                self.pending_connection = false
                self:turnOffWifi()
            end,
        }
        ZenSpec.replace("device", Device)
        ZenSpec.replace("ui/network/manager", NetworkMgr)
        ZenSpec.replace("ui/uimanager", UIManager)
        ZenSpec.replace("common/zen_logger", { new = function() return { warn = function() end } end })
        ZenSpec.unload("modules/global/patches/nonblocking_wifi")
    end)

    after_each(function()
        for _i, name in ipairs(module_names) do package.loaded[name] = originals[name] end
    end)

    local function finish_worker()
        for _i = 1, 500 do
            if #scheduled == 0 then break end
            ffiutil.usleep(10000)
            table.remove(scheduled, 1)()
        end
        assert.are.same({}, scheduled)
        assert.are.equal(0, standby)
    end

    it("uses the normal saved-network connection in a subprocess", function()
        require("modules/global/patches/nonblocking_wifi")()
        local turn_on = NetworkMgr.turnOnWifi

        NetworkMgr:restoreWifiAsync()

        assert.are.equal(1, requests)
        assert.are.equal(turn_on, NetworkMgr.turnOnWifi)
        assert.is_true(NetworkMgr.pending_connection)
        assert.is_nil(NetworkMgr.lease_ssid)
        assert.are.equal(1, standby)
        finish_worker()
        assert.are.equal("KOReader-only network", NetworkMgr.lease_ssid)
        assert.are.equal(0, aborts)
    end)

    it("tears down a failed restore", function()
        NetworkMgr.turnOnWifi = function() return false end
        require("modules/global/patches/nonblocking_wifi")()

        NetworkMgr:restoreWifiAsync()
        finish_worker()

        assert.are.equal(1, aborts)
        assert.is_false(NetworkMgr.pending_connection)
    end)

    it("cancels restoration when suspending again", function()
        require("modules/global/patches/nonblocking_wifi")()
        NetworkMgr:restoreWifiAsync()

        assert.are.equal("onSuspend", UIManager:broadcastEvent({ handler = "onSuspend" }))
        finish_worker()

        assert.is_nil(NetworkMgr.lease_ssid)
        assert.is_false(NetworkMgr.pending_connection)
        assert.are.equal(0, aborts)
    end)

    it("preserves Kindle's native restore", function()
        Device.isKobo = function() return false end
        Device.isKindle = function() return true end
        local restore = NetworkMgr.restoreWifiAsync

        require("modules/global/patches/nonblocking_wifi")()

        assert.are.equal(restore, NetworkMgr.restoreWifiAsync)
    end)
end)
