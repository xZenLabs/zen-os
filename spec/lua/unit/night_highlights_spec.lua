describe("night mode highlights", function()
    local Blitbuffer = require("ffi/blitbuffer")
    local modules = { "apps/reader/modules/readerview", "apps/reader/modules/readerhighlight", "device",
        "ui/widget/buttonselector" }
    local saved, screen, calls, props, ReaderView
    local yellow = Blitbuffer.ColorRGB32(0xff, 0xff, 0x00, 0xff)
    local cyan = Blitbuffer.ColorRGB32(0x00, 0xff, 0xff, 0xff)

    local function rgb(bb, x, y)
        local c = bb:getPixel(x, y):getColorRGB32()
        return { c.r, c.g, c.b }
    end

    local function setup()
        screen = { night_mode = true }
        calls, props = {}, {}
        ReaderView = {
            -- Mirrors stock: temp boxes are drawn with the selection color after the page.
            paintTo = function(self, bb)
                for _k, boxes in pairs(self.highlight.temp) do
                    for _i, box in ipairs(boxes) do self:drawHighlightRect(bb, 0, 0, box, "lighten", yellow) end
                end
            end,
            drawSavedHighlight = function(self, bb, rect, color)
                self:drawHighlightRect(bb, 0, 0, rect, "lighten", color)
            end,
            drawHighlightRect = function(_self, bb, _x, _y, rect, drawer, color, mark)
                calls[#calls + 1] = { drawer = drawer, color = color, mark = mark, inverse = bb:getInverse() }
                if drawer == "lighten" then bb:multiplyRectRGB(rect.x, rect.y, rect.w, rect.h, color) end
            end,
        }
        local ReaderHighlight = {
            -- Mirrors stock: the selection color is pre-inverted at night.
            setSelectionColor = function(self)
                self.document._document:setStringProperty("crengine.highlight.selection.color",
                    screen.night_mode and "#0000FF" or "#FFFF00")
            end,
        }
        ZenSpec.replace("apps/reader/modules/readerview", ReaderView)
        ZenSpec.replace("apps/reader/modules/readerhighlight", ReaderHighlight)
        ZenSpec.replace("device", { screen = screen })
        ZenSpec.replace("ui/widget/buttonselector", {
            init = function(self)
                self.by_id = {}
                for i, value in ipairs(self.values) do
                    self.by_id[value[2]] = { { background = value[3] or self.bg_colors and self.bg_colors[i] },
                        label_widget = { fgcolor = Blitbuffer.COLOR_BLACK } }
                end
            end,
            getButtonById = function(self, id) return self.by_id[id] end,
        })
        require("modules/reader/patches/night_highlights")()
        local hl = setmetatable({ ui = {}, document = { _document = {
            setStringProperty = function(_self, key, value) props[key] = value end,
        } } }, { __index = ReaderHighlight })
        return setmetatable({ highlight = { temp = {} }, ui = { rolling = true, highlight = hl } },
            { __index = ReaderView })
    end

    -- White page with one black "glyph" pixel at (1, 1).
    local function page(software)
        local bb = Blitbuffer.new(8, 4, Blitbuffer.TYPE_BBRGB32)
        bb:fill(software and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE)
        bb:setPixel(1, 1, software and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK)
        if software then bb:setInverse(1) end
        return bb
    end

    before_each(function()
        saved = {}
        for _i, name in ipairs(modules) do saved[name] = package.loaded[name] end
        ZenSpec.unload("modules/reader/patches/night_highlights")
    end)

    after_each(function()
        for _i, name in ipairs(modules) do package.loaded[name] = saved[name] end
        ZenSpec.unload("modules/reader/patches/night_highlights")
    end)

    it("leaves day mode and other drawers to stock", function()
        local view = setup()
        local bb = page()
        screen.night_mode = false
        view:drawHighlightRect(bb, 0, 0, { x = 0, y = 0, w = 4, h = 4 }, "lighten", yellow)
        screen.night_mode = true
        view:drawHighlightRect(bb, 0, 0, { x = 4, y = 0, w = 4, h = 4 }, "underscore", yellow, true)
        assert.are.same({ 0xff, 0xff, 0x00 }, rgb(bb, 0, 0))
        assert.are.same({ 0xff, 0xff, 0xff }, rgb(bb, 5, 0))
        assert.are.equal(true, calls[2].mark)
        bb:free()
    end)

    it("pre-inverts day pixels for hardware night mode, inverting overlaps once", function()
        local view = setup()
        local bb = page()
        view:paintTo(bb)
        view:drawHighlightRect(bb, 0, 0, { x = 0, y = 0, w = 4, h = 4 }, "lighten", yellow)
        view:drawHighlightRect(bb, 0, 0, { x = 2, y = 0, w = 4, h = 4 }, "lighten", cyan)
        -- Display inverts: stored values are the inverse of day colors.
        assert.are.same({ 0x00, 0x00, 0xff }, rgb(bb, 0, 0))
        assert.are.same({ 0xff, 0xff, 0xff }, rgb(bb, 1, 1))
        assert.are.same({ 0xff, 0x00, 0xff }, rgb(bb, 2, 0))
        assert.are.same({ 0xff, 0x00, 0x00 }, rgb(bb, 5, 0))
        assert.are.same({ 0xff, 0xff, 0xff }, rgb(bb, 7, 0))
        bb:free()
    end)

    it("draws day pixels directly in software night mode", function()
        local view = setup()
        local bb = page(true)
        view:paintTo(bb)
        view:drawHighlightRect(bb, 0, 0, { x = 0, y = 0, w = 4, h = 4 }, "lighten", yellow)
        view:drawHighlightRect(bb, 0, 0, { x = 2, y = 0, w = 4, h = 4 }, "lighten", cyan)
        assert.are.equal(0, calls[1].inverse)
        assert.are.equal(1, bb:getInverse())
        bb:setInverse(0)
        assert.are.same({ 0xff, 0xff, 0x00 }, rgb(bb, 0, 0))
        assert.are.same({ 0x00, 0x00, 0x00 }, rgb(bb, 1, 1))
        assert.are.same({ 0x00, 0xff, 0x00 }, rgb(bb, 2, 0))
        assert.are.same({ 0x00, 0x00, 0x00 }, rgb(bb, 7, 0))
        bb:free()
    end)

    it("draws saved day colors as given and keeps side marks stock", function()
        local view = setup()
        view.highlight.note_mark = "sideline"
        local bb = page()
        view:drawSavedHighlight(bb, { x = 0, y = 0, w = 4, h = 4 }, yellow)
        assert.are.same({ 0x00, 0x00, 0xff }, rgb(bb, 0, 0))
        view:drawHighlightRect(bb, 0, 0, { x = 4, y = 0, w = 4, h = 4 }, "lighten", cyan, true)
        assert.are.equal(cyan, calls[2].color)
        assert.is_nil(calls[2].mark)
        assert.is_nil(calls[3].drawer)
        assert.are.equal(cyan, calls[3].color)
        assert.are.equal(true, calls[3].mark)
        bb:free()
    end)

    it("blanks the CRe selection at night and draws it as a highlight", function()
        local view = setup()
        local hl, temp = view.ui.highlight, view.highlight.temp
        hl.selected_text = { sboxes = { { x = 0, y = 0, w = 4, h = 4 } } }
        local bb = page()
        view:paintTo(bb)
        assert.are.equal("#FFFFFF", props["crengine.highlight.selection.color"])
        assert.are.same({ 0x00, 0x00, 0xff }, rgb(bb, 0, 0))
        assert.are.same({ 0xff, 0xff, 0xff }, rgb(bb, 1, 1))
        assert.are.equal(temp, view.highlight.temp)

        -- An unsaved handles draft wins over the stale selection.
        hl._zen_highlight_handles = { draft = { sboxes = { { x = 4, y = 0, w = 4, h = 4 } } } }
        view:paintTo(bb)
        assert.are.same({ 0x00, 0x00, 0xff }, rgb(bb, 5, 0))

        screen.night_mode = false
        local count = #calls
        view:paintTo(bb)
        assert.are.equal("#FFFF00", props["crengine.highlight.selection.color"])
        assert.are.equal(count, #calls)
        bb:free()
    end)

    it("flips swatch labels and grays in night mode only", function()
        setup()
        local ButtonSelector = require("ui/widget/buttonselector")
        local gray = Blitbuffer.Color8(0xcc)
        local selector = setmetatable({ values = { { "Yellow", "yellow", yellow }, { "Gray", "gray", gray },
            { "None", "none" } } }, { __index = ButtonSelector })
        selector:init()
        local swatch, plain = selector:getButtonById("yellow"), selector:getButtonById("none")
        assert.are.equal(Blitbuffer.COLOR_WHITE, swatch.label_widget.fgcolor)
        assert.are.equal(yellow, swatch[1].background)
        assert.are.equal(0x33, selector:getButtonById("gray")[1].background.a)
        assert.are.equal(Blitbuffer.COLOR_BLACK, plain.label_widget.fgcolor)

        screen.night_mode = false
        local legacy = setmetatable({ values = { { "Yellow", "yellow" } }, bg_colors = { yellow } },
            { __index = ButtonSelector })
        legacy:init()
        assert.are.equal(Blitbuffer.COLOR_BLACK, legacy:getButtonById("yellow").label_widget.fgcolor)
        screen.night_mode = true
        legacy:init()
        assert.are.equal(Blitbuffer.COLOR_WHITE, legacy:getButtonById("yellow").label_widget.fgcolor)
    end)

    it("defers to stock night inversion when KOReader's invert color setting is on", function()
        local key, use_key = "highlight_selection_invert_highlight_color", "highlight_selection_use_highlight_color"
        local prev, prev_use = G_reader_settings:readSetting(key), G_reader_settings:readSetting(use_key)
        G_reader_settings:saveSetting(key, true)
        G_reader_settings:saveSetting(use_key, true)
        local ok, err = pcall(function()
            local view = setup()
            local hl = view.ui.highlight
            hl.selected_text = { sboxes = { { x = 0, y = 0, w = 4, h = 4 } } }
            local bb = page()
            -- Selection is still drawn as a temp highlight, now through stock inversion.
            view:paintTo(bb)
            assert.are.equal("#FFFFFF", props["crengine.highlight.selection.color"])
            assert.are.equal(0, calls[#calls].inverse)
            assert.are.same({ 0xff, 0xff, 0x00 }, rgb(bb, 0, 0))
            view:drawHighlightRect(bb, 0, 0, { x = 0, y = 0, w = 4, h = 4 }, "lighten", yellow)
            assert.are.same({ 0xff, 0xff, 0x00 }, rgb(bb, 0, 0))

            -- Color modal: pre-inverted swatches flip back so they invert with the page; labels stay stock.
            local ButtonSelector = require("ui/widget/buttonselector")
            local gray = Blitbuffer.Color8(0xcc)
            local selector = setmetatable({ values = { { "Yellow", "yellow", yellow }, { "Gray", "gray", gray } } },
                { __index = ButtonSelector })
            selector:init()
            local swatch = selector:getButtonById("yellow")
            assert.are.same({ 0x00, 0x00, 0xff },
                { swatch[1].background.r, swatch[1].background.g, swatch[1].background.b })
            assert.are.equal(Blitbuffer.COLOR_BLACK, swatch.label_widget.fgcolor)
            assert.are.equal(gray, selector:getButtonById("gray")[1].background)

            -- Live toggle back to day colors.
            G_reader_settings:saveSetting(key, false)
            local count = #calls
            view:paintTo(bb)
            assert.are.equal(count + 1, #calls)
            bb:free()
        end)
        G_reader_settings:saveSetting(key, prev)
        G_reader_settings:saveSetting(use_key, prev_use)
        if not ok then error(err, 0) end
    end)
end)
