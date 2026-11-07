describe("filebrowser optional provider initialization", function()
    local names = { "modules/filebrowser/patches/rakuyomi", "modules/filebrowser/patches/kindle_virtual_library" }
    local saved, preloads

    before_each(function()
        saved, preloads = {}, {}
        for _i, name in ipairs(names) do
            saved[name], preloads[name] = package.loaded[name], package.preload[name]
        end
    end)

    after_each(function()
        for _i, name in ipairs(names) do
            package.loaded[name], package.preload[name] = saved[name], preloads[name]
        end
    end)

    local function verify_startup()
        local applied = {}
        local globals = {}
        local chunk = assert(loadfile(ZenSpec.root .. "/modules/filebrowser/filebrowser.lua"))
        setfenv(chunk, setmetatable({ _G = globals, require = function(name)
            if name == "common/optional_provider" then return require(name) end
            for _i, provider in ipairs(names) do
                if name == provider then return require(name) end
            end
            return function() applied[name] = true end
        end }, { __index = _G }))
        local Filebrowser = chunk()
        local logger = { warn = function() end }
        assert.is_true(Filebrowser.init(logger, { config = { features = { navbar = true } } }))
        assert.is_true(applied["modules/filebrowser/patches/home_page"])
        assert.is_true(applied["modules/filebrowser/patches/navbar"])
        assert.is_nil(globals.__ZEN_UI_PLUGIN)
    end

    it("loads Home and navigation when provider modules cannot load", function()
        for _i, name in ipairs(names) do
            package.loaded[name] = nil
            package.preload[name] = function() error("provider failed to load") end
        end
        verify_startup()
    end)

    it("loads Home and navigation when provider initialization and availability fail", function()
        local function failed() error("provider did not initialize") end
        for _i, name in ipairs(names) do
            package.loaded[name] = { apply = failed, installMetadataIntegration = failed, is_available = failed }
        end
        verify_startup()
    end)
end)
