describe("Zen icon picker", function()
    local saved_modules
    local shown
    local selected
    local closed
    local focused_cell
    local close_inverted
    local footer_focus_x
    local painted_page
    local device_has_dpad
    local device_has_keyboard
    local device_is_touch
    local close_icon
    local close_paint_x
    local title_spec
    local text_values

    local module_names = {
        "gettext",
        "device",
        "ui/geometry",
        "ffi/blitbuffer",
        "ui/font",
        "ui/size",
        "ui/uimanager",
        "ui/widget/focusmanager",
        "ui/widget/container/centercontainer",
        "ui/widget/container/framecontainer",
        "ui/widget/verticalgroup",
        "ui/widget/horizontalgroup",
        "ui/widget/iconwidget",
        "ui/widget/textwidget",
        "common/ui/zen_pager",
        "common/ui/zen_title_style",
        "common/ui/zen_icon_picker",
    }

    local function widget_class(kind)
        local class = {}

        function class:new(values)
            values = values or {}
            values._kind = kind
            setmetatable(values, { __index = self })
            return values
        end

        function class:paintTo(bb, x, y)
            if self._kind == "frame" and self.invert then
                focused_cell = self._frame_index
            end
            for _i, child in ipairs(self) do
                if child.paintTo then child:paintTo(bb, x, y) end
            end
        end

        return class
    end

    local function focus_manager()
        local FocusManager = {}

        function FocusManager:extend(definition)
            definition = definition or {}
            setmetatable(definition, { __index = self })
            return definition
        end

        function FocusManager:new(values)
            values = values or {}
            setmetatable(values, { __index = self })
            values:init()
            return values
        end

        function FocusManager:_init()
            self.key_events = {
                FocusDown = { { "Down" }, event = "FocusMove", args = { 0, 1 } },
                Press = { { "Press" }, event = "Press" },
            }
        end

        function FocusManager:registerTouchZones(zones) self.touch_zones = zones end

        return FocusManager
    end

    local function icons(count)
        local items = {}
        for i = 1, count do
            items[i] = { name = string.format("icon_%02d", i) }
        end
        return items
    end

    local function paint()
        focused_cell = nil
        footer_focus_x = nil
        shown:paintTo({
            paintRect = function() end,
            invertRect = function(_bb, x) footer_focus_x = x end,
        }, 0, 0)
    end

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(module_names) do
            saved_modules[name] = package.loaded[name] or false
        end
        shown = nil
        selected = nil
        closed = 0
        focused_cell = nil
        close_inverted = nil
        footer_focus_x = nil
        painted_page = nil
        device_has_dpad = true
        device_has_keyboard = false
        device_is_touch = false
        close_icon = nil
        close_paint_x = nil
        title_spec = nil
        text_values = {}

        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 300 end,
                scaleBySize = function(_, value) return value end,
            },
            input = { group = { Back = { "Back" }, PgBack = { "PgBack" }, PgFwd = { "PgFwd" } } },
            hasKeys = function() return true end,
            hasDPad = function() return device_has_dpad end,
            hasKeyboard = function() return device_has_keyboard end,
            isTouchDevice = function() return device_is_touch end,
        })
        ZenSpec.replace("ui/geometry", {
            new = function(_, values)
                values.intersectWith = function(self, other)
                    return self.x >= other.x and self.x < other.x + other.w
                        and self.y >= other.y and self.y < other.y + other.h
                end
                return values
            end,
        })
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_BLACK = "black",
            COLOR_LIGHT_GRAY = "light_gray",
            COLOR_WHITE = "white",
        })
        ZenSpec.replace("ui/font", {
            sizemap = { xx_smallinfofont = 18 },
            getFace = function() return {} end,
        })
        ZenSpec.replace("ui/size", {
            padding = { default = 10 },
            span = { vertical_default = 4 },
        })
        ZenSpec.replace("ui/uimanager", {
            show = function(_, widget) shown = widget end,
            close = function() closed = closed + 1 end,
            forceRePaint = function() end,
            nextTick = function(_, callback) callback() end,
            setDirty = function() end,
        })
        ZenSpec.replace("ui/widget/focusmanager", focus_manager())
        ZenSpec.replace("ui/widget/container/centercontainer", widget_class("center"))

        local frame_count = 0
        local Frame = widget_class("frame")
        local frame_new = Frame.new
        function Frame:new(values)
            local frame = frame_new(self, values)
            frame_count = frame_count + 1
            frame._frame_index = frame_count
            return frame
        end
        ZenSpec.replace("ui/widget/container/framecontainer", Frame)
        ZenSpec.replace("ui/widget/verticalgroup", widget_class("vertical"))
        ZenSpec.replace("ui/widget/horizontalgroup", widget_class("horizontal"))
        ZenSpec.replace("ui/widget/iconwidget", {
            new = function(_, values)
                if values.icon == "close" then close_icon = values end
                values.paintTo = function(self, _bb, x)
                    if self.icon == "close" then
                        close_inverted = self.invert
                        close_paint_x = x
                    end
                end
                return values
            end,
        })
        ZenSpec.replace("ui/widget/textwidget", {
            new = function(_, values)
                if values.text == "Select icon" then title_spec = values end
                text_values[#text_values + 1] = values.text
                values.getSize = function() return { w = 100, h = 20 } end
                values.paintTo = function(self, _bb, x) self.paint_x = x end
                values.free = function() end
                return values
            end,
        })
        ZenSpec.replace("common/ui/zen_pager", {
            CHEV_W = 20,
            CHEV_HIT_W = 40,
            PN_FOOTER_H = 30,
            flashChevron = function() end,
            getHoldSkip = function() return "ends" end,
            getCenteredFooterY = function(content_bottom, footer_y, footer_h)
                local gap_h = footer_y + footer_h - content_bottom
                return content_bottom + math.floor((gap_h - footer_h) / 2)
            end,
            getPageNumberZone = function(x, y, footer_x, footer_y, footer_w, footer_h, available_bottom)
                local hit_bottom = math.min(footer_y + footer_h + 24, available_bottom)
                if x < footer_x or x >= footer_x + footer_w
                        or y < footer_y or y >= hit_bottom then
                    return nil
                end
                if x < footer_x + 40 then return "left" end
                if x >= footer_x + footer_w - 40 then return "right" end
                if y < footer_y + footer_h then return "center" end
            end,
            paint = function(_bb, _x, _y, _w, _h, cur_page)
                painted_page = cur_page
            end,
        })
        ZenSpec.replace("common/ui/zen_title_style", {
            ICON_SIZE = 28,
            BUTTON_SIZE = 44,
            LEFT_PADDING = 4,
            RIGHT_PADDING = 20,
            ROW_HEIGHT = 44,
            VERTICAL_PADDING = 6,
            DIVIDER_HEIGHT = 2,
            DIVIDER_COLOR = "light_gray",
            HEADER_CONTENT_HEIGHT = 56,
            HEADER_HEIGHT = 58,
            getTitleFace = function() return { name = "settings_title" } end,
            getTitleX = function(origin) return (origin or 0) + 54 end,
            getTrailingIconX = function(width, origin)
                return (origin or 0) + width - 56
            end,
        })
        ZenSpec.unload("common/ui/zen_icon_picker")
    end)

    after_each(function()
        for _i, name in ipairs(module_names) do
            package.loaded[name] = saved_modules[name] or nil
        end
    end)

    it("moves focus through every grid direction and activates the icon", function()
        require("common/ui/zen_icon_picker")(icons(10), "icon_01", function(name)
            selected = name
        end)

        paint()
        assert.are.equal(1, focused_cell)
        assert.is_true(shown:onFocusMove({ 1, 0 }))
        assert.is_true(shown:onFocusMove({ 0, 1 }))
        paint()
        assert.are.equal(9, focused_cell)
        assert.is_true(shown:onPress())
        assert.are.equal("icon_09", selected)
    end)

    it("labels the legacy Zen icon as ZenOS without changing its stored ID", function()
        require("common/ui/zen_icon_picker")({ { name = "zen_ui" } }, "zen_ui", function(name)
            selected = name
        end)

        assert.is_true(table.concat(text_values, "\n"):find("ZenOS", 1, true) ~= nil)
        assert.is_nil(table.concat(text_values, "\n"):find("zen_ui", 1, true))
        assert.is_true(shown:onPress())
        assert.are.equal("zen_ui", selected)
    end)

    it("focuses and activates the top-right close button from the first row", function()
        require("common/ui/zen_icon_picker")(icons(2), "icon_01", function() end)

        assert.is_true(shown:onFocusMove({ 0, -1 }))
        paint()
        assert.is_true(close_inverted)
        assert.is_nil(focused_cell)
        assert.is_true(shown:onPress())
        assert.are.equal(1, closed)
    end)

    it("closes only when the top-right header button is tapped", function()
        require("common/ui/zen_icon_picker")(icons(2), "icon_01", function() end)
        local tap = shown.touch_zones[1].handler
        local function pos(x, y)
            return { x = x, y = y, intersectWith = function() return false end }
        end

        assert.is_true(tap({ pos = pos(10, 10) }))
        assert.are.equal(0, closed)
        assert.is_true(tap({ pos = pos(560, 10) }))
        assert.are.equal(1, closed)
    end)

    it("aligns its title and close icon with the arrange-list header", function()
        require("common/ui/zen_icon_picker")(icons(2), "icon_01", function() end)
        paint()

        assert.are.equal("settings_title", title_spec.face.name)
        assert.are.equal(54, title_spec.paint_x)
        assert.are.equal(28, close_icon.width)
        assert.are.equal(544, close_paint_x)
    end)

    it("keeps focus on the grid when there is no footer pager", function()
        require("common/ui/zen_icon_picker")(icons(2), "icon_01", function(name)
            selected = name
        end)

        assert.is_true(shown:onFocusMove({ 0, 1 }))
        paint()
        assert.are.equal(1, focused_cell)
        assert.is_nil(footer_focus_x)
        assert.is_true(shown:onPress())
        assert.are.equal("icon_01", selected)
    end)

    it("focuses both footer page arrows and returns to the last grid row", function()
        require("common/ui/zen_icon_picker")(icons(16), "icon_08", function(name)
            selected = name
        end)

        assert.is_true(shown:onFocusMove({ 0, 1 }))
        paint()
        assert.are.equal(10, footer_focus_x)

        assert.is_true(shown:onFocusMove({ 1, 0 }))
        paint()
        assert.are.equal(570, footer_focus_x)
        assert.is_true(shown:onPress())
        paint()
        assert.are.equal(2, painted_page)

        assert.is_true(shown:onFocusMove({ -1, 0 }))
        paint()
        assert.are.equal(10, footer_focus_x)
        assert.is_true(shown:onPress())
        paint()
        assert.are.equal(1, painted_page)

        assert.is_true(shown:onFocusMove({ 1, 0 }))
        assert.is_true(shown:onPress())
        assert.is_true(shown:onFocusMove({ 0, -1 }))
        assert.is_true(shown:onPress())
        assert.are.equal("icon_16", selected)
    end)

    it("registers direct arrow events for keyed devices without a D-pad", function()
        device_has_dpad = false
        device_has_keyboard = true
        device_is_touch = true
        require("common/ui/zen_icon_picker")(icons(2), nil, function() end)

        assert.is_not_nil(shown.key_events.IconPickerUp)
        assert.is_not_nil(shown.key_events.IconPickerDown)
        assert.is_not_nil(shown.key_events.IconPickerLeft)
        assert.is_not_nil(shown.key_events.IconPickerRight)
        assert.is_not_nil(shown.key_events.IconPickerSelect)
    end)

    it("accepts wider chevron taps briefly below the painted footer", function()
        require("common/ui/zen_icon_picker")(icons(16), "icon_01", function() end)
        local tap = shown.touch_zones[1].handler
        local function pos(x, y)
            return { x = x, y = y, intersectWith = function() return false end }
        end

        assert.is_true(tap({ pos = pos(40, 270) }))
        paint()
        assert.are.equal(2, painted_page)
        assert.is_true(tap({ pos = pos(300, 270) }))
        assert.is_true(tap({ pos = pos(40, 290) }))
        paint()
        assert.are.equal(2, painted_page)
    end)
end)
