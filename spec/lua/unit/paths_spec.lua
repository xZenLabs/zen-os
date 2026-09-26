local Paths = require("common/paths")

describe("paths", function()
    before_each(function()
        _G.G_reader_settings = ZenSpec.memorySettings({ home_dir = "/sdcard/Books/" })
        ZenSpec.replace("config/manager", {
            get = function()
                return { additional_home_dirs = { "/library/extra" } }
            end,
        })
    end)

    it("normalizes Android storage and respects primary/additional home roots", function()
        assert.are.equal("/storage/emulated/0/Books", Paths.getHomeDir())
        assert.is_true(Paths.isInHomeDir("/sdcard/Books/Series"))
        assert.is_true(Paths.isHomeRoot("/library/extra/"))
        assert.is_false(Paths.isPrimaryHomeRoot("/library/extra"))
        assert.is_false(Paths.isInHomeDir("/outside/Book.epub"))
    end)

    it("matches canonical history paths under an explicit /sdcard home", function()
        _G.G_reader_settings = ZenSpec.memorySettings({ home_dir = "/sdcard" })

        assert.are.equal("/storage/emulated/0", Paths.getConfiguredHomeDir())
        assert.are.equal("/storage/emulated/0", Paths.getHomeDir())
        assert.is_true(Paths.isInHomeDir("/storage/emulated/0/Book.epub"))
    end)

    it("falls back to KOReader's normalized device home", function()
        _G.G_reader_settings = ZenSpec.memorySettings()
        ZenSpec.replace("device", { home_dir = "/sdcard/" })

        assert.is_nil(Paths.getConfiguredHomeDir())
        assert.are.equal("/storage/emulated/0", Paths.getHomeDir())
        assert.is_true(Paths.isInHomeDir("/storage/emulated/0/Book.epub"))
    end)

    it("themes the external archive without treating it as a library root", function()
        local original_get_archive_dir = Paths.getArchiveDir
        Paths.getArchiveDir = function() return "/storage/emulated/0/Archive" end

        assert.is_true(Paths.isInThemedDir("/sdcard/Archive/Book.epub"))
        assert.is_true(Paths.isArchiveRoot("/sdcard/Archive/"))
        assert.is_false(Paths.isInHomeDir("/sdcard/Archive/Book.epub"))
        assert.is_false(Paths.isHomeRoot("/sdcard/Archive"))

        Paths.getArchiveDir = original_get_archive_dir
    end)
end)
