local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconButton = require("ui/widget/iconbutton")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputText = require("ui/widget/inputtext")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ClockTimer = require("common/clock_timer")
local SharedState = require("common/shared_state")
local IconItem = require("common/ui/icon_menu_item")
local ZenIconButton = require("common/ui/zen_icon_button")
local SolidCircle = require("common/ui/zen_solid_circle")
local TitleStyle = require("common/ui/zen_title_style")
local WidgetResources = require("common/widget_resources")
local utils = require("common/utils")
local _ = require("gettext")

local Screen = Device.screen

local ZenSettingsTitleBar = InputContainer:extend{
    title = "",
    back_visible = false,
    search_visible = true,
    query = "",
    search_expanded = false,
}

local function zen_icon_path()
    local root = require("common/plugin_root")
    return root and utils.resolveLocalIcon(root .. "/icons/", "zen_ui")
end

local function plugin_icon_path(icon_name)
    local root = require("common/plugin_root")
    local icons_dir = root and root .. "/icons/"
    return icons_dir and utils.resolveIcon(icons_dir, icon_name)
end

local function title_back_range(title_bar)
    if not title_bar.back_visible then return end
    local dimen = title_bar.title_container.dimen
    if not dimen then return end
    return Geom:new{
        x = dimen.x,
        y = dimen.y,
        w = math.min(dimen.w, title_bar.title_widget:getSize().w),
        h = dimen.h,
    }
end

local function default_status_factory(plugin)
    local settings_page = rawget(_G, "__ZEN_UI_SETTINGS_PAGE")
    plugin = plugin or rawget(_G, "__ZEN_UI_PLUGIN") or (settings_page and settings_page.plugin)
    local features = plugin and plugin.config and plugin.config.features
    if type(features) ~= "table" or features.status_bar ~= true then return nil end
    return function(width)
        local current_features = plugin and plugin.config and plugin.config.features
        if type(current_features) ~= "table" or current_features.status_bar ~= true then
            return nil
        end
        local build_status_row = SharedState.get(plugin, "buildStatusRow")
        if type(build_status_row) ~= "function" then return nil end
        local status_config = plugin.config.status_bar
        return build_status_row(width, {
            padding = Screen:scaleBySize(10),
            row_height = 18,
            show_bottom_border = type(status_config) == "table"
                and status_config.show_bottom_border ~= false,
        })
    end
end

local function refresh_status_on_clock_tick(owner)
    if not (owner and owner._zen_status_refresh) then return end
    local stack = UIManager._window_stack
    if not stack then return end
    for index = #stack, 1, -1 do
        local widget = stack[index] and stack[index].widget
        if widget == owner then
            owner:_zen_status_refresh()
            return
        end
        if widget and widget.covers_fullscreen then return end
    end
end

local function file_manager_dispatches_status_refresh()
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local file_manager = FileManager and FileManager.instance
    return file_manager and type(file_manager._updateStatusBar) == "function"
end

local function refresh_status_on_device_event(title_bar)
    if file_manager_dispatches_status_refresh() then return end
    local owner = title_bar and title_bar.show_parent
    if not (owner and owner._zen_status_title_bar == title_bar
            and type(owner._zen_status_refresh) == "function") then
        return
    end
    refresh_status_on_clock_tick(owner)
end

local function dismiss_keyboard_on_outside_tap(input)
    local keyboard = input and input.keyboard
    if not keyboard or keyboard._zen_settings_outside_tap then return end

    keyboard._zen_settings_outside_tap = true
    local orig_on_gesture = keyboard.onGesture
    keyboard.onGesture = function(self, ges)
        local handled = orig_on_gesture(self, ges)
        if handled or not (ges and ges.ges == "tap" and input:isKeyboardVisible()) then
            return handled
        end
        if self.dimen and ges.pos and ges.pos:notIntersectWith(self.dimen) then
            input:onCloseKeyboard()
            input:unfocus()
            return true
        end
        return false
    end
end

function ZenSettingsTitleBar:clearStatusRefresh()
    if self._zen_status_charging_refresh_timer then
        UIManager:unschedule(self._zen_status_charging_refresh_timer)
        self._zen_status_charging_refresh_timer = nil
    end
    local owner = self.show_parent
    if not owner or owner._zen_status_title_bar ~= self then return end
    ClockTimer.unbind(owner)
    owner._zen_status_refresh = nil
    owner._zen_status_clock_bound = nil
    owner._zen_status_title_bar = nil
end

function ZenSettingsTitleBar:onNetworkConnected()
    refresh_status_on_device_event(self)
end

ZenSettingsTitleBar.onNetworkDisconnected = ZenSettingsTitleBar.onNetworkConnected

function ZenSettingsTitleBar:onCharging()
    if file_manager_dispatches_status_refresh() then return end
    if self._zen_status_charging_refresh_timer then
        UIManager:unschedule(self._zen_status_charging_refresh_timer)
    end
    local title_bar = self
    self._zen_status_charging_refresh_timer = function()
        title_bar._zen_status_charging_refresh_timer = nil
        refresh_status_on_device_event(title_bar)
    end
    UIManager:scheduleIn(1.5, self._zen_status_charging_refresh_timer)
end

ZenSettingsTitleBar.onNotCharging = ZenSettingsTitleBar.onCharging

function ZenSettingsTitleBar:onSuspend()
    if not self._zen_status_charging_refresh_timer then return end
    UIManager:unschedule(self._zen_status_charging_refresh_timer)
    self._zen_status_charging_refresh_timer = nil
end

function ZenSettingsTitleBar:init()
    self.width = self.width or Screen:getWidth()
    self.show_parent = self.show_parent or self
    self:clearStatusRefresh()
    self.status_factory = self.status_factory or default_status_factory(self.plugin)

    local icon_size = TitleStyle.ICON_SIZE
    local button_padding = TitleStyle.BUTTON_PADDING
    local button_size = TitleStyle.BUTTON_SIZE
    local close_hitbox_inset = Screen:scaleBySize(4)
    local close_hitbox_left_inset = Screen:scaleBySize(4)
    local close_hitbox_bottom_inset = Screen:scaleBySize(12)
    local title_leading_padding = TitleStyle.TITLE_LEADING_PADDING
        or IconItem.getSettingsIconGap()
    self.title_leading_padding = title_leading_padding
    local root_icon_size = math.min(button_size, Screen:scaleBySize(32))
    local root_icon_inset = button_size - root_icon_size
    local root_icon_inset_start = math.floor(root_icon_inset / 2)
    local root_icon_inset_end = root_icon_inset - root_icon_inset_start
    local leading_width = TitleStyle.LEADING_WIDTH or IconItem.SETTINGS_ICON_WIDTH
    local left_padding = TitleStyle.LEFT_PADDING or IconItem.getSettingsLeftPadding()
    local right_padding = TitleStyle.RIGHT_PADDING
    local back_width = leading_width
    local show_search = self.search_expanded == true and self.search_visible ~= false
    local show_search_button = self.search_visible ~= false and not show_search
    local title_cap = math.min(Screen:scaleBySize(150), math.floor(self.width * 0.25))
    local title_width = title_cap
    self.action_button = nil
    local action_width = 0
    if self.action then
        if self.action.text then
            self.action_button = Button:new{
                text = self.action.text,
                height = self.action.height,
                bordersize = 0,
                radius = 0,
                padding_h = self.action.padding_h
                    or TitleStyle.ACTION_PADDING_H or Size.padding.default,
                padding_v = Size.padding.small,
                text_font_face = "smallinfofont",
                text_font_size = self.action.text_font_size
                    or TitleStyle.ACTION_FONT_SIZE or 18,
                text_font_bold = true,
                allow_flash = false,
                show_parent = self.show_parent,
                callback = self.action.callback,
            }
            if self.action.zen_button then
                local ZenButton = require("common/ui/zen_button")
                local radius = self.action.radius or Screen:scaleBySize(8)
                local border = Screen:scaleBySize(1)
                self.action_button._zen_filled = self.action.filled == true
                self.action_button.paintTo = function(button, bb, x, y)
                    button.dimen.x, button.dimen.y = x, y
                    local filled = button._zen_filled ~= (button._zen_focused == true)
                    local max_text_width = math.max(1,
                        button.dimen.w - 2 * (button.padding_h or 0))
                    if filled then
                        ZenButton.paintFilled(bb, x, y, button.dimen.w, button.dimen.h,
                            button.text, button.text_font_size, radius, max_text_width)
                    else
                        ZenButton.paintOutlined(bb, x, y, button.dimen.w, button.dimen.h,
                            button.text, button.text_font_size, radius, border, max_text_width)
                    end
                end
                self.action_button.onFocus = function(button)
                    button._zen_focused = true
                    UIManager:setDirty(button.show_parent, "fast", button.dimen)
                    return true
                end
                self.action_button.onUnfocus = function(button)
                    button._zen_focused = false
                    UIManager:setDirty(button.show_parent, "fast", button.dimen)
                    return true
                end
                self.action_button._doFeedbackHighlight = function() end
                self.action_button._undoFeedbackHighlight = function() end
            end
        else
            self.action_button = ZenIconButton:new{
                file = self.action.file,
                icon = self.action.icon,
                width = icon_size,
                height = icon_size,
                padding = button_padding,
                allow_flash = false,
                show_parent = self.show_parent,
                callback = self.action.callback,
            }
        end
        action_width = self.action_button:getSize().w
    end
    local trailing_controls = 1 + (self.action and 1 or 0)
        + (show_search_button and 1 or 0)
    local trailing_gap = TitleStyle.TRAILING_GAP or Screen:scaleBySize(4)
    local trailing_width = button_size + action_width
        + (show_search_button and button_size or 0)
        + (trailing_controls - 1) * trailing_gap
    local max_title_width = math.max(1,
        self.width - left_padding - right_padding - back_width - title_leading_padding
            - trailing_width)
    self._title_max_width = max_title_width
    if self.title_full_width and not show_search then
        title_cap = max_title_width
        title_width = title_cap
    elseif self.title_expand_to_fit and not show_search then
        local title_probe = TextWidget:new{
            text = self.title,
            face = TitleStyle.getTitleFace(),
            bold = true,
        }
        title_cap = math.max(1, math.min(max_title_width, title_probe:getSize().w))
        title_probe:free()
        title_width = title_cap
    end
    self.title_widget = TextWidget:new{
        text = self.title,
        face = TitleStyle.getTitleFace(),
        bold = true,
        max_width = title_cap,
    }
    local available_width = math.max(0,
        self.width - left_padding - right_padding - back_width - title_leading_padding
            - title_width - trailing_width)
    local search_outer_width = math.max(Screen:scaleBySize(100), available_width)
    local row_height = TitleStyle.ROW_HEIGHT
    local vertical_padding = TitleStyle.VERTICAL_PADDING

    local row = HorizontalGroup:new{ align = "center" }
    self._header_row = row
    self.back_button = IconButton:new{
        icon = "chevron.left",
        width = icon_size,
        height = icon_size,
        padding = button_padding,
        allow_flash = false,
        show_parent = self.show_parent,
        callback = function()
            if self.back_visible and self.back_callback then return self.back_callback() end
            return true
        end,
        hold_callback = function()
            if self.back_visible and self.back_hold_callback then
                return self.back_hold_callback()
            end
            return true
        end,
    }
    self.back_button.skip_paint = self.back_visible ~= true
    self.root_icon = ZenIconButton:new{
        file = zen_icon_path(),
        icon = "zen_ui",
        width = root_icon_size,
        height = root_icon_size,
        padding = 0,
        padding_top = root_icon_inset_start,
        padding_right = root_icon_inset_end,
        padding_bottom = root_icon_inset_end,
        padding_left = root_icon_inset_start,
        allow_flash = false,
        show_parent = self.show_parent,
    }
    self.root_icon.skip_paint = self.back_visible == true
    self.leading_container = CenterContainer:new{
        dimen = Geom:new{ w = leading_width, h = row_height },
        OverlapGroup:new{
            self.root_icon,
            self.back_button,
        },
    }
    table.insert(row, self.leading_container)
    table.insert(row, HorizontalSpan:new{ width = title_leading_padding })

    self.title_container = LeftContainer:new{
        dimen = Geom:new{ w = title_width, h = row_height },
        self.title_widget,
    }
    table.insert(row, self.title_container)
    self.ges_events.TapBackTitle = {
        GestureRange:new{
            ges = "tap",
            range = function() return title_back_range(self) end,
        },
    }
    self.ges_events.HoldBackTitle = {
        GestureRange:new{
            ges = "hold",
            range = function() return title_back_range(self) end,
        },
    }

    self.search_input = nil
    self.search_frame = nil
    self._title_filler = nil
    if show_search then
        local search_border = Screen:scaleBySize(2)
        local search_height = Screen:scaleBySize(36)
        local search_text_inset = math.floor(search_height / 2)
        local search_frame_padding = math.max(0,
            search_text_inset - search_border - Size.padding.small)
        local search_inner_width = math.max(1, search_outer_width - 2 * search_text_inset)
        self.search_input = InputText:new{
            text = self.query or "",
            hint = _("Search settings"),
            width = search_inner_width,
            height = math.max(1, search_height - 2 * (search_border + Size.padding.small)),
            padding = Size.padding.small,
            margin = 0,
            bordersize = 0,
            focused = false,
            parent = self.show_parent,
            enter_callback = function()
                self:closeSearchKeyboard()
            end,
        }
        dismiss_keyboard_on_outside_tap(self.search_input)
        self.search_input.edit_callback = function(edited)
            if edited and self.search_callback then
                self.query = self.search_input:getText()
                self.search_callback(self.query)
            end
        end
        local orig_on_key_press = self.search_input.onKeyPress
        self.search_input.onKeyPress = function(input, key)
            local at_end = key and key["Right"]
                and (input.charpos or 1) > #(input.charlist or {})
            if input.focused and key and (key["Back"] or at_end) then
                self:closeSearchKeyboard()
                if self.search_input_exit_callback then
                    self.search_input_exit_callback(input)
                end
                return true
            end
            return orig_on_key_press(input, key)
        end
        self.search_frame = SolidCircle:new{
            width = search_outer_width,
            height = search_height,
            radius = math.floor(search_height / 2),
            bordersize = search_border,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{
                    w = search_outer_width - 2 * search_border,
                    h = search_height - 2 * search_border,
                },
                HorizontalGroup:new{
                    HorizontalSpan:new{ width = search_frame_padding },
                    self.search_input,
                },
            },
        }
        table.insert(row, CenterContainer:new{
            dimen = Geom:new{ w = search_outer_width, h = row_height },
            self.search_frame,
        })
        self.ges_events.TapSearch = {
            GestureRange:new{
                ges = "tap",
                range = function() return self.search_frame.dimen end,
            },
        }
    else
        self._title_filler = HorizontalSpan:new{ width = available_width }
        table.insert(row, self._title_filler)
        self.ges_events.TapSearch = nil
    end
    self.search_button = nil
    if show_search_button then
        self.search_button = ZenIconButton:new{
            file = plugin_icon_path("quick_search"),
            icon = "appbar.search",
            width = icon_size,
            height = icon_size,
            padding = button_padding,
            allow_flash = false,
            show_parent = self.show_parent,
            callback = function() return self:openSearch() end,
        }
    end

    self.close_button = IconButton:new{
        icon = "close",
        width = icon_size,
        height = icon_size,
        padding_top = button_padding + close_hitbox_inset,
        padding_right = button_padding + close_hitbox_inset,
        padding_bottom = button_padding + close_hitbox_inset + close_hitbox_bottom_inset,
        padding_left = button_padding + close_hitbox_inset + close_hitbox_left_inset,
        overlap_offset = {
            -(close_hitbox_inset + close_hitbox_left_inset),
            -close_hitbox_inset,
        },
        allow_flash = false,
        show_parent = self.show_parent,
        callback = function()
            if self.search_expanded then
                if self.search_close_callback then return self.search_close_callback() end
                self:collapseSearch()
                return true
            end
            if self.close_callback then return self.close_callback() end
            return true
        end,
    }
    local trailing_buttons = {}
    if self.action_button then table.insert(trailing_buttons, self.action_button) end
    if self.search_button then table.insert(trailing_buttons, self.search_button) end
    table.insert(trailing_buttons, OverlapGroup:new{
        dimen = Geom:new{ w = button_size, h = button_size },
        allow_mirroring = false,
        self.close_button,
    })
    for index, button in ipairs(trailing_buttons) do
        if index > 1 then table.insert(row, HorizontalSpan:new{ width = trailing_gap }) end
        table.insert(row, button)
    end

    self.status_widget = nil
    local vertical_group = VerticalGroup:new{}
    if type(self.status_factory) == "function" then
        local ok, status_widget = pcall(self.status_factory, self.width)
        if ok and status_widget then
            self.status_widget = status_widget
        end
    end
    if self.status_widget then
        table.insert(vertical_group, VerticalSpan:new{ width = vertical_padding })
        table.insert(vertical_group, self.status_widget)
    end
    table.insert(vertical_group, VerticalSpan:new{ width = vertical_padding })
    self._header_group = HorizontalGroup:new{
        HorizontalSpan:new{ width = left_padding },
        row,
        HorizontalSpan:new{ width = right_padding },
    }
    table.insert(vertical_group, self._header_group)
    table.insert(vertical_group, VerticalSpan:new{ width = vertical_padding })
    table.insert(vertical_group, LineWidget:new{
        dimen = Geom:new{ w = self.width, h = TitleStyle.DIVIDER_HEIGHT },
        background = TitleStyle.DIVIDER_COLOR,
    })
    self._vertical_group = vertical_group
    self[1] = FrameContainer:new{
        width = self.width,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        vertical_group,
    }
    self.dimen = self[1]:getSize()
    if self.status_widget and self.show_parent then
        local title_bar = self
        self.show_parent._zen_status_title_bar = self
        self.show_parent._zen_status_refresh = function(owner)
            if title_bar:refreshStatus() then
                UIManager:setDirty(owner, "ui", title_bar.dimen)
            end
        end
        self.show_parent._zen_status_clock_bound = true
        ClockTimer.bind(self.show_parent, refresh_status_on_clock_tick)
    end
end

function ZenSettingsTitleBar:onTapSearch(arg, ges)
    if self.search_input and self.search_input.onTapTextBox then
        return self.search_input:onTapTextBox(arg, ges)
    end
    return false
end

function ZenSettingsTitleBar:onTapBackTitle()
    if not (self.back_visible and self.back_callback) then return false end
    self.back_callback()
    return true
end

function ZenSettingsTitleBar:onHoldBackTitle()
    if not (self.back_visible and self.back_hold_callback) then return false end
    self.back_hold_callback()
    return true
end

function ZenSettingsTitleBar:onGesture(ges)
    if InputContainer.onGesture(self, ges) then return true end
    local dimen = self.dimen
    local pos = ges and ges.pos
    local in_header = dimen and pos
        and pos.x >= dimen.x and pos.x < dimen.x + dimen.w
        and pos.y >= dimen.y and pos.y < dimen.y + dimen.h
    if in_header and (ges.ges == "tap" or ges.ges == "swipe") then return false end
    return in_header or false
end

function ZenSettingsTitleBar:closeSearchKeyboard()
    if not self.search_input then return false end
    local keyboard_was_visible = self.search_input:isKeyboardVisible()
    if keyboard_was_visible then self.search_input:onCloseKeyboard() end
    self.search_input:unfocus()
    return keyboard_was_visible
end

function ZenSettingsTitleBar:openSearch()
    if self.search_expanded or self.search_visible == false then return true end
    self.search_expanded = true
    self:clear()
    self:init()
    if self.search_opened_callback then
        self.search_opened_callback(self.search_input)
    end
    UIManager:setDirty(self.show_parent, "ui", self.dimen)
    UIManager:nextTick(function()
        local input = self.search_input
        if not input then return end
        input:focus()
        if not ((Device:hasKeyboard() or Device:hasScreenKB())
                and G_reader_settings:nilOrFalse("virtual_keyboard_enabled")) then
            input:onShowKeyboard()
        end
    end)
    return true
end

function ZenSettingsTitleBar:collapseSearch()
    if not self.search_expanded then return false end
    self:closeSearchKeyboard()
    self.search_expanded = false
    self.query = ""
    self:clear()
    self:init()
    UIManager:setDirty(self.show_parent, "ui", self.dimen)
    return true
end

function ZenSettingsTitleBar:onTextInput(text)
    if self.search_input and self.search_input.focused then
        return self.search_input:onTextInput(text)
    end
    return false
end

function ZenSettingsTitleBar:getHeight()
    return self.dimen.h
end

function ZenSettingsTitleBar:setState(title, back_visible, search_visible)
    search_visible = search_visible ~= false
    if self.title_expand_to_fit and not self.search_expanded and title ~= self.title then
        self.title = title
        self.back_visible = back_visible == true
        self.search_visible = search_visible
        if self.back_button then self.back_button.skip_paint = not self.back_visible end
        if self.root_icon then self.root_icon.skip_paint = self.back_visible end
        if self.search_button then self.search_button.skip_paint = not self.search_visible end
        local title_probe = TextWidget:new{
            text = title,
            face = IconItem.getSettingsFace(),
            bold = true,
        }
        local title_width = math.max(1,
            math.min(self._title_max_width, title_probe:getSize().w))
        title_probe:free()
        self.title_widget:setMaxWidth(title_width)
        self.title_widget:setText(title)
        self.title_container.dimen.w = title_width
        if self._title_filler then
            self._title_filler.width = self._title_max_width - title_width
        end
        if self._header_row and self._header_row.resetLayout then
            self._header_row:resetLayout()
        end
        if self._header_group and self._header_group.resetLayout then
            self._header_group:resetLayout()
        end
        if self._vertical_group and self._vertical_group.resetLayout then
            self._vertical_group:resetLayout()
        end
        UIManager:setDirty(self.show_parent, "ui", self.dimen)
        return
    end
    if self.search_expanded and not search_visible then
        self:closeSearchKeyboard()
        self.search_expanded = false
        self.title = title
        self.back_visible = back_visible == true
        self.search_visible = search_visible
        self.query = ""
        self:clear()
        self:init()
        return
    end
    self.title = title
    self.back_visible = back_visible == true
    self.search_visible = search_visible
    if self.title_widget then self.title_widget:setText(title) end
    if self.back_button then self.back_button.skip_paint = not self.back_visible end
    if self.root_icon then self.root_icon.skip_paint = self.back_visible end
    if self.search_button then self.search_button.skip_paint = not self.search_visible end
end

function ZenSettingsTitleBar:setTitle(title)
    self.title = title
    if self.title_widget then self.title_widget:setText(title) end
end

function ZenSettingsTitleBar:setQuery(query)
    self.query = query or ""
    if self.search_input and self.search_input:getText() ~= self.query then
        self.search_input:setText(self.query)
    end
end

function ZenSettingsTitleBar:setAction(action)
    local old_key = self.action and (self.action.text or self.action.file or self.action.icon)
    local new_key = action and (action.text or action.file or action.icon)
    self.action = action
    if old_key == new_key and (self.action_button or action == nil) then
        if self.action_button then self.action_button.callback = action.callback end
        return
    end
    self:clear()
    self:init()
end

function ZenSettingsTitleBar:refreshStatus()
    if type(self.status_factory) ~= "function" then return false end
    local ok, status_widget = pcall(self.status_factory, self.width)
    if not (ok and status_widget) then
        self:clearStatusRefresh()
        return false
    end
    if not self.status_widget then
        self:clear()
        self:init()
        return self.status_widget ~= nil
    end
    WidgetResources.replaceChild(self._vertical_group, 2, status_widget)
    self.status_widget = status_widget
    self.dimen = self[1]:getSize()
    return true
end

local function focus_controls(title_bar)
    local controls = {}
    local function append(control)
        if control and not control.skip_paint then controls[#controls + 1] = control end
    end
    append(title_bar.back_button)
    append(title_bar.search_input)
    append(title_bar.search_button)
    append(title_bar.action_button)
    append(title_bar.close_button)
    return controls
end

function ZenSettingsTitleBar:generateHorizontalLayout()
    return { focus_controls(self) }
end

function ZenSettingsTitleBar:generateVerticalLayout()
    local layout = {}
    for control_i, control in ipairs(focus_controls(self)) do
        layout[control_i] = { control }
    end
    return layout
end

function ZenSettingsTitleBar:containsFocus(control)
    if not control then return false end
    for _control_i, candidate in ipairs(focus_controls(self)) do
        if candidate == control then return true end
    end
    return false
end

function ZenSettingsTitleBar:installFocusLayout(owner)
    if not (owner and type(owner.layout) == "table") then return end

    local row = self:generateHorizontalLayout()[1]
    row._zen_settings_titlebar = true
    for index, existing in ipairs(owner.layout) do
        if existing._zen_settings_titlebar then
            owner.layout[index] = row
            return row
        end
    end

    table.insert(owner.layout, 1, row)
    if owner.selected then
        owner.selected.y = (owner.selected.y or 1) + 1
    end
    return row
end

return ZenSettingsTitleBar
