describe("Quickstart pages", function()
    local original_modules
    local original_settings
    local reader_apply_result
    local color_screen, saved_configs, navbar_refreshes, home_rebuilds

    local module_names = {
        "bookinfomanager",
        "common/cover_utils",
        "common/paths",
        "common/plugin_root",
        "common/quickstart/quickstart_pages",
        "common/reader_defaults",
        "common/shared_state",
        "common/ui/accent",
        "common/zen_logger",
        "config/manager",
        "config/preset_store",
        "config/screensaver_presets",
        "device",
        "gettext",
        "modules/settings/zen_settings_apply",
        "ui/uimanager",
    }

    before_each(function()
        original_modules = {}
        for _i, name in ipairs(module_names) do
            original_modules[name] = package.loaded[name]
        end
        original_settings = G_reader_settings
        color_screen = false
        saved_configs, navbar_refreshes, home_rebuilds = {}, 0, 0

        ZenSpec.replace("bookinfomanager", {})
        ZenSpec.replace("common/cover_utils", {})
        ZenSpec.replace("common/paths", {
            getHomeDir = function() return "/books" end,
            getConfiguredHomeDir = function()
                return G_reader_settings:readSetting("home_dir")
            end,
        })
        ZenSpec.replace("common/plugin_root", "/plugins/zenos.koplugin")
        reader_apply_result = nil
        ZenSpec.replace("common/reader_defaults", {
            apply = function() return reader_apply_result end,
        })
        ZenSpec.replace("common/zen_logger", {
            new = function() return { warn = function() end } end,
        })
        ZenSpec.replace("config/manager", {
            save = function(config) saved_configs[#saved_configs + 1] = config end,
        })
        ZenSpec.replace("config/preset_store", {})
        ZenSpec.replace("config/screensaver_presets", {
            get = function() return {} end,
        })
        ZenSpec.replace("device", {
            screen = { isColorScreen = function() return color_screen end },
        })
        ZenSpec.unload("common/ui/accent")
        ZenSpec.replace("common/shared_state", {
            get = function()
                return { rebuildActive = function() home_rebuilds = home_rebuilds + 1 end }
            end,
        })
        ZenSpec.replace("ui/uimanager", {
            setDirty = function() end,
        })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("modules/settings/zen_settings_apply", {
            apply_feature_toggle = function() end,
            refresh_navbar_on_menu_close = function() navbar_refreshes = navbar_refreshes + 1 end,
            defer_until_settings_close = function(_key, callback) callback() end,
        })
        ZenSpec.unload("common/quickstart/quickstart_pages")
        _G.G_reader_settings = ZenSpec.memorySettings()
    end)

    after_each(function()
        for _i, name in ipairs(module_names) do
            package.loaded[name] = original_modules[name]
        end
        _G.G_reader_settings = original_settings
    end)

    local function install_page(title, completed, pending)
        local config = {
            _meta = {
                quickstart_completed = completed,
                reader_defaults_apply_on_next_open = pending == true,
            },
            features = {},
            navbar = { show_tabs = {} },
        }
        local pages = require("common/quickstart/quickstart_pages").build_install_pages({
            config = config,
            plugin = {},
        })
        for _i, page in ipairs(pages) do
            if page.title == title then return page, config end
        end
    end

    local function reader_page(completed, pending)
        return install_page("Reader", completed, pending)
    end

    local function reader_choices(completed)
        return reader_page(completed).choices
    end

    local function install_pages()
        return require("common/quickstart/quickstart_pages").build_install_pages({
            config = {
                _meta = { quickstart_completed = false },
                features = {},
                navbar = { show_tabs = {} },
            },
            plugin = {},
        })
    end

    it("selects Zen Reader defaults before setup has been completed", function()
        local choices = reader_choices(false)

        assert.is_false(choices[1].checked)
        assert.is_true(choices[2].checked)
    end)

    it("keeps existing Reader settings when a completed setup is rerun", function()
        local choices = reader_choices(true)

        assert.is_true(choices[1].checked)
        assert.is_false(choices[2].checked)
    end)

    it("selects the book cover sleep screen before setup has been completed", function()
        local choices = install_page("Sleep Screen", false).choices

        assert.is_false(choices[1].checked)
        assert.is_true(choices[2].checked)
    end)

    it("keeps existing sleep screen settings when a completed setup is rerun", function()
        local choices = install_page("Sleep Screen", true).choices

        assert.is_true(choices[1].checked)
        assert.is_false(choices[2].checked)
    end)

    it("applies Zen Reader defaults to the next book when no reader is active", function()
        reader_apply_result = false
        local page, config = reader_page(false)

        page.on_apply({ zen = true })

        assert.is_true(config._meta.reader_defaults_apply_on_next_open)
    end)

    it("does not defer Zen Reader defaults after applying them to an active book", function()
        reader_apply_result = true
        local page, config = reader_page(true, true)

        page.on_apply({ zen = true })

        assert.is_false(config._meta.reader_defaults_apply_on_next_open)
    end)

    it("cancels a deferred application when existing Reader settings are kept", function()
        local page, config = reader_page(true, true)

        page.on_apply({ keep = true })

        assert.is_false(config._meta.reader_defaults_apply_on_next_open)
    end)

    it("still offers Home Folder setup when only the device fallback exists", function()
        local found = false
        for _i, page in ipairs(install_pages()) do
            if page.title == "Home Folder" then found = true end
        end

        assert.is_true(found)
    end)

    it("adds the accent page after Library View only on color screens", function()
        assert.is_nil(install_page("Accent color", false))
        color_screen = true

        local pages = install_pages()
        assert.are.equal("Library View", pages[2].title)
        assert.are.equal("Accent color", pages[3].title)
    end)

    it("does not add accent setup after updates on monochrome or color screens", function()
        local pages_mod = require("common/quickstart/quickstart_pages")

        assert.are.same({}, pages_mod.build_update_pages("4.2.0"))
        color_screen = true
        assert.are.same({}, pages_mod.build_update_pages("4.2.0"))
        assert.are.same({}, pages_mod.build_update_pages("4.2.1"))
    end)

    it("preserves version-specific update pages without adding accent setup", function()
        color_screen = true
        local pages_mod = require("common/quickstart/quickstart_pages")
        local feature_page = { title = "What's new" }
        pages_mod.UPDATE_PAGES["4.2.0-beta1"] = { feature_page }
        local pages = pages_mod.build_update_pages("4.2.0-beta1")

        assert.are.equal(feature_page, pages[1])
        assert.are.equal(1, #pages)
        assert.are.equal(1, #pages_mod.UPDATE_PAGES["4.2.0-beta1"])
    end)

    it("keeps the saved accent until the embedded picker applies a selection", function()
        color_screen = true
        local config = { accent_enabled = false, accent_color = "#AABBCC", accent_opacity = 65 }
        local page = require("common/quickstart/quickstart_pages").build_accent_page({ config = config })

        assert.are.equal("#AABBCC", page.color_picker.hex)
        assert.are.equal(65, page.color_picker.opacity)
        assert.is_nil(page.on_button)
        assert.is_nil(page.button_text)
        assert.are.equal("Choose an accent color for buttons, sliders, and navigation.", page.description)

        assert.is_false(config.accent_enabled)
        assert.are.equal("#AABBCC", config.accent_color)
        assert.are.equal(0, #saved_configs)
        assert.are.equal(0, navbar_refreshes)
    end)

    it("edits the regular accent during setup even when the night accent is active", function()
        color_screen = true
        package.loaded["device"].screen.night_mode = true
        local config = { accent_color = "#204080", accent_opacity = 80,
            accent_night_enabled = true, accent_night_color = "#CC8844", accent_night_opacity = 40 }
        local page = require("common/quickstart/quickstart_pages").build_accent_page({ config = config })

        assert.are.equal("#204080", page.color_picker.hex)
        assert.are.equal(80, page.color_picker.opacity)
        page.color_picker.callback("#0088FF", 75)
        assert.are.equal("#0088FF", config.accent_color)
        assert.are.equal(75, config.accent_opacity)
        assert.is_true(config.accent_night_enabled)
        assert.are.equal("#CC8844", config.accent_night_color)
        assert.are.equal(40, config.accent_night_opacity)
    end)

    it("saves and enables the chosen accent and refreshes navigation and Home", function()
        color_screen = true
        local config = { accent_enabled = false, accent_color = "#000000", accent_opacity = 100 }
        local page = require("common/quickstart/quickstart_pages").build_accent_page({ config = config })

        assert.are.equal("#3399FF", page.color_picker.hex)
        assert.are.equal(0, #saved_configs)
        page.color_picker.callback("#0088FF", 75)

        assert.is_true(config.accent_enabled)
        assert.are.equal("#0088FF", config.accent_color)
        assert.are.equal(75, config.accent_opacity)
        assert.are.equal("#0088FF", page.color_picker.hex)
        assert.are.equal(75, page.color_picker.opacity)
        assert.are.same({ config }, saved_configs)
        assert.are.equal(1, navbar_refreshes)
        assert.are.equal(1, home_rebuilds)
    end)
end)
