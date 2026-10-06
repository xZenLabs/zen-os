local sort_key = require("common/sort_key")
local M = {}

local HTML_SPACES = {
    ["&nbsp;"] = " ",
    ["&#32;"] = " ",
    ["&#x20;"] = " ",
    ["&#X20;"] = " ",
}

local VALID = {
    authors = true,
    authors_last = true,
}

function M.normalize(mode)
    return VALID[mode] and mode or "authors"
end

function M.isMode(mode)
    return VALID[mode] == true
end

function M.key(name, mode)
    local text = tostring(name or ""):gsub("&[#%w]+;", HTML_SPACES)
    text = (text:match("^[^\r\n]+") or text):match("^%s*(.-)%s*$")
    local sort_text = text:gsub("%s+%b()$", "")
    local surname, given = sort_text:match("^(.-),%s*(.+)$")
    if mode == "authors_last" then
        if surname then return surname:match("^%s*(.-)%s*$") end
        -- ponytail: Assume one given name; use "Surname, Given names" for ambiguous names.
        return sort_text:match("^%S+%s+(.+)$") or sort_text
    end
    if given then sort_text = given end
    return sort_text:match("^([^%s,]+)") or sort_text
end

function M.less(a, b, mode)
    local ak = sort_key(M.key(a, mode))
    local bk = sort_key(M.key(b, mode))
    if ak ~= bk then return ak < bk end
    return sort_key(a) < sort_key(b)
end

function M.options(gettext)
    return {
        { key = "authors", text = gettext("First name") },
        { key = "authors_last", text = gettext("Last name") },
    }
end

function M.modeButtons(mode, gettext, on_select)
    mode = M.normalize(mode)
    local buttons = {}
    for _i, option in ipairs(M.options(gettext)) do
        local key = option.key
        local active = mode == key
        buttons[#buttons + 1] = {{
            text = "\u{F04BB}  " .. option.text .. (active and "  \u{2713}" or ""),
            align = "left",
            enabled = not active,
            callback = function() on_select(key) end,
        }}
    end
    return buttons
end

return M
