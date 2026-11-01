-- Stats tabs: Overview, Books and Calendar.
--
-- The body of the Stats page (navbar "Stats"). A ZenTabBar switches between
-- three pages that are painted by hand from the table built by data.lua. The
-- layout is designed on a 1264 px wide grid and scaled to the body; the page
-- is painted into an offscreen buffer and centred when the body is wider than
-- the grid allows.

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local Accent = require("common/ui/accent")
local ZenTabBar = require("common/ui/zen_tab_bar")
local Data = require("modules/filebrowser/patches/stats_tabs/data")
local datetime = require("datetime")
local T = require("ffi/util").template
local _ = require("gettext")

local Screen = Device.screen

local DESIGN_W = 1264
local BOTTOM = 1512         -- design height of the body
local TAB_Y, TAB_H = 14, 70 -- tab bar
local TOP = 106             -- first section label
local X, W = 24, 1216       -- card left / width
local GAP = 16              -- between cards
local SECTION_H = 44        -- label above a box

local MONTHS = { "January", "February", "March", "April", "May", "June", "July", "August",
    "September", "October", "November", "December" }
local MONTHS_SHORT = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local WDAYS = { "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" }

local function month(m)
    return datetime.longMonthTranslation[MONTHS[m]] or MONTHS[m]
end

local function monthShort(m)
    return datetime.shortMonthTranslation[MONTHS_SHORT[m]] or MONTHS_SHORT[m]
end

--- Short weekday name; i = 1 is Sunday.
local function wday(i)
    return datetime.shortDayOfWeekTranslation[WDAYS[i]] or WDAYS[i]
end

local function int(n) return tostring(math.floor((tonumber(n) or 0) + 0.5)) end

local function dec(x) return string.format("%.1f", x) end

local function hm(sec)
    local m = math.floor((tonumber(sec) or 0) / 60 + 0.5)
    if m >= 60 then return T(_("%1 h %2 min"), math.floor(m / 60), string.format("%02d", m % 60)) end
    return T(_("%1 min"), m)
end

-- luminance 0 (black) .. 255 (white); Blitbuffer.gray() expects blackness 0..1
local function G(lum) return Blitbuffer.gray((255 - lum) / 255) end

local SOFT = G(190)       -- separators between rows
local MID = G(50)         -- secondary text
local FUTURE = G(120)     -- day numbers of future days

-- string.upper() is byte based; this covers the common Latin-1 letters
local function upper(s)
    return (s:upper():gsub("\195([\160-\190])", function(c)
        local b = c:byte()
        if b == 0xB7 then return "\195" .. c end -- division sign
        return "\195" .. string.char(b - 32)
    end))
end

local function spaced(s)
    return (s:gsub("([%z\1-\127\194-\244][\128-\191]*)", "%1 "):gsub(" $", ""))
end

local StatsTabsView = InputContainer:extend{
    name = "zen_stats_tabs",
    width = nil,
    height = nil,
    S = nil,                -- statistics table from data.lua
    page = 1,
    monday_first = true,
}

local last_page = 1

function StatsTabsView:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.height }
    self.k = math.min(self.width / DESIGN_W, self.height / BOTTOM)
    self.pw, self.ph = self:p(DESIGN_W), math.min(self.height, self:p(BOTTOM))
    self.ox = math.floor((self.width - self.pw) / 2)
    self.page = last_page
    self.faces = {}
    self.hits = {}
    self.covers = {}
    if self.S then self.cal_y, self.cal_m = self.S.year, self.S.month end
    self.ges_events = {
        ZenStatsTabsTap = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
        ZenStatsTabsSwipe = { GestureRange:new{ ges = "swipe", range = function() return self.dimen end } },
    }
end

-- design px -> device px
function StatsTabsView:p(n) return math.floor(n * self.k + 0.5) end

function StatsTabsView:face(px)
    local f = self.faces[px]
    if not f then
        local size = math.max(8, math.floor(px * self.k / (Screen:scaleBySize(1000) / 1000) + 0.5))
        f = Font:getFace("cfont", size)
        self.faces[px] = f
    end
    return f
end

--- Draw text in design coordinates. opts: bold, align (left/center/right), fg, h
function StatsTabsView:text(bb, str, px, x, y, w, opts)
    opts = opts or {}
    str = tostring(str or "")
    if str == "" then return 0 end
    local tw = TextWidget:new{
        text = str, face = self:face(px), bold = opts.bold, padding = 0,
        fgcolor = opts.fg or Blitbuffer.COLOR_BLACK, max_width = self:p(w),
    }
    local sz = tw:getSize()
    local tx = self:p(x)
    if opts.align == "center" then tx = tx + math.floor((self:p(w) - sz.w) / 2)
    elseif opts.align == "right" then tx = tx + self:p(w) - sz.w end
    local ty = self:p(y)
    if opts.h then ty = ty + math.floor((self:p(opts.h) - sz.h) / 2) end
    tw:paintTo(bb, tx, ty)
    tw:free()
    return sz.w / self.k
end

function StatsTabsView:measure(str, px, bold)
    local tw = TextWidget:new{ text = tostring(str), face = self:face(px), bold = bold, padding = 0 }
    local w = tw:getSize().w
    tw:free()
    return w / self.k
end

function StatsTabsView:rrect(bb, x, y, w, h, color, radius)
    local pw, ph = math.max(1, self:p(w)), math.max(1, self:p(h))
    local r = math.min(self:p(radius or 6), math.floor(math.min(pw, ph) / 2))
    if not Blitbuffer.isColor8(color) and bb.paintRoundedRectRGB32 then
        bb:paintRoundedRectRGB32(self:p(x), self:p(y), pw, ph, color, r)
    else
        bb:paintRoundedRect(self:p(x), self:p(y), pw, ph, color, r)
    end
end

function StatsTabsView:rect(bb, x, y, w, h, color)
    local paint = Blitbuffer.isColor8(color) and bb.paintRect or bb.paintRectRGB32
    paint(bb, self:p(x), self:p(y), math.max(1, self:p(w)), math.max(1, self:p(h)), color)
end

function StatsTabsView:outline(bb, x, y, w, h, color, thick)
    local px, py, pw, ph = self:p(x), self:p(y), self:p(w), self:p(h)
    local th = math.max(1, self:p(thick or 2))
    bb:paintRect(px, py, pw, th, color)
    bb:paintRect(px, py + ph - th, pw, th, color)
    bb:paintRect(px, py, th, ph, color)
    bb:paintRect(px + pw - th, py, th, ph, color)
end

function StatsTabsView:hit(id, x, y, w, h, data)
    self.hits[#self.hits + 1] = { id = id, x = self:p(x), y = self:p(y), w = self:p(w), h = self:p(h), data = data }
end

--- Rounded box (home "rows" style).
function StatsTabsView:rbox(bb, x, y, w, h, thick, radius, color)
    color = color or Blitbuffer.COLOR_BLACK
    if not Blitbuffer.isColor8(color) then
        -- accent: rounded corners need a Color8 border; draw a plain outline
        self:outline(bb, x, y, w, h, color, thick or 3)
        return
    end
    bb:paintBorder(self:p(x), self:p(y), self:p(w), self:p(h), math.max(1, self:p(thick or 3)),
        color, self:p(radius or 20))
end

--- Short vertical divider inside a box.
function StatsTabsView:vdiv(bb, x, y, h)
    self:rect(bb, x, y, 2, h, SOFT)
end

--- Section: small label above a rounded box. The box starts SECTION_H below y.
function StatsTabsView:card(bb, x, y, w, h, title)
    if title then
        self:text(bb, spaced(upper(title)), 24, x + 12, y, w - 24, { fg = MID, bold = true, h = 36 })
    end
    self:rbox(bb, x, y + SECTION_H, w, h - SECTION_H, 3, 20)
end

-- ---- tabs ------------------------------------------------------------------

function StatsTabsView:tabs(bb)
    local bar = ZenTabBar:new{
        items = { { text = _("Overview") }, { text = _("Books") }, { text = _("Calendar") } },
        selected = self.page,
        width = self:p(DESIGN_W - 64),
        cell_height = self:p(TAB_H),
        font_size = math.max(12, math.floor(28 * self.k / (Screen:scaleBySize(1000) / 1000) + 0.5)),
    }
    bar:paintTo(bb, self:p(32), self:p(TAB_Y))
    for i, cell in ipairs(bar.cells or {}) do
        local d = cell.dimen
        if d then
            self.hits[#self.hits + 1] = { id = "tab", x = d.x, y = d.y - self:p(6), w = d.w,
                h = d.h + self:p(12), data = i }
        end
    end
    bar:free()
end

-- ---- page 1: overview ------------------------------------------------------

function StatsTabsView:page1(bb)
    local S = self.S
    local y = TOP
    local cw = (W - 40) / 3

    -- at a glance
    local h = SECTION_H + 228
    self:card(bb, X, y, W, h, _("At a glance"))
    local by = y + SECTION_H
    local cols = {
        { _("Books read"), int(S.finished_total), _("books, all time") },
        { T(_("Finished in %1"), S.year), int(S.fin_this_year), _("books") },
        { _("Reading time"), int(S.total_sec / 3600), _("hours, all time") },
    }
    for i, c in ipairs(cols) do
        local cx = X + 20 + (i - 1) * cw
        self:text(bb, upper(c[1]), 24, cx, by + 20, cw, { align = "center", fg = MID, bold = true, h = 36 })
        self:text(bb, c[2], 100, cx, by + 52, cw, { align = "center", bold = true, h = 116 })
        self:text(bb, c[3], 28, cx, by + 170, cw, { align = "center", fg = MID, h = 40 })
        if i > 1 then self:vdiv(bb, cx, by + 24, 180) end
    end
    y = y + h + 22

    -- reading speed (minutes per standard page)
    h = SECTION_H + 170
    self:card(bb, X, y, W, h, _("Reading speed") .. " · " .. _("min / page"))
    by = y + SECTION_H
    local sp = {
        { T(_("%1 so far"), month(S.month)), S.cur_speed, true },
        { month(S.prev.m), S.prev.speed },
        { _("Overall"), S.speed_all },
    }
    for i, c in ipairs(sp) do
        local cx = X + 20 + (i - 1) * cw
        self:text(bb, upper(c[1]), 24, cx, by + 18, cw, { align = "center", fg = MID, bold = true, h = 36 })
        local v = c[2] and dec(c[2]) or "–"
        if c[3] then
            local vw = self:measure(v, 72, true) + 48
            self:rbox(bb, cx + (cw - vw) / 2, by + 62, vw, 90, 3, 14)
        end
        self:text(bb, v, 72, cx, by + 62, cw, { align = "center", bold = true, h = 90 })
        if i > 1 then self:vdiv(bb, cx, by + 24, 122) end
    end
    y = y + h + 22

    -- pages & time
    local months_label
    if S.full_months and S.full_months > 0 then
        months_label = "(" .. (S.full_months == 1 and _("1 month") or T(_("%1 months"), S.full_months)) .. ")"
    end
    local rows = {
        { _("Today"), nil, int(S.today_pages), S.today_sec },
        { _("Daily average"), "(" .. month(S.month) .. ")", int(S.daily_pages), S.daily_sec },
        { _("This month so far"), nil, int(S.cur_month.pages), S.cur_month.sec },
        { _("Last month"), "(" .. month(S.prev.m) .. ")", int(S.prev.pages), S.prev.sec },
        { _("Monthly average"), months_label, S.monthly_pages and int(S.monthly_pages) or "–", S.monthly_sec },
    }
    local note_h = 50
    h = BOTTOM - 16 - note_h - y
    self:card(bb, X, y, W, h, _("Pages & time"))
    by = y + SECTION_H
    local c1, c2r, c3r = X + 30, X + 30 + 820, X + W - 30
    local v1, v2 = X + 600, X + 860
    local head_h = 60
    self:text(bb, spaced(upper(_("Period"))), 22, c1, by + 8, 400, { fg = MID, bold = true, h = head_h - 8 })
    self:text(bb, spaced(upper(_("Pages"))), 22, c2r - 240, by + 8, 240,
        { fg = MID, bold = true, align = "right", h = head_h - 8 })
    self:text(bb, spaced(upper(_("Reading time"))), 22, c3r - 320, by + 8, 320,
        { fg = MID, bold = true, align = "right", h = head_h - 8 })
    local row_h = math.floor((h - SECTION_H - head_h - 8) / (#rows + 1))
    local ry = by + head_h
    local min_u = " " .. _("min")
    local function time_cell(sec, ry2, bold_total)
        -- "28 h 14" bold, "min" small and grey
        local m = math.floor((tonumber(sec) or 0) / 60 + 0.5)
        local num = m >= 60 and string.format("%d h %02d", math.floor(m / 60), m % 60) or tostring(m)
        local uw = self:measure(min_u, 24)
        self:text(bb, min_u, 24, c3r - uw, ry2 + 6, uw, { fg = MID, h = row_h })
        self:text(bb, sec and num or "–", bold_total and 42 or 40, c3r - uw - 300, ry2, 300,
            { align = "right", bold = true, h = row_h })
    end
    for i, r in ipairs(rows) do
        if i > 1 then self:rect(bb, X + 30, ry, W - 60, 2, SOFT) end
        local w1 = self:text(bb, r[1], 36, c1, ry, 520, { h = row_h })
        if r[2] then self:text(bb, r[2], 26, c1 + w1 + 10, ry + 4, 300, { fg = MID, h = row_h }) end
        self:text(bb, r[3], 40, c2r - 240, ry, 240, { align = "right", bold = true, h = row_h })
        time_cell(r[4], ry)
        self:vdiv(bb, v1, ry + 18, row_h - 36)
        self:vdiv(bb, v2, ry + 18, row_h - 36)
        ry = ry + row_h
    end
    self:rect(bb, X + 30, ry, W - 60, 3, Blitbuffer.COLOR_BLACK)
    local w1 = self:text(bb, _("Total"), 40, c1, ry, 520, { bold = true, h = row_h })
    if S.first_ym then
        local fy, fm = S.first_ym:match("^(%d+)-(%d+)$")
        if fy then
            self:text(bb, "(" .. T(_("since %1"), monthShort(tonumber(fm)) .. " " .. fy) .. ")", 26,
                c1 + w1 + 10, ry + 4, 300, { fg = MID, h = row_h })
        end
    end
    self:text(bb, int(S.total_pages), 42, c2r - 240, ry, 240, { align = "right", bold = true, h = row_h })
    time_cell(S.total_sec, ry, true)
    self:vdiv(bb, v1, ry + 18, row_h - 36)
    self:vdiv(bb, v2, ry + 18, row_h - 36)
    local chars
    local gs = rawget(_G, "G_reader_settings")
    if gs and gs.readSetting then chars = tonumber(gs:readSetting("pagemap_chars_per_synthetic_page")) end
    local note = chars and T(_("Pages = standard pages (%1 characters)."), int(chars))
        or _("Pages = standard pages.")
    if (S.legacy_count or 0) > 0 then
        note = note .. " " .. T(_("Plus %1 finished books without reading data (≈ %2 pages)."),
            S.legacy_count, int(S.legacy_pages))
    end
    self:text(bb, note, 25, X + 12, y + h + 6, W - 24, { fg = MID, h = 40 })
end

-- ---- page 2: books -----------------------------------------------------------

function StatsTabsView:cover(bb, item, x, y, w, h)
    local entry = self.covers[item.id]
    if entry == nil then
        entry = false
        local ok, Cover = pcall(require, "common/cover_utils")
        if ok and Cover and Cover.makeCover and item.file then
            local ok2, cbb = pcall(Cover.makeCover, item.file, nil, {
                is_folder = false, width = self:p(w), height = self:p(h), need_copy = true,
            })
            if ok2 and cbb and cbb.getWidth then entry = cbb end
        end
        self.covers[item.id] = entry
    end
    if entry then
        bb:blitFrom(entry, self:p(x), self:p(y), 0, 0, math.min(entry:getWidth(), self:p(w)),
            math.min(entry:getHeight(), self:p(h)))
    else
        self:rect(bb, x, y, w, h, G(232))
        self:text(bb, upper(item.title:match("[%z\1-\127\194-\244][\128-\191]*") or "?"), 44, x, y, w,
            { align = "center", h = h, bold = true })
    end
    self:outline(bb, x, y, w, h, Blitbuffer.COLOR_BLACK, 2)
end

function StatsTabsView:bars(bb, x, y, w, h, values, labels, opts)
    opts = opts or {}
    local n = #values
    local mx = 0
    for _i, v in ipairs(values) do if v > mx then mx = v end end
    local ac = Accent.color()
    local slot = w / n
    local bw = math.min(48, slot * 0.5)
    local base = y + h
    for i, v in ipairs(values) do
        local cx = x + (i - 0.5) * slot
        if v > 0 and mx > 0 then
            local bh = math.max(6, (h - 40) * v / mx)
            self:rrect(bb, cx - bw / 2, base - bh, bw, bh + 4, v == mx and ac or Blitbuffer.COLOR_BLACK, 8)
            self:text(bb, tostring(v), 25, cx - slot / 2, base - bh - 36, slot, { align = "center" })
        end
        self:text(bb, labels[i], opts.small and 23 or 26, cx - slot / 2, base + 8, slot,
            { align = "center", fg = MID })
    end
    self:rect(bb, x, base, w, 3, Blitbuffer.COLOR_BLACK)
end

--- Subtitle line. A work of an omnibus gets a small "Book 2 of 3" pill and
--- the omnibus name instead of the author; a finished omnibus "3 books".
function StatsTabsView:subline(bb, b, rest, tx, y, tw)
    local tag, who = nil, b.author
    if b.omni_all then tag = T(_("%1 books"), b.omni_all)
    elseif b.omni_k then tag, who = T(_("Book %1 of %2"), b.omni_k, b.omni_n), b.omni_name end
    if tag then
        local w = self:measure(tag, 21) + 22
        self:rbox(bb, tx, y + 1, w, 32, 2, 16)
        self:text(bb, tag, 21, tx, y + 1, w, { align = "center", h = 32 })
        tx, tw = tx + w + 12, tw - w - 12
    end
    self:text(bb, (who ~= "" and who .. " · " or "") .. rest, 25, tx, y, tw, { fg = MID })
end

local function day_month(ts)
    local d = os.date("*t", ts)
    return T(_("%1 %2"), d.day, monthShort(d.month))
end

function StatsTabsView:page2(bb)
    local S = self.S
    local y = TOP
    local n = math.max(1, #S.reading)
    local row = 124
    local h = SECTION_H + 12 + n * row
    self:card(bb, X, y, W, h, _("Currently reading"))
    local ac = Accent.color()
    if #S.reading == 0 then
        self:text(bb, "–", 34, X, y + SECTION_H + 30, W, { align = "center", fg = MID })
    end
    for i, b in ipairs(S.reading) do
        local by = y + SECTION_H + 6 + (i - 1) * row
        self:cover(bb, b, X + 24, by + 6, 74, 108)
        local tx = X + 122
        local tw = W - 122 - 230
        self:text(bb, b.title, 31, tx, by + 4, tw, { bold = true })
        self:subline(bb, b, T(_("since %1"), day_month(b.first)), tx, by + 46, tw)
        -- progress bar like the home screen: light track, accent fill
        self:rrect(bb, tx, by + 92, tw, 14, G(204), 7)
        if b.pct > 0 then self:rrect(bb, tx, by + 92, math.max(14, tw * b.pct), 14, ac, 7) end
        self:text(bb, math.floor(b.pct * 100 + 0.5) .. " %", 38, X + W - 224, by + 10, 200,
            { align = "right", bold = true })
        self:text(bb, b.cur .. " / " .. b.total .. " " .. _("p."), 24, X + W - 264, by + 66, 240,
            { align = "right", fg = MID })
        if i < #S.reading then self:rect(bb, X + 26, by + row - 2, W - 52, 2, SOFT) end
    end
    y = y + h + GAP

    -- recently finished
    if #S.recent > 0 then
        local frow = 110
        h = SECTION_H + 12 + #S.recent * frow
        self:card(bb, X, y, W, h, _("Recently finished"))
        for i, b in ipairs(S.recent) do
            local by = y + SECTION_H + 6 + (i - 1) * frow
            self:cover(bb, b, X + 24, by + 6, 66, 96)
            local tx = X + 114
            local tw = W - 114 - 230
            self:text(bb, b.title, 31, tx, by + 12, tw, { bold = true })
            self:subline(bb, b, day_month(b.last), tx, by + 56, tw)
            self:text(bb, b.pages .. " " .. _("p."), 36, X + W - 264, by + 12, 240, { align = "right", bold = true })
            self:text(bb, hm(b.dur), 24, X + W - 264, by + 60, 240, { align = "right", fg = MID })
            if i < #S.recent then self:rect(bb, X + 26, by + frow - 2, W - 52, 2, SOFT) end
        end
        y = y + h + GAP
    end

    -- weekday chart (left) + per book (right)
    h = 330
    local wl = math.floor((W - GAP) * 0.58)
    local wr = W - GAP - wl
    local x2 = X + wl + GAP
    self:card(bb, X, y, wl, h, _("Reading time by weekday"))
    local vals, labels = {}, {}
    for i = 1, 7 do
        -- S.weekday is Monday first
        local k = self.monday_first and i or ((i + 5) % 7 + 1)
        vals[i] = math.floor(S.weekday[k] + 0.5)
        labels[i] = wday(k % 7 + 1)
    end
    self:bars(bb, X + 20, y + SECTION_H + 44, wl - 40, h - SECTION_H - 44 - 92, vals, labels)
    self:text(bb, _("Avg. minutes, last 3 months"), 24, X + 10, y + h - 50, wl - 20, { align = "center", fg = MID })
    self:card(bb, x2, y, wr, h, _("Per book"))
    local cy = y + SECTION_H
    self:text(bb, S.fin_avg_days and tostring(S.fin_avg_days) or "–", 64, x2, cy + 8, wr,
        { align = "center", bold = true, h = 76 })
    self:text(bb, _("Reading days per book on average"), 23, x2 + 10, cy + 84, wr - 20,
        { align = "center", fg = MID, h = 32 })
    self:rect(bb, x2 + 30, cy + 126, wr - 60, 2, SOFT)
    self:text(bb, S.fin_avg_sec and hm(S.fin_avg_sec) or "–", 48, x2, cy + 138, wr,
        { align = "center", bold = true, h = 60 })
    self:text(bb, _("Average reading time"), 23, x2 + 10, cy + 200, wr - 20, { align = "center", fg = MID, h = 32 })
    y = y + h + GAP
    local h2 = BOTTOM - 20 - y

    -- books per month
    self:card(bb, X, y, W, h2, _("Books read"))
    if (S.legacy_count or 0) > 0 then
        self:text(bb, T(_("Books without reading data: %1"), S.legacy_count), 25, X + 24, y + SECTION_H + 10,
            W - 48, { h = 34, fg = MID })
    end
    vals, labels = {}, {}
    local ty, tm = S.year, S.month
    local list = {}
    for _i = 1, 12 do
        list[#list + 1] = { ty, tm }
        ty, tm = Data.monthsBack(ty, tm, 1)
    end
    local total_with = 0
    for i = 12, 1, -1 do
        local key = string.format("%04d-%02d", list[i][1], list[i][2])
        local v = S.finished_by_month[key] or 0
        vals[#vals + 1] = v
        labels[#labels + 1] = monthShort(list[i][2])
        total_with = total_with + v
    end
    self:bars(bb, X + 30, y + SECTION_H + 40, W - 60, h2 - SECTION_H - 40 - 96, vals, labels, { small = true })
    self:text(bb, T(_("Last 12 months · %1 books finished"), total_with), 27, X, y + h2 - 44, W,
        { align = "center", fg = MID })
end

-- ---- page 3: calendar --------------------------------------------------------

--- One dot per full hour, a half dot for a started hour.
function StatsTabsView:hourDots(bb, x, y, w, sec)
    local d, gap = 17, 6
    local per_row = math.max(1, math.floor((w + gap) / (d + gap)))
    local mins = math.floor(sec / 60 + 0.5)
    local full, part = math.floor(mins / 60), mins % 60 > 0
    local n = math.min(per_row, full + (part and 1 or 0))
    local r = math.max(2, math.floor(self:p(d) / 2))
    for i = 1, n do
        local cx = self:p(x + (i - 1) * (d + gap)) + r
        local cy = self:p(y) + r
        if i <= full then
            bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_BLACK)
        else
            -- half dot: outline, left half filled
            bb:paintCircle(cx, cy, r, Blitbuffer.COLOR_BLACK, math.max(1, self:p(2)))
            for dy = -r, r do
                local hw = math.floor(math.sqrt(math.max(0, r * r - dy * dy)) + 0.5)
                if hw > 0 then bb:paintRect(cx - hw, cy + dy, hw, 1, Blitbuffer.COLOR_BLACK) end
            end
        end
    end
end

function StatsTabsView:page3(bb)
    local S = self.S
    local y = TOP - 4
    local C = Data.calendar(S, self.cal_y, self.cal_m, self.monday_first)
    local rows = math.ceil((C.lead + C.days) / 7)
    local legend = {}
    for _i, l in ipairs(C.legend) do legend[#legend + 1] = { tostring(l.n), l.title } end
    if C.others then legend[#legend + 1] = { "+", _("Other books") } end
    local lrows = math.max(1, math.ceil(#legend / 2))
    local gx, gw = X + 8, W - 16

    -- month navigation
    local ny = y + 8
    self:rbox(bb, gx, ny, 76, 76, 3, 16)
    self:text(bb, "‹", 46, gx, ny, 76, { align = "center", h = 76 })
    self:hit("prev", gx - 10, ny - 10, 120, 96)
    self:rbox(bb, gx + gw - 76, ny, 76, 76, 3, 16)
    self:text(bb, "›", 46, gx + gw - 76, ny, 76, { align = "center", h = 76 })
    self:hit("next", gx + gw - 110, ny - 10, 120, 96)
    self:text(bb, month(C.m) .. " " .. C.y, 50, X, ny, W, { align = "center", bold = true, h = 76 })

    -- legend: one dot = 1 hour, half dot = started hour
    local sy = ny + 90
    self:hourDots(bb, gx + 4, sy + 9, 40, 3600)
    local lw1 = self:text(bb, _("= 1 hour"), 26, gx + 30, sy, 300, { fg = MID, h = 36 })
    self:hourDots(bb, gx + 30 + lw1 + 26, sy + 9, 40, 1800)
    self:text(bb, _("= started hour"), 26, gx + 30 + lw1 + 52, sy, 400, { fg = MID, h = 36 })

    -- weekdays
    local gap = 8
    local cw = (gw - 6 * gap) / 7
    local dy = sy + 44
    for i = 1, 7 do
        local k = self.monday_first and (i % 7 + 1) or i
        self:text(bb, wday(k), 25, gx + (i - 1) * (cw + gap), dy, cw,
            { align = "center", fg = MID, bold = true, h = 34 })
    end
    local top = dy + 42

    -- bottom block: book legend, totals box, note; cells take the rest
    local totals_h = 128
    local bottom_h = 16 + lrows * 46 + 14 + totals_h + 8 + 40
    local avail = (BOTTOM - 16) - top - bottom_h
    local cell_h = math.min(190, math.floor(avail / rows) - gap)

    local ac = Accent.color()
    local mk, mgap = 34, 6
    local min_u = _("min")
    for d = 1, C.days do
        local c = C.cells[d]
        local idx = C.lead + d - 1
        local cx = gx + (idx % 7) * (cw + gap)
        local cy = top + math.floor(idx / 7) * (cell_h + gap)
        if c.future then
            self:rbox(bb, cx, cy, cw, cell_h, 2, 12, G(221))
            self:text(bb, tostring(d), 32, cx + 10, cy + 4, cw, { fg = FUTURE, bold = true })
        else
            if c.today then
                self:rbox(bb, cx, cy, cw, cell_h, 5, 12, ac)
            else
                self:rbox(bb, cx, cy, cw, cell_h, 2, 12, G(153))
            end
            local dw = self:text(bb, tostring(d), 32, cx + 10, cy + 4, 60,
                { bold = true, fg = c.sec >= 60 and Blitbuffer.COLOR_BLACK or FUTURE })
            if c.sec >= 60 then
                self:text(bb, math.floor(c.sec / 60 + 0.5) .. " " .. min_u, 26, cx + 10 + dw + 4, cy + 6,
                    cw - dw - 20, { align = "right", h = 40 })
                self:hourDots(bb, cx + 12, cy + 56, cw - 24, c.sec)
            end
            -- number boxes, up to two rows
            local per_row = math.max(1, math.floor((cw - 16 + mgap) / (mk + mgap)))
            local n = #c.marks
            local rows_m = math.min(2, math.ceil(n / per_row))
            local by0 = cy + cell_h - 10 - rows_m * mk - (rows_m - 1) * mgap
            local max_marks = per_row * 2
            for i, v in ipairs(c.marks) do
                local r = math.floor((i - 1) / per_row)
                if r >= 2 then break end
                if n > max_marks and i == max_marks then v = Data.OTHERS end
                local mx = cx + 10 + ((i - 1) % per_row) * (mk + mgap)
                local my = by0 + r * (mk + mgap)
                self:rbox(bb, mx, my, mk, mk, 2, 7)
                self:text(bb, v == Data.OTHERS and "+" or tostring(v), 22, mx, my, mk,
                    { align = "center", bold = true, h = mk })
            end
        end
    end
    local gy = top + rows * (cell_h + gap)

    -- book legend (two columns)
    local ly = gy + 12
    for i, l in ipairs(legend) do
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        local lx = gx + 10 + col * (gw / 2)
        local yy = ly + row * 46
        self:rbox(bb, lx, yy, 36, 36, 2, 8)
        self:text(bb, l[1], 22, lx, yy, 36, { align = "center", bold = true, h = 36 })
        self:text(bb, l[2], 25, lx + 50, yy, gw / 2 - 70, { h = 36 })
    end

    -- totals box
    local fy = ly + lrows * 46 + 14
    self:rbox(bb, X, fy, W, totals_h, 3, 20)
    local fw = W / 3
    local figs = {
        { _("Reading days"), tostring(C.days_read), " / " .. C.days_total },
        { _("Reading time"), nil, nil, C.sec },
        { _("Sessions"), tostring(C.sessions) },
    }
    for i, f in ipairs(figs) do
        local fx = X + (i - 1) * fw
        self:text(bb, upper(f[1]), 24, fx, fy + 12, fw, { align = "center", fg = MID, bold = true, h = 36 })
        local big, small
        if f[4] then
            local m = math.floor(f[4] / 60 + 0.5)
            big = m >= 60 and string.format("%d h %02d", math.floor(m / 60), m % 60) or tostring(m)
            small = " " .. min_u
        else
            big, small = f[2], f[3]
        end
        local bw = self:measure(big, 52, true)
        local sw = small and self:measure(small, 26) or 0
        local sx = fx + (fw - bw - sw) / 2
        self:text(bb, big, 52, sx, fy + 50, bw + 4, { bold = true, h = 66 })
        if small then self:text(bb, small, 26, sx + bw, fy + 64, sw + 4, { fg = MID, h = 50 }) end
        if i > 1 then self:vdiv(bb, fx, fy + 20, totals_h - 40) end
    end
    self:text(bb, _("Numbers = books read that day (at least 10 min.)"), 25, X, fy + totals_h + 8, W,
        { align = "center", fg = MID, h = 36 })
end

-- ---- painting / events -------------------------------------------------------

function StatsTabsView:getSize()
    return self.dimen
end

function StatsTabsView:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    self.hits = {}
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    -- paint in grid coordinates (0, 0) into a buffer of the page's own size
    local buf = Blitbuffer.new(self.pw, self.ph, bb:getType())
    buf:fill(Blitbuffer.COLOR_WHITE)
    local ok, err = pcall(function()
        self:tabs(buf)
        if not self.S then
            self:text(buf, self.error_text or _("No reading statistics yet."), 32, X, TOP + 40, W,
                { align = "center", fg = MID })
        elseif self.page == 1 then self:page1(buf)
        elseif self.page == 2 then self:page2(buf)
        else self:page3(buf) end
    end)
    if not ok then
        require("common/zen_logger").new("stats_tabs").warn("paint failed:", err)
    end
    bb:blitFrom(buf, x + self.ox, y, 0, 0, self.pw, self.ph)
    buf:free()
end

function StatsTabsView:refresh()
    UIManager:setDirty(self.show_parent or self, function() return "ui", self.dimen end)
end

function StatsTabsView:setPage(n)
    n = math.max(1, math.min(3, n))
    if n == self.page then return true end
    self.page = n
    last_page = n
    self:refresh()
    return true
end

function StatsTabsView:shiftMonth(delta)
    local S = self.S
    local y, m = Data.monthsBack(self.cal_y, self.cal_m, -delta)
    local key = string.format("%04d-%02d", y, m)
    if key > string.format("%04d-%02d", S.year, S.month) then return end
    if S.first_ym and key < S.first_ym then return end
    self.cal_y, self.cal_m = y, m
    self:refresh()
end

function StatsTabsView:onZenStatsTabsTap(_arg, ges)
    local px = ges.pos.x - self.dimen.x - self.ox
    local py = ges.pos.y - self.dimen.y
    for _i, h in ipairs(self.hits) do
        if px >= h.x and px < h.x + h.w and py >= h.y and py < h.y + h.h then
            if h.id == "tab" then return self:setPage(h.data)
            elseif h.id == "prev" then self:shiftMonth(-1) return true
            elseif h.id == "next" then self:shiftMonth(1) return true end
        end
    end
    return false
end

function StatsTabsView:onZenStatsTabsSwipe(_arg, ges)
    if ges.direction == "west" then return self:setPage(self.page + 1) end
    if ges.direction == "east" then return self:setPage(self.page - 1) end
    return false
end

function StatsTabsView:free()
    for _id, c in pairs(self.covers) do
        if c and c.free then pcall(c.free, c) end
    end
    self.covers = {}
end

function StatsTabsView:onCloseWidget()
    self:free()
end

return StatsTabsView
