describe("ZenOS translations", function()
    local saved_gettext
    local saved_logger
    local saved_settings
    local GetText
    local methods
    local warnings

    before_each(function()
        saved_gettext = package.loaded["gettext"]
        saved_logger = package.loaded["common/zen_logger"]
        saved_settings = _G.G_reader_settings

        methods = {}
        GetText = {
            context = {},
            translation = {},
            current_lang = "pt_BR",
        }
        methods.changeLang = function(language)
            GetText.context = {}
            GetText.translation = {}
            GetText.current_lang = language
            return true
        end
        setmetatable(GetText, {
            __index = methods,
            __call = function(self, msgid)
                return self.translation[msgid] or msgid
            end,
        })

        package.loaded["gettext"] = GetText
        warnings = {}
        package.loaded["common/zen_logger"] = {
            new = function()
                return {
                    info = function() end,
                    warn = function(message)
                        table.insert(warnings, message)
                    end,
                }
            end,
        }
        _G.G_reader_settings = ZenSpec.memorySettings({ language = "pt_BR" })
        ZenSpec.unload("common/i18n")
    end)

    after_each(function()
        local I18n = package.loaded["common/i18n"]
        if I18n then I18n.uninstall() end
        ZenSpec.unload("common/i18n")
        package.loaded["gettext"] = saved_gettext
        package.loaded["common/zen_logger"] = saved_logger
        _G.G_reader_settings = saved_settings
    end)

    it("restores Brazilian Portuguese labels after the live table is cleared", function()
        local I18n = require("common/i18n")
        I18n.install()
        assert.are.equal("Biblioteca", GetText("Library"))
        assert.are.equal("Barra de navegação", GetText("Navbar"))
        assert.are.equal("Adicionais", GetText("Extras"))

        GetText.translation = {}
        assert.are.equal("Library", GetText("Library"))
        assert.is_true(I18n.refresh())
        assert.are.equal("Biblioteca", GetText("Library"))
        assert.are.equal("Barra de navegação", GetText("Navbar"))
        assert.are.equal("Adicionais", GetText("Extras"))
    end)

    it("reapplies translations when install is called after a shared-table reset", function()
        local I18n = require("common/i18n")
        I18n.install()
        GetText.translation = {}

        assert.is_true(I18n.install())
        assert.are.equal("Biblioteca", GetText("Library"))
    end)

    it("silently uses English source strings for the C locale", function()
        _G.G_reader_settings:saveSetting("language", "C")

        local I18n = require("common/i18n")
        assert.is_true(I18n.install())
        assert.are.equal("Library", package.loaded["gettext"]("Library"))
        assert.are.same({}, warnings)
    end)

    it("patches KOReader gettext behind another plugin wrapper", function()
        local wrapper = setmetatable({}, {
            __call = function(_self, msgid)
                if msgid == "About" then return "Sobre" end
                if msgid == "Library" then return "Biblioteca externa" end
                return GetText(msgid)
            end,
            __index = GetText,
        })
        package.loaded["gettext"] = wrapper

        local I18n = require("common/i18n")
        I18n.install()
        assert.are.equal("Sobre", wrapper("About"))
        assert.are.equal("Biblioteca externa", wrapper("Library"))
        assert.are.equal("Biblioteca", package.loaded["gettext"]("Library"))

        methods.changeLang("pt_BR")
        assert.are.equal("Biblioteca", package.loaded["gettext"]("Library"))
    end)

    it("forwards another plugin's gettext state restoration", function()
        local I18n = require("common/i18n")
        I18n.install()
        local wrapper = package.loaded["gettext"]
        GetText.translation["External label"] = "Rótulo externo"
        local original_translation = wrapper.translation

        wrapper.changeLang("pt_BR")
        wrapper.translation = original_translation

        assert.are.equal("Rótulo externo", wrapper("External label"))
    end)
end)
