local _ = require("gettext")
local lfs = require("libs/libkoreader-lfs")
local Store = require("modules/menu/app_launcher/store")

local M = {}

local ZENPM_AUTO_ADD_EXCLUDED = {
    zenfm = true,
    zenpm = true,
    zenos = true,
    zen_ui = true,
}

local function suggest_icon(label)
    local ok_root, root = pcall(require, "common/plugin_root")
    return require("common/utils").suggestIcon(
        ok_root and root or nil, label, "lightning")
end

local function valid_plugin(plugin)
    return type(plugin) == "table"
        and type(plugin.key) == "string"
        and type(plugin.method) == "string"
end

local function valid_koreader_menu(menu)
    return type(menu) == "table"
        and type(menu.id) == "string"
        and menu.id ~= ""
end

local function valid_entry(entry, allow_folder)
    if type(entry) ~= "table" or type(entry.id) ~= "string" then
        return false
    end
    if entry.type == "break" then
        return true
    end
    if type(entry.label) ~= "string" or entry.label == "" then
        return false
    end
    if entry.type == "action" then
        return type(entry.action) == "table"
    elseif entry.type == "plugin" then
        return valid_plugin(entry.plugin)
    elseif entry.type == "koreader_menu" then
        return valid_koreader_menu(entry.koreader_menu)
    elseif entry.type == "quick_setting" then
        return type(entry.quick_setting_id) == "string" and entry.quick_setting_id ~= ""
    elseif entry.type == "folder_shortcut" then
        return type(entry.folder) == "string" and entry.folder ~= ""
    elseif entry.type == "tag" then
        return type(entry.tag) == "string" and entry.tag ~= ""
    elseif allow_folder and entry.type == "folder" then
        return true
    end
    return false
end

local function sanitize_list(entries, allow_folder)
    local out = {}
    local changed = false
    if type(entries) ~= "table" then
        return out, true
    end
    for _i, entry in ipairs(entries) do
        if valid_entry(entry, allow_folder) then
            if entry.type == "folder" then
                local children, child_changed = sanitize_list(entry.children, false)
                local folder = entry
                if child_changed or type(entry.children) ~= "table" then
                    folder = {}
                    for key, value in pairs(entry) do
                        folder[key] = value
                    end
                    folder.children = children
                    changed = true
                end
                out[#out + 1] = folder
            else
                out[#out + 1] = entry
            end
        else
            changed = true
        end
    end
    return out, changed
end

local function plugin_is_enabled(name)
    local ok_loader, PluginLoader = pcall(require, "pluginloader")
    if not ok_loader or type(PluginLoader) ~= "table"
            or type(PluginLoader.loadPlugins) ~= "function" then
        return false
    end
    local ok_plugins, plugins = pcall(PluginLoader.loadPlugins, PluginLoader)
    if not ok_plugins or type(plugins) ~= "table" then return false end
    for _i, plugin in ipairs(plugins) do
        if type(plugin) == "table" and plugin.name == name then
            return true
        end
    end
    return false
end

local function has_plugin_entry(entries, plugin_key, quick_setting_id)
    for _i, entry in ipairs(entries or {}) do
        if type(entry) == "table" then
            local plugin = entry.plugin
            if entry.type == "plugin" and type(plugin) == "table"
                    and plugin.key == plugin_key then
                return true
            end
            if quick_setting_id and entry.type == "quick_setting"
                    and entry.quick_setting_id == quick_setting_id then
                return true
            end
            if entry.type == "folder"
                    and has_plugin_entry(entry.children, plugin_key, quick_setting_id) then
                return true
            end
        end
    end
    return false
end

local function remove_uninstalled_zenpm_entries(entries, installed)
    local changed = false
    for i = #(entries or {}), 1, -1 do
        local entry = entries[i]
        local plugin = type(entry) == "table" and entry.plugin or nil
        local package_id = type(plugin) == "table" and plugin.zenpm_package_id or nil
        local install_path = type(plugin) == "table" and plugin.zenpm_install_path or nil
        if type(package_id) == "string" and package_id ~= ""
                and not installed[package_id]
                and type(install_path) == "string" and install_path ~= ""
                and lfs.attributes(install_path, "mode") == nil then
            table.remove(entries, i)
            changed = true
        elseif type(entry) == "table" and entry.type == "folder"
                and remove_uninstalled_zenpm_entries(entry.children, installed) then
            changed = true
        end
    end
    return changed
end

function M.ensure()
    local cfg = Store.load()
    local entries, changed = sanitize_list(cfg.entries, true)
    if changed then
        cfg.entries = entries
    elseif type(cfg.entries) ~= "table" then
        cfg.entries = {}
    end
    if changed then
        Store.save(cfg)
    end
    return cfg
end

function M.save(cfg)
    return Store.save(cfg)
end

function M.ensure_zenpm_launcher_entry()
    local cfg = M.ensure()
    if cfg.zenpm_launcher_added == true or not plugin_is_enabled("zenpm") then
        return false
    end
    if not has_plugin_entry(cfg.entries, "zenpm") then
        cfg.entries[#cfg.entries + 1] = {
            id = M.next_id(cfg),
            type = "plugin",
            label = "ZenPM",
            icon = "zenpm",
            plugin = { key = "zenpm", method = "open" },
        }
    end
    cfg.zenpm_launcher_added = true
    Store.save(cfg)
    return true
end

function M.ensure_zenfm_launcher_entry()
    local cfg = M.ensure()
    if not plugin_is_enabled("zenfm") then
        if cfg.zenfm_launcher_added == true then
            cfg.zenfm_launcher_added = nil
            Store.save(cfg)
        end
        return false
    end
    if cfg.zenfm_launcher_added == true then
        return false
    end
    if not has_plugin_entry(cfg.entries, "zenfm", "zenfm") then
        cfg.entries[#cfg.entries + 1] = {
            id = M.next_id(cfg),
            type = "quick_setting",
            label = "ZenFM",
            icon = "zenfm",
            quick_setting_id = "zenfm",
        }
    end
    cfg.zenfm_launcher_added = true
    Store.save(cfg)
    return true
end

function M.ensure_zenpm_plugin_entries()
    local Pending = require("modules/menu/app_launcher/zenpm_pending")
    local pending, db_path, installed = Pending.read()
    if #pending == 0 and installed == nil then return false end

    local cfg = M.ensure()
    local consumed = {}
    local install_paths = {}
    local changed = installed ~= nil
        and remove_uninstalled_zenpm_entries(cfg.entries, installed) or false
    local added = false
    if #pending == 0 then
        if changed then Store.save(cfg) end
        return false
    end
    for _i, entry in ipairs(pending) do
        local path = type(entry) == "table" and entry.install_path or ""
        path = path:gsub("/+$", "")
        local key = path:match("([^/]+)%.koplugin$")
        if path ~= "" and type(entry.id) == "string" then
            install_paths[entry.id] = path
        end
        if ZENPM_AUTO_ADD_EXCLUDED[key] and type(entry.id) == "string" then
            consumed[entry.id] = true
        end
    end

    local plugins = require("modules/menu/app_launcher/plugin_scan").scanZenPM(pending)
    for _i, plugin in ipairs(plugins) do
        local key = type(plugin) == "table" and plugin.key or nil
        local package_id = type(plugin) == "table" and plugin.zenpm_package_id or nil
        if type(key) == "string" and type(package_id) == "string" then
            if not has_plugin_entry(cfg.entries, key) then
                if not ZENPM_AUTO_ADD_EXCLUDED[key] then
                    cfg.entries[#cfg.entries + 1] = {
                        id = M.next_id(cfg),
                        type = "plugin",
                        label = plugin.title,
                        icon = suggest_icon(plugin.title),
                        plugin = {
                            key = key,
                            method = plugin.method,
                            zenpm_install_path = install_paths[package_id],
                            zenpm_package_id = package_id,
                        },
                    }
                    changed = true
                    added = true
                end
            end
            consumed[package_id] = true
        end
    end
    if changed then
        Store.save(cfg)
    end
    Pending.clear(consumed, db_path)
    return added
end

-- Monotonic counter that only ever increments, so removing entries can never
-- cause a future id to collide with an existing one.
function M.next_id(cfg)
    cfg.next_id = (tonumber(cfg.next_id) or 0) + 1
    return "al_" .. cfg.next_id
end

function M.find_by_id(entries, id)
    for i, entry in ipairs(entries or {}) do
        if entry.id == id then
            return entries, i, entry, nil
        end
        if entry.type == "folder" then
            for j, child in ipairs(entry.children or {}) do
                if child.id == id then
                    return entry.children, j, child, entry
                end
            end
        end
    end
end

function M.move_by(entries, id, dir)
    local list, index = M.find_by_id(entries, id)
    if not list then return false end
    local target = index + dir
    if target < 1 or target > #list then return false end
    list[index], list[target] = list[target], list[index]
    return true
end

function M.remove_by_id(entries, id)
    local list, index = M.find_by_id(entries, id)
    if not list then return false end
    table.remove(list, index)
    return true
end

function M.move_to_folder(entries, id, folder_id)
    local entry = select(3, M.find_by_id(entries, id))
    local folder = select(3, M.find_by_id(entries, folder_id))
    if not entry or not folder or entry.type == "folder" or folder.type ~= "folder" then
        return false
    end
    M.remove_by_id(entries, id)
    folder.children = folder.children or {}
    folder.children[#folder.children + 1] = entry
    return true
end

function M.move_to_root(entries, id)
    local found = { M.find_by_id(entries, id) }
    local entry, parent = found[3], found[4]
    if not entry or not parent then return false end
    M.remove_by_id(entries, id)
    entries[#entries + 1] = entry
    return true
end

function M.display_label(entry)
    if not entry then return _("App") end
    if entry.type == "break" then
        local label = type(entry.label) == "string" and entry.label:match("%S")
            and entry.label or _("Row break")
        return "\u{2014} " .. label .. " \u{2014}"
    end
    return entry.label or _("App")
end

function M.enabled_entries(entries)
    local enabled = {}
    for _i, entry in ipairs(entries or {}) do
        if entry.enabled ~= false then
            enabled[#enabled + 1] = entry
        end
    end
    return enabled
end

return M
