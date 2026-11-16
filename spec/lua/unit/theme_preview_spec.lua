describe("theme preview", function()
    local ThemePreview
    local saved_modules
    local module_names = {
        "device", "ui/size", "ui/widget/container/centercontainer", "ui/widget/container/framecontainer",
        "common/ui/color_text_widget", "common/reader_themes", "common/ui/theme_preview",
    }
    local function widget() return { new = function(_, spec) return spec end } end

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(module_names) do
            saved_modules[name] = package.loaded[name]
            ZenSpec.unload(name)
        end
        ZenSpec.replace("device", { screen = { scaleBySize = function(_, size) return size end } })
        ZenSpec.replace("ui/size", { border = { thin = 1 } })
        ZenSpec.replace("ui/widget/container/centercontainer", widget())
        ZenSpec.replace("ui/widget/container/framecontainer", widget())
        ZenSpec.replace("common/ui/color_text_widget", widget())
        ZenSpec.replace("common/reader_themes", {
            getPreviewColors = function(_, key)
                if key == "sepia" then return "text", "background" end
            end,
        })
        ThemePreview = require("common/ui/theme_preview")
    end)

    after_each(function()
        for _i, name in ipairs(module_names) do
            package.loaded[name] = saved_modules[name]
        end
    end)

    it("builds a rounded swatch in the theme colors", function()
        local preview = ThemePreview.new{ key = "sepia", width = 100, height = 40 }
        assert.are.equal("background", preview.background)
        assert.are.equal("text", preview[1][1].fgcolor)
        assert.are.equal(10, preview.radius)
        assert.are.equal(100, preview.width)
        assert.are.equal(90, preview[1][1].max_width)
    end)

    it("clamps the corner radius for short swatches", function()
        assert.are.equal(7, ThemePreview.new{ key = "sepia", width = 100, height = 16 }.radius)
    end)

    it("accepts a custom corner radius", function()
        assert.are.equal(4, ThemePreview.new{ key = "sepia", width = 100, height = 40, radius = 4 }.radius)
    end)

    it("returns nil for unknown themes", function()
        assert.is_nil(ThemePreview.new{ key = "missing", width = 100, height = 40 })
    end)
end)
