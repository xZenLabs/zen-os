-- ZenOS: Compact DictQuickLookup buttons
-- Replaces the dictionary popup's text button row with a compact icon row.
-- Supports both old KOReader (DictButtonsReady event) and new KOReader
-- (buildButtonLayout override). When "show other items" is enabled,
-- unknown buttons are preserved as a text row.

local function apply()
    local ReaderHighlight = require("apps/reader/modules/readerhighlight")
    local DictQuickLookup = require("ui/widget/dictquicklookup")
    local Translator = require("ui/translator")
    local Event = require("ui/event")
    local UIManager = require("ui/uimanager")
    local logger = require("common/zen_logger").new("dict_quick_lookup")
    local LookupPluginItems = require("modules/reader/lookup_plugin_items")
    local References = require("modules/reader/references")
    local Labels = require("common/ui/button_labels")
    local function add_pin_button(widget, buttons)
        local dictionary = widget.ui and widget.ui.dictionary
        widget._zen_pin_page = widget._zen_pin_page or dictionary and dictionary._zen_reference_page
        if not widget._zen_pin_page and widget.highlight and widget.highlight.selected_text then
            widget._zen_pin_page = References.selectionPage(widget.highlight)
        end
        if widget._zen_pin_page then
            References.addPinButton(buttons, widget.ui, widget._zen_pin_page, function() widget:onClose() end, "dict_quick_lookup")
        end
    end
    local utils = require("common/utils")
    local plugin_root = require("common/plugin_root")
    local ai_icon = utils.resolveIcon(plugin_root and plugin_root .. "/icons/", "lookup_ai")
    local _ = require("gettext")

    local _plugin_ref = rawget(_G, "__ZEN_UI_PLUGIN")

    local function is_enabled()
        local features = _plugin_ref
            and _plugin_ref.config
            and _plugin_ref.config.features
        return type(features) == "table" and features.dict_quick_lookup == true
    end

    local function show_labels()
        local settings = _plugin_ref and _plugin_ref.config.dict_quick_lookup
        return settings and settings.show_labels == true
    end

    local function prepare_labels(widget, buttons)
        if not show_labels() then return buttons end
        local Size = require("ui/size")
        return Labels.prepare(buttons, widget.width - 2 * (Size.border.window + Size.padding.default))
    end

    -- Large windows keep their stock full-screen layout.
    local function docks(widget)
        local settings = _plugin_ref and _plugin_ref.config.dict_quick_lookup
        local request = DictQuickLookup.temp_large_window_request
        return type(settings) == "table" and settings.bottom_sheet ~= false
            and not widget.is_wiki_fullpage and not G_reader_settings:isTrue("dict_largewindow")
            and not (request and request.is_large_window)
    end

    -- Remaps stock black-on-white pixels to the reader theme: white -> background, black -> text.
    local function tint(bb, x, y, w, h, radius)
        local ReaderThemes = require("common/reader_themes")
        local background, foreground = ReaderThemes.getBackgroundColor(_plugin_ref), ReaderThemes.getTextColor(_plugin_ref)
        if not (background and foreground) then return end
        -- Software night mode stores pixels inverted; work on raw pixels so the C blitter stays usable.
        local inverse = bb.getInverse and bb:getInverse() == 1
        if inverse then background, foreground = foreground:invert(), background:invert() end
        local Blitbuffer = require("ffi/blitbuffer")
        local light, dark = background:getColorRGB32(), foreground:getColorRGB32()
        -- Dark-background themes skip the first inversion so white still lands on the background.
        local swap = light.r + light.g + light.b < dark.r + dark.g + dark.b
        if swap then light, dark = dark, light end
        if not swap and light.r + light.g + light.b == 765 and dark.r + dark.g + dark.b == 0 then return end
        local function ratio(l, d) return l > d and math.floor(255 * (l - d) / l + 0.5) or 0 end
        local scale = Blitbuffer.ColorRGB32(ratio(light.r, dark.r), ratio(light.g, dark.g), ratio(light.b, dark.b), 0xFF)
        -- light * (1 - (1 - c) * (light - dark) / light), all in C blit passes.
        if inverse then bb:setInverse(0) end
        local ok, err = pcall(require("common/ui/button_feedback").eachSpan,
            { x = x, y = y, w = w, h = h }, radius or 0, function(sx, sy, sw, sh)
                if not swap then bb:invertRect(sx, sy, sw, sh) end
                bb:multiplyRectRGB(sx, sy, sw, sh, scale)
                bb:invertRect(sx, sy, sw, sh)
                bb:multiplyRectRGB(sx, sy, sw, sh, light)
            end)
        if inverse then bb:setInverse(1) end
        if not ok then error(err, 0) end
    end

    local init = DictQuickLookup.init
    DictQuickLookup.init = function(self, ...)
        local BottomSheet = docks(self) and require("common/ui/bottom_sheet")
        local w, h, margin, width
        if BottomSheet then
            local Screen = require("device").screen
            w, h = Screen:getWidth(), Screen:getHeight()
            margin, width = BottomSheet.dock(w, h)
            self.width = self.width or width
        end
        local result = init(self, ...)
        if is_enabled() and show_labels() and not self.is_wiki and not self.is_wiki_fullpage then
            Labels.apply(self.button_table, self.button_table.buttons)
        end
        local docked = BottomSheet and self.dict_frame and self[1]
        if docked then
            -- Match the footnote drawer: docked to the bottom, rounded corners pushed off-screen.
            local Size = require("ui/size")
            local extension = Size.radius.window + Size.border.window
            self.dict_frame.padding_bottom = extension
            self.region = require("ui/geometry"):new{ x = w > h and w - self.width - margin or 0, y = 0,
                w = w > h and self.width or w, h = h + extension }
            self.align = "bottom"
            self[1].dimen, self[1].align = self.region, "bottom"
            self.alpha = BottomSheet.alpha
            -- Stock refreshes only the frame; widen it to the shadow.
            self.onShow = function(widget)
                UIManager:setDirty(widget, function()
                    local dimen = widget.dict_frame.dimen
                    return "flashui", BottomSheet.refreshArea(dimen.x, dimen.y, dimen.w, dimen.h)
                end)
                return true
            end
            -- Down chevron instead of X, like a dismissable sheet.
            local close = self.dict_title and self.dict_title.right_button
            local chevron = close and utils.resolveLocalIcon(
                require("libs/libkoreader-lfs").currentdir() .. "/resources/icons/mdlight/", "chevron.up")
            if chevron then
                close.icon_rotation_angle = 180
                close:setIcon(chevron)
            end
        end
        local dots = is_enabled() and self.definition_widget and self.results
        if dots and self.displaynb_text then self.displaynb_text.paintTo = function() end end
        local themed = self.ui and self.ui.document
        if self.dict_frame and (dots or themed or docked) then
            local paint = self.dict_frame.paintTo
            self.dict_frame.paintTo = function(frame, bb, x, y)
                local size = frame:getSize()
                if docked then BottomSheet.paintShadow(bb, x, y, size.w, size.h, frame.radius + frame.bordersize) end
                paint(frame, bb, x, y)
                local definition = self.definition_widget and self.definition_widget.dimen
                if dots and definition then
                    -- Result dots replace "1 / N", centered in the padding above the buttons.
                    require("common/ui/zen_pager").paint(bb, x, definition.y + definition.h, size.w,
                        require("ui/size").padding.large, self.dict_index, #self.results, "dots", nil,
                        require("device").screen:scaleBySize(6))
                end
                if themed then tint(bb, x, y, size.w, size.h, frame.radius) end
            end
        end
        return result
    end

    local function update_vocab_icon(widget, in_vocab)
        local button = widget.button_table and widget.button_table:getButtonById("vocabulary")
        if not button then return end
        local icon = in_vocab and "lookup.vocab_remove" or "lookup.vocab"
        button:setIcon(icon, button.width)
        if show_labels() then Labels.applyButton(button, { icon = icon }) end
    end

    local function show_wikipedia()
        local cfg = _plugin_ref
            and _plugin_ref.config
            and _plugin_ref.config.highlight_lookup
        return type(cfg) == "table" and cfg.show_wikipedia == true
    end

    local function show_ai_assistant()
        local cfg = _plugin_ref
            and _plugin_ref.config
            and _plugin_ref.config.highlight_lookup
        return type(cfg) == "table" and cfg.show_ai_assistant ~= false
    end

    local function show_other_button(button)
        local setting = LookupPluginItems.settingForDictButton(button)
        return LookupPluginItems.shouldShow(
            _plugin_ref and _plugin_ref.config, setting)
    end

    -- IDs we handle explicitly; everything else is "unknown".
    -- assistant_* are the dict-popup buttons of assistant.koplugin; the Zen
    -- AI icon replaces them (see ai_dict_button).
    local KNOWN_IDS = {
        highlight = true, search = true, wikipedia = true,
        translate = true, close = true, save = true,
        vocabulary = true, prev_dict = true, next_dict = true,
        assistant_dictionary = true, assistant_wikipedia = true,
        assistant_term_xray = true,
    }

    -- Icon mapping for pool button ids.
    local ICON_MAP = {
        highlight = "lookup.highlight",
        search    = "lookup.search",
        wikipedia = "lookup.wikipedia",
        translate = "lookup.translate",
        close     = "close",
        prev_dict = "prev_dict",
        next_dict = "next_dict",
    }
    local LABELS = { highlight = _("Highlight"), search = _("Search"), wikipedia = _("Wikipedia"),
        translate = _("Translate"), vocabulary = _("Vocabulary") }

    local function is_vocabulary_button(button, dict_widget)
        if button.id == "vocabulary" then return true end
        local text = button.text
        if type(text) ~= "string" and type(button.text_func) == "function" then
            text = button.text_func(dict_widget)
        end
        return text == _("Add to vocabulary builder")
            or text == _("Remove from vocabulary builder")
            or text == _("Long-press to add to vocabulary builder")
    end

    local function ai_dialog_method(dialog)
        if not dialog then return nil end
        if type(dialog.showAskDialog) == "function" then return dialog.showAskDialog end
        if type(dialog.show) == "function" then return dialog.show end
    end

    -- Assistant versions expose either showAskDialog or show.
    local function ai_dict_button(dict_widget)
        local assistant = dict_widget.ui and dict_widget.ui.assistant
        if not assistant or type(assistant.isConfigured) ~= "function"
                or not ai_dialog_method(assistant.assistant_dialog) then return nil end
        return {
            id = "zen_ai_assistant",
            icon = ai_icon,
            text = show_labels() and _("AI assistant") or nil,
            callback = function()
                if not assistant:isConfigured() then return end
                local NetworkMgr = require("ui/network/manager")
                NetworkMgr:runWhenOnline(LookupPluginItems.safeCallback(function()
                    UIManager:nextTick(LookupPluginItems.safeCallback(function()
                        local dialog = assistant.assistant_dialog
                        local show = ai_dialog_method(dialog)
                        if not show then error("Assistant dialog is unavailable") end
                        show(dialog, dict_widget.lookupword or dict_widget.word)
                    end))
                end))
            end,
        }
    end

    -- Build a minimal icon-only spec from an original button.
    local function icon_btn(orig, icon)
        if not orig then return nil end
        return {
            id            = orig.id,
            icon          = icon,
            text          = show_labels() and (LABELS[orig.id] or orig.text) or nil,
            enabled       = orig.enabled,
            enabled_func  = orig.enabled_func,
            callback      = orig.callback,
            hold_callback = orig.hold_callback,
        }
    end

    -- KOReader 2026.07 removed Translate from the default dictionary layout,
    -- while keeping the action in the button pool.
    local function translate_btn(dict_widget, orig)
        if orig then
            return icon_btn(orig, ICON_MAP.translate)
        end
        return {
            id = "translate",
            icon = ICON_MAP.translate,
            text = show_labels() and _("Translate") or nil,
            enabled = not dict_widget.isDocless or not dict_widget:isDocless(),
            callback = function()
                Translator:showTranslation(dict_widget.lookupword or dict_widget.word, true)
            end,
        }
    end

    -- Find the existing highlight index for the current selection (rolling docs).
    -- Returns nil if no match found.
    local function find_existing_highlight_index(highlight_module)
        local sel = highlight_module.selected_text
        if not sel or not sel.pos0 then return nil end
        local annotations = highlight_module.ui
            and highlight_module.ui.annotation
            and highlight_module.ui.annotation.annotations
        if not annotations then return nil end
        local is_rolling = highlight_module.ui.rolling ~= nil
        for i, item in ipairs(annotations) do
            if item.drawer then
                if is_rolling then
                    if item.pos0 == sel.pos0 and item.pos1 == sel.pos1 then
                        return i
                    end
                else
                    local p0, p1 = item.pos0, item.pos1
                    if p0 and p1
                        and p0.page == sel.pos0.page
                        and math.abs(p0.x - sel.pos0.x) < 2
                        and math.abs(p0.y - sel.pos0.y) < 2
                        and math.abs(p1.x - sel.pos1.x) < 2
                        and math.abs(p1.y - sel.pos1.y) < 2 then
                        return i
                    end
                end
            end
        end
        return nil
    end

    -- =========================================================================
    -- New KOReader API (buildButtonLayout exists)
    -- =========================================================================
    if DictQuickLookup.buildButtonLayout then
        local orig_buildButtonLayout = DictQuickLookup.buildButtonLayout

        DictQuickLookup.buildButtonLayout = function(self_dql)
            if not is_enabled() or self_dql.is_wiki_fullpage then
                return orig_buildButtonLayout(self_dql)
            end

            local buttons = orig_buildButtonLayout(self_dql)

            if self_dql.is_wiki then
                return buttons -- Wiki has its own layout, leave unchanged
            end

            -- Flatten all rows and index by id.
            local by_id = {}
            local unknown = {}
            for _i, row in ipairs(buttons) do
                for _j, btn in ipairs(row) do
                    if btn.id and KNOWN_IDS[btn.id] then
                        by_id[btn.id] = btn
                    elseif show_other_button(btn) then
                        table.insert(unknown, btn)
                    end
                end
            end

            -- Build Zen icon row: highlight, [vocab], [wikipedia], translate, search.
            local icon_row = {}

            -- Highlight button with toggle behavior.
            local h = by_id["highlight"]
            if h then
                local orig_cb = h.callback
                h.callback = function()
                    local idx = find_existing_highlight_index(self_dql.highlight)
                    if idx then
                        self_dql.highlight:deleteHighlight(idx)
                    else
                        orig_cb()
                    end
                    self_dql:onClose()
                end
                table.insert(icon_row, icon_btn(h, ICON_MAP.highlight))
            end

            -- Vocab button: use its id when available, with a localized-label
            -- fallback for older KOReader integrations.
            local vocab_btn = by_id["vocabulary"]
            if not vocab_btn then
                for _i, row in ipairs(buttons) do
                    for _j, btn in ipairs(row) do
                        if is_vocabulary_button(btn, self_dql) then
                            vocab_btn = btn
                            break
                        end
                    end
                    if vocab_btn then break end
                end
            end
            if vocab_btn then
                -- Toggle-aware vocab icon: on first tap, VocabBuilder's
                -- WordLookedUp event fires and toggles state.
                -- We use a simple add-then-remove cycle via DB.
                local DB = package.loaded["db"]
                local vocab_word = self_dql.lookupword or self_dql.word
                local is_in_vocab = false

                local function get_book_title()
                    local dui = self_dql.ui
                    return (dui and dui.doc_props and dui.doc_props.display_title)
                        or _("Dictionary lookup")
                end

                local v = icon_btn(vocab_btn, "lookup.vocab")
                v.id = "vocabulary"
                v.text = show_labels() and _("Vocabulary") or nil
                v.callback = function()
                    if not is_in_vocab then
                        self_dql.ui:handleEvent(
                            Event:new("WordLookedUp", vocab_word, get_book_title(), true)
                        )
                        is_in_vocab = true
                        update_vocab_icon(self_dql, true)
                    else
                        if DB and DB.remove then
                            DB:remove({ word = vocab_word })
                        end
                        is_in_vocab = false
                        update_vocab_icon(self_dql, false)
                    end
                    UIManager:setDirty(self_dql, "ui")
                end
                table.insert(icon_row, v)
            end

            -- Wikipedia (conditional).
            if show_wikipedia() and by_id["wikipedia"] then
                table.insert(icon_row, icon_btn(by_id["wikipedia"], ICON_MAP.wikipedia))
            end

            -- Translate.
            table.insert(icon_row, translate_btn(self_dql, by_id["translate"]))

            -- AI assistant.
            if show_ai_assistant() then
                local ai = ai_dict_button(self_dql)
                if ai then
                    table.insert(icon_row, ai)
                end
            end

            -- Search.
            if by_id["search"] then
                table.insert(icon_row, icon_btn(by_id["search"], ICON_MAP.search))
            end

            -- Reconstruct button layout.
            local result = {}
            if #icon_row > 0 then
                table.insert(result, icon_row)
            end

            -- Preserve companion-plugin and opted-in unknown buttons as text rows.
            for _i, btn in ipairs(unknown) do
                if btn ~= vocab_btn and btn.id ~= "vocabulary" then
                    -- Put each unknown in its own row.
                    local found = false
                    for _j, row in ipairs(result) do
                        for _k, rb in ipairs(row) do
                            if rb.id and rb.id == btn.id then found = true; break end
                        end
                        if found then break end
                    end
                    if not found then
                        table.insert(result, { btn })
                    end
                end
            end

            logger.dbg("new-api icon_row=",
                #icon_row, "unknown=", #unknown)
            result = #result > 0 and result or buttons
            add_pin_button(self_dql, result)
            LookupPluginItems.protectButtons(result)
            return prepare_labels(self_dql, result)
        end

        logger.dbg("installed new-API buildButtonLayout override")
        return
    end

    -- =========================================================================
    -- Old KOReader API (DictButtonsReady event)
    -- =========================================================================
    logger.dbg("using legacy DictButtonsReady API")

    ReaderHighlight.onDictButtonsReady = function(self, dict_widget, buttons)
        logger.dbg("onDictButtonsReady, is_enabled=",
            tostring(is_enabled()), "is_wiki=", tostring(dict_widget.is_wiki),
            "is_wiki_fullpage=", tostring(dict_widget.is_wiki_fullpage))
        if not is_enabled() then return end
        if dict_widget.is_wiki or dict_widget.is_wiki_fullpage then return end

        local by_id = {}
        local unknown = {}
        for _i, row in ipairs(buttons) do
            for _j, btn in ipairs(row) do
                if btn.id and KNOWN_IDS[btn.id] then
                    by_id[btn.id] = btn
                elseif show_other_button(btn) then
                    table.insert(unknown, btn)
                end
            end
        end

        -- Translate is not included in the DictButtonsReady event; build manually.
        local translation = translate_btn(dict_widget)

        local icon_row = {}
        local h = icon_btn(by_id["highlight"], "lookup.highlight")
        -- Wrap highlight button to toggle (delete if already highlighted).
        if h then
            local orig_cb = h.callback
            h.callback = function()
                local idx = find_existing_highlight_index(self)
                if idx then
                    self:deleteHighlight(idx)
                else
                    orig_cb() -- sets save_highlight=true; onClose() below saves it
                end
                dict_widget:onClose()
            end
        end
        -- vocab button built below after post-processing catches VocabBuilder's row
        local w = show_wikipedia() and icon_btn(by_id["wikipedia"], "lookup.wikipedia") or nil
        local s = icon_btn(by_id["search"],    "lookup.search")
        local ai = show_ai_assistant() and ai_dict_button(dict_widget) or nil
        if h then table.insert(icon_row, h) end
        -- vocab slot placeholder: filled in post-process below
        if w then table.insert(icon_row, w) end
        table.insert(icon_row, translation)
        if ai then table.insert(icon_row, ai) end
        if s then table.insert(icon_row, s) end

        if #icon_row == 0 then
            logger.dbg("no known button ids found, leaving unchanged")
            return
        end

        -- Replace the entire buttons table in-place.
        -- VocabBuilder will append its row AFTER this returns (separate event handler).
        -- The DictQuickLookup:init wrap below handles the post-process cleanup.
        for i = #buttons, 1, -1 do table.remove(buttons, i) end
        table.insert(buttons, icon_row)

        -- Preserve companion-plugin and opted-in unknown buttons as a text row.
        if #unknown > 0 then
            table.insert(buttons, unknown)
        end

        -- Tag the widget so the init-wrap knows to post-process.
        dict_widget._zen_icon_row = icon_row
        logger.dbg("replaced buttons, icon_row=",
            #icon_row, "unknown=", #unknown)
    end

    -- Wrap DictQuickLookup:init to post-process buttons after ALL DictButtonsReady
    -- handlers have run (including VocabBuilder, which appends after our handler).
    -- We temporarily wrap ui:handleEvent to observe the final buttons state.
    local orig_init = DictQuickLookup.init
    DictQuickLookup.init = function(self_dql, ...)
        local ui = self_dql.ui
        if ui and is_enabled()
            and not self_dql.is_wiki and not self_dql.is_wiki_fullpage then
            local orig_handle = ui.handleEvent
            local own_handle = rawget(ui, "handleEvent")
            ui.handleEvent = function(ui_self, event, ...)
                local result = orig_handle(ui_self, event, ...)
                -- Post-process after all DictButtonsReady handlers have run.
                if event and event.handler == "onDictButtonsReady"
                    and self_dql._zen_icon_row then
                    local buttons = event.args[2]
                    local icon_row = self_dql._zen_icon_row
                    -- Scan for VocabBuilder's row, including localized id-less buttons.
                    local vocab_raw = nil
                    for ri = #buttons, 1, -1 do
                        local row = buttons[ri]
                        if row ~= icon_row then
                            for _i, btn in ipairs(row) do
                                if is_vocabulary_button(btn, self_dql) then
                                    vocab_raw = btn
                                    break
                                end
                            end
                            if vocab_raw then
                                table.remove(buttons, ri)
                                break
                            end
                        end
                    end
                    if vocab_raw then
                        -- Build a toggle-aware vocab icon button.
                        -- DB is cached in package.loaded by VocabBuilder on load.
                        local DB = package.loaded["db"]
                        local vocab_word = self_dql.lookupword or self_dql.word
                        local is_in_vocab = false -- start as "add" (matches VocabBuilder's own UX)

                        local function get_book_title()
                            local dui = self_dql.ui
                            return (dui and dui.doc_props and dui.doc_props.display_title)
                                or _("Dictionary lookup")
                        end

                        local v = {
                            id   = "vocabulary",
                            icon = "lookup.vocab",
                            text = show_labels() and _("Vocabulary") or nil,
                            callback = function()
                                if not is_in_vocab then
                                    -- Add: fire WordLookedUp so VocabBuilder handles insert.
                                    self_dql.ui:handleEvent(
                                        Event:new("WordLookedUp", vocab_word, get_book_title(), true)
                                    )
                                    is_in_vocab = true
                                    update_vocab_icon(self_dql, true)
                                else
                                    -- Remove directly (no confirmation, matching icon-toggle UX).
                                    if DB and DB.remove then
                                        DB:remove({ word = vocab_word })
                                    end
                                    is_in_vocab = false
                                    update_vocab_icon(self_dql, false)
                                end
                                UIManager:setDirty(self_dql, "ui")
                            end,
                        }
                        table.insert(icon_row, 2, v)
                        logger.dbg("vocab icon inserted")
                    end

                    -- Other plugins may append their legacy rows after our
                    -- onDictButtonsReady handler. Filter the final layout so
                    -- companion toggles work regardless of handler order.
                    for row_index = #buttons, 1, -1 do
                        local row = buttons[row_index]
                        if row ~= icon_row then
                            local filtered = {}
                            for _i, btn in ipairs(row) do
                                if not (btn.id and KNOWN_IDS[btn.id])
                                        and show_other_button(btn) then
                                    table.insert(filtered, btn)
                                end
                            end
                            if #filtered > 0 then
                                buttons[row_index] = filtered
                            else
                                table.remove(buttons, row_index)
                            end
                        end
                    end
                    add_pin_button(self_dql, buttons)
                    LookupPluginItems.protectButtons(buttons)
                    local labelled = prepare_labels(self_dql, buttons)
                    if labelled ~= buttons then
                        for i = #buttons, 1, -1 do buttons[i] = nil end
                        for i, row in ipairs(labelled) do buttons[i] = row end
                    end
                end
                return result
            end
            local ok, err = pcall(orig_init, self_dql, ...)
            -- Always restore; drop the instance field if there was none so later class patches still apply.
            rawset(ui, "handleEvent", own_handle)
            if not ok then error(err) end
        else
            return orig_init(self_dql, ...)
        end
    end

    logger.dbg("onDictButtonsReady handler installed")
end

return apply
