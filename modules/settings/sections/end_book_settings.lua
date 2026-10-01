local _ = require("gettext")
local UIManager = require("ui/uimanager")
local M = {}

M.labels = {
    stats_triplet = _("Reading statistics"), featured = _("Featured book"),
    quotes = _("Highlights and notes"), strip = _("Book strip"),
}
M.sources = {
    { "next_series", _("Next in series") },
    { "author", _("Same author") },
    { "other_series", _("Other series") },
}
local metrics = {
    { "book_days", _("Days reading this book") },
    { "book_duration", _("Reading time") },
    { "book_page_minutes", _("Minutes per page") },
    { "book_daily_minutes", _("Minutes per reading day") },
}

local function widget_items(config, id, save)
    local items = {}
    local function toggle(target, key, label)
        items[#items + 1] = {
            text = label,
            checked_func = function() return target[key] ~= false end,
            callback = function() target[key] = target[key] == false; save() end,
        }
    end
    if id == "stats_triplet" then
        for slot = 1, 3 do
            local choices = {}
            for _i, metric in ipairs(metrics) do
                choices[#choices + 1] = {
                    text = metric[2], radio = true,
                    checked_func = function() return config.middle_stats_triplet[slot] == metric[1] end,
                    callback = function() config.middle_stats_triplet[slot] = metric[1]; save() end,
                }
            end
            items[#items + 1] = { text = tostring(slot), sub_item_table = choices }
        end
    elseif id == "featured" then
        toggle(config.modules.featured, "show_author", _("Author"))
        toggle(config.modules.featured, "show_description", _("Book status"))
        toggle(config.modules.featured, "show_progress", _("Reading progress"))
    elseif id == "quotes" then
        toggle(config.quotes, "show_title", _("Book title"))
        items[#items + 1] = {
            text = _("Font size"),
            callback = function()
                UIManager:show(require("ui/widget/spinwidget"):new{
                    title_text = _("Font size"), value = config.quotes.max_font_size,
                    value_min = 8, value_max = 32, value_step = 1,
                    callback = function(spin) config.quotes.max_font_size = spin.value; save() end,
                })
            end,
        }
    elseif id == "strip" then
        toggle(config.modules.strip, "show_strip_titles", _("Book titles"))
        items[#items + 1] = {
            text = _("Books per page"),
            callback = function()
                UIManager:show(require("ui/widget/spinwidget"):new{
                    title_text = _("Books per page"), value = config.modules.strip.count,
                    value_min = 3, value_max = 5, value_step = 1,
                    callback = function(spin) config.modules.strip.count = spin.value; save() end,
                })
            end,
        }
        local choices = {}
        for _i, source in ipairs(M.sources) do
            choices[#choices + 1] = {
                text = source[2], radio = true,
                checked_func = function() return config.strip_source == source[1] end,
                callback = function() config.strip_source = source[1]; save() end,
            }
        end
        items[#items + 1] = { text = _("Default source"), sub_item_table = choices }
    end
    return items
end

function M.showWidgets(plugin, refresh)
    local config = plugin.config.end_book
    local items = {}
    local function save()
        plugin:saveConfig()
        if refresh then refresh() end
    end
    for _i, id in ipairs(config.rows.order) do
        items[#items + 1] = {
            text = M.labels[id], orig_item = id,
            checked_func = function() return config.rows.enabled[id] == true end,
            callback = function()
                config.rows.enabled[id] = not config.rows.enabled[id]
                save()
            end,
            sub_title = M.labels[id],
            sub_item_table_func = function() return widget_items(config, id, save) end,
        }
    end
    require("common/ui/zen_arrange_list").show{
        title = _("End of book"), plugin = plugin, item_table = items,
        callback = function()
            local order = {}
            for _i, item in ipairs(items) do order[#order + 1] = item.orig_item end
            config.rows.order = order
            save()
        end,
    }
end

function M.build(ctx)
    return {
        {
            text = _("Use at end of book"),
            checked_func = function()
                return G_reader_settings:readSetting("end_document_action") == "zen_end_book"
            end,
            callback = function()
                G_reader_settings:saveSetting("end_document_action", "zen_end_book")
            end,
        },
        { text = _("Widgets"), callback = function() M.showWidgets(ctx.plugin) end },
        {
            text = _("Preview"),
            enabled_func = function() return require("apps/reader/readerui").instance ~= nil end,
            callback = function(touchmenu)
                if touchmenu then touchmenu:closeMenu() end
                require("modules/reader/end_book").show(require("apps/reader/readerui").instance, ctx.plugin)
            end,
        },
    }
end

return M
