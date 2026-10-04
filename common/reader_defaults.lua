local plugin_root = require("common/plugin_root") or ""
local ReaderStatusBar = require("common/reader_status_bar")
local FontLanguage = require("common/font_language")

local M = {}

local READER_FONT = "Readerly R"
local STATUS_FONT = plugin_root .. "/fonts/hyperreadable/Hyperreadable-SemiBold.ttf"
local CRE_DEFAULTS = {
    copt_h_page_margins = {30, 30},
    copt_sync_t_b_page_margins = 1,
    copt_t_page_margin = 30,
    copt_b_page_margin = 30,
    copt_word_spacing = {100, 90},
    copt_word_expansion = 5,
    copt_line_spacing = 110,
    copt_font_gamma = 25,
    copt_font_base_weight = -0.5,
    copt_font_size = 23,
    copt_font_hinting = 2,
    copt_font_kerning = 3,
    copt_embedded_css = 0,
    copt_embedded_fonts = 0,
    copt_nightmode_images = 1,
    copt_status_line = 1,
}
local KOPT_DEFAULTS = {
    kopt_contrast = 2.5,
    kopt_nightmode_document = 1,
    kopt_page_margin = 0.1,
    kopt_page_scroll = 0,
    kopt_saturation = 2,
    kopt_trim_page = 1,
    kopt_zoom_mode_genus = 4,
    kopt_zoom_mode_type = 1,
}

local function copy_value(value)
    if type(value) ~= "table" then return value end
    local copy = {}
    for key, item in pairs(value) do
        copy[key] = copy_value(item)
    end
    return copy
end

local function scale_by_size(value)
    local ok_device, Device = pcall(require, "device")
    local Screen = ok_device and Device and Device.screen
    return Screen and type(Screen.scaleBySize) == "function"
        and Screen:scaleBySize(value) or value
end

local function ensure_reader_font_registered()
    if plugin_root == "" then return end
    local ok_cre, CreDocument = pcall(require, "document/credocument")
    if not ok_cre or type(CreDocument.engineInit) ~= "function" then return end
    local ok_engine, cre = pcall(CreDocument.engineInit, CreDocument)
    if not ok_engine or type(cre) ~= "table" then return end

    if type(cre.getFontFaces) == "function" then
        local ok_faces, faces = pcall(cre.getFontFaces)
        if ok_faces and type(faces) == "table" then
            for _i, face in ipairs(faces) do
                if face == READER_FONT then return end
            end
        end
    end
    if type(cre.registerFont) ~= "function" then return end

    for _i, filename in ipairs({
        "Readerly_R-Regular.ttf",
        "Readerly_R-Bold.ttf",
        "Readerly_R-Italic.ttf",
        "Readerly_R-BoldItalic.ttf",
    }) do
        pcall(cre.registerFont, plugin_root .. "/fonts/readerly/" .. filename)
    end
    if type(cre.regularizeRegisteredFontsWeights) == "function" then
        pcall(cre.regularizeRegisteredFontsWeights, false)
    end
end

local function save_footer_preset(preset)
    local ok_store, PresetStore = pcall(require, "config/preset_store")
    if not ok_store then return end
    if type(PresetStore.saveSettings) == "function" then
        PresetStore.saveSettings("reader", {
            footer = copy_value(preset.footer),
            reader_footer_mode = preset.reader_footer_mode,
            reader_footer_custom_text = preset.reader_footer_custom_text,
            reader_footer_custom_text_repetitions = preset.reader_footer_custom_text_repetitions,
            chapter_time_format = preset.chapter_time_format,
        })
    end
    if type(PresetStore.setActivePreset) == "function" then
        PresetStore.setActivePreset("reader", preset.name)
    end
end

local function apply_to_active_reader(preset, use_bundled_fonts, reader, preserve_status_bars)
    if not reader then
        local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
        reader = ok_reader and ReaderUI and ReaderUI.instance
    end
    if not reader then return false end

    local footer = reader.view and reader.view.footer
    if not preserve_status_bars and footer and type(footer.loadPreset) == "function" then
        footer:loadPreset(copy_value(preset))
        local bottom_padding = preset.footer.container_bottom_padding
        if type(footer.settings) == "table" then
            footer.settings.container_bottom_padding = bottom_padding
        end
        footer.bottom_padding = scale_by_size(bottom_padding)
        if type(footer.footer_content) == "table" then
            footer.footer_content.padding_bottom = footer.bottom_padding
        end
        if type(footer.resetLayout) == "function" then footer:resetLayout(true) end
        if type(footer.refreshFooter) == "function" then footer:refreshFooter(true, true) end
    end

    local document = reader.document
    local configurable = document and document.configurable
    if not configurable then return false end
    if reader.paging then
        for key, value in pairs(KOPT_DEFAULTS) do
            configurable[key:sub(6)] = value
        end
        local Event = require("ui/event")
        reader:handleEvent(Event:new("GammaUpdate", KOPT_DEFAULTS.kopt_contrast, true))
        reader:handleEvent(Event:new("SaturationUpdate", KOPT_DEFAULTS.kopt_saturation, true))
        reader:handleEvent(Event:new("SetScrollMode", false))
        reader:handleEvent(Event:new("SetZoomMode", "pagewidth"))
        reader:handleEvent(Event:new("ReZoom"))
        if type(reader.saveSettings) == "function" then reader:saveSettings() end
        return true
    end
    if not reader.rolling then return false end

    for key, value in pairs(CRE_DEFAULTS) do
        if not preserve_status_bars or key ~= "copt_status_line" then
            configurable[key:sub(6)] = copy_value(value)
        end
    end
    if use_bundled_fonts and reader.font then reader.font.font_face = READER_FONT end

    if use_bundled_fonts and type(document.setFontFace) == "function" then
        document:setFontFace(READER_FONT)
    end
    if type(document.setFontSize) == "function" then
        document:setFontSize(scale_by_size(CRE_DEFAULTS.copt_font_size))
    end
    if type(document.setFontBaseWeight) == "function" then
        document:setFontBaseWeight(CRE_DEFAULTS.copt_font_base_weight)
    end
    if type(document.setFontHinting) == "function" then
        document:setFontHinting(CRE_DEFAULTS.copt_font_hinting)
    end
    if type(document.setFontKerning) == "function" then
        document:setFontKerning(CRE_DEFAULTS.copt_font_kerning)
    end
    if type(document.setWordSpacing) == "function" then
        document:setWordSpacing(copy_value(CRE_DEFAULTS.copt_word_spacing))
    end
    if type(document.setWordExpansion) == "function" then
        document:setWordExpansion(CRE_DEFAULTS.copt_word_expansion)
    end
    if type(document.setInterlineSpacePercent) == "function" then
        document:setInterlineSpacePercent(CRE_DEFAULTS.copt_line_spacing)
    end
    if type(document.setGammaIndex) == "function" then
        document:setGammaIndex(CRE_DEFAULTS.copt_font_gamma)
    end
    if type(document.setEmbeddedStyleSheet) == "function" then
        document:setEmbeddedStyleSheet(CRE_DEFAULTS.copt_embedded_css)
    end
    if type(document.setEmbeddedFonts) == "function" then
        document:setEmbeddedFonts(CRE_DEFAULTS.copt_embedded_fonts)
    end
    if type(document.setNightmodeImages) == "function" then
        document:setNightmodeImages(true)
    end

    local typeset = reader.typeset
    if typeset and type(typeset.onSetPageMargins) == "function" then
        typeset.unscaled_margins = {30, 30, 30, 30}
        typeset.sync_t_b_page_margins = true
        typeset:onSetPageMargins(typeset.unscaled_margins)
    end
    if type(reader.saveSettings) == "function" then reader:saveSettings() end
    return true
end

function M.apply(settings, config)
    local use_bundled_fonts = FontLanguage.supportsBundledFonts()
    if use_bundled_fonts then
        ensure_reader_font_registered()
        settings:saveSetting("cre_font", READER_FONT)
    end
    for key, value in pairs(CRE_DEFAULTS) do
        settings:saveSetting(key, copy_value(value))
    end
    for key, value in pairs(KOPT_DEFAULTS) do
        settings:saveSetting(key, value)
    end
    ReaderStatusBar.disableKoreaderAltStatusBar(settings)

    local preset = copy_value(require("modules/reader/patches/reader_footer_presets")[1])
    if use_bundled_fonts then
        preset.footer.text_font_face = STATUS_FONT
        preset.footer.text_font_bold = false
    else
        local existing_footer = settings:readSetting("footer")
        if type(existing_footer) == "table" then
            if type(existing_footer.text_font_face) == "string" then
                preset.footer.text_font_face = existing_footer.text_font_face
            end
            if type(existing_footer.text_font_bold) == "boolean" then
                preset.footer.text_font_bold = existing_footer.text_font_bold
            end
        end
    end
    local ok_device, Device = pcall(require, "device")
    local is_color = ok_device and Device and type(Device.hasColorScreen) == "function"
        and Device:hasColorScreen()
    preset.footer.container_bottom_padding = is_color and 6 or 1
    settings:saveSetting("footer", copy_value(preset.footer))
    settings:saveSetting("reader_footer_mode", preset.reader_footer_mode)
    settings:saveSetting("reader_footer_custom_text", preset.reader_footer_custom_text)
    settings:saveSetting("reader_footer_custom_text_repetitions",
        preset.reader_footer_custom_text_repetitions)

    if type(config.reader_top_status_bar) ~= "table" then
        config.reader_top_status_bar = {}
    end
    if use_bundled_fonts then
        config.reader_top_status_bar.font_face = STATUS_FONT
    end
    config.reader_top_status_bar.left_order = {}
    config.reader_top_status_bar.center_order = { "time" }
    config.reader_top_status_bar.right_order = {}
    if type(config.reader_footer) ~= "table" then
        config.reader_footer = {}
    end
    config.reader_footer.chapter_time_format = preset.chapter_time_format
    if type(config.features) ~= "table" then
        config.features = {}
    end
    config.features.reader_top_status_bar = true

    save_footer_preset(preset)
    return apply_to_active_reader(preset, use_bundled_fonts)
end

function M.applyDeferredToReader(reader)
    local use_bundled_fonts = FontLanguage.supportsBundledFonts()
    if use_bundled_fonts then ensure_reader_font_registered() end
    return apply_to_active_reader(nil, use_bundled_fonts, reader, true)
end

return M
