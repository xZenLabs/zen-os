describe("metadata settings", function()
    local Settings
    local saved = {}
    local ui_manager
    local credentials
    local credential_error

    local function clean_credential(value)
        value = tostring(value or ""):match("^%s*(.-)%s*$") or ""
        if value == "" or value:find("%s") then return nil end
        return value
    end

    local function credential_store(name)
        return {
            clean = clean_credential,
            get = function() return credentials[name] end,
            save = function(value)
                if credential_error then return nil, credential_error end
                credentials[name] = value
                return true
            end,
            clear = function()
                if credential_error then return nil, credential_error end
                credentials[name] = ""
                return true
            end,
        }
    end

    before_each(function()
        for _i, name in ipairs({
            "device", "ui/uimanager", "common/inline_icon_map",
            "common/ui/icon_menu_item", "config/hardcover_token",
            "config/google_books_key", "gettext",
            "ui/widget/confirmbox", "ui/widget/infomessage", "ui/widget/inputdialog",
            "modules/settings/sections/library_settings/metadata_settings",
        }) do
            saved[name] = package.loaded[name] or false
        end
        ZenSpec.replace("device", {
            screen = { getWidth = function() return 600 end, getHeight = function() return 800 end },
            openLink = function() end,
        })
        ui_manager = {}
        credentials = { hardcover = "", google = "" }
        credential_error = nil
        ZenSpec.replace("ui/uimanager", ui_manager)
        ZenSpec.replace("common/inline_icon_map", { edit = "edit" })
        ZenSpec.replace("common/ui/icon_menu_item", {
            decorate = function(item) return item end,
        })
        ZenSpec.replace("config/hardcover_token", credential_store("hardcover"))
        ZenSpec.replace("config/google_books_key", credential_store("google"))
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.unload("modules/settings/sections/library_settings/metadata_settings")
        Settings = require("modules/settings/sections/library_settings/metadata_settings")
    end)

    after_each(function()
        for name, module in pairs(saved) do package.loaded[name] = module or nil end
        saved = {}
    end)

    it("validates and masks credentials", function()
        assert.same("hc_pat_token", Settings.cleanToken("  hc_pat_token  "))
        assert.is_nil(Settings.cleanToken("bad token"))
        assert.is_nil(Settings.cleanToken(""))
        assert.same("AIza-key", Settings.cleanGoogleKey("  AIza-key  "))
        assert.is_nil(Settings.cleanGoogleKey("bad key"))
        assert.same("••••oken", Settings.maskedToken("hc_pat_token"))
        assert.same("••••", Settings.maskedToken("abc"))
    end)

    it("clears the dedicated token file", function()
        local confirm
        credentials.hardcover = "secret"
        ZenSpec.replace("ui/widget/confirmbox", {
            new = function(_self, options) return options end,
        })
        ZenSpec.replace("ui/widget/infomessage", {
            new = function(_self, options) return options end,
        })
        ui_manager.show = function(_self, widget) confirm = widget end
        local menu = Settings.build{}

        menu.sub_item_table[1].sub_item_table[2].callback()
        confirm.ok_callback()

        assert.are.equal("", credentials.hardcover)
        assert.is_false(menu.sub_item_table[1].sub_item_table[2].enabled_func())
    end)

    it("saves, masks, and clears the Google Books key", function()
        local shown = {}
        local closed = 0
        ZenSpec.replace("ui/widget/inputdialog", {
            new = function(_self, options)
                options.getInputText = function() return "AIza-replacement" end
                options.onShowKeyboard = function() end
                return options
            end,
        })
        ZenSpec.replace("ui/widget/confirmbox", {
            new = function(_self, options) return options end,
        })
        ui_manager.show = function(_self, widget) shown[#shown + 1] = widget end
        ui_manager.close = function() closed = closed + 1 end
        local google = Settings.build{}.sub_item_table[2]

        google.sub_item_table[1].callback()
        shown[1].buttons[1][2].callback()

        assert.are.equal("AIza-replacement", credentials.google)
        assert.are.equal("Google Books API key: ••••ment",
            google.sub_item_table[1].text_func())
        assert.are.equal(1, closed)
        google.sub_item_table[2].callback()
        shown[2].ok_callback()
        assert.are.equal("", credentials.google)
    end)

    it("keeps the credential dialog open when verified persistence fails", function()
        local shown = {}
        local closed = 0
        credentials.google = "original"
        credential_error = "disk full"
        ZenSpec.replace("ui/widget/inputdialog", {
            new = function(_self, options)
                options.getInputText = function() return "replacement" end
                options.onShowKeyboard = function() end
                return options
            end,
        })
        ZenSpec.replace("ui/widget/infomessage", {
            new = function(_self, options) return options end,
        })
        ui_manager.show = function(_self, widget) shown[#shown + 1] = widget end
        ui_manager.close = function() closed = closed + 1 end
        local menu = Settings.build{}

        menu.sub_item_table[2].sub_item_table[1].callback()
        shown[1].buttons[1][2].callback()

        assert.are.equal("original", credentials.google)
        assert.are.equal(0, closed)
        assert.are.equal("Metadata could not be saved.", shown[2].text)
    end)

    it("saves provider, match-selection, and backup preferences", function()
        local config = { metadata = {} }
        local save_count = 0
        local menu = Settings.build{
            config = config,
            plugin = { saveConfig = function() save_count = save_count + 1 end },
        }

        assert.are.equal("Hardcover", menu.sub_item_table[1].text)
        assert.are.equal("Google Books", menu.sub_item_table[2].text)
        assert.are.equal("Open Library", menu.sub_item_table[3].text)
        assert.is_true(menu.sub_item_table[1].checked_func())
        assert.is_true(menu.sub_item_table[2].checked_func())
        assert.is_true(menu.sub_item_table[3].checked_func())
        assert.is_true(menu.sub_item_table[4].sub_item_table[1].checked_func())
        assert.is_false(menu.sub_item_table[5].checked_func())

        menu.sub_item_table[1].checkmark_callback()
        menu.sub_item_table[2].checkmark_callback()
        menu.sub_item_table[3].callback()
        menu.sub_item_table[4].sub_item_table[2].callback()
        menu.sub_item_table[5].callback()

        assert.is_false(config.metadata.hardcover_enabled)
        assert.is_false(config.metadata.google_books_enabled)
        assert.is_false(config.metadata.open_library_enabled)
        assert.is_false(config.metadata.hardcover_auto_match)
        assert.is_true(config.metadata.epub_backup)
        assert.are.equal(5, save_count)
    end)
end)
