local LuaSettings = require("luasettings")
local PresetStore = require("config/preset_store")
local PagePlan = require("modules/menu/app_launcher/page_plan")
local BookSwitcherPage = require("modules/menu/app_launcher/book_switcher_page")

local M = {}

local BOOK_DETAILS_ORDER = {
    "read_time",
    "time_remaining",
    "pages_today",
    "time_today",
    "pages",
    "progress",
}
local BOOK_DETAILS_DEFAULT_ENABLED = {
    read_time = true,
    time_remaining = true,
    pages_today = false,
    time_today = false,
    pages = true,
    progress = true,
}

local BOOK_DETAILS_VALID = {}
for _i, id in ipairs(BOOK_DETAILS_ORDER) do
    BOOK_DETAILS_VALID[id] = true
end

local _settings_file
local _current_config

local function normalize_book_details(cfg)
    cfg = type(cfg) == "table" and cfg or {}
    local order = {}
    local seen = {}
    for _i, id in ipairs(type(cfg.book_details_order) == "table"
            and cfg.book_details_order or {}) do
        if BOOK_DETAILS_VALID[id] and not seen[id] then
            order[#order + 1] = id
            seen[id] = true
        end
    end
    for _i, id in ipairs(BOOK_DETAILS_ORDER) do
        if not seen[id] then order[#order + 1] = id end
    end
    cfg.book_details_order = order

    local saved = type(cfg.book_details_enabled) == "table"
        and cfg.book_details_enabled or {}
    local enabled = {}
    for _i, id in ipairs(BOOK_DETAILS_ORDER) do
        if type(saved[id]) == "boolean" then
            enabled[id] = saved[id]
        else
            enabled[id] = BOOK_DETAILS_DEFAULT_ENABLED[id]
        end
    end
    cfg.book_details_enabled = enabled
    return cfg
end

local function default_config()
    return normalize_book_details({
        entries = {},
        next_id = 0,
        show_labels = true,
        open_first = false,
        hide_reader_actions_in_library = false,
        page_order = PagePlan.normalizeOrder(),
        show_book_switcher = false,
        book_switcher_reader_only = false,
        book_switcher_count = BookSwitcherPage.BOOK_COUNT,
        book_switcher_hide_finished = true,
        book_switcher_hidden = {},
        show_book_details = false,
    })
end

local function settings_path()
    return PresetStore.rootDir() .. "/app_launcher.lua"
end

local function open_file()
    if not _settings_file then
        _settings_file = LuaSettings:open(settings_path())
    end
    return _settings_file
end

local function normalize(cfg)
    if type(cfg) ~= "table" then cfg = {} end
    if type(cfg.entries) ~= "table" then cfg.entries = {} end
    if type(cfg.next_id) ~= "number" then cfg.next_id = 0 end
    if type(cfg.show_labels) ~= "boolean" then cfg.show_labels = true end
    if type(cfg.open_first) ~= "boolean" then cfg.open_first = false end
    cfg.center_icons = nil
    if type(cfg.hide_reader_actions_in_library) ~= "boolean" then
        cfg.hide_reader_actions_in_library = false
    end
    if type(cfg.page_order) ~= "table" then
        local legacy_order = { "buttons", "book_switcher", "book_details" }
        if cfg.book_details_first == true
                and not (cfg.book_switcher_first == true and cfg.show_book_details ~= true) then
            legacy_order = { "book_details", "buttons", "book_switcher" }
        elseif cfg.book_switcher_first == true then
            legacy_order = { "book_switcher", "buttons", "book_details" }
        end
        cfg.page_order = PagePlan.normalizeOrder(nil, legacy_order)
    else
        cfg.page_order = PagePlan.normalizeOrder(cfg.page_order)
    end
    cfg.book_switcher_first = nil
    cfg.book_details_first = nil
    if type(cfg.show_book_switcher) ~= "boolean" then cfg.show_book_switcher = false end
    if type(cfg.book_switcher_reader_only) ~= "boolean" then
        cfg.book_switcher_reader_only = false
    end
    cfg.book_switcher_count = BookSwitcherPage.normalizeCount(cfg.book_switcher_count)
    if type(cfg.book_switcher_hide_finished) ~= "boolean" then
        cfg.book_switcher_hide_finished = true
    end
    if type(cfg.book_switcher_hidden) ~= "table" then cfg.book_switcher_hidden = {} end
    if type(cfg.show_book_details) ~= "boolean" then cfg.show_book_details = false end
    return normalize_book_details(cfg)
end

function M.path()
    return settings_path()
end

function M.load()
    if _current_config then return _current_config end
    local f = open_file()
    if type(f.data) == "table" and next(f.data) ~= nil then
        _current_config = normalize(f.data)
    else
        _current_config = default_config()
    end
    return _current_config
end

function M.save(cfg)
    cfg = normalize(cfg)
    local f = open_file()
    f.data = cfg
    f:flush()
    _current_config = cfg
    return cfg
end

return M
