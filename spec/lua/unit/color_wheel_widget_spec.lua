describe("color picker opacity", function()
    local Picker
    local Blitbuffer
    local saved_modules
    local saved_settings
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
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
                scaleBySize = function(_self, value) return value end,
            },
            isTouchDevice = function() return true end,
            hasKeys = function() return false end,
        })
        ZenSpec.replace("ui/size", {
            padding = { large = 10, default = 5, button = 4 },
            border = { button = 1, thick = 2 },
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
        _G.G_reader_settings = saved_settings
        for _i, name in ipairs(module_names) do package.loaded[name] = saved_modules[name] end
    end)

    it("keeps opacity absent for ordinary color pickers", function()
        local picked
        local picker = Picker:new{
            hex = "#0000FF",
            callback = function(hex, opacity) picked = { hex = hex, opacity = opacity } end,
        }
        assert.is_nil(picker.opacity_slider)
        assert.are.equal(2, #picker.layout)
        picker:onApply()
        assert.are.equal("#0000FF", picked.hex)
        assert.is_nil(picked.opacity)
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
end)
