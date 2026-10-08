local Archiver
local DataStorage = require("datastorage")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("common/zen_logger").new("icon_packs")

local M = {}

local SCHEMA_VERSION = 1
local MAX_ZIP_SIZE = 25 * 1024 * 1024
local MAX_ENTRY_COUNT = 512
local MAX_ENTRY_SIZE = 5 * 1024 * 1024
local MAX_TOTAL_SIZE = 50 * 1024 * 1024
local MAX_JSON_SIZE = 64 * 1024

local resolved_icons = {}
local active_pack_dir
local last_scan = { packs = {}, errors = {}, installed = {} }
local test_icons_root
local rename_path = os.rename

local function is_safe_id(value)
    return type(value) == "string"
        and value:match("^[%w][%w._-]*$") ~= nil
        and #value <= 128
end

local function file_mode(path)
    return lfs.attributes(path, "mode")
end

local function direct_mode(path)
    if lfs.symlinkattributes then return lfs.symlinkattributes(path, "mode") end
    return file_mode(path)
end

local function file_size(path)
    return tonumber(lfs.attributes(path, "size"))
end

local function resolve_local_icon(dir, name)
    if type(dir) ~= "string" or type(name) ~= "string" or not is_safe_id(name) then
        return nil
    end
    dir = dir:gsub("/+$", "") .. "/"
    local stem, ext = name:match("^(.*)(%.[Ss][Vv][Gg])$")
    if not stem then stem, ext = name:match("^(.*)(%.[Pp][Nn][Gg])$") end
    if stem and is_safe_id(stem) then
        local path = dir .. stem .. ext:lower()
        if file_mode(path) == "file" then return path end
    end
    for _i, suffix in ipairs({ ".svg", ".png" }) do
        local path = dir .. name .. suffix
        if file_mode(path) == "file" then return path end
    end
end

local function read_file(path, max_size)
    local size = file_size(path)
    if not size or size < 0 or (max_size and size > max_size) then return nil end
    local file = io.open(path, "rb")
    if not file then return nil end
    local content = file:read("*a")
    file:close()
    return content
end

local function decode_json(content)
    if type(content) ~= "string" or content == "" then return nil, "empty document" end
    local ok, value = pcall(json.decode, content)
    if not ok then return nil, value end
    if type(value) ~= "table" then return nil, "expected a JSON object" end
    return value
end

local function icons_root()
    if test_icons_root then return test_icons_root end
    return DataStorage:getFullDataDir() .. "/icons"
end

local function packs_root()
    return icons_root() .. "/zen"
end

local function make_path(path)
    if file_mode(path) == "directory" then return true end
    local current = path:sub(1, 1) == "/" and "/" or ""
    for component in path:gmatch("[^/]+") do
        current = current .. component .. "/"
        local mode = file_mode(current)
        if mode == nil then
            local ok = lfs.mkdir(current)
            if not ok then return false end
        elseif mode ~= "directory" then
            return false
        end
    end
    return true
end

local function remove_tree(path)
    local attr = lfs.symlinkattributes and lfs.symlinkattributes(path) or lfs.attributes(path)
    if not attr then return true end
    if attr.mode ~= "directory" then return os.remove(path) == true end

    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if not ok then return false end
    for entry in iter, dir_obj do
        if entry ~= "." and entry ~= ".." then
            if not remove_tree(path .. "/" .. entry) then return false end
        end
    end
    return lfs.rmdir(path) == true
end

local function validate_pack_metadata(value, expected_id)
    if type(value) ~= "table" then
        return nil, "pack.json is malformed"
    end
    if value.schema_version ~= SCHEMA_VERSION then
        return nil, "unsupported or missing pack schema"
    end
    if not is_safe_id(value.id) or (expected_id and value.id ~= expected_id) then
        return nil, "pack id does not match its folder"
    end
    if type(value.name) ~= "string" or value.name == "" or #value.name > 160 then
        return nil, "pack name is missing or invalid"
    end
    if value.version ~= nil and type(value.version) ~= "string" then
        return nil, "pack version must be a string"
    end
    if value.author ~= nil and type(value.author) ~= "string" then
        return nil, "pack author must be a string"
    end
    return {
        id = value.id,
        name = value.name,
        version = value.version,
        author = value.author,
    }
end

local function count_pack_icons(path)
    local count = 0
    local seen = {}
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if not ok then return 0 end
    for entry in iter, dir_obj do
        local stem = entry:match("^(.*)%.svg$") or entry:match("^(.*)%.png$")
        if stem and direct_mode(path .. "/" .. entry) == "file" then
            if not is_safe_id(stem) then return 0, "pack contains an unsafe icon filename" end
            if not seen[stem] then
                seen[stem] = true
                count = count + 1
            end
        end
    end
    return count
end

local function validate_pack_dir(path, expected_id)
    if direct_mode(path) ~= "directory" then return nil, "pack folder is missing" end
    if direct_mode(path .. "/pack.json") ~= "file" then return nil, "pack.json is missing" end
    local content = read_file(path .. "/pack.json", MAX_JSON_SIZE)
    local value, decode_error = decode_json(content)
    if not value then return nil, "pack.json is malformed: " .. tostring(decode_error) end
    local metadata, err = validate_pack_metadata(value, expected_id)
    if not metadata then return nil, err end
    metadata.path = path
    local icon_count, icon_error = count_pack_icons(path)
    if icon_error then return nil, icon_error end
    metadata.icon_count = icon_count
    if metadata.icon_count == 0 then return nil, "pack contains no root icons" end
    return metadata
end

local function add_pack_icons(map, path)
    local ok, iter, dir_obj = pcall(lfs.dir, path)
    if not ok then return end
    for entry in iter, dir_obj do
        local stem = entry:match("^(.*)%.svg$") or entry:match("^(.*)%.png$")
        if stem and is_safe_id(stem) and map[stem] == nil then
            local icon_path = resolve_local_icon(path, stem)
            if icon_path then map[stem] = icon_path end
        end
    end
end

local function build_resolved_map(config)
    active_pack_dir = nil
    resolved_icons = {}

    local features = type(config) == "table" and config.features
    local enabled = type(features) == "table" and features.custom_icons_enabled == true
    local custom = type(config) == "table" and config.custom_icons
    local pack_id = type(custom) == "table" and custom.active_pack or ""
    if enabled and is_safe_id(pack_id) then
        local path = packs_root() .. "/" .. pack_id
        if validate_pack_dir(path, pack_id) then active_pack_dir = path end
    end

    if enabled then
        if active_pack_dir then
            add_pack_icons(resolved_icons, active_pack_dir)
        elseif pack_id == "" or pack_id == nil then
            add_pack_icons(resolved_icons, icons_root())
        end
    end
end

local function install_icon_hook()
    local ok, IconWidget = pcall(require, "ui/widget/iconwidget")
    if not ok or not IconWidget or IconWidget.__zen_icon_pack_hook then return end
    IconWidget.__zen_icon_pack_hook = true
    local original_init = IconWidget.init
    function IconWidget:init(...)
        if not self.image and not self.file and type(self.icon) == "string" then
            local path = resolved_icons[self.icon]
            if path then self.file = path end
        end
        return original_init(self, ...)
    end
end

local function is_unsafe_archive_path(path)
    if type(path) ~= "string" or path == "" or path:find("\\", 1, true)
            or path:find("//", 1, true) or path:sub(1, 1) == "/" then
        return true
    end
    for component in path:gmatch("[^/]+") do
        if component == ".." or component == "." or component == "" then return true end
    end
    return false
end

local function get_archiver()
    if Archiver then return Archiver end
    local ok, module = pcall(require, "ffi/archiver")
    if ok then Archiver = module end
    return Archiver
end

local function inspect_zip(zip_path)
    local size = file_size(zip_path)
    if not size or size <= 0 or size > MAX_ZIP_SIZE then
        return nil, "archive exceeds the 25 MiB limit"
    end
    local archiver = get_archiver()
    if not archiver or not archiver.Reader then return nil, "archive support is unavailable" end

    local reader = archiver.Reader:new()
    if not reader:open(zip_path) then return nil, reader.err or "archive open failed" end
    local root_id
    local pack_json
    local entry_count = 0
    local total_size = 0
    local seen_paths = {}
    for entry in reader:iterate() do
        entry_count = entry_count + 1
        if entry_count > MAX_ENTRY_COUNT then
            reader:close()
            return nil, "archive contains more than 512 entries"
        end
        local path = entry.path
        if is_unsafe_archive_path(path) or (entry.mode ~= "file" and entry.mode ~= "directory") then
            reader:close()
            return nil, "archive contains an unsafe entry"
        end
        local path_key = path:lower()
        if seen_paths[path_key] then
            reader:close()
            return nil, "archive contains duplicate or conflicting paths"
        end
        seen_paths[path_key] = true
        local entry_root = path:match("^([^/]+)")
        if not is_safe_id(entry_root) or (root_id and entry_root ~= root_id) then
            reader:close()
            return nil, "archive must contain exactly one pack folder"
        end
        root_id = entry_root
        if entry.mode == "file" then
            local entry_size = tonumber(entry.size) or -1
            if entry_size < 0 or entry_size > MAX_ENTRY_SIZE then
                reader:close()
                return nil, "archive entry exceeds the 5 MiB limit"
            end
            total_size = total_size + entry_size
            if total_size > MAX_TOTAL_SIZE then
                reader:close()
                return nil, "archive exceeds the 50 MiB expanded limit"
            end
            local prefix = root_id .. "/"
            local relative = path:sub(1, #prefix) == prefix and path:sub(#prefix + 1) or ""
            local icon_stem = not relative:find("/", 1, true)
                and (relative:match("^(.*)%.svg$") or relative:match("^(.*)%.png$"))
            if icon_stem and not is_safe_id(icon_stem) then
                reader:close()
                return nil, "archive contains an unsafe icon filename"
            end
            if path == root_id .. "/pack.json" then
                if entry_size > MAX_JSON_SIZE then
                    reader:close()
                    return nil, "pack.json exceeds the 64 KiB limit"
                end
                pack_json = reader:extractToMemory(path)
                if not pack_json then
                    local err = reader.err or "could not read pack.json"
                    reader:close()
                    return nil, err
                end
            end
        end
    end
    local iterate_error = reader.err
    if iterate_error or not root_id or not pack_json then
        reader:close()
        return nil, iterate_error or "archive is missing pack.json"
    end
    reader:close()
    local value, decode_error = decode_json(pack_json)
    if not value then return nil, "pack.json is malformed: " .. tostring(decode_error) end
    local metadata, err = validate_pack_metadata(value, root_id)
    if not metadata then return nil, err end
    return metadata
end

local function extract_zip(zip_path, destination, expected_id)
    local zip_size = file_size(zip_path)
    if not zip_size or zip_size <= 0 or zip_size > MAX_ZIP_SIZE then
        return false, "archive exceeds the 25 MiB limit"
    end
    local archiver = get_archiver()
    local reader = archiver and archiver.Reader and archiver.Reader:new()
    if not reader or not reader:open(zip_path) then
        return false, reader and reader.err or "archive open failed"
    end
    local extracted = 0
    local total_size = 0
    local seen_paths = {}
    for entry in reader:iterate() do
        extracted = extracted + 1
        local path = entry.path
        local entry_root = type(path) == "string" and path:match("^([^/]+)") or nil
        if extracted > MAX_ENTRY_COUNT or is_unsafe_archive_path(path)
                or entry_root ~= expected_id
                or (entry.mode ~= "file" and entry.mode ~= "directory") then
            reader:close()
            return false, "archive changed after validation"
        end
        local path_key = path:lower()
        if seen_paths[path_key] then
            reader:close()
            return false, "archive changed after validation"
        end
        seen_paths[path_key] = true
        if entry.mode == "file" then
            local entry_size = tonumber(entry.size) or -1
            total_size = total_size + math.max(entry_size, 0)
            if entry_size < 0 or entry_size > MAX_ENTRY_SIZE or total_size > MAX_TOTAL_SIZE then
                reader:close()
                return false, "archive changed after validation"
            end
        end
        if not reader:extractToPath(path, destination .. "/" .. path) then
            local err = reader.err or "archive extraction failed"
            reader:close()
            return false, err
        end
    end
    local err = reader.err
    reader:close()
    return extracted > 0 and not err, err or (extracted == 0 and "archive is empty" or nil)
end

local function recover_transactions()
    local root = packs_root()
    local ok, iter, dir_obj = pcall(lfs.dir, root)
    if not ok then return end
    for entry in iter, dir_obj do
        local stage_id = entry:match("^%.zen%-stage%-(.+)$")
        local backup_id = entry:match("^%.zen%-backup%-(.+)$")
        local path = root .. "/" .. entry
        if stage_id and is_safe_id(stage_id) then
            remove_tree(path)
        elseif backup_id and is_safe_id(backup_id) then
            local destination = root .. "/" .. backup_id
            if file_mode(destination) == nil then
                if not rename_path(path, destination) then
                    logger.warn("Could not restore interrupted icon pack", backup_id)
                end
            else
                remove_tree(path)
            end
        end
    end
end

local function install_zip(zip_path)
    local metadata, inspect_error = inspect_zip(zip_path)
    if not metadata then return nil, inspect_error end

    local root = packs_root()
    local stage = root .. "/.zen-stage-" .. metadata.id
    local staged_pack = stage .. "/" .. metadata.id
    local destination = root .. "/" .. metadata.id
    local backup = root .. "/.zen-backup-" .. metadata.id
    remove_tree(stage)
    if not lfs.mkdir(stage) then return nil, "could not create extraction staging folder" end

    local extracted, extract_error = extract_zip(zip_path, stage, metadata.id)
    if not extracted then
        remove_tree(stage)
        return nil, extract_error
    end
    local valid, validation_error = validate_pack_dir(staged_pack, metadata.id)
    if not valid then
        remove_tree(stage)
        return nil, validation_error
    end

    remove_tree(backup)
    local had_destination = file_mode(destination) == "directory"
    if had_destination and not rename_path(destination, backup) then
        remove_tree(stage)
        return nil, "could not back up the installed pack"
    end
    if not rename_path(staged_pack, destination) then
        if had_destination then rename_path(backup, destination) end
        remove_tree(stage)
        return nil, "could not activate the extracted pack"
    end
    remove_tree(stage)
    if had_destination and not remove_tree(backup) then
        return nil, "pack installed but its backup could not be removed"
    end
    if not os.remove(zip_path) then
        return nil, "pack installed but its ZIP could not be removed"
    end
    return valid
end

local function scan_pack_folders(errors)
    local packs = {}
    local root = packs_root()
    local ok, iter, dir_obj = pcall(lfs.dir, root)
    if not ok then return packs end
    for entry in iter, dir_obj do
        if entry:sub(1, 1) ~= "." and is_safe_id(entry) then
            local path = root .. "/" .. entry
            if file_mode(path) == "directory" then
                local pack, err = validate_pack_dir(path, entry)
                if pack then
                    packs[#packs + 1] = pack
                elseif file_mode(path .. "/pack.json") == "file" then
                    errors[#errors + 1] = { file = entry, message = err }
                end
            end
        end
    end
    table.sort(packs, function(a, b)
        local an, bn = a.name:lower(), b.name:lower()
        return an == bn and a.id < b.id or an < bn
    end)
    return packs
end

function M.scan()
    local result = { packs = {}, errors = {}, installed = {} }
    if not make_path(packs_root()) then
        result.errors[1] = { file = packs_root(), message = "could not create icon pack folder" }
        last_scan = result
        return result
    end
    recover_transactions()

    local zip_names = {}
    local ok, iter, dir_obj = pcall(lfs.dir, packs_root())
    if ok then
        for entry in iter, dir_obj do
            if entry:sub(1, 1) ~= "." and entry:lower():sub(-4) == ".zip"
                    and direct_mode(packs_root() .. "/" .. entry) == "file" then
                zip_names[#zip_names + 1] = entry
            end
        end
    end
    table.sort(zip_names)
    for _i, name in ipairs(zip_names) do
        local installed, err = install_zip(packs_root() .. "/" .. name)
        if installed then
            result.installed[#result.installed + 1] = installed
            logger.info("Installed icon pack", installed.id, "from", name)
        else
            result.errors[#result.errors + 1] = { file = name, message = err or "install failed" }
            logger.warn("Could not install icon pack", name, err or "install failed")
        end
    end
    result.packs = scan_pack_folders(result.errors)
    last_scan = result
    return result
end

function M.initialize(config)
    local result = M.scan()
    build_resolved_map(config)
    install_icon_hook()
    return result
end

function M.bootstrap()
    build_resolved_map({ features = { custom_icons_enabled = false }, custom_icons = {} })
    install_icon_hook()
end

function M.resolve(name, plugin_icons_dir)
    if type(name) ~= "string" then return nil end
    local path = resolved_icons[name]
    if path then return path end
    return resolve_local_icon(plugin_icons_dir, name)
end

function M.getPickerDirectories(plugin_root_path)
    local dirs = {}
    if active_pack_dir then dirs[#dirs + 1] = active_pack_dir end
    if plugin_root_path then dirs[#dirs + 1] = plugin_root_path .. "/icons" end
    dirs[#dirs + 1] = icons_root()
    dirs[#dirs + 1] = lfs.currentdir() .. "/resources/icons/mdlight"
    return dirs
end

function M.getActivePackDirectory()
    return active_pack_dir
end

function M.isPackPickerIconAllowed(name)
    return is_safe_id(name)
end

function M.getLastScan()
    return last_scan
end

function M.getPacksRoot()
    return packs_root()
end

function M.isSafeId(value)
    return is_safe_id(value)
end

function M._inspectZip(path)
    return inspect_zip(path)
end

function M._setIconsRootForTests(path)
    test_icons_root = path
    active_pack_dir = nil
    last_scan = { packs = {}, errors = {}, installed = {} }
end

function M._setRenameForTests(rename)
    rename_path = rename or os.rename
end

function M._setArchiverForTests(archiver)
    Archiver = archiver
end

function M._getResolvedPathForTests(name)
    return resolved_icons[name]
end

function M._resetForTests()
    resolved_icons = {}
    active_pack_dir = nil
    last_scan = { packs = {}, errors = {}, installed = {} }
    test_icons_root = nil
    rename_path = os.rename
    Archiver = nil
end

return M
