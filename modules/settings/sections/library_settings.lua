-- settings/sections/library_settings.lua
-- Library (filebrowser) settings items for ZenOS.
-- Receives ctx: { plugin, config, save_and_apply, apply_feature }

local _ = require("gettext")
local UIManager = require("ui/uimanager")
local paths = require("common/paths")
local SharedState = require("common/shared_state")
local icons = require("common/inline_icon_map")
local IconItem = require("common/ui/icon_menu_item")
local defaults = require("config/defaults")
local LibraryFontPath = require("common/library_font_path")

local metadata_section    = require("modules/settings/sections/library_settings/metadata_settings")
local settings_apply      = require("modules/settings/zen_settings_apply")
local zen_settings_utils  = require("modules/settings/zen_settings_utils")

local M = {}
local BOOK_DETAIL_ORDER = defaults.book_details.order
local BOOK_DETAIL_TEXT_STYLE_DEFAULTS = defaults.book_details.text_styles

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

function M.build(ctx)
    local config        = ctx.config
    local plugin        = ctx.plugin
    local save_and_apply = ctx.save_and_apply
    local refresh_filechooser

    local function fbc()
        if type(config.browser_folder_cover) ~= "table" then
            config.browser_folder_cover = {}
        end
        return config.browser_folder_cover
    end
    local function rebuild_filechooser()
        local ui = require("apps/filemanager/filemanager").instance
        if ui and ui.file_chooser then ui.file_chooser:updateItems() end
    end
    local function save_fbc_and_update()
        plugin:saveConfig()
        rebuild_filechooser()
        schedule_home_rebuild_on_menu_close(plugin)
    end
    local function get_home_lock_mode()
        local cfg = config.browser_hide_up_folder
        local mode = type(cfg) == "table" and cfg.lock_home_folder
        if mode == "off" or mode == "zen" or mode == "on" then
            return mode
        end
        return "zen"
    end
    local function set_home_lock_mode(mode)
        if type(config.browser_hide_up_folder) ~= "table" then
            config.browser_hide_up_folder = {}
        end
        config.browser_hide_up_folder.lock_home_folder = mode
        G_reader_settings:saveSetting("lock_home_folder", mode == "on")
        plugin:saveConfig()
        refresh_filechooser()
    end

    local appearance_items = {}
    local book_items = {}
    -- -------------------------------------------------------------------------
    -- Folders
    -- -------------------------------------------------------------------------

    local function save_and_refresh_series_grouping()
        plugin:saveConfig()
        local home = SharedState.get(plugin, "home")
        if home and type(home.invalidateLibraryCache) == "function" then
            home.invalidateLibraryCache()
        end
        local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
        local fc = ok_fm and FileManager and FileManager.instance
            and FileManager.instance.file_chooser
        if fc and fc._zen_clear_item_table_cache then
            fc:_zen_clear_item_table_cache()
        end
        if fc and fc.path and fc.changeToPath then
            fc:changeToPath(fc.path)
        else
            save_and_apply("automatic_series_grouping")
        end
    end

    local function build_series_items()
        local sub_items = {
            {
                text = _("Group book series into folders"),
                checked_func = function()
                    return config.features.automatic_series_grouping ~= false
                end,
                callback = function(touchmenu_instance)
                    config.features.automatic_series_grouping =
                        config.features.automatic_series_grouping == false
                    save_and_refresh_series_grouping()
                    if touchmenu_instance then
                        touchmenu_instance.item_table = build_series_items()
                    end
                end,
            },
        }
        if config.features.automatic_series_grouping ~= false then
            sub_items[#sub_items + 1] = {
                text = _("Hide grouped series"),
                checked_func = function()
                    return config.features.hide_grouped_series == true
                end,
                callback = function()
                    config.features.hide_grouped_series =
                        config.features.hide_grouped_series ~= true
                    save_and_refresh_series_grouping()
                end,
            }
        end
        return sub_items
    end

    local folders_item = {
        text = _("Folders"),
        sub_item_table = {
            -- Cover mode subsection
            IconItem.decorate({
                text = _("Covers"),
                sub_item_table = {
                    {
                        text = _("Gallery"),
                        radio = true,
                        checked_func = function() return fbc().cover_mode == "gallery" end,
                        callback = function()
                            fbc().cover_mode = "gallery"
                            save_fbc_and_update()
                        end,
                    },
                    {
                        text = _("First cover image"),
                        radio = true,
                        checked_func = function() return fbc().cover_mode == "normal" end,
                        callback = function()
                            fbc().cover_mode = "normal"
                            save_fbc_and_update()
                        end,
                    },
                    {
                        text = _("Stack"),
                        radio = true,
                        checked_func = function() return fbc().cover_mode == "stack" end,
                        callback = function()
                            fbc().cover_mode = "stack"
                            save_fbc_and_update()
                        end,
                    },
                    {
                        text = _("None (folder name only)"),
                        radio = true,
                        checked_func = function() return fbc().cover_mode == "none" end,
                        callback = function()
                            fbc().cover_mode = "none"
                            save_fbc_and_update()
                        end,
                    },
                    {
                        text = _("Show spine lines"),
                        checked_func = function() return fbc().show_spine_lines ~= false end,
                        callback = function()
                            fbc().show_spine_lines = fbc().show_spine_lines == false
                            save_fbc_and_update()
                        end,
                    },
                    {
                        text = _("Show item count"),
                        checked_func = function() return fbc().show_item_count ~= false end,
                        callback = function()
                            fbc().show_item_count = fbc().show_item_count == false
                            save_fbc_and_update()
                        end,
                    },
                },
            }, icons.settings_covers),
            IconItem.decorate({
                text = _("Series"),
                sub_item_table_func = build_series_items,
            }, icons.series),
            -- Folder name subsection
            IconItem.decorate({
                text = _("Folder name"),
                sub_item_table = {
                    {
                        text = _("Opaque background"),
                        checked_func = function() return fbc().name_opaque == true end,
                        callback = function()
                            fbc().name_opaque = fbc().name_opaque ~= true
                            save_fbc_and_update()
                        end,
                    },
                    {
                        text = _("Folder name position"),
                        sub_item_table = {
                            {
                                text = _("Center"),
                                radio = true,
                                checked_func = function() return fbc().name_centered == true end,
                                callback = function()
                                    fbc().name_centered = true
                                    save_fbc_and_update()
                                end,
                            },
                            {
                                text = _("Bottom"),
                                radio = true,
                                checked_func = function() return fbc().name_centered ~= true end,
                                callback = function()
                                    fbc().name_centered = false
                                    save_fbc_and_update()
                                end,
                            },
                        },
                    },
                    {
                        text = _("Show folder name"),
                        checked_func = function() return fbc().show_folder_name ~= false end,
                        callback = function()
                            fbc().show_folder_name = fbc().show_folder_name == false
                            save_fbc_and_update()
                        end,
                    },
                },
            }, icons.settings_folder_name),
        },
    }

    table.insert(appearance_items, {
        text = _("Covers"),
        sub_item_table = {
            {
                text = _("Badges"),
                sub_item_table = {
                    {
                        text = _("Badge size"),
                        sub_item_table = (function()
                            local sizes = {
                                { label = _("Compact"),     value = "compact"     },
                                { label = _("Normal"),      value = "normal"      },
                                { label = _("Large"),       value = "large"       },
                                { label = _("Extra large"), value = "extra_large" },
                            }
                            local badge_size_items = {}
                            for _i, sz in ipairs(sizes) do
                                local v = sz.value
                                table.insert(badge_size_items, {
                                    text = sz.label,
                                    radio = true,
                                    checked_func = function()
                                        local cur = type(config.browser_cover_badges) == "table"
                                            and config.browser_cover_badges.badge_size
                                        return (cur or "compact") == v
                                    end,
                                    callback = function()
                                        if type(config.browser_cover_badges) ~= "table" then
                                            config.browser_cover_badges = {}
                                        end
                                        config.browser_cover_badges.badge_size = v
                                        plugin:saveConfig()
                                        UIManager:setDirty(nil, "full")
                                    end,
                                })
                            end
                            return badge_size_items
                        end)(),
                    },
                    zen_settings_utils.buildColorSubMenu({
                        label        = _("Badge color: "),
                        get          = function()
                            local c = type(config.browser_cover_badges) == "table"
                                and config.browser_cover_badges.badge_color
                            return type(c) == "table" and c or nil
                        end,
                        set          = function(r, g, b)
                            if type(config.browser_cover_badges) ~= "table" then
                                config.browser_cover_badges = {}
                            end
                            config.browser_cover_badges.badge_color = { r, g, b }
                            plugin:saveConfig()
                            UIManager:setDirty(nil, "full")
                        end,
                        reset        = function()
                            if type(config.browser_cover_badges) == "table" then
                                config.browser_cover_badges.badge_color = nil
                            end
                            plugin:saveConfig()
                            UIManager:setDirty(nil, "full")
                        end,
                        default_text = _("Default"),
                        reset_text   = _("Default (black)"),
                        dialog_title = _("Badge color RGB"),
                        presets = {
                            { text = _("Black"), r = 0,    g = 0,    b = 0    },
                            { text = _("White"), r = 255,  g = 255,  b = 255  },
                            { text = _("Gray"),  r = 204,  g = 204,  b = 204  },
                            { text = _("Blue"),  r = 0x99, g = 0xBB, b = 0xF0 },
                            { text = _("Green"), r = 0x99, g = 0xCC, b = 0x99 },
                            { text = _("Amber"), r = 0xF0, g = 0xD0, b = 0x80 },
                            { text = _("Red"),   r = 0xDD, g = 0x99, b = 0x99 },
                        },
                    }),
                    {
                        text = _("Show page count"),
                        checked_func = function()
                            return type(config.browser_page_count) == "table"
                                and config.browser_page_count.show_page_count == true
                        end,
                        callback = function()
                            if type(config.browser_page_count) ~= "table" then
                                config.browser_page_count = {}
                            end
                            config.browser_page_count.show_page_count =
                                config.browser_page_count.show_page_count ~= true
                            plugin:saveConfig()
                            rebuild_filechooser()
                        end,
                    },
                    {
                        text = _("Show series number on covers"),
                        checked_func = function()
                            return type(config.browser_series_badge) == "table"
                                and config.browser_series_badge.show_series_badge == true
                        end,
                        callback = function()
                            if type(config.browser_series_badge) ~= "table" then
                                config.browser_series_badge = {}
                            end
                            config.browser_series_badge.show_series_badge =
                                config.browser_series_badge.show_series_badge ~= true
                            plugin:saveConfig()
                            rebuild_filechooser()
                        end,
                    },
                    {
                        text = _("Show favorite badge"),
                        checked_func = function()
                            return type(config.browser_cover_badges) == "table"
                                and config.browser_cover_badges.show_favorite_badge == true
                        end,
                        callback = function()
                            if type(config.browser_cover_badges) ~= "table" then
                                config.browser_cover_badges = {}
                            end
                            config.browser_cover_badges.show_favorite_badge =
                                config.browser_cover_badges.show_favorite_badge ~= true
                            plugin:saveConfig()
                            rebuild_filechooser()
                        end,
                    },
                    {
                        text = _("Show new banner"),
                        checked_func = function()
                            return type(config.browser_cover_badges) == "table"
                                and config.browser_cover_badges.show_new_banner == true
                        end,
                        callback = function()
                            if type(config.browser_cover_badges) ~= "table" then
                                config.browser_cover_badges = {}
                            end
                            config.browser_cover_badges.show_new_banner =
                                config.browser_cover_badges.show_new_banner ~= true
                            plugin:saveConfig()
                            UIManager:setDirty(nil, "full")
                        end,
                    },
                    {
                        text = _("Show progress bar"),
                        checked_func = function()
                            return type(config.browser_cover_badges) == "table"
                                and config.browser_cover_badges.show_native_progress_bar == true
                        end,
                        callback = function()
                            if type(config.browser_cover_badges) ~= "table" then
                                config.browser_cover_badges = {}
                            end
                            config.browser_cover_badges.show_native_progress_bar =
                                config.browser_cover_badges.show_native_progress_bar ~= true
                            plugin:saveConfig()
                            UIManager:setDirty(nil, "full")
                        end,
                    },
                    {
                        text = _("Show reading progress"),
                        checked_func = function()
                            return type(config.browser_cover_badges) == "table"
                                and config.browser_cover_badges.show_mosaic_progress == true
                        end,
                        callback = function()
                            if type(config.browser_cover_badges) ~= "table" then
                                config.browser_cover_badges = {}
                            end
                            config.browser_cover_badges.show_mosaic_progress =
                                config.browser_cover_badges.show_mosaic_progress ~= true
                            plugin:saveConfig()
                            UIManager:setDirty(nil, "full")
                        end,
                    },
                },
            },
            {
                text = _("Uniform covers"),
                checked_func = function()
                    return type(config.features) == "table"
                        and config.features.browser_cover_mosaic_uniform == true
                end,
                checkmark_callback = function()
                    if type(config.features) ~= "table" then config.features = {} end
                    config.features.browser_cover_mosaic_uniform =
                        config.features.browser_cover_mosaic_uniform ~= true
                    plugin:saveConfig()
                    settings_apply.prompt_restart()
                end,
                sub_item_table = {
                    {
                        text = "2:3 " .. _("(standard)"),
                        radio = true,
                        checked_func = function()
                            return config.uniform_cover_ratio ~= "3:4"
                        end,
                        callback = function()
                            config.uniform_cover_ratio = "2:3"
                            plugin:saveConfig()
                            local ui = require("apps/filemanager/filemanager").instance
                            if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                        end,
                    },
                    {
                        text = "3:4 " .. _("(Kindle)"),
                        radio = true,
                        checked_func = function()
                            return config.uniform_cover_ratio == "3:4"
                        end,
                        callback = function()
                            config.uniform_cover_ratio = "3:4"
                            plugin:saveConfig()
                            local ui = require("apps/filemanager/filemanager").instance
                            if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                        end,
                    },
                },
            },
            {
                text = _("Dim finished books"),
                checked_func = function()
                    return type(config.browser_cover_badges) == "table"
                        and config.browser_cover_badges.dim_finished_books == true
                end,
                callback = function()
                    if type(config.browser_cover_badges) ~= "table" then
                        config.browser_cover_badges = {}
                    end
                    config.browser_cover_badges.dim_finished_books =
                        config.browser_cover_badges.dim_finished_books ~= true
                    plugin:saveConfig()
                    local ui = require("apps/filemanager/filemanager").instance
                    if ui and ui.file_chooser then ui.file_chooser:updateItems() end
                    UIManager:setDirty(nil, "full")
                end,
            },
            {
                text = _("Rounded cover corners"),
                checked_func = function()
                    return type(config.features) == "table"
                        and config.features.browser_cover_rounded_corners == true
                end,
                callback = function()
                    if type(config.features) ~= "table" then config.features = {} end
                    config.features.browser_cover_rounded_corners =
                        config.features.browser_cover_rounded_corners ~= true
                    plugin:saveConfig()
                    rebuild_filechooser()
                    schedule_home_rebuild_on_menu_close(plugin)
                end,
            },
            {
                text = _("Show title below cover (mosaic)"),
                checked_func = function()
                    return type(config.mosaic_title_strip) == "table"
                        and config.mosaic_title_strip.show_title == true
                end,
                callback = function()
                    if type(config.mosaic_title_strip) ~= "table" then
                        config.mosaic_title_strip = {}
                    end
                    config.mosaic_title_strip.show_title =
                        config.mosaic_title_strip.show_title ~= true
                    plugin:saveConfig()
                    rebuild_filechooser()
                end,
            },
            {
                text = _("Show author below cover (mosaic)"),
                checked_func = function()
                    return type(config.mosaic_title_strip) == "table"
                        and config.mosaic_title_strip.show_author == true
                end,
                callback = function()
                    if type(config.mosaic_title_strip) ~= "table" then
                        config.mosaic_title_strip = {}
                    end
                    config.mosaic_title_strip.show_author =
                        config.mosaic_title_strip.show_author ~= true
                    plugin:saveConfig()
                    rebuild_filechooser()
                end,
            },
        },
    })

    -- -------------------------------------------------------------------------
    -- Layout density
    -- -------------------------------------------------------------------------

    local function get_bim()
        local ok, bim = pcall(require, "bookinfomanager")
        return ok and bim or nil
    end
    local function get_fc()
        local ok, FM = pcall(require, "apps/filemanager/filemanager")
        local fm = ok and FM and FM.instance
        return fm and fm.file_chooser or nil
    end
    local function layout_value(key, default)
        local bim, fc = get_bim(), get_fc()
        return (fc and fc[key]) or (bim and bim:getSetting(key)) or default
    end
    local function save_layout(values, touchmenu_instance)
        local bim = get_bim()
        if not bim then return end
        local fc = get_fc()
        local ok, fc_class = pcall(require, "ui/widget/filechooser")
        for key, value in pairs(values) do
            bim:saveSetting(key, value)
            if fc then fc[key] = value end
            if ok then fc_class[key] = value end
        end
        if fc then fc:updateItems() end
        if touchmenu_instance then touchmenu_instance:updateItems() end
    end
    local mosaic_items = {}
    for _i, orientation in ipairs({ "portrait", "landscape" }) do
        local portrait = orientation == "portrait"
        local cols_key, rows_key = "nb_cols_" .. orientation, "nb_rows_" .. orientation
        local default_cols, default_rows = portrait and 3 or 4, portrait and 3 or 2
        mosaic_items[#mosaic_items + 1] = {
            text = portrait and _("Portrait") or _("Landscape"),
            text_func = function()
                return (portrait and _("Portrait") or _("Landscape")) .. ": "
                    .. layout_value(cols_key, default_cols) .. " × " .. layout_value(rows_key, default_rows)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(require("common/ui/mosaic_layout_dialog").new{
                    title = portrait and _("Portrait mosaic mode") or _("Landscape mosaic mode"),
                    portrait = portrait,
                    columns = layout_value(cols_key, default_cols), rows = layout_value(rows_key, default_rows),
                    callback = function(columns, rows)
                        save_layout({ [cols_key] = columns, [rows_key] = rows }, touchmenu_instance)
                    end,
                })
            end,
        }
    end
    mosaic_items[#mosaic_items + 1] = {
        text = _("Reset to default"),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            save_layout({ nb_cols_portrait = 3, nb_rows_portrait = 3,
                nb_cols_landscape = 4, nb_rows_landscape = 2 }, touchmenu_instance)
        end,
    }
    local list_items = {
        {
            text = _("Items per page"),
            text_func = function()
                return _("Items per page") .. ": " .. math.min(layout_value("files_per_page", 5),
                    require("common/cover_utils").MAX_FILES_PER_PAGE)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local max_fpp = require("common/cover_utils").MAX_FILES_PER_PAGE
                UIManager:show(require("ui/widget/spinwidget"):new{
                    title_text = _("Items per page"), value = math.min(layout_value("files_per_page", 5), max_fpp),
                    value_min = 4, value_max = max_fpp, default_value = 5,
                    callback = function(spin) save_layout({ files_per_page = spin.value }, touchmenu_instance) end,
                })
            end,
        },
    }
    local ListFields = require("common/library_list_fields")
    local list_labels = {
        title = _("Title"), filename = _("Filename"), authors = _("Authors"), series = _("Series"),
        tags = _("Tags"), pages = _("Pages"), filetype = _("File type"), read_status = _("Read status"),
        language = _("Language"), file_size = _("File size"),
    }
    local function show_detailed_items()
        if type(config.browser_list_item_layout) ~= "table" then config.browser_list_item_layout = {} end
        local cfg = config.browser_list_item_layout
        if type(cfg.show) ~= "table" then cfg.show = {} end
        local sort_items = {}
        for _i, id in ipairs(ListFields.order(cfg)) do
            sort_items[#sort_items + 1] = {
                text = list_labels[id], orig_item = id,
                checked_func = function() return ListFields.enabled(cfg, id) end,
                callback = function()
                    cfg.show[id] = not ListFields.enabled(cfg, id)
                    plugin:saveConfig()
                    rebuild_filechooser()
                end,
            }
        end
        require("common/ui/zen_arrange_list").show{
            title = _("Detailed list items"), item_table = sort_items, plugin = plugin,
            callback = function()
                local order = {}
                for _i, item in ipairs(sort_items) do order[#order + 1] = item.orig_item end
                cfg.order = order
                plugin:saveConfig()
                rebuild_filechooser()
            end,
        }
    end
    list_items[#list_items + 1] = IconItem.decorate({
        text = _("Detailed list items"), _zen_settings_submenu = true, keep_menu_open = true,
        _zen_search_items_func = function()
            local search_items = {}
            for _i, id in ipairs(ListFields.order()) do
                search_items[#search_items + 1] = { text = list_labels[id], _zen_search_open = show_detailed_items }
            end
            return search_items
        end,
        callback = show_detailed_items,
    }, icons.details)

    refresh_filechooser = function(clear_cache)
        local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
        local fm = ok and FileManager and FileManager.instance
        if fm and fm.file_chooser and type(fm.file_chooser.refreshPath) == "function" then
            if clear_cache and fm.file_chooser._zen_clear_item_table_cache then
                fm.file_chooser:_zen_clear_item_table_cache()
            end
            pcall(fm.file_chooser.refreshPath, fm.file_chooser)
        end
    end

    -- -------------------------------------------------------------------------
    -- Scroll bar style
    -- -------------------------------------------------------------------------

    local scroll_bar_styles = {
        { text = _("Bar"),         style = "bar"         },
        { text = _("Dots"),        style = "dots"        },
        { text = _("Page number"), style = "page_number" },
    }

    local function get_scroll_bar_style()
        return (type(config.zen_scroll_bar) == "table" and config.zen_scroll_bar.style) or "page_number"
    end

    local scroll_bar_sub_items = {}
    for _i, entry in ipairs(scroll_bar_styles) do
        table.insert(scroll_bar_sub_items, {
            text = entry.text,
            checked_func = function() return get_scroll_bar_style() == entry.style end,
            radio = true,
            callback = function()
                if type(config.zen_scroll_bar) ~= "table" then config.zen_scroll_bar = {} end
                config.zen_scroll_bar.style = entry.style
                plugin:saveConfig()
                UIManager:setDirty(nil, "ui")
                -- Footer height differs between page_number and other styles;
                -- reinit rebuilds the menu with the correct height and touch zones.
                settings_apply.reinit_filemanager()
            end,
        })
    end

    local page_number_item = scroll_bar_sub_items[3]
    page_number_item.checkmark_callback = page_number_item.callback

    -- Page number format
    local pn_formats = {
        { text = _("Current only"), fmt = "current" },
        { text = _("Page x / y"),   fmt = "total"   },
    }
    local function get_pn_format()
        return (type(config.zen_scroll_bar) == "table"
            and config.zen_scroll_bar.page_number_format) or "current"
    end
    local pn_format_sub_items = {}
    for _i, entry in ipairs(pn_formats) do
        table.insert(pn_format_sub_items, {
            text = entry.text,
            checked_func = function() return get_pn_format() == entry.fmt end,
            radio = true,
            callback = function()
                if type(config.zen_scroll_bar) ~= "table" then config.zen_scroll_bar = {} end
                config.zen_scroll_bar.page_number_format = entry.fmt
                plugin:saveConfig()
                UIManager:setDirty(nil, "ui")
            end,
        })
    end
    -- Hold to skip
    local hold_skip_opts = {
        { text = _("Skip 10 pages"),   skip = "10"   },
        { text = _("Skip 20 pages"),   skip = "20"   },
        { text = _("Beginning / End"), skip = "ends" },
    }
    local function get_hold_skip()
        return (type(config.zen_scroll_bar) == "table"
            and config.zen_scroll_bar.hold_skip) or "10"
    end
    local hold_skip_sub_items = {}
    for _i, entry in ipairs(hold_skip_opts) do
        table.insert(hold_skip_sub_items, {
            text = entry.text,
            checked_func = function() return get_hold_skip() == entry.skip end,
            radio = true,
            callback = function()
                if type(config.zen_scroll_bar) ~= "table" then config.zen_scroll_bar = {} end
                config.zen_scroll_bar.hold_skip = entry.skip
                plugin:saveConfig()
                UIManager:setDirty(nil, "ui")
            end,
        })
    end
    page_number_item.sub_item_table = {
        { text = _("Page number format"), sub_item_table = pn_format_sub_items },
        { text = _("Hold to skip"), sub_item_table = hold_skip_sub_items },
    }

    table.insert(appearance_items, {
        text = _("Scroll bar"),
        sub_item_table = scroll_bar_sub_items,
    })

    -- -------------------------------------------------------------------------
    -- Layout
    -- -------------------------------------------------------------------------

    local layout_items = {
        IconItem.decorate({ text = _("Mosaic"), sub_item_table = mosaic_items }, icons.view_mosaic),
        IconItem.decorate({ text = _("List"), sub_item_table = list_items }, icons.view_list),
    }
    table.insert(layout_items, IconItem.decorate({
        text = _("Show item underline"),
        checked_func = function()
            return config.features.browser_hide_underline ~= true
        end,
        callback = function()
            config.features.browser_hide_underline = config.features.browser_hide_underline ~= true
            save_and_apply("browser_hide_underline")
        end,
    }, icons.settings_underline))
    table.insert(list_items, {
        text = _("Hide list borders"),
        checked_func = function()
            return type(config.browser_list_item_layout) == "table"
                and config.browser_list_item_layout.hide_list_borders == true
        end,
        callback = function()
            if type(config.browser_list_item_layout) ~= "table" then
                config.browser_list_item_layout = {}
            end
            config.browser_list_item_layout.hide_list_borders =
                config.browser_list_item_layout.hide_list_borders ~= true
            plugin:saveConfig()
            -- updateItems rebuilds item_group so stripListBorders takes effect immediately.
            local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
            local fm = ok_fm and FM and FM.instance
            if fm and fm.file_chooser and fm.file_chooser.updateItems then
                fm.file_chooser:updateItems()
                UIManager:setDirty(fm, "ui")
            else
                UIManager:setDirty(nil, "full")
            end
        end,
    })

    table.insert(appearance_items, 1, {
        text = _("Layout"),
        sub_item_table = layout_items,
    })

    local function build_additional_home_items()
        local dirs = type(config.additional_home_dirs) == "table"
            and config.additional_home_dirs or {}
        local sub = {}
        local function refresh(touchmenu_instance)
            if touchmenu_instance then
                touchmenu_instance.item_table = build_additional_home_items()
                touchmenu_instance:updateItems()
            end
        end
        table.insert(sub, {
            text = _("Add folder…"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local PathChooser = require("ui/widget/pathchooser")
                local start_path = paths.getHomeDir()
                    or G_reader_settings:readSetting("lastdir") or "/"
                UIManager:show(PathChooser:new{
                    select_file = false,
                    show_files  = false,
                    path        = start_path,
                    onConfirm   = function(dir_path)
                        if paths.isUnsafeFlatViewRoot(dir_path) then
                            local InfoMessage = require("ui/widget/infomessage")
                            UIManager:show(InfoMessage:new{
                                text = _("Use a narrower books folder instead of the device storage root."),
                            })
                            return
                        end
                        if type(config.additional_home_dirs) ~= "table" then
                            config.additional_home_dirs = {}
                        end
                        for _i, existing in ipairs(config.additional_home_dirs) do
                            if existing == dir_path then return end
                        end
                        table.insert(config.additional_home_dirs, dir_path)
                        plugin:saveConfig()
                        refresh(touchmenu_instance)
                    end,
                })
            end,
        })
        for i, dir in ipairs(dirs) do
            local util = require("util")
            local name = select(2, util.splitFilePathName(dir))
            table.insert(sub, {
                text = name ~= "" and name or dir,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local ConfirmBox = require("ui/widget/confirmbox")
                    UIManager:show(ConfirmBox:new{
                        text = _("Remove this folder from additional home folders?") .. "\n" .. dir,
                        ok_text = _("Remove"),
                        ok_callback = function()
                            table.remove(config.additional_home_dirs, i)
                            plugin:saveConfig()
                            refresh(touchmenu_instance)
                        end,
                    })
                end,
            })
        end
        return sub
    end

    table.insert(folders_item.sub_item_table, IconItem.decorate({
        text = _("Home folder"),
        sub_item_table = {
            {
                text = _("Set home folder"),
                callback = function()
                    local filemanagerutil = require("apps/filemanager/filemanagerutil")
                    local title_header = _("Current home folder:")
                    local current_path = paths.getHomeDir()
                    local default_path = filemanagerutil.getDefaultDir()
                    filemanagerutil.showChooseDialog(title_header, function(path)
                        G_reader_settings:saveSetting("home_dir", path)
                        if paths.isUnsafeFlatViewRoot(path)
                                and type(config.browser_flat_view) == "table"
                                and config.browser_flat_view.enabled == true then
                            config.browser_flat_view.enabled = false
                            plugin:saveConfig()
                            local InfoMessage = require("ui/widget/infomessage")
                            UIManager:show(InfoMessage:new{
                                text = _("Subfolder flat view was disabled because the home folder is the device storage root."),
                            })
                        end
                        local ok, FM = pcall(require, "apps/filemanager/filemanager")
                        local fm = ok and FM and FM.instance
                        if fm and type(fm.updateTitleBarPath) == "function" then
                            pcall(fm.updateTitleBarPath, fm)
                        end
                    end, current_path, default_path)
                end,
                keep_menu_open = true,
            },
            {
                text = _("Lock home folder"),
                enabled_func = function()
                    return G_reader_settings:has("home_dir")
                end,
                sub_item_table = {
                    {
                        text = _("Off"),
                        radio = true,
                        checked_func = function() return get_home_lock_mode() == "off" end,
                        callback = function() set_home_lock_mode("off") end,
                    },
                    {
                        text = _("Only in Zen mode"),
                        radio = true,
                        checked_func = function() return get_home_lock_mode() == "zen" end,
                        callback = function() set_home_lock_mode("zen") end,
                    },
                    {
                        text = _("On"),
                        radio = true,
                        checked_func = function() return get_home_lock_mode() == "on" end,
                        callback = function() set_home_lock_mode("on") end,
                    },
                },
            },
            {
                text = _("Additional home folders"),
                sub_item_table_func = build_additional_home_items,
            },
        },
    }, icons.settings_home_folder))
    table.insert(folders_item.sub_item_table, IconItem.decorate({
        text = _("Hide up folder"),
        checked_func = function() return config.browser_hide_up_folder.hide_up_folder == true end,
        callback = function()
            config.browser_hide_up_folder.hide_up_folder =
                config.browser_hide_up_folder.hide_up_folder ~= true
            save_and_apply("browser_hide_up_folder")
        end,
    }, icons.hide_reader_actions))

    local allow_delete_item = {
        text = _("Allow delete"),
        checked_func = function()
            return type(config.context_menu) == "table"
                and config.context_menu.allow_delete == true
        end,
        callback = function()
            if type(config.context_menu) ~= "table" then config.context_menu = {} end
            config.context_menu.allow_delete = config.context_menu.allow_delete ~= true
            plugin:saveConfig()
        end,
    }

    local detail_labels = {
        authors = _("Authors"),
        series = _("Series"),
        tags = _("Tags"),
        language = _("Language"),
        rating = _("Rating"),
        annotations = _("Annotations"),
        note = _("Note"),
        navigate_to_tag = _("Navigate to tag"),
        pages = _("Pages"),
        progress = _("Progress"),
        read_time = _("Read time"),
        time_remaining = _("Time remaining"),
        description = _("Description"),
    }
    local function normalize_detail_order(order)
        local normalized, seen, valid = {}, {}, {}
        for _i, id in ipairs(BOOK_DETAIL_ORDER) do valid[id] = true end
        for _i, id in ipairs(type(order) == "table" and order or {}) do
            if valid[id] and not seen[id] then
                normalized[#normalized + 1], seen[id] = id, true
            end
        end
        for _i, id in ipairs(BOOK_DETAIL_ORDER) do
            if not seen[id] then normalized[#normalized + 1] = id end
        end
        return normalized
    end
    local function detail_toggle(id)
        local default_enabled = defaults.book_details[id] == true
        local function is_enabled()
            local cfg = type(config.book_details) == "table"
                and config.book_details or {}
            if type(cfg[id]) == "boolean" then return cfg[id] end
            return default_enabled
        end
        return {
            text = detail_labels[id],
            orig_item = id,
            checked_func = is_enabled,
            callback = function()
                if type(config.book_details) ~= "table" then
                    config.book_details = {}
                end
                config.book_details[id] = not is_enabled()
                plugin:saveConfig()
            end,
        }
    end

    local function ensure_book_detail_description_style()
        if type(config.book_details) ~= "table" then config.book_details = {} end
        local cfg = config.book_details
        if type(cfg.text_styles) ~= "table" then cfg.text_styles = {} end
        local style = type(cfg.text_styles.description) == "table"
            and cfg.text_styles.description or {}
        cfg.text_styles.description = style
        local style_defaults = BOOK_DETAIL_TEXT_STYLE_DEFAULTS.description
        if type(style.font_face) ~= "string" or style.font_face == "" then
            style.font_face = style_defaults.font_face
        end
        local size = tonumber(style.font_size)
        style.font_size = size and math.max(6, math.min(40,
            math.floor(size + 0.5))) or nil
        return style
    end

    local function description_font_size(style)
        return style.font_size or ensure_library_font_cfg(config).font_size
    end

    local function save_book_detail_description_style(touchmenu_instance)
        plugin:saveConfig()
        if touchmenu_instance and touchmenu_instance.updateItems then
            touchmenu_instance:updateItems()
        end
    end

    local function book_detail_default_font(FontChooser)
        local face = resolved_library_font(ensure_library_font_cfg(config).font_face)
        if type(FontChooser.isFontRegistered) ~= "function"
                or FontChooser.isFontRegistered(face) then
            return face
        end
        return find_registered_font_file(face) or select(2, picker_default(FontChooser))
    end

    local function build_book_detail_description_font_items()
        return {
            {
                _zen_search_text = _("Font"),
                text_func = function()
                    local style = ensure_book_detail_description_style()
                    local ok_fc, FontChooser = pcall(require, "ui/widget/fontchooser")
                    local face_text = style.font_face == "default" and _("default")
                        or (ok_fc and font_name_text(style, FontChooser) or style.font_face)
                    return string.format("%s %s", _("Font:"), face_text)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local ok_fc, FontChooser = pcall(require, "ui/widget/fontchooser")
                    if not ok_fc then return end
                    local style = ensure_book_detail_description_style()
                    local default_font = book_detail_default_font(FontChooser)
                    local display_face = style.font_face == "default"
                        and default_font or resolved_library_font(style.font_face)
                    if type(FontChooser.isFontRegistered) == "function"
                            and not FontChooser.isFontRegistered(display_face) then
                        display_face = find_registered_font_file(display_face)
                            or default_font
                    end
                    if not display_face then return end
                    UIManager:show(FontChooser:new{
                        title = _("Description") .. " " .. _("font"),
                        font_file = display_face,
                        default_font_file = default_font,
                        callback = function(file)
                            local portable_file = LibraryFontPath.toConfig(file)
                            if style.font_face ~= portable_file then
                                style.font_face = portable_file
                                save_book_detail_description_style(touchmenu_instance)
                            end
                        end,
                    })
                end,
            },
            {
                text_func = function()
                    local style = ensure_book_detail_description_style()
                    return string.format("%s %s", _("Font size:"),
                        tostring(description_font_size(style)))
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local SpinWidget = require("ui/widget/spinwidget")
                    local style = ensure_book_detail_description_style()
                    UIManager:show(SpinWidget:new{
                        title_text = _("Description") .. " " .. _("font size"),
                        value = description_font_size(style),
                        value_min = 6,
                        value_max = 40,
                        default_value = ensure_library_font_cfg(config).font_size,
                        callback = function(spin)
                            style.font_size = math.max(6, math.min(40, spin.value))
                            save_book_detail_description_style(touchmenu_instance)
                        end,
                    })
                end,
            },
            {
                text = _("Use default style"),
                callback = function(touchmenu_instance)
                    config.book_details.text_styles.description = {
                        font_face = BOOK_DETAIL_TEXT_STYLE_DEFAULTS.description.font_face,
                    }
                    save_book_detail_description_style(touchmenu_instance)
                end,
            },
        }
    end

    local function show_book_details()
        if type(config.book_details) ~= "table" then config.book_details = {} end
        local cfg = config.book_details
        cfg.order = normalize_detail_order(cfg.order)
        local sort_items = {}
        for _i, id in ipairs(cfg.order) do
            local item = detail_toggle(id)
            if id == "tags" then
                item.sub_title = detail_labels[id]
                item.sub_item_table = { detail_toggle("navigate_to_tag") }
            end
            sort_items[#sort_items + 1] = item
        end
        local description_item = detail_toggle("description")
        description_item.arrange_pinned_last = true
        description_item.sub_title = detail_labels.description
        description_item.checkmark_callback = description_item.callback
        description_item.callback = nil
        description_item.sub_item_table_func = build_book_detail_description_font_items
        sort_items[#sort_items + 1] = description_item
        require("common/ui/zen_arrange_list").show{
            title = _("Book details"),
            item_table = sort_items,
            plugin = plugin,
            callback = function()
                local order = {}
                for _i, item in ipairs(sort_items) do
                    if item.orig_item ~= "description" then
                        order[#order + 1] = item.orig_item
                    end
                end
                cfg.order = normalize_detail_order(order)
                plugin:saveConfig()
            end,
        }
    end

    local function detail_search_items()
        local search_items = {}
        local function add(id)
            search_items[#search_items + 1] = {
                text = detail_labels[id],
                orig_item = id,
                _zen_search_open = show_book_details,
            }
        end
        for _i, id in ipairs(BOOK_DETAIL_ORDER) do add(id) end
        for _i, id in ipairs({ "navigate_to_tag", "description" }) do
            add(id)
        end
        return search_items
    end

    table.insert(book_items, IconItem.decorate({
        text = _("Book details"),
        _zen_settings_submenu = true,
        _zen_search_items_func = detail_search_items,
        keep_menu_open = true,
        callback = show_book_details,
    }, icons.details))

    local double_tap_item = {
        text = _("Double-tap to open a book"),
        help_text = _("When enabled, tap the same book twice in rapid succession to open it. Keyboard controls are unchanged."),
        checked_func = function()
            return type(config.developer) == "table"
                and config.developer.double_tap_to_open_books == true
        end,
        callback = function()
            if type(config.developer) ~= "table" then config.developer = {} end
            config.developer.double_tap_to_open_books =
                config.developer.double_tap_to_open_books ~= true
            plugin:saveConfig()
        end,
        sub_item_table = {
            {
                text = _("Single tap to open context menu"),
                enabled_func = function()
                    return type(config.developer) == "table"
                        and config.developer.double_tap_to_open_books == true
                end,
                checked_func = function()
                    return type(config.developer) == "table"
                        and config.developer.single_tap_to_open_context_menu == true
                end,
                callback = function()
                    if type(config.developer) ~= "table" then config.developer = {} end
                    config.developer.single_tap_to_open_context_menu =
                        config.developer.single_tap_to_open_context_menu ~= true
                    plugin:saveConfig()
                end,
            },
        },
    }
    double_tap_item.checkmark_callback = double_tap_item.callback
    table.insert(book_items, IconItem.decorate(double_tap_item, icons.double_tap))

    local context_item = IconItem.decorate({
        text = _("Context menu"),
        sub_item_table = {
            IconItem.decorate({
                text = _("Archive"),
                checked_func = function()
                    return type(config.context_menu) == "table"
                        and config.context_menu.show_archive == true
                end,
                callback = function()
                    if type(config.context_menu) ~= "table" then config.context_menu = {} end
                    config.context_menu.show_archive =
                        config.context_menu.show_archive ~= true
                    plugin:saveConfig()
                end,
            }, icons.archive),
            IconItem.decorate({
                text = _("Plugin actions"),
                checked_func = function()
                    return type(config.context_menu) == "table"
                        and config.context_menu.show_plugin_actions == true
                end,
                callback = function()
                    if type(config.context_menu) ~= "table" then config.context_menu = {} end
                    config.context_menu.show_plugin_actions =
                        config.context_menu.show_plugin_actions ~= true
                    plugin:saveConfig()
                end,
            }, icons.action),
        },
    }, icons.more_vertical)
    table.insert(context_item.sub_item_table, IconItem.decorate(allow_delete_item, icons.delete))

    table.insert(book_items, IconItem.decorate({
        text = _("Include new books in TBR"),
        help_text = _("New includes unread books and books modified since they were last opened."),
        checked_func = function()
            return type(config.group_view) == "table"
                and config.group_view.include_new_in_tbr == true
        end,
        callback = function(touchmenu_instance)
            if type(config.group_view) ~= "table" then config.group_view = {} end
            config.group_view.include_new_in_tbr =
                config.group_view.include_new_in_tbr ~= true
            plugin:saveConfig()
            local home = SharedState.get(plugin, "home")
            if home and home.rebuildActive then
                home.rebuildActive()
            end
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    }, icons.tbr))

    table.insert(book_items, IconItem.decorate({
        text = _("Treat file updates as New"),
        help_text = _("Show modified books as New until they are opened or their read status is changed."),
        checked_func = function()
            return config.group_view and config.group_view.file_updates_as_new == true or false
        end,
        callback = function(touchmenu_instance)
            if type(config.group_view) ~= "table" then config.group_view = {} end
            config.group_view.file_updates_as_new = config.group_view.file_updates_as_new ~= true
            plugin:saveConfig()
            require("common/book_status").clearCache()
            require("common/tbr_index").invalidateStatusCache()
            local home = SharedState.get(plugin, "home")
            if home then
                home.rebuildActive()
            end
            refresh_filechooser(true)
            if touchmenu_instance then touchmenu_instance:updateItems() end
        end,
    }, icons.refresh))

    table.insert(book_items, 2, metadata_section.build(ctx))
    table.insert(book_items, IconItem.decorate({
        text = _("Show all files from subfolders"),
        checked_func = function()
            return type(config.browser_flat_view) == "table"
                and config.browser_flat_view.enabled == true
                and not paths.hasUnsafeFlatViewHomeRoot()
        end,
        callback = function()
            if type(config.browser_flat_view) ~= "table" then
                config.browser_flat_view = {}
            end
            local v = config.browser_flat_view.enabled ~= true
            if v and paths.hasUnsafeFlatViewHomeRoot() then
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{
                    text = _("This option is disabled when a home folder is the device storage root. Set home folders to narrower books folders first."),
                })
                return
            end
            config.browser_flat_view.enabled = v
            if v then
                G_reader_settings:saveSetting("show_flat_view", false)
            end
            plugin:saveConfig()
            settings_apply.prompt_restart()
        end,
    }, icons.settings_subfolders))
    IconItem.decorate(appearance_items[1], icons.settings_layout)
    IconItem.decorate(appearance_items[2], icons.settings_covers)
    IconItem.decorate(appearance_items[3], icons.settings_scroll)
    return {
        IconItem.decorate({ text = _("Appearance"), sub_item_table = appearance_items }, icons.navbar_styling),
        IconItem.decorate(folders_item, icons.settings_folders),
        IconItem.decorate({ text = _("Books"), sub_item_table = book_items }, icons.reading),
        context_item,
    }
end

return M
