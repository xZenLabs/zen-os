describe("bar color text", function()
    local Blitbuffer
    local ColorTextWidget
    local Screen
    local painted_color
    local saved_modules
    local module_names = {
        "ffi/blitbuffer", "device", "ui/rendertext", "ui/widget/textwidget",
        "common/ui/color_text_widget",
    }

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(module_names) do
            saved_modules[name] = package.loaded[name]
            ZenSpec.unload(name)
        end
        Blitbuffer = require("ffi/blitbuffer")
        Screen = { isColorScreen = function() return true end }
        ZenSpec.replace("device", { screen = Screen })
        ZenSpec.replace("ui/widget/textwidget", {
            extend = function(self, values)
                return setmetatable(values, { __index = self })
            end,
            updateSize = function() end,
            paintTo = function(widget) painted_color = widget.fgcolor end,
        })
        ZenSpec.replace("ui/rendertext", {
            getGlyphByIndex = function()
                return {
                    bb = { getWidth = function() return 1 end, getHeight = function() return 1 end },
                    l = 0, t = 0,
                }
            end,
        })
        ColorTextWidget = require("common/ui/color_text_widget")
    end)

    after_each(function()
        for _i, name in ipairs(module_names) do
            package.loaded[name] = saved_modules[name]
        end
    end)

    it("preserves RGB colors across dark mode toggles in both text renderers", function()
        local color = Blitbuffer.ColorRGB32(0x33, 0x99, 0xFF, 0x80)
        local widget = setmetatable({
            fgcolor = color,
            face = { getFallbackFont = function() return {} end },
            _baseline_h = 0,
            _xshaping = { { font_num = 0, glyph = 1, x_offset = 0, y_offset = 0, x_advance = 1 } },
        }, { __index = ColorTextWidget })
        local bb = {
            getWidth = function() return 10 end,
            colorblitFromRGB32 = function(_self, _source, _x, _y, _ox, _oy, _w, _h, tint)
                painted_color = tint
            end,
        }
        for _i, use_xtext in ipairs({ true, false }) do
            widget.use_xtext = use_xtext
            for _j, night_mode in ipairs({ false, true, false }) do
                Screen.night_mode = night_mode
                widget:paintTo(bb, 0, 0)
                assert.are.equal(night_mode and color:invert() or color, painted_color)
                assert.are.equal(color, widget.fgcolor)
                assert.are.equal(0x80, painted_color:getAlpha())
            end
        end
        Screen.night_mode = true
        Screen.isColorScreen = function() return false end
        widget:paintTo(bb, 0, 0)
        assert.are.equal(color:invert(), painted_color)
        assert.are.equal(color, widget.fgcolor)

        widget.fgcolor = Blitbuffer.COLOR_DARK_GRAY
        widget:paintTo(bb, 0, 0)
        assert.are.equal(Blitbuffer.COLOR_DARK_GRAY, painted_color)
    end)
end)
