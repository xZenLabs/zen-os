local _ = require("gettext")
local NetworkMgr = require("ui/network/manager")
local Bluetooth = require("modules/menu/bluetooth/bluetooth")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local advanced_section = require("modules/settings/sections/advanced_settings")
local updates_section = require("modules/settings/sections/updates_settings")
local icons = require("common/inline_icon_map")
local IconItem = require("common/ui/icon_menu_item")

local M = {}

function M.build(ctx, extras_items)
    local plugin = ctx.plugin
    local items = {
        IconItem.decorate({
            text = _("Wi-Fi"),
            checked_func = function()
                return NetworkMgr:isWifiOn()
            end,
            checkmark_callback = function(touch_menu)
                local refresh = function()
                    touch_menu:updateItems()
                    if touch_menu._zen_status_refresh then touch_menu:_zen_status_refresh() end
                end
                require("modules/menu/network_switcher").toggleWifi({
                    updateItems = refresh,
                }, refresh, true, plugin)
            end,
            _zen_settings_submenu = true,
            callback = function()
                require("modules/menu/network_switcher").open(nil, true, plugin)
            end,
            keep_menu_open = true,
        }, icons.wifi_on),
    }

    if Bluetooth.isAvailable() then
        table.insert(items, IconItem.decorate({
            text = _("Bluetooth"),
            checked_func = function()
                local state = Bluetooth.getCachedState()
                if state ~= nil then return state end
                return Bluetooth.isEnabled()
            end,
            checkmark_callback = function(touch_menu)
                Bluetooth.toggle(function(success, reason)
                    if success then
                        UIManager:broadcastEvent(Event:new("BluetoothStateChanged"))
                    else
                        local InfoMessage = require("ui/widget/infomessage")
                        UIManager:show(InfoMessage:new{ text = reason or _("Could not change Bluetooth power.") })
                    end
                    touch_menu:updateItems()
                    if touch_menu._zen_status_refresh then touch_menu:_zen_status_refresh() end
                end)
            end,
            _zen_settings_submenu = true,
            callback = function()
                require("modules/menu/bluetooth_switcher").open(nil, true, plugin)
            end,
            keep_menu_open = true,
        }, icons.bluetooth_on))
    end

    for _i, label in ipairs({ _("Schedules"), _("Sleep") }) do
        for i, item in ipairs(extras_items) do
            if item.text == label then
                table.insert(items, table.remove(extras_items, i))
                break
            end
        end
    end

    table.insert(items, IconItem.decorate({
        text = _("Battery"),
        sub_item_table_func = require("modules/settings/battery_stats_menu").buildItems,
    }, icons.battery))

    local language_setting = require("ui/language"):getLangMenuTable()
    table.insert(items, IconItem.decorate({
        text = language_setting.text,
        sub_item_table = language_setting.sub_item_table,
    }, icons.language))
    table.insert(items, IconItem.decorate(
        require("ui/elements/common_settings_menu_table").time, icons.tbr))

    table.insert(items, IconItem.decorate({
        text = _("Advanced"),
        sub_item_table = advanced_section.build(ctx),
    }, icons.settings_advanced))
    table.insert(items, IconItem.decorate({
        text = _("Updates"),
        sub_item_table = updates_section.build(ctx),
    }, icons.upgrade))

    return items
end

return M
