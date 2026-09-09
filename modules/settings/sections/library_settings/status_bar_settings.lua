-- settings/sections/library/status_bar.lua
-- Status bar settings item for ZenOS.
-- Returns a single menu-item table: { text = _("Status bar"), sub_item_table = {...} }
-- Receives ctx: { config, save_and_apply }

local _ = require("gettext")
local UIManager = require("ui/uimanager")
local constants = require("common/constants")
local icons = require("common/inline_icon_map")
local IconItem = require("common/ui/icon_menu_item")
local Bluetooth = require("common/bluetooth")
local DateFormat = require("common/date_format")

local M = {}

function M.build(ctx)
    local config        = ctx.config
    local save_and_apply = ctx.save_and_apply

    local function save_and_apply_status_bar() save_and_apply("status_bar") end

    -- -------------------------------------------------------------------------
    -- Slot items (deduplicates left / center / right)
    -- -------------------------------------------------------------------------

    local status_bar_all_items = {
        { key = "bluetooth",   text = _("Bluetooth"), available = Bluetooth.isAvailable },
        { key = "incognito",   text = _("Incognito")   },
        { key = "wifi",        text = _("Wi-Fi")       },
        { key = "disk",        text = _("Disk space")  },
        { key = "ram",         text = _("RAM usage")   },
        { key = "frontlight",  text = _("Brightness")  },
        { key = "battery",     text = _("Battery")     },
        { key = "time",        text = _("Time")        },
        { key = "date",        text = _("Date")        },
        { key = "custom_text", text = _("Custom text") },
    }

    do
        local available_items = {}
        for _i, item in ipairs(status_bar_all_items) do
            if not item.available or item.available() then
                table.insert(available_items, item)
            end
        end
        status_bar_all_items = available_items
    end

    -- Append items registered via __ZENOS_REGISTER_STATUS_ITEM (or its legacy alias).
    local ext_registry = rawget(_G, "__ZEN_UI_STATUS_ITEMS")
    if type(ext_registry) == "table" then
        for key, entry in pairs(ext_registry) do
            if type(entry) == "table" and type(entry.fetch) == "function" then
                table.insert(status_bar_all_items, {
                    key  = key,
                    text = type(entry.label) == "string" and entry.label or key,
                })
            end
        end
    end

    -- Canonical positions within each slot: items are inserted at the slot
    -- position matching this order when the user enables them, rather than
    -- always appending to the end.
    local CANONICAL_ORDERS = {
        left   = { "time", "date", "custom_text" },
        center = {},
        right  = { "date", "custom_text", "disk", "ram", "frontlight", "incognito", "bluetooth", "wifi", "battery" },
    }

    local function current_date_format()
        return config.status_bar.date_format or "short"
    end

    local function make_date_format_items()
        local items = {}
        for _i, def in ipairs({
            { key = "short" },
            { key = "long" },
        }) do
            local format = def.key
            local item = {
                text_func = function() return DateFormat.format(format) end,
                radio = true,
                checked_func = function() return current_date_format() == format end,
                callback = function(touchmenu_instance)
                    config.status_bar.date_format = format
                    save_and_apply_status_bar()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            }
            table.insert(items, item)
        end
        return items
    end

    local function make_wifi_items()
        return {
            {
                text = _("Hide when off"),
                checked_func = function()
                    return config.status_bar.wifi_hide_when_off == true
                end,
                callback = function()
                    config.status_bar.wifi_hide_when_off =
                        config.status_bar.wifi_hide_when_off ~= true
                    save_and_apply_status_bar()
                end,
            },
        }
    end

    local function make_status_bar_slot_items(slot_name, arrange_title)
        local order_key = slot_name .. "_order"
        local canonical = CANONICAL_ORDERS[slot_name] or {}
        local canon_pos = {}
        for i, k in ipairs(canonical) do canon_pos[k] = i end
        local other_keys = {}
        for _i, s in ipairs({ "left", "center", "right" }) do
            if s ~= slot_name then
                table.insert(other_keys, s .. "_order")
            end
        end

        local t = {
            {
                text = _("Arrange"),
                keep_menu_open = true,
                separator = true,
                callback = function()
                    local SortWidget = require("ui/widget/sortwidget")
                    local lbl = {}
                    for _i, d in ipairs(status_bar_all_items) do lbl[d.key] = d.text end
                    local sort_items = {}
                    for _i, key in ipairs(config.status_bar[order_key] or {}) do
                        if lbl[key] then
                            table.insert(sort_items, { text = lbl[key], orig_item = key })
                        end
                    end
                    UIManager:show(SortWidget:new{
                        title = arrange_title,
                        item_table = sort_items,
                        callback = function()
                            local new_order = {}
                            for _i, item in ipairs(sort_items) do
                                table.insert(new_order, item.orig_item)
                            end
                            config.status_bar[order_key] = new_order
                            save_and_apply_status_bar()
                        end,
                    })
                end,
            },
        }

        for _i, def in ipairs(status_bar_all_items) do
            local key = def.key
            local function is_available()
                -- Disable if already active in another slot.
                for _j, other_key in ipairs(other_keys) do
                    for _k, k in ipairs(config.status_bar[other_key] or {}) do
                        if k == key then return false end
                    end
                end
                return true
            end
            local function is_checked()
                for _j, k in ipairs(config.status_bar[order_key] or {}) do
                    if k == key then return true end
                end
                return false
            end
            local function toggle(touchmenu_instance)
                local this_order = config.status_bar[order_key] or {}
                local found = false
                local new_this = {}
                for _j, k in ipairs(this_order) do
                    if k == key then found = true else table.insert(new_this, k) end
                end
                if found then
                    config.status_bar[order_key] = new_this
                else
                    for _j, other_key in ipairs(other_keys) do
                        local new_other = {}
                        for _k, k in ipairs(config.status_bar[other_key] or {}) do
                            if k ~= key then table.insert(new_other, k) end
                        end
                        config.status_bar[other_key] = new_other
                    end
                    local new_key_canon = canon_pos[key] or math.huge
                    local insert_at = #this_order + 1
                    for i, k in ipairs(this_order) do
                        if (canon_pos[k] or math.huge) > new_key_canon then
                            insert_at = i
                            break
                        end
                    end
                    table.insert(this_order, insert_at, key)
                    config.status_bar[order_key] = this_order
                end
                if touchmenu_instance then touchmenu_instance:updateItems() end
                save_and_apply_status_bar()
            end

            local item = {
                text = def.text,
                keep_menu_open = true,
                enabled_func = is_available,
            }
            if key == "date" then
                item.checked_func = is_checked
                item.checkmark_callback = toggle
                item.sub_item_table = make_date_format_items()
            elseif key == "wifi" then
                item.checked_func = is_checked
                item.checkmark_callback = toggle
                item.sub_item_table = make_wifi_items()
            else
                item.checked_func = is_checked
                item.callback = toggle
            end
            table.insert(t, item)
        end
        return t
    end

    -- -------------------------------------------------------------------------
    -- Status bar item
    -- -------------------------------------------------------------------------

    local function has_status_items()
        return #(config.status_bar.left_order or {}) > 0
            or #(config.status_bar.center_order or {}) > 0
            or #(config.status_bar.right_order or {}) > 0
    end

    return IconItem.decorate({
        text = _("Status bar"),
        checked_func = has_status_items,
        checkmark_callback = function()
            if has_status_items() then
                config.status_bar.left_order = {}
                config.status_bar.center_order = {}
                config.status_bar.right_order = {}
            else
                config.status_bar.left_order = { "time" }
                config.status_bar.center_order = {}
                config.status_bar.right_order = { "wifi", "battery" }
            end
            config.features.status_bar = true
            save_and_apply("status_bar")
        end,
        sub_item_table = {
            {
                text_func = function()
                    local name = config.status_bar.custom_text
                    if name == nil or name == "" then
                        name = require("device").model or ""
                    end
                    return _("Custom text: ") .. name
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local InputDialog = require("ui/widget/inputdialog")
                    local Device = require("device")
                    local dlg
                    dlg = InputDialog:new{
                        title = _("Custom text"),
                        input = config.status_bar.custom_text or "",
                        hint = Device.model or "",
                        buttons = {{
                            {
                                text = _("Cancel"),
                                id = "close",
                                callback = function() UIManager:close(dlg) end,
                            },
                            {
                                text = _("Set"),
                                is_enter_default = true,
                                callback = function()
                                    config.status_bar.custom_text = dlg:getInputText()
                                    UIManager:close(dlg)
                                    save_and_apply_status_bar()
                                    if touchmenu_instance then
                                        touchmenu_instance:updateItems()
                                    end
                                end,
                            },
                        }},
                    }
                    UIManager:show(dlg)
                    dlg:onShowKeyboard()
                end,
            },
            {
                text = _("Show bottom border"),
                checked_func = function() return config.status_bar.show_bottom_border == true end,
                callback = function()
                    config.status_bar.show_bottom_border = config.status_bar.show_bottom_border ~= true
                    save_and_apply_status_bar()
                end,
            },
            {
                text = _("Bold text"),
                checked_func = function() return config.status_bar.bold_text == true end,
                callback = function()
                    config.status_bar.bold_text = config.status_bar.bold_text ~= true
                    save_and_apply_status_bar()
                end,
            },
            {
                text = _("Colored status icons"),
                checked_func = function() return config.status_bar.colored == true end,
                callback = function()
                    config.status_bar.colored = config.status_bar.colored ~= true
                    save_and_apply_status_bar()
                end,
            },
            {
                text = _("Left items"),
                sub_item_table = make_status_bar_slot_items("left", _("Arrange left items")),
            },
            {
                text = _("Center items"),
                sub_item_table = make_status_bar_slot_items("center", _("Arrange center items")),
            },
            {
                text = _("Right items"),
                sub_item_table = make_status_bar_slot_items("right", _("Arrange right items")),
            },
            {
                text_func = function()
                    local key = config.status_bar.separator_key or "dot"
                    for _i, s in ipairs(constants.SEPARATOR_PRESETS) do
                        if s.key == key then
                            return _("Separator: ") .. _(s.label)
                        end
                    end
                    return _("Separator: ") .. key
                end,
                sub_item_table = (function()
                    -- Preview strings per key (bar-specific spacing).
                    local preview = {
                        dot             = "  \xC2\xB7  ",
                        bar             = "  |  ",
                        dash            = "  -  ",
                        bullet          = "  \xE2\x80\xA2  ",
                        space           = "   ",
                        ["small-space"] = " ",
                        none            = "",
                    }
                    local sub = {}
                    for _i, sep in ipairs(constants.SEPARATOR_PRESETS) do
                        local key = sep.key
                        if key == "custom" then
                            table.insert(sub, {
                                text_func = function()
                                    return _("Custom") .. "  '" .. (config.status_bar.custom_separator or "") .. "'"
                                end,
                                checked_func = function() return config.status_bar.separator_key == "custom" end,
                                callback = function(touchmenu_instance)
                                    local InputDialog = require("ui/widget/inputdialog")
                                    local dlg
                                    dlg = InputDialog:new{
                                        title = _("Custom separator"),
                                        input = config.status_bar.custom_separator or "",
                                        buttons = {{
                                            {
                                                text = _("Cancel"),
                                                id = "close",
                                                callback = function() UIManager:close(dlg) end,
                                            },
                                            {
                                                text = _("Set"),
                                                is_enter_default = true,
                                                callback = function()
                                                    config.status_bar.custom_separator = dlg:getInputText()
                                                    config.status_bar.separator_key = "custom"
                                                    UIManager:close(dlg)
                                                    save_and_apply_status_bar()
                                                    if touchmenu_instance then
                                                        touchmenu_instance:updateItems()
                                                    end
                                                end,
                                            },
                                        }},
                                    }
                                    UIManager:show(dlg)
                                    dlg:onShowKeyboard()
                                end,
                            })
                        else
                            local pv = preview[key]
                            table.insert(sub, {
                                text = _(sep.label) .. (pv and pv ~= "" and ("  '" .. pv .. "'") or ""),
                                checked_func = function() return config.status_bar.separator_key == key end,
                                callback = function()
                                    config.status_bar.separator_key = key
                                    save_and_apply_status_bar()
                                end,
                            })
                        end
                    end
                    return sub
                end)(),
            },
        },
    }, icons.settings_status)
end

return M
