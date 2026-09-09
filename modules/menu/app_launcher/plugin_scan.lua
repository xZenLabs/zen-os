local M = {}

M.SENTINEL = "__menu_callback"
M.SUBMENU = "__menu_submenu"

local EXCLUDED_PLUGINS = {
    zenos = true,
    zen_ui = true,
}

local LAUNCH_METHODS = { "onShow", "show", "open", "launch", "onOpen" }

local installed_plugins_scanned = false
local installed_plugins

local function live_uis()
    local out = {}
    local fm_mod = package.loaded["apps/filemanager/filemanager"]
    if fm_mod and fm_mod.instance then
        out[#out + 1] = fm_mod.instance
    end
    local reader_mod = package.loaded["apps/reader/readerui"]
    if reader_mod and reader_mod.instance then
        out[#out + 1] = reader_mod.instance
    end
    return out
end

local function plugin_loader()
    local ok, loader = pcall(require, "pluginloader")
    return ok and loader or nil
end

local function enabled_plugin_names()
    local names = {}
    local loader = plugin_loader()
    if not (loader and type(loader.loadPlugins) == "function") then
        return names
    end
    local ok, enabled = pcall(loader.loadPlugins, loader)
    if not ok or type(enabled) ~= "table" then
        return names
    end
    for _i, plugin in ipairs(enabled) do
        if type(plugin) == "table" and type(plugin.name) == "string" then
            names[plugin.name] = true
        end
    end
    names.zenos = nil
    names.zen_ui = nil
    return names
end

local function is_callable(value)
    if type(value) == "function" then return true end
    local mt = type(value) == "table" and getmetatable(value) or nil
    return type(mt) == "table" and type(mt.__call) == "function"
end

local function probe_menu_entry(mod, key)
    if type(mod.addToMainMenu) ~= "function" then return nil end
    local probe = {}
    local ok = pcall(mod.addToMainMenu, mod, probe)
    if not ok then return nil end
    local entry = probe[key]
    if entry == nil and type(mod.name) == "string" then
        entry = probe[mod.name]
    end
    if entry == nil then
        local only, count = nil, 0
        for _k, value in pairs(probe) do
            if type(value) == "table" then
                count = count + 1
                only = value
            end
        end
        if count == 1 then entry = only end
    end
    return type(entry) == "table" and entry or nil
end

local function text_without_glyph(text)
    if type(text) ~= "string" then return nil end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function entry_text(entry)
    if type(entry) ~= "table" then return nil end
    if type(entry.text_func) == "function" then
        local ok, text = pcall(entry.text_func)
        if ok then return text_without_glyph(text) end
    end
    return text_without_glyph(entry.text)
end

local function normalized_path(path)
    if type(path) ~= "string" then return nil end
    return path:gsub("/+$", "")
end

local function plugin_root_name(path)
    path = normalized_path(path)
    return path and path:match("([^/]+%.koplugin)$") or nil
end

function M.installed()
    if installed_plugins_scanned then return installed_plugins end
    installed_plugins_scanned = true

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local ok_root, root = pcall(require, "common/plugin_root")
    if not ok_lfs or not lfs or not ok_root or type(root) ~= "string" then return nil end

    local directories = {}
    local parent = normalized_path(root):match("^(.*)/[^/]+$")
    if parent then directories[parent] = true end
    local ok_cwd, cwd = pcall(lfs.currentdir)
    cwd = ok_cwd and normalized_path(cwd) or nil
    directories[cwd and cwd .. "/plugins" or "plugins"] = true
    local settings = rawget(_G, "G_reader_settings")
    local extra = settings and settings:readSetting("extra_plugin_paths")
    if type(extra) == "string" then extra = { extra } end
    for _i, path in ipairs(type(extra) == "table" and extra or {}) do
        path = normalized_path(path)
        if path then directories[path] = true end
    end

    local found, scanned = {}, false
    for directory in pairs(directories) do
        local ok = pcall(function()
            for entry in lfs.dir(directory) do
                local path = directory .. "/" .. entry
                if entry:sub(-9) == ".koplugin"
                        and lfs.attributes(path, "mode") == "directory" then
                    found[entry:sub(1, -10):lower()] = true
                end
            end
        end)
        scanned = ok or scanned
    end
    installed_plugins = scanned and found or nil
    return installed_plugins
end

local function find_method(mod, key)
    for _i, method in ipairs(LAUNCH_METHODS) do
        if is_callable(mod[method]) then return method end
    end
    local camel = "on" .. key:sub(1, 1):upper() .. key:sub(2)
    if is_callable(mod[camel]) then return camel end
    local entry = probe_menu_entry(mod, key)
    if entry then
        if type(entry.callback) == "function" then
            return M.SENTINEL
        end
        if entry.sub_item_table ~= nil or entry.sub_item_table_func ~= nil then
            return M.SUBMENU
        end
    end
end

local function add_candidate(out, seen, key, mod, pending_index)
    if type(key) ~= "string" or key == "" or EXCLUDED_PLUGINS[key] or seen[key]
            or type(mod) ~= "table" then
        return
    end
    local pending
    if pending_index then
        local path = normalized_path(mod.path)
        pending = pending_index.paths[path]
            or pending_index.names[plugin_root_name(path)]
        if not pending then return end
    end
    local method = find_method(mod, key)
    if not method then return end
    seen[key] = true
    local entry = probe_menu_entry(mod, key)
    local title = entry_text(entry)
    if not title or title == "" then
        title = key:sub(1, 1):upper() .. key:sub(2)
    end
    out[#out + 1] = {
        key = key,
        method = method,
        title = title,
        zenpm_package_id = pending and pending.id or nil,
    }
end

local function scan(pending_index)
    local ok, results = pcall(function()
        local out, seen = {}, {}
        local loader = plugin_loader()
        if loader and type(loader.loaded_plugins) == "table" then
            for key, mod in pairs(loader.loaded_plugins) do
                add_candidate(out, seen, key, mod, pending_index)
            end
        end

        local names = enabled_plugin_names()
        if loader and type(loader.getPluginInstance) == "function" then
            for key in pairs(names) do
                local ok_plugin, plugin = pcall(loader.getPluginInstance, loader, key)
                if ok_plugin then
                    add_candidate(out, seen, key, plugin, pending_index)
                end
            end
        end

        for _i, ui in ipairs(live_uis()) do
            for key in pairs(names) do
                add_candidate(out, seen, key, ui[key], pending_index)
            end
        end
        table.sort(out, function(a, b) return a.title < b.title end)
        return out
    end)
    return ok and results or {}
end

function M.scan()
    return scan(nil)
end

function M.scanZenPM(pending)
    local index = { paths = {}, names = {} }
    for _i, entry in ipairs(type(pending) == "table" and pending or {}) do
        local path = normalized_path(type(entry) == "table" and entry.install_path)
        if path and type(entry.id) == "string" and entry.id ~= "" then
            index.paths[path] = entry
            local name = plugin_root_name(path)
            if name then
                if index.names[name] == nil then
                    index.names[name] = entry
                else
                    index.names[name] = false
                end
            end
        end
    end
    return scan(index)
end

local function live_plugin(key)
    local loader = plugin_loader()
    local loaded = loader and loader.loaded_plugins
    if type(loaded) == "table" and type(loaded[key]) == "table" then
        return loaded[key]
    end
    if loader and type(loader.getPluginInstance) == "function" then
        local ok, plugin = pcall(loader.getPluginInstance, loader, key)
        if ok and type(plugin) == "table" then
            return plugin
        end
    end
    for _i, ui in ipairs(live_uis()) do
        if type(ui[key]) == "table" then
            return ui[key]
        end
    end
end

function M.exists(key, method)
    if type(key) ~= "string" or type(method) ~= "string" then return false end
    local mod = live_plugin(key)
    if type(mod) ~= "table" then return false end
    if method == M.SENTINEL or method == M.SUBMENU then
        return type(mod.addToMainMenu) == "function"
    end
    return is_callable(mod[method])
end

local TOUCHMENU_STUB = {
    closeMenu = function() end,
    onClose = function() end,
    updateItems = function() end,
    handleEvent = function() return false end,
}

function M.resolve(key, method)
    if type(key) ~= "string" or type(method) ~= "string" then return nil end
    local mod = live_plugin(key)
    if type(mod) ~= "table" then return nil end
    if method == M.SENTINEL then
        local entry = probe_menu_entry(mod, key)
        local callback = entry and entry.callback
        if type(callback) ~= "function" then return nil end
        return function()
            return callback(TOUCHMENU_STUB)
        end
    end
    if method == M.SUBMENU then
        local entry = probe_menu_entry(mod, key)
        if not entry then return nil end
        local sub_items = entry.sub_item_table
        if sub_items == nil and type(entry.sub_item_table_func) == "function" then
            local ok_sub, res = pcall(entry.sub_item_table_func, TOUCHMENU_STUB)
            if ok_sub then sub_items = res end
        end
        if type(sub_items) ~= "table" then return nil end
        local title = type(entry.text) == "string" and entry.text or key
        return function()
            return require("modules/menu/app_launcher/menu_host").show{
                title = title,
                item_table = sub_items,
            }
        end
    end
    if not is_callable(mod[method]) then return nil end
    return function()
        return mod[method](mod)
    end
end

return M
