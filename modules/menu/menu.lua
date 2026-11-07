local M = {}
local initialized = false

local FEATURES = {
    "quick_settings",
    "app_launcher",
    "zen_mode",
}

local PATCH_MODULES = {
    quick_settings = "modules/menu/patches/quick_settings",
    app_launcher = "modules/menu/patches/app_launcher",
    reader_controls = "modules/menu/patches/reader_controls",
    zen_mode = "modules/menu/patches/zen_mode",
    disable_top_menu_swipe_zones = "modules/menu/patches/disable_top_menu_swipe_zones",
    touch_menu_footer = "modules/menu/patches/touch_menu_footer",
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
        logger.warn("grouped menu feature failed", feature, err)
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

    -- Ensure the runtime-patches registry exists.
    local runtime_patches = rawget(_G, "__ZEN_UI_RUNTIME_PATCHES")
    if type(runtime_patches) ~= "table" then
        runtime_patches = {}
        _G.__ZEN_UI_RUNTIME_PATCHES = runtime_patches
    end

    for _i, feature in ipairs(FEATURES) do
        if is_feature_enabled(plugin, feature) then
            local fn = load_patch(feature)
            if fn then
                local ok = run_feature(logger, plugin, feature, fn)
                if ok then
                    runtime_patches[feature] = true
                end
            elseif logger then
                logger.warn("menu patch module missing", feature)
            end
        end
    end

    local function apply_always(feature)
        local fn = load_patch(feature)
        if fn and run_feature(logger, plugin, feature, fn) then
            runtime_patches[feature] = true
        end
    end
    -- Always apply: swipe zones keep quick settings first; footer moves pagination left
    apply_always("disable_top_menu_swipe_zones")
    apply_always("touch_menu_footer")
    -- ReaderMenu-only; waits for ReaderUI.
    require("common/on_require").whenLoaded("apps/reader/readerui", function() apply_always("reader_controls") end)

    initialized = true
    return true
end

return M
