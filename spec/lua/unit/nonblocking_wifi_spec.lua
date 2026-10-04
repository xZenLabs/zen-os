describe("background Wi-Fi toggles", function()
    local originals, reader_settings, defaults
    local Device, UIManager, NetworkMgr, ffiutil, native_ffi
    local scheduled, workers, wifi_on, connected, in_child, standby, notices, events, sleeps, warnings
    local outcome, spawn_failed, off_calls, reads, closed_fds, inherited_flags, shown, closed_notices
    local names = {
        "device", "ui/uimanager", "ui/network/manager", "ui/widget/networksetting",
        "ui/widget/infomessage", "ui/widget/confirmbox", "ui/widget/multiconfirmbox",
        "ui/event", "ui/bidi", "datastorage", "luasettings", "util", "logger", "gettext",
        "ffi", "ffi/util", "common/zen_logger", "modules/global/patches/nonblocking_wifi",
        "lj-wpaclient/wpaclient", "ui/network/wpa_supplicant", "ffi/crypto", "ffi/sha2",
        "modules/menu/network_adapters/kobo", "modules/settings/zen_settings_utils",
        "modules/menu/network_switcher", "ffi/inkview",
    }

    local function snapshot(value)
        local copy = {}
        for key, item in pairs(value) do copy[key] = item end
        return copy
    end

    local function restore(value, copy)
        for key in pairs(value) do value[key] = nil end
        for key, item in pairs(copy) do value[key] = item end
    end

    local function tick()
        local task = table.remove(scheduled, 1)
        assert.is_truthy(task)
        task.callback(unpack(task.args))
    end

    local function finish_worker(index)
        local worker = workers[index or #workers]
        local ui = snapshot(UIManager)
        local manager = snapshot(NetworkMgr)
        local picker = package.loaded["ui/widget/networksetting"]
        in_child = true
        worker.task(index, worker.fd)
        in_child = false
        restore(UIManager, ui)
        restore(NetworkMgr, manager)
        package.loaded["ui/widget/networksetting"] = picker
        worker.done = true
        tick()
    end

    before_each(function()
        originals = {}
        for _i, name in ipairs(names) do originals[name] = package.loaded[name] end
        reader_settings, defaults = _G.G_reader_settings, rawget(_G, "G_defaults")
        _G.G_reader_settings = ZenSpec.memorySettings()
        _G.G_reader_settings.makeTrue = function(self, key) self:saveSetting(key, true) end
        _G.G_reader_settings.makeFalse = function(self, key) self:saveSetting(key, false) end
        _G.G_defaults = ZenSpec.memorySettings()
        native_ffi = require("ffi")
        require("ffi/posix_h")
        scheduled, workers, events, sleeps, shown = {}, {}, {}, {}, {}
        closed_notices = {}
        warnings = {}
        wifi_on, connected, in_child = false, false, false
        standby, notices, off_calls, reads, closed_fds, inherited_flags = 0, 0, 0, 0, 0, 0
        outcome, spawn_failed = "connected", false
        UIManager = {
            show = function(_self, widget)
                notices = notices + 1
                shown[#shown + 1] = widget
            end,
            close = function(_self, widget)
                closed_notices[#closed_notices + 1] = widget
                if widget.dismiss_callback then widget.dismiss_callback() end
            end,
            forceRePaint = function() notices = notices + 1 end,
            preventStandby = function() standby = standby + 1 end,
            allowStandby = function() standby = standby - 1 end,
            broadcastEvent = function(_self, event) events[#events + 1] = event.handler end,
            scheduleIn = function(_self, delay, callback, ...)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback, args = { ... } }
            end,
            unschedule = function(_self, callback)
                for index = #scheduled, 1, -1 do
                    if scheduled[index].callback == callback then table.remove(scheduled, index) end
                end
            end,
        }
        ffiutil = {
            template = function(text, value) return (text:gsub("%%1", value)) end,
            usleep = function(delay) sleeps[#sleeps + 1] = delay end,
            runInSubProcess = function(task, with_pipe)
                assert.is_true(with_pipe)
                if spawn_failed then return false, "fork failed" end
                local index = #workers + 1
                workers[index] = { task = task, fd = index, done = false }
                return index, index
            end,
            isSubProcessDone = function(pid) return workers[pid].done end,
            writeToFD = function(fd, bytes) workers[fd].bytes = bytes end,
            getNonBlockingReadSize = function(fd) return #(workers[fd].bytes or "") end,
        }
        Device = {
            isKobo = function() return true end,
            isKindle = function() return false end,
            hasWifiRestore = function() return false end,
            hasSeamlessWifiToggle = function() return true end,
            hasWifiManager = function() return true end,
            initNetworkManager = function(_self, manager)
                manager.isWifiOn = function() return wifi_on end
                manager.isConnected = function() return connected end
                manager.ifHasAnAddress = function() return connected end
                manager.hasDefaultRoute = function() return connected end
                manager.canResolveHostnames = function()
                    assert.is_true(in_child, "DNS must not block the UI")
                    return true
                end
                manager.getNetworkInterfaceName = function() return "wlan0" end
                manager.getCurrentNetwork = function() return connected and { ssid = "Home" } end
                manager.getConfiguredNetworks = function() return {} end
                manager.getNetworkList = function()
                    if outcome == "error" then error("scan failed") end
                    if outcome == "picker" then return {} end
                    return {{ ssid = "Home", connected = true, signal_quality = 90 }}
                end
                manager.obtainIP = function() connected = true end
                manager.turnOnWifi = function(self, callback, interactive)
                    wifi_on = true
                    return self:reconnectOrShowNetworkMenu(callback, interactive)
                end
                manager.turnOffWifi = function(_manager, callback)
                    off_calls = off_calls + 1
                    wifi_on, connected = false, false
                    if callback then
                        if Device:isKindle() then UIManager:scheduleIn(2, callback) else callback() end
                    end
                end
            end,
        }
        local widget = { new = function(_self, options) return options end }
        local logger = { dbg = function() end, info = function() end,
            warn = function(...) warnings[#warnings + 1] = { ... } end }
        ZenSpec.replace("device", Device)
        ZenSpec.replace("ui/uimanager", UIManager)
        ZenSpec.replace("ffi/util", ffiutil)
        ZenSpec.replace("ui/bidi", { wrap = function(value) return value end })
        ZenSpec.replace("ui/event", { new = function(_self, name) return { handler = "on" .. name } end })
        for _i, name in ipairs({ "ui/widget/infomessage", "ui/widget/confirmbox", "ui/widget/multiconfirmbox" }) do
            ZenSpec.replace(name, widget)
        end
        ZenSpec.replace("datastorage", {})
        ZenSpec.replace("luasettings", {})
        ZenSpec.replace("util", { fixUtf8 = function(value) return value end })
        ZenSpec.replace("logger", logger)
        ZenSpec.replace("common/zen_logger", { new = function() return logger end })
        ZenSpec.replace("gettext", function(value) return value end)
        ZenSpec.unload("ui/network/manager")
        NetworkMgr = require("ui/network/manager")
        NetworkMgr.getAllSavedNetworks = function() return ZenSpec.memorySettings() end
        ZenSpec.replace("ffi", {
            new = native_ffi.new, cast = native_ffi.cast, string = native_ffi.string,
            C = {
                fcntl = function(_fd, command, flag)
                    assert.are.equal(2, command)
                    assert.are.equal(1, tonumber(flag))
                    inherited_flags = inherited_flags + 1
                end,
                kill = function(pid) workers[math.abs(pid)].done = true end,
                read = function(fd, data, size)
                    assert.is_false(in_child)
                    reads = reads + 1
                    native_ffi.copy(data, workers[fd].bytes, size)
                    return size
                end,
                close = function() closed_fds = closed_fds + 1 end,
            },
        })
        ZenSpec.unload("modules/global/patches/nonblocking_wifi")
        require("modules/global/patches/nonblocking_wifi")()
    end)

    after_each(function()
        for _i, name in ipairs(names) do package.loaded[name] = originals[name] end
        _G.G_reader_settings = reader_settings
        _G.G_defaults = defaults
    end)

    it("reports IP, route, DNS and check failures without disconnecting Wi-Fi", function()
        wifi_on, connected = true, true
        local cases = {
            { ip = false, route = true, dns = true, text = "no IP address" },
            { ip = true, route = false, dns = true, text = "no default route" },
            { ip = true, route = true, dns = false, text = "DNS lookup failed" },
            { ip = true, route = true, dns = "error", text = "connection check failed" },
            { ip = true, route = true, dns = true, text = "Connected to Home" },
        }
        for _i, case in ipairs(cases) do
            NetworkMgr.ifHasAnAddress = function() return case.ip end
            NetworkMgr.hasDefaultRoute = function() return case.route end
            NetworkMgr.canResolveHostnames = function()
                assert.is_true(in_child)
                assert.is_true(case.ip and case.route)
                if case.dns == "error" then error("lookup error") end
                return case.dns
            end
            local before = #shown
            NetworkMgr:showWifiConnected("Home")
            assert.are.equal(before, #shown)
            assert.is_false(NetworkMgr:isWifiChanging())
            finish_worker()
            assert.is_truthy(shown[#shown].text:find(case.text, 1, true))
            assert.are.equal(_i == #cases and 2 or 8, shown[#shown].timeout)
            assert.is_true(wifi_on)
            assert.are.equal(0, off_calls)
            assert.are.equal(0, standby)
        end
    end)

    it("bounds a DNS stall and suppresses notices after disconnecting or switching", function()
        wifi_on, connected = true, true
        NetworkMgr:showWifiConnected("Home")
        for _i = 1, 61 do tick() end
        assert.is_truthy(shown[#shown].text:find("timed out", 1, true))
        assert.are.equal(0, standby)
        for _i, action in ipairs({ "off", "switch", "notice" }) do
            wifi_on, connected = true, true
            NetworkMgr.getCurrentNetwork = function() return { ssid = "Home" } end
            NetworkMgr:showWifiConnected("Home")
            local before = #shown
            if action == "off" then
                wifi_on = false
            elseif action == "switch" then
                NetworkMgr.getCurrentNetwork = function() return { ssid = "Guest" } end
            else
                NetworkMgr:showWifiStarting()
                before = #shown
            end
            finish_worker()
            assert.are.equal(before, #shown)
        end
    end)

    it("keeps the UI usable and runs the complete callback through KOReader's connectivity check", function()
        local completed = 0
        NetworkMgr:toggleWifiOn(function()
            assert.is_false(in_child)
            completed = completed + 1
        end, false, true)
        assert.is_false(wifi_on)
        assert.is_true(NetworkMgr.pending_connection)
        assert.is_true(NetworkMgr:isWifiChanging())
        tick() -- The UI keeps running while the worker is busy.
        assert.are.equal(0, reads)
        assert.are.equal(1, notices)
        assert.are.equal(0, completed)
        finish_worker()
        assert.are.equal(NetworkMgr.hasLeaseForCurrentNetwork and "Home", NetworkMgr.lease_ssid)
        assert.is_true(NetworkMgr.pending_connectivity_check)
        assert.is_true(NetworkMgr:isWifiChanging())
        assert.are.equal(0, completed)
        tick()
        assert.are.equal(1, completed)
        assert.is_false(NetworkMgr.pending_connection)
        assert.is_false(NetworkMgr:isWifiChanging())
        assert.is_true(G_reader_settings:isTrue("wifi_was_on"))
        assert.are.same({ "onNetworkConnecting", "onNetworkStateChanged",
            "onNetworkConnected", "onNetworkStateChanged" }, events)
        assert.are.equal(1, notices)
        finish_worker() -- Verify DNS before announcing success.
        assert.are.equal(2, notices)
        assert.are.equal("Connected to Home", shown[2].text)
        assert.is_true(shown[1].toast)
        assert.is_true(shown[2].toast)
        assert.are.equal(2, shown[2].timeout)
        assert.is_true(shown[2].dismissable)
        assert.are.same({ shown[1] }, closed_notices)
        assert.are.equal(0, standby)
        assert.are.equal(2, closed_fds)
        assert.are.equal(2, inherited_flags)
    end)

    it("waits for resume authentication before starting the connectivity timeout", function()
        NetworkMgr:restoreWifiAsync()
        NetworkMgr:scheduleConnectivityCheck()

        for _i = 1, 400 do tick() end -- More than 45 seconds with both timers running.

        assert.is_false(workers[1].done)
        assert.are.equal(1, #workers)
        assert.are.equal(0, off_calls)
        assert.is_true(NetworkMgr.pending_connection)
        finish_worker()
        for _i = 1, 3 do
            if not NetworkMgr.pending_connection then break end
            tick()
        end
        assert.is_true(connected)
        assert.is_false(NetworkMgr.pending_connection)
        assert.is_false(NetworkMgr.pending_connectivity_check)
        assert.is_true(G_reader_settings:isTrue("wifi_was_on"))
        assert.are.equal(0, standby)
    end)

    it("turns off Kindle Wi-Fi in the worker and preserves its delayed completion callback", function()
        Device.isKindle = function() return true end
        wifi_on, connected = true, true
        local completed = 0
        NetworkMgr:toggleWifiOff(function() completed = completed + 1 end, true)
        assert.is_true(wifi_on)
        assert.is_true(NetworkMgr:isWifiChanging())
        assert.are.equal(0, off_calls)
        finish_worker()
        assert.is_false(wifi_on)
        assert.is_false(NetworkMgr:isWifiChanging())
        assert.are.equal(1, completed)
        assert.are.same({ 2000000 }, sleeps)
        assert.are.same({ "onNetworkDisconnecting", "onNetworkStateChanged",
            "onNetworkDisconnected", "onNetworkStateChanged" }, events)
        assert.are.equal(0, notices)
    end)

    describe("PocketBook", function()
        local pings, silent_calls

        before_each(function()
            pings = {}
            silent_calls = 0
            Device.isKobo = function() return false end
            Device.isPocketBook = function() return true end
            Device.hasWifiManager = function() return false end
            package.loaded["ffi"].cdef = function(declaration)
                assert.is_truthy(declaration:find("NetConnectSilent", 1, true))
            end
            package.loaded["ffi"].C.NET_OK = 0
            ZenSpec.replace("ffi/inkview", {
                WiFiPower = function(value)
                    assert.is_true(in_child, "PocketBook power changes must not block the UI")
                    assert.are.equal(1, value)
                    wifi_on = true
                end,
                NetConnect = function() error("Interactive NetConnect must not run in a worker") end,
                NetConnectSilent = function(name)
                    assert.is_true(in_child, "PocketBook reconnect must not block the UI")
                    assert.is_nil(name, "Reconnect using firmware-saved networks")
                    silent_calls = silent_calls + 1
                    connected = outcome == "connected"
                    return outcome == "failed" and -22 or 0
                end,
            })
            local init_network = Device.initNetworkManager
            Device.initNetworkManager = function(self, manager)
                local get_interface, has_address = manager.getNetworkInterfaceName, manager.ifHasAnAddress
                init_network(self, manager)
                manager.getNetworkInterfaceName, manager.ifHasAnAddress = get_interface, has_address
                local function keepWifiAlive()
                    UIManager:unschedule(keepWifiAlive)
                    if wifi_on then
                        pings[#pings + 1] = { in_child = in_child }
                        UIManager:scheduleIn(30, keepWifiAlive)
                    end
                end
                manager.getCurrentNetwork = function() end
                manager.turnOnWifi = function(_self, callback)
                    local inkview = require("ffi/inkview")
                    inkview.WiFiPower(1)
                    if inkview.NetConnect(nil) == 0 then keepWifiAlive() end
                    if callback then callback() end
                end
                manager.turnOffWifi = function(_self, callback)
                    assert.is_true(in_child, "PocketBook shutdown must not block the UI")
                    off_calls = off_calls + 1
                    wifi_on, connected = false, false
                    if callback then callback() end
                end
            end
            UIManager.broadcastEvent = function(_self, event) events[#events + 1] = event.handler end
            ZenSpec.unload("ui/network/manager")
            NetworkMgr = require("ui/network/manager")
            require("modules/global/patches/nonblocking_wifi")()
            ZenSpec.replace("modules/menu/network_switcher", {
                open = function() error("Power toggles must not open PocketBook settings") end,
            })
        end)

        it("runs power changes in workers and keeps the native timer in the UI process", function()
            assert.is_nil(NetworkMgr.interface)
            local completed = 0
            local refresh = function()
                assert.is_false(in_child)
                completed = completed + 1
            end
            NetworkMgr:toggleWifiOn(refresh, false, true)
            assert.is_false(wifi_on)
            assert.are.equal(1, #workers)
            tick()
            assert.are.equal(0, completed)
            finish_worker()
            local keepalive = table.remove(scheduled, 1)
            assert.are.equal(30, keepalive.delay)
            assert.are.same({ { in_child = false } }, pings)
            assert.are.equal(1, silent_calls)
            assert.are.same({}, sleeps)
            tick()
            assert.are.equal(1, completed)
            finish_worker() -- DNS check also stays off the UI thread.
            assert.are.equal("Connected", shown[#shown].text)
            keepalive.callback()
            assert.is_false(pings[#pings].in_child)
            NetworkMgr:toggleWifiOff(refresh, true)
            assert.is_true(wifi_on)
            assert.are.equal(0, off_calls)
            finish_worker()
            assert.is_false(wifi_on)
            assert.are.equal(2, completed)
            assert.are.equal(0, #scheduled)
            assert.are.equal(0, standby)
        end)

        it("checks route and DNS without an interface in the worker", function()
            wifi_on, connected = true, true
            local cases = {
                { route = false, dns = true, text = "no default route" },
                { route = true, dns = false, text = "DNS lookup failed" },
            }
            for _i, case in ipairs(cases) do
                NetworkMgr.hasDefaultRoute = function()
                    assert.is_true(in_child)
                    return case.route
                end
                NetworkMgr.canResolveHostnames = function()
                    assert.is_true(in_child)
                    assert.is_true(case.route)
                    return case.dns
                end
                NetworkMgr:showWifiConnected()
                finish_worker()
                assert.is_truthy(shown[#shown].text:find(case.text, 1, true))
                assert.is_true(wifi_on)
                assert.are.equal(0, off_calls)
                assert.are.equal(0, standby)
            end
        end)

        for _i, result in ipairs({ "failed", "no_route" }) do
            it("reports " .. result .. " without opening system settings", function()
                outcome = result
                local refreshed = 0
                NetworkMgr:toggleWifiOn(function() refreshed = refreshed + 1 end, false, true)
                finish_worker()
                if result == "no_route" then
                    assert.are.equal(30, table.remove(scheduled, 1).delay)
                    for _j = 1, 180 do tick() end
                end
                finish_worker()
                assert.are.equal(1, silent_calls)
                assert.are.equal(1, refreshed)
                assert.is_false(wifi_on)
                assert.is_false(NetworkMgr.pending_connection)
                assert.are.equal("Error connecting to the network", shown[#shown].text)
                assert.are.equal(0, standby)
            end)
        end
    end)

    it("queues a scan without cancelling authentication or clearing its pending state", function()
        local scanned = false
        NetworkMgr.nw_settings = {}
        NetworkMgr:toggleWifiOn(nil, false, true)
        NetworkMgr:runWifiAsync(function()
            assert.is_true(in_child)
            return { networks = {{ ssid = "Home", signal_quality = 80 }} }
        end, function(result)
            assert.is_false(in_child)
            scanned = result.networks[1].ssid == "Home"
        end, true)
        assert.are.equal(1, #workers)
        assert.is_false(workers[1].done)
        finish_worker(1)
        assert.is_nil(NetworkMgr.nw_settings)
        assert.is_true(NetworkMgr.pending_connection)
        assert.is_true(NetworkMgr.pending_connectivity_check)
        assert.are.equal(2, #workers)
        tick() -- Complete connection verification before delivering the scan.
        finish_worker(2)
        assert.is_true(scanned)
        assert.is_false(NetworkMgr.pending_connection)
        finish_worker() -- The connection check was queued behind the scan.
        assert.are.equal(0, standby)
    end)

    it("uses the native radio methods for recovery inside the worker", function()
        local starts = 0
        local function turn_on(self, callback)
            starts = starts + 1
            assert.is_true(in_child)
            assert.are.equal(turn_on, self.turnOnWifi)
            if starts == 1 then self:turnOnWifi() end
            wifi_on, connected = true, true
            if callback then callback() end
            return true
        end
        NetworkMgr.turnOnWifi = turn_on
        NetworkMgr:toggleWifiOn(nil, false, true)
        finish_worker()
        assert.are.equal(2, starts)
        assert.are.equal(1, #workers)
        tick()
        assert.is_false(NetworkMgr.pending_connection)
    end)

    it("waits for a Nickel profile to authenticate before starting DHCP", function()
        local association_polls, dhcp_calls, dhcp_start_polls = 0, 0, nil
        local raw_ssid = "Caf\\xc3\\xa9"
        local ssid = "Café"
        ZenSpec.replace("ffi/crypto", {})
        ZenSpec.replace("ffi/sha2", {})
        ZenSpec.replace("modules/settings/zen_settings_utils", {
            get_device_ip_address = function() return connected and "192.168.1.10" or nil end,
        })
        ZenSpec.replace("lj-wpaclient/wpaclient", {
            new = function()
                return {
                    getConnectedNetwork = function()
                        if association_polls >= 2 then return { id = "7", ssid = raw_ssid } end
                        return nil, association_polls == 0 and "ASSOCIATING" or "4WAY_HANDSHAKE"
                    end,
                    getCurrentNetwork = function()
                        return { id = "7", ssid = raw_ssid, bssid = "any", flags = "[CURRENT]" }
                    end,
                    scanThenGetResults = function()
                        return {{ ssid = raw_ssid, bssid = "any", getSignalQuality = function() return 80 end }}
                    end,
                    listNetworks = function() return {{ id = "7", ssid = ssid }} end,
                    close = function() end,
                }
            end,
        })
        ZenSpec.unload("ui/network/wpa_supplicant")
        ZenSpec.unload("modules/menu/network_adapters/kobo")
        require("ui/network/wpa_supplicant").init(NetworkMgr, { ctrl_interface = "/test/wlan0" })
        NetworkMgr.getAllSavedNetworks = function() return ZenSpec.memorySettings() end
        NetworkMgr.obtainIP = function()
            dhcp_start_polls = association_polls
            dhcp_calls = dhcp_calls + 1
            connected = true
        end
        ffiutil.usleep = function(delay)
            assert.are.equal(250000, delay)
            association_polls = association_polls + 1
        end
        require("modules/menu/network_adapters/kobo").install(NetworkMgr)
        NetworkMgr:toggleWifiOn(nil, false, true)
        finish_worker()
        tick()
        assert.are.equal(2, dhcp_start_polls, "DHCP started before authentication completed")
        assert.are.equal(1, dhcp_calls)
        assert.are.equal(NetworkMgr.hasLeaseForCurrentNetwork and ssid, NetworkMgr.lease_ssid)
        assert.is_false(NetworkMgr.pending_connection)
        finish_worker()
        assert.are.equal("Connected to " .. ssid, shown[2].text)
    end)

    it("keeps the completion notice readable when the backend has no SSID yet", function()
        NetworkMgr.getCurrentNetwork = function() return { ssid = "" } end
        NetworkMgr:toggleWifiOn(nil, false, true)
        finish_worker()
        tick()
        finish_worker()
        assert.are.equal("Connected", shown[2].text)
    end)

    for _i, missing_ssid in ipairs({ false, "" }) do
        it("waits for the Kindle SSID when initially " .. tostring(missing_ssid), function()
            Device.isKobo = function() return false end
            Device.isKindle = function() return true end
            local ssid = missing_ssid
            NetworkMgr.getCurrentNetwork = function() return ssid ~= false and { ssid = ssid } or nil end
            local completed = 0
            NetworkMgr:toggleWifiOn(function() completed = completed + 1 end, false, true)
            finish_worker()
            NetworkMgr.lease_ssid = nil
            tick()
            assert.are.equal(1, completed)
            assert.is_false(NetworkMgr.pending_connection)
            assert.are.equal(1, notices)
            assert.are.equal(1, #scheduled)
            ssid = "Home."
            tick()
            finish_worker()
            assert.are.equal("Connected to Home.", shown[2].text)
            assert.are.equal(0, #scheduled)
            assert.are.equal(1, completed)
        end)
    end

    it("bounds Kindle SSID retries to five seconds before showing Connected", function()
        Device.isKobo = function() return false end
        Device.isKindle = function() return true end
        NetworkMgr.getCurrentNetwork = function() return { ssid = "" } end
        NetworkMgr:toggleWifiOn(nil, false, true)
        finish_worker()
        tick()
        local retry_time = 0
        for _i = 1, 8 do
            assert.are.equal(1, #scheduled)
            retry_time = retry_time + scheduled[1].delay
            tick()
        end
        assert.are.equal(5, retry_time)
        finish_worker()
        assert.are.equal("Connected", shown[2].text)
        assert.are.equal(0, #scheduled)
    end)

    for _i, action in ipairs({ "off", "notice" }) do
        it("cancels a delayed Kindle connection notice on " .. action, function()
            Device.isKobo = function() return false end
            Device.isKindle = function() return true end
            NetworkMgr.getCurrentNetwork = function() return { ssid = "" } end
            NetworkMgr:toggleWifiOn(nil, false, true)
            finish_worker()
            tick()
            assert.are.equal(1, #scheduled)
            local pending = scheduled[1].callback
            if action == "off" then
                NetworkMgr:toggleWifiOff(nil, true)
                finish_worker()
            else
                NetworkMgr:showWifiNotice("New notice")
            end
            for _j, task in ipairs(scheduled) do assert.not_equal(pending, task.callback) end
            pending()
            assert.are.equal(action == "off" and 1 or 2, notices)
            assert.are.equal(0, #scheduled)
        end)
    end

    it("shows a two-second tap-dismissable notice without cancelling the connection", function()
        local completed = 0
        NetworkMgr:toggleWifiOn(function() completed = completed + 1 end, false, true)
        assert.are.equal("Turning on Wi-Fi…", shown[1].text)
        assert.are.equal(2, shown[1].timeout)
        assert.is_true(shown[1].dismissable)
        UIManager:close(shown[1])
        assert.is_true(NetworkMgr.pending_connection)
        finish_worker()
        tick()
        assert.are.equal(1, completed)
    end)

    it("runs manual connection work in the worker and delivers its result in the UI process", function()
        local value
        NetworkMgr.nw_settings = {}
        NetworkMgr:runWifiAsync(function()
            assert.is_true(in_child)
            wifi_on, connected = true, true
            return { connection = "10.0.0.20", psk = "derived" }
        end, function(result)
            assert.is_false(in_child)
            assert.is_false(NetworkMgr.pending_connection)
            assert.is_nil(NetworkMgr.nw_settings)
            value = result
        end)
        assert.is_false(wifi_on)
        assert.is_nil(value)
        tick()
        assert.is_true(NetworkMgr.pending_connection)
        finish_worker()
        assert.are.same({ connection = "10.0.0.20", psk = "derived" }, value)
        assert.are.equal(0, standby)
        assert.are.equal(0, notices)
    end)

    it("reports a manual worker error without leaving a connection pending", function()
        local reason
        NetworkMgr:runWifiAsync(function() error("authentication crashed for Home at 192.168.1.10") end, function(result, err)
            assert.is_nil(result)
            assert.is_false(NetworkMgr.pending_connection)
            reason = err
        end)
        finish_worker()
        assert.is_truthy(reason:find("authentication crashed", 1, true))
        assert.are.same({ "Wi-Fi worker failed", "error_type=", "string" }, warnings[1])
        assert.are.equal(0, standby)
    end)

    it("clears manual connection state if the worker cannot start", function()
        spawn_failed = true
        local reason
        NetworkMgr:runWifiAsync(function() error("Must not run") end, function(result, err)
            assert.is_nil(result)
            reason = err
        end)
        assert.are.equal("fork failed", reason)
        assert.is_false(NetworkMgr.pending_connection)
        assert.is_false(NetworkMgr:isWifiChanging())
        assert.are.equal(0, standby)
    end)

    it("cancels a manual connection when Wi-Fi is turned off", function()
        NetworkMgr:runWifiAsync(function() return true end, function()
            error("Cancelled manual callback must not run")
        end)
        NetworkMgr:toggleWifiOff(nil, true)
        tick()
        finish_worker()
        assert.is_false(NetworkMgr.pending_connection)
        assert.is_false(wifi_on)
        assert.are.equal(0, standby)
    end)

    for _i, saved_in in ipairs({ "none", "koreader", "nickel" }) do
        it("opens the Kobo scanner with networks saved in " .. saved_in, function()
            outcome = "picker"
            if saved_in == "koreader" then
                NetworkMgr.getAllSavedNetworks = function()
                    return ZenSpec.memorySettings({ Home = { password = "saved" } })
                end
            elseif saved_in == "nickel" then
                NetworkMgr.getConfiguredNetworks = function() return {{ id = "7", ssid = "Home" }} end
            end
            local opened, completed = 0, 0
            NetworkMgr:toggleWifiOn(function() completed = completed + 1 end, false, true, function()
                assert.is_false(in_child)
                assert.is_false(NetworkMgr.pending_connection)
                opened = opened + 1
            end)
            finish_worker()
            assert.are.equal(1, opened)
            assert.are.equal(0, completed)
            assert.is_true(wifi_on)
            assert.is_false(NetworkMgr.pending_connectivity_check)
            assert.are.equal(saved_in == "none" and 1 or 2, notices)
            if saved_in ~= "none" then
                assert.are.equal("Error connecting to the network", shown[2].text)
                assert.are.equal(2, shown[2].timeout)
                assert.is_true(shown[2].dismissable)
            end
        end)
    end

    for _i, succeeded in ipairs({ false, true }) do
        it("shows the verified Kindle " .. (succeeded and "success" or "failure") .. " notice", function()
            Device.isKobo = function() return false end
            Device.isKindle = function() return true end
            outcome = succeeded and "connected" or "picker"
            NetworkMgr.getCurrentNetwork = function() return connected and { ssid = "Home." } end
            local completed, failed = 0, 0
            NetworkMgr:toggleWifiOn(function() completed = completed + 1 end, false, true, function()
                failed = failed + 1
            end)
            finish_worker()
            if succeeded then
                assert.are.equal(1, notices)
                tick()
                finish_worker()
            end
            assert.are.equal(succeeded and 1 or 0, completed)
            assert.are.equal(succeeded and 0 or 1, failed)
            assert.are.equal(2, notices)
            assert.are.equal(succeeded and "Connected to Home." or "Error connecting to the network", shown[2].text)
            assert.are.equal(2, shown[2].timeout)
            assert.is_true(shown[2].dismissable)
            UIManager:close(shown[2])
            assert.is_false(NetworkMgr.pending_connection)
        end)
    end

    it("cleans up an errored reconnect in the background before opening the chooser", function()
        outcome = "error"
        local opened = 0
        NetworkMgr:toggleWifiOn(nil, false, true, function() opened = opened + 1 end)
        finish_worker()
        assert.are.equal(0, opened)
        assert.are.equal(0, off_calls)
        assert.are.equal(2, #workers)
        finish_worker()
        assert.are.equal(1, opened)
        assert.are.equal(1, off_calls)
        assert.is_false(wifi_on)
        assert.is_false(NetworkMgr.pending_connection)
        assert.are.equal(0, standby)
    end)

    it("does not show a power transition for a scan on an idle radio", function()
        NetworkMgr:runWifiAsync(function() return {} end, function() end, true)
        assert.is_false(NetworkMgr:isWifiChanging())
        finish_worker()
        assert.is_false(NetworkMgr:isWifiChanging())
        assert.are.same({}, events)
    end)

    it("cancels a pending enable without letting its callback revive the connection", function()
        local completed = 0
        NetworkMgr:toggleWifiOn(function() completed = completed + 1 end, false, true)
        NetworkMgr:toggleWifiOff(function() completed = completed + 10 end, true)
        assert.are.equal(1, #workers)
        tick() -- Reap the cancelled worker before starting the shutdown.
        assert.are.equal(2, #workers)
        finish_worker()
        assert.are.equal(10, completed)
        assert.is_false(NetworkMgr.pending_connection)
        assert.is_false(NetworkMgr.pending_connectivity_check)
        assert.are.equal(0, standby)
        assert.are.equal(2, closed_fds)
    end)

    it("shuts down synchronously on suspend even if hardware bring-up has not finished", function()
        NetworkMgr:toggleWifiOn(function() error("Cancelled callback must not run") end, false, true)
        UIManager:broadcastEvent({ handler = "onSuspend" })
        assert.are.equal(1, off_calls)
        assert.is_false(wifi_on)
        assert.is_false(NetworkMgr.pending_connection)
        tick()
        assert.are.equal(0, standby)
        assert.are.equal(1, #workers)
    end)

    it("bounds a stuck worker and keeps noninteractive failures silent", function()
        NetworkMgr:toggleWifiOn(function() error("Failed callback must not run") end, false, false)
        for _i = 1, 481 do tick() end
        assert.are.equal(2, #workers)
        finish_worker()
        assert.is_false(NetworkMgr.pending_connection)
        assert.are.equal(0, notices)
        assert.are.equal(0, standby)
    end)

    it("recovers its state when forking fails", function()
        spawn_failed = true
        local opened = 0
        NetworkMgr:toggleWifiOn(nil, false, true, function() opened = opened + 1 end)
        assert.is_false(NetworkMgr.pending_connection)
        assert.is_false(NetworkMgr.pending_connectivity_check)
        assert.are.equal(1, opened)
        assert.are.equal(0, standby)
        assert.are.equal(2, notices)
    end)

    it("opens the chooser if asynchronous connection verification fails", function()
        local opened, completed = 0, 0
        NetworkMgr:toggleWifiOn(function() completed = completed + 1 end, false, true, function()
            opened = opened + 1
        end)
        finish_worker()
        connected = false
        for _i = 1, 180 do tick() end
        assert.are.equal(0, opened)
        assert.are.equal(0, completed)
        finish_worker()
        assert.are.equal(1, opened)
        assert.is_false(NetworkMgr.pending_connection)
        assert.are.equal(2, notices)
    end)

    it("explains an associated network with no IP when the toggle times out", function()
        NetworkMgr:toggleWifiOn(nil, false, true, function() end)
        finish_worker()
        connected = false
        NetworkMgr.getCurrentNetwork = function() return { ssid = "Home" } end
        for _i = 1, 180 do tick() end
        finish_worker()
        assert.is_truthy(shown[#shown].text:find("no IP address", 1, true))
        assert.are.equal(8, shown[#shown].timeout)
        assert.is_false(NetworkMgr.pending_connection)
        assert.are.equal(0, standby)
    end)

    it("keeps duplicate enable requests quiet", function()
        NetworkMgr:toggleWifiOn(nil, false, true)
        NetworkMgr:toggleWifiOn(nil, false, true)
        assert.are.equal(1, #workers)
        assert.are.equal(1, notices)
    end)
end)
