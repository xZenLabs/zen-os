-- "Map buttons" for a HID device: capture a press, pick what it does in the reader and the library.
local M = {}

-- capture: listen for a press right away, without a tap on "Map a button".
function M.show(device, plugin, capture)
    local Device = require("device")
    local Dispatcher = require("dispatcher")
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager = require("ui/uimanager")
    local ArrangeList = require("common/ui/zen_arrange_list")
    local Destination = require("common/library_destination")
    local DispatcherMenu = require("common/dispatcher_menu")
    local GlyphIcons = require("common/ui/glyph_icons")
    local IconItem = require("common/ui/icon_menu_item")
    local Keys = require("common/hid_keys")
    local icons = require("common/inline_icon_map")
    local T = require("ffi/util").template
    local _ = require("gettext")
    -- label, icon, KOReader menu scope
    local SCREENS = {
        reader = { _("Reader"), icons.settings_reader, "reader" },
        library = { _("Library"), icons.settings_library, "filemanager" },
    }
    local root_menu

    -- Hold-on-back returns to the settings root from any depth: every list here closes with it.
    local function show_list(opts)
        opts.plugin, opts.allow_arrange, opts.hide_footer_cancel = plugin, false, true
        local list = ArrangeList.show(opts)
        list.onCloseZenSettingsSubpages = list._zen_arrange_close_all
        return list
    end

    local function save()
        Keys.save()
        if root_menu then root_menu:updateItems() end
    end

    local function pick(title, items, empty, touch_menu, on_select)
        if #items == 0 then
            if empty then UIManager:show(InfoMessage:new{ text = empty }) end
            return
        end
        require("common/ui/zen_menu_picker"){
            title = title, items = items, on_select = on_select,
            back_hold_callback = touch_menu and touch_menu.backToSettingsRoot,
        }
    end

    -- What a button does on one screen: a row per kind, the assigned one showing its value.
    local function screen_row(binding, screen)
        local function assign(touch_menu, field, value)
            Keys.assign(device.address, binding, screen, field, value)
            save()
            if touch_menu and touch_menu.updateItems then touch_menu:updateItems() end
        end
        local items = {}
        -- item: the row's fields, or a chooser handing over a launcher entry of that kind.
        local function add(kind, text, glyph, item)
            local choose = type(item) == "function" and item
            if choose then
                item = { callback = function(touch_menu)
                    choose(function(entry)
                        entry.type = kind
                        assign(touch_menu, "entries", entry)
                    end, touch_menu)
                end }
            end
            item.text_func = function()
                local label, assigned = Keys.label(binding, screen)
                return assigned == kind and text .. ": " .. label or text
            end
            item.keep_menu_open, item._zen_arrange_no_caret = true, true -- one list of choices: no chevrons
            items[#items + 1] = IconItem.decorate(item, glyph)
            return item
        end

        local common = {}
        for _i, preset in ipairs(Keys.COMMON[screen]) do
            if DispatcherMenu.available(Dispatcher, preset[1]) then
                common[#common + 1] = {
                    text = preset[3] or Dispatcher:menuTextFunc({ [preset[1]] = preset[2] }), radio = true,
                    checked_func = function() return Keys.preset(screen, binding[screen]) == preset end,
                    callback = function() assign(nil, "actions", { [preset[1]] = preset[2] }) end,
                }
            end
        end
        add("common", _("Common actions"), icons.fav_add, { sub_item_table = common })

        add("quick_setting", _("Control"), icons.settings_quick, function(done, touch_menu)
            local controls = rawget(_G, "__ZEN_UI_QUICK_SETTINGS")
            pick(_("Choose control"), controls and controls.getItems() or {}, nil, touch_menu, function(item)
                done({ quick_setting_id = item.id, label = item.label })
            end)
        end)

        local actions, caller = {}, {}
        DispatcherMenu.addSubMenu(Dispatcher, caller, actions, binding, screen)
        DispatcherMenu.wrap(actions, caller, function(touch_menu)
            assign(touch_menu, "actions", binding[screen])
        end)
        add("actions", _("Action"), icons.action, { sub_item_table = actions })

        if screen == "library" then
            add("folder_shortcut", _("Folder"), icons.settings_folders, function(done)
                local current = binding.entries and binding.entries[screen]
                Destination.chooseFolder(function(path)
                    done({ folder = path, label = Destination.folderLabel(path) })
                end, { path = current and current.folder })
            end)
            add("tag", _("Specific tag"), icons.keywords, function(done, touch_menu)
                Destination.chooseTag(function(tag) done({ tag = tag, label = tag }) end,
                    { back_hold_callback = touch_menu and touch_menu.backToSettingsRoot })
            end)
        end

        add("plugin", _("Plugin Menu"), icons.plugin, function(done, touch_menu)
            local found = {}
            for _i, plugin_menu in ipairs(require("modules/menu/app_launcher/plugin_scan").scan()) do
                found[#found + 1] = { text = plugin_menu.title, plugin = plugin_menu }
            end
            pick(_("Choose plugin menu"), found, _("No launchable plugin menus found"), touch_menu, function(item)
                done({ label = item.text, plugin = { key = item.plugin.key, method = item.plugin.method } })
            end)
        end)

        add("koreader_menu", _("KOReader menu"), nil, function(done, touch_menu)
            local found = require("modules/menu/app_launcher/native_menu").scan(SCREENS[screen][3])
            pick(_("Choose KOReader menu"), found, _("No KOReader submenus found"), touch_menu, function(item)
                done({ label = item.title, koreader_menu = { id = item.id, title = item.title } })
            end)
        end).icon_file = require("common/plugin_root") .. "/icons/koreader.png"

        -- Native key names have no handlers on a touch-only device.
        if Device:hasKeys() then
            local keys = {}
            for _i, key in ipairs(Keys.KEYS) do
                keys[#keys + 1] = {
                    text = key[2], radio = true,
                    checked_func = function() return binding.keys ~= nil and binding.keys[screen] == key[1] end,
                    callback = function() assign(nil, "keys", key[1]) end,
                }
            end
            add("keys", _("Keys"), icons.keyboard, { sub_item_table = keys })
        end

        return IconItem.decorate({
            text_func = function()
                return SCREENS[screen][1] .. ": " .. (Keys.label(binding, screen) or _("(none)"))
            end,
            keep_menu_open = true,
            sub_item_table = items,
        }, SCREENS[screen][2])
    end

    local function show_binding(binding)
        local items = {}
        for _i, screen in ipairs(Keys.SCREENS) do items[#items + 1] = screen_row(binding, screen) end
        items[#items + 1] = IconItem.decorate({
            text = _("Remove mapping"),
            callback = function(touch_menu)
                Keys.remove(device.address, binding)
                save()
                if touch_menu and touch_menu.closeMenu then touch_menu:closeMenu() end
            end,
        }, icons.delete)
        show_list{ title = T(_("Button %1"), binding.code), item_table = items }
    end

    local function listen()
        local message
        message = InfoMessage:new{
            text = T(_("Press a button on %1…"), device.name),
            dismiss_callback = Keys.stopCapture,
        }
        UIManager:show(message)
        Keys.rescan() -- a remote that reconnected by itself may not be open yet
        Keys.capture(function(code)
            UIManager:close(message)
            if not code then
                UIManager:show(InfoMessage:new{ text = _("No button press detected."), timeout = 3 })
                return
            end
            show_binding(Keys.add(device.address, code))
        end)
    end

    local function rows()
        local items = { {
            text = _("Map a button"), keep_menu_open = true,
            icon_file = GlyphIcons.iconPath("plus"),
            callback = function(touch_menu)
                root_menu = touch_menu or root_menu
                listen()
            end,
        } }
        for _i, binding in ipairs(Keys.list(device.address)) do
            items[#items + 1] = {
                text_func = function()
                    local labels = {}
                    for _j, screen in ipairs(Keys.SCREENS) do
                        local label = Keys.label(binding, screen)
                        if label then labels[#labels + 1] = SCREENS[screen][1] .. ": " .. label end
                    end
                    return T(_("Button %1"), binding.code) .. " — "
                        .. (#labels > 0 and table.concat(labels, " · ") or _("(none)"))
                end,
                keep_menu_open = true, _zen_settings_submenu = true,
                callback = function(touch_menu)
                    root_menu = touch_menu or root_menu
                    show_binding(binding)
                end,
            }
        end
        return items
    end

    local list = show_list{ title = device.name, item_table = rows(), refresh_func = rows }
    if capture then
        root_menu = list._zen_menu_proxy -- the list behind picks up the new mapping
        listen()
    end
    return list
end

return M
