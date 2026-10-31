-- Avoid repeated zstd decompression of CoverBrowser thumbnail BLOBs.
local function apply_cover_decode_cache()
    local BookInfoManager = require("bookinfomanager")
    if BookInfoManager.__zen_cover_decode_cache_patched then return end
    BookInfoManager.__zen_cover_decode_cache_patched = true

    local cache = require("common/cover_decode_cache")
    local render_cache = require("common/cover_render_cache")
    local now = require("common/zen_logger").now
    local orig_getBookInfo = BookInfoManager.getBookInfo
    local VALIDATION_TTL_S = 30

    local function invalidate_library_cache()
        local db_bookinfo = package.loaded["common/db_bookinfo"]
        if db_bookinfo and type(db_bookinfo.invalidate) == "function" then
            db_bookinfo.invalidate()
        end
    end

    local function signature(info)
        return table.concat({
            tostring(info and info.filesize),
            tostring(info and info.filemtime),
            tostring(info and info.cover_fetched),
            tostring(info and info.has_cover),
            tostring(info and info.cover_sizetag),
            tostring(info and info.ignore_cover),
            tostring(info and info.cover_w),
            tostring(info and info.cover_h),
        }, "\31")
    end

    local function remember_metadata(filepath, info)
        if info and type(cache.putMetadata) == "function" then
            cache:putMetadata(filepath, info, now())
        end
    end

    function BookInfoManager:getBookInfo(filepath, get_cover)
        if not get_cover or not cache:has(filepath) then
            local started_at = get_cover and now()
            local info = orig_getBookInfo(self, filepath, get_cover)
            remember_metadata(filepath, info)
            if get_cover then
                cache:recordMiss()
                cache:recordFullRead(
                    (now() - started_at) * 1000,
                    info and info.cover_bb ~= nil,
                    rawget(_G, "__ZEN_COVER_PRELOAD_ACTIVE") == true
                )
            end
            if get_cover and info and info.cover_bb and info.has_cover and not info.ignore_cover then
                cache:put(filepath, signature(info), info.cover_bb, info, now())
            end
            return info
        end

        local lookup_started_at = now()
        local info = cache:getFresh(filepath, lookup_started_at, VALIDATION_TTL_S)
        cache:recordLookup((now() - lookup_started_at) * 1000)
        if info then return info end

        -- Metadata-only reads stop before the compressed BLOB, making cache
        -- validation cheap while preserving CoverBrowser's return shape.
        local validation_started_at = now()
        info = orig_getBookInfo(self, filepath, false)
        remember_metadata(filepath, info)
        cache:recordValidation((now() - validation_started_at) * 1000)
        if not info or not info.has_cover or info.ignore_cover then
            cache:drop(filepath)
            remember_metadata(filepath, info)
            cache:recordMiss()
            return info
        end
        lookup_started_at = now()
        local cover_bb = cache:get(filepath, signature(info), info, lookup_started_at)
        cache:recordLookup((now() - lookup_started_at) * 1000)
        if cover_bb then
            info.cover_bb = cover_bb
            return info
        end

        local full_read_started_at = now()
        info = orig_getBookInfo(self, filepath, true)
        remember_metadata(filepath, info)
        cache:recordFullRead(
            (now() - full_read_started_at) * 1000,
            info and info.cover_bb ~= nil,
            rawget(_G, "__ZEN_COVER_PRELOAD_ACTIVE") == true
        )
        if info and info.cover_bb and info.has_cover and not info.ignore_cover then
            cache:put(filepath, signature(info), info.cover_bb, info, now())
        end
        return info
    end

    local function wrap_filepath_mutation(name)
        local original = BookInfoManager[name]
        if type(original) ~= "function" then return end
        BookInfoManager[name] = function(self, filepath, ...)
            cache:drop(filepath)
            render_cache:drop(filepath)
            invalidate_library_cache()
            return original(self, filepath, ...)
        end
    end

    wrap_filepath_mutation("deleteBookInfo")
    wrap_filepath_mutation("extractBookInfo")
    wrap_filepath_mutation("setBookInfoProperties")

    local orig_extractInBackground = BookInfoManager.extractInBackground
    if type(orig_extractInBackground) == "function" then
        function BookInfoManager:extractInBackground(files, ...)
            invalidate_library_cache()
            if type(files) == "table" then
                for _i, item in ipairs(files) do
                    local filepath = type(item) == "table" and item.filepath or item
                    cache:drop(filepath)
                    render_cache:drop(filepath)
                end
            end
            return orig_extractInBackground(self, files, ...)
        end
    end

    local orig_deleteDb = BookInfoManager.deleteDb
    if type(orig_deleteDb) == "function" then
        function BookInfoManager:deleteDb(...)
            cache:clear()
            render_cache:clear()
            invalidate_library_cache()
            return orig_deleteDb(self, ...)
        end
    end
end

return apply_cover_decode_cache
