local M = {}
local initialized = false

local PATCH_MODULES = {
    library_navigation = "modules/reader/patches/library_navigation",
    opening_banner = "modules/reader/patches/opening_banner",
    book_status = "modules/reader/patches/book_status",
    reader_top_status_bar = "modules/reader/patches/reader_top_status_bar",
    reader_themes = "modules/reader/patches/reader_themes",
    screensaver_cover = "modules/reader/patches/screensaver_cover",
    reader_footer = "modules/reader/patches/reader_footer",
    reader_footer_time_format = "modules/reader/patches/reader_footer_time_format",
    reader_footer_cbz_hide = "modules/reader/patches/reader_footer_cbz_hide",
    margin_hold_guard = "modules/reader/patches/margin_hold_guard",
    bookmarks = "modules/reader/patches/bookmarks",
    page_browser = "modules/reader/patches/page_browser",
    stable_page_statistics = "modules/reader/patches/stable_page_statistics",
    highlight_names = "modules/reader/patches/highlight_names",
    highlight_menu = "modules/reader/patches/highlight_menu",
    dict_quick_lookup = "modules/reader/patches/dict_quick_lookup",
    status_on_open = "modules/reader/patches/status_on_open",
}

local function is_feature_enabled(plugin, key)
    return plugin
        and type(plugin.config) == "table"
        and type(plugin.config.features) == "table"
        and plugin.config.features[key] == true
end

local function run_feature(logger, plugin, feature, fn)
    local prev_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    _G.__ZEN_UI_PLUGIN = plugin
    local ok, err = pcall(fn)
    _G.__ZEN_UI_PLUGIN = prev_plugin
    if not ok and logger then
        logger.warn("grouped reader feature failed", feature, err)
    end
    return ok
end

local function load_patch(feature)
    local module_name = PATCH_MODULES[feature]
    if not module_name then
        return nil
    end
    local ok, patch_fn = pcall(require, module_name)
    if not ok or type(patch_fn) ~= "function" then
        return nil
    end
    return patch_fn
end

function M.init(logger, plugin)
    if initialized then
        return true
    end

    -- Route KOReader's File browser gesture through the same transition as ZenOS.
    local library_navigation_fn = load_patch("library_navigation")
    if library_navigation_fn then
        run_feature(logger, plugin, "library_navigation", library_navigation_fn)
    end

    -- Always apply: page browser (self-disables when feature is off).
    local page_browser_fn = load_patch("page_browser")
    if page_browser_fn then
        run_feature(logger, plugin, "page_browser", page_browser_fn)
    end

    -- Make page-based reading statistics follow active stable page labels.
    local stable_page_statistics_fn = load_patch("stable_page_statistics")
    if stable_page_statistics_fn then
        run_feature(logger, plugin, "stable_page_statistics", stable_page_statistics_fn)
    end

    -- Always apply: replaces the "Opening file..." popup with a bottom banner
    local opening_banner_fn = load_patch("opening_banner")
    if opening_banner_fn then
        run_feature(logger, plugin, "opening_banner", opening_banner_fn)
    end

    -- Always apply: custom Book Status layout + sets native end_document_action
    local book_status_fn = load_patch("book_status")
    if book_status_fn then
        run_feature(logger, plugin, "book_status", book_status_fn)
    end

    local status_on_open_fn = load_patch("status_on_open")
    if status_on_open_fn then
        run_feature(logger, plugin, "status_on_open", status_on_open_fn)
    end

    -- Always apply: replace koreader.png fallback screensaver with zen_ui.svg
    local screensaver_cover_fn = load_patch("screensaver_cover")
    if screensaver_cover_fn then
        run_feature(logger, plugin, "screensaver_cover", screensaver_cover_fn)
    end

    -- Always apply: two-filler L/C/R layout support.
    local reader_footer_fn = load_patch("reader_footer")
    if reader_footer_fn then
        run_feature(logger, plugin, "reader_footer", reader_footer_fn)
    end

    -- Always apply the selected chapter-time display format.
    local reader_footer_time_format_fn = load_patch("reader_footer_time_format")
    if reader_footer_time_format_fn then
        run_feature(logger, plugin, "reader_footer_time_format", reader_footer_time_format_fn)
    end

    -- Always apply: hide footer in CBZ files when setting is on (self-disables when off).
    local reader_footer_cbz_hide_fn = load_patch("reader_footer_cbz_hide")
    if reader_footer_cbz_hide_fn then
        run_feature(logger, plugin, "reader_footer_cbz_hide", reader_footer_cbz_hide_fn)
    end

    -- Always apply: swallow holds inside page margins to prevent accidental word selection.
    local margin_hold_guard_fn = load_patch("margin_hold_guard")
    if margin_hold_guard_fn then
        run_feature(logger, plugin, "margin_hold_guard", margin_hold_guard_fn)
    end

    -- Always apply: larger black page numbers in the bookmark/highlight list.
    local bookmarks_fn = load_patch("bookmarks")
    if bookmarks_fn then
        run_feature(logger, plugin, "bookmarks", bookmarks_fn)
    end

    -- Always apply: user-defined highlight color names.
    local highlight_names_fn = load_patch("highlight_names")
    if highlight_names_fn then
        run_feature(logger, plugin, "highlight_names", highlight_names_fn)
    end

    -- Always apply: icon-only DictQuickLookup buttons (self-disables when feature is off).
    local dict_quick_lookup_fn = load_patch("dict_quick_lookup")
    if dict_quick_lookup_fn then
        run_feature(logger, plugin, "dict_quick_lookup", dict_quick_lookup_fn)
    end

    -- Always apply: custom highlight/lookup popup (self-disables when feature is off).
    local highlight_menu_fn = load_patch("highlight_menu")
    logger.dbg("load_patch(highlight_menu)=", tostring(highlight_menu_fn))
    if highlight_menu_fn then
        local ok = run_feature(logger, plugin, "highlight_menu", highlight_menu_fn)
        logger.dbg("run_feature(highlight_menu) ok=", tostring(ok))
    end

    -- Ensure the runtime-patches registry exists.
    local runtime_patches = rawget(_G, "__ZEN_UI_RUNTIME_PATCHES")
    if type(runtime_patches) ~= "table" then
        runtime_patches = {}
        _G.__ZEN_UI_RUNTIME_PATCHES = runtime_patches
    end

    if is_feature_enabled(plugin, "reader_top_status_bar") then
        local fn = load_patch("reader_top_status_bar")
        if fn then
            local ok = run_feature(logger, plugin, "reader_top_status_bar", fn)
            if ok then
                runtime_patches["reader_top_status_bar"] = true
            end
        elseif logger then
            logger.warn("reader patch module missing", "reader_top_status_bar")
        end
    end

    if is_feature_enabled(plugin, "reader_themes") then
        local fn = load_patch("reader_themes")
        if fn then
            local ok = run_feature(logger, plugin, "reader_themes", fn)
            if ok then
                runtime_patches["reader_themes"] = true
            end
        elseif logger then
            logger.warn("reader patch module missing", "reader_themes")
        end
    end

    initialized = true
    return true
end

return M
