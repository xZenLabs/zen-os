local Blitbuffer = require("ffi/blitbuffer")
local Viewport = require("modules/reader/highlight_viewport")

describe("highlight viewport", function()
    it("preserves page margins and footer over temporary scroll selections", function()
        local buffer = Blitbuffer.new(60, 80, Blitbuffer.TYPE_BBRGB32)
        local screen = Blitbuffer.new(60, 80, Blitbuffer.TYPE_BBRGB32)
        local color = Blitbuffer.ColorRGB32(243, 234, 210)
        buffer:paintRectRGB32(0, 0, 60, 80, color)
        screen:fill(Blitbuffer.COLOR_BLACK)
        local doc = {
            buffer = buffer,
            getPageMargins = function() return { left = 0, right = 0, top = 12, bottom = 15 } end,
            getHeaderHeight = function() return 3 end,
            getCurrentPos = function() return 0 end,
            getTextFromPositions = function() end,
        }
        local highlight = { ui = { document = doc, rolling = {} }, screen_h = 80,
            screen_w = 60,
            restore_page_mode_func = function() end }
        local view = { document = doc, dimen = { w = 60, h = 80 }, ui = { highlight = highlight },
            view_mode = "scroll", footer_visible = true,
            footer = { paintTo = function(_self, bb)
                bb:paintRect(0, 75, 60, 5, Blitbuffer.COLOR_BLACK)
            end } }
        highlight.view = view

        Viewport.paintMargins(view, screen, 0, 0)
        local pixel = screen:getPixel(20, 14)
        assert.same({243, 234, 210}, {pixel:getR(), pixel:getG(), pixel:getB()})
        assert.are.equal(0, screen:getPixel(20, 15):getR())
        assert.are.equal(0, screen:getPixel(20, 64):getR())
        assert.are.equal(243, screen:getPixel(20, 65):getR())
        assert.are.equal(0, screen:getPixel(20, 75):getR())

        highlight.restore_page_mode_func = nil
        screen:fill(Blitbuffer.COLOR_BLACK)
        Viewport.paintMargins(view, screen, 0, 0)
        assert.are.equal(0, screen:getPixel(20, 14):getR())
        screen:free()
        buffer:free()
    end)

    it("excludes partial lines without changing text coordinates or selection", function()
        local restored, queries = nil, 0
        local highlight = { screen_w = 600, screen_h = 800, restore_page_mode_func = function() end,
            selected_text = { pos0 = "start", pos1 = "end" },
            ui = { rolling = {}, document = {
                getPageMargins = function() return { left = 20, right = 20, top = 100, bottom = 100 } end,
                getHeaderHeight = function() return 0 end,
                getCurrentPos = function() return 500 end,
                getTextFromPositions = function(_self, pos0, pos1, no_selection)
                    assert.is_true(no_selection)
                    assert.are.equal(pos0.y, pos1.y)
                    queries = queries + 1
                    return { sboxes = {{ x = 20, y = pos0.y - 10, w = 560, h = 30 }} }
                end,
                getTextFromXPointers = function(_self, pos0, pos1, draw)
                    restored = { pos0, pos1, draw }
                end,
            } } }
        highlight.view = { ui = { highlight = highlight }, view_mode = "scroll" }
        local top, bottom = Viewport.bounds(highlight)
        assert.are.equal(120, top)
        assert.are.equal(690, bottom)
        assert.same({ "start", "end", true }, restored)
        Viewport.bounds(highlight)
        assert.are.equal(2, queries)
        highlight.view.view_mode = "page"
        top, bottom = Viewport.bounds(highlight)
        assert.are.equal(100, top)
        assert.are.equal(700, bottom)
        highlight.view.view_mode = "scroll"
        highlight.restore_page_mode_func = nil
        top, bottom = Viewport.bounds(highlight)
        assert.are.equal(0, top)
        assert.are.equal(800, bottom)
    end)
end)
