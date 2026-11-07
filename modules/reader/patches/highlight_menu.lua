-- ZenOS: Highlight menu
-- Replaces the default highlight popup with a clean icon row.
-- Patches the text-selection highlight menu with icon buttons.

local function apply()
    local ReaderHighlight = require("apps/reader/modules/readerhighlight")
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")
    local Event = require("ui/event")
    local Handles = require("modules/reader/highlight_handles")
    local Viewport = require("modules/reader/highlight_viewport")
    local time = require("ui/time")
    local ReaderView = require("apps/reader/modules/readerview")
    local paintTo = ReaderView.paintTo
    ReaderView.paintTo = function(self, bb, x, y)
        paintTo(self, bb, x, y)
        Viewport.paintMargins(self, bb, x, y)
    end
    local logger = require("common/zen_logger").new("highlight_menu")
    local LookupPluginItems = require("modules/reader/lookup_plugin_items")
    local References = require("modules/reader/references")
    local Labels = require("common/ui/button_labels")
    local MenuItems = require("modules/reader/highlight_menu_items")
    local _ = require("gettext")
    local utils = require("common/utils")
    local plugin_root = require("common/plugin_root")
    local _icons_dir = plugin_root and plugin_root .. "/icons/"
    local _stock_icons_dir = require("libs/libkoreader-lfs").currentdir() .. "/resources/icons/mdlight/"
    local menu_icons = {
        style = utils.resolveLocalIcon(_icons_dir, "font"),
        color = utils.resolveLocalIcon(_icons_dir, "paint_palette"),
        note = utils.resolveLocalIcon(_icons_dir, "edit"),
        delete = utils.resolveLocalIcon(_icons_dir, "trash"),
        more = utils.resolveLocalIcon(_icons_dir, "more_vertical"),
    }
    local settings_icon = utils.resolveLocalIcon(_stock_icons_dir, "appbar.settings")
    local ai_icon = utils.resolveIcon(_icons_dir, "lookup_ai")

    local _plugin_ref = rawget(_G, "__ZEN_UI_PLUGIN")

    logger.dbg("apply() called, _plugin_ref=", tostring(_plugin_ref))
    if _plugin_ref then
        local cfg = _plugin_ref.config
        logger.dbg("config=", tostring(cfg))
        if type(cfg) == "table" and type(cfg.features) == "table" then
            logger.dbg("features.highlight_lookup=",
                tostring(cfg.features.highlight_lookup))
        end
    end

    local function is_enabled()
        local features = _plugin_ref
            and _plugin_ref.config
            and _plugin_ref.config.features
        return type(features) == "table" and features.highlight_lookup == true
    end

    -- Selection uses default highlight color instead of gray, unless user opted out
    if is_enabled() and G_reader_settings:readSetting("highlight_selection_use_highlight_color") == nil then
        G_reader_settings:saveSetting("highlight_selection_use_highlight_color", true)
    end

    local ReaderUI = require("apps/reader/readerui")
    local handleEvent = ReaderUI.handleEvent
    ReaderUI.handleEvent = function(self, event)
        if is_enabled() and event.handler == "onGesture" then
            local highlight = self.highlight
            local deadline = highlight and highlight._zen_highlight_tap_until
            if deadline then
                if time.now() >= deadline then
                    highlight._zen_highlight_tap_until = nil
                elseif event.args[1].ges == "tap" or event.args[1].ges == "double_tap" then
                    return true
                end
            end
        end
        return handleEvent(self, event)
    end

    local onHoldRelease = ReaderHighlight.onHoldRelease
    ReaderHighlight.onHoldRelease = function(self, ...)
        if is_enabled() and self.selected_text then Handles.suppressReaderTaps(self) end
        return onHoldRelease(self, ...)
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

    local function show_labels()
        local settings = _plugin_ref and _plugin_ref.config.highlight_lookup
        return settings and settings.show_labels == true
    end

    local function find_highlight_button(self, index, name)
        if not self._highlight_buttons then return nil end
        for key, fn_button in pairs(self._highlight_buttons) do
            local key_name = key:match("^%d+_(.*)$") or key
            if key_name == name then
                local ok, btn = pcall(fn_button, self, index)
                if ok and type(btn) == "table" and btn.callback then
                    return btn
                end
                return nil
            end
        end
        return nil
    end

    -- Only the keys we explicitly convert to icons; everything else is "other".
    -- ai_assistant is the main button registered by assistant.koplugin.
    local KNOWN_KEYS = {
        select = true, highlight = true, search = true, translate = true,
        wikipedia = true, dictionary = true,
        ai_assistant = true,
    }

    local function get_selection_anchor(self, dialog, index)
        local boxes = index and self:getHighlightVisibleBoxes(index)
            or (self.selected_text.sboxes or self.selected_text.pboxes)
        if not boxes or #boxes == 0 then
            return self:_getDialogAnchor(dialog, index)
        end

        local page = self.ui.paging and (index
            and self.ui.annotation.annotations[index].pos0.page
            or self.selected_text.pos0.page)
        local y0, y1
        for _i, box in ipairs(boxes) do
            if page then box = self.view:pageToScreenTransform(page, box) end
            if box then
                y0 = math.min(y0 or box.y, box.y)
                y1 = math.max(y1 or box.y + box.h, box.y + box.h)
            end
        end
        if not y0 then return self:_getDialogAnchor(dialog, index) end

        local padding = require("ui/size").padding.small
        local above = y0 - padding
        local below = self.screen_h - y1 - padding
        local x = math.floor((self.screen_w - dialog:getContentSize().w) / 2)
        return { x = x, y = above, w = 0, h = y1 - y0 + 2 * padding }, below >= above
    end

    -- -------------------------------------------------------------------------
    -- Override: onShowHighlightMenu  (new text-selection popup)
    -- Build the 3-icon row directly instead of mutating existing button specs.
    -- -------------------------------------------------------------------------
    local orig_onShowHighlightMenu = ReaderHighlight.onShowHighlightMenu

    logger.dbg("orig_onShowHighlightMenu=", tostring(orig_onShowHighlightMenu))

    ReaderHighlight.onShowHighlightMenu = function(self, index)
        logger.dbg("onShowHighlightMenu called, is_enabled=",
            tostring(is_enabled()), "selected_text=", tostring(self.selected_text ~= nil))
        if not is_enabled() then
            logger.dbg("disabled, falling back to orig")
            return orig_onShowHighlightMenu(self, index)
        end
        if not self.selected_text then
            logger.dbg("no selected_text, aborting")
            return
        end

        local buttons = {{}}
        local labels = show_labels()
        if not index then
            buttons[1][1] = {
                icon = "lookup.highlight",
                text = labels and _("Highlight") or nil,
                enabled = self.hold_pos ~= nil,
                callback = function()
                    self.view.highlight.saved_color = G_reader_settings:readSetting("highlight_color") or self._fallback_color
                    if self.setSelectionColor then self:setSelectionColor() end -- added after v2026.03
                    self:saveHighlight(not self.selected_text._zen_resized)
                    self:onClose()
                end,
            }
        end

        if show_wikipedia() then
            table.insert(buttons[1], {
                icon = "lookup.wikipedia",
                text = labels and _("Wikipedia") or nil,
                callback = function()
                    UIManager:scheduleIn(0.1, LookupPluginItems.safeCallback(function()
                        self:lookupWikipedia()
                    end))
                end,
            })
        end

        table.insert(buttons[1], {
            icon = "lookup.dictionary",
            text = labels and _("Dictionary") or nil,
            callback = function()
                self.ui:handleEvent(Event:new("LookupWord", self.selected_text.text, true))
                self:onClose()
            end,
        })
        table.insert(buttons[1], {
            icon = "lookup.translate",
            text = labels and _("Translate") or nil,
            callback = function()
                self:translate(index)
            end,
        })

        if show_ai_assistant() then
            local ai_btn = find_highlight_button(self, index, "ai_assistant")
            if ai_btn then
                table.insert(buttons[1], {
                    icon = ai_icon,
                    text = labels and _("AI assistant") or nil,
                    enabled = ai_btn.enabled ~= false,
                    callback = ai_btn.callback,
                })
            end
        end

        table.insert(buttons[1], {
            icon = "lookup.search",
            text = labels and _("Search") or nil,
            callback = function()
                self:onHighlightSearch()
            end,
        })

        if index then
            table.insert(buttons[1], {
                id = "zen_highlight_settings", icon = settings_icon,
                text = labels and _("Settings") or nil,
                callback = function()
                    self:onClose()
                    require("modules/settings/zen_settings_page").show(_plugin_ref, {
                        path = { { key = "text", value = _("Reader") },
                            { key = "text", value = _("Highlight / Lookup") },
                            { key = "text", value = _("Highlight") } },
                    })
                end,
            })
        end

        -- Include recognized companion-plugin buttons or opted-in unknown items.
        if self._highlight_buttons then
            local ffiUtil = require("ffi/util")
            local extra = {}
            for key, fn_button in ffiUtil.orderedPairs(self._highlight_buttons) do
                local key_name = key:match("^%d+_(.*)$") or key
                local plugin_setting = LookupPluginItems.settingForHighlightKey(key)
                if not KNOWN_KEYS[key_name]
                        and LookupPluginItems.shouldShow(
                            _plugin_ref and _plugin_ref.config, plugin_setting) then
                    local ok, btn = pcall(fn_button, self, index)
                    if ok and btn then
                        if not btn.show_in_highlight_dialog_func
                            or btn.show_in_highlight_dialog_func() then
                            table.insert(extra, btn)
                        end
                    end
                end
            end
            -- Split into rows of 2 so they render properly.
            local max_cols = 2
            for i = 1, #extra, max_cols do
                local row = {}
                for j = i, math.min(i + max_cols - 1, #extra) do
                    row[#row + 1] = extra[j]
                end
                table.insert(buttons, row)
            end
        end

        References.addPinButton(buttons, self.ui, References.selectionPage(self, index), function() self:onClose() end)
        LookupPluginItems.protectButtons(buttons)
        if labels then buttons = Labels.prepare(buttons) end
        MenuItems.compact(buttons)
        self.highlight_dialog = ButtonDialog:new{
            buttons = buttons,
            anchor = function()
                return get_selection_anchor(self, self.highlight_dialog, index)
            end,
            tap_close_callback = function()
                if self.hold_pos then
                    self:clear()
                end
            end,
        }
        if labels then Labels.apply(self.highlight_dialog.buttontable, buttons) end
        Handles.attach(self, self.highlight_dialog, index, function()
            self:onShowHighlightMenu(index)
        end)
        logger.dbg("showing custom highlight_dialog")
        UIManager:show(self.highlight_dialog, "[ui]")
    end

    local orig_showHighlightDialog = ReaderHighlight.showHighlightDialog
    ReaderHighlight.showHighlightDialog = function(self, index)
        if not is_enabled() then return orig_showHighlightDialog(self, index) end
        local original_new = ButtonDialog.new
        -- Intercept only this synchronous factory call to preserve upstream actions and bindings.
        ButtonDialog.new = function(class, spec, ...)
            if spec.name ~= "edit_highlight_dialog" then return original_new(class, spec, ...) end
            local settings = _plugin_ref.config.highlight_lookup or {}
            local available = Handles.available(self, index)
            local original_buttons = spec.buttons
            spec.buttons = MenuItems.arrange(spec.buttons, settings, available, menu_icons)
            References.addPinButton(spec.buttons, self.ui, References.selectionPage(self, index), function() self:onClose() end)
            if settings.show_labels then spec.buttons = Labels.prepare(spec.buttons) end
            MenuItems.compact(spec.buttons)
            local empty = #spec.buttons == 0
            if empty then spec.buttons = {{ { text = "", enabled = false } }} end
            local dialog = original_new(class, spec, ...)
            if settings.show_labels then Labels.apply(dialog.buttontable, spec.buttons) end
            if empty then dialog.buttons = {} end
            local controller = Handles.attach(self, dialog, index, function()
                self:showHighlightDialog(index)
            end)
            if available and not controller then
                dialog.buttons = MenuItems.arrange(original_buttons, settings, false, menu_icons)
                References.addPinButton(dialog.buttons, self.ui, References.selectionPage(self, index), function() self:onClose() end)
                if settings.show_labels then dialog.buttons = Labels.prepare(dialog.buttons) end
                MenuItems.compact(dialog.buttons)
                dialog:reinit()
                if settings.show_labels then Labels.apply(dialog.buttontable, dialog.buttons) end
            end
            self.highlight_dialog = dialog
            return dialog
        end
        local ok, result = pcall(orig_showHighlightDialog, self, index)
        ButtonDialog.new = original_new
        if not ok then error(result) end
        return result
    end

    local ReaderBookmark = require("apps/reader/modules/readerbookmark")
    local orig_setBookmarkNote = ReaderBookmark.setBookmarkNote
    ReaderBookmark.setBookmarkNote = function(self, item_or_index, ...)
        if not is_enabled() then return orig_setBookmarkNote(self, item_or_index, ...) end
        local index = self.bookmark_menu and self:getBookmarkItemIndex(item_or_index) or item_or_index
        local annotation = self.ui.annotation.annotations[index]
        local InputDialog = require("ui/widget/inputdialog")
        local original_new = InputDialog.new
        InputDialog.new = function(class, spec, ...)
            local T = require("ffi/util").template
            spec.description = "   " .. require("common/date_format").formatISODate(annotation.datetime)
                .. " · " .. T(_("Page %1"), annotation.mandatory or self:getBookmarkPageString(annotation.page))
            spec.add_scroll_buttons = false
            spec.use_available_height = false
            local Screen = require("device").screen
            spec.text_height = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.25)
            local close = spec.buttons[1][1].callback
            spec.buttons = {{ spec.buttons[1][3] }}
            local dialog = original_new(class, spec, ...)
            local excess = dialog.dialog_frame:getSize().h + Screen:scaleBySize(40)
                - (Screen:getHeight() - dialog._input_widget:getKeyboardDimen().h)
            if excess > 0 then
                dialog.orig_text_height = math.max(dialog._input_widget:getLineHeight(), dialog.text_height - excess)
                dialog:reinit()
            end
            local function close_dialog()
                close()
                return true
            end
            dialog.onCloseDialog = close_dialog
            require("common/ui/zen_modal_close").installDialog(dialog, close_dialog)
            return dialog
        end
        local ok, result = pcall(orig_setBookmarkNote, self, item_or_index, ...)
        InputDialog.new = original_new
        if not ok then error(result) end
        return result
    end

    for _i, method in ipairs({ "clear", "onClose", "onCloseDocument", "onSetDimensions", "onSuspend" }) do
        local original = ReaderHighlight[method]
        ReaderHighlight[method] = function(self, ...)
            self._zen_highlight_viewport = nil
            local controller = self._zen_highlight_handles
            if (method == "clear" or method == "onClose") and is_enabled()
                    and (self.hold_pos or self.highlight_dialog or controller) then
                Handles.suppressReaderTaps(self)
            end
            if controller then
                controller:close()
                UIManager:close(controller.dialog)
            end
            if original then return original(self, ...) end
        end
    end

    logger.dbg("onShowHighlightMenu override installed, new fn=",
        tostring(ReaderHighlight.onShowHighlightMenu))

end

return apply
