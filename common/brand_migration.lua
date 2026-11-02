local M = {}

M.LEGACY_PLUGIN_DIR = "zen_ui.koplugin"
M.PLUGIN_DIR = "zenos.koplugin"
M.LEGACY_PLUGIN_ID = "zen_ui"
M.PLUGIN_ID = "zenos"
M.LEGACY_SETTINGS_DIR = "Zen UI"
M.SETTINGS_DIR = "ZenOS"

local SETTINGS_FILES = {
    "config.lua",
    "home.lua",
    "stats.lua",
    "reader.lua",
    "screensaver.lua",
    "app_launcher.lua",
    "quote_state.lua",
    "library_item_cache.lua",
}
local GLOBAL_SETTINGS_KEYS = {
    "zen_ui_config",
    "zen_ui_folder_sort",
    "zen_ui_folder_display_mode",
    "zen_ui_just_updated",
    "zen_ui_last_update_check",
    "zen_ui_update_available",
    "zen_ui_latest_version",
    "zen_ui_update_dl_url",
    "zen_ui_update_sha256",
    "zen_ui_update_channel",
    "zen_ui_update_auto_check",
    "zen_tags_global_collate",
    "zen_tags_global_reverse",
    "zen_authors_reverse",
    "zen_series_reverse",
    "zen_page_browser_layout",
    "uniform_cover_ratio",
    "opds_default_url",
}
local GLOBAL_SETTINGS_PATTERNS = {
    "^zen_tags_global_.+",
    "^zen_.+_display_mode$",
    "^zen_.+_detail_collate_.+$",
    "^zen_.+_detail_reverse_.+$",
}
local USERPATCH_PATTERNS = {
    "^%d+%-zen.*%-suppress%-startup%-alerts%.lua$",
    "^%d+%-zen[%-_]ui[%-_].*%.lua$",
    "^%d+%-zenos[%-_].*%.lua$",
}
local BRAND_MIGRATION_MARKER = "zenos_brand_migration_v1"
local PRESERVED_LEGACY_MARKER = ".zenos-preserved-legacy"
local ROOT_GUARD_KEY = "__ZENOS_PLUGIN_ROOT_GUARD"

local READER_BRAND_VALUES = {
    ["(Zen UI) Chapter Time + %"] = "(ZenOS) Chapter Time + %",
    ["(Zen UI) Pages and %"] = "(ZenOS) Pages and %",
    ["(Zen UI) Pages + Time + %"] = "(ZenOS) Pages + Time + %",
    ["(Zen UI) Centered Pages"] = "(ZenOS) Centered Pages",
    ["(Zen UI) L/C/R: Chapter Time | Page | %"] =
        "(ZenOS) L/C/R: Chapter Time | Page | %",
    ["(Zen UI) Pages | Bar | %"] = "(ZenOS) Pages | Bar | %",
}
local READER_BUILTIN_NAMES = {}
for legacy_name, current_name in pairs(READER_BRAND_VALUES) do
    READER_BUILTIN_NAMES[legacy_name] = true
    READER_BUILTIN_NAMES[current_name] = true
end

local function trim_trailing_slashes(path)
    if type(path) ~= "string" then return nil end
    if path == "/" then return path end
    return (path:gsub("/+$", ""))
end

local function join(parent, child)
    parent = trim_trailing_slashes(parent)
    if not parent or parent == "" then return child end
    return parent .. "/" .. child
end

local function dirname(path)
    return type(path) == "string" and path:match("^(.*)/[^/]+$") or nil
end

local function basename(path)
    return type(path) == "string" and path:match("([^/]+)$") or nil
end

local function get_lfs(options)
    if options and options.lfs then return options.lfs end
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    return ok and lfs or nil
end

local function get_mode(lfs, path)
    if not lfs or type(lfs.attributes) ~= "function" then return nil end
    local ok, mode = pcall(lfs.attributes, path, "mode")
    return ok and mode or nil
end

local function get_entry_mode(lfs, path)
    if lfs and type(lfs.symlinkattributes) == "function" then
        local ok, mode = pcall(lfs.symlinkattributes, path, "mode")
        if ok then return mode end
    end
    return get_mode(lfs, path)
end

local function is_directory_entry(lfs, path, entry_mode)
    entry_mode = entry_mode or get_entry_mode(lfs, path)
    return entry_mode == "directory"
        or (entry_mode == "link" and get_mode(lfs, path) == "directory")
end

local function normalize_path(path)
    if type(path) ~= "string" then return nil end
    path = path:gsub("\\", "/")
    local drive = path:match("^(%a:)/")
    local absolute = path:sub(1, 1) == "/" or drive ~= nil
    if drive then path = path:sub(4) end
    local parts = {}
    for part in path:gmatch("[^/]+") do
        if part == ".." then
            if #parts > 0 and parts[#parts] ~= ".." then
                table.remove(parts)
            elseif not absolute then
                parts[#parts + 1] = part
            end
        elseif part ~= "." and part ~= "" then
            parts[#parts + 1] = part
        end
    end
    local prefix = drive and (drive .. "/") or (absolute and "/" or "")
    local normalized = prefix .. table.concat(parts, "/")
    return normalized ~= "" and normalized or (absolute and prefix or ".")
end

local function absolute_path(path, lfs)
    path = trim_trailing_slashes(path)
    if not path or path == "" then return nil end
    path = path:gsub("\\", "/")
    if path:sub(1, 1) ~= "/" and not path:match("^%a:/")
            and lfs and type(lfs.currentdir) == "function" then
        local ok, cwd = pcall(lfs.currentdir)
        if ok and type(cwd) == "string" and cwd ~= "" then
            path = join(cwd, path)
        end
    end
    return normalize_path(path)
end

local function is_exact_settings_alias(lfs, legacy_root, root)
    if get_entry_mode(lfs, legacy_root) ~= "link"
            or not is_directory_entry(lfs, legacy_root, "link")
            or not is_directory_entry(lfs, root) then
        return false
    end
    local ok, target = pcall(lfs.symlinkattributes, legacy_root, "target")
    if not ok or type(target) ~= "string" or target == "" then return false end
    target = target:gsub("\\", "/")
    if target:sub(1, 1) ~= "/" and not target:match("^%a:/") then
        target = join(dirname(legacy_root), target)
    end
    return normalize_path(target) == normalize_path(root)
end

local function is_empty_directory(lfs, path)
    if get_entry_mode(lfs, path) ~= "directory" then return false end
    local ok, iterator, state = pcall(lfs.dir, path)
    if not ok or type(iterator) ~= "function" then return false end
    for entry in iterator, state do
        if entry ~= "." and entry ~= ".." then return false end
    end
    return true
end

local function rename_path(from_path, to_path, options)
    local rename = options and options.rename or os.rename
    local ok, result, err = pcall(rename, from_path, to_path)
    if not ok then return false, result end
    if result then return true end
    return false, err
end

local function log(level, ...)
    local ok, logger = pcall(require, "logger")
    local writer = ok and logger and logger[level]
    if type(writer) == "function" then
        writer("ZenOS: [migration]", ...)
    end
end

local function diagnostic_value(value)
    if value == nil then return "n/a" end
    return tostring(value)
end

local function migration_snapshot_status(result)
    if result.legacy_settings_snapshot_materialized then return "materialized" end
    if result.legacy_settings_snapshot_created then return "created" end
    if result.legacy_settings_preserved then return "preserved" end
    if result.snapshot_attempted then return "unavailable" end
    return "not_attempted"
end

local function migration_rollback_status(result)
    if not result.settings_rollback_attempted then return "not_needed" end
    return result.settings_rollback_succeeded and "succeeded" or "failed"
end

local function migration_conflict_count(result)
    if type(result.conflict_paths) == "table" then
        return #result.conflict_paths
    end
    return result.conflict_path and 1 or 0
end

local function log_migration_result(result)
    if type(result) ~= "table" then return end
    local status = result.status or "unknown"
    if result.migration_result_logged_status == status then return end
    if (status == "current" and not result.legacy_settings_snapshot_materialized)
            or status == "development" or status == "unmanaged"
            or status == "legacy_pending" then
        return
    end
    result.migration_result_logged_status = status
    local settings = type(result.settings) == "table" and result.settings or {}
    local level = (result.restart or status == "settings_migrated"
        or result.legacy_settings_snapshot_materialized)
        and "info" or "warn"
    log(level, "result",
        "status=" .. status,
        "plugin_dir=" .. diagnostic_value(result.plugin_dir),
        "plugin_renamed=" .. diagnostic_value(result.plugin_renamed),
        "settings_status=" .. diagnostic_value(settings.status),
        "settings_renamed=" .. diagnostic_value(settings.renamed),
        "settings_copied=" .. diagnostic_value(settings.copied),
        "legacy_preserved="
            .. diagnostic_value(result.legacy_settings_preserved),
        "disabled_transferred="
            .. diagnostic_value(result.disabled_state_transferred),
        "disabled_saved=" .. diagnostic_value(result.disabled_state_saved),
        "paths_saved=" .. diagnostic_value(result.persisted_paths_saved),
        "files_rewritten="
            .. diagnostic_value(result.persisted_files_changed),
        "global_rewritten="
            .. diagnostic_value(result.persisted_global_changed),
        "rollback=" .. migration_rollback_status(result),
        "snapshot=" .. migration_snapshot_status(result),
        "conflicts=" .. migration_conflict_count(result),
        "restart=" .. diagnostic_value(result.restart == true))
end

local function settings_parent_path(options)
    options = options or {}
    if options.settings_dir then return trim_trailing_slashes(options.settings_dir) end
    local data_storage = options.data_storage
    if not data_storage then
        local ok, loaded = pcall(require, "datastorage")
        if ok then data_storage = loaded end
    end
    if not data_storage then return nil end
    local ok_settings, settings_dir = pcall(data_storage.getSettingsDir, data_storage)
    if not ok_settings then return nil end
    return trim_trailing_slashes(settings_dir)
end

local function data_dir_path(options)
    options = options or {}
    if options.data_dir then return trim_trailing_slashes(options.data_dir) end
    local data_storage = options.data_storage
    if not data_storage then
        local ok, loaded = pcall(require, "datastorage")
        if ok then data_storage = loaded end
    end
    if not data_storage or type(data_storage.getDataDir) ~= "function" then return nil end
    local ok_data, data_dir = pcall(data_storage.getDataDir, data_storage)
    return ok_data and trim_trailing_slashes(data_dir) or nil
end

local function source_root(main_source, lfs)
    local source = main_source
    if type(source) ~= "string" or source == "" then
        source = debug.getinfo(2, "S").source or ""
    end
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    local root = source:match("^(.*)/main%.lua$")
    if not root then return nil end
    if root:sub(1, 1) ~= "/" and lfs and type(lfs.currentdir) == "function" then
        local ok, cwd = pcall(lfs.currentdir)
        if ok and type(cwd) == "string" and cwd ~= "" then
            root = join(cwd, root)
        end
    end
    return trim_trailing_slashes(root)
end

local function remove_tree(path, lfs)
    local mode = get_entry_mode(lfs, path)
    if mode == "file" or mode == "link" then
        pcall(os.remove, path)
        return
    end
    if mode ~= "directory" then return end
    local ok_dir, iterator, state = pcall(lfs.dir, path)
    if ok_dir and type(iterator) == "function" then
        for entry in iterator, state do
            if entry ~= "." and entry ~= ".." then
                remove_tree(join(path, entry), lfs)
            end
        end
    end
    pcall(lfs.rmdir, path)
end

local function copy_file(from_path, to_path, options)
    if type(options.copy_file) == "function" then
        return options.copy_file(from_path, to_path)
    end
    local source, source_err = io.open(from_path, "rb")
    if not source then return false, source_err end
    local destination, destination_err = io.open(to_path, "wb")
    if not destination then
        source:close()
        return false, destination_err
    end
    local copied = true
    local copy_err
    while true do
        local chunk = source:read(64 * 1024)
        if not chunk then break end
        local ok, err = destination:write(chunk)
        if not ok then
            copied = false
            copy_err = err
            break
        end
    end
    source:close()
    local closed, close_err = destination:close()
    if not closed then
        copied = false
        copy_err = copy_err or close_err
    end
    return copied, copy_err
end

local function copy_tree(from_path, to_path, lfs, options, follow_root_link)
    local mode = get_entry_mode(lfs, from_path)
    if mode == "link" and follow_root_link
            and get_mode(lfs, from_path) == "directory" then
        mode = "directory"
    end
    if mode == "file" then return copy_file(from_path, to_path, options) end
    if mode == "link" then
        if type(lfs.link) ~= "function"
                or type(lfs.symlinkattributes) ~= "function" then
            return false, "symlink copy unavailable"
        end
        local ok_target, target = pcall(
            lfs.symlinkattributes, from_path, "target")
        if not ok_target or type(target) ~= "string" or target == "" then
            return false, "symlink target unavailable"
        end
        local ok_link, linked = pcall(lfs.link, target, to_path, true)
        return ok_link and linked == true,
            ok_link and "could not copy symlink" or linked
    end
    if mode ~= "directory" then return false, "unsupported settings entry" end
    local created = lfs.mkdir(to_path) == true
        or get_entry_mode(lfs, to_path) == "directory"
    if not created then return false, "could not create settings directory" end
    local ok_dir, iterator, state = pcall(lfs.dir, from_path)
    if not ok_dir or type(iterator) ~= "function" then
        return false, iterator
    end
    for entry in iterator, state do
        if entry ~= "." and entry ~= ".." then
            local copied, err = copy_tree(join(from_path, entry),
                join(to_path, entry), lfs, options, false)
            if not copied then return false, err end
        end
    end
    return true
end

local function preserved_legacy_marker_path(root)
    return join(root, PRESERVED_LEGACY_MARKER)
end

local function has_preserved_legacy_marker(lfs, root)
    return get_mode(lfs, preserved_legacy_marker_path(root)) == "file"
end

local function mark_legacy_settings_preserved(root)
    local file = io.open(preserved_legacy_marker_path(root), "wb")
    if not file then return false end
    local written = file:write("v1\n")
    local closed = file:close()
    return written ~= nil and closed ~= nil
end

-- Copy the complete settings tree before any LuaSettings file is opened.
-- The untouched Zen UI tree remains a rollback snapshot; only the ZenOS copy
-- is migrated.
function M.prepareSettings(settings_parent, options)
    options = options or {}
    local lfs = get_lfs(options)
    settings_parent = trim_trailing_slashes(settings_parent)
    local legacy_root = join(settings_parent, M.LEGACY_SETTINGS_DIR)
    local root = join(settings_parent, M.SETTINGS_DIR)
    local legacy_mode = get_entry_mode(lfs, legacy_root)
    local root_mode = get_entry_mode(lfs, root)
    local legacy_is_directory = is_directory_entry(lfs, legacy_root, legacy_mode)
    local root_is_directory = is_directory_entry(lfs, root, root_mode)

    if is_exact_settings_alias(lfs, legacy_root, root) then
        return {
            ok = true,
            status = "current",
            root = root,
            legacy_root = legacy_root,
            legacy_alias = true,
        }
    end

    if legacy_mode and not legacy_is_directory then
        return {
            ok = false,
            status = "legacy_settings_invalid",
            root = root,
            legacy_root = legacy_root,
        }
    end
    if root_mode and not root_is_directory then
        return {
            ok = false,
            status = "settings_destination_invalid",
            root = legacy_is_directory and legacy_root or root,
            legacy_root = legacy_root,
        }
    end
    if legacy_is_directory and root_is_directory then
        if is_empty_directory(lfs, root) then
            local removed = pcall(lfs.rmdir, root)
            root_mode = get_entry_mode(lfs, root)
            root_is_directory = is_directory_entry(lfs, root, root_mode)
            if not removed or root_mode ~= nil then
                return {
                    ok = false,
                    status = "settings_destination_remove_failed",
                    root = legacy_root,
                    legacy_root = legacy_root,
                }
            end
        elseif is_empty_directory(lfs, legacy_root) then
            pcall(lfs.rmdir, legacy_root)
            if get_entry_mode(lfs, legacy_root) == nil then
                return {
                    ok = true,
                    status = "current",
                    root = root,
                    legacy_root = legacy_root,
                }
            end
        end
        if root_is_directory then
            if has_preserved_legacy_marker(lfs, root) then
                return {
                    ok = true,
                    status = "current",
                    root = root,
                    legacy_root = legacy_root,
                    legacy_preserved = true,
                }
            end
            return {
                ok = false,
                status = "settings_conflict",
                root = root,
                legacy_root = legacy_root,
            }
        end
    end
    if not legacy_is_directory then
        return {
            ok = true,
            status = root_is_directory and "current" or "absent",
            root = root,
            legacy_root = legacy_root,
        }
    end

    local copied, err = copy_tree(legacy_root, root, lfs, options, true)
    if copied and mark_legacy_settings_preserved(root) then
        return {
            ok = true,
            status = "migrated",
            root = root,
            legacy_root = legacy_root,
            copied = true,
            legacy_preserved = true,
        }
    end
    remove_tree(root, lfs)
    return {
        ok = false,
        status = "settings_copy_failed",
        root = legacy_root,
        legacy_root = legacy_root,
        error = err,
    }
end

function M.removeSettings(options)
    options = options or {}
    local lfs = get_lfs(options)
    local settings_parent = settings_parent_path(options)
    if not lfs or not settings_parent then return false end
    remove_tree(join(settings_parent, M.SETTINGS_DIR), lfs)
    remove_tree(join(settings_parent, M.LEGACY_SETTINGS_DIR), lfs)
    return true
end

local function rewrite_string(value, old_root, new_root, replacements)
    if replacements and replacements[value] then return replacements[value], true end
    if type(old_root) == "string" and old_root ~= "" then
        if value == old_root then return new_root, true end
        local prefix = old_root .. "/"
        if value:sub(1, #prefix) == prefix then
            return new_root .. value:sub(#old_root + 1), true
        end
    end
    return value, false
end

local function deeply_equal(left, right, seen)
    if left == right then return true end
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    seen = seen or {}
    if seen[left] then return seen[left] == right end
    seen[left] = right
    for key, value in pairs(left) do
        if not deeply_equal(value, right[key], seen) then return false end
    end
    for key in pairs(right) do
        if left[key] == nil then return false end
    end
    return true
end

local function unique_migrated_key(value, rewritten_key, old_key, label)
    local suffix = label or ("migrated from " .. old_key)
    local base = rewritten_key .. " (" .. suffix .. ")"
    local candidate = base
    local index = 2
    while value[candidate] ~= nil do
        candidate = base .. " " .. index
        index = index + 1
    end
    return candidate
end

local function rewrite_table(value, old_root, new_root, replacements, seen)
    if type(value) ~= "table" then return false end
    seen = seen or {}
    if seen[value] then return false end
    seen[value] = true

    local changed = false
    local key_moves = {}
    for key, item in pairs(value) do
        if type(item) == "string" then
            local rewritten, item_changed = rewrite_string(
                item, old_root, new_root, replacements)
            if item_changed then
                value[key] = rewritten
                changed = true
            end
        elseif type(item) == "table"
                and rewrite_table(item, old_root, new_root, replacements, seen) then
            changed = true
        end

        if type(key) == "string" then
            local rewritten_key, key_changed = rewrite_string(
                key, old_root, new_root, replacements)
            if key_changed and rewritten_key ~= key then
                key_moves[#key_moves + 1] = { old = key, new = rewritten_key }
            end
        end
    end
    table.sort(key_moves, function(left, right)
        if left.new == right.new then return left.old < right.old end
        return left.new < right.new
    end)
    for _i, move in ipairs(key_moves) do
        if value[move.new] == nil then
            value[move.new] = value[move.old]
            value[move.old] = nil
            changed = true
        elseif deeply_equal(value[move.old], value[move.new]) then
            value[move.old] = nil
            changed = true
        else
            local collision_key = unique_migrated_key(
                value, move.new, move.old)
            local migrated_value = value[move.old]
            value[collision_key] = migrated_value
            value[move.old] = nil
            if type(migrated_value) == "table"
                    and migrated_value.name == move.new then
                migrated_value.name = collision_key
            end
            changed = true
        end
    end
    return changed
end

function M.rewriteTablePaths(value, old_root, new_root, replacements)
    if type(old_root) ~= "string" or old_root == ""
            or type(new_root) ~= "string" or new_root == ""
            or old_root == new_root then return false end
    return rewrite_table(value, old_root, new_root, replacements)
end

function M.markConfigMigrationComplete(config)
    if type(config) ~= "table" then return false end
    if type(config._meta) ~= "table" then config._meta = {} end
    if config._meta[BRAND_MIGRATION_MARKER] == true then return false end
    config._meta[BRAND_MIGRATION_MARKER] = true
    return true
end

function M.isConfigMigrationComplete(config)
    local meta = type(config) == "table" and config._meta or nil
    return type(meta) == "table" and meta[BRAND_MIGRATION_MARKER] == true
end

local function migrate_disabled_data(data)
    local disabled = type(data) == "table" and data.plugins_disabled or nil
    if type(disabled) ~= "table" or disabled[M.LEGACY_PLUGIN_ID] == nil then
        return false, false
    end
    if disabled[M.PLUGIN_ID] == nil then
        disabled[M.PLUGIN_ID] = disabled[M.LEGACY_PLUGIN_ID]
    end
    disabled[M.LEGACY_PLUGIN_ID] = nil
    return true, disabled[M.PLUGIN_ID] == true
end

local function flush_settings(settings, prevent_backup)
    if type(settings) ~= "table" then return false end
    if type(settings.flush) ~= "function" then return settings.file == nil end
    if prevent_backup then settings.backup = function() return false end end
    local ok, result = pcall(settings.flush, settings)
    if not ok or result == false then return false end
    if type(settings.file) ~= "string" or settings.file == "" then return true end
    local ok_read, persisted = pcall(dofile, settings.file)
    return ok_read and deeply_equal(persisted, settings.data)
end

function M.deletePluginSettings(options)
    options = options or {}
    M.removeSettings(options)

    local g_settings = options.g_settings
    if g_settings == nil then g_settings = rawget(_G, "G_reader_settings") end
    if type(g_settings) == "table" and type(g_settings.delSetting) == "function" then
        local owned_keys = {}
        for _i, key in ipairs(GLOBAL_SETTINGS_KEYS) do
            owned_keys[key] = true
        end

        local setting_keys = {}
        if type(g_settings.pairs) == "function" then
            local ok, iterator, state, first_key = pcall(
                g_settings.pairs, g_settings)
            if ok and type(iterator) == "function" then
                local key = first_key
                while true do
                    local ok_next, next_key = pcall(iterator, state, key)
                    if not ok_next or next_key == nil then break end
                    if type(next_key) == "string" then setting_keys[next_key] = true end
                    key = next_key
                end
            end
        end
        for _i, field in ipairs({ "data", "settings", "_data" }) do
            local values = rawget(g_settings, field)
            if type(values) == "table" then
                for key in pairs(values) do
                    if type(key) == "string" then setting_keys[key] = true end
                end
            end
        end
        for key in pairs(g_settings) do
            if type(key) == "string" then setting_keys[key] = true end
        end
        for key in pairs(setting_keys) do
            for _i, pattern in ipairs(GLOBAL_SETTINGS_PATTERNS) do
                if key:match(pattern) then
                    owned_keys[key] = true
                    break
                end
            end
        end

        local sorted_keys = {}
        for key in pairs(owned_keys) do sorted_keys[#sorted_keys + 1] = key end
        table.sort(sorted_keys)
        for _i, key in ipairs(sorted_keys) do
            pcall(g_settings.delSetting, g_settings, key)
        end
        flush_settings(g_settings)
    end

    local lfs = get_lfs(options)
    local data_dir = data_dir_path(options)
    local patches_dir = data_dir and join(data_dir, "patches") or nil
    if lfs and patches_dir and get_mode(lfs, patches_dir) == "directory" then
        local ok_dir, iterator, state = pcall(lfs.dir, patches_dir)
        if ok_dir and type(iterator) == "function" then
            for entry in iterator, state do
                local matches = false
                for _i, pattern in ipairs(USERPATCH_PATTERNS) do
                    if entry:match(pattern) then
                        matches = true
                        break
                    end
                end
                local fullpath = matches and join(patches_dir, entry) or nil
                local mode = fullpath and get_entry_mode(lfs, fullpath) or nil
                if mode == "file" or mode == "link" then
                    pcall(os.remove, fullpath)
                end
            end
        end
    end

    -- Rebuildable caches kept outside the ZenOS settings tree.
    if lfs then
        local settings_parent = settings_parent_path(options)
        if settings_parent then
            for _i, suffix in ipairs({ "", "-wal", "-shm", "-journal" }) do
                remove_tree(join(settings_parent, "docprops_cache.sqlite" .. suffix), lfs)
            end
        end
        if data_dir then remove_tree(join(data_dir, "cache/zen-opds-covers"), lfs) end
    end
    return true
end

local function rewrite_global_settings(g_settings, old_root, new_root,
        migrate_builtin_custom_text, prevent_backup)
    if type(g_settings) ~= "table" then return false, true end
    local changed = false
    local saved = true
    if type(g_settings.data) == "table" then
        changed = M.rewriteTablePaths(g_settings.data, old_root, new_root) or changed
        local migrated_disabled = migrate_disabled_data(g_settings.data)
        changed = migrated_disabled or changed
    else
        for _i, key in ipairs({ "footer", "screensaver_document_cover" }) do
            if type(g_settings.readSetting) == "function" then
                local ok_read, value = pcall(g_settings.readSetting, g_settings, key)
                if ok_read then
                    if type(value) == "table" then
                        if M.rewriteTablePaths(value, old_root, new_root) then
                            if type(g_settings.saveSetting) == "function" then
                                local ok_save, save_result = pcall(
                                    g_settings.saveSetting, g_settings, key, value)
                                saved = saved and ok_save and save_result ~= false
                            else
                                saved = false
                            end
                            changed = true
                        end
                    elseif type(value) == "string" then
                        local rewritten, value_changed = rewrite_string(
                            value, old_root, new_root)
                        if value_changed then
                            if type(g_settings.saveSetting) == "function" then
                                local ok_save, save_result = pcall(
                                    g_settings.saveSetting, g_settings, key, rewritten)
                                saved = saved and ok_save and save_result ~= false
                            else
                                saved = false
                            end
                            changed = true
                        end
                    end
                end
            end
        end
    end

    if migrate_builtin_custom_text
            and type(g_settings.readSetting) == "function" then
        local ok_read, custom_text = pcall(
            g_settings.readSetting, g_settings, "reader_footer_custom_text")
        if ok_read and custom_text == "Zen UI" then
            if type(g_settings.saveSetting) == "function" then
                local ok_save, save_result = pcall(g_settings.saveSetting,
                    g_settings, "reader_footer_custom_text", "ZenOS")
                saved = saved and ok_save and save_result ~= false
            else
                saved = false
            end
            changed = true
        end
    end
    if changed then
        local flushed = flush_settings(g_settings, prevent_backup)
        saved = saved and flushed
    end
    return changed, saved
end

local function migrate_reader_key_collisions(data)
    if type(data) ~= "table" or type(data.presets) ~= "table" then return false end
    local legacy_names = {}
    for legacy_name in pairs(READER_BRAND_VALUES) do
        legacy_names[#legacy_names + 1] = legacy_name
    end
    table.sort(legacy_names)
    local changed = false
    for _i, legacy_name in ipairs(legacy_names) do
        local current_name = READER_BRAND_VALUES[legacy_name]
        local legacy_preset = data.presets[legacy_name]
        local current_preset = data.presets[current_name]
        if legacy_preset ~= nil and current_preset ~= nil then
            local migrated_name = current_name
            if not deeply_equal(legacy_preset, current_preset) then
                migrated_name = unique_migrated_key(
                    data.presets, current_name, legacy_name, "migrated from Zen UI")
                data.presets[migrated_name] = legacy_preset
                if type(legacy_preset) == "table" then
                    legacy_preset.name = migrated_name
                    legacy_preset.builtin = false
                end
            end
            data.presets[legacy_name] = nil
            if data.active_preset == legacy_name then data.active_preset = migrated_name end
            if type(data.settings) == "table"
                    and data.settings.active_preset == legacy_name then
                data.settings.active_preset = migrated_name
            end
            changed = true
        end
    end
    return changed
end

local function rewrite_reader_builtins(data)
    if type(data) ~= "table" then return false, false end
    local active_preset = data.active_preset
    if type(data.settings) == "table" and data.settings.active_preset then
        active_preset = data.settings.active_preset
    end
    local builtin_active = READER_BUILTIN_NAMES[active_preset] == true
    local changed = false

    if type(data.presets) == "table" then
        for name, preset in pairs(data.presets) do
            local is_builtin = READER_BUILTIN_NAMES[name] == true
                or (type(preset) == "table"
                    and READER_BUILTIN_NAMES[preset.name] == true)
            if is_builtin and type(preset) == "table"
                    and preset.reader_footer_custom_text == "Zen UI" then
                preset.reader_footer_custom_text = "ZenOS"
                changed = true
            end
        end
    end
    if migrate_reader_key_collisions(data) then changed = true end
    if builtin_active and type(data.settings) == "table"
            and data.settings.reader_footer_custom_text == "Zen UI" then
        data.settings.reader_footer_custom_text = "ZenOS"
        changed = true
    end
    if rewrite_table(data, nil, nil, READER_BRAND_VALUES) then
        changed = true
    end
    return changed, builtin_active
end

local function rewrite_settings_files(settings_root, old_root, new_root, options)
    local lfs = get_lfs(options)
    local LuaSettings = options and options.lua_settings
    if not LuaSettings then
        local ok, loaded = pcall(require, "luasettings")
        if ok then LuaSettings = loaded end
    end
    if not LuaSettings or type(LuaSettings.open) ~= "function" then
        for _i, filename in ipairs(SETTINGS_FILES) do
            local path = join(settings_root, filename)
            if get_mode(lfs, path) == "file"
                    or get_mode(lfs, path .. ".old") == "file" then
                return 0, false, false, false
            end
        end
        return 0, false, false, true
    end

    local changed_count = 0
    local reader_builtin_active = false
    local reader_backup_builtin_active = false
    local saved = true
    for _i, filename in ipairs(SETTINGS_FILES) do
        local path = join(settings_root, filename)
        for backup_index = 0, 1 do
            local is_backup = backup_index == 1
            local candidate = is_backup and path .. ".old" or path
            if get_mode(lfs, candidate) == "file" then
                local ok_open, settings = pcall(
                    LuaSettings.open, LuaSettings, candidate)
                local changed = ok_open and type(settings) == "table"
                    and type(settings.data) == "table"
                    and M.rewriteTablePaths(
                        settings.data, old_root, new_root,
                        options.path_replacements) or false
                if options.rewrite_brand_values ~= false
                        and filename == "reader.lua" and ok_open
                        and type(settings) == "table" then
                    local reader_changed, is_builtin_active =
                        rewrite_reader_builtins(settings.data)
                    changed = reader_changed or changed
                    if is_backup then
                        reader_backup_builtin_active = is_builtin_active
                    else
                        reader_builtin_active = is_builtin_active
                    end
                end
                if changed then
                    local ok_flush = flush_settings(settings, is_backup)
                    if ok_flush then
                        changed_count = changed_count + 1
                    else
                        saved = false
                        log("warn", "could not save migrated paths in", candidate)
                    end
                elseif not ok_open then
                    saved = false
                end
            end
            -- The live flush above may have created a new legacy .old file;
            -- inspect the backup only after processing the live file.
        end
    end
    return changed_count, reader_builtin_active,
        reader_backup_builtin_active, saved
end

local function legacy_snapshot_replacements(current_root)
    local replacements = {}
    for _i, filename in ipairs({
        "Hyperreadable-Bold.ttf",
        "Hyperreadable-Italic.ttf",
        "Hyperreadable-Regular.ttf",
        "Hyperreadable-SemiBold.ttf",
    }) do
        local relative_path = "fonts/hyperreadable/" .. filename
        replacements[join(current_root, relative_path)] = "default"
        replacements[relative_path] = "default"
    end
    return replacements
end

function M.ensureLegacySettingsSnapshot(settings_parent, legacy_plugin_root,
        current_plugin_root, options)
    options = options or {}
    local lfs = get_lfs(options)
    settings_parent = trim_trailing_slashes(settings_parent)
    if not lfs or not settings_parent then return false, false, "unavailable" end

    local legacy_root = join(settings_parent, M.LEGACY_SETTINGS_DIR)
    local root = join(settings_parent, M.SETTINGS_DIR)
    local legacy_mode = get_entry_mode(lfs, legacy_root)
    if legacy_mode == "directory"
            or (legacy_mode == "link"
                and not is_exact_settings_alias(lfs, legacy_root, root)) then
        if not has_preserved_legacy_marker(lfs, root)
                and not mark_legacy_settings_preserved(root) then
            return false, false, "marker_failed"
        end
        return true, false, "preserved"
    end
    if legacy_mode == nil then return true, false, "absent" end
    if not is_exact_settings_alias(lfs, legacy_root, root) then
        return false, false, "legacy_settings_invalid"
    end

    local temp_root = join(settings_parent, M.LEGACY_SETTINGS_DIR
        .. ".zenos-snapshot-tmp")
    if get_entry_mode(lfs, temp_root) ~= nil then remove_tree(temp_root, lfs) end
    local copied, copy_err = copy_tree(root, temp_root, lfs, options, true)
    if not copied then
        remove_tree(temp_root, lfs)
        return false, false, copy_err or "copy_failed"
    end

    local rewrite_options = {}
    for key, value in pairs(options) do rewrite_options[key] = value end
    rewrite_options.path_replacements =
        legacy_snapshot_replacements(current_plugin_root)
    rewrite_options.rewrite_brand_values = false
    local saved = select(4, rewrite_settings_files(temp_root,
        current_plugin_root, legacy_plugin_root, rewrite_options))
    if not saved then
        remove_tree(temp_root, lfs)
        return false, false, "rewrite_failed"
    end
    pcall(os.remove, preserved_legacy_marker_path(temp_root))
    if not has_preserved_legacy_marker(lfs, root)
            and not mark_legacy_settings_preserved(root) then
        remove_tree(temp_root, lfs)
        return false, false, "marker_failed"
    end

    if not pcall(os.remove, legacy_root)
            or get_entry_mode(lfs, legacy_root) ~= nil then
        remove_tree(temp_root, lfs)
        return false, false, "alias_remove_failed"
    end
    local renamed, rename_err = rename_path(temp_root, legacy_root, options)
    if not renamed then
        if type(lfs.link) == "function" then
            pcall(lfs.link, M.SETTINGS_DIR, legacy_root, true)
        end
        remove_tree(temp_root, lfs)
        return false, false, rename_err or "snapshot_activate_failed"
    end
    return true, true, "materialized"
end

local function rewrite_global_backup(g_settings, old_root, new_root,
        migrate_builtin_custom_text, options)
    local path = type(g_settings) == "table" and g_settings.file or nil
    local lfs = get_lfs(options)
    if type(path) ~= "string" or get_mode(lfs, path .. ".old") ~= "file" then
        return false, true
    end
    local LuaSettings = options and options.lua_settings
    if not LuaSettings then
        local ok, loaded = pcall(require, "luasettings")
        if ok then LuaSettings = loaded end
    end
    if not LuaSettings or type(LuaSettings.open) ~= "function" then
        return false, false
    end
    local ok, backup = pcall(LuaSettings.open, LuaSettings, path .. ".old")
    if not ok then return false, false end
    return rewrite_global_settings(backup, old_root, new_root,
        migrate_builtin_custom_text, true)
end

local function config_store(settings_root, options)
    local lfs = get_lfs(options)
    local path = join(settings_root, "config.lua")
    if get_mode(lfs, path) ~= "file" then return nil end
    local LuaSettings = options and options.lua_settings
    if not LuaSettings then
        local ok, loaded = pcall(require, "luasettings")
        if ok then LuaSettings = loaded end
    end
    if not LuaSettings or type(LuaSettings.open) ~= "function" then return nil end
    local ok, settings = pcall(LuaSettings.open, LuaSettings, path)
    return ok and settings or nil
end

local function migration_marked(settings_root, options)
    local settings = config_store(settings_root, options)
    local meta = settings and type(settings.data) == "table"
        and settings.data._meta or nil
    return type(meta) == "table" and meta[BRAND_MIGRATION_MARKER] == true
end

local function mark_migration_complete(settings_root, options)
    local lfs = get_lfs(options)
    if get_mode(lfs, join(settings_root, "config.lua")) ~= "file" then return true end
    local settings = config_store(settings_root, options)
    if not settings or type(settings.data) ~= "table"
            or type(settings.flush) ~= "function" then return false end
    if next(settings.data) == nil then return true end
    if not M.markConfigMigrationComplete(settings.data) then return true end
    return flush_settings(settings)
end

function M.rewritePersistedPaths(settings_root, old_root, new_root, options)
    options = options or {}
    if not options.force and migration_marked(settings_root, options) then
        return false, 0, true
    end
    local g_settings = options.g_settings
    if g_settings == nil then g_settings = rawget(_G, "G_reader_settings") end
    local files_changed, reader_builtin_active,
        reader_backup_builtin_active, files_saved = rewrite_settings_files(
            settings_root, old_root, new_root, options)
    local global_changed, global_saved = rewrite_global_settings(
        g_settings, old_root, new_root, reader_builtin_active)
    local global_backup_changed, global_backup_saved = rewrite_global_backup(
        g_settings, old_root, new_root, reader_backup_builtin_active, options)
    local saved = files_saved and global_saved and global_backup_saved
    if saved then saved = mark_migration_complete(settings_root, options) end
    return global_changed or global_backup_changed, files_changed, saved
end

local function transfer_disabled_key(g_settings)
    if type(g_settings) ~= "table" then return false, false, true end
    if type(g_settings.readSetting) ~= "function" then
        return false, false, false
    end
    local ok_read, disabled = pcall(
        g_settings.readSetting, g_settings, "plugins_disabled")
    if not ok_read then return false, false, false end
    if type(disabled) ~= "table" then return false, false, true end
    local changed, disabled_value = migrate_disabled_data({
        plugins_disabled = disabled,
    })
    if not changed then return false, false, true end
    local saved = type(g_settings.data) == "table"
    if type(g_settings.saveSetting) == "function" then
        local ok_save, save_result = pcall(
            g_settings.saveSetting, g_settings, "plugins_disabled", disabled)
        saved = ok_save and save_result ~= false
    end
    local flushed = flush_settings(g_settings)
    return true, disabled_value, saved and flushed
end

function M.installLegacyRuntimeAliases(plugin, options)
    if type(plugin) ~= "table" then return false, false end
    options = options or {}
    local plugin_loader = options.plugin_loader
    if plugin_loader == nil then
        local ok, loaded = pcall(require, "pluginloader")
        if ok then plugin_loader = loaded end
    end

    local loader_aliased = false
    local loaded_plugins = type(plugin_loader) == "table"
        and plugin_loader.loaded_plugins or nil
    if type(loaded_plugins) == "table" then
        local legacy = loaded_plugins[M.LEGACY_PLUGIN_ID]
        local current = loaded_plugins[M.PLUGIN_ID]
        if (current == nil or current == plugin)
                and (legacy == nil or legacy == current or legacy == plugin) then
            loaded_plugins[M.LEGACY_PLUGIN_ID] = plugin
            loader_aliased = true
        end
    end

    local ui_aliased = false
    if type(plugin.ui) == "table" then
        local legacy = rawget(plugin.ui, M.LEGACY_PLUGIN_ID)
        if legacy == nil or legacy == plugin then
            rawset(plugin.ui, M.LEGACY_PLUGIN_ID, plugin)
            ui_aliased = true
        end
    end
    return loader_aliased, ui_aliased
end

local function add_brand_root(roots, root, lfs)
    root = trim_trailing_slashes(root)
    if type(root) == "string" then root = root:gsub("\\", "/") end
    local plugin_dir = basename(root)
    if plugin_dir ~= M.LEGACY_PLUGIN_DIR and plugin_dir ~= M.PLUGIN_DIR then
        return false
    end
    local normalized = absolute_path(root, lfs)
    if not normalized or get_mode(lfs, normalized) ~= "directory" then
        return false
    end
    roots[normalized] = plugin_dir
    return true
end

local function add_lookup_path(paths, seen, path, lfs)
    local normalized = absolute_path(path, lfs)
    if normalized and not seen[normalized]
            and get_mode(lfs, normalized) == "directory" then
        seen[normalized] = true
        paths[#paths + 1] = normalized
    end
end

local function fallback_lookup_paths(plugin_root, options, lfs)
    local paths = {}
    local seen = {}
    add_lookup_path(paths, seen, dirname(plugin_root), lfs)
    add_lookup_path(paths, seen, options.default_plugin_path or "plugins", lfs)

    local g_settings = options.g_settings
    if g_settings == nil then g_settings = rawget(_G, "G_reader_settings") end
    local extra_paths
    if type(g_settings) == "table" and type(g_settings.readSetting) == "function" then
        local ok, value = pcall(
            g_settings.readSetting, g_settings, "extra_plugin_paths")
        if ok then extra_paths = value end
    end
    if type(extra_paths) == "string" then extra_paths = { extra_paths } end
    if type(extra_paths) == "table" then
        for _i, path in ipairs(extra_paths) do
            add_lookup_path(paths, seen, path, lfs)
        end
    elseif extra_paths == nil then
        local data_dir = data_dir_path(options)
        if data_dir and data_dir ~= "." then
            add_lookup_path(paths, seen, join(data_dir, "plugins"), lfs)
        end
    end
    return paths
end

local function discovered_root_conflict(plugin_root, options, lfs)
    local roots = {}
    add_brand_root(roots, plugin_root, lfs)

    local plugin_loader = options.plugin_loader
    if plugin_loader == nil then plugin_loader = package.loaded["pluginloader"] end
    local discovered_ok = false
    if type(plugin_loader) == "table"
            and type(plugin_loader._discover) == "function" then
        local ok, discovered = pcall(plugin_loader._discover, plugin_loader)
        if ok and type(discovered) == "table" then
            for _i, plugin in ipairs(discovered) do
                if type(plugin) == "table" then
                    if add_brand_root(roots, plugin.path, lfs) then
                        discovered_ok = true
                    end
                end
            end
        end
    end

    if not discovered_ok then
        for _i, lookup_path in ipairs(
                fallback_lookup_paths(plugin_root, options, lfs)) do
            for _j, plugin_dir in ipairs({ M.LEGACY_PLUGIN_DIR, M.PLUGIN_DIR }) do
                local root = join(lookup_path, plugin_dir)
                if get_mode(lfs, root) == "directory" then
                    add_brand_root(roots, root, lfs)
                end
            end
        end
    end

    local conflict_paths = {}
    for root in pairs(roots) do conflict_paths[#conflict_paths + 1] = root end
    if #conflict_paths < 2 then return nil end
    table.sort(conflict_paths)
    return conflict_paths
end

local function registered_root_conflict(plugin_root, plugin_dir)
    local roots = rawget(_G, ROOT_GUARD_KEY)
    if type(roots) ~= "table" then
        roots = {}
        rawset(_G, ROOT_GUARD_KEY, roots)
    end
    if plugin_root then roots[plugin_root] = plugin_dir or true end

    local conflict_paths = {}
    for root in pairs(roots) do
        conflict_paths[#conflict_paths + 1] = root
    end
    if #conflict_paths < 2 then return nil end
    table.sort(conflict_paths)
    return conflict_paths
end

local function as_plugin_conflict(result, conflict_paths)
    local conflict = {}
    for key, value in pairs(result or {}) do conflict[key] = value end
    conflict.proceed = false
    conflict.inert = true
    conflict.pending = nil
    conflict.restart = nil
    conflict.status = "plugin_conflict"
    conflict.conflict_paths = conflict_paths
    return conflict
end

function M.checkRootConflict(result)
    if type(result) ~= "table" or not result.source_plugin_root then return result end
    local paths = registered_root_conflict(
        result.source_plugin_root, result.plugin_dir)
    return paths and as_plugin_conflict(result, paths) or result
end

local function as_state_save_failure(result, disabled_saved, paths_saved)
    result.proceed = false
    result.inert = true
    result.pending = nil
    result.restart = nil
    result.status = "migration_save_failed"
    result.disabled_state_saved = disabled_saved
    result.persisted_paths_saved = paths_saved
    log("warn", "persisted migration state could not be saved")
    return result
end

local function as_snapshot_failure(result)
    result.proceed = false
    result.inert = true
    result.pending = nil
    result.restart = nil
    result.status = "settings_snapshot_failed"
    log("warn", "legacy settings snapshot could not be saved:",
        result.legacy_settings_snapshot_status or "unknown")
    return result
end

local function preserve_legacy_settings_snapshot(result, settings_parent,
        legacy_root, new_root, options)
    result.snapshot_attempted = true
    local saved, materialized, status = M.ensureLegacySettingsSnapshot(
        settings_parent, legacy_root, new_root, options)
    result.legacy_settings_snapshot_saved = saved
    result.legacy_settings_snapshot_materialized = materialized
    result.legacy_settings_preserved = status == "preserved"
        or status == "materialized"
    result.legacy_settings_snapshot_created = result.settings
        and result.settings.copied == true
    result.legacy_settings_snapshot_status = status
    return saved
end

function M.startup(main_source, options)
    options = options or {}
    local lfs = get_lfs(options)
    local root = options.plugin_root or source_root(main_source, lfs)
    local settings_parent = settings_parent_path(options)
    local result = {
        proceed = true,
        status = "unmanaged",
        plugin_root = root,
    }
    if not root or not settings_parent then return result end

    local development_root = os.getenv and os.getenv("ZEN_UI_ROOT") or nil
    if development_root and trim_trailing_slashes(development_root) == root then
        result.status = "development"
        return result
    end

    local plugin_dir = basename(root)
    if plugin_dir ~= M.LEGACY_PLUGIN_DIR and plugin_dir ~= M.PLUGIN_DIR then
        return result
    end
    local plugin_parent = dirname(root)

    local legacy_root = join(plugin_parent, M.LEGACY_PLUGIN_DIR)
    local new_root = join(plugin_parent, M.PLUGIN_DIR)
    result.legacy_plugin_root = legacy_root
    result.plugin_root = new_root
    result.source_plugin_root = root
    result.settings_parent = settings_parent
    result.plugin_dir = plugin_dir

    if not lfs then
        result.proceed = false
        result.inert = true
        result.status = "filesystem_unavailable"
        return result
    end
    local discovered_paths = discovered_root_conflict(root, options, lfs)
    if discovered_paths then
        log("warn", "multiple plugin roots discovered; startup is disabled")
        return as_plugin_conflict(result, discovered_paths)
    end
    local guarded_paths = registered_root_conflict(root, plugin_dir)
    if guarded_paths then
        log("warn", "multiple plugin roots detected; startup is disabled")
        return as_plugin_conflict(result, guarded_paths)
    end

    local sibling_root = plugin_dir == M.LEGACY_PLUGIN_DIR and new_root or legacy_root
    if get_entry_mode(lfs, sibling_root) ~= nil then
        result.proceed = false
        result.inert = true
        result.status = "plugin_conflict"
        result.conflict_path = sibling_root
        log("warn", "both plugin directories exist; startup is disabled")
        return result
    end

    if plugin_dir == M.LEGACY_PLUGIN_DIR and options.defer_legacy then
        result.proceed = false
        result.inert = true
        result.pending = true
        result.status = "legacy_pending"
        result.options = options
        return result
    end

    local settings = M.prepareSettings(settings_parent, options)
    result.settings = settings
    if not settings.ok then
        result.proceed = false
        result.inert = true
        result.status = settings.status
        log("warn", "settings migration stopped:", settings.status,
            settings.error or "")
        return result
    end

    local g_settings = options.g_settings
    if g_settings == nil then g_settings = rawget(_G, "G_reader_settings") end

    if plugin_dir == M.LEGACY_PLUGIN_DIR then
        result.plugin_renamed = false
        local renamed, err = rename_path(legacy_root, new_root, options)
        if not renamed then
            local rename_completed = get_entry_mode(lfs, legacy_root) == nil
                and is_directory_entry(lfs, new_root)
            if not rename_completed then
                local rollback_error
                if settings.copied then
                    result.settings_rollback_attempted = true
                    remove_tree(settings.root, lfs)
                    result.settings_rollback_succeeded =
                        get_entry_mode(lfs, settings.root) == nil
                    if not result.settings_rollback_succeeded then
                        rollback_error = "could not remove copied settings"
                    end
                elseif settings.renamed then
                    local rolled_back, rollback_err = rename_path(
                        settings.root, settings.legacy_root, options)
                    result.settings_rollback_attempted = true
                    result.settings_rollback_succeeded = rolled_back == true
                    if not rolled_back then rollback_error = rollback_err end
                end
                result.proceed = false
                result.inert = true
                result.status = rollback_error
                    and "plugin_rename_failed_settings_rollback_failed"
                    or "plugin_rename_failed"
                result.error = err
                result.rollback_error = rollback_error
                log("warn", "plugin directory migration failed:", err or "")
                return result
            end
        end
        result.plugin_renamed = true
        local disabled_result = { transfer_disabled_key(g_settings) }
        local disabled_transferred = disabled_result[1]
        local disabled_saved = disabled_result[3]
        result.disabled_state_transferred = disabled_transferred
        result.disabled_state_saved = disabled_saved
        local global_changed, files_changed, paths_saved =
            M.rewritePersistedPaths(settings.root, legacy_root, new_root, {
                force = true,
                g_settings = g_settings,
                lfs = lfs,
                lua_settings = options.lua_settings,
        })
        result.persisted_global_changed = global_changed
        result.persisted_files_changed = files_changed
        result.persisted_paths_saved = paths_saved
        if not disabled_saved or not paths_saved then
            return as_state_save_failure(result, disabled_saved, paths_saved)
        end
        if not preserve_legacy_settings_snapshot(
                result, settings_parent, legacy_root, new_root, options) then
            return as_snapshot_failure(result)
        end
        result.proceed = false
        result.inert = true
        result.restart = true
        result.status = "migrated"
        log("info", "plugin and settings migrated; restart requested")
        return result
    end

    local disabled_transferred, disabled, disabled_saved =
        transfer_disabled_key(g_settings)
    result.disabled_state_transferred = disabled_transferred
    result.disabled_state_saved = disabled_saved
    local global_changed, files_changed, paths_saved =
        M.rewritePersistedPaths(settings.root, legacy_root, new_root, {
            force = settings.status == "migrated",
            g_settings = g_settings,
            lfs = lfs,
            lua_settings = options.lua_settings,
    })
    result.persisted_global_changed = global_changed
    result.persisted_files_changed = files_changed
    result.persisted_paths_saved = paths_saved
    if not disabled_saved or not paths_saved then
        return as_state_save_failure(result, disabled_saved, paths_saved)
    end
    if not preserve_legacy_settings_snapshot(
            result, settings_parent, legacy_root, new_root, options) then
        return as_snapshot_failure(result)
    end
    result.status = settings.status == "migrated"
        and "settings_migrated" or "current"
    if disabled then
        result.proceed = false
        result.inert = true
        result.restart = true
        result.status = "disabled_state_migrated"
    end
    return result
end

local function copy_options(options)
    local copy = {}
    for key, value in pairs(options or {}) do copy[key] = value end
    return copy
end

function M.detectStartup(main_source, options)
    local detection_options = copy_options(options)
    detection_options.defer_legacy = true
    local result = M.startup(main_source, detection_options)
    if not result.pending then log_migration_result(result) end
    return result
end

function M.performPending(result, options)
    if type(result) ~= "table" or not result.pending then return result end
    local perform_options = copy_options(result.options)
    for key, value in pairs(options or {}) do perform_options[key] = value end
    perform_options.defer_legacy = false
    perform_options.plugin_root = result.source_plugin_root
    perform_options.settings_dir = result.settings_parent
    local completed = M.startup(nil, perform_options)
    log_migration_result(completed)
    return completed
end

local function notice_text(result)
    if result.restart then
        if result.status == "disabled_state_migrated" then
            return "ZenOS preserved the disabled plugin setting. Restarting..."
        end
        return "ZenOS upgrade complete. Restarting..."
    end
    if result.status == "plugin_conflict" then
        return "ZenOS found more than one plugin copy. Close KOReader, keep "
            .. "one zenos.koplugin folder, move or remove every duplicate "
            .. "and zen_ui.koplugin folder, then restart."
    end
    if result.status == "settings_conflict" then
        return "ZenOS found both Zen UI and ZenOS settings. Close KOReader, "
            .. "back up both folders, move one aside, then restart. Neither "
            .. "folder was overwritten."
    end
    if result.status == "migration_save_failed" then
        return "ZenOS could not save migrated settings. Check available "
            .. "storage and folder permissions, then restart KOReader to retry. "
            .. "Existing files were kept."
    end
    if result.status == "settings_snapshot_failed" then
        return "ZenOS could not preserve the Zen UI settings snapshot. Check "
            .. "available storage and folder permissions, then restart KOReader "
            .. "to retry. Existing files were kept."
    end
    return "ZenOS could not finish migrating. Check available storage and "
        .. "folder permissions, then restart KOReader to retry. Existing files "
        .. "were kept."
end

function M.notify(result)
    if type(result) ~= "table" or not result.inert then return end
    log_migration_result(result)
    if rawget(_G, "__ZENOS_BRAND_MIGRATION_NOTICE") then return end
    _G.__ZENOS_BRAND_MIGRATION_NOTICE = true

    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    local ok_info, InfoMessage = pcall(require, "ui/widget/infomessage")
    if ok_ui and ok_info then
        UIManager:show(InfoMessage:new{ text = notice_text(result) })
    end
    if not result.restart or not ok_ui then return end

    local ok_event, Event = pcall(require, "ui/event")
    if not ok_event then return end
    local restart = function()
        UIManager:broadcastEvent(Event:new("Restart"))
    end
    if type(UIManager.tickAfterNext) == "function" then
        UIManager:tickAfterNext(restart)
    elseif type(UIManager.nextTick) == "function" then
        UIManager:nextTick(restart)
    else
        restart()
    end
end

return M
