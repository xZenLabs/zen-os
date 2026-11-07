local M = {}

function M.radius(w, h)
    return math.floor(math.min(w, h) / 2)
end

function M.paint(bb, x, y, w, h, color)
    if w <= 0 or h <= 0 then return end
    bb:paintRoundedRect(x, y, w, h, color, M.radius(w, h))
end

return M
