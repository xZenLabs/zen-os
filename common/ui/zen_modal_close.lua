local Device = require("device")
local ZenIconButton = require("common/ui/zen_icon_button")
local utils = require("common/utils")

local M = {}

local root = require("common/plugin_root")
local close_icon_path = root and utils.resolveLocalIcon(root .. "/icons/", "close")

local function supports_focus()
    local is_non_touch = type(Device.isTouchDevice) == "function" and not Device:isTouchDevice()
    local has_dpad = type(Device.hasDPad) == "function" and Device:hasDPad()
    local has_keyboard = type(Device.hasKeyboard) == "function" and Device:hasKeyboard()
    return is_non_touch or has_dpad or has_keyboard
end

local function replace_right_button(title_bar, parent)
    local old_button = title_bar.right_button
    if not (old_button and close_icon_path) then return nil end

    local close_button = ZenIconButton:new{
        file = close_icon_path,
        width = old_button.width,
        height = old_button.height,
        padding = old_button.padding,
        padding_top = old_button.padding_top,
        padding_right = old_button.padding_right,
        padding_bottom = old_button.padding_bottom,
        padding_left = old_button.padding_left,
        overlap_align = old_button.overlap_align,
        overlap_offset = old_button.overlap_offset,
        callback = old_button.callback,
        hold_callback = old_button.hold_callback,
        allow_flash = true,
        show_parent = parent,
    }
    for i = 1, #title_bar do
        if rawequal(title_bar[i], old_button) then
            title_bar[i] = close_button
            break
        end
    end
    title_bar.right_button = close_button
    if type(old_button.free) == "function" then old_button:free() end
    return close_button
end

function M.installTitleBar(title_bar, parent, callback)
    if not (title_bar and close_icon_path) then return nil end
    title_bar.not_focusable = true
    title_bar.right_icon = close_icon_path
    title_bar.right_icon_tap_callback = callback
    title_bar.right_icon_allow_flash = true
    title_bar:clear()
    title_bar:init()
    return replace_right_button(title_bar, parent)
end

function M.addToFocusLayout(dialog, close_button)
    if not (close_button and supports_focus() and dialog.layout) then return end
    for _i, row in ipairs(dialog.layout) do
        for _j, widget in ipairs(row) do
            if rawequal(widget, close_button) then return end
        end
    end
    table.insert(dialog.layout, 1, { close_button })
    if dialog.selected then dialog.selected.y = dialog.selected.y + 1 end
end

local function apply_dialog(dialog)
    local close_button = M.installTitleBar(
        dialog.title_bar, dialog, dialog._zen_modal_close_callback
    )
    M.addToFocusLayout(dialog, close_button)
    return close_button
end

function M.installDialog(dialog, callback)
    if not dialog then return nil end
    dialog._zen_modal_close_callback = callback
    if not dialog._zen_modal_close_init then
        dialog._zen_modal_close_init = dialog.init
        dialog.init = function(self, ...)
            local result = self._zen_modal_close_init(self, ...)
            apply_dialog(self)
            return result
        end
    end
    return apply_dialog(dialog)
end

return M
