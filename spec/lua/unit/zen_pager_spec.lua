describe("Zen pager positioning", function()
    local Pager
    local saved_modules
    local saved_settings
    local module_names = {
        "ffi/blitbuffer",
        "ui/font",
        "ui/geometry",
        "ui/widget/iconwidget",
        "ui/rendertext",
        "ui/uimanager",
        "device",
        "modules/filebrowser/patches/library_font",
        "common/ui/zen_pager",
        "common/ui/button_feedback",
    }

    before_each(function()
        saved_settings = G_reader_settings
        _G.G_reader_settings = { isFalse = function() return false end }
        saved_modules = {}
        for _i, name in ipairs(module_names) do
            saved_modules[name] = package.loaded[name] or false
        end
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_BLACK = "black",
            COLOR_DARK_GRAY = "dark_gray",
            COLOR_LIGHT_GRAY = "light_gray",
        })
        ZenSpec.replace("ui/font", {})
        ZenSpec.replace("ui/geometry", { new = function(_self, values) return values end })
        ZenSpec.replace("ui/widget/iconwidget", {})
        ZenSpec.replace("ui/rendertext", {})
        ZenSpec.replace("ui/uimanager", {})
        ZenSpec.replace("device", {
            screen = {
                scaleBySize = function(_self, value) return value end,
            },
        })
        ZenSpec.replace("modules/filebrowser/patches/library_font", {})
        ZenSpec.unload("common/ui/button_feedback")
        ZenSpec.unload("common/ui/zen_pager")
        Pager = require("common/ui/zen_pager")
    end)

    after_each(function()
        _G.G_reader_settings = saved_settings
        for _i, name in ipairs(module_names) do
            package.loaded[name] = saved_modules[name] or nil
        end
    end)

    it("centers a footer in the fixed space after a full page of rows", function()
        assert.are.equal(485, Pager.getCenteredFooterY(220, 750, 40, true))
    end)

    it("keeps full pages and tight layouts at the bottom", function()
        assert.are.equal(750, Pager.getCenteredFooterY(750, 750, 40, false))
        assert.are.equal(750, Pager.getCenteredFooterY(750, 750, 40, true))
    end)

    it("uses a centered footer spanning 92 percent of its container", function()
        local x, width = Pager.getFooterGeometry(0, 1000)

        assert.are.equal(40, x)
        assert.are.equal(920, width)
    end)

    it("widens chevron targets and extends only their bottoms by a bounded amount", function()
        assert.are.equal("left", Pager.getPageNumberZone(180, 250, 100, 200, 400, 40, 500))
        assert.are.equal("right", Pager.getPageNumberZone(420, 250, 100, 200, 400, 40, 500))
        assert.are.equal("center", Pager.getPageNumberZone(300, 220, 100, 200, 400, 40, 500))
        assert.is_nil(Pager.getPageNumberZone(300, 250, 100, 200, 400, 40, 500))
        assert.is_nil(Pager.getPageNumberZone(180, 264, 100, 200, 400, 40, 500))
        assert.are.equal(250, Pager.getChevronHitBottom(200, 40, 250))
    end)

    it("uses shared rounded feedback with padding around the tapped chevron", function()
        local Feedback = require("common/ui/button_feedback")
        for _i, side in ipairs({ "left", "right" }) do
            local flashed
            Feedback.flash = function(region) flashed = region end
            Pager.flashChevron(side, 100, 200, 400, 42)
            assert.are.same({ x = side == "left" and 108 or 448,
                y = 199, w = 44, h = 44 }, flashed)
        end
    end)

    it("skips feedback on the center and when button feedback is disabled", function()
        Pager.flashChevron("center", 100, 200, 400, 42)
        Pager.flashChevron(nil, 100, 200, 400, 42)
        G_reader_settings.isFalse = function(_self, key)
            assert.are.equal("flash_ui", key)
            return true
        end
        Pager.flashChevron("left", 100, 200, 400, 42)
        Pager.flashChevron("right", 100, 200, 400, 42)
    end)
end)
