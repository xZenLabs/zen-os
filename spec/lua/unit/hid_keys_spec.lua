describe("HID button mappings", function()
    local names = { "device", "ui/uimanager", "config/manager", "dispatcher", "common/zen_logger",
        "common/hid_keys", "apps/reader/readerui", "ffi/util" }
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
        } })
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
        assert.are.equal(binding, Keys.add("AA:BB:CC:DD:EE:FF", 304))
        binding.reader = { page_jmp = 1 }
        binding.keys = { library = "LPgFwd" }
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
end)
