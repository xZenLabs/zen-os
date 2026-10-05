local M = {}

local function callback_result(ok, ...)
    if ok then return ... end
    require("common/zen_logger").new("lookup_plugin_items").err("lookup action failed:", ...)
    local _ = require("gettext")
    require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
        text = _("Dictionary lookup") .. ": " .. _("Unknown error"),
    })
end

function M.safeCallback(callback)
    if type(callback) ~= "function" then return nil end
    return function(...)
        return callback_result(pcall(callback, ...))
    end
end

function M.protectButtons(buttons)
    for _i, row in ipairs(buttons) do
        for _j, button in ipairs(row) do
            button.callback = M.safeCallback(button.callback)
            button.hold_callback = M.safeCallback(button.hold_callback)
        end
    end
end

function M.settingForHighlightKey(key)
    if type(key) ~= "string" then return nil end
    local name = key:match("^%d+_(.*)$") or key
    if name == "xray_lookup" then return "show_xray" end
    if name:find("koassistant", 1, true) then return "show_koassistant" end
    if name == "ai_assistant" or name:sub(1, 10) == "assistant_" then
        return "show_ai_assistant"
    end
end

function M.settingForDictButton(button)
    if type(button) ~= "table" then return nil end
    local id = button.id
    if id == "xray_lookup" then return "show_xray" end
    if type(id) == "string" then
        if id:sub(1, 17) == "koassistant_dict_" then return "show_koassistant" end
        if id:sub(1, 10) == "assistant_" then return "show_ai_assistant" end
    end

    local label = button.text
    if type(label) ~= "string" and type(button.text_func) == "function" then
        local ok, text = pcall(button.text_func)
        if ok then label = text end
    end
    if label == "X-Ray" then return "show_xray" end
    if type(label) == "string" and label:sub(-6) == " (KOA)" then
        return "show_koassistant"
    end
end

function M.shouldShow(config, setting)
    local lookup = type(config) == "table" and config.highlight_lookup
    if type(lookup) ~= "table" then return false end
    if setting then return lookup[setting] ~= false end
    return lookup.allow_unknown_items == true
end

return M
