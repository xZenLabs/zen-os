-- Auto-switch to classic display mode when browsing outside home_dir.
-- Restores the user's preferred mode instantly when returning to home_dir so
-- there is no classic-mode flash.
--
-- changeToPath() calls refreshPath() (which renders items) BEFORE it fires
-- the PathChanged event.  Both the enter-home and leave-home mode switches are
-- handled inside the changeToPath wrapper so the mode is correct BEFORE
-- refreshPath() renders anything, avoiding a double-render flash/lag.
local function apply_browser_display_mode_by_path()
    local FileManager = require("apps/filemanager/filemanager")
    local FileChooser  = require("ui/widget/filechooser")
    local ConfigManager = require("config/manager")
    local ffiUtil      = require("ffi/util")
    local paths        = require("common/paths")

    local VALID_MODES = {
        mosaic_image = true,
        list_image_meta = true,
        list_image_filename = true,
    }

    local function normalize_path(path)
        if not path then return nil end
        local real_path = ffiUtil.realpath(path) or path
        real_path = real_path:gsub("/+$", "")
        return paths.normPath(real_path ~= "" and real_path or "/")
    end

    local function get_config()
        local cfg = ConfigManager.get()
        if type(cfg) ~= "table" then
            cfg = ConfigManager.load()
        end
        return cfg
    end

    local function read_map()
        local cfg = get_config()
        if type(cfg.folder_display_mode) ~= "table" then
            cfg.folder_display_mode = {}
        end
        return cfg.folder_display_mode, cfg
    end

    local function save_config(cfg)
        ConfigManager.save(cfg)
    end

    local function is_in_home(path)
        return paths.isInThemedDir(path)
    end

    local orig_changeToPath = FileChooser.changeToPath
    local _switching = false
    local _active_home_mode = nil

    -- ── Suppress refreshFileManagerInstance, call setDisplayMode, restore ──
    local function apply_mode(cb, mode, file_chooser)
        local orig_refresh = cb.refreshFileManagerInstance
        cb.refreshFileManagerInstance = function() end
        _switching = true
        local ok = pcall(cb.setDisplayMode, cb, mode)
        _switching = false
        cb.refreshFileManagerInstance = orig_refresh
        if ok and file_chooser and type(file_chooser._recalculateDimen) == "function" then
            pcall(file_chooser._recalculateDimen, file_chooser)
        end
    end

    local function save_global_mode(BookInfoManager, mode)
        pcall(BookInfoManager.saveSetting, BookInfoManager,
            "filemanager_display_mode", mode)
    end

    local M = {}

    function M.get(path)
        local key = normalize_path(path)
        if not key then return nil end
        local m = read_map()
        local mode = m[key]
        return VALID_MODES[mode] and mode or nil
    end

    function M.set(path, mode)
        local key = normalize_path(path)
        if not key or not VALID_MODES[mode] or paths.isPrimaryHomeRoot(key) then return end
        local m, cfg = read_map()
        m[key] = mode
        save_config(cfg)
    end

    function M.clear(path)
        local key = normalize_path(path)
        if not key then return end
        local m, cfg = read_map()
        if m[key] == nil then return end
        m[key] = nil
        save_config(cfg)
    end

    function M.apply(path)
        local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
        if not ok_bim then return false end

        local current_mode = BookInfoManager:getSetting("filemanager_display_mode")
        local override = M.get(path)
        local target_mode = override or current_mode

        local fm = FileManager.instance
        local cb = fm and fm.coverbrowser
        if cb and type(cb.setDisplayMode) == "function" then
            apply_mode(cb, target_mode, fm.file_chooser)
            if override then
                save_global_mode(BookInfoManager, current_mode)
            end
            _active_home_mode = target_mode
            return true
        end
        return false
    end

    function M.current()
        return _active_home_mode
    end

    _G.__ZEN_FOLDER_DISPLAY_MODE = M

    FileChooser.changeToPath = function(self, path, ...)
        if not _switching and self.name == "filemanager" then
            -- Resolve realpath before is_in_home: raw ".." paths like home_dir/..
            -- still match the home prefix check and block the classic-mode switch.
            local resolved = ffiUtil.realpath(path) or path
            local in_home = is_in_home(resolved)
            local saved = rawget(_G, "__ZEN_PREFERRED_DISPLAY_MODE")
            local fm = FileManager.instance
            local cb = fm and fm.coverbrowser
            local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
            local current_mode = ok_bim and BookInfoManager:getSetting("filemanager_display_mode") or nil
            local override = in_home and not paths.isPrimaryHomeRoot(resolved) and M.get(resolved) or nil

            if saved and in_home then
                -- ── Entering home_dir: restore preferred mode BEFORE refreshPath ──
                _G.__ZEN_PREFERRED_DISPLAY_MODE = nil
                if cb and type(cb.setDisplayMode) == "function" then
                    local target_mode = override or saved
                    apply_mode(cb, target_mode, self)
                    if override and ok_bim then
                        save_global_mode(BookInfoManager, saved)
                    end
                    _active_home_mode = target_mode
                end

            elseif not in_home then
                -- ── Leaving home_dir: switch to classic BEFORE refreshPath ──
                if ok_bim then
                    if current_mode ~= nil then  -- non-nil means a cover mode is active
                        if not saved then
                            _G.__ZEN_PREFERRED_DISPLAY_MODE = current_mode
                        end
                        if cb and type(cb.setDisplayMode) == "function" then
                            apply_mode(cb, nil, self)  -- nil = classic
                            -- setDisplayMode(nil) persisted nil; write back preferred so
                            -- CoverBrowser reads the correct mode on next restart.
                            pcall(BookInfoManager.saveSetting, BookInfoManager,
                                "filemanager_display_mode", current_mode)
                        end
                    end
                end
            elseif ok_bim and cb and type(cb.setDisplayMode) == "function" then
                local target_mode = override or current_mode
                if _active_home_mode ~= target_mode then
                    apply_mode(cb, target_mode, self)
                    if override then
                        save_global_mode(BookInfoManager, current_mode)
                    end
                    _active_home_mode = target_mode
                end
            end
        end
        return orig_changeToPath(self, path, ...)
    end

    -- ── onPathChanged: only needed for the title-bar update (no mode logic) ──
    local orig_onPathChanged = FileManager.onPathChanged

    function FileManager:onPathChanged(path)
        if orig_onPathChanged then
            orig_onPathChanged(self, path)
        end
    end
end

return apply_browser_display_mode_by_path
