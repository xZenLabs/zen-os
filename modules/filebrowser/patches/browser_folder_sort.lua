local function apply_browser_folder_sort()
    --[[
        Per-folder sort overrides stored in zen_ui_config.folder_sort.
        Temporarily swaps self.collate and reverse_collate for the overridden path.

        Public API (used by context_menu.lua via __ZEN_FOLDER_SORT global):
          FolderSort.get(path)                  → { collate = "title", reverse = false } or nil
          FolderSort.set(path, collate, reverse) → save override
          FolderSort.clear(path)                → remove override
    ]]

    local FileChooser = require("ui/widget/filechooser")
    local ConfigManager = require("config/manager")
    local ffiUtil     = require("ffi/util")
    local HistoryIndex = require("common/history_index")
    local paths       = require("common/paths")
    local _           = require("gettext")

    local NO_METADATA = "\u{FFFF}"

    local function normalize_path(path)
        if type(path) ~= "string" then return nil end
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
        if type(cfg.folder_sort) ~= "table" then
            cfg.folder_sort = {}
        end
        return cfg.folder_sort, cfg
    end

    local function save_config(cfg)
        ConfigManager.save(cfg)
    end

    local M = {}

    function M.get(path)
        local key = normalize_path(path)
        if not key then return nil end
        local m = read_map()
        local entry = m[key]
        if entry == nil and key ~= path then entry = m[path] end
        -- Backward compat: if entry is a string, convert to table format
        if type(entry) == "string" then
            return { collate = entry, reverse = false }
        end
        return entry
    end

    function M.set(path, collate_id, reverse)
        local key = normalize_path(path)
        if not key or not collate_id then return end
        local m, cfg = read_map()
        m[key] = { collate = collate_id, reverse = reverse or false }
        if key ~= path then m[path] = nil end
        save_config(cfg)
    end

    function M.clear(path)
        local key = normalize_path(path)
        if not key then return end
        local m, cfg = read_map()
        if m[key] == nil and m[path] == nil then return end
        m[key] = nil
        if key ~= path then m[path] = nil end
        save_config(cfg)
    end

    -- Expose API on a well-known global to avoid a cross-module require cycle.
    _G.__ZEN_FOLDER_SORT = M

    -- Wrap getCollate() and getSortingFunction() to inject per-folder overrides.
    -- genItemTable() calls getCollate() for the collate object and reads
    -- reverse_collate from G_reader_settings directly (not self.reverse_collate),
    -- so we must intercept getSortingFunction to substitute the override's reverse.

    local orig_getCollate = FileChooser.getCollate

    FileChooser.getCollate = function(self)
        local override = self._zen_sort_override
        if override and type(override) == "table" then
            local collate_obj = self.collates and self.collates[override.collate]
            if collate_obj then
                return collate_obj, override.collate
            end
        end
        return orig_getCollate(self)
    end

    -- genItemTable() reads reverse_collate from G_reader_settings, bypassing
    -- self.reverse_collate entirely. Intercept getSortingFunction to inject
    -- the override's reverse when it is set. The nil-reverse_collate case is
    -- the internal folder-name fallback sort; don't touch that.
    local orig_getSortingFunction = FileChooser.getSortingFunction

    local function sort_item_key(item)
        local value = tostring(item and (item.path or item.file or item.text) or "")
        return value:lower() .. "\30" .. value
    end

    FileChooser.collates.date_added = {
        text = _("Date added"),
        menu_order = 45,
        can_collate_mixed = true,
        init_sort_func = function()
            return function(a, b)
                local a_attr, b_attr = a.attr or {}, b.attr or {}
                -- ponytail: ctime approximates arrival; track discovery if stable dates are needed.
                local a_time = a_attr.change or a_attr.modification or 0
                local b_time = b_attr.change or b_attr.modification or 0
                if a_time ~= b_time then return a_time > b_time end
                return sort_item_key(a) < sort_item_key(b)
            end
        end,
    }

    FileChooser.getSortingFunction = function(self, collate, reverse_collate)
        local override = self._zen_sort_override
        if override and type(override) == "table" and type(override.reverse) == "boolean"
                and reverse_collate ~= nil then
            reverse_collate = override.reverse
        end
        local sorting = orig_getSortingFunction(self, collate, reverse_collate)
        if not (override and type(sorting) == "function") then return sorting end
        return function(a, b)
            if sorting(a, b) then return true end
            if sorting(b, a) then return false end
            return sort_item_key(a) < sort_item_key(b)
        end
    end

    local function prepare_directory_items(items, collate_id)
        local dirs = {}
        local indices = {}
        for index, item in ipairs(items) do
            if not item.is_go_up and item.attr and item.attr.mode == "directory" then
                local title = tostring(item.text or ""):gsub("/$", "")
                item.doc_props = {
                    display_title = title,
                    title = title,
                    authors = NO_METADATA,
                    series = NO_METADATA,
                    series_index = 0,
                    keywords = NO_METADATA,
                }
                item.suffix = item.suffix or ""
                item.opened = item.opened == true
                item.percent_finished = item.percent_finished or 0
                item.sort_percent = item.sort_percent or 0
                dirs[#dirs + 1] = item
                indices[#indices + 1] = index
            end
        end

        if collate_id == "access" and #dirs > 0 then
            local dir_paths = {}
            for index, item in ipairs(dirs) do
                dir_paths[index] = normalize_path(item.path)
                item._zen_history_time = nil
            end
            local history = HistoryIndex.load(normalize_path)
            local times = HistoryIndex.maxDescendantTimes(history, dir_paths)
            for _i, item in ipairs(dirs) do
                local dir_path = normalize_path(item.path)
                item._zen_history_time = dir_path and times[dir_path] or nil
                item.attr.access = item._zen_history_time
                    or item.attr.modification
                    or item.attr.access
                    or 0
            end
        end

        return dirs, indices
    end

    local function sort_directory_items(self, items, override)
        if type(items) ~= "table" or type(override) ~= "table" then return end
        local collate = self.collates and self.collates[override.collate]
        if not collate then return end

        local dirs, indices = prepare_directory_items(items, override.collate)
        if #dirs < 2 then return end

        local sorting = self:getSortingFunction(collate, override.reverse == true)
        local ok = pcall(table.sort, dirs, sorting)
        if not ok then return end
        for index, item_index in ipairs(indices) do
            items[item_index] = dirs[index]
        end
    end

    local orig_genItemTableFromPath = FileChooser.genItemTableFromPath

    FileChooser.genItemTableFromPath = function(self, path, ...)
        local real_path = ffiUtil.realpath(path) or path

        -- Never apply a per-folder sort override to the home directory.
        local home_dir = paths.getHomeDir()
        if home_dir then
            local home_real = ffiUtil.realpath(home_dir) or home_dir
            if real_path == home_real or path == home_dir then
                return orig_genItemTableFromPath(self, path, ...)
            end
        end

        local override = (real_path and M.get(real_path))
            or (path ~= real_path and M.get(path))

        if not override then
            return orig_genItemTableFromPath(self, path, ...)
        end

        -- Set the instance flag so getCollate() and getSortingFunction() see the override.
        self._zen_sort_override = override
        local saved_reverse = self.reverse_collate

        local ok, result_or_err = pcall(orig_genItemTableFromPath, self, path, ...)

        if ok then pcall(sort_directory_items, self, result_or_err, override) end
        self._zen_sort_override = nil
        self.reverse_collate = saved_reverse

        if ok then
            return result_or_err
        else
            -- Fallback: run without override so the browser stays functional.
            return orig_genItemTableFromPath(self, path, ...)
        end
    end

end

return apply_browser_folder_sort
