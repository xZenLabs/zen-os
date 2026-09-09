local ButtonModel = require("common/nav_button_model")

local M = {}

M.DEFAULT_PRESET_NAME = "Zen Default"
M.BOOKSHELF_PRESET_NAME = "Bookshelf"
M.CUSTOM_PRESET_NAME = "Custom preset"

local function featured_text_styles()
    return {
        title = { font_face = "default", font_size = 11, bold = true },
        author = { font_face = "default", font_size = 9, bold = false },
        series = { font_face = "default", font_size = 7, bold = false },
        description = { font_face = "default", font_size = 16, bold = false },
        progress = { font_face = "default", font_size = 7, bold = false },
    }
end

local function featured_defaults()
    return {
        default_source = { kind = "recent" },
        interactive = true,
        path = nil,
        progress_meta = {
            left = "percent",
            right = "total_pages",
        },
        show_author = true,
        show_series = true,
        show_progress = true,
        show_description = true,
        wrap_description_text = false,
        justify_description_text = false,
        format_description_html = false,
        show_status_bar = true,
        status_bar_bold_text = true,
        status_bar_show_bottom_border = true,
        text_styles = featured_text_styles(),
    }
end

local function datetime_text_styles()
    return {
        time = { font_face = "default", font_size = 36 },
        date = { font_face = "default", font_size = 12 },
    }
end

local function strip_defaults(opts)
    opts = type(opts) == "table" and opts or {}
    return {
        center_books = false,
        count = opts.count or 4,
        controls = {
            enabled = opts.controls == true,
            labels = {},
            next_custom_id = 0,
            order = { "page_left", "recent", "search", "tags", "page_right" },
            show_buttons = {
                page_left = true,
                recent = true,
                search = true,
                tags = true,
                page_right = true,
            },
            text_style = {
                font_face = "default",
                font_size = 10,
                bold = false,
            },
            custom_buttons = {},
        },
        default_source = { kind = "recent" },
        interactive = true,
        order = "default",
        show_badges = false,
        show_strip_titles = false,
        sources = {
            custom = { paths = {} },
            recent = {
                filter_finished = false,
                filter_tbr = false,
                filter_unread = false,
            },
            tag = { tag = nil },
        },
        strip_schema_version = 3,
        two_rows = opts.two_rows == true,
    }
end

local DEFAULT_HOME_PAGE = {
    title = M.DEFAULT_PRESET_NAME,
    rows = {
        capacity_units = 10,
        layout_schema_version = 2,
        order = {
            "datetime",
            "featured",
            "stats_triplet",
            "reading_goals",
            "strip",
            "quotes",
        },
        enabled = {
            datetime = false,
            featured = true,
            quotes = true,
            reading_goals = false,
            stats_triplet = true,
            strip = true,
        },
    },
    middle_stats_triplet = {
        "today_pages",
        "today_duration",
        "streak",
    },
    goals = {
        daily_pages_target = 30,
        daily_target = 30,
        daily_time_target_min = 30,
        metric = "pages",
        metrics = { daily = "pages", weekly = "pages", monthly = "pages", yearly = "pages" },
        period = "daily",
        periods = { "daily" },
        weekly_pages_target = 210,
        weekly_target = 210,
        weekly_time_target_min = 210,
        monthly_pages_target = 900,
        monthly_time_target_min = 900,
        monthly_books_target = 1,
        yearly_pages_target = 1000,
        yearly_time_target_min = 1000,
        yearly_books_target = 12,
    },
    show_status_bar = false,
    modules = {
        datetime = {
            automatic_font_size = true,
            max_font_size = 36,
            text_styles = datetime_text_styles(),
        },
        featured = featured_defaults(),
        quotes = {},
        reading_goals = {},
        stats_triplet = {
            automatic_font_size = true,
            font_size = 16,
            max_font_size = 18,
            stat_style = "divider",
        },
        strip = strip_defaults{ controls = true },
    },
    quotes = {
        automatic_font_size = true,
        font_size = 12,
        max_font_size = 14,
        rotation = "daily",
        show_author = true,
        show_title = true,
        sources = { default = true },
    },
}

local BOOKSHELF_HOME_PAGE = {
    title = M.BOOKSHELF_PRESET_NAME,
    rows = {
        capacity_units = 10,
        layout_schema_version = 2,
        order = {
            "datetime",
            "featured",
            "stats_triplet",
            "reading_goals",
            "strip",
            "quotes",
        },
        enabled = {
            datetime = false,
            featured = true,
            quotes = false,
            reading_goals = false,
            stats_triplet = false,
            strip = true,
        },
    },
    middle_stats_triplet = {
        "today_pages",
        "today_duration",
        "streak",
    },
    goals = {
        daily_pages_target = 30,
        daily_target = 30,
        daily_time_target_min = 30,
        metric = "pages",
        metrics = { daily = "pages", weekly = "pages", monthly = "pages", yearly = "pages" },
        period = "daily",
        periods = { "daily" },
        weekly_pages_target = 210,
        weekly_target = 210,
        weekly_time_target_min = 210,
        monthly_pages_target = 900,
        monthly_time_target_min = 900,
        monthly_books_target = 1,
        yearly_pages_target = 1000,
        yearly_time_target_min = 1000,
        yearly_books_target = 12,
    },
    show_status_bar = false,
    modules = {
        datetime = {
            automatic_font_size = true,
            max_font_size = 36,
            text_styles = datetime_text_styles(),
        },
        featured = featured_defaults(),
        quotes = {},
        reading_goals = {},
        stats_triplet = {
            automatic_font_size = true,
            max_font_size = 18,
            stat_style = "divider",
        },
        strip = strip_defaults{ count = 8, controls = true, two_rows = true },
    },
    quotes = {
        automatic_font_size = true,
        font_size = 12,
        max_font_size = 14,
        rotation = "daily",
        show_author = true,
        show_title = true,
        sources = { default = true },
    },
}

local HOME_KEYS = {
    "title",
    "rows",
    "middle_stats_triplet",
    "goals",
    "show_status_bar",
    "modules",
    "quotes",
}

local function deepcopy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for key, val in pairs(value) do
        out[deepcopy(key, seen)] = deepcopy(val, seen)
    end
    return out
end

local function same_source(a, b)
    if type(a) ~= "table" or type(b) ~= "table"
            or a.kind ~= b.kind or a.value ~= b.value then
        return false
    end
    local a_paths = a.paths
    local b_paths = b.paths
    if a_paths == nil and b_paths == nil then return true end
    if type(a_paths) ~= "table" or type(b_paths) ~= "table"
            or #a_paths ~= #b_paths then
        return false
    end
    for i, path in ipairs(a_paths) do
        if path ~= b_paths[i] then return false end
    end
    return true
end

function M.copy(value)
    return deepcopy(value)
end

function M.defaultHomePage()
    local page = deepcopy(DEFAULT_HOME_PAGE)
    page.active_preset = M.DEFAULT_PRESET_NAME
    return page
end
function M.getBuiltinPresets()
    return {
        {
            name = M.DEFAULT_PRESET_NAME,
            builtin = true,
            home_page = deepcopy(DEFAULT_HOME_PAGE),
        },
        {
            name = M.BOOKSHELF_PRESET_NAME,
            builtin = true,
            home_page = deepcopy(BOOKSHELF_HOME_PAGE),
        },
    }
end

function M.isBuiltinPresetName(name)
    if type(name) ~= "string" then return false end
    for _i, preset in ipairs(M.getBuiltinPresets()) do
        if preset.name == name then return true end
    end
    return false
end

function M.ensurePresetState(dcfg)
    if type(dcfg.active_preset) ~= "string" or dcfg.active_preset == "" then
        dcfg.active_preset = nil
    end
end

function M.captureHomePage(dcfg)
    local out = {}
    for _i, key in ipairs(HOME_KEYS) do
        out[key] = deepcopy(dcfg[key])
    end
    return out
end

local LEGACY_FEATURED_MODULE_IDS = {
    "featured_recent", "featured_custom", "featured_tbr",
}

local function legacy_featured_source(id)
    if id == "featured_custom" then return { kind = "custom" } end
    if id == "featured_tbr" then return { kind = "to_be_read" } end
    return { kind = "recent" }
end

function M.featuredSourceKey(source)
    local kind = type(source) == "table" and source.kind or source
    if kind == "custom" then return "custom_featured" end
    if kind == "to_be_read" then return "to_be_read" end
    return "recently_read"
end

local function ensure_featured_shape(featured)
    local defaults = featured_defaults()
    local changed = false
    for key, value in pairs(defaults) do
        if featured[key] == nil then
            featured[key] = deepcopy(value)
            changed = true
        end
    end
    local source = featured.default_source
    local valid_sources = { recent = true, custom = true, to_be_read = true }
    if type(source) ~= "table" or not valid_sources[source.kind] then
        featured.default_source = { kind = "recent" }
        changed = true
    end
    if type(featured.path) ~= "string" or featured.path == "" then
        if featured.path ~= nil then changed = true end
        featured.path = nil
    end
    if featured.order ~= nil then
        featured.order = nil
        changed = true
    end
    if featured.cover_layout ~= nil then
        featured.cover_layout = nil
        changed = true
    end
    return changed
end

function M.normalizeFeaturedConfig(dcfg)
    if type(dcfg) ~= "table" then return false end
    if type(dcfg.rows) ~= "table" then dcfg.rows = {} end
    if type(dcfg.rows.order) ~= "table" then dcfg.rows.order = {} end
    if type(dcfg.rows.enabled) ~= "table" then dcfg.rows.enabled = {} end
    if type(dcfg.modules) ~= "table" then dcfg.modules = {} end

    local modules = dcfg.modules
    local legacy_present = false
    local enabled_legacy = {}
    for _i, id in ipairs(LEGACY_FEATURED_MODULE_IDS) do
        if type(modules[id]) == "table" then legacy_present = true end
        if dcfg.rows.enabled[id] == true then enabled_legacy[id] = true end
    end

    local changed = false
    if legacy_present then
        local ordered_enabled = {}
        for _i, id in ipairs(dcfg.rows.order) do
            if enabled_legacy[id] then ordered_enabled[#ordered_enabled + 1] = id end
        end
        for _i, id in ipairs(LEGACY_FEATURED_MODULE_IDS) do
            local found = false
            for _j, ordered in ipairs(ordered_enabled) do
                if ordered == id then found = true; break end
            end
            if enabled_legacy[id] and not found then
                ordered_enabled[#ordered_enabled + 1] = id
            end
        end

        if type(modules.featured) ~= "table" then
            local recent_cfg = type(modules.featured_recent) == "table"
                and modules.featured_recent or nil
            local primary_cfg = type(modules[ordered_enabled[1]]) == "table"
                and modules[ordered_enabled[1]] or nil
            local featured = deepcopy(recent_cfg or primary_cfg or featured_defaults())
            featured.default_source = legacy_featured_source(ordered_enabled[1])
            local custom_cfg = type(modules.featured_custom) == "table"
                and modules.featured_custom or {}
            featured.path = type(custom_cfg.path) == "string" and custom_cfg.path or nil
            modules.featured = featured
        end

        local order = {}
        local inserted = false
        for _i, id in ipairs(dcfg.rows.order) do
            local is_legacy = false
            for _j, legacy_id in ipairs(LEGACY_FEATURED_MODULE_IDS) do
                if id == legacy_id then is_legacy = true; break end
            end
            if is_legacy or id == "featured" then
                if not inserted then order[#order + 1] = "featured"; inserted = true end
            else
                order[#order + 1] = id
            end
        end
        if not inserted then order[#order + 1] = "featured" end
        dcfg.rows.order = order
        if dcfg.rows.enabled.featured == nil then
            dcfg.rows.enabled.featured = #ordered_enabled > 0
        end
        for _i, id in ipairs(LEGACY_FEATURED_MODULE_IDS) do
            dcfg.rows.enabled[id] = nil
            modules[id] = nil
        end
        changed = true
    elseif type(modules.featured) ~= "table" then
        modules.featured = featured_defaults()
        changed = true
    end

    if ensure_featured_shape(modules.featured) then changed = true end
    return changed
end

local LEGACY_STRIP_MODULE_IDS = { "strip_recent", "strip_custom", "strip_tag", "strip_tbr" }
local STRIP_COMMON_KEYS = {
    "center_books", "count", "interactive", "order", "show_badges",
    "show_strip_titles", "two_rows",
}

local VALID_CONTROL_IDS = {
    recent = true, favorites = true, to_be_read = true, authors = true,
    series = true, languages = true, tags = true, collections = true,
    books = true, manga = true,
    news = true, continue = true, history = true, home = true,
    search = true, calibre_search = true, stats = true, exit = true, page_left = true,
    page_right = true, menu = true,
}

local function ensure_strip_shape(strip)
    local defaults = strip_defaults()
    local changed = false
    for key, value in pairs(defaults) do
        if strip[key] == nil then
            strip[key] = deepcopy(value)
            changed = true
        end
    end
    if type(strip.default_source) ~= "table"
            or type(strip.default_source.kind) ~= "string" then
        strip.default_source = { kind = "recent" }
        changed = true
    end
    if type(strip.sources) ~= "table" then strip.sources = {}; changed = true end
    for key, value in pairs(defaults.sources) do
        if type(strip.sources[key]) ~= "table" then
            strip.sources[key] = deepcopy(value)
            changed = true
        end
    end
    if type(strip.controls) ~= "table" then
        strip.controls = deepcopy(defaults.controls)
        changed = true
    end
    local controls = strip.controls
    for key, value in pairs(defaults.controls) do
        if controls[key] == nil then
            controls[key] = deepcopy(value)
            changed = true
        end
    end
    if type(controls.labels) ~= "table" then
        controls.labels = deepcopy(defaults.controls.labels)
        changed = true
    end
    if controls.labels.tags == "Genres" then
        controls.labels.tags = nil
        changed = true
    end
    if type(controls.order) ~= "table" then
        controls.order = deepcopy(defaults.controls.order)
        changed = true
    end
    if type(controls.show_buttons) ~= "table" then
        controls.show_buttons = deepcopy(defaults.controls.show_buttons)
        changed = true
    end
    if type(controls.custom_buttons) ~= "table" then
        controls.custom_buttons = {}
        changed = true
    end
    local strip_schema_version = math.max(1, math.floor(
        tonumber(strip.strip_schema_version) or 1))
    if strip_schema_version < 2 then
        local has_search = false
        for _i, id in ipairs(controls.order) do
            if id == "search" then has_search = true; break end
        end
        if not has_search then controls.order[#controls.order + 1] = "search" end
        controls.show_buttons.search = true
        changed = true
    end
    if strip_schema_version < 3
            and #controls.order == 4
            and controls.order[1] == "recent"
            and controls.order[2] == "to_be_read"
            and controls.order[3] == "tags"
            and controls.order[4] == "search"
            and controls.show_buttons.recent == true
            and controls.show_buttons.to_be_read == true
            and controls.show_buttons.tags == true
            and controls.show_buttons.search == true then
        controls.order = deepcopy(defaults.controls.order)
        controls.show_buttons.recent = true
        controls.show_buttons.to_be_read = nil
        controls.show_buttons.page_left = true
        controls.show_buttons.page_right = true
        changed = true
    end
    controls.next_custom_id = math.max(0, math.floor(
        tonumber(controls.next_custom_id) or 0))
    controls.enabled = controls.enabled == true
    local valid_sources = {
        recent = true, favorites = true, to_be_read = true, authors = true,
        series = true, languages = true, tags = true, collections = true, tag = true,
        folder = true, custom = true,
    }
    if not valid_sources[strip.default_source.kind] then
        strip.default_source = { kind = "recent" }
        changed = true
    end
    local custom_ids = {}
    for _i, entry in ipairs(controls.custom_buttons) do
        if type(entry) == "table" and type(entry.id) == "string"
                and entry.id ~= "" and entry.id ~= "search" then
            custom_ids[entry.id] = true
        end
    end
    local order, seen, visible_ids = {}, {}, {}
    for _i, id in ipairs(controls.order) do
        if type(id) == "string" and (VALID_CONTROL_IDS[id] or custom_ids[id])
                and not seen[id] then
            seen[id] = true
            order[#order + 1] = id
            if controls.show_buttons[id] == true then
                visible_ids[#visible_ids + 1] = id
            end
        else
            changed = true
        end
    end
    while #visible_ids > 7 do
        local disable_index = #visible_ids
        while disable_index > 1 and visible_ids[disable_index] == "search" do
            disable_index = disable_index - 1
        end
        controls.show_buttons[visible_ids[disable_index]] = false
        table.remove(visible_ids, disable_index)
        changed = true
    end
    if #order == 0 then
        order = deepcopy(defaults.controls.order)
        controls.show_buttons = deepcopy(defaults.controls.show_buttons)
        changed = true
    elseif #visible_ids == 0 then
        controls.show_buttons[order[1]] = true
        changed = true
    end
    controls.order = order
    if controls.enabled then
        local first_source = ButtonModel.firstVisibleSource(controls)
        if first_source and not same_source(strip.default_source, first_source) then
            strip.default_source = deepcopy(first_source)
            changed = true
        end
    end
    if strip.strip_schema_version ~= 3 then
        strip.strip_schema_version = 3
        changed = true
    end
    return changed
end

local function legacy_source(id, cfg)
    if id == "strip_custom" then return { kind = "custom" } end
    if id == "strip_tag" then
        return { kind = "tag", value = type(cfg.tag) == "string" and cfg.tag or nil }
    end
    if id == "strip_tbr" then return { kind = "to_be_read" } end
    return { kind = "recent" }
end

local function add_migrated_control(controls, source, custom_paths)
    local id = source.kind
    if id == "tag" then
        controls.next_custom_id = (tonumber(controls.next_custom_id) or 0) + 1
        id = "hs_" .. controls.next_custom_id
        controls.custom_buttons[#controls.custom_buttons + 1] = {
            id = id,
            label = source.value or "Tag",
            tag = source.value,
            type = "tag",
        }
    elseif id == "custom" then
        controls.next_custom_id = (tonumber(controls.next_custom_id) or 0) + 1
        id = "hs_" .. controls.next_custom_id
        controls.custom_buttons[#controls.custom_buttons + 1] = {
            id = id,
            label = "Custom",
            paths = deepcopy(custom_paths or {}),
            type = "custom_source",
        }
    end
    for _i, existing in ipairs(controls.order) do
        if existing == id then
            controls.show_buttons[id] = true
            return
        end
    end
    controls.order[#controls.order + 1] = id
    controls.show_buttons[id] = true
end

function M.normalizeStripConfig(dcfg)
    if type(dcfg) ~= "table" then return false end
    if type(dcfg.rows) ~= "table" then dcfg.rows = {}; end
    if type(dcfg.rows.order) ~= "table" then dcfg.rows.order = {}; end
    if type(dcfg.rows.enabled) ~= "table" then dcfg.rows.enabled = {}; end
    if type(dcfg.modules) ~= "table" then dcfg.modules = {}; end

    local modules = dcfg.modules
    local legacy_present = false
    local enabled_legacy = {}
    for _i, id in ipairs(LEGACY_STRIP_MODULE_IDS) do
        if type(modules[id]) == "table" then legacy_present = true end
        if dcfg.rows.enabled[id] == true then enabled_legacy[id] = true end
    end

    local changed = false
    if legacy_present then
        local ordered_enabled = {}
        for _i, id in ipairs(dcfg.rows.order) do
            if enabled_legacy[id] then ordered_enabled[#ordered_enabled + 1] = id end
        end
        for _i, id in ipairs(LEGACY_STRIP_MODULE_IDS) do
            local found = false
            for _j, ordered in ipairs(ordered_enabled) do
                if ordered == id then found = true; break end
            end
            if enabled_legacy[id] and not found then ordered_enabled[#ordered_enabled + 1] = id end
        end

        local primary_id = ordered_enabled[1]
        if not primary_id then
            for _i, id in ipairs(LEGACY_STRIP_MODULE_IDS) do
                if type(modules[id]) == "table" then primary_id = id; break end
            end
        end
        primary_id = primary_id or "strip_recent"
        local primary_cfg = type(modules[primary_id]) == "table" and modules[primary_id] or {}
        local strip = strip_defaults()
        for _i, key in ipairs(STRIP_COMMON_KEYS) do
            if primary_cfg[key] ~= nil then strip[key] = deepcopy(primary_cfg[key]) end
        end
        strip.default_source = legacy_source(primary_id, primary_cfg)

        local recent = modules.strip_recent or {}
        strip.sources.recent.filter_finished = recent.filter_finished == true
        strip.sources.recent.filter_tbr = recent.filter_tbr == true
        strip.sources.recent.filter_unread = recent.filter_unread == true
        strip.sources.custom.paths = deepcopy(type(modules.strip_custom) == "table"
            and modules.strip_custom.paths or {})
        strip.sources.tag.tag = type(modules.strip_tag) == "table"
            and modules.strip_tag.tag or nil

        if #ordered_enabled > 1 then
            strip.controls.enabled = true
            strip.controls.order = {}
            strip.controls.show_buttons = {}
            for _i, id in ipairs(ordered_enabled) do
                local cfg = modules[id] or {}
                add_migrated_control(strip.controls, legacy_source(id, cfg), cfg.paths)
            end
            strip.controls.order[#strip.controls.order + 1] = "search"
            strip.controls.show_buttons.search = true
        end
        modules.strip = strip

        local new_order = {}
        local inserted = false
        for _i, id in ipairs(dcfg.rows.order) do
            local is_legacy = false
            for _j, legacy_id in ipairs(LEGACY_STRIP_MODULE_IDS) do
                if id == legacy_id then is_legacy = true; break end
            end
            if is_legacy then
                if not inserted then new_order[#new_order + 1] = "strip"; inserted = true end
            else
                new_order[#new_order + 1] = id
            end
        end
        if not inserted then new_order[#new_order + 1] = "strip" end
        dcfg.rows.order = new_order
        dcfg.rows.enabled.strip = #ordered_enabled > 0
        for _i, id in ipairs(LEGACY_STRIP_MODULE_IDS) do
            dcfg.rows.enabled[id] = nil
            modules[id] = nil
        end
        changed = true
    elseif type(modules.strip) ~= "table" then
        modules.strip = strip_defaults()
        changed = true
    end

    if ensure_strip_shape(modules.strip) then changed = true end
    return changed
end

function M.normalizeLayoutGrid(dcfg)
    if type(dcfg) ~= "table" then return false end
    if type(dcfg.rows) ~= "table" then dcfg.rows = {} end
    local rows = dcfg.rows
    local changed = rows.layout_notice_pending ~= nil
    rows.layout_notice_pending = nil
    if tonumber(rows.layout_schema_version) and rows.layout_schema_version >= 2 then
        return changed
    end

    local max_rows = tonumber(rows.max_rows)
    if max_rows and type(rows.order) == "table" and type(rows.enabled) == "table" then
        local visible = 0
        for _i, id in ipairs(rows.order) do
            if rows.enabled[id] == true then
                visible = visible + 1
                if visible > max_rows then rows.enabled[id] = false end
            end
        end
    end

    rows.max_rows = nil
    rows.capacity_units = 10
    rows.layout_schema_version = 2
    return true
end

-- Mirror the library "Show title below cover (mosaic)" setting onto the strip
-- widgets' show_strip_titles. Only used for the one-time first-startup seed;
-- afterwards strip titles are user-owned and the mosaic setting no longer drives
-- them.
function M.applyMosaicTitlesToStrips(dcfg, show_titles)
    if type(dcfg) ~= "table" or type(dcfg.modules) ~= "table" then return end
    M.normalizeStripConfig(dcfg)
    if type(dcfg.modules.strip) == "table" then
        dcfg.modules.strip.show_strip_titles = show_titles == true
    end
end

function M.applyHomePagePreset(dcfg, preset)
    if type(dcfg) ~= "table" or type(preset) ~= "table" then return end
    local source = type(preset.home_page) == "table" and preset.home_page or preset
    if source.title == nil and type(preset.name) == "string" then
        dcfg.title = preset.name
    end
    for _i, key in ipairs(HOME_KEYS) do
        if source[key] ~= nil then
            dcfg[key] = deepcopy(source[key])
        end
    end
    M.normalizeFeaturedConfig(dcfg)
    M.normalizeStripConfig(dcfg)
    M.normalizeLayoutGrid(dcfg)
end

return M
