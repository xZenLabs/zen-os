describe("temporary reader return button", function()
    local saved, Button, button, ui, enabled, timers, queued, dirty, returns
    local painted_frame, saved_settings
    local names = { "modules/reader/return_button", "modules/reader/references", "ffi/blitbuffer",
        "common/ui/color_text_widget", "ui/font", "ui/widget/container/framecontainer", "ui/geometry",
        "common/reader_themes", "device", "ui/size", "ui/uimanager", "ui/widget/widget", "gettext", "ffi/util",
        "common/ui/button_feedback", "common/ui/color_icon_widget", "common/utils", "common/plugin_root",
        "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "common/reader_status_bar", "common/ui/button_labels",
        "apps/reader/modules/readerview" }

    before_each(function()
        saved, timers, queued, dirty, returns, enabled = {}, {}, {}, {}, 0, true
        painted_frame = nil
        saved_settings = G_reader_settings
        _G.G_reader_settings = ZenSpec.memorySettings()
        for _i, name in ipairs(names) do saved[name] = package.loaded[name] end
        for _i, name in ipairs(names) do ZenSpec.replace(name, {}) end
        local Widget = {}
        function Widget:extend(values) return setmetatable(values or {}, { __index = self }) end
        Widget.new = Widget.extend
        ZenSpec.replace("ui/widget/widget", Widget)
        ZenSpec.replace("ui/size", { radius = { window = 7 } })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("device", { hasColorScreen = function() return true end,
            screen = { bb = {}, getWidth = function() return 600 end,
            getHeight = function() return 800 end,
            scaleBySize = function(_self, size) return size end } })
        ZenSpec.replace("common/plugin_root", ZenSpec.root)
        ZenSpec.replace("common/utils", { resolveLocalIcon = function(dir, name) return dir .. name .. ".svg" end })
        for _i, name in ipairs({ "common/ui/color_icon_widget", "common/ui/color_text_widget",
            "ui/widget/horizontalgroup", "ui/widget/horizontalspan" }) do
            ZenSpec.replace(name, { new = function(_self, spec) return spec end })
        end
        ZenSpec.replace("ui/font", { getFace = function(_self, name, size)
            return { name = name, size = size }
        end })
        ZenSpec.replace("common/reader_themes", { getTextColor = function() return "sepia" end,
            getBackgroundColor = function() return "paper" end })
        ZenSpec.replace("ui/widget/container/framecontainer", { new = function(_self, spec)
            painted_frame = spec
            spec.getSize = function()
                return { w = 180, h = math.max(spec[1][1].height, spec[1][3].face.size)
                    + spec.padding_top + spec.padding_bottom + 2 * spec.bordersize }
            end
            spec.paintTo = function(_frame, _bb, x, y)
                local size = spec:getSize()
                spec.dimen = { x = x, y = y, w = size.w, h = size.h }
            end
            spec.free = function() end
            return spec
        end })
        ZenSpec.replace("ffi/util", { template = function(text, value) return (text:gsub("%%1", tostring(value))) end })
        ZenSpec.replace("ui/geometry", { new = function(_self, values) return values end })
        ZenSpec.replace("ui/uimanager", {
            nextTick = function(_self, callback) queued[#queued + 1] = callback end,
            scheduleIn = function(_self, delay, callback) timers[callback] = delay end,
            unschedule = function(_self, callback) timers[callback] = nil end,
            setDirty = function(_self, widget, mode) dirty[#dirty + 1] = mode end,
            getTopmostVisibleWidget = function() return ui end,
        })
        ZenSpec.replace("common/ui/button_feedback", { flashButton = function() end })
        ZenSpec.replace("common/ui/button_labels", { alignIcon = function(icon, label) icon.aligned_label = label end })
        ZenSpec.replace("modules/reader/references", { enabled = function() return enabled and ui or false end,
            locationPage = function(_ui, location) return location.page end,
            pageLabel = function(_ui, page) return tostring(page) end,
            goBack = function() returns = returns + 1 end })
        ZenSpec.unload("modules/reader/return_button")
        ZenSpec.unload("common/reader_status_bar")
        Button = require("modules/reader/return_button")
        ui = { page = 3, view = { footer = { horizontal_margin = 10,
            settings = { text_font_size = 14, text_font_bold = false },
            footer_text_face = { name = "NotoSans-Bold.ttf", size = 14 },
        } } }
        ui.link = { compareLocationToCurrent = function(_self, location) return location.page == ui.page end }
        button = Button:new{ ui = ui }
    end)

    after_each(function()
        _G.G_reader_settings = saved_settings
        for _i, name in ipairs(names) do package.loaded[name] = saved[name] end
    end)

    it("waits for an actual jump, then expires after 10 seconds", function()
        button:queue({ page = 3 })
        queued[#queued]()
        assert.is_false(button:isVisible())
        assert.same({}, timers)
        button:queue({ page = 3 })
        ui.page = 20
        queued[#queued]()
        assert.is_true(button:isVisible())
        assert.equals(10, timers[button.expire])
        button:paintTo(require("device").screen.bb, 0, 0)
        local mode, region = dirty[#dirty]()
        assert.equals("ui", mode)
        assert.same(button.dimen, region)
        local expire = button.expire
        ui.page = 21
        assert.equals(expire, button.expire)
        expire()
        assert.is_false(button:isVisible())
        assert.same({}, timers)
        local hide_mode, hide_region = dirty[#dirty]()
        assert.equals("ui", hide_mode)
        assert.same(region, hide_region)
    end)

    it("puts the themed return SVG before the renamed label within the width limit", function()
        button:queue({ page = 7 })
        queued[#queued]()
        button:paintTo(require("device").screen.bb, 0, 0)
        local row = painted_frame[1]
        assert.equals("Return to page 7", button.text)
        assert.matches("/icons/return.svg$", row[1].icon)
        assert.equals(row[3], row[1].aligned_label)
        assert.equals("sepia", row[1].fgcolor)
        assert.equals("Return to page 7", row[3].text)
        assert.equals("sepia", row[3].fgcolor)
        assert.equals(ui.view.footer.footer_text_face, row[3].face)
        assert.is_true(row[3].max_width + row[1].width + row[2].width
            + painted_frame.padding_left + painted_frame.padding_right + 2 * painted_frame.bordersize <= 600 * 0.48)
    end)

    it("follows live footer font settings on both screen types independently of the header", function()
        button:queue({ page = 7 })
        queued[#queued]()
        button.plugin = { config = { reader_top_status_bar = { font_face = "header.ttf", font_size = 40 } } }
        local device = require("device")
        local footer = ui.view.footer
        for _i, size in ipairs({ 14, 20, 32 }) do
            footer.settings.text_font_size = size
            footer.settings.text_font_bold = size > 14
            footer.footer_text_face = { name = "footer.ttf", size = size }
            for _j, color in ipairs({ true, false }) do
                device.hasColorScreen = function() return color end
                button:paintTo(device.screen.bb, 0, 0)
                assert.equals(footer.footer_text_face, painted_frame[1][3].face)
                assert.equals(footer.settings.text_font_bold, painted_frame[1][3].bold)
            end
        end
    end)

    it("uses the footer size before its font face is available", function()
        button:queue({ page = 7 })
        queued[#queued]()
        ui.view.footer.footer_text_face = nil
        ui.view.footer.settings.text_font_size = 22
        button:paintTo(require("device").screen.bb, 0, 0)
        assert.same({ name = "cfont", size = 22 }, painted_frame[1][3].face)
    end)

    it("anchors a rounded tab to the bottom left with its label fully on screen", function()
        button:queue({ page = 7 })
        queued[#queued]()
        local screen = require("device").screen
        for _i, size in ipairs({ { w = 600, h = 800 }, { w = 800, h = 600 } }) do
            screen.getWidth = function() return size.w end
            screen.getHeight = function() return size.h end
            for _j, font_size in ipairs({ 14, 32 }) do
                ui.view.footer.footer_text_face = { name = "footer.ttf", size = font_size }
                button:paintTo(screen.bb, 0, 0)
                local bounds = button.dimen
                assert.equals(10, bounds.x)
                assert.equals(require("ui/size").radius.window, painted_frame.radius)
                assert.equals(10, painted_frame.padding_left)
                assert.equals(10, painted_frame.padding_right)
                assert.equals(6, painted_frame.padding_top)
                assert.equals(6, painted_frame.padding_bottom - painted_frame.radius)
                assert.equals(font_size, painted_frame[1][3].face.size)
                assert.is_true(bounds.y > size.h / 2)
                assert.equals(size.h + painted_frame.radius, bounds.y + bounds.h)
                local content_bottom = bounds.y + painted_frame.bordersize + painted_frame.padding_top
                    + math.max(painted_frame[1][1].height, painted_frame[1][3].face.size)
                assert.is_true(content_bottom < size.h)
            end
        end
    end)

    it("follows the footer margin setting and asymmetric book margins without double scaling", function()
        button:queue({ page = 7 })
        queued[#queued]()
        button.plugin = { config = { features = { reader_status_bar_margins = true } } }
        ui.document = { getPageMargins = function() return { left = 61, right = 43 } end }
        local screen = require("device").screen
        screen.scaleBySize = function(_self, size) return 2 * size end
        button:paintTo(screen.bb, 0, 0)
        assert.equals(61, button.dimen.x)
        ui.document.getPageMargins = nil
        ui.document.configurable = { h_page_margins = { 31, 22 } }
        button:paintTo(screen.bb, 0, 0)
        assert.equals(62, button.dimen.x)
        button.plugin.config.features.reader_status_bar_margins = false
        button:paintTo(screen.bb, 0, 0)
        assert.equals(10, button.dimen.x)
    end)

    it("uses less vertical padding on monochrome screens while keeping footer-sized text visible", function()
        button:queue({ page = 7 })
        queued[#queued]()
        local device = require("device")
        local screen = device.screen
        for _i, size in ipairs({ { w = 600, h = 800 }, { w = 800, h = 600 }, { w = 1200, h = 1600 } }) do
            screen.getWidth = function() return size.w end
            screen.getHeight = function() return size.h end
            local scale = math.min(size.w, size.h) / 600
            screen.scaleBySize = function(_self, value) return math.ceil(value * scale) end
            device.hasColorScreen = function() return true end
            button:paintTo(screen.bb, 0, 0)
            local color_height = button.dimen.h
            assert.equals(ui.view.footer.footer_text_face, painted_frame[1][3].face)
            device.hasColorScreen = function() return false end
            button:paintTo(screen.bb, 0, 0)
            local padding = screen:scaleBySize(4)
            assert.equals(padding, painted_frame.padding_top)
            assert.equals(padding, painted_frame.padding_bottom - painted_frame.radius)
            assert.is_true(button.dimen.h < color_height)
            assert.equals(size.h + painted_frame.radius, button.dimen.y + button.dimen.h)
            local content_bottom = button.dimen.y + painted_frame.bordersize + painted_frame.padding_top
                + math.max(painted_frame[1][1].height, painted_frame[1][3].face.size)
            assert.is_true(content_bottom < size.h)
            assert.equals(ui.view.footer.footer_text_face, painted_frame[1][3].face)
        end
    end)

    it("replaces the timer on a new jump and cancels pending work on hide", function()
        button:queue({ page = 1 })
        queued[#queued]()
        local first = button.expire
        button:queue({ page = 2 })
        queued[#queued]()
        assert.is_nil(timers[first])
        assert.equals(10, timers[button.expire])
        assert.equals(2, button.location.page)
        button:queue({ page = 4 })
        button:hide()
        assert.is_nil(button.pending_callback)
        assert.is_nil(button.expire)
        assert.same({}, timers)
    end)

    it("does not arm a disabled feature and consumes only return-button taps", function()
        button:queue({ page = 1 })
        enabled = false
        queued[#queued]()
        assert.same({}, timers)
        enabled = true
        button:queue({ page = 1 })
        queued[#queued]()
        button.dimen = { contains = function(_self, pos) return pos.inside end }
        assert.is_false(button:onTap({ pos = {} }))
        assert.equals(0, returns)
        assert.is_true(button:onTap({ pos = { inside = true } }))
        assert.equals(1, returns)
        assert.same({}, timers)
    end)

    it("dismisses on a downward swipe on the tab without navigating or clearing history", function()
        button:queue({ page = 1 })
        queued[#queued]()
        button.dimen = { x = 10, y = 760, w = 180, h = 40, contains = function(_self, pos) return pos.inside end }
        local location = button.location
        ui.link.location_stack = { location }
        for _i, direction in ipairs({ "north", "east", "southeast", "southwest" }) do
            assert.is_false(button:onSwipe({ direction = direction, pos = { x = 50, y = 770, inside = true } }))
        end
        -- West only from the tab itself; elsewhere it remains a page turn.
        assert.is_false(button:onSwipe({ direction = "west", pos = { x = 50, y = 700 } }))
        -- Generous band: tab column +/- 24px, from 15% of screen height above the tab down.
        for _i, pos in ipairs({ { x = 50, y = 639 }, { x = -15, y = 770 }, { x = 214, y = 770 } }) do
            assert.is_false(button:onSwipe({ direction = "south", pos = pos }))
        end
        enabled = false
        assert.is_false(button:onSwipe({ direction = "south", pos = { x = 50, y = 770 } }))
        enabled = true
        assert.is_true(button:isVisible())
        assert.equals(10, timers[button.expire])
        local repaints = #dirty
        button:queue({ page = 2 })
        assert.is_true(button:onSwipe({ direction = "south", pos = { x = -14, y = 640 } }))
        assert.is_false(button:isVisible())
        assert.is_nil(button.location)
        assert.is_nil(button.pending_callback)
        assert.is_nil(button.expire)
        assert.same({}, timers)
        assert.equals(repaints + 1, #dirty)
        assert.equals(0, returns)
        assert.equals(3, ui.page)
        assert.same({ location }, ui.link.location_stack)
        assert.is_false(button:onSwipe({ direction = "south", pos = { x = 50, y = 770 } }))
        button:queue({ page = 4 })
        queued[#queued]()
        assert.is_true(button:onSwipe({ direction = "west", pos = { x = 50, y = 770, inside = true } }))
        assert.is_false(button:isVisible())
        assert.equals(0, returns)
    end)

    it("registers swipe dismissal ahead of existing reader swipe handlers", function()
        ui._zones = {
            rolling_swipe = { def = { ges = "swipe" } },
            readerconfigmenu_ext_swipe = { def = { ges = "swipe" } },
            tap_forward = { def = { ges = "tap" } },
        }
        local zones
        ui.registerTouchZones = function(_self, registered) zones = registered end
        Button.attach(ui)
        button = ui._zen_return_button
        button:queue({ page = 1 })
        queued[#queued]()
        assert.is_false(button:onSwipe({ direction = "south", pos = { x = 50, y = 770 } }))
        button.dimen = { x = 10, y = 760, w = 180, h = 40, contains = function(_self, pos) return pos.inside end }
        assert.equals("tap", zones[1].ges)
        assert.equals("swipe", zones[2].ges)
        assert.same({ ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 }, zones[2].screen_zone)
        table.sort(zones[2].overrides)
        assert.same({ "readerconfigmenu_ext_swipe", "rolling_swipe" }, zones[2].overrides)
        assert.is_false(zones[2].handler({ direction = "north", pos = { x = 50, y = 700 } }))
        assert.is_true(zones[2].handler({ direction = "south", pos = { x = 50, y = 700 } }))
        assert.is_false(button:isVisible())
        assert.equals("touch", zones[3].ges)
        assert.same({}, zones[3].overrides)
    end)

    it("samples raw contacts only while a tab touch is armed", function()
        local fed = 0
        local detector = { feedEvent = function(_self, tevs) fed = fed + #tevs; return {} end }
        package.loaded["device"].input = { gesture_detector = detector }
        ui.registerTouchZones = function() end
        Button.attach(ui)
        Button.attach({ view = ui.view, registerTouchZones = ui.registerTouchZones })
        button = ui._zen_return_button
        button:queue({ page = 1 })
        queued[#queued]()
        button.dimen = { x = 10, y = 760, w = 180, h = 40, contains = function(box, pos)
            return pos.x >= box.x and pos.x < box.x + box.w and pos.y >= box.y and pos.y < box.y + box.h
        end }
        detector:feedEvent({ { x = 50, y = 790 } })
        assert.is_nil(button.touch)
        button:onTouch({ pos = { x = 50, y = 780 } })
        detector:feedEvent({ { x = 50, y = 786 } })
        detector:feedEvent({ { x = 49, y = 779 } })
        assert.equals(3, fed)
        assert.same({ x = 50, y = 780, down = 6, up = 1, left = 1, right = 0 }, button.touch)
        assert.is_true(button:onTap({ pos = { x = 49, y = 779 } }))
        assert.is_false(button:isVisible())
        assert.equals(0, returns)
        package.loaded["device"].input = nil
    end)

    it("treats a short downward drag from the tab as a swipe away, not a tap", function()
        local function show()
            button:queue({ page = 1 })
            queued[#queued]()
            button.dimen = { x = 10, y = 760, w = 180, h = 40, contains = function(box, pos)
                return pos.x >= box.x and pos.x < box.x + box.w and pos.y >= box.y and pos.y < box.y + box.h
            end }
        end
        show()
        -- Touches outside the tab are passed through and never arm the drag.
        assert.is_false(button:onTouch({ pos = { x = 300, y = 770 } }))
        assert.is_false(button:onTap({ pos = { x = 300, y = 790 } }))
        assert.is_true(button:isVisible())
        -- Drag below KOReader's pan threshold still arrives as a tap at the lift point.
        assert.is_false(button:onTouch({ pos = { x = 50, y = 770 } }))
        assert.is_true(button:onTap({ pos = { x = 52, y = 799 } }))
        assert.is_false(button:isVisible())
        assert.equals(0, returns)
        assert.is_nil(button.touch_pos)
        -- Recessed screens: a 3px nudge is enough.
        show()
        button:onTouch({ pos = { x = 50, y = 770 } })
        assert.is_true(button:onTap({ pos = { x = 51, y = 773 } }))
        assert.is_false(button:isVisible())
        assert.equals(0, returns)
        -- A leftward nudge dismisses too.
        show()
        button:onTouch({ pos = { x = 50, y = 770 } })
        assert.is_true(button:onTap({ pos = { x = 46, y = 771 } }))
        assert.is_false(button:isVisible())
        assert.equals(0, returns)
        -- Lift points drift back on recessed bezels; the furthest raw sample decides.
        show()
        button:onTouch({ pos = { x = 50, y = 780 } })
        button.touch.down = 6
        assert.is_true(button:onTap({ pos = { x = 50, y = 779 } }))
        assert.is_false(button:isVisible())
        assert.equals(0, returns)
        -- Sub-threshold jitter and rightward drags remain explicit taps.
        show()
        button:onTouch({ pos = { x = 50, y = 770 } })
        assert.is_true(button:onTap({ pos = { x = 51, y = 772 } }))
        assert.equals(1, returns)
        show()
        button:onTouch({ pos = { x = 50, y = 770 } })
        assert.is_true(button:onTap({ pos = { x = 60, y = 775 } }))
        assert.equals(2, returns)
    end)
end)
