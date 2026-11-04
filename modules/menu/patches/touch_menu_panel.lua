local M = {}

local active_plugin

local function get_shared(key)
    local SharedState = require("common/shared_state")
    return SharedState.get(active_plugin, key)
end

local function in_panel_mode(tm)
    return tm
        and tm._zen_panel_refs ~= nil
        and tm.item_table ~= nil
        and tm.item_table.panel ~= nil
end

local function cancel_sliders(tm)
    for _i, ref in ipairs(tm._zen_panel_refs and tm._zen_panel_refs.sliders or {}) do
        if ref.cancel then ref.cancel() end
    end
end

local function handle_panel_gesture(touch_menu, ges, is_hold)
    local refs = touch_menu._zen_panel_refs
    if not refs then return false end

    if not is_hold then
        for _i, sr in ipairs(refs.sliders or {}) do
            if sr.slider:handleTap(ges) then return true end
        end
    end

    if not is_hold then
        for _i, tr in ipairs(refs.toggles or {}) do
            if tr.toggle.dimen and ges.pos:intersectWith(tr.toggle.dimen) then
                tr.callback()
                return true
            end
        end
    end

    for _i, btn_ref in ipairs(refs.buttons or {}) do
        if btn_ref.widget.dimen and ges.pos:intersectWith(btn_ref.widget.dimen) then
            local require_hold = type(refs.require_hold) == "function"
                and refs.require_hold()
                or refs.require_hold == true
            if require_hold then
                if is_hold and btn_ref.callback then
                    btn_ref.callback(touch_menu)
                end
                return true
            end
            if is_hold and btn_ref.hold_callback then
                btn_ref.hold_callback(touch_menu)
                return true
            elseif not is_hold and btn_ref.callback then
                btn_ref.callback(touch_menu)
                return true
            elseif not is_hold then
                return true
            end
            return false
        end
    end

    return false
end

M.handlePanelGesture = handle_panel_gesture

--- Refresh for swapped panel content over accent fills, which "ui" leaves ghosted on color e-ink.
--- Dithered partial, no flash. Nil when view and page are unchanged.
function M.viewSwapRefresh(old_refs, refs)
    if not (old_refs and refs) then return end
    if refs.view ~= old_refs.view or refs.view_page ~= old_refs.view_page then return "partial", true end
end

function M.install(plugin)
    active_plugin = plugin or active_plugin or rawget(_G, "__ZEN_UI_PLUGIN")

    local TouchMenu = require("ui/widget/touchmenu")
    if TouchMenu.__zen_touch_menu_panel_patched then
        return
    end
    TouchMenu.__zen_touch_menu_panel_patched = true

    local Device = require("device")
    local Event = require("ui/event")
    local FocusManager = require("ui/widget/focusmanager")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local T = require("ffi/util").template
    local UIManager = require("ui/uimanager")
    local Accent = require("common/ui/accent")
    local getFullRefreshMode = require("common/ui/refresh")
    local ZenSlider = require("common/ui/zen_slider")
    local _ = require("gettext")
    local Screen = Device.screen

    local Blitbuffer = require("ffi/blitbuffer")

    -- Elbow tiles rendered once per geometry, then blitted on every bar paint.
    local elbow_tiles = {}
    local function elbow_tile(radius, inner_x, inner_y, left, top, anti_alias)
        local key = ("%d:%d:%d:%d"):format(radius, inner_x, inner_y,
            (left and 1 or 0) + (top and 2 or 0) + (anti_alias and 4 or 0))
        local tile = elbow_tiles[key]
        if tile then return tile end
        tile = Blitbuffer.new(radius, radius, Blitbuffer.TYPE_BB8)
        local center_x, center_y = left and 0 or radius, top and radius or 0
        local r2, ix2, iy2 = radius * radius, inner_x * inner_x, inner_y * inner_y
        for row = 0, radius - 1 do
            for col = 0, radius - 1 do
                local hits = 0 -- 4x4 supersampled coverage
                for i = 0.125, 1, 0.25 do
                    local dy2 = (row + i - center_y) ^ 2
                    for j = 0.125, 1, 0.25 do
                        local dx2 = (col + j - center_x) ^ 2
                        if dx2 + dy2 <= r2 and dx2 / ix2 + dy2 / iy2 >= 1 then hits = hits + 1 end
                    end
                end
                if not anti_alias then hits = hits >= 8 and 16 or 0 end
                tile:setPixel(col, row, Blitbuffer.Color8(255 - math.floor(hits * 255 / 16)))
            end
        end
        elbow_tiles[key] = tile
        return tile
    end

    -- Round the elbows where the active tab's dividers meet the bar line.
    local function paint_tab_elbows(bar, bb, x, y)
        local line = bar.bar_sep
        local segment = line and line.empty_segments and line.empty_segments[1]
        local group = bar[1] and bar[1][1]
        if not (segment and group) then return end
        local Size = require("ui/size")
        local radius = Size.radius.window
        local line_on_top = group[1] == line
        local line_y = line_on_top and y or y + bar.bar_icon_group:getSize().h
        local square_y = line_on_top and line_y or line_y + line.dimen.h - radius
        -- Inner edge is an ellipse so the stroke blends from divider width to line height.
        local inner_x, inner_y = radius - Size.span.vertical_default, radius - line.dimen.h
        local anti_alias = G_reader_settings:nilOrTrue("anti_alias_ui")
        for side = 1, 2 do
            local left = side == 1
            local edge = left and segment.s or segment.e
            if edge > 0 and edge < line.dimen.w then
                bb:blitFrom(elbow_tile(radius, inner_x, inner_y, left, line_on_top, anti_alias),
                    x + (left and edge - radius or edge), square_y, 0, 0, radius, radius)
            end
        end
    end

    local function ensure_panel_gestures(touch_menu)
        local gestures = touch_menu.ges_events
        if gestures
                and gestures.Pan and gestures.Pan.event == "PanCloseAllMenus"
                and gestures.Pan[1] and gestures.Pan[1].range == touch_menu.dimen
                and gestures.PanCloseAllMenus == nil
                and gestures.HoldCloseAllMenus and gestures.HoldCloseAllMenus[1]
                and gestures.PanReleaseCloseAllMenus and gestures.PanReleaseCloseAllMenus[1]
                and gestures.MultiSwipe and gestures.MultiSwipe[1] then
            return
        end

        local sw = (touch_menu.screen_size and touch_menu.screen_size.w) or Screen:getWidth()
        local sh = (touch_menu.screen_size and touch_menu.screen_size.h) or Screen:getHeight()
        touch_menu.ges_events = touch_menu.ges_events or {}
        touch_menu.ges_events.HoldCloseAllMenus = {
            GestureRange:new{
                ges = "hold",
                range = Geom:new{ x = 0, y = 0, w = sw, h = sh },
            }
        }
        -- Reuse KOReader's Pan slot so its handler cannot race ours.
        touch_menu.ges_events.PanCloseAllMenus = nil
        local pan_gestures = touch_menu.ges_events.Pan
        if type(pan_gestures) ~= "table"
                or not pan_gestures[1]
                or pan_gestures[1].range ~= touch_menu.dimen then
            pan_gestures = {
                GestureRange:new{
                    ges = "pan",
                    range = touch_menu.dimen,
                }
            }
            touch_menu.ges_events.Pan = pan_gestures
        end
        pan_gestures.event = "PanCloseAllMenus"
        touch_menu.ges_events.PanReleaseCloseAllMenus = {
            GestureRange:new{
                ges = "pan_release",
                range = Geom:new{ x = 0, y = 0, w = sw, h = sh },
            }
        }
        touch_menu.ges_events.MultiSwipe = {
            GestureRange:new{
                ges = "multiswipe",
                range = Geom:new{ x = 0, y = 0, w = sw, h = sh },
            }
        }
    end

    local orig_init = TouchMenu.init
    function TouchMenu:init()
        orig_init(self)
        if self.bar and type(self.bar.icon_widgets) == "table" then
            for _i, btn in ipairs(self.bar.icon_widgets) do
                if btn and btn.image and not btn.image.dimen then
                    local ok_sz, sz = pcall(function() return btn.image:getSize() end)
                    if ok_sz and sz then
                        btn.image.dimen = Geom:new{ w = sz.w, h = sz.h }
                    end
                end
            end
        end
        ensure_panel_gestures(self)
        local Bar = self.bar and getmetatable(self.bar)
        if Bar and not Bar.__zen_rounded_tabs then
            Bar.__zen_rounded_tabs = true
            local paint_bar = Bar.paintTo
            function Bar:paintTo(bb, x, y)
                paint_bar(self, bb, x, y)
                paint_tab_elbows(self, bb, x, y)
            end
        end
        local frame = self.menu_frame
        if frame then
            -- Match the bottom sheet: round the inner corners, push the docked edge's corners off-screen.
            local radius = require("ui/size").radius.window
            local extension = radius + frame.bordersize
            -- Content is centered, so dropping side padding only pulls the corners on-screen.
            frame.padding_left, frame.padding_right, frame.radius = 0, 0, radius
            local paint = frame.paintTo
            frame.paintTo = function(f, bb, x, y)
                local docked_bottom = self._zen_panel_refs and self._zen_panel_refs.bottom_tabs and true
                f.padding_top = docked_bottom and 0 or extension
                -- Bottom tabs sit on the edge line, so their dividers reach it.
                f.padding_bottom = docked_bottom and extension or nil
                paint(f, bb, x, docked_bottom and y or y - extension)
                -- Keep the docked edge line the tab dividers join.
                local edge = docked_bottom and y + f:getSize().h - extension - f.bordersize or y
                bb:paintRect(x, edge, f:getSize().w, f.bordersize, f.color)
            end
        end
    end

    local orig_updateItems = TouchMenu.updateItems
    function TouchMenu:updateItems(target_page, target_item_id)
        cancel_sliders(self)
        -- FileManager may create its TouchMenu before Zen UI patches the class.
        ensure_panel_gestures(self)
        if self.footer and self.footer.resetLayout then
            for _i, slot in ipairs(self.footer) do
                if slot.dimen then
                    slot._zen_normal_height = slot._zen_normal_height or slot.dimen.h
                    slot.dimen.h = slot._zen_normal_height
                end
            end
            self.footer:resetLayout()
        end
        if not self.item_table or not self.item_table.panel then
            if self._zen_panel_refs and self._zen_panel_refs.bottom_tabs then
                self.dimen.y = 0
                UIManager:setDirty("all", "ui")
            end
            local cancelPanelRefresh = get_shared("cancelPanelRefresh")
            if type(cancelPanelRefresh) == "function" then
                cancelPanelRefresh(self)
            end
            self._zen_panel_refs = nil
            return orig_updateItems(self, target_page, target_item_id)
        end

        local previous_tab = self._zen_panel_refs and self._zen_panel_refs.tab_id
        local old_refs = self._zen_panel_refs
        if not self._zen_panel_refs then
            self._zen_panel_locked = true
            UIManager:scheduleIn(0.35, function()
                self._zen_panel_locked = false
            end)
        end

        local old_selected
        if self.selected then
            old_selected = { x = self.selected.x, y = self.selected.y }
        end
        self.item_group:clear()
        self.layout = {}
        local panel_fn = self.item_table.panel
        local panel = type(panel_fn) == "function" and panel_fn(self) or panel_fn
        local refs = self._zen_panel_refs
        if not (refs and refs.bottom_tabs) then
            table.insert(self.item_group, self.bar)
            table.insert(self.layout, self.bar.icon_widgets)
        end
        table.insert(self.item_group, panel)

        if refs then refs.tab_id = self.item_table.id end
        if refs and type(refs.layout_rows) == "table" then
            for _i, row in ipairs(refs.layout_rows) do
                if type(row) == "table" and #row > 0 then
                    table.insert(self.layout, row)
                end
            end
        elseif refs and refs.button_layout_row and #refs.button_layout_row > 0 then
            table.insert(self.layout, refs.button_layout_row)
        end

        local page = refs and refs.page or 1
        local page_num = refs and refs.page_num or 1
        if refs and refs.bottom_tabs then
            if page_num > 1 and not refs.pager then
                table.insert(self.item_group, self.page_info)
                table.insert(self.layout, { self.page_info_left_chev, self.page_info_right_chev })
            end
            table.insert(self.item_group, refs.bottom_tabs)
            table.insert(self.layout, refs.tab_layout)
        else
            table.insert(self.item_group, refs and refs.footer_top_margin or self.footer_top_margin)
            table.insert(self.item_group, self.footer)
        end
        if page_num > 1 then
            self.page_info_text:setText(T(_("Page %1 of %2"), page, page_num))
        else
            self.page_info_text:setText("")
        end
        self.page_info_left_chev:showHide(page_num > 1)
        self.page_info_right_chev:showHide(page_num > 1)
        local cycle_pages = self.item_table.id == "app_launcher"
        self.page_info_left_chev:enableDisable(page_num > 1 and (cycle_pages or page > 1))
        self.page_info_right_chev:enableDisable(page_num > 1 and (cycle_pages or page < page_num))
        if refs and refs.bottom_tabs and page_num > 1 then self.page_info:resetLayout() end

        local schedulePanelRefresh = get_shared("schedulePanelRefresh")
        if type(schedulePanelRefresh) == "function" then
            schedulePanelRefresh(self)
        end

        local old_dimen = self.dimen:copy()
        self.dimen.w = self.width
        self.dimen.h = self.item_group:getSize().h + self.bordersize * 2
            + (refs and refs.bottom_tabs and 0 or self.padding)
        self.dimen.y = refs and refs.bottom_tabs and Screen:getHeight() - self.dimen.h or 0
        local tab_x, tab_y = self.cur_tab, 1
        if refs and refs.bottom_tabs then tab_x, tab_y = 1, #self.layout end
        if old_selected then
            local row = self.layout[old_selected.y]
            if row and row[old_selected.x] then
                self:moveFocusTo(old_selected.x, old_selected.y, 0)
            else
                self:moveFocusTo(tab_x, tab_y, FocusManager.NOT_FOCUS)
            end
        else
            self:moveFocusTo(tab_x, tab_y, FocusManager.NOT_FOCUS)
        end

        local keep_bg = self.dimen.y == old_dimen.y and (self.dimen.h >= old_dimen.h
            or self._zen_hatched_background)
        local colored = Accent.isEnabled(active_plugin and active_plugin.config)
        local is_fresh = self.is_fresh -- Background hatching may clear this in onShow.
        local tab_changed = not is_fresh and previous_tab ~= self.item_table.id
        local swap_type = not is_fresh and not tab_changed and colored and M.viewSwapRefresh(old_refs, refs)
        UIManager:setDirty((self.is_fresh or keep_bg) and self.show_parent or "all", function()
            local refresh_dimen = old_dimen and old_dimen:combine(self.dimen) or self.dimen
            -- Clear old tab glyphs beneath colored fills when switching tabs or panel views.
            local color_refresh = colored and (Screen.night_mode == true or tab_changed)
            local refresh_type = color_refresh and "partial" or "ui"
            if swap_type then refresh_type, color_refresh = swap_type, true end
            if self.is_fresh or (colored and is_fresh) then
                refresh_type = colored and getFullRefreshMode() or "flashui"
                self.is_fresh = false
            end
            return refresh_type, refresh_dimen, color_refresh
        end)
    end

    local orig_switchMenuTab = TouchMenu.switchMenuTab
    function TouchMenu:switchMenuTab(tab_num, ...)
        local tab = self.tab_item_table and self.tab_item_table[tab_num]
        if tab_num == self.cur_tab and tab and not tab.callback then
            local changed = self.item_table ~= tab or (self.page or 1) ~= 1
            if tab.panel then
                local reset = self._zen_panel_refs and self._zen_panel_refs.reset
                changed = reset and reset() or self.item_table ~= tab
            end
            if not changed then return end
            self.item_table_stack, self.parent_id, self.item_table = {}, nil, tab
            return self:updateItems(1)
        end
        return orig_switchMenuTab(self, tab_num, ...)
    end

    local orig_onTapCloseAllMenus = TouchMenu.onTapCloseAllMenus
    function TouchMenu:onTapCloseAllMenus(arg, ges_ev)
        if in_panel_mode(self) then
            if self._zen_panel_locked then return true end
            if handle_panel_gesture(self, ges_ev, false) then
                return true
            end
        end
        return orig_onTapCloseAllMenus(self, arg, ges_ev)
    end

    local orig_onHoldCloseAllMenus = TouchMenu.onHoldCloseAllMenus
    function TouchMenu:onHoldCloseAllMenus(arg, ges_ev)
        if in_panel_mode(self) then
            if not self._zen_panel_locked then
                handle_panel_gesture(self, ges_ev, true)
            end
            return true
        end
        if orig_onHoldCloseAllMenus then
            return orig_onHoldCloseAllMenus(self, arg, ges_ev)
        end
    end

    local function close_panel_on_resize(tm)
        if tm and tm.item_table and tm.item_table.panel and tm.closeMenu then
            tm:closeMenu()
        end
        return false
    end

    local function forward_rotation_after_close(tm, rotation)
        close_panel_on_resize(tm)
        local stack = UIManager._window_stack
        local top = stack and stack[#stack] and stack[#stack].widget
        if top and top ~= tm and top ~= tm.show_parent and type(top.handleEvent) == "function" then
            return top:handleEvent(Event:new("SetRotationMode", rotation)) == true
        end
        return false
    end

    local orig_onSetRotationMode = TouchMenu.onSetRotationMode
    function TouchMenu:onSetRotationMode(rotation, ...)
        if rotation ~= nil and rotation ~= Screen:getRotationMode()
                and forward_rotation_after_close(self, rotation) then
            return true
        end
        if orig_onSetRotationMode then
            return orig_onSetRotationMode(self, rotation, ...)
        end
        return false
    end

    local orig_onSetDimensions = TouchMenu.onSetDimensions
    function TouchMenu:onSetDimensions(...)
        close_panel_on_resize(self)
        return orig_onSetDimensions and orig_onSetDimensions(self, ...)
    end

    local orig_onScreenResize = TouchMenu.onScreenResize
    function TouchMenu:onScreenResize(...)
        close_panel_on_resize(self)
        return orig_onScreenResize and orig_onScreenResize(self, ...)
    end

    ZenSlider.installTouchMenuHooks(TouchMenu, {
        in_panel_mode = function(tm)
            local refs = tm._zen_panel_refs
            return in_panel_mode(tm)
                and type(refs.sliders) == "table"
                and #refs.sliders > 0
        end,
        get_sliders = function(tm)
            local refs = tm._zen_panel_refs
            if not refs then return {} end
            local sliders = {}
            for _i, sr in ipairs(refs.sliders or {}) do
                table.insert(sliders, sr.slider)
            end
            return sliders
        end,
        is_locked           = function(tm) return tm._zen_panel_locked end,
        swipe_fallback      = function(tm, ges) handle_panel_gesture(tm, ges, false) end,
        multiswipe_fallback = function(tm, ges) handle_panel_gesture(tm, ges, false) end,
    })

    local orig_onCloseWidget = TouchMenu.onCloseWidget
    function TouchMenu:onCloseWidget()
        cancel_sliders(self)
        local cancelPanelRefresh = get_shared("cancelPanelRefresh")
        if type(cancelPanelRefresh) == "function" then
            cancelPanelRefresh(self)
        end
        self._zen_panel_refs = nil
        self._reader_controls_state = nil
        self._zen_panel_opening_pan = false
        if orig_onCloseWidget then orig_onCloseWidget(self) end
    end

    local function panel_goto(self, dir)
        local refs = self._zen_panel_refs
        if refs and type(refs.goto_page) == "function" then
            refs.goto_page((refs.page or 1) + dir)
        end
        return true
    end

    local orig_onPrevPage = TouchMenu.onPrevPage
    if orig_onPrevPage then
        function TouchMenu:onPrevPage()
            if self.item_table and self.item_table.panel then
                return panel_goto(self, -1)
            end
            return orig_onPrevPage(self)
        end
    end

    local orig_onNextPage = TouchMenu.onNextPage
    if orig_onNextPage then
        function TouchMenu:onNextPage()
            if self.item_table and self.item_table.panel then
                return panel_goto(self, 1)
            end
            return orig_onNextPage(self)
        end
    end
end

return M
