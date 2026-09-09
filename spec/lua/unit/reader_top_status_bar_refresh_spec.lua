describe("reader top status bar refresh", function()
    local ReaderUI
    local ReaderTypeset
    local ReaderView
    local CreDocument
    local UIManager
    local saved_modules
    local saved_plugin
    local saved_settings
    local scheduled
    local unscheduled
    local paint_rects
    local dirty_calls
    local paint_order
    local item_fetchers
    local collect_item_texts
    local build_group_from_texts
    local startup_reader
    local disabled_reader
    local NetworkMgr

    local dependencies = {
        "apps/reader/modules/readerview",
        "apps/reader/modules/readertypeset",
        "apps/reader/readerui",
        "common/inline_icon_map",
        "common/ui/color_text_widget",
        "common/reader_status_bar",
        "common/reader_themes",
        "common/utils",
        "common/zen_logger",
        "datetime",
        "device",
        "document/credocument",
        "ffi/blitbuffer",
        "gettext",
        "ui/bidi",
        "ui/font",
        "ui/geometry",
        "ui/network/manager",
        "ui/size",
        "ui/uimanager",
        "ui/widget/container/centercontainer",
        "ui/widget/container/leftcontainer",
        "ui/widget/container/rightcontainer",
        "ui/widget/horizontalgroup",
        "ui/widget/horizontalspan",
        "ui/widget/linewidget",
        "ui/widget/textwidget",
        "ui/widget/verticalgroup",
        "ui/widget/verticalspan",
        "modules/reader/patches/reader_top_status_bar",
    }

    local function geometry_class()
        return {
            new = function(_self, values) return values end,
        }
    end

    local function replace(name, module)
        ZenSpec.replace(name, module)
    end

    local function replace_upvalue(fn, target, replacement)
        for index = 1, 40 do
            local name = debug.getupvalue(fn, index)
            if not name then break end
            if name == target then
                debug.setupvalue(fn, index, replacement)
                return true
            end
        end
        return false
    end

    local function get_upvalue(fn, target)
        for index = 1, 40 do
            local name, value = debug.getupvalue(fn, index)
            if not name then break end
            if name == target then return value end
        end
    end

    local function reset_paint_log()
        paint_rects = {}
        dirty_calls = {}
        paint_order = {}
    end

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(dependencies) do
            saved_modules[name] = package.loaded[name] or false
        end
        saved_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        saved_settings = G_reader_settings
        scheduled = {}
        unscheduled = {}
        reset_paint_log()

        local screen_bb = {
            paintRect = function(_self, x, y, w, h, color)
                paint_rects[#paint_rects + 1] = { x = x, y = y, w = w, h = h, color = color }
                paint_order[#paint_order + 1] = "clear"
            end,
        }
        local screen = {
            bb = screen_bb,
            getWidth = function() return 600 end,
            scaleBySize = function(_self, value) return value end,
        }

        UIManager = {
            _window_stack = {},
            scheduleIn = function(_self, delay, callback)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end,
            unschedule = function(_self, callback)
                unscheduled[callback] = true
            end,
            widgetRepaint = function()
                paint_order[#paint_order + 1] = "header"
            end,
            setDirty = function(_self, widget, mode, region, dither)
                dirty_calls[#dirty_calls + 1] = {
                    widget = widget, mode = mode, region = region, dither = dither,
                }
                paint_order[#paint_order + 1] = "dirty"
            end,
        }
        ReaderUI = {
            onSuspend = function() end,
            onResume = function() end,
            onCharging = function() end,
            onNotCharging = function() end,
            onNetworkConnected = function() end,
            onNetworkDisconnected = function() end,
            onClose = function() return "closed" end,
        }
        CreDocument = {
            setPageMargins = function(self, left, top, right, bottom)
                self.applied_margins = { left, top, right, bottom }
            end,
        }
        ReaderTypeset = {
            onSetPageMargins = function(self, margins)
                CreDocument.setPageMargins(self.ui.document,
                    margins[1], margins[2], margins[3], margins[4])
            end,
        }
        ReaderView = {
            paintTo = function() end,
            onSetViewMode = function(self, new_mode) self.view_mode = new_mode end,
        }

        replace("apps/reader/modules/readerview", ReaderView)
        replace("apps/reader/modules/readertypeset", ReaderTypeset)
        replace("apps/reader/readerui", ReaderUI)
        replace("common/inline_icon_map", {})
        replace("common/reader_themes", {
            getBackgroundColor = function() end,
            getTextColor = function() end,
        })
        replace("common/utils", {})
        replace("common/zen_logger", {
            new = function() return { dbg = function() end } end,
        })
        replace("datetime", {})
        replace("device", {
            screen = screen,
            hasBattery = function() return true end,
            getPowerDevice = function()
                return {
                    getCapacity = function() return 73 end,
                    getBatterySymbol = function() return "B" end,
                    isCharged = function() return false end,
                    isCharging = function() return false end,
                }
            end,
        })
        replace("document/credocument", CreDocument)
        replace("ffi/blitbuffer", {
            ColorRGB32 = function(red, green, blue)
                return string.format("rgb:%d:%d:%d", red, green, blue)
            end,
            COLOR_BLACK = "black",
            COLOR_DARK_GRAY = "dark_gray",
            COLOR_GRAY_5 = "gray_5",
            COLOR_LIGHT_GRAY = "light_gray",
            COLOR_WHITE = "white",
        })
        replace("gettext", function(text) return text end)
        replace("ui/bidi", { wrap = function(value) return value end })
        replace("ui/font", { getFace = function() return {} end })
        replace("ui/geometry", geometry_class())
        NetworkMgr = {
            wifi_on = false,
            connected = false,
            isWifiOn = function(self) return self.wifi_on end,
            isConnected = function(self) return self.connected end,
        }
        replace("ui/network/manager", NetworkMgr)
        replace("ui/size", { line = { thin = 1, medium = 1 }, padding = { small = 2 } })
        replace("ui/uimanager", UIManager)
        for _i, name in ipairs({
            "ui/widget/container/centercontainer",
            "ui/widget/container/leftcontainer",
            "ui/widget/container/rightcontainer",
            "ui/widget/horizontalgroup",
            "ui/widget/horizontalspan",
            "ui/widget/linewidget",
            "ui/widget/verticalgroup",
            "ui/widget/verticalspan",
        }) do
            replace(name, {})
        end
        replace("ui/widget/horizontalgroup", {
            new = function(_self, values) return values or {} end,
        })
        local function make_text_widget(values, is_color)
            values = values or {}
            values._is_color = is_color
            values.getSize = function() return { w = 10, h = 18 } end
            values.free = function() end
            return values
        end
        replace("ui/widget/textwidget", {
            new = function(_self, values) return make_text_widget(values, false) end,
        })
        replace("common/ui/color_text_widget", {
            new = function(_self, values) return make_text_widget(values, true) end,
        })

        G_reader_settings = ZenSpec.memorySettings({ footer = {} })
        replace("common/reader_status_bar", {
            disableKoreaderAltStatusBar = function(settings, reader)
                settings = settings or G_reader_settings
                settings:saveSetting("copt_status_line", 1)
                settings:saveSetting("alt_status_bar", false)
                disabled_reader = reader
                reader.document.configurable.status_line = 1
                reader.rolling:onSetStatusLine(1)
            end,
        })
        startup_reader = {
            document = { configurable = {} },
            rolling = {
                onSetStatusLine = function(_self, value)
                    startup_reader.status_line = value
                end,
            },
        }
        _G.__ZEN_UI_PLUGIN = {
            ui = startup_reader,
            config = {
                features = { reader_top_status_bar = true },
                reader_top_status_bar = {
                    left_order = { "wifi" },
                    center_order = { "time" },
                    right_order = { "battery" },
                },
            },
        }

        ZenSpec.unload("modules/reader/patches/reader_top_status_bar")
        require("modules/reader/patches/reader_top_status_bar")()

        local header = { paintTo = function() end }
        local slot_regions = {
            left = { x = 0, y = 0, w = 100, h = 20 },
            center = { x = 250, y = 0, w = 100, h = 20 },
            right = { x = 500, y = 0, w = 100, h = 20 },
        }
        local original_build_header = get_upvalue(ReaderView.paintTo, "buildHeader")
        collect_item_texts = get_upvalue(original_build_header, "collectItemTexts")
        build_group_from_texts = get_upvalue(original_build_header, "buildGroupFromTexts")
        item_fetchers = get_upvalue(collect_item_texts, "item_fetchers")
        assert.is_true(replace_upvalue(ReaderView.paintTo, "buildHeader", function()
            return header, {}, 20, 600, slot_regions
        end))
    end)

    after_each(function()
        for _i, name in ipairs(dependencies) do
            package.loaded[name] = saved_modules[name] or nil
        end
        _G.__ZEN_UI_PLUGIN = saved_plugin
        G_reader_settings = saved_settings
    end)

    local function make_view()
        local ui = { document = {}, dithered = true }
        local view = {
            ui = ui,
            document = {},
            view_mode = "page",
            dogear_visible = true,
            dogear = {
                paintTo = function()
                    paint_order[#paint_order + 1] = "dogear"
                end,
            },
        }
        ui.view = view
        ReaderUI.instance = ui
        UIManager._window_stack = { { widget = ui } }
        ReaderView.paintTo(view, require("device").screen.bb, 0, 0)
        reset_paint_log()
        return view
    end

    local function assert_single_slot(expected_x)
        assert.are.equal(1, #paint_rects)
        assert.same({ x = expected_x, y = 0, w = 100, h = 20, color = "white" }, paint_rects[1])
        assert.are.equal(1, #dirty_calls)
        assert.is_nil(dirty_calls[1].widget)
        assert.are.equal("ui", dirty_calls[1].mode)
        assert.are.equal(expected_x, dirty_calls[1].region.x)
        assert.are.equal(100, dirty_calls[1].region.w)
        assert.is_true(dirty_calls[1].dither)
        assert.same({ "clear", "header", "dogear", "dirty" }, paint_order)
    end

    local function make_typeset(view_mode)
        local document = {}
        local typeset = setmetatable({
            ui = { document = document },
            view = {
                view_mode = view_mode,
                footer = {
                    reclaim_height = false,
                    getHeight = function() return 15 end,
                },
            },
            unscaled_margins = { 5, 10, 5, 12 },
        }, { __index = ReaderTypeset })
        return typeset, document
    end

    it("adds the bottom status bar height only to effective paged CRE margins", function()
        local typeset, document = make_typeset("page")
        assert.are.equal(1, G_reader_settings:readSetting("copt_status_line"))
        assert.is_false(G_reader_settings:readSetting("alt_status_bar"))
        assert.are.equal(1, startup_reader.document.configurable.status_line)
        assert.are.equal(1, startup_reader.status_line)
        assert.are.equal(startup_reader, disabled_reader)

        typeset:onSetPageMargins(typeset.unscaled_margins)
        assert.same({ 5, 25, 5, 12 }, document.applied_margins)
        assert.are.equal(15, document._zen_top_status_bar_reserved_height)

        typeset:onSetPageMargins(typeset.unscaled_margins)
        assert.same({ 5, 25, 5, 12 }, document.applied_margins)

        _G.__ZEN_UI_PLUGIN.config.reader_top_status_bar.show_bottom_border = true
        typeset:onSetPageMargins(typeset.unscaled_margins)
        assert.same({ 5, 26, 5, 12 }, document.applied_margins)
    end)

    it("keeps equal margins equal when the status bars reclaim their height", function()
        local typeset, document = make_typeset("page")
        typeset.view.footer.reclaim_height = true
        typeset.unscaled_margins = { 5, 10, 5, 10 }

        typeset:onSetPageMargins(typeset.unscaled_margins)
        assert.same({ 5, 10, 5, 10 }, document.applied_margins)
        assert.are.equal(0, document._zen_top_status_bar_reserved_height)
    end)

    it("removes reserved space outside enabled paged CRE documents", function()
        local typeset, document = make_typeset("scroll")
        typeset:onSetPageMargins(typeset.unscaled_margins)
        assert.same({ 5, 10, 5, 12 }, document.applied_margins)

        typeset.view.view_mode = "page"
        _G.__ZEN_UI_PLUGIN.config.features.reader_top_status_bar = false
        typeset:onSetPageMargins(typeset.unscaled_margins)
        assert.same({ 5, 10, 5, 12 }, document.applied_margins)
    end)

    it("reapplies base margins when switching page and scroll modes", function()
        local typeset, document = make_typeset("page")
        local view = {
            view_mode = "page",
            footer = typeset.view.footer,
            ui = { typeset = typeset },
        }
        typeset.view = view
        typeset:onSetPageMargins(typeset.unscaled_margins)
        assert.are.equal(25, document.applied_margins[2])

        ReaderView.onSetViewMode(view, "scroll")
        assert.are.equal(10, document.applied_margins[2])
        ReaderView.onSetViewMode(view, "page")
        assert.are.equal(25, document.applied_margins[2])
    end)

    it("keeps margins unchanged during KOReader's temporary selection scrolling", function()
        local typeset, document = make_typeset("page")
        local view = typeset.view
        local highlight = {}
        view.ui = { typeset = typeset, highlight = highlight }
        typeset:onSetPageMargins(typeset.unscaled_margins)
        assert.are.equal(25, document.applied_margins[2])

        local margin_updates = 0
        typeset.onSetPageMargins = function() margin_updates = margin_updates + 1 end
        highlight.restore_page_mode_func = function()
            ReaderView.onSetViewMode(view, "page")
        end
        ReaderView.onSetViewMode(view, "scroll")
        assert.are.equal("scroll", view.view_mode)
        assert.are.equal(0, margin_updates) -- UpdatePos would reset the active hold gesture.
        assert.are.equal(25, document.applied_margins[2])

        highlight.restore_page_mode_func()
        highlight.restore_page_mode_func = nil
        assert.are.equal("page", view.view_mode)
        assert.are.equal(0, margin_updates)
        ReaderView.onSetViewMode(view, "scroll")
        assert.are.equal(1, margin_updates)
    end)

    it("exposes the granular alt-status-bar items alongside combined items", function()
        local icon, icon_suffix = item_fetchers.battery_icon()
        local percent = item_fetchers.battery_percent()
        assert.are.equal("B", icon)
        assert.is_nil(icon_suffix)
        assert.are.equal("73%", percent)

        local context = {
            ui = {
                document = {
                    getCurrentPage = function() return 7 end,
                    getPageCount = function() return 120 end,
                    hasHiddenFlows = function() return false end,
                },
            },
        }
        assert.are.equal("7", item_fetchers.current_page(context))
        assert.are.equal("120", item_fetchers.total_pages(context))
        assert.are.equal("7 / 120", item_fetchers.page_progress(context))
    end)

    it("hides Wi-Fi only when it is off and the option is enabled", function()
        assert.are.equal("\u{ECA9}", item_fetchers.wifi())

        _G.__ZEN_UI_PLUGIN.config.reader_top_status_bar.wifi_hide_when_off = true
        assert.is_nil(item_fetchers.wifi())

        NetworkMgr.wifi_on = true
        assert.are.equal("\u{ECA8}", item_fetchers.wifi())
    end)

    it("uses the bottom status bar's progress percentage format", function()
        local footer = {
            ui = {},
            percent_finished = 0.12345,
            settings = { progress_pct_format = "2" },
        }
        assert.are.equal("12.35%", item_fetchers.progress_percent({ footer = footer }))
    end)

    it("colors icon glyphs while keeping their labels in the reader text color", function()
        _G.__ZEN_UI_PLUGIN.config.reader_top_status_bar.colored = true
        local texts = collect_item_texts({ "battery" })
        assert.are.equal("rgb:51:170:85", texts[1].color)

        local group, widgets = build_group_from_texts(texts, {}, "", 100)
        assert.are.equal(2, #group)
        assert.is_true(widgets[1]._is_color)
        assert.are.equal("B", widgets[1].text)
        assert.is_false(widgets[2]._is_color)
        assert.are.equal("73%", widgets[2].text)

        _G.__ZEN_UI_PLUGIN.config.reader_top_status_bar.colored = false
        assert.is_nil(collect_item_texts({ "battery" })[1].color)
    end)

    it("hides reflowable headers in scroll mode and keeps the fixed-layout overlay optional", function()
        local view = make_view()
        view._zen_header_dimen = nil
        view.view_mode = "scroll"
        ReaderView.paintTo(view, require("device").screen.bb, 0, 0)
        assert.is_nil(view._zen_header_dimen)

        view.render_mode = 1
        _G.__ZEN_UI_PLUGIN.config.reader_top_status_bar.hide_in_cbz = true
        ReaderView.paintTo(view, require("device").screen.bb, 0, 0)
        assert.is_nil(view._zen_header_dimen)

        _G.__ZEN_UI_PLUGIN.config.reader_top_status_bar.hide_in_cbz = false
        ReaderView.paintTo(view, require("device").screen.bb, 0, 0)
        assert.is_not_nil(view._zen_header_dimen)
    end)

    it("refreshes autonomously without exposing a setting", function()
        _G.__ZEN_UI_PLUGIN.config.reader_top_status_bar.auto_refresh = false
        make_view()
        assert.are.equal(1, #scheduled)
    end)

    it("keeps one hook set and releases old reader views", function()
        local handlers = {
            onSuspend = ReaderUI.onSuspend,
            onResume = ReaderUI.onResume,
            onCharging = ReaderUI.onCharging,
            onNotCharging = ReaderUI.onNotCharging,
            onNetworkConnected = ReaderUI.onNetworkConnected,
            onNetworkDisconnected = ReaderUI.onNetworkDisconnected,
            onClose = ReaderUI.onClose,
        }
        local weak_first
        do
            local first = make_view()
            weak_first = setmetatable({ first }, { __mode = "v" })
        end
        local second = make_view()

        assert.are.equal(1, #scheduled)
        assert.are.equal(handlers.onSuspend, ReaderUI.onSuspend)
        assert.are.equal(handlers.onResume, ReaderUI.onResume)
        assert.are.equal(handlers.onCharging, ReaderUI.onCharging)
        assert.are.equal(handlers.onNotCharging, ReaderUI.onNotCharging)
        assert.are.equal(handlers.onNetworkConnected, ReaderUI.onNetworkConnected)
        assert.are.equal(handlers.onNetworkDisconnected, ReaderUI.onNetworkDisconnected)
        assert.are.equal(handlers.onClose, ReaderUI.onClose)

        scheduled[1].callback()
        assert.are.equal(2, #paint_rects)
        collectgarbage("collect")
        collectgarbage("collect")
        assert.is_nil(weak_first[1])

        local scheduled_before_resume = #scheduled
        ReaderUI.onResume(second.ui)
        local resume_timer_1 = scheduled[scheduled_before_resume + 1].callback
        local resume_timer_2 = scheduled[scheduled_before_resume + 2].callback
        ReaderUI.onCharging(second.ui)
        local charging_timer = scheduled[#scheduled].callback
        local auto_refresh = scheduled[1].callback

        unscheduled = {}
        assert.are.equal("closed", ReaderUI.onClose(second.ui, true))
        assert.is_true(unscheduled[auto_refresh])
        assert.is_true(unscheduled[resume_timer_1])
        assert.is_true(unscheduled[resume_timer_2])
        assert.is_true(unscheduled[charging_timer])
    end)

    it("paints footer-style progress and chapter ticks on the shared border", function()
        local view = make_view()
        _G.__ZEN_UI_PLUGIN.config.reader_top_status_bar.show_bottom_border = true
        _G.__ZEN_UI_PLUGIN.config.reader_top_status_bar.bottom_border_progress = true
        _G.__ZEN_UI_PLUGIN.config.reader_top_status_bar.show_chapter_marks = true
        view.footer = {
            ui = view.ui,
            pageno = 5,
            pages = 10,
            percent_finished = 0.5,
        }
        view.ui.document = {
            getPageCount = function() return 10 end,
            hasHiddenFlows = function() return false end,
        }
        view.ui.toc = { getTocTicksFlattened = function() return { 2, 8 } end }

        ReaderView.paintTo(view, require("device").screen.bb, 0, 0)

        assert.same({ x = 10, y = 20, w = 290, h = 1, color = "gray_5" }, paint_rects[2])
        assert.same({ x = 126, y = 20, w = 2, h = 1, color = "black" }, paint_rects[3])
        assert.same({ x = 474, y = 20, w = 2, h = 1, color = "black" }, paint_rects[4])
    end)

    it("refreshes only the dynamic item's slot and restores the dogear", function()
        make_view()

        scheduled[1].callback()
        assert.are.equal(2, #paint_rects)
        assert.same({ 250, 500 }, { paint_rects[1].x, paint_rects[2].x })

        reset_paint_log()
        ReaderUI.onNetworkConnected({})
        assert_single_slot(0)

        reset_paint_log()
        ReaderUI.onCharging({})
        assert.are.equal(0, #paint_rects)
        scheduled[#scheduled].callback()
        assert_single_slot(500)
    end)

    it("defers configured dynamic slot refreshes until after resume", function()
        _G.__ZEN_UI_PLUGIN.config.reader_top_status_bar.left_order = { "book_title" }
        _G.__ZEN_UI_PLUGIN.config.reader_top_status_bar.right_order = { "wifi", "battery" }
        make_view()

        ReaderUI.onResume({})

        assert.are.equal(0, #paint_rects)
        scheduled[2].callback()
        assert.are.equal(2, #paint_rects)
        assert.same({ 250, 500 }, { paint_rects[1].x, paint_rects[2].x })
        assert.are.equal(2, #dirty_calls)
        for _i, call in ipairs(dirty_calls) do
            assert.is_nil(call.widget)
            assert.is_true(call.dither)
            assert.is_true(call.region.w < 600)
        end
        local dogear_paints = 0
        for _i, step in ipairs(paint_order) do
            if step == "dogear" then dogear_paints = dogear_paints + 1 end
        end
        assert.are.equal(1, dogear_paints)
    end)

    it("uses the active reader theme background for a direct slot refresh", function()
        package.loaded["common/reader_themes"].getBackgroundColor = function() return "sepia" end
        _G.__ZEN_UI_PLUGIN.config.reader_top_status_bar.right_order = {}
        make_view()

        scheduled[1].callback()

        assert.are.equal("sepia", paint_rects[1].color)
        assert.is_nil(dirty_calls[1].widget)
        assert.is_true(dirty_calls[1].dither)
        assert.same({ "clear", "header", "dogear", "dirty" }, paint_order)
    end)
end)
