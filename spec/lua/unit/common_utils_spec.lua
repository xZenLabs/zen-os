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

    it("keeps icon-pack replacements of logo icons at their requested size", function()
        local saved = package.loaded["common/icon_packs"]
        package.loaded["common/icon_packs"] = {
            isPackIcon = function(path) return path == "/icons/zen/pack/zenfm.svg" end,
        }
        assert.are.equal(1, utils.iconOpticalScale("zenfm", "/icons/zen/pack/zenfm.svg"))
        assert.are.equal(1.25, utils.iconOpticalScale("zenfm", "/plugins/zenos/icons/zenfm.svg"))
        package.loaded["common/icon_packs"] = saved
    end)
end)

describe("common utils badge font sizing", function()
    local utils = require("common/utils")

    it("scales the minimum font size with every badge size", function()
        for _i, preset in ipairs({
            { "compact", 7 }, { "normal", 8 }, { "large", 9 }, { "extra_large", 11 },
        }) do
            local config = { browser_cover_badges = { badge_size = preset[1] } }
            local size = math.floor(20 * utils.getBadgeScale(config))
            assert.are.equal(preset[2], utils.getBadgeFontSize(config, size, 0.24, 7))
        end
    end)

    it("defaults to normal fonts and preserves fonts above the minimum", function()
        assert.are.equal(1.10, utils.getBadgeScale({}))
        assert.are.equal(1.10, utils.getBadgeScale({ browser_cover_badges = {} }))
        assert.are.equal(8, utils.getBadgeFontSize(nil, 20, 0.24, 7))
        assert.are.equal(19, utils.getBadgeFontSize(nil, 80, 0.24, 7))
        assert.are.equal(8, utils.getBadgeFontSize(nil, 18, 0.45, 6))
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

describe("common utils frontlight broadcast", function()
    local utils = require("common/utils")

    it("silences powerd broadcasts only while fn runs, even when it errors", function()
        local Class = { broadcasts = 0 }
        Class.__index = Class
        function Class:stateChanged() self.broadcasts = self.broadcasts + 1 end
        local powerd = setmetatable({}, Class)
        utils.withoutFrontlightBroadcast(powerd, function() powerd:stateChanged() end)
        assert.are.equal(0, powerd.broadcasts)
        assert.is_nil(rawget(powerd, "stateChanged"))
        assert.has_error(function()
            utils.withoutFrontlightBroadcast(powerd, function() error("boom") end)
        end)
        assert.is_nil(rawget(powerd, "stateChanged"))
        powerd:stateChanged()
        assert.are.equal(1, powerd.broadcasts)
    end)
end)
