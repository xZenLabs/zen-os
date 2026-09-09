describe("Hardcover token store", function()
    local Store
    local lfs = require("libs/libkoreader-lfs")
    local root
    local saved = {}

    before_each(function()
        root = os.tmpname()
        os.remove(root)
        assert.is_true(lfs.mkdir(root))
        for _i, name in ipairs({
            "config/hardcover_token", "config/preset_store", "ffi/util",
        }) do
            saved[name] = package.loaded[name] or false
        end
        ZenSpec.replace("config/preset_store", { rootDir = function() return root end })
        ZenSpec.replace("ffi/util", {
            dirname = function() return root end,
            fsyncOpenedFile = function() return true end,
            fsyncDirectory = function() return true end,
        })
        ZenSpec.unload("config/hardcover_token")
        Store = require("config/hardcover_token")
    end)

    after_each(function()
        for _i, name in ipairs({
            "hardcover_token.txt", "hardcover_token.txt.zen-write",
        }) do
            os.remove(root .. "/" .. name)
        end
        lfs.rmdir(root)
        for name, module in pairs(saved) do package.loaded[name] = module or nil end
        saved = {}
    end)

    it("stores only the token in a dedicated plaintext file", function()
        assert.is_true(Store.ensureFile())
        local placeholder = assert(io.open(Store.path(), "rb"))
        assert.are.equal("", placeholder:read("*a"))
        placeholder:close()

        assert.is_true(Store.save("catalog-token"))
        assert.are.equal("catalog-token", Store.get())
        if require("ffi").os ~= "Windows" then
            assert.are.equal("rw-------", lfs.attributes(Store.path(), "permissions"))
        end
        local file = assert(io.open(Store.path(), "rb"))
        assert.are.equal("catalog-token\n", file:read("*a"))
        file:close()

        assert.is_true(Store.clear())
        assert.are.equal("", Store.get())
    end)
end)
