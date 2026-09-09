local PresetStore = require("config/preset_store")

local M = {}
local DEFAULT_GOALS_FONT_SIZE = 11

M.MAX_WIDGET_SLOTS = 6
M.ALL_WIDGET_IDS = {
    "today", "trend_graph", "goal_progress", "calendar", "library",
    "this_week", "this_month", "this_year", "all_time", "personal_records", "current_book",
}

local DEFAULT_ENABLED = {
    today = true,
    trend_graph = true,
    goal_progress = true,
    calendar = true,
}

local TEXT_WIDGET_IDS = {
    today = true,
    this_week = true,
    this_month = true,
    this_year = true,
    all_time = true,
    personal_records = true,
    library = true,
    current_book = true,
    goal_progress = true,
}

function M.hasFontSize(id)
    return TEXT_WIDGET_IDS[id] == true
end

local function default_font_size(id)
    return id == "goal_progress" and DEFAULT_GOALS_FONT_SIZE or 15
end

function M.defaultWidget(id)
    if id == "trend_graph" then
        return { id = id, metric = "pages", range_days = 14 }
    end
    return { id = id }
end

function M.widgetSlots(id)
    return id == "calendar" and 2 or 1
end

local function normalize_options(id, options)
    local widget = M.defaultWidget(id)
    if id == "trend_graph" and type(options) == "table" then
        widget.metric = (options.metric == "time" or options.metric == "duration") and "time" or "pages"
        local range = tonumber(options.range_days) or 14
        widget.range_days = (range == 7 or range == 14 or range == 30 or range == 90) and range or 14
    end
    if M.hasFontSize(id) then
        local font_size = type(options) == "table" and tonumber(options.font_size)
        local is_override = type(options) == "table" and options.font_size_override == true
        if font_size and (is_override or font_size ~= default_font_size(id)) then
            widget.font_size = math.max(6, math.min(32, math.floor(font_size + 0.5)))
            widget.font_size_override = true
        end
    end
    return widget
end

function M.defaultSettings()
    local order, enabled = {}, {}
    for _i, id in ipairs(M.ALL_WIDGET_IDS) do
        order[#order + 1] = id
        enabled[id] = DEFAULT_ENABLED[id] == true
    end
    return {
        widgets = {
            order = order,
            enabled = enabled,
            options = { trend_graph = M.defaultWidget("trend_graph") },
        },
        font_size = 15,
        stat_style = "divider",
        week_start_day = 1,
    }
end

function M.normalize(settings)
    settings = type(settings) == "table" and settings or {}
    local widgets = type(settings.widgets) == "table" and settings.widgets or {}
    local valid, seen, order = {}, {}, {}
    for _i, id in ipairs(M.ALL_WIDGET_IDS) do valid[id] = true end
    for _i, id in ipairs(type(widgets.order) == "table" and widgets.order or {}) do
        if valid[id] and not seen[id] then
            order[#order + 1] = id
            seen[id] = true
        end
    end
    for _i, id in ipairs(M.ALL_WIDGET_IDS) do
        if not seen[id] then order[#order + 1] = id end
    end

    local enabled = {}
    for _i, id in ipairs(M.ALL_WIDGET_IDS) do
        enabled[id] = type(widgets.enabled) == "table" and widgets.enabled[id] == true
    end
    local has_enabled = false
    for _i, id in ipairs(M.ALL_WIDGET_IDS) do
        if enabled[id] then has_enabled = true break end
    end
    if not has_enabled then
        for id, value in pairs(DEFAULT_ENABLED) do enabled[id] = value end
    end

    local legacy_font_scale = tonumber(settings.font_scale)
    local font_size = tonumber(settings.font_size)
    settings.font_size = font_size and math.max(6, math.min(32, math.floor(font_size + 0.5)))
        or legacy_font_scale and math.max(6, math.min(32, math.floor(15 * legacy_font_scale / 100 + 0.5)))
        or 15
    settings.font_size_override = settings.font_size_override == true
    settings.edit_mode = settings.edit_mode == true
    settings.week_start_day = settings.week_start_day == 2 and 2 or 1
    local options = {}
    for _i, id in ipairs(M.ALL_WIDGET_IDS) do
        options[id] = normalize_options(id, type(widgets.options) == "table" and widgets.options[id])
    end

    settings.widgets = { order = order, enabled = enabled, options = options }
    if settings.stat_style ~= "outline" and settings.stat_style ~= "none" then
        settings.stat_style = "divider"
    end
    settings.font_scale = nil
    if type(settings.calendar_month) ~= "string" then settings.calendar_month = nil end
    return settings
end

function M.load()
    return M.normalize(PresetStore.getSettings("stats"))
end

function M.save(settings)
    return PresetStore.saveSettings("stats", M.normalize(settings))
end

function M.enabledBlocks(settings)
    settings = M.normalize(settings)
    local blocks, slots = {}, 0
    for _i, id in ipairs(settings.widgets.order) do
        if settings.widgets.enabled[id] then
            local weight = M.widgetSlots(id)
            if slots + weight <= M.MAX_WIDGET_SLOTS then
                local block = normalize_options(id, settings.widgets.options[id])
                if M.hasFontSize(id) then
                    block.font_size = block.font_size or (id == "goal_progress" and DEFAULT_GOALS_FONT_SIZE or settings.font_size)
                end
                blocks[#blocks + 1] = block
                slots = slots + weight
            end
        end
    end
    return blocks
end

function M.saveBlockOptions(settings, block)
    if type(block) ~= "table" then return end
    local id = block.id
    if id then settings.widgets.options[id] = normalize_options(id, block) end
    M.save(settings)
end

return M
