describe("UI scale conversions", function()
    local Scale
    local saved_device

    local function stub_device(factor)
        ZenSpec.replace("device", { screen = {
            scaleBySize = function(_, value) return math.ceil(value * factor) end,
        } })
    end

    before_each(function()
        saved_device = package.loaded["device"]
        -- Fresh copy: the shared instance runs specs at reference 1.
        Scale = dofile(ZenSpec.root .. "/common/ui/scale.lua")
    end)
    after_each(function() package.loaded["device"] = saved_device end)

    it("turns sizes tuned through scaleBySize into screen-independent font sizes", function()
        for _i, factor in ipairs({ 1, 1264 / 600, 3.1 }) do
            stub_device(factor)
            -- Same result as scaleBySize on the 1264 px reference panel.
            assert.are.equal(22, Scale.font(10))
            assert.are.equal(34, Scale.font(16))
            assert.are.equal(38, Scale.font(18))
        end
        assert.are.equal(1, Scale.font(0.1))
    end)

    it("keeps pixel-derived sizes at their reference-screen proportion", function()
        stub_device(1264 / 600)
        assert.are.equal(14, Scale.fontFromTunedPx(14)) -- unchanged where it was tuned
        stub_device(1)
        assert.are.equal(14, Scale.fontFromTunedPx(14 * 600 / 1264))
    end)

    it("converts device pixels to the font size that renders at them", function()
        stub_device(2.12)
        local size = Scale.fontFromPx(20)
        assert.is_true(size < 20 / 2.12 + 0.001)
        assert.are.equal(20, math.ceil(size * 2.12)) -- what Font:getFace renders
        stub_device(1)
        assert.are.equal(20, Scale.fontFromPx(20))
    end)

    it("keeps device pixels out of Font:getFace calls", function()
        local lfs = require("lfs")
        local offenders = {}
        local function scan(dir)
            for entry in lfs.dir(dir) do
                local path = dir .. "/" .. entry
                if entry:sub(1, 1) ~= "." and lfs.attributes(path, "mode") == "directory" then
                    scan(path)
                elseif entry:sub(-4) == ".lua" then
                    local file = assert(io.open(path, "r"))
                    local source = file:read("*a")
                    file:close()
                    for call in source:gmatch("[gG]et%a*Face%s*(%b())") do
                        if call:find("scaleBySize", 1, true) then
                            offenders[#offenders + 1] = path:sub(#ZenSpec.root + 2) .. " " .. call
                        end
                    end
                end
            end
        end
        scan(ZenSpec.root .. "/common")
        scan(ZenSpec.root .. "/modules")
        assert.are.same({}, offenders)
    end)

    it("shrinks reference-screen pixel counts on smaller screens", function()
        stub_device(1)
        assert.are.equal(142, Scale.px(300))
        assert.are.equal(1, Scale.px(1))
        stub_device(1264 / 600)
        assert.are.equal(300, Scale.px(300))
    end)
end)
