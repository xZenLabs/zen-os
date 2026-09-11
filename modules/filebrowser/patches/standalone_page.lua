local Menu = require("ui/widget/menu")
local TitleBar = require("ui/widget/titlebar")
local Geom = require("ui/geometry")
local ClockTimer = require("common/clock_timer")
local WidgetResources = require("common/widget_resources")
local Background = require("common/ui/background")

local M = {}
local _zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")

local function library_background_path()
    return Background.library_path(_zen_plugin)
end

local SKIP_FM_DISPATCH = {
    onBatchedUpdate = true,
    onBatchedUpdateDone = true,
    onCloseWidget = true,
    onFlushSettings = true,
    onGesture = true,
    onSetDimensions = true,
    onShow = true,
}

local function get_filemanager_instance()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok and FileManager then
        return FileManager.instance
    end
end

local function is_horizontal_swipe(ges)
    if not ges then return false end
    local direction = ges.direction
    return direction == "east" or direction == "west"
end

local function is_gesture_manager_zone(id)
    if type(id) ~= "string" then return false end
    return id == "multiswipe"
        or id == "short_diagonal_swipe"
        or id == "spread_gesture"
        or id == "pinch_gesture"
        or id == "rotate_cw"
        or id == "rotate_ccw"
        or id:sub(1, 4) == "tap_"
        or id:sub(1, 5) == "hold_"
        or id:sub(1, 11) == "double_tap_"
        or id:sub(1, 17) == "one_finger_swipe_"
        or id:sub(1, 11) == "two_finger_"
end

local function should_block_standalone_swipe(menu, ges)
    return menu and menu._zen_block_fm_horizontal_swipe and is_horizontal_swipe(ges)
end

local function dispatch_gesture_manager(ges)
    if not ges then return false end
    local fm = get_filemanager_instance()
    if not (fm and fm._ordered_touch_zones) then return false end

    local UIManager = require("ui/uimanager")
    local gestures_disabled = UIManager._input_gestures_disabled == true
    for _i, zone in ipairs(fm._ordered_touch_zones) do
        local id = zone.def and zone.def.id
        if is_gesture_manager_zone(id) then
            local always_active = not gestures_disabled
                or (type(fm.isGestureAlwaysActive) == "function"
                    and fm:isGestureAlwaysActive(id, ges.multiswipe_directions))
            if always_active and zone.gs_range and type(zone.gs_range.match) == "function"
                    and zone.gs_range:match(ges) and type(zone.handler) == "function"
                    and zone.handler(ges) then
                return true
            end
        end
    end
    return false
end

local function is_navbar_gesture(menu, ges)
    local navbar_h = tonumber(menu and menu._zen_navbar_height)
    local screen_h = tonumber(menu and menu.dimen and menu.dimen.h)
    local y = tonumber(ges and ges.pos and ges.pos.y)
    return navbar_h and navbar_h > 0 and screen_h and y
        and y >= screen_h - navbar_h
end

-- broadcastEvent dispatches to *every* window-stack widget directly, including
-- FileManager.instance (which sits beneath the standalone page). Forwarding
-- broadcast events to FM as well would dispatch them twice -- harmless for most
-- handlers, but breaks toggles that flip state (e.g. ToggleGSensor's
-- flipNilOrFalse, which double-flips to a no-op). sendEvent does NOT call FM's
-- handleEvent down-stack, so its events still need forwarding. Track when we're
-- inside a broadcast so the forwarder can skip it.
local in_broadcast = false
local function install_broadcast_guard()
    if rawget(_G, "__ZEN_UI_BROADCAST_GUARD_PATCHED") then return end
    _G.__ZEN_UI_BROADCAST_GUARD_PATCHED = true
    local UIManager = require("ui/uimanager")
    local orig_broadcastEvent = UIManager.broadcastEvent
    UIManager.broadcastEvent = function(self, event, ...)
        local prev = in_broadcast
        local args = { n = select("#", ...), ... }
        local ret
        in_broadcast = true
        local ok, err = xpcall(function()
            ret = orig_broadcastEvent(self, event, unpack(args, 1, args.n))
        end, debug.traceback)
        in_broadcast = prev
        if not ok then error(err, 0) end
        return ret
    end
end
install_broadcast_guard()

local function refresh_bound_status_row(target)
    if not target or not target._zen_status_refresh then return end
    if target._zen_home_show_status_bar == false then return end
    local UIManager = require("ui/uimanager")
    local stack = UIManager._window_stack
    local top = stack and stack[#stack]
    if not top or top.widget ~= target then return end
    target:_zen_status_refresh()
end

local function remove_from_overlap(group, widget)
    if not widget then return end
    for i = #group, 1, -1 do
        if rawequal(group[i], widget) then
            table.remove(group, i)
            return
        end
    end
end

function M.enable_gesture_manager_dispatch(menu)
    if not menu or menu._zen_gesture_manager_dispatch_enabled then return end
    menu._zen_gesture_manager_dispatch_enabled = true

    local orig_handleEvent = menu.handleEvent
    function menu:handleEvent(event)
        local ges = event and event.handler == "onGesture"
            and event.args and event.args[1] or nil
        local local_checked = false
        if is_navbar_gesture(self, ges) then
            local_checked = true
            if orig_handleEvent and orig_handleEvent(self, event) then return true end
        end
        if ges and dispatch_gesture_manager(ges) then
            return true
        end
        if not local_checked and orig_handleEvent then
            return orig_handleEvent(self, event)
        end
        return false
    end
end

function M.enable_filemanager_dispatch(menu)
    if not menu or menu._zen_fm_dispatch_enabled then return end
    M.enable_gesture_manager_dispatch(menu)
    menu._zen_fm_dispatch_enabled = true

    local orig_handleEvent = menu.handleEvent
    function menu:handleEvent(event)
        local consumed = orig_handleEvent and orig_handleEvent(self, event)
        if consumed or not event or SKIP_FM_DISPATCH[event.handler] then
            return consumed
        end
        -- Broadcast events already reach FM directly via the window stack;
        -- forwarding here would dispatch them twice. Only sendEvent events
        -- (which stop at the top widget) need the forward.
        if in_broadcast then
            return consumed
        end

        local fm = get_filemanager_instance()
        if fm and fm ~= self and type(fm.handleEvent) == "function" then
            return fm:handleEvent(event)
        end
        return consumed
    end

    local orig_onSwipe = menu.onSwipe
    function menu:onSwipe(arg, ges)
        if should_block_standalone_swipe(self, ges) then
            return true
        end
        if orig_onSwipe then
            return orig_onSwipe(self, arg, ges)
        end
    end
end

function M.prevent_swipe_close(menu)
    if not menu or menu._zen_prevent_swipe_close then return end
    menu._zen_prevent_swipe_close = true

    menu.onMultiSwipe = function()
        return true
    end
end

function M.create_menu(opts)
    opts = opts or {}

    local orig_tb_new = TitleBar.new
    TitleBar.new = function(cls, t)
        if type(t) == "table" then
            t.subtitle = nil
            t.subtitle_fullwidth = nil
            t.left_icon = nil
            t.left_icon_tap_callback = nil
            t.left_icon_hold_callback = nil
            t.right_icon = nil
            t.right_icon_tap_callback = nil
            t.right_icon_hold_callback = nil
            t.close_callback = nil
            t.title_tap_callback = nil
            t.title_hold_callback = nil
            t.bottom_v_padding = 0
            t.title = " "
        end
        return orig_tb_new(cls, t)
    end

    local ok_menu, menu_or_err = pcall(Menu.new, Menu, {
        name = opts.name,
        title = opts.title or " ",
        no_title = opts.no_title == true,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        item_table = opts.item_table or {},
        onMenuSelect = opts.onMenuSelect,
        onMenuHold = opts.onMenuHold,
        updateItems = opts.updateItems,
    })

    TitleBar.new = orig_tb_new
    if not ok_menu then
        error(menu_or_err)
    end

    if opts.filemanager_dispatch ~= false then
        M.enable_filemanager_dispatch(menu_or_err)
    end
    menu_or_err._zen_block_fm_horizontal_swipe = opts.block_filemanager_horizontal_swipe == true
    M.prevent_swipe_close(menu_or_err)
    M.apply_background(menu_or_err)

    return menu_or_err
end

-- Paint the configured library background image behind the page. The root
-- FrameContainer's opaque white fill is dropped so the image shows through the
-- gaps around the page content.
function M.apply_background(menu)
    if not menu or menu._zen_bg_applied then return end
    menu._zen_bg_applied = true

    local orig_paintTo = menu.paintTo
    function menu:paintTo(bb, x, y)
        local path = library_background_path()
        if path ~= "" then
            -- Menu:updateItems rebuilds self[1] with an opaque COLOR_WHITE fill,
            -- so drop it on every paint (not just once at creation) or the white
            -- returns after any refresh and hides the background.
            Background.clearWhiteBackgrounds(self[1], 14)
            if self.dimen then
                Background.paintScreenRegion(bb, 0, 0, 0, 0,
                    self.dimen.w, self.dimen.h, path)
            end
        end
        if orig_paintTo then
            return orig_paintTo(self, bb, x, y)
        end
    end
end

function M.hide_page_arrow(menu)
    if not menu then return end
    local page_arrow = menu.page_return_arrow
    if page_arrow then
        page_arrow:hide()
        page_arrow.show = function() end
        page_arrow.showHide = function() end
        page_arrow.dimen = Geom:new{ w = 0, h = 0 }
    end
end

function M.suppress_page_info_tap(menu)
    if not menu then return end
    if menu.page_info_text then
        menu.page_info_text.tap_input = nil
        menu.page_info_text.hold_input = nil
    end
end

function M.prepare_shell(menu)
    if not menu then return end
    menu.updateItems = function() end
    M.hide_page_arrow(menu)
    M.suppress_page_info_tap(menu)
end

function M.apply_status_row(menu, params)
    if not menu then return end
    params = params or {}

    local tb = menu.title_bar
    if not tb then return end

    local createStatusRow = params.createStatusRow
    local createStatusRowCustomBack = params.createStatusRowCustomBack
    local repaintTitleBar = params.repaintTitleBar
    local back_callback = params.back_callback
    local label = params.label

    local function build_row()
        if back_callback and createStatusRowCustomBack then
            return createStatusRowCustomBack(back_callback, label)
        elseif createStatusRow then
            local FileManager = require("apps/filemanager/filemanager")
            return createStatusRow(nil, FileManager.instance, label)
        end
    end

    local function set_title_row(row)
        if not (row and tb.title_group and #tb.title_group >= 2) then return end
        WidgetResources.replaceChild(tb.title_group, 2, row)
    end

    remove_from_overlap(tb, tb.left_button)
    remove_from_overlap(tb, tb.right_button)
    tb.has_left_icon = false
    tb.has_right_icon = false

    if tb.title_group and #tb.title_group >= 2 then
        set_title_row(build_row())
    end

    menu._zen_status_refresh = function(_self, suppress_repaint)
        if tb.title_group and #tb.title_group >= 2 then
            set_title_row(build_row())
            if repaintTitleBar and suppress_repaint ~= true then repaintTitleBar(tb) end
        end
    end

    menu._zen_status_clock_bound = true
    ClockTimer.bind(menu, refresh_bound_status_row)
end

function M.mount_body(menu, body_widget)
    if not menu or not menu.item_group then return end
    WidgetResources.free(menu.item_group[1])
    while #menu.item_group > 0 do table.remove(menu.item_group) end
    menu.item_group[1] = body_widget
    menu.item_group:resetLayout()
    if menu.content_group then menu.content_group:resetLayout() end
end

function M.remove_overlay_icons(menu)
    if not menu or not menu.title_bar then return end
    local tb = menu.title_bar
    remove_from_overlap(tb, tb.left_button)
    remove_from_overlap(tb, tb.right_button)
    tb.has_left_icon = false
    tb.has_right_icon = false
end

return M
