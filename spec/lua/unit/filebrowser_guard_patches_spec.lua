describe("file browser guard patches", function()
    local original_plugin
    local original_memory_policy

    local function apply_patch(name)
        ZenSpec.unload(name)
        require(name)()
    end

    before_each(function()
        original_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        original_memory_policy = package.loaded["common/memory_policy"]
        _G.G_reader_settings = ZenSpec.memorySettings()
    end)

    after_each(function()
        _G.__ZEN_UI_PLUGIN = original_plugin
        package.loaded["common/memory_policy"] = original_memory_policy
    end)

    it("shows hidden and unsupported files only outside the library home", function()
        local observed = {}
        local FileChooser
        FileChooser = {
            show_hidden = true,
            show_unsupported = true,
            getList = function(self, path, collate)
                observed[#observed + 1] = {
                    path = path,
                    collate = collate,
                    hidden = FileChooser.show_hidden,
                    unsupported = FileChooser.show_unsupported,
                }
                return "stock"
            end,
        }
        ZenSpec.replace("ui/widget/filechooser", FileChooser)
        ZenSpec.replace("common/paths", {
            getHomeDir = function() return "/library" end,
            normPath = function(path) return path end,
        })
        _G.__ZEN_UI_PLUGIN = {
            config = { developer = { show_hidden_outside_home = true } },
        }

        apply_patch("modules/filebrowser/patches/browser_show_hidden")
        local chooser = { name = "filemanager", path = "/library" }
        assert.are.equal("stock", FileChooser.getList(chooser, "/library/series/", "natural"))
        assert.is_false(observed[1].hidden)
        assert.is_false(observed[1].unsupported)
        assert.is_false(G_reader_settings:readSetting("show_hidden"))

        assert.are.equal("stock", FileChooser.getList(chooser, "/mnt/usb", "date"))
        assert.is_true(observed[2].hidden)
        assert.is_true(observed[2].unsupported)
        assert.is_true(G_reader_settings:readSetting("show_unsupported"))
    end)

    it("does not change hidden-file policy for non-file-manager choosers", function()
        local FileChooser = {
            show_hidden = false,
            show_unsupported = false,
            getList = function() return {} end,
        }
        ZenSpec.replace("ui/widget/filechooser", FileChooser)
        ZenSpec.replace("common/paths", {
            getHomeDir = function() return "/library" end,
            normPath = function(path) return path end,
        })
        _G.__ZEN_UI_PLUGIN = {
            config = { developer = { show_hidden_outside_home = true } },
        }

        apply_patch("modules/filebrowser/patches/browser_show_hidden")
        FileChooser.getList({ name = "move_chooser" }, "/mnt/usb")
        assert.is_false(FileChooser.show_hidden)
        assert.is_false(FileChooser.show_unsupported)
    end)

    it("hides only the synthetic Kindle Library folder without mutating cached items", function()
        local source = {
            { text = "Kindle Library/", is_kindle_library_folder = true },
            { text = "Books", path = "/library/Books" },
        }
        local FileChooser = {
            _zen_kindle_library_patched = true,
            switchItemTable = function(self, _, items)
                self.item_table = items
                return items
            end,
        }
        ZenSpec.replace("ui/widget/filechooser", FileChooser)
        local plugin = { config = { kindle = { hide_library_folder = true } } }

        ZenSpec.unload("modules/filebrowser/patches/kindle_virtual_library")
        require("modules/filebrowser/patches/kindle_virtual_library").apply(plugin)
        local chooser = { name = "filemanager" }
        setmetatable(chooser, { __index = FileChooser })

        local filtered = chooser:switchItemTable(nil, source)
        assert.are.equal(1, #filtered)
        assert.are.equal("Books", filtered[1].text)
        assert.are.equal(2, #source)

        plugin.config.kindle.hide_library_folder = false
        assert.are.equal(source, chooser:switchItemTable(nil, source))
    end)

    it("opens Kindle Library through its registered dispatcher action", function()
        local dispatched, fallback = 0, 0
        local Dispatcher = {}
        function Dispatcher.getDisplayList(settings)
            assert.is_true(settings.kindle_library)
            return { { key = "kindle_library" } }
        end
        function Dispatcher:execute(settings)
            assert.is_true(settings.kindle_library)
            dispatched = dispatched + 1
        end
        ZenSpec.replace("dispatcher", Dispatcher)
        ZenSpec.replace("modules/menu/app_launcher/plugin_scan", {
            exists = function() return false end,
            installed = function() return { kindle = true } end,
            resolve = function(key, method)
                if key == "kindle" and method == "onShowKindleLibrary" then
                    return function() fallback = fallback + 1; return true end
                end
            end,
        })
        ZenSpec.unload("modules/filebrowser/patches/kindle_virtual_library")
        local Kindle = require("modules/filebrowser/patches/kindle_virtual_library")

        assert.is_true(Kindle.isAvailable())
        assert.is_true(Kindle.open())
        assert.are.equal(1, dispatched)
        assert.are.equal(0, fallback)
    end)

    it("opens the loaded Kindle library manager directly", function()
        local filemanager = {}
        local shown
        ZenSpec.replace("apps/filemanager/filemanager", { instance = filemanager })
        ZenSpec.replace("lua/filechooser_ext", {
            kindle_library = {
                show = function(_, ui, force)
                    shown = { ui, force }
                    return true
                end,
            },
        })
        ZenSpec.replace("modules/menu/app_launcher/plugin_scan", {})
        ZenSpec.unload("modules/filebrowser/patches/kindle_virtual_library")
        local Kindle = require("modules/filebrowser/patches/kindle_virtual_library")

        assert.is_true(Kindle.open())
        assert.are.same({ filemanager, true }, shown)
    end)

    it("reads Kindle thumbnail dimensions without decoding the image", function()
        ZenSpec.replace("modules/menu/app_launcher/plugin_scan", {})
        ZenSpec.unload("modules/filebrowser/patches/kindle_virtual_library")
        local Kindle = require("modules/filebrowser/patches/kindle_virtual_library")
        local jpeg = string.char(
            0xFF, 0xD8, 0xFF, 0xE0, 0, 2,
            0xFF, 0xC0, 0, 7, 8, 3, 32, 2, 88)
        local png = "\137PNG\r\n\26\n" .. string.char(
            0, 0, 0, 13) .. "IHDR" .. string.char(0, 0, 2, 88, 0, 0, 3, 32)

        assert.are.same({ 600, 800 }, { Kindle._imageSizeFromData(jpeg) })
        assert.are.same({ 600, 800 }, { Kindle._imageSizeFromData(png) })
        assert.is_nil(Kindle._imageSizeFromData("GIF89a"))
    end)

    it("lists the real paths exposed by the Kindle virtual library", function()
        ZenSpec.replace("modules/menu/app_launcher/plugin_scan", {})
        ZenSpec.replace("lua/open_file_ext", {
            virtual_library = {
                getBookEntries = function(_, force)
                    assert.is_false(force)
                    return {
                        { file = "/cache/converted.epub" },
                        { file = "/mnt/us/documents/native.kfx" },
                        { file = "" },
                    }
                end,
            },
        })
        ZenSpec.unload("modules/filebrowser/patches/kindle_virtual_library")
        local Kindle = require("modules/filebrowser/patches/kindle_virtual_library")

        assert.are.same({
            "/cache/converted.epub",
            "/mnt/us/documents/native.kfx",
        }, Kindle.getBookPaths())
    end)

    it("uses the Kindle catalog metadata and native thumbnail before first open", function()
        local stock_calls, render_calls = 0, 0
        local BookInfoManager = {
            getBookInfo = function()
                stock_calls = stock_calls + 1
                return { stock = true }
            end,
        }
        local source = "/mnt/us/documents/book.kfx"
        ZenSpec.replace("modules/menu/app_launcher/plugin_scan", {})
        ZenSpec.replace("bookinfomanager", BookInfoManager)
        ZenSpec.replace("util", {
            splitFilePathName = function() return "/mnt/us/documents/", "book.kfx" end,
        })
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function() return { size = 42, modification = 7 } end,
        })
        local cover = {
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
        }
        ZenSpec.replace("ui/renderimage", {
            renderImageFile = function(_, path)
                assert.are.equal("/native-cover.jpg", path)
                render_calls = render_calls + 1
                return cover
            end,
        })
        ZenSpec.replace("lua/open_file_ext", {
            virtual_library = {
                getBook = function(_, path)
                    if path == source then
                        return {
                            source_path = source,
                            source_size = 42,
                            cde_key = "B012345678",
                            title = "Catalog Title",
                            authors = { "First Author", "Second Author" },
                        }
                    end
                end,
            },
        })
        ZenSpec.unload("modules/filebrowser/patches/kindle_virtual_library")
        local Kindle = require("modules/filebrowser/patches/kindle_virtual_library")
        Kindle._thumbnailPath = function()
            return "/native-cover.jpg", 600, 800
        end

        assert.is_true(Kindle.installMetadataIntegration())
        local metadata = BookInfoManager:getBookInfo(source, false)
        assert.are.equal("Catalog Title", metadata.title)
        assert.are.equal("First Author\nSecond Author", metadata.authors)
        assert.are.equal("Y", metadata.has_cover)
        assert.are.same({ 600, 800 }, { metadata.cover_w, metadata.cover_h })
        assert.are.equal(0, render_calls)

        local with_cover = BookInfoManager:getBookInfo(source, true)
        assert.are.equal(cover, with_cover.cover_bb)
        assert.are.equal(1, render_calls)
        assert.is_true(BookInfoManager:getBookInfo("/library/normal.epub", true).stock)
        assert.are.equal(1, stock_calls)
    end)

    it("decorates Kindle Library like a regular folder view", function()
        local shown, saved_mode, reopened, updated, status_options
        ZenSpec.replace("modules/menu/app_launcher/plugin_scan", {})
        ZenSpec.replace("common/ui/background", {
            applyToMenu = function(menu) menu.background_applied = true end,
        })
        ZenSpec.replace("modules/filebrowser/patches/standalone_page", {
            hide_page_arrow = function(menu) menu.arrow_hidden = true end,
            suppress_page_info_tap = function(menu) menu.page_info_suppressed = true end,
            apply_status_row = function(_, options) status_options = options end,
        })
        ZenSpec.replace("common/shared_state", {
            get = function(_, key) return key end,
        })
        ZenSpec.replace("device", {
            isTouchDevice = function() return true end,
            screen = { getWidth = function() return 600 end, getHeight = function() return 800 end },
        })
        ZenSpec.replace("ui/geometry", { new = function(_, spec) return spec end })
        ZenSpec.replace("ui/gesturerange", { new = function(_, spec) return spec end })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/widget/buttondialog", { new = function(_, spec) return spec end })
        ZenSpec.replace("ui/uimanager", {
            show = function(_, widget) shown = widget end,
            close = function() end,
        })
        ZenSpec.replace("bookinfomanager", {
            getSetting = function(_, key)
                if key == "filemanager_display_mode" then return "mosaic_image" end
            end,
            saveSetting = function(_, _, mode) saved_mode = mode end,
        })
        ZenSpec.unload("modules/filebrowser/patches/kindle_virtual_library")
        local Kindle = require("modules/filebrowser/patches/kindle_virtual_library")
        local manager = {
            close = function() end,
            show = function(_, _, force)
                reopened = force == false
            end,
        }
        local held
        local menu = {
            name = "kindle_library",
            _manager = manager,
            onMenuHold = function(_, item)
                held = item
                return true
            end,
            updateItems = function(_, page, no_resize)
                updated = { page, no_resize }
            end,
        }

        assert.is_true(Kindle._decorateLibraryView(menu, {}))
        assert.is_true(menu.background_applied)
        assert.is_false(menu._do_center_partial_rows)
        assert.are.same({ 1, true }, updated)
        assert.are.equal("Kindle Library", status_options.label)
        assert.is_nil(status_options.back_callback)
        assert.is_nil(status_options.createStatusRowCustomBack)
        local book = { kindle_book_id = "cc:1" }
        assert.is_true(menu:onMenuHold(book))
        assert.are.equal(book, held)

        assert.is_true(menu.onZenKindleBlankHold())
        assert.are.equal("Display mode", shown.title)
        shown.buttons[3][1].callback()
        assert.are.equal("list_image_filename", saved_mode)
        assert.is_true(reopened)
    end)

    it("hides the up-folder row and turns the title action into folder-up", function()
        local home_locked = false
        local FileChooser = {
            genItemTable = function(self) return self.stock_items end,
        }
        ZenSpec.replace("ui/widget/filechooser", FileChooser)
        ZenSpec.replace("ui/bidi", { mirroredUILayout = function() return false end })
        ZenSpec.replace("common/paths", {
            isHomeRoot = function(path) return path == "/library" end,
            isHomeLocked = function() return home_locked end,
        })
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { browser_hide_up_folder = true },
                browser_hide_up_folder = { hide_up_folder = true },
            },
        }

        apply_patch("modules/filebrowser/patches/browser_hide_up_folder")
        local folder_up_calls = 0
        local button = { setIcon = function(self, icon) self.icon = icon end }
        local chooser = {
            name = "filemanager",
            stock_items = {
                { path = "/library/series/..", text = "\u{2B06} ..", is_go_up = true },
                { path = "/library/series/book.epub", text = "Book" },
            },
            title_bar = {
                left_button = button,
                left_icon_tap_callback = function() return "home" end,
            },
            onFolderUp = function() folder_up_calls = folder_up_calls + 1 end,
        }
        setmetatable(chooser, { __index = FileChooser })

        local items = FileChooser.genItemTable(chooser, {}, {}, "/library/series")
        assert.are.equal(1, #items)
        assert.are.equal("Book", items[1].text)
        assert.are.equal("back.top", button.icon)
        button.callback()
        assert.are.equal(1, folder_up_calls)
    end)

    it("force-hides up-folder at a locked home even when the feature is disabled", function()
        local FileChooser = {
            genItemTable = function(self) return self.stock_items end,
        }
        ZenSpec.replace("ui/widget/filechooser", FileChooser)
        ZenSpec.replace("ui/bidi", { mirroredUILayout = function() return false end })
        ZenSpec.replace("common/paths", {
            isHomeRoot = function() return true end,
            isHomeLocked = function() return true end,
        })
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { browser_hide_up_folder = false },
                browser_hide_up_folder = { hide_up_folder = false },
            },
        }

        apply_patch("modules/filebrowser/patches/browser_hide_up_folder")
        local button = { setIcon = function(self, icon) self.icon = icon end }
        local chooser = {
            name = "filemanager",
            stock_items = {
                { path = "/library/..", text = "\u{2B06} ..", is_go_up = true },
                { path = "/library/book.epub", text = "Book" },
            },
            title_bar = {
                left_button = button,
                left_icon_tap_callback = function() return "home" end,
            },
        }
        setmetatable(chooser, { __index = FileChooser })
        local items = FileChooser.genItemTable(chooser, {}, {}, "/library")
        assert.are.equal(1, #items)
        assert.are.equal("home", button.icon)
    end)

    it("makes every movable container unmovable and consumes drag callbacks", function()
        local init_calls = 0
        local MovableContainer = {
            init = function(self, marker)
                init_calls = init_calls + 1
                return self.unmovable and marker
            end,
            onMovableTouch = function() return "touch" end,
            onMovableSwipe = function() return "swipe" end,
        }
        ZenSpec.replace("ui/widget/container/movablecontainer", MovableContainer)

        apply_patch("modules/filebrowser/patches/disable_modal_drag")
        local frame = { bordersize = 1 }
        local instance = { frame }
        assert.are.equal("initialized", MovableContainer.init(instance, "initialized"))
        assert.is_true(instance.unmovable)
        assert.are.equal(1, init_calls)
        assert.is_nil(MovableContainer.onMovableTouch(instance))
        assert.is_nil(MovableContainer.onMovableSwipe(instance))
        assert.is_nil(MovableContainer.onMovablePanRelease(instance))
    end)

    it("hides separators in non-classic menus and CoverBrowser layouts", function()
        local registered, shared
        local menu_updates, cover_updates = 0, 0
        local Menu = {
            updateItems = function() menu_updates = menu_updates + 1 end,
        }
        local CoverMenu = {
            updateItems = function() cover_updates = cover_updates + 1 end,
        }
        local ListMenuItem = { update = function() end }
        local function list_builder()
            return ListMenuItem
        end
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_BLACK = "black",
            COLOR_WHITE = "white",
        })
        ZenSpec.replace("ui/widget/menu", Menu)
        ZenSpec.replace("covermenu", CoverMenu)
        ZenSpec.replace("mosaicmenu", { _updateItemsBuildUI = function() end })
        ZenSpec.replace("listmenu", { _updateItemsBuildUI = list_builder })
        ZenSpec.replace("common/shared_state", {
            register = function(_, values) shared = values end,
        })
        ZenSpec.replace("userpatch", {
            registerPatchPluginFunc = function(name, callback)
                assert.are.equal("coverbrowser", name)
                registered = callback
            end,
        })
        _G.__ZEN_UI_PLUGIN = { config = {} }

        apply_patch("modules/filebrowser/patches/browser_hide_underline")
        assert.is_true(shared.hide_underline_active)
        assert.is_function(shared.hideMenuUnderlines)
        assert.is_function(registered)
        registered({})

        local hidden = { _underline_container = { color = "black" } }
        Menu.updateItems({ name = "history", layout = { { hidden } } })
        assert.are.equal("white", hidden._underline_container.color)

        local classic = { _underline_container = { color = "black" } }
        Menu.updateItems({ name = "filemanager", layout = { { classic } } })
        assert.are.equal("black", classic._underline_container.color)

        local cover = { _underline_container = { color = "black" } }
        CoverMenu.updateItems({ layout = { { cover } } })
        assert.are.equal("white", cover._underline_container.color)

        local restored = { _underline_container = { color = "black" } }
        shared.hideMenuUnderlines({ layout = { { restored } } })
        assert.are.equal("white", restored._underline_container.color)

        local list_item = { _underline_container = { color = "black" } }
        ListMenuItem.update(list_item)
        assert.are.equal("white", list_item._underline_container.color)
        ListMenuItem.onFocus(list_item)
        assert.are.equal("black", list_item._underline_container.color)
        assert.are.same({ 2, 1 }, { menu_updates, cover_updates })
    end)

    it("avoids repainting one-page menus but delegates multi-page navigation", function()
        local next_calls, previous_calls = 0, 0
        local Menu = {
            onNextPage = function() next_calls = next_calls + 1; return "next" end,
            onPrevPage = function() previous_calls = previous_calls + 1; return "previous" end,
        }
        local FileChooser = { onMenuSelect = function() return "selected" end }
        ZenSpec.replace("ui/widget/menu", Menu)
        ZenSpec.replace("ui/widget/filechooser", FileChooser)

        apply_patch("modules/filebrowser/patches/menu_single_page_scroll_guard")
        assert.is_true(Menu.onNextPage({ page_num = 1 }))
        assert.is_true(Menu.onPrevPage({}))
        assert.are.equal("next", Menu.onNextPage({ page_num = 2 }))
        assert.are.equal("previous", Menu.onPrevPage({ page_num = 3 }))
        assert.are.same({ 1, 1 }, { next_calls, previous_calls })

        _G.__ZEN_QUICKSTART_JUST_CLOSED = true
        assert.is_true(FileChooser.onMenuSelect({}, {}))
        _G.__ZEN_QUICKSTART_JUST_CLOSED = nil
        assert.are.equal("selected", FileChooser.onMenuSelect({}, {}))
    end)

    it("marks new, on-hold, and explicit TBR books as reading", function()
        local statuses = {
            new = "new",
            tbr = "complete",
            abandoned = "abandoned",
            complete = "complete",
        }
        local saved, cached, opened, invalidated = {}, {}, {}, {}
        local tbr_books = { tbr = true }
        local reader_releases = 0
        local filemanagerutil = {
            openFile = function(_, file)
                opened[#opened + 1] = file
                return "opened"
            end,
            saveSummary = function(_, summary)
                saved[#saved + 1] = summary.status
            end,
        }
        ZenSpec.replace("apps/filemanager/filemanagerutil", filemanagerutil)
        ZenSpec.replace("docsettings", {
            open = function(_, file)
                return {
                    readSetting = function() return { status = statuses[file] } end,
                }
            end,
        })
        ZenSpec.replace("ui/widget/booklist", {
            setBookInfoCacheProperty = function(file, key, value)
                cached[#cached + 1] = { file, key, value }
            end,
        })
        ZenSpec.replace("common/book_status", {
            acknowledgeNewVersion = function() return false end,
            invalidate = function(file) invalidated[#invalidated + 1] = file end,
        })
        ZenSpec.replace("common/tbr_index", {
            isExplicit = function(file) return tbr_books[file] == true end,
            setExplicit = function(file, enabled)
                tbr_books[file] = enabled == true
                return true
            end,
            refreshPath = function() end,
        })
        ZenSpec.replace("common/memory_policy", {
            releaseForReader = function() reader_releases = reader_releases + 1 end,
        })

        apply_patch("modules/filebrowser/patches/status_on_open")
        assert.are.equal("opened", filemanagerutil.openFile({}, "new"))
        assert.are.equal("opened", filemanagerutil.openFile({}, "tbr"))
        assert.are.equal("opened", filemanagerutil.openFile({}, "abandoned"))
        assert.are.equal("opened", filemanagerutil.openFile({}, "complete"))
        assert.same({ "reading", "reading", "reading" }, saved)
        assert.same({
            { "new", "status", "reading" },
            { "tbr", "status", "reading" },
            { "abandoned", "status", "reading" },
        }, cached)
        assert.same({ "new", "tbr", "abandoned", "complete" }, opened)
        assert.same({ "new", "tbr", "abandoned" }, invalidated)
        assert.is_false(tbr_books.tbr)
        assert.are.equal(4, reader_releases)
    end)
end)
