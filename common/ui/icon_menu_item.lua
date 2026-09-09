local Blitbuffer = require("ffi/blitbuffer")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local CheckMark = require("ui/widget/checkmark")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RadioMark = require("ui/widget/radiomark")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UnderlineContainer = require("ui/widget/container/underlinecontainer")
local VerticalGroup = require("ui/widget/verticalgroup")
local ZenToggle = require("common/ui/zen_toggle")

local Screen = Device.screen

local M = {}

local DEFAULT_WIDTH = Screen:scaleBySize(30)
M.SETTINGS_ROW_SCALE = 1.15

local function settings_size(size)
    return Screen:scaleBySize(math.floor(size * M.SETTINGS_ROW_SCALE + 0.5))
end

M.SETTINGS_ROW_HEIGHT = settings_size(60)
M.SETTINGS_ICON_WIDTH = settings_size(54)
M.SETTINGS_TOGGLE_WIDTH = settings_size(44)
M.SETTINGS_TOGGLE_HEIGHT = settings_size(22)
M.SETTINGS_CARET_SIZE = settings_size(22)
M.SETTINGS_TITLE_FONT_SIZE = 18

function M.getSettingsFontSize()
    local settings = rawget(_G, "G_reader_settings")
    local perpage = 14
    if settings and type(settings.readSetting) == "function" then
        perpage = tonumber(settings:readSetting("items_per_page")) or perpage
        local configured = tonumber(settings:readSetting("items_font_size"))
        if configured then
            return math.floor(configured * M.SETTINGS_ROW_SCALE + 0.5)
        end
    end
    return math.floor(require("ui/widget/menu").getItemFontSize(perpage)
        * M.SETTINGS_ROW_SCALE + 0.5)
end

function M.getSettingsRowHeight()
    return M.SETTINGS_ROW_HEIGHT
end

function M.getSettingsLeftPadding()
    return Size.padding.large + Size.padding.fullscreen
end

function M.getSettingsIconGap()
    return Size.padding.default
end

function M.getSettingsFace(fallback)
    return Font:getFace("smallinfofont", M.getSettingsFontSize())
        or fallback or Font:getFace("smallinfofont")
end

function M.getItemFace(item, fallback)
    local face = M.getSettingsFace(fallback)
    if type(item) == "table" and type(item.font_func) == "function" then
        return item.font_func(face.orig_size) or face
    end
    return face
end

function M.getSettingsIconFace(face)
    face = face or M.getSettingsFace()
    return Font:getFace(
        face.orig_font or "smallinfofont",
        math.floor((face.orig_size or M.getSettingsFontSize()) * 1.25 + 0.5)
    ) or face
end

function M.decorate(item, glyph, width)
    item = item or {}
    item.icon_glyph = glyph
    item.icon_width = width or item.icon_width or DEFAULT_WIDTH
    return item
end

function M.text(glyph, text, item)
    item = item or {}
    item.text = text
    return M.decorate(item, glyph)
end

function M.textFunc(glyph, text_func, item)
    item = item or {}
    item.text_func = text_func
    return M.decorate(item, glyph)
end

function M.getWidth(item)
    return item and item.icon_width or DEFAULT_WIDTH
end

function M.makeState(glyph, width, height, face)
    width = width or DEFAULT_WIDTH
    height = height or width
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = height },
        TextWidget:new{
            text = glyph,
            face = face or Font:getFace("smallinfofont"),
        },
    }
end

function M.enableFullRowFocus(frame, unfocused_invert)
    local orig_on_focus = frame.onFocus
    local orig_on_unfocus = frame.onUnfocus
    frame.invert = unfocused_invert == true
    frame.onFocus = function(self)
        local handled = orig_on_focus(self)
        self.invert = true
        return handled or true
    end
    frame.onUnfocus = function(self)
        local handled = orig_on_unfocus(self)
        self.invert = unfocused_invert == true
        return handled or true
    end
    return frame
end

local function get_menu_icon_width(menu)
    local width
    for _i, item in ipairs(menu and menu.item_table or {}) do
        if type(item) == "table" and item.icon_glyph then
            width = math.max(width or 0, M.getWidth(item))
        end
    end
    return width
end

local function rebuild_touch_menu_item(row)
    local item = row and row.item
    if not (item and row.dimen) then return end

    local icon_w = item.icon_glyph and M.getWidth(item) or get_menu_icon_width(row.menu)
    if not icon_w or (not item.icon_glyph and not item.checked_func) then return end

    local item_enabled = item.enabled
    if item.enabled_func then
        item_enabled = item.enabled_func()
    end
    local text_max_width = row.dimen.w - 2 * Size.padding.default - icon_w
    local text = require("ui/widget/menu").getMenuText(item)
    local face = row.face
    local forced_baseline, forced_height
    if item.font_func then
        face = item.font_func(row.face.orig_size)
        if face then
            local w = TextWidget:new{ text = "", face = row.face }
            forced_baseline = w:getBaseline()
            forced_height = w:getSize().h
            w:free()
        else
            face = row.face
        end
    end
    local state_widget
    if item.checked_func then
        local item_checked = item.checked_func()
        local checkmark_widget = item.radio and RadioMark:new{
            checkable = true,
            checked = item_checked,
            enabled = item_enabled,
        } or CheckMark:new{
            checkable = true,
            checked = item_checked,
            enabled = item_enabled,
        }
        state_widget = CenterContainer:new{
            dimen = Geom:new{ w = icon_w, h = row.dimen.h },
            checkmark_widget,
        }
    else
        state_widget = M.makeState(item.icon_glyph, icon_w, row.dimen.h, face)
    end
    local text_widget = TextWidget:new{
        text = text,
        max_width = text_max_width,
        fgcolor = item_enabled ~= false and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        face = face,
        forced_baseline = forced_baseline,
        forced_height = forced_height,
    }
    row.text_truncated = text_widget:isTruncated()
    row.item_frame = FrameContainer:new{
        width = row.dimen.w,
        bordersize = 0,
        color = Blitbuffer.COLOR_BLACK,
        HorizontalGroup:new{
            align = "center",
            state_widget,
            text_widget,
        },
    }

    row._underline_container = UnderlineContainer:new{
        vertical_align = "center",
        dimen = row.dimen:copy(),
        line_width = row.item_frame:getSize().w,
        row.item_frame,
    }
    row[1] = row._underline_container
end

local function settings_control_widget(item, enabled)
    if type(item.checked_func) == "function" then
        if item.radio == true then
            return RadioMark:new{
                checkable = true,
                checked = item.checked_func() == true,
                enabled = enabled,
            }
        end
        return ZenToggle:new{
            width = M.SETTINGS_TOGGLE_WIDTH,
            height = M.SETTINGS_TOGGLE_HEIGHT,
            value_func = function()
                return item.checked_func() == true
            end,
        }
    end
end

local function settings_icon_widget(item, height, face)
    if item.icon_glyph then
        return M.makeState(item.icon_glyph, M.SETTINGS_ICON_WIDTH, height,
            M.getSettingsIconFace(face))
    end
end

local function rebuild_settings_menu_item(row)
    local item = row and row.entry
    if not (item and item._zen_settings_row and row.dimen) then return end

    local enabled = item.enabled ~= false
    if type(item.enabled_func) == "function" then
        enabled = item.enabled_func() ~= false
    end
    local visual_enabled = enabled and item.dim ~= true
    local face = M.getItemFace(item, row.face)
    local left_padding = M.getSettingsLeftPadding()
    local right_padding = Size.padding.large + Size.padding.default
    local icon_widget = settings_icon_widget(item, row.dimen.h, face)
    local control_widget = settings_control_widget(item, visual_enabled)
    local icon_gap = M.getSettingsIconGap()
    local left_icon_w = M.SETTINGS_ICON_WIDTH + icon_gap
    local right_controls = HorizontalGroup:new{ align = "center" }
    if control_widget then
        table.insert(right_controls, control_widget)
        table.insert(right_controls, HorizontalSpan:new{ width = Size.padding.large })
    end
    if item._zen_has_submenu then
        table.insert(right_controls, IconWidget:new{
            icon = item._zen_caret_icon or "chevron.right",
            width = M.SETTINGS_CARET_SIZE,
            height = M.SETTINGS_CARET_SIZE,
        })
    elseif control_widget then
        table.insert(right_controls, HorizontalSpan:new{ width = M.SETTINGS_CARET_SIZE })
    end
    table.insert(right_controls, HorizontalSpan:new{ width = right_padding })
    local right_controls_w = right_controls:getSize().w
    if control_widget then
        local control_w = control_widget:getSize().w
        local control_right = row.dimen.w - right_padding
        if item._zen_has_submenu then
            control_right = control_right - M.SETTINGS_CARET_SIZE - Size.padding.large
        end
        item._zen_settings_control_bounds = {
            left = (control_right - control_w) / row.dimen.w,
            right = control_right / row.dimen.w,
        }
    else
        item._zen_settings_control_bounds = nil
    end
    local text_w = math.max(1, row.dimen.w - left_padding - left_icon_w
        - right_controls_w - icon_gap)
    local text = item._zen_display_text
        or (type(item.text_func) == "function" and item.text_func() or item.text)
        or ""
    local has_breadcrumb = type(item._zen_settings_breadcrumb) == "string"
        and item._zen_settings_breadcrumb ~= ""
    local text_widget = TextWidget:new{
        text = text,
        max_width = text_w,
        fgcolor = visual_enabled and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
        face = face,
        bold = item._zen_primary_bold == true,
        padding = has_breadcrumb and 0 or nil,
    }
    row.text_truncated = text_widget:isTruncated()
    item._zen_settings_text_truncated = row.text_truncated
    row._zen_settings_style = {
        row_height = row.dimen.h,
        font_size = face.orig_size,
        icon_width = M.SETTINGS_ICON_WIDTH,
        toggle_width = M.SETTINGS_TOGGLE_WIDTH,
        toggle_height = M.SETTINGS_TOGGLE_HEIGHT,
        caret_size = M.SETTINGS_CARET_SIZE,
    }

    local text_group = VerticalGroup:new{
        align = "left",
        text_widget,
    }
    if has_breadcrumb then
        table.insert(text_group, TextWidget:new{
            text = item._zen_settings_breadcrumb,
            max_width = text_w,
            fgcolor = visual_enabled and item._zen_value_black == true
                and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
            face = Font:getFace("xx_smallinfofont"),
            padding = 0,
        })
    end

    local left_items = {
        align = "center",
        HorizontalSpan:new{ width = left_padding },
    }
    table.insert(left_items, icon_widget or HorizontalSpan:new{ width = M.SETTINGS_ICON_WIDTH })
    table.insert(left_items, HorizontalSpan:new{ width = icon_gap })
    table.insert(left_items, text_group)
    local custom_content = type(item._zen_settings_content_func) == "function"
        and item._zen_settings_content_func(
            row.dimen.w - right_controls_w, row.dimen.h, face, visual_enabled)
    if custom_content and type(text_group.free) == "function" then text_group:free() end
    local left = LeftContainer:new{
        dimen = Geom:new{ w = row.dimen.w, h = row.dimen.h },
        custom_content or HorizontalGroup:new(left_items),
    }
    local content = OverlapGroup:new{
        dimen = Geom:new{ w = row.dimen.w, h = row.dimen.h },
        left,
    }
    if control_widget or item._zen_has_submenu then
        table.insert(content, RightContainer:new{
            dimen = Geom:new{ w = row.dimen.w, h = row.dimen.h },
            right_controls,
        })
    end

    row.item_frame = FrameContainer:new{
        width = row.dimen.w,
        padding = 0,
        margin = 0,
        bordersize = 0,
        focusable = true,
        focus_border_size = Size.border.thin,
        focus_inner_border = true,
        content,
    }
    if item._zen_focus_border_only ~= true then
        M.enableFullRowFocus(row.item_frame)
    end
    row._zen_settings_divider = LineWidget:new{
        dimen = Geom:new{ w = row.dimen.w, h = Size.line.thin },
        background = Blitbuffer.COLOR_LIGHT_GRAY,
    }
    -- MenuItem uses this container's painted coordinates for tap feedback.
    -- UnderlineContainer keeps those coordinates current; OverlapGroup does not.
    row._underline_container = UnderlineContainer:new{
        linesize = 0,
        padding = 0,
        OverlapGroup:new{
            dimen = row.dimen:copy(),
            row.item_frame,
            BottomContainer:new{
                dimen = row.dimen:copy(),
                row._zen_settings_divider,
            },
        },
    }
    row[1] = row._underline_container
end

local function prepare_menu_items(menu)
    local items = menu and menu.item_table
    if type(items) ~= "table" then return end
    local width
    for _i, item in ipairs(items) do
        if type(item) == "table" and item.icon_glyph and not item._zen_settings_row then
            width = math.max(width or 0, M.getWidth(item))
        end
    end
    if width then
        if menu._zen_icon_item_base_state_w == nil then
            menu._zen_icon_item_base_state_w = menu.state_w or false
        end
        menu.state_w = math.max(menu._zen_icon_item_base_state_w or 0, width)
        local height = menu.item_dimen and menu.item_dimen.h or width
        local face = Font:getFace(menu.font or "smallinfofont", menu.font_size)
        for _i, item in ipairs(items) do
            if type(item) == "table" and item.icon_glyph and not item._zen_settings_row then
                item.state = M.makeState(item.icon_glyph, width, height, face)
            end
        end
    elseif menu._zen_icon_item_base_state_w ~= nil then
        menu.state_w = menu._zen_icon_item_base_state_w or nil
        menu._zen_icon_item_base_state_w = nil
    end
end

function M.installMenuPatch()
    local Menu = require("ui/widget/menu")
    if not Menu._zen_icon_item_patched then
        Menu._zen_icon_item_patched = true
        local orig_updateItems = Menu.updateItems
        local MenuItem
        for i = 1, 64 do
            local name, value = debug.getupvalue(orig_updateItems, i)
            if name == nil then break end
            if name == "MenuItem" then
                MenuItem = value
                break
            end
        end
        if MenuItem and type(MenuItem.init) == "function" then
            local orig_menu_item_init = MenuItem.init
            MenuItem.init = function(self, ...)
                local result = orig_menu_item_init(self, ...)
                rebuild_settings_menu_item(self)
                return result
            end
        end
        local orig_get_menu_text = Menu.getMenuText
        Menu.getMenuText = function(item)
            if type(item) == "table" and item._zen_settings_row then
                return item._zen_display_text
                    or (type(item.text_func) == "function" and item.text_func() or item.text)
                    or ""
            end
            return orig_get_menu_text(item)
        end
        Menu.updateItems = function(self, ...)
            prepare_menu_items(self)
            return orig_updateItems(self, ...)
        end
    end

    local ok_touch, TouchMenu = pcall(require, "ui/widget/touchmenu")
    if not ok_touch or TouchMenu._zen_icon_item_patched then return end
    local TouchMenuItem
    for i = 1, 64 do
        local name, value = debug.getupvalue(TouchMenu.updateItems, i)
        if name == nil then break end
        if name == "TouchMenuItem" then
            TouchMenuItem = value
            break
        end
    end
    if not (TouchMenuItem and type(TouchMenuItem.init) == "function") then return end
    TouchMenu._zen_icon_item_patched = true
    local orig_touch_init = TouchMenuItem.init
    TouchMenuItem.init = function(self, ...)
        local result = orig_touch_init(self, ...)
        rebuild_touch_menu_item(self)
        return result
    end
end

return M
