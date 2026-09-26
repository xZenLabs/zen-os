local Background = require("common/ui/background")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local RenderText = require("ui/rendertext")
local TextWidget = require("ui/widget/textwidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local GestureRange = require("ui/gesturerange")
local ButtonDialog = require("ui/widget/buttondialog")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local Font = require("ui/font")
local Device = require("device")
local WidgetResources = require("common/widget_resources")
local ZenModalClose = require("common/ui/zen_modal_close")
local _ = require("gettext")
local Screen = Device.screen
local MIN_FONT_SIZE = 10
local DEFAULT_FONT_SIZE = 11
local MAX_FONT_SIZE = 16

local function text_ink_bounds(widget)
    local baseline = widget:getBaseline()
    local metrics = RenderText:sizeUtf8Text(
        0, false, widget.face, widget._text_to_draw or widget.text, true, widget.bold)
    return baseline - metrics.y_top, baseline + metrics.y_bottom
end

local function paint_pill(bb, x, y, w, h, color)
    if w <= 0 or h <= 0 then return end
    if h <= 1 then
        bb:paintRect(x, y, w, h, color)
        return
    end
    local r = math.floor(h / 2)
    if w <= h then
        local cx = x + math.floor(w / 2)
        for row = 0, h - 1 do
            local dy = row - r + 0.5
            local half = math.floor(math.sqrt(math.max(0, r * r - dy * dy)) + 0.5)
            local x0 = math.max(x, cx - half)
            local rw = math.min(w, half * 2)
            if rw > 0 then bb:paintRect(x0, y + row, rw, 1, color) end
        end
        return
    end
    for row = 0, h - 1 do
        local dy = row - r + 0.5
        local inset = math.floor(r - math.sqrt(math.max(0, r * r - dy * dy)) + 0.5)
        local rw = w - inset * 2
        if rw > 0 then bb:paintRect(x + inset, y + row, rw, 1, color) end
    end
end

local function progress_bar(width, current, target, bar_h)
    local pct = 0
    if target > 0 then
        pct = math.min(1, math.max(0, current / target))
    end
    local bar_w = width
    local fill_w = math.floor(bar_w * pct)
    if fill_w > 0 then fill_w = math.min(bar_w, math.max(bar_h, fill_w)) end

    local bar = {
        dimen = Geom:new{ w = bar_w, h = bar_h },
        getSize = function(self)
            return self.dimen
        end,
        handleEvent = function()
            return false
        end,
        paintTo = function(_self, bb, x, y)
            paint_pill(bb, x, y, bar_w, bar_h, Blitbuffer.COLOR_LIGHT_GRAY)
            if fill_w > 0 then
                paint_pill(bb, x, y, fill_w, bar_h, Blitbuffer.COLOR_GRAY_5)
            end
        end,
    }

    return bar, math.floor(pct * 100 + 0.5)
end

local function create_goal_summary_card(width, row)
    local padding = Screen:scaleBySize(8)
    local inner_w = math.max(1, width - padding * 2)
    local title = TextWidget:new{
        text = row.summary_label,
        face = Font:getFace("smallinfofontbold", Screen:scaleBySize(10)),
        max_width = inner_w,
    }
    local value_face = Font:getFace("smallinfofont", Screen:scaleBySize(12))
    local values = { align = "center" }
    local stats = {
        tostring(row.pages_current) .. " / " .. tostring(row.pages_target) .. " " .. _("pages"),
        tostring(row.time_current) .. " / " .. tostring(row.time_target) .. " " .. _("min"),
    }
    if row.books_target then
        stats[#stats + 1] = tostring(row.books_current) .. " / " .. tostring(row.books_target) .. " " .. _("Books")
    end
    local value_w = math.floor(inner_w / #stats)
    for _i, value in ipairs(stats) do
        local text = TextWidget:new{
            text = value,
            face = value_face,
            max_width = value_w,
        }
        values[#values + 1] = CenterContainer:new{
            dimen = Geom:new{ w = value_w, h = text:getSize().h },
            text,
        }
    end
    values = HorizontalGroup:new(values)
    local content = VerticalGroup:new{
        LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = title:getSize().h },
            title,
        },
        VerticalSpan:new{ width = Screen:scaleBySize(5) },
        values,
    }
    return FrameContainer:new{
        width = width,
        height = content:getSize().h + padding * 2,
        padding = padding,
        bordersize = 0,
        background = Background.tile_bg(Blitbuffer.COLOR_WHITE),
        content,
    }
end

local function enable_dialog_scroll(dialog, scroll_widget)
    if dialog.movable then dialog.movable.ges_events = {} end
    for _i, event in ipairs({ "Touch", "Swipe", "Pan", "PanRelease", "Hold", "HoldPan", "HoldRelease" }) do
        local gesture = event:gsub("(%u)", function(letter) return "_" .. letter:lower() end):sub(2)
        local name = "ZenReadingGoals" .. event
        dialog.ges_events[name] = {
            GestureRange:new{ ges = gesture, range = Geom:new{
                x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight(),
            } },
        }
        dialog["on" .. name] = function(_self, _arg, ges)
            return scroll_widget["onScrollable" .. event](scroll_widget, nil, ges)
        end
    end
end

local function show_goals_summary(rows)
    local dialog_w = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9)
    local dialog = ButtonDialog:new{ width = dialog_w, buttons = {} }
    local width = math.max(Screen:scaleBySize(160), dialog_w - Screen:scaleBySize(28))
    local scroll_w = math.max(
        Screen:scaleBySize(120),
        width - ScrollableContainer:getScrollbarWidth() - Screen:scaleBySize(4)
    )
    local title_bar = TitleBar:new{
        width = width,
        align = "left",
        title = _("Reading goals"),
        title_face = Font:getFace("smallinfofontbold", Screen:scaleBySize(10)),
        show_parent = dialog,
    }
    local close_button = ZenModalClose.installTitleBar(
        title_bar, dialog, function() UIManager:close(dialog) end
    )
    dialog:addWidget(title_bar)
    dialog:addWidget(VerticalSpan:new{ width = Screen:scaleBySize(6) })
    local items = { align = "center" }
    for _i, row in ipairs(rows) do
        items[#items + 1] = create_goal_summary_card(scroll_w, row)
        if _i < #rows then items[#items + 1] = VerticalSpan:new{ width = Screen:scaleBySize(8) } end
    end
    local content = VerticalGroup:new(items)
    local content_h = math.min(content:getSize().h, math.floor(Screen:getHeight() * 0.58))
    local scroll_widget = ScrollableContainer:new{
        dimen = Geom:new{ w = width, h = content_h },
        content,
    }
    dialog:addWidget(scroll_widget)
    enable_dialog_scroll(dialog, scroll_widget)
    ZenModalClose.addToFocusLayout(dialog, close_button)
    UIManager:show(dialog)
end

return {
    id = "reading_goals",
    label = _("Reading goals"),
    size = "xs",
    build = function(ctx)
        local width = ctx.width
        local height = ctx.height
        local stats = ctx.data.goal_stats or ctx.data.stats or {}
        local goals = ctx.config.goals or {}
        local legacy_metric = goals.metric == "time" and "time" or "pages"
        local metrics = type(goals.metrics) == "table" and goals.metrics or {}
        local valid_periods = { daily = true, weekly = true, monthly = true, yearly = true }
        local periods, seen = {}, {}
        for _i, period in ipairs(type(goals.periods) == "table" and goals.periods or {}) do
            if valid_periods[period] and not seen[period] then
                periods[#periods + 1] = period
                seen[period] = true
            end
        end
        if #periods == 0 then periods[1] = goals.period == "weekly" and "weekly" or "daily" end
        local daily_pages_target = tonumber(goals.daily_pages_target) or 30
        if daily_pages_target < 1 then daily_pages_target = 1 end
        local weekly_pages_target = tonumber(goals.weekly_pages_target) or 210
        if weekly_pages_target < 1 then weekly_pages_target = 1 end
        local monthly_pages_target = tonumber(goals.monthly_pages_target) or 900
        if monthly_pages_target < 1 then monthly_pages_target = 1 end
        local yearly_pages_target = tonumber(goals.yearly_pages_target) or 1000
        if yearly_pages_target < 1 then yearly_pages_target = 1 end
        local daily_time_target_min = tonumber(goals.daily_time_target_min) or 30
        if daily_time_target_min < 1 then daily_time_target_min = 1 end
        local weekly_time_target_min = tonumber(goals.weekly_time_target_min) or 210
        if weekly_time_target_min < 1 then weekly_time_target_min = 1 end
        local monthly_time_target_min = tonumber(goals.monthly_time_target_min) or 900
        if monthly_time_target_min < 1 then monthly_time_target_min = 1 end
        local yearly_time_target_min = tonumber(goals.yearly_time_target_min) or 1000
        if yearly_time_target_min < 1 then yearly_time_target_min = 1 end
        local monthly_books_target = tonumber(goals.monthly_books_target) or 1
        if monthly_books_target < 1 then monthly_books_target = 1 end
        local yearly_books_target = tonumber(goals.yearly_books_target) or 12
        if yearly_books_target < 1 then yearly_books_target = 1 end

        local goal_rows = {}
        local labels = {
            daily = _("Daily"),
            weekly = _("Weekly"),
            monthly = _("Monthly"),
            yearly = _("Yearly"),
        }
        local today = os.time()
        local month = _(os.date("%B", today))
        local summary_labels = {
            daily = string.format(_("%s goal (%s)"), labels.daily,
                month .. " " .. os.date("%d", today)),
            weekly = string.format(_("%s goal"), labels.weekly),
            monthly = string.format(_("%s goal (%s)"), labels.monthly, month),
            yearly = string.format(_("%s goal (%s)"), labels.yearly, os.date("%Y", today)),
        }
        for _i, period in ipairs(periods) do
            local metric = (period == "monthly" or period == "yearly") and metrics[period] == "books"
                and "books" or metrics[period] == "time" and "time"
                or metrics[period] == "pages" and "pages" or legacy_metric
            local current, target
            if metric == "time" then
                local duration = period == "weekly" and stats.week_duration
                    or period == "monthly" and stats.month_duration
                    or period == "yearly" and stats.year_duration or stats.today_duration
                current = math.floor((duration or 0) / 60)
                target = period == "weekly" and weekly_time_target_min
                    or period == "monthly" and monthly_time_target_min
                    or period == "yearly" and yearly_time_target_min or daily_time_target_min
            elseif metric == "books" then
                current = period == "monthly" and (stats.finished_this_month or 0)
                    or (stats.finished_this_year or 0)
                target = period == "monthly" and monthly_books_target or yearly_books_target
            else
                local pages = period == "weekly" and stats.week_pages
                    or period == "monthly" and stats.month_pages
                    or period == "yearly" and stats.year_pages or stats.today_pages
                current = math.floor(pages or 0)
                target = period == "weekly" and weekly_pages_target
                    or period == "monthly" and monthly_pages_target
                    or period == "yearly" and yearly_pages_target or daily_pages_target
            end
            goal_rows[#goal_rows + 1] = {
                label = labels[period], summary_label = summary_labels[period], current = current, target = target,
                unit = metric == "time" and _("min") or metric == "books" and _("Books") or _("pages"),
                pages_current = math.floor(period == "weekly" and stats.week_pages
                    or period == "monthly" and stats.month_pages
                    or period == "yearly" and stats.year_pages or stats.today_pages or 0),
                pages_target = period == "weekly" and weekly_pages_target
                    or period == "monthly" and monthly_pages_target
                    or period == "yearly" and yearly_pages_target or daily_pages_target,
                time_current = math.floor((period == "weekly" and stats.week_duration
                    or period == "monthly" and stats.month_duration
                    or period == "yearly" and stats.year_duration or stats.today_duration or 0) / 60),
                time_target = period == "weekly" and weekly_time_target_min
                    or period == "monthly" and monthly_time_target_min
                    or period == "yearly" and yearly_time_target_min or daily_time_target_min,
                books_current = period == "monthly" and math.floor(stats.finished_this_month or 0)
                    or period == "yearly" and math.floor(stats.finished_this_year or 0) or nil,
                books_target = period == "monthly" and monthly_books_target
                    or period == "yearly" and yearly_books_target or nil,
            }
        end
        local pad_h = Screen:scaleBySize(8)
        local content_w = math.max(20, width - pad_h * 2)
        local module_cfg = ctx.module_cfg or {}
        local configured_font_size = tonumber(module_cfg.font_size)
            or DEFAULT_FONT_SIZE
        local max_px = math.max(MIN_FONT_SIZE,
            math.min(MAX_FONT_SIZE, configured_font_size))
        local min_px = MIN_FONT_SIZE
        local min_bar_w = math.max(24, math.floor(content_w * 0.16))
        local gap = math.max(2, math.floor(content_w * 0.01))
        local chosen_face
        local chosen_line_h
        local chosen_bar_h
        local chosen_ink_top
        local chosen_ink_bottom
        local left_text_w = 0
        local right_text_w = 0
        local row_h = math.max(1, math.floor(height / #goal_rows))

        for px = max_px, min_px, -1 do
            local face = Font:getFace("smallinfofont", Screen:scaleBySize(px))
            local lw, rw = 0, 0
            local candidate_ink_top
            local candidate_ink_bottom
            for _i, row in ipairs(goal_rows) do
                local left_probe = TextWidget:new{ text = row.label, face = face }
                local right_probe = TextWidget:new{
                    text = tostring(row.current) .. " / " .. tostring(row.target) .. " " .. row.unit .. " (100%)",
                    face = face,
                }
                lw = math.max(lw, left_probe:getSize().w or 0)
                rw = math.max(rw, right_probe:getSize().w or 0)
                local left_top, left_bottom = text_ink_bounds(left_probe)
                local right_top, right_bottom = text_ink_bounds(right_probe)
                candidate_ink_top = math.min(
                    candidate_ink_top or left_top, left_top, right_top)
                candidate_ink_bottom = math.max(
                    candidate_ink_bottom or left_bottom, left_bottom, right_bottom)
                WidgetResources.free(left_probe)
                WidgetResources.free(right_probe)
            end
            local line_probe = TextWidget:new{ text = "A", face = face }
            local candidate_line_h = line_probe:getSize().h or math.max(10, min_px)
            WidgetResources.free(line_probe)
            local candidate_bar_h = math.max(6,
                math.min(12, math.floor(candidate_line_h * 0.65)))
            local candidate_offset = math.floor((row_h - candidate_line_h) / 2)
            if candidate_ink_top + candidate_offset >= 0
                    and candidate_ink_bottom + candidate_offset <= row_h
                    and candidate_bar_h <= row_h then
                chosen_face = face
                chosen_line_h = candidate_line_h
                chosen_bar_h = candidate_bar_h
                chosen_ink_top = candidate_ink_top
                chosen_ink_bottom = candidate_ink_bottom
                left_text_w = lw
                right_text_w = rw
                break
            end
        end
        if not chosen_face then
            chosen_face = Font:getFace("smallinfofont", Screen:scaleBySize(min_px))
            for _i, row in ipairs(goal_rows) do
                local left_probe = TextWidget:new{ text = row.label, face = chosen_face }
                local right_probe = TextWidget:new{
                    text = tostring(row.current) .. " / " .. tostring(row.target) .. " " .. row.unit .. " (100%)",
                    face = chosen_face,
                }
                left_text_w = math.max(left_text_w, left_probe:getSize().w or 0)
                right_text_w = math.max(right_text_w, right_probe:getSize().w or 0)
                local left_top, left_bottom = text_ink_bounds(left_probe)
                local right_top, right_bottom = text_ink_bounds(right_probe)
                chosen_ink_top = math.min(
                    chosen_ink_top or left_top, left_top, right_top)
                chosen_ink_bottom = math.max(
                    chosen_ink_bottom or left_bottom, left_bottom, right_bottom)
                WidgetResources.free(left_probe)
                WidgetResources.free(right_probe)
            end
        end

        if not chosen_line_h then
            local line_probe = TextWidget:new{ text = "A", face = chosen_face }
            chosen_line_h = line_probe:getSize().h or math.max(10, min_px)
            WidgetResources.free(line_probe)
            chosen_bar_h = math.max(6,
                math.min(12, math.floor(chosen_line_h * 0.65)))
        end
        local line_h = chosen_line_h
        local bar_h = chosen_bar_h
        local ink_h = math.max(1, chosen_ink_bottom - chosen_ink_top)
        local row_gap_h = 0
        if #goal_rows > 1 then
            local desired_gap = math.max(1, math.floor(ink_h * 0.15 + 0.5))
            local available_gap = math.max(0,
                math.floor((height - ink_h * #goal_rows) / (#goal_rows - 1)))
            row_gap_h = math.min(desired_gap, available_gap)
            while row_gap_h > 0 do
                row_h = math.max(1,
                    math.floor((height - row_gap_h * (#goal_rows - 1)) / #goal_rows))
                local offset = math.floor((row_h - line_h) / 2)
                if chosen_ink_top + offset >= 0
                        and chosen_ink_bottom + offset <= row_h then
                    break
                end
                row_gap_h = row_gap_h - 1
            end
            row_h = math.max(1,
                math.floor((height - row_gap_h * (#goal_rows - 1)) / #goal_rows))
        end

        local left_w = left_text_w + 2
        local right_w = right_text_w + 2
        local text_budget = math.max(2, content_w - min_bar_w - gap * 2)
        if left_w + right_w > text_budget then
            left_w = math.max(1, math.min(left_w, math.floor(text_budget * 0.3)))
            right_w = math.max(1, text_budget - left_w)
        end
        local bar_w = math.max(1, content_w - left_w - right_w - gap * 2)
        local rows = {}
        local body_ink_top
        local body_ink_bottom
        local row_y = 0
        for i, row in ipairs(goal_rows) do
            local bar, pct = progress_bar(bar_w, row.current, row.target, bar_h)
            local value_text = tostring(row.current) .. " / " .. tostring(row.target)
                .. " " .. row.unit .. " (" .. tostring(pct) .. "%)"
            local left_text = TextWidget:new{
                text = row.label, face = chosen_face, fgcolor = Blitbuffer.COLOR_GRAY_3,
                max_width = left_w, truncate_with_ellipsis = true,
            }
            local right_text = TextWidget:new{
                text = value_text, face = chosen_face, fgcolor = Blitbuffer.COLOR_GRAY_3,
                max_width = right_w, truncate_with_ellipsis = true,
            }
            local left_top, left_bottom = text_ink_bounds(left_text)
            local right_top, right_bottom = text_ink_bounds(right_text)
            local left_offset = math.floor((row_h - line_h) / 2)
            local right_offset = left_offset
            local bar_top = math.floor((row_h - bar_h) / 2)
            left_top, left_bottom = left_top + left_offset, left_bottom + left_offset
            right_top, right_bottom = right_top + right_offset, right_bottom + right_offset
            local ink_top = math.min(left_top, right_top, bar_top)
            local ink_bottom = math.max(left_bottom, right_bottom, bar_top + bar_h)
            body_ink_top = math.min(body_ink_top or row_y + ink_top, row_y + ink_top)
            body_ink_bottom = math.max(
                body_ink_bottom or row_y + ink_bottom, row_y + ink_bottom)
            rows[#rows + 1] = HorizontalGroup:new{
                LeftContainer:new{
                    dimen = Geom:new{ w = left_w, h = row_h },
                    left_text,
                },
                HorizontalSpan:new{ width = gap },
                CenterContainer:new{
                    dimen = Geom:new{ w = bar_w, h = row_h },
                    bar,
                },
                HorizontalSpan:new{ width = gap },
                RightContainer:new{
                    dimen = Geom:new{ w = right_w, h = row_h },
                    right_text,
                },
            }
            row_y = row_y + row_h
            if i < #goal_rows and row_gap_h > 0 then
                rows[#rows + 1] = VerticalSpan:new{ width = row_gap_h }
                row_y = row_y + row_gap_h
            end
        end
        local body = VerticalGroup:new(rows)
        local body_size = body:getSize()
        local body_h = body_size.h or height
        local body_top = math.floor(math.max(0, height - body_h) / 2)
        local visual_shift = 0
        local body_container = CenterContainer:new{
            dimen = Geom:new{ w = width, h = height },
            body,
        }
        local original_body_paint = body_container.paintTo
        body_container.paintTo = function(self, bb, x, y)
            return original_body_paint(self, bb, x, y + visual_shift)
        end
        if type(ctx.setContentBounds) == "function" then
            local visual_top = body_top + (body_ink_top or 0)
            local visual_bottom = body_top + (body_ink_bottom or body_h)
            ctx.setContentBounds{
                top = visual_top,
                bottom = visual_bottom,
                min_shift = -visual_top,
                max_shift = height - visual_bottom,
                set_shift = function(shift) visual_shift = shift end,
            }
        end

        local body_frame = FrameContainer:new{
            width = width,
            height = height,
            padding = 0,
            bordersize = 0,
            background = Background.tile_bg(Blitbuffer.COLOR_WHITE),
            body_container,
        }
        local tap = InputContainer:new{
            dimen = Geom:new{ w = width, h = height },
            ges_events = {
                TapReadingGoals = {
                    GestureRange:new{ ges = "tap", range = Geom:new{
                        x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight(),
                    } },
                },
                HoldReadingGoals = {
                    GestureRange:new{ ges = "hold", range = Geom:new{
                        x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight(),
                    } },
                },
            },
        }
        tap.onTapReadingGoals = function(tap_self, _arg, ges)
            if not (tap_self.dimen and ges and ges.pos and tap_self.dimen:contains(ges.pos)) then
                return false
            end
            if ctx.openTopMenu and ctx.openTopMenu(ges) then return true end
            show_goals_summary(goal_rows)
            return true
        end
        tap.onHoldReadingGoals = function(tap_self, _arg, ges)
            if not (tap_self.dimen and ges and ges.pos and tap_self.dimen:contains(ges.pos)) then
                return false
            end
            if ctx.editMode and ctx.openWidgetSettings then
                return ctx.openWidgetSettings()
            end
            return false
        end
        tap[1] = body_frame
        return tap
    end,
}
