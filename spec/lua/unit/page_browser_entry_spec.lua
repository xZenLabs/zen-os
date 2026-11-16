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
        ZenSpec.replace("common/ui/zen_tab_bar", { new = function(_self, spec)
            spec.cells = {}
            for i, item in ipairs(spec.items) do spec.cells[i] = { callback = item.callback } end
            spec.getSize = function() return { w = 256, h = 44 } end
            spec.free = function() end
            return spec
        end })
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

    local function install_android_thumbnail_dependencies()
        install_widget_dependencies({})
        ZenSpec.replace("apps/reader/modules/readermenu", {})
        ZenSpec.replace("apps/reader/modules/readerconfig", {})
        require("device").isAndroid = function() return true end
        local ReaderThumbnail = {
            checkTileGeneration = function() error("unexpected subprocess check") end,
        }
        ZenSpec.replace("apps/reader/modules/readerthumbnail", ReaderThumbnail)
        local function buffer(width, height)
            return {
                w = width, h = height, stride = width,
                getWidth = function() return width end,
                getHeight = function() return height end,
                free = function(self) self.freed = true end,
                viewport = function(_self, _x, _y, w, h) return buffer(w, h) end,
                copy = function() return buffer(width, height) end,
            }
        end
        ZenSpec.replace("ffi/blitbuffer", { new = buffer })
        ZenSpec.replace("ui/geometry", { new = function(_, spec) return spec or { x = 0, y = 0 } end })
        ZenSpec.replace("ui/renderimage", {
            scaleBlitBuffer = function(_, bb, width, height)
                if bb.w == width and bb.h == height then return bb end
                bb:free()
                return buffer(width, height)
            end,
        })
        ZenSpec.replace("document/tilecacheitem", { new = function(_, spec) return spec end })
        ZenSpec.replace("logger", logger_stub())
        require("modules/reader/patches/page_browser")()
        return ReaderThumbnail, buffer
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
        ZenSpec.replace("common/ui/zen_title_style", { ICON_SIZE = 28 })
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
            nextTick = function(_self, callback) callback() end,
            setDirty = function() end,
            unschedule = function() end,
        })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("apps/reader/modules/readersearch", {})
        ZenSpec.replace("ui/widget/inputdialog", { onTap = function() end })
        ZenSpec.replace("apps/reader/readerui", {})
        ZenSpec.replace("apps/reader/modules/readerthumbnail", { onShowPageBrowser = function() return false end })
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
        ZenSpec.unload("modules/reader/page_browser_preview")
        ZenSpec.unload("modules/filebrowser/patches/library_font")
        ZenSpec.unload("common/reader_font")
        ZenSpec.unload("common/ui/zen_title_style")
    end)

    it("renders Android EPUB thumbnails without changing the live reader", function()
        local ReaderThumbnail, buffer = install_android_thumbnail_dependencies()
        local inserted, generated, save_calls
        local statistics = {}
        local position, drawn_page = 160, nil
        local document = {
            getCurrentPos = function() return position end,
            gotoPos = function(_, pos) position = pos end,
            getHeaderHeight = function() return 20 end,
            drawCurrentViewByPage = function(_, bb, x, y, rect, page)
                expect(bb.w == 600 and bb.h == 800 and x == 0 and y == 0)
                expect(rect.w == 600 and rect.h == 800)
                drawn_page, position = page, 560
            end,
        }
        local rendering_state = {}
        local ui = setmetatable({
            statistics = statistics,
            document = document,
            rolling = { rendering_state = rendering_state },
            view = { footer_visible = true, state = { page = 2, zoom = 3, rotation = 4 } },
        }, {
            __index = {
                saveSettings = function() save_calls = (save_calls or 0) + 1 end,
            },
        })
        local thumbnail = {
            ui = ui,
            tile_cache = { insert = function(_, hash, tile) inserted = { hash, tile } end },
            _getPageImage = function(self, page)
                self.ui.view.footer_visible = false
                self.ui.view.state.page = page
                self.ui.rolling.rendering_state = nil
                local bb = buffer(600, 800)
                document:drawCurrentViewByPage(bb, 0, 0, { w = 600, h = 800 }, page)
                return bb
            end,
        }
        local request = {
            page = 7, width = 300, height = 200, hash = "page-7", batch_id = 5,
            when_generated_callback = function(tile, batch_id, delayed)
                generated = { tile, batch_id, delayed }
            end,
        }

        expect(ReaderThumbnail.startTileGeneration(thumbnail, request) == true)
        expect(position == 160 and drawn_page == 7)
        expect(ui.rolling.rendering_state == rendering_state)
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
        expect(not generated[1].bb.freed)
        expect(generated[1].bb.h <= 200)
        expect(math.abs(generated[1].bb.w / generated[1].bb.h - 600 / 780) < 0.01)
    end)

    it("renders Android PDF thumbnails at native size and restores reflow settings on failure", function()
        local ReaderThumbnail, buffer = install_android_thumbnail_dependencies()
        local configurable = { text_wrap = 1, trim_page = 2, auto_straighten = 5 }
        local dimen, visible_area, bbox = { w = 600, h = 800 }, {}, {}
        local highlight = { lighten_factor = 0.2, page_boxes = {}, visible_boxes = {} }
        local original_page_boxes, original_visible_boxes = highlight.page_boxes, highlight.visible_boxes
        local highlighted, bookmarked = 0, 0
        local rendered, fail
        local ui = {
            paging = {},
            bookmark = { isPageBookmarked = function(_, page) return page == 7 end },
            view = {
                dimen = dimen, visible_area = visible_area, page_scroll = true, hinting = true,
                footer_visible = true, flipping_visible = true,
                state = { page = 2, zoom = 3, rotation = 90, gamma = 1.2, saturation = 0.8, bbox = bbox },
                highlight_visible = true, highlight = highlight,
                drawSavedHighlight = function(self, bb)
                    expect(self.highlight ~= highlight and self.state.page == 7 and self.state.zoom == 0.5)
                    expect(self.state.offset.x == 0 and self.visible_area.w == bb.w)
                    expect(self.highlight.lighten_factor == 0.3)
                    self.highlight.page_boxes[7], self.highlight.visible_boxes = {}, { 7 }
                    highlighted = highlighted + 1
                end,
                dogear = {
                    dogear_y_offset = 8,
                    icon = {
                        getWidth = function() return 20 end,
                        paintTo = function(_, bb, x, y)
                            expect(x == bb.w - 20 and y == 8)
                            bookmarked = bookmarked + 1
                        end,
                    },
                },
            },
            document = {
                configurable = configurable,
                getPageDimensions = function(_, page, zoom, rotation)
                    expect(page == 7 and zoom == 1 and rotation == 0)
                    expect(configurable.text_wrap == false and configurable.trim_page == 3)
                    expect(configurable.auto_straighten == 0)
                    return { w = 1200, h = 600 }
                end,
                drawPage = function(_, bb, x, y, rect, page, zoom, rotation, gamma, saturation)
                    rendered = bb
                    expect(bb.w == 600 and bb.h == 300 and x == 0 and y == 0)
                    expect(rect.w == 600 and rect.h == 300)
                    expect(page == 7 and zoom == 0.5 and rotation == 0)
                    expect(gamma == 1.2 and saturation == 0.8)
                    if fail then error("render failed") end
                end,
            },
        }
        local thumbnail = {
            ui = ui,
            _getPageImage = function(self, page)
                configurable.text_wrap, configurable.trim_page, configurable.auto_straighten = false, 3, 0
                local view = self.ui.view
                view.dimen, view.visible_area = { w = 600, h = 300 }, {}
                view.page_scroll, view.hinting, view.footer_visible, view.flipping_visible = false, false, false, false
                view.state.page, view.state.zoom, view.state.rotation, view.state.bbox = page, 0.5, 0, nil
                local bb = buffer(600, 300)
                self.ui.document:drawPage(bb, 0, 0, { w = 600, h = 300 }, page, 0.5, 0, 1.2, 0.8)
                return bb
            end,
        }
        local request = { page = 7, width = 300, height = 200 }
        for _i = 1, 2 do
            expect(ReaderThumbnail.startTileGeneration(thumbnail, request) == not fail)
            expect(configurable.text_wrap == 1 and configurable.trim_page == 2)
            expect(configurable.auto_straighten == 5)
            expect(ui.view.state.page == 2 and ui.view.state.zoom == 3)
            expect(ui.view.state.rotation == 90)
            expect(ui.view.dimen == dimen and ui.view.visible_area == visible_area and ui.view.state.bbox == bbox)
            expect(ui.view.page_scroll and ui.view.hinting and ui.view.footer_visible and ui.view.flipping_visible)
            expect(highlight.page_boxes == original_page_boxes and highlight.page_boxes[7] == nil)
            expect(highlight.visible_boxes == original_visible_boxes and highlight.lighten_factor == 0.2)
            if fail then expect(rendered.freed) end
            request._zen_sync_tile = nil
            fail = true
        end
        expect(highlighted == 1 and bookmarked == 1)
    end)

    it("restores the Android EPUB position after a render error", function()
        local ReaderThumbnail = install_android_thumbnail_dependencies()
        local position, rendered = 0, nil
        local thumbnail = {
            ui = {
                rolling = {},
                document = {
                    getCurrentPos = function() return position end,
                    gotoPos = function(_, pos) position = pos end,
                    drawCurrentViewByPage = function(_, bb)
                        rendered, position = bb, 560
                        error("render failed")
                    end,
                },
            },
        }
        local request = { page = 7, width = 300, height = 200 }
        expect(ReaderThumbnail.startTileGeneration(thumbnail, request) == false)
        expect(position == 0 and rendered and rendered.freed)
        expect(request._zen_sync_tile == nil)
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
        browser._zen_layout_zone = zone("layout-zone")
        browser._zen_layout_button = { callback = function() activated[#activated + 1] = "layout-menu" end }
        expect(PageBrowserWidget.onTap(browser, nil, { pos = { x = 20, y = 20 } }) == true)
        expect(activated[1] == "layout-zone")
        expect(activated[2] == "layout-menu")

        activated = {}
        browser._zen_layout_zone = nil
        browser._zen_search_zone = zone("search-zone")
        browser._zen_search_button = { callback = function() activated[#activated + 1] = "search" end }
        expect(PageBrowserWidget.onTap(browser, nil, { pos = { x = 25, y = 20 } }) == true)
        expect(activated[1] == "search-zone")
        expect(activated[2] == "search")

        expect(PageBrowserWidget.onSwipe(browser, nil, { direction = "west" }) == true)
        expect(PageBrowserWidget.onSwipe(browser, nil, { direction = "east" }) == true)
        expect(page_down == 2 and page_up == 2)
    end)

    it("starts the pending reader tour even when the page browser is disabled", function()
        local ReaderMenu = { initGesListener = function() end }
        local ReaderConfig = { onSwipeShowConfigMenu = function() end }
        local browser_closes = 0
        local PageBrowserWidget = {
            new = function(_, spec)
                return {
                    ui = spec.ui,
                    zen_page_browser = true,
                    onClose = function() browser_closes = browser_closes + 1 end,
                }
            end,
        }
        install_widget_dependencies(PageBrowserWidget)
        ZenSpec.replace("apps/reader/modules/readermenu", ReaderMenu)
        ZenSpec.replace("apps/reader/modules/readerconfig", ReaderConfig)

        local scheduled, tour_args
        ZenSpec.replace("ui/uimanager", {
            show = function(_, widget) shown = widget end,
            scheduleIn = function(_, delay, callback)
                scheduled = { delay = delay, callback = callback }
            end,
            setDirty = function() end,
            unschedule = function() end,
        })
        ZenSpec.replace("common/quickstart/reader_tour", {
            start = function(...) tour_args = { ... } end,
        })
        local plugin = {
            config = {
                _meta = { quickstart_reader_tour_pending = true },
                features = { page_browser = false },
            },
        }
        _G.__ZEN_UI_PLUGIN = plugin
        require("modules/reader/patches/page_browser")()

        local ui = { registerTouchZones = function() end, document = {} }
        ReaderMenu.onReaderReady({ ui = ui })
        expect(scheduled.delay == 0.5)
        scheduled.callback()
        expect(tour_args[1] == plugin and tour_args[2] == ui)

        local menu_closes = 0
        local reader_menu = {
            ui = ui,
            onCloseReaderMenu = function() menu_closes = menu_closes + 1 end,
        }
        setmetatable(reader_menu, { __index = ReaderMenu })
        reader_menu:_zen_start_reader_tour()
        expect(menu_closes == 1)
        expect(scheduled.delay == 0)
        scheduled.callback()
        expect(tour_args[1] == plugin and tour_args[2] == ui)

        reader_store.settings.page_browser_layout = "single"
        local browser, finish_tour = tour_args[3]("carousel")
        expect(browser == shown and browser.zen_page_browser == true)
        expect(reader_store.settings.page_browser_layout == "carousel")
        finish_tour()
        expect(reader_store.settings.page_browser_layout == "single")
        expect(browser_closes == 1)
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
            _zen_layout_button = footer[1],
            _zen_btn_skip_left = footer[2],
            _zen_btn_skip_right = footer[3],
            _zen_search_button = footer[4],
        }
        setmetatable(browser, { __index = PageBrowserWidget })
        PageBrowserWidget._zenRebuildFocusLayout(browser)
        expect(#browser.layout == 4)
        expect(#browser.layout[1] == 7 and #browser.layout[2] == 3)
        expect(#browser.layout[3] == 3 and #browser.layout[4] == 4)
        expect(browser.layout[1][7]._zen_focus_id == "header:7")
        expect(browser.layout[3][3]._zen_focus_id == "page:6")
        expect(browser.layout[4][1]._zen_focus_id == "footer:layout")
        expect(browser.layout[4][3]._zen_focus_id == "footer:next")
        expect(browser.layout[4][4]._zen_focus_id == "footer:search")
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
        expect(browser.layout[browser.selected.y][browser.selected.x]._zen_focus_id == "footer:search")

        require("ui/bidi").mirroredUILayout = function() return true end
        browser.selected = { x = 3, y = 1 }
        local physical_dx
        headers[3].onHorizontalKey = function(_self, dx) physical_dx = dx; return true end
        PageBrowserWidget.onFocusMove(browser, { 1, 0 })
        expect(physical_dx == 1)
        PageBrowserWidget.onFocusMove(browser, { -1, 0 })
        expect(physical_dx == -1)
        expect(browser.selected.x == 3)
        headers[3].onHorizontalKey = nil
        PageBrowserWidget.onFocusMove(browser, { 1, 0 })
        expect(browser.selected.x == 2)
        browser.selected = { x = 2, y = 4 }
        PageBrowserWidget.onFocusMove(browser, { 1, 0 })
        expect(browser.selected.x == 3)
        require("ui/bidi").mirroredUILayout = function() return false end

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

        browser._zen_active_tab = "aa"
        browser._zen_row_panel = { layout = { { focus_widget() } } }
        PageBrowserWidget._zenRebuildFocusLayout(browser, "page:2")
        expect(#browser.layout == 3)
        expect(browser.layout[2][2]._zen_focus_id == "page:2")
        expect(browser.layout[3][1]._zen_focus_id == "content:1:1")

        local info, scrolls = focus_widget(), 0
        info.layout = { { info } }
        info._description_widget = {}
        info._descriptionAtTop = function() return scrolls == 0 end
        info.onKeyPress = function() scrolls = scrolls + 1; return true end
        info.onKeyRepeat = info.onKeyPress
        info.handleEvent = function(self, event) self._zen_focus_enabled = event.name == "Focus" end
        browser._zen_active_tab, browser._zen_content_panel = "book_details", info
        PageBrowserWidget._zenRebuildFocusLayout(browser, "header:1")
        expect(#browser.layout == 2 and #browser.layout[2] == 1)
        local function key(name)
            return { match = function(_self, sequence) return sequence[1] == name end }
        end
        browser:onKeyPress(key("Down"))
        expect(info._zen_focus_enabled and browser.selected.y == 2)
        browser:onKeyPress(key("Down"))
        browser:onKeyRepeat(key("Down"))
        expect(scrolls == 2 and browser.selected.y == 2)
        scrolls = 0
        browser:onKeyPress(key("Up"))
        expect(not info._zen_focus_enabled and browser.selected.y == 1)
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
            updateFocusPage = function(self, value, relative)
                self.focus_page = relative and self.focus_page + value or value
                return true
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
            title_bar_h = 0,
            grid_width = 600,
            grid_height = 500,
            nb_grid_items = 3,
            grid = grid,
            focus_page = 5,
            cur_page = 5,
            nb_pages = 10,
        }
        expect(PageBrowserWidget._zenConfigureCarouselGrid(browser) == true)
        expect(browser.grid_item_width == 400 and browser.grid_item_height == 488)
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
        expect(painted_labels["5"].x == 290 and painted_labels["5"].y == 451)
        expect(painted_labels["4"].y == 485 and painted_labels["6"].y == 485)

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

        browser._zen_active_tab = "aa"
        browser.title_bar_h, browser._zen_panel_h = 80, 210
        browser.updateFocusPage = nil
        browser.ui = { rolling = {}, document = { getPageXPointer = function(_self, page) return "xp:" .. page end } }
        grid[1].page_idx = 4
        expect(PageBrowserWidget.onTap(browser, nil, { pos = tap_item(1) }) == true)
        expect(browser.focus_page == 4 and browser._zen_preview_xpointer == "xp:4")
        expect(PageBrowserWidget.onTap(browser, nil, { pos = tap_item(3) }) == true)
        expect(browser.focus_page == 6 and browser._zen_preview_xpointer == "xp:6")
        expect(PageBrowserWidget.onSwipe(browser, nil, { pos = tap_item(2), direction = "west" }) == true)
        expect(browser.focus_page == 7 and browser._zen_preview_xpointer == "xp:7")
        expect(PageBrowserWidget.onSwipe(browser, nil, { pos = tap_item(2), direction = "east" }) == true)
        expect(browser.focus_page == 6 and browser._zen_preview_xpointer == "xp:6")
        expect(PageBrowserWidget.onTap(browser, nil, { pos = tap_item(2) }) == "stock")
        expect(stock_taps == 2)

        local opened, held, closed, stacked
        browser._zen_visible_pages = { 10, 20, 30, 40, 50, 60, 70 }
        browser.ui.link = { addCurrentLocationToStack = function() stacked = true end }
        browser.ui.handleEvent = function(_self, event) opened = event.args[1] end
        browser.onClose = function() closed = true end
        browser.onThumbnailHold = function(_self, page) held = page end
        PageBrowserWidget.onHold(browser, nil, { pos = tap_item(1) })
        expect(held == 40 and not closed)
        PageBrowserWidget.onTap(browser, nil, { pos = { x = 10, y = 750 } })
        PageBrowserWidget.onSwipe(browser, nil, { pos = { x = 10, y = 750 }, direction = "west" })
        expect(browser.focus_page == 6 and not closed)
        PageBrowserWidget.onTap(browser, nil, { pos = tap_item(2) })
        expect(closed and stacked and opened == 50)

        browser.grid_height, browser._zen_active_tab = 560, "browser"
        PageBrowserWidget._zenConfigureCarouselGrid(browser)
        expect(browser.grid_item_width == 411 and browser.grid_item_height == 548)
        browser._zen_active_tab = "aa"
        PageBrowserWidget._zenConfigureCarouselGrid(browser)
        expect(browser.grid_item_width == 400 and browser.grid_item_height == 548)
    end)

    it("opens the Zen page browser from its reader event while the bottom gesture is disabled", function()
        local PageBrowserWidget = { new = function(_self, spec) return spec end }
        install_widget_dependencies(PageBrowserWidget)
        ZenSpec.replace("apps/reader/modules/readermenu", { initGesListener = function() end })
        ZenSpec.replace("apps/reader/modules/readerconfig", { onSwipeShowConfigMenu = function() end })
        local config = { features = { page_browser = false }, reader_bottom_swipe = { mode = "none" } }
        _G.__ZEN_UI_PLUGIN = { config = config }
        require("modules/reader/patches/page_browser")()
        local ui = {}
        assert.is_true(require("apps/reader/modules/readerthumbnail").onShowPageBrowser{ ui = ui })
        assert.are.equal(ui, shown.ui)
        assert.is_function(PageBrowserWidget.init)
        assert.are.equal("none", require("common/reader_bottom_swipe").getMode(config))
        assert.is_false(config.features.page_browser)
    end)

    it("routes custom bottom swipes through both gesture entry points and respects lockdown", function()
        local stock_calls, activated = 0, 0
        local ReaderMenu = { initGesListener = function() end }
        local ReaderConfig = { onSwipeShowConfigMenu = function() stock_calls = stock_calls + 1 end }
        install_widget_dependencies({})
        ZenSpec.replace("apps/reader/modules/readermenu", ReaderMenu)
        ZenSpec.replace("apps/reader/modules/readerconfig", ReaderConfig)
        local entry = { type = "action", action = { show_menu = true } }
        local plugin = { config = {
            features = { page_browser = false }, reader_bottom_swipe = { mode = "custom", entries = { entry } },
        } }
        ZenSpec.replace("modules/menu/app_launcher/entry_action", function(actual, menu, owner, scope)
            expect(actual == entry and menu == nil and owner == plugin and scope == "reader")
            activated = activated + 1
        end)
        _G.__ZEN_UI_PLUGIN = plugin
        require("modules/reader/patches/page_browser")()
        local ui = {
            registerTouchZones = function(_self, registered) zones = registered end,
            handleEvent = function(_self, event) events[#events + 1] = event end,
        }
        ReaderMenu.initGesListener({ ui = ui })
        expect(zones[1].handler({ direction = "north" }) == true)
        expect(ReaderConfig.onSwipeShowConfigMenu({ ui = ui }, { direction = "north" }) == true)
        expect(activated == 2 and #events == 2 and stock_calls == 0)
        expect(zones[1].handler({ direction = "east" }) == nil)
        expect(activated == 2)
        plugin.config.features.lockdown_mode = true
        plugin.config.lockdown = { disable_bottom_menu_swipe = true }
        expect(zones[1].handler({ direction = "north" }) == nil)
        expect(ReaderConfig.onSwipeShowConfigMenu({ ui = ui }, { direction = "north" }) == nil)
        expect(activated == 2 and stock_calls == 0)
        plugin.config.reader_bottom_swipe.mode = "none"
        plugin.config.features.lockdown_mode = false
        expect(zones[1].handler({ direction = "north" }) == nil)
        expect(ReaderConfig.onSwipeShowConfigMenu({ ui = ui }, { direction = "north" }) == nil)
        expect(stock_calls == 0)
        plugin.config.reader_bottom_swipe.mode = "koreader"
        ReaderConfig.onSwipeShowConfigMenu({ ui = ui }, { direction = "north" })
        expect(stock_calls == 1)
        plugin.config.reader_bottom_swipe.mode = "reader_controls"
        ui.menu = { onShowReaderControls = function() activated = activated + 1 end }
        expect(zones[1].handler({ direction = "north" }) == true)
        expect(ReaderConfig.onSwipeShowConfigMenu({ ui = ui }, { direction = "north" }) == true)
        expect(activated == 4 and stock_calls == 1)
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
                self.title_bar_h = 64
                self.title_bar = {
                    left,
                    right,
                    left_button = left,
                    right_button = right,
                    setTitle = function() end,
                    getHeight = function() return 64 end,
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

    it("keeps KOReader book-search results with word context", function()
        local results = {
            { matched_text = "river", matched_word_prefix = "", matched_word_suffix = "s" },
            { matched_text = "river", matched_word_prefix = "a", matched_word_suffix = "" },
        }
        local shown_results
        local ReaderSearch = {
            findall_results = results,
            onShowFindAllResults = function(self)
                shown_results = self.findall_results
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

        ReaderSearch:onShowFindAllResults(true)
        expect(shown_results == results and #shown_results == 2)
    end)

    it("leaves KOReader reader search untouched when Zen Search is disabled", function()
        local stock_show = function() return "stock" end
        local stock_search = function() return "search" end
        local stock_results = function() return "results" end
        local ReaderSearch = {
            onShowFulltextSearchInput = stock_show,
            search = stock_search,
            onShowFindAllResults = stock_results,
        }
        ZenSpec.replace("apps/reader/modules/readersearch", ReaderSearch)
        ZenSpec.replace("apps/reader/modules/readermenu", { initGesListener = function() end })
        ZenSpec.replace("apps/reader/modules/readerconfig", { onSwipeShowConfigMenu = function() end })
        _G.__ZEN_UI_PLUGIN = {
            config = { features = { page_browser = false, search = false } },
        }

        require("modules/reader/patches/page_browser")()
        expect(ReaderSearch.onShowFulltextSearchInput == stock_show)
        expect(ReaderSearch.search == stock_search)
        expect(ReaderSearch.onShowFindAllResults == stock_results)
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

    it("refreshes only a visible changed status bar and unbinds its clock on close", function()
        local closed, unbound, dirty = 0, nil, nil
        local PageBrowserWidget = {
            new = function(_self, spec) return spec end,
            onClose = function() closed = closed + 1 end,
        }
        install_widget_dependencies(PageBrowserWidget)
        ZenSpec.replace("apps/reader/modules/readermenu", { initGesListener = function() end })
        ZenSpec.replace("apps/reader/modules/readerconfig", { onSwipeShowConfigMenu = function() end })
        ZenSpec.replace("common/clock_timer", { unbind = function(target) unbound = target end })
        _G.__ZEN_UI_PLUGIN = { config = { features = { page_browser = true } } }
        require("modules/reader/patches/page_browser")()
        require("apps/reader/modules/readerthumbnail"):onShowPageBrowser()
        local function status_row(value)
            return { value = value, dimen = { copy = function() return { y = 16, h = 20 } end },
                free = function(self) self.freed = true end }
        end
        local previous, current = status_row("12:00"), status_row("12:00")
        local browser = setmetatable({
            _zen_status_row = previous, _zen_header = { {}, previous }, _zen_status_clock_bound = true,
            _zen_build_status_row = function() return current end,
            _zen_status_regions = function(first, second)
                return first.value == second.value and {} or { {} }
            end,
        }, { __index = PageBrowserWidget })
        local manager = require("ui/uimanager")
        manager._window_stack = {{ widget = browser }}
        manager.setDirty = function(_self, target, mode, bounds) dirty = { target, mode, bounds } end
        browser:_zen_status_refresh()
        expect(current.freed and not previous.freed and not dirty)
        current = status_row("12:01")
        manager._window_stack = {{ widget = {} }}
        browser:onNetworkConnected()
        expect(not previous.freed and not dirty)
        manager._window_stack = {{ widget = browser }}
        browser:onResume()
        expect(previous.freed and browser._zen_status_row == current and browser._zen_header[2] == current)
        expect(dirty[1] == browser and dirty[2] == "ui" and dirty[3].y == 16 and dirty[3].h == 20)
        expect(current.dimen.y == 16 and current.dimen.h == 20)
        browser:onClose()
        expect(closed == 1 and unbound == browser and not browser._zen_status_clock_bound)
        dirty = nil
        browser:_zen_status_refresh()
        expect(not dirty)
    end)

    it("restores the recent controls page for six seconds and the last tab across restarts", function()
        local close_button_taps, closes, layouts = 0, 0, 0
        local now = 1000
        local time_stub = stub(os, "time", function() return now end)
        finally(function() time_stub:revert() end)
        local PageBrowserWidget = {
            onClose = function() closes = closes + 1 end,
            init = function(self)
                local left = { callback = function() end }
                local right = { callback = function() close_button_taps = close_button_taps + 1 end }
                self.ges_events = {}
                self.dimen = { w = 600, h = 800 }
                self.title_bar_h = 64
                self.nb_cols, self.nb_rows = 3, 2
                self.title_bar = {
                    left, right, width = 600, left_button = left, right_button = right,
                    button_padding = 11, setTitle = function(bar, title) bar.title = title end,
                    getHeight = function() return 64 end,
                }
            end,
            new = function(_self, spec) return { ui = spec.ui } end,
        }
        install_widget_dependencies(PageBrowserWidget)
        ZenSpec.replace("apps/reader/modules/readermenu", { initGesListener = function() end })
        ZenSpec.replace("apps/reader/modules/readerconfig", { onSwipeShowConfigMenu = function() end })
        local function widget_class()
            return { new = function(_self, spec) return spec end }
        end
        ZenSpec.replace("common/ui/zen_icon_button", widget_class())
        ZenSpec.replace("ui/gesturerange", widget_class())
        ZenSpec.replace("ui/geometry", widget_class())
        ZenSpec.replace("common/ui/zen_tab_bar", { new = function(_self, spec)
            spec.cells = {}
            for i, item in ipairs(spec.items) do spec.cells[i] = { callback = item.callback } end
            spec.getSize = function() return { w = spec.width, h = 44 } end
            spec.free = function() end
            return spec
        end })
        ZenSpec.replace("common/plugin_root", ZenSpec.root)
        ZenSpec.replace("common/utils", {
            resolveIcon = function(_dir, name) return "/custom-icons/" .. name .. ".svg" end,
            resolveLocalIcon = function(dir, name)
                local path = dir .. name .. ".svg"
                local file = io.open(path, "rb")
                if not file then return nil end
                file:close()
                return path
            end,
        })
        local details
        ZenSpec.replace("modules/reader/book_details", { show = function(ui) details = ui end })
        local saves = 0
        _G.__ZEN_UI_PLUGIN = { saveConfig = function() saves = saves + 1 end,
            config = { features = { page_browser = true }, page_browser = {
                tab_order = { "browser", "aa", "annotations", "toc" },
                tabs = { bookmarks = false, highlights = false, annotations = true } } } }
        require("modules/reader/patches/page_browser")()
        require("apps/reader/modules/readerconfig").onSwipeShowConfigMenu(
            { ui = { handleEvent = function() end } }, { direction = "north" })
        local function shell(ui)
            return setmetatable({ ui = ui or {},
                updateLayout = function() layouts = layouts + 1 end,
            }, { __index = PageBrowserWidget })
        end
        local browser = shell()
        PageBrowserWidget.init(browser)
        expect(browser.title_bar.title == "" and browser.title_bar.left_button == nil)
        expect(#browser._zen_header_buttons == 6)
        for _i, button in ipairs(browser._zen_header_buttons) do
            expect(button.file:sub(1, 14) == "/custom-icons/")
        end
        local close = browser._zen_header_buttons[6]
        expect(browser._zen_header_buttons[1] == browser._zen_more_button)
        expect(browser._zen_more_button.overlap_align == "left" and browser._zen_more_button.overlap_offset[1] == 0)
        expect(browser._zen_header_buttons[2].file == "/custom-icons/view_carousel_outline.svg")
        expect(browser._zen_header_buttons[3].file == "/custom-icons/font.svg")
        expect(browser._zen_tab_bar.icon_size == 24)
        expect(browser._zen_tab_bar.items[2].icon_size == nil and browser._zen_tab_bar.items[4].icon_size == nil)
        expect(browser._zen_header_buttons[5].file == "/custom-icons/toc.svg")
        expect(browser._zen_more_button.file == "/custom-icons/more_vertical.svg")
        expect(close.file == "/custom-icons/close.svg" and close.overlap_align == "right")
        expect(close.width == 28 and close.height == 28)
        expect(close.width + close.padding + close.padding_right == 54)
        expect(close.height + close.padding + close.padding_bottom == 54)
        expect(browser._zen_tab_bar.selected == 1 and browser._zen_tab_bar.overlap_offset[1] == 108)
        for _i, dimensions in ipairs({ { 1200, 800 }, { 1000, 666 }, { 400, 184 }, { 600, 384 } }) do
            browser.dimen.w = dimensions[1]
            browser:_zenBuildHeaderTabs()
            local tabs = browser._zen_tab_bar
            expect(tabs.width == dimensions[2])
            expect(tabs.overlap_offset[1] == math.floor((dimensions[1] - dimensions[2]) / 2))
            expect(tabs.overlap_offset[1] + tabs.width <= dimensions[1] - 108)
        end
        expect(details == nil and closes == 0)
        browser._zen_post_scrub = true
        browser._zen_placeholders_painted = true
        for _i, tab in ipairs({ { 2, "aa", "carousel" }, { 3, "annotations", "carousel" },
                { 4, "toc", "carousel" }, { 1, "browser", "carousel" } }) do
            browser._zen_tab_bar.cells[tab[1]].callback()
            expect(browser._zen_active_tab == tab[2] and browser._zen_layout_mode == tab[3])
            expect(browser._zen_tab_bar.selected == tab[1] and closes == 0)
            expect(browser._zen_header_buttons[1] == browser._zen_more_button)
            expect(#browser._zen_header_buttons == 6)
            expect(not browser._zen_post_scrub and not browser._zen_placeholders_painted)
        end
        expect(layouts == 5)
        expect(browser._zen_header_top_padding == 16 and browser.title_bar_h == 80)
        local taps = 0
        browser._zen_tab_bar.dimen = { contains = function() return true end }
        browser._zen_tab_bar.cells[2].dimen = { contains = function() return true end }
        browser._zen_tab_bar.cells[2].callback = function() taps = taps + 1 end
        local gesture = { handler = "onGesture", args = { { ges = "tap", pos = {} } } }
        expect(browser:handleEvent(gesture) == true and taps == 1)
        gesture.args[1].ges = "swipe"
        expect(browser:handleEvent(gesture) == true and taps == 1)
        reader_store.settings.page_browser_layout = "grid"
        browser:_zenSelectTab("aa")
        expect(browser._zen_layout_mode == "single")
        close.callback()
        expect(close_button_taps == 1)

        local state = { section = "font", page = 2, advanced = { page = true }, section_pages = { page = 3 },
            themes_move = function() error("closed panel callback retained") end }
        browser._zen_controls_state = state
        browser:onClose()
        now = now + 6
        local reopened = shell(browser.ui)
        PageBrowserWidget.init(reopened)
        expect(reopened._zen_active_tab == "aa" and reopened._zen_layout_mode == "single")
        expect(reopened._zen_tab_bar.selected == 2)
        expect(reopened._zen_controls_state.section == "font" and reopened._zen_controls_state.page == 2)
        expect(reopened._zen_controls_state.advanced.page and reopened._zen_controls_state.section_pages.page == 3)
        expect(reopened._zen_controls_state.themes_move == nil)
        expect(reopened.ui._zen_page_browser_resume == nil)

        for _i, tab in ipairs({ "annotations", "toc", "browser" }) do
            reopened:_zenSelectTab(tab)
            reopened:onClose()
            now = now + 1
            reopened = shell(browser.ui)
            PageBrowserWidget.init(reopened)
            expect(reopened._zen_active_tab == tab)
        end
        reopened:_zenSelectTab("aa")
        local saved = saves
        reopened:onClose()
        local cfg = _G.__ZEN_UI_PLUGIN.config.page_browser
        expect(cfg.last_tab == "aa" and saves == saved + 1)
        -- A fresh reader (restart) keeps the persisted tab but not the transient controls state.
        local other_book = shell()
        PageBrowserWidget.init(other_book)
        expect(other_book._zen_active_tab == "aa" and other_book._zen_controls_state == nil)
        other_book:_zenSelectTab("browser")
        other_book:onClose()
        local overview = shell(other_book.ui)
        PageBrowserWidget.init(overview)
        expect(overview._zen_active_tab == "browser" and overview._zen_controls_state == nil)
        saved = saves
        overview:onClose()
        expect(saves == saved)
        now = now + 7
        cfg.last_tab = nil
        local expired = shell(browser.ui)
        PageBrowserWidget.init(expired)
        expect(expired._zen_active_tab == "browser" and expired._zen_controls_state == nil)

        cfg.tab_order = { "highlights", "annotations", "aa", "browser", "toc", "bookmarks" }
        cfg.tabs.highlights = false
        local ordered = shell(browser.ui)
        PageBrowserWidget.init(ordered)
        expect(ordered._zen_active_tab == "annotations")
        expect(ordered._zen_tab_bar.cells[1].file == "/custom-icons/annotations.svg")
        ordered:_zenSelectTab("aa")
        ordered:onClose()
        ordered = shell(browser.ui)
        PageBrowserWidget.init(ordered)
        expect(ordered._zen_active_tab == "aa" and ordered._zen_tab_bar.selected == 2)
        ordered:_zenSelectTab("annotations")
        ordered:onClose()
        cfg.tabs.annotations = false
        ordered = shell(browser.ui)
        PageBrowserWidget.init(ordered)
        expect(ordered._zen_active_tab == "aa")
        expect(#ordered._zen_tab_bar.cells == 3)
        expect(#ordered._zen_header_buttons == 5)
        cfg.tabs.book_details = true
        ordered:_zenBuildHeaderTabs()
        expect(#ordered._zen_tab_bar.cells == 4)
        expect(ordered._zen_tab_bar.cells[4].file == "/custom-icons/info.svg")
        local previous_layouts = layouts
        ordered._zen_tab_bar.cells[4].callback()
        expect(details == nil and layouts == previous_layouts + 1)
        expect(ordered._zen_active_tab == "book_details" and ordered._zen_tab_bar.selected == 4)

        local targeted = shell(browser.ui)
        targeted._zen_initial_tab = "bookmarks"
        PageBrowserWidget.init(targeted)
        expect(targeted._zen_active_tab == "bookmarks")
        expect(targeted._zen_tab_bar.cells[targeted._zen_tab_bar.selected].file == "/custom-icons/bookmark_outline.svg")
        expect(cfg.tabs.bookmarks == false)

        cfg.tab_order = { "book_details" }
        for id in pairs(cfg.tabs) do cfg.tabs[id] = id == "book_details" end
        details = nil
        local details_first = shell()
        PageBrowserWidget.init(details_first)
        expect(#details_first._zen_tab_bar.cells == 1 and details == nil)
        expect(details_first._zen_active_tab == "book_details" and details_first._zen_tab_bar.selected == 1)

        require("common/utils").resolveIcon = function(dir, name) return dir .. name .. ".svg" end
        cfg.tab_order = { "browser", "aa", "toc", "book_details" }
        cfg.tabs.browser, cfg.tabs.aa, cfg.tabs.toc = true, true, true
        local bundled = shell()
        PageBrowserWidget.init(bundled)
        expect(bundled._zen_tab_bar.cells[1].file == ZenSpec.root .. "/icons/view_carousel_outline.svg")
        for i, name in ipairs({ "font", "toc", "info" }) do
            expect(bundled._zen_tab_bar.cells[i + 1].file == ZenSpec.root .. "/icons/" .. name .. ".svg")
        end
        expect(bundled._zen_more_button.file == ZenSpec.root .. "/icons/more_vertical.svg")
        expect(bundled.title_bar.right_button.file == require("libs/libkoreader-lfs").currentdir()
            .. "/resources/icons/mdlight/close.svg")
    end)

    it("offers bookmark and pin actions for the held page without navigating", function()
        local PageBrowserWidget = { new = function(_self, spec) return spec end }
        install_widget_dependencies(PageBrowserWidget)
        ZenSpec.replace("apps/reader/modules/readermenu", {})
        ZenSpec.replace("apps/reader/modules/readerconfig", {})
        ZenSpec.replace("common/utils", {
            resolveIcon = function(_dir, name) return "/custom-icons/" .. name .. ".svg" end,
        })
        local menu_size = { w = 120, h = 60 }
        ZenSpec.replace("ui/widget/buttondialog", { new = function(_self, spec)
            spec.getContentSize = function() return menu_size end
            return spec
        end })
        ZenSpec.replace("common/ui/button_labels", {
            prepare = function(buttons) return buttons end, apply = function() end,
        })
        local plugin = { config = { features = { page_browser = true, reader_references = false } } }
        _G.__ZEN_UI_PLUGIN = plugin
        require("modules/reader/patches/page_browser")()
        require("apps/reader/modules/readerthumbnail"):onShowPageBrowser()
        local closed, refreshed, invalidated, bookmarked = 0, 0, 0
        local bookmarks = {}
        require("ui/uimanager").close = function(_self, dialog)
            expect(dialog == shown)
            closed = closed + 1
        end
        local ui = {
            rolling = {}, doc_settings = ZenSpec.memorySettings(),
            document = { getPageCount = function() return 20 end,
                getPageXPointer = function(_self, page) return "xp:" .. page end,
                getPageFromXPointer = function(_self, xp) return tonumber(xp:match("%d+")) end },
            bookmark = {
                isPageBookmarked = function(_self, location)
                    local page = type(location) == "string" and tonumber(location:match("^xp:(%d+)$")) or location
                    return bookmarks[page] == true
                end,
                toggleBookmark = function(_self, page)
                    bookmarked, bookmarks[page] = page, not bookmarks[page]
                end,
            },
            getCurrentPage = function() return 2 end,
        }
        local browser = setmetatable({ ui = ui, _zen_plugin = plugin,
            nb_grid_items = 2, _zen_visible_pages = { 7, 9 },
            grid = {
                { page_idx = 1, dimen = { x = 20, y = 100, w = 240, h = 360 } },
                { page_idx = 2, dimen = { x = 300, y = 100, w = 240, h = 360 } },
            },
            updateEditableStuff = function(_self, redraw)
                expect(redraw == true)
                refreshed = refreshed + 1
            end,
        }, { __index = PageBrowserWidget })
        local gesture = { pos = { x = 200, y = 300 } }
        browser:onThumbnailHold(7, gesture)
        expect(bookmarked == nil and refreshed == 0 and invalidated == 0)
        expect(shown.name == "page_browser_page_actions" and #shown.buttons == 1 and #shown.buttons[1] == 2)
        local anchor, pop_down = shown.anchor()
        assert.same({ x = 80, y = 250, w = 120, h = 0 }, anchor)
        expect(pop_down == true and shown.shrink_unneeded_width == true)
        expect(shown.buttons[1][1].icon == "/custom-icons/bookmark.svg" and shown.buttons[1][1].text == nil)
        expect(shown.buttons[1][2].icon == "/custom-icons/pin.svg" and shown.buttons[1][2].text == nil)
        expect(shown.buttons[1][1].icon_height == 32 and shown.buttons[1][2].icon_height == 32)
        shown.buttons[1][1].callback()
        expect(bookmarked == 7 and refreshed == 1 and closed == 1)
        gesture.pos = { x = 30, y = 110 }
        browser:onThumbnailHold(7, gesture)
        assert.same(anchor, shown.anchor())
        expect(shown.buttons[1][1].icon == "/custom-icons/bookmark_remove.svg")
        shown.buttons[1][2].callback()
        assert.same({ "xp:7" }, ui.doc_settings:readSetting("zen_pinned_pages"))
        expect(ui.doc_settings:readSetting("pinned_page") == "xp:7")
        plugin.config.highlight_lookup = { show_labels = true }
        browser:onThumbnailHold(7, gesture)
        expect(shown.buttons[1][1].text == "Toggle page bookmark" and shown.buttons[1][2].text == "Remove pin")
        expect(shown.buttons[1][2].icon == "/custom-icons/pin_remove.svg" and shown.buttons[1][2].height == 28)
        shown.buttons[1][2].callback()
        assert.same({}, ui.doc_settings:readSetting("zen_pinned_pages"))
        expect(ui.doc_settings:readSetting("pinned_page") == nil)
        ui.rolling, ui.paging = nil, {}
        browser:onThumbnailHold(9, nil)
        assert.same({ x = 360, y = 250, w = 120, h = 0 }, shown.anchor())
        expect(shown.buttons[1][1].icon == "/custom-icons/bookmark.svg")
        expect(shown.buttons[1][2].text == "Pin")
        shown.buttons[1][2].callback()
        assert.same({ 9 }, ui.doc_settings:readSetting("zen_pinned_pages"))
        browser._zen_full_page_preview = { dimen = { x = 0, y = 0, w = 600, h = 800 },
            invalidate = function() invalidated = invalidated + 1 end }
        menu_size.w, menu_size.h = 200, 80
        browser:onThumbnailHold(9, gesture)
        assert.same({ x = 200, y = 360, w = 200, h = 0 }, shown.anchor())
        expect(shown.buttons[1][2].icon == "/custom-icons/pin_remove.svg")
        shown.buttons[1][2].callback()
        expect(ui:getCurrentPage() == 2 and refreshed == 5 and closed == 5 and invalidated == 1)
        browser:onThumbnailHold(7, gesture)
        expect(shown.buttons[1][1].icon == "/custom-icons/bookmark_remove.svg")
        shown.buttons[1][1].callback()
        expect(bookmarks[7] == false)
        browser:onThumbnailHold(7, gesture)
        expect(shown.buttons[1][1].icon == "/custom-icons/bookmark.svg")
    end)

    it("renders Android PDF Aa thumbnails with reading settings and leaves the live reader intact", function()
        local ReaderThumbnail, buffer = install_android_thumbnail_dependencies()
        local configurable = { text_wrap = 1, trim_page = 1, auto_straighten = 5 }
        local ui = {
            paging = {}, document = { configurable = configurable },
            view = { highlight_visible = true },
        }
        local rendered
        ZenSpec.replace("modules/reader/page_browser_preview", { new = function(_self, spec)
            spec.render = function(self)
                expect(self.ui == ui and self.page == 7 and self.width == 600 and self.height == 800)
                expect(self.bb_type == "thumbnail type")
                expect(configurable.text_wrap == 1 and configurable.trim_page == 1 and configurable.auto_straighten == 5)
                self.bb = buffer(self.width, self.height)
                rendered = self.bb
            end
            return spec
        end })
        local thumbnail = setmetatable({ ui = ui, _zen_settings_preview = true, bb_type = "thumbnail type" },
            { __index = ReaderThumbnail })
        local request = { page = 7, width = 150, height = 200 }
        expect(thumbnail:startTileGeneration(request))
        local tile = request._zen_sync_tile
        expect(rendered.freed and tile.bb.w == 150 and tile.bb.h == 200 and tile.pageno == 7)
        expect(configurable.text_wrap == 1 and configurable.trim_page == 1 and configurable.auto_straighten == 5)
    end)

    it("isolates PDF Aa thumbnails from overview thumbnails on tab changes and close", function()
        local PageBrowserWidget = { new = function(_self, spec) return spec end, onClose = function() end }
        install_widget_dependencies(PageBrowserWidget)
        ZenSpec.replace("apps/reader/modules/readermenu", {})
        ZenSpec.replace("apps/reader/modules/readerconfig", {})
        require("modules/reader/patches/page_browser")()
        require("apps/reader/modules/readerthumbnail"):onShowPageBrowser()
        local cancelled, cleared, layouts = 0, 0, 0
        local request = { hash = "p1-w150_h200" }
        local thumbnail = {
            req_in_progress = request,
            cancelPageThumbnailRequests = function() cancelled = cancelled + 1 end,
            resetCache = function() cleared = cleared + 1 end,
        }
        local browser = setmetatable({
            _zen_active_tab = "browser", _zen_layout_mode = "carousel", grid = {},
            ui = { paging = {}, thumbnail = thumbnail },
            _zenBuildHeaderTabs = function() end,
            updateLayout = function(self)
                expect(not self._zen_panel_only_rebuild)
                layouts = layouts + 1
            end,
        }, { __index = PageBrowserWidget })
        browser:_zenSelectTab("aa")
        expect(thumbnail._zen_settings_preview and cancelled == 1 and cleared == 1)
        expect(request.hash ~= "p1-w150_h200")
        browser:_zenSelectTab("browser")
        expect(not thumbnail._zen_settings_preview and cancelled == 2 and cleared == 2)
        browser:_zenSelectTab("aa")
        browser:onClose()
        expect(not thumbnail._zen_settings_preview and cancelled == 4 and cleared == 4 and layouts == 3)
    end)

    it("invalidates in-flight thumbnails and preserves the preview location after reflow", function()
        local PageBrowserWidget = { new = function(_self, spec) return spec end }
        install_widget_dependencies(PageBrowserWidget)
        ZenSpec.replace("apps/reader/modules/readermenu", {})
        ZenSpec.replace("apps/reader/modules/readerconfig", {})
        require("modules/reader/patches/page_browser")()
        require("apps/reader/modules/readerthumbnail"):onShowPageBrowser()
        local request, cancelled, cleared, updated = { hash = "p4-w200_h300" }, false, false, 0
        local panel = {}
        local browser = setmetatable({
            _zen_active_tab = "aa", _zen_preview_xpointer = "paragraph-4", _zen_row_panel = panel,
            focus_page = 4, cur_page = 2, nb_pages = 8, _zen_tile_size = {},
            ui = {
                thumbnail = {
                    req_in_progress = request,
                    cancelPageThumbnailRequests = function(_self, batch) cancelled = batch == nil end,
                    resetCache = function() cleared = true end,
                },
                document = {
                    getPageCount = function() return 12 end,
                    getPageFromXPointer = function(_self, xp) expect(xp == "paragraph-4"); return 6 end,
                },
                getCurrentPage = function() return 3 end,
            },
            updateEditableStuff = function() end,
            update = function() updated = updated + 1 end,
        }, { __index = PageBrowserWidget })
        browser:_zenRefreshPreview()
        expect(request.hash ~= "p4-w200_h300" and cancelled and cleared)
        expect(browser.nb_pages == 12 and browser.cur_page == 3 and browser.focus_page == 6)
        expect(browser._zen_row_panel == panel and browser._zen_tile_size == nil and updated == 1)
        browser._zen_closed = true
        browser:_zenRefreshPreview()
        expect(updated == 1)
    end)

    it("adds book-search navigation arrows and supports hardware Back", function()
        local search_directions = {}
        local ReaderSearch = {
            searchCallback = function(_, direction)
                table.insert(search_directions, direction)
            end,
        }
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
                scaleBySize = function(_, value) return value end,
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
        local buttons = dialog.buttons[1]
        expect(#buttons == 3)
        expect(buttons[1].text == "◀" and buttons[1].width == 56)
        expect(buttons[2].is_enter_default == true)
        expect(buttons[3].text == "▶" and buttons[3].width == 56)
        buttons[1].callback()
        buttons[3].callback()
        expect(search_directions[1] == 1 and search_directions[2] == 0)
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

    it("opens page-browser searches as a results list that closes the browser on pick", function()
        local order = {}
        local page_browser = { onClose = function(_, all) table.insert(order, all and "close_all" or "close") end }
        local menu
        local ReaderSearch = {
            _zen_page_browser = page_browser,
            onShowFindAllResults = function(self)
                menu = {
                    dimen = { h = 800 }, [1] = {},
                    onMenuChoice = function(_, item) table.insert(order, "goto:" .. item.idx) end,
                }
                self.result_menu = menu
            end,
        }
        local dialog
        ZenSpec.replace("apps/reader/modules/readersearch", ReaderSearch)
        ZenSpec.replace("apps/reader/modules/readermenu", { initGesListener = function() end })
        ZenSpec.replace("apps/reader/modules/readerconfig", { onSwipeShowConfigMenu = function() end })
        ZenSpec.replace("ui/widget/inputdialog", {
            onTap = function() end,
            new = function(_, spec)
                dialog = spec
                spec.title_bar = {}
                spec.onShowKeyboard = function() end
                return spec
            end,
        })
        ZenSpec.replace("ui/uimanager", {
            show = function() end,
            isWidgetShown = function(_, widget) return widget == menu end,
            scheduleIn = function() end,
            setDirty = function() end,
            unschedule = function() end,
        })
        ZenSpec.replace("common/ui/zen_modal_close", { installDialog = function() end })
        _G.__ZEN_UI_PLUGIN = { config = { features = { page_browser = false } } }
        require("modules/reader/patches/page_browser")()

        ReaderSearch:onShowFulltextSearchInput("needle")
        expect(#dialog.buttons[1] == 1 and dialog.buttons[1][1].is_enter_default == true)

        ReaderSearch:onShowFindAllResults(true)
        menu:onMenuChoice({ idx = 3 })
        expect(order[1] == "close_all" and order[2] == "goto:3")
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
