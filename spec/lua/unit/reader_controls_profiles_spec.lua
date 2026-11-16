describe("reader profile integration", function()
    local Profiles, reader, dispatcher, original_modules, applied, plugin
    local modules = { "common/reader_themes", "modules/menu/reader_controls/settings", "dispatcher",
        "apps/reader/readerui", "modules/menu/reader_controls/profiles", "ui/uimanager", "ui/widget/infomessage" }
    before_each(function()
        original_modules, applied = {}, {}
        for _i, name in ipairs(modules) do original_modules[name] = package.loaded[name] end
        reader = {
            document = { configurable = { font_size = 23, auto_straighten = 5 } },
            doc_settings = ZenSpec.memorySettings({ text_lang = "en", last_xpointer = "secret", annotations = { "note" } }),
            saveSettings = function() end,
            profiles = { getProfileFromCurrentBookSettings = function(_self, name)
                return { font_size = 23, settings = { name = name, order = { "font_size" } } }
            end },
        }
        plugin = { config = {} }
        ZenSpec.replace("modules/menu/reader_controls/settings", {
            group = function() return "copt" end,
            options = function() return { font_size = {}, auto_straighten = {} } end,
            apply = function(_reader, name, value) applied[#applied + 1] = { name, value } end,
        })
        ZenSpec.replace("common/reader_themes", {
            capture = function() return { enabled = true, light_mode = { text = "#000000", background = "#ffffff" } } end,
            restore = function(_plugin, theme) applied[#applied + 1] = { "theme", theme } end,
        })
        dispatcher = { execute = function(_self, actions) applied[#applied + 1] = { "native", actions.font_size } end }
        ZenSpec.replace("dispatcher", dispatcher)
        ZenSpec.replace("apps/reader/readerui", { instance = reader })
        ZenSpec.replace("ui/uimanager", {
            show = function() applied[#applied + 1] = { "incompatible" } end,
            broadcastEvent = function(_self, event) applied[#applied + 1] = { event.handler } end,
        })
        ZenSpec.replace("ui/widget/infomessage", { new = function(_self, args) return args end })
        ZenSpec.unload("modules/menu/reader_controls/profiles")
        Profiles = require("modules/menu/reader_controls/profiles")
    end)
    after_each(function()
        for _i, name in ipairs(modules) do package.loaded[name] = original_modules[name] end
    end)

    it("captures uncatalogued presentation options without progress or annotations", function()
        local profile = Profiles.capture(reader, plugin, "Test", true)
        assert.are.same({ auto_straighten = 5 }, profile.settings.zen_reader.values)
        assert.are.equal("en", profile.settings.zen_reader.book.text_lang.value)
        assert.is_nil(profile.settings.zen_reader.book.last_xpointer)
        assert.is_nil(profile.settings.zen_reader.book.annotations)
        assert.is_true(profile.settings.zen_reader.theme.enabled)
        reader.doc_settings.data.text_lang = "fr"
        assert.are.equal("en", profile.settings.zen_reader.book.text_lang.value)
    end)

    it("can omit themes without changing the global theme", function()
        local profile = Profiles.capture(reader, plugin, "Test", false)
        assert.is_nil(profile.settings.zen_reader.theme)
        Profiles.restore(reader, plugin, profile.settings.zen_reader)
        assert.are.same({ { "auto_straighten", 5 } }, applied)
    end)

    it("restores supplemental settings before native profile edits in one batch", function()
        local profile = Profiles.capture(reader, plugin, "Test", true)
        profile.font_size = 31
        Profiles.install(plugin)
        dispatcher:execute(profile)
        assert.are.same({ "onBatchedUpdate" }, applied[1])
        assert.are.same({ "auto_straighten", 5 }, applied[2])
        assert.are.equal("theme", applied[3][1])
        assert.are.same({ "native", 31 }, applied[4])
        assert.are.same({ "onBatchedUpdateDone" }, applied[5])
    end)

    it("does not apply a snapshot when only opening its QuickMenu", function()
        local profile = Profiles.capture(reader, plugin, "Test", true)
        Profiles.install(plugin)
        dispatcher:execute(profile, { qm_show = true })
        assert.are.same({ { "native", 23 } }, applied)
    end)

    it("rejects a snapshot for an incompatible rendering engine", function()
        local profile = Profiles.capture(reader, plugin, "Test", true)
        profile.settings.zen_reader.group = "kopt"
        Profiles.install(plugin)
        dispatcher:execute(profile)
        assert.are.same({ { "incompatible" } }, applied)
    end)

    it("leaves ordinary native profiles unchanged", function()
        Profiles.install(plugin)
        dispatcher:execute({ font_size = 27, settings = {} })
        assert.are.same({ { "native", 27 } }, applied)
    end)

    it("ignores unknown or incorrectly typed supplemental configuration", function()
        local snapshot = { version = 1, group = "copt", values = { auto_straighten = "bad", injected = true }, book = {} }
        assert.is_true(Profiles.restore(reader, plugin, snapshot))
        assert.are.same({}, applied)
    end)
end)
