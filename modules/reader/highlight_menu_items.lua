local _ = require("gettext")
local M = {}

M.order = { "style", "color", "note", "start_prev", "start_next", "end_prev", "end_next", "delete", "more" }
local UPSTREAM_ORDER = { "delete", "style", "color", "note", "details", "more",
    "start_prev", "start_next", "end_prev", "end_next" }

function M.labels()
    return {
        delete = _("Delete"), style = _("Style"), color = _("Color"),
        note = _("Note"), more = _("More"),
        start_prev = _("Extend start"), start_next = _("Contract start"),
        end_prev = _("Contract end"), end_next = _("Extend end"),
    }
end

function M.getOrder(settings)
    local order, seen, known, legacy = {}, {}, {}, false
    for _i, id in ipairs(M.order) do known[id] = true end
    for _i, id in ipairs(settings.submenu_order or {}) do
        if id == "details" then legacy = true end
        if known[id] and not seen[id] then
            order[#order + 1], seen[id] = id, true
        end
    end
    for _i, id in ipairs(M.order) do
        if not seen[id] then order[#order + 1] = id end
    end
    if legacy then
        for i = #order, 1, -1 do
            if order[i] == "delete" or order[i] == "more" then table.remove(order, i) end
        end
        order[#order + 1], order[#order + 2] = "delete", "more"
    end
    return order
end

function M.isEnabled(settings, id, handles_available)
    local enabled = settings.submenu_enabled or {}
    if id:find("_", 1, true) and handles_available == false then return true end
    if enabled[id] ~= nil then return enabled[id] == true end
    return not id:find("_", 1, true)
end

function M.arrange(buttons, settings, handles_available, icons)
    local by_id, index = {}, 0
    for _i, row in ipairs(buttons) do
        for _j, button in ipairs(row) do
            index = index + 1
            local id = UPSTREAM_ORDER[index]
            if not id then return buttons end
            button.id = "zen_highlight_" .. id
            by_id[id] = button
        end
    end
    -- Leave unfamiliar upstream layouts intact.
    if index ~= #UPSTREAM_ORDER then return buttons end
    local rows = {}
    local labels = settings.show_labels and M.labels()
    for _i, id in ipairs(M.getOrder(settings)) do
        if M.isEnabled(settings, id, handles_available) then
            if #rows == 0 or #rows[#rows] == 6 then rows[#rows + 1] = {} end
            if icons and icons[id] then
                by_id[id].icon = icons[id]
                by_id[id].text = labels and labels[id] or nil
            end
            table.insert(rows[#rows], by_id[id])
        end
    end
    return rows
end

function M.compact(buttons)
    local Screen = require("device").screen
    for _i, row in ipairs(buttons) do
        for _j, button in ipairs(row) do
            if button.icon then
                button.height = Screen:scaleBySize(button.text and 28 or 32)
                if not button.text then button.icon_width, button.icon_height = button.height, button.height end
            end
        end
    end
end

return M
