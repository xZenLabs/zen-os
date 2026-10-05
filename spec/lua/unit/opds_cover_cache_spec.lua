local lfs = require("lfs")

describe("OPDS cover disk cache", function()
    local Cache, directory, originals
    local modules = { "common/opds_cover_cache", "datastorage", "util", "libs/libkoreader-lfs" }

    before_each(function()
        originals = {}
        for _i, name in ipairs(modules) do originals[name] = package.loaded[name] end
        directory = os.tmpname()
        os.remove(directory)
        assert(lfs.mkdir(directory))
        ZenSpec.replace("datastorage", { getDataDir = function() return directory end })
        ZenSpec.replace("libs/libkoreader-lfs", lfs)
        ZenSpec.replace("util", { makePath = function(path)
            lfs.mkdir(directory .. "/cache")
            lfs.mkdir(path)
        end })
        ZenSpec.unload("common/opds_cover_cache")
        Cache = require("common/opds_cover_cache")
    end)

    after_each(function()
        local path = directory .. "/cache/zen-opds-covers"
        if lfs.attributes(path) then
            for name in lfs.dir(path) do
                if name ~= "." and name ~= ".." then os.remove(path .. "/" .. name) end
            end
            lfs.rmdir(path)
            lfs.rmdir(directory .. "/cache")
        end
        lfs.rmdir(directory)
        for _i, name in ipairs(modules) do package.loaded[name] = originals[name] end
    end)

    it("persists across reloads and isolates servers and credentials", function()
        local creds = { url = "https://example.test/opds", username = "user", password = "secret" }
        local key = Cache.key("https://example.test/cover", creds)
        Cache.put(key, "cover bytes")
        ZenSpec.unload("common/opds_cover_cache")
        Cache = require("common/opds_cover_cache")
        assert.are.equal("cover bytes", Cache.get(key))
        assert.is_nil(Cache.get(Cache.key("https://example.test/cover", {
            url = creds.url, username = "other", password = "secret",
        })))
        assert.is_nil(Cache.get(Cache.key("https://example.test/cover", {
            url = "https://another.test/opds", username = "user", password = "secret",
        })))
        assert.is_nil(Cache.get(Cache.key("https://example.test/cover", {
            url = creds.url, username = "user", password = "changed",
        })))
        assert.is_nil(key:find("secret", 1, true))
    end)

    it("evicts the least recently used bytes when over budget", function()
        Cache.MAX_BYTES = 6
        local first, second, third = Cache.key("first"), Cache.key("second"), Cache.key("third")
        Cache.put(first, "aaa")
        Cache.put(second, "bbb")
        assert.are.equal("aaa", Cache.get(first))
        Cache.put(third, "ccc")
        assert.are.equal("aaa", Cache.get(first))
        assert.is_nil(Cache.get(second))
        assert.are.equal("ccc", Cache.get(third))
    end)

    it("expires old images and clears only the requested server account", function()
        local first, second = { url = "https://one.test" }, { url = "https://two.test" }
        local expired = Cache.key("old", first)
        local current = Cache.key("current", first)
        local other = Cache.key("current", second)
        Cache.put(expired, "old")
        Cache.put(current, "current")
        Cache.put(other, "other")
        assert(lfs.touch(directory .. "/cache/zen-opds-covers/" .. expired,
            os.time() - Cache.MAX_AGE - 1, os.time() - Cache.MAX_AGE - 1))
        ZenSpec.unload("common/opds_cover_cache")
        Cache = require("common/opds_cover_cache")
        assert.is_nil(Cache.get(expired))
        Cache.clear(first)
        assert.is_nil(Cache.get(current))
        assert.are.equal("other", Cache.get(other))
    end)
end)
