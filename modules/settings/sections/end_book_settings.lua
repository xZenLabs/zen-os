local _ = require("gettext")
local UIManager = require("ui/uimanager")
local M = {}

M.labels = {
    stats_triplet = _("Reading statistics"), featured = _("Featured book"),
    quotes = _("Highlights and notes"), strip = _("Book strip"),
}
M.sources = {
    { "next_series", _("Next in series") },
    { "author", _("More by author") },
    { "continue", _("Continue") },
    { "other_series", _("Series") },
    { "to_be_read", _("To Be Read") },
}
local metrics = {
    { "book_days", _("Days") },
    { "book_duration", _("Total time") },
    { "book_page_minutes", _("Time per page") },
    { "book_daily_minutes", _("Time per day") },
}

local function show_featured_buttons(plugin, config, save)
    local Data = require("modules/reader/end_book_data")
    local utils = require("common/utils")
    local picker_icons
    config.navigation_icons = config.navigation_icons or {}
    local entries, selected = Data.featuredActions(config), {}
    for _i, entry in ipairs(entries) do selected[entry.id] = true end
    for _i, entry in ipairs(Data.actions) do
        if not selected[entry.id] then entries[#entries + 1] = entry end
    end
    local items = {}
    local function save_buttons()
        config.navigation_actions = {}
        for _i, item in ipairs(items) do
            if selected[item.orig_item] then config.navigation_actions[#config.navigation_actions + 1] = item.orig_item end
        end
        save()
    end
    for _i, entry in ipairs(entries) do
        items[#items + 1] = {
            text = entry.label, orig_item = entry.id,
            checked_func = function() return selected[entry.id] == true end,
            callback = function()
                if not selected[entry.id] and #Data.featuredActions(config) >= Data.MAX_ACTIONS then
                    UIManager:show(require("ui/widget/infomessage"):new{ text = _("Maximum 5 buttons allowed") })
                    return
                end
                selected[entry.id] = not selected[entry.id]
                save_buttons()
            end,
            sub_item_table = {{
                text_func = function()
                    return require("ffi/util").template(_("Icon: %1"),
                        utils.getIconDisplayName(config.navigation_icons[entry.id] or entry.icon))
                end,
                keep_menu_open = true,
                callback = function(touchmenu)
                    picker_icons = picker_icons or utils.getIconPickerList(require("common/plugin_root"),
                        { zen_ui_light = true, zen_ui_update = true })
                    require("common/ui/zen_icon_picker")(picker_icons,
                        config.navigation_icons[entry.id] or entry.icon, function(name)
                            config.navigation_icons[entry.id] = name
                            save()
                            if touchmenu then touchmenu:updateItems(1) end
                        end)
                end,
            }},
        }
    end
    return require("common/ui/zen_arrange_list").show{
        title = _("Buttons"), plugin = plugin, item_table = items,
        hide_footer_cancel = true, callback = save_buttons,
    }
end

local function widget_items(plugin, config, id, save)
    local items = {}
    local function toggle(target, key, label)
        return {
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
        items[#items + 1] = toggle(config.modules.stats_triplet, "show_icons", _("Show icons"))
        local stats_config = config.modules.stats_triplet
        local function label()
            return (stats_config.label or "") ~= "" and stats_config.label or _("Statistics")
        end
        local label_items = {
            {
                text_func = function() return _("Label") .. ": " .. label() end,
                keep_menu_open = true,
                callback = function(touchmenu)
                    local dialog
                    dialog = require("ui/widget/inputdialog"):new{
                        title = _("Label"), input = label(),
                        buttons = {{
                            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                            {
                                text = _("Set"), is_enter_default = true,
                                callback = function()
                                    stats_config.label = dialog:getInputText()
                                    UIManager:close(dialog)
                                    save()
                                    if touchmenu then touchmenu:updateItems() end
                                end,
                            },
                        }},
                    }
                    UIManager:show(dialog)
                    dialog:onShowKeyboard()
                end,
            },
        }
        local font_items = require("modules/settings/sections/library_settings/home_settings").buildTextStyleItems(
            stats_config, "label", _("Label"), require("config/defaults").end_book.modules.stats_triplet.text_styles.label, save)
        for _i, item in ipairs(font_items) do label_items[#label_items + 1] = item end
        items[#items + 1] = {
            text = _("Label"), sub_item_table = label_items,
            checked_func = function() return stats_config.show_label ~= false end,
            checkmark_callback = function() stats_config.show_label = stats_config.show_label == false; save() end,
        }
    elseif id == "quotes" then
        items[#items + 1] = toggle(config.quotes, "show_title", _("Book title"))
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
    end
    if id == "featured" or id == "strip" then
        local Data = require("modules/reader/end_book_data")
        local editable = require("common/utils").deepcopy(config)
        editable.modules.featured = Data.featuredConfig(plugin)
        editable.modules.strip = Data.stripConfig(nil, nil, config)
        local function save_widget()
            config.modules[id] = editable.modules[id]
            save()
        end
        if id == "featured" then
            local featured = editable.modules.featured
            local default_size = math.floor(G_defaults:readSetting("DGENERIC_ICON_SIZE") * 1.25 + 0.5)
            local function icon_size()
                return (featured.navigation_icon_size or 0) > 0 and featured.navigation_icon_size or default_size
            end
            items[#items + 1] = {
                text_func = function() return string.format("%s %s", _("Icon size:"), icon_size()) end,
                keep_menu_open = true,
                callback = function(touchmenu)
                    UIManager:show(require("ui/widget/spinwidget"):new{
                        title_text = _("Icon size:"), value = icon_size(),
                        value_min = 8, value_max = 64, value_step = 2, default_value = default_size,
                        callback = function(spin)
                            featured.navigation_icon_size = spin.value ~= default_size and spin.value or 0
                            save_widget()
                            if touchmenu then touchmenu:updateItems() end
                        end,
                    })
                end,
            }
            items[#items + 1] = {
                text = _("Buttons"), keep_menu_open = true, _zen_settings_submenu = true,
                callback = function() return show_featured_buttons(plugin, featured, save_widget) end,
            }
        end
        local shared_items = require("modules/settings/sections/library_settings/home_settings").build{
            config = plugin.config, plugin = plugin, widget_id = id, widget_config = editable,
            featured_text_style_defaults = Data.FEATURED_TEXT_STYLES,
            used_widget_units = Data.usedUnits,
            strip_controls_defaults = Data.stripConfig().controls,
            save_widget_config = save_widget,
        }
        for _i, item in ipairs(shared_items) do items[#items + 1] = item end
    end
    return items
end

local function save_config(plugin, refresh)
    plugin:saveConfig()
    if refresh then
        refresh()
    else
        for _i, window in ipairs(UIManager._window_stack or {}) do
            local page = window.widget
            if page and page.name == "zen_end_book" then
                require("modules/settings/zen_settings_apply").defer_until_settings_close("end_book", function()
                    if not page.closed then page:rebuild() end
                end)
                break
            end
        end
    end
end

function M.openWidgetSettings(id, plugin)
    require("common/ui/zen_arrange_list").show{
        title = M.labels[id], plugin = plugin, allow_arrange = false, hide_footer_cancel = true,
        item_table = widget_items(plugin, plugin.config.end_book, id, function() save_config(plugin) end),
    }
    return true
end

function M.showWidgets(plugin, refresh)
    local config = plugin.config.end_book
    local items = {}
    local function save() save_config(plugin, refresh) end
    for _i, id in ipairs(config.rows.order) do
        items[#items + 1] = {
            text = M.labels[id], orig_item = id,
            checked_func = function() return config.rows.enabled[id] == true end,
            callback = function()
                if not config.rows.enabled[id] then
                    local Registry = require("modules/filebrowser/patches/home/components/registry")
                    local Data = require("modules/reader/end_book_data")
                    local modules = require("common/utils").deepcopy(config.modules)
                    modules.strip = Data.stripConfig(nil, nil, config)
                    local used = Data.usedUnits(config.rows.enabled, modules)
                    local needed = Data.WIDGET_UNITS[id] or Registry.sizeUnits(Registry.get(id), modules[id])
                    local capacity = Registry.capacityUnits()
                    if used + needed > capacity then
                        UIManager:show(require("ui/widget/infomessage"):new{
                            text = require("ffi/util").template(
                                _("Not enough space: %1/%2 units used; this widget needs %3."), used, capacity, needed),
                        })
                        return
                    end
                end
                config.rows.enabled[id] = not config.rows.enabled[id]
                save()
            end,
            sub_title = M.labels[id],
            sub_item_table_func = function() return widget_items(plugin, config, id, save) end,
        }
    end
    return require("common/ui/zen_arrange_list").show{
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
    local items = {
        { text = _("Widgets"), keep_menu_open = true, _zen_settings_submenu = true, callback = function() M.showWidgets(ctx.plugin) end },
        {
            text = _("Edit mode"),
            help_text = _("Hold a widget to open settings directly"),
            checked_func = function() return ctx.plugin.config.end_book.edit_mode ~= false end,
            callback = function()
                ctx.plugin.config.end_book.edit_mode = ctx.plugin.config.end_book.edit_mode == false
                save_config(ctx.plugin)
            end,
        },
        {
            text = _("Preview"), keep_menu_open = true,
            callback = function()
                require("modules/reader/end_book").show(require("apps/reader/readerui").instance, ctx.plugin, true)
            end,
        },
    }
    local action = require("modules/menu/app_launcher/native_menu").settingsItems("active", "document_end_action")[1]
    if action then table.insert(items, 1, action) end
    return items
end

return M
