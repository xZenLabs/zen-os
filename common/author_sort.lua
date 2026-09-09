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
    local text = tostring(name or ""):gsub("&[#%w]+;", HTML_SPACES):match("^%s*(.-)%s*$")
    local sort_text = text:gsub("%s+%b()$", "")
    if mode == "authors_last" then
        -- ponytail: Last-token heuristic; structured metadata is needed for compound surnames.
        return sort_text:match("(%S+)$") or sort_text
    end
    return sort_text:match("^([^%s,]+)") or sort_text
end

function M.less(a, b, mode)
    local ak = M.key(a, mode):lower()
    local bk = M.key(b, mode):lower()
    if ak ~= bk then return ak < bk end
    return tostring(a or ""):lower() < tostring(b or ""):lower()
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
