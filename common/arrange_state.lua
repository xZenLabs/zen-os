-- Pure arrange-list state helpers shared by the widget and its specs.
local M = {}

M.SUBMENU_CARET = " \u{25B8}"

function M.itemOrderKey(item)
    if type(item) ~= "table" then return item end
    local key = item.orig_item
    if key == nil then key = item.orig_entry end
    if type(key) == "table" then
        return key.id or key.key or key.name or key.text or key.label
    end
    return key or item.text
end

function M.hasRearrangedItems(original, current)
    if type(original) ~= "table" or type(current) ~= "table" then return false end
    if #original ~= #current then return true end
    for i, item in ipairs(current) do
        if M.itemOrderKey(item) ~= M.itemOrderKey(original[i]) then return true end
    end
    return false
end

function M.rootTapAction(item, toggle_tap)
    if type(item) ~= "table" then return nil end
    if item.checked_func and toggle_tap then return "toggle" end
    if type(item.sub_item_table) == "table"
            or type(item.sub_item_table_func) == "function" then
        return "submenu"
    end
    if item.callback then return "callback" end
    return "consume"
end

function M.toggleItem(item)
    if type(item) ~= "table" then return false end
    if type(item.checkmark_callback) == "function" then
        item.checkmark_callback()
        return true
    end
    if type(item.callback) == "function" then
        item:callback()
        return true
    end
    return false
end

function M.confirmKeyName(key)
    for _i, name in ipairs({ "Press", "Return" }) do
        if key == name then return name end
        if type(key) == "table" and type(key.match) == "function"
                and key:match({ name }) then
            return name
        end
    end
end

function M.dragTargetIndex(show_page, items_per_page, item_count, top, row_height, y)
    if type(show_page) ~= "number" or type(items_per_page) ~= "number"
            or type(item_count) ~= "number" or type(top) ~= "number"
            or type(row_height) ~= "number" or row_height <= 0
            or type(y) ~= "number" or show_page < 1
            or items_per_page < 1 or item_count < 1 then
        return nil
    end
    local first = (show_page - 1) * items_per_page + 1
    local visible = math.min(items_per_page, item_count - first + 1)
    local slot = math.floor((y - top) / row_height) + 1
    if slot < 1 then return math.max(1, first - 1) end
    if slot > visible then return math.min(item_count, first + visible) end
    return first + slot - 1
end

function M.dragPageDirection(y, top, bottom)
    if type(y) == "number" and type(top) == "number" and type(bottom) == "number" then
        if y < top then return -1 end
        if y >= bottom then return 1 end
    end
    return 0
end

function M.moveTableItem(items, from, target)
    if type(items) ~= "table" or type(from) ~= "number" or type(target) ~= "number"
            or from % 1 ~= 0 or target % 1 ~= 0
            or from < 1 or from > #items or target < 1 or target > #items
            or type(items[from]) ~= "table" then
        return false
    end
    if items[from].arrange_pinned_last then return false end
    while target > 1 and items[target] and items[target].arrange_pinned_last do
        target = target - 1
    end
    if target == from then return false end
    local item = table.remove(items, from)
    table.insert(items, target, item)
    return true, target
end

function M.stripSubmenuCaret(text)
    if type(text) ~= "string" then return text end
    local ascii_caret = " >"
    local old_caret = string.char(226, 150, 184)
    if text:sub(-#M.SUBMENU_CARET) == M.SUBMENU_CARET then
        return text:sub(1, -#M.SUBMENU_CARET - 1)
    end
    if text:sub(-#ascii_caret) == ascii_caret then
        return text:sub(1, -#ascii_caret - 1)
    end
    if text:sub(-#old_caret) == old_caret then
        return (text:sub(1, -#old_caret - 1):gsub("%s+$", ""))
    end
    return text
end

function M.stripValueSuffix(text)
    if type(text) ~= "string" then return text end
    local value_start = text:find(": ", 1, true)
    if value_start and value_start > 1 then return text:sub(1, value_start - 1) end
    return text
end

return M
