describe("Zen settings page", function()
    local Page
    local PageModule
    local saved_modules
    local shown_widgets
    local deferred_apply_flushes
    local translation_refreshes

    local dependency_names = {
        "gettext",
        "ui/bidi",
        "ui/widget/menu",
        "ui/widget/infomessage",
        "ui/uimanager",
        "ffi/utf8proc",
        "util",
        "device",
        "ui/size",
        "ffi/blitbuffer",
        "ui/widget/inputdialog",
        "common/i18n",
        "common/ui/icon_menu_item",
        "common/ui/truncated_text_message",
        "modules/global/patches/menu_top_swipe",
        "modules/settings/zen_settings",
        "modules/settings/zen_settings_apply",
        "common/ui/zen_settings_titlebar",
        "apps/filemanager/filemanager",
    }

    local Menu = {}

    function Menu:extend(prototype)
        prototype = prototype or {}
        setmetatable(prototype, { __index = self })
        prototype.__index = prototype
        return prototype
    end

    function Menu:new(instance)
        instance = instance or {}
        setmetatable(instance, { __index = self })
        instance:init()
        return instance
    end

    function Menu:init()
        self.item_table_stack = {}
        self.title_bar = self.custom_title_bar
        self:updateItems(1)
    end

    function Menu:updateItems(select_number)
        self.last_select_number = select_number
        self.updated_item_tables = self.updated_item_tables or {}
        self.updated_item_tables[#self.updated_item_tables + 1] = self.item_table
    end

    function Menu:onTap()
        self.top_menu_taps = (self.top_menu_taps or 0) + 1
        return true
    end

    function Menu:onSwipe()
        self.top_menu_swipes = (self.top_menu_swipes or 0) + 1
        return true
    end

    function Menu:getPageNumber()
        return 1
    end

    function Menu.onCloseWidget() end

    before_each(function()
        saved_modules = {}
        shown_widgets = {}
        deferred_apply_flushes = 0
        translation_refreshes = 0
        for _i, name in ipairs(dependency_names) do
            saved_modules[name] = package.loaded[name] or false
        end
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/bidi", { mirroredUILayout = function() return false end })
        ZenSpec.replace("ui/widget/menu", Menu)
        ZenSpec.replace("ui/widget/infomessage", {
            new = function(_self, opts)
                opts.movable = {}
                return opts
            end,
        })
        ZenSpec.replace("ui/uimanager", {
            close = function() end,
            nextTick = function(_self, callback) callback() end,
            show = function(_self, widget) shown_widgets[#shown_widgets + 1] = widget end,
        })
        ZenSpec.replace("ffi/utf8proc", {
            lowercase = function(text) return text:lower() end,
        })
        ZenSpec.replace("util", { fixUtf8 = function(text) return text end })
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
            },
        })
        ZenSpec.replace("ui/size", {
            line = { thin = 1 },
            padding = { small = 4 },
        })
        ZenSpec.replace("ffi/blitbuffer", { COLOR_LIGHT_GRAY = 1 })
        ZenSpec.replace("ui/widget/inputdialog", { init = function() end })
        ZenSpec.replace("common/i18n", {
            refresh = function()
                translation_refreshes = translation_refreshes + 1
            end,
        })
        ZenSpec.replace("common/ui/icon_menu_item", {
            getSettingsFontSize = function() return 18 end,
            getSettingsRowHeight = function() return 64 end,
            installMenuPatch = function() end,
        })
        ZenSpec.replace("modules/settings/zen_settings", {
            build = function() return { sub_item_table = {} } end,
        })
        ZenSpec.replace("modules/settings/zen_settings_apply", {
            flush_deferred_on_settings_close = function()
                deferred_apply_flushes = deferred_apply_flushes + 1
            end,
        })
        ZenSpec.replace("apps/filemanager/filemanager", {
            instance = {
                menu = {
                    onShowMenu = function(self)
                        self.opened = (self.opened or 0) + 1
                    end,
                },
            },
        })
        ZenSpec.replace("common/ui/zen_settings_titlebar", {
            new = function(_self, opts)
                opts.setState = function(self, title, back_visible, search_visible)
                    self.title = title
                    self.back_visible = back_visible
                    self.search_visible = search_visible
                end
                opts.setQuery = function(self, query) self.query = query end
                opts.collapseSearch = function(self)
                    self.search_collapsed = true
                end
                return opts
            end,
        })
        ZenSpec.unload("common/ui/truncated_text_message")
        ZenSpec.unload("modules/settings/zen_settings_page")
        PageModule = require("modules/settings/zen_settings_page")
        Page = PageModule.Page
    end)

    after_each(function()
        _G.__ZEN_UI_SETTINGS_PAGE = nil
        ZenSpec.unload("modules/settings/zen_settings_page")
        for _i, name in ipairs(dependency_names) do
            package.loaded[name] = saved_modules[name] or nil
        end
    end)

    local function make_page(items)
        items._zen_title = "Settings"
        return Page:new{
            title = "Settings",
            item_table = items,
            _root_items = items,
        }
    end

    it("loads the settings builder only when opening Settings", function()
        local name = "modules/settings/zen_settings"
        local builder, preload = package.loaded[name], package.preload[name]
        local loads = 0
        package.loaded[name] = nil
        package.preload[name] = function()
            loads = loads + 1
            return builder
        end
        local ok, err = pcall(function()
            ZenSpec.unload("modules/settings/zen_settings_page")
            PageModule = require("modules/settings/zen_settings_page")
            assert.are.equal(0, loads)
            local page = PageModule.show({ config = {} })
            assert.are.equal(1, loads)
            assert.are.equal(page, shown_widgets[1])
        end)
        package.preload[name], package.loaded[name] = preload, builder
        assert.is_true(ok, err)
    end)

    it("shows no root back button, navigates submenus, and updates radio choices", function()
        local choice = "a"
        local radio = {
            text = "Choice B",
            radio = true,
            checked_func = function() return choice == "b" end,
            callback = function() choice = "b" end,
        }
        local library_items = { radio }
        local library = { text = "Library >", sub_item_table = library_items }
        local settings = make_page({ library })

        assert.is_false(settings.title_bar.back_visible)
        assert.is_true(settings.title_bar.search_visible)
        assert.is_true(settings.title_bar.title_full_width)
        assert.are.equal("Library", library._zen_display_text)
        assert.is_true(library._zen_has_submenu)

        settings.page = 2
        settings:onMenuSelect(library)
        assert.are.equal(1, settings.page)
        assert.are.equal("Library", settings.title_bar.title)
        assert.is_true(settings.title_bar.back_visible)
        assert.is_true(settings.title_bar.search_visible)

        settings:onMenuSelect(radio)
        assert.are.equal("b", choice)
        assert.is_true(radio.checked_func())

        settings:backToUpperMenu()
        assert.are.equal("Settings", settings.title_bar.title)
        assert.is_false(settings.title_bar.back_visible)
        assert.is_true(settings.title_bar.search_visible)
    end)

    it("toggles configurable submenu rows only from their outer switch", function()
        local active = false
        local date = {
            text = "Date",
            checked_func = function() return active end,
            checkmark_callback = function() active = not active end,
            sub_item_table = {{ text = "MM/DD/YY" }},
            _zen_settings_control_bounds = { left = 0.75, right = 0.9 },
        }
        local settings = make_page({ date })

        settings:onMenuSelect(date, { x = 0.8 })
        assert.is_true(active)
        assert.are.equal(settings._root_items, settings.item_table)

        settings:onMenuSelect(date, { x = 0.95 })
        assert.are.equal(date.sub_item_table, settings.item_table)
        assert.are.equal("Date", settings.title_bar.title)
    end)

    it("returns to the settings root when the header Back button is held", function()
        local detail = { text = "Detail", sub_item_table = {{ text = "Option" }} }
        local library = { text = "Library >", sub_item_table = { detail } }
        local settings = make_page({ library })

        settings:onMenuSelect(library)
        settings:onMenuSelect(detail)
        assert.are.equal("Detail", settings.title_bar.title)
        assert.is_function(settings.title_bar.back_hold_callback)

        settings.title_bar.back_hold_callback()

        assert.are.equal("Settings", settings.title_bar.title)
        assert.are.equal(settings._root_items, settings.item_table)
        assert.are.equal(0, #settings.item_table_stack)
        assert.is_false(settings.title_bar.back_visible)
    end)

    it("shows full truncated row text on hold while preserving explicit help", function()
        local plain = { text = "Plain setting" }
        local truncated = {
            text = "A setting label too long for its row",
            _zen_settings_text_truncated = true,
        }
        local help = { text = "Helped setting", help_text = "Helpful details" }
        local settings = make_page({ plain, truncated, help })
        settings.item_group = {
            {
                entry = truncated,
                _underline_container = { dimen = { x = 20, y = 300, w = 560, h = 64 } },
            },
        }

        assert.is_true(settings:onMenuHold(plain, true))
        assert.are.equal(0, #shown_widgets)

        assert.is_true(settings:onMenuHold(truncated, true))
        assert.are.equal(1, #shown_widgets)
        assert.are.equal("A setting label too long for its row", shown_widgets[1].text)
        assert.is_false(shown_widgets[1].show_icon)
        assert.are.same({ y = 296, h = 72 }, shown_widgets[1].movable.anchor)

        assert.is_true(settings:onMenuHold(help, true))
        assert.are.equal(2, #shown_widgets)
        assert.are.equal("Helpful details", shown_widgets[2].text)
    end)

    it("reuses the active settings page", function()
        local plugin = { config = {} }
        local first = PageModule.show(plugin)
        local second = PageModule.show(plugin)

        assert.are.equal(first, second)
        assert.are.equal(1, #shown_widgets)
        assert.are.equal(1, translation_refreshes)

        first:closeMenu()
        local reopened = PageModule.show(plugin)
        assert.are_not.equal(first, reopened)
        assert.are.equal(2, #shown_widgets)
        assert.are.equal(2, translation_refreshes)
    end)

    it("closes every arrange overlay without losing the deepest resume route", function()
        local restored_path
        require("modules/settings/zen_settings").build = function()
            return {
                sub_item_table = {{
                    text = "Widgets",
                    keep_menu_open = true,
                    callback = function()
                        restored_path = PageModule.claimArrangeRoute().path
                    end,
                }},
            }
        end
        local plugin = { config = {} }
        local page = PageModule.show(plugin)
        local closed = {}
        local opener = { text = "Widgets", occurrence = 1 }
        local deepest_path = { "strip", "Controls", "Tabs", "To Be Read" }
        PageModule.noteArrangeRoute({ opener = opener, path = deepest_path })
        local lower_arrange = {
            _zen_arrange_close_all = function()
                closed[#closed + 1] = "lower"
                PageModule.noteArrangeRoute({
                    opener = opener,
                    path = { "strip", "Controls" },
                })
            end,
        }
        local upper_arrange = {
            _zen_arrange_close_all = function()
                closed[#closed + 1] = "upper"
                PageModule.noteArrangeRoute({
                    opener = opener,
                    path = { "strip", "Controls", "Tabs" },
                })
            end,
        }
        local UIManager = require("ui/uimanager")
        UIManager._window_stack = {
            { widget = page },
            { widget = lower_arrange },
            { widget = upper_arrange },
        }
        local orig_close = page.closeMenu
        page.closeMenu = function(self)
            closed[#closed + 1] = "settings"
            return orig_close(self)
        end

        assert.is_true(PageModule.closeActive())
        assert.are.same({ "upper", "lower", "settings" }, closed)
        assert.is_true(page._closed)
        UIManager._window_stack = nil

        PageModule.show(plugin)
        assert.are.same(deepest_path, restored_path)
    end)

    it("closes and restores a standalone nested arrange stack", function()
        local restored_path
        require("modules/settings/zen_settings").build = function()
            return {
                sub_item_table = {{
                    text = "Home",
                    sub_item_table = {{
                        text = "Widgets",
                        keep_menu_open = true,
                        callback = function()
                            restored_path = PageModule.claimArrangeRoute().path
                        end,
                    }},
                }},
            }
        end
        local ok, standalone_resume = PageModule.rememberStandaloneArrangeRoute({
            { text = "Home", occurrence = 1 },
        }, "Widgets", { "strip" })
        assert.is_true(ok)
        assert.are.same({ "strip" }, standalone_resume.path)

        local opener = standalone_resume.opener
        local deepest_path = {
            "strip", "Controls", "Tabs", "to_be_read", "Order",
        }
        PageModule.noteArrangeRoute({ opener = opener, path = deepest_path })
        local closed = {}
        local UIManager = require("ui/uimanager")
        UIManager._window_stack = {
            { widget = {
                _zen_arrange_close_all = function()
                    closed[#closed + 1] = "strip"
                    PageModule.noteArrangeRoute({
                        opener = opener,
                        path = { "strip" },
                    })
                end,
            }},
            { widget = {
                _zen_arrange_close_all = function()
                    closed[#closed + 1] = "tabs"
                    PageModule.noteArrangeRoute({
                        opener = opener,
                        path = { "strip", "Controls", "Tabs" },
                    })
                end,
            }},
        }

        assert.is_true(PageModule.closeActive())
        assert.are.same({ "tabs", "strip" }, closed)
        UIManager._window_stack = nil

        PageModule.show({ config = {} })
        assert.are.same(deepest_path, restored_path)
    end)

    it("allows the underlying screen to repaint when a deferred page closes", function()
        local settings = make_page({})
        settings.invisible = true
        settings._deferred_arrange_parent = true

        settings:closeMenu()

        assert.is_false(settings.invisible)
        assert.is_nil(settings._deferred_arrange_parent)
    end)

    it("flushes deferred setting changes after closing", function()
        local settings = make_page({})

        settings:closeMenu()

        assert.are.equal(1, deferred_apply_flushes)
    end)

    it("restores the last page for six seconds after closing", function()
        local original_time = os.time
        local now = 100
        rawset(os, "time", function() return now end)

        require("modules/settings/zen_settings").build = function()
            local opds = { text = "Zen OPDS", sub_item_table = {{ text = "Mosaic" }} }
            return {
                sub_item_table = {
                    { text = "Extras", sub_item_table = { opds } },
                },
            }
        end

        local plugin = { config = {} }
        local first = PageModule.show(plugin)
        first:onMenuSelect(first.item_table[1])
        first:onMenuSelect(first.item_table[1])
        first:closeMenu()

        now = 106
        local shown_titles = {}
        local UIManager = require("ui/uimanager")
        UIManager.show = function(_self, widget)
            shown_titles[#shown_titles + 1] = widget.title_bar.title
            shown_widgets[#shown_widgets + 1] = widget
        end
        local restored = PageModule.show(plugin)
        assert.are.same({ "Zen OPDS" }, shown_titles)
        assert.are.equal("Zen OPDS", restored.title_bar.title)
        assert.are.equal(2, #restored.item_table_stack)
        assert.are.same({ restored.item_table }, restored.updated_item_tables)
        restored:closeMenu()

        now = 113
        local expired = PageModule.show(plugin)
        assert.are.equal("Settings", expired.title_bar.title)

        rawset(os, "time", original_time)
    end)

    it("restores settings-launched arrange pages generically", function()
        local restored_arrange_path

        require("modules/settings/zen_settings").build = function()
            local widgets = {
                text = "Widgets",
                keep_menu_open = true,
                callback = function()
                    local route = PageModule.claimArrangeRoute()
                    if route.path[1] == "quotes" then
                        restored_arrange_path = route.path
                        require("ui/uimanager"):show({ title = "Quotes" })
                    else
                        PageModule.noteArrangeRoute({
                            opener = route.opener,
                            path = { "quotes" },
                        })
                    end
                end,
            }
            return {
                sub_item_table = {
                    {
                        text = "Extras",
                        sub_item_table = {
                            { text = "Stats", sub_item_table = { widgets } },
                        },
                    },
                },
            }
        end

        local plugin = { config = {} }
        local first = PageModule.show(plugin)
        first:onMenuSelect(first.item_table[1])
        first:onMenuSelect(first.item_table[1])
        first:onMenuSelect(first.item_table[1])
        first:closeMenu()

        shown_widgets = {}
        local restored = PageModule.show(plugin)
        assert.are.equal("Stats", restored.title_bar.title)
        assert.are.same({ "quotes" }, restored_arrange_path)
        assert.are.equal(2, #shown_widgets)
        assert.are.equal(restored, shown_widgets[1])
        assert.is_true(shown_widgets[1].invisible)
        assert.are.equal("Quotes", shown_widgets[2].title)
    end)

    it("restores a standalone widget-settings route from the top menu", function()
        local restored_arrange_path

        require("modules/settings/zen_settings").build = function()
            local widgets = {
                text = "Widgets",
                keep_menu_open = true,
                callback = function()
                    local route = PageModule.claimArrangeRoute()
                    restored_arrange_path = route.path
                end,
            }
            return {
                sub_item_table = {
                    {
                        text = "Extras",
                        sub_item_table = {
                            { text = "Stats", sub_item_table = { widgets } },
                        },
                    },
                },
            }
        end

        assert.is_true(PageModule.rememberStandaloneArrangeRoute({
            { text = "Extras", occurrence = 1 },
            { text = "Stats", occurrence = 1 },
        }, "Widgets", { "trend_graph" }))

        local restored = PageModule.show({ config = {} })
        assert.are.equal("Stats", restored.title_bar.title)
        assert.are.same({ "trend_graph" }, restored_arrange_path)
    end)

    it("does not replay an arrange route while the settings page stays open", function()
        local opened_paths = {}

        require("modules/settings/zen_settings").build = function()
            local buttons = {
                text = "Buttons",
                keep_menu_open = true,
                callback = function()
                    local route = PageModule.claimArrangeRoute()
                    opened_paths[#opened_paths + 1] = route.path
                    if #opened_paths == 1 then
                        PageModule.noteArrangeRoute({
                            opener = route.opener,
                            path = { "screenshot" },
                        })
                    end
                end,
            }
            return {
                sub_item_table = {
                    { text = "Controls", sub_item_table = { buttons } },
                },
            }
        end

        local page = PageModule.show({ config = {} })
        page:onMenuSelect(page.item_table[1])
        page:onMenuSelect(page.item_table[1])
        page:onMenuSelect(page.item_table[1])

        assert.are.same({}, opened_paths[1])
        assert.are.same({}, opened_paths[2])
    end)

    it("covers the underlying page when first opened", function()
        local settings = make_page({})

        assert.is_true(settings.covers_fullscreen)
        assert.is_nil(settings.title_bar.more_visible)
    end)

    it("restores the parent title when the parent table refreshes on back", function()
        local library = { text = "Library", sub_item_table = {{ text = "Layout" }} }
        local root = { library }
        root.needs_refresh = true
        root.refresh_func = function() return { library } end
        local settings = make_page(root)

        settings:onMenuSelect(library)
        assert.are.equal("Library", settings.title_bar.title)

        settings:backToUpperMenu()
        assert.are.equal("Settings", settings.title_bar.title)
        assert.is_false(settings.title_bar.back_visible)
    end)

    it("searches every settings branch and navigates to a matching row", function()
        local timeout = { text = "Screen timeout" }
        local controls = { text = "Controls", sub_item_table = { timeout } }
        local library = {
            text = "Library",
            sub_item_table = {{ text = "Items per page" }},
        }
        local settings = make_page({ controls, library })

        settings:onMenuSelect(library)
        settings:_onSearchChanged("screen")

        assert.is_true(settings._search_active)
        assert.are.equal(1, #settings.item_table)
        assert.are.equal("Screen timeout", settings.item_table[1].text)
        assert.are.equal("Controls", settings.item_table[1]._zen_settings_breadcrumb)

        settings:onMenuSelect(settings.item_table[1])
        assert.is_false(settings._search_active)
        assert.are.equal(controls.sub_item_table, settings.item_table)
        assert.are.equal("Controls", settings.title_bar.title)
        assert.is_true(settings.title_bar.search_collapsed)
        assert.are.equal(1, settings.itemnumber)
    end)

    it("hides gated settings from menus and search", function()
        local visible_plugin = { text = "Visible plugin", show_func = function() return true end }
        local hidden_plugin = { text = "Hidden plugin", show_func = function() return false end }
        local reader = {
            text = "Reader",
            sub_item_table = { visible_plugin, hidden_plugin },
        }
        local settings = make_page({
            { text = "Hidden root", show_func = function() return false end },
            reader,
        })

        assert.are.equal(1, #settings.item_table)
        assert.are.equal(reader, settings.item_table[1])
        settings:onMenuSelect(reader)
        assert.are.equal(1, #settings.item_table)
        assert.are.equal(visible_plugin, settings.item_table[1])

        settings:_onSearchChanged("plugin")
        assert.are.equal(1, #settings.item_table)
        assert.are.equal("Visible plugin", settings.item_table[1].text)
    end)

    it("does not run dynamic help actions while indexing settings", function()
        local help_calls = 0
        local custom_text = {
            text = "Custom text",
            help_text_func = function() help_calls = help_calls + 1 end,
        }
        local settings = make_page({
            { text = "Bottom status bar", sub_item_table = { custom_text } },
        })

        settings:_onSearchChanged("custom")

        assert.are.equal(0, help_calls)
        assert.are.equal(1, #settings.item_table)
        assert.are.equal("Custom text", settings.item_table[1].text)
    end)

    it("closes settings immediately when KOReader exits during a search", function()
        local settings = make_page({ { text = "Screen timeout" } })

        settings.title_bar.search_expanded = true
        settings:_onSearchChanged("screen")

        assert.is_true(settings:onExit())
        assert.is_true(settings._closed)
        assert.are.equal(1, deferred_apply_flushes)
    end)

    it("collapses an empty search pill to an icon when opening a submenu", function()
        local controls = { text = "Controls", sub_item_table = {{ text = "Screen timeout" }} }
        local settings = make_page({ controls })

        settings:_onSearchChanged("control")
        settings:_onSearchChanged("")
        settings:onMenuSelect(controls)

        assert.are.equal("Controls", settings.title_bar.title)
        assert.is_true(settings.title_bar.search_visible)
        assert.is_true(settings.title_bar.search_collapsed)
    end)

    it("opens the KOReader menu from the physical Menu key", function()
        local settings = make_page({})
        local menu = require("apps/filemanager/filemanager").instance.menu

        assert.is_true(settings:onLeftButtonTap())
        assert.are.equal(1, menu.opened)
    end)

    it("keeps top-menu taps away from header controls and their edges", function()
        local settings = make_page({})
        settings.title_bar.search_button = { dimen = { x = 50, y = 10, w = 20, h = 24 } }
        settings.title_bar.close_button = { dimen = { x = 100, y = 10, w = 24, h = 24 } }

        assert.is_true(settings:onTap(nil, { pos = { x = 46, y = 20 } }))
        assert.is_true(settings:onTap(nil, { pos = { x = 85, y = 20 } }))
        assert.is_true(settings:onTap(nil, { pos = { x = 85, y = 0 } }))
        assert.is_nil(settings.top_menu_taps)
        assert.is_true(settings:onSwipe(nil, { pos = { x = 55, y = 20 } }))
        assert.are.equal(1, settings.top_menu_swipes)
    end)

    it("leaves unoccupied header space for the KOReader top menu", function()
        local settings = make_page({})
        settings.title_bar.close_button = { dimen = { x = 50, y = 10, w = 24, h = 24 } }

        assert.is_true(settings:onTap(nil, { pos = { x = 100, y = 10 } }))
        assert.is_true(settings:onSwipe(nil, { pos = { x = 100, y = 10 } }))
        assert.are.equal(1, settings.top_menu_taps)
        assert.are.equal(1, settings.top_menu_swipes)
    end)

    it("opens an arrange-only item from search", function()
        local opened = 0
        local home = {
            text = "Home",
            _zen_search_items_func = function()
                return {
                    {
                        text = "Quotes",
                        _zen_search_breadcrumb = "Home",
                        _zen_search_open = function() opened = opened + 1 end,
                    },
                }
            end,
        }
        local settings = make_page({ home })

        settings:_onSearchChanged("quotes")

        assert.are.equal(1, #settings.item_table)
        assert.are.equal("Quotes", settings.item_table[1].text)
        assert.are.equal("Home", settings.item_table[1]._zen_settings_breadcrumb)
        assert.is_true(settings.item_table[1]._zen_has_submenu)

        settings:onMenuSelect(settings.item_table[1])

        assert.are.equal(1, opened)
        assert.is_false(settings._search_active)
        assert.is_true(settings.title_bar.search_collapsed)
    end)

end)
