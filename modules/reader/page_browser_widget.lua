-- ZenOS PageBrowserWidget customisations, compiled only when the page browser first opens.
-- Shared helpers come from modules/reader/patches/page_browser via ctx.
return function(ctx)
    local UIManager = require("ui/uimanager")
    local time = require("ui/time")
    local Event = require("ui/event")
    local Device = require("device")
    local GlyphIcons = require("common/ui/glyph_icons")
    local PageBrowserTabs = require("modules/reader/page_browser_tabs")
    local References = require("modules/reader/references")
    local utils = require("common/utils")
    local settings_panel_height = 226
    local RESUME_TTL_SECONDS = 6
    local _plugin_ref, _icons_dir, _stock_icons_dir = ctx.plugin, ctx.icons_dir, ctx.stock_icons_dir
    local panel_height, preview_padding = ctx.panel_height, ctx.preview_padding
    local chapter_padding, slider_gap = ctx.chapter_padding, ctx.slider_gap
    local format_progress, make_progress_label = ctx.format_progress, ctx.make_progress_label
    local add_chapter_rows, reset_thumbnail_cache = ctx.add_chapter_rows, ctx.reset_thumbnail_cache
    local key_matches_menu, supports_page_browser_focus = ctx.key_matches_menu, ctx.supports_page_browser_focus
    local get_page_browser_layout, set_page_browser_layout = ctx.get_page_browser_layout, ctx.set_page_browser_layout

    local function set_settings_preview(thumbnail, enabled)
        if not thumbnail or thumbnail._zen_settings_preview == enabled then return end
        thumbnail._zen_settings_preview = enabled
        reset_thumbnail_cache(thumbnail)
    end


    local PageBrowserWidget = require("ui/widget/pagebrowserwidget")
    local BD         = require("ui/bidi")
    local Font       = require("ui/font")
    local Geom       = require("ui/geometry")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local TextWidget      = require("ui/widget/textwidget")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local OverlapGroup    = require("ui/widget/overlapgroup")
    local Blitbuffer      = require("ffi/blitbuffer")
    local Size            = require("ui/size")
    local Screen          = Device.screen
    local GestureRange    = require("ui/gesturerange")
    local Accent          = require("common/ui/accent")
    local ZenSlider       = require("common/ui/zen_slider")
    local ZenIconButton   = require("common/ui/zen_icon_button")
    local logger          = require("common/zen_logger").new("page_browser")
    local LineWidget      = require("ui/widget/linewidget")
    local _               = require("gettext")

    local function is_content_tab(tab)
        return tab == "toc" or tab == "book_details" or tab == "book_switcher" or tab == "bookmarks"
            or tab == "highlights" or tab == "annotations" or tab == "pins"
    end

    local function is_full_page(pbw)
        return pbw._zen_active_tab == "aa" and pbw._zen_font_full_page == true
    end
    PageBrowserWidget._zenIsFullPage = is_full_page

    local function divider(pbw, y)
        return FrameContainer:new{
            padding = 0, bordersize = 0, overlap_offset = { 0, y },
            LineWidget:new{ dimen = Geom:new{ w = pbw.dimen.w, h = Screen:scaleBySize(1) },
                background = Blitbuffer.COLOR_LIGHT_GRAY },
        }
    end

    local function preview_divider(pbw, y)
        pbw._zen_preview_divider = divider(pbw, y)
        return pbw._zen_preview_divider
    end

    -- Centered between the tab bar and the preview top. Nil during native init
    -- (tabs not built yet), so callers keep it last in their child list.
    local function header_divider(pbw, top_pad)
        local tabs = pbw._zen_tab_bar
        if not tabs then return end
        local title_top = pbw._zen_status_row and pbw._zen_header_offset
            or math.floor(pbw._zen_header_top_inset / 2)
        local tabs_bottom = title_top + tabs.overlap_offset[2] + tabs:getSize().h
        pbw._zen_header_divider = divider(pbw,
            math.floor((tabs_bottom + pbw.title_bar_h + top_pad - Screen:scaleBySize(1)) / 2))
        return pbw._zen_header_divider
    end

    function PageBrowserWidget:_zenOpenFocusedPage()
        local page = self:_zenFocusedDocumentPage()
        self:onClose(true)
        self.ui.link:addCurrentLocationToStack()
        self.ui:handleEvent(Event:new("GotoPage", page))
    end

    local function current_focus_id(pbw)
        local selected = pbw.selected
        local row = selected and pbw.layout and pbw.layout[selected.y]
        local widget = row and row[selected.x]
        return widget and widget._zen_focus_id
    end

    local function unfocus_current(pbw)
        local selected = pbw.selected
        local row = selected and pbw.layout and pbw.layout[selected.y]
        local widget = row and row[selected.x]
        if widget and type(widget.handleEvent) == "function" then
            widget:handleEvent(Event:new("Unfocus"))
        end
    end

    local function tag_focus_widget(widget, id)
        if not widget then return end
        widget._zen_focus_id = id
        return widget
    end

    local function rebuild_focus_layout(pbw, desired_id)
        if not pbw._zen_focus_enabled then return end
        desired_id = desired_id or current_focus_id(pbw)
        if pbw._zen_layout_mode == "carousel"
            and type(desired_id) == "string"
            and desired_id:match("^page:%d+$") then
            desired_id = "page:" .. ((pbw.focus_page_shift or 1) + 1)
        end
        unfocus_current(pbw)

        local layout = {}
        local header_row = {}
        for i, button in ipairs(pbw._zen_header_buttons or {}) do
            tag_focus_widget(button, "header:" .. i)
            table.insert(header_row, button)
        end
        if #header_row > 0 then table.insert(layout, header_row) end
        if is_full_page(pbw) and pbw._zen_full_page_preview then
            table.insert(layout, { tag_focus_widget(pbw._zen_full_page_preview, "preview") })
        end

        local page_rows = {}
        local nb_cols = pbw.nb_cols or 1
        for idx = 1, ((not pbw._zen_active_tab or pbw._zen_active_tab == "browser"
                or pbw._zen_active_tab == "aa") and not is_full_page(pbw) and pbw.nb_grid_items or 0) do
            local page_frame = pbw.grid and pbw.grid[idx]
            local nav_frame = pbw.grid and pbw.grid[(pbw.nb_grid_items or 0) + idx]
            if page_frame and page_frame.page_idx and nav_frame then
                local row_index = math.floor((idx - 1) / nb_cols) + 1
                local row = page_rows[row_index]
                if not row then
                    row = {}
                    page_rows[row_index] = row
                end
                tag_focus_widget(nav_frame, "page:" .. idx)
                table.insert(row, nav_frame)
            end
        end
        for row_index = 1, #page_rows do
            if page_rows[row_index] and #page_rows[row_index] > 0 then
                table.insert(layout, page_rows[row_index])
            end
        end

        if pbw._zen_page_actions then
            table.insert(layout, pbw._zen_page_actions.buttons)
        end
        local content = pbw._zen_content_panel or (pbw._zen_active_tab == "aa" and pbw._zen_row_panel)
        for y, row in ipairs(content and content.layout or {}) do
            local focus_row = {}
            for x, widget in ipairs(row) do
                tag_focus_widget(widget, "content:" .. y .. ":" .. x)
                table.insert(focus_row, widget)
            end
            if #focus_row > 0 then table.insert(layout, focus_row) end
        end
        if not pbw._zen_active_tab or pbw._zen_active_tab == "browser" then
            local footer_row = {}
            for _i, item in ipairs({
                { pbw._zen_layout_button, "footer:layout" },
                { pbw._zen_btn_skip_left, "footer:previous" },
                { pbw._zen_btn_skip_right, "footer:next" },
                { pbw._zen_search_button, "footer:search" },
            }) do
                if item[1] then
                    tag_focus_widget(item[1], item[2])
                    table.insert(footer_row, item[1])
                end
            end
            if #footer_row > 0 then table.insert(layout, footer_row) end
        end
        if #layout == 0 then return end

        pbw.layout = layout
        pbw._zen_focus_layout_ready = true
        desired_id = desired_id or "header:1"
        local target_x, target_y
        for y, row in ipairs(layout) do
            for x, widget in ipairs(row) do
                if widget._zen_focus_id == desired_id then
                    target_x, target_y = x, y
                    break
                end
            end
            if target_x then break end
        end
        if not target_x then
            target_y = 1
            target_x = 1
        end
        pbw.selected = { x = target_x, y = target_y }
        local target = layout[target_y][target_x]
        if target and type(target.handleEvent) == "function" then
            target:handleEvent(Event:new("Focus"))
        end
    end

    PageBrowserWidget._zenRebuildFocusLayout = rebuild_focus_layout

    local _orig_registerKeyEvents = PageBrowserWidget.registerKeyEvents
    PageBrowserWidget.registerKeyEvents = function(self)
        if _orig_registerKeyEvents then _orig_registerKeyEvents(self) end
        if supports_page_browser_focus() then
            self.key_events = self.key_events or {}
            self.key_events.ScrollRowUp = nil
            self.key_events.ScrollRowDown = nil
            self.key_events.FocusUp = nil
            self.key_events.FocusRight = nil
            self.key_events.FocusDown = nil
            self.key_events.FocusLeft = nil
            self.key_events.Press = nil
            self.key_events.ZenPageBrowserUp = {
                { "Up" },
                event = "FocusMove",
                args = { 0, -1 },
            }
            self.key_events.ZenPageBrowserRight = {
                { "Right" },
                event = "FocusMove",
                args = { 1, 0 },
            }
            self.key_events.ZenPageBrowserDown = {
                { "Down" },
                event = "FocusMove",
                args = { 0, 1 },
            }
            self.key_events.ZenPageBrowserLeft = {
                { "Left" },
                event = "FocusMove",
                args = { -1, 0 },
            }
            self.key_events.ZenPageBrowserPress = {
                { "Press" },
                event = "Press",
            }
            self.key_events.ZenPageBrowserConfirm = {
                { "Return" },
                { "Enter" },
                event = "Press",
            }
        end
    end
    PageBrowserWidget.onPhysicalKeyboardConnected = PageBrowserWidget.registerKeyEvents

    local function resolve_stock_icon(name)
        return utils.resolveIcon(_stock_icons_dir, name)
    end

    local function get_page_display_text(pbw, page_num)
        local fallback = tostring(page_num)
        local pagemap = pbw.ui and pbw.ui.pagemap
        local labels = pbw.page_labels
        if not (pagemap and type(pagemap.wantsPageLabels) == "function"
            and pagemap:wantsPageLabels()
            and type(labels) == "table" and #labels > 0) then
            return fallback
        end

        if pbw._zen_page_label_source ~= labels then
            pbw._zen_page_label_source = labels
            pbw._zen_page_label_text_cache = {}
        end
        local cache = pbw._zen_page_label_text_cache
        if cache[page_num] then
            return cache[page_num]
        end

        local lo, hi, best = 1, #labels, nil
        while lo <= hi do
            local mid = math.floor((lo + hi) / 2)
            local item = labels[mid]
            if item and item.page and item.page <= page_num then
                best = item
                lo = mid + 1
            else
                hi = mid - 1
            end
        end

        local text = best and best.label
        if text and type(pagemap.cleanPageLabel) == "function" then
            text = pagemap:cleanPageLabel(text)
        end
        text = text and tostring(text) or fallback
        cache[page_num] = text
        return text
    end

    local function visible_page_raw(pbw, page)
        local pages = pbw._zen_visible_pages
        return pages and pages[page] or page
    end

    local function page_progress_text(pbw, page)
        local np = math.max(1, pbw.nb_pages or 1)
        return format_progress(get_page_display_text(pbw, visible_page_raw(pbw, page)),
            get_page_display_text(pbw, visible_page_raw(pbw, np)), math.floor(page / np * 100))
    end

    local function visible_page_index(pbw, page)
        local pages = pbw._zen_visible_pages
        if not pages then return page end

        local index = (pbw._zen_visible_page_indexes or {})[page]
        if index then return index end

        -- A TOC entry may target a hidden fragment. Keep it hidden by
        -- focusing the next linear page (or the final one at the end).
        for i, visible_page in ipairs(pages) do
            if visible_page >= page then return i end
        end
        return #pages
    end

    PageBrowserWidget._zenFocusedDocumentPage = function(self)
        return visible_page_raw(self, self.focus_page or self.cur_page or 1)
    end

    local function update_visible_pages(pbw)
        local document = pbw.ui and pbw.ui.document
        if not document then return false end

        local raw_nb_pages = type(document.getPageCount) == "function"
            and document:getPageCount() or pbw._zen_raw_nb_pages or pbw.nb_pages
        if type(raw_nb_pages) ~= "number" or raw_nb_pages < 1 then return false end

        local raw_focus = visible_page_raw(pbw, pbw.focus_page or pbw.cur_page or 1)
        local raw_current = visible_page_raw(pbw, pbw.cur_page or raw_focus)
        local has_hidden_flows = type(document.hasHiddenFlows) == "function"
            and document:hasHiddenFlows()
            and type(document.getPageFlow) == "function"

        if not has_hidden_flows then
            pbw._zen_visible_pages = nil
            pbw._zen_visible_page_indexes = nil
            pbw._zen_raw_nb_pages = raw_nb_pages
            pbw.nb_pages = raw_nb_pages
            pbw.focus_page = math.max(1, math.min(raw_nb_pages, raw_focus))
            pbw.cur_page = math.max(1, math.min(raw_nb_pages, raw_current))
            return false
        end

        if pbw._zen_visible_pages
            and pbw._zen_visible_document == document
            and pbw._zen_raw_nb_pages == raw_nb_pages then
            return true
        end

        local pages, indexes = {}, {}
        for raw_page = 1, raw_nb_pages do
            if document:getPageFlow(raw_page) == 0 then
                table.insert(pages, raw_page)
                indexes[raw_page] = #pages
            end
        end
        if #pages == 0 or #pages == raw_nb_pages then
            pbw._zen_visible_pages = nil
            pbw._zen_visible_page_indexes = nil
            pbw._zen_raw_nb_pages = raw_nb_pages
            pbw.nb_pages = raw_nb_pages
            pbw.focus_page = math.max(1, math.min(raw_nb_pages, raw_focus))
            pbw.cur_page = math.max(1, math.min(raw_nb_pages, raw_current))
            return false
        end

        pbw._zen_visible_pages = pages
        pbw._zen_visible_page_indexes = indexes
        pbw._zen_visible_document = document
        pbw._zen_raw_nb_pages = raw_nb_pages
        pbw.nb_pages = #pages
        pbw.focus_page = visible_page_index(pbw, raw_focus)
        pbw.cur_page = visible_page_index(pbw, raw_current)
        return true
    end

    local function configure_carousel_grid(pbw)
        if pbw._zen_layout_mode ~= "carousel" or not pbw.grid
            or pbw.nb_grid_items ~= 3 then
            return false
        end
        local grid_w = pbw.grid_width or (pbw.dimen and pbw.dimen.w)
        local grid_h = pbw.grid_height
        if not grid_w or not grid_h then return false end

        local gap = Screen:scaleBySize(12)
        local item_w = math.max(1, math.floor(grid_w * 2 / 3))
        local item_h = math.max(1, grid_h - Screen:scaleBySize(preview_padding))
        if pbw._zen_active_tab ~= "aa" then
            item_w = math.max(item_w, math.ceil(item_h * Screen:getWidth() / Screen:getHeight()))
        end
        local center_x = math.floor((grid_w - item_w) / 2)
        local offsets = {
            center_x - item_w - gap,
            center_x,
            center_x + item_w + gap,
        }
        if BD.mirroredUILayout() then
            offsets[1], offsets[3] = offsets[3], offsets[1]
        end

        local size_changed = pbw.grid_item_width ~= item_w
            or pbw.grid_item_height ~= item_h
        pbw.grid_item_width = item_w
        pbw.grid_item_height = item_h
        pbw.grid_item_dimen = Geom:new{ w = item_w, h = item_h }
        pbw.focus_page_shift = 1

        for idx = 1, 3 do
            local page_frame = pbw.grid[idx]
            if page_frame and page_frame[1] then
                page_frame.overlap_offset = { offsets[idx], 0 }
                page_frame[1].dimen = pbw.grid_item_dimen:copy()
                page_frame.dimen = nil
            end
            local nav_frame = pbw.grid[pbw.nb_grid_items + idx]
            if nav_frame and nav_frame.is_nav_item and nav_frame[1] then
                nav_frame.initial_overlap_offset = { offsets[idx], 0 }
                nav_frame.overlap_offset = { offsets[idx], 0 }
                nav_frame[1].dimen = pbw.grid_item_dimen:copy()
                nav_frame.dimen = nil
            end
        end
        if size_changed then pbw._zen_tile_size = nil end
        return true
    end

    local function get_badge_bottom(pbw, item, item_h, is_focus_page)
        if pbw._zen_layout_mode ~= "carousel" or not is_focus_page then
            return item_h
        end

        local thumb_frame = item[1] and item[1][1]
        local image = thumb_frame and thumb_frame.is_page_thumbnail and thumb_frame[1]
        local image_size = image and type(image.getSize) == "function" and image:getSize()
        local thumb_h = image_size and image_size.h
        if not thumb_h then return nil end

        return math.floor((item_h - thumb_h) / 2) + thumb_h
    end

    PageBrowserWidget._zenConfigureCarouselGrid = configure_carousel_grid

    -- ----------------------------------------------------------------
    -- 1. Patch init: blank title, actions on the left and close on the right.
    -- ----------------------------------------------------------------
    local function pad_header(pbw)
        if pbw._zen_header_top_padding then return end
        pbw._zen_header_top_padding = Screen:scaleBySize(16)
        local config = _plugin_ref and _plugin_ref.config
        if config and config.features.status_bar == true
                and require("common/status_bar_registry").hasItems(config.status_bar)
                and (not config.page_browser or config.page_browser.show_status_bar ~= false) then
            local shared = require("common/shared_state")
            local build = shared.get(_plugin_ref, "buildStatusRow")
            if build then
                pbw._zen_build_status_row = function()
                    return build(pbw.dimen.w, {
                        row_height = 18,
                        show_bottom_border = config.status_bar and config.status_bar.show_bottom_border == true,
                    })
                end
                pbw._zen_status_row = pbw._zen_build_status_row()
                pbw._zen_status_regions = shared.get(_plugin_ref, "statusRowRefreshRegions")
            end
        end
        pbw._zen_header_top_inset = pbw._zen_status_row
            and Screen:scaleBySize(6) or pbw._zen_header_top_padding
        pbw._zen_header_offset = pbw._zen_header_top_inset
            + (pbw._zen_status_row and pbw._zen_status_row:getSize().h + Screen:scaleBySize(4) or 0)
        pbw.title_bar_h = pbw.title_bar_h + pbw._zen_header_offset
    end

    local function header(pbw)
        local inset = pbw._zen_header_top_inset
        -- Without a status row, split the inset so the tabs sit centered in the header.
        local top = pbw._zen_status_row and inset or math.floor(inset / 2)
        local group = VerticalGroup:new{ align = "center", VerticalSpan:new{ width = top } }
        if pbw._zen_status_row then
            group[#group + 1] = pbw._zen_status_row
            group[#group + 1] = VerticalSpan:new{ width = Screen:scaleBySize(4) }
        end
        group[#group + 1] = pbw.title_bar
        if not pbw._zen_status_row then group[#group + 1] = VerticalSpan:new{ width = inset - top } end
        pbw._zen_header = group
        return group
    end

    function PageBrowserWidget:_zen_status_refresh()
        if self._zen_closed or not self._zen_status_row then return end
        local stack = UIManager._window_stack
        local top = stack and stack[#stack]
        if not top or top.widget ~= self then return end
        local previous = self._zen_status_row
        local current = self._zen_build_status_row()
        if #self._zen_status_regions(previous, current) == 0 then current:free(); return end
        local bounds = previous.dimen:copy()
        current.dimen = bounds
        self._zen_header[2] = current
        self._zen_status_row = current
        previous:free()
        UIManager:setDirty(self, "ui", bounds)
    end

    for _i, name in ipairs({ "onResume", "onNetworkConnected", "onNetworkDisconnected",
            "onNetworkStateChanged", "onCharging", "onNotCharging" }) do
        local original = PageBrowserWidget[name]
        PageBrowserWidget[name] = function(self, ...)
            local result = original and original(self, ...)
            self:_zen_status_refresh()
            return result
        end
    end

    local _orig_init = PageBrowserWidget.init
    PageBrowserWidget.init = function(self)
        local resume = self.ui and self.ui._zen_page_browser_resume
        local resume_tab
        if resume then
            self.ui._zen_page_browser_resume = nil
            local age = os.time() - resume.closed_at
            if age >= 0 and age <= RESUME_TTL_SECONDS then
                self._zen_controls_state = resume.controls_state
                resume_tab = resume.active_tab
            end
        end
        self._zen_plugin = _plugin_ref
        self._zen_active_tab = "browser"
        -- Reflowable Aa and paged Contrast tabs remember full page separately.
        self._zen_full_page_key = self.ui and self.ui.rolling and "font_full_page" or "contrast_full_page"
        self._zen_font_full_page = _plugin_ref and _plugin_ref.config.page_browser
            and _plugin_ref.config.page_browser[self._zen_full_page_key] == true or false
        self._zen_layout_mode = get_page_browser_layout()
        if self._zen_layout_mode == "single" then
            self._zen_nb_cols_override = 1
            self._zen_nb_rows_override = 1
        elseif self._zen_layout_mode == "carousel" then
            self._zen_nb_cols_override = 3
            self._zen_nb_rows_override = 1
        else
            self._zen_nb_cols_override = 3
            self._zen_nb_rows_override = 3
        end
        _orig_init(self)
        pad_header(self)
        if self._zen_status_row then
            self._zen_status_clock_bound = true
            require("common/clock_timer").bind(self, function(target) target:_zen_status_refresh() end)
        end
        local stock_focus_layout = self.build_focus_layout
        self._zen_focus_enabled = supports_page_browser_focus()
        if self._zen_focus_enabled then self.build_focus_layout = true end
        update_visible_pages(self)
        -- Register pan_release so onPanRelease fires when the user lifts
        -- their finger after dragging the slider.  PageBrowserWidget does
        -- not include pan_release in its native ges_events.
        self.ges_events.PanRelease = {
            GestureRange:new{
                ges   = "pan_release",
                range = Geom:new{ x = 0, y = 0,
                                  w = Screen:getWidth(), h = Screen:getHeight() },
            }
        }
        -- Grid mode is fixed at 3 columns × 3 rows on every device.
        self._zen_orig_nb_cols = 3
        self._zen_orig_nb_rows = 3
        -- Block slider input until the opening swipe gesture completes so
        -- the northward swipe that opens us doesn't immediately move the
        -- slider (which appears right where the finger lifted).
        self._zen_slider_locked = true
        UIManager:scheduleIn(0.35, function()
            self._zen_slider_locked = false
        end)

        -- Blank the title text (no "Page browser" label)
        self.title_bar:setTitle("")

        local btn_sz  = Screen:scaleBySize(32)
        local btn_pad = self.title_bar.button_padding or Screen:scaleBySize(11)
        local focus_pad = Screen:scaleBySize(4)

        -- Remove the hamburger (left_button)
        if self.title_bar.left_button then
            for i = #self.title_bar, 1, -1 do
                if self.title_bar[i] == self.title_bar.left_button then
                    table.remove(self.title_bar, i)
                    break
                end
            end
            self.title_bar.left_button   = nil
            self.title_bar.has_left_icon = false
        end

        local function make_header_btn(file_path, x_pos, cb, hold_cb, align, icon_size)
            icon_size = icon_size or btn_sz
            local inset_start = math.floor((btn_sz - icon_size) / 2)
            local inset_end = btn_sz - icon_size - inset_start
            local button = {
                file           = file_path,
                width          = icon_size,
                height         = icon_size,
                padding        = btn_pad + inset_start,
                padding_right  = btn_pad + inset_end,
                padding_bottom = btn_pad + inset_end,
                overlap_align  = align or "left",
                allow_flash    = true,
                show_parent    = self,
                callback       = cb or function() end,
                hold_callback  = hold_cb,
            }
            if x_pos then button.overlap_offset = { x_pos, 0 } end
            button = ZenIconButton:new(button)
            local orig_paint_to = button.paintTo
            button.onFocus = function(btn)
                btn._zen_keyboard_focused = true
                if btn.image then btn.image.invert = true end
                return true
            end
            button.onUnfocus = function(btn)
                btn._zen_keyboard_focused = nil
                if btn.image then btn.image.invert = false end
                return true
            end
            if orig_paint_to then
                button.paintTo = function(btn, bb, x, y)
                    local focused = btn._zen_keyboard_focused == true
                    if btn.image then btn.image.invert = focused end
                    if focused then
                        local left_pad = btn.padding_left or btn.padding or 0
                        local right_pad = btn.padding_right or btn.padding or 0
                        local icon_x = x + (BD.mirroredUILayout() and right_pad or left_pad)
                        local icon_y = y + (btn.padding_top or btn.padding or 0)
                        bb:paintRect(
                            icon_x - focus_pad,
                            icon_y - focus_pad,
                            (btn.width or btn_sz) + 2 * focus_pad,
                            (btn.height or btn_sz) + 2 * focus_pad,
                            Blitbuffer.COLOR_BLACK
                        )
                    end
                    return orig_paint_to(btn, bb, x, y)
                end
            end
            return button
        end

        local old_right_button = self.title_bar.right_button
        if old_right_button then
            for i = #self.title_bar, 1, -1 do
                if self.title_bar[i] == old_right_button then
                    table.remove(self.title_bar, i)
                    break
                end
            end
            self.title_bar.right_button = make_header_btn(
                utils.resolveIcon(_stock_icons_dir, "close"), nil,
                old_right_button.callback, old_right_button.hold_callback,
                "right", require("common/ui/zen_title_style").ICON_SIZE)
            table.insert(self.title_bar, self.title_bar.right_button)
        end

        local more_button
        more_button = make_header_btn(utils.resolveIcon(_icons_dir, "more_vertical"),
            0, function()
                local state = self._zen_row_panel and self._zen_row_panel._reader_controls_state
                local font_section = self._zen_active_tab == "aa" and state
                    and (state.section == "font" or state.section == "contrast")
                local dialog
                local function launch(callback)
                    UIManager:close(dialog)
                    self:onClose()
                    UIManager:nextTick(callback)
                end
                local buttons = {
                    {{ text = _("Reader controls"), icon = utils.resolveIcon(_icons_dir, "quicksettings")
                            or utils.resolveLocalIcon(_icons_dir, "quicksettings"),
                        callback = function() launch(function()
                            if not self.ui.menu.onShowReaderControls then
                                require("modules/menu/patches/reader_controls")(_plugin_ref)
                            end
                            self.ui.menu:onShowReaderControls()
                        end) end }},
                }
                if font_section then
                    table.insert(buttons, 1, {{
                        text = _("Show full page") .. (self._zen_font_full_page and " ✓" or ""),
                        callback = function()
                            UIManager:close(dialog)
                            self._zen_font_full_page = not self._zen_font_full_page
                            local config = _plugin_ref.config
                            config.page_browser = config.page_browser or {}
                            config.page_browser[self._zen_full_page_key] = self._zen_font_full_page
                            _plugin_ref:saveConfig()
                            self:updateLayout()
                            UIManager:setDirty(self, "ui")
                        end,
                    }})
                else
                    buttons[#buttons + 1] = {{ text = _("Settings"), icon = GlyphIcons.iconPath(GlyphIcons.SVG.settings),
                        callback = function() launch(function()
                            require("modules/settings/zen_settings_page").show(_plugin_ref, {
                                path = {{ key = "text", value = _("Reader") }, { key = "text", value = _("Page Browser") }},
                            })
                        end) end }}
                end
                dialog = require("common/ui/zen_anchored_menu").new{
                    anchor = more_button.dimen, buttons = buttons,
                }
                UIManager:show(dialog)
            end)
        self._zen_more_button = more_button
        table.insert(self.title_bar, more_button)
        self._zenBuildHeaderTabs = function(pbw)
            if pbw._zen_tab_bar then
                for i = #pbw.title_bar, 1, -1 do
                    if pbw.title_bar[i] == pbw._zen_tab_bar then table.remove(pbw.title_bar, i) end
                end
                pbw._zen_tab_bar:free()
            end
            local items, selected = {}, 1
            local entries = PageBrowserTabs.list(pbw._zen_plugin.config, pbw.ui, false, pbw._zen_initial_tab)
            for i, entry in ipairs(entries) do
                local tab = entry.id
                items[i] = { icon = utils.resolveIcon(_icons_dir, entry.icon) or resolve_stock_icon(entry.icon), text = entry.text,
                    callback = function() pbw:_zenSelectTab(tab) end }
                if pbw._zen_active_tab == tab then selected = i end
            end
            local tabs = require("common/ui/zen_tab_bar"):new{
                items = items, selected = selected, icon_size = Screen:scaleBySize(24),
                width = math.min(math.floor(pbw.dimen.w * 2 / 3), pbw.dimen.w - (btn_sz + btn_pad * 2) * 4),
                cell_height = Screen:scaleBySize(40), focusable = pbw._zen_focus_enabled,
            }
            local size = tabs:getSize()
            tabs.overlap_offset = { math.floor((pbw.dimen.w - size.w) / 2),
                math.floor((pbw.title_bar_h - pbw._zen_header_offset - size.h) / 2) }
            pbw._zen_tab_bar = tabs
            table.insert(pbw.title_bar, tabs)
            pbw._zen_header_buttons = { more_button }
            for i, cell in ipairs(tabs.cells) do
                cell.file = items[i].icon
                table.insert(pbw._zen_header_buttons, cell)
            end
            if pbw.title_bar.right_button then
                table.insert(pbw._zen_header_buttons, pbw.title_bar.right_button)
            end
        end
        self:_zenBuildHeaderTabs()

        -- Rebuild only the panel: the initial layout already used the
        -- selected fixed grid dimensions.
        local tabs = PageBrowserTabs.list(self._zen_plugin.config, self.ui)
        local initial_tab = self._zen_initial_tab or tabs[1].id
        resume_tab = resume_tab or self._zen_plugin.config.page_browser.last_tab
        for _i, tab in ipairs(tabs) do
            if not self._zen_initial_tab and tab.id == resume_tab then initial_tab = tab.id; break end
        end
        if initial_tab ~= "browser" then
            self:_zenSelectTab(initial_tab)
        else
            self._zen_panel_only_rebuild = not self._zen_focus_enabled or stock_focus_layout
            self:updateLayout()
            self._zen_panel_only_rebuild = nil
        end
    end

    -- ----------------------------------------------------------------
    -- 2. Patch updateLayout: swap BookMapRow ribbon for ZenSlider+labels
    -- ----------------------------------------------------------------
    local _orig_updateLayout = PageBrowserWidget.updateLayout

    -- Pre-measure panel height once so we can inject it as row_height
    -- before _orig_updateLayout runs. This means the native code computes
    -- grid_height = screen_h - title_h - panel_h, sizes thumbnails to fit
    -- that exact space, and positions them with correct offsets. No
    -- post-hoc shrinking = no thumbnail overlap.
    local zen_icon_size      = Screen:scaleBySize(32)
    local zen_icon_pad_v = Screen:scaleBySize(11)
    local zen_panel_pad_top = Screen:scaleBySize(chapter_padding)

    PageBrowserWidget._zenSelectTab = function(self, tab)
        if self._zen_active_tab == tab then return end
        -- Highlight swatches ghost under "ui" waveform; flash when leaving them.
        local prev = self._zen_active_tab
        local refresh_mode = (prev == "highlights" or prev == "annotations")
            and require("common/ui/refresh")() or "ui"
        self._zen_active_tab = tab
        set_settings_preview(self.ui.thumbnail, self.ui.paging and tab == "aa" or nil)
        local layout = get_page_browser_layout()
        self._zen_layout_mode = tab == "aa" and layout == "grid" and "single" or layout
        self._zen_slider = nil
        self._zen_scrubbing = false
        self._zen_post_scrub = nil
        self._zen_placeholders_painted = false
        self._zen_last_scrub_dirty = nil
        if tab == "aa" and self.ui.rolling then
            self._zen_preview_xpointer = self.ui.document:getPageXPointer(self:_zenFocusedDocumentPage())
        end
        for _i, name in ipairs({ "_zen_deferred_update", "_zen_scrub_dirty_func", "_zen_post_scrub_clear" }) do
            if self[name] then UIManager:unschedule(self[name]) end
        end
        self:_zenBuildHeaderTabs()
        self:updateLayout()
        UIManager:setDirty(self, refresh_mode)
    end

    PageBrowserWidget._zenRefreshPreview = function(self)
        if self._zen_closed then return end
        if self._zen_full_page_preview then self._zen_full_page_preview:invalidate() end
        reset_thumbnail_cache(self.ui.thumbnail)
        self._zen_tile_size = nil
        self:updateEditableStuff()
        update_visible_pages(self)
        self.cur_page = visible_page_index(self, self.ui:getCurrentPage())
        if self._zen_preview_xpointer then
            self.focus_page = visible_page_index(self,
                self.ui.document:getPageFromXPointer(self._zen_preview_xpointer))
        end
        if self._zen_active_tab == "aa" or self._zen_active_tab == "browser" then self:update() end
        UIManager:setDirty(self, "ui")
    end

    PageBrowserWidget.updateLayout = function(self)
        pad_header(self)
        self._zen_page_actions = nil
        self._zen_controls_state = self._zen_row_panel and self._zen_row_panel._reader_controls_state
            or self._zen_controls_state
        if self._zen_full_page_preview then
            self._zen_full_page_preview:free()
            self._zen_full_page_preview = nil
        end
        if self._zen_content_panel then
            self._zen_content_panel:free()
            self._zen_content_panel = nil
        end
        if is_content_tab(self._zen_active_tab) then
            if self._zen_row_panel then self._zen_row_panel:free(); self._zen_row_panel = nil end
            if self.requests_batch_id then self.ui.thumbnail:cancelPageThumbnailRequests(self.requests_batch_id) end
            self._zen_slider = nil
            local panel = require("modules/reader/page_browser_panels").build(self, self._zen_active_tab,
                self.dimen.w, self.dimen.h - self.title_bar_h - self._zen_header_top_padding, function(page, item)
                    self:onClose(true)
                    if self.ui.link then self.ui.link:addCurrentLocationToStack() end
                    if item and item._zen_bookmark then
                        self.ui.bookmark:gotoBookmark(item.page, item.pos0)
                    else
                        self.ui:handleEvent(Event:new("GotoPage", page))
                    end
                end)
            self._zen_content_panel = panel
            self[1] = FrameContainer:new{
                width = self.dimen.w, height = self.dimen.h, padding = 0, margin = 0,
                bordersize = 0, background = Blitbuffer.COLOR_WHITE,
                VerticalGroup:new{ header(self), panel,
                    VerticalSpan:new{ width = self._zen_header_top_padding } },
            }
            rebuild_focus_layout(self)
            return
        end
        local desired_focus_id = current_focus_id(self)
        if self._zen_focus_enabled then
            unfocus_current(self)
            self._zen_rebuilding_focus_layout = true
        end
        update_visible_pages(self)
        if not self._zen_panel_only_rebuild and not self._zen_nb_cols_override then
            if self._zen_layout_mode == "single" then
                self._zen_nb_cols_override = 1
                self._zen_nb_rows_override = 1
            elseif self._zen_layout_mode == "carousel" then
                self._zen_nb_cols_override = 3
                self._zen_nb_rows_override = 1
            else
                self._zen_nb_cols_override = 3
                self._zen_nb_rows_override = 3
            end
        end
        -- Free any panel we built in a previous updateLayout call.
        if self._zen_row_panel then
            if self._zen_row_panel.free then self._zen_row_panel:free() end
            self._zen_row_panel = nil
        end

        -- Inject our required panel height as row_height BEFORE calling
        -- _orig_updateLayout. The native code uses self.row_height if it
        -- is already set — but it recomputes it unconditionally, so we
        -- must monkey-patch span_height temporarily to coerce the result.
        -- Simpler: just call _orig_updateLayout, then rebuild the grid
        -- from scratch with the correct height. Instead we use the cleanest
        -- approach: override nb_toc_spans to 0 via a temporary shim so
        -- the native row_height formula yields the minimum, then fix up.
        --
        -- Actually the cleanest approach: run _orig_updateLayout normally,
        -- then rebuild self.grid (OverlapGroup) with the corrected height.
        -- The native code rebuilds self.grid from scratch inside
        -- _orig_updateLayout, so we just need to redo that part.
        local is_aa = self._zen_active_tab == "aa"
        local controls_h = math.min(Screen:scaleBySize(is_aa and settings_panel_height or panel_height),
            math.floor(self.dimen.h * 0.45))
        local actions = not is_aa and References.actions(self.ui, function() self:onClose(true) end) or {}
        self._zen_page_actions = #actions > 0
            and require("modules/reader/page_actions").new(actions, self.dimen.w) or nil
        local actions_h = self._zen_page_actions and self._zen_page_actions:getSize().h or 0
        local zen_panel_h = controls_h + actions_h

        -- When _zen_panel_only_rebuild is set (second call during init, no
        -- layout change needed), skip _orig_updateLayout entirely so the
        -- async tile rendering queue started by the first call is not
        -- cancelled and restarted, which caused ~11s delays on slow devices.
        local top_pad = Screen:scaleBySize(preview_padding)
        if self._zen_panel_only_rebuild then
            logger.dbg("panel-only rebuild, skipping _orig_updateLayout")
        else
        local nb_toc_pre
        if self.ui.handmade and self.ui.handmade:isHandmadeTocEnabled() then
            nb_toc_pre = self.ui.doc_settings:readSetting("page_browser_toc_depth_handmade_toc") or self.max_toc_depth
        else
            nb_toc_pre = self.ui.doc_settings:readSetting("page_browser_toc_depth") or self.max_toc_depth
        end
        nb_toc_pre = nb_toc_pre or 0
        local stats_on = self.ui.statistics and self.ui.statistics:isEnabled()
        local psr      = (not stats_on and nb_toc_pre > 0) and 0.2 or 1
        local BookMapRow = require("ui/widget/bookmapwidget").BookMapRow
        local border2    = 2 * BookMapRow.pages_frame_border
        local factor     = nb_toc_pre + psr + 1
        -- Solve: factor * span_height + border2 = zen_panel_h + top_pad
        local target_span = math.max(1, math.floor((zen_panel_h + top_pad - border2) / factor))
        local orig_span_h = self.span_height
        self.span_height  = target_span

        -- _orig_updateLayout UNCONDITIONALLY overwrites self.nb_cols/nb_rows
        -- by reading from doc_settings (key: "page_browser_nb_cols/rows").
        -- Temporarily patch those keys so our forced layout survives.
        local ds = self.ui and self.ui.doc_settings
        local _saved_ds_cols, _saved_ds_rows, _zen_ds_patched
        if self._zen_nb_cols_override then
            local nc = self._zen_nb_cols_override
            local nr = self._zen_nb_rows_override or nc
            self._zen_nb_cols_override = nil
            self._zen_nb_rows_override = nil
            logger.dbg("forcing cols=", nc, "rows=", nr)
            if ds then
                _saved_ds_cols = ds:readSetting("page_browser_nb_cols")
                _saved_ds_rows = ds:readSetting("page_browser_nb_rows")
                logger.dbg("saved ds cols=", _saved_ds_cols, "rows=", _saved_ds_rows)
                ds:saveSetting("page_browser_nb_cols", nc)
                ds:saveSetting("page_browser_nb_rows", nr)
                _zen_ds_patched = true
            else
                -- no doc_settings: set directly (won't be overwritten)
                self.nb_cols = nc
                self.nb_rows = nr
            end
        end

        -- Reset cached tile size; the new layout will re-seed it on
        -- the first showTile call.
        self._zen_tile_size = nil

        _orig_updateLayout(self)

        logger.dbg("after orig nb_cols=", self.nb_cols, "nb_rows=", self.nb_rows, "nb_grid_items=", self.nb_grid_items)

        -- Restore span_height so the detached BookMapRow is self-consistent.
        self.span_height = orig_span_h
        -- Restore doc_settings to original values (undo temporary patch).
        -- If the key didn't exist before, delete it rather than saveSetting(nil).
        if _zen_ds_patched and ds then
            if _saved_ds_cols ~= nil then
                ds:saveSetting("page_browser_nb_cols", _saved_ds_cols)
            else
                ds:delSetting("page_browser_nb_cols")
            end
            if _saved_ds_rows ~= nil then
                ds:saveSetting("page_browser_nb_rows", _saved_ds_rows)
            else
                ds:delSetting("page_browser_nb_rows")
            end
            logger.dbg("restored ds cols=", _saved_ds_cols, "rows=", _saved_ds_rows)
        end
        end -- panel_only_rebuild else

        -- Suppress native left-side page number widgets: we draw our own
        -- badges in paintTo() instead.  showTile() checks show_pagenum on
        -- the FrameContainer before inserting a TextBoxWidget; clearing it
        -- here stops future insertions.  Then remove any already inserted
        -- during the update() call that _orig_updateLayout makes internally.
        for i = 1, (self.nb_grid_items or 0) do
            if self.grid[i] then
                self.grid[i].show_pagenum = false
            end
        end
        for i = #self.grid, 1, -1 do
            if self.grid[i] and self.grid[i].is_page_num_widget then
                if self.grid[i].free then self.grid[i]:free() end
                table.remove(self.grid, i)
            end
        end

        -- After _orig_updateLayout:
        --  self.row_height  ≈ zen_panel_h + top_pad
        --  self.grid_height  = screen_h - title_h - zen_panel_h - top_pad
        --  self.grid         = OverlapGroup sized to grid_height (correct)
        --  self.row          = CenterContainer (kept detached)

        -- Cache the grid screen region for targeted dirty calls while
        -- scrubbing.  Expand by Size.border.thin on the top edge so that
        -- the first row's border overflow is included in every screen flush.
        local _gd_bs = Size.border.thin
        local _scrub_top = math.max(0, self.dimen.y + (self.title_bar_h or 0) + top_pad - _gd_bs)
        self._zen_grid_dimen = Geom:new{
            x = self.dimen.x,
            y = _scrub_top,
            w = self.grid_width or self.dimen.w,
            h = (self.grid_height or 0) + _gd_bs,
        }
        -- Combined region covering grid + panel (including the slider).
        -- Using one dirty call with the correct waveform is crucial: the
        -- "fast" (A2) waveform is black/white-only and corrupts the gray
        -- badge backgrounds; "ui" (GL16) handles gray correctly.
        self._zen_scrub_dimen = Geom:new{
            x = self.dimen.x,
            y = _scrub_top,
            w = self.dimen.w,
            h = self.dimen.h + self.dimen.y - _scrub_top,
        }

        if is_aa then
            if not self.ui.menu.createZenReaderControlsPanel then
                require("modules/menu/patches/reader_controls")(_plugin_ref)
            end
            local panel = self.ui.menu:createZenReaderControlsPanel{
                ui = self.ui, width = self.dimen.w, height = controls_h,
                state = self._zen_controls_state,
                padding_bottom = self._zen_header_top_padding,
                show_parent = self, close_callback = function() self:onClose() end,
                on_change = function() self:_zenRefreshPreview() end,
                on_layout_changed = function() rebuild_focus_layout(self) end,
            }
            panel.overlap_offset = { 0, self.dimen.h - controls_h }
            self._zen_row_panel = panel
            self._zen_controls_state = panel._reader_controls_state
            self._zen_panel_h = zen_panel_h
            self._zen_slider = nil
            if is_full_page(self) then
                self.ui.thumbnail:cancelPageThumbnailRequests(self.requests_batch_id)
                local preview = require("modules/reader/page_browser_preview"):new{
                    ui = self.ui, width = self.dimen.w, height = self.dimen.h,
                    top = self.title_bar_h + top_pad, bottom = zen_panel_h,
                    page = self:_zenFocusedDocumentPage(),
                    callback = function() self:_zenOpenFocusedPage() end,
                }
                self._zen_full_page_preview = preview
                self[1] = FrameContainer:new{
                    width = self.dimen.w, height = self.dimen.h, padding = 0, margin = 0,
                    bordersize = 0, background = Blitbuffer.COLOR_WHITE,
                    OverlapGroup:new{
                        dimen = Geom:new{ w = self.dimen.w, h = self.dimen.h }, preview,
                        FrameContainer:new{
                            width = self.dimen.w, height = preview.top, bordersize = 0, padding = 0,
                            background = Blitbuffer.COLOR_WHITE,
                            VerticalGroup:new{ align = "center", header(self),
                                VerticalSpan:new{ width = top_pad } },
                        },
                        FrameContainer:new{
                            width = self.dimen.w, height = controls_h, bordersize = 0, padding = 0,
                            background = Blitbuffer.COLOR_WHITE,
                            overlap_offset = { 0, self.dimen.h - controls_h }, panel,
                        },
                        preview_divider(self, self.dimen.h - controls_h),
                        header_divider(self, top_pad),
                    },
                }
                self._zen_rebuilding_focus_layout = nil
                rebuild_focus_layout(self, desired_focus_id)
                return
            end
            self[1] = FrameContainer:new{
                width = self.dimen.w, height = self.dimen.h, padding = 0, margin = 0,
                bordersize = 0, background = Blitbuffer.COLOR_WHITE,
                OverlapGroup:new{
                    dimen = Geom:new{ w = self.dimen.w, h = self.dimen.h },
                    VerticalGroup:new{ align = "center", header(self),
                        VerticalSpan:new{ width = top_pad }, self.grid }, panel,
                    preview_divider(self, self.dimen.h - controls_h),
                    header_divider(self, top_pad),
                },
            }
            self._zen_rebuilding_focus_layout = nil
            rebuild_focus_layout(self, desired_focus_id)
            return
        end

        local nb_pages  = self.nb_pages  or 1
        local cur_page  = self.focus_page or self.cur_page or 1
        local grid_w    = self.grid_width or Screen:getWidth()

        -- Derive the thumbnail-span width from the actual layout, then use
        -- roughly half of that for the slider so it sits as a short centred
        -- track rather than spanning edge-to-edge.
        local thumb_span
        if self._zen_layout_mode == "carousel" then
            thumb_span = self.grid_item_width or math.floor(grid_w * 2 / 3)
        else
            local outer_margin = (self.grid[1] and self.grid[1].overlap_offset
                                  and self.grid[1].overlap_offset[1]) or 0
            thumb_span = math.max(1, grid_w - 2 * outer_margin)
        end
        local slider_w = math.floor(math.min(thumb_span * 0.95,
            grid_w * 0.76 - zen_icon_size - zen_icon_pad_v * 2 - Screen:scaleBySize(16)))

        local function chapter_title(pg)
            if not self.ui or not self.ui.toc then return "" end
            return self.ui.toc:getTocTitleByPage(pg) or ""
        end

        local label_face = Font:getFace("cfont", 18)

        -- Use focus_page consistently so slider position doesn't jump when switching views
        local cp = self.focus_page or cur_page
        local chap_label = TextWidget:new{
            text      = chapter_title(visible_page_raw(self, cp)),
            face      = label_face,
            max_width = math.floor(grid_w * 0.6),
            padding   = 0,
        }
        local progress_label = make_progress_label(page_progress_text(self, cp), math.floor(grid_w * 0.6))

        -- Throttle interval for setDirty during drag (seconds).
        -- GL16 takes ~450ms on Kobo; firing faster than this just queues
        -- competing waveform cycles that produce artifacts.
        -- Deferred full update used to debounce thumbnail re-render during drag.
        -- Fires after 250 ms of slider inactivity regardless of whether the
        -- finger is still down; if the user resumes dragging, on_change will
        -- re-enable scrubbing and reschedule.
        self._zen_deferred_update = function()
            logger.dbg("fired, setting post_scrub=true")
            self._zen_scrubbing = false
            self._zen_placeholders_painted = false
            self._zen_last_scrub_dirty = nil
            self._zen_post_scrub = true
            UIManager:unschedule(self._zen_post_scrub_clear)
            UIManager:scheduleIn(0.4, self._zen_post_scrub_clear)
            self:update()
        end

        -- Clears post-scrub suppression and fires one clean repaint to show
        -- all tiles that loaded during the suppression window without flashing.
        self._zen_post_scrub_clear = function()
            logger.dbg("fired, clearing post_scrub, scheduling setDirty")
            self._zen_post_scrub = false
            UIManager:setDirty(self, "ui", self._zen_scrub_dimen or self.dimen)
        end

        -- Paint the slider (and optionally chapter label) directly to
        -- Screen.bb, bypassing the widget tree.  Then queue an
        -- A2-waveform hardware refresh of just the slider area via
        -- setDirty(nil, ...) — nil means "don't repaint any widgets."
        -- A2 completes in ~60ms so frames can't pile up.
        local function directPaintSlider(sl, label, label_text, page)
            if not sl or not sl.dimen or not sl.dimen.x then return end
            sl:paintTo(Screen.bb, sl.dimen.x, sl.dimen.y)
            if label and label_text then
                local zone = self._zen_chapter_zone
                local prog = self._zen_progress_label
                label:setText(label_text)
                prog:setText(page_progress_text(self, page))
                local ch = label:getSize().h
                local label_y = zone.y + math.floor((zone.h - ch - prog:getSize().h) / 2)
                Screen.bb:paintRect(zone.x, zone.y, zone.w, zone.h, Blitbuffer.COLOR_WHITE)
                label:paintTo(Screen.bb, zone.x + math.floor((zone.w - label:getSize().w) / 2), label_y)
                prog:paintTo(Screen.bb, zone.x + math.floor((zone.w - prog:getSize().w) / 2), label_y + ch)
            end
            -- No A2 here — the caller pushes one consolidated refresh.
        end

        -- Paint blank placeholders with page-number badges directly to
        -- Screen.bb for all grid cells, then push one A2 refresh over
        -- the combined grid + slider region.
        --
        -- On the FIRST call after scrubbing starts, erase thumbnails and
        -- draw the static borders (they never move).  On subsequent calls,
        -- only erase + repaint the small badge area at the bottom of each
        -- cell — the borders stay untouched in the framebuffer.
        local badge_face_s = Font:getFace("cfont", 13)
        local ph_s         = Screen:scaleBySize(4)
        local pv_s         = Screen:scaleBySize(2)
        -- Pure B/W so A2 waveform renders the badge cleanly (same as chapter text).
        local bg_color_s   = Blitbuffer.COLOR_BLACK
        local fg_color_s   = Blitbuffer.COLOR_WHITE
        local gap_bot_s    = Screen:scaleBySize(3)
        local bs_s         = Size.border.thin

        -- Pre-measure the maximum badge height (constant for all cells).
        local _badge_h_sample = TextWidget:new{
            text = "0", face = badge_face_s, padding = 0,
        }
        local badge_max_h = _badge_h_sample:getSize().h + 2 * pv_s
        _badge_h_sample:free()

        local function directPaintScrub(focus_pg, chap_text)
            local pbw  = self
            local bb   = Screen.bb
            local sl   = pbw._zen_slider
            local clbl = pbw._zen_chap_label
            local grid = pbw.grid
            if not grid then return end

            local fp    = focus_pg or pbw.focus_page or 1
            local shift = pbw.focus_page_shift or 0
            local np    = pbw.nb_pages or 1
            local n     = pbw.nb_grid_items or 0

            -- Grid top-left in blitbuffer space
            local title_h = pbw.title_bar_h
            local gx = pbw.dimen.x or 0
            local gy = (pbw.dimen.y or 0) + title_h + top_pad

            local first_frame = not pbw._zen_placeholders_painted

            for i = 1, n do
                local item = grid[i]
                if item and item.overlap_offset then
                    local page_num = fp - shift + (i - 1)
                    local ox = item.overlap_offset[1]
                    local oy = item.overlap_offset[2]
                    local sz = item:getSize()

                    if first_frame then
                        -- Erase cell + draw static border (once)
                        bb:paintRect(gx + ox - bs_s, gy + oy - bs_s,
                                     sz.w + 2 * bs_s, sz.h + 2 * bs_s,
                                     Blitbuffer.COLOR_WHITE)
                        local tw = (pbw._zen_tile_size and pbw._zen_tile_size.w) or sz.w
                        local th = (pbw._zen_tile_size and pbw._zen_tile_size.h) or sz.h
                        local pdx = math.floor((sz.w - tw) / 2)
                        local pdy = math.floor((sz.h - th) / 2)
                        bb:paintBorder(gx + ox + pdx - bs_s, gy + oy + pdy - bs_s,
                                       tw + 2 * bs_s, th + 2 * bs_s,
                                       bs_s, Blitbuffer.COLOR_BLACK, 0)
                    end

                    -- Badge area: erase + repaint (every frame)
                    -- Clip to the interior of the border so we never
                    -- overwrite the bottom line or corner pixels.
                    local tw = (pbw._zen_tile_size and pbw._zen_tile_size.w) or sz.w
                    local th = (pbw._zen_tile_size and pbw._zen_tile_size.h) or sz.h
                    local pdx = math.floor((sz.w - tw) / 2)
                    local pdy = math.floor((sz.h - th) / 2)
                    local inner_x = gx + ox + pdx
                    local inner_bottom = gy + oy + pdy + th
                    local badge_bottom = get_badge_bottom(
                        pbw, item, sz.h, page_num == fp) or pdy + th
                    local badge_y = gy + oy + badge_bottom - badge_max_h - gap_bot_s
                    local erase_h = math.max(0, inner_bottom - badge_y)
                    if erase_h > 0 then
                        bb:paintRect(inner_x, badge_y, tw, erase_h,
                                 Blitbuffer.COLOR_WHITE)
                    end

                    if page_num >= 1 and page_num <= np then
                        local lbl = TextWidget:new{
                            text    = get_page_display_text(pbw, visible_page_raw(pbw, page_num)),
                            face    = badge_face_s,
                            fgcolor = fg_color_s,
                            padding = 0,
                        }
                        local lsz = lbl:getSize()
                        local bh  = lsz.h + 2 * pv_s
                        local bw  = math.max(lsz.w + 2 * ph_s, bh)
                        local bx  = gx + ox + math.floor((sz.w - bw) / 2)
                        local by  = gy + oy + badge_bottom - bh - gap_bot_s

                        local r_p = bh / 2
                        for row = 0, bh - 1 do
                            local dy = math.abs(row + 0.5 - r_p)
                            local dx = math.sqrt(math.max(0, r_p * r_p - dy * dy))
                            local x0 = math.ceil(bx + r_p - dx)
                            local x1 = math.floor(bx + bw - r_p + dx)
                            local w  = x1 - x0
                            if w > 0 then bb:paintRect(x0, by + row, w, 1, bg_color_s) end
                        end

                        lbl:paintTo(bb,
                            bx + math.floor((bw - lsz.w) / 2),
                            by + math.floor((bh - lsz.h) / 2))
                        lbl:free()
                    end
                end
            end

            pbw._zen_placeholders_painted = true

            -- Paint slider + chapter label
            directPaintSlider(sl, clbl, chap_text, fp)

            -- One A2 refresh over grid + label + slider avoids double flashes.
            -- DU can't render accent fills (ghosting), so a colored slider
            -- gets its own drag refresh; the 1px gap keeps UIManager from merging them.
            local scrub = pbw._zen_scrub_dimen or pbw.dimen
            if sl and sl.dimen and sl.dimen.y and Accent.isEnabled() then
                UIManager:setDirty(nil, "fast", Geom:new{ x = scrub.x, y = scrub.y,
                    w = scrub.w, h = math.max(0, sl.dimen.y - scrub.y - 1) })
                ZenSlider.refreshDrag(sl.dimen:copy(), true)
            else
                UIManager:setDirty(nil, "fast", scrub)
            end
        end

        -- Trailing scrub paint: shows the latest page once pan events pause.
        local SCRUB_PAINT_INTERVAL = time.ms(100)
        self._zen_scrub_dirty_func = function()
            if not self._zen_scrubbing then return end
            self._zen_last_scrub_dirty = time.now()
            directPaintScrub(self.focus_page or self.cur_page or 1,
                chapter_title(visible_page_raw(self, self.focus_page or self.cur_page or 1)))
        end

        -- Only create slider if there's more than 1 page
        local zen_slider
        if nb_pages > 1 then
            zen_slider = ZenSlider:new{
                width       = slider_w,
                value       = cp,
                value_min   = 1,
                value_max   = math.max(nb_pages, 1),
                on_change   = function(v)
                    -- Set scrubbing BEFORE updateFocusPage so that any
                    -- showTile callbacks it triggers are already suppressed,
                    -- preventing a flash of stale tile bitmaps on drag start.
                    local dragging = self._zen_slider and self._zen_slider._dragging
                    if dragging then
                        self._zen_scrubbing = true
                        -- Cancel any pending post-scrub clear so resuming a
                        -- drag after a pause doesn't re-enable tile refreshes.
                        UIManager:unschedule(self._zen_post_scrub_clear)
                    end
                    if self:updateFocusPage(v, false) then
                        if dragging then
                            UIManager:unschedule(self._zen_deferred_update)
                            UIManager:scheduleIn(0.25, self._zen_deferred_update)
                            -- Paint grid placeholders + slider + label directly to Screen.bb
                            -- with one A2 refresh, at most every SCRUB_PAINT_INTERVAL.
                            UIManager:unschedule(self._zen_scrub_dirty_func)
                            local last = self._zen_last_scrub_dirty
                            if last and time.now() - last < SCRUB_PAINT_INTERVAL then
                                UIManager:scheduleIn(time.to_s(SCRUB_PAINT_INTERVAL), self._zen_scrub_dirty_func)
                            else
                                self._zen_last_scrub_dirty = time.now()
                                directPaintScrub(v, chapter_title(visible_page_raw(self, v)))
                            end
                        else
                            UIManager:unschedule(self._zen_deferred_update)
                            UIManager:unschedule(self._zen_scrub_dirty_func)
                            self._zen_scrubbing = false
                            self._zen_placeholders_painted = false
                            self._zen_last_scrub_dirty = nil
                            self._zen_post_scrub = true
                            UIManager:unschedule(self._zen_post_scrub_clear)
                            UIManager:scheduleIn(0.4, self._zen_post_scrub_clear)
                            self:update()
                        end
                    end
                end,
            }
        end

        self._zen_slider     = zen_slider
        self._zen_chap_label = chap_label
        self._zen_progress_label = progress_label

        local pbw = self
        local function make_button(icon, callback)
            return ZenIconButton:new{
                file = icon, width = zen_icon_size, height = zen_icon_size,
                padding = zen_icon_pad_v, show_parent = self, callback = callback,
            }
        end
        for _i, mode in ipairs({ "single", "carousel", "grid" }) do
            self["_zen_switch_" .. mode] = function()
                pbw._zen_layout_mode = mode
                set_page_browser_layout(mode)
                pbw:updateLayout()
                UIManager:setDirty(pbw, "ui")
            end
        end
        local layout_button
        layout_button = make_button(utils.resolveIcon(_icons_dir, "grid"), function()
            local dialog, buttons = nil, {}
            local icon_size, gap = Screen:scaleBySize(24), Screen:scaleBySize(12)
            local padding = Size.padding.large + Screen:scaleBySize(6)
            local width = 0
            for i, entry in ipairs({ { "single", _("Single page"), "grid_slide" },
                { "carousel", _("Carousel"), "coverflow" }, { "grid", _("Grid"), "grid" } }) do
                local mode = entry[1]
                local text = entry[2] .. (pbw._zen_layout_mode == mode and " ✓" or "")
                local label = TextWidget:new{ text = text, face = Font:getFace("cfont", 20), bold = true }
                width = math.max(width, label:getSize().w)
                label:free()
                buttons[i] = { { text = text, align = "left", height = Screen:scaleBySize(32), padding_h = padding,
                    icon = utils.resolveIcon(_icons_dir, entry[3]),
                    callback = function()
                        UIManager:close(dialog)
                        pbw["_zen_switch_" .. mode]()
                    end } }
            end
            dialog = require("common/ui/zen_anchored_menu").new{
                buttons = buttons, anchor = layout_button.dimen,
                width = math.min(Screen:getWidth() * 0.9, width + icon_size + gap + padding * 2
                    + Size.border.window * 2 + Size.padding.button * 2),
            }
            UIManager:show(dialog)
        end)
        local search_button = make_button(utils.resolveIcon(_icons_dir, "quick_search"), function()
            if pbw.ui.search then pbw.ui.search._zen_page_browser = pbw end -- cleared in onClose
            pbw.ui:handleEvent(Event:new("ShowFulltextSearchInput"))
        end)
        local skip_left_btn = make_button(resolve_stock_icon("chevron.left"), function() pbw:onScrollPageUp() end)
        local skip_right_btn = make_button(resolve_stock_icon("chevron.right"), function() pbw:onScrollPageDown() end)
        -- Chapter-skip: jump to nearest TOC boundary before/after focus_page
        local function skip_to_prev_chapter()
            if not pbw.ui or not pbw.ui.toc or not pbw.ui.toc.toc then return end
            local cur = visible_page_raw(pbw, pbw.focus_page or pbw.cur_page or 1)
            for i = #pbw.ui.toc.toc, 1, -1 do
                local e = pbw.ui.toc.toc[i]
                if e.page and e.page < cur then
                    if pbw:updateFocusPage(visible_page_index(pbw, e.page), false) then pbw:update() end
                    return
                end
            end
        end
        local function skip_to_next_chapter()
            if not pbw.ui or not pbw.ui.toc or not pbw.ui.toc.toc then return end
            local cur = visible_page_raw(pbw, pbw.focus_page or pbw.cur_page or 1)
            for _i, e in ipairs(pbw.ui.toc.toc) do
                if e.page and e.page > cur then
                    if pbw:updateFocusPage(visible_page_index(pbw, e.page), false) then pbw:update() end
                    return
                end
            end
        end
        self._zen_skip_prev = skip_to_prev_chapter
        self._zen_skip_next = skip_to_next_chapter

        self._zen_layout_button = layout_button
        self._zen_search_button = search_button
        self._zen_btn_skip_left = skip_left_btn
        self._zen_btn_skip_right = skip_right_btn
        skip_left_btn.hold_callback = skip_to_prev_chapter
        skip_right_btn.hold_callback = skip_to_next_chapter
        local button_size = layout_button:getSize()
        local row_h = button_size.h
        local panel_y = self.dimen.h - zen_panel_h
        local chapter_y = zen_panel_pad_top + actions_h
        local slider_y = chapter_y + row_h + Screen:scaleBySize(slider_gap)
        local contents = OverlapGroup:new{
            dimen = Geom:new{ w = grid_w, h = zen_panel_h }, allow_mirroring = false,
            preview_divider(self, actions_h),
        }
        if self._zen_page_actions then
            self._zen_page_actions.overlap_offset = { 0, 0 }
            contents[#contents + 1] = self._zen_page_actions
        end
        local chapter_w = math.floor(grid_w * 0.6)
        local chapter_x = math.floor((grid_w - chapter_w) / 2)
        add_chapter_rows(contents, chapter_x, chapter_y, chapter_w, row_h, chap_label, progress_label)
        self._zen_chapter_zone = Geom:new{
            x = (self.dimen.x or 0) + chapter_x,
            y = (self.dimen.y or 0) + panel_y + chapter_y, w = chapter_w, h = row_h,
        }
        for i, button in ipairs({ layout_button, skip_left_btn, skip_right_btn, search_button }) do
            local x = math.floor(grid_w * (i <= 2 and 0.12 or 0.88) - button_size.w / 2)
            local y = (i == 1 or i == 4) and chapter_y or slider_y
            button.overlap_offset = { x, y }
            contents[#contents + 1] = button
            local zone = Geom:new{ x = (self.dimen.x or 0) + x, y = (self.dimen.y or 0) + panel_y + y,
                w = button_size.w, h = row_h }
            if i == 1 then self._zen_layout_zone = zone
            elseif i == 2 then self._zen_btn_skip_left_zone = zone
            elseif i == 3 then self._zen_btn_skip_right_zone = zone
            else self._zen_search_zone = zone end
        end
        if zen_slider then
            local slider_row = CenterContainer:new{
                dimen = Geom:new{ w = grid_w, h = row_h }, zen_slider,
                overlap_offset = { 0, slider_y },
            }
            contents[#contents + 1] = slider_row
        end
        self._zen_panel_h = zen_panel_h

        local panel = FrameContainer:new{
            width      = grid_w,
            height     = zen_panel_h,
            padding    = 0,
            margin     = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            contents,
        }
        -- Pin panel to absolute screen bottom; grid gets the full space above.
        panel.overlap_offset = { 0, self.dimen.h - zen_panel_h }
        self._zen_row_panel = panel

        -- Use an OverlapGroup so the panel hovers over the bottom of the
        -- screen independently of the grid's natural height.  The
        -- VerticalGroup (title + small gap + grid) occupies the upper
        -- portion; the panel is drawn over the dead space below the grid.
        self[1] = FrameContainer:new{
            width      = self.dimen.w,
            height     = self.dimen.h,
            padding    = 0,
            margin     = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            OverlapGroup:new{
                dimen = Geom:new{ w = self.dimen.w, h = self.dimen.h },
                VerticalGroup:new{
                    align = "center",
                    header(self),
                    VerticalSpan:new{ width = top_pad },
                    self.grid,
                },
                panel,
                header_divider(self, top_pad),
            }
        }
        self._zen_rebuilding_focus_layout = nil
        rebuild_focus_layout(self, desired_focus_id)
    end

    -- ----------------------------------------------------------------
    -- 3. Update slider/labels whenever the focus page changes
    -- ----------------------------------------------------------------
    local _orig_update = PageBrowserWidget.update
    PageBrowserWidget.update = function(self)
        if is_full_page(self) then
            if self._zen_full_page_preview then
                self._zen_full_page_preview:setPage(self:_zenFocusedDocumentPage())
            end
            if not self._zen_rebuilding_focus_layout then rebuild_focus_layout(self) end
            UIManager:setDirty(self, "ui")
            return
        end
        local desired_focus_id = current_focus_id(self)
        logger.dbg("focus_page=", self.focus_page, "cur_page=", self.cur_page,
            "scrubbing=", self._zen_scrubbing, "post_scrub=", self._zen_post_scrub,
            "nb_grid_items=", self.nb_grid_items, "nb_pages=", self.nb_pages)
        configure_carousel_grid(self)
        -- On the very first call (focus_page is nil, init → updateLayout → update),
        -- pre-initialise focus_page from cur_page with clamping so the grid
        -- never displays blank leading/trailing slots.  Subsequent calls
        -- (slider drag, scroll) already carry a valid focus_page and don't
        -- need adjustment.
        local shift = self.focus_page_shift
        local items = self.nb_grid_items
        local total = self.nb_pages
        if self._zen_layout_mode ~= "carousel"
            and not self.focus_page and shift and items and total and total >= items then
            local fp     = self.cur_page or 1
            local min_fp = shift + 1
            local max_fp = math.max(min_fp, total - items + 1 + shift)
            self.focus_page = math.max(min_fp, math.min(max_fp, fp))
            logger.dbg("clamped focus_page to", self.focus_page)
        end

        -- Block showTile() from re-adding native page number widgets.
        for i = 1, (self.nb_grid_items or 0) do
            if self.grid[i] then self.grid[i].show_pagenum = false end
        end

        -- _orig_update writes BookMapRow into self.row (detached CenterContainer).
        -- When non-linear fragments are hidden, make its logical page slots
        -- request thumbnails for the matching linear document page instead.
        local t0 = os.clock()
        local thumbnail = self._zen_visible_pages and self.ui and self.ui.thumbnail
        local orig_get_thumbnail = thumbnail and thumbnail.getPageThumbnail
        local orig_has_hidden_flows = self.has_hidden_flows
        if orig_get_thumbnail then
            thumbnail.getPageThumbnail = function(thumb, page, ...)
                return orig_get_thumbnail(thumb, visible_page_raw(self, page), ...)
            end
            -- The native stripe overlay is for visible hidden fragments.
            self.has_hidden_flows = false
            self._zen_mapping_thumbnails = true
        end
        local restore_focus_layout = self._zen_focus_enabled
            and self._zen_focus_layout_ready and self.build_focus_layout
        if restore_focus_layout then self.build_focus_layout = false end
        local ok, err = pcall(_orig_update, self)
        if restore_focus_layout then self.build_focus_layout = true end
        if orig_get_thumbnail then
            thumbnail.getPageThumbnail = orig_get_thumbnail
            self.has_hidden_flows = orig_has_hidden_flows
            self._zen_mapping_thumbnails = nil
        end
        if not ok then error(err, 0) end

        -- Keep the next page that can enter from either edge warm. The
        -- native update already requests focus-1/focus/focus+1; KOReader's
        -- optional broader preloader covers these lookahead pages too.
        if self._zen_layout_mode == "carousel"
            and not G_reader_settings:isTrue("page_browser_preload_thumbnails") then
            local focus_page = self.focus_page or self.cur_page or 1
            self:preloadThumbnail(focus_page - 2, "preload carousel previous")
            self:preloadThumbnail(focus_page + 2, "preload carousel next")
        end

        self._zen_page_label_text_cache = nil
        self._zen_page_label_source = nil
        logger.perf("Original update completed", (os.clock() - t0) * 1000)

        -- Clean up any page num widgets that slipped through (e.g. async tiles).
        for i = #self.grid, 1, -1 do
            if self.grid[i] and self.grid[i].is_page_num_widget then
                if self.grid[i].free then self.grid[i]:free() end
                table.remove(self.grid, i)
            end
        end

        -- Display info for the focus page.
        local fp    = self.focus_page or self.cur_page or 1
        local np    = self.nb_pages or 1
        local cp    = math.max(1, math.min(np, fp))

        if self._zen_slider then
            self._zen_slider:setValue(cp)
        end
        if self._zen_chap_label then
            local title = ""
            if self.ui and self.ui.toc then
                title = self.ui.toc:getTocTitleByPage(visible_page_raw(self, cp)) or ""
            end
            self._zen_chap_label:setText(title)
        end
        if self._zen_progress_label then
            self._zen_progress_label:setText(page_progress_text(self, cp))
        end
        if not self._zen_rebuilding_focus_layout then
            rebuild_focus_layout(self, desired_focus_id)
        end
    end

    -- ----------------------------------------------------------------
    -- 3a. showTile: cache actual tile pixel dimensions so scrubbing
    --     placeholders can draw borders at the correct centred position.
    -- ----------------------------------------------------------------
    local _orig_showTile = PageBrowserWidget.showTile
    local function show_tile(self, grid_idx, page, tile, do_refresh)
        local cur_page = self.cur_page
        local has_hidden_flows = self.has_hidden_flows
        if self._zen_layout_mode == "carousel" then
            self.cur_page = self.focus_page or cur_page
        end
        if self._zen_visible_pages then self.has_hidden_flows = false end
        local ok, result = pcall(_orig_showTile, self, grid_idx, page, tile, do_refresh)
        self.cur_page = cur_page
        self.has_hidden_flows = has_hidden_flows
        if not ok then error(result, 0) end
        return result
    end

    PageBrowserWidget.showTile = function(self, grid_idx, page, tile, do_refresh)
        local has_bitmap = tile and tile.bb ~= nil
        if tile and tile.bb and not self._zen_tile_size then
            self._zen_tile_size = {
                w = tile.bb:getWidth(),
                h = tile.bb:getHeight(),
            }
            logger.dbg("first tile bitmap seen, size", self._zen_tile_size.w, self._zen_tile_size.h)
        end
        -- During scrubbing and for one full repaint cycle after scrubbing
        -- ends, suppress per-tile display refreshes.  Without this, each
        -- async tile that loads fires its own hardware update, producing
        -- the multi-flash artifact on the panel area.
        -- _zen_post_scrub is cleared by the next paintTo call.
        local suppressed = (self._zen_scrubbing or self._zen_post_scrub) and do_refresh
        logger.dbg("idx=", grid_idx, "page=", page, "has_bitmap=", has_bitmap,
            "do_refresh=", do_refresh, "suppressed=", suppressed ~= nil and suppressed ~= false,
            "scrubbing=", self._zen_scrubbing, "post_scrub=", self._zen_post_scrub)
        if suppressed then
            return show_tile(self, grid_idx, page, tile, false)
        end
        return show_tile(self, grid_idx, page, tile, do_refresh)
    end

    local _orig_preloadThumbnail = PageBrowserWidget.preloadThumbnail
    if _orig_preloadThumbnail then
        PageBrowserWidget.preloadThumbnail = function(self, page, dbg_msg)
            if not self._zen_visible_pages or self._zen_mapping_thumbnails then
                return _orig_preloadThumbnail(self, page, dbg_msg)
            end
            if page < 1 or page > self.nb_pages then return end
            self.ui.thumbnail:getPageThumbnail(
                visible_page_raw(self, page),
                self.grid_item_width,
                self.grid_item_height,
                self.requests_batch_id,
                function() end
            )
        end
    end

    -- ----------------------------------------------------------------
    -- 4. paintTo: suppress the viewfinder overlay; page-number badges
    -- ----------------------------------------------------------------
    PageBrowserWidget.paintTo = function(self, bb, x, y)
        local InputContainer = require("ui/widget/container/inputcontainer")
        InputContainer.paintTo(self, bb, x, y)
        -- viewfinder border and row-lines intentionally omitted

        if is_full_page(self) then return end
        if is_content_tab(self._zen_active_tab) then return end
        if not (self.grid and self.focus_page) then return end

        local fp    = self.focus_page
        local shift = self.focus_page_shift or 0
        local np    = self.nb_pages or 1

        -- Grid top-left in blitbuffer coordinate space.
        -- OverlapGroup child 1 = VerticalGroup: header → span(top_pad) → grid.
        local title_h = self.title_bar_h
        local gx      = x
        local gy      = y + title_h + Screen:scaleBySize(preview_padding)

        local badge_face = Font:getFace("cfont", 13)
        local ph         = Screen:scaleBySize(4)   -- badge horiz padding
        local pv         = Screen:scaleBySize(2)   -- badge vert  padding
        local bg_color   = Blitbuffer.gray(0x33)   -- dark badge fill
        local fg_color   = Blitbuffer.gray(0xFF)   -- white badge text
        local gap_bot    = Screen:scaleBySize(3)   -- badge offset from thumb bottom

        -- paintPill: horizontal capsule (rounded left/right, flat top/bottom).
        -- Matches the library page-count badge.
        local function paintPill(bx, by, bw, bh, color)
            local r = bh / 2
            for row = 0, bh - 1 do
                local dy = math.abs(row + 0.5 - r)
                local dx = math.sqrt(math.max(0, r * r - dy * dy))
                local x0 = math.ceil(bx + r - dx)
                local x1 = math.floor(bx + bw - r + dx)
                local w  = x1 - x0
                if w > 0 then bb:paintRect(x0, by + row, w, 1, color) end
            end
        end

        -- Only iterate the real thumbnail slots (1..nb_grid_items).
        local n = self.nb_grid_items or 0
        for i = 1, n do
            local item = self.grid[i]
            if item and item.overlap_offset then
                local page_num = fp - shift + (i - 1)
                if page_num >= 1 and page_num <= np then
                    local ox = item.overlap_offset[1]
                    local oy = item.overlap_offset[2]
                    local sz = item:getSize()

                    -- While scrubbing: blank the cell then draw a bordered
                    -- placeholder sized to match the actual thumbnail.
                    if self._zen_scrubbing then
                        local bs = Size.border.thin
                        -- Erase full cell + overflow so stale thumbnail +
                        -- its border are completely hidden.
                        bb:paintRect(gx + ox - bs, gy + oy - bs,
                                     sz.w + 2 * bs, sz.h + 2 * bs,
                                     Blitbuffer.COLOR_WHITE)
                        -- Border sized to the cached tile pixel dimensions,
                        -- centred in the cell exactly as CenterContainer would.
                        -- Falls back to full cell until the first tile is seen.
                        local tw = (self._zen_tile_size and self._zen_tile_size.w) or sz.w
                        local th = (self._zen_tile_size and self._zen_tile_size.h) or sz.h
                        local pdx = math.floor((sz.w - tw) / 2)
                        local pdy = math.floor((sz.h - th) / 2)
                        bb:paintBorder(gx + ox + pdx - bs, gy + oy + pdy - bs,
                                       tw + 2 * bs, th + 2 * bs,
                                       bs, Blitbuffer.COLOR_BLACK, 0)
                    end

                    if not self._zen_scrubbing then
                        local thumb = item[1] and item[1][1]
                        local image = thumb and thumb.is_page_thumbnail and thumb[1]
                        local dimen = image and image.dimen
                        if dimen then
                            References.paintPin(self.ui, visible_page_raw(self, page_num), bb,
                                dimen.x, dimen.y, dimen.w, dimen.h)
                        end
                    end
                    local badge_bottom = get_badge_bottom(
                        self, item, sz.h, page_num == fp)
                    if badge_bottom then
                        local label = TextWidget:new{
                            text    = get_page_display_text(self, visible_page_raw(self, page_num)),
                            face    = badge_face,
                            fgcolor = fg_color,
                            padding = 0,
                        }
                        local lsz = label:getSize()
                        local bh  = lsz.h + 2 * pv
                        local bw  = math.max(lsz.w + 2 * ph, bh)  -- never narrower than a circle
                        local bx  = gx + ox + math.floor((sz.w - bw) / 2)
                        local by  = gy + oy + badge_bottom - bh - gap_bot

                        paintPill(bx, by, bw, bh, bg_color)
                        label:paintTo(bb,
                            bx + math.floor((bw - lsz.w) / 2),
                            by + math.floor((bh - lsz.h) / 2))
                        label:free()
                    end
                end
            end
        end
    end

    -- ----------------------------------------------------------------
    -- 5. Gesture handling: slider, view-toggle buttons, panel boundary
    -- ----------------------------------------------------------------
    local function move_carousel_to_page(pbw, page)
        local focus_page = pbw.focus_page or pbw.cur_page
        if pbw._zen_layout_mode ~= "carousel" or not page
            or page == focus_page then
            return false
        end
        if pbw:updateFocusPage(page, false) then pbw:update() end
        return true
    end

    local function scroll_carousel(pbw, delta)
        if pbw._zen_layout_mode ~= "carousel" then return false end
        if pbw:updateFocusPage(delta, true) then pbw:update() end
        return true
    end

    local _orig_onScrollPageUp = PageBrowserWidget.onScrollPageUp
    PageBrowserWidget.onScrollPageUp = function(self)
        if scroll_carousel(self, -1) then return true end
        if _orig_onScrollPageUp then return _orig_onScrollPageUp(self) end
        return true
    end

    local _orig_onScrollPageDown = PageBrowserWidget.onScrollPageDown
    PageBrowserWidget.onScrollPageDown = function(self)
        if scroll_carousel(self, 1) then return true end
        if _orig_onScrollPageDown then return _orig_onScrollPageDown(self) end
        return true
    end

    local _orig_updateFocusPage = PageBrowserWidget.updateFocusPage
    PageBrowserWidget.updateFocusPage = function(self, ...)
        local changed = _orig_updateFocusPage(self, ...)
        if changed and self._zen_active_tab == "aa" and self.ui.rolling then
            self._zen_preview_xpointer = self.ui.document:getPageXPointer(self:_zenFocusedDocumentPage())
        end
        return changed
    end

    local function outside_preview(pbw, ges)
        return ges.pos and (ges.pos.y < pbw.title_bar_h
            or ges.pos.y >= pbw.dimen.y + pbw.dimen.h - (pbw._zen_panel_h or 0))
    end

    local function handle_carousel_side_tap(pbw, pos)
        if pbw._zen_layout_mode ~= "carousel" or not (pbw.grid and pos) then
            return false
        end
        for idx = 1, 3, 2 do
            local item = pbw.grid[idx]
            if item and item.dimen and pos:intersectWith(item.dimen) then
                move_carousel_to_page(pbw, item.page_idx)
                return true
            end
        end
        return false
    end

    local _orig_onTap = PageBrowserWidget.onTap
    PageBrowserWidget.onTap = function(self, arg, ges)
        logger.dbg("onTap at", ges.pos.x, ges.pos.y)
        if self._zen_status_row and self._zen_status_row.dimen and self._zen_status_row.dimen:contains(ges.pos) then
            require("modules/global/patches/menu_top_swipe").handleTap(nil, ges)
            return true
        end
        for _i, button in ipairs(self._zen_page_actions and self._zen_page_actions.buttons or {}) do
            if button.dimen:contains(ges.pos) then button.callback(); return true end
        end
        for _i, cell in ipairs(self._zen_tab_bar and self._zen_tab_bar.cells or {}) do
            if cell.dimen and cell.dimen:contains(ges.pos) then cell.callback(); return true end
        end
        if is_content_tab(self._zen_active_tab) then return true end
        if self._zen_active_tab == "aa" and outside_preview(self, ges) then return true end
        if is_full_page(self) then self:_zenOpenFocusedPage(); return true end
        -- 1. Slider tap → navigate to that page.
        if self._zen_slider and self._zen_slider:handleTap(ges) then
            logger.dbg("onTap → slider")
            return true
        end
        -- 2. Chevron buttons: tap to move the page-browser viewport.
        if self._zen_btn_skip_left_zone
           and self._zen_btn_skip_left_zone:contains(ges.pos) then
            self:onScrollPageUp()
            return true
        end
        if self._zen_btn_skip_right_zone
           and self._zen_btn_skip_right_zone:contains(ges.pos) then
            self:onScrollPageDown()
            return true
        end
        if self._zen_layout_zone and self._zen_layout_zone:contains(ges.pos) then
            self._zen_layout_button.callback()
            return true
        end
        if self._zen_search_zone and self._zen_search_zone:contains(ges.pos) then
            self._zen_search_button.callback()
            return true
        end
        -- 4. Any tap inside the panel strip → swallow.  Without this a
        --    tap falls through to _orig_onTap which hits the thumbnail
        --    behind the panel, navigates the page, and the slider jumps.
        local panel_h = self._zen_panel_h or 0
        if panel_h > 0 and self.dimen
           and ges.pos.y >= (self.dimen.y + self.dimen.h - panel_h) then
            return true
        end
        -- Side previews recenter in carousel mode; the center page keeps
        -- the native tap behavior and opens in the reader.
        if handle_carousel_side_tap(self, ges.pos) then return true end
        -- Native page slots use linear-page indexes while this Zen view is
        -- active; translate a thumbnail tap back to its document page.
        if self._zen_visible_pages and self.grid then
            for idx = 1, self.nb_grid_items do
                if ges.pos:intersectWith(self.grid[idx].dimen) then
                    local page = self.grid[idx].page_idx
                    if page then
                        self:onClose(true)
                        self.ui.link:addCurrentLocationToStack()
                        self.ui:handleEvent(Event:new("GotoPage", visible_page_raw(self, page)))
                        return true
                    end
                    break
                end
            end
        end
        -- 5. Thumbnail grid area → native handler.
        return _orig_onTap(self, arg, ges)
    end

    PageBrowserWidget.onPan = function(self, arg, ges)
        if self._zen_slider and not self._zen_slider_locked then
            if self._zen_slider:handlePan(ges) then return true end
        end
        return true  -- swallow all other pans
    end

    PageBrowserWidget.onPanRelease = function(self, arg, ges)
        if self._zen_slider
           and self._zen_slider:handlePanRelease(ges, self, self.dimen) then
            -- handlePanRelease fires on_change only when the slider value
            -- actually changes; if the release lands on the same page as
            -- the last pan, on_change won't fire and _zen_scrubbing would
            -- stay true until the 250 ms deferred fires.  Always clean up
            -- here so thumbnails reload immediately on finger lift.
            if self._zen_scrubbing then
                UIManager:unschedule(self._zen_deferred_update)
                self._zen_scrubbing = false
                self._zen_placeholders_painted = false
                self._zen_post_scrub = true
                UIManager:unschedule(self._zen_post_scrub_clear)
                UIManager:scheduleIn(0.4, self._zen_post_scrub_clear)
                self:update()
            end
            return true
        end
        -- Swallow releases in the panel strip (e.g. near button group).
        local panel_h = self._zen_panel_h or 0
        if panel_h > 0 and self.dimen
           and ges.pos.y >= (self.dimen.y + self.dimen.h - panel_h) then
            return true
        end
        return true
    end

    -- ----------------------------------------------------------------
    -- 6. Gesture lockdown: only horizontal swipe (page prev/next)
    -- ----------------------------------------------------------------
    PageBrowserWidget.onSwipe = function(self, _arg, ges)
        -- Top-edge swipe down opens the reader menu from every tab.
        if ges.direction == "south" and ges.pos.y < Device.screen:getHeight() * 0.14 then
            local ok_rui, RUI = pcall(require, "apps/reader/readerui")
            if ok_rui and RUI and RUI.instance then
                local reader_menu = RUI.instance.menu
                if reader_menu and reader_menu.activation_menu ~= "tap" then
                    reader_menu:onShowMenu(reader_menu:_getTabIndexFromLocation(ges))
                    return true
                end
            end
        end
        if self._zen_active_tab and self._zen_active_tab ~= "browser"
            and (self._zen_active_tab ~= "aa" or outside_preview(self, ges)) then return true end
        -- A fast drag on the slider is classified as a swipe rather than
        -- pan + pan_release; ZenSlider.handleSwipe covers both cases.
        if self._zen_slider and not self._zen_slider_locked then
            -- Pre-set scrubbing BEFORE handleSwipe so that on_change's
            -- call to updateFocusPage (which triggers async tile loads)
            -- already has the suppress flag set when was_dragging=false.
            -- If handleSwipe doesn't claim the gesture we clear it below.
            self._zen_scrubbing = true
            UIManager:unschedule(self._zen_post_scrub_clear)
            if self._zen_slider:handleSwipe(ges, self, self.dimen) then
                -- was_dragging=false: on_change already fired and transitioned
                -- to _zen_post_scrub, so _zen_scrubbing is now false. Nothing to do.
                -- was_dragging=true: on_change never fires; clean up here.
                if self._zen_scrubbing then
                    UIManager:unschedule(self._zen_deferred_update)
                    self._zen_scrubbing = false
                    self._zen_placeholders_painted = false
                    self._zen_post_scrub = true
                    UIManager:scheduleIn(0.4, self._zen_post_scrub_clear)
                    self:update()
                end
                return true
            end
            -- handleSwipe didn't claim the gesture; undo the pre-set.
            self._zen_scrubbing = false
            self._zen_placeholders_painted = false
        end
        local direction = ges.direction
        if direction == "west" then
            self:onScrollPageDown()
            return true
        elseif direction == "east" then
            self:onScrollPageUp()
            return true
        end
        return true  -- swallow remaining north/south and anything else
    end

    PageBrowserWidget.onThumbnailHold = function(self, page)
        local Labels = require("common/ui/button_labels")
        local settings = self._zen_plugin.config.highlight_lookup or {}
        local labels = settings.show_labels == true
        local pinned = References.isPinned(self.ui, page)
        local pin_icon = pinned and "pin_remove" or "pin"
        local bookmarked = self.ui.bookmark:isPageBookmarked(
            self.ui.rolling and self.ui.document:getPageXPointer(page) or page)
        local bookmark_icon = bookmarked and "bookmark_remove" or "bookmark"
        local page_dimen = self._zen_full_page_preview and self._zen_full_page_preview.dimen
        if not page_dimen then
            for idx = 1, self.nb_grid_items or 0 do
                local item = self.grid[idx]
                if item.page_idx and visible_page_raw(self, item.page_idx) == page then
                    page_dimen = item.dimen
                    break
                end
            end
        end
        local dialog
        local function refresh()
            UIManager:close(dialog)
            if self._zen_full_page_preview then self._zen_full_page_preview:invalidate() end
            self:updateEditableStuff(true)
            UIManager:setDirty(self, "ui")
        end
        local buttons = {{
            { id = "bookmark", icon = utils.resolveIcon(_icons_dir, bookmark_icon)
                    or utils.resolveLocalIcon(_icons_dir, bookmark_icon),
                text = labels and _("Toggle page bookmark") or nil,
                callback = function()
                    self.ui.bookmark:toggleBookmark(page)
                    refresh()
                end },
            { id = "pin", icon = utils.resolveIcon(_icons_dir, pin_icon)
                    or utils.resolveLocalIcon(_icons_dir, pin_icon),
                text = labels and (pinned and _("Remove pin") or _("Pin")) or nil,
                callback = function()
                    References.setPin(self.ui, page, pinned)
                    refresh()
                end },
        }}
        if labels then buttons = Labels.prepare(buttons) end
        require("modules/reader/highlight_menu_items").compact(buttons)
        dialog = require("ui/widget/buttondialog"):new{
            name = "page_browser_page_actions", buttons = buttons,
            shrink_unneeded_width = not labels,
            anchor = page_dimen and function()
                local size = dialog:getContentSize()
                return {
                    x = page_dimen.x + math.floor((page_dimen.w - size.w) / 2),
                    y = page_dimen.y + math.floor((page_dimen.h - size.h) / 2),
                    w = size.w, h = 0,
                }, true
            end or nil,
        }
        if labels then Labels.apply(dialog.buttontable, buttons) end
        UIManager:show(dialog)
    end

    -- Holds on the navigation chevrons skip chapters. Other holds in the
    -- bottom panel stay suppressed to avoid the native book-map-row popup.
    local _orig_onHold = PageBrowserWidget.onHold
    PageBrowserWidget.onHold = function(self, arg, ges)
        if self._zen_active_tab and self._zen_active_tab ~= "browser"
            and (self._zen_active_tab ~= "aa" or outside_preview(self, ges)) then return true end
        if is_full_page(self) then
            self:onThumbnailHold(self:_zenFocusedDocumentPage(), ges)
            return true
        end
        if ges.pos and self._zen_btn_skip_left_zone
           and self._zen_btn_skip_left_zone:contains(ges.pos) then
            if self._zen_skip_prev then self._zen_skip_prev() end
            return true
        end
        if ges.pos and self._zen_btn_skip_right_zone
           and self._zen_btn_skip_right_zone:contains(ges.pos) then
            if self._zen_skip_next then self._zen_skip_next() end
            return true
        end
        local panel_h = self._zen_panel_h or 0
        if panel_h > 0 and self.dimen
           and ges.pos.y >= (self.dimen.y + self.dimen.h - panel_h) then
            return true  -- swallow
        end
        if self._zen_visible_pages and self.grid and ges.pos then
            for idx = 1, self.nb_grid_items do
                if ges.pos:intersectWith(self.grid[idx].dimen) then
                    local page = self.grid[idx].page_idx
                    if page then
                        self:onThumbnailHold(visible_page_raw(self, page), ges)
                        return true
                    end
                    break
                end
            end
        end
        if _orig_onHold then return _orig_onHold(self, arg, ges) end
    end

    PageBrowserWidget.onPinch  = function() return true end
    PageBrowserWidget.onSpread = function() return true end
    PageBrowserWidget.onMultiSwipe = function(self, arg, ges)
        if self._zen_slider then
            self._zen_slider:handleMultiSwipe(ges, self, self.dimen)
        end
        -- handleMultiSwipe can also terminate a drag without firing on_change.
        if self._zen_scrubbing then
            UIManager:unschedule(self._zen_deferred_update)
            self._zen_scrubbing = false
            self._zen_placeholders_painted = false
            self._zen_post_scrub = true
            UIManager:unschedule(self._zen_post_scrub_clear)
            UIManager:scheduleIn(0.4, self._zen_post_scrub_clear)
            self:update()
        end
        -- Swallow all multiswipes; never close the page browser.
        return true
    end

    local _orig_onFocusMove = PageBrowserWidget.onFocusMove
    PageBrowserWidget.onFocusMove = function(self, args)
        if not (self._zen_focus_enabled and self._zen_focus_layout_ready) then
            return _orig_onFocusMove and _orig_onFocusMove(self, args)
        end
        local dx = args and args[1] or 0
        local dy = args and args[2] or 0
        local selected = self.selected or { x = 1, y = 1 }
        local selected_row = self.layout and self.layout[selected.y]
        local selected_widget = selected_row and selected_row[selected.x]
        local selected_id = selected_widget and selected_widget._zen_focus_id or ""
        if dx ~= 0 and selected_id:sub(1, 7) ~= "footer:" then
            if BD.mirroredUILayout() then dx = -dx end
        end
        local row = selected_row
        if not row then return true end
        local target_x, target_y = selected.x, selected.y
        if dx ~= 0 then
            target_x = math.max(1, math.min(#row, selected.x + dx))
        elseif dy ~= 0 then
            target_y = math.max(1, math.min(#self.layout, selected.y + dy))
            local target_row = self.layout[target_y]
            if target_y ~= selected.y and target_row then
                target_x = math.floor((selected.x - 0.5) * #target_row / #row) + 1
                target_x = math.max(1, math.min(#target_row, target_x))
            end
        end
        if target_x == selected.x and target_y == selected.y then return true end
        local current = row[selected.x]
        local target = self.layout[target_y] and self.layout[target_y][target_x]
        if not target then return true end
        if current and type(current.handleEvent) == "function" then
            current:handleEvent(Event:new("Unfocus"))
        end
        self.selected = { x = target_x, y = target_y }
        if type(target.handleEvent) == "function" then
            target:handleEvent(Event:new("Focus"))
        end
        UIManager:setDirty(self, "fast")
        return true
    end

    local function handle_focus_key(pbw, key, allow_confirm)
        if not (pbw._zen_focus_enabled and key and type(key.match) == "function") then
            return false
        end
        local direction
        if key:match({ "Up" }) then
            direction = { 0, -1 }
        elseif key:match({ "Right" }) then
            direction = { 1, 0 }
        elseif key:match({ "Down" }) then
            direction = { 0, 1 }
        elseif key:match({ "Left" }) then
            direction = { -1, 0 }
        end
        local info = pbw._zen_active_tab == "book_details" and pbw._zen_content_panel
        if info and info._zen_focus_enabled then
            local leave_content = direction and direction[2] == -1
                and (info._zen_focus_area == "tags" or not info._tag_buttons
                    and (not info._description_widget or info:_descriptionAtTop()))
            if not leave_content then
                if allow_confirm then return info:onKeyPress(key) end
                return info:onKeyRepeat(key)
            end
        end
        if direction then
            pbw:onFocusMove(direction)
            return true
        end
        if allow_confirm and (key:match({ "Press" })
                or key:match({ "Return" }) or key:match({ "Enter" })) then
            local selected = pbw.selected
            local row = selected and pbw.layout and pbw.layout[selected.y]
            local focused = row and row[selected.x]
            local page_index = focused and focused._zen_focus_id
                and tonumber(focused._zen_focus_id:match("^page:(%d+)$"))
            local page = page_index and pbw.grid and pbw.grid[page_index]
                and pbw.grid[page_index].page_idx
            if move_carousel_to_page(pbw, page) then return true end
            if page then
                pbw:onClose(true)
                pbw.ui.link:addCurrentLocationToStack()
                pbw.ui:handleEvent(Event:new("GotoPage", visible_page_raw(pbw, page)))
                return true
            end
            if focused and focused.callback then focused.callback(); return true end
            pbw:onPress()
            return true
        end
        return false
    end

    local _orig_handleEvent = PageBrowserWidget.handleEvent
    PageBrowserWidget.handleEvent = function(self, event)
        local gesture = event.handler == "onGesture" and event.args[1]
            or event.handler == "onTap" and event.args[2]
        local tabs = self._zen_tab_bar
        if gesture and gesture.pos and tabs and tabs.dimen and tabs.dimen:contains(gesture.pos) then
            if gesture.ges == "tap" or event.handler == "onTap" then
                for _i, cell in ipairs(tabs.cells) do
                    if cell.dimen and cell.dimen:contains(gesture.pos) then cell.callback(); break end
                end
            end
            return true
        end
        if (event.handler == "onKeyPress" or event.handler == "onKeyRepeat")
            and handle_focus_key(self, event.args[1], event.handler == "onKeyPress") then
            return true
        end
        -- Children already saw the raw hold; embedded Menus' FocusManager:onHold would
        -- re-send it to their focused row, looping forever when the row ignores holds (TOC).
        if event.handler == "onHold" then return self:onHold(unpack(event.args, 1, event.args.n)) end
        return _orig_handleEvent(self, event)
    end

    local _orig_onClose = PageBrowserWidget.onClose
    PageBrowserWidget.onClose = function(self, ...)
        if not self._zen_closed and self.ui then
            local state = self._zen_controls_state and {}
            for key, value in pairs(self._zen_controls_state or {}) do
                -- Drop callbacks that retain the closed panel.
                if type(value) ~= "function" then state[key] = value end
            end
            self.ui._zen_page_browser_resume = {
                closed_at = os.time(), active_tab = self._zen_active_tab, controls_state = state,
            }
            local cfg = self._zen_plugin and self._zen_plugin.config.page_browser
            if cfg and cfg.last_tab ~= self._zen_active_tab then
                cfg.last_tab = self._zen_active_tab
                self._zen_plugin:saveConfig()
            end
        end
        self._zen_closed = true
        local search = self.ui and self.ui.search
        if search and search._zen_page_browser == self then search._zen_page_browser = nil end
        if self._zen_annotations then self._zen_annotations:close(); self._zen_annotations = nil end
        set_settings_preview(self.ui and self.ui.thumbnail, nil)
        if self._zen_status_clock_bound then
            require("common/clock_timer").unbind(self)
            self._zen_status_clock_bound = nil
        end
        if self._zen_full_page_preview then self._zen_full_page_preview:free() end
        for _i, ref in ipairs(self._zen_row_panel and self._zen_row_panel._zen_panel_refs
                and self._zen_row_panel._zen_panel_refs.sliders or {}) do
            ref.cancel()
        end
        for _i, name in ipairs({ "_zen_deferred_update", "_zen_scrub_dirty_func", "_zen_post_scrub_clear" }) do
            if self[name] then UIManager:unschedule(self[name]) end
        end
        return _orig_onClose(self, ...)
    end

    local _orig_onKeyPress = PageBrowserWidget.onKeyPress
    PageBrowserWidget.onKeyPress = function(self, key)
        if handle_focus_key(self, key, true) then return true end
        return _orig_onKeyPress and _orig_onKeyPress(self, key)
    end

    local _orig_onKeyRepeat = PageBrowserWidget.onKeyRepeat
    PageBrowserWidget.onKeyRepeat = function(self, key)
        if handle_focus_key(self, key, false) then return true end
        if self._zen_ignore_opening_menu_key and key_matches_menu(key) then return true end
        return _orig_onKeyRepeat and _orig_onKeyRepeat(self, key)
    end

    local _orig_onKeyRelease = PageBrowserWidget.onKeyRelease
    PageBrowserWidget.onKeyRelease = function(self, key)
        if self._zen_ignore_opening_menu_key and key_matches_menu(key) then
            self._zen_ignore_opening_menu_key = nil
            return true
        end
        return _orig_onKeyRelease and _orig_onKeyRelease(self, key)
    end
end
