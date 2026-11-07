return function()
    local BD = require("ui/bidi")
    local Geom = require("ui/geometry")
    local Pill = require("common/ui/pill")
    local VerticalScrollBar = require("ui/widget/verticalscrollbar")
    local HorizontalScrollBar = require("ui/widget/horizontalscrollbar")

    local function paint(self, bb, x, y, vertical)
        if not self.enable then return end
        local extra = self.extra_touch_on_side
        self.touch_dimen = Geom:new{
            x = x - (vertical and extra or 0),
            y = y - (vertical and 0 or extra),
            w = self.width + (vertical and 2 * extra or 0),
            h = self.height + (vertical and 0 or 2 * extra),
        }
        local border = self.bordersize
        if border > 0 then
            bb:paintBorder(x, y, self.width, self.height, border,
                self.bordercolor, Pill.radius(self.width, self.height))
        end
        local w, h = self.width - 2 * border, self.height - 2 * border
        if w <= 0 or h <= 0 then return end
        local length = vertical and h or w
        local thumb = math.min(length, math.max(self.min_thumb_size,
            math.ceil(length * (self.high - self.low))))
        local low = not vertical and BD.mirroredUILayout() and (1 - self.high) or self.low
        local offset = math.floor(math.min(length - thumb, length * low))
        Pill.paint(bb, x + border + (vertical and 0 or offset),
            y + border + (vertical and offset or 0),
            vertical and w or thumb, vertical and thumb or h, self.rectcolor)
    end

    function VerticalScrollBar:paintTo(bb, x, y)
        paint(self, bb, x, y, true)
    end

    function HorizontalScrollBar:paintTo(bb, x, y)
        paint(self, bb, x, y, false)
    end
end
