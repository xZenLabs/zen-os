require("ffi/loadlib")

describe("bundled UI font paths", function()
    local saved_root
    local saved_module
    local saved_defaults

    before_each(function()
        saved_defaults = package.loaded["config/defaults"]
        saved_root = package.loaded["common/plugin_root"]
        saved_module = package.loaded["common/library_font_path"]
        ZenSpec.replace("common/plugin_root", ZenSpec.root)
        ZenSpec.unload("common/library_font_path")
    end)

    after_each(function()
        package.loaded["config/defaults"] = saved_defaults
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
    it("copies bundled families into KOReader's fonts dir and resolves to the copies", function()
        local lfs = require("libs/libkoreader-lfs")
        local fontdir = os.tmpname()
        os.remove(fontdir)
        assert.truthy(lfs.mkdir(fontdir))
        local read_dirs = {}
        local FontList = {
            fontdir = fontdir,
            fontlist = { fontdir .. "/stock/Stock.ttf" },
            fontinfo = {},
            _readList = function(self, dir, mark)
                read_dirs[#read_dirs + 1] = dir
                for file in lfs.dir(dir) do
                    if file:match("%.ttf$") then
                        local path = dir .. "/" .. file
                        table.insert(self.fontlist, path)
                        self.fontinfo[path] = { { name = file } }
                        mark[path] = true
                    end
                end
            end,
        }
        local paths = require("common/library_font_path")
        local added = paths.installBundled(FontList)

        local face = paths.BUNDLED_DEFAULT
        local global = fontdir .. "/hyperreadable/Hyperreadable-Regular.ttf"
        assert.are.equal(lfs.attributes(ZenSpec.root .. "/" .. face, "size"),
            lfs.attributes(global, "size"))
        assert.is_true(added[global])
        assert.are.equal(global, paths.resolve(face))
        assert.are.equal(face, paths.toConfig(global))
        assert.are.equal(fontdir .. "/stock/Stock.ttf", paths.toConfig(fontdir .. "/stock/Stock.ttf"))

        -- Plugin paths resolved before install must load the installed copy.
        local Font = { fontmap = {} }
        FontList.getFontList = function(self) return self.fontlist end
        paths.registerFontAliases(Font, FontList)
        assert.are.equal("hyperreadable/Hyperreadable-Regular.ttf", Font.fontmap[global])
        assert.are.equal("hyperreadable/Hyperreadable-Regular.ttf", Font.fontmap[ZenSpec.root .. "/" .. face])

        -- Second run: nothing to copy or rescan.
        read_dirs = {}
        assert.is_nil(next(paths.installBundled(FontList)))
        assert.are.same({}, read_dirs)
        os.execute("rm -rf '" .. fontdir .. "'")
    end)
    it("keeps the language-specific default when sharing font settings helpers", function()
        ZenSpec.replace("config/defaults", { library_font = { font_face = "default" } })
        local paths = require("common/library_font_path")
        assert.are.equal("default", paths.ensureConfig({}).font_face)
        assert.are.equal("default", paths.resolveConfigured("default"))
        local face, file = paths.pickerDefault({ isFontRegistered = function() return true end })
        assert.are.same({ "default", "default" }, { face, file })
    end)
end)
