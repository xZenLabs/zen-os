local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local paths = require("common/paths")

local M = {}

local EXTENSIONS = { "jpg", "jpeg" }
local SUPPORTED_EXTENSIONS = {}
for _i, extension in ipairs(EXTENSIONS) do
    SUPPORTED_EXTENSIONS[extension] = true
end

local function join(folder, name)
    if folder:sub(-1) == "/" then return folder .. name end
    return folder .. "/" .. name
end

local function canonical(path)
    if type(path) ~= "string" or path == "" then return nil end
    path = path:gsub("/+$", "")
    if path == "" then path = "/" end
    local ok, resolved = pcall(ffiUtil.realpath, path)
    return paths.normPath(ok and resolved or path)
end

local function attributes(path)
    local ok, result = pcall(lfs.attributes, path)
    return ok and result or nil
end

local function split_managed_name(filename)
    if type(filename) ~= "string" or filename == "" then return nil end
    local stem, extension = filename:lower():match("^(.+)%.([^.]+)$")
    if not stem or not SUPPORTED_EXTENSIONS[extension] then return nil end
    if stem == "cover" or stem == ".cover"
            or stem == "cover1" or stem == "cover2"
            or stem == "cover3" or stem == "cover4" then
        return stem, extension
    end
end

local function directory_names(folder)
    local names = {}
    local ok, iter, dir_obj = pcall(lfs.dir, folder)
    if not ok or type(iter) ~= "function" then return names end
    for name in iter, dir_obj do
        if name ~= "." and name ~= ".." then
            local lower = name:lower()
            if split_managed_name(lower)
                    and (not names[lower] or name < names[lower]) then
                names[lower] = name
            end
        end
    end
    return names
end

local function find_stem(folder, names, stems)
    for _i, stem in ipairs(stems) do
        for _j, extension in ipairs(EXTENSIONS) do
            local name = names[stem .. "." .. extension]
            if name then
                local path = join(folder, name)
                local attr = attributes(path)
                if attr and attr.mode == "file" then return path end
            end
        end
    end
end

local function source_extension(source)
    if type(source) ~= "string" then return nil end
    local extension = source:lower():match("%.([^./]+)$")
    return extension and SUPPORTED_EXTENSIONS[extension] and extension or nil
end

local function current_config()
    local plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    if type(plugin) == "table" and type(plugin.config) == "table" then
        local ok, manager = pcall(require, "config/manager")
        return plugin.config, ok and manager or nil
    end
    local ok, manager = pcall(require, "config/manager")
    if not ok or type(manager) ~= "table" then return nil end
    local config = type(manager.get) == "function" and manager.get() or nil
    if type(config) ~= "table" and type(manager.load) == "function" then
        config = manager.load()
    end
    return type(config) == "table" and config or nil, manager
end

local function configured_covers(folder, mode)
    local config = current_config()
    local cover_map = config and config.folder_cover_paths
    local slots = type(cover_map) == "table" and cover_map[canonical(folder)] or nil
    if type(slots) ~= "table" then return nil, false end

    local result = {}
    for slot = 1, M.slotCount(mode) do
        local path = canonical(slots[slot])
        local attr = path and attributes(path) or nil
        if attr and attr.mode == "file" and source_extension(path) then
            result[slot] = path
        end
    end
    return result, true
end

local function managed_covers(folder, mode)
    local result = {}
    if type(folder) ~= "string" or folder == "" then return result end
    local count = M.slotCount(mode)
    if count == 0 then return result end
    local names = directory_names(folder)
    if count == 1 then
        result[1] = find_stem(folder, names, { "cover", ".cover" })
        return result
    end
    result[1] = find_stem(folder, names, { "cover1", "cover", ".cover" })
    for slot = 2, count do
        result[slot] = find_stem(folder, names, { "cover" .. slot })
    end
    return result
end

function M.isManaged(filename)
    return split_managed_name(filename) ~= nil
end

function M.isSupportedImage(filename)
    return source_extension(filename) ~= nil
end

function M.slotCount(mode)
    if mode == "gallery" or mode == "stack" then return 4 end
    if mode == "none" then return 0 end
    return 1
end

function M.find(folder, mode)
    local configured, has_config = configured_covers(folder, mode)
    if has_config then return configured end
    return managed_covers(folder, mode)
end

function M.has(folder, mode)
    local covers = M.find(folder, mode)
    for slot = 1, M.slotCount(mode) do
        if covers[slot] then return true end
    end
    return false
end

function M.set(folder, mode, slot, source)
    local max_slot = M.slotCount(mode)
    slot = tonumber(slot)
    if not slot or slot % 1 ~= 0 or slot < 1 or slot > max_slot then
        return nil, "invalid_slot"
    end
    folder = canonical(folder)
    local folder_attr = folder and attributes(folder) or nil
    if not folder_attr or folder_attr.mode ~= "directory" then
        return nil, "invalid_folder"
    end
    source = canonical(source)
    local extension = source_extension(source)
    if not extension then return nil, "unsupported_source" end
    local source_attr = attributes(source)
    local source_size = source_attr and tonumber(source_attr.size)
    if not source_attr or source_attr.mode ~= "file" or not source_size or source_size <= 0 then
        return nil, "invalid_source"
    end

    local config, manager = current_config()
    if type(config) ~= "table" or type(manager) ~= "table"
            or type(manager.save) ~= "function" then
        return nil, "config_unavailable"
    end
    local previous_cover_map = config.folder_cover_paths
    local cover_map = previous_cover_map
    if type(cover_map) ~= "table" then
        cover_map = {}
        config.folder_cover_paths = cover_map
    end
    local previous_slots = cover_map[folder]
    local slots = previous_slots
    if type(slots) ~= "table" then
        slots = {}
        cover_map[folder] = slots
    end
    local previous = slots[slot]
    slots[slot] = source
    local ok_save, saved = pcall(manager.save, config, true)
    if not ok_save or saved ~= true then
        if type(previous_slots) == "table" then
            slots[slot] = previous
        else
            cover_map[folder] = previous_slots
        end
        if type(previous_cover_map) ~= "table" then
            config.folder_cover_paths = previous_cover_map
        end
        return nil, "save_failed"
    end
    return source
end

function M.clear(folder, mode, slot)
    local max_slot = M.slotCount(mode)
    slot = tonumber(slot)
    if not slot or slot % 1 ~= 0 or slot < 1 or slot > max_slot then
        return nil, "invalid_slot"
    end
    folder = canonical(folder)
    local folder_attr = folder and attributes(folder) or nil
    if not folder_attr or folder_attr.mode ~= "directory" then
        return nil, "invalid_folder"
    end

    local config, manager = current_config()
    if type(config) ~= "table" or type(manager) ~= "table"
            or type(manager.save) ~= "function" then
        return nil, "config_unavailable"
    end
    local previous_cover_map = config.folder_cover_paths
    local cover_map = previous_cover_map
    if type(cover_map) ~= "table" then
        cover_map = {}
        config.folder_cover_paths = cover_map
    end
    local previous_slots = cover_map[folder]
    local slots = previous_slots
    if type(slots) ~= "table" then
        slots = {}
        local fallback = managed_covers(folder, "gallery")
        for fallback_slot = 1, M.slotCount("gallery") do
            if fallback_slot ~= slot and fallback[fallback_slot] then
                slots[fallback_slot] = canonical(fallback[fallback_slot])
            end
        end
        cover_map[folder] = slots
    end
    local previous = slots[slot]
    slots[slot] = nil

    local ok_save, saved = pcall(manager.save, config, true)
    if not ok_save or saved ~= true then
        if type(previous_slots) == "table" then
            slots[slot] = previous
        else
            cover_map[folder] = previous_slots
        end
        if type(previous_cover_map) ~= "table" then
            config.folder_cover_paths = previous_cover_map
        end
        return nil, "save_failed"
    end
    return true
end

return M
