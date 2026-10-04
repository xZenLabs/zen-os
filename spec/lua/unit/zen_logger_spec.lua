describe("Zen logger branding", function()
    local backend
    local original_backend
    local captured

    before_each(function()
        package.loaded["common/zen_logger"] = nil
        original_backend = package.loaded.logger
        captured = nil
        backend = { levels = { dbg = 1, info = 2, warn = 3, err = 4 } }
        local writers = {}
        for _i, level in ipairs({ "dbg", "info", "warn", "err" }) do
            writers[level] = function(...)
                captured = { ... }
            end
        end
        function backend:setLevel(new_level)
            for level, value in pairs(self.levels) do
                self[level] = value >= new_level and writers[level] or function() end
            end
        end
        backend:setLevel(backend.levels.info)
        package.loaded.logger = backend
    end)

    after_each(function()
        package.loaded["common/zen_logger"] = nil
        package.loaded.logger = original_backend
    end)

    it("uses ZenOS and strips current and legacy product prefixes", function()
        local logger = require("common/zen_logger").new("test")

        logger.info("Zen UI: legacy message")
        assert.are.equal("ZenOS: [zen_logger_spec] legacy message", captured[1])

        logger.info("ZenOS: current message")
        assert.are.equal("ZenOS: [zen_logger_spec] current message", captured[1])
    end)

    it("follows KOReader log-level changes made after installation", function()
        local logger = require("common/zen_logger").new("test")

        assert.is_false(logger.isEnabled("dbg"))
        logger.dbg("hidden")
        assert.is_nil(captured)

        backend:setLevel(backend.levels.dbg)
        assert.is_true(logger.isEnabled("dbg"))
        logger.dbg("visible")
        assert.are.equal("ZenOS: [zen_logger_spec] visible", captured[1])
    end)

    it("keeps a debug level enabled before installation", function()
        backend:setLevel(backend.levels.dbg)
        local logger = require("common/zen_logger").new("test")

        logger.dbg("visible")

        assert.are.equal("ZenOS: [zen_logger_spec] visible", captured[1])
    end)

    it("omits KOReader network identifiers at every enabled level", function()
        local logger = require("common/zen_logger").new("test")
        backend:setLevel(backend.levels.dbg)
        local upstream_log = assert(loadstring([[return function(level, ...)
            require("logger")[level](...)
        end]], "@/koreader/frontend/ui/network/manager.lua"))()
        local messages = {
            { "NetworkMgr: interface", "wlan0", "is up @", "10.0.0.86" },
            { "NetworkMgr: interface", "wlan0", "is up @", "fe80::1234%wlan0" },
            { "NetworkMgr: lease_ssid set to", "Private Wi-Fi", "after async restore" },
            { "NetworkMgr: Connected to network", "Private Wi-Fi" },
            { "NetworkMgr: stale DHCP lease detected (lease_ssid=", "Private Wi-Fi", ")" },
            { "WpaSupplicant:getCurrentNetwork: Connected network:", { ssid = "Private Wi-Fi" } },
            { "active network", "ssid=", "Private Wi-Fi" },
            { '{"ssid": "Private Wi-Fi"}' },
            { "device address", "2001:db8::" },
        }
        for _i, level in ipairs({ "dbg", "info", "warn", "err" }) do
            for _j, args in ipairs(messages) do
                captured = nil
                upstream_log(level, unpack(args))
                assert.is_nil(captured)
                logger[level](unpack(args))
                assert.is_nil(captured)
            end
        end

        upstream_log("dbg", "NetworkMgr: socket.udp.setpeername:", "Network is unreachable")
        assert.are.same({ "NetworkMgr: socket.udp.setpeername:", "Network is unreachable" }, captured)
        logger.dbg("connection verified", "ip_assigned=", true)
        assert.is_true(captured[3])
    end)

    it("skips stack inspection for disabled debug logging", function()
        local logger = require("common/zen_logger").new("test")
        local original_getinfo = debug.getinfo
        local inspections = 0
        local getinfo_stub = stub(debug, "getinfo", function(...)
            inspections = inspections + 1
            return original_getinfo(...)
        end)

        logger.dbg("hidden")
        logger.measure("hidden", 1)
        logger.perf("hidden", 1)
        getinfo_stub:revert()

        assert.are.equal(0, inspections)
    end)
end)
