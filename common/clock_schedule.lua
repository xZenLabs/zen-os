local M = {}

-- 61 - sec matches KOReader's footer timer so minute ticks share one wakeup.
function M.nextMinuteDelay(time_table)
    local second = type(time_table) == "table" and tonumber(time_table.sec) or 0
    second = second or 0
    local delay = 61 - second
    if delay < 1 or delay > 61 then return 61 end
    return delay
end

return M
