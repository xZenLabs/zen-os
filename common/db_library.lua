-- common/db_library.lua
-- Determines book completion status from KOReader's actual library state.
--
-- KOReader stores book status ("reading", "complete", "abandoned") in per-book
-- sidecar directories (.sdr/), NOT in any SQL database.  The correct way to
-- query this is:
--   ReadHistory  →  gives all historically opened books (file paths)
--   DocSettings  →  reads the .sdr/ sidecar and exposes summary.status
--
-- This module iterates ReadHistory, checks each book's DocSettings sidecar,
-- and counts non-Rakuyomi entries whose summary.status == "complete".
--
-- Cost notes: DocSettings:open() stats up to ten candidate paths and parses
-- the WHOLE sidecar (bookmarks, highlights, ...) just to expose summary.  For
-- counting we only need `summary`, so we locate the sidecar once with
-- findSidecarFile() (at most a few stats) and cache the parsed summary keyed
-- by (path, mtime, size).  Repeated scans therefore re-stat each sidecar but
-- never re-parse it, and unchanged sidecars stay on the cheap path even after
-- the result cache expires.

local logger = require("common/zen_logger").new("db_library")
local paths = require("common/paths")
local lfs = require("libs/libkoreader-lfs")
local Rakuyomi = require("modules/filebrowser/patches/rakuyomi")

local LibraryDB = {}

-- In-memory cache so the expensive sidecar scan only runs once per cache
-- window (default 5 minutes).  Call LibraryDB.invalidateCache() to force a
-- rescan on the next getBookCounts() call.
local _cache = {
    all = { book_counts = nil, cache_time = 0 },
    without_comics = { book_counts = nil, cache_time = 0 },
}
local CACHE_TTL = 300  -- seconds

-- Per-sidecar summary cache.  Key is sidecar path + modification time + size,
-- so an entry is only reused while the file on disk is byte-identical.
-- Bounded FIFO; entries are tiny (a status string and a date string).
local _summary_cache = {}
local _summary_order = {}
local SUMMARY_CACHE_MAX = 1024

local function cache_summary(key, summary)
    _summary_cache[key] = summary
    _summary_order[#_summary_order + 1] = key
    if #_summary_order > SUMMARY_CACHE_MAX then
        local oldest = table.remove(_summary_order, 1)
        _summary_cache[oldest] = nil
    end
end

-- Invalidate the cache so the next getBookCounts() call forces a fresh scan.
function LibraryDB.invalidateCache()
    for _key, cached in pairs(_cache) do
        cached.book_counts = nil
        cached.cache_time = 0
    end
end

-- Returns { finished = N, reading = N, total = N, finished_this_month = N, finished_this_year = N }
--   finished  non-Rakuyomi books whose sidecar summary.status is "complete"
--   reading   books whose sidecar summary.status is "reading"
--   total     all books in ReadHistory that have a sidecar file
-- All three counts come from the same ReadHistory walk so reading + finished
-- is always <= total.
-- Results are cached for CACHE_TTL seconds to avoid rescanning on every open.
function LibraryDB.getBookCounts(exclude_cbz_cbr)
    local now = os.time()
    local cached = _cache[exclude_cbz_cbr == true and "without_comics" or "all"]
    if cached.book_counts and (now - cached.cache_time) < CACHE_TTL then
        logger.info("returning cached book counts")
        return cached.book_counts
    end

    local counts = {
        finished = 0,
        reading = 0,
        total = 0,
        finished_this_month = 0,
        finished_this_year = 0,
    }
    local month = os.date("%Y-%m")
    local year = os.date("%Y")

    -- Count finished books from sidecar status
    local ok, err = pcall(function()
        local ReadHistory = require("readhistory")
        local DocSettings = require("docsettings")

        -- ReadHistory.hist may not be populated until the history module has
        -- been initialised.  Calling reload() ensures the list is current.
        if ReadHistory.reload then
            ReadHistory:reload(false)
        end

        local home_dir = paths.getHomeDir()

        local hist = ReadHistory.hist or {}
        for _i, entry in ipairs(hist) do
            local file = entry.file
            -- Skip books outside home_dir (SD card, other folders, etc.)
            if file and home_dir and not paths.isInHomeDir(file) then
                file = nil
            end
            if file and exclude_cbz_cbr == true and file:lower():match("%.cb[rz]$") then
                file = nil
            end
            if file then
                -- Locate the sidecar without the ten-candidate scan that
                -- DocSettings:open() performs.
                local sidecar_file = DocSettings:findSidecarFile(file)
                if sidecar_file then
                    local attrs = lfs.attributes(sidecar_file)
                    local mtime = attrs and attrs.modification
                    local size = attrs and attrs.size
                    if mtime and size and size > 0 then
                        counts.total = counts.total + 1
                        local summary = _summary_cache[
                            sidecar_file .. "\31" .. tostring(mtime) .. "\31" .. tostring(size)
                        ]
                        if not summary then
                            -- Light open: parses only the given sidecar file.
                            local doc_settings = DocSettings.openSettingsFile(sidecar_file)
                            summary = doc_settings and doc_settings.data.summary or nil
                            cache_summary(
                                sidecar_file .. "\31" .. tostring(mtime) .. "\31" .. tostring(size),
                                summary
                            )
                        end
                        if summary then
                            local status = summary.status
                            if status == "complete"
                                    and (file:lower():sub(-4) ~= ".cbz"
                                        or not Rakuyomi.isChapterFile(file)) then
                                counts.finished = counts.finished + 1
                                local modified = summary.modified
                                if type(modified) == "string" then
                                    if modified:sub(1, 7) == month then
                                        counts.finished_this_month = counts.finished_this_month + 1
                                    end
                                    if modified:sub(1, 4) == year then
                                        counts.finished_this_year = counts.finished_this_year + 1
                                    end
                                end
                            elseif status == "reading" then
                                counts.reading = counts.reading + 1
                            end
                        end
                    end
                end
            end
        end
    end)

    if not ok then
        logger.warn("finished count failed:", err)
    end

    logger.info("finished=", counts.finished,
                "reading=", counts.reading,
                "total=", counts.total)
    cached.book_counts = counts
    cached.cache_time = now
    return counts
end

return LibraryDB
