local defaults = require("config/defaults")
local HomePresets = require("modules/filebrowser/patches/home/home_presets")
local PresetStore = require("config/preset_store")
local HardcoverToken = require("config/hardcover_token")
local GoogleBooksKey = require("config/google_books_key")
local HomeQuotes = require("modules/filebrowser/patches/home/home_quotes")
local utils = require("common/utils")
local FontLanguage = require("common/font_language")
local LibraryFontPath = require("common/library_font_path")
local plugin_root = require("common/plugin_root") or ""
local BrandMigration = require("common/brand_migration")

local LEGACY_KEY = "zen_ui_config"  -- legacy G_reader_settings key; cleanup only
local HYPERREADABLE_LIBRARY_FONT = LibraryFontPath.BUNDLED_DEFAULT

local _zen_settings_file = nil  -- cached LuaSettings instance
local _current_config    = nil  -- in-memory cache for M.get()

local M = {}

local function get_settings_path()
    return PresetStore.rootDir() .. "/config.lua"
end

local function open_zen_file()
    if not _zen_settings_file then
        local LuaSettings = require("luasettings")
        _zen_settings_file = LuaSettings:open(get_settings_path())
    end
    return _zen_settings_file
end

-- Returns the stored config table and whether it came from settings.reader.lua.
local function load_raw_config()
    local f = open_zen_file()
    if type(f.data) == "table" and next(f.data) ~= nil then
        return f.data, false
    end
    local g = rawget(_G, "G_reader_settings")
    local legacy = g and g:readSetting(LEGACY_KEY)
    if type(legacy) == "table" then
        return legacy, true
    end
    return {}, false
end

local function migrate_brand_plugin_paths(stored)
    if type(stored) ~= "table" then return false end
    local plugin_parent = plugin_root:match("^(.*)/" .. BrandMigration.PLUGIN_DIR .. "$")
    if not plugin_parent then return false end
    return BrandMigration.rewriteTablePaths(
        stored,
        plugin_parent .. "/" .. BrandMigration.LEGACY_PLUGIN_DIR,
        plugin_root
    )
end

local function merged_with_defaults(stored)
    local cfg = type(stored) == "table" and stored or {}
    utils.deepmerge(cfg, defaults)
    return cfg
end

-- Recover the sparse config produced when an empty table was mistaken for an
-- array and therefore received none of the defaults during a fresh ZenOS boot.
local function is_incomplete_fresh_config(stored)
    if type(stored) ~= "table"
            or not BrandMigration.isConfigMigrationComplete(stored) then
        return false
    end
    local meta = type(stored._meta) == "table" and stored._meta or {}
    local features = stored.features
    local shown = meta.quickstart_shown_for_version
    return type(features) == "table" and next(features) == nil
        and (shown == nil or shown == "pre-quickstart")
end

local function normalize_renamed_keys(cfg)
    if type(cfg) ~= "table" then
        return cfg, false
    end

    cfg.features = cfg.features or {}
    local changed = false

    if cfg.features.disable_top_menu_swipe_zones == nil
       and cfg.features.disable_top_menu_zones ~= nil then
        cfg.features.disable_top_menu_swipe_zones = cfg.features.disable_top_menu_zones
        changed = true
    end

    if cfg.features.browser_hide_up_folder == nil
       and cfg.features.browser_up_folder ~= nil then
        cfg.features.browser_hide_up_folder = cfg.features.browser_up_folder
        changed = true
    end

    if cfg.features.status_bar == false then
        cfg.features.status_bar = true
        cfg.status_bar = type(cfg.status_bar) == "table" and cfg.status_bar or {}
        cfg.status_bar.left_order, cfg.status_bar.center_order, cfg.status_bar.right_order = {}, {}, {}
        changed = true
    end

    if cfg.browser_hide_up_folder == nil and cfg.browser_up_folder ~= nil then
        cfg.browser_hide_up_folder = cfg.browser_up_folder
        changed = true
    end
    if type(cfg.browser_hide_up_folder) ~= "table" then
        cfg.browser_hide_up_folder = {}
        changed = true
    end
    local lock_mode = cfg.browser_hide_up_folder.lock_home_folder
    if lock_mode == true then
        cfg.browser_hide_up_folder.lock_home_folder = "on"
        changed = true
    elseif lock_mode == false then
        cfg.browser_hide_up_folder.lock_home_folder = "off"
        changed = true
    elseif lock_mode ~= "off" and lock_mode ~= "zen" and lock_mode ~= "on" then
        cfg.browser_hide_up_folder.lock_home_folder = "zen"
        changed = true
    end

    -- Folder covers are always on and no longer need a persisted feature flag.
    if cfg.features.browser_folder_cover ~= nil then
        cfg.features.browser_folder_cover = nil
        changed = true
    end
    if type(cfg.browser_folder_cover) == "table"
            and cfg.browser_folder_cover.crop_to_fit ~= nil then
        cfg.browser_folder_cover.crop_to_fit = nil
        changed = true
    end
    if type(cfg._meta) == "table" and cfg._meta.gallery_mode_defaulted ~= nil then
        cfg._meta.gallery_mode_defaulted = nil
        changed = true
    end

    if type(cfg.navbar) == "table" and cfg.navbar.active_tab_bold ~= nil then
        cfg.navbar.active_tab_bold = nil
        changed = true
    end
    if type(cfg.navbar) == "table" and cfg.navbar.active_tab_styling ~= nil then
        cfg.navbar.active_tab_styling = nil
        changed = true
    end

    if type(cfg.group_view) == "table"
            and cfg.group_view.mark_new_as_tbr ~= nil then
        cfg.group_view.include_new_in_tbr = cfg.group_view.mark_new_as_tbr == true
        cfg.group_view.mark_new_as_tbr = nil
        changed = true
    end

    if cfg.features.reader_color_presets ~= nil then
        cfg.features.reader_themes = cfg.features.reader_color_presets
        changed = true
    end
    if cfg.features.reader_color_presets ~= nil then
        cfg.features.reader_color_presets = nil
        changed = true
    end

    if type(cfg.reader_color_presets) == "table" then
        cfg.reader_themes = cfg.reader_color_presets
        cfg.reader_color_presets = nil
        changed = true
    end

    local reader_themes = cfg.reader_themes
    if type(reader_themes) == "table" and reader_themes.preset ~= nil then
        reader_themes.dark_mode = reader_themes.preset
        reader_themes.light_mode = reader_themes.preset
        reader_themes.preset = nil
        changed = true
    end

    local reader_footer = cfg.reader_footer
    if type(reader_footer) == "table" then
        if reader_footer.verbose_chapter_time ~= nil then
            reader_footer.chapter_time_format = reader_footer.verbose_chapter_time == true
                and "full" or "number"
            reader_footer.verbose_chapter_time = nil
            changed = true
        end
        local format = reader_footer.chapter_time_format
        if format ~= "full" and format ~= "compact" and format ~= "number"
                and format ~= "koreader" then
            reader_footer.chapter_time_format = "number"
            changed = true
        end
    end

    return cfg, changed
end

local function migrate_legacy_rakuyomi_keys(cfg)
    local rakuyomi = type(cfg) == "table" and cfg.rakuyomi
    if type(rakuyomi) ~= "table" then
        return false
    end

    local changed = false
    if rakuyomi.return_to_chapter_list_on_exit == nil
            and rakuyomi.return_to_chapter_list_on_reader_exit ~= nil then
        rakuyomi.return_to_chapter_list_on_exit =
            rakuyomi.return_to_chapter_list_on_reader_exit
        changed = true
    end
    if rakuyomi.return_to_chapter_list_on_reader_exit ~= nil then
        rakuyomi.return_to_chapter_list_on_reader_exit = nil
        changed = true
    end
    if rakuyomi.return_to_chapter_on_reader_exit ~= nil then
        rakuyomi.return_to_chapter_on_reader_exit = nil
        changed = true
    end
    if rakuyomi.reverse_page_scrolling ~= nil then
        rakuyomi.reverse_page_scrolling = nil
        changed = true
    end

    return changed
end

local function collect_setting_keys(g_settings)
    local keys = {}

    if type(g_settings.pairs) == "function" then
        local ok_pairs, iterator, state, first_key = pcall(g_settings.pairs, g_settings)
        if ok_pairs and type(iterator) == "function" then
            local key_name = first_key
            while true do
                local next_key = iterator(state, key_name)
                if next_key == nil then break end
                if type(next_key) == "string" then
                    keys[next_key] = true
                end
                key_name = next_key
            end
        end
    end

    local tables_to_scan = {
        rawget(g_settings, "data"),
        rawget(g_settings, "settings"),
        rawget(g_settings, "_data"),
    }

    for i = 1, #tables_to_scan do
        local tbl = tables_to_scan[i]
        if type(tbl) == "table" then
            for key_name in pairs(tbl) do
                if type(key_name) == "string" then
                    keys[key_name] = true
                end
            end
        end
    end

    if type(g_settings) == "table" then
        for key_name in pairs(g_settings) do
            if type(key_name) == "string" then
                keys[key_name] = true
            end
        end
    end

    return keys
end

local function migrate_legacy_group_view_keys(cfg)
    local g = rawget(_G, "G_reader_settings")
    if not g or type(cfg) ~= "table" then
        return cfg, false
    end

    local changed = false
    local removed_legacy = false

    local function ensure_group_view()
        if type(cfg.group_view) ~= "table" then
            cfg.group_view = {}
            changed = true
        end
        return cfg.group_view
    end

    local function ensure_display_mode()
        local group_view = ensure_group_view()
        if type(group_view.display_mode) ~= "table" then
            group_view.display_mode = {}
            changed = true
        end
        return group_view.display_mode
    end

    local function ensure_detail_collate(tab_id)
        local group_view = ensure_group_view()
        if type(group_view.detail_collate) ~= "table" then
            group_view.detail_collate = {}
            changed = true
        end
        local detail_collate = group_view.detail_collate
        if type(detail_collate[tab_id]) ~= "table" then
            detail_collate[tab_id] = {}
            changed = true
        end
        return detail_collate[tab_id]
    end

    local function ensure_group_reverse()
        local group_view = ensure_group_view()
        if type(group_view.group_reverse) ~= "table" then
            group_view.group_reverse = {}
            changed = true
        end
        return group_view.group_reverse
    end

    local function ensure_detail_reverse(tab_id)
        local group_view = ensure_group_view()
        if type(group_view.detail_reverse) ~= "table" then
            group_view.detail_reverse = {}
            changed = true
        end
        local detail_reverse = group_view.detail_reverse
        if type(detail_reverse[tab_id]) ~= "table" then
            detail_reverse[tab_id] = {}
            changed = true
        end
        return detail_reverse[tab_id]
    end

    local function ensure_tags_global()
        local group_view = ensure_group_view()
        if type(group_view.tags_global) ~= "table" then
            group_view.tags_global = {}
            changed = true
        end
        return group_view.tags_global
    end

    local setting_keys = collect_setting_keys(g)

    for key_name in pairs(setting_keys) do
        local display_tab = key_name:match("^zen_(.+)_display_mode$")
        if display_tab then
            local legacy_value = g:readSetting(key_name)
            if legacy_value ~= nil then
                local display_mode = ensure_display_mode()
                if display_mode[display_tab] == nil then
                    display_mode[display_tab] = legacy_value
                    changed = true
                end
                g:delSetting(key_name)
                removed_legacy = true
            end
        else
            local detail_tab, group_name = key_name:match("^zen_(.+)_detail_collate_(.+)$")
            if detail_tab and group_name then
                local legacy_value = g:readSetting(key_name)
                if legacy_value ~= nil then
                    local detail_collate = ensure_detail_collate(detail_tab)
                    if detail_collate[group_name] == nil then
                        detail_collate[group_name] = legacy_value
                        changed = true
                    end
                    g:delSetting(key_name)
                    removed_legacy = true
                end
            else
                local reverse_tab, reverse_group = key_name:match("^zen_(.+)_detail_reverse_(.+)$")
                if reverse_tab and reverse_group then
                    local legacy_value = g:readSetting(key_name)
                    if legacy_value ~= nil then
                        local detail_reverse = ensure_detail_reverse(reverse_tab)
                        if detail_reverse[reverse_group] == nil then
                            if legacy_value == true then
                                detail_reverse[reverse_group] = true
                            end
                            changed = true
                        end
                        g:delSetting(key_name)
                        removed_legacy = true
                    end
                end
            end
        end
    end

    local tags_global_collate = g:readSetting("zen_tags_global_collate")
    if tags_global_collate ~= nil then
        local tags_global = ensure_tags_global()
        if type(tags_global.collate) ~= "string" or tags_global.collate == "" then
            tags_global.collate = type(tags_global_collate) == "string"
                and tags_global_collate or "title"
            changed = true
        end
        g:delSetting("zen_tags_global_collate")
        removed_legacy = true
    end

    local tags_global_reverse = g:readSetting("zen_tags_global_reverse")
    if tags_global_reverse ~= nil then
        local tags_global = ensure_tags_global()
        if tags_global.reverse == nil then
            tags_global.reverse = tags_global_reverse == true
            changed = true
        end
        g:delSetting("zen_tags_global_reverse")
        removed_legacy = true
    end

    local authors_reverse = g:readSetting("zen_authors_reverse")
    if authors_reverse ~= nil then
        local group_reverse = ensure_group_reverse()
        if group_reverse.authors == nil then
            group_reverse.authors = authors_reverse == true
            changed = true
        end
        g:delSetting("zen_authors_reverse")
        removed_legacy = true
    end

    local series_reverse = g:readSetting("zen_series_reverse")
    if series_reverse ~= nil then
        local group_reverse = ensure_group_reverse()
        if group_reverse.series == nil then
            group_reverse.series = series_reverse == true
            changed = true
        end
        g:delSetting("zen_series_reverse")
        removed_legacy = true
    end

    if removed_legacy then
        pcall(g.flush, g)
    end

    return cfg, (changed or removed_legacy)
end

local function migrate_legacy_owned_keys(cfg)
    local g = rawget(_G, "G_reader_settings")
    if not g or type(cfg) ~= "table" then return cfg, false end

    local changed = false
    local removed_legacy = false
    local ratio = g:readSetting("uniform_cover_ratio")
    if ratio ~= nil then
        if cfg.uniform_cover_ratio == nil and type(ratio) == "string" and ratio ~= "" then
            cfg.uniform_cover_ratio = ratio
            changed = true
        end
        g:delSetting("uniform_cover_ratio")
        removed_legacy = true
    end

    local default_url = g:readSetting("opds_default_url")
    if default_url ~= nil then
        if type(cfg.opds) ~= "table" then cfg.opds = {} end
        if cfg.opds.default_url == nil and type(default_url) == "string" and default_url ~= "" then
            cfg.opds.default_url = default_url
            changed = true
        end
        g:delSetting("opds_default_url")
        removed_legacy = true
    end

    if removed_legacy then pcall(g.flush, g) end
    return cfg, (changed or removed_legacy)
end

local function migrate_legacy_substring_search(cfg)
    local g = rawget(_G, "G_reader_settings")
    if not g or type(cfg) ~= "table" then return cfg, false end

    local legacy = g:readSetting("substring_search")
    if legacy == nil then return cfg, false end

    if type(cfg.search) ~= "table" then cfg.search = {} end
    cfg.search.substring = legacy ~= false
    g:delSetting("substring_search")
    pcall(g.flush, g)
    return cfg, true
end

local function migrate_legacy_updater_keys(cfg)
    local g = rawget(_G, "G_reader_settings")
    if not g or type(cfg) ~= "table" then
        return cfg, false
    end

    if type(cfg.updater) ~= "table" then
        cfg.updater = {}
    end
    local updater = cfg.updater
    local changed = false
    local removed_legacy = false

    for _i, key_name in ipairs({
        "latest_version",
        "update_dl_url",
        "update_sha256",
    }) do
        if updater[key_name] ~= nil then
            updater[key_name] = nil
            changed = true
        end
    end

    local function del_legacy(key_name)
        g:delSetting(key_name)
        removed_legacy = true
    end

    local just_updated = g:readSetting("zen_ui_just_updated")
    if just_updated ~= nil then
        if type(just_updated) == "string" and updater.just_updated_version ~= just_updated then
            updater.just_updated_version = just_updated
            changed = true
        end
        del_legacy("zen_ui_just_updated")
    end

    local last_check = g:readSetting("zen_ui_last_update_check")
    if last_check ~= nil then
        local normalized = type(last_check) == "number" and last_check or 0
        if updater.last_update_check ~= normalized then
            updater.last_update_check = normalized
            changed = true
        end
        del_legacy("zen_ui_last_update_check")
    end

    local update_available = g:readSetting("zen_ui_update_available")
    if update_available ~= nil then
        local normalized = update_available == true
        if updater.update_available ~= normalized then
            updater.update_available = normalized
            changed = true
        end
        del_legacy("zen_ui_update_available")
    end

    local latest_version = g:readSetting("zen_ui_latest_version")
    if latest_version ~= nil then
        del_legacy("zen_ui_latest_version")
    end

    local update_dl_url = g:readSetting("zen_ui_update_dl_url")
    if update_dl_url ~= nil then
        del_legacy("zen_ui_update_dl_url")
    end

    local update_sha256 = g:readSetting("zen_ui_update_sha256")
    if update_sha256 ~= nil then
        del_legacy("zen_ui_update_sha256")
    end

    local update_channel = g:readSetting("zen_ui_update_channel")
    if update_channel ~= nil then
        local normalized = update_channel == "beta" and "beta" or "stable"
        if updater.update_channel ~= normalized then
            updater.update_channel = normalized
            changed = true
        end
        del_legacy("zen_ui_update_channel")
    end

    local update_auto_check = g:readSetting("zen_ui_update_auto_check")
    if update_auto_check ~= nil then
        local normalized = update_auto_check ~= false
        if updater.update_auto_check ~= normalized then
            updater.update_auto_check = normalized
            changed = true
        end
        del_legacy("zen_ui_update_auto_check")
    end

    if removed_legacy then
        pcall(g.flush, g)
    end

    return cfg, changed
end

local function migrate_folder_path_settings(cfg)
    if type(cfg) ~= "table" then return cfg, false end

    local changed = false
    if type(cfg.folder_sort) ~= "table" then
        cfg.folder_sort = {}
        changed = true
    end
    if type(cfg.folder_display_mode) ~= "table" then
        cfg.folder_display_mode = {}
        changed = true
    end
    if type(cfg.folder_cover_paths) ~= "table" then
        cfg.folder_cover_paths = {}
        changed = true
    end
    for folder, slots in pairs(cfg.folder_cover_paths) do
        if type(slots) == "table" then
            local was_empty = next(slots) == nil
            for slot, cover_path in pairs(slots) do
                local extension = type(cover_path) == "string"
                    and cover_path:lower():match("%.([^./]+)$") or nil
                if extension ~= "jpg" and extension ~= "jpeg" then
                    slots[slot] = nil
                    changed = true
                end
            end
            if not was_empty and next(slots) == nil then
                cfg.folder_cover_paths[folder] = nil
            end
        end
    end

    local g = rawget(_G, "G_reader_settings")
    if not g then return cfg, changed end

    local removed_legacy = false
    local valid_display_modes = {
        mosaic_image = true,
        list_image_meta = true,
        list_image_filename = true,
    }

    local legacy_sort = g:readSetting("zen_ui_folder_sort")
    if type(legacy_sort) == "table" then
        for path, entry in pairs(legacy_sort) do
            if type(path) == "string" and cfg.folder_sort[path] == nil then
                if type(entry) == "string" then
                    cfg.folder_sort[path] = { collate = entry, reverse = false }
                    changed = true
                elseif type(entry) == "table" and type(entry.collate) == "string" then
                    cfg.folder_sort[path] = {
                        collate = entry.collate,
                        reverse = entry.reverse == true,
                    }
                    changed = true
                end
            end
        end
        g:delSetting("zen_ui_folder_sort")
        removed_legacy = true
    end

    local legacy_display = g:readSetting("zen_ui_folder_display_mode")
    if type(legacy_display) == "table" then
        for path, mode in pairs(legacy_display) do
            if type(path) == "string" and cfg.folder_display_mode[path] == nil
                    and valid_display_modes[mode] then
                cfg.folder_display_mode[path] = mode
                changed = true
            end
        end
        g:delSetting("zen_ui_folder_display_mode")
        removed_legacy = true
    end

    if removed_legacy then
        pcall(g.flush, g)
    end

    return cfg, (changed or removed_legacy)
end

local function migrate_folder_cover_keys(cfg)
    local g = rawget(_G, "G_reader_settings")
    if not g or type(cfg) ~= "table" then return cfg, false end

    if type(cfg.browser_folder_cover) ~= "table" then
        cfg.browser_folder_cover = {}
    end
    local fbc = cfg.browser_folder_cover
    local changed = false
    local removed_legacy = false

    -- Read legacy keys before deleting them.
    local gallery_val = g:readSetting("folder_gallery_mode")
    local stack_val   = g:isTrue("folder_stack_mode")
    local none_val    = g:isTrue("folder_none_mode")
    local has_legacy  = gallery_val ~= nil or stack_val or none_val

    if has_legacy then
        -- Existing user: override cover_mode from their legacy selection.
        -- merged_with_defaults already ran, so the legacy value must overwrite it.
        -- New installs never have these keys so defaults.lua applies cleanly.
        if none_val then
            fbc.cover_mode = "none"
        elseif stack_val then
            fbc.cover_mode = "stack"
        elseif gallery_val == false then
            fbc.cover_mode = "normal"
        else
            fbc.cover_mode = "gallery"
        end
        changed = true
    end

    for _i, key in ipairs({ "folder_gallery_mode", "folder_stack_mode", "folder_none_mode" }) do
        if g:readSetting(key) ~= nil then
            g:delSetting(key)
            removed_legacy = true
        end
    end

    if removed_legacy then pcall(g.flush, g) end
    return cfg, (changed or removed_legacy)
end

local function migrate_bim_folder_cover_keys(cfg)
    if type(cfg._meta) == "table" and cfg._meta.bim_fbc_migrated then
        return cfg, false
    end

    local ok, bim = pcall(require, "bookinfomanager")
    if not ok or not bim then return cfg, false end

    if type(cfg.browser_folder_cover) ~= "table" then
        cfg.browser_folder_cover = {}
    end
    local fbc = cfg.browser_folder_cover
    -- All BIM folder cover keys used BooleanSetting(default=true): get() = not BIM_value.
    -- Zen config stores the direct value, so: zen_value = BIM_value ~= true.
    local mappings = {
        { bim = "folder_name_centered",     cfg = "name_centered"     },
        { bim = "folder_name_show",         cfg = "show_folder_name"  },
        { bim = "folder_item_count_show",   cfg = "show_item_count"   },
        { bim = "folder_name_opaque",       cfg = "name_opaque"       },
        { bim = "folder_spine_lines_show",  cfg = "show_spine_lines"  },
    }
    -- This old CoverBrowser option never affected Zen's renderer.
    if bim:getSetting("folder_crop_custom_image") ~= nil then
        pcall(bim.saveSetting, bim, "folder_crop_custom_image", nil)
    end
    for _i, m in ipairs(mappings) do
        local bim_val = bim:getSetting(m.bim)
        if bim_val ~= nil then
            fbc[m.cfg] = bim_val ~= true
            pcall(bim.saveSetting, bim, m.bim, nil)
        end
    end

    -- Migrate display modes (plain strings, no inversion)
    if type(cfg.group_view) ~= "table" then cfg.group_view = {} end
    local gv = cfg.group_view
    if type(gv.display_mode) ~= "table" then gv.display_mode = {} end
    local dm = gv.display_mode
    local dm_mappings = {
        { bim = "collection_display_mode", key = "collections" },
        { bim = "history_display_mode",    key = "history"     },
    }
    for _i, m in ipairs(dm_mappings) do
        local bim_val = bim:getSetting(m.bim)
        if bim_val ~= nil then
            dm[m.key] = bim_val
            pcall(bim.saveSetting, bim, m.bim, nil)
        end
    end

    if type(cfg._meta) == "table" then
        cfg._meta.bim_fbc_migrated = true
    end
    return cfg, true  -- always save: marks migration as attempted
end

local function capture_screensaver_settings()
    local g = rawget(_G, "G_reader_settings")
    if not g then return {} end
    return {
        screensaver_type = g:readSetting("screensaver_type"),
        screensaver_message = g:readSetting("screensaver_message"),
        screensaver_show_message = g:isTrue("screensaver_show_message"),
        screensaver_img_background = g:readSetting("screensaver_img_background"),
        screensaver_document_cover = g:readSetting("screensaver_document_cover"),
        screensaver_stretch_images = g:isTrue("screensaver_stretch_images"),
        screensaver_stretch_limit_percentage = g:readSetting("screensaver_stretch_limit_percentage"),
    }
end

local function capture_reader_footer_settings()
    local g = rawget(_G, "G_reader_settings")
    if not g then return {} end
    local util = require("util")
    local footer = g:readSetting("footer")
    return {
        footer = type(footer) == "table" and util.tableDeepCopy(footer) or {},
        reader_footer_mode = g:readSetting("reader_footer_mode") or 1,
        reader_footer_custom_text = g:readSetting("reader_footer_custom_text") or "KOReader",
        reader_footer_custom_text_repetitions = g:readSetting("reader_footer_custom_text_repetitions") or 1,
    }
end

local function load_reader_theme_settings(cfg)
    if type(cfg) ~= "table" then return end
    local reader_store = PresetStore.loadStore("reader")
    if type(reader_store.reader_themes) == "table" then
        cfg.reader_themes = reader_store.reader_themes
    end
end

local function migrate_reader_preset_zen_settings()
    local store = PresetStore.loadStore("reader")
    local changed = false

    local function migrate(preset)
        if type(preset) ~= "table" then return end
        local zen = preset.zen
        if type(zen) == "table" then
            if preset.verbose_chapter_time == nil and zen.verbose_chapter_time ~= nil then
                preset.verbose_chapter_time = zen.verbose_chapter_time
                changed = true
            end
            if zen.verbose_chapter_time ~= nil then changed = true end
            zen.verbose_chapter_time = nil
            if next(zen) == nil then
                preset.zen = nil
                changed = true
            end
        end
        if preset.verbose_chapter_time ~= nil then
            if preset.chapter_time_format == nil then
                preset.chapter_time_format = preset.verbose_chapter_time == true
                    and "full" or "number"
            end
            preset.verbose_chapter_time = nil
            changed = true
        end
        local format = preset.chapter_time_format
        if format ~= nil and format ~= "full" and format ~= "compact" and format ~= "number"
                and format ~= "koreader" then
            preset.chapter_time_format = "number"
            changed = true
        end
    end

    migrate(store.settings)
    for _name, preset in pairs(store.presets) do
        migrate(preset)
    end
    return changed and PresetStore.saveStore("reader", store)
end

local function migrate_reader_footer_backup(cfg)
    if type(cfg) ~= "table" or type(cfg.reader_footer) ~= "table" then
        return false
    end
    local backup = cfg.reader_footer.backup_preset
    if type(backup) ~= "table" then return false end
    if type(backup.name) ~= "string" or backup.name == "" then
        backup.name = "Backup of Original"
    end
    backup.builtin = true
    PresetStore.save("reader", backup.name, backup)
    PresetStore.saveSettings("reader", capture_reader_footer_settings())
    cfg.reader_footer.backup_preset = nil
    return true
end

local function migrate_page_browser_layout(cfg)
    if type(cfg) ~= "table" then return false end

    local function valid_layout(layout)
        return layout == "single" or layout == "carousel" or layout == "grid"
    end

    local store = PresetStore.loadStore("reader")
    if type(store) ~= "table" then return false end
    if type(store.settings) ~= "table" then store.settings = {} end

    local changed = false
    local layout = store.settings.page_browser_layout
    if not valid_layout(layout) then
        local legacy_config = type(cfg.reader_page_browser) == "table"
            and cfg.reader_page_browser.layout
        local g = rawget(_G, "G_reader_settings")
        local legacy_global = g and g:readSetting("zen_page_browser_layout")
        if valid_layout(legacy_config) then
            layout = legacy_config
        elseif valid_layout(legacy_global) then
            layout = legacy_global
        end
        if valid_layout(layout) then
            store.settings.page_browser_layout = layout
            PresetStore.saveStore("reader", store)
            changed = true
        end
    end

    if cfg.reader_page_browser ~= nil then
        cfg.reader_page_browser = nil
        changed = true
    end

    local g = rawget(_G, "G_reader_settings")
    if g and g:readSetting("zen_page_browser_layout") ~= nil then
        g:delSetting("zen_page_browser_layout")
        pcall(g.flush, g)
        changed = true
    end

    return changed
end

local function migrate_home_quote_font_size()
    local store = PresetStore.loadStore("home")
    local changed = false

    local function migrate(page)
        if type(page) ~= "table" then return end
        if page.font_size ~= nil then
            page.font_size = nil
            changed = true
        end
        if page.font_size_override ~= nil then
            page.font_size_override = nil
            changed = true
        end
        if type(page.quotes) ~= "table" then
            page.quotes = {}
            changed = true
        end
        local quotes = page.quotes
        if type(quotes.sources) ~= "table" then
            quotes.sources = { default = true }
            changed = true
        end
        if quotes.rotation ~= "daily" and quotes.rotation ~= "refresh" then
            quotes.rotation = "daily"
            changed = true
        end
        if quotes.automatic_font_size ~= true and quotes.automatic_font_size ~= false then
            quotes.automatic_font_size = true
            changed = true
        end
        local max_font_size = tonumber(quotes.max_font_size)
        local normalized_max_font_size = math.max(
            4, math.min(32, math.floor((max_font_size or 14) + 0.5))
        )
        if quotes.max_font_size ~= normalized_max_font_size then
            quotes.max_font_size = normalized_max_font_size
            changed = true
        end
        if quotes.day_seed ~= nil then
            quotes.day_seed = nil
            changed = true
        end
        if quotes.manual_index ~= nil then
            quotes.manual_index = nil
            changed = true
        end
        local font_size = tonumber(quotes.font_size)
        if font_size == nil or (font_size == 18 and quotes.font_size_override ~= true) then
            quotes.font_size = 12
            quotes.font_size_override = nil
            changed = true
        end
        if quotes.use_home_font_size ~= nil then
            quotes.use_home_font_size = nil
            changed = true
        end
    end

    migrate(store.settings)
    for _name, preset in pairs(store.presets) do
        local page = type(preset) == "table" and (preset.home_page or preset)
        migrate(page)
    end
    return changed and PresetStore.saveStore("home", store)
end

local function migrate_home_strip_config()
    if type(HomePresets.normalizeStripConfig) ~= "function" then return false end
    local store = PresetStore.loadStore("home")
    local changed = HomePresets.normalizeStripConfig(store.settings)
    local active_preset = type(store.settings) == "table"
        and store.settings.active_preset or nil
    if type(active_preset) ~= "string" or active_preset == "" then
        active_preset = store.active_preset
    end
    local strip = type(store.settings) == "table"
        and type(store.settings.modules) == "table"
        and store.settings.modules.strip or nil
    if (active_preset == HomePresets.DEFAULT_PRESET_NAME
                or active_preset == HomePresets.BOOKSHELF_PRESET_NAME)
            and type(strip) == "table"
            and type(strip.controls) == "table"
            and strip.controls.enabled ~= true then
        strip.controls.enabled = true
        changed = true
    end
    for _name, preset in pairs(store.presets) do
        local page = type(preset) == "table" and (preset.home_page or preset)
        if HomePresets.normalizeStripConfig(page) then changed = true end
    end
    return changed and PresetStore.saveStore("home", store)
end

local function migrate_home_featured_config()
    if type(HomePresets.normalizeFeaturedConfig) ~= "function" then return false end
    local store = PresetStore.loadStore("home")
    local changed = HomePresets.normalizeFeaturedConfig(store.settings)
    for _name, preset in pairs(store.presets) do
        local page = type(preset) == "table" and (preset.home_page or preset)
        if HomePresets.normalizeFeaturedConfig(page) then changed = true end
    end
    return changed and PresetStore.saveStore("home", store)
end

local function migrate_home_layout_grid()
    if type(HomePresets.normalizeLayoutGrid) ~= "function" then return false end
    local store = PresetStore.loadStore("home")
    local changed = HomePresets.normalizeLayoutGrid(store.settings)
    for _name, preset in pairs(store.presets) do
        local page = type(preset) == "table" and (preset.home_page or preset)
        if HomePresets.normalizeLayoutGrid(page) then changed = true end
    end
    return changed and PresetStore.saveStore("home", store)
end

local function migrate_settings_files()
    local changed = PresetStore.migrateStores({
        home = HomePresets.defaultHomePage(),
        reader = capture_reader_footer_settings(),
        screensaver = capture_screensaver_settings(),
    })
    if HomeQuotes.ensureFile() then
        changed = true
    end
    if HardcoverToken.ensureFile() then
        changed = true
    end
    if GoogleBooksKey.ensureFile() then
        changed = true
    end
    if migrate_home_quote_font_size() then
        changed = true
    end
    if migrate_home_featured_config() then
        changed = true
    end
    if migrate_home_strip_config() then
        changed = true
    end
    if migrate_home_layout_grid() then
        changed = true
    end
    return changed
end

local function migrate_changed_defaults(cfg)
    if type(cfg) ~= "table" then
        return cfg, false
    end

    local changed = false
    if type(cfg._meta) ~= "table" then
        cfg._meta = {}
        changed = true
    end

    if cfg._meta.reader_footer_hide_cbz_default_migrated ~= true then
        if type(cfg.reader_footer) ~= "table" then
            cfg.reader_footer = {}
        end
        if cfg.reader_footer.hide_in_cbz ~= true then
            cfg.reader_footer.hide_in_cbz = true
        end
        cfg._meta.reader_footer_hide_cbz_default_migrated = true
        changed = true
    end

    if cfg._meta.context_menu_allow_delete_default_migrated ~= true then
        if type(cfg.context_menu) ~= "table" then
            cfg.context_menu = {}
        end
        if cfg.context_menu.allow_delete ~= true then
            cfg.context_menu.allow_delete = true
        end
        cfg._meta.context_menu_allow_delete_default_migrated = true
        changed = true
    end

    if cfg._meta.lookup_plugin_items_default_migrated ~= true then
        if type(cfg.highlight_lookup) ~= "table" then
            cfg.highlight_lookup = {}
        end
        cfg.highlight_lookup.show_xray = true
        cfg.highlight_lookup.show_koassistant = true
        cfg.highlight_lookup.show_ai_assistant = true
        cfg._meta.lookup_plugin_items_default_migrated = true
        changed = true
    end

    if cfg._meta.library_font_hyperreadable_default_migrated ~= true then
        if type(cfg.library_font) ~= "table" then
            cfg.library_font = {}
        end
        local font_face = cfg.library_font.font_face
        if type(font_face) ~= "string" or font_face == "" or font_face == "default" then
            cfg.library_font.font_face = defaults.library_font.font_face
        end
        cfg._meta.library_font_hyperreadable_default_migrated = true
        changed = true
    end
    if type(cfg.library_font) == "table" then
        local font_face = cfg.library_font.font_face
        local portable_face = LibraryFontPath.toConfig(font_face)
        if portable_face ~= font_face then
            cfg.library_font.font_face = portable_face
            changed = true
        end
    end
    if type(cfg.library_font) == "table"
            and not FontLanguage.supportsBundledFonts()
            and cfg.library_font.font_face == HYPERREADABLE_LIBRARY_FONT then
        cfg.library_font.font_face = "default"
        changed = true
    end

    -- One-time seed of home strip book titles from the mosaic "Show title below
    -- cover" setting. After this runs once, strip titles are user-owned and the
    -- mosaic setting no longer overrides them.
    if cfg._meta.home_strip_titles_seeded ~= true then
        local show = type(cfg.mosaic_title_strip) == "table"
            and cfg.mosaic_title_strip.show_title == true
        if show then
            local dcfg = PresetStore.getSettings("home")
            if type(dcfg) == "table" and next(dcfg) ~= nil then
                HomePresets.applyMosaicTitlesToStrips(dcfg, true)
                PresetStore.saveSettings("home", dcfg)
            end
        end
        cfg._meta.home_strip_titles_seeded = true
        changed = true
    end

    return cfg, changed
end

function M.get()
    return _current_config
end

function M.settingsPath()
    return get_settings_path()
end

function M.load()
    local stored, migrated_file_config = load_raw_config()
    local recovered_fresh_config = is_incomplete_fresh_config(stored)
    if recovered_fresh_config then
        stored._meta.quickstart_shown_for_version = false
        stored._meta.quickstart_completed = false
    end
    local fresh_config = type(stored) ~= "table" or next(stored) == nil
        or recovered_fresh_config
    local migrated_brand_paths = migrate_brand_plugin_paths(stored)
    local migrated_home_lock = false
    local stored_hide_up = type(stored) == "table" and rawget(stored, "browser_hide_up_folder")
    if type(stored_hide_up) ~= "table" or stored_hide_up.lock_home_folder == nil then
        local g = rawget(_G, "G_reader_settings")
        if g and g.isTrue and g:isTrue("lock_home_folder") then
            if type(stored_hide_up) ~= "table" then
                stored.browser_hide_up_folder = {}
                stored_hide_up = stored.browser_hide_up_folder
            end
            stored_hide_up.lock_home_folder = "on"
            migrated_home_lock = true
        end
    end

    -- Existing install that predates the quickstart feature: stored config is
    -- non-empty but lacks quickstart_shown_for_version. deepmerge would fill
    -- it with false (new-install trigger), so set a sentinel before merging.
    local migrated_qs = false
    if type(stored) == "table" and next(stored) ~= nil then
        local m = rawget(stored, "_meta")
        if type(m) ~= "table" or m.quickstart_shown_for_version == nil then
            stored._meta = (type(m) == "table" and m) or {}
            stored._meta.quickstart_shown_for_version = "pre-quickstart"
            migrated_qs = true
        end
    end

    -- Older configs only tracked whether Quickstart had been shown. Treat a
    -- previously shown guide as completed so reruns preserve reader settings.
    local migrated_qs_completion = false
    if type(stored) == "table" and next(stored) ~= nil then
        local m = rawget(stored, "_meta")
        if type(m) == "table" and m.quickstart_completed == nil then
            m.quickstart_completed = m.quickstart_shown_for_version ~= false
            migrated_qs_completion = true
        end
    end

    local migrated_rakuyomi = migrate_legacy_rakuyomi_keys(stored)
    local migrated_group, migrated_owned
    stored, migrated_group = migrate_legacy_group_view_keys(stored)
    stored, migrated_owned = migrate_legacy_owned_keys(stored)
    local cfg = merged_with_defaults(stored)
    local migrated_renamed
    cfg, migrated_renamed = normalize_renamed_keys(cfg)
    local migrated_substring, migrated_updater, migrated_folder_paths, migrated_fbc, migrated_bim
    cfg, migrated_substring = migrate_legacy_substring_search(cfg)
    cfg, migrated_updater = migrate_legacy_updater_keys(cfg)
    cfg, migrated_folder_paths = migrate_folder_path_settings(cfg)
    cfg, migrated_fbc     = migrate_folder_cover_keys(cfg)
    cfg, migrated_bim     = migrate_bim_folder_cover_keys(cfg)
    local migrated_reader_backup = migrate_reader_footer_backup(cfg)
    local migrated_settings_files = migrate_settings_files()
    local migrated_page_browser = migrate_page_browser_layout(cfg)
    load_reader_theme_settings(cfg)
    local migrated_reader_presets = migrate_reader_preset_zen_settings()
    local migrated_changed_defaults
    cfg, migrated_changed_defaults = migrate_changed_defaults(cfg)
    local initialized_brand_marker = fresh_config
        and plugin_root:match("/" .. BrandMigration.PLUGIN_DIR .. "$") ~= nil
        and BrandMigration.markConfigMigrationComplete(cfg)
    if migrated_renamed or migrated_group or migrated_substring or migrated_updater or migrated_fbc or migrated_bim
            or migrated_reader_backup or migrated_qs or migrated_qs_completion or migrated_file_config
            or migrated_settings_files or migrated_reader_presets
            or migrated_changed_defaults or migrated_home_lock
            or migrated_folder_paths or migrated_rakuyomi or migrated_page_browser
            or migrated_brand_paths or migrated_owned or initialized_brand_marker
            or recovered_fresh_config then
        M.save(cfg)
    end
    if migrated_file_config then
        local g = rawget(_G, "G_reader_settings")
        if g and type(g.delSetting) == "function" then -- luacheck: ignore 542
            -- TODO: re-enable to delete legacy zen_ui_config key from settings.reader.lua
            -- pcall(g.delSetting, g, LEGACY_KEY)
            -- pcall(g.flush, g)
        end
    end
    _current_config = cfg
    return cfg
end

function M.save(config, verify)
    local f = open_zen_file()
    f.data = config

    local ok, saved, err = pcall(function()
        if verify and type(f.file) == "string" and type(f.backup) == "function" then
            local dump = require("dump")
            local file_util = require("util")
            local serialized = dump(config, nil, true)
            local directory_updated = f:backup()
            local write_ok, write_err = file_util.writeToFile(
                serialized, f.file, true, true, directory_updated)
            if not write_ok then return nil, write_err end
            local stored, read_err = file_util.readFromFile(f.file)
            local expected = "-- " .. f.file .. "\nreturn " .. serialized .. "\n"
            if stored ~= expected then
                return nil, read_err or "settings verification failed"
            end
            return true
        end

        local result = f:flush()
        if result == false then return nil, "settings flush failed" end
        return true
    end)
    if not ok then return nil, saved end
    if not saved then return nil, err end
    _current_config = config
    return true
end

function M.movePathSettings(from_path, to_path)
    if type(from_path) ~= "string" or type(to_path) ~= "string" then return false end

    local paths = require("common/paths")
    local function normalize(path)
        path = paths.normPath(path:gsub("/+$", ""))
        return path ~= "" and path or "/"
    end

    local source = normalize(from_path)
    local destination = normalize(to_path)
    if source == destination then return false end

    local cfg = M.get()
    if type(cfg) ~= "table" then cfg = M.load() end
    local changed = false

    for _i, map_name in ipairs({
        "folder_sort", "folder_display_mode", "folder_cover_paths",
    }) do
        local settings = cfg[map_name]
        if type(settings) == "table" then
            local moves = {}
            for key, value in pairs(settings) do
                if type(key) == "string" then
                    local normalized_key = normalize(key)
                    if normalized_key == source
                            or normalized_key:sub(1, #source + 1) == source .. "/" then
                        moves[#moves + 1] = {
                            from = key,
                            to = destination .. normalized_key:sub(#source + 1),
                            value = value,
                        }
                    end
                end
            end
            for _j, move in ipairs(moves) do
                settings[move.from] = nil
                if settings[move.to] == nil then
                    settings[move.to] = move.value
                end
                changed = true
            end
        end
    end

    local cover_paths = cfg.folder_cover_paths
    if type(cover_paths) == "table" then
        for _folder, slots in pairs(cover_paths) do
            if type(slots) == "table" then
                for slot, image_path in pairs(slots) do
                    if type(image_path) == "string" then
                        local normalized_path = normalize(image_path)
                        if normalized_path == source
                                or normalized_path:sub(1, #source + 1) == source .. "/" then
                            slots[slot] = destination .. normalized_path:sub(#source + 1)
                            changed = true
                        end
                    end
                end
            end
        end
    end

    if changed then return M.save(cfg, true) == true end
    return false
end

M.moveFolderPathSettings = M.movePathSettings

-- Kept for deletePluginSettings: identifies the legacy G_reader_settings key
-- so it can be cleaned up alongside the dedicated file.
function M.key()
    return LEGACY_KEY
end

return M
