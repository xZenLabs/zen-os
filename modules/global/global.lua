local M = {}
local initialized = false

local PATCH_MODULES = {
    night_mode_schedule    = "modules/global/patches/night_mode_schedule",
    warmth_schedule        = "modules/global/patches/warmth_schedule",
    brightness_schedule    = "modules/global/patches/brightness_schedule",
    menu_top_swipe         = "modules/global/patches/menu_top_swipe",
    opds                   = "modules/global/patches/opds",
    cloud_storage_home     = "modules/global/patches/cloud_storage_home",
    kindle_network_profile_guard = "modules/global/patches/kindle_network_profile_guard",
    lockdown_mode          = "modules/global/patches/lockdown_mode",
    incognito_mode         = "modules/global/patches/incognito_mode",
    menu_font              = "modules/global/patches/menu_font",
    unified_title_style    = "modules/global/patches/unified_title_style",
}

local function run_patch(logger, plugin, feature, fn)
    local prev_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    _G.__ZEN_UI_PLUGIN = plugin
    local ok, err = pcall(fn)
    _G.__ZEN_UI_PLUGIN = prev_plugin
    if not ok and logger then
        logger.warn("global patch failed", feature, err)
    end
    return ok
end

local function load_patch(feature)
    local module_name = PATCH_MODULES[feature]
    if not module_name then return nil end
    local ok, patch_fn = pcall(require, module_name)
    if not ok then return nil end
    -- Patch modules may return a plain function or a table with an `apply` key
    if type(patch_fn) == "table" and type(patch_fn.apply) == "function" then
        return patch_fn.apply
    end
    if type(patch_fn) == "function" then return patch_fn end
    return nil
end

local function is_koreader_opds_enabled()
    local settings = rawget(_G, "G_reader_settings")
    if type(settings) ~= "table" or type(settings.readSetting) ~= "function" then
        return true
    end
    local disabled_plugins = settings:readSetting("plugins_disabled")
    return type(disabled_plugins) ~= "table" or not disabled_plugins.opds
end

local function disable_zen_opds(plugin, logger)
    plugin.config.features.zen_opds = false
    if type(plugin.saveConfig) == "function" then
        plugin:saveConfig()
    end
    if logger then
        logger.info("Zen OPDS disabled because KOReader OPDS is disabled")
    end
end

function M.init(logger, plugin)
    if initialized then return true end

    local night_mode_schedule_fn = load_patch("night_mode_schedule")
    if night_mode_schedule_fn then
        run_patch(logger, plugin, "night_mode_schedule", night_mode_schedule_fn)
    end

    local warmth_schedule_fn = load_patch("warmth_schedule")
    if warmth_schedule_fn then
        run_patch(logger, plugin, "warmth_schedule", warmth_schedule_fn)
    end

    local brightness_schedule_fn = load_patch("brightness_schedule")
    if brightness_schedule_fn then
        run_patch(logger, plugin, "brightness_schedule", brightness_schedule_fn)
    end

    local menu_top_swipe_fn = load_patch("menu_top_swipe")
    if menu_top_swipe_fn then
        run_patch(logger, plugin, "menu_top_swipe", menu_top_swipe_fn)
    end

    if plugin.config.features.zen_opds ~= false then
        if is_koreader_opds_enabled() then
            local opds_fn = load_patch("opds")
            if opds_fn then
                run_patch(logger, plugin, "opds", opds_fn)
            end
        else
            disable_zen_opds(plugin, logger)
        end
    end

    local cloud_storage_home_fn = load_patch("cloud_storage_home")
    if cloud_storage_home_fn then
        run_patch(logger, plugin, "cloud_storage_home", cloud_storage_home_fn)
    end

    local kindle_network_profile_guard_fn = load_patch("kindle_network_profile_guard")
    if kindle_network_profile_guard_fn then
        run_patch(logger, plugin, "kindle_network_profile_guard", kindle_network_profile_guard_fn)
    end

    -- Lockdown mode runs last so it wraps any reader-layer patches (e.g. margin_hold_guard).
    local lockdown_mode_fn = load_patch("lockdown_mode")
    if lockdown_mode_fn then
        run_patch(logger, plugin, "lockdown_mode", lockdown_mode_fn)
    end

    -- Always install the incognito monkeypatches; they no-op unless the
    -- incognito_mode feature flag is live, so toggling needs no restart.
    local incognito_mode_fn = load_patch("incognito_mode")
    if incognito_mode_fn then
        run_patch(logger, plugin, "incognito_mode", incognito_mode_fn)
    end

    local menu_font_fn = load_patch("menu_font")
    if menu_font_fn then
        run_patch(logger, plugin, "menu_font", menu_font_fn)
    end

    local unified_title_style_fn = load_patch("unified_title_style")
    if unified_title_style_fn then
        run_patch(logger, plugin, "unified_title_style", unified_title_style_fn)
    end

    -- Hook the global Resume broadcast so schedules are independent of the
    -- active widget. This also covers Android, which broadcasts Resume without
    -- going through Device:_afterResume.
    local Device = require("device")
    local UIManager = require("ui/uimanager")
    local SCHEDULE_STATES = {
        "__ZEN_UI_NIGHT_SCHEDULE",
        "__ZEN_UI_BRIGHTNESS_SCHEDULE",
        "__ZEN_UI_WARMTH_SCHEDULE",
    }
    local FRONTLIGHT_SCHEDULE_STATES = {
        "__ZEN_UI_BRIGHTNESS_SCHEDULE",
        "__ZEN_UI_WARMTH_SCHEDULE",
    }

    local function reschedule_states(states)
        for _i, name in ipairs(states) do
            local state = rawget(_G, name)
            if type(state) == "table" then
                local fn = state.force_reschedule or state.reschedule
                if type(fn) == "function" then pcall(fn) end
            end
        end
    end

    local function reschedule_schedules()
        reschedule_states(SCHEDULE_STATES)
    end

    local function reapply_frontlight_schedules()
        reschedule_states(FRONTLIGHT_SCHEDULE_STATES)
    end

    local function schedule_resume_reapply()
        UIManager:unschedule(reschedule_schedules)
        UIManager:unschedule(reapply_frontlight_schedules)
        UIManager:scheduleIn(0.1, reschedule_schedules)
        -- Some frontlights ignore writes immediately after resume.
        UIManager:scheduleIn(1.5, reapply_frontlight_schedules)
    end

    if type(UIManager.broadcastEvent) == "function" then
        local orig_broadcastEvent = UIManager.broadcastEvent
        UIManager.broadcastEvent = function(self, event, ...)
            if event and event.handler == "onResume" then
                schedule_resume_reapply()
            end
            return orig_broadcastEvent(self, event, ...)
        end
    end

    if type(Device._beforeSuspend) == "function" then
        local orig_beforeSuspend = Device._beforeSuspend
        Device._beforeSuspend = function(self, ...)
            for _i, name in ipairs(SCHEDULE_STATES) do
                local state = rawget(_G, name)
                if type(state) == "table" and type(state._on_suspend) == "function" then
                    pcall(state._on_suspend)
                end
            end
            return orig_beforeSuspend(self, ...)
        end
    end

    -- Reconcile night mode after a crash. On HW-invert devices (e.g. Kindle) the
    -- framebuffer EPDC inversion flag persists at the OS level across restarts,
    -- but G_reader_settings.night_mode is only flushed on a clean exit. A crash
    -- leaves the real HW flag and the saved setting out of sync, so the screen
    -- can be dark while the toggle reads unchecked (or vice versa) with no way to
    -- recover. Treat the saved setting as the source of truth and re-write the HW
    -- flag to match.
    if Device.canHWInvert and Device:canHWInvert() then
        local Screen = Device.screen
        if type(Screen.getHWNightmode) == "function"
            and type(Screen.setHWNightmode) == "function" then
            local want = G_reader_settings:isTrue("night_mode")
            local ok_hw, hw = pcall(Screen.getHWNightmode, Screen)
            if ok_hw and hw ~= want then
                Screen.night_mode = want
                pcall(Screen.setHWNightmode, Screen, want)
                require("ui/uimanager"):setDirty("all", "full")
            end
        end
    end

    initialized = true
    return true
end

return M
