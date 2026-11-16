local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local SolidCircle = WidgetContainer:extend{}

function SolidCircle:init()
    self.width = self.width or self.height
    self.height = self.height or self.width
    self.bordersize = self.bordersize or 0
    self.radius = self.radius or math.floor(math.min(self.width, self.height) / 2)
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function SolidCircle:getSize()
    return self.dimen
end

function SolidCircle:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y

    if self.background then
        local radius = self.radius + (self.bordersize > 0 and self.bordersize or 0)
        local paint = Blitbuffer.isColor8(self.background)
            and bb.paintRoundedRect or bb.paintRoundedRectRGB32
        require("common/ui/raw_paint").run(bb, paint, bb, x, y, self.width, self.height, self.background, radius)
    end
    if self.bordersize > 0 then
        bb:paintBorder(x, y, self.width, self.height,
            self.bordersize, Blitbuffer.COLOR_BLACK, self.radius, false)
    end
    if self[1] then
        self[1]:paintTo(bb, x + self.bordersize, y + self.bordersize)
    end
    if self.invert then
        bb:invertRect(x + self.bordersize, y + self.bordersize,
            self.width - self.bordersize * 2, self.height - self.bordersize * 2)
    end
end

return SolidCircle
