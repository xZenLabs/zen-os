local _ = require("gettext")

local M = {}

local BUILTINS = {
    { id = "recent", label = _("Recent"), source = true },
    { id = "favorites", label = _("Favorites"), source = true },
    { id = "to_be_read", label = _("To Be Read"), source = true },
    { id = "authors", label = _("Authors"), source = true },
    { id = "series", label = _("Series"), source = true },
    { id = "languages", label = _("Languages"), source = true },
    { id = "tags", label = _("Tags"), source = true },
    { id = "collections", label = _("Collections"), source = true },
    { id = "books", label = _("Library") },
    { id = "manga", label = _("Manga") },
    { id = "news", label = _("News") },
    { id = "continue", label = _("Continue") },
    { id = "history", label = _("History") },
    { id = "home", label = _("Home") },
    { id = "search", label = _("Search") },
    { id = "calibre_search", label = _("Calibre Search") },
    { id = "stats", label = _("Stats") },
    { id = "exit", label = _("Exit") },
    { id = "page_left", label = _("Previous page") },
    { id = "page_right", label = _("Next page") },
    { id = "menu", label = _("Menu") },
}

local STATUSES = {
    { key = "new", label = _("Unread") },
    { key = "reading", label = _("Reading") },
    { key = "tbr", label = _("To Be Read") },
    { key = "abandoned", label = _("On hold") },
    { key = "complete", label = _("Finished") },
}

local by_id = {}
for _i, item in ipairs(BUILTINS) do by_id[item.id] = item end
local status_by_key = {}
for _i, item in ipairs(STATUSES) do status_by_key[item.key] = item end

function M.builtins()
    return BUILTINS
end

function M.statuses()
    return STATUSES
end

function M.statusLabel(status)
    local item = status_by_key[status]
    return item and item.label or nil
end

function M.isSource(entry)
    if type(entry) == "string" then entry = by_id[entry] end
    if type(entry) ~= "table" then return false end
    return entry.source == true or entry.type == "tag" or entry.type == "status"
        or entry.type == "folder" or entry.type == "custom_source"
end

function M.sourceDescriptor(entry)
    if type(entry) == "string" then
        local builtin = by_id[entry]
        return builtin and builtin.source and { kind = entry } or nil
    end
    if type(entry) ~= "table" then return nil end
    if entry.source == true and type(entry.id) == "string" then
        return { kind = entry.id }
    end
    if entry.type == "tag" then return { kind = "tag", value = entry.tag } end
    if entry.type == "status" and status_by_key[entry.status] then
        return { kind = "status", value = entry.status }
    end
    if entry.type == "folder" then return { kind = "folder", value = entry.folder } end
    if entry.type == "custom_source" then
        return { kind = "custom", paths = entry.paths }
    end
end

function M.find(controls, id)
    local builtin = by_id[id]
    if builtin then return builtin end
    for _i, entry in ipairs(type(controls) == "table"
            and controls.custom_buttons or {}) do
        if entry.id == id then return entry end
    end
end

function M.getFolderActionPath(actions)
    if type(actions) ~= "table" then return end
    local folder = actions.zen_ui_show_folder
    if type(folder) ~= "string" or folder == "" then return end
    local found
    for key, value in pairs(actions) do
        if key ~= "settings" then
            local name = type(key) == "number" and value or key
            if name ~= "zen_ui_show_folder" or found then return end
            found = true
        end
    end
    return found and folder or nil
end

function M.firstVisibleSource(controls)
    if type(controls) ~= "table" then return end
    local show_buttons = type(controls.show_buttons) == "table"
        and controls.show_buttons or {}
    local seen = {}
    local visible_count = 0
    for _i, id in ipairs(type(controls.order) == "table" and controls.order or {}) do
        if type(id) == "string" and not seen[id] and show_buttons[id] == true then
            seen[id] = true
            visible_count = visible_count + 1
            local source = M.sourceDescriptor(M.find(controls, id))
            if source then return source, id end
            if visible_count >= 7 then return end
        end
    end
end

function M.label(controls, entry)
    if type(entry) ~= "table" then return _("Custom") end
    local override = type(controls) == "table" and type(controls.labels) == "table"
        and controls.labels[entry.id]
    if override == "Genres" or override == "Tags" then return _("Tags") end
    if type(override) == "string" and override ~= "" then return override end
    if type(entry.label) == "string" and entry.label ~= "" then return entry.label end
    if entry.type == "tag" then return entry.tag or _("Tag") end
    if entry.type == "status" then
        return M.statusLabel(entry.status) or _("Custom")
    end
    if entry.type == "folder" or entry.type == "folder_shortcut" then
        return require("common/library_destination").folderLabel(entry.folder)
    end
    if entry.type == "plugin" then return entry.plugin_title or _("Plugin") end
    if entry.type == "koreader_menu" then
        return entry.koreader_menu and entry.koreader_menu.title or _("KOReader menu")
    end
    return _("Custom")
end

function M.execute(entry, plugin)
    if type(entry) ~= "table" then return false end
    if by_id[entry.id] then
        local open_tab = rawget(_G, "__ZEN_UI_NAVBAR_OPEN_TAB")
        return type(open_tab) == "function" and open_tab(entry.id) == true
    end
    if entry.type == "plugin" and type(entry.plugin) == "table" then
        local PluginScan = require("modules/menu/app_launcher/plugin_scan")
        local launch = PluginScan.resolve(entry.plugin.key, entry.plugin.method)
        if launch then return pcall(launch) end
        return false
    end
    if entry.type == "quick_setting" then
        local controls = rawget(_G, "__ZEN_UI_QUICK_SETTINGS")
        if controls and type(controls.activate) == "function" then
            controls.activate(entry.quick_setting_id)
            return true
        end
        return false
    end
    if entry.type == "koreader_menu" and type(entry.koreader_menu) == "table" then
        local NativeMenu = require("modules/menu/app_launcher/native_menu")
        local launch = NativeMenu.resolve(entry.koreader_menu.id, "filemanager")
        if launch then
            require("ui/uimanager"):nextTick(function() pcall(launch) end)
            return true
        end
        return false
    end
    if (entry.type == "folder" or entry.type == "folder_shortcut")
            and type(entry.folder) == "string" then
        return require("common/dispatch_action").onShowZenUIFolder(
            plugin or rawget(_G, "__ZEN_UI_PLUGIN"), entry.folder) == true
    end
    if entry.type == "tag" and type(entry.tag) == "string" then
        return require("common/dispatch_action").onShowZenUITag(
            plugin or rawget(_G, "__ZEN_UI_PLUGIN"), entry.tag) == true
    end
    if entry.action and next(entry.action) then
        local ok, Dispatcher = pcall(require, "dispatcher")
        if ok and Dispatcher then
            Dispatcher:execute(entry.action)
            return true
        end
    end
    return false
end

return M
