local _ = require("gettext")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local icons = require("common/inline_icon_map")
local IconItem = require("common/ui/icon_menu_item")
local icon_utils = require("common/utils")

local Model = require("modules/menu/app_launcher/model")
local NativeMenu = require("modules/menu/app_launcher/native_menu")
local PagePlan = require("modules/menu/app_launcher/page_plan")
local PluginScan = require("modules/menu/app_launcher/plugin_scan")
local DispatcherMenu = require("common/dispatcher_menu")
local Destination = require("common/library_destination")

local M = {}
local DEFAULT_ENTRY_ICON = "lightning"
local DEFAULT_FOLDER_ICON = "folder_open"

local function suggest_icon(label, strip_zen_prefix, preferred)
    local ok_root, root = pcall(require, "common/plugin_root")
    return icon_utils.suggestIcon(
        ok_root and root or nil, label, DEFAULT_ENTRY_ICON, strip_zen_prefix, preferred)
end

local function trim(text)
    return (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.build(ctx)
    local config = ctx.config
    local save_and_apply = ctx.save_and_apply
    local cfg = Model.ensure(config)
    local build_entry_items
    local show_entries_arrange
    local sync_action_label

    local function save_app_launcher()
        Model.save(cfg)
        if ctx.apply_feature then
            ctx.apply_feature("app_launcher")
        else
            save_and_apply("app_launcher")
        end
    end

    local function show_page_order()
        local sort_items = {}
        local labels = {
            book_details = _("Book information"),
            book_switcher = _("Book switcher"),
            buttons = _("Buttons"),
        }
        for _i, kind in ipairs(PagePlan.normalizeOrder(cfg.page_order)) do
            sort_items[#sort_items + 1] = {
                text = labels[kind],
                orig_kind = kind,
            }
        end
        require("common/ui/zen_arrange_list").show{
            title = _("Order"),
            item_table = sort_items,
            callback = function()
                local order = {}
                for _i, item in ipairs(sort_items) do
                    order[#order + 1] = item.orig_kind
                end
                cfg.page_order = PagePlan.normalizeOrder(order)
                save_app_launcher()
            end,
        }
    end

    local function show_book_details_arrange()
        local labels = {
            read_time = _("Read time"),
            time_remaining = _("Time remaining"),
            pages_today = _("Pages today"),
            time_today = _("Time today"),
            pages = _("Pages"),
            progress = _("Progress bar"),
        }
        local sort_items = {}
        for _i, id in ipairs(cfg.book_details_order) do
            local item_id = id
            sort_items[#sort_items + 1] = {
                text = labels[item_id],
                orig_item = item_id,
                checked_func = function()
                    return cfg.book_details_enabled[item_id] ~= false
                end,
                callback = function()
                    cfg.book_details_enabled[item_id]
                        = cfg.book_details_enabled[item_id] == false
                    save_app_launcher()
                end,
            }
        end
        require("common/ui/zen_arrange_list").show{
            title = _("Book details"),
            item_table = sort_items,
            callback = function()
                local order = {}
                for _i, item in ipairs(sort_items) do
                    order[#order + 1] = item.orig_item
                end
                cfg.book_details_order = order
                save_app_launcher()
            end,
        }
    end

    local function is_draft_entry(entry)
        return type(entry) == "table" and type(entry._zen_draft_commit) == "function"
    end

    local function open_entry_settings(touch_menu, entry, parent)
        if not (touch_menu and type(touch_menu.updateItems) == "function" and entry) then
            return
        end
        table.insert(touch_menu.item_table_stack, touch_menu.item_table)
        touch_menu.parent_id = nil
        touch_menu.item_table = build_entry_items(entry, parent)
        touch_menu:updateItems(1)
    end

    local ok_disp, Dispatcher = pcall(require, "dispatcher")

    local function wrap_dispatch_callbacks(items, caller, on_update)
        DispatcherMenu.wrap(items, caller, on_update, "_zen_launcher_dispatch")
    end

    local ICONS
    local function get_icons()
        if ICONS then return ICONS end
        local ok_root, root = pcall(require, "common/plugin_root")
        ICONS = icon_utils.getIconPickerList(ok_root and root or nil, {
            zen_ui_light = true,
            zen_ui_update = true,
        })
        return ICONS
    end

    local function show_icon_picker(entry, touch_menu)
        require("common/ui/zen_icon_picker")(get_icons(), entry.icon, function(name)
            entry.icon = name
            if not is_draft_entry(entry) then
                save_app_launcher()
            end
            if touch_menu and touch_menu.updateItems then
                touch_menu:updateItems(1)
            end
        end)
    end

    local function action_label(entry)
        if ok_disp and entry.action and next(entry.action) then
            local text = Dispatcher:menuTextFunc(entry.action)
            if text and text ~= "" and text ~= _("Nothing") then
                return icon_utils.stripZenPrefix(text)
            end
        end
        return nil
    end

    sync_action_label = function(entry)
        if entry.type ~= "action" then return end
        local current = entry.label or ""
        if entry.label_auto == true or current == "" or current == _("Action") then
            entry.label = action_label(entry) or _("Action")
            entry.label_auto = true
        end
        if entry.icon == DEFAULT_ENTRY_ICON then
            entry.icon = suggest_icon(entry.label, true)
        end
    end

    local function prompt_label(entry, title, touch_menu)
        local InputDialog = require("ui/widget/inputdialog")
        local dialog
        dialog = InputDialog:new{
            title = title,
            input = entry.label or "",
            input_hint = entry.type == "action" and _("Leave empty to use action title") or nil,
            buttons = {{
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Set"),
                    is_enter_default = true,
                    callback = function()
                        local label = trim(dialog:getInputText())
                        if label ~= "" then
                            entry.label = label
                            if entry.type ~= "break" then entry.label_auto = false end
                            if not is_draft_entry(entry) then
                                save_app_launcher()
                            end
                        elseif entry.type == "action" then
                            entry.label_auto = true
                            sync_action_label(entry)
                            if not is_draft_entry(entry) then
                                save_app_launcher()
                            end
                        elseif entry.type == "break" then
                            entry.label = nil
                            save_app_launcher()
                        end
                        UIManager:close(dialog)
                        if touch_menu and touch_menu.updateItems then
                            touch_menu:updateItems(1)
                        end
                    end,
                },
            }},
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end

    local function insert_entry(entry, folder)
        if folder then
            folder.children = folder.children or {}
            folder.children[#folder.children + 1] = entry
        else
            cfg.entries[#cfg.entries + 1] = entry
        end
        save_app_launcher()
    end

    local function current_list(parent)
        if parent then
            if type(parent.children) ~= "table" then
                parent.children = {}
            end
            return parent.children
        end
        if type(cfg.entries) ~= "table" then
            cfg.entries = {}
        end
        return cfg.entries
    end

    local function entry_exists_in_list(list, entry)
        if not (list and entry and entry.id) then return false end
        for _i, candidate in ipairs(list) do
            if candidate.id == entry.id then
                return true
            end
        end
        return false
    end

    local function new_action_entry(label, draft)
        return {
            id = draft and nil or Model.next_id(cfg),
            type = "action",
            label = label or _("Action"),
            label_auto = true,
            icon = DEFAULT_ENTRY_ICON,
            action = {},
        }
    end

    local function add_folder(touch_menu)
        local InputDialog = require("ui/widget/inputdialog")
        local dialog
        dialog = InputDialog:new{
            title = _("New folder"),
            input = "",
            buttons = {{
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Add"),
                    is_enter_default = true,
                    callback = function()
                        local label = trim(dialog:getInputText())
                        UIManager:close(dialog)
                        if label == "" then return end
                        local entry = {
                            id = Model.next_id(cfg),
                            type = "folder",
                            label = label,
                            icon = DEFAULT_FOLDER_ICON,
                            children = {},
                        }
                        insert_entry(entry)
                        UIManager:nextTick(function()
                            open_entry_settings(touch_menu, entry, nil)
                        end)
                    end,
                },
            }},
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end

    local function add_plugin(folder, touch_menu)
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
        local show_menu_picker = require("common/ui/zen_menu_picker")
        show_menu_picker{
            title = _("Choose plugin menu"),
            items = picker_items,
            back_hold_callback = touch_menu and touch_menu.backToSettingsRoot,
            on_select = function(item)
                local plugin = item.plugin
                local entry = {
                    id = Model.next_id(cfg),
                    type = "plugin",
                    label = plugin.title,
                    icon = suggest_icon(plugin.title),
                    plugin = { key = plugin.key, method = plugin.method },
                }
                insert_entry(entry, folder)
                UIManager:nextTick(function()
                    open_entry_settings(touch_menu, entry, folder)
                end)
            end,
        }
    end

    local function add_library_folder(folder, touch_menu)
        Destination.chooseFolder(function(path)
            local entry = {
                id = Model.next_id(cfg),
                type = "folder_shortcut",
                folder = path,
                label = Destination.folderLabel(path),
                label_auto = true,
                icon = suggest_icon(Destination.folderLabel(path), nil, "folder"),
            }
            insert_entry(entry, folder)
            UIManager:nextTick(function()
                open_entry_settings(touch_menu, entry, folder)
            end)
        end)
    end

    local function add_tag(folder, touch_menu)
        Destination.chooseTag(function(tag)
            local entry = {
                id = Model.next_id(cfg),
                type = "tag",
                tag = tag,
                label = tag,
                label_auto = true,
                icon = suggest_icon(tag, nil, "tab_tags"),
            }
            insert_entry(entry, folder)
            UIManager:nextTick(function()
                open_entry_settings(touch_menu, entry, folder)
            end)
        end)
    end

    local function choose_plugin_entry(entry, touch_menu)
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
        local show_menu_picker = require("common/ui/zen_menu_picker")
        show_menu_picker{
            title = _("Choose plugin menu"),
            items = picker_items,
            back_hold_callback = touch_menu and touch_menu.backToSettingsRoot,
            on_select = function(item)
                local plugin = item.plugin
                entry.type = "plugin"
                entry.plugin = { key = plugin.key, method = plugin.method }
                entry.label = plugin.title
                save_app_launcher()
                if touch_menu and touch_menu.updateItems then
                    touch_menu:updateItems(1)
                end
            end,
        }
    end

    local function show_koreader_menu_picker(on_select, touch_menu)
        local found = NativeMenu.scan("active")
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

    local function choose_koreader_menu_entry(entry, touch_menu)
        show_koreader_menu_picker(function(item)
            entry.koreader_menu = { id = item.id, title = item.title }
            entry.label = item.title
            entry.icon = suggest_icon(item.title)
            save_app_launcher()
            if touch_menu and touch_menu.updateItems then
                touch_menu:updateItems(1)
            end
        end, touch_menu)
    end

    local function add_koreader_menu(folder, touch_menu)
        show_koreader_menu_picker(function(item)
            local entry = {
                id = Model.next_id(cfg),
                type = "koreader_menu",
                label = item.title,
                icon = suggest_icon(item.title),
                koreader_menu = { id = item.id, title = item.title },
            }
            insert_entry(entry, folder)
            UIManager:nextTick(function()
                open_entry_settings(touch_menu, entry, folder)
            end)
        end, touch_menu)
    end

    local function open_new_action_picker(folder, touch_menu)
        if not ok_disp then return end
        local entry = new_action_entry(nil, true)
        local committed = false
        local function commit()
            if committed or not (entry.action and next(entry.action)) then return end
            sync_action_label(entry)
            entry.id = Model.next_id(cfg)
            entry._zen_draft_commit = nil
            insert_entry(entry, folder)
            committed = true
        end
        entry._zen_draft_commit = commit
        open_entry_settings(touch_menu, entry, folder)
    end

    local function show_quick_setting_picker(on_select, touch_menu)
        local controls = rawget(_G, "__ZEN_UI_QUICK_SETTINGS")
        if not controls or type(controls.getItems) ~= "function" then return end
        local picker_items = controls.getItems()
        if #picker_items == 0 then return end
        require("common/ui/zen_menu_picker"){
            title = _("Choose control"),
            items = picker_items,
            back_hold_callback = touch_menu and touch_menu.backToSettingsRoot,
            on_select = on_select,
        }
    end

    local function choose_quick_setting_entry(entry, touch_menu)
        show_quick_setting_picker(function(item)
            entry.quick_setting_id = item.id
            entry.label = item.label
            entry.icon = suggest_icon(item.label, nil, item.icon)
            save_app_launcher()
            if touch_menu and touch_menu.updateItems then
                touch_menu:updateItems(1)
            end
        end, touch_menu)
    end

    local function add_quick_setting(folder, touch_menu)
        show_quick_setting_picker(function(item)
                local entry = {
                    id = Model.next_id(cfg),
                    type = "quick_setting",
                    label = item.label,
                    icon = suggest_icon(item.label, nil, item.icon),
                    quick_setting_id = item.id,
                }
                insert_entry(entry, folder)
                UIManager:nextTick(function()
                    open_entry_settings(touch_menu, entry, folder)
                end)
        end, touch_menu)
    end

    local function add_items(folder)
        return {
            IconItem.decorate({
                text = _("Add action"),
                keep_menu_open = true,
                callback = function(touch_menu)
                    open_new_action_picker(folder, touch_menu)
                end,
            }, icons.action),
            IconItem.decorate({
                text = _("Add control"),
                keep_menu_open = true,
                callback = function(touch_menu)
                    add_quick_setting(folder, touch_menu)
                end,
            }, icons.settings_quick),
            IconItem.decorate({
                text = _("Add plugin"),
                keep_menu_open = true,
                callback = function(touch_menu)
                    add_plugin(folder, touch_menu)
                end,
            }, icons.plugin),
            IconItem.decorate({
                text = _("Add KOReader menu"),
                keep_menu_open = true,
                callback = function(touch_menu)
                    add_koreader_menu(folder, touch_menu)
                end,
            }, icons.open_menu),
            IconItem.decorate({
                text = _("Open folder"),
                keep_menu_open = true,
                callback = function(touch_menu)
                    add_library_folder(folder, touch_menu)
                end,
            }, icons.settings_folders),
            IconItem.decorate({
                text = _("Specific tag"),
                keep_menu_open = true,
                callback = function(touch_menu)
                    add_tag(folder, touch_menu)
                end,
            }, icons.keywords),
        }
    end

    local function arrange_add_items(folder)
        local items = {
            IconItem.decorate({
                text = _("Action"),
                keep_menu_open = true,
                callback = function(touch_menu)
                    open_new_action_picker(folder, touch_menu)
                end,
            }, icons.action),
            IconItem.decorate({
                text = _("Control"),
                keep_menu_open = true,
                callback = function(touch_menu)
                    add_quick_setting(folder, touch_menu)
                end,
            }, icons.settings_quick),
            IconItem.decorate({
                text = _("Plugin Menu"),
                keep_menu_open = true,
                callback = function(touch_menu)
                    add_plugin(folder, touch_menu)
                end,
            }, icons.plugin),
            IconItem.decorate({
                text = _("KOReader menu"),
                keep_menu_open = true,
                callback = function(touch_menu)
                    add_koreader_menu(folder, touch_menu)
                end,
            }, icons.koreader_menu),
        }
        if not folder then
            items[#items + 1] = IconItem.decorate({
                text = _("Folder"),
                keep_menu_open = true,
                callback = add_folder,
            }, icons.new_folder)
        end
        items[#items + 1] = IconItem.decorate({
            text = _("Open folder"),
            keep_menu_open = true,
            callback = function(touch_menu)
                add_library_folder(folder, touch_menu)
            end,
        }, icons.settings_folders)
        items[#items + 1] = IconItem.decorate({
            text = _("Specific tag"),
            keep_menu_open = true,
            callback = function(touch_menu)
                add_tag(folder, touch_menu)
            end,
        }, icons.keywords)
        items[#items + 1] = IconItem.decorate({
            text = _("Row break"),
            keep_menu_open = true,
            callback = function(touch_menu)
                local entry = {
                    id = Model.next_id(cfg),
                    type = "break",
                }
                insert_entry(entry, folder)
                if touch_menu then touch_menu:backToUpperMenu() end
            end,
        }, icons.move)
        return items
    end

    local function build_action_picker(entry)
        if not ok_disp then return nil end
        local dispatch_items = {}
        local caller = {}
        Dispatcher:addSubMenu(caller, dispatch_items, entry, "action")
        wrap_dispatch_callbacks(dispatch_items, caller, function(touch_menu)
            sync_action_label(entry)
            if is_draft_entry(entry) then
                entry._zen_draft_commit()
            else
                save_app_launcher()
            end
            if touch_menu and touch_menu.updateItems then
                touch_menu:updateItems(1)
            end
        end)
        return IconItem.decorate({
            text_func = function()
                if entry.action and next(entry.action) then
                    return T(_("Action: %1"), Dispatcher:menuTextFunc(entry.action))
                end
                return _("Action: (none)")
            end,
            keep_menu_open = true,
            sub_item_table = dispatch_items,
        }, icons.action)
    end

    local function build_move_items(entry, parent)
        local items = {}
        if entry.type ~= "folder" then
            local folder_choices = {}
            for _i, candidate in ipairs(cfg.entries) do
                if candidate.type == "folder" and not (parent and candidate.id == parent.id) then
                    folder_choices[#folder_choices + 1] = candidate
                end
            end
            if parent then
                items[#items + 1] = IconItem.decorate({
                    text = _("Move out of folder"),
                    callback = function(touch_menu)
                        if Model.move_to_root(cfg.entries, entry.id) then
                            save_app_launcher()
                            if touch_menu then touch_menu:backToUpperMenu() end
                        end
                    end,
                }, icons.move)
            end
            if #folder_choices > 0 then
                items[#items + 1] = IconItem.decorate({
                    text = _("Move to folder"),
                    keep_menu_open = true,
                    callback = function(touch_menu)
                        local ButtonDialog = require("ui/widget/buttondialog")
                        local dialog
                        local buttons = {}
                        for _i, folder in ipairs(folder_choices) do
                            local folder_id = folder.id
                            buttons[#buttons + 1] = {{
                                text = folder.label,
                                callback = function()
                                    UIManager:close(dialog)
                                    if Model.move_to_folder(cfg.entries, entry.id, folder_id) then
                                        save_app_launcher()
                                        if touch_menu then touch_menu:backToUpperMenu() end
                                    end
                                end,
                            }}
                        end
                        dialog = ButtonDialog:new{
                            title = _("Move to folder"),
                            title_align = "center",
                            width_factor = 0.85,
                            buttons = buttons,
                        }
                        UIManager:show(dialog)
                    end,
                }, icons.move)
            end
        end
        return items
    end

    build_entry_items = function(entry, parent)
        local items = {}
        local function add_icon_item()
            items[#items + 1] = IconItem.decorate({
                text_func = function()
                    return T(_("Icon: %1"),
                        icon_utils.getIconDisplayName(entry.icon or DEFAULT_ENTRY_ICON))
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    show_icon_picker(entry, touch_menu)
                end,
            }, icons.icon)
        end
        local function add_label_item()
            items[#items + 1] = IconItem.decorate({
                text_func = function()
                    return T(_("Label: %1"), entry.label)
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    prompt_label(entry, _("Launcher label"), touch_menu)
                end,
            }, icons.label)
        end
        if entry.type == "action" then
            local picker = build_action_picker(entry)
            if picker then items[#items + 1] = picker end
            add_icon_item()
            add_label_item()
        elseif entry.type == "folder" then
            add_label_item()
            add_icon_item()
            items[#items + 1] = IconItem.decorate({
                text = _("Folder buttons"),
                keep_menu_open = true,
                callback = function()
                    show_entries_arrange(entry)
                end,
            }, icons.folder_open)
            local add_sub = add_items(entry)
            for _i, item in ipairs(add_sub) do
                items[#items + 1] = item
            end
        elseif entry.type == "folder_shortcut" then
            items[#items + 1] = IconItem.decorate({
                text_func = function()
                    return _("Folder") .. ": " .. Destination.folderLabel(entry.folder)
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    Destination.chooseFolder(function(path)
                        local old_label = Destination.folderLabel(entry.folder)
                        entry.folder = path
                        if entry.label_auto == true or entry.label == old_label then
                            entry.label = Destination.folderLabel(path)
                            entry.label_auto = true
                        end
                        save_app_launcher()
                        if touch_menu then touch_menu:updateItems(1) end
                    end, { path = entry.folder })
                end,
            }, icons.settings_folders)
            add_label_item()
            add_icon_item()
        elseif entry.type == "tag" then
            items[#items + 1] = IconItem.decorate({
                text_func = function()
                    return T(_("Tag: %1"), entry.tag or _("(none)"))
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    Destination.chooseTag(function(tag)
                        local old_tag = entry.tag
                        entry.tag = tag
                        if entry.label_auto == true or entry.label == old_tag then
                            entry.label = tag
                            entry.label_auto = true
                        end
                        save_app_launcher()
                        if touch_menu then touch_menu:updateItems(1) end
                    end)
                end,
            }, icons.keywords)
            add_label_item()
            add_icon_item()
        elseif entry.type == "quick_setting" then
            items[#items + 1] = IconItem.decorate({
                text_func = function()
                    return T(_("Control: %1"), entry.label or _("(none)"))
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    choose_quick_setting_entry(entry, touch_menu)
                end,
            }, icons.settings_quick)
            if entry.quick_setting_id ~= "zenfm" then
                local controls = rawget(_G, "__ZEN_UI_QUICK_SETTINGS")
                local settings_items = controls and controls.getSettingsItems
                    and controls.getSettingsItems(entry.quick_setting_id)
                if settings_items and #settings_items > 0 then
                    items[#items + 1] = IconItem.decorate({
                        text = _("Control settings"),
                        keep_menu_open = true,
                        sub_item_table = settings_items,
                    }, icons.settings_quick)
                end
            end
            add_label_item()
            add_icon_item()
        elseif entry.type == "koreader_menu" then
            items[#items + 1] = IconItem.decorate({
                text_func = function()
                    local target = entry.koreader_menu
                    return T(_("KOReader menu: %1"),
                        type(target) == "table" and target.title or entry.label or _("(none)"))
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    choose_koreader_menu_entry(entry, touch_menu)
                end,
            }, icons.koreader_menu)
            add_label_item()
            add_icon_item()
        elseif entry.type == "break" then
            items[#items + 1] = IconItem.decorate({
                text_func = function()
                    local title = type(entry.label) == "string" and entry.label:match("%S")
                        and entry.label or _("(none)")
                    return _("Title") .. ": " .. title
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    prompt_label(entry, _("Title"), touch_menu)
                end,
            }, icons.label)
        elseif entry.type ~= "break" then
            items[#items + 1] = IconItem.decorate({
                text_func = function()
                    return T(_("Plugin: %1"), entry.label or _("(none)"))
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    choose_plugin_entry(entry, touch_menu)
                end,
            }, icons.plugin)
            add_label_item()
            add_icon_item()
        end
        if not is_draft_entry(entry) then
            local move_items = build_move_items(entry, parent)
            for _i, item in ipairs(move_items) do
                items[#items + 1] = item
            end
        end
        items[#items + 1] = IconItem.decorate({
            text = _("Delete"),
            separator = true,
            callback = function(touch_menu)
                if is_draft_entry(entry) then
                    if touch_menu then touch_menu:backToUpperMenu() end
                    return
                end
                local ConfirmBox = require("ui/widget/confirmbox")
                local function remove()
                    Model.remove_by_id(cfg.entries, entry.id)
                    save_app_launcher()
                    if touch_menu then touch_menu:backToUpperMenu() end
                end
                UIManager:show(ConfirmBox:new{
                    text = entry.type == "folder" and entry.children and #entry.children > 0
                            and _("Delete this folder and its buttons?")
                        or entry.type == "break" and _("Delete this row break?")
                        or _("Delete this button?"),
                    ok_text = _("Delete"),
                    ok_callback = remove,
                })
            end,
        }, icons.delete)
        return items
    end

    show_entries_arrange = function(parent)
        local list = current_list(parent)
        local ZenArrangeList = require("common/ui/zen_arrange_list")
        local sort_items
        local function build_sort_items()
            local items = {}
            list = current_list(parent)
            for _i, entry in ipairs(list) do
                items[#items + 1] = {
                    text_func = function()
                        return Model.display_label(entry)
                    end,
                    orig_entry = entry,
                    sub_title = Model.display_label(entry),
                    sub_item_table_func = function()
                        return build_entry_items(entry, parent)
                    end,
                    dim = entry.enabled == false,
                    checked_func = function()
                        return entry.enabled ~= false
                    end,
                    callback = function()
                        entry.enabled = entry.enabled == false and true or false
                        save_app_launcher()
                    end,
                }
            end
            sort_items = items
            return items
        end
        sort_items = build_sort_items()
        ZenArrangeList.show{
            title = parent and parent.label or _("Buttons"),
            item_table = sort_items,
            add_title = _("Add"),
            add_item_table = arrange_add_items(parent),
            open_add_on_show = #sort_items == 0,
            callback = function()
                list = current_list(parent)
                local reordered = {}
                local reordered_ids = {}
                for _i, item in ipairs(sort_items) do
                    if entry_exists_in_list(list, item.orig_entry) then
                        reordered[#reordered + 1] = item.orig_entry
                        reordered_ids[item.orig_entry.id] = true
                    end
                end
                for _i, entry in ipairs(list) do
                    if entry.id and not reordered_ids[entry.id] then
                        reordered[#reordered + 1] = entry
                    end
                end
                if parent then
                    parent.children = reordered
                else
                    cfg.entries = reordered
                end
                save_app_launcher()
            end,
            refresh_func = build_sort_items,
        }
    end

    local root_items = {
        {
            text = _("Enable"),
            checked_func = function()
                return config.features.app_launcher == true
            end,
            callback = function()
                config.features.app_launcher = config.features.app_launcher ~= true
                save_and_apply("app_launcher")
            end,
        },
        {
            text = _("Buttons") .. " \u{25B8}",
            separator = true,
            keep_menu_open = true,
            _zen_launcher_buttons = true,
            callback = function()
                show_entries_arrange(nil)
            end,
        },
        {
            text = _("Book switcher"),
            checked_func = function()
                return cfg.show_book_switcher == true
            end,
            checkmark_callback = function()
                cfg.show_book_switcher = cfg.show_book_switcher ~= true
                save_app_launcher()
            end,
            sub_item_table = {
                {
                    text = _("Only show while reading"),
                    enabled_func = function()
                        return cfg.show_book_switcher == true
                    end,
                    checked_func = function()
                        return cfg.book_switcher_reader_only == true
                    end,
                    callback = function()
                        cfg.book_switcher_reader_only = cfg.book_switcher_reader_only ~= true
                        save_app_launcher()
                    end,
                },
            },
        },
        {
            text = _("Book details"),
            checked_func = function()
                return cfg.show_book_details == true
            end,
            checkmark_callback = function()
                cfg.show_book_details = cfg.show_book_details ~= true
                save_app_launcher()
            end,
            sub_item_table = {
                {
                    text = _("Items") .. " \u{25B8}",
                    keep_menu_open = true,
                    callback = show_book_details_arrange,
                },
            },
        },
        {
            text = _("Show labels"),
            checked_func = function()
                return cfg.show_labels ~= false
            end,
            callback = function(touch_menu)
                cfg.show_labels = cfg.show_labels == false
                save_app_launcher()
                if touch_menu and touch_menu.updateItems then
                    touch_menu:updateItems(1)
                end
            end,
        },
        {
            text = _("Order") .. " \u{25B8}",
            keep_menu_open = true,
            callback = show_page_order,
        },
        {
            text = _("Open menu to Launcher"),
            checked_func = function()
                return cfg.open_first == true
            end,
            callback = function(touch_menu)
                cfg.open_first = cfg.open_first ~= true
                save_app_launcher()
                if touch_menu and touch_menu.updateItems then
                    touch_menu:updateItems(1)
                end
            end,
        },
        {
            text = _("Hide reader actions in library"),
            checked_func = function()
                return cfg.hide_reader_actions_in_library == true
            end,
            callback = function(touch_menu)
                cfg.hide_reader_actions_in_library = cfg.hide_reader_actions_in_library ~= true
                save_app_launcher()
                if touch_menu and touch_menu.updateItems then
                    touch_menu:updateItems(1)
                end
            end,
        },
    }
    IconItem.decorate(root_items[1], icons.enable)
    IconItem.decorate(root_items[2], icons.action)
    IconItem.decorate(root_items[3], icons.book_switcher)
    IconItem.decorate(root_items[4], icons.details)
    IconItem.decorate(root_items[5], icons.keywords)
    IconItem.decorate(root_items[6], icons.sort)
    IconItem.decorate(root_items[7], icons.open_menu)
    IconItem.decorate(root_items[8], icons.hide_reader_actions)

    local function open_entry_settings_from_search(entry, parent)
        local items = build_entry_items(entry, parent)
        if type(items) ~= "table" or #items == 0 then
            show_entries_arrange(parent)
            return true
        end
        require("common/ui/zen_arrange_list").show{
            title = Model.display_label(entry),
            item_table = items,
            hide_footer_cancel = true,
        }
        return true
    end

    local function arrange_search_items()
        local items = {}
        local function add_entries(entries, parent, breadcrumb)
            for _i, entry in ipairs(entries or {}) do
                local label = Model.display_label(entry)
                if type(label) == "string" and label ~= "" then
                    local search_entry = entry
                    local search_parent = parent
                    items[#items + 1] = {
                        text = label,
                        _zen_search_breadcrumb = breadcrumb,
                        _zen_search_open = function()
                            return open_entry_settings_from_search(search_entry, search_parent)
                        end,
                    }
                    if entry.type == "folder" then
                        add_entries(entry.children, entry, breadcrumb .. " › " .. label)
                    end
                end
            end
        end
        add_entries(cfg.entries, nil, _("Launcher"))
        return items
    end

    return {
        text = _("Launcher"),
        _zen_search_items_func = arrange_search_items,
        sub_item_table = root_items,
    }
end

return M
