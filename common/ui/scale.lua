-- Font:getFace applies Screen:scaleBySize itself: never hand it device pixels.
local M = {}

-- scaleBySize factor of the 1264 px panels the layouts were tuned on; specs use 1.
M.REFERENCE = 1264 / 600

function M.factor()
    return require("device").screen:scaleBySize(1000) / 1000
end

--- getFace size for a size tuned as scaleBySize(n) on the reference screen.
function M.font(n)
    return math.max(1, math.ceil(n * M.REFERENCE))
end

--- getFace size rendering at `px` device pixels; floored so getFace's ceil lands on px.
function M.fontFromPx(px)
    return math.floor(px / M.factor() * 100) / 100
end

--- getFace size for a pixel-derived size tuned unconverted on the reference screen.
function M.fontFromTunedPx(px)
    return math.max(1, math.floor(px * M.REFERENCE / M.factor() + 0.5))
end

--- Device pixels for a pixel count tuned on the reference screen.
function M.px(n)
    return math.max(1, math.floor(n * M.factor() / M.REFERENCE + 0.5))
end

return M
