describe("reader highlight names", function()
    before_each(function()
        _G.__ZEN_UI_PLUGIN = nil
        ZenSpec.unload("modules/reader/patches/highlight_names")
    end)

    after_each(function()
        _G.__ZEN_UI_PLUGIN = nil
        ZenSpec.unload("modules/reader/patches/highlight_names")
    end)

    it("applies configured names without replacing native color customizations", function()
        local ReaderHighlight = {
            highlight_colors = {
                { "Red", "red" },
                { "Blue", "blue" },
            },
            getHighlightColorString = function(_self, color_name, force_orig)
                if color_name == "red" and not force_orig then return "Native red" end
                return color_name == "red" and "Red" or "Blue"
            end,
            getHighlightColorList = function()
                return {
                    { "Native red", "red", "#ff0000" },
                    { "Native blue", "blue", "#0000ff" },
                }
            end,
        }
        ZenSpec.replace("apps/reader/modules/readerhighlight", ReaderHighlight)
        local apply = require("modules/reader/patches/highlight_names")
        local plugin = {
            config = { highlight_lookup = { color_names = { red = "Important" } } },
        }

        apply(plugin)

        assert.are.equal("Important", ReaderHighlight.highlight_colors[1][1])
        assert.are.equal("Blue", ReaderHighlight.highlight_colors[2][1])
        assert.are.equal("Important", ReaderHighlight:getHighlightColorString("red"))
        assert.are.equal("Red", ReaderHighlight:getHighlightColorString("red", true))
        local colors = ReaderHighlight:getHighlightColorList()
        assert.are.equal("Important", colors[1][1])
        assert.are.equal("Native blue", colors[2][1])

        plugin.config.highlight_lookup.color_names.red = nil
        apply(plugin)
        assert.are.equal("Red", ReaderHighlight.highlight_colors[1][1])
        assert.are.equal("Native red", ReaderHighlight:getHighlightColorString("red"))
    end)

    it("supports older palettes that do not expose color helper methods", function()
        local ReaderHighlight = {
            highlight_colors = { { "Yellow", "yellow" } },
        }
        ZenSpec.replace("apps/reader/modules/readerhighlight", ReaderHighlight)
        _G.__ZEN_UI_PLUGIN = {
            config = { highlight_lookup = { color_names = { yellow = "Funny" } } },
        }

        require("modules/reader/patches/highlight_names")()

        assert.are.equal("Funny", ReaderHighlight.highlight_colors[1][1])
    end)

    it("applies configured colors to current and legacy highlight paths", function()
        local Blitbuffer = require("ffi/blitbuffer")
        local original_red = Blitbuffer.HIGHLIGHT_COLORS.red
        local original_reader_settings = G_reader_settings
        local night_mode = false
        _G.G_reader_settings = {
            isTrue = function(_self, key) return key == "night_mode" and night_mode end,
        }
        local ReaderHighlight = {
            highlight_colors = {
                { "Red", "red" },
                { "Gray", "gray" },
            },
            getHighlightColorCode = function(_self, color_name)
                return color_name == "red" and original_red or nil
            end,
            getHighlightColor = function(self, color_name, force_orig, honor_night_mode)
                local code = self:getHighlightColorCode(color_name, force_orig, honor_night_mode)
                return code and Blitbuffer.colorFromString(code) or Blitbuffer.gray(0.2)
            end,
            getHighlightColorList = function(self)
                return {
                    { "Red", "red", self:getHighlightColor("red") },
                    { "Gray", "gray", self:getHighlightColor("gray") },
                }
            end,
        }
        ZenSpec.replace("apps/reader/modules/readerhighlight", ReaderHighlight)
        local apply = require("modules/reader/patches/highlight_names")
        local plugin = {
            config = {
                highlight_lookup = {
                    color_names = {},
                    color_codes = { red = "#123456", gray = "#abcdef" },
                },
            },
        }

        apply(plugin)

        assert.are.equal("#123456", ReaderHighlight:getHighlightColorCode("red"))
        assert.are.equal("#abcdef", ReaderHighlight:getHighlightColorCode("gray"))
        assert.are.equal(0x12, ReaderHighlight:getHighlightColor("red"):getR())
        assert.are.equal(0xab, ReaderHighlight:getHighlightColor("gray"):getR())
        assert.are.equal("#123456", Blitbuffer.HIGHLIGHT_COLORS.red)
        assert.are.equal(0xab, ReaderHighlight:getHighlightColorList()[2][3]:getR())

        night_mode = true
        assert.are.equal("#edcba9", ReaderHighlight:getHighlightColorCode("red", false, true))

        plugin.config.highlight_lookup.color_codes = {}
        apply(plugin)
        assert.are.equal(original_red, ReaderHighlight:getHighlightColorCode("red"))
        assert.are.equal(original_red, Blitbuffer.HIGHLIGHT_COLORS.red)
        _G.G_reader_settings = original_reader_settings
    end)

    it("keeps legacy color lists unchanged", function()
        local color = require("ffi").new("struct { uint8_t r; uint8_t g; uint8_t b; uint8_t a; }")
        local ReaderHighlight = {
            highlight_colors = { { "Yellow", "yellow" } },
            getHighlightColorList = function() return { color } end,
        }
        ZenSpec.replace("apps/reader/modules/readerhighlight", ReaderHighlight)

        require("modules/reader/patches/highlight_names")()

        assert.are.equal(color, ReaderHighlight:getHighlightColorList()[1])
    end)
end)
