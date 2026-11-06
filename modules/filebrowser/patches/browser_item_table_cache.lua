-- Caches file-browser item tables and keeps access sorting tied to read history.
local function apply_browser_item_table_cache()
    local FileChooser = require("ui/widget/filechooser")
    if FileChooser._zen_item_table_cache_patched then return end
    FileChooser._zen_item_table_cache_patched = true

    local HistoryIndex = require("common/history_index")
    local ffiUtil = require("ffi/util")
    local lfs = require("libs/libkoreader-lfs")
    local paths = require("common/paths")
    local SharedState = require("common/shared_state")
    local zen_logger = require("common/zen_logger")
    local logger = zen_logger.new("browser_item_table_cache")
    local now = zen_logger.now
    local plugin = rawget(_G, "__ZEN_UI_PLUGIN")

    local ITEM_TABLE_CACHE_MAX = 32
    local FOLDER_AGGREGATE_CACHE_MAX = 128
    local PERSISTED_CACHE_MAX = 4
    local PERSISTED_ITEM_MAX = 4096
    local PERSISTED_SCHEMA = 6
    local PERSISTED_TREE_DEPTH = 2
    local PERSISTED_TREE_DIR_MAX = 256
    local PERSISTED_TREE_ENTRY_MAX = 4096
    local shared_cache = { values = {}, order = {} }
    -- Disk snapshot, loaded on demand and released after each flush event.
    local persisted_cache
    local persisted_store
    local persisted_keys -- path -> key on disk while released
    -- Writes are batched until FlushSettings/SaveSettings (suspend, FM close) to spare flash.
    local pending = { values = {}, order = {} } -- false value = drop
    local persist_owner = {}
    local build_tree_signature, directory_signature
    FileChooser._zen_item_table_cache_persist_owner = persist_owner

    local function stable_table_key(value)
        if type(value) ~= "table" then return tostring(value) end
        local fields = {}
        for key, field_value in pairs(value) do
            local kind = type(field_value)
            if kind == "string" or kind == "number" or kind == "boolean" or field_value == nil then
                fields[#fields + 1] = tostring(key) .. "=" .. tostring(field_value)
            end
        end
        table.sort(fields)
        return table.concat(fields, "\31")
    end

    local function compatibility_key()
        local plugin_version = plugin and plugin.version
        if type(plugin_version) ~= "string" or plugin_version == "" then
            local ok_meta, meta = pcall(require, "_meta")
            plugin_version = ok_meta and type(meta) == "table" and meta.version or "dev"
        end

        local koreader_version = rawget(_G, "KOREADER_VERSION")
            or rawget(_G, "KO_VERSION") or rawget(_G, "GIT_REV")
        if koreader_version == nil then
            local ok_version, version = pcall(require, "version")
            if ok_version and type(version) == "table" then
                koreader_version = version.version or version.short or version.git
                    or version.git_rev or version.build or version.tag
            elseif ok_version and type(version) == "string" then
                koreader_version = version
            end
        end
        return table.concat({
            tostring(PERSISTED_SCHEMA), tostring(plugin_version),
            tostring(koreader_version or "unknown"),
        }, "|")
    end

    local function empty_persisted_cache()
        return {
            schema = PERSISTED_SCHEMA,
            compatibility = compatibility_key(),
            values = {},
            order = {},
        }
    end

    local function load_persisted_cache()
        if persisted_cache then return persisted_cache end
        local started_at = now()
        local ok_luasettings, LuaSettings = pcall(require, "luasettings")
        local ok_store, PresetStore = pcall(require, "config/preset_store")
        if not (ok_luasettings and LuaSettings and type(LuaSettings.open) == "function"
                and ok_store and PresetStore and type(PresetStore.rootDir) == "function") then
            persisted_cache = empty_persisted_cache()
            logger.measure("Library snapshot loaded", (now() - started_at) * 1000,
                "cache=unavailable", "entries=", 0)
            return persisted_cache
        end

        local ok_root, root_dir = pcall(PresetStore.rootDir)
        local ok_open, store
        if ok_root and type(root_dir) == "string" and root_dir ~= "" then
            ok_open, store = pcall(LuaSettings.open, LuaSettings,
                root_dir .. "/library_item_cache.lua")
        end
        if not ok_open or type(store) ~= "table" then
            persisted_cache = empty_persisted_cache()
            logger.measure("Library snapshot loaded", (now() - started_at) * 1000,
                "cache=open_failed", "entries=", 0)
            return persisted_cache
        end
        persisted_store = store
        local data = store.data
        local compatible = type(data) == "table"
            and data.schema == PERSISTED_SCHEMA
            and data.compatibility == compatibility_key()
            and type(data.values) == "table"
            and type(data.order) == "table"
        persisted_cache = compatible and data or empty_persisted_cache()
        logger.measure("Library snapshot loaded", (now() - started_at) * 1000,
            compatible and "cache=hit" or "cache=incompatible",
            "entries=", #persisted_cache.order)
        return persisted_cache
    end

    local function release_persisted_cache()
        if not persisted_cache then return end
        persisted_keys = {}
        for path, value in pairs(persisted_cache.values) do persisted_keys[path] = value.key end
        persisted_cache, persisted_store = nil, nil
    end

    local function remove_path(order, path)
        for index = #order, 1, -1 do
            if order[index] == path then table.remove(order, index) end
        end
    end

    local function set_pending(path, entry)
        if pending.values[path] == nil then pending.order[#pending.order + 1] = path end
        pending.values[path] = entry
        local count = 0
        for index = #pending.order, 1, -1 do
            local queued = pending.order[index]
            if pending.values[queued] then
                count = count + 1
                if count > PERSISTED_CACHE_MAX then
                    pending.values[queued] = nil
                    table.remove(pending.order, index)
                end
            end
        end
    end

    local function flush_persisted_cache()
        if FileChooser._zen_item_table_cache_persist_owner ~= persist_owner then return end
        if not pending.clear and #pending.order == 0 then
            release_persisted_cache()
            return
        end
        local cache = load_persisted_cache()
        if pending.clear then cache.values, cache.order = {}, {} end
        for _i, path in ipairs(pending.order) do
            local entry = pending.values[path]
            if entry then
                if not cache.values[path] then cache.order[#cache.order + 1] = path end
                cache.values[path] = entry
            elseif cache.values[path] then
                cache.values[path] = nil
                remove_path(cache.order, path)
            end
        end
        pending = { values = {}, order = {} }
        while #cache.order > PERSISTED_CACHE_MAX do
            cache.values[table.remove(cache.order, 1)] = nil
        end
        if not (persisted_store and type(persisted_store.flush) == "function") then
            release_persisted_cache()
            return
        end
        local started_at = now()
        local invalid_paths = {}
        local signature_fallbacks = 0
        for _i, path in ipairs(cache.order) do
            local value = cache.values[path]
            -- Writes are deferred: reject listings whose root changed since the scan.
            if value and value.needs_tree_signature
                    and value.key ~= tostring(value.stable_key) .. "|" .. directory_signature(path) then
                logger.warn("Library snapshot rejected", "path=", path, "reason=", "root_changed")
                invalid_paths[#invalid_paths + 1] = path
            elseif value and value.needs_tree_signature then
                local ok_signature, signature, signature_mode, signature_reason =
                    pcall(build_tree_signature, path, value.requires_full_tree)
                if not ok_signature then
                    signature_reason = tostring(signature)
                    signature = nil
                    signature_mode = "failed"
                end
                if signature_mode == "root" and value.requires_full_tree then
                    signature = nil
                    signature_reason = "flat_view_requires_full_tree"
                end
                if signature then
                    value.tree_signature = signature
                    value.tree_signature_mode = signature_mode
                    value.needs_tree_signature = nil
                    if signature_mode ~= "full" and value.requires_full_tree then
                        signature_fallbacks = signature_fallbacks + 1
                        logger.warn("Library snapshot signature degraded",
                            "path=", path, "mode=", tostring(signature_mode),
                            "reason=", tostring(signature_reason))
                    end
                else
                    logger.warn("Library snapshot signature rejected",
                        "path=", path, "reason=", tostring(signature_reason))
                    invalid_paths[#invalid_paths + 1] = path
                end
            end
        end
        for _i, path in ipairs(invalid_paths) do
            cache.values[path] = nil
            remove_path(cache.order, path)
        end
        persisted_store.data = cache
        local ok_flush, err = pcall(persisted_store.flush, persisted_store)
        logger.measure("Library snapshot saved", (now() - started_at) * 1000,
            ok_flush and "cache=written" or "cache=write_failed",
            "entries=", #cache.order,
            "signature_fallbacks=", signature_fallbacks)
        if not ok_flush then logger.warn("Library snapshot write failed", tostring(err)) end
        release_persisted_cache()
    end

    local function cancel_persist()
        pending = { values = {}, order = {} }
        release_persisted_cache()
    end

    local function copy_serializable(value, seen, skipped_key)
        local kind = type(value)
        if kind == "nil" or kind == "string" or kind == "number" or kind == "boolean" then
            return value, true
        end
        if kind ~= "table" or getmetatable(value) ~= nil or seen[value] then
            return nil, false
        end
        seen[value] = true
        local copied = {}
        for key, field_value in pairs(value) do
            local key_kind = type(key)
            if key ~= skipped_key then
                if key_kind ~= "string" and key_kind ~= "number" then
                    seen[value] = nil
                    return nil, false
                end
                local field_copy, ok = copy_serializable(field_value, seen)
                if not ok then
                    seen[value] = nil
                    return nil, false
                end
                copied[key] = field_copy
            end
        end
        seen[value] = nil
        return copied, true
    end

    local function snapshot_item_table(item_table)
        if type(item_table) ~= "table" or #item_table > PERSISTED_ITEM_MAX then return nil end
        local snapshot, seen = {}, {}
        for index, item in ipairs(item_table) do
            if type(item) ~= "table" or type(item.path) ~= "string" then return nil end
            local copied, ok = copy_serializable(item, seen, "bidi_wrap_func")
            if not ok then return nil end
            snapshot[index] = copied
        end
        return snapshot
    end

    local function restore_item_table(snapshot)
        if type(snapshot) ~= "table" or #snapshot > PERSISTED_ITEM_MAX then return nil end
        local ok_bidi, BD = pcall(require, "ui/bidi")
        local restored, seen = {}, {}
        for index, item in ipairs(snapshot) do
            local copied, ok = copy_serializable(item, seen)
            if not ok or type(copied.path) ~= "string" then return nil end
            if ok_bidi and type(copied.attr) == "table" then
                if copied.attr.mode == "file" then
                    copied.bidi_wrap_func = BD.filename
                elseif copied.attr.mode == "directory" then
                    copied.bidi_wrap_func = BD.directory
                end
            end
            restored[index] = copied
        end
        return restored
    end

    local function folder_aggregate_cache(self)
        if not self._zen_folder_aggregate_cache then
            self._zen_folder_aggregate_cache = { values = {}, order = {} }
        end
        return self._zen_folder_aggregate_cache
    end

    local function cache_folder_aggregate(self, path, mtime, access, modification)
        local cache = folder_aggregate_cache(self)
        if not cache.values[path] then cache.order[#cache.order + 1] = path end
        cache.values[path] = { mtime = mtime, access = access, modification = modification }
        while #cache.order > FOLDER_AGGREGATE_CACHE_MAX do
            cache.values[table.remove(cache.order, 1)] = nil
        end
    end

    local function folder_sort_override(path)
        local api = rawget(_G, "__ZEN_FOLDER_SORT")
        if not (api and type(api.get) == "function") then return nil end
        return api.get(path)
    end

    local function folder_sort_key(override)
        if type(override) ~= "table" then return "" end
        return tostring(override.collate or "") .. ":" .. tostring(override.reverse == true)
    end

    local function automatic_series_enabled()
        local features = plugin and plugin.config and plugin.config.features
        return type(features) ~= "table" or features.automatic_series_grouping ~= false
    end

    local function hide_grouped_series_enabled()
        local features = plugin and plugin.config and plugin.config.features
        return type(features) == "table" and features.hide_grouped_series == true
    end

    local function dim_finished_enabled()
        local config = plugin and plugin.config and plugin.config.browser_cover_badges
        return type(config) == "table" and config.dim_finished_books == true
    end

    local function up_folder_visibility_key()
        local config = plugin and plugin.config
        local features = type(config) == "table" and config.features
        local folder_config = type(config) == "table" and config.browser_hide_up_folder
        return table.concat({
            tostring(type(features) == "table" and features.browser_hide_up_folder == true),
            tostring(type(folder_config) == "table" and folder_config.hide_up_folder == true),
            tostring(type(folder_config) == "table" and folder_config.lock_home_folder or "zen"),
            tostring(type(features) == "table" and features.zen_mode == true),
        }, ":")
    end

    local function canonical_path(path)
        if not path then return nil end
        return paths.normPath((ffiUtil.realpath(path) or path):gsub("/$", ""))
    end

    -- Rebuilds the index only when ReadHistory actually changed.  The
    -- KOReader reload() re-parses history.lua and rebuilds the table on every
    -- file change; in-place mutations (clearMissing, removeItem, _reduce)
    -- change the length or the head/tail entry.  Rebuilding the index walks
    -- every history entry through realpath(), so the steady state must not
    -- pay for it on each listing refresh.
    local _history_index_memo = nil
    local function history_time_map()
        local ReadHistory = package.loaded["readhistory"]
        local hist = ReadHistory and ReadHistory.hist
        local memo = _history_index_memo
        if memo and type(hist) == "table" and memo.len == #hist
                and memo.first == hist[1] and memo.last == hist[#hist] then
            -- The snapshot still matches, whether hist is the same table or a
            -- reload with identical content.
            return memo.index
        end
        local index = HistoryIndex.load(canonical_path)
        if type(hist) == "table" then
            _history_index_memo = {
                hist = hist, len = #hist,
                first = hist[1], last = hist[#hist],
                index = index,
            }
        end
        return index
    end

    local function is_special_item(item)
        return item.is_go_up or (item.path and item.path:sub(-2) == "/.")
    end

    local function apply_history_order(chooser, item_table, collate, reverse_collate)
        if type(item_table) ~= "table" then return item_table end
        local map = history_time_map()
        local reverse = type(reverse_collate) == "boolean"
            and reverse_collate or G_reader_settings:isTrue("reverse_collate")
        local mixed = collate.can_collate_mixed and G_reader_settings:isTrue("collate_mixed")
        local directory_paths = {}
        for _i, item in ipairs(item_table) do
            if not is_special_item(item) and item.attr and item.attr.mode == "directory" then
                item._zen_canonical_path = canonical_path(item.path)
                directory_paths[#directory_paths + 1] = item._zen_canonical_path
            end
        end
        local directory_times = HistoryIndex.maxDescendantTimes(map, directory_paths)

        for _i, item in ipairs(item_table) do
            if not is_special_item(item) then
                local is_directory = item.attr and item.attr.mode == "directory"
                local read_time
                if is_directory then
                    read_time = directory_times[item._zen_canonical_path]
                else
                    -- Memoized on the cached item: realpath per file per listing is costly.
                    read_time = HistoryIndex.fileTime(map, item.path, function(path)
                        if item._zen_canonical_path == nil then
                            item._zen_canonical_path = canonical_path(path) or false
                        end
                        return item._zen_canonical_path or nil
                    end)
                end
                if read_time then
                    item.attr = item.attr or {}
                    item.attr.access = read_time
                    if not is_directory and collate.mandatory_func ~= nil then
                        item.mandatory = chooser:getMenuItemMandatory(item, collate)
                    end
                end
                item._zen_sort_key = read_time or (item.attr and item.attr.modification) or 0
                item._zen_sort_text = tostring(item.text or ""):lower()
            end
        end

        local function compare(a, b)
            local a_key, b_key = a._zen_sort_key or 0, b._zen_sort_key or 0
            if a_key == b_key then
                return a._zen_sort_text < b._zen_sort_text
            end
            if reverse then return a_key < b_key end
            return a_key > b_key
        end

        -- The same table is re-sorted on every refresh, and consecutive
        -- listings rarely change the keys; verifying the current order is
        -- O(n) and skips the O(n log n) sort when it already holds.
        local function already_ordered(items)
            for i = 2, #items do
                if not compare(items[i - 1], items[i]) then return false end
            end
            return true
        end

        local head, directories, files = {}, {}, {}
        for _i, item in ipairs(item_table) do
            if is_special_item(item) then
                head[#head + 1] = item
            elseif item.attr and item.attr.mode == "directory" then
                directories[#directories + 1] = item
            else
                files[#files + 1] = item
            end
        end

        local result = {}
        for _i, item in ipairs(head) do result[#result + 1] = item end
        if mixed then
            local body = {}
            for _i, item in ipairs(directories) do body[#body + 1] = item end
            for _i, item in ipairs(files) do body[#body + 1] = item end
            if not already_ordered(body) then table.sort(body, compare) end
            for _i, item in ipairs(body) do result[#result + 1] = item end
        else
            if not already_ordered(directories) then table.sort(directories, compare) end
            if not already_ordered(files) then table.sort(files, compare) end
            for _i, item in ipairs(directories) do result[#result + 1] = item end
            for _i, item in ipairs(files) do result[#result + 1] = item end
        end
        -- Keep the table identity when the order holds so downstream memos (series grouping) hit.
        for index = 1, #result do
            if result[index] ~= item_table[index] then return result end
        end
        return #result == #item_table and item_table or result
    end

    local original_getListItem = FileChooser.getListItem
    function FileChooser:getListItem(dirpath, filename, fullpath, attributes, collate)
        if self._dummy or self.name ~= "filemanager" then
            return original_getListItem(self, dirpath, filename, fullpath, attributes, collate)
        end
        if attributes.mode == "directory" and collate
                and collate ~= (self.collates and self.collates.access)
                and collate.can_collate_mixed and collate.mandatory_func and not collate.item_func then
            local item = original_getListItem(self, dirpath, filename, fullpath, attributes, collate)
            local mtime = attributes.modification or 0
            local aggregate = folder_aggregate_cache(self).values[fullpath]
            local cached = aggregate and aggregate.mtime == mtime
            local max_access = cached and aggregate.access or attributes.access or 0
            local max_modification = cached and aggregate.modification or mtime
            if not cached then
                local ok, iterator, directory = pcall(lfs.dir, fullpath)
                if ok then
                    for child in iterator, directory do
                        if child ~= "." and child ~= ".." then
                            local child_attr = lfs.attributes(fullpath .. "/" .. child)
                            if child_attr and child_attr.mode == "file" then
                                max_access = math.max(max_access, child_attr.access or 0)
                                max_modification = math.max(max_modification, child_attr.modification or 0)
                            end
                        end
                    end
                end
                cache_folder_aggregate(self, fullpath, mtime, max_access, max_modification)
            end
            local copied = {}
            for key, value in pairs(attributes) do copied[key] = value end
            copied.access, copied.modification = max_access, max_modification
            item.attr = copied
            return item
        end

        return original_getListItem(self, dirpath, filename, fullpath, attributes, collate)
    end

    local function status_filter(self)
        local filter = self and self.show_filter or FileChooser.show_filter
        return type(filter) == "table" and filter.status or nil
    end

    local function status_filter_active(self)
        return status_filter(self) ~= nil
    end

    -- A status change rewrites only the book's sidecar, which leaves folder
    -- timestamps alone, so filtered listings are keyed on ZenOS's status
    -- revision (bumped by every status change ZenOS makes).
    local function status_filter_key(self)
        local filter = status_filter(self)
        if filter == nil then return "nil" end
        local BookStatus = package.loaded["common/book_status"]
        local revision = type(BookStatus) == "table" and type(BookStatus.revision) == "function"
            and BookStatus.revision()
        return stable_table_key(filter) .. "@" .. tostring(revision or 0)
    end

    local function stable_key(self, path, override)
        local flat_config = plugin and plugin.config and plugin.config.browser_flat_view
        local show_hidden = self.show_hidden
        if show_hidden == nil then show_hidden = FileChooser.show_hidden end
        local show_flat_view = self.show_flat_view
        if show_flat_view == nil then show_flat_view = FileChooser.show_flat_view end
        local show_unsupported = self.show_unsupported
        if show_unsupported == nil then show_unsupported = FileChooser.show_unsupported end
        return table.concat({
            tostring(path),
            tostring(G_reader_settings:readSetting("collate", "strcoll")),
            tostring(G_reader_settings:isTrue("collate_mixed")),
            tostring(G_reader_settings:isTrue("reverse_collate")),
            tostring(show_hidden), status_filter_key(self), folder_sort_key(override),
            tostring(automatic_series_enabled()), tostring(hide_grouped_series_enabled()),
            tostring(dim_finished_enabled()),
            up_folder_visibility_key(), tostring(show_flat_view),
            tostring(flat_config and flat_config.enabled == true),
            tostring(show_unsupported),
            tostring(G_reader_settings:readSetting("show_file_in_bold")),
            tostring(G_reader_settings:readSetting("show_parent_folder")),
            tostring(G_reader_settings:isTrue("lock_home_folder")),
            tostring(G_reader_settings:readSetting("home_dir")),
            tostring(self.show_current_dir_for_hold == true),
        }, "\31")
    end

    local function attr_signature(attr)
        return table.concat({
            tostring(attr.modification or 0), tostring(attr.change or 0),
            tostring(attr.size or 0), tostring(attr.ino or 0),
        }, ":")
    end

    directory_signature = function(path)
        local attr = lfs.attributes(path)
        if type(attr) == "table" then return attr_signature(attr) end
        return tostring(lfs.attributes(path, "modification") or 0)
    end

    -- Timestamps are whole seconds, and FAT32 (Kobo and most e-readers) keeps
    -- them in 2 s steps, so a folder changed just after a scan can keep the
    -- timestamp the scan saw. Treat a folder whose timestamp falls in that
    -- window as changed. Timestamps later than the scan's end were already
    -- there (e.g. a computer with a fast clock) and do not count.
    local function changed_near_scan(modification, value)
        local started = value and value.scanned_at
        if type(started) ~= "number" or type(modification) ~= "number" then return false end
        local finished = value.scanned_until
        return modification >= started - 1
            and (type(finished) ~= "number" or modification <= finished + 1)
    end

    -- Calibre rewrites its book list (metadata.calibre or .metadata.calibre)
    -- in the library root after every book it sends, metadata update and
    -- deletion, whether over wireless or from the computer over USB. Folder
    -- timestamps miss some of these: an overwritten book leaves its folder
    -- untouched, and nested Author/ folders can sit below the child-folder
    -- check. Listings in or above a Calibre library therefore also record
    -- the book list's signature.
    local CALIBRE_METADATA_FILES = { "metadata.calibre", ".metadata.calibre" }

    local function strip_trailing_slashes(path)
        return (path:gsub("(.)/+$", "%1"))
    end

    -- True when the paths are equal or one contains the other.
    local function paths_related(a, b)
        if a == b then return true end
        local inside, outside = a, b
        if #a < #b then inside, outside = b, a end
        if outside == "/" then return inside:sub(1, 1) == "/" end
        return inside:sub(1, #outside + 1) == outside .. "/"
    end

    -- Returns the book list's signature ("missing" when absent) and timestamp.
    local function calibre_signature(root)
        local prefix = root == "/" and "" or root
        for _i, name in ipairs(CALIBRE_METADATA_FILES) do
            local attr = lfs.attributes(prefix .. "/" .. name)
            if type(attr) == "table" and attr.mode == "file" then
                return attr_signature(attr), attr.modification
            end
        end
        return "missing"
    end

    -- Wireless always writes into inbox_dir, recorded even before Calibre
    -- has created its book list there so that the first send is noticed.
    -- Other libraries (e.g. written over USB) are found above the listing.
    -- Runs only on a full scan, which already reads the whole folder.
    local function calibre_signatures(path)
        if type(path) ~= "string" or path == "" then return nil end
        path = strip_trailing_slashes(path)
        local signatures
        local inbox = G_reader_settings and G_reader_settings:readSetting("inbox_dir")
        if type(inbox) == "string" and inbox ~= "" then
            inbox = strip_trailing_slashes(inbox)
            if paths_related(path, inbox) then
                signatures = { [inbox] = calibre_signature(inbox) }
            end
        end
        local dir = path
        while dir and dir ~= "" and dir ~= "/" do
            local signature = calibre_signature(dir)
            if signature ~= "missing" then
                signatures = signatures or {}
                signatures[dir] = signature
            end
            dir = dir:match("^(.+)/[^/]*$")
        end
        return signatures
    end

    local function calibre_unchanged(value)
        for root, expected in pairs(value.calibre_signatures or {}) do
            local current, modification = calibre_signature(root)
            if current ~= expected or changed_near_scan(modification, value) then
                return false
            end
        end
        return true
    end

    -- Also reports whether any child directory changed near the value's scan.
    local function child_directory_signatures(item_table, value)
        local signatures = {}
        local near_scan = false
        for _i, item in ipairs(item_table or {}) do
            if item.attr and item.attr.mode == "directory" and type(item.path) == "string" then
                local attr = lfs.attributes(item.path)
                if type(attr) == "table" then
                    signatures[item.path] = attr_signature(attr)
                    near_scan = near_scan or changed_near_scan(attr.modification, value)
                else
                    signatures[item.path] = directory_signature(item.path)
                end
            end
        end
        return signatures, near_scan
    end

    -- True when the freshly scanned map matches the stored one, in both
    -- directions: a child removed from the listing invalidates the stored map.
    local function signatures_match(stored, fresh)
        if type(stored) ~= "table" then return false end
        for path, signature in pairs(fresh) do
            if stored[path] ~= signature then return false end
        end
        for path in pairs(stored) do
            if not fresh[path] then return false end
        end
        return true
    end

    -- Validates the cached listing's child directories against the current
    -- filesystem.  Each validation is one lfs.attributes per child directory;
    -- consecutive lookups of the same value (refresh, focus moves, path
    -- re-reads) skip the scan for CHILD_VALIDATION_TTL_S, and the freshly
    -- scanned map is kept on the value so callers that repopulate the cache
    -- (history re-order, disk restore) do not scan a second time.
    local CHILD_VALIDATION_TTL_S = 5
    local function validate_children(value, path)
        if type(path) == "string"
                and changed_near_scan(lfs.attributes(path, "modification"), value) then
            return false
        end
        if not calibre_unchanged(value) then return false end
        if value.recursive then
            local signatures = value.child_directory_signatures
            if type(signatures) ~= "table" or next(signatures) == nil then return false end
            for dir, signature in pairs(signatures) do
                if type(dir) ~= "string" then return false end
                local attributes = lfs.attributes(dir)
                if not attributes or attr_signature(attributes) ~= signature
                        or not value.scanned_at
                        or changed_near_scan(attributes.modification, value) then
                    return false
                end
            end
            return true
        end
        if value.last_children_check and value.last_children_ok
                and now() - value.last_children_check < CHILD_VALIDATION_TTL_S then
            return true
        end
        local fresh, near_scan = child_directory_signatures(value.table, value)
        local ok = not near_scan and signatures_match(value.child_directory_signatures, fresh)
        value.child_directory_signatures = fresh
        value.last_children_check = now()
        value.last_children_ok = ok
        return ok
    end

    build_tree_signature = function(root, full_tree)
        if not full_tree then
            local attr = lfs.attributes(root)
            if type(attr) ~= "table" or attr.mode ~= "directory" then
                return nil, "failed", "root_unavailable"
            end
            return { [root] = attr_signature(attr) }, "root"
        end
        local signature = {}
        local directory_count = 0
        local entry_count = 0
        local failure_reason

        local function walk(path, depth)
            local attr = lfs.attributes(path)
            if type(attr) ~= "table" or attr.mode ~= "directory" then
                failure_reason = "not_directory"
                return false
            end
            directory_count = directory_count + 1
            if directory_count > PERSISTED_TREE_DIR_MAX then
                failure_reason = "directory_limit"
                return false
            end
            signature[path] = attr_signature(attr)
            if depth >= PERSISTED_TREE_DEPTH then return true end

            local ok_dir, iterator, directory = pcall(lfs.dir, path)
            if not ok_dir or type(iterator) ~= "function" then
                failure_reason = "directory_open"
                return false
            end
            while true do
                local ok_next, child = pcall(iterator, directory)
                if not ok_next then
                    failure_reason = "directory_read"
                    return false
                end
                if child == nil then break end
                if child ~= "." and child ~= ".." and child:sub(1, 1) ~= "."
                        and child:sub(-4) ~= ".sdr" then
                    entry_count = entry_count + 1
                    if entry_count > PERSISTED_TREE_ENTRY_MAX then
                        failure_reason = "entry_limit"
                        return false
                    end
                    local child_path = path .. "/" .. child
                    if lfs.attributes(child_path, "mode") == "directory"
                            and not walk(child_path, depth + 1) then return false end
                end
            end
            return true
        end

        if walk(root, 0) then return signature, "full" end

        -- A persisted listing is still useful with the same root-directory
        -- validation used by the in-memory cache. Large or partly unreadable
        -- trees should not silently discard the entire snapshot.
        local root_attr = lfs.attributes(root)
        if type(root_attr) ~= "table" or root_attr.mode ~= "directory" then
            return nil, "failed", failure_reason or "root_unavailable"
        end
        return { [root] = attr_signature(root_attr) }, "root",
            failure_reason or "tree_unavailable"
    end

    local function tree_signature_matches(signature)
        if type(signature) ~= "table" then return false end
        local count = 0
        for path, expected in pairs(signature) do
            count = count + 1
            if count > PERSISTED_TREE_DIR_MAX or type(path) ~= "string"
                    or type(expected) ~= "string"
                    or directory_signature(path) ~= expected then return false end
        end
        return count > 0
    end

    local function get_cached(path, key)
        local value = shared_cache.values[path]
        return value and value.key == key and validate_children(value, path) and value or nil
    end

    local function put_cached(path, value)
        if not value.child_directory_signatures then
            value.child_directory_signatures = child_directory_signatures(value.table)
        end
        value.last_children_ok = true
        value.last_children_check = now()
        if not shared_cache.values[path] then shared_cache.order[#shared_cache.order + 1] = path end
        shared_cache.values[path] = value
        while #shared_cache.order > ITEM_TABLE_CACHE_MAX do
            shared_cache.values[table.remove(shared_cache.order, 1)] = nil
        end
    end

    local function get_persisted(self, path, key)
        if status_filter_active(self) then return nil, "disk_filtered" end
        if pending.clear or pending.values[path] ~= nil then return nil, "disk_pending" end
        if not persisted_cache and persisted_keys and persisted_keys[path] ~= key then
            return nil, persisted_keys[path] and "disk_stale" or "disk_miss"
        end
        local cache = load_persisted_cache()
        local value = cache.values[path]
        if not value then return nil, "disk_miss" end
        if value.key ~= key then return nil, "disk_stale" end
        if not validate_children(value, path) then return nil, "disk_stale_children" end
        if not value.recursive and not tree_signature_matches(value.tree_signature) then
            return nil, "disk_stale_tree"
        end
        local restored = restore_item_table(value.table)
        if not restored then return nil, "disk_invalid" end
        return {
            key = value.key,
            stable_key = value.stable_key,
            table = restored,
            child_directory_signatures = value.child_directory_signatures,
            calibre_signatures = value.calibre_signatures,
            recursive = value.recursive,
            scanned_at = value.scanned_at,
            scanned_until = value.scanned_until,
            tree_signature_mode = value.tree_signature_mode or "legacy",
        }, "disk_hit"
    end

    local function put_persisted(self, path, value)
        if status_filter_active(self)
                or FileChooser._zen_item_table_cache_persist_owner ~= persist_owner then
            return false
        end
        local snapshot = snapshot_item_table(value.table)
        if not snapshot then return false end
        set_pending(path, {
            key = value.key,
            stable_key = value.stable_key,
            table = snapshot,
            child_directory_signatures = value.child_directory_signatures,
            calibre_signatures = value.calibre_signatures,
            recursive = value.recursive,
            scanned_at = value.scanned_at,
            scanned_until = value.scanned_until,
            tree_signature_mode = value.recursive and "full" or nil,
            needs_tree_signature = not value.recursive,
            requires_full_tree = value.recursive or self.show_flat_view == true
                or (self.show_flat_view == nil and FileChooser.show_flat_view == true),
        })
        return true
    end

    local function clear_persisted_cache()
        pending = { values = {}, order = {}, clear = true }
    end

    local function drop_persisted_path(path)
        if pending.clear then return false end
        if not (persisted_cache or persisted_keys) then load_persisted_cache() end
        local exists = pending.values[path]
            or (persisted_cache and persisted_cache.values[path])
            or (persisted_keys and persisted_keys[path])
        if not exists then return false end
        set_pending(path, false)
        return true
    end

    function FileChooser:_zen_clear_item_table_cache()
        shared_cache = { values = {}, order = {} }
        self._zen_prepared_item_table = nil
        clear_persisted_cache()
        self._zen_folder_aggregate_cache = nil
        local FolderCover = package.loaded["modules/filebrowser/folder_cover"]
        if FolderCover and type(FolderCover.clear) == "function" then
            FolderCover.clear()
        end
    end

    function FileChooser:_zen_invalidate_item_table_path(path)
        if type(path) ~= "string" or path == "" then return false end
        if self._zen_prepared_item_table
                and self._zen_prepared_item_table.path == path then
            self._zen_prepared_item_table = nil
        end
        local dropped = shared_cache.values[path] ~= nil
        shared_cache.values[path] = nil
        for index = #shared_cache.order, 1, -1 do
            if shared_cache.order[index] == path then table.remove(shared_cache.order, index) end
        end
        self._zen_folder_aggregate_cache = nil
        local FolderCover = package.loaded["modules/filebrowser/folder_cover"]
        if FolderCover and type(FolderCover.clear) == "function" then
            FolderCover.clear(path)
        end
        return drop_persisted_path(path) or dropped
    end

    function FileChooser:_zen_prepare_item_table(path, items)
        if self._dummy or self.name ~= "filemanager"
                or type(path) ~= "string" or type(items) ~= "table" then
            return false
        end
        local cached = shared_cache.values[path]
        if not cached or cached.table ~= items then return false end
        self._zen_prepared_item_table = {
            path = path,
            key = cached.key,
            table = items,
            last_read_file = rawget(_G, "__ZEN_UI_LAST_READ_FILE"),
        }
        return true
    end

    function FileChooser:_zen_discard_prepared_item_table(path)
        local prepared = self._zen_prepared_item_table
        if not prepared or (path and prepared.path ~= path) then return false end
        self._zen_prepared_item_table = nil
        return true
    end

    function FileChooser:_zen_flush_item_table_cache_persist()
        flush_persisted_cache()
    end

    for _i, event in ipairs({ "onFlushSettings", "onSaveSettings" }) do
        local original = FileChooser[event]
        FileChooser[event] = function(self, ...)
            flush_persisted_cache()
            if original then return original(self, ...) end
        end
    end

    function FileChooser:_zen_cancel_item_table_cache_persist()
        cancel_persist()
        if FileChooser._zen_item_table_cache_persist_owner == persist_owner then
            FileChooser._zen_item_table_cache_persist_owner = nil
        end
    end

    local original_genItemTableFromPath = FileChooser.genItemTableFromPath
    function FileChooser:genItemTableFromPath(path)
        if self._dummy or self.name ~= "filemanager" then
            return original_genItemTableFromPath(self, path)
        end

        local deferred = rawget(_G, "__ZEN_UI_DEFER_FILEMANAGER_LISTING")
        if type(deferred) == "table" and deferred.path == path then
            logger.measure("File list generated", 0,
                "cache=deferred", "path=", tostring(path), "items=", 0)
            self._zen_last_item_table_cache_result = {
                cache = "deferred", elapsed_ms = 0, items = 0,
            }
            return {}, true
        end

        local started_at = now()
        local override = folder_sort_override(path)
        local collate_mode = type(override) == "table" and override.collate
            or G_reader_settings:readSetting("collate", "strcoll")
        local collate = (self.collates and self.collates[collate_mode]) or self:getCollate()
        local reverse = type(override) == "table"
            and override.reverse or G_reader_settings:isTrue("reverse_collate")
        local stable = stable_key(self, path, override)
        local key = stable .. "|" .. directory_signature(path)
        local prepared = self._zen_prepared_item_table
        if prepared then
            self._zen_prepared_item_table = nil
            if prepared.path == path and prepared.key == key
                    and prepared.last_read_file
                        == rawget(_G, "__ZEN_UI_LAST_READ_FILE") then
                logger.measure("File list generated", (now() - started_at) * 1000,
                    "cache=prepared", "path=", tostring(path),
                    "items=", #prepared.table)
                self._zen_last_item_table_cache_result = {
                    cache = "prepared", elapsed_ms = (now() - started_at) * 1000,
                    items = #prepared.table,
                }
                return prepared.table, true
            end
        end
        local cached = get_cached(path, key)
        if cached then
            if collate_mode == "access" then
                cached.table = apply_history_order(self, cached.table, collate, reverse)
            end
            logger.measure("File list generated", (now() - started_at) * 1000,
                "cache=hit", "path=", tostring(path), "items=", #cached.table)
            self._zen_last_item_table_cache_result = {
                cache = "memory_hit", elapsed_ms = (now() - started_at) * 1000,
                items = #cached.table,
            }
            return cached.table, true
        end


        local disk_state
        cached, disk_state = get_persisted(self, path, key)
        if cached then
            if collate_mode == "access" then
                cached.table = apply_history_order(self, cached.table, collate, reverse)
            end
            put_cached(path, cached)
            logger.measure("File list generated", (now() - started_at) * 1000,
                "cache=disk_hit", "path=", tostring(path), "items=", #cached.table,
                "signature_mode=", tostring(cached.tree_signature_mode))
            self._zen_last_item_table_cache_result = {
                cache = "disk_hit", elapsed_ms = (now() - started_at) * 1000,
                items = #cached.table,
                signature_mode = cached.tree_signature_mode,
            }
            return cached.table, true
        end

        local stale = shared_cache.values[path]
        local last_read_file = rawget(_G, "__ZEN_UI_LAST_READ_FILE")
        if collate_mode == "access" and last_read_file
                and stale and stale.stable_key == stable
                and validate_children(stale) then
            local Home = SharedState.get(plugin, "home")
            if Home and type(Home.invalidateBookCache) == "function" then
                pcall(Home.invalidateBookCache, last_read_file, true)
            end
            _G.__ZEN_UI_LAST_READ_FILE = nil
            stale.table = apply_history_order(self, stale.table, collate, reverse)
            stale.key = key
            -- Not persisted: this runs on every reader return; disk hits re-apply history order.
            put_cached(path, stale)
            self._zen_last_item_table_cache_result = {
                cache = "history_reorder", elapsed_ms = (now() - started_at) * 1000,
                items = #stale.table,
            }
            return stale.table, true
        end

        self._zen_flat_view_directories = nil
        -- Read before the scan so a book list saved during it is noticed.
        local calibre = calibre_signatures(path)
        local scanned_at = os.time()
        local result, readable = original_genItemTableFromPath(self, path)
        -- KOReader >= 2026.10 reports unreadable dirs; never cache those
        if readable == false then
            self._zen_flat_view_directories = nil
            return result, false
        end
        if collate_mode == "access" then
            result = apply_history_order(self, result, collate, reverse)
        end
        local value = {
            key = key, stable_key = stable, table = result,
            scanned_at = scanned_at, scanned_until = os.time(),
            calibre_signatures = calibre,
        }
        local directories = self._zen_flat_view_directories
        self._zen_flat_view_directories = nil
        if directories and directories[path] then
            value.recursive = true
            value.child_directory_signatures = {}
            for dir, attributes in pairs(directories) do
                value.child_directory_signatures[dir] = attr_signature(attributes)
            end
        end
        put_cached(path, value)
        local persisted = put_persisted(self, path, value)
        logger.measure("File list generated", (now() - started_at) * 1000,
            "cache=miss", "prior=", disk_state, "path=", tostring(path),
            "items=", #result, "snapshot=", persisted and "queued" or "skipped")
        self._zen_last_item_table_cache_result = {
            cache = "miss", elapsed_ms = (now() - started_at) * 1000,
            items = #result,
        }
        return result, true
    end

    function FileChooser:_zen_warm_item_table(path)
        if self._dummy or self.name ~= "filemanager"
                or type(path) ~= "string" or path == "" then return nil end
        local deferred = rawget(_G, "__ZEN_UI_DEFER_FILEMANAGER_LISTING")
        if type(deferred) == "table" and deferred.path == path then
            return nil, { cache = "deferred", elapsed_ms = 0, items = 0 }
        end
        local started_at = now()
        local ok, result = pcall(self.genItemTableFromPath, self, path)
        local detail = self._zen_last_item_table_cache_result or {}
        detail.elapsed_ms = (now() - started_at) * 1000
        if not ok then
            detail.cache = "error"
            detail.error = tostring(result)
            logger.warn("Library snapshot warm failed", "path=", path, tostring(result))
            return nil, detail
        end
        detail.items = type(result) == "table" and #result or 0
        logger.measure("Library snapshot warmed", detail.elapsed_ms,
            "cache=", tostring(detail.cache), "path=", path, "items=", detail.items,
            "signature_mode=", tostring(detail.signature_mode or "none"))
        return result, detail
    end

    local function patch_coverbrowser(coverbrowser)
        if not coverbrowser or coverbrowser._zen_item_table_cache_invalidation then return end
        -- Stock CoverBrowser exposes onInvalidateMetadataCache(file); onBookInfoUpdated is legacy.
        local method = type(coverbrowser.onBookInfoUpdated) == "function" and "onBookInfoUpdated"
            or type(coverbrowser.onInvalidateMetadataCache) == "function" and "onInvalidateMetadataCache"
        if not method then return end
        coverbrowser._zen_item_table_cache_invalidation = true
        local original = coverbrowser[method]
        coverbrowser[method] = function(self, file, ...)
            local result = original(self, file, ...)
            local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
            local chooser = ok and FileManager.instance and FileManager.instance.file_chooser
            if G_reader_settings:readSetting("collate", "strcoll") ~= "access"
                    or status_filter_active(chooser or FileChooser) then
                local dir = type(file) == "string" and file:match("^(.*)/[^/]+$")
                if dir and dir ~= "" then
                    FileChooser._zen_invalidate_item_table_path(chooser or FileChooser, dir)
                else
                    FileChooser._zen_clear_item_table_cache(chooser or FileChooser)
                end
            else
                local FolderCover = package.loaded["modules/filebrowser/folder_cover"]
                if FolderCover and type(FolderCover.clear) == "function" then FolderCover.clear() end
            end
            return result
        end
    end

    local ok_userpatch, userpatch = pcall(require, "userpatch")
    if ok_userpatch and userpatch and type(userpatch.registerPatchPluginFunc) == "function" then
        userpatch.registerPatchPluginFunc("coverbrowser", patch_coverbrowser)
    else
        local ok_coverbrowser, coverbrowser = pcall(require, "coverbrowser")
        if ok_coverbrowser then patch_coverbrowser(coverbrowser) end
    end
end

return apply_browser_item_table_cache
