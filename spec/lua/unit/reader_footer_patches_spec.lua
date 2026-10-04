describe("reader footer patches", function()
    local saved_modules

    local function apply_patch(name)
        ZenSpec.unload(name)
        require(name)()
    end

    before_each(function()
        saved_modules = nil
        _G.__ZEN_UI_PLUGIN = nil
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ffi/util", {
            template = function(text, ...)
                local values = { ... }
                return (text:gsub("%%(%d+)", function(index)
                    return tostring(values[tonumber(index)])
                end))
            end,
        })
    end)

    after_each(function()
        _G.__ZEN_UI_PLUGIN = nil
        if saved_modules then
            ZenSpec.unload("modules/reader/patches/reader_footer")
            for name, module in pairs(saved_modules) do
                package.loaded[name] = module or nil
            end
        end
    end)

    it("formats chapter time for sub-minute, singular, and plural durations", function()
        local ReaderFooter = {
            textGeneratorMap = {
                chapter_time_to_read = function() return "stock" end,
                dynamic_filler = function() return "          ", true end,
            },
            genAllFooterText = function() return "all" end,
        }
        ZenSpec.replace("apps/reader/modules/readerfooter", ReaderFooter)
        _G.__ZEN_UI_PLUGIN = {
            config = { reader_footer = { chapter_time_format = "full" } },
        }
        apply_patch("modules/reader/patches/reader_footer_time_format")

        local footer = {
            pageno = 10,
            ui = {
                statistics = { settings = { is_enabled = true }, avg_time = 30 },
                toc = { getChapterPagesLeft = function() return 1 end },
                document = { getTotalPagesLeft = function() return 99 end },
            },
        }
        local nbsp = "\u{00A0}"
        local hair = "\u{200A}"
        assert.are.equal(hair .. "<" .. nbsp .. "1" .. nbsp .. "min" .. nbsp
            .. "left" .. nbsp .. "in" .. nbsp .. "chapter",
            ReaderFooter.textGeneratorMap.chapter_time_to_read(footer))

        footer.ui.statistics.avg_time = 60
        assert.are.equal(hair .. "1" .. nbsp .. "min" .. nbsp .. "left" .. nbsp
            .. "in" .. nbsp .. "chapter",
            ReaderFooter.textGeneratorMap.chapter_time_to_read(footer))

        footer.ui.toc.getChapterPagesLeft = function() return 4 end
        assert.are.equal(hair .. "4" .. nbsp .. "min" .. nbsp .. "left" .. nbsp
            .. "in" .. nbsp .. "chapter",
            ReaderFooter.textGeneratorMap.chapter_time_to_read(footer))

        footer.ui.statistics._zenPagesInStatisticsUnits = function(_stats, pages)
            return pages / 2
        end
        assert.are.equal(hair .. "2" .. nbsp .. "min" .. nbsp .. "left" .. nbsp
            .. "in" .. nbsp .. "chapter",
            ReaderFooter.textGeneratorMap.chapter_time_to_read(footer))
    end)

    it("formats compact and abbreviated chapter times", function()
        local ReaderFooter = {
            textGeneratorMap = {
                chapter_time_to_read = function() return "stock" end,
                dynamic_filler = function() return "          ", false end,
            },
            genAllFooterText = function() return "all" end,
        }
        ZenSpec.replace("apps/reader/modules/readerfooter", ReaderFooter)
        _G.__ZEN_UI_PLUGIN = {
            config = { reader_footer = { chapter_time_format = "compact" } },
        }
        apply_patch("modules/reader/patches/reader_footer_time_format")

        local footer = {
            pageno = 10,
            ui = {
                statistics = { settings = { is_enabled = true }, avg_time = 60 },
                toc = { getChapterPagesLeft = function() return 4 end },
                document = { getTotalPagesLeft = function() return 99 end },
            },
        }
        local nbsp = "\u{00A0}"
        local hair = "\u{200A}"
        assert.are.equal(hair .. "4" .. nbsp .. "min" .. nbsp .. "left",
            ReaderFooter.textGeneratorMap.chapter_time_to_read(footer))

        _G.__ZEN_UI_PLUGIN.config.reader_footer.chapter_time_format = "number"
        assert.are.equal(hair .. "4m", ReaderFooter.textGeneratorMap.chapter_time_to_read(footer))
        local text, merge = ReaderFooter.textGeneratorMap.dynamic_filler(footer)
        assert.are.equal("          ", text)
        assert.is_false(merge)

        footer.ui.statistics.avg_time = 30
        footer.ui.toc.getChapterPagesLeft = function() return 1 end
        assert.are.equal(hair .. "< 1m", ReaderFooter.textGeneratorMap.chapter_time_to_read(footer))

        footer.ui.statistics.avg_time = 60
        footer.ui.toc.getChapterPagesLeft = function() return 60 end
        assert.are.equal(hair .. "1h", ReaderFooter.textGeneratorMap.chapter_time_to_read(footer))

        footer.ui.toc.getChapterPagesLeft = function() return 65 end
        assert.are.equal(hair .. "1h 5m", ReaderFooter.textGeneratorMap.chapter_time_to_read(footer))
    end)

    it("uses KOReader's chapter-time formatter for the default format", function()
        local original_filler = function() return "          ", false end
        local ReaderFooter = {
            textGeneratorMap = {
                chapter_time_to_read = function() return "01:05" end,
                dynamic_filler = original_filler,
            },
            genAllFooterText = function() return "all" end,
        }
        ZenSpec.replace("apps/reader/modules/readerfooter", ReaderFooter)
        _G.__ZEN_UI_PLUGIN = {
            config = { reader_footer = { chapter_time_format = "koreader" } },
        }
        apply_patch("modules/reader/patches/reader_footer_time_format")

        assert.are.equal("01:05", ReaderFooter.textGeneratorMap.chapter_time_to_read({}))
        local text, merge = ReaderFooter.textGeneratorMap.dynamic_filler({})
        assert.are.equal("          ", text)
        assert.is_false(merge)
    end)

    it("preserves native dynamic filler spacing for full and compact chapter time", function()
        local original_filler = function() return "          ", true end
        local footer = {
            pageno = 1,
            footerTextGenerators = { original_filler },
            ui = {
                statistics = { settings = { is_enabled = true }, avg_time = 60 },
                toc = { getChapterPagesLeft = function() return 1 end },
                document = { getTotalPagesLeft = function() return 1 end },
            },
        }
        for _i, format in ipairs({ "full", "compact" }) do
            local ReaderFooter = {
                textGeneratorMap = {
                    chapter_time_to_read = function() return "stock" end,
                    dynamic_filler = original_filler,
                },
            }
            ZenSpec.replace("apps/reader/modules/readerfooter", ReaderFooter)
            _G.__ZEN_UI_PLUGIN = {
                config = { reader_footer = { chapter_time_format = format } },
            }
            apply_patch("modules/reader/patches/reader_footer_time_format")

            local text, merge = ReaderFooter.textGeneratorMap.dynamic_filler(footer)
            assert.are.equal("          ", text)
            assert.is_true(merge)
            assert.are.equal(original_filler, ReaderFooter.textGeneratorMap.dynamic_filler)
        end
    end)

    it("preserves KOReader's dynamic filler marker in verbose mode", function()
        local ReaderFooter = {
            textGeneratorMap = {
                chapter_time_to_read = function() return "chapter" end,
                dynamic_filler = function() return nil, true, true end,
            },
            genAllFooterText = function() return "all" end,
        }
        ZenSpec.replace("apps/reader/modules/readerfooter", ReaderFooter)
        _G.__ZEN_UI_PLUGIN = {
            config = { reader_footer = { chapter_time_format = "full" } },
        }
        apply_patch("modules/reader/patches/reader_footer_time_format")

        local text, merge, is_filler = ReaderFooter.textGeneratorMap.dynamic_filler({})
        assert.is_nil(text)
        assert.is_true(merge)
        assert.is_true(is_filler)
    end)

    it("keeps configured image documents hidden after load and footer toggles", function()
        local ready_calls, mode
        local ReaderFooter = {
            onReaderReady = function() ready_calls = (ready_calls or 0) + 1 end,
            applyFooterMode = function(_, value) mode = value end,
        }
        ZenSpec.replace("apps/reader/modules/readerfooter", ReaderFooter)
        _G.__ZEN_UI_PLUGIN = { config = { reader_footer = { hide_in_cbz = true } } }
        apply_patch("modules/reader/patches/reader_footer_cbz_hide")

        local refresh_args
        local footer = {
            ui = { document = { file = "/books/Comic.CBZ" } },
            view = { footer_visible = true },
            refreshFooter = function(_, first, second) refresh_args = { first, second } end,
        }
        ReaderFooter.onReaderReady(footer)
        assert.are.equal(1, ready_calls)
        assert.is_false(footer.view.footer_visible)
        assert.same({ true, true }, refresh_args)

        footer.view.footer_visible = true
        ReaderFooter.applyFooterMode(footer, 3)
        assert.are.equal(3, mode)
        assert.is_false(footer.view.footer_visible)
    end)

    it("keeps a disabled bottom status bar hidden after reopening a book", function()
        local ready_calls, applied_mode
        local ReaderFooter = {
            onReaderReady = function() ready_calls = (ready_calls or 0) + 1 end,
            applyFooterMode = function(self, mode)
                applied_mode = mode
                self.view.footer_visible = mode ~= self.mode_list.off
            end,
        }
        ZenSpec.replace("apps/reader/modules/readerfooter", ReaderFooter)
        _G.__ZEN_UI_PLUGIN = {
            config = { reader_footer = { status_bar_enabled = false } },
        }
        apply_patch("modules/reader/patches/reader_footer_cbz_hide")

        local refresh_args
        local footer = {
            mode_list = { off = 0 },
            ui = { document = { file = "/books/Novel.epub" } },
            view = { footer_visible = true },
            applyFooterMode = ReaderFooter.applyFooterMode,
            refreshFooter = function(_, first, second) refresh_args = { first, second } end,
        }
        ReaderFooter.onReaderReady(footer)

        assert.are.equal(1, ready_calls)
        assert.are.equal(0, applied_mode)
        assert.is_false(footer.view.footer_visible)
        assert.same({ true, true }, refresh_args)
    end)

    it("persists customized bottom status bar items before closing an EPUB", function()
        local save_calls = 0
        local ReaderFooter = {
            onReaderReady = function() end,
            applyFooterMode = function() end,
            onSaveSettings = function() save_calls = save_calls + 1 end,
        }
        ZenSpec.replace("apps/reader/modules/readerfooter", ReaderFooter)
        _G.__ZEN_UI_PLUGIN = { config = { reader_footer = {} } }
        G_reader_settings:saveSetting("footer", { time = false, battery = true })
        apply_patch("modules/reader/patches/reader_footer_cbz_hide")

        local customized = {
            time = true,
            battery = false,
            book_title = true,
            order = { [0] = "off", "book_title", "time", "battery" },
        }
        ReaderFooter.onSaveSettings({
            settings = customized,
            ui = { document = { file = "/books/Novel.epub" } },
        })

        assert.are.equal(1, save_calls)
        assert.are.equal(customized, G_reader_settings:readSetting("footer"))
        assert.is_true(G_reader_settings:readSetting("footer").book_title)
        assert.same(customized.order, G_reader_settings:readSetting("footer").order)
    end)

    it("leaves ordinary documents and disabled image hiding unchanged", function()
        local refreshes = 0
        local ReaderFooter = {
            onReaderReady = function() end,
            applyFooterMode = function(self) self.view.footer_visible = true end,
        }
        ZenSpec.replace("apps/reader/modules/readerfooter", ReaderFooter)
        _G.__ZEN_UI_PLUGIN = { config = { reader_footer = { hide_in_cbz = false } } }
        apply_patch("modules/reader/patches/reader_footer_cbz_hide")

        local footer = {
            ui = { document = { file = "/books/Novel.epub" } },
            view = { footer_visible = true },
            refreshFooter = function() refreshes = refreshes + 1 end,
        }
        ReaderFooter.onReaderReady(footer)
        ReaderFooter.applyFooterMode(footer, 1)
        assert.is_true(footer.view.footer_visible)
        assert.are.equal(0, refreshes)
    end)

    it("keeps forced footer refreshes behind overlays and clears a hidden footer", function()
        saved_modules = {}
        for _i, name in ipairs({
            "apps/reader/modules/readerfooter", "apps/reader/readerui", "device", "ffi/blitbuffer",
            "ui/bidi", "ui/geometry", "ui/uimanager", "ui/widget/container/leftcontainer", "ui/widget/textwidget",
        }) do
            saved_modules[name] = package.loaded[name] or false
        end
        local repaint, repaint_full, received
        local ReaderFooter = {
            textGeneratorMap = {
                battery = function() return "" end,
                page_progress = function() return "" end,
                dynamic_filler = function() return "" end,
            },
            shouldBeRepainted = function() return repaint, repaint_full end,
            _updateFooterText = function(_, force_repaint, full_repaint)
                received = { force_repaint, full_repaint }
            end,
        }
        ZenSpec.replace("apps/reader/modules/readerfooter", ReaderFooter)
        ZenSpec.replace("apps/reader/readerui", {})
        ZenSpec.replace("device", { screen = {} })
        for _i, name in ipairs({
            "ffi/blitbuffer", "ui/bidi", "ui/geometry", "ui/uimanager",
            "ui/widget/container/leftcontainer", "ui/widget/textwidget",
        }) do
            ZenSpec.replace(name, {})
        end
        ZenSpec.replace("ui/uimanager", { scheduleIn = function() end })
        _G.__ZEN_UI_PLUGIN = { config = { features = {} } }
        apply_patch("modules/reader/patches/reader_footer")
        local footer = setmetatable({
            settings = { progress_margin_width = 10 },
            view = { footer_visible = true },
        }, { __index = ReaderFooter })

        repaint = false -- PageBrowser covers the footer.
        footer:_updateFooterText(true)
        assert.is_false(received[1])
        repaint, repaint_full = true, true -- A smaller overlay needs the full stack repainted.
        footer:_updateFooterText(true)
        assert.is_true(received[1])
        assert.is_true(received[2])
        repaint_full = nil -- Reader is visible again.
        footer:_updateFooterText(true)
        assert.is_true(received[1])
        assert.is_nil(received[2])
        repaint = false
        footer.view.footer_visible = false
        footer:_updateFooterText(true, true)
        assert.is_true(received[1])
        assert.is_true(received[2])
    end)

    it("opts into book margins without changing saved footer spacing and restores it when disabled", function()
        saved_modules = {}
        for _i, name in ipairs({
            "apps/reader/modules/readerfooter", "apps/reader/readerui",
            "common/reader_status_bar", "device", "ffi/blitbuffer", "ui/bidi",
            "ui/geometry", "ui/uimanager", "ui/widget/container/leftcontainer", "ui/widget/textwidget",
        }) do
            saved_modules[name] = package.loaded[name] or false
        end
        local painted_x, text_margin, layout_margin, builds, resets = nil, nil, nil, 0, 0
        local ReaderFooter = {
            textGeneratorMap = {
                battery = function() return "" end,
                page_progress = function() return "" end,
                dynamic_filler = function() return "" end,
            },
            textOptionTitles = function() end,
            set_mode_index = function() end,
            addToMainMenu = function() end,
            updateFooterContainer = function(self)
                builds = builds + 1
                self.vertical_frame = { paintTo = function(_frame, _bb, x) painted_x = x end }
            end,
            resetLayout = function(self, force)
                assert.is_true(force)
                layout_margin = self.settings.progress_margin_width
                resets = resets + 1
            end,
            _updateFooterText = function(self)
                text_margin = self.settings.progress_margin_width
                return "updated"
            end,
            genAllFooterText = function() return "" end,
        }
        ZenSpec.replace("apps/reader/modules/readerfooter", ReaderFooter)
        ZenSpec.replace("apps/reader/readerui", {})
        ZenSpec.replace("device", {
            screen = { scaleBySize = function(_self, value) return value * 2 end },
        })
        ZenSpec.replace("ffi/blitbuffer", { COLOR_GRAY_5 = 5 })
        ZenSpec.replace("ui/bidi", {})
        ZenSpec.replace("ui/geometry", {})
        ZenSpec.replace("ui/uimanager", { scheduleIn = function() end })
        ZenSpec.replace("ui/widget/container/leftcontainer", {})
        ZenSpec.replace("ui/widget/textwidget", {})
        ZenSpec.unload("common/reader_status_bar")
        _G.__ZEN_UI_PLUGIN = { config = { features = {} } }
        apply_patch("modules/reader/patches/reader_footer")

        local document = { configurable = { h_page_margins = { 30, 50 } } }
        local footer = setmetatable({
            ui = { document = document },
            settings = { disable_progress_bar = true, progress_margin = false, progress_margin_width = 10 },
            horizontal_margin = 3,
        }, { __index = ReaderFooter })
        footer:updateFooterContainer()
        footer.vertical_frame:paintTo({}, 100, 0)
        assert.are.equal(100, painted_x)
        assert.are.equal("updated", footer:_updateFooterText())
        assert.are.equal(10, text_margin)
        assert.are.equal(3, footer.horizontal_margin)
        assert.are.equal(1, builds)
        assert.are.equal(0, resets)

        _G.__ZEN_UI_PLUGIN.config.features.reader_status_bar_margins = true
        footer:updateFooterContainer()
        assert.are.equal(80, footer.horizontal_margin)
        assert.are.equal(10, footer.settings.progress_margin_width)
        assert.is_false(footer.settings.progress_margin)
        footer.vertical_frame:paintTo({}, 100, 0)
        assert.are.equal(80, painted_x)

        assert.are.equal("updated", footer:_updateFooterText())
        assert.are.equal(40, text_margin)
        assert.are.equal(10, footer.settings.progress_margin_width)
        assert.are.equal(2, builds)
        document.configurable.h_page_margins = { 40, 40 }
        footer.vertical_frame:paintTo({}, 100, 0)
        assert.are.equal(100, painted_x)
        document.configurable.h_page_margins = { 50, 70 }
        footer:_updateFooterText()
        assert.are.equal(120, footer.horizontal_margin)
        assert.are.equal(60, text_margin)
        assert.are.equal(60, layout_margin)
        assert.are.equal(10, footer.settings.progress_margin_width)
        assert.are.equal(3, builds)
        assert.are.equal(1, resets)

        _G.__ZEN_UI_PLUGIN.config.features.reader_status_bar_margins = false
        footer:_updateFooterText()
        assert.are.equal(3, footer.horizontal_margin)
        assert.are.equal(10, text_margin)
        assert.are.equal(10, layout_margin)
        assert.is_false(footer.settings.progress_margin)
        assert.are.equal(4, builds)
        assert.are.equal(2, resets)
        footer.vertical_frame:paintTo({}, 100, 0)
        assert.are.equal(100, painted_x)

        _G.__ZEN_UI_PLUGIN.config.features.reader_status_bar_margins = true
        local fixed_footer = setmetatable({
            ui = { document = {} },
            settings = { disable_progress_bar = true, progress_margin_width = 10 },
            horizontal_margin = 3,
        }, { __index = ReaderFooter })
        fixed_footer:updateFooterContainer()
        assert.are.equal(3, fixed_footer.horizontal_margin)
        assert.are.equal(10, fixed_footer.settings.progress_margin_width)
        fixed_footer.vertical_frame:paintTo({}, 100, 0)
        assert.are.equal(100, painted_x)

        document.getPageMargins = function() return { left = 30, right = 50 } end
        footer:updateFooterContainer()
        assert.are.equal(40, footer.horizontal_margin)
        footer.vertical_frame:paintTo({}, 100, 0)
        assert.are.equal(90, painted_x)
        footer:_updateFooterText()
        assert.are.equal(20, text_margin)
        assert.are.equal(10, footer.settings.progress_margin_width)

        local screen = package.loaded["device"].screen
        screen.scaleBySize = function(_self, value) return math.ceil(value * 1264 / 600) end
        document.getPageMargins = function() return { left = 64, right = 64 } end
        footer:updateFooterContainer()
        assert.are.equal(64, footer.horizontal_margin)
        footer:_updateFooterText()
        assert.are.equal(64, screen:scaleBySize(text_margin))
        assert.are.equal(10, footer.settings.progress_margin_width)
    end)

    it("keeps the progress anchor out of cycling and uses the Zen arrange list", function()
        local dependency_names = {
            "apps/reader/modules/readerfooter",
            "apps/reader/readerui",
            "common/ui/zen_arrange_list",
            "device",
            "ffi/blitbuffer",
            "ui/bidi",
            "ui/geometry",
            "ui/uimanager",
            "ui/widget/container/leftcontainer",
            "ui/widget/textwidget",
        }
        saved_modules = {}
        for _i, name in ipairs(dependency_names) do
            saved_modules[name] = package.loaded[name] or false
        end

        local stock_arrange_called = false
        local ReaderFooter = {
            textGeneratorMap = {
                battery = function() return "battery" end,
                page_progress = function() return "page" end,
                dynamic_filler = function() return "" end,
            },
            textOptionTitles = function(_self, option) return option end,
            set_mode_index = function(self)
                self.mode_index = {
                    [0] = "off",
                    "page_progress",
                    "progress_bar",
                    "dynamic_filler_2",
                }
                self.mode_nb = 4
            end,
            addToMainMenu = function(_self, menu_items)
                menu_items.status_bar = {
                    sub_item_table = {
                        {
                            text = "Status bar items",
                            sub_item_table = {{ text = "External content" }},
                        },
                        {
                            text = "Configure items",
                            sub_item_table = {{
                                text = "Arrange items in status bar",
                                callback = function() stock_arrange_called = true end,
                            }},
                        },
                    },
                }
            end,
            updateFooterContainer = function() end,
            _updateFooterText = function() end,
            genAllFooterText = function() return "" end,
            updateFooterTextGenerator = function(self) self.updated = true end,
            onUpdateFooter = function(self) self.repainted = true end,
        }
        local footer = setmetatable({
            settings = {
                disable_progress_bar = true,
                dynamic_filler_2 = false,
                page_progress = true,
                progress_bar = true,
            },
            mode_index = {
                [0] = "off",
                "page_progress",
                "progress_bar",
                "dynamic_filler_2",
            },
            mode_nb = 4,
            mode_list = {
                off = 0,
                page_progress = 1,
                progress_bar = 2,
                dynamic_filler_2 = 3,
            },
        }, { __index = ReaderFooter })
        local arrange_options
        local dirty = false
        ZenSpec.replace("apps/reader/modules/readerfooter", ReaderFooter)
        ZenSpec.replace("apps/reader/readerui", {
            instance = { view = { footer = footer } },
        })
        ZenSpec.replace("common/ui/zen_arrange_list", {
            show = function(options) arrange_options = options end,
        })
        ZenSpec.replace("device", {
            screen = { scaleBySize = function(_self, value) return value end },
        })
        ZenSpec.replace("ffi/blitbuffer", { COLOR_GRAY_5 = 5 })
        ZenSpec.replace("ui/bidi", { wrap = function(text) return text end })
        ZenSpec.replace("ui/geometry", {})
        ZenSpec.replace("ui/widget/container/leftcontainer", {})
        ZenSpec.replace("ui/widget/textwidget", {})
        ZenSpec.replace("ui/uimanager", {
            scheduleIn = function() end,
            setDirty = function() dirty = true end,
        })

        apply_patch("modules/reader/patches/reader_footer")
        assert.is_nil(footer.settings.progress_bar)
        footer.settings.progress_bar = true
        footer:set_mode_index()
        assert.is_nil(footer.settings.progress_bar)

        local menu_items = {}
        footer:addToMainMenu(menu_items)
        local arrange_item = menu_items.status_bar.sub_item_table[2].sub_item_table[1]
        assert.is_false(arrange_item.enabled_func())
        arrange_item.callback()

        assert.is_false(stock_arrange_called)
        assert.are.equal("Arrange items", arrange_options.title)
        assert.is_true(arrange_options.item_table[2].dim)

        footer.settings.disable_progress_bar = false
        assert.is_true(arrange_item.enabled_func())
        arrange_item.callback()
        assert.is_false(arrange_options.item_table[2].dim)
        arrange_options.callback()
        assert.is_true(footer.updated)
        assert.is_true(footer.repainted)
        assert.is_true(dirty)
    end)
end)
