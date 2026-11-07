local Accent = require("common/ui/accent")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local IconWidget = require("ui/widget/iconwidget")
local LineWidget = require("ui/widget/linewidget")
local Screen = require("device").screen
local TextWidget = require("ui/widget/textwidget")

-- Like ZenToggle, the parent handles input using the exposed cells and callbacks.
local ZenTabBar = FrameContainer:extend{}

function ZenTabBar:init()
    self._night_mode = Screen.night_mode
    self.padding, self.margin = 0, 0
    self.bordersize = Screen:scaleBySize(2)
    self.radius = Screen:scaleBySize(4)
    self.background = Blitbuffer.COLOR_WHITE
    local divider = Screen:scaleBySize(1)
    local pad_h = self.padding_h or Screen:scaleBySize(10)
    local pad_v = self.padding_v or Screen:scaleBySize(6)
    local icon_size = self.icon_size
    if icon_size and self.width then
        icon_size = math.min(icon_size, math.floor((self.width - self.bordersize * 2
            - divider * (#self.items - 1)) / #self.items))
    end
    local labels, width, height = {}, 0, 0
    for i, item in ipairs(self.items) do
        local active = i == self.selected
        local label
        if item.icon then
            label = IconWidget:new{ file = item.icon, width = icon_size, height = icon_size, alpha = true }
            Accent.styleIcon(label, active)
        else
            label = TextWidget:new{ text = item.text, face = Font:getFace("cfont", self.font_size or 18),
                fgcolor = active and Accent.foreground() or Blitbuffer.COLOR_BLACK, padding = 0 }
        end
        labels[i] = label
        local size = label:getSize()
        width, height = math.max(width, size.w), math.max(height, size.h)
    end
    local cell_width = width + pad_h * 2
    if self.max_width then
        cell_width = math.min(cell_width, math.floor((self.max_width - self.bordersize * 2
            - divider * (#labels - 1)) / #labels))
    end
    local inner_width = self.width and self.width - self.bordersize * 2 - divider * (#labels - 1)
    local cell_height = self.cell_height or height + pad_v * 2
    self.cells = {}
    local group = HorizontalGroup:new{ align = "center" }
    for i, item in ipairs(self.items) do
        local active = i == self.selected
        local item_width = inner_width and math.floor(inner_width * i / #labels)
            - math.floor(inner_width * (i - 1) / #labels) or cell_width
        if not item.icon then labels[i]:setMaxWidth(math.max(0, item_width - pad_h * 2)) end
        local cell = FrameContainer:new{
            padding = 0, bordersize = 0, focusable = self.focusable,
            focus_inner_border = true, focus_border_size = Screen:scaleBySize(3),
            focus_border_color = active and Accent.foreground() or Blitbuffer.COLOR_BLACK,
            background = active and Accent.color() or Blitbuffer.COLOR_WHITE,
            text = item.text, callback = item.callback, selected = active,
            CenterContainer:new{ dimen = Geom:new{ w = item_width, h = cell_height }, labels[i] },
        }
        if i > 1 then
            group[#group + 1] = LineWidget:new{ dimen = Geom:new{ w = divider, h = cell_height },
                background = Blitbuffer.COLOR_DARK_GRAY, direction = "vert" }
        end
        group[#group + 1] = cell
        self.cells[i] = cell
    end
    self[1] = group
    require("common/widget_resources").paintFrameBorderOnTop(self)
end

function ZenTabBar:paintTo(bb, x, y)
    if self._night_mode ~= Screen.night_mode then
        self._night_mode = Screen.night_mode
        local cell = self.cells[self.selected]
        if cell then
            cell.background = Accent.color()
            cell.focus_border_color = Accent.foreground()
            local label = cell[1][1]
            if self.items[self.selected].icon then
                label:free()
                Accent.styleIcon(label, true)
            else
                label.fgcolor = cell.focus_border_color
            end
        end
    end
    return FrameContainer.paintTo(self, bb, x, y)
end

return ZenTabBar
