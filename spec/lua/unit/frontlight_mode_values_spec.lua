describe("frontlight light/dark mode values", function()
    local original_plugin
    local dirty_calls

    before_each(function()
        original_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        _G.__ZEN_UI_BRIGHTNESS_SCHEDULE = nil
        _G.__ZEN_UI_WARMTH_SCHEDULE = nil
        dirty_calls = 0
    end)

    after_each(function()
        _G.__ZEN_UI_PLUGIN = original_plugin
        _G.__ZEN_UI_BRIGHTNESS_SCHEDULE = nil
        _G.__ZEN_UI_WARMTH_SCHEDULE = nil
        ZenSpec.unload("modules/global/patches/brightness_schedule")
        ZenSpec.unload("modules/global/patches/warmth_schedule")
        ZenSpec.unload("ui/uimanager")
        ZenSpec.unload("device")
    end)

    local function make_screen()
        return {
            night_mode = false,
            toggleNightMode = function(self)
                self.night_mode = not self.night_mode
            end,
        }
    end

    local function make_ui_manager()
        return {
            setDirty = function() dirty_calls = dirty_calls + 1 end,
            scheduleIn = function() end,
            unschedule = function() end,
            nextTick = function(_, callback) callback() end,
        }
    end

    it("applies brightness on mode changes while the time schedule is off", function()
        local screen = make_screen()
        local powerd = {
            fl_min = 0,
            fl_max = 100,
            is_on = true,
            values = {},
            setIntensity = function(self, value)
                self.values[#self.values + 1] = value
            end,
            isFrontlightOff = function(self) return not self.is_on end,
            turnOnFrontlight = function(self) self.is_on = true end,
            updateResumeFrontlightState = function() end,
        }
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { brightness_schedule = false },
                brightness_schedule = {
                    use_mode_values = true,
                    day_value = 42,
                    night_value = 7,
                },
            },
        }
        ZenSpec.replace("device", { screen = screen, powerd = powerd })
        ZenSpec.replace("ui/uimanager", make_ui_manager())

        require("modules/global/patches/brightness_schedule")()
        assert.are.same({ 42 }, powerd.values)

        screen:toggleNightMode()
        assert.are.same({ 42, 7 }, powerd.values)
        assert.are.equal(0, dirty_calls)
    end)

    it("lets a mode brightness of zero turn the frontlight off", function()
        local screen = make_screen()
        local powerd = {
            fl_min = 0,
            fl_max = 100,
            is_on = true,
            turnOffFrontlight = function(self)
                self.is_on = false
                self.off_calls = (self.off_calls or 0) + 1
            end,
            setIntensity = function(self, value) self.value = value end,
            isFrontlightOff = function(self) return not self.is_on end,
            turnOnFrontlight = function(self) self.is_on = true end,
            updateResumeFrontlightState = function() end,
        }
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { brightness_schedule = false },
                brightness_schedule = {
                    use_mode_values = true,
                    day_value = 0,
                    night_value = 5,
                },
            },
        }
        ZenSpec.replace("device", { screen = screen, powerd = powerd })
        ZenSpec.replace("ui/uimanager", make_ui_manager())

        require("modules/global/patches/brightness_schedule")()
        assert.are.equal(1, powerd.off_calls)
        assert.is_false(powerd.is_on)

        screen:toggleNightMode()
        assert.are.equal(5, powerd.value)
        assert.is_true(powerd.is_on)
    end)

    it("keeps time-based brightness authoritative when its schedule is on", function()
        local screen = make_screen()
        local now = os.date("*t")
        local night = (now.hour * 60 + now.min + 1) % 1440
        local powerd = {
            fl_min = 0,
            fl_max = 100,
            is_on = true,
            values = {},
            setIntensity = function(self, value)
                self.values[#self.values + 1] = value
            end,
            isFrontlightOff = function(self) return not self.is_on end,
            updateResumeFrontlightState = function() end,
        }
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { brightness_schedule = true },
                brightness_schedule = {
                    day_h = now.hour,
                    day_m = now.min,
                    day_value = 31,
                    night_h = math.floor(night / 60),
                    night_m = night % 60,
                    night_value = 9,
                    use_mode_values = true,
                },
            },
        }
        ZenSpec.replace("device", { screen = screen, powerd = powerd })
        ZenSpec.replace("ui/uimanager", make_ui_manager())

        require("modules/global/patches/brightness_schedule")()
        assert.are.same({ 31 }, powerd.values)

        screen:toggleNightMode()
        assert.are.same({ 31 }, powerd.values)
    end)

    it("force reapplies scheduled brightness when the cached value matches", function()
        local screen = make_screen()
        local now = os.date("*t")
        local powerd = {
            fl_min = 0,
            fl_max = 100,
            fl_intensity = 40,
            hardware_intensity = 40,
            is_on = true,
            setIntensity = function(self, value)
                if value == self.fl_intensity then return false end
                self.fl_intensity = value
                self.hardware_intensity = value
                return true
            end,
            setIntensityHW = function(self, value)
                self.hardware_intensity = value
            end,
            isFrontlightOff = function(self) return not self.is_on end,
            updateResumeFrontlightState = function() end,
        }
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { brightness_schedule = true },
                brightness_schedule = {
                    day_h = (now.hour + 1) % 24,
                    day_m = 0,
                    day_value = 40,
                    night_h = now.hour,
                    night_m = 0,
                    night_value = 7,
                },
            },
        }
        ZenSpec.replace("device", { screen = screen, powerd = powerd })
        ZenSpec.replace("ui/uimanager", make_ui_manager())

        require("modules/global/patches/brightness_schedule")()
        assert.are.equal(7, powerd.hardware_intensity)

        powerd.hardware_intensity = 40
        _G.__ZEN_UI_BRIGHTNESS_SCHEDULE.force_reschedule()
        assert.are.equal(7, powerd.hardware_intensity)
    end)

    it("applies warmth on mode changes while the time schedule is off", function()
        local screen = make_screen()
        local powerd = {
            fl_warmth_min = 0,
            fl_warmth_max = 24,
            values = {},
            fromNativeWarmth = function(_, value) return value * 10 end,
            setWarmth = function(self, value)
                self.values[#self.values + 1] = value
            end,
        }
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { warmth_schedule = false },
                warmth_schedule = {
                    use_mode_values = true,
                    day_value = 3,
                    night_value = 8,
                },
            },
        }
        ZenSpec.replace("device", { screen = screen, powerd = powerd })
        ZenSpec.replace("ui/uimanager", make_ui_manager())

        require("modules/global/patches/warmth_schedule")()
        assert.are.same({ 30 }, powerd.values)

        screen:toggleNightMode()
        assert.are.same({ 30, 80 }, powerd.values)
        assert.are.equal(0, dirty_calls)
    end)

    it("force reapplies scheduled warmth when the cached value matches", function()
        local screen = make_screen()
        local now = os.date("*t")
        local powerd = {
            fl_warmth_min = 0,
            fl_warmth_max = 24,
            fl_warmth = 30,
            hardware_warmth = 30,
            fromNativeWarmth = function(_, value) return value * 10 end,
            setWarmth = function(self, value, force)
                if not force and value == self.fl_warmth then return false end
                self.fl_warmth = value
                self.hardware_warmth = value
                return true
            end,
        }
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { warmth_schedule = true },
                warmth_schedule = {
                    day_h = (now.hour + 1) % 24,
                    day_m = 0,
                    day_value = 3,
                    night_h = now.hour,
                    night_m = 0,
                    night_value = 8,
                },
            },
        }
        ZenSpec.replace("device", { screen = screen, powerd = powerd })
        ZenSpec.replace("ui/uimanager", make_ui_manager())

        require("modules/global/patches/warmth_schedule")()
        assert.are.equal(80, powerd.hardware_warmth)

        powerd.hardware_warmth = 30
        _G.__ZEN_UI_WARMTH_SCHEDULE.force_reschedule()
        assert.are.equal(80, powerd.hardware_warmth)
    end)

    it("does nothing when both automatic brightness modes are disabled", function()
        local screen = make_screen()
        local powerd = {
            fl_min = 0,
            fl_max = 100,
            setIntensity = function(self)
                self.calls = (self.calls or 0) + 1
            end,
        }
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { brightness_schedule = false },
                brightness_schedule = { use_mode_values = false },
            },
        }
        ZenSpec.replace("device", { screen = screen, powerd = powerd })
        ZenSpec.replace("ui/uimanager", make_ui_manager())

        require("modules/global/patches/brightness_schedule")()
        screen:toggleNightMode()
        assert.is_nil(powerd.calls)
    end)
end)
