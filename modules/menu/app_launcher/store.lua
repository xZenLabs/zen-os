local LuaSettings = require("luasettings")
local PresetStore = require("config/preset_store")
local PagePlan = require("modules/menu/app_launcher/page_plan")

local M = {}

local _settings_file
local _current_config

local function default_config()
    return {
        entries = {},
        next_id = 0,
        show_labels = true,
        columns = 0, -- 0 = auto
        open_first = false,
        page_order = PagePlan.normalizeOrder(),
        show_book_switcher = false,
        book_switcher_reader_only = false,
        book_switcher_count = PagePlan.BOOK_COUNT,
        book_switcher_hide_finished = true,
        book_switcher_hidden = {},
    }
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
    if type(cfg.columns) ~= "number" or cfg.columns < 2 or cfg.columns > 8 then
        cfg.columns = 0
    else
        cfg.columns = math.floor(cfg.columns)
    end
    if type(cfg.open_first) ~= "boolean" then cfg.open_first = false end
    cfg.center_icons = nil
    cfg.hide_reader_actions_in_library = nil
    if type(cfg.page_order) ~= "table" then
        cfg.page_order = PagePlan.normalizeOrder(nil, cfg.book_switcher_first == true
            and { "book_switcher", "buttons" } or { "buttons", "book_switcher" })
    else
        cfg.page_order = PagePlan.normalizeOrder(cfg.page_order)
    end
    cfg.book_switcher_first = nil
    cfg.book_details_first = nil
    cfg.show_book_details = nil
    if type(cfg.show_book_switcher) ~= "boolean" then cfg.show_book_switcher = false end
    if type(cfg.book_switcher_reader_only) ~= "boolean" then
        cfg.book_switcher_reader_only = false
    end
    cfg.book_switcher_count = PagePlan.normalizeCount(cfg.book_switcher_count)
    if type(cfg.book_switcher_hide_finished) ~= "boolean" then
        cfg.book_switcher_hide_finished = true
    end
    if type(cfg.book_switcher_hidden) ~= "table" then cfg.book_switcher_hidden = {} end
    return cfg
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
