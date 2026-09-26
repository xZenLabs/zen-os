local Navigation

describe("library navigation", function()
    before_each(function()
        for _i, name in ipairs({
            "__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB", "__ZEN_UI_OPEN_TARGET_TAB",
            "__ZEN_UI_OPEN_TARGET_FOLDER", "__ZEN_UI_OPEN_HOME_AFTER_FILEMANAGER",
            "__ZEN_UI_OPEN_TARGET_TAG",
            "__ZEN_UI_KEEP_BOOK_LOCATION", "__ZEN_UI_LAST_READ_FILE",
            "__ZEN_UI_LIBRARY_STATE", "__ZEN_UI_NAVBAR_OPEN_DEFAULT_TAB",
            "__ZEN_UI_NAVBAR_OPEN_FOLDER",
        }) do
            _G[name] = nil
        end
        _G.G_reader_settings = ZenSpec.memorySettings({
            allow_commaneer_filemanager = true,
            home_dir = "/library",
        })
        ZenSpec.replace("ui/event", {
            new = function(_, name) return { name = name } end,
        })
        ZenSpec.replace("device", { home_dir = "/sdcard" })
        ZenSpec.replace("config/manager", { get = function() return {} end })
        ZenSpec.replace("MangaReader", { is_showing = false })
        ZenSpec.replace("common/utils", {
            closeWidgetsAbove = function(anchor)
                assert.is_true(anchor.tearing_down)
                anchor.overlays_closed = true
            end,
        })
        ZenSpec.unload("common/paths")
        ZenSpec.unload("common/library_navigation")
        Navigation = require("common/library_navigation")
    end)

    local function reader(file)
        local state = {
            document = { file = file or "/library/Book.epub" },
            doc_settings = {},
            tearing_down = false,
        }
        function state:handleEvent(event)
            assert.is_true(self.tearing_down)
            self.event = event
        end
        function state:onClose()
            assert.is_false(self.tearing_down)
            assert.is_true(self.overlays_closed)
            self.closed = true
        end
        function state:showFileManager(file_path)
            self.shown = file_path
        end
        return state
    end

    it("closes reader overlays before rebuilding the library", function()
        local ui = reader()
        local dialog = {}
        ui.dialog = dialog
        ZenSpec.replace("common/utils", {
            closeWidgetsAbove = function(anchor)
                assert.are.equal(dialog, anchor)
                assert.is_true(ui.tearing_down)
                ui.overlays_closed = true
            end,
        })

        Navigation.showFromReader(ui, {
            config = { features = { restore_library_view = false } },
        })

        assert.is_true(ui.closed)
        assert.is_true(_G.__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB)
    end)

    it("returns to the file manager with a requested non-retained tab", function()
        local ui = reader()
        local plugin = { config = { features = { restore_library_view = true } } }

        assert.is_true(Navigation.showFromReader(ui, plugin, { target_tab = "history" }))
        assert.are.equal("CloseConfigMenu", ui.event.name)
        assert.is_true(ui.closed)
        assert.are.equal("/library/Book.epub", ui.shown)
        assert.are.equal("history", _G.__ZEN_UI_OPEN_TARGET_TAB)
    end)

    it("runs a post-close action after releasing the document and before opening its folder", function()
        local order = {}
        ZenSpec.replace("MangaReader", {
            is_showing = true,
            onReturn = function() error("archive must close ReaderUI") end,
        })
        local ui = reader("/library/Fiction/Book.epub")
        function ui:onClose()
            order[#order + 1] = "close"
            self.document = nil
        end
        function ui:showFileManager()
            order[#order + 1] = "open"
        end

        Navigation.showFromReader(ui, nil, {
            target_folder = "/library/Fiction/",
            after_close = function()
                assert.is_nil(ui.document)
                order[#order + 1] = "move"
            end,
        })

        assert.are.same({ "close", "move", "open" }, order)
        assert.are.equal("/library/Fiction/", _G.__ZEN_UI_OPEN_TARGET_FOLDER)
    end)

    it("returns to the file manager with a requested specific tag", function()
        local ui = reader()
        local plugin = { config = { features = { restore_library_view = true } } }

        assert.is_true(Navigation.showFromReader(ui, plugin, { target_tag = "Science" }))

        assert.are.equal("Science", _G.__ZEN_UI_OPEN_TARGET_TAG)
        assert.is_nil(_G.__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB)
        assert.is_true(ui.closed)
    end)

    it("opens folder and tag destinations when Navbar is disabled", function()
        local folders = {}
        local tags = {}
        ZenSpec.replace("apps/filemanager/filemanager", { instance = {
            file_chooser = {
                changeToPath = function(_self, path) folders[#folders + 1] = path end,
            },
        } })
        ZenSpec.replace("common/shared_state", {
            get = function()
                return {
                    showTagDetail = function(tag) tags[#tags + 1] = tag end,
                }
            end,
        })
        local plugin = { config = { features = { restore_library_view = true } } }

        Navigation.showFromReader(reader(), plugin, { target_folder = "/library/Fiction" })
        Navigation.showFromReader(reader(), plugin, { target_tag = "Science" })

        assert.are.same({ "/library/Fiction" }, folders)
        assert.are.same({ "Science" }, tags)
        assert.is_nil(_G.__ZEN_UI_OPEN_TARGET_FOLDER)
        assert.is_nil(_G.__ZEN_UI_OPEN_TARGET_TAG)
    end)

    it("treats a dispatched Archive folder as a direct root without Navbar", function()
        local chooser = {
            changeToPath = function(self, path) self.path = path end,
        }
        ZenSpec.replace("apps/filemanager/filemanager", { instance = {
            file_chooser = chooser,
        } })
        local Paths = require("common/paths")
        Paths.getArchiveDir = function() return "/archive" end
        Paths.isArchiveRoot = function(path) return path == "/archive" end

        Navigation.showFromReader(reader(), {
            config = { features = { restore_library_view = true } },
        }, { target_folder = "/archive" })

        assert.are.equal("/archive", chooser.path)
        assert.are.equal("/archive", chooser._zen_direct_archive_root)
        assert.is_true(chooser._zen_opening_archive_root)
    end)

    it("uses Navbar folder navigation when FileManager survives Reader teardown", function()
        local direct_changes = {}
        local navbar_opens = {}
        ZenSpec.replace("apps/filemanager/filemanager", { instance = {
            file_chooser = {
                changeToPath = function(_self, path)
                    direct_changes[#direct_changes + 1] = path
                end,
            },
        } })
        _G.__ZEN_UI_NAVBAR_OPEN_FOLDER = function(path)
            navbar_opens[#navbar_opens + 1] = path
            return true
        end

        Navigation.showFromReader(reader(), {
            config = { features = { restore_library_view = true } },
        }, { target_folder = "/library/Fiction" })

        assert.are.same({ "/library/Fiction" }, navbar_opens)
        assert.are.same({}, direct_changes)
        assert.is_nil(_G.__ZEN_UI_OPEN_TARGET_FOLDER)
    end)

    it("keeps a book outside home instead of forcing the default tab", function()
        local ui = reader("/outside/Book.epub")
        local plugin = { config = { features = { restore_library_view = false } } }

        Navigation.showFromReader(ui, plugin)

        assert.is_true(_G.__ZEN_UI_KEEP_BOOK_LOCATION)
        assert.is_nil(_G.__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB)
    end)

    it("uses KOReader's Android home when no explicit home is stored", function()
        _G.G_reader_settings = ZenSpec.memorySettings({
            allow_commaneer_filemanager = true,
        })
        local ui = reader("/storage/emulated/0/Book.epub")

        Navigation.showFromReader(ui, {
            config = { features = { restore_library_view = true } },
        })

        assert.is_nil(_G.__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB)
        assert.is_nil(_G.__ZEN_UI_KEEP_BOOK_LOCATION)
    end)

    it("preserves a physical folder return when restore is enabled", function()
        local ui = reader("/library/Fiction/Book.epub")

        Navigation.showFromReader(ui, {
            config = { features = { restore_library_view = true } },
        })

        assert.is_true(ui.closed)
        assert.are.equal("/library/Fiction/Book.epub", ui.shown)
        assert.is_nil(_G.__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB)
    end)

    it("hides the passive focused underline after restoring a physical folder", function()
        local item = {
            _underline_container = { color = "black" },
            onUnfocus = function(self)
                self._underline_container.color = "white"
            end,
        }
        local chooser = {
            layout = { { item } },
            selected = { x = 1, y = 1 },
            prev_itemnumber = 4,
        }
        ZenSpec.replace("apps/filemanager/filemanager", {
            instance = { file_chooser = chooser },
        })

        Navigation.showFromReader(reader("/library/Fiction/Book.epub"), {
            config = { features = {
                restore_library_view = true,
                browser_hide_underline = true,
            } },
        })

        assert.are.equal("white", item._underline_container.color)
        assert.are.equal(4, chooser.prev_itemnumber)
    end)

    it("preserves captured group state when restore is enabled", function()
        local ui = reader("/library/Fiction/Book.epub")
        local state = {
            tab = "series",
            page = 3,
            detail_group = "Saga",
            detail_page = 2,
        }
        _G.__ZEN_UI_LIBRARY_STATE = state

        Navigation.showFromReader(ui, {
            config = { features = { restore_library_view = true } },
        })

        assert.is_true(ui.closed)
        assert.is_nil(_G.__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB)
        assert.are.equal(state, _G.__ZEN_UI_LIBRARY_STATE)
    end)

    it("arms the configured default before Reader teardown when restore is disabled", function()
        local ui = reader()
        local original_close = ui.onClose
        function ui:onClose()
            assert.is_true(_G.__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB)
            return original_close(self)
        end

        Navigation.showFromReader(ui, {
            config = { features = { restore_library_view = false } },
        })

        assert.is_true(ui.closed)
        assert.are.equal("/library/Book.epub", ui.shown)
    end)

    it("forces an explicit default even when Android reports an outside path", function()
        local ui = reader("/outside/Book.epub")

        Navigation.showFromReader(ui, {
            config = { features = { restore_library_view = true } },
        }, { force_default = true })

        assert.is_true(_G.__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB)
        assert.is_nil(_G.__ZEN_UI_KEEP_BOOK_LOCATION)
    end)

    it("opens the default directly when a surviving FileManager bypasses showFiles", function()
        local ui = reader()
        local default_opens = 0
        _G.__ZEN_UI_LIBRARY_STATE = { tab = "series", page = 2 }
        _G.__ZEN_UI_NAVBAR_OPEN_DEFAULT_TAB = function()
            default_opens = default_opens + 1
        end

        Navigation.showFromReader(ui, {
            config = { features = { restore_library_view = true } },
        }, { force_default = true })

        assert.are.equal(1, default_opens)
        assert.is_nil(_G.__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB)
        assert.is_nil(_G.__ZEN_UI_LIBRARY_STATE)
    end)

    it("opens the default after a surviving teardown when restore is disabled", function()
        local ui = reader()
        local default_opens = 0
        _G.__ZEN_UI_LIBRARY_STATE = { tab = "authors", page = 3 }
        _G.__ZEN_UI_NAVBAR_OPEN_DEFAULT_TAB = function()
            default_opens = default_opens + 1
        end

        Navigation.showFromReader(ui, {
            config = { features = { restore_library_view = false } },
        })

        assert.are.equal(1, default_opens)
        assert.is_nil(_G.__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB)
        assert.is_nil(_G.__ZEN_UI_LIBRARY_STATE)
    end)

    it("uses explicit home before a simultaneous folder target", function()
        local ui = reader()
        Navigation.showFromReader(ui, {
            config = { features = { restore_library_view = false } },
        }, {
            open_home = true,
            target_folder = "/library/Series",
        })

        assert.is_true(_G.__ZEN_UI_OPEN_HOME_AFTER_FILEMANAGER)
        assert.is_nil(_G.__ZEN_UI_OPEN_TARGET_FOLDER)
        assert.is_true(ui.closed)
        assert.are.equal("/library/Book.epub", ui.shown)
    end)

    it("returns to Rakuyomi instead of closing Reader when available", function()
        local returns = 0
        ZenSpec.replace("MangaReader", {
            is_showing = true,
            onReturn = function() returns = returns + 1 end,
        })
        local ui = reader()

        Navigation.showFromReader(ui, {
            config = {
                features = { restore_library_view = true },
                rakuyomi = { return_to_chapter_list_on_exit = true },
            },
        })

        assert.are.equal(1, returns)
        assert.is_nil(ui.closed)
    end)

    it("closes Rakuyomi chapters when their own return is disabled", function()
        ZenSpec.replace("MangaReader", {
            is_showing = true,
            onReturn = function() error("Rakuyomi return is disabled") end,
        })
        local ui = reader("/library/chapter.cbz")

        Navigation.showFromReader(ui, { config = {
            features = { restore_library_view = false },
            rakuyomi = { return_to_chapter_list_on_exit = false },
        } })

        assert.is_true(ui.closed)
    end)
end)
