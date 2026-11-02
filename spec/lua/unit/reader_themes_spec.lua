describe("reader themes", function()
    local Themes
    local dirty_calls
    local next_tick_callback
    local promote_partial
    local force_repaints
    local saved_version

    before_each(function()
        saved_version = package.loaded.version
        ZenSpec.replace("version", { getNormalizedCurrentVersion = function() return 202607000000 end })
        dirty_calls = {}
        next_tick_callback = nil
        promote_partial = false
        force_repaints = 0
        _G.G_reader_settings = ZenSpec.memorySettings()
        _G.G_reader_settings.has = function(self, key) return self.data[key] ~= nil end
        ZenSpec.replace("ui/uimanager", {
            _refresh_stack = {},
            _refresh = function(self, refresh_type)
                if refresh_type == "partial" and promote_partial then refresh_type = "full" end
                table.insert(self._refresh_stack, { mode = refresh_type })
            end,
            setDirty = function(self, ...)
                dirty_calls[#dirty_calls + 1] = { self, ... }
                return self:_refresh(select(2, ...))
            end,
            nextTick = function(_, callback) next_tick_callback = callback end,
            forceRePaint = function() force_repaints = force_repaints + 1 end,
        })
        ZenSpec.replace("device", {
            isKindle = function() return false end,
            hasColorScreen = function() return false end,
            screen = {
                night_mode = false,
                refreshPartialImp = function() end,
                toggleNightMode = function(self) self.night_mode = not self.night_mode end,
            },
        })
        ZenSpec.unload("common/reader_themes")
        Themes = require("common/reader_themes")
    end)

    after_each(function()
        package.loaded.version = saved_version
    end)

    it("appends the selected theme and removes it when disabled", function()
        local plugin = {
            config = {
                features = { reader_themes = true },
                reader_themes = { light_mode = "dark_warm_gray" },
            },
        }

        local css = Themes.appendCss(plugin, "body { margin: 0; }")
        assert.matches("#dcdccc", css, 1, true)
        assert.matches("#1f1f1f", css, 1, true)

        plugin.config.features.reader_themes = false
        assert.are.equal("body { margin: 0; }\n", Themes.appendCss(plugin, css))

        plugin.config.features.reader_themes = true
        plugin.config.reader_themes.light_mode = "default"
        assert.are.equal("body { margin: 0; }\n", Themes.appendCss(plugin, css))
    end)

    it("uses an independent theme for each display mode", function()
        local plugin = {
            config = {
                features = { reader_themes = true },
                reader_themes = {
                    dark_mode = "dark_graphite",
                    light_mode = "default",
                },
            },
        }

        G_reader_settings:saveSetting("night_mode", true)
        local css = Themes.appendCss(plugin, "base")
        assert.matches("#2f2f2f", css, 1, true)
        assert.matches("#dadada", css, 1, true)
        local background
        Themes.applyBackground({
            document = { setBackgroundColor = function(_, color) background = color end },
        }, plugin)
        assert.are.equal(0xdadada, background)

        G_reader_settings:saveSetting("night_mode", false)
        assert.are.equal("base", Themes.appendCss(plugin, "base"))
    end)

    it("detects a theme selected for an open reader's target mode", function()
        ZenSpec.replace("apps/reader/readerui", { instance = { document = {} } })
        local plugin = {
            config = {
                features = { reader_themes = true },
                reader_themes = {
                    dark_mode = "dark_graphite",
                    light_mode = "default",
                },
            },
        }

        assert.is_false(Themes.isActive(plugin))
        assert.is_true(Themes.isActiveInReader(plugin, true))
    end)

    it("uses custom theme colors and font face", function()
        local face, background
        local reader = {
            document = {
                setFontFace = function(_, value) face = value end,
                setBackgroundColor = function(_, value) background = value end,
            },
        }
        local plugin = {
            config = {
                features = { reader_themes = true },
                reader_themes = {
                    light_mode = "custom_1",
                    custom = {
                        custom_1 = {
                            name = "Paper",
                            text = "#321",
                            background = "#abc",
                            font_face = "NotoSerif-Regular.ttf",
                        },
                    },
                },
            },
        }

        local css = Themes.appendCss(plugin, "base")
        assert.matches("#332211", css, 1, true)
        assert.matches("#aabbcc", css, 1, true)
        assert.is_true(Themes.applyFont(reader, plugin))
        assert.are.equal("NotoSerif-Regular.ttf", face)
        assert.is_true(Themes.applyBackground(reader, plugin))
        assert.are.equal(0xaabbcc, background)
        reader.doc_settings = ZenSpec.memorySettings({ font_face = "Saved book font" })
        assert.is_true(Themes.applyFont(reader, plugin))
        assert.are.equal("NotoSerif-Regular.ttf", face)
        assert.is_true(Themes.isValidColor("#123abc"))
        assert.is_true(Themes.isValidColor("#abc"))
        assert.is_false(Themes.isValidColor("#123ab"))
        local hue, saturation, value = Themes.colorToHsv("#336699")
        assert.is_true(math.abs(hue - 210) < 0.000001)
        assert.is_true(math.abs(saturation - 2 / 3) < 0.000001)
        assert.is_true(math.abs(value - 0.6) < 0.000001)
        assert.is_nil(Themes.colorToHsv("not-a-color"))
    end)

    it("provides preview colors for built-in, custom, and default themes", function()
        local plugin = {
            config = {
                reader_themes = {
                    custom = {
                        custom_1 = { text = "#123456", background = "#abcdef" },
                        invalid = { text = "bad", background = "#ffffff" },
                    },
                },
            },
        }
        local Blitbuffer = require("ffi/blitbuffer")

        local text, background = Themes.getPreviewColors(plugin, "dark_graphite")
        assert.are.equal(tostring(Blitbuffer.ColorRGB32(208, 208, 208, 255)), tostring(text))
        assert.are.equal(tostring(Blitbuffer.ColorRGB32(37, 37, 37, 255)), tostring(background))

        text, background = Themes.getPreviewColors(plugin, "custom_1")
        assert.are.equal(tostring(Blitbuffer.ColorRGB32(18, 52, 86, 255)), tostring(text))
        assert.are.equal(tostring(Blitbuffer.ColorRGB32(171, 205, 239, 255)), tostring(background))

        text, background = Themes.getPreviewColors(plugin, "default")
        assert.are.equal(tostring(Blitbuffer.ColorRGB32(0, 0, 0, 255)), tostring(text))
        assert.are.equal(tostring(Blitbuffer.ColorRGB32(255, 255, 255, 255)), tostring(background))
        assert.is_nil(Themes.getPreviewColors(plugin, "invalid"))

        local editable_theme = { text = "#102030", background = "#f0e0d0" }
        text, background = Themes.getPreviewColors(plugin, nil, editable_theme)
        assert.are.equal(tostring(Blitbuffer.ColorRGB32(16, 32, 48, 255)), tostring(text))
        assert.are.equal(tostring(Blitbuffer.ColorRGB32(240, 224, 208, 255)), tostring(background))
        editable_theme.text = "#abcdef"
        text = Themes.getPreviewColors(plugin, nil, editable_theme)
        assert.are.equal(tostring(Blitbuffer.ColorRGB32(171, 205, 239, 255)), tostring(text))

        G_reader_settings:saveSetting("night_mode", true)
        text, background = Themes.getPreviewColors(plugin, "dark_graphite")
        assert.are.equal(tostring(Blitbuffer.ColorRGB32(208, 208, 208, 255)), tostring(text))
        assert.are.equal(tostring(Blitbuffer.ColorRGB32(37, 37, 37, 255)), tostring(background))
    end)

    it("registers the additional built-in theme palettes", function()
        local expected = {
            sepia = { "#2c1a0e", "#f5e6c8" },
            darker_sepia = { "#2e2014", "#e6cea9" },
            old_book = { "#2e1800", "#edd9b0" },
            sage = { "#1a2e1a", "#eaf0e8" },
            fern = { "#0f2a14", "#dff0e0" },
            arctic = { "#0d1b2a", "#e8f0f8" },
            midnight = { "#e2e8f0", "#121c33" },
            nord = { "#d8dee9", "#2e3440" },
            amber_night = { "#fad08a", "#14100a" },
            sepia_night = { "#c8a070", "#1a0e00" },
            dark_moss = { "#90c090", "#0a1a0a" },
            dark_sky = { "#7aaad4", "#0a1428" },
            velvet = { "#f9d592", "#532653" },
        }
        for key, colors in pairs(expected) do
            assert.are.equal(colors[1], Themes.BUILTIN_THEMES[key].text, key)
            assert.are.equal(colors[2], Themes.BUILTIN_THEMES[key].background, key)
        end
    end)

    it("does not change the font for built-in themes", function()
        local face
        local reader = {
            font = { font_face = "Noto Serif" },
            document = {
                setFontFace = function(_, value) face = value end,
            },
        }
        local plugin = {
            config = {
                features = { reader_themes = true },
                reader_themes = { light_mode = "dark_warm_gray" },
            },
        }

        assert.is_false(Themes.applyFont(reader, plugin))
        assert.is_nil(face)
    end)

    it("reapplies the open CRE reader and restores KOReader's background", function()
        local applied_css, backgrounds = 0, {}
        local call_cache_resets, buffer_cache_resets = 0, 0
        local reader = {
            document = {
                setStyleSheet = function(_, _css_file, css) applied_css = css end,
                setBackgroundColor = function(_, color) backgrounds[#backgrounds + 1] = color end,
                resetCallCache = function() call_cache_resets = call_cache_resets + 1 end,
                resetBufferCache = function() buffer_cache_resets = buffer_cache_resets + 1 end,
            },
            typeset = {
                css = "epub.css",
            },
            styletweak = { getCssText = function() return "base" end },
        }
        ZenSpec.replace("apps/reader/readerui", { instance = reader })
        local plugin = {
            config = {
                features = { reader_themes = true },
                reader_themes = { light_mode = "light_sepia" },
            },
        }

        assert.is_true(Themes.applyCurrent(plugin))
        assert.matches("body, body * { color: #000000 !important; }", applied_css, 1, true)
        assert.are.equal(1, call_cache_resets)
        assert.are.equal(1, buffer_cache_resets)
        assert.are.equal(0xf3ead2, backgrounds[1])
        assert.are.equal("full", dirty_calls[1][3])

        plugin.config.features.reader_themes = false
        G_reader_settings:saveSetting("cre_background_color", "#ffffff")
        G_reader_settings:saveSetting("avoid_flashing_ui", true)
        assert.is_true(Themes.applyCurrent(plugin))
        assert.are.equal("#ffffff", backgrounds[2])
        assert.are.equal("ui", dirty_calls[2][3])
    end)

    it("makes the footer container transparent while colors are enabled", function()
        local footer = {
            footer_content = {},
            footer_text = {},
            _zen_left_text = {},
        }
        local plugin = {
            config = {
                features = { reader_themes = true },
                reader_themes = { light_mode = "dark_warm_gray" },
            },
        }

        assert.is_true(Themes.applyFooterColors(footer, plugin))
        assert.is_true(footer.footer_content.background == false)

        plugin.config.features.reader_themes = false
        Themes.applyFooterColors(footer, plugin)
        assert.is_not_nil(footer.footer_content.background)
    end)

    it("pre-inverts dark theme colors once for CSS, margins and status bars", function()
        local plugin = {
            config = {
                features = { reader_themes = true },
                reader_themes = { dark_mode = "light_tan", light_mode = "light_tan" },
            },
        }
        local document = { render_color = true, _nightmode_images = true }
        G_reader_settings:saveSetting("night_mode", true)
        local css = Themes.appendCss(plugin, "base", document)
        assert.matches("#e8dcc5", css, 1, true)
        assert.matches("#473b2d", css, 1, true)

        local background
        document.setBackgroundColor = function(_self, color) background = color end
        Themes.applyBackground({ document = document }, plugin)
        assert.are.equal(0x17233a, background)

        document.render_color = false
        assert.matches("#17233a", Themes.appendCss(plugin, "base", document), 1, true)
        document.render_color = true
        document._nightmode_images = false
        assert.matches("#17233a", Themes.appendCss(plugin, "base", document), 1, true)
        document._nightmode_images = true
        plugin.config.reader_themes.dark_mode = "dark_graphite"
        assert.matches("#dadada", Themes.appendCss(plugin, "base", document), 1, true)

        ZenSpec.replace("version", { getNormalizedCurrentVersion = function() return 202603000000 end })
        ZenSpec.unload("common/reader_themes")
        local older_themes = require("common/reader_themes")
        plugin.config.reader_themes.dark_mode = "light_tan"
        assert.matches("#17233a", older_themes.appendCss(plugin, "base", document), 1, true)
    end)

    it("honors UI flash avoidance when opening themed books in either mode", function()
        local Screen = require("device").screen
        Screen.waveform_full = 2
        Screen.waveform_flashnight = 8
        local plugin = {
            config = {
                features = { reader_themes = true },
                reader_themes = { dark_mode = "dark_graphite", light_mode = "light_tan" },
            },
        }
        _G.__ZEN_UI_PLUGIN = plugin
        ZenSpec.replace("document/credocument", {})
        ZenSpec.replace("apps/reader/modules/readertypeset", {})
        ZenSpec.replace("apps/reader/modules/readerfooter", {})
        local ReaderUI = {
            doShowReader = function(self)
                self.instance = { document = {} }
                return "opened"
            end,
        }
        ZenSpec.replace("apps/reader/readerui", ReaderUI)
        ZenSpec.unload("modules/reader/patches/reader_themes")
        require("modules/reader/patches/reader_themes")()
        local waveform
        local UIManager = require("ui/uimanager")
        UIManager.forceRePaint = function()
            assert.is_not_nil(ReaderUI.instance.document)
            assert.are.equal(G_reader_settings:isTrue("avoid_flashing_ui") and "ui" or "full",
                dirty_calls[#dirty_calls][3])
            waveform = Screen.waveform_flashnight
        end

        for _i, avoid in ipairs({ false, true }) do
            G_reader_settings:saveSetting("avoid_flashing_ui", avoid)
            for _j, dark_mode in ipairs({ false, true }) do
                Screen.night_mode = dark_mode
                G_reader_settings:saveSetting("night_mode", dark_mode)
                assert.are.equal("opened", ReaderUI:doShowReader("themed.epub"))
                assert.are.equal(dark_mode and not avoid and 2 or 8, waveform)
                assert.are.equal(8, Screen.waveform_flashnight)
                assert.are.equal(dark_mode, Screen.night_mode)
            end
        end
        G_reader_settings:saveSetting("avoid_flashing_ui", false)

        waveform = nil
        plugin.config.features.reader_themes = false
        ReaderUI:doShowReader("disabled.epub")
        assert.is_nil(waveform)
        plugin.config.features.reader_themes = true
        plugin.config.reader_themes.dark_mode = "default"
        ReaderUI:doShowReader("default.epub")
        assert.is_nil(waveform)

        plugin.config.reader_themes.dark_mode = "dark_graphite"
        Screen.waveform_full = nil
        ReaderUI:doShowReader("generic-screen.epub")
        assert.are.equal(8, waveform)

        Screen.waveform_full = 2
        UIManager.forceRePaint = function() error("paint failed", 0) end
        assert.has_error(function() ReaderUI:doShowReader("themed.epub") end, "paint failed")
        assert.are.equal(8, Screen.waveform_flashnight)
    end)

    it("uses the clearing waveform without flashing promotions for themed page refreshes", function()
        local plugin = {
            config = {
                features = { reader_themes = true },
                reader_themes = { dark_mode = "dark_graphite", light_mode = "light_tan" },
            },
        }
        _G.__ZEN_UI_PLUGIN = plugin
        ZenSpec.replace("document/credocument", {})
        ZenSpec.replace("apps/reader/modules/readertypeset", {})
        ZenSpec.replace("apps/reader/modules/readerfooter", {})
        local ReaderUI = { instance = {} }
        ZenSpec.replace("apps/reader/readerui", ReaderUI)
        local Device = require("device")
        local Screen = Device.screen
        local refresh_calls = {}
        local fail_refresh = false
        Screen.waveform_partial, Screen.waveform_night, Screen.waveform_full = 3, 9, 2
        Screen.night_is_reagl = true
        Screen.refreshPartialImp = require("ffi/framebuffer_mxcfb").refreshPartialImp
        Screen.debug = function() end
        Screen.mech_refresh = function(self, flashing, waveform, x, y, w, h, dither)
            refresh_calls[#refresh_calls + 1] = {
                flashing = flashing, waveform = waveform, night_waveform = self.waveform_night,
                night_is_reagl = self.night_is_reagl, region = { x, y, w, h }, dither = dither,
            }
            if fail_refresh then error("refresh failed", 0) end
        end
        ZenSpec.unload("modules/reader/patches/reader_themes")
        require("modules/reader/patches/reader_themes")()

        for _i, dark_mode in ipairs({ false, true }) do
            Screen.night_mode = dark_mode
            G_reader_settings:saveSetting("night_mode", dark_mode)
            Screen:refreshPartialImp(10, 20, 100, 200, true)
            assert.are.same({
                flashing = false, waveform = 2, night_waveform = 2, night_is_reagl = false,
                region = { 10, 20, 100, 200 }, dither = false,
            }, refresh_calls[#refresh_calls])
            assert.are.equal(3, Screen.waveform_partial)
            assert.are.equal(9, Screen.waveform_night)
            assert.is_true(Screen.night_is_reagl)
        end

        ReaderUI.instance = nil
        Screen:refreshPartialImp(10, 20, 100, 200, true)
        assert.are.equal(3, refresh_calls[#refresh_calls].waveform)
        assert.is_true(refresh_calls[#refresh_calls].dither)
        ReaderUI.instance = {}
        plugin.config.features.reader_themes = false
        Screen:refreshPartialImp(10, 20, 100, 200, true)
        assert.are.equal(3, refresh_calls[#refresh_calls].waveform)
        assert.is_true(refresh_calls[#refresh_calls].dither)

        for _i, device_state in ipairs({
            { kindle = true, color = true, night = true, waveform = 2 },
            { kindle = true, color = true, night = false, waveform = 3 },
            { kindle = false, color = true, night = true, waveform = 3 },
            { kindle = true, color = false, night = true, waveform = 3 },
        }) do
            Device.isKindle = function() return device_state.kindle end
            Device.hasColorScreen = function() return device_state.color end
            Screen.night_mode = device_state.night
            Screen:refreshPartialImp(10, 20, 100, 200, true)
            assert.are.equal(device_state.waveform, refresh_calls[#refresh_calls].waveform)
            assert.is_false(refresh_calls[#refresh_calls].flashing)
        end

        plugin.config.features.reader_themes = true
        Screen.waveform_full = nil
        Screen:refreshPartialImp(10, 20, 100, 200, true)
        assert.are.equal(3, refresh_calls[#refresh_calls].waveform)
        assert.is_true(refresh_calls[#refresh_calls].dither)

        Screen.waveform_full = 2
        fail_refresh = true
        assert.has_error(function() Screen:refreshPartialImp(10, 20, 100, 200, true) end, "refresh failed")
        assert.are.equal(3, Screen.waveform_partial)
        assert.are.equal(9, Screen.waveform_night)
        assert.is_true(Screen.night_is_reagl)
    end)

    it("wraps CRE stylesheets only while the feature is enabled", function()
        local received_css
        local CreDocument = {
            setStyleSheet = function(_, _file, css) received_css = css end,
        }
        local ReaderTypeset = {
            onReadSettings = function() return true end,
        }
        local ReaderFooter = {
            updateFooterContainer = function() end,
            updateFooterFont = function() end,
            shouldBeRepainted = function() return true end,
        }
        local plugin = {
            config = {
                features = { reader_themes = true },
                reader_themes = {
                    dark_mode = "dark_graphite",
                    light_mode = "dark_graphite",
                },
            },
        }
        _G.__ZEN_UI_PLUGIN = plugin
        ZenSpec.replace("document/credocument", CreDocument)
        ZenSpec.replace("apps/reader/modules/readertypeset", ReaderTypeset)
        ZenSpec.replace("apps/reader/modules/readerfooter", ReaderFooter)
        local ReaderUI = {
            onClose = function() end,
            doShowReader = function(self, file)
                self.instance = { document = { file = file } }
            end,
        }
        ZenSpec.replace("apps/reader/readerui", ReaderUI)
        ZenSpec.unload("modules/reader/patches/reader_themes")

        assert.is_true(require("modules/reader/patches/reader_themes")())
        CreDocument:setStyleSheet("epub.css", "base")
        assert.matches("#252525", received_css, 1, true)

        local repaint, full_repaint = ReaderFooter:shouldBeRepainted()
        assert.is_true(repaint)
        assert.is_true(full_repaint)
        plugin.config.features.reader_themes = false
        repaint, full_repaint = ReaderFooter:shouldBeRepainted()
        assert.is_true(repaint)
        assert.is_nil(full_repaint)
        plugin.config.features.reader_themes = true

        ReaderUI:doShowReader("themed.epub")
        assert.is_nil(dirty_calls[1][2])
        assert.are.equal("full", dirty_calls[1][3])
        assert.are.equal(1, force_repaints)
        dirty_calls = {}
        require("ui/uimanager")._refresh_stack = {}
        force_repaints = 0

        plugin.config.features.reader_themes = false
        ReaderUI:doShowReader("plain.epub")
        assert.are.equal(0, #dirty_calls)
        assert.are.equal(0, force_repaints)
        plugin.config.features.reader_themes = true

        ReaderUI.instance = {}
        require("ui/uimanager"):setDirty(ReaderUI.instance, "partial")
        assert.are.equal("partial", dirty_calls[1][3])
        assert.are.equal("partial", require("ui/uimanager")._refresh_stack[1].mode)
        dirty_calls = {}
        require("ui/uimanager")._refresh_stack = {}
        promote_partial = true
        require("ui/uimanager"):setDirty(ReaderUI.instance, "partial")
        assert.are.equal("full", require("ui/uimanager")._refresh_stack[1].mode)
        dirty_calls = {}
        require("ui/uimanager")._refresh_stack = {}
        promote_partial = false
        plugin.config.features.reader_themes = false
        require("ui/uimanager"):setDirty(ReaderUI.instance, "partial")
        assert.are.equal("partial", dirty_calls[1][3])
        assert.are.equal("partial", require("ui/uimanager")._refresh_stack[1].mode)

        dirty_calls = {}
        plugin.config.features.reader_themes = true
        ReaderUI.instance = nil

        plugin.config.features.reader_themes = false
        CreDocument:setStyleSheet("epub.css", "base")
        assert.are.equal("base", received_css)

        plugin.config.features.reader_themes = true
        local document = {
            setStyleSheet = function() end,
            setBackgroundColor = function() end,
        }
        ReaderUI.instance = {
            document = document,
            typeset = { css = "epub.css" },
            styletweak = { getCssText = function() return "" end },
        }
        require("device").screen:toggleNightMode()
        G_reader_settings:saveSetting("night_mode", true)
        assert.is_true(require("device").screen.night_mode)
        assert.is_function(next_tick_callback)
        next_tick_callback()
        assert.are.equal("full", dirty_calls[1][3])
    end)
    it("captures both configured theme modes even while themes are disabled", function()
        local plugin = { config = { features = { reader_themes = false }, reader_themes = {
            light_mode = "light_tan", dark_mode = "dark_graphite", custom = {},
        } } }
        local snapshot = Themes.capture(plugin)
        assert.is_false(snapshot.enabled)
        assert.are.equal("#e8dcc5", snapshot.light_mode.background)
        assert.are.equal("#252525", snapshot.dark_mode.background)
    end)

    it("restores profile theme snapshots globally without book overrides", function()
        local old_reader = package.loaded["apps/reader/readerui"]
        local old_store = package.loaded["config/preset_store"]
        local store, saved = {}, 0
        ZenSpec.replace("config/preset_store", {
            loadStore = function() return store end,
            saveStore = function(_kind, value) store = value end,
        })
        local reader = { doc_settings = ZenSpec.memorySettings() }
        ZenSpec.replace("apps/reader/readerui", { instance = reader })
        local plugin = { saveConfig = function() saved = saved + 1 end,
            config = { features = { reader_themes = true }, reader_themes = {
            light_mode = "custom_1", dark_mode = "default", custom = {
                custom_1 = { text = "#102030", background = "#eeffdd" },
            },
        } } }
        local snapshot = Themes.capture(plugin)
        plugin.config.reader_themes.custom.custom_1 = nil
        Themes.restore(plugin, snapshot)
        assert.are.equal("custom_1", plugin.config.reader_themes.light_mode)
        snapshot.light_mode.text = "#ffffff"
        assert.are.equal("#102030", Themes.getTheme(plugin).text)
        assert.are.same({}, reader.doc_settings.data)
        assert.are.equal(plugin.config.reader_themes, store.reader_themes)
        assert.are.equal(1, saved)
        Themes.restore(plugin, Themes.capture(plugin))
        assert.is_nil(plugin.config.reader_themes.custom.custom_2)
        Themes.restore(plugin, { enabled = true, light_mode = Themes.BUILTIN_THEMES.light_tan })
        assert.are.equal("light_tan", plugin.config.reader_themes.light_mode)
        Themes.restore(plugin, { enabled = false })
        assert.is_false(Themes.isEnabled(plugin))
        package.loaded["apps/reader/readerui"] = old_reader
        package.loaded["config/preset_store"] = old_store
    end)

    it("uses global themes even when a book has an old override", function()
        local old_reader = package.loaded["apps/reader/readerui"]
        ZenSpec.replace("apps/reader/readerui", { instance = {
            doc_settings = ZenSpec.memorySettings({ zen_reader_theme = { enabled = false } }), document = {},
        } })
        local plugin = { config = { features = { reader_themes = true },
            reader_themes = { light_mode = "light_tan" } } }
        assert.is_true(Themes.isEnabled(plugin))
        assert.are.equal(Themes.BUILTIN_THEMES.light_tan, Themes.getTheme(plugin))
        assert.matches("#e8dcc5", Themes.appendCss(plugin, "base"), 1, true)
        package.loaded["apps/reader/readerui"] = old_reader
    end)

end)
