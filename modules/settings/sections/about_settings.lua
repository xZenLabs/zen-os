-- settings/sections/about.lua
-- "About" info items: plugin version plus a grouped device subsection.
-- Receives ctx: { plugin, config, save_and_apply, settings_apply }

local _ = require("gettext")
local T = require("ffi/util").template
local NetworkMgr = require("ui/network/manager")
local Bluetooth = require("modules/menu/bluetooth/bluetooth")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local utils = require("modules/settings/zen_settings_utils")
local bugreporter = require("modules/settings/zen_bugreporter")
local advanced_section = require("modules/settings/sections/advanced_settings")
local icons = require("common/inline_icon_map")
local IconItem = require("common/ui/icon_menu_item")

local M = {}

function M.build(ctx)
    local plugin = ctx.plugin
    local items = {}

    table.insert(items, {
        text_func = function()
            return _("ZenOS: ") .. utils.get_plugin_version(plugin)
        end,
        keep_menu_open = true,
    })

    table.insert(items, {
        text = _("Device"),
        sub_item_table = {
            {
                text_func = function()
                    return _("KOReader: ") .. utils.get_koreader_version()
                end,
                keep_menu_open = true,
            },
            {
                text_func = function()
                    return _("Device: ") .. utils.get_device_model_name()
                end,
                keep_menu_open = true,
            },
            {
                text_func = function()
                    return _("Firmware: ") .. utils.get_device_firmware_display()
                end,
                keep_menu_open = true,
            },
            {
                text_func = function()
                    return T(_("IP address: %1"), utils.get_device_ip_address() or "—")
                end,
                keep_menu_open = true,
            },
        },
    })

    table.insert(items, {
        text = _("Wi-Fi"),
        checked_func = function()
            return NetworkMgr:isWifiOn()
        end,
        checkmark_callback = function(touch_menu)
            if require("modules/menu/network_adapters/kindle").restoreWifi(
                NetworkMgr, function()
                    touch_menu:updateItems()
                    if touch_menu._zen_status_refresh then touch_menu:_zen_status_refresh() end
                end)
            then
                return
            end
            NetworkMgr:getWifiMenuTable().callback(touch_menu)
        end,
        _zen_settings_submenu = true,
        callback = function()
            require("modules/menu/network_switcher").open(nil, true, plugin)
        end,
        keep_menu_open = true,
    })
    items[2], items[3] = items[3], items[2]
    local device_items = items[3].sub_item_table

    local has_bluetooth = Bluetooth.isAvailable()
    if has_bluetooth then
        table.insert(items, 3, {
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
        })
    end

    table.insert(items, {
        text = _("Setup Guide"),
        callback = function()
            local ok_qs, QuickstartScreen = pcall(require, "common/quickstart/quickstart_screen")
            if not ok_qs then return end
            local ok_pg, pages_mod = pcall(require, "common/quickstart/quickstart_pages")
            if not ok_pg then return end
            UIManager:show(QuickstartScreen:new{
                pages    = pages_mod.build_install_pages({
                    plugin = plugin,
                    config = ctx.config,
                }),
                on_close = function()
                    if type(ctx.config._meta) ~= "table" then ctx.config._meta = {} end
                    ctx.config._meta.quickstart_completed = true
                    ctx.config._meta.quickstart_menu_tour_pending = true
                    ctx.config._meta.quickstart_reader_tour_pending = true
                    plugin:saveConfig()
                    UIManager:nextTick(function()
                        local reinject = _G.__ZEN_UI_REINJECT_FM_NAVBAR
                        if type(reinject) == "function" then reinject() end
                        local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
                        local fm = ok and FileManager and FileManager.instance
                        if fm and type(fm._updateStatusBar) == "function" then
                            fm:_updateStatusBar()
                        end
                        UIManager:scheduleIn(0.35, function()
                            local ok_tour, tour = pcall(require, "common/quickstart/menu_tour")
                            if ok_tour then tour.start(plugin) end
                        end)
                    end)
                end,
            })
        end,
    })

    local language_setting = require("ui/language"):getLangMenuTable()
    table.insert(device_items, {
        text = language_setting.text,
        sub_item_table = language_setting.sub_item_table,
    })

    local time_setting = require("ui/elements/common_settings_menu_table").time
    table.insert(device_items, time_setting)

    table.insert(items, {
        text      = _("Report a Bug"),
        callback  = function()
            bugreporter.show_dialog(ctx)
        end,
        keep_menu_open = true,
    })

    table.insert(items, {
        text = _("Advanced"),
        sub_item_table = advanced_section.build(ctx),
    })

    IconItem.decorate(items[1], icons.details)
    IconItem.decorate(items[2], icons.wifi_on)
    if has_bluetooth then IconItem.decorate(items[3], icons.bluetooth_on) end
    local offset = has_bluetooth and 1 or 0
    IconItem.decorate(items[3 + offset], icons.settings_device)
    IconItem.decorate(items[4 + offset], icons.settings_setup)
    IconItem.decorate(items[5 + offset], icons.settings_bug)
    IconItem.decorate(items[6 + offset], icons.settings_advanced)
    IconItem.decorate(device_items[#device_items - 1], icons.language)
    IconItem.decorate(device_items[#device_items], icons.tbr)

    return items
end

return M
