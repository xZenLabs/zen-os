describe("color picker opacity", function()
    local Picker
    local Blitbuffer
    local saved_modules
    local saved_settings
    local new_buffer_stub
    local drag_buffer
    local module_names = {
        "ffi/blitbuffer", "device", "gettext", "ui/font", "ui/geometry", "ui/gesturerange",
        "ui/size", "ui/uimanager", "ui/widget/button", "ui/widget/container/centercontainer",
        "ui/widget/container/framecontainer", "ui/widget/container/widgetcontainer",
        "ui/widget/focusmanager", "ui/widget/horizontalgroup", "ui/widget/horizontalspan",
        "ui/widget/textwidget", "ui/widget/titlebar", "ui/widget/verticalgroup",
        "ui/widget/verticalspan", "common/reader_themes", "common/ui/zen_button",
        "common/ui/zen_slider", "common/ui/zen_solid_circle", "common/ui/color_wheel_widget",
    }

    before_each(function()
        saved_settings = G_reader_settings
        saved_modules = {}
        for _i, name in ipairs(module_names) do
            saved_modules[name] = package.loaded[name]
            ZenSpec.unload(name)
        end
        Blitbuffer = require("ffi/blitbuffer")
        local Widget = {}
        function Widget:extend(values)
            return setmetatable(values or {}, { __index = self })
        end
        function Widget:new(values)
            values = self:extend(values)
            if values.init then values:init() end
            return values
        end
        function Widget:getSize()
            return self.dimen or { w = self.width or 100, h = self.height or 20 }
        end
        function Widget:setText(text) self.text = text end
        function Widget:free()
            for _i, child in ipairs(self) do
                if child.free then child:free() end
            end
        end
        for _i, name in ipairs({
            "ui/widget/button", "ui/widget/container/centercontainer",
            "ui/widget/container/framecontainer", "ui/widget/container/widgetcontainer",
            "ui/widget/focusmanager", "ui/widget/horizontalgroup", "ui/widget/horizontalspan",
            "ui/widget/textwidget", "ui/widget/titlebar", "ui/widget/verticalspan", "ui/gesturerange",
        }) do
            ZenSpec.replace(name, Widget)
        end
        ZenSpec.replace("ui/widget/verticalgroup", Widget:extend{
            getSize = function(self)
                local height = 0
                for _i, child in ipairs(self) do height = height + child:getSize().h end
                return { w = 600, h = height }
            end,
        })
        ZenSpec.replace("ui/geometry", { new = function(_self, values) return values end })
        ZenSpec.replace("ui/font", { getFace = function() return {} end })
        ZenSpec.replace("device", {
            screen = {
                bb = { getPixel = function() return Blitbuffer.COLOR_WHITE end },
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
                scaleBySize = function(_self, value) return value end,
            },
            isTouchDevice = function() return true end,
            hasKeys = function() return false end,
        })
        ZenSpec.replace("ui/size", {
            padding = { large = 10, default = 5, button = 4 },
            border = { button = 1, thick = 2, window = 1 },
            radius = { button = 3 },
            item = { height_large = 40 },
        })
        ZenSpec.replace("ui/uimanager", { setDirty = function() end, close = function() end })
        ZenSpec.replace("common/ui/zen_button", {})
        ZenSpec.replace("common/reader_themes", { colorToHsv = function() return 240, 1, 1 end })
        ZenSpec.replace("gettext", function(text) return text end)
        _G.G_reader_settings = ZenSpec.memorySettings()
        Picker = require("common/ui/color_wheel_widget")
    end)

    after_each(function()
        if drag_buffer then
            drag_buffer:free()
            drag_buffer = nil
        end
        if new_buffer_stub then
            new_buffer_stub:revert()
            new_buffer_stub = nil
        end
        _G.G_reader_settings = saved_settings
        for _i, name in ipairs(module_names) do package.loaded[name] = saved_modules[name] end
    end)

    it("keeps color-wheel pixel writes within the allocated buffer", function()
        local picker = Picker:new{ hex = "#0000FF", opacity = 60 }
        local writes = 0
        new_buffer_stub = stub(Blitbuffer, "new", function(width, height)
            return {
                paintRectRGB32 = function() end,
                setPixel = function(_self, x, y)
                    assert(x >= 0 and x < width, "pixel x outside color-wheel buffer")
                    assert(y >= 0 and y < height, "pixel y outside color-wheel buffer")
                    writes = writes + 1
                end,
                free = function() end,
            }
        end)
        for _i, radius in ipairs({ 1, picker.color_wheel.draw_radius }) do
            picker.color_wheel.draw_radius = radius
            picker.color_wheel:_renderToBuffer(10, 10)
        end
        assert.is_true(writes > 0)
        picker:onCloseWidget()
    end)

    it("keeps opacity absent for ordinary color pickers", function()
        local picked
        local picker = Picker:new{
            hex = "#0000FF",
            callback = function(hex, opacity) picked = { hex = hex, opacity = opacity } end,
        }
        assert.is_nil(picker.opacity_slider)
        assert.is_nil(picker[1][1].left_icon)
        assert.is_true(picker[1][1].close_button)
        assert.is_function(picker[1][1].close_callback)
        assert.are.equal(2, #picker.layout)
        picker:onApply()
        assert.are.equal("#0000FF", picked.hex)
        assert.is_nil(picked.opacity)
        picker:onCloseWidget()
    end)

    it("returns from a settings color picker with a left back button without applying edits", function()
        local calls = {}
        local picker
        package.loaded["ui/uimanager"].close = function(_self, widget)
            assert.are.equal(picker, widget)
            calls[#calls + 1] = "close"
        end
        picker = Picker:new{
            hex = "#0000FF", opacity = 60, back_button = true,
            callback = function() calls[#calls + 1] = "apply" end,
            cancel_callback = function() calls[#calls + 1] = "cancel" end,
            close_callback = function() calls[#calls + 1] = "closed" end,
        }
        picker.opacity_slider.on_change(25)
        picker:update()
        local title_bar = picker[1][1]
        assert.are.equal("chevron.left", title_bar.left_icon)
        assert.is_false(title_bar.close_button)
        assert.is_nil(title_bar.close_callback)
        assert.are.same({}, calls)
        title_bar.left_icon_tap_callback()
        assert.are.same({ "close", "cancel", "closed" }, calls)
        picker:onCloseWidget()
    end)

    it("places the accent reset left of Apply and closes without applying a custom color", function()
        local calls = {}
        package.loaded["ui/uimanager"].close = function() calls[#calls + 1] = "close" end
        local picker = Picker:new{
            hex = "#0000FF", opacity = 60,
            reset_text = "Accent color",
            reset_callback = function() calls[#calls + 1] = "accent" end,
            callback = function() calls[#calls + 1] = "apply" end,
            close_callback = function() calls[#calls + 1] = "closed" end,
        }
        picker.opacity_slider.on_change(25)
        picker:update()
        local buttons = picker.layout[#picker.layout]
        assert.are.equal(2, #buttons)
        assert.are.equal("Accent color", buttons[1].text)
        assert.are.equal("Apply", buttons[2].text)
        local footer = picker[1][#picker[1] - 1][1]
        assert.are.equal(buttons[1], footer[1])
        assert.are.equal(buttons[2], footer[3])
        assert.is_true(buttons[1].width + footer[2].width + buttons[2].width <= picker.width)
        buttons[1].callback()
        assert.are.same({ "close", "accent", "closed" }, calls)
        picker:onCloseWidget()
    end)

    it("applies the custom color or cancels without selecting the accent", function()
        local resets, applies = 0, 0
        local picker = Picker:new{
            hex = "#0000FF", opacity = 35,
            reset_callback = function() resets = resets + 1 end,
            callback = function(hex, opacity)
                assert.are.equal("#0000FF", hex)
                assert.are.equal(35, opacity)
                applies = applies + 1
            end,
        }
        picker:onCancel()
        assert.are.same({ 0, 0 }, { resets, applies })
        picker.layout[#picker.layout][2].callback()
        assert.are.same({ 0, 1 }, { resets, applies })
        picker:onCloseWidget()
    end)

    it("embeds the controls without a title or Apply button and only applies changed colors", function()
        local applied, closes, dirty_owner = 0, 0, nil
        local parent = {}
        package.loaded["ui/uimanager"].close = function() closes = closes + 1 end
        package.loaded["ui/uimanager"].setDirty = function(_self, owner) dirty_owner = owner end
        local picker = Picker:new{
            embedded = true, show_parent = parent,
            dimen = { w = 600, h = 500 }, hex = "#0000FF", opacity = 60,
            callback = function(hex, opacity)
                assert.are.equal("#0000FF", hex)
                assert.are.equal(60, opacity)
                applied = applied + 1
            end,
        }

        assert.are.equal(500, picker.screen_height)
        assert.are.equal(2, #picker.layout)
        assert.are.equal(7, #picker[1])
        assert.are.equal(parent, dirty_owner)
        picker:onApply()
        assert.are.equal(0, applied)
        picker:setHex("#0000FF")
        picker:onApply()
        picker:onApply()

        assert.are.equal(1, applied)
        assert.are.equal(0, closes)
        picker:onCloseWidget()
    end)

    it("lets footer gestures through and keeps swipes on embedded controls within the page", function()
        local picker = Picker:new{
            embedded = true, dimen = { w = 600, h = 500 }, hex = "#0000FF", opacity = 60,
        }
        local inside_picker = false
        local gesture = { direction = "west", pos = {
            intersectWith = function(_pos, dimen)
                return inside_picker and dimen == picker.dimen
            end,
        } }
        assert.is_false(picker:onTapColorWheel(nil, gesture))
        assert.is_false(picker:onSwipeColorWheel(nil, gesture))
        inside_picker = true
        assert.is_true(picker:onSwipeColorWheel(nil, gesture))
        picker:onCloseWidget()
    end)

    it("previews opacity and preserves it through color-picker rebuilds", function()
        local picked
        local picker = Picker:new{
            hex = "#0000FF", opacity = 100,
            callback = function(hex, opacity) picked = { hex = hex, opacity = opacity } end,
        }
        assert.are.equal(3, #picker.layout)
        picker.opacity_slider.on_change(40)
        assert.are.equal(40, picker.opacity)
        assert.are.equal(1, picker.value)
        assert.is_nil(picked)
        local preview = picker._live_preview
        local bb = Blitbuffer.new(preview.width, preview.height, Blitbuffer.TYPE_BBRGB32)
        preview:paintTo(bb, 0, 0)
        local pixel = bb:getPixel(math.floor(preview.width / 2), math.floor(preview.height / 2))
        assert.are.equal(153, pixel:getR())
        assert.are.equal(153, pixel:getG())
        assert.are.equal(255, pixel:getB())
        bb:free()

        picker:setHex("#0000FF")
        assert.are.equal(40, picker.opacity_slider:getValue())
        picker.layout[2][1].callback()
        assert.are.equal(39, picker.opacity)
        picker.layout[2][2].callback()
        assert.are.equal(40, picker.opacity)
        picker.layout[1][1].callback()
        assert.are.equal(0.99, picker.value)
        assert.are.equal(40, picker.opacity)
        picker.layout[1][2].callback()
        picker:onApply()
        assert.are.same({ hex = "#0000FF", opacity = 40 }, picked)
        picker:onCloseWidget()
        assert.is_nil(picker.opacity_slider)
    end)

    it("allows fully transparent fills and clamps opacity to its bounds", function()
        local applies = 0
        local picker = Picker:new{
            hex = "#0000FF", opacity = 0,
            callback = function() applies = applies + 1 end,
        }
        assert.are.equal(0, picker.opacity_slider:getValue())
        picker.layout[2][1].callback()
        assert.are.equal(0, picker.opacity)
        picker.opacity_slider.on_change(150)
        assert.are.equal(100, picker.opacity)
        picker.layout[2][2].callback()
        assert.are.equal(100, picker.opacity)
        picker:onCancel()
        assert.are.equal(0, applies)
        picker:onCloseWidget()
    end)

    it("routes tap, pan, release and swipe gestures to the optional opacity slider", function()
        local picker = Picker:new{ hex = "#0000FF", opacity = 50 }
        local gesture = { pos = { intersectWith = function() return false end } }
        for _i, event in ipairs({ "Tap", "Pan", "PanRelease", "Swipe" }) do
            local handled = false
            picker.brightness_slider["handle" .. event] = function() return false end
            picker.opacity_slider["handle" .. event] = function(_self, ges)
                assert.are.equal(gesture, ges)
                handled = true
                return true
            end
            assert.is_true(picker["on" .. event .. "ColorWheel"](picker, nil, gesture))
            assert.is_true(handled)
        end
        picker:onCloseWidget()
    end)

    it("repaints only the slider and label while dragging, then refreshes the picker on release", function()
        local picker = Picker:new{ hex = "#0000FF", opacity = 50 }
        drag_buffer = Blitbuffer.new(600, 800, Blitbuffer.TYPE_BBRGB32)
        package.loaded.device.screen.bb = drag_buffer
        local dirty
        package.loaded["ui/uimanager"].setDirty = function(_self, owner, mode, region)
            dirty = { owner = owner, mode = mode, region = region }
        end
        local controls = picker[1][3][1]
        for _i, entry in ipairs({
            { slider = picker.brightness_slider, label = controls[1][1][1], title = "Brightness" },
            { slider = picker.opacity_slider, label = controls[3][1][1], title = "Opacity" },
        }) do
            local slider, label = entry.slider, entry.label
            label.paintTo = function(_self, bb, x, y)
                assert.are.equal(drag_buffer, bb)
                assert.are.equal(250, x)
                assert.are.equal(slider.dimen.y - 28, y)
            end
            slider:paintTo(drag_buffer, 180, 100 * _i)
            local gesture = { direction = "west", pos = {
                y = slider.dimen.y + slider.dimen.h / 2,
                intersectWith = function(pos, dimen)
                    return pos.x >= dimen.x and pos.x < dimen.x + dimen.w
                        and pos.y >= dimen.y and pos.y < dimen.y + dimen.h
                end,
            } }
            for _k, x in ipairs({ slider:_knobAbsX(), 310, 250 }) do
                gesture.pos.x = x
                assert.is_true(picker:onPanColorWheel(nil, gesture))
                assert.is_nil(dirty.owner)
                assert.are.equal("fast", dirty.mode)
                assert.are.same({ x = 0, y = slider.dimen.y - 28, w = 600,
                    h = slider.dimen.h + 28 }, dirty.region)
                assert.is_false(slider.hide_knob)
                assert.are.equal(entry.title .. ": " .. slider:getValue() .. "%", label.text)
            end
            assert.is_true(picker:onPanReleaseColorWheel(nil, gesture))
            assert.is_false(slider._dragging)
            assert.are.equal(picker, dirty.owner)
            assert.are.equal("ui", dirty.mode)
        end
        assert.are.equal(picker.brightness_slider:getValue() / 100, picker.value)
        assert.are.equal(picker.value, picker.color_wheel.value)
        assert.are.equal(picker.opacity_slider:getValue(), picker.opacity)
        picker:onCloseWidget()
    end)
end)
