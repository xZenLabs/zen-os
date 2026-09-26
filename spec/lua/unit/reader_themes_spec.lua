describe("reader themes", function()
    local Themes
    local dirty_calls
    local next_tick_callback
    local promote_partial
    local force_repaints

    before_each(function()
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
            screen = {
                night_mode = false,
                toggleNightMode = function(self) self.night_mode = not self.night_mode end,
            },
        })
        ZenSpec.unload("common/reader_themes")
        Themes = require("common/reader_themes")
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
        assert.is_true(Themes.isValidColor("#123abc"))
        assert.is_true(Themes.isValidColor("#abc"))
        assert.is_false(Themes.isValidColor("#123ab"))
        local hue, saturation, value = Themes.colorToHsv("#336699")
        assert.is_true(math.abs(hue - 210) < 0.000001)
        assert.is_true(math.abs(saturation - 2 / 3) < 0.000001)
        assert.is_true(math.abs(value - 0.6) < 0.000001)
        assert.is_nil(Themes.colorToHsv("not-a-color"))
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
        assert.matches("#3f3524", applied_css, 1, true)
        assert.are.equal(1, call_cache_resets)
        assert.are.equal(1, buffer_cache_resets)
        assert.are.equal(0xf3ead2, backgrounds[1])
        assert.are.equal("full", dirty_calls[1][3])

        plugin.config.features.reader_themes = false
        G_reader_settings:saveSetting("cre_background_color", "#ffffff")
        assert.is_true(Themes.applyCurrent(plugin))
        assert.are.equal("#ffffff", backgrounds[2])
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
        assert.are.equal("ui", require("ui/uimanager")._refresh_stack[1].mode)
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
end)
