local util = require("util")

describe("reader controls settings", function()
    local Settings, reader, events, globals, previous_settings
    before_each(function()
        ZenSpec.unload("modules/menu/reader_controls/settings")
        Settings = require("modules/menu/reader_controls/settings")
        events, globals = {}, ZenSpec.memorySettings({ unrelated = 42, kopt_font_size = 1.2 })
        previous_settings, _G.G_reader_settings = _G.G_reader_settings, globals
        reader = {
            rolling = {},
            document = { configurable = { font_size = 23, h_page_margins = { 10, 30 },
                t_page_margin = 20, b_page_margin = 35, sync_t_b_page_margins = 1 } },
            config = { options = { prefix = "copt", { options = {
                { name = "font_size", name_text = "Font size", default_value = 20, values = { 12, 24, 36 },
                    event = "SetFontSize", more_options_param = { value_min = 12, value_max = 255, value_step = 0.5 } },
                { name = "h_page_margins", name_text = "L/R Margins", default_value = { 10, 10 },
                    values = { { 5, 5 }, { 10, 10 }, { 20, 20 }, { 40, 40 } },
                    event = "SetPageHorizMargins", more_options = true, more_options_param = { left_min = 0, left_max = 140, left_step = 1 } },
                { name = "view_mode", name_text = "View Mode", default_value = 0, values = { 0, 1 },
                    args = { "page", "scroll" }, event = "SetViewMode" },
                { name = "font_fine_tune", values = { -1, 1 } },
            } } } },
            handleEvent = function(_self, event) events[#events + 1] = event end,
        }
    end)
    after_each(function() _G.G_reader_settings = previous_settings end)

    it("saves exactly one selected native default", function()
        local original = util.tableDeepCopy(reader.document.configurable)
        assert.are.equal(1, Settings.saveDefaults(reader, { copt_font_size = true }, globals))
        assert.are.same({ unrelated = 42, kopt_font_size = 1.2, copt_font_size = 23 }, globals.data)
        assert.are.same(original, reader.document.configurable)
    end)

    it("saves all eligible settings in the active native group", function()
        Settings.saveDefaults(reader, true, globals)
        assert.are.same({ 10, 30 }, globals.data.copt_h_page_margins)
        assert.is_nil(globals.data.copt_font_fine_tune)
        assert.are.equal(1.2, globals.data.kopt_font_size)
        reader.document.configurable.h_page_margins[1] = 99
        assert.are.equal(10, globals.data.copt_h_page_margins[1])
    end)

    it("does not write anything when no settings are selected", function()
        assert.are.equal(0, Settings.saveDefaults(reader, {}, globals))
        assert.are.same({ unrelated = 42, kopt_font_size = 1.2 }, globals.data)
    end)

    it("sends native configuration values before their mapped event arguments", function()
        assert.is_true(Settings.apply(reader, "view_mode", 1))
        assert.are.equal("ConfigChange", events[1].handler:sub(3))
        assert.are.equal("view_mode", events[1].args[1])
        assert.are.equal(1, events[1].args[2])
        assert.are.equal("onSetViewMode", events[2].handler)
        assert.are.equal("scroll", events[2].args[1])
    end)

    it("keeps touch detection active during native slider previews and restores input hooks", function()
        local device, uimanager = package.loaded.device, package.loaded["ui/uimanager"]
        local input, flash_guarded = {}, 0
        ZenSpec.replace("device", { input = input })
        ZenSpec.replace("ui/uimanager", { avoidFlashOnNextRepaint = function() flash_guarded = flash_guarded + 1 end })
        local resets = 0
        input.inhibitInput = function() resets = resets + 1 end
        input.inhibitInputUntil = input.inhibitInput
        local native_inhibit, native_until = input.inhibitInput, input.inhibitInputUntil
        local handle = reader.handleEvent
        reader.handleEvent = function(self, event)
            input:inhibitInput(true)
            input:inhibitInputUntil(0.2)
            handle(self, event)
        end
        local ok, err = pcall(function()
            assert.is_true(Settings.preview(reader, "font_size", 25))
            assert.are.equal(1, flash_guarded) -- No full-refresh promotion mid-drag.
            assert.are.equal(0, resets)
            assert.are.equal("onSetFontSize", events[2].handler)
            assert.are.equal(native_inhibit, input.inhibitInput)
            assert.are.equal(native_until, input.inhibitInputUntil)
            reader.handleEvent = function() error("render failed") end
            assert.has_error(function() Settings.preview(reader, "font_size", 26) end)
            assert.are.equal(native_inhibit, input.inhibitInput)
            assert.are.equal(native_until, input.inhibitInputUntil)
            reader.handleEvent = handle
            Settings.apply(reader, "font_size", 27)
            input:inhibitInput(true)
            assert.are.equal(1, resets)
        end)
        package.loaded.device, package.loaded["ui/uimanager"] = device, uimanager
        assert.is_true(ok, err)
    end)

    it("reads the current native panel including injected options and boolean event arguments", function()
        local panel = { icon = "appbar.contrast", options = {
            { name = "sw_dithering", toggle = { "off", "on" }, values = { 0, 1 }, args = { false, true },
                event = "SWDitheringUpdate" },
        } }
        table.insert(reader.config.options, panel)
        assert.are.equal(panel, Settings.panel(reader, "appbar.contrast"))
        local injected = { name = "native_extra", labels = { "small", "large" }, values = { 2, 4 } }
        table.insert(panel.options, injected)
        assert.are.equal(injected, Settings.options(reader).native_extra)
        assert.is_nil(Settings.panel(reader, "missing"))
        Settings.apply(reader, "sw_dithering", 0)
        assert.are.equal("onSWDitheringUpdate", events[2].handler)
        assert.is_false(events[2].args[1])
        Settings.apply(reader, "sw_dithering", 1)
        assert.is_true(events[4].args[1])
    end)

    it("formats native margin presets as values instead of table addresses", function()
        local option = Settings.options(reader).h_page_margins
        option.values = { { 10, 10 }, { 10, 30 } }
        assert.are.equal("10", Settings.valueText(reader, option, { 10, 10 }))
        assert.are.equal("10 / 30", Settings.valueText(reader, option, { 10, 30 }))
        assert.are.equal("100 / 100", Settings.valueText(reader, { name = "word_spacing" }, { 100, 100 }))
        assert.are.equal("Left/Right Margins", Settings.label(reader, option))
    end)

    it("uses compact numeric font weights instead of named weight classes", function()
        local option = { name = "font_base_weight", show_true_value_func = function() return "Regular (400)" end }
        assert.are.equal("350", Settings.valueText(reader, option, -0.5))
        assert.are.equal("400", Settings.valueText(reader, option, 0))
        assert.are.equal("425", Settings.valueText(reader, option, 0.25))
        assert.are.equal("700", Settings.valueText(reader, option, 3))
    end)

    it("configures both margins before the native paired picker event", function()
        reader.config.options[1].options[#reader.config.options[1].options + 1] = {
            name = "t_page_margin", event = "SetPageTopMargin", more_options_param = {
                names = { "t_page_margin", "b_page_margin" }, event = "SetPageTopAndBottomMargin",
            },
        }
        Settings.apply(reader, "t_page_margin", { 21, 36 })
        assert.are.equal(3, #events)
        assert.are.same({ "t_page_margin", 21, n = 2 }, events[1].args)
        assert.are.same({ "b_page_margin", 36, n = 2 }, events[2].args)
        assert.are.equal("onSetPageTopAndBottomMargin", events[3].handler)
        assert.are.same({ 21, 36 }, events[3].args[1])
        events = {}
        Settings.apply(reader, "t_page_margin", 22)
        assert.are.equal(2, #events)
        assert.are.equal("onSetPageTopMargin", events[2].handler)
        assert.are.equal(22, events[2].args[1])
    end)

    it("keeps asymmetric margins until the paired slider is moved", function()
        local slider = Settings.slider(reader, "h_page_margins")
        assert.are.equal(20, slider.value)
        assert.are.same({ 10, 30 }, reader.document.configurable.h_page_margins)
        assert.are.same({ 21, 21 }, slider.decode(slider.value + 1))
        assert.are.same({ 21, 21 }, slider.advance({ 10, 30 }, 1))
        assert.are.equal(10, slider.default_value)
    end)

    it("drives one side of the horizontal margins while their sync is off", function()
        local slider = Settings.slider(reader, "h_page_margins", nil, 2)
        assert.are.equal(30, slider.value)
        assert.are.equal(2, slider.side)
        assert.are.same({ 10, 31 }, slider.decode(slider.value + 1))
        assert.are.same({ 10, 29 }, slider.advance({ 10, 30 }, -1))
        assert.are.equal(10, slider.default_value)
        assert.are.equal("30", Settings.valueText(reader, slider.option, { 10, 30 }, 2))
        assert.are.same({ 11, 30 }, Settings.slider(reader, "h_page_margins", nil, 1).advance({ 10, 30 }, 1))
    end)

    it("syncs horizontal margins by default when equal, then keeps the book's choice", function()
        assert.is_false(Settings.syncedMargins(reader, "h_page_margins"))
        reader.document.configurable.h_page_margins = { 30, 30 }
        assert.is_true(Settings.syncedMargins(reader, "h_page_margins"))
        reader.doc_settings = ZenSpec.memorySettings({})
        Settings.setMarginSync(reader, "h_page_margins", false)
        assert.is_false(Settings.syncedMargins(reader, "h_page_margins"))
        assert.is_false(reader.doc_settings.data.zen_sync_h_page_margins)
        reader.document.configurable.h_page_margins = { 10, 30 }
        Settings.setMarginSync(reader, "h_page_margins", true)
        assert.is_true(Settings.syncedMargins(reader, "h_page_margins"))
        assert.are.equal(0, #events)
    end)

    it("reads the active native margin sync state before the stored setting", function()
        assert.is_true(Settings.syncedMargins(reader))
        reader.typeset = { sync_t_b_page_margins = false }
        assert.is_false(Settings.syncedMargins(reader))
        reader.document.configurable.sync_t_b_page_margins = 0
        reader.typeset.sync_t_b_page_margins = true
        assert.is_true(Settings.syncedMargins(reader))
    end)

    it("represents fractional native values with integer slider positions", function()
        local slider = Settings.slider(reader, "font_size")
        assert.are.equal(23, slider.decode(slider.value))
        assert.are.equal(23.5, slider.decode(slider.value + 1))
        assert.are.equal(23.75, slider.advance(23.25, 1))
    end)

    it("steps by KOReader's spin step in native preset order", function()
        reader.config.options[1].options[#reader.config.options[1].options + 1] = {
            name = "white_threshold", values = { 255, 224, 192, 160, 128, 96, 64, 32 }, default_value = 255,
            more_options = true, more_options_param = { value_min = 0, value_max = 255, value_step = 1 },
        }
        reader.document.configurable.white_threshold = 255
        local slider = Settings.slider(reader, "white_threshold")
        assert.are.equal(0, slider.value)
        assert.are.equal(127, slider.value_max)
        assert.are.equal(254, slider.decode(1))
        assert.are.equal(128, slider.decode(slider.value_max))
        assert.are.equal(63, slider.advance(64, 1))
        assert.are.equal(0, slider.default_value)
        reader.document.configurable.white_threshold = 230
        slider = Settings.slider(reader, "white_threshold")
        assert.are.equal(25, slider.value)
        assert.are.equal(230, reader.document.configurable.white_threshold)
        assert.are.equal(229, slider.advance(230, 1))
        assert.are.equal(231, slider.advance(230, -1))
        assert.are.equal(255, slider.advance(255, -1))
        globals:saveSetting("copt_white_threshold", 208)
        assert.are.equal(47, Settings.slider(reader, "white_threshold").default_value)
    end)

    it("zooms font size to five nearby presets while retaining native fine steps", function()
        local option = Settings.options(reader).font_size
        option.values = { 12, 16, 20, 22, 24, 26, 28, 30, 34, 38, 44 }
        option.default_value = 22
        local slider = Settings.slider(reader, "font_size")
        assert.are.equal(16, slider.decode(slider.value_min))
        assert.are.equal(26, slider.decode(slider.value_max))
        assert.is_true(slider.position(44) > slider.value_max)
        assert.are.equal(23, slider.decode(slider.value))
        assert.are.equal(23.5, slider.decode(slider.value + 1))
        assert.are.equal(23.75, slider.advance(23.25, 1))
        assert.are.equal(255, slider.advance(254.5, 1))
    end)

    it("keeps custom current values and saved defaults inside the visible range", function()
        local option = Settings.options(reader).font_size
        option.values = { 12, 16, 20, 22, 24, 26, 28, 30, 34, 38, 44 }
        globals:saveSetting("copt_font_size", 80.25)
        reader.document.configurable.font_size = 100.25
        local slider = Settings.slider(reader, "font_size")
        assert.is_true(slider.value >= slider.value_min and slider.value <= slider.value_max)
        assert.is_true(slider.default_value >= slider.value_min and slider.default_value <= slider.value_max)
        assert.are.equal(100.25, slider.decode(slider.value))
        assert.are.equal(80.25, slider.decode(slider.default_value))
        assert.are.equal(100.75, slider.advance(100.25, 1))
        assert.are.equal(100.25, reader.document.configurable.font_size)
        assert.are.equal(80.25, globals.data.copt_font_size)
    end)

    it("can show seven nearby presets without changing native fine steps", function()
        local option = Settings.options(reader).font_size
        option.values = { 12, 16, 20, 22, 24, 26, 28, 30, 34, 38, 44 }
        option.default_value = 22
        local slider = Settings.slider(reader, "font_size", 7)
        assert.are.equal(12, slider.decode(slider.value_min))
        assert.are.equal(28, slider.decode(slider.value_max))
        assert.are.equal(23.5, slider.decode(slider.value + 1))
        assert.are.equal(23.75, slider.advance(23.25, 1))
        reader.document.configurable.font_size = 100.25
        slider = Settings.slider(reader, "font_size", 7)
        assert.is_true(slider.decode(slider.value_max) >= 100.25)
        assert.are.equal(100.25, slider.decode(slider.value))
    end)

    it("fills preset gaps with KOReader's negative-range spin step", function()
        reader.config.options[1].options[#reader.config.options[1].options + 1] = {
            name = "font_base_weight", values = { -1, -0.5, 0, 0.5, 1, 1.5, 3 }, default_value = 0,
            more_options = true, more_options_param = { value_min = -3, value_max = 5.5, value_step = 0.25 },
        }
        reader.document.configurable.font_base_weight = 1.5
        local slider = Settings.slider(reader, "font_base_weight")
        assert.are.equal(-1, slider.decode(slider.value_min))
        assert.are.equal(1.75, slider.decode(slider.value + 1))
        assert.are.equal(12, slider.default_value)
        assert.are.equal(1.5, slider.advance(1.25, 1))
        assert.are.equal(-3, slider.advance(-3, -1))
    end)

    it("displays contrast using KOReader's gamma table between preset values", function()
        local option = { values = { 0, 2 }, labels = { 0.3, 0.4 },
            more_options_param = { value_table = { 0.3, 0.35, 0.4 }, value_table_shift = 1 } }
        assert.are.equal("0.35", Settings.valueText(reader, option, 1))
        assert.are.equal("0.4", Settings.valueText(reader, option, 2))
    end)

    it("does not treat PDF sizing ratios as EPUB font sizes", function()
        reader.config.options.prefix = "kopt"
        reader.rolling = nil
        reader.document.configurable.font_size = 1.2
        reader.config.options[1].options[1].more_options_param = { value_min = 0.2, value_max = 3, value_step = 0.1 }
        reader.config.options[1].options[4].args = { -0.05, 0.05 }
        local slider = Settings.slider(reader, "font_size")
        assert.are.equal(1.2, slider.decode(slider.value))
        assert.are.equal(1.25, slider.decode(slider.value + 1))
        Settings.saveDefaults(reader, { kopt_font_size = true }, globals)
        assert.are.equal(1.2, globals.data.kopt_font_size)
        assert.is_nil(globals.data.copt_font_size)
    end)
end)
