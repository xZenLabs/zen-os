describe("Quickstart menu coachmark", function()
    local MenuCoachmark
    local saved_modules
    local close_calls
    local dirty_hints
    local frame_paints

    local module_names = {
        "ffi/blitbuffer",
        "device",
        "ui/font",
        "ui/geometry",
        "ui/gesturerange",
        "ui/size",
        "ui/uimanager",
        "ui/widget/container/framecontainer",
        "ui/widget/container/inputcontainer",
        "ui/widget/textboxwidget",
        "common/ui/hatching",
        "common/quickstart/menu_coachmark",
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
        values.ges_events = {}
        values.key_events = {}
        setmetatable(values, { __index = self })
        values:init()
        return values
    end

    function InputContainer:onKeyPress(key)
        for name, sequences in pairs(self.key_events) do
            for _i, sequence in ipairs(sequences) do
                if key:match(sequence) then
                    return self["on" .. name](self)
                end
            end
        end
    end

    local function key(name)
        return {
            match = function(_self, sequence)
                local group = sequence[1]
                if type(group) ~= "table" then return group == name end
                for _i, member in ipairs(group) do
                    if member == name then return true end
                end
                return false
            end,
        }
    end

    local function intersects(a, b)
        return a.x < b.x + b.w and b.x < a.x + a.w
            and a.y < b.y + b.h and b.y < a.y + a.h
    end

    local function contains(outer, inner)
        return outer.x <= inner.x and outer.y <= inner.y
            and outer.x + outer.w >= inner.x + inner.w
            and outer.y + outer.h >= inner.y + inner.h
    end

    local function copy_dimen(dimen)
        return { x = dimen.x, y = dimen.y, w = dimen.w, h = dimen.h }
    end

    local function new_coachmark(on_complete, on_cancel)
        return MenuCoachmark:new{
            steps = {
                {
                    text = "Zen Mode",
                    target = { x = 250, y = 690, w = 64, h = 64 },
                },
                {
                    text = "Zen Settings",
                    target = { x = 460, y = 350, w = 64, h = 64 },
                },
            },
            on_complete = on_complete,
            on_cancel = on_cancel,
        }
    end

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(module_names) do
            saved_modules[name] = package.loaded[name] or false
        end

        close_calls = 0
        dirty_hints = {}
        frame_paints = {}

        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_WHITE = "white",
            COLOR_BLACK = "black",
        })
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
                scaleBySize = function(_self, value) return value end,
            },
            input = {
                group = {
                    Any = {
                        "A", "Up", "Down", "Left", "Right", "Press",
                        "Back", "Home", "LPgBack", "RPgBack", "LPgFwd", "RPgFwd",
                    },
                },
            },
            hasKeys = function() return true end,
        })
        ZenSpec.replace("ui/font", {
            getFace = function() return { name = "infofont" } end,
        })
        ZenSpec.replace("ui/geometry", {
            new = function(_self, values) return values end,
        })
        ZenSpec.replace("ui/gesturerange", {
            new = function(_self, values) return values end,
        })
        ZenSpec.replace("ui/size", {
            padding = { large = 12 },
            border = { window = 2 },
            radius = { window = 8 },
        })
        ZenSpec.replace("ui/widget/textboxwidget", {
            new = function(_self, values)
                values.getSize = function()
                    return { w = values.width, h = 100 }
                end
                values.free = function() end
                return values
            end,
        })
        ZenSpec.replace("ui/widget/container/framecontainer", {
            new = function(_self, values)
                local child_size = values[1]:getSize()
                local inset = (values.padding + values.bordersize) * 2
                values._size = { w = child_size.w + inset, h = child_size.h + inset }
                values.getSize = function(self) return self._size end
                values.paintTo = function(self, _bb, x, y)
                    frame_paints[#frame_paints + 1] = {
                        frame = self,
                        x = x,
                        y = y,
                    }
                end
                values.free = function(self)
                    self.free_calls = (self.free_calls or 0) + 1
                end
                return values
            end,
        })
        ZenSpec.replace("ui/uimanager", {
            close = function(_self, widget)
                close_calls = close_calls + 1
                widget:onCloseWidget()
            end,
            setDirty = function(_self, widget, hint)
                local mode, region = hint()
                dirty_hints[#dirty_hints + 1] = {
                    widget = widget,
                    mode = mode,
                    region = copy_dimen(region),
                }
            end,
        })
        ZenSpec.replace("ui/widget/container/inputcontainer", InputContainer)
        ZenSpec.unload("common/ui/hatching")
        ZenSpec.unload("common/quickstart/menu_coachmark")
        MenuCoachmark = require("common/quickstart/menu_coachmark")
    end)

    after_each(function()
        ZenSpec.unload("common/quickstart/menu_coachmark")
        for _i, name in ipairs(module_names) do
            package.loaded[name] = saved_modules[name] or nil
        end
    end)

    it("advances on the first full-screen tap and completes once on the second", function()
        local completions = 0
        local coachmark = new_coachmark(function() completions = completions + 1 end)

        assert.are.same(coachmark.dimen, coachmark.ges_events.TapAdvance[1].range)
        assert.is_true(coachmark:onTapAdvance())
        assert.are.equal(2, coachmark._step)
        assert.are.equal(0, close_calls)
        assert.are.equal(0, completions)

        assert.is_true(coachmark:onTapAdvance())
        assert.are.equal(1, close_calls)
        assert.are.equal(1, completions)

        coachmark:onCloseWidget()
        assert.are.equal(1, completions)
    end)

    it("advances on any hardware key, including page-turn keys", function()
        local keys = {
            "A", "Up", "Down", "Left", "Right", "Press",
            "Back", "Home", "LPgBack", "RPgBack", "LPgFwd", "RPgFwd",
        }
        for _i, name in ipairs(keys) do
            local coachmark = new_coachmark()
            assert.is_true(coachmark:onKeyPress(key(name)))
            assert.are.equal(2, coachmark._step)
        end
    end)

    it("anchors each callout close to its target while keeping it on-screen", function()
        local coachmark = new_coachmark()
        local first_callout = copy_dimen(coachmark._callout_dimen)
        local first_target = coachmark.steps[1].target
        local first_highlight = coachmark:_highlightDimen()

        assert.is_true(contains(coachmark.dimen, first_callout))
        assert.is_false(intersects(first_callout, first_target))
        assert.are.equal(first_highlight.y, first_callout.y + first_callout.h + 4)
        assert.are.equal(36, first_callout.x)

        coachmark:onTapAdvance()
        local second_callout = coachmark._callout_dimen
        local second_target = coachmark.steps[2].target
        local second_highlight = coachmark:_highlightDimen()

        assert.are_not.equal(first_callout.y, second_callout.y)
        assert.is_true(contains(coachmark.dimen, second_callout))
        assert.is_false(intersects(second_callout, second_target))
        assert.are.equal(second_highlight.y + second_highlight.h + 4, second_callout.y)
        assert.are.equal(85, second_callout.x)
    end)

    it("cancels once on resize without marking the tour complete", function()
        local completions = 0
        local cancellations = 0
        local coachmark = new_coachmark(
            function() completions = completions + 1 end,
            function() cancellations = cancellations + 1 end)

        assert.is_true(coachmark:onSetDimensions())
        assert.are.equal(1, close_calls)
        assert.are.equal(0, completions)
        assert.are.equal(1, cancellations)

        assert.is_true(coachmark:onScreenResize())
        assert.are.equal(1, close_calls)
        assert.are.equal(1, cancellations)
    end)

    it("dims around the target and paints a bold square highlight without a pointer", function()
        local coachmark = new_coachmark()
        coachmark:onTapAdvance()

        local paint_rects = {}
        local hatch_rects = {}
        local paint_borders = {}
        local bb = {
            paintRect = function(_self, x, y, w, h, color)
                paint_rects[#paint_rects + 1] = {
                    x = x, y = y, w = w, h = h, color = color,
                }
            end,
            hatchRect = function(_self, x, y, w, h, stripe_width, color, alpha)
                hatch_rects[#hatch_rects + 1] = {
                    x = x, y = y, w = w, h = h,
                    stripe_width = stripe_width, color = color, alpha = alpha,
                }
            end,
            paintBorder = function(_self, x, y, w, h, width, color, radius)
                paint_borders[#paint_borders + 1] = {
                    x = x, y = y, w = w, h = h,
                    width = width, color = color, radius = radius,
                }
            end,
        }

        coachmark:paintTo(bb)

        assert.are.equal(0, #paint_rects)
        assert.are.equal(4, #hatch_rects)
        local highlight = coachmark:_highlightDimen()
        assert.are.same({ x = 446, y = 336, w = 92, h = 92 }, highlight)
        assert.are.same({ x = 0, y = 0, w = 600, h = 336 }, {
            x = hatch_rects[1].x, y = hatch_rects[1].y,
            w = hatch_rects[1].w, h = hatch_rects[1].h,
        })
        assert.are.same({ x = 0, y = 428, w = 600, h = 372 }, {
            x = hatch_rects[2].x, y = hatch_rects[2].y,
            w = hatch_rects[2].w, h = hatch_rects[2].h,
        })
        assert.are.same({ x = 0, y = 336, w = 446, h = 92 }, {
            x = hatch_rects[3].x, y = hatch_rects[3].y,
            w = hatch_rects[3].w, h = hatch_rects[3].h,
        })
        assert.are.same({ x = 538, y = 336, w = 62, h = 92 }, {
            x = hatch_rects[4].x, y = hatch_rects[4].y,
            w = hatch_rects[4].w, h = hatch_rects[4].h,
        })
        for _i, rect in ipairs(hatch_rects) do
            assert.is_false(intersects(rect, highlight))
            assert.are.equal(2, rect.stripe_width)
            assert.are.equal("black", rect.color)
            assert.are.equal(0.4, rect.alpha)
        end
        assert.are.equal(2, #paint_borders)
        assert.are.equal("white", paint_borders[1].color)
        assert.are.equal("black", paint_borders[2].color)
        assert.are.equal(4, paint_borders[1].width)
        assert.are.equal(6, paint_borders[2].width)
        assert.is_nil(paint_borders[1].radius)
        assert.is_nil(paint_borders[2].radius)
        assert.are.equal(1, #frame_paints)
        assert.are.equal(coachmark._callout_dimen.x, frame_paints[1].x)
        assert.are.equal(coachmark._callout_dimen.y, frame_paints[1].y)

        local visible_area = copy_dimen(coachmark:getVisibleArea())
        assert.are.same(coachmark.dimen, visible_area)

        coachmark:onTapAdvance()

        local close_dirty = dirty_hints[#dirty_hints]
        assert.is_nil(close_dirty.widget)
        assert.are.equal("ui", close_dirty.mode)
        assert.are.same(visible_area, close_dirty.region)
    end)
end)
