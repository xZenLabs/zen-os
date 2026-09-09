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

        logger.dbg("hidden")
        assert.is_nil(captured)

        backend:setLevel(backend.levels.dbg)
        logger.dbg("visible")
        assert.are.equal("ZenOS: [zen_logger_spec] visible", captured[1])
    end)
end)
