describe("frontlight slider minus hold", function()
    local replaced_modules = {
        "ffi/blitbuffer",
        "ui/widget/button",
        "ui/widget/container/centercontainer",
        "device",
        "ui/geometry",
        "ui/widget/horizontalgroup",
        "ui/widget/horizontalspan",
        "ui/widget/container/leftcontainer",
        "ui/widget/textwidget",
        "ui/uimanager",
        "ui/widget/verticalgroup",
        "ui/widget/verticalspan",
        "common/ui/zen_slider",
        "modules/filebrowser/patches/library_font",
        "gettext",
    }

    local function widget_class(methods)
        return {
            new = function(_, opts)
                return setmetatable(opts or {}, { __index = methods or {} })
            end,
        }
    end

    before_each(function()
        local text_methods = {
            getSize = function(self) return { w = #(self.text or "") * 10, h = 20 } end,
            free = function() end,
            setText = function(self, text) self.text = text end,
            paintTo = function() end,
        }
        ZenSpec.replace("ffi/blitbuffer", { COLOR_WHITE = 0 })
        ZenSpec.replace("ui/widget/button", widget_class({}))
        ZenSpec.replace("ui/widget/container/centercontainer", widget_class({}))
        ZenSpec.replace("ui/geometry", widget_class({}))
        ZenSpec.replace("ui/widget/horizontalgroup", widget_class({}))
        ZenSpec.replace("ui/widget/horizontalspan", widget_class({}))
        ZenSpec.replace("ui/widget/container/leftcontainer", widget_class({}))
        ZenSpec.replace("ui/widget/textwidget", widget_class(text_methods))
        ZenSpec.replace("ui/widget/verticalgroup", widget_class({}))
        ZenSpec.replace("ui/widget/verticalspan", widget_class({}))
        ZenSpec.replace("ui/uimanager", {
            setDirty = function() end,
            unschedule = function() end,
        })
        ZenSpec.replace("device", {
            screen = {
                bb = {},
                scaleBySize = function(_, value) return value end,
            },
        })
        ZenSpec.replace("common/ui/zen_slider", widget_class({
            getSize = function() return { w = 300, h = 40 } end,
            setValue = function(self, value) self.value = value end,
        }))
        ZenSpec.replace("modules/filebrowser/patches/library_font", {
            getFontName = function() return "ffont" end,
        })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.unload("modules/menu/patches/brightness_slider")
        ZenSpec.unload("modules/menu/patches/warmth_slider")
    end)

    after_each(function()
        ZenSpec.unload("modules/menu/patches/brightness_slider")
        ZenSpec.unload("modules/menu/patches/warmth_slider")
        for _i, name in ipairs(replaced_modules) do ZenSpec.unload(name) end
    end)

    local function slider_opts(powerd)
        return {
            inner_width = 500,
            slider_width = 300,
            small_btn_width = 50,
            slider_gap = 10,
            medium_font = {},
            small_btn_size = 14,
            powerd = powerd,
            refs = { sliders = {} },
        }
    end

    local function touch_menu()
        return {
            show_parent = {},
            dimen = { x = 0, y = 0, w = 600, h = 800 },
        }
    end

    it("restores the last brightness after turning the frontlight off", function()
        local powerd = {
            fl_min = 0,
            fl_max = 100,
            intensity = 40,
            is_on = true,
            frontlightIntensity = function(self) return self.intensity end,
            setIntensity = function(self, value) self.intensity = value end,
            turnOffFrontlight = function(self)
                self.intensity = 0
                self.is_on = false
            end,
            isFrontlightOff = function(self) return not self.is_on end,
            turnOnFrontlight = function(self) self.is_on = true end,
            updateResumeFrontlightState = function(self)
                self.resume_state_updates = (self.resume_state_updates or 0) + 1
            end,
        }
        local opts = slider_opts(powerd)

        local group = require("modules/menu/patches/brightness_slider")(touch_menu(), opts)
        group[4][1].hold_callback()

        assert.are.equal(0, opts.refs.fl_state.cur)
        assert.are.equal(0, powerd.intensity)
        assert.is_false(powerd.is_on)
        assert.are.equal(1, powerd.resume_state_updates)

        group[4][5].callback()
        assert.are.equal(40, powerd.intensity)
        assert.is_true(powerd.is_on)
        assert.are.equal(2, powerd.resume_state_updates)

        opts.refs.setBrightness(25)
        opts.refs.fl_progress.on_drag_start()
        for value = 24, 0, -1 do opts.refs.fl_progress.on_change(value) end
        opts.refs.fl_progress.on_drag_end()
        group[4][5].callback()
        assert.are.equal(25, powerd.intensity)
    end)

    it("sets warmth to zero", function()
        local powerd = {
            fl_warmth_min = 0,
            fl_warmth_max = 24,
            warmth = 9,
            frontlightWarmth = function(self) return self.warmth end,
            toNativeWarmth = function(_, value) return value end,
            fromNativeWarmth = function(_, value) return value end,
            setWarmth = function(self, value) self.warmth = value end,
        }
        local opts = slider_opts(powerd)

        local group = require("modules/menu/patches/warmth_slider")(touch_menu(), opts)
        group[4][1].hold_callback()

        assert.are.equal(0, opts.refs.nl_state.cur)
        assert.are.equal(0, powerd.warmth)
    end)
end)
