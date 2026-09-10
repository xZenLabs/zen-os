describe("TBR path inventory", function()
    local test_dir
    local attrs
    local entries
    local sidecars
    local docs
    local opens
    local open_fail
    local config
    local ReadCollection
    local scheduled
    local collection_writes
    local updated_collection_order
    local arrange_options
    local view_refreshes

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
        docs = {}
        opens = 0
        open_fail = nil
        scheduled = {}
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
                local attr = attrs[path]
                return key and attr and attr[key] or attr
            end,
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
            findSidecarFile = function(_self, path) return sidecars[path] end,
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
        ZenSpec.replace("common/title_sort", { key = function(value) return value end })
        ZenSpec.replace("ui/uimanager", {
            nextTick = function(_self, fn) scheduled[#scheduled + 1] = fn end,
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
        local tick = 0
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
    end)

    after_each(function()
        local index = package.loaded["common/tbr_index"]
        if index and index.close then index.close() end
        ZenSpec.unload("common/tbr_index")
        os.remove(test_dir .. "/docprops_cache.sqlite")
        os.remove(test_dir .. "/docprops_cache.sqlite-journal")
        os.remove(test_dir .. "/docprops_cache.sqlite-wal")
        os.remove(test_dir .. "/docprops_cache.sqlite-shm")
        require("lfs").rmdir(test_dir)
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
end)
