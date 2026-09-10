-- settings/sections/library/navbar.lua
-- Navbar settings item for ZenOS.
-- Returns a single menu-item table: { text = _("Navbar"), sub_item_table = {...} }
-- Receives ctx: { config, save_and_apply, settings_apply }

local _ = require("gettext")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local utils = require("modules/settings/zen_settings_utils")
local icon_utils = require("common/utils")
local paths = require("common/paths")
local icons = require("common/inline_icon_map")
local IconItem = require("common/ui/icon_menu_item")
local NativeMenu = require("modules/menu/app_launcher/native_menu")
local PluginScan = require("modules/menu/app_launcher/plugin_scan")
local DispatcherMenu = require("common/dispatcher_menu")
local ButtonModel = require("common/nav_button_model")
local Destination = require("common/library_destination")
local Kindle = require("modules/filebrowser/patches/kindle_virtual_library")

local M = {}

local function suggest_icon(label, strip_zen_prefix, preferred)
    local ok_root, root = pcall(require, "common/plugin_root")
    return icon_utils.suggestIcon(
        ok_root and root or nil, label, "lightning", strip_zen_prefix, preferred)
end

function M.build(ctx)
    local config        = ctx.config
    local save_and_apply = ctx.save_and_apply
    local settings_apply = ctx.settings_apply

    local function sync_default_tab_icon()
        local ok_root, root = pcall(require, "common/plugin_root")
        icon_utils.copyDefaultCustomTabIcon(ok_root and root and root .. "/icons/" or nil, config.navbar)
    end

    -- Defer reinject to next event loop tick so the menu's post-callback
    -- redraws complete first, then the navbar repaints correctly.
    local function save_and_apply_navbar()
        sync_default_tab_icon()
        ctx.plugin:saveConfig()
        local reinject = rawget(_G, "__ZEN_UI_REINJECT_FM_NAVBAR")
        if reinject then
            UIManager:scheduleIn(0, reinject)
        else
            save_and_apply("navbar")
        end
    end

    local function queue_deferred_navbar_refresh()
        if settings_apply and settings_apply.refresh_navbar_on_menu_close then
            settings_apply.refresh_navbar_on_menu_close()
            return
        end
        local reinject = rawget(_G, "__ZEN_UI_REINJECT_NAVBARS")
            or rawget(_G, "__ZEN_UI_REINJECT_FM_NAVBAR")
        if type(reinject) == "function" then
            UIManager:scheduleIn(0, reinject)
        else
            save_and_apply("navbar")
        end
    end

    local function save_and_defer_navbar_refresh()
        sync_default_tab_icon()
        ctx.plugin:saveConfig()
        queue_deferred_navbar_refresh()
    end

    local function save_and_reinit_navbar()
        save_and_defer_navbar_refresh()
    end

    local function save_and_reflow_navbar()
        ctx.plugin:saveConfig()
        if settings_apply and settings_apply.reinit_filemanager_on_menu_close then
            settings_apply.reinit_filemanager_on_menu_close()
        else
            save_and_reinit_navbar()
        end
        queue_deferred_navbar_refresh()
    end

    if type(config.navbar.default_tab) ~= "string" or config.navbar.default_tab == "" then
        config.navbar.default_tab = "books"
    end

    local navbar_icon_size_default = 34
    local navbar_label_size_default = 20
    local navbar_icon_size_min, navbar_icon_size_max = 24, 48
    local navbar_label_size_min, navbar_label_size_max = 10, 28

    local function clamp_navbar_size(value, min_value, max_value, default_value)
        value = math.floor((tonumber(value) or default_value) + 0.5)
        return math.max(min_value, math.min(max_value, value))
    end

    local function ensure_navbar_sizes()
        config.navbar.icon_size = clamp_navbar_size(
            config.navbar.icon_size,
            navbar_icon_size_min,
            navbar_icon_size_max,
            navbar_icon_size_default)
        config.navbar.label_size = clamp_navbar_size(
            config.navbar.label_size,
            navbar_label_size_min,
            navbar_label_size_max,
            navbar_label_size_default)
    end

    ensure_navbar_sizes()

    -- -------------------------------------------------------------------------
    -- Color helpers
    -- -------------------------------------------------------------------------

    local function ensure_navbar_color()
        local c = config.navbar.active_tab_color
        if type(c) ~= "table" then
            c = { 0x33, 0x99, 0xFF }
            config.navbar.active_tab_color = c
        end
        c[1] = tonumber(c[1]) or 0x33
        c[2] = tonumber(c[2]) or 0x99
        c[3] = tonumber(c[3]) or 0xFF
        c[1] = math.max(0, math.min(255, c[1]))
        c[2] = math.max(0, math.min(255, c[2]))
        c[3] = math.max(0, math.min(255, c[3]))
        return c
    end

    local function set_navbar_color(r, g, b)
        config.navbar.active_tab_color = {
            math.max(0, math.min(255, tonumber(r) or 0)),
            math.max(0, math.min(255, tonumber(g) or 0)),
            math.max(0, math.min(255, tonumber(b) or 0)),
        }
    end

    -- -------------------------------------------------------------------------
    -- Tab definitions
    -- -------------------------------------------------------------------------

    local function get_home_tab_label()
        local label = config.navbar.home_label
        if label == nil or label == "" then return _("Home") end
        return label
    end

    local function get_folder_tab_label()
        local label = config.navbar.folder_label
        if label == nil or label == "" then return _("Folder") end
        return label
    end

    local function get_folder_tab_icon()
        local icon = config.navbar.folder_icon
        if type(icon) ~= "string" or icon == "" then return "tab_folder" end
        return icon
    end

    local navbar_tab_items = {
        { id = "books",       text = _("Library")      },
        { id = "folder",      text_func = get_folder_tab_label },
        { id = "kindle",      text = _("Kindle Library") },
        { id = "manga",       text = _("Manga")         },
        { id = "news",        text = _("News")          },
        { id = "continue",    text = _("Continue")      },
        { id = "history",     text = _("History")       },
        { id = "favorites",   text = _("Favorites")     },
        { id = "collections", text = _("Collections")   },
        { id = "authors",     text = _("Authors")       },
        { id = "series",      text = _("Series")        },
        { id = "languages",   text = _("Languages")     },
        { id = "home",        text_func = get_home_tab_label  },
        { id = "tags",        text = _("Tags")          },
        { id = "to_be_read",  text = _("To Be Read")    },
        { id = "search",         text = _("Search")          },
        { id = "calibre_search", text = _("Calibre Search")  },
        { id = "stats",          text = _("Stats")            },
        { id = "exit",        text = _("Exit")          },
        { id = "page_left",   text = _("Previous page") },
        { id = "page_right",  text = _("Next page")     },
        { id = "menu",        text = _("Menu")          },
    }

    if config.navbar.show_tabs.books == nil then
        config.navbar.show_tabs.books = true
    end

    local function get_tab_item_text(tab)
        if tab.text_func then return tab.text_func() end
        return tab.text
    end

    local tab_item_by_id = {}
    for i, tab in ipairs(navbar_tab_items) do
        tab_item_by_id[tab.id] = tab
    end

    local default_tab_ids = {
        "books", "folder", "kindle", "manga", "news", "history", "favorites",
        "collections", "authors", "series", "languages", "home", "tags", "to_be_read",
    }

    local function get_builtin_tab_label(tab_id)
        local tab = tab_item_by_id[tab_id]
        if tab then return get_tab_item_text(tab) end
    end

    local function get_default_tab_label(tab_id)
        local label = get_builtin_tab_label(tab_id)
        if label then return label end
        if type(config.navbar.custom_tabs) == "table" then
            for i, ct in ipairs(config.navbar.custom_tabs) do
                if ct.id == tab_id then
                    if ct.label and ct.label ~= "" then return ct.label end
                    return _("Custom")
                end
            end
        end
        return _("Library")
    end

    local navbar_max_tabs = 7

    local function is_known_custom_tab(id)
        if type(config.navbar.custom_tabs) ~= "table" then return false end
        for _i, ct in ipairs(config.navbar.custom_tabs) do
            if ct.id == id then return true end
        end
        return false
    end

    local function is_known_tab(id)
        return tab_item_by_id[id] ~= nil or is_known_custom_tab(id)
    end

    local function is_tab_available(id)
        return id ~= "kindle" or Kindle.isAvailable()
    end

    local function countEnabledTabs()
        local count = 0
        for _i, id in ipairs(config.navbar.tab_order) do
            if config.navbar.show_tabs[id] == true and is_known_tab(id)
                    and is_tab_available(id) then
                count = count + 1
            end
        end
        return count
    end

    local function showTabLimitMessage(text)
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = text })
    end

    local function toggleNavbarTab(id)
        if config.navbar.show_tabs[id] == true then
            if countEnabledTabs() <= 1 then
                showTabLimitMessage(_("At least one tab must be visible"))
                return false
            end
            config.navbar.show_tabs[id] = false
        else
            if countEnabledTabs() >= navbar_max_tabs then
                showTabLimitMessage(_("Maximum 7 tabs allowed"))
                return false
            end
            config.navbar.show_tabs[id] = true
        end
        save_and_defer_navbar_refresh()
        return true
    end

    local function shouldDimTab(id)
        return config.navbar.show_tabs[id] ~= true
            and countEnabledTabs() >= navbar_max_tabs
    end

    local function getCustomTabById(id)
        if type(config.navbar.custom_tabs) ~= "table" then return nil end
        for _i, ct in ipairs(config.navbar.custom_tabs) do
            if ct.id == id then return ct end
        end
        return nil
    end

    -- -------------------------------------------------------------------------
    -- Custom tab helpers
    -- -------------------------------------------------------------------------

    local ok_disp, Dispatcher = pcall(require, "dispatcher")
    local build_ct_sub_items
    local build_builtin_tab_items
    local addTagTab
    local addStatusTab

    local function is_draft_tab(ct)
        return type(ct) == "table" and type(ct._zen_draft_commit) == "function"
    end

    local function get_ct_label(ct)
        if ct.label and ct.label ~= "" then return ct.label end
        if ct.type == "tag" then
            return ct.tag or _("Tag")
        end
        if ct.type == "status" then
            return ButtonModel.statusLabel(ct.status) or _("Custom")
        end
        if ct.type == "folder" then
            return Destination.folderLabel(ct.folder)
        end
        if ct.type == "plugin" then
            return ct.plugin_title or _("Plugin")
        end
        if ct.type == "koreader_menu" then
            return ct.koreader_menu and ct.koreader_menu.title or _("KOReader menu")
        end
        if ok_disp and ct.action and next(ct.action) then
            local t = Dispatcher:menuTextFunc(ct.action)
            if t ~= _("Nothing") then return icon_utils.stripZenPrefix(t) end
        end
        return _("Custom")
    end

    local function sync_ct_action_label(ct)
        if ct.type ~= "action" then return end
        local current = ct.label or ""
        local custom_prefix = _("Custom") .. " "
        local is_legacy_auto_label = current == _("Custom")
            or current == _("Action")
            or (current:sub(1, #custom_prefix) == custom_prefix
                and tonumber(current:sub(#custom_prefix + 1)) ~= nil)
        if ct.label_auto == true or current == "" or is_legacy_auto_label then
            ct.label = get_ct_label({
                type = ct.type,
                action = ct.action,
                label = nil,
            })
            ct.label_auto = true
        end
        if ct.icon == "lightning" then
            local preferred = ButtonModel.getFolderActionPath(ct.action)
                and "tab_folder" or nil
            ct.icon = suggest_icon(ct.label, true, preferred)
        end
    end

    local function ensureTabOrder(id)
        for _i, ordered_id in ipairs(config.navbar.tab_order) do
            if ordered_id == id then return end
        end
        local inserted = false
        for i, ordered_id in ipairs(config.navbar.tab_order) do
            if ordered_id == "page_right" or ordered_id == "menu" then
                table.insert(config.navbar.tab_order, i, id)
                inserted = true
                break
            end
        end
        if not inserted then
            table.insert(config.navbar.tab_order, id)
        end
    end

    local function addBuiltinTab(touch_menu)
        local selected = {}
        for _i, id in ipairs(config.navbar.tab_order) do
            selected[id] = true
        end
        local picker_items = {}
        for _i, tab in ipairs(navbar_tab_items) do
            if not selected[tab.id] and is_tab_available(tab.id) then
                picker_items[#picker_items + 1] = {
                    id = tab.id,
                    text = tab.id == "tags" and _("All tags") or get_tab_item_text(tab),
                }
            end
        end
        local selected_status = {}
        for _i, tab in ipairs(config.navbar.custom_tabs or {}) do
            if selected[tab.id] and tab.type == "status" then
                selected_status[tab.status] = true
            end
        end
        for _i, status in ipairs(ButtonModel.statuses()) do
            if not selected_status[status.key] then
                picker_items[#picker_items + 1] = {
                    text = status.label,
                    status = status,
                }
            end
        end
        table.sort(picker_items, function(a, b) return a.text < b.text end)
        if #picker_items == 0 then return end
        require("common/ui/zen_menu_picker"){
            title = _("Choose tab"),
            items = picker_items,
            back_hold_callback = touch_menu and touch_menu.backToSettingsRoot,
            on_select = function(item)
                if item.status then
                    addStatusTab(touch_menu, item.status)
                    return
                end
                ensureTabOrder(item.id)
                config.navbar.show_tabs[item.id] = countEnabledTabs() < navbar_max_tabs
                save_and_defer_navbar_refresh()
                if touch_menu and touch_menu.backToUpperMenu then
                    touch_menu:backToUpperMenu()
                end
            end,
        }
    end

    local function commitCustomTab(ct)
        if type(config.navbar.custom_tabs) ~= "table" then
            config.navbar.custom_tabs = {}
        end
        config.navbar.next_custom_id = (config.navbar.next_custom_id or 0) + 1
        ct.id = "ct_" .. config.navbar.next_custom_id
        ct._zen_draft_commit = nil
        table.insert(config.navbar.custom_tabs, ct)
        config.navbar.show_tabs[ct.id] = countEnabledTabs() < navbar_max_tabs
        ensureTabOrder(ct.id)
        save_and_defer_navbar_refresh()
    end

    local function openCustomTabSettings(touch_menu, ct)
        if not (touch_menu and type(touch_menu.updateItems) == "function" and ct) then
            return
        end
        table.insert(touch_menu.item_table_stack, touch_menu.item_table)
        touch_menu.parent_id = nil
        touch_menu.item_table = build_ct_sub_items(ct)
        touch_menu:updateItems(1)
    end

    local function wrap_dispatch_callbacks(items, caller, on_update)
        DispatcherMenu.wrap(items, caller, on_update, "_zen_nav_dispatch")
    end

    local function showPluginPicker(on_select, touch_menu)
        local found = PluginScan.scan()
        if #found == 0 then
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{ text = _("No launchable plugin menus found") })
            return
        end
        local picker_items = {}
        for _i, plugin in ipairs(found) do
            picker_items[#picker_items + 1] = {
                text = plugin.title,
                plugin = plugin,
            }
        end
        require("common/ui/zen_menu_picker"){
            title = _("Choose plugin menu"),
            items = picker_items,
            back_hold_callback = touch_menu and touch_menu.backToSettingsRoot,
            on_select = on_select,
        }
    end

    local function showKoreaderMenuPicker(on_select, touch_menu)
        local found = NativeMenu.scan("filemanager")
        if #found == 0 then
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{ text = _("No KOReader submenus found") })
            return
        end
        require("common/ui/zen_menu_picker"){
            title = _("Choose KOReader menu"),
            items = found,
            back_hold_callback = touch_menu and touch_menu.backToSettingsRoot,
            on_select = on_select,
        }
    end

    local function showTagPicker(on_select, touch_menu)
        Destination.chooseTag(function(tag)
            on_select({ tag = tag })
        end, {
            back_hold_callback = touch_menu and touch_menu.backToSettingsRoot,
        })
    end

    local function choosePluginTab(ct, touch_menu)
        showPluginPicker(function(item)
            local plugin = item.plugin
            if not plugin then return end
            ct.type = "plugin"
            ct.plugin_title = plugin.title
            ct.plugin = { key = plugin.key, method = plugin.method }
            if not ct.label or ct.label == "" or ct.label == _("Plugin") then
                ct.label = plugin.title
            end
            if not ct.icon or ct.icon == "zen_ui" or ct.icon == "lightning" then
                ct.icon = suggest_icon(plugin.title)
            end
            if not is_draft_tab(ct) then
                save_and_defer_navbar_refresh()
            end
            if touch_menu and touch_menu.updateItems then
                touch_menu:updateItems(1)
            end
        end, touch_menu)
    end

    local function addActionTab(touch_menu)
        if not ok_disp then return end
        local taken = {}
        if type(config.navbar.custom_tabs) == "table" then
            for _i, ct in ipairs(config.navbar.custom_tabs) do
                local lbl = (ct.label and ct.label ~= "") and ct.label or _("Custom")
                taken[lbl] = true
            end
        end
        local default_label
        if taken[_("Custom")] then
            local n = 2
            while taken[_("Custom") .. " " .. n] do n = n + 1 end
            default_label = _("Custom") .. " " .. n
        end
        local new_ct = {
            type = "action",
            label = default_label,
            label_auto = true,
            icon = "lightning",
            action = {},
        }
        local committed = false
        new_ct._zen_draft_commit = function()
            if committed or not (new_ct.action and next(new_ct.action)) then return end
            sync_ct_action_label(new_ct)
            commitCustomTab(new_ct)
            committed = true
        end
        openCustomTabSettings(touch_menu, new_ct)
    end

    local function addPluginTab(touch_menu)
        showPluginPicker(function(item)
            local plugin = item.plugin
            if not plugin then return end
            local new_ct = {
                type = "plugin",
                label = plugin.title,
                plugin_title = plugin.title,
                icon = suggest_icon(plugin.title),
                plugin = { key = plugin.key, method = plugin.method },
            }
            commitCustomTab(new_ct)
            openCustomTabSettings(touch_menu, new_ct)
        end, touch_menu)
    end

    local function chooseKoreaderMenuTab(ct, touch_menu)
        showKoreaderMenuPicker(function(item)
            ct.type = "koreader_menu"
            ct.koreader_menu = { id = item.id, title = item.title }
            if not ct.label or ct.label == "" or ct.label == _("KOReader menu") then
                ct.label = item.title
            end
            if not ct.icon or ct.icon == "zen_ui" or ct.icon == "lightning" then
                ct.icon = suggest_icon(item.title)
            end
            if not is_draft_tab(ct) then
                save_and_defer_navbar_refresh()
            end
            if touch_menu and touch_menu.updateItems then
                touch_menu:updateItems(1)
            end
        end, touch_menu)
    end

    local function addKoreaderMenuTab(touch_menu)
        showKoreaderMenuPicker(function(item)
            local new_ct = {
                type = "koreader_menu",
                label = item.title,
                icon = suggest_icon(item.title),
                koreader_menu = { id = item.id, title = item.title },
            }
            commitCustomTab(new_ct)
            openCustomTabSettings(touch_menu, new_ct)
        end, touch_menu)
    end

    addTagTab = function(touch_menu)
        showTagPicker(function(item)
            local ct = {
                type = "tag",
                tag = item.tag,
                label = item.tag,
                label_auto = true,
                icon = "tab_tags",
            }
            commitCustomTab(ct)
            openCustomTabSettings(touch_menu, ct)
        end, touch_menu)
    end

    addStatusTab = function(touch_menu, item)
        if not item then return end
        local ct = {
            type = "status",
            status = item.key,
            label = item.label,
            label_auto = true,
            icon = "library",
        }
        commitCustomTab(ct)
        openCustomTabSettings(touch_menu, ct)
    end

    local function addFolderTab(touch_menu)
        Destination.chooseFolder(function(path)
            local ct = {
                type = "folder",
                folder = path,
                label = Destination.folderLabel(path),
                label_auto = true,
                icon = "tab_folder",
            }
            commitCustomTab(ct)
            openCustomTabSettings(touch_menu, ct)
        end, {
            back_hold_callback = touch_menu and touch_menu.backToSettingsRoot,
        })
    end

    local function chooseFolderTab(ct, touch_menu)
        Destination.chooseFolder(function(path)
            local old_label = Destination.folderLabel(ct.folder)
            ct.folder = path
            if ct.label_auto == true or not ct.label or ct.label == ""
                    or ct.label == old_label then
                ct.label = Destination.folderLabel(path)
                ct.label_auto = true
            end
            save_and_defer_navbar_refresh()
            if touch_menu and touch_menu.updateItems then touch_menu:updateItems(1) end
        end, { path = ct.folder })
    end

    local function chooseTagTab(ct, touch_menu)
        showTagPicker(function(item)
            local old_tag = ct.tag
            ct.tag = item.tag
            if ct.label_auto == true or not ct.label or ct.label == "" or ct.label == old_tag then
                ct.label = item.tag
                ct.label_auto = true
            end
            if not is_draft_tab(ct) then
                save_and_defer_navbar_refresh()
            end
            if touch_menu and touch_menu.updateItems then
                touch_menu:updateItems(1)
            end
        end, touch_menu)
    end

    local function addQuickSettingTab(touch_menu)
        local controls = rawget(_G, "__ZEN_UI_QUICK_SETTINGS")
        if not controls or type(controls.getItems) ~= "function" then return end
        local picker_items = controls.getItems()
        if #picker_items == 0 then return end
        require("common/ui/zen_menu_picker"){
            title = _("Choose control"),
            items = picker_items,
            back_hold_callback = touch_menu and touch_menu.backToSettingsRoot,
            on_select = function(item)
                local ct = {
                    type = "quick_setting",
                    label = item.label,
                    icon = suggest_icon(item.label, nil, item.icon),
                    quick_setting_id = item.id,
                }
                commitCustomTab(ct)
                openCustomTabSettings(touch_menu, ct)
            end,
        }
    end

    local function chooseQuickSettingTab(ct, touch_menu)
        local controls = rawget(_G, "__ZEN_UI_QUICK_SETTINGS")
        if not controls or type(controls.getItems) ~= "function" then return end
        local picker_items = controls.getItems()
        if #picker_items == 0 then return end
        require("common/ui/zen_menu_picker"){
            title = _("Choose control"),
            items = picker_items,
            back_hold_callback = touch_menu and touch_menu.backToSettingsRoot,
            on_select = function(item)
                ct.quick_setting_id = item.id
                ct.label = item.label
                ct.icon = suggest_icon(item.label, nil, item.icon)
                save_and_defer_navbar_refresh()
                if touch_menu and touch_menu.updateItems then
                    touch_menu:updateItems(1)
                end
            end,
        }
    end

    local CUSTOM_TAB_ICONS
    local function getCustomTabIcons()
        if CUSTOM_TAB_ICONS then return CUSTOM_TAB_ICONS end
        local ok_root, root = pcall(require, "common/plugin_root")
        local excluded = { zen_ui_light = true, zen_ui_update = true }
        CUSTOM_TAB_ICONS = icon_utils.getIconPickerList(ok_root and root or nil, excluded)
        return CUSTOM_TAB_ICONS
    end

    local _icon_picker = require("common/ui/zen_icon_picker")
    local function showTabIconPicker(ct, on_select)
        _icon_picker(getCustomTabIcons(), ct.icon, on_select)
    end

    build_ct_sub_items = function(ct)
        local items = {}

        if ct.type == "tag" then
            table.insert(items, IconItem.decorate({
                text_func = function()
                    return T(_("Tag: %1"), ct.tag or _("(none)"))
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    chooseTagTab(ct, touch_menu)
                end,
            }, icons.keywords))
        elseif ct.type == "folder" then
            table.insert(items, IconItem.decorate({
                text_func = function()
                    return _("Folder") .. ": " .. Destination.folderLabel(ct.folder)
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    chooseFolderTab(ct, touch_menu)
                end,
            }, icons.settings_folders))
        elseif ct.type == "quick_setting" then
            table.insert(items, IconItem.decorate({
                text_func = function()
                    return T(_("Control: %1"), ct.label or _("(none)"))
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    chooseQuickSettingTab(ct, touch_menu)
                end,
            }, icons.settings_quick))
            local controls = rawget(_G, "__ZEN_UI_QUICK_SETTINGS")
            local settings_items = controls and controls.getSettingsItems
                and controls.getSettingsItems(ct.quick_setting_id)
            if settings_items and #settings_items > 0 then
                table.insert(items, IconItem.decorate({
                    text = _("Control settings"),
                    keep_menu_open = true,
                    sub_item_table = settings_items,
                }, icons.settings_quick))
            end
        elseif ct.type == "plugin" then
            table.insert(items, IconItem.decorate({
                text_func = function()
                    return T(_("Plugin: %1"), ct.plugin_title or ct.label or _("(none)"))
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    choosePluginTab(ct, touch_menu)
                end,
            }, icons.plugin))
        elseif ct.type == "koreader_menu" then
            table.insert(items, IconItem.decorate({
                text_func = function()
                    local target = ct.koreader_menu
                    return T(_("KOReader menu: %1"),
                        type(target) == "table" and target.title or ct.label or _("(none)"))
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    chooseKoreaderMenuTab(ct, touch_menu)
                end,
            }, icons.open_menu))
        elseif ct.type == "action" and ok_disp then
            local dispatch_items = {}
            local caller = {}
            Dispatcher:addSubMenu(caller, dispatch_items, ct, "action")
            wrap_dispatch_callbacks(dispatch_items, caller, function(touch_menu)
                sync_ct_action_label(ct)
                if is_draft_tab(ct) then
                    ct._zen_draft_commit()
                else
                    save_and_defer_navbar_refresh()
                end
                if touch_menu and touch_menu.updateItems then
                    touch_menu:updateItems(1)
                end
            end)
            table.insert(items, IconItem.decorate({
                text_func = function()
                    if ct.action and next(ct.action) then
                        return T(_("Action: %1"), Dispatcher:menuTextFunc(ct.action))
                    end
                    return _("Action: (none)")
                end,
                keep_menu_open = true,
                sub_item_table = dispatch_items,
            }, icons.action))
        end

        table.insert(items, IconItem.decorate({
            text_func = function()
                return T(_("Icon: %1"),
                    icon_utils.getIconDisplayName(ct.icon or "zen_ui"))
            end,
            keep_menu_open = true,
            callback = function(tm)
                showTabIconPicker(ct, function(name)
                    ct.icon = name
                    if not is_draft_tab(ct) then
                        save_and_defer_navbar_refresh()
                    end
                    if tm and tm.updateItems then tm:updateItems(1) end
                end)
            end,
        }, icons.icon))

        table.insert(items, IconItem.decorate({
            text_func = function()
                local lbl = (ct.label and ct.label ~= "") and ct.label or _("(auto)")
                return T(_("Label: %1"), lbl)
            end,
            keep_menu_open = true,
            callback = function(touch_menu)
                local InputDialog = require("ui/widget/inputdialog")
                local dialog
                dialog = InputDialog:new{
                    title = _("Custom tab label"),
                    input = ct.label or "",
                    input_hint = ct.type == "action"
                        and _("Leave empty to use action title") or nil,
                    buttons = {{
                        { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                        {
                            text = _("Set"),
                            is_enter_default = true,
                            callback = function()
                                local txt = dialog:getInputText()
                                if txt and txt ~= "" then
                                    ct.label = txt
                                    ct.label_auto = false
                                elseif ct.type == "tag" or ct.type == "status"
                                        or ct.type == "folder" then
                                    ct.label = ct.type == "tag" and ct.tag
                                        or ct.type == "status"
                                            and ButtonModel.statusLabel(ct.status)
                                        or Destination.folderLabel(ct.folder)
                                    ct.label_auto = true
                                else
                                    ct.label = nil
                                    ct.label_auto = true
                                    sync_ct_action_label(ct)
                                end
                                UIManager:close(dialog)
                                if not is_draft_tab(ct) then
                                    save_and_defer_navbar_refresh()
                                end
                                if touch_menu and touch_menu.updateItems then
                                    touch_menu:updateItems(1)
                                end
                            end,
                        },
                    }},
                }
                UIManager:show(dialog)
            end,
        }, icons.label))

        table.insert(items, IconItem.decorate({
            text = _("Delete"),
            separator = true,
            keep_menu_open = true,
            callback = function(touch_menu)
                if is_draft_tab(ct) then
                    if touch_menu then touch_menu:backToUpperMenu() end
                    return
                end
                local ConfirmBox = require("ui/widget/confirmbox")
                local function remove()
                    local cts = config.navbar.custom_tabs
                    for i, item in ipairs(cts) do
                        if item.id == ct.id then
                            table.remove(cts, i)
                            break
                        end
                    end
                    config.navbar.show_tabs[ct.id] = nil
                    local new_order = {}
                    for _i, id in ipairs(config.navbar.tab_order) do
                        if id ~= ct.id then new_order[#new_order + 1] = id end
                    end
                    config.navbar.tab_order = new_order
                    save_and_defer_navbar_refresh()
                    if touch_menu then touch_menu:backToUpperMenu() end
                end
                UIManager:show(ConfirmBox:new{
                    text = _("Delete this tab?"),
                    ok_text = _("Delete"),
                    ok_callback = remove,
                })
            end,
        }, icons.delete))

        return items
    end

    local function build_default_tab_items()
        local items = {}
        for _i, tab_id in ipairs(default_tab_ids) do
            if is_tab_available(tab_id) then
                local tid = tab_id
                local label = get_default_tab_label(tid)
                items[#items + 1] = {
                    text = label,
                    radio = true,
                    checked_func = function()
                        return (config.navbar.default_tab or "books") == tid
                    end,
                    callback = function()
                        config.navbar.default_tab = tid
                        save_and_apply_navbar()
                    end,
                }
            end
        end
        if type(config.navbar.custom_tabs) == "table" then
            for _i, ct in ipairs(config.navbar.custom_tabs) do
                local tid = ct.id
                local label = get_default_tab_label(tid)
                items[#items + 1] = {
                    text = label,
                    radio = true,
                    checked_func = function()
                        return (config.navbar.default_tab or "books") == tid
                    end,
                    callback = function()
                        config.navbar.default_tab = tid
                        save_and_apply_navbar()
                    end,
                }
            end
        end
        return items
    end

    local function build_home_tab_items()
        return {
            {
                text_func = function()
                    local label = config.navbar.home_label
                    if label == nil or label == "" then label = "Home" end
                    return _("Label: ") .. label
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    local InputDialog = require("ui/widget/inputdialog")
                    local dialog
                    dialog = InputDialog:new{
                        title = _("Home tab label"),
                        input = config.navbar.home_label or "Home",
                        input_hint = _("Default: Home"),
                        buttons = {{
                            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                            {
                                text = _("Set"),
                                is_enter_default = true,
                                callback = function()
                                    local text = dialog:getInputText()
                                    config.navbar.home_label = (text and text ~= "") and text or ""
                                    UIManager:close(dialog)
                                    save_and_apply_navbar()
                                    if touch_menu and touch_menu.updateItems then touch_menu:updateItems() end
                                end,
                            },
                        }},
                    }
                    UIManager:show(dialog)
                end,
            },
        }
    end

    local function build_books_label_items()
        local presets = { [""] = true, Books = true, Home = true, Library = true }
        return {
            {
                text = _("Books"),
                radio = true,
                checked_func = function() return config.navbar.books_label == "Books" end,
                callback = function()
                    config.navbar.books_label = "Books"
                    save_and_apply_navbar()
                end,
            },
            {
                text = _("Home"),
                radio = true,
                checked_func = function() return config.navbar.books_label == "Home" end,
                callback = function()
                    config.navbar.books_label = "Home"
                    save_and_apply_navbar()
                end,
            },
            {
                text = _("Library"),
                radio = true,
                checked_func = function()
                    local label = config.navbar.books_label
                    return label == nil or label == "" or label == "Library"
                end,
                callback = function()
                    config.navbar.books_label = ""
                    save_and_apply_navbar()
                end,
            },
            {
                text_func = function()
                    local label = config.navbar.books_label or ""
                    if presets[label] then return _("Custom") end
                    return _("Custom: ") .. label
                end,
                radio = true,
                checked_func = function()
                    return not presets[config.navbar.books_label or ""]
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    local InputDialog = require("ui/widget/inputdialog")
                    local dialog
                    dialog = InputDialog:new{
                        title = _("Books tab label"),
                        input = config.navbar.books_label or "",
                        buttons = {{
                            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                            {
                                text = _("Set"),
                                is_enter_default = true,
                                callback = function()
                                    local text = dialog:getInputText()
                                    config.navbar.books_label = text ~= "" and text or "Books"
                                    UIManager:close(dialog)
                                    save_and_apply_navbar()
                                    if touch_menu and touch_menu.updateItems then touch_menu:updateItems() end
                                end,
                            },
                        }},
                    }
                    UIManager:show(dialog)
                    dialog:onShowKeyboard()
                end,
            },
        }
    end

    local function build_books_tab_items()
        return {
            {
                text = _("Label"),
                sub_item_table = build_books_label_items(),
            },
        }
    end

    local function folder_label(path, fallback)
        if path and path ~= "" then
            local util = require("util")
            local folder_name = select(2, util.splitFilePathName(path))
            return fallback .. ": " .. folder_name
        end
        return fallback
    end

    local function build_folder_presets(action_key, folder_key)
        local function set_folder(dir_path)
            if action_key then config.navbar[action_key] = "folder" end
            config.navbar[folder_key] = dir_path
            save_and_apply_navbar()
        end

        return {
            text = _("Folder presets"),
            sub_item_table = {
                {
                    text = _("Use home folder"),
                    callback = function()
                        set_folder(paths.getHomeDir())
                    end,
                },
                {
                    text = _("Use last folder"),
                    callback = function()
                        set_folder(utils.get_last_dir())
                    end,
                },
                {
                    text = _("Use current folder"),
                    callback = function()
                        set_folder(utils.get_current_dir())
                    end,
                },
            },
        }
    end

    local function build_folder_action_item(action_key, folder_key)
        return {
            text_func = function()
                if not action_key or config.navbar[action_key] == "folder" then
                    return folder_label(config.navbar[folder_key], _("Open folder"))
                end
                return _("Open folder")
            end,
            checked_func = function()
                if action_key then return config.navbar[action_key] == "folder" end
                return config.navbar[folder_key] ~= nil and config.navbar[folder_key] ~= ""
            end,
            keep_menu_open = true,
            callback = function(touch_menu)
                local PathChooser = require("ui/widget/pathchooser")
                local start_path = config.navbar[folder_key] ~= "" and config.navbar[folder_key]
                    or G_reader_settings:readSetting("lastdir") or "/"
                UIManager:show(PathChooser:new{
                    select_file = false,
                    show_files = false,
                    path = start_path,
                    onConfirm = function(dir_path)
                        if action_key then config.navbar[action_key] = "folder" end
                        config.navbar[folder_key] = dir_path
                        save_and_apply_navbar()
                        if touch_menu and touch_menu.updateItems then touch_menu:updateItems() end
                    end,
                })
            end,
        }
    end

    local function build_folder_tab_items()
        return {
            build_folder_action_item(nil, "folder_path"),
            build_folder_presets(nil, "folder_path"),
            IconItem.decorate({
                text_func = function()
                    return T(_("Icon: %1"), icon_utils.getIconDisplayName(
                        get_folder_tab_icon()))
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    showTabIconPicker({ icon = get_folder_tab_icon() },
                        function(name)
                            config.navbar.folder_icon = name
                            save_and_defer_navbar_refresh()
                            if touch_menu and touch_menu.updateItems then
                                touch_menu:updateItems(1)
                            end
                        end)
                end,
            }, icons.icon),
            IconItem.decorate({
                text_func = function()
                    return T(_("Label: %1"), get_folder_tab_label())
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    local InputDialog = require("ui/widget/inputdialog")
                    local dialog
                    dialog = InputDialog:new{
                        title = _("Label"),
                        input = config.navbar.folder_label or "",
                        buttons = {{
                            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                            {
                                text = _("Set"),
                                is_enter_default = true,
                                callback = function()
                                    local text = dialog:getInputText()
                                    config.navbar.folder_label = text and text ~= "" and text or ""
                                    UIManager:close(dialog)
                                    save_and_defer_navbar_refresh()
                                    if touch_menu and touch_menu.updateItems then
                                        touch_menu:updateItems(1)
                                    end
                                end,
                            },
                        }},
                    }
                    UIManager:show(dialog)
                end,
            }, icons.label),
        }
    end

    local function build_manga_tab_items()
        return {
            {
                text = _("Open Rakuyomi"),
                checked_func = function() return config.navbar.manga_action ~= "folder" end,
                callback = function()
                    config.navbar.manga_action = "rakuyomi"
                    save_and_apply_navbar()
                end,
            },
            build_folder_action_item("manga_action", "manga_folder"),
            build_folder_presets("manga_action", "manga_folder"),
        }
    end

    local function build_kindle_tab_items()
        return {{
            text = _("Hide Kindle Library folder"),
            checked_func = function()
                return type(config.kindle) == "table"
                    and config.kindle.hide_library_folder == true
            end,
            callback = function()
                if type(config.kindle) ~= "table" then config.kindle = {} end
                config.kindle.hide_library_folder =
                    config.kindle.hide_library_folder ~= true
                save_and_reflow_navbar()
            end,
        }}
    end

    local function build_news_tab_items()
        return {
            {
                text = _("Open QuickRSS"),
                checked_func = function()
                    return config.navbar.news_action ~= "folder"
                        and config.navbar.news_action ~= "rssreader"
                end,
                callback = function()
                    config.navbar.news_action = "quickrss"
                    save_and_apply_navbar()
                end,
            },
            {
                text = _("Open RSS Reader"),
                checked_func = function() return config.navbar.news_action == "rssreader" end,
                callback = function()
                    config.navbar.news_action = "rssreader"
                    save_and_apply_navbar()
                end,
            },
            build_folder_action_item("news_action", "news_folder"),
            build_folder_presets("news_action", "news_folder"),
        }
    end

    local function build_tbr_tab_items()
        return { IconItem.decorate({
            text = _("Order"),
            _zen_settings_submenu = true,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                require("common/tbr_index").showOrder({
                    plugin = ctx.plugin,
                    settings_resume = touchmenu_instance
                        and touchmenu_instance._zen_settings_resume,
                    on_change = settings_apply
                        and settings_apply.refresh_tbr_on_menu_close,
                })
            end,
        }, icons.sort) }
    end

    build_builtin_tab_items = function(id)
        local items = {}
        if id == "home" then
            items = build_home_tab_items()
        elseif id == "books" then
            items = build_books_tab_items()
        elseif id == "folder" then
            items = build_folder_tab_items()
        elseif id == "kindle" then
            items = build_kindle_tab_items()
        elseif id == "manga" then
            items = build_manga_tab_items()
        elseif id == "news" then
            items = build_news_tab_items()
        elseif id == "to_be_read" then
            items = build_tbr_tab_items()
        end
        items[#items + 1] = IconItem.decorate({
            text = _("Delete"),
            separator = true,
            callback = function(touch_menu)
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("Delete this tab?"),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        local new_order = {}
                        for _i, saved_id in ipairs(config.navbar.tab_order) do
                            if saved_id ~= id then
                                new_order[#new_order + 1] = saved_id
                            end
                        end
                        config.navbar.tab_order = new_order
                        config.navbar.show_tabs[id] = false
                        save_and_defer_navbar_refresh()
                        if touch_menu then touch_menu:backToUpperMenu() end
                    end,
                })
            end,
        }, icons.delete)
        return items
    end

    local function showTabsArrange()
        local ZenArrangeList = require("common/ui/zen_arrange_list")
        local sort_items

        local function updateDimStates()
            for _i, sort_item in ipairs(sort_items) do
                sort_item.dim = shouldDimTab(sort_item.orig_item)
            end
        end

        local function addTabItem(id)
            local tab = tab_item_by_id[id]
            local ct = getCustomTabById(id)
            if not tab and not ct then return false end
            local item = {
                text_func = function()
                    if ct then return get_ct_label(ct) end
                    return get_tab_item_text(tab)
                end,
                orig_item = id,
                dim = shouldDimTab(id),
                checked_func = function()
                    return config.navbar.show_tabs[id] == true
                end,
                callback = function()
                    if toggleNavbarTab(id) then
                        updateDimStates()
                    end
                end,
            }
            if ct then
                item.sub_title = get_ct_label(ct)
                item.sub_item_table_func = function()
                    return build_ct_sub_items(ct)
                end
            else
                item.sub_title = get_tab_item_text(tab)
                item.sub_item_table_func = function()
                    return build_builtin_tab_items(id)
                end
            end
            table.insert(sort_items, item)
            return true
        end

        local function build_sort_items()
            sort_items = {}
            local in_sort = {}
            for _i, id in ipairs(config.navbar.tab_order) do
                if not in_sort[id] and addTabItem(id) then
                    in_sort[id] = true
                end
            end
            return sort_items
        end
        sort_items = build_sort_items()

        local add_items = {
            IconItem.decorate({
                text = _("Tab"),
                keep_menu_open = true,
                callback = addBuiltinTab,
            }, icons.settings_navbar),
            IconItem.decorate({
                text = _("Action"),
                keep_menu_open = true,
                callback = addActionTab,
            }, icons.action),
            IconItem.decorate({
                text = _("Folder"),
                keep_menu_open = true,
                callback = addFolderTab,
            }, icons.settings_folders),
            IconItem.decorate({
                text = _("Specific tag"),
                keep_menu_open = true,
                callback = addTagTab,
            }, icons.keywords),
            IconItem.decorate({
                text = _("Control"),
                keep_menu_open = true,
                callback = addQuickSettingTab,
            }, icons.settings_quick),
            IconItem.decorate({
                text = _("Plugin Menu"),
                keep_menu_open = true,
                callback = addPluginTab,
            }, icons.plugin),
            IconItem.decorate({
                text = _("KOReader menu"),
                keep_menu_open = true,
                callback = addKoreaderMenuTab,
            }, icons.open_menu),
        }
        ZenArrangeList.show{
            title = _("Tabs"),
            item_table = sort_items,
            add_title = _("Add"),
            hide_footer_cancel = true,
            add_item_table = add_items,
            callback = function()
                local new_order = {}
                local ordered = {}
                for _i, item in ipairs(sort_items) do
                    new_order[#new_order + 1] = item.orig_item
                    ordered[item.orig_item] = true
                end
                for _i, id in ipairs(config.navbar.tab_order) do
                    if not ordered[id] then new_order[#new_order + 1] = id end
                end
                config.navbar.tab_order = new_order
                save_and_defer_navbar_refresh()
            end,
            refresh_func = build_sort_items,
        }
    end

    local function open_tab_settings(id)
        local ct = getCustomTabById(id)
        local tab = tab_item_by_id[id]
        if not ct and not tab then
            showTabsArrange()
            return true
        end
        local items = ct and build_ct_sub_items(ct) or build_builtin_tab_items(id)
        if type(items) ~= "table" or #items == 0 then
            showTabsArrange()
            return true
        end
        require("common/ui/zen_arrange_list").show{
            title = ct and get_ct_label(ct) or get_tab_item_text(tab),
            item_table = items,
            hide_footer_cancel = true,
        }
        return true
    end

    local function arrange_search_items()
        local items = {}
        local seen = {}
        for _i, id in ipairs(config.navbar.tab_order) do
            local ct = getCustomTabById(id)
            local tab = tab_item_by_id[id]
            if not seen[id] and (ct or tab) then
                seen[id] = true
                local tab_id = id
                items[#items + 1] = {
                    text = ct and get_ct_label(ct) or get_tab_item_text(tab),
                    _zen_search_open = function()
                        return open_tab_settings(tab_id)
                    end,
                }
            end
        end
        return items
    end

    -- -------------------------------------------------------------------------
    -- Navbar item
    -- -------------------------------------------------------------------------

    return IconItem.decorate({
        text = _("Navbar"),
        _zen_search_items_func = arrange_search_items,
        sub_item_table = {
            IconItem.decorate({
                text = _("Tabs") .. " \u{25B8}",
                keep_menu_open = true,
                callback = showTabsArrange,
            }, icons.navbar_tabs),
            IconItem.decorate({
                text = _("Styling"),
                sub_item_table = {
                    {
                        text = _("Labels"),
                        sub_item_table = {
                            {
                                text = _("Show labels"),
                                checked_func = function() return config.navbar.show_labels == true end,
                                enabled_func = function()
                                    return config.navbar.show_labels ~= true
                                        or config.navbar.show_icons ~= false
                                end,
                                callback = function()
                                    if config.navbar.show_labels == true
                                            and config.navbar.show_icons == false then
                                        return
                                    end
                                    config.navbar.show_labels = config.navbar.show_labels ~= true
                                    save_and_reflow_navbar()
                                end,
                            },
                            {
                                text_func = function()
                                    ensure_navbar_sizes()
                                    return string.format("%s %s", _("Label size:"), tostring(config.navbar.label_size))
                                end,
                                keep_menu_open = true,
                                enabled_func = function()
                                    return config.navbar.show_labels == true
                                        or config.navbar.show_icons == false
                                end,
                                callback = function(touchmenu_instance)
                                    local SpinWidget = require("ui/widget/spinwidget")
                                    ensure_navbar_sizes()
                                    UIManager:show(SpinWidget:new{
                                        title_text = _("Navbar label size"),
                                        value = config.navbar.label_size,
                                        value_min = navbar_label_size_min,
                                        value_max = navbar_label_size_max,
                                        default_value = navbar_label_size_default,
                                        callback = function(spin)
                                            config.navbar.label_size = clamp_navbar_size(
                                                spin.value,
                                                navbar_label_size_min,
                                                navbar_label_size_max,
                                                navbar_label_size_default)
                                            save_and_reflow_navbar()
                                            if touchmenu_instance then touchmenu_instance:updateItems() end
                                        end,
                                    })
                                end,
                            },
                        },
                    },
                    {
                        text = _("Icons"),
                        sub_item_table = {
                            {
                                text = _("Show icons"),
                                checked_func = function() return config.navbar.show_icons ~= false end,
                                enabled_func = function()
                                    return config.navbar.show_icons == false
                                        or config.navbar.show_labels == true
                                end,
                                callback = function()
                                    if config.navbar.show_icons ~= false
                                            and config.navbar.show_labels ~= true then
                                        return
                                    end
                                    config.navbar.show_icons = config.navbar.show_icons == false
                                    save_and_reflow_navbar()
                                end,
                            },
                            {
                                text_func = function()
                                    ensure_navbar_sizes()
                                    return string.format("%s %s", _("Icon size:"), tostring(config.navbar.icon_size))
                                end,
                                keep_menu_open = true,
                                enabled_func = function() return config.navbar.show_icons ~= false end,
                                callback = function(touchmenu_instance)
                                    local SpinWidget = require("ui/widget/spinwidget")
                                    ensure_navbar_sizes()
                                    UIManager:show(SpinWidget:new{
                                        title_text = _("Navbar icon size"),
                                        value = config.navbar.icon_size,
                                        value_min = navbar_icon_size_min,
                                        value_max = navbar_icon_size_max,
                                        default_value = navbar_icon_size_default,
                                        callback = function(spin)
                                            config.navbar.icon_size = clamp_navbar_size(
                                                spin.value,
                                                navbar_icon_size_min,
                                                navbar_icon_size_max,
                                                navbar_icon_size_default)
                                            save_and_reflow_navbar()
                                            if touchmenu_instance then touchmenu_instance:updateItems() end
                                        end,
                                    })
                                end,
                            },
                        },
                    },
                    {
                        text = _("Active tab"),
                        sub_item_table = {
                            {
                                text = _("Underline"),
                                checked_func = function() return config.navbar.active_tab_underline == true end,
                                callback = function()
                                    config.navbar.active_tab_underline = config.navbar.active_tab_underline ~= true
                                    save_and_apply("navbar")
                                end,
                            },
                            {
                                text = _("Underline above icon"),
                                checked_func = function() return config.navbar.underline_above == true end,
                                enabled_func = function()
                                    return config.navbar.active_tab_underline == true
                                end,
                                callback = function()
                                    config.navbar.underline_above = config.navbar.underline_above ~= true
                                    save_and_apply("navbar")
                                end,
                            },
                            {
                                text = _("Colored"),
                                checked_func = function() return config.navbar.colored == true end,
                                callback = function()
                                    config.navbar.colored = config.navbar.colored ~= true
                                    save_and_apply_navbar()
                                end,
                            },
                            utils.buildColorSubMenu({
                                label        = _("Active tab color: "),
                                get          = ensure_navbar_color,
                                set          = function(r, g, b)
                                    set_navbar_color(r, g, b)
                                    save_and_apply_navbar()
                                end,
                                enabled_func = function()
                                    return config.navbar.colored == true
                                end,
                                dialog_title = _("Active tab RGB"),
                                presets = {
                                    { text = _("Blue"),  r = 0x33, g = 0x99, b = 0xFF },
                                    { text = _("Green"), r = 0x33, g = 0xAA, b = 0x55 },
                                    { text = _("Amber"), r = 0xFF, g = 0xAA, b = 0x00 },
                                    { text = _("Red"),   r = 0xDD, g = 0x33, b = 0x33 },
                                },
                            }),
                        },
                    },
                    {
                        text = _("Show top border"),
                        checked_func = function() return config.navbar.show_top_border == true end,
                        callback = function()
                            config.navbar.show_top_border = config.navbar.show_top_border ~= true
                            save_and_reflow_navbar()
                        end,
                    },
                },
            }, icons.navbar_styling),
            IconItem.decorate({
                text_func = function()
                    local current = config.navbar.default_tab or "books"
                    return _("Default tab: ") .. get_default_tab_label(current)
                end,
                keep_menu_open = true,
                sub_item_table_func = build_default_tab_items,
            }, icons.settings_home),
        },
    }, icons.settings_navbar)
end

return M
