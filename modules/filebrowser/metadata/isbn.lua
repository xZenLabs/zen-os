local M = {}

function M.normalize(input)
    local isbn = type(input) == "table"
        and (input.isbn_13 or input.isbn_10 or input.isbn) or input
    if type(isbn) ~= "string" then return nil end
    isbn = isbn:gsub("[^%dXx]", ""):upper()
    if isbn:match("^%d%d%d%d%d%d%d%d%d[%dX]$") then
        local sum = 0
        for index = 1, 10 do
            local character = isbn:sub(index, index)
            local digit = character == "X" and 10 or tonumber(character)
            sum = sum + digit * (11 - index)
        end
        if sum % 11 == 0 then return isbn end
    elseif isbn:match("^%d%d%d%d%d%d%d%d%d%d%d%d%d$") then
        local sum = 0
        for index = 1, 12 do
            local weight = index % 2 == 0 and 3 or 1
            sum = sum + tonumber(isbn:sub(index, index)) * weight
        end
        if (10 - sum % 10) % 10 == tonumber(isbn:sub(13, 13)) then return isbn end
    end
end

return M
