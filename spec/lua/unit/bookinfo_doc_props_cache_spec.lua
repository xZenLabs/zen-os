describe("book info document property cache", function()
    local BookInfo, open_calls
    local module_names = {
        "apps/filemanager/filemanagerbookinfo",
        "apps/filemanager/filemanagerutil",
        "datastorage",
        "docsettings",
        "document/document",
        "document/documentregistry",
        "libs/libkoreader-lfs",
        "lua-ljsqlite3/init",
        "rapidjson",
    }
    local originals = {}

    before_each(function()
        for _i, name in ipairs(module_names) do originals[name] = package.loaded[name] end
        open_calls = 0

        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function() return { size = 123, modification = 456 } end,
        })
        ZenSpec.replace("lua-ljsqlite3/init", {
            open = function()
                return {
                    exec = function() end,
                    prepare = function()
                        return {
                            bind = function() end,
                            step = function() return { "cached" } end,
                            clearbind = function(self) return self end,
                            reset = function(self) return self end,
                        }
                    end,
                }
            end,
        })
        ZenSpec.replace("rapidjson", {
            decode = function() return { title = "The Egg" } end,
            encode = function() return "cached" end,
        })
        ZenSpec.replace("datastorage", {
            getSettingsDir = function() return "/settings" end,
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

    it("uses cached titles without opening books during search", function()
        local props = BookInfo:getDocProps("/books/book.epub", nil, true)

        assert.are.equal("The Egg", props.title)
        assert.are.equal(0, open_calls)
    end)
end)
