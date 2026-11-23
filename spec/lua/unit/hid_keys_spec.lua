describe("HID button mappings", function()
    local names = { "device", "ui/uimanager", "config/manager", "dispatcher", "common/zen_logger",
        "common/hid_keys", "apps/reader/readerui", "ffi/util", "libs/libkoreader-lfs",
        "modules/menu/app_launcher/entry_action" }
    local originals, Keys, hook, config, ticks, executed, saved

    local function press(code, value)
        local ev = { type = 1, code = code, value = value or 1 }
        hook(nil, ev)
        return ev.code
    end
    local function run_ticks()
        local pending = ticks
        ticks = {}
        for _i, fn in ipairs(pending) do fn() end
    end

    before_each(function()
        originals = {}
        for _i, name in ipairs(names) do originals[name] = package.loaded[name] or false end
        config, ticks, executed, saved = { hid_keys = {} }, {}, {}, 0
        ZenSpec.replace("device", { input = {
            event_map = { [193] = "LPgFwd" },
            registerEventAdjustHook = function(_self, fn) hook = fn end,
            open = function() end, close = function() end,
        } })
        ZenSpec.replace("libs/libkoreader-lfs", { attributes = function() return nil end })
        ZenSpec.replace("ui/uimanager", {
            nextTick = function(_self, fn) ticks[#ticks + 1] = fn end,
            scheduleIn = function() end, unschedule = function() end,
        })
        ZenSpec.replace("config/manager", {
            get = function() return config end,
            save = function() saved = saved + 1 end,
        })
        ZenSpec.replace("dispatcher", {
            execute = function(_self, actions) executed[#executed + 1] = actions end,
            _itemsCount = function(_self, actions) return next(actions) and 1 or 0 end,
            menuTextFunc = function(_self, actions)
                return actions.zen_ui_show_book_switcher and "ZenOS: Book switcher" or "Next page"
            end,
        })
        ZenSpec.replace("common/zen_logger", {
            new = function() return { info = function() end, warn = function() end } end,
        })
        package.loaded["apps/reader/readerui"] = nil
        ZenSpec.unload("common/hid_keys")
        Keys = require("common/hid_keys")
        Keys.init()
    end)

    after_each(function()
        for name, module in pairs(originals) do package.loaded[name] = module or nil end
    end)

    it("captures one press, swallows its release, and ignores synthetic and touch codes", function()
        local captured = {}
        Keys.capture(function(code) captured[#captured + 1] = code end)
        assert.are.equal(10040, press(10040))
        assert.are.equal(330, press(330))
        assert.are.equal(0, press(304))
        assert.are.equal(0, press(304, 0))
        assert.are.equal(305, press(305))
        run_ticks()
        assert.are.same({ 304 }, captured)
    end)

    it("runs a mapping only on its screen and labels it", function()
        local binding = Keys.add("AA:BB:CC:DD:EE:FF", 304)
        assert.are.same({}, config.hid_keys) -- nothing is stored until the button does something
        Keys.assign("AA:BB:CC:DD:EE:FF", binding, "reader", "actions", { page_jmp = 1 })
        Keys.assign("AA:BB:CC:DD:EE:FF", binding, "library", "keys", "LPgFwd")
        assert.are.equal(binding, Keys.add("AA:BB:CC:DD:EE:FF", 304))
        assert.are.equal(1, #config.hid_keys["AA:BB:CC:DD:EE:FF"])
        Keys.save()
        assert.are.equal(1, saved)
        assert.are.equal("Next page", Keys.label(binding, "reader"))
        assert.are.equal("Page forward", Keys.label(binding, "library"))
        -- Common actions carry their own label; anything else falls back to the dispatcher's.
        assert.are.equal("Previous page", Keys.label({ reader = { page_jmp = -1 } }, "reader"))
        assert.are.equal("ZenOS: Book switcher",
            Keys.label({ reader = { zen_ui_show_book_switcher = true } }, "reader"))
        assert.is_truthy(Keys.preset("reader", { zen_ui_show_book_switcher = true }))
        assert.are.equal("Next page", Keys.label({ reader = { page_jmp = 5 } }, "reader"))
        assert.is_nil(Keys.preset("reader", { page_jmp = 5 }))
        assert.is_nil(Keys.preset("library", { page_jmp = 1 }))
        assert.is_nil(Keys.label({ code = 1 }, "reader"))

        -- Not connected: nothing is intercepted.
        assert.are.equal(304, press(304))
        Keys._connect("/dev/input/event2", "FF:EE:DD:CC:BB:AA") -- Fluoride's reversed uniq
        assert.are.equal(193, press(304)) -- library: rewritten to the native key's code
        package.loaded["apps/reader/readerui"] = { instance = {} }
        assert.are.equal(0, press(304))
        assert.are.equal(0, press(304, 0))
        run_ticks()
        assert.are.same({ binding.reader }, executed)

        Keys.remove("AA:BB:CC:DD:EE:FF", binding)
        Keys.save()
        assert.is_nil(config.hid_keys["AA:BB:CC:DD:EE:FF"])
        assert.are.equal(304, press(304))

        Keys.assign("AA:BB:CC:DD:EE:FF", Keys.add("AA:BB:CC:DD:EE:FF", 304), "reader", "keys", "LPgFwd")
        Keys.assign("AA:BB:CC:DD:EE:FF", Keys.add("AA:BB:CC:DD:EE:FF", 305), "reader", "actions", { page_jmp = 1 })
        Keys.save()
        assert.are.equal(193, press(304))
        Keys.clear("AA:BB:CC:DD:EE:FF") -- a forgotten device's mappings, all at once
        Keys.save()
        assert.is_nil(config.hid_keys["AA:BB:CC:DD:EE:FF"])
        assert.are.equal(304, press(304))
    end)

    it("keeps one assignment per screen and launches entries", function()
        local launched = {}
        ZenSpec.replace("modules/menu/app_launcher/entry_action", function(entry) launched[#launched + 1] = entry end)
        local address = "AA:BB:CC:DD:EE:FF"
        local binding = Keys.add(address, 304)
        local tag = { type = "tag", tag = "Sci-fi", label = "Sci-fi" }
        Keys.assign(address, binding, "library", "keys", "LPgFwd")
        Keys.assign(address, binding, "reader", "actions", { page_jmp = 1 })
        assert.are.same({ "Page forward", "keys" }, { Keys.label(binding, "library") })
        assert.are.same({ "Next page", "common" }, { Keys.label(binding, "reader") })
        assert.are.same({ "Next page", "actions" }, { Keys.label({ reader = { page_jmp = 5 } }, "reader") })

        Keys.assign(address, binding, "library", "entries", tag)
        assert.is_nil(binding.keys) -- the key it replaced is gone, the other screen untouched
        assert.are.same({ page_jmp = 1 }, binding.reader)
        assert.are.same({ "Sci-fi", "tag" }, { Keys.label(binding, "library") })

        Keys.save()
        Keys._connect("/dev/input/event2", address)
        assert.are.equal(0, press(304))
        assert.are.equal(0, press(304, 0))
        run_ticks()
        assert.are.same({ tag }, launched)
        assert.are.same({}, executed)

        Keys.assign(address, binding, "library", "actions", { zen_ui_show_home = true })
        assert.is_nil(binding.entries)
        -- The dispatcher's "Nothing" leaves an empty table: a button that does nothing is dropped.
        Keys.assign(address, binding, "library", "actions", {})
        assert.is_nil(Keys.label(binding, "library"))
        assert.are.same({ binding }, config.hid_keys[address])
        Keys.assign(address, binding, "reader", "actions", {})
        assert.is_nil(config.hid_keys[address])
        Keys.save()
        assert.are.equal(304, press(304))
    end)

    it("retries opening a hotplugged node until udev has created it, then gives up", function()
        local input, opens, scheduled, missing = require("device").input, 0, {}, 2
        require("ui/uimanager").scheduleIn = function(_self, delay, fn) scheduled[#scheduled + 1] = { delay, fn } end
        ZenSpec.replace("ffi/util", { realpath = function(path)
            return path:find("event2", 1, true) and "/sys/devices/virtual/misc/uhid/0005:045E:0B13.0007/input/input8/event2"
                or "/sys/devices/platform/touch/input/input1/event1"
        end })
        input.open = function()
            opens = opens + 1
            if opens <= missing then error("No such file or directory") end
        end
        local function drain()
            while #scheduled > 0 do
                local entry = table.remove(scheduled, 1)
                assert.are.equal(0.5, entry[1])
                entry[2]()
            end
        end

        Keys.onInsert("/dev/input/event1") -- not a uhid device
        assert.are.equal(0, opens)
        Keys.onInsert("/dev/input/event2")
        assert.are.equal(1, opens)
        drain()
        assert.are.equal(3, opens)

        opens, missing = 0, 99
        Keys.onInsert("/dev/input/event2")
        drain()
        assert.are.equal(5, opens)
    end)

    it("opens Bluetooth HID nodes from uhid and the kernel's HID, not USB ones", function()
        local input, opens = require("device").input, {}
        input.open = function(_self, path) opens[#opens + 1] = path end
        ZenSpec.replace("ffi/util", { realpath = function(path)
            local node = path:match("event%d+$")
            return ({
                event2 = "/sys/devices/virtual/misc/uhid/0005:045E:0B13.0007/input/input8/event2",
                event3 = "/sys/devices/platform/soc/serial0/hci0/hci0:11/0005:046D:B342.0003/input/input9/event3",
                event4 = "/sys/devices/platform/soc/usb1/1-1/1-1:1.0/0003:1532:021A.001C/input/input31/event4",
            })[node] or "/sys/devices/platform/touch/input/input1/" .. node
        end })
        for _i, node in ipairs({ "event1", "event2", "event3", "event4" }) do Keys.onInsert("/dev/input/" .. node) end
        assert.are.same({ "/dev/input/event2", "/dev/input/event3" }, opens)
    end)

    it("applies every mapping where input arrives without a device", function()
        local input, opens = require("device").input, 0
        input.input = { is_ffi = true }
        input.open = function() opens = opens + 1 end
        Keys.assign("AA:BB:CC:DD:EE:FF", Keys.add("AA:BB:CC:DD:EE:FF", 304), "reader", "actions", { page_jmp = 1 })
        Keys.save()
        Keys.rescan()
        Keys.onInsert("/dev/input/event2")
        assert.are.equal(0, opens)
        package.loaded["apps/reader/readerui"] = { instance = {} }
        assert.are.equal(0, press(304))
        assert.is_false(Keys.connected("AA:BB:CC:DD:EE:FF"))
    end)

    it("rescans for reconnected and vanished remotes", function()
        local input, opens, nodes, scheduled = require("device").input, 0, { event2 = "a" }, {}
        input.open = function() opens = opens + 1 end
        require("ui/uimanager").scheduleIn = function(_self, delay, fn) scheduled[#scheduled + 1] = { delay, fn } end
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function() return "directory" end,
            dir = function()
                local list = {}
                for node in pairs(nodes) do list[#list + 1] = node end
                local index = 0
                return function()
                    index = index + 1
                    return list[index]
                end
            end,
        })
        ZenSpec.replace("ffi/util", { realpath = function(path)
            local node = path:match("event%d+$")
            return nodes[node] and "/sys/devices/virtual/misc/uhid/0005:045E:0B13." .. nodes[node] .. "/input/" .. node
        end })
        local real_open = io.open
        local open_stub = stub(io, "open", function(path, ...)
            if path:find("/device/uniq$") then return { read = function() return "aa:bb:cc:dd:ee:ff" end, close = function() end } end
            return real_open(path, ...)
        end)
        finally(function() open_stub:revert() end)
        Keys.assign("AA:BB:CC:DD:EE:FF", Keys.add("AA:BB:CC:DD:EE:FF", 304), "library", "actions", { page_jmp = 1 })

        Keys.rescanSoon()
        local delays = {}
        while #scheduled > 0 do
            local entry = table.remove(scheduled, 1)
            delays[#delays + 1] = entry[1]
            entry[2]()
        end
        assert.are.same({ 2, 3, 7 }, delays)
        assert.are.equal(1, opens) -- an unchanged node is left alone
        assert.is_true(Keys.connected("AA:BB:CC:DD:EE:FF"))
        assert.are.equal(0, press(304))

        nodes.event2 = "b" -- same node name, new device
        Keys.rescan()
        assert.are.equal(2, opens)
        nodes.event2 = nil
        Keys.rescan()
        assert.is_false(Keys.connected("AA:BB:CC:DD:EE:FF"))
        assert.are.equal(304, press(304))
    end)
end)
