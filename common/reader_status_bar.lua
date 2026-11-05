local M = {}

function M.getHeaderFace(cfg)
    local Font = require("ui/font")
    local footer_settings = G_reader_settings:readSetting("footer")
    local face_cfg = type(cfg) == "table" and cfg.font_face or "default"
    local font_name = face_cfg == "default"
        and ((footer_settings and footer_settings.text_font_face) or "NotoSans-Regular.ttf")
        or face_cfg
    local font_size = type(cfg) == "table" and cfg.font_size or 14
    return Font:getFace(font_name, font_size) or Font:getFace("cfont", font_size)
end

function M.getFooterForSettings()
    local ReaderUI = require("apps/reader/readerui")
    local reader = ReaderUI.instance
    if reader and reader.view and reader.view.footer then return reader.view.footer end

    local ReaderFooter = require("apps/reader/modules/readerfooter")
    local util = require("util")
    local settings = util.tableDeepCopy(ReaderFooter.default_settings)
    for key, value in pairs(G_reader_settings:readSetting("footer") or {}) do
        settings[key] = value
    end
    local function save(self) G_reader_settings:saveSetting("footer", self.settings) end
    local function noop() end
    -- Reuse the native menus without document layout, painting, or refresh timers.
    local footer = setmetatable({
        settings = settings,
        ui = {
            document = { info = { has_pages = true } },
            bookinfo = require("apps/filemanager/filemanagerbookinfo"),
        },
        view = {},
        footer_text = { height = 0 },
        progress_bar = { updateStyle = noop },
        percent_finished = 0,
        mode = G_reader_settings:readSetting("reader_footer_mode") or 1,
        custom_text = G_reader_settings:readSetting("reader_footer_custom_text") or "KOReader",
        custom_text_repetitions = tonumber(G_reader_settings:readSetting("reader_footer_custom_text_repetitions")) or 1,
        refreshFooter = save,
        onUpdateFooter = save,
        updateFooterFont = noop,
        updateFooterTextGenerator = function() return true end,
        rescheduleFooterAutoRefreshIfNeeded = save,
        setTocMarkers = noop,
        getHeight = function() return 0 end,
        applyFooterMode = function(self, mode)
            self.mode = mode or self.mode
            self.view.footer_visible = self.mode ~= self.mode_list.off
        end,
        onToggleChapterProgressBar = function(self)
            self.settings.chapter_progress_bar = not self.settings.chapter_progress_bar
            save(self)
        end,
    }, { __index = ReaderFooter })
    footer:set_mode_index()
    local Device = require("device")
    local capabilities = {
        battery = "hasBattery", frontlight = "hasFrontlight",
        frontlight_warmth = "hasNaturalLight", wifi_status = "hasFastWifiStatusQuery",
    }
    for i = #footer.mode_index, 1, -1 do
        local capability = capabilities[footer.mode_index[i]]
        if capability and not Device[capability](Device) then
            table.remove(footer.mode_index, i)
        end
    end
    footer.mode_nb = #footer.mode_index + 1
    footer.mode_list = {}
    for i = 0, #footer.mode_index do footer.mode_list[footer.mode_index[i]] = i end
    footer:set_has_no_mode()
    footer.reclaim_height = settings.reclaim_height
    footer:applyFooterMode()
    footer.preset_obj = {
        presets = G_reader_settings:readSetting("footer_presets") or {},
        dispatcher_name = "load_footer_preset",
        buildPreset = function() return footer:buildPreset() end,
        loadPreset = function(preset) footer:loadPreset(preset) end,
    }
    save(footer)
    return footer
end

local TOP_TAP_HIDDEN = "zen_top_bar_tap_hidden"

-- Which bar(s) a status bar tap hides: "bottom", "top" or "both"; false when lock_tap is on.
function M.getTapHide(plugin, footer)
    if footer and footer.settings and footer.settings.lock_tap then return false end
    local fcfg = plugin and plugin.config and plugin.config.reader_footer
    return type(fcfg) == "table" and fcfg.tap_hide or "both"
end

function M.isTopBarTapHidden(plugin, footer)
    return M.getTapHide(plugin, footer) == "top" and G_reader_settings:isTrue(TOP_TAP_HIDDEN)
end

function M.resetTopBarTapHidden()
    G_reader_settings:delSetting(TOP_TAP_HIDDEN)
end

function M.toggleTopBar(view)
    G_reader_settings:flipNilOrFalse(TOP_TAP_HIDDEN)
    require("ui/uimanager"):setDirty(view.dialog, "ui", view._zen_header_dimen)
end

-- Off <-> on regardless of all_at_once (stock tap cycles items when it's off).
function M.toggleFooter(footer)
    local off = footer.mode_list.off
    if footer.mode == off then
        if not footer._zen_tap_mode then return footer:onToggleFooterMode() end
        footer.mode = footer._zen_tap_mode
    else
        footer._zen_tap_mode = footer.mode
        footer.mode = off
    end
    footer:applyFooterMode()
    G_reader_settings:saveSetting("reader_footer_mode", footer.mode)
    footer:onUpdateFooter(true)
    footer:rescheduleFooterAutoRefreshIfNeeded()
    return true
end

function M.isMarginAlignmentEnabled(plugin)
    local features = plugin and plugin.config and plugin.config.features
    return features and features.reader_status_bar_margins == true or false
end

function M.getHorizontalMargins(document, fallback, plugin)
    if not M.isMarginAlignmentEnabled(plugin) then return fallback, fallback end
    if document and type(document.getPageMargins) == "function" then
        local margins = document:getPageMargins()
        return margins.left, margins.right
    end
    local margins = document and document.configurable and document.configurable.h_page_margins
    if not margins then return fallback, fallback end
    local Screen = require("device").screen
    return Screen:scaleBySize(margins[1]), Screen:scaleBySize(margins[2])
end

function M.disableKoreaderAltStatusBar(settings, reader)
    settings = settings or rawget(_G, "G_reader_settings")
    if settings and type(settings.saveSetting) == "function" then
        settings:saveSetting("copt_status_line", 1)
        settings:saveSetting("alt_status_bar", false)
    end

    if reader == nil then
        local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
        reader = ok_reader and ReaderUI and ReaderUI.instance
    end
    local configurable = reader and reader.document and reader.document.configurable
    if not (reader and reader.rolling and configurable) then return false end

    configurable.status_line = 1
    if type(reader.handleEvent) == "function" then
        local Event = require("ui/event")
        reader:handleEvent(Event:new("SetStatusLine", 1))
    elseif type(reader.rolling.onSetStatusLine) == "function" then
        reader.rolling:onSetStatusLine(1)
    end
    return true
end

return M
