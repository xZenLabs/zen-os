local Blitbuffer = require("ffi/blitbuffer")
local Screen = require("device").screen

local M = {}

function M.paint(bb, x, y, w, h)
    if w > 0 and h > 0 then
        bb:hatchRect(x, y, w, h, math.max(1, Screen:scaleBySize(2)), Blitbuffer.COLOR_BLACK, 0.4)
    end
end

return M
