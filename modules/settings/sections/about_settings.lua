-- settings/sections/about.lua
-- "About" info items: plugin version plus a grouped device subsection.
-- Receives ctx: { plugin, config, save_and_apply, settings_apply }

local _ = require("gettext")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local utils = require("modules/settings/zen_settings_utils")
local bugreporter = require("modules/settings/zen_bugreporter")
local icons = require("common/inline_icon_map")
local IconItem = require("common/ui/icon_menu_item")
local util = require("util")

local M = {}

local function usage_size(usage, key)
    return util.getFriendlySize(usage and usage[key]) or "—"
end

local function clock_speed(khz)
    -- Translators: CPU clock speed in gigahertz; %1 is a number or a minimum-to-maximum range.
    return khz and T(_("%1 GHz"), string.format("%.2f", khz / 1000000)) or "—"
end

local function usage_items(usage, remaining_label)
    return {
        { text = remaining_label .. ": " .. usage_size(usage, "available"), keep_menu_open = true },
        -- Translators: Device statistics label for storage space or RAM currently in use.
        { text = _("Used") .. ": " .. usage_size(usage, "used"), keep_menu_open = true },
        -- Translators: Device statistics label for total storage capacity or installed RAM.
        { text = _("Total") .. ": " .. usage_size(usage, "total"), keep_menu_open = true },
    }
end

function M.build(ctx)
    local plugin = ctx.plugin
    local language_setting = require("ui/language"):getLangMenuTable()
    local items = {}

    table.insert(items, {
        text_func = function()
            return _("ZenOS") .. ": " .. utils.get_plugin_version(plugin)
        end,
        keep_menu_open = true,
    })

    table.insert(items, {
        text = _("Device"),
        sub_item_table = {
            {
                text_func = function()
                    return _("KOReader") .. ": " .. utils.get_koreader_version()
                end,
                keep_menu_open = true,
            },
            {
                text_func = function()
                    return _("Device") .. ": " .. utils.get_device_model_name()
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
                    return _("IP address") .. ": " .. (utils.get_device_ip_address() or "—")
                end,
                keep_menu_open = true,
            },
            IconItem.decorate({
                -- Translators: Settings menu showing total device storage, with remaining, used, and total storage details.
                text = _("Storage"),
                mandatory_func = function()
                    return usage_size(utils.get_device_disk_usage(), "total")
                end,
                sub_item_table_func = function()
                    -- Translators: Device statistics label for remaining free storage space.
                    return usage_items(utils.get_device_disk_usage(), _("Remaining"))
                end,
            }, icons.settings_storage),
            IconItem.decorate({
                -- Translators: Settings menu showing total RAM, with used, available, and total memory details.
                text = _("RAM"),
                mandatory_func = function()
                    return usage_size(utils.get_device_ram_usage(), "total")
                end,
                sub_item_table_func = function()
                    -- Translators: Device statistics label for RAM available to applications.
                    return usage_items(utils.get_device_ram_usage(), _("Available"))
                end,
            }, icons.settings_ram),
            IconItem.decorate({
                -- Translators: Settings menu showing maximum CPU clock speed, with processor, core count, and clock details.
                text = _("CPU"),
                mandatory_func = function()
                    return clock_speed(utils.get_device_cpu_info().max_khz)
                end,
                sub_item_table_func = function()
                    local cpu = utils.get_device_cpu_info()
                    local current = "—"
                    if cpu.current_min_khz then
                        current = string.format("%.2f", cpu.current_min_khz / 1000000)
                        if cpu.current_max_khz ~= cpu.current_min_khz then
                            current = current .. "–" .. string.format("%.2f", cpu.current_max_khz / 1000000)
                        end
                        current = T(_("%1 GHz"), current)
                    end
                    return {
                        { text = _("CPU") .. ": " .. (cpu.model or "—"), keep_menu_open = true },
                        -- Translators: Device CPU statistics label for the number of processor cores.
                        { text = _("Cores") .. ": " .. (cpu.cores or "—"), keep_menu_open = true },
                        -- Translators: Device CPU statistics label for the current clock speed or speed range, in GHz.
                        { text = _("Current clock") .. ": " .. current, keep_menu_open = true },
                        -- Translators: Device CPU statistics label for the maximum supported clock speed, in GHz.
                        { text = _("Maximum clock") .. ": " .. clock_speed(cpu.max_khz), keep_menu_open = true },
                    }
                end,
            }, icons.settings_cpu),
            IconItem.decorate({
                text = language_setting.text,
                sub_item_table = language_setting.sub_item_table,
            }, icons.language),
            IconItem.decorate(require("ui/elements/common_settings_menu_table").time, icons.tbr),
        },
    })

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

    table.insert(items, {
        text      = _("Report a Bug"),
        callback  = function()
            bugreporter.show_dialog(ctx)
        end,
        keep_menu_open = true,
    })

    IconItem.decorate(items[1], icons.details)
    IconItem.decorate(items[2], icons.settings_device)
    IconItem.decorate(items[3], icons.settings_setup)
    IconItem.decorate(items[4], icons.settings_bug)

    return items
end

return M
