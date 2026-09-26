describe("frontlight slider", function()
    local dirty_calls
    local replaced_modules = {
        "ffi/blitbuffer",
        "ui/widget/button",
        "ui/widget/container/centercontainer",
        "ui/widget/container/framecontainer",
        "device",
        "ui/geometry",
        "ui/widget/horizontalgroup",
        "ui/widget/horizontalspan",
        "ui/widget/container/leftcontainer",
        "ui/widget/iconwidget",
        "ui/widget/linewidget",
        "ui/widget/textwidget",
        "ui/uimanager",
        "ui/widget/verticalgroup",
        "ui/widget/verticalspan",
        "common/ui/zen_slider",
        "common/utils",
        "common/widget_resources",
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
        dirty_calls = {}
        local text_methods = {
            getSize = function(self) return { w = #(self.text or "") * 10, h = 20 } end,
            free = function() end,
            setText = function(self, text) self.text = text end,
            paintTo = function() end,
        }
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_WHITE = 0, COLOR_BLACK = 1, COLOR_DARK_GRAY = 2,
        })
        ZenSpec.replace("ui/widget/button", widget_class({}))
        ZenSpec.replace("ui/widget/container/centercontainer", widget_class({}))
        ZenSpec.replace("ui/widget/container/framecontainer", widget_class({
            getSize = function() return { w = 100, h = 30 } end,
        }))
        ZenSpec.replace("ui/geometry", widget_class({}))
        ZenSpec.replace("ui/widget/horizontalgroup", widget_class({
            getSize = function() return { w = 400, h = 40 } end,
        }))
        ZenSpec.replace("ui/widget/horizontalspan", widget_class({}))
        ZenSpec.replace("ui/widget/container/leftcontainer", widget_class({}))
        ZenSpec.replace("ui/widget/iconwidget", widget_class({}))
        ZenSpec.replace("ui/widget/linewidget", widget_class({}))
        ZenSpec.replace("ui/widget/textwidget", widget_class(text_methods))
        ZenSpec.replace("ui/widget/verticalgroup", widget_class({}))
        ZenSpec.replace("ui/widget/verticalspan", widget_class({}))
        ZenSpec.replace("ui/uimanager", {
            setDirty = function(_self, widget, mode, region)
                dirty_calls[#dirty_calls + 1] = { widget = widget, mode = mode, region = region }
            end,
            unschedule = function() end,
        })
        ZenSpec.replace("device", {
            screen = {
                bb = { paintRect = function(self, x, y)
                    self.last_paint_x, self.last_paint_y = x, y
                end },
                scaleBySize = function(_, value) return value end,
            },
        })
        ZenSpec.replace("common/ui/zen_slider", widget_class({
            getSize = function() return { w = 300, h = 40 } end,
            setValue = function(self, value) self.value = value end,
            paintTo = function() end,
        }))
        ZenSpec.replace("common/utils", {
            resolveLocalIcon = function(_dir, name) return "/tmp/zen-ui/icons/" .. name .. ".svg" end,
        })
        ZenSpec.replace("common/widget_resources", { paintFrameBorderOnTop = function() end })
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
            refs = { sliders = {}, toggles = {} },
        }
    end

    local function touch_menu()
        return {
            show_parent = {},
            dimen = { x = 0, y = 0, w = 600, h = 800 },
        }
    end

    local function find_widget(group, predicate)
        if predicate(group) then return group end
        for _i, child in ipairs(group) do
            if type(child) == "table" then
                local found = find_widget(child, predicate)
                if found then return found end
            end
        end
    end

    local function child_index(group, target)
        for index, child in ipairs(group) do
            if type(child) == "table" and find_widget(child, function(widget) return widget == target end) then
                return index
            end
        end
    end

    local function button(group, label)
        return assert(find_widget(group, function(widget) return widget.text == label end))
    end

    local function has_label(group, label)
        return find_widget(group, function(widget)
            return type(widget.text) == "string" and widget.text:find(label, 1, true) ~= nil
        end) ~= nil
    end

    local function power_device()
        return {
            fl_min = 0,
            fl_max = 100,
            fl_warmth_min = 0,
            fl_warmth_max = 24,
            intensity = 40,
            warmth = 9,
            is_on = true,
            brightness_writes = 0,
            warmth_writes = 0,
            frontlightIntensity = function(self) return self.intensity end,
            setIntensity = function(self, value)
                self.intensity = value
                self.brightness_writes = self.brightness_writes + 1
            end,
            turnOffFrontlight = function(self)
                self.intensity = 0
                self.is_on = false
            end,
            isFrontlightOff = function(self) return not self.is_on end,
            turnOnFrontlight = function(self) self.is_on = true end,
            updateResumeFrontlightState = function(self)
                self.resume_state_updates = (self.resume_state_updates or 0) + 1
            end,
            frontlightWarmth = function(self) return self.warmth end,
            toNativeWarmth = function(_, value) return value end,
            fromNativeWarmth = function(_, value) return value end,
            setWarmth = function(self, value)
                self.warmth = value
                self.warmth_writes = self.warmth_writes + 1
            end,
        }
    end

    it("restores the last brightness after turning the frontlight off", function()
        local powerd = power_device()
        local opts = slider_opts(powerd)

        local group = require("modules/menu/patches/brightness_slider")(touch_menu(), opts)
        assert.are.equal(1, #opts.refs.sliders)
        assert.are.equal(0, #opts.refs.toggles)
        assert.is_true(has_label(group, "Brightness"))
        button(group, "−").hold_callback()

        assert.are.equal(0, opts.refs.fl_state.cur)
        assert.are.equal(0, powerd.intensity)
        assert.is_false(powerd.is_on)
        assert.are.equal(1, powerd.resume_state_updates)

        button(group, "＋").callback()
        assert.are.equal(40, powerd.intensity)
        assert.is_true(powerd.is_on)
        assert.are.equal(2, powerd.resume_state_updates)

        opts.refs.setBrightness(25)
        opts.refs.fl_progress.on_drag_start()
        for value = 24, 0, -1 do opts.refs.fl_progress.on_change(value) end
        opts.refs.fl_progress.on_drag_end()
        button(group, "＋").callback()
        assert.are.equal(25, powerd.intensity)
    end)

    it("shows only warmth and holds minus to zero when brightness is unavailable", function()
        local powerd = power_device()
        local opts = slider_opts(powerd)
        opts.show_frontlight = false
        opts.show_warmth = true

        local group = require("modules/menu/patches/brightness_slider")(touch_menu(), opts)
        assert.are.equal(1, #opts.refs.sliders)
        assert.are.equal(0, #opts.refs.toggles)
        assert.is_true(has_label(group, "Warmth"))
        assert.are.equal(9, opts.refs.sliders[1].slider.value)
        button(group, "−").hold_callback()

        assert.are.equal(0, opts.refs.nl_state.cur)
        assert.are.equal(0, powerd.warmth)
        assert.are.equal(40, powerd.intensity)
    end)

    it("keeps separate brightness and warmth sliders independent", function()
        local powerd = power_device()
        local opts = slider_opts(powerd)
        opts.show_frontlight = true
        opts.show_warmth = true
        opts.unified = false

        local brightness_group = require("modules/menu/patches/brightness_slider")(touch_menu(), opts)
        local warmth_group = require("modules/menu/patches/warmth_slider")(touch_menu(), opts)

        assert.are.equal(2, #opts.refs.sliders)
        assert.are.equal(0, #opts.refs.toggles)
        assert.are.equal(opts.refs.fl_progress, opts.refs.sliders[1].slider)
        assert.are.equal(opts.refs.nl_progress, opts.refs.sliders[2].slider)
        assert.are.equal(40, opts.refs.fl_progress.value)
        assert.are.equal(9, opts.refs.nl_progress.value)
        assert.is_true(has_label(brightness_group, "Brightness"))
        assert.is_true(has_label(warmth_group, "Warmth"))

        button(brightness_group, "＋").callback()
        assert.are.equal(41, powerd.intensity)
        assert.are.equal(9, powerd.warmth)
        button(warmth_group, "−").callback()
        assert.are.equal(41, powerd.intensity)
        assert.are.equal(8, powerd.warmth)
    end)

    it("switches one slider between brightness and warmth without changing hardware", function()
        local powerd = power_device()
        local opts = slider_opts(powerd)
        opts.show_frontlight = true
        opts.show_warmth = true

        local menu = touch_menu()
        local group = require("modules/menu/patches/brightness_slider")(menu, opts)
        local slider = opts.refs.sliders[1].slider
        local switch = find_widget(group, function(widget)
            return type(widget[1]) == "table" and widget[1][1] == opts.refs.toggles[1].toggle
        end)
        assert.is_not_nil(switch)
        switch.dimen = { x = 400, y = 50, w = 100, h = 40 }
        slider.dimen = { x = 150, y = 160, w = 300, h = 40 }
        assert.are.equal(1, #opts.refs.sliders)
        assert.are.equal(2, #opts.refs.toggles)
        assert.are.equal(0, slider.value_min)
        assert.are.equal(100, slider.value_max)
        assert.are.equal(40, slider.value)
        assert.is_true(has_label(group, "Brightness"))
        local label = find_widget(group, function(widget) return widget.text == "Brightness: " end)
        local label_row = group[2]
        local number_box = label_row[1][2]
        number_box.dimen = { x = 130, y = 60, w = 30, h = 20 }
        local mode_refreshes = {
            { widget = menu.show_parent, mode = "ui", region = menu.dimen },
        }
        assert.are.equal(250, label_row[2].width)
        assert.are.equal(switch, label_row[3])
        assert.are.equal(child_index(group, opts.refs.toggles[1].toggle), child_index(group, label))
        assert.is_true(child_index(group, label) < child_index(group, slider))
        assert.is_true(opts.refs.toggles[1].toggle.invert)
        assert.is_false(opts.refs.toggles[2].toggle.invert)

        powerd.warmth = 12
        opts.refs.toggles[2].callback()
        assert.are.same(mode_refreshes, dirty_calls)
        assert.is_true(slider == opts.refs.sliders[1].slider)
        assert.are.equal(0, slider.value_min)
        assert.are.equal(24, slider.value_max)
        assert.are.equal(12, slider.value)
        assert.is_true(has_label(group, "Warmth"))
        assert.is_false(opts.refs.toggles[1].toggle.invert)
        assert.is_true(opts.refs.toggles[2].toggle.invert)
        assert.are.equal(0, powerd.brightness_writes)
        assert.are.equal(0, powerd.warmth_writes)

        button(group, "＋").callback()
        assert.are.equal(13, powerd.warmth)
        assert.are.equal(40, powerd.intensity)

        dirty_calls = {}
        opts.refs.toggles[1].callback()
        assert.are.same(mode_refreshes, dirty_calls)
        assert.is_true(slider == opts.refs.sliders[1].slider)
        assert.are.equal(100, slider.value_max)
        assert.are.equal(40, slider.value)
        assert.is_true(has_label(group, "Brightness"))
        assert.is_true(opts.refs.toggles[1].toggle.invert)
        assert.is_false(opts.refs.toggles[2].toggle.invert)
        assert.are.equal(0, powerd.brightness_writes)
        assert.are.equal(1, powerd.warmth_writes)

        button(group, "−").callback()
        assert.are.equal(39, powerd.intensity)
        assert.are.equal(13, powerd.warmth)

        slider.dimen = { x = 150, y = 110, w = 300, h = 40 }
        dirty_calls = {}
        slider._dragging = true
        slider.on_change(38)
        assert.are.equal(130, require("device").screen.bb.last_paint_x)
        assert.are.equal(60, require("device").screen.bb.last_paint_y)
        assert.are.same({ { widget = nil, mode = "fast", region = { x = 130, y = 60, w = 320, h = 90 } } }, dirty_calls)
    end)

    it("stacks and centers the unified controls when requested", function()
        local opts = slider_opts(power_device())
        opts.show_frontlight = true
        opts.show_warmth = true
        opts.centered = true

        local group = require("modules/menu/patches/brightness_slider")(touch_menu(), opts)
        local label = find_widget(group, function(widget) return widget.text == "Brightness: " end)

        assert.are.equal(2, child_index(group, opts.refs.toggles[1].toggle))
        assert.are.equal(4, child_index(group, label))
        assert.are.equal(opts.inner_width, group[4].dimen.w)
        assert.are.equal(1, #opts.refs.sliders)

        opts.refs.toggles[2].callback()
        assert.is_true(has_label(group, "Warmth"))
    end)
end)
