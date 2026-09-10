local function apply_navbar()
    -- Bottom nav bar for the KOReader File Manager.

    local Blitbuffer = require("ffi/blitbuffer")
    local Device = require("device")
    local FileManager = require("apps/filemanager/filemanager")
    local FileChooser = require("ui/widget/filechooser")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local IconWidget = require("ui/widget/iconwidget")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local LineWidget = require("ui/widget/linewidget")
    local TextWidget = require("ui/widget/textwidget")
    local Event = require("ui/event")
    local ffiUtil = require("ffi/util")
    local UIManager = require("ui/uimanager")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local library_font = require("modules/filebrowser/patches/library_font")
    local utils = require("common/utils")
    local paths = require("common/paths")
    local MemoryPolicy = require("common/memory_policy")
    local SharedState = require("common/shared_state")
    local ButtonModel = require("common/nav_button_model")
    local Kindle = require("modules/filebrowser/patches/kindle_virtual_library")
    local StandalonePage = require("modules/filebrowser/patches/standalone_page")
    local NativeMenu = require("modules/menu/app_launcher/native_menu")
    local PluginScan = require("modules/menu/app_launcher/plugin_scan")
    local Screen = Device.screen
    local _ = require("gettext")
    local lfs = require("libs/libkoreader-lfs")
    local zen_logger = require("common/zen_logger")
    local logger = zen_logger.new("navbar")
    local now = zen_logger.now or os.clock

    local function getRakuyomi()
        return rawget(_G, "__ZEN_UI_RAKUYOMI") or {}
    end

    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    if not zen_plugin or type(zen_plugin.config) ~= "table" then
        return
    end

    local function get_shared(key)
        return SharedState.get(zen_plugin, key)
    end

    local _icons_dir
    do
        local root = require("common/plugin_root")
        if root then _icons_dir = root .. "/icons/" end
    end

    local function is_navbar_enabled()
        local features = zen_plugin.config and zen_plugin.config.features
        return type(features) == "table" and features.navbar == true
    end

    local function is_restore_enabled()
        local features = zen_plugin.config and zen_plugin.config.features
        return type(features) == "table" and features.restore_library_view == true
    end

    local function rakuyomi_return_to_chapter_list_on_exit_enabled()
        local rakuyomi = zen_plugin.config and zen_plugin.config.rakuyomi
        if type(rakuyomi) ~= "table" then return true end
        if rakuyomi.return_to_chapter_list_on_exit ~= nil then
            return rakuyomi.return_to_chapter_list_on_exit ~= false
        end
        if rakuyomi.return_to_chapter_list_on_reader_exit ~= nil then
            return rakuyomi.return_to_chapter_list_on_reader_exit ~= false
        end
        return true
    end

    -- === Layout constants ===

    local navbar_icon_size = Screen:scaleBySize(34)
    local navbar_v_padding = Screen:scaleBySize(4)
    local navbar_icon_size_default = 34
    local navbar_label_size_default = 20
    local navbar_icon_size_min, navbar_icon_size_max = 24, 48
    local navbar_label_size_min, navbar_label_size_max = 10, 28
    -- Dead zone at left/right edges to avoid stealing corner gesture taps
    local corner_dead_zone = math.floor(Screen:getWidth() / 20)
    local underline_thickness = Screen:scaleBySize(2)

    local function clampNavbarSize(value, min_value, max_value, default_value)
        value = math.floor((tonumber(value) or default_value) + 0.5)
        return math.max(min_value, math.min(max_value, value))
    end

    -- === Persistent config ===

    local config_default = {
        show_tabs = {
            books = true,
            folder = false,
            kindle = false,
            manga = true,
            news = true,
            continue = true,
            history = false,
            favorites = false,
            collections = false,
            authors = false,
            series = false,
            languages = false,
            tags = false,
            to_be_read = false,
            home = true,
            search = false,
            calibre_search = false,
            stats = false,
            exit = false,
            page_left = false,
            page_right = false,
            menu = false,
        },
        tab_order = { "books", "manga", "news", "continue", "home" },
        show_icons = true,
        show_labels = true,
        icon_size = navbar_icon_size_default,
        label_size = navbar_label_size_default,
        books_label = "",  -- empty = auto-translated "Library"
        home_label = "",   -- empty = auto-translated "Home"
        default_tab = "books",
        folder_path = "",
        folder_label = "",
        folder_icon = "tab_folder",
        manga_action = "rakuyomi",
        manga_folder = "",
        news_action = "quickrss",
        news_folder = "",
        colored = false,
        active_tab_color = {0x33, 0x99, 0xFF}, -- blue
        active_tab_underline = true,
        underline_above = false,
        show_top_border = false,
        layout_version = 2,
    }

    local function loadConfig()
        local config = zen_plugin.config.navbar or {}
        local legacy_layout = config.layout_version ~= 2
        for k, v in pairs(config_default) do
            if config[k] == nil then
                config[k] = utils.deepcopy(v)
            end
        end
        if type(config.show_tabs) == "table" then
            for k, v in pairs(config_default.show_tabs) do
                if config.show_tabs[k] == nil then
                    config.show_tabs[k] = v
                end
            end
        else
            config.show_tabs = config_default.show_tabs
        end
        if legacy_layout then
            local selected = {}
            local seen = {}
            local custom_ids = {}
            for _i, tab in ipairs(config.custom_tabs or {}) do
                if type(tab.id) == "string" then custom_ids[tab.id] = true end
            end
            for _i, id in ipairs(config.tab_order or {}) do
                if (config.show_tabs[id] == true or custom_ids[id]) and not seen[id] then
                    selected[#selected + 1] = id
                    seen[id] = true
                end
            end
            config.tab_order = selected
            config.layout_version = 2
        elseif type(config.tab_order) ~= "table" then
            config.tab_order = config_default.tab_order
        else
            local order_set = {}
            local deduped = {}
            for _i, id in ipairs(config.tab_order) do
                if not order_set[id] then
                    order_set[id] = true
                    deduped[#deduped + 1] = id
                end
            end
            config.tab_order = deduped
        end
        config.icon_size = clampNavbarSize(
            config.icon_size,
            navbar_icon_size_min,
            navbar_icon_size_max,
            navbar_icon_size_default)
        config.label_size = clampNavbarSize(
            config.label_size,
            navbar_label_size_min,
            navbar_label_size_max,
            navbar_label_size_default)
        -- migrate old hard-coded English default
        if config.books_label == "Library" then config.books_label = "" end
        if config.home_label == "Home" then config.home_label = "" end
        zen_plugin.config.navbar = config
        if legacy_layout and type(zen_plugin.saveConfig) == "function" then
            zen_plugin:saveConfig()
        end
        return config
    end

    local config = loadConfig()

    -- === Tab definitions ===

    local function getBooksLabel()
        return config.books_label ~= "" and config.books_label or _("Library")
    end

    local function getHomeLabel()
        return config.home_label ~= "" and config.home_label or _("Home")
    end

    local function getFolderLabel()
        return config.folder_label ~= "" and config.folder_label or _("Folder")
    end

    local function getFolderIcon()
        return type(config.folder_icon) == "string" and config.folder_icon ~= ""
            and config.folder_icon or "tab_folder"
    end

    local tabs = {
        {
            id = "books",
            label = getBooksLabel(),
            icon = "library",
        },
        {
            id = "folder",
            label = getFolderLabel(),
            icon = getFolderIcon(),
        },
        {
            id = "kindle",
            label = _("Kindle Library"),
            icon = utils.resolveLocalIcon(_icons_dir, "library"),
        },
        {
            id = "manga",
            label = _("Manga"),
            icon = "tab_manga",
        },
        {
            id = "news",
            label = _("News"),
            icon = "tab_news",
        },
        {
            id = "continue",
            label = _("Continue"),
            icon = "book.opened",
        },
        {
            id = "history",
            label = _("History"),
            icon = "tab_history",
        },
        {
            id = "favorites",
            label = _("Favorites"),
            icon = "star.empty",
        },
        {
            id = "collections",
            label = _("Collections"),
            icon = "tab_collections",
        },
        {
            id = "authors",
            label = _("Authors"),
            icon = "tab_authors",
        },
        {
            id = "series",
            label = _("Series"),
            icon = "tab_series",
        },
        {
            id = "languages",
            label = _("Languages"),
            icon = "tab_translate",
        },
        {
            id = "tags",
            label = _("Tags"),
            icon = "tab_tags",
        },
        {
            id = "to_be_read",
            label = _("To Be Read"),
            icon = "tab_to_be_read",
        },
        {
            id = "home",
            label = getHomeLabel(),
            icon = "home",
        },
        {
            id = "search",
            label = _("Search"),
            icon = "appbar.search",
        },
        {
            id = "calibre_search",
            label = _("Search"),
            icon = "appbar.search",
        },
        {
            id = "stats",
            label = _("Stats"),
            icon = "tab_stats",
        },
        {
            id = "exit",
            label = _("Exit"),
            icon = "tab_exit",
        },
        {
            id = "page_left",
            label = _("Prev"),
            icon = "tab_left",
        },
        {
            id = "page_right",
            label = _("Next"),
            icon = "tab_right",
        },
        {
            id = "menu",
            label = _("Menu"),
            icon = "appbar.menu",
        },
    }

    local tabs_by_id = {}
    for _i, tab in ipairs(tabs) do
        tabs_by_id[tab.id] = tab
    end

    -- === Active tab tracking ===

    local active_tab
    local _navbar_focused_idx = nil  -- keyboard-focused tab index (nil = file list has focus)
    local _last_menu_item = nil  -- tracks last long-held item for the menu tab

    local function setSelectedWidgetFocus(owner, focused)
        local selected = owner and owner.selected
        local row = selected and owner.layout and owner.layout[selected.y]
        local widget = row and row[selected.x]
        if not (widget and type(widget.handleEvent) == "function") then return false end
        widget:handleEvent(Event:new(focused and "Focus" or "Unfocus"))
        return true
    end

    local skip_tabs_for_state = {
        books = true, kindle = true, manga = true, news = true,
        folder = true, continue = true, search = true, stats = true, exit = true,
    }
    local group_view_tabs = {
        authors = true, series = true, languages = true, tags = true, to_be_read = true,
    }

    local function getCustomTagTab(tab_id)
        if type(config.custom_tabs) ~= "table" then return nil end
        for _i, tab in ipairs(config.custom_tabs) do
            if type(tab) == "table" and tab.id == tab_id and tab.type == "tag"
                    and type(tab.tag) == "string"
                    and tab.tag ~= "" then
                return tab
            end
        end
    end

    local function getCustomStatusTab(tab_id)
        if type(config.custom_tabs) ~= "table" then return nil end
        for _i, tab in ipairs(config.custom_tabs) do
            if type(tab) == "table" and tab.id == tab_id and tab.type == "status"
                    and ButtonModel.statusLabel(tab.status) then
                return tab
            end
        end
    end

    local function getCustomFolderTab(tab_id)
        if type(config.custom_tabs) ~= "table" then return nil end
        for _i, tab in ipairs(config.custom_tabs) do
            if type(tab) == "table" and tab.id == tab_id then
                if tab.type == "folder" and type(tab.folder) == "string"
                        and tab.folder ~= "" then
                    return tab, tab.folder
                end
                if tab.type == "action" then
                    local folder = ButtonModel.getFolderActionPath(tab.action)
                    if folder then return tab, folder end
                end
            end
        end
    end

    local function skipTabState(tab_id)
        return skip_tabs_for_state[tab_id] == true
            or getCustomFolderTab(tab_id) ~= nil
    end

    local function isGroupViewTab(tab_id)
        return group_view_tabs[tab_id] == true or getCustomTagTab(tab_id) ~= nil
            or getCustomStatusTab(tab_id) ~= nil
    end

    local function getGroupViewTab(tab_id)
        if getCustomTagTab(tab_id) then return "tags" end
        if getCustomStatusTab(tab_id) then return "status" end
        return tab_id
    end

    -- Forward declarations; defined later
    local injectNavbar
    local injectStandaloneNavbar
    local hookQuickRSSInit
    local getNavbarHeight
    local cancelHiddenLibraryWarm
    local materializeHiddenLibrary

    local function syncActiveTabLabel()
        _G.__ZEN_UI_ACTIVE_TAB_LABEL = tabs_by_id[active_tab] and tabs_by_id[active_tab].label or active_tab
    end

    local function normalizeFolderPath(path)
        if type(path) ~= "string" or path == "" then return nil end
        if type(paths.normPath) == "function" then path = paths.normPath(path) end
        path = ffiUtil.realpath(path) or path
        if type(paths.normPath) == "function" then path = paths.normPath(path) end
        if path ~= "/" then path = path:gsub("/+$", "") end
        return path ~= "" and path or "/"
    end

    local function isInFolderPath(path, folder_path)
        path = normalizeFolderPath(path)
        folder_path = normalizeFolderPath(folder_path)
        if not path or not folder_path then return false end
        return path == folder_path
            or folder_path == "/"
            or path:sub(1, #folder_path + 1) == folder_path .. "/"
    end

    local function tabStaysInFileManager(id)
        local custom_folder = getCustomFolderTab(id)
        return id == "books"
            or (id == "folder" and normalizeFolderPath(config.folder_path) ~= nil)
            or (id == "manga" and config.manga_action == "folder" and config.manga_folder ~= "")
            or (id == "news" and config.news_action == "folder" and config.news_folder ~= "")
            or custom_folder ~= nil
    end

    local function setActiveTab(id)
        local fm = FileManager.instance
        local fc = fm and fm.file_chooser
        local defer_hidden_folder = fm and id ~= "books"
            and tabStaysInFileManager(id)
            and fm.invisible == true
            and fc and fc._zen_needs_full_listing == true
        if fm and id == "books" and active_tab == "home" then
            local stack = UIManager._window_stack
            local top = stack and stack[#stack]
            local top_widget = top and top.widget
            local returning_from_home = fm._zen_hidden_home_startup == true
                or (fc and fc._zen_home_retained_library ~= nil)
                or (top_widget and (top_widget.name == "home"
                    or top_widget._zen_navbar_tab_id == "home"))
            if returning_from_home then
                fm._zen_home_to_library_started_at = now()
            end
        end
        if fm and id == "home" and active_tab == "books" then
            -- Startup's internal books-to-Home sync is not a visible transition.
            if fm.invisible ~= true and fm._zen_hidden_home_startup ~= true then
                fm._zen_library_to_home_started_at = now()
            else
                fm._zen_library_to_home_started_at = nil
            end
        end
        if fm and id ~= "home" and not defer_hidden_folder
                and cancelHiddenLibraryWarm then
            cancelHiddenLibraryWarm(fm, id == "books")
        end
        active_tab = id
        syncActiveTabLabel()
        _navbar_focused_idx = nil
        local stays_in_browser = tabStaysInFileManager(id)
        if fm and stays_in_browser and not defer_hidden_folder then
            injectNavbar(fm)
            UIManager:setDirty(fm, "ui")
        end
    end

    local _group_prewarm_pending = false
    local function scheduleGroupPrewarm()
        if _group_prewarm_pending or type(UIManager.scheduleIn) ~= "function" then return end
        if not MemoryPolicy.canPrewarmGroups() then return end
        local getters = {}
        if config.show_tabs.authors == true then getters[#getters + 1] = "getGroupedByAuthor" end
        if config.show_tabs.series == true then getters[#getters + 1] = "getGroupedBySeries" end
        if config.show_tabs.languages == true then
            getters[#getters + 1] = "getGroupedByLanguage"
        end
        local has_tag_tab = config.show_tabs.tags == true
        if type(config.custom_tabs) == "table" then
            for _i, tab in ipairs(config.custom_tabs) do
                if type(tab) == "table" and tab.type == "tag" and type(tab.id) == "string"
                        and config.show_tabs[tab.id] == true then
                    has_tag_tab = true
                    break
                end
            end
        end
        if has_tag_tab then getters[#getters + 1] = "getGroupedByTags" end
        if #getters == 0 then return end

        _group_prewarm_pending = true
        local index = 1
        local extraction_retries = 0
        local function step()
            if not MemoryPolicy.canPrewarmGroups() then
                _group_prewarm_pending = false
                return
            end
            local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
            if ok_bim and type(BookInfoManager.isExtractingInBackground) == "function"
                    and BookInfoManager:isExtractingInBackground() then
                extraction_retries = extraction_retries + 1
                if extraction_retries <= 10 then
                    UIManager:scheduleIn(0.4, step)
                    return
                end
                _group_prewarm_pending = false
                return
            end
            local ok_db, db = pcall(require, "common/db_bookinfo")
            local getter = ok_db and db and db[getters[index]]
            if type(getter) == "function" then pcall(getter) end
            index = index + 1
            if index <= #getters then
                UIManager:scheduleIn(0.05, step)
            else
                _group_prewarm_pending = false
            end
        end
        UIManager:scheduleIn(0.75, step)
    end

    local function withCoversSuppressed(fn)
        local old = rawget(_G, "__ZEN_UI_SUPPRESS_FILEMANAGER_COVERS")
        _G.__ZEN_UI_SUPPRESS_FILEMANAGER_COVERS = true
        local ok, result = pcall(fn)
        if old == nil then
            _G.__ZEN_UI_SUPPRESS_FILEMANAGER_COVERS = nil
        else
            _G.__ZEN_UI_SUPPRESS_FILEMANAGER_COVERS = old
        end
        if not ok then error(result) end
        return result
    end

    local function withHiddenHomeBootstrap(path, fn)
        local old_hidden = rawget(_G, "__ZEN_UI_HIDDEN_HOME_BOOTSTRAP")
        local old_listing = rawget(_G, "__ZEN_UI_DEFER_FILEMANAGER_LISTING")
        _G.__ZEN_UI_HIDDEN_HOME_BOOTSTRAP = true
        _G.__ZEN_UI_DEFER_FILEMANAGER_LISTING = { path = path }
        local ok, result = pcall(withCoversSuppressed, fn)
        _G.__ZEN_UI_HIDDEN_HOME_BOOTSTRAP = old_hidden
        _G.__ZEN_UI_DEFER_FILEMANAGER_LISTING = old_listing
        if not ok then error(result) end
        return result
    end

    local HIDDEN_LIBRARY_WARM_DELAY_S = 0.9
    local HIDDEN_LIBRARY_WARM_RETRY_S = 0.5
    local HIDDEN_LIBRARY_WARM_MAX_RETRIES = 5

    cancelHiddenLibraryWarm = function(fm, preserve_listing)
        local fc = fm and fm.file_chooser
        if fc and type(fc._zen_cancel_warm_cover_page) == "function" then
            fc:_zen_cancel_warm_cover_page("left_home")
        end
        if fc and type(fc._zen_cancel_hidden_folder_prewarm) == "function" then
            local mode = preserve_listing and "preserve" or "discard"
            local reason = preserve_listing and "library_reveal" or "left_home"
            fc:_zen_cancel_hidden_folder_prewarm(reason, mode)
        end
        if fc and not preserve_listing then
            if type(fc._zen_discard_prepared_item_table) == "function" then
                fc:_zen_discard_prepared_item_table()
            end
            fc._zen_idle_materialized_library = nil
            fc._zen_home_retained_library = nil
        end
        local pending = fm and fm._zen_hidden_library_warm_fn
        if not pending then return end
        fm._zen_hidden_library_warm_fn = nil
        if type(UIManager.unschedule) == "function" then
            UIManager:unschedule(pending)
        end
    end

    local function scheduleHiddenLibraryWarm(fm)
        local fc = fm and fm.file_chooser
        local home_dir = paths.getHomeDir()
        if not (fc and fc._zen_needs_full_listing and home_dir
                and type(fc._zen_warm_item_table) == "function"
                and MemoryPolicy.canPrewarmGroups()) then
            return false
        end
        cancelHiddenLibraryWarm(fm)
        local retry_count = 0
        local warm
        warm = function()
            if fm._zen_hidden_library_warm_fn ~= warm then return end
            local Home = get_shared("home")
            local stop_reason
            if FileManager.instance ~= fm then
                stop_reason = "filemanager_changed"
            elseif fm.file_chooser ~= fc then
                stop_reason = "filechooser_changed"
            elseif active_tab ~= "home" then
                stop_reason = "left_home"
            elseif not fc._zen_needs_full_listing then
                stop_reason = "listing_ready"
            elseif not MemoryPolicy.canPrewarmGroups() then
                stop_reason = "memory_pressure"
            end
            if stop_reason then
                fm._zen_hidden_library_warm_fn = nil
                logger.measure("Hidden Library listing warm skipped", 0,
                    "reason=", stop_reason,
                    "retries=", retry_count)
                return
            end
            local home_block_reason
            if not (Home and type(Home.isActiveOnTop) == "function") then
                home_block_reason = "home_unavailable"
            elseif not Home.isActiveOnTop() then
                home_block_reason = "home_not_top"
            end
            if home_block_reason then
                if retry_count < HIDDEN_LIBRARY_WARM_MAX_RETRIES then
                    retry_count = retry_count + 1
                    logger.measure("Hidden Library listing warm deferred", 0,
                        "reason=", home_block_reason,
                        "retry=", retry_count,
                        "max_retries=", HIDDEN_LIBRARY_WARM_MAX_RETRIES)
                    UIManager:scheduleIn(HIDDEN_LIBRARY_WARM_RETRY_S, warm)
                else
                    fm._zen_hidden_library_warm_fn = nil
                    logger.measure("Hidden Library listing warm skipped", 0,
                        "reason=", home_block_reason,
                        "retries=", retry_count)
                end
                return
            end
            fm._zen_hidden_library_warm_fn = nil
            local started_at = now()
            local items, detail = fc:_zen_warm_item_table(home_dir)
            detail = type(detail) == "table" and detail or {}
            local listing_prepared = type(items) == "table"
                and type(fc._zen_prepare_item_table) == "function"
                and fc:_zen_prepare_item_table(home_dir, items) == true
            local cover_page_warm, cover_page_warm_reason
            if type(items) == "table" and type(fc._zen_warm_cover_page) == "function" then
                cover_page_warm, cover_page_warm_reason = fc:_zen_warm_cover_page(
                    items, 1, function()
                        materializeHiddenLibrary(fm, fc, home_dir, items, detail)
                    end)
            else
                cover_page_warm_reason = type(items) == "table"
                    and "unsupported" or "listing_unavailable"
            end
            if listing_prepared and not cover_page_warm
                    and (cover_page_warm_reason == "no_files"
                        or cover_page_warm_reason == "unsupported") then
                materializeHiddenLibrary(fm, fc, home_dir, items, detail)
            end
            logger.measure("Hidden Library listing warmed", (now() - started_at) * 1000,
                "cache=", tostring(detail.cache or "unknown"),
                "items=", tostring(detail.items or 0),
                "prepared=", tostring(listing_prepared),
                "cover_page_warm=", tostring(cover_page_warm == true),
                "cover_page_warm_reason=", tostring(cover_page_warm_reason or "scheduled"),
                "retries=", retry_count)
            scheduleGroupPrewarm()
        end
        fm._zen_hidden_library_warm_fn = warm
        UIManager:scheduleIn(HIDDEN_LIBRARY_WARM_DELAY_S, warm)
        return true
    end

    local function refreshSuppressedCoversNow(fm)
        local fc = fm and fm.file_chooser
        if not (fc and type(fc.updateItems) == "function") then return false end
        if not fc._zen_needs_cover_refresh then return false end
        fc._zen_needs_cover_refresh = nil
        fc:updateItems()
        return true
    end

    local function refreshLibraryStatusBar(fm)
        if not (fm and type(fm._updateStatusBar) == "function") then return end
        -- Update synchronously so the titlebar's setDirty coalesces with the
        -- repaint already queued this tick. Deferring to its own nextTick fires
        -- a separate partial refresh and causes a visible flash on color devices.
        if FileManager.instance == fm then
            fm:_updateStatusBar()
        end
    end

    local function fileManagerStackAnchor(fm)
        local stack = UIManager._window_stack
        if not (fm and type(stack) == "table") then return fm end
        for index, entry in ipairs(stack) do
            local widget = entry and entry.widget
            if widget == fm or widget == fm.show_parent then
                return widget, index
            end
        end
        return fm
    end

    local function retainHomeBelowFileManager(fm, menu)
        local fm_stack_widget, fm_index = fileManagerStackAnchor(fm)
        if not fm or not MemoryPolicy.canPrewarmGroups() then
            return false, fm_stack_widget
        end
        local Home = get_shared("home")
        if not (Home and type(Home.suspendActive) == "function") then
            return false, fm_stack_widget
        end
        local widgets = type(Home.getActiveWidgets) == "function"
            and Home.getActiveWidgets() or nil
        local home_widget = menu and menu.name == "home" and menu
            or (type(widgets) == "table" and widgets[#widgets])
        local stack = UIManager._window_stack
        if not (home_widget and type(stack) == "table") then
            return false, fm_stack_widget
        end
        if not menu then
            local top = stack[#stack]
            if not top or top.widget ~= home_widget then return false, fm_stack_widget end
        end
        local home_found
        for index, entry in ipairs(stack) do
            local widget = entry and entry.widget
            if widget == home_widget then home_found = true end
        end
        if not (fm_index and home_found and Home.suspendActive()) then
            return false, fm_stack_widget
        end
        table.insert(stack, table.remove(stack, fm_index))
        return true, fm_stack_widget
    end

    -- === Tab callbacks ===

    -- Build a {dir_path = mtime} snapshot of a directory tree, root + subdirs up
    -- to `max_depth` levels deep. Adding/removing a book bumps its parent dir's
    -- mtime, so comparing snapshots detects external changes (e.g. a network copy)
    -- without re-walking every file. Depth-capped to stay cheap on large trees.
    -- The item-table cache key only stats the root dir mtime, so a book added in
    -- a subfolder would not invalidate it -- this snapshot covers that gap.
    local LIB_SNAPSHOT_DEPTH = 2
    local LIB_VALIDATION_INTERVAL_S = 30

    local function _build_dir_mtime_snapshot(root, max_depth)
        local snap = {}
        local subdirs = {}
        local function walk(dir, depth)
            local m = lfs.attributes(dir, "modification")
            if m then snap[dir] = m end
            if depth >= max_depth then return end
            local ok, iter, dir_obj = pcall(lfs.dir, dir)
            if not ok then return end
            for f in iter, dir_obj do
                if f ~= "." and f ~= ".." and f:sub(1, 1) ~= "."
                        and f:sub(-4) ~= ".sdr" then
                    local sub = dir .. "/" .. f
                    if lfs.attributes(sub, "mode") == "directory" then
                        subdirs[#subdirs + 1] = sub
                        walk(sub, depth + 1)
                    end
                end
            end
        end
        walk(root, 0)
        return snap, subdirs
    end

    local function _snapshot_differs(old, new)
        if type(old) ~= "table" then return true end
        for path, m in pairs(new) do
            if old[path] ~= m then return true end
        end
        for path in pairs(old) do
            if new[path] == nil then return true end
        end
        return false
    end

    local function _library_sort_signature(fc, path)
        local folder_collate, folder_reverse = "", ""
        local folder_sort = rawget(_G, "__ZEN_FOLDER_SORT")
        if folder_sort and type(folder_sort.get) == "function" then
            local ok, override = pcall(folder_sort.get, path)
            if ok and type(override) == "table" then
                folder_collate = tostring(override.collate or "")
                folder_reverse = tostring(override.reverse == true)
            end
        end
        local filter = fc.show_filter or FileChooser.show_filter
        local show_hidden = fc.show_hidden
        if show_hidden == nil then show_hidden = FileChooser.show_hidden end
        return table.concat({
            tostring(G_reader_settings:readSetting("collate", "strcoll")),
            tostring(G_reader_settings:isTrue("collate_mixed")),
            tostring(G_reader_settings:isTrue("reverse_collate")),
            tostring(show_hidden),
            tostring(type(filter) == "table" and filter.status or filter),
            folder_collate,
            folder_reverse,
        }, "\31")
    end

    local function _library_layout_signature(fc)
        local dimen = fc.dimen or {}
        local inner = fc.inner_dimen or {}
        return table.concat({
            tostring(Screen:getWidth()), tostring(Screen:getHeight()),
            tostring(fc.display_mode_type or ""), tostring(fc.perpage or ""),
            tostring(fc.item_width or ""), tostring(fc.item_height or ""),
            tostring(dimen.w or ""), tostring(dimen.h or ""),
            tostring(inner.w or ""), tostring(inner.h or ""),
        }, "\31")
    end

    local function _library_retained_descriptor(fc, home_dir)
        return {
            path = fc.path,
            page = fc.page,
            item_table = fc.item_table,
            sort_signature = _library_sort_signature(fc, home_dir),
            layout_signature = _library_layout_signature(fc),
            root_mtime = lfs.attributes(home_dir, "modification"),
        }
    end

    local function _retained_library_valid(fc, retained, home_dir)
        return retained ~= nil
            and retained.path == home_dir
            and retained.item_table == fc.item_table
            and retained.page == fc.page
            and retained.sort_signature == _library_sort_signature(fc, home_dir)
            and retained.layout_signature == _library_layout_signature(fc)
            and retained.root_mtime == lfs.attributes(home_dir, "modification")
    end

    materializeHiddenLibrary = function(fm, fc, home_dir, items, detail)
        local Home = get_shared("home")
        if FileManager.instance ~= fm or active_tab ~= "home"
                or fm.file_chooser ~= fc or fc._zen_needs_full_listing ~= true
                or fc.path ~= home_dir or fc._zen_idle_materialized_library
                or type(items) ~= "table" or type(fc.refreshPath) ~= "function"
                or not MemoryPolicy.canPrewarmGroups()
                or not (Home and type(Home.isActiveOnTop) == "function"
                    and Home.isActiveOnTop()) then
            return false
        end

        local started_at = now()
        fc.path_items = fc.path_items or {}
        fc.path_items[home_dir] = 1
        local original_set_dirty = UIManager.setDirty
        local suppressed_dirty = 0
        UIManager.setDirty = function()
            suppressed_dirty = suppressed_dirty + 1
        end
        local ok, error_message = pcall(fc.refreshPath, fc)
        UIManager.setDirty = original_set_dirty
        if not ok then
            logger.warn("Hidden Library page materialization failed:",
                tostring(error_message))
            return false
        end
        refreshLibraryStatusBar(fm)
        fc._zen_lib_mtime_snapshot, fc._zen_lib_mtime_subdirs =
            _build_dir_mtime_snapshot(home_dir, LIB_SNAPSHOT_DEPTH)
        fc._zen_lib_mtime_snapshot_at = now()
        local retained = _library_retained_descriptor(fc, home_dir)
        fc._zen_idle_materialized_library = retained
        fc._zen_home_retained_library = retained
        local folder_prewarm, folder_prewarm_detail = false, "unsupported"
        if type(fc._zen_start_hidden_folder_prewarm) == "function" then
            folder_prewarm, folder_prewarm_detail = fc:_zen_start_hidden_folder_prewarm(
                function()
                    return FileManager.instance == fm and fm.file_chooser == fc
                        and active_tab == "home" and fm.invisible == true
                        and fc._zen_hidden_home_startup == true
                        and Home.isActiveOnTop()
                end)
        end
        logger.measure("Hidden Library page materialized", (now() - started_at) * 1000,
            "cache=", tostring(type(detail) == "table" and detail.cache or "unknown"),
            "items=", tostring(#items),
            "page=", tostring(fc.page or 1),
            "folder_prewarm=", tostring(folder_prewarm == true),
            "folder_prewarm_detail=", tostring(folder_prewarm_detail),
            "suppressed_dirty=", suppressed_dirty,
            "listing_cache=", tostring(fc._zen_last_item_table_cache_result
                and fc._zen_last_item_table_cache_result.cache or "unknown"))
        return true
    end

    local function _refresh_library_path(fc, home_dir, invalidate_nested)
        if invalidate_nested and fc._zen_invalidate_item_table_path then
            fc:_zen_invalidate_item_table_path(home_dir)
        end
        fc.path_items[home_dir] = 1
        if fc.path == home_dir and type(fc.refreshPath) == "function" then
            fc:refreshPath()
        else
            fc:changeToPath(home_dir)
        end
    end

    local function _schedule_library_validation(fm, fc, home_dir, options)
        options = options or {}
        local transition_started_at = fm._zen_home_to_library_started_at
        local retained = options.retained
        local schedule = UIManager.tickAfterNext or UIManager.nextTick
        schedule(UIManager, function()
            if FileManager.instance ~= fm or active_tab ~= "books" or fc.path ~= home_dir then
                if fm._zen_home_to_library_started_at == transition_started_at then
                    fm._zen_home_to_library_started_at = nil
                end
                return
            end

            if transition_started_at then
                logger.measure("Home to Library first reveal",
                    (now() - transition_started_at) * 1000,
                    "mode=", options.mode or "current",
                    "cover_work_resumed=", tostring(options.cover_work_resumed == true))
            end

            local validation_started_at = now()
            local sort_changed = retained ~= nil
                and retained.sort_signature ~= _library_sort_signature(fc, home_dir)
            local tree_changed = retained ~= nil
                and retained.item_table ~= fc.item_table
            local baseline_missing = retained ~= nil
                and fc._zen_lib_mtime_snapshot == nil
            local root_changed = retained ~= nil
                and retained.root_mtime ~= lfs.attributes(home_dir, "modification")
            local show_flat_view = fc.show_flat_view
            if show_flat_view == nil then show_flat_view = FileChooser.show_flat_view end
            local validation_due = fc._zen_lib_mtime_snapshot == nil
                or fc._zen_lib_mtime_snapshot_at == nil
                or now() - fc._zen_lib_mtime_snapshot_at >= LIB_VALIDATION_INTERVAL_S
                or root_changed
                or show_flat_view == true
            local listing_changed = false
            local validation_mode = "cached"
            if validation_due then
                local root_mtime = lfs.attributes(home_dir, "modification")
                -- If the root's mtime is untouched since the last scan, no
                -- directory could have been created, removed or renamed at
                -- any depth (all of those bump the parent dir), so re-stat
                -- the previously known subdirs instead of re-listing the
                -- tree.  Changes INSIDE a subdir bump only that subdir.
                local incremental = fc._zen_lib_mtime_subdirs ~= nil
                    and fc._zen_lib_mtime_snapshot ~= nil
                    and fc._zen_lib_mtime_snapshot[home_dir] == root_mtime
                local snapshot
                local subdirs
                if incremental then
                    snapshot = {}
                    for _i, sub in ipairs(fc._zen_lib_mtime_subdirs) do
                        local m = lfs.attributes(sub, "modification")
                        if m then snapshot[sub] = m end
                    end
                    snapshot[home_dir] = root_mtime
                    subdirs = fc._zen_lib_mtime_subdirs
                    validation_mode = "incremental"
                else
                    snapshot, subdirs = _build_dir_mtime_snapshot(
                        home_dir, LIB_SNAPSHOT_DEPTH)
                    validation_mode = "scan"
                end
                listing_changed = fc._zen_lib_mtime_snapshot ~= nil
                    and _snapshot_differs(fc._zen_lib_mtime_snapshot, snapshot)
                fc._zen_lib_mtime_snapshot = snapshot
                fc._zen_lib_mtime_subdirs = subdirs
                fc._zen_lib_mtime_snapshot_at = now()
            end
            local refresh_needed = not options.already_refreshed
                and (sort_changed or tree_changed or listing_changed)

            if refresh_needed then
                refreshLibraryStatusBar(fm)
                _refresh_library_path(fc, home_dir, listing_changed)
            end
            fc._zen_home_retained_library = nil

            if transition_started_at then
                local finished_at = now()
                logger.measure("Home to Library validation completed",
                    (finished_at - transition_started_at) * 1000,
                    "validation_ms=",
                    math.floor((finished_at - validation_started_at) * 1000 + 0.5),
                    "refreshed=", tostring(refresh_needed),
                    "sort_changed=", tostring(sort_changed),
                    "listing_changed=", tostring(listing_changed),
                    "baseline_missing=", tostring(baseline_missing),
                    "validation=", validation_mode,
                    "recursive_validation=",
                        validation_mode == "scan" and "scanned"
                            or validation_mode == "incremental" and "re-statted"
                            or "skipped")
                if fm._zen_home_to_library_started_at == transition_started_at then
                    fm._zen_home_to_library_started_at = nil
                end
            end
        end)
    end

    local function fileManagerIsHidden(fm, fc)
        local fm_parent = fm and fm.show_parent
        local fc_parent = fc and fc.show_parent
        return fm and fm.invisible == true
            or fc and fc.invisible == true
            or fm_parent and fm_parent.invisible == true
            or fc_parent and fc_parent.invisible == true
    end

    local function revealFileManager(fm, fc)
        local was_hidden = fileManagerIsHidden(fm, fc)
        local fm_parent = fm and fm.show_parent
        local fc_parent = fc and fc.show_parent
        local function reveal(widget)
            if widget then
                widget.invisible = nil
                widget._zen_hidden_home_startup = nil
            end
        end
        reveal(fm)
        reveal(fc)
        reveal(fm_parent)
        reveal(fc_parent)
        return was_hidden
    end

    local function onTabBooks()
        local fm = FileManager.instance
        local home_dir = paths.getHomeDir()
                         or require("apps/filemanager/filemanagerutil").getDefaultDir()
        if not (fm and fm.file_chooser) then return false end
        local fc = fm.file_chooser
        local fm_stack_widget = select(2, retainHomeBelowFileManager(fm))
        -- A reinit under Home replaces FileChooser but preserves FileManager.invisible.
        local reveal_hidden_filemanager = revealFileManager(fm, fc)
        utils.closeWidgetsAbove(fm_stack_widget or fm)
        if reveal_hidden_filemanager then
            UIManager:setDirty(fm_stack_widget or fm, "ui")
        end
        local idle_materialized = fc._zen_idle_materialized_library
        if idle_materialized and _retained_library_valid(fc, idle_materialized, home_dir) then
            fc._zen_needs_full_listing = nil
            fc._zen_needs_cover_refresh = nil
            fc._zen_idle_materialized_library = nil
            UIManager:setDirty(fm_stack_widget or fm, "ui")
            local cover_work_resumed = type(fc._zen_resume_visible_cover_work) == "function"
                and fc:_zen_resume_visible_cover_work() == true
            _schedule_library_validation(fm, fc, home_dir, {
                mode = "idle_materialized",
                retained = idle_materialized,
                cover_work_resumed = cover_work_resumed,
            })
            return
        elseif idle_materialized then
            fc._zen_idle_materialized_library = nil
            fc._zen_home_retained_library = nil
        end
        if fc._zen_needs_full_listing then
            fc._zen_needs_full_listing = nil
            fc._zen_needs_cover_refresh = nil
            _refresh_library_path(fc, home_dir)
            refreshLibraryStatusBar(fm)
            _schedule_library_validation(fm, fc, home_dir, {
                already_refreshed = true,
                mode = "deferred_listing",
            })
            return
        end
        -- If inside a virtual series folder, exit it first. path is unchanged in
        -- series view, so without this the home-root branch below would refreshPath
        -- and immediately re-open the series group, trapping the user.
        local series_exit = rawget(_G, "__ZEN_SERIES_EXIT")
        if fc.item_table and fc.item_table.is_in_series_view and series_exit then
            series_exit(fc)
            fc.path_items[home_dir] = 1
            fc._zen_lib_mtime_snapshot, fc._zen_lib_mtime_subdirs =
                _build_dir_mtime_snapshot(home_dir, LIB_SNAPSHOT_DEPTH)
            fc._zen_lib_mtime_snapshot_at = now()
            fc:changeToPath(home_dir)
            refreshLibraryStatusBar(fm)
            return
        end
        if fc.path == home_dir then
            -- Home overlays the live FileManager. Keep its current widget tree so
            -- closing Home only exposes an already-built page; validate after paint.
            local retained = fc._zen_home_retained_library
            local retained_valid = _retained_library_valid(fc, retained, home_dir)
            if not retained_valid then
                fc.path_items[home_dir] = 1
                if retained then
                    _refresh_library_path(fc, home_dir)
                elseif not refreshSuppressedCoversNow(fm)
                        and type(fc.onGotoPage) == "function" then
                    fc:onGotoPage(1)
                end
            end
            local cover_work_resumed = retained_valid
                and type(fc._zen_resume_visible_cover_work) == "function"
                and fc:_zen_resume_visible_cover_work() == true
            _schedule_library_validation(fm, fc, home_dir, {
                already_refreshed = retained ~= nil and not retained_valid,
                mode = retained_valid and "retained" or "rebuilt",
                retained = retained,
                cover_work_resumed = cover_work_resumed,
            })
            if retained_valid and fm._zen_home_to_library_started_at then return end
        else
            fc.path_items[home_dir] = nil
            fc._zen_lib_mtime_snapshot, fc._zen_lib_mtime_subdirs =
                _build_dir_mtime_snapshot(home_dir, LIB_SNAPSHOT_DEPTH)
            fc._zen_lib_mtime_snapshot_at = now()
            fc:changeToPath(home_dir)
        end
        refreshLibraryStatusBar(fm)
    end

    local function openFileManagerFolder(path, tab_id)
        local fm = FileManager.instance
        local fc = fm and fm.file_chooser
        local folder_path = normalizeFolderPath(path)
        if not (fc and folder_path
                and lfs.attributes(folder_path, "mode") == "directory") then
            return false, folder_path
        end

        local listing_deferred = fc._zen_needs_full_listing == true
        if listing_deferred and cancelHiddenLibraryWarm then
            cancelHiddenLibraryWarm(fm)
        end

        local fm_stack_widget = select(2, retainHomeBelowFileManager(fm))
        local was_hidden = fileManagerIsHidden(fm, fc)
        local function buildFolder()
            fc._zen_needs_full_listing = nil
            fc._zen_needs_cover_refresh = nil
            local current_path = normalizeFolderPath(fc.path)
            if current_path == folder_path then
                if listing_deferred and type(fc.refreshPath) == "function" then
                    fc:refreshPath()
                elseif type(fc.onGotoPage) == "function" then
                    fc:onGotoPage(1)
                end
            else
                fc.path_items[folder_path] = nil
                fc:changeToPath(folder_path)
            end
            setActiveTab(tab_id)
        end
        if was_hidden then
            local original_set_dirty = UIManager.setDirty
            UIManager.setDirty = function() end
            local ok, error_message = pcall(buildFolder)
            UIManager.setDirty = original_set_dirty
            if not ok then error(error_message) end
        else
            buildFolder()
        end

        local revealed = revealFileManager(fm, fc)
        utils.closeWidgetsAbove(fm_stack_widget or fm)
        if revealed then UIManager:setDirty(fm_stack_widget or fm, "ui") end
        return true, folder_path
    end

    local function fallbackToLibrary()
        setActiveTab("books")
        onTabBooks()
    end

    local function onTabKindle()
        return Kindle.open()
    end

    local function onTabManga()
        if config.manga_action == "folder" and config.manga_folder ~= "" then
            local opened, folder_path = openFileManagerFolder(config.manga_folder, "manga")
            if not opened then
                fallbackToLibrary()
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{
                    text = _("Manga folder not found: ") .. (folder_path or config.manga_folder),
                })
            end
            return opened
        end

        local Rakuyomi = getRakuyomi()
        if type(Rakuyomi.openLibraryView) == "function" then
            Rakuyomi.openLibraryView({ hideTopClose = true, forceLibraryView = true })
        end
    end

    local function onTabFolder()
        local opened, folder_path = openFileManagerFolder(config.folder_path, "folder")
        if not opened then
            fallbackToLibrary()
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = folder_path and _("ZenOS: folder not found: ") .. folder_path
                    or _("ZenOS: no folder set for this action."),
            })
            return false
        end
        return true
    end

    local function onCustomFolderTab(path, tab_id)
        local opened, folder_path = openFileManagerFolder(path, tab_id)
        if not opened then
            fallbackToLibrary()
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = folder_path and _("ZenOS: folder not found: ") .. folder_path
                    or _("ZenOS: no folder set for this action."),
            })
        end
        return opened
    end

    local function openTag(tag_name, tab_id)
        if type(tag_name) ~= "string" or tag_name == "" then return false end
        local GroupView = get_shared("group_view")
        if not (GroupView and type(GroupView.showTagDetail) == "function") then
            return false
        end
        setActiveTab(tab_id or "tags")
        GroupView.showTagDetail(tag_name, injectStandaloneNavbar, tab_id or "tags")
        return true
    end

    local function openStatus(status, label, tab_id)
        local GroupView = get_shared("group_view")
        if not (ButtonModel.statusLabel(status) and GroupView
                and type(GroupView.showStatusView) == "function") then
            return false
        end
        setActiveTab(tab_id)
        GroupView.showStatusView(status, label, injectStandaloneNavbar, tab_id)
        return true
    end

    local function onTabNews()
        local fm = FileManager.instance
        if not fm then return end

        if config.news_action == "folder" and config.news_folder ~= "" then
            local opened, folder_path = openFileManagerFolder(config.news_folder, "news")
            if not opened then
                fallbackToLibrary()
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{
                    text = _("News folder not found: ") .. (folder_path or config.news_folder),
                })
            end
            return opened
        end

        if config.news_action == "rssreader" then
            local rssreader = fm.rssreader
            if rssreader then
                rssreader:openAccountList()
            else
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{
                    text = _("RSS Reader plugin is not installed."),
                })
            end
            return
        end

        -- Default: open QuickRSS
        hookQuickRSSInit()
        local ok, QuickRSSUI = pcall(require, "modules/ui/feed_view")
        if ok and QuickRSSUI then
            UIManager:show(QuickRSSUI:new{})
        else
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = _("QuickRSS plugin is not installed."),
            })
        end
    end

    local function onTabContinue()
        local last_file = G_reader_settings:readSetting("lastfile")
        if not last_file or lfs.attributes(last_file, "mode") ~= "file" then
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = _("Cannot open last document"),
            })
            return
        end
        local Rakuyomi = getRakuyomi()
        local resume_rakuyomi = type(Rakuyomi.isChapterFile) == "function"
            and Rakuyomi.isChapterFile(last_file)
        local rakuyomi_return_file = resume_rakuyomi
            and rakuyomi_return_to_chapter_list_on_exit_enabled()
            and last_file or nil
        logger.dbg(
            "Rakuyomi return: Continue:",
            "file=", last_file,
            "detected=", tostring(resume_rakuyomi))
        _G.__ZEN_UI_FORCE_SOURCE_TAB_RESTORE = nil
        _G.__ZEN_UI_RAKUYOMI_RETURN_FILE = nil
        if resume_rakuyomi then
            _G.__ZEN_UI_LIBRARY_SOURCE_TAB = "manga"
            _G.__ZEN_UI_FORCE_SOURCE_TAB_RESTORE = true
            _G.__ZEN_UI_RAKUYOMI_RETURN_FILE = rakuyomi_return_file
        elseif is_restore_enabled() and not skipTabState(active_tab) then
            _G.__ZEN_UI_LIBRARY_SOURCE_TAB = active_tab
        else
            _G.__ZEN_UI_LIBRARY_SOURCE_TAB = nil
        end
        local ReaderUI = require("apps/reader/readerui")
        ReaderUI:showReader(last_file)
    end

    local function onTabHistory()
        local fm = FileManager.instance
        if fm and fm.history then
            fm.history:onShowHist()
        end
    end

    local function onTabFavorites()
        local fm = FileManager.instance
        if fm and fm.collections then
            fm.collections:onShowColl()
        end
    end

    local function onTabCollections()
        local fm = FileManager.instance
        if fm and fm.collections then
            fm.collections:onShowCollList()
        end
    end

    local function onTabAuthors()
        local GroupView = get_shared("group_view")
        if GroupView then GroupView.showAuthorsView(injectStandaloneNavbar) end
    end

    local function onTabSeries()
        local GroupView = get_shared("group_view")
        if GroupView then GroupView.showSeriesView(injectStandaloneNavbar) end
    end

    local function onTabLanguages()
        local GroupView = get_shared("group_view")
        if GroupView then GroupView.showLanguagesView(injectStandaloneNavbar) end
    end

    local function onTabTBR()
        local GroupView = get_shared("group_view")
        if GroupView then GroupView.showTBRView(injectStandaloneNavbar) end
    end

    local function onTabTags()
        local GroupView = get_shared("group_view")
        if GroupView then GroupView.showTagsView(injectStandaloneNavbar) end
    end

    local function resetHomeStripPages()
        local Home = get_shared("home")
        if Home and Home.isActiveOnTop and Home.isActiveOnTop()
                and Home.resetStripPages then
            Home.resetStripPages()
            return true
        end
        return false
    end

    local function raiseStandaloneWidgets(widgets, defer_repaint)
        if type(widgets) ~= "table" or #widgets == 0 then return false end
        local stack = UIManager._window_stack
        if type(stack) ~= "table" then return false end
        for _i, widget in ipairs(widgets) do
            local found
            for index, entry in ipairs(stack) do
                if entry and entry.widget == widget then
                    found = index
                    break
                end
            end
            if not found then return false end
            table.insert(stack, table.remove(stack, found))
        end
        if not defer_repaint then
            local top = widgets[#widgets]
            UIManager:setDirty(top, function()
                return "ui", top.dimen
            end)
        end
        return true
    end

    local function measureLibraryToHomeReveal(fm, mode, view_reused)
        local started_at = fm and fm._zen_library_to_home_started_at
        if not started_at then return end
        local schedule = UIManager.tickAfterNext or UIManager.nextTick
        schedule(UIManager, function()
            if fm._zen_library_to_home_started_at ~= started_at then return end
            fm._zen_library_to_home_started_at = nil
            logger.measure("Library to Home first reveal", (now() - started_at) * 1000,
                "mode=", mode,
                "view_reused=", tostring(view_reused == true))
        end)
    end

    local function onTabHome()
        if resetHomeStripPages() then return end
        local Home = get_shared("home")
        if not Home then return end
        local fm = FileManager.instance
        local fc = fm and fm.file_chooser
        local home_dir = paths.getHomeDir()
        if fc and home_dir and fc.path == home_dir
                and not fc._zen_needs_full_listing
                and not fc._zen_needs_cover_refresh
                and type(fc.item_table) == "table" then
            fc._zen_home_retained_library = _library_retained_descriptor(fc, home_dir)
        elseif fc then
            fc._zen_home_retained_library = nil
        end
        local widgets = type(Home.getActiveWidgets) == "function"
            and Home.getActiveWidgets() or nil
        local can_resume = type(Home.resumeActive) == "function"
        if raiseStandaloneWidgets(widgets, can_resume) then
            local strips_reset = type(Home.resetStripPages) == "function"
                and Home.resetStripPages() == true
            local resumed, resume_mode = true, "reused"
            if can_resume then resumed, resume_mode = Home.resumeActive() end
            if not resumed then
                if type(Home.closeAll) == "function" then Home.closeAll() end
                Home.showHomeView(injectStandaloneNavbar)
                measureLibraryToHomeReveal(fm, "rebuilt", false)
            else
                local rebuilt = resume_mode == "rebuilt" or strips_reset
                measureLibraryToHomeReveal(fm, rebuilt and "rebuilt" or "retained", true)
            end
            if not scheduleHiddenLibraryWarm(fm) then scheduleGroupPrewarm() end
            return
        end
        Home.showHomeView(injectStandaloneNavbar)
        measureLibraryToHomeReveal(fm, "rebuilt", false)
        if not scheduleHiddenLibraryWarm(fm) then scheduleGroupPrewarm() end
    end

    local function onTabSearch()
        local fm = FileManager.instance
        if fm and fm.filesearcher then
            fm.filesearcher:onShowFileSearch()
        end
    end

    local function onTabCalibreSearch()
        local fm = FileManager.instance
        if not fm or not fm.calibre then
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = _("Calibre plugin is not installed."),
            })
            return
        end
        UIManager:broadcastEvent(Event:new("CalibreSearch"))
    end

    local function onTabStats()
        local StatsPage = require("modules/filebrowser/patches/stats_page")
        local _createStatusRow = get_shared("createStatusRow")
        local _repaintTitleBar = get_shared("repaintTitleBar")
        local stats_page, is_new = StatsPage.create(
            _createStatusRow, _repaintTitleBar, zen_plugin)
        if not is_new then return end
        injectStandaloneNavbar(stats_page, "stats")
        UIManager:show(stats_page)
    end

    local function onTabExit()
        local fm = FileManager.instance
        if fm then
            fm:onClose()
        end
    end

    local function onTabPageLeft()
        local fm = FileManager.instance
        if fm and fm.file_chooser then
            fm.file_chooser:onPrevPage()
        end
    end

    local function onTabPageRight()
        local fm = FileManager.instance
        if fm and fm.file_chooser then
            fm.file_chooser:onNextPage()
        end
    end

    local function onTabMenu()
        local stack = UIManager._window_stack
        local top = type(stack) == "table" and stack[#stack]
        if Kindle.showContextMenu(top and top.widget) then return end
        local fm = FileManager.instance
        if not fm or not fm.file_chooser then return end
        local fc = fm.file_chooser
        -- Prefer the last touch-held item, then the d-pad focused item,
        -- then fall back to the current directory.
        local item = _last_menu_item
        if not item and fc.itemnumber and fc.itemnumber > 0 then
            item = fc.item_table and fc.item_table[fc.itemnumber]
        end
        if not item then
            item = {
                path = fc.path,
                is_file = false,
                is_go_up = false,
                text = fc.path:match("([^/]+)/?$") or fc.path,
            }
        end
        fc:showFileDialog(item)
    end

    local tab_callbacks = {
        books = onTabBooks,
        folder = onTabFolder,
        kindle = onTabKindle,
        manga = onTabManga,
        news = onTabNews,
        continue = onTabContinue,
        history = onTabHistory,
        favorites = onTabFavorites,
        collections = onTabCollections,
        authors = onTabAuthors,
        series = onTabSeries,
        languages = onTabLanguages,
        tags = onTabTags,
        to_be_read = onTabTBR,
        home = onTabHome,
        search = onTabSearch,
        calibre_search = onTabCalibreSearch,
        stats = onTabStats,
        exit = onTabExit,
        page_left = onTabPageLeft,
        page_right = onTabPageRight,
        menu = onTabMenu,
    }

    local default_tab_whitelist = {
        books = true,
        folder = true,
        kindle = true,
        manga = true,
        news = true,
        history = true,
        favorites = true,
        collections = true,
        authors = true,
        series = true,
        languages = true,
        tags = true,
        to_be_read = true,
        home = true,
    }

    local active_tab_whitelist = {
        books = true,
        folder = true,
        kindle = true,
        manga = true,
        news = true,
        authors = true,
        series = true,
        languages = true,
        tags = true,
        to_be_read = true,
        home = true,
        history = true,
        favorites = true,
        collections = true,
    }

    local function shouldTrackActiveTab(tab_id)
        return active_tab_whitelist[tab_id] == true
            or getCustomTagTab(tab_id) ~= nil
            or getCustomStatusTab(tab_id) ~= nil
            or getCustomFolderTab(tab_id) ~= nil
    end

    local function is_tab_enabled(tab_id)
        return config.show_tabs[tab_id] == true
            and (tab_id ~= "kindle" or Kindle.isAvailable())
    end

    local function first_enabled_default_tab()
        local fallback
        for _i, id in ipairs(config.tab_order) do
            if tab_callbacks[id] and is_tab_enabled(id) then
                if default_tab_whitelist[id] or id:sub(1, 3) == "ct_" then
                    return id
                end
                fallback = fallback or id
            end
        end
        return fallback or "books"
    end

    local function resolve_default_tab()
        config = loadConfig()
        local tab_id = config.default_tab
        if type(tab_id) ~= "string" or tab_id == "" then
            return first_enabled_default_tab()
        end
        if tab_id:sub(1, 3) == "ct_" then
            if tab_callbacks[tab_id] then
                return tab_id
            end
            return first_enabled_default_tab()
        end
        if not default_tab_whitelist[tab_id] then
            return first_enabled_default_tab()
        end
        if tab_callbacks[tab_id] then
            return tab_id
        end
        return first_enabled_default_tab()
    end

    local navbar_refresh_pending = false
    local function refreshAfterNavbarPageSwitch()
        if navbar_refresh_pending then return end
        navbar_refresh_pending = true
        UIManager:nextTick(function()
            navbar_refresh_pending = false
            UIManager:setDirty(nil, "full")
            UIManager:forceRePaint()
        end)
    end

    local function runTabCallback(tab_id)
        local cb = tab_callbacks[tab_id]
        if not cb then return end
        local stack = UIManager._window_stack
        local top = stack and stack[#stack]
        local top_widget = top and top.widget
        if tab_id ~= "home"
                and top_widget
                and top_widget._zen_navbar_tab_id == tab_id then
            return
        end
        if shouldTrackActiveTab(tab_id) then
            local fm = FileManager.instance
            local flash_library_home = fm and (
                (tab_id == "home" and fm._zen_library_to_home_started_at)
                or (tab_id == "books" and fm._zen_home_to_library_started_at))
            cb()
            if flash_library_home then
                UIManager:nextTick(function() UIManager:setDirty(nil, "flashui") end)
            end
            if tab_id ~= "home" and not tabStaysInFileManager(tab_id) then
                refreshAfterNavbarPageSwitch()
            end
            return
        end
        local saved_active = active_tab
        cb()
        if active_tab ~= saved_active then
            active_tab = saved_active
            syncActiveTabLabel()
            local fm = FileManager.instance
            if fm then injectNavbar(fm); UIManager:setDirty(fm, "ui") end
        end
    end

    local function open_default_tab()
        local tab_id = resolve_default_tab()
        if shouldTrackActiveTab(tab_id) then
            setActiveTab(tab_id)
        end
        runTabCallback(tab_id)
        return tab_id
    end

    local function open_tab(tab_id)
        if not tab_callbacks[tab_id] then return false end
        if shouldTrackActiveTab(tab_id) then
            setActiveTab(tab_id)
        end
        runTabCallback(tab_id)
        return true
    end

    local function is_default_tab_active()
        local tab_id = resolve_default_tab()
        if active_tab ~= tab_id then return false end
        local stack = UIManager._window_stack
        local top = stack and stack[#stack]
        local widget = top and top.widget
        if widget and widget._zen_navbar_tab_id == tab_id then return true end
        local fm = FileManager.instance
        return tabStaysInFileManager(tab_id)
            and fm ~= nil
            and (widget == fm or widget == fm.show_parent)
    end

    do
        local default_tab = resolve_default_tab()
        active_tab = shouldTrackActiveTab(default_tab) and default_tab or "books"
    end
    syncActiveTabLabel()

    -- Custom tabs are synced dynamically in createNavBar() so they appear immediately
    -- after being added without needing a full patch re-apply.

    local ok_disp_ct, Dispatcher_ct = pcall(require, "dispatcher")

    -- === Color text support ===
    -- TextWidget.colorblitFrom converts to grayscale; colorblitFromRGB32 needed for color.

    local RenderText = require("ui/rendertext")

    local ColorTextWidget = TextWidget:extend{}

    function ColorTextWidget:paintTo(bb, x, y)
        self:updateSize()
        if self._is_empty then return end

        if not self.fgcolor or Blitbuffer.isColor8(self.fgcolor) or not Screen:isColorScreen() then
            TextWidget.paintTo(self, bb, x, y)
            return
        end

        if not self.use_xtext then
            TextWidget.paintTo(self, bb, x, y)
            return
        end

        if not self._xshaping then
            self._xshaping = self._xtext:shapeLine(self._shape_start, self._shape_end,
                                                self._shape_idx_to_substitute_with_ellipsis)
        end

        local text_width = bb:getWidth() - x
        if self.max_width and self.max_width < text_width then
            text_width = self.max_width
        end
        local pen_x = 0
        local baseline = self.forced_baseline or self._baseline_h
        for _i, xglyph in ipairs(self._xshaping) do
            if pen_x >= text_width then break end
            local face = self.face.getFallbackFont(xglyph.font_num)
            local glyph = RenderText:getGlyphByIndex(face, xglyph.glyph, self.bold)
            bb:colorblitFromRGB32(
                glyph.bb,
                x + pen_x + glyph.l + xglyph.x_offset,
                y + baseline - glyph.t - xglyph.y_offset,
                0, 0,
                glyph.bb:getWidth(), glyph.bb:getHeight(),
                self.fgcolor)
            pen_x = pen_x + xglyph.x_advance
        end
    end

    -- === Colored icon widget ===
    -- Build a mask from the icon, then color-blit through it.

    local ColorIconWidget = IconWidget:extend{
        _tint_color = nil,
    }

    function ColorIconWidget:paintTo(bb, x, y)
        if not self._tint_color or not Screen:isColorScreen() then
            IconWidget.paintTo(self, bb, x, y)
            return
        end

        if self.hide then return end
        local size = self:getSize()
        if not self.dimen then
            self.dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
        else
            self.dimen.x = x
            self.dimen.y = y
        end
        if not self._tint_mask
                or self._tint_mask:getWidth() ~= size.w
                or self._tint_mask:getHeight() ~= size.h then
            if self._tint_mask then
                self._tint_mask:free()
            end
            self._tint_mask = Blitbuffer.new(size.w, size.h, Blitbuffer.TYPE_BB8)
        end
        local mask = self._tint_mask
        mask:fill(Blitbuffer.COLOR_WHITE)

        local bbtype = self._bb:getType()
        if self.alpha == true
                and (bbtype == Blitbuffer.TYPE_BB8A or bbtype == Blitbuffer.TYPE_BBRGB32) then
            if self._is_straight_alpha then
                mask:alphablitFrom(self._bb, 0, 0, self._offset_x, self._offset_y, size.w, size.h)
            else
                mask:pmulalphablitFrom(self._bb, 0, 0, self._offset_x, self._offset_y, size.w, size.h)
            end
        else
            mask:blitFrom(self._bb, 0, 0, self._offset_x, self._offset_y, size.w, size.h)
        end
        mask:invertRect(0, 0, size.w, size.h)
        bb:colorblitFromRGB32(mask, x, y, 0, 0, size.w, size.h, self._tint_color)
    end

    function ColorIconWidget:free()
        if self._tint_mask then
            self._tint_mask:free()
            self._tint_mask = nil
        end
        return IconWidget.free(self)
    end

    -- === Build a single tab (visual only) ===

    local navbar_font_size_steps = {20, 18, 16, 14}

    local function buildFontSizeSteps(base_size)
        local steps = {}
        for i = 0, 3 do
            local size = math.max(8, base_size - i * 2)
            if steps[#steps] ~= size then
                steps[#steps + 1] = size
            end
        end
        return steps
    end

    -- Returns the largest size from navbar_font_size_steps where every label fits within max_w.
    local function getSharedFontSize(labels, max_w)
        for _i, size in ipairs(navbar_font_size_steps) do
            local face = library_font.getFace(size)
            local all_fit = true
            for _j, text in ipairs(labels) do
                local probe = TextWidget:new{ text = text, face = face }
                local fits = probe:getSize().w <= max_w
                probe:free()
                if not fits then all_fit = false; break end
            end
            if all_fit then return size end
        end
        return navbar_font_size_steps[#navbar_font_size_steps]
    end

    local function createTabWidget(tab, label_max_w, is_active, font_size, is_focused)
        local styled = is_active and tab.dim ~= true
        local use_color = styled and config.colored and Screen:isColorScreen()
        local active_color
        if use_color then
            local c = config.active_tab_color
            if c and type(c) == "table" then
                active_color = Blitbuffer.ColorRGB32(c[1], c[2], c[3], 0xFF)
            end
        end

        local show_icon = config.show_icons ~= false
        local show_label = config.show_labels == true or not show_icon

        local icon
        if show_icon then
            local icon_path = tab.icon:sub(1, 1) == "/" and tab.icon
                or utils.resolveIcon(_icons_dir, tab.icon)
            if active_color then
                icon = ColorIconWidget:new{
                    icon   = icon_path and nil or tab.icon,
                    file   = icon_path or nil,
                    width  = navbar_icon_size,
                    height = navbar_icon_size,
                    alpha  = true,
                    _tint_color = active_color,
                }
            else
                icon = IconWidget:new{
                    icon   = icon_path and nil or tab.icon,
                    file   = icon_path or nil,
                    width  = navbar_icon_size,
                    height = navbar_icon_size,
                    alpha  = true,
                    dim = tab.dim == true,
                }
            end
        end

        local size = font_size or navbar_font_size_steps[1]
        local label_face = library_font.getFace(size)
        local label
        if active_color then
            label = ColorTextWidget:new{
                text = tab.label,
                face = label_face,
                max_width = label_max_w,
                fgcolor = active_color,
            }
        else
            label = TextWidget:new{
                text = tab.label,
                face = label_face,
                max_width = label_max_w,
                fgcolor = tab.dim == true and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK,
            }
        end

        local show_underline = styled and config.active_tab_underline
        local underline
        if show_underline then
            local underline_w = show_label and label:getSize().w or icon:getSize().w
            local underline_color = Blitbuffer.COLOR_BLACK
            if config.colored then
                local c = config.active_tab_color
                if c and type(c) == "table" then
                    underline_color = Blitbuffer.ColorRGB32(c[1], c[2], c[3], 0xFF)
                end
            end
            if config.colored and Screen:isColorScreen() then
                local Widget = require("ui/widget/widget")
                local color_line = Widget:new{
                    dimen = Geom:new{ w = underline_w, h = underline_thickness },
                }
                function color_line:paintTo(bb, x, y)
                    bb:paintRectRGB32(x, y, self.dimen.w, self.dimen.h, underline_color)
                end
                underline = color_line
            else
                underline = LineWidget:new{
                    dimen = Geom:new{ w = underline_w, h = underline_thickness },
                    background = underline_color,
                }
            end
        else
            underline = VerticalSpan:new{ width = underline_thickness }
        end

        local icon_label_children = { align = "center" }
        if config.underline_above then
            table.insert(icon_label_children, underline)
        end
        if show_icon and icon then
            table.insert(icon_label_children, icon)
        end
        if show_label then
            table.insert(icon_label_children, label)
        end
        if not config.underline_above then
            table.insert(icon_label_children, underline)
        end

        local icon_label_group = VerticalGroup:new(icon_label_children)

        local v_pad = show_label and navbar_v_padding or navbar_v_padding * 2

        local children = {
            align = "center",
            VerticalSpan:new{ width = v_pad },
            icon_label_group,
            VerticalSpan:new{ width = v_pad },
        }

        local widget = VerticalGroup:new(children)
        if is_focused then
            local FrameContainer = require("ui/widget/container/framecontainer")
            return FrameContainer:new{
                background = Blitbuffer.COLOR_LIGHT_GRAY,
                bordersize = 0,
                padding = 0,
                margin = 0,
                widget,
            }
        end
        return widget
    end

    -- === Build the full navbar ===

    local HorizontalSpan = require("ui/widget/horizontalspan")
    local navbar_h_padding = Screen:scaleBySize(10)

    local navbar_max_tabs = 7

    local function getVisibleTabs()
        local visible = {}
        for _i, id in ipairs(config.tab_order) do
            if is_tab_enabled(id) and tabs_by_id[id] then
                table.insert(visible, tabs_by_id[id])
                if #visible >= navbar_max_tabs then break end
            end
        end
        return visible
    end

    local function createNavBar()
        if not is_navbar_enabled() then
            return nil
        end
        config = loadConfig()

        -- Recompute layout constants so magnify_ui takes effect on each build.
        local lc = zen_plugin.config and zen_plugin.config.lockdown
        local ft = zen_plugin.config and zen_plugin.config.features
        if type(ft) == "table" and ft.lockdown_mode == true
                and type(lc) == "table" and lc.magnify_ui == true then
            navbar_icon_size       = Screen:scaleBySize(math.floor(config.icon_size * 1.25 + 0.5))
            navbar_v_padding       = Screen:scaleBySize(5)    -- 4 * 1.25
            navbar_font_size_steps = buildFontSizeSteps(math.floor(config.label_size * 1.25 + 0.5))
        else
            navbar_icon_size       = Screen:scaleBySize(config.icon_size)
            navbar_v_padding       = Screen:scaleBySize(4)
            navbar_font_size_steps = buildFontSizeSteps(config.label_size)
        end

        -- Update books tab label from config
        tabs_by_id["books"].label = getBooksLabel()
        tabs_by_id["home"].label = getHomeLabel()
        tabs_by_id["folder"].label = getFolderLabel()
        tabs_by_id["folder"].icon = getFolderIcon()

        -- Sync custom tabs from config so add/remove/edit takes effect on every reinject
        local known_custom = {}
        if type(config.custom_tabs) == "table" then
            for _i, ct in ipairs(config.custom_tabs) do
                if type(ct.id) == "string" then
                    known_custom[ct.id] = true
                    local entry = tabs_by_id[ct.id]
                    if not entry then
                        entry = { id = ct.id }
                        table.insert(tabs, entry)
                        tabs_by_id[ct.id] = entry
                    end
                    entry.label = (ct.label ~= nil and ct.label ~= "") and ct.label
                        or ct.tag
                        or (ct.type == "status" and ButtonModel.statusLabel(ct.status))
                        or (ct.type == "folder" and ButtonModel.label(nil, ct))
                        or ct.plugin_title
                        or (ct.koreader_menu and ct.koreader_menu.title)
                        or _("Custom")
                    entry.icon  = ct.icon or "zen_ui"
                    entry.dim = false
                    if ct.type == "koreader_menu" and type(ct.koreader_menu) == "table" then
                        local target = ct.koreader_menu
                        entry.dim = not NativeMenu.exists(target.id, "filemanager")
                        tab_callbacks[ct.id] = function()
                            local launch = NativeMenu.resolve(target.id, "filemanager")
                            if launch then
                                UIManager:nextTick(function() pcall(launch) end)
                            end
                        end
                    elseif ct.type == "plugin" and type(ct.plugin) == "table" then
                        local plugin = ct.plugin
                        tab_callbacks[ct.id] = function()
                            local launch = PluginScan.resolve(plugin.key, plugin.method)
                            if launch then pcall(launch) end
                        end
                    elseif ct.type == "quick_setting" then
                        local quick_setting_id = ct.quick_setting_id
                        tab_callbacks[ct.id] = function()
                            local controls = rawget(_G, "__ZEN_UI_QUICK_SETTINGS")
                            if controls and controls.activate then
                                controls.activate(quick_setting_id)
                            end
                        end
                    elseif ct.type == "tag" and type(ct.tag) == "string" and ct.tag ~= "" then
                        local tag_name = ct.tag
                        local tab_id = ct.id
                        tab_callbacks[ct.id] = function()
                            openTag(tag_name, tab_id)
                        end
                    elseif ct.type == "status" and ButtonModel.statusLabel(ct.status) then
                        local status = ct.status
                        local label = entry.label
                        local tab_id = ct.id
                        tab_callbacks[tab_id] = function()
                            openStatus(status, label, tab_id)
                        end
                    elseif ct.type == "folder" and type(ct.folder) == "string"
                            and ct.folder ~= "" then
                        local folder_path = ct.folder
                        local tab_id = ct.id
                        tab_callbacks[tab_id] = function()
                            onCustomFolderTab(folder_path, tab_id)
                        end
                    elseif ct.type == "action" then
                        local folder_path = ButtonModel.getFolderActionPath(ct.action)
                        if folder_path then
                            local tab_id = ct.id
                            tab_callbacks[tab_id] = function()
                                onCustomFolderTab(folder_path, tab_id)
                            end
                        elseif ok_disp_ct and ct.action and next(ct.action) then
                            local action = ct.action
                            tab_callbacks[ct.id] = function() Dispatcher_ct:execute(action) end
                        else
                            tab_callbacks[ct.id] = function() end
                        end
                    elseif ok_disp_ct and ct.action and next(ct.action) then
                        local action = ct.action
                        tab_callbacks[ct.id] = function() Dispatcher_ct:execute(action) end
                    else
                        tab_callbacks[ct.id] = function() end
                    end
                end
            end
        end
        -- Remove tabs that were deleted from config
        for i = #tabs, 1, -1 do
            local t = tabs[i]
            if t.id:sub(1, 3) == "ct_" and not known_custom[t.id] then
                tabs_by_id[t.id] = nil
                tab_callbacks[t.id] = nil
                table.remove(tabs, i)
            end
        end

        local visible_tabs = getVisibleTabs()
        if #visible_tabs == 0 then return nil end

        local screen_w = Screen:getWidth()
        local inner_w = screen_w - navbar_h_padding * 2
        local num_tabs = #visible_tabs
        local label_max_w = math.floor(inner_w / num_tabs) - Screen:scaleBySize(4)

        -- Compute one font size that fits all labels so every tab uses the same size
        local tab_labels = {}
        for _i, tab in ipairs(visible_tabs) do
            table.insert(tab_labels, tab.label)
        end
        local shared_font_size = getSharedFontSize(tab_labels, label_max_w)

        -- Build tab content widgets and measure their natural widths
        local tab_widgets = {}
        local total_content_w = 0
        for i, tab in ipairs(visible_tabs) do
            local widget = createTabWidget(tab, label_max_w, tab.id == active_tab, shared_font_size, i == _navbar_focused_idx)
            tab_widgets[i] = widget
            total_content_w = total_content_w + widget:getSize().w
        end

        -- Space-evenly: distribute remaining width as equal gaps around and between tabs
        local remaining = inner_w - total_content_w
        local gap_count = num_tabs + 1
        local base_gap = math.max(0, math.floor(remaining / gap_count))
        local extra_pixels = remaining - base_gap * gap_count

        -- Build row with even spacing and track tab center positions for tap detection
        local row = HorizontalGroup:new{}
        local tab_centers = {}
        local x_pos = 0
        for i, widget in ipairs(tab_widgets) do
            local gap = base_gap + (i <= extra_pixels and 1 or 0)
            table.insert(row, HorizontalSpan:new{ width = gap })
            x_pos = x_pos + gap
            local w = widget:getSize().w
            tab_centers[i] = x_pos + w / 2
            table.insert(row, widget)
            x_pos = x_pos + w
        end
        table.insert(row, HorizontalSpan:new{ width = base_gap })

        local row_with_padding = HorizontalGroup:new{
            HorizontalSpan:new{ width = navbar_h_padding },
            row,
            HorizontalSpan:new{ width = navbar_h_padding },
        }

        local visual_children = {}

        if config.show_top_border then
            table.insert(visual_children, LineWidget:new{
                dimen = Geom:new{ w = screen_w, h = Screen:scaleBySize(1) },
                background = Blitbuffer.COLOR_DARK_GRAY,
            })
        end

        table.insert(visual_children, row_with_padding)

        -- Lift navbar off the screen's bottom edge. Some panels (e.g. Kindle
        -- Colorsoft) have a wider bottom bezel/dead zone that occludes the
        -- bottommost row (the active-tab underline) when it sits flush.
        local safe_pad = Screen:scaleBySize(Screen:isColorScreen() and 5 or 0)
        if safe_pad > 0 then
            table.insert(visual_children, VerticalSpan:new{ width = safe_pad })
        end

        local visual = VerticalGroup:new(visual_children)

        -- Wrap in InputContainer to handle taps on the whole navbar
        local navbar = InputContainer:new{
            dimen = Geom:new{ w = screen_w, h = visual:getSize().h },
            ges_events = {
                TapNavBar = {
                    GestureRange:new{
                        ges = "tap",
                        range = Geom:new{ x = 0, y = 0, w = screen_w, h = Screen:getHeight() },
                    },
                },
            },
        }

        navbar.getTappedTabId = function(self, pos)
            if not self.dimen or not self.dimen:contains(pos) then return nil end
            if pos.x < corner_dead_zone or pos.x > screen_w - corner_dead_zone then
                return nil
            end
            -- Find nearest tab by comparing tap position to midpoints between tab centers
            local tap_x = pos.x - navbar_h_padding
            local idx = 1
            for i = 1, num_tabs - 1 do
                local boundary = (tab_centers[i] + tab_centers[i + 1]) / 2
                if tap_x >= boundary then
                    idx = i + 1
                else
                    break
                end
            end
            return visible_tabs[idx].id
        end

        navbar.onTapNavBar = function(self, _, ges)
            local tapped_id = self:getTappedTabId(ges.pos)
            if not tapped_id then return false end
            -- Track active tab for persistent views only, not launcher/action tabs.
            local track_tab = shouldTrackActiveTab(tapped_id)
            if track_tab and tapped_id ~= active_tab then
                setActiveTab(tapped_id)
            end
            runTabCallback(tapped_id)
            return true
        end

        navbar[1] = visual
        _G.__ZEN_UI_NAVBAR_HEIGHT = navbar:getSize().h
        return navbar
    end

    -- === Hook Menu:init() to reduce height for FM and standalone views ===

    local Menu = require("ui/widget/menu")

    getNavbarHeight = function()
        if not is_navbar_enabled() then
            _G.__ZEN_UI_NAVBAR_HEIGHT = 0
            return 0
        end
        local nb = createNavBar()
        if not nb then
            _G.__ZEN_UI_NAVBAR_HEIGHT = 0
            return 0
        end
        local h = nb:getSize().h
        nb:free()
        _G.__ZEN_UI_NAVBAR_HEIGHT = h
        return h
    end

    -- Standalone views (History, Favorites, Collections, Stats) that should get navbar
    local standalone_view_names = {
        history = true,
        collections = true,
        authors = true,
        series = true,
        languages = true,
        tags = true,
        to_be_read = true,
        home = true,
        authors_detail = true,
        series_detail = true,
        languages_detail = true,
        tags_detail = true,
        status_detail = true,
        stats = true,
    }

    local function isRakuyomiView(menu)
        local Rakuyomi = getRakuyomi()
        return type(Rakuyomi.isLibraryView) == "function" and Rakuyomi.isLibraryView(menu)
    end

    local function closeStandaloneView(menu)
        if not menu then return end
        local Rakuyomi = getRakuyomi()
        local closed = type(Rakuyomi.closeLibraryView) == "function"
            and Rakuyomi.closeLibraryView(menu)
        if not closed then
            if menu.close_callback then
                menu.close_callback()
            elseif menu.onClose then
                menu:onClose()
            else
                UIManager:close(menu)
            end
        end
        if menu._zen_close_stack then menu._zen_close_stack() end
    end

    local function isStandaloneExitTarget(widget)
        if not widget then return false end
        local fm = FileManager.instance
        if fm and (widget == fm or widget == fm.show_parent) then return true end
        local ok_rui, RUI = pcall(require, "apps/reader/readerui")
        if ok_rui and RUI and RUI.instance
                and (widget == RUI.instance or widget == RUI.instance.show_parent) then
            return true
        end
        return standalone_view_names[widget.name] == true
            or Kindle.isLibraryView(widget)
            or isRakuyomiView(widget)
            or widget._zen_standalone_navbar_injected == true
    end

    local function getStandaloneNextTickTabId(menu)
        if Kindle.isLibraryView(menu) then return "kindle" end
        local Rakuyomi = getRakuyomi()
        if type(Rakuyomi.getStandaloneTabId) == "function" then
            return Rakuyomi.getStandaloneTabId(menu)
        end
    end

    local function shouldCloseStandaloneBeforeAction(menu, tab_id)
        local Rakuyomi = getRakuyomi()
        return type(Rakuyomi.shouldCloseBeforeActionTab) == "function"
            and Rakuyomi.shouldCloseBeforeActionTab(menu, tab_id)
    end

    local function onStandaloneNavbarInjected(menu)
        local Rakuyomi = getRakuyomi()
        if type(Rakuyomi.onStandaloneNavbarInjected) == "function" then
            Rakuyomi.onStandaloneNavbarInjected(menu, isStandaloneExitTarget)
        end
    end

    local function refreshStandaloneAfterResize(menu)
        local Rakuyomi = getRakuyomi()
        return type(Rakuyomi.refreshAfterResize) == "function"
            and Rakuyomi.refreshAfterResize(menu)
    end

    local function isStandaloneNavbarView(menu)
        if standalone_view_names[menu.name] then return true end
        if Kindle.isLibraryView(menu) then return true end
        if isRakuyomiView(menu) then return true end
        -- Collections list has no name but has these flags. PathChooser also
        -- has them, so exclude its explicit selection contract.
        if not menu.name
                and menu.select_directory == nil and menu.select_file == nil
                and menu.covers_fullscreen and menu.is_borderless and menu.title_bar_fm_style then
            return true
        end
        return false
    end

    local function preventStandaloneSwipeClose(menu)
        if not menu or menu._zen_prevent_swipe_close then return end
        menu._zen_prevent_swipe_close = true

        menu.onMultiSwipe = function()
            return true
        end
    end

    -- Flag to skip navbar for nested views (e.g. collection opened from collections list)
    -- or selection-mode dialogs (e.g. "add to collection")
    local _skip_standalone_navbar = false

    -- Track the last long-held item so the menu tab can show its context dialog.
    local orig_fc_onMenuHold = FileChooser.onMenuHold
    FileChooser.onMenuHold = function(self, item)
        _last_menu_item = item
        return orig_fc_onMenuHold and orig_fc_onMenuHold(self, item)
    end

    local orig_menu_init = Menu.init

    function Menu:init()
        if self.name == "filemanager" and not self.height then
            self.height = Screen:getHeight() - getNavbarHeight()
        elseif not _skip_standalone_navbar and isStandaloneNavbarView(self) then
            -- Override height even if already set (e.g. Rakuyomi sets height = screen_h)
            local reserve = getNavbarHeight()
            self.height = Screen:getHeight() - reserve
            -- Force borderless for plugin views that forgot to set it (e.g. Rakuyomi)
            if not self.is_borderless then
                self.is_borderless = true
            end
        end
        orig_menu_init(self)
        if not _skip_standalone_navbar and isStandaloneNavbarView(self) then
            preventStandaloneSwipeClose(self)
        end
        -- Plugin views can need delayed injection when they can't be hooked via show functions.
        -- so inject navbar via nextTick from here. Hide-pagination doesn't
        -- apply to these views so there's no ordering conflict.
        local nexttick_tab_id = getStandaloneNextTickTabId(self)
        if nexttick_tab_id and not self._zen_standalone_navbar_pending
                and not self._zen_standalone_navbar_injected then
            self._zen_standalone_navbar_pending = true
            local menu = self
            UIManager:nextTick(function()
                menu._zen_standalone_navbar_pending = nil
                injectStandaloneNavbar(menu, nexttick_tab_id)
                UIManager:setDirty(menu, "ui")
            end)
        end
    end

    -- === Auto-switch active tab on folder change ===

    local function tabForFileManagerPath(path)
        if not path then return end

        local active_custom, active_folder = getCustomFolderTab(active_tab)
        if active_custom and isInFolderPath(path, active_folder) then
            return active_tab
        end

        if isInFolderPath(path, config.folder_path) then
            return "folder"
        end
        if config.manga_action == "folder" and config.manga_folder ~= ""
                and isInFolderPath(path, config.manga_folder) then
            return "manga"
        end
        if config.news_action == "folder" and config.news_folder ~= ""
                and isInFolderPath(path, config.news_folder) then
            return "news"
        end
        if type(config.custom_tabs) == "table" then
            for _i, tab in ipairs(config.custom_tabs) do
                local folder = type(tab) == "table"
                    and select(2, getCustomFolderTab(tab.id)) or nil
                if folder and isInFolderPath(path, folder) then return tab.id end
            end
        end

        local home_dir = paths.getHomeDir()
                         or require("apps/filemanager/filemanagerutil").getDefaultDir()
        if home_dir and paths.isInHomeDir(path) then return "books" end
    end

    local function syncFileManagerTabForPath(fm, path, repaint)
        local new_tab = tabForFileManagerPath(path)
        if not new_tab or new_tab == active_tab then return false end
        active_tab = new_tab
        syncActiveTabLabel()
        if repaint then
            injectNavbar(fm)
            UIManager:setDirty(fm, "ui")
        end
        return true
    end

    local orig_onPathChanged = FileManager.onPathChanged

    function FileManager:onPathChanged(path)
        if orig_onPathChanged then
            orig_onPathChanged(self, path)
        end

        syncFileManagerTabForPath(self, path, true)
    end

    -- === Physical Home button: return to the default navbar tab ===

    local orig_onHome = FileManager.onHome

    function FileManager:onHome()
        if is_navbar_enabled() then
            utils.closeWidgetsAbove(self)
            open_default_tab()
            return true
        end
        if orig_onHome then
            return orig_onHome(self)
        end
    end

    -- Inject navbar into FM after all plugins finish init.

    local function resizeFileChooser(file_chooser, target_height)
        if not file_chooser or target_height <= 0 then
            return
        end
        if file_chooser.height == target_height then
            return
        end
        if not file_chooser.dimen or not file_chooser.inner_dimen then
            return  -- not yet laid out; skip to avoid crash
        end

        local chrome = file_chooser.dimen.h - file_chooser.inner_dimen.h
        file_chooser.height = target_height
        file_chooser.dimen.h = target_height
        file_chooser.inner_dimen.h = target_height - chrome
        file_chooser:updateItems()
    end

    injectNavbar = function(fm)
        local fm_ui = fm[1]            -- FrameContainer wrapping file_chooser
        if not fm_ui then return end

        -- Another plugin (e.g. SimpleUI) may have wrapped fm[1] during orig_setupLayout,
        -- displacing the FrameContainer one level deeper. Use fm.file_chooser as an anchor
        -- to find the correct container before injecting.
        local real_fc = fm.file_chooser
        if real_fc and fm_ui[1] then
            local child1 = fm_ui[1]
            -- child1 should be real_fc (not injected) or VG{real_fc,...} (already injected).
            -- If neither, fm[1] was wrapped; check one level deeper.
            if child1 ~= real_fc and not (child1[1] and child1[1] == real_fc) then
                if child1[1] == real_fc or (child1[1] and child1[1][1] == real_fc) then
                    fm_ui = child1
                end
            end
        end

        local file_chooser
        if fm._navbar_injected then
            -- Already injected: fm_ui[1] is VerticalGroup{file_chooser, navbar}
            local maybe_group = fm_ui[1]
            if type(maybe_group) == "table" and maybe_group[1] then
                file_chooser = maybe_group[1]
            else
                -- Guard against stale state after toggling feature off.
                file_chooser = maybe_group
            end
        else
            file_chooser = real_fc or fm_ui[1]
        end
        if not file_chooser then return end

        local navbar = createNavBar()
        if not navbar then
            fm_ui[1] = file_chooser
            fm._navbar_injected = false
            resizeFileChooser(file_chooser, Screen:getHeight())
            return
        end

        fm._navbar_injected = true

        -- Update FileChooser height to account for (potentially changed) navbar height
        local navbar_h = navbar:getSize().h
        local new_height = Screen:getHeight() - navbar_h
        resizeFileChooser(file_chooser, new_height)

    -- Patch key navigation onto file_chooser instance (once per lifetime).
    -- Left/Right: drop/cycle navbar focus. Down from last item: drop to navbar.
    -- Press (held): context menu. Press (tap) / Return: activate.
    -- Up/Down/Back from navbar: return to file list. PgFwd/PgBack: page turns.
    if Device:hasKeys() and not file_chooser._zen_navbar_key_patched then
        file_chooser._zen_navbar_key_patched = true
        local cls_kp = file_chooser.onKeyPress
        local cls_kr = file_chooser.onKeyRelease
        local cls_ms = file_chooser.onMenuSelect
        local cls_press = file_chooser.onPress
        local HOLD_DELAY = 0.4
        local _press_hold_fn = nil   -- scheduled hold callback (nil = not pending)
        local _press_ctx = nil       -- "navbar" or "filelist" when hold pending
        local _back_btn_focused = false  -- status bar back chevron has keyboard focus

        local function repaintStatusBar()
            local fm2 = FileManager.instance
            if fm2 then
                fm2._zen_back_btn_focused = _back_btn_focused
                if fm2._updateStatusBar then fm2:_updateStatusBar() end
                UIManager:setDirty(fm2, "ui")
            end
        end

        local function repaintNavbar()
            local fm2 = FileManager.instance
            if fm2 then injectNavbar(fm2); UIManager:setDirty(fm2, "ui") end
        end

        -- Activate the currently focused navbar tab (tap behaviour).
        local function activateNavbarTab()
            local vis_tabs = getVisibleTabs()
            local idx = _navbar_focused_idx
            _navbar_focused_idx = nil
            local tab = vis_tabs and vis_tabs[idx]
            if not tab then return end
            local tid = tab.id
            local track = shouldTrackActiveTab(tid)
            if track and tid ~= active_tab then
                setActiveTab(tid)
            end
            runTabCallback(tid)
        end

        -- Focus the navbar at the active tab, starting from the given key direction.
        local function focusNavbar(direction, vis_tabs)
            _back_btn_focused = false  -- mutually exclusive with navbar focus
            setSelectedWidgetFocus(file_chooser, false)
            local n = #vis_tabs
            _navbar_focused_idx = 1
            for i, tab in ipairs(vis_tabs) do
                if tab.id == active_tab then _navbar_focused_idx = i; break end
            end
            if direction == "Right" then
                _navbar_focused_idx = (_navbar_focused_idx % n) + 1
            end
        end

        -- Cancel any pending hold timer, returning whether a tap should fire.
        local function cancelHold()
            if _press_hold_fn then
                UIManager:unschedule(_press_hold_fn)
                _press_hold_fn = nil
                local ctx = _press_ctx
                _press_ctx = nil
                return ctx  -- "navbar" or "filelist"
            end
            return nil
        end

        -- Show context menu for current directory (navbar hold = blank-space context).
        local function showCurrentDirMenu(fc)
            local item = {
                path = fc.path,
                is_file = false,
                is_go_up = false,
                text = fc.path:match("([^/]+)/?$") or fc.path,
            }
            fc:showFileDialog(item)
        end

        file_chooser.onKeyPress = function(fc, key)
            local vis_tabs = getVisibleTabs()
            local n = #vis_tabs
            if n > 0 then
                if _navbar_focused_idx then
                    -- === Navbar focused ===
                    if key == "Left" then
                        _navbar_focused_idx = ((_navbar_focused_idx - 2) % n) + 1
                        repaintNavbar(); return true
                    elseif key == "Right" then
                        _navbar_focused_idx = (_navbar_focused_idx % n) + 1
                        repaintNavbar(); return true
                    elseif key == "Press" then
                        -- Hold = current-dir context menu; tap = activate tab.
                        _press_ctx = "navbar"
                        _press_hold_fn = function()
                            _press_hold_fn = nil; _press_ctx = nil
                            showCurrentDirMenu(fc)
                        end
                        UIManager:scheduleIn(HOLD_DELAY, _press_hold_fn)
                        return true
                    elseif key == "Return" then
                        -- Physical keyboard Enter = immediate activate.
                        activateNavbarTab(); return true
                    elseif key == "Back" then
                        _navbar_focused_idx = nil
                        setSelectedWidgetFocus(fc, true)
                        repaintNavbar(); return true
                    end
                else
                    -- === Back button focused ===
                    -- "Back" event is handled via file_chooser.onBack below.
                    -- Only handle keyboard Enter / D-pad OK here.
                    if _back_btn_focused then
                        if key == "Return" or key == "Press" then
                            local fm2 = FileManager.instance
                            local back_zone = fm2 and fm2._zen_back_tap_zone
                            if back_zone and back_zone.callback then
                                back_zone.callback()
                            end
                            _back_btn_focused = false
                            repaintStatusBar()
                        else
                            _back_btn_focused = false
                            setSelectedWidgetFocus(fc, true)
                            repaintStatusBar()
                        end
                        return true
                    end
                    -- Left (or Right on full D-pad) → focus navbar.
                    local goes_to_nav = key == "Left"
                        or (key == "Right" and not Device:hasFewKeys())
                    if goes_to_nav then
                        focusNavbar(key, vis_tabs)
                        repaintNavbar(); return true
                    end
                    -- Press: hold = file context menu, tap = open (handled on release).
                    if key == "Press" then
                        _press_ctx = "filelist"
                        _press_hold_fn = function()
                            _press_hold_fn = nil; _press_ctx = nil
                            fc:sendHoldEventToFocusedWidget()
                        end
                        UIManager:scheduleIn(HOLD_DELAY, _press_hold_fn)
                        return true  -- don't open file on key-down; wait for release
                    end
                end
            end
            return cls_kp(fc, key)
        end

        file_chooser.onKeyRelease = function(fc, key)
            if key == "Press" then
                local ctx = cancelHold()
                if ctx == "navbar" then
                    activateNavbarTab(); return true
                elseif ctx == "filelist" then
                    -- Tap: pass Press to the class handler to open/select the item.
                    cls_kp(fc, key); return true
                end
                -- Hold already fired (fn was nil) — nothing to do.
                return true
            end
            return cls_kr and cls_kr(fc, key)
        end

        -- On non-touch, key-only devices (e.g Kindle 4 NT), Enter may be
        -- delivered as the menu selection event for the still-selected book.
        -- When our virtual navbar has focus, consume that path and activate the
        -- focused tab instead, so the list's retained selection is not opened.
        file_chooser.onMenuSelect = function(fc, item)
            if _navbar_focused_idx then
                activateNavbarTab(); return true
            end
            return cls_ms and cls_ms(fc, item)
        end

        file_chooser.onPress = function(fc)
            if _navbar_focused_idx then
                activateNavbarTab(); return true
            end
            return cls_press and cls_press(fc)
        end

        -- All d-pad moves dispatch as FocusMove events (args={dx,dy}), not onKeyPress.
        -- Patch onFocusMove to handle navbar focus cycling and last-row→navbar.
        local cls_fm = file_chooser.onFocusMove
        file_chooser.onFocusMove = function(fc, args)
            local dx = args and args[1] or 0
            local dy = args and args[2] or 0
            local vis_tabs = getVisibleTabs()
            local n = #vis_tabs
            if n > 0 then
                if _navbar_focused_idx then
                    if dy == -1 then
                        -- Up from navbar → return to file list
                        _navbar_focused_idx = nil
                        setSelectedWidgetFocus(fc, true)
                        repaintNavbar(); return true
                    elseif dx == -1 then
                        _navbar_focused_idx = ((_navbar_focused_idx - 2) % n) + 1
                        repaintNavbar(); return true
                    elseif dx == 1 then
                        _navbar_focused_idx = (_navbar_focused_idx % n) + 1
                        repaintNavbar(); return true
                    end
                    return true  -- consume any other move while navbar focused
                end
                if _back_btn_focused then
                    -- Any d-pad move while back button focused: unfocus and consume.
                    _back_btn_focused = false
                    setSelectedWidgetFocus(fc, true)
                    repaintStatusBar(); return true
                end
                if dy == 1 and fc.selected and fc.layout
                        and not fc.layout[fc.selected.y + 1] then
                    -- Down on last row → focus navbar
                    focusNavbar("Down", vis_tabs)
                    repaintNavbar(); return true
                end
                -- Up from first layout row → focus status bar back chevron.
                if dy == -1 and fc.selected and fc.layout
                        and not fc.layout[fc.selected.y - 1] then
                    local fm2 = FileManager.instance
                    local back_zone = fm2 and fm2._zen_back_tap_zone
                    if back_zone and back_zone.callback then
                        _back_btn_focused = true
                        setSelectedWidgetFocus(fc, false)
                        repaintStatusBar(); return true
                    end
                end
            end
            return cls_fm and cls_fm(fc, args)
        end

        -- Override onBack (the event fired by key_events.Back regardless of
        -- the physical key name or device Back-group mapping).
        local cls_ob = file_chooser.onBack
        file_chooser.onBack = function(fc)
            if _back_btn_focused then
                -- Back confirms the focused back-button chevron.
                local fm2 = FileManager.instance
                local back_zone = fm2 and fm2._zen_back_tap_zone
                if back_zone and back_zone.callback then back_zone.callback() end
                _back_btn_focused = false
                repaintStatusBar(); return true
            end
            if _navbar_focused_idx then
                -- Back unfocuses the navbar row.
                _navbar_focused_idx = nil
                setSelectedWidgetFocus(fc, true)
                repaintNavbar(); return true
            end
            -- Navigate to parent folder via zen back zone.
            local fm2 = FileManager.instance
            local back_zone = fm2 and fm2._zen_back_tap_zone
            if back_zone and back_zone.callback then
                back_zone.callback(); return true
            end
            return cls_ob and cls_ob(fc)
        end
    end

        fm_ui[1] = VerticalGroup:new{
            file_chooser,
            navbar,
        }
        if fm_ui.resetLayout then fm_ui:resetLayout() end
    end

    -- === Inject navbar into standalone views (History, Favorites, Collections) ===

    injectStandaloneNavbar = function(menu, view_tab_id)
        if not menu or not menu[1] then return end
        menu._zen_navbar_tab_id = view_tab_id
        if type(menu._zen_library_bg_reopen) ~= "function" then
            menu._zen_library_bg_reopen = function()
                return open_tab(view_tab_id)
            end
        end
        if menu._zen_standalone_navbar_injected then return end
        _G.__ZEN_UI_ACTIVE_TAB_LABEL = tabs_by_id[view_tab_id] and tabs_by_id[view_tab_id].label or view_tab_id
        StandalonePage.enable_gesture_manager_dispatch(menu)
        preventStandaloneSwipeClose(menu)
        if not is_navbar_enabled() then
            return
        end

        -- Suppress the invisible page-info tap target ("go to letter/page" dialog)
        if menu.page_info_text then
            menu.page_info_text.tap_input  = nil
            menu.page_info_text.hold_input = nil
        end

        -- Temporarily highlight the view's tab
        local saved_active = active_tab
        active_tab = view_tab_id
        local navbar = createNavBar()
        active_tab = saved_active

        if not navbar then return end
        menu._zen_standalone_navbar_injected = true

        -- Override tap handler for standalone view context
        navbar.onTapNavBar = function(self_nb, _, ges)
            local tapped_id = self_nb:getTappedTabId(ges.pos)
            if not tapped_id then return false end

            -- Already in this view: close detail to return to group, or scroll to first page
            if tapped_id == view_tab_id then
                if view_tab_id == "home" and resetHomeStripPages() then
                    return true
                end
                local is_collection_detail = menu._zen_collection_detail == true
                local is_detail = menu.name == "authors_detail"
                    or menu.name == "series_detail"
                    or menu.name == "languages_detail"
                    or menu.name == "tags_detail"
                    or is_collection_detail
                if is_collection_detail and type(menu.onReturn) == "function" then
                    menu:onReturn()
                    local features = zen_plugin.config and zen_plugin.config.features
                    local manager = menu._manager
                    local hide_underlines = get_shared("hideMenuUnderlines")
                    if type(features) == "table"
                            and features.browser_hide_underline == true
                            and manager and manager.coll_list
                            and type(hide_underlines) == "function" then
                        hide_underlines(manager.coll_list)
                    end
                elseif is_detail then
                    if menu.close_callback then
                        menu.close_callback()
                    elseif menu.onClose then
                        menu:onClose()
                    else
                        UIManager:close(menu)
                    end
                else
                    menu.page = 1
                    menu:updateItems()
                end
                return true
            end

            if not shouldTrackActiveTab(tapped_id) then
                if shouldCloseStandaloneBeforeAction(menu, tapped_id) then
                    closeStandaloneView(menu)
                end
                runTabCallback(tapped_id)
                return true
            end

            -- Close this standalone view first
            if tapped_id == "books" then
                setActiveTab(tapped_id)
                if menu.name ~= "home"
                        or not retainHomeBelowFileManager(FileManager.instance, menu) then
                    closeStandaloneView(menu)
                end
                runTabCallback(tapped_id)
                return true
            end

            local keep_home = menu.name == "home"
                and isGroupViewTab(tapped_id)
            if not keep_home then closeStandaloneView(menu) end

            -- Update FM navbar active tab only for persistent views.
            if shouldTrackActiveTab(tapped_id) then
                setActiveTab(tapped_id)
            end

            -- Execute the tapped tab's callback
            runTabCallback(tapped_id)

            return true
        end

        -- Expand dimen to full screen so gestures and repaints cover the navbar area
        menu.dimen.h = Screen:getHeight()
        onStandaloneNavbarInjected(menu)
        -- Suppress the spurious partial_page_repaint nextTick forceRePaint that fires
        -- after updateItems on initial load — the UIManager:show() paint already covers it.
        menu._zen_no_forced_repaint = true

        -- Wrap with navbar below,
        -- opaque background to prevent FM navbar bleed-through
        local FrameContainer = require("ui/widget/container/framecontainer")
        local body_widget = menu[1]
        local vg_children = { align = "left" }
        table.insert(vg_children, body_widget)
        table.insert(vg_children, navbar)

        local vg = VerticalGroup:new(vg_children)
        menu._zen_navbar_height = navbar:getSize().h
        local function resizeStandaloneBody(navbar_h)
            local screen_w = Screen:getWidth()
            local screen_h = Screen:getHeight()
            local body_h = screen_h - navbar_h
            if body_h < 1 then body_h = screen_h end
            menu.width = screen_w
            menu.height = body_h
            if menu.dimen then
                menu.dimen.w = screen_w
                menu.dimen.h = screen_h
            end
            if menu.inner_dimen then
                menu.inner_dimen.w = screen_w - 2 * (menu.border_size or 0)
                menu.inner_dimen.h = body_h
            end
            if type(body_widget) == "table" then
                body_widget.width = screen_w
                body_widget.height = body_h
                if body_widget.dimen then
                    body_widget.dimen.w = screen_w
                    body_widget.dimen.h = body_h
                end
                if body_widget.inner_dimen then
                    body_widget.inner_dimen.w = screen_w - 2 * (menu.border_size or 0)
                    body_widget.inner_dimen.h = body_h
                end
                local content_widget = body_widget[1]
                if type(content_widget) == "table" then
                    if content_widget.dimen then
                        content_widget.dimen.w = menu.inner_dimen.w
                        content_widget.dimen.h = menu.inner_dimen.h
                    end
                    for i = 1, #content_widget do
                        local child = content_widget[i]
                        if type(child) == "table" and child.dimen then
                            child.dimen.w = menu.inner_dimen.w
                            child.dimen.h = menu.inner_dimen.h
                        end
                    end
                end
                if body_widget.resetLayout then body_widget:resetLayout() end
            end
            if menu._zen_stats_rebuild then menu:_zen_stats_rebuild() end
            refreshStandaloneAfterResize(menu)
            if vg.resetLayout then vg:resetLayout() end
            if menu[1] and menu[1].resetLayout then menu[1]:resetLayout() end
        end
        resizeStandaloneBody(menu._zen_navbar_height)
        local reopenStandaloneAfterResize
        menu._zen_reinject_navbar = function()
            local saved_active_local = active_tab
            active_tab = view_tab_id
            local new_nb = createNavBar()
            active_tab = saved_active_local
            if not new_nb then return end
            menu._zen_navbar_refresh_pending = nil
            local new_h = new_nb:getSize().h
            local old_h = menu._zen_navbar_height or new_h
            if new_h ~= old_h and menu.name == "home" then
                local Home = get_shared("home")
                if Home and Home.showHomeView then
                    UIManager:close(menu)
                    Home.showHomeView(injectStandaloneNavbar)
                    return "reopened"
                end
            end
            local is_group_view = menu.name == "authors"
                or menu.name == "series"
                or menu.name == "languages"
                or menu.name == "tags"
                or menu.name == "to_be_read"
                or menu.name == "authors_detail"
                or menu.name == "series_detail"
                or menu.name == "languages_detail"
                or menu.name == "tags_detail"
                or menu.name == "status_detail"
            local is_booklist_view = view_tab_id == "history"
                or view_tab_id == "favorites"
                or view_tab_id == "collections"
                or view_tab_id == "kindle"
            if new_h ~= old_h
                    and (is_group_view or is_booklist_view)
                    and reopenStandaloneAfterResize then
                reopenStandaloneAfterResize()
                return "reopened"
            end
            menu._zen_navbar_height = new_h
            vg[2] = new_nb
            resizeStandaloneBody(new_h)
            UIManager:setDirty(menu, "ui")
        end

        reopenStandaloneAfterResize = function()
            if menu._zen_standalone_reopen_scheduled then return false end
            menu._zen_standalone_reopen_scheduled = true
            utils.closeWidgetsAbove(menu)
            if menu.close_callback then menu.close_callback()
            elseif menu.onClose then menu:onClose()
            else UIManager:close(menu) end
            if menu._zen_close_stack then menu._zen_close_stack() end
            UIManager:nextTick(function()
                setActiveTab(view_tab_id)
                runTabCallback(view_tab_id)
            end)
            return false
        end

        function menu:onSetRotationMode(rotation)
            if rotation ~= nil and rotation ~= Screen:getRotationMode() then
                local fm = FileManager.instance
                if fm and type(fm.onSetRotationMode) == "function" then
                    fm:onSetRotationMode(rotation)
                else
                    Screen:setRotationMode(rotation)
                    UIManager:onRotation()
                end
                reopenStandaloneAfterResize()
                return true
            end
            return false
        end

        function menu:onScreenResize()
            return reopenStandaloneAfterResize()
        end

        function menu:onSetDimensions()
            return reopenStandaloneAfterResize()
        end

        menu[1] = FrameContainer:new{
            background = Blitbuffer.COLOR_WHITE,
            bordersize = 0,
            padding = 0,
            margin = 0,
            vg,
        }

        -- Key nav for standalone views (group view, history, favorites, etc.)
        local has_keys = Device:hasKeys()
        if has_keys and not menu._zen_navbar_key_patched then
            menu._zen_navbar_key_patched = true

            menu.key_events = menu.key_events or {}
            menu.key_events.ZenNavbarFocusLeft = {
                { "Left" },
                event = "ZenNavbarFocusLeft",
            }
            menu.key_events.ZenNavbarFocusRight = {
                { "Right" },
                event = "ZenNavbarFocusRight",
            }
            menu.key_events.ZenNavbarFocusUp = {
                { "Up" },
                event = "ZenNavbarFocusUp",
            }
            menu.key_events.ZenNavbarFocusDown = {
                { "Down" },
                event = "ZenNavbarFocusDown",
            }
            menu.key_events.ZenNavbarConfirm = {
                { "Press" },
                { "Return" },
                event = "ZenNavbarConfirm",
            }

            local function repaintStandaloneNavbar()
                if menu._zen_reinject_navbar then
                    menu._zen_reinject_navbar()
                end
            end

            local function focusStandaloneNavbar(vis_tabs)
                setSelectedWidgetFocus(menu, false)
                _navbar_focused_idx = 1
                for i, tab in ipairs(vis_tabs) do
                    if tab.id == view_tab_id then
                        _navbar_focused_idx = i; break
                    end
                end
            end

            local function activateStandaloneTab()
                local vis_tabs = getVisibleTabs()
                local idx = _navbar_focused_idx
                _navbar_focused_idx = nil
                local tab = vis_tabs and vis_tabs[idx]
                if not tab then return end
                local tapped_id = tab.id
                if tapped_id == view_tab_id then
                    menu.page = 1; menu:updateItems(); return
                end
                if not shouldTrackActiveTab(tapped_id) then
                    if shouldCloseStandaloneBeforeAction(menu, tapped_id) then
                        closeStandaloneView(menu)
                    end
                    runTabCallback(tapped_id)
                    return
                end
                if tapped_id == "books" then
                    setActiveTab(tapped_id)
                    if menu.name ~= "home"
                            or not retainHomeBelowFileManager(FileManager.instance, menu) then
                        closeStandaloneView(menu)
                    end
                    runTabCallback(tapped_id)
                    return
                end
                closeStandaloneView(menu)
                if shouldTrackActiveTab(tapped_id) then
                    setActiveTab(tapped_id)
                end
                runTabCallback(tapped_id)
            end

            local function moveStandaloneNavbar(m, dx, dy)
                local vis_tabs = getVisibleTabs()
                local n = #vis_tabs
                if n > 0 then
                    if _navbar_focused_idx then
                        if dy == -1 then
                            _navbar_focused_idx = nil
                            setSelectedWidgetFocus(m, true)
                            repaintStandaloneNavbar(); return true
                        elseif dx == -1 then
                            _navbar_focused_idx = ((_navbar_focused_idx - 2) % n) + 1
                            repaintStandaloneNavbar(); return true
                        elseif dx == 1 then
                            _navbar_focused_idx = (_navbar_focused_idx % n) + 1
                            repaintStandaloneNavbar(); return true
                        end
                        return true
                    end
                    if dy == 1 and (not m.selected or not m.layout
                            or not m.layout[m.selected.y + 1]) then
                        focusStandaloneNavbar(vis_tabs)
                        repaintStandaloneNavbar(); return true
                    end
                end
                return false
            end

            local cls_sfm = menu.onFocusMove
            local cls_sp = menu.onPress

            function menu:onZenNavbarFocusLeft()
                if moveStandaloneNavbar(self, -1, 0) then return true end
                return cls_sfm and cls_sfm(self, { -1, 0 })
            end

            function menu:onZenNavbarFocusRight()
                if moveStandaloneNavbar(self, 1, 0) then return true end
                return cls_sfm and cls_sfm(self, { 1, 0 })
            end

            function menu:onZenNavbarFocusUp()
                if moveStandaloneNavbar(self, 0, -1) then return true end
                return cls_sfm and cls_sfm(self, { 0, -1 })
            end

            function menu:onZenNavbarFocusDown()
                if moveStandaloneNavbar(self, 0, 1) then return true end
                return cls_sfm and cls_sfm(self, { 0, 1 })
            end

            function menu:onZenNavbarConfirm()
                if _navbar_focused_idx then
                    activateStandaloneTab(); return true
                end
                return cls_sp and cls_sp(self)
            end

            -- D-pad moves arrive as FocusMove events, not onKeyPress.
            menu.onFocusMove = function(m, args)
                local dx = args and args[1] or 0
                local dy = args and args[2] or 0
                if moveStandaloneNavbar(m, dx, dy) then return true end
                return cls_sfm and cls_sfm(m, args)
            end

            local cls_skp = menu.onKeyPress
            menu.onKeyPress = function(m, key)
                local is_menu_key = key == "Menu"
                if not is_menu_key and type(key) == "table"
                        and type(key.match) == "function" then
                    is_menu_key = key:match({ "Menu" })
                end
                if is_menu_key then
                    local fm = FileManager.instance
                    local fm_menu = fm and fm.menu
                    if fm_menu and type(fm_menu.onShowMenu) == "function" then
                        return fm_menu:onShowMenu()
                    end
                end
                local vis_tabs = getVisibleTabs()
                if #vis_tabs > 0 and _navbar_focused_idx then
                    if key == "Return" or key == "Press" then
                        activateStandaloneTab(); return true
                    end
                end
                return cls_skp and cls_skp(m, key)
            end

            menu.onPress = function(m)
                if _navbar_focused_idx then
                    activateStandaloneTab(); return true
                end
                return cls_sp and cls_sp(m)
            end

            -- Back event (fired by key_events regardless of physical key name).
            menu.onBack = function(m)
                if _navbar_focused_idx then
                    _navbar_focused_idx = nil
                    setSelectedWidgetFocus(m, true)
                    repaintStandaloneNavbar(); return true
                end
                local fm = FileManager.instance
                if view_tab_id == "home" and fm then
                    setActiveTab("books")
                    if not retainHomeBelowFileManager(fm, m) then
                        closeStandaloneView(m)
                    end
                    runTabCallback("books")
                    return true
                end
                if m.close_callback then m.close_callback()
                elseif m.onClose then m:onClose()
                else UIManager:close(m) end
                return true
            end
        end

        if not has_keys and view_tab_id == "home" then
            menu.onBack = function(m)
                local fm = FileManager.instance
                if fm then
                    setActiveTab("books")
                    if not retainHomeBelowFileManager(fm, m) then
                        closeStandaloneView(m)
                    end
                    runTabCallback("books")
                    return true
                end
                if m.close_callback then m.close_callback()
                elseif m.onClose then m:onClose()
                else UIManager:close(m) end
                return true
            end

            -- Physical Home button: close this standalone view and return to
            -- the default navbar tab, same as pressing Home from the main FM.
            menu.key_events = menu.key_events or {}
            menu.key_events.Home = { { "Home" } }
            function menu:onHome()
                _navbar_focused_idx = nil
                closeStandaloneView(self)
                open_default_tab()
                return true
            end
        end

        -- Top south swipe → open KOReader menu is handled globally by
        -- menu_top_swipe (class-level patch on Menu.onSwipe).
    end

    -- Save current library view state just before the reader takes over.
    -- The FM is about to be destroyed; we persist {tab, page} so that when
    -- showFileManager() recreates it we can scroll back to the right place.
    local orig_fm_onShowingReader = FileManager.onShowingReader
    function FileManager:onShowingReader()
        local started_at = os.clock()
        local gv = get_shared("group_view")
        local source_tab = rawget(_G, "__ZEN_UI_LIBRARY_SOURCE_TAB") or active_tab
        local force_source_restore = rawget(_G, "__ZEN_UI_FORCE_SOURCE_TAB_RESTORE") == true
        local rakuyomi_return_file = rawget(_G, "__ZEN_UI_RAKUYOMI_RETURN_FILE")
        if force_source_restore or rakuyomi_return_file then
            logger.dbg(
                "Rakuyomi return: onShowingReader capture:",
                "source_tab=", tostring(source_tab),
                "force=", tostring(force_source_restore),
                "file=", tostring(rakuyomi_return_file))
        end
        _G.__ZEN_UI_LIBRARY_SOURCE_TAB = nil
        _G.__ZEN_UI_FORCE_SOURCE_TAB_RESTORE = nil
        _G.__ZEN_UI_RAKUYOMI_RETURN_FILE = nil
        if (is_restore_enabled() or force_source_restore)
                and (force_source_restore or not skipTabState(source_tab)) then
            local page = 1
            -- Group views expose page via M.getActivePage
            if gv and gv.getActivePage then
                page = gv.getActivePage(getGroupViewTab(source_tab)) or 1
            end
            local home = get_shared("home")
            if home and source_tab == "home" and home.getActivePage then
                page = home.getActivePage() or 1
            end
            -- Standalone views: history / favorites / collections
            local fm = FileManager.instance
            if fm and source_tab == "history"
                    and fm.history and fm.history.booklist_menu then
                page = fm.history.booklist_menu.page or 1
            elseif fm and (source_tab == "favorites" or source_tab == "collections")
                    and fm.collections and fm.collections.booklist_menu then
                page = fm.collections.booklist_menu.page or 1
            end
            -- If a detail view (author/series book list) was open, save which one
            local detail_group, detail_page
            if gv and gv.getActiveDetail then
                local detail = gv.getActiveDetail()
                if detail then
                    detail_group = detail.group_name
                    detail_page  = detail.page
                end
            end
            _G.__ZEN_UI_LIBRARY_STATE = {
                tab          = source_tab,
                page         = page,
                detail_group = detail_group,
                detail_page  = detail_page,
                force_restore = force_source_restore,
                rakuyomi_return_file = rakuyomi_return_file,
            }
        else
            _G.__ZEN_UI_LIBRARY_STATE = nil
        end
        local home = get_shared("home")
        if gv and gv.closeAll then gv.closeAll() end
        if home and home.closeAll then home.closeAll() end
        local fm = FileManager.instance
        if fm then
            if fm.history and fm.history.booklist_menu then
                UIManager:close(fm.history.booklist_menu)
                fm.history.booklist_menu = nil
            end
            if fm.collections then
                if fm.collections.booklist_menu then
                    UIManager:close(fm.collections.booklist_menu)
                    fm.collections.booklist_menu = nil
                end
                if fm.collections.coll_list then
                    UIManager:close(fm.collections.coll_list)
                    fm.collections.coll_list = nil
                end
            end
        end
        if orig_fm_onShowingReader then orig_fm_onShowingReader(self) end
        logger.perf("Library state captured for reader", (os.clock() - started_at) * 1000,
            "tab=", tostring(source_tab))
    end

    local orig_setupLayout = FileManager.setupLayout

    local function should_defer_cold_default_home(fm)
        if FileManager.instance ~= nil or rawget(fm, "file_chooser") ~= nil then
            return false
        end
        if rawget(_G, "__ZEN_UI_HIDDEN_HOME_BOOTSTRAP") == true
                or rawget(_G, "__ZEN_UI_DEFER_FILEMANAGER_LISTING") ~= nil
                or resolve_default_tab() ~= "home" then
            return false
        end
        if rawget(_G, "__ZEN_UI_OPEN_HOME_AFTER_FILEMANAGER") == true
                or rawget(_G, "__ZEN_UI_OPEN_TARGET_TAB") ~= nil
                or rawget(_G, "__ZEN_UI_OPEN_TARGET_FOLDER") ~= nil
                or rawget(_G, "__ZEN_UI_OPEN_TARGET_TAG") ~= nil
                or rawget(_G, "__ZEN_UI_LIBRARY_STATE") ~= nil then
            return false
        end
        return not is_restore_enabled() or not fm.focused_file
    end

    function FileManager:setupLayout()
        local defer_default_home = should_defer_cold_default_home(self)
        if defer_default_home then
            local home_dir = paths.getHomeDir()
            if home_dir then self.root_path = home_dir end
            self.focused_file = nil
            self.invisible = true
            withHiddenHomeBootstrap(self.root_path, function()
                if orig_setupLayout then orig_setupLayout(self) end
            end)
            local fc = self.file_chooser
            self._zen_hidden_home_startup = true
            if fc then
                fc._zen_hidden_home_startup = true
                fc._zen_needs_full_listing = true
                fc._zen_needs_cover_refresh = nil
            end
            logger.measure("Cold Home setup deferred", 0,
                "path=", tostring(self.root_path),
                "listing_deferred=", true,
                "covers_suppressed=", true)
        elseif orig_setupLayout then
            orig_setupLayout(self)
        end
        self._navbar_injected = false
        if defer_default_home then
            withHiddenHomeBootstrap(self.root_path, function()
                injectNavbar(self)
            end)
        else
            injectNavbar(self)
        end
    end

    -- Restore the view state (group tab + optional detail) when returning from the reader.
    -- Patching showFiles (rather than setupLayout) is critical: UIManager:show(fm) is called
    -- inside showFiles *after* setupLayout returns.  Any overlay we show here therefore lands
    -- *above* fm in the window stack, so _repaint starts from the overlay (topmost
    -- covers_fullscreen) and never paints the FM books view at all -- no flash, no artifacts.
    local orig_showFiles = FileManager.showFiles

    local function filemanager_stack_index(fm)
        local stack = UIManager._window_stack
        if type(stack) ~= "table" then return end
        for index = 1, #stack do
            local widget = stack[index] and stack[index].widget
            if widget == fm or (widget and widget == fm.show_parent) then
                return index
            end
        end
    end

    local function open_default_tab_below_startup_widgets(fm, anchor_index)
        local stack = UIManager._window_stack
        local upper_windows = {}
        local upper_set = {}
        local protect_input = false
        for index = anchor_index + 1, #stack do
            local window = stack[index]
            upper_windows[#upper_windows + 1] = window
            upper_set[window] = true
            if window.widget and not window.widget.toast then
                protect_input = true
            end
        end

        local input = Device.input
        local input_state = protect_input and {
            disable_double_tap = input and input.disable_double_tap,
            tap_interval_override = input and input.tap_interval_override,
            gestures_disabled = UIManager._input_gestures_disabled == true,
        } or nil

        open_default_tab()

        local new_windows = {}
        if #upper_windows > 0 then
            anchor_index = filemanager_stack_index(fm)
            if anchor_index then
                local retained_upper = {}
                for index = anchor_index + 1, #stack do
                    local window = stack[index]
                    if upper_set[window] then
                        retained_upper[window] = true
                    else
                        new_windows[#new_windows + 1] = window
                    end
                end
                while #stack > anchor_index do table.remove(stack) end
                for _i, window in ipairs(new_windows) do
                    stack[#stack + 1] = window
                end
                for _i, window in ipairs(upper_windows) do
                    if retained_upper[window] then stack[#stack + 1] = window end
                end
            end
        end
        if input_state and input then
            input.disable_double_tap = input_state.disable_double_tap
            input.tap_interval_override = input_state.tap_interval_override
        end
        if input_state and input_state.gestures_disabled
                and not UIManager._input_gestures_disabled then
            UIManager:setIgnoreTouchInput(true)
            for _i, window in ipairs(new_windows) do
                if window.widget then window.widget._restored_input_gestures = nil end
            end
        end
    end

    local function maybe_open_startup_default_tab(fm)
        if not fm or fm._zen_default_tab_bootstrapped
                or FileManager.instance ~= fm then
            return false
        end
        if resolve_default_tab() == "books" and active_tab == "books" then
            fm._zen_default_tab_bootstrapped = true
            return false
        end
        local anchor_index = filemanager_stack_index(fm)
        if not anchor_index then return false end
        fm._zen_default_tab_bootstrapped = true
        if FileManager.instance == fm then
            -- Preserve every widget another plugin already placed above FileManager.
            open_default_tab_below_startup_widgets(fm, anchor_index)
            return true
        end
        return false
    end

    function FileManager:showFiles(path, focused_file, selected_files)
        local started_at = os.clock()
        local open_home_after_filemanager = rawget(_G, "__ZEN_UI_OPEN_HOME_AFTER_FILEMANAGER") == true
        local open_target_tab = rawget(_G, "__ZEN_UI_OPEN_TARGET_TAB")
        local open_target_folder = rawget(_G, "__ZEN_UI_OPEN_TARGET_FOLDER")
        local open_target_tag = rawget(_G, "__ZEN_UI_OPEN_TARGET_TAG")
        local keep_book_location_requested = rawget(_G, "__ZEN_UI_KEEP_BOOK_LOCATION") == true
        local restore_enabled = is_restore_enabled()
        local state_before_show = rawget(_G, "__ZEN_UI_LIBRARY_STATE")
        local force_source_restore = state_before_show and state_before_show.force_restore == true
        local hide_rakuyomi_filemanager = force_source_restore
            and state_before_show.tab == "manga"
            and rakuyomi_return_to_chapter_list_on_exit_enabled()
        local keep_book_location = keep_book_location_requested and not force_source_restore
        if force_source_restore then
            logger.dbg(
                "Rakuyomi return: showFiles restore state:",
                "path=", tostring(path),
                "focused_file=", tostring(focused_file),
                "file=", tostring(state_before_show.rakuyomi_return_file),
                "keep_requested=", tostring(keep_book_location_requested),
                "open_home=", tostring(open_home_after_filemanager),
                "open_target_tab=", tostring(open_target_tab),
                "open_target_folder=", tostring(open_target_folder),
                "open_target_tag=", tostring(open_target_tag))
        end
        if force_source_restore then
            _G.__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB = nil
        end
        local forced_default_tab = not force_source_restore
            and not open_home_after_filemanager
            and rawget(_G, "__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB") == true
            and resolve_default_tab() or nil
        local default_tab = forced_default_tab or resolve_default_tab()
        local startup_default_home = default_tab == "home"
            and not force_source_restore
            and not open_home_after_filemanager
            and not open_target_tab
            and not open_target_folder
            and not open_target_tag
            and not keep_book_location_requested
            and not (state_before_show and state_before_show.tab)
            and (not restore_enabled or not focused_file)
        local target_folder_path = normalizeFolderPath(open_target_folder)
        if target_folder_path
                and lfs.attributes(target_folder_path, "mode") ~= "directory" then
            target_folder_path = nil
        end
        -- When restore is disabled, open at library root immediately (no double render).
        local effective_focused = not startup_default_home and not forced_default_tab
            and (restore_enabled or keep_book_location) and focused_file or nil
        if target_folder_path then
            path = target_folder_path
            effective_focused = nil
        elseif startup_default_home or forced_default_tab
                or (not restore_enabled and not keep_book_location) then
            local home_dir = require("common/paths").getHomeDir()
            if home_dir then
                path = home_dir
                if default_tab ~= "books" and self.file_chooser and self.file_chooser.path_items then
                    self.file_chooser.path_items[home_dir] = nil
                end
            end
        end
        local hidden_bootstrap = forced_default_tab ~= nil
            or startup_default_home
            or open_home_after_filemanager
            or open_target_tab
            or open_target_folder
            or open_target_tag
            or (state_before_show and state_before_show.force_restore)
            or (not restore_enabled
                and not keep_book_location
                and default_tab ~= "books")
            or (restore_enabled
                and state_before_show
                and state_before_show.tab
                and state_before_show.tab ~= "books")
        local defer_hidden_home_listing = startup_default_home
            or open_home_after_filemanager
            or open_target_tab == "home"
            or forced_default_tab == "home"
            or (restore_enabled
                and state_before_show
                and state_before_show.tab == "home")
        local suppress_initial_covers = hidden_bootstrap
        if defer_hidden_home_listing then
            withHiddenHomeBootstrap(path, function()
                orig_showFiles(self, path, effective_focused, selected_files)
            end)
        elseif suppress_initial_covers then
            withCoversSuppressed(function()
                orig_showFiles(self, path, effective_focused, selected_files)
            end)
        else
            orig_showFiles(self, path, effective_focused, selected_files)
        end
        _G.__ZEN_UI_OPEN_HOME_AFTER_FILEMANAGER = nil
        _G.__ZEN_UI_OPEN_TARGET_TAB = nil
        _G.__ZEN_UI_OPEN_TARGET_FOLDER = nil
        _G.__ZEN_UI_OPEN_TARGET_TAG = nil
        _G.__ZEN_UI_KEEP_BOOK_LOCATION = nil
        local filemanager = FileManager.instance
        -- Android may restore a focused book after setupLayout already chose hidden Home.
        if not startup_default_home
                and default_tab == "home"
                and restore_enabled
                and focused_file
                and not forced_default_tab
                and not open_home_after_filemanager
                and not open_target_tab
                and not open_target_folder
                and not open_target_tag
                and not keep_book_location_requested
                and not (state_before_show and state_before_show.tab)
                and filemanager
                and filemanager._zen_hidden_home_startup == true then
            startup_default_home = true
            defer_hidden_home_listing = true
        end
        if hide_rakuyomi_filemanager and filemanager then
            filemanager.invisible = true
            UIManager._dirty[filemanager] = nil
        end
        logger.perf("File manager base restore completed", (os.clock() - started_at) * 1000,
            "restore_tab=", tostring(state_before_show and state_before_show.tab),
            "path=", tostring(path),
            "hidden_home_startup=", tostring(defer_hidden_home_listing),
            "listing_deferred=", tostring(defer_hidden_home_listing))
        if suppress_initial_covers and not defer_hidden_home_listing
                and filemanager and filemanager.file_chooser then
            filemanager.file_chooser._zen_needs_cover_refresh = true
        end
        if defer_hidden_home_listing and filemanager and filemanager.file_chooser then
            filemanager.invisible = true
            filemanager._zen_hidden_home_startup = true
            filemanager.file_chooser._zen_hidden_home_startup = true
            filemanager.file_chooser._zen_needs_full_listing = true
            if UIManager._dirty then UIManager._dirty[filemanager] = nil end
        end
        if startup_default_home and filemanager and filemanager.file_chooser then
            filemanager._zen_default_tab_bootstrapped = true
            _G.__ZEN_UI_LIBRARY_STATE = nil
            local anchor_index = filemanager_stack_index(filemanager)
            if anchor_index then
                open_default_tab_below_startup_widgets(filemanager, anchor_index)
            else
                open_tab("home")
            end
            return
        end
        if open_home_after_filemanager then
            _G.__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB = nil
            _G.__ZEN_UI_LIBRARY_STATE = nil
            open_tab("home")
            return
        end
        if open_target_tab then
            _G.__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB = nil
            _G.__ZEN_UI_LIBRARY_STATE = nil
            open_tab(open_target_tab)
            return
        end
        if open_target_folder then
            _G.__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB = nil
            _G.__ZEN_UI_LIBRARY_STATE = nil
            local tab_id = tabForFileManagerPath(target_folder_path) or "books"
            local opened = target_folder_path
                and openFileManagerFolder(target_folder_path, tab_id)
            if opened then
                refreshSuppressedCoversNow(FileManager.instance)
            end
            return
        end
        if open_target_tag then
            _G.__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB = nil
            _G.__ZEN_UI_LIBRARY_STATE = nil
            openTag(open_target_tag, "tags")
            return
        end
        if rawget(_G, "__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB") then
            _G.__ZEN_UI_FORCE_DEFAULT_LIBRARY_TAB = nil
            _G.__ZEN_UI_LIBRARY_STATE = nil
            if forced_default_tab == "books" then
                setActiveTab("books")
                refreshSuppressedCoversNow(filemanager)
                return
            end
            open_default_tab()
            return
        end
        if keep_book_location then
            _G.__ZEN_UI_LIBRARY_STATE = nil
            return
        end
        local state = rawget(_G, "__ZEN_UI_LIBRARY_STATE")
        if not restore_enabled and not (state and state.force_restore) then
            _G.__ZEN_UI_LIBRARY_STATE = nil
            if not keep_book_location then
                maybe_open_startup_default_tab(self)
            end
            return
        end
        if not state or not state.tab or not tab_callbacks[state.tab] then
            if not focused_file and not keep_book_location then
                maybe_open_startup_default_tab(self)
            end
            return
        end
        local gv = get_shared("group_view")
        -- onPathChanged inside orig_setupLayout may have reset active_tab to "books";
        -- restore it now so onShowingReader saves the right tab on the next book open.
        active_tab = state.tab
        syncActiveTabLabel()
        -- Open group/standalone view synchronously (stack: [fm, group_menu])
        local function restoreSavedTab()
            local Rakuyomi = getRakuyomi()
            local return_enabled = rakuyomi_return_to_chapter_list_on_exit_enabled()
            local return_file = return_enabled and state.rakuyomi_return_file or nil
            if not return_enabled then
                state.rakuyomi_return_file = nil
            end
            if state.tab == "manga" and not return_enabled then
                local opened_library = type(Rakuyomi.openLibraryView) == "function"
                    and Rakuyomi.openLibraryView({ hideTopClose = true })
                logger.dbg(
                    "Rakuyomi return: restore library:",
                    "opened_library=", tostring(opened_library),
                    "manga_action=", tostring(config.manga_action),
                    "manga_destination=", tostring(config.manga_action == "folder"
                        and config.manga_folder or config.manga_action))
                return
            end
            if not return_file and state.tab == "manga" and return_enabled
                    and type(focused_file) == "string" then
                return_file = focused_file
                state.rakuyomi_return_file = return_file
            end
            local has_file_opener = return_enabled
                and type(Rakuyomi.openChapterListingFromFile) == "function"
            local opened_chapters = return_file and has_file_opener
                and Rakuyomi.openChapterListingFromFile(return_file, true)
            if opened_chapters then
                _G.__ZEN_UI_RAKUYOMI_CHAPTER_LIST_RESTORED = true
            end
            logger.dbg(
                "Rakuyomi return: restore dispatch:",
                "has_file=", tostring(return_file ~= nil),
                "has_file_opener=", tostring(has_file_opener),
                "opened_chapters=", tostring(opened_chapters),
                "fallback_tab=", tostring(state.tab),
                "manga_action=", tostring(config.manga_action),
                "manga_destination=", tostring(config.manga_action == "folder"
                    and config.manga_folder or config.manga_action))
            if not opened_chapters then
                tab_callbacks[state.tab]()
            end
        end
        restoreSavedTab()
        if filemanager and not filemanager._zen_hidden_home_startup then
            filemanager.invisible = nil
        end
        -- If a detail view was open, open it synchronously too (stack: [fm, group_menu, detail_menu]).
        -- _repaint will then start from detail_menu and never show the intermediate views.
        if state.detail_group and gv and gv.restoreDetail
                and not getCustomTagTab(state.tab)
                and not getCustomStatusTab(state.tab) then
            gv.restoreDetail(state.detail_group, state.tab, injectStandaloneNavbar)
        end
    end

    -- === Hook standalone views to inject navbar after creation ===
    -- Injection happens after UIManager:show() in the same execution frame,
    -- so the first paint uses the modified widget tree. No setDirty needed.

    local FileManagerHistory = require("apps/filemanager/filemanagerhistory")
    local orig_onShowHist = FileManagerHistory.onShowHist

    function FileManagerHistory:onShowHist(search_info)
        local result = orig_onShowHist(self, search_info)
        if self.booklist_menu then
            injectStandaloneNavbar(self.booklist_menu, "history")
            local state = rawget(_G, "__ZEN_UI_LIBRARY_STATE")
            if state and state.tab == "history" and state.page and state.page > 1 then
                local menu = self.booklist_menu
                _G.__ZEN_UI_LIBRARY_STATE = nil
                UIManager:nextTick(function()
                    if menu.onGotoPage then menu:onGotoPage(state.page) end
                end)
            end
        end
        return result
    end

    local FileManagerFileSearcher = require("apps/filemanager/filemanagerfilesearcher")
    local orig_onShowSearchResults = FileManagerFileSearcher.onShowSearchResults

    function FileManagerFileSearcher:onShowSearchResults(not_cached)
        local result = orig_onShowSearchResults(self, not_cached)
        if self.booklist_menu then
            injectStandaloneNavbar(self.booklist_menu, "search")
        end
        return result
    end

    local FileManagerCollection = require("apps/filemanager/filemanagercollection")
    local orig_onShowColl = FileManagerCollection.onShowColl

    function FileManagerCollection:onShowColl(collection_name)
        local from_coll_list = self.coll_list ~= nil
        local result = orig_onShowColl(self, collection_name)
        if self.booklist_menu then
            local inferred_tab = from_coll_list and "collections" or "favorites"
            self.booklist_menu._zen_collection_detail = from_coll_list or nil
            injectStandaloneNavbar(self.booklist_menu, inferred_tab)
            local state = rawget(_G, "__ZEN_UI_LIBRARY_STATE")
            if state and state.tab == inferred_tab and state.page and state.page > 1 then
                local menu = self.booklist_menu
                _G.__ZEN_UI_LIBRARY_STATE = nil
                UIManager:nextTick(function()
                    if menu.onGotoPage then menu:onGotoPage(state.page) end
                end)
            end
        end
        return result
    end

    local orig_onShowCollList = FileManagerCollection.onShowCollList

    function FileManagerCollection:onShowCollList(file_or_selected_collections, caller_callback, no_dialog)
        -- Skip navbar in selection mode (adding file to collection, filtering by collection)
        if file_or_selected_collections ~= nil then
            _skip_standalone_navbar = true
        end
        local result = orig_onShowCollList(self, file_or_selected_collections, caller_callback, no_dialog)
        _skip_standalone_navbar = false
        -- Only inject navbar in browse mode, not selection mode
        if self.coll_list and file_or_selected_collections == nil then
            injectStandaloneNavbar(self.coll_list, "collections")
            local state = rawget(_G, "__ZEN_UI_LIBRARY_STATE")
            if state and state.tab == "collections" and state.page and state.page > 1 then
                local menu = self.coll_list
                _G.__ZEN_UI_LIBRARY_STATE = nil
                UIManager:nextTick(function()
                    if menu.onGotoPage then menu:onGotoPage(state.page) end
                end)
            end
        end
        return result
    end

    -- === Hook QuickRSS feed view to inject navbar ===
    -- QuickRSS extends InputContainer (not Menu), so Menu:init() hook doesn't apply.
    -- We hook its init lazily on first use since the plugin path isn't available at patch load time.

    local _qrss_hooked = false

    hookQuickRSSInit = function()
        if _qrss_hooked then return end
        local ok, QuickRSSUI_class = pcall(require, "modules/ui/feed_view")
        if not ok or not QuickRSSUI_class then return end
        _qrss_hooked = true

        local ok_ai, ArticleItemModule = pcall(require, "modules/ui/article_item")
        local QRSS_ITEM_HEIGHT = ok_ai and ArticleItemModule.ITEM_HEIGHT

        local orig_qrss_init = QuickRSSUI_class.init
        function QuickRSSUI_class:init()
            orig_qrss_init(self)
            self._zen_navbar_tab_id = "news"
            StandalonePage.enable_gesture_manager_dispatch(self)

            local navbar_h = getNavbarHeight()
            if navbar_h <= 0 then return end

            -- Reduce the outer FrameContainer height
            self[1].height = self[1].height - navbar_h

            -- Reduce the article list area and recalculate items per page
            self.list_h = self.list_h - navbar_h
            if QRSS_ITEM_HEIGHT then
                self.items_per_page = math.max(1, math.floor(self.list_h / QRSS_ITEM_HEIGHT))
            end

            -- Inject navbar below the QuickRSS view
            local saved_active = active_tab
            active_tab = "news"
            local navbar = createNavBar()
            active_tab = saved_active
            if not navbar then return end
            self._zen_navbar_height = navbar:getSize().h

            -- Override tap handler for standalone view context
            navbar.onTapNavBar = function(self_nb, _, ges)
                local tapped_id = self_nb:getTappedTabId(ges.pos)
                if not tapped_id then return false end
                if tapped_id == "news" then return true end
                if not shouldTrackActiveTab(tapped_id) then
                    runTabCallback(tapped_id)
                    return true
                end
                self:onClose()
                if shouldTrackActiveTab(tapped_id) then
                    setActiveTab(tapped_id)
                end
                runTabCallback(tapped_id)
                return true
            end

            -- Wrap with navbar below, opaque background to prevent bleed-through
            local FrameContainer = require("ui/widget/container/framecontainer")
            self[1] = FrameContainer:new{
                background = Blitbuffer.COLOR_WHITE,
                bordersize = 0,
                padding = 0,
                margin = 0,
                VerticalGroup:new{
                    align = "left",
                    self[1],
                    navbar,
                },
            }

            -- Set dimen to full screen for gesture handling and setDirty
            self.dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() }

            -- Re-populate with corrected items_per_page
            if #self.articles > 0 then
                self:_populateItems()
            end
        end

        local orig_qrss_onClose = QuickRSSUI_class.onClose
        function QuickRSSUI_class:onClose()
            orig_qrss_onClose(self)
            -- Reset FM navbar to "books" when QuickRSS closes via its own close button
            setActiveTab("books")
        end
    end

    -- Hook QuickRSS init eagerly so navbar support is ready regardless
    -- of how QuickRSS is opened.
    hookQuickRSSInit()

    -- The first outer showFiles call starts before this patch is installed.
    -- Open its deferred default tab once FileManager reaches the window stack.
    local function reinject_initial_filemanager()
        local fm = FileManager.instance
        if fm then
            if fm._zen_hidden_home_startup then
                maybe_open_startup_default_tab(fm)
                return
            end
            if tabStaysInFileManager(active_tab) and fm.file_chooser then
                syncFileManagerTabForPath(fm, fm.file_chooser.path, false)
            end
            injectNavbar(fm)
            if maybe_open_startup_default_tab(fm) then return end
            UIManager:setDirty(fm, "ui")
        end
    end

    reinject_initial_filemanager()
    UIManager:nextTick(reinject_initial_filemanager)

    -- Expose a reinject function for external callers (e.g. quickstart on_close).
    -- Allows main.lua to rebuild the navbar after quickstart changes tab config.
    _G.__ZEN_UI_NAVBAR_OPEN_DEFAULT_TAB = open_default_tab
    _G.__ZEN_UI_NAVBAR_OPEN_TAB = open_tab
    _G.__ZEN_UI_NAVBAR_OPEN_FOLDER = function(path)
        local tab_id = tabForFileManagerPath(path) or "books"
        local opened = openFileManagerFolder(path, tab_id)
        return opened == true
    end
    _G.__ZEN_UI_NAVBAR_OPEN_TAG = function(tag_name)
        return openTag(tag_name, "tags")
    end
    _G.__ZEN_UI_NAVBAR_RESOLVE_DEFAULT_TAB = resolve_default_tab
    _G.__ZEN_UI_NAVBAR_IS_DEFAULT_TAB_ACTIVE = is_default_tab_active
    _G.__ZEN_UI_NAVBAR_DEFAULT_TAB_ICON = function()
        local tab = tabs_by_id[resolve_default_tab()]
        return tab and tab.icon
    end

    _G.__ZEN_UI_REINJECT_FM_NAVBAR = function()
        local fm = FileManager.instance
        if fm then
            if tabStaysInFileManager(active_tab) and fm.file_chooser then
                syncFileManagerTabForPath(fm, fm.file_chooser.path, false)
            end
            injectNavbar(fm)
            UIManager:setDirty(fm, "full")
        else
            UIManager:setDirty(nil, "full")
        end
        UIManager:forceRePaint()
    end

    _G.__ZEN_UI_REINJECT_NAVBARS = function()
        local stack = UIManager._window_stack
        local top = stack and stack[#stack]
        local top_widget = top and top.widget
        local has_standalone_navbar = top_widget
            and type(top_widget._zen_reinject_navbar) == "function"
        local standalone_result
        if top_widget and type(top_widget._zen_reinject_navbar) == "function" then
            standalone_result = top_widget:_zen_reinject_navbar()
            if standalone_result ~= "reopened" then
                UIManager:forceRePaint()
            end
        end
        if has_standalone_navbar then
            if standalone_result == "reopened" then
                return
            end
            local fm = FileManager.instance
            if fm then
                injectNavbar(fm)
            end
        else
            _G.__ZEN_UI_REINJECT_FM_NAVBAR()
        end
    end
end


return apply_navbar
