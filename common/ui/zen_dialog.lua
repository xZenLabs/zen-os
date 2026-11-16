-- common/zen_dialog.lua
-- Factory for a Zen-styled InputDialog:
--   - Close (X) icon in the title bar top-right
--   - Single primary button whose text carries the action icon
--   - Outside-tap dismisses both keyboard and dialog
--
-- Usage:
--   local createZenDialog = require("common/ui/zen_dialog")
--   local dialog = createZenDialog{
--       title           = _("Go to page"),
--       input           = "",
--       input_type      = "number",
--       input_hint      = "1 - 42",
--       button_text     = icons.go .. " " .. _("Go"),
--       button_callback = function() ... end,
--       -- close_callback: optional, called when X is tapped
--   }
--   UIManager:show(dialog)
--   dialog:onShowKeyboard()

local InputDialog = require("ui/widget/inputdialog")
local UIManager   = require("ui/uimanager")
local ZenModalClose = require("common/ui/zen_modal_close")

local function createZenDialog(opts)
    local orig_onTap = InputDialog.onTap
    local dialog

    dialog = InputDialog:new{
        title      = opts.title,
        input      = opts.input or "",
        input_type = opts.input_type,
        input_hint = opts.input_hint,
        buttons = {
            {
                {
                    text             = opts.button_text,
                    is_enter_default = true,
                    callback         = function() opts.button_callback(dialog) end,
                },
            },
        },
    }
    ZenModalClose.installDialog(dialog, function()
        UIManager:close(dialog)
        if opts.close_callback then opts.close_callback() end
    end)

    -- Close both keyboard and dialog on outside tap (mirrors search dialog behaviour).
    function dialog:onTap(arg, ges)
        if self.deny_keyboard_hiding then return end
        if self:isKeyboardVisible() then
            local kb = self._input_widget and self._input_widget.keyboard
            if kb and kb.dimen
               and ges.pos:notIntersectWith(kb.dimen)
               and ges.pos:notIntersectWith(self.dialog_frame.dimen) then
                self:onCloseKeyboard()
                UIManager:close(self)
                return true
            end
            return orig_onTap(self, arg, ges)
        else
            if ges.pos:notIntersectWith(self.dialog_frame.dimen) then
                UIManager:close(self)
                return true
            end
        end
    end

    return dialog
end

return createZenDialog
