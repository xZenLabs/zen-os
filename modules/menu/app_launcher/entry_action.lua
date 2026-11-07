local UIManager = require("ui/uimanager")
local SettingsTransition = require("common/settings_transition")
local _ = require("gettext")

return function(entry, touch_menu, plugin, scope)
    if entry.enabled == false then return false end
    if entry.type == "quick_setting" then
        local controls = rawget(_G, "__ZEN_UI_QUICK_SETTINGS")
        if controls and controls.activate and controls.activate(entry.quick_setting_id, touch_menu) then return true end
    else
        local launch
        if entry.type == "action" and type(entry.action) == "table" and next(entry.action) then
            launch = function() require("dispatcher"):execute(entry.action) end
        elseif entry.type == "plugin" and entry.plugin then
            launch = require("modules/menu/app_launcher/plugin_scan").resolve(entry.plugin.key, entry.plugin.method)
        elseif entry.type == "koreader_menu" and entry.koreader_menu then
            launch = require("modules/menu/app_launcher/native_menu").resolve(entry.koreader_menu.id, scope or "active")
        elseif entry.type == "folder_shortcut" or entry.type == "tag" then
            launch = function() require("common/nav_button_model").execute(entry, plugin) end
        end
        if launch then
            if touch_menu then touch_menu:closeMenu() end
            SettingsTransition.close()
            UIManager:nextTick(function()
                local ok = pcall(launch)
                if not ok then
                    UIManager:show(require("ui/widget/infomessage"):new{ text = _("This action is not available.") })
                end
            end)
            return true
        end
    end
    UIManager:show(require("ui/widget/infomessage"):new{ text = _("This action is not available.") })
    return false
end
