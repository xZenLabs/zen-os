local function apply_browser_flat_view_compat()
    local FileChooser = require("ui/widget/filechooser")
    local ffiUtil = require("ffi/util")
    local paths = require("common/paths")
    local ConfigManager = require("config/manager")
    local BookWalker = require("common/book_walker")

    if FileChooser._zen_flat_view_compat_patched then return end
    FileChooser._zen_flat_view_compat_patched = true

    -- local has_native_flat_view = FileChooser.show_flat_view ~= nil

    local function is_in_home(path)
        if type(path) ~= "string" then return false end
        return paths.isInHomeDir(ffiUtil.realpath(path) or path)
    end

    -- Temporarily prefer ZenOS's scanner over KOReader's native flat view.
    -- if has_native_flat_view then return end

    local function zen_flat_view_enabled()
        local config = ConfigManager.get()
        return type(config) == "table"
            and type(config.browser_flat_view) == "table"
            and config.browser_flat_view.enabled == true
    end

    if zen_flat_view_enabled() and G_reader_settings:isTrue("show_flat_view") then
        G_reader_settings:saveSetting("show_flat_view", false)
    end

    -- Library only; PathChooser etc. must keep real folder navigation.
    local function flat_view_enabled(path, self)
        return (self == nil or self.name == "filemanager")
            and zen_flat_view_enabled()
            and not paths.hasUnsafeFlatViewHomeRoot()
            and is_in_home(path)
    end

    local function pack(...) return { n = select("#", ...), ... } end

    local function show_hidden(self)
        if FileChooser.show_hidden ~= nil then
            return FileChooser.show_hidden
        end
        return self.show_hidden == true
    end

    -- The paths of the files in folder (names only, no stat).
    local function folder_files(folder)
        local present = {}
        local lfs = require("libs/libkoreader-lfs")
        local ok, iter, dir_obj = pcall(lfs.dir, folder)
        if not ok or not iter then return present end
        local prefix = folder == "/" and "/" or folder .. "/"
        for name in iter, dir_obj do
            if name ~= "." and name ~= ".." then present[prefix .. name] = true end
        end
        return present
    end

    -- Library sources' books (e.g. a catalog's books not downloaded yet),
    -- from BookSources.booksWithoutFile(folders, present), listed as
    -- KOReader lists files: through the browser's filters, as items or,
    -- when only counting, true. present may be a function giving it, asked
    -- only when there are books to check.
    local function add_source_books(self, collate, files, folders, present)
        local ok, BookSources = pcall(require, "common/book_sources")
        if not ok or type(BookSources) ~= "table"
                or type(BookSources.booksWithoutFile) ~= "function" then
            return
        end
        local lazy = type(present) == "function" and present or nil
        local ok_books, books = pcall(BookSources.booksWithoutFile, folders,
            not lazy and present or nil)
        if not ok_books or type(books) ~= "table" then return end
        if lazy and #books > 0 then
            local on_disk = lazy()
            local kept = {}
            for _i, book in ipairs(books) do
                if not on_disk[book.file] then kept[#kept + 1] = book end
            end
            books = kept
        end
        local include_hidden = show_hidden(self)
        for _i, book in ipairs(books) do
            if (include_hidden or book.name:sub(1, 1) ~= ".") and not book.name:match("^%._")
                    and self:show_file(book.name, book.file) then
                local item = true
                if collate then
                    item = self:getListItem(book.folder, book.name, book.file, book.attr, collate)
                    if type(item) == "table" and type(item.doc_props) ~= "table"
                            and type(BookSources.docProps) == "function" then
                        local ok_props, props = pcall(BookSources.docProps, book.file)
                        if ok_props then item.doc_props = props end
                    end
                end
                table.insert(files, item)
            end
        end
    end

    -- A folder's listing (or count) in the file browser: its library
    -- sources' books, after the files KOReader found (a book it listed as a
    -- file is left out). Other sources add their books themselves, if at
    -- all.
    local function add_folder_source_books(self, path, collate, files)
        if self.name ~= "filemanager" or type(path) ~= "string" or type(files) ~= "table" then
            return
        end
        local folder = path:gsub("/+$", "")
        if folder == "" then folder = "/" end
        local present
        if collate then
            present = {}
            for _i, item in ipairs(files) do
                if type(item) == "table" and type(item.path) == "string" then present[item.path] = true end
            end
        else
            -- Only counting: KOReader's items are true, without their names.
            -- Read the folder's names (just after KOReader did) only when it
            -- holds library sources' books, so one that is also a file there
            -- is counted once.
            present = function() return folder_files(folder) end
        end
        add_source_books(self, collate, files, { [folder] = true }, present)
    end

    local function scan_flat(self, path, collate, dirs, files)
        local directories = {}
        if collate then self._zen_flat_view_directories = directories end
        local include_hidden = show_hidden(self)
        local walked, seen = {}, {}
        BookWalker.walk(path, {
            include_hidden = include_hidden,
            on_scan_dir = function(dir, attributes)
                walked[dir] = true
                if collate then directories[dir] = attributes end
            end,
            on_dir = function(name)
                if name == "koreader" then return false end
                return self:show_dir(name)
            end,
            on_file = function(name, fullpath, attributes, _depth, parent_path)
                seen[fullpath] = true
                if not self:show_file(name, fullpath) then return end
                local item = true
                if collate then
                    item = self:getListItem(parent_path, name, fullpath, attributes, collate)
                end
                table.insert(files, item)
            end,
        })
        -- The library sources' books in the folders walked (the walk saw
        -- every file there, so none is listed twice).
        add_source_books(self, collate, files, walked, seen)
        return true -- readable; KOReader >= 2026.10 warns on falsy
    end

    if type(FileChooser.getPathList) == "function" then
        local orig_getPathList = FileChooser.getPathList
        FileChooser.getPathList = function(self, path, collate, dirs, files, ...)
            if flat_view_enabled(path, self) then
                return scan_flat(self, path, collate, dirs, files)
            end
            local r = pack(orig_getPathList(self, path, collate, dirs, files, ...))
            add_folder_source_books(self, path, collate, files)
            return unpack(r, 1, r.n)
        end
    elseif type(FileChooser.getList) == "function" then
        local orig_getList = FileChooser.getList
        FileChooser.getList = function(self, path, collate, ...)
            if flat_view_enabled(path, self) then
                local dirs, files = {}, {}
                return dirs, files, scan_flat(self, path, collate, dirs, files)
            end
            local r = pack(orig_getList(self, path, collate, ...))
            add_folder_source_books(self, path, collate, r[2])
            return unpack(r, 1, r.n)
        end
    end

    if zen_flat_view_enabled() then
        local ok_ui, UIManager = pcall(require, "ui/uimanager")
        if ok_ui and UIManager and type(UIManager.scheduleIn) == "function" then
            local attempts = 0
            local function refresh_startup_listing()
                attempts = attempts + 1
                local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
                local file_chooser = ok_fm and FileManager and FileManager.instance
                    and FileManager.instance.file_chooser
                if file_chooser and type(file_chooser.path) == "string" then
                    if not flat_view_enabled(file_chooser.path) then return end
                    if type(file_chooser.refreshPath) == "function" then
                        file_chooser:refreshPath()
                        return
                    end
                end
                if attempts < 20 then
                    UIManager:scheduleIn(0.1, refresh_startup_listing)
                end
            end
            UIManager:scheduleIn(0.1, refresh_startup_listing)
        end
    end
end

return apply_browser_flat_view_compat
