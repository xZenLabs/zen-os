describe("raw paint for C-blitted night mode", function()
    local RawPaint = require("common/ui/raw_paint")

    local function fake_bb(inverse, cbb)
        return {
            getInverse = function(self) return self.inverse end,
            setInverse = function(self, value) self.inverse = value end,
            canUseCbb = function() return cbb end,
            inverse = inverse,
        }
    end

    it("clears the invert flag only while the C blitter ignores it", function()
        local bb, seen = fake_bb(1, true)
        RawPaint.run(bb, function(value) seen = { bb.inverse, value } end, "arg")
        assert.are.same({ 0, "arg" }, seen)
        assert.are.equal(1, bb.inverse)

        for _i, case in ipairs({ fake_bb(1, false), fake_bb(0, true), {} }) do
            assert.is_false(RawPaint.needed(case))
            RawPaint.run(case, function() seen = case.inverse end)
            assert.are.equal(case.inverse, seen)
        end
    end)

    it("restores the flag when painting fails", function()
        local bb = fake_bb(1, true)
        assert.has_error(function() RawPaint.run(bb, error, "boom") end, "boom")
        assert.are.equal(1, bb.inverse)
    end)

    it("pre-paints rounded RGB32 frame backgrounds raw and leaves other frames alone", function()
        local Blitbuffer = require("ffi/blitbuffer")
        local saved = package.loaded["ui/widget/container/framecontainer"]
        local stock = {}
        local Frame = { paintTo = function(self) stock[#stock + 1] = self.background and true or false end }
        package.loaded["ui/widget/container/framecontainer"] = Frame
        require("modules/global/patches/raw_rounded_fill")()
        package.loaded["ui/widget/container/framecontainer"] = saved

        local fills = {}
        local bb = fake_bb(1, true)
        function bb.paintRoundedRectRGB32(self, ...) fills[#fills + 1] = { self.inverse, ... } end
        local color = Blitbuffer.ColorRGB32(1, 2, 3, 255)
        local frame = { background = color, radius = 4, bordersize = 1, width = 30,
            getSize = function() return { w = 20, h = 10 } end }
        Frame.paintTo(frame, bb, 5, 6)
        assert.is_true(rawequal(color, table.remove(fills[1], 6)))
        assert.are.same({ { 0, 5, 6, 30, 10, 5 } }, fills)
        assert.are.same({ false }, stock)
        assert.is_true(rawequal(color, frame.background))

        frame.radius = 0
        Frame.paintTo(frame, bb, 5, 6)
        frame.radius, frame.background = 4, Blitbuffer.COLOR_BLACK
        Frame.paintTo(frame, bb, 5, 6)
        frame.background = color
        Frame.paintTo(frame, fake_bb(1, false), 5, 6)
        assert.are.equal(1, #fills)
        assert.are.same({ false, true, true, true }, stock)
    end)
end)
