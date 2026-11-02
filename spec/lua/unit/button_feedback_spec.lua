require("ffi/loadlib")

describe("rounded button feedback", function()
    local originals, settings, plugin, Feedback, screen, UIManager, Button, IconButton, mirrored, logs
    local Blitbuffer = require("ffi/blitbuffer")
    local Geom = require("ui/geometry")
    local modules = {
        "ffi", "ffi/framebuffer_mxcfb",
        "device", "ui/uimanager", "ui/widget/button", "ui/widget/iconbutton", "ui/bidi",
        "common/ui/button_feedback", "modules/global/patches/button_feedback", "common/zen_logger",
    }

    before_each(function()
        originals, settings, logs = {}, _G.G_reader_settings, {}
        plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        _G.__ZEN_UI_PLUGIN = nil
        for _i, name in ipairs(modules) do originals[name] = package.loaded[name] or false end
        _G.G_reader_settings = { isFalse = function() return false end }
        screen = {
            scaleBySize = function(_self, size) return size end,
            isColorScreen = function() return false end,
            calculateRealCoordinates = function(_self, x, y, w, h) return x, y, w, h end,
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
        _G.__ZEN_UI_PLUGIN = plugin
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

    it("flashes the accent with contrasting glyphs and restores every original pixel", function()
        _G.__ZEN_UI_PLUGIN = { config = { accent_color = "#204080" } }
        screen.isColorScreen = function() return true end
        screen.bb = Blitbuffer.new(64, 64, Blitbuffer.TYPE_BBRGB32)
        screen.bb:fill(Blitbuffer.COLOR_WHITE)
        screen.bb:paintRect(30, 30, 4, 4, Blitbuffer.COLOR_BLACK)
        local before = screen.bb:copy()
        local modes = {}
        UIManager.setDirty = function(_self, _owner, mode) modes[#modes + 1] = mode end
        UIManager.yieldToEPDC = function()
            assert.are.equal(tostring(Blitbuffer.ColorRGB32(32, 64, 128, 255)),
                tostring(screen.bb:getPixel(36, 36)))
            assert.are.equal(255, screen.bb:getPixel(31, 31):getColor8().a)
            assert.are.equal(255, screen.bb:getPixel(20, 20):getColor8().a)
        end
        Feedback.flash({ x = 20, y = 20, w = 32, h = 32 }, 16)
        assert.are.same({ "ui", "ui" }, modes)
        for y = 0, 63 do
            for x = 0, 63 do
                assert.are.equal(tostring(before:getPixel(x, y)), tostring(screen.bb:getPixel(x, y)))
            end
        end
        before:free()
    end)

    it("uses consistent Colorsoft processing for the first frame and colored feedback", function()
        _G.__ZEN_UI_PLUGIN = { config = { accent_color = "#204080" } }
        local Device = package.loaded.device
        Device.isKindle = function() return true end
        Device.hasColorScreen = function() return true end
        Device.canHWDither = function() return true end
        Device.hasKaleidoWfm = function() return false end
        screen.isColorScreen = function() return true end
        screen.waveform_fast, screen.waveform_ui, screen.waveform_full = 1, 257, 2
        screen.waveform_partial, screen.waveform_reagl, screen.waveform_flashui = 4, 4, 257
        screen.debug = function() end
        screen.bb = Blitbuffer.new(80, 80, Blitbuffer.TYPE_BBRGB32)
        screen.bb:fill(Blitbuffer.COLOR_WHITE)
        screen.bb:paintRect(30, 30, 4, 4, Blitbuffer.COLOR_BLACK)
        local before = screen.bb:copy()
        local region = Geom:new{ x = 20, y = 20, w = 32, h = 32 }
        local pending, refreshes = nil, 0
        local ffi = require("ffi")
        require("ffi/mxcfb_kindle_h")
        local native = ffi.C
        local backend = setmetatable({
            ioctl = function(_fd, request, update)
                assert.are.equal(native.MXCFB_SEND_UPDATE_MTK, request)
                assert.are.equal(refreshes == 0 and native.UPDATE_MODE_FULL or native.UPDATE_MODE_PARTIAL,
                    tonumber(update.update_mode))
                assert.are.equal(native.MTK_WAVEFORM_MODE_GC16, tonumber(update.waveform_mode))
                assert.are.equal(0, tonumber(update.flags))
                local rect = update.update_region
                assert.are.same(refreshes == 0 and { 0, 0, 80, 80 } or { region.x, region.y, region.w, region.h },
                    { tonumber(rect.left), tonumber(rect.top), tonumber(rect.width), tonumber(rect.height) })
                assert.are.equal(tostring(before:getPixel(20, 20)), tostring(screen.bb:getPixel(20, 20)))
                refreshes = refreshes + 1
                return 0
            end,
        }, { __index = native })
        ZenSpec.replace("ffi", setmetatable({ C = backend }, { __index = ffi }))
        ZenSpec.unload("ffi/framebuffer_mxcfb")
        local Framebuffer = require("ffi/framebuffer_mxcfb")
        setmetatable(screen, { __index = Framebuffer })
        screen.device = Device
        screen.update_data = ffi.new("struct mxcfb_update_data_mtk")
        for index = 1, 64 do
            local name, value = debug.getupvalue(Framebuffer.init, index)
            if name == "refresh_mtk" then screen.mech_refresh = value break end
            if name == nil then break end
        end
        assert.is_function(screen.mech_refresh)
        UIManager.setDirty = function(_self, _owner, mode, refreshed)
            assert.are.equal("ui", mode)
            pending = refreshed
        end
        UIManager.forceRePaint = function()
            if not pending then return end
            screen:refreshUI(pending.x, pending.y, pending.w, pending.h, true)
            pending = nil
        end
        UIManager.yieldToEPDC = function()
            assert.are.equal(tostring(Blitbuffer.ColorRGB32(32, 64, 128, 255)),
                tostring(screen.bb:getPixel(36, 36)))
            assert.are.equal(255, screen.bb:getPixel(31, 31):getColor8().a)
        end
        require("modules/global/patches/button_feedback")()

        screen:refreshFullImp(0, 0, 80, 80, false)
        Feedback.flash(region, 16)
        UIManager:forceRePaint()
        local icon = setmetatable({
            dimen = { x = 16, y = 16, w = 40, h = 40 }, width = 24, height = 24,
            padding_left = 8, padding_top = 8, callback = function() end,
        }, { __index = IconButton })
        assert.is_true(icon:onTapIconButton())

        local button = setmetatable({ dimen = region }, { __index = Button })
        button:_doFeedbackHighlight()
        UIManager:forceRePaint()
        button:_undoFeedbackHighlight(false)
        UIManager:forceRePaint()

        assert.are.equal(7, refreshes)
        assert.are.equal(257, screen.waveform_ui)
        for y = 0, 79 do
            for x = 0, 79 do
                assert.are.equal(tostring(before:getPixel(x, y)), tostring(screen.bb:getPixel(x, y)))
            end
        end
        before:free()
    end)

    it("keeps colored feedback on color devices in light and night mode", function()
        _G.__ZEN_UI_PLUGIN = { config = { accent_color = "#204080" } }
        local kindle = true
        package.loaded.device.isKindle = function() return kindle end
        screen.isColorScreen = function() return true end
        screen.bb = Blitbuffer.new(64, 64, Blitbuffer.TYPE_BBRGB32)
        screen.bb:fill(Blitbuffer.COLOR_WHITE)
        local Accent = require("common/ui/accent")
        local region = { x = 20, y = 20, w = 32, h = 32 }
        for _i, case in ipairs({ { true, false }, { true, true }, { false, false }, { false, true } }) do
            kindle, screen.night_mode = case[1], case[2]
            local saved = Feedback.highlight(region, 16)
            assert.are.equal(tostring(Accent.color()), tostring(screen.bb:getPixel(36, 36)))
            assert.are.equal(255, screen.bb:getPixel(20, 20):getColor8().a)
            Feedback.restore(region, saved, 16)
            assert.are.equal(255, screen.bb:getPixel(36, 36):getColor8().a)
        end
        _G.__ZEN_UI_PLUGIN.config.accent_enabled = false
        local saved = Feedback.highlight(region, 16)
        assert.is_nil(saved)
        assert.are.equal(0, screen.bb:getPixel(36, 36):getColor8().a)
        Feedback.restore(region, saved, 16)
        assert.are.equal(255, screen.bb:getPixel(36, 36):getColor8().a)
    end)

    it("preserves stock UI waveforms and dithering on monochrome devices", function()
        screen.waveform_ui, screen.waveform_full = 257, 2
        screen.mech_refresh = function() error("monochrome UI must use the stock waveform") end
        local expected, calls
        screen.refreshUI = function(_self, ...)
            assert.are.same(expected, { ... })
            calls = calls + 1
            return "stock"
        end
        require("modules/global/patches/button_feedback")()

        calls = 0
        for _i, device in ipairs({ { false, false }, { true, false }, { false, true } }) do
            package.loaded.device.isKindle = function() return device[1] end
            package.loaded.device.isSunxi = function() return device[2] end
            for _j, region in ipairs({ { 0, 0, 80, 60, true }, { 10, 20, 30, 40, false } }) do
                expected = region
                assert.are.equal("stock", screen:refreshUI(unpack(region)))
            end
        end
        assert.are.equal(6, calls)
    end)

    it("uses non-flashing grayscale updates on color screens for both framebuffer APIs", function()
        screen.isColorScreen = function() return true end
        screen.waveform_ui, screen.waveform_full = 257, 2
        screen.bb = Blitbuffer.new(80, 60, Blitbuffer.TYPE_BB8)
        screen.bb:fill(Blitbuffer.Color8(32))
        screen.refreshUI = function() error("feedback must bypass AUTO") end
        local region = { x = 20, y = 20, w = 32, h = 24 }
        local pending, refreshes = nil, 0
        UIManager.setDirty = function(_self, _owner, mode, refreshed)
            assert.are.equal("ui", mode)
            pending = refreshed
        end
        UIManager.forceRePaint = function()
            if not pending then return end
            screen:refreshUI(pending.x, pending.y, pending.w, pending.h, true)
            pending = nil
        end
        require("modules/global/patches/button_feedback")()

        for _i, sunxi in ipairs({ false, true }) do
            package.loaded.device.isSunxi = function() return sunxi end
            screen.mech_refresh = function(_self, ...)
                assert.are.same(sunxi and { false, false, 2, 20, 20, 32, 24, false }
                    or { false, 2, 20, 20, 32, 24, false }, { ... })
                assert.are.equal(32, screen.bb:getPixel(20, 20).a)
                assert.are.equal(refreshes % 2 == 0 and 223 or 32, screen.bb:getPixel(28, 28).a)
                refreshes = refreshes + 1
            end
            Feedback.flash(region)
            UIManager:forceRePaint()
            local button = setmetatable({ dimen = region, icon = "chevron.left" }, { __index = Button })
            button:_doFeedbackHighlight()
            UIManager:forceRePaint()
            button:_undoFeedbackHighlight(false)
            UIManager:forceRePaint()
        end
        assert.are.equal(8, refreshes)
        assert.are.equal(257, screen.waveform_ui)
    end)

    it("preserves stock UI refreshes at night or without direct waveform support", function()
        screen.isColorScreen = function() return true end
        screen.waveform_ui, screen.waveform_full = 257, 2
        screen.mech_refresh = function() error("must preserve the stock refresh") end
        local calls = 0
        screen.refreshUI = function(_self, ...)
            assert.are.same({ 10, 20, 30, 40, true }, { ... })
            calls = calls + 1
            return "stock"
        end
        require("modules/global/patches/button_feedback")()

        -- Non-feedback UI refreshes keep the stock (AUTO) waveform on color screens.
        assert.are.equal("stock", screen:refreshUI(10, 20, 30, 40, true))
        Feedback.markRegion({ x = 10, y = 20, w = 30, h = 40 })
        screen.night_mode = true
        assert.are.equal("stock", screen:refreshUI(10, 20, 30, 40, true))
        screen.night_mode = false
        screen.waveform_full = nil
        assert.are.equal("stock", screen:refreshUI(10, 20, 30, 40, true))
        screen.waveform_full, screen.mech_refresh = 2, nil
        assert.are.equal("stock", screen:refreshUI(10, 20, 30, 40, true))
        assert.are.equal(4, calls)
    end)

    it("clips colored feedback snapshots at screen edges and restores rotated buffers", function()
        _G.__ZEN_UI_PLUGIN = { config = { accent_color = "#FFFF80" } }
        screen.isColorScreen = function() return true end
        screen.bb = Blitbuffer.new(48, 64, Blitbuffer.TYPE_BBRGB32)
        screen.bb:setRotation(1)
        screen.bb:fill(Blitbuffer.COLOR_WHITE)
        local region = { x = -8, y = -8, w = 32, h = 32 }
        local saved = Feedback.highlight(region)
        assert.are.equal(0, saved.x)
        assert.are.equal(24, saved.bb:getWidth())
        assert.are.equal(tostring(Blitbuffer.ColorRGB32(255, 255, 128, 255)),
            tostring(screen.bb:getPixel(10, 10)))
        Feedback.restore(region, saved)
        assert.are.equal(255, screen.bb:getPixel(10, 10):getColor8().a)
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

    it("merges custom button feedback with a subsequent fullscreen refresh", function()
        screen.bb = Blitbuffer.new(80, 60, Blitbuffer.TYPE_BB8)
        screen.bb:fill(Blitbuffer.Color8(32))
        local region = { x = 20, y = 20, w = 32, h = 24 }
        local fullscreen = Geom:new{ x = 0, y = 0, w = 80, h = 60 }
        local refreshes = 0
        UIManager.setDirty = function(_self, owner, mode, refreshed)
            assert.is_nil(owner)
            assert.are.equal(refreshes % 2 == 0 and "fast" or "ui", mode)
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

    it("uses fast monochrome feedback and UI color feedback in light mode", function()
        screen.bb = Blitbuffer.new(80, 60, Blitbuffer.TYPE_BB8)
        screen.bb:fill(Blitbuffer.Color8(32))
        require("modules/global/patches/button_feedback")()
        local region = { x = 20, y = 20, w = 32, h = 24 }
        local button = setmetatable({ dimen = region, enabled = true }, { __index = Button })
        for _i, case in ipairs({
            { false, false, false }, { false, false, true },
            { false, true, false }, { false, true, true },
            { true, false, false }, { true, false, true },
            { true, true, false }, { true, true, true },
        }) do
            package.loaded.device.isKindle = function() return case[1] end
            screen.night_mode = case[2]
            screen.isColorScreen = function() return case[3] end
            local highlight_mode = case[3] and not case[2] and "ui" or "fast"
            local modes = {}
            local expected_region = region
            UIManager.setDirty = function(_self, owner, mode, refreshed)
                assert.is_nil(owner)
                assert.are.same(expected_region, refreshed)
                modes[#modes + 1] = mode
            end
            Feedback.flash(region)
            assert.are.same({ highlight_mode, "ui" }, modes)
            assert.are.equal(32, screen.bb:getPixel(28, 28).a)

            modes = {}
            button:_doFeedbackHighlight()
            button:_undoFeedbackHighlight(false)
            assert.are.same({ highlight_mode, "ui" }, modes)
            assert.are.equal(32, screen.bb:getPixel(28, 28).a)
        end
    end)

    it("waits once per pending frame on monochrome and color screens without waiting for completion", function()
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
        for _i, color in ipairs({ false, true }) do
            screen.isColorScreen = function() return color end
            for _j, mtk in ipairs({ false, true }) do
                package.loaded.device.isMTK = function() return mtk end
                for _k, result in ipairs({ 0, 25 }) do
                    submission_result = result
                    Feedback.flash(region)
                    button:_doFeedbackHighlight()
                    UIManager:forceRePaint()
                    button:_undoFeedbackHighlight(false)
                end
            end
        end
        assert.are.same({ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17 }, submitted)
        assert.are.same({}, logs)
    end)

    it("waits again when the framebuffer is replaced or the marker wraps", function()
        screen.bb = Blitbuffer.new(48, 48, Blitbuffer.TYPE_BB8)
        screen.marker = 1
        local submitted = {}
        screen.mech_wait_update_submission = function(_self, marker)
            submitted[#submitted + 1] = marker
            return 0
        end
        local region = { x = 20, y = 20, w = 24, h = 24 }
        Feedback.invert(region)
        Feedback.invert(region)
        screen.bb:free()
        screen.bb = Blitbuffer.new(48, 48, Blitbuffer.TYPE_BB8)
        Feedback.invert(region)
        screen.marker = 4294967295
        Feedback.invert(region)
        screen.marker = 1
        Feedback.invert(region)
        assert.are.same({ 1, 1, 4294967295, 1 }, submitted)
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

    it("submits the accent highlight before restoring pixels and opening the next screen", function()
        _G.__ZEN_UI_PLUGIN = { config = { accent_color = "#204080" } }
        screen.isColorScreen = function() return true end
        screen.bb = Blitbuffer.new(48, 48, Blitbuffer.TYPE_BBRGB32)
        screen.bb:fill(Blitbuffer.COLOR_WHITE)
        screen.marker = 1
        local frames = {}
        screen.mech_wait_update_submission = function(_self, marker)
            if not frames[marker] then
                frames[marker] = tostring(screen.bb:getPixel(28, 28))
            end
            return 0
        end
        UIManager.forceRePaint = function()
            screen:mech_wait_update_submission(screen.marker)
            screen.marker = screen.marker + 1
        end

        Feedback.flash({ x = 20, y = 20, w = 24, h = 24 })
        screen.bb:fill(Blitbuffer.COLOR_BLACK)
        UIManager:forceRePaint()

        assert.are.equal(tostring(Blitbuffer.COLOR_WHITE:getColorRGB32()), frames[1])
        assert.are.equal(tostring(Blitbuffer.ColorRGB32(32, 64, 128, 255)), frames[2])
        assert.are.equal(tostring(Blitbuffer.COLOR_BLACK:getColorRGB32()), tostring(screen.bb:getPixel(28, 28)))
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

    it("restores colored text-button feedback after vsync repaint and translucent taps", function()
        _G.__ZEN_UI_PLUGIN = { config = { accent_color = "#204080" } }
        screen.isColorScreen = function() return true end
        screen.bb = Blitbuffer.new(80, 60, Blitbuffer.TYPE_BBRGB32)
        screen.bb:fill(Blitbuffer.COLOR_WHITE)
        Button.paintTo = function(self)
            local d = self.dimen
            screen.bb:paintRect(d.x, d.y, d.w, d.h, Blitbuffer.COLOR_WHITE)
        end
        require("modules/global/patches/button_feedback")()
        for _i, vsync in ipairs({ false, true }) do
            local button = setmetatable({ dimen = { x = 20, y = 20, w = 32, h = 24 },
                bordersize = 1, vsync = vsync, show_parent = {},
            }, { __index = Button })
            button:_doFeedbackHighlight()
            assert.are.equal(tostring(Blitbuffer.ColorRGB32(32, 64, 128, 255)),
                tostring(screen.bb:getPixel(28, 28)))
            if vsync then button:paintTo() end
            button:_undoFeedbackHighlight(true)
            assert.are.equal(255, screen.bb:getPixel(28, 28):getColor8().a)
            assert.is_nil(button._zen_feedback_pixels)
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
