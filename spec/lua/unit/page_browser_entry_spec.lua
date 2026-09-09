describe("page browser entry", function()
    local shown, events, zones, reader_store

    local function expect(condition, message)
        if not condition then error(message or "expectation failed", 2) end
    end

    local function logger_stub()
        return {
            dbg = function() end,
            warn = function() end,
            err = function() end,
            perf = function() end,
        }
    end

    local function install_widget_dependencies(PageBrowserWidget)
        local empty_modules = {
            "ui/font", "ui/geometry", "ui/widget/iconbutton", "ui/widget/iconwidget",
            "ui/widget/horizontalgroup", "ui/widget/verticalgroup", "ui/widget/verticalspan",
            "ui/widget/textwidget", "ui/widget/container/framecontainer",
            "ui/widget/container/centercontainer", "ui/widget/overlapgroup", "ffi/blitbuffer",
            "ui/size", "ui/gesturerange", "common/ui/zen_slider", "common/ui/zen_icon_button",
        }
        for _i, name in ipairs(empty_modules) do ZenSpec.replace(name, {}) end
        ZenSpec.replace("ui/bidi", { mirroredUILayout = function() return false end })
        ZenSpec.replace("ui/widget/pagebrowserwidget", PageBrowserWidget)
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
                scaleBySize = function(_, value) return value end,
            },
        })
    end

    before_each(function()
        shown, events, zones = nil, {}, nil
        reader_store = { settings = {}, presets = {} }
        _G.__ZEN_UI_PLUGIN = nil
        G_reader_settings = ZenSpec.memorySettings()
        ZenSpec.replace("common/plugin_root", "/tmp/zen-ui")
        ZenSpec.replace("common/utils", {
            resolveIcon = function() return nil end,
            resolveLocalIcon = function() return nil end,
        })
        ZenSpec.replace("common/zen_logger", { new = logger_stub })
        ZenSpec.replace("config/preset_store", {
            getSettings = function() return reader_store.settings end,
            loadStore = function() return reader_store end,
            saveStore = function(_, store)
                reader_store = store
                return true
            end,
        })
        ZenSpec.replace("modules/reader/zen_toc_widget", { set_plugin = function() end })
        ZenSpec.replace("ui/event", {
            new = function(_, name, ...)
                return { name = name, args = { ... } }
            end,
        })
        ZenSpec.replace("ui/uimanager", {
            show = function(_, widget) shown = widget end,
            scheduleIn = function() end,
            setDirty = function() end,
            unschedule = function() end,
        })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("apps/reader/modules/readersearch", {})
        ZenSpec.replace("ui/widget/inputdialog", { onTap = function() end })
        ZenSpec.replace("apps/reader/readerui", {})
        ZenSpec.unload("modules/filebrowser/patches/library_font")
        ZenSpec.unload("common/reader_font")
    end)

    after_each(function()
        _G.__ZEN_UI_PLUGIN = nil
        package.loaded["db"] = nil
        ZenSpec.unload("common/cover_utils")
        ZenSpec.unload("ui/widget/booklist")
        ZenSpec.unload("modules/reader/book_info_widget")
        ZenSpec.unload("modules/reader/book_details")
        ZenSpec.unload("modules/reader/patches/page_browser")
        ZenSpec.unload("modules/filebrowser/patches/library_font")
        ZenSpec.unload("common/reader_font")
    end)

    it("renders Android thumbnails without a subprocess", function()
        local PageBrowserWidget = {}
        install_widget_dependencies(PageBrowserWidget)
        ZenSpec.replace("apps/reader/modules/readermenu", {})
        ZenSpec.replace("apps/reader/modules/readerconfig", {})

        local Device = require("device")
        Device.isAndroid = function() return true end
        local stock_check_calls = 0
        local ReaderThumbnail = {
            checkTileGeneration = function() stock_check_calls = stock_check_calls + 1 end,
        }
        ZenSpec.replace("apps/reader/modules/readerthumbnail", ReaderThumbnail)
        ZenSpec.replace("ui/renderimage", {
            scaleBlitBuffer = function(_, _bb, width, height)
                return { stride = width, h = height }
            end,
        })
        ZenSpec.replace("document/tilecacheitem", {
            new = function(_, spec) return spec end,
        })
        ZenSpec.replace("logger", logger_stub())

        require("modules/reader/patches/page_browser")()

        local inserted, generated, save_calls
        local statistics = {}
        local ui = setmetatable({
            statistics = statistics,
            view = { footer_visible = true, state = { page = 2, zoom = 3, rotation = 4 } },
        }, {
            __index = {
                saveSettings = function() save_calls = (save_calls or 0) + 1 end,
            },
        })
        local thumbnail = {
            ui = ui,
            tile_cache = { insert = function(_, hash, tile) inserted = { hash, tile } end },
            _getPageImage = function(self)
                self.ui.saveSettings = function() end
                self.ui.statistics = nil
                self.ui.view.footer_visible = false
                self.ui.view.state.page = 99
                return {
                    getWidth = function() return 600 end,
                    getHeight = function() return 800 end,
                }
            end,
        }
        local request = {
            page = 7, width = 300, height = 200, hash = "page-7", batch_id = 5,
            when_generated_callback = function(tile, batch_id, delayed)
                generated = { tile, batch_id, delayed }
            end,
        }

        expect(ReaderThumbnail.startTileGeneration(thumbnail, request) == true)
        expect(thumbnail.ui.view.footer_visible == true)
        expect(thumbnail.ui.view.state.page == 2)
        expect(thumbnail.ui.view.state.zoom == 3)
        expect(thumbnail.ui.view.state.rotation == 4)
        expect(rawget(ui, "saveSettings") == nil)
        ui:saveSettings()
        expect(save_calls == 1)
        expect(ui.statistics == statistics)
        expect(ReaderThumbnail.checkTileGeneration(thumbnail, request) == false)
        expect(inserted[1] == "page-7")
        expect(generated[1] == inserted[2])
        expect(generated[2] == 5 and generated[3] == true)
        expect(stock_check_calls == 0)
    end)

    it("registers the bottom gesture and opens the patched browser only when enabled", function()
        local stock_listener_calls = 0
        local ReaderMenu = {
            initGesListener = function() stock_listener_calls = stock_listener_calls + 1 end,
        }
        local stock_swipes = 0
        local ReaderConfig = {
            onSwipeShowConfigMenu = function()
                stock_swipes = stock_swipes + 1
                return "stock"
            end,
        }
        local PageBrowserWidget = {
            new = function(_, spec) return { ui = spec.ui, zen_page_browser = true } end,
        }
        install_widget_dependencies(PageBrowserWidget)
        ZenSpec.replace("apps/reader/modules/readermenu", ReaderMenu)
        ZenSpec.replace("apps/reader/modules/readerconfig", ReaderConfig)
        local plugin = {
            config = { features = { page_browser = false } },
        }
        _G.__ZEN_UI_PLUGIN = plugin
        require("modules/reader/patches/page_browser")()

        local ui = {
            registerTouchZones = function(_, registered) zones = registered end,
            handleEvent = function(_, event) events[#events + 1] = event end,
        }
        ReaderMenu.initGesListener({ ui = ui })
        expect(stock_listener_calls == 1)
        expect(zones[1].id == "zen_page_browser_reader")
        local disabled_result = zones[1].handler({ direction = "north" })
        expect(disabled_result == nil)
        expect(shown == nil)
        expect(ReaderConfig.onSwipeShowConfigMenu({ ui = ui }, { direction = "north" }) == nil)
        expect(stock_swipes == 0)

        plugin.config.features.page_browser = true
        expect(ReaderConfig.onSwipeShowConfigMenu({ ui = ui }, { direction = "south" }) == "stock")
        expect(stock_swipes == 1)
        expect(zones[1].handler({ direction = "north" }) == true)
        expect(shown.zen_page_browser == true)
        expect(shown.ui == ui)
        expect(events[1].name == "HandledAsSwipe")
        expect(ReaderConfig.onSwipeShowConfigMenu({ ui = ui }, { direction = "north" }) == true)
        expect(events[2].name == "HandledAsSwipe")

        local activated = {}
        local function zone(name)
            return { contains = function() activated[#activated + 1] = name; return true end }
        end
        local page_down, page_up = 0, 0
        local browser = {
            _zen_slider = {
                handleTap = function() return false end,
                handleSwipe = function() return false end,
            },
            _zen_btn_skip_left_zone = zone("skip-left-zone"),
            _zen_skip_prev = function() activated[#activated + 1] = "skip-left" end,
            _zen_skip_next = function() activated[#activated + 1] = "skip-right" end,
            _zen_switch_single = function() activated[#activated + 1] = "single" end,
            _zen_switch_carousel = function() activated[#activated + 1] = "carousel" end,
            onScrollPageDown = function() page_down = page_down + 1 end,
            onScrollPageUp = function() page_up = page_up + 1 end,
            dimen = { x = 0, y = 0, h = 800 },
        }
        expect(PageBrowserWidget.onTap(browser, nil, { pos = { x = 10, y = 10 } }) == true)
        expect(activated[1] == "skip-left-zone")
        expect(page_up == 1)

        activated = {}
        expect(PageBrowserWidget.onHold(browser, nil, { pos = { x = 10, y = 10 } }) == true)
        expect(activated[1] == "skip-left-zone")
        expect(activated[2] == "skip-left")

        activated = {}
        browser._zen_btn_skip_left_zone = nil
        browser._zen_btn_skip_right_zone = zone("skip-right-zone")
        expect(PageBrowserWidget.onTap(browser, nil, { pos = { x = 30, y = 10 } }) == true)
        expect(activated[1] == "skip-right-zone")
        expect(page_down == 1)

        activated = {}
        expect(PageBrowserWidget.onHold(browser, nil, { pos = { x = 30, y = 10 } }) == true)
        expect(activated[1] == "skip-right-zone")
        expect(activated[2] == "skip-right")

        activated = {}
        browser._zen_btn_skip_right_zone = nil
        browser._zen_btn_view_zone = zone("single-zone")
        expect(PageBrowserWidget.onTap(browser, nil, { pos = { x = 20, y = 20 } }) == true)
        expect(activated[1] == "single-zone")
        expect(activated[2] == "single")

        activated = {}
        browser._zen_btn_view_zone = nil
        browser._zen_btn_carousel_zone = zone("carousel-zone")
        expect(PageBrowserWidget.onTap(browser, nil, { pos = { x = 25, y = 20 } }) == true)
        expect(activated[1] == "carousel-zone")
        expect(activated[2] == "carousel")

        expect(PageBrowserWidget.onSwipe(browser, nil, { direction = "west" }) == true)
        expect(PageBrowserWidget.onSwipe(browser, nil, { direction = "east" }) == true)
        expect(page_down == 2 and page_up == 2)
    end)

    it("opens from a non-touch Menu hold and preserves the short Menu action", function()
        local scheduled_fn, scheduled_delay, short_menu_calls = nil, nil, 0
        local ReaderMenu = {
            initGesListener = function() end,
            onKeyPressShowMenu = function()
                short_menu_calls = short_menu_calls + 1
                return true
            end,
        }
        local ReaderConfig = { onSwipeShowConfigMenu = function() end }
        local PageBrowserWidget = {
            new = function(_, spec) return { ui = spec.ui, zen_page_browser = true } end,
        }
        install_widget_dependencies(PageBrowserWidget)
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
                scaleBySize = function(_, value) return value end,
            },
            isTouchDevice = function() return false end,
            hasDPad = function() return false end,
            hasFewKeys = function() return false end,
        })
        ZenSpec.replace("apps/reader/modules/readermenu", ReaderMenu)
        ZenSpec.replace("apps/reader/modules/readerconfig", ReaderConfig)
        ZenSpec.replace("ui/uimanager", {
            show = function(_, widget) shown = widget end,
            scheduleIn = function(_, delay, callback)
                scheduled_delay, scheduled_fn = delay, callback
            end,
            unschedule = function(_, callback)
                if scheduled_fn == callback then scheduled_fn = nil end
            end,
            setDirty = function() end,
        })
        _G.__ZEN_UI_PLUGIN = { config = { features = { page_browser = true } } }
        require("modules/reader/patches/page_browser")()

        local menu_key = {
            match = function(_, sequence)
                return sequence[1] == "Menu"
            end,
        }
        local menu = setmetatable({ ui = {} }, { __index = ReaderMenu })
        expect(ReaderMenu.onKeyPress(menu, menu_key) == true)
        expect(scheduled_delay == 0.5 and type(scheduled_fn) == "function")
        expect(ReaderMenu.onKeyRelease(menu, menu_key) == true)
        expect(short_menu_calls == 1 and shown == nil and scheduled_fn == nil)

        expect(ReaderMenu.onKeyPress(menu, menu_key) == true)
        local hold_callback = scheduled_fn
        hold_callback()
        expect(shown and shown.zen_page_browser == true)
        expect(shown._zen_ignore_opening_menu_key == true)
        expect(PageBrowserWidget.onKeyRepeat(shown, menu_key) == true)
        expect(PageBrowserWidget.onKeyRelease(shown, menu_key) == true)
        expect(shown._zen_ignore_opening_menu_key == nil)
        expect(short_menu_calls == 1)
    end)

    it("focuses the header, every page, and footer controls", function()
        local ReaderMenu = { initGesListener = function() end }
        local ReaderConfig = { onSwipeShowConfigMenu = function() end }
        local PageBrowserWidget = {
            registerKeyEvents = function(self)
                self.key_events = {
                    Close = { { "Back" }, event = "Close" },
                    ScrollRowUp = { { "Up" } },
                    ScrollRowDown = { { "Down" } },
                }
            end,
            onKeyPress = function(self)
                self.stock_key_called = true
            end,
            new = function(_, spec) return { ui = spec.ui } end,
        }
        install_widget_dependencies(PageBrowserWidget)
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
                scaleBySize = function(_, value) return value end,
            },
            isTouchDevice = function() return true end,
            hasDPad = function() return false end,
            hasKeyboard = function() return true end,
            hasFewKeys = function() return false end,
        })
        ZenSpec.replace("apps/reader/modules/readermenu", ReaderMenu)
        ZenSpec.replace("apps/reader/modules/readerconfig", ReaderConfig)
        _G.__ZEN_UI_PLUGIN = { config = { features = { page_browser = true } } }
        require("modules/reader/patches/page_browser")()
        ReaderConfig.onSwipeShowConfigMenu({ ui = { handleEvent = function() end } }, { direction = "north" })
        local key_owner = {}
        PageBrowserWidget.registerKeyEvents(key_owner)
        expect(key_owner.key_events.Close.event == "Close")
        expect(key_owner.key_events.Close[1][1] == "Back")
        expect(key_owner.key_events.ScrollRowUp == nil)
        expect(key_owner.key_events.ScrollRowDown == nil)
        expect(key_owner.key_events.ZenPageBrowserUp.event == "FocusMove")
        expect(key_owner.key_events.ZenPageBrowserDown.args[2] == 1)
        expect(key_owner.key_events.ZenPageBrowserPress.event == "Press")
        expect(key_owner.key_events.ZenPageBrowserConfirm.event == "Press")
        expect(key_owner.key_events.ZenPageBrowserConfirm[1][1] == "Return")
        expect(key_owner.key_events.ZenPageBrowserConfirm[2][1] == "Enter")

        local function focus_widget(callback)
            return {
                callback = callback,
                handleEvent = function(self, event) self.last_focus_event = event.name end,
            }
        end
        local headers = {}
        for i = 1, 7 do
            headers[i] = focus_widget(function() end)
        end
        local grid = {}
        for idx = 1, 6 do grid[idx] = { page_idx = idx } end
        for idx = 1, 6 do grid[6 + idx] = focus_widget() end
        local footer = {
            focus_widget(), focus_widget(), focus_widget(), focus_widget(), focus_widget(),
        }
        local browser = {
            _zen_focus_enabled = true,
            nb_cols = 3,
            nb_grid_items = 6,
            grid = grid,
            _zen_header_buttons = headers,
            _zen_btn_skip_left = footer[1],
            _zen_btn_view_frame = footer[2],
            _zen_btn_carousel_frame = footer[3],
            _zen_btn_grid_frame = footer[4],
            _zen_btn_skip_right = footer[5],
        }
        setmetatable(browser, { __index = PageBrowserWidget })
        PageBrowserWidget._zenRebuildFocusLayout(browser)
        expect(#browser.layout == 4)
        expect(#browser.layout[1] == 7 and #browser.layout[2] == 3)
        expect(#browser.layout[3] == 3 and #browser.layout[4] == 5)
        expect(browser.layout[1][7]._zen_focus_id == "header:7")
        expect(browser.layout[3][3]._zen_focus_id == "page:6")
        expect(browser.layout[4][1]._zen_focus_id == "footer:previous")
        expect(browser.layout[4][3]._zen_focus_id == "footer:carousel")
        expect(browser.layout[4][5]._zen_focus_id == "footer:next")
        expect(browser.layout[browser.selected.y][browser.selected.x]._zen_focus_id == "header:1")

        PageBrowserWidget.onKeyPress(browser, {
            match = function(_key, sequence) return sequence[1] == "Down" end,
        })
        expect(browser.layout[browser.selected.y][browser.selected.x]._zen_focus_id == "page:1")
        expect(browser.stock_key_called == nil)
        PageBrowserWidget.onFocusMove(browser, { 0, -1 })
        for _i = 1, 6 do PageBrowserWidget.onFocusMove(browser, { 1, 0 }) end
        expect(browser.layout[browser.selected.y][browser.selected.x]._zen_focus_id == "header:7")
        for _i = 1, 3 do PageBrowserWidget.onFocusMove(browser, { 0, 1 }) end
        expect(browser.layout[browser.selected.y][browser.selected.x]._zen_focus_id == "footer:next")

        local carousel_grid = {
            { page_idx = 4 }, { page_idx = 5 }, { page_idx = 6 },
            focus_widget(), focus_widget(), focus_widget(),
        }
        browser._zen_layout_mode = "carousel"
        browser.focus_page_shift = 1
        browser.nb_grid_items = 3
        browser.grid = carousel_grid
        PageBrowserWidget._zenRebuildFocusLayout(browser, "page:1")
        expect(browser.layout[browser.selected.y][browser.selected.x]._zen_focus_id == "page:2")
        PageBrowserWidget._zenRebuildFocusLayout(browser, "page:3")
        expect(browser.layout[browser.selected.y][browser.selected.x]._zen_focus_id == "page:2")
        PageBrowserWidget._zenRebuildFocusLayout(browser, "footer:next")
        expect(browser.layout[browser.selected.y][browser.selected.x]._zen_focus_id == "footer:next")
    end)

    it("centers clipped carousel pages and recenters side taps", function()
        local ReaderMenu = { initGesListener = function() end }
        local ReaderConfig = { onSwipeShowConfigMenu = function() end }
        local stock_taps = 0
        local painted_labels = {}
        local PageBrowserWidget = {
            init = function() error("init stop") end,
            update = function(self)
                self.stock_updates = (self.stock_updates or 0) + 1
            end,
            preloadThumbnail = function(self, page)
                self.preloaded = self.preloaded or {}
                self.preloaded[#self.preloaded + 1] = page
            end,
            showTile = function(self, grid_idx, page)
                self.stock_tile_focus = self.stock_tile_focus or {}
                self.stock_tile_focus[grid_idx] = page == self.cur_page
            end,
            onTap = function()
                stock_taps = stock_taps + 1
                return "stock"
            end,
            new = function(_, spec) return spec end,
        }
        install_widget_dependencies(PageBrowserWidget)
        ZenSpec.replace("ui/widget/container/inputcontainer", { paintTo = function() end })
        ZenSpec.replace("ui/font", { getFace = function() return {} end })
        ZenSpec.replace("ui/size", { border = { thin = 1 } })
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_BLACK = 0,
            COLOR_WHITE = 255,
            gray = function(value) return value end,
        })
        ZenSpec.replace("ui/widget/textwidget", {
            new = function(_, spec)
                return {
                    getSize = function() return { w = 20, h = 10 } end,
                    paintTo = function(_, _bb, x, y)
                        painted_labels[spec.text] = { x = x, y = y }
                    end,
                    free = function() end,
                }
            end,
        })

        local Geom = {}
        function Geom:new(spec)
            spec = spec or {}
            function spec:copy()
                local copy = {}
                for key, value in pairs(self) do
                    if type(value) ~= "function" then copy[key] = value end
                end
                return Geom:new(copy)
            end
            return spec
        end
        ZenSpec.replace("ui/geometry", Geom)
        ZenSpec.replace("apps/reader/modules/readermenu", ReaderMenu)
        ZenSpec.replace("apps/reader/modules/readerconfig", ReaderConfig)
        _G.__ZEN_UI_PLUGIN = { config = { features = { page_browser = true } } }
        require("modules/reader/patches/page_browser")()
        ReaderConfig.onSwipeShowConfigMenu(
            { ui = { handleEvent = function() end } }, { direction = "north" })

        local initialized = {
            dimen = { x = 0, y = 0, w = 600, h = 800 },
        }
        local ok, init_err = pcall(PageBrowserWidget.init, initialized)
        expect(ok == false and tostring(init_err):find("init stop", 1, true) ~= nil)
        expect(initialized._zen_layout_mode == "carousel")
        expect(initialized._zen_nb_cols_override == 3)
        expect(initialized._zen_nb_rows_override == 1)

        local function page_frame()
            local frame = {
                { dimen = Geom:new{ w = 100, h = 100 } },
                dimen = Geom:new{ x = 1, y = 1, w = 100, h = 100 },
                overlap_offset = { 0, 0 },
            }
            function frame:getSize() return self[1].dimen end
            return frame
        end
        local function nav_frame()
            return {
                { dimen = Geom:new{ w = 100, h = 100 } },
                dimen = Geom:new{ x = 1, y = 1, w = 100, h = 100 },
                overlap_offset = { 0, 0 },
                initial_overlap_offset = { 0, 0 },
                is_nav_item = true,
            }
        end
        local grid = {
            page_frame(), page_frame(), page_frame(),
            nav_frame(), nav_frame(), nav_frame(),
        }
        local browser = {
            _zen_layout_mode = "carousel",
            dimen = { x = 0, y = 0, w = 600, h = 800 },
            grid_width = 600,
            grid_height = 500,
            nb_grid_items = 3,
            grid = grid,
            focus_page = 5,
            cur_page = 5,
            nb_pages = 10,
        }
        expect(PageBrowserWidget._zenConfigureCarouselGrid(browser) == true)
        expect(browser.grid_item_width == 400 and browser.grid_item_height == 490)
        expect(browser.focus_page_shift == 1)
        expect(grid[1].overlap_offset[1] == -312)
        expect(grid[2].overlap_offset[1] == 100)
        expect(grid[3].overlap_offset[1] == 512)
        expect(grid[1].overlap_offset[1] + browser.grid_item_width == 88)
        expect(600 - grid[3].overlap_offset[1] == 88)
        expect(grid[1].dimen == nil and grid[1][1].dimen.w == 400)
        expect(grid[4].dimen == nil and grid[4].initial_overlap_offset[1] == -312)

        browser._zen_tile_size = { w = 300, h = 450 }
        setmetatable(browser, { __index = PageBrowserWidget })
        PageBrowserWidget.paintTo(browser, {
            paintRect = function() end,
        }, 0, 0)
        expect(painted_labels["5"] == nil)

        grid[2][1][1] = {
            is_page_thumbnail = true,
            { getSize = function() return { w = 280, h = 420 } end },
        }
        PageBrowserWidget.paintTo(browser, {
            paintRect = function() end,
        }, 0, 0)
        expect(painted_labels["5"].x == 290 and painted_labels["5"].y == 446)
        expect(painted_labels["4"].y == 481 and painted_labels["6"].y == 481)

        PageBrowserWidget.update(browser)
        expect(browser.stock_updates == 1)
        expect(#browser.preloaded == 2)
        expect(browser.preloaded[1] == 3 and browser.preloaded[2] == 7)

        browser.cur_page = 4
        PageBrowserWidget.showTile(browser, 1, 4, nil, false)
        PageBrowserWidget.showTile(browser, 2, 5, nil, false)
        PageBrowserWidget.showTile(browser, 3, 6, nil, false)
        expect(browser.stock_tile_focus[1] == false)
        expect(browser.stock_tile_focus[2] == true)
        expect(browser.stock_tile_focus[3] == false)
        expect(browser.cur_page == 4)
        browser.cur_page = 5

        grid[1].page_idx, grid[2].page_idx, grid[3].page_idx = 4, 5, 6
        for idx = 1, 3 do
            grid[idx].dimen = { id = idx }
        end
        local updates, calls = 0, {}
        browser.updateFocusPage = function(self, value, relative)
            calls[#calls + 1] = { value, relative }
            self.focus_page = relative and self.focus_page + value or value
            return true
        end
        browser.update = function() updates = updates + 1 end
        local function tap_item(index)
            return {
                x = 10,
                y = 100,
                intersectWith = function(_, dimen) return dimen == grid[index].dimen end,
            }
        end

        expect(PageBrowserWidget.onTap(browser, nil, { pos = tap_item(1) }) == true)
        expect(browser.focus_page == 4 and calls[#calls][2] == false)
        expect(updates == 1 and stock_taps == 0)

        browser.focus_page = 5
        expect(PageBrowserWidget.onTap(browser, nil, { pos = tap_item(3) }) == true)
        expect(browser.focus_page == 6 and updates == 2 and stock_taps == 0)

        browser.focus_page = 5
        grid[1].page_idx = nil
        expect(PageBrowserWidget.onTap(browser, nil, { pos = tap_item(1) }) == true)
        expect(browser.focus_page == 5 and updates == 2 and stock_taps == 0)

        expect(PageBrowserWidget.onTap(browser, nil, { pos = tap_item(2) }) == "stock")
        expect(stock_taps == 1)

        PageBrowserWidget.onScrollPageDown(browser)
        expect(browser.focus_page == 6 and calls[#calls][1] == 1 and calls[#calls][2] == true)
        PageBrowserWidget.onScrollPageUp(browser)
        expect(browser.focus_page == 5 and calls[#calls][1] == -1 and calls[#calls][2] == true)
    end)

    it("honors lockdown by suppressing page-browser and native config gestures", function()
        local stock_calls = 0
        local ReaderMenu = { initGesListener = function() end }
        local ReaderConfig = {
            onSwipeShowConfigMenu = function()
                stock_calls = stock_calls + 1
                return "stock"
            end,
        }
        install_widget_dependencies({ new = function(_, spec) return spec end })
        ZenSpec.replace("apps/reader/modules/readermenu", ReaderMenu)
        ZenSpec.replace("apps/reader/modules/readerconfig", ReaderConfig)
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { page_browser = true, lockdown_mode = true },
                lockdown = { disable_bottom_menu_swipe = true },
            },
        }
        require("modules/reader/patches/page_browser")()
        local ui = { handleEvent = function() end }
        local lockdown_result = ReaderConfig.onSwipeShowConfigMenu(
            { ui = ui }, { direction = "north" }
        )
        expect(lockdown_result == nil)
        expect(ReaderConfig.onSwipeShowConfigMenu({ ui = ui }, { direction = "south" }) == nil)
        expect(stock_calls == 0)
        expect(shown == nil)
    end)

    it("hides non-linear fragments from page-browser navigation", function()
        local ReaderMenu = { initGesListener = function() end }
        local ReaderConfig = { onSwipeShowConfigMenu = function() end }
        local PageBrowserWidget = {
            init = function(self)
                local left = { callback = function() end }
                local right = { callback = function() end }
                self.ges_events = {}
                self.nb_cols, self.nb_rows = 3, 2
                self.nb_pages, self.cur_page, self.focus_page = 5, 3, 3
                self.title_bar = {
                    left,
                    right,
                    left_button = left,
                    right_button = right,
                    setTitle = function() end,
                }
            end,
            new = function(_, spec) return spec end,
            onTap = function() error("mapped thumbnail tap was not handled") end,
        }
        install_widget_dependencies(PageBrowserWidget)
        ZenSpec.replace("apps/reader/modules/readermenu", ReaderMenu)
        ZenSpec.replace("apps/reader/modules/readerconfig", ReaderConfig)
        local function button_class()
            return { new = function(_, spec) return spec end }
        end
        ZenSpec.replace("ui/widget/iconbutton", button_class())
        ZenSpec.replace("common/ui/zen_icon_button", button_class())
        ZenSpec.replace("ui/gesturerange", button_class())
        ZenSpec.replace("ui/geometry", button_class())
        ZenSpec.replace("common/utils", {
            resolveIcon = function(_, name) return "/icons/" .. name .. ".svg" end,
            resolveLocalIcon = function(_, name) return "/local-icons/" .. name .. ".svg" end,
        })
        reader_store.settings.page_browser_layout = "grid"
        _G.__ZEN_UI_PLUGIN = { config = { features = { page_browser = true } } }
        require("modules/reader/patches/page_browser")()

        ReaderConfig.onSwipeShowConfigMenu({ ui = { handleEvent = function() end } }, { direction = "north" })
        local goto_page, closes, locations = nil, 0, 0
        local browser = {
            dimen = { x = 0, y = 0, w = 600, h = 800 },
            ui = {
                document = {
                    getPageCount = function() return 5 end,
                    hasHiddenFlows = function() return true end,
                    getPageFlow = function(_, page) return (page == 2 or page == 4) and 1 or 0 end,
                },
                link = { addCurrentLocationToStack = function() locations = locations + 1 end },
                handleEvent = function(_, event) goto_page = event.args[1] end,
            },
            onClose = function(_, all) if all then closes = closes + 1 end end,
            updateLayout = function() error("layout stop") end,
        }
        local initialized, init_err = pcall(PageBrowserWidget.init, browser)
        expect(initialized == false and tostring(init_err):find("layout stop", 1, true) ~= nil)
        expect(browser.nb_pages == 3)
        expect(browser.focus_page == 2 and browser.cur_page == 2)
        expect(browser._zen_visible_pages[1] == 1
            and browser._zen_visible_pages[2] == 3
            and browser._zen_visible_pages[3] == 5)

        browser.nb_grid_items = 1
        browser.grid = {{
            page_idx = 2,
            dimen = { x = 0, y = 0, w = 100, h = 100 },
        }}
        PageBrowserWidget.onTap(browser, nil, {
            pos = { intersectWith = function() return true end, x = 10, y = 10 },
        })
        expect(goto_page == 3 and closes == 1 and locations == 1)
    end)

    it("preserves KOReader search-type tables for whole-word searches", function()
        local search_call = {}
        local find_all_call = {}
        local default_search_type = { flags = 0x00FF, regex = false, text = "default" }
        local original_search = function(_, pattern, origin, search_type, case_insensitive)
            search_call = {
                pattern = pattern,
                origin = origin,
                search_type = search_type,
                case_insensitive = case_insensitive,
            }
        end
        local ReaderSearch = {
            default_search_type = default_search_type,
            ui = { document = { checkRegex = function() return 0 end } },
            search = original_search,
            findAllText = function(self, pattern)
                find_all_call = {
                    pattern = pattern,
                    search_type = self.current_search_type,
                }
            end,
        }
        ZenSpec.replace("apps/reader/modules/readersearch", ReaderSearch)
        ZenSpec.replace("apps/reader/modules/readermenu", { initGesListener = function() end })
        ZenSpec.replace("apps/reader/modules/readerconfig", { onSwipeShowConfigMenu = function() end })
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { page_browser = false },
                search = { substring = false },
            },
        }
        require("modules/reader/patches/page_browser")()

        expect(ReaderSearch.search ~= original_search)
        ReaderSearch:search("red", 0, default_search_type, true)
        expect(search_call.pattern == "\\b" .. "red" .. "\\b")
        expect(search_call.origin == 0 and search_call.case_insensitive == true)
        expect(search_call.search_type ~= default_search_type)
        expect(search_call.search_type.flags == default_search_type.flags)
        expect(search_call.search_type.text == default_search_type.text)
        expect(search_call.search_type.regex == true and default_search_type.regex == false)

        ReaderSearch:search("red", 0, nil, true)
        expect(type(search_call.search_type) == "table")
        expect(search_call.search_type.regex == true)

        ReaderSearch.current_search_type = default_search_type
        ReaderSearch:findAllText("red")
        expect(find_all_call.pattern == "\\b" .. "red" .. "\\b")
        expect(find_all_call.search_type ~= default_search_type)
        expect(find_all_call.search_type.regex == true)
        expect(ReaderSearch.current_search_type == default_search_type)
    end)

    it("uses native whole-word boundaries for fixed-layout document searches", function()
        local search_call = {}
        local find_all_call = {}
        local default_search_type = { flags = 0x00FF, regex = false }
        local ReaderSearch = {
            default_search_type = default_search_type,
            current_search_type = default_search_type,
            ui = { document = {} },
            search = function(_, pattern, origin, search_type, case_insensitive)
                search_call = {
                    pattern = pattern,
                    origin = origin,
                    search_type = search_type,
                    case_insensitive = case_insensitive,
                }
            end,
            findAllText = function(_, pattern)
                find_all_call.pattern = pattern
            end,
        }
        ZenSpec.replace("apps/reader/modules/readersearch", ReaderSearch)
        ZenSpec.replace("apps/reader/modules/readermenu", { initGesListener = function() end })
        ZenSpec.replace("apps/reader/modules/readerconfig", { onSwipeShowConfigMenu = function() end })
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { page_browser = false },
                search = { substring = false },
            },
        }
        require("modules/reader/patches/page_browser")()

        ReaderSearch:search("red", 0, default_search_type, true)
        expect(search_call.pattern == " red ")
        expect(search_call.origin == 0 and search_call.case_insensitive == true)
        expect(search_call.search_type == default_search_type)

        ReaderSearch:findAllText("red")
        expect(find_all_call.pattern == " red ")
        expect(ReaderSearch.current_search_type == default_search_type)
    end)

    it("routes page-browser title-bar actions and keeps nested views returnable", function()
        local ReaderMenu = { initGesListener = function() end }
        local ReaderConfig = { onSwipeShowConfigMenu = function() end }
        local close_button_taps = 0
        local PageBrowserWidget = {
            init = function(self)
                local left = { callback = function() end, hold_callback = function() end }
                local right = {
                    callback = function() close_button_taps = close_button_taps + 1 end,
                    hold_callback = function() end,
                }
                self.ges_events = {}
                self.nb_cols, self.nb_rows = 3, 2
                self.title_bar = {
                    left,
                    right,
                    width = 600,
                    left_button = left,
                    right_button = right,
                    button_padding = 11,
                    setTitle = function(bar, title) bar.title = title end,
                }
            end,
            new = function(_, spec) return { ui = spec.ui } end,
        }
        install_widget_dependencies(PageBrowserWidget)
        ZenSpec.replace("apps/reader/modules/readermenu", ReaderMenu)
        ZenSpec.replace("apps/reader/modules/readerconfig", ReaderConfig)

        local function button_class()
            return { new = function(_, spec) return spec end }
        end
        ZenSpec.replace("ui/widget/iconbutton", button_class())
        ZenSpec.replace("common/ui/zen_icon_button", button_class())
        ZenSpec.replace("ui/gesturerange", button_class())
        ZenSpec.replace("ui/geometry", button_class())
        local toc_spec
        ZenSpec.replace("modules/reader/zen_toc_widget", {
            set_plugin = function() end,
            new = function(_, spec)
                toc_spec = spec
                return spec
            end,
        })
        ZenSpec.replace("common/utils", {
            resolveIcon = function(_, name) return "/icons/" .. name .. ".svg" end,
            resolveLocalIcon = function(_, name) return "/local-icons/" .. name .. ".svg" end,
        })
        local shown_widgets, closed_widgets = {}, {}
        ZenSpec.replace("ui/uimanager", {
            show = function(_, widget) shown_widgets[#shown_widgets + 1] = widget end,
            close = function(_, widget) closed_widgets[#closed_widgets + 1] = widget end,
            scheduleIn = function() end,
            setDirty = function() end,
            unschedule = function() end,
            nextTick = function(_, callback) callback() end,
        })
        local config_dialog
        ZenSpec.replace("ui/widget/configdialog", {
            new = function(_, spec)
                spec.onShowConfigPanel = function(self, index) self.shown_panel = index end
                config_dialog = spec
                return spec
            end,
        })
        local overflow_spec
        ZenSpec.replace("ui/widget/buttondialog", {
            new = function(_, spec)
                overflow_spec = spec
                return spec
            end,
        })
        local info_spec
        ZenSpec.replace("ui/font", {
            getFace = function(_, name, size, index)
                return { name = name, size = size, index = index }
            end,
        })
        ZenSpec.replace("modules/filebrowser/patches/library_font", {
            getFace = function(size)
                return require("ui/font"):getFace("LibraryFont", size)
            end,
        })
        ZenSpec.replace("document/credocument", {})
        ZenSpec.replace("ui/language", {
            getLanguageName = function(_, code)
                return code == "en" and "English" or code
            end,
        })
        ZenSpec.replace("common/cover_utils", {
            getRatio = function() return 2 / 3 end,
            makeCover = function()
                return { copy = function(self) return self end }, 120, 180, "single", "real_cover"
            end,
        })
        ZenSpec.replace("ui/widget/booklist", {
            getBookRatingString = function(rating) return "rating " .. rating end,
        })
        ZenSpec.replace("modules/reader/book_info_widget", {
            new = function(_, spec)
                info_spec = spec
                return spec
            end,
        })
        ZenSpec.replace("modules/reader/book_details", {
            show = function(ui, opts)
                info_spec = { ui = ui, opts = opts }
                return true
            end,
        })
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { page_browser = true, browser_cover_rounded_corners = true },
                page_browser = { toc_font_size = 26 },
            },
            saveConfig = function() end,
        }
        package.loaded["db"] = {}
        require("modules/reader/patches/page_browser")()

        local bootstrap_ui = { handleEvent = function() end }
        ReaderConfig.onSwipeShowConfigMenu({ ui = bootstrap_ui }, { direction = "north" })

        local action_events, closes, bookmarks, stack_adds, stopped = {}, 0, 0, 0, 0
        local ui = {
            link = { addCurrentLocationToStack = function() stack_adds = stack_adds + 1 end },
            bookmark = { onShowBookmark = function() bookmarks = bookmarks + 1 end },
            document = { file = "/books/test.epub" },
            doc_props = {
                title = "Test title",
                authors = "Test author",
                series = "Test series",
                series_index = 2,
                keywords = "First tag; Second tag",
                language = "en",
                description = "Test description",
            },
            doc_settings = {
                readSetting = function(_, key)
                    if key == "summary" then return { rating = 4, note = "" } end
                    if key == "annotations" then return { {}, {} } end
                    if key == "doc_pages" then return 240 end
                    if key == "font_face" then return "ReaderFont" end
                end,
            },
            annotation = { annotations = { {}, {} } },
            font = { font_face = "ReaderFont" },
            configurable = { font_size = 21 },
            keyselection = {
                onStopHighlightIndicator = function(_, immediate)
                    if immediate then stopped = stopped + 1 end
                end,
            },
            config = {
                document = {}, ui = {}, configurable = {}, options = {}, last_panel_index = 4,
            },
            handleEvent = function(_, event) action_events[#action_events + 1] = event end,
        }
        local browser = {
            ui = ui,
            focus_page = 12,
            dimen = { x = 0, y = 0, w = 600, h = 800 },
            onClose = function() closes = closes + 1 end,
            updateLayout = function() error("layout stop") end,
        }
        local initialized, init_err = pcall(PageBrowserWidget.init, browser)
        expect(initialized == false, "test seam should stop before layout")
        expect(tostring(init_err):find("layout stop", 1, true) ~= nil, tostring(init_err))

        local by_file, buttons_by_file, positions = {}, {}, {}
        for _i, button in ipairs(browser.title_bar) do
            if button.file then
                by_file[button.file] = button.callback
                buttons_by_file[button.file] = button
                positions[button.file] = button.overlap_offset and button.overlap_offset[1]
            end
        end
        expect(type(by_file["/icons/appbar.search.svg"]) == "function")
        expect(type(by_file["/icons/appbar.textsize.svg"]) == "function")
        expect(type(by_file["/icons/more_vertical.svg"]) == "function")
        expect(type(buttons_by_file["/icons/more_vertical.svg"]) == "table")
        expect(type(by_file["/icons/bookmark.svg"]) == "function")
        expect(type(by_file["/icons/toc.svg"]) == "function")
        expect(type(by_file["/icons/info.svg"]) == "function")
        expect(positions["/icons/appbar.search.svg"] == 0)
        expect(positions["/icons/info.svg"] == 58)
        expect(positions["/icons/appbar.textsize.svg"] == 215)
        expect(positions["/icons/bookmark.svg"] == 273)
        expect(positions["/icons/toc.svg"] == 331)
        expect(positions["/icons/more_vertical.svg"] == 492)
        expect(browser._zen_orig_nb_cols == 3 and browser._zen_orig_nb_rows == 3)
        local close_button = browser.title_bar.right_button
        expect(close_button.file == "/icons/close_light.svg")
        expect(close_button.width == 32 and close_button.height == 32)
        expect(close_button.padding == 11 and close_button.padding_bottom == 32)
        expect(close_button.overlap_align == "right")
        expect(close_button.onFocus(close_button) == true)
        expect(close_button._zen_keyboard_focused == true)
        expect(close_button.onUnfocus(close_button) == true)
        expect(close_button._zen_keyboard_focused == nil)
        close_button.callback()
        expect(close_button_taps == 1)

        by_file["/icons/appbar.search.svg"]()
        expect(closes == 1 and action_events[#action_events].name == "ShowFulltextSearchInput")
        by_file["/icons/bookmark.svg"]()
        expect(closes == 1 and bookmarks == 1)
        expect(ui.bookmark.bookmark_menu == nil)

        ui.bookmark.bookmark_menu = { {} }
        by_file["/icons/bookmark.svg"]()
        expect(closes == 1 and bookmarks == 2)
        expect(ui.bookmark.bookmark_menu[1]._zen_page_browser_parent == browser)

        local overflow_anchor = { x = 492, y = 10, w = 32, h = 32 }
        buttons_by_file["/icons/more_vertical.svg"].image = { dimen = overflow_anchor }
        by_file["/icons/more_vertical.svg"]()
        expect(overflow_spec ~= nil and shown_widgets[#shown_widgets] == overflow_spec)
        overflow_spec.movable = { dimen = { w = 200 } }
        local popup_anchor = overflow_spec.anchor()
        expect(popup_anchor.x == 390 and popup_anchor.y == 10 and popup_anchor.h == 32)
        local vocab_action = overflow_spec.buttons[1][1]
        expect(vocab_action.align == "left" and vocab_action.avoid_text_truncation == false)
        expect(vocab_action.text:find("Vocabulary builder", 1, true) > 1)
        vocab_action.callback()
        expect(closed_widgets[#closed_widgets] == overflow_spec)
        expect(closes == 2 and action_events[#action_events].name == "ShowVocabBuilder")

        by_file["/icons/toc.svg"]()
        expect(closes == 2 and toc_spec.focus_page == 12
            and toc_spec.font_size == 26
            and type(toc_spec.close_all_callback) == "function")
        toc_spec.on_goto(27)
        expect(closes == 3 and stack_adds == 1)
        expect(action_events[#action_events].name == "GotoPage"
            and action_events[#action_events].args[1] == 27)

        by_file["/icons/info.svg"]()
        expect(closes == 3 and info_spec ~= nil and info_spec.ui == ui)
        expect(info_spec.opts.config == _G.__ZEN_UI_PLUGIN.config)
        expect(type(info_spec.opts.close_all_callback) == "function")

        by_file["/icons/appbar.textsize.svg"]()
        expect(closes == 4)
        expect(config_dialog ~= nil and ui.config.config_dialog == config_dialog)
        expect(config_dialog.shown_panel == 4 and stopped == 1)
        expect(action_events[#action_events].name == "DisableHinting")
        config_dialog.panel_index = 2
        config_dialog.close_callback()
        expect(ui.config.config_dialog == nil and ui.config.last_panel_index == 2)
        expect(action_events[#action_events].name == "RestoreHinting")

        toc_spec.close_all_callback()
        info_spec.opts.close_all_callback()
        expect(closes == 6)
    end)

    it("closes book search with hardware Back and focuses its X on non-touch devices", function()
        local ReaderSearch = {}
        local close_button = { name = "close" }
        local input_widget = {
            name = "input",
            keyboard = {
                key_events = { Close = { { "Back" } } },
            },
        }
        local search_button = { name = "search" }
        local dialog
        local InputDialog = {
            onTap = function() end,
            new = function(_, spec)
                dialog = spec
                dialog.title_bar = {}
                dialog._input_widget = input_widget
                dialog.layout = { { input_widget }, { search_button } }
                dialog.selected = { x = 1, y = 1 }
                dialog.isKeyboardVisible = function() return false end
                dialog.onShowKeyboard = function() end
                return dialog
            end,
        }
        local closes, shown_dialog = 0, nil
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
            },
            isTouchDevice = function() return false end,
        })
        ZenSpec.replace("apps/reader/modules/readersearch", ReaderSearch)
        ZenSpec.replace("apps/reader/modules/readermenu", { initGesListener = function() end })
        ZenSpec.replace("apps/reader/modules/readerconfig", { onSwipeShowConfigMenu = function() end })
        ZenSpec.replace("ui/widget/inputdialog", InputDialog)
        ZenSpec.replace("ui/uimanager", {
            close = function(_, closed)
                expect(closed == dialog)
                closes = closes + 1
            end,
            show = function(_, widget) shown_dialog = widget end,
            scheduleIn = function() end,
            setDirty = function() end,
            unschedule = function() end,
        })
        ZenSpec.replace("common/utils", {
            resolveIcon = function(_, name) return "/icons/" .. name .. ".svg" end,
            resolveLocalIcon = function(_, name) return "/local-icons/" .. name .. ".svg" end,
        })
        ZenSpec.replace("common/ui/zen_modal_close", {
            installDialog = function(target, callback)
                close_button.callback = callback
                target.title_bar.right_button = close_button
                table.insert(target.layout, 1, { close_button })
                target.selected.y = target.selected.y + 1
                return close_button
            end,
        })
        _G.__ZEN_UI_PLUGIN = { config = { features = { page_browser = false } } }
        require("modules/reader/patches/page_browser")()

        ReaderSearch:onShowFulltextSearchInput("needle")
        expect(shown_dialog == dialog)
        expect(dialog.title_bar.left_button == nil)
        expect(dialog.title_bar.right_button == close_button)
        expect(dialog.layout[1][1] == close_button)
        expect(dialog.layout[2][1] == input_widget)
        expect(dialog.selected.x == 1 and dialog.selected.y == 2)

        expect(dialog:onCloseDialog() == true)
        expect(closes == 1)
        expect(input_widget.keyboard.key_events.Close == nil)
        expect(input_widget.keyboard.key_events.ZenCloseSearchDialog.event == "ZenCloseSearchDialog")
        expect(input_widget.keyboard:onZenCloseSearchDialog() == true)
        expect(closes == 2)

        close_button.callback()
        expect(closes == 3)
    end)

    it("makes both book-search result header buttons reachable on non-touch devices", function()
        local left_button = { name = "menu" }
        local right_button = { name = "close" }
        local first_result = { name = "first" }
        local second_result = { name = "second" }
        local focus_moves, presses = {}, 0
        local menu = {
            dimen = { h = 800 },
            [1] = {},
            selected = { x = 1, y = 1 },
            title_bar = {
                generateHorizontalLayout = function()
                    return { { left_button, right_button } }
                end,
            },
            close_callback = function() end,
            updateItems = function(self)
                self.layout = { { first_result }, { second_result } }
                self.selected = { x = 1, y = 1 }
                self:mergeTitleBarIntoLayout()
            end,
            onFocusMove = function(_, args)
                focus_moves[#focus_moves + 1] = args
                return true
            end,
            onPress = function()
                presses = presses + 1
                return true
            end,
        }
        local ReaderSearch = {
            onShowFindAllResults = function(self)
                self.result_menu = menu
            end,
        }
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
            },
            isTouchDevice = function() return false end,
            hasDPad = function() return true end,
            hasKeyboard = function() return false end,
        })
        ZenSpec.replace("apps/reader/modules/readersearch", ReaderSearch)
        ZenSpec.replace("apps/reader/modules/readermenu", { initGesListener = function() end })
        ZenSpec.replace("apps/reader/modules/readerconfig", { onSwipeShowConfigMenu = function() end })
        ZenSpec.replace("ui/widget/inputdialog", { onTap = function() end })
        ZenSpec.replace("ui/uimanager", {
            isWidgetShown = function(_, shown_menu) return shown_menu == menu end,
            setDirty = function() end,
            scheduleIn = function() end,
            unschedule = function() end,
        })
        _G.__ZEN_UI_PLUGIN = { config = { features = { page_browser = false } } }
        require("modules/reader/patches/page_browser")()

        ReaderSearch:onShowFindAllResults(true)
        expect(menu.layout[1][1] == left_button and menu.layout[1][2] == right_button)
        expect(menu.layout[2][1] == first_result)
        expect(menu.selected.x == 1 and menu.selected.y == 2)

        local function key(name)
            return {
                match = function(_, sequence) return sequence[1] == name end,
            }
        end
        expect(menu:onKeyPress(key("Up")) == true)
        expect(menu:onKeyPress(key("Right")) == true)
        expect(menu:onKeyPress(key("Return")) == true)
        expect(menu:onKeyRepeat(key("Left")) == true)
        expect(focus_moves[1][2] == -1)
        expect(focus_moves[2][1] == 1)
        expect(focus_moves[3][1] == -1)
        expect(presses == 1)
    end)
end)
