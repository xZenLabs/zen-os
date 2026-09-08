describe("folder cover context-menu integration", function()
    local missing = {}
    local saved_modules
    local original_plugin

    local function replace(name, value)
        if saved_modules[name] == nil then
            saved_modules[name] = package.loaded[name] == nil
                and missing or package.loaded[name]
        end
        package.loaded[name] = value
    end

    local function callable_gettext()
        return setmetatable({
            pgettext = function(_context, text) return text end,
        }, {
            __call = function(_self, text) return text end,
        })
    end

    local function widget_class()
        local Widget = {}
        function Widget:new(values)
            values = values or {}
            values.dimen = values.dimen or { w = 10, h = 10 }
            values.paintTo = values.paintTo or function() end
            values.free = values.free or function() end
            return values
        end
        function Widget:extend(values)
            return setmetatable(values or {}, { __index = self })
        end
        return Widget
    end

    local function install_stubs(deps)
        local Widget = widget_class()
        local screen = {
            scaleBySize = function(_self, value) return value end,
            getWidth = function() return 600 end,
            getHeight = function() return 800 end,
        }
        local bidi = {
            auto = function(value) return value end,
            directory = function(value) return value end,
            filename = function(value) return value end,
            filepath = function(value) return value end,
            ltr = function(value) return value end,
            mirroredUILayout = function() return false end,
        }

        replace("ui/bidi", deps.bidi or bidi)
        replace("ui/widget/buttondialog", deps.ButtonDialog or Widget)
        replace("device", deps.Device or {
            screen = screen,
            isTouchDevice = function() return false end,
        })
        replace("ui/widget/filechooser", deps.FileChooser)
        replace("apps/filemanager/filemanager", deps.FileManager)
        replace("ui/widget/pathchooser", deps.PathChooser or Widget)
        replace("ui/uimanager", deps.UIManager or {})
        replace("gettext", callable_gettext())
        replace("common/book_status", {})
        replace("config/manager", deps.ConfigManager or {})
        replace("common/folder_cover_files", deps.Files)
        replace("common/ui/folder_cover_picker", deps.FolderCoverPicker or {
            show = function() end,
        })
        replace("common/paths", deps.paths or {})
        replace("common/shared_state", deps.SharedState or {})
        replace("common/inline_icon_map", {
            arrow_right = ">",
            settings_covers = "covers-icon",
            check = "check-icon",
            filename = "filename-icon",
            details = "details-icon",
            edit = "edit-icon",
            read_status = "status-icon",
            refresh = "refresh-icon",
        })
        replace("common/cover_utils", deps.Cover or {})
        replace("common/zen_logger", deps.zen_logger or {
            new = function()
                return { dbg = function() end, warn = function() end }
            end,
        })
        replace("ffi/util", deps.ffiUtil or {
            realpath = function(path) return path end,
        })
        replace("libs/libkoreader-lfs", deps.lfs or {
            dir = function() return function() end end,
            attributes = function() end,
        })
        replace("document/documentregistry", deps.DocumentRegistry or {})
        replace("readcollection", deps.ReadCollection or {
            coll = {},
            default_collection_name = "Favorites",
        })
        if deps.BookInfoManager then replace("bookinfomanager", deps.BookInfoManager) end
        if deps.BookDetails then
            replace("modules/reader/book_details", deps.BookDetails)
        end
        if deps.MetadataService then
            replace("modules/filebrowser/metadata/service", deps.MetadataService)
        end
        replace("ui/size", {
            border = { window = 1 },
            padding = { button = 1, default = 1 },
            margin = { default = 1 },
        })
        replace("ui/widget/verticalgroup", Widget)
        replace("ui/widget/verticalspan", Widget)
        replace("ui/widget/container/leftcontainer", Widget)
        replace("ui/widget/container/centercontainer", Widget)
        replace("ui/widget/container/framecontainer", Widget)
        replace("ui/widget/horizontalgroup", Widget)
        replace("ui/widget/horizontalspan", Widget)
        replace("ui/widget/imagewidget", Widget)
        replace("ui/widget/container/inputcontainer", Widget)
        replace("ui/gesturerange", Widget)
        replace("ui/widget/textwidget", Widget)
        replace("ui/geometry", Widget)
        replace("ffi/blitbuffer", {
            COLOR_WHITE = 0,
            COLOR_BLACK = 1,
            COLOR_LIGHT_GRAY = 2,
            COLOR_GRAY_3 = 3,
        })
        replace("modules/filebrowser/patches/library_font", {
            scaleValue = function(value) return value end,
            getFontName = function() return "font" end,
            getFace = function() return {} end,
        })
    end

    local function apply_patch()
        local patch_name = "modules/filebrowser/patches/context_menu"
        replace(patch_name, nil)
        require(patch_name)()
    end

    local function find_button(dialog, label)
        for _i, row in ipairs(dialog and dialog.buttons or {}) do
            for _j, button in ipairs(row) do
                if type(button.text) == "string"
                        and button.text:find(label, 1, true) then
                    return button
                end
            end
        end
    end

    before_each(function()
        saved_modules = {}
        original_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        _G.__ZEN_UI_PLUGIN = nil
    end)

    after_each(function()
        for name, value in pairs(saved_modules) do
            if value == missing then
                package.loaded[name] = nil
            else
                package.loaded[name] = value
            end
        end
        _G.__ZEN_UI_PLUGIN = original_plugin
    end)

    it("hides managed cover files only from the file manager", function()
        local stock_calls = {}
        local FileChooser = {
            show_filter = {},
            show_file = function(self, filename, fullpath)
                stock_calls[#stock_calls + 1] = {
                    name = self.name,
                    filename = filename,
                    fullpath = fullpath,
                }
                return "stock"
            end,
        }
        local FileManager = {
            moveFile = function() return true end,
            setupLayout = function() end,
        }

        install_stubs({
            FileChooser = FileChooser,
            FileManager = FileManager,
            Files = {
                isManaged = function(filename)
                    return filename == "cover.jpg" or filename == "COVER4.JPG"
                end,
            },
        })
        apply_patch()

        assert.is_false(FileChooser.show_file(
            { name = "filemanager" }, "cover.jpg", "/library/cover.jpg"))
        assert.is_false(FileChooser.show_file(
            { name = "filemanager" }, "COVER4.JPG", "/library/COVER4.JPG"))
        for _i, name in ipairs({
            "cover.jpeg", "cover1.png", "cover2.webp", "cover3.gif",
        }) do
            assert.are.equal("stock", FileChooser.show_file(
                { name = "filemanager" }, name, "/library/" .. name))
        end
        assert.are.equal("stock", FileChooser.show_file(
            { name = "filemanager" }, "book.epub", "/library/book.epub"))
        assert.are.equal("stock", FileChooser.show_file(
            { name = "pathchooser" }, "cover.jpg", "/library/cover.jpg"))

        assert.are.equal(6, #stock_calls)
        assert.are.equal("cover.jpeg", stock_calls[1].filename)
        assert.are.equal("book.epub", stock_calls[5].filename)
        assert.are.equal("pathchooser", stock_calls[6].name)
    end)

    it("keeps every path chooser traversable without changing its title bar", function()
        local PathChooser = widget_class()
        function PathChooser:init()
            self.title_bar_left_icon = "home"
            self.title_bar = {
                has_left_icon = true,
                left_icon = "home",
                left_button = { icon = "home" },
                right_icon = "close",
                right_button = { icon = "close" },
                clear = function() end,
                init = function(title_bar)
                    title_bar.has_left_icon = title_bar.left_icon ~= nil
                    title_bar.left_button = title_bar.has_left_icon
                        and { icon = title_bar.left_icon } or nil
                    title_bar.right_button = { icon = title_bar.right_icon }
                end,
            }
        end
        function PathChooser:genItemTableFromPath()
            return self.stock_items or {}
        end

        local FileChooser = {
            show_filter = {},
            show_file = function() return true end,
        }
        local FileManager = {
            moveFile = function() return true end,
            setupLayout = function() end,
        }
        install_stubs({
            FileChooser = FileChooser,
            FileManager = FileManager,
            PathChooser = PathChooser,
            Files = { isManaged = function() return false end },
            ffiUtil = {
                realpath = function(path) return path end,
                dirname = function(path)
                    if path == "/" then return path end
                    return path:match("^(.*)/[^/]+$") or "."
                end,
            },
        })
        apply_patch()

        local chooser = { show_current_dir_for_hold = false }
        PathChooser.init(chooser)
        assert.are.equal("home", chooser.title_bar_left_icon)
        assert.is_true(chooser.title_bar.has_left_icon)
        assert.are.equal("home", chooser.title_bar.left_button.icon)
        assert.are.equal("close", chooser.title_bar.right_button.icon)

        local items = PathChooser.genItemTableFromPath(chooser, "/library")
        assert.is_true(items[1].is_go_up)
        assert.are.equal("/library/..", items[1].path)

        chooser.show_current_dir_for_hold = true
        chooser.stock_items = { { path = "/library/." } }
        items = PathChooser.genItemTableFromPath(chooser, "/library")
        assert.are.equal("/library/.", items[1].path)
        assert.is_true(items[2].is_go_up)

        chooser.stock_items = { { is_go_up = true, path = "/library/.." } }
        items = PathChooser.genItemTableFromPath(chooser, "/library")
        assert.are.equal(1, #items)
        chooser.stock_items = {}
        assert.are.equal(0, #PathChooser.genItemTableFromPath(chooser, "/"))
    end)

    it("keeps a configured cover reference aligned when its image moves", function()
        local migrations = {}
        local FileChooser = {
            show_filter = {},
            show_file = function() return true end,
        }
        local FileManager = {
            moveFile = function() return true end,
            setupLayout = function() end,
        }

        install_stubs({
            FileChooser = FileChooser,
            FileManager = FileManager,
            Files = { isManaged = function() return false end },
            ConfigManager = {
                movePathSettings = function(from, to)
                    migrations[#migrations + 1] = { from, to }
                end,
            },
            UIManager = {
                nextTick = function(_self, callback) callback() end,
            },
            SharedState = { get = function() end },
            ffiUtil = {
                realpath = function(path) return path end,
                basename = function(path) return path:match("([^/]+)$") end,
                joinPath = function(parent, name) return parent .. "/" .. name end,
            },
            lfs = {
                dir = function() return function() end end,
                attributes = function(path, field)
                    if path == "/artwork" and field == "mode" then
                        return "directory"
                    end
                end,
            },
        })
        apply_patch()

        assert.is_true(FileManager.moveFile(
            {}, "/images/cover3.jpg", "/artwork"))
        assert.are.same({
            { "/images/cover3.jpg", "/artwork/cover3.jpg" },
        }, migrations)
    end)

    it("builds mode-aware slots and refreshes a folder after selection", function()
        local current_mode = "normal"
        local shown = {}
        local shown_modes = {}
        local closed = {}
        local chooser_specs = {}
        local picker_specs = {}
        local set_calls = {}
        local clear_calls = {}
        local invalidated = {}
        local sorting_clears = 0
        local updates = 0
        local refreshes = 0
        local library_invalidations = 0
        local home_rebuilds = 0

        local FileChooser = {
            show_filter = {},
            show_file = function() return true end,
        }
        local file_chooser = {
            name = "filemanager",
            path = "/library",
            display_mode_type = "mosaic",
            _zen_file_cover_specs = {
                max_cover_w = 118,
                max_cover_h = 176,
                uniform = false,
            },
            nb_cols_portrait = 3,
            nb_rows_portrait = 3,
            nb_cols_landscape = 4,
            nb_rows_landscape = 2,
            showFileDialog = function() return "stock" end,
            _zen_invalidate_item_table_path = function(_self, path)
                invalidated[#invalidated + 1] = path
            end,
            clearSortingCache = function()
                sorting_clears = sorting_clears + 1
            end,
            updateItems = function()
                updates = updates + 1
            end,
            refreshPath = function()
                refreshes = refreshes + 1
            end,
        }
        local FileManager = {
            moveFile = function() return true end,
            setupLayout = function() end,
        }
        local file_manager = {
            file_chooser = file_chooser,
            cutFile = function() end,
            copyFile = function() end,
            onToggleSelectMode = function() end,
        }
        FileManager.instance = file_manager

        local PathChooser = widget_class()
        function PathChooser:new(values)
            chooser_specs[#chooser_specs + 1] = values
            return values
        end

        local UIManager = {
            show = function(_self, widget, mode)
                shown[#shown + 1] = widget
                shown_modes[#shown_modes + 1] = mode
            end,
            close = function(_self, widget)
                closed[#closed + 1] = widget
            end,
            nextTick = function(_self, callback) callback() end,
        }
        local home = {
            invalidateLibraryCache = function()
                library_invalidations = library_invalidations + 1
            end,
            rebuildActive = function()
                home_rebuilds = home_rebuilds + 1
            end,
        }
        local Files = {
            isManaged = function() return false end,
            isSupportedImage = function(filename)
                return filename:lower():match("%.jpg$") ~= nil
            end,
            slotCount = function(mode)
                if mode == "gallery" or mode == "stack" then return 4 end
                if mode == "none" then return 0 end
                return 1
            end,
            find = function(_folder, mode)
                if mode == "gallery" or mode == "stack" then
                    return {
                        [1] = "/images/first.jpg",
                        [3] = "/images/third.jpg",
                    }
                end
                return { [1] = "/images/first.jpg" }
            end,
            set = function(folder, mode, slot, source)
                set_calls[#set_calls + 1] = {
                    folder = folder,
                    mode = mode,
                    slot = slot,
                    source = source,
                }
                return source
            end,
            clear = function(folder, mode, slot)
                clear_calls[#clear_calls + 1] = {
                    folder = folder,
                    mode = mode,
                    slot = slot,
                }
                return true
            end,
        }
        local Cover = {
            BORDER_SIZE = 1,
            getMode = function() return current_mode end,
            getRatio = function() return 2 / 3 end,
            makeCover = function()
                return { dimen = { w = 90, h = 140 }, paintTo = function() end }
            end,
        }
        local DocumentRegistry = {
            hasProvider = function() return false end,
            isImageFile = function(_self, filename)
                return filename:lower():match("%.jpg$") ~= nil
            end,
        }
        local FolderCoverPicker = {
            show = function(options)
                picker_specs[#picker_specs + 1] = options
                return options
            end,
        }

        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { browser_cover_mosaic_uniform = true },
                context_menu = { allow_delete = false },
            },
        }
        install_stubs({
            FileChooser = FileChooser,
            FileManager = FileManager,
            PathChooser = PathChooser,
            UIManager = UIManager,
            Files = Files,
            FolderCoverPicker = FolderCoverPicker,
            Cover = Cover,
            DocumentRegistry = DocumentRegistry,
            paths = {
                getHomeDir = function() return "/library" end,
                isInHomeDir = function() return true end,
                isHomeRoot = function() return false end,
                isPrimaryHomeRoot = function() return false end,
            },
            SharedState = {
                get = function() return home end,
            },
        })
        apply_patch()
        FileManager.setupLayout(file_manager)

        current_mode = "none"
        file_chooser:showFileDialog({
            path = "/library/series",
            is_file = false,
            text = "Series",
        })
        assert(find_button(shown[#shown], "Edit")).callback()
        assert.is_nil(find_button(shown[#shown], "Set folder cover"))

        local cases = {
            { mode = "normal", slots = 1 },
            { mode = "gallery", slots = 4 },
            { mode = "stack", slots = 4 },
        }
        for _i, case in ipairs(cases) do
            current_mode = case.mode
            shown = {}
            shown_modes = {}
            closed = {}
            chooser_specs = {}

            file_chooser:showFileDialog({
                path = "/library/series",
                is_file = false,
                text = "Series",
            })
            local edit = assert(find_button(shown[#shown], "Edit"))
            edit.callback()
            local set_cover = assert(find_button(shown[#shown], "Set folder cover"))
            set_cover.callback()

            local picker = picker_specs[#picker_specs]
            assert.are.equal("Set folder cover", picker.title)
            assert.are.equal("/library/series", picker.path)
            assert.are.equal(case.slots, picker.slot_count)
            assert.are.equal(2 / 3, picker.cover_ratio)
            assert.are.equal(1, picker.border)
            assert.is_false(picker.uniform)
            assert.are.equal(118, picker.mosaic_cover_width)
            assert.are.equal(176, picker.mosaic_cover_height)
            assert.is_true(picker.mosaic_portrait)
            assert.are.equal(3, picker.mosaic_cols_portrait)
            assert.are.equal(3, picker.mosaic_rows_portrait)
            assert.are.equal(4, picker.mosaic_cols_landscape)
            assert.are.equal(2, picker.mosaic_rows_landscape)
            assert.are.equal("/images/first.jpg", picker.covers[1])
            if case.slots == 4 then
                assert.is_nil(picker.covers[2])
                assert.are.equal("/images/third.jpg", picker.covers[3])
            end

            local preview_updates = {}
            local closes_before_chooser = #closed
            picker.on_select(case.slots, function(path)
                preview_updates[#preview_updates + 1] = { path = path }
            end)
            local chooser = chooser_specs[#chooser_specs]
            assert.is_table(chooser)
            assert.are.equal(closes_before_chooser, #closed)
            assert.are.equal("full", shown_modes[#shown_modes])
            assert.is_false(chooser.select_directory)
            assert.is_true(chooser.select_file)
            assert.is_true(chooser.show_files)
            assert.are.equal("/library/series", chooser.path)
            assert.is_true(chooser.file_filter("poster.jpg"))
            assert.is_true(chooser.file_filter("poster.JPG"))
            assert.is_false(chooser.file_filter("poster.jpeg"))
            assert.is_false(chooser.file_filter("poster.png"))
            assert.is_false(chooser.file_filter("poster.webp"))
            assert.is_false(chooser.file_filter("poster.gif"))
            assert.is_false(chooser.file_filter("poster.svg"))
            assert.is_false(chooser.file_filter("book.epub"))

            chooser.onConfirm("/images/chosen.jpg")
            local call = set_calls[#set_calls]
            assert.are.same({
                folder = "/library/series",
                mode = case.mode,
                slot = case.slots,
                source = "/images/chosen.jpg",
            }, call)
            assert.are.same({ { path = "/images/chosen.jpg" } }, preview_updates)
            assert.are.equal("/library/series", invalidated[#invalidated])

            local chooser_count = #chooser_specs
            local clear_updates = {}
            picker.on_clear(1, function(path)
                clear_updates[#clear_updates + 1] = { path = path }
            end)
            assert.are.equal(chooser_count, #chooser_specs)
            assert.are.same({ { path = nil } }, clear_updates)
            assert.are.same({
                folder = "/library/series",
                mode = case.mode,
                slot = 1,
            }, clear_calls[#clear_calls])
            assert.are.equal("/library/series", invalidated[#invalidated])
        end

        assert.are.equal(6, sorting_clears)
        assert.are.equal(6, updates)
        assert.are.equal(0, refreshes)
        assert.are.equal(6, library_invalidations)
        assert.are.equal(6, home_rebuilds)
    end)

    it("places metadata editing above Delete in the Edit submenu", function()
        local shown = {}
        local details_options
        local editor_options
        local refreshed = {}
        local FileChooser = {
            show_filter = {},
            show_file = function() return true end,
        }
        local file_chooser = {
            name = "filemanager",
            path = "/library",
            showFileDialog = function() return "stock" end,
            refreshPath = function() end,
        }
        local FileManager = {
            moveFile = function() return true end,
            setupLayout = function() end,
        }
        local bookinfo = {
            showFromBookDetails = function(_self, file, _props, options)
                assert.are.equal("/library/book.epub", file)
                editor_options = options
            end,
        }
        local file_manager = {
            file_chooser = file_chooser,
            bookinfo = bookinfo,
        }
        FileManager.instance = file_manager
        _G.__ZEN_UI_PLUGIN = {
            config = { context_menu = { allow_delete = true } },
        }

        install_stubs({
            FileChooser = FileChooser,
            FileManager = FileManager,
            Files = { isManaged = function() return false end },
            UIManager = {
                show = function(_self, widget) shown[#shown + 1] = widget end,
                close = function() end,
                nextTick = function(_self, callback) callback() end,
            },
            Cover = {
                BORDER_SIZE = 1,
                getRatio = function() return 2 / 3 end,
                makeCover = function()
                    return { free = function() end }, 80, 120
                end,
            },
            BookInfoManager = {
                getBookInfo = function()
                    return { title = "Book", authors = "Author" }
                end,
            },
            BookDetails = {
                showFile = function(_file, options) details_options = options end,
            },
            MetadataService = {
                refreshLibrary = function(_file_manager, file)
                    refreshed[#refreshed + 1] = file
                end,
            },
            paths = {
                getHomeDir = function() return "/library" end,
                isInHomeDir = function() return true end,
                isHomeRoot = function() return false end,
                isPrimaryHomeRoot = function() return false end,
            },
        })
        apply_patch()
        FileManager.setupLayout(file_manager)

        file_chooser:showFileDialog({
            path = "/library/book.epub",
            is_file = true,
            _zen_collection_name = "Test",
        })
        local dialog = shown[#shown]
        assert(find_button(dialog, "Details")).callback()
        assert.is_nil(details_options.edit_callback)
        assert.is_false(details_options.home_context)
        assert.are.equal(_G.__ZEN_UI_PLUGIN, details_options.plugin)
        assert.is_nil(find_button(dialog, "Edit metadata"))

        assert(find_button(dialog, "Edit")).callback()
        local edit_dialog = shown[#shown]
        assert.matches("Edit metadata", edit_dialog.buttons[#edit_dialog.buttons - 1][1].text,
            1, true)
        assert.matches("Delete", edit_dialog.buttons[#edit_dialog.buttons][1].text, 1, true)
        assert(find_button(edit_dialog, "Edit metadata")).callback()
        assert.is_table(editor_options)
        editor_options.on_renamed("/library/renamed.epub")
        editor_options.on_saved("/library/renamed.epub")
        editor_options.on_restored("/library/renamed.epub")
        assert.are.same({
            "/library/renamed.epub",
            "/library/renamed.epub",
            "/library/renamed.epub",
        }, refreshed)
    end)
end)
