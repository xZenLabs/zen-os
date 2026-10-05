local _ = require("gettext")

local M = {}

local ROOT_TITLES = {
    filemanager_settings = _("File browser"),
    main = _("Main menu"),
    navi = _("Navigation"),
    search = _("Search"),
    setting = _("Settings"),
    tools = _("Tools"),
    typeset = _("Typesetting"),
}

local TOUCHMENU_STUB = {
    closeMenu = function() end,
    onClose = function() end,
    updateItems = function() end,
    handleEvent = function() return false end,
}

local function trim(text)
    if type(text) ~= "string" then return nil end
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function item_title(item)
    if type(item) ~= "table" then return nil end
    if type(item.text_func) == "function" then
        local ok, title = pcall(item.text_func)
        if ok then
            title = trim(title)
            if title and title ~= "" then return title end
        end
    end
    local title = trim(item.text)
    if title and title ~= "" then return title end
    return ROOT_TITLES[item.id]
end

local function fallback_title(id)
    local title = type(id) == "string" and id:gsub("_", " ") or ""
    return title:gsub("^%l", string.upper)
end

local function menu_kind(menu)
    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_reader and ReaderUI.instance and ReaderUI.instance.menu == menu then
        return "reader"
    end
    return "filemanager"
end

local function live_menu(scope, allow_active_fallback)
    if scope == "reader" or scope == "active" or scope == nil then
        local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
        local reader = ok_reader and ReaderUI.instance or nil
        if reader and reader.menu then return reader.menu end
        if scope == "reader" then return nil end
    end

    if scope == "filemanager" or scope == "active" or scope == nil then
        local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
        local fm = ok_fm and FileManager.instance or nil
        if fm and fm.menu then return fm.menu end
        if scope == "filemanager" and not allow_active_fallback then return nil end
    end

    if allow_active_fallback then
        local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
        local reader = ok_reader and ReaderUI.instance or nil
        if reader and reader.menu then return reader.menu end
    end
end

local function ensure_item_table(menu)
    if not menu then return nil end
    if type(menu.tab_item_table) ~= "table"
            and type(menu.setUpdateItemTable) == "function" then
        pcall(menu.setUpdateItemTable, menu)
    end
    return type(menu.tab_item_table) == "table" and menu.tab_item_table or nil
end

local function menu_tree(menu)
    local items = ensure_item_table(menu)
    local removed = menu and menu._zen_mode_removed_tabs
    if not items or type(removed) ~= "table" or #removed == 0 then return items end
    local out, seen = {}, {}
    for _i, item in ipairs(items) do
        out[#out + 1] = item
        seen[item] = true
    end
    for _i, entry in ipairs(removed) do
        local item = type(entry) == "table" and entry.tab or nil
        if type(item) == "table" and not seen[item] then
            local position = #out + 1
            for index, tab in ipairs(out) do
                if tab == entry.before then position = index; break end
            end
            table.insert(out, position, item)
            seen[item] = true
        end
    end
    return out
end

local function order_for(kind)
    local module_name = kind == "reader"
        and "ui/elements/reader_menu_order"
        or "ui/elements/filemanager_menu_order"
    local ok, order = pcall(require, module_name)
    return ok and type(order) == "table" and order or {}
end

local function allowed_ids(kind)
    local allowed = {}
    for key, entries in pairs(order_for(kind)) do
        if type(key) == "string" and key ~= "KOMenu:menu_buttons" then
            allowed[key] = true
        end
        if type(entries) == "table" then
            for _i, id in ipairs(entries) do
                if type(id) == "string" and id ~= "----------------------------" then
                    allowed[id] = true
                end
            end
        end
    end
    return allowed
end

local function submenu_items(item, evaluate_func)
    if type(item) ~= "table" then return nil end
    if type(item.sub_item_table) == "table" then
        return item.sub_item_table
    end
    if type(item.sub_item_table_func) == "function" then
        if not evaluate_func then return true end
        local ok, items = pcall(item.sub_item_table_func, TOUCHMENU_STUB)
        return ok and type(items) == "table" and items or nil
    end
    if #item > 0 then return item end
end

local function walk(items, allowed, depth, out, seen, visited)
    if type(items) ~= "table" or visited[items] then return end
    visited[items] = true
    for _i, item in ipairs(items) do
        if type(item) == "table" then
            local children = submenu_items(item, true)
            local title = item_title(item) or fallback_title(item.id)
            if type(item.id) == "string" and allowed[item.id]
                    and children and not seen[item.id] then
                seen[item.id] = true
                out[#out + 1] = {
                    id = item.id,
                    title = title,
                    text = title,
                    bold = depth == 0,
                    indent_level = depth,
                }
            end
            if type(children) == "table" then
                walk(children, allowed, depth + 1, out, seen, visited)
            end
        end
    end
end

local function find_by_id(items, id, visited)
    if type(items) ~= "table" or visited[items] then return nil end
    visited[items] = true
    for _i, item in ipairs(items) do
        if type(item) == "table" then
            if item.id == id then return item end
            local children = submenu_items(item, false)
            if type(children) == "table" then
                local found = find_by_id(children, id, visited)
                if found then return found end
            end
        end
    end
end

local function resolve_item(id, scope)
    local menu = live_menu(scope, false)
    local items = menu_tree(menu)
    if not items or not allowed_ids(menu_kind(menu))[id] then return nil end
    local item = find_by_id(items, id, {})
    return item and submenu_items(item, false) and item or nil
end

function M.scan(scope)
    scope = scope or "active"
    local menu = live_menu(scope, scope == "filemanager")
    local items = menu_tree(menu)
    if not items then return {} end
    local kind = scope == "filemanager" and "filemanager" or menu_kind(menu)
    local out = {}
    walk(items, allowed_ids(kind), 0, out, {}, {})
    return out
end

function M.exists(id, scope)
    return type(id) == "string" and resolve_item(id, scope or "active") ~= nil
end

function M.isSettingsOwner(menu)
    return menu ~= nil and live_menu("active", false) == menu
        and not (menu.ui and menu.ui.tearing_down)
end

function M.settingsItems(scope, id)
    local menu = live_menu(scope or "active", false)
    local items = menu_tree(menu)
    if not items then return {} end
    local Settings = require("modules/settings/koreader_settings")
    Settings.install()
    if id then
        local item = resolve_item(id, scope or "active")
        return Settings.copyItems(item and { item } or {}, menu, true)
    end
    local roots = { _zen_native_owner = menu }
    local icons = require("common/inline_icon_map")
    local glyphs = {
        filemanager_settings = icons.koreader_file_browser,
        setting = icons.settings, tools = icons.settings_advanced,
        search = icons.search, main = icons.koreader_menu,
        navi = icons.koreader_navigation, typeset = icons.koreader_typesetting,
    }
    local injected = { zen_ui = true, zen_library_home = true, quicksettings = true,
        app_launcher = true, filemanager = true }
    for _i, tab in ipairs(items) do
        if not injected[tab.id] then
            local setting = tab.id == "setting" or tab.id == "typeset"
                or tab.id == "filemanager_settings"
            local root = {}
            for key, value in pairs(tab) do
                if type(key) ~= "number" then root[key] = value end
            end
            root.text = item_title(tab) or fallback_title(tab.id)
            if tab.enabled_func then root.enabled = nil end
            root.icon_glyph = glyphs[tab.id]
            root._zen_native_owner, root._zen_native_setting = menu, setting
            if #tab > 0 or ROOT_TITLES[tab.id] or tab.sub_item_table or tab.sub_item_table_func then
                root.sub_item_table = nil
                root.sub_item_table_func = function(page)
                    local children = tab.sub_item_table_func and tab.sub_item_table_func(page)
                        or tab.sub_item_table or tab
                    return Settings.copyItems(children, menu, setting)
                end
            end
            roots[#roots + 1] = root
        end
    end
    return roots
end

function M.resolve(id, scope)
    scope = scope or "active"
    if type(id) ~= "string" or not resolve_item(id, scope) then return nil end
    return function()
        local item = resolve_item(id, scope)
        if not item then return false end
        local items = submenu_items(item, true)
        if type(items) ~= "table" then return false end
        require("modules/menu/app_launcher/menu_host").show{
            title = item_title(item) or fallback_title(id),
            item_table = items,
        }
        return true
    end
end

return M
