local util = require("util")

describe("reader setting context menus", function()
    local Details, reader, shown, applied, original, globals, anchor, closed, refreshes
    local modules = { "modules/menu/reader_controls/details", "ui/uimanager", "ui/widget/confirmbox",
        "common/ui/zen_anchored_menu", "ui/widget/spinwidget" }

    local function action(text)
        for _i, row in ipairs(shown.buttons) do
            if row[1].text == text or row[1].text == "✓ " .. text then row[1].callback(); return end
        end
        error("Missing action: " .. text)
    end

    local function open(name)
        return Details.show(reader, name, function(key, value)
            applied[#applied + 1] = { key, util.tableDeepCopy(value) }
            if key == "font_face" then
                reader.font.font_face = value
            elseif key == "t_page_margin" then
                reader.document.configurable.t_page_margin = value[1]
                reader.document.configurable.b_page_margin = value[2]
            else
                reader.document.configurable[key] = value
            end
        end, function() refreshes = refreshes + 1 end, anchor)
    end

    local function confirm()
        local dialog = shown
        dialog.ok_callback()
        require("ui/uimanager"):close(dialog)
    end

    before_each(function()
        original, applied, closed, refreshes, shown = {}, {}, {}, 0, nil
        for _i, name in ipairs(modules) do original[name] = package.loaded[name] end
        globals, _G.G_reader_settings = _G.G_reader_settings, ZenSpec.memorySettings{ unrelated = 42 }
        ZenSpec.replace("ui/uimanager", {
            show = function(_self, widget) shown = widget end,
            close = function(_self, widget)
                closed[#closed + 1] = widget
                if shown == widget then shown = nil end
            end,
        })
        ZenSpec.replace("ui/widget/confirmbox", { new = function(_self, config) return config end })
        ZenSpec.replace("ui/widget/spinwidget", { new = function(_self, config) return config end })
        ZenSpec.replace("common/ui/zen_anchored_menu", { new = function(config)
            config.layout = config.buttons
            config.moveFocusTo = function() end
            return config
        end })
        anchor = { x = 500, y = 300, w = 40, h = 40 }
        reader = { document = { default_font = "Built-in", configurable = { font_size = 23, font_gamma = 1,
            word_spacing = { 100, 95 }, t_page_margin = 20, b_page_margin = 30, sync_t_b_page_margins = 0,
            h_page_margins = { 20, 20 } } },
            font = { font_face = "Current", onSaveSettings = function() applied[#applied + 1] = "font saved" end },
            config = { options = { prefix = "copt", { options = {
                { name = "font_size", values = { 12, 24, 36 }, default_value = 20 },
                { name = "font_fine_tune", more_options_param = { value_min = 12, value_max = 255,
                    value_step = 0.5, precision = "%.1f" } },
                { name = "font_gamma", values = { 0, 1, 2 }, default_value = 0,
                    more_options_param = { value_table = { 0.3, 0.35, 0.4 }, value_table_shift = 1 } },
                { name = "word_spacing", values = {}, default_value = { 100, 90 },
                    more_options_param = { left_min = 10, left_max = 500, right_min = 25, right_max = 100 } },
                { name = "t_page_margin", default_value = 10, values = {}, more_options_param = {
                    names = { "t_page_margin", "b_page_margin" }, left_min = 0, left_max = 140,
                    right_min = 0, right_max = 140 } },
                { name = "b_page_margin", default_value = 15 },
                { name = "sync_t_b_page_margins", values = { 0, 1 } },
                { name = "h_page_margins", default_value = { 10, 10 }, values = {}, more_options = true,
                    more_options_param = { left_min = 0, left_max = 140, left_step = 1 } },
            } } } }, doc_settings = ZenSpec.memorySettings({}), handleEvent = function(_self, event)
                if event.handler == "onConfigChange" then reader.document.configurable[event.args[1]] = event.args[2] end
            end }
        ZenSpec.unload("modules/menu/reader_controls/details")
        Details = require("modules/menu/reader_controls/details")
    end)

    after_each(function()
        _G.G_reader_settings = globals
        for _i, name in ipairs(modules) do package.loaded[name] = original[name] end
    end)

    it("shows only default actions and restores the saved value", function()
        G_reader_settings:saveSetting("copt_font_size", 22.5)
        local popup = open("font_size")
        assert.are.equal(anchor, popup.anchor)
        assert.is_true(popup.anchor_right)
        assert.are.equal(3, #popup.buttons)
        assert.are.equal("Set value", popup.buttons[1][1].text)
        assert.are.equal("Set as default", popup.buttons[2][1].text)
        assert.are.equal("Reset", popup.buttons[3][1].text)
        assert.is_nil(popup.rows_per_page)
        assert.is_nil(popup.value_widget)
        action("Reset")
        assert.is_nil(shown)
        assert.are.same({ popup }, closed)
        assert.are.equal(1, refreshes)
        assert.are.same({ { "font_size", 22.5 } }, applied)
        assert.are.equal(22.5, reader.document.configurable.font_size)
        assert.are.equal(22.5, G_reader_settings.data.copt_font_size)
    end)

    it("confirms the current slider value without altering unrelated settings", function()
        reader.document.configurable.font_size = 24
        local popup = open("font_size")
        action("Set as default")
        assert.are.same({ popup }, closed)
        assert.is_nil(G_reader_settings.data.copt_font_size)
        confirm()
        assert.is_nil(shown)
        assert.are.equal(2, refreshes)
        assert.are.same({ unrelated = 42, copt_font_size = 24 }, G_reader_settings.data)
        reader.document.configurable.font_size = 25
        open("font_size")
        action("Reset")
        assert.are.equal(24, reader.document.configurable.font_size)
    end)

    it("picks an exact value with KOReader's spin step", function()
        local popup = open("font_size")
        action("Set value")
        assert.are.same({ popup }, closed)
        assert.are.equal(23, shown.value)
        assert.are.equal(0.5, shown.value_step)
        assert.are.equal("%.1f", shown.precision)
        shown.callback({ value = 30.5 })
        assert.are.same({ { "font_size", 30.5 } }, applied)
    end)

    it("restores gamma's native default index, including zero", function()
        open("font_gamma")
        action("Reset")
        assert.are.same({ { "font_gamma", 0 } }, applied)
    end)

    it("saves fixed-layout scaling defaults in the native group", function()
        reader.config.options.prefix = "kopt"
        reader.document.configurable.font_size = 1.05
        open("font_size")
        action("Set as default")
        confirm()
        assert.are.equal(1.05, G_reader_settings.data.kopt_font_size)
        assert.is_nil(G_reader_settings.data.copt_font_size)
    end)

    it("restores fractional fixed-layout margin values", function()
        reader.config.options.prefix = "kopt"
        table.insert(reader.config.options[1].options, { name = "page_margin", values = { 0.05, 1 },
            default_value = 0.1, more_options_param = { value_min = 0, value_max = 1.5, value_step = 0.01 } })
        reader.document.configurable.page_margin = 0.11
        open("page_margin")
        action("Reset")
        assert.are.same({ { "page_margin", 0.1 } }, applied)
    end)

    it("saves paired defaults without sharing mutable book settings", function()
        reader.document.configurable.word_spacing = { 100, 85 }
        open("word_spacing")
        action("Set as default")
        confirm()
        reader.document.configurable.word_spacing[1] = 110
        assert.are.same({ 100, 85 }, G_reader_settings.data.copt_word_spacing)
        open("word_spacing")
        action("Reset")
        assert.are.same({ 100, 85 }, reader.document.configurable.word_spacing)
    end)

    it("keeps margin sync available and saves both defaults", function()
        local popup = open("t_page_margin")
        assert.are.equal(4, #popup.buttons)
        action("Sync")
        assert.is_nil(shown)
        assert.are.same({ popup }, closed)
        assert.are.equal(1, refreshes)
        assert.are.same({ "t_page_margin", { 25, 25 } }, applied[1])
        reader.document.configurable.t_page_margin, reader.document.configurable.b_page_margin = 26, 26
        open("t_page_margin")
        action("Set as default")
        confirm()
        assert.are.equal(26, G_reader_settings.data.copt_t_page_margin)
        assert.are.equal(26, G_reader_settings.data.copt_b_page_margin)
        open("t_page_margin")
        action("Sync")
        assert.are.equal(0, reader.document.configurable.sync_t_b_page_margins)
    end)

    it("toggles horizontal margin sync per book and picks one side while unsynced", function()
        local popup = open("h_page_margins")
        assert.are.equal("✓ Sync", popup.buttons[1][1].text)
        action("Sync")
        assert.are.same({}, applied)
        assert.is_false(reader.doc_settings.data.zen_sync_h_page_margins)
        reader.document.configurable.h_page_margins = { 20, 30 }
        Details.show(reader, "h_page_margins", function(key, value) applied[#applied + 1] = { key, value } end,
            function() end, anchor, 2)
        action("Set value")
        assert.are.equal(30, shown.value)
        shown.callback({ value = 35 })
        assert.are.same({ { "h_page_margins", { 20, 35 } } }, applied)
        applied = {}
        popup = open("h_page_margins")
        assert.are.equal("Sync", popup.buttons[1][1].text)
        action("Sync")
        assert.are.same({ { "h_page_margins", { 25, 25 } } }, applied)
        assert.is_true(reader.doc_settings.data.zen_sync_h_page_margins)
    end)

    it("provides font-family defaults and reset using the same context menu", function()
        local popup = open("font_face")
        assert.is_nil(popup.footer_buttons)
        assert.are.equal("Set as default", popup.buttons[1][1].text)
        assert.are.equal("Reset", popup.buttons[2][1].text)
        action("Reset")
        assert.are.same({ { "font_face", "Built-in" }, "font saved" }, applied)
        assert.is_nil(shown)
        open("font_face")
        action("Set as default")
        confirm()
        assert.is_nil(shown)
        assert.are.equal("Built-in", G_reader_settings.data.cre_font)
    end)
end)
