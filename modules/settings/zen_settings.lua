local _ = require("gettext")
local UIManager = require("ui/uimanager")

local settings_apply = require("modules/settings/zen_settings_apply")
local updater        = require("modules/settings/zen_updater")
local icons          = require("common/inline_icon_map")
local plugin_root    = require("common/plugin_root")
local IconItem       = require("common/ui/icon_menu_item")
local utils          = require("modules/settings/zen_settings_utils")

local lib_section      = require("modules/settings/sections/library_settings")
local home_section = require("modules/settings/sections/library_settings/home_settings")
local interface_section = require("modules/settings/sections/interface_settings")
local reader_section   = require("modules/settings/sections/reader_settings")
local extras_section   = require("modules/settings/sections/extras_settings")
local general_section  = require("modules/settings/sections/general_settings")
local about_section    = require("modules/settings/sections/about_settings")
local shutdown         = require("common/shutdown")

local M = {}

IconItem.installMenuPatch()

function M.build(plugin)
    -- Initialize updater banner state; release metadata stays live-only.
    updater.init_banner()
    if settings_apply.set_plugin then
        settings_apply.set_plugin(plugin)
    end

    local config = plugin.config

    local function apply_feature(feature)
        local enabled = config.features[feature] == true
        settings_apply.apply_feature_toggle(plugin, feature, enabled)
    end

    local function save_and_apply(feature)
        plugin:saveConfig()
        apply_feature(feature)
    end

    local ctx = {
        plugin         = plugin,
        config         = config,
        save_and_apply = save_and_apply,
        apply_feature  = apply_feature,
        settings_apply = settings_apply,
    }

    local filebrowser_items    = lib_section.build(ctx)
    local home_item       = home_section.build(ctx)
    local reader_items         = reader_section.build(ctx)
    local extras_items      = extras_section.build(ctx)
    local about_items     = about_section.build(ctx)
    local general_items   = general_section.build(ctx, extras_items)

    extras_items = utils.order_items_by_text(extras_items, {
        _("Install ZenPM"),
        _("Zen OPDS"),
        _("Stats"),
        _("Rakuyomi"),
    })

    home_item.text = _("Home")
    IconItem.decorate(home_item, icons.settings_home)
    local interface_item = interface_section.build(ctx, extras_items)

    local library_item = IconItem.decorate({
        text = _("Library"),
        sub_item_table = filebrowser_items,
        _zen_settings_root = "library",
    }, icons.settings_library)

    local root_items = {
        home_item,
        library_item,
        IconItem.decorate({ text = _("Reader"), sub_item_table = reader_items }, icons.settings_reader),
        interface_item,
        IconItem.decorate({ text = _("Extras"), sub_item_table = extras_items }, icons.fav_add),
        IconItem.decorate({ text = _("General"), sub_item_table = general_items }, icons.settings),
        {
            text = _("KOReader"),
            icon_file = plugin_root .. "/icons/koreader.png",
            _zen_settings_root = "koreader",
            sub_item_table_func = function()
                local items = require("modules/menu/app_launcher/native_menu").settingsItems("active")
                table.insert(items, IconItem.decorate({
                    text = _("Quit KOReader"),
                    keep_menu_open = true,
                    callback = function()
                        UIManager:show(require("ui/widget/confirmbox"):new{
                            text = _("Are you sure you want to quit KOReader?"),
                            ok_text = _("Quit"),
                            ok_callback = function()
                                shutdown.broadcastExit(plugin)
                            end,
                        })
                    end,
                }, icons.delete))
                return items
            end,
        },
        IconItem.decorate({ text = _("About"), sub_item_table = about_items }, icons.settings_about),
    }

    root_items._zen_header_action_func = function()
        return updater.build_update_available_action(plugin)
    end

    -- fires when navigating back from a submenu (e.g. About after manual check).
    root_items.needs_refresh = true
    root_items.refresh_func  = function()
        return M.build(plugin).sub_item_table
    end

    return {
        text = _("ZenOS"),
        sub_item_table = root_items,
    }
end

return M
