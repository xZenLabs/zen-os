local UIManager = require("ui/uimanager")
local _ = require("gettext")

local M = {}

local PERIODS = {
    {
        id = "daily", text = _("Daily"),
        pages = { key = "daily_pages_target", default = 30, max = 5000 },
        time = { key = "daily_time_target_min", default = 30, max = 1440 },
    },
    {
        id = "weekly", text = _("Weekly"),
        pages = { key = "weekly_pages_target", default = 210, max = 20000 },
        time = { key = "weekly_time_target_min", default = 210, max = 10080 },
    },
    {
        id = "monthly", text = _("Monthly"),
        pages = { key = "monthly_pages_target", default = 900, max = 100000 },
        time = { key = "monthly_time_target_min", default = 900, max = 44640 },
        books = { key = "monthly_books_target", default = 1, max = 1000 },
    },
    {
        id = "yearly", text = _("Yearly"),
        pages = { key = "yearly_pages_target", default = 1000, max = 1000000 },
        time = { key = "yearly_time_target_min", default = 1000, max = 525600 },
        books = { key = "yearly_books_target", default = 12, max = 10000 },
    },
}

local function has_period(goals, wanted)
    for _i, period in ipairs(goals.periods) do
        if period == wanted then return true end
    end
    return false
end

function M.normalize(goals)
    if type(goals) ~= "table" then goals = {} end
    goals.exclude_cbz_cbr = goals.exclude_cbz_cbr == true
    local legacy_metric = goals.metric == "time" and "time" or "pages"
    local valid, periods, seen = {}, {}, {}
    for _i, item in ipairs(PERIODS) do valid[item.id] = true end
    for _i, period in ipairs(type(goals.periods) == "table" and goals.periods or {}) do
        if valid[period] and not seen[period] then
            periods[#periods + 1] = period
            seen[period] = true
        end
    end
    if #periods == 0 then periods[1] = goals.period == "weekly" and "weekly" or "daily" end
    goals.periods = periods
    if type(goals.metrics) ~= "table" then goals.metrics = {} end
    for _i, period in ipairs(PERIODS) do
        local metric = goals.metrics[period.id]
        if metric ~= "time" and metric ~= "pages" and not (period.books and metric == "books") then
            goals.metrics[period.id] = legacy_metric
        end
        local targets = { period.pages, period.time }
        if period.books then targets[#targets + 1] = period.books end
        for _j, target in ipairs(targets) do
            if type(goals[target.key]) ~= "number" then goals[target.key] = target.default end
        end
    end
    return goals
end

function M.settingsItems(goals, save)
    goals = M.normalize(goals)
    local items = {}
    for _i, item in ipairs(PERIODS) do
        local period = item
        items[#items + 1] = {
            text = period.text,
            sub_item_table_func = function()
                local function set_metric(metric)
                    goals.metrics[period.id] = metric
                    save()
                end
                local function target_item(target)
                    local is_time = target == period.time
                    local is_books = target == period.books
                    local title = is_time and string.format(_("%s time goal (min)"), period.text)
                        or is_books and string.format(_("%s books goal"), period.text)
                        or string.format(_("%s pages goal"), period.text)
                    local label = title .. ": "
                    return {
                        text_func = function()
                            return label .. tostring(goals[target.key] or target.default)
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            local SpinWidget = require("ui/widget/spinwidget")
                            UIManager:show(SpinWidget:new{
                                title_text = title,
                                value = goals[target.key] or target.default,
                                value_min = 1,
                                value_max = target.max,
                                callback = function(spin)
                                    goals[target.key] = spin.value
                                    save()
                                    if touchmenu_instance and touchmenu_instance.updateItems then
                                        touchmenu_instance:updateItems()
                                    end
                                end,
                            })
                        end,
                    }
                end
                local period_items = {
                    {
                        text = _("Show goal"),
                        checked_func = function() return has_period(goals, period.id) end,
                        callback = function()
                            for i, selected in ipairs(goals.periods) do
                                if selected == period.id then
                                    if #goals.periods > 1 then
                                        table.remove(goals.periods, i)
                                        save()
                                    end
                                    return
                                end
                            end
                            goals.periods[#goals.periods + 1] = period.id
                            save()
                        end,
                    },
                    {
                        text = _("Pages"),
                        radio = true,
                        checked_func = function() return goals.metrics[period.id] == "pages" end,
                        callback = function() set_metric("pages") end,
                    },
                    {
                        text = _("Time"),
                        radio = true,
                        checked_func = function() return goals.metrics[period.id] == "time" end,
                        callback = function() set_metric("time") end,
                    },
                }
                if period.books then
                    period_items[#period_items + 1] = {
                        text = _("Books"),
                        radio = true,
                        checked_func = function() return goals.metrics[period.id] == "books" end,
                        callback = function() set_metric("books") end,
                    }
                end
                period_items[#period_items + 1] = target_item(period.pages)
                period_items[#period_items + 1] = target_item(period.time)
                if period.books then period_items[#period_items + 1] = target_item(period.books) end
                return period_items
            end,
        }
    end
    items[#items + 1] = {
        text = _("Exclude CBZ/CBR files"),
        checked_func = function() return goals.exclude_cbz_cbr end,
        callback = function()
            goals.exclude_cbz_cbr = not goals.exclude_cbz_cbr
            save()
        end,
    }
    return items
end

function M.metricFor(goals, period)
    goals = M.normalize(goals)
    if (period == "monthly" or period == "yearly") and goals.metrics[period] == "books" then
        return "books"
    end
    return goals.metrics[period] == "time" and "time" or "pages"
end

return M
