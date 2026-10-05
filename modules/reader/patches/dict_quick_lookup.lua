-- ZenOS: Icon-only DictQuickLookup buttons
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
    local utils = require("common/utils")
    local plugin_root = require("common/plugin_root")
    local ai_icon = utils.resolveLocalIcon(plugin_root and plugin_root .. "/icons/", "lookup_ai")
    if ai_icon then
        utils.overrideIcons({ [ai_icon] = ai_icon }, false)
    end
    local _ = require("gettext")

    local _plugin_ref = rawget(_G, "__ZEN_UI_PLUGIN")

    local function is_enabled()
        local features = _plugin_ref
            and _plugin_ref.config
            and _plugin_ref.config.features
        return type(features) == "table" and features.dict_quick_lookup == true
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
                v.callback = function()
                    if not is_in_vocab then
                        self_dql.ui:handleEvent(
                            Event:new("WordLookedUp", vocab_word, get_book_title(), true)
                        )
                        is_in_vocab = true
                        local btn_w = self_dql.button_table
                            and self_dql.button_table:getButtonById("vocabulary")
                        if btn_w then
                            btn_w:setIcon("lookup.vocab_remove", btn_w.width)
                        end
                    else
                        if DB and DB.remove then
                            DB:remove({ word = vocab_word })
                        end
                        is_in_vocab = false
                        local btn_w = self_dql.button_table
                            and self_dql.button_table:getButtonById("vocabulary")
                        if btn_w then
                            btn_w:setIcon("lookup.vocab", btn_w.width)
                        end
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
            LookupPluginItems.protectButtons(result)
            return result
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

                        local function update_vocab_icon(in_vocab)
                            local btn_w = self_dql.button_table
                                and self_dql.button_table:getButtonById("vocabulary")
                            if btn_w then
                                btn_w:setIcon(
                                    in_vocab and "lookup.vocab_remove" or "lookup.vocab",
                                    btn_w.width
                                )
                            end
                            UIManager:setDirty(self_dql, "ui")
                        end

                        local v = {
                            id   = "vocabulary",
                            icon = "lookup.vocab",
                            callback = function()
                                if not is_in_vocab then
                                    -- Add: fire WordLookedUp so VocabBuilder handles insert.
                                    self_dql.ui:handleEvent(
                                        Event:new("WordLookedUp", vocab_word, get_book_title(), true)
                                    )
                                    is_in_vocab = true
                                    update_vocab_icon(true)
                                else
                                    -- Remove directly (no confirmation, matching icon-toggle UX).
                                    if DB and DB.remove then
                                        DB:remove({ word = vocab_word })
                                    end
                                    is_in_vocab = false
                                    update_vocab_icon(false)
                                end
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
                    LookupPluginItems.protectButtons(buttons)
                end
                return result
            end
            local ok, err = pcall(orig_init, self_dql, ...)
            ui.handleEvent = orig_handle -- always restore
            if not ok then error(err) end
        else
            return orig_init(self_dql, ...)
        end
    end

    logger.dbg("onDictButtonsReady handler installed")
end

return apply
