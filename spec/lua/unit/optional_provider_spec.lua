describe("optional provider calls", function()
    local OptionalProvider, warnings

    before_each(function()
        warnings = {}
        local chunk = assert(loadfile(ZenSpec.root .. "/common/optional_provider.lua"))
        setfenv(chunk, setmetatable({ require = function(name)
            if name == "common/zen_logger" then
                return { new = function() return { warn = function(...)
                    warnings[#warnings + 1] = { ... }
                end } end }
            end
            if name == "loaded-provider" then return { isAvailable = function() return false end } end
            error("provider failed to load: " .. name)
        end }, { __index = _G }))
        OptionalProvider = chunk()
    end)

    it("preserves false results and arguments including nil", function()
        assert.is_false(OptionalProvider.call("loaded-provider", "isAvailable"))
        local provider = { getBook = function(self, path, cover, count)
            assert.equals("book.epub", path)
            assert.is_nil(cover)
            assert.equals(4, count)
            return self
        end }
        assert.equals(provider, OptionalProvider.call(provider, "getBook", provider, "book.epub", nil, 4))
        assert.equals(0, #warnings)
    end)

    it("logs load and callback errors without propagating them", function()
        assert.is_nil(OptionalProvider.call("missing-provider", "getBooks"))
        assert.is_nil(OptionalProvider.call({ getBooks = function() error("not initialized") end }, "getBooks"))
        assert.equals(2, #warnings)
        assert.matches("missing-provider", warnings[1][4], 1, true)
        assert.matches("not initialized", warnings[2][4], 1, true)
    end)

    it("ignores unavailable methods and incomplete providers", function()
        for _i, provider in ipairs({ false, true, {}, { getBooks = true } }) do
            assert.is_nil(OptionalProvider.call(provider, "getBooks"))
        end
        assert.equals(0, #warnings)
    end)
end)
