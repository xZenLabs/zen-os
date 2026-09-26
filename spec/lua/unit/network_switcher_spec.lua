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
        "ui/size",
        "ui/network/manager",
        "ui/uimanager",
        "ffi/util",
        "liblipclua",
        "common/inline_icon_map",
        "common/plugin_root",
        "common/ui/icon_menu_item",
        "common/ui/zen_settings_titlebar",
        "common/utils",
        "common/zen_logger",
        "modules/menu/network_adapters/kindle",
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
        button_dialog = nil
        scan_task = nil
        scheduled = {}
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
                options.switchItemTable = function(self, _title, items, selected_index)
                    self.item_table = items
                    self.selected_index = selected_index
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
                return true
            end,
            obtainIP = function(self) self.obtained = true end,
            getCurrentNetwork = function(self) return { ssid = self.current_ssid } end,
            hasDefaultRoute = function() return false end,
            queryNetworkState = function(self) self.queried = true end,
        }
        ZenSpec.replace("ui/network/manager", NetworkMgr)
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
            forceRePaint = function() end,
            broadcastEvent = function(_self, event) events[#events + 1] = event.name end,
            tickAfterNext = function(_self, action) scan_task = action end,
            nextTick = function(_self, action) action() end,
            scheduleIn = function(_self, delay, action)
                assert.are.equal(0.25, delay)
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
    end)

    local function finish_scan()
        scan_task()
        network_menu.custom_title_bar.action.callback()
        while #scheduled > 0 do table.remove(scheduled, 1)() end
    end

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
        assert.are.equal(1, #button_dialog.buttons)
    end)

    it("does not scan connected non-Kindle Wi-Fi until refresh", function()
        ZenSpec.replace("device", {
            hasWifiManager = function() return true end,
            isKindle = function() return false end,
        })
        local scans = 0
        NetworkMgr.getNetworkList = function()
            scans = scans + 1
            return {{ ssid = "Home", connected = true }}
        end

        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        scan_task()
        assert.are.equal(0, scans)
        assert.are.equal("Home", network_menu.item_table[1].text)

        network_menu.custom_title_bar.action.callback()
        assert.are.equal(1, scans)
    end)

    it("scans automatically when there is no current network", function()
        NetworkMgr.current_ssid = nil
        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        scan_task()
        assert.are.equal(1, kindle_scans)
    end)

    it("keeps an active connection when its network name is unavailable", function()
        NetworkMgr.getCurrentNetwork = function() error("network name unavailable") end
        local Switcher = require("modules/menu/network_switcher")
        assert.is_true(Switcher.open())
        scan_task()
        assert.are.equal(0, kindle_scans)
        assert.are.equal("Connected", network_menu.item_table[1].text)
    end)

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

    it("uses settings back navigation when opened from About", function()
        local Switcher = require("modules/menu/network_switcher")
        local plugin = {}
        assert.is_true(Switcher.open(nil, true, plugin))
        assert.is_true(network_menu.custom_title_bar.back_visible)
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
