return function()
    local Device = require("device")
    if not (Device.isKindle and Device:isKindle()) then return end

    local ok_loader, PluginLoader = pcall(require, "pluginloader")
    if not ok_loader or type(PluginLoader.loadPlugins) ~= "function" then return end

    local UIManager = require("ui/uimanager")
    for _i, plugin_class in ipairs(PluginLoader:loadPlugins() or {}) do
        if plugin_class.name == "autosuspend" then
            if plugin_class._zen_resume_time_patched or not plugin_class.onResume then return end
            local orig_onResume = plugin_class.onResume
            plugin_class.onResume = function(self, ...)
                -- Kindle may account for sleep after InputEvent recorded activity.
                self.last_action_time = UIManager:getElapsedTimeSinceBoot()
                return orig_onResume(self, ...)
            end
            plugin_class._zen_resume_time_patched = true
            return
        end
    end
end
