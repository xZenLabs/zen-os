local Device = require("device")
local LuaSettings = require("luasettings")
local PresetStore = require("config/preset_store")
local UIManager = require("ui/uimanager")

local M = {}
local SAMPLE_SECONDS = 30 * 60
local MAX_EVENTS = 512
-- compact level curve for the battery page (kept CURVE_DAYS, survives
-- the archiving of the samples): { time, level, flags } with flags
-- 1 = charging, 2 = asleep, 4 = gap before this point, 8 = Bluetooth on
local CURVE_DAYS = 31
local settings
local sleeping = false
local timer
local charge_timer
local bt_timer
local pending_gap = false
-- right after waking the fuel gauge still reports the value from before
-- sleep; the first sample waits until it has caught up.
local WAKE_DELAY = 20
local wake_pending, wake_charge_event = false, false
local wake_timer
local history
local history_tail
local HISTORY_TOTALS = {
    discharge_loss = "discharge_loss_pct", discharge_time = "discharge_seconds",
    awake_loss = "awake_loss_pct", awake_discharge_time = "awake_discharge_seconds",
    asleep_loss = "asleep_loss_pct", asleep_discharge_time = "asleep_discharge_seconds",
    awake_time = "awake_seconds", asleep_time = "asleep_seconds",
    -- awake with Bluetooth on (not part of awake_loss / awake_discharge_time)
    bt_loss = "bt_awake_loss_pct", bt_discharge_time = "bt_awake_discharge_seconds",
    -- awake with Wi-Fi on, and with Wi-Fi and Bluetooth on at the same time
    wifi_loss = "wifi_awake_loss_pct", wifi_discharge_time = "wifi_awake_discharge_seconds",
    both_loss = "both_awake_loss_pct", both_discharge_time = "both_awake_discharge_seconds",
}
local HISTORY_READINGS = {
    full_charge_time = "last_full_charge_seconds",
    full_mah = "full_capacity_mah", design_mah = "design_capacity_mah", health = "health_pct",
}

local function nonnegative(value)
    return type(value) == "number" and value >= 0 and value < math.huge
end

local function valid_session(session)
    return type(session) == "table" and nonnegative(session.start_time) and nonnegative(session.time)
        and session.time >= session.start_time and nonnegative(session.start_level)
        and nonnegative(session.level) and session.level <= 100 and session.level >= session.start_level
        and type(session.full) == "boolean"
end

local function merge_history(summary)
    if type(summary) ~= "table" or summary.version ~= 1
        or not nonnegative(summary.start_time) or not nonnegative(summary.end_time)
        or summary.end_time < summary.start_time then return end
    local replaced = history_tail and history_tail.start_time == summary.start_time and history_tail
    if replaced and replaced.end_time > summary.end_time then return end
    for key, field in pairs(HISTORY_TOTALS) do
        local value = nonnegative(summary[field]) and summary[field] or 0
        local old = replaced and nonnegative(replaced[field]) and replaced[field] or 0
        history[key] = (history[key] or 0) + value - old
    end
    for key, field in pairs(HISTORY_READINGS) do
        if nonnegative(summary[field]) then history[key] = summary[field] end
    end
    if nonnegative(summary.last_charge_gain_pct) and summary.last_charge_gain_pct > 0
        and summary.last_charge_gain_pct <= 100 then
        history.charge_gain = summary.last_charge_gain_pct
        history.charge_rate = nonnegative(summary.last_charge_pct_per_hour)
            and summary.last_charge_pct_per_hour > 0 and summary.last_charge_pct_per_hour or nil
    end
    if summary.last_unplug == false or nonnegative(summary.last_unplug) then history.last_unplug = summary.last_unplug end
    if valid_session(summary.last_full_charge) then history.last_full_charge = summary.last_full_charge end
    if type(summary.usage_baseline) == "table" then history.usage_baseline = summary.usage_baseline end
    if nonnegative(summary.samples) and not replaced then
        history.samples = (history.samples or 0) + summary.samples
    end
    if nonnegative(summary.start_time) and (not history.first_time or summary.start_time < history.first_time) then
        history.first_time = summary.start_time
    end
    history_tail = summary
end

local function load_history()
    history, history_tail = {}, nil
    local file = io.open(PresetStore.rootDir() .. "/battery_history", "r")
    if not file then return end
    local json = require("json")
    for line in file:lines() do
        local ok, summary = pcall(json.decode, line)
        if ok then merge_history(summary) end
    end
    file:close()
end

--- Bluetooth on? (true / false; nil when unknown or not available)
local function bluetooth_on()
    local ok, Bluetooth = pcall(require, "modules/menu/bluetooth/bluetooth")
    if not ok or type(Bluetooth) ~= "table" then return nil end
    if Bluetooth.isChanging and Bluetooth.isChanging() then
        return Bluetooth.getCachedState and Bluetooth.getCachedState() or nil
    end
    local ok2, state = pcall(Bluetooth.getState)
    if ok2 and state ~= nil then return state == true end
    return nil
end

--- Wi-Fi on? (true / false; nil when unknown)
local function wifi_on()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or type(NetworkMgr) ~= "table" or type(NetworkMgr.isWifiOn) ~= "function" then return nil end
    local ok2, state = pcall(NetworkMgr.isWifiOn, NetworkMgr)
    if ok2 and state ~= nil then return state == true end
    return nil
end

local function capture()
    local powerd = Device:getPowerDevice()
    if not powerd then return nil end
    local ok, raw_level, charging, charged = pcall(function()
        local full = powerd:isCharged()
        return powerd:getCapacityHW(), powerd:isCharging() or full, full
    end)
    if not ok then return nil end
    local level = tonumber(raw_level)
    if not level or level <= 0 or level > 100 then return nil end
    return {
        time = os.time(), level = level,
        charging = charging,
        charged = charged,
        sleeping = sleeping,
        bluetooth = not sleeping and bluetooth_on() or nil,
        wifi = not sleeping and wifi_on() or nil,
        mah = M._read_mah and M._read_mah() or nil,
    }
end

local function read_attr(dir, name)
    local file = io.open(dir .. "/" .. name, "r")
    if not file then return nil end
    local value = file:read("*l")
    file:close()
    return value
end

local function battery_dir()
    local powerd = Device:getPowerDevice()
    for _i, key in ipairs({ "batt_capacity_file", "capacity_file" }) do
        local path = powerd and powerd[key]
        local dir = type(path) == "string" and path:match("^(.*)/[^/]+$")
        if dir and (read_attr(dir, "type") == "Battery"
            or read_attr(dir, "charge_full") or read_attr(dir, "charge_now")) then return dir end
    end

    local ok, iter, state = pcall(require("libs/libkoreader-lfs").dir, "/sys/class/power_supply")
    if not ok or type(iter) ~= "function" then return nil end
    local found
    for name in iter, state do
        local dir = "/sys/class/power_supply/" .. name
        if read_attr(dir, "type") == "Battery" then
            if found then return nil end
            found = dir
        end
    end
    return found
end

local function device_capacity()
    local dir = battery_dir()
    if not dir then return nil, nil end
    local function value(name)
        local number = tonumber(read_attr(dir, name))
        return number and number >= 0 and number or nil
    end
    local full, design = value("charge_full"), value("charge_full_design")
    local empty, design_empty = value("charge_empty"), value("charge_empty_design")
    local use_empty = full and design and empty and design_empty
        and full > empty and design > design_empty
    local current_charge = value("charge_now")
    if use_empty then
        full, design = full - empty, design - design_empty
        if current_charge then current_charge = math.max(0, current_charge - empty) end
    end
    local full_mah = full and full >= 50000 and full <= 100000000 and full / 1000 or nil
    local design_mah = design and design >= 50000 and design <= 100000000 and design / 1000 or nil
    local current_mah = current_charge and current_charge <= 100000000 and current_charge / 1000 or nil
    local health = full_mah and design_mah and full_mah / design_mah * 100 or nil
    if health and (health <= 0 or health > 200) then health = nil end
    return full_mah, design_mah, health, current_mah
end

--- Current charge in mAh from the fuel gauge (finer than whole percent).
--- Stored with every sample; the use rates are computed from it when available.
function M._read_mah()
    local ok, _full, _design, _health, current = pcall(device_capacity)
    if ok and type(current) == "number" then return math.floor(current * 10 + 0.5) / 10 end
    return nil
end

local function archive(events)
    if #events == 0 then return true end
    local stats = M.snapshot(false, false)
    local gaps = 0
    for i = 2, #events do
        if events[i].gap then gaps = gaps + 1 end
    end
    local summary = {
        version = 1,
        start_time = events[1].time, end_time = events[#events].time,
        start_level_pct = events[1].level, end_level_pct = events[#events].level,
        samples = #events, gaps = gaps,
        discharge_pct_per_hour = stats.overall,
        awake_pct_per_hour = stats.awake, asleep_pct_per_hour = stats.asleep,
        discharge_loss_pct = stats.discharge_loss,
        awake_loss_pct = stats.awake_loss, asleep_loss_pct = stats.asleep_loss,
        discharge_seconds = stats.discharge_time,
        awake_discharge_seconds = stats.awake_discharge_time,
        asleep_discharge_seconds = stats.asleep_discharge_time,
        awake_seconds = stats.awake_time, asleep_seconds = stats.asleep_time,
        bt_awake_loss_pct = stats.bt_loss, bt_awake_discharge_seconds = stats.bt_discharge_time,
        wifi_awake_loss_pct = stats.wifi_loss, wifi_awake_discharge_seconds = stats.wifi_discharge_time,
        both_awake_loss_pct = stats.both_loss, both_awake_discharge_seconds = stats.both_discharge_time,
        last_charge_pct_per_hour = stats.charge_rate, last_charge_gain_pct = stats.charge_gain,
        last_full_charge_seconds = stats.full_charge_time,
        last_unplug = settings:readSetting("last_unplug"),
        last_full_charge = settings:readSetting("last_full_charge"),
        usage_baseline = settings:readSetting("usage_baseline"),
        full_capacity_mah = stats.full_mah, design_capacity_mah = stats.design_mah,
        health_pct = stats.health,
    }
    local encoded = require("json").encode(summary)
    local file, err = io.open(PresetStore.rootDir() .. "/battery_history", "a+")
    local saved
    if file then
        local prefix = ""
        if file:seek("end") > 0 then
            file:seek("end", -1)
            if file:read(1) ~= "\n" then prefix = "\n" end
        end
        saved, err = file:write(prefix .. encoded .. "\n")
        if saved then saved, err = file:flush() end
        if saved then
            local ffiutil = require("ffi/util")
            saved, err = ffiutil.fsyncOpenedFile(file)
            if saved then saved, err = ffiutil.fsyncDirectory(PresetStore.rootDir()) end
        end
        local closed, close_err = file:close()
        if not closed then saved, err = nil, close_err end
    end
    if not saved then
        require("common/zen_logger").new("battery_stats").warn("Could not save battery history:", err)
        return false
    end
    merge_history(summary)
    return true
end

local function curve_point(event)
    return { event.time, event.level,
        (event.charging and 1 or 0) + (event.sleeping and 2 or 0) + (event.gap and 4 or 0)
        + (event.bluetooth and 8 or 0) + (event.wifi and 16 or 0), event.mah }
end

local function curve_add(event)
    local curve = settings:readSetting("curve")
    if type(curve) ~= "table" then
        curve = {}
        settings:saveSetting("curve", curve)
    end
    curve[#curve + 1] = curve_point(event)
    local cutoff = event.time - CURVE_DAYS * 86400
    if curve[1] and curve[1][1] < cutoff then
        local keep = {}
        for _i, p in ipairs(curve) do
            if p[1] >= cutoff then keep[#keep + 1] = p end
        end
        settings:saveSetting("curve", keep)
    end
end

local function charging_session(previous, event, session)
    if event.gap and not event.charging then return session end
    if event.gap or (previous and (event.time < previous.time
        or (event.charging and event.level < previous.level))) then session = nil end
    if event.charging and (not session or not previous or not previous.charging) then
        return { start_time = event.time, start_level = event.level,
            time = event.time, level = event.level, full = event.charged or event.level == 100 }
    end
    if session and previous and previous.charging and not session.full
        and event.time >= session.time and event.level >= session.level then
        return { start_time = session.start_time, start_level = session.start_level,
            time = event.time, level = event.level, full = event.charged or event.level == 100 }
    end
    return session
end

local function charge_ended(previous, event)
    return previous and not event.charging and (previous.charging or event.level > previous.level)
end

local function sample(gap, charging_event, force)
    if not settings then return end
    if wake_pending and not force and not sleeping then
        if charging_event then wake_charge_event = true end
        return
    end
    local event = capture()
    if not event then pending_gap = true; return end
    local events = settings:readSetting("events")
    local previous = events[#events]
    local same_state = previous and previous.level == event.level and previous.charging == event.charging
        and previous.charged == event.charged and previous.sleeping == event.sleeping
        and (previous.bluetooth or false) == (event.bluetooth or false)
        and (previous.wifi or false) == (event.wifi or false)
    if same_state and not gap and not pending_gap and previous.time == event.time then return end
    -- KOReader switching between reader and library stops and starts the
    -- log within a second; such a point adds nothing (and no real gap)
    if same_state and event.time >= previous.time and event.time - previous.time <= 5 then
        pending_gap = false
        return
    end
    event.gap = gap or pending_gap
        or (previous and previous.charging ~= event.charging and not charging_event) or nil
    pending_gap = false
    local session = charging_session(previous, event, settings:readSetting("charge_session"))
    settings:saveSetting("charge_session", session)
    if session and session.full and session.time > session.start_time then
        settings:saveSetting("last_full_charge", session)
    end
    if session and session.time > session.start_time and session.level > session.start_level
        and (session.full or not event.charging) then
        settings:saveSetting("last_charge", session)
    end
    if previous and not previous.charging and event.level > previous.level then
        settings:saveSetting("last_unplug", false)
    elseif previous and previous.charging and not event.charging then
        if event.gap then
            settings:saveSetting("last_unplug", false)
        else
            settings:saveSetting("last_unplug", event.time)
        end
    end
    events[#events + 1] = event
    curve_add(event)
    if charge_ended(previous, event) then
        local stats, baseline = M.snapshot(false), {}
        for key in pairs(HISTORY_TOTALS) do baseline[key] = stats[key] end
        settings:saveSetting("usage_baseline", baseline)
    end
    if #events > MAX_EVENTS and archive(events) then
        settings:saveSetting("events", { event }) -- Keep the next window's starting sample.
    end
    settings:flush()
end

local function schedule()
    UIManager:unschedule(timer)
    if sleeping then return end
    UIManager:scheduleIn(SAMPLE_SECONDS, timer)
end

timer = function()
    sample()
    schedule()
end

charge_timer = function()
    sample(nil, true)
end

bt_timer = function()
    -- only when a radio really changed; repeated state events add no point
    local events = settings and settings:readSetting("events") or {}
    local last = events[#events]
    if last and not last.sleeping and (last.bluetooth or false) == (bluetooth_on() or false)
            and (last.wifi or false) == (wifi_on() or false) then
        return
    end
    sample()
end

wake_timer = function()
    if not wake_pending then return end
    wake_pending = false
    local charge_event = wake_charge_event
    wake_charge_event = false
    sample(nil, charge_event or nil, true)
    schedule()
end

-- suspend, resume and charger events straight from the device. The
-- ZenOS plugin only receives these as widget events while its FileManager or
-- reader is in the window stack; with the ZenOS home screen on top they never
-- arrive, so sleep periods after a fresh start went unrecorded. The calls are
-- idempotent, so the plugin's own event handlers may call them as well.
local function hook_device()
    if Device._zen_battery_hooked then return end
    Device._zen_battery_hooked = true
    local function wrap(name, before, after)
        local orig = Device[name]
        if type(orig) ~= "function" then return end
        Device[name] = function(self, ...)
            if before then pcall(before) end
            local r = { orig(self, ...) }
            if after then pcall(after) end
            return unpack(r)
        end
    end
    wrap("_beforeSuspend", function() M.suspend() end)
    wrap("_afterResume", nil, function() M.resume() end)
    wrap("_beforeCharging", nil, function() M.chargingChanged() end)
    wrap("_afterNotCharging", nil, function() M.chargingChanged() end)
end

function M.start()
    if settings or not Device:hasBattery() then return end
    hook_device()
    settings = LuaSettings:open(PresetStore.rootDir() .. "/battery.lua")
    load_history()
    local events = settings:readSetting("events")
    if type(events) ~= "table" then events = {} end
    for i = #events, 1, -1 do
        local event = events[i]
        if type(event) ~= "table" or type(event.time) ~= "number"
            or type(event.level) ~= "number" or type(event.charging) ~= "boolean"
            or type(event.sleeping) ~= "boolean" then
            table.remove(events, i)
        end
    end
    if history_tail and events[1] and events[1].time == history_tail.start_time then
        -- A saved summary may outlive a failed write of the trimmed log.
        while events[1] and events[1].time < history_tail.end_time do table.remove(events, 1) end
    end
    for _i, key in ipairs({ "last_unplug", "last_full_charge", "usage_baseline" }) do
        if settings:readSetting(key) == nil then settings:saveSetting(key, history[key]) end
    end
    for _i, key in ipairs({ "charge_session", "last_charge", "last_full_charge" }) do
        if not valid_session(settings:readSetting(key)) then settings:saveSetting(key, nil) end
    end
    local session = settings:readSetting("charge_session")
    if not settings:readSetting("last_charge") and session
        and session.time > session.start_time and session.level > session.start_level
        and (session.full or (events[#events] and not events[#events].charging)) then
        settings:saveSetting("last_charge", session)
    end
    settings:saveSetting("events", events)
    if type(settings:readSetting("curve")) ~= "table" then
        -- first start with the curve: begin with the samples still in the log
        local curve = {}
        for _i, event in ipairs(events) do curve[#curve + 1] = curve_point(event) end
        settings:saveSetting("curve", curve)
    end
    sample(true) -- KOReader may have been closed or the device charged while it was off.
    schedule()
end

function M.suspend()
    if not settings or sleeping then return end
    UIManager:unschedule(charge_timer)
    UIManager:unschedule(wake_timer)
    wake_pending, wake_charge_event = false, false
    sleeping = true
    sample()
    UIManager:unschedule(timer)
end

function M.resume()
    if not settings then return end
    if sleeping then
        sleeping = false
        wake_pending, wake_charge_event = true, false
        UIManager:unschedule(wake_timer)
        UIManager:scheduleIn(WAKE_DELAY, wake_timer)
        return -- wake_timer takes the sample and schedules the next one
    end
    schedule()
end

function M.chargingChanged()
    if not settings or sleeping then return end
    UIManager:unschedule(charge_timer)
    UIManager:scheduleIn(1.5, charge_timer)
end

--- Bluetooth or Wi-Fi switched on or off: add a point so the curve shows the change.
function M.bluetoothChanged()
    if not settings or sleeping then return end
    UIManager:unschedule(bt_timer)
    UIManager:scheduleIn(3, bt_timer)
end
M.wifiChanged = M.bluetoothChanged

function M.stop()
    if not settings then return end
    UIManager:unschedule(timer)
    UIManager:unschedule(charge_timer)
    UIManager:unschedule(bt_timer)
    UIManager:unschedule(wake_timer)
    sample(nil, nil, true)
    settings = nil
    sleeping = false
    pending_gap = false
    wake_pending, wake_charge_event = false, false
end

--- Samples in the log and the time of the first one.
function M.logInfo()
    if not settings then return 0, nil end
    local events = settings:readSetting("events") or {}
    local count = (history.samples or 0) + #events
    local first = history.first_time
    if events[1] and (not first or events[1].time < first) then first = events[1].time end
    local curve = settings:readSetting("curve")
    if type(curve) == "table" and curve[1] and (not first or curve[1][1] < first) then first = curve[1][1] end
    return count, first
end

function M.reset()
    if not settings then return false end
    UIManager:unschedule(bt_timer)
    sample(nil, nil, true)
    local events = settings:readSetting("events")
    if not archive(events) then return false end
    settings:saveSetting("events", events[#events] and { events[#events] } or {})
    settings:flush()
    if settings.file then os.remove(settings.file .. ".old") end
    return true
end

--- Level curve of the last CURVE_DAYS days, oldest first, plus the current
--- level: { { time, level, flags } }.
function M.curve()
    if not settings then return {} end
    local out = {}
    for _i, p in ipairs(settings:readSetting("curve") or {}) do out[#out + 1] = p end
    local current = capture()
    if current and (not out[#out] or current.time > out[#out][1]) then
        out[#out + 1] = curve_point(current)
    end
    return out
end

function M.snapshot(include_current, include_history)
    if not settings then return nil end
    local events = settings:readSetting("events")
    local current = include_current ~= false and capture() or nil
    local previous = events[#events]
    local session = settings:readSetting("charge_session")
    if current then
        current.gap = pending_gap or (previous and previous.charging ~= current.charging)
        session = charging_session(previous, current, session)
    end
    local last_full = settings:readSetting("last_full_charge")
    if session and session.full and session.time > session.start_time then last_full = session end
    local charge_time = session and session.time - session.start_time or 0
    local charge_gain = session and session.level - session.start_level or 0
    local charge_rate = charge_time >= 60 and charge_gain > 0 and charge_gain * 3600 / charge_time or nil
    local last_charge = settings:readSetting("last_charge")
    if session and session.full and charge_gain > 0 then last_charge = session end
    local previous_rate, previous_gain = history.charge_rate, history.charge_gain
    if last_charge then
        local elapsed = last_charge.time - last_charge.start_time
        previous_gain = last_charge.level - last_charge.start_level
        previous_rate = elapsed >= 60 and previous_gain > 0 and previous_gain * 3600 / elapsed or nil
    elseif not previous_gain then
        previous_rate, previous_gain = charge_rate, session and charge_gain
    end
    local awake, asleep, total = { loss = 0, time = 0, elapsed = 0 },
        { loss = 0, time = 0, elapsed = 0 }, { loss = 0, time = 0 }
    local bt = { loss = 0, time = 0, elapsed = 0 }
    local wifi = { loss = 0, time = 0, elapsed = 0 }
    local both = { loss = 0, time = 0, elapsed = 0 }
    local full_mah, design_mah, health, current_mah = device_capacity()
    local function accumulate(first, second)
        if type(first) ~= "table" or type(second) ~= "table" or second.gap then return end
        local elapsed = second.time - first.time
        if elapsed <= 0 or first.charging then return end
        local bucket = first.sleeping and asleep
            or first.bluetooth and first.wifi and both
            or first.bluetooth and bt or first.wifi and wifi or awake
        bucket.elapsed = bucket.elapsed + elapsed
        local loss
        if full_mah and full_mah > 0 and not second.charging and nonnegative(first.mah) and nonnegative(second.mah) then
            -- fine measurement from the fuel gauge (mAh), whole percent is too coarse
            local drop = first.mah - second.mah
            -- small rises are gauge noise: count the time with no loss; a large
            -- rise means a charge we did not see, so the stretch is left out
            if drop < -5 then return end
            loss = math.max(0, drop) * 100 / full_mah
        else
            if first.level < second.level then return end
            loss = first.level - second.level
        end
        bucket.loss = bucket.loss + loss
        bucket.time = bucket.time + elapsed
        total.loss = total.loss + loss
        total.time = total.time + elapsed
    end
    for i = 2, #events do accumulate(events[i - 1], events[i]) end
    if current and #events > 0 and events[#events].charging == current.charging then
        accumulate(events[#events], current)
    end
    if include_history ~= false then
        total.loss, total.time = total.loss + (history.discharge_loss or 0), total.time + (history.discharge_time or 0)
        awake.loss, awake.time = awake.loss + (history.awake_loss or 0), awake.time + (history.awake_discharge_time or 0)
        asleep.loss, asleep.time = asleep.loss + (history.asleep_loss or 0), asleep.time + (history.asleep_discharge_time or 0)
        -- history awake_time is the whole screen-on time (Bluetooth included)
        awake.elapsed, asleep.elapsed = awake.elapsed + (history.awake_time or 0), asleep.elapsed + (history.asleep_time or 0)
        bt.loss, bt.time = bt.loss + (history.bt_loss or 0), bt.time + (history.bt_discharge_time or 0)
        wifi.loss, wifi.time = wifi.loss + (history.wifi_loss or 0), wifi.time + (history.wifi_discharge_time or 0)
        both.loss, both.time = both.loss + (history.both_loss or 0), both.time + (history.both_discharge_time or 0)
    end
    local function rate(bucket, minimum_seconds)
        return bucket.time >= (minimum_seconds or 1) and bucket.loss * 3600 / bucket.time or nil
    end
    local overall = rate(total, 3600)
    local unplug = settings:readSetting("last_unplug")
    if current and #events > 0 then
        if not previous.charging and current.level > previous.level then
            unplug = nil
        elseif previous.charging and not current.charging then
            unplug = not current.gap and current.time or nil
        end
    end
    local stats = {
        level = current and current.level,
        full_mah = full_mah or history.full_mah,
        current_mah = current_mah,
        design_mah = design_mah or history.design_mah,
        health = health or history.health,
        charging = current and current.charging,
        charge_rate = previous_rate,
        charge_gain = previous_gain,
        -- ponytail: linear estimate; use charge-level bands if taper accuracy matters.
        time_to_full = current and current.charging and (session.full and 0
            or charge_rate and (100 - current.level) * 3600 / charge_rate) or nil,
        full_charge_time = last_full and last_full.time - last_full.start_time or history.full_charge_time,
        since_full_charge = last_full and current and current.time >= last_full.time
            and current.time - last_full.time or nil,
        overall = overall,
        awake = rate(awake, 3600),
        asleep = rate(asleep),
        bluetooth = rate(bt, 1800),
        wifi = rate(wifi, 1800),
        both = rate(both, 1800),
        awake_time = awake.elapsed + bt.elapsed + wifi.elapsed + both.elapsed,
        asleep_time = asleep.elapsed,
        discharge_loss = total.loss,
        awake_loss = awake.loss,
        asleep_loss = asleep.loss,
        discharge_time = total.time,
        awake_discharge_time = awake.time,
        asleep_discharge_time = asleep.time,
        bt_loss = bt.loss,
        bt_discharge_time = bt.time,
        wifi_loss = wifi.loss,
        wifi_discharge_time = wifi.time,
        both_loss = both.loss,
        both_discharge_time = both.time,
        remaining = overall and overall > 0 and current and current.level * 3600 / overall or nil,
        since_charge = type(unplug) == "number" and current and current.time >= unplug
            and current.time - unplug or nil,
        samples = #events,
    }
    local baseline = settings:readSetting("usage_baseline")
    local reset_usage = current and charge_ended(previous, current)
    local usage = {}
    for key in pairs(HISTORY_TOTALS) do
        local offset = include_history ~= false and type(baseline) == "table"
            and nonnegative(baseline[key]) and baseline[key] or 0
        usage[key] = reset_usage and 0 or math.max(0, stats[key] - offset)
    end
    usage.overall = rate({ loss = usage.discharge_loss, time = usage.discharge_time }, 3600)
    usage.awake = rate({ loss = usage.awake_loss, time = usage.awake_discharge_time }, 3600)
    usage.asleep = rate({ loss = usage.asleep_loss, time = usage.asleep_discharge_time })
    usage.bluetooth = rate({ loss = usage.bt_loss, time = usage.bt_discharge_time }, 1800)
    usage.wifi = rate({ loss = usage.wifi_loss, time = usage.wifi_discharge_time }, 1800)
    usage.both = rate({ loss = usage.both_loss, time = usage.both_discharge_time }, 1800)
    stats.usage = usage
    return stats
end

return M
