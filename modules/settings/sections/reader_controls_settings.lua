local _ = require("gettext")
local Buttons = require("modules/menu/reader_controls/buttons")
local icons = require("common/inline_icon_map")
local M = {}

function M.build(ctx)
    local config = ctx.config
    local cfg = Buttons.ensure(config)
    local editor_ctx = {}
    for key, value in pairs(ctx) do editor_ctx[key] = value end
    editor_ctx.button_config = cfg
    editor_ctx.button_scope = "reader"
    editor_ctx.save_buttons = function() ctx.save_and_apply("reader_controls") end
    editor_ctx.button_can_enable = function(entry)
        if Buttons.canEnable(config, entry) then return true end
        require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
            text = _("Maximum 8 reader controls per book"),
        })
        return false
    end
    editor_ctx.button_add_items = function()
        local Model = require("modules/menu/app_launcher/model")
        local present, items = {}, {}
        for _i, entry in ipairs(cfg.entries) do if entry.control then present[entry.control] = true end end
        for _i, entry in ipairs(Buttons.defaults()) do
            if not present[entry.control] then
                items[#items + 1] = { text = Model.display_label(entry), callback = function(menu)
                    entry.enabled = editor_ctx.button_can_enable(entry)
                    cfg.entries[#cfg.entries + 1] = entry
                    editor_ctx.save_buttons()
                    if menu then menu:backToUpperMenu() end
                end }
            end
        end
        return items
    end
    return {
        text = _("Reader controls"),
        icon_glyph = icons.settings_reader,
        help_text = _("Bottom menu containing reader settings and tools."),
        sub_item_table = {
            {
                text = _("Buttons") .. " \u{25B8}",
                icon_glyph = icons.action,
                keep_menu_open = true,
                callback = function()
                    require("modules/settings/sections/app_launcher_settings").build(editor_ctx).callback()
                end,
            },
        },
    }
end

return M
