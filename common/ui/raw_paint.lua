-- Android's C blitter ignores the night invert flag (the frame is inverted at flip), while Lua
-- setPixel paths such as RGB32 rounded corners honor it and end up double-inverted.
local M = {}

function M.needed(bb)
    return bb.canUseCbb and bb:getInverse() == 1 and bb:canUseCbb() or false
end

-- Runs fn with the flag cleared so both paths store raw pixels.
function M.run(bb, fn, ...)
    if not M.needed(bb) then return fn(...) end
    bb:setInverse(0)
    local ok, err = pcall(fn, ...)
    bb:setInverse(1)
    if not ok then error(err, 0) end
end

return M
