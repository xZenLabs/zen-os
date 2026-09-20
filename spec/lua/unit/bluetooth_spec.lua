describe("Bluetooth state cache", function()
    local originals
    local state
    local reads

    before_each(function()
        originals = {}
        for _i, name in ipairs({
            "device", "common/kobo_bluetooth", "common/zen_logger", "common/bluetooth",
        }) do
            originals[name] = package.loaded[name]
        end
        state, reads = false, 0
        ZenSpec.replace("device", { isKindle = function() return false end })
        ZenSpec.replace("common/kobo_bluetooth", {
            getState = function()
                reads = reads + 1
                return state
            end,
            isAvailable = function() return true end,
            onSuspend = function() end,
        })
        ZenSpec.replace("common/zen_logger", {
            new = function() return { info = function() end, warn = function() end } end,
        })
        ZenSpec.unload("common/bluetooth")
    end)

    after_each(function()
        for name, module in pairs(originals) do package.loaded[name] = module end
    end)

    it("serves paint-time reads without querying hardware", function()
        local Bluetooth = require("common/bluetooth")
        assert.is_nil(Bluetooth.getCachedState())
        assert.is_false(Bluetooth.getState())
        assert.is_false(Bluetooth.getCachedState())
        assert.are.equal(1, reads)

        state = true
        assert.is_false(Bluetooth.getCachedState())
        assert.are.equal(1, reads)
        assert.is_true(Bluetooth.getState())
        assert.are.equal(2, reads)
    end)
end)
