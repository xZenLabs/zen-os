local _ = require("gettext")
local UIManager = require("ui/uimanager")
local StatsSettings = require("modules/filebrowser/patches/stats_settings")
local PresetStore = require("config/preset_store")
local HomePresets = require("modules/filebrowser/patches/home/home_presets")
local ReadingGoals = require("common/reading_goals")
local SharedState = require("common/shared_state")
local icons = require("common/inline_icon_map")
local IconItem = require("common/ui/icon_menu_item")

local M = {}
local DEFAULT_GOALS_FONT_SIZE = 11
local open_widget_settings

function M.openWidgetSettings(id, plugin)
    if type(open_widget_settings) ~= "function" then
        M.build({ plugin = plugin })
    end
    if type(open_widget_settings) == "function" then
        return open_widget_settings(id, plugin)
    end
    return false
end

local function label_for(id)
    local labels = {
        today = _("Today"),
        this_week = _("This week"),
        this_month = _("This month"),
        this_year = _("This year"),
        all_time = _("All time"),
        personal_records = _("Personal records"),
        library = _("Library"),
        current_book = _("Current book"),
        trend_graph = _("Reading trend"),
        goal_progress = _("Reading goals"),
        calendar = _("Reading calendar"),
    }
    return labels[id] or tostring(id)
end

local function refresh_active_pages(plugin)
    local StatsPage = require("modules/filebrowser/patches/stats_page")
    if StatsPage.rebuildActive then StatsPage.rebuildActive() end
    local home = SharedState.get(plugin, "home")
    if home and home.rebuildActive then home.rebuildActive() end
end

local function is_filemanager_menu_open()
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok_fm or not FileManager or not FileManager.instance then return false end
    local menu = FileManager.instance.menu
    if not menu then return false end
    local menu_container = menu.menu_container
    local stack = UIManager._window_stack
    if not stack then return menu_container ~= nil end
    for _i, entry in ipairs(stack) do
        local widget = entry and entry.widget
        if widget == menu or (menu_container and widget == menu_container) then return true end
    end
    return false
end

function M.build(ctx)
    local plugin = ctx and ctx.plugin or rawget(_G, "__ZEN_UI_PLUGIN")
    local active_pages_refresh_pending = false
    local active_pages_refresh_poll_active = false

    local function refresh_active_pages_on_menu_close()
        active_pages_refresh_pending = true
        if active_pages_refresh_poll_active then return end
        active_pages_refresh_poll_active = true

        local function tick()
            if is_filemanager_menu_open() then
                UIManager:scheduleIn(0.25, tick)
                return
            end
            active_pages_refresh_poll_active = false
            if not active_pages_refresh_pending then return end
            active_pages_refresh_pending = false
            refresh_active_pages(plugin)
        end

        UIManager:scheduleIn(0.25, tick)
    end

    local function save(settings)
        StatsSettings.save(settings)
        refresh_active_pages_on_menu_close()
    end

    local function graph_items(settings)
        local function graph()
            return settings.widgets.options.trend_graph
        end
        return {
            {
                text = _("Metric"),
                sub_item_table = {
                    {
                        text = _("Pages"),
                        radio = true,
                        checked_func = function() return graph().metric ~= "time" end,
                        callback = function() graph().metric = "pages"; save(settings) end,
                    },
                    {
                        text = _("Time"),
                        radio = true,
                        checked_func = function() return graph().metric == "time" end,
                        callback = function() graph().metric = "time"; save(settings) end,
                    },
                },
            },
            {
                text = _("Range"),
                sub_item_table_func = function()
                    local items = {}
                    for _i, range in ipairs({ 7, 14, 30, 90 }) do
                        local item_range = range
                        items[#items + 1] = {
                            text = tostring(item_range) .. _(" days"),
                            radio = true,
                            checked_func = function() return graph().range_days == item_range end,
                            callback = function() graph().range_days = item_range; save(settings) end,
                        }
                    end
                    return items
                end,
            },
        }
    end

    local function font_size_items(settings, id)
        local function widget()
            return settings.widgets.options[id]
        end
        local default_font_size = id == "goal_progress" and DEFAULT_GOALS_FONT_SIZE or settings.font_size or 15
        return {{
            text_func = function()
                return string.format("%s %s", _("Font size:"),
                    tostring(widget().font_size or default_font_size))
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new{
                    title_text = label_for(id) .. " " .. _("font size"),
                    value = widget().font_size or default_font_size,
                    value_min = 6,
                    value_max = 32,
                    default_value = default_font_size,
                    callback = function(spin)
                        widget().font_size = spin.value
                        widget().font_size_override = true
                        save(settings)
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end,
                })
            end,
        }}
    end

    local function goal_items(settings)
        local items = font_size_items(settings, "goal_progress")
        local home = PresetStore.getSettings("home")
        if type(home) ~= "table" or next(home) == nil then
            home = HomePresets.defaultHomePage()
        end
        home.goals = ReadingGoals.normalize(home.goals)
        local shared_items = ReadingGoals.settingsItems(home.goals, function()
            PresetStore.saveSettings("home", home)
            refresh_active_pages_on_menu_close()
        end)
        for _i, item in ipairs(shared_items) do items[#items + 1] = item end
        return items
    end

    local function arrange_widgets()
        local settings = StatsSettings.load()
        local widgets = settings.widgets
        local sort_items = {}
        local function used_slots(except_id)
            local slots = 0
            for _i, id in ipairs(widgets.order) do
                if id ~= except_id and widgets.enabled[id] then
                    slots = slots + StatsSettings.widgetSlots(id)
                end
            end
            return slots
        end
        local function should_dim(id)
            return not widgets.enabled[id]
                and used_slots(id) + StatsSettings.widgetSlots(id) > StatsSettings.MAX_WIDGET_SLOTS
        end
        local function update_dims()
            for _i, item in ipairs(sort_items) do item.dim = should_dim(item.orig_item) end
        end
        for _i, id in ipairs(widgets.order) do
            local item_id = id
            local item = {
                text = label_for(item_id),
                orig_item = item_id,
                dim = should_dim(item_id),
                checked_func = function() return widgets.enabled[item_id] == true end,
                callback = function()
                    if widgets.enabled[item_id] then
                        if used_slots(item_id) <= 0 then return end
                        widgets.enabled[item_id] = false
                    elseif used_slots(item_id) + StatsSettings.widgetSlots(item_id) <= StatsSettings.MAX_WIDGET_SLOTS then
                        widgets.enabled[item_id] = true
                    else
                        return
                    end
                    save(settings)
                    widgets = settings.widgets
                    update_dims()
                end,
            }
            if item_id == "trend_graph" then
                item.sub_title = label_for(item_id)
                item.sub_item_table_func = function()
                    return graph_items(settings)
                end
            elseif item_id == "goal_progress" then
                item.sub_item_table_func = function()
                    return goal_items(settings)
                end
            elseif StatsSettings.hasFontSize(item_id) then
                item.sub_item_table_func = function()
                    return font_size_items(settings, item_id)
                end
            end
            sort_items[#sort_items + 1] = item
        end
        require("common/ui/zen_arrange_list").show{
            title = _("Widgets"),
            item_table = sort_items,
            plugin = plugin,
            callback = function()
                local order = {}
                for _i, item in ipairs(sort_items) do order[#order + 1] = item.orig_item end
                settings.widgets.order = order
                save(settings)
                widgets = settings.widgets
            end,
        }
    end

    local function style_items()
        local settings = StatsSettings.load()
        local items = {}
        for _i, item in ipairs({
            { id = "divider", text = _("Divider") },
            { id = "outline", text = _("Outline") },
            { id = "none", text = _("None") },
        }) do
            local style = item.id
            items[#items + 1] = {
                text = item.text,
                radio = true,
                checked_func = function() return settings.stat_style == style end,
                callback = function() settings.stat_style = style; save(settings) end,
            }
        end
        return items
    end

    local function default_font_size_item()
        return {
            text_func = function()
                local settings = StatsSettings.load()
                return string.format("%s %s", _("Default font size:"), tostring(settings.font_size or 15))
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                local settings = StatsSettings.load()
                UIManager:show(SpinWidget:new{
                    title_text = _("Stats default font size"),
                    value = settings.font_size or 15,
                    value_min = 6,
                    value_max = 32,
                    default_value = 15,
                    callback = function(spin)
                        settings.font_size = spin.value
                        settings.font_size_override = true
                        save(settings)
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end,
                })
            end,
        }
    end

    open_widget_settings = function(id, owning_plugin)
        local settings_page = require("modules/settings/zen_settings_page")
        local standalone_route = settings_page.rememberStandaloneArrangeRoute({
            { text = _("Extras"), occurrence = 1 },
            { text = _("Stats"), occurrence = 1 },
        }, _("Widgets"), { id })
        local settings = StatsSettings.load()
        local items
        if id == "trend_graph" then
            items = graph_items(settings)
        elseif id == "goal_progress" then
            items = goal_items(settings)
        elseif StatsSettings.hasFontSize(id) then
            items = font_size_items(settings, id)
        end
        if type(items) ~= "table" or #items == 0 then
            arrange_widgets()
            return true
        end
        require("common/ui/zen_arrange_list").show{
            title = label_for(id),
            item_table = items,
            plugin = owning_plugin or plugin,
            allow_arrange = false,
            hide_footer_cancel = true,
            back_callback = standalone_route and function()
                settings_page.rememberStandaloneArrangeRoute({
                    { text = _("Extras"), occurrence = 1 },
                    { text = _("Stats"), occurrence = 1 },
                }, _("Widgets"), {})
                UIManager:nextTick(function()
                    if plugin then settings_page.show(plugin) end
                end)
                return true
            end or nil,
        }
        return true
    end

    local function arrange_search_items()
        local items = {}
        local settings = StatsSettings.load()
        for _i, id in ipairs(settings.widgets.order) do
            if id == "trend_graph" or id == "goal_progress" or StatsSettings.hasFontSize(id) then
                local widget_id = id
                items[#items + 1] = {
                    text = label_for(widget_id),
                    _zen_search_open = function()
                        return open_widget_settings(widget_id)
                    end,
                }
            end
        end
        return items
    end

    return IconItem.decorate({
        text = _("Stats"),
        _zen_search_items_func = arrange_search_items,
        sub_item_table = {
            IconItem.decorate({
                text = _("Widgets") .. " \u{25B8}",
                keep_menu_open = true,
                callback = arrange_widgets,
            }, icons.widgets),
            IconItem.decorate({
                text = _("Edit mode"),
                checked_func = function()
                    return StatsSettings.load().edit_mode == true
                end,
                callback = function()
                    local settings = StatsSettings.load()
                    settings.edit_mode = settings.edit_mode ~= true
                    save(settings)
                end,
            }, icons.edit),
            IconItem.decorate(default_font_size_item(), icons.title),
            IconItem.decorate({
                text = _("Stat separators"),
                sub_item_table_func = style_items,
            }, icons.divider),
            IconItem.decorate({
                text = _("Week reset day"),
                sub_item_table_func = function()
                    local settings = StatsSettings.load()
                    local items = {}
                    for day, label in ipairs({ _("Sunday"), _("Monday") }) do
                        local start_day = day
                        items[#items + 1] = {
                            text = label,
                            radio = true,
                            checked_func = function() return settings.week_start_day == start_day end,
                            callback = function() settings.week_start_day = start_day; save(settings) end,
                        }
                    end
                    return items
                end,
            }, icons.calendar),
        },
    }, icons.settings_stats)
end

return M
