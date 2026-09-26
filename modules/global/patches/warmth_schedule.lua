local function apply_warmth_schedule()
    --[[
        Sets screen warmth by time or light/dark mode.
        Only active on devices with natural-light frontlight.
        State survives module reloads via __ZEN_UI_WARMTH_SCHEDULE.
    --]]

    local Device = require("device")
    local UIManager = require("ui/uimanager")
    local Screen = Device.screen

    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    if not zen_plugin or type(zen_plugin.config) ~= "table" then return end

    local state = rawget(_G, "__ZEN_UI_WARMTH_SCHEDULE")
    if type(state) ~= "table" then
        state = {}
        _G.__ZEN_UI_WARMTH_SCHEDULE = state
    end

    -- Re-install hooks on the current plugin instance (survives FileManager:reinit).
    do
        local orig_suspend = zen_plugin.onSuspend
        zen_plugin.onSuspend = function(self, ...)
            if state._on_suspend then state._on_suspend() end
            if type(orig_suspend) == "function" then
                return orig_suspend(self, ...)
            end
        end
        local orig_resume = zen_plugin.onResume
        zen_plugin.onResume = function(self, ...)
            local result
            if type(orig_resume) == "function" then
                result = orig_resume(self, ...)
            end
            if state._on_resume then state._on_resume() end
            return result
        end
    end

    if state.initialized then return end

    -- Helpers

    local function is_enabled()
        local plugin   = zen_plugin or rawget(_G, "__ZEN_UI_PLUGIN")
        local features = plugin and plugin.config and plugin.config.features
        return type(features) == "table" and features.warmth_schedule == true
    end

    local function get_config()
        local plugin = zen_plugin or rawget(_G, "__ZEN_UI_PLUGIN")
        local cfg    = plugin and plugin.config and plugin.config.warmth_schedule
        if type(cfg) ~= "table" then cfg = {} end
        return {
            day_h       = tonumber(cfg.day_h)       or 7,
            day_m       = tonumber(cfg.day_m)       or 0,
            day_value   = tonumber(cfg.day_value)   or 3,
            night_h     = tonumber(cfg.night_h)     or 20,
            night_m     = tonumber(cfg.night_m)     or 0,
            night_value = tonumber(cfg.night_value) or 8,
            use_mode_values = cfg.use_mode_values == true,
        }
    end

    local function uses_mode_values()
        return not is_enabled() and get_config().use_mode_values
    end

    local function now_s()
        local t = os.date("*t")
        return t.hour * 3600 + t.min * 60 + t.sec
    end

    local function seconds_until(h, m)
        local diff = (h * 3600 + m * 60) - now_s()
        if diff <= 0 then diff = diff + 86400 end
        return diff
    end

    -- Returns the warmth value that should be active right now.
    local function current_warmth_value()
        local cfg   = get_config()
        local cur   = now_s()
        local day_s   = cfg.day_h   * 3600 + cfg.day_m   * 60
        local night_s = cfg.night_h * 3600 + cfg.night_m * 60
        if day_s == night_s then return cfg.day_value end
        if day_s < night_s then
            return (cur >= day_s and cur < night_s) and cfg.day_value or cfg.night_value
        else
            -- Day window wraps midnight
            return (cur >= day_s or cur < night_s) and cfg.day_value or cfg.night_value
        end
    end

    local function set_warmth(value, force)
        local Powerd = Device.powerd
        if Powerd and type(Powerd.setWarmth) == "function"
           and type(Powerd.fromNativeWarmth) == "function" then
            local lo = Powerd.fl_warmth_min or 0
            local hi = Powerd.fl_warmth_max or 24
            pcall(Powerd.setWarmth, Powerd,
                Powerd:fromNativeWarmth(math.max(lo, math.min(hi, value))), force)
        end
    end

    local function apply_mode_value(force)
        if not uses_mode_values() then return end
        local cfg = get_config()
        set_warmth(Screen.night_mode and cfg.night_value or cfg.day_value, force)
    end

    -- -------------------------------------------------------------------------
    -- Stable function references required by UIManager:unschedule
    -- -------------------------------------------------------------------------

    local day_fn
    local night_fn

    day_fn = function()
        if is_enabled() then
            set_warmth(get_config().day_value)
            UIManager:scheduleIn(86400, day_fn)
        end
    end

    night_fn = function()
        if is_enabled() then
            set_warmth(get_config().night_value)
            UIManager:scheduleIn(86400, night_fn)
        end
    end

    -- -------------------------------------------------------------------------
    -- Public reschedule
    -- -------------------------------------------------------------------------

    local function reschedule(force)
        UIManager:unschedule(day_fn)
        UIManager:unschedule(night_fn)
        if not is_enabled() then
            apply_mode_value(force)
            return
        end
        set_warmth(current_warmth_value(), force)
        local cfg = get_config()
        UIManager:scheduleIn(seconds_until(cfg.day_h,   cfg.day_m),   day_fn)
        UIManager:scheduleIn(seconds_until(cfg.night_h, cfg.night_m), night_fn)
    end

    state.reschedule       = reschedule
    state.force_reschedule = function() reschedule(true) end
    state.apply_mode_value = apply_mode_value
    state._on_suspend = function()
        UIManager:unschedule(day_fn)
        UIManager:unschedule(night_fn)
    end
    state._on_resume = function()
        UIManager:nextTick(function() reschedule() end)
    end
    state.initialized = true

    if type(Screen.toggleNightMode) == "function" then
        local orig_toggle_night_mode = Screen.toggleNightMode
        Screen.toggleNightMode = function(self, ...)
            local result = orig_toggle_night_mode(self, ...)
            apply_mode_value()
            return result
        end
    end

    -- -------------------------------------------------------------------------
    -- Boot-time: apply correct state and arm timers
    -- -------------------------------------------------------------------------

    if is_enabled() or uses_mode_values() then
        reschedule()
    end
end

return apply_warmth_schedule
