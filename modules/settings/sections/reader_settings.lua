-- settings/sections/reader.lua
-- Reader settings items for ZenOS (clock, presets, fonts, footer).
-- Receives ctx: { plugin, config, save_and_apply }

local _ = require("gettext")
local T = require("ffi/util").template
local UIManager = require("ui/uimanager")
local dispatch_action = require("common/dispatch_action")
local utils = require("modules/settings/zen_settings_utils")
local constants = require("common/constants")
local PresetStore = require("config/preset_store")
local ReaderThemes = require("common/reader_themes")
local icons = require("common/inline_icon_map")
local IconItem = require("common/ui/icon_menu_item")

local M = {}

function M.build(ctx)
    local config = ctx.config
    local plugin = ctx.plugin
    local save_and_apply = ctx.save_and_apply

    local function make_enable_feature_item(feature, text)
        return utils.make_enable_feature_item(feature, text, config, save_and_apply)
    end

    -- Returns true if a plugin is loaded in the active UI or PluginLoader.
    local function hasPlugin(slot)
        local ok_f, FM = pcall(require, "apps/filemanager/filemanager")
        local ok_r, RU = pcall(require, "apps/reader/readerui")
        local ui = (ok_f and FM.instance) or (ok_r and RU.instance)
        if ui and ui[slot] ~= nil then return true end
        local ok_l, loader = pcall(require, "pluginloader")
        return ok_l and type(loader.loaded_plugins) == "table"
            and loader.loaded_plugins[slot] ~= nil
    end

    local function make_lookup_plugin_item(slot, setting, text, help_text)
        return {
            text = text,
            help_text = help_text,
            show_func = function() return hasPlugin(slot) end,
            checked_func = function()
                return type(config.highlight_lookup) == "table"
                    and config.highlight_lookup[setting] ~= false
            end,
            callback = function()
                if type(config.highlight_lookup) ~= "table" then
                    config.highlight_lookup = {}
                end
                config.highlight_lookup[setting] =
                    config.highlight_lookup[setting] == false
                plugin:saveConfig()
            end,
        }
    end

    local highlight_colors = {
        { key = "red", text = _("Red") },
        { key = "orange", text = _("Orange") },
        { key = "yellow", text = _("Yellow") },
        { key = "green", text = _("Green") },
        { key = "olive", text = _("Olive") },
        { key = "cyan", text = _("Cyan") },
        { key = "blue", text = _("Blue") },
        { key = "purple", text = _("Purple") },
        { key = "gray", text = _("Gray") },
    }

    local function highlight_color_names()
        if type(config.highlight_lookup) ~= "table" then config.highlight_lookup = {} end
        if type(config.highlight_lookup.color_names) ~= "table" then
            config.highlight_lookup.color_names = {}
        end
        return config.highlight_lookup.color_names
    end

    local function save_highlight_color_names()
        plugin:saveConfig()
        require("modules/reader/patches/highlight_names")(plugin)
    end

    local function make_highlight_name_items()
        local items = {
            {
                text = _("Reset"),
                enabled_func = function() return next(highlight_color_names()) ~= nil end,
                callback = function(touchmenu_instance)
                    config.highlight_lookup.color_names = {}
                    save_highlight_color_names()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
                separator = true,
            },
        }
        for _i, color in ipairs(highlight_colors) do
            local color_name = color.key
            local default_name = color.text
            table.insert(items, {
                text_func = function()
                    local name = highlight_color_names()[color_name]
                    return name and (default_name .. ": " .. name) or default_name
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local InputDialog = require("ui/widget/inputdialog")
                    local dlg
                    dlg = InputDialog:new{
                        title = default_name,
                        input = highlight_color_names()[color_name] or "",
                        input_hint = default_name,
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
                                    local name = dlg:getInputText()
                                    name = type(name) == "string"
                                        and name:match("^%s*(.-)%s*$") or ""
                                    if name == "" or name == default_name then name = nil end
                                    if highlight_color_names()[color_name] == name then
                                        UIManager:close(dlg)
                                        return
                                    end
                                    highlight_color_names()[color_name] = name
                                    UIManager:close(dlg)
                                    save_highlight_color_names()
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            },
                        }},
                    }
                    UIManager:show(dlg)
                    dlg:onShowKeyboard()
                end,
            })
        end
        return items
    end

    local items = {}

    -- -------------------------------------------------------------------------
    -- Top status bar
    -- -------------------------------------------------------------------------

    -- Items available in each slot (excludes dynamic fillers / external content)
    local header_all_items = {
        { key = "time",        text = _("Time")          },
        { key = "battery",     text = _("Battery")       },
        { key = "battery_icon", text = _("Battery icon") },
        { key = "battery_percent", text = _("Battery percentage") },
        { key = "incognito",   text = _("Incognito")     },
        { key = "wifi",        text = _("Wi-Fi")         },
        { key = "frontlight",  text = _("Brightness")    },
        { key = "ram",         text = _("RAM usage")     },
        { key = "disk",        text = _("Disk space")    },
        { key = "custom_text", text = _("Custom text")   },
        { key = "book_title",  text = _("Book title")    },
        { key = "author",      text = _("Author")        },
        { key = "chapter",     text = _("Chapter")       },
        { key = "progress_percent", text = _("Progress %") },
        { key = "current_page",     text = _("Current page") },
        { key = "total_pages",      text = _("Total pages") },
        { key = "page_progress",    text = _("Current / total pages") },
    }

    local HEADER_CANONICAL = {
        left   = { "time", "custom_text" },
        center = { "time" },
        right  = {
            "progress_percent", "current_page", "total_pages", "page_progress",
            "custom_text", "frontlight", "incognito", "wifi", "battery",
            "battery_icon", "battery_percent",
        },
    }

    local function save_clock() save_and_apply("reader_top_status_bar") end

    local function make_custom_text_items()
        return {
            {
                text_func = function()
                    local name = type(config.reader_top_status_bar) == "table"
                        and config.reader_top_status_bar.custom_text or ""
                    local Device = require("device")
                    if name == nil or name == "" then name = Device.model or "" end
                    return _("Custom text: ") .. name
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local InputDialog = require("ui/widget/inputdialog")
                    local Device = require("device")
                    local dlg
                    dlg = InputDialog:new{
                        title = _("Custom text"),
                        input = type(config.reader_top_status_bar) == "table"
                            and config.reader_top_status_bar.custom_text or "",
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
                                    if type(config.reader_top_status_bar) ~= "table" then
                                        config.reader_top_status_bar = {}
                                    end
                                    config.reader_top_status_bar.custom_text = dlg:getInputText()
                                    UIManager:close(dlg)
                                    save_clock()
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            },
                        }},
                    }
                    UIManager:show(dlg)
                    dlg:onShowKeyboard()
                end,
            },
        }
    end

    local function make_header_wifi_items()
        return {
            {
                text = _("Hide when off"),
                checked_func = function()
                    return type(config.reader_top_status_bar) == "table"
                        and config.reader_top_status_bar.wifi_hide_when_off == true
                end,
                callback = function()
                    if type(config.reader_top_status_bar) ~= "table" then
                        config.reader_top_status_bar = {}
                    end
                    config.reader_top_status_bar.wifi_hide_when_off =
                        config.reader_top_status_bar.wifi_hide_when_off ~= true
                    save_clock()
                end,
            },
        }
    end

    local function make_header_slot_items(slot_name, arrange_title)
        local order_key = slot_name .. "_order"
        local canonical = HEADER_CANONICAL[slot_name] or {}
        local canon_pos = {}
        for idx, k in ipairs(canonical) do canon_pos[k] = idx end
        local other_slots = {}
        for _i, s in ipairs({ "left", "center", "right" }) do
            if s ~= slot_name then table.insert(other_slots, s .. "_order") end
        end

        local t = {
            {
                text = _("Show separator"),
                keep_menu_open = true,
                checked_func = function()
                    if type(config.reader_top_status_bar) ~= "table" then return false end
                    return config.reader_top_status_bar[slot_name .. "_show_separator"] == true
                end,
                callback = function(touchmenu_instance)
                    if type(config.reader_top_status_bar) ~= "table" then config.reader_top_status_bar = {} end
                    local key = slot_name .. "_show_separator"
                    config.reader_top_status_bar[key] = config.reader_top_status_bar[key] ~= true
                    save_clock()
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            },
            {
                text = _("Arrange"),
                keep_menu_open = true,
                separator = true,
                callback = function()
                    local SortWidget = require("ui/widget/sortwidget")
                    local lbl = {}
                    for _i, d in ipairs(header_all_items) do lbl[d.key] = d.text end
                    if type(config.reader_top_status_bar) ~= "table" then config.reader_top_status_bar = {} end
                    local cur = config.reader_top_status_bar[order_key] or {}
                    local sort_items = {}
                    for _i, key in ipairs(cur) do
                        if lbl[key] then table.insert(sort_items, { text = lbl[key], orig_item = key }) end
                    end
                    UIManager:show(SortWidget:new{
                        title = arrange_title,
                        item_table = sort_items,
                        callback = function()
                            local new_order = {}
                            for _i, item in ipairs(sort_items) do
                                table.insert(new_order, item.orig_item)
                            end
                            config.reader_top_status_bar[order_key] = new_order
                            save_clock()
                        end,
                    })
                end,
            },
        }

        for _i, def in ipairs(header_all_items) do
            local key = def.key
            local item = {
                text = def.text,
                keep_menu_open = true,
                enabled_func = function()
                    -- Disable if the key is active in another slot.
                    if type(config.reader_top_status_bar) ~= "table" then return true end
                    for _j, other in ipairs(other_slots) do
                        for _k, k in ipairs(config.reader_top_status_bar[other] or {}) do
                            if k == key then return false end
                        end
                    end
                    return true
                end,
                checked_func = function()
                    if type(config.reader_top_status_bar) ~= "table" then return false end
                    for _j, k in ipairs(config.reader_top_status_bar[order_key] or {}) do
                        if k == key then return true end
                    end
                    return false
                end,
                callback = function(touchmenu_instance)
                    if type(config.reader_top_status_bar) ~= "table" then config.reader_top_status_bar = {} end
                    local this_order = config.reader_top_status_bar[order_key] or {}
                    local found = false
                    local new_this = {}
                    for _j, k in ipairs(this_order) do
                        if k == key then found = true else table.insert(new_this, k) end
                    end
                    if found then
                        config.reader_top_status_bar[order_key] = new_this
                    else
                        -- Remove from any other slot first.
                        for _j, other in ipairs(other_slots) do
                            local new_other = {}
                            for _k, k in ipairs(config.reader_top_status_bar[other] or {}) do
                                if k ~= key then table.insert(new_other, k) end
                            end
                            config.reader_top_status_bar[other] = new_other
                        end
                        -- Insert at canonical position.
                        local new_key_pos = canon_pos[key] or math.huge
                        local insert_at = #this_order + 1
                        for idx, k in ipairs(this_order) do
                            if (canon_pos[k] or math.huge) > new_key_pos then
                                insert_at = idx
                                break
                            end
                        end
                        table.insert(this_order, insert_at, key)
                        config.reader_top_status_bar[order_key] = this_order
                    end
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                    save_clock()
                end,
            }
            if key == "custom_text" then
                item.checkmark_callback = item.callback
                item.callback = nil
                item.sub_item_table = make_custom_text_items()
            elseif key == "wifi" then
                item.checkmark_callback = item.callback
                item.callback = nil
                item.sub_item_table = make_header_wifi_items()
            end
            table.insert(t, item)
        end
        return t
    end

    table.insert(items, {
        text = _("Top status bar"),
        checked_func = function()
            return config.features["reader_top_status_bar"] == true
        end,
        checkmark_callback = function()
            config.features["reader_top_status_bar"] =
                config.features["reader_top_status_bar"] ~= true
            save_and_apply("reader_top_status_bar")
        end,
        sub_item_table = {
            {
                text = _("Left items"),
                sub_item_table = make_header_slot_items("left", _("Arrange left items")),
            },
            {
                text = _("Center items"),
                sub_item_table = make_header_slot_items("center", _("Arrange center items")),
            },
            {
                text = _("Right items"),
                sub_item_table = make_header_slot_items("right", _("Arrange right items")),
            },
            {
                text_func = function()
                    local ok_fc, FontChooser = pcall(require, "ui/widget/fontchooser")
                    local face = type(config.reader_top_status_bar) == "table" and config.reader_top_status_bar.font_face
                    local text = (not face or face == "default") and _("default")
                        or (ok_fc and FontChooser.getFontNameText(face) or face)
                    local size = type(config.reader_top_status_bar) == "table" and config.reader_top_status_bar.font_size or 14
                    return string.format("%s %s, %s", _("Font:"), text, size)
                end,
                sub_item_table = {
                    {
                        text_func = function()
                            local size = type(config.reader_top_status_bar) == "table" and config.reader_top_status_bar.font_size or 14
                            return string.format("%s %s", _("Font size:"), size)
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            local SpinWidget = require("ui/widget/spinwidget")
                            UIManager:show(SpinWidget:new{
                                title_text = _("Font size"),
                                value = type(config.reader_top_status_bar) == "table" and config.reader_top_status_bar.font_size or 14,
                                value_min = 8,
                                value_max = 36,
                                default_value = 14,
                                callback = function(spin)
                                    if type(config.reader_top_status_bar) ~= "table" then config.reader_top_status_bar = {} end
                                    config.reader_top_status_bar.font_size = spin.value
                                    save_clock()
                                    if touchmenu_instance then touchmenu_instance:updateItems() end
                                end,
                            })
                        end,
                    },
                    {
                        text_func = function()
                            local ok_fc, FontChooser = pcall(require, "ui/widget/fontchooser")
                            local face = type(config.reader_top_status_bar) == "table" and config.reader_top_status_bar.font_face
                            local text = (not face or face == "default") and _("default")
                                or (ok_fc and FontChooser.getFontNameText(face) or face)
                            return string.format("%s %s", _("Font:"), text)
                        end,
                        keep_menu_open = true,
                        callback = function(touchmenu_instance)
                            local ok_fc, FontChooser = pcall(require, "ui/widget/fontchooser")
                            if not ok_fc then return end
                            local footer_settings = G_reader_settings:readSetting("footer") or {}
                            local footer_font = footer_settings.text_font_face or "NotoSans-Regular.ttf"
                            local current_face = type(config.reader_top_status_bar) == "table" and config.reader_top_status_bar.font_face
                            local display_face = (not current_face or current_face == "default")
                                and footer_font or current_face
                            UIManager:show(FontChooser:new{
                                title = _("Top bar font"),
                                font_file = display_face,
                                default_font_file = footer_font,
                                callback = function(file)
                                    if type(config.reader_top_status_bar) ~= "table" then config.reader_top_status_bar = {} end
                                    if config.reader_top_status_bar.font_face ~= file then
                                        config.reader_top_status_bar.font_face = file
                                        save_clock()
                                        if touchmenu_instance then touchmenu_instance:updateItems() end
                                    end
                                end,
                            })
                        end,
                        hold_callback = function(touchmenu_instance)
                            if type(config.reader_top_status_bar) ~= "table" then config.reader_top_status_bar = {} end
                            if config.reader_top_status_bar.font_face ~= "default" then
                                config.reader_top_status_bar.font_face = "default"
                                save_clock()
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end
                        end,
                    },
                    {
                        text = _("Use default font"),
                        show_func = function()
                            local ok = pcall(require, "ui/widget/fontchooser")
                            return ok
                        end,
                        callback = function(touchmenu_instance)
                            if type(config.reader_top_status_bar) ~= "table" then config.reader_top_status_bar = {} end
                            config.reader_top_status_bar.font_face = "default"
                            save_clock()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    },
                },
            },
            (function()
                local function cur_sep_key()
                    return type(config.reader_top_status_bar) == "table"
                        and config.reader_top_status_bar.separator_key or "small-space"
                end
                local function cur_sep_label()
                    local key = cur_sep_key()
                    for _i, s in ipairs(constants.SEPARATOR_PRESETS) do
                        if s.key == key then return _(s.label) end
                    end
                    return key
                end
                local sub = {}
                for _i, sep in ipairs(constants.SEPARATOR_PRESETS) do
                    if sep.key ~= "custom" then  -- custom not yet wired to reader top bar
                        local key = sep.key
                        table.insert(sub, {
                            text = _(sep.label),
                            checked_func = function() return cur_sep_key() == key end,
                            callback = function(touchmenu_instance)
                                if type(config.reader_top_status_bar) ~= "table" then config.reader_top_status_bar = {} end
                                config.reader_top_status_bar.separator_key = key
                                save_clock()
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end,
                        })
                    end
                end
                return {
                    text_func = function()
                        return string.format("%s: %s", _("Separator"), cur_sep_label())
                    end,
                    sub_item_table = sub,
                }
            end)(),
            {
                text = _("Show bottom border"),
                checked_func = function()
                    return type(config.reader_top_status_bar) == "table"
                        and config.reader_top_status_bar.show_bottom_border == true
                end,
                callback = function()
                    if type(config.reader_top_status_bar) ~= "table" then config.reader_top_status_bar = {} end
                    config.reader_top_status_bar.show_bottom_border = not config.reader_top_status_bar.show_bottom_border
                    save_clock()
                end,
            },
            {
                text = _("Use border as progress bar"),
                checked_func = function()
                    return type(config.reader_top_status_bar) == "table"
                        and config.reader_top_status_bar.bottom_border_progress == true
                end,
                callback = function()
                    if type(config.reader_top_status_bar) ~= "table" then config.reader_top_status_bar = {} end
                    local enabled = config.reader_top_status_bar.bottom_border_progress ~= true
                    config.reader_top_status_bar.bottom_border_progress = enabled
                    if enabled then
                        config.reader_top_status_bar.show_bottom_border = true
                    end
                    save_clock()
                end,
            },
            {
                text = _("Chapter marks"),
                checked_func = function()
                    return type(config.reader_top_status_bar) == "table"
                        and config.reader_top_status_bar.show_chapter_marks == true
                end,
                callback = function()
                    if type(config.reader_top_status_bar) ~= "table" then config.reader_top_status_bar = {} end
                    local enabled = config.reader_top_status_bar.show_chapter_marks ~= true
                    config.reader_top_status_bar.show_chapter_marks = enabled
                    if enabled then
                        config.reader_top_status_bar.show_bottom_border = true
                        config.reader_top_status_bar.bottom_border_progress = true
                    end
                    save_clock()
                end,
            },
            {
                text = _("Colored status icons"),
                checked_func = function()
                    return type(config.reader_top_status_bar) == "table"
                        and config.reader_top_status_bar.colored == true
                end,
                callback = function()
                    if type(config.reader_top_status_bar) ~= "table" then config.reader_top_status_bar = {} end
                    config.reader_top_status_bar.colored = config.reader_top_status_bar.colored ~= true
                    save_clock()
                end,
            },
            {
                text = _("Hide in CBZ/PDF files"),
                checked_func = function()
                    return type(config.reader_top_status_bar) == "table"
                        and config.reader_top_status_bar.hide_in_cbz == true
                end,
                callback = function()
                    if type(config.reader_top_status_bar) ~= "table" then config.reader_top_status_bar = {} end
                    config.reader_top_status_bar.hide_in_cbz = not config.reader_top_status_bar.hide_in_cbz
                    save_clock()
                end,
            },
        },
    })

    local builtin_themes = {
        { key = "default", text = _("Default") },
        { key = "dark_warm_gray", text = _("Dark warm gray") },
        { key = "dark_graphite", text = _("Dark graphite") },
        { key = "light_sepia", text = _("Light sepia") },
        { key = "light_tan", text = _("Light tan") },
    }

    local function theme_settings()
        if type(config.reader_themes) ~= "table" then config.reader_themes = {} end
        if type(config.reader_themes.custom) ~= "table" then config.reader_themes.custom = {} end
        return config.reader_themes
    end

    local function save_themes()
        if type(PresetStore.loadStore) == "function" and type(PresetStore.saveStore) == "function" then
            local reader_store = PresetStore.loadStore("reader")
            reader_store.reader_themes = config.reader_themes
            PresetStore.saveStore("reader", reader_store)
        end
        plugin:saveConfig()
        if config.features.reader_themes == true then ctx.apply_feature("reader_themes") end
    end

    local function get_theme(mode)
        local settings = config.reader_themes
        local default = mode == "dark_mode" and "dark_warm_gray" or "default"
        return type(settings) == "table" and settings[mode] or default
    end

    local function theme_name(key)
        for _i, theme in ipairs(builtin_themes) do
            if theme.key == key then return theme.text end
        end
        local custom = type(config.reader_themes) == "table" and config.reader_themes.custom
        local theme = type(custom) == "table" and custom[key]
        return type(theme) == "table" and theme.name or _("Default")
    end

    local function make_theme_mode_item(mode, label)
        return {
            text_func = function()
                return label .. ": " .. theme_name(get_theme(mode))
            end,
            sub_item_table_func = function()
                local theme_items = {}
                for _i, theme in ipairs(builtin_themes) do
                    local key = theme.key
                    table.insert(theme_items, {
                        text = theme.text,
                        checked_func = function() return get_theme(mode) == key end,
                        callback = function(touchmenu_instance)
                            theme_settings()[mode] = key
                            save_themes()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end
                local custom = theme_settings().custom
                for key, theme in pairs(custom) do
                    if type(theme) == "table" then
                        table.insert(theme_items, {
                            text = theme.name or _("Custom theme"),
                            checked_func = function() return get_theme(mode) == key end,
                            callback = function(touchmenu_instance)
                                theme_settings()[mode] = key
                                save_themes()
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end,
                        })
                    end
                end
                return theme_items
            end,
        }
    end

    local function show_theme_text_dialog(theme, field, title, touchmenu_instance, on_change)
        local InputDialog = require("ui/widget/inputdialog")
        local dlg
        dlg = InputDialog:new{
            title = title,
            input = theme[field] or "",
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
                        local value = dlg:getInputText()
                        local is_color = field == "background" or field == "text"
                        if (not is_color and value and not value:match("^%s*$"))
                            or (is_color and ReaderThemes.isValidColor(value)) then
                            value = is_color and ReaderThemes.normalizeColor(value) or value
                            if value == theme[field] then
                                UIManager:close(dlg)
                                return
                            end
                            UIManager:close(dlg)
                            on_change(value)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end
                    end,
                },
            }},
        }
        UIManager:show(dlg)
        dlg:onShowKeyboard()
    end

    local function unique_custom_theme_name(base_key)
        local custom = theme_settings().custom
        local base_name = base_key and (_("Custom") .. " " .. theme_name(base_key)) or _("Custom theme")
        local name = base_name
        local number = 2
        local in_use = true
        while in_use do
            in_use = false
            for _key, existing in pairs(custom) do
                if type(existing) == "table" and existing.name == name then
                    in_use = true
                    name = base_name .. " " .. number
                    number = number + 1
                    break
                end
            end
        end
        return name
    end

    local function create_custom_theme(theme, base_key)
        local custom = theme_settings().custom
        local number = 1
        local key = "custom_" .. number
        while custom[key] do
            number = number + 1
            key = "custom_" .. number
        end
        local new_theme = {
            name = unique_custom_theme_name(base_key),
            text = theme.text,
            background = theme.background,
            font_face = theme.font_face or "default",
        }
        custom[key] = new_theme
        return key, new_theme
    end

    local build_custom_theme_items

    local function make_theme_edit_item(key, theme, base_key)
        local editable_theme = theme
        local editable_key = key
        local function save_change(field, value)
            if editable_theme[field] == value then return end
            if not editable_key then
                editable_key, editable_theme = create_custom_theme(theme, base_key)
            end
            editable_theme[field] = value
            save_themes()
        end

        local edit_items = {}
        if editable_key then
            table.insert(edit_items, {
                text_func = function() return _("Theme name") .. ": " .. (editable_theme.name or "") end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    show_theme_text_dialog(editable_theme, "name", _("Theme name"), touchmenu_instance,
                        function(value) save_change("name", value) end)
                end,
            })
        end
        table.insert(edit_items, {
            text_func = function() return _("Background color") .. ": " .. editable_theme.background end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                show_theme_text_dialog(editable_theme, "background", _("Background color"), touchmenu_instance,
                    function(value) save_change("background", value) end)
            end,
        })
        table.insert(edit_items, {
            text_func = function() return _("Text color") .. ": " .. editable_theme.text end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                show_theme_text_dialog(editable_theme, "text", _("Text color"), touchmenu_instance,
                    function(value) save_change("text", value) end)
            end,
        })
        table.insert(edit_items, {
            text_func = function()
                local ok, FontChooser = pcall(require, "ui/widget/fontchooser")
                local face = editable_theme.font_face
                local name = (not face or face == "default") and _("default")
                    or (ok and FontChooser.getFontNameText(face) or face)
                return _("Theme font") .. ": " .. name
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local ok, FontChooser = pcall(require, "ui/widget/fontchooser")
                if not ok then return end
                local face = editable_theme.font_face
                UIManager:show(FontChooser:new{
                    title = _("Theme font"),
                    font_file = (not face or face == "default") and "NotoSerif-Regular.ttf" or face,
                    default_font_file = "NotoSerif-Regular.ttf",
                    callback = function(file)
                        save_change("font_face", file)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end,
            hold_callback = function(touchmenu_instance)
                save_change("font_face", "default")
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        })
        if editable_key then
            table.insert(edit_items, {
                text = _("Delete theme"),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local ConfirmBox = require("ui/widget/confirmbox")
                    UIManager:show(ConfirmBox:new{
                        text = _("Delete this custom theme?") .. "\n\n" .. (editable_theme.name or ""),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            local settings = theme_settings()
                            settings.custom[editable_key] = nil
                            if settings.dark_mode == editable_key then settings.dark_mode = "dark_warm_gray" end
                            if settings.light_mode == editable_key then settings.light_mode = "default" end
                            save_themes()
                            if touchmenu_instance then
                                local refreshed_items = build_custom_theme_items()
                                local stack = touchmenu_instance.item_table_stack
                                if type(stack) == "table" and #stack > 0 then
                                    stack[#stack] = refreshed_items
                                    touchmenu_instance:backToUpperMenu()
                                else
                                    touchmenu_instance.item_table = refreshed_items
                                    touchmenu_instance:updateItems()
                                end
                            end
                        end,
                    })
                end,
            })
        end

        return {
            text_func = function() return editable_theme.name or theme_name(base_key) end,
            sub_item_table = edit_items,
        }
    end

    build_custom_theme_items = function(target_key)
        local custom_items = {
            {
                text = _("New custom theme"),
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local new_key = create_custom_theme({
                        text = "#000000",
                        background = "#ffffff",
                        font_face = "default",
                    })
                    save_themes()
                    if touchmenu_instance then
                        local parent_items, edit_item = build_custom_theme_items(new_key)
                        touchmenu_instance.item_table = parent_items
                        touchmenu_instance:onMenuSelect(edit_item)
                    end
                end,
            },
        }
        local target_item
        for _i, builtin in ipairs(builtin_themes) do
            if builtin.key ~= "default" then
                table.insert(custom_items,
                    make_theme_edit_item(nil, ReaderThemes.BUILTIN_THEMES[builtin.key], builtin.key))
            end
        end
        for key, theme in pairs(theme_settings().custom) do
            if type(theme) == "table" then
                local item = make_theme_edit_item(key, theme)
                table.insert(custom_items, item)
                if key == target_key then target_item = item end
            end
        end
        return custom_items, target_item
    end

    local function make_custom_themes_item()
        return {
            text = _("Custom themes"),
            sub_item_table_func = build_custom_theme_items,
        }
    end

    table.insert(items, {
        text = _("Reader themes"),
        checked_func = function()
            return config.features["reader_themes"] == true
        end,
        checkmark_callback = function()
            config.features["reader_themes"] = config.features["reader_themes"] ~= true
            save_and_apply("reader_themes")
        end,
        sub_item_table = {
            make_theme_mode_item("dark_mode", _("Dark mode")),
            make_theme_mode_item("light_mode", _("Light mode")),
            make_custom_themes_item(),
        },
    })

    -- -------------------------------------------------------------------------
    -- Footer presets
    -- -------------------------------------------------------------------------

    local function build_footer_presets_item()
        return {
            text = _("Zen Presets"),
            enabled_func = function()
                local ReaderUI = require("apps/reader/readerui")
                return ReaderUI.instance ~= nil
            end,
            sub_item_table_func = function()
                local ReaderUI = require("apps/reader/readerui")
                local ui = ReaderUI.instance
                if not (ui and ui.view and ui.view.footer) then
                    return {}
                end
                local function resolve_preset_font(preset)
                    if not (preset.footer and preset.footer.text_font_face) then return preset end
                    local ok_fc, FontChooser = pcall(require, "ui/widget/fontchooser")
                    if not ok_fc then return preset end
                    local face = preset.footer.text_font_face
                    if FontChooser.isFontRegistered(face) then return preset end
                    -- bare filename: search fontinfo for a matching full path
                    local FontList = require("fontlist")
                    FontList:getFontList()
                    local suffix = "/" .. face
                    for path in pairs(FontList.fontinfo) do
                        if path:sub(-#suffix) == suffix then
                            local util = require("util")
                            local copy = util.tableDeepCopy(preset)
                            copy.footer.text_font_face = path
                            return copy
                        end
                    end
                    return preset
                end

                local function capture_footer_state()
                    local util = require("util")
                    local footer_settings = ui.view.footer.settings
                        or G_reader_settings:readSetting("footer")
                        or {}
                    return {
                        footer = util.tableDeepCopy(footer_settings),
                        reader_footer_mode = G_reader_settings:readSetting("reader_footer_mode") or 1,
                        reader_footer_custom_text = G_reader_settings:readSetting("reader_footer_custom_text") or "KOReader",
                        reader_footer_custom_text_repetitions =
                            G_reader_settings:readSetting("reader_footer_custom_text_repetitions") or 1,
                        chapter_time_format = type(config.reader_footer) == "table"
                            and config.reader_footer.chapter_time_format or "number",
                    }
                end

                local function apply_footer_preset(preset)
                    ui.view.footer:loadPreset(resolve_preset_font(preset))
                    config.features["reader_top_status_bar"] = true
                    save_and_apply("reader_top_status_bar")
                    local chapter_time_format = preset.chapter_time_format
                    local verbose_chapter_time = preset.verbose_chapter_time
                    if verbose_chapter_time == nil and type(preset.zen) == "table" then
                        verbose_chapter_time = preset.zen.verbose_chapter_time
                    end
                    if chapter_time_format == nil and verbose_chapter_time ~= nil then
                        chapter_time_format = verbose_chapter_time == true and "full" or "number"
                    end
                    if chapter_time_format == "full" or chapter_time_format == "compact"
                            or chapter_time_format == "number" or chapter_time_format == "koreader" then
                        if type(config.reader_footer) ~= "table" then config.reader_footer = {} end
                        config.reader_footer.chapter_time_format = chapter_time_format
                        plugin:saveConfig()
                    end
                    PresetStore.saveSettings("reader", capture_footer_state())
                    PresetStore.setActivePreset("reader", preset.name)
                end

                local presets_items = {}
                local function refresh_preset_menu(touchmenu_instance)
                    if touchmenu_instance then
                        local presets_item = build_footer_presets_item()
                        touchmenu_instance.item_table = presets_item.sub_item_table_func()
                        touchmenu_instance:updateItems()
                    end
                end

                table.insert(presets_items, {
                    text = _("Save current settings as preset"),
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local InputDialog = require("ui/widget/inputdialog")
                        local dlg
                        dlg = InputDialog:new{
                            title = _("Preset name"),
                            input = "",
                            buttons = {{
                                {
                                    text = _("Cancel"),
                                    id = "close",
                                    callback = function() UIManager:close(dlg) end,
                                },
                                {
                                    text = _("Save"),
                                    is_enter_default = true,
                                    callback = function()
                                        local name = dlg:getInputText()
                                        if not name or name:match("^%s*$") then return end
                                        name = name:match("^%s*(.-)%s*$")
                                        UIManager:close(dlg)
                                        local state = capture_footer_state()
                                        PresetStore.save("reader", name, state)
                                        PresetStore.saveSettings("reader", state)
                                        PresetStore.setActivePreset("reader", name)
                                        refresh_preset_menu(touchmenu_instance)
                                    end,
                                },
                            }},
                        }
                        UIManager:show(dlg)
                        dlg:onShowKeyboard()
                    end,
                })

                local user_presets = PresetStore.list("reader")
                for _i, preset in ipairs(user_presets) do
                    local preset_name = preset.name
                    local is_builtin = preset.builtin == true
                    table.insert(presets_items, {
                        text_func = function()
                            local active = PresetStore.getActivePreset("reader")
                            local prefix = active == preset_name and "* " or ""
                            return prefix .. (preset_name or _("Unnamed preset"))
                        end,
                        callback = function(touchmenu_instance)
                            apply_footer_preset(preset)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                        hold_callback = not is_builtin and function(touchmenu_instance)
                            local ConfirmBox = require("ui/widget/confirmbox")
                            UIManager:show(ConfirmBox:new{
                                text = _("Delete preset?") .. "\n\n" .. (preset_name or ""),
                                ok_text = _("Delete"),
                                ok_callback = function()
                                    PresetStore.delete("reader", preset_name)
                                    if PresetStore.getActivePreset("reader") == preset_name then
                                        PresetStore.setActivePreset("reader", nil)
                                    end
                                    refresh_preset_menu(touchmenu_instance)
                                end,
                            })
                        end or nil,
                        separator = _i == #user_presets,
                    })
                end

                local footer_presets = require("modules/reader/patches/reader_footer_presets")
                for _i, preset in ipairs(footer_presets) do
                    table.insert(presets_items, {
                        text_func = function()
                            local active = PresetStore.getActivePreset("reader")
                            local prefix = active == preset.name and "* " or ""
                            return prefix .. _(preset.name)
                        end,
                        callback = function(touchmenu_instance)
                            apply_footer_preset(preset)
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end,
                    })
                end
                return presets_items
            end,
        }
    end

    -- -------------------------------------------------------------------------
    -- Font (passthrough to KOReader's font menu)
    -- -------------------------------------------------------------------------

    table.insert(items, {
        text = _("Font"),
        enabled_func = function()
            local ReaderUI = require("apps/reader/readerui")
            local ui = ReaderUI.instance
            return ui ~= nil and ui.view ~= nil and ui.view.footer ~= nil
        end,
        sub_item_table_func = function()
            local ReaderUI = require("apps/reader/readerui")
            local ui = ReaderUI.instance
            if not (ui and ui.font) then return {} end
            local mock = {}
            ui.font:addToMainMenu(mock)
            if not mock.change_font then return {} end
            local entry = mock.change_font
            if entry.sub_item_table_func then
                return entry.sub_item_table_func()
            end
            return entry.sub_item_table or {}
        end,
    })

    -- -------------------------------------------------------------------------
    -- Highlight / Lookup
    -- -------------------------------------------------------------------------

    table.insert(items, {
        text = _("Highlight / Lookup"),
        sub_item_table = {
            make_enable_feature_item("dict_quick_lookup", _("Zen quick lookup")),
            make_enable_feature_item("highlight_lookup", _("Zen highlight menu")),
            {
                text = _("Highlight names"),
                sub_item_table_func = make_highlight_name_items,
            },
            {
                text = _("Show Wikipedia"),
                checked_func = function()
                    return type(config.highlight_lookup) == "table"
                        and config.highlight_lookup.show_wikipedia == true
                end,
                callback = function()
                    if type(config.highlight_lookup) ~= "table" then
                        config.highlight_lookup = {}
                    end
                    config.highlight_lookup.show_wikipedia =
                        config.highlight_lookup.show_wikipedia ~= true
                    plugin:saveConfig()
                end,
            },
            make_lookup_plugin_item("xray", "show_xray", _("Show X-Ray")),
            make_lookup_plugin_item("koassistant", "show_koassistant", _("Show KOAssistant")),
            make_lookup_plugin_item(
                "assistant",
                "show_ai_assistant",
                _("Show AI assistant"),
                _("Show a button for the Assistant plugin, if installed.")
            ),
            {
                text = _("Show other items"),
                help_text = _("Show other KOReader quick lookup options alongside Zen buttons."),
                checked_func = function()
                    return type(config.highlight_lookup) == "table"
                        and config.highlight_lookup.allow_unknown_items == true
                end,
                callback = function()
                    if type(config.highlight_lookup) ~= "table" then
                        config.highlight_lookup = {}
                    end
                    config.highlight_lookup.allow_unknown_items =
                        config.highlight_lookup.allow_unknown_items ~= true
                    plugin:saveConfig()
                end,
            },
        },
    })

    local chapter_time_formats = {
        { value = "full", text = T(_("%1 min left in chapter"), "5") },
        { value = "compact", text = T(_("%1 min left"), "5") },
        { value = "number", text = T(_("%1m"), 5) },
        { value = "koreader", text = "hh:mm" },
    }
    local chapter_time_format_items = {}
    for _i, entry in ipairs(chapter_time_formats) do
        local format = entry.value
        chapter_time_format_items[#chapter_time_format_items + 1] = {
            text = entry.text,
            radio = true,
            checked_func = function()
                return type(config.reader_footer) == "table"
                    and config.reader_footer.chapter_time_format == format
            end,
            callback = function()
                if type(config.reader_footer) ~= "table" then
                    config.reader_footer = {}
                end
                config.reader_footer.chapter_time_format = format
                plugin:saveConfig()
            end,
        }
    end
    table.insert(items, IconItem.decorate({
        text = _("Time until chapter end"),
        sub_item_table = chapter_time_format_items,
    }, icons.chapter_time_format))

    -- -------------------------------------------------------------------------
    -- Feature toggles
    -- -------------------------------------------------------------------------

    -- bottom swipe is forced on when page browser is active
    table.insert(items, IconItem.decorate({
        text = _("Enable bottom swipe"),
        checked_func = function()
            return config.features["reader_bottom_menu"] == true
                or config.features["page_browser"] == true
        end,
        enabled_func = function()
            return config.features["page_browser"] ~= true
        end,
        callback = function()
            config.features["reader_bottom_menu"] = config.features["reader_bottom_menu"] ~= true
            save_and_apply("reader_bottom_menu")
        end,
    }, icons.bottom_swipe))
    -- Enabling the page browser forces the bottom swipe on.
    local function make_page_browser_font_size_item(key, section)
        return {
            text_func = function()
                local cfg = type(config.page_browser) == "table" and config.page_browser or {}
                return string.format("%s — %s %s", section, _("Font size:"), tonumber(cfg[key]) or 18)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local SpinWidget = require("ui/widget/spinwidget")
                local cfg = type(config.page_browser) == "table" and config.page_browser or {}
                UIManager:show(SpinWidget:new{
                    title_text = string.format("%s — %s", section, _("Font size")),
                    value = tonumber(cfg[key]) or 18,
                    value_min = 10,
                    value_max = 40,
                    default_value = 18,
                    callback = function(spin)
                        if type(config.page_browser) ~= "table" then config.page_browser = {} end
                        config.page_browser[key] = spin.value
                        plugin:saveConfig()
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end,
        }
    end

    table.insert(items, IconItem.decorate({
        text = _("Zen page browser"),
        checked_func = function()
            return config.features["page_browser"] == true
        end,
        checkmark_callback = function()
            config.features["page_browser"] = config.features["page_browser"] ~= true
            save_and_apply("page_browser")
        end,
        sub_item_table = {
            make_page_browser_font_size_item(
                "toc_font_size", _("Table of contents")
            ),
            make_page_browser_font_size_item(
                "bookmarks_font_size", _("Bookmarks")
            ),
        },
    }, icons.page_browser))
    table.insert(items, IconItem.decorate({
        text = _("Restore library location on exit"),
        checked_func = function()
            return config.features["restore_library_view"] == true
        end,
        callback = function()
            config.features["restore_library_view"] = config.features["restore_library_view"] ~= true
            save_and_apply("restore_library_view")
        end,
    }, icons.restore_library_location))

    -- -------------------------------------------------------------------------
    -- Bottom status bar (passthrough to KOReader's footer menu)
    -- -------------------------------------------------------------------------

    table.insert(items, {
        text = _("Bottom status bar"),
        checked_func = function()
            return dispatch_action.isBottomStatusBarVisible(plugin)
        end,
        checkmark_callback = function()
            dispatch_action.setBottomStatusBar(plugin,
                not dispatch_action.isBottomStatusBarVisible(plugin))
        end,
        enabled_func = function()
            local ReaderUI = require("apps/reader/readerui")
            return ReaderUI.instance ~= nil
        end,
        sub_item_table_func = function()
            local ReaderUI = require("apps/reader/readerui")
            local ui = ReaderUI.instance
            if not (ui and ui.view and ui.view.footer) then
                return {}
            end

            local ok_fc, FontChooser = pcall(require, "ui/widget/fontchooser")
            if not ok_fc then FontChooser = nil end

            local font_sub_items = {
                {
                    text_func = function()
                        local footer_settings = G_reader_settings:readSetting("footer") or {}
                        local size = footer_settings.text_font_size or 14
                        return string.format("%s %s", _("Font size:"), size)
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local SpinWidget = require("ui/widget/spinwidget")
                        local footer_settings = G_reader_settings:readSetting("footer") or {}
                        UIManager:show(SpinWidget:new{
                            title_text = _("Font size"),
                            value = footer_settings.text_font_size or 14,
                            value_min = 8,
                            value_max = 36,
                            default_value = 14,
                            callback = function(spin)
                                ui.view.footer.settings.text_font_size = spin.value
                                ui.view.footer:updateFooterFont()
                                ui.view.footer:refreshFooter(true, true)
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end,
                        })
                    end,
                },
            }
            if FontChooser then
                table.insert(font_sub_items, {
                    text_func = function()
                        local footer_settings = G_reader_settings:readSetting("footer") or {}
                        local face = footer_settings.text_font_face
                        local text = (not face or face == "NotoSans-Regular.ttf")
                            and _("default") or FontChooser.getFontNameText(face)
                        return string.format("%s %s", _("Font:"), text)
                    end,
                    keep_menu_open = true,
                    callback = function(touchmenu_instance)
                        local footer_settings = G_reader_settings:readSetting("footer") or {}
                        UIManager:show(FontChooser:new{
                            title = _("Font"),
                            font_file = footer_settings.text_font_face or "NotoSans-Regular.ttf",
                            default_font_file = "NotoSans-Regular.ttf",
                            callback = function(file)
                                ui.view.footer.settings.text_font_face = file
                                ui.view.footer:updateFooterFont()
                                ui.view.footer:refreshFooter(true, true)
                                if touchmenu_instance then touchmenu_instance:updateItems() end
                            end,
                        })
                    end,
                })
            end
            table.insert(font_sub_items, {
                text = _("Bold"),
                checked_func = function()
                    local footer_settings = G_reader_settings:readSetting("footer") or {}
                    return footer_settings.text_font_bold == true
                end,
                callback = function()
                    ui.view.footer.settings.text_font_bold = not ui.view.footer.settings.text_font_bold
                    ui.view.footer:updateFooterFont()
                    ui.view.footer:refreshFooter(true, true)
                end,
            })
            local ok_fc_default = pcall(require, "ui/widget/fontchooser")
            if ok_fc_default then
                table.insert(font_sub_items, {
                    text = _("Use default font"),
                    callback = function(touchmenu_instance)
                        ui.view.footer.settings.text_font_face = "NotoSans-Regular.ttf"
                        ui.view.footer.settings.text_font_size = 14
                        ui.view.footer.settings.text_font_bold = false
                        ui.view.footer:updateFooterFont()
                        ui.view.footer:refreshFooter(true, true)
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end
            local font_submenu = {
                text = _("Font"),
                sub_item_table = font_sub_items,
            }

            local mock = {}
            ui.view.footer:addToMainMenu(mock)
            local result = {}
            table.insert(result, build_footer_presets_item())
            table.insert(result, font_submenu)
            table.insert(result, {
                text = _("Hide in CBZ/PDF files"),
                checked_func = function()
                    return type(config.reader_footer) == "table"
                        and config.reader_footer.hide_in_cbz == true
                end,
                callback = function()
                    if type(config.reader_footer) ~= "table" then
                        config.reader_footer = {}
                    end
                    config.reader_footer.hide_in_cbz =
                        config.reader_footer.hide_in_cbz ~= true
                    plugin:saveConfig()
                    -- Apply immediately to the current open document.
                    local footer = ui and ui.view and ui.view.footer
                    if footer then
                        footer:applyFooterMode()
                        footer:refreshFooter(true, true)
                    end
                end,
            })
            if mock.status_bar and mock.status_bar.sub_item_table then
                for _i, item in ipairs(mock.status_bar.sub_item_table) do
                    table.insert(result, item)
                end
            end
            return result
        end,
    })

    IconItem.decorate(items[1], icons.settings_status)
    IconItem.decorate(items[2], icons.reader_themes)
    IconItem.decorate(items[3], icons.title)
    IconItem.decorate(items[4], icons.search)
    IconItem.decorate(items[9], icons.settings_status)

    return items
end

return M
