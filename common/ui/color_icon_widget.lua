local Blitbuffer = require("ffi/blitbuffer")
local IconWidget = require("ui/widget/iconwidget")

local ColorIconWidget = IconWidget:extend{ fgcolor = Blitbuffer.COLOR_BLACK }

function ColorIconWidget:paintTo(bb, x, y)
    if not self._mask then
        local size = self:getSize()
        self._mask = Blitbuffer.new(size.w, size.h, Blitbuffer.TYPE_BB8)
        self._mask:fill(Blitbuffer.COLOR_WHITE)
        IconWidget.paintTo(self, self._mask, 0, 0)
        self._mask:invertRect(0, 0, size.w, size.h)
    end
    self.dimen.x, self.dimen.y = x, y
    bb:colorblitFromRGB32(self._mask, x, y, 0, 0, self._mask:getWidth(), self._mask:getHeight(), self.fgcolor)
end

function ColorIconWidget:free()
    if self._mask then self._mask:free(); self._mask = nil end
    return IconWidget.free(self)
end

return ColorIconWidget
