local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local BrandMigration = require("common/brand_migration")

local settings_parent = DataStorage:getSettingsDir()
local settings_migration = BrandMigration.preparedSettings(settings_parent)
    or BrandMigration.prepareSettings(settings_parent, { lfs = lfs })
local ROOT_DIR = settings_migration.root

-- Resolve and, when needed, rename the complete settings tree before opening
-- any individual LuaSettings file.
local LuaSettings = require("luasettings")
local util = require("util")

local M = {}
local _store_cache = {} -- kind -> { mtime, size, data }; avoids re-parsing on hot reads

local VALID_KINDS = {
    home = true,
    stats = true,
    reader = true,
    screensaver = true,
}

local function ensure_dir(path)
    if lfs.attributes(path, "mode") == "directory" then return true end
    return lfs.mkdir(path) == true or lfs.attributes(path, "mode") == "directory"
end

local root_ready = false
local function ensure_root_dir()
    root_ready = root_ready or ensure_dir(ROOT_DIR)
    return ROOT_DIR
end

local function normalize_kind(kind)
    if VALID_KINDS[kind] then return kind end
end

local function kind_path(kind)
    kind = normalize_kind(kind)
    if not kind then return nil end
    return ensure_root_dir() .. "/" .. kind .. ".lua"
end

local function file_exists(path)
    return lfs.attributes(path, "mode") == "file"
end

local function empty_store()
    return {
        settings = {},
        presets = {},
        active_preset = nil,
        version = 1,
    }
end

local function is_valid_store(data)
    return type(data) == "table" and type(data.settings) == "table"
        and type(data.presets) == "table" and type(data.version) == "number"
end

local function normalize_store(data)
    if type(data) ~= "table" then data = {} end
    if type(data.settings) ~= "table" then data.settings = {} end
    if type(data.presets) ~= "table" then data.presets = {} end
    if type(data.active_preset) ~= "string" or data.active_preset == "" then
        data.active_preset = nil
    end
    if type(data.version) ~= "number" then data.version = 1 end
    return data
end

local function open_store(kind)
    local path = kind_path(kind)
    if not path then return nil end
    return LuaSettings:open(path)
end

-- Shared parsed store; callers must not mutate it.
local function read_store(kind)
    local path = kind_path(kind)
    if not path then return nil end
    local attr = lfs.attributes(path)
    local cached = _store_cache[kind]
    if cached and attr and cached.mtime == attr.modification and cached.size == attr.size then
        return cached.data, cached.valid
    end
    local raw = LuaSettings:open(path).data
    local valid = is_valid_store(raw)
    local data = normalize_store(raw)
    _store_cache[kind] = attr and {
        mtime = attr.modification, size = attr.size, data = data, valid = valid,
    } or nil
    return data, valid
end

function M.rootDir()
    return ensure_root_dir()
end

function M.kindPath(kind)
    return kind_path(kind)
end

function M.loadStore(kind)
    local data = read_store(kind)
    if not data then return empty_store() end
    return util.tableDeepCopy(data)
end

function M.saveStore(kind, data)
    local settings = open_store(kind)
    if not settings then return false end
    settings.data = normalize_store(data)
    settings:flush()
    _store_cache[kind] = nil
    return true
end

-- Private copy of the settings only; presets stay in the shared parse.
function M.getSettings(kind)
    local data = read_store(kind)
    return data and util.tableDeepCopy(data.settings) or {}
end

-- initial_settings may be a table or a function building it on demand.
function M.ensureStore(kind, initial_settings)
    local path = kind_path(kind)
    if not path then return false end

    local exists = file_exists(path)
    -- Steady state: validate via the shared parse (seeds the read cache).
    if exists and select(2, read_store(kind)) then return false end

    local settings = LuaSettings:open(path)
    local store = normalize_store(settings.data)
    if not exists then
        if type(initial_settings) == "function" then initial_settings = initial_settings() end
        if type(initial_settings) == "table" then store.settings = initial_settings end
    end
    settings.data = store
    settings:flush()
    _store_cache[kind] = nil
    return true
end

function M.migrateStores(initial_settings)
    local changed = false
    for _i, kind in ipairs({ "home", "stats", "reader", "screensaver" }) do
        local init = type(initial_settings) == "table" and initial_settings[kind] or nil
        if M.ensureStore(kind, init) then
            changed = true
        end
    end
    return changed
end

function M.saveSettings(kind, settings_data)
    local store = M.loadStore(kind)
    local previous = store.settings
    store.settings = type(settings_data) == "table" and settings_data or {}
    if kind == "reader" and store.settings.page_browser_layout == nil then
        local layout = type(previous) == "table" and previous.page_browser_layout
        if layout == "single" or layout == "carousel" or layout == "grid" then
            store.settings.page_browser_layout = layout
        end
    end
    return M.saveStore(kind, store)
end

function M.getActivePreset(kind)
    local data = read_store(kind)
    return data and data.active_preset
end

function M.setActivePreset(kind, name)
    local store = M.loadStore(kind)
    store.active_preset = type(name) == "string" and name ~= "" and name or nil
    return M.saveStore(kind, store)
end

function M.list(kind)
    local store = M.loadStore(kind)
    local out = {}
    for name, preset in pairs(store.presets) do
        if type(preset) == "table" then
            if type(preset.name) ~= "string" or preset.name == "" then
                preset.name = tostring(name)
            end
            out[#out + 1] = preset
        end
    end
    table.sort(out, function(a, b)
        return tostring(a.name):lower() < tostring(b.name):lower()
    end)
    return out
end

function M.find(kind, name)
    if type(name) ~= "string" then return nil end
    local preset = M.loadStore(kind).presets[name]
    if type(preset) == "table" then
        if type(preset.name) ~= "string" or preset.name == "" then preset.name = name end
        return preset
    end
end

function M.save(kind, name, preset)
    if type(preset) ~= "table" then return false end
    name = tostring(name or ""):match("^%s*(.-)%s*$") or ""
    if name == "" then return false end

    local store = M.loadStore(kind)
    local copy = {}
    for key, value in pairs(preset) do
        if key ~= "_filename" then copy[key] = value end
    end
    copy.name = name
    store.presets[name] = copy
    return M.saveStore(kind, store)
end

function M.delete(kind, name)
    if type(name) ~= "string" then return false end
    local store = M.loadStore(kind)
    store.presets[name] = nil
    if store.active_preset == name then store.active_preset = nil end
    return M.saveStore(kind, store)
end

function M.removeAll()
    root_ready = false
    return BrandMigration.removeSettings({ settings_dir = settings_parent, lfs = lfs })
end

return M
