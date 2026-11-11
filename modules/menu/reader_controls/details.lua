local Settings = require("modules/menu/reader_controls/settings")
local UIManager = require("ui/uimanager")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template
local M = {}

function M.show(reader, name, apply, refresh, anchor, side)
    local options = Settings.options(reader)
    local is_font = name == "font_face"
    local option = options[name]
    if not option and not is_font then return end
    local params = option and option.more_options_param or {}
    local prefix = Settings.group(reader) .. "_"
    local current = is_font and reader.font.font_face or reader.document.configurable[name]
    local default = G_reader_settings:readSetting(is_font and "cre_font" or prefix .. name)
    if default == nil then
        if is_font then default = reader.document.default_font else default = option.default_value end
    end
    if params.names then
        current, default = {}, {}
        for i, key in ipairs(params.names) do
            current[i] = reader.document.configurable[key]
            default[i] = G_reader_settings:readSetting(prefix .. key)
            if default[i] == nil then default[i] = options[key].default_value end
        end
    end
    local title = is_font and _("Font family") or params.name_text or Settings.label(reader, option)
    local syncable = params.names or name == "h_page_margins"
    local synced = syncable and Settings.syncedMargins(reader, name)
    local dialog
    local function close()
        UIManager:close(dialog)
        refresh()
    end
    local function commit(value)
        apply(name, util.tableDeepCopy(value))
        if is_font then reader.font:onSaveSettings() end
    end
    local actions = {
        {{ text = _("Set as default"), callback = function()
            local value = util.tableDeepCopy(current)
            local display = is_font and value or Settings.valueText(reader, option, value)
            close()
            UIManager:show(require("ui/widget/confirmbox"):new{
                text = T(_("Set default %1 to %2?"), title, display),
                ok_text = _("Set as default"), ok_callback = function()
                    if params.names then
                        for i, key in ipairs(params.names) do G_reader_settings:saveSetting(prefix .. key, value[i]) end
                    else
                        G_reader_settings:saveSetting(is_font and "cre_font" or prefix .. name, value)
                    end
                    refresh()
                end,
            })
        end }},
        {{ text = _("Reset"), enabled = default ~= nil, callback = function()
            local value = util.tableDeepCopy(default)
            if synced then
                local mean = math.floor((value[1] + value[2]) / 2 + 0.5)
                value = { mean, mean }
            end
            commit(value)
            close()
        end }},
    }
    local spec = not is_font and Settings.slider(reader, name, nil, side)
    if spec and spec.pick then
        table.insert(actions, 1, {{ text = _("Set value"), callback = function()
            close()
            spec.pick(commit)
        end }})
    end
    if syncable then
        table.insert(actions, 1, {{ text = (synced and "✓ " or "") .. _("Sync"), callback = function()
            if not synced then
                local mean = math.floor((current[1] + current[2]) / 2 + 0.5)
                commit({ mean, mean })
            end
            Settings.setMarginSync(reader, name, not synced)
            close()
        end }})
    end
    dialog = require("common/ui/zen_anchored_menu").new{
        title = title, buttons = actions, anchor = anchor, anchor_right = true, close_callback = refresh,
    }
    dialog._reader_setting = name
    UIManager:show(dialog)
    return dialog
end

return M
