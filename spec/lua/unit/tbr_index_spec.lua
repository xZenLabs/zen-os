describe("TBR path inventory", function()
    local test_dir
    local attrs
    local entries
    local sidecars
    local sidecar_lookups
    local docs
    local opens
    local open_fail
    local config
    local ReadCollection
    local scheduled
    local scheduled_delays
    local collection_writes
    local updated_collection_order
    local arrange_options
    local view_refreshes
    local tick

    local function add_book(path, status, sidecar_mtime)
        local directory, name = path:match("^(.*)/([^/]+)$")
        entries[directory] = entries[directory] or { ".", ".." }
        entries[directory][#entries[directory] + 1] = name
        attrs[path] = { mode = "file", size = 10, modification = 1, access = 1 }
        if sidecar_mtime then
            local sidecar = "/sidecars/" .. name .. ".lua"
            sidecars[path] = sidecar
            attrs[sidecar] = {
                mode = "file", size = 10, modification = sidecar_mtime,
            }
            docs[path] = {
                data = { doc_path = path },
                summary = { status = status },
                percent_finished = status == "reading" and 0.4 or nil,
                readSetting = function(self, key)
                    if key == "summary" then return self.summary end
                    if key == "percent_finished" then return self.percent_finished end
                end,
            }
        end
    end

    local function run_scheduled()
        while #scheduled > 0 do table.remove(scheduled, 1)() end
    end

    before_each(function()
        local host_lfs = require("lfs")
        test_dir = os.tmpname()
        os.remove(test_dir)
        assert(host_lfs.mkdir(test_dir))

        attrs = {
            ["/books"] = { mode = "directory", modification = 1 },
        }
        entries = { ["/books"] = { ".", ".." } }
        sidecars = {}
        sidecar_lookups = 0
        docs = {}
        opens = 0
        open_fail = nil
        scheduled = {}
        scheduled_delays = {}
        collection_writes = 0
        updated_collection_order = nil
        arrange_options = nil
        view_refreshes = { home = 0, group = 0, collection = 0 }
        config = {
            _meta = { tbr_collection_migrated = true },
            additional_home_dirs = {},
        }
        ReadCollection = {
            coll = { favorites = {} },
            coll_settings = { favorites = { order = 1 } },
        }
        function ReadCollection:addCollection(name)
            self.coll[name] = {}
            self.coll_settings[name] = { order = 2 }
        end
        function ReadCollection:renameCollection(name, new_name)
            self.coll[new_name] = self.coll[name]
            self.coll_settings[new_name] = self.coll_settings[name]
            self.coll[name] = nil
            self.coll_settings[name] = nil
        end
        function ReadCollection:write() collection_writes = collection_writes + 1 end
        function ReadCollection:addItem(path, name, attr)
            local order = 1
            for _path, item in pairs(self.coll[name]) do
                order = math.max(order, (tonumber(item.order) or 0) + 1)
            end
            self.coll[name][path] = {
                file = path,
                attr = attr,
                text = path:match("([^/]+)$"),
                order = order,
            }
        end
        function ReadCollection:removeItem(path, name)
            self.coll[name][path] = nil
            return true
        end
        function ReadCollection:isFileInCollection(path, name)
            return self.coll[name] and self.coll[name][path] ~= nil
        end
        function ReadCollection:getOrderedCollection(name)
            local ordered = {}
            for _path, item in pairs(self.coll[name]) do ordered[#ordered + 1] = item end
            table.sort(ordered, function(first, second)
                return first.order < second.order
            end)
            return ordered
        end
        function ReadCollection:updateCollectionOrder(name, ordered)
            updated_collection_order = {}
            for index, item in ipairs(ordered) do
                local path = type(item) == "table" and item.file or item
                updated_collection_order[#updated_collection_order + 1] = path
                if self.coll[name][path] then self.coll[name][path].order = index end
            end
        end

        ZenSpec.replace("datastorage", { getSettingsDir = function() return test_dir end })
        ZenSpec.replace("device", { canUseWAL = function() return true end })
        ZenSpec.replace("config/manager", {
            get = function() return config end,
            save = function(value) config = value end,
        })
        ZenSpec.replace("common/paths", {
            getHomeDir = function() return "/books" end,
            normPath = function(path) return path end,
            isInHomeDir = function(path) return path:sub(1, 7) == "/books/" end,
        })
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function(path, key)
                if path:sub(1, #test_dir) == test_dir then
                    return host_lfs.attributes(path, key)
                end
                local attr = attrs[path]
                return key and attr and attr[key] or attr
            end,
            mkdir = host_lfs.mkdir,
            rmdir = host_lfs.rmdir,
            dir = function(path)
                local list = assert(entries[path], "missing directory " .. path)
                local index = 0
                return function()
                    index = index + 1
                    return list[index]
                end, {}
            end,
        })
        ZenSpec.replace("document/documentregistry", {
            hasProvider = function(_self, path) return path:sub(-5) == ".epub" end,
        })
        ZenSpec.replace("ui/widget/filechooser", {
            show_hidden = false,
            exclude_files = {},
            show_dir = function() return true end,
        })
        ZenSpec.replace("readcollection", ReadCollection)
        ZenSpec.replace("docsettings", {
            findSidecarFile = function(_self, path)
                sidecar_lookups = sidecar_lookups + 1
                return sidecars[path]
            end,
            open = function(_self, path)
                opens = opens + 1
                if open_fail == path then return nil end
                return docs[path]
            end,
        })
        ZenSpec.replace("apps/filemanager/filemanagerutil", {
            saveSummary = function(doc, summary) doc.summary = summary end,
        })
        ZenSpec.replace("ui/widget/booklist", {
            setBookInfoCacheProperty = function() end,
            collates = {},
        })
        ZenSpec.replace("common/book_status", {
            isImageFile = function() return false end,
            fileUpdatesAsNewEnabled = function()
                return config.group_view and config.group_view.file_updates_as_new == true or false
            end,
            migrateLegacyMarker = function(_path, status) return status end,
            getComputedStatus = function(_path, status, percent)
                if status then return status end
                return percent == nil and "new" or "reading"
            end,
            getDisplayStatus = function(path, status)
                for name, settings in pairs(ReadCollection.coll_settings) do
                    if settings.zenos_tbr == true
                            and ReadCollection:isFileInCollection(path, name) then
                        return "tbr"
                    end
                end
                return status
            end,
            includeNewInTBREnabled = function()
                return config.group_view
                    and config.group_view.include_new_in_tbr == true
            end,
        })
        ZenSpec.replace("common/db_bookinfo", {
            getLightMetadata = function()
                return {
                    ["/books/a.epub"] = { title = "Zulu" },
                    ["/books/b.epub"] = { title = "Bravo" },
                    ["/books/c.epub"] = { title = "Alpha" },
                }
            end,
        })
        ZenSpec.replace("common/title_sort", { sortKey = function(value) return value:lower() end })
        ZenSpec.replace("ui/uimanager", {
            nextTick = function(_self, fn) scheduled[#scheduled + 1] = fn end,
            scheduleIn = function(_self, delay, fn)
                scheduled_delays[#scheduled_delays + 1] = delay
                scheduled[#scheduled + 1] = fn
            end,
            unschedule = function() end,
        })
        ZenSpec.replace("common/ui/zen_arrange_list", {
            show = function(options) arrange_options = options end,
        })
        ZenSpec.replace("common/shared_state", {
            get = function(_plugin, key)
                if key == "home" then
                    return {
                        invalidateTBRCache = function()
                            view_refreshes.home = view_refreshes.home + 1
                        end,
                    }
                end
                if key == "group_view" then
                    return {
                        refreshTBRView = function()
                            view_refreshes.group = view_refreshes.group + 1
                        end,
                    }
                end
                if key == "collections" then
                    return {
                        refreshTBRCollection = function()
                            view_refreshes.collection = view_refreshes.collection + 1
                        end,
                    }
                end
            end,
        })
        tick = 0
        ZenSpec.replace("common/zen_logger", {
            now = function() tick = tick + 0.001; return tick end,
            new = function()
                return {
                    warn = function() end,
                    info = function() end,
                    measure = function() end,
                }
            end,
        })
        ZenSpec.unload("common/tbr_index")
        ZenSpec.unload("common/docprops_cache")
    end)

    after_each(function()
        local index = package.loaded["common/tbr_index"]
        if index and index.close then index.close() end
        ZenSpec.unload("common/tbr_index")
        ZenSpec.unload("common/docprops_cache")
        local host_lfs = require("lfs")
        for name in host_lfs.dir(test_dir) do
            local path = test_dir .. "/" .. name
            if host_lfs.attributes(path, "mode") == "file" then
                os.remove(path)
            elseif name:find(".corrupt-", 1, true) then
                for file in host_lfs.dir(path) do
                    if file ~= "." and file ~= ".." then os.remove(path .. "/" .. file) end
                end
                host_lfs.rmdir(path)
            end
        end
        host_lfs.rmdir(test_dir)
    end)

    it("publishes every sidecar-free book without BookInfo or DocSettings", function()
        add_book("/books/a.epub")
        add_book("/books/b.epub")
        add_book("/books/c.epub")
        ZenSpec.replace("common/db_bookinfo", {
            getLightMetadata = function() return {} end,
        })

        local Index = require("common/tbr_index")
        assert.same({ "/books/a.epub", "/books/b.epub", "/books/c.epub" },
            Index.getAll({ include_new = true, collate = "title" }))
        assert.are.equal(0, opens)
    end)

    it("exports every book path from all configured home directories", function()
        config.additional_home_dirs = { "/extra" }
        attrs["/extra"] = { mode = "directory", modification = 1 }
        entries["/extra"] = { ".", ".." }
        add_book("/books/current.epub")
        add_book("/extra/already-read.epub", "complete", 1)

        assert.same({ "/books/current.epub", "/extra/already-read.epub" },
            require("common/tbr_index").getInventoryPaths())
    end)

    it("filters the inventory by display status", function()
        add_book("/books/a.epub", "complete", 1)
        add_book("/books/b.epub", "reading", 1)
        add_book("/books/c.epub", "abandoned", 1)
        add_book("/books/d.epub", "reading", 1)
        add_book("/books/e.epub")
        local Index = require("common/tbr_index")
        assert.is_true(Index.setExplicit("/books/b.epub", true))

        assert.same({ "/books/c.epub", "/books/a.epub" }, Index.getByStatuses({
            complete = true,
            abandoned = true,
        }))
        assert.same({ "/books/b.epub" }, Index.getByStatuses({ tbr = true }))
        assert.same({ "/books/d.epub" }, Index.getByStatuses({ reading = true }))
        assert.same({ "/books/e.epub" }, Index.getByStatuses({ new = true }))
        assert.are.equal(5, sidecar_lookups)
    end)

    it("preserves and rebuilds a corrupt status cache from Reading and Finished sidecars", function()
        add_book("/books/a.epub", "reading", 1)
        add_book("/books/b.epub", "complete", 1)
        local Index = require("common/tbr_index")
        Index.getByStatuses({ reading = true })
        Index.close()
        Index.invalidateStatusCache()

        local database_path = test_dir .. "/docprops_cache.sqlite"
        local connection = require("lua-ljsqlite3/init").open(database_path)
        local page_size = tonumber(connection:exec("PRAGMA page_size")[1][1])
        local root_page = tonumber(connection:exec([[
            SELECT rootpage FROM sqlite_master WHERE name = 'zen_doc_status_cache'
        ]])[1][1])
        connection:close()
        local database = assert(io.open(database_path, "r+b"))
        assert(database:seek("set", (root_page - 1) * page_size))
        assert(database:write(string.rep("\0", page_size)))
        database:seek("set", 0)
        local corrupted = database:read("*a")
        database:close()
        local reads_before = opens

        assert.same({ "/books/a.epub" }, Index.getByStatuses({ reading = true }))
        assert.same({ "/books/b.epub" }, Index.getByStatuses({ complete = true }))
        assert.are.equal(reads_before + 2, opens)
        Index.invalidateStatusCache()
        assert.same({ "/books/a.epub" }, Index.getByStatuses({ reading = true }))
        assert.are.equal(reads_before + 2, opens)

        local backup
        for name in require("lfs").dir(test_dir) do
            if name:find(".corrupt-", 1, true) then backup = test_dir .. "/" .. name end
        end
        database = assert(io.open(backup .. "/docprops_cache.sqlite", "rb"))
        assert.are.equal(corrupted, database:read("*a"))
        database:close()
        Index.close()
        connection = require("lua-ljsqlite3/init").open(database_path)
        assert.are.equal("ok", connection:exec("PRAGMA quick_check")[1][1])
        assert.are.equal(2, tonumber(connection:exec("SELECT count(*) FROM zen_doc_status_cache")[1][1]))
        connection:close()
        Index.invalidateStatusCache()
        assert.same({ "/books/b.epub" }, Index.getByStatuses({ complete = true }))
        assert.are.equal(reads_before + 2, opens)
    end)

    it("rebuilds an invalid database and persists status changes", function()
        add_book("/books/a.epub", "reading", 1)
        local database_path = test_dir .. "/docprops_cache.sqlite"
        local database = assert(io.open(database_path, "wb"))
        database:write("not a SQLite database")
        database:close()

        local Index = require("common/tbr_index")
        assert.same({ "/books/a.epub" }, Index.getByStatuses({ reading = true }))
        docs["/books/a.epub"].summary.status = "complete"
        assert.is_true(Index.refreshPath("/books/a.epub", docs["/books/a.epub"]))
        assert.same({ "/books/a.epub" }, Index.getByStatuses({ complete = true }))
        local connection = require("lua-ljsqlite3/init").open(database_path)
        assert.are.equal("complete", connection:exec("SELECT status FROM zen_doc_status_cache")[1][1])
        connection:close()
        Index.removePath("/books/a.epub")

        Index.close()
        connection = require("lua-ljsqlite3/init").open(database_path)
        assert.are.equal("ok", connection:exec("PRAGMA quick_check")[1][1])
        assert.are.equal(0, tonumber(connection:exec("SELECT count(*) FROM zen_doc_status_cache")[1][1]))
        connection:close()
    end)

    it("does not cache a status change whose database write fails", function()
        add_book("/books/a.epub", "reading", 1)
        local Index = require("common/tbr_index")
        assert.same({ "/books/a.epub" }, Index.getByStatuses({ reading = true }))
        docs["/books/a.epub"].summary.status = "complete"
        local Cache = require("common/docprops_cache")
        local with_db = Cache.withDB
        Cache.withDB = function() error("ljsqlite3[full] database is full", 0) end
        local ok, err = pcall(Index.refreshPath, "/books/a.epub", docs["/books/a.epub"])
        Cache.withDB = with_db
        assert.is_false(ok)
        assert.matches("database is full", err)
        Index.invalidateStatusCache()
        assert.same({ "/books/a.epub" }, Index.getByStatuses({ reading = true }))
        assert.is_true(Index.refreshPath("/books/a.epub", docs["/books/a.epub"]))
        assert.same({ "/books/a.epub" }, Index.getByStatuses({ complete = true }))
    end)

    it("retries the whole status transaction when committing detects corruption", function()
        add_book("/books/a.epub", "reading", 1)
        add_book("/books/b.epub", "complete", 1)
        local sqlite3 = require("lua-ljsqlite3/init")
        local open = sqlite3.open
        local failed_commit
        sqlite3.open = function(path)
            local db = open(path)
            if failed_commit then return db end
            return {
                exec = function(_self, sql)
                    if sql == "COMMIT" then
                        failed_commit = true
                        error("ljsqlite3[corrupt] database disk image is malformed", 0)
                    end
                    return db:exec(sql)
                end,
                prepare = function(_self, sql) return db:prepare(sql) end,
                close = function() db:close() end,
            }
        end
        local Index = require("common/tbr_index")
        local ok, result = pcall(Index.getByStatuses, { reading = true })
        sqlite3.open = open
        assert.is_true(ok, result)
        assert.same({ "/books/a.epub" }, result)
        assert.same({ "/books/b.epub" }, Index.getByStatuses({ complete = true }))
        assert.are.equal(4, opens)
        Index.close()
        local db = open(test_dir .. "/docprops_cache.sqlite")
        assert.are.equal(2, tonumber(db:exec("SELECT count(*) FROM zen_doc_status_cache")[1][1]))
        assert.are.equal("ok", db:exec("PRAGMA quick_check")[1][1])
        db:close()
    end)

    it("uses the ordinary collection for explicit TBR membership", function()
        add_book("/books/a.epub", "reading", 1)
        add_book("/books/b.epub", "reading", 1)
        local Index = require("common/tbr_index")

        assert.is_true(Index.setExplicit("/books/b.epub", true))
        assert.same({ "/books/b.epub" }, Index.getAll({ include_new = false }))
        assert.is_true(Index.isExplicit("/books/b.epub"))
        assert.are.equal("reading", docs["/books/b.epub"].summary.status)
        assert.are.equal(0.4, docs["/books/b.epub"].percent_finished)
        assert.is_true(Index.setExplicit("/books/b.epub", false))
        assert.same({}, Index.getAll({ include_new = false }))
        assert.are.equal(3, collection_writes)
    end)

    it("keeps explicit Kindle books outside the configured library", function()
        local kindle_path = "/kindle-cache/book.epub"
        attrs[kindle_path] = { mode = "file" }
        ZenSpec.replace("modules/filebrowser/patches/kindle_virtual_library", {
            isBookPath = function(path) return path == kindle_path end,
        })
        local Index = require("common/tbr_index")

        assert.is_true(Index.setExplicit(kindle_path, true))
        assert.same({ kindle_path }, Index.getAll({ include_new = false }))
    end)

    it("rejects missing TBR files and still removes stale membership", function()
        local path = "/books/manga.cbz"
        add_book(path, "reading", 1)
        local Index = require("common/tbr_index")
        assert.is_true(Index.setExplicit(path, true))
        attrs[path] = nil
        assert.is_true(Index.setExplicit(path, false))
        local writes = collection_writes
        ReadCollection.addItem = function() error("attempted to add a missing file") end
        assert.is_false(Index.setExplicit(path, true))
        assert.is_false(Index.setExplicit("/books", true))
        assert.are.equal(writes, collection_writes)
        assert.is_false(Index.isExplicit(path))
    end)

    it("saves a shared manual order and refreshes its views", function()
        config.group_view = { include_new_in_tbr = true }
        add_book("/books/a.epub", "reading", 1)
        add_book("/books/b.epub", "reading", 1)
        add_book("/books/c.epub")
        add_book("/books/d.epub")
        local Index = require("common/tbr_index")

        assert.is_true(Index.setExplicit("/books/a.epub", true))
        assert.is_true(Index.setExplicit("/books/b.epub", true))
        local coll_name = Index.collectionName()
        local settings = ReadCollection.coll_settings[coll_name]
        settings.collate = "title"
        settings.collate_reverse = true
        local writes_before = collection_writes
        local plugin = {}
        local settings_resume = { path = { "To Be Read" } }
        local changed = 0

        Index.showOrder({
            plugin = plugin,
            settings_resume = settings_resume,
            on_change = function() changed = changed + 1 end,
        })
        assert.are.equal("Order", arrange_options.title)
        assert.are.equal(plugin, arrange_options.plugin)
        assert.same({ "To Be Read", "Order" }, arrange_options.settings_resume.path)
        assert.same({ "To Be Read" }, settings_resume.path)
        assert.same({ "Zulu", "Bravo", "Alpha", "d" }, {
            arrange_options.item_table[1].text,
            arrange_options.item_table[2].text,
            arrange_options.item_table[3].text,
            arrange_options.item_table[4].text,
        })
        arrange_options.item_table[1], arrange_options.item_table[3] =
            arrange_options.item_table[3], arrange_options.item_table[1]
        arrange_options.callback()

        assert.same({
            "/books/c.epub", "/books/b.epub", "/books/a.epub", "/books/d.epub",
        }, settings.zenos_tbr_order)
        assert.is_true(settings.zenos_tbr)
        assert.is_nil(settings.collate)
        assert.is_nil(settings.collate_reverse)
        assert.same({ "/books/b.epub", "/books/a.epub" }, updated_collection_order)
        assert.are.equal(1, ReadCollection.coll[coll_name]["/books/b.epub"].order)
        assert.are.equal(2, ReadCollection.coll[coll_name]["/books/a.epub"].order)
        assert.are.equal(writes_before + 1, collection_writes)
        assert.are.equal("manual",
            config.group_view.detail_collate.to_be_read.to_be_read)
        assert.is_false(config.group_view.detail_reverse.to_be_read.to_be_read)
        assert.are.equal(1, changed)
        assert.same({ home = 1, group = 1, collection = 1 }, view_refreshes)

        assert.is_true(Index.setExplicit("/books/c.epub", true))
        assert.same({
            "/books/c.epub", "/books/b.epub", "/books/a.epub",
        }, updated_collection_order)

        add_book("/books/e.epub")
        attrs["/books"].modification = 2
        assert.same({
            "/books/c.epub", "/books/b.epub", "/books/a.epub",
            "/books/d.epub", "/books/e.epub",
        }, Index.getAll({ include_new = true, collate = "manual" }))

        assert.is_true(Index.moveOrderPath(
            "/books/a.epub", "/books/shelf/a.epub"))
        assert.is_true(Index.moveOrderPath("/books", "/library", true))
        assert.same({
            "/library/c.epub", "/library/b.epub",
            "/library/shelf/a.epub", "/library/d.epub",
        }, settings.zenos_tbr_order)
    end)

    it("adopts an existing To Be Read collection without replacing it", function()
        add_book("/books/a.epub", "reading", 1)
        ReadCollection:addCollection("To Be Read")
        ReadCollection:addItem("/books/a.epub", "To Be Read")
        local existing = ReadCollection.coll["To Be Read"]
        local Index = require("common/tbr_index")

        assert.are.equal("To Be Read", Index.collectionName())
        assert.is_true(rawequal(existing, ReadCollection.coll["To Be Read"]))
        assert.is_true(ReadCollection.coll_settings["To Be Read"].zenos_tbr)
        assert.same({ "/books/a.epub" }, Index.getAll({ include_new = false }))
        assert.are.equal(1, collection_writes)
    end)

    it("keeps explicit TBR membership linked after the collection is renamed", function()
        add_book("/books/a.epub", "reading", 1)
        add_book("/books/b.epub", "reading", 1)
        local Index = require("common/tbr_index")

        assert.is_true(Index.setExplicit("/books/a.epub", true))
        local old_name = Index.collectionName()
        assert.is_true(ReadCollection.coll_settings[old_name].zenos_tbr)
        ReadCollection:renameCollection(old_name, "Later")
        assert.are.equal("Later", Index.collectionName())
        assert.is_true(ReadCollection.coll_settings.Later.zenos_tbr)

        Index.close()
        ZenSpec.unload("common/tbr_index")
        Index = require("common/tbr_index")

        assert.are.equal("Later", Index.collectionName())
        assert.same({ "/books/a.epub" }, Index.getAll({ include_new = false }))
        assert.is_true(Index.isExplicit("/books/a.epub"))
        assert.is_nil(ReadCollection.coll[old_name])
        assert.is_true(Index.setExplicit("/books/b.epub", true))
        assert.is_truthy(ReadCollection.coll.Later["/books/b.epub"])
        assert.is_nil(ReadCollection.coll[old_name])
    end)

    it("does not reload disk state over a pending TBR collection rename", function()
        add_book("/books/a.epub", "reading", 1)
        local Index = require("common/tbr_index")

        assert.is_true(Index.setExplicit("/books/a.epub", true))
        local old_name = Index.collectionName()
        ReadCollection:renameCollection(old_name, "Later")
        local reloads = 0
        ReadCollection._read = function(self)
            reloads = reloads + 1
            self:renameCollection("Later", old_name)
        end

        assert.same({ "/books/a.epub" }, Index.getAll({ include_new = false }))
        assert.are.equal(0, reloads)
        assert.are.equal("Later", Index.collectionName())
        assert.is_nil(ReadCollection.coll[old_name])
    end)

    it("reopens only a changed sidecar across warm queries and reloads", function()
        add_book("/books/a.epub", "reading", 1)
        add_book("/books/b.epub", nil, 1)
        local Index = require("common/tbr_index")

        assert.same({ "/books/b.epub" }, Index.getAll({ include_new = true }))
        assert.are.equal(2, opens)
        Index.invalidateStatusCache()
        assert.same({ "/books/b.epub" }, Index.getAll({ include_new = true }))
        assert.are.equal(2, opens)

        Index.close()
        ZenSpec.unload("common/tbr_index")
        Index = require("common/tbr_index")
        assert.same({ "/books/b.epub" }, Index.getAll({ include_new = true }))
        assert.are.equal(2, opens)

        attrs[sidecars["/books/a.epub"]].modification = 2
        docs["/books/a.epub"].summary.status = nil
        docs["/books/a.epub"].percent_finished = nil
        Index.invalidateStatusCache()
        assert.same({ "/books/b.epub", "/books/a.epub" },
            Index.getAll({ include_new = true }))
        assert.are.equal(3, opens)
    end)

    it("reclassifies unchanged sidecars after the file-update setting changes, including after reload", function()
        add_book("/books/a.epub", "complete", 1)
        attrs["/books/a.epub"].modification = 2
        package.loaded["common/book_status"].getComputedStatus = function(_path, status)
            return config.group_view.file_updates_as_new and "new" or status
        end
        config.group_view = { file_updates_as_new = true }
        local Index = require("common/tbr_index")
        assert.same({ "/books/a.epub" }, Index.getByStatuses({ new = true }))
        assert.are.equal(1, opens)

        config.group_view.file_updates_as_new = false
        Index.invalidateStatusCache()
        assert.same({}, Index.getByStatuses({ new = true }))
        assert.same({ "/books/a.epub" }, Index.getByStatuses({ complete = true }))
        assert.are.equal(2, opens)

        Index.close()
        config.group_view.file_updates_as_new = true
        ZenSpec.unload("common/tbr_index")
        Index = require("common/tbr_index")
        assert.same({ "/books/a.epub" }, Index.getByStatuses({ new = true }))
        assert.are.equal(3, opens)
    end)

    it("reuses explicit paths without restatting and sees collection additions", function()
        add_book("/books/a.epub")
        add_book("/books/b.epub")
        local Index = require("common/tbr_index")
        assert.is_true(Index.setExplicit("/books/a.epub", true))
        assert.same({ "/books/a.epub" }, Index.getAll())

        local library_lfs = require("libs/libkoreader-lfs")
        local original_attributes = library_lfs.attributes
        local attribute_calls = 0
        library_lfs.attributes = function(...)
            attribute_calls = attribute_calls + 1
            return original_attributes(...)
        end
        assert.same({ "/books/a.epub" }, Index.getAll())
        assert.are.equal(0, attribute_calls)

        ReadCollection:addItem("/books/b.epub", Index.collectionName())
        assert.same({ "/books/b.epub", "/books/a.epub" }, Index.getAll())
        assert.is_true(attribute_calls > 0)
    end)

    it("drops a removed explicit book after a path notification", function()
        add_book("/books/a.epub")
        local Index = require("common/tbr_index")
        assert.is_true(Index.setExplicit("/books/a.epub", true))
        assert.same({ "/books/a.epub" }, Index.getAll())

        attrs["/books/a.epub"] = nil
        assert.is_true(Index.refreshPath("/books/a.epub"))
        assert.same({}, Index.getAll())
    end)

    it("rechecks explicit files after the cache interval", function()
        add_book("/books/a.epub")
        local Index = require("common/tbr_index")
        assert.is_true(Index.setExplicit("/books/a.epub", true))
        assert.same({ "/books/a.epub" }, Index.getAll())

        attrs["/books/a.epub"] = nil
        assert.same({ "/books/a.epub" }, Index.getAll())
        tick = tick + 5
        assert.same({}, Index.getAll())
    end)

    it("migrates legacy abandoned statuses into the collection once", function()
        config._meta.tbr_collection_migrated = false
        add_book("/books/a.epub", "abandoned", 1)
        add_book("/books/b.epub", "reading", 1)

        local Index = require("common/tbr_index")
        assert.same({ "/books/a.epub" }, Index.getAll({ include_new = false }))
        assert.is_nil(docs["/books/a.epub"].summary.status)
        assert.is_true(config._meta.tbr_collection_migrated)
        assert.is_true(Index.isExplicit("/books/a.epub"))
    end)

    it("migrates against a completed startup audit", function()
        config._meta.tbr_collection_migrated = false
        add_book("/books/a.epub", "abandoned", 1)
        local Index = require("common/tbr_index")

        assert.is_true(Index.scheduleAudit())
        run_scheduled()
        assert.is_true(Index.isAuditComplete())
        assert.same({ "/books/a.epub" }, Index.getAll())
        assert.is_true(config._meta.tbr_collection_migrated)
    end)

    it("keeps a cached classification when a changed sidecar cannot be read", function()
        add_book("/books/a.epub", nil, 1)
        local Index = require("common/tbr_index")
        assert.same({ "/books/a.epub" }, Index.getAll({ include_new = true }))

        attrs[sidecars["/books/a.epub"]].modification = 2
        open_fail = "/books/a.epub"
        Index.invalidateStatusCache()
        assert.same({ "/books/a.epub" }, Index.getAll({ include_new = true }))
    end)

    it("reconciles externally added books as one complete result", function()
        add_book("/books/a.epub")
        local Index = require("common/tbr_index")
        assert.same({ "/books/a.epub" }, Index.getAll({ include_new = true }))

        add_book("/books/b.epub")
        attrs["/books"].modification = 2
        assert.same({ "/books/b.epub", "/books/a.epub" },
            Index.getAll({ include_new = true }))
    end)

    it("keeps the previous complete inventory when a root is unavailable", function()
        add_book("/books/a.epub")
        local Index = require("common/tbr_index")
        assert.same({ "/books/a.epub" }, Index.getAll({ include_new = true }))

        attrs["/books"] = nil
        assert.same({ "/books/a.epub" }, Index.getAll({ include_new = true }))
    end)

    it("applies a status change immediately without rescanning paths", function()
        add_book("/books/a.epub", "reading", 1)
        local Index = require("common/tbr_index")
        assert.same({}, Index.getAll({ include_new = true }))

        docs["/books/a.epub"].summary.status = nil
        docs["/books/a.epub"].percent_finished = nil
        assert.is_true(Index.refreshPath("/books/a.epub", docs["/books/a.epub"]))
        assert.same({ "/books/a.epub" }, Index.getAll({ include_new = true }))
    end)

    it("keeps results on duplicate open notifications without sidecar lookups", function()
        add_book("/books/a.epub", "reading", 1)
        local Index = require("common/tbr_index")
        assert.same({}, Index.getAll({ include_new = true }))
        local lookups = sidecar_lookups
        local revision = Index.getRevision()

        assert.is_false(Index.refreshPath("/books/a.epub", docs["/books/a.epub"]))
        assert.is_false(Index.refreshPath("/books/a.epub", docs["/books/a.epub"]))
        assert.are.equal(lookups, sidecar_lookups)
        assert.are.equal(revision, Index.getRevision())
    end)

    it("reorders cached access-sorted books after an unchanged status update", function()
        add_book("/books/a.epub", "reading", 1)
        add_book("/books/b.epub", "reading", 1)
        attrs["/books/a.epub"].access = 2
        local Index = require("common/tbr_index")
        assert.is_true(Index.setExplicit("/books/a.epub", true))
        assert.is_true(Index.setExplicit("/books/b.epub", true))
        Index.getByStatuses({ reading = true })
        assert.same({ "/books/a.epub", "/books/b.epub" },
            Index.getAll({ include_new = true, collate = "access" }))

        attrs["/books/b.epub"].access = 3
        assert.is_false(Index.refreshPath("/books/b.epub", docs["/books/b.epub"]))
        assert.same({ "/books/b.epub", "/books/a.epub" },
            Index.getAll({ include_new = true, collate = "access" }))
    end)

    it("coalesces scheduled reconciliation callbacks", function()
        add_book("/books/a.epub")
        local Index = require("common/tbr_index")
        local completed = 0
        assert.is_true(Index.scheduleAudit(function() end,
            function() completed = completed + 1 end))
        assert.is_false(Index.scheduleAudit(function() end,
            function() completed = completed + 1 end))
        run_scheduled()
        assert.are.equal(2, completed)
        assert.is_true(Index.isAuditComplete())
    end)

    it("keeps a failed startup audit incomplete for a later migration", function()
        attrs["/books"] = nil
        local Index = require("common/tbr_index")
        assert.is_true(Index.scheduleAudit())
        run_scheduled()
        assert.is_false(Index.isAuditComplete())
    end)

    it("scans a cold nested inventory over multiple UI ticks", function()
        for shelf = 1, 40 do
            local path = "/books/shelf" .. shelf
            attrs[path] = { mode = "directory", modification = 1 }
            entries["/books"][#entries["/books"] + 1] = "shelf" .. shelf
            entries[path] = { ".", ".." }
        end
        add_book("/books/shelf1/a.epub")
        local Index = require("common/tbr_index")

        assert.is_true(Index.scheduleAudit())
        table.remove(scheduled, 1)()
        assert.is_true(Index.isAuditRunning())
        assert.are.equal(1, #scheduled)
        -- A zero-delay continuation keeps UIManager from ever polling input.
        assert.is_true(scheduled_delays[1] > 0)

        run_scheduled()
        assert.is_false(Index.isAuditRunning())
        assert.same({ "/books/shelf1/a.epub" }, Index.getInventoryPaths())
    end)

    it("skips system and sidecar directories like the book walker", function()
        for _i, name in ipairs({ "proc", "tmp", "a.sdr" }) do
            attrs["/books/" .. name] = { mode = "directory", modification = 1 }
            entries["/books"][#entries["/books"] + 1] = name
            entries["/books/" .. name] = { ".", ".." }
            add_book("/books/" .. name .. "/x.epub")
        end
        add_book("/books/a.epub")
        local Index = require("common/tbr_index")

        assert.is_true(Index.scheduleAudit())
        run_scheduled()
        assert.same({ "/books/a.epub" }, Index.getInventoryPaths())
    end)

    it("does not rescan a directory reached through a symlink loop", function()
        attrs["/books"].dev, attrs["/books"].ino = 1, 10
        attrs["/books/loop"] = { mode = "directory", modification = 1, dev = 1, ino = 10 }
        entries["/books"][#entries["/books"] + 1] = "loop"
        entries["/books/loop"] = { ".", ".." }
        add_book("/books/a.epub")
        add_book("/books/loop/a.epub")
        local Index = require("common/tbr_index")

        assert.is_true(Index.scheduleAudit())
        run_scheduled()
        assert.is_true(Index.isAuditComplete())
        assert.same({ "/books/a.epub" }, Index.getInventoryPaths())
    end)

    it("reuses a count result for the immediately following page", function()
        add_book("/books/a.epub")
        local Index = require("common/tbr_index")
        local library_lfs = require("libs/libkoreader-lfs")
        local original_attributes = library_lfs.attributes
        local attribute_calls = 0
        library_lfs.attributes = function(...)
            attribute_calls = attribute_calls + 1
            return original_attributes(...)
        end
        local options = { include_new = true, collate = "title" }

        assert.are.equal(1, Index.getCount(options))
        local after_count = attribute_calls
        assert.same({ "/books/a.epub" }, Index.getPage(0, 1, {
            include_new = true,
            collate = "title",
        }))

        assert.are.equal(after_count, attribute_calls)
    end)
end)

describe("shared document cache", function()
    local Cache, directory, database_path, host_lfs, warnings, infos, use_wal
    local originals = {}
    local modules = { "datastorage", "device", "libs/libkoreader-lfs", "common/zen_logger" }

    local function read_file(path)
        local file = assert(io.open(path, "rb"))
        local contents = file:read("*a")
        file:close()
        return contents
    end

    local function write_file(path, contents)
        local file = assert(io.open(path, "wb"))
        file:write(contents)
        file:close()
    end

    local function backups()
        local result = {}
        for name in host_lfs.dir(directory) do
            if name:find(".corrupt-", 1, true) then result[#result + 1] = directory .. "/" .. name end
        end
        return result
    end

    before_each(function()
        for _i, name in ipairs(modules) do originals[name] = package.loaded[name] end
        host_lfs = require("lfs")
        directory = os.tmpname()
        os.remove(directory)
        assert(host_lfs.mkdir(directory))
        database_path = directory .. "/docprops_cache.sqlite"
        warnings = {}
        infos = {}
        use_wal = true
        ZenSpec.replace("datastorage", { getSettingsDir = function() return directory end })
        ZenSpec.replace("device", { canUseWAL = function() return use_wal end })
        ZenSpec.replace("libs/libkoreader-lfs", host_lfs)
        ZenSpec.replace("common/zen_logger", {
            new = function()
                return {
                    warn = function(message) warnings[#warnings + 1] = message end,
                    info = function(message) infos[#infos + 1] = message end,
                }
            end,
        })
        ZenSpec.unload("common/docprops_cache")
        Cache = require("common/docprops_cache")
    end)

    after_each(function()
        Cache.close()
        ZenSpec.unload("common/docprops_cache")
        for _i, backup in ipairs(backups()) do
            for name in host_lfs.dir(backup) do
                if name ~= "." and name ~= ".." then os.remove(backup .. "/" .. name) end
            end
            host_lfs.rmdir(backup)
        end
        for name in host_lfs.dir(directory) do
            if name ~= "." and name ~= ".." then os.remove(directory .. "/" .. name) end
        end
        host_lfs.rmdir(directory)
        for _i, name in ipairs(modules) do package.loaded[name] = originals[name] end
    end)

    it("shares one journaled connection and rolls back both cache tables", function()
        local first = Cache.withDB(function(db) return db end)
        local second = Cache.withDB(function(db) return db end)
        assert.are.equal(first, second)
        assert.are.equal("wal", first:exec("PRAGMA journal_mode")[1][1])
        assert.are.equal(1, tonumber(first:exec("PRAGMA synchronous")[1][1]))
        first:exec([[
            BEGIN;
            INSERT INTO doc_props_cache VALUES ('book', '{}', 1);
            INSERT INTO zen_doc_status_cache (path, signature) VALUES ('book', '1');
            ROLLBACK;
        ]])
        assert.are.equal(0, tonumber(first:exec("SELECT count(*) FROM doc_props_cache")[1][1]))
        assert.are.equal(0, tonumber(first:exec("SELECT count(*) FROM zen_doc_status_cache")[1][1]))
        assert.same({}, warnings)
    end)

    it("scans integrity once per process and re-verifies a removed file", function()
        local sqlite3 = require("lua-ljsqlite3/init")
        local open, checks = sqlite3.open, 0
        sqlite3.open = function(path)
            local db = open(path)
            return {
                exec = function(_self, sql)
                    if sql:find("quick_check", 1, true) then checks = checks + 1 end
                    return db:exec(sql)
                end,
                prepare = function(_self, sql) return db:prepare(sql) end,
                close = function() db:close() end,
            }
        end
        local function count()
            return Cache.withDB(function(db)
                return tonumber(db:exec("SELECT count(*) FROM doc_props_cache")[1][1])
            end)
        end
        local ok, err = pcall(function()
            assert.are.equal(0, count())
            Cache.close()
            assert.are.equal(0, count())
            assert.are.equal(1, checks)
            Cache.close()
            for name in host_lfs.dir(directory) do
                if name ~= "." and name ~= ".." then os.remove(directory .. "/" .. name) end
            end
            assert.are.equal(0, count())
            assert.are.equal(2, checks)
        end)
        sqlite3.open = open
        assert(ok, err)
    end)

    it("uses full syncing when WAL is unavailable", function()
        use_wal = false
        Cache.withDB(function(db)
            assert.are.equal("truncate", db:exec("PRAGMA journal_mode")[1][1])
            assert.are.equal(2, tonumber(db:exec("PRAGMA synchronous")[1][1]))
        end)
    end)

    it("enables journaling on a healthy legacy cache without losing its metadata", function()
        local legacy = require("lua-ljsqlite3/init").open(database_path)
        legacy:exec([[
            PRAGMA journal_mode = OFF;
            PRAGMA synchronous = OFF;
            CREATE TABLE doc_props_cache (cache_key TEXT PRIMARY KEY, props TEXT, created_at INTEGER);
            INSERT INTO doc_props_cache VALUES ('book', '{}', 1);
        ]])
        legacy:close()
        Cache.withDB(function(db)
            assert.are.equal("wal", db:exec("PRAGMA journal_mode")[1][1])
            assert.are.equal(1, tonumber(db:exec("PRAGMA synchronous")[1][1]))
            assert.are.equal("{}", db:exec("SELECT props FROM doc_props_cache")[1][1])
        end)
        assert.same({}, backups())
    end)

    it("preserves a broken database and persists fresh metadata after reopening", function()
        write_file(database_path, "not a SQLite database")
        Cache.withDB(function(db)
            db:exec("INSERT INTO doc_props_cache VALUES ('book', '{\"title\":\"Book\"}', 1)")
        end)
        assert.are.equal(1, #backups())
        assert.are.equal("not a SQLite database", read_file(backups()[1] .. "/docprops_cache.sqlite"))
        assert.are.equal("Cache corruption detected:", warnings[1])
        assert.same({ "Cache rebuilt:" }, infos)
        Cache.close()
        Cache.withDB(function(db)
            assert.are.equal("ok", db:exec("PRAGMA quick_check")[1][1])
            assert.are.equal('{"title":"Book"}', db:exec("SELECT props FROM doc_props_cache")[1][1])
        end)
        assert.are.equal(1, #backups())
    end)

    it("closes the old shared handle before retrying after corruption", function()
        local old = Cache.withDB(function(db) return db end)
        local calls = 0
        Cache.withDB(function(db)
            calls = calls + 1
            if calls == 1 then error("ljsqlite3[corrupt] database disk image is malformed") end
            assert.is_true(old._closed)
            assert.are_not.equal(old, db)
            db:exec("INSERT INTO doc_props_cache VALUES ('book', '{}', 1)")
        end)
        assert.are.equal(2, calls)
        assert.are.equal(1, #backups())
    end)

    it("keeps remaining journal files with the preserved database", function()
        write_file(database_path, "not a SQLite database")
        write_file(database_path .. "-journal", "journal evidence")
        write_file(database_path .. "-wal", "wal evidence")
        write_file(database_path .. "-shm", "shm evidence")
        local sqlite3 = require("lua-ljsqlite3/init")
        local open = sqlite3.open
        local closed
        sqlite3.open = function(path)
            if path == database_path and not closed then
                return {
                    exec = function() error("ljsqlite3[corrupt] malformed") end,
                    close = function() closed = true end,
                }
            end
            return open(path)
        end
        local ok, err = pcall(Cache.withDB, function(db)
            assert.are.equal("ok", db:exec("PRAGMA quick_check")[1][1])
        end)
        sqlite3.open = open
        assert.is_true(ok, err)
        assert.are.equal("journal evidence", read_file(backups()[1] .. "/docprops_cache.sqlite-journal"))
        assert.are.equal("wal evidence", read_file(backups()[1] .. "/docprops_cache.sqlite-wal"))
        assert.are.equal("shm evidence", read_file(backups()[1] .. "/docprops_cache.sqlite-shm"))
        assert.is_nil(host_lfs.attributes(database_path .. "-journal"))
    end)

    it("does not replace a database on a locking error", function()
        Cache.withDB(function(db) db:exec("INSERT INTO doc_props_cache VALUES ('book', '{}', 1)") end)
        Cache.close()
        local original = read_file(database_path)
        assert.has_error(function()
            Cache.withDB(function() error("ljsqlite3[busy] database is locked", 0) end)
        end, "ljsqlite3[busy] database is locked")
        assert.are.equal("Cache operation failed:", warnings[#warnings])
        assert.same({}, backups())
        assert.are.equal(original, read_file(database_path))
        Cache.close()
        assert.are.equal("{}", Cache.withDB(function(db)
            return db:exec("SELECT props FROM doc_props_cache")[1][1]
        end))
    end)

    it("leaves the corrupt database intact if preserving it fails", function()
        write_file(database_path, "not a SQLite database")
        local mkdir = host_lfs.mkdir
        host_lfs.mkdir = function() return nil, "Permission denied" end
        local ok, err = pcall(Cache.withDB, function() return true end)
        host_lfs.mkdir = mkdir
        assert.is_false(ok)
        assert.matches("Permission denied", err)
        assert.same({}, backups())
        assert.are.equal("not a SQLite database", read_file(database_path))
        assert.are.equal("Cache recovery failed:", warnings[#warnings])
        assert.same({}, infos)
    end)

    it("leaves the corrupt database intact if renaming it fails", function()
        write_file(database_path, "not a SQLite database")
        local rename = os.rename
        rawset(os, "rename", function() return nil, "Permission denied" end)
        local ok, err = pcall(Cache.withDB, function() return true end)
        rawset(os, "rename", rename)
        assert.is_false(ok)
        assert.matches("Permission denied", err)
        assert.same({}, backups())
        assert.are.equal("not a SQLite database", read_file(database_path))
    end)

    it("logs and propagates failure if corruption remains after rebuilding once", function()
        local calls = 0
        assert.has_error(function()
            Cache.withDB(function()
                calls = calls + 1
                error("ljsqlite3[corrupt] persistent corruption", 0)
            end)
        end, "ljsqlite3[corrupt] persistent corruption")
        assert.are.equal(2, calls)
        assert.are.equal(1, #backups())
        assert.are.equal("Cache recovery failed:", warnings[#warnings])
        assert.is_true(Cache.withDB(function() return true end))
    end)

    it("keeps previous backups when corruption recurs", function()
        local date = os.date
        rawset(os, "date", function() return "20261011-200000" end)
        for i = 1, 2 do
            write_file(database_path, "broken cache " .. i)
            Cache.withDB(function(db) return db end)
            Cache.close()
        end
        rawset(os, "date", date)
        assert.are.equal(2, #backups())
        local base = database_path .. ".corrupt-20261011-200000"
        assert.are.equal("broken cache 1", read_file(base .. "/docprops_cache.sqlite"))
        assert.are.equal("broken cache 2", read_file(base .. "-1/docprops_cache.sqlite"))
    end)

    it("propagates application errors without treating them as corruption", function()
        assert.has_error(function()
            Cache.withDB(function() error("metadata failure", 0) end)
        end, "metadata failure")
        assert.same({}, backups())
        assert.same({}, warnings)
    end)

    it("propagates application errors after a successful rebuild", function()
        write_file(database_path, "not a SQLite database")
        assert.has_error(function()
            Cache.withDB(function() error("metadata failure", 0) end)
        end, "metadata failure")
        assert.are.equal(1, #backups())
        assert.are_not.equal("Cache unavailable:", warnings[#warnings])
    end)
end)
