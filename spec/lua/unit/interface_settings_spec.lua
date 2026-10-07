describe("Interface settings", function()
    local saved_modules
    local saved_reinject_navbars

    local dependencies = {
        "gettext",
        "ui/uimanager",
        "datastorage",
        "common/paths",
        "common/library_font_path",
        "common/shared_state",
        "common/inline_icon_map",
        "common/ui/icon_menu_item",
        "modules/settings/sections/library_settings/status_bar_settings",
        "modules/settings/sections/menu_settings",
        "modules/settings/sections/app_launcher_settings",
        "modules/settings/sections/library_settings/navbar_settings",
        "modules/settings/zen_settings_apply",
        "modules/settings/zen_settings_utils",
        "apps/filemanager/filemanager",
        "fontlist",
        "ui/font",
        "ffi/util",
        "ui/widget/confirmbox",
        "ui/widget/fontchooser",
        "ui/widget/infomessage",
        "ui/widget/pathchooser",
        "ui/widget/spinwidget",
        "common/ui/background",
        "common/book_status",
        "common/tbr_index",
    }

    before_each(function()
        saved_reinject_navbars = rawget(_G, "__ZEN_UI_REINJECT_NAVBARS")
        saved_modules = {}
        for _i, name in ipairs(dependencies) do
            saved_modules[name] = package.loaded[name] or false
        end
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/uimanager", {})
        ZenSpec.replace("datastorage", {
            getFullDataDir = function() return "/koreader" end,
        })
        ZenSpec.replace("common/paths", {})
        ZenSpec.replace("common/shared_state", {})
        ZenSpec.replace("common/inline_icon_map", {})
        ZenSpec.replace("common/ui/icon_menu_item", {
            decorate = function(item) return item end,
        })
        ZenSpec.replace("modules/settings/sections/library_settings/status_bar_settings", {
            build = function() return {} end,
        })
        ZenSpec.replace("modules/settings/zen_settings_apply", {})
        ZenSpec.replace("modules/settings/zen_settings_utils", {
            reorder_nested_items_by_text = function() end,
            buildColorSubMenu = function() return {} end,
            newImagePathChooser = function(options)
                options._image_layout = true
                return options
            end,
        })
        for _i, section in ipairs({ "menu_settings", "app_launcher_settings", "library_settings/navbar_settings" }) do
            ZenSpec.replace("modules/settings/sections/" .. section, { build = function() return { sub_item_table = {} } end })
        end
        ZenSpec.unload("common/library_font_path")
        ZenSpec.unload("modules/settings/sections/interface_settings")
    end)

    after_each(function()
        _G.__ZEN_UI_REINJECT_NAVBARS = saved_reinject_navbars
        ZenSpec.unload("modules/settings/sections/interface_settings")
        for _i, name in ipairs(dependencies) do
            package.loaded[name] = saved_modules[name] or nil
        end
    end)

    it("builds Interface directly and removes its controls from Extras", function()
        local extras = { { text = "Zen Keyboard" }, { text = "Custom icons" }, { text = "Zen Search" }, { text = "Stats" } }
        package.loaded["modules/settings/sections/menu_settings"].build = function()
            return { sub_item_table = { { text = "Blur menu background" }, { text = "Buttons" } } }
        end
        package.loaded["modules/settings/sections/library_settings/status_bar_settings"].build = function()
            return { text = "Status bar" }
        end
        local section = require("modules/settings/sections/interface_settings").build({
            config = { features = {} }, plugin = {}, save_and_apply = function() end,
        }, extras)
        local labels = {}
        for _i, item in ipairs(section.sub_item_table) do labels[#labels + 1] = item.text end
        assert.are.same({ "Controls", "Launcher", "Navbar", "Status bar", "Font", "Zen Keyboard",
            "Wallpaper", "Custom icons", "Blur menu background", "Zen Search" }, labels)
        assert.are.same({ { text = "Stats" } }, extras)
        assert.are.equal(1, #section.sub_item_table[1].sub_item_table)
    end)

    it("resets the Library font to bundled Hyperreadable", function()
        local confirmation
        local saves = 0
        package.loaded["ui/uimanager"].show = function(_self, widget)
            confirmation = widget
        end
        package.loaded["ui/uimanager"].scheduleIn = function() end
        package.loaded["modules/settings/zen_settings_apply"].reinit_filemanager = function() end
        package.loaded["modules/settings/zen_settings_apply"].prompt_restart = function() end
        ZenSpec.replace("ui/widget/confirmbox", {
            new = function(_self, options) return options end,
        })
        ZenSpec.replace("apps/filemanager/filemanager", {})

        local config = {
            browser_hide_up_folder = {},
            features = {},
            library_font = { font_face = "/fonts/Custom-Regular.ttf", font_size = 24 },
        }
        local items = require("modules/settings/sections/interface_settings").build({
            config = config,
            plugin = { saveConfig = function() saves = saves + 1 end },
            save_and_apply = function() end,
        }, {}).sub_item_table

        local function find_item(item_table, text)
            for _i, item in ipairs(item_table) do
                if item.text == text then return item end
                if type(item.sub_item_table) == "table" then
                    local found = find_item(item.sub_item_table, text)
                    if found then return found end
                end
            end
        end

        find_item(items, "Reset font").callback()
        confirmation.ok_callback()

        assert.are.equal(require("config/defaults").library_font.font_face, config.library_font.font_face)
        assert.are.equal(18, config.library_font.font_size)
        assert.are.equal(1, saves)
    end)

    it("lists Library fonts inside settings and stores portable paths", function()
        local name_path
        local saves = 0
        local plugin_root = assert(require("common/plugin_root"))
        local font_path = "fonts/hyperreadable/Hyperreadable-Regular.ttf"
        local resolved_font_path = plugin_root .. "/" .. font_path
        local selected = plugin_root .. "/fonts/hyperreadable/Hyperreadable-Bold.ttf"
        local stock_font_path = "./fonts/noto/NotoSans-Regular.ttf"
        local external_path = "/mnt/fonts/External-Regular.ttf"
        package.loaded["ui/uimanager"].scheduleIn = function() end
        package.loaded["modules/settings/zen_settings_apply"].reinit_filemanager = function() end
        package.loaded["modules/settings/zen_settings_apply"].prompt_restart = function() end
        ZenSpec.replace("ui/widget/fontchooser", {
            getFontNameText = function(path)
                name_path = path
                return path:match("([^/]+)$")
            end,
            isFontRegistered = function(path)
                return path == resolved_font_path or path == stock_font_path
                    or path == selected or path == external_path
            end,
        })
        ZenSpec.replace("ui/font", {
            fontmap = { cfont = "NotoSans-Regular.ttf" },
        })
        ZenSpec.replace("ffi/util", {
            strcoll = function(a, b) return a < b end,
        })
        ZenSpec.replace("fontlist", {
            fontinfo = {
                [resolved_font_path] = {},
                [selected] = {},
                [stock_font_path] = {},
                [external_path] = {},
            },
        })
        ZenSpec.replace("apps/filemanager/filemanager", {})

        local config = {
            browser_hide_up_folder = {},
            features = {},
            library_font = { font_face = font_path, font_size = 24 },
        }
        local items = require("modules/settings/sections/interface_settings").build({
            config = config,
            plugin = { saveConfig = function() saves = saves + 1 end },
            save_and_apply = function() end,
        }, {}).sub_item_table

        local font_item
        for _i, item in ipairs(items) do
            if type(item.sub_item_table) == "table" then
                for _j, sub_item in ipairs(item.sub_item_table) do
                    if sub_item.text == "Reset font" then
                        for _k, sibling in ipairs(item.sub_item_table) do
                            if sibling.hold_callback then font_item = sibling end
                        end
                        break
                    end
                end
            end
        end
        assert.is_not_nil(font_item)
        assert.are.equal("Font: Hyperreadable-Regular.ttf", font_item.text_func())
        assert.are.equal(resolved_font_path, name_path)

        local menu_updates = 0
        local touchmenu = { updateItems = function() menu_updates = menu_updates + 1 end }
        local font_choices = font_item.sub_item_table_func(touchmenu)
        assert.are.equal(resolved_font_path, font_choices.open_on_menu_item_id_func())
        local function choice(file)
            for _i, item in ipairs(font_choices) do
                if item.menu_item_id == file then return item end
            end
        end
        assert.is_true(choice(resolved_font_path).checked_func())

        choice(selected).callback()
        assert.are.equal("fonts/hyperreadable/Hyperreadable-Bold.ttf",
            config.library_font.font_face)
        assert.are.equal(1, saves)
        assert.is_true(choice(selected).checked_func())

        choice(external_path).callback()
        assert.are.equal(external_path, config.library_font.font_face)
        assert.are.equal(2, saves)

        config.library_font.font_face = "cfont"
        font_choices = font_item.sub_item_table_func(touchmenu)
        assert.are.equal(stock_font_path, font_choices.open_on_menu_item_id_func())
        assert.is_true(choice(stock_font_path).checked_func())
        assert.are.equal("cfont", config.library_font.font_face)
        assert.are.equal(2, saves)

        config.library_font.font_face = "/missing/Unavailable-Regular.ttf"
        font_choices = font_item.sub_item_table_func(touchmenu)
        assert.are.equal(resolved_font_path, font_choices.open_on_menu_item_id_func())
        assert.are.equal(font_path, config.library_font.font_face)
        assert.are.equal(3, saves)
        assert.are.equal(3, menu_updates)
    end)

    it("shows the selected Library font path on hold without resetting it", function()
        local message
        local saves = 0
        package.loaded["ui/uimanager"].show = function(_self, widget)
            message = widget
        end
        ZenSpec.replace("ui/widget/infomessage", {
            new = function(_self, options) return options end,
        })

        local font_path = "fonts/Custom-Regular.ttf"
        local resolved_font_path = assert(require("common/plugin_root")) .. "/" .. font_path
        local config = {
            browser_hide_up_folder = {},
            features = {},
            library_font = { font_face = font_path, font_size = 24 },
        }
        local items = require("modules/settings/sections/interface_settings").build({
            config = config,
            plugin = { saveConfig = function() saves = saves + 1 end },
            save_and_apply = function() end,
        }, {}).sub_item_table

        local font_item
        for _i, item in ipairs(items) do
            if type(item.sub_item_table) == "table" then
                for _j, sub_item in ipairs(item.sub_item_table) do
                    if sub_item.text == "Reset font" then
                        for _k, sibling in ipairs(item.sub_item_table) do
                            if sibling.hold_callback then font_item = sibling end
                        end
                        break
                    end
                end
            end
        end
        assert.is_not_nil(font_item)
        font_item.hold_callback()

        assert.are.equal(resolved_font_path, message.text)
        assert.is_false(message.show_icon)
        assert.are.equal(font_path, config.library_font.font_face)
        assert.are.equal(0, saves)
    end)

    it("edits wallpaper opacity and inversion and refreshes the cached surfaces", function()
        local picker
        local saves = 0
        local cache_clears = 0
        local reinitializations = 0
        local scheduled = 0
        local menu_updates = 0
        local navbar_invalidations = 0
        local home_rebuilds = 0
        local navbar_reinjections = 0
        local home = {
            invalidateNavbar = function() navbar_invalidations = navbar_invalidations + 1 end,
            rebuildActive = function() home_rebuilds = home_rebuilds + 1 end,
        }
        package.loaded["common/shared_state"].get = function() return home end
        _G.__ZEN_UI_REINJECT_NAVBARS = function()
            navbar_reinjections = navbar_reinjections + 1
        end
        package.loaded["modules/settings/zen_settings_utils"].show_value_picker =
            function(title, value, callback, min, max)
                picker = {
                    title = title,
                    value = value,
                    callback = callback,
                    min = min,
                    max = max,
                }
            end
        package.loaded["modules/settings/zen_settings_apply"].reinit_filemanager_on_menu_close =
            function() reinitializations = reinitializations + 1 end
        local deferred = {}
        package.loaded["modules/settings/zen_settings_apply"].defer_until_settings_close =
            function(key, callback)
                if not deferred[key] then scheduled = scheduled + 1 end
                deferred[key] = callback
            end
        ZenSpec.replace("common/ui/background", {
            clearCache = function() cache_clears = cache_clears + 1 end,
        })

        local config = {
            browser_hide_up_folder = {},
            features = {},
            library_background = {
                enabled = true,
                path = "/library/background.jpg",
            },
        }
        local items = require("modules/settings/sections/interface_settings").build({
            config = config,
            plugin = { saveConfig = function() saves = saves + 1 end },
            save_and_apply = function() end,
        }, {}).sub_item_table
        local background
        for _i, item in ipairs(items) do
            if item.text == "Wallpaper" then
                background = item
                break
            end
        end
        local opacity = assert(background).sub_item_table[2]
        local inversion = background.sub_item_table[3]

        assert.is_true(background.checked_func())
        assert.is_function(background.checkmark_callback)
        assert.are.equal("Invert with dark mode", inversion.text)
        assert.is_true(inversion.checked_func())
        assert.are.equal("Opacity: 100%", opacity.text_func())
        assert.is_true(opacity.enabled_func())
        opacity.callback({ updateItems = function() menu_updates = menu_updates + 1 end })
        assert.are.same({
            title = "Wallpaper - Opacity",
            value = 100,
            min = 0,
            max = 100,
            callback = picker.callback,
        }, picker)

        picker.callback(37.6)
        assert.are.equal(38, config.library_background.opacity)
        assert.are.equal(1, saves)
        assert.are.equal(1, cache_clears)
        assert.are.equal(1, reinitializations)
        assert.are.equal(1, scheduled)
        assert.are.equal(1, menu_updates)
        assert.are.equal("Opacity: 38%", opacity.text_func())

        assert.is_function(inversion.callback)
        inversion.callback()
        assert.is_false(config.library_background.invert_with_dark_mode)
        assert.is_false(inversion.checked_func())
        assert.are.equal(2, saves)
        assert.are.equal(2, cache_clears)
        assert.are.equal(2, reinitializations)

        inversion.callback()
        assert.is_true(config.library_background.invert_with_dark_mode)
        assert.is_true(inversion.checked_func())
        assert.are.equal(3, saves)
        assert.are.equal(3, cache_clears)

        background.checkmark_callback()
        assert.is_false(config.library_background.enabled)
        assert.is_false(background.checked_func())
        assert.are.equal(4, saves)
        assert.are.equal(4, cache_clears)
        assert.are.equal(4, reinitializations)
        assert.are.equal(1, scheduled)
        assert.are.equal(0, navbar_invalidations)
        assert.are.equal(0, home_rebuilds)
        assert.are.equal(0, navbar_reinjections)

        deferred.background_surfaces()

        assert.are.equal(1, navbar_invalidations)
        assert.are.equal(1, home_rebuilds)
        assert.are.equal(1, navbar_reinjections)
    end)

    it("validates the image when enabling the wallpaper parent switch", function()
        local shown
        local saves = 0
        local cache_clears = 0
        local reinitializations = 0
        local scheduled = 0
        package.loaded["ui/uimanager"].show = function(_, dialog) shown = dialog end
        package.loaded["ui/uimanager"].scheduleIn = function()
            scheduled = scheduled + 1
        end
        package.loaded["modules/settings/zen_settings_apply"].reinit_filemanager_on_menu_close =
            function() reinitializations = reinitializations + 1 end
        local deferred = {}
        package.loaded["modules/settings/zen_settings_apply"].defer_until_settings_close =
            function(key, callback)
                if not deferred[key] then scheduled = scheduled + 1 end
                deferred[key] = callback
            end
        ZenSpec.replace("ui/widget/infomessage", {
            new = function(_, spec) return spec end,
        })
        local background_module = {
            validateImage = function() return false, "missing" end,
            clearCache = function() cache_clears = cache_clears + 1 end,
        }
        ZenSpec.replace("common/ui/background", background_module)

        local config = {
            browser_hide_up_folder = {},
            features = {},
            library_background = {
                enabled = false,
                path = "/library/missing.jpg",
            },
        }
        local items = require("modules/settings/sections/interface_settings").build({
            config = config,
            plugin = { saveConfig = function() saves = saves + 1 end },
            save_and_apply = function() end,
        }, {}).sub_item_table
        local background
        for _i, item in ipairs(items) do
            if item.text == "Wallpaper" then
                background = item
                break
            end
        end

        assert.is_false(background.checked_func())
        assert.are.equal(3, #background.sub_item_table)
        background.checkmark_callback()

        assert.is_false(config.library_background.enabled)
        assert.are.equal("Background image file not found.", shown.text)
        assert.are.equal(0, saves)
        assert.are.equal(0, cache_clears)

        background_module.validateImage = function() return true end
        background.checkmark_callback()

        assert.is_true(config.library_background.enabled)
        assert.is_true(background.checked_func())
        assert.are.equal(1, saves)
        assert.are.equal(1, cache_clears)
        assert.are.equal(1, reinitializations)
        assert.are.equal(1, scheduled)
    end)

    it("uses the wallpapers directory as the wallpaper picker default and Home", function()
        local chooser
        local home_path
        package.loaded["ui/uimanager"].show = function(_, widget) chooser = widget end
        ZenSpec.replace("ui/widget/pathchooser", {
            new = function(_self, values) return values end,
        })

        local items = require("modules/settings/sections/interface_settings").build({
            config = {
                browser_hide_up_folder = {},
                features = {},
                library_background = { path = "" },
            },
            plugin = { saveConfig = function() end },
            save_and_apply = function() end,
        }, {}).sub_item_table
        local background
        for _i, item in ipairs(items) do
            if item.text == "Wallpaper" then background = item; break end
        end

        background.sub_item_table[1].callback()
        assert.are.equal("/koreader/resources/wallpapers", chooser.path)
        assert.is_true(chooser._image_layout)
        assert.is_true(chooser.goHome({
            changeToPath = function(_, path) home_path = path end,
        }))
        assert.are.equal("/koreader/resources/wallpapers", home_path)
    end)

end)
