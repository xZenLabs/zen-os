-- settings/sections/extras.lua
-- Extra integration settings for ZenOS.
-- Receives ctx: { plugin, config, settings_apply }

local _ = require("gettext")
local Device = require("device")
local T = require("ffi/util").template
local IconPacks = require("common/icon_packs")
local Rakuyomi = require("modules/filebrowser/patches/rakuyomi")
local global_settings = require("modules/settings/sections/global_settings")
local stats_settings = require("modules/settings/sections/stats_settings")
local zenpm_installer = require("modules/settings/zenpm_installer")
local icons = require("common/inline_icon_map")
local IconItem = require("common/ui/icon_menu_item")

local M = {}

function M.build(ctx)
    local config = ctx.config
    local plugin = ctx.plugin
    local settings_apply = ctx.settings_apply
    local items = {}

    table.insert(items, stats_settings.build(ctx))
    if not (Device.isAndroid and Device:isAndroid()) then
        table.insert(items, IconItem.decorate(zenpm_installer.build_item(plugin), icons.download))
    end

    do
        if type(config.opds) ~= "table" then
            config.opds = {}
        end
        if config.opds.display_mode ~= "list" and config.opds.display_mode ~= "classic" then
            config.opds.display_mode = "mosaic"
        end

        local display_modes = {
            { text = _("Mosaic"),  mode = "mosaic"  },
            { text = _("List"),    mode = "list"    },
            { text = _("Classic"), mode = "classic" },
        }
        local display_mode_items = {}
        for _i, entry in ipairs(display_modes) do
            table.insert(display_mode_items, {
                text = entry.text,
                radio = true,
                checked_func = function()
                    return config.opds.display_mode == entry.mode
                end,
                callback = function(touchmenu_instance)
                    if config.opds.display_mode == entry.mode then return end
                    config.opds.display_mode = entry.mode
                    plugin:saveConfig()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end

        local opds_display_item = IconItem.decorate({
            text = _("Display mode"),
            sub_item_table = display_mode_items,
        }, icons.settings_layout)

        table.insert(items, {
            text = _("Zen OPDS"),
            help_text = _("Enable ZenOS enhancements to the OPDS browser: cover art, list view, hold menu, and navigation improvements."),
            sub_item_table = {
                IconItem.decorate({
                    text = _("Enable Zen OPDS"),
                    checked_func = function()
                        return config.features.zen_opds ~= false
                    end,
                    callback = function(touchmenu_instance)
                        config.features.zen_opds = config.features.zen_opds == false
                        plugin:saveConfig()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                        settings_apply.prompt_restart()
                    end,
                }, icons.enable),
                opds_display_item,
            },
        })
        IconItem.decorate(items[#items], icons.settings_opds)
    end

    if Rakuyomi.is_available() then
        if type(config.rakuyomi) ~= "table" then
            config.rakuyomi = {}
        end
        local migrated_rakuyomi = false
        if config.rakuyomi.return_to_chapter_list_on_exit == nil then
            if config.rakuyomi.return_to_chapter_list_on_reader_exit ~= nil then
                config.rakuyomi.return_to_chapter_list_on_exit =
                    config.rakuyomi.return_to_chapter_list_on_reader_exit
                migrated_rakuyomi = true
            else
                config.rakuyomi.return_to_chapter_list_on_exit = true
            end
        end
        if config.rakuyomi.return_to_chapter_list_on_reader_exit ~= nil then
            config.rakuyomi.return_to_chapter_list_on_reader_exit = nil
            migrated_rakuyomi = true
        end
        if config.rakuyomi.return_to_chapter_on_reader_exit ~= nil then
            config.rakuyomi.return_to_chapter_on_reader_exit = nil
            migrated_rakuyomi = true
        end
        if migrated_rakuyomi then
            plugin:saveConfig()
        end
        table.insert(items, {
            text = _("Rakuyomi"),
            sub_item_table = {
                {
                    text = _("Return to chapter list on exit"),
                    checked_func = function()
                        return config.rakuyomi.return_to_chapter_list_on_exit ~= false
                    end,
                    callback = function(touchmenu_instance)
                        config.rakuyomi.return_to_chapter_list_on_exit =
                            config.rakuyomi.return_to_chapter_list_on_exit == false
                        plugin:saveConfig()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                },
            },
        })
        IconItem.decorate(items[#items], icons.reading)
    end

    local global_items = global_settings.build_extras_items(ctx)
    for _i, item in ipairs(global_items) do
        table.insert(items, item)
    end

    local custom_icons_enabled_item = IconItem.decorate({
        text = _("Enable custom icons"),
        help_text = _("When enabled, loose icons or a selected ZenOS icon pack override supported icons. Missing icons fall back to ZenOS, then KOReader."),
        checked_func = function()
            return config.features.custom_icons_enabled == true
        end,
        callback = function(touchmenu_instance)
            config.features.custom_icons_enabled = config.features.custom_icons_enabled ~= true
            plugin:saveConfig()
            if touchmenu_instance then touchmenu_instance:updateItems() end
            settings_apply.prompt_restart()
        end,
    }, icons.enable)

    if type(config.custom_icons) ~= "table" then config.custom_icons = { active_pack = "" } end
    local function active_pack_id()
        local value = config.custom_icons.active_pack
        return type(value) == "string" and value or ""
    end

    local function active_pack_name()
        local active_id = active_pack_id()
        if active_id == "" then return _("Loose icons") end
        for _i, pack in ipairs(IconPacks.getLastScan().packs or {}) do
            if pack.id == active_id then return pack.name end
        end
        return T(_("Missing: %1"), active_id)
    end

    local function select_pack(pack_id, touchmenu_instance)
        if active_pack_id() == pack_id then return end
        config.custom_icons.active_pack = pack_id
        plugin:saveConfig()
        if touchmenu_instance then touchmenu_instance:updateItems() end
        settings_apply.prompt_restart()
    end

    local function build_pack_items()
        local scan = IconPacks.scan()
        local pack_items = {
            {
                text = _("Loose icons in /koreader/icons"),
                radio = true,
                checked_func = function() return active_pack_id() == "" end,
                callback = function(touchmenu_instance)
                    select_pack("", touchmenu_instance)
                end,
            },
        }
        local found_active = active_pack_id() == ""
        for _i, pack in ipairs(scan.packs or {}) do
            local pack_id = pack.id
            pack_items[#pack_items + 1] = {
                text = pack.name,
                help_text = pack.author and T(_("By %1"), pack.author) or nil,
                radio = true,
                checked_func = function() return active_pack_id() == pack_id end,
                callback = function(touchmenu_instance)
                    select_pack(pack_id, touchmenu_instance)
                end,
            }
            if pack_id == active_pack_id() then found_active = true end
        end
        if not found_active then
            pack_items[#pack_items + 1] = {
                text = T(_("Unavailable pack: %1"), active_pack_id()),
                enabled = false,
                radio = true,
                checked_func = function() return true end,
            }
        end
        for _i, installed in ipairs(scan.installed or {}) do
            if installed.id == active_pack_id() then
                pack_items[#pack_items + 1] = {
                    text = _("Restart KOReader to apply the updated active pack"),
                    enabled = false,
                }
                break
            end
        end
        for _i, err in ipairs(scan.errors or {}) do
            pack_items[#pack_items + 1] = {
                text = T(_("Could not install %1: %2"), err.file, err.message),
                enabled = false,
            }
        end
        return pack_items
    end

    local custom_icon_pack_item = IconItem.decorate({
        text_func = function()
            return T(_("Custom icon pack: %1"), active_pack_name())
        end,
        help_text = _("Place pack folders or ZIP files in /koreader/icons/zen. ZIP files are installed automatically."),
        enabled_func = function()
            return config.features.custom_icons_enabled == true
        end,
        sub_item_table_func = build_pack_items,
    }, icons.icon)

    table.insert(items, IconItem.decorate({
        text = _("Custom icons"),
        sub_item_table = {
            custom_icons_enabled_item,
            custom_icon_pack_item,
        },
    }, icons.icon))

    return items
end

return M
