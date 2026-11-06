local M = {}
local initialized = false

local PATCH_MODULES = {
    library_navigation = "modules/reader/patches/library_navigation",
    opening_banner = "modules/reader/patches/opening_banner",
    book_status = "modules/reader/patches/book_status",
    end_book = "modules/reader/patches/end_book",
    reader_top_status_bar = "modules/reader/patches/reader_top_status_bar",
    reader_themes = "modules/reader/patches/reader_themes",
    screensaver_cover = "modules/reader/patches/screensaver_cover",
    reader_footer = "modules/reader/patches/reader_footer",
    reader_footer_time_format = "modules/reader/patches/reader_footer_time_format",
    reader_footer_cbz_hide = "modules/reader/patches/reader_footer_cbz_hide",
    reader_flash_cbz = "modules/reader/patches/reader_flash_cbz",
    margin_hold_guard = "modules/reader/patches/margin_hold_guard",
    bookmarks = "modules/reader/patches/bookmarks",
    page_browser = "modules/reader/patches/page_browser",
    reader_references = "modules/reader/patches/reader_references",
    stable_page_statistics = "modules/reader/patches/stable_page_statistics",
    highlight_names = "modules/reader/patches/highlight_names",
    night_highlights = "modules/reader/patches/night_highlights",
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

-- Also patch library-side UI (statistics, opening-banner tap hooks, book status,
-- end-book menu, screensaver, dictionary), so they apply at boot. Patches that
-- target reader-only classes defer themselves via common/on_require.
local BOOT_FEATURES = {
    "stable_page_statistics", "opening_banner", "book_status", "end_book", "screensaver_cover",
    "dict_quick_lookup",
}

-- ReaderUI-only; applied when KOReader first requires ReaderUI.
local READER_FEATURES = {
    "reader_references",
    -- Route KOReader's File browser gesture through the same transition as ZenOS.
    "library_navigation",
    "page_browser", -- self-disables when feature is off
    "status_on_open",
    "reader_footer", -- two-filler L/C/R layout support
    "reader_footer_time_format",
    "reader_footer_cbz_hide", -- self-disables when off
    "reader_flash_cbz",
    "margin_hold_guard", -- swallow holds inside page margins
    "bookmarks", -- larger black page numbers in the bookmark/highlight list
    "highlight_names",
    "night_highlights",
    "highlight_menu", -- self-disables when feature is off
}

local function apply(logger, plugin, features)
    for _i, feature in ipairs(features) do
        local fn = load_patch(feature)
        if fn then run_feature(logger, plugin, feature, fn) end
    end
end

-- Optional patches; zen_settings_apply may already have applied them at runtime.
local function apply_runtime(logger, plugin, runtime_patches, feature)
    if runtime_patches[feature] then return end
    local fn = load_patch(feature)
    if fn then
        if run_feature(logger, plugin, feature, fn) then runtime_patches[feature] = true end
    elseif logger then
        logger.warn("reader patch module missing", feature)
    end
end

local function apply_reader(logger, plugin)
    apply(logger, plugin, READER_FEATURES)

    -- Ensure the runtime-patches registry exists.
    local runtime_patches = rawget(_G, "__ZEN_UI_RUNTIME_PATCHES")
    if type(runtime_patches) ~= "table" then
        runtime_patches = {}
        _G.__ZEN_UI_RUNTIME_PATCHES = runtime_patches
    end

    if is_feature_enabled(plugin, "reader_top_status_bar") then
        apply_runtime(logger, plugin, runtime_patches, "reader_top_status_bar")
    end

    local Device = require("device")
    local color_kindle = Device.isKindle and Device:isKindle()
        and Device.hasColorScreen and Device:hasColorScreen()
    local reader_controls = plugin.config and type(plugin.config.reader_controls) == "table"
    if reader_controls then require("modules/menu/reader_controls/profiles").install(plugin) end
    if is_feature_enabled(plugin, "reader_themes") or color_kindle or reader_controls then
        apply_runtime(logger, plugin, runtime_patches, "reader_themes")
    end
end

function M.init(logger, plugin)
    if initialized then
        return true
    end
    initialized = true
    apply(logger, plugin, BOOT_FEATURES)
    require("common/on_require").whenLoaded("apps/reader/readerui", function() apply_reader(logger, plugin) end)
    return true
end

return M
