local M = {}

local zen_logger = require("common/zen_logger")
local logger = zen_logger.new("book_status")
local now = zen_logger.now

local LEGACY_NEW_MTIME_KEY = "zen_auto_tbr_mtime"
local NEW_MTIME_KEY = "zen_new_mtime"
local STATUS_CACHE_MAX = 2048
local STATUS_VALIDATE_TTL_S = 5
local status_cache = {}
local status_cache_size = 0
local status_cache_tick = 0
local primed_path
local cache_metrics = {
    lookups = 0,
    ttl_hits = 0,
    validated_hits = 0,
    misses = 0,
    stale = 0,
}

local function copy_status_data(data)
    local copy = {}
    for key, value in pairs(data or {}) do copy[key] = value end
    return copy
end

-- Read-only stand-in for cached hits: only the page/progress keys callers read.
local SNAPSHOT_KEYS = {
    "percent_finished", "partial_md5_checksum", "doc_pages", "pagemap_use_page_labels",
    "pagemap_doc_pages", "pagemap_current_page_label", "pagemap_last_page_label",
}
local snapshot_mt = { __index = { readSetting = function(self, key) return rawget(self, key) end } }

local function sidecar_snapshot(doc)
    local snapshot = {}
    for _i, key in ipairs(SNAPSHOT_KEYS) do snapshot[key] = doc:readSetting(key) end
    local summary, stats = doc:readSetting("summary"), doc:readSetting("stats")
    if type(summary) == "table" then snapshot.summary = { status = summary.status } end
    if type(stats) == "table" then snapshot.stats = { pages = stats.pages } end
    return setmetatable(snapshot, snapshot_mt)
end

-- Cached entries hold scalars only; full DocSettings/BookList refs are never retained.
local function cacheable_status_data(data)
    local book_info = data.book_info
    return {
        status = data.status,
        percent_finished = data.percent_finished,
        effective_status = data.effective_status,
        sidecar_checked = data.sidecar_checked,
        doc_settings = data.doc_settings and sidecar_snapshot(data.doc_settings) or nil,
        book_info = type(book_info) == "table" and { pages = book_info.pages } or nil,
    }
end

local function remove_cached_status(file_path)
    if status_cache[file_path] then status_cache_size = status_cache_size - 1 end
    status_cache[file_path] = nil
end

local function status_signature(DocSettings, file_path)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return nil end
    local file_mtime = lfs.attributes(file_path, "modification")
    if type(DocSettings.findSidecarFile) ~= "function" then
        return nil, lfs, file_mtime
    end
    local ok_sidecar, sidecar_file = pcall(DocSettings.findSidecarFile, DocSettings, file_path)
    if not ok_sidecar or not sidecar_file then
        return nil, lfs, file_mtime, nil, false
    end
    local sidecar_mtime = lfs.attributes(sidecar_file, "modification")
    if file_mtime == nil or sidecar_mtime == nil then
        return nil, lfs, file_mtime, sidecar_mtime, true
    end
    return table.concat({ "sidecar", tostring(file_mtime), tostring(sidecar_mtime) }, "|"),
        lfs, file_mtime, sidecar_mtime, true
end

local function fallback_signature(file_path, lfs, file_mtime)
    if not lfs then
        local ok_lfs
        ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if not ok_lfs then return nil end
    end
    if file_mtime == nil then file_mtime = lfs.attributes(file_path, "modification") end
    if file_mtime == nil then return nil end
    return "fallback|" .. tostring(file_mtime)
end

-- Book sources (common/book_sources) can give the status of books without
-- a sidecar here, e.g. a cloud book read on another device. Only asked once
-- something has loaded the module (the file browser does at startup).
local function book_sources()
    local BookSources = package.loaded["common/book_sources"]
    return type(BookSources) == "table" and BookSources or nil
end

local function sources_revision()
    local BookSources = book_sources()
    local fn = BookSources and (BookSources.statusRevision or BookSources.revision)
    if type(fn) ~= "function" then return 0 end
    local ok, revision = pcall(fn)
    return ok and tonumber(revision) or 0
end

local function source_status(file_path)
    local BookSources = book_sources()
    if not (BookSources and type(BookSources.status) == "function") then return nil end
    local ok, status = pcall(BookSources.status, file_path)
    return ok and type(status) == "table" and status or nil
end

local function touch_status(cached, validated_at)
    status_cache_tick = status_cache_tick + 1
    cached.last_used = status_cache_tick
    if validated_at then cached.validated_at = validated_at end
end

-- One sweep drops entries outside the newest 3/4 of ticks: amortized O(1) per insert.
local function evict_status_if_needed()
    if status_cache_size <= STATUS_CACHE_MAX then return end
    local keep_after = status_cache_tick - math.floor(STATUS_CACHE_MAX * 3 / 4)
    for path, cached in pairs(status_cache) do
        if cached.last_used <= keep_after then remove_cached_status(path) end
    end
end

local status_revision = 0 -- bumps when a known status changes or is invalidated

local function display_key()
    local TBRIndex = package.loaded["common/tbr_index"]
    local revision = type(TBRIndex) == "table" and type(TBRIndex.peekRevision) == "function"
        and TBRIndex.peekRevision() or 0
    return (M.includeNewInTBREnabled() and "new|" or "|") .. tostring(revision)
end

-- source_revision: the book sources' revision the entry depends on (entries
-- for books without a sidecar), checked by TTL hits too.
local function remember_status(file_path, signature, data, source, validated_at, source_revision)
    if not signature then return end
    local cached = status_cache[file_path]
    if not cached then status_cache_size = status_cache_size + 1
    elseif cached.data.effective_status ~= data.effective_status then
        status_revision = status_revision + 1
    end
    cached = {
        signature = signature,
        data = cacheable_status_data(data),
        source = source,
        validated_at = validated_at or now(),
        display_status = data.display_status,
        display_key = display_key(),
        source_revision = source_revision,
    }
    touch_status(cached)
    status_cache[file_path] = cached
    evict_status_if_needed()
end

-- TTL hits reuse the display status while the TBR revision and setting are unchanged;
-- validated hits recompute it so external collection edits surface within the TTL.
local function cached_status_result(file_path, cached, reuse_display)
    local key = display_key()
    if not reuse_display or cached.display_key ~= key or cached.display_status == nil then
        cached.display_status = M.getDisplayStatus(file_path, cached.data.effective_status)
        cached.display_key = key
    end
    local data = copy_status_data(cached.data)
    data.display_status = cached.display_status
    return data
end

local function get_fresh_cached_status(file_path, checked_at, allow_booklist)
    local cached = status_cache[file_path]
    -- With fallback_info, booklist and book_source entries are rebuilt so the
    -- caller's table is returned as book_info.
    if not cached or (cached.source ~= "sidecar" and not allow_booklist)
            or checked_at - cached.validated_at >= STATUS_VALIDATE_TTL_S then return nil end
    if cached.source_revision and cached.source_revision ~= sources_revision() then return nil end
    touch_status(cached)
    return cached_status_result(file_path, cached, true)
end

local function get_validated_cached_status(file_path, signature, checked_at)
    local cached = signature and status_cache[file_path]
    if not cached then return nil, "miss" end
    if cached.signature ~= signature then
        remove_cached_status(file_path)
        return nil, "stale"
    end
    touch_status(cached, checked_at)
    return cached_status_result(file_path, cached, false), "validated_hit"
end

local function record_cache_result(result, started_at, file_path)
    cache_metrics.lookups = cache_metrics.lookups + 1
    if result == "ttl_hit" then
        cache_metrics.ttl_hits = cache_metrics.ttl_hits + 1
    elseif result == "validated_hit" then
        cache_metrics.validated_hits = cache_metrics.validated_hits + 1
    elseif result == "stale" then
        cache_metrics.stale = cache_metrics.stale + 1
    else
        cache_metrics.misses = cache_metrics.misses + 1
    end
    if result == "stale" or cache_metrics.lookups % 16 == 0 then
        logger.measure("Book status cache", (now() - started_at) * 1000,
            "cache=", result, "path=", tostring(file_path),
            "lookups=", cache_metrics.lookups,
            "ttl_hits=", cache_metrics.ttl_hits,
            "validated_hits=", cache_metrics.validated_hits,
            "misses=", cache_metrics.misses, "stale=", cache_metrics.stale)
    end
end

function M.invalidate(file_path)
    if type(file_path) == "string" and file_path ~= "" then
        remove_cached_status(file_path)
        if primed_path == file_path then primed_path = nil end
        status_revision = status_revision + 1
    end
end

-- Also changes when a book source reports a change (its statuses may have).
function M.revision()
    return status_revision + sources_revision()
end

function M.clearCache()
    status_revision = status_revision + 1
    status_cache = {}
    status_cache_size = 0
    status_cache_tick = 0
    primed_path = nil
    cache_metrics = {
        lookups = 0,
        ttl_hits = 0,
        validated_hits = 0,
        misses = 0,
        stale = 0,
    }
end

local function is_explicit_status(status)
    return status == "reading" or status == "complete" or status == "abandoned"
end

function M.isNewStatus(status, percent_finished)
    return percent_finished == nil and not is_explicit_status(status)
end

function M.getEffectiveStatus(status, percent_finished)
    if is_explicit_status(status) then
        return status
    end
    if M.isNewStatus(status, percent_finished) then
        return "new"
    end
    return "reading"
end

function M.includeNewInTBREnabled()
    local ok, ConfigManager = pcall(require, "config/manager")
    if not ok then return false end
    local cfg = ConfigManager.get()
    return cfg and cfg.group_view
        and cfg.group_view.include_new_in_tbr == true
end

function M.fileUpdatesAsNewEnabled()
    local ok, ConfigManager = pcall(require, "config/manager")
    if not ok then return false end
    local cfg = ConfigManager.get()
    return cfg and cfg.group_view and cfg.group_view.file_updates_as_new == true or false
end

function M.getDisplayStatus(file_path, effective_status)
    if effective_status == "new" and M.includeNewInTBREnabled() then
        return "tbr"
    end
    if type(file_path) ~= "string" or file_path == "" then return effective_status end

    local ok, TBRIndex = pcall(require, "common/tbr_index")
    if ok and type(TBRIndex.isExplicit) == "function"
            and TBRIndex.isExplicit(file_path) then
        return "tbr"
    end
    return effective_status
end

local IMAGE_EXTS = {
    jpg = true, jpeg = true, png = true, gif = true, bmp = true,
    tiff = true, tif = true, webp = true, svg = true, ico = true,
    heic = true, heif = true, avif = true,
}

function M.isImageFile(file_path)
    if not file_path then return false end
    local ext = file_path:match("^.+%.([^%.]+)$")
    if not ext then return false end
    return IMAGE_EXTS[ext:lower()] == true
end

local function flushDocSettings(doc_settings)
    if type(doc_settings.flush) == "function" then
        pcall(doc_settings.flush, doc_settings)
    end
end

local function getSidecarMtime(DocSettings, file_path, lfs)
    if type(DocSettings.findSidecarFile) ~= "function" then return nil end
    local ok, sidecar_file = pcall(DocSettings.findSidecarFile, DocSettings, file_path)
    if not ok or not sidecar_file then return nil end
    return lfs.attributes(sidecar_file, "modification")
end

local function getFileContext(file_path, doc_settings, known_context)
    if not file_path or M.isImageFile(file_path) then return end
    local lfs = known_context and known_context.lfs
    if not lfs then
        local ok_lfs
        ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if not ok_lfs then return end
    end
    local current_mtime = known_context and known_context.file_mtime
    if current_mtime == nil then
        local attr = lfs.attributes(file_path)
        if not attr or attr.mode ~= "file" then return end
        current_mtime = attr.modification
    end

    local DocSettings = known_context and known_context.DocSettings
    if not DocSettings then
        local ok_ds
        ok_ds, DocSettings = pcall(require, "docsettings")
        if not ok_ds or not DocSettings then return end
    end
    if not doc_settings then
        if not DocSettings:hasSidecarFile(file_path) then return end
        local ok_doc, doc = pcall(DocSettings.open, DocSettings, file_path)
        if not ok_doc or not doc then return end
        doc_settings = doc
    end
    return lfs, DocSettings, doc_settings, current_mtime
end

local function get_computed_status(file_path, status, percent_finished, doc_settings, context)
    local effective_status = M.getEffectiveStatus(status, percent_finished)
    if effective_status == "new" or M.isImageFile(file_path)
            or not M.fileUpdatesAsNewEnabled() then
        return effective_status
    end

    local lfs, DocSettings, doc, current_mtime = getFileContext(
        file_path, doc_settings, context)
    if not doc or current_mtime == nil then return effective_status end

    -- NEW_MTIME_KEY stores the file mtime that was last acknowledged (i.e. the
    -- content the user has already seen). The book is "new" when the file has
    -- changed since then. Pure read: acknowledgment is what writes the marker.
    local acked_mtime = tonumber(doc:readSetting(NEW_MTIME_KEY))
    if acked_mtime ~= nil then
        if current_mtime > acked_mtime then
            return "new"
        end
        return effective_status
    end

    -- No acknowledgment yet: first-time detection compares against the sidecar.
    local sidecar_mtime = context and context.sidecar_mtime
        or getSidecarMtime(DocSettings, file_path, lfs)
    if sidecar_mtime ~= nil and current_mtime > sidecar_mtime then
        return "new"
    end
    return effective_status
end

function M.getComputedStatus(file_path, status, percent_finished, doc_settings)
    return get_computed_status(file_path, status, percent_finished, doc_settings)
end

function M.acknowledgeNewVersion(doc_settings)
    if not doc_settings then return false end

    -- Record the current file mtime as the acknowledged version. Detection then
    -- only re-flags "new" when the file changes again (see getComputedStatus).
    local file_path = doc_settings.data and doc_settings.data.doc_path
    local current_mtime
    if file_path then
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if ok_lfs then
            current_mtime = lfs.attributes(file_path, "modification")
        end
    end

    local prev_acked = tonumber(doc_settings:readSetting(NEW_MTIME_KEY))
    local had_legacy = doc_settings:readSetting(LEGACY_NEW_MTIME_KEY) ~= nil
    if had_legacy then
        doc_settings:delSetting(LEGACY_NEW_MTIME_KEY)
    end

    if current_mtime == nil then
        -- Can't stat the file: fall back to clearing so we don't get stuck.
        local changed = prev_acked ~= nil or had_legacy
        if prev_acked ~= nil then
            doc_settings:delSetting(NEW_MTIME_KEY)
        end
        if changed then M.invalidate(file_path) end
        return changed
    end

    doc_settings:saveSetting(NEW_MTIME_KEY, current_mtime)
    local changed = prev_acked ~= current_mtime or had_legacy
    if changed then M.invalidate(file_path) end
    return changed
end

function M.migrateLegacyMarker(file_path, status, doc_settings)
    if not doc_settings then return status, false end
    local legacy_mtime = tonumber(doc_settings:readSetting(LEGACY_NEW_MTIME_KEY))
    if legacy_mtime == nil then return status, false end

    -- Legacy marker meant "flagged new/updated". Under the new scheme detection
    -- re-derives newness from the sidecar mtime, so we only drop the legacy key
    -- (writing NEW_MTIME_KEY now would record the version as *acknowledged*).
    local summary_changed = status == "abandoned"
    doc_settings:delSetting(LEGACY_NEW_MTIME_KEY)
    M.invalidate(file_path)

    if summary_changed then
        local summary = doc_settings:readSetting("summary") or {}
        summary.status = nil
        require("apps/filemanager/filemanagerutil").saveSummary(doc_settings, summary)
        require("ui/widget/booklist").setBookInfoCacheProperty(file_path, "status", nil)
        return nil, true
    end

    flushDocSettings(doc_settings)
    return status, true
end

function M.getEffectiveStatusFromInfo(book_info)
    if type(book_info) ~= "table" then
        return "new"
    end
    return M.getEffectiveStatus(book_info.status, book_info.percent_finished)
end

local function getBookListInfo(file_path)
    local ok_bl, BookList = pcall(require, "ui/widget/booklist")
    if ok_bl and type(BookList) == "table" and type(BookList.getBookInfo) == "function" then
        local ok_info, book_info = pcall(BookList.getBookInfo, file_path)
        if ok_info then return book_info end
    end
end

local function sidecar_status_data(file_path, doc, context)
    local summary = doc:readSetting("summary")
    local status = summary and summary.status
    local percent_finished = doc:readSetting("percent_finished")
    local effective_status = get_computed_status(
        file_path, status, percent_finished, doc, context)
    return {
        status = status,
        percent_finished = percent_finished,
        effective_status = effective_status,
        display_status = M.getDisplayStatus(file_path, effective_status),
        doc_settings = doc,
        sidecar_checked = true,
    }
end

-- Caches a just-flushed in-memory sidecar (e.g. on reader close) so later lookups skip the parse.
function M.prime(file_path, doc_settings)
    if type(file_path) ~= "string" or file_path == "" or not doc_settings then return false end
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not ok_ds or not DocSettings then return false end
    local signature, lfs, file_mtime, sidecar_mtime, has_sidecar =
        status_signature(DocSettings, file_path)
    M.invalidate(file_path)
    if not (signature and has_sidecar) then return false end
    remember_status(file_path, signature, sidecar_status_data(file_path, doc_settings, {
        lfs = lfs,
        DocSettings = DocSettings,
        file_mtime = file_mtime,
        sidecar_mtime = sidecar_mtime,
    }), "sidecar", now())
    primed_path = file_path
    return true
end

-- True once if file_path was primed since the last call.
function M.takePrimed(file_path)
    if primed_path == nil or primed_path ~= file_path then return false end
    primed_path = nil
    return status_cache[file_path] ~= nil
end

-- Read status metadata from one authoritative source. A sidecar, when present
-- and readable, wins; BookList is only consulted as the fallback path.
function M.getFileStatusData(file_path, fallback_info)
    local started_at = now()
    local checked_at = started_at
    local cached = get_fresh_cached_status(file_path, checked_at, fallback_info == nil)
    if cached then
        record_cache_result("ttl_hit", started_at, file_path)
        return cached
    end

    local ok_ds, DocSettings = pcall(require, "docsettings")
    local signature, lfs, file_mtime, sidecar_mtime, has_sidecar
    if ok_ds and DocSettings then
        signature, lfs, file_mtime, sidecar_mtime, has_sidecar =
            status_signature(DocSettings, file_path)
        if has_sidecar == nil and type(DocSettings.hasSidecarFile) == "function" then
            local ok_sidecar, found = pcall(
                DocSettings.hasSidecarFile, DocSettings, file_path)
            has_sidecar = ok_sidecar and not not found
        end
    end
    if has_sidecar then
        local cache_state
        if signature then
            cached, cache_state = get_validated_cached_status(
                file_path, signature, checked_at)
        end
        if cached then
            record_cache_result(cache_state, started_at, file_path)
            return cached
        end
        local ok_doc, doc = pcall(DocSettings.open, DocSettings, file_path)
        if ok_doc and doc then
            local data = sidecar_status_data(file_path, doc, {
                lfs = lfs,
                DocSettings = DocSettings,
                file_mtime = file_mtime,
                sidecar_mtime = sidecar_mtime,
            })
            remember_status(file_path, signature, data, "sidecar", checked_at)
            record_cache_result(cache_state == "stale" and "stale" or "miss",
                started_at, file_path)
            return data
        end
    end

    -- No sidecar: a book source may know the status (read-only; the sidecar
    -- wins once there is one). Entries depend on the sources' revision.
    local source_revision = sources_revision()
    local source_key = table.concat({
        "source", tostring(source_revision), tostring(file_mtime) }, "|")
    local cache_state
    local existing = status_cache[file_path]
    if existing and existing.source == "book_source" and fallback_info == nil then
        cached, cache_state = get_validated_cached_status(file_path, source_key, checked_at)
        if cached then
            record_cache_result(cache_state, started_at, file_path)
            return cached
        end
    end
    local from_source = source_status(file_path)
    if from_source then
        local effective_status = M.getEffectiveStatus(
            from_source.status, from_source.percent_finished)
        local data = {
            status = from_source.status,
            percent_finished = from_source.percent_finished,
            effective_status = effective_status,
            display_status = M.getDisplayStatus(file_path, effective_status),
            book_info = type(fallback_info) == "table" and fallback_info or nil,
            sidecar_checked = true,
        }
        remember_status(file_path, source_key, data, "book_source", checked_at, source_revision)
        record_cache_result(cache_state == "stale" and "stale" or "miss",
            started_at, file_path)
        return data
    end

    local fallback_key = fallback_info == nil
        and fallback_signature(file_path, lfs, file_mtime) or nil
    if fallback_key then
        fallback_key = fallback_key .. "|" .. tostring(source_revision)
        cached, cache_state = get_validated_cached_status(
            file_path, fallback_key, checked_at)
        if cached then
            record_cache_result(cache_state, started_at, file_path)
            return cached
        end
    end

    local book_info = type(fallback_info) == "table" and fallback_info
        or getBookListInfo(file_path)
    local status = book_info and book_info.status
    local percent_finished = book_info and book_info.percent_finished
    local effective_status = M.getEffectiveStatus(status, percent_finished)
    local data = {
        status = status,
        percent_finished = percent_finished,
        effective_status = effective_status,
        display_status = M.getDisplayStatus(file_path, effective_status),
        book_info = book_info,
        sidecar_checked = true,
    }
    if fallback_key then
        remember_status(file_path, fallback_key, data, "booklist", checked_at, source_revision)
    end
    record_cache_result(cache_state == "stale" and "stale" or "miss",
        started_at, file_path)
    return data
end

function M.getEffectiveStatusFromFile(file_path)
    return M.getFileStatusData(file_path).effective_status
end

function M.getDisplayStatusFromFile(file_path)
    return M.getFileStatusData(file_path).display_status
end

return M
