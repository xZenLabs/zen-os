local M = {}

local FileManager
local Geom
local UIManager
local logger
local _

local action_tabs_close_library = {
    continue = true,
    search = true,
    calibre_search = true,
    stats = true,
    exit = true,
}

local is_real_exit_target
local zen_plugin

local function live_plugin()
    local filemanager = package.loaded["apps/filemanager/filemanager"]
    local instance = filemanager and filemanager.instance
    if type(instance) == "table" and type(instance.rakuyomi) == "table" then
        return instance.rakuyomi
    end
end

local function loaded_plugin()
    local ok_loader, loader = pcall(require, "pluginloader")
    if not ok_loader or not loader then return nil end

    local loaded = loader.loaded_plugins
    if type(loaded) == "table" and type(loaded.rakuyomi) == "table" then
        return loaded.rakuyomi
    end

    if type(loader.getPluginInstance) == "function" then
        local ok_plugin, plugin = pcall(loader.getPluginInstance, loader, "rakuyomi")
        if ok_plugin and type(plugin) == "table" then
            return plugin
        end
    end
end

function M.is_available()
    return live_plugin() ~= nil or loaded_plugin() ~= nil
end

local function get_zen_config()
    local plugin = zen_plugin or rawget(_G, "__ZEN_UI_PLUGIN")
    if plugin and type(plugin.config) == "table" then
        return plugin.config
    end

    local ok_cm, ConfigManager = pcall(require, "config/manager")
    if ok_cm and ConfigManager and type(ConfigManager.get) == "function" then
        return ConfigManager.get()
    end
end

local function is_library_view(widget)
    return widget and widget.name == "library_view"
end

local function is_chapter_listing(widget)
    return widget and widget.name == "chapter_listing"
end

local function close_top_chapter_listing()
    local stack = UIManager._window_stack
    local top = type(stack) == "table" and stack[#stack]
    local widget = top and top.widget
    if is_chapter_listing(widget) then
        UIManager:close(widget)
    end
end

local function return_to_chapter_list_on_exit_enabled()
    local config = get_zen_config()
    local rakuyomi = config and config.rakuyomi
    if type(rakuyomi) ~= "table" then return true end
    if rakuyomi.return_to_chapter_list_on_exit ~= nil then
        return rakuyomi.return_to_chapter_list_on_exit ~= false
    end
    if rakuyomi.return_to_chapter_list_on_reader_exit ~= nil then
        return rakuyomi.return_to_chapter_list_on_reader_exit ~= false
    end
    return true
end

function M.isLibraryView(widget)
    return is_library_view(widget)
end

function M.isScrollBarMenu(widget)
    local name = widget and widget.name
    return name == "available_sources_listing"
        or name == "chapter_listing"
        or name == "installed_sources_listing"
        or name == "library_view"
        or name == "manga_search_results"
        or name == "notification_view"
end

function M.getStandaloneTabId(widget)
    if is_library_view(widget) then
        return "manga"
    end
end

function M.shouldCloseBeforeActionTab(widget, tab_id)
    return is_library_view(widget)
        and (action_tabs_close_library[tab_id] == true
            or type(tab_id) == "string" and tab_id:sub(1, 3) == "ct_")
end

local android = pcall(require, "android")
local is_android = android ~= nil

local function normalize_path(path)
    if type(path) ~= "string" or path == "" then return nil end
    if is_android then
        path = path:gsub("^/sdcard/", "/storage/emulated/0/")
    end
    return path:gsub("/+$", "")
end

local function path_is_inside(path, directory)
    path = normalize_path(path)
    directory = normalize_path(directory)

    if not (path and directory) then return false end

    local dir_prefix = directory
    if dir_prefix:sub(-1) ~= "/" then
        dir_prefix = dir_prefix .. "/"
    end

    if path:sub(1, #dir_prefix) ~= dir_prefix then
        return false
    end

    local remainder = path:sub(#dir_prefix + 1)
    return remainder ~= "" and not remainder:find("/")
end

local function get_data_dir()
    local DataStorage = require("datastorage")
    return DataStorage:getFullDataDir() or DataStorage:getDataDir()
end

local function absolute_data_path(path)
    if type(path) ~= "string" or path == "" or path:sub(1, 1) == "/" then
        return path
    end
    path = path:gsub("^%./", "")
    return get_data_dir() .. "/" .. path
end

local storage_path_loaded = false
local storage_path_cache
local origin_metadata_cache = {}
local metadata_cache = {}
local series_cover_paths = {}

local function get_storage_path()
    if storage_path_loaded then
        return storage_path_cache
    end
    storage_path_loaded = true
    local home = get_data_dir() .. "/rakuyomi"
    local storage = home .. "/downloads"
    local content = require("util").readFromFile(home .. "/settings.json", "rb")
    if content then
        local ok_json, rapidjson = pcall(require, "rapidjson")
        local ok_decode, settings = false, nil
        if ok_json then
            ok_decode, settings = pcall(rapidjson.decode, content)
        end
        if ok_decode and type(settings) == "table"
                and type(settings.storage_path) == "string"
                and settings.storage_path ~= "" then
            storage = absolute_data_path(settings.storage_path)
        end
    end
    storage_path_cache = normalize_path(storage)
    return storage_path_cache
end

function M.isTmpfsChapterFile(path)
    if type(path) ~= "string" then return false end
    local storage = get_storage_path()
    return path_is_inside(path, (storage:match("^(.*)/[^/]+$") or storage) .. "/tmpfs")
end

local function read_zip_comment(path)
    local file = io.open(path, "rb")
    if not file then return nil end

    local size = file:seek("end")
    if not size or size <= 0 then
        file:close()
        return nil
    end

    local read_size = math.min(size, 65535 + 22)
    file:seek("set", size - read_size)
    local data = file:read(read_size)
    file:close()
    if not data then return nil end

    for pos = read_size - 21, 1, -1 do
        if data:sub(pos, pos + 3) == "PK\005\006" then
            local len_low = data:byte(pos + 20) or 0
            local len_high = data:byte(pos + 21) or 0
            local comment_len = len_low + len_high * 256
            if pos + 21 + comment_len == read_size and comment_len > 0 then
                return data:sub(pos + 22, pos + 21 + comment_len)
            end
        end
    end
end

local function has_origin_metadata(path)
    if origin_metadata_cache[path] ~= nil then
        return origin_metadata_cache[path]
    end

    local comment = read_zip_comment(path)
    local has_origin = type(comment) == "string"
        and comment:find('"chapter_id"', 1, true) ~= nil
        and comment:find('"manga_id"', 1, true) ~= nil
        and comment:find('"source_id"', 1, true) ~= nil
    origin_metadata_cache[path] = has_origin
    return has_origin
end

function M.getSeriesCoverPath(path)
    if type(path) ~= "string" or path:lower():sub(-4) ~= ".cbz" then return nil end
    if series_cover_paths[path] == nil then
        series_cover_paths[path] = false
        local comment = read_zip_comment(path)
        if not comment then return nil end
        local ok, origin = pcall(require("rapidjson").decode, comment)
        if not ok or type(origin) ~= "table" or type(origin.chapter_id) ~= "string"
                or type(origin.source_id) ~= "string" or type(origin.manga_id) ~= "string" then
            return nil
        end
        local sha = require("ffi/sha2")
        local name = sha.bin_to_base64(sha.hex_to_bin(sha.sha256(origin.source_id .. origin.manga_id)))
            :gsub("%+", "-"):gsub("/", "_"):gsub("=+$", "")
        series_cover_paths[path] = get_storage_path() .. "/.posters/" .. name .. ".jpg"
    end
    local cover = series_cover_paths[path]
    if cover and require("libs/libkoreader-lfs").attributes(cover, "mode") == "file" then
        return cover
    end
end

-- Rakuyomi's storage_path is user-configurable and may be pointed at the
-- KOReader library folder itself. In that case every book in the library sits
-- "inside storage", so path containment proves nothing -- fall back to the
-- authoritative zip-comment origin check instead.
local function storage_shadows_library()
    local ok, paths = pcall(require, "common/paths")
    local home = ok and type(paths) == "table" and type(paths.getHomeDir) == "function"
        and paths.getHomeDir() or nil
    home = normalize_path(home)
    if not home then return false end
    return home == get_storage_path()
end

function M.isChapterFile(path)
    if type(path) ~= "string" then
        return false
    end

    local storage = get_storage_path()
    local in_storage = not storage_shadows_library()
        and path_is_inside(path, storage) == true
    local has_origin = in_storage or has_origin_metadata(path)
    return has_origin
end

function M.getMetadataProvider(path)
    if type(path) ~= "string" or path:lower():sub(-4) ~= ".cbz"
            or not M.isChapterFile(path) then
        return nil
    end

    local ok_cbz, CbzDocument = pcall(require, "extensions/CbzDocument")
    if ok_cbz and type(CbzDocument) == "table" then
        return CbzDocument
    end
end

function M.getMetadata(path)
    local CbzDocument = M.getMetadataProvider(path)
    if not CbzDocument then return nil end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local size = ok_lfs and lfs.attributes(path, "size") or 0
    local modification = ok_lfs and lfs.attributes(path, "modification") or 0
    local cache_key = tostring(size or 0) .. ":" .. tostring(modification or 0)
    local cached = metadata_cache[path]
    if cached and cached.key == cache_key then
        return cached.props or nil
    end

    local reader = setmetatable({ file = path }, { __index = CbzDocument })
    local read_json = reader._getComicBookInfoJSONFromBinary
    local parse_json = reader._parseMetadata
    if type(read_json) ~= "function" or type(parse_json) ~= "function" then
        metadata_cache[path] = { key = cache_key, props = false }
        return nil
    end

    local ok_json, json = pcall(read_json, reader)
    local ok_parse, raw = false, nil
    if ok_json and json then
        ok_parse, raw = pcall(parse_json, reader, json)
    end
    if not ok_parse or type(raw) ~= "table" then
        metadata_cache[path] = { key = cache_key, props = false }
        return nil
    end

    local props = {
        title = raw.title,
        authors = raw.authors or raw.author,
        series = raw.series,
        series_index = tonumber(raw.series_index),
        language = raw.language,
        keywords = raw.keywords,
        description = raw.description or raw.notes,
    }
    if not next(props) then props = false end
    metadata_cache[path] = { key = cache_key, props = props }
    return props or nil
end

local function recent_series(config)
    if not config then return {} end
    config.rakuyomi = config.rakuyomi or {}
    if not config.rakuyomi.recent_series then
        local previous = config.rakuyomi.last_read_series
        config.rakuyomi.recent_series = previous and { previous } or {}
        config.rakuyomi.last_read_series = nil
    end
    return config.rakuyomi.recent_series
end

local function remember_recent_series(manga, chapter, file, timestamp)
    if type(manga) ~= "table" or type(manga.source) ~= "table"
            or type(manga.source.id) ~= "string" or type(manga.id) ~= "string"
            or type(file) ~= "string" then return end
    local config = get_zen_config()
    if not config then return end
    local series = recent_series(config)
    for index, previous in ipairs(series) do
        if previous.manga.id == manga.id and previous.manga.source.id == manga.source.id then
            if not manga.title or manga.title == "" then manga = previous.manga end
            table.remove(series, index)
            break
        end
    end
    local recent = {
        manga = manga,
        chapter = {
            id = chapter.id, title = chapter.title,
            chapter_num = chapter.chapter_num, volume_num = chapter.volume_num,
        },
        file = file,
        time = timestamp,
        cover_path = M.getSeriesCoverPath(file),
    }
    table.insert(series, 1, recent)
    return recent
end

function M.getRecentSeries(history)
    if not M.is_available() then return {} end
    local config = get_zen_config()
    local series = recent_series(config)
    local by_source, by_file = {}, {}
    for _i, recent in ipairs(series) do
        local source = recent.manga.source.id
        by_source[source] = by_source[source] or {}
        by_source[source][recent.manga.id] = recent
        by_file[recent.file] = recent
    end
    local changed = false
    for _i, entry in ipairs(history or {}) do
        local file = entry.file
        local existing = by_file[file]
        if existing then
            local timestamp = math.max(existing.time, entry.time or 0)
            if timestamp ~= existing.time then changed = true; existing.time = timestamp end
        elseif type(file) == "string" and file:lower():sub(-4) == ".cbz" and M.isChapterFile(file) then
            local origin = require("RakuyomiShared"):getOrigin(file)
            local source = origin and origin.manga_id.source_id
            local previous = source and by_source[source] and by_source[source][origin.manga_id.manga_id]
            local metadata = origin and (not previous or (entry.time or 0) > previous.time)
                and M.getMetadata(file)
            if metadata then
                local recent = remember_recent_series(previous and previous.manga or {
                    id = origin.manga_id.manga_id,
                    source = { id = origin.manga_id.source_id },
                    title = metadata.series or metadata.title,
                    viewer = "DefaultViewer", state_viewer = false,
                }, {
                    id = origin.chapter_id, title = metadata.title,
                    chapter_num = metadata.series_index,
                }, file, entry.time or 0)
                if recent then
                    by_source[source] = by_source[source] or {}
                    by_source[source][recent.manga.id] = recent
                    by_file[recent.file] = recent
                    changed = true
                end
            end
        end
    end
    table.sort(series, function(first, second)
        if first.time ~= second.time then return first.time > second.time end
        return first.file < second.file
    end)
    if changed then require("config/manager").save(config) end
    return series
end

function M.getRecentBook(recent, metadata_only)
    local chapter_label = require("utils/getChapterDisplayName")(recent.chapter)
    local book = {
        path = recent.file, title = recent.manga.title,
        authors = "", chapter_label = chapter_label,
        series_index = recent.chapter.chapter_num,
        status = "reading", percent = 0,
    }
    local DocSettings = require("docsettings")
    if DocSettings:hasSidecarFile(recent.file) then
        local doc = DocSettings:open(recent.file)
        book.percent_finished = doc:readSetting("percent_finished")
        book.percent = book.percent_finished or 0
        local stats = doc:readSetting("stats")
        book.pages = stats and stats.pages
        book.current_page = book.pages and math.floor(book.pages * book.percent + 0.5)
    end
    local cover_path = recent.manga.manga_cover
    if type(cover_path) == "string" and cover_path:sub(1, 7) == "file://" then
        cover_path = cover_path:sub(8):gsub("%%(%x%x)", function(hex) return string.char(tonumber(hex, 16)) end)
    else
        cover_path = recent.cover_path or M.getSeriesCoverPath(recent.file)
    end
    if cover_path and require("libs/libkoreader-lfs").attributes(cover_path, "mode") ~= "file" then
        cover_path = nil
    end
    book.has_real_cover = cover_path ~= nil
    book.is_cover_pending = metadata_only and book.has_real_cover or nil
    if cover_path and not metadata_only then
        local cover = require("common/cover_utils").loadExplicitCover(cover_path)
        if cover then
            book.cover_bb, book.cover_w, book.cover_h = cover.data, cover.w, cover.h
        else
            book.has_real_cover = false
        end
    end
    return book
end

function M.resumeRecentSeries(file)
    local config = get_zen_config()
    local recent
    for _i, entry in ipairs(recent_series(config)) do
        if entry.file == file then recent = entry; break end
    end
    if not recent or not M.is_available() then return false end
    local Backend = require("Backend")
    Backend.getBackend()
    if not Backend.getInitialized() then
        (live_plugin() or loaded_plugin()):showErrorDialog()
        return true
    end
    M.installResumePatch()
    local LibraryView = require("LibraryView")
    -- Home has no library widget to close after the chapter opens.
    local library = setmetatable({ hide_top_close = true, onClose = function() end }, { __index = LibraryView })
    if not G_reader_settings:isTrue("file_ask_to_open") then
        require("ui/trapper"):wrap(function()
            local settings = Backend.getSettings()
            if settings.type == "ERROR" then
                require("ErrorDialog"):show(settings.message)
                return
            end
            local listing = require("ChapterListing"):new{
                manga = recent.manga, chapter_sorting_mode = settings.body.chapter_sorting_mode,
                preload_count = settings.body.preload_chapters, covers_fullscreen = true,
            }
            listing.on_return_callback = function()
                library:fetchAndShow(nil, nil, { hideTopClose = true })
            end
            local chapter = require("utils/findLastRead")(listing.chapters)
            if chapter then
                listing:openChapterOnReader(chapter)
            else
                require("ErrorDialog"):show(require("gettext+")("No chapters found for this manga."))
            end
        end)
        return true
    end
    library:_handleContinueReading(recent.manga)
    return true
end

function M.onEndOfBook(ui)
    local path = ui and ui.document and ui.document.file
    if not M.getMetadataProvider(path) then return false end
    local ok, shared = pcall(require, "RakuyomiShared")
    if not ok or type(shared) ~= "table" or type(shared.getOrigin) ~= "function" then
        return false
    end
    local origin = shared:getOrigin(path)
    if not origin then return false end
    if ui._zen_rakuyomi_next_pending then return true end
    ui._zen_rakuyomi_next_pending = true
    if G_reader_settings:isTrue("end_document_auto_mark") then ui.status:markBook(true) end
    ui.doc_settings:flush()
    local manager = require("ui/uimanager")
    manager:nextTick(function()
        ui._zen_rakuyomi_next_pending = nil
        if not ui.document or ui.document.file ~= path then return end
        require("ui/trapper"):wrap(function()
            local Backend = require("Backend")
            local ErrorDialog = require("ErrorDialog")
            Backend.getBackend()
            if not Backend.getInitialized() then
                ErrorDialog:show(Backend.getLogs())
                return
            end
            local manga = {
                id = origin.manga_id.manga_id,
                source = { id = origin.manga_id.source_id, name = "", version = 0, languages = {} },
                title = "", in_library = false, viewer = "DefaultViewer", state_viewer = false,
            }
            local settings = Backend.getSettings()
            if settings.type == "ERROR" then
                ErrorDialog:show(settings.message)
                return
            end
            local listing = require("ChapterListing"):new{
                manga = manga, chapter_sorting_mode = settings.body.chapter_sorting_mode,
                preload_count = settings.body.preload_chapters, covers_fullscreen = true,
            }
            listing.on_return_callback = function()
                require("LibraryView"):fetchAndShow(nil, nil, {
                    hideTopClose = true, focus_manga_id = manga.id, focus_manga_source_id = manga.source.id,
                })
            end
            local current
            for _i, chapter in ipairs(listing.chapters) do
                if chapter.id == origin.chapter_id then current = chapter; break end
            end
            if current then
                local marked = Backend.markChapterAsRead(current.source_id, current.manga_id, current.id)
                if marked.type == "ERROR" then
                    ErrorDialog:show(marked.message)
                    return
                end
                current.read = true
            end
            local next_chapter = current and require("chapters/findNextChapter")(listing.chapters, current)
            if next_chapter then
                listing:openChapterOnReader(next_chapter)
            else
                manager:show(listing)
            end
        end)
    end)
    return true
end

function M.installMetadataIntegration()
    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    local ok_registry, DocumentRegistry = pcall(require, "document/documentregistry")
    if not (ok_bim and ok_registry)
            or type(BookInfoManager) ~= "table"
            or type(BookInfoManager.extractBookInfo) ~= "function"
            or type(DocumentRegistry) ~= "table"
            or type(DocumentRegistry.getProvider) ~= "function" then
        return false
    end
    if BookInfoManager._zen_rakuyomi_metadata_patched then
        return true
    end

    local BookInfo = require("apps/filemanager/filemanagerbookinfo")
    local DocSettings = require("docsettings")
    local orig_getCoverImage = BookInfo.getCoverImage
    function BookInfo:getCoverImage(document, file, force_orig)
        local filepath = file or document and document.file
        local cover_path = not force_orig and M.getSeriesCoverPath(filepath)
        if cover_path and not DocSettings:findCustomCoverFile(filepath) then
            local cover = require("common/cover_utils").loadExplicitCover(cover_path)
            if cover then return cover.data end
        end
        return orig_getCoverImage(self, document, file, force_orig)
    end

    local orig_extractBookInfo = BookInfoManager.extractBookInfo
    function BookInfoManager:extractBookInfo(filepath, ...)
        local provider = M.getMetadataProvider(filepath)
        if not provider then
            return orig_extractBookInfo(self, filepath, ...)
        end

        local orig_getProvider = DocumentRegistry.getProvider
        DocumentRegistry.getProvider = function(registry, file, ...)
            if file == filepath then
                return provider
            end
            return orig_getProvider(registry, file, ...)
        end
        local ok_extract, result = pcall(orig_extractBookInfo, self, filepath, ...)
        DocumentRegistry.getProvider = orig_getProvider
        if not ok_extract then
            error(result, 0)
        end
        return result
    end

    local orig_getBookInfo = BookInfoManager.getBookInfo
    if type(orig_getBookInfo) == "function"
            and type(BookInfoManager.deleteBookInfo) == "function" then
        local checked_cache_rows = {}
        function BookInfoManager:getBookInfo(filepath, get_cover, ...)
            local cover_path = M.getSeriesCoverPath(filepath)
            if cover_path and DocSettings:findCustomCoverFile(filepath) then cover_path = nil end
            local bookinfo = orig_getBookInfo(self, filepath, not cover_path and get_cover, ...)
            if bookinfo and not bookinfo.title and not checked_cache_rows[filepath]
                    and M.getMetadataProvider(filepath) then
                checked_cache_rows[filepath] = true
                self:deleteBookInfo(filepath)
                return nil
            end
            if bookinfo and cover_path and not bookinfo.ignore_cover then
                if get_cover then
                    local cover = require("common/cover_utils").loadExplicitCover(
                        cover_path, bookinfo.cover_w, bookinfo.cover_h)
                    if not cover then return orig_getBookInfo(self, filepath, get_cover, ...) end
                    bookinfo.cover_bb = cover.data
                    bookinfo.cover_w, bookinfo.cover_h = cover.w, cover.h
                    bookinfo.cover_sizetag = cover.w .. "x" .. cover.h
                end
                bookinfo.has_cover, bookinfo.cover_fetched = "Y", "Y"
            end
            return bookinfo
        end
    end

    BookInfoManager._zen_rakuyomi_metadata_patched = true
    return true
end

local function append_file_opener_candidate(candidates, label, object)
    if type(object) == "table" and type(object.openChapterListingFromFile) == "function" then
        candidates[#candidates + 1] = {
            label = label,
            object = object,
        }
    end
end

local function append_file_opener_candidates(candidates, label, object)
    append_file_opener_candidate(candidates, label .. " method", object)
end

function M.openLibraryView(options)
    local fm = FileManager and FileManager.instance
    local rakuyomi = fm and fm.rakuyomi
    if rakuyomi then
        options = options or { hideTopClose = true }
        rakuyomi:openLibraryView(options)
        if options.forceLibraryView == true then
            close_top_chapter_listing()
            UIManager:nextTick(close_top_chapter_listing)
        end
        return true
    end

    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{
        text = _("Rakuyomi plugin is not installed."),
    })
    return false
end

function M.openChapterListingFromFile(filepath, hide_top_close)
    if type(filepath) ~= "string" or filepath == "" then
        logger.warn("rakuyomi return: invalid chapter-list file")
        return false
    end

    local candidates = {}
    append_file_opener_candidates(candidates, "global RakuyomiShared", rawget(_G, "RakuyomiShared"))
    append_file_opener_candidates(candidates, "package.loaded RakuyomiShared", package.loaded.RakuyomiShared)

    local ok_shared, RakuyomiShared = pcall(require, "RakuyomiShared")
    if ok_shared then
        append_file_opener_candidates(candidates, "require RakuyomiShared", RakuyomiShared)
    end

    local fm = FileManager and FileManager.instance
    local rakuyomi = fm and fm.rakuyomi
    append_file_opener_candidates(candidates, "FileManager.rakuyomi", rakuyomi)
    append_file_opener_candidates(candidates, "FileManager.rakuyomi.shared", rakuyomi and rakuyomi.shared)
    append_file_opener_candidates(
        candidates,
        "FileManager.rakuyomi.RakuyomiShared",
        rakuyomi and rakuyomi.RakuyomiShared)

    for _i, candidate in ipairs(candidates) do
        local ok_open, opened = pcall(
            candidate.object.openChapterListingFromFile,
            candidate.object,
            filepath,
            hide_top_close)
        if ok_open and opened == true then
            return true
        elseif not ok_open then
            logger.warn(
                "rakuyomi return: openChapterListingFromFile failed:",
                candidate.label,
                tostring(opened))
        end
    end

    return false
end

function M.closeLibraryView(widget)
    if not (is_library_view(widget) and type(widget.onClose) == "function") then
        return false
    end
    if widget._zen_rakuyomi_onclose_running then
        return false
    end
    widget._zen_rakuyomi_onclose_running = true
    local ok, err = pcall(widget.onClose, widget)
    widget._zen_rakuyomi_onclose_running = nil
    if not ok then error(err) end
    return true
end

local function isTransientCover(widget, library_view)
    if not widget or widget == library_view then return true end
    if widget.show_parent == library_view then return true end
    local fm = FileManager.instance
    local fm_menu = fm and fm.menu
    if fm_menu and (widget == fm_menu or widget == fm_menu.menu_container) then
        return true
    end
    return widget.is_popout == true
end

local function closeCoveredLibraryView()
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return end
    local library_view, library_index
    for i = #stack, 1, -1 do
        local widget = stack[i] and stack[i].widget
        if is_library_view(widget) then
            library_view = widget
            library_index = i
            break
        end
    end
    if not library_view or library_index == #stack then return end
    local top_widget = stack[#stack] and stack[#stack].widget
    if isTransientCover(top_widget, library_view) then
        return
    end
    if type(is_real_exit_target) == "function" and is_real_exit_target(top_widget) then
        M.closeLibraryView(library_view)
    end
end

local function isTopWidget(widget)
    local stack = UIManager._window_stack
    return type(stack) == "table" and stack[#stack] and stack[#stack].widget == widget
end

local function scheduleStackCleanup()
    if UIManager._zen_rakuyomi_stack_cleanup_pending then return end
    UIManager._zen_rakuyomi_stack_cleanup_pending = true
    UIManager:nextTick(function()
        UIManager._zen_rakuyomi_stack_cleanup_pending = nil
        closeCoveredLibraryView()
    end)
end

function M.installCloseGuard(exit_target_predicate)
    if type(exit_target_predicate) == "function" then
        is_real_exit_target = exit_target_predicate
    end
    if UIManager._zen_rakuyomi_close_guard_patched then return end
    UIManager._zen_rakuyomi_close_guard_patched = true
    local orig_show = UIManager.show
    UIManager.show = function(self, ...)
        local result = orig_show(self, ...)
        scheduleStackCleanup()
        return result
    end
    local orig_close = UIManager.close
    UIManager.close = function(self, widget, ...)
        if is_library_view(widget)
                and not widget._zen_rakuyomi_onclose_running
                and type(widget.onClose) == "function" then
            if not isTopWidget(widget) then
                local result = orig_close(self, widget, ...)
                scheduleStackCleanup()
                return result
            end
            return M.closeLibraryView(widget)
        end
        local result = orig_close(self, widget, ...)
        scheduleStackCleanup()
        return result
    end
end

function M.onStandaloneNavbarInjected(widget, exit_target_predicate)
    if not is_library_view(widget) then return end
    M.installCloseGuard(exit_target_predicate)
end

-- Capture the Rakuyomi return target for *any* book open, not only the
-- Continue-tab resume. showReader is the single choke point every open flows
-- through, and it broadcasts "ShowingReader" before opening. Detect chapter
-- files here so file lists / history / etc. still restore to Rakuyomi.
function M.installShowReaderCapture()
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI._zen_rakuyomi_showReader_patched then
        return
    end
    ReaderUI._zen_rakuyomi_showReader_patched = true
    local orig_reader_showReader = ReaderUI.showReader
    function ReaderUI:showReader(file, ...)
        if type(file) == "string" then
            local is_chapter = M.isChapterFile(file) == true
            local return_to_chapter_list = return_to_chapter_list_on_exit_enabled()
            if is_chapter then
                _G.__ZEN_UI_LIBRARY_SOURCE_TAB = "manga"
                _G.__ZEN_UI_FORCE_SOURCE_TAB_RESTORE = true
                _G.__ZEN_UI_RAKUYOMI_RETURN_FILE = return_to_chapter_list and file or nil
                if not return_to_chapter_list then
                    close_top_chapter_listing()
                end
            end
        end
        return orig_reader_showReader(self, file, ...)
    end

    local orig_onClose = ReaderUI.onClose
    function ReaderUI:onClose(...)
        local file = self.document and self.document.file
        if M.isChapterFile(file) and not return_to_chapter_list_on_exit_enabled()
                and type(UIManager.avoidFlashOnNextRepaint) == "function" then
            UIManager:avoidFlashOnNextRepaint()
        end
        return orig_onClose(self, ...)
    end
end

function M.installReaderReturnPatch()
    local ok, MangaReader = pcall(require, "MangaReader")
    if not ok or type(MangaReader) ~= "table"
            or type(MangaReader.onReturn) ~= "function"
            or MangaReader._zen_rakuyomi_return_patched then
        return
    end
    MangaReader._zen_rakuyomi_return_patched = true
    local orig_onReturn = MangaReader.onReturn
    function MangaReader:onReturn(...)
        local ReaderUI = require("apps/reader/readerui")
        local reader = ReaderUI.instance
        local file = reader and reader.document and reader.document.file
        if self.is_showing and M.isChapterFile(file)
                and return_to_chapter_list_on_exit_enabled()
                and not self._zen_rakuyomi_return_pending then
            local orig_callback = self.on_return_callback
            self._zen_rakuyomi_return_pending = true
            self.on_return_callback = function(...)
                self._zen_rakuyomi_return_pending = nil
                if rawget(_G, "__ZEN_UI_RAKUYOMI_CHAPTER_LIST_RESTORED") then
                    _G.__ZEN_UI_RAKUYOMI_CHAPTER_LIST_RESTORED = nil
                    return
                end
                if not M.openChapterListingFromFile(file, true) and orig_callback then
                    return orig_callback(...)
                end
            end
        end
        return orig_onReturn(self, ...)
    end
end

function M.installResumePatch()
    if M._resume_patched then return end
    local ok, original = pcall(require, "utils/findLastRead")
    if not ok or type(original) ~= "function" then return end
    local function findLastRead(chapters)
        local newest
        for _i, chapter in ipairs(chapters) do
            if chapter.last_read and (not newest or chapter.last_read > newest.last_read) then
                newest = chapter
            end
        end
        return newest or original(chapters)
    end
    local function patch_resume(fn)
        if type(fn) ~= "function" then return end
        for index = 1, 64 do
            local name, value = debug.getupvalue(fn, index)
            if not name then break end
            if name == "findLastRead" and value == original then
                debug.setupvalue(fn, index, findLastRead)
                break
            end
        end
    end
    local ok_listing, ChapterListing = pcall(require, "ChapterListing")
    local ok_library, LibraryView = pcall(require, "LibraryView")
    if ok_listing and type(ChapterListing) == "table" then
        patch_resume(ChapterListing.readContinue)
        local open = ChapterListing.openChapterOnReader
        if type(open) == "function" then
            function ChapterListing:openChapterOnReader(chapter, job, on_opened)
                return open(self, chapter, job, function(...)
                    chapter.last_read = os.time() -- Native opening saves this only in the backend.
                    local function record_recent()
                        local ReaderUI = package.loaded["apps/reader/readerui"]
                        local reader = ReaderUI and ReaderUI.instance
                        local file = reader and reader.document and reader.document.file or chapter.file
                        if remember_recent_series(self.manga, chapter, file, chapter.last_read) then
                            require("config/manager").save(get_zen_config())
                            local home = require("common/shared_state").get(
                                zen_plugin or rawget(_G, "__ZEN_UI_PLUGIN"), "home")
                            if home then home.invalidateBookCache(file, true) end
                        end
                    end
                    local MangaReader = package.loaded["MangaReader"]
                    if MangaReader and MangaReader.is_switching_document then
                        require("ui/uimanager"):nextTick(record_recent)
                    else
                        record_recent()
                    end
                    if on_opened then return on_opened(...) end
                end)
            end
        end
    end
    if ok_library and type(LibraryView) == "table" then
        patch_resume(LibraryView._handleContinueReading)
    end
    package.loaded["utils/findLastRead"] = findLastRead
    M._resume_patched = true
end

local function get_series_manga(source_id, manga_id)
    local response = require("Backend").getMangasInLibrary()
    if response.type == "ERROR" then return nil end
    for _i, manga in ipairs(response.body) do
        if manga.id == manga_id and manga.source.id == source_id then return manga end
    end
end

function M.installReadingDirectionPatch()
    local ok, MangaReader = pcall(require, "MangaReader")
    if not ok or type(MangaReader.show) ~= "function" or type(MangaReader.applyViewMode) ~= "function"
            or type(MangaReader.initializeFromReaderUI) ~= "function" or M._direction_patched then return end
    local Backend = require("Backend")
    local viewers = {}
    for id, name in pairs(Backend.MangaViewerName) do viewers[name] = id end
    local show = MangaReader.show
    function MangaReader:show(options)
        if options.viewer == "DefaultViewer" and not options.state_viewer then
            local chapter = options.chapter
            local manga = get_series_manga(chapter.source_id, chapter.manga_id)
            if manga then options.viewer, options.state_viewer = manga.viewer, manga.state_viewer end
        end
        return show(self, options)
    end

    local apply_view = MangaReader.applyViewMode
    function MangaReader:applyViewMode(ui)
        local result = apply_view(self, ui)
        if self.viewer == 0 then -- Default follows the global order, not a chapter's stale sidecar.
            ui.view:onToggleReadingOrder(G_reader_settings:isTrue("inverse_reading_order")
                and not G_reader_settings:isTrue("rakuyomi_never_rtl"))
        end
        return result
    end

    local initialize = MangaReader.initializeFromReaderUI
    function MangaReader:initializeFromReaderUI(ui)
        local result = initialize(self, ui)
        local file = ui.document and ui.document.file
        if not self.is_showing and M.getMetadataProvider(file) then
            local origin = require("RakuyomiShared"):getOrigin(file)
            if origin then
                ui:registerPostInitCallback(function()
                    require("ui/trapper"):wrap(function()
                        Backend.getBackend()
                        if not Backend.getInitialized() then return end
                        local manga = get_series_manga(origin.manga_id.source_id, origin.manga_id.manga_id)
                        local global_viewer = G_reader_settings:readSetting("rakuyomi_global_viewer")
                        local viewer = viewers[global_viewer] or viewers[manga and manga.viewer] or 0
                        if not ui.document or ui.document.file ~= file then return end
                        if viewers[global_viewer] or manga and manga.state_viewer
                                or G_reader_settings:readSetting("rakuyomi_auto_viewer_mode") ~= false then
                            MangaReader.applyViewMode({ viewer = viewer }, ui)
                        end
                    end)
                end)
            end
        end
        return result
    end
    M._direction_patched = true
end

function M.installLoadingDialogPatch()
    local ok, LoadingDialog = pcall(require, "LoadingDialog")
    if not ok or type(LoadingDialog) ~= "table" or M._loading_dialog_patched then return end
    local ConfirmBox = require("ui/widget/confirmbox")
    local LoadingConfirmBox = ConfirmBox:extend{ dismissable = false }
    -- Scope the default to Rakuyomi, including dialogs rebuilt by progress updates.
    for _i, method in ipairs({ "showAndRun", "showAndRunWithProgress", "simple" }) do
        local fn = LoadingDialog[method]
        if type(fn) == "function" then
            for index = 1, 64 do
                local name, value = debug.getupvalue(fn, index)
                if not name then break end
                if name == "ConfirmBox" and value == ConfirmBox then
                    debug.setupvalue(fn, index, LoadingConfirmBox)
                    break
                end
            end
        end
    end
    M._loading_dialog_patched = true
end

function M.installChapterOpenPatch()
    local ok, ChapterListing = pcall(require, "ChapterListing")
    if not ok or type(ChapterListing.openChapterOnReader) ~= "function" or M._chapter_open_patched then return end
    local MangaReader = require("MangaReader")
    local ReaderUI = require("apps/reader/readerui")
    local end_of_book = MangaReader.onEndOfBook
    if type(end_of_book) == "function" then
        function MangaReader:onEndOfBook(...)
            local ui = ReaderUI.instance
            if self.is_showing and M.isTmpfsChapterFile(ui and ui.document and ui.document.file)
                    and M.onEndOfBook(ui) then return true end
            return end_of_book(self, ...)
        end
    end
    local open = ChapterListing.openChapterOnReader
    function ChapterListing:openChapterOnReader(chapter, job, on_opened)
        local reader = ReaderUI.instance
        local file = reader and reader.document and reader.document.file
        if not M.isTmpfsChapterFile(file) then return open(self, chapter, job, on_opened) end
        local origin = require("RakuyomiShared"):getOrigin(file)
        local current = origin and {
            id = origin.chapter_id, source_id = origin.manga_id.source_id, manga_id = origin.manga_id.manga_id,
        } or MangaReader.is_showing and MangaReader.chapter
        if not current or current.id == chapter.id and current.source_id == chapter.source_id
                and current.manga_id == chapter.manga_id then return open(self, chapter, job, on_opened) end
        if reader._zen_rakuyomi_open_pending then return end
        reader._zen_rakuyomi_open_pending = true
        local manager = require("ui/uimanager")
        manager:nextTick(function()
            if ReaderUI.instance ~= reader or not reader.document or reader.document.file ~= file then
                reader._zen_rakuyomi_open_pending = nil
                return
            end
            M._chapter_handoff_pending = true
            local notice = require("LoadingDialog"):simple(require("gettext+")("Loading next chapter..."))
            manager:forceRePaint()
            MangaReader:closeReaderUi(function()
                M._chapter_handoff_pending = nil
                reader._zen_rakuyomi_open_pending = nil
                -- closeReaderUi cleans the singleton after its callback; open on the following tick.
                manager:nextTick(function()
                    require("ui/trapper"):wrap(function()
                        local revoked = require("Backend").revokeChapter(current.source_id, current.manga_id, current.id, true)
                        if revoked.type == "ERROR" then
                            manager:close(notice)
                            require("ErrorDialog"):show(revoked.message)
                            return
                        end
                        for _i, item in ipairs(self.chapters) do
                            if item.id == current.id and item.source_id == current.source_id
                                    and item.manga_id == current.manga_id then
                                item.file, item.downloaded, item.on_tmpfs = nil, false, false
                                self.preload_jobs[item.id] = nil
                            end
                        end
                        self:updateItems()
                        manager:close(notice)
                        open(self, chapter, job, on_opened)
                    end)
                end)
            end)
        end)
    end
    M._chapter_open_patched = true
end

function M.refreshAfterResize(widget)
    if is_library_view(widget) and type(widget.updateItems) == "function"
            and widget.item_group and widget.content_group then
        widget:updateItems(widget.itemnumber)
        return true
    end
    return false
end

function M.configureScrollBarFooter(widget)
    if not M.isScrollBarMenu(widget) or not widget.page_return_arrow then
        return false
    end
    widget.onReturn = false
    widget.page_return_arrow:hide()
    widget.page_return_arrow.show = function() end
    widget.page_return_arrow.showHide = function() end
    widget.page_return_arrow.callback = nil
    widget.page_return_arrow.hold_callback = nil
    widget.page_return_arrow.dimen = Geom:new{ w = 0, h = 0 }
    widget.page_return_arrow.getSize = function()
        return widget.page_return_arrow.dimen
    end
    return true
end

function M.apply()
    if rawget(_G, "__ZEN_UI_RAKUYOMI") == M then
        return
    end

    FileManager = require("apps/filemanager/filemanager")
    Geom = require("ui/geometry")
    UIManager = require("ui/uimanager")
    logger = require("common/zen_logger").new("rakuyomi")
    _ = require("gettext")

    zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    _G.__ZEN_UI_RAKUYOMI = M
    M.installShowReaderCapture()
    M.installReaderReturnPatch()
    M.installResumePatch()
    M.installReadingDirectionPatch()
    M.installLoadingDialogPatch()
    M.installChapterOpenPatch()
end

return M
