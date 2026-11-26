local Blitbuffer = require("ffi/blitbuffer")
local Scale = require("common/ui/scale")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")

local Screen = Device.screen

local LineGraph = {}

local function drawLine(bb, x0, y0, x1, y1, thickness, color)
    local dx = math.abs(x1 - x0)
    local dy = math.abs(y1 - y0)
    local steps = math.max(dx, dy, 1)
    local offset = math.floor(thickness / 2)
    for i = 0, steps do
        local t = i / steps
        local x = math.floor(x0 + (x1 - x0) * t + 0.5)
        local y = math.floor(y0 + (y1 - y0) * t + 0.5)
        bb:paintRect(x - offset, y - offset, thickness, thickness, color)
    end
end

local function drawCircle(bb, cx, cy, radius, color)
    for dy = -radius, radius do
        local half_w = math.floor(math.sqrt(math.max(0, radius * radius - dy * dy)) + 0.5)
        bb:paintRect(cx - half_w, cy + dy, half_w * 2 + 1, 1, color)
    end
end

local function paintText(bb, text, face, color, x, y, max_width)
    if not text or text == "" then return end
    local widget = TextWidget:new{
        text = text,
        face = face,
        fgcolor = color,
        max_width = max_width,
    }
    widget:paintTo(bb, x, y)
    widget:free()
end

local function paintAlignedText(bb, text, face, color, x, y, width, align)
    if not text or text == "" then return end
    local widget = TextWidget:new{
        text = text,
        face = face,
        fgcolor = color,
        max_width = width,
    }
    local size = widget:getSize()
    local tx = x
    if align == "right" then
        tx = x + math.max(0, width - size.w)
    elseif align == "center" then
        tx = x + math.floor(math.max(0, width - size.w) / 2)
    end
    widget:paintTo(bb, tx, y)
    widget:free()
end

local function compactNumber(value)
    value = math.floor(tonumber(value) or 0)
    if value >= 1000 then
        local tenths = math.floor(value / 100 + 0.5)
        if tenths % 10 == 0 then
            return tostring(math.floor(tenths / 10)) .. "k"
        end
        return string.format("%d.%dk", math.floor(tenths / 10), tenths % 10)
    end
    return tostring(value)
end

local function graphValues(series, metric, max_value)
    local values = {}
    max_value = max_value or 0
    for _i, point in ipairs(series) do
        local value = metric == "time"
            and math.floor((point.duration or 0) / 60)
            or (point.pages or 0)
        values[#values + 1] = value
        if value > max_value then max_value = value end
    end
    return max_value, values
end

local function axisLeftPadding(axis_face, max_value)
    local label = TextWidget:new{
        text = compactNumber(max_value),
        face = axis_face,
    }
    local label_w = label:getWidth()
    label:free()
    return math.max(Screen:scaleBySize(28), label_w + Screen:scaleBySize(4))
end

function LineGraph:new(opts)
    opts = opts or {}
    local obj = {
        dimen = Geom:new{
            w = opts.width or Screen:scaleBySize(280),
            h = opts.height or Screen:scaleBySize(120),
        },
        series = opts.series or {},
        metric = (opts.metric == "time" or opts.metric == "duration") and "time" or "pages",
        empty_text = opts.empty_text,
        label_left = opts.label_left,
        label_right = opts.label_right,
        x_labels = opts.x_labels,
        max_value = tonumber(opts.max_value) or nil,
        axis_color = opts.axis_color,
        dot_radius = tonumber(opts.dot_radius),
    }
    setmetatable(obj, self)
    self.__index = self
    return obj
end

function LineGraph:getSize()
    return self.dimen
end

function LineGraph:handleEvent()
    return false
end

function LineGraph:getPointIndexAt(x)
    local count = #self.series
    if count == 0 then return nil end
    if count == 1 then return 1 end
    local axis_face = Font:getFace("smallinfofont", Scale.font(9))
    local max_value = graphValues(self.series, self.metric, self.max_value)
    local pad_l = axisLeftPadding(axis_face, max_value)
    local pad_r = Screen:scaleBySize(10)
    local plot_w = math.max(1, self.dimen.w - pad_l - pad_r)
    local ratio = (x - pad_l) / plot_w
    ratio = math.min(1, math.max(0, ratio))
    return math.floor(ratio * (count - 1) + 0.5) + 1
end

function LineGraph:paintTo(bb, x, y)
    local w = self.dimen.w
    local h = self.dimen.h
    local pad_r = Screen:scaleBySize(10)
    local pad_t = Screen:scaleBySize(8)
    local pad_b = Screen:scaleBySize(24)
    local axis_face = Font:getFace("smallinfofont", Scale.font(9))
    local max_value, values = graphValues(self.series, self.metric, self.max_value)
    local pad_l = axisLeftPadding(axis_face, max_value)
    local plot_x = x + pad_l
    local plot_y = y + pad_t
    local plot_w = math.max(1, w - pad_l - pad_r)
    local plot_h = math.max(1, h - pad_t - pad_b)
    local grid = Blitbuffer.COLOR_LIGHT_GRAY
    local fg = Blitbuffer.COLOR_BLACK
    local faint = Blitbuffer.COLOR_DARK_GRAY
    local axis_text = self.axis_color or fg

    bb:paintRect(plot_x, plot_y + plot_h, plot_w, 1, fg)
    bb:paintRect(plot_x, plot_y, 1, plot_h + 1, fg)
    for i = 1, 3 do
        local gy = plot_y + math.floor(plot_h * i / 4)
        bb:paintRect(plot_x, gy, plot_w, 1, grid)
    end

    paintText(bb, compactNumber(max_value), axis_face, axis_text, x, plot_y - 1, pad_l - 2)
    paintText(bb, "0", axis_face, axis_text, x, plot_y + plot_h - Screen:scaleBySize(7), pad_l - 2)

    if max_value <= 0 or #values == 0 then
        paintText(
            bb,
            self.empty_text or "No reading data",
            Font:getFace("infofont", Scale.font(16)),
            faint,
            plot_x + Screen:scaleBySize(8),
            plot_y + math.floor(plot_h / 2) - Screen:scaleBySize(8),
            plot_w - Screen:scaleBySize(16)
        )
    else
        local last_x, last_y
        local count = #values
        local dot_radius = math.max(1, self.dot_radius or Screen:scaleBySize(3))
        for i, value in ipairs(values) do
            local px
            if count == 1 then
                px = plot_x + math.floor(plot_w / 2)
            else
                px = plot_x + math.floor((i - 1) * plot_w / (count - 1))
            end
            local py = plot_y + plot_h - math.floor((value / max_value) * plot_h)
            if last_x then drawLine(bb, last_x, last_y, px, py, Screen:scaleBySize(2), fg) end
            drawCircle(bb, px, py, dot_radius, fg)
            last_x, last_y = px, py
        end
    end

    local date_y = plot_y + plot_h + Screen:scaleBySize(3)
    local labels = self.x_labels
    if type(labels) ~= "table" or #labels == 0 then
        labels = {
            { text = self.label_left, ratio = 0 },
            { text = self.label_right, ratio = 1 },
        }
    end
    local label_w = math.max(Screen:scaleBySize(28), math.floor(plot_w / math.max(#labels, 1)))
    for i, label in ipairs(labels) do
        local ratio = tonumber(label.ratio) or 0
        local lx = plot_x + math.floor(plot_w * ratio + 0.5) - math.floor(label_w / 2)
        local align = "center"
        if i == 1 then
            lx = plot_x
            align = "left"
        elseif i == #labels then
            lx = plot_x + plot_w - label_w
            align = "right"
        end
        paintAlignedText(bb, label.text, axis_face, axis_text, lx, date_y, label_w, align)
    end
end

return LineGraph
