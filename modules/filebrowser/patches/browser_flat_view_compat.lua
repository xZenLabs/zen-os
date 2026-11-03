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

    local function flat_view_enabled(path)
        return zen_flat_view_enabled()
            and not paths.hasUnsafeFlatViewHomeRoot()
            and is_in_home(path)
    end

    local function show_hidden(self)
        if FileChooser.show_hidden ~= nil then
            return FileChooser.show_hidden
        end
        return self.show_hidden == true
    end

    local function scan_flat(self, path, collate, dirs, files)
        local directories = {}
        if collate then self._zen_flat_view_directories = directories end
        BookWalker.walk(path, {
            include_hidden = show_hidden(self),
            on_scan_dir = collate and function(dir, attributes)
                directories[dir] = attributes
            end,
            on_dir = function(name)
                if name == "koreader" then return false end
                return self:show_dir(name)
            end,
            on_file = function(name, fullpath, attributes, _depth, parent_path)
                if not self:show_file(name, fullpath) then return end
                local item = true
                if collate then
                    item = self:getListItem(parent_path, name, fullpath, attributes, collate)
                end
                table.insert(files, item)
            end,
        })
        return true -- readable; KOReader >= 2026.10 warns on falsy
    end

    if type(FileChooser.getPathList) == "function" then
        local orig_getPathList = FileChooser.getPathList
        FileChooser.getPathList = function(self, path, collate, dirs, files, ...)
            if flat_view_enabled(path) then
                return scan_flat(self, path, collate, dirs, files)
            end
            return orig_getPathList(self, path, collate, dirs, files, ...)
        end
    elseif type(FileChooser.getList) == "function" then
        local orig_getList = FileChooser.getList
        FileChooser.getList = function(self, path, collate, ...)
            if flat_view_enabled(path) then
                local dirs, files = {}, {}
                return dirs, files, scan_flat(self, path, collate, dirs, files)
            end
            return orig_getList(self, path, collate, ...)
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
