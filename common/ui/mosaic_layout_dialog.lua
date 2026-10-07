local _ = require("gettext")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ZenSlider = require("common/ui/zen_slider")
local Screen = Device.screen

local Preview = WidgetContainer:extend{}

function Preview:paintTo(bb, x, y)
    local w, h = self.dimen.w, self.dimen.h
    local gap = math.max(2, Screen:scaleBySize(4))
    bb:paintRect(x, y, w, h, Blitbuffer.COLOR_WHITE)
    bb:paintBorder(x, y, w, h, 1, Blitbuffer.COLOR_BLACK)
    local cell_w = (w - 2 * gap) / self.columns
    local cell_h = (h - 2 * gap) / self.rows
    local cover_h = math.min(cell_h - gap, (cell_w - gap) / self.ratio)
    local cover_w = cover_h * self.ratio
    for row = 1, self.rows do
        for col = 1, self.columns do
            local cx = math.floor(x + gap + (col - 1) * cell_w + (cell_w - cover_w) / 2)
            local cy = math.floor(y + gap + (row - 1) * cell_h + (cell_h - cover_h) / 2)
            bb:paintRect(cx, cy, math.floor(cover_w), math.floor(cover_h), Blitbuffer.COLOR_LIGHT_GRAY)
            bb:paintBorder(cx, cy, math.floor(cover_w), math.floor(cover_h), 1, Blitbuffer.COLOR_DARK_GRAY)
        end
    end
end

local M = {}

function M.new(options)
    local dialog, preview
    local sliders, labels = {}, {}
    local function update(id, value)
        sliders[id]:setValue(value)
        labels[id]:setText((id == "columns" and _("Columns") or _("Rows")) .. ": " .. sliders[id]:getValue())
        preview[id] = sliders[id]:getValue()
        UIManager:setDirty(dialog, "ui")
    end
    dialog = ButtonDialog:new{
        title = options.title,
        buttons = {
            {
                { text = _("Cancel"), callback = function() dialog:onClose() end },
                { text = _("Accept"), callback = function()
                    options.callback(sliders.columns:getValue(), sliders.rows:getValue())
                    dialog:onClose()
                end },
            },
        },
    }
    local width = dialog:getAddedWidgetAvailableWidth()
    local short = math.min(Screen:getWidth(), Screen:getHeight())
    local long = math.max(Screen:getWidth(), Screen:getHeight())
    local page_ratio = options.portrait and short / long or long / short
    local preview_h = math.min(math.floor(Screen:getHeight() * 0.2), math.floor(width / page_ratio))
    preview = Preview:new{
        dimen = Geom:new{ w = math.floor(preview_h * page_ratio), h = preview_h },
        ratio = require("common/cover_utils").getRatio(),
        columns = options.columns,
        rows = options.rows,
    }
    local content = VerticalGroup:new{ align = "center", not_focusable = true, parent = dialog }
    table.insert(content, CenterContainer:new{ dimen = Geom:new{ w = width, h = preview_h }, preview })
    for _i, id in ipairs({ "columns", "rows" }) do
        labels[id] = TextWidget:new{ text = "", face = Font:getFace("cfont", 20) }
        local slider = ZenSlider:new{
            width = width, value = options[id], value_min = 2, value_max = 8,
            on_change = function(value) update(id, value) end,
        }
        sliders[id] = slider
        local paint = slider.paintTo
        function slider:paintTo(bb, x, y)
            paint(self, bb, x, y)
            for value = self.value_min, self.value_max do
                bb:paintRect(math.floor(x + self:_valueToX(value)), y + self.height - 3,
                    1, 3, Blitbuffer.COLOR_DARK_GRAY)
            end
        end
        update(id, options[id])
        table.insert(content, VerticalSpan:new{ width = Screen:scaleBySize(8) })
        table.insert(content, labels[id])
        table.insert(content, slider)
    end
    dialog:addWidget(content)
    dialog.movable.ges_events = {} -- Slider drags must reach the dialog.
    dialog._sliders = sliders
    dialog._preview = preview
    local full = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    for _i, event in ipairs({ "pan", "pan_release", "swipe" }) do
        local name = "Mosaic_" .. event
        dialog.ges_events[name] = { GestureRange:new{ ges = event, range = full } }
        dialog["on" .. name] = function(self, _arg, ges)
            for _k, slider in pairs(sliders) do
                if event == "pan" then
                    if slider:handlePan(ges) then return true end
                elseif event == "pan_release" then
                    if slider:handlePanRelease(ges, self, self.dimen) then return true end
                elseif slider:handleSwipe(ges, self, self.dimen) then
                    return true
                end
            end
            return true
        end
    end
    local original_tap = dialog.onTapClose
    function dialog:onTapClose(arg, ges)
        for _k, slider in pairs(sliders) do
            if slider:handleTap(ges) then return true end
        end
        return original_tap(self, arg, ges)
    end
    return dialog
end

return M
