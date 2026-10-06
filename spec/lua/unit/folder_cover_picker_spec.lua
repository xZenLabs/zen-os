describe("full-screen folder cover picker", function()
    local Picker
    local shown
    local next_ticks
    local screen_w
    local screen_h
    local menu_row_h
    local draw_calls
    local decorated
    local zen_paints
    local saved_feedback

    local function widget_class(kind)
        local Widget = {}
        function Widget:new(values)
            values = values or {}
            values.kind = kind
            return setmetatable(values, { __index = self })
        end
        function Widget:paintTo(_bb, x, y)
            self.paint_x = x
            self.paint_y = y
        end
        return Widget
    end

    before_each(function()
        saved_feedback = package.loaded["common/ui/button_feedback"]
        ZenSpec.replace("common/ui/button_feedback", { flashButton = function() end })
        shown = {}
        next_ticks = {}
        screen_w = 600
        screen_h = 800
        menu_row_h = 180
        draw_calls = {}
        decorated = {}
        zen_paints = {}

        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return screen_w end,
                getHeight = function() return screen_h end,
                scaleBySize = function(_self, value) return value end,
            },
        })
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_BLACK = "black",
            COLOR_LIGHT_GRAY = "light-gray",
            COLOR_WHITE = "white",
        })
        ZenSpec.replace("ui/bidi", {
            directory = function(path) return "dir:" .. path end,
        })
        ZenSpec.replace("apps/filemanager/filemanagerutil", {
            abbreviate = function(path) return "abbr:" .. path end,
        })
        ZenSpec.replace("ui/font", {
            sizemap = { smallinfofont = 18 },
            getFace = function() return "face" end,
        })
        ZenSpec.replace("ui/geometry", {
            new = function(_self, values) return values end,
        })
        ZenSpec.replace("ui/size", {
            border = { default = 1 },
            line = { medium = 3 },
            padding = { fullscreen = 10 },
        })
        local InputContainer = {}
        InputContainer.__index = InputContainer
        function InputContainer:extend(values)
            values = values or {}
            values.__index = values
            return setmetatable(values, { __index = self })
        end
        function InputContainer:new(values)
            values = values or {}
            values.kind = values.kind or self.kind or "input"
            values = setmetatable(values, { __index = self })
            if values.init then values:init() end
            return values
        end
        ZenSpec.replace("ui/widget/container/inputcontainer", InputContainer)
        ZenSpec.replace("ui/widget/container/centercontainer",
            widget_class("center"))
        ZenSpec.replace("ui/widget/container/framecontainer",
            widget_class("frame"))
        ZenSpec.replace("ui/widget/container/rightcontainer",
            widget_class("right"))
        ZenSpec.replace("ui/gesturerange",
            widget_class("gesture-range"))
        ZenSpec.replace("ui/widget/overlapgroup",
            widget_class("overlap-group"))
        local TextWidget = widget_class("text")
        function TextWidget:getSize()
            return { w = #(self.text or "") * 10, h = 20 }
        end
        function TextWidget:free()
            self.freed = true
        end
        ZenSpec.replace("ui/widget/textwidget", TextWidget)
        ZenSpec.replace("common/ui/zen_button", {
            paintFilled = function(_bb, x, y, w, h, text, font_size, radius)
                zen_paints[#zen_paints + 1] = {
                    style = "filled",
                    x = x,
                    y = y,
                    w = w,
                    h = h,
                    text = text,
                    font_size = font_size,
                    radius = radius,
                }
            end,
            paintOutlined = function(_bb, x, y, w, h, text, font_size, radius)
                zen_paints[#zen_paints + 1] = {
                    style = "outlined",
                    x = x,
                    y = y,
                    w = w,
                    h = h,
                    text = text,
                    font_size = font_size,
                    radius = radius,
                }
            end,
        })
        ZenSpec.replace("common/cover_utils", {
            loadExplicitCover = function(path)
                return { path = path, data = "image:" .. path, w = 120, h = 180 }
            end,
            drawSingle = function(cover, width, height, border, uniform)
                draw_calls[#draw_calls + 1] = {
                    path = cover.path,
                    width = width,
                    height = height,
                    border = border,
                    uniform = uniform,
                }
                return {
                    kind = "cover-frame",
                    path = cover.path,
                    width = width + 2 * border,
                    height = height + 2 * border,
                    background = "light-gray",
                }
            end,
        })
        ZenSpec.replace("modules/filebrowser/patches/home/widgets/cover_common", {
            decorate_cover_frame = function(frame)
                frame.decorated = true
                decorated[#decorated + 1] = frame
                return frame
            end,
        })
        local Menu = { __index = nil }
        Menu.__index = Menu
        function Menu:extend(values)
            values = values or {}
            values.__index = values
            return setmetatable(values, { __index = self })
        end
        function Menu:new(values)
            values = setmetatable(values or {}, { __index = self })
            values:init()
            return values
        end
        function Menu:init()
            self.dimen = { x = 0, y = 0, w = screen_w, h = screen_h }
            self.ges_events = {}
            self.key_events = { Press = true }
            self.item_group = self.item_group or {}
            self.perpage = self.items_per_page
            self.title_bar = {
                getHeight = function() return 50 end,
            }
            self.page_info = {
                dimen = { w = 20, h = 10 },
                getSize = function(page_info) return page_info.dimen end,
                paintTo = function() return "painted" end,
                propagateEvent = function() return true end,
            }
            self.page_info_text = {
                tap_input = true,
                hold_input = true,
                call_hold_input_on_tap = true,
            }
            self:_recalculateDimen()
            self:updatePageInfo()
        end
        function Menu:_recalculateDimen()
            self.perpage = self.items_per_page
            self.inner_dimen = {
                x = 0,
                y = 0,
                w = screen_w,
                h = 50 + menu_row_h * self.perpage,
            }
            self.item_dimen = {
                x = 0,
                y = 0,
                w = self.inner_dimen.w,
                h = menu_row_h,
            }
        end
        function Menu:updatePageInfo(select_number)
            self.page_info_updates = self.page_info_updates or {}
            self.page_info_updates[#self.page_info_updates + 1] = select_number
            self.page_info.dimen = { w = 20, h = 10 }
        end
        function Menu:updateItems(selected_slot, recalculate)
            self.update_calls = self.update_calls or {}
            self.update_calls[#self.update_calls + 1] = {
                selected_slot = selected_slot,
                recalculate = recalculate,
            }
            self.item_group = {}
            for index = 1, #self.item_table do
                local item = {
                    entry = self.item_table[index],
                    dimen = {
                        x = 0,
                        y = 50 + (index - 1) * self.item_dimen.h,
                        w = screen_w,
                        h = self.item_dimen.h,
                    },
                    _underline_container = { color = "black" },
                }
                function item:onFocus()
                    self._underline_container.color = "black"
                    return true
                end
                function item:onUnfocus()
                    self._underline_container.color = "dark-gray"
                    return true
                end
                self.item_group[index] = item
            end
            self:updatePageInfo(selected_slot)
        end
        function Menu:onMenuSelect(item)
            if item.callback then item.callback() end
            return true
        end
        function Menu:getFocusItem()
            return self.focused_item
        end
        function Menu:propagateEvent()
            self.base_propagate_calls = (self.base_propagate_calls or 0) + 1
            return false
        end
        function Menu:onScreenResize()
            self.dimen = { x = 0, y = 0, w = screen_w, h = screen_h }
            self.resize_count = (self.resize_count or 0) + 1
            self:_recalculateDimen()
            self:updatePageInfo()
            return false
        end
        ZenSpec.replace("ui/widget/menu", Menu)
        ZenSpec.replace("ui/uimanager", {
            show = function(_self, widget, mode)
                shown[#shown + 1] = { widget = widget, mode = mode }
            end,
            nextTick = function(_self, callback)
                next_ticks[#next_ticks + 1] = callback
            end,
        })
        ZenSpec.replace("gettext", setmetatable({}, {
            __call = function(_self, text) return text end,
        }))

        ZenSpec.unload("common/ui/folder_cover_picker")
        Picker = require("common/ui/folder_cover_picker")
    end)

    after_each(function()
        package.loaded["common/ui/button_feedback"] = saved_feedback
        ZenSpec.unload("common/ui/folder_cover_picker")
    end)

    it("uses live mosaic cover bounds, styling, and clear buttons", function()
        local selected = {}
        local selection_updaters = {}
        local cleared = {}
        local menu = Picker.show{
            path = "/library/series",
            slot_count = 4,
            covers = {
                [1] = "/images/first.jpg",
                [3] = "/images/third.jpg",
            },
            cover_ratio = 0.5,
            border = 2,
            uniform = false,
            mosaic_cover_width = 120,
            mosaic_cover_height = 180,
            mosaic_portrait = true,
            mosaic_cols_portrait = 3,
            mosaic_rows_portrait = 3,
            mosaic_cols_landscape = 4,
            mosaic_rows_landscape = 2,
            on_select = function(slot, update)
                selected[#selected + 1] = slot
                selection_updaters[slot] = update
            end,
            on_clear = function(slot, update)
                cleared[#cleared + 1] = slot
                update(nil)
            end,
        }

        assert.are.equal("folder_cover_picker", menu.name)
        assert.are.equal(600, menu.dimen.w)
        assert.are.equal(800, menu.dimen.h)
        assert.are.equal(4, menu.items_per_page)
        assert.is_false(menu.is_enable_shortcut)
        assert.is_true(menu.single_line)
        assert.are.equal(128, menu.state_w)
        assert.are.equal(176, menu.item_dimen.h)
        assert.are.equal(704, menu.available_height)
        assert.is_true(menu.is_borderless)
        assert.is_false(menu.is_popout)
        assert.is_true(menu.title_bar_fm_style)
        assert.is_true(menu.covers_fullscreen)
        assert.is_true(menu._zen_no_forced_repaint)
        assert.is_true(menu.show_path)
        assert.are.equal("dir:abbr:/library/series", menu.subtitle)
        assert.are.same({ widget = menu, mode = "full" }, shown[1])
        assert.are.equal(4, #menu.item_table)
        assert.are.same({ w = 0, h = 0 }, menu.page_info:getSize())
        assert.is_nil(menu.page_info:paintTo())
        assert.is_false(menu.page_info:propagateEvent())
        assert.is_nil(menu.page_info_text.tap_input)
        assert.is_nil(menu.page_info_text.hold_input)
        assert.is_false(menu.page_info_text.call_hold_input_on_tap)
        assert.are.equal("gesture-range",
            menu.ges_events.FolderCoverTap[1].kind)
        assert.are.equal("tap", menu.ges_events.FolderCoverTap[1].ges)
        assert.are.equal(menu.dimen,
            menu.ges_events.FolderCoverTap[1].range)
        assert.are.equal("FolderCoverTap",
            menu.ges_events.FolderCoverTap.event)

        for index = 1, 4 do
            local row = menu.item_group[index]
            assert.are.equal("white", row._underline_container.color)
            assert.is_true(row:onFocus())
            assert.are.equal("black", row._underline_container.color)
            assert.is_true(row:onUnfocus())
            assert.are.equal("white", row._underline_container.color)
        end

        for slot = 1, 4 do
            local item = menu.item_table[slot]
            assert.are.equal("Cover " .. tostring(slot), item.text)
            assert.are.equal(slot, item.slot)
            assert.are.equal("row-state", item.state.kind)
            assert.are.same({ w = 290, h = 160 }, item.state:getSize())
            assert.are.same({ w = 580, h = 160 }, item.state.tap_dimen)
            assert.are.equal("gesture-range",
                item.state.ges_events.TapSelect[1].kind)
            assert.are.equal("tap", item.state.ges_events.TapSelect[1].ges)
            assert.are.equal(item.state.tap_dimen,
                item.state.ges_events.TapSelect[1].range)
            local visual = item.state[1]
            assert.are.equal("overlap-group", visual.kind)
            assert.is_true(visual.allow_mirroring)
            assert.are.same({ w = 580, h = 160 }, visual.dimen)
            assert.are.equal("center", visual[1].kind)
            assert.are.same({ w = 116, h = 160 }, visual[1].dimen)
            assert.are.equal("right", visual[2].kind)
            assert.is_true(visual[2].allow_mirroring)
            assert.are.same({ w = 580, h = 160 }, visual[2].dimen)
            assert.are.equal(item.clear_button, visual[2][1])
            assert.are.equal("input", item.clear_button.kind)
            assert.are.equal("Clear", item.clear_button.text)
            assert.are.equal(100, item.clear_button.width)
            assert.are.equal(46, item.clear_button.height)
            assert.are.same({ w = 100, h = 46 }, item.clear_button.dimen)
            assert.are.equal("gesture-range",
                item.clear_button.ges_events.TapSelect[1].kind)
            assert.are.equal("tap",
                item.clear_button.ges_events.TapSelect[1].ges)
            assert.are.equal(item.clear_button.dimen,
                item.clear_button.ges_events.TapSelect[1].range)
        end
        assert.is_true(menu.item_table[1].clear_button.enabled)
        assert.is_false(menu.item_table[2].clear_button.enabled)
        assert.is_true(menu.item_table[3].clear_button.enabled)
        assert.is_false(menu.item_table[4].clear_button.enabled)

        local first_frame = menu.item_table[1].state[1][1][1]
        assert.are.equal("cover-frame", first_frame.kind)
        assert.are.equal("/images/first.jpg", first_frame.path)
        assert.is_true(first_frame.decorated)
        assert.are.same({
            path = "/images/first.jpg",
            width = 112,
            height = 156,
            border = 2,
            uniform = false,
        }, draw_calls[1])

        local empty_frame = menu.item_table[2].state[1][1][1]
        assert.are.equal("frame", empty_frame.kind)
        assert.are.equal(82, empty_frame.width)
        assert.are.equal(160, empty_frame.height)
        assert.are.equal("light-gray", empty_frame.background)
        assert.is_true(empty_frame.decorated)
        assert.are.equal("+", empty_frame[1][1].text)
        assert.are.equal(4, #decorated)

        menu.item_table[1].state:paintTo("bb", 10, 54)
        assert.are.same({ x = 10, y = 54, w = 580, h = 160 },
            menu.item_table[1].state.tap_dimen)
        assert.is_true(menu.item_table[1].state:onTapSelect())
        assert.are.same({ 1 }, selected)
        assert.are.same({}, cleared)

        assert.are.same({ "Press" }, menu.key_events.FolderCoverSelect[1])
        assert.are.same({ "Return" }, menu.key_events.FolderCoverSelect[2])
        assert.are.same({ "Enter" }, menu.key_events.FolderCoverSelect[3])
        assert.are.equal("FolderCoverSelect",
            menu.key_events.FolderCoverSelect.event)
        assert.is_nil(menu.key_events.Press)
        menu.focused_item = { entry = menu.item_table[2] }
        assert.is_true(menu:onFolderCoverSelect())
        assert.are.same({ 1, 2 }, selected)
        assert.are.same({}, cleared)

        menu.item_table[1].clear_button:paintTo("bb", 470, 63)
        menu.item_table[2].clear_button:paintTo("bb", 470, 243)
        assert.are.same({
            style = "filled",
            x = 470,
            y = 63,
            w = 100,
            h = 46,
            text = "Clear",
            font_size = 18,
            radius = 10,
        }, zen_paints[1])
        assert.are.same({
            style = "outlined",
            x = 470,
            y = 243,
            w = 100,
            h = 46,
            text = "Clear",
            font_size = 18,
            radius = 10,
        }, zen_paints[2])

        assert.is_true(menu.item_table[2].clear_button:onTapSelect())
        assert.are.same({}, cleared)

        local old_items = menu.item_table
        assert.is_true(menu.item_table[1].clear_button:onTapSelect())
        assert.are.same({ 1, 2 }, selected)
        assert.are.same({ 1 }, cleared)
        assert.are.equal(1, #next_ticks)
        assert.are.equal(old_items, menu.item_table)

        table.remove(next_ticks, 1)()
        assert.are_not.equal(old_items, menu.item_table)
        assert.is_nil(menu.item_table[1].preview_path)
        assert.are.equal("input", menu.item_table[1].clear_button.kind)
        assert.is_false(menu.item_table[1].clear_button.enabled)
        assert.are.equal("+", menu.item_table[1].state[1][1][1][1][1].text)
        assert.are.same({
            { selected_slot = 1, recalculate = false },
            { selected_slot = 1, recalculate = false },
        }, menu.update_calls)

        menu:onMenuHold(menu.item_table[3])
        assert.are.same({ 1, 3 }, cleared)
        table.remove(next_ticks, 1)()
        assert.is_false(menu.item_table[3].clear_button.enabled)
        menu:onMenuHold(menu.item_table[3])
        assert.are.same({ 1, 3 }, cleared)

        menu:onMenuSelect(menu.item_table[4])
        assert.are.same({ 1, 2, 4 }, selected)
        selection_updaters[4]("/images/fourth.jpg")
        table.remove(next_ticks, 1)()
        assert.are.equal(1, menu.page)
        assert.are.same({ selected_slot = 4, recalculate = false },
            menu.update_calls[#menu.update_calls])
        assert.are.equal("/images/fourth.jpg", menu.item_table[4].preview_path)
        assert.are.equal("input", menu.item_table[4].clear_button.kind)
        assert.is_true(menu.item_table[4].clear_button.enabled)
        assert.are.equal("/images/fourth.jpg",
            menu.item_table[4].state[1][1][1].path)

        local cleared_groups = 0
        menu.item_group = {
            clear = function() cleared_groups = cleared_groups + 1 end,
        }
        local portrait_items = menu.item_table
        screen_w, screen_h = 800, 600
        menu_row_h = 130
        assert.is_false(menu:onScreenResize())
        assert.are.equal(1, cleared_groups)
        assert.are.equal(800, menu.dimen.w)
        assert.are.equal(600, menu.dimen.h)
        assert.are.equal(1, menu.resize_count)
        assert.are_not.equal(portrait_items, menu.item_table)
        assert.are.equal(4, menu.items_per_page)
        assert.are.equal(126, menu.item_dimen.h)
        assert.are.equal(504, menu.available_height)
        assert.are.equal(191, menu.state_w)
        assert.are.equal("row-state", menu.item_table[4].state.kind)
        assert.are.same({ w = 390, h = 110 },
            menu.item_table[4].state:getSize())
        local landscape_visual = menu.item_table[4].state[1]
        assert.are.equal("overlap-group", landscape_visual.kind)
        assert.is_true(landscape_visual.allow_mirroring)
        assert.are.same({ w = 780, h = 110 },
            landscape_visual.dimen)
        assert.are.same({ w = 179, h = 110 },
            landscape_visual[1].dimen)
        assert.are.equal("right", landscape_visual[2].kind)
        assert.is_true(landscape_visual[2].allow_mirroring)
        assert.are.same({ w = 780, h = 110 },
            landscape_visual[2].dimen)
        assert.are.equal(menu.item_table[4].clear_button,
            landscape_visual[2][1])
        assert.are.same({
            path = "/images/fourth.jpg",
            width = 175,
            height = 106,
            border = 2,
            uniform = false,
        }, draw_calls[#draw_calls])
        assert.are.same({ w = 0, h = 0 }, menu.page_info:getSize())
        assert.is_nil(menu.page_info:paintTo())
        assert.is_false(menu.page_info:propagateEvent())
    end)

    it("shows one slot in single-cover mode at the native mosaic density", function()
        local menu = Picker.show{
            slot_count = 1,
            covers = {},
            cover_ratio = 2 / 3,
            border = 1,
            mosaic_cover_width = 100,
            mosaic_cover_height = 150,
            mosaic_portrait = true,
            mosaic_rows_portrait = 3,
        }

        assert.are.equal(4, menu.items_per_page)
        assert.are.equal(1, #menu.item_table)
        assert.are.equal("Cover 1", menu.item_table[1].text)
        assert.are.equal("row-state", menu.item_table[1].state.kind)
        assert.are.same({ w = 290, h = 144 },
            menu.item_table[1].state:getSize())
        local visual = menu.item_table[1].state[1]
        assert.are.equal("overlap-group", visual.kind)
        assert.is_true(visual.allow_mirroring)
        assert.are.same({ w = 580, h = 144 },
            visual.dimen)
        assert.are.same({ w = 94, h = 144 },
            visual[1].dimen)
        assert.are.equal("right", visual[2].kind)
        assert.is_true(visual[2].allow_mirroring)
        assert.are.same({ w = 580, h = 144 },
            visual[2].dimen)
        assert.are.equal(menu.item_table[1].clear_button,
            visual[2][1])
        assert.are.equal("input", menu.item_table[1].clear_button.kind)
        assert.is_false(menu.item_table[1].clear_button.enabled)
    end)

    it("falls back to painted row hit testing for cover and Clear taps", function()
        local selected = {}
        local cleared = {}
        local menu = Picker.show{
            slot_count = 1,
            covers = { [1] = "/images/first.jpg" },
            on_select = function(slot)
                selected[#selected + 1] = slot
            end,
            on_clear = function(slot)
                cleared[#cleared + 1] = slot
            end,
        }

        menu.item_table[1].clear_button:paintTo("bb", 470, 90)
        assert.is_true(menu:onFolderCoverTap(nil, {
            pos = { x = 200, y = 100 },
        }))
        assert.are.same({ 1 }, selected)
        assert.are.same({}, cleared)

        assert.is_true(menu.item_group[1]:onTapSelect())
        assert.are.same({ 1, 1 }, selected)
        assert.is_true(menu.item_group[1]:onHoldSelect())
        assert.are.same({ 1 }, cleared)

        assert.is_true(menu:onFolderCoverTap(nil, {
            pos = { x = 500, y = 100 },
        }))
        assert.are.same({ 1, 1 }, selected)
        assert.are.same({ 1, 1 }, cleared)

        assert.is_true(menu:propagateEvent({
            handler = "onGesture",
            args = {{
                ges = "tap",
                pos = { x = 200, y = 100 },
            }},
        }))
        assert.are.same({ 1, 1, 1 }, selected)
        assert.is_nil(menu.base_propagate_calls)

        assert.is_true(menu:propagateEvent({
            handler = "onGesture",
            args = {{
                ges = "hold",
                pos = { x = 200, y = 100 },
            }},
        }))
        assert.are.same({ 1, 1, 1 }, cleared)
        assert.is_nil(menu.base_propagate_calls)

        assert.is_false(menu:propagateEvent({
            handler = "onGesture",
            args = {{
                ges = "tap",
                pos = { x = 200, y = 790 },
            }},
        }))
        assert.are.equal(1, menu.base_propagate_calls)
    end)

    it("leaves label space when the live mosaic uses one wide column", function()
        local menu = Picker.show{
            slot_count = 1,
            covers = { [1] = "/images/wide.jpg" },
            cover_ratio = 2 / 3,
            border = 2,
            mosaic_cover_width = 560,
            mosaic_cover_height = 180,
            mosaic_portrait = true,
            mosaic_cols_portrait = 1,
        }

        assert.are.equal(176, menu.item_dimen.h)
        assert.are.same({ w = 290, h = 160 },
            menu.item_table[1].state:getSize())
        local visual = menu.item_table[1].state[1]
        assert.are.equal("overlap-group", visual.kind)
        assert.is_true(visual.allow_mirroring)
        assert.are.same({ w = 580, h = 160 },
            visual.dimen)
        assert.are.same({ w = 378, h = 160 }, visual[1].dimen)
        assert.are.equal(390, menu.state_w)
        assert.is_true(580 - menu.state_w - 100 > 0)
        assert.are.equal("right", visual[2].kind)
        assert.is_true(visual[2].allow_mirroring)
        assert.are.same({ w = 580, h = 160 },
            visual[2].dimen)
        assert.are.same({
            path = "/images/wide.jpg",
            width = 374,
            height = 156,
            border = 2,
            uniform = true,
        }, draw_calls[#draw_calls])
    end)
end)
