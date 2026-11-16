describe("night mode schedule", function()
    local plugin
    local ui_manager
    local screen
    local device
    local ReaderUI
    local ReaderThemes

    before_each(function()
        _G.G_reader_settings = ZenSpec.memorySettings()
        _G.__ZEN_UI_NIGHT_SCHEDULE = nil
        _G.__ZEN_UI_BRIGHTNESS_SCHEDULE = {
            apply_mode_value = function()
                _G.brightness_mode_reapplies = (_G.brightness_mode_reapplies or 0) + 1
            end,
        }
        _G.__ZEN_UI_WARMTH_SCHEDULE = {
            apply_mode_value = function()
                _G.warmth_mode_reapplies = (_G.warmth_mode_reapplies or 0) + 1
            end,
        }
        _G.brightness_mode_reapplies = nil
        _G.warmth_mode_reapplies = nil
        local now = os.date("*t")
        local night_off = (now.hour * 60 + now.min + 1) % 1440
        plugin = {
            config = {
                features = { night_mode_schedule = true, reader_themes = true },
                night_mode_schedule = {
                    night_on_h = now.hour,
                    night_on_m = now.min,
                    night_off_h = math.floor(night_off / 60),
                    night_off_m = night_off % 60,
                },
                reader_themes = { dark_mode = "dark_warm_gray" },
            },
        }
        _G.__ZEN_UI_PLUGIN = plugin
        ui_manager = {
            setDirty = function() end,
            scheduleIn = function() end,
            unschedule = function() end,
            nextTick = function(_, callback) callback() end,
        }
        screen = {
            night_mode = false,
            setHWNightmode = function(self, enabled)
                self.hw_night_mode = enabled
            end,
        }
        device = { screen = screen, canHWInvert = function() return true end }
        screen.device = device
        screen.toggleNightMode = require("ffi/framebuffer").toggleNightMode
        ReaderUI = { instance = nil }
        ReaderThemes = {
            isEnabled = function()
                return true
            end,
            applyCurrent = function()
                ReaderThemes.applied = (ReaderThemes.applied or 0) + 1
            end,
        }
        ZenSpec.replace("ui/uimanager", ui_manager)
        ZenSpec.replace("device", device)
        ZenSpec.replace("apps/reader/readerui", ReaderUI)
        ZenSpec.replace("common/reader_themes", ReaderThemes)
        ZenSpec.unload("modules/global/patches/night_mode_schedule")
    end)

    after_each(function()
        _G.__ZEN_UI_NIGHT_SCHEDULE = nil
        _G.__ZEN_UI_BRIGHTNESS_SCHEDULE = nil
        _G.__ZEN_UI_WARMTH_SCHEDULE = nil
        _G.brightness_mode_reapplies = nil
        _G.warmth_mode_reapplies = nil
        _G.__ZEN_UI_PLUGIN = nil
    end)

    it("keeps hardware inversion on for an open themed reader", function()
        ReaderUI.instance = { document = {} }
        assert.is_nil(require("modules/global/patches/night_mode_schedule")())

        assert.is_true(G_reader_settings:isTrue("night_mode"))
        assert.is_true(screen.night_mode)
        assert.is_true(screen.hw_night_mode)
        assert.are.equal(1, ReaderThemes.applied)
        assert.are.equal(1, _G.brightness_mode_reapplies)
        assert.are.equal(1, _G.warmth_mode_reapplies)
    end)

    it("inverts the file manager at night", function()
        assert.is_nil(require("modules/global/patches/night_mode_schedule")())

        assert.is_true(G_reader_settings:isTrue("night_mode"))
        assert.is_true(screen.night_mode)
        assert.is_true(screen.hw_night_mode)
        assert.are.equal(1, ReaderThemes.applied)
        assert.are.equal(1, _G.brightness_mode_reapplies)
        assert.are.equal(1, _G.warmth_mode_reapplies)
    end)

    it("inverts the software framebuffer and preserves cover colors", function()
        ZenSpec.unload("ffi/blitbuffer")
        local Blitbuffer = require("ffi/blitbuffer")
        device.canHWInvert = function() return false end
        screen.bb = Blitbuffer.new(2, 2, Blitbuffer.TYPE_BBRGB32)
        screen.bb:fill(Blitbuffer.COLOR_WHITE)

        require("modules/global/patches/night_mode_schedule")()

        assert.is_true(screen.night_mode)
        assert.are.equal(1, screen.bb:getInverse())
        screen.bb:fill(Blitbuffer.COLOR_WHITE)
        assert.are.equal(0, tonumber(screen.bb.data[0].r))
        _G.__ZEN_UI_NIGHT_SCHEDULE.force_reschedule()
        assert.are.equal(1, screen.bb:getInverse())

        local cover = Blitbuffer.new(1, 1, Blitbuffer.TYPE_BBRGB32)
        cover:setPixel(0, 0, Blitbuffer.ColorRGB32(220, 40, 20, 255))
        screen.bb:blitFrom(cover, 0, 0, 0, 0, 1, 1)
        screen.bb:invertRect(0, 0, 1, 1)
        assert.are.same({ 220, 40, 20 }, {
            tonumber(screen.bb.data[0].r), tonumber(screen.bb.data[0].g),
            tonumber(screen.bb.data[0].b),
        })

        plugin.config.night_mode_schedule.night_off_h = plugin.config.night_mode_schedule.night_on_h
        plugin.config.night_mode_schedule.night_off_m = plugin.config.night_mode_schedule.night_on_m
        _G.__ZEN_UI_NIGHT_SCHEDULE.reschedule()
        assert.is_false(screen.night_mode)
        assert.are.equal(0, screen.bb:getInverse())
        cover:free()
        screen.bb:free()
    end)

    it("restores hardware inversion on wake without restyling an unchanged reader", function()
        ReaderUI.instance = { document = {} }
        require("modules/global/patches/night_mode_schedule")()
        screen.hw_night_mode = false

        _G.__ZEN_UI_NIGHT_SCHEDULE.force_reschedule()

        assert.is_true(screen.hw_night_mode)
        assert.are.equal(1, ReaderThemes.applied)
        assert.are.equal(2, _G.brightness_mode_reapplies)
        assert.are.equal(2, _G.warmth_mode_reapplies)

        screen.night_mode = false
        G_reader_settings:saveSetting("night_mode", false)
        _G.__ZEN_UI_NIGHT_SCHEDULE.force_reschedule()

        assert.is_true(screen.night_mode)
        assert.is_true(G_reader_settings:isTrue("night_mode"))
        assert.are.equal(2, ReaderThemes.applied)
    end)

    it("skips the wake flash and frontlight rewrite when the hardware flag still matches", function()
        local dirty = 0
        ui_manager.setDirty = function() dirty = dirty + 1 end
        screen.getHWNightmode = function(self) return self.hw_night_mode == true end
        require("modules/global/patches/night_mode_schedule")()
        local writes = 0
        screen.setHWNightmode = function(self, enabled)
            writes = writes + 1
            self.hw_night_mode = enabled
        end
        dirty = 0

        _G.__ZEN_UI_NIGHT_SCHEDULE.force_reschedule()

        assert.are.equal(0, dirty)
        assert.are.equal(0, writes)
        assert.are.equal(1, _G.brightness_mode_reapplies)

        screen.hw_night_mode = false
        _G.__ZEN_UI_NIGHT_SCHEDULE.force_reschedule()

        assert.are.equal(1, dirty)
        assert.are.equal(1, writes)
        assert.is_true(screen.hw_night_mode)
        assert.are.equal(1, ReaderThemes.applied)
    end)
end)
