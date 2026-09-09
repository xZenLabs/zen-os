local Blitbuffer = require("ffi/blitbuffer")
local BD = require("ui/bidi")
local Device = require("device")
local Event = require("ui/event")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local CheckMark = require("ui/widget/checkmark")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RadioMark = require("ui/widget/radiomark")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local SortWidget = require("ui/widget/sortwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local _ = require("gettext")
local IconItem = require("common/ui/icon_menu_item")
local SettingsTitleBar = require("common/ui/zen_settings_titlebar")
local TruncatedTextMessage = require("common/ui/truncated_text_message")
local TopMenu = require("modules/global/patches/menu_top_swipe")
local ZenToggle = require("common/ui/zen_toggle")
local pager = require("common/ui/zen_pager")
local utils = require("common/utils")
local ArrangeState = require("common/arrange_state")
local DispatcherMenu = require("common/dispatcher_menu")

local M = {}
local show_submenu
local repopulate
local plus_icon_path
local cancel_item_drag_hold
local pending_callback_resume_path
local DRAG_UNFOCUS_DELAY = 0.1
local ITEM_DRAG_HOLD_DELAY = 0.25

local function background_refresh_count()
    local refreshes = UIManager._refresh_func_stack
    return type(refreshes) == "table" and #refreshes or nil
end

local function discard_background_refreshes(count)
    local refreshes = UIManager._refresh_func_stack
    if not (count and type(refreshes) == "table") then return end
    for i = #refreshes, count + 1, -1 do
        table.remove(refreshes, i)
    end
end

local function get_plus_icon_path()
    if plus_icon_path ~= nil then return plus_icon_path end
    plus_icon_path = false
    local ok_root, root = pcall(require, "common/plugin_root")
    if ok_root and root then
        plus_icon_path = utils.resolveLocalIcon(root .. "/icons/", "plus") or false
    end
    return plus_icon_path or nil
end

local function suppress_footer_button(button)
    if not button then return end
    button:disableWithoutDimming()
    button.callback = function() return true end
    button.onTapSelectButton = function() return true end
    button.onHoldSelectButton = function() return true end
    button.hidden = false
    button.skip_paint = true
    button:hide()
end

local function item_is_enabled(item)
    if type(item) ~= "table" or item.enabled == false then return false end
    if type(item.enabled_func) == "function" then
        return item.enabled_func() ~= false
    end
    return true
end

local function toggle_sort_item(sort_widget, item)
    if not (sort_widget and item and item.checked_func) then
        return false
    end
    if not item_is_enabled(item) then return false end
    if not ArrangeState.toggleItem(item) then return false end
    if sort_widget.marked and sort_widget.marked > 0 then
        sort_widget.marked = 0
    end
    sort_widget:_populateItems()
    return true
end

local function get_focused_item(sort_widget)
    local focused = sort_widget and sort_widget.getFocusItem and sort_widget:getFocusItem()
    return focused and focused.item
end

local function hide_button_icon(button)
    if not button then return end
    if button._zen_arrange_callback == nil then
        button._zen_arrange_callback = button.callback
        button._zen_arrange_on_tap = button.onTapSelectButton
        button._zen_arrange_on_hold = button.onHoldSelectButton
        button._zen_arrange_on_hold_release = button.onHoldReleaseSelectButton
    end
    button:disableWithoutDimming()
    button.callback = function() return true end
    button.onTapSelectButton = function() return true end
    button.onHoldSelectButton = function() return true end
    button.onHoldReleaseSelectButton = function() return true end
    button.hidden = false
    button.skip_paint = true
    button:hide()
end

local function restore_button_icon(button)
    if not button then return end
    button.skip_paint = false
    if button._zen_arrange_callback ~= nil then
        button.callback = button._zen_arrange_callback
        button.onTapSelectButton = button._zen_arrange_on_tap
        button.onHoldSelectButton = button._zen_arrange_on_hold
        button.onHoldReleaseSelectButton = button._zen_arrange_on_hold_release
    end
    button:show()
end

local function can_use_arrange_pager(sort_widget)
    return (sort_widget.pages or 0) > 1
end

local function update_arrange_pager_zones(sort_widget, paint_y, footer_h)
    local hit_h = pager.getChevronHitBottom(
        paint_y, footer_h, Device.screen:getHeight()
    ) - paint_y
    for _i, zone in ipairs(sort_widget._zen_arrange_pager_zones or {}) do
        zone.screen_zone.ratio_y = paint_y / Device.screen:getHeight()
        zone.screen_zone.ratio_h = hit_h / Device.screen:getHeight()
        local registered = sort_widget._zones and sort_widget._zones[zone.id]
        local range = registered and registered.gs_range and registered.gs_range.range
        if range then
            range.y = paint_y
            range.h = hit_h
        end
    end
end

local function install_arrange_pager_zones(sort_widget, bar_x, bar_w, footer_h)
    if sort_widget._zen_arrange_pager_zones then return end
    local screen_w = Device.screen:getWidth()
    local screen_h = Device.screen:getHeight()
    local footer_y = sort_widget.dimen.y + sort_widget.dimen.h - footer_h
    local chevron_w = pager.getChevronHitWidth(bar_w)
    local hit_h = pager.getChevronHitBottom(footer_y, footer_h, screen_h) - footer_y
    local function change_page(diff)
        if not can_use_arrange_pager(sort_widget) then return end
        local pages = sort_widget.pages
        local target = ((sort_widget.show_page - 1 + diff) % pages) + 1
        sort_widget:onGoToPage(target)
        return true
    end
    sort_widget._zen_arrange_pager_zones = {
        {
            id = "zen_arrange_pager_left_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = bar_x / screen_w,
                ratio_y = footer_y / screen_h,
                ratio_w = chevron_w / screen_w,
                ratio_h = hit_h / screen_h,
            },
            handler = function() return change_page(-1) end,
        },
        {
            id = "zen_arrange_pager_right_tap",
            ges = "tap",
            screen_zone = {
                ratio_x = (bar_x + bar_w - chevron_w) / screen_w,
                ratio_y = footer_y / screen_h,
                ratio_w = chevron_w / screen_w,
                ratio_h = hit_h / screen_h,
            },
            handler = function() return change_page(1) end,
        },
    }
    sort_widget:registerTouchZones(sort_widget._zen_arrange_pager_zones)
end

local function sync_pagination_footer(sort_widget)
    if not (sort_widget and sort_widget.page_info) then return end

    local has_pages = (sort_widget.pages or 0) > 1
    if has_pages then
        restore_button_icon(sort_widget.footer_left)
        restore_button_icon(sort_widget.footer_right)
    else
        hide_button_icon(sort_widget.footer_left)
        hide_button_icon(sort_widget.footer_right)
    end

    local page_info = sort_widget.page_info
    local show_footer = has_pages
    if page_info._zen_arrange_footer_visible == show_footer then return end
    page_info._zen_arrange_footer_visible = show_footer

    if page_info._zen_arrange_paint_to == nil then
        local original_paint_to = page_info.paintTo
        local bar_x, bar_w = pager.getFooterGeometry(
            sort_widget.dimen.x,
            sort_widget.dimen.w
        )
        install_arrange_pager_zones(sort_widget, bar_x, bar_w, page_info:getSize().h)
        page_info._zen_arrange_paint_to = function(self, bb, x, y)
            local perpage = tonumber(sort_widget.items_per_page) or 0
            local row_height = (tonumber(sort_widget.item_height) or 0)
                + (tonumber(sort_widget.item_margin) or 0)
            local title_height = sort_widget.title_bar and sort_widget.title_bar:getHeight() or 0
            local content_bottom = sort_widget.dimen.y + title_height + perpage * row_height
            local paint_y = pager.getCenteredFooterY(
                content_bottom,
                y,
                self:getSize().h,
                perpage > 0 and row_height > 0
            )
            if not can_use_arrange_pager(sort_widget) then
                return original_paint_to(self, bb, x, paint_y)
            end
            local footer_h = self:getSize().h
            update_arrange_pager_zones(sort_widget, paint_y, footer_h)
            pager.paint(
                bb,
                bar_x,
                paint_y,
                bar_w,
                footer_h,
                sort_widget.show_page,
                sort_widget.pages,
                "page_number"
            )
        end
    end

    local content = sort_widget[1] and sort_widget[1][1]
    local footer_group = content and content[2] and content[2][1]
    local footer_line = footer_group and footer_group[1]
    if footer_line then footer_line.style = "none" end

    if show_footer then
        page_info.paintTo = page_info._zen_arrange_paint_to
    else
        page_info.paintTo = function() end
    end
end

local function suppress_footer_page_button(sort_widget)
    local button = sort_widget and sort_widget.footer_page
    if not button then return end
    button.call_hold_input_on_tap = false
    button.tap_input = nil
    button.tap_input_func = nil
    button.hold_input = nil
    button.hold_input_func = nil
    button.callback = nil
    button:disableWithoutDimming()
    button.onTapSelectButton = function() return true end
    button.onHoldSelectButton = function() return true end
    button.onHoldReleaseSelectButton = function() return true end
    button.skip_paint = (sort_widget.pages or 0) <= 1
end

local function rebuild_icon_row(row)
    local item = row and row.item
    if not (item and row.width and row.height) then return end

    local item_checkable = false
    local item_checked = item.checked
    if item.checked_func then
        item_checkable = true
        item_checked = item.checked_func()
    end
    local item_disabled = item.dim == true or item_is_enabled(item) == false
    local toggle_h = IconItem.SETTINGS_TOGGLE_HEIGHT
    local check_w = IconItem.SETTINGS_TOGGLE_WIDTH
    if item_checkable then
        if item.radio == true then
            row.checkmark_widget = RadioMark:new{
                checkable = true,
                checked = item_checked == true,
                enabled = not item_disabled,
            }
        else
            row.checkmark_widget = ZenToggle:new{
                value = item_checked,
                width = check_w,
                height = toggle_h,
            }
        end
    else
        row.checkmark_widget = CheckMark:new{ checkable = false }
    end
    local left_padding = Size.padding.fullscreen
    local right_padding = Size.padding.default
    local icon_w = IconItem.SETTINGS_ICON_WIDTH
    local arrange_enabled = row.show_parent._zen_arrange_enabled == true
        and item.arrange_pinned_last ~= true
    local content_w = row.width - left_padding - right_padding
    local item_has_submenu = type(item.sub_item_table) == "table"
        or type(item.sub_item_table_func) == "function"
        or item._zen_settings_submenu == true
    local face = IconItem.getItemFace(item, item.face or row.face)
    local right_items = { align = "center" }
    if item_checkable then
        local toggle_control = row.checkmark_widget
        if arrange_enabled and Device:hasDPad() then
            local toggle_focus = FrameContainer:new{
                padding = 0,
                bordersize = 0,
                focusable = true,
                focus_border_size = Size.border.thick,
                focus_inner_border = true,
                toggle_control,
            }
            toggle_focus._zen_arrange_toggle = true
            toggle_focus._zen_arrange_row = row
            toggle_focus.item = item
            toggle_focus.index = row.index
            row._zen_arrange_toggle_focus = toggle_focus
            local orig_toggle_focus = toggle_focus.onFocus
            toggle_focus.onFocus = function(self)
                row.show_parent._zen_arrange_focus_column = 3
                return orig_toggle_focus(self)
            end
            table.insert(right_items, toggle_focus)
        else
            table.insert(right_items, toggle_control)
        end
    end
    if item_checkable and item_has_submenu then
        table.insert(right_items, HorizontalSpan:new{ width = Size.padding.large })
    end
    if item_has_submenu then
        table.insert(right_items, IconWidget:new{
            icon = BD.mirroredUILayout() and "chevron.left" or "chevron.right",
            width = IconItem.SETTINGS_CARET_SIZE,
            height = IconItem.SETTINGS_CARET_SIZE,
        })
    elseif item_checkable then
        table.insert(right_items, HorizontalSpan:new{
            width = Size.padding.large + IconItem.SETTINGS_CARET_SIZE,
        })
    end
    local right_group = HorizontalGroup:new(right_items)
    local right_w = right_group:getSize().w
    local icon_gap = Size.padding.default
    local controls_gap = right_w > 0 and Size.padding.default or 0
    local text_max_width = math.max(1,
        content_w - icon_w - icon_gap - right_w - controls_gap)
    local icon_face = IconItem.getSettingsIconFace(face)
    local row_items = {
        align = "center",
    }
    table.insert(row_items, not arrange_enabled and item.icon_glyph
        and IconItem.makeState(item.icon_glyph, icon_w, row.height, icon_face)
        or HorizontalSpan:new{ width = icon_w })
    table.insert(row_items, HorizontalSpan:new{ width = icon_gap })
    row._zen_settings_style = {
        row_height = row.height,
        font_size = face.orig_size,
        icon_width = IconItem.SETTINGS_ICON_WIDTH,
        toggle_width = IconItem.SETTINGS_TOGGLE_WIDTH,
        toggle_height = IconItem.SETTINGS_TOGGLE_HEIGHT,
        caret_size = IconItem.SETTINGS_CARET_SIZE,
    }
    local display_text = ArrangeState.stripSubmenuCaret(item.text)
    local text_widget = TextWidget:new{
        text = display_text,
        max_width = text_max_width,
        face = face,
        fgcolor = item_disabled and Blitbuffer.COLOR_DARK_GRAY or nil,
    }
    row._zen_settings_text_truncated = text_widget:isTruncated()
    if row._zen_settings_text_truncated then
        row.onHoldTouch = function(self)
            local anchor = self._zen_arrange_row_frame
                and self._zen_arrange_row_frame.dimen
            TruncatedTextMessage.show(display_text, anchor)
            return true
        end
    end
    table.insert(row_items, VerticalGroup:new{
        align = "left",
        text_widget,
        row.show_parent.underscore_checked_item and item_checked and LineWidget:new{
            dimen = Geom:new{ w = text_max_width, h = Size.line.thick },
            background = Blitbuffer.COLOR_DARK_GRAY,
        },
    })

    local content = OverlapGroup:new{
        dimen = Geom:new{ w = content_w, h = row.height },
        LeftContainer:new{
            dimen = Geom:new{ w = content_w, h = row.height },
            HorizontalGroup:new(row_items),
        },
    }
    if right_w > 0 then
        local EndContainer = BD.mirroredUILayout() and LeftContainer or RightContainer
        table.insert(content, EndContainer:new{
            dimen = Geom:new{ w = content_w, h = row.height },
            right_group,
        })
    end

    local frame_items = { align = "center" }
    if arrange_enabled then
        local handle = FrameContainer:new{
            dimen = Geom:new{ w = icon_w, h = row.height },
            padding = 0,
            bordersize = 0,
            focusable = true,
            focus_border_size = Size.border.thin,
            focus_inner_border = true,
            CenterContainer:new{
                dimen = Geom:new{ w = icon_w, h = row.height },
                IconWidget:new{
                    icon = "appbar.menu",
                    width = IconItem.SETTINGS_CARET_SIZE,
                    height = IconItem.SETTINGS_CARET_SIZE,
                },
            },
        }
        handle._zen_arrange_handle = true
        handle._zen_arrange_row = row
        row._zen_arrange_handle = handle
        IconItem.enableFullRowFocus(handle, row.show_parent.marked == row.index)
        local orig_handle_focus = handle.onFocus
        local orig_handle_unfocus = handle.onUnfocus
        handle.onFocus = function(self)
            row.show_parent._zen_arrange_focus_column = 1
            return orig_handle_focus(self)
        end
        handle.onUnfocus = function(self)
            return orig_handle_unfocus(self)
        end
        local StartContainer = BD.mirroredUILayout() and RightContainer or LeftContainer
        table.insert(content, StartContainer:new{
            dimen = Geom:new{ w = content_w, h = row.height },
            handle,
        })
    end
    table.insert(frame_items, HorizontalSpan:new{ width = left_padding })
    table.insert(frame_items, content)
    table.insert(frame_items, HorizontalSpan:new{ width = right_padding })

    local frame = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        focusable = true,
        focus_border_size = Size.border.thin,
        focus_inner_border = true,
        HorizontalGroup:new(frame_items),
    }
    row._zen_arrange_row_frame = frame
    if arrange_enabled then
        local focus_content = InputContainer:new{
            dimen = row.dimen,
            item = item,
            index = row.index,
        }
        focus_content._zen_arrange_content = true
        focus_content._zen_arrange_row = row
        focus_content.onFocus = function()
            row.show_parent._zen_arrange_focus_column = 2
            return frame:onFocus()
        end
        focus_content.onUnfocus = function()
            return frame:onUnfocus()
        end
        row._zen_arrange_content_focus = focus_content
    end
    row[1] = OverlapGroup:new{
        dimen = Geom:new{ w = row.width, h = row.height },
        frame,
        BottomContainer:new{
            dimen = Geom:new{ w = row.width, h = row.height },
            LineWidget:new{
                -- Keep dividers edge-to-edge while the row content stays inset.
                dimen = Geom:new{ w = row.show_parent.dimen.w, h = Size.line.thin },
                background = Blitbuffer.COLOR_LIGHT_GRAY,
            },
        },
    }
    IconItem.enableFullRowFocus(frame, not arrange_enabled and row.invert)
end

local function is_arrange_handle_tap(row, pos)
    local handle = row and row._zen_arrange_handle
    return handle and handle.dimen and pos and pos:intersectWith(handle.dimen) or false
end

local function is_arrange_row_tap(row, pos)
    return row and row.dimen and pos and pos:intersectWith(row.dimen) or false
end

local function is_toggle_tap(row, pos)
    local toggle = row and row.checkmark_widget
    local dimen = toggle and toggle.dimen
    if not (dimen and pos) then return false end
    local padding = Size.padding.default
    return pos:intersectWith(Geom:new{
        x = dimen.x - padding,
        y = dimen.y - padding,
        w = dimen.w + 2 * padding,
        h = dimen.h + 2 * padding,
    })
end

local function apply_icon_rows(sort_widget)
    if not sort_widget or not sort_widget.main_content then return end
    for _i, child in ipairs(sort_widget.main_content) do
        rebuild_icon_row(child)
    end
end

local function install_arrange_handle_layout(sort_widget)
    if not Device:hasDPad() or not (sort_widget and sort_widget._zen_arrange_enabled) then
        return
    end
    for _row_i, layout_row in ipairs(sort_widget.layout or {}) do
        local row = #layout_row == 1 and layout_row[1]
        if row and row._zen_arrange_handle then
            sort_widget.layout[_row_i] = {
                row._zen_arrange_handle,
                row._zen_arrange_content_focus,
                row._zen_arrange_toggle_focus,
            }
        end
    end

    local selected = sort_widget.selected
    local layout_row = selected and sort_widget.layout[selected.y]
    if not (layout_row and layout_row[1] and layout_row[1]._zen_arrange_handle) then
        return
    end
    local focus_column = sort_widget._zen_handle_active and 1
        or sort_widget._zen_arrange_focus_column or 2
    if not layout_row[focus_column] then focus_column = 2 end
    selected.x = focus_column
    for column, target in ipairs(layout_row) do
        if column == focus_column then
            target:onFocus()
        else
            target:onUnfocus()
        end
    end
end

local function suppress_page_centering(sort_widget)
    local content = sort_widget and sort_widget[1] and sort_widget[1][1]
    local frame_content = content and content[1]
    local vertical_group = frame_content and frame_content[1]
    local padding_span = vertical_group and vertical_group[2]
    if vertical_group and padding_span and vertical_group[3] == sort_widget.main_content then
        padding_span.width = 0
        if vertical_group.resetLayout then
            vertical_group:resetLayout()
        end
    end
end

local function apply_settings_row_metrics(sort_widget)
    if not (sort_widget and sort_widget.dimen and sort_widget.title_bar) then return end

    sort_widget.item_height = IconItem.getSettingsRowHeight()
    sort_widget.item_margin = 0

    local content = sort_widget[1] and sort_widget[1][1]
    local footer = content and content[2]
    local footer_group = footer and footer[1]
    local footer_size = footer_group and footer_group.getSize and footer_group:getSize()
    local footer_height = footer_size and footer_size.h or 0
    local content_height = sort_widget.dimen.h - sort_widget.title_bar:getHeight()
        - footer_height - Size.padding.large
    sort_widget.items_per_page = math.max(1,
        math.floor(content_height / sort_widget.item_height))
    sort_widget.pages = math.max(1,
        math.ceil(#sort_widget.item_table / sort_widget.items_per_page))
    sort_widget.show_page = math.min(sort_widget.show_page, sort_widget.pages)
end

local function back_to_settings_root()
    local settings_page = rawget(_G, "__ZEN_UI_SETTINGS_PAGE")
    if settings_page and settings_page.backToRootMenu then
        if settings_page._deferred_arrange_parent then
            settings_page._deferred_arrange_parent = nil
            settings_page.invisible = false
        end
        return settings_page:backToRootMenu()
    end
    return false
end

local function commit_arrange_order(sort_widget)
    if sort_widget and type(sort_widget._zen_arrange_commit_order) == "function" then
        return sort_widget:_zen_arrange_commit_order()
    end
    return false
end

local function configure_title_bar(sort_widget, opts)
    opts = opts or {}
    local old_title_bar = sort_widget and sort_widget.title_bar
    local content = sort_widget and sort_widget[1] and sort_widget[1][1]
    local frame_content = content and content[1]
    local vertical_group = frame_content and frame_content[1]
    if not (old_title_bar and vertical_group) then return end

    local default_action
    if type(opts.add_item_table) == "table" and #opts.add_item_table > 0 then
        default_action = {
            file = get_plus_icon_path(),
            icon = "plus",
            callback = function()
                commit_arrange_order(sort_widget)
                show_submenu(opts.add_title or "", opts.add_item_table, function()
                    if sort_widget._zen_arrange_refresh then
                        sort_widget:_zen_arrange_refresh()
                    else
                        repopulate(sort_widget)
                    end
                end, {
                    close_arrange = opts.close_arrange,
                    plugin = opts.plugin,
                })
                return true
            end,
        }
    end

    local function close_with(callback)
        if type(callback) == "function" then return callback() end
        return sort_widget:onClose()
    end

    local title_bar = SettingsTitleBar:new{
        width = sort_widget.dimen.w,
        title = sort_widget.title,
        back_visible = opts.back_visible ~= false,
        search_visible = false,
        title_full_width = true,
        action = default_action,
        plugin = opts.plugin,
        show_parent = sort_widget,
        back_callback = function() return close_with(opts.back_callback) end,
        back_hold_callback = function() return close_with(opts.back_hold_callback) end,
        close_callback = function() return close_with(opts.close_callback) end,
    }
    title_bar._zen_arrange_default_action = default_action
    vertical_group[1] = title_bar
    sort_widget.title_bar = title_bar
    sort_widget.onShowWidgetMenu = function() return TopMenu.open() end
    if vertical_group.resetLayout then vertical_group:resetLayout() end
    old_title_bar:free()

    local orig_onCloseWidget = sort_widget.onCloseWidget
    sort_widget.onCloseWidget = function(self, ...)
        title_bar:clearStatusRefresh()
        if orig_onCloseWidget then return orig_onCloseWidget(self, ...) end
    end
end

local function install_top_menu_gestures(sort_widget)
    if not sort_widget or sort_widget._zen_top_menu_gestures then return end
    sort_widget._zen_top_menu_gestures = true
    sort_widget.ges_events.Tap = {
        GestureRange:new{
            ges = "tap",
            range = Geom:new{
                x = sort_widget.dimen.x,
                y = sort_widget.dimen.y,
                w = sort_widget.dimen.w,
                h = TopMenu.getTapHeight(sort_widget.title_bar),
            },
        },
    }

    local original_handle_event = sort_widget.handleEvent
    sort_widget.handleEvent = function(self, event)
        if event.handler == "onGesture" then
            local gesture = event.args[1]
            if gesture and gesture.ges == "tap"
                    and not TopMenu.isInsideHeaderControl(self.title_bar, gesture.pos) then
                local handled = TopMenu.handleTap(self.title_bar, gesture)
                if handled ~= nil then return handled end
            end
        end
        return original_handle_event(self, event)
    end

    local original_on_tap = sort_widget.onTap
    sort_widget.onTap = function(self, arg, gesture)
        local handled = TopMenu.handleTap(self.title_bar, gesture)
        if handled ~= nil then return handled end
        if original_on_tap then return original_on_tap(self, arg, gesture) end
    end

    local original_on_swipe = sort_widget.onSwipe
    sort_widget.onSwipe = function(self, arg, gesture)
        local handled = TopMenu.handleSwipe(gesture)
        if handled ~= nil then return handled end
        if original_on_swipe then return original_on_swipe(self, arg, gesture) end
    end
end

local function strip_submenu_caret(text)
    return ArrangeState.stripSubmenuCaret(text)
end

local function has_submenu(item)
    return type(item) == "table"
        and (type(item.sub_item_table) == "table"
            or type(item.sub_item_table_func) == "function")
end

local function item_base_text(item)
    if type(item) ~= "table" then return nil end
    if type(item.text_func) == "function" then
        return strip_submenu_caret(item.text_func())
    end
    if item._zen_arrange_base_text == nil then
        item._zen_arrange_base_text = strip_submenu_caret(item.text)
    end
    return item._zen_arrange_base_text
end

local function strip_value_suffix(text)
    return ArrangeState.stripValueSuffix(text)
end

local function item_submenu_title(item)
    return item.sub_title or strip_value_suffix(item_base_text(item)) or item.text
end

local function resume_item_key(item)
    return item and (item._zen_settings_resume_key or item.orig_item or item_base_text(item))
end

local function find_resume_item(items, key)
    for _i, item in ipairs(items or {}) do
        if resume_item_key(item) == key then return item end
    end
end

local function extend_settings_resume(resume, item)
    if not (resume and resume.opener) then return nil end
    local path = {}
    for _i, key in ipairs(resume.path or {}) do path[#path + 1] = key end
    local key = resume_item_key(item)
    if type(key) ~= "string" then return nil end
    path[#path + 1] = key
    return { opener = resume.opener, path = path }
end

local function remember_settings_resume(sort_widget)
    local resume = sort_widget and sort_widget._zen_settings_resume
    if not (resume and resume.opener) then return end
    local ok, settings_page = pcall(require, "modules/settings/zen_settings_page")
    if ok and settings_page.noteArrangeRoute then
        settings_page.noteArrangeRoute(resume)
    end
end

local function update_dynamic_text(items)
    if type(items) ~= "table" then return end
    for _i, item in ipairs(items) do
        local text = item_base_text(item)
        if has_submenu(item) and type(text) == "string" then
            item.text = text .. ArrangeState.SUBMENU_CARET
        elseif text ~= nil then
            item.text = text
        end
    end
end

local function update_menu_enabled_state(items)
    if type(items) ~= "table" then return end
    for _i, item in ipairs(items) do
        if type(item) == "table" then
            if not item._zen_menu_original_dim_set then
                item._zen_menu_original_dim = item.dim
                item._zen_menu_original_dim_set = true
            end
            item.dim = not item_is_enabled(item) or item._zen_menu_original_dim
            update_menu_enabled_state(item.sub_item_table)
        end
    end
end

repopulate = function(sort_widget)
    if not sort_widget then return end
    sort_widget:_populateItems()
    UIManager:setDirty(sort_widget, "ui")
end

local function install_titlebar_focus(sort_widget)
    if not (sort_widget and sort_widget.layout) then return end
    local title_bar = sort_widget.title_bar
    if title_bar and type(title_bar.installFocusLayout) == "function" then
        title_bar:installFocusLayout(sort_widget)
        return
    end
    local left_button = title_bar and title_bar.left_button
    if not left_button then return end
    local first = sort_widget.layout[1]
    if first and first[1] == left_button then return end
    table.insert(sort_widget.layout, 1, { left_button })
    if sort_widget.selected then
        sort_widget.selected.y = (sort_widget.selected.y or 1) + 1
    end
end

local function move_focus_right_from_header(sort_widget)
    local title_bar = sort_widget and sort_widget.title_bar
    local focused = sort_widget and sort_widget.getFocusItem and sort_widget:getFocusItem()
    if title_bar and type(title_bar.containsFocus) == "function"
            and title_bar:containsFocus(focused) then
        sort_widget:onFocusMove({ 1, 0 })
        return true
    end
    return false
end

local function refresh_after_callbacks(items, refresh, menu_proxy, callback_complete)
    if type(items) ~= "table" or type(refresh) ~= "function" then return end
    for _i, item in ipairs(items) do
        if (type(item.callback) == "function" or type(item.callback_func) == "function")
                and (not item._zen_arrange_refresh_wrapped
                    or item._zen_arrange_refresh_proxy ~= menu_proxy) then
            local orig_callback = item._zen_arrange_orig_callback or item.callback
            item.callback = function(...)
                local callback = type(item.callback_func) == "function"
                    and item.callback_func() or orig_callback
                if type(callback) ~= "function" then return end
                local result = callback(menu_proxy, select(2, ...))
                if callback_complete then
                    callback_complete(item)
                else
                    refresh()
                end
                return result
            end
            item._zen_arrange_orig_callback = orig_callback
            item._zen_arrange_refresh_proxy = menu_proxy
            item._zen_arrange_refresh_wrapped = true
        end
        if type(item.hold_callback) == "function"
                and (not item._zen_arrange_hold_wrapped
                    or item._zen_arrange_hold_proxy ~= menu_proxy) then
            local orig_hold_callback = item._zen_arrange_orig_hold_callback
                or item.hold_callback
            item.hold_callback = function(_item, callback_refresh, ...)
                return orig_hold_callback(menu_proxy, callback_refresh, ...)
            end
            item._zen_arrange_orig_hold_callback = orig_hold_callback
            item._zen_arrange_hold_proxy = menu_proxy
            item._zen_arrange_hold_wrapped = true
        end
        refresh_after_callbacks(item.sub_item_table, refresh, menu_proxy, callback_complete)
    end
end

local function complete_menu_callback(item, refresh, close)
    if type(item.checked_func) == "function" then
        if item.check_callback_closes_menu then
            close()
        elseif not item.check_callback_updates_menu then
            refresh()
        end
    elseif item.keep_menu_open then
        refresh()
    else
        close()
    end
end

local install_submenu_tap_handlers
local install_root_tap_handlers

local function open_submenu_for_item(sort_widget, item, resume_path, resume_in_background)
    if not (sort_widget and item and has_submenu(item)
            and item_is_enabled(item)) then
        return false
    end
    commit_arrange_order(sort_widget)
    local sub_items = item.sub_item_table
    if type(item.sub_item_table_func) == "function" then
        sub_items = item.sub_item_table_func(sort_widget._zen_menu_proxy)
    end
    local submenu = show_submenu(item_submenu_title(item), sub_items, function()
        if sort_widget._zen_arrange_refresh then
            sort_widget:_zen_arrange_refresh()
        else
            repopulate(sort_widget)
        end
    end, {
        close_arrange = sort_widget._zen_arrange_close_all,
        menu_mode = sort_widget._zen_menu_mode,
        plugin = sort_widget._zen_plugin,
        settings_resume = extend_settings_resume(sort_widget._zen_settings_resume, item),
        resume_path = resume_path,
        resume_in_background = resume_in_background,
        restore_parent = resume_in_background and sort_widget or nil,
    })
    return submenu ~= nil
end

local function open_resume_item(sort_widget, item, resume_path)
    if open_submenu_for_item(sort_widget, item, resume_path, true) then return true end
    if item._zen_settings_submenu ~= true then return false end
    local callback = item.callback
    if type(callback) ~= "function" and type(item.callback_func) == "function" then
        callback = item.callback_func()
    end
    if type(callback) ~= "function" then return false end
    local previous_resume_path = pending_callback_resume_path
    if #resume_path > 0 then
        pending_callback_resume_path = {}
        for _i, key in ipairs(resume_path) do
            pending_callback_resume_path[#pending_callback_resume_path + 1] = key
        end
    end
    sort_widget.invisible = false
    callback(sort_widget._zen_menu_proxy)
    pending_callback_resume_path = previous_resume_path
    return true
end

local function get_focused_arrange_target(sort_widget)
    local focused = sort_widget and sort_widget.getFocusItem and sort_widget:getFocusItem()
    if focused and (focused._zen_arrange_handle
            or focused._zen_arrange_content
            or focused._zen_arrange_toggle) then
        return focused
    end
end

local function get_focused_arrange_handle(sort_widget)
    local focused = get_focused_arrange_target(sort_widget)
    if focused and focused._zen_arrange_handle then return focused end
end

local function focus_arrange_column(sort_widget, column)
    local selected = sort_widget and sort_widget.selected
    local row = selected and sort_widget.layout and sort_widget.layout[selected.y]
    if not (row and row[1] and row[1]._zen_arrange_handle and row[column]) then
        return false
    end
    sort_widget:moveFocusTo(column, selected.y)
    return true
end

local function toggle_focused_arrange_item(sort_widget)
    local focused = get_focused_arrange_target(sort_widget)
    local row = focused and focused._zen_arrange_row
    if not (row and row.index) then return false end
    local dropped = sort_widget._zen_handle_active == true
    sort_widget._zen_handle_active = not dropped
    sort_widget.marked = dropped and 0 or row.index
    sort_widget._zen_arrange_focus_column = 1
    sort_widget:_populateItems()
    focus_arrange_column(sort_widget, 1)
    if dropped then commit_arrange_order(sort_widget) end
    return true
end

local function toggle_keyboard_handle(sort_widget)
    local handle = get_focused_arrange_handle(sort_widget)
    if not handle then return false end
    return toggle_focused_arrange_item(sort_widget)
end

local function activate_keyboard_target(sort_widget)
    if toggle_keyboard_handle(sort_widget) then return true end
    local focused = get_focused_arrange_target(sort_widget)
    local item = focused and focused.item
    if not (focused and item) then return false end
    if not item_is_enabled(item) then return true end
    if focused._zen_arrange_toggle then
        sort_widget._zen_arrange_focus_column = 3
        local toggled = toggle_sort_item(sort_widget, item)
        focus_arrange_column(sort_widget, 3)
        return toggled
    end
    if focused._zen_arrange_content and open_submenu_for_item(sort_widget, item) then
        return true
    end
    if item.checked_func then return toggle_sort_item(sort_widget, item) end
    if item.callback then
        item:callback()
        if not sort_widget._zen_menu_mode then sort_widget:_populateItems() end
        return true
    end
    return true
end

local function move_arrange_item(sort_widget, target)
    if not (sort_widget and type(target) == "number") then return false end
    local moved, actual_target = ArrangeState.moveTableItem(
        sort_widget.item_table, sort_widget.marked, target)
    if not moved then
        return false
    end
    sort_widget.marked = actual_target
    sort_widget._zen_arrange_order_dirty = true
    sort_widget.show_page = math.ceil(actual_target / sort_widget.items_per_page)
    sort_widget:_populateItems()
    return true
end

local function install_arrange_movement(sort_widget)
    sort_widget.moveItem = function(self, diff)
        if type(diff) ~= "number" then return false end
        return move_arrange_item(self, self.marked + diff)
    end
    sort_widget.onMoveItemKB = function(self, diff)
        if self._zen_handle_active then self:moveItem(diff) end
        return true
    end
end

local function release_arrange_item(sort_widget)
    if not sort_widget then return false end
    cancel_item_drag_hold(sort_widget)
    if (sort_widget.marked or 0) == 0
            and not sort_widget._zen_handle_active
            and not sort_widget._zen_dragging then
        return false
    end
    sort_widget._zen_handle_active = false
    sort_widget._zen_dragging = false
    sort_widget._zen_drag_top = nil
    sort_widget._zen_drag_last_pos = nil
    sort_widget._zen_drag_page_latch = nil
    sort_widget._zen_arrange_focus_column = 2
    sort_widget.marked = 0
    commit_arrange_order(sort_widget)
    return true
end

local function install_arrange_paging(sort_widget)
    local orig_next_page = sort_widget.nextPage
    sort_widget.nextPage = function(self)
        local page = self.show_page
        local released = release_arrange_item(self)
        local result = orig_next_page(self)
        if released and self.show_page == page then self:_populateItems() end
        return result
    end

    local orig_prev_page = sort_widget.prevPage
    sort_widget.prevPage = function(self)
        local page = self.show_page
        local released = release_arrange_item(self)
        local result = orig_prev_page(self)
        if released and self.show_page == page then self:_populateItems() end
        return result
    end

    local orig_on_go_to_page = sort_widget.onGoToPage
    sort_widget.onGoToPage = function(self, page)
        release_arrange_item(self)
        return orig_on_go_to_page(self, page)
    end
end

local function install_dpad_handle_controls(sort_widget)
    if not Device:hasDPad() then return end

    local orig_on_focus_move = sort_widget.onFocusMove
    sort_widget.onFocusMove = function(self, args)
        if self._zen_handle_active and args then
            if args[1] ~= 0 then return true end
            if args[2] ~= 0 then
                self:moveItem(args[2])
                return true
            end
        end
        return orig_on_focus_move and orig_on_focus_move(self, args)
    end

    local confirm_key_down
    local orig_on_key_press = sort_widget.onKeyPress
    sort_widget.onKeyPress = function(self, key)
        local key_name = get_focused_arrange_target(self)
            and ArrangeState.confirmKeyName(key)
        if key_name then
            if confirm_key_down == key_name then return true end
            confirm_key_down = key_name
        end
        return orig_on_key_press and orig_on_key_press(self, key)
    end

    local orig_on_key_repeat = sort_widget.onKeyRepeat
    sort_widget.onKeyRepeat = function(self, key)
        if get_focused_arrange_target(self) and ArrangeState.confirmKeyName(key) then
            return true
        end
        return orig_on_key_repeat and orig_on_key_repeat(self, key)
    end

    local orig_on_key_release = sort_widget.onKeyRelease
    sort_widget.onKeyRelease = function(self, key)
        local key_name = ArrangeState.confirmKeyName(key)
        if key_name and confirm_key_down == key_name then
            confirm_key_down = nil
            if orig_on_key_release then orig_on_key_release(self, key) end
            return true
        end
        return orig_on_key_release and orig_on_key_release(self, key)
    end
end

local function move_dragged_item(sort_widget, ges)
    local pos = ges and ges.pos
    if not pos then return false end

    local item_count = #sort_widget.item_table
    local first = (sort_widget.show_page - 1) * sort_widget.items_per_page + 1
    local visible = math.min(sort_widget.items_per_page, item_count - first + 1)
    local row_height = sort_widget.item_height + sort_widget.item_margin
    local bottom = sort_widget._zen_drag_top + visible * row_height
    local page_direction = ArrangeState.dragPageDirection(
        pos.y,
        sort_widget._zen_drag_top,
        bottom
    )
    local target
    if page_direction ~= 0 then
        target = page_direction < 0 and first - 1 or first + visible
        if target < 1 or target > item_count then return false end
        if sort_widget._zen_drag_page_latch == page_direction then return false end
        sort_widget._zen_drag_page_latch = page_direction
    else
        sort_widget._zen_drag_page_latch = nil
        target = ArrangeState.dragTargetIndex(
            sort_widget.show_page,
            sort_widget.items_per_page,
            item_count,
            sort_widget._zen_drag_top,
            row_height,
            pos.y
        )
    end
    if target == sort_widget.marked then return false end
    return move_arrange_item(sort_widget, target)
end

local function cancel_drag_unfocus(sort_widget)
    local pending = sort_widget and sort_widget._zen_drag_unfocus
    if not pending then return end
    UIManager:unschedule(pending)
    sort_widget._zen_drag_unfocus = nil
end

cancel_item_drag_hold = function(sort_widget)
    local pending = sort_widget and sort_widget._zen_item_drag_hold
    if not pending then return end
    UIManager:unschedule(pending)
    sort_widget._zen_item_drag_hold = nil
end

local function unfocus_widget(widget)
    if widget and type(widget.handleEvent) == "function" then
        widget:handleEvent(Event:new("Unfocus"))
    end
end

local function schedule_drag_unfocus(sort_widget, dropped_index, focused_after_drop)
    cancel_drag_unfocus(sort_widget)
    local pending
    pending = function()
        if sort_widget._zen_drag_unfocus ~= pending then return end
        sort_widget._zen_drag_unfocus = nil
        if sort_widget._zen_dragging or sort_widget._zen_arrange_closing then return end
        if focused_after_drop
                and get_focused_arrange_target(sort_widget) == focused_after_drop then
            unfocus_widget(focused_after_drop)
        end
        for _row_i, row in ipairs(sort_widget.main_content or {}) do
            if row.index == dropped_index then
                unfocus_widget(row._zen_arrange_handle)
                unfocus_widget(row._zen_arrange_row_frame)
                break
            end
        end
        UIManager:setDirty(sort_widget, "ui")
    end
    sort_widget._zen_drag_unfocus = pending
    UIManager:scheduleIn(DRAG_UNFOCUS_DELAY, pending)
end

local function finish_touch_drag(sort_widget, ges)
    cancel_item_drag_hold(sort_widget)
    if not sort_widget._zen_dragging then return false end
    local drop_pos = ges and ges.pos
    if ges and ges.ges == "swipe" then
        drop_pos = ges.end_pos or sort_widget._zen_drag_last_pos
    end
    if drop_pos then
        move_dragged_item(sort_widget, {
            pos = drop_pos,
            relative = ges and ges.relative,
        })
    end
    local dropped_index = sort_widget.marked
    sort_widget._zen_dragging = false
    sort_widget._zen_drag_top = nil
    sort_widget._zen_drag_last_pos = nil
    sort_widget._zen_drag_page_latch = nil
    sort_widget._zen_arrange_focus_column = 2
    sort_widget.marked = 0
    sort_widget:_populateItems()
    schedule_drag_unfocus(
        sort_widget,
        dropped_index,
        get_focused_arrange_target(sort_widget)
    )
    commit_arrange_order(sort_widget)
    return true
end

local function start_touch_drag(sort_widget, pos, handle_only)
    if not pos then return false end
    for _row_i, row in ipairs(sort_widget.main_content or {}) do
        local matches = handle_only and is_arrange_handle_tap(row, pos)
            or not handle_only and is_arrange_row_tap(row, pos)
        if row.index and row.item and row.item.arrange_pinned_last ~= true and matches then
            cancel_item_drag_hold(sort_widget)
            cancel_drag_unfocus(sort_widget)
            local first = (sort_widget.show_page - 1) * sort_widget.items_per_page + 1
            local row_height = sort_widget.item_height + sort_widget.item_margin
            sort_widget._zen_drag_top = row._zen_arrange_handle.dimen.y
                - (row.index - first) * row_height
            sort_widget._zen_drag_last_pos = pos
            sort_widget._zen_drag_page_latch = nil
            sort_widget._zen_dragging = true
            sort_widget.marked = row.index
            sort_widget:_populateItems()
            return true
        end
    end
    return false
end

local function schedule_item_drag_hold(sort_widget, pos)
    if not pos then return false end
    local item_pos = false
    for _row_i, row in ipairs(sort_widget.main_content or {}) do
        if row.index and is_arrange_row_tap(row, pos)
                and not is_arrange_handle_tap(row, pos)
                and not is_toggle_tap(row, pos) then
            item_pos = true
            break
        end
    end
    if not item_pos then return false end

    cancel_item_drag_hold(sort_widget)
    local pending
    pending = function()
        if sort_widget._zen_item_drag_hold ~= pending then return end
        sort_widget._zen_item_drag_hold = nil
        if sort_widget._zen_arrange_closing or sort_widget._zen_dragging then return end
        start_touch_drag(sort_widget, pos, false)
    end
    sort_widget._zen_item_drag_hold = pending
    UIManager:scheduleIn(ITEM_DRAG_HOLD_DELAY, pending)
    return true
end

local function install_touch_handle_drag(sort_widget)
    if not Device:isTouchDevice() or not sort_widget._zen_arrange_enabled then return end

    local full = sort_widget.dimen
    sort_widget._zen_item_drag_hold_delay = ITEM_DRAG_HOLD_DELAY
    sort_widget.ges_events.ZenArrangeItemTouch = {
        GestureRange:new{ ges = "touch", range = full },
    }
    sort_widget.ges_events.ZenArrangeHold = {
        GestureRange:new{ ges = "hold", range = full },
    }
    sort_widget.ges_events.ZenArrangeHoldPan = {
        GestureRange:new{ ges = "hold_pan", range = full },
    }
    sort_widget.ges_events.ZenArrangeHoldRelease = {
        GestureRange:new{ ges = "hold_release", range = full },
    }
    sort_widget.ges_events.ZenArrangeHandlePan = {
        GestureRange:new{ ges = "pan", range = full },
    }
    sort_widget.ges_events.ZenArrangeHandlePanRelease = {
        GestureRange:new{ ges = "pan_release", range = full },
    }
    sort_widget.onZenArrangeHandlePan = function(self, _arg, ges)
        local pos = ges and ges.pos
        if not pos then return false end
        if not self._zen_dragging then
            local start_pos = ges.start_pos or pos
            if not start_touch_drag(self, start_pos, true) then return false end
        end
        self._zen_drag_last_pos = pos
        move_dragged_item(self, ges)
        return true
    end
    sort_widget.onZenArrangeHandlePanRelease = function(self, _arg, ges)
        return finish_touch_drag(self, ges)
    end
    sort_widget.onZenArrangeHold = function(self, _arg, ges)
        if self._zen_dragging then return true end
        return start_touch_drag(self, ges and ges.pos, false)
    end
    sort_widget.onZenArrangeHoldPan = function(self, _arg, ges)
        local pos = ges and ges.pos
        if not pos then return false end
        if not self._zen_dragging then
            local start_pos = ges.start_pos or pos
            if not start_touch_drag(self, start_pos, false) then return false end
        end
        self._zen_drag_last_pos = pos
        move_dragged_item(self, ges)
        return true
    end
    sort_widget.onZenArrangeHoldRelease = function(self, _arg, ges)
        return finish_touch_drag(self, ges)
    end

    local orig_on_swipe = sort_widget.onSwipe
    sort_widget.onSwipe = function(self, arg, ges)
        cancel_item_drag_hold(self)
        if not self._zen_dragging and ges then
            self:onZenArrangeHandlePan(nil, ges)
        end
        if self._zen_dragging then return finish_touch_drag(self, ges) end
        return orig_on_swipe and orig_on_swipe(self, arg, ges)
    end

    local orig_handle_event = sort_widget.handleEvent
    sort_widget.handleEvent = function(self, event)
        if event.handler == "onGesture" then
            local ges = event.args[1]
            if ges and ges.ges == "touch" then
                if schedule_item_drag_hold(self, ges.pos) then return true end
            elseif ges and ges.ges == "tap" then
                if self._zen_dragging then return finish_touch_drag(self, ges) end
                cancel_item_drag_hold(self)
            elseif ges and ges.ges == "hold" then
                cancel_item_drag_hold(self)
                if self:onZenArrangeHold(nil, ges) then return true end
            elseif ges and ges.ges == "hold_pan" then
                cancel_item_drag_hold(self)
                if self:onZenArrangeHoldPan(nil, ges) then return true end
            elseif ges and ges.ges == "hold_release" and self._zen_dragging then
                return self:onZenArrangeHoldRelease(nil, ges)
            elseif ges and ges.ges == "pan" then
                cancel_item_drag_hold(self)
                if self:onZenArrangeHandlePan(nil, ges) then return true end
            elseif ges and ges.ges == "pan_release" and self._zen_dragging then
                return self:onZenArrangeHandlePanRelease(nil, ges)
            end
        end
        return orig_handle_event(self, event)
    end
end

local function ensure_submenu_callbacks(items)
    if type(items) ~= "table" then return end
    for _i, item in ipairs(items) do
        if not item.hold_callback and has_submenu(item) then
            local submenu_item = item
            item.hold_callback = function(parent, refresh)
                local sub_items = submenu_item.sub_item_table
                if type(submenu_item.sub_item_table_func) == "function" then
                    sub_items = submenu_item.sub_item_table_func()
                end
                show_submenu(item_submenu_title(submenu_item), sub_items, refresh, {
                    plugin = parent and parent._zen_plugin,
                })
            end
        end
        if item.hold_callback and has_submenu(item) then
            item._zen_arrange_submenu_on_tap = true
        end
        ensure_submenu_callbacks(item.sub_item_table)
    end
end

show_submenu = function(title, items, refresh, opts)
    if type(items) ~= "table" or #items == 0 then return end
    opts = opts or {}
    if opts.menu_mode then update_menu_enabled_state(items) end
    ensure_submenu_callbacks(items)
    update_dynamic_text(items)

    local resume_item
    if opts.resume_in_background and type(opts.resume_path) == "table" and #opts.resume_path > 0 then
        resume_item = find_resume_item(items, opts.resume_path[1])
    end
    local refresh_count = resume_item and background_refresh_count()

    local sort_widget
    local menu_proxy
    local close_submenu_and_arrange
    local refresh_lists
    local menu_callback_complete = opts.menu_mode and function(item)
        complete_menu_callback(item, refresh_lists, close_submenu_and_arrange)
    end
    refresh_lists = function()
        if menu_proxy and type(menu_proxy.item_table) == "table" and menu_proxy.item_table ~= items then
            items = menu_proxy.item_table
        end
        if opts.menu_mode then update_menu_enabled_state(items) end
        ensure_submenu_callbacks(items)
        update_dynamic_text(items)
        refresh_after_callbacks(items, refresh_lists, menu_proxy, menu_callback_complete)
        if sort_widget then
            sort_widget.item_table = items
            repopulate(sort_widget)
        end
        if refresh then refresh() end
    end

    menu_proxy = {
        _zen_settings_resume = opts.settings_resume,
        _zen_plugin = opts.plugin,
        item_table_stack = {},
        item_table = items,
        backToUpperMenu = function()
            if #menu_proxy.item_table_stack > 0 then
                items = table.remove(menu_proxy.item_table_stack)
                menu_proxy.item_table = items
                refresh_lists()
                return
            end
            if sort_widget then
                local current = sort_widget
                sort_widget = nil
                current:onClose()
            end
        end,
        backToSettingsRoot = function()
            close_submenu_and_arrange()
            back_to_settings_root()
            return true
        end,
        updateItems = function(self)
            if type(self.item_table) == "table" then
                items = self.item_table
            end
            refresh_lists()
        end,
        closeMenu = function()
            close_submenu_and_arrange()
            return true
        end,
        onClose = function()
            close_submenu_and_arrange()
            return true
        end,
        handleEvent = function()
            return false
        end,
    }
    refresh_after_callbacks(items, refresh_lists, menu_proxy, menu_callback_complete)
    sort_widget = SortWidget:new{
        title = title,
        item_table = items,
        sort_disabled = false,
        covers_fullscreen = true,
        invisible = resume_item ~= nil,
    }
    sort_widget.item_margin = 0
    sort_widget:_populateItems()
    sort_widget.sort_disabled = true
    sort_widget._zen_arrange_close_all = opts.close_arrange
    sort_widget._zen_menu_mode = opts.menu_mode == true
    sort_widget._zen_plugin = opts.plugin
    sort_widget._zen_menu_proxy = menu_proxy
    sort_widget._zen_settings_resume = opts.settings_resume

    local orig_on_close = sort_widget.onClose
    local function close_submenu(self, restore_parent)
        if restore_parent and opts.restore_parent then
            opts.restore_parent.invisible = false
        end
        DispatcherMenu.flush(menu_proxy)
        remember_settings_resume(self)
        local result = orig_on_close(self)
        if refresh then refresh() end
        return result
    end
    sort_widget.onClose = function(self)
        return close_submenu(self, true)
    end
    sort_widget.onCancelOrClose = sort_widget.onClose

    sort_widget.key_events = sort_widget.key_events or {}
    sort_widget.key_events.FocusRight = nil
    sort_widget.key_events.AlternativeFocusRight = nil
    sort_widget.key_events.ZenArrangeOpenSubmenu = {
        { "Right" },
        event = "ZenArrangeOpenSubmenu",
    }
    sort_widget.onZenArrangeOpenSubmenu = function(self)
        if move_focus_right_from_header(self) then return true end
        open_submenu_for_item(self, get_focused_item(self))
        return true
    end

    close_submenu_and_arrange = function()
        if sort_widget then
            local current = sort_widget
            sort_widget = nil
            close_submenu(current, false)
        end
        if type(opts.close_arrange) == "function" then opts.close_arrange() end
    end
    sort_widget._zen_arrange_close_all = close_submenu_and_arrange
    configure_title_bar(sort_widget, {
        plugin = opts.plugin,
        back_callback = function()
            menu_proxy:backToUpperMenu()
            return true
        end,
        back_hold_callback = function()
            back_to_settings_root()
            close_submenu_and_arrange()
            return true
        end,
        close_callback = function()
            close_submenu_and_arrange()
            require("modules/settings/zen_settings_page").closeActive()
            return true
        end,
    })
    install_top_menu_gestures(sort_widget)
    apply_settings_row_metrics(sort_widget)
    sort_widget:_populateItems()
    suppress_page_centering(sort_widget)
    suppress_footer_button(sort_widget.footer_cancel)
    suppress_footer_button(sort_widget.footer_ok)
    suppress_footer_button(sort_widget.footer_first_up)
    suppress_footer_button(sort_widget.footer_last_down)
    suppress_footer_page_button(sort_widget)
    sync_pagination_footer(sort_widget)
    apply_icon_rows(sort_widget)
    install_submenu_tap_handlers(sort_widget)

    local orig_populate = sort_widget._populateItems
    sort_widget._populateItems = function(self, ...)
        update_dynamic_text(self.item_table)
        apply_settings_row_metrics(self)
        local result = orig_populate(self, ...)
        suppress_page_centering(self)
        suppress_footer_button(self.footer_cancel)
        suppress_footer_button(self.footer_ok)
        suppress_footer_button(self.footer_first_up)
        suppress_footer_button(self.footer_last_down)
        suppress_footer_page_button(self)
        sync_pagination_footer(self)
        apply_icon_rows(self)
        install_submenu_tap_handlers(self)
        install_titlebar_focus(self)
        return result
    end
    install_titlebar_focus(sort_widget)

    if resume_item then
        discard_background_refreshes(refresh_count)
        UIManager:show(sort_widget)
        table.remove(opts.resume_path, 1)
        if not open_resume_item(sort_widget, resume_item, opts.resume_path) then
            sort_widget.invisible = false
            UIManager:setDirty(sort_widget, "ui")
        end
    else
        UIManager:show(sort_widget)
    end
    return sort_widget
end

install_submenu_tap_handlers = function(sort_widget)
    if not sort_widget or not sort_widget.main_content then return end
    for _i, child in ipairs(sort_widget.main_content) do
        local item = type(child) == "table" and child.item or nil
        if item and sort_widget._zen_menu_mode
                and not child._zen_arrange_menu_hold_patched then
            child._zen_arrange_menu_hold_patched = true
            if not child._zen_settings_text_truncated then
                child.onHoldTouch = function() return true end
            end
        end
        if item and sort_widget._zen_menu_mode
                and not child._zen_arrange_menu_tap_patched then
            child._zen_arrange_menu_tap_patched = true
            local orig_on_tap = child.onTap
            child.onTap = function(row, arg, ges)
                if not item_is_enabled(item) then return true end
                return orig_on_tap(row, arg, ges)
            end
        end
        if item and item._zen_arrange_submenu_on_tap and not child._zen_arrange_submenu_tap_patched then
            child._zen_arrange_submenu_tap_patched = true
            child.onTap = function(row, _arg, ges)
                if not item_is_enabled(item) then
                    return true
                end
                if item.checked_func and ges and is_toggle_tap(row, ges.pos) then
                    ArrangeState.toggleItem(item)
                    if not row.show_parent._zen_menu_mode then
                        repopulate(row.show_parent)
                    end
                    return true
                end
                open_submenu_for_item(row.show_parent, item)
                return true
            end
        end
    end
end

install_root_tap_handlers = function(sort_widget)
    if not sort_widget or not sort_widget.main_content then return end
    for _i, child in ipairs(sort_widget.main_content) do
        local item = type(child) == "table" and child.item or nil
        if item and not child._zen_arrange_root_hold_patched then
            child._zen_arrange_root_hold_patched = true
            if not child._zen_settings_text_truncated then
                child.onHoldTouch = function() return true end
            end
        end
        if item and not child._zen_arrange_root_tap_patched then
            child._zen_arrange_root_tap_patched = true
            child.onTap = function(row, _arg, ges)
                if not item_is_enabled(item) then
                    return true
                end
                if ges and is_arrange_handle_tap(row, ges.pos) then return true end
                local action = ArrangeState.rootTapAction(
                    item,
                    ges and is_toggle_tap(row, ges.pos)
                )
                if action == "toggle" then
                    ArrangeState.toggleItem(item)
                    if not row.show_parent._zen_menu_mode then
                        repopulate(row.show_parent)
                    end
                    return true
                end
                if action == "submenu" then
                    open_submenu_for_item(row.show_parent, item)
                elseif action == "callback" then
                    item:callback()
                    if not row.show_parent._zen_menu_mode then
                        repopulate(row.show_parent)
                    end
                end
                return true
            end
        end
    end
end

function M.show(opts)
    opts = opts or {}
    local callback_resume_path = pending_callback_resume_path
    pending_callback_resume_path = nil
    local arrange_enabled = opts.allow_arrange ~= false
    local menu_mode = opts.menu_mode == true
    local item_table = opts.item_table or {}
    if menu_mode then update_menu_enabled_state(item_table) end
    update_dynamic_text(item_table)
    ensure_submenu_callbacks(item_table)

    local settings_resume = type(opts.settings_resume) == "table"
        and opts.settings_resume or nil
    if not settings_resume and not menu_mode and rawget(_G, "__ZEN_UI_SETTINGS_PAGE") then
        local ok_settings_page, settings_page = pcall(require, "modules/settings/zen_settings_page")
        if ok_settings_page and settings_page.claimArrangeRoute then
            settings_resume = settings_page.claimArrangeRoute()
        end
    end
    local resume_item
    local resume_path
    if type(callback_resume_path) == "table" and #callback_resume_path > 0 then
        resume_path = {}
        for _i, key in ipairs(callback_resume_path) do
            resume_path[#resume_path + 1] = key
        end
        resume_item = find_resume_item(item_table, resume_path[1])
    elseif settings_resume and #settings_resume.path > 0 then
        resume_path = {}
        for _i, key in ipairs(settings_resume.path) do
            resume_path[#resume_path + 1] = key
        end
        resume_item = find_resume_item(item_table, resume_path[1])
        if resume_item then
            settings_resume = {
                opener = settings_resume.opener,
                path = {},
                deferred_parent = settings_resume.deferred_parent,
            }
        end
    end
    local refresh_count = resume_item and background_refresh_count()

    local menu_proxy
    local menu_callback_complete
    local sort_widget = SortWidget:new{
        title = opts.title or "",
        item_table = item_table,
        callback = opts.callback,
        sort_disabled = not arrange_enabled,
        covers_fullscreen = true,
        invisible = resume_item ~= nil,
    }
    sort_widget.item_margin = 0
    sort_widget:_populateItems()
    sort_widget._zen_arrange_enabled = arrange_enabled
    sort_widget._zen_menu_mode = menu_mode
    sort_widget._zen_plugin = opts.plugin
    sort_widget._zen_arrange_refresh = function(self)
        if type(opts.refresh_func) == "function" then
            local refreshed = opts.refresh_func()
            if type(refreshed) == "table" then
                item_table = refreshed
                self.item_table = item_table
                ensure_submenu_callbacks(item_table)
                update_dynamic_text(item_table)
            end
        end
        if menu_mode then update_menu_enabled_state(item_table) end
        if menu_proxy then
            refresh_after_callbacks(item_table, function()
                sort_widget:_zen_arrange_refresh()
            end, menu_proxy, menu_callback_complete)
        end
        self:_populateItems()
    end
    menu_proxy = {
        _zen_settings_resume = settings_resume,
        _zen_plugin = opts.plugin,
        item_table = item_table,
        updateItems = function(self)
            if type(self.item_table) == "table" and self.item_table ~= item_table then
                item_table = self.item_table
                sort_widget.item_table = item_table
            end
            sort_widget:_zen_arrange_refresh()
        end,
        closeMenu = function()
            return sort_widget:_zen_arrange_close_all()
        end,
        onClose = function()
            return sort_widget:_zen_arrange_close_all()
        end,
        handleEvent = function()
            return false
        end,
    }
    sort_widget._zen_menu_proxy = menu_proxy
    menu_callback_complete = menu_mode and function(item)
        complete_menu_callback(item, function()
            sort_widget:_zen_arrange_refresh()
        end, function()
            sort_widget:_zen_arrange_close_all()
        end)
    end
    refresh_after_callbacks(item_table, function()
        sort_widget:_zen_arrange_refresh()
    end, menu_proxy, menu_callback_complete)
    sort_widget._zen_arrange_order_dirty = false
    sort_widget._zen_arrange_commit_order = function(self)
        if not self._zen_arrange_order_dirty then return false end
        if self.callback then self:callback() end
        self._zen_arrange_order_dirty = false
        return true
    end
    local orig_on_close = sort_widget.onClose
    local function show_deferred_parent()
        local parent = settings_resume and settings_resume.deferred_parent
        if not parent then return end
        settings_resume.deferred_parent = nil
        if parent._deferred_arrange_parent then
            parent._deferred_arrange_parent = nil
            parent.invisible = false
        end
    end
    local function close_arrange(restore_parent)
        if sort_widget._zen_arrange_closing then return true end
        sort_widget._zen_arrange_closing = true
        if restore_parent then show_deferred_parent() end
        cancel_item_drag_hold(sort_widget)
        cancel_drag_unfocus(sort_widget)
        DispatcherMenu.flush(menu_proxy)
        commit_arrange_order(sort_widget)
        sort_widget.marked = 0
        sort_widget.orig_item_table = nil
        return orig_on_close(sort_widget)
    end
    sort_widget._zen_arrange_close_all = function()
        return close_arrange(false)
    end
    local close_and_go_back
    if type(opts.back_callback) == "function" then
        close_and_go_back = function()
            if sort_widget._zen_arrange_closing then return true end
            sort_widget:_zen_arrange_close_all()
            return opts.back_callback()
        end
    end
    local close_and_restore_parent = function()
        return close_arrange(true)
    end
    sort_widget.onClose = close_and_go_back or close_and_restore_parent
    sort_widget.onCancelOrClose = sort_widget.onClose
    sort_widget._zen_settings_resume = settings_resume
    local title_opts = {
        add_title = opts.add_title,
        add_item_table = opts.add_item_table,
        close_arrange = sort_widget._zen_arrange_close_all,
        plugin = opts.plugin,
        back_visible = opts.back_visible,
        back_callback = close_and_go_back or close_and_restore_parent,
        back_hold_callback = function()
            if close_and_go_back then return close_and_go_back() end
            if not menu_mode then back_to_settings_root() end
            sort_widget._zen_arrange_close_all()
            return true
        end,
        close_callback = function()
            if not menu_mode then remember_settings_resume(sort_widget) end
            sort_widget._zen_arrange_close_all()
            if not menu_mode then
                require("modules/settings/zen_settings_page").closeActive()
            end
            return true
        end,
    }

    local orig_on_press = sort_widget.onPress
    sort_widget.onPress = function(self)
        if activate_keyboard_target(self) then return true end
        return orig_on_press and orig_on_press(self)
    end
    sort_widget.key_events = sort_widget.key_events or {}
    sort_widget.key_events.ZenArrangeToggleReturn = {
        { "Return" },
        event = "ZenArrangeToggle",
    }
    sort_widget.onZenArrangeToggle = function(self)
        return self:onPress()
    end
    sort_widget.key_events.FocusRight = nil
    sort_widget.key_events.AlternativeFocusRight = nil
    sort_widget.key_events.ZenArrangeOpenSubmenu = {
        { "Right" },
        event = "ZenArrangeOpenSubmenu",
    }
    sort_widget.onZenArrangeOpenSubmenu = function(self)
        if move_focus_right_from_header(self) then return true end
        if arrange_enabled and get_focused_arrange_target(self) then
            return self:onFocusMove({ 1, 0 })
        end
        if open_submenu_for_item(self, get_focused_item(self)) then return true end
        return true
    end

    configure_title_bar(sort_widget, title_opts)
    install_top_menu_gestures(sort_widget)
    apply_settings_row_metrics(sort_widget)
    sort_widget:_populateItems()
    suppress_page_centering(sort_widget)
    suppress_footer_button(sort_widget.footer_cancel)
    suppress_footer_button(sort_widget.footer_first_up)
    suppress_footer_button(sort_widget.footer_last_down)
    suppress_footer_button(sort_widget.footer_ok)
    suppress_footer_page_button(sort_widget)
    sync_pagination_footer(sort_widget)
    apply_icon_rows(sort_widget)
    install_arrange_handle_layout(sort_widget)
    install_root_tap_handlers(sort_widget)
    if arrange_enabled then
        install_arrange_movement(sort_widget)
        install_arrange_paging(sort_widget)
        install_dpad_handle_controls(sort_widget)
        install_touch_handle_drag(sort_widget)
    end
    local orig_populate = sort_widget._populateItems
    sort_widget._populateItems = function(self, ...)
        update_dynamic_text(self.item_table)
        apply_settings_row_metrics(self)
        local result = orig_populate(self, ...)
        suppress_page_centering(self)
        suppress_footer_button(self.footer_cancel)
        suppress_footer_button(self.footer_first_up)
        suppress_footer_button(self.footer_last_down)
        suppress_footer_button(self.footer_ok)
        suppress_footer_page_button(self)
        sync_pagination_footer(self)
        apply_icon_rows(self)
        install_arrange_handle_layout(self)
        install_root_tap_handlers(self)
        install_titlebar_focus(self)
        return result
    end
    install_titlebar_focus(sort_widget)

    if resume_item then
        discard_background_refreshes(refresh_count)
        UIManager:show(sort_widget)
        table.remove(resume_path, 1)
        if not open_resume_item(sort_widget, resume_item, resume_path) then
            sort_widget.invisible = false
            UIManager:setDirty(sort_widget, "ui")
        end
    else
        UIManager:show(sort_widget)
    end
    if opts.open_add_on_show and type(opts.add_item_table) == "table" and #opts.add_item_table > 0 then
        UIManager:nextTick(function()
            show_submenu(opts.add_title or "", opts.add_item_table, function()
                if sort_widget._zen_arrange_refresh then
                    sort_widget:_zen_arrange_refresh()
                else
                    repopulate(sort_widget)
                end
            end, {
                close_arrange = sort_widget._zen_arrange_close_all,
                plugin = opts.plugin,
            })
        end)
    end
    return sort_widget
end

return M
