describe("Zen screen", function()
    local ZenScreen
    local saved_modules
    local closed
    local dirty_modes
    local inverted
    local image_widgets
    local scroll_widgets
    local text_widgets
    local color_screen

    local module_names = {
        "gettext",
        "ffi/blitbuffer",
        "device",
        "device/input",
        "ui/font",
        "ui/geometry",
        "ui/uimanager",
        "ui/widget/container/inputcontainer",
        "ui/widget/imagewidget",
        "ui/widget/scrolltextwidget",
        "ui/widget/textboxwidget",
        "ui/widget/textwidget",
        "common/plugin_root",
        "common/zen_screen",
        "common/ui/zen_button",
        "common/ui/zen_title_style",
        "common/ui/zen_screen",
        "common/zen_logger",
    }

    local InputContainer = {}

    function InputContainer:extend(definition)
        definition = definition or {}
        setmetatable(definition, { __index = self })
        definition.__index = definition
        return definition
    end

    function InputContainer:new(values)
        values = values or {}
        setmetatable(values, { __index = self })
        values:init()
        return values
    end

    function InputContainer:registerTouchZones(zones)
        self.touch_zones = zones
    end

    local function text_widget(values)
        values = values or {}
        values.getSize = function() return { w = 100, h = 24 } end
        values.paintTo = function() end
        values.free = function() end
        return values
    end

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(module_names) do
            saved_modules[name] = package.loaded[name] or false
        end
        closed = 0
        dirty_modes = {}
        inverted = {}
        image_widgets = {}
        scroll_widgets = {}
        text_widgets = {}
        color_screen = false

        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_WHITE = "white",
            COLOR_BLACK = "black",
            COLOR_LIGHT_GRAY = "light_gray",
        })
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
                scaleBySize = function(_self, size) return size end,
                night_mode = false,
            },
            hasKeys = function() return true end,
            hasDPad = function() return true end,
            isTouchDevice = function() return false end,
            hasColorScreen = function() return color_screen end,
        })
        ZenSpec.replace("device/input", {
            group = { PgFwd = "PgFwd", PgBack = "PgBack", Back = "Back" },
        })
        ZenSpec.replace("ui/font", { getFace = function(_self, name, size)
            return { name = name, size = size }
        end })
        ZenSpec.replace("ui/geometry", { new = function(_self, values) return values end })
        ZenSpec.replace("ui/uimanager", {
            close = function() closed = closed + 1 end,
            scheduleIn = function() end,
            setDirty = function(_self, _widget, mode)
                if type(mode) == "function" then mode = mode() end
                dirty_modes[#dirty_modes + 1] = mode
            end,
        })
        ZenSpec.replace("ui/widget/container/inputcontainer", InputContainer)
        ZenSpec.replace("ui/widget/imagewidget", { new = function(_self, values)
            image_widgets[#image_widgets + 1] = values
            return text_widget(values)
        end })
        ZenSpec.replace("ui/widget/scrolltextwidget", {
            updateScrollBar = function(widget, is_partial)
                if not widget.for_measurement_only then
                    dirty_modes[#dirty_modes + 1] = is_partial and "partial" or "ui"
                end
            end,
            new = function(_self, values)
                scroll_widgets[#scroll_widgets + 1] = {
                    for_measurement_only = values.for_measurement_only,
                }
                values.text_widget = { for_measurement_only = values.for_measurement_only }
                values:updateScrollBar()
                return text_widget(values)
            end,
        })
        ZenSpec.replace("ui/widget/textboxwidget", { new = function(_self, values) return text_widget(values) end })
        ZenSpec.replace("ui/widget/textwidget", { new = function(_self, values)
            text_widgets[#text_widgets + 1] = values
            return text_widget(values)
        end })
        ZenSpec.replace("common/plugin_root", "/plugin")
        ZenSpec.replace("common/ui/zen_button", {
            paintFilled = function(_bb, x, y, w, h) return { x = x, y = y, w = w, h = h } end,
            paintOutlined = function(_bb, x, y, w, h) return { x = x, y = y, w = w, h = h } end,
        })
        ZenSpec.replace("common/ui/zen_title_style", {
            ICON_SIZE = 28,
            TITLE_LEADING_PADDING = 6,
            VERTICAL_PADDING = 6,
            ROW_HEIGHT = 44,
            DIVIDER_HEIGHT = 2,
            DIVIDER_COLOR = "light_gray",
            HEADER_CONTENT_HEIGHT = 56,
            HEADER_HEIGHT = 58,
            getTitleFace = function() return { name = "settings_title" } end,
        })
        ZenSpec.replace("common/zen_logger", {
            new = function()
                return { info = function() end }
            end,
        })
        ZenSpec.unload("common/ui/zen_screen")
        ZenScreen = require("common/ui/zen_screen")
    end)

    after_each(function()
        _G.__ZEN_QUICKSTART_JUST_CLOSED = nil
        ZenSpec.unload("common/ui/zen_screen")
        for _i, name in ipairs(module_names) do
            package.loaded[name] = saved_modules[name] or nil
        end
    end)

    local function new_screen(values)
        return ZenScreen:new(values or {})
    end

    it("uses a flashing initial refresh on color screens", function()
        color_screen = true
        local screen = new_screen{ title = "ZenOS", scroll_text = "Changes" }
        screen:onShow()
        assert.is_true(screen.covers_fullscreen)
        assert.are.equal("flashui", dirty_modes[#dirty_modes])
    end)

    it("suppresses the scroll widget's redundant initial refresh", function()
        color_screen = true
        local screen = new_screen{ title = "ZenOS", scroll_text = "Changes" }
        screen:paintTo({ paintRect = function() end, invertRect = function() end }, 0, 0)

        assert.is_true(scroll_widgets[1].for_measurement_only)
        assert.is_false(screen._scroll_text_w.for_measurement_only)
        assert.is_false(screen._scroll_text_w.text_widget.for_measurement_only)
        assert.are.same({}, dirty_modes)
    end)

    it("uses only a full-screen fast refresh for color-screen changelog updates", function()
        color_screen = true
        local screen = new_screen{ title = "ZenOS", scroll_text = "Changes" }
        screen:paintTo({ paintRect = function() end, invertRect = function() end }, 0, 0)
        dirty_modes = {}
        screen._scroll_text_w:updateScrollBar(true)

        assert.are.same({ "fast" }, dirty_modes)
    end)

    it("focuses the primary action and confirms the selected button", function()
        local primary_actions = 0
        local screen = new_screen{
            button = "Update now",
            later_button = "Later",
            _on_button_action = function() primary_actions = primary_actions + 1 end,
        }

        assert.are.equal("primary", screen._button_focus)
        assert.is_true(screen._button_focus_visible)
        assert.is_true(screen:onZsConfirm())
        assert.are.equal(1, primary_actions)
        assert.are.equal(0, closed)

        assert.is_true(screen:onZsFocusPrevious())
        assert.are.equal("later", screen._button_focus)
        assert.are.equal("fast", dirty_modes[#dirty_modes])
        assert.is_true(screen:onZsConfirm())
        assert.are.equal(1, closed)
    end)

    it("cycles focus and keeps page-forward as the primary shortcut", function()
        local primary_actions = 0
        local screen = new_screen{
            button = "Update now",
            later_button = "Later",
            _on_button_action = function() primary_actions = primary_actions + 1 end,
        }

        screen:onZsFocusNext()
        assert.are.equal("later", screen._button_focus)
        screen:onZsFocusNext()
        assert.are.equal("primary", screen._button_focus)
        screen:onZsFocusPrevious()
        assert.are.equal("later", screen._button_focus)
        assert.is_true(screen:onZsPrimary())
        assert.are.equal(1, primary_actions)

        assert.are.equal("ZsFocusNext", screen.key_events.ZsFocusNext.event)
        assert.are.equal("ZsFocusPrevious", screen.key_events.ZsFocusPrevious.event)
        assert.are.equal("ZsPrimary", screen.key_events.ZsConfirmPgFwd.event)
    end)

    it("uses hardware Back and Home to cancel or close", function()
        local cancel_actions = 0
        local cancel_screen = new_screen{
            button = "Cancel",
            dismissable = false,
            _on_button_action = function() cancel_actions = cancel_actions + 1 end,
        }

        assert.are.same({ "Back" }, cancel_screen.key_events.ZsCancelOrClose[1])
        assert.are.same({ "Home" }, cancel_screen.key_events.ZsCancelOrClose[2])
        assert.is_true(cancel_screen:onZsCancelOrClose())
        assert.are.equal(1, cancel_actions)
        assert.are.equal(0, closed)

        local update_actions = 0
        local update_screen = new_screen{
            button = "Update now",
            later_button = "Later",
            dismissable = true,
            _on_button_action = function() update_actions = update_actions + 1 end,
        }
        assert.is_true(update_screen:onZsCancelOrClose())
        assert.are.equal(0, update_actions)
        assert.are.equal(1, closed)

        local progress_screen = new_screen{ button = false, dismissable = false }
        assert.is_true(progress_screen:onZsCancelOrClose())
        assert.are.equal(1, closed)
    end)

    it("normalizes focus when an update changes the available buttons", function()
        local screen = new_screen{
            button = false,
            later_button = false,
            dismissable = false,
        }
        assert.is_nil(screen._button_focus)

        screen:update{ later_button = "Close" }
        assert.are.equal("later", screen._button_focus)

        screen:update{ button = "OK", later_button = false }
        assert.are.equal("primary", screen._button_focus)

        screen:update{ button = false, later_button = false }
        assert.is_nil(screen._button_focus)
    end)

    it("inverts only the focused button while painting", function()
        local screen = new_screen{ button = "Update now", later_button = "Later", hide_logo = true }
        local bb = {
            paintRect = function() end,
            invertRect = function(_self, x, y, w, h)
                inverted[#inverted + 1] = { x = x, y = y, w = w, h = h }
            end,
        }

        screen:paintTo(bb, 0, 0)
        assert.are.same({ x = 308, y = 733, w = 200, h = 54 }, inverted[#inverted])

        screen:onZsFocusPrevious()
        screen:paintTo(bb, 0, 0)
        assert.are.same({ x = 92, y = 733, w = 200, h = 54 }, inverted[#inverted])
    end)

    it("caps the centered logo when a short changelog leaves extra space", function()
        local screen = new_screen{
            title = "ZenOS",
            title_icon = true,
            subtitle = "Updated to v1.2.3",
            changelog = { "Small update" },
            scroll_text = "What's New\n\n- Small update",
        }
        local bb = {
            paintRect = function() end,
            invertRect = function() end,
        }

        screen:paintTo(bb, 0, 0)

        assert.are.equal(0, screen._L.sep_h)
        assert.are.equal(2, #image_widgets)
        assert.are.equal(28, image_widgets[1].width)
        assert.are.equal(330, image_widgets[2].width)
        assert.are.equal(330, image_widgets[2].height)
        for _i, widget in ipairs(text_widgets) do
            if widget.text == "ZenOS" then
                assert.are.equal("cfont", widget.face.name)
                assert.are.equal(28, widget.face.size)
                return
            end
        end
        assert.fail("ZenOS title was not rendered")
    end)
end)
