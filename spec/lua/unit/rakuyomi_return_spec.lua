describe("Rakuyomi reader return", function()
    local original_modules = {}
    local original_plugin
    local original_rakuyomi
    local original_globals
    local globals = { "__ZEN_UI_LIBRARY_SOURCE_TAB", "__ZEN_UI_FORCE_SOURCE_TAB_RESTORE",
        "__ZEN_UI_RAKUYOMI_RETURN_FILE", "__ZEN_UI_RAKUYOMI_CHAPTER_LIST_RESTORED" }
    local module_names = {
        "MangaReader",
        "apps/filemanager/filemanager",
        "apps/reader/readerui",
        "ui/geometry",
        "device",
        "ui/uimanager",
        "common/zen_logger",
        "common/library_navigation",
        "common/paths",
        "common/utils",
        "ui/event",
        "gettext",
    }

    local function apply_patch(return_enabled, open_enabled)
        local opened_chapters, opened_library, opened_zen = 0, 0, 0
        local MangaReader = {
            is_showing = true,
            on_return_callback = function() opened_chapters = opened_chapters + 1 end,
            onReturn = function(self) self.on_return_callback() end,
            clean = function(self) self.cleaned = true end,
        }
        ZenSpec.replace("MangaReader", MangaReader)
        ZenSpec.replace("apps/filemanager/filemanager", { instance = { rakuyomi = {
            openLibraryView = function(_self, options)
                assert.is_true(options.hideTopClose)
                assert.is_true(options.forceLibraryView)
                opened_library = opened_library + 1
            end,
        } } })
        ZenSpec.replace("apps/reader/readerui", {
            instance = { document = { file = "/library/chapter.cbz" } },
            showReader = function() end,
            onClose = function() end,
        })
        ZenSpec.replace("ui/geometry", {})
        ZenSpec.replace("device", { screen = {} })
        ZenSpec.replace("ui/uimanager", {
            _window_stack = {},
            nextTick = function(_self, callback) callback() end,
        })
        ZenSpec.replace("common/zen_logger", {
            new = function() return { warn = function() end } end,
        })
        ZenSpec.replace("gettext", function(text) return text end)
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { restore_library_view = return_enabled },
                rakuyomi = {
                    return_to_chapter_list_on_exit = return_enabled,
                    open_on_manga_exit = open_enabled,
                },
            },
        }
        ZenSpec.replace("common/library_navigation", {
            restoreEnabled = function(plugin) return plugin.config.features.restore_library_view end,
            showFromReader = function(reader, plugin, opts)
                assert.are.equal(require("apps/reader/readerui").instance, reader)
                assert.are.equal(_G.__ZEN_UI_PLUGIN, plugin)
                assert.are.equal(not plugin.config.features.restore_library_view, opts.force_default)
                opened_zen = opened_zen + 1
                opts.after_close()
                return true
            end,
        })
        ZenSpec.unload("modules/filebrowser/patches/rakuyomi")
        require("modules/filebrowser/patches/rakuyomi").apply()
        local Rakuyomi = _G.__ZEN_UI_RAKUYOMI
        Rakuyomi.isChapterFile = function() return true end
        Rakuyomi.openChapterListingFromFile = function(path, hide_top_close)
            opened_chapters = opened_chapters + 1
            assert.are.equal("/library/chapter.cbz", path)
            assert.is_true(hide_top_close)
            return true
        end
        return MangaReader, function() return opened_chapters, opened_library, opened_zen end
    end

    before_each(function()
        original_globals = {}
        for _i, name in ipairs(globals) do
            original_globals[name] = rawget(_G, name)
            _G[name] = nil
        end
        for _i, name in ipairs(module_names) do
            original_modules[name] = package.loaded[name]
        end
        original_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        original_rakuyomi = rawget(_G, "__ZEN_UI_RAKUYOMI")
    end)

    after_each(function()
        for _i, name in ipairs(globals) do _G[name] = original_globals[name] end
        for _i, name in ipairs(module_names) do
            package.loaded[name] = original_modules[name]
        end
        _G.__ZEN_UI_PLUGIN = original_plugin
        _G.__ZEN_UI_RAKUYOMI = original_rakuyomi
        ZenSpec.unload("modules/filebrowser/patches/rakuyomi")
    end)

    it("returns directly to the chapter list when enabled", function()
        local MangaReader, results = apply_patch(true, true)
        MangaReader:onReturn()
        local opened_chapters, opened_library = results()
        assert.are.equal(1, opened_chapters)
        assert.are.equal(0, opened_library)
    end)

    it("opens Rakuyomi Home instead of the native chapter list when chapter-list return is disabled", function()
        local MangaReader, results = apply_patch(false, true)
        MangaReader:onReturn()
        local opened_chapters, opened_library = results()
        assert.are.equal(0, opened_chapters)
        assert.are.equal(1, opened_library)
    end)

    it("honors both Rakuyomi return options from the top-right Home button after a Home resume", function()
        for _i, chapter_list in ipairs({ true, false }) do
            local MangaReader, results = apply_patch(chapter_list, true)
            MangaReader.chapter = { _zen_rakuyomi_source_tab = "home" }
            local reader = require("apps/reader/readerui").instance
            reader.handleEvent = function() end
            reader.onClose = function() error("Home must return through Rakuyomi") end
            ZenSpec.replace("common/paths", { isInHomeDir = function() return false end })
            ZenSpec.replace("common/utils", { closeWidgetsAbove = function() end })
            ZenSpec.replace("ui/event", { new = function(_self, name) return { name = name } end })
            require("ui/uimanager").scheduleIn = function(_self, _delay, callback) callback() end
            ZenSpec.unload("common/library_navigation")
            local menu_closed = false

            require("common/library_navigation").openDefault(reader, _G.__ZEN_UI_PLUGIN, function()
                menu_closed = true
            end)

            assert.is_true(menu_closed)
            assert.are.same(chapter_list and { 1, 0, 0 } or { 0, 1, 0 }, { results() })
        end
    end)

    it("uses Zen's exit navigation by default and when reopening Rakuyomi is disabled", function()
        for _i, return_enabled in ipairs({ true, false }) do
            local MangaReader, results = apply_patch(return_enabled, false)
            MangaReader:onReturn()
            assert.are.same({ 0, 0, 1 }, { results() })
            assert.is_true(MangaReader.cleaned)
            _G.__ZEN_UI_RAKUYOMI = nil

            MangaReader, results = apply_patch(return_enabled)
            MangaReader:onReturn()
            assert.are.same({ 0, 0, 1 }, { results() })
            assert.is_true(MangaReader.cleaned)
            _G.__ZEN_UI_RAKUYOMI = nil
        end
    end)

    it("does not reopen the chapter list after the file manager restored it", function()
        local MangaReader, results = apply_patch(true, true)
        _G.__ZEN_UI_RAKUYOMI_CHAPTER_LIST_RESTORED = true
        MangaReader:onReturn()
        local opened_chapters, opened_library = results()
        assert.are.equal(0, opened_chapters)
        assert.are.equal(0, opened_library)
    end)

    it("captures the actual opening source instead of forcing every chapter back to Rakuyomi", function()
        local MangaReader = apply_patch(true, true)
        local ReaderUI = require("apps/reader/readerui")
        MangaReader.chapter = { _zen_rakuyomi_source_tab = "manga" }
        ReaderUI:showReader("/library/chapter.cbz")
        assert.equals("manga", _G.__ZEN_UI_LIBRARY_SOURCE_TAB)
        assert.is_true(_G.__ZEN_UI_FORCE_SOURCE_TAB_RESTORE)
        assert.equals("/library/chapter.cbz", _G.__ZEN_UI_RAKUYOMI_RETURN_FILE)

        MangaReader.chapter = { _zen_rakuyomi_source_tab = "home" }
        _G.__ZEN_UI_LIBRARY_SOURCE_TAB = nil
        ReaderUI:showReader("/library/chapter.cbz")
        assert.equals("home", _G.__ZEN_UI_LIBRARY_SOURCE_TAB)
        assert.is_nil(_G.__ZEN_UI_FORCE_SOURCE_TAB_RESTORE)
        assert.is_nil(_G.__ZEN_UI_RAKUYOMI_RETURN_FILE)

        MangaReader.is_showing = false
        _G.__ZEN_UI_LIBRARY_SOURCE_TAB = "history"
        ReaderUI:showReader("/library/chapter.cbz")
        assert.equals("history", _G.__ZEN_UI_LIBRARY_SOURCE_TAB)
        assert.is_nil(_G.__ZEN_UI_FORCE_SOURCE_TAB_RESTORE)
        assert.is_nil(_G.__ZEN_UI_RAKUYOMI_RETURN_FILE)
    end)

    it("does not force Rakuyomi restoration and closes the chapter list when reopening is disabled", function()
        local MangaReader = apply_patch(true, false)
        local closed
        local UIManager = require("ui/uimanager")
        local listing = { name = "chapter_listing" }
        UIManager._window_stack = { { widget = listing } }
        UIManager.close = function(_self, widget) closed = widget end
        MangaReader.chapter = { _zen_rakuyomi_source_tab = "manga" }
        _G.__ZEN_UI_LIBRARY_SOURCE_TAB = "authors"

        require("apps/reader/readerui"):showReader("/library/chapter.cbz")

        assert.equals("authors", _G.__ZEN_UI_LIBRARY_SOURCE_TAB)
        assert.is_nil(_G.__ZEN_UI_FORCE_SOURCE_TAB_RESTORE)
        assert.is_nil(_G.__ZEN_UI_RAKUYOMI_RETURN_FILE)
        assert.are.equal(listing, closed)
    end)
end)
