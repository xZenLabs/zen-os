require("ffi/loadlib")

describe("rounded button feedback", function()
    local originals, settings, Feedback, screen, UIManager, Button, IconButton, mirrored
    local Blitbuffer = require("ffi/blitbuffer")
    local modules = {
        "device", "ui/uimanager", "ui/widget/button", "ui/widget/iconbutton", "ui/bidi",
        "common/ui/button_feedback", "modules/global/patches/button_feedback",
    }

    before_each(function()
        originals, settings = {}, _G.G_reader_settings
        for _i, name in ipairs(modules) do originals[name] = package.loaded[name] or false end
        _G.G_reader_settings = { isFalse = function() return false end }
        screen = {
            scaleBySize = function(_self, size) return size end,
            isColorScreen = function() return false end,
        }
        UIManager = {
            setDirty = function() end, forceRePaint = function() end, yieldToEPDC = function() end,
            widgetRepaint = function(_self, widget) widget:paintTo() end,
            waitForVSync = function() error("ordinary feedback must not wait for refresh completion") end,
        }
        Button = { paintTo = function() end }
        IconButton = {}
        mirrored = false
        ZenSpec.replace("device", { screen = screen })
        ZenSpec.replace("ui/uimanager", UIManager)
        ZenSpec.replace("ui/widget/button", Button)
        ZenSpec.replace("ui/widget/iconbutton", IconButton)
        ZenSpec.replace("ui/bidi", { mirroredUILayout = function() return mirrored end })
        ZenSpec.unload("common/ui/button_feedback")
        ZenSpec.unload("modules/global/patches/button_feedback")
        Feedback = require("common/ui/button_feedback")
    end)

    after_each(function()
        if screen.bb then screen.bb:free() end
        _G.G_reader_settings = settings
        for _i, name in ipairs(modules) do package.loaded[name] = originals[name] or nil end
    end)

    it("pads by four pixels, rounds at eight, and restores grayscale and color pixels", function()
        for _i, buffer_type in ipairs({ Blitbuffer.TYPE_BB8, Blitbuffer.TYPE_BBRGB32 }) do
            screen.bb = Blitbuffer.new(48, 48, buffer_type)
            screen.bb:fill(Blitbuffer.ColorRGB32(32, 64, 96, 255))
            local before = screen.bb:copy()
            local region = Feedback.paddedRegion({ x = 20, y = 20, w = 16, h = 16 })
            assert.are.same({ x = 16, y = 16, w = 24, h = 24 }, region)
            Feedback.invert(region)
            assert.are.equal(before:getPixel(16, 16):getColor8().a,
                screen.bb:getPixel(16, 16):getColor8().a)
            assert.are.equal(before:getPixel(21, 16):getColor8().a,
                screen.bb:getPixel(21, 16):getColor8().a)
            assert.are_not.equal(before:getPixel(22, 16):getColor8().a,
                screen.bb:getPixel(22, 16):getColor8().a)
            assert.are_not.equal(before:getPixel(20, 20):getColor8().a,
                screen.bb:getPixel(20, 20):getColor8().a)
            Feedback.invert(region)
            for y = 0, 47 do
                for x = 0, 47 do
                    assert.are.equal(tostring(before:getPixel(x, y):getColorRGB32()),
                        tostring(screen.bb:getPixel(x, y):getColorRGB32()))
                end
            end
            before:free()
            screen.bb:free()
            screen.bb = nil
        end
    end)

    it("restores icon pixels before callbacks, including close buttons, RTL, and focused icons", function()
        screen.bb = Blitbuffer.new(80, 60, Blitbuffer.TYPE_BB8)
        screen.bb:fill(Blitbuffer.Color8(32))
        require("modules/global/patches/button_feedback")()
        local patched_tap = IconButton.onTapIconButton
        require("modules/global/patches/button_feedback")()
        assert.are.equal(patched_tap, IconButton.onTapIconButton)
        for _i, rtl in ipairs({ false, true }) do
            mirrored = rtl
            local icon = setmetatable({
                dimen = { x = 10, y = 10, w = 50, h = 32 }, width = 16, height = 16,
                padding_left = 8, padding_right = 24, padding_top = 8,
                image = { invert = true }, allow_flash = false,
            }, { __index = IconButton })
            local called, flashes = 0, 0
            icon.callback = function()
                called = called + 1
                assert.are.equal(32, screen.bb:getPixel(rtl and 34 or 18, 18).a)
                assert.is_true(icon.image.invert)
            end
            UIManager.yieldToEPDC = function()
                flashes = flashes + 1
                assert.are.equal(223, screen.bb:getPixel(rtl and 34 or 18, 18).a)
            end
            assert.is_true(icon:onTapIconButton())
            assert.are.equal(1, called)
            assert.are.equal(1, flashes)
            _G.G_reader_settings.isFalse = function() return true end
            assert.is_true(icon:onTapIconButton())
            assert.are.equal(2, called)
            assert.are.equal(1, flashes)
            _G.G_reader_settings.isFalse = function() return false end
        end
    end)

    it("flashes only a circle and restores its pixels, honoring Flash UI", function()
        for _i, buffer_type in ipairs({ Blitbuffer.TYPE_BB8, Blitbuffer.TYPE_BBRGB32 }) do
            screen.bb = Blitbuffer.new(80, 80, buffer_type)
            screen.bb:fill(Blitbuffer.ColorRGB32(32, 64, 96, 255))
            local before = screen.bb:copy()
            local region = { x = 20, y = 20, w = 32, h = 32 }
            local modes = {}
            UIManager.setDirty = function(_self, owner, mode, refreshed)
                assert.is_nil(owner)
                assert.are.equal(region, refreshed)
                modes[#modes + 1] = mode
            end
            UIManager.yieldToEPDC = function()
                assert.are_not.equal(tostring(before:getPixel(36, 36)), tostring(screen.bb:getPixel(36, 36)))
                for _j, point in ipairs({ { 20, 20 }, { 24, 24 }, { 36, 56 }, { 72, 36 } }) do
                    assert.are.equal(tostring(before:getPixel(point[1], point[2])),
                        tostring(screen.bb:getPixel(point[1], point[2])))
                end
            end
            Feedback.flash(region, 16)
            assert.are.same({ "fast", "ui" }, modes)
            for y = 0, 79 do
                for x = 0, 79 do
                    assert.are.equal(tostring(before:getPixel(x, y)), tostring(screen.bb:getPixel(x, y)))
                end
            end
            _G.G_reader_settings.isFalse = function() return true end
            Feedback.flash(region, 16)
            assert.are.same({ "fast", "ui" }, modes)
            _G.G_reader_settings.isFalse = function() return false end
            before:free()
            screen.bb:free()
            screen.bb = nil
        end
    end)

    it("restores gray content with UI refreshes on monochrome and color screens", function()
        screen.bb = Blitbuffer.new(80, 60, Blitbuffer.TYPE_BB8)
        screen.bb:fill(Blitbuffer.Color8(32))
        require("modules/global/patches/button_feedback")()
        local region = { x = 20, y = 20, w = 32, h = 24 }
        local button = setmetatable({ dimen = region, enabled = true }, { __index = Button })
        for _i, color in ipairs({ false, true }) do
            screen.isColorScreen = function() return color end
            local modes = {}
            local expected_region = region
            UIManager.setDirty = function(_self, owner, mode, refreshed)
                assert.is_nil(owner)
                assert.are.same(expected_region, refreshed)
                modes[#modes + 1] = mode
            end
            Feedback.flash(region)
            local mode = color and "ui" or "fast"
            assert.are.same({ mode, "ui" }, modes)
            assert.are.equal(32, screen.bb:getPixel(28, 28).a)

            modes = {}
            expected_region = Feedback.paddedRegion(region)
            button:_doFeedbackHighlight()
            button:_undoFeedbackHighlight(false)
            assert.are.same({ mode, "ui" }, modes)
            assert.are.equal(32, screen.bb:getPixel(28, 28).a)
        end
    end)

    it("waits for MTK Kindle updates before overwriting the previous frame or highlight", function()
        local device = package.loaded.device
        device.isKindle = function() return true end
        device.isMTK = function() return true end
        local reading, waits = true, 0
        screen.bb = {
            invertRect = function() assert.is_false(reading, "EPDC is still reading the framebuffer") end,
            free = function() end,
        }
        UIManager.waitForVSync = function()
            reading = false
            waits = waits + 1
        end
        UIManager.forceRePaint = function() reading = true end
        local region = { x = 20, y = 20, w = 200, h = 60 }
        Feedback.flash(region)
        assert.are.equal(2, waits)

        require("modules/global/patches/button_feedback")()
        local button = setmetatable({ dimen = region, enabled = true }, { __index = Button })
        reading = true
        button:_doFeedbackHighlight()
        UIManager:forceRePaint()
        button:_undoFeedbackHighlight(false)
        assert.are.equal(4, waits)

        UIManager.waitForVSync = function() error("other devices must not wait") end
        reading = false
        device.isKindle = function() return false end
        Feedback.invert(region)
        device.isKindle = function() return true end
        device.isMTK = function() return false end
        Feedback.invert(region)
    end)

    it("skips highlighting and restore refreshes for buttons with feedback disabled", function()
        require("modules/global/patches/button_feedback")()
        UIManager.setDirty = function() error("disabled feedback must not refresh") end
        UIManager.widgetRepaint = function() error("disabled feedback must not repaint") end
        Feedback.invert = function() error("disabled feedback must not invert") end
        for _i, vsync in ipairs({ false, true }) do
            local button = setmetatable({ allow_flash = false, vsync = vsync,
                dimen = { x = 20, y = 20, w = 32, h = 24 },
            }, { __index = Button })
            button:_doFeedbackHighlight()
            button:_undoFeedbackHighlight(true)
            assert.is_nil(button._zen_feedback_region)
        end
    end)

    it("restores text-button state and keeps vsync redraws and translucent refreshes working", function()
        screen.bb = Blitbuffer.new(80, 60, Blitbuffer.TYPE_BB8)
        screen.bb:fill(Blitbuffer.Color8(32))
        Button.paintTo = function(self)
            local d = self.dimen
            screen.bb:paintRect(d.x, d.y, d.w, d.h, Blitbuffer.Color8(32))
        end
        require("modules/global/patches/button_feedback")()
        for _i, vsync in ipairs({ false, true }) do
            local button = setmetatable({ dimen = { x = 20, y = 20, w = 32, h = 24 },
                vsync = vsync, enabled = true, show_parent = {},
            }, { __index = Button })
            button:_doFeedbackHighlight()
            assert.are.equal(223, screen.bb:getPixel(28, 28).a)
            if vsync then
                button:paintTo()
                assert.are.equal(223, screen.bb:getPixel(28, 28).a)
            end
            UIManager.setDirty = function(_self, owner, mode)
                assert.are.equal(button.show_parent, owner)
                assert.are.equal("ui", mode)
            end
            button:_undoFeedbackHighlight(true)
            assert.are.equal(32, screen.bb:getPixel(28, 28).a)
            assert.is_nil(button._zen_feedback_region)
            UIManager.setDirty = function() end
        end
    end)
end)
