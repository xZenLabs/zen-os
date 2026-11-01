local function apply_unified_title_style()
    local Screen = require("device").screen
    local TitleBar = require("ui/widget/titlebar")
    local TitleStyle = require("common/ui/zen_title_style")
    if TitleBar._zen_title_style_patched then return end
    TitleBar._zen_title_style_patched = true

    local orig_init = TitleBar.init
    TitleBar.init = function(self, ...)
        local width = tonumber(self.width) or Screen:getWidth()
        local use_zen_style = self.zen_style or width >= Screen:getWidth()
        if use_zen_style then TitleStyle.applyToStockTitleBar(self) end
        local result = orig_init(self, ...)
        if use_zen_style and self.title_widget then self.title_widget.bold = true end
        -- Stock forces allow_flash = false on close buttons.
        if self.close_callback and self.right_button then
            self.right_icon_allow_flash = true
            self.right_button.allow_flash = true
        end
        return result
    end
end

return apply_unified_title_style
