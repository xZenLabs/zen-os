describe("library font", function()
    local saved_modules
    local cfg
    local calls
    local warnings
    local plugin_root
    local default_font
    local resolved_default_font
    local default_font_missing
    local saved_configs

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs({
            "ui/font",
            "common/zen_logger",
            "common/plugin_root",
            "common/library_font_path",
            "config/defaults",
            "config/manager",
            "modules/filebrowser/patches/library_font",
        }) do
            saved_modules[name] = package.loaded[name] or false
        end

        cfg = { font_face = "Custom-Regular.ttf", font_size = 18 }
        calls = {}
        warnings = {}
        plugin_root = "/plugins/zenos.koplugin"
        default_font = "fonts/hyperreadable/Hyperreadable-Regular.ttf"
        resolved_default_font = plugin_root .. "/" .. default_font
        default_font_missing = false
        saved_configs = {}
        rawset(_G, "__ZEN_UI_LIBRARY_FONT_CFG", cfg)
        ZenSpec.replace("common/plugin_root", plugin_root)
        ZenSpec.replace("config/defaults", {
            library_font = { font_face = default_font, font_size = 18 },
        })
        ZenSpec.unload("common/library_font_path")
        ZenSpec.replace("ui/font", {
            getFace = function(_self, name, size)
                calls[#calls + 1] = { name, size }
                if name == plugin_root .. "/fonts/Missing-Regular.ttf" then return nil end
                if name == plugin_root .. "/fonts/Broken-Regular.ttf" then
                    error("font loader failed")
                end
                if default_font_missing and name == resolved_default_font then return nil end
                return { orig_font = name, orig_size = size }
            end,
        })
        ZenSpec.replace("common/zen_logger", {
            new = function()
                return {
                    warn = function(...)
                        warnings[#warnings + 1] = { ... }
                    end,
                }
            end,
        })
        local owning_config = { library_font = cfg }
        ZenSpec.replace("config/manager", {
            get = function() return owning_config end,
            save = function(config)
                saved_configs[#saved_configs + 1] = config
            end,
        })
        ZenSpec.unload("modules/filebrowser/patches/library_font")
    end)

    after_each(function()
        rawset(_G, "__ZEN_UI_LIBRARY_FONT_CFG", nil)
        for name, original in pairs(saved_modules) do
            package.loaded[name] = original == false and nil or original
        end
    end)

    it("uses and caches a loadable custom font", function()
        local library_font = require("modules/filebrowser/patches/library_font")

        assert.are.equal("Custom-Regular.ttf", library_font.getFontName())
        assert.are.equal("Custom-Regular.ttf", library_font.getFontName())
        assert.are.same({ { "Custom-Regular.ttf", 18 } }, calls)
        assert.are.equal(0, #warnings)
    end)

    it("temporarily applies the library face to menu fonts", function()
        local library_font = require("modules/filebrowser/patches/library_font")
        local Font = require("ui/font")
        local get_face = Font.getFace
        local mapped, untouched

        library_font.withMenuFaces(function()
            mapped = Font:getFace("smallinfofont", 22)
            untouched = Font:getFace("titlefont", 20)
        end)

        assert.are.equal("Custom-Regular.ttf", mapped.orig_font)
        assert.are.equal("titlefont", untouched.orig_font)
        assert.are.equal(get_face, Font.getFace)
    end)

    it("resolves and caches a portable bundled font path", function()
        cfg.font_face = "fonts/Custom-Regular.ttf"
        local library_font = require("modules/filebrowser/patches/library_font")

        local resolved = plugin_root .. "/fonts/Custom-Regular.ttf"
        assert.are.equal(resolved, library_font.getFontName())
        assert.are.equal(resolved, library_font.getFontName())
        assert.are.same({ { resolved, 18 } }, calls)
        assert.are.equal("fonts/Custom-Regular.ttf", cfg.font_face)
    end)

    it("leaves an external absolute font path unchanged", function()
        cfg.font_face = "/mnt/fonts/Custom-Regular.ttf"
        local library_font = require("modules/filebrowser/patches/library_font")

        assert.are.equal(cfg.font_face, library_font.getFontName())
        assert.are.same({ { cfg.font_face, 18 } }, calls)
    end)

    it("uses the default alias without probing it as a custom font", function()
        cfg.font_face = "cfont"
        local library_font = require("modules/filebrowser/patches/library_font")

        assert.are.equal("cfont", library_font.getFontName())
        assert.are.equal(0, #calls)
        assert.are.equal(0, #warnings)
    end)

    it("restores the default when the configured font file is missing", function()
        cfg.font_face = "fonts/Missing-Regular.ttf"
        cfg.font_size = 24
        local library_font = require("modules/filebrowser/patches/library_font")

        assert.are.equal(resolved_default_font, library_font.getFontName())
        local face = library_font.getFace(16)

        assert.are.equal(resolved_default_font, face.orig_font)
        assert.are.equal(default_font, cfg.font_face)
        assert.are.equal(24, cfg.font_size)
        assert.are.same({
            { plugin_root .. "/fonts/Missing-Regular.ttf", 18 },
            { resolved_default_font, 18 },
            { resolved_default_font, 16 },
        }, calls)
        assert.are.equal(1, #warnings)
        assert.are.same({ { library_font = cfg } }, saved_configs)
    end)

    it("restores the default when the font loader raises an error", function()
        cfg.font_face = "fonts/Broken-Regular.ttf"
        local library_font = require("modules/filebrowser/patches/library_font")

        assert.are.equal(resolved_default_font, library_font.getFontName())
        assert.are.equal(default_font, cfg.font_face)
        assert.are.equal(1, #warnings)
    end)

    it("uses the KOReader default when the restored bundled font is unavailable", function()
        cfg.font_face = "fonts/Missing-Regular.ttf"
        default_font_missing = true
        local library_font = require("modules/filebrowser/patches/library_font")

        assert.are.equal("cfont", library_font.getFontName())
        local face = library_font.getFace(16)

        assert.are.equal("cfont", face.orig_font)
        assert.are.equal("default", cfg.font_face)
    end)

    it("resolves legacy absolute plugin paths in widget style fonts", function()
        local library_font = require("modules/filebrowser/patches/library_font")
        local legacy = "/mnt/us/koreader/plugins/zen_ui.koplugin/" .. default_font

        assert.are.equal(resolved_default_font, library_font.resolveStyleFont(legacy))
        assert.are.equal("Custom-Regular.ttf", library_font.resolveStyleFont("default"))
        assert.are.equal("smallinfofont", library_font.resolveStyleFont("default", "smallinfofont"))
        assert.are.equal(resolved_default_font, library_font.getStyleFace(legacy, 12).orig_font)
    end)

    it("falls back when a widget style font cannot load", function()
        local library_font = require("modules/filebrowser/patches/library_font")
        local missing = plugin_root .. "/fonts/Missing-Regular.ttf"

        assert.are.equal("smallinfofont", library_font.getStyleFace(missing, 12, "smallinfofont").orig_font)
        assert.are.equal("Custom-Regular.ttf", library_font.getStyleFace(missing, 14).orig_font)
        assert.are.equal("Custom-Regular.ttf",
            library_font.getStyleFace(plugin_root .. "/fonts/Broken-Regular.ttf", 14).orig_font)
        local missing_probes = 0
        for _i, call in ipairs(calls) do
            if call[1] == missing then missing_probes = missing_probes + 1 end
        end
        assert.are.equal(1, missing_probes)
        assert.are.equal("cfont", library_font.getStyleFace(missing, 14, missing).orig_font)
    end)
end)
