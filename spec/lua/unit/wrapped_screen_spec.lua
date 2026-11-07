describe("Wrapped screen", function()
    local WrappedScreen
    local saved_modules
    local closed, freed, text_widgets, box_widgets

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
        closed, freed, text_widgets, box_widgets = 0, 0, {}, {}
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
        ZenSpec.replace("ui/widget/textboxwidget", { new = function(_self, values)
            box_widgets[#box_widgets + 1] = values
            return widget(values, values.width, 40)
        end })
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

    local function screen(pages, extra)
        local spec = { pages = pages or {
            { title = "Reading Wrapped", icon = "/icons/zen_ui.svg", stat = "2026", stat_label = "Your year in books", description = "Swipe" },
            { title = "Time spent reading", icon = "/icons/timer.svg", stat = "12h 30m", stat_label = "spent reading", description = "Quip" },
            { icon = "/icons/zen_ui.svg", stat = "That's a wrap", stat_label = "2026", description = "Bye" },
        } }
        for key, value in pairs(extra or {}) do spec[key] = value end
        return WrappedScreen:new(spec)
    end

    local function heading()
        for _i, w in ipairs(box_widgets) do
            if w.bold and w.face.size == 36 then return w.text end
        end
    end

    it("labels the buttons Next, Back and Done and draws each heading in the content", function()
        local s = screen()
        assert.is_nil(s.title)
        assert.are.equal(0, s._L.title_h)
        s.pages[3].title = nil
        assert.are.equal("Next", s.button)
        assert.is_nil(s.later_button)
        s:paintTo(bb, 0, 0)
        assert.are.equal("Reading Wrapped", heading())
        s:setPage(2)
        box_widgets = {}
        s:paintTo(bb, 0, 0)
        assert.are.equal("Time spent reading", heading())
        assert.are.equal("Back", s.later_button)
        assert.are.equal("Next", s.button)
        s:setPage(3)
        box_widgets = {}
        s:paintTo(bb, 0, 0)
        assert.is_nil(heading())
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

    it("paints single, grid and coverflow layouts and frees the shared covers on close", function()
        local painted = {}
        ZenSpec.replace("ui/widget/imagewidget", { new = function(_self, values)
            painted[#painted + 1] = { w = values.width, h = values.height }
            return widget(values, values.width, values.height)
        end })
        ZenSpec.unload("common/ui/wrapped_screen")
        WrappedScreen = require("common/ui/wrapped_screen")
        local bb_a = { free = function() freed = freed + 1 end }
        local bb_b = { free = function() freed = freed + 1 end }
        local cover_a, cover_b = { bb = bb_a, w = 200, h = 300 }, { bb = bb_b, w = 200, h = 300 }
        local pages = {
            { covers = { cover_a }, layout = "grid", stat = "Dune", stat_label = "7h", description = "Quip" },
            { covers = { cover_a, cover_b, cover_a, cover_b }, layout = "grid", stat = "4", stat_label = "books" },
            { covers = { cover_a, cover_b, cover_a }, layout = "flow", stat = "9h", stat_label = "time" },
        }
        local s = screen(pages, { covers_owned = { bb_a, bb_b }, rounded_covers = true })
        s:paintTo(bb, 0, 0)
        assert.are.equal(1, #painted)
        assert.is_true(painted[1].h > painted[1].w)
        s:setPage(2)
        painted = {}
        s:paintTo(bb, 0, 0)
        assert.are.equal(4, #painted)
        assert.is_true(painted[1].w < 200)
        s:setPage(3)
        painted = {}
        s:paintTo(bb, 0, 0)
        assert.are.equal(3, #painted)
        assert.is_true(painted[3].h > painted[1].h)
        s:onClose()
        assert.are.equal(2, freed)
        assert.is_nil(s.covers_owned)
        assert.is_nil(pages[1].covers)
        assert.are.equal(1, closed)
    end)

    it("joins a short stat with its unit on one line and stacks a long one", function()
        local long = string.rep("B", 30)
        local s = screen({ { stat = "12h", unit = "spent reading" }, { stat = long, unit = "spent reading" } })
        s:paintTo(bb, 0, 0)
        local sizes = {}
        for _i, w in ipairs(text_widgets) do sizes[w.text] = w.face.size end
        assert.are.equal(64, sizes["12h"])
        assert.are.equal(22, sizes["spent reading"])
        for _i, w in ipairs(box_widgets) do assert.are_not.equal("spent reading", w.text) end
        s:setPage(2)
        text_widgets, box_widgets = {}, {}
        s:paintTo(bb, 0, 0)
        sizes = {}
        for _i, w in ipairs(text_widgets) do sizes[w.text] = w.face.size end
        assert.are.equal(28, sizes[long])
        local stacked
        for _i, w in ipairs(box_widgets) do if w.text == "spent reading" then stacked = w end end
        assert.are.equal(22, stacked.face.size)
    end)

    it("shrinks a long stat, wraps when it still overflows, and sizes text stats like the heading", function()
        local long = string.rep("A", 40)
        local s = screen({ { stat = long, stat_label = "x", description = "y" }, { stat = "2026" }, { stat = "Dune", stat_text = true } })
        s:paintTo(bb, 0, 0)
        local size, wrapped
        for _i, w in ipairs(text_widgets) do if w.text == long then size = w.face.size end end
        for _i, w in ipairs(box_widgets) do if w.text == long then wrapped = w end end
        assert.are.equal(24, size)
        assert.is_true(wrapped.bold)
        assert.are.equal(24, wrapped.face.size)
        s:setPage(2)
        text_widgets = {}
        s:paintTo(bb, 0, 0)
        for _i, w in ipairs(text_widgets) do if w.text == "2026" then size = w.face.size end end
        assert.are.equal(64, size)
        s:setPage(3)
        text_widgets = {}
        s:paintTo(bb, 0, 0)
        for _i, w in ipairs(text_widgets) do if w.text == "Dune" then size = w.face.size end end
        assert.are.equal(36, size)
    end)
end)
