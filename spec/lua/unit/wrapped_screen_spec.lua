describe("Wrapped screen", function()
    local WrappedScreen
    local saved_modules
    local closed, freed, text_widgets, box_widgets, backdrops, cards, refreshes, corner_buffers

    local module_names = {
        "gettext", "ffi/blitbuffer", "device", "device/input", "ui/font", "ui/geometry", "ui/uimanager",
        "ui/widget/container/inputcontainer", "ui/widget/imagewidget", "ui/widget/iconwidget",
        "ui/widget/scrolltextwidget", "ui/widget/textboxwidget", "ui/widget/textwidget",
        "common/plugin_root", "common/ui/zen_button", "common/ui/zen_title_style", "common/ui/button_feedback",
        "common/ui/zen_screen", "common/ui/wrapped_backdrops", "common/ui/wrapped_screen", "common/zen_logger",
        "common/ui/refresh",
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
        values.paintTo = function(_self, _bb, x, y) values.painted = { x = x, y = y } end
        values.free = function() end
        return values
    end

    local bb = {
        paintRect = function() end, invertRect = function() end, blitFrom = function() end,
        lightenRect = function() end, getType = function() return "bb8" end,
        paintBorder = function(_self, x, y, w, h) cards[#cards + 1] = { x = x, y = y, w = w, h = h } end,
    }

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(module_names) do saved_modules[name] = package.loaded[name] or false end
        closed, freed, text_widgets, box_widgets, backdrops, cards, refreshes, corner_buffers = 0, 0, {}, {}, {}, {}, {}, 0
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_WHITE = "white", COLOR_BLACK = "black", COLOR_LIGHT_GRAY = "light_gray", COLOR_DARK_GRAY = "dark_gray",
            new = function()
                corner_buffers = corner_buffers + 1
                return { blitFrom = function() end, free = function() end }
            end,
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
            setDirty = function(_self, _widget, refresh)
                if type(refresh) == "function" then refreshes[#refreshes + 1] = (refresh()) end
            end,
        })
        ZenSpec.replace("common/ui/refresh", function() return "full" end)
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
        ZenSpec.replace("common/ui/wrapped_backdrops", { paint = function(_bb, index, count, x, y, w, h, clear)
            backdrops[#backdrops + 1] = { index = index, count = count, x = x, y = y, w = w, h = h, clear = clear }
        end })
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
            { title = "Time spent reading", icon = "/icons/timer.svg", stat = "12h 30m", description = "Quip" },
            { icon = "/icons/zen_ui.svg", stat = "That's a wrap", stat_label = "2026", description = "Bye" },
        } }
        for key, value in pairs(extra or {}) do spec[key] = value end
        return WrappedScreen:new(spec)
    end

    local function heading()
        for _i, w in ipairs(text_widgets) do
            if w.bold and w.face.size == 36 then return w.text end
        end
    end

    -- The widget that was actually painted for a text (fitting creates and drops others).
    local function painted(text)
        for _i, list in ipairs({ text_widgets, box_widgets }) do
            for _j, w in ipairs(list) do
                if w.text == text and w.painted then return w end
            end
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
        text_widgets = {}
        s:paintTo(bb, 0, 0)
        assert.are.equal("Time spent reading", heading())
        assert.are.equal("Back", s.later_button)
        assert.are.equal("Next", s.button)
        s:setPage(3)
        text_widgets = {}
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
        local images = {}
        ZenSpec.replace("ui/widget/imagewidget", { new = function(_self, values)
            images[#images + 1] = { w = values.width, h = values.height }
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
            { covers = { cover_b }, stat = "9" },
        }
        local s = screen(pages, { covers_owned = { bb_a, bb_b }, rounded_covers = true })
        s:paintTo(bb, 0, 0)
        assert.are.equal(1, #images)
        assert.is_true(images[1].h > images[1].w)
        s:setPage(2)
        images = {}
        s:paintTo(bb, 0, 0)
        assert.are.equal(4, #images)
        assert.is_true(images[1].w < 200)
        s:setPage(3)
        images = {}
        s:paintTo(bb, 0, 0)
        assert.are.equal(3, #images)
        assert.is_true(images[3].h > images[1].h)
        -- A slide with less text shows its cover at the same size.
        s:setPage(1)
        images = {}
        s:paintTo(bb, 0, 0)
        local single = images[1]
        s:setPage(4)
        images = {}
        s:paintTo(bb, 0, 0)
        assert.are.same(single, images[1])
        s:onClose()
        assert.are.equal(2, freed)
        assert.is_nil(s.covers_owned)
        assert.is_nil(pages[1].covers)
        assert.are.equal(1, closed)
    end)

    it("rounds cover corners only when asked to", function()
        local cover = { bb = {}, w = 200, h = 300 }
        local function flow() return { { covers = { cover, cover, cover }, layout = "flow", stat = "9h" } } end
        screen(flow()):paintTo(bb, 0, 0)
        assert.are.equal(0, corner_buffers)
        screen(flow(), { rounded_covers = true }):paintTo(bb, 0, 0)
        -- Three covers plus the outline around the centre one.
        assert.are.equal(4, corner_buffers)
    end)

    it("clears the screen with a full refresh when a slide with covers comes or goes", function()
        local s = screen({ { stat = "1" }, { stat = "2", covers = { { bb = {}, w = 200, h = 300 } } }, { stat = "3" }, { stat = "4" } })
        refreshes = {}
        s:setPage(2)
        s:setPage(3)
        s:setPage(4)
        assert.are.same({ "full", "full", "ui" }, refreshes)
    end)

    it("keeps one card and one visual band on every slide and the backdrop behind the icon clear", function()
        local cover = { bb = {}, w = 200, h = 300 }
        local s = screen({
            { title = "Reading Wrapped", icon = "/icons/zen_ui.svg", stat = "2026", description = "Swipe" },
            { title = "Top book", covers = { cover }, stat = "Dune", stat_label = "7h", description = string.rep("quip ", 40) },
            { title = "Bye", icon = "/icons/zen_ui.svg" },
        })
        s:paintTo(bb, 0, 0)
        -- Backdrop spans everything above the dots and buttons.
        local drop = backdrops[1]
        assert.are.same({ 1, 3, 0, 0, 600 }, { drop.index, drop.count, drop.x, drop.y, drop.w })
        assert.are.equal(800 - 80 - 36, drop.h)
        assert.are.equal(drop.clear.w, drop.clear.h)
        assert.are.equal(300, drop.clear.x + drop.clear.w / 2)
        local card, title = cards[1], painted("Reading Wrapped")
        assert.are.equal(560, card.w)
        assert.is_true(card.x < title.painted.x and card.y < title.painted.y)
        assert.is_true(card.y >= drop.clear.y + drop.clear.h)
        assert.is_true(card.y + card.h <= drop.h)
        -- The card is sized for the tallest slide: heading, stat, label and wrapped quip.
        assert.are.equal(36 + 48 + 22 + 40 + 3 * 10 + 2 * 18, card.h)
        s:setPage(2)
        s:paintTo(bb, 0, 0)
        -- Covers need no clear box.
        assert.is_nil(backdrops[2].clear)
        assert.are.same(card, cards[2])
        s:setPage(3)
        s:paintTo(bb, 0, 0)
        assert.are.same(card, cards[3])
        assert.are.same(drop.clear, backdrops[3].clear)
    end)

    it("draws every stat at one size and ends a long one in an ellipsis after two lines", function()
        local long = string.rep("A", 40)
        ZenSpec.replace("ui/widget/textboxwidget", { new = function(_self, values)
            box_widgets[#box_widgets + 1] = values
            values.getLineHeight = function() return 50 end
            return widget(values, values.width, values.height or 150)
        end })
        ZenSpec.unload("common/ui/wrapped_screen")
        WrappedScreen = require("common/ui/wrapped_screen")
        local s = screen({ { stat = long, stat_label = "x", description = string.rep("quip ", 40) }, { stat = "2026" }, { stat = "Dune" } })
        s:paintTo(bb, 0, 0)
        local stat, quip = painted(long), painted(string.rep("quip ", 40))
        assert.is_true(stat.bold)
        assert.are.equal(48, stat.face.size)
        assert.are.equal(100, stat.height)
        assert.is_true(stat.height_overflow_show_ellipsis)
        -- Only the stat is cut short.
        assert.is_nil(quip.height)
        for page, text in pairs({ [2] = "2026", [3] = "Dune" }) do
            s:setPage(page)
            s:paintTo(bb, 0, 0)
            assert.are.equal(48, painted(text).face.size)
        end
    end)
end)
