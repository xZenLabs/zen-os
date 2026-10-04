describe("network switcher", function()
    local original_modules
    local shown
    local closed
    local events
    local NetworkMgr
    local network_menu
    local password_dialog
    local confirm_box
    local button_dialog
    local connected_network
    local connected_ip
    local verification_sleeps
    local authentication_attempts
    local fail_first_auth
    local ip_calls
    local logs
    local scan_task
    local scheduled
    local follow_up_checks
    local scan_handle_closes
    local kindle_disconnects
    local kindle_connects
    local kindle_deletes
    local kindle_scans
    local kindle_scan_state
    local kindle_scan_stays_idle
    local power_cycle_sleeps
    local created_profile
    local native_profiles
    local profile_read_fails
    local deleted_profile_id

    local module_names = {
        "device",
        "libopenlipclua",
        "ui/event",
        "ui/widget/buttondialog",
        "ui/widget/confirmbox",
        "ui/widget/infomessage",
        "ui/widget/inputdialog",
        "ui/widget/menu",
        "ui/widget/networksetting",
        "ui/size",
        "ui/time",
        "ui/network/manager",
        "ui/uimanager",
        "ffi/util",
        "ffi/crypto",
        "ffi/sha2",
        "ffi/inkview",
        "liblipclua",
        "lj-wpaclient/wpaclient",
        "ui/network/wpa_supplicant",
        "util",
        "common/inline_icon_map",
        "common/plugin_root",
        "common/ui/icon_menu_item",
        "common/ui/zen_settings_titlebar",
        "common/utils",
        "common/zen_logger",
        "modules/menu/network_adapters/kindle",
        "modules/menu/network_adapters/kobo",
        "modules/settings/zen_settings_utils",
        "gettext",
    }

    before_each(function()
        original_modules = {}
        for _i, name in ipairs(module_names) do
            original_modules[name] = package.loaded[name]
        end
        shown = {}
        closed = {}
        events = {}
        verification_sleeps = 0
        authentication_attempts = 0
        fail_first_auth = false
        ip_calls = 0
        logs = {}
        password_dialog = nil
        button_dialog = nil
        scan_task = nil
        scheduled = {}
        follow_up_checks = {}
        scan_handle_closes = 0
        kindle_disconnects = 0
        kindle_connects = 0
        kindle_deletes = 0
        kindle_scans = 0
        kindle_scan_state = 0
        kindle_scan_stays_idle = false
        power_cycle_sleeps = 0
        created_profile = nil
        native_profiles = {
            Home = { essid = "Home", netid = 11, psk = "saved" },
        }
        profile_read_fails = false
        deleted_profile_id = nil

        ZenSpec.replace("device", {
            hasWifiManager = function() return false end,
            isKindle = function() return true end,
        })
        ZenSpec.replace("ui/event", {
            new = function(_self, name) return { name = name } end,
        })
        ZenSpec.replace("ui/widget/buttondialog", {
            new = function(_self, options)
                options.kind = "actions"
                options.getContentSize = function() return { w = 400, h = 300 } end
                button_dialog = options
                return options
            end,
        })
        ZenSpec.replace("ui/widget/confirmbox", {
            new = function(_self, options)
                options.kind = "confirm"
                confirm_box = options
                return options
            end,
        })
        ZenSpec.replace("ui/widget/infomessage", {
            new = function(_self, options)
                options.kind = "message"
                return options
            end,
        })
        ZenSpec.replace("ui/widget/inputdialog", {
            new = function(_self, options)
                options.kind = "password"
                options.getInputText = function() return "guest-password" end
                options.onShowKeyboard = function() options.keyboard_shown = true end
                password_dialog = options
                return options
            end,
        })
        ZenSpec.replace("ui/widget/menu", {
            new = function(_self, options)
                options.kind = "menu"
                options.updateItems = function(self)
                    self.updates = (self.updates or 0) + 1
                end
                options.switchItemTable = function(self, _title, items, selected_index)
                    self.item_table = items
                    self.selected_index = selected_index
                    self:updateItems()
                end
                options.onMenuChoice = function(_menu, item)
                    if item.callback then return item.callback() end
                end
                options.onClose = function(self)
                    if self.close_callback then self.close_callback() end
                    return true
                end
                network_menu = options
                return options
            end,
        })
        ZenSpec.replace("common/ui/zen_settings_titlebar", {
            new = function(_self, options)
                options.root_icon = {}
                options.clearStatusRefresh = function(self)
                    self.status_refresh_clears = (self.status_refresh_clears or 0) + 1
                end
                options.clear = function(self) self.was_cleared = true end
                options.init = function(self) self.was_initialized = true end
                return options
            end,
        })
        ZenSpec.replace("ui/size", {
            padding = { large = 12, default = 8 },
        })

        NetworkMgr = {
            wifi_on = true,
            isWifiOn = function(self) return self.wifi_on end,
            isConnected = function(self) return self.current_ssid ~= nil end,
            turnOffWifi = function(self)
                self.wifi_on = false
                self.current_ssid = nil
            end,
            turnOnWifi = function(self) self.wifi_on = true return true end,
            getNetworkList = function(self)
                if self.current_ssid then
                    return {{
                        ssid = self.current_ssid,
                        flags = "[WPA2]",
                        password = "saved",
                        signal_quality = 80,
                        connected = true,
                    }}
                end
                return {
                    {
                        ssid = "Home",
                        flags = "[WPA2]",
                        password = "saved",
                        signal_quality = 80,
                        connected = false,
                        wpa_supplicant_id = 1,
                    },
                    {
                        ssid = "Guest",
                        flags = "[WPA2]",
                        password = self.guest_password,
                        signal_quality = 60,
                    },
                }
            end,
            current_ssid = "Home",
            disconnectNetwork = function(self, network)
                self.disconnected = network
            end,
            releaseIP = function(self) self.released = true end,
            saveNetwork = function(self, network) self.saved = network end,
            deleteNetwork = function(self, network) self.deleted = network end,
            authenticateNetwork = function(self, network)
                authentication_attempts = authentication_attempts + 1
                self.authenticated = network
                self.current_ssid = fail_first_auth and authentication_attempts == 1
                    and "Home" or network.ssid
                return true, "Authenticated"
            end,
            obtainIP = function(self) self.obtained = true end,
            getCurrentNetwork = function(self) return { ssid = self.current_ssid } end,
            getAllSavedNetworks = function()
                return { readSetting = function() return nil end }
            end,
            hasDefaultRoute = function() return false end,
            queryNetworkState = function(self) self.queried = true end,
        }
        ZenSpec.replace("ui/network/manager", NetworkMgr)
        ZenSpec.replace("lj-wpaclient/wpaclient", {
            __index = { enableNetworkByID = function() end },
        })
        ZenSpec.replace("liblipclua", {
            init = function(name)
                assert.are.equal("com.github.koreader.networkmgr", name)
                return {
                    set_string_property = function(_self, service, property, value)
                        assert.are.equal("com.lab126.wifid", service)
                        if property == "cmDisconnect" then
                            assert.are.equal("", value)
                            kindle_disconnects = kindle_disconnects + 1
                            NetworkMgr.current_ssid = nil
                        elseif property == "scan" then
                            assert.are.equal("", value)
                            kindle_scans = kindle_scans + 1
                            kindle_scan_state = 1
                        else
                            assert.are.equal("cmConnect", property)
                            local profile
                            for _name, saved in pairs(native_profiles) do
                                if tostring(saved.netid) == value then profile = saved break end
                            end
                            assert.is_not_nil(profile)
                            kindle_connects = kindle_connects + 1
                            authentication_attempts = authentication_attempts + 1
                            NetworkMgr.authenticated = { ssid = profile.essid }
                            NetworkMgr.current_ssid = fail_first_auth
                                    and authentication_attempts == 1 and "Home" or profile.essid
                        end
                    end,
                    get_string_property = function(_self, service, property)
                        assert.are.equal("com.lab126.wifid", service)
                        if property == "scanState" then
                            if kindle_scan_stays_idle then return "idle" end
                            local states = { "idle", "scanning", "idle" }
                            local state = states[kindle_scan_state]
                            kindle_scan_state = kindle_scan_state + 1
                            return state
                        end
                        assert.are.equal("cmState", property)
                        return "READY"
                    end,
                    close = function() scan_handle_closes = scan_handle_closes + 1 end,
                }
            end,
        })
        ZenSpec.replace("libopenlipclua", {
            open_no_name = function()
                local profile_data = {}
                return {
                    new_hasharray = function()
                        return {
                            add_hash = function() end,
                            put_string = function(_self, index, key, value)
                                assert.are.equal(0, index)
                                profile_data[key] = value
                            end,
                            put_int = function(_self, index, key, value)
                                assert.are.equal(0, index)
                                profile_data[key] = value
                            end,
                            destroy = function() end,
                        }
                    end,
                    access_hash_property = function(_self, service, property)
                        assert.are.equal("com.lab126.wifid", service)
                        if property == "scanList" then
                            return {
                                to_table = function()
                                    return {
                                        {
                                            essid = "Home",
                                            key_mgmt = "WPA2-PSK",
                                            signal = 4,
                                            signal_max = 5,
                                        },
                                        {
                                            essid = "Guest",
                                            key_mgmt = "WPA2-PSK",
                                            signal = 3,
                                            signal_max = 5,
                                        },
                                    }
                                end,
                                destroy = function() end,
                            }
                        elseif property == "profileData" then
                            if profile_read_fails then error("profileData unavailable") end
                            return {
                                to_table = function()
                                    local profiles = {}
                                    for _name, profile in pairs(native_profiles) do
                                        profiles[#profiles + 1] = profile
                                    end
                                    return profiles
                                end,
                                destroy = function() end,
                            }
                        end
                        assert.are.equal("createProfile", property)
                        created_profile = profile_data
                        native_profiles[profile_data.essid] = {
                            essid = profile_data.essid,
                            netid = 22,
                            psk = profile_data.psk,
                            smethod = profile_data.smethod,
                        }
                        return { destroy = function() end }
                    end,
                    set_int_property = function(_self, service, property, value)
                        assert.are.equal("com.lab126.wifid", service)
                        assert.are.equal("deleteProfile", property)
                        kindle_deletes = kindle_deletes + 1
                        deleted_profile_id = value
                        for name, profile in pairs(native_profiles) do
                            if profile.netid == value then native_profiles[name] = nil break end
                        end
                    end,
                    close = function() end,
                }
            end,
        })
        ZenSpec.replace("ui/uimanager", {
            show = function(_self, widget) shown[#shown + 1] = widget end,
            close = function(_self, widget) closed[#closed + 1] = widget end,
            topdown_widgets_iter = function()
                local index = #shown + 1
                return function()
                    index = index - 1
                    return shown[index]
                end
            end,
            forceRePaint = function() end,
            setDirty = function(_self, widget)
                widget.repainted_wifi = widget.custom_title_bar.toggle.value_func()
            end,
            broadcastEvent = function(_self, event) events[#events + 1] = event.name end,
            tickAfterNext = function(_self, action) scan_task = action end,
            nextTick = function(_self, action) action() end,
            scheduleIn = function(_self, delay, action)
                if delay == 3 then
                    follow_up_checks[#follow_up_checks + 1] = action
                    return
                end
                assert.is_true(delay == 0.25 or delay == 5 / 8)
                scheduled[#scheduled + 1] = action
            end,
            unschedule = function(_self, action)
                for i = #scheduled, 1, -1 do
                    if scheduled[i] == action then table.remove(scheduled, i) end
                end
            end,
        })
        ZenSpec.replace("ffi/util", {
            template = function(value, ...)
                local args = { ... }
                return (value:gsub("%%(%d)", function(index)
                    return tostring(args[tonumber(index)])
                end))
            end,
            usleep = function(delay)
                if delay == 2 * 1000 * 1000 then
                    power_cycle_sleeps = power_cycle_sleeps + 1
                    return
                end
                assert.are.equal(250 * 1000, delay)
                verification_sleeps = verification_sleeps + 1
            end,
        })
        ZenSpec.replace("common/zen_logger", {
            new = function()
                return {
                    dbg = function(...) logs[#logs + 1] = { "dbg", ... } end,
                    warn = function(...) logs[#logs + 1] = { "warn", ... } end,
                    isEnabled = function() return true end,
                }
            end,
        })
        ZenSpec.replace("common/ui/icon_menu_item", {
            SETTINGS_CARET_SIZE = 22,
            getSettingsFontSize = function() return 27 end,
            installMenuPatch = function() end,
        })
        ZenSpec.replace("common/inline_icon_map", {
            delete = "delete",
            details = "details",
            edit = "edit",
            wifi_off = "wifi-off",
            wifi_on = "wifi-on",
        })
        ZenSpec.replace("common/plugin_root", "/tmp/zen-ui")
        ZenSpec.replace("common/utils", {
            resolveLocalIcon = function(path, name)
                assert.are.equal("/tmp/zen-ui/icons/", path)
                return path .. name .. ".svg"
            end,
        })
        ZenSpec.replace("modules/settings/zen_settings_utils", {
            get_device_ip_address = function()
                ip_calls = ip_calls + 1
                if ip_calls == 1 then return "192.168.1.10" end
                if ip_calls == 2 then return nil end
                return "10.0.0.20"
            end,
        })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.unload("modules/menu/network_switcher")
    end)

    after_each(function()
        for _i, name in ipairs(module_names) do
            package.loaded[name] = original_modules[name]
        end
        ZenSpec.unload("modules/menu/network_switcher")
        for _i, entry in ipairs(logs) do
            for _j, value in pairs(entry) do
                if type(value) == "string" then
                    for _k, private in ipairs({ "Home", "Guest", "guest-password", "192.168.1.10", "10.0.0.20" }) do
                        assert.is_nil(value:find(private, 1, true), "Wi-Fi logs contain private network details")
                    end
                end
            end
        end
    end)

    local function finish_scan()
        scan_task()
        network_menu.custom_title_bar.action.callback()
        while #scheduled > 0 do table.remove(scheduled, 1)() end
    end

    for _i, device in ipairs({ "kindle", "kobo" }) do
        for _j, use_password in ipairs({ false, true }) do
            it("connects " .. device .. " Wi-Fi in the background with "
                    .. (use_password and "a new password" or "saved credentials"), function()
                ZenSpec.replace("device", {
                    hasWifiManager = function() return true end,
                    isKobo = function() return device == "kobo" end,
                    isKindle = function() return device == "kindle" end,
                })
                NetworkMgr.current_ssid = nil
                local work, complete, reported_network
                local notices = {}
                NetworkMgr.showWifiNotice = function(_self, text) notices[#notices + 1] = text end
                NetworkMgr.showWifiConnected = function(_self, ssid)
                    notices[#notices + 1] = "Checking " .. ssid
                end
                NetworkMgr.runWifiAsync = function(_self, action, callback, queued_only)
                    if queued_only then return callback(action()) end
                    work, complete = action, callback
                end
                assert.is_true(require("modules/menu/network_switcher").open(function(network)
                    reported_network = network
                end))
                finish_scan()
                local item = network_menu.item_table[use_password and 2 or 1]
                if device == "kobo" then item.network.wpa_supplicant_id = nil end
                item.callback()
                if use_password then password_dialog.buttons[1][2].callback() end
                assert.is_function(work)
                assert.are.equal(0, authentication_attempts)
                assert.is_nil(created_profile)
                assert.is_nil(NetworkMgr.obtained)
                assert.is_nil(reported_network)
                assert.are.same({}, notices)
                assert.are.equal("Connecting to " .. item.network.ssid .. "…", network_menu.item_table[1].text)
                local result = work()
                assert.is_nil(reported_network)
                complete(result)
                assert.are.equal(item.network.ssid, reported_network.ssid)
                assert.are.equal(item.network.ssid, NetworkMgr.lease_ssid)
                assert.is_true(NetworkMgr.obtained)
                assert.are.same({ "NetworkConnecting", "NetworkConnected" }, events)
                assert.are.same({ "Checking " .. item.network.ssid }, notices)
            end)
        end
    end

    it("returns manual connection failures to the password dialog after the worker finishes", function()
        NetworkMgr.current_ssid = nil
        local work, complete
        NetworkMgr.showWifiNotice = function(_self, text)
            require("ui/uimanager"):show({ text = text })
        end
        NetworkMgr.runWifiAsync = function(_self, action, callback) work, complete = action, callback end
        assert.is_true(require("modules/menu/network_switcher").open())
        finish_scan()
        network_menu.item_table[1].callback()
        assert.is_nil(password_dialog)
        work()
        complete({ failure = "authentication", auth_error = "Wrong password" })
        assert.are.equal("Home", password_dialog.title)
        assert.are.equal("Wrong password", password_dialog.description)
        assert.are.equal("Wrong password", shown[#shown].text)
    end)

    it("reports Kobo DHCP failure instead of the successful authentication message", function()
        local notice, notice_timeout
        NetworkMgr.showWifiNotice = function(_self, text, timeout)
            notice, notice_timeout = text, timeout
        end
        ZenSpec.replace("device", {
            hasWifiManager = function() return true end,
            isKobo = function() return true end,
            isKindle = function() return false end,
        })
        NetworkMgr.current_ssid = nil
        ZenSpec.replace("modules/settings/zen_settings_utils", {
            get_device_ip_address = function() end,
        })
        local reported_network
        assert.is_true(require("modules/menu/network_switcher").open(function(network)
            reported_network = network
        end))
        finish_scan()
        network_menu.item_table[1].network.wpa_supplicant_id = nil
        network_menu.item_table[1].callback()

        assert.is_nil(reported_network)
        assert.is_nil(password_dialog)
        assert.are.equal("Connected to Home, but no IP address or default route was assigned.",
            network_menu.item_table[1].text)
        assert.are.equal(network_menu.item_table[1].text, notice)
        assert.are.equal(8, notice_timeout)
        assert.are.same({ "NetworkConnecting" }, events)
    end)

    it("does not open a password retry after the Wi-Fi list was closed", function()
        NetworkMgr.current_ssid = nil
        local complete
        NetworkMgr.runWifiAsync = function(_self, _action, callback) complete = callback end
        assert.is_true(require("modules/menu/network_switcher").open())
        finish_scan()
        network_menu.item_table[1].callback()
        network_menu:onClose()
        complete({ failure = "authentication" })
        assert.is_nil(password_dialog)
    end)

    it("powers Wi-Fi on in the background before scanning the list", function()
        NetworkMgr.wifi_on, NetworkMgr.current_ssid = false, nil
        local work, complete, notices = nil, nil, 0
        NetworkMgr.runWifiAsync = function(_self, action, callback) work, complete = action, callback end
        NetworkMgr.showWifiStarting = function() notices = notices + 1 end
        assert.is_true(require("modules/menu/network_switcher").open())
        scan_task()
        assert.are.equal(1, notices)
        assert.is_false(NetworkMgr.wifi_on)
        assert.are.equal(0, kindle_scans)
        complete(work())
        assert.is_true(NetworkMgr.wifi_on)
        while #scheduled > 0 do table.remove(scheduled, 1)() end
        assert.are.equal("Home", network_menu.item_table[1].text)
    end)

    it("refreshes the list when the Wi-Fi toggle replaces a pending scan startup", function()
        NetworkMgr.wifi_on, NetworkMgr.current_ssid = false, nil
        NetworkMgr.runWifiAsync = function() end
        local Switcher = require("modules/menu/network_switcher")
        Switcher.toggleWifi = function(touch_menu)
            NetworkMgr.wifi_on, NetworkMgr.current_ssid = true, "Home"
            touch_menu:updateItems()
        end
        assert.is_true(Switcher.open())
        scan_task()
        network_menu.custom_title_bar.toggle.callback()
        assert.are.equal("Home", network_menu.item_table[1].text)
        assert.are.equal("Connected", network_menu.item_table[1]._zen_settings_breadcrumb)
    end)

    for _i, wifi_on in ipairs({ false, true }) do
        it("rejoins saved Kindle Wi-Fi with the radio " .. (wifi_on and "on" or "off"), function()
            NetworkMgr.wifi_on = wifi_on
            NetworkMgr.current_ssid = nil
            local updates = 0
            local UIManager = require("ui/uimanager")
            UIManager.topdown_widgets_iter = function() return function() end end
            NetworkMgr.getWifiMenuTable = function() error("Should connect without a prompt") end
            NetworkMgr.toggleWifiOn = function(self, callback, long_press, interactive)
                assert.is_false(long_press)
                assert.is_true(interactive)
                self:turnOnWifi()
                self.current_ssid = "Home"
                callback()
            end
            local Switcher = require("modules/menu/network_switcher")
            Switcher.open = function() error("Saved Wi-Fi should rejoin without the switcher") end

            Switcher.toggleWifi({ updateItems = function() updates = updates + 1 end })

            assert.is_true(NetworkMgr:isWifiOn())
            assert.are.equal("Home", NetworkMgr.current_ssid)
            assert.are.equal(1, updates)
            assert.is_nil(scan_task)
            assert.are.same({}, shown)
        end)
    end

    for _i, has_saved in ipairs({ false, true }) do
        it("opens the Kindle switcher when " .. (has_saved and "saved networks are out of range"
                or "no networks are saved"), function()
            native_profiles = has_saved and {
                Old = { essid = "Old", netid = 2, psk = "saved" },
            } or {}
            NetworkMgr.wifi_on = false
            NetworkMgr.current_ssid = nil
            local NetworkSetting = {}
            ZenSpec.replace("ui/widget/networksetting", NetworkSetting)
            local dialog = setmetatable({}, NetworkSetting)
            local UIManager = require("ui/uimanager")
            UIManager.topdown_widgets_iter = function()
                local index = #shown + 1
                return function()
                    index = index - 1
                    return shown[index]
                end
            end
            local attempts = 0
            NetworkMgr.toggleWifiOn = function(self)
                attempts = attempts + 1
                self:turnOnWifi()
                UIManager:show(dialog)
            end
            local Switcher = require("modules/menu/network_switcher")

            assert.is_true(Switcher.toggleWifi({}, function() end, false, {}))
            assert.are.equal(1, attempts)
            assert.are.same({ dialog }, closed)
            assert.are.equal("network_switcher", network_menu.name)
            scan_task()
            assert.is_true(NetworkMgr.wifi_on)
            assert.are.equal(1, kindle_scans)
            while #scheduled > 0 do table.remove(scheduled, 1)() end
            assert.are.equal("Home", network_menu.item_table[1].text)
        end)
    end

    it("reconnects Kindle Wi-Fi from the title bar and updates the same switcher", function()
        local changed = 0
        local complete_connection
        local name_ready = true
        NetworkMgr.getCurrentNetwork = function(self)
            return { ssid = name_ready and self.current_ssid or "" }
        end
        NetworkMgr.toggleWifiOff = function(self, callback, interactive)
            assert.is_true(interactive)
            self:turnOffWifi()
            callback()
        end
        NetworkMgr.toggleWifiOn = function(self, callback, long_press, interactive)
            assert.is_false(long_press)
            assert.is_true(interactive)
            self.wifi_on = true
            self.pending_connection = true
            complete_connection = function()
                self.current_ssid = "Home"
                self.pending_connection = false
                callback()
            end
        end
        require("modules/menu/network_switcher").open(function() changed = changed + 1 end, true)
        scan_task()
        local original_menu = network_menu
        local toggle = network_menu.custom_title_bar.toggle
        assert.is_true(toggle.value_func())

        toggle.callback()
        assert.is_false(toggle.value_func())
        assert.are.equal("Off", network_menu.item_table[1].text)
        assert.is_false(network_menu.item_table[1].select_enabled)
        assert.are.equal(1, changed)
        assert.are.equal(1, #shown)

        toggle.callback()
        assert.is_true(toggle.value_func())
        assert.are.equal(0, kindle_scans)
        assert.are.equal("Turning on Wi-Fi…", network_menu.item_table[1].text)
        assert.is_function(complete_connection)
        name_ready = false
        complete_connection()
        assert.are.equal("Connected", network_menu.item_table[1].text)
        assert.are.equal(1, #scheduled)
        table.remove(scheduled, 1)()
        assert.are.equal("Connected", network_menu.item_table[1].text)
        assert.are.equal(1, #scheduled)
        name_ready = true
        table.remove(scheduled, 1)()
        assert.are.equal(original_menu, network_menu)
        assert.are.equal("Home", network_menu.item_table[1].text)
        assert.are.equal("Connected", network_menu.item_table[1]._zen_settings_breadcrumb)
        assert.are.equal("wifi-on", network_menu.item_table[1].icon_glyph)
        assert.are.equal(0, #scheduled)
        assert.are.equal(0, kindle_scans)
        assert.are.equal(2, changed)
        assert.are.equal(1, #shown)
        network_menu.item_table[1].callback()
        assert.are.equal("Home", button_dialog.title)
        assert.is_truthy(button_dialog.buttons[3][1].text:find("Disconnect", 1, true))
        assert.is_truthy(button_dialog.buttons[4][1].text:find("Forget", 1, true))

        toggle.callback()
        toggle.callback()
        network_menu:onClose()
        complete_connection()
        assert.are.equal(3, changed)
        assert.are.equal("Turning on Wi-Fi…", network_menu.item_table[1].text)
    end)

    it("updates an open Kobo switcher when Wi-Fi restores externally", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return true end,
            isKobo = function() return true end,
            isKindle = function() return false end,
        })
        NetworkMgr.getConfiguredNetworks = function() return {} end
        require("modules/menu/network_switcher").open(nil, true, {})
        scan_task()
        NetworkMgr.turnOnWifi = function() error("Events must not turn Wi-Fi on") end
        NetworkMgr.getNetworkList = function() error("Events must not scan") end
        local toggle = network_menu.custom_title_bar.toggle

        NetworkMgr:turnOffWifi()
        network_menu:onNetworkDisconnected()
        assert.is_false(toggle.value_func())
        assert.is_false(network_menu.repainted_wifi)
        assert.are.equal("Off", network_menu.item_table[1].text)
        local updates = network_menu.updates

        NetworkMgr.wifi_on = true
        network_menu:onNetworkStateChanged()
        assert.is_true(toggle.value_func())
        assert.is_true(network_menu.repainted_wifi)
        assert.are.equal(updates + 1, network_menu.updates)

        NetworkMgr.current_ssid = "Home"
        network_menu:onNetworkConnected()
        assert.are.equal("Home", network_menu.item_table[1].text)
        assert.are.equal("Connected", network_menu.item_table[1]._zen_settings_breadcrumb)

        local UIManager = require("ui/uimanager")
        UIManager:show({ covers_fullscreen = true })
        updates = network_menu.updates
        network_menu:onNetworkStateChanged()
        network_menu:onClose()
        table.remove(shown)
        network_menu:onNetworkStateChanged()
        assert.are.equal(updates, network_menu.updates)
    end)

    it("keeps scan results and repaints the power toggle during external changes", function()
        require("modules/menu/network_switcher").open()
        finish_scan()
        local scans = kindle_scans
        NetworkMgr.current_ssid = "Guest"
        network_menu:onNetworkConnected()
        assert.are.equal(2, #network_menu.item_table)
        assert.is_nil(network_menu.item_table[1].icon_glyph)
        assert.are.equal("wifi-on", network_menu.item_table[2].icon_glyph)

        NetworkMgr.current_ssid = nil
        network_menu:onNetworkDisconnected()
        assert.are.equal(2, #network_menu.item_table)
        assert.is_nil(network_menu.item_table[2].icon_glyph)
        assert.are.equal(scans, kindle_scans)

        network_menu.custom_title_bar.action.callback()
        local items = network_menu.item_table
        NetworkMgr.wifi_on = false
        network_menu:onNetworkStateChanged()
        assert.is_false(network_menu.repainted_wifi)
        assert.are.equal(items, network_menu.item_table)
        NetworkMgr.wifi_on = true
        network_menu:onNetworkStateChanged()
        assert.is_true(network_menu.repainted_wifi)
        assert.are.equal(items, network_menu.item_table)
        network_menu:onClose()
    end)

    it("refreshes the Kobo status bar after the list toggle turns Wi-Fi off", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return true end,
            isKobo = function() return true end,
            isKindle = function() return false end,
        })
        NetworkMgr.getConfiguredNetworks = function() return {} end
        local complete_shutdown
        NetworkMgr.toggleWifiOff = function(_self, callback, interactive)
            assert.is_true(interactive)
            complete_shutdown = callback
        end
        assert.is_true(require("modules/menu/network_switcher").open(nil, true, {}))
        scan_task()
        local status_wifi_on = true
        local status_refreshes = 0
        network_menu._zen_status_refresh = function()
            status_refreshes = status_refreshes + 1
            status_wifi_on = NetworkMgr:isWifiOn()
        end

        network_menu.custom_title_bar.toggle.callback()
        assert.are.equal(0, status_refreshes)
        NetworkMgr:turnOffWifi()
        complete_shutdown()

        assert.are.equal("Off", network_menu.item_table[1].text)
        assert.is_false(network_menu.custom_title_bar.toggle.value_func())
        assert.are.equal(1, status_refreshes)
        assert.is_false(status_wifi_on)
    end)

    it("uses Kobo's saved-network reconnect from the title bar", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return true end,
            isKobo = function() return true end,
            isKindle = function() return false end,
        })
        NetworkMgr.getConfiguredNetworks = function() return {} end
        NetworkMgr.getAllSavedNetworks = function()
            return { readSetting = function() return { password = "saved", flags = "[WPA2]" } end }
        end
        local reconnects = 0
        NetworkMgr.reconnectOrShowNetworkMenu = function(self, callback)
            reconnects = reconnects + 1
            self.current_ssid = "Home"
            callback()
            return true
        end
        NetworkMgr.turnOnWifi = function(self, callback)
            self.wifi_on = true
            return self:reconnectOrShowNetworkMenu(callback)
        end
        NetworkMgr.toggleWifiOn = function(self, callback) self:turnOnWifi(callback) end
        NetworkMgr.toggleWifiOff = function(self, callback) self:turnOffWifi() callback() end
        NetworkMgr.getWifiMenuTable = function(self)
            return { callback = function(menu)
                self:toggleWifiOn(function() menu:updateItems() end, false, true)
            end }
        end
        NetworkMgr.getNetworkList = function() error("Saved Wi-Fi should reconnect before listing") end
        local changed = 0
        assert.is_true(require("modules/menu/network_switcher").open(function()
            changed = changed + 1
        end, true))
        scan_task()
        local original_menu = network_menu
        local toggle = network_menu.custom_title_bar.toggle
        toggle.callback()
        assert.are.equal("Off", network_menu.item_table[1].text)
        toggle.callback()
        assert.are.equal(1, reconnects)
        assert.are.equal(original_menu, network_menu)
        assert.are.equal("Home", network_menu.item_table[1].text)
        assert.are.equal("Connected", network_menu.item_table[1]._zen_settings_breadcrumb)
        assert.are.equal("wifi-on", network_menu.item_table[1].icon_glyph)
        assert.are.equal(2, changed)
    end)

    for _i, platform in ipairs({ "kindle", "kobo" }) do
        it("keeps the " .. platform .. " switcher open when the header toggle cannot reconnect", function()
            ZenSpec.replace("device", {
                hasWifiManager = function() return true end,
                isKobo = function() return platform == "kobo" end,
                isKindle = function() return platform == "kindle" end,
            })
            NetworkMgr.getConfiguredNetworks = function() return {} end
            local NetworkSetting = {}
            ZenSpec.replace("ui/widget/networksetting", NetworkSetting)
            local dialog = setmetatable({
                onCloseWidget = function() NetworkMgr.pending_connection = false end,
            }, NetworkSetting)
            local UIManager = require("ui/uimanager")
            local close_widget = UIManager.close
            UIManager.close = function(self, widget)
                close_widget(self, widget)
                if widget.onCloseWidget then widget:onCloseWidget() end
            end
            local attempts = 0
            NetworkMgr.toggleWifiOn = function(self)
                attempts = attempts + 1
                self.wifi_on = true
                self.pending_connection = true
                UIManager:show({ text = "Connection failed" })
                UIManager:show(dialog)
            end
            NetworkMgr.getWifiMenuTable = function(self)
                return { callback = function() self:toggleWifiOn() end }
            end
            NetworkMgr.toggleWifiOff = function(self, callback) self:turnOffWifi() callback() end
            require("modules/menu/network_switcher").open()
            scan_task()
            local original_menu = network_menu
            local toggle = network_menu.custom_title_bar.toggle
            toggle.callback()
            toggle.callback()
            while #scheduled > 0 do table.remove(scheduled, 1)() end
            assert.are.equal(1, attempts)
            assert.are.equal(original_menu, network_menu)
            assert.is_false(NetworkMgr.pending_connection)
            assert.are.equal(2, #closed)
            assert.are.equal("Home", network_menu.item_table[1].text)
            assert.are.equal("Saved · 80%", network_menu.item_table[1]._zen_settings_breadcrumb)
        end)
    end

    it("still turns off a connected Kindle", function()
        local calls = 0
        package.loaded["ui/uimanager"].topdown_widgets_iter = function()
            return function() end
        end
        NetworkMgr.getWifiMenuTable = function()
            return { callback = function()
                calls = calls + 1
                NetworkMgr.wifi_on = false
            end }
        end
        local Switcher = require("modules/menu/network_switcher")

        Switcher.toggleWifi({}, nil, false, {})
        assert.are.equal(1, calls)
        assert.is_false(NetworkMgr.wifi_on)
        assert.are.equal(0, #shown)
    end)

    for _i, pending in ipairs({ "pending_connection", "pending_connectivity_check" }) do
        for _j, wifi_on in ipairs({ false, true }) do
            it("recovers Kobo Wi-Fi with " .. pending .. " and radio " .. (wifi_on and "on" or "off"), function()
                ZenSpec.replace("device", {
                    isKobo = function() return true end,
                    isKindle = function() return false end,
                })
                NetworkMgr.wifi_on = wifi_on
                NetworkMgr.current_ssid = nil
                NetworkMgr.pending_connection = false
                NetworkMgr.pending_connectivity_check = false
                NetworkMgr[pending] = true
                local updates, cancellations, connections = 0, 0, 0
                NetworkMgr.disableWifi = function(self, callback, interactive)
                    assert.is_true(interactive)
                    cancellations = cancellations + 1
                    self:turnOffWifi()
                    self.pending_connection = false
                    self.pending_connectivity_check = false
                    if callback then callback() end
                end
                NetworkMgr.toggleWifiOff = NetworkMgr.disableWifi
                NetworkMgr.getWifiMenuTable = function()
                    return { callback = function(menu)
                        assert.is_false(NetworkMgr.pending_connection)
                        assert.is_false(NetworkMgr.pending_connectivity_check)
                        connections = connections + 1
                        NetworkMgr.wifi_on = true
                        NetworkMgr.current_ssid = "Home"
                        menu:updateItems()
                    end }
                end
                local Switcher = require("modules/menu/network_switcher")
                Switcher.open = function() error("Recovery should not open the network picker") end
                local touch_menu = { updateItems = function() updates = updates + 1 end }

                Switcher.toggleWifi(touch_menu)
                assert.are.equal(1, cancellations)
                assert.are.equal(wifi_on and 0 or 1, connections)
                assert.are.equal(1, updates)
                assert.are.equal(not wifi_on, NetworkMgr.wifi_on)
                if wifi_on then
                    Switcher.toggleWifi(touch_menu)
                    assert.are.equal(1, connections)
                    assert.is_true(NetworkMgr.wifi_on)
                end
            end)
        end
    end

    it("uses KOReader's Wi-Fi toggle on Kobo with no saved Zen networks", function()
        ZenSpec.replace("device", {
            isKobo = function() return true end,
            isKindle = function() return false end,
        })
        package.loaded["ui/uimanager"].topdown_widgets_iter = function()
            return function() end
        end
        local updates = 0
        local touch_menu = { updateItems = function() updates = updates + 1 end }
        NetworkMgr.wifi_on = false
        NetworkMgr.current_ssid = nil
        NetworkMgr.getAllSavedNetworks = function()
            error("Kobo toggle should not inspect Zen saved networks")
        end
        NetworkMgr.getWifiMenuTable = function()
            return { callback = function(menu)
                assert.are.equal(touch_menu, menu)
                NetworkMgr.wifi_on = not NetworkMgr.wifi_on
                menu:updateItems()
            end }
        end
        local Switcher = require("modules/menu/network_switcher")
        Switcher.open = function() error("Kobo toggle should not open the Zen switcher") end

        Switcher.toggleWifi(touch_menu, nil, true, {})
        assert.is_true(NetworkMgr.wifi_on)
        Switcher.toggleWifi(touch_menu, nil, true, {})
        assert.is_false(NetworkMgr.wifi_on)
        assert.are.equal(2, updates)
    end)

    it("reconnects Kobo in the background and preserves the asynchronous chooser fallback", function()
        ZenSpec.replace("device", {
            isKobo = function() return true end,
            isKindle = function() return false end,
        })
        NetworkMgr._zen_nonblocking_wifi = true
        NetworkMgr.wifi_on = false
        NetworkMgr.current_ssid = nil
        local fallback
        local completed
        local updates = 0
        package.loaded["ui/uimanager"].topdown_widgets_iter = function() return function() end end
        NetworkMgr.getWifiMenuTable = function() error("Disconnected Wi-Fi must not show a prompt") end
        NetworkMgr.toggleWifiOn = function(_self, callback, long_press, interactive, on_failure)
            assert.is_false(long_press)
            assert.is_true(interactive)
            completed, fallback = callback, on_failure
        end
        local Switcher = require("modules/menu/network_switcher")
        local opened = 0
        local on_connected, plugin = function() end, {}
        Switcher.open = function(callback, settings_subpage, owner)
            assert.are.equal(on_connected, callback)
            assert.is_true(settings_subpage)
            assert.are.equal(plugin, owner)
            opened = opened + 1
        end
        Switcher.toggleWifi({ updateItems = function() updates = updates + 1 end }, on_connected, true, plugin)
        assert.are.equal(0, opened)
        assert.are.equal(0, #shown)
        completed()
        assert.are.equal(1, updates)
        fallback()
        assert.are.equal(1, opened)
    end)

    it("turns Kobo Wi-Fi off after a list disconnect before reconnecting from controls", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return true end,
            isKobo = function() return true end,
            isKindle = function() return false end,
        })
        NetworkMgr._zen_nonblocking_wifi = true
        NetworkMgr.wpa_supplicant = { ctrl_interface = "/test/wlan0" }
        NetworkMgr.getCurrentNetwork = function(self)
            return self.current_ssid and { ssid = self.current_ssid, id = "7" } or nil
        end
        local profiles = {{ ssid = "Home", id = "7" }}
        NetworkMgr.getConfiguredNetworks = function() return profiles end
        ZenSpec.replace("lj-wpaclient/wpaclient", {
            new = function()
                return {
                    sendCtrlCmd = function(_self, command)
                        assert.are.equal("DISCONNECT", command)
                        NetworkMgr.current_ssid = nil
                        return "OK\n"
                    end,
                    close = function() end,
                }
            end,
        })
        local stops, starts, updates = 0, 0, 0
        NetworkMgr.toggleWifiOff = function(self, callback, interactive)
            assert.is_true(interactive)
            stops = stops + 1
            self:turnOffWifi()
            callback()
        end
        NetworkMgr.toggleWifiOn = function(self, callback)
            assert.is_false(self:isWifiOn(), "Must turn the radio off before restarting the supplicant")
            starts = starts + 1
            self:turnOnWifi()
            self.current_ssid = profiles[1].ssid
            callback()
        end
        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        scan_task()
        network_menu.item_table[1].callback()
        button_dialog.buttons[2][1].callback()
        assert.is_true(NetworkMgr:isWifiOn())
        assert.is_false(NetworkMgr:isConnected())
        assert.is_true(NetworkMgr.released)
        local controls = { updateItems = function() updates = updates + 1 end }

        Switcher.toggleWifi(controls)
        assert.is_false(NetworkMgr:isWifiOn())
        assert.are.equal(1, stops)
        assert.are.equal(0, starts)
        Switcher.toggleWifi(controls)
        assert.is_true(NetworkMgr:isConnected())
        assert.are.equal(1, starts)
        assert.are.equal(2, updates)
        assert.are.same({{ ssid = "Home", id = "7" }}, profiles)
        assert.is_nil(NetworkMgr.saved)
        assert.is_nil(NetworkMgr.deleted)
    end)

    it("opens and scans the switcher when KOReader has no saved networks", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return true end,
            isKindle = function() return false end,
        })
        NetworkMgr.wifi_on = false
        NetworkMgr.current_ssid = nil
        NetworkMgr.getAllSavedNetworks = function() return { data = {} } end
        NetworkMgr.getWifiMenuTable = function()
            error("KOReader Wi-Fi toggle should not run")
        end
        local Switcher = require("modules/menu/network_switcher")

        assert.is_true(Switcher.toggleWifi({}, function() end, true, {}))
        assert.are.equal("network_switcher", network_menu.name)
        scan_task()
        assert.is_true(NetworkMgr.wifi_on)
        assert.are.equal("Home", network_menu.item_table[1].text)
    end)

    it("replaces Kobo's native network list with the Zen switcher", function()
        ZenSpec.replace("device", {
            isKobo = function() return true end,
            isKindle = function() return false end,
        })
        NetworkMgr.wifi_on = false
        NetworkMgr.current_ssid = nil
        NetworkMgr.getAllSavedNetworks = function()
            error("Kobo toggle should not inspect Zen saved networks")
        end
        local NetworkSetting = {}
        ZenSpec.replace("ui/widget/networksetting", NetworkSetting)
        local UIManager = package.loaded["ui/uimanager"]
        local windows = {{ text = "Existing message" }}
        UIManager.topdown_widgets_iter = function()
            local index = #windows + 1
            return function()
                index = index - 1
                return windows[index]
            end
        end
        UIManager.close = function(_self, widget)
            closed[#closed + 1] = widget
            if widget.onCloseWidget then widget:onCloseWidget() end
            for index = #windows, 1, -1 do
                if windows[index] == widget then table.remove(windows, index) end
            end
        end
        local stock_calls, switcher_calls = 0, 0
        local dialog = setmetatable({
            network_list = {},
            onCloseWidget = function() NetworkMgr.pending_connection = false end,
        }, NetworkSetting)
        local notice = { text = "Connection failed" }
        NetworkMgr.getWifiMenuTable = function()
            return { callback = function(touch_menu)
                assert.are.equal("touch menu", touch_menu)
                stock_calls = stock_calls + 1
                if stock_calls == 1 then
                    windows[#windows + 1] = dialog
                    windows[#windows + 1] = notice
                    NetworkMgr.pending_connection = true
                end
            end }
        end
        local Switcher = require("modules/menu/network_switcher")
        Switcher.open = function(callback, settings_subpage, plugin)
            switcher_calls = switcher_calls + 1
            assert.is_false(NetworkMgr.pending_connection)
            assert.is_function(callback)
            assert.is_false(settings_subpage)
            assert.are.equal("plugin", plugin)
            return true
        end

        assert.is_true(Switcher.toggleWifi("touch menu", function() end, false, "plugin"))
        assert.are.same({ dialog, notice }, closed)
        assert.are.equal(1, switcher_calls)
        assert.is_nil(Switcher.toggleWifi("touch menu", function() end, false, "plugin"))
        assert.are.equal(2, stock_calls)
        assert.are.equal(1, switcher_calls)
    end)

    for _i, settings_subpage in ipairs({ false, true }) do
        it("toggles PocketBook Wi-Fi from " .. (settings_subpage and "Settings" or "Controls")
                .. " without opening settings", function()
            ZenSpec.replace("device", {
                isPocketBook = function() return true end,
            })
            NetworkMgr.wifi_on = false
            NetworkMgr.current_ssid = nil
            NetworkMgr.getAllSavedNetworks = function()
                error("PocketBook uses firmware-saved networks")
            end
            NetworkMgr.getWifiMenuTable = function()
                error("PocketBook power toggles should not prompt to connect")
            end
            local starts, stops, updates = 0, 0, 0
            NetworkMgr.toggleWifiOn = function(self, callback, long_press, interactive)
                assert.is_false(long_press)
                assert.is_true(interactive)
                starts = starts + 1
                self:turnOnWifi()
                callback()
            end
            NetworkMgr.toggleWifiOff = function(self, callback, interactive)
                assert.is_true(interactive)
                stops = stops + 1
                self:turnOffWifi()
                callback()
            end
            local Switcher = require("modules/menu/network_switcher")
            Switcher.open = function() error("Power toggles must not open PocketBook settings") end
            local touch_menu = { updateItems = function() updates = updates + 1 end }

            Switcher.toggleWifi(touch_menu, nil, settings_subpage, {})
            assert.is_true(NetworkMgr.wifi_on)
            assert.is_false(NetworkMgr:isConnected())
            Switcher.toggleWifi(touch_menu, nil, settings_subpage, {})
            assert.is_false(NetworkMgr.wifi_on)
            Switcher.toggleWifi(touch_menu, nil, settings_subpage, {})
            NetworkMgr.current_ssid = "Home"
            Switcher.toggleWifi(touch_menu, nil, settings_subpage, {})
            assert.is_false(NetworkMgr.wifi_on)
            assert.are.same({ 2, 2, 4 }, { starts, stops, updates })
            assert.are.same({}, shown)
        end)
    end

    it("opens PocketBook settings without changing an active connection", function()
        ZenSpec.replace("device", {
            model = "PB700",
            hasWifiManager = function() return false end,
            hasWifiToggle = function() return true end,
            isPocketBook = function() return true end,
        })
        local launches, callbacks = 0, 0
        ZenSpec.replace("ffi/inkview", {
            OpenBook = function(path, position, flags)
                assert.are.equal("/ebrmain/bin/settings.app", path)
                assert.is_nil(position)
                assert.are.equal(0, flags)
                launches = launches + 1
            end,
        })

        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open(function() callbacks = callbacks + 1 end))
        assert.is_true(Switcher.open(nil, true, {}))

        assert.are.equal(2, launches)
        assert.are.equal(0, callbacks)
        assert.is_true(NetworkMgr.wifi_on)
        assert.are.equal("Home", NetworkMgr.current_ssid)
        assert.is_nil(NetworkMgr.disconnected)
        assert.is_nil(NetworkMgr.released)
        assert.is_nil(scan_task)
        assert.are.same({}, events)
        assert.are.same({}, shown)
    end)

    it("keeps devices without Wi-Fi unsupported", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return false end,
            hasWifiToggle = function() return false end,
            isPocketBook = function() return true end,
        })
        local Switcher = require("modules/menu/network_switcher")
        assert.is_false(Switcher.open())
        assert.are.equal("Network selection is not supported on this device.", shown[1].text)
        assert.is_nil(scan_task)
    end)

    it("opens connected Wi-Fi without scanning or changing the connection", function()
        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        scan_task()

        assert.are.equal(0, kindle_scans)
        assert.are.equal(1, #network_menu.item_table)
        assert.are.equal("Home", network_menu.item_table[1].text)
        assert.are.equal("Connected", network_menu.item_table[1]._zen_settings_breadcrumb)
        assert.is_true(NetworkMgr.wifi_on)
        assert.is_nil(NetworkMgr.released)
        assert.is_nil(NetworkMgr.disconnected)
        assert.are.same({}, events)
        network_menu.item_table[1].callback()
        assert.are.equal(4, #button_dialog.buttons)
        assert.is_truthy(button_dialog.buttons[1][1].text:find("Info", 1, true))
        assert.is_truthy(button_dialog.buttons[2][1].text:find("Edit", 1, true))
        assert.is_truthy(button_dialog.buttons[3][1].text:find("Disconnect", 1, true))
        assert.is_truthy(button_dialog.buttons[4][1].text:find("Forget", 1, true))
        network_menu.dimen = { x = 20, y = 20 }
        network_menu.item_dimen = { w = 560, h = 80 }
        network_menu.title_bar = { getSize = function() return { h = 100 } end }
        network_menu.item_group = {{ entry = network_menu.item_table[1] }}
        local anchor, prefers_down = button_dialog.anchor()
        assert.are.same({ x = 152, y = 149, w = 22, h = 22 }, anchor)
        assert.is_true(prefers_down)
        button_dialog.buttons[4][1].callback()
        assert.are.equal("Forget Wi-Fi network Home?", confirm_box.text)
        confirm_box.ok_callback()
        assert.are.equal(1, kindle_deletes)
        assert.is_false(NetworkMgr.wifi_on)
        assert.are.equal(0, kindle_scans)
    end)

    for _i, case in ipairs({
        { name = "accepts an unchanged IP when reconnecting with a default route",
            route = true, connected = true, sleeps = 0 },
        { name = "waits for a default route when reconnecting with an unchanged IP",
            route = true, connected = true, sleeps = 1 },
        { name = "rejects an unchanged IP when reconnecting without a default route",
            route = false, sleeps = 60 },
        { name = "handles a failed route check when reconnecting with an unchanged IP",
            route_error = true, sleeps = 60 },
        { name = "rejects a stale IP and route when switching to another network",
            switch_network = true, route = true, sleeps = 60 },
        { name = "checks the active SSID before accepting an unchanged IP",
            current_ssid = "Guest", route = true, sleeps = 60 },
        { name = "rejects an unchanged IP and route when authentication selects another SSID",
            actual_ssid = "Guest", route = true, sleeps = 60 },
    }) do
        it(case.name, function()
            local ip = "192.168.1.10"
            ZenSpec.replace("modules/settings/zen_settings_utils", {
                get_device_ip_address = function() return ip end,
            })
            NetworkMgr.hasDefaultRoute = function()
                if case.route_error then error("route unavailable") end
                return case.route and verification_sleeps >= (case.connected and case.sleeps or 0)
            end
            NetworkMgr.obtainIP = function(self)
                self.obtained = true
                if case.actual_ssid then self.current_ssid = case.actual_ssid end
            end
            local reported_network, reported_ip
            local Switcher = require("modules/menu/network_switcher")
            assert.is_true(Switcher.open(function(network, address)
                reported_network, reported_ip = network, address
            end))
            if case.switch_network then finish_scan() else scan_task() end
            local item = network_menu.item_table[case.switch_network and 2 or 1]
            local target_ssid = item.network.ssid
            network_menu:onMenuHold(item)
            button_dialog.buttons[2][1].callback()
            if case.current_ssid then NetworkMgr.current_ssid = case.current_ssid end
            local buttons = password_dialog.buttons[1]
            buttons[#buttons].callback()

            assert.are.equal(case.sleeps, verification_sleeps)
            assert.is_nil(NetworkMgr.released)
            assert.is_nil(NetworkMgr.disconnected)
            if case.connected then
                assert.are.equal(target_ssid, reported_network.ssid)
                assert.are.equal(ip, reported_ip)
                assert.are.equal(target_ssid, NetworkMgr.lease_ssid)
                assert.are.same({ "NetworkConnecting", "NetworkConnected" }, events)
            else
                assert.is_nil(reported_network)
                assert.is_nil(reported_ip)
                assert.is_nil(NetworkMgr.lease_ssid)
                assert.are.same(case.switch_network
                    and { "NetworkConnecting", "NetworkConnecting" }
                    or { "NetworkConnecting" }, events)
                if case.actual_ssid then
                    assert.are.equal("Connected to Guest instead of Home. The password may be incorrect.",
                        password_dialog.description)
                else
                    assert.are.equal("Connected to " .. target_ssid
                        .. ", but no IP address or default route was assigned.",
                        network_menu.item_table[1].text)
                end
            end
        end)
    end

    it("does not scan connected non-Kindle Wi-Fi until refresh", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return true end,
            isKindle = function() return false end,
        })
        local scans = 0
        NetworkMgr.getCurrentNetwork = function()
            return { ssid = "Home", id = 7 }
        end
        NetworkMgr.getAllSavedNetworks = function()
            return { readSetting = function(_self, ssid)
                assert.are.equal("Home", ssid)
                return { flags = "[WPA2]", password = "saved" }
            end }
        end
        NetworkMgr.getNetworkList = function()
            scans = scans + 1
            return {{ ssid = "Home", connected = true }}
        end

        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        scan_task()
        assert.are.equal(0, scans)
        assert.are.equal("Home", network_menu.item_table[1].text)
        network_menu.item_table[1].callback()
        assert.are.equal(4, #button_dialog.buttons)
        button_dialog.buttons[3][1].callback()
        assert.are.equal(7, NetworkMgr.disconnected.wpa_supplicant_id)
        assert.are.equal("saved", network_menu.item_table[1].network.password)
        assert.are.equal("Saved", network_menu.item_table[1]._zen_settings_breadcrumb)
        network_menu.item_table[1].callback()
        assert.is_nil(password_dialog)
        assert.are.equal("Home", NetworkMgr.authenticated.ssid)

        network_menu.custom_title_bar.action.callback()
        assert.are.equal(1, scans)
    end)

    it("disconnects and clears a connected Kobo network when forgotten", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return true end,
            isKobo = function() return true end,
            isKindle = function() return false end,
        })
        NetworkMgr.getCurrentNetwork = function()
            return { ssid = "Home", id = 7 }
        end
        NetworkMgr.getConfiguredNetworks = function() return {} end
        NetworkMgr.getAllSavedNetworks = function()
            return { readSetting = function()
                return { flags = "[WPA2]", password = "saved" }
            end }
        end
        local disconnect_fails = true
        NetworkMgr.disconnectNetwork = function(self, network)
            if disconnect_fails then return nil, "WPA client unavailable" end
            self.disconnected = network
            self.current_ssid = nil
        end
        local refreshes = 0
        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open(function() refreshes = refreshes + 1 end))
        scan_task()
        network_menu.item_table[1].callback()
        button_dialog.buttons[4][1].callback()
        confirm_box.ok_callback()
        assert.is_nil(NetworkMgr.deleted)
        assert.is_true(network_menu.item_table[1].network.connected)
        disconnect_fails = false
        confirm_box.ok_callback()

        assert.are.equal(7, NetworkMgr.disconnected.wpa_supplicant_id)
        assert.is_true(NetworkMgr.released)
        assert.are.equal("Home", NetworkMgr.deleted.ssid)
        assert.are.equal(1, refreshes)
        assert.is_nil(network_menu.item_table[1].network.saved)
        assert.are.equal("Available", network_menu.item_table[1]._zen_settings_breadcrumb)
        network_menu:onMenuHold(network_menu.item_table[1])
        assert.are.equal(2, #button_dialog.buttons)
    end)

    it("persists Kobo Forget before deleting KOReader credentials", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return true end,
            isKobo = function() return true end,
            isKindle = function() return false end,
        })
        NetworkMgr.wpa_supplicant = { ctrl_interface = "/var/run/wpa_supplicant/wlan0" }
        NetworkMgr.getCurrentNetwork = function(self)
            return self.current_ssid and { ssid = self.current_ssid, id = "7" } or nil
        end
        local profiles = {{ ssid = "Home", id = "7" }, { ssid = "Guest", id = "8" }}
        NetworkMgr.getConfiguredNetworks = function() return profiles end
        local saved = { flags = "[WPA2]", password = "saved" }
        NetworkMgr.getAllSavedNetworks = function()
            return { readSetting = function() return saved end }
        end
        NetworkMgr.deleteNetwork = function(self, network)
            self.deleted = network
            saved = nil
        end
        NetworkMgr.disconnectNetwork = function() error("profile was already removed") end
        local commands = {}
        local save_fails = true
        ZenSpec.replace("lj-wpaclient/wpaclient", {
            new = function()
                return {
                    sendCtrlCmd = function(_self, command)
                        commands[#commands + 1] = command
                        if command == "REMOVE_NETWORK 7" then
                            profiles = {{ ssid = "Guest", id = "8" }}
                            NetworkMgr.current_ssid = nil
                        elseif command == "RECONFIGURE" then
                            profiles = {{ ssid = "Home", id = "7" }, { ssid = "Guest", id = "8" }}
                            NetworkMgr.current_ssid = "Home"
                        elseif command == "SAVE_CONFIG" and save_fails then
                            return "FAIL\n"
                        end
                        return "OK\n"
                    end,
                    close = function() end,
                }
            end,
        })

        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        scan_task()
        network_menu.item_table[1].callback()
        button_dialog.buttons[4][1].callback()
        confirm_box.ok_callback()
        assert.are.same({ "REMOVE_NETWORK 7", "SAVE_CONFIG", "RECONFIGURE" }, commands)
        assert.is_nil(NetworkMgr.deleted)
        assert.is_true(network_menu.item_table[1].network.connected)

        save_fails = false
        confirm_box.ok_callback()
        assert.are.same({ "REMOVE_NETWORK 7", "SAVE_CONFIG", "RECONFIGURE",
            "REMOVE_NETWORK 7", "SAVE_CONFIG" }, commands)
        assert.are.same({{ ssid = "Guest", id = "8" }}, profiles)
        assert.are.equal("Home", NetworkMgr.deleted.ssid)
        assert.is_true(NetworkMgr.released)
        assert.are.equal("Available", network_menu.item_table[1]._zen_settings_breadcrumb)
        network_menu.item_table[1].callback()
        assert.is_not_nil(password_dialog)
    end)

    it("reuses a Kobo-configured network after disconnect without a KOReader password", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return true end,
            isKobo = function() return true end,
            isKindle = function() return false end,
        })
        NetworkMgr.wpa_supplicant = { ctrl_interface = "/var/run/wpa_supplicant/wlan0" }
        NetworkMgr.getCurrentNetwork = function(self)
            return self.current_ssid and { ssid = self.current_ssid, id = "7" } or nil
        end
        NetworkMgr.getConfiguredNetworks = function()
            return {{ ssid = "Home", id = "7" }}
        end
        NetworkMgr.getNetworkList = function()
            return {{ ssid = "Home", flags = "[WPA2]", signal_quality = 80 }}
        end
        NetworkMgr.disconnectNetwork = function() error("Kobo profile must be preserved") end
        local commands = {}
        local association_checks = 0
        ZenSpec.replace("lj-wpaclient/wpaclient", {
            __index = { enableNetworkByID = function() end },
            new = function(path)
                assert.are.equal("/var/run/wpa_supplicant/wlan0", path)
                return {
                    sendCtrlCmd = function(_self, command)
                        commands[#commands + 1] = command
                        if command == "DISCONNECT" then NetworkMgr.current_ssid = nil end
                        if command == "SELECT_NETWORK 7" then NetworkMgr.current_ssid = "Home" end
                        return "OK\n"
                    end,
                    getConnectedNetwork = function()
                        association_checks = association_checks + 1
                        if association_checks == 1 then return nil end
                        return NetworkMgr.current_ssid and { id = "7" } or nil
                    end,
                    attach = function() return true end,
                    readAllEvents = function() end,
                    close = function() end,
                }
            end,
        })

        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        scan_task()
        network_menu.item_table[1].callback()
        button_dialog.buttons[2][1].callback()
        assert.are.same({ "DISCONNECT" }, commands)
        assert.is_true(NetworkMgr.released)
        assert.are.equal("Saved", network_menu.item_table[1]._zen_settings_breadcrumb)

        assert.is_true(Switcher.open())
        scan_task()
        assert.are.equal("Saved · 80%", network_menu.item_table[1]._zen_settings_breadcrumb)
        network_menu:onMenuHold(network_menu.item_table[1])
        assert.is_truthy(button_dialog.buttons[3][1].text:find("Forget", 1, true))
        network_menu.item_table[1].callback()
        assert.is_nil(password_dialog)
        assert.are.same({ "DISCONNECT", "SELECT_NETWORK 7",
            "ENABLE_NETWORK all" }, commands)
        assert.are.equal(2, association_checks)
        assert.are.equal(1, verification_sleeps)
        assert.is_nil(NetworkMgr.authenticated)
        assert.are.equal("Connected · 80%", network_menu.item_table[1]._zen_settings_breadcrumb)

        network_menu.item_table[1].callback()
        button_dialog.buttons[2][1].callback()
        ip_calls = 0
        password_dialog.buttons[1][3].callback()
        assert.are.equal("guest-password", NetworkMgr.authenticated.password)
        assert.are.same({ "DISCONNECT", "SELECT_NETWORK 7",
            "ENABLE_NETWORK all" }, commands)
    end)

    for _i, case in ipairs({
        { name = "keeps a successful Kobo DHCP lease", success_on = 1, attempts = 1, connected = true },
        { name = "keeps Kobo local IPv4 connectivity without a default route",
            success_on = 1, attempts = 1, connected = true, address = "192.168.1.10" },
        { name = "retries Kobo DHCP once after a timeout", success_on = 2, attempts = 2, connected = true },
        { name = "rejects Kobo link-local connectivity after both DHCP attempts fail",
            success_on = 3, attempts = 2, connected = false },
    }) do
        it(case.name, function()
            local attempts = 0
            NetworkMgr.obtainIP = function(self)
                assert.are.equal(NetworkMgr, self)
                attempts = attempts + 1
            end
            ZenSpec.replace("modules/settings/zen_settings_utils", {
                get_device_ip_address = function()
                    return attempts >= case.success_on and case.address or nil
                end,
            })
            NetworkMgr.hasDefaultRoute = function()
                return not case.address and attempts >= case.success_on
            end
            local Kobo = require("modules/menu/network_adapters/kobo")
            Kobo.install(NetworkMgr)
            local obtain_ip, is_connected = NetworkMgr.obtainIP, NetworkMgr.isConnected
            Kobo.install(NetworkMgr)
            assert.are.equal(obtain_ip, NetworkMgr.obtainIP)
            assert.are.equal(is_connected, NetworkMgr.isConnected)
            assert.is_false(NetworkMgr:isConnected())

            NetworkMgr:obtainIP()

            assert.are.equal(case.attempts, attempts)
            assert.are.equal(case.connected, NetworkMgr:isConnected())
            NetworkMgr.current_ssid = nil
            assert.is_false(NetworkMgr:isConnected())
        end)
    end

    for _i, recovered in ipairs({ false, true }) do
        it(recovered and "recovers a timed-out Nickel profile without KOReader credentials"
                or "stops a timed-out Nickel profile after one radio reset", function()
            NetworkMgr.wpa_supplicant = { ctrl_interface = "/var/run/wpa_supplicant/wlan0" }
            local resets, starts = 0, 0
            NetworkMgr.getConfiguredNetworks = function()
                return {{ ssid = "Home", id = resets == 0 and "7" or "9" }}
            end
            NetworkMgr.turnOffWifi = function() resets = resets + 1 end
            NetworkMgr.reconnectOrShowNetworkMenu = function() error("Must not recurse into authentication") end
            local reconnect = NetworkMgr.reconnectOrShowNetworkMenu
            NetworkMgr.turnOnWifi = function(self)
                starts = starts + 1
                return self:reconnectOrShowNetworkMenu()
            end
            NetworkMgr.authenticateNetwork = function() error("Nickel password is unavailable in KOReader") end
            local commands = {}
            local selected
            ZenSpec.replace("lj-wpaclient/wpaclient", {
                new = function()
                    return {
                        sendCtrlCmd = function(_self, command)
                            commands[#commands + 1] = command
                            if command == "SELECT_NETWORK 9" then selected = "9" end
                            return "OK\n"
                        end,
                        getConnectedNetwork = function()
                            if recovered and selected then return { id = selected } end
                            return nil, "ASSOCIATING"
                        end,
                        attach = function() return true end,
                        readAllEvents = function() end,
                        close = function() end,
                    }
                end,
            })
            local Kobo = require("modules/menu/network_adapters/kobo")
            local adapter = Kobo.new(NetworkMgr, require("common/zen_logger").new())
            local network = { ssid = "Home", wpa_supplicant_id = "4" }
            local connected, reason = adapter.connect(network)
            assert.are.equal(recovered, connected)
            assert.are.equal(recovered and "Authenticated" or "Timed out", reason)
            assert.are.equal(recovered and 120 or 240, verification_sleeps)
            assert.are.equal(1, resets)
            assert.are.equal(1, starts)
            assert.are.equal(reconnect, NetworkMgr.reconnectOrShowNetworkMenu)
            assert.is_nil(network.password)
            assert.is_nil(NetworkMgr.saved)
            assert.is_nil(NetworkMgr.deleted)
            if recovered then
                assert.are.equal("9", network.wpa_supplicant_id)
                assert.are.same({ "SELECT_NETWORK 7", "ENABLE_NETWORK all", "DISCONNECT",
                    "SELECT_NETWORK 9", "ENABLE_NETWORK all" }, commands)
            else
                assert.are.same({ "SELECT_NETWORK 7", "ENABLE_NETWORK all", "DISCONNECT",
                    "SELECT_NETWORK 9", "ENABLE_NETWORK all", "DISCONNECT" }, commands)
            end
        end)
    end

    for _i, case in ipairs({
        { name = "retries a rejected Kobo handshake once", failures = 2,
            message = "WPA: 4-Way Handshake failed - pre-shared key may be incorrect" },
        { name = "retries a rejected Kobo password once", failures = 2,
            message = 'CTRL-EVENT-SSID-TEMP-DISABLED id=7 ssid="Home" reason=WRONG_KEY' },
    }) do
        it(case.name .. " and asks for a new password", function()
            ZenSpec.replace("device", {
                hasWifiManager = function() return true end,
                isKobo = function() return true end,
                isKindle = function() return false end,
            })
            NetworkMgr.current_ssid = nil
            NetworkMgr.wpa_supplicant = { ctrl_interface = "/var/run/wpa_supplicant/wlan0" }
            NetworkMgr.getConfiguredNetworks = function()
                return {{ ssid = "Home", id = "7" }}
            end
            NetworkMgr.getNetworkList = function()
                return {{ ssid = "Home", flags = "[WPA2]", password = "saved", signal_quality = 80 }}
            end
            local commands = {}
            local polls = 0
            local attached = false
            local client_closed = false
            ZenSpec.replace("lj-wpaclient/wpaclient", {
                __index = { enableNetworkByID = function() end },
                new = function()
                    return {
                        attach = function() attached = true return true end,
                        sendCtrlCmd = function(_self, command)
                            assert.is_true(attached)
                            commands[#commands + 1] = command
                            return "OK\n"
                        end,
                        getConnectedNetwork = function() return nil end,
                        readAllEvents = function()
                            polls = polls + 1
                            return {{
                                msg = polls == 1
                                    and "CTRL-EVENT-DISCONNECTED reason=3 locally_generated=1"
                                    or case.message,
                                isAuthFailed = function(self)
                                    return self.msg:find("CTRL-EVENT-DISCONNECTED", 1, true) ~= nil
                                end,
                            }}
                        end,
                        close = function() client_closed = true end,
                    }
                end,
            })

            local Switcher = require("modules/menu/network_switcher")
            assert.is_true(Switcher.open())
            scan_task()
            network_menu.item_table[1].callback()
            assert.are.equal(case.failures + 1, polls)
            assert.is_true(client_closed)
            assert.are.same({ "SELECT_NETWORK 7", "ENABLE_NETWORK all", "DISCONNECT" }, commands)
            assert.is_nil(NetworkMgr.deleted)
            assert.is_nil(NetworkMgr.obtained)
            assert.are.equal("Home", password_dialog.title)
            assert.are.equal("Failed to authenticate", password_dialog.description)
            assert.are.equal("saved", password_dialog.input)

            ip_calls = 0
            password_dialog.buttons[1][3].callback()
            assert.are.equal("guest-password", NetworkMgr.authenticated.password)
            assert.are.equal("Connected · 80%", network_menu.item_table[1]._zen_settings_breadcrumb)
            assert.are.equal(case.failures + 1, polls)
        end)
    end

    it("keeps associating through transient Kobo disconnects and timeouts", function()
        NetworkMgr.wpa_supplicant = { ctrl_interface = "/var/run/wpa_supplicant/wlan0" }
        local polls = 0
        ZenSpec.replace("lj-wpaclient/wpaclient", {
            new = function()
                return {
                    attach = function() return true end,
                    sendCtrlCmd = function() return "OK\n" end,
                    getConnectedNetwork = function()
                        if polls == 4 then return { id = "7" } end
                    end,
                    readAllEvents = function()
                        polls = polls + 1
                        return {{
                            msg = polls % 2 == 0 and "Authentication with AP timed out."
                                or "CTRL-EVENT-DISCONNECTED reason=3 locally_generated=0",
                            isAuthFailed = function() return true end,
                        }}
                    end,
                    close = function() end,
                }
            end,
        })
        local adapter = require("modules/menu/network_adapters/kobo").new(
            NetworkMgr, require("common/zen_logger").new())
        assert.is_true(adapter.connect({ ssid = "Home", wpa_supplicant_id = "7" }))
        assert.are.equal(4, polls)
    end)

    it("resets a stalled Kobo radio once with the same KOReader-only credentials", function()
        local attempts, resets, starts = 0, 0, 0
        local network = { ssid = "Home", password = "saved", psk = "saved-psk" }
        NetworkMgr.current_ssid = nil
        NetworkMgr.authenticateNetwork = function(_self, candidate)
            attempts = attempts + 1
            assert.are.equal(network, candidate)
            assert.are.equal("saved", candidate.password)
            assert.are.equal("saved-psk", candidate.psk)
            return attempts > 1, attempts == 1 and "Timed out" or "Authenticated"
        end
        NetworkMgr.turnOffWifi = function() resets = resets + 1 end
        NetworkMgr.reconnectOrShowNetworkMenu = function() error("Must not recurse into authentication") end
        local reconnect = NetworkMgr.reconnectOrShowNetworkMenu
        NetworkMgr.turnOnWifi = function(self)
            starts = starts + 1
            return self:reconnectOrShowNetworkMenu()
        end
        local Kobo = require("modules/menu/network_adapters/kobo")
        Kobo.install(NetworkMgr)
        assert.is_true(NetworkMgr:authenticateNetwork(network))
        assert.are.equal(2, attempts)
        assert.are.equal(1, resets)
        assert.are.equal(1, starts)
        assert.are.equal(reconnect, NetworkMgr.reconnectOrShowNetworkMenu)

        attempts = 0
        NetworkMgr._zen_kobo_authenticate = function() attempts = attempts + 1 return false, "Timed out" end
        assert.is_false(NetworkMgr:authenticateNetwork(network))
        assert.are.equal(2, attempts)
        assert.are.equal(2, resets)
        assert.are.equal(reconnect, NetworkMgr.reconnectOrShowNetworkMenu)
    end)

    it("queues Kobo scans in the worker while a connection is pending", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return true end,
            isKobo = function() return true end,
            isKindle = function() return false end,
        })
        NetworkMgr.current_ssid = nil
        NetworkMgr.pending_connection = true
        local action, callback, scans = nil, nil, 0
        local get_networks = NetworkMgr.getNetworkList
        NetworkMgr.getNetworkList = function(self)
            scans = scans + 1
            return get_networks(self)
        end
        NetworkMgr.runWifiAsync = function(_self, work, complete, queued_only)
            assert.is_true(queued_only)
            action, callback = work, complete
        end
        assert.is_true(require("modules/menu/network_switcher").open())
        scan_task()
        assert.are.equal(0, scans)
        assert.are.equal("Searching for networks…", network_menu.item_table[1].text)
        callback(action())
        assert.are.equal(1, scans)
        assert.are.equal("Home", network_menu.item_table[1].text)
        assert.is_true(NetworkMgr.pending_connection)
        network_menu.custom_title_bar.action.callback()
        callback(nil, "Scan failed")
        assert.are.equal(1, scans)
        assert.are.equal("Scan failed", network_menu.item_table[1].text)
    end)

    it("keeps saved Kobo credentials after a connection timeout", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return true end,
            isKobo = function() return true end,
            isKindle = function() return false end,
        })
        NetworkMgr.current_ssid = nil
        local complete
        NetworkMgr.runWifiAsync = function(_self, action, callback, queued_only)
            if queued_only then return callback(action()) end
            complete = callback
        end
        assert.is_true(require("modules/menu/network_switcher").open())
        scan_task()
        local network = network_menu.item_table[1].network
        network_menu.item_table[1].callback()
        complete({ failure = "authentication", auth_error = "Timed out" })
        assert.is_nil(password_dialog)
        assert.is_nil(NetworkMgr.deleted)
        assert.are.equal("saved", network.password)
        assert.are.equal("Timed out", network_menu.item_table[1].text)
    end)

    it("shows one Kobo network across bands and clears its credentials on Forget", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return true end,
            isKobo = function() return true end,
            isKindle = function() return false end,
        })
        NetworkMgr.current_ssid = nil
        NetworkMgr.getConfiguredNetworks = function() return {} end
        local saved = ZenSpec.memorySettings()
        NetworkMgr.getAllSavedNetworks = function() return saved end
        NetworkMgr.saveNetwork = function(_self, network)
            saved:saveSetting(network.ssid, { password = network.password, psk = network.psk })
        end
        NetworkMgr.deleteNetwork = function(_self, network) saved:delSetting(network.ssid) end
        NetworkMgr.disconnectNetwork = function(self) self.current_ssid = nil end
        local connected_band
        NetworkMgr.getNetworkList = function()
            local credentials = saved:readSetting("Home")
            return {
                { ssid = "Home", flags = "[WPA2]", bssid = "strong", signal_quality = 68,
                    password = credentials and credentials.password },
                { ssid = "Home", flags = "[WPA2]", bssid = "weak", signal_quality = 58,
                    password = credentials and credentials.password, connected = connected_band },
                { ssid = "Other", flags = "[WPA2]", signal_quality = 20 },
            }
        end
        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        scan_task()
        assert.are.equal(2, #network_menu.item_table)
        assert.are.equal(68, network_menu.item_table[1].network.signal_quality)
        network_menu.item_table[1].callback()
        password_dialog.buttons[1][2].callback()
        assert.are.equal("Connected · 68%", network_menu.item_table[1]._zen_settings_breadcrumb)
        assert.is_false(network_menu.item_table[2].network.connected)

        connected_band = true
        network_menu.custom_title_bar.action.callback()
        assert.are.equal(2, #network_menu.item_table)
        assert.are.equal("Connected · 58%", network_menu.item_table[1]._zen_settings_breadcrumb)
        network_menu.item_table[1].callback()
        button_dialog.buttons[4][1].callback()
        confirm_box.ok_callback()
        assert.is_nil(saved:readSetting("Home"))
        assert.are.equal("58%", network_menu.item_table[1]._zen_settings_breadcrumb)
        password_dialog = nil
        network_menu.item_table[1].callback()
        assert.are.equal("", password_dialog.input)
    end)

    for _i, state in ipairs({ "DISCONNECTED", "INACTIVE" }) do
        it("retries an empty Kobo scan in " .. state .. " state", function()
            ZenSpec.replace("device", {
                hasWifiManager = function() return true end,
                isKobo = function() return true end,
                isKindle = function() return false end,
            })
            NetworkMgr.current_ssid = nil
            NetworkMgr.wpa_supplicant = { ctrl_interface = "/var/run/wpa_supplicant/wlan0" }
            NetworkMgr.getConfiguredNetworks = function() return {} end
            local scans = 0
            local commands = {}
            local resumed = state ~= "DISCONNECTED"
            NetworkMgr.getNetworkList = function()
                scans = scans + 1
                if scans == 1 or not resumed then return {} end
                return {{ ssid = "Home", flags = "[WPA2]", signal_quality = 68 }}
            end
            ZenSpec.replace("lj-wpaclient/wpaclient", {
                new = function()
                    return {
                        getStatus = function() return { wpa_state = state } end,
                        sendCtrlCmd = function(_self, command)
                            commands[#commands + 1] = command
                            resumed = true
                            return "OK\n"
                        end,
                        close = function() scan_handle_closes = scan_handle_closes + 1 end,
                    }
                end,
            })
            assert.is_true(require("modules/menu/network_switcher").open())
            scan_task()
            assert.are.equal(2, scans)
            assert.are.same(state == "DISCONNECTED" and { "RECONNECT" } or {}, commands)
            assert.are.equal(1, scan_handle_closes)
            assert.are.equal("Home", network_menu.item_table[1].text)
        end)
    end

    it("resumes Kobo password authentication after Disconnect and Forget", function()
        NetworkMgr.wpa_supplicant = { ctrl_interface = "/var/run/wpa_supplicant/wlan0" }
        local profiles = {{ ssid = "Home", id = "7" }, { ssid = "Other", id = "8" }}
        NetworkMgr.getConfiguredNetworks = function() return profiles end
        local disconnected = false
        local current_id = "7"
        local other_enabled = true
        local auth_client
        local attached = false
        local removed_network
        local WpaClient = { __index = {} }
        WpaClient.new = function()
            return setmetatable({}, WpaClient)
        end
        local methods = WpaClient.__index
        methods.sendCtrlCmd = function(_self, command)
            if command == "DISCONNECT" then
                disconnected = true
                current_id = nil
            elseif command == "REMOVE_NETWORK 7" then
                table.remove(profiles, 1)
            elseif command == "SELECT_NETWORK 9" then
                assert.is_true(attached)
                disconnected = false
                other_enabled = false
                current_id = "9"
            elseif command == "ENABLE_NETWORK all" then
                other_enabled = true
            elseif command == "ENABLE_NETWORK 9" and not disconnected then
                current_id = "9"
            end
            return "OK\n"
        end
        methods.enableNetworkByID = function(self, id)
            return self:sendCtrlCmd("ENABLE_NETWORK " .. id)
        end
        local original_enable = methods.enableNetworkByID
        methods.addNetwork = function(self)
            auth_client = self
            return "9"
        end
        methods.setNetwork = function(_self, id, key, value)
            assert.are.equal("9", id)
            assert.are.equal(key == "ssid" and "Home" or "new-psk", value)
            return "OK"
        end
        methods.getConnectedNetwork = function()
            if current_id then return { id = current_id, ssid = "Home" } end
            return nil, "DISCONNECTED"
        end
        methods.attach = function() attached = true return true end
        methods.readEvent = function() end
        methods.readAllEvents = function() return {} end
        methods.waitForEvent = function() end
        methods.removeNetwork = function(_self, id) removed_network = id end
        methods.close = function(self) self.closed = true attached = false end
        ZenSpec.replace("lj-wpaclient/wpaclient", WpaClient)
        ZenSpec.replace("ffi/crypto", {
            pbkdf2_hmac_sha1 = function(password, ssid)
                assert.are.equal("new-password", password)
                assert.are.equal("Home", ssid)
                return "new-psk"
            end,
        })
        ZenSpec.replace("ffi/sha2", { bin_to_hex = function(value) return value end })
        ZenSpec.replace("util", {})
        ZenSpec.unload("ui/network/wpa_supplicant")
        NetworkMgr.authenticateNetwork = require("ui/network/wpa_supplicant").authenticateNetwork
        local Kobo = require("modules/menu/network_adapters/kobo")
        local adapter = Kobo.new(NetworkMgr, require("common/zen_logger").new())
        local network = { ssid = "Home", wpa_supplicant_id = "7", password = "new-password" }

        assert.is_true(adapter.disconnect(network, true))
        assert.is_true(adapter.forgetNetwork(network))
        assert.is_true(adapter.connect(network, true))
        assert.is_false(disconnected)
        assert.are.equal("9", network.wpa_supplicant_id)
        assert.are.equal("new-psk", NetworkMgr.saved.psk)
        assert.are.same({{ ssid = "Other", id = "8" }}, profiles)
        assert.is_true(other_enabled)
        assert.is_true(auth_client.closed)
        assert.are.equal(original_enable, methods.enableNetworkByID)

        assert.is_true(adapter.disconnect(network, true))
        local reconnected, reconnect_error = NetworkMgr:authenticateNetwork(network)
        assert.is_false(reconnected)
        assert.are.equal("Timed out", reconnect_error)
        assert.is_true(disconnected)

        Kobo.install(NetworkMgr)
        local installed_authenticate = NetworkMgr.authenticateNetwork
        Kobo.install(NetworkMgr)
        assert.are.equal(installed_authenticate, NetworkMgr.authenticateNetwork)
        assert.is_true(NetworkMgr:authenticateNetwork(network))
        assert.is_false(disconnected)
        assert.is_nil(password_dialog)
        assert.is_true(other_enabled)
        assert.is_true(auth_client.closed)
        assert.are.equal(original_enable, methods.enableNetworkByID)

        local failure_events = 0
        removed_network = nil
        local show = require("ui/uimanager").show
        methods.getConnectedNetwork = function() return nil, "4WAY_HANDSHAKE" end
        methods.readEvent = function()
            error("Password authentication should read events in order")
        end
        methods.readAllEvents = function(_self, queued)
            failure_events = failure_events + 1
            queued[1] = {
                msg = failure_events == 1
                    and "CTRL-EVENT-DISCONNECTED reason=3 locally_generated=1"
                    or 'CTRL-EVENT-SSID-TEMP-DISABLED id=9 ssid="Home" reason=WRONG_KEY',
                isAuthFailed = function(self)
                    return self.msg:find("CTRL-EVENT-DISCONNECTED", 1, true) ~= nil
                end,
                isAuthSuccessful = function() return false end,
                isScanEvent = function() return false end,
            }
            return queued
        end
        local authenticated, err = adapter.connect(network, true)
        assert.is_false(authenticated)
        assert.are.equal("Failed to authenticate", err)
        assert.are.equal(3, failure_events)
        assert.are.equal("9", removed_network)
        assert.is_true(disconnected)
        assert.is_true(other_enabled)
        assert.is_true(auth_client.closed)
        assert.are.equal(original_enable, methods.enableNetworkByID)
        assert.are.equal(show, require("ui/uimanager").show)
        assert.are.equal(shown[#shown], closed[#closed])

        failure_events = 0
        methods.getConnectedNetwork = function()
            if failure_events == 2 then return { id = "9", ssid = "Home" } end
            return nil, "4WAY_HANDSHAKE"
        end
        assert.is_true(adapter.connect(network, true))
        assert.are.equal(2, failure_events)
        assert.is_true(other_enabled)
        assert.is_true(auth_client.closed)

        NetworkMgr._zen_kobo_authenticate = function()
            auth_client = WpaClient.new()
            auth_client:enableNetworkByID("9")
            error("authentication interrupted")
        end
        authenticated, err = adapter.connect(network, true)
        assert.is_false(authenticated)
        assert.is_truthy(err:find("authentication interrupted", 1, true))
        assert.is_true(disconnected)
        assert.is_true(other_enabled)
        assert.is_true(auth_client.closed)
        assert.are.equal(original_enable, methods.enableNetworkByID)

        local clock = 0
        ZenSpec.replace("ui/time", {
            now = function() clock = clock + 10 return clock end,
            s = function(seconds) return seconds end,
        })
        NetworkMgr._zen_kobo_authenticate = require("ui/network/wpa_supplicant").authenticateNetwork
        methods.getConnectedNetwork = function() return nil, "ASSOCIATING" end
        methods.readAllEvents = function(_self, queued)
            queued[1] = {
                msg = "CTRL-EVENT-SCAN-RESULTS",
                isAuthFailed = function() return false end,
                isAuthSuccessful = function() return false end,
                isScanEvent = function() return true end,
            }
            return queued
        end
        local bounded = Kobo.new(NetworkMgr, require("common/zen_logger").new())
        authenticated, err = bounded.connect(network, true)
        assert.is_false(authenticated)
        assert.are.equal("Timed out", err)
        assert.are.equal(80, clock) -- Two attempts, bounded despite continuous events.
        assert.are.equal("9", removed_network)
        assert.is_true(auth_client.closed)
        assert.are.equal(original_enable, methods.enableNetworkByID)
    end)

    it("saves a Kobo connection and remembers Wi-Fi for restoration", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return true end,
            isKobo = function() return true end,
            isKindle = function() return false end,
        })
        local saved_password
        local saves = 0
        NetworkMgr.wifi_on = false
        NetworkMgr.current_ssid = nil
        NetworkMgr.wifi_was_on = false
        G_reader_settings:saveSetting("wifi_was_on", false)
        NetworkMgr.getNetworkList = function()
            return {{
                ssid = "Guest", flags = "[WPA2]", signal_quality = 80,
                password = saved_password,
            }}
        end
        NetworkMgr.saveNetwork = function(_self, network)
            saves = saves + 1
            saved_password = network.password
        end
        NetworkMgr.getAllSavedNetworks = function()
            return { readSetting = function()
                return saved_password and { password = saved_password } or nil
            end }
        end
        NetworkMgr.isOnline = function() return true end
        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        scan_task()
        network_menu.item_table[1].callback()
        password_dialog.buttons[1][2].callback()

        assert.are.equal("guest-password", saved_password)
        assert.are.equal(1, saves)
        assert.is_true(NetworkMgr.wifi_was_on)
        assert.is_true(G_reader_settings:isTrue("wifi_was_on"))

        NetworkMgr.wifi_on = false
        NetworkMgr.current_ssid = nil
        ip_calls = 0
        password_dialog = nil
        assert.is_true(Switcher.open())
        scan_task()
        assert.are.equal("Saved · 80%", network_menu.item_table[1]._zen_settings_breadcrumb)
        network_menu.item_table[1].callback()
        assert.is_nil(password_dialog)
        assert.are.equal("Guest", NetworkMgr.authenticated.ssid)
        assert.are.equal(2, #follow_up_checks)
        follow_up_checks[2]()

        local messages = {}
        for _i, entry in ipairs(logs) do
            messages[#messages + 1] = entry[2]
            for _j, value in ipairs(entry) do
                assert.not_equal("guest-password", value)
            end
        end
        local output = table.concat(messages, "\n")
        assert.is_truthy(output:find("Kobo scan result", 1, true))
        assert.is_truthy(output:find("Kobo scan network", 1, true))
        assert.is_truthy(output:find("Kobo credentials saved", 1, true))
        assert.is_truthy(output:find("Kobo credentials before auth", 1, true))
        assert.is_truthy(output:find("Kobo connection result", 1, true))
        assert.is_truthy(output:find("Kobo connection follow-up", 1, true))
    end)

    it("scans automatically when there is no current network", function()
        NetworkMgr.current_ssid = nil
        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        scan_task()
        assert.are.equal(1, kindle_scans)
    end)

    it("limits network-name retries to eight over five seconds", function()
        local reads = 0
        local retry_time = 0
        local UIManager = require("ui/uimanager")
        local schedule_in = UIManager.scheduleIn
        UIManager.scheduleIn = function(self, delay, action)
            retry_time = retry_time + delay
            schedule_in(self, delay, action)
        end
        NetworkMgr.getCurrentNetwork = function()
            reads = reads + 1
            error("network name unavailable")
        end
        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        scan_task()
        for _i = 1, 8 do
            assert.are.equal(1, #scheduled)
            table.remove(scheduled, 1)()
        end
        assert.are.equal(9, reads)
        assert.are.equal(5, retry_time)
        assert.are.equal(0, #scheduled)
        assert.are.equal(0, kindle_scans)
        assert.are.equal("Connected", network_menu.item_table[1].text)
    end)

    for _i, action in ipairs({ "close", "off", "scan" }) do
        it("cancels network-name retries on " .. action, function()
            NetworkMgr.getCurrentNetwork = function() return { ssid = "" } end
            NetworkMgr.toggleWifiOff = function(self, callback) self:turnOffWifi() callback() end
            assert.is_true(require("modules/menu/network_switcher").open())
            scan_task()
            assert.are.equal(1, #scheduled)
            local pending = scheduled[1]
            if action == "close" then
                network_menu:onClose()
            elseif action == "off" then
                network_menu.custom_title_bar.toggle.callback()
            else
                network_menu.custom_title_bar.action.callback()
            end
            for _j, task in ipairs(scheduled) do assert.not_equal(pending, task) end
            while #scheduled > 0 do table.remove(scheduled, 1)() end
            assert.are.equal(action == "scan" and 1 or 0, kindle_scans)
            assert.are.equal(action == "scan" and "Home" or action == "off" and "Off" or "Connected",
                network_menu.item_table[1].text)
        end)
    end

    it("cancels an active scan and accepts idle results after reopening", function()
        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        scan_task()
        network_menu.custom_title_bar.action.callback()

        assert.are.equal(1, kindle_scans)
        assert.are.equal(1, #scheduled)
        local pending_poll = scheduled[1]

        network_menu.custom_title_bar.close_callback()

        assert.are.equal(0, #scheduled)
        assert.are.equal(1, scan_handle_closes)
        pending_poll()
        assert.are.equal("Searching for networks…", network_menu.item_table[1].text)

        kindle_scan_stays_idle = true
        assert.is_true(Switcher.open())
        finish_scan()
        assert.are.equal(2, kindle_scans)
        assert.are.equal("Guest", network_menu.item_table[2].text)
    end)

    it("rescans from the title bar without overlapping scans", function()
        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        local refresh = network_menu.custom_title_bar.action
        assert.are.equal("/tmp/zen-ui/icons/quick_sync.svg", refresh.file)

        scan_task()
        refresh.callback()
        assert.are.equal(1, kindle_scans)
        while #scheduled > 0 do table.remove(scheduled, 1)() end

        refresh.callback()
        assert.are.equal("Searching for networks…", network_menu.item_table[1].text)
        assert.are.equal(2, kindle_scans)
        refresh.callback()
        assert.are.equal(2, kindle_scans)
        while #scheduled > 0 do table.remove(scheduled, 1)() end
        assert.are.equal("Guest", network_menu.item_table[2].text)
    end)

    it("uses settings back navigation when opened from Settings", function()
        local Switcher = require("modules/menu/network_switcher")
        local plugin = {}
        assert.is_true(Switcher.open(nil, true, plugin))
        assert.is_true(network_menu.custom_title_bar.back_visible)
        assert.is_false(network_menu.custom_title_bar.close_visible)
        assert.are.equal(plugin, network_menu.custom_title_bar.plugin)
        assert.are.equal(network_menu.custom_title_bar.back_callback,
            network_menu.custom_title_bar.back_hold_callback)

        network_menu.custom_title_bar.back_callback()
        scan_task()
        assert.are.equal(0, kindle_scans)

        assert.is_true(Switcher.open(nil, true))
        network_menu.dimen = { w = 600 }
        assert.is_true(network_menu:onSwipe(nil, {
            direction = "east",
            pos = { x = 100 },
        }))
        scan_task()
        assert.are.equal(0, kindle_scans)
    end)

    it("prompts, saves, switches, and verifies an unsaved network", function()
        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open(function(network, ip)
            connected_network = network
            connected_ip = ip
        end))

        assert.are.equal("menu", network_menu.kind)
        assert.are.equal("network_switcher", network_menu.name)
        assert.are.equal(8, network_menu.items_per_page)
        assert.are.equal(27, network_menu.items_font_size)
        assert.is_false(network_menu.custom_title_bar.back_visible)
        assert.is_true(network_menu.custom_title_bar.close_visible)
        assert.is_false(network_menu.custom_title_bar.search_visible)
        assert.is_true(network_menu.custom_title_bar.title_full_width)
        assert.is_true(network_menu.custom_title_bar.root_icon.skip_paint)
        assert.is_nil(network_menu.custom_title_bar.status_factory)
        assert.are.equal(network_menu, network_menu.custom_title_bar.show_parent)
        assert.is_true(network_menu.custom_title_bar.was_cleared)
        assert.is_true(network_menu.custom_title_bar.was_initialized)
        assert.are.equal("Searching for networks…", network_menu.item_table[1].text)
        assert.is_true(network_menu.item_table[1]._zen_settings_row)
        assert.are.equal("Searching for networks…",
            network_menu.item_table[1]._zen_display_text)
        assert.is_nil(NetworkMgr.disconnected)
        assert.is_function(scan_task)

        finish_scan()

        assert.are.equal("Guest", network_menu.item_table[2].text)
        assert.are.equal(0, kindle_disconnects)
        assert.are.equal(1, kindle_scans)
        assert.are.equal(0, power_cycle_sleeps)
        assert.is_true(NetworkMgr.wifi_on)
        assert.is_nil(NetworkMgr.disconnected)
        assert.is_nil(NetworkMgr.released)
        assert.are.equal("Connected · 80%",
            network_menu.item_table[1]._zen_settings_breadcrumb)
        assert.are.equal("wifi-on", network_menu.item_table[1].icon_glyph)
        assert.is_nil(network_menu.item_table[2].icon_glyph)
        assert.is_true(network_menu.item_table[2]._zen_value_black)
        network_menu.item_table[2].callback()
        assert.are.equal("password", password_dialog.kind)
        assert.is_true(password_dialog.keyboard_shown)
        assert.is_nil(NetworkMgr.authenticated)

        password_dialog.buttons[1][2].callback()

        assert.is_nil(NetworkMgr.saved)
        assert.are.same({
            essid = "Guest",
            psk = "guest-password",
            secured = "yes",
            smethod = "wpa2",
            store_nw_user_pref = 0,
        }, created_profile)
        assert.are.equal(0, kindle_disconnects)
        assert.are.equal(1, kindle_connects)
        assert.are.equal(0, kindle_deletes)
        assert.are.equal("Guest", NetworkMgr.authenticated.ssid)
        assert.is_true(NetworkMgr.obtained)
        assert.are.equal("Guest", NetworkMgr.lease_ssid)
        assert.is_true(NetworkMgr.queried)
        assert.are.same({
            "NetworkConnecting",
            "NetworkConnected",
        }, events)
        assert.are.equal("Guest", connected_network.ssid)
        assert.are.equal("10.0.0.20", connected_ip)
        assert.are.equal(0, verification_sleeps)
        assert.are.equal(2, #network_menu.item_table)
        assert.are.equal("Home", network_menu.item_table[1].text)
        assert.are.equal("Guest", network_menu.item_table[2].text)
        assert.are.equal("Saved · 80%",
            network_menu.item_table[1]._zen_settings_breadcrumb)
        assert.is_nil(network_menu.item_table[1].icon_glyph)
        assert.are.equal("Connected · 60%",
            network_menu.item_table[2]._zen_settings_breadcrumb)
        assert.are.equal("wifi-on", network_menu.item_table[2].icon_glyph)
        assert.is_true(network_menu.item_table[2]._zen_value_black)
        assert.is_true(network_menu.item_table[2]._zen_settings_row)
        assert.are.equal("/tmp/zen-ui/icons/app_menu.svg",
            network_menu.item_table[2]._zen_caret_icon)
        assert.are.equal(2, network_menu.selected_index)

        network_menu.dimen = { x = 20, y = 20 }
        network_menu.border_size = 0
        network_menu.item_dimen = { w = 560, h = 80 }
        network_menu.title_bar = { getSize = function() return { h = 100 } end }
        network_menu.item_group = {
            { entry = network_menu.item_table[1] },
            { entry = network_menu.item_table[2] },
        }
        network_menu:onMenuSelect(network_menu.item_table[2], { x = 0.9, y = 0.5 })
        assert.are.equal("actions", button_dialog.kind)
        assert.are.equal("Guest", button_dialog.title)
        assert.are.equal(0.5, button_dialog.width_factor)
        assert.is_nil(button_dialog.buttons[1][1].height)
        assert.are.same({ x = 152, y = 229, w = 22, h = 22 }, button_dialog.anchor())
        assert.is_truthy(button_dialog.buttons[1][1].text:find("Info", 1, true))
        button_dialog.buttons[1][1].callback()
        assert.is_truthy(shown[#shown].text:find("IP address: 10.0.0.20", 1, true))

        network_menu:onMenuSelect(network_menu.item_table[2], { x = 0.9, y = 0.5 })
        assert.is_truthy(button_dialog.buttons[3][1].text:find("Disconnect", 1, true))
        button_dialog.buttons[3][1].callback()
        assert.is_false(NetworkMgr.wifi_on)
        assert.is_true(NetworkMgr.released)
        assert.are.equal(2, #network_menu.item_table)
        assert.are.equal("Saved · 60%",
            network_menu.item_table[2]._zen_settings_breadcrumb)
        assert.is_nil(network_menu.item_table[2].icon_glyph)
        assert.are.same({
            "NetworkConnecting",
            "NetworkConnected",
            "NetworkDisconnecting",
            "NetworkDisconnected",
        }, events)
    end)

    it("explains a target mismatch and prompts to replace the saved password", function()
        NetworkMgr.guest_password = "old-password"
        native_profiles.Guest = { essid = "Guest", netid = 22, psk = "old-password" }
        fail_first_auth = true

        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        finish_scan()
        network_menu.item_table[2].callback()

        assert.are.equal(1, authentication_attempts)
        assert.are.equal(0, kindle_deletes)
        assert.is_nil(created_profile)
        assert.are.equal("Guest", password_dialog.title)
        assert.are.equal("old-password", password_dialog.input)
        assert.are.equal(
            "Connected to Home instead of Guest. The password may be incorrect.",
            password_dialog.description
        )

        assert.are.equal("Forget", password_dialog.buttons[1][2].text)
        password_dialog.buttons[1][3].callback()

        assert.are.equal(2, authentication_attempts)
        assert.are.equal(0, kindle_disconnects)
        assert.are.equal(2, kindle_connects)
        assert.are.equal(1, kindle_deletes)
        assert.are.equal(22, deleted_profile_id)
        assert.are.equal("guest-password", created_profile.psk)
        assert.are.equal("wpa2", created_profile.smethod)
        assert.are.equal("Guest", NetworkMgr.lease_ssid)
        assert.is_true(NetworkMgr.queried)
        assert.are.equal(60, verification_sleeps)
        assert.is_true(#logs > 0)
    end)

    it("forgets a saved Kindle profile on hold", function()
        NetworkMgr.guest_password = string.rep("ab", 32)
        native_profiles.Guest = {
            essid = "Guest",
            netid = 22,
            psk = string.rep("ab", 32),
        }

        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        finish_scan()

        network_menu:onMenuHold(network_menu.item_table[2])
        assert.are.equal("actions", button_dialog.kind)
        assert.is_truthy(button_dialog.buttons[3][1].text:find("Forget", 1, true))
        button_dialog.buttons[3][1].callback()
        assert.are.equal("confirm", confirm_box.kind)
        assert.are.equal("Forget Wi-Fi network Guest?", confirm_box.text)
        confirm_box.ok_callback()

        assert.are.equal(0, kindle_disconnects)
        assert.are.equal(1, kindle_deletes)
        assert.are.equal(22, deleted_profile_id)
        assert.is_nil(native_profiles.Guest)
        assert.are.equal("Guest", NetworkMgr.deleted.ssid)
        assert.is_nil(NetworkMgr.deleted.password)
        assert.are.equal("Guest", network_menu.item_table[2].text)
        assert.are.equal("60%", network_menu.item_table[2]._zen_settings_breadcrumb)
    end)
end)
