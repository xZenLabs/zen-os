describe("library settings", function()
    local saved_modules

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
        "modules/settings/zen_settings_apply",
        "modules/settings/zen_settings_utils",
        "apps/filemanager/filemanager",
        "fontlist",
        "ui/font",
        "ui/widget/confirmbox",
        "ui/widget/fontchooser",
        "ui/widget/infomessage",
        "ui/widget/pathchooser",
        "ui/widget/spinwidget",
        "common/ui/background",
    }

    before_each(function()
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
            buildColorSubMenu = function() return {} end,
        })
        ZenSpec.unload("common/library_font_path")
        ZenSpec.unload("modules/settings/sections/library_settings")
    end)

    after_each(function()
        ZenSpec.unload("modules/settings/sections/library_settings")
        for _i, name in ipairs(dependencies) do
            package.loaded[name] = saved_modules[name] or nil
        end
    end)

    it("nests series settings and refreshes the library when they change", function()
        local invalidations = 0
        local clears = 0
        local refreshes = 0
        local saves = 0
        local home = {
            invalidateLibraryCache = function()
                invalidations = invalidations + 1
            end,
        }
        package.loaded["common/shared_state"].get = function() return home end
        ZenSpec.replace("apps/filemanager/filemanager", {
            instance = {
                file_chooser = {
                    path = "/library",
                    _zen_clear_item_table_cache = function() clears = clears + 1 end,
                    changeToPath = function() refreshes = refreshes + 1 end,
                },
            },
        })

        local config = {
            browser_hide_up_folder = {},
            features = { automatic_series_grouping = true, hide_grouped_series = false },
        }
        local items = require("modules/settings/sections/library_settings").build({
            config = config,
            plugin = { saveConfig = function() saves = saves + 1 end },
            save_and_apply = function() end,
        })
        local folders
        for _i, item in ipairs(items) do
            if item.text == "Folders" then
                folders = item
                break
            end
        end

        assert.is_not_nil(folders)
        local series
        for _i, item in ipairs(folders.sub_item_table) do
            if item.text == "Series" then
                series = item
                break
            end
        end

        assert.is_not_nil(series)
        local series_items = series.sub_item_table_func()
        assert.are.same({ "Group book series into folders", "Hide grouped series" }, {
            series_items[1].text, series_items[2].text,
        })

        local touchmenu = { item_table = series_items }
        series_items[1].callback(touchmenu)

        assert.is_false(config.features.automatic_series_grouping)
        assert.are.equal(1, #touchmenu.item_table)

        touchmenu.item_table[1].callback(touchmenu)
        assert.is_true(config.features.automatic_series_grouping)
        assert.are.equal("Hide grouped series", touchmenu.item_table[2].text)

        touchmenu.item_table[2].callback()
        assert.is_true(config.features.hide_grouped_series)
        assert.are.equal(3, saves)
        assert.are.equal(3, invalidations)
        assert.are.equal(3, clears)
        assert.are.equal(3, refreshes)
    end)

    it("uses one arrange list for Book details ordering and toggles", function()
        local saves = 0
        local arranged
        ZenSpec.replace("common/ui/zen_arrange_list", {
            show = function(opts) arranged = opts end,
        })
        local config = { browser_hide_up_folder = {}, features = {} }
        local items = require("modules/settings/sections/library_settings").build({
            config = config,
            plugin = { saveConfig = function() saves = saves + 1 end },
            save_and_apply = function() end,
        })
        local details
        for _i, item in ipairs(items) do
            if item.text == "Book details" then
                details = item
                break
            end
        end

        assert.is_not_nil(details)
        assert.are.equal("Book details", details.text)
        assert.is_true(details._zen_settings_submenu)
        assert.is_nil(details.sub_item_table)
        details.callback()
        assert.are.same({
            "Authors", "Series", "Tags", "Language", "Rating", "Annotations",
            "Note", "Pages", "Progress", "Read time", "Time remaining", "Description",
        }, (function()
            local labels = {}
            for _i, item in ipairs(arranged.item_table) do
                labels[#labels + 1] = item.text
            end
            return labels
        end)())
        for index = 1, 9 do
            assert.is_true(arranged.item_table[index].checked_func())
        end
        assert.is_true(arranged.item_table[12].checked_func())
        assert.are.equal("Navigate to tag",
            arranged.item_table[3].sub_item_table[1].text)
        assert.is_false(arranged.item_table[3].sub_item_table[1].checked_func())
        assert.is_false(arranged.item_table[10].checked_func())
        assert.is_false(arranged.item_table[11].checked_func())
        assert.is_true(arranged.item_table[12].arrange_pinned_last)
        assert.are.equal("Description", arranged.item_table[12].sub_title)
        assert.is_function(arranged.item_table[12].checkmark_callback)
        assert.is_nil(arranged.item_table[12].callback)
        assert.are.same({ "Font: default", "Font size: 18", "Use default style" },
            (function()
                local labels = {}
                for _i, item in ipairs(arranged.item_table[12].sub_item_table_func()) do
                    labels[#labels + 1] = item.text_func and item.text_func() or item.text
                end
                return labels
            end)())
        assert.is_nil(arranged.add_title)
        assert.is_nil(arranged.add_item_table)

        arranged.item_table[3].callback()
        assert.is_false(config.book_details.tags)
        assert.is_false(arranged.item_table[3].checked_func())
        assert.are.equal(1, saves)

        arranged.item_table[1], arranged.item_table[9]
            = arranged.item_table[9], arranged.item_table[1]
        arranged.callback()
        assert.are.same({
            "progress", "series", "tags", "language", "rating", "annotations",
            "note", "pages", "authors", "read_time", "time_remaining",
        }, config.book_details.order)
        assert.are.equal(2, saves)
    end)

    it("edits only the Book details description font", function()
        local arranged
        local shown
        local saves = 0
        local updates = 0
        package.loaded["ui/uimanager"].show = function(_self, widget) shown = widget end
        ZenSpec.replace("common/ui/zen_arrange_list", {
            show = function(opts) arranged = opts end,
        })
        ZenSpec.replace("ui/widget/spinwidget", {
            new = function(_self, opts) return opts end,
        })
        ZenSpec.replace("ui/widget/fontchooser", {
            getFontNameText = function(path) return path:match("([^/]+)$") end,
            isFontRegistered = function() return true end,
            new = function(_self, opts) return opts end,
        })
        local config = {
            browser_hide_up_folder = {},
            features = {},
            library_font = { font_face = "Library.ttf", font_size = 18 },
        }
        local items = require("modules/settings/sections/library_settings").build({
            config = config,
            plugin = { saveConfig = function() saves = saves + 1 end },
            save_and_apply = function() end,
        })
        for _i, item in ipairs(items) do
            if item.text == "Book details" then item.callback() break end
        end

        local font_items = arranged.item_table[12].sub_item_table_func()
        local touchmenu = { updateItems = function() updates = updates + 1 end }
        font_items[1].callback(touchmenu)
        shown.callback("/fonts/Details.ttf")
        assert.are.equal("/fonts/Details.ttf",
            config.book_details.text_styles.description.font_face)

        font_items[2].callback(touchmenu)
        shown.callback({ value = 28 })
        assert.are.equal(28, config.book_details.text_styles.description.font_size)

        font_items[3].callback(touchmenu)
        assert.are.same({ font_face = "default" },
            config.book_details.text_styles.description)
        assert.is_nil(config.book_details.text_styles.all)
        assert.are.equal(3, saves)
        assert.are.equal(3, updates)
    end)

    it("rebuilds the library when mosaic title strips change", function()
        local saves = 0
        local refreshes = 0
        local restart_prompts = 0
        package.loaded["modules/settings/zen_settings_apply"].prompt_restart = function()
            restart_prompts = restart_prompts + 1
        end
        ZenSpec.replace("apps/filemanager/filemanager", {
            instance = {
                file_chooser = {
                    updateItems = function() refreshes = refreshes + 1 end,
                },
            },
        })

        local config = {
            browser_hide_up_folder = {},
            features = {},
            mosaic_title_strip = {},
        }
        local items = require("modules/settings/sections/library_settings").build({
            config = config,
            plugin = { saveConfig = function() saves = saves + 1 end },
            save_and_apply = function() end,
        })

        local function find_item(item_table, text)
            for _i, item in ipairs(item_table) do
                if item.text == text then return item end
                if type(item.sub_item_table) == "table" then
                    local found = find_item(item.sub_item_table, text)
                    if found then return found end
                end
            end
        end

        find_item(items, "Show title below cover (mosaic)").callback()
        find_item(items, "Show author below cover (mosaic)").callback()

        assert.is_true(config.mosaic_title_strip.show_title)
        assert.is_true(config.mosaic_title_strip.show_author)
        assert.are.equal(2, saves)
        assert.are.equal(2, refreshes)
        assert.are.equal(0, restart_prompts)
    end)

    it("rebuilds Home when the folder cover mode changes", function()
        local scheduled
        local saves = 0
        local refreshes = 0
        local rebuilds = 0
        package.loaded["ui/uimanager"].scheduleIn = function(_self, delay, callback)
            scheduled = { delay = delay, callback = callback }
        end
        package.loaded["common/shared_state"].get = function()
            return { rebuildActive = function() rebuilds = rebuilds + 1 end }
        end
        ZenSpec.replace("apps/filemanager/filemanager", {
            instance = {
                file_chooser = {
                    updateItems = function() refreshes = refreshes + 1 end,
                },
            },
        })

        local config = {
            browser_hide_up_folder = {},
            browser_folder_cover = { cover_mode = "gallery" },
            features = {},
        }
        local plugin = { saveConfig = function() saves = saves + 1 end }
        local items = require("modules/settings/sections/library_settings").build({
            config = config,
            plugin = plugin,
            save_and_apply = function() end,
        })

        local function find_item(item_table, text)
            for _i, item in ipairs(item_table) do
                if item.text == text then return item end
                if type(item.sub_item_table) == "table" then
                    local found = find_item(item.sub_item_table, text)
                    if found then return found end
                end
            end
        end

        find_item(items, "First cover image").callback()

        assert.are.equal("normal", config.browser_folder_cover.cover_mode)
        assert.are.equal(1, saves)
        assert.are.equal(1, refreshes)
        assert.are.equal(0, rebuilds)
        assert.are.equal(0.25, scheduled.delay)

        scheduled.callback()
        assert.are.equal(1, rebuilds)
    end)

    it("rebuilds Home when spine lines or rounded corners change", function()
        local scheduled
        local saves = 0
        local refreshes = 0
        local rebuilds = 0
        package.loaded["ui/uimanager"].scheduleIn = function(_self, delay, callback)
            scheduled = { delay = delay, callback = callback }
        end
        package.loaded["common/shared_state"].get = function()
            return { rebuildActive = function() rebuilds = rebuilds + 1 end }
        end
        ZenSpec.replace("apps/filemanager/filemanager", {
            instance = {
                file_chooser = {
                    updateItems = function() refreshes = refreshes + 1 end,
                },
            },
        })

        local config = {
            browser_hide_up_folder = {},
            browser_folder_cover = { show_spine_lines = false },
            features = { browser_cover_rounded_corners = true },
        }
        local items = require("modules/settings/sections/library_settings").build({
            config = config,
            plugin = { saveConfig = function() saves = saves + 1 end },
            save_and_apply = function() end,
        })

        local function find_item(item_table, text)
            for _i, item in ipairs(item_table) do
                if item.text == text then return item end
                if type(item.sub_item_table) == "table" then
                    local found = find_item(item.sub_item_table, text)
                    if found then return found end
                end
            end
        end

        find_item(items, "Show spine lines").callback()
        assert.are.equal(0.25, scheduled.delay)
        scheduled.callback()

        find_item(items, "Rounded cover corners").callback()
        assert.are.equal(0.25, scheduled.delay)
        scheduled.callback()

        assert.is_true(config.browser_folder_cover.show_spine_lines)
        assert.is_false(config.features.browser_cover_rounded_corners)
        assert.are.equal(2, saves)
        assert.are.equal(2, refreshes)
        assert.are.equal(2, rebuilds)
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
        local items = require("modules/settings/sections/library_settings").build({
            config = config,
            plugin = { saveConfig = function() saves = saves + 1 end },
            save_and_apply = function() end,
        })

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

    it("resolves portable Library font paths for the chooser and stores them relatively", function()
        local chooser
        local name_path
        local saves = 0
        local plugin_root = assert(require("common/plugin_root"))
        local font_path = "fonts/hyperreadable/Hyperreadable-Regular.ttf"
        local resolved_font_path = plugin_root .. "/" .. font_path
        local stock_font_path = "./fonts/noto/NotoSans-Regular.ttf"
        package.loaded["ui/uimanager"].show = function(_self, widget)
            chooser = widget
        end
        package.loaded["ui/uimanager"].scheduleIn = function() end
        package.loaded["modules/settings/zen_settings_apply"].reinit_filemanager = function() end
        package.loaded["modules/settings/zen_settings_apply"].prompt_restart = function() end
        ZenSpec.replace("ui/widget/fontchooser", {
            getFontNameText = function(path)
                name_path = path
                return "Hyperreadable"
            end,
            isFontRegistered = function(path)
                return path == resolved_font_path or path == stock_font_path
            end,
            new = function(_self, options) return options end,
        })
        ZenSpec.replace("ui/font", {
            fontmap = { cfont = "NotoSans-Regular.ttf" },
        })
        ZenSpec.replace("fontlist", {
            fontinfo = {
                [stock_font_path] = {},
                ["/external/Unavailable-Regular.ttf"] = {},
            },
        })
        ZenSpec.replace("apps/filemanager/filemanager", {})

        local config = {
            browser_hide_up_folder = {},
            features = {},
            library_font = { font_face = font_path, font_size = 24 },
        }
        local items = require("modules/settings/sections/library_settings").build({
            config = config,
            plugin = { saveConfig = function() saves = saves + 1 end },
            save_and_apply = function() end,
        })

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
        assert.are.equal("Font: Hyperreadable", font_item.text_func())
        assert.are.equal(resolved_font_path, name_path)

        font_item.callback()

        assert.are.equal(resolved_font_path, chooser.font_file)
        assert.are.equal(resolved_font_path, chooser.default_font_file)

        local selected = plugin_root .. "/fonts/hyperreadable/Hyperreadable-Bold.ttf"
        chooser.callback(selected)
        assert.are.equal("fonts/hyperreadable/Hyperreadable-Bold.ttf",
            config.library_font.font_face)
        assert.are.equal(1, saves)

        chooser.callback("/mnt/fonts/External-Regular.ttf")
        assert.are.equal("/mnt/fonts/External-Regular.ttf", config.library_font.font_face)
        assert.are.equal(2, saves)

        config.library_font.font_face = "cfont"
        font_item.callback()
        assert.are.equal(stock_font_path, chooser.font_file)
        assert.are.equal("cfont", config.library_font.font_face)
        assert.are.equal(2, saves)

        config.library_font.font_face = "/missing/Unavailable-Regular.ttf"
        font_item.callback()
        assert.are.equal(resolved_font_path, chooser.font_file)
        assert.are.equal(font_path, config.library_font.font_face)
        assert.are.equal(3, saves)
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
        local items = require("modules/settings/sections/library_settings").build({
            config = config,
            plugin = { saveConfig = function() saves = saves + 1 end },
            save_and_apply = function() end,
        })

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

    it("edits library background opacity and refreshes the cached surfaces", function()
        local picker
        local saves = 0
        local cache_clears = 0
        local reinitializations = 0
        local scheduled = 0
        local menu_updates = 0
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
        package.loaded["ui/uimanager"].scheduleIn = function()
            scheduled = scheduled + 1
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
        local items = require("modules/settings/sections/library_settings").build({
            config = config,
            plugin = { saveConfig = function() saves = saves + 1 end },
            save_and_apply = function() end,
        })
        local background
        for _i, item in ipairs(items) do
            if item.text == "Background" then
                background = item
                break
            end
        end
        local opacity = assert(background).sub_item_table[2]

        assert.is_true(background.checked_func())
        assert.is_function(background.checkmark_callback)
        assert.are.equal("Opacity: 100%", opacity.text_func())
        assert.is_true(opacity.enabled_func())
        opacity.callback({ updateItems = function() menu_updates = menu_updates + 1 end })
        assert.are.same({
            title = "Background - Opacity",
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

        background.checkmark_callback()
        assert.is_false(config.library_background.enabled)
        assert.is_false(background.checked_func())
        assert.are.equal(2, saves)
        assert.are.equal(2, cache_clears)
        assert.are.equal(2, reinitializations)
        assert.are.equal(1, scheduled)
    end)

    it("validates the image when enabling the library background parent switch", function()
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
        local items = require("modules/settings/sections/library_settings").build({
            config = config,
            plugin = { saveConfig = function() saves = saves + 1 end },
            save_and_apply = function() end,
        })
        local background
        for _i, item in ipairs(items) do
            if item.text == "Background" then
                background = item
                break
            end
        end

        assert.is_false(background.checked_func())
        assert.are.equal(2, #background.sub_item_table)
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

    it("uses the wallpapers directory as the background picker default and Home", function()
        local chooser
        local home_path
        package.loaded["ui/uimanager"].show = function(_, widget) chooser = widget end
        ZenSpec.replace("ui/widget/pathchooser", {
            new = function(_self, values) return values end,
        })

        local items = require("modules/settings/sections/library_settings").build({
            config = {
                browser_hide_up_folder = {},
                features = {},
                library_background = { path = "" },
            },
            plugin = { saveConfig = function() end },
            save_and_apply = function() end,
        })
        local background
        for _i, item in ipairs(items) do
            if item.text == "Background" then background = item; break end
        end

        background.sub_item_table[1].callback()
        assert.are.equal("/koreader/resources/wallpapers", chooser.path)
        assert.is_true(chooser.goHome({
            changeToPath = function(_, path) home_path = path end,
        }))
        assert.are.equal("/koreader/resources/wallpapers", home_path)
    end)
end)
