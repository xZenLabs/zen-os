-- "Hide connection alerts": drops routine Wi-Fi and Bluetooth state notices; problems still show.
local _ = require("gettext")

local M = {}
local plugin

function M.hidden()
    local developer = plugin and plugin.config and plugin.config.developer
    return type(developer) == "table" and developer.hide_connection_alerts == true
end

-- KOReader builds its own notices in local functions: the text is the only handle.
local function upstream_alert(text)
    return text == _("Keyboard connected") or text == _("Keyboard disconnected") -- externalkeyboard.koplugin
        or text == _("Turning on Wi-Fi…") or text == _("Turning off Wi-Fi…") or text == _("Wi-Fi off.")
end

function M.apply()
    plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    local UIManager = require("ui/uimanager")
    if UIManager._zen_connection_alerts then return end
    UIManager._zen_connection_alerts = true
    local show = UIManager.show
    UIManager.show = function(self, widget, ...)
        if widget and M.hidden() and upstream_alert(widget.text) then return end
        return show(self, widget, ...)
    end
end

return M
