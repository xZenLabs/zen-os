-- File:         cache_bookinfo_get_doc_props.lua
-- Description:  Don't modify this to use `BookInfoManager:extractBookInfo`—it's extremely slow,
--               causes the app to freeze, and it won't cache data in many cases (87% of test cases fail).
-- Author:       Tachibana Shin <tachibshin@duck.com>
local function apply_cache_bookinfo_get_doc_props()
    local lfs = require("libs/libkoreader-lfs")
    local Cache = require("common/docprops_cache")
    local rapidjson = require("rapidjson")
    local DocumentRegistry = require("document/documentregistry")

    ---@param file string
    local function getProvider(file)
        local providers = DocumentRegistry:getProviders(file)
        if providers then
            -- associated provider
            local provider_key = DocumentRegistry:getAssociatedProviderKey(file)
            local provider = provider_key and DocumentRegistry.known_providers[provider_key]
            if provider and not provider.order then -- excluding auxiliary by default
                return provider, true
            end
            -- highest weighted provider
            return providers and providers[1].provider
        end
    end

    ---@param file string
    ---@return string
    local function getFastCacheKey(file)
        local attrs = lfs.attributes(file)
        local provider = getProvider(file)

        if not provider or provider.provider == "picdocument" or provider.provider == "imageviewer" or provider.provider == "textviewer" then
            return file
        end
        if not attrs then return file end
        return string.format("%s_%s_%s", file, attrs.size, attrs.modification)
    end

    -- Statements are reused while docprops_cache keeps the same handle open.
    local SQL = {
        select = "SELECT props FROM doc_props_cache WHERE cache_key = ?",
        insert = "INSERT OR REPLACE INTO doc_props_cache (cache_key, props, created_at) VALUES (?, ?, ?)",
        -- Key range instead of substr() so the PRIMARY KEY index is used.
        prune = "DELETE FROM doc_props_cache WHERE cache_key >= ? AND cache_key < ?"
            .. " AND substr(cache_key, ?) NOT GLOB '*[^0-9_]*' AND cache_key != ?",
    }
    local stmt_db, stmts = nil, {}

    local function statement(db, name)
        if stmt_db ~= db then stmt_db, stmts = db, {} end
        local stmt = stmts[name]
        if not stmt or stmt._closed then
            stmt = db:prepare(SQL[name])
            stmts[name] = stmt
        end
        if stmt then stmt:reset():clearbind() end
        return stmt
    end

    ---@param key string
    ---@return table|nil
    local function getPropsFromCache(key)
        return Cache.withDB(function(db)
            local stmt = statement(db, "select")
            if not stmt then return nil end

            stmt:bind(key)
            local row = stmt:step()
            local result = nil

            if row then
                local props_json = row[1]
                if props_json then
                    local status, data = pcall(rapidjson.decode, props_json)
                    if status then result = data end
                end
            end

            stmt:reset()
            return result
        end)
    end

    ---@param key string
    ---@param props table
    ---@return nil
    local function savePropsToCache(key, props)
        if not props then return end
        local status, props_json = pcall(rapidjson.encode, props)
        if not status then return end

        Cache.withDB(function(db)
            local stmt = statement(db, "insert")
            if not stmt then return end
            stmt:bind(key, props_json, os.time()):step()
            stmt:reset()
            -- Drop rows for older size/mtime versions of this file; otherwise the table only grows.
            local prefix = key:match("^(.*_)%d+_%d+$")
            if prefix then
                stmt = statement(db, "prune")
                if stmt then
                    stmt:bind(prefix, prefix .. "\255", #prefix + 1, key):step()
                    stmt:reset()
                end
            end
        end)
    end

    local BookInfo = require("apps/filemanager/filemanagerbookinfo")
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    local BookList = require("ui/widget/booklist")
    local DocSettings = require("docsettings")
    local Document = require("document/document")

    -- Returns customized document metadata, including number of pages.
    ---@param file string
    ---@param book_props table
    ---@param no_open_document boolean
    function BookInfo:getDocProps(file, book_props, no_open_document)
        ---@original
        if self.ui.coverbrowser then
            book_props = self.ui.coverbrowser.getDocProps(file)

            if book_props ~= nil then -- already customized
                book_props.display_title = book_props.title or filemanagerutil.splitFileNameType(file)
                return book_props
            end
        end

        if BookList.hasBookBeenOpened(file) then
            local doc_settings = BookList.getDocSettings(file)
            if not book_props then
                book_props = doc_settings:readSetting("doc_props")
            end
            if not book_props then
                local stats = doc_settings:readSetting("stats")
                if stats and stats.pages ~= 0 then
                    book_props = Document:getProps(stats)
                end
            end
            local doc_pages = doc_settings:readSetting("doc_pages")
            if doc_pages and book_props then
                book_props.pages = doc_pages
            end
        end

        if not book_props then
            local custom_metadata_file = DocSettings:findCustomMetadataFile(file)
            if custom_metadata_file then
                book_props = DocSettings.openSettingsFile(custom_metadata_file):readSetting("doc_props")
            end
        end
        ---@/original

        local cache_key = nil
        if not book_props then
            cache_key = getFastCacheKey(file)
            local cached_props = getPropsFromCache(cache_key)
            if cached_props then
                book_props = cached_props
                -- print("Hit SQLite cache for: " .. file)
            end
        end

        if not book_props and not no_open_document then
            ---@original
            local has = DocumentRegistry:hasProvider(file)
            local document = has and DocumentRegistry:openDocument(file)

            if document then
                local loaded = true
                local pages

                if document.loadDocument then -- CreDocument
                    if not document:loadDocument(false) then
                        loaded = false
                    end
                else
                    pages = document:getPageCount()
                end

                if loaded then
                    book_props = document:getProps()
                    book_props.pages = pages
                end
                document:close()
            end
            ---@/original

            if cache_key then
                savePropsToCache(cache_key, book_props or {})
            end
        end

        local out = BookInfo.extendProps(book_props, file)
        return out
    end
end

return apply_cache_bookinfo_get_doc_props
