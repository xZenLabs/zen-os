describe("reader references", function()
    local References, ui, config, saved, saved_settings
    local names = { "gettext", "ffi/util", "modules/reader/references", "modules/reader/reference_drawer",
        "ui/uimanager", "ui/widget/buttondialog", "ui/widget/infomessage", "logger", "common/ui/button_labels",
        "modules/reader/pin_settings", "device", "common/utils", "ui/font", "document/credocument",
        "ui/widget/iconwidget", "ffi/blitbuffer" }

    before_each(function()
        saved_settings = G_reader_settings
        _G.G_reader_settings = ZenSpec.memorySettings()
        saved = {}
        for _i, name in ipairs(names) do saved[name] = package.loaded[name] end
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("device", { screen = { scaleBySize = function(_self, size) return size end } })
        ZenSpec.replace("common/utils", { resolveLocalIcon = function(dir, name) return dir .. name .. ".svg" end,
            htmlFontRoot = function(path) return "root:" .. path end })
        ZenSpec.replace("ffi/util", { template = function(text, value) return (text:gsub("%%1", tostring(value))) end })
        ZenSpec.unload("modules/reader/references")
        References = require("modules/reader/references")
        config = { features = { reader_references = true } }
        References.configure({ config = config })
        ui = {
            page = 5, rolling = {}, doc_settings = ZenSpec.memorySettings(),
            document = { getPageCount = function() return 100 end,
                getPageMargins = function() return { left = 0, right = 0 } end,
                getPageFromXPointer = function(_self, xp) return tonumber(xp:match("%d+")) end,
                getPageXPointer = function(_self, page) return "xp:" .. page end },
            getCurrentPage = function(self) return self.page end,
            annotation = { annotations = {{ page = "xp:12" }} },
        }
        ui.link = {
            location_stack = {{ xpointer = "xp:2" }, { xpointer = "xp:5" }},
            getCurrentLocation = function() return { xpointer = "xp:" .. ui.page } end,
            compareLocationToCurrent = function(_self, loc) return loc.xpointer == "xp:" .. ui.page end,
            onGoBackLink = function() ui.page = 2 end,
        }
        ui.gotopage = {
            getPinnedPageNumber = function() return ui.pin end,
            onPinPage = function(_self, page, remove) ui.pin = not remove and page or nil end,
        }
    end)

    after_each(function()
        _G.G_reader_settings = saved_settings
        for _i, name in ipairs(names) do package.loaded[name] = saved[name] end
    end)

    it("defaults to popups with the reader font without replacing saved preferences", function()
        config.features.reader_references = false
        References.applyDefaults(ui)
        assert.is_nil(G_reader_settings:readSetting("footnote_link_in_popup"))
        config.features.reader_references = true
        References.applyDefaults(ui)
        assert.is_true(G_reader_settings:readSetting("footnote_link_in_popup"))
        assert.is_true(G_reader_settings:readSetting("footnote_popup_use_book_font"))
        assert.equals(0, G_reader_settings:readSetting("footnote_popup_relative_font_size"))
        G_reader_settings:saveSetting("footnote_link_in_popup", false)
        G_reader_settings:saveSetting("footnote_popup_use_book_font", false)
        G_reader_settings:saveSetting("footnote_popup_relative_font_size", -3)
        G_reader_settings:saveSetting("footnote_popup_absolute_font_size", 24)
        References.applyDefaults(ui)
        assert.is_false(G_reader_settings:readSetting("footnote_link_in_popup"))
        assert.is_false(G_reader_settings:readSetting("footnote_popup_use_book_font"))
        assert.equals(-3, G_reader_settings:readSetting("footnote_popup_relative_font_size"))
        assert.equals(24, G_reader_settings:readSetting("footnote_popup_absolute_font_size"))
        -- Native toggle turns the book font off by deleting the key.
        G_reader_settings:delSetting("footnote_popup_use_book_font")
        References.applyDefaults(ui)
        assert.is_nil(G_reader_settings:readSetting("footnote_popup_use_book_font"))
    end)

    it("only shows Return even with a saved footnote without changing history or reading position", function()
        ui.doc_settings:saveSetting("pinned_page", "xp:22")
        ui._zen_references = { footnote = { xpointer = "xp:90" } }
        local actions = References.actions(ui, function() ui.browser_closed = true end)
        assert.equals(1, #actions)
        assert.equals("back", actions[1].id)
        assert.matches("/icons/return.svg$", actions[1].icon)
        assert.equals("Return to page 2", actions[1].text)
        assert.equals(5, ui.page)
        assert.equals(2, #ui.link.location_stack)
        actions[1].callback()
        assert.is_true(ui.browser_closed)
        assert.equals(2, ui.page)
    end)

    it("omits unavailable actions and disappears when disabled", function()
        ui.link.location_stack = {{ xpointer = "xp:5" }}
        ui._zen_references = { footnote = { xpointer = "xp:90" } }
        assert.same({}, References.actions(ui))
        ui.doc_settings:saveSetting("zen_pinned_pages", { "xp:200" })
        assert.same({}, References.actions(ui))
        config.features.reader_references = false
        assert.same({}, References.pinButtons(ui, 9))
        assert.same({}, References.actions(ui))
    end)

    it("returns past repeated checkpoints without creating another history", function()
        ui.link.location_stack = {{ xpointer = "xp:2" }, { xpointer = "xp:5" }, { xpointer = "xp:5" }}
        ui.link.onGoBackLink = function(self)
            local location = table.remove(self.location_stack)
            ui.page = tonumber(location.xpointer:match("%d+"))
        end
        References.actions(ui, function() end)[1].callback()
        assert.equals(2, ui.page)
        assert.equals(0, #ui.link.location_stack)
    end)

    it("uses stable labels and fixed-page history", function()
        ui.pagemap = { wantsPageLabels = function() return true end,
            getXPointerPageLabel = function(_self, xp, clean)
                assert.equals("xp:2", xp); assert.is_true(clean); return "iv"
            end }
        assert.equals("Return to page iv", References.actions(ui)[1].text)
        ui.pagemap.getXPointerPageLabel = function() return "" end
        assert.equals("Return to page 2", References.actions(ui)[1].text)
        ui.rolling, ui.pagemap = nil, nil
        ui.link.location_stack = {{ { page = 3 } }}
        ui.link.compareLocationToCurrent = function() return false end
        assert.equals("Return to page 3", References.actions(ui)[1].text)
    end)

    it("pins the selection start without creating annotations or navigating", function()
        local highlight = { ui = ui, selected_text = { pos0 = "xp:8", pos1 = "xp:9", text = "Selected" } }
        assert.equals(8, References.selectionPage(highlight))
        local buttons = References.pinButtons(ui, References.selectionPage(highlight), function()
            assert.equals(8, References.pinnedPage(ui))
        end)
        assert.equals("Pin this page", buttons[1].text)
        buttons[1].callback()
        assert.equals(8, References.pinnedPage(ui))
        assert.equals(5, ui.page)
        assert.equals(1, #ui.annotation.annotations)
        assert.equals(2, #ui.link.location_stack)
        assert.equals(12, References.selectionPage({ ui = ui }, 1))
        ui.rolling = nil
        assert.equals(4, References.selectionPage({ ui = ui, selected_text = { pos0 = { page = 4 } } }))
    end)

    it("adds independent pins, rejects duplicates and removes only the requested page", function()
        ui.doc_settings:saveSetting("pinned_page", "xp:4")
        local buttons = References.pinButtons(ui, 9)
        assert.equals("Pin this page", buttons[1].text)
        buttons[1].callback()
        assert.same({ "xp:9", "xp:4" }, References.pinLocations(ui))
        assert.is_false(References.pinButtons(ui, 9)[1].enabled)
        References.setPin(ui, 9)
        assert.equals(2, #References.pins(ui))
        References.pinButtons(ui, 9)[2].callback()
        assert.same({ "xp:4" }, References.pinLocations(ui))
        assert.equals("xp:4", ui.doc_settings:readSetting("pinned_page"))
        References.setPin(ui, 4, true)
        assert.same({}, References.pinLocations(ui))
        assert.is_nil(ui.doc_settings:readSetting("pinned_page"))
    end)

    it("clears only the removed pin's image settings after repagination", function()
        References.setPin(ui, 8)
        References.setPin(ui, 12)
        local images = { ["xp:8"] = { image_full = true, image_zoom = 2 },
            ["xp:12"] = { image_full = false, image_zoom = 3 } }
        ui.doc_settings:saveSetting("zen_pinned_image_settings", images)
        ui.document.getPageFromXPointer = function(_self, xp) return tonumber(xp:match("%d+")) + 2 end
        References.setPin(ui, 10, true)
        assert.same({ ["xp:12"] = { image_full = false, image_zoom = 3 } },
            ui.doc_settings:readSetting("zen_pinned_image_settings"))
    end)

    it("clears image settings for native fixed-page pins", function()
        ui.rolling, ui.paging = nil, {}
        ui.doc_settings:saveSetting("zen_pinned_pages", { {{ page = 8 }}, 12 })
        ui.doc_settings:saveSetting("zen_pinned_image_settings", {
            [8] = { image_full = true, image_zoom = 2 }, [12] = { image_full = false, image_zoom = 3 },
        })
        References.setPin(ui, 8, true)
        assert.same({ [12] = { image_full = false, image_zoom = 3 } },
            ui.doc_settings:readSetting("zen_pinned_image_settings"))
    end)

    it("retains anchors after repagination and reopening, separately for each book", function()
        References.setPin(ui, 8)
        References.setPin(ui, 12)
        local settings = ui.doc_settings
        ui.document.getPageFromXPointer = function(_self, xp) return tonumber(xp:match("%d+")) + 2 end
        assert.equals(14, References.pins(ui)[1].page)
        References.clear(ui)
        assert.equals(settings, ui.doc_settings)
        assert.equals(2, #References.pins(ui))
        ui.doc_settings = ZenSpec.memorySettings()
        assert.same({}, References.pins(ui))
        ui.doc_settings = settings
        assert.equals(2, #References.pins(ui))
    end)

    it("does not duplicate a stable anchor when it resolves to the next page", function()
        ui.document.getPageFromXPointer = function(_self, xp) return tonumber(xp:match("%d+")) + 1 end
        References.setPin(ui, 8)
        References.setPin(ui, 8)
        assert.equals(1, #References.pins(ui))
        assert.is_false(References.pinButtons(ui, 8)[1].enabled)
        References.pinButtons(ui, 8)[2].callback()
        assert.same({}, References.pins(ui))
    end)

    it("supports fixed-page native locations and ignores pins from another engine", function()
        ui.rolling, ui.paging = nil, {}
        ui.doc_settings:saveSetting("pinned_page", {{ page = 3 }})
        assert.equals(3, References.pinnedPage(ui))
        References.setPin(ui, 9)
        assert.equals(9, References.pins(ui)[1].page)
        References.setPin(ui, 0)
        References.setPin(ui, 101)
        assert.equals(2, #References.pins(ui))
        References.pinLocations(ui)[3] = "xp:8"
        assert.equals(2, #References.pins(ui))
    end)

    it("caches pinned pages for header paints until pins change or the book repaginates", function()
        References.setPin(ui, 8)
        local lookups = 0
        local resolve = ui.document.getPageFromXPointer
        ui.document.getPageFromXPointer = function(...) lookups = lookups + 1; return resolve(...) end
        assert.is_true(References.isPinned(ui, 8))
        assert.is_false(References.isPinned(ui, 9))
        assert.is_true(References.isPinned(ui, 8))
        assert.equals(1, lookups)

        References.setPin(ui, 9)
        assert.is_true(References.isPinned(ui, 9))
        ui.document.getPageFromXPointer = function(_self, xp) return tonumber(xp:match("%d+")) + 2 end
        assert.is_true(References.isPinned(ui, 9)) -- Same rendering: cached pages.
        ui.rolling.rendering_hash = 42
        assert.is_true(References.isPinned(ui, 11))
        assert.is_true(References.isPinned(ui, 9)) -- Anchor xpointer still matches.
        assert.is_true(References.isPinned(ui, 10))
        assert.is_false(References.isPinned(ui, 12))
    end)

    it("clears temporary state and closes the drawer on document close", function()
        local closed = 0
        ui._zen_references = { footnote = {}, drawer = { onClose = function() closed = closed + 1 end } }
        References.clear(ui)
        assert.is_nil(ui._zen_references)
        assert.equals(1, closed)
    end)

    it("pins directly from one inline icon while preserving annotations", function()
        local shown, closed
        ZenSpec.replace("ui/uimanager", { show = function(_self, dialog) shown = dialog end,
            close = function() end })
        ZenSpec.replace("ui/widget/buttondialog", { new = function(_self, spec) return spec end })
        local buttons = {{ { text = "Existing" } }}
        local close = function() closed = true end
        References.addPinButton(buttons, ui, 9, close)
        References.addPinButton(buttons, ui, 9, close)
        assert.equals(1, #buttons)
        assert.equals(2, #buttons[1])
        assert.matches("/icons/pin.svg$", buttons[1][2].icon)
        assert.is_nil(buttons[1][2].text)
        buttons[1][2].callback()
        assert.is_nil(shown)
        assert.equals(9, References.pinnedPage(ui))
        assert.is_true(References.isPinned(ui, 9))
        assert.is_false(References.isPinned(ui, 5))
        assert.is_true(closed)
        assert.equals(1, #ui.annotation.annotations)
        assert.equals(5, ui.page)
    end)

    it("replaces the inline pin with an enabled removal action for pinned pages", function()
        References.setPin(ui, 9)
        References.setPin(ui, 12)
        config.highlight_lookup = { show_labels = true }
        local closed = 0
        local buttons = {{}}
        References.addPinButton(buttons, ui, 9, function() closed = closed + 1 end)
        local button = buttons[1][1]
        assert.equals("zen_pin", button.id)
        assert.equals("Remove pin", button.text)
        assert.matches("/icons/pin_remove.svg$", button.icon)
        assert.is_not_false(button.enabled)
        button.callback()
        assert.same({ "xp:12" }, References.pinLocations(ui))
        assert.equals(1, closed)
        assert.equals(5, ui.page)
        assert.equals(1, #ui.annotation.annotations)
        local lookup = {{}}
        config.dict_quick_lookup = { show_labels = false }
        References.addPinButton(lookup, ui, 12, nil, "dict_quick_lookup")
        assert.matches("/icons/pin_remove.svg$", lookup[1][1].icon)
        assert.is_nil(lookup[1][1].text)
    end)

    it("matches the scaled bookmark size and paints transparently to its left only while pinned", function()
        local painted, freed, size = {}, 0, 10
        ZenSpec.replace("device", { screen = { getWidth = function() return 600 end,
            getHeight = function() return 800 end, scaleBySize = function(_self, value) return value end } })
        ZenSpec.replace("ui/uimanager", { setDirty = function() end })
        ui.view = { dogear = { icon = { getSize = function() return { w = 20, h = 20 } end } } }
        ZenSpec.replace("ui/widget/iconwidget", { new = function(_self, spec)
            assert.matches("/icons/pin.svg$", spec.file)
            assert.same({ size, size }, { spec.width, spec.height })
            assert.is_true(spec.alpha)
            return {
                paintTo = function(_icon, bb, x, y) painted[#painted + 1] = { bb, x, y } end,
                free = function() freed = freed + 1 end,
            }
        end })
        local bb = { paintRect = function() error("The pin must not erase its background") end }
        References.paintPin(ui, 9, bb, 10, 20, 300, 400)
        assert.equals(0, #painted)
        References.setPin(ui, 9)
        for _i, dimensions in ipairs({ { 300, 400 }, { 300, 100 }, { 100, 400 }, { 600, 800 } }) do
            size = _i == 4 and 20 or 10
            References.paintPin(ui, 9, bb, 10, 20, dimensions[1], dimensions[2])
            assert.same({ bb, 10 + dimensions[1] - size * 2 - 2, 20 }, painted[_i])
        end
        assert.equals(4, freed)
        References.setPin(ui, 9, true)
        References.paintPin(ui, 9, bb, 10, 20, 300, 400)
        assert.equals(4, #painted)
        References.setPin(ui, 9)
        config.features.reader_references = false
        References.paintPin(ui, 9, bb, 10, 20, 300, 400)
        assert.equals(4, #painted)
    end)

    it("uses the book line spacing and the shorter font-size label", function()
        ZenSpec.replace("device", { screen = { scaleBySize = function(_self, size) return size end } })
        ZenSpec.replace("ui/uimanager", {})
        ZenSpec.unload("modules/reader/pin_settings")
        local settings = { relative_font_size = 0, use_book_font = false, justify = true }
        ui.document.configurable = { font_size = 18, line_spacing = 150 }
        ui.document.getHTMLFromXPointers = function() return "<p>Reference</p>" end
        local PinSettings = require("modules/reader/pin_settings")
        local bb = require("ffi/blitbuffer")
        local _html, css = PinSettings.content(ui, 9, settings, bb.COLOR_WHITE, bb.COLOR_BLACK)
        assert.matches("line-height: 1.800", css, 1, true)
        assert.matches("p { text-indent: 1.2em; margin-top: 0; margin-bottom: 0; }", css, 1, true)
        assert.matches("h1, h2, h3, h4, h5, h6 { margin-top: 0.7em; margin-bottom: 0.5em; }", css, 1, true)
        assert.equals("Font size", PinSettings.items(ui, { config = { reader_pins = settings } })[2].text)
    end)

    it("halves the rendered book margins independently for pinned text", function()
        ZenSpec.replace("ui/uimanager", {})
        ZenSpec.unload("modules/reader/pin_settings")
        local PinSettings = require("modules/reader/pin_settings")
        local bb = require("ffi/blitbuffer")
        local settings = { relative_font_size = 0, use_book_font = false, justify = true }
        ui.document.configurable = { font_size = 18 }
        ui.document.getHTMLFromXPointers = function() return "<p>Reference</p>" end
        for _i, margins in ipairs({ { left = 31, right = 46 }, { left = 0, right = 0 } }) do
            ui.document.getPageMargins = function() return margins end
            local html, css = PinSettings.content(ui, 9, settings, bb.COLOR_WHITE, bb.COLOR_BLACK)
            assert.equals("<p>Reference</p>", html)
            assert.matches(string.format("@page { margin: 0 %gpx 0 %gpx;", margins.right / 2, margins.left / 2),
                css, 1, true)
        end
    end)

    it("keeps publisher indentation and spacing on regular and final pages", function()
        ZenSpec.replace("device", { screen = { scaleBySize = function(_self, size) return size end } })
        ZenSpec.replace("ui/uimanager", {})
        ZenSpec.unload("modules/reader/pin_settings")
        local PinSettings = require("modules/reader/pin_settings")
        local bb = require("ffi/blitbuffer")
        local settings = { relative_font_size = 0, use_book_font = false, justify = true }
        ui.document.configurable = { font_size = 18 }
        local html = '<div class="chapter"><p class="noindent">Opening</p><p>Indented</p></div>'
        local publisher = 'p { text-indent: 2em; margin: 0.5em 0; } .noindent { text-indent: 0; }'
        local inline_css = '.chapter .special { text-indent: 3em; } h2 { margin-bottom: 1em; }'
        local function extract(_self, first, last, flags, from_root)
            assert.equals("xp:9", first); assert.equals("xp:10", last)
            assert.equals(0x7001, flags); assert.is_true(from_root)
            return "<stylesheet>" .. inline_css .. "</stylesheet>" .. html, { "book.css", "missing.css" }
        end
        ui.document.getHTMLFromXPointers = extract
        ui.document.getHTMLFromXPointer = function(_self, first, flags, final_parent)
            assert.equals("xp:100", first); assert.equals(0x7001, flags); assert.is_true(final_parent)
            return "<stylesheet>" .. inline_css .. "</stylesheet>" .. html, { "book.css", "missing.css" }
        end
        ui.document.getDocumentFileContent = function(_self, path)
            if path == "book.css" then return publisher end
        end
        for _i, page in ipairs({ 9, 100 }) do
            local content, css, size = PinSettings.content(ui, page, settings, bb.COLOR_WHITE, bb.COLOR_BLACK)
            assert.equals(html, content)
            assert.equals(18, size)
            assert.matches("p { text-indent: 1.2em; margin-top: 0; margin-bottom: 0; }", css, 1, true)
            assert.matches(publisher, css, 1, true)
            assert.matches(inline_css, css, 1, true)
            assert.is_true(css:find("margin-bottom: 0.5em;", 1, true) < css:find(publisher, 1, true))
        end
        ui.document.configurable.embedded_css = 0
        local content, css = PinSettings.content(ui, 9, settings, bb.COLOR_WHITE, bb.COLOR_BLACK)
        assert.equals(html, content)
        assert.is_nil(css:find(publisher, 1, true))
        assert.is_nil(css:find(inline_css, 1, true))
    end)

    it("uses the book font height for preview line spacing", function()
        ZenSpec.replace("device", { screen = { scaleBySize = function(_self, size) return size end } })
        ZenSpec.replace("ui/uimanager", {})
        ZenSpec.replace("document/credocument", { engineInit = function()
            return { getFontFaceFilenameAndFaceIndex = function() return "/book.ttf", 2 end }
        end })
        ZenSpec.replace("ui/font", { getFace = function(_self, path, size, face_index)
            assert.equals("/book.ttf", path); assert.equals(18, size); assert.equals(2, face_index)
            return { size = size, ftsize = { getHeightAndAscender = function() return 24.4, 18 end } }
        end })
        ZenSpec.unload("modules/reader/pin_settings")
        local PinSettings = require("modules/reader/pin_settings")
        local bb = require("ffi/blitbuffer")
        local settings = { relative_font_size = 0, use_book_font = true, justify = true }
        ui.font = { font_face = "Book font" }
        ui.document.configurable = { font_size = 18, line_spacing = 150 }
        ui.document.getHTMLFromXPointers = function() return "<p>Reference</p>" end
        local html, css, _size, font_root = PinSettings.content(ui, 9, settings, bb.COLOR_WHITE, bb.COLOR_BLACK)
        assert.equals("<p>Reference</p>", html)
        assert.equals("root:/book.ttf", font_root)
        assert.matches("font-family: ZenPinFont; line-height: 2.000", css, 1, true)
        ZenSpec.replace("ui/font", { getFace = function() return nil end })
        html, css = PinSettings.content(ui, 9, settings, bb.COLOR_WHITE, bb.COLOR_BLACK)
        assert.matches("line-height: 1.800", css, 1, true)
    end)

    it("defaults pins to the right and saves either side for text and fixed-page books", function()
        ZenSpec.replace("device", { screen = {} })
        ZenSpec.replace("ui/uimanager", {})
        ZenSpec.unload("modules/reader/pin_settings")
        local settings = { side = require("config/defaults").reader_pins.side }
        local saves, refreshes = 0, 0
        local plugin = { config = { reader_pins = settings },
            saveConfig = function() saves = saves + 1 end }
        local function items()
            return require("modules/reader/pin_settings").items(ui, plugin, function() refreshes = refreshes + 1 end)
        end
        local options = items()
        local sides = options[4].sub_item_table
        assert.equals("Position", options[4].text)
        assert.equals("right", settings.side)
        assert.is_true(sides[1].radio)
        assert.is_true(sides[2].radio)
        assert.is_true(sides[2].checked_func())
        assert.is_false(sides[1].checked_func())
        sides[1].callback()
        assert.equals("left", settings.side)
        assert.is_true(sides[1].checked_func())
        assert.is_false(sides[2].checked_func())
        ui.rolling = nil
        options = items()
        for i = 1, 3 do assert.is_false(options[i].enabled) end
        options[4].sub_item_table[2].callback()
        assert.equals("right", settings.side)
        assert.equals(2, saves)
        assert.equals(2, refreshes)
    end)

    local function image_menu(image, disposable)
        local shown, opened = {}, 0
        ZenSpec.replace("ui/uimanager", { show = function(_self, widget) shown[#shown + 1] = widget end })
        ZenSpec.replace("ui/widget/buttondialog", {
            new = function(_self, spec) return spec end, onCloseWidget = function() end,
        })
        local highlight = { ui = ui, view = { screenToPageTransform = function(_self, pos) return pos end },
            onClose = function(self) self.highlight_dialog:onCloseWidget() end }
        local spec = { image = image, image_disposable = disposable }
        local menu = References.imageMenu(highlight, 9, { x = 20, y = 30 }, spec, function()
            opened = opened + 1
            return { image = spec.image }
        end)
        return menu, highlight, shown, function() return opened end
    end

    it("offers image viewing and pinning without creating a text selection", function()
        local freed = 0
        local menu, highlight, shown, opened = image_menu({ free = function() freed = freed + 1 end })
        assert.equals("highlight_image_dialog", menu.name)
        assert.equals(1, #menu.buttons)
        assert.equals(2, #menu.buttons[1])
        assert.is_nil(menu.buttons[1][1].text)
        assert.matches("/icons/fullscreen.svg$", menu.buttons[1][1].icon)
        assert.equals("zen_pin", menu.buttons[1][2].id)
        assert.matches("/icons/pin.svg$", menu.buttons[1][2].icon)
        assert.is_nil(highlight.selected_text)
        assert.equals(0, opened())
        menu.buttons[1][1].callback()
        assert.equals(1, opened())
        assert.equals(1, #shown)
        assert.is_nil(highlight.highlight_dialog)
        assert.equals(0, freed)
    end)

    it("uses the highlight label preference for both image actions", function()
        local prepared, applied
        ZenSpec.replace("common/ui/button_labels", {
            prepare = function(buttons) prepared = buttons; return buttons end,
            apply = function(_table, buttons) applied = buttons end,
        })
        config.highlight_lookup = { show_labels = true }
        local menu = image_menu({ free = function() end })
        assert.equals("View image", menu.buttons[1][1].text)
        assert.equals("Pin", menu.buttons[1][2].text)
        assert.equals(menu.buttons, prepared)
        assert.equals(prepared, applied)
    end)

    it("persists only the held image anchor across reopening and repagination", function()
        ui.document._document = { getTextFromPositions = function(_self, x0, y0, x1, y1, draw, segments, images)
            assert.same({ 20, 30, 20, 30 }, { x0, y0, x1, y1 })
            assert.is_false(draw); assert.is_false(segments); assert.is_true(images)
            return { pos0 = "/body/p/text().0" }
        end, getWordBoxesFromPositions = function(_self, first, last, segments, images)
            assert.equals(first, last); assert.is_true(segments); assert.is_true(images)
            if first == "/body/p/img[1].0" then return {{ x0 = 0, y0 = 0, x1 = 10, y1 = 10 }} end
            assert.equals("/body/p/img[2].0", first)
            return {{ x0 = 10, y0 = 20, x1 = 40, y1 = 50 }}
        end }
        ui.document.getHTMLFromXPointer = function(_self, xp, flags, from_parent)
            assert.equals("/body/p", xp); assert.equals(0x8000, flags); assert.is_false(from_parent)
            return "", {}, "0\t4\t12\tp\n3\t5\t16\timg\n5\t5\n5\t5\t20\timg\n7\t5\n7\t4\n"
        end
        local freed = 0
        local menu = image_menu({ free = function() freed = freed + 1 end })
        menu.buttons[1][2].callback()
        assert.equals(1, freed)
        assert.same({ "/body/p/img[2].0" }, References.pinLocations(ui))
        assert.equals("/body/p/img[2].0", ui.doc_settings:readSetting("pinned_page"))
        References.clear(ui)
        ui.document.getPageFromXPointer = function(_self, xp)
            return xp:find("img", 1, true) and 12 or 11
        end
        local pin = References.pins(ui)[1]
        assert.equals("/body/p/img[2].0", pin.image)
        assert.equals(12, pin.page)
        assert.is_true(References.isPinned(ui, 12))
        assert.is_false(References.isPinned(ui, 11))
        References.setPin(ui, pin.page, true)
        assert.same({}, References.pinLocations(ui))
        assert.is_nil(ui.doc_settings:readSetting("zen_pinned_images")["/body/p/img[2].0"])
    end)

    it("releases unused images once and retains borrowed panel images", function()
        local freed = 0
        local image = { free = function() freed = freed + 1 end }
        local menu = image_menu(image)
        menu:onCloseWidget()
        menu:onCloseWidget()
        assert.equals(1, freed)
        image_menu(image, false):onCloseWidget()
        assert.equals(1, freed)
        image_menu(function(scale) assert.is_false(scale); freed = freed + 1 end):onCloseWidget()
        assert.equals(2, freed)
    end)

    it("finds a nested image beyond text-only ancestors and resets sibling counts", function()
        ui.document._document = {
            getTextFromPositions = function() return { pos0 = "/body/h1/text().0" } end,
            getWordBoxesFromPositions = function(_self, xp)
                if xp == "/body/p[1]/a[1]/img[1].0" then
                    return {{ x0 = 0, y0 = 0, x1 = 10, y1 = 10 }}
                end
                assert.equals("/body/p[2]/a[1]/svg[1].0", xp)
                return {{ x0 = 10, y0 = 20, x1 = 40, y1 = 50 }}
            end,
        }
        ui.document.getPageFromXPointer = function() return 9 end
        ui.document.getHTMLFromXPointer = function(_self, xp)
            if xp == "/body/h1" then return "", {}, "0\t1\t1\th1\n2\t1\n" end
            assert.equals("/body", xp)
            return "", {}, "0\t0\t1\tbody\n1\t1\t2\tp\n2\t2\t3\ta\n3\t3\t4\timg\n"
                .. "4\t3\n4\t2\n4\t1\n5\t1\t5\tp\n6\t2\t6\ta\n7\t3\t7\tsvg\n"
        end
        local menu = image_menu({ free = function() end })
        menu.buttons[1][2].callback()
        assert.equals("/body/p[2]/a[1]/svg[1].0", References.pins(ui)[1].image)
    end)

    it("restores the last opened pin across reopening, repagination and earlier pin removal", function()
        local shown
        ZenSpec.replace("modules/reader/reference_drawer", { new = function(_self, spec) return spec end })
        ZenSpec.replace("ui/uimanager", { show = function(_self, dialog) shown = dialog end })
        References.setPin(ui, 4)
        References.setPin(ui, 9)
        References.setPin(ui, 12)
        assert.same({ "xp:12", "xp:9", "xp:4" }, References.pinLocations(ui))
        assert.is_true(References.openPinned(ui))
        assert.equals(12, shown.page) -- The newest pin is on top and opens first.
        References.openPinned(ui, 2)
        assert.equals("xp:9", ui.doc_settings:readSetting("zen_last_pinned_page"))
        References.clear(ui)
        References.openPinned(ui)
        assert.equals(9, shown.page)
        assert.equals(2, shown.pin_index)
        ui.document.getPageFromXPointer = function(_self, xp) return tonumber(xp:match("%d+")) + 2 end
        References.openPinned(ui)
        assert.equals(11, shown.page)
        References.setPin(ui, 6, true)
        References.openPinned(ui)
        assert.equals(11, shown.page)
        assert.equals(2, shown.pin_index)
        References.openPinned(ui, 1)
        assert.equals(14, shown.page)
        References.setPin(ui, 14, true)
        References.openPinned(ui)
        assert.equals(11, shown.page)
        local settings = ui.doc_settings
        ui.doc_settings = ZenSpec.memorySettings()
        References.setPin(ui, 20)
        References.openPinned(ui)
        assert.equals(22, shown.page)
        ui.doc_settings = settings
        References.openPinned(ui)
        assert.equals(11, shown.page)
        assert.equals(5, ui.page)
        assert.equals(2, #ui.link.location_stack)
    end)

    it("remembers fixed-page pins including native locations", function()
        local shown
        ZenSpec.replace("modules/reader/reference_drawer", { new = function(_self, spec) return spec end })
        ZenSpec.replace("ui/uimanager", { show = function(_self, dialog) shown = dialog end })
        ui.rolling, ui.paging = nil, {}
        ui.doc_settings:saveSetting("zen_pinned_pages", { 4, {{ page = 9 }} })
        References.openPinned(ui, 2)
        assert.equals(9, ui.doc_settings:readSetting("zen_last_pinned_page"))
        ui.doc_settings:saveSetting("zen_pinned_pages", { 4, {{ page = 9 }} })
        References.clear(ui)
        References.openPinned(ui)
        assert.equals(9, shown.page)
        assert.equals(2, shown.pin_index)
    end)

    it("keeps reading position, history and last pin after a preview failure", function()
        local shown
        ui.doc_settings:saveSetting("zen_pinned_pages", { "xp:9", "xp:12" })
        ui.doc_settings:saveSetting("zen_last_pinned_page", "xp:12")
        ZenSpec.replace("modules/reader/reference_drawer", { new = function() error("render failed") end })
        ZenSpec.replace("logger", { warn = function() end })
        ZenSpec.replace("ui/uimanager", { show = function(_self, dialog) shown = dialog end })
        ZenSpec.replace("ui/widget/infomessage", { new = function(_self, spec) return spec end })
        assert.is_false(References.openPinned(ui, 1))
        assert.equals("Unable to open reference preview.", shown.text)
        assert.equals(5, ui.page)
        assert.equals(2, #ui.link.location_stack)
        assert.equals("xp:12", ui.doc_settings:readSetting("zen_last_pinned_page"))
    end)
end)

describe("native footnote adapter", function()
    local names = { "modules/reader/references", "modules/reader/reference_drawer",
        "apps/reader/modules/readerlink", "apps/reader/modules/readerdictionary",
        "ui/widget/footnotewidget", "modules/reader/patches/reader_references",
        "modules/reader/pin_footer", "apps/reader/modules/readergoto",
        "apps/reader/modules/readerhighlight", "ui/widget/imageviewer", "device",
        "apps/reader/modules/readerrolling", "ui/uimanager" }
    local saved, saved_settings, Footnote, ReaderLink, ReaderHighlight, ImageViewer, ReaderRolling, ui, enabled
    local scheduled

    before_each(function()
        saved = {}
        for _i, name in ipairs(names) do saved[name] = package.loaded[name] end
        saved_settings = G_reader_settings
        _G.G_reader_settings = ZenSpec.memorySettings()
        G_reader_settings.isFalse = function(self, key) return self:readSetting(key) == false end
        ZenSpec.replace("device", { screen = { scaleByDPI = function(_self, value) return 2 * value end } })
        enabled, ui = true, {}
        Footnote = { new = function(_self, spec) return spec end }
        ReaderLink = { onReadSettings = function() return "native settings" end,
            onTap = function(self) return self.native_tap_result end,
            showAsFootnotePopup = function(_self, link)
            if link.fail then error("extraction failed", 0) end
            if link.ordinary then return false end
            return Footnote:new{ html = "Native content", follow_callback = function() end }
        end }
        ZenSpec.replace("modules/reader/references", { configure = function() end,
            applyDefaults = function(reader) reader.defaults = true end,
            enabled = function() return enabled end, clear = function(reader) reader.cleared = true end,
            selectionPage = function(highlight) return highlight.page end,
            imageMenu = function(_highlight, page, position, spec, open)
                return { image_menu = true, page = page, position = position, image = spec.image, open = open }
            end })
        ZenSpec.replace("modules/reader/reference_drawer", { new = function(_self, spec)
            spec.drawer = true; return spec
        end })
        ZenSpec.replace("apps/reader/modules/readerlink", ReaderLink)
        ZenSpec.replace("apps/reader/modules/readerdictionary", { onLookupWord = function() return true end })
        ZenSpec.replace("modules/reader/pin_footer", { apply = function() end })
        ZenSpec.replace("apps/reader/modules/readergoto", {})
        ImageViewer = { new = function(_self, spec) return { native = true, image = spec.image } end }
        ReaderHighlight = { onHold = function(_self, _arg, ges)
            if ges.fail then error("hold failed", 0) end
            if ges.text then return "text selection" end
            return ImageViewer:new{ image = "native image" }
        end }
        ZenSpec.replace("apps/reader/modules/readerhighlight", ReaderHighlight)
        ZenSpec.replace("ui/widget/imageviewer", ImageViewer)
        ZenSpec.replace("ui/widget/footnotewidget", Footnote)
        ReaderRolling = { onGotoXPointer = function(self, xp, marker_xp)
            self.went, self.marker = xp, marker_xp
            return true
        end }
        ZenSpec.replace("apps/reader/modules/readerrolling", ReaderRolling)
        scheduled = {}
        ZenSpec.replace("ui/uimanager", {
            scheduleIn = function(_self, delay, callback) scheduled[callback] = delay end,
            unschedule = function(_self, callback) scheduled[callback] = nil end,
            setDirty = function() end,
        })
        ZenSpec.unload("modules/reader/patches/reader_references")
        require("modules/reader/patches/reader_references")()
    end)

    after_each(function()
        _G.G_reader_settings = saved_settings
        for _i, name in ipairs(names) do package.loaded[name] = saved[name] end
    end)

    it("adds a small scaled internal-link tap allowance after precise detection misses", function()
        local ges = { pos = { x = 100, y = 200 } }
        local probed, targets = {}, { ["100,184"] = "#note", ["116,200"] = "http://example.com" }
        local link = setmetatable({ ui = ui,
            getLinkFromGes = function(_self, gesture)
                local key = gesture.pos.x .. "," .. gesture.pos.y
                probed[#probed + 1] = key
                return targets[key] and { xpointer = targets[key] }
            end,
            onGotoLink = function(_self, target, neglect, popup)
                assert.equals("#note", target.xpointer)
                assert.is_false(neglect)
                assert.is_true(popup)
                return "nearby link"
            end,
            onGoToPageLink = function() error("scanned page links") end,
        }, { __index = ReaderLink })
        G_reader_settings:saveSetting("footnote_link_in_popup", true)
        assert.equals("nearby link", link:onTap(nil, ges))
        assert.same({ "116,200", "84,200", "100,216", "100,184" }, probed)
        targets["100,184"] = nil
        assert.is_nil(link:onTap(nil, ges))
        link.native_tap_result = "precise link"
        assert.equals("precise link", link:onTap(nil, ges))
        link.native_tap_result = nil
        enabled = false
        assert.is_nil(link:onTap(nil, ges))
        enabled, ui.paging = true, {}
        assert.is_nil(link:onTap(nil, ges))
        ui.paging = nil
        G_reader_settings:saveSetting("tap_to_follow_links", false)
        assert.is_nil(link:onTap(nil, ges))
        G_reader_settings:delSetting("tap_to_follow_links")
        G_reader_settings:saveSetting("larger_tap_area_to_follow_links", true)
        assert.is_nil(link:onTap(nil, ges))
    end)

    it("reuses native content and restores the factory", function()
        local factory = Footnote.new
        local link = { xpointer = "note" }
        local result = ReaderLink.showAsFootnotePopup({ ui = ui }, link)
        assert.is_true(result.drawer)
        assert.equals("Native content", result.footnote.html)
        assert.equals(link, result.link)
        assert.equals(factory, Footnote.new)
        assert.has_error(function() ReaderLink.showAsFootnotePopup({ ui = ui }, { fail = true }) end, "extraction failed")
        assert.equals(factory, Footnote.new)
    end)

    it("intercepts image holds and restores native image viewing and text selection", function()
        local factory = ImageViewer.new
        local pos = { x = 10, y = 20 }
        local highlight = { ui = ui, view = { screenToPageTransform = function() return { page = 7 } end } }
        local menu = ReaderHighlight.onHold(highlight, nil, { pos = pos })
        assert.is_true(menu.image_menu)
        assert.equals(7, menu.page)
        assert.equals(pos, menu.position)
        assert.equals("native image", menu.image)
        assert.equals(factory, ImageViewer.new)
        assert.is_true(menu.open().native)
        assert.equals("text selection", ReaderHighlight.onHold(highlight, nil, { text = true }))
        assert.equals(factory, ImageViewer.new)
        assert.has_error(function() ReaderHighlight.onHold(highlight, nil, { fail = true }) end, "hold failed")
        assert.equals(factory, ImageViewer.new)
        enabled = false
        assert.is_true(ReaderHighlight.onHold(highlight, nil, {}).native)
    end)

    it("flashes the followed link instead of the stock margin marker", function()
        local highlighted = {}
        local long = ("x"):rep(1001)
        local texts = { link = "Note text", other = "Note text", chapter = long, anchor = " ", note = long,
            ["/p/a"] = "[1]", ["/section/h1"] = "Title", ["/p"] = long }
        local words = { note = "/p/a/text().1", anchor = "/p/a/text()[2].0", chapter = "/section/h1/text().0",
            blob = "/p/text().0" }
        ui.document = {
            highlightXPointer = function(_self, xp)
                if xp then highlighted[#highlighted + 1] = xp else highlighted = {} end
                return true
            end,
            getTextFromXPointer = function(_self, xp) return texts[xp] end,
            getNextVisibleWordStart = function(_self, xp) return words[xp] end,
        }
        local rolling = { ui = ui, view = {} }
        assert.is_true(ReaderRolling.onGotoXPointer(rolling, "top", "link"))
        assert.equals("top", rolling.went)
        assert.is_nil(rolling.marker)
        assert.same({ "link" }, highlighted)
        assert.equals(1, scheduled[rolling._zen_unmark])
        ui._zen_references = { drawer = {} }
        rolling._zen_unmark()
        assert.same({ "link" }, highlighted)
        ui._zen_references = nil
        ReaderRolling.onGotoXPointer(rolling, "top", "link")
        rolling._zen_unmark()
        assert.same({}, highlighted)
        for target, node in pairs({ note = "/p/a", anchor = "/p/a", chapter = "/section/h1" }) do
            ReaderRolling.onGotoXPointer(rolling, "top", target)
            assert.is_nil(rolling.marker)
            assert.same({ node }, highlighted)
            rolling._zen_unmark()
        end
        for _i, target in ipairs({ "blob", "missing" }) do
            ReaderRolling.onGotoXPointer(rolling, "top", target)
            assert.equals(target, rolling.marker)
            assert.same({}, highlighted)
        end
        G_reader_settings:saveSetting("followed_link_marker", false)
        ReaderRolling.onGotoXPointer(rolling, "top", "link")
        assert.equals("link", rolling.marker)
        G_reader_settings:delSetting("followed_link_marker")
        enabled = false
        ReaderRolling.onGotoXPointer(rolling, "top", "other")
        assert.equals("other", rolling.marker)
        assert.same({}, highlighted)
    end)

    it("applies popup defaults when a book opens", function()
        assert.equals("native settings", ReaderLink.onReadSettings({ ui = ui }))
        assert.is_true(ui.defaults)
    end)

    it("preserves disabled popups, ordinary links and close cleanup", function()
        assert.is_false(ReaderLink.showAsFootnotePopup({ ui = ui }, { ordinary = true }))
        enabled = false
        assert.is_nil(ReaderLink.showAsFootnotePopup({ ui = ui }, {}).drawer)
        ReaderLink.onCloseDocument({ ui = ui })
        assert.is_true(ui.cleared)
    end)

    it("captures the page before asynchronous lookup clears the selection", function()
        ui.highlight = { selected_text = {}, page = 12 }
        local dictionary = setmetatable({ ui = ui }, { __index = require("apps/reader/modules/readerdictionary") })
        assert.is_true(dictionary:onLookupWord("word"))
        ui.highlight.selected_text = nil
        assert.equals(12, dictionary._zen_reference_page)
        dictionary:onLookupWord("standalone lookup")
        assert.is_nil(dictionary._zen_reference_page)
    end)
end)
