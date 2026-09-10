local M = {}
local PluginScan = require("modules/menu/app_launcher/plugin_scan")

local PLUGIN_KEYS = { "kindle", "kindle_plugin" }
local OPEN_METHOD = "onShowKindleLibrary"
local THUMBNAILS_DIR = "/mnt/us/system/thumbnails"
local thumbnail_index

local function dispatcher_has_action()
    local ok, Dispatcher = pcall(require, "dispatcher")
    if not ok or type(Dispatcher.getDisplayList) ~= "function" then return false end
    local listed, items = pcall(Dispatcher.getDisplayList, { kindle_library = true })
    return listed and type(items) == "table" and #items > 0, Dispatcher
end

local function loaded_manager()
    local extension = package.loaded["lua/filechooser_ext"]
    return type(extension) == "table" and extension.kindle_library or nil
end

function M.isAvailable()
    if dispatcher_has_action() then return true end
    if type(PluginScan.exists) == "function" then
        for _i, key in ipairs(PLUGIN_KEYS) do
            if PluginScan.exists(key, OPEN_METHOD) then return true end
        end
    end
    local installed = type(PluginScan.installed) == "function"
        and PluginScan.installed() or nil
    return type(installed) == "table"
        and (installed.kindle == true or installed.kindle_plugin == true)
end

function M.open()
    local library = loaded_manager()
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local filemanager = FileManager and FileManager.instance
    if type(library) == "table" and type(library.show) == "function" and filemanager then
        local ok = pcall(library.show, library, filemanager, true)
        if ok then return true end
    end

    local has_action, Dispatcher = dispatcher_has_action()
    if has_action and type(Dispatcher.execute) == "function" then
        local ok = pcall(Dispatcher.execute, Dispatcher, { kindle_library = true })
        if ok then return true end
    end
    for _i, key in ipairs(PLUGIN_KEYS) do
        local launch = PluginScan.resolve(key, OPEN_METHOD)
        if launch then
            local ok = pcall(launch)
            if ok then return true end
        end
    end
    return false
end

function M.isLibraryView(widget)
    return widget and widget.name == "kindle_library"
end

local function be16(data, offset)
    local high, low = data:byte(offset, offset + 1)
    return high and low and high * 256 + low or nil
end

local function be32(data, offset)
    local a, b, c, d = data:byte(offset, offset + 3)
    return a and d and ((a * 256 + b) * 256 + c) * 256 + d or nil
end

local function image_size_from_data(data)
    if type(data) ~= "string" then return nil end
    if data:sub(1, 8) == "\137PNG\r\n\26\n" then
        return be32(data, 17), be32(data, 21)
    end
    if data:sub(1, 2) ~= "\255\216" then return nil end

    local offset = 3
    while offset + 8 <= #data do
        if data:byte(offset) ~= 0xFF then
            offset = offset + 1
        else
            repeat offset = offset + 1 until data:byte(offset) ~= 0xFF
            local marker = data:byte(offset)
            offset = offset + 1
            if marker and marker >= 0xC0 and marker <= 0xCF
                    and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                return be16(data, offset + 5), be16(data, offset + 3)
            end
            local length = be16(data, offset)
            if not length or length < 2 then break end
            offset = offset + length
        end
    end
end
M._imageSizeFromData = image_size_from_data

local function image_size(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local data = file:read(65536)
    file:close()
    return image_size_from_data(data)
end

local function thumbnail_path(cde_key)
    if type(cde_key) ~= "string" or cde_key == "" then return nil end
    for _i, cde_type in ipairs({ "EBOK", "PDOC" }) do
        local path = THUMBNAILS_DIR .. "/thumbnail_" .. cde_key
            .. "_" .. cde_type .. "_portrait.jpg"
        local width, height = image_size(path)
        if width and height then return path, width, height end
    end

    if not thumbnail_index then
        thumbnail_index = {}
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs and lfs then
            pcall(function()
                for name in lfs.dir(THUMBNAILS_DIR) do
                    local key = name:match("^thumbnail_(.+)_[^_]+_portrait%.jpg$")
                    if key and not thumbnail_index[key] then
                        thumbnail_index[key] = THUMBNAILS_DIR .. "/" .. name
                    end
                end
            end)
        end
    end
    local path = thumbnail_index[cde_key]
    if not path then return nil end
    local width, height = image_size(path)
    if width and height then return path, width, height end
end
M._thumbnailPath = thumbnail_path

local function virtual_library()
    local OpenFileExt = package.loaded["lua/open_file_ext"]
    local manager = loaded_manager()
    return type(OpenFileExt) == "table" and OpenFileExt.virtual_library
        or manager and manager.virtual_library or nil
end

local function kindle_book(filepath)
    local library = virtual_library()
    if type(library) ~= "table" or type(library.getBook) ~= "function" then return nil end
    local ok, book = pcall(library.getBook, library, filepath)
    return ok and type(book) == "table" and book or nil
end

function M.getBookPaths()
    local library = virtual_library()
    if type(library) ~= "table" or type(library.getBookEntries) ~= "function" then
        return {}
    end
    local ok, entries = pcall(library.getBookEntries, library, false)
    if not ok or type(entries) ~= "table" then return {} end
    local paths = {}
    for _i, entry in ipairs(entries) do
        local path = type(entry) == "table" and entry.file or nil
        if type(path) == "string" and path ~= "" then paths[#paths + 1] = path end
    end
    return paths
end

function M.installMetadataIntegration()
    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok_bim or type(BookInfoManager) ~= "table"
            or type(BookInfoManager.getBookInfo) ~= "function" then
        return false
    end
    if BookInfoManager._zen_kindle_metadata_patched then return true end

    local original = BookInfoManager.getBookInfo
    function BookInfoManager:getBookInfo(filepath, get_cover)
        local book = kindle_book(filepath)
        if not book or filepath ~= book.source_path then
            return original(self, filepath, get_cover)
        end

        local util = require("util")
        local directory, filename = util.splitFilePathName(filepath)
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        local attr = ok_lfs and lfs.attributes(filepath) or nil
        local cover_path, cover_w, cover_h = M._thumbnailPath(book.cde_key)
        local info = {
            directory = directory,
            filename = filename,
            filesize = tonumber(book.source_size) or attr and attr.size,
            filemtime = attr and attr.modification,
            in_progress = 0,
            cover_fetched = "Y",
            has_meta = "Y",
            has_cover = cover_path and "Y" or nil,
            cover_sizetag = cover_path and cover_w .. "x" .. cover_h or nil,
            title = book.display_name or book.title,
            authors = type(book.authors) == "table" and table.concat(book.authors, "\n") or nil,
            cover_w = cover_w,
            cover_h = cover_h,
        }
        if get_cover and cover_path then
            local RenderImage = require("ui/renderimage")
            local ok_cover, cover = pcall(RenderImage.renderImageFile,
                RenderImage, cover_path, false)
            if ok_cover and cover then
                info.cover_bb = cover
                info.cover_w = cover:getWidth()
                info.cover_h = cover:getHeight()
                info.cover_sizetag = info.cover_w .. "x" .. info.cover_h
            else
                info.has_cover = nil
            end
        end
        return info
    end

    BookInfoManager._zen_kindle_metadata_patched = true
    return true
end

local function show_display_mode(menu)
    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok_bim then return false end
    local current = BookInfoManager:getSetting("kindle_library_display_mode")
        or BookInfoManager:getSetting("filemanager_display_mode")
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")
    local _ = require("gettext")
    local dialog
    local function button(label, icon, mode)
        local active = current == mode
        return {{
            text = icon .. "  " .. label .. (active and "  \u{2713}" or ""),
            align = "left",
            enabled = not active,
            callback = function()
                UIManager:close(dialog)
                BookInfoManager:saveSetting("kindle_library_display_mode", mode)
                local manager = menu and menu._manager
                if manager and type(manager.show) == "function" then
                    manager:show(manager.ui, false)
                end
            end,
        }}
    end
    dialog = ButtonDialog:new{
        title = _("Display mode"),
        title_align = "center",
        buttons = {
            button(_("Mosaic"), "\u{F00A}", "mosaic_image"),
            button(_("List (detailed)"), "\u{F03A}", "list_image_meta"),
            button(_("List (basic)"), "\u{F0CA}", "list_image_filename"),
        },
    }
    UIManager:show(dialog)
    return true
end

function M.showContextMenu(menu)
    return M.isLibraryView(menu) and show_display_mode(menu) or false
end

function M.showBookContextMenu(menu, item, after_change)
    local manager = menu and menu._manager or loaded_manager()
    local library = manager and manager.virtual_library or virtual_library()
    if type(item) ~= "table" or type(library) ~= "table"
            or type(library.getBook) ~= "function" then return false end

    local ok_book, book = pcall(library.getBook, library,
        item.kindle_book_id or item.file or item.path)
    if not ok_book or type(book) ~= "table" then return false end

    local cache_manager = manager and manager.cache_manager
    local file = book.source_path or item.file or item.path
    if book.open_mode ~= "direct" and cache_manager
            and type(cache_manager.getCachePaths) == "function" then
        file = cache_manager:getCachePaths(book) or file
    end
    if type(file) ~= "string" or file == "" then return false end

    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local filemanager = FileManager and FileManager.instance
    local file_chooser = filemanager and filemanager.file_chooser
    if not file_chooser or type(file_chooser.showFileDialog) ~= "function" then
        return false
    end

    local function refresh_view()
        if type(after_change) == "function" then
            after_change(file)
        elseif manager and type(manager.show) == "function" then
            manager:show(manager.ui, false)
        end
    end

    local icons = require("common/inline_icon_map")
    local _ = require("gettext")
    local clear_cache = {{
        text = icons.delete .. "  " .. _("Clear cache"),
        align = "left",
        enabled = book.open_mode ~= "direct" and cache_manager ~= nil,
        callback = function()
            require("ui/uimanager"):close(file_chooser.file_dialog)
            local ok, err = cache_manager:clearBookCache(book)
            if not ok then
                local InfoMessage = require("ui/widget/infomessage")
                require("ui/uimanager"):show(InfoMessage:new{
                    text = _("Failed to clear cache:") .. "\n" .. (err or _("Unknown error")),
                })
                return
            end
            refresh_view()
        end,
    }}

    file_chooser:showFileDialog({
        path = file,
        is_file = true,
        _zen_home_context = true,
        _zen_disable_select = true,
        _zen_kindle_book = true,
        _zen_extra_buttons = { clear_cache },
        _zen_refresh = function()
            if type(library.refresh) == "function" then library:refresh(true) end
            refresh_view()
        end,
        _zen_after_status_change = refresh_view,
    })
    return true
end

function M._decorateLibraryView(menu, plugin)
    if not M.isLibraryView(menu) or menu._zen_kindle_decorated then return false end
    menu._zen_kindle_decorated = true
    menu._zen_renderer = true
    menu._do_center_partial_rows = false
    thumbnail_index = nil

    require("common/ui/background").applyToMenu(menu)
    local StandalonePage = require("modules/filebrowser/patches/standalone_page")
    StandalonePage.hide_page_arrow(menu)
    StandalonePage.suppress_page_info_tap(menu)
    local SharedState = require("common/shared_state")
    StandalonePage.apply_status_row(menu, {
        createStatusRow = SharedState.get(plugin, "createStatusRow"),
        repaintTitleBar = SharedState.get(plugin, "repaintTitleBar"),
        label = require("gettext")("Kindle Library"),
    })

    menu.onMenuHold = function(self, item)
        return M.showBookContextMenu(self, item)
    end

    local Device = require("device")
    if Device:isTouchDevice() then
        local Geom = require("ui/geometry")
        local GestureRange = require("ui/gesturerange")
        menu.ges_events = menu.ges_events or {}
        menu.ges_events.ZenKindleBlankHold = {
            GestureRange:new{
                ges = "hold",
                range = Geom:new{
                    x = 0, y = 0,
                    w = Device.screen:getWidth(),
                    h = Device.screen:getHeight(),
                },
            },
        }
        menu.onZenKindleBlankHold = function()
            return M.showContextMenu(menu)
        end
    end
    if type(menu.updateItems) == "function" then menu:updateItems(1, true) end
    return true
end

local function compact_titlebar_enabled(plugin)
    local config = plugin and plugin.config
    local features = config and config.features
    local status = config and config.status_bar
    return type(features) == "table" and features.status_bar == true
        and (type(status) ~= "table" or status.hide_browser_bar ~= false)
end

local function apply_view_integration(plugin)
    local ok_menu, Menu = pcall(require, "ui/widget/menu")
    if not ok_menu or type(Menu) ~= "table" or type(Menu.init) ~= "function" then return end
    if Menu._zen_kindle_library_patched then return end
    Menu._zen_kindle_library_patched = true
    local original = Menu.init
    function Menu:init()
        local is_kindle = M.isLibraryView(self)
        if is_kindle then
            self._zen_renderer = true
            self._do_center_partial_rows = false
        end
        if is_kindle and compact_titlebar_enabled(plugin) then
            local TitleBar = require("ui/widget/titlebar")
            local original_new = TitleBar.new
            TitleBar.new = function(class, spec)
                if type(spec) == "table" then
                    spec.title = " "
                    spec.subtitle = nil
                    spec.subtitle_fullwidth = nil
                    spec.left_icon = nil
                    spec.left_icon_tap_callback = nil
                    spec.left_icon_hold_callback = nil
                    spec.right_icon = nil
                    spec.right_icon_tap_callback = nil
                    spec.right_icon_hold_callback = nil
                    spec.close_callback = nil
                    spec.title_tap_callback = nil
                    spec.title_hold_callback = nil
                    spec.bottom_v_padding = 0
                end
                return original_new(class, spec)
            end
            local ok, err = pcall(original, self)
            TitleBar.new = original_new
            if not ok then error(err, 0) end
        else
            original(self)
        end
        if is_kindle then
            local UIManager = require("ui/uimanager")
            local menu = self
            UIManager:nextTick(function() M._decorateLibraryView(menu, plugin) end)
        end
    end
end

function M.apply(plugin)
    local FileChooser = require("ui/widget/filechooser")
    apply_view_integration(plugin)
    if FileChooser._zen_kindle_virtual_folder_filter_patched then return end
    FileChooser._zen_kindle_virtual_folder_filter_patched = true

    local original = FileChooser.switchItemTable
    function FileChooser:switchItemTable(title, items, ...)
        local config = plugin and plugin.config
        if self.name ~= "filemanager" or type(items) ~= "table"
                or not (config and config.kindle
                    and config.kindle.hide_library_folder == true) then
            return original(self, title, items, ...)
        end

        local filtered
        for _i, item in ipairs(items) do
            if item.is_kindle_library_folder then
                filtered = {}
                break
            end
        end
        if not filtered then return original(self, title, items, ...) end
        for key, value in pairs(items) do
            if type(key) ~= "number" then filtered[key] = value end
        end
        for _i, item in ipairs(items) do
            if not item.is_kindle_library_folder then filtered[#filtered + 1] = item end
        end
        return original(self, title, filtered, ...)
    end
end

return M
