local _ = require("gettext")
local UIManager = require("ui/uimanager")
local DataStorage = require("datastorage")
local SharedState = require("common/shared_state")
local icons = require("common/inline_icon_map")
local IconItem = require("common/ui/icon_menu_item")
local defaults = require("config/defaults")
local LibraryFontPath = require("common/library_font_path")
local status_bar_section = require("modules/settings/sections/library_settings/status_bar_settings")
local settings_apply = require("modules/settings/zen_settings_apply")
local zen_settings_utils = require("modules/settings/zen_settings_utils")
local M = {}
local DEFAULT_LIBRARY_FONT = defaults.library_font.font_face
local LIBRARY_WALLPAPERS_DIR = DataStorage:getFullDataDir() .. "/resources/wallpapers"

local resolved_library_font = LibraryFontPath.resolveConfigured
local font_name_text = LibraryFontPath.nameText
local find_registered_font_file = LibraryFontPath.findRegistered
local picker_default = LibraryFontPath.pickerDefault
local ensure_library_font_cfg = LibraryFontPath.ensureConfig

local function schedule_home_rebuild_on_menu_close(plugin)
    if not plugin or not settings_apply.defer_until_settings_close then return end
    settings_apply.defer_until_settings_close("home_rebuild", function()
        local home = SharedState.get(plugin, "home")
        if home and home.rebuildActive then
            home.rebuildActive()
        end
    end)
end

local function refresh_background_surfaces(plugin)
    local home = SharedState.get(plugin, "home")
    if home and type(home.invalidateNavbar) == "function" then
        home.invalidateNavbar()
    end
    if home and home.rebuildActive then
        home.rebuildActive()
    end

    local stack = UIManager._window_stack
    if type(stack) == "table" then
        for _i, entry in ipairs(stack) do
            local widget = entry and entry.widget
            if widget and widget._zen_bg_applied and type(widget.updateItems) == "function" then
                pcall(widget.updateItems, widget)
                UIManager:setDirty(widget, "full")
            end
        end
    end

    local reinject_navbars = rawget(_G, "__ZEN_UI_REINJECT_NAVBARS")
    if type(reinject_navbars) == "function" then
        reinject_navbars()
    else
        UIManager:setDirty(nil, "full")
        UIManager:forceRePaint()
    end
end

local function schedule_background_surface_refresh(plugin)
    if not plugin or not settings_apply.defer_until_settings_close then return end
    settings_apply.defer_until_settings_close("background_surfaces", function()
        refresh_background_surfaces(plugin)
    end)
end

local function save_library_font(config, plugin, touchmenu_instance, prompt_restart)
    _G.__ZEN_UI_LIBRARY_FONT_CFG = config.library_font
    plugin:saveConfig()
    settings_apply.reinit_filemanager()
    schedule_home_rebuild_on_menu_close(plugin)
    local strip_cfg = type(config.mosaic_title_strip) == "table" and config.mosaic_title_strip or nil
    if prompt_restart or (strip_cfg and (strip_cfg.show_title == true or strip_cfg.show_author == true)) then
        settings_apply.prompt_restart()
    end
    if touchmenu_instance then
        touchmenu_instance:updateItems()
    end
end

local function move_item(items, text, destination)
    for i, item in ipairs(items) do
        if item.text == text then
            table.insert(destination, table.remove(items, i))
            return
        end
    end
end

function M.build(ctx, extras_items)
    local config = ctx.config
    local plugin = ctx.plugin
    local quick_settings_item = require("modules/settings/sections/menu_settings").build(ctx)
    local app_launcher_item = require("modules/settings/sections/app_launcher_settings").build(ctx)
    local navbar_item = require("modules/settings/sections/library_settings/navbar_settings").build(ctx)
    local utils = zen_settings_utils
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
        _("Filled"),
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

    quick_settings_item.text = _("Controls")
    IconItem.decorate(quick_settings_item, icons.settings_quick)
    app_launcher_item.text = _("Launcher")
    IconItem.decorate(app_launcher_item, icons.settings_launcher)
    app_launcher_item._zen_settings_root = "launcher"
    navbar_item.text = _("Navbar")
    local status_bar_item = status_bar_section.build(ctx)
    utils.reorder_nested_items_by_text({ status_bar_item }, _("Status bar"), {
        _("12-hour time"), _("Show bottom border"), _("Bold text"), _("Colored status icons"),
        _("Left items"), _("Center items"), _("Right items"),
    })
    local items = {
        quick_settings_item,
        app_launcher_item,
        IconItem.decorate(navbar_item, icons.settings_navbar),
        IconItem.decorate(status_bar_item, icons.settings_status),
    }
    table.insert(items, {
        text = _("Font"),
        text_func = function()
            local cfg = ensure_library_font_cfg(config)
            local ok_fc, FontChooser = pcall(require, "ui/widget/fontchooser")
            local face_text = (cfg.font_face == "default") and _("default")
                or (ok_fc and font_name_text(cfg, FontChooser) or cfg.font_face)
            return string.format("%s %s, %s", _("Font:"), face_text, tostring(cfg.font_size))
        end,
        sub_item_table = {
            {
                text_func = function()
                    local cfg = ensure_library_font_cfg(config)
                    return string.format("%s %s", _("Font size:"), tostring(cfg.font_size))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local cfg = ensure_library_font_cfg(config)
                    UIManager:show(SpinWidget:new{
                        title_text = _("Font size"),
                        value = cfg.font_size,
                        value_min = 10,
                        value_max = 40,
                        default_value = 18,
                        callback = function(spin)
                            cfg.font_size = math.max(10, math.min(40, spin.value))
                            save_library_font(config, plugin, touchmenu_instance)
                        end,
                    })
                end,
            },
            {
                _zen_search_text = _("Font"),
                text_func = function()
                    local cfg = ensure_library_font_cfg(config)
                    local ok_fc, FontChooser = pcall(require, "ui/widget/fontchooser")
                    local face_text = (cfg.font_face == "default") and _("default")
                        or (ok_fc and font_name_text(cfg, FontChooser) or cfg.font_face)
                    return string.format("%s %s", _("Font:"), face_text)
                end,
                keep_menu_open = true,
                _zen_search_skip_children = true,
                sub_item_table_func = function(touchmenu_instance)
                    local ok_fc, FontChooser = pcall(require, "ui/widget/fontchooser")
                    if not ok_fc then return {} end
                    local cfg = ensure_library_font_cfg(config)
                    local default_config, default_file = picker_default(FontChooser)
                    local display_face = cfg.font_face == "default"
                        and default_file or resolved_library_font(cfg.font_face)
                    if type(FontChooser.isFontRegistered) == "function"
                            and not FontChooser.isFontRegistered(display_face) then
                        local registered_face = find_registered_font_file(display_face)
                        if registered_face then
                            display_face = registered_face
                        else
                            cfg.font_face = default_config
                            display_face = default_file
                            save_library_font(config, plugin, touchmenu_instance)
                        end
                    end
                    if not display_face then return {} end
                    local FontList = require("fontlist")
                    local Font = require("ui/font")
                    local font_items = {
                        open_on_menu_item_id_func = function() return display_face end,
                    }
                    for file in pairs(FontList.fontinfo) do
                        local name_text, name = FontChooser.getFontNameText(file)
                        font_items[#font_items + 1] = {
                            text = (name_text or file) .. (file == default_file and "  ★" or ""),
                            font_name = name or name_text or file,
                            menu_item_id = file,
                            radio = true,
                            checked_func = function() return display_face == file end,
                            font_func = function(size) return Font:getFace(file, size) end,
                            keep_menu_open = true,
                            callback = function()
                                local portable_file = LibraryFontPath.toConfig(file)
                                if cfg.font_face ~= portable_file then
                                    cfg.font_face = portable_file
                                    display_face = file
                                    save_library_font(config, plugin, touchmenu_instance, true)
                                end
                            end,
                            hold_callback = function()
                                local InfoMessage = require("ui/widget/infomessage")
                                UIManager:show(InfoMessage:new{ text = file, show_icon = false })
                            end,
                        }
                    end
                    local ffiUtil = require("ffi/util")
                    table.sort(font_items, function(a, b)
                        if a.font_name ~= b.font_name then
                            return ffiUtil.strcoll(a.font_name, b.font_name)
                        end
                        return ffiUtil.strcoll(a.text, b.text)
                    end)
                    return font_items
                end,
                hold_callback = function()
                    local cfg = ensure_library_font_cfg(config)
                    local font_file = resolved_library_font(cfg.font_face)
                    local InfoMessage = require("ui/widget/infomessage")
                    UIManager:show(InfoMessage:new{ text = font_file, show_icon = false })
                end,
            },
            {
                text = _("Reset font"),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local ConfirmBox = require("ui/widget/confirmbox")
                    UIManager:show(ConfirmBox:new{
                        text = _("Reset font family and size to default?"),
                        ok_text = _("Reset"),
                        ok_callback = function()
                            local cfg = ensure_library_font_cfg(config)
                            local changed = cfg.font_face ~= DEFAULT_LIBRARY_FONT or cfg.font_size ~= 18
                            if changed then
                                cfg.font_face = DEFAULT_LIBRARY_FONT
                                cfg.font_size = 18
                                save_library_font(config, plugin, touchmenu_instance, true)
                            end
                        end,
                    })
                end,
            },
        },
    })

    IconItem.decorate(items[#items], icons.title)
    move_item(extras_items, _("Zen Keyboard"), items)

    local function ensure_lib_bg()
        if type(config.library_background) ~= "table" then config.library_background = {} end
        if config.library_background.enabled == nil then
            config.library_background.enabled = false
        end
        if type(config.library_background.path) ~= "string" then
            config.library_background.path = ""
        end
        local opacity = tonumber(config.library_background.opacity)
        if not opacity then
            config.library_background.opacity = 100
        else
            config.library_background.opacity = math.max(0,
                math.min(100, math.floor(opacity + 0.5)))
        end
        return config.library_background
    end
    local function lib_bg_path()
        return ensure_lib_bg().path
    end
    local function save_lib_bg()
        plugin:saveConfig()
        require("common/ui/background").clearCache()
        settings_apply.reinit_filemanager_on_menu_close()
        schedule_background_surface_refresh(plugin)
    end
    local function set_lib_bg(path)
        ensure_lib_bg().path = path or ""
        save_lib_bg()
    end
    local function lib_bg_error_text(code)
        if code == "missing" then
            return _("Background image file not found.")
        elseif code == "no_decoder" then
            return _("Image support is unavailable on this device.")
        elseif code == "unsupported" or code == "decode_failed" then
            return _("Background image could not be loaded. It may be corrupt or unsupported.")
        end
        return _("No background image selected.")
    end
    local function lib_bg_start_path()
        local path = lib_bg_path()
        if path ~= "" then
            local util = require("util")
            local dir = select(1, util.splitFilePathName(path))
            if type(dir) == "string" and dir ~= "" then
                return dir
            end
        end
        return LIBRARY_WALLPAPERS_DIR
    end

    table.insert(items, {
        text = _("Wallpaper"),
        checked_func = function()
            return ensure_lib_bg().enabled == true
        end,
        checkmark_callback = function(touchmenu_instance)
            local bg = ensure_lib_bg()
            if bg.enabled ~= true then
                -- Enabling: only allow if the image actually works.
                local bg_mod = require("common/ui/background")
                local ok_img, reason = bg_mod.validateImage(bg.path)
                if not ok_img then
                    bg.enabled = false
                    local InfoMessage = require("ui/widget/infomessage")
                    UIManager:show(InfoMessage:new{
                        text = lib_bg_error_text(reason),
                    })
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                    return
                end
                bg.enabled = true
            else
                bg.enabled = false
            end
            save_lib_bg()
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
        sub_item_table = {
            {
                text_func = function()
                    local path = lib_bg_path()
                    if path == "" then return _("Image: none") end
                    local util = require("util")
                    local name = select(2, util.splitFilePathName(path))
                    return _("Image: ") .. (name ~= "" and name or path)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    UIManager:show(zen_settings_utils.newImagePathChooser{
                        select_file = true,
                        select_directory = false,
                        show_files = true,
                        path = lib_bg_start_path(),
                        goHome = function(chooser)
                            chooser:changeToPath(LIBRARY_WALLPAPERS_DIR)
                            return true
                        end,
                        onConfirm = function(file_path)
                            local bg_mod = require("common/ui/background")
                            local ok_img, reason = bg_mod.validateImage(file_path)
                            if not ok_img then
                                local InfoMessage = require("ui/widget/infomessage")
                                UIManager:show(InfoMessage:new{
                                    text = lib_bg_error_text(reason),
                                })
                                return
                            end
                            set_lib_bg(file_path)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end,
                hold_callback = function(touchmenu_instance)
                    if lib_bg_path() ~= "" then
                        set_lib_bg("")
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end
                end,
            },
            {
                text_func = function()
                    return string.format("%s: %d%%", _("Opacity"),
                        ensure_lib_bg().opacity)
                end,
                enabled_func = function()
                    return ensure_lib_bg().enabled == true
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local bg = ensure_lib_bg()
                    zen_settings_utils.show_value_picker(
                        _("Wallpaper") .. " - " .. _("Opacity"), bg.opacity,
                        function(value)
                            bg.opacity = math.max(0,
                                math.min(100, math.floor(value + 0.5)))
                            save_lib_bg()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end, 0, 100)
                end,
            },
            {
                text = _("Invert with dark mode"),
                checked_func = function()
                    return ensure_lib_bg().invert_with_dark_mode ~= false
                end,
                callback = function()
                    local bg = ensure_lib_bg()
                    bg.invert_with_dark_mode = bg.invert_with_dark_mode == false
                    save_lib_bg()
                end,
            },
        },
    })

    IconItem.decorate(items[#items], icons.settings_background)
    move_item(extras_items, _("Custom icons"), items)
    move_item(quick_settings_item.sub_item_table, _("Blur menu background"), items)
    move_item(extras_items, _("Zen Search"), items)
    return IconItem.decorate({
        text = _("Interface"),
        sub_item_table = items,
        _zen_settings_root = "interface",
    }, icons.settings_global)
end

return M
