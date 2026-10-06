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
        function BookInfoManager:getBookInfo(filepath, ...)
            local bookinfo = orig_getBookInfo(self, filepath, ...)
            if bookinfo and not bookinfo.title and not checked_cache_rows[filepath]
                    and M.getMetadataProvider(filepath) then
                checked_cache_rows[filepath] = true
                self:deleteBookInfo(filepath)
                return nil
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
end

return M
