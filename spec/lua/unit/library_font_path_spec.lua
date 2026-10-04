require("ffi/loadlib")

describe("bundled UI font paths", function()
    local saved_root
    local saved_module

    before_each(function()
        saved_root = package.loaded["common/plugin_root"]
        saved_module = package.loaded["common/library_font_path"]
        ZenSpec.replace("common/plugin_root", ZenSpec.root)
        ZenSpec.unload("common/library_font_path")
    end)

    after_each(function()
        package.loaded["common/plugin_root"] = saved_root
        package.loaded["common/library_font_path"] = saved_module
    end)

    it("loads bundled absolute paths with stable KOReader's fonts-directory prefix", function()
        local Font = { fontmap = { cfont = "NotoSans-Regular.ttf" } }
        local fonts = {
            ZenSpec.root .. "/fonts/hyperreadable/Hyperreadable-Regular.ttf",
            ZenSpec.root .. "/fonts/hyperreadable/Hyperreadable-SemiBold.ttf",
            "/external/Custom.ttf",
        }
        local FontList = {
            fontdir = "./fonts",
            getFontList = function() return fonts end,
        }
        local paths = require("common/library_font_path")
        paths.registerFontAliases(Font, FontList)

        for i = 1, 2 do
            local alias = assert(Font.fontmap[fonts[i]])
            local path = FontList.fontdir .. "/" .. alias
            assert.are.equal(fonts[i], require("ffi/util").realpath(path))
            local face = require("ffi/freetype").newFaceSize(path, 14)
            face:done()
            assert.are.equal(alias, Font.fontmap[paths.resolve(paths.toConfig(fonts[i]))])
        end
        assert.are.equal("NotoSans-Regular.ttf", Font.fontmap.cfont)
        assert.is_nil(Font.fontmap[fonts[3]])
    end)
end)
