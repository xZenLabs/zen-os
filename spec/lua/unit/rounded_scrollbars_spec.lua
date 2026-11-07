describe("rounded KOReader scrollbars", function()
    local saved_modules
    local VerticalScrollBar, HorizontalScrollBar
    local mirrored, borders, fills, bb
    local module_names = {
        "device", "ui/bidi", "ui/geometry", "ui/gesturerange", "ui/size",
        "ui/widget/container/inputcontainer", "ui/widget/verticalscrollbar",
        "ui/widget/horizontalscrollbar", "modules/global/patches/rounded_scrollbars",
    }

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(module_names) do
            saved_modules[name] = package.loaded[name] or false
        end
        mirrored, borders, fills = false, {}, {}
        ZenSpec.replace("device", { isTouchDevice = function() return false end })
        ZenSpec.replace("ui/bidi", { mirroredUILayout = function() return mirrored end })
        ZenSpec.replace("ui/geometry", { new = function(_self, values) return values end })
        ZenSpec.replace("ui/gesturerange", {})
        ZenSpec.replace("ui/size", {
            padding = { default = 8 }, item = { height_large = 100 },
            border = { thin = 1 }, line = { thick = 4 },
        })
        ZenSpec.replace("ui/widget/container/inputcontainer", require("ui/widget/widget"))
        VerticalScrollBar = assert(loadfile("frontend/ui/widget/verticalscrollbar.lua"))()
        HorizontalScrollBar = assert(loadfile("frontend/ui/widget/horizontalscrollbar.lua"))()
        ZenSpec.replace("ui/widget/verticalscrollbar", VerticalScrollBar)
        ZenSpec.replace("ui/widget/horizontalscrollbar", HorizontalScrollBar)
        ZenSpec.unload("modules/global/patches/rounded_scrollbars")
        require("modules/global/patches/rounded_scrollbars")()
        bb = {
            paintBorder = function(_self, ...) borders[#borders + 1] = { ... } end,
            paintRoundedRect = function(_self, ...) fills[#fills + 1] = { ... } end,
        }
    end)

    after_each(function()
        for _i, name in ipairs(module_names) do
            package.loaded[name] = saved_modules[name] or nil
        end
    end)

    it("rounds vertical tracks and thumbs while preserving touch bounds and colors", function()
        local selected
        local bar = VerticalScrollBar:new{
            width = 8, height = 100, low = 0.25, high = 0.5,
            bordercolor = "track", rectcolor = "thumb",
            scroll_callback = function(ratio) selected = ratio end,
        }
        bar:paintTo(bb, 10, 20)

        assert.are.same({ 10, 20, 8, 100, 1, "track", 4 }, borders[1])
        assert.are.same({ 11, 45, 6, 25, "thumb", 3 }, fills[1])
        assert.are.same({ x = 2, y = 20, w = 24, h = 100 }, bar.touch_dimen)
        bar:onTapScroll(nil, { pos = { y = 45 } })
        assert.are.equal(0.25, selected)
    end)

    it("rounds horizontal bars and mirrors their thumb and callback in RTL", function()
        local selected
        local bar = HorizontalScrollBar:new{
            width = 100, height = 8, low = 0.25, high = 0.5,
            bordercolor = "track", rectcolor = "thumb",
            scroll_callback = function(ratio) selected = ratio end,
        }
        bar:paintTo(bb, 10, 20)
        assert.are.same({ 10, 20, 100, 8, 1, "track", 4 }, borders[1])
        assert.are.same({ 35, 21, 25, 6, "thumb", 3 }, fills[1])
        assert.are.same({ x = 10, y = 12, w = 100, h = 24 }, bar.touch_dimen)
        bar:onTapScroll(nil, { pos = { x = 35 } })
        assert.are.equal(0.25, selected)

        mirrored = true
        bar:paintTo(bb, 10, 20)
        assert.are.same({ 60, 21, 25, 6, "thumb", 3 }, fills[2])
        bar:onTapScroll(nil, { pos = { x = 35 } })
        assert.are.equal(0.75, selected)
    end)

    it("keeps minimum-sized thumbs inside either end of the track", function()
        for _i, class in ipairs({ VerticalScrollBar, HorizontalScrollBar }) do
            local vertical = class == VerticalScrollBar
            local bar = class:new{
                width = vertical and 8 or 100, height = vertical and 100 or 8,
                min_thumb_size = 10,
            }
            for _j, range in ipairs({ { 0, 0.001 }, { 0.999, 1 } }) do
                bar:set(range[1], range[2])
                bar:paintTo(bb, 10, 20)
                local fill = fills[#fills]
                assert.is_true(fill[1] >= 11 and fill[2] >= 21)
                assert.is_true(fill[1] + fill[3] <= 10 + bar.width - 1)
                assert.is_true(fill[2] + fill[4] <= 20 + bar.height - 1)
                assert.are.equal(10, vertical and fill[4] or fill[3])
            end
        end
    end)

    it("handles full, one-pixel, and disabled bars", function()
        local bar = VerticalScrollBar:new{
            width = 1, height = 100, bordersize = 0, rectcolor = "thumb",
        }
        bar:paintTo(bb, 10, 20)
        assert.are.equal(0, #borders)
        assert.are.same({ 10, 20, 1, 100, bar.rectcolor, 0 }, fills[1])

        bar.bordersize = 1
        bar:paintTo(bb, 10, 20)
        assert.are.equal(1, #fills)
        bar.enable = false
        bar:paintTo(bb, 10, 20)
        assert.are.equal(1, #borders)
        assert.are.equal(1, #fills)
    end)
end)
