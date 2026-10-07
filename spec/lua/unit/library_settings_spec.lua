describe("library settings", function()
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
        "bookinfomanager",
        "common/cover_utils",
        "ui/widget/filechooser",
        "common/ui/mosaic_layout_dialog",
        "common/ui/zen_arrange_list",
    }

    local function find_item(items, text)
        for _i, item in ipairs(items) do
            if item.text == text then return item end
            if item.sub_item_table then
                local found = find_item(item.sub_item_table, text)
                if found then return found end
            end
        end
    end

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
            buildColorSubMenu = function() return {} end,
            newImagePathChooser = function(options)
                options._image_layout = true
                return options
            end,
        })
        ZenSpec.unload("common/library_font_path")
        ZenSpec.unload("modules/settings/sections/library_settings")
    end)

    after_each(function()
        _G.__ZEN_UI_REINJECT_NAVBARS = saved_reinject_navbars
        ZenSpec.unload("modules/settings/sections/library_settings")
        for _i, name in ipairs(dependencies) do
            package.loaded[name] = saved_modules[name] or nil
        end
    end)

    it("groups Library into Appearance, Folders, Books, and Context menu", function()
        local items = require("modules/settings/sections/library_settings").build({
            config = { features = {}, browser_hide_up_folder = {} },
            plugin = {}, save_and_apply = function() end,
        })
        local function labels(item_table)
            local result = {}
            for _i, item in ipairs(item_table) do result[#result + 1] = item.text end
            return result
        end
        assert.are.same({ "Appearance", "Folders", "Books", "Context menu" }, labels(items))
        assert.are.same({ "Layout", "Covers", "Scroll bar" }, labels(items[1].sub_item_table))
        assert.are.same({ "Covers", "Series", "Folder name", "Home folder", "Hide up folder" },
            labels(items[2].sub_item_table))
        assert.are.same({ "Book details", "Metadata", "Double-tap to open a book",
            "Include new books in TBR", "Treat file updates as New" }, labels(items[3].sub_item_table))
        assert.are.same({ "Archive", "Plugin actions", "Allow delete" }, labels(items[4].sub_item_table))
        assert.are.same({ "Mosaic", "List", "Show all files from subfolders", "Show item underline" },
            labels(find_item(items, "Layout").sub_item_table))
        assert.are.same({ "Portrait", "Landscape", "Reset to default" },
            labels(find_item(items, "Mosaic").sub_item_table))
        assert.are.same({ "Items per page", "Detailed list items", "Hide list borders" },
            labels(find_item(items, "List").sub_item_table))
        assert.are.same({ "Bar", "Dots", "Page number" },
            labels(find_item(items, "Scroll bar").sub_item_table))
        assert.are.same({ "Page number format", "Hold to skip" },
            labels(find_item(items, "Page number").sub_item_table))
        assert.is_nil(find_item(items, "Font"))
        assert.is_nil(find_item(items, "Wallpaper"))
        assert.is_nil(find_item(items, "Status bar"))
    end)

    it("persists both mosaic orientations and list density without an open library", function()
        local saved, shown = {}, nil
        local fc_class = {}
        ZenSpec.replace("common/cover_utils", { MAX_FILES_PER_PAGE = 12 })
        ZenSpec.replace("bookinfomanager", {
            getSetting = function(_self, key) return saved[key] end,
            saveSetting = function(_self, key, value) saved[key] = value end,
        })
        ZenSpec.replace("apps/filemanager/filemanager", {})
        ZenSpec.replace("ui/widget/filechooser", fc_class)
        ZenSpec.replace("common/ui/mosaic_layout_dialog", { new = function(options) return options end })
        ZenSpec.replace("ui/widget/spinwidget", { new = function(_self, options) return options end })
        package.loaded["ui/uimanager"].show = function(_self, options) shown = options end
        local items = require("modules/settings/sections/library_settings").build({
            config = { features = {}, browser_hide_up_folder = {} },
            plugin = {}, save_and_apply = function() end,
        })
        find_item(items, "Portrait").callback()
        assert.are.same({ 3, 3 }, { shown.columns, shown.rows })
        shown.callback(2, 8)
        find_item(items, "Landscape").callback()
        assert.are.same({ 4, 2 }, { shown.columns, shown.rows })
        shown.callback(8, 2)
        find_item(items, "Items per page").callback()
        shown.callback({ value = 6 })
        assert.are.same({ nb_cols_portrait = 2, nb_rows_portrait = 8,
            nb_cols_landscape = 8, nb_rows_landscape = 2, files_per_page = 6 }, saved)
        assert.are.same(saved, fc_class)
        find_item(items, "Reset to default").callback()
        assert.are.same({ nb_cols_portrait = 3, nb_rows_portrait = 3,
            nb_cols_landscape = 4, nb_rows_landscape = 2, files_per_page = 6 }, saved)
        assert.are.same(saved, fc_class)
    end)

    it("arranges detailed fields and keeps existing defaults with file type off", function()
        local arranged, saves, refreshes = nil, 0, 0
        ZenSpec.replace("common/ui/zen_arrange_list", { show = function(options) arranged = options end })
        ZenSpec.replace("apps/filemanager/filemanager", {
            instance = { file_chooser = { updateItems = function() refreshes = refreshes + 1 end } },
        })
        local config = { features = {}, browser_hide_up_folder = {} }
        local items = require("modules/settings/sections/library_settings").build({
            config = config, plugin = { saveConfig = function() saves = saves + 1 end },
            save_and_apply = function() end,
        })
        find_item(items, "Detailed list items").callback()
        assert.are.equal("Detailed list items", arranged.title)
        for _i, id in ipairs({ "Title", "Authors", "Series", "Tags", "Pages", "Read status" }) do
            assert.is_true(find_item(arranged.item_table, id).checked_func())
        end
        for _i, id in ipairs({ "Filename", "File type", "Language", "File size" }) do
            assert.is_false(find_item(arranged.item_table, id).checked_func())
        end
        assert.is_nil(find_item(arranged.item_table, "Progress"))
        find_item(arranged.item_table, "File type").callback()
        find_item(arranged.item_table, "Title").callback()
        assert.is_true(config.browser_list_item_layout.show.filetype)
        assert.is_false(config.browser_list_item_layout.show.title)
        table.insert(arranged.item_table, 1, table.remove(arranged.item_table, 5))
        arranged.callback()
        assert.are.equal("filename", config.browser_list_item_layout.order[1])
        assert.are.same({ 3, 3 }, { saves, refreshes })
    end)

    it("selects page-number style and persists its nested controls", function()
        local saves, reinitializations = 0, 0
        package.loaded["ui/uimanager"].setDirty = function() end
        package.loaded["modules/settings/zen_settings_apply"].reinit_filemanager = function()
            reinitializations = reinitializations + 1
        end
        local config = { features = {}, browser_hide_up_folder = {}, zen_scroll_bar = { style = "bar" } }
        local items = require("modules/settings/sections/library_settings").build({
            config = config, plugin = { saveConfig = function() saves = saves + 1 end },
            save_and_apply = function() end,
        })
        local page_number = find_item(items, "Page number")
        assert.is_false(page_number.checked_func())
        page_number.checkmark_callback()
        assert.is_true(page_number.checked_func())
        find_item(page_number.sub_item_table, "Page x / y").callback()
        find_item(page_number.sub_item_table, "Skip 20 pages").callback()
        assert.are.same({ style = "page_number", page_number_format = "total", hold_skip = "20" }, config.zen_scroll_bar)
        assert.are.same({ 3, 1 }, { saves, reinitializations })
    end)

    it("toggles double-tap book opening", function()
        local saved = 0
        local config = { features = {}, developer = {}, browser_hide_up_folder = {} }
        local items = require("modules/settings/sections/library_settings").build({
            config = config,
            plugin = { saveConfig = function() saved = saved + 1 end },
            save_and_apply = function() end,
        })
        local double_tap_item = find_item(items, "Double-tap to open a book")

        assert.is_table(double_tap_item)
        assert.is_false(double_tap_item.checked_func())
        double_tap_item.checkmark_callback()
        assert.is_true(double_tap_item.checked_func())
        assert.are.equal(1, saved)

        local single_tap_item = double_tap_item.sub_item_table[1]
        assert.are.equal("Single tap to open context menu", single_tap_item.text)
        assert.is_true(single_tap_item.enabled_func())
        assert.is_false(single_tap_item.checked_func())
        single_tap_item.callback()
        assert.is_true(single_tap_item.checked_func())
        assert.are.equal(2, saved)
        double_tap_item.checkmark_callback()
        assert.is_false(single_tap_item.enabled_func())
        assert.are.equal(3, saved)
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

    it("defaults file updates to the saved status and refreshes statuses when toggled", function()
        local saves, clears, index_clears, item_clears, rebuilds, refreshes, menu_updates = 0, 0, 0, 0, 0, 0, 0
        ZenSpec.replace("common/book_status", { clearCache = function() clears = clears + 1 end })
        ZenSpec.replace("common/tbr_index", { invalidateStatusCache = function() index_clears = index_clears + 1 end })
        package.loaded["common/shared_state"].get = function()
            return {
                rebuildActive = function() rebuilds = rebuilds + 1 end,
            }
        end
        ZenSpec.replace("apps/filemanager/filemanager", {
            instance = { file_chooser = {
                refreshPath = function() refreshes = refreshes + 1 end,
                _zen_clear_item_table_cache = function() item_clears = item_clears + 1 end,
            } },
        })
        local config = { browser_hide_up_folder = {}, features = {} }
        local items = require("modules/settings/sections/library_settings").build({
            config = config,
            plugin = { saveConfig = function() saves = saves + 1 end },
            save_and_apply = function() end,
        })
        local setting = find_item(items, "Treat file updates as New")
        assert.are.equal("Treat file updates as New", setting.text)
        assert.is_not_nil(find_item(items, "Include new books in TBR"))
        assert.is_false(setting.checked_func())
        local menu = { updateItems = function() menu_updates = menu_updates + 1 end }
        setting.callback(menu)
        assert.is_true(config.group_view.file_updates_as_new)
        assert.is_true(setting.checked_func())
        setting.callback(menu)
        assert.is_false(config.group_view.file_updates_as_new)
        assert.is_false(setting.checked_func())
        assert.same({ 2, 2, 2, 2, 2, 2, 2 },
            { saves, clears, index_clears, item_clears, rebuilds, refreshes, menu_updates })
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
        local details = find_item(items, "Book details")

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
        find_item(items, "Book details").callback()

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

        find_item(items, "Show title below cover (mosaic)").callback()
        find_item(items, "Show author below cover (mosaic)").callback()

        assert.is_true(config.mosaic_title_strip.show_title)
        assert.is_true(config.mosaic_title_strip.show_author)
        assert.are.equal(2, saves)
        assert.are.equal(2, refreshes)
        assert.are.equal(0, restart_prompts)
    end)

    it("rebuilds Home when the folder cover mode changes", function()
        local deferred
        local saves = 0
        local refreshes = 0
        local rebuilds = 0
        package.loaded["modules/settings/zen_settings_apply"].defer_until_settings_close =
            function(key, callback)
                assert.are.equal("home_rebuild", key)
                deferred = callback
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

        find_item(items, "First cover image").callback()

        assert.are.equal("normal", config.browser_folder_cover.cover_mode)
        assert.are.equal(1, saves)
        assert.are.equal(1, refreshes)
        assert.are.equal(0, rebuilds)
        assert.is_function(deferred)

        deferred()
        assert.are.equal(1, rebuilds)
    end)

    it("rebuilds Home when spine lines or rounded corners change", function()
        local deferred
        local saves = 0
        local refreshes = 0
        local rebuilds = 0
        package.loaded["modules/settings/zen_settings_apply"].defer_until_settings_close =
            function(_key, callback) deferred = callback end
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

        find_item(items, "Show spine lines").callback()
        assert.is_function(deferred)
        deferred()

        find_item(items, "Rounded cover corners").callback()
        assert.is_function(deferred)
        deferred()

        assert.is_true(config.browser_folder_cover.show_spine_lines)
        assert.is_false(config.features.browser_cover_rounded_corners)
        assert.are.equal(2, saves)
        assert.are.equal(2, refreshes)
        assert.are.equal(2, rebuilds)
    end)

    it("puts archive and plugin actions off by default under Context menu", function()
        local saves = 0
        local config = {
            browser_hide_up_folder = {},
            context_menu = { allow_delete = true },
            features = {},
        }
        local items = require("modules/settings/sections/library_settings").build({
            config = config,
            plugin = { saveConfig = function() saves = saves + 1 end },
            save_and_apply = function() end,
        })

        local context_menu = find_item(items, "Context menu")
        assert.are.equal("Context menu", context_menu.text)
        assert.are.equal(3, #context_menu.sub_item_table)
        local archive = context_menu.sub_item_table[1]
        assert.are.equal("Archive", archive.text)
        assert.are.equal("Plugin actions", context_menu.sub_item_table[2].text)
        local allow_delete = find_item(context_menu.sub_item_table, "Allow delete")
        assert.is_not_nil(allow_delete)
        assert.is_true(allow_delete.checked_func())
        local plugin_actions = context_menu.sub_item_table[2]
        assert.is_false(archive.checked_func())
        assert.is_false(plugin_actions.checked_func())
        assert.is_false(require("config/defaults").context_menu.show_archive)
        assert.is_false(require("config/defaults").context_menu.show_plugin_actions)

        archive.callback()
        assert.is_true(archive.checked_func())
        plugin_actions.callback()
        assert.is_true(plugin_actions.checked_func())
        assert.are.equal(2, saves)
    end)
end)
