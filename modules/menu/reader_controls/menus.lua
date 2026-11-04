local Settings = require("modules/menu/reader_controls/settings")
local Profiles = require("modules/menu/reader_controls/profiles")
local Themes = require("common/reader_themes")
local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local util = require("util")
local _ = require("gettext")

local M = {}

local function show(title, items)
    return require("common/ui/zen_arrange_list").show{
        title = title, item_table = items, allow_arrange = false, menu_mode = true,
    }
end

function M.fontFamily(reader, anchor, refresh)
    local font = reader.font
    if not font.face_table or font.face_table.needs_refresh then font:setupFaceMenuTable() end
    local buttons, faces, dialog, selected = {}, {}, nil, 1
    for _i, face in ipairs(font.face_table) do
        if face.menu_item_id then
            if face.checked_func() then selected = #buttons + 1 end
            local sample_face = face.font_func and face.font_func(24)
            faces[#buttons + 1] = sample_face
            buttons[#buttons + 1] = {{
                text = (face.checked_func() and "✓ " or "") .. face.text_func(),
                align = "left",
                font_face = sample_face and sample_face.orig_font, font_size = 24, font_bold = false,
                callback = function()
                    UIManager:close(dialog)
                    face.callback()
                    font:onSaveSettings()
                    refresh()
                end,
                hold_callback = function() if face.hold_callback then face.hold_callback(dialog) end end,
            }}
        end
    end
    dialog = require("common/ui/zen_anchored_menu").new{
        title = _("Font family"), buttons = buttons,
        rows_per_page = 6,
        anchor = function() return anchor end,
    }
    for i, row in ipairs(dialog.buttontable and dialog.buttontable.buttons_layout or {}) do
        if faces[i] then
            row[1].label_widget:free()
            row[1].label_widget.face = faces[i]
        end
    end
    if #buttons > 6 and not dialog.cropping_widget then
        local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
        local table_widget = dialog.buttontable
        table_widget:setupGridScrollBehaviour()
        local grid = table_widget:getStepScrollGrid()
        dialog.cropping_widget = ScrollableContainer:new{
            dimen = require("ui/geometry"):new{
                w = table_widget:getSize().w + ScrollableContainer:getScrollbarWidth(),
                h = grid[6].bottom + 1 - grid[1].top,
            },
            show_parent = dialog, step_scroll_grid = grid, table_widget,
        }
        local group = dialog.movable[1][1]
        group[3] = dialog.cropping_widget
        group:resetLayout()
    end
    dialog.updateItems = function() UIManager:close(dialog); M.fontFamily(reader, anchor, refresh) end
    UIManager:show(dialog)
    if dialog.layout and dialog.layout[selected] then dialog:moveFocusTo(1, selected) end
    return dialog
end

function M.defaults(reader, names)
    local selected, rows, items = {}, Settings.defaults(reader), {}
    for _i, name in ipairs(names or {}) do
        selected[name == "font_face" and "cre_font" or Settings.group(reader) .. "_" .. name] = true
    end
    local group = Settings.group(reader) == "copt" and _("Reflowable documents") or _("Fixed-layout documents")
    local function save(all, menu)
        local descriptions = {}
        for _i, row in ipairs(rows) do
            if all or selected[row.key] then
                descriptions[#descriptions + 1] = row.label .. ": " .. row.display
            end
        end
        if #descriptions == 0 then return end
        UIManager:show(ConfirmBox:new{
            text = group .. "\n\n" .. table.concat(descriptions, "\n") .. "\n\n"
                .. _("Existing book settings take precedence over these defaults."),
            ok_text = _("Save defaults"),
            ok_callback = function()
                Settings.saveDefaults(reader, all or selected)
                if menu then menu:closeMenu() end
            end,
        })
    end
    if names then return save(false) end
    items[#items + 1] = { text = _("Save selected"), keep_menu_open = true,
        callback = function(menu) save(false, menu) end }
    items[#items + 1] = { text = _("Save all"), keep_menu_open = true,
        callback = function(menu) save(true, menu) end }
    items[#items + 1] = { text = _("Cancel"), callback = function(menu) menu:closeMenu() end, separator = true }
    for _i, row in ipairs(rows) do
        local key = row.key
        items[#items + 1] = {
            text = row.label .. ": " .. row.display,
            checked_func = function() return selected[key] == true end,
            callback = function() selected[key] = not selected[key] end,
            keep_menu_open = true,
        }
    end
    return show(_("Defaults") .. " — " .. group, items)
end

function M.themeRows(reader, plugin, refresh)
    local mode = G_reader_settings:isTrue("night_mode") and "dark_mode" or "light_mode"
    local config = plugin.config
    local themes = config.reader_themes
    local selected = config.features.reader_themes and themes[mode] or "default"
    selected = selected or (mode == "dark_mode" and "dark_warm_gray" or "default")
    local rows = {}
    local function add(text, key)
        rows[#rows + 1] = { text = text, radio = true, checked = selected == key, theme_key = key,
            callback = function()
                config.features.reader_themes = true
                themes[mode] = key
                Themes.saveConfig(plugin)
                Themes.applyCurrent(plugin)
                reader:saveSettings()
                refresh()
            end }
    end
    for _i, entry in ipairs(Themes.builtinList()) do add(entry.text, entry.key) end
    local custom = themes.custom or {}
    local names = {}
    for key in pairs(custom) do names[#names + 1] = key end
    table.sort(names)
    for _i, key in ipairs(names) do
        add(custom[key].name or _("Custom theme"), key)
    end
    return rows
end

function M.saveProfile(reader, plugin, include_theme, name)
    local native = reader.profiles
    if not native then return end
    local function save(target)
        local profile = Profiles.capture(reader, plugin, target, include_theme)
        if native.data[target] then
            local snapshot = profile.settings.zen_reader
            local order = profile.settings.order
            profile.settings = util.tableDeepCopy(native.data[target].settings)
            profile.settings.order = order
            profile.settings.zen_reader = snapshot
        end
        native.data[target] = profile
        native.updated = true
        native:onFlushSettings()
    end
    if name then
        UIManager:show(ConfirmBox:new{ text = _("Update this profile from the current book settings?") .. "\n\n" .. name,
            ok_text = _("Update"), ok_callback = function() save(name) end })
    else
        native:editProfileName(save)
    end
end

function M.profileMenu(reader, plugin, name, include_theme)
    local items = {
        { text = _("Apply"), callback = function() reader.profiles:onProfileExecute(name, { qm_show = false }) end },
        { text = _("Update from current book"), callback = function()
            M.saveProfile(reader, plugin, include_theme, name)
        end },
    }
    for _i, item in ipairs(reader.profiles:getSubMenuItems()) do
        if item.name == name then
            for _j, child in ipairs(item.sub_item_table) do items[#items + 1] = child end
            break
        end
    end
    return show(name, items)
end

return M
