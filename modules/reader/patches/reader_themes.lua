local function apply_reader_themes()
    local CreDocument = require("document/credocument")
    local Device = require("device")
    local UIManager = require("ui/uimanager")
    local ReaderFooter = require("apps/reader/modules/readerfooter")
    local ReaderTypeset = require("apps/reader/modules/readertypeset")
    local ReaderUI = require("apps/reader/readerui")
    local ReaderThemes = require("common/reader_themes")
    local plugin = rawget(_G, "__ZEN_UI_PLUGIN")

    if CreDocument._zen_reader_themes then return true end
    CreDocument._zen_reader_themes = true

    local orig_setStyleSheet = CreDocument.setStyleSheet
    CreDocument.setStyleSheet = function(self, css_file, appended_css)
        return orig_setStyleSheet(self, css_file, ReaderThemes.appendCss(plugin, appended_css, self))
    end

    local Screen = Device.screen
    local orig_refreshPartialImp = Screen.refreshPartialImp
    Screen.refreshPartialImp = function(self, x, y, w, h, dither)
        if not self.waveform_full or not ReaderUI.instance
                or not (ReaderThemes.isActive(plugin) or (self.night_mode
                    and Device.isKindle and Device:isKindle()
                    and Device.hasColorScreen and Device:hasColorScreen())) then
            return orig_refreshPartialImp(self, x, y, w, h, dither)
        end
        -- GC16 + PARTIAL handles tinted backgrounds without a full-screen flash.
        local partial, night, night_is_reagl = self.waveform_partial, self.waveform_night, self.night_is_reagl
        self.waveform_partial, self.waveform_night, self.night_is_reagl = self.waveform_full, self.waveform_full, false
        -- Dithering would promote GC16 to a flashing color waveform.
        local ok, result = pcall(orig_refreshPartialImp, self, x, y, w, h, false)
        self.waveform_partial, self.waveform_night, self.night_is_reagl = partial, night, night_is_reagl
        if not ok then error(result, 0) end
        return result
    end

    local orig_onReadSettings = ReaderTypeset.onReadSettings
    ReaderTypeset.onReadSettings = function(self, ...)
        local result = orig_onReadSettings(self, ...)
        ReaderThemes.applyBackground(self.ui, plugin)
        ReaderThemes.applyFont(self.ui, plugin)
        return result
    end

    local orig_updateFooterContainer = ReaderFooter.updateFooterContainer
    ReaderFooter.updateFooterContainer = function(self, ...)
        local result = orig_updateFooterContainer(self, ...)
        ReaderThemes.applyFooterColors(self, plugin)
        return result
    end

    local orig_updateFooterFont = ReaderFooter.updateFooterFont
    ReaderFooter.updateFooterFont = function(self, ...)
        local result = orig_updateFooterFont(self, ...)
        ReaderThemes.applyFooterColors(self, plugin)
        return result
    end

    local orig_shouldBeRepainted = ReaderFooter.shouldBeRepainted
    if type(orig_shouldBeRepainted) == "function" then
        ReaderFooter.shouldBeRepainted = function(self, ...)
            local repaint, full_repaint = orig_shouldBeRepainted(self, ...)
            -- A transparent footer needs ReaderView to redraw its backdrop first.
            if repaint and not full_repaint and ReaderThemes.isActive(plugin) then
                return true, true
            end
            return repaint, full_repaint
        end
    end

    local orig_doShowReader = ReaderUI.doShowReader
    ReaderUI.doShowReader = function(self, ...)
        local result = orig_doShowReader(self, ...)
        local reader = ReaderUI.instance
        if reader and reader.document and ReaderThemes.isActive(plugin) then
            -- The themed background replaces a visually busy library page.
            ReaderThemes.refreshFull()
        end
        return result
    end

    local orig_toggleNightMode = Screen.toggleNightMode
    Screen.toggleNightMode = function(self, ...)
        local result = orig_toggleNightMode(self, ...)
        local reader = ReaderUI.instance
        if reader and reader.document and ReaderThemes.isEnabled(plugin) then
            UIManager:nextTick(function()
                ReaderThemes.applyCurrent(plugin)
            end)
        end
        return result
    end
    return true
end

return apply_reader_themes
