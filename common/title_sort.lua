-- Natural comparison adapted from natord-plus-lua.
-- LICENSE: https://github.com/tachibana-shin/natord-plus-lua
local function is_digit(code)
    return code and code >= 48 and code <= 57
end

local function is_space(code)
    return code and (code == 32 or code == 9 or code == 13 or code == 10)
end

local function compare_left(a, b, ai, bi)
    while true do
        local ca = a:byte(ai)
        local cb = b:byte(bi)
        local da = is_digit(ca)
        local db = is_digit(cb)

        if not da and not db then return 0, ai, bi end
        if not da then return -1, ai, bi end
        if not db then return 1, ai, bi end
        if ca < cb then return -1, ai, bi end
        if ca > cb then return 1, ai, bi end

        ai = ai + 1
        bi = bi + 1
    end
end

local function compare_right(a, b, ai, bi)
    local bias = 0
    while true do
        local ca = a:byte(ai)
        local cb = b:byte(bi)
        local da = is_digit(ca)
        local db = is_digit(cb)

        if not da and not db then return bias, ai, bi end
        if not da then return -1, ai, bi end
        if not db then return 1, ai, bi end
        if ca < cb and bias == 0 then
            bias = -1
        elseif ca > cb and bias == 0 then
            bias = 1
        end

        ai = ai + 1
        bi = bi + 1
    end
end

local function natural_compare(a, b)
    local ai, bi = 1, 1
    local after_digit = false

    while true do
        local ca = a:byte(ai)
        local cb = b:byte(bi)

        while ai <= #a and is_space(ca) do
            ai = ai + 1
            ca = a:byte(ai)
        end
        while bi <= #b and is_space(cb) do
            bi = bi + 1
            cb = b:byte(bi)
        end

        if is_digit(ca) and is_digit(cb) then
            local result
            if ca == 48 or cb == 48 then
                result, ai, bi = compare_left(a, b, ai, bi)
            else
                result, ai, bi = compare_right(a, b, ai, bi)
            end
            if result ~= 0 then return result end
            after_digit = true
        else
            if not ca and not cb then return 0 end
            if not ca then return -1 end
            if not cb then return 1 end

            if after_digit then
                if ca == 46 and cb ~= 46 and is_digit(a:byte(ai + 1)) then
                    return 1
                elseif cb == 46 and ca ~= 46 and is_digit(b:byte(bi + 1)) then
                    return -1
                end
            end

            if ca >= 65 and ca <= 90 then ca = ca + 32 end
            if cb >= 65 and cb <= 90 then cb = cb + 32 end
            if ca < cb then return -1 end
            if ca > cb then return 1 end

            ai = ai + 1
            bi = bi + 1
            after_digit = false
        end
    end
end

local M = {}

local ARTICLES = {
    en = { a = true, an = true, the = true },
    es = { el = true, la = true, los = true, las = true,
        un = true, una = true, unos = true, unas = true },
    fr = { le = true, la = true, les = true, un = true, une = true, des = true },
    it = { il = true, lo = true, la = true, i = true, gli = true, le = true,
        un = true, uno = true, una = true, dei = true, degli = true, delle = true },
    nl = { de = true, het = true, een = true },
    pt = { o = true, a = true, os = true, as = true,
        um = true, uma = true, uns = true, umas = true },
    ro = { un = true, o = true, ["niște"] = true, ["nişte"] = true },
}

local function current_language()
    local settings = rawget(_G, "G_reader_settings")
    local language = settings and settings.readSetting
        and settings:readSetting("language") or "en"
    return tostring(language):lower():match("^([a-z]+)") or "en"
end

function M.key(title)
    local text = tostring(title or ""):gsub("^%s+", "")
    local language = current_language()
    local localized = ARTICLES[language]
    local first, rest = text:match("^(%S+)%s+(.+)$")
    first = first and first:lower()
    if first and rest and (ARTICLES.en[first] or localized and localized[first]) then
        return rest:gsub("^%s+", "")
    end
    if language == "fr" or language == "it" then
        rest = text:match("^[Ll]'(.+)$") or text:match("^[Ll]’(.+)$")
        if rest then return rest:gsub("^%s+", "") end
    end
    return text
end

function M.less(first, second, natural)
    first = tostring(first or "")
    second = tostring(second or "")
    local first_key = M.key(first)
    local second_key = M.key(second)
    if natural then
        local result = natural_compare(first_key, second_key)
        if result == 0 then result = natural_compare(first, second) end
        return result < 0
    end
    first_key, second_key = first_key:lower(), second_key:lower()
    if first_key ~= second_key then return first_key < second_key end
    return first:lower() < second:lower()
end

return M
