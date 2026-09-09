describe("Google Books API key store", function()
    local Store
    local lfs = require("libs/libkoreader-lfs")
    local root
    local saved = {}

    before_each(function()
        root = os.tmpname()
        os.remove(root)
        assert.is_true(lfs.mkdir(root))
        for _i, name in ipairs({
            "config/credential_file", "config/google_books_key",
            "config/preset_store", "ffi/util",
        }) do
            saved[name] = package.loaded[name] or false
        end
        ZenSpec.replace("config/preset_store", { rootDir = function() return root end })
        ZenSpec.replace("ffi/util", {
            dirname = function() return root end,
            fsyncOpenedFile = function() return true end,
            fsyncDirectory = function() return true end,
        })
        ZenSpec.unload("config/credential_file")
        ZenSpec.unload("config/google_books_key")
        Store = require("config/google_books_key")
    end)

    after_each(function()
        for _i, name in ipairs({
            "google_books_api_key.txt", "google_books_api_key.txt.zen-write",
        }) do
            os.remove(root .. "/" .. name)
        end
        lfs.rmdir(root)
        for name, module in pairs(saved) do package.loaded[name] = module or nil end
        saved = {}
    end)

    it("stores only the key in its dedicated plaintext file", function()
        assert.are.equal(root .. "/google_books_api_key.txt", Store.path())
        assert.is_true(Store.ensureFile())
        assert.is_true(Store.save("AIza-test-key"))
        assert.are.equal("AIza-test-key", Store.get())

        local file = assert(io.open(Store.path(), "rb"))
        assert.are.equal("AIza-test-key\n", file:read("*a"))
        file:close()

        local saved_key, err = Store.save("bad key")
        assert.is_nil(saved_key)
        assert.are.equal("invalid Google Books API key", err)
        assert.is_true(Store.clear())
        assert.are.equal("", Store.get())
    end)
end)
