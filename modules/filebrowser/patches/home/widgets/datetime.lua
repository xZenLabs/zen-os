local Background = require("common/ui/background")
local Blitbuffer = require("ffi/blitbuffer")
local DateFormat = require("common/date_format")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local FrameContainer = require("ui/widget/container/framecontainer")
local TextWidget = require("ui/widget/textwidget")
local WidgetResources = require("common/widget_resources")
local library_font = require("modules/filebrowser/patches/library_font")
local _ = require("gettext")

local DEFAULT_MAX_TIME_SIZE = 36
local MAX_TIME_SIZE = 52

local function clamp(value, minimum, maximum)
    value = math.floor((tonumber(value) or minimum) + 0.5)
    return math.max(minimum, math.min(maximum, value))
end

local function time_text()
    local gs = rawget(_G, "G_reader_settings")
    local twelve_hour = gs and gs:isTrue("twelve_hour_clock")
    local text = os.date(twelve_hour and "%I:%M" or "%H:%M")
    if twelve_hour then
        text = text:gsub("^0(%d:)", "%1")
    end
    return text
end

local function clock_styles(module_cfg)
    local text_styles = type(module_cfg.text_styles) == "table"
        and module_cfg.text_styles or {}
    local time_style = type(text_styles.time) == "table" and text_styles.time or {}
    local date_style = type(text_styles.date) == "table" and text_styles.date or {}
    local time_font_name = type(time_style.font_face) == "string"
        and time_style.font_face ~= "" and time_style.font_face or "default"
    local date_font_name = type(date_style.font_face) == "string"
        and date_style.font_face ~= "" and date_style.font_face or "default"
    if time_font_name == "default" then time_font_name = library_font.getFontName() end
    if date_font_name == "default" then date_font_name = library_font.getFontName() end
    return time_style, date_style, time_font_name, date_font_name
end

local function new_clock_widgets(Screen, time_font_name, date_font_name,
        time_str, date_str, time_px, date_px, date_gap)
    date_px = date_px or math.max(8, math.floor(time_px * 0.36))
    local tw = TextWidget:new{
        text = time_str,
        face = Font:getFace(time_font_name, Screen:scaleBySize(time_px)),
        bold = true,
    }
    local dw = TextWidget:new{
        text = date_str,
        face = Font:getFace(date_font_name, Screen:scaleBySize(date_px)),
        fgcolor = Blitbuffer.COLOR_GRAY_3,
    }
    local ts = tw:getSize()
    local ds = dw:getSize()
    local th = ts.h or 18
    local dh = ds.h or 10
    local overlap = math.floor(th * 0.16)
    local ch = th - overlap + date_gap + dh
    return tw, dw, ts, ds, th, dh, overlap, ch
end

local function preferred_height(ctx)
    ctx = type(ctx) == "table" and ctx or {}
    local Screen = Device.screen
    local width = math.max(1, tonumber(ctx.width) or Screen:getWidth())
    local module_cfg = type(ctx.module_cfg) == "table" and ctx.module_cfg or {}
    local time_style, date_style, time_font_name, date_font_name =
        clock_styles(module_cfg)
    local automatic_font_size = module_cfg.automatic_font_size ~= false
    local date_gap = math.max(1, Screen:scaleBySize(2))
    local time_str = time_text()
    local date_str = DateFormat.formatLongWithWeekday()
    local best_h
    local last_h

    local function keep_if_fits(time_px, date_px)
        local tw, dw, ts, ds, th, dh, overlap = new_clock_widgets(
            Screen, time_font_name, date_font_name,
            time_str, date_str, time_px, date_px, date_gap)
        local ch = th - overlap + date_gap + dh
        local fits = (ts.w or 0) <= width and (ds.w or 0) <= width
        WidgetResources.free(tw)
        WidgetResources.free(dw)
        last_h = ch
        if fits then best_h = ch end
        return fits
    end

    if automatic_font_size then
        local low = 4
        local high = clamp(tonumber(module_cfg.max_font_size)
            or DEFAULT_MAX_TIME_SIZE, 8, MAX_TIME_SIZE)
        while low <= high do
            local time_px = math.floor((low + high) / 2)
            if keep_if_fits(time_px) then
                low = time_px + 1
            else
                high = time_px - 1
            end
        end
    else
        local time_px = clamp(time_style.font_size, 8, MAX_TIME_SIZE)
        local date_px = clamp(date_style.font_size, 6, 80)
        local scale = 1
        while scale >= 0.25 do
            if keep_if_fits(
                    math.max(4, math.floor(time_px * scale + 0.5)),
                    math.max(4, math.floor(date_px * scale + 0.5))) then
                break
            end
            scale = scale - 0.05
        end
    end

    return (best_h or last_h or 1) + Screen:scaleBySize(2)
end

return {
    id = "datetime",
    label = _("Date/time"),
    size = "sm",
    preferredHeight = preferred_height,
    build = function(ctx)
        local width = ctx.width
        local height = ctx.height
        local Screen = Device.screen
        local module_cfg = type(ctx.module_cfg) == "table" and ctx.module_cfg or {}
        local time_style, date_style, time_font_name, date_font_name =
            clock_styles(module_cfg)
        local automatic_font_size = module_cfg.automatic_font_size ~= false
        local date_gap = math.max(1, Screen:scaleBySize(2))
        local max_content_h = math.max(1, height - Screen:scaleBySize(2))
        local time_widget
        local date_widget
        local time_size
        local date_size
        local time_h
        local date_h
        local content_h
        local time_date_overlap = 0
        local top = 0
        local visual_shift = 0
        local resources = {}

        local min_time_px = 4
        local max_time_px = clamp(
            tonumber(module_cfg.max_font_size) or DEFAULT_MAX_TIME_SIZE, 8, MAX_TIME_SIZE)

        local function rebuild_clock_widgets()
            WidgetResources.free(time_widget)
            WidgetResources.free(date_widget)
            time_widget = nil
            date_widget = nil
            resources[1] = nil
            resources[2] = nil

            local time_str = time_text()
            local date_str = DateFormat.formatLongWithWeekday()
            local function make_clock_widgets(time_px, date_px)
                return new_clock_widgets(
                    Screen, time_font_name, date_font_name,
                    time_str, date_str, time_px, date_px, date_gap)
            end

            local best
            local function keep_if_fits(time_px, date_px)
                local tw, dw, ts, ds, th, dh, overlap, ch =
                    make_clock_widgets(time_px, date_px)
                if ch <= max_content_h and (ts.w or 0) <= width and (ds.w or 0) <= width then
                    WidgetResources.free(best and best.tw)
                    WidgetResources.free(best and best.dw)
                    best = {
                        tw = tw, dw = dw, ts = ts, ds = ds,
                        th = th, dh = dh, overlap = overlap, ch = ch,
                    }
                    return true
                end
                WidgetResources.free(tw)
                WidgetResources.free(dw)
                return false
            end

            if automatic_font_size then
                local low, high = min_time_px, max_time_px
                while low <= high do
                    local time_px = math.floor((low + high) / 2)
                    if keep_if_fits(time_px) then
                        low = time_px + 1
                    else
                        high = time_px - 1
                    end
                end
            else
                local time_px = clamp(time_style.font_size, 8, MAX_TIME_SIZE)
                local date_px = clamp(date_style.font_size, 6, 80)
                local scale = 1
                while scale >= 0.25 and not keep_if_fits(
                        math.max(4, math.floor(time_px * scale + 0.5)),
                        math.max(4, math.floor(date_px * scale + 0.5))) do
                    scale = scale - 0.05
                end
            end

            if not best then
                local tw, dw, ts, ds, th, dh, overlap, ch = make_clock_widgets(
                    automatic_font_size and min_time_px or 4,
                    automatic_font_size and nil or 4)
                best = {
                    tw = tw, dw = dw, ts = ts, ds = ds,
                    th = th, dh = dh, overlap = overlap, ch = ch,
                }
            end

            time_widget = best.tw
            date_widget = best.dw
            time_size = best.ts
            date_size = best.ds
            time_h = best.th
            date_h = best.dh
            content_h = best.ch
            time_date_overlap = best.overlap

            resources[1] = time_widget
            resources[2] = date_widget

            local spare_h = math.max(0, height - content_h)
            top = math.floor(spare_h * 0.70)
        end

        rebuild_clock_widgets()
        if type(ctx.setContentBounds) == "function" then
            local date_top = math.min(
                height - date_h,
                top + time_h - time_date_overlap + date_gap
            )
            local visual_top = math.min(top, date_top)
            local visual_bottom = math.max(top + time_h, date_top + date_h)
            ctx.setContentBounds{
                top = visual_top,
                bottom = visual_bottom,
                min_shift = -visual_top,
                max_shift = height - visual_bottom,
                set_shift = function(shift) visual_shift = shift end,
            }
        end

        local content = WidgetResources.managedPaintWidget{
            dimen = Geom:new{ w = width, h = height },
            resources = resources,
            paintTo = function(_self, bb, x, y)
                local time_x = x + math.floor((width - (time_size.w or 0)) / 2)
                local date_x = x + math.floor((width - (date_size.w or 0)) / 2)
                local time_y = y + top + visual_shift
                local date_y = math.min(
                    y + height - date_h,
                    y + top + time_h - time_date_overlap + date_gap
                ) + visual_shift
                time_widget:paintTo(bb, time_x, time_y)
                date_widget:paintTo(bb, date_x, date_y)
            end,
            free = function()
                time_widget = nil
                date_widget = nil
            end,
        }

        local frame = FrameContainer:new{
            width = width,
            height = height,
            padding = 0,
            bordersize = 0,
            background = Background.tile_bg(Blitbuffer.COLOR_WHITE),
            content,
        }
        if type(ctx.registerClockRefresh) == "function" then
            ctx.registerClockRefresh(function()
                rebuild_clock_widgets()
                return true
            end, frame, { "time", "date" })
        end
        return frame
    end,
}
