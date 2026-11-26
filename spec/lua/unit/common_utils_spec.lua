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

describe("common utils html font root", function()
    local utils = require("common/utils")

    local lfs = require("libs/libkoreader-lfs")
    local dir = lfs.dir
    after_each(function() lfs.dir = dir end)

    local function deny(denied)
        lfs.dir = function(path)
            if denied[path] then error("cannot open " .. path) end
            return function() end, { close = function() end }
        end
    end

    it("roots absolute fonts at / and bundled relative fonts at the working directory", function()
        assert.are.same({ "/", "/mnt/us/fonts/Book.ttf" }, { utils.htmlFontRoot("/mnt/us/fonts/Book.ttf") })
        assert.are.same({ ".", "./fonts/noto/NotoSerif-Regular.ttf" },
            { utils.htmlFontRoot("./fonts/noto/NotoSerif-Regular.ttf") })
        assert.are.equal(".", utils.htmlFontRoot("fonts/noto/NotoSerif-Regular.ttf"))
    end)

    it("roots fonts at their own directory when / cannot be listed", function()
        deny({ ["/"] = true })
        local root, url = utils.htmlFontRoot("/system/fonts/Book.ttf")
        assert.are.same({ "/system/fonts", "Book.ttf" }, { root, url })
        assert.are.same({ root, "Book-Bold.ttf" }, { utils.htmlFontRoot("/system/fonts/Book-Bold.ttf", root) })
        assert.are.same({ root, "/sdcard/fonts/Book-Italic.ttf" },
            { utils.htmlFontRoot("/sdcard/fonts/Book-Italic.ttf", root) })
    end)

    it("returns no root when the font directory cannot be listed either", function()
        deny({ ["/"] = true, ["/system/fonts"] = true })
        assert.are.same({ nil, "/system/fonts/Book.ttf" }, { utils.htmlFontRoot("/system/fonts/Book.ttf") })
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
    local saved_device

    local function stub_device(scale)
        ZenSpec.replace("device", { screen = {
            scaleBySize = function(_, value) return value * scale end,
        } })
    end

    before_each(function()
        saved_device = package.loaded["device"]
        stub_device(1)
    end)
    after_each(function() package.loaded["device"] = saved_device end)

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

    it("derives the same pixel size on a scaled screen", function()
        stub_device(2)
        -- Twice the pixels per unit: half the pre-scale size for the same badge box.
        assert.are.equal(10, utils.getBadgeFontSize(nil, 80, 0.24, 7))
    end)

    describe("with an explicit badge font size", function()
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

describe("common utils badge text centring", function()
    local utils = require("common/utils")
    local saved_render

    before_each(function() saved_render = package.loaded["ui/rendertext"] end)
    after_each(function() package.loaded["ui/rendertext"] = saved_render end)

    -- glyphs: { rows above the baseline, ink height } each, in a 30-row line box with its baseline at row 20.
    local function paint_y(glyphs, cy)
        ZenSpec.replace("ui/rendertext", {
            getGlyphByIndex = function(_self, _face, index)
                return { t = glyphs[index][1], bb = { getHeight = function() return glyphs[index][2] end } }
            end,
        })
        local shaping = {}
        for index = 1, #glyphs do shaping[index] = { glyph = index, font_num = 0, y_offset = 0 } end
        local painted_y
        utils.paintBadgeText({}, {
            face = { getFallbackFont = function() return {} end },
            _xtext = glyphs[1] and { shapeLine = function() return shaping end } or nil,
            getSize = function() return { w = 10, h = 30 } end,
            getBaseline = function() return 20 end,
            paintTo = function(_self, _bb, _x, y) painted_y = y end,
        }, 50, cy)
        return painted_y
    end

    it("centres digits on their ink instead of the line box", function()
        assert.are.equal(87, paint_y({ { 14, 14 } }, 100))
        assert.are.equal(87, paint_y({ { 14, 14 } }, 100.5))
    end)

    it("keeps digits in place next to a lone descender", function()
        assert.are.equal(87, paint_y({ { 14, 14 }, { 10, 15 } }, 100))
    end)

    it("uses the whole ink when every glyph floats above or dips below the baseline", function()
        assert.are.equal(92, paint_y({ { 18, 12 } }, 100))
        assert.are.equal(85, paint_y({ { 14, 18 } }, 100))
    end)

    it("falls back to the line box when the glyphs cannot be measured", function()
        assert.are.equal(85, paint_y({}, 100))
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
