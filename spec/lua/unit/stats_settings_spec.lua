describe("stats settings", function()
    local saved_settings
    local saved_default_font_size
    local saved_font_size
    local saved_week_start_day
    local saved_edit_mode
    local arrange_options
    local shown_widget
    local remembered_routes

    before_each(function()
        remembered_routes = {}
        local settings = {
            week_start_day = 1,
            widgets = {
                order = { "today", "this_week", "trend_graph", "goal_progress" },
                enabled = { today = false, this_week = false, goal_progress = false },
                options = {
                    this_week = { id = "this_week", font_size = 15 },
                    trend_graph = { id = "trend_graph", metric = "pages", range_days = 14 },
                    goal_progress = { id = "goal_progress" },
                },
            },
        }
        local StatsSettings = {
            MAX_WIDGET_SLOTS = 6,
            load = function() return settings end,
            save = function(current)
                saved_week_start_day = current.week_start_day
                saved_edit_mode = current.edit_mode
                local widgets = current.widgets
                local order, enabled = {}, {}
                for _i, id in ipairs(widgets.order) do order[_i] = id end
                for id, value in pairs(widgets.enabled) do enabled[id] = value end
                local graph = widgets.options.trend_graph
                local this_week = widgets.options.this_week
                local goal_progress = widgets.options.goal_progress
                current.widgets = {
                    order = order,
                    enabled = enabled,
                    options = {
                        this_week = {
                            id = this_week.id,
                            font_size = this_week.font_size,
                        },
                        trend_graph = {
                            id = graph.id,
                            metric = graph.metric,
                            range_days = graph.range_days,
                        },
                        goal_progress = {
                            id = goal_progress.id,
                            font_size = goal_progress.font_size,
                        },
                    },
                }
                saved_settings = current.widgets
                saved_default_font_size = current.font_size
                saved_font_size = current.widgets.options.this_week.font_size
            end,
            widgetSlots = function() return 1 end,
            hasFontSize = function(id) return id == "this_week" end,
        }

        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/uimanager", {
            scheduleIn = function() end,
            show = function(_self, widget) shown_widget = widget end,
            nextTick = function(_self, callback) callback() end,
        })
        ZenSpec.replace("ui/widget/spinwidget", { new = function(_self, opts) return opts end })
        ZenSpec.replace("modules/filebrowser/patches/stats_settings", StatsSettings)
        ZenSpec.replace("config/preset_store", {
            getSettings = function() return { goals = {} } end,
            saveSettings = function() end,
        })
        ZenSpec.replace("modules/filebrowser/patches/home/home_presets", {})
        ZenSpec.replace("common/reading_goals", {
            normalize = function(goals) return goals end,
            settingsItems = function() return {} end,
        })
        ZenSpec.replace("common/shared_state", { get = function() end })
        ZenSpec.replace("common/inline_icon_map", {
            divider = "divider",
            widgets = "widgets",
            edit = "edit",
            settings_stats = "stats",
            title = "font",
        })
        ZenSpec.replace("common/ui/icon_menu_item", {
            decorate = function(item, icon)
                item.icon_glyph = icon
                return item
            end,
        })
        ZenSpec.replace("common/ui/zen_arrange_list", {
            show = function(opts) arrange_options = opts end,
        })
        ZenSpec.replace("modules/settings/zen_settings_page", {
            rememberStandaloneArrangeRoute = function(path, opener, arrange_path)
                remembered_routes[#remembered_routes + 1] = {
                    path = path,
                    opener = opener,
                    arrange_path = arrange_path,
                }
                return true
            end,
            show = function() end,
        })
        ZenSpec.unload("modules/settings/sections/stats_settings")
    end)

    it("persists each widget change while the menu remains open", function()
        local section = require("modules/settings/sections/stats_settings").build({})
        assert.are.equal("widgets", section.sub_item_table[1].icon_glyph)
        section.sub_item_table[1].callback()
        arrange_options.item_table[1].callback()
        arrange_options.item_table[2].callback()

        assert.is_true(saved_settings.enabled.today)
        assert.is_true(saved_settings.enabled.this_week)
    end)

    it("keeps the plugin when Widgets is opened from the settings page", function()
        local plugin = { config = {} }
        local section = require("modules/settings/sections/stats_settings").build({
            plugin = plugin,
        })

        section.sub_item_table[1].callback({})

        assert.are.equal(plugin, arrange_options.plugin)
    end)

    it("persists repeated widget order commits", function()
        local section = require("modules/settings/sections/stats_settings").build({})
        section.sub_item_table[1].callback()
        local items = arrange_options.item_table

        items[1], items[2] = items[2], items[1]
        arrange_options.callback()
        assert.are.same({ "this_week", "today", "trend_graph", "goal_progress" },
            saved_settings.order)

        items[2], items[3] = items[3], items[2]
        arrange_options.callback()
        assert.are.same({ "this_week", "trend_graph", "today", "goal_progress" },
            saved_settings.order)
    end)

    it("uses the divider icon for stat separators", function()
        local section = require("modules/settings/sections/stats_settings").build({})

        assert.are.equal("divider", section.sub_item_table[4].icon_glyph)
    end)

    it("persists consecutive graph settings", function()
        local section = require("modules/settings/sections/stats_settings").build({})
        section.sub_item_table[1].callback()
        local graph_items = arrange_options.item_table[3].sub_item_table_func()
        graph_items[1].sub_item_table[2].callback()
        graph_items[2].sub_item_table_func()[3].callback()

        assert.are.equal("time", saved_settings.options.trend_graph.metric)
        assert.are.equal(30, saved_settings.options.trend_graph.range_days)
    end)

    it("persists a widget font size", function()
        local section = require("modules/settings/sections/stats_settings").build({})
        section.sub_item_table[1].callback()
        local font_items = arrange_options.item_table[2].sub_item_table_func()
        local updates = 0
        font_items[1].callback({ updateItems = function() updates = updates + 1 end })
        shown_widget.callback({ value = 17 })

        assert.are.equal(17, saved_font_size)
        assert.are.equal(1, updates)
    end)

    it("offers Reading Goals font options", function()
        local section = require("modules/settings/sections/stats_settings").build({})
        section.sub_item_table[1].callback()
        local font_items = arrange_options.item_table[4].sub_item_table_func()

        assert.are.equal("Font size: 11", font_items[1].text_func())
        assert.is_nil(font_items[2])
    end)

    it("persists the default font size", function()
        local section = require("modules/settings/sections/stats_settings").build({})
        assert.are.equal("font", section.sub_item_table[3].icon_glyph)
        section.sub_item_table[3].callback()
        shown_widget.callback({ value = 19 })

        assert.are.equal(19, saved_default_font_size)
    end)

    it("persists Sunday and Monday as the week reset day", function()
        local section = require("modules/settings/sections/stats_settings").build({})
        local days = section.sub_item_table[5].sub_item_table_func()
        assert.is_true(days[1].checked_func())
        days[2].callback()
        assert.are.equal(2, saved_week_start_day)
        assert.is_true(days[2].checked_func())
        assert.is_false(days[1].checked_func())
        days[1].callback()
        assert.are.equal(1, saved_week_start_day)
    end)

    it("persists edit mode", function()
        local section = require("modules/settings/sections/stats_settings").build({})
        assert.are.equal("edit", section.sub_item_table[2].icon_glyph)
        section.sub_item_table[2].callback()

        assert.is_true(saved_edit_mode)
    end)

    it("opens a widget settings page without finish controls", function()
        local settings = require("modules/settings/sections/stats_settings")
        local plugin = { config = {} }

        assert.is_true(settings.openWidgetSettings("trend_graph", plugin))
        assert.are.equal("Reading trend", arrange_options.title)
        assert.are.equal(plugin, arrange_options.plugin)
        assert.is_false(arrange_options.allow_arrange)
        assert.is_function(arrange_options.back_callback)
        assert.is_nil(arrange_options.item_table._zen_arrange_done_func)

        arrange_options.back_callback()
        assert.are.same({ "trend_graph" }, remembered_routes[1].arrange_path)
        assert.are.same({}, remembered_routes[2].arrange_path)
    end)
end)
