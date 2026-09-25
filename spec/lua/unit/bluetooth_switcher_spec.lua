describe("Bluetooth switcher", function()
    local originals, menu, shown, scheduled, events, adapter, state, changed
    local paired = "11:22:33:44:55:66"
    local available = "AA:BB:CC:DD:EE:FF"

    before_each(function()
        originals = {}
        for _i, name in ipairs({
            "device", "modules/menu/bluetooth/bluetooth", "modules/menu/bluetooth_adapters/kindle",
            "modules/menu/bluetooth_adapters/kobo", "modules/menu/bluetooth_adapters/pocketbook",
            "ui/uimanager", "ui/event", "ui/widget/menu", "ui/widget/buttondialog",
            "ui/widget/confirmbox", "ui/widget/infomessage", "common/ui/icon_menu_item",
            "ui/size",
            "common/ui/zen_settings_titlebar", "common/inline_icon_map", "common/utils",
            "common/plugin_root", "ffi/util", "gettext", "modules/menu/bluetooth_switcher",
        }) do originals[name] = package.loaded[name] or false end
        shown, scheduled, events, changed = {}, {}, {}, 0
        state = true
        adapter = { scanned = 0, closed = false }
        local devices = {
            { address = available, name = "Headphones", paired = false, connected = false, rssi = -45 },
            { address = paired, name = "Page turner", paired = true, connected = false, rssi = -80 },
            { address = "00:11:22:33:44:55", name = "Speaker", paired = true,
                connected = true, rssi = -90 },
        }
        adapter.getDeviceList = function() return devices end
        adapter.scan = function(done) adapter.scanned = adapter.scanned + 1; adapter.scan_done = done end
        adapter.close = function() adapter.closed = true end
        for _i, action in ipairs({ "pair", "connect", "disconnect", "forget" }) do
            adapter[action] = function(device, done)
                adapter.last_action = action
                if action == "pair" then device.paired = true end
                if action == "connect" then device.connected = true end
                if action == "disconnect" then device.connected = false end
                if action == "forget" then device.paired = false end
                done(true)
            end
        end
        ZenSpec.replace("device", { isKindle = function() return true end })
        ZenSpec.replace("modules/menu/bluetooth/bluetooth", {
            isEnabled = function() return state end,
            setEnabled = function(_enabled, done) state = true; done(true); return true end,
        })
        ZenSpec.replace("modules/menu/bluetooth_adapters/kindle", {
            isSupported = function() return true end, new = function() return adapter end,
        })
        ZenSpec.replace("modules/menu/bluetooth_adapters/kobo", { isSupported = function() return false end })
        ZenSpec.replace("modules/menu/bluetooth_adapters/pocketbook", { isSupported = function() return false end })
        ZenSpec.replace("ui/uimanager", {
            show = function(_self, widget) shown[#shown + 1] = widget end,
            close = function() end, forceRePaint = function() end,
            tickAfterNext = function(_self, callback) callback() end,
            broadcastEvent = function(_self, event) events[#events + 1] = event end,
            scheduleIn = function(_self, delay, callback)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end,
        })
        ZenSpec.replace("ui/event", { new = function(_self, name) return { name = name } end })
        ZenSpec.replace("ui/widget/menu", { new = function(_self, spec)
            menu = spec
            spec.switchItemTable = function(self, _title, rows) self.item_table = rows end
            spec.onMenuChoice = function(_menu, row) row.callback() end
            spec.onClose = function(self) self.close_callback(); return true end
            return spec
        end })
        ZenSpec.replace("ui/widget/buttondialog", { new = function(_self, spec) return spec end })
        ZenSpec.replace("ui/widget/confirmbox", { new = function(_self, spec) return spec end })
        ZenSpec.replace("ui/widget/infomessage", { new = function(_self, spec) return spec end })
        ZenSpec.replace("ui/size", { padding = { large = 12, default = 8 } })
        ZenSpec.replace("common/ui/icon_menu_item", {
            installMenuPatch = function() end, getSettingsFontSize = function() return 18 end,
            SETTINGS_CARET_SIZE = 16,
        })
        ZenSpec.replace("common/ui/zen_settings_titlebar", { new = function(_self, spec)
            spec.root_icon = {}
            spec.clearStatusRefresh = function() end
            spec.clear = function() end
            spec.init = function() end
            return spec
        end })
        ZenSpec.replace("common/inline_icon_map", {
            details = "i", wifi_off = "x", connect = "+", delete = "d", bluetooth_on = "b",
        })
        ZenSpec.replace("common/utils", { resolveLocalIcon = function(_path, name)
            return name .. ".svg"
        end })
        ZenSpec.replace("common/plugin_root", "/tmp/zen-ui")
        ZenSpec.replace("ffi/util", { template = function(text, value)
            return text:gsub("%%1", tostring(value))
        end })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.unload("modules/menu/bluetooth_switcher")
    end)

    after_each(function()
        for name, module in pairs(originals) do package.loaded[name] = module or nil end
    end)

    it("sorts devices, pairs and connects, and cleans up discovery", function()
        local Switcher = require("modules/menu/bluetooth_switcher")
        assert.is_true(Switcher.open(function() changed = changed + 1 end, true, {}))
        assert.are.equal("bluetooth_switcher", menu.name)
        assert.is_true(menu.custom_title_bar.back_visible)
        assert.are.equal(8, menu.items_per_page)
        assert.are.equal(1, adapter.scanned)
        assert.are.same({ "Speaker", "Page turner", "Headphones" },
            { menu.item_table[1].text, menu.item_table[2].text, menu.item_table[3].text })
        assert.are.equal("Connected · -90 dBm", menu.item_table[1]._zen_settings_breadcrumb)

        menu.item_table[3].callback()
        assert.are.equal("connect", adapter.last_action)
        assert.are.equal(2, changed)
        assert.are.equal("BluetoothStateChanged", events[1].name)

        menu:onMenuHold(menu.item_table[1])
        local actions = shown[#shown]
        assert.is_truthy(actions.buttons[2][1].text:find("Disconnect", 1, true))
        actions.buttons[2][1].callback()
        assert.are.equal("disconnect", adapter.last_action)

        menu:onClose()
        assert.is_true(adapter.closed)
        adapter.scan_done(true)
        assert.are.equal(3, changed)
    end)

    it("shows pair and connect progress beneath the device name", function()
        local pending_pair, pending_connect
        adapter.pair = function(_device, done) pending_pair = done end
        adapter.connect = function(_device, done) pending_connect = done end
        require("modules/menu/bluetooth_switcher").open()
        local device = menu.item_table[3].device
        menu.item_table[3].callback()
        assert.are.equal("Headphones", menu.item_table[3].text)
        assert.are.equal("Updating…", menu.item_table[3]._zen_settings_breadcrumb)
        assert.are.equal("Page turner", menu.item_table[2].text)
        assert.are.equal("Paired · -80 dBm", menu.item_table[2]._zen_settings_breadcrumb)

        device.paired = true
        pending_pair(true)
        assert.is_function(pending_connect)
        for _i, row in ipairs(menu.item_table) do
            if row.device == device then
                assert.are.equal("Headphones", row.text)
                assert.are.equal("Updating…", row._zen_settings_breadcrumb)
            end
        end
        device.connected = true
        pending_connect(true)
        assert.are.equal("Headphones", menu.item_table[1].text)
        assert.are.equal("Connected · -45 dBm", menu.item_table[1]._zen_settings_breadcrumb)
    end)

    it("powers on before scanning and confirms forget", function()
        state = false
        require("modules/menu/bluetooth_switcher").open()
        assert.is_true(state)
        assert.are.equal(1, adapter.scanned)
        menu:onMenuHold(menu.item_table[2])
        local actions = shown[#shown]
        actions.buttons[3][1].callback()
        local confirm = shown[#shown]
        assert.are.equal("Forget Bluetooth device Page turner?", confirm.text)
        confirm.ok_callback()
        assert.are.equal("forget", adapter.last_action)
    end)

    it("shows power and scan failures without starting background work", function()
        state = false
        package.loaded["modules/menu/bluetooth/bluetooth"].setEnabled = function(_enabled, done)
            done(false, "Power denied")
            return false
        end
        require("modules/menu/bluetooth_switcher").open()
        assert.are.equal("Power denied", menu.item_table[1].text)
        assert.are.equal(0, adapter.scanned)

        state = true
        require("modules/menu/bluetooth_switcher").open()
        adapter.scan_done(false, "Radio busy")
        assert.are.equal("Speaker", menu.item_table[1].text)
        assert.are.equal("Radio busy", menu.item_table[4].text)

        adapter.scanned = 0
        adapter.getDeviceList = function() return nil, "Unsupported firmware" end
        require("modules/menu/bluetooth_switcher").open()
        assert.are.equal("Unsupported firmware", menu.item_table[1].text)
        assert.are.equal(0, adapter.scanned)
    end)

    it("keeps an empty Kindle list in the searching state until scanning finishes", function()
        adapter.getDeviceList = function() return {} end
        require("modules/menu/bluetooth_switcher").open()
        assert.are.equal(1, adapter.scanned)
        assert.are.equal("Searching for devices…", menu.item_table[1].text)
        adapter.scan_done(true)
        assert.are.equal("No Bluetooth devices found.", menu.item_table[1].text)
    end)

    it("rescans from the title bar without overlapping discovery", function()
        require("modules/menu/bluetooth_switcher").open()
        local refresh = menu.custom_title_bar.action
        assert.are.equal("quick_sync.svg", refresh.file)
        refresh.callback()
        assert.are.equal(1, adapter.scanned)
        adapter.scan_done(false, "Radio busy")
        assert.are.equal("Radio busy", menu.item_table[4].text)
        refresh.callback()
        assert.are.equal(2, adapter.scanned)
        assert.is_nil(menu.item_table[4])
        refresh.callback()
        assert.are.equal(2, adapter.scanned)
        adapter.scan_done(true)
        assert.are.equal("Speaker", menu.item_table[1].text)
    end)

    it("shows devices discovered by the Kindle scan", function()
        local discovered = false
        local reads = 0
        adapter.id = "kindle"
        adapter.getDeviceList = function()
            reads = reads + 1
            if not discovered then return nil, "Kindle list unavailable" end
            return {{ address = available, name = "Headphones" }}
        end
        require("modules/menu/bluetooth_switcher").open()
        assert.are.equal(1, adapter.scanned)
        assert.are.equal(0, reads)
        assert.are.equal("Searching for devices…", menu.item_table[1].text)
        discovered = true
        adapter.scan_done(true)
        assert.are.equal(1, reads)
        assert.are.equal("Headphones", menu.item_table[1].text)
    end)

    it("shows a concise Kindle error if the post-scan list cannot be read", function()
        adapter.id = "kindle"
        adapter.getDeviceList = function() return nil, "Firmware property failure" end
        require("modules/menu/bluetooth_switcher").open()
        adapter.scan_done(true)
        assert.are.equal("Could not read Bluetooth devices.", menu.item_table[1].text)
    end)

    it("cancels discovery without closing the settings switcher", function()
        local Switcher = require("modules/menu/bluetooth_switcher")
        adapter.cancelScan = function()
            adapter.cancelled = true
            adapter.scan_done(false, "Cancelled.")
        end
        Switcher.open(nil, true)
        assert.is_true(Switcher.cancelScan())
        assert.is_true(adapter.cancelled)
        assert.is_false(adapter.closed)
        assert.is_false(Switcher.cancelScan())
        menu.custom_title_bar.action.callback()
        assert.are.equal(2, adapter.scanned)
        adapter.scan_done(true)
        assert.is_false(adapter.closed)
        assert.is_false(Switcher.cancelScan())
        menu:onClose()
        assert.is_true(adapter.closed)
    end)

    it("keeps known devices visible when live scanning is unavailable", function()
        adapter.scan = function(done)
            done(false, "Kindle live scanning is unavailable.")
        end
        require("modules/menu/bluetooth_switcher").open()
        assert.are.equal("Speaker", menu.item_table[1].text)
        assert.are.equal("Kindle live scanning is unavailable.", menu.item_table[4].text)
        assert.is_false(menu.item_table[4].select_enabled)
    end)

end)
