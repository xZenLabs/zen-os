describe("shared Reader controls", function()
    local originals, painted, focused
    local modules = {
        "device", "ui/font", "ui/geometry", "ui/gesturerange", "ffi/blitbuffer", "ui/uimanager",
        "ui/widget/button", "ui/widget/container/inputcontainer", "ui/widget/container/framecontainer",
        "ui/widget/container/centercontainer", "ui/widget/horizontalgroup", "ui/widget/iconwidget",
        "ui/widget/linewidget", "ui/widget/textwidget", "common/ui/accent", "common/widget_resources",
        "common/ui/zen_button", "common/ui/zen_action_button", "common/ui/zen_tab_bar", "common/ui/zen_slider",
        "common/ui/slider_step_button", "modules/filebrowser/patches/library_font",
    }
    before_each(function()
        originals = {}
        for _i, name in ipairs(modules) do originals[name] = package.loaded[name]; ZenSpec.unload(name) end
        local Widget = {}
        function Widget:extend(values) return setmetatable(values or {}, { __index = self }) end
        function Widget:new(values)
            local obj = self:extend(values)
            if obj.init then obj:init() end
            return obj
        end
        function Widget:getSize() return self.dimen or { w = #(self.text or "") * 8, h = 20 } end
        function Widget:setMaxWidth(width) self.max_width = width end
        function Widget:paintTo() end
        function Widget:free() self.frees = (self.frees or 0) + 1 end
        for _i, name in ipairs({ "ui/geometry", "ui/gesturerange", "ui/widget/button", "ui/widget/container/inputcontainer",
            "ui/widget/container/framecontainer", "ui/widget/container/centercontainer", "ui/widget/horizontalgroup",
            "ui/widget/iconwidget", "ui/widget/linewidget", "ui/widget/textwidget" }) do ZenSpec.replace(name, Widget) end
        ZenSpec.replace("device", { screen = { scaleBySize = function(_self, value) return value end } })
        ZenSpec.replace("ui/font", { getFace = function() return {} end })
        ZenSpec.replace("ffi/blitbuffer", { COLOR_BLACK = "black", COLOR_WHITE = "white", COLOR_DARK_GRAY = "gray",
            isColor8 = function() return true end })
        ZenSpec.replace("common/ui/accent", {
            color = function() return "accent" end, foreground = function() return "foreground" end,
            styleIcon = function(icon, selected) icon.accent = selected end,
        })
        ZenSpec.replace("common/widget_resources", { paintFrameBorderOnTop = function(frame) frame.border_on_top = true end })
        ZenSpec.replace("modules/filebrowser/patches/library_font", { getFontName = function() return "Library font" end })
        ZenSpec.replace("common/ui/zen_button", {
            paintFilled = function(...) painted = { ... }; painted.style = "filled" end,
            paintOutlined = function(...) painted = { ... }; painted.style = "outlined" end,
        })
        ZenSpec.replace("ui/uimanager", { setDirty = function() focused = true end })
    end)
    after_each(function()
        for _i, name in ipairs(modules) do package.loaded[name] = originals[name] end
    end)

    it("bounds equal tabs and fills only the selected tab with the accent", function()
        local called
        local bar = require("common/ui/zen_tab_bar"):new{
            items = { { text = "small" }, { text = "medium", callback = function() called = true end }, { text = "large" } },
            selected = 2, max_width = 150, cell_height = 32, focusable = true,
        }
        local width = bar.bordersize * 2 + 2
        for i, cell in ipairs(bar.cells) do
            width = width + cell[1].dimen.w
            assert.are.equal(32, cell[1].dimen.h)
            assert.are.equal(i == 2 and "accent" or "white", cell.background)
            assert.are.equal(i == 2 and "foreground" or "black", cell[1][1].fgcolor)
            assert.is_true(cell.focusable)
            assert.is_true(cell.focus_inner_border)
        end
        assert.is_true(width <= 150)
        assert.is_true(bar.border_on_top)
        bar.cells[2].callback()
        assert.is_true(called)
    end)

    it("supports page-browser icons and no selected preset after a granular edit", function()
        local Selection = require("common/ui/zen_tab_bar")
        local bar = Selection:new{ items = { { icon = "/single.svg" }, { icon = "/grid.svg" } },
            selected = 1, icon_size = 24, padding_h = 12, padding_v = 6 }
        assert.is_true(bar.cells[1][1][1].accent)
        assert.is_false(bar.cells[2][1][1].accent)
        bar = Selection:new{ items = { { text = "small" }, { text = "large" } } }
        for _i, cell in ipairs(bar.cells) do assert.is_false(cell.selected) end
    end)

    it("restores existing tab colors and icon contrast after leaving dark mode", function()
        local screen = require("device").screen
        ZenSpec.replace("common/ui/accent", {
            color = function() return screen.night_mode and "night accent" or "accent" end,
            foreground = function() return screen.night_mode and "black" or "white" end,
            styleIcon = function(icon) icon.foreground = screen.night_mode and "black" or "white" end,
        })
        local Selection = require("common/ui/zen_tab_bar")
        for _i, icon in ipairs({ false, "/page-browser.svg" }) do
            screen.night_mode = true
            local callback = function() end
            local bar = Selection:new{ items = { { text = "Active", icon = icon, callback = callback },
                { text = "Inactive" } }, selected = 1 }
            local cell, inactive = bar.cells[1], bar.cells[2]
            local label = cell[1][1]
            cell.invert = true
            for _j, night in ipairs({ true, false, false, true, false }) do
                screen.night_mode = night
                bar:paintTo({}, 0, 0)
                assert.are.equal(night and "night accent" or "accent", cell.background)
                assert.are.equal(night and "black" or "white", cell.focus_border_color)
                assert.are.equal(night and "black" or "white", icon and label.foreground or label.fgcolor)
                assert.are.equal("white", inactive.background)
                assert.are.equal("black", inactive[1][1].fgcolor)
                assert.are.equal(cell, bar.cells[1])
                assert.are.equal(callback, cell.callback)
                assert.is_true(cell.invert)
            end
            assert.are.equal(icon and 3 or nil, label.frees)
        end
    end)

    it("fills the requested width regardless of tab count", function()
        local Selection = require("common/ui/zen_tab_bar")
        for count = 2, 5 do
            local items = {}
            for i = 1, count do items[i] = { text = tostring(i) } end
            local bar = Selection:new{ items = items, width = 203 }
            local width = bar.bordersize * 2 + count - 1
            for _i, cell in ipairs(bar.cells) do width = width + cell[1].dimen.w end
            assert.are.equal(203, width)
        end
    end)

    it("keeps direction icons inside narrow fixed-width tabs", function()
        local items = {}
        for i = 1, 8 do items[i] = { icon = "/direction.svg" } end
        local bar = require("common/ui/zen_tab_bar"):new{ items = items, width = 150, icon_size = 32 }
        for _i, cell in ipairs(bar.cells) do assert.is_true(cell[1][1].width <= cell[1].dimen.w) end
    end)

    it("paints an optional default notch on the slider rail", function()
        local Slider = require("common/ui/zen_slider")
        for _i, marked in ipairs({ false, true }) do
            local ticks = 0
            local slider = Slider:new{ width = 200, value_min = 0, value_max = 100, value = 75,
                default_value = marked and 25 or nil, knob_radius = 4, track_color = "gray" }
            slider:paintTo({ paintRect = function(_self, x, y, w, h, color)
                if w == 2 and h == 14 and color == "black" then
                    ticks = ticks + 1
                    assert.are.equal(61, x)
                    assert.are.equal(13, y)
                end
            end }, 10, 13)
            assert.are.equal(marked and 1 or 0, ticks)
        end
    end)

    it("preserves a granular reader value until the slider is moved to a native step", function()
        local Slider = require("common/ui/zen_slider")
        local slider = Slider:new{ width = 200, value_min = 0, value_max = 8,
            value = 1.5, fractional_value = true }
        assert.are.equal(1.5, slider:getValue())
        slider:applyPosition(slider:_valueToX(2))
        assert.are.equal(2, slider:getValue())
        assert.are.equal(2, Slider:new{ width = 200, value_min = 0, value_max = 8, value = 1.5 }:getValue())
    end)

    it("shares brightness button type, dimensions and font while preserving hold actions", function()
        local hold = function() end
        local button = require("common/ui/slider_step_button"):new{ text = "＋", height = 39, hold_callback = hold }
        assert.are.equal(56, button.width)
        assert.are.equal(39, button.height)
        assert.are.equal(14, button.text_font_size)
        assert.are.equal("Library font", button.text_font_face)
        assert.is_false(button.text_font_bold)
        assert.is_false(button.allow_flash)
        assert.are.equal(0, button.bordersize)
        assert.are.equal(hold, button.hold_callback)
    end)

    it("paints Zen action buttons and supports touch and keyboard focus", function()
        local called
        local button = require("common/ui/zen_action_button"):new{ text = "Advanced", width = 140, height = 40,
            callback = function() called = true end }
        button:paintTo({}, 8, 20)
        assert.are.equal("filled", painted.style)
        assert.are.equal("Advanced", painted[6])
        assert.are.equal(8, button.dimen.x)
        assert.are.equal(20, button.dimen.y)
        assert.is_true(button:onFocus())
        assert.is_true(button.invert)
        assert.is_true(focused)
        assert.is_true(button:onTapSelect())
        assert.is_true(called)
        assert.is_true(button:onUnfocus())
        assert.is_false(button.invert)
        button.outlined = true
        button:paintTo({}, 8, 20)
        assert.are.equal("outlined", painted.style)
    end)
end)
