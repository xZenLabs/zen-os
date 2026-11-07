local Blitbuffer = require("ffi/blitbuffer")
local ButtonLabels = require("common/ui/button_labels")
local Button = require("ui/widget/button")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local Screen = require("device").screen
local VerticalGroup = require("ui/widget/verticalgroup")

local M = {}

function M.new(actions, width)
    if #actions == 0 then return end
    local inset = Screen:scaleBySize(12)
    local line_w = Screen:scaleBySize(1)
    local cell_w = math.floor((width - inset * 2 - line_w * (#actions - 1)) / #actions)
    local row = HorizontalGroup:new{ align = "center", allow_mirroring = false }
    row.buttons = {}
    row[#row + 1] = HorizontalSpan:new{ width = inset }
    for _i, action in ipairs(actions) do
        if _i > 1 then
            row[#row + 1] = LineWidget:new{ dimen = Geom:new{ w = line_w, h = Screen:scaleBySize(24) },
                background = Blitbuffer.COLOR_LIGHT_GRAY }
        end
        local button = Button:new{
            text = action.text, callback = action.callback, width = cell_w,
            height = Screen:scaleBySize(40), padding_h = Screen:scaleBySize(4), padding_v = 0,
            bordersize = 0, margin = 0, text_font_size = 16, text_font_bold = false,
        }
        ButtonLabels.applyButton(button, action)
        button._zen_focus_id = "reference:" .. action.id
        row.buttons[#row.buttons + 1] = button
        row[#row + 1] = button
    end
    row[#row + 1] = HorizontalSpan:new{ width = width - inset - cell_w * #actions - line_w * (#actions - 1) }
    return VerticalGroup:new{ align = "left", buttons = row.buttons,
        LineWidget:new{ dimen = Geom:new{ w = width, h = line_w }, background = Blitbuffer.COLOR_LIGHT_GRAY },
        row,
    }
end

return M
