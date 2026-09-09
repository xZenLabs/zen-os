-- ZenOS: Highlight menu
-- Replaces the default highlight popup with a clean icon row.
-- Patches the text-selection highlight menu with icon buttons.

local function apply()
    local ReaderHighlight = require("apps/reader/modules/readerhighlight")
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")
    local Event = require("ui/event")
    local logger = require("common/zen_logger").new("highlight_menu")
    local LookupPluginItems = require("modules/reader/lookup_plugin_items")
    local utils = require("common/utils")
    local plugin_root = require("common/plugin_root")
    local _icons_dir = plugin_root and plugin_root .. "/icons/"
    local extend_icon = utils.resolveLocalIcon(_icons_dir, "lookup_extend")
    if extend_icon then
        utils.overrideIcons({ [extend_icon] = extend_icon }, false)
    end

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

        local extend_btn = index and find_highlight_button(self, index, "select")
        local buttons = {{
            extend_btn and {
                icon = extend_icon,
                enabled = extend_btn.enabled,
                callback = extend_btn.callback,
            } or {
                icon = "lookup.highlight",
                enabled = self.hold_pos ~= nil,
                callback = function()
                    self:saveHighlight(true)
                    self:onClose()
                end,
            },
        }}

        if show_wikipedia() then
            table.insert(buttons[1], {
                icon = "lookup.wikipedia",
                callback = function()
                    UIManager:scheduleIn(0.1, function()
                        self:lookupWikipedia()
                    end)
                end,
            })
        end

        table.insert(buttons[1], {
            icon = "lookup.dictionary",
            callback = function()
                self.ui:handleEvent(Event:new("LookupWord", self.selected_text.text, true))
                self:onClose()
            end,
        })
        table.insert(buttons[1], {
            icon = "lookup.translate",
            callback = function()
                self:translate(index)
            end,
        })

        if show_ai_assistant() then
            local ai_btn = find_highlight_button(self, index, "ai_assistant")
            if ai_btn then
                table.insert(buttons[1], {
                    icon = "lookup.ai",
                    enabled = ai_btn.enabled ~= false,
                    callback = ai_btn.callback,
                })
            end
        end

        table.insert(buttons[1], {
            icon = "lookup.search",
            callback = function()
                self:onHighlightSearch()
            end,
        })

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
        logger.dbg("showing custom highlight_dialog")
        UIManager:show(self.highlight_dialog, "[ui]")
    end

    logger.dbg("onShowHighlightMenu override installed, new fn=",
        tostring(ReaderHighlight.onShowHighlightMenu))

end

return apply
