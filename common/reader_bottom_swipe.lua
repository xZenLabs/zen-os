local M = {}

function M.hasTarget(config)
    local cfg = config.reader_bottom_swipe
    local entry = type(cfg) == "table" and type(cfg.entries) == "table" and cfg.entries[1]
    if type(entry) ~= "table" or entry.enabled == false then return false end
    if entry.type == "action" and type(entry.action) == "table" then
        for key in pairs(entry.action) do
            if key ~= "settings" then return true end
        end
    elseif entry.type == "quick_setting" then
        return type(entry.quick_setting_id) == "string" and entry.quick_setting_id ~= ""
    elseif entry.type == "plugin" then
        local target = entry.plugin
        return type(target) == "table" and type(target.key) == "string" and target.key ~= ""
            and type(target.method) == "string" and target.method ~= ""
    elseif entry.type == "koreader_menu" then
        local target = entry.koreader_menu
        return type(target) == "table" and type(target.id) == "string" and target.id ~= ""
    end
    return false
end

function M.getMode(config)
    local cfg = config.reader_bottom_swipe
    local mode = type(cfg) == "table" and cfg.mode
    if mode == "custom" and not M.hasTarget(config) then return "none" end
    if mode == "reader_controls" or mode == "koreader" or mode == "page_browser" or mode == "none" or mode == "custom" then
        return mode
    end
    local features = config.features or {}
    if features.page_browser == true then return "page_browser" end
    return features.reader_bottom_menu == true and "koreader" or "none"
end

function M.isEnabled(config)
    local lockdown = config.features and config.features.lockdown_mode == true
        and config.lockdown
    return M.getMode(config) ~= "none"
        and not (type(lockdown) == "table" and lockdown.disable_bottom_menu_swipe)
end

return M
