describe("Home widget content settings", function()
    local arrange_options
    local arrange_history
    local home_page
    local remembered_routes
    local responsive_strip_per_row
    local shown
    local tbr_order_calls
    local tbr_order_options
    local choose_folder
    local choose_tag
    local quote_files

    local function item_text(item)
        return item.text or (item.text_func and item.text_func())
    end

    local function find_item(items, text)
        for _i, item in ipairs(items) do
            if item_text(item) == text then return item end
        end
    end

    local function has_item_prefix(items, prefix)
        for _i, item in ipairs(items) do
            local text = item_text(item)
            if type(text) == "string" and text:sub(1, #prefix) == prefix then
                return true
            end
        end
        return false
    end

    local function find_item_prefix(items, prefix)
        for _i, item in ipairs(items) do
            local text = item_text(item)
            if type(text) == "string" and text:sub(1, #prefix) == prefix then
                return item
            end
        end
    end

    before_each(function()
        arrange_options = nil
        arrange_history = {}
        remembered_routes = {}
        responsive_strip_per_row = 5
        shown = {}
        tbr_order_calls = 0
        tbr_order_options = nil
        choose_folder = nil
        choose_tag = nil
        quote_files = { "quotes.lua" }
        home_page = {
            strip_memory = {
                active_id = "recent",
                source = { kind = "recent" },
            },
            rows = {
                order = { "featured", "strip" },
                enabled = { featured = true, strip = true },
            },
            modules = {
                featured = {
                    default_source = { kind = "recent" },
                    path = "/books/selected.epub",
                    show_module_title = true,
                },
                quotes = { show_module_title = true },
                reading_goals = { show_module_title = true },
                stats_triplet = { show_module_title = true },
                strip = {
                    show_module_title = true,
                    controls = {
                        enabled = false,
                        labels = {},
                        order = { "recent", "favorites" },
                        show_buttons = { recent = true, favorites = true },
                        custom_buttons = {},
                    },
                    default_source = { kind = "recent" },
                    sources = {
                        custom = { paths = {} },
                        recent = {},
                        tag = {},
                    },
                },
            },
            goals = {},
            quotes = {},
        }

        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ffi/util", {
            template = function(text) return text end,
        })
        ZenSpec.replace("ui/uimanager", {
            scheduleIn = function() end,
            show = function(_self, widget) shown[#shown + 1] = widget end,
        })
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return 600 end,
                scaleBySize = function(_self, value) return value end,
            },
        })
        ZenSpec.replace("ui/widget/confirmbox", {
            new = function(_self, opts) return opts end,
        })
        ZenSpec.replace("config/preset_store", {
            getSettings = function() return home_page end,
            saveSettings = function() end,
            isBuiltin = function() return false end,
            list = function()
                return { { name = "My preset" } }
            end,
        })
        ZenSpec.replace("modules/filebrowser/patches/home/home_presets", {
            DEFAULT_PRESET_NAME = "Zen Default",
            CUSTOM_PRESET_NAME = "Custom preset",
            getBuiltinPresets = function()
                return { { name = "Zen Default", builtin = true } }
            end,
            ensurePresetState = function() end,
            normalizeFeaturedConfig = function() end,
            normalizeStripConfig = function() end,
            normalizeLayoutGrid = function() end,
            isBuiltinPresetName = function() return false end,
            defaultHomePage = function()
                return {
                    modules = {
                        strip = {
                            controls = {
                                labels = {},
                                next_custom_id = 0,
                                order = {
                                    "page_left", "recent", "search", "tags", "page_right",
                                },
                                show_buttons = {
                                    page_left = true,
                                    recent = true,
                                    search = true,
                                    tags = true,
                                    page_right = true,
                                },
                                custom_buttons = {},
                            },
                        },
                    },
                }
            end,
        })
        ZenSpec.replace("modules/filebrowser/patches/home/home_quotes", {
            listFiles = function() return quote_files end,
        })
        ZenSpec.replace("modules/filebrowser/patches/home/components/registry", {
            CAPACITY_UNITS = 10,
            normalizeRows = function(rows) return rows end,
            list = function()
                return {
                    { id = "featured", label = "Featured book" },
                    { id = "strip", label = "Book strip" },
                }
            end,
            get = function(id) return { id = id, label = id, size = 2 } end,
            totalUnits = function() return 4 end,
            sizeUnits = function() return 2 end,
        })
        ZenSpec.replace("modules/filebrowser/patches/home/widgets/strip_common", {
            max_books_for_width = function(_width, two_rows)
                return responsive_strip_per_row * (two_rows and 2 or 1)
            end,
        })
        ZenSpec.replace("modules/filebrowser/patches/library_font", {
            getFontName = function() return "default" end,
        })
        ZenSpec.replace("common/reading_goals", {
            normalize = function(goals) return goals end,
            settingsItems = function() return {} end,
        })
        ZenSpec.replace("common/inline_icon_map", setmetatable({}, {
            __index = function(_self, key) return key end,
        }))
        ZenSpec.replace("common/ui/icon_menu_item", {
            decorate = function(item) return item end,
        })
        ZenSpec.replace("common/nav_button_model", {
            builtins = function()
                return {
                    { id = "recent", label = "Recent", source = true },
                    { id = "favorites", label = "Favorites", source = true },
                    { id = "to_be_read", label = "To Be Read", source = true },
                    { id = "authors", label = "Authors", source = true },
                }
            end,
            find = function(controls, id)
                for _i, entry in ipairs(require("common/nav_button_model").builtins()) do
                    if entry.id == id then return entry end
                end
                for _i, entry in ipairs(controls.custom_buttons or {}) do
                    if entry.id == id then return entry end
                end
            end,
            firstVisibleSource = function(controls)
                local model = require("common/nav_button_model")
                for _i, id in ipairs(controls.order or {}) do
                    if controls.show_buttons[id] == true then
                        local entry = model.find(controls, id)
                        if entry and entry.source == true then
                            return { kind = id }, id
                        end
                    end
                end
            end,
            label = function(_controls, entry) return entry.label end,
        })
        ZenSpec.replace("common/library_destination", {
            chooseFolder = function(callback) choose_folder = callback end,
            chooseTag = function(callback) choose_tag = callback end,
        })
        ZenSpec.replace("common/dispatcher_menu", {})
        ZenSpec.replace("modules/menu/app_launcher/native_menu", {})
        ZenSpec.replace("modules/menu/app_launcher/plugin_scan", {})
        ZenSpec.replace("common/tbr_index", {
            showOrder = function(options)
                tbr_order_calls = tbr_order_calls + 1
                tbr_order_options = options
            end,
        })
        ZenSpec.replace("common/ui/zen_arrange_list", {
            show = function(opts)
                arrange_options = opts
                arrange_history[#arrange_history + 1] = opts
            end,
        })
        ZenSpec.replace("modules/settings/zen_settings_page", {
            rememberStandaloneArrangeRoute = function(path, opener, arrange_path)
                remembered_routes[#remembered_routes + 1] = {
                    path = path,
                    opener = opener,
                    arrange_path = arrange_path,
                }
                return true, {
                    opener = { text = opener, occurrence = 1 },
                    path = arrange_path,
                }
            end,
        })
        ZenSpec.replace("apps/filemanager/filemanager", {})
        ZenSpec.unload("modules/settings/sections/library_settings/home_settings")

        require("modules/settings/sections/library_settings/home_settings").build({
            config = {},
            settings_apply = { refresh_tbr_on_menu_close = function() end },
        })
    end)

    it("shows Featured book settings only for custom content", function()
        local settings = require("modules/settings/sections/library_settings/home_settings")
        local plugin = { config = {} }
        assert.is_true(settings.openWidgetSettings("featured", plugin))
        assert.are.equal(plugin, arrange_options.plugin)

        local items = arrange_options.item_table
        assert.are.equal("Content: Recently read", item_text(items[1]))
        assert.is_nil(find_item(items, "Show widget title"))
        assert.is_false(has_item_prefix(items, "Book: "))
        assert.is_nil(find_item(items, "Clear book"))

        local parent = { updateItems = function() end }
        find_item(items[1].sub_item_table_func(parent), "Custom").callback()

        assert.are.equal("Content: Custom", item_text(parent.item_table[1]))
        assert.is_true(has_item_prefix(parent.item_table, "Book: "))
        assert.is_not_nil(find_item(parent.item_table, "Clear book"))

        find_item(parent.item_table[1].sub_item_table_func(parent), "Recently read").callback()
        assert.is_false(has_item_prefix(parent.item_table, "Book: "))
        assert.is_nil(find_item(parent.item_table, "Clear book"))
    end)

    it("keeps featured description wrapping disabled by default", function()
        local settings = require("modules/settings/sections/library_settings/home_settings")
        assert.is_true(settings.openWidgetSettings("featured"))

        local styles = find_item(arrange_options.item_table, "Text styles").sub_item_table_func()
        local description = find_item_prefix(styles, "Description:")
        local item = find_item(description.sub_item_table, "Wrap description text")
        assert.is_table(item)
        assert.is_false(item.checked_func())

        item.callback()
        assert.is_true(home_page.modules.featured.wrap_description_text)
        assert.is_true(item.checked_func())
    end)

    it("keeps the Home and featured top status bars mutually exclusive", function()
        local settings = require("modules/settings/sections/library_settings/home_settings")
        local section = settings.build({ config = {}, settings_apply = {} })
        local home_status = find_item(section.sub_item_table, "Show top status bar")

        assert.is_true(settings.openWidgetSettings("featured"))
        local featured_status = find_item(arrange_options.item_table, "Top status bar")
        assert.is_nil(find_item(featured_status.sub_item_table, "Show top status bar"))

        featured_status.checkmark_callback()
        assert.is_false(home_status.checked_func())
        assert.is_true(featured_status.checked_func())

        home_status.callback()
        assert.is_true(home_status.checked_func())
        assert.is_false(featured_status.checked_func())
    end)

    it("puts the progress toggle on its settings entry", function()
        local settings = require("modules/settings/sections/library_settings/home_settings")
        assert.is_true(settings.openWidgetSettings("featured"))

        local progress = find_item(arrange_options.item_table, "Progress")
        assert.is_table(progress)
        assert.is_nil(find_item(progress.sub_item_table, "Enable"))
        assert.is_true(progress.checked_func())

        progress.checkmark_callback()
        assert.is_false(home_page.modules.featured.show_progress)
        assert.is_false(progress.checked_func())
    end)

    it("puts featured metadata toggles and description options on their style entries", function()
        local settings = require("modules/settings/sections/library_settings/home_settings")
        assert.is_true(settings.openWidgetSettings("featured"))

        local items = arrange_options.item_table
        local styles = find_item(items, "Text styles").sub_item_table_func()
        local author = find_item_prefix(styles, "Author:")
        local series = find_item_prefix(styles, "Series:")
        local description = find_item_prefix(styles, "Description:")

        assert.is_nil(find_item(items, "Show description"))
        assert.is_true(author.checked_func())
        assert.is_true(series.checked_func())
        assert.is_true(description.checked_func())

        author.checkmark_callback()
        series.checkmark_callback()
        description.checkmark_callback()
        assert.is_false(home_page.modules.featured.show_author)
        assert.is_false(home_page.modules.featured.show_series)
        assert.is_false(home_page.modules.featured.show_description)

        local justify = find_item(description.sub_item_table, "Justify text")
        local html = find_item(description.sub_item_table, "HTML")
        assert.is_false(justify.checked_func())
        assert.is_false(html.checked_func())
        justify.callback()
        html.callback()
        assert.is_true(home_page.modules.featured.justify_description_text)
        assert.is_true(home_page.modules.featured.format_description_html)
    end)

    it("keeps the plugin when Widgets is opened from the settings page", function()
        local plugin = { config = {} }
        local section = require("modules/settings/sections/library_settings/home_settings").build({
            plugin = plugin,
            config = {},
            settings_apply = {},
        })

        section.sub_item_table[1].callback({})

        assert.are.equal(plugin, arrange_options.plugin)
    end)

    it("uses radio buttons to mark the active Home preset", function()
        home_page.active_preset = "Zen Default"
        local section = require("modules/settings/sections/library_settings/home_settings").build({
            config = {},
            settings_apply = {},
        })

        local presets = find_item(section.sub_item_table, "Presets").sub_item_table_func()
        local builtin = find_item(presets, "Zen Default")
        local custom = find_item(presets, "My preset")

        assert.is_true(builtin.radio)
        assert.is_true(builtin.checked_func())
        assert.is_true(custom.radio)
        assert.is_false(custom.checked_func())
        assert.is_nil(find_item(presets, "* Zen Default"))
    end)

    it("removes widget-title settings and legacy values", function()
        local settings = require("modules/settings/sections/library_settings/home_settings")
        for _i, id in ipairs({ "featured", "strip", "reading_goals", "stats_triplet", "quotes" }) do
            assert.is_nil(home_page.modules[id].show_module_title)
            assert.is_true(settings.openWidgetSettings(id))
            assert.is_nil(find_item(arrange_options.item_table, "Show widget title"))
        end
    end)

    it("removes shared Home font-size controls and legacy values", function()
        home_page.font_size = 23
        home_page.font_size_override = true
        home_page.quotes.use_home_font_size = true

        local settings = require("modules/settings/sections/library_settings/home_settings")
        local section = settings.build({ config = {}, settings_apply = {} })

        assert.is_nil(home_page.font_size)
        assert.is_nil(home_page.font_size_override)
        assert.is_nil(home_page.quotes.use_home_font_size)
        assert.is_false(has_item_prefix(section.sub_item_table, "Default font size:"))
        for _i, id in ipairs({ "reading_goals", "stats_triplet", "quotes" }) do
            assert.is_true(settings.openWidgetSettings(id))
            assert.is_nil(find_item(arrange_options.item_table, "Use default font size"))
            assert.is_nil(find_item(arrange_options.item_table, "Use Home default font size"))
        end
    end)

    it("shows Strip filters and custom books only for their content", function()
        local settings = require("modules/settings/sections/library_settings/home_settings")
        assert.is_true(settings.openWidgetSettings("strip"))

        local items = arrange_options.item_table
        assert.are.equal("Content: Recent", item_text(items[1]))
        assert.is_nil(find_item(items, "Show widget title"))
        assert.is_nil(find_item(items, "Order"))
        assert.is_not_nil(find_item(items, "Recent filters"))
        assert.is_nil(find_item(items, "Custom books"))

        local parent = { updateItems = function() end }
        find_item(items[1].sub_item_table_func(parent), "Custom books").callback()

        assert.is_nil(home_page.strip_memory)
        assert.is_nil(find_item(parent.item_table, "Recent filters"))
        assert.is_not_nil(find_item(parent.item_table, "Custom books"))

        find_item(parent.item_table[1].sub_item_table_func(parent), "Favorites").callback()
        assert.is_nil(find_item(parent.item_table, "Recent filters"))
        assert.is_nil(find_item(parent.item_table, "Custom books"))
    end)

    it("uses the first visible source tab instead of a Content option", function()
        local strip = home_page.modules.strip
        strip.controls.enabled = true
        strip.controls.order = { "recent", "favorites" }
        strip.default_source = { kind = "favorites" }

        local settings = require("modules/settings/sections/library_settings/home_settings")
        assert.is_true(settings.openWidgetSettings("strip"))

        local items = arrange_options.item_table
        assert.is_false(has_item_prefix(items, "Content: "))
        assert.is_not_nil(find_item(items, "Controls"))
        assert.is_not_nil(find_item(items, "Recent filters"))
    end)

    it("exposes the shared TBR order from Strip content and controls", function()
        local strip = home_page.modules.strip
        strip.default_source = { kind = "to_be_read" }
        strip.controls.order = { "recent", "to_be_read" }
        strip.controls.show_buttons.to_be_read = true

        local settings = require("modules/settings/sections/library_settings/home_settings")
        assert.is_true(settings.openWidgetSettings("strip"))
        local order = find_item(arrange_options.item_table, "Order")
        assert.is_table(order)
        order.callback()
        assert.is_function(tbr_order_options.on_change)

        strip.controls.enabled = true
        assert.is_true(settings.openWidgetSettings("strip"))
        local controls = find_item(arrange_options.item_table, "Controls")
        find_item(controls.sub_item_table_func(), "Tabs").callback({})
        local tbr = find_item(arrange_options.item_table, "To Be Read")
        local tab_order = find_item(tbr.sub_item_table, "Order")
        assert.is_table(tab_order)
        tab_order.callback()
        assert.is_function(tbr_order_options.on_change)

        assert.are.equal(2, tbr_order_calls)
    end)

    it("exposes author name sorting from the Authors control tab", function()
        local strip = home_page.modules.strip
        strip.controls.enabled = true
        strip.controls.order = { "recent", "authors" }
        strip.controls.show_buttons.authors = true
        local config = { group_view = { authors_collate = "authors" } }
        local saves = 0
        local settings = require("modules/settings/sections/library_settings/home_settings")
        settings.build({
            config = config,
            plugin = { saveConfig = function() saves = saves + 1 end },
            settings_apply = {},
        })
        assert.is_true(settings.openWidgetSettings("strip"))

        local controls = find_item(arrange_options.item_table, "Controls")
        find_item(controls.sub_item_table_func(), "Tabs").callback({})
        local authors = find_item(arrange_options.item_table, "Authors")
        local sort = find_item(authors.sub_item_table, "Sort by: First name")
        local first = find_item(sort.sub_item_table, "First name")
        local last = find_item(sort.sub_item_table, "Last name")

        assert.is_true(first.radio)
        assert.is_true(first.checked_func())
        assert.is_false(last.checked_func())
        last.callback()
        assert.are.equal("authors_last", config.group_view.authors_collate)
        assert.are.equal("Sort by: Last name", item_text(sort))
        assert.are.equal(1, saves)
    end)

    it("exposes strip control font face, size, and weight settings", function()
        local settings = require("modules/settings/sections/library_settings/home_settings")
        assert.is_true(settings.openWidgetSettings("strip"))

        local controls = find_item(arrange_options.item_table, "Controls")
        local controls_items = controls.sub_item_table_func()
        local font = find_item(controls_items, "Font: default, 10, regular")
        assert.is_not_nil(font)

        local font_items = font.sub_item_table_func()
        assert.is_not_nil(find_item(font_items, "Font size: 10"))
        assert.is_not_nil(find_item(font_items, "Font: default"))
        assert.is_not_nil(find_item(font_items, "Bold"))
        assert.is_not_nil(find_item(font_items, "Use default style"))
    end)

    it("refreshes the Strip book count after the spinner changes it", function()
        ZenSpec.replace("ui/widget/spinwidget", {
            new = function(_self, values) return values end,
        })
        local settings = require("modules/settings/sections/library_settings/home_settings")
        assert.is_true(settings.openWidgetSettings("strip"))

        local maximum = find_item(arrange_options.item_table, "Max books shown: 4")
        assert.is_true(maximum.keep_menu_open)
        local updates = 0
        maximum.callback({
            updateItems = function() updates = updates + 1 end,
        })
        shown[#shown].callback({ value = 5 })

        assert.are.equal(5, home_page.modules.strip.count)
        assert.are.equal(1, updates)
        assert.are.equal("Max books shown: 5", item_text(maximum))
    end)

    it("limits the Strip book count spinner to responsive capacity", function()
        ZenSpec.replace("ui/widget/spinwidget", {
            new = function(_self, values) return values end,
        })
        responsive_strip_per_row = 4
        home_page.modules.strip.two_rows = true
        home_page.modules.strip.count = 10
        local settings = require("modules/settings/sections/library_settings/home_settings")
        assert.is_true(settings.openWidgetSettings("strip"))

        local maximum = find_item(arrange_options.item_table, "Max books shown: 10")
        maximum.callback({ updateItems = function() end })

        assert.are.equal(8, shown[#shown].value)
        assert.are.equal(8, shown[#shown].value_max)
        assert.is_true(shown[#shown].ok_always_enabled)
        assert.are.equal(10, home_page.modules.strip.count)

        shown[#shown].callback({ value = 8 })
        assert.are.equal(8, home_page.modules.strip.count)
    end)

    it("caps automatic Date/time sizing and lets the maximum be changed", function()
        ZenSpec.replace("ui/widget/spinwidget", {
            new = function(_self, values) return values end,
        })
        local settings = require("modules/settings/sections/library_settings/home_settings")
        assert.is_true(settings.openWidgetSettings("datetime"))

        local items = arrange_options.item_table
        local automatic = find_item(items, "Automatic font size")
        local maximum = find_item(items, "Maximum font size: 36")
        assert.is_true(automatic.checked_func())
        assert.is_not_nil(maximum)
        assert.is_true(maximum.enabled_func())

        maximum.callback({ updateItems = function() end })
        assert.are.equal(36, shown[#shown].value)
        assert.are.equal(160, shown[#shown].value_max)
        shown[#shown].callback({ value = 52 })
        assert.are.equal(52, home_page.modules.datetime.max_font_size)

        automatic.callback({ updateItems = function() end })
        assert.is_false(maximum.enabled_func())
    end)

    it("caps automatic stats sizing and disables its manual size", function()
        ZenSpec.replace("ui/widget/spinwidget", {
            new = function(_self, values) return values end,
        })
        local settings = require("modules/settings/sections/library_settings/home_settings")
        assert.is_true(settings.openWidgetSettings("stats_triplet"))

        local items = arrange_options.item_table
        local automatic = find_item(items, "Automatic font size")
        local maximum = find_item(items, "Maximum font size: 18")
        local size = find_item(items, "Font size: Automatic")
        assert.is_true(automatic.checked_func())
        assert.is_not_nil(maximum)
        assert.is_true(maximum.enabled_func())
        assert.is_not_nil(size)
        assert.is_false(size.enabled_func())

        maximum.callback({ updateItems = function() end })
        assert.are.equal(18, shown[#shown].value)
        assert.are.equal(64, shown[#shown].value_max)
        shown[#shown].callback({ value = 30 })
        assert.are.equal(30, home_page.modules.stats_triplet.max_font_size)
        assert.is_false(home_page.modules.stats_triplet.automatic_font_size)

        assert.is_false(automatic.checked_func())
        assert.is_false(maximum.enabled_func())
        assert.is_true(size.enabled_func())
        assert.are.equal("Font size: 16", item_text(size))

        size.callback({ updateItems = function() end })
        assert.are.equal(16, shown[#shown].value)
        assert.are.equal(64, shown[#shown].value_max)
        shown[#shown].callback({ value = 22 })
        assert.are.equal(22, home_page.modules.stats_triplet.font_size)
    end)

    it("disables the inactive quote font-size control", function()
        ZenSpec.replace("ui/widget/spinwidget", {
            new = function(_self, values) return values end,
        })
        home_page.quotes.automatic_font_size = true

        local settings = require("modules/settings/sections/library_settings/home_settings")
        assert.is_true(settings.openWidgetSettings("quotes"))

        local items = arrange_options.item_table
        local automatic = find_item(items, "Automatic font size")
        local maximum = find_item(items, "Maximum font size: 14")
        local size = find_item(items, "Font size: 12")
        assert.is_true(automatic.checked_func())
        assert.is_true(maximum.enabled_func())
        assert.is_false(size.enabled_func())

        automatic.callback({ updateItems = function() end })
        assert.is_false(automatic.checked_func())
        assert.is_false(maximum.enabled_func())
        assert.is_true(size.enabled_func())
    end)

    it("selects and combines named custom quote files", function()
        quote_files = { "quotes.lua", "wisdom.lua" }

        local settings = require("modules/settings/sections/library_settings/home_settings")
        assert.is_true(settings.openWidgetSettings("quotes"))

        local sources = find_item(arrange_options.item_table, "Quote sources")
        local custom = find_item(sources.sub_item_table, "Custom quotes")
        local custom_items = custom.sub_item_table_func()
        local default_file = find_item(custom_items, "quotes.lua")
        local wisdom_file = find_item(custom_items, "wisdom.lua")
        assert.is_nil(find_item(custom_items, "Enable"))
        assert.is_false(default_file.checked_func())
        assert.is_false(wisdom_file.checked_func())

        default_file.callback()
        wisdom_file.callback()
        default_file.callback()

        assert.are.same({ ["wisdom.lua"] = true }, home_page.quotes.custom_files)
        assert.is_true(home_page.quotes.sources.custom)

        wisdom_file.callback()
        assert.is_false(home_page.quotes.sources.custom)
        assert.is_true(home_page.quotes.sources.default)
    end)

    it("keeps quotes.lua selected for legacy custom quote settings", function()
        home_page.quotes.sources = { custom = true }

        local settings = require("modules/settings/sections/library_settings/home_settings")
        assert.is_true(settings.openWidgetSettings("quotes"))

        local sources = find_item(arrange_options.item_table, "Quote sources")
        local custom = find_item(sources.sub_item_table, "Custom quotes")
        local quotes_file = find_item(custom.sub_item_table_func(), "quotes.lua")
        assert.is_true(quotes_file.checked_func())
    end)

    it("confirms before deleting a Strip control tab and returns to Tabs", function()
        local settings = require("modules/settings/sections/library_settings/home_settings")
        home_page.strip_memory = {
            active_id = "favorites",
            source = { kind = "favorites" },
        }
        assert.is_true(settings.openWidgetSettings("strip"))

        local controls = find_item(arrange_options.item_table, "Controls")
        local controls_items = controls.sub_item_table_func()
        local inherited_resume = {
            opener = { text = "Widgets", occurrence = 1 },
            path = { "strip", "Controls" },
        }
        find_item(controls_items, "Tabs").callback({
            _zen_settings_resume = inherited_resume,
        })

        assert.are.equal(2, #arrange_history)
        assert.are.equal(inherited_resume.opener, arrange_options.settings_resume.opener)
        assert.are.same({ "strip", "Controls", "Tabs" },
            arrange_options.settings_resume.path)
        local favorites = find_item(arrange_options.item_table, "Favorites")
        local backs = 0
        find_item(favorites.sub_item_table, "Delete").callback({
            backToUpperMenu = function() backs = backs + 1 end,
        })

        assert.are.same({ "recent", "favorites" },
            home_page.modules.strip.controls.order)
        assert.are.equal(0, backs)
        assert.are.equal("Delete this tab?", shown[1].text)
        assert.are.equal("Delete", shown[1].ok_text)

        shown[1].ok_callback()

        assert.are.same({ "recent" }, home_page.modules.strip.controls.order)
        assert.is_nil(home_page.modules.strip.controls.show_buttons.favorites)
        assert.is_nil(home_page.strip_memory)
        assert.are.equal(1, backs)
    end)

    it("adds multiple folder sources and a specific-tag source to Strip controls", function()
        local settings = require("modules/settings/sections/library_settings/home_settings")
        assert.is_true(settings.openWidgetSettings("strip"))
        local controls_item = find_item(arrange_options.item_table, "Controls")
        find_item(controls_item.sub_item_table_func(), "Tabs").callback({})
        local add_folder = find_item(arrange_options.add_item_table, "Folder")
        local add_tag = find_item(arrange_options.add_item_table, "Specific tag")

        add_folder.callback()
        choose_folder("/library/Fiction")
        add_folder.callback()
        choose_folder("/library/Nonfiction")
        add_tag.callback()
        choose_tag("Science")

        assert.are.same({
            { id = "hs_1", type = "folder", folder = "/library/Fiction",
                label = "Fiction" },
            { id = "hs_2", type = "folder", folder = "/library/Nonfiction",
                label = "Nonfiction" },
            { id = "hs_3", type = "tag", tag = "Science", label = "Science" },
        }, home_page.modules.strip.controls.custom_buttons)
    end)

    it("resets Strip control tabs without changing control display settings", function()
        local strip = home_page.modules.strip
        strip.controls.enabled = true
        strip.controls.labels = { favorites = "Saved" }
        strip.controls.next_custom_id = 4
        strip.controls.order = { "favorites", "hs_4" }
        strip.controls.show_buttons = { favorites = true, hs_4 = true }
        strip.controls.custom_buttons = {
            { id = "hs_4", type = "tag", tag = "Science" },
        }
        strip.controls.text_style = {
            font_face = "custom", font_size = 13, bold = true,
        }

        local settings = require("modules/settings/sections/library_settings/home_settings")
        assert.is_true(settings.openWidgetSettings("strip"))
        local controls = find_item(arrange_options.item_table, "Controls")
        local controls_items = controls.sub_item_table_func()
        local updates = 0
        find_item(controls_items, "Reset to defaults").callback({
            updateItems = function() updates = updates + 1 end,
        })

        assert.are.same({ "favorites", "hs_4" }, strip.controls.order)
        assert.are.equal("Reset Controls to defaults?", shown[1].text)
        assert.are.equal("Reset", shown[1].ok_text)

        shown[1].ok_callback()

        assert.are.same({
            "page_left", "recent", "search", "tags", "page_right", "hs_4",
        }, strip.controls.order)
        assert.are.same({
            page_left = true,
            recent = true,
            search = true,
            tags = true,
            page_right = true,
            hs_4 = false,
        }, strip.controls.show_buttons)
        assert.are.same({}, strip.controls.labels)
        assert.are.same({
            { id = "hs_4", type = "tag", tag = "Science" },
        }, strip.controls.custom_buttons)
        assert.are.equal(4, strip.controls.next_custom_id)
        assert.is_true(strip.controls.enabled)
        assert.are.same({
            font_face = "custom", font_size = 13, bold = true,
        }, strip.controls.text_style)
        assert.is_nil(home_page.strip_memory)
        assert.are.equal(1, updates)
    end)

    it("remembers Strip Controls and Tabs when opened from standalone settings", function()
        local strip = home_page.modules.strip
        table.insert(strip.controls.order, "to_be_read")
        strip.controls.show_buttons.to_be_read = true
        local settings = require("modules/settings/sections/library_settings/home_settings")
        assert.is_true(settings.openWidgetSettings("strip"))
        local root_resume = arrange_options.settings_resume
        assert.are.same({ "strip" }, root_resume.path)

        local controls = find_item(arrange_options.item_table, "Controls")
        find_item(controls.sub_item_table_func(), "Tabs").callback({
            _zen_settings_resume = {
                opener = root_resume.opener,
                path = { "strip", "Controls" },
            },
        })

        local remembered = remembered_routes[#remembered_routes]
        assert.are.same({ "strip", "Controls", "Tabs" },
            arrange_options.settings_resume.path)

        local tbr = find_item(arrange_options.item_table, "To Be Read")
        find_item(tbr.sub_item_table, "Order").callback({
            _zen_settings_resume = {
                opener = root_resume.opener,
                path = { "strip", "Controls", "Tabs", "to_be_read" },
            },
        })
        assert.are.same({ "strip", "Controls", "Tabs", "to_be_read" },
            tbr_order_options.settings_resume.path)
        assert.are.equal("Widgets", remembered.opener)
    end)
end)
