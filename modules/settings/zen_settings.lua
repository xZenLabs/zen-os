local _ = require("gettext")
local UIManager = require("ui/uimanager")

local settings_apply = require("modules/settings/zen_settings_apply")
local updater        = require("modules/settings/zen_updater")
local icons          = require("common/inline_icon_map")
local IconItem       = require("common/ui/icon_menu_item")
local utils          = require("modules/settings/zen_settings_utils")

local lib_section      = require("modules/settings/sections/library_settings")
local home_section = require("modules/settings/sections/library_settings/home_settings")
local navbar_section   = require("modules/settings/sections/library_settings/navbar_settings")
local menu_section     = require("modules/settings/sections/menu_settings")
local app_launcher_section = require("modules/settings/sections/app_launcher_settings")
local reader_section   = require("modules/settings/sections/reader_settings")
local extras_section   = require("modules/settings/sections/extras_settings")
local about_section    = require("modules/settings/sections/about_settings")
local updates_section  = require("modules/settings/sections/updates_settings")
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

    local navbar_item          = navbar_section.build(ctx)
    local filebrowser_items    = lib_section.build(ctx)
    local home_item       = home_section.build(ctx)
    local quick_settings_item  = menu_section.build(ctx)
    local app_launcher_item = app_launcher_section.build(ctx)
    local reader_items         = reader_section.build(ctx)
    local extras_items      = extras_section.build(ctx)
    local general_items     = about_section.build(ctx)
    local updates_items     = updates_section.build(ctx)

    table.insert(general_items, IconItem.decorate({
        text = _("Quit KOReader"),
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

    -- -------------------------------------------------------------------------
    -- Item ordering
    -- -------------------------------------------------------------------------

    filebrowser_items = utils.order_items_by_text(filebrowser_items, {
        _("Display mode"),
        _("Items per page"),
        _("Sort by"),
        _("Status bar"),
    })

    utils.reorder_nested_items_by_text(filebrowser_items, _("Status bar"), {
        _("12-hour time"),
        _("Show bottom border"),
        _("Bold text"),
        _("Colored status icons"),
        _("Left items"),
        _("Center items"),
        _("Right items"),
    })

    utils.reorder_nested_items_by_text({ navbar_item }, _("Navbar"), {
        _("Tabs") .. " \u{25B8}",
        _("Styling"),
        _("Default tab: "),
    })

    utils.reorder_nested_items_by_text({ navbar_item }, _("Styling"), {
        _("Labels"),
        _("Icons"),
        _("Active tab"),
        _("Show top border"),
    })

    utils.reorder_nested_items_by_text({ navbar_item }, _("Active tab"), {
        _("Underline"),
        _("Underline above icon"),
        _("Colored"),
        _("Active tab color"),
    })

    utils.reorder_nested_items_by_text({ navbar_item }, _("Labels"), {
        _("Show labels"),
        _("Label size:"),
    })

    utils.reorder_nested_items_by_text({ navbar_item }, _("Icons"), {
        _("Show icons"),
        _("Icon size:"),
    })

    -- -------------------------------------------------------------------------
    -- Root menu assembly
    -- -------------------------------------------------------------------------

    quick_settings_item.text = _("Controls")
    IconItem.decorate(quick_settings_item, icons.settings_quick)
    app_launcher_item.text = _("Launcher")
    IconItem.decorate(app_launcher_item, icons.settings_launcher)
    app_launcher_item._zen_settings_root = "launcher"
    home_item.text = _("Home")
    IconItem.decorate(home_item, icons.settings_home)
    navbar_item.text = _("Navbar")

    local library_item = IconItem.decorate({
        text = _("Library"),
        sub_item_table = filebrowser_items,
        _zen_settings_root = "library",
    }, icons.settings_library)

    local root_items = {
        quick_settings_item,
        app_launcher_item,
        home_item,
        library_item,
        IconItem.decorate(navbar_item, icons.settings_navbar),
        IconItem.decorate({ text = _("Reader"), sub_item_table = reader_items }, icons.settings_reader),
        IconItem.decorate({ text = _("Extras"), sub_item_table = extras_items }, icons.fav_add),
        IconItem.decorate({ text = _("Updates"), sub_item_table = updates_items }, icons.upgrade),
        IconItem.decorate({
            text = _("About"),
            sub_item_table = general_items,
        }, icons.settings_about),
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
