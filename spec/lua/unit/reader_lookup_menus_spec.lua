describe("reader lookup menus", function()
    local shown

    local function logger_stub()
        return { dbg = function() end, warn = function() end, err = function() end }
    end

    before_each(function()
        shown = nil
        _G.__ZEN_UI_PLUGIN = nil
        ZenSpec.replace("common/zen_logger", { new = logger_stub })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/widget/iconwidget", {
            init = function(self) self.file = "resources/icons/icon-not-found.svg" end,
        })
        ZenSpec.replace("ui/event", {
            new = function(_, name, ...)
                return { handler = "on" .. name, args = { ... }, name = name }
            end,
        })
        ZenSpec.replace("ui/uimanager", {
            show = function(_, widget) shown = widget end,
            scheduleIn = function(_, _, callback) callback() end,
            setDirty = function() end,
            nextTick = function(_, callback) callback() end,
        })
    end)

    after_each(function()
        _G.__ZEN_UI_PLUGIN = nil
        ZenSpec.unload("modules/reader/patches/highlight_menu")
        ZenSpec.unload("modules/reader/patches/dict_quick_lookup")
    end)

    it("renders the enabled highlight actions and dispatches their callbacks", function()
        local dialog_spec
        ZenSpec.replace("ui/widget/buttondialog", {
            new = function(_, spec)
                dialog_spec = spec
                return spec
            end,
        })
        local ReaderHighlight = { onShowHighlightMenu = function() return "stock" end }
        ZenSpec.replace("apps/reader/modules/readerhighlight", ReaderHighlight)
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { highlight_lookup = true },
                highlight_lookup = { show_wikipedia = true },
            },
        }
        require("modules/reader/patches/highlight_menu")()

        local calls, events = {}, {}
        local highlight = {
            selected_text = { text = "deterministic" },
            hold_pos = { x = 10, y = 20 },
            ui = { handleEvent = function(_, event) events[#events + 1] = event end },
            saveHighlight = function(_, close) calls.saved = close end,
            onClose = function() calls.closed = (calls.closed or 0) + 1 end,
            lookupWikipedia = function() calls.wikipedia = true end,
            translate = function(_, index) calls.translated = index end,
            onHighlightSearch = function() calls.searched = true end,
            _getDialogAnchor = function() return { x = 1, y = 2 } end,
        }
        ReaderHighlight.onShowHighlightMenu(highlight, 7)

        assert.are.equal(dialog_spec, shown)
        assert.same({
            "lookup.highlight", "lookup.wikipedia", "lookup.dictionary",
            "lookup.translate", "lookup.search",
        }, (function()
            local icons = {}
            for _i, button in ipairs(dialog_spec.buttons[1]) do
                icons[#icons + 1] = button.icon
            end
            return icons
        end)())
        dialog_spec.buttons[1][1].callback()
        dialog_spec.buttons[1][2].callback()
        dialog_spec.buttons[1][3].callback()
        dialog_spec.buttons[1][4].callback()
        dialog_spec.buttons[1][5].callback()
        assert.is_true(calls.saved)
        assert.is_true(calls.wikipedia)
        assert.are.equal(7, calls.translated)
        assert.is_true(calls.searched)
        assert.are.equal(2, calls.closed)
        assert.are.equal("LookupWord", events[1].name)
        assert.same({ "deterministic", true }, events[1].args)
    end)

    it("delegates the highlight menu when disabled and ignores empty selections", function()
        local stock_calls = 0
        local ReaderHighlight = {
            onShowHighlightMenu = function()
                stock_calls = stock_calls + 1
                return "stock"
            end,
        }
        ZenSpec.replace("apps/reader/modules/readerhighlight", ReaderHighlight)
        ZenSpec.replace("ui/widget/buttondialog", { new = function(_, spec) return spec end })
        _G.__ZEN_UI_PLUGIN = { config = { features = { highlight_lookup = false } } }
        require("modules/reader/patches/highlight_menu")()
        assert.are.equal("stock", ReaderHighlight.onShowHighlightMenu({}))
        assert.are.equal(1, stock_calls)

        _G.__ZEN_UI_PLUGIN.config.features.highlight_lookup = true
        assert.is_nil(ReaderHighlight.onShowHighlightMenu({}))
        assert.is_nil(shown)
    end)

    it("saves a new highlight without offering Extend", function()
        ZenSpec.replace("ui/widget/buttondialog", { new = function(_, spec) return spec end })
        local ReaderHighlight = { onShowHighlightMenu = function() return "stock" end }
        ZenSpec.replace("apps/reader/modules/readerhighlight", ReaderHighlight)
        _G.__ZEN_UI_PLUGIN = {
            config = { features = { highlight_lookup = true }, highlight_lookup = {} },
        }
        require("modules/reader/patches/highlight_menu")()

        local saved, selected = false, false
        local select_callback = function() selected = true end
        local highlight = {
            selected_text = { text = "start of a multipage highlight" },
            hold_pos = { x = 10, y = 20 },
            saveHighlight = function() saved = true end,
            onClose = function() end,
            _highlight_buttons = {
                ["01_select"] = function(this, index)
                    assert.are.equal("start of a multipage highlight", this.selected_text.text)
                    assert.is_nil(index)
                    return { enabled = true, callback = select_callback }
                end,
            },
        }
        ReaderHighlight.onShowHighlightMenu(highlight)

        assert.same({ "lookup.highlight", "lookup.dictionary", "lookup.translate", "lookup.search" }, {
            shown.buttons[1][1].icon, shown.buttons[1][2].icon,
            shown.buttons[1][3].icon, shown.buttons[1][4].icon,
        })
        assert.are.equal(4, #shown.buttons[1])
        assert.are.equal(1, #shown.buttons)
        shown.buttons[1][1].callback()
        assert.is_true(saved)
        assert.is_false(selected)
    end)

    it("shows KOReader's extend action for an existing highlight", function()
        local dialog_spec
        ZenSpec.replace("ui/widget/buttondialog", {
            new = function(_, spec)
                dialog_spec = spec
                return spec
            end,
        })
        local ReaderHighlight = { onShowHighlightMenu = function() return "stock" end }
        ZenSpec.replace("apps/reader/modules/readerhighlight", ReaderHighlight)
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { highlight_lookup = true },
                highlight_lookup = { allow_unknown_items = true },
            },
        }
        require("modules/reader/patches/highlight_menu")()

        local extended_index, highlight_text_edited
        local highlight = {
            selected_text = { text = "existing highlight" },
            ui = { handleEvent = function() end },
            translate = function() end,
            onHighlightSearch = function() end,
            _getDialogAnchor = function() return {} end,
            _highlight_buttons = {
                ["01_select"] = function(_, index)
                    return {
                        enabled = not highlight_text_edited,
                        callback = function() extended_index = index end,
                    }
                end,
            },
        }
        ReaderHighlight.onShowHighlightMenu(highlight, 3)

        assert.are.equal(ZenSpec.root .. "/icons/lookup_extend.svg", dialog_spec.buttons[1][1].icon)
        local icon_widget = { icon = dialog_spec.buttons[1][1].icon }
        require("ui/widget/iconwidget").init(icon_widget)
        assert.are.equal(ZenSpec.root .. "/icons/lookup_extend.svg", icon_widget.file)
        assert.is_true(dialog_spec.buttons[1][1].enabled)
        assert.are.equal(1, #dialog_spec.buttons)
        dialog_spec.buttons[1][1].callback()
        assert.are.equal(3, extended_index)

        highlight_text_edited = true
        ReaderHighlight.onShowHighlightMenu(highlight, 3)
        assert.is_false(dialog_spec.buttons[1][1].enabled)
    end)

    it("anchors the highlight menu outside the selected text", function()
        local dialog_spec
        ZenSpec.replace("ui/size", { padding = { small = 4 } })
        ZenSpec.replace("ui/widget/buttondialog", {
            new = function(_, spec)
                dialog_spec = spec
                spec.getContentSize = function() return { w = 200 } end
                return spec
            end,
        })
        local ReaderHighlight = { onShowHighlightMenu = function() end }
        ZenSpec.replace("apps/reader/modules/readerhighlight", ReaderHighlight)
        _G.__ZEN_UI_PLUGIN = {
            config = { features = { highlight_lookup = true }, highlight_lookup = {} },
        }
        require("modules/reader/patches/highlight_menu")()

        local highlight = {
            selected_text = {
                text = "selected",
                sboxes = { { y = 300, h = 20 }, { y = 100, h = 20 } },
            },
            screen_w = 600,
            screen_h = 800,
            ui = { handleEvent = function() end },
            onClose = function() end,
            translate = function() end,
            onHighlightSearch = function() end,
        }
        ReaderHighlight.onShowHighlightMenu(highlight)

        local anchor, prefers_below = dialog_spec.anchor()
        assert.same({ x = 200, y = 96, w = 0, h = 228 }, anchor)
        assert.is_true(prefers_below)

        highlight.selected_text.sboxes = { { y = 650, h = 20 }, { y = 700, h = 20 } }
        anchor, prefers_below = dialog_spec.anchor()
        assert.same({ x = 200, y = 646, w = 0, h = 78 }, anchor)
        assert.is_false(prefers_below)
    end)

    it("shows recognized highlight plugins by default and honors their toggles", function()
        local dialog_spec
        ZenSpec.replace("ui/widget/buttondialog", {
            new = function(_, spec)
                dialog_spec = spec
                return spec
            end,
        })
        local ReaderHighlight = { onShowHighlightMenu = function() return "stock" end }
        ZenSpec.replace("apps/reader/modules/readerhighlight", ReaderHighlight)
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { highlight_lookup = true },
                highlight_lookup = { show_koassistant = false },
            },
        }
        require("modules/reader/patches/highlight_menu")()

        local highlight = {
            selected_text = { text = "plugins" },
            ui = { handleEvent = function() end },
            onClose = function() end,
            translate = function() end,
            onHighlightSearch = function() end,
            _getDialogAnchor = function() return {} end,
            _highlight_buttons = {
                xray_lookup = function() return { text = "X-Ray" } end,
                koassistant_dialog = function() return { text = "Chat/Action (KOA)" } end,
                unrelated = function() return { text = "Other" } end,
            },
        }
        ReaderHighlight.onShowHighlightMenu(highlight)
        assert.are.equal("X-Ray", dialog_spec.buttons[2][1].text)
        assert.are.equal(2, #dialog_spec.buttons)

        _G.__ZEN_UI_PLUGIN.config.highlight_lookup.show_xray = false
        _G.__ZEN_UI_PLUGIN.config.highlight_lookup.show_koassistant = true
        ReaderHighlight.onShowHighlightMenu(highlight)
        assert.are.equal("Chat/Action (KOA)", dialog_spec.buttons[2][1].text)
        assert.are.equal(2, #dialog_spec.buttons)

        _G.__ZEN_UI_PLUGIN.config.highlight_lookup.allow_unknown_items = true
        ReaderHighlight.onShowHighlightMenu(highlight)
        assert.are.same({ "Chat/Action (KOA)", "Other" }, {
            dialog_spec.buttons[2][1].text,
            dialog_spec.buttons[2][2].text,
        })
    end)

    it("turns dictionary buttons into the configured icon row", function()
        local translated
        local original = {
            { { id = "highlight", callback = function() end }, { id = "wikipedia" } },
            { { id = "search" }, { id = "third_party", text = "Extra" } },
        }
        local DictQuickLookup = {
            buildButtonLayout = function() return original end,
        }
        ZenSpec.replace("ui/widget/dictquicklookup", DictQuickLookup)
        ZenSpec.replace("apps/reader/modules/readerhighlight", {})
        ZenSpec.replace("ui/translator", {
            showTranslation = function(_, word, is_quick_lookup)
                translated = { word, is_quick_lookup }
            end,
        })
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { dict_quick_lookup = true },
                highlight_lookup = { show_wikipedia = true, allow_unknown_items = true },
            },
        }
        require("modules/reader/patches/dict_quick_lookup")()

        local result = DictQuickLookup.buildButtonLayout({
            highlight = {},
            lookupword = "deterministic",
        })
        assert.same({
            "lookup.highlight", "lookup.wikipedia", "lookup.translate", "lookup.search",
        }, (function()
            local icons = {}
            for _i, button in ipairs(result[1]) do icons[#icons + 1] = button.icon end
            return icons
        end)())
        assert.are.equal("third_party", result[2][1].id)
        assert.are.equal("Extra", result[2][1].text)
        result[1][3].callback()
        assert.same({ "deterministic", true }, translated)
    end)

    it("recognizes localized id-less vocabulary buttons on the new API", function()
        local translated_label = "添加到生词本"
        ZenSpec.replace("gettext", function(text)
            if text == "Add to vocabulary builder" then return translated_label end
            return text
        end)
        local DictQuickLookup = {
            buildButtonLayout = function()
                return {
                    { { id = "highlight", callback = function() end }, { id = "search" } },
                    { { text = translated_label } },
                }
            end,
        }
        ZenSpec.replace("ui/widget/dictquicklookup", DictQuickLookup)
        ZenSpec.replace("apps/reader/modules/readerhighlight", {})
        ZenSpec.replace("ui/translator", {})
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { dict_quick_lookup = true },
                highlight_lookup = {},
            },
        }
        require("modules/reader/patches/dict_quick_lookup")()

        local events = {}
        local result = DictQuickLookup.buildButtonLayout({
            highlight = {},
            lookupword = "本",
            ui = { handleEvent = function(_, event) events[#events + 1] = event end },
        })
        assert.are.equal("vocabulary", result[1][2].id)
        assert.are.equal("lookup.vocab", result[1][2].icon)
        assert.are.equal(1, #result)
        result[1][2].callback()
        assert.are.equal("WordLookedUp", events[1].name)
        assert.are.equal("本", events[1].args[1])
    end)

    it("shows recognized dictionary plugins by default and honors their toggles", function()
        local original = {
            { { id = "highlight", callback = function() end }, { id = "search" } },
            {
                { id = "xray_lookup", text = "X-Ray" },
                { id = "koassistant_dict_01_explain", text = "Explain (KOA)" },
                { id = "third_party", text = "Other" },
            },
        }
        local DictQuickLookup = { buildButtonLayout = function() return original end }
        ZenSpec.replace("ui/widget/dictquicklookup", DictQuickLookup)
        ZenSpec.replace("apps/reader/modules/readerhighlight", {})
        ZenSpec.replace("ui/translator", {})
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { dict_quick_lookup = true },
                highlight_lookup = { show_koassistant = false },
            },
        }
        require("modules/reader/patches/dict_quick_lookup")()

        local result = DictQuickLookup.buildButtonLayout({ highlight = {} })
        assert.are.equal("xray_lookup", result[2][1].id)
        assert.are.equal(2, #result)

        _G.__ZEN_UI_PLUGIN.config.highlight_lookup.show_xray = false
        _G.__ZEN_UI_PLUGIN.config.highlight_lookup.show_koassistant = true
        result = DictQuickLookup.buildButtonLayout({ highlight = {} })
        assert.are.equal("koassistant_dict_01_explain", result[2][1].id)
        assert.are.equal(2, #result)

        _G.__ZEN_UI_PLUGIN.config.highlight_lookup.allow_unknown_items = true
        result = DictQuickLookup.buildButtonLayout({ highlight = {} })
        assert.are.equal("third_party", result[3][1].id)
    end)

    it("preserves id-less X-Ray and KOAssistant buttons on the legacy API", function()
        local ReaderHighlight = {}
        local original = {
            { { id = "highlight", callback = function() end }, { id = "search" } },
        }
        local DictQuickLookup = {
            init = function(self)
                local buttons = {
                    { original[1][1], original[1][2] },
                }
                self.ui:handleEvent({
                    handler = "onDictButtonsReady",
                    args = { self, buttons },
                })
                self.final_buttons = buttons
            end,
        }
        ZenSpec.replace("ui/widget/dictquicklookup", DictQuickLookup)
        ZenSpec.replace("apps/reader/modules/readerhighlight", ReaderHighlight)
        ZenSpec.replace("ui/translator", {})
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { dict_quick_lookup = true },
                highlight_lookup = { show_koassistant = false },
            },
        }
        require("modules/reader/patches/dict_quick_lookup")()

        local lookup = {
            lookupword = "plugins",
            highlight = {},
            ui = {
                handleEvent = function(_, event)
                    ReaderHighlight.onDictButtonsReady(
                        {}, event.args[1], event.args[2])
                    table.insert(event.args[2], {
                        { text = "X-Ray" },
                        { text = "Explain (KOA)" },
                        { text = "Other" },
                    })
                end,
            },
        }
        DictQuickLookup.init(lookup)
        assert.are.equal("X-Ray", lookup.final_buttons[2][1].text)
        assert.are.equal(2, #lookup.final_buttons)

        _G.__ZEN_UI_PLUGIN.config.highlight_lookup.show_xray = false
        _G.__ZEN_UI_PLUGIN.config.highlight_lookup.show_koassistant = true
        DictQuickLookup.init(lookup)
        assert.are.equal("Explain (KOA)", lookup.final_buttons[2][1].text)
        assert.are.equal(2, #lookup.final_buttons)
    end)

    it("recognizes localized id-less vocabulary buttons on the legacy API", function()
        local translated_label = "添加到生词本"
        ZenSpec.replace("gettext", function(text)
            if text == "Add to vocabulary builder" then return translated_label end
            return text
        end)
        local ReaderHighlight = {}
        local DictQuickLookup = {
            init = function(self)
                local buttons = {
                    { { id = "highlight", callback = function() end }, { id = "search" } },
                }
                self.ui:handleEvent({
                    handler = "onDictButtonsReady",
                    args = { self, buttons },
                })
                self.final_buttons = buttons
            end,
        }
        ZenSpec.replace("ui/widget/dictquicklookup", DictQuickLookup)
        ZenSpec.replace("apps/reader/modules/readerhighlight", ReaderHighlight)
        ZenSpec.replace("ui/translator", {})
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { dict_quick_lookup = true },
                highlight_lookup = {},
            },
        }
        require("modules/reader/patches/dict_quick_lookup")()

        local lookup = {
            lookupword = "本",
            highlight = {},
            ui = {
                handleEvent = function(_, event)
                    ReaderHighlight.onDictButtonsReady(
                        {}, event.args[1], event.args[2])
                    table.insert(event.args[2], { { text = translated_label } })
                end,
            },
        }
        DictQuickLookup.init(lookup)
        assert.are.equal(1, #lookup.final_buttons)
        assert.are.equal("vocabulary", lookup.final_buttons[1][2].id)
        assert.are.equal("lookup.vocab", lookup.final_buttons[1][2].icon)
    end)

    it("toggles an existing dictionary highlight off and closes the lookup", function()
        local original_adds, deleted, closes = 0, nil, 0
        local DictQuickLookup = {
            buildButtonLayout = function()
                return { { { id = "highlight", callback = function() original_adds = original_adds + 1 end } } }
            end,
        }
        ZenSpec.replace("ui/widget/dictquicklookup", DictQuickLookup)
        ZenSpec.replace("apps/reader/modules/readerhighlight", {})
        ZenSpec.replace("ui/translator", {})
        _G.__ZEN_UI_PLUGIN = {
            config = { features = { dict_quick_lookup = true }, highlight_lookup = {} },
        }
        require("modules/reader/patches/dict_quick_lookup")()

        local lookup = {
            highlight = {
                selected_text = { pos0 = "a", pos1 = "b" },
                ui = { rolling = {}, annotation = { annotations = {
                    { drawer = "lighten", pos0 = "a", pos1 = "b" },
                } } },
                deleteHighlight = function(_, index) deleted = index end,
            },
            onClose = function() closes = closes + 1 end,
        }
        local result = DictQuickLookup.buildButtonLayout(lookup)
        result[1][1].callback()
        assert.are.equal(1, deleted)
        assert.are.equal(0, original_adds)
        assert.are.equal(1, closes)
    end)
end)
