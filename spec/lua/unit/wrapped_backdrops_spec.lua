describe("Wrapped backdrops", function()
    local Backdrops
    local saved
    local names = { "ffi/blitbuffer", "device", "common/ui/wrapped_backdrops" }
    local BOX = { x = 10, y = 20, w = 600, h = 700 }

    before_each(function()
        saved = {}
        for _i, name in ipairs(names) do saved[name] = package.loaded[name] or false end
        ZenSpec.replace("ffi/blitbuffer", { COLOR_GRAY_E = "light", COLOR_GRAY_D = "mid" })
        ZenSpec.replace("device", { screen = { scaleBySize = function(_self, size) return size end } })
        ZenSpec.unload("common/ui/wrapped_backdrops")
        Backdrops = require("common/ui/wrapped_backdrops")
    end)

    after_each(function()
        ZenSpec.unload("common/ui/wrapped_backdrops")
        for _i, name in ipairs(names) do package.loaded[name] = saved[name] or nil end
    end)

    local function paint(index, count, clear)
        local runs = {}
        local bb = { paintRect = function(_self, x, y, w, h, color)
            runs[#runs + 1] = { x = x, y = y, w = w, h = h, color = color }
        end }
        Backdrops.paint(bb, index, count, BOX.x, BOX.y, BOX.w, BOX.h, clear)
        return runs
    end

    it("opens and closes on confetti and never repeats a backdrop on neighbouring slides", function()
        local seen, previous = {}, nil
        for index = 1, 16 do
            local name, mirror = Backdrops.pick(index, 16)
            if index == 1 or index == 16 then
                assert.are.equal("confetti", name)
            else
                assert.are_not.equal("confetti", name)
                assert.are_not.equal(previous, name)
                -- The second pass through the cycle is mirrored.
                assert.are.equal(index >= 9, mirror)
                seen[name] = true
            end
            previous = name
        end
        local count = 0
        for _name in pairs(seen) do count = count + 1 end
        assert.are.equal(7, count)
        assert.are.equal("confetti", (Backdrops.pick(1, 1)))
    end)

    it("paints every backdrop as light one-row runs inside its box", function()
        for index = 1, 16 do
            local runs = paint(index, 16)
            assert.is_true(#runs > 0)
            for _i, run in ipairs(runs) do
                assert.are.equal(1, run.h)
                assert.is_true(run.w > 0 and run.x >= BOX.x and run.x + run.w <= BOX.x + BOX.w)
                assert.is_true(run.y >= BOX.y and run.y < BOX.y + BOX.h)
                assert.is_true(run.color == "light" or run.color == "mid")
            end
        end
    end)

    it("paints the same confetti every time and keeps it out of the clear box", function()
        assert.are.same(paint(1, 16), paint(1, 16))
        local clear = { x = 200, y = 100, w = 200, h = 200 }
        local runs = paint(1, 16, clear)
        assert.is_true(#runs > 0 and #runs < #paint(1, 16))
        for _i, run in ipairs(runs) do
            local in_rows = run.y >= BOX.y + clear.y and run.y < BOX.y + clear.y + clear.h
            local in_cols = run.x < BOX.x + clear.x + clear.w and run.x + run.w > BOX.x + clear.x
            assert.is_false(in_rows and in_cols)
        end
    end)

    it("paints nothing into an empty box", function()
        local runs = {}
        Backdrops.paint({ paintRect = function() runs[#runs + 1] = true end }, 2, 16, 0, 0, 600, 0)
        assert.are.equal(0, #runs)
    end)
end)
