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
        -- PARTIAL updates with a 16-gray waveform tint pages without a full-screen flash: the "ui"
        -- waveform (GL16-class) fades changed pixels, GC16 clears ghosting but flashes each of them.
        local waveform = ReaderThemes.cleanPageTurns(plugin) and self.waveform_full
            or self.waveform_ui or self.waveform_full
        local partial, night, night_is_reagl = self.waveform_partial, self.waveform_night, self.night_is_reagl
        self.waveform_partial, self.waveform_night, self.night_is_reagl = waveform, waveform, false
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
        if not self.ui.doc_settings:readSetting("font_face") then
            ReaderThemes.applyFont(self.ui, plugin)
        end
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

    -- Restore the rendered CRE page under the last painted footer, like the top status bar.
    local function restoreFooterBackdrop(footer)
        local view = footer.view
        local dimen = footer.footer_content and footer.footer_content.dimen
        local buffer = view and view.render_mode == nil and view.document and view.document.buffer
        local offset = view and view.state and view.state.offset
        if not (dimen and dimen.w and buffer and offset and Screen.bb) then return false end
        local sx, sy = dimen.x - offset.x, dimen.y - offset.y
        if sx < 0 or sy < 0 or sx + dimen.w > buffer:getWidth() or sy + dimen.h > buffer:getHeight() then
            return false
        end
        Screen.bb:blitFrom(buffer, dimen.x, dimen.y, sx, sy, dimen.w, dimen.h)
        return true
    end

    local orig_shouldBeRepainted = ReaderFooter.shouldBeRepainted
    if type(orig_shouldBeRepainted) == "function" then
        ReaderFooter.shouldBeRepainted = function(self, ...)
            local repaint, full_repaint = orig_shouldBeRepainted(self, ...)
            -- A transparent footer needs its backdrop redrawn first; fall back to a full ReaderView repaint.
            if repaint and not full_repaint and ReaderThemes.isActive(plugin)
                    and not restoreFooterBackdrop(self) then
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
