local function apply_reader_footer()
    -- Adds "dynamic_filler_2" as a second independent filler item so that
    -- presets can place items in three sections: left | center | right.
    -- Also patches genAllFooterText to render the L/C/R layout when both
    -- dynamic_filler and dynamic_filler_2 are enabled.
    -- When progress_bar_position == "alongside", patches updateFooterContainer
    -- and _updateFooterText to add a left text widget so the bar is centered.

    local ReaderFooter = require("apps/reader/modules/readerfooter")
    local BD = require("ui/bidi")
    local Blitbuffer = require("ffi/blitbuffer")
    local Geom = require("ui/geometry")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local TextWidget = require("ui/widget/textwidget")
    local UIManager = require("ui/uimanager")
    local Device = require("device")
    local Screen = Device.screen
    local ReaderStatusBar = require("common/reader_status_bar")
    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    local _ = require("gettext")

    -- In compact_items mode, KOReader's battery generator returns the icon
    -- only. Append the numeric percentage so it matches "icons" mode
    -- (BD.wrap(prefix) .. batt_lvl .. "%").
    if not ReaderFooter._zen_battery_patched then
        local orig_battery = ReaderFooter.textGeneratorMap.battery
        ReaderFooter.textGeneratorMap.battery = function(footer)
            local result = orig_battery(footer)
            if footer.settings.item_prefix == "compact_items" and result ~= "" then
                local powerd = Device:getPowerDevice()
                local batt_lvl = 0
                if Device:hasBattery() then
                    local main_batt_lvl = powerd:getCapacity()
                    if Device:hasAuxBattery() and powerd:isAuxBatteryConnected() then
                        batt_lvl = main_batt_lvl + powerd:getAuxCapacity()
                    else
                        batt_lvl = main_batt_lvl
                    end
                end
                result = result .. batt_lvl .. "%"
            end
            return result
        end
        ReaderFooter._zen_battery_patched = true
    end

    -- KOReader formats hidden-flow pages as "current // total". Use the
    -- same current/total format as ordinary documents.
    if not ReaderFooter._zen_page_progress_patched then
        local orig_page_progress = ReaderFooter.textGeneratorMap.page_progress
        ReaderFooter.textGeneratorMap.page_progress = function(footer)
            local document = footer.ui and footer.ui.document
            if document and document:hasHiddenFlows() then
                local page = document:getPageNumberInFlow(footer.pageno)
                local pages = document:getTotalPagesInFlow(document:getPageFlow(footer.pageno))
                if page and pages then return ("%d / %d"):format(page, pages) end
            end
            return orig_page_progress(footer)
        end
        ReaderFooter._zen_page_progress_patched = true
    end

    -- Register as a generator (alias of dynamic_filler; only layout differs).
    if not ReaderFooter.textGeneratorMap.dynamic_filler_2 then
        ReaderFooter.textGeneratorMap.dynamic_filler_2 =
            ReaderFooter.textGeneratorMap.dynamic_filler
    end
    -- progress_bar: position-only item for alongside L/R split.
    -- Returns "" (bar is a widget, not text); its mode_index position
    -- splits left from right text in alongside mode.
    if not ReaderFooter.textGeneratorMap.progress_bar then
        ReaderFooter.textGeneratorMap.progress_bar = function() return "" end
    end

    -- textOptionTitles is a method, not a table — wrap it.
    local orig_textOptionTitles = ReaderFooter.textOptionTitles
    ReaderFooter.textOptionTitles = function(self, option)
        if option == "dynamic_filler_2" then return _("Dynamic filler 2") end
        if option == "progress_bar"  then return _("Progress bar") end
        return orig_textOptionTitles(self, option)
    end

    -- set_mode_index filters by MODE[name], so custom modes not in KOReader's
    -- MODE table are silently dropped. Inject them at their settings.order
    -- positions; if not yet in settings.order, append at the end so they
    -- still appear in the arrange dialog.
    local zen_custom_modes = { "dynamic_filler_2", "progress_bar" }
    local orig_set_mode_index = ReaderFooter.set_mode_index
    ReaderFooter.set_mode_index = function(self)
        orig_set_mode_index(self)

        -- Track which custom modes are already in mode_index (shouldn't happen
        -- normally, but guard against double-injection).
        local already_in = {}
        for i = 0, self.mode_nb - 1 do
            already_in[self.mode_index[i]] = true
        end

        if self.settings and self.settings.order then
            -- Inject modes that appear in settings.order at their saved position.
            local injections = {}
            for i = 0, #self.settings.order do
                local name = self.settings.order[i]
                for _k, cm in ipairs(zen_custom_modes) do
                    if name == cm and not already_in[name] then
                        table.insert(injections, { pos = i, name = name })
                        already_in[name] = true
                        break
                    end
                end
            end
            for _i, inj in ipairs(injections) do
                local mi_pos = {}
                for i = 0, self.mode_nb - 1 do
                    mi_pos[self.mode_index[i]] = i
                end
                local insert_after = -1
                for i = inj.pos - 1, 0, -1 do
                    local nm = self.settings.order[i]
                    if mi_pos[nm] ~= nil then
                        insert_after = mi_pos[nm]
                        break
                    end
                end
                for i = self.mode_nb - 1, insert_after + 1, -1 do
                    self.mode_index[i + 1] = self.mode_index[i]
                end
                self.mode_index[insert_after + 1] = inj.name
                self.mode_nb = self.mode_nb + 1
                already_in[inj.name] = true
            end
        end

        -- Any custom mode still missing from mode_index (e.g. newly added,
        -- not yet in settings.order) gets appended so it shows in the arrange
        -- dialog and can be positioned by the user.
        for _k, name in ipairs(zen_custom_modes) do
            if not already_in[name] then
                self.mode_index[self.mode_nb] = name
                self.mode_nb = self.mode_nb + 1
            end
        end
        -- progress_bar is a positional anchor, never a text mode.
        if self.settings then
            self.settings.progress_bar = nil
        end
    end

    -- addToMainMenu explicitly enumerates footer items; inject dynamic_filler_2
    -- right before additional_content (the last entry).
    local orig_addToMainMenu = ReaderFooter.addToMainMenu
    ReaderFooter.addToMainMenu = function(self, menu_items)
        orig_addToMainMenu(self, menu_items)
        if not menu_items.status_bar then return end

        local footer_items, arrange_item
        for _i, item in ipairs(menu_items.status_bar.sub_item_table or {}) do
            if item.text == _("Status bar items")
                    and type(item.sub_item_table) == "table" then
                footer_items = item.sub_item_table
            end
            for _j, child in ipairs(item.sub_item_table or {}) do
                if child.text == _("Arrange items in status bar") then
                    arrange_item = child
                    break
                end
            end
        end
        if not footer_items then return end

        -- Mirror the getMinibarOption callback pattern used by KOReader.
        local df2_entry = {
            text_func = function()
                return self:textOptionTitles("dynamic_filler_2")
            end,
            checked_func = function()
                return self.settings.dynamic_filler_2 == true
            end,
            callback = function()
                self.settings.dynamic_filler_2 = not self.settings.dynamic_filler_2
                local should_signal = false
                local should_update = false
                local prev_has_no_mode = self.has_no_mode
                local first_enabled_mode_num = self:set_has_no_mode()
                local prev_reclaim_height = self.reclaim_height
                self.reclaim_height = self.settings.reclaim_height
                if self.has_no_mode then
                    self.footer_text.height = 0
                    should_signal = true
                    -- textGeneratorMap == footerTextGeneratorMap (exposed on class)
                    self.genFooterText = self.textGeneratorMap.empty
                    self.mode = self.mode_list.off
                elseif prev_has_no_mode then
                    if self.settings.all_at_once then
                        self.mode = self.mode_list.page_progress
                        self:applyFooterMode()
                        G_reader_settings:saveSetting("reader_footer_mode", self.mode)
                    else
                        G_reader_settings:saveSetting("reader_footer_mode", first_enabled_mode_num)
                    end
                    should_signal = true
                elseif self.reclaim_height ~= prev_reclaim_height then
                    should_signal = true
                    should_update = true
                end
                if self.settings.all_at_once then
                    should_update = self:updateFooterTextGenerator()
                elseif (self.mode_list.dynamic_filler_2 == self.mode
                            and not self.settings.dynamic_filler_2)
                        or (prev_has_no_mode ~= self.has_no_mode) then
                    if not self.has_no_mode then
                        self.mode = first_enabled_mode_num
                    else
                        self.mode = self.settings.disable_progress_bar
                            and self.mode_list.off or self.mode_list.page_progress
                    end
                    should_update = true
                    self:applyFooterMode()
                    G_reader_settings:saveSetting("reader_footer_mode", self.mode)
                end
                if should_update or should_signal then
                    self:refreshFooter(should_update, should_signal)
                end
                self:rescheduleFooterAutoRefreshIfNeeded()
            end,
        }
        -- Insert before the last entry (additional_content).
        table.insert(footer_items, #footer_items, df2_entry)
        -- progress_bar is a positional anchor in the arrange dialog, not
        -- a user toggle, so it has no entry in the Status bar items list.

        if arrange_item then
            arrange_item.enabled_func = function()
                local enabled_count = self.settings.disable_progress_bar and 0 or 1
                for _i, mode in ipairs(self.mode_index) do
                    if mode ~= "progress_bar" and self.settings[mode] then
                        enabled_count = enabled_count + 1
                        if enabled_count > 1 then return true end
                    end
                end
                return false
            end
            arrange_item.callback = function()
                local item_table = {}
                for i, item in ipairs(self.mode_index) do
                    local enabled = self.settings[item]
                    if item == "progress_bar" then
                        enabled = not self.settings.disable_progress_bar
                    end
                    item_table[i] = {
                        text = self:textOptionTitles(item),
                        label = item,
                        dim = not enabled,
                    }
                end
                require("common/ui/zen_arrange_list").show{
                    title = _("Arrange items"),
                    item_table = item_table,
                    callback = function()
                        for i, item in ipairs(item_table) do
                            self.mode_index[i] = item.label
                        end
                        self.settings.order = self.mode_index
                        self:updateFooterTextGenerator()
                        self:onUpdateFooter(true)
                        UIManager:setDirty(nil, "ui")
                    end,
                }
            end
        end
    end

    -- Returns true when the alongside LCR layout should be used.
    local function is_lcr_alongside(self)
        return not self.settings.disable_progress_bar
            and self.settings.progress_bar_position == "alongside"
    end

    -- Returns (left_end_gi, right_start_gi) as 1-based indices into
    -- footerTextGenerators, split at progress_bar's position in mode_index.
    -- progress_bar itself is positional-only: its enabled state is irrelevant.
    local function bar_split_indices(self)
        local gi = 0
        for mi = 0, self.mode_nb - 1 do
            local m = self.mode_index[mi]
            if m == "progress_bar" then
                return gi, gi + 1  -- items [1..gi] are left, [gi+1..] are right
            elseif m and self.settings[m] then
                gi = gi + 1
            end
        end
    end

    -- Build concatenated text for a range of generators (shared by multiple callers).
    local function gen_section(self, gens, from_i, to_i)
        if from_i > to_i then return "" end
        local sep_str = BD.wrap(self:genSeparator())
        local is_compact = self.settings.item_prefix == "compact_items"
        local parts = {}
        local prev_merge = false
        for i = from_i, to_i do
            local gen = gens[i]
            if gen then
                local text, merge = gen(self)
                if text and text ~= "" then
                    if is_compact then text = text:gsub("%s", "\u{200A}") end
                    if merge then
                        local pos = #parts == 0 and 1 or #parts
                        parts[pos] = (parts[pos] or "") .. text
                        prev_merge = true
                    elseif prev_merge then
                        parts[#parts] = parts[#parts] .. text
                        prev_merge = false
                    else
                        table.insert(parts, BD.wrap(text))
                    end
                end
            end
        end
        return table.concat(parts, sep_str)
    end

    -- Measure text width using footer font settings.
    local function measure_text(self, text)
        if not text or text == "" then return 0 end
        local tw = TextWidget:new{
            text = text,
            face = self.footer_text_face,
            bold = self.settings.text_font_bold,
        }
        local w = tw:getSize().w
        tw:free()
        return w
    end

    -- Patch updateFooterContainer to add a left_text_container when in
    -- LCR+alongside mode. The layout becomes:
    --   [margin | left_text_container | progress_bar | text_container | margin]
    -- where text_container (right section) continues to drive bar width.
    local function book_margin_width(self)
        if not ReaderStatusBar.isMarginAlignmentEnabled(zen_plugin) then return end
        local document = self.ui and self.ui.document
        local left, right = ReaderStatusBar.getHorizontalMargins(document, nil, zen_plugin)
        -- KOReader scales progress_margin_width itself; convert rendered pixels back.
        return left and (left + right) / 2 / (Screen:scaleBySize(1000000) / 1000000)
    end

    local orig_updateFooterContainer = ReaderFooter.updateFooterContainer
    ReaderFooter.updateFooterContainer = function(self)
        local margin = book_margin_width(self)
        if margin then
            self._zen_horizontal_margin = self._zen_horizontal_margin or self.horizontal_margin
            self.horizontal_margin = Screen:scaleBySize(margin)
        elseif self._zen_horizontal_margin then
            self.horizontal_margin = self._zen_horizontal_margin
            self._zen_horizontal_margin = nil
        end
        orig_updateFooterContainer(self)
        if margin then
            local paintTo = self.vertical_frame.paintTo
            -- Shift the contents for unequal margins; keep the background full-width.
            self.vertical_frame.paintTo = function(frame, bb, x, y)
                local left, right = ReaderStatusBar.getHorizontalMargins(self.ui.document, 0, zen_plugin)
                paintTo(frame, bb, x + math.floor((left - right) / 2), y)
            end
        end
        if self.progress_bar then
            self.progress_bar.fillcolor = Blitbuffer.COLOR_GRAY_5
        end
        if not is_lcr_alongside(self) then
            -- Remove any stale left container from a previous mode.
            self._zen_left_text = nil
            self._zen_left_container = nil
            self._zen_bar_left_pad = nil
            return
        end
        -- Create the left text widget and container (text set later in _updateFooterText).
        self._zen_left_text = TextWidget:new{
            text = "",
            face = self.footer_text_face,
            bold = self.settings.text_font_bold,
        }
        self._zen_left_container = LeftContainer:new{
            dimen = Geom:new{ w = 0, h = self.height },
            self._zen_left_text,
        }
        -- Padding span between left text and bar; width matches horizontal_margin
        -- so L/R gaps around the bar are equal (horizontal_margin is also on the
        -- right, baked into text_width by _updateFooterText).
        local HorizontalSpan = require("ui/widget/horizontalspan")
        self._zen_bar_left_pad = HorizontalSpan:new{
            width = self.horizontal_margin or Screen:scaleBySize(3),
        }
        -- Insert [left_container, pad_span] before the bar; mutate in-place so
        -- footer_container[1]'s reference to horizontal_group stays valid.
        table.insert(self.horizontal_group, 2, self._zen_left_container)
        table.insert(self.horizontal_group, 3, self._zen_bar_left_pad)
        self.horizontal_group:resetLayout()
    end

    -- Patch _updateFooterText to correct progress_bar.width after orig runs.
    -- genAllFooterText (called inside orig) sets up _zen_left_container and
    -- stores _zen_left_w as a side effect, so left text is ready before orig's
    -- resetLayout/widgetRepaint. We then subtract left_w from bar width and
    -- call widgetRepaint again to overwrite the incorrect layout in the fb.
    local orig_updateFooterText = ReaderFooter._updateFooterText
    ReaderFooter._updateFooterText = function(self, force_repaint, full_repaint)
        if not is_lcr_alongside(self) or not self._zen_left_container then
            return orig_updateFooterText(self, force_repaint, full_repaint)
        end

        -- Reset so genAllFooterText (called inside orig) can set it.
        self._zen_left_w = nil

        -- orig calls genAllFooterText, which sets up _zen_left_container and
        -- stores _zen_left_w. orig then sets progress_bar.width too large
        -- (not accounting for left_w), calls resetLayout, and if force_repaint
        -- calls widgetRepaint (painting wrong layout to fb).
        orig_updateFooterText(self, force_repaint, full_repaint)

        local left_w = self._zen_left_w or 0
        -- Only apply left padding when there's actual left text.
        local pad_w = (left_w > 0 and self._zen_bar_left_pad)
            and self._zen_bar_left_pad.width or 0
        if left_w > 0 or pad_w > 0 then
            self.progress_bar.width = math.max(0, self.progress_bar.width - left_w - pad_w)
            self.horizontal_group:resetLayout()
            -- Re-paint to overwrite the incorrect fb content from orig's widgetRepaint.
            -- setDirty from orig is still pending; it will flush the corrected fb.
            if force_repaint and self.view.footer_visible and not full_repaint then
                UIManager:widgetRepaint(self.view.footer, 0, 0)
            end
        end
    end

    -- Keep book margins out of persisted footer settings.
    local orig_resetLayout = ReaderFooter.resetLayout
    ReaderFooter.resetLayout = function(self, ...)
        local width = self.settings.progress_margin_width
        self.settings.progress_margin_width = book_margin_width(self) or width
        local result = orig_resetLayout(self, ...)
        self.settings.progress_margin_width = width
        return result
    end

    local update_footer_text = ReaderFooter._updateFooterText
    ReaderFooter._updateFooterText = function(self, force_repaint, full_repaint)
        if force_repaint and self.view.footer_visible then
            local repaint, repaint_full = self:shouldBeRepainted()
            force_repaint = repaint
            full_repaint = full_repaint or repaint_full
        end
        local margin = book_margin_width(self)
        if margin and self.horizontal_margin ~= Screen:scaleBySize(margin)
                or not margin and self._zen_horizontal_margin then
            self:updateFooterContainer()
            self:resetLayout(true)
        end
        local width = self.settings.progress_margin_width
        self.settings.progress_margin_width = margin or width
        local result = update_footer_text(self, force_repaint, full_repaint)
        self.settings.progress_margin_width = width
        return result
    end

    -- genAllFooterText: activate L/C/R layout when both dynamic_filler and
    -- dynamic_filler_2 are enabled and present in mode_index.
    local orig_genAllFooterText = ReaderFooter.genAllFooterText

    ReaderFooter.genAllFooterText = function(self, skip_gen)
        -- Sub-calls from the original dynamic_filler generator (measuring
        -- remaining width) pass themselves as skip_gen; pass through.
        if skip_gen ~= nil then
            return orig_genAllFooterText(self, skip_gen)
        end

        if not self.mode_index or not self.mode_nb or self.mode_nb < 2 then
            return orig_genAllFooterText(self, nil)
        end

        local gens = self.footerTextGenerators
        if not gens then return orig_genAllFooterText(self, nil) end

        -- Scan mode_index for filler positions (LCR text mode + legacy alongside).
        -- Iterating 0..mode_nb-1 matches the enabled-item ordering used by
        -- updateFooterTextGenerator's pairs() call (which in LuaJIT visits
        -- the array part 1..N before the hash key 0, and "off" at key 0 is
        -- always disabled, so the gi counts stay aligned).
        local filler1_gi, filler2_gi, gi = nil, nil, 0
        for mi = 0, self.mode_nb - 1 do
            local m = self.mode_index[mi]
            if m and self.settings[m] then
                gi = gi + 1
                if m == "dynamic_filler" then
                    filler1_gi = gi
                elseif m == "dynamic_filler_2" then
                    filler2_gi = gi
                end
            end
        end

        -- Alongside LCR: use progress_bar position as split point (primary),
        -- or fall back to the legacy filler pair.
        if not self.settings.disable_progress_bar
                and self.settings.progress_bar_position == "alongside" then
            local left_end_gi, right_start_gi, center_prepend
            -- Primary: progress_bar positional anchor (ignores enabled state).
            left_end_gi, right_start_gi = bar_split_indices(self)
            if not left_end_gi and filler1_gi and filler2_gi then
                -- Legacy: filler pair; center items (between fillers) go to right text.
                local lo = math.min(filler1_gi, filler2_gi)
                local hi = math.max(filler1_gi, filler2_gi)
                left_end_gi    = lo - 1
                right_start_gi = hi + 1
                center_prepend = gen_section(self, gens, lo + 1, hi - 1)
            end
            if left_end_gi then
                if self._zen_left_container then
                    local left_text = gen_section(self, gens, 1, left_end_gi)
                    self._zen_left_text:setText(left_text)
                    local lw = measure_text(self, left_text)
                    self._zen_left_container.dimen.w = lw
                    self._zen_left_container.dimen.h = self.height
                    self._zen_left_w = lw
                    -- Zero pad when no left text so bar stays flush with left margin.
                    if self._zen_bar_left_pad then
                        self._zen_bar_left_pad.width = lw > 0
                            and (self.horizontal_margin or Screen:scaleBySize(3)) or 0
                    end
                end
                local right_text = gen_section(self, gens, right_start_gi, #gens)
                if center_prepend and center_prepend ~= "" then
                    if right_text ~= "" then
                        return center_prepend .. BD.wrap(self:genSeparator()) .. right_text
                    end
                    return center_prepend
                end
                return right_text
            end
            -- No split found; let orig handle alongside layout normally.
            return orig_genAllFooterText(self, nil)
        end

        -- Text-only LCR centering: both fillers required.
        if not filler1_gi or not filler2_gi then
            return orig_genAllFooterText(self, nil)
        end

        local idx1 = math.min(filler1_gi, filler2_gi)
        local idx2 = math.max(filler1_gi, filler2_gi)

        if idx2 > #gens then
            return orig_genAllFooterText(self, nil)
        end

        local left_text   = gen_section(self, gens, 1, idx1 - 1)
        local center_text = gen_section(self, gens, idx1 + 1, idx2 - 1)
        local right_text  = gen_section(self, gens, idx2 + 1, #gens)

        -- max_width: match original dynamic_filler formula.
        local margin = self.horizontal_margin or 0
        if not self.settings.disable_progress_bar
                and self.settings.align == "center" then
            margin = Screen:scaleBySize(self.settings.progress_margin_width or 0)
        end
        local screen_w  = self._saved_screen_width or Screen:getWidth()
        local max_width = math.floor(screen_w - 2 * margin)

        local function measure(text)
            if not text or text == "" then return 0 end
            local w = TextWidget:new{
                text = text,
                face = self.footer_text_face,
                bold = self.settings.text_font_bold,
            }
            local width = w:getSize().w
            w:free()
            return width
        end

        if not self.filler_space_width then
            self.filler_space_width = measure(" ")
        end
        local space_w = self.filler_space_width

        local left_w   = measure(left_text)
        local center_w = measure(center_text)
        local right_w  = measure(right_text)

        -- True centering: each filler = (max_width - center_w)/2 - its section.
        local half_outer = math.floor((max_width - center_w) / 2)
        local filler1_nb = math.max(0, math.floor((half_outer - left_w)  / space_w))
        local filler2_nb = math.max(0, math.floor((half_outer - right_w) / space_w))

        -- Assemble without separators around fillers (matches filler merge behavior).
        local result = {}
        if left_text ~= ""   then table.insert(result, left_text) end
        if filler1_nb > 0    then table.insert(result, (" "):rep(filler1_nb)) end
        if center_text ~= "" then table.insert(result, center_text) end
        if filler2_nb > 0    then table.insert(result, (" "):rep(filler2_nb)) end
        if right_text ~= ""  then table.insert(result, right_text) end

        return table.concat(result)
    end

    local function refresh_live_footer_modes(footer)
        if not (footer and footer.settings and footer.mode_index) then return end
        footer.settings.progress_bar = nil
        if footer.mode_list and footer.mode_list.dynamic_filler_2
                and footer.mode_list.progress_bar then
            return
        end
        footer:set_mode_index()
        footer.mode_list = {}
        for i = 0, #footer.mode_index do
            footer.mode_list[footer.mode_index[i]] = i
        end
        if footer.settings.disabled then return end
        footer:set_has_no_mode()

        local mode = G_reader_settings:readSetting("reader_footer_mode")
        if type(mode) == "number" then
            footer.mode = mode
        end
        if footer.settings.all_at_once and type(footer.updateFooterTextGenerator) == "function" then
            footer:updateFooterTextGenerator()
        elseif type(footer.applyFooterMode) == "function" then
            footer:applyFooterMode(footer.mode)
        end
        if type(footer.refreshFooter) == "function" then
            footer:refreshFooter(true, true)
        end
    end

    local function refresh_reader_footer()
        local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
        local ui = ok_rui and ReaderUI and ReaderUI.instance or nil
        local footer = ui and ui.view and ui.view.footer
        if footer then
            pcall(refresh_live_footer_modes, footer)
        end
    end

    refresh_reader_footer()
    UIManager:scheduleIn(0, refresh_reader_footer)
end

return apply_reader_footer
