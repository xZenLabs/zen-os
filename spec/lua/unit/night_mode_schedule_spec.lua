describe("night mode schedule", function()
    local plugin
    local ui_manager
    local screen
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
        ZenSpec.replace("device", { screen = screen })
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
end)
