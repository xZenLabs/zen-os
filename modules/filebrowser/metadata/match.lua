-- Ranks provider search results against the searched title and author.
local M = {}

local function fold(value)
    if type(value) ~= "string" then return "" end
    value = value:lower():gsub("'", ""):gsub("’", ""):gsub("[%p%s]+", " ")
    return value:match("^ ?(.-) ?$")
end

-- 3 same title, 2 one extends the other (subtitle, series suffix), 1 one quotes the other.
local function title_tier(found, wanted)
    if found == "" or wanted == "" then return 0 end
    if found == wanted then return 3 end
    local short, long = found, wanted
    if #short > #long then short, long = long, short end
    if long:sub(1, #short + 1) == short .. " " then return 2 end
    return (" " .. long .. " "):find(" " .. short .. " ", 1, true) and 1 or 0
end

-- Word order is ignored: "Collins, Suzanne" matches "Suzanne Collins".
local function has_author(authors, wanted)
    for _i, author in ipairs(type(authors) == "table" and authors or {}) do
        author = " " .. fold(author) .. " "
        local matched = true
        for word in wanted:gmatch("%S+") do
            if not author:find(" " .. word .. " ", 1, true) then
                matched = false
                break
            end
        end
        if matched then return true end
    end
    return false
end

-- Returns the closest work (first wins ties) and whether its title and author both fit.
function M.best(works, query)
    local title, author = fold(query.title), fold(query.author)
    if author == "" and type(query.authors) == "table" then
        author = fold(query.authors[1])
    end
    local best, best_score, confident
    for _i, work in ipairs(works) do
        local tier = title_tier(fold(work.title), title)
        local by_author = author ~= "" and has_author(work.authors, author)
        local score = tier * 2 + (by_author and 3 or 0)
        if not best or score > best_score then
            best, best_score = work, score
            confident = tier >= 2 and (author == "" or by_author)
        end
    end
    return best, confident == true
end

return M
