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

    it("parses each catalog once and only re-injects on refresh", function()
        local cache = require("datastorage"):getDataDir() .. "/cache/zen-i18n-"
        os.remove(cache .. "pt_BR.lua")
        os.remove(cache .. "pt_PT.lua")
        local opened = {}
        local open = io.open
        rawset(io, "open", function(path, ...)
            if type(path) == "string" and path:match("%.po$") then opened[#opened + 1] = path end
            return open(path, ...)
        end)
        local ok, err = pcall(function()
            local I18n = require("common/i18n")
            I18n.install()
            GetText.translation = {}
            assert.is_true(I18n.refresh())
            assert.is_true(I18n.refresh())
            assert.are.equal("Biblioteca", GetText("Library"))
            assert.are.equal(1, #opened)

            methods.changeLang("pt_PT")
            assert.are.equal(2, #opened)
        end)
        rawset(io, "open", open)
        assert(ok, err)
    end)

    it("loads parsed catalogs from the cache and reparses stale ones", function()
        local cache = require("datastorage"):getDataDir() .. "/cache/zen-i18n-pt_BR.lua"
        os.remove(cache)
        local opened = 0
        local open = io.open
        rawset(io, "open", function(path, ...)
            if type(path) == "string" and path:match("%.po$") then opened = opened + 1 end
            return open(path, ...)
        end)
        local ok, err = pcall(function()
            require("common/i18n").install()
            assert.are.equal(1, opened)
            local fh = assert(open(cache, "r"))
            fh:close()

            local function reload()
                require("common/i18n").uninstall()
                ZenSpec.unload("common/i18n")
                GetText.translation = {}
                require("common/i18n").install()
            end
            reload()
            assert.are.equal(1, opened)
            assert.are.equal("Biblioteca", GetText("Library"))
            assert.are.equal("Barra de navegação", GetText("Navbar"))

            local f = open(cache, "w")
            f:write('return{stamp="stale",n=1,t={Library="x"},c={}}')
            f:close()
            reload()
            assert.are.equal(2, opened)
            assert.are.equal("Biblioteca", GetText("Library"))
        end)
        rawset(io, "open", open)
        assert(ok, err)
    end)
end)
