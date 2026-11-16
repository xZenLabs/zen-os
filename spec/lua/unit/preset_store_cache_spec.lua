require("ffi/loadlib")
describe("preset store parse cache", function()
    local lfs = require("libs/libkoreader-lfs")
    local originals, root, opens, PresetStore

    before_each(function()
        originals = {}
        for _i, name in ipairs({ "datastorage", "common/brand_migration", "luasettings", "config/preset_store" }) do
            originals[name] = { value = package.loaded[name] }
        end
        local LuaSettings = require("luasettings")
        root = os.tmpname()
        os.remove(root)
        assert.is_true(lfs.mkdir(root))
        opens = 0
        ZenSpec.replace("datastorage", { getSettingsDir = function() return root end })
        ZenSpec.replace("common/brand_migration", {
            preparedSettings = function() end,
            prepareSettings = function() return { root = root } end,
        })
        ZenSpec.replace("luasettings", setmetatable({
            open = function(_self, path)
                opens = opens + 1
                return LuaSettings:open(path)
            end,
        }, { __index = LuaSettings }))
        ZenSpec.unload("config/preset_store")
        PresetStore = require("config/preset_store")
    end)

    after_each(function()
        for _i, kind in ipairs({ "reader", "home" }) do
            os.remove(root .. "/" .. kind .. ".lua")
            os.remove(root .. "/" .. kind .. ".lua.old")
        end
        lfs.rmdir(root)
        for name, saved in pairs(originals) do package.loaded[name] = saved.value end
    end)

    it("parses a store once until it is saved", function()
        assert.is_true(PresetStore.saveStore("reader", { settings = { a = 1 }, presets = {}, active_preset = "Zen" }))
        opens = 0

        assert.are.equal("Zen", PresetStore.getActivePreset("reader"))
        assert.are.equal(1, PresetStore.getSettings("reader").a)
        assert.are.equal("Zen", PresetStore.getActivePreset("reader"))
        assert.are.equal(1, opens)

        assert.is_true(PresetStore.setActivePreset("reader", "Other"))
        opens = 0
        assert.are.equal("Other", PresetStore.getActivePreset("reader"))
        assert.are.equal(1, opens)
    end)

    it("returns private copies so unsaved edits never leak into the cache", function()
        assert.is_true(PresetStore.saveStore("reader", { settings = { a = 1 }, presets = {} }))
        local store = PresetStore.loadStore("reader")
        store.settings.a = 2
        store.presets.Draft = { name = "Draft" }

        assert.are.equal(1, PresetStore.getSettings("reader").a)
        assert.is_nil(PresetStore.find("reader", "Draft"))
        local settings = PresetStore.getSettings("reader")
        settings.a = 3
        assert.are.equal(1, PresetStore.getSettings("reader").a)
    end)

    it("seeds the read cache from ensureStore and builds defaults only for new stores", function()
        local built = 0
        local function initial()
            built = built + 1
            return { a = 1 }
        end
        assert.is_true(PresetStore.ensureStore("home", initial))
        assert.are.equal(1, built)

        opens = 0
        assert.is_false(PresetStore.ensureStore("home", initial))
        assert.are.equal(1, PresetStore.getSettings("home").a)
        assert.is_false(PresetStore.ensureStore("home", initial))
        assert.are.equal(1, built)
        assert.are.equal(1, opens)
    end)
end)
