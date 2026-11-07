-- Reader controls "Book info" card fields, stored in config.reader_controls.book_info.
local _ = require("gettext")

local M = {}

M.ORDER = { "read_time", "time_remaining", "pages_today", "time_today", "pages", "progress" }
M.DEFAULT_ENABLED = {
    read_time = true,
    time_remaining = true,
    pages_today = false,
    time_today = false,
    pages = true,
    progress = true,
}

local VALID = {}
for _i, id in ipairs(M.ORDER) do VALID[id] = true end

function M.normalize(info)
    info = type(info) == "table" and info or {}
    local order, seen = {}, {}
    for _i, id in ipairs(type(info.order) == "table" and info.order or {}) do
        if VALID[id] and not seen[id] then
            order[#order + 1] = id
            seen[id] = true
        end
    end
    for _i, id in ipairs(M.ORDER) do
        if not seen[id] then order[#order + 1] = id end
    end
    local saved = type(info.enabled) == "table" and info.enabled or {}
    local enabled = {}
    for _i, id in ipairs(M.ORDER) do
        if type(saved[id]) == "boolean" then enabled[id] = saved[id]
        else enabled[id] = M.DEFAULT_ENABLED[id] end
    end
    info.order, info.enabled = order, enabled
    return info
end

function M.ensure(config)
    config.reader_controls = type(config.reader_controls) == "table" and config.reader_controls or {}
    config.reader_controls.book_info = M.normalize(config.reader_controls.book_info)
    return config.reader_controls.book_info
end

function M.settingsItem(config, save)
    local labels = {
        read_time = _("Read time"),
        time_remaining = _("Time remaining"),
        pages_today = _("Pages today"),
        time_today = _("Time today"),
        pages = _("Pages"),
        progress = _("Progress bar"),
    }
    return {
        text = _("Book info") .. " \u{25B8}",
        icon_glyph = require("common/inline_icon_map").details,
        keep_menu_open = true,
        callback = function()
            local info = M.ensure(config)
            local sort_items = {}
            for _i, id in ipairs(info.order) do
                sort_items[#sort_items + 1] = {
                    text = labels[id],
                    orig_item = id,
                    checked_func = function() return info.enabled[id] end,
                    callback = function()
                        info.enabled[id] = not info.enabled[id]
                        save()
                    end,
                }
            end
            require("common/ui/zen_arrange_list").show{
                title = _("Book info"),
                item_table = sort_items,
                callback = function()
                    local order = {}
                    for _i, item in ipairs(sort_items) do order[#order + 1] = item.orig_item end
                    info.order = order
                    save()
                end,
            }
        end,
    }
end

return M
