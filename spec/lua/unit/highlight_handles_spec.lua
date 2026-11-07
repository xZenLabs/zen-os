describe("highlight handles", function()
    local Handles, highlight, dialog, tasks, writes, events, dirty, reopened, originals
    local function loadFixture(saved)
        local doc = {
            compareXPointers = function(_self, a, b) return a < b and 1 or a == b and 0 or -1 end,
            getTextFromXPointers = function(_self, a, b) return a .. " to " .. b end,
            getScreenBoxesFromPositions = function(_self, a, b)
                return { { x = a:byte(), y = 100, w = b:byte() - a:byte() + 10, h = 20 } }
            end,
            getScreenPositionFromXPointer = function(_self, xp) return 100, xp:byte() end,
            isXPointerInCurrentPage = function() return true end,
            getWordFromPosition = function(_self, pos)
                local letter = string.char(math.max(97, math.min(122, math.floor(pos.x))))
                return { pos0 = letter, pos1 = string.char(letter:byte() + 1) }
            end,
            getTextFromPositions = function() end,
            getCurrentPage = function() return 2 end,
            getPageCount = function() return 10 end,
            getPageFromXPointer = function() return 2 end,
            getPrevVisibleWordStart = function(_self, xp) return string.char(xp:byte() - 1) end,
            getNextVisibleWordEnd = function(_self, xp) return string.char(xp:byte() + 1) end,
            getEPubCFIRangeFromXPointers = function() return "cfi" end,
        }
        local item = { pos0 = "c", pos1 = "m", text = "original", drawer = "lighten", color = "red",
            note = "Keep this note", datetime = "original date" }
        highlight = {
            ui = { document = doc, rolling = { onGotoViewRel = function() end },
                annotation = { annotations = { item }, getPageRef = function() return "2" end },
                toc = { getTocTitleByPage = function() return "chapter" end },
                handleEvent = function(_self, event) events[#events + 1] = event end },
            screen_w = 600, screen_h = 800, dialog = {}, selected_text = item, hold_pos = {},
            view = { view_mode = "page", resetHighlightBoxesCache = function() end,
                screenToPageTransform = function(_self, pos) return pos end,
                drawSavedHighlight = function() return "painted" end },
            writePdfAnnotation = function(_self, action) writes[#writes + 1] = action end,
            onHoldPan = function(state)
                state.ui.rolling.corner_calls = (state.ui.rolling.corner_calls or 0) + 1
                state.was_in_some_corner = true
                if not state.restore_page_mode_func then
                    local restore = function() state.view.view_mode = "page" end
                    state.restore_page_mode_func = restore
                    assert.are.equal(restore, highlight.restore_page_mode_func)
                    state.view.view_mode = "scroll"
                end
            end,
        }
        dialog = { buttons = {{ {} }}, paintTo = function() end, handleEvent = function() return false end }
        return Handles.attach(highlight, dialog, saved and 1 or nil, function() reopened = reopened + 1 end)
    end

    before_each(function()
        originals = {}
        for _i, name in ipairs({ "device", "ui/bidi", "ui/uimanager", "common/ui/accent", "common/reader_themes",
            "modules/reader/highlight_handles", "util" }) do
            originals[name] = package.loaded[name] or false
        end
        tasks, writes, events, dirty, reopened = {}, {}, {}, {}, 0
        local function copy(value)
            if type(value) ~= "table" then return value end
            local result = {}
            for key, entry in pairs(value) do result[key] = copy(entry) end
            return result
        end
        ZenSpec.replace("util", { tableDeepCopy = copy, cleanupSelectedText = function(text) return text end })
        ZenSpec.replace("ui/bidi", { mirroredUILayout = function() return false end })
        ZenSpec.replace("device", { isTouchDevice = function() return true end, screen = {
            scaleBySize = function(_self, n) return n end, isColorEnabled = function() return false end } })
        ZenSpec.replace("common/ui/accent", { color = function() return require("ffi/blitbuffer").COLOR_BLACK end })
        ZenSpec.replace("ui/uimanager", {
            setDirty = function(_self, _widget, mode, region) dirty[#dirty + 1] = { mode = mode, region = region } end,
            scheduleIn = function(_self, delay, callback) tasks[callback] = delay end,
            unschedule = function(_self, callback) tasks[callback] = nil end,
            close = function(_self, widget) if widget.onCloseWidget then widget:onCloseWidget() end end,
        })
        ZenSpec.unload("modules/reader/highlight_handles")
        Handles = require("modules/reader/highlight_handles")
    end)

    after_each(function()
        for name, module in pairs(originals) do package.loaded[name] = module or nil end
    end)

    it("puts the start knob above and end knob below with larger touch targets", function()
        local controller = loadFixture()
        local geometry = controller:geometry()
        assert.are.equal(95, geometry[0].y)
        assert.are.equal(125, geometry[1].y)
        for _i, offset in ipairs({ { x = -55, y = 0 }, { x = 0, y = -55 }, { x = -40, y = -40 } }) do
            assert.are.equal(0, controller:hitTest({ x = geometry[0].x + offset.x, y = geometry[0].y + offset.y }))
            assert.are.equal(1, controller:hitTest({ x = geometry[1].x - offset.x, y = geometry[1].y - offset.y }))
        end
        assert.is_nil(controller:hitTest({ x = geometry[0].x - 65, y = geometry[0].y }))
        assert.is_nil(controller:hitTest({ x = 400, y = 400 }))
    end)

    it("paints handle stems and knobs in the reader text color with a black fallback", function()
        local controller = loadFixture()
        local Blitbuffer = require("ffi/blitbuffer")
        for _i, color in ipairs({ false, Blitbuffer.ColorRGB32(0x3f, 0x35, 0x24, 0xff) }) do
            ZenSpec.replace("common/reader_themes", { getTextColor = function(plugin)
                assert.are.equal(rawget(_G, "__ZEN_UI_PLUGIN"), plugin)
                return color or nil
            end })
            local colors = {}
            local function paint(_bb, _x, _y, _w, _h, value) colors[#colors + 1] = value end
            controller:paintTo(color and { paintRectRGB32 = paint, paintRoundedRectRGB32 = paint }
                or { paintRect = paint, paintRoundedRect = paint })
            assert.are.equal(4, #colors)
            for _j, actual in ipairs(colors) do assert.are.equal(color or Blitbuffer.COLOR_BLACK, actual) end
        end
    end)

    it("keeps menu buttons tappable where the enlarged targets overlap", function()
        local controller = loadFixture()
        dialog.movable = { dimen = require("ui/geometry"):new{ x = 50, y = 30, w = 200, h = 40 } }
        assert.is_nil(controller:hitTest({ x = 99, y = 55 }))
        assert.is_false(dialog:handleEvent(require("ui/event"):new("Gesture", {
            ges = "tap", pos = { x = 99, y = 55 },
        })))
        dialog.buttons = {}
        assert.are.equal(0, controller:hitTest({ x = 99, y = 55 }))
    end)

    it("refreshes the reader tap grace period when the handle menu closes", function()
        local controller = loadFixture()
        local time = require("ui/time")
        local before = time.now()
        controller:close()
        assert.is_true(highlight._zen_highlight_tap_until >= before + time.ms(600))
        assert.same({}, tasks)
    end)

    it("keeps handles and drag positions inside the reading margins", function()
        local controller = loadFixture()
        local doc = highlight.ui.document
        doc.getPageMargins = function() return { top = 95, bottom = 665 } end
        doc.getHeaderHeight = function() return 0 end
        local geometry = controller:geometry()
        assert.are.equal(100, geometry[0].y)
        assert.are.equal(125, geometry[1].y)
        local position
        doc.getWordFromPosition = function(_self, pos) position = pos end
        controller:begin(1, { x = 119, y = 125 })
        controller:move({ x = 120, y = 790 })
        assert.are.equal(134, position.y)
        controller:move({ x = 120, y = 0 })
        assert.are.equal(95, position.y)
    end)

    it("previews saved boundaries without writes and commits once preserving note and style", function()
        local controller = loadFixture(true)
        controller:begin(1, { x = 119, y = 125 })
        controller:move({ x = 120, y = 125 })
        assert.are.equal("m", highlight.ui.annotation.annotations[1].pos1)
        assert.are.equal("y", controller.draft.pos1)
        assert.same({}, writes)
        assert.are.equal("fast", dirty[#dirty].mode)
        local rendered
        controller.original_draw = function()
            rendered = highlight.ui.annotation.annotations[1].pos1
        end
        highlight.view:drawSavedHighlight()
        assert.are.equal("y", rendered)
        assert.are.equal("m", highlight.ui.annotation.annotations[1].pos1)
        controller:finish()
        local item = highlight.ui.annotation.annotations[1]
        assert.are.equal("y", item.pos1)
        assert.are.equal("Keep this note", item.note)
        assert.are.equal("original date", item.datetime)
        assert.are.equal("red", item.color)
        assert.same({ "delete", "save" }, writes)
        assert.are.equal(1, #events)
        assert.are.equal(1, reopened)
    end)

    it("keeps new selections unsaved and updates boxes for the reopened menu", function()
        local controller = loadFixture()
        controller:begin(0, { x = 99, y = 95 })
        controller:move({ x = 97, y = 95 })
        controller:finish()
        assert.are.equal("a", highlight.selected_text.pos0)
        assert.is_not_nil(highlight.selected_text.sboxes)
        assert.is_true(highlight.selected_text._zen_resized)
        assert.same({}, writes)
        assert.same({}, events)
    end)

    it("clamps at one word when a handle crosses the opposite endpoint", function()
        local controller = loadFixture(true)
        controller:begin(0, { x = 99, y = 95 })
        controller:move({ x = 122, y = 95 })
        assert.are.equal("l", controller.draft.pos0)
        controller:finish()
        assert.are.equal("l", highlight.ui.annotation.annotations[1].pos0)
    end)

    it("does not write unchanged drags", function()
        local controller = loadFixture(true)
        controller:begin(0, { x = 99, y = 95 })
        controller:finish()
        assert.same({}, writes)
        assert.same({}, events)
    end)

    it("restores PDF reflow mode even when text extraction fails", function()
        local controller = loadFixture()
        local doc = highlight.ui.document
        doc.configurable = { text_wrap = 1 }
        doc.getTextFromPositions = function()
            assert.are.equal(0, doc.configurable.text_wrap)
            error("extraction failed")
        end
        assert.has_error(function() controller:pdfSelection({ page = 1 }, { page = 1 }) end)
        assert.are.equal(1, doc.configurable.text_wrap)
    end)

    it("does not offer handles for highlights whose text was edited", function()
        local controller = loadFixture(true)
        controller:close()
        highlight.ui.annotation.annotations[1].text_edited = true
        assert.is_false(Handles.available(highlight, 1))
        assert.is_nil(Handles.attach(highlight, dialog, 1, function() end))
    end)

    it("stops PDF corner navigation at book boundaries", function()
        local controller = loadFixture(true)
        controller:begin(1, { x = 119, y = 125 })
        highlight.ui.rolling = nil
        highlight.ui.paging = { current_page = 10, onGotoViewRel = function() error("must not turn beyond the book") end }
        assert.is_true(controller:corner({ x = 590, y = 795 }))
        assert.same({}, tasks)
    end)

    it("delegates to native corner scrolling once per entry without timers", function()
        local controller = loadFixture(true)
        controller:begin(1, { x = 119, y = 125 })
        assert.is_false(controller:corner({ x = 300, y = 795 }))
        assert.is_true(controller:corner({ x = 590, y = 795 }))
        assert.are.equal(1, highlight.ui.rolling.corner_calls)
        assert.are.equal("scroll", highlight.view.view_mode)
        assert.are.equal("c", controller.corner_state.selected_text_start_xpointer)
        assert.is_true(controller:corner({ x = 590, y = 795 }))
        assert.are.equal(1, highlight.ui.rolling.corner_calls)
        assert.is_false(controller:corner({ x = 300, y = 400 }))
        assert.is_true(controller:corner({ x = 590, y = 795 }))
        assert.are.equal(2, highlight.ui.rolling.corner_calls)
        assert.same({}, tasks)
        controller:close()
        assert.are.equal("page", highlight.view.view_mode)
        assert.is_nil(highlight.restore_page_mode_func)
        assert.is_nil(highlight._zen_highlight_handles)
    end)

    it("requires leaving a corner before scrolling a selection started there", function()
        local controller = loadFixture()
        controller:begin(0, { x = 10, y = 10 })
        assert.is_false(controller:corner({ x = 10, y = 10 }))
        assert.is_nil(highlight.ui.rolling.corner_calls)
        controller:corner({ x = 300, y = 400 })
        assert.is_true(controller:corner({ x = 10, y = 10 }))
        assert.are.equal("m", controller.corner_state.selected_text_start_xpointer)
    end)

    it("honors mirrored reading order and the native corner-scroll setting", function()
        local controller = loadFixture()
        controller:begin(1, { x = 119, y = 125 })
        package.loaded["ui/bidi"].mirroredUILayout = function() return true end
        assert.is_false(controller:corner({ x = 590, y = 795 }))
        assert.is_true(controller:corner({ x = 10, y = 795 }))
        assert.are.equal(1, highlight.ui.rolling.corner_calls)
        highlight.allow_corner_scroll = false
        assert.is_false(controller:corner({ x = 590, y = 10 }))
        assert.are.equal(1, highlight.ui.rolling.corner_calls)
    end)

    it("keeps native scroll mode until a new selection is saved or dismissed", function()
        local controller = loadFixture()
        controller:begin(1, { x = 119, y = 125 })
        controller:corner({ x = 590, y = 795 })
        controller:finish()
        assert.are.equal("scroll", highlight.view.view_mode)
        assert.is_not_nil(highlight.restore_page_mode_func)
        local next_controller = Handles.attach(highlight, dialog, nil, function() end)
        next_controller:close()
        assert.are.equal("page", highlight.view.view_mode)
        assert.is_nil(highlight.restore_page_mode_func)
    end)

    it("consumes a handle drag but lets unrelated gestures reach the menu", function()
        loadFixture()
        local Event = require("ui/event")
        assert.is_false(dialog:handleEvent(Event:new("Gesture", { ges = "pan", pos = { x = 400, y = 400 } })))
        assert.is_true(dialog:handleEvent(Event:new("Gesture", { ges = "touch", pos = { x = 99, y = 95 } })))
        assert.is_true(dialog:handleEvent(Event:new("Gesture", { ges = "pan", pos = { x = 97, y = 95 } })))
        assert.is_true(dialog:handleEvent(Event:new("Gesture", { ges = "pan_release", pos = { x = 97, y = 95 } })))
        assert.are.equal(1, reopened)
    end)

    it("dismisses an empty submenu on taps away from the handles", function()
        loadFixture(true)
        local dismissed = false
        dialog.buttons = {}
        dialog.onClose = function() dismissed = true; return true end
        assert.is_true(dialog:handleEvent(require("ui/event"):new("Gesture", {
            ges = "tap", pos = { x = 400, y = 400 },
        })))
        assert.is_true(dismissed)
    end)

    it("handles a fast swipe from a knob without an earlier pan event", function()
        loadFixture()
        assert.is_true(dialog:handleEvent(require("ui/event"):new("Gesture", {
            ges = "swipe", pos = { x = 99, y = 95 }, end_pos = { x = 97, y = 95 },
        })))
        assert.are.equal("a", highlight.selected_text.pos0)
        assert.are.equal(1, reopened)
    end)
end)
