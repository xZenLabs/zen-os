describe("book info document property cache", function()
    local BookInfo, open_calls
    local module_names = {
        "apps/filemanager/filemanagerbookinfo",
        "apps/filemanager/filemanagerutil",
        "common/docprops_cache",
        "docsettings",
        "document/document",
        "document/documentregistry",
        "libs/libkoreader-lfs",
        "rapidjson",
        "ui/widget/booklist",
    }
    local originals = {}

    before_each(function()
        for _i, name in ipairs(module_names) do originals[name] = package.loaded[name] end
        open_calls = 0

        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function() return { size = 123, modification = 456 } end,
        })
        ZenSpec.replace("common/docprops_cache", {
            withDB = function(callback)
                return callback({
                    prepare = function()
                        return {
                            bind = function(self) return self end,
                            step = function() return { "cached" } end,
                            reset = function(self) return self end,
                            clearbind = function(self) return self end,
                            close = function() end,
                        }
                    end,
                })
            end,
        })
        ZenSpec.replace("rapidjson", {
            decode = function() return { title = "The Egg" } end,
            encode = function() return "cached" end,
        })
        ZenSpec.replace("document/documentregistry", {
            known_providers = {},
            getProviders = function()
                return { { provider = { provider = "crengine" } } }
            end,
            getAssociatedProviderKey = function() end,
            hasProvider = function() return true end,
            openDocument = function()
                open_calls = open_calls + 1
            end,
        })
        BookInfo = {
            ui = {},
            extendProps = function(props) return props or {} end,
        }
        ZenSpec.replace("apps/filemanager/filemanagerbookinfo", BookInfo)
        ZenSpec.replace("apps/filemanager/filemanagerutil", {
            splitFileNameType = function() return "book" end,
        })
        ZenSpec.replace("ui/widget/booklist", {
            hasBookBeenOpened = function() return false end,
        })
        ZenSpec.replace("docsettings", {
            findCustomMetadataFile = function() end,
        })
        ZenSpec.replace("document/document", {})

        ZenSpec.unload("modules/filebrowser/patches/cache_bookinfo_get_doc_props")
        require("modules/filebrowser/patches/cache_bookinfo_get_doc_props")()
    end)

    after_each(function()
        ZenSpec.unload("modules/filebrowser/patches/cache_bookinfo_get_doc_props")
        for _i, name in ipairs(module_names) do package.loaded[name] = originals[name] end
    end)

    it("prunes older file versions by key range with reused statements", function()
        local prepared, binds = {}, {}
        local db = {
            prepare = function(_db, sql)
                prepared[#prepared + 1] = sql
                return {
                    bind = function(self, ...) binds[sql] = { ... }; return self end,
                    step = function() return nil end,
                    reset = function(self) return self end,
                    clearbind = function(self) return self end,
                }
            end,
        }
        require("common/docprops_cache").withDB = function(callback) return callback(db) end

        BookInfo:getDocProps("/books/book.epub")
        BookInfo:getDocProps("/books/book.epub")

        assert.are.equal(3, #prepared)
        local prune = prepared[3]
        assert.matches("cache_key >= %? AND cache_key < %?", prune)
        assert.is_nil(prune:find("substr(cache_key, 1", 1, true))
        assert.are.same({ "/books/book.epub_", "/books/book.epub_\255", 18,
            "/books/book.epub_123_456" }, binds[prune])
    end)

    it("uses cached titles without opening books during search", function()
        local props = BookInfo:getDocProps("/books/book.epub", nil, true)

        assert.are.equal("The Egg", props.title)
        assert.are.equal(0, open_calls)
    end)
end)
