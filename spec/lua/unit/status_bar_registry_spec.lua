local Registry = require("common/status_bar_registry")

describe("status bar registry", function()
    it("uses configured items to distinguish a disabled interface bar", function()
        assert.is_false(Registry.hasItems(nil))
        assert.is_false(Registry.hasItems({ left_order = {}, center_order = {}, right_order = {} }))
        for _i, key in ipairs({ "left_order", "center_order", "right_order" }) do
            assert.is_true(Registry.hasItems({ [key] = { "time" } }))
        end
    end)

    after_each(function()
        _G.__ZENOS_REGISTER_STATUS_ITEM = nil
        _G.__ZENOS_UNREGISTER_STATUS_ITEM = nil
        _G.__ZEN_UI_REGISTER_STATUS_ITEM = nil
        _G.__ZEN_UI_UNREGISTER_STATUS_ITEM = nil
    end)

    it("registers, refreshes, and unregisters external items", function()
        local refreshes = 0
        ZenSpec.replace("apps/filemanager/filemanager", {
            instance = { _updateStatusBar = function() refreshes = refreshes + 1 end },
        })
        Registry.install()
        assert.are.equal(_G.__ZEN_UI_REGISTER_STATUS_ITEM, _G.__ZENOS_REGISTER_STATUS_ITEM)
        assert.are.equal(_G.__ZEN_UI_UNREGISTER_STATUS_ITEM, _G.__ZENOS_UNREGISTER_STATUS_ITEM)
        assert.is_true(_G.__ZENOS_REGISTER_STATUS_ITEM("sync", function() return "S", "Ready" end, {
            label = "Sync",
            side = "left",
        }))
        assert.are.equal("Sync", Registry.get("sync").label)
        assert.are.equal("left", Registry.get("sync").side)
        _G.__ZENOS_UNREGISTER_STATUS_ITEM("sync")
        assert.is_nil(Registry.get("sync"))
        assert.are.equal(2, refreshes)
    end)
end)
