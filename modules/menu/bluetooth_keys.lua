-- "Map buttons" for a HID device: capture a press, pick what it does in the reader and the library.
local M = {}

function M.show(device, plugin)
    local Device = require("device")
    local Dispatcher = require("dispatcher")
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager = require("ui/uimanager")
    local ArrangeList = require("common/ui/zen_arrange_list")
    local DispatcherMenu = require("common/dispatcher_menu")
    local IconItem = require("common/ui/icon_menu_item")
    local Keys = require("common/hid_keys")
    local icons = require("common/inline_icon_map")
    local T = require("ffi/util").template
    local _ = require("gettext")
    local SCREENS = {
        reader = { _("Reader"), icons.settings_reader },
        library = { _("Library"), icons.settings_library },
    }
    local root_menu

    local function save()
        Keys.save()
        if root_menu then root_menu:updateItems() end
    end

    local function screen_row(binding, screen)
        local items, caller = {}, {}
        DispatcherMenu.addSubMenu(Dispatcher, caller, items, binding, screen)
        DispatcherMenu.wrap(items, caller, function(touch_menu)
            if binding.keys then binding.keys[screen] = nil end
            save()
            if touch_menu and touch_menu.updateItems then touch_menu:updateItems() end
        end)
        -- Native key names have no handlers on a touch-only device.
        if Device:hasKeys() then
            local keys = {}
            for _i, key in ipairs(Keys.KEYS) do
                keys[#keys + 1] = {
                    text = key[2], radio = true,
                    checked_func = function() return binding.keys ~= nil and binding.keys[screen] == key[1] end,
                    callback = function()
                        binding.keys = binding.keys or {}
                        binding.keys[screen] = key[1]
                        binding[screen] = nil
                        save()
                    end,
                }
            end
            table.insert(items, 1, { text = _("Keys"), sub_item_table = keys })
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
        ArrangeList.show{
            title = T(_("Button %1"), binding.code), plugin = plugin,
            allow_arrange = false, hide_footer_cancel = true, item_table = items,
        }
    end

    local function listen()
        local message
        message = InfoMessage:new{
            text = T(_("Press a button on %1…"), device.name),
            dismiss_callback = Keys.stopCapture,
        }
        UIManager:show(message)
        Keys.capture(function(code)
            UIManager:close(message)
            if not code then
                UIManager:show(InfoMessage:new{ text = _("No button press detected."), timeout = 3 })
                return
            end
            local binding = Keys.add(device.address, code)
            save()
            show_binding(binding)
        end)
    end

    local function rows()
        local items = { IconItem.decorate({
            text = _("Map a button"), keep_menu_open = true,
            callback = function(touch_menu)
                root_menu = touch_menu or root_menu
                listen()
            end,
        }, icons.add) }
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

    return ArrangeList.show{
        title = device.name, plugin = plugin, allow_arrange = false, hide_footer_cancel = true,
        item_table = rows(), refresh_func = rows,
    }
end

return M
