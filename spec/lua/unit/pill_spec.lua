describe("shared pill rendering", function()
    local Pill = require("common/ui/pill")

    it("uses half the thickness for either orientation, including dots and thin bars", function()
        assert.are.equal(3, Pill.radius(100, 6))
        assert.are.equal(3, Pill.radius(6, 100))
        assert.are.equal(2, Pill.radius(100, 5))
        assert.are.equal(5, Pill.radius(10, 10))
        assert.are.equal(0, Pill.radius(1, 100))
    end)

    it("paints pills in the native buffer and leaves corner pixels untouched", function()
        local BB = require("ffi/blitbuffer")
        for _i, size in ipairs({ { 40, 8 }, { 8, 40 } }) do
            local bb = BB.new(50, 50, BB.TYPE_BB8)
            bb:fill(BB.COLOR_WHITE)
            Pill.paint(bb, 2, 3, size[1], size[2], BB.COLOR_BLACK)
            assert.are.equal(255, bb:getPixel(2, 3):getColor8().a)
            assert.are.equal(0, bb:getPixel(2 + math.floor(size[1] / 2),
                3 + math.floor(size[2] / 2)):getColor8().a)
            assert.are.equal(255, bb:getPixel(1, 3):getColor8().a)
            bb:free()
        end
    end)

    it("skips empty shapes", function()
        Pill.paint({}, 0, 0, 0, 10, "black")
        Pill.paint({}, 0, 0, 10, 0, "black")
    end)
end)
