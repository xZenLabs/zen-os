-- Paints rounded RGB32 frame backgrounds raw so their corners match the fill on Android at night.
return function()
    local Blitbuffer = require("ffi/blitbuffer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local RawPaint = require("common/ui/raw_paint")
    local paint = FrameContainer.paintTo

    function FrameContainer:paintTo(bb, x, y)
        local background, radius = self.background, self.radius or 0
        if not background or radius == 0 or Blitbuffer.isColor8(background) or not RawPaint.needed(bb) then
            return paint(self, bb, x, y)
        end
        local size = self:getSize()
        RawPaint.run(bb, bb.paintRoundedRectRGB32, bb, x, y, self.width or size.w, self.height or size.h,
            background, radius + (self.bordersize or 0))
        self.background = nil
        local ok, err = pcall(paint, self, bb, x, y)
        self.background = background
        if not ok then error(err, 0) end
    end
end
