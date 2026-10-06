-- Shared top-menu gesture policy plus the Menu class patch.
local Device = require("device")

local M = {}

local function visible_dimen(control)
    if not control or control.skip_paint then return end
    local dimen = control.dimen
    if dimen and dimen.x and dimen.y and dimen.w and dimen.h then return dimen end
end

local function header_controls(title_bar)
    return {
        title_bar.back_button,
        title_bar.search_button,
        title_bar.search_frame,
        title_bar.action_button,
        title_bar.more_button,
        title_bar.close_button,
    }
end

function M.isInsideHeaderControl(title_bar, pos)
    if not (title_bar and pos and pos.x and pos.y) then return false end
    local controls = header_controls(title_bar)
    for control_index = 1, 6 do
        local control = controls[control_index]
        local dimen = visible_dimen(control)
        if dimen
                and pos.x >= dimen.x and pos.x < dimen.x + dimen.w
                and pos.y >= dimen.y and pos.y < dimen.y + dimen.h then
            return true
        end
    end
    return false
end

function M.getTapHeight(title_bar)
    local height = Device.screen:getHeight() * 0.07
    local dimen = title_bar and title_bar.dimen
    if dimen and dimen.y and dimen.h then
        return math.max(height, dimen.y + dimen.h)
    end
    if title_bar and type(title_bar.getHeight) == "function" then
        return math.max(height, title_bar:getHeight())
    end
    return height
end

function M.isNearHeaderControl(title_bar, pos)
    if not (title_bar and pos and pos.x and pos.y) then return false end
    local screen = Device.screen
    local padding = type(screen.scaleBySize) == "function" and screen:scaleBySize(8) or 8

    local function is_near(control)
        local dimen = visible_dimen(control)
        return dimen
            and pos.x >= dimen.x - padding and pos.x < dimen.x + dimen.w + padding
            and pos.y >= dimen.y - padding and pos.y < dimen.y + dimen.h + padding
    end

    local controls = header_controls(title_bar)
    for control_index = 1, 6 do
        if is_near(controls[control_index]) then return true end
    end

    local min_x, max_x, max_y
    local right_controls = {
        controls[2],
        controls[3],
        controls[4],
        controls[5],
        controls[6],
    }
    for control_index = 1, 5 do
        local dimen = visible_dimen(right_controls[control_index])
        if dimen then
            min_x = min_x and math.min(min_x, dimen.x) or dimen.x
            max_x = max_x and math.max(max_x, dimen.x + dimen.w) or dimen.x + dimen.w
            max_y = max_y and math.max(max_y, dimen.y + dimen.h) or dimen.y + dimen.h
        end
    end
    if min_x then
        return pos.x >= min_x - padding and pos.x < max_x + padding
            and pos.y >= 0 and pos.y < max_y + padding
    end

    local trailing_width = 0
    for control_index = 1, 5 do
        local control = right_controls[control_index]
        if control and not control.skip_paint and type(control.getSize) == "function" then
            trailing_width = trailing_width + control:getSize().w
        end
    end
    local title_width = title_bar.width or Device.screen:getWidth()
    return trailing_width > 0
        and pos.x >= title_width - trailing_width - padding
        and pos.y >= 0 and pos.y < M.getTapHeight(title_bar) + padding
end

local function get_filemanager_menu()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    return ok and FileManager.instance and FileManager.instance.menu
end

local function get_reader_menu()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    return ok and ReaderUI.instance and ReaderUI.instance.menu
end

local function show_for_gesture(gesture, blocked_activation)
    local function show(menu)
        if menu and menu.activation_menu ~= blocked_activation
                and type(menu.onShowMenu) == "function" then
            local tab_index = type(menu._getTabIndexFromLocation) == "function"
                and menu:_getTabIndexFromLocation(gesture) or nil
            menu:onShowMenu(tab_index)
            return true
        end
    end
    return show(get_filemanager_menu()) or show(get_reader_menu()) or false
end

function M.handleTap(title_bar, gesture)
    local pos = gesture and gesture.pos
    if M.isNearHeaderControl(title_bar, pos) then return true end
    if not (pos and pos.y < Device.screen:getHeight() * 0.07) then return end
    if show_for_gesture(gesture, "swipe") then return true end
end

function M.handleSwipe(gesture)
    if not (gesture and gesture.direction == "south") then return end
    local pos = gesture.pos
    if pos and pos.y < Device.screen:getHeight() * 0.14 then
        show_for_gesture(gesture, "tap")
    end
    return true
end

function M.open()
    local function open(menu)
        if menu and type(menu.onShowMenu) == "function" then
            menu:onShowMenu()
            return true
        end
    end
    return open(get_filemanager_menu()) or open(get_reader_menu()) or false
end

function M.apply()
    local GestureRange = require("ui/gesturerange")
    local Menu = require("ui/widget/menu")
    local original_on_swipe = Menu.onSwipe
    local original_init = Menu.init

    for _i, menu_class in ipairs({
        require("apps/reader/modules/readermenu"),
        require("apps/filemanager/filemanagermenu"),
    }) do
        local original_on_show_menu = menu_class.onShowMenu
        menu_class.onShowMenu = function(self, ...)
            if self.menu_container then
                self.menu_container[1]:closeMenu()
            end
            return original_on_show_menu(self, ...)
        end
        local original_on_tap_show_menu = menu_class.onTapShowMenu
        menu_class.onTapShowMenu = function(self, gesture)
            if gesture and gesture.pos and gesture.pos.y < Device.screen:getHeight() * 0.07 then
                return original_on_tap_show_menu(self, gesture)
            end
        end
    end

    Menu.onSwipe = function(self, arg, gesture)
        local handled = M.handleSwipe(gesture)
        if handled ~= nil then return handled end
        return original_on_swipe(self, arg, gesture)
    end

    Menu.init = function(self, ...)
        original_init(self, ...)
        if self.ges_events and self.ges_events.Swipe then
            self.ges_events.Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = self.dimen,
                },
            }
        end
    end

    Menu.onTap = function(self, _arg, gesture)
        if self._zen_opds_browser and self.title_bar and gesture and gesture.pos then
            local left_button = self.title_bar.left_button
            local right_button = self.title_bar.right_button
            local left_dimen = left_button and left_button.dimen
            local right_dimen = right_button and right_button.dimen
            if (left_dimen and gesture.pos:intersectWith(left_dimen))
                    or (right_dimen and gesture.pos:intersectWith(right_dimen)) then
                return
            end
        end
        return M.handleTap(nil, gesture)
    end
end

return M
