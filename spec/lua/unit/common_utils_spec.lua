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

    describe("with an explicit badge font size", function()
        local saved_device

        before_each(function() saved_device = package.loaded["device"] end)
        after_each(function() package.loaded["device"] = saved_device end)

        local function stub_device(scale)
            ZenSpec.replace("device", { screen = {
                scaleBySize = function(_, value) return value * scale end,
            } })
        end

        it("honours an explicit badge font size", function()
            stub_device(1)
            local config = { browser_cover_badges = { badge_font_size = 14 } }
            assert.are.equal(14, utils.getBadgeFontSize(config, 40, 0.24, 7))
        end)

        it("caps an explicit badge font size at the badge box", function()
            stub_device(1)
            local config = { browser_cover_badges = { badge_font_size = 30 } }
            assert.are.equal(12, utils.getBadgeFontSize(config, 20, 0.24, 7))
        end)

        it("caps with the same pixel budget on a scaled screen", function()
            stub_device(2)
            local config = { browser_cover_badges = { badge_font_size = 30 } }
            assert.are.equal(12, utils.getBadgeFontSize(config, 40, 0.24, 7))
        end)

        it("lets an explicit badge font size go below the derived minimum", function()
            stub_device(1)
            local config = { browser_cover_badges = { badge_font_size = 5 } }
            assert.are.equal(5, utils.getBadgeFontSize(config, 40, 0.24, 7))
        end)
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
