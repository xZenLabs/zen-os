local Background = require("common/ui/background")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local TextWidget = require("ui/widget/textwidget")
local IconWidget = require("ui/widget/iconwidget")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local Device = require("device")
local Font = require("ui/font")
local utils = require("common/utils")
local WidgetResources = require("common/widget_resources")
local _ = require("gettext")

local _icons_dir
do
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then
        local root = src:sub(2):match("^(.*)/modules/")
        if root then _icons_dir = root .. "/icons/" end
    end
end

local flame_icon_path = _icons_dir and utils.resolveLocalIcon(_icons_dir, "flame") or nil
local MIN_FONT_SIZE = 8
local MAX_FONT_SIZE = 64
local DEFAULT_FONT_SIZE = 16
local DEFAULT_MAX_FONT_SIZE = 18

local function time_unit(unit)
    if type(_) == "table" and type(_.pgettext) == "function" then
        return _.pgettext("Time", unit)
    end
    return _(unit)
end

local function fmt_time(secs)
    secs = math.floor(secs or 0)
    if secs <= 0 then return "0" .. time_unit("m") end
    local h = math.floor(secs / 3600)
    local m = math.floor((secs % 3600) / 60)
    if h > 0 then
        return h .. time_unit("h") .. " " .. m .. time_unit("m")
    end
    return m .. time_unit("m")
end

local FIELD_MAP = {
    today_pages = { id = "today_pages", label = _("Pages today"), get = function(s) return tostring(s.today_pages or 0) end },
    today_duration = { id = "today_duration", label = _("Read today"), get = function(s) return fmt_time(s.today_duration or 0) end },
    streak = { id = "streak", label = _("Day streak"), get = function(s) return tostring(s.streak or 0) end },
    week_pages = { id = "week_pages", label = _("Pages this week"), get = function(s) return tostring(s.week_pages or 0) end },
    week_duration = { id = "week_duration", label = _("Time this week"), get = function(s) return fmt_time(s.week_duration or 0) end },
}

local function metric_content(width, height, value_widget, label_widget, shift_state)
    local value_size = value_widget:getSize()
    local label_size = label_widget:getSize()
    local value_h = value_size.h or 1
    local label_h = label_size.h or 1
    local overlap = math.floor(value_h * 0.18)
    local gap = 1
    local content_h = value_h - overlap + gap + label_h
    local top = math.floor(math.max(0, height - content_h) / 2)

    local content = WidgetResources.managedPaintWidget{
        dimen = Geom:new{ w = width, h = height },
        resources = { value_widget, label_widget },
        paintTo = function(_self, bb, x, y)
            local value_x = x + math.floor((width - (value_size.w or 0)) / 2)
            local value_y = y + top + shift_state.value
            local label_x = x + math.floor((width - (label_size.w or 0)) / 2)
            local label_y = value_y + value_h - overlap + gap
            value_widget:paintTo(bb, value_x, value_y)
            label_widget:paintTo(bb, label_x, label_y)
        end,
        free = function()
            value_widget = nil
            label_widget = nil
        end,
    }
    return content, top, content_h
end

local function configured_font_size(ctx)
    local module_cfg = type(ctx.module_cfg) == "table" and ctx.module_cfg or {}
    return math.max(MIN_FONT_SIZE, math.min(MAX_FONT_SIZE,
        tonumber(module_cfg.font_size) or DEFAULT_FONT_SIZE))
end

local function configured_max_font_size(ctx)
    local module_cfg = type(ctx.module_cfg) == "table" and ctx.module_cfg or {}
    return math.max(MIN_FONT_SIZE, math.min(MAX_FONT_SIZE,
        tonumber(module_cfg.max_font_size) or DEFAULT_MAX_FONT_SIZE))
end

local function font_size_fits(candidate, fields, stats, inner_w, inner_h)
    local Screen = Device.screen
    local value_face = Font:getFace("smallinfofont", Screen:scaleBySize(candidate))
    local label_face = Font:getFace("smallinfofont", Screen:scaleBySize(
        math.max(6, math.floor(candidate * 0.6))))
    for _i, field in ipairs(fields) do
        local value_probe = TextWidget:new{
            text = field.get(stats),
            face = value_face,
            bold = true,
        }
        local label_probe = TextWidget:new{ text = field.label, face = label_face }
        local value_size = value_probe:getSize()
        local label_size = label_probe:getSize()
        local value_w = value_size.w or 0
        local value_h = value_size.h or 1
        if field.id == "streak" and flame_icon_path then
            value_w = value_w + math.max(8, math.floor(value_h * 0.62)) + 3
        end
        local content_h = value_h - math.floor(value_h * 0.18)
            + 1 + (label_size.h or 1)
        local fits = value_w <= inner_w and (label_size.w or 0) <= inner_w
            and content_h <= inner_h
        WidgetResources.free(value_probe)
        WidgetResources.free(label_probe)
        if not fits then return false end
    end
    return true
end

local function fitting_font_size(fields, stats, inner_w, inner_h, max_font_size)
    local low, high = MIN_FONT_SIZE, max_font_size
    local best = MIN_FONT_SIZE
    while low <= high do
        local candidate = math.floor((low + high) / 2)
        if font_size_fits(candidate, fields, stats, inner_w, inner_h) then
            best = candidate
            low = candidate + 1
        else
            high = candidate - 1
        end
    end
    return best
end

local function preferred_height(ctx)
    ctx = type(ctx) == "table" and ctx or {}
    local Screen = Device.screen
    local module_cfg = type(ctx.module_cfg) == "table" and ctx.module_cfg or {}
    local font_size = module_cfg.automatic_font_size ~= false
        and configured_max_font_size(ctx) or configured_font_size(ctx)
    local value_probe = TextWidget:new{
        text = "A",
        face = Font:getFace("smallinfofont", Screen:scaleBySize(font_size)),
        bold = true,
    }
    local label_probe = TextWidget:new{
        text = "A",
        face = Font:getFace("smallinfofont", Screen:scaleBySize(
            math.max(6, math.floor(font_size * 0.6)))),
    }
    local value_h = value_probe:getSize().h or 1
    local label_h = label_probe:getSize().h or 1
    WidgetResources.free(value_probe)
    WidgetResources.free(label_probe)
    local content_h = value_h - math.floor(value_h * 0.18) + 1 + label_h
    local border_size = ctx.module_cfg and ctx.module_cfg.stat_style == "outline" and 2 or 0
    return math.max(20, content_h + 12 + border_size * 2)
end

-- Blank space above and below the reported content box at the preferred
-- height (content_h + 12): the centered metrics leave 6 px on each side; the
-- outline style reports the whole card.
local function preferred_insets(ctx)
    local module_cfg = type(ctx) == "table" and type(ctx.module_cfg) == "table"
        and ctx.module_cfg or {}
    if module_cfg.stat_style == "outline" then return 0, 0 end
    return 6, 6
end

return {
    id = "stats_triplet",
    label = _("Reading stats"),
    size = "xs",
    preferredHeight = preferred_height,
    preferredInsets = preferred_insets,
    build = function(ctx)
        local outer_width = ctx.width
        local height = ctx.height
        local stats = ctx.data.stats or {}
        local module_cfg = ctx.module_cfg or {}
        local stat_style = module_cfg.stat_style == "outline" and "outline"
            or module_cfg.stat_style == "none" and "none"
            or "divider"
        local horizontal_padding = stat_style == "outline"
            and Device.screen:scaleBySize(8) or 0
        local width = math.max(1, outer_width - horizontal_padding * 2)

        local config = ctx.config.middle_stats_triplet or { "today_pages", "today_duration", "streak" }
        local fields = {}
        for _i, fid in ipairs(config) do
            local entry = FIELD_MAP[fid] or FIELD_MAP.today_pages
            table.insert(fields, entry)
            if #fields >= 3 then break end
        end
        while #fields < 3 do
            table.insert(fields, FIELD_MAP.today_pages)
        end

        local gap_w = stat_style == "outline" and math.max(10, math.floor(width * 0.045))
            or stat_style == "divider" and 8
            or 6
        local cell_w = math.max(20, math.floor((width - gap_w * 2) / 3))
        local card_h = math.max(20, height)
        local border_size = stat_style == "outline" and 2 or 0
        local inner_w = math.max(1, cell_w - border_size * 2)
        local inner_h = math.max(1, card_h - border_size * 2)
        local Screen = Device.screen
        local shift_state = { value = 0 }
        local font_size = module_cfg.automatic_font_size ~= false
            and fitting_font_size(fields, stats, inner_w, inner_h,
                configured_max_font_size(ctx))
            or configured_font_size(ctx)
        local value_face = Font:getFace("smallinfofont", Screen:scaleBySize(font_size))
        local label_face = Font:getFace("smallinfofont", Screen:scaleBySize(math.max(6, math.floor(font_size * 0.6))))
        local row = HorizontalGroup:new{ align = "center" }
        local visual_top
        local visual_bottom

        for _i, field in ipairs(fields) do
            local value_widget = TextWidget:new{
                text = field.get(stats),
                face = value_face,
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
            }
            if field.id == "streak" and flame_icon_path then
                local value_size = value_widget:getSize()
                local icon_size = math.max(8, math.floor((value_size.h or 12) * 0.62))
                value_widget = HorizontalGroup:new{
                    align = "center",
                    IconWidget:new{
                        file = flame_icon_path,
                        width = icon_size,
                        height = icon_size,
                        alpha = true,
                    },
                    HorizontalSpan:new{ width = 3 },
                    value_widget,
                }
            end
            local content, metric_top, metric_h = metric_content(
                inner_w, inner_h, value_widget,
                TextWidget:new{ text = field.label, face = label_face, fgcolor = Blitbuffer.COLOR_BLACK },
                shift_state)
            visual_top = math.min(visual_top or metric_top, metric_top)
            visual_bottom = math.max(visual_bottom or metric_top + metric_h,
                metric_top + metric_h)
            local card = FrameContainer:new{
                width = cell_w,
                height = card_h,
                padding = 0,
                bordersize = border_size,
                color = Blitbuffer.COLOR_DARK_GRAY,
                radius = stat_style == "outline" and 8 or 0,
                background = Background.tile_bg(Blitbuffer.COLOR_WHITE),
                CenterContainer:new{
                    dimen = Geom:new{ w = inner_w, h = inner_h },
                    content,
                },
            }
            table.insert(row, card)
            if _i < 3 then
                if stat_style == "outline" then
                    table.insert(row, HorizontalSpan:new{ width = gap_w })
                elseif stat_style == "divider" then
                    local divider_trim = math.min(
                        math.max(0, metric_h - 1),
                        math.max(1, Screen:scaleBySize(4))
                    )
                    local divider_h = math.min(card_h, math.max(1, metric_h - divider_trim))
                    local divider_bottom = metric_top + metric_h
                    local divider_top = divider_bottom - divider_h
                    local divider_shift = divider_top - math.floor((card_h - divider_h) / 2)
                    local divider_container = CenterContainer:new{
                        dimen = Geom:new{ w = gap_w, h = card_h },
                        LineWidget:new{
                            dimen = Geom:new{ w = 2, h = divider_h },
                            background = Blitbuffer.COLOR_DARK_GRAY,
                        },
                    }
                    local original_divider_paint = divider_container.paintTo
                    divider_container.paintTo = function(self, bb, x, y)
                        return original_divider_paint(
                            self, bb, x, y + divider_shift + shift_state.value)
                    end
                    table.insert(row, divider_container)
                else
                    table.insert(row, HorizontalSpan:new{ width = gap_w })
                end
            end
        end

        local row_container = CenterContainer:new{
            dimen = Geom:new{ w = outer_width, h = height },
            row,
        }
        if type(ctx.setContentBounds) == "function" then
            local fixed = stat_style == "outline"
            local top = fixed and 0 or visual_top or 0
            local bottom = fixed and height or visual_bottom or height
            ctx.setContentBounds{
                top = top,
                bottom = bottom,
                min_shift = fixed and 0 or -top,
                max_shift = fixed and 0 or height - bottom,
                set_shift = function(shift)
                    if not fixed then shift_state.value = shift end
                end,
            }
        end

        return FrameContainer:new{
            width = outer_width,
            height = height,
            padding = 0,
            bordersize = 0,
            background = Background.tile_bg(Blitbuffer.COLOR_WHITE),
            row_container,
        }
    end,
}
