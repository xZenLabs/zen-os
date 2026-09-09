describe("opening banner", function()
    after_each(function()
        G_reader_settings:delSetting("file_ask_to_open")
    end)

    local function apply_patch()
        ZenSpec.unload("modules/reader/patches/opening_banner")
        require("modules/reader/patches/opening_banner")()
    end

    local function install_stubs(is_color)
        local next_tick
        local shown, closed, scheduled, refresh_hints = {}, {}, {}, {}
        local ReaderUI = {
            showReaderCoroutine = function() end,
            showReader = function(self, ...)
                return self:showReaderCoroutine(...)
            end,
        }
        local ReaderHighlight = {
            onTap = function()
                return "stock"
            end,
        }
        local ListMenuItem = {
            onTapSelect = function()
                return "selected"
            end,
        }
        local MosaicMenuItem = {
            onTapSelect = function()
                return "mosaic selected"
            end,
        }
        local ConfirmBox = {}
        function ConfirmBox:new(props)
            return setmetatable(props, { __index = self })
        end
        local function build_list_items()
            return ListMenuItem
        end
        local function build_mosaic_items()
            return MosaicMenuItem
        end
        local Widget = {}
        function Widget:extend(proto)
            return setmetatable(proto, { __index = self })
        end
        function Widget:new(props)
            return setmetatable(props, { __index = self })
        end
        local TextWidget = {}
        function TextWidget:new(props)
            function props:getSize() return { w = 40, h = 10 } end
            function props:paintTo() end
            function props:free() end
            return props
        end

        ZenSpec.replace("apps/reader/readerui", ReaderUI)
        ZenSpec.replace("apps/reader/modules/readerhighlight", ReaderHighlight)
        ZenSpec.replace("ui/uimanager", {
            show = function(_, widget)
                shown[#shown + 1] = widget
                if widget.onShow then widget:onShow() end
            end,
            close = function(_, widget)
                closed[#closed + 1] = widget
                if widget.onCloseWidget then widget:onCloseWidget() end
            end,
            setDirty = function(_, _, refreshtype, refreshregion)
                if type(refreshtype) == "function" then
                    refreshtype, refreshregion = refreshtype()
                end
                refresh_hints[#refresh_hints + 1] = {
                    refreshtype = refreshtype,
                    refreshregion = refreshregion,
                }
            end,
            nextTick = function(_, callback)
                next_tick = callback
            end,
            scheduleIn = function(_, seconds, callback)
                scheduled[#scheduled + 1] = {
                    seconds = seconds,
                    callback = callback,
                }
            end,
            unschedule = function(_, callback)
                for _i, task in ipairs(scheduled) do
                    if task.callback == callback then
                        task.cancelled = true
                        return true
                    end
                end
                return false
            end,
            forceRePaint = function() end,
        })
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
                scaleBySize = function(_, value) return value end,
                isColorScreen = function() return is_color == true end,
            },
            setIgnoreInput = function() end,
        })
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_BLACK = "black",
            COLOR_WHITE = "white",
        })
        ZenSpec.replace("ui/font", { getFace = function() return {} end })
        ZenSpec.replace("ui/geometry", { new = function(_, value) return value end })
        ZenSpec.replace("ui/widget/textwidget", TextWidget)
        ZenSpec.replace("ui/widget/widget", Widget)
        ZenSpec.replace("common/zen_logger", {
            new = function()
                return { info = function() end, warn = function() end, err = function() end, perf = function() end }
            end,
        })
        ZenSpec.replace("common/book_open_tap", {
            willOpen = function() return true end,
        })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("listmenu", { _updateItemsBuildUI = build_list_items })
        ZenSpec.replace("mosaicmenu", { _updateItemsBuildUI = build_mosaic_items })
        ZenSpec.replace("common/cover_utils", {
            BORDER_SIZE = 1,
            getRatio = function() return 2 / 3 end,
        })
        ZenSpec.replace("apps/filemanager/filemanager", { instance = {} })
        ZenSpec.replace("ui/widget/confirmbox", ConfirmBox)

        return ReaderUI, ReaderHighlight, shown, closed, function()
            assert.is_function(next_tick)
            next_tick()
        end, ListMenuItem, MosaicMenuItem, scheduled, ConfirmBox, refresh_hints
    end

    it("extends color-screen banners to the bottom edge", function()
        local ReaderUI, _, shown = install_stubs(true)
        apply_patch()

        ReaderUI.showReaderCoroutine({ doShowReader = function() end }, "book.epub", {})

        assert.are.same({ x = 0, y = 764, w = 600, h = 36 }, shown[1].dimen)
    end)

    it("shows a bottom fallback for each coverless open", function()
        local ReaderUI, _, shown, _, run_next_tick = install_stubs()
        ReaderUI.doShowReader = function() end
        apply_patch()

        ReaderUI:showReader("book.epub", {})
        run_next_tick()
        ReaderUI:showReader("book.epub", {})

        assert.are.equal(2, #shown)
        assert.are.same({ x = 0, y = 772, w = 600, h = 28 }, shown[2].dimen)
    end)

    it("defers no-banner opens while retaining a silent UI window", function()
        local ReaderUI, _, shown, closed, run_next_tick = install_stubs()
        local opens = 0
        local reader = {
            doShowReader = function()
                opens = opens + 1
            end,
        }
        apply_patch()

        ReaderUI.showReaderCoroutine(reader, "book.epub", {}, true)
        assert.are.equal(0, opens)
        assert.are.equal(1, #shown)
        assert.is_true(shown[1].invisible)

        run_next_tick()
        assert.same({ shown[1] }, closed)
        assert.are.equal(1, opens)
    end)

    it("uses a home-widget cover supplied by the opening-banner handoff", function()
        local ReaderUI, _, shown, _, run_next_tick = install_stubs()
        local opens = 0
        local reader = {
            doShowReader = function()
                opens = opens + 1
            end,
        }
        apply_patch()

        local set_cover = rawget(_G, "__ZEN_UI_SET_OPENING_BANNER_COVER")
        assert.is_function(set_cover)
        assert.is_true(set_cover({
            dimen = { x = 31, y = 47, w = 220, h = 330 },
            bordersize = 2,
        }))
        assert.are.same({ x = 33, y = 347, w = 216, h = 28 }, shown[1].dimen)

        ReaderUI.showReaderCoroutine(reader, "book.epub", {})
        assert.are.equal(1, #shown)

        run_next_tick()
        assert.is_true(set_cover({
            dimen = { x = 52, y = 80, w = 180, h = 270 },
            bordersize = 2,
        }))
        assert.are.same({ x = 54, y = 320, w = 176, h = 28 }, shown[2].dimen)
        ReaderUI.showReaderCoroutine(reader, "book.epub", {})
        assert.are.equal(2, #shown)

        run_next_tick()
        assert.are.equal(2, opens)
    end)

    it("keeps the immediate banner on confirm and closes it on cancel", function()
        local ReaderUI, _, shown, closed, run_next_tick, _, _, scheduled, ConfirmBox,
            refresh_hints = install_stubs()
        local opens = 0
        local reader = {
            doShowReader = function()
                opens = opens + 1
            end,
        }
        G_reader_settings:saveSetting("file_ask_to_open", true)
        apply_patch()

        local set_cover = rawget(_G, "__ZEN_UI_SET_OPENING_BANNER_COVER")
        assert.is_true(set_cover({ dimen = { x = 31, y = 47, w = 220, h = 330 } }))
        assert.are.equal(1, #shown)

        local cancelled_prompt = ConfirmBox:new{
            text = "Open this file?\n\nbook.epub",
            ok_text = "Open",
            ok_callback = function() end,
        }
        assert.is_function(cancelled_prompt.cancel_callback)
        cancelled_prompt.cancel_callback()
        assert.same({ shown[1] }, closed)
        assert.is_true(scheduled[1].cancelled)
        assert.are.equal("ui", refresh_hints[1].refreshtype)
        assert.are.equal(shown[1].dimen, refresh_hints[1].refreshregion)

        assert.is_true(set_cover({ dimen = { x = 31, y = 47, w = 220, h = 330 } }))
        local confirmed_prompt = ConfirmBox:new{
            text = "Open this file?\n\nbook.epub",
            ok_text = "Open",
            ok_callback = function()
                ReaderUI.showReaderCoroutine(reader, "book.epub", {})
            end,
        }
        confirmed_prompt.ok_callback()
        assert.are.equal(2, #shown)
        assert.are.equal(1, #closed)

        run_next_tick()
        assert.are.equal(1, opens)
    end)

    it("keeps only a dark cover banner's top border white", function()
        local _, _, shown = install_stubs()
        apply_patch()

        local set_cover = rawget(_G, "__ZEN_UI_SET_OPENING_BANNER_COVER")
        assert.is_true(set_cover({
            dimen = { x = 31, y = 47, w = 220, h = 330 },
            bordersize = 2,
        }))
        shown[1].round_bottom_corners = false

        local painted = {}
        shown[1]:paintTo({
            paintRect = function(_, x, y, w, h, color)
                painted[#painted + 1] = { x = x, y = y, w = w, h = h, color = color }
            end,
        }, shown[1].dimen.x, shown[1].dimen.y)

        assert.are.same({
            { x = 33, y = 347, w = 216, h = 28, color = "black" },
            { x = 33, y = 374, w = 216, h = 1, color = "black" },
            { x = 33, y = 347, w = 1, h = 28, color = "black" },
            { x = 248, y = 347, w = 1, h = 28, color = "black" },
            { x = 33, y = 347, w = 216, h = 2, color = "white" },
        }, painted)
    end)

    it("does not recreate a banner after its cover is released", function()
        local ReaderUI, _, shown, closed, run_next_tick = install_stubs()
        local opens = 0
        local reader = {
            doShowReader = function()
                opens = opens + 1
            end,
        }
        apply_patch()

        local set_cover = rawget(_G, "__ZEN_UI_SET_OPENING_BANNER_COVER")
        local cancel_banner = rawget(_G, "__ZEN_UI_CANCEL_OPENING_BANNER")
        assert.is_true(set_cover({ dimen = { x = 31, y = 47, w = 220, h = 330 } }))
        assert.are.equal(1, #shown)

        cancel_banner(true)
        assert.same({ shown[1] }, closed)

        ReaderUI.showReaderCoroutine(reader, "book.epub", {})
        assert.are.equal(2, #shown)
        assert.is_true(shown[2].invisible)

        run_next_tick()
        assert.are.equal(1, opens)
    end)

    it("closes a stale banner after its timeout", function()
        local ReaderUI, _, shown, closed, run_next_tick, _, _, scheduled = install_stubs()
        local reader = { doShowReader = function() end }
        apply_patch()

        local set_cover = rawget(_G, "__ZEN_UI_SET_OPENING_BANNER_COVER")
        assert.is_true(set_cover({ dimen = { x = 31, y = 47, w = 220, h = 330 } }))
        assert.are.equal(1, #shown)
        assert.are.equal(10, scheduled[1].seconds)

        scheduled[1].callback()
        assert.same({ shown[1] }, closed)

        ReaderUI.showReaderCoroutine(reader, "book.epub", {})
        assert.are.equal(2, #shown)
        run_next_tick()
        assert.is_true(scheduled[2].cancelled)
    end)

    it("prepares list banners only for actual books", function()
        local _, _, shown, _, _, ListMenuItem, MosaicMenuItem = install_stubs()
        apply_patch()

        local dimen = { x = 10, y = 20, w = 300, h = 60 }
        assert.are.equal("mosaic selected", MosaicMenuItem.onTapSelect({
            entry = { path = "/book.epub", is_file = true },
            filepath = "/book.epub",
            dimen = dimen,
            menu = { ui = { selected_files = {} } },
        }))
        assert.are.equal("selected", ListMenuItem.onTapSelect({
            entry = { path = "/book.epub", is_file = true },
            filepath = "/book.epub",
            dimen = dimen,
            menu = { ui = { selected_files = {} } },
        }))
        assert.are.equal(0, #shown)

        package.loaded["apps/filemanager/filemanager"].instance.selected_files = {}
        assert.are.equal("selected", ListMenuItem.onTapSelect({
            entry = { path = "/book.epub", is_file = true },
            filepath = "/book.epub",
            dimen = dimen,
            menu = {},
        }))
        assert.are.equal(0, #shown)
        package.loaded["apps/filemanager/filemanager"].instance.selected_files = nil

        assert.are.equal("selected", ListMenuItem.onTapSelect({
            entry = { text = "Author", _zen_files = { "/book.epub" } },
            dimen = dimen,
        }))
        assert.are.equal("selected", ListMenuItem.onTapSelect({
            entry = { path = "/books", attr = { mode = "directory" } },
            filepath = "/books",
            is_directory = true,
            dimen = dimen,
        }))
        assert.are.equal(0, #shown)

        assert.are.equal("selected", ListMenuItem.onTapSelect({
            entry = { path = "/book.epub", is_file = true },
            filepath = "/book.epub",
            dimen = dimen,
        }))
        assert.are.equal(1, #shown)
    end)

    it("ignores file and directory chooser taps", function()
        local ReaderUI, _, shown, _, _, ListMenuItem, MosaicMenuItem = install_stubs()
        apply_patch()

        local item = {
            entry = { path = "/book.epub", is_file = true },
            filepath = "/book.epub",
            dimen = { x = 10, y = 20, w = 300, h = 60 },
        }
        item.menu = { select_file = true, select_directory = false }
        assert.are.equal("selected", ListMenuItem.onTapSelect(item))

        item.menu = { select_file = false, select_directory = true }
        item._zen_cover_dimen = item.dimen
        assert.are.equal("mosaic selected", MosaicMenuItem.onTapSelect(item))
        assert.are.equal(0, #shown)

        ReaderUI.showReaderCoroutine({ doShowReader = function() end }, "book.epub", {})
        assert.are.equal(1, #shown)
    end)

    it("does not prepare a list banner until the opening tap is accepted", function()
        local _, _, shown, _, _, ListMenuItem = install_stubs()
        local accepted = false
        ZenSpec.replace("common/book_open_tap", {
            willOpen = function() return accepted end,
        })
        apply_patch()

        local item = {
            entry = { path = "/book.epub", is_file = true },
            filepath = "/book.epub",
            dimen = { x = 10, y = 20, w = 300, h = 60 },
        }
        assert.are.equal("selected", ListMenuItem.onTapSelect(item, nil, { time = 1 }))
        assert.are.equal(0, #shown)

        accepted = true
        assert.are.equal("selected", ListMenuItem.onTapSelect(item, nil, { time = 1.2 }))
        assert.are.equal(1, #shown)
    end)

    it("ignores an early tap before visible highlight boxes exist", function()
        local _, ReaderHighlight = install_stubs()
        local stock_calls = 0
        ReaderHighlight.onTap = function()
            stock_calls = stock_calls + 1
            return "stock"
        end
        apply_patch()

        local highlight = {
            view = { highlight = { visible_boxes = nil } },
        }
        assert.is_nil(ReaderHighlight.onTap(highlight, nil, { pos = {} }))
        assert.are.equal(0, stock_calls)

        highlight.view.highlight.visible_boxes = {}
        assert.are.equal("stock", ReaderHighlight.onTap(highlight, nil, { pos = {} }))
        assert.are.equal(1, stock_calls)

        highlight.hold_pos = {}
        highlight.view.highlight.visible_boxes = nil
        assert.are.equal("stock", ReaderHighlight.onTap(highlight, nil, { pos = {} }))
        assert.are.equal(2, stock_calls)
    end)
end)
