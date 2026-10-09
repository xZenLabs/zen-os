require("ffi/loadlib")

describe("rounded button feedback", function()
    local originals, settings, Feedback, screen, UIManager, Button, IconButton, mirrored, logs
    local Blitbuffer = require("ffi/blitbuffer")
    local Geom = require("ui/geometry")
    local modules = {
        "device", "ui/uimanager", "ui/widget/button", "ui/widget/iconbutton", "ui/bidi",
        "common/ui/button_feedback", "modules/global/patches/button_feedback", "common/zen_logger",
    }

    before_each(function()
        originals, settings, logs = {}, _G.G_reader_settings, {}
        for _i, name in ipairs(modules) do originals[name] = package.loaded[name] or false end
        _G.G_reader_settings = { isFalse = function() return false end }
        screen = {
            scaleBySize = function(_self, size) return size end,
            isColorScreen = function() return false end,
        }
        UIManager = {
            setDirty = function() end, forceRePaint = function() end, yieldToEPDC = function() end,
            widgetRepaint = function(_self, widget) widget:paintTo() end,
            waitForVSync = function() error("feedback must not wait for refresh completion") end,
        }
        Button = { paintTo = function() end }
        IconButton = {}
        mirrored = false
        ZenSpec.replace("device", { screen = screen })
        ZenSpec.replace("ui/uimanager", UIManager)
        ZenSpec.replace("ui/widget/button", Button)
        ZenSpec.replace("ui/widget/iconbutton", IconButton)
        ZenSpec.replace("ui/bidi", { mirroredUILayout = function() return mirrored end })
        ZenSpec.replace("common/zen_logger", { new = function()
            return {
                dbg = function() error("feedback must only log fallback warnings") end,
                warn = function(...) logs[#logs + 1] = { ... } end,
            }
        end })
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
                image = { invert = true }, allow_flash = true,
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

    it("runs disabled-flash icon callbacks without touching the framebuffer or forcing a repaint", function()
        require("modules/global/patches/button_feedback")()
        Feedback.flash = function() error("disabled feedback must not flash") end
        UIManager.forceRePaint = function() error("disabled feedback must not force a repaint") end
        local called = 0
        local icon = setmetatable({
            allow_flash = false,
            callback = function() called = called + 1 end,
        }, { __index = IconButton })
        assert.is_true(icon:onTapIconButton())
        assert.are.equal(1, called)
    end)

    it("ignores disabled icon taps with flashing enabled or disabled", function()
        require("modules/global/patches/button_feedback")()
        Feedback.flash = function() error("disabled icons must not flash") end
        UIManager.forceRePaint = function() error("disabled icons must not repaint") end
        for _i, flash_ui in ipairs({ false, true }) do
            _G.G_reader_settings.isFalse = function() return not flash_ui end
            for _j, allow_flash in ipairs({ false, true }) do
                local icon = setmetatable({
                    enabled = false, allow_flash = allow_flash,
                    callback = function() error("disabled icons must not activate") end,
                }, { __index = IconButton })
                assert.is_true(icon:onTapIconButton())
            end
        end
    end)

    it("does not highlight disabled buttons", function()
        require("modules/global/patches/button_feedback")()
        Feedback.invert = function() error("disabled buttons must not invert") end
        UIManager.setDirty = function() error("disabled buttons must not refresh") end
        local button = setmetatable({ enabled = false }, { __index = Button })
        button:_doFeedbackHighlight()
        button:_undoFeedbackHighlight(false)
        assert.is_nil(button._zen_feedback_region)
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
                assert.are.same(region, refreshed)
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
            assert.are.same({ "ui", "ui" }, modes)
            for y = 0, 79 do
                for x = 0, 79 do
                    assert.are.equal(tostring(before:getPixel(x, y)), tostring(screen.bb:getPixel(x, y)))
                end
            end
            _G.G_reader_settings.isFalse = function() return true end
            Feedback.flash(region, 16)
            assert.are.same({ "ui", "ui" }, modes)
            _G.G_reader_settings.isFalse = function() return false end
            before:free()
            screen.bb:free()
            screen.bb = nil
        end
    end)

    it("merges custom button feedback with a subsequent fullscreen refresh", function()
        screen.bb = Blitbuffer.new(80, 60, Blitbuffer.TYPE_BB8)
        screen.bb:fill(Blitbuffer.Color8(32))
        local region = { x = 20, y = 20, w = 32, h = 24 }
        local fullscreen = Geom:new{ x = 0, y = 0, w = 80, h = 60 }
        local refreshes = 0
        UIManager.setDirty = function(_self, owner, mode, refreshed)
            assert.is_nil(owner)
            assert.are.equal("ui", mode)
            assert.is_true(fullscreen:openIntersectWith(refreshed))
            assert.is_true(refreshed:openIntersectWith(fullscreen))
            assert.are.same(fullscreen, fullscreen:combine(refreshed))
            refreshes = refreshes + 1
        end
        Feedback.flash(region)
        Feedback.flashButton(region)
        assert.are.equal(4, refreshes)
        assert.is_nil(getmetatable(region))
    end)

    it("keeps custom button feedback within its supplied bounds", function()
        local region = { x = 20, y = 20, w = 100, h = 60 }
        local flashes = 0
        Feedback.flash = function(refreshed)
            assert.are.equal(region, refreshed)
            flashes = flashes + 1
        end
        Feedback.flashButton(region)
        Feedback.flashButton(nil)
        Feedback.flashButton({ w = 100, h = 60 })
        assert.are.equal(1, flashes)
        assert.are.same({ x = 20, y = 20, w = 100, h = 60 }, region)
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
            assert.are.same({ "ui", "ui" }, modes)
            assert.are.equal(32, screen.bb:getPixel(28, 28).a)

            modes = {}
            button:_doFeedbackHighlight()
            button:_undoFeedbackHighlight(false)
            assert.are.same({ "ui", "ui" }, modes)
            assert.are.equal(32, screen.bb:getPixel(28, 28).a)
        end
    end)

    it("waits for monochrome submission with and without MTK without waiting for completion", function()
        local reading, submitted = true, {}
        screen.marker = 1
        screen.bb = {
            invertRect = function() assert.is_false(reading, "EPDC is still reading the framebuffer") end,
            free = function() end,
        }
        local submission_result
        screen.mech_wait_update_submission = function(_self, marker)
            assert.are.equal(screen.marker, marker)
            submitted[#submitted + 1] = marker
            reading = false
            return submission_result
        end
        UIManager.forceRePaint = function()
            screen.marker = screen.marker + 1
            reading = true
        end
        require("modules/global/patches/button_feedback")()
        local region = { x = 20, y = 20, w = 200, h = 60 }
        local button = setmetatable({ dimen = region, enabled = true }, { __index = Button })
        for _i, mtk in ipairs({ false, true }) do
            package.loaded.device.isMTK = function() return mtk end
            for _j, result in ipairs({ 0, 25 }) do
                submission_result = result
                Feedback.flash(region)
                button:_doFeedbackHighlight()
                UIManager:forceRePaint()
                button:_undoFeedbackHighlight(false)
            end
        end
        assert.are.same({ 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9 }, submitted)
        assert.are.same({}, logs)
    end)

    it("falls back to completion when monochrome MTK submission is unavailable", function()
        local device = package.loaded.device
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
        require("modules/global/patches/button_feedback")()
        local button = setmetatable({ dimen = region, enabled = true }, { __index = Button })
        device.isMTK = function() return true end
        Feedback.flash(region)
        reading = true
        button:_doFeedbackHighlight()
        UIManager:forceRePaint()
        button:_undoFeedbackHighlight(false)
        assert.are.equal(4, waits)
        assert.are.equal(4, #logs)
        assert.are.equal("Using VSync fallback: update submission unavailable", logs[1][1])
        device.isMTK = function() return false end

        UIManager.waitForVSync = function() error("other monochrome devices must not wait") end
        reading = false
        Feedback.invert(region)
    end)

    it("falls back to completion when the submission ioctl fails", function()
        package.loaded.device.isMTK = function() return false end
        local reading, events = true, {}
        screen.marker = 7
        screen.bb = {
            invertRect = function() assert.is_false(reading, "EPDC is still reading the framebuffer") end,
            free = function() end,
        }
        screen.mech_wait_update_submission = function(_self, marker)
            events[#events + 1] = marker
            return -1
        end
        UIManager.waitForVSync = function()
            events[#events + 1] = "complete"
            reading = false
        end
        Feedback.invert({ x = 20, y = 20, w = 200, h = 60 })
        assert.are.same({ 7, "complete" }, events)
        assert.are.same({
            { "Using VSync fallback: submission wait failed", "marker=", 7 },
        }, logs)
    end)

    it("skips submission waits for invalid or already completed markers", function()
        package.loaded.device.isMTK = function() return true end
        local inversions = 0
        screen.bb = {
            invertRect = function() inversions = inversions + 1 end,
            free = function() end,
        }
        screen.mech_wait_update_submission = function() error("no pending update must not wait") end
        screen.marker = 0
        Feedback.invert({ x = 20, y = 20, w = 200, h = 60 })
        screen.marker, screen.dont_wait_for_marker = 7, 7
        Feedback.invert({ x = 20, y = 20, w = 200, h = 60 })
        assert.is_true(inversions > 0)
        assert.are.same({}, logs)
    end)

    it("uses asynchronous feedback on unsupported monochrome screens, including Sunxi", function()
        local inversions, yields = 0, 0
        screen.bb = {
            invertRect = function() inversions = inversions + 1 end,
            free = function() end,
        }
        UIManager.yieldToEPDC = function() yields = yields + 1 end
        require("modules/global/patches/button_feedback")()
        local region = { x = 20, y = 20, w = 200, h = 60 }
        local button = setmetatable({ dimen = region, enabled = true }, { __index = Button })
        for _i, sunxi in ipairs({ false, true }) do
            package.loaded.device.isSunxi = function() return sunxi end
            Feedback.flash(region)
            button:_doFeedbackHighlight()
            UIManager:forceRePaint()
            button:_undoFeedbackHighlight(false)
        end
        assert.are.equal(2, yields)
        assert.is_true(inversions > 0)
        assert.are.same({}, logs)
    end)

    it("preserves pending Colorsoft frames before highlighting and restoring", function()
        screen.isColorScreen = function() return true end
        package.loaded.device.isMTK = function() return true end
        screen.bb = Blitbuffer.new(48, 48, Blitbuffer.TYPE_BB8)
        screen.bb:fill(Blitbuffer.Color8(32))
        screen.marker = 1
        local frames = {}
        screen.mech_wait_update_submission = function(_self, marker)
            if not frames[marker] then
                frames[marker] = {
                    corner = screen.bb:getPixel(20, 20).a,
                    center = screen.bb:getPixel(28, 28).a,
                }
            end
            return 0
        end
        UIManager.forceRePaint = function()
            screen:mech_wait_update_submission(screen.marker)
            screen.marker = screen.marker + 1
        end

        Feedback.flash({ x = 20, y = 20, w = 24, h = 24 })
        UIManager:forceRePaint()

        assert.are.same({ corner = 32, center = 32 }, frames[1])
        assert.are.same({ corner = 32, center = 223 }, frames[2])
        assert.are.equal(32, screen.bb:getPixel(28, 28).a)
    end)

    it("uses asynchronous feedback on color screens without submission support", function()
        local device = package.loaded.device
        screen.isColorScreen = function() return true end
        screen.marker = 1
        local inversions, yields = 0, 0
        screen.bb = {
            invertRect = function() inversions = inversions + 1 end,
            free = function() end,
        }
        UIManager.yieldToEPDC = function() yields = yields + 1 end
        require("modules/global/patches/button_feedback")()
        local region = { x = 20, y = 20, w = 32, h = 24 }
        local button = setmetatable({ dimen = region, enabled = true }, { __index = Button })
        for _i, mtk in ipairs({ false, true }) do
            device.isMTK = function() return mtk end
            Feedback.flash(region)
            button:_doFeedbackHighlight()
            UIManager:forceRePaint()
            button:_undoFeedbackHighlight(false)
        end
        assert.are.equal(2, yields)
        assert.is_true(inversions > 0)
    end)

    it("never falls back to VSync when color submission fails", function()
        screen.isColorScreen = function() return true end
        package.loaded.device.isMTK = function() return true end
        screen.marker = 1
        local submissions = 0
        screen.mech_wait_update_submission = function()
            submissions = submissions + 1
            return -1
        end
        screen.bb = Blitbuffer.new(48, 48, Blitbuffer.TYPE_BB8)
        screen.bb:fill(Blitbuffer.Color8(32))

        Feedback.flash({ x = 20, y = 20, w = 24, h = 24 })

        assert.are.equal(2, submissions)
        assert.are.equal(32, screen.bb:getPixel(28, 28).a)
        assert.are.same({}, logs)
    end)

    it("flashes the painted borderless icon without enlarging or moving its tap target", function()
        require("modules/global/patches/button_feedback")()
        local inverted, refreshed
        Feedback.invert = function(region) inverted = region end
        UIManager.setDirty = function(_self, _owner, _mode, region) refreshed = region end
        local dimen = { x = 20, y = 20, w = 100, h = 60 }
        for _i, vsync in ipairs({ false, true }) do
            local icon_dimen = { x = 52, y = 32, w = 36, h = 36 }
            local button = setmetatable({ dimen = dimen, bordersize = 0, vsync = vsync,
                label_widget = { is_icon = true, dimen = icon_dimen },
            }, { __index = Button })
            button:_doFeedbackHighlight()
            assert.are.same(vsync and icon_dimen or { x = 48, y = 28, w = 44, h = 44 }, inverted)
            assert.are.equal(inverted, refreshed)
            assert.are.equal(dimen, button.dimen)
            button:_undoFeedbackHighlight(false)
            assert.are.equal(inverted, refreshed)
        end
    end)

    it("adds no feedback padding outside KOReader pager chevron icons", function()
        require("modules/global/patches/button_feedback")()
        local inverted, refreshed
        Feedback.invert = function(region) inverted = region end
        UIManager.setDirty = function(_self, _owner, _mode, region) refreshed = region end
        local dimen = { x = 20, y = 20, w = 100, h = 60 }
        local icon_dimen = { x = 52, y = 32, w = 36, h = 36 }
        for _i, icon in ipairs({ "chevron.left", "chevron.right", "chevron.first", "chevron.last" }) do
            local button = setmetatable({ icon = icon, dimen = dimen, bordersize = 0,
                label_widget = { is_icon = true, dimen = icon_dimen },
            }, { __index = Button })
            button:_doFeedbackHighlight()
            assert.are.same(icon_dimen, inverted)
            assert.are.equal(inverted, refreshed)
            assert.are.equal(dimen, button.dimen)
            button:_undoFeedbackHighlight(false)
            assert.are.same(icon_dimen, refreshed)
        end
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

    it("keeps text-button feedback inside its bounds and restores vsync and translucent buttons", function()
        screen.bb = Blitbuffer.new(80, 60, Blitbuffer.TYPE_BB8)
        screen.bb:fill(Blitbuffer.Color8(32))
        Button.paintTo = function(self)
            local d = self.dimen
            screen.bb:paintRect(d.x, d.y, d.w, d.h, Blitbuffer.Color8(32))
        end
        require("modules/global/patches/button_feedback")()
        for _i, vsync in ipairs({ false, true }) do
            local button = setmetatable({ dimen = { x = 20, y = 20, w = 32, h = 24 },
                text = "OK", bordersize = 1, vsync = vsync, enabled = true, show_parent = {},
            }, { __index = Button })
            button:_doFeedbackHighlight()
            assert.are.same(button.dimen, button._zen_feedback_region)
            assert.are.equal(223, screen.bb:getPixel(28, 28).a)
            for y = 0, 59 do
                for x = 0, 79 do
                    if x < 20 or x >= 52 or y < 20 or y >= 44 then
                        assert.are.equal(32, screen.bb:getPixel(x, y).a)
                    end
                end
            end
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
