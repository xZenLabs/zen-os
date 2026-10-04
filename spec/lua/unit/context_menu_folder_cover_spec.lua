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
        replace("common/archive_actions", deps.ArchiveActions or {
            contextRow = function() end,
        })
        replace("common/book_status", deps.BookStatus or {})
        replace("config/manager", deps.ConfigManager or {})
        replace("common/folder_cover_files", deps.Files)
        replace("common/ui/folder_cover_picker", deps.FolderCoverPicker or {
            show = function() end,
        })
        local paths = deps.paths or {}
        paths.isInThemedDir = paths.isInThemedDir or paths.isInHomeDir
        replace("common/paths", paths)
        replace("common/shared_state", deps.SharedState or {})
        replace("common/inline_icon_map", {
            arrow_right = ">",
            settings_covers = "covers-icon",
            check = "check-icon",
            filename = "filename-icon",
            details = "details-icon",
            edit = "edit-icon",
            more = "more-icon",
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

    local function has_widget_text(widget, text)
        if type(widget) ~= "table" then return false end
        if widget.text == text then return true end
        for _i, child in ipairs(widget) do
            if has_widget_text(child, text) then return true end
        end
        return false
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

    it("hides regular folders without books matching the status filter", function()
        local empty = { mandatory = "2 \u{F114} 0 \u{F016}" }
        local matching = { mandatory = "1 \u{F016}" }
        local FileChooser = {
            show_filter = { status = { complete = true } },
            show_file = function() return true end,
            getList = function()
                return { empty, matching }, { "finished.epub" }
            end,
        }
        local FileManager = {
            moveFile = function() return true end,
            setupLayout = function() end,
        }

        install_stubs({
            FileChooser = FileChooser,
            FileManager = FileManager,
            Files = { isManaged = function() return false end },
        })
        apply_patch()

        local dirs, files = FileChooser.getList({ name = "filemanager" }, "/library", {})
        assert.are.same({ matching }, dirs)
        assert.are.same({ "finished.epub" }, files)

        dirs = FileChooser.getList({ name = "pathchooser" }, "/library", {})
        assert.are.same({ empty, matching }, dirs)
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

    it("flashes only the painted context-menu cover and skips closed dialogs", function()
        local scheduled, flashes = {}, {}
        local top_widget
        local opening_calls = 0
        local ButtonDialog = widget_class()
        function ButtonDialog:new(options)
            options.onShow = function() opening_calls = opening_calls + 1 end
            return options
        end
        local FileManager = { setupLayout = function() end, moveFile = function() end }
        local chooser = { path = "/library", showFileDialog = function() end }
        local fm = { file_chooser = chooser }
        FileManager.instance = fm
        install_stubs({
            ButtonDialog = ButtonDialog,
            FileChooser = { show_filter = {}, show_file = function() return true end },
            FileManager = FileManager,
            Files = { isManaged = function() return false end },
            UIManager = {
                show = function(_self, widget)
                    top_widget = widget
                    widget:onShow()
                end,
                tickAfterNext = function(_self, callback) scheduled[#scheduled + 1] = callback end,
                getTopmostVisibleWidget = function() return top_widget end,
                setDirty = function(_self, widget, mode, region, dither)
                    flashes[#flashes + 1] = {
                        widget = widget, mode = mode, region = region, dither = dither,
                    }
                end,
            },
            Cover = {
                BORDER_SIZE = 1,
                getRatio = function() return 2 / 3 end,
                makeCover = function() return { paintTo = function() end }, 80, 120 end,
            },
            BookInfoManager = { getBookInfo = function() return { title = "Book", pages = 100 } end },
            paths = {
                getHomeDir = function() return "/library" end,
                isInHomeDir = function() return true end,
                isHomeRoot = function() return false end,
                isPrimaryHomeRoot = function() return false end,
            },
        })
        apply_patch()
        FileManager.setupLayout(fm)

        local items = {
            { path = "/library/book.epub", is_file = true, _zen_collection_name = "Test" },
            { path = "/library/folder", is_file = false },
            { _zen_group_files = { "/library/book.epub" }, _zen_group_name = "Group" },
        }
        for index, item in ipairs(items) do
            chooser:showFileDialog(item)
            assert.are.equal(index, opening_calls)
            assert.are.equal(index, #scheduled)
            assert.are.equal(index - 1, #flashes)
            local cover = top_widget._added_widgets[1][1][1]
            cover.dimen = { x = 100, y = 200, w = 80, h = 120 }
            scheduled[index]()
            assert.are.same({ mode = "full", region = cover.dimen, dither = true }, flashes[index])
        end

        top_widget:onShow()
        top_widget = nil
        scheduled[#scheduled]()
        assert.are.equal(3, #flashes)
        chooser:showSortOrderDialog({ title = "Sort order" })
        assert.are.equal(4, #scheduled)
    end)

    it("keeps inline icons in plugin actions and preserves Edit ordering", function()
        local shown = {}
        local details_options
        local editor_options
        local editor_file
        local plugin_args
        local plugin_action_called = false
        local refresh_action_built = false
        local refreshed = {}
        local deleted_bookinfo
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
            file_dialog_added_buttons = {
                function()
                    refresh_action_built = true
                    return {{ text = "Refresh cached book information" }}
                end,
                function(file, is_file, book_props)
                    plugin_args = { file, is_file, book_props }
                    return {
                        {
                            text = "\u{F05F9}  Incognito",
                            icon = "plugin.svg",
                            callback = function() plugin_action_called = true end,
                        },
                        {
                            text_func = function() return "\u{F140B}  Dynamic action" end,
                        },
                        { text = "\u{F048A}  ZenFM Send" },
                    }
                end,
                function() error("broken plugin") end,
                index = { coverbrowser_2 = 1 },
            },
        }
        local bookinfo = {
            showFromBookDetails = function(_self, file, _props, options)
                editor_file = file
                editor_options = options
            end,
        }
        local file_manager = {
            file_chooser = file_chooser,
            bookinfo = bookinfo,
        }
        FileManager.instance = file_manager
        local context_menu_config = { allow_delete = true }
        _G.__ZEN_UI_PLUGIN = {
            config = { context_menu = context_menu_config },
        }

        local ButtonDialog = widget_class()
        function ButtonDialog:new(options)
            options.buttontable = { buttons_layout = options.buttons }
            for _i, row in ipairs(options.buttons) do
                for _j, button in ipairs(row) do
                    button.text = button.text_func and button.text_func() or button.text
                    button.label_widget = { face = {}, free = function() end }
                    button.label_container = { dimen = { w = 400, h = 40 } }
                end
            end
            return options
        end

        install_stubs({
            ButtonDialog = ButtonDialog,
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
                deleteBookInfo = function(_, file) deleted_bookinfo = file end,
            },
            BookDetails = {
                showFile = function(_file, options) details_options = options end,
            },
            MetadataService = {
                refreshLibrary = function(_file_manager, file)
                    refreshed[#refreshed + 1] = file
                end,
            },
            SharedState = { get = function() end },
            ArchiveActions = {
                contextRow = function()
                    return {{ text = "\u{F19C}  Archive" }}
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
        assert.is_nil(find_button(dialog, "Archive"))
        assert.is_nil(find_button(dialog, "More"))
        assert.is_nil(plugin_args)

        context_menu_config.show_archive = true
        context_menu_config.show_plugin_actions = true
        file_chooser:showFileDialog({
            path = "/library/book.epub",
            is_file = true,
            _zen_collection_name = "Test",
        })
        dialog = shown[#shown]
        assert.matches("\u{F19C}", assert(find_button(dialog, "Archive")).text, 1, true)
        local more = assert(find_button(dialog, "More"))
        assert.matches("more-icon", more.text, 1, true)
        more.callback()
        local more_dialog = shown[#shown]
        assert.is_false(refresh_action_built)
        assert.is_nil(find_button(more_dialog, "Refresh cached book information"))
        assert.are.equal("/library/book.epub", plugin_args[1])
        assert.is_true(plugin_args[2])
        assert.are.equal("Book", plugin_args[3].title)
        assert.are.equal(3, #more_dialog.buttons)
        assert.are.equal(1, #more_dialog.buttons[1])
        assert.are.equal(1, #more_dialog.buttons[2])
        assert.are.equal("\u{F05F9}  Incognito", more_dialog.buttons[1][1].text)
        assert.are.equal("Incognito", more_dialog.buttons[1][1].label_widget.text)
        assert.is_true(has_widget_text(more_dialog.buttons[1][1].label_container, "\u{F05F9}"))
        assert.is_nil(more_dialog.buttons[1][1].icon)
        assert.are.equal("left", more_dialog.buttons[1][1].align)
        assert.are.equal("\u{F140B}  Dynamic action", more_dialog.buttons[2][1].text_func())
        assert.are.equal("Dynamic action", more_dialog.buttons[2][1].label_widget.text)
        assert.is_true(has_widget_text(more_dialog.buttons[2][1].label_container, "\u{F140B}"))
        assert.are.equal("ZenFM Send", more_dialog.buttons[3][1].label_widget.text)
        assert.is_true(has_widget_text(more_dialog.buttons[3][1].label_container, "\u{F048A}"))
        assert(find_button(more_dialog, "Incognito")).callback()
        assert.is_true(plugin_action_called)

        file_chooser:showFileDialog({
            path = "/library/book.epub",
            is_file = true,
            _zen_collection_name = "Test",
        })
        dialog = shown[#shown]
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
        assert.are.equal("/library/book.epub", editor_file)
        assert.is_table(editor_options)
        editor_options.on_renamed("/library/renamed.epub")
        editor_options.on_saved("/library/renamed.epub")
        editor_options.on_restored("/library/renamed.epub")
        assert.are.same({
            "/library/renamed.epub",
            "/library/renamed.epub",
            "/library/renamed.epub",
        }, refreshed)

        local kindle_refreshes = 0
        file_chooser:showFileDialog({
            path = "/mnt/us/documents/kindle.kfx",
            is_file = true,
            _zen_home_context = true,
            _zen_kindle_book = true,
        })
        assert.is_nil(find_button(shown[#shown], "Edit"))

        file_chooser:showFileDialog({
            path = "/cache/kindle.epub",
            is_file = true,
            _zen_home_context = true,
            _zen_kindle_book = true,
            _zen_kindle_processed = true,
            _zen_refresh = function() kindle_refreshes = kindle_refreshes + 1 end,
            _zen_extra_buttons = { {{ text = "Clear cache" }} },
        })
        local kindle_dialog = shown[#shown]
        assert.is_true(has_widget_text(kindle_dialog._added_widgets[1], "Kindle Library"))
        assert.is_truthy(find_button(kindle_dialog, "Details"))
        assert.is_truthy(find_button(kindle_dialog, "Read status"))
        assert.is_truthy(find_button(kindle_dialog, "Clear cache"))
        assert.is_truthy(find_button(kindle_dialog, "Add to collection"))
        assert(find_button(kindle_dialog, "Edit")).callback()
        local kindle_edit_dialog = shown[#shown]
        assert.are.equal(2, #kindle_edit_dialog.buttons)
        assert.is_nil(find_button(kindle_edit_dialog, "Cut"))
        assert.is_nil(find_button(kindle_edit_dialog, "Copy"))
        assert.is_nil(find_button(kindle_edit_dialog, "Paste"))
        assert.is_nil(find_button(kindle_edit_dialog, "Delete"))
        assert(find_button(kindle_edit_dialog, "Refresh")).callback()
        assert.are.equal("/cache/kindle.epub", deleted_bookinfo)
        assert(find_button(kindle_edit_dialog, "Edit metadata")).callback()
        assert.are.equal("/cache/kindle.epub", editor_file)
        assert.is_table(editor_options)
        editor_options.on_saved("/cache/kindle.epub")
        assert.are.equal("/cache/kindle.epub", refreshed[#refreshed])
        find_button(kindle_dialog, "Refresh").callback()
        assert.are.equal(1, kindle_refreshes)
    end)

    it("keeps selected copy pending and moves selected files through the directory chooser", function()
        local shown, pasted = {}, {}
        local tree = {
            ["/"] = { "home", "etc", "proc", "mnt", "library" },
            ["/home"] = { "user" }, ["/home/user"] = {},
            ["/etc"] = {}, ["/proc"] = {},
            ["/mnt"] = { "us" }, ["/mnt/us"] = {},
            ["/library"] = { "home", "proc", "notes.sdr", "outside_link", "target" },
            ["/library/home"] = {}, ["/library/proc"] = {},
            ["/library/notes.sdr"] = {}, ["/library/target"] = {},
            ["/library/outside_link"] = {},
            ["/library/extra"] = {},
            ["/external/books"] = { "novels" }, ["/external/books/novels"] = {},
        }
        local preview, preview_entries, preview_options = {}, nil, nil
        local decorated_cover
        local skip_second = false
        local summaries, added = {}, {}
        local chooser = {
            path = "/library",
            showFileDialog = function() end,
            refreshPath = function() end,
            changeToPath = function(self, path) self.path = path end,
            onFileSelect = function() error("unexpected selection fallback") end,
        }
        local FileChooser = { show_filter = {}, show_file = function() return true end }
        local PathChooser = widget_class()
        function PathChooser:new(values)
            return setmetatable(values, { __index = self })
        end
        function PathChooser:getMenuItemMandatory() end
        function PathChooser:show_dir() return true end
        function PathChooser:changeToPath(path) self.path = path end
        local FileManager = {
            setupLayout = function() end,
            moveFile = function() return true end,
            copyFile = function(self, file) self.clipboard = file end,
            cutFile = function(self, file) self.clipboard = file end,
        }
        local fm = setmetatable({ file_chooser = chooser }, { __index = FileManager })
        FileManager.instance = fm
        function fm:onToggleSelectMode()
            if self.selected_files then self.selected_files = nil
            else self.selected_files = {} end
        end
        function fm:pasteSelectedFiles(overwrite, folder)
            pasted[#pasted + 1] = {
                files = {
                    ["/library/a.epub"] = self.selected_files["/library/a.epub"],
                    ["/library/b.epub"] = self.selected_files["/library/b.epub"],
                },
                cut = self.cutfile,
                overwrite = overwrite,
                folder = folder,
            }
            if skip_second then
                self.selected_files["/library/a.epub"] = nil
            else
                for file in pairs(self.selected_files) do self.selected_files[file] = nil end
                self:onToggleSelectMode()
            end
        end
        install_stubs({
            FileChooser = FileChooser,
            FileManager = FileManager,
            PathChooser = PathChooser,
            Files = { isManaged = function() return false end, slotCount = function() return 0 end },
            Cover = {
                BORDER_SIZE = 1,
                getMode = function() return "none" end,
                getRatio = function() return 3 / 4 end,
                makeCover = function(path, fake_chooser, options)
                    preview_entries = fake_chooser:genItemTableFromPath(path)
                    preview_options = options
                    return preview
                end,
            },
            paths = {
                getHomeDir = function() return "/library" end,
                isInThemedDir = function() return true end,
                isHomeRoot = function() return false end,
                isPrimaryHomeRoot = function() return false end,
            },
            ConfigManager = { get = function()
                return { additional_home_dirs = { "/library/extra", "/external/books" } }
            end },
            ffiUtil = {
                realpath = function(path)
                    if path == "/library/outside_link" then return "/etc" end
                    return path
                end,
                basename = function(path) return path:match("([^/]+)$") end,
                dirname = function(path)
                    local parent = path:match("^(.*)/[^/]+$")
                    return parent and parent ~= "" and parent or "/"
                end,
                strcoll = function(a, b) return a < b end,
                template = function(str, value) return str:gsub("%%1", tostring(value)) end,
            },
            UIManager = {
                show = function(_self, widget) shown[#shown + 1] = widget end,
                close = function() end,
                setDirty = function() end,
            },
            SharedState = { get = function() end },
            lfs = {
                dir = function(path)
                    local entries, index = tree[path] or {}, 0
                    return function()
                        index = index + 1
                        return entries[index]
                    end
                end,
                attributes = function(path, field)
                    if tree[path] and field == "mode" then
                        return "directory"
                    end
                end,
            },
            BookStatus = { acknowledgeNewVersion = function() end, invalidate = function() end },
            ReadCollection = {
                coll = { Favorites = {} },
                default_collection_name = "Favorites",
                isFileInCollection = function() return false end,
                addItemsMultiple = function(_self, files)
                    for file in pairs(files) do added[file] = true end
                end,
                write = function() end,
            },
        })
        replace("common/utils", { resolveLocalIcon = function(_dir, name) return name end })
        replace("modules/filebrowser/patches/home/widgets/cover_common", {
            decorate_cover_frame = function(frame)
                decorated_cover = frame
                return frame
            end,
        })
        replace("common/inline_icon_map", {
            copy = "copy", move = "move", delete = "delete", clear = "clear",
            read_status = "status", status = "unread", reading = "reading",
            tbr = "tbr", on_hold = "on hold", finished = "finished",
            arrow_right = ">",
        })
        local BookList = widget_class()
        BookList.setBookInfoCacheProperty = function() end
        replace("ui/widget/booklist", BookList)
        replace("ui/widget/menu", widget_class())
        replace("ui/widget/titlebar", widget_class())
        replace("docsettings", {
            open = function(_self, file)
                return {
                    file = file,
                    readSetting = function() return {} end,
                    delSetting = function() end,
                }
            end,
        })
        replace("apps/filemanager/filemanagerutil", {
            saveSummary = function(doc, summary) summaries[doc.file] = summary.status end,
        })
        replace("common/tbr_index", {
            collectionName = function() return "To Be Read" end,
            setExplicit = function() end,
            refreshPath = function() end,
            collectionChanged = function() end,
        })
        replace("modules/filebrowser/patches/standalone_page", {
            apply_background = function() end,
        })
        replace("ui/widget/confirmbox", {
            new = function(_class, spec)
                spec.addWidget = function() end
                return spec
            end,
        })
        replace("ui/widget/checkbutton", widget_class())
        _G.__ZEN_UI_PLUGIN = {
            config = {
                context_menu = { allow_delete = true },
                features = { browser_cover_rounded_corners = true },
                uniform_cover_ratio = "3:4",
            },
        }
        apply_patch()
        fm:setupLayout()

        local selected_item = { path = "/library/a.epub", is_file = true }
        local cover = {}
        local widget = {
            entry = selected_item, _zen_cover_frame = cover, dimen = {},
            update = function() error("mosaic selection rebuilt the cover") end,
        }
        chooser.layout = { { widget } }
        fm.selected_files = {}
        assert.is_true(chooser:onFileSelect(selected_item))
        assert.is_nil(cover.dim)
        assert.are.equal(cover, widget._zen_cover_frame)
        assert.is_true(chooser:onFileSelect(selected_item))
        assert.is_nil(cover.dim)

        do
            fm.selected_files = { ["/library/a.epub"] = true, ["/library/b.epub"] = true }
            fm:onShowPlusMenu()
            local header_row = shown[#shown]._added_widgets[1][1]
            assert.is_nil(shown[#shown].title)
            assert.is_nil(shown[#shown].item_table)
            assert.are.equal(preview, header_row[1])
            assert.are.equal("2 files", header_row[3][1].text)
            assert.is_true(preview_options.is_folder)
            assert.are.equal(105, preview_options.max_w)
            assert.are.equal(preview, decorated_cover)
            assert.are.same({ "/library/a.epub", "/library/b.epub" },
                { preview_entries[1].path, preview_entries[2].path })
            assert.is_true(find_button(shown[#shown], "Delete").enabled)
            assert.is_truthy(find_button(shown[#shown], "Read status"))
            assert.is_truthy(find_button(shown[#shown], "Add to collection"))
            assert.is_truthy(find_button(shown[#shown], "Exit select mode"))
            assert(find_button(shown[#shown], "Copy")).callback()
            assert.is_nil(fm.selected_files)
            assert.is_true(fm._zen_selected_clipboard.files["/library/a.epub"])
            chooser:changeToPath("/library/target")
            fm:pasteSelectedFilesFromZenClipboard(chooser.path)
            shown[#shown].ok_callback()
            assert.are.same({
                files = { ["/library/a.epub"] = true, ["/library/b.epub"] = true },
                cut = false,
                overwrite = false,
                folder = "/library/target",
            }, pasted[#pasted])
            assert.is_nil(fm._zen_selected_clipboard)
        end

        fm.selected_files = {}
        assert.is_true(chooser:onFileSelect(selected_item))
        fm.selected_files["/library/b.epub"] = true
        fm:onShowPlusMenu()
        assert(find_button(shown[#shown], "Move")).callback()
        local destination_chooser = shown[#shown]
        assert.is_true(destination_chooser.select_directory)
        assert.are.equal("/library", destination_chooser.path)
        assert.are.same({ "/library/extra", "/external/books" }, destination_chooser.extra_roots)
        assert.are.equal("/library", destination_chooser.home_root)
        table.insert(destination_chooser.extra_roots, "")
        assert.is_true(fm.selected_files["/library/a.epub"])
        assert.is_nil(cover.dim)
        assert.are.equal(cover, widget._zen_cover_frame)
        assert.is_nil(fm._zen_selected_clipboard)
        assert.are.equal(1, #pasted)
        local destinations = destination_chooser:genItemTableFromPath("/library")
        assert.is_nil(destinations[1].is_go_up)
        assert.are.equal("/library", destinations[1].path)
        local listed = {}
        for _i, entry in ipairs(destinations) do listed[entry.path] = true end
        assert.is_true(listed["/library/home"])
        assert.is_true(listed["/external/books"])
        assert.is_true(listed["/external/books/novels"])
        assert.is_nil(listed["/library/proc"])
        assert.is_nil(listed["/library/notes.sdr"])
        assert.is_nil(listed["/library/outside_link"])
        assert.are.same({}, destination_chooser:genItemTableFromPath("/"))
        assert.are.same({}, destination_chooser:genItemTableFromPath("/home"))
        destination_chooser:onMenuSelect({ path = "/" })
        destination_chooser:onMenuSelect({ path = "/library/outside_link" })
        destination_chooser:changeToPath("/")
        assert.are.equal("/library", destination_chooser.path)
        destination_chooser:onMenuHold({ path = "/external/books" })
        assert.are.equal("/external/books", destination_chooser.path)
        local external = destination_chooser:genItemTableFromPath("/external/books")
        assert.is_nil(external[1].is_go_up)
        listed = {}
        for _i, entry in ipairs(external) do listed[entry.path] = entry end
        assert.is_true(listed["/library"].is_go_up)
        destination_chooser:onMenuHold({ path = "/external/books/novels" })
        assert.are.equal("/external/books/novels", destination_chooser.path)
        destination_chooser:onMenuSelect(listed["/library"])
        assert.are.equal("/library", destination_chooser.path)
        destination_chooser:onMenuHold({ path = "/library/target" })
        local target_items = destination_chooser:genItemTableFromPath("/library/target")
        assert.is_true(target_items[1].is_go_up)
        assert.are.equal("/library", target_items[1].path)
        destination_chooser:onMenuSelect(target_items[1])
        assert.are.equal("/library", destination_chooser.path)
        assert.are.equal(1, #pasted)
        assert.is_true(fm.selected_files["/library/a.epub"])
        destination_chooser:onMenuSelect({ path = "/library/target" })
        assert.are.same({
            files = { ["/library/a.epub"] = true, ["/library/b.epub"] = true },
            cut = true, overwrite = false, folder = "/library/target",
        }, pasted[#pasted])
        assert.is_nil(fm.selected_files)

        fm.selected_files = { ["/library/a.epub"] = true, ["/library/b.epub"] = true }
        fm:onShowPlusMenu()
        assert(find_button(shown[#shown], "Copy")).callback()
        skip_second = true
        fm:pasteSelectedFilesFromZenClipboard("/library/target")
        shown[#shown].ok_callback()
        assert.is_nil(fm.selected_files)
        assert.are.same({ ["/library/b.epub"] = true }, fm._zen_selected_clipboard.files)
        skip_second = false
        fm:pasteSelectedFilesFromZenClipboard("/library/target")
        shown[#shown].ok_callback()
        assert.are.same({ ["/library/b.epub"] = true }, pasted[#pasted].files)
        assert.is_nil(fm._zen_selected_clipboard)

        fm.selected_files = { ["/library/a.epub"] = true, ["/library/b.epub"] = true }
        fm:onShowPlusMenu()
        assert(find_button(shown[#shown], "Read status")).callback()
        assert(find_button(shown[#shown], "Finished")).callback()
        assert.are.same({ ["/library/a.epub"] = "complete", ["/library/b.epub"] = "complete" }, summaries)

        fm:onShowPlusMenu()
        assert(find_button(shown[#shown], "Add to collection")).callback()
        local picker = shown[#shown]
        picker.onMenuSelect(picker, picker.item_table[1])
        assert.are.same({ ["/library/a.epub"] = true, ["/library/b.epub"] = true }, added)

        fm.selected_files = { ["/library/a.epub"] = true }
        fm:onShowPlusMenu()
        assert.are.equal("1 file", shown[#shown]._added_widgets[1][1][3][1].text)
        assert(find_button(shown[#shown], "Exit select mode")).callback()
        assert.is_nil(fm.selected_files)
    end)
end)
