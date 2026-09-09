local M = {}

local METADATA_KEYS = {
    "title", "authors", "series", "series_index",
    "language", "keywords", "publisher", "description",
}

local SIDECAR_NAME = "custom_metadata.lua"
local SIDECAR_NEW_SUFFIX = ".zen-metadata.new"
local SIDECAR_OLD_SUFFIX = ".zen-metadata.old"

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$") or ""
end

local function list(value)
    local result = {}
    if type(value) == "table" then
        for _i, entry in ipairs(value) do
            entry = trim(entry)
            if entry ~= "" then result[#result + 1] = entry end
        end
    else
        value = tostring(value or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
        for entry in (value .. "\n"):gmatch("(.-)\n") do
            entry = trim(entry)
            if entry ~= "" then result[#result + 1] = entry end
        end
    end
    return result
end

local function copy_table(value)
    local result = {}
    if type(value) == "table" then
        for key, entry in pairs(value) do result[key] = entry end
    end
    return result
end

local function copy_metadata(value)
    local result = {}
    value = type(value) == "table" and value or {}
    for _i, key in ipairs(METADATA_KEYS) do result[key] = value[key] end
    result.pages = tonumber(value.pages)
    return result
end

local function same_list(left, right)
    if #left ~= #right then return false end
    for index, value in ipairs(left) do
        if value ~= right[index] then return false end
    end
    return true
end

function M.isEpub(file)
    return type(file) == "string" and file:lower():sub(-5) == ".epub"
end

function M.normalize(props)
    props = type(props) == "table" and props or {}
    local description = props.description
    local ok_util, util = pcall(require, "util")
    if description and ok_util and type(util.htmlToPlainTextIfHtml) == "function" then
        description = util.htmlToPlainTextIfHtml(description)
    end
    return {
        title = trim(props.title),
        authors = list(props.authors),
        series_name = trim(props.series_name or props.series),
        series_index = trim(props.series_index),
        genres = list(props.genres or props.keywords),
        language = trim(props.language),
        publisher = trim(props.publisher),
        description = trim(description),
        isbn = trim(props.isbn),
    }
end

local function serialized(draft)
    return {
        title = draft.title,
        authors = table.concat(draft.authors, "\n"),
        series = draft.series_name,
        series_index = draft.series_index,
        language = draft.language,
        keywords = table.concat(draft.genres, "\n"),
        publisher = draft.publisher,
        description = draft.description,
    }
end

local function changed_embedded_fields(embedded, desired, custom)
    local current = M.normalize(embedded)
    local changed = {}
    for _i, key in ipairs({ "title", "language", "publisher" }) do
        if desired[key] ~= current[key] then changed[key] = desired[key] end
    end
    local raw_custom = custom and custom.description
    local uses_custom_description = raw_custom ~= nil
        and M.normalize({ description = raw_custom }).description == desired.description
    if desired.description ~= current.description
            or (uses_custom_description
                and tostring(raw_custom) ~= tostring(embedded.description or "")) then
        if uses_custom_description then
            changed.description = raw_custom
        else
            changed.description = desired.description
        end
    end
    for _i, key in ipairs({ "authors", "genres" }) do
        if not same_list(desired[key], current[key]) then
            changed[key] = copy_table(desired[key])
        end
    end
    if desired.series_name ~= current.series_name
            or desired.series_index ~= current.series_index then
        changed.series_name = desired.series_name
        changed.series_index = desired.series_index
    end
    return changed
end

local function exists(path)
    return type(path) == "string"
        and require("libs/libkoreader-lfs").symlinkattributes(path) ~= nil
end

local function sync_directory(path)
    local ok, synced, err = pcall(require("ffi/util").fsyncDirectory, path)
    if not ok then return nil, synced end
    if synced ~= true then return nil, err or "could not sync metadata directory" end
    return true
end

local function make_path_durable(path)
    local ffiutil = require("ffi/util")
    local missing = {}
    local current = path
    while current and current ~= "" and not exists(current) do
        missing[#missing + 1] = current
        local parent = ffiutil.dirname(current)
        if parent == current then break end
        current = parent
    end
    local ok, err = require("util").makePath(path)
    if not ok then return nil, err end
    for index = #missing, 1, -1 do
        ok, err = sync_directory(ffiutil.dirname(missing[index]))
        if not ok then return nil, err end
    end
    return true
end

local function remove_file(path)
    if not exists(path) then return true end
    local ok, err = os.remove(path)
    return ok ~= nil, err
end

local function move_file(source, destination)
    local ok, err = os.rename(source, destination)
    if not ok then return nil, err end
    return true
end

function M.moveEpubBackup(from, to)
    if not M.isEpub(from) or not M.isEpub(to) then return true, false end
    local source = from .. ".zen-metadata.bak"
    local source_snapshot = source .. ".json"
    local destination = to .. ".zen-metadata.bak"
    local destination_snapshot = destination .. ".json"
    local has_backup = exists(source)
    local has_snapshot = exists(source_snapshot)
    if not has_backup and not has_snapshot then return true, false end
    if has_backup ~= has_snapshot then return nil, "EPUB metadata backup is incomplete" end
    if exists(destination) or exists(destination_snapshot) then
        return nil, "an EPUB metadata backup already exists for that filename"
    end

    local ok, err = move_file(source, destination)
    if not ok then return nil, err end
    ok, err = move_file(source_snapshot, destination_snapshot)
    if not ok then
        move_file(destination, source)
        return nil, err
    end
    ok, err = sync_directory(require("ffi/util").dirname(destination))
    if not ok then
        move_file(destination_snapshot, source_snapshot)
        move_file(destination, source)
        return nil, err
    end
    return true, true
end

local function recover_sidecar_target(target)
    local stage = target .. SIDECAR_NEW_SUFFIX
    local old = target .. SIDECAR_OLD_SUFFIX
    if exists(target) then
        local ok, err = remove_file(stage)
        if not ok then return nil, err end
        ok, err = remove_file(old)
        if not ok then return nil, err end
        return sync_directory(target)
    end
    if exists(old) then
        remove_file(stage)
        local ok, err = move_file(old, target)
        if not ok then return nil, err end
        return sync_directory(target)
    end
    return remove_file(stage)
end

local function sidecar_targets(file, settings)
    local targets = {}
    local function add(target)
        if type(target) ~= "string" or target == "" then return end
        for _i, existing in ipairs(targets) do
            if existing == target then return end
        end
        targets[#targets + 1] = target
    end
    add(settings.sidecar_file)
    for _i, directory in ipairs(settings:getCustomLocationCandidates(file) or {}) do
        add(directory .. "/" .. SIDECAR_NAME)
    end
    local DocSettings = require("docsettings")
    if type(DocSettings.getSidecarDir) == "function" then
        for _i, location in ipairs({ "doc", "dir", "hash" }) do
            local ok, directory = pcall(DocSettings.getSidecarDir,
                DocSettings, file, location)
            if ok and type(directory) == "string" and directory ~= "" then
                add(directory .. "/" .. SIDECAR_NAME)
            end
        end
    end
    return targets
end

local function recover_uncommitted_sidecar(file)
    local DocSettings = require("docsettings")
    local settings = DocSettings.openSettingsFile(
        DocSettings:findCustomMetadataFile(file))
    for _i, target in ipairs(sidecar_targets(file, settings)) do
        local ok, err = recover_sidecar_target(target)
        if not ok then return nil, err end
    end
    return true
end

local function refresh_hash_sidecar(file)
    local DocSettings = require("docsettings")
    if type(DocSettings.getSidecarStorage) ~= "function"
            or type(DocSettings.getSidecarDir) ~= "function" then
        return true
    end
    local hash = require("util").partialMD5(file)
    local storage = DocSettings.getSidecarStorage("hash")
    if type(hash) ~= "string" or type(storage) ~= "string" then
        return nil, "could not refresh hash sidecar location"
    end
    local expected = storage .. "/" .. hash:sub(1, 2) .. "/" .. hash .. ".sdr"
    if DocSettings:getSidecarDir(file, "hash") == expected then return true end

    local getter = DocSettings.getSidecarDir
    if type(debug.getupvalue) == "function" then
        local index = 1
        while true do
            local name, value = debug.getupvalue(getter, index)
            if not name then break end
            if name == "doc_hash_cache" and type(value) == "table" then
                value[file] = nil
                break
            end
            index = index + 1
        end
    end
    if DocSettings:getSidecarDir(file, "hash") ~= expected then
        return nil, "could not refresh hash sidecar location"
    end
    return true
end

local function write_checked_sidecar(stage, target, data)
    local dumped = require("dump")(data, nil, true)
    local content = "return " .. dumped .. "\n"
    local file, err = io.open(stage, "wb")
    if not file then return nil, err end
    local wrote, write_err = file:write(content)
    if not wrote then
        file:close()
        remove_file(stage)
        return nil, write_err
    end
    local flushed, flush_err = file:flush()
    local synced, sync_err
    if flushed then
        synced, sync_err = require("ffi/util").fsyncOpenedFile(file, true)
    end
    local closed, close_err = file:close()
    if flushed == nil or synced ~= true or closed == nil then
        remove_file(stage)
        return nil, flush_err or sync_err or close_err
    end
    local check = io.open(stage, "rb")
    local saved = check and check:read("*a")
    if check then check:close() end
    if saved ~= content then
        remove_file(stage)
        return nil, "short sidecar write"
    end
    local loader, load_err = loadfile(stage)
    local ok, decoded
    if loader then ok, decoded = pcall(loader) end
    if not loader or not ok or type(decoded) ~= "table" then
        remove_file(stage)
        return nil, load_err or decoded or "invalid sidecar"
    end
    return true
end

local function prepare_sidecar(file, settings, delete)
    local targets = sidecar_targets(file, settings)
    for _i, target in ipairs(targets) do
        local recovered, recover_err = recover_sidecar_target(target)
        if not recovered then return nil, recover_err end
        if delete then
            if exists(target) then
                return true, {
                    target = target,
                    stage = target .. SIDECAR_NEW_SUFFIX,
                    old = target .. SIDECAR_OLD_SUFFIX,
                    delete = true,
                    had_target = true,
                }
            end
            return true
        end

        local directory = require("ffi/util").dirname(target)
        local made, make_err = make_path_durable(directory)
        if made then
            local stage = target .. SIDECAR_NEW_SUFFIX
            local wrote, write_err = write_checked_sidecar(stage, target, settings.data)
            if wrote then wrote, write_err = sync_directory(directory) end
            if wrote then
                return true, {
                    target = target,
                    stage = stage,
                    old = target .. SIDECAR_OLD_SUFFIX,
                    delete = false,
                    had_target = exists(target),
                }
            end
            make_err = write_err
        end
        if _i == #targets then return nil, make_err end
    end
    return nil, "no sidecar location"
end

local function discard_sidecar(update)
    if type(update) == "table" then remove_file(update.stage) end
end

local function commit_sidecar(update)
    if not update then return true end
    local directory = require("ffi/util").dirname(update.target)
    if update.delete then
        local moved, err = move_file(update.target, update.old)
        if not moved then return nil, err end
        local synced, sync_err = sync_directory(directory)
        if not synced then
            move_file(update.old, update.target)
            sync_directory(directory)
            return nil, sync_err
        end
        local removed, remove_err = remove_file(update.old)
        if not removed then return nil, remove_err end
        return sync_directory(directory)
    end
    if update.had_target then
        local moved, err = move_file(update.target, update.old)
        if not moved then return nil, err end
        local synced, sync_err = sync_directory(directory)
        if not synced then
            move_file(update.old, update.target)
            sync_directory(directory)
            return nil, sync_err
        end
    end
    local moved, err = move_file(update.stage, update.target)
    if not moved then
        if update.had_target then move_file(update.old, update.target) end
        sync_directory(directory)
        return nil, err
    end
    local synced, sync_err = sync_directory(update.target)
    if not synced then
        remove_file(update.target)
        if update.had_target then move_file(update.old, update.target) end
        sync_directory(directory)
        return nil, sync_err
    end
    local removed, remove_err = remove_file(update.old)
    if not removed then return nil, remove_err end
    return sync_directory(update.target)
end

local function custom_state(file)
    local DocSettings = require("docsettings")
    local path = DocSettings:findCustomMetadataFile(file)
    if not path then return nil, {}, {} end
    local settings = DocSettings.openSettingsFile(path)
    return settings,
        copy_table(settings:readSetting("custom_props", {})),
        copy_table(settings:readSetting("doc_props", {}))
end

local function load_original(file)
    local original = select(3, custom_state(file))
    if next(original) ~= nil then return original end

    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if ok_bim and BookInfoManager and type(BookInfoManager.getBookInfo) == "function" then
        local ok, props = pcall(BookInfoManager.getBookInfo, BookInfoManager, file, false)
        if ok and type(props) == "table" and not props.ignore_meta then
            return copy_metadata(props)
        end
    end

    local BookInfo = require("apps/filemanager/filemanagerbookinfo")
    local fake = { ui = {} }
    setmetatable(fake, { __index = BookInfo })
    local ok, props = pcall(fake.getDocProps, fake, file)
    return ok and type(props) == "table" and copy_metadata(props) or {}
end

local function merged_props(original, custom)
    local result = copy_table(original)
    for _i, key in ipairs(METADATA_KEYS) do
        if custom[key] ~= nil then result[key] = custom[key] end
    end
    return result
end

local function current_reader_file()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local ui = ok and ReaderUI and ReaderUI.instance
    return ui and ui.document and ui.document.file
end

local function is_current_reader_file(file)
    local current = current_reader_file()
    if current == file then return true end
    if type(current) ~= "string" or type(file) ~= "string" then return false end
    local ffiutil = require("ffi/util")
    current, file = ffiutil.realpath(current), ffiutil.realpath(file)
    if not current or not file then return false end
    if package.config:sub(1, 1) == "\\" then
        current, file = current:lower(), file:lower()
    end
    return current == file
end

function M.load(file)
    local lfs = require("libs/libkoreader-lfs")
    if type(file) ~= "string" or lfs.attributes(file, "mode") ~= "file" then
        return nil, "invalid_file"
    end
    if is_current_reader_file(file) then return nil, "open_book" end

    local original
    if M.isEpub(file) then
        local props, err = require("modules/filebrowser/metadata/epub").read(file)
        if not props then return nil, err or "invalid_epub" end
        local cache_ok, cache_err = refresh_hash_sidecar(file)
        if not cache_ok then return nil, cache_err end
        local recovered, recover_err = recover_uncommitted_sidecar(file)
        if not recovered then return nil, recover_err or "sidecar_write_failed" end
        original = props
    else
        local recovered, recover_err = recover_uncommitted_sidecar(file)
        if not recovered then return nil, recover_err or "sidecar_write_failed" end
        original = load_original(file)
    end
    local custom = select(2, custom_state(file))
    return M.normalize(merged_props(original, custom))
end

function M.validate(file, draft)
    draft = M.normalize(draft)
    if draft.series_index ~= "" then
        local index = tonumber(draft.series_index)
        if not index or index ~= index or index == math.huge or index == -math.huge then
            return nil, "invalid_series_index"
        end
    end
    if M.isEpub(file) then
        if draft.title == "" then return nil, "missing_title" end
        if draft.language == "" then return nil, "missing_language" end
    end
    return draft
end

local function prepare_custom(file, original, desired, restored_snapshot)
    local DocSettings = require("docsettings")
    local settings, custom = custom_state(file)
    settings = settings or DocSettings.openSettingsFile()
    original = copy_table(original)
    desired = desired or {}

    if restored_snapshot then
        local snapshot_props = restored_snapshot.props or {}
        for _i, key in ipairs(METADATA_KEYS) do
            local entry = snapshot_props[key]
            custom[key] = type(entry) == "table" and entry.present and entry.value or nil
        end
        if type(restored_snapshot.doc_props) == "table" then
            original = copy_table(restored_snapshot.doc_props)
        end
    else
        for _i, key in ipairs(METADATA_KEYS) do
            local wanted = desired[key]
            local base = original[key]
            if tostring(wanted or "") == tostring(base or "") then
                custom[key] = nil
            else
                custom[key] = wanted
            end
        end
    end

    if next(custom) == nil then
        local unrelated
        for key in pairs(settings.data or {}) do
            if key ~= "custom_props" and key ~= "doc_props" then unrelated = true break end
        end
        if not unrelated then return prepare_sidecar(file, settings, true) end
    end
    settings:saveSetting("doc_props", original)
    settings:saveSetting("custom_props", custom)
    local ok, update_or_err = prepare_sidecar(file, settings, false)
    if ok then return true, update_or_err end
    return nil, update_or_err or "sidecar_write_failed"
end

local function sidecar_snapshot(file, embedded)
    local custom, original = select(2, custom_state(file))
    local snapshot = { version = 1, props = {}, doc_props = next(original) and original or embedded }
    for _i, key in ipairs(METADATA_KEYS) do
        snapshot.props[key] = {
            present = custom[key] ~= nil,
            value = custom[key],
        }
    end
    return snapshot
end

local function prepare_clear_embedded_overrides(file, embedded)
    local settings, custom, original = custom_state(file)
    if not settings then return true end
    for _i, key in ipairs(METADATA_KEYS) do custom[key] = nil end
    if next(custom) == nil then
        local unrelated
        for key in pairs(settings.data or {}) do
            if key ~= "custom_props" and key ~= "doc_props" then unrelated = true break end
        end
        if not unrelated then return prepare_sidecar(file, settings, true) end
    end
    local updated_original = copy_table(original)
    for _i, key in ipairs(METADATA_KEYS) do
        updated_original[key] = embedded[key]
    end
    settings:saveSetting("doc_props", updated_original)
    settings:saveSetting("custom_props", custom)
    local ok, update_or_err = prepare_sidecar(file, settings, false)
    if ok then return true, update_or_err end
    return nil, update_or_err or "sidecar_write_failed"
end

function M.save(file, draft, options)
    options = options or {}
    local valid, err = M.validate(file, draft)
    if not valid then return nil, err end
    if is_current_reader_file(file) then return nil, "open_book" end

    if M.isEpub(file) then
        local Epub = require("modules/filebrowser/metadata/epub")
        local embedded, read_err = Epub.read(file)
        if not embedded then return nil, read_err end
        local cache_ok, cache_err = refresh_hash_sidecar(file)
        if not cache_ok then return nil, cache_err end
        local recovered, recover_err = recover_uncommitted_sidecar(file)
        if not recovered then return nil, recover_err or "sidecar_write_failed" end
        local custom = select(2, custom_state(file))
        local snapshot = sidecar_snapshot(file, embedded)
        local embedded_draft = changed_embedded_fields(embedded, valid, custom)
        local prepared_update
        local ok, write_err = Epub.write(file, embedded_draft, {
            keep_backup = options.keep_backup,
            sidecar_snapshot = snapshot,
            prepare_sidecar = function(updated)
                local prepared, update_or_err = prepare_clear_embedded_overrides(
                    file, serialized(updated))
                if prepared then prepared_update = update_or_err end
                return prepared, update_or_err
            end,
        })
        cache_ok, cache_err = refresh_hash_sidecar(file)
        if not ok then
            discard_sidecar(prepared_update)
            return nil, write_err
        end
        if not cache_ok then return nil, cache_err end
    else
        local recovered, recover_err = recover_uncommitted_sidecar(file)
        if not recovered then return nil, recover_err or "sidecar_write_failed" end
        local original = load_original(file)
        local prepared, update_or_err = prepare_custom(file, original, serialized(valid))
        if not prepared then return nil, update_or_err end
        local ok, write_err = commit_sidecar(update_or_err)
        if not ok then return nil, write_err or "sidecar_write_failed" end
    end
    M.invalidate(file, serialized(valid))
    return true
end

function M.canRestore(file)
    if not M.isEpub(file) then return false end
    local available, err = require("modules/filebrowser/metadata/epub").canRestore(file)
    local cache_ok, cache_err = refresh_hash_sidecar(file)
    if not cache_ok then return false, cache_err end
    return available == true, err
end

function M.restore(file)
    if is_current_reader_file(file) then return nil, "open_book" end
    local Epub = require("modules/filebrowser/metadata/epub")
    local current, read_err = Epub.read(file)
    if not current then return nil, read_err end
    local cache_ok, cache_err = refresh_hash_sidecar(file)
    if not cache_ok then return nil, cache_err end
    local recovered, recover_err = recover_uncommitted_sidecar(file)
    if not recovered then return nil, recover_err or "sidecar_write_failed" end
    local prepared_update
    local snapshot, err = Epub.restore(file, {
        sidecar_snapshot = sidecar_snapshot(file, current),
        prepare_sidecar = function(embedded, restored_snapshot)
            local prepared, update_or_err = prepare_custom(
                file, embedded, nil, restored_snapshot)
            if prepared then prepared_update = update_or_err end
            return prepared, update_or_err
        end,
    })
    cache_ok, cache_err = refresh_hash_sidecar(file)
    if snapshot == nil and err then
        discard_sidecar(prepared_update)
        return nil, err
    end
    if not cache_ok then return nil, cache_err end
    M.invalidate(file)
    return true
end

function M.invalidate(file, props)
    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    local updated = false
    if ok_bim and type(props) == "table"
            and type(BookInfoManager.getBookInfo) == "function"
            and type(BookInfoManager.setBookInfoProperties) == "function" then
        local cached = {}
        for _i, key in ipairs(METADATA_KEYS) do
            if key ~= "publisher" then cached[key] = props[key] end
        end
        cached.has_meta = "Y"
        cached.ignore_meta = false
        local ok_info, info = pcall(BookInfoManager.getBookInfo,
            BookInfoManager, file, false)
        if ok_info and not info
                and type(BookInfoManager.extractBookInfo) == "function" then
            pcall(BookInfoManager.extractBookInfo, BookInfoManager, file)
        end
        if pcall(BookInfoManager.setBookInfoProperties,
                BookInfoManager, file, cached) then
            ok_info, info = pcall(BookInfoManager.getBookInfo,
                BookInfoManager, file, false)
            updated = ok_info and type(info) == "table" and not info.ignore_meta
                and info.has_meta == "Y"
            if updated then
                for _i, key in ipairs(METADATA_KEYS) do
                    if key ~= "publisher"
                            and tostring(info[key] or "") ~= tostring(cached[key] or "") then
                        updated = false
                        break
                    end
                end
            end
        end
    end
    if ok_bim and not updated and type(BookInfoManager.deleteBookInfo) == "function" then
        pcall(BookInfoManager.deleteBookInfo, BookInfoManager, file)
    end
    local ok_event, Event = pcall(require, "ui/event")
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if ok_event and ok_ui then
        if not updated then
            UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", file))
        end
        UIManager:broadcastEvent(Event:new("BookMetadataChanged"))
    end
end

function M.refreshLibrary(file_manager, file)
    local chooser = file_manager and file_manager.file_chooser
    if not chooser then return end
    if file then
        local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
        if ok_bim and BookInfoManager
                and type(BookInfoManager.getBookInfo) == "function" then
            local ok_info, info = pcall(BookInfoManager.getBookInfo,
                BookInfoManager, file, false)
            if ok_info and not info
                    and type(BookInfoManager.extractBookInfo) == "function" then
                local height = math.floor(require("device").screen:getHeight() * 0.30)
                pcall(BookInfoManager.extractBookInfo, BookInfoManager, file, {
                    max_cover_w = math.floor(height
                        * require("common/cover_utils").getRatio()),
                    max_cover_h = height,
                })
            end
        end
    end
    if type(chooser._zen_clear_item_table_cache) == "function" then
        chooser:_zen_clear_item_table_cache()
    end
    if chooser.path and type(chooser.changeToPath) == "function" then
        chooser:changeToPath(chooser.path)
    elseif type(chooser.updateItems) == "function" then
        chooser:updateItems()
    end
end

return M
