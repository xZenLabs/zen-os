local function apply_night_mode_schedule()
    --[[
        Toggles night mode at two user-defined times per day.
        State survives module reloads via __ZEN_UI_NIGHT_SCHEDULE.
        reschedule() is exposed so settings callbacks can trigger a re-apply.
    --]]

    local UIManager = require("ui/uimanager")
    local getFullRefreshMode = require("common/ui/refresh")
    local Device    = require("device")
    local Screen    = Device.screen

    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    if not zen_plugin or type(zen_plugin.config) ~= "table" then
        return
    end

    -- Persistent state table; survives module-cache clears for stable UIManager references.
    local state = rawget(_G, "__ZEN_UI_NIGHT_SCHEDULE")
    if type(state) ~= "table" then
        state = {}
        _G.__ZEN_UI_NIGHT_SCHEDULE = state
    end

    -- Guard against double-init after a package.loaded purge.
    if state.initialized then
        return
    end

    -- Helpers

    local function is_enabled()
        local plugin   = zen_plugin or rawget(_G, "__ZEN_UI_PLUGIN")
        local features = plugin and plugin.config and plugin.config.features
        return type(features) == "table" and features.night_mode_schedule == true
    end

    local function get_config()
        local plugin = zen_plugin or rawget(_G, "__ZEN_UI_PLUGIN")
        local cfg    = plugin and plugin.config and plugin.config.night_mode_schedule
        if type(cfg) ~= "table" then cfg = {} end
        return {
            night_on_h  = tonumber(cfg.night_on_h)  or 22,
            night_on_m  = tonumber(cfg.night_on_m)  or 0,
            night_off_h = tonumber(cfg.night_off_h) or 7,
            night_off_m = tonumber(cfg.night_off_m) or 0,
        }
    end

    -- Seconds elapsed since local midnight.
    local function now_s()
        local t = os.date("*t")
        return t.hour * 3600 + t.min * 60 + t.sec
    end

    -- Seconds from now until the next occurrence of HH:MM (always > 0).
    local function seconds_until(h, m)
        local diff = (h * 3600 + m * 60) - now_s()
        if diff <= 0 then diff = diff + 86400 end
        return diff
    end

    -- True when the current local time falls inside the night window.
    local function is_night_now()
        local cfg  = get_config()
        local cur  = now_s()
        local on_s = cfg.night_on_h  * 3600 + cfg.night_on_m  * 60
        local off_s = cfg.night_off_h * 3600 + cfg.night_off_m * 60
        if on_s == off_s then return false end
        if on_s < off_s then
            -- Night window within one day (e.g. 20:00 → 22:00).
            return cur >= on_s and cur < off_s
        else
            -- Night window wraps midnight (e.g. 22:00 → 07:00).
            return cur >= on_s or cur < off_s
        end
    end

    -- Forced (resume) passes re-assert HW inversion only when the flag drifted.
    local function set_night_mode(enable, force)
        local changed = Screen.night_mode ~= enable
        local hw_invert = Device:canHWInvert()
        local hw_stale = false
        if force and hw_invert and not changed then
            local ok_hw, hw = pcall(Screen.getHWNightmode, Screen)
            hw_stale = not ok_hw or hw ~= enable -- Unknown flag: re-assert.
        end
        if not changed and not hw_stale then return end
        G_reader_settings:saveSetting("night_mode", enable)
        if hw_invert then
            Screen.night_mode = enable
            pcall(Screen.setHWNightmode, Screen, enable)
        else
            Screen:toggleNightMode()
        end
        if hw_invert and changed then
            local ReaderThemes = require("common/reader_themes")
            if ReaderThemes.isEnabled(zen_plugin) then ReaderThemes.applyCurrent(zen_plugin) end
        end
        -- SW toggleNightMode is wrapped by the frontlight schedules; HW invert bypasses it.
        if hw_invert then
            for _i, name in ipairs({
                "__ZEN_UI_BRIGHTNESS_SCHEDULE",
                "__ZEN_UI_WARMTH_SCHEDULE",
            }) do
                local frontlight_state = rawget(_G, name)
                if type(frontlight_state) == "table"
                        and type(frontlight_state.apply_mode_value) == "function" then
                    pcall(frontlight_state.apply_mode_value)
                end
            end
        end
        UIManager:setDirty("all", getFullRefreshMode())
    end

    -- -------------------------------------------------------------------------
    -- Stable function references (required by UIManager:unschedule).
    -- Declared before assignment so the closures can capture the local vars.
    -- -------------------------------------------------------------------------

    local night_on_fn
    local night_off_fn

    -- Each callback applies its target state then self-reschedules for +24 h.
    -- Drift is corrected on every device resume via reschedule().
    night_on_fn = function()
        if is_enabled() then
            set_night_mode(true)
            UIManager:scheduleIn(86400, night_on_fn)
        end
    end

    night_off_fn = function()
        if is_enabled() then
            set_night_mode(false)
            UIManager:scheduleIn(86400, night_off_fn)
        end
    end

    -- -------------------------------------------------------------------------
    -- Public reschedule – cancel outstanding timers, apply the correct state
    -- for the current time of day, then arm both transition timers.
    -- Exposed via state so settings callbacks can call it after config changes.
    -- -------------------------------------------------------------------------

    local function reschedule(force)
        UIManager:unschedule(night_on_fn)
        UIManager:unschedule(night_off_fn)
        if not is_enabled() then return end
        set_night_mode(is_night_now(), force)
        local cfg = get_config()
        UIManager:scheduleIn(seconds_until(cfg.night_on_h,  cfg.night_on_m),  night_on_fn)
        UIManager:scheduleIn(seconds_until(cfg.night_off_h, cfg.night_off_m), night_off_fn)
    end

    state.reschedule       = reschedule
    state.force_reschedule = function() reschedule(true) end
    state._on_suspend = function()
        UIManager:unschedule(night_on_fn)
        UIManager:unschedule(night_off_fn)
    end
    state.initialized = true

    -- -------------------------------------------------------------------------
    -- Boot-time: apply the correct state now and arm the initial timers.
    -- -------------------------------------------------------------------------

    if is_enabled() then
        reschedule()
    end
end

return apply_night_mode_schedule
