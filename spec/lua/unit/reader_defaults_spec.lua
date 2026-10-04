describe("Reader defaults", function()
    local original_modules
    local original_settings
    local preset_settings
    local active_preset

    before_each(function()
        original_modules = {}
        original_settings = G_reader_settings
        for _i, name in ipairs({
            "apps/reader/readerui",
            "common/plugin_root",
            "common/reader_defaults",
            "common/reader_status_bar",
            "config/preset_store",
            "device",
            "document/credocument",
            "modules/reader/patches/reader_footer_presets",
        }) do
            original_modules[name] = package.loaded[name]
        end
        preset_settings = nil
        active_preset = nil
        ZenSpec.replace("device", {
            hasColorScreen = function() return true end,
        })
        ZenSpec.replace("common/plugin_root", "/plugins/zenos.koplugin")
        ZenSpec.replace("config/preset_store", {
            saveSettings = function(kind, settings)
                assert.are.equal("reader", kind)
                preset_settings = settings
            end,
            setActivePreset = function(kind, name)
                assert.are.equal("reader", kind)
                active_preset = name
            end,
        })
        ZenSpec.unload("modules/reader/patches/reader_footer_presets")
        ZenSpec.unload("common/reader_defaults")
    end)

    after_each(function()
        for _i, name in ipairs({
            "apps/reader/readerui",
            "common/plugin_root",
            "common/reader_defaults",
            "common/reader_status_bar",
            "config/preset_store",
            "device",
            "document/credocument",
            "modules/reader/patches/reader_footer_presets",
        }) do
            package.loaded[name] = original_modules[name]
        end
        _G.G_reader_settings = original_settings
    end)

    it("applies the Zen Reader typography and layout defaults", function()
        local settings = ZenSpec.memorySettings({
            footer = {
                page_progress = true,
                container_bottom_padding = 1,
            },
        })
        local config = {
            features = { reader_top_status_bar = false },
            reader_footer = { chapter_time_format = "number" },
            reader_top_status_bar = {
                font_size = 14,
                left_order = { "battery" },
                center_order = {},
                right_order = { "time" },
            },
        }
        local status_font = "/plugins/zenos.koplugin/fonts/hyperreadable/Hyperreadable-SemiBold.ttf"

        require("common/reader_defaults").apply(settings, config)

        assert.are.equal("Readerly R", settings:readSetting("cre_font"))
        assert.are.same({30, 30}, settings:readSetting("copt_h_page_margins"))
        assert.are.equal(1, settings:readSetting("copt_sync_t_b_page_margins"))
        assert.are.equal(30, settings:readSetting("copt_t_page_margin"))
        assert.are.equal(30, settings:readSetting("copt_b_page_margin"))
        assert.are.same({100, 90}, settings:readSetting("copt_word_spacing"))
        assert.are.equal(5, settings:readSetting("copt_word_expansion"))
        assert.are.equal(110, settings:readSetting("copt_line_spacing"))
        assert.are.equal(25, settings:readSetting("copt_font_gamma"))
        assert.are.equal(-0.5, settings:readSetting("copt_font_base_weight"))
        assert.are.equal(23, settings:readSetting("copt_font_size"))
        assert.are.equal(2, settings:readSetting("copt_font_hinting"))
        assert.are.equal(3, settings:readSetting("copt_font_kerning"))
        assert.are.equal(0, settings:readSetting("copt_embedded_css"))
        assert.are.equal(0, settings:readSetting("copt_embedded_fonts"))
        assert.are.equal(1, settings:readSetting("copt_nightmode_images"))
        assert.are.equal(1, settings:readSetting("copt_status_line"))
        assert.is_false(settings:readSetting("alt_status_bar"))

        local footer = settings:readSetting("footer")
        assert.is_false(footer.page_progress)
        assert.is_true(footer.chapter_time_to_read)
        assert.is_true(footer.dynamic_filler)
        assert.is_true(footer.percentage)
        assert.are.equal("chapter_time_to_read", footer.order[2])
        assert.are.equal("dynamic_filler", footer.order[3])
        assert.are.equal("percentage", footer.order[4])
        assert.are.equal(status_font, footer.text_font_face)
        assert.is_false(footer.text_font_bold)
        assert.are.equal(6, footer.container_bottom_padding)
        assert.are.equal(1, settings:readSetting("reader_footer_mode"))
        assert.are.equal("ZenOS", settings:readSetting("reader_footer_custom_text"))
        assert.are.equal(1, settings:readSetting("reader_footer_custom_text_repetitions"))
        assert.are.equal(status_font, config.reader_top_status_bar.font_face)
        assert.are.equal(14, config.reader_top_status_bar.font_size)
        assert.are.same({}, config.reader_top_status_bar.left_order)
        assert.are.same({ "time" }, config.reader_top_status_bar.center_order)
        assert.are.same({}, config.reader_top_status_bar.right_order)
        assert.are.equal("full", config.reader_footer.chapter_time_format)
        assert.is_true(config.features.reader_top_status_bar)
        assert.are.equal("(ZenOS) Chapter Time + %", active_preset)
        assert.are.same(footer, preset_settings.footer)
        assert.are.equal("full", preset_settings.chapter_time_format)
    end)

    it("keeps the preset bottom margin on monochrome screens", function()
        ZenSpec.replace("device", {
            hasColorScreen = function() return false end,
        })
        ZenSpec.unload("modules/reader/patches/reader_footer_presets")
        local settings = ZenSpec.memorySettings()

        require("common/reader_defaults").apply(settings, {})

        assert.are.equal(1, settings:readSetting("footer").container_bottom_padding)
    end)

    it("saves the Colorsoft CBZ/PDF defaults", function()
        local settings = ZenSpec.memorySettings({ kopt_contrast = 1, kopt_page_scroll = 1 })

        require("common/reader_defaults").apply(settings, {})

        assert.are.equal(2.5, settings:readSetting("kopt_contrast"))
        assert.are.equal(1, settings:readSetting("kopt_nightmode_document"))
        assert.are.equal(0.1, settings:readSetting("kopt_page_margin"))
        assert.are.equal(0, settings:readSetting("kopt_page_scroll"))
        assert.are.equal(2, settings:readSetting("kopt_saturation"))
        assert.are.equal(1, settings:readSetting("kopt_trim_page"))
        assert.are.equal(4, settings:readSetting("kopt_zoom_mode_genus"))
        assert.are.equal(1, settings:readSetting("kopt_zoom_mode_type"))
    end)

    it("applies CBZ/PDF defaults to active and deferred paged readers", function()
        local ReaderDefaults = require("common/reader_defaults")
        for _i, deferred in ipairs({ false, true }) do
            local events = {}
            local saved = false
            local reader = {
                document = { configurable = { text_wrap = 0 } },
                paging = {},
                handleEvent = function(_self, event) events[event.handler] = { unpack(event.args) } end,
                saveSettings = function() saved = true end,
            }
            ZenSpec.replace("apps/reader/readerui", { instance = reader })

            local applied
            if deferred then
                applied = ReaderDefaults.applyDeferredToReader(reader)
            else
                applied = ReaderDefaults.apply(ZenSpec.memorySettings(), {})
            end

            assert.is_true(applied)
            assert.is_true(saved)
            assert.are.equal(2.5, reader.document.configurable.contrast)
            assert.are.equal(1, reader.document.configurable.nightmode_document)
            assert.are.equal(0.1, reader.document.configurable.page_margin)
            assert.are.equal(0, reader.document.configurable.page_scroll)
            assert.are.equal(2, reader.document.configurable.saturation)
            assert.are.equal(1, reader.document.configurable.trim_page)
            assert.are.equal(4, reader.document.configurable.zoom_mode_genus)
            assert.are.equal(1, reader.document.configurable.zoom_mode_type)
            assert.are.equal(0, reader.document.configurable.text_wrap)
            assert.is_nil(reader.document.configurable.font_size)
            assert.are.same({ 2.5, true }, events.onGammaUpdate)
            assert.are.same({ 2, true }, events.onSaturationUpdate)
            assert.are.same({ false }, events.onSetScrollMode)
            assert.are.same({ "pagewidth" }, events.onSetZoomMode)
            assert.is_table(events.onReZoom)
        end
    end)

    it("keeps existing reader and status fonts for unsupported locales", function()
        _G.G_reader_settings = ZenSpec.memorySettings({ language = "ru_RU" })
        local settings = ZenSpec.memorySettings({
            cre_font = "Noto Serif CJK",
            footer = {
                text_font_face = "NotoSansCJK-Regular.ttc",
                text_font_bold = true,
            },
        })
        local document_calls = {}
        local reader = {
            document = {
                configurable = {},
                setFontFace = function(_self, value) document_calls.font_face = value end,
            },
            font = { font_face = "Noto Serif CJK" },
            rolling = {},
        }
        local config = {
            reader_top_status_bar = { font_face = "NotoSansCJK-Regular.ttc" },
        }
        ZenSpec.replace("apps/reader/readerui", { instance = reader })

        require("common/reader_defaults").apply(settings, config)

        assert.are.equal("Noto Serif CJK", settings:readSetting("cre_font"))
        assert.are.equal("NotoSansCJK-Regular.ttc", settings:readSetting("footer").text_font_face)
        assert.is_true(settings:readSetting("footer").text_font_bold)
        assert.are.equal("NotoSansCJK-Regular.ttc", config.reader_top_status_bar.font_face)
        assert.are.equal("Noto Serif CJK", reader.font.font_face)
        assert.is_nil(document_calls.font_face)
    end)

    it("applies deferred EPUB defaults without replacing customized status bars", function()
        local custom_footer = {
            time = true,
            battery = false,
            book_title = true,
            order = { [0] = "off", "book_title", "time", "battery" },
        }
        local settings = ZenSpec.memorySettings({
            alt_status_bar = true,
            copt_status_line = 0,
            footer = custom_footer,
            reader_footer_mode = 3,
            reader_footer_custom_text = "Mine",
        })
        local config = {
            features = { reader_top_status_bar = false },
            reader_footer = { chapter_time_format = "number" },
            reader_top_status_bar = {
                left_order = { "book_title" },
                center_order = { "chapter" },
                right_order = { "battery" },
            },
        }
        local preset_loads = 0
        local saved = false
        local reader = {
            document = { configurable = { status_line = 0 } },
            font = {},
            rolling = {},
            view = {
                footer = {
                    loadPreset = function() preset_loads = preset_loads + 1 end,
                },
            },
            saveSettings = function() saved = true end,
        }

        local applied = require("common/reader_defaults").applyDeferredToReader(reader)

        assert.is_true(applied)
        assert.is_true(saved)
        assert.are.equal(custom_footer, settings:readSetting("footer"))
        assert.same(custom_footer.order, settings:readSetting("footer").order)
        assert.are.equal(3, settings:readSetting("reader_footer_mode"))
        assert.are.equal("Mine", settings:readSetting("reader_footer_custom_text"))
        assert.is_true(settings:readSetting("alt_status_bar"))
        assert.are.equal(0, settings:readSetting("copt_status_line"))
        assert.are.equal(0, reader.document.configurable.status_line)
        assert.are.equal(0, preset_loads)
        assert.is_false(config.features.reader_top_status_bar)
        assert.same({ "book_title" }, config.reader_top_status_bar.left_order)
        assert.same({ "chapter" }, config.reader_top_status_bar.center_order)
        assert.same({ "battery" }, config.reader_top_status_bar.right_order)
        assert.are.equal("number", config.reader_footer.chapter_time_format)
        assert.is_nil(preset_settings)
        assert.is_nil(active_preset)
    end)

    it("updates the active reflowable book and loads the Chapter Time preset", function()
        local document_calls = {}
        local loaded_preset
        local footer_resets = 0
        local footer_refreshes = 0
        local saved = false
        local document = {
            configurable = {},
            setFontFace = function(_self, value) document_calls.font_face = value end,
            setFontSize = function(_self, value) document_calls.font_size = value end,
            setFontHinting = function(_self, value) document_calls.font_hinting = value end,
            setFontKerning = function(_self, value) document_calls.font_kerning = value end,
            setWordSpacing = function(_self, value) document_calls.word_spacing = value end,
            setWordExpansion = function(_self, value) document_calls.word_expansion = value end,
            setInterlineSpacePercent = function(_self, value) document_calls.line_spacing = value end,
            setGammaIndex = function(_self, value) document_calls.font_gamma = value end,
            setFontBaseWeight = function(_self, value) document_calls.font_base_weight = value end,
            setEmbeddedStyleSheet = function(_self, value) document_calls.embedded_css = value end,
            setEmbeddedFonts = function(_self, value) document_calls.embedded_fonts = value end,
            setNightmodeImages = function(_self, value) document_calls.nightmode_images = value end,
        }
        local reader = {
            document = document,
            font = {},
            rolling = {
                onSetStatusLine = function(_self, value) document_calls.status_line = value end,
            },
            typeset = {
                onSetPageMargins = function(_self, value) document_calls.page_margins = value end,
            },
            view = {
                footer = {
                    settings = { container_bottom_padding = 1 },
                    bottom_padding = 1,
                    footer_content = { padding_bottom = 1 },
                    loadPreset = function(_self, value) loaded_preset = value end,
                    resetLayout = function(_self, force)
                        assert.is_true(force)
                        footer_resets = footer_resets + 1
                    end,
                    refreshFooter = function(_self, update, signal)
                        assert.is_true(update)
                        assert.is_true(signal)
                        footer_refreshes = footer_refreshes + 1
                    end,
                },
            },
            handleEvent = function(_self, event)
                assert.are.equal("onSetStatusLine", event.handler)
                document_calls.status_line = event.args[1]
            end,
            saveSettings = function() saved = true end,
        }
        ZenSpec.replace("apps/reader/readerui", { instance = reader })
        ZenSpec.replace("device", {
            hasColorScreen = function() return true end,
            screen = { scaleBySize = function(_self, value) return value * 2 end },
        })
        ZenSpec.unload("modules/reader/patches/reader_footer_presets")
        ZenSpec.unload("common/reader_defaults")

        local applied = require("common/reader_defaults").apply(ZenSpec.memorySettings(), {})

        assert.are.equal("(ZenOS) Chapter Time + %", loaded_preset.name)
        assert.is_true(loaded_preset.footer.chapter_time_to_read)
        assert.is_false(loaded_preset.footer.page_progress)
        assert.is_true(loaded_preset.footer.percentage)
        assert.are.equal(6, reader.view.footer.settings.container_bottom_padding)
        assert.are.equal(12, reader.view.footer.bottom_padding)
        assert.are.equal(12, reader.view.footer.footer_content.padding_bottom)
        assert.are.equal(1, footer_resets)
        assert.are.equal(1, footer_refreshes)
        assert.are.equal("Readerly R", reader.font.font_face)
        assert.are.equal("Readerly R", document_calls.font_face)
        assert.are.equal(46, document_calls.font_size)
        assert.are.equal(25, document_calls.font_gamma)
        assert.are.equal(-0.5, document_calls.font_base_weight)
        assert.are.equal(110, document_calls.line_spacing)
        assert.are.same({100, 90}, document_calls.word_spacing)
        assert.are.equal(5, document_calls.word_expansion)
        assert.are.same({30, 30, 30, 30}, document_calls.page_margins)
        assert.are.same({30, 30}, document.configurable.h_page_margins)
        assert.are.equal(1, document.configurable.sync_t_b_page_margins)
        assert.are.equal(1, document.configurable.status_line)
        assert.are.equal(1, document_calls.status_line)
        assert.is_true(saved)
        assert.is_true(applied)
    end)

    it("uses device-aware margins in every built-in footer preset", function()
        local color_presets = require("modules/reader/patches/reader_footer_presets")
        for _i, preset in ipairs(color_presets) do
            assert.are.equal(6, preset.footer.container_bottom_padding)
        end

        ZenSpec.replace("device", {
            hasColorScreen = function() return false end,
        })
        ZenSpec.unload("modules/reader/patches/reader_footer_presets")
        local monochrome_presets = require("modules/reader/patches/reader_footer_presets")
        for _i, preset in ipairs(monochrome_presets) do
            assert.are.equal(1, preset.footer.container_bottom_padding)
        end
    end)
end)
