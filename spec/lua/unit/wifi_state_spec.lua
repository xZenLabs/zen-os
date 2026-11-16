describe("cached Wi-Fi state", function()
    local mgr, probes, original_time, now, WifiState

    before_each(function()
        probes = 0
        mgr = { on = false, connected = false }
        function mgr.isWifiOn(self) probes = probes + 1; return self.on end
        function mgr.isConnected(self) probes = probes + 1; return self.connected end
        ZenSpec.replace("ui/network/manager", mgr)
        original_time = os.time
        now = 1000
        rawset(os, "time", function(t) return t and original_time(t) or now end)
        ZenSpec.unload("common/wifi_state")
        WifiState = require("common/wifi_state")
    end)

    after_each(function()
        rawset(os, "time", original_time)
        ZenSpec.unload("ui/network/manager")
        ZenSpec.unload("common/wifi_state")
    end)

    it("skips the connection probe while the radio is off", function()
        assert.are.equal("off", WifiState.get())
        assert.are.equal(1, probes)
    end)

    it("serves paints from cache until invalidated", function()
        mgr.on, mgr.connected = true, true
        assert.are.equal("on", WifiState.get())
        local after_first = probes
        mgr.on = false
        assert.are.equal("on", WifiState.get())
        assert.are.equal(after_first, probes)
        WifiState.invalidate()
        assert.are.equal("off", WifiState.get())
    end)

    it("re-probes searching quickly and stable states within a minute", function()
        mgr.on = true
        assert.are.equal("searching", WifiState.get())
        mgr.connected = true
        now = now + 1
        assert.are.equal("searching", WifiState.get())
        now = now + 1
        assert.are.equal("on", WifiState.get())
        -- Upstream can turn Wi-Fi off without broadcasting an event.
        mgr.on = false
        now = now + 54
        assert.are.equal("on", WifiState.get())
        now = now + 1
        assert.are.equal("off", WifiState.get())
    end)

    it("re-probes when the clock moves backwards", function()
        mgr.on, mgr.connected = true, true
        assert.are.equal("on", WifiState.get())
        mgr.on = false
        now = now - 10
        assert.are.equal("off", WifiState.get())
    end)
end)
