describe("common utils deep merge", function()
    local utils = require("common/utils")

    it("fills an empty map from map defaults", function()
        local target = {}

        utils.deepmerge(target, {
            navbar = true,
            features = { launcher = true },
        })

        assert.are.same({
            navbar = true,
            features = { launcher = true },
        }, target)
    end)

    it("preserves an intentionally empty array", function()
        local target = {}

        utils.deepmerge(target, { "default" })

        assert.are.same({}, target)
    end)
end)

describe("common utils icon sizing", function()
    local utils = require("common/utils")

    it("optically enlarges ZenFM, ZenPM, and Zen UI icons", function()
        assert.are.equal(1.25, utils.iconOpticalScale("zenfm"))
        assert.are.equal(1.25, utils.iconOpticalScale("/plugins/zenpm/icons/zenpm.svg"))
        assert.are.equal(1.25, utils.iconOpticalScale("/plugins/zenos/icons/zen_ui.svg"))
    end)

    it("keeps other icons at their requested size", function()
        assert.are.equal(1, utils.iconOpticalScale("quick_wifi"))
        assert.are.equal(1, utils.iconOpticalScale(nil))
    end)
end)

describe("Controls menu tab placement", function()
    local utils = require("common/utils")

    it("replaces tabs only while Controls is available outside the guided tour", function()
        local config = {
            features = { quick_settings = true },
            quick_settings = { show_buttons = { launcher = true } },
            _meta = {},
        }
        assert.is_true(utils.controlReplacesMenuTab(config, "launcher"))
        assert.is_false(utils.controlReplacesMenuTab(config, "zen_settings"))
        config._meta.quickstart_menu_tour_pending = true
        assert.is_false(utils.controlReplacesMenuTab(config, "launcher"))
        config._meta.quickstart_menu_tour_pending = false
        config.features.quick_settings = false
        assert.is_false(utils.controlReplacesMenuTab(config, "launcher"))
        assert.is_false(utils.controlReplacesMenuTab(nil, "launcher"))
    end)
end)
