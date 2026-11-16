local _ = require("gettext")
local UIManager = require("ui/uimanager")

local M = {}

function M.build(ctx)
    local config, plugin = ctx.config, ctx.plugin
    config.annotation_viewer = config.annotation_viewer or {}
    local cfg = config.annotation_viewer
    cfg.details = cfg.details or { book = "auto", author = "auto", chapter = true, page = true }
    local function save() plugin:saveConfig() end
    local function choices(target, key, entries, default)
        local items = {}
        for _i, entry in ipairs(entries) do
            items[#items + 1] = {
                text = entry[2], radio = true,
                checked_func = function() return (target[key] or default) == entry[1] end,
                callback = function() target[key] = entry[1]; save() end,
            }
        end
        return items
    end
    local details = {}
    for _i, entry in ipairs({ { "book", _("Book title") }, { "author", _("Author") } }) do
        details[#details + 1] = { text = entry[2],
            sub_item_table = choices(cfg.details, entry[1], {
                { "auto", _("Auto") }, { "show", _("Show") }, { "hide", _("Hide") },
            }, "auto"),
        }
    end
    for _i, entry in ipairs({ { "chapter", _("Chapter") }, { "page", _("Page") },
            { "date", _("Date") }, { "label", _("Label") } }) do
        details[#details + 1] = { text = entry[2],
            checked_func = function() return cfg.details[entry[1]] ~= false end,
            callback = function() cfg.details[entry[1]] = cfg.details[entry[1]] == false; save() end }
    end
    return {
        text = _("Annotation viewer"),
        icon_name = "bookmark",
        sub_item_table = {
            { text = _("Details"), sub_item_table = details },
            { text = _("Preview length"), sub_item_table = choices(cfg, "preview_length", {
                { "short", _("Short") }, { "standard", _("Standard") }, { "long", _("Long") },
            }, "standard") },
            { keep_menu_open = true, text_func = function()
                return _("Text size") .. ": " .. tostring(config.page_browser and config.page_browser.bookmarks_font_size or 18)
            end, callback = function()
                config.page_browser = config.page_browser or {}
                UIManager:show(require("ui/widget/spinwidget"):new{
                    title_text = _("Text size"), value = config.page_browser.bookmarks_font_size or 18,
                    value_min = 10, value_max = 40, value_step = 1, default_value = 18,
                    callback = function(spin) config.page_browser.bookmarks_font_size = spin.value; save() end,
                })
            end },
        },
    }
end

return M
