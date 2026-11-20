describe("Wi-Fi wait", function()
    local mgr, scheduled, unscheduled, prompts, events, saved, WifiWait

    local function run()
        return WifiWait.run(
            function() events[#events + 1] = "connected" end,
            function() events[#events + 1] = "failed" end,
            function() events[#events + 1] = "waiting" end
        )
    end

    local function poll()
        local last = scheduled[#scheduled]
        assert.are.equal(0.5, last.delay)
        last.callback()
    end

    before_each(function()
        saved = { package.loaded["ui/network/manager"], package.loaded["ui/uimanager"] }
        scheduled, unscheduled, prompts, events = {}, {}, {}, {}
        mgr = { on = false, connected = false }
        function mgr.isWifiOn(self) return self.on end
        function mgr.isConnected(self) return self.connected end
        function mgr.runWhenConnected(_self, callback) prompts[#prompts + 1] = callback end
        ZenSpec.replace("ui/network/manager", mgr)
        ZenSpec.replace("ui/uimanager", {
            scheduleIn = function(_self, delay, callback)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end,
            unschedule = function(_self, callback) unscheduled[callback] = true end,
        })
        ZenSpec.unload("common/wifi_wait")
        WifiWait = require("common/wifi_wait")
    end)

    after_each(function()
        package.loaded["ui/network/manager"], package.loaded["ui/uimanager"] = saved[1], saved[2]
        ZenSpec.unload("common/wifi_wait")
    end)

    it("runs immediately when connected", function()
        mgr.on, mgr.connected = true, true
        run()
        assert.are.same({ "connected" }, events)
        assert.are.equal(0, #scheduled)
        assert.are.equal(0, #prompts)
    end)

    it("leaves a powered-off radio to KOReader's prompt", function()
        run()
        assert.are.same({}, events)
        assert.are.equal(0, #scheduled)
        assert.are.equal(1, #prompts)
        prompts[1]()
        assert.are.same({ "connected" }, events)
    end)

    it("waits for a powered-on radio to connect without prompting", function()
        mgr.on = true
        run()
        poll()
        assert.are.same({ "waiting" }, events)
        mgr.connected = true
        poll()
        assert.are.same({ "waiting", "connected" }, events)
        assert.are.equal(0, #prompts)
        scheduled[#scheduled].callback() -- A stale timer must not fire the callback twice.
        assert.are.equal(2, #events)
    end)

    it("gives up after ten seconds when nothing is connecting", function()
        mgr.on = true
        run()
        for _i = 1, 19 do poll() end
        assert.are.same({ "waiting" }, events)
        poll()
        assert.are.same({ "waiting", "failed" }, events)
        assert.are.equal(20, #scheduled)
    end)

    it("keeps waiting for a connection attempt in flight, even with the radio still off", function()
        for _i, flag in ipairs({ "pending_connection", "pending_connectivity_check", "changing" }) do
            scheduled, events = {}, {}
            mgr.pending_connection, mgr.pending_connectivity_check, mgr.isWifiChanging = nil, nil, nil
            if flag == "changing" then
                mgr.isWifiChanging = function() return true end
            else
                mgr[flag] = true
            end
            run()
            for _j = 1, 89 do poll() end
            assert.are.same({ "waiting" }, events)
            poll()
            assert.are.same({ "waiting", "failed" }, events)
            assert.are.equal(0, #prompts)
        end
    end)

    it("stops polling when cancelled", function()
        mgr.on = true
        local cancel = run()
        local pending = scheduled[1].callback
        cancel()
        assert.is_true(unscheduled[pending])
        mgr.connected = true
        pending()
        assert.are.same({ "waiting" }, events)
    end)

    it("describes a missing connection on two lines", function()
        assert.are.equal("No internet connection.\nConnect to a Wi-Fi network and try again.",
            WifiWait.no_connection_text())
    end)
end)
