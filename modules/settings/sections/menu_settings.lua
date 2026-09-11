-- settings/sections/menu.lua
-- Touch menu settings items for ZenOS (Quick Settings panel).
-- Receives ctx: { plugin, config, save_and_apply }

local _ = require("gettext")
local T = require("ffi/util").template
local Device = require("device")
local UIManager = require("ui/uimanager")
local defaults = require("config/defaults")
local icons = require("common/inline_icon_map")
local IconItem = require("common/ui/icon_menu_item")
local NativeMenu = require("modules/menu/app_launcher/native_menu")
local PluginScan = require("modules/menu/app_launcher/plugin_scan")
local DispatcherMenu = require("common/dispatcher_menu")
local icon_utils = require("common/utils")
local Destination = require("common/library_destination")
local Bluetooth = require("common/bluetooth")

local M = {}

local function suggest_icon(label, strip_zen_prefix, preferred)
    local ok_root, root = pcall(require, "common/plugin_root")
    return icon_utils.suggestIcon(
        ok_root and root or nil, label, "lightning", strip_zen_prefix, preferred)
end

function M.build(ctx)
    local config = ctx.config
    local zen_plugin = ctx.plugin
    local save_and_apply = ctx.save_and_apply

    local function save_and_apply_quick_settings() save_and_apply("quick_settings") end

    local function is_draft_button(cb)
        return type(cb) == "table" and type(cb._zen_draft_commit) == "function"
    end

    local function hasPlugin(name)
        local meta = type(config) == "table" and config._meta
        local installed = type(meta) == "table" and meta.installed_plugins
        return type(installed) ~= "table" or installed[name:lower()] == true
    end

    local function hasAnyPlugin(slots)
        for _i, slot in ipairs(slots) do
            if hasPlugin(slot) then return true end
        end
        return false
    end

    local filebrowser_slots = { "filebrowser", "FilebrowserPlus", "filebrowserplus" }

    local function getAutorotateLabel()
        local label = config.quick_settings.gyro_label
        return type(label) == "string" and label ~= "" and label or _("Autorotate")
    end

    local function getAutorotateIcon()
        local icon = config.quick_settings.gyro_icon
        return type(icon) == "string" and icon ~= "" and icon or "quick_rotate"
    end

    local quick_button_items = {
        { key = "wifi",    text = _("Wi-Fi")       },
        { key = "bluetooth", text = _("Bluetooth"), detect = Bluetooth.isAvailable },
        { key = "night",   text = _("Night mode")  },
        { key = "frontlight", text = _("Frontlight"), detect = function() return Device:hasFrontlight() end },
        { key = "gyro", text = getAutorotateLabel(), detect = function() return Device:hasGSensor() end },
        { key = "zen",     text = _("Zen mode")    },
        { key = "lockdown",text = _("Lockdown")    },
        { key = "incognito", text = _("Incognito")  },
        { key = "rotate",  text = _("Rotate")      },
        { key = "usb",     text = _("USB")         },
        { key = "search",  text = _("File search") },
        { key = "restart", text = _("Restart")     },
        { key = "exit",    text = _("Exit")        },
        { key = "sleep",   text = _("Sleep")       },
        -- Optional: only shown when the plugin/feature is detected.
        { key = "quickrss",       text = _("QuickRSS"),        detect = function() local ok = pcall(require, "modules/ui/feed_view"); return ok end },
        { key = "cloud",          text = _("Cloud storage") },
        { key = "zlibrary",       text = _("Z-Library"),       detect = function() return hasPlugin("zlibrary") end },
        { key = "calibre",        text = _("Calibre"),         detect = function() return hasPlugin("calibre") end },
        { key = "calibre_search", text = _("Calibre Search"),  detect = function() return hasPlugin("calibre") end },
        { key = "notion",         text = _("Notion"),          detect = function() return hasPlugin("NotionSync") end },
        { key = "streak",         text = _("Streak"),          detect = function() return hasPlugin("readingstreak") end },
        { key = "opds",           text = _("OPDS"),            detect = function() return hasPlugin("opds") end },
        { key = "localsend",      text = _("LocalSend"),       detect = function() return hasPlugin("localsend") end },
        { key = "tailscale",      text = _("Tailscale"),       detect = function() return hasPlugin("tailscale") end },
        { key = "zenfm",          text = _("ZenFM"),           detect = function() return hasPlugin("zenfm") end },
        { key = "filebrowser",    text = _("Filebrowser"),     detect = function() return hasAnyPlugin(filebrowser_slots) end },
        { key = "puzzle",         text = _("Slide Puzzle"),    detect = function() return hasPlugin("slidepuzzle") end },
        { key = "crossword",      text = _("Crossword"),       detect = function() return hasPlugin("crossword") end },
        { key = "connections",    text = _("Connections"),      detect = function() return hasPlugin("nytconnections") end },
        { key = "chess",          text = _("Chess"),            detect = function() return hasPlugin("kochess") end },
        { key = "casualchess",    text = _("Casual Chess"),     detect = function() return hasPlugin("casualkochess") end },
        { key = "stats_progress", text = _("Stats: Progress"), detect = function() return hasPlugin("statistics") end },
        { key = "stats_calendar", text = _("Stats: Calendar"), detect = function() return hasPlugin("statistics") end },
        { key = "battery_stats",  text = _("Battery Stats"),   detect = function() return hasPlugin("batterystat") end },
        { key = "kosync",         text = _("Sync") },
        { key = "screenshot",     text = _("Screenshot") },
    }

    -- Remove any button whose plugin/feature is not detected.
    do
        local filtered = {}
        for _i, item in ipairs(quick_button_items) do
            if not item.detect or item.detect() then
                filtered[#filtered + 1] = item
            end
        end
        quick_button_items = filtered
    end

    table.sort(quick_button_items, function(a, b) return a.text < b.text end)

    local quick_button_label_by_id = {}
    for _i, quick_item in ipairs(quick_button_items) do
        quick_button_label_by_id[quick_item.key] = quick_item.text
    end
    local quick_button_custom_by_id = {}

    local quick_buttons_max = 9

    local rotate_action_options = {
        { key = "cycle", text = _("Cycle") },
        { key = "90",    text = _("90°")   },
        { key = "180",   text = _("180°")  },
        { key = "270",   text = _("270°")  },
    }

    local rotate_action_labels = {}
    for _i, item in ipairs(rotate_action_options) do
        rotate_action_labels[item.key] = item.text
    end

    local function getRotateAction()
        local action = config.quick_settings.rotate_action
        return rotate_action_labels[action] and action or "cycle"
    end

    local function getRotateActionLabel()
        return rotate_action_labels[getRotateAction()]
    end

    local function getScreenshotTimerSeconds()
        local seconds = tonumber(config.quick_settings.screenshot_timer_seconds) or 3
        return math.max(0, math.min(10, math.floor(seconds)))
    end

    -- only count buttons that are actually toggleable in the UI
    local quick_button_key_set = {}
    for _i, item in ipairs(quick_button_items) do
        quick_button_key_set[item.key] = true
    end

    -- Register custom buttons so they appear in arrange widget and count toward limit
    local ok_disp, Dispatcher = pcall(require, "dispatcher")
    if type(config.quick_settings.custom_buttons) == "table" then
        for _i, cb in ipairs(config.quick_settings.custom_buttons) do
            if type(cb.id) == "string" then
                quick_button_custom_by_id[cb.id] = cb
                local lbl
                if cb.label and cb.label ~= "" then
                    lbl = cb.label
                elseif cb.type == "plugin" then
                    lbl = cb.plugin_title
                elseif cb.type == "koreader_menu" then
                    lbl = cb.koreader_menu and cb.koreader_menu.title
                elseif cb.type == "folder" then
                    lbl = Destination.folderLabel(cb.folder)
                elseif cb.type == "tag" then
                    lbl = cb.tag
                elseif ok_disp and cb.action and next(cb.action) then
                    lbl = icon_utils.stripZenPrefix(Dispatcher:menuTextFunc(cb.action))
                end
                quick_button_label_by_id[cb.id] = lbl or _("Custom")
                quick_button_key_set[cb.id] = true
            end
        end
    end

    local function countEnabledButtons()
        local count = 0
        for _i, id in ipairs(config.quick_settings.button_order) do
            if config.quick_settings.show_buttons[id] == true and quick_button_key_set[id] then
                count = count + 1
            end
        end
        return count
    end

    local function buildRotateButtonSubItems()
        local items = {}
        for _i, item in ipairs(rotate_action_options) do
            local key = item.key
            table.insert(items, {
                text = item.text,
                radio = true,
                checked_func = function()
                    return getRotateAction() == key
                end,
                callback = function()
                    config.quick_settings.rotate_action = key
                    save_and_apply_quick_settings()
                end,
            })
        end
        return items
    end

    local function buildTailscaleButtonSubItems()
        return {{
            text = _("Toggle Wi-Fi with Tailscale"),
            checked_func = function()
                return config.quick_settings.tailscale_toggle_wifi == true
            end,
            callback = function()
                config.quick_settings.tailscale_toggle_wifi =
                    config.quick_settings.tailscale_toggle_wifi ~= true
                save_and_apply_quick_settings()
            end,
        }}
    end

    local function buildScreenshotButtonSubItems()
        return {
            {
                text_func = function()
                    return T(_("Timer: %1 s"), getScreenshotTimerSeconds())
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    local SpinWidget = require("ui/widget/spinwidget")
                    UIManager:show(SpinWidget:new{
                        title_text = _("Screenshot timer"),
                        value = getScreenshotTimerSeconds(),
                        value_min = 0,
                        value_max = 10,
                        default_value = 3,
                        callback = function(spin)
                            config.quick_settings.screenshot_timer_seconds = spin.value
                            save_and_apply_quick_settings()
                            if touch_menu and touch_menu.updateItems then touch_menu:updateItems() end
                        end,
                    })
                end,
            },
        }
    end

    local function toggleQuickButton(id)
        if config.quick_settings.show_buttons[id] == true then
            config.quick_settings.show_buttons[id] = false
        else
            if countEnabledButtons() >= quick_buttons_max then
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{
                    text = _("Maximum 9 buttons allowed"),
                })
                return false
            end
            config.quick_settings.show_buttons[id] = true
        end
        save_and_apply_quick_settings()
        return true
    end

    local build_cb_sub_items
    local build_control_sub_items
    local get_cb_label
    local sync_cb_action_label

    local function ensureButtonOrder(id)
        for _i, ordered_id in ipairs(config.quick_settings.button_order) do
            if ordered_id == id then return end
        end
        table.insert(config.quick_settings.button_order, id)
    end

    local function wrap_dispatch_callbacks(items, caller, on_update)
        DispatcherMenu.wrap(items, caller, on_update, "_zen_qs_dispatch")
    end

    local function commitDestinationButton(cb, touch_menu)
        local cbs = config.quick_settings.custom_buttons
        if type(cbs) ~= "table" then
            config.quick_settings.custom_buttons = {}
            cbs = config.quick_settings.custom_buttons
        end
        config.quick_settings.next_custom_id =
            (config.quick_settings.next_custom_id or 0) + 1
        cb.id = "cb_" .. config.quick_settings.next_custom_id
        table.insert(cbs, cb)
        quick_button_custom_by_id[cb.id] = cb
        quick_button_label_by_id[cb.id] = get_cb_label(cb)
        quick_button_key_set[cb.id] = true
        config.quick_settings.show_buttons[cb.id] = countEnabledButtons() < quick_buttons_max
        ensureButtonOrder(cb.id)
        save_and_apply_quick_settings()
        if touch_menu and build_cb_sub_items then
            table.insert(touch_menu.item_table_stack, touch_menu.item_table)
            touch_menu.parent_id = nil
            touch_menu.item_table = build_cb_sub_items(cb)
            touch_menu:updateItems(1)
        end
    end

    local function addFolderButton(touch_menu)
        Destination.chooseFolder(function(path)
            local label = Destination.folderLabel(path)
            commitDestinationButton({
                type = "folder",
                folder = path,
                label = label,
                label_auto = true,
                icon = suggest_icon(label, nil, "folder"),
            }, touch_menu)
        end)
    end

    local function addTagButton(touch_menu)
        Destination.chooseTag(function(tag)
            commitDestinationButton({
                type = "tag",
                tag = tag,
                label = tag,
                label_auto = true,
                icon = suggest_icon(tag, nil, "tab_tags"),
            }, touch_menu)
        end)
    end

    local function addActionButton(touch_menu)
        if not ok_disp then return end
        local cbs = config.quick_settings.custom_buttons
        if type(cbs) ~= "table" then
            config.quick_settings.custom_buttons = {}
            cbs = config.quick_settings.custom_buttons
        end
        local taken = {}
        for _i, b in ipairs(cbs) do
            local lbl = (b.label and b.label ~= "") and b.label or _("Custom")
            taken[lbl] = true
        end
        local default_label
        if taken[_("Custom")] then
            local n = 2
            while taken[_("Custom") .. " " .. n] do n = n + 1 end
            default_label = _("Custom") .. " " .. n
        end
        local new_cb = {
            type   = "action",
            label  = default_label,
            label_auto = true,
            icon   = "lightning",
            action = {},
        }
        local committed = false
        local function commit()
            if committed or not (new_cb.action and next(new_cb.action)) then return end
            config.quick_settings.next_custom_id =
                (config.quick_settings.next_custom_id or 0) + 1
            new_cb.id = "cb_" .. config.quick_settings.next_custom_id
            new_cb._zen_draft_commit = nil
            table.insert(cbs, new_cb)
            quick_button_custom_by_id[new_cb.id] = new_cb
            quick_button_label_by_id[new_cb.id] = get_cb_label(new_cb)
            quick_button_key_set[new_cb.id] = true
            config.quick_settings.show_buttons[new_cb.id] = countEnabledButtons() < quick_buttons_max
            ensureButtonOrder(new_cb.id)
            save_and_apply_quick_settings()
            committed = true
        end
        new_cb._zen_draft_commit = commit
        if touch_menu then
            table.insert(touch_menu.item_table_stack, touch_menu.item_table)
            touch_menu.parent_id = nil
            touch_menu.item_table = build_cb_sub_items(new_cb)
            touch_menu:updateItems(1)
        end
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
        local show_menu_picker = require("common/ui/zen_menu_picker")
        show_menu_picker{
            title = _("Choose plugin menu"),
            items = picker_items,
            on_select = on_select,
            back_hold_callback = touch_menu and touch_menu.backToSettingsRoot,
        }
    end

    local function showKoreaderMenuPicker(on_select, touch_menu)
        local found = NativeMenu.scan("active")
        if #found == 0 then
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{ text = _("No KOReader submenus found") })
            return
        end
        require("common/ui/zen_menu_picker"){
            title = _("Choose KOReader menu"),
            items = found,
            on_select = on_select,
            back_hold_callback = touch_menu and touch_menu.backToSettingsRoot,
        }
    end

    local function addControlButton(touch_menu)
        local selected = {}
        for _i, id in ipairs(config.quick_settings.button_order) do
            selected[id] = true
        end
        local picker_items = {}
        for _i, item in ipairs(quick_button_items) do
            if not selected[item.key] then
                picker_items[#picker_items + 1] = { id = item.key, text = item.text }
            end
        end
        if #picker_items == 0 then return end
        require("common/ui/zen_menu_picker"){
            title = _("Choose control"),
            items = picker_items,
            back_hold_callback = touch_menu and touch_menu.backToSettingsRoot,
            on_select = function(item)
                ensureButtonOrder(item.id)
                config.quick_settings.show_buttons[item.id] = countEnabledButtons() < quick_buttons_max
                save_and_apply_quick_settings()
                if touch_menu and touch_menu.backToUpperMenu then
                    touch_menu:backToUpperMenu()
                end
            end,
        }
    end

    local function choosePluginButton(cb, touch_menu, open_settings)
        showPluginPicker(function(item)
            local plugin = item.plugin
            if not plugin then return end
            cb.type = "plugin"
            cb.plugin_title = plugin.title
            cb.plugin = { key = plugin.key, method = plugin.method }
            if not cb.label or cb.label == "" or cb.label == _("Plugin") then
                cb.label = plugin.title
            end
            quick_button_label_by_id[cb.id] = get_cb_label(cb)
            save_and_apply_quick_settings()
            if touch_menu and build_cb_sub_items and open_settings then
                local sub_items = build_cb_sub_items(cb)
                if #sub_items > 0 then
                    table.insert(touch_menu.item_table_stack, touch_menu.item_table)
                    touch_menu.parent_id = nil
                    touch_menu.item_table = sub_items
                    touch_menu:updateItems(1)
                end
            elseif touch_menu and touch_menu.updateItems then
                touch_menu:updateItems(1)
            end
        end, touch_menu)
    end

    local function addPluginButton(touch_menu)
        showPluginPicker(function(item)
            local plugin = item.plugin
            if not plugin then return end
            local cbs = config.quick_settings.custom_buttons
            if type(cbs) ~= "table" then
                config.quick_settings.custom_buttons = {}
                cbs = config.quick_settings.custom_buttons
            end
            config.quick_settings.next_custom_id =
                (config.quick_settings.next_custom_id or 0) + 1
            local new_cb = {
                id           = "cb_" .. config.quick_settings.next_custom_id,
                type         = "plugin",
                label        = plugin.title,
                plugin_title = plugin.title,
                icon         = suggest_icon(plugin.title),
                plugin       = { key = plugin.key, method = plugin.method },
            }
            table.insert(cbs, new_cb)
            quick_button_custom_by_id[new_cb.id] = new_cb
            quick_button_label_by_id[new_cb.id] = get_cb_label(new_cb)
            quick_button_key_set[new_cb.id] = true
            config.quick_settings.show_buttons[new_cb.id] = countEnabledButtons() < quick_buttons_max
            ensureButtonOrder(new_cb.id)
            save_and_apply_quick_settings()
            if touch_menu and build_cb_sub_items then
                local sub_items = build_cb_sub_items(new_cb)
                if #sub_items > 0 then
                    table.insert(touch_menu.item_table_stack, touch_menu.item_table)
                    touch_menu.parent_id = nil
                    touch_menu.item_table = sub_items
                    touch_menu:updateItems(1)
                end
            end
        end, touch_menu)
    end

    local function chooseKoreaderMenuButton(cb, touch_menu, open_settings)
        showKoreaderMenuPicker(function(item)
            cb.type = "koreader_menu"
            cb.koreader_menu = { id = item.id, title = item.title }
            if not cb.label or cb.label == "" or cb.label == _("KOReader menu") then
                cb.label = item.title
            end
            cb.icon = suggest_icon(item.title)
            quick_button_label_by_id[cb.id] = get_cb_label(cb)
            save_and_apply_quick_settings()
            if touch_menu and build_cb_sub_items and open_settings then
                local sub_items = build_cb_sub_items(cb)
                if #sub_items > 0 then
                    table.insert(touch_menu.item_table_stack, touch_menu.item_table)
                    touch_menu.parent_id = nil
                    touch_menu.item_table = sub_items
                    touch_menu:updateItems(1)
                end
            elseif touch_menu and touch_menu.updateItems then
                touch_menu:updateItems(1)
            end
        end, touch_menu)
    end

    local function addKoreaderMenuButton(touch_menu)
        showKoreaderMenuPicker(function(item)
            local cbs = config.quick_settings.custom_buttons
            if type(cbs) ~= "table" then
                config.quick_settings.custom_buttons = {}
                cbs = config.quick_settings.custom_buttons
            end
            config.quick_settings.next_custom_id =
                (config.quick_settings.next_custom_id or 0) + 1
            local new_cb = {
                id = "cb_" .. config.quick_settings.next_custom_id,
                type = "koreader_menu",
                label = item.title,
                icon = suggest_icon(item.title),
                koreader_menu = { id = item.id, title = item.title },
            }
            table.insert(cbs, new_cb)
            quick_button_custom_by_id[new_cb.id] = new_cb
            quick_button_label_by_id[new_cb.id] = get_cb_label(new_cb)
            quick_button_key_set[new_cb.id] = true
            config.quick_settings.show_buttons[new_cb.id] = countEnabledButtons() < quick_buttons_max
            ensureButtonOrder(new_cb.id)
            save_and_apply_quick_settings()
            if touch_menu and build_cb_sub_items then
                local sub_items = build_cb_sub_items(new_cb)
                if #sub_items > 0 then
                    table.insert(touch_menu.item_table_stack, touch_menu.item_table)
                    touch_menu.parent_id = nil
                    touch_menu.item_table = sub_items
                    touch_menu:updateItems(1)
                end
            end
        end, touch_menu)
    end

    local function showButtonsArrange()
        local ZenArrangeList = require("common/ui/zen_arrange_list")
        local sort_items
        local function shouldDimButton(id)
            return config.quick_settings.show_buttons[id] ~= true
                and countEnabledButtons() >= quick_buttons_max
        end
        local function updateDimStates()
            for _i, sort_item in ipairs(sort_items) do
                sort_item.dim = shouldDimButton(sort_item.orig_item)
            end
        end
        local function build_sort_items()
            local items = {}
            for _i, id in ipairs(config.quick_settings.button_order) do
                local label = quick_button_label_by_id[id]
                if label then
                    local item = {
                        text = label,
                        orig_item = id,
                        dim = shouldDimButton(id),
                        checked_func = function()
                            return config.quick_settings.show_buttons[id] == true
                        end,
                        callback = function()
                            if toggleQuickButton(id) then
                                updateDimStates()
                            end
                        end,
                    }
                    if id == "gyro" then
                        item.text_func = getAutorotateLabel
                        item.sub_title = getAutorotateLabel()
                        item.sub_item_table_func = function()
                            return build_control_sub_items(id)
                        end
                    elseif id == "rotate" then
                        item.text_func = function()
                            return T(_("Rotate: %1"), getRotateActionLabel()) .. " \u{25B8}"
                        end
                        item.sub_title = _("Rotate")
                        item.sub_item_table_func = function()
                            return build_control_sub_items(id)
                        end
                    elseif id == "tailscale" then
                        item.text_func = function()
                            return _("Tailscale") .. " \u{25B8}"
                        end
                        item.sub_title = _("Tailscale")
                        item.sub_item_table_func = function()
                            return build_control_sub_items(id)
                        end
                    elseif id == "screenshot" then
                        item.text_func = function()
                            return T(_("Screenshot: %1 s"), getScreenshotTimerSeconds()) .. " \u{25B8}"
                        end
                        item.sub_title = _("Screenshot")
                        item.sub_item_table_func = function()
                            return build_control_sub_items(id)
                        end
                    elseif quick_button_custom_by_id[id] then
                        local cb = quick_button_custom_by_id[id]
                        item.text_func = function()
                            return get_cb_label(cb)
                        end
                        item.sub_title = get_cb_label(cb)
                        item.sub_item_table_func = function()
                            return build_cb_sub_items(cb)
                        end
                    else
                        item.sub_title = label
                        item.sub_item_table_func = function()
                            return build_control_sub_items(id)
                        end
                    end
                    table.insert(items, item)
                end
            end
            sort_items = items
            return items
        end
        sort_items = build_sort_items()
        ZenArrangeList.show{
            title = _("Buttons"),
            item_table = sort_items,
            add_title = _("Add"),
            hide_footer_cancel = true,
            add_item_table = {
                IconItem.decorate({
                    text = _("Control"),
                    keep_menu_open = true,
                    callback = addControlButton,
                }, icons.settings_quick),
                IconItem.decorate({
                    text = _("Action"),
                    keep_menu_open = true,
                    callback = addActionButton,
                }, icons.action),
                IconItem.decorate({
                    text = _("Folder"),
                    keep_menu_open = true,
                    callback = addFolderButton,
                }, icons.settings_folders),
                IconItem.decorate({
                    text = _("Specific tag"),
                    keep_menu_open = true,
                    callback = addTagButton,
                }, icons.keywords),
                IconItem.decorate({
                    text = _("Plugin Menu"),
                    keep_menu_open = true,
                    callback = addPluginButton,
                }, icons.plugin),
                IconItem.decorate({
                    text = _("KOReader menu"),
                    keep_menu_open = true,
                    callback = addKoreaderMenuButton,
                }, icons.koreader_menu),
            },
            callback = function()
                -- Replace the table to avoid leaving stale trailing entries
                local new_order = {}
                local in_sort = {}
                for _i, item in ipairs(sort_items) do
                    table.insert(new_order, item.orig_item)
                    in_sort[item.orig_item] = true
                end
                -- Preserve any orphaned entries not shown in the sort widget
                for _i, id in ipairs(config.quick_settings.button_order) do
                    if not in_sort[id] then
                        table.insert(new_order, id)
                    end
                end
                config.quick_settings.button_order = new_order
                save_and_apply_quick_settings()
            end,
            refresh_func = build_sort_items,
        }
    end

    -- Icon list: plugin icons + KOReader user/built-in icons.
    local CUSTOM_BUTTON_ICONS
    local function getCustomButtonIcons()
        if CUSTOM_BUTTON_ICONS then return CUSTOM_BUTTON_ICONS end
        local ok_root, root = pcall(require, "common/plugin_root")
        local excluded = { zen_ui_light = true, zen_ui_update = true }
        CUSTOM_BUTTON_ICONS = icon_utils.getIconPickerList(ok_root and root or nil, excluded)
        return CUSTOM_BUTTON_ICONS
    end

    local _icon_picker = require("common/ui/zen_icon_picker")
    local function showIconPickerDialog(cb, on_select)
        _icon_picker(getCustomButtonIcons(), cb.icon, on_select)
    end

    get_cb_label = function(cb)
        if cb.label and cb.label ~= "" then return cb.label end
        if cb.type == "plugin" then
            return cb.plugin_title or _("Plugin")
        end
        if cb.type == "folder" then
            return Destination.folderLabel(cb.folder)
        end
        if cb.type == "tag" then
            return cb.tag or _("Tag")
        end
        if cb.type == "koreader_menu" then
            return cb.koreader_menu and cb.koreader_menu.title or _("KOReader menu")
        end
        if ok_disp and cb.action and next(cb.action) then
            local t = Dispatcher:menuTextFunc(cb.action)
            if t ~= _("Nothing") then return icon_utils.stripZenPrefix(t) end
        end
        return _("Custom")
    end

    sync_cb_action_label = function(cb)
        if cb.type ~= "action" then return end
        local current = cb.label or ""
        local custom_prefix = _("Custom") .. " "
        local is_legacy_auto_label = current == _("Custom")
            or current == _("Action")
            or (current:sub(1, #custom_prefix) == custom_prefix
                and tonumber(current:sub(#custom_prefix + 1)) ~= nil)
        if cb.label_auto == true or current == "" or is_legacy_auto_label then
            cb.label = get_cb_label({
                type = cb.type,
                action = cb.action,
                label = nil,
            })
            cb.label_auto = true
        end
        if cb.icon == "lightning" then
            cb.icon = suggest_icon(cb.label, true)
        end
    end

    build_cb_sub_items = function(cb)
        local items = {}

        if cb.type == "plugin" then
            table.insert(items, IconItem.decorate({
                text_func = function()
                    return T(_("Plugin: %1"), cb.plugin_title or cb.label or _("(none)"))
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    choosePluginButton(cb, touch_menu, false)
                end,
            }, icons.plugin))
        elseif cb.type == "koreader_menu" then
            table.insert(items, IconItem.decorate({
                text_func = function()
                    local target = cb.koreader_menu
                    return T(_("KOReader menu: %1"),
                        type(target) == "table" and target.title or cb.label or _("(none)"))
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    chooseKoreaderMenuButton(cb, touch_menu, false)
                end,
            }, icons.open_menu))
        elseif cb.type == "folder" then
            table.insert(items, IconItem.decorate({
                text_func = function()
                    return _("Folder") .. ": " .. Destination.folderLabel(cb.folder)
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    Destination.chooseFolder(function(path)
                        local old_label = Destination.folderLabel(cb.folder)
                        cb.folder = path
                        if cb.label_auto == true or not cb.label or cb.label == ""
                                or cb.label == old_label then
                            cb.label = Destination.folderLabel(path)
                            cb.label_auto = true
                        end
                        quick_button_label_by_id[cb.id] = get_cb_label(cb)
                        save_and_apply_quick_settings()
                        if touch_menu then touch_menu:updateItems(1) end
                    end, { path = cb.folder })
                end,
            }, icons.settings_folders))
        elseif cb.type == "tag" then
            table.insert(items, IconItem.decorate({
                text_func = function()
                    return T(_("Tag: %1"), cb.tag or _("(none)"))
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    Destination.chooseTag(function(tag)
                        local old_tag = cb.tag
                        cb.tag = tag
                        if cb.label_auto == true or not cb.label or cb.label == ""
                                or cb.label == old_tag then
                            cb.label = tag
                            cb.label_auto = true
                        end
                        quick_button_label_by_id[cb.id] = get_cb_label(cb)
                        save_and_apply_quick_settings()
                        if touch_menu then touch_menu:updateItems(1) end
                    end)
                end,
            }, icons.keywords))
        elseif ok_disp then
            -- Action picker via Dispatcher submenu
            local dispatch_items = {}
            local caller = {}
            Dispatcher:addSubMenu(caller, dispatch_items, cb, "action")
            wrap_dispatch_callbacks(dispatch_items, caller, function(touch_menu)
                sync_cb_action_label(cb)
                if is_draft_button(cb) then
                    cb._zen_draft_commit()
                else
                    quick_button_label_by_id[cb.id] = get_cb_label(cb)
                    save_and_apply_quick_settings()
                end
                if touch_menu and touch_menu.updateItems then
                    touch_menu:updateItems(1)
                end
            end)
            table.insert(items, IconItem.decorate({
                text_func = function()
                    if cb.action and next(cb.action) then
                        return T(_("Action: %1"), Dispatcher:menuTextFunc(cb.action))
                    end
                    return _("Action: (none)")
                end,
                keep_menu_open = true,
                sub_item_table = dispatch_items,
            }, icons.action))
        end

        -- Icon picker
        table.insert(items, IconItem.decorate({
            text_func = function()
                return T(_("Icon: %1"),
                    icon_utils.getIconDisplayName(cb.icon or "zen_ui"))
            end,
            keep_menu_open = true,
            callback = function(tm)
                showIconPickerDialog(cb, function(name)
                    cb.icon = name
                    if not is_draft_button(cb) then
                        save_and_apply_quick_settings()
                    end
                    -- Refresh the submenu so text_func re-reads cb.icon.
                    if tm and tm.updateItems then tm:updateItems(1) end
                end)
            end,
        }, icons.icon))

        -- Optional label override
        table.insert(items, IconItem.decorate({
            text_func = function()
                local lbl = (cb.label and cb.label ~= "") and cb.label or _("(auto)")
                return T(_("Label: %1"), lbl)
            end,
            keep_menu_open = true,
            callback = function(touch_menu)
                local InputDialog = require("ui/widget/inputdialog")
                local dialog
                dialog = InputDialog:new{
                    title = _("Custom button label"),
                    input = cb.label or "",
                    input_hint = cb.type == "action"
                        and _("Leave empty to use action title") or nil,
                    buttons = {{
                        { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                        {
                            text = _("Set"),
                            is_enter_default = true,
                            callback = function()
                                local txt = dialog:getInputText()
                                if txt and txt ~= "" then
                                    cb.label = txt
                                    cb.label_auto = false
                                else
                                    cb.label = cb.type == "folder"
                                        and Destination.folderLabel(cb.folder)
                                        or cb.type == "tag" and cb.tag or nil
                                    cb.label_auto = true
                                    sync_cb_action_label(cb)
                                end
                                UIManager:close(dialog)
                                if not is_draft_button(cb) then
                                    quick_button_label_by_id[cb.id] = get_cb_label(cb)
                                    save_and_apply_quick_settings()
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

        -- Delete button
        table.insert(items, IconItem.decorate({
            text = _("Delete"),
            separator = true,
            keep_menu_open = true,
            callback = function(touch_menu)
                if is_draft_button(cb) then
                    if touch_menu then touch_menu:backToUpperMenu() end
                    return
                end
                local ConfirmBox = require("ui/widget/confirmbox")
                local function remove()
                    local cbs = config.quick_settings.custom_buttons
                    for i, item in ipairs(cbs) do
                        if item.id == cb.id then
                            table.remove(cbs, i)
                            break
                        end
                    end
                    quick_button_custom_by_id[cb.id] = nil
                    quick_button_label_by_id[cb.id] = nil
                    quick_button_key_set[cb.id] = nil
                    config.quick_settings.show_buttons[cb.id] = nil
                    local new_order = {}
                    for _i, id in ipairs(config.quick_settings.button_order) do
                        if id ~= cb.id then table.insert(new_order, id) end
                    end
                    config.quick_settings.button_order = new_order
                    save_and_apply_quick_settings()
                    if touch_menu then touch_menu:backToUpperMenu() end
                end
                UIManager:show(ConfirmBox:new{
                    text = _("Delete this button?"),
                    ok_text = _("Delete"),
                    ok_callback = remove,
                })
            end,
        }, icons.delete))

        return items
    end

    build_control_sub_items = function(id)
        local items = {}
        if id == "gyro" then
            items[#items + 1] = IconItem.decorate({
                text_func = function()
                    return T(_("Icon: %1"),
                        icon_utils.getIconDisplayName(getAutorotateIcon()))
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    showIconPickerDialog({ icon = getAutorotateIcon() }, function(name)
                        config.quick_settings.gyro_icon = name
                        save_and_apply_quick_settings()
                        if touch_menu and touch_menu.updateItems then touch_menu:updateItems(1) end
                    end)
                end,
            }, icons.icon)
            items[#items + 1] = IconItem.decorate({
                text_func = function()
                    return T(_("Label: %1"), getAutorotateLabel())
                end,
                keep_menu_open = true,
                callback = function(touch_menu)
                    local InputDialog = require("ui/widget/inputdialog")
                    local dialog
                    dialog = InputDialog:new{
                        title = _("Autorotate"),
                        input = config.quick_settings.gyro_label or "",
                        buttons = {{
                            { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                            {
                                text = _("Set"),
                                is_enter_default = true,
                                callback = function()
                                    local label = dialog:getInputText()
                                    config.quick_settings.gyro_label = label or ""
                                    quick_button_label_by_id.gyro = getAutorotateLabel()
                                    UIManager:close(dialog)
                                    save_and_apply_quick_settings()
                                    if touch_menu and touch_menu.updateItems then
                                        touch_menu:updateItems(1)
                                    end
                                end,
                            },
                        }},
                    }
                    UIManager:show(dialog)
                end,
            }, icons.label)
        elseif id == "rotate" then
            items = buildRotateButtonSubItems()
        elseif id == "screenshot" then
            items = buildScreenshotButtonSubItems()
        elseif id == "incognito" then
            items = require("modules/global/patches/incognito_mode").timeoutMenuItems(zen_plugin)
        elseif id == "tailscale" then
            items = buildTailscaleButtonSubItems()
        end
        items[#items + 1] = IconItem.decorate({
            text = _("Delete"),
            separator = true,
            callback = function(touch_menu)
                local ConfirmBox = require("ui/widget/confirmbox")
                UIManager:show(ConfirmBox:new{
                    text = _("Delete this control?"),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        local new_order = {}
                        for _i, saved_id in ipairs(config.quick_settings.button_order) do
                            if saved_id ~= id then
                                new_order[#new_order + 1] = saved_id
                            end
                        end
                        config.quick_settings.button_order = new_order
                        config.quick_settings.show_buttons[id] = false
                        save_and_apply_quick_settings()
                        if touch_menu then touch_menu:backToUpperMenu() end
                    end,
                })
            end,
        }, icons.delete)
        return items
    end

    -- Restore the default controls while retaining custom buttons as disabled items.
    local function resetQuickSettings()
        local def = defaults.quick_settings
        local new_show = {}
        local new_order = icon_utils.deepcopy(def.button_order)
        for key, val in pairs(def.show_buttons) do
            new_show[key] = val
        end
        -- Keep custom buttons saved but disabled (not part of defaults).
        if type(config.quick_settings.custom_buttons) == "table" then
            for _i, cb in ipairs(config.quick_settings.custom_buttons) do
                new_show[cb.id] = false
                new_order[#new_order + 1] = cb.id
            end
        end
        config.quick_settings.show_buttons = new_show
        config.quick_settings.button_order = new_order
        config.quick_settings.show_labels = def.show_labels
        config.quick_settings.show_frontlight = def.show_frontlight
        config.quick_settings.show_warmth = def.show_warmth
        config.quick_settings.background_hatching = def.background_hatching
        config.quick_settings.flip_lh_rh_icon = def.flip_lh_rh_icon
        config.quick_settings.gyro_label = def.gyro_label
        config.quick_settings.gyro_icon = def.gyro_icon
        quick_button_label_by_id.gyro = getAutorotateLabel()
        config.quick_settings.screenshot_timer_seconds = def.screenshot_timer_seconds
        config.quick_settings.tailscale_toggle_wifi = def.tailscale_toggle_wifi
        save_and_apply_quick_settings()
    end

    local function open_button_settings(id)
        local cb = quick_button_custom_by_id[id]
        local items = cb and build_cb_sub_items(cb) or build_control_sub_items(id)
        if type(items) ~= "table" or #items == 0 then
            showButtonsArrange()
            return true
        end
        require("common/ui/zen_arrange_list").show{
            title = quick_button_label_by_id[id] or tostring(id),
            item_table = items,
            hide_footer_cancel = true,
        }
        return true
    end

    local function button_search_label(id)
        if id == "rotate" then
            return T(_("Rotate: %1"), getRotateActionLabel())
        end
        if id == "screenshot" then
            return T(_("Screenshot: %1 s"), getScreenshotTimerSeconds())
        end
        return quick_button_label_by_id[id]
    end

    local function arrange_search_items()
        local items = {}
        for _i, id in ipairs(config.quick_settings.button_order) do
            local label = button_search_label(id)
            if label then
                local button_id = id
                items[#items + 1] = {
                    text = label,
                    _zen_search_open = function()
                        return open_button_settings(button_id)
                    end,
                }
            end
        end
        return items
    end

    return {
        text = _("Controls"),
        _zen_search_items_func = arrange_search_items,
        sub_item_table = {
            IconItem.decorate({
                text = _("Buttons") .. " \u{25B8}",
                keep_menu_open = true,
                callback = showButtonsArrange,
            }, icons.action),
            IconItem.decorate({
                text = _("Show labels"),
                checked_func = function() return config.quick_settings.show_labels ~= false end,
                callback = function()
                    config.quick_settings.show_labels = config.quick_settings.show_labels == false
                    save_and_apply_quick_settings()
                end,
            }, icons.keywords),
            IconItem.decorate({
                text = _("Show brightness slider"),
                checked_func = function() return config.quick_settings.show_frontlight == true end,
                callback = function()
                    config.quick_settings.show_frontlight = config.quick_settings.show_frontlight ~= true
                    save_and_apply_quick_settings()
                end,
            }, icons.schedule_brightness),
            IconItem.decorate({
                text = _("Show warmth slider"),
                checked_func = function() return config.quick_settings.show_warmth == true end,
                callback = function()
                    config.quick_settings.show_warmth = config.quick_settings.show_warmth ~= true
                    save_and_apply_quick_settings()
                end,
            }, icons.schedule_warmth),
            IconItem.decorate({
                text = _("Flip LH/RH icon"),
                checked_func = function() return config.quick_settings.flip_lh_rh_icon == true end,
                callback = function()
                    config.quick_settings.flip_lh_rh_icon = config.quick_settings.flip_lh_rh_icon ~= true
                    save_and_apply_quick_settings()
                end,
            }, icons.flip_lh_rh),
            IconItem.decorate({
                text = _("Background hatching"),
                checked_func = function()
                    return config.quick_settings.background_hatching == true
                end,
                callback = function()
                    config.quick_settings.background_hatching = config.quick_settings.background_hatching ~= true
                    save_and_apply_quick_settings()
                end,
            }, icons.settings_background),
            IconItem.decorate({
                text = _("Reset to defaults"),
                separator = true,
                keep_menu_open = true,
                callback = function(touch_menu)
                    local ConfirmBox = require("ui/widget/confirmbox")
                    UIManager:show(ConfirmBox:new{
                        text = _("Reset Controls to defaults?"),
                        ok_text = _("Reset"),
                        ok_callback = function()
                            resetQuickSettings()
                            if touch_menu and touch_menu.updateItems then touch_menu:updateItems() end
                        end,
                    })
                end,
            }, icons.restart),
        },
    }
end

return M
