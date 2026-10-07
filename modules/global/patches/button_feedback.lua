return function()
    local Button = require("ui/widget/button")
    local IconButton = require("ui/widget/iconbutton")
    local BD = require("ui/bidi")
    local Feedback = require("common/ui/button_feedback")
    local Geom = require("ui/geometry")
    local UIManager = require("ui/uimanager")
    if Button._zen_feedback_patched then return end
    Button._zen_feedback_patched = true

    function Button:_doFeedbackHighlight()
        if self.allow_flash == false then return end
        local dimen = self.bordersize == 0 and self.label_widget and self.label_widget.is_icon
            and self.label_widget.dimen or self.dimen
        self._zen_feedback_region = (self.vsync or dimen == self.dimen
            or self.icon and self.icon:sub(1, 8) == "chevron.") and Geom:new{
            x = dimen.x, y = dimen.y, w = dimen.w, h = dimen.h,
        }
            or Feedback.paddedRegion(dimen)
        Feedback.invert(self._zen_feedback_region)
        UIManager:setDirty(nil, "ui", self._zen_feedback_region)
    end

    function Button:_undoFeedbackHighlight(is_translucent)
        local region = self._zen_feedback_region
        if not region then return end
        self._zen_feedback_region = nil
        if self.vsync then
            UIManager:widgetRepaint(self, self.dimen.x, self.dimen.y)
        else
            Feedback.invert(region)
        end
        UIManager:setDirty(is_translucent and self.show_parent or nil,
            "ui", region)
    end

    local orig_paint_to = Button.paintTo
    function Button:paintTo(...)
        orig_paint_to(self, ...)
        if self.vsync and self._zen_feedback_region then
            Feedback.invert(self._zen_feedback_region)
        end
    end

    function IconButton:onTapIconButton()
        if not self.callback or self.skip_paint then return end
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
