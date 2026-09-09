describe("file browser navbar navigation", function()
    local FileManager
    local shared
    local calls
    local library_font_sizes
    local UIManager
    local home_widget
    local allow_group_prewarm
    local original_memory_policy
    local base_observation
    local measurements
    local dir_entries
    local dir_mtimes
    local dir_scan_calls
    local home_show_callback
    local setup_observation
    local initial_reinject_callback
    local device_input
    local native_available
    local native_launches
    local dispatcher_executions
    local real_paths
    local full_repaints
    local device_has_keys

    local function class(methods)
        methods = methods or {}
        methods.extend = methods.extend or function(self, child)
            child = child or {}
            child.extend = self.extend
            return setmetatable(child, { __index = self })
        end
        methods.new = methods.new or function(_, values)
            values = values or {}
            values.dimen = values.dimen or { w = values.width or 20, h = values.height or 20 }
            values.getSize = values.getSize or function(self) return self.dimen end
            values.free = values.free or function() end
            return values
        end
        return methods
    end

    local function measurement_detail(measurement, key)
        for index = 1, #(measurement and measurement.details or {}) - 1 do
            if measurement.details[index] == key then
                return measurement.details[index + 1]
            end
        end
    end

    before_each(function()
        calls = {}
        library_font_sizes = {}
        home_widget = {}
        allow_group_prewarm = true
        base_observation = nil
        measurements = {}
        dir_entries = {}
        dir_mtimes = {}
        dir_scan_calls = 0
        home_show_callback = nil
        setup_observation = nil
        initial_reinject_callback = nil
        native_available = true
        native_launches = {}
        dispatcher_executions = {}
        real_paths = {}
        full_repaints = 0
        device_has_keys = false
        device_input = {
            disable_double_tap = true,
            tap_interval_override = nil,
        }
        original_memory_policy = package.loaded["common/memory_policy"]
        shared = {
            home = {
                showHomeView = function(inject)
                    calls[#calls + 1] = "home"
                    if home_show_callback then home_show_callback(inject) end
                end,
                closeAll = function() calls[#calls + 1] = "close_home" end,
                getActiveWidgets = function() return { home_widget } end,
                isActiveOnTop = function() return true end,
            },
            group_view = {
                showAuthorsView = function() calls[#calls + 1] = "authors" end,
                showSeriesView = function() calls[#calls + 1] = "series" end,
                showTagsView = function() calls[#calls + 1] = "tags" end,
                showTagDetail = function(tag, _inject, tab_id)
                    calls[#calls + 1] = "tag:" .. tag .. ":" .. tab_id
                end,
                showTBRView = function() calls[#calls + 1] = "to_be_read" end,
                closeAll = function() calls[#calls + 1] = "close_groups" end,
            },
        }
        FileManager = class({
            setupLayout = function(self)
                setup_observation = {
                    hidden = rawget(_G, "__ZEN_UI_HIDDEN_HOME_BOOTSTRAP"),
                    deferred = rawget(_G, "__ZEN_UI_DEFER_FILEMANAGER_LISTING"),
                    invisible = self.invisible,
                }
                if self._test_setup_file_chooser then
                    self.file_chooser = self._test_setup_file_chooser
                end
            end,
            showFiles = function(self, path, focused)
                base_observation = {
                    hidden = rawget(_G, "__ZEN_UI_HIDDEN_HOME_BOOTSTRAP"),
                    deferred = rawget(_G, "__ZEN_UI_DEFER_FILEMANAGER_LISTING"),
                    target_folder = rawget(_G, "__ZEN_UI_OPEN_TARGET_FOLDER"),
                }
                FileManager.instance = self._test_next_instance or self
                self._test_next_instance = nil
                calls[#calls + 1] = "base:" .. tostring(path) .. ":" .. tostring(focused)
            end,
            onShowingReader = function() end,
        })
        FileManager.instance = nil
        ZenSpec.replace("apps/filemanager/filemanager", FileManager)
        ZenSpec.replace("ui/widget/filechooser", class({
            init = function() end,
            onPathChanged = function() end,
            onMenuSelect = function() end,
            onClose = function() end,
        }))
        ZenSpec.replace("apps/filemanager/filemanagerhistory", class({ onShowHist = function() end }))
        ZenSpec.replace("apps/filemanager/filemanagerfilesearcher", class({ onShowSearchResults = function() end }))
        ZenSpec.replace("apps/filemanager/filemanagercollection", class({
            onShowColl = function() end,
            onShowCollList = function() end,
        }))
        ZenSpec.replace("apps/filemanager/filemanagerutil", {})
        ZenSpec.replace("ui/widget/menu", class({ init = function() end, updateItems = function() end }))
        for _i, name in ipairs({
            "ui/widget/container/framecontainer", "ui/widget/container/inputcontainer",
            "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/widget/iconwidget",
            "ui/widget/linewidget", "ui/widget/textwidget", "ui/widget/verticalgroup",
            "ui/widget/verticalspan", "ui/widget/widget", "ui/widget/infomessage",
            "ui/gesturerange",
        }) do
            ZenSpec.replace(name, class())
        end
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_BLACK = "black", COLOR_DARK_GRAY = "dark", COLOR_WHITE = "white",
        })
        ZenSpec.replace("device", {
            input = device_input,
            screen = {
                scaleBySize = function(_, value) return value end,
                getWidth = function() return 800 end,
                getHeight = function() return 600 end,
                isColorScreen = function() return false end,
            },
            hasKeys = function() return device_has_keys end,
        })
        ZenSpec.replace("ui/geometry", {
            new = function(_, values)
                function values:contains() return true end
                return values
            end,
        })
        ZenSpec.replace("ui/event", { new = function(_, name) return { name = name } end })
        ZenSpec.replace("ui/rendertext", { getGlyphByIndex = function() return nil end })
        ZenSpec.replace("ffi/util", {
            realpath = function(path) return real_paths[path] or path end,
        })
        ZenSpec.replace("dispatcher", {
            execute = function(_self, action)
                dispatcher_executions[#dispatcher_executions + 1] = action
            end,
        })
        UIManager = {
            _window_stack = {},
            setDirty = function() end,
            forceRePaint = function() full_repaints = full_repaints + 1 end,
            nextTick = function(_, callback)
                initial_reinject_callback = initial_reinject_callback or callback
                callback()
            end,
            scheduleIn = function() end,
            unschedule = function() end,
            show = function() end,
            close = function() end,
            closeWidgetsAbove = function() end,
            broadcastEvent = function() end,
        }
        ZenSpec.replace("ui/uimanager", UIManager)
        ZenSpec.replace("common/utils", {
            deepcopy = function(value)
                if type(value) ~= "table" then return value end
                local result = {}
                for key, child in pairs(value) do result[key] = child end
                return result
            end,
            resolveLocalIcon = function(_, icon) return icon end,
            closeWidgetsAbove = function() end,
        })
        ZenSpec.replace("common/paths", {
            getHomeDir = function() return "/library" end,
            isInHomeDir = function(path) return path:sub(1, 8) == "/library" end,
        })
        ZenSpec.replace("common/plugin_root", "/plugin")
        ZenSpec.replace("common/shared_state", {
            get = function(_, key) return shared[key] end,
        })
        ZenSpec.replace("common/memory_policy", {
            canPrewarmGroups = function() return allow_group_prewarm end,
        })
        ZenSpec.replace("modules/filebrowser/patches/standalone_page", {
            enable_gesture_manager_dispatch = function() end,
        })
        ZenSpec.replace("common/ui/background", {
            library_active = function() return false end,
        })
        ZenSpec.replace("modules/menu/app_launcher/plugin_scan", {})
        ZenSpec.replace("modules/menu/app_launcher/native_menu", {
            exists = function(id, scope)
                return native_available and id == "network" and scope == "filemanager"
            end,
            resolve = function(id, scope)
                if not native_available or id ~= "network" or scope ~= "filemanager" then
                    return nil
                end
                return function()
                    native_launches[#native_launches + 1] = id .. ":" .. scope
                end
            end,
        })
        ZenSpec.replace("modules/filebrowser/patches/library_font", {
            getFace = function(size)
                library_font_sizes[#library_font_sizes + 1] = size
                return { size = size }
            end,
            scaleValue = function() error("navbar used library font size") end,
        })
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function(path, field)
                if field == "mode" and (path == "/library" or dir_mtimes[path]) then
                    return "directory"
                end
                if field == "modification" then return dir_mtimes[path] end
            end,
            dir = function(path)
                dir_scan_calls = dir_scan_calls + 1
                local entries = dir_entries[path] or {}
                local index = 0
                return function()
                    index = index + 1
                    return entries[index]
                end
            end,
        })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("common/zen_logger", {
            new = function()
                return {
                    dbg = function() end,
                    perf = function() end,
                    warn = function() end,
                    measure = function(message, elapsed, ...)
                        measurements[#measurements + 1] = {
                            message = message,
                            elapsed = elapsed,
                            details = { ... },
                        }
                    end,
                }
            end,
        })
        _G.G_reader_settings = ZenSpec.memorySettings()
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { navbar = true, restore_library_view = false },
                navbar = {
                    show_tabs = {
                        books = true, folder = true, home = true, authors = true, series = true,
                        tags = true, to_be_read = true, history = true,
                        favorites = true, collections = true, search = true,
                        page_left = true, page_right = true, menu = true,
                    },
                    tab_order = {
                        "home", "books", "authors", "series", "tags", "to_be_read",
                        "history", "favorites", "collections", "search",
                        "page_left", "page_right", "menu",
                    },
                    default_tab = "home",
                    folder_path = "/library/Fiction/",
                    show_icons = false,
                    show_labels = true,
                    label_size = 17,
                },
            },
        }
        ZenSpec.unload("modules/filebrowser/patches/navbar")
        require("modules/filebrowser/patches/navbar")()
    end)

    after_each(function()
        for _i, name in ipairs({
            "__ZEN_UI_PLUGIN", "__ZEN_UI_NAVBAR_OPEN_DEFAULT_TAB", "__ZEN_UI_NAVBAR_OPEN_TAB",
            "__ZEN_UI_NAVBAR_OPEN_FOLDER", "__ZEN_UI_NAVBAR_OPEN_TAG",
            "__ZEN_UI_NAVBAR_RESOLVE_DEFAULT_TAB", "__ZEN_UI_NAVBAR_IS_DEFAULT_TAB_ACTIVE",
            "__ZEN_UI_NAVBAR_DEFAULT_TAB_ICON",
            "__ZEN_UI_ACTIVE_TAB_LABEL",
            "__ZEN_UI_REINJECT_FM_NAVBAR", "__ZEN_UI_REINJECT_NAVBARS",
            "__ZEN_UI_LIBRARY_STATE", "__ZEN_UI_OPEN_HOME_AFTER_FILEMANAGER",
            "__ZEN_UI_OPEN_TARGET_TAB", "__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB",
            "__ZEN_UI_OPEN_TARGET_FOLDER", "__ZEN_UI_OPEN_TARGET_TAG",
            "__ZEN_UI_HIDDEN_HOME_BOOTSTRAP", "__ZEN_UI_DEFER_FILEMANAGER_LISTING",
        }) do
            _G[name] = nil
        end
        package.loaded["common/memory_policy"] = original_memory_policy
    end)

    local function make_instance()
        local instance = {
            file_chooser = {
                path = "/library/subfolder",
                path_items = {},
                item_table = {},
                changeToPath = function(_, path) calls[#calls + 1] = "books:" .. path end,
                updateItems = function() calls[#calls + 1] = "covers" end,
                onPrevPage = function() calls[#calls + 1] = "previous" end,
                onNextPage = function() calls[#calls + 1] = "next" end,
                showFileDialog = function() calls[#calls + 1] = "menu" end,
            },
            history = { onShowHist = function() calls[#calls + 1] = "history" end },
            collections = {
                onShowColl = function() calls[#calls + 1] = "favorites" end,
                onShowCollList = function() calls[#calls + 1] = "collections" end,
            },
            filesearcher = { onShowFileSearch = function() calls[#calls + 1] = "search" end },
        }
        FileManager.instance = instance
        return instance
    end

    local function stack_widgets()
        local widgets = {}
        for _i, window in ipairs(UIManager._window_stack) do
            widgets[#widgets + 1] = window.widget
        end
        return widgets
    end

    it("keeps configured tab order and resolves the first enabled default", function()
        assert.are.equal("home", _G.__ZEN_UI_NAVBAR_RESOLVE_DEFAULT_TAB())
        assert.are.same({
            "home", "books", "authors", "series", "tags", "to_be_read",
            "history", "favorites", "collections", "search",
            "page_left", "page_right", "menu",
        }, { unpack(_G.__ZEN_UI_PLUGIN.config.navbar.tab_order, 1, 13) })
        assert.are.equal("Home", _G.__ZEN_UI_ACTIVE_TAB_LABEL)
    end)

    it("keeps the move chooser fullscreen without a navbar", function()
        local Menu = require("ui/widget/menu")
        local chooser = {
            height = 600,
            covers_fullscreen = true,
            is_borderless = true,
            title_bar_fm_style = true,
            select_directory = true,
            select_file = false,
            _zen_renderer = true,
            _zen_no_forced_repaint = true,
        }

        Menu.init(chooser)

        assert.are.equal(600, chooser.height)
        assert.is_nil(chooser._zen_prevent_swipe_close)
        assert.is_nil(chooser.onMultiSwipe)
    end)

    it("keeps the named folder cover picker fullscreen without a navbar", function()
        local Menu = require("ui/widget/menu")
        local picker = {
            name = "folder_cover_picker",
            height = 600,
            covers_fullscreen = true,
            is_borderless = true,
            title_bar_fm_style = true,
            _zen_no_forced_repaint = true,
        }

        Menu.init(picker)

        assert.are.equal(600, picker.height)
        assert.is_nil(picker._zen_prevent_swipe_close)
        assert.is_nil(picker.onMultiSwipe)
    end)

    it("opens a hidden default tab and keeps its top-menu icon", function()
        _G.__ZEN_UI_PLUGIN.config.navbar.show_tabs.home = false

        assert.are.equal("home", _G.__ZEN_UI_NAVBAR_RESOLVE_DEFAULT_TAB())
        assert.are.equal("home", _G.__ZEN_UI_NAVBAR_DEFAULT_TAB_ICON())
        assert.are.equal("home", _G.__ZEN_UI_NAVBAR_OPEN_DEFAULT_TAB())
        assert.are.same({ "home" }, calls)
    end)

    it("applies updated label and icon to the existing built-in Folder tab", function()
        local navbar = _G.__ZEN_UI_PLUGIN.config.navbar
        navbar.folder_label = "Novels"
        navbar.folder_icon = "library"
        navbar.default_tab = "folder"
        table.insert(navbar.tab_order, 1, "folder")
        dir_mtimes["/library/Fiction"] = 1
        local fm = make_instance()
        fm[1] = { fm.file_chooser }

        _G.__ZEN_UI_REINJECT_FM_NAVBAR()

        assert.are.equal("library", _G.__ZEN_UI_NAVBAR_DEFAULT_TAB_ICON())
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("folder"))
        assert.are.equal("Novels", _G.__ZEN_UI_ACTIVE_TAB_LABEL)
    end)

    it("recognizes an already-active default tab", function()
        local fm = make_instance()
        UIManager._window_stack = { { widget = { _zen_navbar_tab_id = "home" } } }
        assert.is_true(_G.__ZEN_UI_NAVBAR_IS_DEFAULT_TAB_ACTIVE())

        _G.__ZEN_UI_PLUGIN.config.navbar.default_tab = "authors"
        assert.is_false(_G.__ZEN_UI_NAVBAR_IS_DEFAULT_TAB_ACTIVE())
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("authors"))
        UIManager._window_stack = { { widget = { _zen_navbar_tab_id = "authors" } } }
        assert.is_true(_G.__ZEN_UI_NAVBAR_IS_DEFAULT_TAB_ACTIVE())

        _G.__ZEN_UI_PLUGIN.config.navbar.default_tab = "books"
        assert.is_false(_G.__ZEN_UI_NAVBAR_IS_DEFAULT_TAB_ACTIVE())
        FileManager.onPathChanged(fm, "/library/folder")
        UIManager._window_stack = { { widget = fm } }
        assert.is_true(_G.__ZEN_UI_NAVBAR_IS_DEFAULT_TAB_ACTIVE())

        _G.__ZEN_UI_PLUGIN.config.navbar.default_tab = "tags"
        assert.is_false(_G.__ZEN_UI_NAVBAR_IS_DEFAULT_TAB_ACTIVE())
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("tags"))
        UIManager._window_stack = { { widget = { _zen_navbar_tab_id = "tags" } } }
        assert.is_true(_G.__ZEN_UI_NAVBAR_IS_DEFAULT_TAB_ACTIVE())
    end)

    it("reloads and opens a file-manager-backed Library default at the root", function()
        _G.__ZEN_UI_PLUGIN.config.features.restore_library_view = true
        _G.__ZEN_UI_PLUGIN.config.navbar.default_tab = "books"
        assert.are.equal("books", _G.__ZEN_UI_NAVBAR_RESOLVE_DEFAULT_TAB())

        local fm = make_instance()
        calls = {}
        FileManager._test_next_instance = fm
        _G.__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB = true
        FileManager.showFiles(FileManager, "/library/subfolder", "/library/Book.epub")

        assert.are.same({ "base:/library:nil", "covers" }, calls)
        assert.are.equal("Library", _G.__ZEN_UI_ACTIVE_TAB_LABEL)
        assert.is_nil(fm.file_chooser._zen_needs_cover_refresh)
        assert.is_nil(_G.__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB)
    end)

    it("keeps the physical folder and focused book when restoring Reader", function()
        _G.__ZEN_UI_PLUGIN.config.features.restore_library_view = true
        local fm = make_instance()
        FileManager._test_next_instance = fm
        calls = {}

        FileManager.showFiles(FileManager,
            "/library/Fiction", "/library/Fiction/Book.epub")

        assert.are.same({
            "base:/library/Fiction:/library/Fiction/Book.epub",
        }, calls)
        assert.is_nil(_G.__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB)
    end)

    it("lets a forced default Home override saved Series state", function()
        _G.__ZEN_UI_PLUGIN.config.features.restore_library_view = true
        _G.__ZEN_UI_LIBRARY_STATE = { tab = "series", page = 2 }
        _G.__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB = true
        local fm = make_instance()
        FileManager._test_next_instance = fm
        calls = {}

        FileManager.showFiles(FileManager, "/library/Series", "/library/Series/Book.epub")

        assert.are.same({ "base:/library:nil", "home" }, calls)
        assert.is_true(fm.invisible)
        assert.is_nil(_G.__ZEN_UI_LIBRARY_STATE)
        assert.is_nil(_G.__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB)
    end)

    it("defers hidden FileManager construction for a default Home startup", function()
        _G.__ZEN_UI_PLUGIN.config.features.restore_library_view = true
        local fm = make_instance()
        FileManager.onPathChanged(fm, "/library")
        calls = {}
        measurements = {}
        FileManager._test_next_instance = fm

        FileManager.showFiles(FileManager, "/library", nil)

        assert.are.same({ "base:/library:nil", "home" }, calls)
        assert.is_true(base_observation.hidden)
        assert.are.equal("/library", base_observation.deferred.path)
        assert.is_true(fm.invisible)
        assert.is_true(fm.file_chooser._zen_needs_full_listing)
        assert.is_nil(_G.__ZEN_UI_HIDDEN_HOME_BOOTSTRAP)
        assert.is_nil(_G.__ZEN_UI_DEFER_FILEMANAGER_LISTING)
        for _i, measurement in ipairs(measurements) do
            assert.are_not.equal("Library to Home first reveal", measurement.message)
        end

        calls = {}
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("books"))
        assert.are.same({ "books:/library" }, calls)
        assert.is_nil(fm.invisible)
        assert.is_nil(fm.file_chooser._zen_needs_full_listing)
        assert.is_nil(fm.file_chooser._zen_hidden_home_startup)
    end)

    it("builds a Reader folder target directly without hidden Home startup", function()
        local target = "/library/Fiction"
        dir_mtimes[target] = 10
        local fm = make_instance()
        fm.file_chooser.path = target
        FileManager._test_next_instance = fm
        _G.__ZEN_UI_OPEN_TARGET_FOLDER = target
        calls = {}

        FileManager.showFiles(FileManager, "/library", "/library/Book.epub")

        assert.are.same({ "base:/library/Fiction:nil" }, calls)
        assert.are.equal(target, base_observation.target_folder)
        assert.is_nil(base_observation.hidden)
        assert.is_nil(fm.invisible)
        assert.is_nil(fm._zen_hidden_home_startup)
        assert.is_nil(fm.file_chooser._zen_hidden_home_startup)
        assert.is_nil(_G.__ZEN_UI_OPEN_TARGET_FOLDER)
        assert.are.equal("Folder", _G.__ZEN_UI_ACTIVE_TAB_LABEL)
    end)

    it("finishes deferred Home when Android restores a focused book", function()
        _G.__ZEN_UI_PLUGIN.config.features.restore_library_view = true
        local fm = make_instance()
        fm.invisible = true
        fm._zen_hidden_home_startup = true
        fm.file_chooser._zen_hidden_home_startup = true
        fm.file_chooser._zen_needs_full_listing = true
        FileManager._test_next_instance = fm
        calls = {}

        FileManager.showFiles(FileManager, "/library", "/library/Book.epub")

        assert.are.same({
            "base:/library:/library/Book.epub",
            "home",
        }, calls)
        assert.is_true(fm._zen_default_tab_bootstrapped)
    end)

    it("defers cold default-Home construction from the initial setupLayout seam", function()
        local injected_update
        local file_chooser = {
            path_items = {},
            height = 600,
            dimen = { h = 600 },
            inner_dimen = { h = 600 },
            updateItems = function()
                injected_update = {
                    hidden = rawget(_G, "__ZEN_UI_HIDDEN_HOME_BOOTSTRAP"),
                    deferred = rawget(_G, "__ZEN_UI_DEFER_FILEMANAGER_LISTING"),
                }
            end,
        }
        local fm = {
            root_path = "/library/subfolder",
            focused_file = nil,
            _test_setup_file_chooser = file_chooser,
        }
        fm[1] = { file_chooser }
        FileManager.instance = nil

        FileManager.setupLayout(fm)

        assert.is_true(setup_observation.hidden)
        assert.are.equal("/library", setup_observation.deferred.path)
        assert.is_true(setup_observation.invisible)
        assert.are.equal("/library", fm.root_path)
        assert.is_true(fm.invisible)
        assert.is_true(fm._zen_hidden_home_startup)
        assert.is_true(file_chooser._zen_hidden_home_startup)
        assert.is_true(file_chooser._zen_needs_full_listing)
        assert.is_true(injected_update.hidden)
        assert.are.equal("/library", injected_update.deferred.path)
        assert.is_nil(_G.__ZEN_UI_HIDDEN_HOME_BOOTSTRAP)
        assert.is_nil(_G.__ZEN_UI_DEFER_FILEMANAGER_LISTING)
        assert.are.equal("Cold Home setup deferred", measurements[1].message)
        assert.are.equal("/library", measurement_detail(measurements[1], "path="))
        assert.is_true(measurement_detail(measurements[1], "listing_deferred="))
        assert.is_true(measurement_detail(measurements[1], "covers_suppressed="))
    end)

    it("opens deferred Home below every existing startup widget without polling", function()
        local fm = make_instance()
        fm.invisible = true
        fm._zen_hidden_home_startup = true
        fm.file_chooser._zen_hidden_home_startup = true
        fm.file_chooser._zen_needs_full_listing = true
        local plugin_widget = {}
        local invisible_widget = { invisible = true }
        local lock_modal = { modal = true }
        local notification = { toast = true }
        UIManager._window_stack = {
            { widget = fm },
            { widget = plugin_widget },
            { widget = invisible_widget },
            { widget = lock_modal },
            { widget = notification },
        }
        local scheduled = {}
        UIManager.scheduleIn = function(_self, delay)
            scheduled[#scheduled + 1] = delay
        end
        home_show_callback = function()
            -- UIManager initially places a non-modal Home above non-modal widgets.
            table.insert(UIManager._window_stack, 4, { widget = home_widget })
        end
        calls = {}

        initial_reinject_callback()
        initial_reinject_callback()

        assert.are.same({ "home" }, calls)
        assert.is_true(fm._zen_default_tab_bootstrapped)
        assert.is_nil(fm._zen_default_tab_retry_fn)
        for _i, delay in ipairs(scheduled) do
            assert.are_not.equal(0.25, delay)
        end
        assert.are.same({
            fm, home_widget, plugin_widget, invisible_widget,
            lock_modal, notification,
        }, stack_widgets())
    end)

    it("preserves the top plugin widget's input state while preparing Home", function()
        local fm = make_instance()
        fm.invisible = true
        fm._zen_hidden_home_startup = true
        fm.file_chooser._zen_hidden_home_startup = true
        fm.file_chooser._zen_needs_full_listing = true
        local plugin_widget = {}
        UIManager._window_stack = {
            { widget = fm },
            { widget = plugin_widget },
        }
        device_input.disable_double_tap = false
        device_input.tap_interval_override = "plugin"
        UIManager._input_gestures_disabled = true
        local ignore_touch_states = {}
        UIManager.setIgnoreTouchInput = function(self, state)
            ignore_touch_states[#ignore_touch_states + 1] = state
            self._input_gestures_disabled = state == true
        end
        home_show_callback = function()
            table.insert(UIManager._window_stack, { widget = home_widget })
            -- Mirror UIManager:show() side effects before Zen restores the real top widget.
            device_input.disable_double_tap = true
            device_input.tap_interval_override = nil
            UIManager._input_gestures_disabled = false
            home_widget._restored_input_gestures = true
        end
        calls = {}

        initial_reinject_callback()
        initial_reinject_callback()

        assert.are.same({ "home" }, calls)
        assert.is_true(fm._zen_default_tab_bootstrapped)
        assert.are.same({ fm, home_widget, plugin_widget }, stack_widgets())
        assert.is_false(device_input.disable_double_tap)
        assert.are.equal("plugin", device_input.tap_interval_override)
        assert.is_true(UIManager._input_gestures_disabled)
        assert.is_nil(home_widget._restored_input_gestures)
        assert.are.same({ true }, ignore_touch_states)
    end)

    it("does not defer initial setupLayout when Library is the default", function()
        _G.__ZEN_UI_PLUGIN.config.navbar.default_tab = "books"
        local fm = {
            root_path = "/library/subfolder",
            _test_setup_file_chooser = { path_items = {} },
        }
        FileManager.instance = nil

        FileManager.setupLayout(fm)

        assert.is_nil(setup_observation.hidden)
        assert.is_nil(setup_observation.deferred)
        assert.is_nil(fm.invisible)
        assert.is_nil(fm._zen_hidden_home_startup)
    end)

    it("does not request another repaint after setupLayout", function()
        _G.__ZEN_UI_PLUGIN.config.navbar.default_tab = "books"
        local file_chooser = { path_items = {} }
        local fm = {
            root_path = "/library",
            _test_setup_file_chooser = file_chooser,
            { file_chooser },
        }
        FileManager.instance = fm
        local dirty_calls = 0
        UIManager.setDirty = function() dirty_calls = dirty_calls + 1 end

        FileManager.setupLayout(fm)

        assert.are.equal(0, dirty_calls)
    end)

    it("reapplies a Library default after cold-start path tracking", function()
        _G.__ZEN_UI_PLUGIN.config.navbar.default_tab = "books"
        local fm = make_instance()
        fm.file_chooser.path = "/library/Fiction"
        fm[1] = { fm.file_chooser }
        FileManager.onPathChanged(fm, fm.file_chooser.path)
        UIManager._window_stack = { { widget = fm } }
        calls = {}

        initial_reinject_callback()

        assert.are.same({ "books:/library" }, calls)
        assert.are.equal("Library", _G.__ZEN_UI_ACTIVE_TAB_LABEL)
        assert.is_true(fm._zen_default_tab_bootstrapped)
    end)

    it("defers hidden FileManager construction when restoring Home", function()
        _G.__ZEN_UI_PLUGIN.config.features.restore_library_view = true
        _G.__ZEN_UI_LIBRARY_STATE = { tab = "home", page = 2 }
        local fm = make_instance()
        calls = {}
        FileManager._test_next_instance = fm

        FileManager.showFiles(FileManager, "/library/subfolder", "/library/Book.epub")

        assert.are.same({
            "base:/library/subfolder:/library/Book.epub",
            "home",
        }, calls)
        assert.is_true(base_observation.hidden)
        assert.are.equal("/library/subfolder", base_observation.deferred.path)
        assert.is_true(fm.invisible)
        assert.is_true(fm.file_chooser._zen_needs_full_listing)

        calls = {}
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("books"))
        assert.are.same({ "books:/library" }, calls)
        assert.is_nil(fm.invisible)
        assert.is_nil(fm.file_chooser._zen_needs_full_listing)
    end)

    it("idle-warms only the deferred Library listing while Home remains visible", function()
        local fm = make_instance()
        fm.file_chooser._zen_needs_full_listing = true
        fm.file_chooser._zen_warm_item_table = function(_, path)
            calls[#calls + 1] = "warm:" .. path
            return { { path = "/library/Book.epub" } },
                { cache = "disk_hit", items = 42 }
        end
        fm.file_chooser._zen_warm_cover_page = function(_, items, page)
            calls[#calls + 1] = "warm_covers:" .. tostring(page) .. ":" .. #items
            return true
        end
        local scheduled = {}
        UIManager.scheduleIn = function(_self, delay, callback)
            scheduled[#scheduled + 1] = { delay = delay, callback = callback }
        end
        calls = {}

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("home"))
        local listing_warm
        for _i, entry in ipairs(scheduled) do
            if entry.delay == 0.9 then listing_warm = entry.callback end
        end
        assert.is_function(listing_warm)
        listing_warm()

        assert.are.same({ "home", "warm:/library", "warm_covers:1:1" }, calls)
        assert.are.equal("Hidden Library listing warmed", measurements[1].message)
        assert.are.equal("true", measurement_detail(measurements[1], "cover_page_warm="))
        assert.are.equal("scheduled",
            measurement_detail(measurements[1], "cover_page_warm_reason="))
        assert.is_true(fm.file_chooser._zen_needs_full_listing)
    end)

    it("retries hidden Library warming after a temporary Home overlay", function()
        local fm = make_instance()
        local home_on_top = false
        local warm_calls = 0
        fm.file_chooser._zen_needs_full_listing = true
        fm.file_chooser._zen_warm_item_table = function()
            warm_calls = warm_calls + 1
            return {}, { cache = "disk_hit", items = 0 }
        end
        shared.home.isActiveOnTop = function() return home_on_top end
        local scheduled = {}
        UIManager.scheduleIn = function(_self, delay, callback)
            scheduled[#scheduled + 1] = { delay = delay, callback = callback }
        end
        calls = {}

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("home"))
        local first_warm
        for _i, entry in ipairs(scheduled) do
            if entry.delay == 0.9 then first_warm = entry.callback end
        end
        assert.is_function(first_warm)
        first_warm()

        assert.are.equal(0, warm_calls)
        local retry = scheduled[#scheduled]
        assert.are.equal(0.5, retry.delay)
        assert.are.equal(first_warm, retry.callback)
        assert.are.equal(retry.callback, fm._zen_hidden_library_warm_fn)

        home_on_top = true
        retry.callback()

        assert.are.equal(1, warm_calls)
        assert.is_nil(fm._zen_hidden_library_warm_fn)
        local warmed
        for _i, measurement in ipairs(measurements) do
            if measurement.message == "Hidden Library listing warmed" then
                warmed = measurement
            end
        end
        assert.is_table(warmed)
    end)

    it("materializes page one under Home and reveals it without a second refresh", function()
        local fm = make_instance()
        local fc = fm.file_chooser
        local warmed_items = { { path = "/library/Book.epub", is_file = true } }
        fm.invisible = true
        fm._zen_hidden_home_startup = true
        fc.path = "/library"
        fc.page = 1
        fc.item_table = {}
        fc._zen_hidden_home_startup = true
        fc._zen_needs_full_listing = true
        dir_mtimes["/library"] = 10
        local hidden_dirty = 0
        UIManager.setDirty = function() hidden_dirty = hidden_dirty + 1 end
        fc._zen_warm_item_table = function(_, path)
            calls[#calls + 1] = "warm:" .. path
            return warmed_items, { cache = "disk_hit", items = 1 }
        end
        fc._zen_prepare_item_table = function(_, path, items)
            calls[#calls + 1] = "prepare:" .. path
            return items == warmed_items
        end
        fc.refreshPath = function(self)
            calls[#calls + 1] = "refresh"
            UIManager:setDirty(fm, "ui")
            self.item_table = warmed_items
            self.page = 1
            self._zen_last_item_table_cache_result = { cache = "prepared" }
        end
        fc._zen_warm_cover_page = function(_, items, page, on_complete)
            calls[#calls + 1] = "warm_covers:" .. tostring(page) .. ":" .. #items
            on_complete()
            return true
        end
        fc._zen_start_hidden_folder_prewarm = function(_, guard)
            calls[#calls + 1] = "prewarm_folders:" .. tostring(guard())
            fc._zen_hidden_folder_prewarm_state = {}
            return true, 2
        end
        fc._zen_cancel_hidden_folder_prewarm = function(_, reason, mode)
            calls[#calls + 1] = "cancel_folder_prewarm:"
                .. tostring(reason) .. ":" .. tostring(mode)
            fc._zen_hidden_folder_prewarm_state = nil
            return true
        end
        local scheduled = {}
        UIManager.scheduleIn = function(_self, delay, callback)
            scheduled[#scheduled + 1] = { delay = delay, callback = callback }
        end
        calls = {}

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("home"))
        local listing_warm
        for _i, entry in ipairs(scheduled) do
            if entry.delay == 0.9 then listing_warm = entry.callback end
        end
        assert.is_function(listing_warm)
        listing_warm()

        assert.are.same({
            "home", "cancel_folder_prewarm:left_home:discard",
            "warm:/library", "prepare:/library",
            "warm_covers:1:1", "refresh", "prewarm_folders:true",
        }, calls)
        assert.is_table(fc._zen_idle_materialized_library)
        assert.is_true(rawequal(warmed_items, fc.item_table))
        assert.is_true(fc._zen_needs_full_listing)
        assert.is_true(fm.invisible)
        assert.are.equal(0, hidden_dirty)

        shared.home.suspendActive = function() return true end
        UIManager._window_stack = {
            { widget = fm },
            { widget = home_widget },
        }
        local reveal_dirty
        UIManager.setDirty = function(_self, widget, mode)
            if widget and widget.invisible ~= true then
                local top = UIManager._window_stack[#UIManager._window_stack]
                reveal_dirty = { widget = widget, mode = mode, top = top and top.widget }
            end
        end
        calls = {}
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("books"))

        assert.are.same({
            "cancel_folder_prewarm:library_reveal:preserve",
        }, calls)
        assert.are.same({ widget = fm, mode = "ui", top = fm }, reveal_dirty)
        assert.is_true(rawequal(warmed_items, fc.item_table))
        assert.is_nil(fc._zen_idle_materialized_library)
        assert.is_nil(fc._zen_needs_full_listing)
        assert.is_nil(fc._zen_hidden_home_startup)
        assert.is_nil(fm._zen_hidden_home_startup)
        assert.is_nil(fm.invisible)
        local materialized
        for _i, measurement in ipairs(measurements) do
            if measurement.message == "Hidden Library page materialized" then
                materialized = measurement
            end
        end
        assert.is_table(materialized)
        assert.are.equal("prepared",
            measurement_detail(materialized, "listing_cache="))
        assert.are.equal(1,
            measurement_detail(materialized, "suppressed_dirty="))
    end)

    it("cancels a pending hidden Library warm when leaving Home", function()
        local fm = make_instance()
        fm.file_chooser._zen_needs_full_listing = true
        local warmed = false
        fm.file_chooser._zen_warm_item_table = function()
            warmed = true
            return {}, { cache = "miss", items = 0 }
        end
        local listing_warm
        local unscheduled
        UIManager.scheduleIn = function(_self, delay, callback)
            if delay == 0.9 then listing_warm = callback end
        end
        UIManager.unschedule = function(_self, callback)
            unscheduled = callback
        end

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("home"))
        assert.is_function(listing_warm)
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("books"))
        assert.are.equal(listing_warm, unscheduled)
        listing_warm()
        assert.is_false(warmed)
    end)

    it("cancels active page-one cover warming when leaving Home", function()
        local fm = make_instance()
        fm.file_chooser._zen_needs_full_listing = true
        local cover_warm_active = false
        local cover_warm_cancelled = 0
        fm.file_chooser._zen_warm_item_table = function()
            return { { path = "/library/Book.epub" } },
                { cache = "disk_hit", items = 1 }
        end
        fm.file_chooser._zen_warm_cover_page = function()
            cover_warm_active = true
            return true
        end
        fm.file_chooser._zen_cancel_warm_cover_page = function()
            if cover_warm_active then
                cover_warm_active = false
                cover_warm_cancelled = cover_warm_cancelled + 1
            end
        end
        local listing_warm
        UIManager.scheduleIn = function(_self, delay, callback)
            if delay == 0.9 then listing_warm = callback end
        end

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("home"))
        listing_warm()
        assert.is_true(cover_warm_active)

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("books"))
        assert.is_false(cover_warm_active)
        assert.are.equal(1, cover_warm_cancelled)
    end)

    it("reveals a retained Library page before validating it", function()
        local fm = make_instance()
        fm.file_chooser.path = "/library"
        fm.file_chooser.page = 3
        fm.file_chooser._zen_lib_mtime_snapshot = { ["/library"] = 10 }
        fm.file_chooser._zen_lib_mtime_snapshot_at = os.clock()
        local cover_resume_calls = 0
        local status_updates = 0
        fm.file_chooser._zen_resume_visible_cover_work = function()
            cover_resume_calls = cover_resume_calls + 1
            return true
        end
        fm._updateStatusBar = function()
            status_updates = status_updates + 1
        end
        dir_mtimes["/library"] = 10

        local next_ticks = {}
        UIManager.nextTick = function(_self, callback)
            next_ticks[#next_ticks + 1] = callback
        end

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("home"))
        assert.are.equal(0, #next_ticks)
        calls = {}

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("books"))
        assert.are.same({}, calls)
        assert.are.equal(3, fm.file_chooser.page)
        assert.are.equal(1, cover_resume_calls)
        assert.are.equal(2, #next_ticks)

        table.remove(next_ticks, 1)()
        table.remove(next_ticks, 1)()
        assert.are.same({}, calls)
        assert.is_nil(fm.file_chooser._zen_home_retained_library)
        assert.are.equal(0, dir_scan_calls)
        assert.are.equal(0, status_updates)
        assert.are.equal("Home to Library first reveal", measurements[1].message)
        assert.are.equal("Home to Library validation completed", measurements[2].message)
        assert.are.equal("skipped",
            measurement_detail(measurements[2], "recursive_validation="))
    end)

    it("routes Back from a live Home overlay through Library validation", function()
        local fm = make_instance()
        fm.file_chooser.path = "/library"
        fm.file_chooser.page = 2
        local cover_resume_calls = 0
        fm.file_chooser._zen_resume_visible_cover_work = function()
            cover_resume_calls = cover_resume_calls + 1
            return true
        end
        local home_menu
        home_show_callback = function(inject)
            local body = {
                dimen = { w = 800, h = 560 },
                inner_dimen = { w = 800, h = 560 },
                resetLayout = function() end,
            }
            home_menu = {
                name = "home",
                dimen = { w = 800, h = 600 },
                inner_dimen = { w = 800, h = 600 },
                close_callback = function() calls[#calls + 1] = "home_close" end,
                [1] = body,
            }
            inject(home_menu, "home")
        end

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("home"))
        assert.is_table(home_menu)
        calls = {}

        assert.is_true(home_menu:onBack())
        assert.are.same({ "home_close" }, calls)
        assert.are.equal("Library", _G.__ZEN_UI_ACTIVE_TAB_LABEL)
        assert.are.equal(1, cover_resume_calls)
        assert.is_nil(fm.file_chooser._zen_home_retained_library)
    end)

    it("re-stats known subdirs when the Library root is untouched", function()
        local fm = make_instance()
        fm.file_chooser.path = "/library"
        fm.file_chooser.page = 2
        fm.file_chooser._zen_lib_mtime_snapshot = {
            ["/library"] = 10,
            ["/library/sub"] = 20,
        }
        fm.file_chooser._zen_lib_mtime_subdirs = { "/library/sub" }
        fm.file_chooser._zen_lib_mtime_snapshot_at = os.clock() - 31
        fm.file_chooser._zen_invalidate_item_table_path = function(_, path)
            calls[#calls + 1] = "invalidate:" .. path
        end
        dir_mtimes["/library"] = 10
        dir_mtimes["/library/sub"] = 20
        dir_entries["/library"] = { "sub" }

        local next_ticks = {}
        UIManager.nextTick = function(_self, callback)
            next_ticks[#next_ticks + 1] = callback
        end
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("home"))
        dir_mtimes["/library/sub"] = 21
        calls = {}

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("books"))
        assert.are.same({}, calls)
        table.remove(next_ticks, 1)()
        assert.are.same({ "invalidate:/library", "books:/library" }, calls)
        assert.are.equal("re-statted",
            measurement_detail(measurements[2], "recursive_validation="))
        assert.are.equal("true", measurement_detail(measurements[2], "listing_changed="))
        assert.are.equal(0, dir_scan_calls)
    end)

    it("refreshes after first reveal when recursive Library validation changes", function()
        local fm = make_instance()
        fm.file_chooser.path = "/library"
        fm.file_chooser.page = 2
        fm.file_chooser._zen_lib_mtime_snapshot = {
            ["/library"] = 10,
            ["/library/sub"] = 20,
        }
        fm.file_chooser._zen_invalidate_item_table_path = function(_, path)
            calls[#calls + 1] = "invalidate:" .. path
        end
        dir_mtimes["/library"] = 10
        dir_mtimes["/library/sub"] = 20
        dir_entries["/library"] = { "sub" }

        local next_ticks = {}
        UIManager.nextTick = function(_self, callback)
            next_ticks[#next_ticks + 1] = callback
        end
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("home"))
        dir_mtimes["/library/sub"] = 21
        calls = {}

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("books"))
        assert.are.same({}, calls)
        table.remove(next_ticks, 1)()
        assert.are.same({ "invalidate:/library", "books:/library" }, calls)
        assert.are.equal("scanned",
            measurement_detail(measurements[2], "recursive_validation="))
        assert.are.equal("true", measurement_detail(measurements[2], "listing_changed="))
        assert.are.equal("true", measurement_detail(measurements[2], "refreshed="))
    end)

    it("ignores sidecar directories during recursive Library validation", function()
        local fm = make_instance()
        fm.file_chooser.path = "/library"
        fm.file_chooser.page = 2
        fm.file_chooser._zen_lib_mtime_snapshot = { ["/library"] = 10 }
        dir_mtimes["/library"] = 10
        dir_mtimes["/library/Book.sdr"] = 20
        dir_entries["/library"] = { "Book.sdr" }

        local next_ticks = {}
        UIManager.nextTick = function(_self, callback)
            next_ticks[#next_ticks + 1] = callback
        end
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("home"))
        dir_mtimes["/library/Book.sdr"] = 21
        calls = {}

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("books"))
        table.remove(next_ticks, 1)()
        assert.are.same({}, calls)
        assert.are.equal(1, dir_scan_calls)
    end)

    it("rebuilds before reveal when retained Library sorting changed", function()
        local fm = make_instance()
        fm.file_chooser.path = "/library"
        fm.file_chooser.page = 2
        dir_mtimes["/library"] = 10
        local next_ticks = {}
        UIManager.nextTick = function(_self, callback)
            next_ticks[#next_ticks + 1] = callback
        end

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("home"))
        _G.G_reader_settings:saveSetting("collate", "date")
        calls = {}

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("books"))
        assert.are.same({ "books:/library" }, calls)
    end)

    it("dispatches persistent tabs to their intended library views and tracks active state", function()
        make_instance()
        for _i, id in ipairs({ "home", "authors", "series", "tags", "to_be_read" }) do
            assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB(id))
            assert.are.equal(id == "to_be_read" and "To Be Read" or id:gsub("^%l", string.upper),
                _G.__ZEN_UI_ACTIVE_TAB_LABEL)
        end
        assert.are.same({ "home", "authors", "series", "tags", "to_be_read" }, calls)
    end)

    it("opens the configured folder and highlights its full subtree only", function()
        local fm = make_instance()
        dir_mtimes["/library/Fiction"] = 10
        calls = {}

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("folder"))
        assert.are.same({ "books:/library/Fiction" }, calls)
        assert.are.equal("Folder", _G.__ZEN_UI_ACTIVE_TAB_LABEL)

        FileManager.onPathChanged(fm, "/library/Fiction/Series")
        assert.are.equal("Folder", _G.__ZEN_UI_ACTIVE_TAB_LABEL)

        FileManager.onPathChanged(fm, "/library/Fictional")
        assert.are.equal("Library", _G.__ZEN_UI_ACTIVE_TAB_LABEL)
    end)

    it("builds the configured folder when the hidden Home listing is still deferred", function()
        local fm = make_instance()
        local fc = fm.file_chooser
        local rendered_paths = {}
        _G.__ZEN_UI_PLUGIN.config.navbar.folder_path = "/library"
        fm.invisible = true
        fm._zen_hidden_home_startup = true
        fc.path = "/library"
        fc._zen_hidden_home_startup = true
        fc._zen_needs_full_listing = true
        fc.refreshPath = function(self)
            assert.is_true(fm.invisible)
            calls[#calls + 1] = "refresh:" .. self.path
            self.item_table = { { path = "/library/Book.epub" } }
        end
        fc.onGotoPage = function(_, page)
            calls[#calls + 1] = "page:" .. page
        end
        UIManager._window_stack = {
            { widget = fm },
            { widget = home_widget },
        }
        UIManager.setDirty = function(_self, widget)
            if widget == fm and widget.invisible ~= true then
                rendered_paths[#rendered_paths + 1] = fc.path
            end
        end
        calls = {}

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("folder"))

        assert.are.same({ "refresh:/library" }, calls)
        assert.is_nil(fm.invisible)
        assert.is_nil(fm._zen_hidden_home_startup)
        assert.is_nil(fc._zen_hidden_home_startup)
        assert.is_nil(fc._zen_needs_full_listing)
        assert.are.equal("Folder", _G.__ZEN_UI_ACTIVE_TAB_LABEL)
        assert.are.same({ "/library" }, rendered_paths)
        assert.are.equal(0, full_repaints)
    end)

    it("keeps Folder active when FileChooser canonicalizes its configured path", function()
        local fm = make_instance()
        _G.__ZEN_UI_PLUGIN.config.navbar.folder_path = "/alias/Fiction/"
        real_paths["/alias/Fiction/"] = "/library/Fiction"
        real_paths["/alias/Fiction"] = "/library/Fiction"
        dir_mtimes["/library/Fiction"] = 10
        calls = {}

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("folder"))
        assert.are.same({ "books:/library/Fiction" }, calls)

        FileManager.onPathChanged(fm, "/library/Fiction/Series")
        assert.are.equal("Folder", _G.__ZEN_UI_ACTIVE_TAB_LABEL)
    end)

    it("routes a navbar Open folder action through Folder tab navigation", function()
        local fm = make_instance()
        local fc = fm.file_chooser
        fm[1] = { fc }
        fm.invisible = true
        fm._zen_hidden_home_startup = true
        fc.path = "/library"
        fc._zen_hidden_home_startup = true
        fc._zen_needs_full_listing = true
        fc.changeToPath = function(self, path)
            calls[#calls + 1] = "books:" .. path
            self.path = path
            FileManager.onPathChanged(fm, path)
        end
        local navbar_config = _G.__ZEN_UI_PLUGIN.config.navbar
        navbar_config.custom_tabs = {{
            id = "ct_folder",
            type = "action",
            label = "Sci-Fi",
            icon = "tab_folder",
            action = { zen_ui_show_folder = "/library/SciFi" },
        }}
        navbar_config.show_tabs.ct_folder = true
        navbar_config.tab_order = { "home", "ct_folder" }
        dir_mtimes["/library/SciFi"] = 10
        _G.__ZEN_UI_REINJECT_FM_NAVBAR()
        calls = {}

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("ct_folder"))

        assert.are.same({ "books:/library/SciFi" }, calls)
        assert.are.equal(0, #dispatcher_executions)
        assert.are.equal("/library/SciFi", fc.path)
        assert.is_nil(fm.invisible)
        assert.is_nil(fm._zen_hidden_home_startup)
        assert.is_nil(fc._zen_hidden_home_startup)
        assert.is_nil(fc._zen_needs_full_listing)
        assert.are.equal("Sci-Fi", _G.__ZEN_UI_ACTIVE_TAB_LABEL)

        FileManager.onPathChanged(fm, "/library/SciFi/Series")
        assert.are.equal("Sci-Fi", _G.__ZEN_UI_ACTIVE_TAB_LABEL)
    end)

    it("opens independently configured folder tabs and tracks each destination", function()
        local fm = make_instance()
        local fc = fm.file_chooser
        fm[1] = { fc }
        fc.changeToPath = function(self, path)
            calls[#calls + 1] = "books:" .. path
            self.path = path
            FileManager.onPathChanged(fm, path)
        end
        local navbar_config = _G.__ZEN_UI_PLUGIN.config.navbar
        navbar_config.custom_tabs = {
            { id = "ct_fiction", type = "folder", folder = "/library/Fiction",
                label = "Fiction", icon = "tab_folder" },
            { id = "ct_nonfiction", type = "folder", folder = "/library/Nonfiction",
                label = "Nonfiction", icon = "tab_folder" },
        }
        navbar_config.show_tabs.ct_fiction = true
        navbar_config.show_tabs.ct_nonfiction = true
        navbar_config.tab_order = { "home", "ct_fiction", "ct_nonfiction" }
        dir_mtimes["/library/Fiction"] = 10
        dir_mtimes["/library/Nonfiction"] = 10
        _G.__ZEN_UI_REINJECT_FM_NAVBAR()
        calls = {}

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("ct_fiction"))
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("ct_nonfiction"))

        assert.are.same({
            "books:/library/Fiction",
            "books:/library/Nonfiction",
        }, calls)
        assert.are.equal("Nonfiction", _G.__ZEN_UI_ACTIVE_TAB_LABEL)
        FileManager.onPathChanged(fm, "/library/Nonfiction/History")
        assert.are.equal("Nonfiction", _G.__ZEN_UI_ACTIVE_TAB_LABEL)
    end)

    it("opens a specific tag for non-navbar destination buttons", function()
        make_instance()
        calls = {}

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAG("Science"))

        assert.are.same({ "tag:Science:tags" }, calls)
        assert.are.equal("Tags", _G.__ZEN_UI_ACTIVE_TAB_LABEL)
    end)

    it("reveals a deferred FileManager for tabs configured as folder destinations", function()
        local fm = make_instance()
        local fc = fm.file_chooser
        _G.__ZEN_UI_PLUGIN.config.navbar.folder_path = "/library"
        _G.__ZEN_UI_PLUGIN.config.navbar.manga_action = "folder"
        _G.__ZEN_UI_PLUGIN.config.navbar.manga_folder = "/library/Manga"
        dir_mtimes["/library/Manga"] = 10
        fm.invisible = true
        fm._zen_hidden_home_startup = true
        fc._zen_hidden_home_startup = true
        fc._zen_needs_full_listing = true
        fc.changeToPath = function(self, path)
            calls[#calls + 1] = "books:" .. path
            self.path = path
            FileManager.onPathChanged(fm, path)
        end
        UIManager._window_stack = {
            { widget = fm },
            { widget = home_widget },
        }
        calls = {}

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("manga"))

        assert.are.same({ "books:/library/Manga" }, calls)
        assert.is_nil(fm.invisible)
        assert.is_nil(fm._zen_hidden_home_startup)
        assert.is_nil(fc._zen_hidden_home_startup)
        assert.is_nil(fc._zen_needs_full_listing)
        assert.are.equal("Manga", _G.__ZEN_UI_ACTIVE_TAB_LABEL)
        assert.are.equal(0, full_repaints)
    end)

    it("handles a cold Folder tap from the live Home navbar", function()
        local fm = make_instance()
        local fc = fm.file_chooser
        local wrapper = {
            invisible = true,
            _zen_hidden_home_startup = true,
        }
        local rendered_paths = {}
        fm.show_parent = wrapper
        fm[1] = { fc }
        fc.show_parent = wrapper
        fm.invisible = true
        fm._zen_hidden_home_startup = true
        fc.path = "/library"
        fc._zen_hidden_home_startup = true
        fc._zen_needs_full_listing = true
        fc.refreshPath = function(self)
            calls[#calls + 1] = "refresh:" .. self.path
            self.item_table = { { path = "/library/Book.epub" } }
        end
        fc.changeToPath = function(self, path)
            calls[#calls + 1] = "books:" .. path
            self.path = path
            FileManager.onPathChanged(fm, path)
        end
        fc.onGotoPage = function(_, page)
            calls[#calls + 1] = "page:" .. page
        end
        fc._zen_discard_prepared_item_table = function()
            calls[#calls + 1] = "discard_prepared"
        end
        dir_mtimes["/library/Fiction"] = 10
        local navbar_config = _G.__ZEN_UI_PLUGIN.config.navbar
        navbar_config.tab_order = { "home", "folder" }
        UIManager.setDirty = function(_self, widget)
            if (widget == fm or widget == wrapper) and widget.invisible ~= true then
                rendered_paths[#rendered_paths + 1] = fc.path
            end
        end

        local home_menu
        home_show_callback = function(inject)
            home_menu = {
                name = "home",
                dimen = { w = 800, h = 600 },
                inner_dimen = { w = 800, h = 600 },
                close_callback = function() calls[#calls + 1] = "home_close" end,
                [1] = {
                    dimen = { w = 800, h = 560 },
                    inner_dimen = { w = 800, h = 560 },
                    resetLayout = function() end,
                },
            }
            inject(home_menu, "home")
        end

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("home"))
        local navbar = home_menu[1][1][2]
        calls = {}

        assert.is_true(navbar:onTapNavBar(nil, { pos = { x = 600, y = 1 } }))

        assert.are.same({
            "home_close",
            "discard_prepared",
            "books:/library/Fiction",
            "discard_prepared",
        }, calls)
        assert.are.equal("/library/Fiction", fc.path)
        assert.is_nil(fm.invisible)
        assert.is_nil(fm._zen_hidden_home_startup)
        assert.is_nil(fc._zen_hidden_home_startup)
        assert.is_nil(wrapper.invisible)
        assert.is_nil(wrapper._zen_hidden_home_startup)
        assert.are.equal("Folder", _G.__ZEN_UI_ACTIVE_TAB_LABEL)
        assert.are.same({ "/library/Fiction" }, rendered_paths)
        assert.are.equal(0, full_repaints)

        local filemanager_navbar = fm[1][1][2]
        calls = {}
        assert.is_true(filemanager_navbar:onTapNavBar(nil, { pos = { x = 600, y = 1 } }))
        assert.are.same({ "page:1", "discard_prepared" }, calls)
        assert.are.equal("Folder", _G.__ZEN_UI_ACTIVE_TAB_LABEL)
    end)

    it("falls back to a usable Library when a configured folder is missing", function()
        local fm = make_instance()
        local fc = fm.file_chooser
        _G.__ZEN_UI_PLUGIN.config.navbar.manga_action = "folder"
        _G.__ZEN_UI_PLUGIN.config.navbar.manga_folder = "/library/Missing"
        fm.invisible = true
        fm._zen_hidden_home_startup = true
        fc._zen_hidden_home_startup = true
        fc._zen_needs_full_listing = true
        calls = {}

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("manga"))

        assert.are.same({ "books:/library" }, calls)
        assert.is_nil(fm.invisible)
        assert.is_nil(fm._zen_hidden_home_startup)
        assert.is_nil(fc._zen_hidden_home_startup)
        assert.is_nil(fc._zen_needs_full_listing)
        assert.are.equal("Library", _G.__ZEN_UI_ACTIVE_TAB_LABEL)
        assert.are.equal(0, full_repaints)
    end)

    it("does not reopen the navbar page already on top", function()
        make_instance()
        UIManager._window_stack = {
            { widget = { _zen_navbar_tab_id = "authors" } },
        }

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("authors"))
        assert.are.same({}, calls)
    end)

    it("opens a custom tag tab directly in that tag's detail view", function()
        local navbar = _G.__ZEN_UI_PLUGIN.config.navbar
        navbar.custom_tabs = {
            { id = "ct_tag", type = "tag", tag = "Science", label = "Science" },
        }
        navbar.show_tabs.ct_tag = true
        table.insert(navbar.tab_order, "ct_tag")
        local fm = make_instance()
        fm[1] = { fm.file_chooser }
        _G.__ZEN_UI_REINJECT_FM_NAVBAR()
        calls = {}

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("ct_tag"))
        assert.are.same({ "tag:Science:ct_tag" }, calls)
        assert.are.equal("Science", _G.__ZEN_UI_ACTIVE_TAB_LABEL)
    end)

    it("launches available native menu tabs and retains unavailable ones", function()
        local navbar = _G.__ZEN_UI_PLUGIN.config.navbar
        navbar.custom_tabs = {
            {
                id = "ct_network",
                type = "koreader_menu",
                label = "Network",
                koreader_menu = { id = "network", title = "Network" },
            },
        }
        navbar.show_tabs.ct_network = true
        table.insert(navbar.tab_order, "ct_network")
        local fm = make_instance()
        fm[1] = { fm.file_chooser }
        _G.__ZEN_UI_REINJECT_FM_NAVBAR()

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("ct_network"))
        assert.are.same({ "network:filemanager" }, native_launches)

        native_available = false
        _G.__ZEN_UI_REINJECT_FM_NAVBAR()
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("ct_network"))
        assert.are.same({ "network:filemanager" }, native_launches)
    end)

    it("does not repaint the covered file manager for overlay tabs", function()
        local fm = make_instance()
        local dirty = {}
        UIManager.setDirty = function(_self, widget, mode)
            dirty[#dirty + 1] = { widget = widget, mode = mode }
        end

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("authors"))
        for _i, entry in ipairs(dirty) do
            assert.are_not.equal(fm, entry.widget)
        end

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("books"))
        local file_manager_dirty
        for _i, entry in ipairs(dirty) do
            if entry.widget == fm then file_manager_dirty = entry end
        end
        assert.are.equal(fm, file_manager_dirty.widget)
        assert.are.equal("ui", file_manager_dirty.mode)
    end)

    it("prewarms enabled group tabs after Home becomes visible", function()
        local scheduled = {}
        local warmed = {}
        UIManager.scheduleIn = function(_self, delay, callback)
            scheduled[#scheduled + 1] = { delay = delay, callback = callback }
        end
        ZenSpec.replace("bookinfomanager", {
            isExtractingInBackground = function() return false end,
        })
        ZenSpec.replace("common/db_bookinfo", {
            getGroupedByAuthor = function() warmed[#warmed + 1] = "authors" end,
            getGroupedBySeries = function() warmed[#warmed + 1] = "series" end,
            getGroupedByTags = function() warmed[#warmed + 1] = "tags" end,
        })

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("home"))
        assert.are.equal(0.75, scheduled[1].delay)
        while #scheduled > 0 do
            table.remove(scheduled, 1).callback()
        end

        assert.are.same({ "authors", "series", "tags" }, warmed)
    end)

    it("does not prewarm group tabs on constrained devices", function()
        local scheduled = {}
        allow_group_prewarm = false
        UIManager.scheduleIn = function(_self, delay, callback)
            scheduled[#scheduled + 1] = { delay = delay, callback = callback }
        end

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("home"))
        assert.are.same({}, scheduled)
    end)

    it("resets strip pages when Home is already on top", function()
        make_instance()
        shared.home.isActiveOnTop = function() return true end
        shared.home.resetStripPages = function() calls[#calls + 1] = "reset_strips" end

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("home"))
        assert.are.same({ "reset_strips" }, calls)
    end)

    it("raises an existing Home view instead of rebuilding it", function()
        make_instance()
        local covering_widget = {}
        UIManager._window_stack = {
            { widget = home_widget },
            { widget = covering_widget },
        }
        calls = {}

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("home"))

        assert.are.equal(home_widget, UIManager._window_stack[#UIManager._window_stack].widget)
        assert.are.same({}, calls)
    end)

    it("retains Home below Library and resumes the same view", function()
        local fm = make_instance()
        fm.file_chooser.path = "/library"
        fm.file_chooser.page = 2
        fm.file_chooser.item_table = { { path = "/library/Book.epub" } }
        dir_mtimes["/library"] = 10
        shared.home.isActiveOnTop = function()
            local top = UIManager._window_stack[#UIManager._window_stack]
            return top and top.widget == home_widget
        end
        shared.home.suspendActive = function()
            calls[#calls + 1] = "suspend_home"
            return true
        end
        shared.home.resumeActive = function()
            calls[#calls + 1] = "resume_home"
            return true, "reused"
        end
        UIManager._window_stack = {
            { widget = fm },
            { widget = home_widget },
        }
        calls = {}

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("books"))
        assert.are.equal(fm, UIManager._window_stack[#UIManager._window_stack].widget)
        assert.are.same({ "suspend_home" }, calls)

        calls = {}
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("home"))
        assert.are.equal(home_widget,
            UIManager._window_stack[#UIManager._window_stack].widget)
        assert.are.same({ "resume_home" }, calls)

        local reveal
        for _i, measurement in ipairs(measurements) do
            if measurement.message == "Library to Home first reveal" then
                reveal = measurement
            end
        end
        assert.is_table(reveal)
        assert.are.same({ "mode=", "retained", "view_reused=", "true" },
            reveal.details)
    end)

    it("uses flashui between Library and Home", function()
        local fm = make_instance()
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("books"))
        fm.file_chooser.path = "/library"
        fm.file_chooser.item_table = { { path = "/library/Book.epub" } }
        dir_mtimes["/library"] = 10
        UIManager._window_stack = {
            { widget = fm },
            { widget = home_widget },
        }
        local flash_count = 0
        UIManager.setDirty = function(_self, _widget, mode)
            if mode == "flashui" then flash_count = flash_count + 1 end
        end

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("home"))
        assert.are.equal(1, flash_count)
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("books"))
        assert.are.equal(2, flash_count)
    end)

    it("reveals a reinitialized hidden FileManager before handling Library taps", function()
        local fm = make_instance()
        fm.invisible = true
        fm._zen_hidden_home_startup = true
        fm.file_chooser = {
            path = "/library",
            path_items = {},
            item_table = { { path = "/library/Book.epub" } },
            page = 1,
        }
        dir_mtimes["/library"] = 10
        shared.home.isActiveOnTop = function()
            local top = UIManager._window_stack[#UIManager._window_stack]
            return top and top.widget == home_widget
        end
        shared.home.suspendActive = function() return true end
        local taps = 0
        fm.handleEvent = function(_, event)
            taps = taps + 1
            return event.name == "Gesture"
        end
        UIManager._window_stack = {
            { widget = fm },
            { widget = home_widget },
        }
        local reveal
        UIManager.setDirty = function(_self, widget, mode)
            local top = UIManager._window_stack[#UIManager._window_stack]
            reveal = {
                widget = widget,
                mode = mode,
                top = top and top.widget,
                invisible = widget and widget.invisible,
            }
        end

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("books"))

        assert.is_nil(fm.invisible)
        assert.is_nil(fm._zen_hidden_home_startup)
        assert.are.same({
            mode = "flashui",
            top = fm,
        }, reveal)
        local top = UIManager._window_stack[#UIManager._window_stack].widget
        assert.is_true(top:handleEvent({ name = "Gesture" }))
        assert.are.equal(1, taps)
    end)

    it("uses the wrapped FileManager stack anchor when preserving Home", function()
        local fm = make_instance()
        local wrapper = {}
        fm.show_parent = wrapper
        fm.file_chooser.path = "/library"
        fm.file_chooser.page = 1
        fm.file_chooser.item_table = { { path = "/library/Book.epub" } }
        dir_mtimes["/library"] = 10
        shared.home.isActiveOnTop = function()
            local top = UIManager._window_stack[#UIManager._window_stack]
            return top and top.widget == home_widget
        end
        shared.home.suspendActive = function() return true end
        UIManager._window_stack = {
            { widget = wrapper },
            { widget = home_widget },
        }
        local close_anchor
        package.loaded["common/utils"].closeWidgetsAbove = function(anchor)
            close_anchor = anchor
        end

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("books"))

        assert.are.equal(wrapper, close_anchor)
        assert.are.equal(home_widget, UIManager._window_stack[1].widget)
        assert.are.equal(wrapper, UIManager._window_stack[2].widget)
    end)

    it("records a real navbar tap to retained Home without a forced full repaint", function()
        local fm = make_instance()
        fm.file_chooser.path = "/library"
        fm.file_chooser.page = 1
        fm.file_chooser.item_table = { { path = "/library/Book.epub" } }
        fm[1] = { fm.file_chooser }
        dir_mtimes["/library"] = 10
        shared.home.isActiveOnTop = function()
            local top = UIManager._window_stack[#UIManager._window_stack]
            return top and top.widget == home_widget
        end
        shared.home.suspendActive = function() return true end
        shared.home.resumeActive = function()
            calls[#calls + 1] = "resume_home"
            UIManager:setDirty(home_widget, "ui")
            return true, "reused"
        end
        UIManager._window_stack = {
            { widget = fm },
            { widget = home_widget },
        }
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("books"))
        _G.__ZEN_UI_REINJECT_FM_NAVBAR()
        local navbar = fm[1][1][2]
        assert.is_table(navbar)
        assert.is_function(navbar.onTapNavBar)

        local dirty = {}
        local force_repaints = 0
        UIManager.setDirty = function(_self, widget, mode)
            dirty[#dirty + 1] = { widget = widget, mode = mode }
        end
        UIManager.forceRePaint = function() force_repaints = force_repaints + 1 end
        calls = {}
        assert.is_true(navbar:onTapNavBar(nil, { pos = { x = 50, y = 1 } }))

        assert.are.same({ "resume_home" }, calls)
        assert.are.equal(0, force_repaints)
        for _i, entry in ipairs(dirty) do
            assert.is_false(entry.widget == nil and entry.mode == "full")
        end
        local reveal
        for _i, measurement in ipairs(measurements) do
            if measurement.message == "Library to Home first reveal" then
                reveal = measurement
            end
        end
        assert.is_table(reveal)
        assert.are.equal("retained", measurement_detail(reveal, "mode="))
    end)

    it("keeps the screen-edge navbar dead zones", function()
        local fm = make_instance()
        fm[1] = { fm.file_chooser }
        _G.__ZEN_UI_REINJECT_FM_NAVBAR()
        local navbar = fm[1][1][2]

        calls = {}
        assert.is_false(navbar:onTapNavBar(nil, { pos = { x = 1, y = 1 } }))
        assert.is_false(navbar:onTapNavBar(nil, { pos = { x = 799, y = 1 } }))
        assert.are.same({}, calls)
    end)

    it("activates a focused file-manager navbar tab on Press", function()
        device_has_keys = true
        local fm = make_instance()
        local fc = fm.file_chooser
        local focus_events = {}
        local content_moves = 0
        local content_presses = 0
        local first_item = {}
        local last_item = {
            handleEvent = function(_self, event)
                focus_events[#focus_events + 1] = event.name
                return true
            end,
        }
        fc.onFocusMove = function(self, args)
            content_moves = content_moves + 1
            self.selected.y = self.selected.y + (args[2] or 0)
            return true
        end
        fc.onPress = function()
            content_presses = content_presses + 1
            return true
        end
        fm[1] = { fc }
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("books"))
        fc.selected = { x = 1, y = 1 }
        fc.layout = { { first_item }, { last_item } }
        calls = {}

        assert.is_true(fc:onFocusMove({ 0, 1 }))
        assert.are.equal(1, content_moves)
        assert.is_true(fc:onFocusMove({ 0, 1 }))
        assert.are.same({ "Unfocus" }, focus_events)
        assert.is_true(fc:onFocusMove({ 0, -1 }))
        assert.are.same({ "Unfocus", "Focus" }, focus_events)
        assert.is_true(fc:onPress())
        assert.are.equal(1, content_presses)
        assert.is_true(fc:onFocusMove({ 0, 1 }))
        assert.is_true(fc:onFocusMove({ -1, 0 }))
        assert.is_true(fc:onPress())

        assert.are.same({ "home" }, calls)
    end)

    it("activates a focused standalone navbar tab on Press", function()
        device_has_keys = true
        local fm = make_instance()
        fm[1] = { fm.file_chooser }
        local home_menu
        local focus_events = {}
        local content_moves = 0
        local content_presses = 0
        home_show_callback = function(inject)
            local body = {
                dimen = { w = 800, h = 560 },
                inner_dimen = { w = 800, h = 560 },
                resetLayout = function() end,
            }
            local first_item = {}
            local last_item = {
                handleEvent = function(_self, event)
                    focus_events[#focus_events + 1] = event.name
                    return true
                end,
            }
            home_menu = {
                name = "home",
                dimen = { w = 800, h = 600 },
                inner_dimen = { w = 800, h = 600 },
                updateItems = function() end,
                selected = { x = 1, y = 1 },
                layout = { { first_item }, { last_item } },
                onFocusMove = function(self, args)
                    content_moves = content_moves + 1
                    self.selected.y = self.selected.y + (args[2] or 0)
                    return true
                end,
                onPress = function()
                    content_presses = content_presses + 1
                    return true
                end,
                [1] = body,
            }
            inject(home_menu, "home")
        end
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("books"))
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("home"))
        calls = {}

        assert.is_true(home_menu:onZenNavbarFocusDown())
        assert.are.equal(1, content_moves)
        assert.is_true(home_menu:onFocusMove({ 0, 1 }))
        assert.are.same({ "Unfocus" }, focus_events)
        assert.is_true(home_menu:onFocusMove({ 0, -1 }))
        assert.are.same({ "Unfocus", "Focus" }, focus_events)
        assert.is_true(home_menu:onZenNavbarConfirm())
        assert.are.equal(1, content_presses)
        assert.is_true(home_menu:onFocusMove({ 0, 1 }))
        assert.is_true(home_menu:onFocusMove({ 1, 0 }))
        assert.is_true(home_menu:onPress())

        assert.are.same({ "books:/library" }, calls)
    end)

    it("opens the top menu from the physical Menu key on standalone pages", function()
        device_has_keys = true
        local fm = make_instance()
        fm[1] = { fm.file_chooser }
        fm.menu = {
            onShowMenu = function()
                calls[#calls + 1] = "top_menu"
                return true
            end,
        }
        local home_menu
        home_show_callback = function(inject)
            home_menu = {
                name = "home",
                dimen = { w = 800, h = 600 },
                inner_dimen = { w = 800, h = 600 },
                updateItems = function() end,
                [1] = {
                    dimen = { w = 800, h = 560 },
                    inner_dimen = { w = 800, h = 560 },
                    resetLayout = function() end,
                },
            }
            inject(home_menu, "home")
        end
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("home"))
        calls = {}

        assert.is_true(home_menu:onKeyPress({
            match = function(_self, sequence) return sequence[1] == "Menu" end,
        }))

        assert.are.same({ "top_menu" }, calls)
    end)

    it("uses rendered tab centers when tapping a standalone navbar background", function()
        local fm = make_instance()
        fm[1] = { fm.file_chooser }
        local navbar_config = _G.__ZEN_UI_PLUGIN.config.navbar
        navbar_config.show_tabs.stats = true
        navbar_config.tab_order = { "home", "books", "authors", "stats", "to_be_read" }

        local stats_page = {
            name = "stats",
            dimen = { w = 800, h = 600 },
            inner_dimen = { w = 800, h = 600 },
            border_size = 0,
            updateItems = function() calls[#calls + 1] = "stats_reset" end,
            { dimen = { w = 800, h = 580 } },
        }
        local stats_plugin
        ZenSpec.replace("modules/filebrowser/patches/stats_page", {
            create = function(_create_status_row, _repaint_title_bar, plugin)
                stats_plugin = plugin
                return stats_page, true
            end,
        })

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("stats"))
        assert.are.equal(_G.__ZEN_UI_PLUGIN, stats_plugin)
        local navbar = stats_page[1][1][2]
        calls = {}

        assert.is_true(navbar:onTapNavBar(nil, { pos = { x = 620, y = 1 } }))
        assert.are.same({ "to_be_read" }, calls)
    end)

    it("dispatches books and stock file-browser tabs to their intended actions", function()
        make_instance()
        for _i, id in ipairs({
            "books", "history", "favorites", "collections", "search",
            "page_left", "page_right", "menu",
        }) do
            assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB(id))
        end
        assert.are.same({
            "books:/library", "history", "favorites", "collections", "search",
            "previous", "next", "menu",
        }, calls)
        assert.are.equal("Collections", _G.__ZEN_UI_ACTIVE_TAB_LABEL)
    end)

    it("returns an open collection to the collections root on an active-tab tap", function()
        local fm = make_instance()
        local restored_item = { _underline_container = { color = "black" } }
        local collection_root = { layout = { { restored_item } } }
        shared.hideMenuUnderlines = function(menu)
            calls[#calls + 1] = "underlines_hidden"
            menu.layout[1][1]._underline_container.color = "white"
        end
        _G.__ZEN_UI_PLUGIN.config.features.browser_hide_underline = true
        local detail = {
            name = "collections",
            page = 2,
            dimen = { w = 800, h = 600 },
            inner_dimen = { w = 800, h = 600 },
            onReturn = function()
                calls[#calls + 1] = "collection_root"
                fm.collections.coll_list = collection_root
            end,
            close_callback = function() calls[#calls + 1] = "collections_closed" end,
            updateItems = function() calls[#calls + 1] = "detail_reset" end,
            [1] = {
                dimen = { w = 800, h = 560 },
                inner_dimen = { w = 800, h = 560 },
                resetLayout = function() end,
            },
        }
        detail._manager = fm.collections
        fm.collections.coll_list = {}
        fm.collections.booklist_menu = detail

        local FileManagerCollection = require("apps/filemanager/filemanagercollection")
        FileManagerCollection.onShowColl(fm.collections, "Reading")
        local navbar = detail[1][1][2]
        navbar.getTappedTabId = function() return "collections" end
        calls = {}

        assert.is_true(navbar:onTapNavBar(nil, { pos = { x = 400, y = 1 } }))
        assert.are.same({ "collection_root", "underlines_hidden" }, calls)
        assert.are.equal("white", restored_item._underline_container.color)
        assert.are.equal(2, detail.page)
    end)

    it("reveals the current Library page without scheduling a full-screen repaint", function()
        local fm = make_instance()
        fm.file_chooser.path = "/library"
        fm.file_chooser.onGotoPage = function(_, page)
            calls[#calls + 1] = "goto:" .. tostring(page)
        end
        local next_ticks = {}
        local dirty = {}
        local force_repaints = 0
        UIManager.nextTick = function(_, callback) next_ticks[#next_ticks + 1] = callback end
        UIManager.setDirty = function(_self, widget, mode)
            dirty[#dirty + 1] = { widget = widget, mode = mode }
        end
        UIManager.forceRePaint = function() force_repaints = force_repaints + 1 end
        calls = {}

        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("books"))
        assert.are.same({ "goto:1" }, calls)
        assert.are.equal(1, #next_ticks)
        table.remove(next_ticks, 1)()
        for _i, entry in ipairs(dirty) do
            assert.is_false(entry.widget == nil and entry.mode == "full")
        end
        assert.are.equal(0, force_repaints)
    end)

    it("rejects unknown tab ids without changing the active tab", function()
        make_instance()
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("authors"))
        assert.is_false(_G.__ZEN_UI_NAVBAR_OPEN_TAB("not-a-tab"))
        assert.are.equal("Authors", _G.__ZEN_UI_ACTIVE_TAB_LABEL)
    end)

    it("uses the library face at the navbar's configured label size", function()
        local fm = make_instance()
        fm[1] = { fm.file_chooser }
        _G.__ZEN_UI_REINJECT_FM_NAVBAR()
        local used_configured_size = false
        for _i, size in ipairs(library_font_sizes) do
            if size == 17 then used_configured_size = true end
        end
        assert.is_true(used_configured_size)
    end)

    it("captures the active view and closes library overlays before Reader opens", function()
        local fm = make_instance()
        _G.__ZEN_UI_PLUGIN.config.features.restore_library_view = true
        assert.is_true(_G.__ZEN_UI_NAVBAR_OPEN_TAB("series"))
        shared.group_view.getActivePage = function(tab_id)
            assert.are.equal("series", tab_id)
            return 4
        end
        shared.group_view.getActiveDetail = function()
            return { group_name = "Saga", page = 3 }
        end
        calls = {}

        FileManager.onShowingReader(fm)

        assert.are.same({ "close_groups", "close_home" }, calls)
        assert.are.equal("series", _G.__ZEN_UI_LIBRARY_STATE.tab)
        assert.are.equal(4, _G.__ZEN_UI_LIBRARY_STATE.page)
        assert.are.equal("Saga", _G.__ZEN_UI_LIBRARY_STATE.detail_group)
        assert.are.equal(3, _G.__ZEN_UI_LIBRARY_STATE.detail_page)
    end)

    it("defers FileManager listing before opening Home after Reader closes", function()
        local fm = make_instance()
        _G.__ZEN_UI_OPEN_HOME_AFTER_FILEMANAGER = true
        calls = {}

        FileManager.showFiles(fm, "/library/subfolder", "/library/Book.epub")

        assert.are.same({ "base:/library:nil", "home" }, calls)
        assert.is_true(base_observation.hidden)
        assert.are.equal("/library", base_observation.deferred.path)
        assert.is_true(fm.invisible)
        assert.is_true(fm.file_chooser._zen_needs_full_listing)
        assert.is_nil(fm.file_chooser._zen_needs_cover_refresh)
        assert.are.equal("Home", _G.__ZEN_UI_ACTIVE_TAB_LABEL)
    end)
end)
