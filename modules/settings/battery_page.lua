-- Battery page (Battery button in quick settings and the dispatcher action).
--
--   * charge level, battery bar, estimated time left / time to full
--   * level curve: 1 day, 7 days, 30 days or since the last charge, with a
--     scale that follows the data (at least 30 %, 10 % for 1 day);
--     thick = awake, thin = asleep, grey band = charging, outlined bar = Bluetooth,
--     hatched bar = Wi-Fi
--   * 2 x 4 tiles; hold a tile to choose what it shows (use per hour awake,
--     with Bluetooth, Wi-Fi or both, asleep, screen times, capacity, ...)
--   * ⋮ menu: the battery details (Health, Usage, Charging, Reset log) from
--     battery_stats_menu, the unit for use per hour (% or mAh) and the tiles
--   * last charge and what a full charge lasts
--   * built from ZenOS components: ZenTabBar for the range, ZenButton for
--     the menus, TitleStyle for the header; curve and bar use the accent color
--
-- Data: common/battery_stats.lua (snapshot + curve). Nothing is computed twice.

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local IconWidget     = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local Accent         = require("common/ui/accent")
local TitleStyle     = require("common/ui/zen_title_style")
local ZenTabBar      = require("common/ui/zen_tab_bar")
local utils          = require("common/utils")
local lfs            = require("libs/libkoreader-lfs")
local PresetStore    = require("config/preset_store")
local _              = require("gettext")
local T              = require("ffi/util").template

local Screen = Device.screen
local function s(n) return Screen:scaleBySize(n) end

local DAY = 86400
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local GREY = Blitbuffer.COLOR_GRAY_5
local GRID = Blitbuffer.Color8(0xDD)
local BAND = Blitbuffer.Color8(0xCC)

local icons_dir = require("common/plugin_root") .. "/icons/"

local function stock_icon(name)
    return utils.resolveLocalIcon(lfs.currentdir() .. "/resources/icons/mdlight/", name)
end

local function face(size) return Font:getFace("cfont", size) end

--- Filled rectangle in any color (the accent color can be RGB).
local function fill(bb, x, y, w, h, color)
    if w <= 0 or h <= 0 then return end
    if Blitbuffer.isColor8(color) then bb:paintRect(x, y, w, h, color)
    else bb:paintRectRGB32(x, y, w, h, color) end
end

--- Outline of a rectangle in any color.
local function outline(bb, x, y, w, h, t, color)
    fill(bb, x, y, w, t, color)
    fill(bb, x, y + h - t, w, t, color)
    fill(bb, x, y, t, h, color)
    fill(bb, x + w - t, y, t, h, color)
end

--- Text at (x, y) in a box of (w, h); returns the width used.
local function text(bb, str, fc, x, y, w, h, opts)
    opts = opts or {}
    local tw = TextWidget:new{ text = str, face = fc, bold = opts.bold, fgcolor = opts.fg or BLACK,
        max_width = math.max(1, w), padding = 0 }
    local sz = tw:getSize()
    local tx = x
    if opts.align == "right" then tx = x + w - sz.w
    elseif opts.align == "center" then tx = x + math.floor((w - sz.w) / 2) end
    tw:paintTo(bb, tx, y + math.floor((h - sz.h) / 2))
    tw:free()
    return sz.w, sz.h
end

local function measure(str, fc, bold)
    local tw = TextWidget:new{ text = str, face = fc, bold = bold, padding = 0 }
    local sz = tw:getSize()
    tw:free()
    return sz.w, sz.h
end

local function duration(seconds)
    if not seconds or seconds < 0 then return "–" end
    local m = math.floor(seconds / 60 + 0.5)
    local d, h = math.floor(m / 1440), math.floor(m % 1440 / 60)
    m = m % 60
    if d > 0 then return T(_("%1 d %2 h"), d, h) end
    if h > 0 then return T(_("%1 h %2 min"), h, m) end
    return T(_("%1 min"), m)
end

-- page options: tiles and unit, kept in battery_page.lua in the ZenOS settings folder
local DEFAULT_TILES = { "awake", "bt", "wifi", "asleep", "screen_on", "screen_off", "per_hour", "health" }
local function options_file()
    return require("luasettings"):open(PresetStore.rootDir() .. "/battery_page.lua")
end
local function load_options()
    local ok, f = pcall(options_file)
    local o = ok and f and f.data or {}
    if type(o.tiles) ~= "table" or #o.tiles ~= 8 then
        o.tiles = {}
        for i, id in ipairs(DEFAULT_TILES) do o.tiles[i] = id end
    end
    o.unit = o.unit == "mah" and "mah" or "pct"
    return o
end
local options = load_options()
local function save_options()
    local ok, f = pcall(options_file)
    if not ok or not f then return end
    f.data = { tiles = options.tiles, unit = options.unit }
    f:flush()
end
local full_mah   -- set from the snapshot; mAh needs the full capacity

--- Use per hour: "0.82 %/h", or the mAh lost per hour ("15 mAh").
local function rate(v)
    if not v then return "–" end
    if options.unit == "mah" and full_mah and full_mah > 0 then
        local m = v * full_mah / 100
        return string.format(m < 1 and "%.2f mAh" or m < 10 and "%.1f mAh" or "%.0f mAh", m)
    end
    return string.format(v < 0.1 and "%.3f %%/h" or v < 10 and "%.2f %%/h" or "%.1f %%/h", v)
end

--- Long times in hours ("118 h"), short ones as "2 h 15 min".
local function hours(seconds)
    if not seconds or seconds < 0 then return "–" end
    if seconds >= 10 * 3600 then return T(_("%1 h"), math.floor(seconds / 3600 + 0.5)) end
    return duration(seconds)
end

--- Whole days for long times ("32 d"), otherwise as duration().
local function days(seconds)
    if seconds >= 2 * DAY then return T(_("%1 d"), math.floor(seconds / DAY + 0.5)) end
    return duration(seconds)
end

--- "today", "yesterday", "3 days ago" by calendar day.
local function day_ago(t, now)
    local function midday(x)
        local d = os.date("*t", x)
        return os.time{ year = d.year, month = d.month, day = d.day, hour = 12 }
    end
    local n = math.floor((midday(now) - midday(t)) / DAY + 0.5)
    if n <= 0 then return _("today") end
    if n == 1 then return _("yesterday") end
    return T(_("%1 days ago"), n)
end

local RANGES = {
    { id = "1", label = _("1 day") },
    { id = "7", label = _("7 days") },
    { id = "30", label = _("30 days") },
    { id = "charge", label = _("Since charge") },
}

local BatteryPage = InputContainer:extend{
    covers_fullscreen = true,
    plugin = nil,
    range = "charge",
}

function BatteryPage:init()
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self.range = BatteryPage._last_range or "charge"
    self:_load()
    self:registerTouchZones({
        { id = "zen_battery_tap", ges = "tap",
          screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
          handler = function(ges) return self:_onTap(ges) end },
        { id = "zen_battery_swipe", ges = "swipe",
          screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
          handler = function(ges) return self:_onSwipe(ges) end },
        { id = "zen_battery_hold", ges = "hold",
          screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
          handler = function(ges) return self:_onHold(ges) end },
        { id = "zen_battery_multiswipe", ges = "multiswipe",
          screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
          handler = function() UIManager:setDirty(self, "full") return true end },
    })
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
end

function BatteryPage:_load()
    local BS = require("common/battery_stats")
    self.stats = BS.snapshot()
    full_mah = self.stats and self.stats.full_mah or nil
    local curve = {}
    for _i, p in ipairs(BS.curve()) do
        if type(p) == "table" and tonumber(p[1]) and tonumber(p[2]) then
            curve[#curve + 1] = { tonumber(p[1]), tonumber(p[2]), tonumber(p[3]) or 0 }
        end
    end
    self.curve = curve
    self.now = os.time()
end

-- ---------------------------------------------------------------------------
-- Painting
-- ---------------------------------------------------------------------------

function BatteryPage:_paintTitle(bb)
    local isz = TitleStyle.ICON_SIZE
    local iy = TitleStyle.VERTICAL_PADDING + math.floor((TitleStyle.ROW_HEIGHT - isz) / 2)
    local back = IconWidget:new{ file = stock_icon("chevron.left"), width = isz, height = isz }
    back:paintTo(bb, TitleStyle.getLeadingIconX(0), iy)
    back:free()
    local close = IconWidget:new{ file = stock_icon("close"), width = isz, height = isz }
    local cx = TitleStyle.getTrailingIconX(self.dimen.w, 0)
    close:paintTo(bb, cx, iy)
    close:free()
    local mx = cx - isz - s(24)
    local more = IconWidget:new{ file = utils.resolveLocalIcon(icons_dir, "more_vertical"), width = isz, height = isz }
    more:paintTo(bb, mx, iy)
    more:free()
    self._hit_more = Geom:new{ x = mx - s(12), y = 0, w = isz + s(24), h = TitleStyle.HEADER_HEIGHT }
    local tf = TitleStyle.getTitleFace()
    local th = select(2, measure(_("Battery"), tf, true))
    text(bb, _("Battery"), tf, TitleStyle.getTitleX(0), TitleStyle.VERTICAL_PADDING
        + math.floor((TitleStyle.ROW_HEIGHT - th) / 2), self.dimen.w, th, { bold = true })
    bb:paintRect(0, TitleStyle.HEADER_CONTENT_HEIGHT, self.dimen.w, TitleStyle.DIVIDER_HEIGHT,
        TitleStyle.DIVIDER_COLOR)
    self._hit_back = Geom:new{ x = 0, y = 0, w = TitleStyle.getTitleX(0) + s(140), h = TitleStyle.HEADER_HEIGHT }
    self._hit_close = Geom:new{ x = cx - s(8), y = 0, w = self.dimen.w - cx + s(8), h = TitleStyle.HEADER_HEIGHT }
end

function BatteryPage:_paintHero(bb, x, y, w)
    local st = self.stats or {}
    local level = st.level
    local big = face(56)
    local num = level and tostring(level) or "–"
    local nw, nh = measure(num, big, true)
    text(bb, num, big, x, y, nw, nh, { bold = true })
    local pw = text(bb, "%", face(26), x + nw + s(2), y + math.floor(nh * 0.22), s(40), math.floor(nh * 0.7),
        { bold = true })
    local bx = x + nw + pw + s(24)
    local bw = w - (bx - x) - s(8)
    local bh = s(26)
    local by = y + s(8)
    bb:paintBorder(bx, by, bw, bh, s(2), BLACK, s(7))
    bb:paintRoundedRect(bx + bw + s(1), by + math.floor(bh / 3), s(5), math.ceil(bh / 3), BLACK, s(2))
    if level then
        local fw = math.floor((bw - 2 * s(4)) * level / 100)
        if fw > 0 then fill(bb, bx + s(4), by + s(4), fw, bh - 2 * s(4), Accent.color()) end
    end
    local sub
    if st.charging then
        sub = st.time_to_full and st.time_to_full > 0 and T(_("Charging · full in %1"), duration(st.time_to_full))
            or _("Charging")
    elseif st.remaining then
        sub = T(_("About %1 left"), duration(st.remaining))
    else
        sub = _("Estimate after about an hour of use")
    end
    local sy = by + bh + s(10)
    text(bb, sub, face(18), bx, sy, bw, s(36), { fg = GREY })
    return math.max(nh, sy + s(36) - y) + s(4)
end

function BatteryPage:_window()
    local now = self.now
    if self.range == "1" then return now - DAY, now end
    if self.range == "7" then return now - 7 * DAY, now end
    if self.range == "30" then return now - 30 * DAY, now end
    local st = self.stats or {}
    if st.since_charge and st.since_charge > 0 then return now - st.since_charge, now end
    -- charging now or unknown: from the end of the last charge in the curve
    for i = #self.curve, 2, -1 do
        local a, b = self.curve[i - 1], self.curve[i]
        if (a[3] % 2) == 1 and (b[3] % 2) == 0 then return a[1], now end
    end
    return now - 7 * DAY, now
end

--- Polyline by pixel columns (Blitbuffer has no line drawing).
local function seg(bb, x0, y0, x1, y1, thick, color)
    if x1 < x0 then x0, y0, x1, y1 = x1, y1, x0, y0 end
    local n = math.max(1, x1 - x0)
    local py = y0
    for i = 0, n do
        local xx = x0 + i
        local yy = math.floor(y0 + (y1 - y0) * i / n + 0.5)
        local top = math.min(py, yy)
        fill(bb, xx, top - math.floor(thick / 2), 1, math.abs(yy - py) + thick, color)
        py = yy
    end
end

local function flag(p, bit) return math.floor(p[3] / bit) % 2 == 1 end

--- Scale of the level axis: min − 5 … max + 5 (0 … 100), at least `span`;
--- when the data spans less, the top stays and the bottom goes down.
local function scale(pts, span)
    local lo, hi = 100, 0
    for _i, p in ipairs(pts) do
        lo, hi = math.min(lo, p[2]), math.max(hi, p[2])
    end
    if hi < lo then return 100 - span, 100 end
    lo, hi = math.max(0, lo - 5), math.min(100, hi + 5)
    if hi - lo < span then
        lo = hi - span
        if lo < 0 then lo, hi = 0, span end
    end
    return lo, hi
end

--- Ticks on the time axis: { seconds before now, label }.
local function time_ticks(span)
    local ticks = {}
    if span <= 36 * 3600 then
        local h = span / 3600
        local step = h <= 6 and 1 or h <= 12 and 3 or 6
        local k = 0
        while k * 3600 <= span + 1 do
            ticks[#ticks + 1] = { k * 3600, k == 0 and _("now") or T(_("−%1 h"), k) }
            k = k + step
        end
    else
        local d = span / DAY
        local step = d <= 5 and 1 or d <= 10 and 2 or d <= 20 and 4 or 7
        local k = 0
        while k * DAY <= span + 1 do
            ticks[#ticks + 1] = { k * DAY, k == 0 and _("now") or T(_("−%1 d"), k) }
            k = k + step
        end
    end
    return ticks
end

function BatteryPage:_paintChart(bb, x, y, w, h)
    local pad = s(14)
    local head_h = s(40) + s(34) + s(8)
    local legend_h = s(34)
    bb:paintBorder(x, y, w, h, s(2), BLACK, s(14))
    -- range switch (right): ZenTabBar
    local items, selected = {}, 1
    for i, r in ipairs(RANGES) do
        items[i] = { text = r.label }
        if r.id == self.range then selected = i end
    end
    local seg_h = s(34)
    local sx, sy = x + pad, y + pad + seg_h + s(8)
    local bar = ZenTabBar:new{ items = items, selected = selected, font_size = 15,
        width = w - 2 * pad, cell_height = seg_h }
    bar:paintTo(bb, sx, sy)
    self._hit_ranges = {}
    for i, cell in ipairs(bar.cells or {}) do
        local d = cell.dimen
        if d then
            self._hit_ranges[#self._hit_ranges + 1] = { id = RANGES[i].id, x = d.x, y = d.y - s(8),
                w = d.w, h = d.h + s(16) }
        end
    end
    bar:free()

    -- points in the window (plus the one before, to start at the left edge)
    local t0, t1 = self:_window()
    local pts = {}
    for i, p in ipairs(self.curve) do
        if p[1] >= t0 then
            if #pts == 0 and i > 1 then pts[1] = self.curve[i - 1] end
            pts[#pts + 1] = p
        end
    end

    -- title (left): range · first → last level
    local label = ""
    for _i, r in ipairs(RANGES) do if r.id == self.range then label = r.label end end
    local title = label
    if #pts >= 2 then
        title = T(_("%1 · %2 → %3 %"), label, pts[1][2], pts[#pts][2])
    end
    text(bb, title, face(16), x + pad, y + pad, w - 2 * pad, seg_h, { bold = true })

    -- plot area
    local lf = face(13)
    local lw = measure("100%", lf)
    local px, py = x + pad + lw + s(10), y + pad + head_h + s(12)
    local pw = x + w - pad - px
    local ph = h - (py - y) - s(26) - legend_h - s(14)
    local lo, hi = scale(pts, self.range == "1" and 10 or 30)
    local function X(t) return px + math.floor(pw * (t - t0) / math.max(1, t1 - t0) + 0.5) end
    local function Y(l)
        l = math.max(lo, math.min(hi, l))
        return py + math.floor(ph * (hi - l) / math.max(1, hi - lo) + 0.5)
    end
    for _i, v in ipairs({ lo, math.floor((lo + hi) / 2 + 0.5), hi }) do
        bb:paintRect(px, Y(v), pw, 1, GRID)
        text(bb, v .. "%", lf, x + pad, Y(v) - s(10), lw, s(20), { align = "right", fg = GREY })
    end
    -- time labels
    for _i, tk in ipairs(time_ticks(t1 - t0)) do
        local xx = X(t1 - tk[1])
        local lw2 = measure(tk[2], lf)
        local lx = math.max(px, math.min(px + pw - lw2, xx - math.floor(lw2 / 2)))
        text(bb, tk[2], lf, lx, py + ph + s(4), lw2 + 1, s(20), { fg = GREY })
    end
    if #pts < 2 then
        text(bb, _("Collecting data… The chart fills after a few hours of use."), face(16),
            px, py, pw, ph, { align = "center", fg = GREY })
    else
        local acc = Accent.color()
        local thick, thin = s(4), math.max(2, s(1.5))
        local bt_h = s(7)
        local wifi_y = py + ph - bt_h - s(3)
        local bt_y = wifi_y - bt_h - s(4)
        -- Bluetooth (outlined) and Wi-Fi (hatched): one bar per continuous period
        local function hatch(x0, y0, w0, h0)
            local step = s(5)
            for xx = x0, x0 + w0 - 1, step do fill(bb, xx, y0, math.min(s(2), x0 + w0 - xx), h0, acc) end
        end
        local runs = { [8] = {}, [16] = {} }
        local function flush(bit)
            local run = runs[bit]
            if run[1] then
                local bw = math.max(s(7), run[2] - run[1])
                local yy = bit == 8 and bt_y or wifi_y
                bb:paintRect(run[1], yy, bw, bt_h, WHITE)
                if bit == 16 then hatch(run[1], yy, bw, bt_h) end
                outline(bb, run[1], yy, bw, bt_h, math.max(1, s(1)), acc)
            end
            run[1], run[2] = nil, nil
        end
        for i = 2, #pts do
            local a, b = pts[i - 1], pts[i]
            local ax, bx2 = math.max(px, X(a[1])), X(b[1])
            if not flag(b, 4) and bx2 >= px then
                if flag(a, 1) then
                    bb:paintRect(ax, py, math.max(s(3), bx2 - ax), ph, BAND)
                    seg(bb, ax, Y(a[2]), bx2, Y(b[2]), thin, acc)
                elseif flag(a, 2) then
                    seg(bb, ax, Y(a[2]), bx2, Y(b[2]), thin, acc)
                else
                    seg(bb, ax, Y(a[2]), bx2, Y(b[2]), thick, acc)
                end
                for bit, run in pairs(runs) do
                    if flag(a, bit) and not flag(a, 2) then
                        if run[2] and ax > run[2] + 1 then flush(bit) end
                        run[1], run[2] = run[1] or ax, bx2
                    else
                        flush(bit)
                    end
                end
            else
                flush(8)
                flush(16)
            end
        end
        flush(8)
        flush(16)
        local last = pts[#pts]
        local r = s(10)
        local dx, dy = X(last[1]), Y(last[2])
        for k = 0, r - 1 do
            local o = k - (r - 1) / 2
            local half = math.floor(math.sqrt(math.max(0, (r / 2) ^ 2 - o * o)) + 0.5)
            fill(bb, dx - half, dy - math.floor(r / 2) + k, 2 * half, 1, acc)
        end
    end
    -- legend
    local ly = y + h - legend_h - s(10)
    local lx = x + pad
    local function key(kind, name)
        local kw = s(28)
        local cy = ly + math.floor(legend_h / 2)
        if kind == "band" then
            kw = s(22)
            bb:paintRect(lx, cy - s(7), kw, s(14), BAND)
        elseif kind == "bt" or kind == "wifi" then
            if kind == "wifi" then
                for xx = lx, lx + kw - 1, s(5) do fill(bb, xx, cy - s(4), s(2), s(8), Accent.color()) end
            end
            outline(bb, lx, cy - s(4), kw, s(8), math.max(1, s(1)), Accent.color())
        else
            local t = kind == "awake" and s(4) or math.max(2, s(1.5))
            fill(bb, lx, cy - math.floor(t / 2), kw, t, Accent.color())
        end
        local tw = text(bb, name, lf, lx + kw + s(6), ly, s(200), legend_h, { fg = GREY })
        lx = lx + kw + s(6) + tw + s(22)
    end
    key("awake", _("awake"))
    key("asleep", _("asleep"))
    key("band", _("charging"))
    key("bt", _("Bluetooth"))
    key("wifi", _("Wi-Fi"))
    return h
end

BatteryPage.TILE_ROW_H = 62

-- Values a tile can show, in the order of the picker: use per hour, times,
-- battery, and an empty place.
local TILE_ORDER = {
    "awake", "bt", "wifi", "both", "asleep", "per_hour",
    "screen_on", "screen_off", "since_charge", "full_charge",
    "health", "full_mah", "design_mah", "empty",
}

local function tile_label(id)
    return ({
        awake = _("Awake"), bt = _("Bluetooth"), wifi = _("Wi-Fi"), both = _("Wi-Fi + Bluetooth"),
        asleep = _("Asleep"), per_hour = _("Per hour"), screen_on = _("Screen on"),
        screen_off = _("Screen off"), since_charge = _("Since charge"), full_charge = _("Full charge lasts"),
        health = _("Health"), full_mah = _("Full capacity"), design_mah = _("Design capacity"),
        empty = _("Empty"),
    })[id] or id
end

--- Tile labels are short; the picker uses the long name for "both".
local function tile_short(id)
    if id == "both" then return _("Wi-Fi + BT") end
    return tile_label(id)
end

function BatteryPage:_tileValue(id)
    local st = self.stats or {}
    if id == "awake" then return rate(st.awake)
    elseif id == "bt" then return rate(st.bluetooth)
    elseif id == "wifi" then return rate(st.wifi)
    elseif id == "both" then return rate(st.both)
    elseif id == "asleep" then return rate(st.asleep)
    elseif id == "per_hour" then return rate(st.overall)
    elseif id == "screen_on" then return hours(st.awake_time)
    elseif id == "screen_off" then return hours(st.asleep_time)
    elseif id == "since_charge" then return st.charging and _("Charging") or duration(st.since_charge)
    elseif id == "full_charge" then
        return st.overall and st.overall > 0 and days(100 * 3600 / st.overall) or "–"
    elseif id == "health" then return st.health and string.format("%.0f %%", st.health) or "–"
    elseif id == "full_mah" then return st.full_mah and string.format("%.0f mAh", st.full_mah) or "–"
    elseif id == "design_mah" then return st.design_mah and string.format("%.0f mAh", st.design_mah) or "–"
    end
    return ""
end

function BatteryPage:_paintTiles(bb, x, y, w)
    local rh = s(BatteryPage.TILE_ROW_H)
    local vpad = s(8)
    local h = 2 * rh + 2 * vpad
    bb:paintBorder(x, y, w, h, s(2), BLACK, s(14))
    local cw = math.floor(w / 4)
    self._hit_tiles = {}
    for r = 1, 2 do
        local ry = y + vpad + (r - 1) * rh
        if r > 1 then bb:paintRect(x + s(16), ry, w - 2 * s(16), 1, BAND) end
        for i = 1, 4 do
            local idx = (r - 1) * 4 + i
            local id = options.tiles[idx]
            local cx = x + (i - 1) * cw
            if i > 1 then bb:paintRect(cx, ry + s(8), 1, rh - s(16), BAND) end
            if self.customize then
                -- customize mode: every tile shows a frame, a tap changes it
                outline(bb, cx + s(6), ry + s(4), cw - s(12), rh - s(8), math.max(1, s(1)), GREY)
            end
            if id ~= "empty" then
                text(bb, tile_short(id), face(14), cx, ry + s(5), cw, s(22), { align = "center", fg = GREY })
                text(bb, self:_tileValue(id), face(20), cx, ry + s(27), cw, s(30), { align = "center", bold = true })
            elseif self.customize then
                text(bb, "+", face(20), cx, ry, cw, rh, { align = "center", fg = GREY })
            end
            self._hit_tiles[idx] = Geom:new{ x = cx, y = ry, w = cw, h = rh }
        end
    end
    return h
end

--- Picker for one tile: the current value is ticked.
function BatteryPage:_pickTile(idx)
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local buttons = {}
    for _i, id in ipairs(TILE_ORDER) do
        local value = id ~= "empty" and self:_tileValue(id) or nil
        local label = tile_label(id) .. (value and value ~= "" and ("  ·  " .. value) or "")
            .. (options.tiles[idx] == id and "  \u{2713}" or "")
        buttons[#buttons + 1] = { {
            text = label,
            align = "left",
            callback = function()
                UIManager:close(dialog)
                options.tiles[idx] = id
                save_options()
                self:_refresh()
            end,
        } }
    end
    dialog = ButtonDialog:new{
        title = T(_("Tile %1 of %2"), idx, 8),
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(dialog)
end

--- ⋮ menu: battery details from battery_stats_menu, then the page options.
function BatteryPage:_showMenu()
    local items = require("modules/settings/battery_stats_menu").buildItems()
    if items[#items] then items[#items].separator = true end
    items[#items + 1] = {
        text = _("Use per hour in"),
        mandatory_func = function() return options.unit == "mah" and "mAh" or "%" end,
        sub_item_table = {
            {
                text = "%",
                radio = true,
                checked_func = function() return options.unit ~= "mah" end,
                callback = function() options.unit = "pct"; save_options() end,
            },
            {
                text = "mAh",
                radio = true,
                enabled_func = function() return full_mah ~= nil and full_mah > 0 end,
                checked_func = function() return options.unit == "mah" end,
                callback = function() options.unit = "mah"; save_options() end,
            },
        },
    }
    items[#items + 1] = {
        text = _("Customize tiles"),
        checked_func = function() return self.customize == true end,
        callback = function(touchmenu)
            self.customize = not self.customize
            if touchmenu and touchmenu.closeMenu then touchmenu:closeMenu() end
        end,
    }
    items[#items + 1] = {
        text = _("Restore default tiles"),
        callback = function(touchmenu)
            for i, id in ipairs(DEFAULT_TILES) do options.tiles[i] = id end
            save_options()
            if touchmenu and touchmenu.closeMenu then touchmenu:closeMenu() end
        end,
    }
    local menu = require("modules/settings/zen_settings_page").show(self.plugin, {
        title = _("Battery"),
        root_items = items,
    })
    -- back on the page: reload (a reset may have run) and repaint
    if menu then
        local orig = menu.onCloseWidget
        menu.onCloseWidget = function(m, ...)
            UIManager:nextTick(function()
                self:_load()
                self:_refresh()
            end)
            if orig then return orig(m, ...) end
        end
    end
end

function BatteryPage:_sentences()
    local st = self.stats or {}
    local out = {}
    local gain, crate = st.charge_gain, st.charge_rate
    local how = gain and gain > 0 and (crate and crate > 0
        and T(_("+%1 % in %2"), gain, duration(gain * 3600 / crate)) or T(_("+%1 %"), gain)) or nil
    if st.charging then
        out[#out + 1] = _("Charging now.")
    elseif st.since_charge and how then
        out[#out + 1] = T(_("Last charged %1, %2."), day_ago(self.now - st.since_charge, self.now), how)
    elseif st.since_charge then
        out[#out + 1] = T(_("Last charged %1."), day_ago(self.now - st.since_charge, self.now))
    elseif how then
        out[#out + 1] = T(_("Last charge: %1."), how)
    end
    if st.overall and st.overall > 0 then
        local per = rate(st.overall)
        if options.unit == "mah" and full_mah and full_mah > 0 then per = T(_("%1 per hour"), per) end
        out[#out + 1] = T(_("A full charge lasts %1 at %2 on average."), days(100 * 3600 / st.overall), per)
    end
    return out
end

function BatteryPage:paintTo(bb, x, y)
    local W, H = self.dimen.w, self.dimen.h
    bb:paintRect(x, y, W, H, WHITE)
    self:_paintTitle(bb)
    local pad = s(22)
    local cx, cw = x + pad, W - 2 * pad
    local cy = y + TitleStyle.HEADER_HEIGHT + s(22)
    self._hit_ranges, self._hit_tiles = nil, nil
    if not self.stats then
        text(bb, _("No battery data on this device."), face(18), cx, cy, cw, s(60), { align = "center", fg = GREY })
        return
    end
    cy = cy + self:_paintHero(bb, cx, cy, cw) + s(18)
    local lines = self:_sentences()
    local line_h = s(32)
    local tiles_h = 2 * s(BatteryPage.TILE_ROW_H) + 2 * s(8)
    local bottom = y + H - s(24) - #lines * line_h - s(14) - tiles_h - s(16)
    local chart_h = math.max(s(260), bottom - cy)
    self:_paintChart(bb, cx, cy, cw, chart_h)
    cy = cy + chart_h + s(16)
    cy = cy + self:_paintTiles(bb, cx, cy, cw) + s(14)
    for _i, line in ipairs(lines) do
        text(bb, line, face(18), cx + s(4), cy, cw - s(8), line_h)
        cy = cy + line_h
    end
end

-- ---------------------------------------------------------------------------
-- Gestures
-- ---------------------------------------------------------------------------

local function inside(r, p)
    return r and p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h
end

function BatteryPage:_refresh()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function BatteryPage:_onTap(ges)
    local p = ges.pos
    if inside(self._hit_close, p) then return self:onClose(true) end
    if inside(self._hit_back, p) then return self:onClose() end
    for _i, r in ipairs(self._hit_ranges or {}) do
        if inside(r, p) then
            if self.range ~= r.id then
                self.range = r.id
                BatteryPage._last_range = r.id
                self:_refresh()
            end
            return true
        end
    end
    if inside(self._hit_more, p) then
        self:_showMenu()
        return true
    end
    if self.customize then
        for idx, r in pairs(self._hit_tiles or {}) do
            if inside(r, p) then
                self:_pickTile(idx)
                return true
            end
        end
    end
    return true
end

--- Hold a tile to choose what it shows.
function BatteryPage:_onHold(ges)
    for idx, r in pairs(self._hit_tiles or {}) do
        if inside(r, ges.pos) then
            self:_pickTile(idx)
            return true
        end
    end
    return true
end

function BatteryPage:_onSwipe(ges)
    -- KOReader's refresh gesture (short diagonal swipe): full screen refresh
    local dir = ges.direction
    if dir == "northeast" or dir == "northwest" or dir == "southeast" or dir == "southwest" then
        UIManager:setDirty(self, "full")
        return true
    end
    -- left / right: switch the chart range
    local i = 1
    for k, r in ipairs(RANGES) do if r.id == self.range then i = k end end
    if ges.direction == "west" then i = math.min(#RANGES, i + 1)
    elseif ges.direction == "east" then i = math.max(1, i - 1)
    elseif ges.direction == "south" then
        -- swipe down from the top: the pull-down menu, as on the other pages
        local ok, TopSwipe = pcall(require, "modules/global/patches/menu_top_swipe")
        if ok and TopSwipe and type(TopSwipe.handleSwipe) == "function" then
            pcall(TopSwipe.handleSwipe, ges)
        end
        return true
    else return true end
    local id = RANGES[i].id
    if id ~= self.range then
        self.range = id
        BatteryPage._last_range = id
        self:_refresh()
    end
    return true
end

function BatteryPage:onClose(all)
    UIManager:close(self, "ui", self.dimen)
    if all and self.close_all_callback then pcall(self.close_all_callback) end
    return true
end

function BatteryPage:onShow()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

local M = {}

function M.show(plugin, opts)
    opts = opts or {}
    local page = BatteryPage:new{ plugin = plugin, close_all_callback = opts.close_all_callback }
    UIManager:show(page)
    return page
end

M.BatteryPage = BatteryPage
return M
