describe("Wrapped screen", function()
    local WrappedScreen
    local saved_modules
    local closed, freed, text_widgets

    local module_names = {
        "gettext", "ffi/blitbuffer", "device", "device/input", "ui/font", "ui/geometry", "ui/uimanager",
        "ui/widget/container/inputcontainer", "ui/widget/imagewidget", "ui/widget/iconwidget",
        "ui/widget/scrolltextwidget", "ui/widget/textboxwidget", "ui/widget/textwidget",
        "common/plugin_root", "common/ui/zen_button", "common/ui/zen_title_style", "common/ui/button_feedback",
        "common/ui/zen_screen", "common/ui/wrapped_screen", "common/zen_logger",
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
    function InputContainer:registerTouchZones() end

    local function widget(values, w, h)
        values = values or {}
        values.getSize = function() return { w = w or 100, h = h or 24 } end
        values.paintTo = function() end
        values.free = function() end
        return values
    end

    local bb = { paintRect = function() end, invertRect = function() end }

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(module_names) do saved_modules[name] = package.loaded[name] or false end
        closed, freed, text_widgets = 0, 0, {}
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_WHITE = "white", COLOR_BLACK = "black", COLOR_LIGHT_GRAY = "light_gray", COLOR_DARK_GRAY = "dark_gray",
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
            isTouchDevice = function() return true end,
            hasColorScreen = function() return false end,
        })
        ZenSpec.replace("device/input", { group = { PgFwd = "PgFwd", PgBack = "PgBack", Back = "Back" } })
        ZenSpec.replace("ui/font", { getFace = function(_self, name, size) return { name = name, size = size } end })
        ZenSpec.replace("ui/geometry", { new = function(_self, values) return values end })
        ZenSpec.replace("ui/uimanager", {
            close = function() closed = closed + 1 end,
            scheduleIn = function() end,
            setDirty = function() end,
        })
        ZenSpec.replace("ui/widget/container/inputcontainer", InputContainer)
        ZenSpec.replace("ui/widget/imagewidget", { new = function(_self, values) return widget(values, 200, 300) end })
        ZenSpec.replace("ui/widget/iconwidget", { new = function(_self, values) return widget(values, values.width, values.height) end })
        ZenSpec.replace("ui/widget/scrolltextwidget", { new = function(_self, values) return widget(values) end })
        ZenSpec.replace("ui/widget/textboxwidget", { new = function(_self, values) return widget(values, values.width, 40) end })
        ZenSpec.replace("ui/widget/textwidget", { new = function(_self, values)
            text_widgets[#text_widgets + 1] = values
            -- Width grows with the font size so the stat fitter has something to shrink.
            local size = values.face and values.face.size or 20
            return widget(values, math.floor(#(values.text or "") * size * 0.6), size)
        end })
        ZenSpec.replace("common/plugin_root", "/plugin")
        ZenSpec.replace("common/ui/zen_button", {
            paintFilled = function(_bb, x, y, w, h) return { x = x, y = y, w = w, h = h } end,
            paintOutlined = function(_bb, x, y, w, h) return { x = x, y = y, w = w, h = h } end,
        })
        ZenSpec.replace("common/ui/zen_title_style", {
            ICON_SIZE = 28, TITLE_LEADING_PADDING = 6, VERTICAL_PADDING = 6, ROW_HEIGHT = 44,
            DIVIDER_HEIGHT = 2, DIVIDER_COLOR = "light_gray", HEADER_CONTENT_HEIGHT = 56, HEADER_HEIGHT = 58,
            getTitleFace = function() return { name = "settings_title" } end,
        })
        ZenSpec.replace("common/ui/button_feedback", { flashButton = function() end })
        ZenSpec.replace("common/zen_logger", { new = function() return { info = function() end } end })
        ZenSpec.unload("common/ui/zen_screen")
        ZenSpec.unload("common/ui/wrapped_screen")
        WrappedScreen = require("common/ui/wrapped_screen")
    end)

    after_each(function()
        _G.__ZEN_QUICKSTART_JUST_CLOSED = nil
        ZenSpec.unload("common/ui/wrapped_screen")
        ZenSpec.unload("common/ui/zen_screen")
        for _i, name in ipairs(module_names) do package.loaded[name] = saved_modules[name] or nil end
    end)

    local function screen(pages)
        return WrappedScreen:new{ pages = pages or {
            { icon = "/icons/zen_ui.svg", stat = "2026", stat_label = "Your year in books", description = "Swipe" },
            { icon = "/icons/timer.svg", stat = "12h 30m", stat_label = "spent reading", description = "Quip" },
            { icon = "/icons/zen_ui.svg", stat = "That's a wrap", stat_label = "2026", description = "Bye" },
        } }
    end

    it("labels the buttons Next, Back and Done by page", function()
        local s = screen()
        assert.are.equal("Reading Wrapped", s.title)
        assert.are.equal("Next", s.button)
        assert.is_nil(s.later_button)
        s:setPage(2)
        assert.are.equal("Back", s.later_button)
        assert.are.equal("Next", s.button)
        s:setPage(3)
        assert.are.equal("Done", s.button)
    end)

    it("swipes between pages without ever closing", function()
        local s = screen()
        s:_onSwipe({ direction = "west" })
        s:_onSwipe({ direction = "west" })
        s:_onSwipe({ direction = "west" })
        assert.are.equal(3, s._page_idx)
        s:_onSwipe({ direction = "east" })
        assert.are.equal(2, s._page_idx)
        assert.are.equal(0, closed)
    end)

    it("navigates with the buttons and dots and ignores other taps", function()
        local s = screen()
        s:paintTo(bb, 0, 0)
        s:_onTap({ pos = { x = 300, y = 400 } })
        assert.are.equal(1, s._page_idx)
        local btn = s._btn_rect
        s:_onTap({ pos = { x = btn.x + 1, y = btn.y + 1 } })
        assert.are.equal(2, s._page_idx)
        s:paintTo(bb, 0, 0)
        local dots = s._dot_rect
        s:_onTap({ pos = { x = dots.x + dots.w - 1, y = dots.y + 1 } })
        assert.are.equal(3, s._page_idx)
        s:paintTo(bb, 0, 0)
        local back = s._later_btn_rect
        s:_onTap({ pos = { x = back.x + 1, y = back.y + 1 } })
        assert.are.equal(2, s._page_idx)
        s:setPage(3)
        s:paintTo(bb, 0, 0)
        assert.are.equal(0, closed)
        s:_onTap({ pos = { x = s._btn_rect.x + 1, y = s._btn_rect.y + 1 } })
        assert.are.equal(1, closed)
    end)

    it("steps back on page-back and closes on Back or Home", function()
        local s = screen()
        s:setPage(2)
        assert.is_true(s:onZsDismiss())
        assert.are.equal(1, s._page_idx)
        assert.is_true(s:onZsDismiss())
        assert.are.equal(1, s._page_idx)
        assert.are.equal(0, closed)
        assert.is_true(s:onZsCancelOrClose())
        assert.are.equal(1, closed)
    end)

    it("frees covers on close", function()
        local cover = { free = function() freed = freed + 1 end }
        local pages = { { image_bb = cover, stat = "Dune", stat_label = "7h", description = "Quip" } }
        local s = screen(pages)
        s:paintTo(bb, 0, 0)
        s:onClose()
        assert.are.equal(1, freed)
        assert.is_nil(pages[1].image_bb)
        assert.are.equal(1, closed)
    end)

    it("shrinks a long stat until it fits and keeps a short one large", function()
        local long = string.rep("A", 40)
        local s = screen({ { stat = long, stat_label = "x", description = "y" }, { stat = "2026" } })
        s:paintTo(bb, 0, 0)
        local size
        for _i, w in ipairs(text_widgets) do if w.text == long then size = w.face.size end end
        assert.are.equal(24, size)
        s:setPage(2)
        text_widgets = {}
        s:paintTo(bb, 0, 0)
        for _i, w in ipairs(text_widgets) do if w.text == "2026" then size = w.face.size end end
        assert.are.equal(64, size)
    end)
end)
