local _ = require("gettext")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")

local HomePresets = require("modules/filebrowser/patches/home/home_presets")
local HomeQuotes = require("modules/filebrowser/patches/home/home_quotes")
local author_sort = require("common/author_sort")
local PresetStore = require("config/preset_store")
local Registry = require("modules/filebrowser/patches/home/components/registry")
local library_font = require("modules/filebrowser/patches/library_font")
local ReadingGoals = require("common/reading_goals")
local icons = require("common/inline_icon_map")
local IconItem = require("common/ui/icon_menu_item")
local ButtonModel = require("common/nav_button_model")
local Destination = require("common/library_destination")
local DispatcherMenu = require("common/dispatcher_menu")
local NativeMenu = require("modules/menu/app_launcher/native_menu")
local PluginScan = require("modules/menu/app_launcher/plugin_scan")

local M = {}
local DEFAULT_GOALS_FONT_SIZE = 11
local DEFAULT_DATETIME_MAX_FONT_SIZE = 36
local MAX_DATETIME_FONT_SIZE = 160
local DEFAULT_STATS_FONT_SIZE = 16
local DEFAULT_STATS_MAX_FONT_SIZE = 18
local MAX_STATS_FONT_SIZE = 64
local DEFAULT_DATETIME_FONT_SIZES = { time = 36, date = 12 }
local DEFAULT_STRIP_CONTROL_TEXT_STYLE = {
    font_face = "default",
    font_size = 10,
    bold = false,
}
local open_widget_settings

function M.openWidgetSettings(id, plugin)
    if type(open_widget_settings) ~= "function"
            and plugin and type(plugin.config) == "table" then
        M.build({
            plugin = plugin,
            config = plugin.config,
            settings_apply = require("modules/settings/zen_settings_apply"),
        })
    end
    if type(open_widget_settings) == "function" then
        return open_widget_settings(id, plugin)
    end
    return false
end

local DEFAULT_ORDER = {
    "datetime",
    "featured",
    "stats_triplet",
    "reading_goals",
    "strip",
    "quotes",
}

local DEFAULT_ENABLED = {
    featured = true,
    quotes = true,
    stats_triplet = true,
    strip = true,
}

local DEFAULT_FEATURED_PROGRESS_META = {
    left = "percent",
    right = "total_pages",
}

local FEATURED_TEXT_STYLE_DEFAULTS = {
    title = { font_face = "default", font_size = 11, bold = true },
    author = { font_face = "default", font_size = 9, bold = false },
    series = { font_face = "default", font_size = 7, bold = false },
    description = { font_face = "default", font_size = 16, bold = false },
    progress = { font_face = "default", font_size = 7, bold = false },
}

local function normalize_order(order)
    if order == "reverse" then return "reverse" end
    return "default"
end

local function ensure_featured_text_style(mcfg, key)
    if type(mcfg.text_styles) ~= "table" then mcfg.text_styles = {} end
    local defaults = FEATURED_TEXT_STYLE_DEFAULTS[key]
    if type(defaults) ~= "table" then return nil end
    if type(mcfg.text_styles[key]) ~= "table" then mcfg.text_styles[key] = {} end
    local style = mcfg.text_styles[key]
    if type(style.font_face) ~= "string" or style.font_face == "" then
        style.font_face = defaults.font_face
    end
    local size = tonumber(style.font_size)
    if not size then
        style.font_size = defaults.font_size
    else
        style.font_size = math.max(6, math.min(40, math.floor(size + 0.5)))
    end
    if style.bold == nil then
        style.bold = defaults.bold
    else
        style.bold = style.bold == true
    end
    return style
end

local function ensure_featured_text_styles(mcfg)
    for key, defaults in pairs(FEATURED_TEXT_STYLE_DEFAULTS) do
        if defaults then ensure_featured_text_style(mcfg, key) end
    end
end

local function ensure_datetime_text_style(mcfg, key)
    if type(mcfg.text_styles) ~= "table" then mcfg.text_styles = {} end
    if type(mcfg.text_styles[key]) ~= "table" then mcfg.text_styles[key] = {} end
    local style = mcfg.text_styles[key]
    if type(style.font_face) ~= "string" or style.font_face == "" then
        style.font_face = "default"
    end
    local minimum = key == "time" and 8 or 6
    local maximum = key == "time" and 160 or 80
    style.font_size = math.max(minimum, math.min(maximum, math.floor(
        (tonumber(style.font_size) or DEFAULT_DATETIME_FONT_SIZES[key]) + 0.5
    )))
    return style
end

local function ensure_module_cfg(dcfg, module_id)
    if type(dcfg.modules) ~= "table" then dcfg.modules = {} end
    if type(dcfg.modules[module_id]) ~= "table" then dcfg.modules[module_id] = {} end
    local mcfg = dcfg.modules[module_id]
    mcfg.show_module_title = nil
    return mcfg
end

local function ensure_datetime_cfg(dcfg)
    local mcfg = ensure_module_cfg(dcfg, "datetime")
    mcfg.automatic_font_size = mcfg.automatic_font_size ~= false
    mcfg.max_font_size = math.max(8, math.min(MAX_DATETIME_FONT_SIZE, math.floor(
        (tonumber(mcfg.max_font_size) or DEFAULT_DATETIME_MAX_FONT_SIZE) + 0.5
    )))
    ensure_datetime_text_style(mcfg, "time")
    ensure_datetime_text_style(mcfg, "date")
    return mcfg
end

local function ensure_featured_cfg(dcfg, module_id)
    local mcfg = ensure_module_cfg(dcfg, module_id)
    mcfg.order = nil
    if mcfg.show_author == nil then mcfg.show_author = true end
    if mcfg.show_series == nil then mcfg.show_series = true end
    if mcfg.show_description == nil then mcfg.show_description = true end
    if mcfg.show_progress == nil then mcfg.show_progress = true end
    if mcfg.wrap_description_text == nil then mcfg.wrap_description_text = false end
    if mcfg.justify_description_text == nil then mcfg.justify_description_text = false end
    if mcfg.format_description_html == nil then mcfg.format_description_html = false end
    if mcfg.interactive == nil then mcfg.interactive = true end
    if mcfg.show_status_bar == nil then mcfg.show_status_bar = false end
    if mcfg.status_bar_show_bottom_border == nil then mcfg.status_bar_show_bottom_border = true end
    if mcfg.status_bar_bold_text == nil then mcfg.status_bar_bold_text = true end
    ensure_featured_text_styles(mcfg)
    if type(mcfg.progress_meta) ~= "table" then mcfg.progress_meta = {} end
    if mcfg.progress_meta.left == nil and mcfg.progress_meta.right == nil then
        for key, side in pairs(mcfg.progress_meta) do
            if side == "left" and mcfg.progress_meta.left == nil then
                mcfg.progress_meta.left = key
            elseif side == "right" and mcfg.progress_meta.right == nil then
                mcfg.progress_meta.right = key
            end
        end
    end
    for side, metric in pairs(DEFAULT_FEATURED_PROGRESS_META) do
        if mcfg.progress_meta[side] ~= "total_pages"
                and mcfg.progress_meta[side] ~= "current_total"
                and mcfg.progress_meta[side] ~= "percent"
                and mcfg.progress_meta[side] ~= "time_left"
                and mcfg.progress_meta[side] ~= "off" then
            mcfg.progress_meta[side] = metric
        end
    end
    return mcfg
end

local function ensure_strip_cfg(dcfg)
    local mcfg = ensure_module_cfg(dcfg, "strip")
    mcfg.order = normalize_order(mcfg.order)
    if mcfg.interactive == nil then mcfg.interactive = true end
    if mcfg.two_rows == nil then mcfg.two_rows = false end
    if type(mcfg.count) ~= "number" then mcfg.count = mcfg.two_rows and 8 or 4 end
    if mcfg.two_rows then
        if mcfg.count < 2 then mcfg.count = 2 end
        if mcfg.count > 10 then mcfg.count = 10 end
    else
        if mcfg.count < 3 then mcfg.count = 3 end
        if mcfg.count > 5 then mcfg.count = 5 end
    end
    if mcfg.show_strip_titles == nil then mcfg.show_strip_titles = false end
    if mcfg.show_badges == nil then mcfg.show_badges = false end
    if mcfg.center_books == nil then mcfg.center_books = false end
    if type(mcfg.controls) ~= "table" then mcfg.controls = {} end
    if type(mcfg.controls.text_style) ~= "table" then
        mcfg.controls.text_style = {}
    end
    local style = mcfg.controls.text_style
    if type(style.font_face) ~= "string" or style.font_face == "" then
        style.font_face = DEFAULT_STRIP_CONTROL_TEXT_STYLE.font_face
    end
    style.font_size = math.max(6, math.min(24, math.floor(
        (tonumber(style.font_size) or DEFAULT_STRIP_CONTROL_TEXT_STYLE.font_size) + 0.5)))
    style.bold = style.bold == true
    return mcfg
end

local function ensure_home_widget_cfg(dcfg)
    ensure_datetime_cfg(dcfg)
    local featured = ensure_featured_cfg(dcfg, "featured")
    if type(featured.default_source) ~= "table" then
        featured.default_source = { kind = "recent" }
    end
    if type(featured.path) ~= "string" then featured.path = nil end
    local stats_triplet = ensure_module_cfg(dcfg, "stats_triplet")
    if stats_triplet.stat_style ~= "outline" and stats_triplet.stat_style ~= "none" then
        stats_triplet.stat_style = "divider"
    end
    stats_triplet.font_size = tonumber(stats_triplet.font_size)
    if stats_triplet.font_size then
        stats_triplet.font_size = math.max(8, math.min(MAX_STATS_FONT_SIZE, math.floor(stats_triplet.font_size + 0.5)))
    end
    stats_triplet.automatic_font_size = stats_triplet.automatic_font_size ~= false
    stats_triplet.max_font_size = math.max(8, math.min(MAX_STATS_FONT_SIZE, math.floor(
        (tonumber(stats_triplet.max_font_size) or DEFAULT_STATS_MAX_FONT_SIZE) + 0.5
    )))
    stats_triplet.font_scale = nil
    local reading_goals = ensure_module_cfg(dcfg, "reading_goals")
    local goals_font_size = tonumber(reading_goals.font_size)
    reading_goals.font_size = goals_font_size and math.max(8, math.min(32, math.floor(goals_font_size + 0.5))) or nil
    reading_goals.automatic_font_size = reading_goals.automatic_font_size ~= false
    reading_goals.max_font_size = math.max(8, math.min(64, math.floor(
        (tonumber(reading_goals.max_font_size) or 32) + 0.5
    )))
    ensure_module_cfg(dcfg, "quotes")
    ensure_strip_cfg(dcfg)
end

local function ensure_cfg(_config)
    local dcfg = PresetStore.getSettings("home")
    if type(dcfg) ~= "table" or next(dcfg) == nil then
        dcfg = HomePresets.defaultHomePage()
    end
    HomePresets.ensurePresetState(dcfg)
    HomePresets.normalizeFeaturedConfig(dcfg)
    HomePresets.normalizeStripConfig(dcfg)
    if type(HomePresets.normalizeLayoutGrid) == "function" then
        HomePresets.normalizeLayoutGrid(dcfg)
    end

    dcfg.rows = Registry.normalizeRows(dcfg.rows, DEFAULT_ORDER, DEFAULT_ENABLED)

    if dcfg.show_status_bar == nil then dcfg.show_status_bar = true end
    dcfg.edit_mode = dcfg.edit_mode == true
    dcfg.font_size = nil
    dcfg.font_size_override = nil

    if type(dcfg.middle_stats_triplet) ~= "table" then
        dcfg.middle_stats_triplet = { "today_pages", "today_duration", "streak" }
    end

    dcfg.goals = ReadingGoals.normalize(dcfg.goals)

    if type(dcfg.quotes) ~= "table" then dcfg.quotes = {} end
    if dcfg.quotes.show_author == nil then dcfg.quotes.show_author = true end
    if dcfg.quotes.show_title == nil then dcfg.quotes.show_title = true end
    if type(dcfg.quotes.sources) ~= "table" then
        dcfg.quotes.sources = { default = true }
    end
    if dcfg.quotes.rotation ~= "refresh" then dcfg.quotes.rotation = "daily" end
    dcfg.quotes.automatic_font_size = dcfg.quotes.automatic_font_size == true
    dcfg.quotes.max_font_size = math.max(
        4, math.min(32, tonumber(dcfg.quotes.max_font_size) or 14)
    )
    dcfg.quotes.use_home_font_size = nil
    local quote_font_size = tonumber(dcfg.quotes.font_size)
    local quote_font_override = dcfg.quotes.font_size_override == true
    if quote_font_size == 18 and not quote_font_override then quote_font_size = nil end
    dcfg.quotes.font_size = quote_font_size and (quote_font_override or quote_font_size ~= 12)
        and math.max(4, math.min(32, math.floor(quote_font_size + 0.5))) or nil
    dcfg.quotes.font_size_override = dcfg.quotes.font_size and true or nil

    for _i, comp in ipairs(Registry.list()) do
        ensure_module_cfg(dcfg, comp.id)
    end
    ensure_home_widget_cfg(dcfg)

    return dcfg
end

local custom_strip_max_books = 40

local function responsive_strip_max_books(two_rows)
    local Screen = require("device").screen
    local body_w = Screen:getWidth()
    local side_pad = math.max(2, math.min(
        Screen:scaleBySize(8), math.floor(body_w * 0.025)))
    if side_pad * 2 >= body_w then
        side_pad = math.max(0, math.floor(body_w * 0.04))
    end
    local outer_width = math.max(1, body_w - side_pad * 2)
    local StripCommon = require(
        "modules/filebrowser/patches/home/widgets/strip_common")
    return StripCommon.max_books_for_width(outer_width, two_rows)
end

function M.build(ctx)
    local config = ctx.config
    local dcfg = ensure_cfg(config)
    local capacity_units = type(Registry.capacityUnits) == "function"
        and Registry.capacityUnits() or Registry.CAPACITY_UNITS
    local home_rebuild_pending = false
    local home_rebuild_poll_active = false
    local schedule_home_rebuild_on_menu_close

    local function unique_user_preset_name(base)
        if not PresetStore.find("home", base) then return base end
        local i = 2
        while PresetStore.find("home", base .. " " .. i) do
            i = i + 1
        end
        return base .. " " .. i
    end

    local function editable_name_for_builtin(preset_name)
        if preset_name == HomePresets.DEFAULT_PRESET_NAME then
            return HomePresets.CUSTOM_PRESET_NAME
        end
        return tostring(preset_name or HomePresets.CUSTOM_PRESET_NAME) .. " custom"
    end

    local function copy_builtin_for_editing(preset_name)
        local name = unique_user_preset_name(editable_name_for_builtin(preset_name))
        dcfg.active_preset = name
        dcfg.title = name
        local state = HomePresets.captureHomePage(dcfg)
        state.title = name
        PresetStore.save("home", name, state)
        PresetStore.setActivePreset("home", name)
        return name
    end

    local function make_builtin_editable()
        if not HomePresets.isBuiltinPresetName(dcfg.active_preset) then return end
        copy_builtin_for_editing(dcfg.active_preset)
    end

    local function save_home(_mode, opts)
        if not (type(opts) == "table" and opts.make_builtin_editable == false) then
            make_builtin_editable()
        end
        PresetStore.saveSettings("home", dcfg)
        home_rebuild_pending = true
        schedule_home_rebuild_on_menu_close()
    end

    local function set_authors_collate(collate)
        if not author_sort.isMode(collate) then return end
        if type(config.group_view) ~= "table" then config.group_view = {} end
        config.group_view.authors_collate = collate
        if ctx.plugin and type(ctx.plugin.saveConfig) == "function" then
            ctx.plugin:saveConfig()
        end
        home_rebuild_pending = true
        schedule_home_rebuild_on_menu_close()
    end

    local function is_filemanager_menu_open()
        local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
        if not ok_fm or not FileManager or not FileManager.instance then return false end
        local fm = FileManager.instance
        local menu = fm.menu
        if not menu then return false end
        local menu_container = menu.menu_container
        local stack = UIManager._window_stack
        if not stack then return false end
        for _i, entry in ipairs(stack) do
            local widget = entry and entry.widget
            if widget == menu or (menu_container and widget == menu_container) then return true end
        end
        return false
    end

    schedule_home_rebuild_on_menu_close = function()
        if home_rebuild_poll_active then return end
        home_rebuild_poll_active = true
        local function tick()
            local plugin = ctx.plugin or rawget(_G, "__ZEN_UI_PLUGIN")
            local settings_apply = ctx.settings_apply
            local home = settings_apply
                and settings_apply.get_shared
                and settings_apply.get_shared(plugin, "home")
            local home_waiting = home
                and home.hasActive
                and home.hasActive()
                and home.isActiveOnTop
                and not home.isActiveOnTop()
            if is_filemanager_menu_open() or home_waiting then
                UIManager:scheduleIn(0.25, tick)
                return
            end
            home_rebuild_poll_active = false
            if not home_rebuild_pending then return end
            home_rebuild_pending = false
            if home and home.rebuildActive then
                UIManager:scheduleIn(0, function()
                    home.rebuildActive()
                end)
            end
        end
        UIManager:scheduleIn(0.25, tick)
    end

    local function component_label(id)
        local comp = Registry.get(id)
        if comp and comp.label then return comp.label end
        return tostring(id) .. " (" .. _("Unavailable") .. ")"
    end

    local function used_home_units()
        return Registry.totalUnits(dcfg.rows.enabled, dcfg.modules)
    end

    local function enabled_widget_count()
        local count = 0
        for _id, value in pairs(dcfg.rows.enabled) do
            if value == true then count = count + 1 end
        end
        return count
    end

    local function component_units(id, module_cfg)
        local comp = Registry.get(id)
        return comp and Registry.sizeUnits(comp, module_cfg or dcfg.modules[id]) or 0
    end

    local function show_capacity_message(used, needed)
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = T(
                _("Not enough Home space: %1/%2 units used; this widget needs %3."),
                used,
                capacity_units,
                needed
            ),
        })
    end

    local function toggle_strip_rows(module_id, mcfg)
        local enable_two_rows = mcfg.two_rows ~= true
        if enable_two_rows and dcfg.rows.enabled[module_id] == true then
            local used = used_home_units()
            local current_units = component_units(module_id, mcfg)
            local next_units = component_units(module_id, { two_rows = true })
            if used - current_units + next_units > capacity_units then
                show_capacity_message(used - current_units, next_units)
                return false
            end
        end
        mcfg.two_rows = enable_two_rows
        mcfg.count = enable_two_rows and 8 or 4
        save_home("reinit")
        return true
    end

    local progress_label_options = {
        { id = "off", text = _("Off") },
        { id = "percent", text = _("Percent") },
        { id = "time_left", text = _("Time to book end") },
        { id = "current_total", text = _("Current/total pages") },
        { id = "total_pages", text = _("Total pages") },
    }

    local function progress_label(metric)
        for _i, opt in ipairs(progress_label_options) do
            if opt.id == metric then return opt.text end
        end
        return _("Off")
    end

    local function build_progress_meta_items(mcfg)
        if type(mcfg.progress_meta) ~= "table" then mcfg.progress_meta = {} end
        local function side_items(side)
            local items = {}
            for _i, opt in ipairs(progress_label_options) do
                local metric = opt.id
                items[#items + 1] = {
                    text = opt.text,
                    radio = true,
                    checked_func = function()
                        return (mcfg.progress_meta[side] or "off") == metric
                    end,
                    callback = function()
                        mcfg.progress_meta[side] = metric
                        save_home("reinit")
                    end,
                }
            end
            return items
        end
        return {
            {
                text_func = function()
                    return _("Left") .. ": " .. progress_label(mcfg.progress_meta.left)
                end,
                sub_item_table = side_items("left"),
            },
            {
                text_func = function()
                    return _("Right") .. ": " .. progress_label(mcfg.progress_meta.right)
                end,
                sub_item_table = side_items("right"),
            },
        }
    end

    local function font_label(face)
        if face == nil or face == "" or face == "default" then return _("default") end
        local ok_fc, FontChooser = pcall(require, "ui/widget/fontchooser")
        return ok_fc and FontChooser.getFontNameText(face) or face
    end

    local function chooser_default_font()
        local font_name = library_font.getFontName()
        if font_name and font_name ~= "" and font_name ~= "cfont" then
            return font_name
        end
        local footer_settings = G_reader_settings:readSetting("footer") or {}
        return footer_settings.text_font_face or "NotoSans-Regular.ttf"
    end

    local function datetime_style_summary(mcfg, key)
        local style = ensure_datetime_text_style(mcfg, key)
        local size = mcfg.automatic_font_size ~= false
            and _("Automatic") or tostring(style.font_size)
        return font_label(style.font_face) .. ", " .. size
    end

    local function build_datetime_text_style_items(mcfg, key, label)
        return {
            {
                text_func = function()
                    local style = ensure_datetime_text_style(mcfg, key)
                    return string.format("%s %s", _("Font size:"), tostring(style.font_size))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local style = ensure_datetime_text_style(mcfg, key)
                    UIManager:show(SpinWidget:new{
                        title_text = string.format("%s %s", label, _("font size")),
                        value = style.font_size,
                        value_min = key == "time" and 8 or 6,
                        value_max = key == "time" and 160 or 80,
                        default_value = DEFAULT_DATETIME_FONT_SIZES[key],
                        callback = function(spin)
                            style.font_size = spin.value
                            mcfg.automatic_font_size = false
                            save_home("reinit")
                            if touchmenu_instance and touchmenu_instance.updateItems then
                                touchmenu_instance:updateItems()
                            end
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    return string.format("%s %s", _("Font:"),
                        font_label(ensure_datetime_text_style(mcfg, key).font_face))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local ok_fc, FontChooser = pcall(require, "ui/widget/fontchooser")
                    if not ok_fc then return end
                    local style = ensure_datetime_text_style(mcfg, key)
                    local default_font = chooser_default_font()
                    local display_face = style.font_face == "default"
                        and default_font or style.font_face
                    UIManager:show(FontChooser:new{
                        title = string.format("%s %s", label, _("font")),
                        font_file = display_face,
                        default_font_file = default_font,
                        callback = function(file)
                            if style.font_face ~= file then
                                style.font_face = file
                                save_home("reinit")
                                if touchmenu_instance and touchmenu_instance.updateItems then
                                    touchmenu_instance:updateItems()
                                end
                            end
                        end,
                    })
                end,
                hold_callback = function(touchmenu_instance)
                    local style = ensure_datetime_text_style(mcfg, key)
                    if style.font_face ~= "default" then
                        style.font_face = "default"
                        save_home("reinit")
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end
                end,
            },
            {
                text = _("Use default style"),
                callback = function(touchmenu_instance)
                    mcfg.text_styles[key] = {
                        font_face = "default",
                        font_size = DEFAULT_DATETIME_FONT_SIZES[key],
                    }
                    save_home("reinit")
                    if touchmenu_instance and touchmenu_instance.updateItems then
                        touchmenu_instance:updateItems()
                    end
                end,
            },
        }
    end

    local function build_datetime_items()
        local mcfg = ensure_datetime_cfg(dcfg)
        return {
            {
                text = _("Automatic font size"),
                checked_func = function() return mcfg.automatic_font_size ~= false end,
                callback = function(touchmenu_instance)
                    mcfg.automatic_font_size = mcfg.automatic_font_size == false
                    save_home("reinit")
                    if touchmenu_instance and touchmenu_instance.updateItems then
                        touchmenu_instance:updateItems()
                    end
                end,
            },
            {
                text_func = function()
                    return string.format("%s %s", _("Maximum font size:"),
                        tostring(mcfg.max_font_size))
                end,
                enabled_func = function() return mcfg.automatic_font_size ~= false end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text = _("Time") .. " " .. _("font size"),
                        value = mcfg.max_font_size,
                        value_min = 8,
                        value_max = MAX_DATETIME_FONT_SIZE,
                        default_value = DEFAULT_DATETIME_MAX_FONT_SIZE,
                        callback = function(spin)
                            mcfg.max_font_size = spin.value
                            save_home("reinit")
                            if touchmenu_instance and touchmenu_instance.updateItems then
                                touchmenu_instance:updateItems()
                            end
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    return _("Time") .. ": " .. datetime_style_summary(mcfg, "time")
                end,
                sub_item_table = build_datetime_text_style_items(mcfg, "time", _("Time")),
            },
            {
                text_func = function()
                    return _("Date") .. ": " .. datetime_style_summary(mcfg, "date")
                end,
                sub_item_table = build_datetime_text_style_items(mcfg, "date", _("Date")),
            },
        }
    end

    local function save_featured_text_style(touchmenu_instance)
        save_home("reinit")
        if touchmenu_instance then touchmenu_instance:updateItems() end
    end

    local function featured_text_style_summary(mcfg, key)
        local style = ensure_featured_text_style(mcfg, key)
        local weight = style.bold and _("bold") or _("regular")
        return string.format("%s, %s, %s", font_label(style.font_face), tostring(style.font_size), weight)
    end

    local function build_featured_text_style_items(mcfg, key, label)
        local defaults = FEATURED_TEXT_STYLE_DEFAULTS[key]
        local items = {
            {
                text_func = function()
                    local style = ensure_featured_text_style(mcfg, key)
                    return string.format("%s %s", _("Font size:"), tostring(style.font_size))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local style = ensure_featured_text_style(mcfg, key)
                    UIManager:show(SpinWidget:new{
                        title_text = string.format("%s %s", label, _("font size")),
                        value = style.font_size,
                        value_min = 6,
                        value_max = 40,
                        default_value = defaults.font_size,
                        callback = function(spin)
                            style.font_size = math.max(6, math.min(40, spin.value))
                            save_featured_text_style(touchmenu_instance)
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    local style = ensure_featured_text_style(mcfg, key)
                    return string.format("%s %s", _("Font:"), font_label(style.font_face))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local ok_fc, FontChooser = pcall(require, "ui/widget/fontchooser")
                    if not ok_fc then return end
                    local style = ensure_featured_text_style(mcfg, key)
                    local default_font = chooser_default_font()
                    local display_face = style.font_face == "default" and default_font or style.font_face
                    UIManager:show(FontChooser:new{
                        title = string.format("%s %s", label, _("font")),
                        font_file = display_face,
                        default_font_file = default_font,
                        callback = function(file)
                            if style.font_face ~= file then
                                style.font_face = file
                                save_featured_text_style(touchmenu_instance)
                            end
                        end,
                    })
                end,
                hold_callback = function(touchmenu_instance)
                    local style = ensure_featured_text_style(mcfg, key)
                    if style.font_face ~= "default" then
                        style.font_face = "default"
                        save_featured_text_style(touchmenu_instance)
                    end
                end,
            },
            {
                text = _("Bold"),
                checked_func = function()
                    return ensure_featured_text_style(mcfg, key).bold == true
                end,
                callback = function(touchmenu_instance)
                    local style = ensure_featured_text_style(mcfg, key)
                    style.bold = style.bold ~= true
                    save_featured_text_style(touchmenu_instance)
                end,
            },
        }
        if key == "description" then
            items[#items + 1] = {
                text = _("Wrap description text"),
                checked_func = function()
                    return mcfg.wrap_description_text == true
                end,
                callback = function()
                    mcfg.wrap_description_text = mcfg.wrap_description_text ~= true
                    save_home("reinit")
                end,
            }
            items[#items + 1] = {
                text = _("Justify text"),
                checked_func = function()
                    return mcfg.justify_description_text == true
                end,
                callback = function()
                    mcfg.justify_description_text = mcfg.justify_description_text ~= true
                    save_home("reinit")
                end,
            }
            items[#items + 1] = {
                text = _("HTML"),
                checked_func = function()
                    return mcfg.format_description_html == true
                end,
                callback = function()
                    mcfg.format_description_html = mcfg.format_description_html ~= true
                    save_home("reinit")
                end,
            }
        end
        items[#items + 1] = {
            text = _("Use default style"),
            callback = function(touchmenu_instance)
                mcfg.text_styles[key] = {
                    font_face = defaults.font_face,
                    font_size = defaults.font_size,
                    bold = defaults.bold,
                }
                save_featured_text_style(touchmenu_instance)
            end,
        }
        return items
    end

    local function featured_text_style_item(mcfg, key, label, show_key)
        local item = {
            sub_title = label,
            text_func = function()
                return label .. ": " .. featured_text_style_summary(mcfg, key)
            end,
            sub_item_table = build_featured_text_style_items(mcfg, key, label),
        }
        if show_key then
            item.checked_func = function()
                return mcfg[show_key] ~= false
            end
            item.checkmark_callback = function()
                mcfg[show_key] = mcfg[show_key] == false
                save_home("reinit")
            end
        end
        return item
    end

    local function build_featured_text_styles_items(mcfg)
        local items = {
            needs_refresh = true,
            refresh_func = function()
                return build_featured_text_styles_items(mcfg)
            end,
        }
        items[#items + 1] = featured_text_style_item(mcfg, "title", _("Title"))
        items[#items + 1] = featured_text_style_item(mcfg, "author", _("Author"), "show_author")
        items[#items + 1] = featured_text_style_item(mcfg, "series", _("Series"), "show_series")
        items[#items + 1] = featured_text_style_item(
            mcfg, "description", _("Description"), "show_description")
        items[#items + 1] = featured_text_style_item(
            mcfg, "progress", _("Progress labels"))
        return items
    end

    local function featured_text_styles_item(mcfg)
        return {
            text = _("Text styles"),
            sub_item_table_func = function()
                return build_featured_text_styles_items(mcfg)
            end,
        }
    end

    local function interactive_item(mcfg)
        return {
            text = _("Interactive"),
            checked_func = function()
                return mcfg.interactive ~= false
            end,
            callback = function()
                mcfg.interactive = mcfg.interactive == false
                save_home("reinit")
            end,
        }
    end

    local function filter_status_item(mcfg, key, text)
        return {
            text = text,
            checked_func = function()
                return mcfg[key] == true
            end,
            callback = function()
                mcfg[key] = mcfg[key] ~= true
                save_home("reinit")
            end,
        }
    end

    local function toggle_featured_status_bar(mcfg)
        local enabled = mcfg.show_status_bar ~= true
        mcfg.show_status_bar = enabled
        if enabled and dcfg.show_status_bar ~= false then
            dcfg.show_status_bar = false
        end
        save_home("reinit")
    end

    local function featured_status_bar_options(mcfg)
        return {
            {
                text = _("Show bottom border"),
                checked_func = function()
                    return mcfg.status_bar_show_bottom_border ~= false
                end,
                callback = function()
                    mcfg.status_bar_show_bottom_border = mcfg.status_bar_show_bottom_border == false
                    save_home("reinit")
                end,
            },
            {
                text = _("Bold text"),
                checked_func = function()
                    return mcfg.status_bar_bold_text ~= false
                end,
                callback = function()
                    mcfg.status_bar_bold_text = mcfg.status_bar_bold_text == false
                    save_home("reinit")
                end,
            },
        }
    end

    local function path_label(path)
        if type(path) ~= "string" or path == "" then
            return _("None")
        end
        local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
        if ok_bim and BookInfoManager then
            local bi = BookInfoManager:getBookInfo(path, false)
            if bi and type(bi.title) == "string" and bi.title ~= "" then
                return bi.title
            end
        end
        return (path:match("([^/]+)$") or path):gsub("%.[^%.]+$", "")
    end

    local function choose_book(callback)
        local PathChooser = require("ui/widget/pathchooser")
        local paths = require("common/paths")
        local start_path = paths.getHomeDir() or G_reader_settings:readSetting("lastdir") or "/"
        UIManager:show(PathChooser:new{
            select_directory = false,
            select_file = true,
            show_files = true,
            path = start_path,
            onConfirm = function(file_path)
                local lfs = require("libs/libkoreader-lfs")
                if type(file_path) == "string" and lfs.attributes(file_path, "mode") == "file" then
                    callback(file_path)
                end
            end,
        })
    end

    local function choose_tag(callback)
        return Destination.chooseTag(callback)
    end

    local function choose_folder(callback)
        return Destination.chooseFolder(callback)
    end

    local function featured_source_label(source)
        local kind = type(source) == "table" and source.kind or "recent"
        if kind == "custom" then return _("Custom") end
        if kind == "to_be_read" then return _("To Be Read") end
        return _("Recently read")
    end

    local build_featured_widget_items
    local build_strip_widget_items

    local function refresh_widget_items(touchmenu_instance, builder)
        if touchmenu_instance and type(builder) == "function" then
            touchmenu_instance.item_table = builder()
            touchmenu_instance:updateItems()
        end
    end

    local function build_featured_source_items(mcfg, on_change)
        local function source_item(kind, label)
            return {
                text = label,
                radio = true,
                checked_func = function()
                    return mcfg.default_source.kind == kind
                end,
                callback = function()
                    if kind == "custom" and not mcfg.path then
                        choose_book(function(path)
                            mcfg.path = path
                            mcfg.default_source = { kind = kind }
                            save_home("reinit")
                            if on_change then on_change() end
                        end)
                        return
                    end
                    mcfg.default_source = { kind = kind }
                    save_home("reinit")
                    if on_change then on_change() end
                end,
            }
        end
        return {
            source_item("recent", _("Recently read")),
            source_item("to_be_read", _("To Be Read")),
            source_item("custom", _("Custom")),
        }
    end

    build_featured_widget_items = function()
        local mcfg = ensure_featured_cfg(dcfg, "featured")
        local items = {
            {
                text_func = function()
                    return _("Content: ")
                        .. featured_source_label(mcfg.default_source)
                end,
                sub_item_table_func = function(touchmenu_instance)
                    return build_featured_source_items(mcfg, function()
                        refresh_widget_items(touchmenu_instance, build_featured_widget_items)
                    end)
                end,
            },
            interactive_item(mcfg),
            {
                text = _("Top status bar"),
                checked_func = function()
                    return mcfg.show_status_bar == true
                end,
                checkmark_callback = function()
                    toggle_featured_status_bar(mcfg)
                end,
                sub_item_table = featured_status_bar_options(mcfg),
            },
            featured_text_styles_item(mcfg),
            {
                text = _("Progress"),
                checked_func = function()
                    return mcfg.show_progress ~= false
                end,
                checkmark_callback = function()
                    mcfg.show_progress = mcfg.show_progress == false
                    save_home("reinit")
                end,
                sub_item_table = build_progress_meta_items(mcfg),
            },
        }
        if mcfg.default_source.kind == "custom" then
            items[#items + 1] = {
                text_func = function()
                    return _("Book: ") .. path_label(mcfg.path)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    choose_book(function(path)
                        mcfg.path = path
                        mcfg.default_source = { kind = "custom" }
                        save_home("reinit")
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end)
                end,
            }
            items[#items + 1] = {
                text = _("Clear book"),
                enabled_func = function()
                    return type(mcfg.path) == "string" and mcfg.path ~= ""
                end,
                callback = function()
                    mcfg.path = nil
                    save_home("reinit")
                end,
            }
        end
        return items
    end

    local function source_label(source)
        source = type(source) == "table" and source or { kind = "recent" }
        local labels = {
            recent = _("Recent"), favorites = _("Favorites"),
            to_be_read = _("To Be Read"), authors = _("Authors"),
            series = _("Series"), languages = _("Languages"), tags = _("Tags"),
            collections = _("Collections"), custom = _("Custom books"),
        }
        if source.kind == "tag" then return source.value or _("Specific tag") end
        if source.kind == "folder" then return path_label(source.value) end
        return labels[source.kind] or _("Recent")
    end

    local function build_default_source_items(mcfg, on_change)
        local items = {}
        local function set_default_source(source)
            mcfg.default_source = source
            dcfg.strip_memory = nil
        end
        for _i, entry in ipairs(ButtonModel.builtins()) do
            if entry.source == true then
                local kind = entry.id
                items[#items + 1] = {
                    text = entry.label,
                    radio = true,
                    checked_func = function()
                        return mcfg.default_source.kind == kind
                    end,
                    callback = function()
                        set_default_source({ kind = kind })
                        save_home("reinit")
                        if on_change then on_change() end
                    end,
                }
            end
        end
        items[#items + 1] = {
            text = _("Specific tag"),
            radio = true,
            checked_func = function() return mcfg.default_source.kind == "tag" end,
            callback = function()
                choose_tag(function(tag)
                    set_default_source({ kind = "tag", value = tag })
                    mcfg.sources.tag.tag = tag
                    save_home("reinit")
                    if on_change then on_change() end
                end)
            end,
        }
        items[#items + 1] = {
            text = _("Folder"),
            radio = true,
            checked_func = function() return mcfg.default_source.kind == "folder" end,
            callback = function()
                choose_folder(function(path)
                    set_default_source({ kind = "folder", value = path })
                    save_home("reinit")
                    if on_change then on_change() end
                end)
            end,
        }
        items[#items + 1] = {
            text = _("Custom books"),
            radio = true,
            checked_func = function() return mcfg.default_source.kind == "custom" end,
            callback = function()
                set_default_source({ kind = "custom" })
                save_home("reinit")
                if on_change then on_change() end
            end,
        }
        return items
    end

    local function strip_default_source(mcfg)
        if mcfg.controls.enabled == true then
            local source = ButtonModel.firstVisibleSource(mcfg.controls)
            if source then return source end
        end
        return mcfg.default_source
    end

    local function tbr_order_item()
        return IconItem.decorate({
            text = _("Order"),
            _zen_settings_submenu = true,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                require("common/tbr_index").showOrder({
                    plugin = ctx.plugin,
                    settings_resume = touchmenu_instance
                        and touchmenu_instance._zen_settings_resume,
                    on_change = ctx.settings_apply
                        and ctx.settings_apply.refresh_tbr_on_menu_close,
                })
            end,
        }, icons.sort)
    end

    local function authors_sort_item()
        local items = {}
        for _i, option in ipairs(author_sort.options(_)) do
            local collate = option.key
            items[#items + 1] = {
                text = option.text,
                radio = true,
                checked_func = function()
                    local group_view = type(config.group_view) == "table"
                        and config.group_view or {}
                    return author_sort.normalize(group_view.authors_collate) == collate
                end,
                callback = function() set_authors_collate(collate) end,
            }
        end
        return {
            text_func = function()
                local group_view = type(config.group_view) == "table"
                    and config.group_view or {}
                local mode = author_sort.normalize(group_view.authors_collate)
                local label = mode == "authors_last" and _("Last name") or _("First name")
                return _("Sort by") .. ": " .. label
            end,
            sub_item_table = items,
        }
    end

    local function edit_strip_label(controls, entry, touchmenu_instance)
        local InputDialog = require("ui/widget/inputdialog")
        local dialog
        dialog = InputDialog:new{
            title = _("Custom tab label"),
            input = ButtonModel.label(controls, entry),
            buttons = {{
                { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                {
                    text = _("Set"),
                    is_enter_default = true,
                    callback = function()
                        local label = dialog:getInputText()
                        if entry.id:sub(1, 3) == "hs_" then
                            entry.label = label
                        else
                            controls.labels[entry.id] = label
                        end
                        UIManager:close(dialog)
                        save_home("reinit")
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                },
            }},
        }
        UIManager:show(dialog)
    end

    local function count_strip_buttons(controls)
        local count = 0
        for _i, id in ipairs(controls.order) do
            if controls.show_buttons[id] == true then count = count + 1 end
        end
        return count
    end

    local function clear_strip_memory_for_control(id)
        local memory = type(dcfg.strip_memory) == "table" and dcfg.strip_memory or nil
        if memory and memory.active_id == id then dcfg.strip_memory = nil end
    end

    local function remove_strip_button(controls, id)
        for i, entry in ipairs(controls.custom_buttons) do
            if entry.id == id then table.remove(controls.custom_buttons, i); break end
        end
        controls.show_buttons[id] = nil
        local order = {}
        for _i, ordered_id in ipairs(controls.order) do
            if ordered_id ~= id then order[#order + 1] = ordered_id end
        end
        controls.order = order
        clear_strip_memory_for_control(id)
    end

    local function reset_strip_tabs(mcfg)
        local defaults = HomePresets.defaultHomePage().modules.strip.controls
        local controls = mcfg.controls
        for _i, entry in ipairs(controls.custom_buttons) do
            if type(entry) == "table" and type(entry.id) == "string"
                    and entry.id ~= "" then
                defaults.order[#defaults.order + 1] = entry.id
                defaults.show_buttons[entry.id] = false
            end
        end
        controls.labels = defaults.labels
        controls.order = defaults.order
        controls.show_buttons = defaults.show_buttons
        dcfg.strip_memory = nil
        save_home("reinit")
    end

    local function add_strip_builtin(controls, touchmenu_instance)
        if count_strip_buttons(controls) >= 7 then
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{ text = _("Maximum 7 tabs allowed") })
            return
        end
        local selected = {}
        for _i, id in ipairs(controls.order) do selected[id] = true end
        local items = {}
        for _i, entry in ipairs(ButtonModel.builtins()) do
            if not selected[entry.id] then
                items[#items + 1] = {
                    text = entry.id == "tags" and _("All tags") or entry.label,
                    entry = entry,
                }
            end
        end
        table.sort(items, function(a, b) return a.text < b.text end)
        if #items == 0 then return end
        require("common/ui/zen_menu_picker"){
            title = _("Choose tab"),
            items = items,
            on_select = function(item)
                local entry = item and item.entry
                if not entry or count_strip_buttons(controls) >= 7 then return end
                controls.order[#controls.order + 1] = entry.id
                controls.show_buttons[entry.id] = true
                save_home("reinit")
                if touchmenu_instance and touchmenu_instance.backToUpperMenu then
                    touchmenu_instance:backToUpperMenu()
                end
            end,
        }
    end

    local function commit_strip_button(controls, entry)
        if count_strip_buttons(controls) >= 7 then
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{ text = _("Maximum 7 tabs allowed") })
            return false
        end
        controls.next_custom_id = (tonumber(controls.next_custom_id) or 0) + 1
        entry.id = "hs_" .. controls.next_custom_id
        controls.custom_buttons[#controls.custom_buttons + 1] = entry
        controls.order[#controls.order + 1] = entry.id
        controls.show_buttons[entry.id] = true
        save_home("reinit")
        return true
    end

    local function add_strip_plugin(controls)
        local plugins = PluginScan.scan()
        local items = {}
        for _i, plugin in ipairs(plugins) do
            items[#items + 1] = { text = plugin.title, plugin = plugin }
        end
        require("common/ui/zen_menu_picker"){
            title = _("Choose plugin menu"),
            items = items,
            on_select = function(item)
                local plugin = item and item.plugin
                if plugin then
                    commit_strip_button(controls, {
                        type = "plugin", label = plugin.title,
                        plugin_title = plugin.title,
                        plugin = { key = plugin.key, method = plugin.method },
                    })
                end
            end,
        }
    end

    local function add_strip_menu(controls)
        local found = NativeMenu.scan("filemanager")
        local items = {}
        for _i, item in ipairs(found) do
            items[#items + 1] = { text = item.title, target = item }
        end
        require("common/ui/zen_menu_picker"){
            title = _("Choose KOReader menu"),
            items = items,
            on_select = function(item)
                local target = item and item.target
                if target then
                    commit_strip_button(controls, {
                        type = "koreader_menu", label = target.title,
                        koreader_menu = { id = target.id, title = target.title },
                    })
                end
            end,
        }
    end

    local function add_strip_control(controls)
        local quick = rawget(_G, "__ZEN_UI_QUICK_SETTINGS")
        local items = quick and type(quick.getItems) == "function" and quick.getItems() or {}
        require("common/ui/zen_menu_picker"){
            title = _("Choose control"),
            items = items,
            on_select = function(item)
                if item then
                    commit_strip_button(controls, {
                        type = "quick_setting", label = item.label,
                        quick_setting_id = item.id,
                    })
                end
            end,
        }
    end

    local function add_strip_action(controls, touchmenu_instance)
        local ok_dispatcher, Dispatcher = pcall(require, "dispatcher")
        if not ok_dispatcher or not Dispatcher then return end
        local entry = { type = "action", action = {} }
        local items, caller = {}, {}
        Dispatcher:addSubMenu(caller, items, entry, "action")
        DispatcherMenu.wrap(items, caller, function()
            if entry.action and next(entry.action) then
                local label = Dispatcher:menuTextFunc(entry.action)
                entry.label = label ~= _("Nothing") and label or _("Action")
                if commit_strip_button(controls, entry) and touchmenu_instance then
                    touchmenu_instance:backToUpperMenu()
                end
            end
        end, "_zen_strip_dispatch")
        return items
    end

    local function build_add_strip_button_items(mcfg)
        local controls = mcfg.controls
        return {
            IconItem.decorate({
                text = _("Tab"),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    add_strip_builtin(controls, touchmenu_instance)
                end,
            }, icons.settings_navbar),
            IconItem.decorate({
                text = _("Specific tag"),
                keep_menu_open = true,
                callback = function()
                    choose_tag(function(tag)
                        commit_strip_button(controls,
                            { type = "tag", tag = tag, label = tag })
                    end)
                end,
            }, icons.keywords),
            IconItem.decorate({
                text = _("Folder"),
                keep_menu_open = true,
                callback = function()
                    choose_folder(function(path)
                        commit_strip_button(controls, {
                            type = "folder", folder = path, label = path_label(path),
                        })
                    end)
                end,
            }, icons.settings_folders),
            IconItem.decorate({
                text = _("Action"),
                keep_menu_open = true,
                sub_item_table_func = function(touchmenu_instance)
                    return add_strip_action(controls, touchmenu_instance)
                end,
            }, icons.action),
            IconItem.decorate({
                text = _("Control"),
                keep_menu_open = true,
                callback = function() add_strip_control(controls) end,
            }, icons.settings_quick),
            IconItem.decorate({
                text = _("Plugin"),
                keep_menu_open = true,
                callback = function() add_strip_plugin(controls) end,
            }, icons.plugin),
            IconItem.decorate({
                text = _("KOReader menu"),
                keep_menu_open = true,
                callback = function() add_strip_menu(controls) end,
            }, icons.open_menu),
        }
    end

    local function show_strip_buttons(mcfg, parent_touchmenu)
        local ZenArrangeList = require("common/ui/zen_arrange_list")
        local controls = mcfg.controls
        local settings_page = require("modules/settings/zen_settings_page")
        local settings_resume = parent_touchmenu
            and parent_touchmenu._zen_settings_resume or nil
        if type(settings_resume) == "table" then
            local path = {}
            for _i, key in ipairs(settings_resume.path or {}) do path[#path + 1] = key end
            path[#path + 1] = _("Tabs")
            settings_resume = {
                opener = settings_resume.opener,
                path = path,
                deferred_parent = settings_resume.deferred_parent,
            }
        else
            settings_resume = select(2, settings_page.rememberStandaloneArrangeRoute({
                { text = _("Home"), occurrence = 1 },
            }, _("Widgets"), { "strip", _("Controls"), _("Tabs") }))
        end
        local sort_items
        local function build_sort_items()
            sort_items = {}
            for _i, id in ipairs(controls.order) do
                local entry = ButtonModel.find(controls, id)
                if entry then
                    local button_id = id
                    local button_entry = entry
                    local sort_item = {
                        text_func = function()
                            return ButtonModel.label(controls, button_entry)
                        end,
                        orig_item = button_id,
                        checked_func = function()
                            return controls.show_buttons[button_id] == true
                        end,
                        callback = function()
                            if controls.show_buttons[button_id] == true then
                                if count_strip_buttons(controls) <= 1 then return end
                                controls.show_buttons[button_id] = false
                                clear_strip_memory_for_control(button_id)
                            elseif count_strip_buttons(controls) < 7 then
                                controls.show_buttons[button_id] = true
                            end
                            save_home("reinit")
                        end,
                        sub_item_table = {
                            {
                                text = _("Label"),
                                callback = function(touchmenu_instance)
                                    edit_strip_label(
                                        controls, button_entry, touchmenu_instance)
                                end,
                            },
                            {
                                text = _("Delete"),
                                enabled_func = function()
                                    return controls.show_buttons[button_id] ~= true
                                        or count_strip_buttons(controls) > 1
                                end,
                                callback = function(touchmenu_instance)
                                    if controls.show_buttons[button_id] == true
                                            and count_strip_buttons(controls) <= 1 then
                                        return
                                    end
                                    local ConfirmBox = require("ui/widget/confirmbox")
                                    UIManager:show(ConfirmBox:new{
                                        text = _("Delete this tab?"),
                                        ok_text = _("Delete"),
                                        ok_callback = function()
                                            remove_strip_button(controls, button_id)
                                            save_home("reinit")
                                            if touchmenu_instance then
                                                touchmenu_instance:backToUpperMenu()
                                            end
                                        end,
                                    })
                                end,
                            },
                        },
                    }
                    if button_id == "to_be_read" then
                        table.insert(sort_item.sub_item_table, 2, tbr_order_item())
                    elseif button_id == "authors" then
                        table.insert(sort_item.sub_item_table, 2, authors_sort_item())
                    end
                    sort_items[#sort_items + 1] = sort_item
                end
            end
            return sort_items
        end
        sort_items = build_sort_items()
        ZenArrangeList.show{
            title = _("Tabs"),
            item_table = sort_items,
            add_title = _("Add"),
            add_item_table = build_add_strip_button_items(mcfg),
            hide_footer_cancel = true,
            settings_resume = settings_resume,
            callback = function()
                local order = {}
                for _i, item in ipairs(sort_items) do
                    if item.orig_item then order[#order + 1] = item.orig_item end
                end
                controls.order = order
                save_home("reinit")
            end,
            refresh_func = build_sort_items,
        }
    end

    local function build_custom_books_items(mcfg)
        local custom = mcfg.sources.custom
        local items = {{
            text = _("Add book"),
            enabled_func = function() return #custom.paths < custom_strip_max_books end,
            callback = function()
                choose_book(function(path)
                    for _i, existing in ipairs(custom.paths) do
                        if existing == path then return end
                    end
                    custom.paths[#custom.paths + 1] = path
                    save_home("reinit")
                end)
            end,
        }}
        for i, path in ipairs(custom.paths) do
            items[#items + 1] = {
                text = _("Remove: ") .. path_label(path),
                callback = function()
                    table.remove(custom.paths, i)
                    save_home("reinit")
                end,
            }
        end
        return items
    end

    local function strip_control_style_summary(mcfg)
        local style = ensure_strip_cfg(dcfg).controls.text_style
        local weight = style.bold and _("bold") or _("regular")
        return string.format("%s, %s, %s",
            font_label(style.font_face), tostring(style.font_size), weight)
    end

    local function save_strip_control_style(touchmenu_instance)
        save_home("reinit")
        if touchmenu_instance and touchmenu_instance.updateItems then
            touchmenu_instance:updateItems()
        end
    end

    local function build_strip_control_font_items(mcfg)
        return {
            {
                text_func = function()
                    local style = ensure_strip_cfg(dcfg).controls.text_style
                    return string.format("%s %s", _("Font size:"), tostring(style.font_size))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local style = ensure_strip_cfg(dcfg).controls.text_style
                    UIManager:show(SpinWidget:new{
                        title_text = string.format("%s %s", _("Controls"), _("font size")),
                        value = style.font_size,
                        value_min = 6,
                        value_max = 24,
                        default_value = DEFAULT_STRIP_CONTROL_TEXT_STYLE.font_size,
                        callback = function(spin)
                            style.font_size = spin.value
                            save_strip_control_style(touchmenu_instance)
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    local style = ensure_strip_cfg(dcfg).controls.text_style
                    return string.format("%s %s", _("Font:"), font_label(style.font_face))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local ok_fc, FontChooser = pcall(require, "ui/widget/fontchooser")
                    if not ok_fc then return end
                    local style = ensure_strip_cfg(dcfg).controls.text_style
                    local default_font = chooser_default_font()
                    local display_face = style.font_face == "default"
                        and default_font or style.font_face
                    UIManager:show(FontChooser:new{
                        title = string.format("%s %s", _("Controls"), _("font")),
                        font_file = display_face,
                        default_font_file = default_font,
                        callback = function(file)
                            if style.font_face ~= file then
                                style.font_face = file
                                save_strip_control_style(touchmenu_instance)
                            end
                        end,
                    })
                end,
                hold_callback = function(touchmenu_instance)
                    local style = ensure_strip_cfg(dcfg).controls.text_style
                    if style.font_face ~= "default" then
                        style.font_face = "default"
                        save_strip_control_style(touchmenu_instance)
                    end
                end,
            },
            {
                text = _("Bold"),
                checked_func = function()
                    return ensure_strip_cfg(dcfg).controls.text_style.bold == true
                end,
                callback = function(touchmenu_instance)
                    local style = ensure_strip_cfg(dcfg).controls.text_style
                    style.bold = style.bold ~= true
                    save_strip_control_style(touchmenu_instance)
                end,
            },
            {
                text = _("Use default style"),
                callback = function(touchmenu_instance)
                    mcfg.controls.text_style = {
                        font_face = DEFAULT_STRIP_CONTROL_TEXT_STYLE.font_face,
                        font_size = DEFAULT_STRIP_CONTROL_TEXT_STYLE.font_size,
                        bold = DEFAULT_STRIP_CONTROL_TEXT_STYLE.bold,
                    }
                    save_strip_control_style(touchmenu_instance)
                end,
            },
        }
    end

    build_strip_widget_items = function()
        local mcfg = ensure_strip_cfg(dcfg)
        local recent = mcfg.sources.recent
        local items = {
            {
                text = _("Controls"),
                sub_item_table_func = function()
                    return {
                        {
                            text = _("Show controls"),
                            checked_func = function()
                                return mcfg.controls.enabled == true
                            end,
                            callback = function()
                                mcfg.controls.enabled = mcfg.controls.enabled ~= true
                                save_home("reinit")
                            end,
                        },
                        IconItem.decorate({
                            text = _("Tabs"),
                            _zen_settings_submenu = true,
                            keep_menu_open = true,
                            callback = function(touchmenu_instance)
                                show_strip_buttons(mcfg, touchmenu_instance)
                            end,
                        }, icons.navbar_tabs),
                        {
                            text_func = function()
                                return _("Font") .. ": " .. strip_control_style_summary(mcfg)
                            end,
                            sub_item_table_func = function()
                                return build_strip_control_font_items(mcfg)
                            end,
                        },
                        IconItem.decorate({
                            text = _("Reset to defaults"),
                            separator = true,
                            keep_menu_open = true,
                            callback = function(touchmenu_instance)
                                local ConfirmBox = require("ui/widget/confirmbox")
                                UIManager:show(ConfirmBox:new{
                                    text = _("Reset Controls to defaults?"),
                                    ok_text = _("Reset"),
                                    ok_callback = function()
                                        reset_strip_tabs(mcfg)
                                        if touchmenu_instance
                                                and touchmenu_instance.updateItems then
                                            touchmenu_instance:updateItems()
                                        end
                                    end,
                                })
                            end,
                        }, icons.restart),
                    }
                end,
            },
            {
                text = _("Show book titles"),
                checked_func = function() return mcfg.show_strip_titles == true end,
                callback = function()
                    mcfg.show_strip_titles = mcfg.show_strip_titles ~= true
                    save_home("reinit")
                end,
            },
            {
                text = _("Show badges"),
                checked_func = function() return mcfg.show_badges == true end,
                callback = function()
                    mcfg.show_badges = mcfg.show_badges ~= true
                    save_home("reinit")
                end,
            },
            {
                text = _("Center books"),
                checked_func = function() return mcfg.center_books == true end,
                callback = function()
                    mcfg.center_books = mcfg.center_books ~= true
                    save_home("reinit")
                end,
            },
            interactive_item(mcfg),
            {
                text = _("Two rows"),
                checked_func = function() return mcfg.two_rows == true end,
                callback = function() toggle_strip_rows("strip", mcfg) end,
            },
            {
                text_func = function()
                    return _("Max books shown: ") .. tostring(mcfg.count or 4)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local is_two = mcfg.two_rows == true
                    local responsive_max = responsive_strip_max_books(is_two)
                    local configured_count = mcfg.count or (is_two and 8 or 4)
                    UIManager:show(SpinWidget:new{
                        title_text = _("Max books shown"),
                        value = math.min(configured_count, responsive_max),
                        value_min = is_two and 2 or 3,
                        value_max = responsive_max,
                        ok_always_enabled = configured_count > responsive_max,
                        callback = function(spin)
                            mcfg.count = spin.value
                            save_home("reinit")
                            if touchmenu_instance and touchmenu_instance.updateItems then
                                touchmenu_instance:updateItems()
                            end
                        end,
                    })
                end,
            },
        }
        if mcfg.controls.enabled ~= true then
            table.insert(items, 1, {
                text_func = function()
                    return _("Content: ") .. source_label(mcfg.default_source)
                end,
                sub_item_table_func = function(touchmenu_instance)
                    return build_default_source_items(mcfg, function()
                        refresh_widget_items(touchmenu_instance, build_strip_widget_items)
                    end)
                end,
            })
        end
        local source = strip_default_source(mcfg)
        if mcfg.controls.enabled ~= true and source.kind == "to_be_read" then
            table.insert(items, 2, tbr_order_item())
        elseif source.kind == "recent" then
            table.insert(items, 2, {
                text = _("Recent filters"),
                sub_item_table = {
                    filter_status_item(recent, "filter_unread", _("Hide unread books")),
                    filter_status_item(recent, "filter_tbr", _("Hide on-hold books")),
                    filter_status_item(recent, "filter_finished", _("Hide finished books")),
                },
            })
        elseif source.kind == "custom" and source.paths == nil then
            table.insert(items, 2, {
                text = _("Custom books"),
                sub_item_table_func = function() return build_custom_books_items(mcfg) end,
            })
        end
        return items
    end

    local function toggle_widget_enabled(cid)
        if dcfg.rows.enabled[cid] == true then
            if enabled_widget_count() <= 1 and Registry.get(cid) then
                return false
            end
            dcfg.rows.enabled[cid] = false
        else
            local comp = Registry.get(cid)
            if not comp then return false end
            local used = used_home_units()
            local needed = component_units(cid)
            if used + needed > capacity_units then
                show_capacity_message(used, needed)
                return false
            end
            dcfg.rows.enabled[cid] = true
        end
        save_home("reinit")
        return true
    end

    local build_widget_settings_items
    local widget_ids_with_settings = {
        datetime = true,
        featured = true,
        stats_triplet = true,
        reading_goals = true,
        strip = true,
        quotes = true,
    }

    local function arrange_search_items()
        dcfg.rows = Registry.normalizeRows(dcfg.rows, DEFAULT_ORDER, DEFAULT_ENABLED)
        local items = {}
        for _i, id in ipairs(dcfg.rows.order) do
            if widget_ids_with_settings[id] then
                local widget_id = id
                items[#items + 1] = {
                    text = component_label(widget_id),
                    _zen_search_breadcrumb = _("Home"),
                    _zen_search_open = function()
                        return open_widget_settings(widget_id)
                    end,
                }
            end
        end
        return items
    end

    local function arrange_widgets()
        local ZenArrangeList = require("common/ui/zen_arrange_list")
        dcfg.rows = Registry.normalizeRows(dcfg.rows, DEFAULT_ORDER, DEFAULT_ENABLED)
        local order = dcfg.rows.order
        local sort_items = {}
        local function should_dim_widget(id)
            local comp = Registry.get(id)
            if not comp then return true end
            return dcfg.rows.enabled[id] ~= true
                and used_home_units() + component_units(id) > capacity_units
        end
        local function update_dim_states()
            for _i, sort_item in ipairs(sort_items) do
                sort_item.dim = should_dim_widget(sort_item.orig_item)
            end
        end
        for _i, id in ipairs(order) do
            local item = {
                text = component_label(id),
                orig_item = id,
                dim = should_dim_widget(id),
                checked_func = function()
                    return dcfg.rows.enabled[id] == true
                end,
                callback = function()
                    if toggle_widget_enabled(id) then
                        update_dim_states()
                    end
                end,
            }
            if widget_ids_with_settings[id] then
                item.sub_title = component_label(id)
                item.sub_item_table_func = function()
                    return build_widget_settings_items(id)
                end
            end
            sort_items[#sort_items + 1] = item
        end
        ZenArrangeList.show{
            title = _("Widgets"),
            item_table = sort_items,
            plugin = ctx.plugin,
            callback = function()
                local new_order = {}
                for _i, item in ipairs(sort_items) do
                    new_order[#new_order + 1] = item.orig_item
                end
                dcfg.rows.order = new_order
                save_home("reinit")
            end,
        }
    end

    local function all_home_presets()
        local all = HomePresets.getBuiltinPresets()
        local presets = PresetStore.list("home")
        for _i, preset in ipairs(presets) do
            all[#all + 1] = preset
        end
        return all
    end

    local function apply_home_preset(preset, touchmenu_instance)
        local preset_name = preset and preset.name
        HomePresets.applyHomePagePreset(dcfg, preset)
        dcfg.strip_memory = nil
        dcfg.active_preset = preset_name
        PresetStore.setActivePreset("home", preset_name)
        ensure_cfg(config)
        save_home("reinit", { make_builtin_editable = false })
        if touchmenu_instance then touchmenu_instance:updateItems() end
    end

    local build_preset_items

    local function refresh_preset_menu(touchmenu_instance)
        if touchmenu_instance then
            touchmenu_instance.item_table = build_preset_items()
            touchmenu_instance:updateItems()
        end
    end

    local function show_rename_preset_dialog(preset_name, touchmenu_instance)
        if type(preset_name) ~= "string" or preset_name == "" then return end
        local InputDialog = require("ui/widget/inputdialog")
        local dlg
        dlg = InputDialog:new{
            title = _("Preset name"),
            input = preset_name,
            input_hint = _("Home page preset"),
            buttons = {{
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dlg) end,
                },
                {
                    text = _("Rename"),
                    is_enter_default = true,
                    callback = function()
                        local name = dlg:getInputText()
                        if not name or name:match("^%s*$") then return end
                        name = name:match("^%s*(.-)%s*$")
                        if name == preset_name then
                            UIManager:close(dlg)
                            return
                        end
                        if HomePresets.isBuiltinPresetName(name) then
                            name = unique_user_preset_name(HomePresets.CUSTOM_PRESET_NAME)
                        elseif PresetStore.find("home", name) then
                            name = unique_user_preset_name(name)
                        end
                        local preset = PresetStore.find("home", preset_name)
                        if not preset then return end
                        if type(preset.home_page) == "table" then
                            preset.home_page.title = name
                        else
                            preset.title = name
                        end
                        UIManager:close(dlg)
                        PresetStore.save("home", name, preset)
                        PresetStore.delete("home", preset_name)
                        if dcfg.active_preset == preset_name then
                            dcfg.active_preset = name
                            dcfg.title = name
                            PresetStore.setActivePreset("home", name)
                            save_home("reinit")
                        end
                        refresh_preset_menu(touchmenu_instance)
                    end,
                },
            }},
        }
        UIManager:show(dlg)
        dlg:onShowKeyboard()
    end

    local function show_delete_preset_confirm(preset_name, touchmenu_instance)
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text = _("Delete preset?") .. "\n\n" .. (preset_name or ""),
            ok_text = _("Delete"),
            ok_callback = function()
                PresetStore.delete("home", preset_name)
                if dcfg.active_preset == preset_name then
                    dcfg.active_preset = nil
                    PresetStore.setActivePreset("home", nil)
                end
                save_home("reinit")
                refresh_preset_menu(touchmenu_instance)
            end,
        })
    end

    function build_preset_items()
        local all = all_home_presets()
        local items = {}

        items[#items + 1] = {
            text = _("Save current home page as preset"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local InputDialog = require("ui/widget/inputdialog")
                local dlg
                dlg = InputDialog:new{
                    title = _("Preset name"),
                    input = "",
                    input_hint = _("Home page preset"),
                    buttons = {{
                        {
                            text = _("Cancel"),
                            id = "close",
                            callback = function() UIManager:close(dlg) end,
                        },
                        {
                            text = _("Save"),
                            is_enter_default = true,
                            callback = function()
                                local name = dlg:getInputText()
                                if not name or name:match("^%s*$") then return end
                                name = name:match("^%s*(.-)%s*$")
                                if HomePresets.isBuiltinPresetName(name) then
                                    name = unique_user_preset_name(HomePresets.CUSTOM_PRESET_NAME)
                                end
                                UIManager:close(dlg)
                                local state = HomePresets.captureHomePage(dcfg)
                                state.title = name
                                PresetStore.save("home", name, state)
                                dcfg.active_preset = name
                                PresetStore.setActivePreset("home", name)
                                save_home("reinit")
                                refresh_preset_menu(touchmenu_instance)
                            end,
                        },
                    }},
                }
                UIManager:show(dlg)
                dlg:onShowKeyboard()
            end,
            separator = #all > 0,
        }

        for i, preset in ipairs(all) do
            local preset_name = preset.name
            local is_builtin = preset.builtin == true
            items[#items + 1] = {
                text_func = function()
                    return preset_name or _("Unnamed preset")
                end,
                radio = true,
                checked_func = function()
                    return dcfg.active_preset == preset_name
                end,
                callback = function(touchmenu_instance)
                    apply_home_preset(preset, touchmenu_instance)
                end,
                hold_callback = not is_builtin and function(touchmenu_instance)
                    local ButtonDialog = require("ui/widget/buttondialog")
                    local dialog
                    dialog = ButtonDialog:new{
                        buttons = {
                            {{
                                text = _("Rename"),
                                callback = function()
                                    UIManager:close(dialog)
                                    show_rename_preset_dialog(preset_name, touchmenu_instance)
                                end,
                            }},
                            {{
                                text = _("Delete"),
                                callback = function()
                                    UIManager:close(dialog)
                                    show_delete_preset_confirm(preset_name, touchmenu_instance)
                                end,
                            }},
                        },
                    }
                    UIManager:show(dialog)
                end or nil,
                separator = i == #all or (is_builtin and all[i + 1] and all[i + 1].builtin ~= true),
            }
        end

        return items
    end

    local function build_goals_items()
        local goals_cfg = ensure_module_cfg(dcfg, "reading_goals")
        local items = {{
            text_func = function()
                return string.format("%s %s", _("Font size:"),
                    tostring(goals_cfg.font_size or DEFAULT_GOALS_FONT_SIZE))
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new{
                    title_text = _("Reading goals font size"),
                    value = goals_cfg.font_size or DEFAULT_GOALS_FONT_SIZE,
                    value_min = 8,
                    value_max = 32,
                    default_value = DEFAULT_GOALS_FONT_SIZE,
                    callback = function(spin)
                        goals_cfg.font_size = spin.value
                        goals_cfg.font_size_override = true
                        save_home("reinit")
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end,
                })
            end,
        }}
        local shared_items = ReadingGoals.settingsItems(dcfg.goals, function()
            save_home("reinit")
        end)
        for _i, item in ipairs(shared_items) do items[#items + 1] = item end
        return items
    end

    local stats_field_options = {
        { id = "today_pages", text = _("Pages today") },
        { id = "today_duration", text = _("Time today") },
        { id = "streak", text = _("Day streak") },
        { id = "week_pages", text = _("Pages this week") },
        { id = "week_duration", text = _("Time this week") },
    }
    local stats_field_labels = {}
    for _i, option in ipairs(stats_field_options) do
        stats_field_labels[option.id] = option.text
    end

    local function stats_style_summary(stats_cfg)
        local size = stats_cfg.automatic_font_size ~= false
            and _("Automatic") or tostring(stats_cfg.font_size or DEFAULT_STATS_FONT_SIZE)
        return size
    end

    local function build_stats_triplet_items()
        local stats_cfg = ensure_module_cfg(dcfg, "stats_triplet")
        local items = {
            {
                text = _("Automatic font size"),
                checked_func = function()
                    return stats_cfg.automatic_font_size ~= false
                end,
                callback = function(touchmenu_instance)
                    stats_cfg.automatic_font_size = stats_cfg.automatic_font_size == false
                    save_home("reinit")
                    if touchmenu_instance and touchmenu_instance.updateItems then
                        touchmenu_instance:updateItems()
                    end
                end,
            },
            {
                text_func = function()
                    return string.format("%s %s", _("Maximum font size:"),
                        tostring(stats_cfg.max_font_size or DEFAULT_STATS_MAX_FONT_SIZE))
                end,
                enabled_func = function()
                    return stats_cfg.automatic_font_size ~= false
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text = _("Stats font size"),
                        value = stats_cfg.max_font_size or DEFAULT_STATS_MAX_FONT_SIZE,
                        value_min = 8,
                        value_max = MAX_STATS_FONT_SIZE,
                        default_value = DEFAULT_STATS_MAX_FONT_SIZE,
                        callback = function(spin)
                            stats_cfg.max_font_size = spin.value
                            stats_cfg.automatic_font_size = false
                            save_home("reinit")
                            if touchmenu_instance and touchmenu_instance.updateItems then
                                touchmenu_instance:updateItems()
                            end
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    return string.format("%s %s", _("Font size:"),
                        stats_style_summary(stats_cfg))
                end,
                enabled_func = function()
                    return stats_cfg.automatic_font_size == false
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text = _("Stats font size"),
                        value = stats_cfg.font_size or DEFAULT_STATS_FONT_SIZE,
                        value_min = 8,
                        value_max = MAX_STATS_FONT_SIZE,
                        default_value = DEFAULT_STATS_FONT_SIZE,
                        callback = function(spin)
                            stats_cfg.font_size = spin.value
                            stats_cfg.automatic_font_size = false
                            save_home("reinit")
                            if touchmenu_instance and touchmenu_instance.updateItems then
                                touchmenu_instance:updateItems()
                            end
                        end,
                    })
                end,
            },
            {
                text = _("Stat separators"),
                sub_item_table = {
                    {
                        text = _("Dividing lines"),
                        radio = true,
                        checked_func = function()
                            return stats_cfg.stat_style ~= "outline" and stats_cfg.stat_style ~= "none"
                        end,
                        callback = function()
                            stats_cfg.stat_style = "divider"
                            save_home("reinit")
                        end,
                    },
                    {
                        text = _("Outlined boxes"),
                        radio = true,
                        checked_func = function()
                            return stats_cfg.stat_style == "outline"
                        end,
                        callback = function()
                            stats_cfg.stat_style = "outline"
                            save_home("reinit")
                        end,
                    },
                    {
                        text = _("None"),
                        radio = true,
                        checked_func = function()
                            return stats_cfg.stat_style == "none"
                        end,
                        callback = function()
                            stats_cfg.stat_style = "none"
                            save_home("reinit")
                        end,
                    },
                },
            },
        }
        for slot = 1, 3 do
            items[#items + 1] = {
                text_func = function()
                    local cur = dcfg.middle_stats_triplet[slot] or "today_pages"
                    return _("Stat slot ") .. tostring(slot) .. ": "
                        .. (stats_field_labels[cur] or stats_field_labels.today_pages)
                end,
                sub_item_table = (function()
                    local slot_items = {}
                    for _i, opt in ipairs(stats_field_options) do
                        local oid = opt.id
                        slot_items[#slot_items + 1] = {
                            text = opt.text,
                            radio = true,
                            checked_func = function()
                                return (dcfg.middle_stats_triplet[slot] or "today_pages") == oid
                            end,
                            callback = function()
                                dcfg.middle_stats_triplet[slot] = oid
                                save_home("reinit")
                            end,
                        }
                    end
                    return slot_items
                end)(),
            }
        end
        return items
    end

    local function build_quotes_items()
        local function quote_sources()
            if type(dcfg.quotes.sources) ~= "table" then
                dcfg.quotes.sources = { default = true }
            end
            return dcfg.quotes.sources
        end
        local function source_item(label, key)
            return {
                text = label,
                keep_menu_open = true,
                checked_func = function()
                    return quote_sources()[key] == true
                end,
                callback = function()
                    local sources = quote_sources()
                    sources[key] = sources[key] ~= true
                    if not sources.default and not sources.custom and not sources.annotations then
                        sources.default = true
                    end
                    save_home("reinit")
                end,
            }
        end
        local function quote_font_size()
            return dcfg.quotes.font_size or 12
        end
        local sources = quote_sources()
        if type(dcfg.quotes.custom_files) ~= "table" then
            if sources.custom == true then
                dcfg.quotes.custom_files = { ["quotes.lua"] = true }
            else
                dcfg.quotes.custom_files = {}
            end
        elseif sources.custom ~= true then
            dcfg.quotes.custom_files = {}
        end
        local function custom_quote_files()
            return dcfg.quotes.custom_files
        end
        local function has_selected_custom_file()
            for filename, selected in pairs(custom_quote_files()) do
                if filename and selected == true then return true end
            end
            return false
        end
        local function custom_quote_items()
            local items = {}
            for _i, filename in ipairs(HomeQuotes.listFiles(dcfg.quotes)) do
                local quote_file = filename
                items[#items + 1] = {
                    text = quote_file,
                    keep_menu_open = true,
                    checked_func = function()
                        return custom_quote_files()[quote_file] == true
                    end,
                    callback = function()
                        local files = custom_quote_files()
                        if files[quote_file] == true then
                            files[quote_file] = nil
                        else
                            files[quote_file] = true
                        end
                        local selected = has_selected_custom_file()
                        sources.custom = selected
                        if not selected and not sources.default and not sources.annotations then
                            sources.default = true
                        end
                        save_home("reinit")
                    end,
                }
            end
            return items
        end
        sources.custom = has_selected_custom_file()
        if not sources.custom and not sources.default and not sources.annotations then
            sources.default = true
        end
        local source_items = {
            source_item(_("Default quotes"), "default"),
            {
                text = _("Custom quotes"),
                sub_item_table_func = custom_quote_items,
            },
        }
        source_items[#source_items + 1] =
            source_item(_("Annotations"), "annotations")
        local items = {
            {
                text = _("Quote sources"),
                sub_item_table = source_items,
            },
            {
                text = _("New quote"),
                sub_item_table = {
                    {
                        text = _("Daily"),
                        checked_func = function()
                            return dcfg.quotes.rotation ~= "refresh"
                        end,
                        callback = function()
                            dcfg.quotes.rotation = "daily"
                            save_home("reinit")
                        end,
                    },
                    {
                        text = _("On Home refresh"),
                        checked_func = function()
                            return dcfg.quotes.rotation == "refresh"
                        end,
                        callback = function()
                            dcfg.quotes.rotation = "refresh"
                            save_home("reinit")
                        end,
                    },
                },
            },
            {
                text = _("Automatic font size"),
                checked_func = function()
                    return dcfg.quotes.automatic_font_size == true
                end,
                callback = function(touchmenu_instance)
                    dcfg.quotes.automatic_font_size =
                        dcfg.quotes.automatic_font_size ~= true
                    save_home("reinit")
                    if touchmenu_instance and touchmenu_instance.updateItems then
                        touchmenu_instance:updateItems()
                    end
                end,
            },
        }

        items[#items + 1] = {
            text_func = function()
                return string.format("%s %s", _("Maximum font size:"),
                    tostring(dcfg.quotes.max_font_size or 14))
            end,
            enabled_func = function()
                return dcfg.quotes.automatic_font_size == true
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new{
                    title_text = _("Maximum quote font size"),
                    value = dcfg.quotes.max_font_size or 14,
                    value_min = 4,
                    value_max = 32,
                    default_value = 14,
                    callback = function(spin)
                        dcfg.quotes.max_font_size = spin.value
                        save_home("reinit")
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end,
                })
            end,
        }
        items[#items + 1] = {
            text_func = function()
                return string.format("%s %s", _("Font size:"), tostring(quote_font_size()))
            end,
            enabled_func = function()
                return dcfg.quotes.automatic_font_size ~= true
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                UIManager:show(SpinWidget:new{
                    title_text = _("Quote font size"),
                    value = quote_font_size(),
                    value_min = 4,
                    value_max = 32,
                    default_value = 12,
                    callback = function(spin)
                        dcfg.quotes.font_size = spin.value
                        dcfg.quotes.font_size_override = true
                        save_home("reinit")
                        if touchmenu_instance and touchmenu_instance.updateItems then
                            touchmenu_instance:updateItems()
                        end
                    end,
                })
            end,
        }

        items[#items + 1] = {
            text = _("Show author"),
            checked_func = function()
                return dcfg.quotes.show_author ~= false
            end,
            callback = function()
                dcfg.quotes.show_author = dcfg.quotes.show_author == false
                save_home("reinit")
            end,
        }
        items[#items + 1] = {
            text = _("Show title"),
            checked_func = function()
                return dcfg.quotes.show_title ~= false
            end,
            callback = function()
                dcfg.quotes.show_title = dcfg.quotes.show_title == false
                save_home("reinit")
            end,
        }
        return items
    end

    build_widget_settings_items = function(id)
        local items
        if id == "datetime" then
            items = build_datetime_items()
        elseif id == "featured" then
            items = build_featured_widget_items()
        elseif id == "strip" then
            items = build_strip_widget_items()
        elseif id == "reading_goals" then
            items = build_goals_items()
        elseif id == "stats_triplet" then
            items = build_stats_triplet_items()
        elseif id == "quotes" then
            items = build_quotes_items()
        end
        return items
    end

    open_widget_settings = function(id, owning_plugin)
        local settings_page = require("modules/settings/zen_settings_page")
        local standalone_route, settings_resume = settings_page.rememberStandaloneArrangeRoute({
            { text = _("Home"), occurrence = 1 },
        }, _("Widgets"), { id })
        local items = build_widget_settings_items(id)
        if type(items) ~= "table" or #items == 0 then
            arrange_widgets()
            return true
        end
        require("common/ui/zen_arrange_list").show{
            title = component_label(id),
            item_table = items,
            plugin = owning_plugin or ctx.plugin,
            allow_arrange = false,
            hide_footer_cancel = true,
            settings_resume = settings_resume,
            back_callback = standalone_route and function()
                settings_page.rememberStandaloneArrangeRoute({
                    { text = _("Home"), occurrence = 1 },
                }, _("Widgets"), {})
                UIManager:nextTick(function()
                    local plugin = ctx.plugin or rawget(_G, "__ZEN_UI_PLUGIN")
                    if plugin then settings_page.show(plugin) end
                end)
                return true
            end or nil,
        }
        return true
    end

    local home_items = {
            {
                text = _("Widgets") .. " \u{25B8}",
                keep_menu_open = true,
                callback = arrange_widgets,
            },
            {
                text = _("Edit mode"),
                checked_func = function()
                    return dcfg.edit_mode == true
                end,
                callback = function()
                    dcfg.edit_mode = dcfg.edit_mode ~= true
                    save_home("reinit")
                end,
            },
            {
                text = _("Presets"),
                sub_item_table_func = build_preset_items,
            },
            {
                text = _("Show top status bar"),
                checked_func = function()
                    return dcfg.show_status_bar ~= false
                end,
                callback = function()
                    dcfg.show_status_bar = dcfg.show_status_bar == false
                    if dcfg.show_status_bar then
                        dcfg.modules.featured.show_status_bar = false
                    end
                    save_home("reinit")
                end,
            },
            --[[
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text = _("Show top status bar"),
                        checked_func = function()
                            return dcfg.show_status_bar ~= false
                        end,
                        callback = function()
                            dcfg.show_status_bar = dcfg.show_status_bar == false
                            save_home("reinit")
                        end,
                    },
                    {
                        text = _("Featured widgets"),
                        sub_item_table = {
                            {
                                text = _("Featured book"),
                                sub_item_table_func = build_featured_widget_items,
                            },
                        },
                    },
                    {
                        text = _("Strip widgets"),
                        sub_item_table = {
                            {
                                text = _("Custom strip widget"),
                                sub_item_table_func = function() return build_strip_widget_items("strip_custom") end,
                            },
                            {
                                text = _("Tag strip widget"),
                                sub_item_table_func = function() return build_strip_widget_items("strip_tag") end,
                            },
                            {
                                text = _("To Be Read strip widget"),
                                sub_item_table_func = function() return build_strip_widget_items("strip_tbr") end,
                            },
                            {
                                text = _("Recently read strip widget"),
                                sub_item_table_func = function() return build_strip_widget_items("strip_recent") end,
                            },
                        },
                    },
                    {
                        text = _("Reading goals"),
                        sub_item_table_func = build_goals_items,
                    },
                    {
                        text = _("Reading stats"),
                        sub_item_table_func = build_stats_triplet_items,
                    },
                    {
                        text = _("Quotes"),
                        sub_item_table_func = build_quotes_items,
                    },
                },
            },
            ]]
    }
    IconItem.decorate(home_items[1], icons.widgets)
    IconItem.decorate(home_items[2], icons.edit)
    IconItem.decorate(home_items[3], icons.save)
    IconItem.decorate(home_items[4], icons.settings_status)
    IconItem.decorate(home_items[5], icons.settings_status)

    return {
        text = _("Home"),
        sub_item_table = home_items,
        _zen_search_items_func = arrange_search_items,
    }
end

return M
