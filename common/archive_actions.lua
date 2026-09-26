local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local FileManager = require("apps/filemanager/filemanager")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local icons = require("common/inline_icon_map")
local library_navigation = require("common/library_navigation")
local Kindle = require("modules/filebrowser/patches/kindle_virtual_library")
local paths = require("common/paths")
local util = require("util")
local _ = require("gettext")

local M = {}

local settings_path = DataStorage:getSettingsDir()
    .. "/move_to_archive_settings.lua"
local original_dirs_key = "library_archive_original_dirs"

local function with_slash(path)
    if type(path) == "string" and path ~= "" and path:sub(-1) ~= "/" then
        return path .. "/"
    end
    return path
end

local function parent_dir(file)
    local dir = util.splitFilePathName(file)
    return with_slash(dir)
end

local function archive_dir()
    return with_slash(paths.getArchiveDir())
end

local function is_in_archive(file, archive)
    local normalized = paths.normPath(file)
    local root = paths.normPath((archive or ""):gsub("/+$", ""))
    return root ~= "" and (normalized == root
        or normalized:sub(1, #root + 1) == root .. "/")
end

local function show_message(text)
    UIManager:show(InfoMessage:new{ text = text, timeout = 3 })
end

local function confirm_action(text, ok_text, callback)
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = ok_text,
        ok_callback = callback,
    })
end

local function update_location(source, destination)
    require("readhistory"):updateItem(source, destination)
    require("readcollection"):updateItem(source, destination)
    DocSettings.updateLocation(source, destination, false)
end

local function invalidate_archive_listing()
    _G.__ZEN_UI_ARCHIVE_LISTING_DIRTY = true
end

local function close_file_dialogs(fm)
    local closed = {}
    local function close(dialog)
        if dialog and not closed[dialog] then
            closed[dialog] = true
            UIManager:close(dialog)
        end
    end
    close(fm.file_chooser and fm.file_chooser.file_dialog)
    close(fm.history and fm.history.file_dialog)
    close(fm.history and fm.history.booklist_menu
        and fm.history.booklist_menu.file_dialog)
    close(fm.collections and fm.collections.file_dialog)
    close(fm.collections and fm.collections.booklist_menu
        and fm.collections.booklist_menu.file_dialog)
    close(fm.filesearcher and fm.filesearcher.file_dialog)
    close(fm.filesearcher and fm.filesearcher.booklist_menu
        and fm.filesearcher.booklist_menu.file_dialog)
end

local function refresh_views(fm)
    if fm.history and fm.history.booklist_menu then
        fm.history:updateItemTable()
    end
    if fm.collections and fm.collections.booklist_menu then
        fm.collections:updateItemTable()
    end
    if fm.filesearcher and fm.filesearcher.booklist_menu then
        fm.filesearcher:updateItemTable()
    end
    UIManager:nextTick(function()
        if fm.file_chooser then
            fm:onRefresh()
            UIManager:setDirty(fm, "ui")
        end
    end)
end

local function choose_archive_folder(fm)
    local settings = LuaSettings:open(settings_path)
    local current = settings:readSetting("archive_dir_path")
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory = true,
        show_files = false,
        path = current or G_reader_settings:readSetting("home_dir"),
        onConfirm = function(path)
            path = with_slash(path)
            settings:saveSetting("archive_dir_path", path)
            settings:flush()
            local mover = fm and fm.movetoarchive
            if mover then
                mover:loadSettings()
                mover.data.archive_dir_path = path
                mover.updated = true
            end
            local refresh_settings = rawget(_G, "__ZEN_UI_REFRESH_SETTINGS")
            if type(refresh_settings) == "function" then
                UIManager:nextTick(refresh_settings)
            end
        end,
    })
end

local function move_book(fm, file, destination_dir, original_dirs)
    local filename = select(2, util.splitFilePathName(file))
    destination_dir = with_slash(destination_dir)
    local destination = destination_dir .. filename
    if lfs.attributes(destination) then
        show_message(_("A book with that name already exists in the destination."))
        return false
    end
    if not FileManager:moveFile(file, destination_dir) then
        show_message(_("Failed to move book."))
        return false
    end

    update_location(file, destination)
    invalidate_archive_listing()
    local settings = LuaSettings:open(settings_path)
    settings:saveSetting(original_dirs_key, original_dirs)
    settings:flush()
    close_file_dialogs(fm)
    refresh_views(fm)
    return true
end

function M.contextRow(fm, file, is_file)
    if not (fm and is_file and type(file) == "string"
            and lfs.attributes(file, "mode") == "file")
            or Kindle.isBookPath(file) then
        return nil
    end

    local archive = archive_dir()
    if not archive or lfs.attributes(archive, "mode") ~= "directory" then
        return {{
            text = icons.archive .. "  " .. _("Archive"),
            align = "left",
            callback = function()
                close_file_dialogs(fm)
                UIManager:show(ConfirmBox:new{
                    text = _("No archive folder is set. Set one now?"),
                    ok_text = _("Set archive folder"),
                    ok_callback = function()
                        choose_archive_folder(fm)
                    end,
                })
            end,
        }}
    end

    local settings = LuaSettings:open(settings_path)
    local original_dirs = settings:readSetting(original_dirs_key) or {}
    local currently_open = fm.document and fm.document.file == file

    if is_in_archive(file, archive) then
        return {{
            text = icons.archive .. "  " .. _("Remove from archive"),
            align = "left",
            enabled = not currently_open,
            callback = function()
                local destination = paths.getHomeDir()
                if not destination
                        or lfs.attributes(destination, "mode") ~= "directory" then
                    show_message(_("Set a HOME folder in File Manager first."))
                    return
                end
                confirm_action(_("Remove this book from archive?"), _("Remove from archive"),
                    function()
                        original_dirs[file] = nil
                        if move_book(fm, file, destination, original_dirs) then
                            show_message(_("Book moved to library."))
                        end
                    end)
            end,
        }}
    end

    return {{
        text = icons.archive .. "  " .. _("Archive"),
        align = "left",
        enabled = not currently_open,
        callback = function()
            confirm_action(_("Archive this book?"), _("Archive"), function()
                local filename = select(2, util.splitFilePathName(file))
                original_dirs[archive .. filename] = parent_dir(file)
                if move_book(fm, file, archive, original_dirs) then
                    show_message(_("Book moved to archive."))
                end
            end)
        end,
    }}
end

function M.canArchive(file)
    local archive = archive_dir()
    return type(file) == "string" and archive ~= nil
        and lfs.attributes(archive, "mode") == "directory"
        and not is_in_archive(file, archive)
        and not Kindle.isBookPath(file)
end

function M.markCompleteAndArchive(reader_status, status_widget)
    local file = reader_status and reader_status.document
        and reader_status.document.file
    local archive = archive_dir()
    if not file or not archive
            or lfs.attributes(archive, "mode") ~= "directory" then
        show_message(_("Set an archive folder with Move to archive first."))
        return false
    end
    if is_in_archive(file, archive) then
        show_message(_("This book is already in the archive."))
        return false
    end

    local source_dir = parent_dir(file)
    local filename = select(2, util.splitFilePathName(file))
    local destination = archive .. filename
    if lfs.attributes(destination) then
        show_message(_("A book with that name already exists in the archive."))
        return false
    end

    local settings = LuaSettings:open(settings_path)
    local original_dirs = settings:readSetting(original_dirs_key) or {}

    confirm_action(_("Archive this book?"), _("Archive"), function()
        reader_status:markBook(true)
        reader_status.ui.doc_settings:flush()
        if status_widget then UIManager:close(status_widget) end
        library_navigation.showFromReader(reader_status.ui, rawget(_G, "__ZEN_UI_PLUGIN"), {
            target_folder = source_dir,
            after_close = function()
                local message = _("Failed to move book to archive.")
                if FileManager:moveFile(file, archive) then
                    update_location(file, destination)
                    invalidate_archive_listing()
                    original_dirs[destination] = source_dir
                    settings:saveSetting(original_dirs_key, original_dirs)
                    settings:flush()
                    message = _("Book moved to archive.")
                end
                UIManager:nextTick(function() show_message(message) end)
            end,
        })
    end)
    return true
end

return M
