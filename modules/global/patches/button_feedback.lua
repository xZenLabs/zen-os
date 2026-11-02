return function()
    local Button = require("ui/widget/button")
    local IconButton = require("ui/widget/iconbutton")
    local BD = require("ui/bidi")
    local Feedback = require("common/ui/button_feedback")
    local Device = require("device")
    local Geom = require("ui/geometry")
    local UIManager = require("ui/uimanager")
    if Button._zen_feedback_patched then return end
    Button._zen_feedback_patched = true

    local Screen = Device.screen
    local orig_refresh_ui = Screen.refreshUI
    function Screen:refreshUI(x, y, w, h, dither)
        -- Full waveform only for color feedback regions; AUTO flashes their refresh rectangle.
        if self.mech_refresh and self.waveform_full and self:isColorScreen() and not self.night_mode
                and Feedback.consumeRegion(x, y, w, h) then
            x, y, w, h = self:calculateRealCoordinates(x, y, w, h)
            if Device.isSunxi and Device:isSunxi() then
                return self:mech_refresh(false, false, self.waveform_full, x, y, w, h, false)
            end
            return self:mech_refresh(false, self.waveform_full, x, y, w, h, false)
        end
        return orig_refresh_ui(self, x, y, w, h, dither)
    end

    function Button:_doFeedbackHighlight()
        if self.enabled == false or self.allow_flash == false then return end
        local dimen = self.bordersize == 0 and self.label_widget and self.label_widget.is_icon
            and self.label_widget.dimen or self.dimen
        self._zen_feedback_region = (self.vsync or dimen == self.dimen
            or self.icon and self.icon:sub(1, 8) == "chevron.") and Geom:new{
            x = dimen.x, y = dimen.y, w = dimen.w, h = dimen.h,
        }
            or Feedback.paddedRegion(dimen)
        self._zen_feedback_pixels = Feedback.highlight(self._zen_feedback_region)
        Feedback.setDirty(nil, Feedback.getRefreshMode(), self._zen_feedback_region)
    end

    function Button:_undoFeedbackHighlight(is_translucent)
        local region = self._zen_feedback_region
        if not region then return end
        self._zen_feedback_region = nil
        local saved = self._zen_feedback_pixels
        self._zen_feedback_pixels = nil
        if self.vsync then
            if saved then saved.bb:free() end
            UIManager:widgetRepaint(self, self.dimen.x, self.dimen.y)
        else
            Feedback.restore(region, saved)
        end
        Feedback.setDirty(is_translucent and self.show_parent or nil, "ui", region)
    end

    local orig_paint_to = Button.paintTo
    function Button:paintTo(...)
        orig_paint_to(self, ...)
        if self.vsync and self._zen_feedback_region then
            if self._zen_feedback_pixels then self._zen_feedback_pixels.bb:free() end
            self._zen_feedback_pixels = Feedback.highlight(self._zen_feedback_region)
        end
    end

    function IconButton:onTapIconButton()
        if self.enabled == false then return true end
        if not self.callback or self.skip_paint then return end
        if self.allow_flash == false or G_reader_settings:isFalse("flash_ui") then
            self.callback()
            return true
        end
        local padding = BD.mirroredUILayout() and self.padding_right or self.padding_left
        Feedback.flash(Feedback.paddedRegion(Geom:new{
            x = self.dimen.x + padding, y = self.dimen.y + self.padding_top,
            w = self.width, h = self.height,
        }))
        self.callback()
        if not G_reader_settings:isFalse("flash_ui") then UIManager:forceRePaint() end
        return true
    end
end
