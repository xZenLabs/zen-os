-- ZenOS Stats Page
-- Fullscreen reading stats dashboard with long-press block customization.

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local PluginLoader = require("pluginloader")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Background = require("common/ui/background")
local StandalonePage = require("modules/filebrowser/patches/standalone_page")
local SharedState = require("common/shared_state")
local StatsDB = require("common/db_stats")
local LibraryDB = require("common/db_library")
local BookInfoDB = require("common/db_bookinfo")
local WidgetResources = require("common/widget_resources")
local LineGraph = require("common/ui/zen_line_graph")
local StatsSettings = require("modules/filebrowser/patches/stats_settings")
local PresetStore = require("config/preset_store")
local HomeGoals = require("modules/filebrowser/patches/home/widgets/reading_goals")
local ZenModalClose = require("common/ui/zen_modal_close")
local icons = require("common/inline_icon_map")
local utils = require("common/utils")
local datetime = require("datetime")
local Screen = Device.screen
local _ = require("gettext")

local StatsPage = {}
local active_stats_menus = {}

local _icons_dir
do
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then
        local root = src:sub(2):match("^(.*)/modules/")
        if root then _icons_dir = root .. "/icons/" end
    end
end

local flame_icon_path = utils.resolveLocalIcon(_icons_dir, "flame")

local function blockTitle(block)
    local titles = {
        today            = _("Today"),
        this_week        = _("This Week"),
        this_month       = _("This Month"),
        this_year        = _("This Year"),
        all_time         = _("All Time"),
        personal_records = _("Personal Records"),
        library          = _("Library"),
        current_book     = _("Current Book"),
        trend_graph      = _("Reading Trend"),
        goal_progress    = _("Reading goals"),
        calendar         = _("Reading Calendar"),
    }
    return titles[block.id] or tostring(block.id)
end

local function metricLabel(metric)
    return metric == "time" and _("Minutes") or _("Pages")
end

local function normalizeStatStyle(style)
    if style == "outline" then return style end
    if style == "none" then return style end
    return "divider"
end

local function statsFrameBg()
    return Background.tile_bg(Blitbuffer.COLOR_WHITE)
end

local function clearStatsBackgrounds(widget)
    if Background.library_active() then
        Background.clearWhiteBackgrounds(widget, 40)
    end
end

local function displayBlockTitle(block)
    local title = blockTitle(block)
    if block.id == "trend_graph" then
        title = title .. " " .. metricLabel(block.metric) .. ", "
            .. tostring(block.range_days or 14) .. _(" days")
    elseif block.id == "calendar" then
        title = ""
    end
    return title
end

local function isCalendarMonth(month)
    local year, month_num = tostring(month or ""):match("^(%d%d%d%d)%-(%d%d)$")
    month_num = tonumber(month_num)
    return year ~= nil and month_num ~= nil and month_num >= 1 and month_num <= 12
end

local function saveCalendarMonthConfig(settings, month)
    month = tostring(month or "")
    if not isCalendarMonth(month) then return end
    settings.calendar_month = month
    StatsSettings.save(settings)
end

local function loadCalendarMonthConfig(settings)
    local month = tostring(settings.calendar_month or "")
    if isCalendarMonth(month) then return month end
end

local function time_unit(unit)
    if type(_) == "table" and type(_.pgettext) == "function" then
        return _.pgettext("Time", unit)
    end
    return _(unit)
end

local function formatTime(secs)
    secs = math.floor(secs or 0)
    if secs <= 0 then return "0" .. time_unit("m") end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 then
        return h .. time_unit("h") .. " " .. m .. time_unit("m")
    end
    return m .. time_unit("m")
end

local function formatLongTime(secs)
    secs = math.floor(secs or 0)
    if secs <= 0 then return "0" .. time_unit("m") end
    local d = math.floor(secs / 86400)
    local h = math.floor((secs % 86400) / 3600)
    local m = math.floor((secs % 3600) / 60)
    if d > 0 then
        return h > 0 and (d .. time_unit("d") .. " " .. h .. time_unit("h"))
            or (d .. time_unit("d"))
    elseif h > 0 then
        return h .. time_unit("h") .. " " .. m .. time_unit("m")
    end
    return m .. time_unit("m")
end

local function minuteCount(secs)
    return tostring(math.floor((tonumber(secs) or 0) / 60 + 0.5))
end

local function fmtPeakDay(ts)
    if not ts then return "" end
    local month = datetime.shortMonthTranslation[os.date("%b", ts)] or os.date("%b", ts)
    return month .. " " .. tostring(os.date("*t", ts).day)
end

local function fmtPeakWeek(ts)
    if not ts then return "" end
    local start_ts = StatsDB.weekStart(os.date("*t", ts))
    local end_date = os.date("*t", start_ts)
    end_date.day = end_date.day + 6
    end_date.isdst = nil
    local end_ts = os.time(end_date)
    local start_month = datetime.shortMonthTranslation[os.date("%b", start_ts)] or os.date("%b", start_ts)
    local end_month = datetime.shortMonthTranslation[os.date("%b", end_ts)] or os.date("%b", end_ts)
    local start_str = start_month .. " " .. tostring(os.date("*t", start_ts).day)
    if os.date("%m", start_ts) == os.date("%m", end_ts) then
        return start_str .. "-" .. tostring(os.date("*t", end_ts).day)
    end
    return start_str .. "-" .. end_month .. " " .. tostring(os.date("*t", end_ts).day)
end

local function fmtPeakMonth(ts)
    if not ts then return "" end
    local month = datetime.shortMonthTranslation[os.date("%b", ts)] or os.date("%b", ts)
    return month .. " " .. os.date("%Y", ts)
end

local function shortDate(date)
    local m, d = tostring(date or ""):match("^%d+%-(%d+)%-(%d+)$")
    if not m or not d then return "" end
    return tostring(tonumber(m)) .. "/" .. tostring(tonumber(d))
end

local function monthShift(month_s, delta)
    local year, month = tostring(month_s or ""):match("^(%d%d%d%d)%-(%d%d)$")
    year = tonumber(year)
    month = tonumber(month)
    if not year or not month then return os.date("%Y-%m", os.time()) end
    return os.date("%Y-%m", os.time{
        year = year,
        month = month + (delta or 0),
        day = 15,
        hour = 12,
        min = 0,
        sec = 0,
    })
end

local function monthLabel(month_s)
    local year, month = tostring(month_s or ""):match("^(%d%d%d%d)%-(%d%d)$")
    year = tonumber(year)
    month = tonumber(month)
    if not year or not month then return tostring(month_s or "") end
    local ts = os.time{
        year = year,
        month = month,
        day = 15,
        hour = 12,
        min = 0,
        sec = 0,
    }
    local month_name = datetime.longMonthTranslation[os.date("%B", ts)] or os.date("%B", ts)
    return month_name .. " " .. tostring(year)
end

local function graphDateLabels(series, max_labels)
    local labels = {}
    local count = type(series) == "table" and #series or 0
    if count == 0 then return labels end
    local wanted = math.min(max_labels or 5, count)
    if wanted <= 1 then
        labels[#labels + 1] = { text = shortDate(series[count].date), ratio = 0.5 }
        return labels
    end
    local used = {}
    for i = 1, wanted do
        local idx = math.floor((i - 1) * (count - 1) / (wanted - 1) + 1.5)
        if not used[idx] then
            used[idx] = true
            labels[#labels + 1] = {
                text = shortDate(series[idx].date),
                ratio = count > 1 and ((idx - 1) / (count - 1)) or 0.5,
            }
        end
    end
    return labels
end

local function queryStats()
    local stats = StatsDB.queryStats()
    local book_counts = LibraryDB.getBookCounts()
    stats.books_finished = book_counts.finished
    stats.books_reading = book_counts.reading
    stats.total_books = BookInfoDB.getTotalBookCount()
    return stats
end

local function queryCurrentBookStats()
    local out = {
        title = _("Current Book"),
        total_time = 0,
        pages_read = 0,
        avg_time_per_page = 0,
        session_time = 0,
        session_pages = 0,
        total_pages = 0,
    }
    local stats_plugin = PluginLoader:getPluginInstance("statistics")
    if type(stats_plugin) ~= "table" or not stats_plugin.id_curr_book then
        return out
    end
    if type(stats_plugin.insertDB) == "function" then
        pcall(stats_plugin.insertDB, stats_plugin)
    end
    if type(stats_plugin.data) == "table" and type(stats_plugin.data.title) == "string" then
        out.title = stats_plugin.data.title
    end
    if type(stats_plugin.getPageTimeTotalStats) == "function" then
        local ok, pages, duration = pcall(stats_plugin.getPageTimeTotalStats, stats_plugin, stats_plugin.id_curr_book)
        if ok then
            out.pages_read = tonumber(pages) or 0
            out.total_time = tonumber(duration) or 0
        end
    end
    if type(stats_plugin.getCurrentBookStats) == "function" then
        local ok, duration, pages = pcall(stats_plugin.getCurrentBookStats, stats_plugin)
        if ok then
            out.session_time = tonumber(duration) or 0
            out.session_pages = tonumber(pages) or 0
        end
    end
    if type(stats_plugin.document) == "table" and type(stats_plugin.document.getPageCount) == "function" then
        local ok, pages = pcall(stats_plugin.document.getPageCount, stats_plugin.document)
        if ok then out.total_pages = tonumber(pages) or 0 end
    end
    if out.pages_read > 0 and out.total_time > 0 then
        out.avg_time_per_page = math.floor(out.total_time / out.pages_read + 0.5)
    end
    return out
end

local function queryDashboardData(blocks)
    local data = {
        stats = queryStats(),
        current_book = nil,
        series = {},
    }
    for _i, block in ipairs(blocks) do
        if block.id == "trend_graph" then
            local range = tonumber(block.range_days) or 14
            if not data.series[range] then
                data.series[range] = StatsDB.queryDailySeries(range)
            end
        elseif block.id == "current_book" then
            data.current_book = queryCurrentBookStats()
        end
    end
    return data
end

local function createCard(opts)
    local card_w = opts.width
    local card_h = opts.height
    local stat_style = normalizeStatStyle(opts.stat_style)
    local value_font = Font:getFace("infofont", opts.value_size or 28)
    local label_font = Font:getFace("smallinfofont", opts.label_size or 16)
    local hdr_font = Font:getFace("smallinfofont", opts.header_size or 16)
    local padding = Screen:scaleBySize(stat_style == "outline" and 7 or 3)
    local border = stat_style == "outline" and Screen:scaleBySize(1) or 0
    local inner_w = math.max(1, card_w - (padding + border) * 2)
    local content_items = { align = "center" }

    if (opts.header or "") ~= "" then
        content_items[#content_items + 1] = TextWidget:new{
            text = opts.header,
            face = hdr_font,
            fgcolor = Blitbuffer.COLOR_BLACK,
            max_width = inner_w,
        }
        content_items[#content_items + 1] = VerticalSpan:new{ width = Screen:scaleBySize(2) }
    end
    content_items[#content_items + 1] = opts.value_widget or TextWidget:new{
        text = opts.value or "",
        face = value_font,
        max_width = inner_w,
    }
    content_items[#content_items + 1] = VerticalSpan:new{ width = Screen:scaleBySize(3) }
    content_items[#content_items + 1] = TextWidget:new{
        text = opts.label or "",
        face = label_font,
        fgcolor = Blitbuffer.COLOR_BLACK,
        max_width = inner_w,
    }

    local content = VerticalGroup:new(content_items)
    local chrome_h = (padding + border) * 2
    local actual_h = math.max(card_h, content:getSize().h + chrome_h)
    return FrameContainer:new{
        width = card_w,
        height = actual_h,
        padding = padding,
        bordersize = border,
        radius = stat_style == "outline" and Screen:scaleBySize(6) or 0,
        color = Blitbuffer.COLOR_BLACK,
        background = statsFrameBg(),
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = actual_h - chrome_h },
            content,
        },
    }
end

local function createCardRow(page_w, cards, stat_style, gap_w)
    stat_style = normalizeStatStyle(stat_style)
    gap_w = gap_w or Screen:scaleBySize(stat_style == "divider" and 8 or 6)
    local row_h = 0
    for _i, card in ipairs(cards) do
        local h = card:getSize().h
        if h > row_h then row_h = h end
    end
    local row = HorizontalGroup:new{ align = "center" }
    for i, card in ipairs(cards) do
        row[#row + 1] = card
        if i < #cards then
            if stat_style == "divider" then
                row[#row + 1] = CenterContainer:new{
                    dimen = Geom:new{ w = gap_w, h = row_h },
                    LineWidget:new{
                        dimen = Geom:new{
                            w = Screen:scaleBySize(1),
                            h = math.max(1, row_h - Screen:scaleBySize(12)),
                        },
                        background = Blitbuffer.COLOR_BLACK,
                    },
                }
            else
                row[#row + 1] = HorizontalSpan:new{ width = gap_w }
            end
        end
    end
    return CenterContainer:new{
        dimen = Geom:new{ w = page_w, h = row_h },
        row,
    }
end

local function createDayBookCard(width, title_text, minutes, pages, stat_style)
    width = math.max(Screen:scaleBySize(120), tonumber(width) or 0)
    local padding = Screen:scaleBySize(8)
    local inner_w = math.max(1, width - padding * 2)
    stat_style = normalizeStatStyle(stat_style)
    local title = TextWidget:new{
        text = tostring(title_text or ""),
        face = Font:getFace("smallinfofontbold", Screen:scaleBySize(10)),
        max_width = inner_w,
    }
    local gap = Screen:scaleBySize(stat_style == "divider" and 8 or stat_style == "outline" and 9 or 6)
    local pill_w = math.max(Screen:scaleBySize(48), math.floor((inner_w - gap) / 2))
    local card_h = Screen:scaleBySize(74)
    local stats = HorizontalGroup:new{
        align = "center",
        createCardRow(inner_w, {
            createCard{
                width = pill_w, height = card_h, stat_style = stat_style,
                value = minuteCount(minutes), label = _("minutes"),
            },
            createCard{
                width = pill_w, height = card_h, stat_style = stat_style,
                value = tostring(pages or 0), label = _("pages"),
            },
        }, stat_style, gap),
    }
    local content = VerticalGroup:new{
        align = "center",
        LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = title:getSize().h },
            title,
        },
        VerticalSpan:new{ width = Screen:scaleBySize(5) },
        stats,
    }
    local height = content:getSize().h + padding * 2
    return FrameContainer:new{
        width = width,
        height = height,
        padding = padding,
        bordersize = 0,
        radius = 0,
        color = Blitbuffer.COLOR_BLACK,
        background = statsFrameBg(),
        content,
    }
end

local function makeBlockPanel(page_w, content_w, title, body, height)
    local padding = Screen:scaleBySize(8)
    local title_h = title ~= "" and Screen:scaleBySize(15) or 0
    local title_gap = title ~= "" and Screen:scaleBySize(5) or 0
    local body_h = body:getSize().h
    local min_h = title_h + title_gap + body_h + padding * 2
    local panel_h = height or (title_h + title_gap + body_h + padding * 2)
    local inner_w = content_w - padding * 2
    local panel_items = {}
    if title_h > 0 then
        panel_items[#panel_items + 1] = LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = title_h },
            TextWidget:new{
                text = title,
                face = Font:getFace("smallinfofontbold", Screen:scaleBySize(10)),
                max_width = inner_w,
            },
        }
        panel_items[#panel_items + 1] = VerticalSpan:new{ width = title_gap }
    end
    panel_items[#panel_items + 1] = body
    local panel = FrameContainer:new{
        width = content_w,
        height = panel_h,
        padding = padding,
        bordersize = 0,
        radius = 0,
        color = Blitbuffer.COLOR_BLACK,
        background = statsFrameBg(),
        VerticalGroup:new(panel_items),
    }
    return CenterContainer:new{
        dimen = Geom:new{ w = page_w, h = panel_h },
        panel,
    }, min_h
end

local function createFallbackCalendarWidget(width, height)
    local text = TextWidget:new{
        text = _("Statistics calendar is unavailable"),
        face = Font:getFace("smallinfofont", Screen:scaleBySize(14)),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        max_width = width - Screen:scaleBySize(16),
    }
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
        text,
    }
end

local function loadNativeCalendarView()
    local ok, CalendarView = pcall(require, "calendarview")
    if ok and CalendarView then return CalendarView end

    local old_path = package.path
    package.path = "plugins/statistics.koplugin/?.lua;" .. old_path
    ok, CalendarView = pcall(require, "calendarview")
    package.path = old_path
    if ok and CalendarView then return CalendarView end
end

local function calendarDayShift(stats_plugin)
    local settings = stats_plugin and stats_plugin.settings or {}
    if not settings.calendar_use_day_time_shift then return 0 end
    return (tonumber(settings.calendar_day_start_hour) or 0) * 3600
        + (tonumber(settings.calendar_day_start_minute) or 0) * 60
end

local function showCalendarDaySummary(stats_plugin, visible_day_ts, stat_style)
    stat_style = normalizeStatStyle(stat_style)
    local shift = calendarDayShift(stats_plugin)
    local period_begin = visible_day_ts + shift
    local books = StatsDB.queryBooksForPeriod(period_begin, period_begin + 86400)
    local total_duration = 0
    local total_pages = 0
    for _i, book in ipairs(books) do
        total_duration = total_duration + (book.duration or 0)
        total_pages = total_pages + (book.pages or 0)
    end

    local dialog
    local dialog_w = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9)
    dialog = ButtonDialog:new{
        width = dialog_w,
        buttons = {},
    }
    local width = math.max(Screen:scaleBySize(160), dialog_w - Screen:scaleBySize(28))
    local scroll_w = math.max(
        Screen:scaleBySize(120),
        width - ScrollableContainer:getScrollbarWidth() - Screen:scaleBySize(4)
    )
    local title_text = datetime.secondsToDate(visible_day_ts, true)
    local title_bar = TitleBar:new{
        width = width,
        align = "left",
        title = title_text,
        title_face = Font:getFace("smallinfofontbold", Screen:scaleBySize(10)),
        show_parent = dialog,
    }
    local close_button = ZenModalClose.installTitleBar(
        title_bar, dialog, function() UIManager:close(dialog) end
    )
    dialog:addWidget(title_bar)
    dialog:addWidget(VerticalSpan:new{ width = Screen:scaleBySize(6) })
    local items = { align = "center" }
    items[#items + 1] = createDayBookCard(scroll_w, _("Total"), total_duration, total_pages, stat_style)
    if #books == 0 then
        items[#items + 1] = VerticalSpan:new{ width = Screen:scaleBySize(8) }
        items[#items + 1] = TextWidget:new{
            text = _("No reading data"),
            face = Font:getFace("smallinfofont", Screen:scaleBySize(14)),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
            max_width = scroll_w,
        }
    else
        for _i, book in ipairs(books) do
            items[#items + 1] = VerticalSpan:new{ width = Screen:scaleBySize(8) }
            items[#items + 1] = createDayBookCard(scroll_w, book.title, book.duration, book.pages, stat_style)
        end
    end

    local content = VerticalGroup:new(items)
    local content_h = math.min(content:getSize().h, math.floor(Screen:getHeight() * 0.58))
    local scroll_widget = ScrollableContainer:new{
        dimen = Geom:new{ w = width, h = content_h },
        show_parent = dialog,
        content,
    }
    dialog:addWidget(scroll_widget)
    dialog.cropping_widget = scroll_widget
    if dialog.movable then dialog.movable.ges_events = {} end
    dialog.ges_events.ZenDayPopupTouch = {
        GestureRange:new{ ges = "touch", range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } },
    }
    dialog.ges_events.ZenDayPopupSwipe = {
        GestureRange:new{ ges = "swipe", range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } },
    }
    dialog.ges_events.ZenDayPopupPan = {
        GestureRange:new{ ges = "pan", range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } },
    }
    dialog.ges_events.ZenDayPopupPanRelease = {
        GestureRange:new{ ges = "pan_release", range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } },
    }
    dialog.ges_events.ZenDayPopupHold = {
        GestureRange:new{ ges = "hold", range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } },
    }
    dialog.ges_events.ZenDayPopupHoldPan = {
        GestureRange:new{ ges = "hold_pan", range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } },
    }
    dialog.ges_events.ZenDayPopupHoldRelease = {
        GestureRange:new{ ges = "hold_release", range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } },
    }
    function dialog:onZenDayPopupTouch(_arg, ges)
        return scroll_widget:onScrollableTouch(nil, ges)
    end
    function dialog:onZenDayPopupSwipe(_arg, ges)
        return scroll_widget:onScrollableSwipe(nil, ges)
    end
    function dialog:onZenDayPopupPan(_arg, ges)
        return scroll_widget:onScrollablePan(nil, ges)
    end
    function dialog:onZenDayPopupPanRelease(_arg, ges)
        return scroll_widget:onScrollablePanRelease(nil, ges)
    end
    function dialog:onZenDayPopupHold(_arg, ges)
        return scroll_widget:onScrollableHold(nil, ges)
    end
    function dialog:onZenDayPopupHoldPan(_arg, ges)
        return scroll_widget:onScrollableHoldPan(nil, ges)
    end
    function dialog:onZenDayPopupHoldRelease(_arg, ges)
        return scroll_widget:onScrollableHoldRelease(nil, ges)
    end
    ZenModalClose.addToFocusLayout(dialog, close_button)
    UIManager:show(dialog)
end

local function installCalendarDaySummary(calendar, stats_plugin, stat_style)
    if not (calendar and type(calendar.layout) == "table") then return end
    local year, month = tostring(calendar.cur_month or ""):match("^(%d%d%d%d)%-(%d%d)$")
    year = tonumber(year)
    month = tonumber(month)
    if not year or not month then return end
    local today_s = os.date("%Y-%m-%d", os.time())
    for _i, row in ipairs(calendar.layout) do
        for _j, day_widget in ipairs(row) do
            if day_widget and not day_widget.filler and day_widget.daynum then
                local day_ts = os.time({
                    year = year,
                    month = month,
                    day = day_widget.daynum,
                    hour = 0, min = 0, sec = 0,
                })
                local day_s = os.date("%Y-%m-%d", day_ts)
                local day_frame = day_widget[1]
                if day_s == today_s and day_frame and not day_frame._zen_today_outline then
                    day_frame._zen_today_outline = true
                    local orig_paint_to = day_frame.paintTo
                    day_frame.paintTo = function(self_frame, bb, x, y)
                        orig_paint_to(self_frame, bb, x, y)
                        local inset = math.max(1, calendar.day_border or 1)
                        local width = self_frame.width or self_frame.dimen.w
                        local height = self_frame.height or self_frame.dimen.h
                        if width > inset * 2 and height > inset * 2 then
                            bb:paintBorder(x + inset, y + inset, width - inset * 2, height - inset * 2,
                                inset, Blitbuffer.COLOR_BLACK)
                        end
                    end
                end
                if day_widget.nb_not_shown_w then
                    day_widget.nb_not_shown_w.fgcolor = Blitbuffer.COLOR_BLACK
                end
                if day_s <= today_s then
                    day_widget.callback = function()
                        showCalendarDaySummary(stats_plugin, day_ts, stat_style)
                    end
                    local orig_on_tap = day_widget.onTap
                    day_widget.onTap = function(self_day, arg, ges)
                        if not (ges and ges.pos and self_day.dimen
                                and self_day.dimen:contains(ges.pos)) then
                            return false
                        end
                        return orig_on_tap(self_day, arg, ges)
                    end
                    day_widget.onHold = function()
                        return false
                    end
                else
                    day_widget.callback = nil
                    day_widget.onHold = function()
                        return false
                    end
                end
            end
        end
    end
end

local function embeddedCalendarWeekCount(month, start_day_of_week)
    local year, month_num = tostring(month or ""):match("^(%d%d%d%d)%-(%d%d)$")
    year = tonumber(year)
    month_num = tonumber(month_num)
    if not year or not month_num then return 6 end
    local first_day = os.date("*t", os.time({ year = year, month = month_num, day = 1, hour = 12 }))
    local last_day = os.date("*t", os.time({ year = year, month = month_num + 1, day = 0, hour = 12 }))
    local start_day = tonumber(start_day_of_week) or 2
    if start_day < 1 or start_day > 7 then start_day = 2 end
    local leading_days = (first_day.wday - start_day + 7) % 7
    return math.ceil((leading_days + last_day.day) / 7)
end

local function refreshEmbeddedCalendarLayout(calendar)
    local layout = calendar and calendar[1] and calendar[1][1] and calendar[1][1][1]
    if layout and layout.resetLayout then layout:resetLayout() end
end

local function tuneEmbeddedCalendar(calendar, populate)
    if not calendar or not calendar.dimen then return end

    if calendar.title_bar then
        calendar.title_bar.close_callback = nil
        calendar.title_bar.right_icon = nil
        calendar.title_bar.has_right_icon = false
        calendar.title_bar.right_button = nil
        calendar.title_bar.title_face = Font:getFace("smallinfofontbold", Screen:scaleBySize(10))
        calendar.title_bar.title_top_padding = 0
        calendar.title_bar.bottom_v_padding = 0
        calendar.title_bar:clear()
        calendar.title_bar:init()
    end

    if calendar.page_info then
        calendar.page_info:clear()
        calendar.page_info:resetLayout()
        calendar.page_info.dimen = Geom:new{ w = 0, h = 0 }
        calendar.page_info.getSize = function(self) return self.dimen end
    end
    if calendar.page_info_text then
        calendar.page_info_text.hold_input = nil
        calendar.page_info_text.call_hold_input_on_tap = false
    end

    if calendar.title_bar and calendar.day_names then
        local available_height = calendar.dimen.h - calendar.title_bar:getHeight()
            - calendar.day_names:getSize().h
        local week_count = embeddedCalendarWeekCount(calendar.cur_month, calendar.start_day_of_week)
        calendar.week_height = math.floor((available_height - week_count * calendar.inner_padding) / week_count)
        calendar.week_height = math.max(1, calendar.week_height)
        calendar.day_border = calendar.day_border or Screen:scaleBySize(1)
        if calendar.show_hourly_histogram then
            calendar.span_height = math.ceil((calendar.week_height - 2 * calendar.day_border)
                / (calendar.nb_book_spans + 2))
        else
            calendar.span_height = math.floor((calendar.week_height - 2 * calendar.day_border)
                / (calendar.nb_book_spans + 1))
        end
        local text_height = math.min(calendar.span_height, calendar.week_height / 3)
        calendar.span_font_size = TextBoxWidget:getFontSizeToFitHeight(text_height, 1, 0.55)
        local day_inner_width = calendar.day_width - 2 * calendar.day_border - 2 * calendar.inner_padding
        while true do
            local test_w = TextWidget:new{
                text = " 30 + 99 ",
                face = Font:getFace(calendar.font_face, calendar.span_font_size),
                bold = true,
            }
            local fits = test_w:getWidth() <= day_inner_width
            test_w:free()
            if fits then break end
            calendar.span_font_size = calendar.span_font_size - 1
        end
        if populate ~= false then
            calendar:_populateItems()
            refreshEmbeddedCalendarLayout(calendar)
        end
    end
end

local function embeddedCalendarBookSpans(stats_plugin, month)
    if type(stats_plugin.getReadBookByDay) ~= "function" then return 1 end
    if not isCalendarMonth(month) then month = os.date("%Y-%m", os.time()) end
    local ok, books_by_day = pcall(stats_plugin.getReadBookByDay, stats_plugin, month)
    if not ok or type(books_by_day) ~= "table" then return 1 end
    for _day, books in pairs(books_by_day) do
        if type(books) == "table" and #books >= 2 then return 2 end
    end
    return 1
end

local function hideCalendarPageInfo(calendar)
    if not (calendar and calendar.page_info) then return end
    calendar.page_info:clear()
    calendar.page_info:resetLayout()
    calendar.page_info.dimen = Geom:new{ w = 0, h = 0 }
    calendar.page_info.getSize = function(self) return self.dimen end
end

local STATS_TRIPLET_SIZE = { preferred_pct = 0.08, min_pct = 0.06, max_pct = 0.10, grow_priority = 4 }
local GOALS_SIZE = { preferred_pct = 0.12, min_pct = 0.08, max_pct = 0.18, grow_priority = 4 }
local TREND_GRAPH_SIZE = { preferred_pct = 0.26, min_pct = 0.20, max_pct = 0.36, grow_priority = 2 }
local FEATURED_SIZE = { preferred_pct = 0.60, min_pct = 0.40, max_pct = 0.74, grow_priority = 1 }

local function blockSize(block)
    if block.id == "trend_graph" then return TREND_GRAPH_SIZE end
    if block.id == "calendar" then return FEATURED_SIZE end
    if block.id == "goal_progress" then return GOALS_SIZE end
    return STATS_TRIPLET_SIZE
end

local function computeBlockHeights(blocks, height, required_heights)
    local specs, total_min = {}, 0
    required_heights = required_heights or {}
    for i, block in ipairs(blocks) do
        local size = blockSize(block)
        local min_h = math.max(1, math.floor(height * size.min_pct + 0.5))
        min_h = math.max(min_h, required_heights[i] or 0)
        local max_h = math.max(min_h, math.floor(height * size.max_pct + 0.5))
        local pref_h = math.max(min_h, math.min(max_h, math.floor(height * size.preferred_pct + 0.5)))
        specs[#specs + 1] = { min = min_h, max = max_h, h = pref_h, priority = size.grow_priority }
        total_min = total_min + min_h
    end
    if total_min > height then
        for _i, spec in ipairs(specs) do
            spec.h = spec.min
        end
        return specs
    end

    local total = 0
    for _i, spec in ipairs(specs) do total = total + spec.h end
    while total > height do
        local candidate, room, priority = nil, 0, nil
        for i, spec in ipairs(specs) do
            local available = spec.h - spec.min
            if available > 0 and (not priority or spec.priority > priority
                    or (spec.priority == priority and available > room)) then
                candidate, room, priority = i, available, spec.priority
            end
        end
        if not candidate then break end
        specs[candidate].h = specs[candidate].h - 1
        total = total - 1
    end
    while total < height do
        local grew = false
        for priority = 1, 4 do
            for _i, spec in ipairs(specs) do
                if total >= height then break end
                if spec.priority == priority and spec.h < spec.max then
                    spec.h = spec.h + 1
                    total = total + 1
                    grew = true
                end
            end
            if grew or total >= height then break end
        end
        if not grew then break end
    end
    return specs
end

local function buildContent(blocks_config, data, page_w, h_padding, top_padding, calendar_widgets, stat_style, stats_settings, block_heights)
    local function sz(x) return Screen:scaleBySize(x) end
    stat_style = normalizeStatStyle(stat_style)
    local content_w = math.max(1, page_w - h_padding * 2)
    local body_w = content_w - sz(16)
    local card_gap = stat_style == "divider" and sz(8) or stat_style == "outline" and sz(9) or sz(6)
    local c3_w = math.floor((body_w - card_gap * 2) / 3)
    local c4_w = math.floor((body_w - card_gap * 3) / 4)
    local stats = data.stats or {}
    local now_t = os.date("*t")
    local days_this_month = math.max(1, now_t.day)
    local days_this_year = math.max(1, now_t.yday)
    local block_hits = {}

    local function card(opts)
        local height = opts.height or Screen:scaleBySize(74)
        local font_size = tonumber(opts.font_size)
        opts.value_size = font_size and sz(font_size)
            or sz(math.max(10, math.min(15, math.floor(height * 0.14))))
        opts.label_size = font_size and sz(math.max(6, math.floor(font_size * 0.6)))
            or sz(math.max(6, math.min(9, math.floor(height * 0.08))))
        opts.header_size = opts.header and opts.label_size or opts.header_size
        if opts.streak and flame_icon_path then
            local value_widget = TextWidget:new{
                text = opts.value or "",
                face = Font:getFace("infofont", opts.value_size),
            }
            local value_size = value_widget:getSize()
            local icon_size = math.max(8, math.floor((value_size.h or 12) * 0.62))
            opts.value_widget = HorizontalGroup:new{
                align = "center",
                IconWidget:new{
                    file = flame_icon_path,
                    width = icon_size,
                    height = icon_size,
                    alpha = true,
                },
                HorizontalSpan:new{ width = Screen:scaleBySize(3) },
                value_widget,
            }
        end
        opts.stat_style = stat_style
        return createCard(opts)
    end

    local function periodCards(block, body_h)
        local card_h = math.max(Screen:scaleBySize(36), body_h)
        local function blockCard(opts)
            opts.font_size = block.font_size
            return card(opts)
        end
        if block.id == "today" then
            return createCardRow(body_w, {
                blockCard{ width = c3_w, height = card_h, value = tostring(stats.today_pages or 0), label = _("Pages today") },
                blockCard{ width = c3_w, height = card_h, value = formatTime(stats.today_duration), label = _("Read today") },
                blockCard{ width = c3_w, height = card_h, value = tostring(stats.streak or 0), label = _("Day streak"), streak = true },
            }, stat_style, card_gap)
        elseif block.id == "this_week" then
            local avg_p = (stats.week_pages or 0) > 0 and math.floor((stats.week_pages or 0) / 7) or 0
            local avg_t = (stats.week_duration or 0) > 0 and math.floor((stats.week_duration or 0) / 7) or 0
            return createCardRow(body_w, {
                blockCard{ width = c4_w, height = card_h, value = tostring(stats.week_pages or 0), label = _("Pages") },
                blockCard{ width = c4_w, height = card_h, value = tostring(avg_p), label = _("Pages/day") },
                blockCard{ width = c4_w, height = card_h, value = formatTime(avg_t), label = _("Time/day") },
                blockCard{ width = c4_w, height = card_h, value = formatTime(stats.week_duration), label = _("Total time") },
            }, stat_style, card_gap)
        elseif block.id == "this_month" then
            local avg_p = math.floor((stats.month_pages or 0) / days_this_month)
            local avg_t = math.floor((stats.month_duration or 0) / days_this_month)
            return createCardRow(body_w, {
                blockCard{ width = c4_w, height = card_h, value = tostring(stats.month_pages or 0), label = _("Pages") },
                blockCard{ width = c4_w, height = card_h, value = tostring(avg_p), label = _("Pages/day") },
                blockCard{ width = c4_w, height = card_h, value = formatTime(avg_t), label = _("Time/day") },
                blockCard{ width = c4_w, height = card_h, value = formatTime(stats.month_duration), label = _("Total time") },
            }, stat_style, card_gap)
        elseif block.id == "this_year" then
            local avg_t = math.floor((stats.year_duration or 0) / days_this_year)
            return createCardRow(body_w, {
                blockCard{ width = c4_w, height = card_h, value = tostring(stats.year_pages or 0), label = _("Pages") },
                blockCard{ width = c4_w, height = card_h, value = formatTime(avg_t), label = _("Time/day") },
                blockCard{ width = c4_w, height = card_h, value = formatTime(stats.year_duration), label = _("Total time") },
                blockCard{ width = c4_w, height = card_h, value = tostring(stats.books_this_year or 0), label = _("Books read") },
            }, stat_style, card_gap)
        elseif block.id == "all_time" then
            return createCardRow(body_w, {
                blockCard{ width = c4_w, height = card_h, value = tostring(stats.lifetime_pages or 0), label = _("Total pages") },
                blockCard{ width = c4_w, height = card_h, value = formatTime(stats.avg_time_per_book), label = _("Time/book") },
                blockCard{ width = c4_w, height = card_h, value = formatLongTime(stats.lifetime_read_time), label = _("Read time") },
                blockCard{ width = c4_w, height = card_h, value = tostring(stats.books_finished or 0), label = _("Finished") },
            }, stat_style, card_gap)
        elseif block.id == "personal_records" then
            return createCardRow(body_w, {
                blockCard{ width = c3_w, height = card_h, header = _("Best day"), value = formatTime(stats.peak_day_duration), label = fmtPeakDay(stats.peak_day_ts) },
                blockCard{ width = c3_w, height = card_h, header = _("Best week"), value = formatTime(stats.peak_week_duration), label = fmtPeakWeek(stats.peak_week_ts) },
                blockCard{ width = c3_w, height = card_h, header = _("Best month"), value = formatLongTime(stats.peak_month_duration), label = fmtPeakMonth(stats.peak_month_ts) },
            }, stat_style, card_gap)
        elseif block.id == "library" then
            return createCardRow(body_w, {
                blockCard{ width = c3_w, height = card_h, value = tostring(stats.total_books or 0), label = _("Total books") },
                blockCard{ width = c3_w, height = card_h, value = tostring(stats.books_reading or 0), label = _("Reading") },
                blockCard{ width = c3_w, height = card_h, value = tostring(stats.books_finished or 0), label = _("Finished") },
            }, stat_style, card_gap)
        elseif block.id == "current_book" then
            local book = data.current_book or {}
            local avg = book.avg_time_per_page or 0
            return createCardRow(body_w, {
                blockCard{ width = c4_w, height = card_h, value = formatLongTime(book.total_time), label = _("Total time") },
                blockCard{ width = c4_w, height = card_h, value = tostring(book.pages_read or 0), label = _("Pages read") },
                blockCard{ width = c4_w, height = card_h, value = formatTime(avg), label = _("Time/page") },
                blockCard{ width = c4_w, height = card_h, value = tostring(book.session_pages or 0), label = _("Session pages") },
            }, stat_style, card_gap)
        end
    end

    local function graphBlock(block, body_h)
        local series = data.series[block.range_days or 14] or {}
        local graph = LineGraph:new{
            width = body_w,
            height = math.max(Screen:scaleBySize(42), body_h),
            series = series,
            metric = block.metric,
            empty_text = _("No reading data"),
            label_left = shortDate(series[1] and series[1].date),
            label_right = shortDate(series[#series] and series[#series].date),
            x_labels = graphDateLabels(series, 5),
            axis_color = Blitbuffer.COLOR_BLACK,
            dot_radius = block.range_days == 90 and math.max(1, sz(1)) or math.max(1, sz(3)),
        }
        local graph_container = CenterContainer:new{
            dimen = Geom:new{ w = body_w, h = graph:getSize().h },
            graph,
        }
        if not Device:isTouchDevice() or #series == 0 then
            return VerticalGroup:new{ graph_container }
        end
        local tap = InputContainer:new{
            dimen = Geom:new{ w = body_w, h = graph:getSize().h },
            ges_events = {
                TapStatsGraph = {
                    GestureRange:new{ ges = "tap", range = Geom:new{
                        x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight(),
                    } },
                },
            },
        }
        tap.onTapStatsGraph = function(tap_self, _arg, ges)
            if not (tap_self.dimen and ges and ges.pos and tap_self.dimen:contains(ges.pos)) then
                return false
            end
            local point = series[graph:getPointIndexAt(ges.pos.x - tap_self.dimen.x)]
            local year, month, day = tostring(point and point.date or ""):match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
            if not (year and month and day) then return false end
            local day_ts = os.time({
                year = tonumber(year), month = tonumber(month), day = tonumber(day),
                hour = 0, min = 0, sec = 0,
            })
            if os.date("%Y-%m-%d", day_ts) > os.date("%Y-%m-%d", os.time()) then return false end
            showCalendarDaySummary(PluginLoader:getPluginInstance("statistics"), day_ts, stat_style)
            return true
        end
        tap[1] = graph_container
        return VerticalGroup:new{
            tap,
        }
    end

    local function goalBlock(height, block)
        local config = PresetStore.getSettings("home")
        if type(config) ~= "table" then config = {} end
        local goals = type(config.goals) == "table" and config.goals or {}
        local metrics = type(goals.metrics) == "table" and goals.metrics or {}
        if metrics.monthly == "books" or metrics.yearly == "books" then
            local counts = LibraryDB.getBookCounts()
            stats.finished_this_month = counts.finished_this_month or 0
            stats.finished_this_year = counts.finished_this_year or 0
        end
        return HomeGoals.build{
            width = content_w,
            height = height,
            font_size = block.font_size or 11,
            data = { stats = stats },
            config = config,
        }
    end

    local function calendarBlock(body_h)
        local stats_plugin = PluginLoader:getPluginInstance("statistics")
        if type(stats_plugin) ~= "table" then
            return createFallbackCalendarWidget(body_w, body_h)
        end
        if type(stats_plugin.insertDB) == "function" then
            pcall(stats_plugin.insertDB, stats_plugin)
        end
        local CalendarView = loadNativeCalendarView()
        if not CalendarView then
            return createFallbackCalendarWidget(body_w, body_h)
        end
        local settings = stats_plugin.settings or {}
        local calendar_h = body_h
        local calendar_month = loadCalendarMonthConfig(stats_settings)
        local calendar = CalendarView:new{
            reader_statistics = stats_plugin,
            width = body_w,
            height = calendar_h,
            cur_month = calendar_month,
            start_day_of_week = settings.calendar_start_day_of_week,
            nb_book_spans = embeddedCalendarBookSpans(stats_plugin, calendar_month),
            show_hourly_histogram = false,
            browse_future_months = settings.calendar_browse_future_months,
        }
        tuneEmbeddedCalendar(calendar)
        clearStatsBackgrounds(calendar)
        local orig_go_to_month = calendar.goToMonth
        calendar.goToMonth = function(self_cal, month, ...)
            local result = orig_go_to_month(self_cal, month, ...)
            saveCalendarMonthConfig(stats_settings, self_cal.cur_month)
            return result
        end
        local orig_next_month = calendar.nextMonth
        calendar.nextMonth = function(self_cal, ...)
            local result = orig_next_month(self_cal, ...)
            saveCalendarMonthConfig(stats_settings, self_cal.cur_month)
            return result
        end
        local orig_prev_month = calendar.prevMonth
        calendar.prevMonth = function(self_cal, ...)
            local result = orig_prev_month(self_cal, ...)
            saveCalendarMonthConfig(stats_settings, self_cal.cur_month)
            return result
        end
        local orig_populate_items = calendar._populateItems
        calendar._populateItems = function(self_cal, ...)
            self_cal.nb_book_spans = embeddedCalendarBookSpans(stats_plugin, self_cal.cur_month)
            tuneEmbeddedCalendar(self_cal, false)
            local result = orig_populate_items(self_cal, ...)
            hideCalendarPageInfo(self_cal)
            installCalendarDaySummary(self_cal, stats_plugin, stat_style)
            clearStatsBackgrounds(self_cal)
            refreshEmbeddedCalendarLayout(self_cal)
            UIManager:setDirty(self_cal, "ui")
            return result
        end
        installCalendarDaySummary(calendar, stats_plugin, stat_style)
        calendar.show_parent = nil
        calendar.covers_fullscreen = false
        calendar.close_callback = nil
        calendar.onClose = function() return true end
        calendar.onMultiSwipe = function() return false end
        local orig_calendar_paintTo = calendar.paintTo
        calendar.paintTo = function(self_cal, bb, x, y)
            clearStatsBackgrounds(self_cal)
            return orig_calendar_paintTo(self_cal, bb, x, y)
        end
        calendar.onSwipe = function(_self, _arg, ges_ev)
            if not ges_ev then return false end
            local direction = ges_ev.direction
            if direction == "west" then
                calendar:nextMonth()
                return true
            elseif direction == "east" then
                calendar:prevMonth()
                return true
            end
            return false
        end
        return CenterContainer:new{
            dimen = Geom:new{ w = content_w, h = calendar:getSize().h },
            calendar,
        }, calendar
    end

    local items = { align = "center" }
    local y_acc = top_padding
    local has_overflow = false
    local required_heights = {}
    items[#items + 1] = VerticalSpan:new{ width = top_padding }

    for i, block in ipairs(blocks_config) do
        local block_h = block_heights[i] and block_heights[i].h or Screen:scaleBySize(80)
        local title = displayBlockTitle(block)
        local panel_padding = Screen:scaleBySize(8)
        local title_h = title ~= "" and Screen:scaleBySize(15) or 0
        local title_gap = title ~= "" and Screen:scaleBySize(5) or 0
        local panel_body_h = math.max(1, block_h - title_h - title_gap - panel_padding * 2)
        local body
        if block.id == "trend_graph" then
            body = graphBlock(block, panel_body_h)
        elseif block.id == "goal_progress" then
            body = goalBlock(block_h, block)
        elseif block.id == "calendar" then
            local calendar
            body, calendar = calendarBlock(block_h)
            if calendar_widgets then
                calendar_widgets[i] = calendar or body
            end
        else
            body = periodCards(block, panel_body_h)
        end

        if body then
            local panel
            local min_h
            if block.id == "goal_progress" or block.id == "calendar" then
                panel = CenterContainer:new{
                    dimen = Geom:new{ w = page_w, h = block_h },
                    body,
                }
                min_h = body:getSize().h
            else
                panel, min_h = makeBlockPanel(page_w, content_w, title, body, block_h)
            end
            if min_h <= block_h then
                if #block_hits > 0 then
                    local gap = sz(8)
                    items[#items + 1] = VerticalSpan:new{ width = gap }
                    y_acc = y_acc + gap
                end
                items[#items + 1] = panel
                block_hits[#block_hits + 1] = {
                    block_idx = i,
                    y_start = y_acc,
                    y_end = y_acc + block_h,
                }
                y_acc = y_acc + block_h
            else
                has_overflow = true
                required_heights[i] = min_h
                WidgetResources.free(panel)
                if calendar_widgets then calendar_widgets[i] = nil end
            end
        end
    end

    return VerticalGroup:new(items), block_hits, has_overflow, required_heights
end

function StatsPage.create(createStatusRow, repaintTitleBar, zen_plugin)
    if #active_stats_menus > 0 then
        return active_stats_menus[#active_stats_menus], false
    end
    local stats_settings = StatsSettings.load()
    local blocks_config = StatsSettings.enabledBlocks(stats_settings)
    local stat_style = stats_settings.stat_style
    local data = queryDashboardData(blocks_config)
    local menu = StandalonePage.create_menu{
        name = "stats",
        title = " ",
    }
    StandalonePage.prepare_shell(menu)
    StandalonePage.apply_status_row(menu, {
        createStatusRow = createStatusRow,
        repaintTitleBar = repaintTitleBar,
    })

    local tb = menu.title_bar
    local tb_h = tb and tb:getSize().h or 0
    local function getBodyHeight()
        local menu_h = menu.height or (menu.inner_dimen and menu.inner_dimen.h or menu.dimen.h)
        local body_h = menu_h - tb_h
        local navbar_h = tonumber(menu._zen_navbar_height)
            or tonumber(rawget(_G, "__ZEN_UI_NAVBAR_HEIGHT")) or 0
        local hard_body_h = Screen:getHeight() - tb_h - navbar_h
        if hard_body_h < 1 then hard_body_h = Screen:getHeight() - tb_h end
        if body_h < 1 then body_h = hard_body_h end
        if body_h > hard_body_h then body_h = hard_body_h end
        return body_h
    end
    local page_w = menu.inner_dimen and menu.inner_dimen.w or Screen:getWidth()
    local h_padding = math.max(2, math.min(Screen:scaleBySize(8), math.floor(page_w * 0.025)))
    if h_padding * 2 >= page_w then
        h_padding = math.max(0, math.floor(page_w * 0.04))
    end
    local block_hits
    local calendar_widgets = {}
    local function buildFixed()
        local body_h = getBodyHeight()
        local top_pad = 0
        local bottom_pad = Screen:scaleBySize(8)
        local visible_blocks = {}
        local required_heights = {}
        for _i, block in ipairs(blocks_config) do
            visible_blocks[#visible_blocks + 1] = block
        end

        while #visible_blocks > 0 do
            calendar_widgets = {}
            local gap_h = Screen:scaleBySize(8) * math.max(0, #visible_blocks - 1)
            local block_heights = computeBlockHeights(visible_blocks,
                math.max(1, body_h - top_pad - bottom_pad - gap_h), required_heights)
            local content, hits, has_overflow, measured_heights = buildContent(visible_blocks, data, page_w, h_padding, top_pad,
                calendar_widgets, stat_style, stats_settings, block_heights)
            content:resetLayout()
            if not has_overflow and content:getSize().h <= body_h then
                local remaining = body_h - content:getSize().h
                if remaining > 0 then
                    content[#content + 1] = VerticalSpan:new{ width = remaining }
                    content:resetLayout()
                end
                blocks_config = visible_blocks
                menu.cropping_widget = nil
                return FrameContainer:new{
                    width = page_w,
                    height = body_h,
                    padding = 0,
                    bordersize = 0,
                    background = statsFrameBg(),
                    content,
                }, hits
            end
            WidgetResources.free(content)
            local updated = false
            for i, min_h in pairs(measured_heights) do
                if min_h > (required_heights[i] or 0) then
                    required_heights[i] = min_h
                    updated = true
                end
            end
            if not updated then
                required_heights[#visible_blocks] = nil
                visible_blocks[#visible_blocks] = nil
            end
        end

        calendar_widgets = {}
        menu.cropping_widget = nil
        return FrameContainer:new{
            width = page_w,
            height = body_h,
            padding = 0,
            bordersize = 0,
            background = statsFrameBg(),
            VerticalSpan:new{ width = math.max(1, body_h) },
        }, {}
    end

    local content
    content, block_hits = buildFixed()

    local function rebuildStats()
        stats_settings = StatsSettings.load()
        blocks_config = StatsSettings.enabledBlocks(stats_settings)
        stat_style = stats_settings.stat_style
        data = queryDashboardData(blocks_config)
        local new_content
        new_content, block_hits = buildFixed()
        StandalonePage.mount_body(menu, new_content)
        UIManager:setDirty(menu, "ui")
    end
    menu._zen_stats_rebuild = rebuildStats

    local function closeConfigDialog()
        if menu._zen_block_dlg then
            UIManager:close(menu._zen_block_dlg)
            menu._zen_block_dlg = nil
        end
    end

    local function showRangeMenu(block_idx)
        closeConfigDialog()
        local buttons = {}
        for _i, range in ipairs({ 7, 14, 30, 90 }) do
            local selected = blocks_config[block_idx].range_days == range
            buttons[#buttons + 1] = {{
                text = tostring(range) .. _(" days") .. (selected and "  \u{2713}" or ""),
                enabled = not selected,
                callback = function()
                    UIManager:close(menu._zen_block_dlg)
                    menu._zen_block_dlg = nil
                    blocks_config[block_idx].range_days = range
                    StatsSettings.saveBlockOptions(stats_settings, blocks_config[block_idx])
                    rebuildStats()
                end,
            }}
        end
        menu._zen_block_dlg = ButtonDialog:new{
            title = _("Graph range"),
            title_align = "center",
            buttons = buttons,
        }
        UIManager:show(menu._zen_block_dlg)
    end

    local function showMetricMenu(block_idx)
        closeConfigDialog()
        local buttons = {}
        for _i, item in ipairs({
            { id = "pages", text = _("Pages") },
            { id = "time", text = _("Time") },
        }) do
            local current_metric = blocks_config[block_idx].metric
            if current_metric == "duration" then current_metric = "time" end
            local selected = current_metric == item.id
            buttons[#buttons + 1] = {{
                text = item.text .. (selected and "  \u{2713}" or ""),
                enabled = not selected,
                callback = function()
                    UIManager:close(menu._zen_block_dlg)
                    menu._zen_block_dlg = nil
                    blocks_config[block_idx].metric = item.id
                    StatsSettings.saveBlockOptions(stats_settings, blocks_config[block_idx])
                    rebuildStats()
                end,
            }}
        end
        menu._zen_block_dlg = ButtonDialog:new{
            title = _("Graph metric"),
            title_align = "center",
            buttons = buttons,
        }
        UIManager:show(menu._zen_block_dlg)
    end

    local function showCalendarMonthMenu(block_idx)
        closeConfigDialog()
        local calendar = calendar_widgets[block_idx]
        if not calendar then return end

        local min_month = calendar.min_month or calendar.cur_month or os.date("%Y-%m", os.time())
        local max_month = calendar.max_month or calendar.cur_month or os.date("%Y-%m", os.time())
        local selected_month = calendar.cur_month or max_month
        if calendar.browse_future_months then
            max_month = monthShift(max_month, 12)
        end
        if selected_month > max_month then max_month = selected_month end
        if selected_month < min_month then min_month = selected_month end

        local buttons = {}
        local month = max_month
        local guard = 0
        while month >= min_month and guard < 240 do
            local item_month = month
            local selected = item_month == selected_month
            buttons[#buttons + 1] = {{
                text = monthLabel(item_month) .. (selected and "  \u{2713}" or ""),
                enabled = not selected,
                callback = function()
                    UIManager:close(menu._zen_block_dlg)
                    menu._zen_block_dlg = nil
                    if type(calendar.goToMonth) == "function" then
                        calendar:goToMonth(item_month)
                    else
                        calendar.cur_month = item_month
                        if type(calendar._populateItems) == "function" then
                            calendar:_populateItems()
                        end
                    end
                    UIManager:setDirty(menu, "ui")
                end,
            }}
            month = monthShift(month, -1)
            guard = guard + 1
        end

        menu._zen_block_dlg = ButtonDialog:new{
            title = _("Months"),
            title_align = "center",
            buttons = buttons,
        }
        UIManager:show(menu._zen_block_dlg)
    end

    local function showBlockMenu(block_idx)
        closeConfigDialog()
        local current = blocks_config[block_idx]
        local buttons = {}
        if current.id == "trend_graph" then
            buttons[#buttons + 1] = {{
                text = _("Metric") .. ": " .. (current.metric == "time" and _("Time") or _("Pages")),
                callback = function() showMetricMenu(block_idx) end,
            }}
            buttons[#buttons + 1] = {{
                text = _("Range") .. ": " .. tostring(current.range_days or 14) .. _(" days"),
                callback = function() showRangeMenu(block_idx) end,
            }}
        end
        if current.id == "calendar" then
            local calendar = calendar_widgets[block_idx]
            buttons[#buttons + 1] = {{
                text = _("Date") .. ": "
                    .. (calendar and monthLabel(calendar.cur_month) or ""),
                callback = function() showCalendarMonthMenu(block_idx) end,
            }}
        end
        local has_context = #buttons > 0
        if not has_context and stats_settings.edit_mode == true then
            return require("modules/settings/sections/stats_settings")
                .openWidgetSettings(current.id, zen_plugin)
        end
        if stats_settings.edit_mode == true then
            buttons[#buttons + 1] = {{
                text = icons.settings .. "  " .. _("Widget settings"),
                callback = function()
                    closeConfigDialog()
                    UIManager:nextTick(function()
                        require("modules/settings/sections/stats_settings")
                            .openWidgetSettings(current.id, zen_plugin)
                    end)
                end,
            }}
        end
        if #buttons == 0 then return false end

        menu._zen_block_dlg = ButtonDialog:new{
            title = _("Customize widget"),
            title_align = "center",
            buttons = buttons,
        }
        UIManager:show(menu._zen_block_dlg)
    end

    if not menu.ges_events then menu.ges_events = {} end
    menu.ges_events.ZenStatsHold = {
        GestureRange:new{
            ges = "hold",
            range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() },
        },
    }
    local top_tap_zone_h = math.max(1, math.floor(Screen:getHeight() * 0.05))
    menu.ges_events.ZenStatsTopTap = {
        GestureRange:new{
            ges = "tap",
            range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = top_tap_zone_h },
        },
    }
    local function openTopMenuFromTap(ges)
        if not (ges and ges.pos and ges.pos.y < top_tap_zone_h) then return false end
        local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
        local fm_menu = ok_fm and FileManager.instance and FileManager.instance.menu
        if fm_menu and fm_menu.activation_menu ~= "swipe" then
            fm_menu:onShowMenu(fm_menu:_getTabIndexFromLocation(ges))
            return true
        end
        local ok_rui, RUI = pcall(require, "apps/reader/readerui")
        local reader_menu = ok_rui and RUI.instance and RUI.instance.menu
        if reader_menu and reader_menu.activation_menu ~= "swipe" then
            reader_menu:onShowMenu(reader_menu:_getTabIndexFromLocation(ges))
            return true
        end
        return false
    end
    function menu:onZenStatsTopTap(_arg, ges)
        return openTopMenuFromTap(ges)
    end
    if tb then
        tb.ges_events = tb.ges_events or {}
        tb.ges_events.ZenStatsTopTap = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = top_tap_zone_h },
            },
        }
        function tb:onZenStatsTopTap(_arg, ges)
            return openTopMenuFromTap(ges)
        end
    end
    local orig_onGesture = menu.onGesture
    function menu:onGesture(ges)
        if ges and ges.ges == "tap" and openTopMenuFromTap(ges) then
            return true
        end
        if orig_onGesture then return orig_onGesture(self, ges) end
    end
    function menu:onZenStatsHold(_ges_event, ges)
        local offset_y = self.dimen and self.dimen.y or 0
        local content_y = ges.pos.y - offset_y - tb_h
        if content_y < 0 then return false end
        for _i, hit in ipairs(block_hits) do
            if content_y >= hit.y_start and content_y < hit.y_end then
                if blocks_config[hit.block_idx].id == "calendar" and stats_settings.edit_mode ~= true then
                    showCalendarMonthMenu(hit.block_idx)
                else
                    showBlockMenu(hit.block_idx)
                end
                return true
            end
        end
        return false
    end

    StandalonePage.mount_body(menu, content)

    if menu.page_info then
        while #menu.page_info > 0 do table.remove(menu.page_info) end
        menu.page_info:resetLayout()
        menu.page_info.dimen = Geom:new{ w = 0, h = 0 }
        menu.page_info.getSize = function(self) return self.dimen end
    end

    menu.close_callback = function()
        UIManager:close(menu)
    end

    active_stats_menus[#active_stats_menus + 1] = menu
    local orig_onCloseWidget = menu.onCloseWidget
    function menu:onCloseWidget(...)
        for i = #active_stats_menus, 1, -1 do
            if rawequal(active_stats_menus[i], self) then
                table.remove(active_stats_menus, i)
                break
            end
        end
        if self._zen_block_dlg then
            UIManager:close(self._zen_block_dlg)
            self._zen_block_dlg = nil
        end
        if orig_onCloseWidget then
            return orig_onCloseWidget(self, ...)
        end
    end

    UIManager:scheduleIn(0, function()
        UIManager:setDirty(menu, "flashui")
    end)

    return menu, true
end

function StatsPage.closeAll()
    for i = #active_stats_menus, 1, -1 do
        local menu = active_stats_menus[i]
        if menu then
            if menu._zen_block_dlg then
                UIManager:close(menu._zen_block_dlg)
                menu._zen_block_dlg = nil
            end
            UIManager:close(menu)
        end
        active_stats_menus[i] = nil
    end
end

function StatsPage.rebuildActive()
    for _i, menu in ipairs(active_stats_menus) do
        if menu and menu._zen_stats_rebuild then menu:_zen_stats_rebuild() end
    end
end

local function register_stats_api(zen_plugin)
    if not zen_plugin or type(zen_plugin.config) ~= "table" then return end
    SharedState.register(zen_plugin, { stats = StatsPage })
end

SharedState.registerLoader("stats", register_stats_api)

return StatsPage
