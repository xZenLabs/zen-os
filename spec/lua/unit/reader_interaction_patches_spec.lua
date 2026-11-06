describe("reader interaction patches", function()
    local function apply_patch(name)
        ZenSpec.unload(name)
        require(name)()
    end

    -- status_on_open defers index and sidecar work to the next tick.
    local function apply_status_on_open()
        local ticks = {}
        ZenSpec.replace("ui/uimanager", { nextTick = function(_, fn, ...)
            local args = { n = select("#", ...), ... }
            ticks[#ticks + 1] = function() fn(unpack(args, 1, args.n)) end
        end })
        apply_patch("modules/reader/patches/status_on_open")
        return function()
            for _i, tick in ipairs(ticks) do tick() end
            ticks = {}
        end
    end

    local function install_bookmark_button_stub()
        ZenSpec.replace("common/utils", {
            resolveLocalIcon = function(_dir, name) return "/icons/" .. name .. ".svg" end,
        })
        ZenSpec.replace("common/ui/zen_icon_button", {
            new = function(_self, spec)
                spec.image = { dimen = { x = 12, y = 14, w = 24, h = 24 } }
                spec.paintTo = function() end
                spec.free = function() end
                spec.init = function() end
                return spec
            end,
        })
        ZenSpec.replace("ui/uimanager", { setDirty = function() end })
    end

    before_each(function()
        _G.__ZEN_UI_PLUGIN = nil
        ZenSpec.replace("modules/filebrowser/patches/library_font", {
            withMenuFaces = function(callback) return callback() end,
        })
        ZenSpec.unload("common/reader_font")
    end)

    after_each(function()
        _G.__ZEN_UI_PLUGIN = nil
        ZenSpec.unload("modules/filebrowser/patches/library_font")
        ZenSpec.unload("common/reader_font")
    end)

    it("swallows holds in page margins and delegates content holds", function()
        local delegated = 0
        local ReaderHighlight = {
            onHold = function()
                delegated = delegated + 1
                return "stock"
            end,
        }
        ZenSpec.replace("apps/reader/modules/readerhighlight", ReaderHighlight)
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
            },
        })
        apply_patch("modules/reader/patches/margin_hold_guard")

        local highlight = {
            ui = {
                document = { getPageMargins = function()
                    return { left = 30, right = 40, top = 50, bottom = 60 }
                end },
            },
            view = { view_mode = "page" },
        }
        assert.is_false(ReaderHighlight.onHold(highlight, nil, { pos = { x = 10, y = 400 } }))
        assert.is_false(ReaderHighlight.onHold(highlight, nil, { pos = { x = 300, y = 20 } }))
        assert.are.equal("stock",
            ReaderHighlight.onHold(highlight, nil, { pos = { x = 300, y = 400 } }))
        assert.are.equal(1, delegated)
    end)

    it("does not guard vertical margins in scroll mode or any margins for paging docs", function()
        local delegated = 0
        local ReaderHighlight = {
            onHold = function()
                delegated = delegated + 1
                return "stock"
            end,
        }
        ZenSpec.replace("apps/reader/modules/readerhighlight", ReaderHighlight)
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
            },
        })
        apply_patch("modules/reader/patches/margin_hold_guard")

        local highlight = {
            ui = {
                document = { getPageMargins = function()
                    return { left = 30, right = 40, top = 50, bottom = 60 }
                end },
            },
            view = { view_mode = "scroll" },
        }
        assert.are.equal("stock",
            ReaderHighlight.onHold(highlight, nil, { pos = { x = 300, y = 10 } }))
        highlight.ui.paging = {}
        assert.are.equal("stock",
            ReaderHighlight.onHold(highlight, nil, { pos = { x = 10, y = 10 } }))
        assert.are.equal(2, delegated)
    end)

    it("acknowledges a new book version after stock reader setup and flushes changes", function()
        local order = {}
        local ReaderUI = {
            onReaderReady = function() order[#order + 1] = "stock" end,
        }
        ZenSpec.replace("apps/reader/readerui", ReaderUI)
        ZenSpec.replace("common/book_status", {
            acknowledgeNewVersion = function(settings)
                order[#order + 1] = "acknowledge"
                return settings.changed
            end,
        })
        local run_ticks = apply_status_on_open()

        local ui = {
            document = {},
            doc_settings = {
                changed = true,
                flush = function() order[#order + 1] = "flush" end,
            },
        }
        ReaderUI.onReaderReady(ui)
        assert.same({ "stock" }, order)
        run_ticks()
        assert.same({ "stock", "acknowledge", "flush" }, order)

        -- A reader closed before the tick already flushed on close.
        order = {}
        ReaderUI.onReaderReady(ui)
        ui.document = nil
        run_ticks()
        assert.same({ "stock" }, order)
    end)

    it("does not flush status when acknowledgement makes no change", function()
        local flushes = 0
        local ReaderUI = { onReaderReady = function() end }
        ZenSpec.replace("apps/reader/readerui", ReaderUI)
        ZenSpec.replace("common/book_status", {
            acknowledgeNewVersion = function() return false end,
        })
        local run_ticks = apply_status_on_open()

        ReaderUI.onReaderReady({ document = {}, doc_settings = { flush = function() flushes = flushes + 1 end } })
        run_ticks()
        assert.are.equal(0, flushes)
    end)

    it("applies deferred Quickstart Reader defaults to the next opened book", function()
        local apply_calls = 0
        local saves = 0
        local plugin = {
            config = {
                _meta = { reader_defaults_apply_on_next_open = true },
            },
            saveConfig = function() saves = saves + 1 end,
        }
        _G.__ZEN_UI_PLUGIN = plugin
        local ReaderUI = { onReaderReady = function() end }
        ZenSpec.replace("apps/reader/readerui", ReaderUI)
        ZenSpec.replace("common/book_status", {
            acknowledgeNewVersion = function() return false end,
        })
        local ui = { doc_settings = {} }
        ZenSpec.replace("common/reader_defaults", {
            applyDeferredToReader = function(reader)
                assert.are.equal(ui, reader)
                apply_calls = apply_calls + 1
                return true
            end,
        })
        apply_status_on_open()

        ReaderUI.onReaderReady(ui)

        assert.are.equal(1, apply_calls)
        assert.is_false(plugin.config._meta.reader_defaults_apply_on_next_open)
        assert.are.equal(1, saves)
    end)

    it("preserves a top status bar disabled after Quickstart was deferred", function()
        local saves = 0
        local plugin = {
            config = {
                _meta = { reader_defaults_apply_on_next_open = true },
                features = { reader_top_status_bar = false },
            },
            saveConfig = function() saves = saves + 1 end,
        }
        _G.__ZEN_UI_PLUGIN = plugin
        local ReaderUI = { onReaderReady = function() end }
        ZenSpec.replace("apps/reader/readerui", ReaderUI)
        ZenSpec.replace("common/book_status", {
            acknowledgeNewVersion = function() return false end,
        })
        ZenSpec.replace("common/reader_defaults", {
            applyDeferredToReader = function() return true end,
        })
        apply_status_on_open()

        ReaderUI.onReaderReady({ doc_settings = {} })

        assert.is_false(plugin.config.features.reader_top_status_bar)
        assert.is_false(plugin.config._meta.reader_defaults_apply_on_next_open)
        assert.are.equal(1, saves)
    end)

    it("resets saved book margins once only while a Zen reader preset is active", function()
        local saved_defaults = package.loaded["common/reader_defaults"]
        local saved_presets = package.loaded["config/preset_store"]
        local saved_device = package.loaded["device"]
        ZenSpec.replace("device", { hasColorScreen = function() return false end })
        ZenSpec.unload("common/reader_defaults")
        local preset_name = "(ZenOS) Chapter Time + %"
        ZenSpec.replace("config/preset_store", { getActivePreset = function() return preset_name end })
        local ReaderUI = { onReaderReady = function() end }
        ZenSpec.replace("apps/reader/readerui", ReaderUI)
        ZenSpec.replace("common/book_status", { acknowledgeNewVersion = function() return false end })
        apply_status_on_open()

        local calls, saves = {}, 0
        local ui = {
            rolling = {},
            document = { configurable = { t_page_margin = 30, b_page_margin = 30, font_size = 23 } },
            doc_settings = ZenSpec.memorySettings({ copt_t_page_margin = 30, copt_b_page_margin = 30 }),
            typeset = { onSetPageTopAndBottomMargin = function(_self, margins)
                calls[#calls + 1] = margins
            end },
            saveSettings = function() saves = saves + 1 end,
        }
        ReaderUI.onReaderReady(ui)
        assert.same({ { 15, 15 } }, calls)
        assert.are.equal(15, ui.document.configurable.t_page_margin)
        assert.are.equal(15, ui.document.configurable.b_page_margin)
        assert.are.equal(23, ui.document.configurable.font_size)
        assert.is_true(ui.doc_settings:isTrue("zen_vertical_margins_migrated"))

        ui.document.configurable.t_page_margin = 22
        ReaderUI.onReaderReady(ui)
        assert.are.equal(22, ui.document.configurable.t_page_margin)
        assert.are.equal(1, saves)

        for _i, name in ipairs({ "", "My preset", "(ZenOS) Custom preset" }) do
            preset_name = name ~= "" and name or nil
            ui.doc_settings = ZenSpec.memorySettings({ copt_t_page_margin = 30, copt_b_page_margin = 30 })
            ReaderUI.onReaderReady(ui)
            assert.are.equal(22, ui.document.configurable.t_page_margin)
            assert.are.equal(1, saves)
            assert.is_false(ui.doc_settings:isTrue("zen_vertical_margins_migrated"))
        end
        preset_name = "(ZenOS) Pages and %"
        ui.doc_settings = ZenSpec.memorySettings()
        ReaderUI.onReaderReady(ui)
        assert.are.equal(1, saves)
        ui.doc_settings = ZenSpec.memorySettings({ copt_t_page_margin = 30 })
        ui.rolling = nil
        ReaderUI.onReaderReady(ui)
        assert.are.equal(1, saves)

        package.loaded["common/reader_defaults"] = saved_defaults
        package.loaded["config/preset_store"] = saved_presets
        package.loaded["device"] = saved_device
    end)

    it("starts explicit TBR books as reading and removes them from the collection", function()
        local saved, cached, invalidated, removed = {}, {}, {}, 0
        local ReaderUI = { onReaderReady = function() end }
        ZenSpec.replace("apps/reader/readerui", ReaderUI)
        ZenSpec.replace("common/book_status", {
            acknowledgeNewVersion = function() return false end,
            invalidate = function(file) invalidated[#invalidated + 1] = file end,
        })
        ZenSpec.replace("common/tbr_index", {
            isExplicit = function() return true end,
            setExplicit = function(_, enabled)
                if not enabled then removed = removed + 1 end
                return true
            end,
            refreshPath = function() end,
        })
        ZenSpec.replace("apps/filemanager/filemanagerutil", {
            saveSummary = function(_, summary) saved[#saved + 1] = summary.status end,
        })
        ZenSpec.replace("ui/widget/booklist", {
            setBookInfoCacheProperty = function(file, key, value)
                cached[#cached + 1] = { file, key, value }
            end,
        })
        local run_ticks = apply_status_on_open()

        local summary = { status = "complete" }
        local flushes = 0
        ReaderUI.onReaderReady({
            document = {},
            doc_settings = {
                data = { doc_path = "/books/tbr.epub" },
                readSetting = function(_, key) return key == "summary" and summary or nil end,
                flush = function() flushes = flushes + 1 end,
            },
        })
        assert.are.equal(0, removed)
        assert.are.equal(0, flushes)
        run_ticks()

        assert.are.equal(1, removed)
        assert.same({ "reading" }, saved)
        assert.same({ { "/books/tbr.epub", "status", "reading" } }, cached)
        assert.same({ "/books/tbr.epub" }, invalidated)
        assert.are.equal("reading", summary.status)
        assert.are.equal(1, flushes)
    end)

    it("starts on-hold books as reading", function()
        local saved, cached, invalidated = {}, {}, {}
        local ReaderUI = { onReaderReady = function() end }
        ZenSpec.replace("apps/reader/readerui", ReaderUI)
        ZenSpec.replace("common/book_status", {
            acknowledgeNewVersion = function() return false end,
            invalidate = function(file) invalidated[#invalidated + 1] = file end,
        })
        ZenSpec.replace("common/tbr_index", {
            isExplicit = function() return false end,
            refreshPath = function() end,
        })
        ZenSpec.replace("apps/filemanager/filemanagerutil", {
            saveSummary = function(_, summary) saved[#saved + 1] = summary.status end,
        })
        ZenSpec.replace("ui/widget/booklist", {
            setBookInfoCacheProperty = function(file, key, value)
                cached[#cached + 1] = { file, key, value }
            end,
        })
        apply_status_on_open()

        local summary = { status = "abandoned" }
        ReaderUI.onReaderReady({
            doc_settings = {
                data = { doc_path = "/books/on-hold.epub" },
                readSetting = function(_, key) return key == "summary" and summary or nil end,
                flush = function() end,
            },
        })

        assert.same({ "reading" }, saved)
        assert.same({ { "/books/on-hold.epub", "status", "reading" } }, cached)
        assert.same({ "/books/on-hold.epub" }, invalidated)
        assert.are.equal("reading", summary.status)
    end)

    it("routes Home through library navigation only while a document is open", function()
        local stock_calls, routed = 0, 0
        local ReaderUI = {
            onHome = function(_, value)
                stock_calls = stock_calls + 1
                return value
            end,
        }
        local plugin = { marker = "plugin" }
        _G.__ZEN_UI_PLUGIN = plugin
        ZenSpec.replace("apps/reader/readerui", ReaderUI)
        ZenSpec.replace("common/library_navigation", {
            showFromReader = function(ui, received_plugin)
                routed = routed + 1
                assert.are.equal(plugin, received_plugin)
                assert.is_truthy(ui.document)
                return "library"
            end,
        })
        apply_patch("modules/reader/patches/library_navigation")

        assert.are.equal("library", ReaderUI.onHome({ document = {} }))
        assert.are.equal("stock", ReaderUI.onHome({}, "stock"))
        assert.are.equal(1, routed)
        assert.are.equal(1, stock_calls)
    end)

    it("updates bookmark styling and adds right-side header actions", function()
        local stock_calls, update_calls = 0, 0
        local font_calls = {}
        local close_order = {}
        install_bookmark_button_stub()
        ZenSpec.replace("ui/font", {
            getFace = function(_, name, size, index)
                table.insert(font_calls, { name = name, size = size, index = index })
                return { name = name, size = size, index = index }
            end,
        })
        ZenSpec.replace("document/credocument", {})
        ZenSpec.replace("modules/filebrowser/patches/library_font", {
            withMenuFaces = function(callback, menu_faces)
                local Font = require("ui/font")
                local get_face = Font.getFace
                Font.getFace = function(font, name, size, index)
                    if menu_faces[name] then name = "LibraryFont" end
                    return get_face(font, name, size, index)
                end
                local ok, result = pcall(callback)
                Font.getFace = get_face
                if not ok then error(result, 0) end
                return result
            end,
        })
        local ReaderBookmark = {
            onShowBookmark = function() stock_calls = stock_calls + 1 end,
        }
        ZenSpec.replace("apps/reader/modules/readerbookmark", ReaderBookmark)
        _G.__ZEN_UI_PLUGIN = {
            config = { page_browser = { bookmarks_font_size = 19 } },
        }
        apply_patch("modules/reader/patches/bookmarks")

        local left_tap = function() return "left" end
        local left_hold = function() return "hold" end
        local right_tap = function() close_order[#close_order + 1] = "bookmarks" end
        local left, right = {
            callback = left_tap,
            hold_callback = left_hold,
            setIcon = function(self, icon) self.icon = icon end,
        }, {
            width = 32,
            callback = right_tap,
            setIcon = function(self, icon) self.icon = icon end,
        }
        local menu = {
            font_size = 20,
            item_table = { { mandatory_dim = true }, { mandatory_dim = true } },
            item_group = {
                setmetatable({}, { font = "MenuBody", infont = "MenuInfo" }),
            },
            updateItems = function(self)
                update_calls = update_calls + 1
                local Font = require("ui/font")
                Font:getFace("MenuBody", self.font_size)
                Font:getFace("MenuInfo", self.items_mandatory_font_size)
            end,
            onCloseAllMenus = function()
                close_order[#close_order + 1] = "bookmarks"
            end,
            title_bar = {
                left, right,
                width = 600,
                button_padding = 5,
                left_button = left,
                right_button = right,
            },
        }
        local bookmark = {
            bookmark_menu = { menu },
            ui = {
                font = { font_face = "ReaderFont" },
                document = { configurable = { font_size = 23 } },
            },
        }
        menu._zen_page_browser_parent = {}
        ReaderBookmark.onShowBookmark(bookmark)

        assert.are.equal(1, stock_calls)
        assert.are.equal(19, menu.items_font_size)
        assert.are.equal(19, menu.font_size)
        assert.are.equal(19, menu.items_mandatory_font_size)
        assert.is_nil(menu.item_table[1].mandatory_dim)
        assert.is_nil(menu.item_table[2].mandatory_dim)
        assert.are.equal(1, update_calls)
        assert.same({ name = "LibraryFont", size = 19, index = nil }, font_calls[1])
        assert.same({ name = "LibraryFont", size = 19, index = nil }, font_calls[2])
        local back_button = menu.title_bar.left_button
        assert.are.equal("/icons/chevron.left.svg", back_button.file)
        assert.are.equal(right_tap, back_button.callback)
        assert.is_nil(back_button.hold_callback)
        local menu_button = menu.title_bar.menu_button
        local close_button = menu.title_bar.right_button
        for _i, button in ipairs({ back_button, menu_button, close_button }) do
            assert.is_true(button.allow_flash)
        end
        assert.are.equal("/icons/appbar.menu.svg", menu_button.file)
        assert.are.equal(left_tap, menu_button.callback)
        assert.are.equal(left_hold, menu_button.hold_callback)
        assert.are.same({ 516, 0 }, menu_button.overlap_offset)
        assert.are.equal("/icons/close_light.svg", close_button.file)
        assert.are.equal("right", close_button.overlap_align)

        menu:setTitleBarLeftIcon("check")
        assert.are.equal("/icons/check.svg", menu_button.file)

        menu._zen_page_browser_parent = {
            onClose = function() close_order[#close_order + 1] = "page_browser" end,
        }
        close_button.callback()
        assert.same({ "bookmarks", "page_browser" }, close_order)
        assert.is_nil(menu._zen_page_browser_parent)

        menu.item_table[1].mandatory_dim = true
        menu:updateItems()
        assert.is_nil(menu.item_table[1].mandatory_dim)
        assert.are.equal(2, update_calls)
    end)

    it("closes a page browser parent before jumping to a bookmark", function()
        local parent_closes, goto_calls = 0, 0
        local ReaderBookmark = {
            onShowBookmark = function() end,
            gotoBookmark = function(_, page, pos0)
                goto_calls = goto_calls + 1
                assert.are.equal(42, page)
                assert.are.equal("xp", pos0)
            end,
        }
        ZenSpec.replace("apps/reader/modules/readerbookmark", ReaderBookmark)
        apply_patch("modules/reader/patches/bookmarks")

        local menu = {
            _zen_page_browser_parent = {
                onClose = function() parent_closes = parent_closes + 1 end,
            },
        }
        ReaderBookmark.gotoBookmark({ bookmark_menu = { menu } }, 42, "xp")

        assert.are.equal(1, parent_closes)
        assert.are.equal(1, goto_calls)
        assert.is_nil(menu._zen_page_browser_parent)
    end)

    it("focuses bookmark header actions and routes hardware arrows to the list", function()
        local focus_moves, press_calls = 0, 0
        local focus_rect
        install_bookmark_button_stub()
        local left, right = {
            callback = function() end,
            setIcon = function(self, icon) self.icon = icon end,
            image = { dimen = { x = 12, y = 14, w = 24, h = 24 } },
            dimen = { w = 60, h = 60 },
            paintTo = function() end,
            handleEvent = function(self, event)
                if event.name == "Focus" then return self:onFocus() end
                if event.name == "Unfocus" then return self:onUnfocus() end
            end,
        }, {
            callback = function() end,
            setIcon = function(self, icon) self.icon = icon end,
            handleEvent = function(self, event)
                if event.name == "Focus" then return self:onFocus() end
                if event.name == "Unfocus" then return self:onUnfocus() end
            end,
        }
        local title_bar = {
            width = 600,
            button_padding = 5,
            left_button = left,
            right_button = right,
            generateHorizontalLayout = function(self)
                return { { self.left_button, self.right_button } }
            end,
        }
        local first_item = { handleEvent = function() end }
        local second_item = { handleEvent = function() end }
        local menu = {
            font_size = 20,
            item_table = { {}, {} },
            key_events = { Close = { { "Back" }, event = "Close" } },
            selected = { x = 1, y = 1 },
            title_bar = title_bar,
            show_parent = {},
            updateItems = function(self)
                self.layout = { { first_item }, { second_item } }
                self.selected = { x = 1, y = 1 }
                self:mergeTitleBarIntoLayout()
            end,
            onFocusMove = function(self, args)
                focus_moves = focus_moves + 1
                if args[2] > 0 then self.selected = { x = 1, y = 2 } end
                return true
            end,
            onPress = function()
                press_calls = press_calls + 1
                return true
            end,
        }
        local ReaderBookmark = {
            onShowBookmark = function(self)
                self.bookmark_menu = { menu }
            end,
        }
        ZenSpec.replace("device", {
            screen = { scaleBySize = function(_self, value) return value end },
            hasDPad = function() return true end,
            hasKeyboard = function() return false end,
        })
        ZenSpec.replace("ui/event", {
            new = function(_self, name) return { name = name } end,
        })
        ZenSpec.replace("ui/uimanager", { setDirty = function() end })
        ZenSpec.replace("apps/reader/modules/readerbookmark", ReaderBookmark)
        apply_patch("modules/reader/patches/bookmarks")

        ReaderBookmark.onShowBookmark({})
        assert.is_nil(title_bar.left_button)
        assert.is_false(title_bar.has_left_icon)
        assert.are.equal(2, #menu.layout[1])
        assert.are.equal(title_bar.menu_button, menu.layout[1][1])
        assert.are.equal(title_bar.right_button, menu.layout[1][2])
        assert.are.same({ x = 2, y = 1 }, menu.selected)
        assert.is_true(title_bar.right_button._zen_keyboard_focused)
        assert.are.equal("Close", menu.key_events.Close.event)
        title_bar.right_button:paintTo({
            invertRect = function(_bb, x, y, w, h)
                focus_rect = { x = x, y = y, w = w, h = h }
            end,
        }, 0, 0)
        assert.are.same({ x = 9, y = 11, w = 30, h = 30 }, focus_rect)

        local function key(name)
            return {
                match = function(_self, sequence) return sequence[1] == name end,
            }
        end
        assert.is_true(menu:onKeyPress(key("Down")))
        assert.are.equal(1, focus_moves)
        assert.are.same({ x = 1, y = 2 }, menu.selected)
        assert.is_true(menu:onKeyPress(key("Return")))
        assert.are.equal(1, press_calls)
    end)
end)
