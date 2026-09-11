-- zen_ui: page_browser patch
-- Opens KOReader's native PageBrowserWidget from the bottom swipe zone
-- or a physical Menu-key hold.

local function apply_page_browser()

    -- -----------------------------------------------------------------------
    -- Dependencies
    -- -----------------------------------------------------------------------
    local UIManager    = require("ui/uimanager")
    local Event        = require("ui/event")
    local Device       = require("device")
    local ZenTocWidget = require("modules/reader/zen_toc_widget")
    local PresetStore   = require("config/preset_store")
    local utils        = require("common/utils")
    local WidgetResources = require("common/widget_resources")
    local lfs          = require("libs/libkoreader-lfs")
    local _stock_icons_dir = lfs.currentdir() .. "/resources/icons/mdlight/"

    -- Boox Android aborts forked thumbnail workers inside ART; render in-process.
    if Device.isAndroid and Device:isAndroid() then
        local ReaderThumbnail = require("apps/reader/modules/readerthumbnail")
        local RenderImage = require("ui/renderimage")
        local TileCacheItem = require("document/tilecacheitem")
        local logger = require("logger")

        if not ReaderThumbnail._zen_android_sync_thumbnail_patch then
            ReaderThumbnail._zen_android_sync_thumbnail_patch = true
            local orig_check_tile_generation = ReaderThumbnail.checkTileGeneration

            ReaderThumbnail.startTileGeneration = function(self, request)
                local ui = self.ui
                local view = ui and ui.view
                local state = view and view.state
                local saved_save_settings = ui and rawget(ui, "saveSettings")
                local saved_statistics = ui and rawget(ui, "statistics")
                local saved_footer = view and view.footer_visible
                local saved_page = state and state.page
                local saved_zoom = state and state.zoom
                local saved_rotation = state and state.rotation

                local ok, err = pcall(function()
                    local bb = self:_getPageImage(request.page)
                    local scale = math.min(request.width / bb:getWidth(), request.height / bb:getHeight())
                    local tile = TileCacheItem:new{
                        bb = RenderImage:scaleBlitBuffer(bb,
                            math.floor(bb:getWidth() * scale),
                            math.floor(bb:getHeight() * scale), true),
                        pageno = request.page,
                    }
                    tile.size = tonumber(tile.bb.stride) * tile.bb.h
                    request._zen_sync_tile = tile
                end)

                if ui then
                    rawset(ui, "saveSettings", saved_save_settings)
                    rawset(ui, "statistics", saved_statistics)
                end
                if view then
                    view.footer_visible = saved_footer
                    if state then
                        state.page = saved_page
                        state.zoom = saved_zoom
                        state.rotation = saved_rotation
                    end
                end
                if not ok then
                    logger.warn("ZenOS Android synchronous thumbnail generation failed:", err)
                    return false
                end
                return true
            end

            ReaderThumbnail.checkTileGeneration = function(self, request)
                local tile = request._zen_sync_tile
                if not tile then
                    return orig_check_tile_generation(self, request)
                end
                request._zen_sync_tile = nil
                if self.tile_cache then
                    self.tile_cache:insert(request.hash, tile)
                end
                if request.when_generated_callback then
                    request.when_generated_callback(tile, request.batch_id, true)
                end
                return false
            end
        end
    end

    local function key_matches_menu(key)
        if not key then return false end
        if type(key.match) ~= "function" then return key == "Menu" end
        local has_few_keys = type(Device.hasFewKeys) == "function" and Device:hasFewKeys()
        return key:match(has_few_keys and { { "Menu", "Right" } } or { "Menu" })
    end

    local function is_non_touch_device()
        return type(Device.isTouchDevice) == "function" and not Device:isTouchDevice()
    end

    local function supports_page_browser_focus()
        local has_dpad = type(Device.hasDPad) == "function" and Device:hasDPad()
        local has_keyboard = type(Device.hasKeyboard) == "function" and Device:hasKeyboard()
        return has_dpad or has_keyboard
    end

    -- -----------------------------------------------------------------------
    -- Resolve plugin icons/ dir from this file's path at apply-time
    -- -----------------------------------------------------------------------
    local _icons_dir
    do
        local root = require("common/plugin_root")
        if root then _icons_dir = root .. "/icons/" end
    end

    -- -----------------------------------------------------------------------
    -- Feature guard
    -- -----------------------------------------------------------------------
    -- Capture the plugin reference NOW (while __ZEN_UI_PLUGIN is set by
    -- run_patch). After apply_page_browser() returns the global is cleared,
    -- so reading it inside gesture handlers would always return nil.
    local _plugin_ref = rawget(_G, "__ZEN_UI_PLUGIN")
    ZenTocWidget.set_plugin(_plugin_ref)

    local function is_page_browser_layout(layout)
        return layout == "single" or layout == "carousel" or layout == "grid"
    end

    local function get_page_browser_layout()
        local settings = PresetStore.getSettings("reader")
        local layout = type(settings) == "table" and settings.page_browser_layout
        if is_page_browser_layout(layout) then return layout end
        return "carousel"
    end

    local function set_page_browser_layout(layout)
        if not is_page_browser_layout(layout) then return end
        local store = PresetStore.loadStore("reader")
        if type(store) ~= "table" then return end
        if type(store.settings) ~= "table" then store.settings = {} end
        if store.settings.page_browser_layout == layout then return end
        store.settings.page_browser_layout = layout
        PresetStore.saveStore("reader", store)
    end

    local function get_page_browser_font_size(key)
        local config = _plugin_ref and _plugin_ref.config
        local page_browser = type(config) == "table" and config.page_browser
        local size = type(page_browser) == "table" and tonumber(page_browser[key])
        if size and size >= 10 and size <= 40 then return size end
    end

    local function is_enabled()
        local features = _plugin_ref
            and _plugin_ref.config
            and _plugin_ref.config.features
        if type(features) ~= "table" or features.page_browser ~= true then return false end
        if features.lockdown_mode == true then
            local lc = _plugin_ref.config.lockdown
            if type(lc) == "table" and lc.disable_bottom_menu_swipe then return false end
        end
        return true
    end

    local function is_substring_enabled()
        local cfg = _plugin_ref and _plugin_ref.config
        local search = type(cfg) == "table" and cfg.search
        return type(search) ~= "table" or search.substring ~= false
    end

    rawset(_G, "__ZEN_UI_BUILD_PAGE_BROWSER_PREVIEW", function(slot_w, slot_h)
        local Blitbuffer      = require("ffi/blitbuffer")
        local Font            = require("ui/font")
        local Geom            = require("ui/geometry")
        local IconWidget      = require("ui/widget/iconwidget")
        local TextWidget      = require("ui/widget/textwidget")
        local FrameContainer  = require("ui/widget/container/framecontainer")
        local CenterContainer = require("ui/widget/container/centercontainer")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local VerticalGroup   = require("ui/widget/verticalgroup")
        local VerticalSpan    = require("ui/widget/verticalspan")
        local OverlapGroup    = require("ui/widget/overlapgroup")
        local LineWidget      = require("ui/widget/linewidget")
        local ZenSlider       = require("common/ui/zen_slider")
        local Screen          = Device.screen

        local canvas = Blitbuffer.new(slot_w, slot_h, Blitbuffer.TYPE_BB8)
        canvas:fill(Blitbuffer.COLOR_WHITE)

        local function paint_icon(icon_name, file_path, x, y, size)
            local icon = IconWidget:new{
                file   = file_path,
                icon   = file_path and nil or icon_name,
                width  = size,
                height = size,
            }
            icon:paintTo(canvas, x, y)
            icon:free()
        end

        local title_h = Screen:scaleBySize(54)
        local btn_sz  = Screen:scaleBySize(32)
        local btn_pad = Screen:scaleBySize(11)
        local slot_btn_w = btn_sz + btn_pad * 2
        local header_gap = Screen:scaleBySize(4)
        local title_y = math.floor((title_h - btn_sz) / 2)
        canvas:paintRect(0, title_h - 1, slot_w, 1, Blitbuffer.COLOR_LIGHT_GRAY)
        local stock_icons_dir = _stock_icons_dir
        local left_icons = {
            { "appbar.search", stock_icons_dir },
            { "info", _icons_dir },
        }
        for i, icon in ipairs(left_icons) do
            local icon_path = icon[3]
                or (icon[2] and utils.resolveIcon(icon[2], icon[1]))
            paint_icon(nil, icon_path, (slot_btn_w + header_gap) * (i - 1) + btn_pad, title_y, btn_sz)
        end
        local center_icons = {
            { "appbar.textsize", stock_icons_dir },
            { "bookmark", stock_icons_dir },
            { "toc", _icons_dir },
        }
        local center_group_w = slot_btn_w * #center_icons + header_gap * (#center_icons - 1)
        local header_center_x = math.floor((slot_w - center_group_w) / 2)
        for i, icon in ipairs(center_icons) do
            local icon_path = utils.resolveIcon(icon[2], icon[1])
            paint_icon(nil, icon_path,
                header_center_x + (slot_btn_w + header_gap) * (i - 1) + btn_pad, title_y, btn_sz)
        end
        if package.loaded["db"] then
            local more_path = _icons_dir and utils.resolveIcon(_icons_dir, "more_vertical")
            paint_icon(nil, more_path, slot_w - 2 * slot_btn_w + btn_pad, title_y, btn_sz)
        end
        local close_icon_path = _icons_dir and utils.resolveIcon(_icons_dir, "close_light")
        paint_icon(nil, close_icon_path, slot_w - slot_btn_w + btn_pad, title_y, btn_sz)

        local icon_size            = Screen:scaleBySize(24)
        local skip_icon_size       = Screen:scaleBySize(36)
        local icon_pad_h           = Screen:scaleBySize(20)
        local icon_pad_v           = Screen:scaleBySize(10)
        local panel_pad_v          = Screen:scaleBySize(6)
        local panel_pad_btn        = Screen:scaleBySize(12)
        local panel_pad_top        = Screen:scaleBySize(6)
        local panel_pad_bottom     = Screen:scaleBySize(12)
        local knob_r               = Screen:scaleBySize(16.5)
        local slider_h             = knob_r * 2 + Screen:scaleBySize(6)
        local label_face           = Font:getFace("cfont", 18)
        local measure_label        = TextWidget:new{ text = "Chapter 1", face = label_face, padding = 0 }
        local label_h              = measure_label:getSize().h
        measure_label:free()
        local btn_toggle_h         = icon_size + icon_pad_v * 2 + Screen:scaleBySize(2) * 2
        local btn_skip_h           = skip_icon_size + icon_pad_v * 2
        local btn_h                = math.max(btn_toggle_h, btn_skip_h)
        local panel_h              = panel_pad_top + panel_pad_v + panel_pad_btn
            + label_h + slider_h + btn_h + panel_pad_bottom

        local top_pad = Screen:scaleBySize(6)
        local grid_top = title_h + top_pad
        local panel_top = math.max(grid_top, slot_h - panel_h)
        local grid_h = math.max(Screen:scaleBySize(80), panel_top - grid_top)
        local layout = get_page_browser_layout()

        local badge_face = Font:getFace("cfont", 13)
        local function paint_pill(bx, by, bw, bh, color)
            local r = bh / 2
            for row = 0, bh - 1 do
                local dy = math.abs(row + 0.5 - r)
                local dx = math.sqrt(math.max(0, r * r - dy * dy))
                local x0 = math.ceil(bx + r - dx)
                local x1 = math.floor(bx + bw - r + dx)
                local w  = x1 - x0
                if w > 0 then canvas:paintRect(x0, by + row, w, 1, color) end
            end
        end
        local function paint_badge(page_num, bx, by, bw, bh)
            local label = TextWidget:new{
                text    = tostring(page_num),
                face    = badge_face,
                fgcolor = Blitbuffer.COLOR_WHITE,
                padding = 0,
            }
            local sz = label:getSize()
            local pv = Screen:scaleBySize(2)
            local ph = Screen:scaleBySize(4)
            local h = sz.h + 2 * pv
            local w = math.max(sz.w + 2 * ph, h)
            local x = bx + math.floor((bw - w) / 2)
            local y = by + bh - h - Screen:scaleBySize(3)
            paint_pill(x, y, w, h, Blitbuffer.gray(0x33))
            label:paintTo(canvas, x + math.floor((w - sz.w) / 2), y + math.floor((h - sz.h) / 2))
            label:free()
        end
        local function paint_page(page_num, cell_x, cell_y, cell_w, cell_h)
            local page_h = math.floor(cell_h * 0.92)
            local page_w = math.floor(page_h * 0.70)
            if page_w > cell_w * 0.86 then
                page_w = math.floor(cell_w * 0.86)
                page_h = math.floor(page_w / 0.70)
            end
            local x = cell_x + math.floor((cell_w - page_w) / 2)
            local y = cell_y + math.floor((cell_h - page_h) / 2)
            canvas:paintRect(x, y, page_w, page_h, Blitbuffer.COLOR_WHITE)
            canvas:paintBorder(x, y, page_w, page_h, Screen:scaleBySize(1), Blitbuffer.COLOR_DARK_GRAY, 0)
            local line_h = math.max(1, Screen:scaleBySize(2))
            local line_gap = Screen:scaleBySize(8)
            local text_w = math.floor(page_w * 0.62)
            local text_x = x + math.floor(page_w * 0.18)
            local text_y = y + math.floor(page_h * 0.18)
            for i = 0, 5 do
                local w = (i % 3 == 2) and math.floor(text_w * 0.72) or text_w
                canvas:paintRect(text_x, text_y + i * line_gap, w, line_h, Blitbuffer.COLOR_LIGHT_GRAY)
            end
            paint_badge(page_num, x, y, page_w, page_h)
        end

        if layout == "single" then
            paint_page(42, 0, grid_top, slot_w, grid_h)
        elseif layout == "carousel" then
            local gap = Screen:scaleBySize(8)
            local cell_w = math.floor(slot_w * 2 / 3)
            local center_x = math.floor((slot_w - cell_w) / 2)
            paint_page(41, center_x - cell_w - gap, grid_top, cell_w, grid_h)
            paint_page(42, center_x, grid_top, cell_w, grid_h)
            paint_page(43, center_x + cell_w + gap, grid_top, cell_w, grid_h)
        else
            local cols, rows = 3, 3
            local gap = Screen:scaleBySize(8)
            local margin_x = Screen:scaleBySize(14)
            local cell_w = math.floor((slot_w - 2 * margin_x - (cols - 1) * gap) / cols)
            local cell_h = math.floor((grid_h - (rows - 1) * gap) / rows)
            local first_page = 40
            for row = 0, rows - 1 do
                for col = 0, cols - 1 do
                    local idx = row * cols + col
                    paint_page(first_page + idx, margin_x + col * (cell_w + gap),
                        grid_top + row * (cell_h + gap), cell_w, cell_h)
                end
            end
        end

        local slider_w = math.floor(slot_w * 0.70)
        local chapter_label = TextWidget:new{
            text      = "Chapter 1",
            face      = label_face,
            max_width = slider_w,
            padding   = 0,
        }
        local slider = ZenSlider:new{
            width     = slider_w,
            value     = 42,
            value_min = 1,
            value_max = 240,
        }

        local grid_slide_path = _icons_dir and utils.resolveIcon(_icons_dir, "grid_slide")
        local carousel_path   = utils.resolveIcon(_icons_dir, "coverflow")
        local grid_path       = _icons_dir and utils.resolveIcon(_icons_dir, "grid")
        local chevron_left_path  = utils.resolveIcon(stock_icons_dir, "chevron.left")
        local chevron_right_path = utils.resolveIcon(stock_icons_dir, "chevron.right")
        local is_single_page = layout == "single"
        local is_carousel = layout == "carousel"

        local function make_toggle_icon(file_path, active)
            local icon = IconWidget:new{
                file   = file_path,
                width  = icon_size,
                height = icon_size,
                alpha  = not active,
            }
            if active then
                icon:_render()
                if icon._bb then
                    local bb_copy = icon._bb:copy()
                    bb_copy:invertRect(0, 0, bb_copy:getWidth(), bb_copy:getHeight())
                    icon._bb = bb_copy
                end
            end
            return CenterContainer:new{ dimen = Geom:new{ w = icon_size, h = icon_size }, icon }
        end
        local btn_view_frame = FrameContainer:new{
            padding_top = icon_pad_v, padding_bottom = icon_pad_v,
            padding_left = icon_pad_h, padding_right = icon_pad_h,
            bordersize = 0,
            background = is_single_page and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
            make_toggle_icon(grid_slide_path, is_single_page),
        }
        local btn_carousel_frame = FrameContainer:new{
            padding_top = icon_pad_v, padding_bottom = icon_pad_v,
            padding_left = icon_pad_h, padding_right = icon_pad_h,
            bordersize = 0,
            background = is_carousel and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
            make_toggle_icon(carousel_path, is_carousel),
        }
        local btn_grid_frame = FrameContainer:new{
            padding_top = icon_pad_v, padding_bottom = icon_pad_v,
            padding_left = icon_pad_h, padding_right = icon_pad_h,
            bordersize = 0,
            background = layout == "grid" and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
            make_toggle_icon(grid_path, layout == "grid"),
        }
        local divider = LineWidget:new{
            dimen = Geom:new{ w = Screen:scaleBySize(1), h = icon_size + icon_pad_v * 2 },
            background = Blitbuffer.COLOR_DARK_GRAY,
            direction = "vert",
        }
        local btn_row = FrameContainer:new{
            padding = 0, margin = 0, bordersize = Screen:scaleBySize(2),
            background = Blitbuffer.COLOR_WHITE,
            radius = Screen:scaleBySize(4),
            HorizontalGroup:new{
                align = "center",
                btn_view_frame,
                divider,
                btn_carousel_frame,
                LineWidget:new{
                    dimen = Geom:new{ w = Screen:scaleBySize(1), h = icon_size + icon_pad_v * 2 },
                    background = Blitbuffer.COLOR_DARK_GRAY,
                    direction = "vert",
                },
                btn_grid_frame,
            },
        }
        WidgetResources.paintFrameBorderOnTop(btn_row)
        local function make_skip_btn(file_path)
            return FrameContainer:new{
                padding_top = icon_pad_v, padding_bottom = icon_pad_v,
                padding_left = icon_pad_h, padding_right = icon_pad_h,
                bordersize = 0,
                background = Blitbuffer.COLOR_WHITE,
                IconWidget:new{
                    file = file_path,
                    width = skip_icon_size,
                    height = skip_icon_size,
                },
            }
        end
        local skip_left_btn = make_skip_btn(chevron_left_path)
        local skip_right_btn = make_skip_btn(chevron_right_path)
        local btn_row_sz = btn_row:getSize()
        local skip_sz = skip_left_btn:getSize()
        local row_h = math.max(btn_row_sz.h, skip_sz.h)
        local skip_side_gap = Screen:scaleBySize(40)
        skip_left_btn.overlap_offset = { skip_side_gap, math.floor((row_h - skip_sz.h) / 2) }
        skip_right_btn.overlap_offset = {
            slot_w - skip_side_gap - skip_sz.w,
            math.floor((row_h - skip_sz.h) / 2),
        }
        local btn_and_skip = OverlapGroup:new{
            dimen = Geom:new{ w = slot_w, h = row_h },
            allow_mirroring = false,
            CenterContainer:new{ dimen = Geom:new{ w = slot_w, h = row_h }, btn_row },
            skip_left_btn,
            skip_right_btn,
        }

        local panel = FrameContainer:new{
            width = slot_w,
            height = panel_h,
            padding = 0,
            margin = 0,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            VerticalGroup:new{
                align = "center",
                VerticalSpan:new{ width = panel_pad_top },
                btn_and_skip,
                VerticalSpan:new{ width = panel_pad_btn },
                CenterContainer:new{ dimen = Geom:new{ w = slot_w, h = slider:getSize().h }, slider },
                VerticalSpan:new{ width = panel_pad_v },
                CenterContainer:new{ dimen = Geom:new{ w = slot_w, h = chapter_label:getSize().h }, chapter_label },
                VerticalSpan:new{ width = panel_pad_bottom },
            },
        }
        panel:paintTo(canvas, 0, panel_top)
        if panel.free then panel:free() end
        return canvas
    end)

    -- -----------------------------------------------------------------------
    -- ZenOS customisations applied once to PageBrowserWidget
    -- -----------------------------------------------------------------------
    local _zen_pbw_patched = false

    local function zen_patch_page_browser_widget()
        if _zen_pbw_patched then return end
        _zen_pbw_patched = true

        local PageBrowserWidget = require("ui/widget/pagebrowserwidget")
        local BD         = require("ui/bidi")
        local Font       = require("ui/font")
        local Geom       = require("ui/geometry")
        local IconWidget = require("ui/widget/iconwidget")
        local HorizontalGroup = require("ui/widget/horizontalgroup")
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
        local ZenSlider       = require("common/ui/zen_slider")
        local ZenIconButton   = require("common/ui/zen_icon_button")
        local inline_icons    = require("common/inline_icon_map")
        local logger          = require("common/zen_logger").new("page_browser")
        local _               = require("gettext")

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

            local page_rows = {}
            local nb_cols = pbw.nb_cols or 1
            for idx = 1, (pbw.nb_grid_items or 0) do
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

            local footer_row = {}
            local footer = {
                { pbw._zen_btn_skip_left, "footer:previous" },
                { pbw._zen_btn_view_frame, "footer:single" },
                { pbw._zen_btn_carousel_frame, "footer:carousel" },
                { pbw._zen_btn_grid_frame, "footer:grid" },
                { pbw._zen_btn_skip_right, "footer:next" },
            }
            for _i, item in ipairs(footer) do
                if item[1] then
                    tag_focus_widget(item[1], item[2])
                    table.insert(footer_row, item[1])
                end
            end
            if #footer_row > 0 then table.insert(layout, footer_row) end
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
            local item_h = math.max(1, grid_h - Screen:scaleBySize(10))
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
        local _orig_init = PageBrowserWidget.init
        PageBrowserWidget.init = function(self)
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

            local function make_header_btn(file_path, x_pos, cb, hold_cb, align, allow_flash)
                local button = {
                    file           = file_path,
                    width          = btn_sz,
                    height         = btn_sz,
                    padding        = btn_pad,
                    padding_bottom = btn_sz,
                    overlap_align  = align or "left",
                    allow_flash    = allow_flash ~= false,
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

            local slot_w = btn_sz + btn_pad * 2
            local header_gap = Screen:scaleBySize(4)

            local old_right_button = self.title_bar.right_button
            local header_buttons = {}
            if old_right_button then
                for i = #self.title_bar, 1, -1 do
                    if self.title_bar[i] == old_right_button then
                        table.remove(self.title_bar, i)
                        break
                    end
                end
                self.title_bar.right_button = make_header_btn(
                    utils.resolveIcon(_icons_dir, "close_light"), nil,
                    old_right_button.callback, old_right_button.hold_callback,
                    "right", old_right_button.allow_flash)
                table.insert(self.title_bar, self.title_bar.right_button)
            end

            local pbw_ref = self
            local function open_toc()
                -- Keep this widget open beneath the full-screen TOC. Closing the
                -- TOC then naturally returns to the page browser.
                UIManager:show(ZenTocWidget:new{
                    ui         = pbw_ref.ui,
                    focus_page = visible_page_raw(pbw_ref, pbw_ref.focus_page or pbw_ref.cur_page or 1),
                    font_size  = get_page_browser_font_size("toc_font_size"),
                    on_goto    = function(page)
                        if pbw_ref.ui.link then
                            pbw_ref.ui.link:addCurrentLocationToStack()
                        end
                        pbw_ref:onClose()
                        pbw_ref.ui:handleEvent(Event:new("GotoPage", page))
                    end,
                    close_all_callback = function() pbw_ref:onClose() end,
                })
            end

            local function open_book_info()
                require("modules/reader/book_details").show(pbw_ref.ui, {
                    config = _plugin_ref and _plugin_ref.config,
                    plugin = _plugin_ref,
                    close_all_callback = function() pbw_ref:onClose() end,
                })
            end

            local function open_search()
                pbw_ref:onClose()
                pbw_ref.ui:handleEvent(Event:new("ShowFulltextSearchInput"))
            end
            local function open_bookmarks()
                -- Keep the page browser underneath so closing bookmarks returns here.
                if pbw_ref.ui.bookmark then
                    local bookmark = pbw_ref.ui.bookmark
                    bookmark:onShowBookmark()
                    local bm_menu = bookmark.bookmark_menu and bookmark.bookmark_menu[1]
                    if bm_menu then bm_menu._zen_page_browser_parent = pbw_ref end
                end
            end

            local function open_vocab()
                pbw_ref:onClose()
                pbw_ref.ui:handleEvent(Event:new("ShowVocabBuilder"))
            end

            local function open_reader_menu()
                local ui_ref = pbw_ref.ui
                if not (ui_ref and ui_ref.config) then
                    logger.warn("open_reader_menu: ui.config missing")
                    pbw_ref:onClose()
                    return
                end
                local cfg = ui_ref.config
                pbw_ref:onClose()
                UIManager:nextTick(function()
                    if cfg.config_dialog then return end
                    local ok, err = pcall(function()
                        local ConfigDialog = require("ui/widget/configdialog")
                        local dialog
                        dialog = ConfigDialog:new{
                            document        = cfg.document,
                            ui              = cfg.ui,
                            configurable    = cfg.configurable,
                            config_options  = cfg.options,
                            is_always_active = true,
                            covers_footer   = true,
                            close_callback  = function()
                                cfg.last_panel_index = dialog.panel_index or cfg.last_panel_index
                                cfg.config_dialog = nil
                                ui_ref:handleEvent(Event:new("RestoreHinting"))
                            end,
                        }
                        cfg.config_dialog = dialog
                        if ui_ref.keyselection and type(ui_ref.keyselection.onStopHighlightIndicator) == "function" then
                            ui_ref.keyselection:onStopHighlightIndicator(true)
                        elseif ui_ref.highlight and type(ui_ref.highlight.onStopHighlightIndicator) == "function" then
                            ui_ref.highlight:onStopHighlightIndicator(true)
                        end
                        ui_ref:handleEvent(Event:new("DisableHinting"))
                        dialog:onShowConfigPanel(cfg.last_panel_index)
                        UIManager:show(dialog)
                    end)
                    if not ok then
                        logger.err("open_reader_menu: failed to open config dialog:", err)
                        cfg.config_dialog = nil
                    end
                end)
            end

            local function add_header_action(action, x_pos)
                local icon_path = action[4] or (action[3] and resolve_stock_icon(action[1]))
                    or (_icons_dir and utils.resolveIcon(_icons_dir, action[1]))
                local button = make_header_btn(icon_path, x_pos, action[2])
                table.insert(self.title_bar, button)
                table.insert(header_buttons, button)
                return button
            end

            local left_actions = {
                { "appbar.search", open_search, true },
                { "info", open_book_info },
            }
            for i, action in ipairs(left_actions) do
                add_header_action(action, (slot_w + header_gap) * (i - 1))
            end

            local center_actions = {
                { "appbar.textsize", open_reader_menu, true },
                { "bookmark", open_bookmarks, true },
                { "toc", open_toc },
            }
            local title_w = self.title_bar.width or Screen:getWidth()
            local center_group_w = slot_w * #center_actions + header_gap * (#center_actions - 1)
            local center_x = math.floor((title_w - center_group_w) / 2)
            self._zen_reader_tour_targets = {}
            for i, action in ipairs(center_actions) do
                self._zen_reader_tour_targets[i] = add_header_action(
                    action, center_x + (slot_w + header_gap) * (i - 1))
            end

            local vocab_icon_path = package.loaded["db"]
                and _icons_dir and utils.resolveIcon(_icons_dir, "tab_vocab")
            if vocab_icon_path then
                local overflow_button
                local function show_overflow_menu()
                    local ButtonDialog = require("ui/widget/buttondialog")
                    local dialog
                    dialog = ButtonDialog:new{
                        buttons = {
                            {{
                                text = inline_icons.vocabulary .. "  " .. _("Vocabulary builder"),
                                align = "left",
                                avoid_text_truncation = false,
                                callback = function()
                                    UIManager:close(dialog)
                                    open_vocab()
                                end,
                            }},
                        },
                        shrink_unneeded_width = true,
                        anchor = function()
                            local button_dimen = overflow_button.image and overflow_button.image.dimen
                            local dialog_dimen = dialog.movable and dialog.movable.dimen
                            if not (button_dimen and dialog_dimen) then return button_dimen end
                            local inset = Screen:scaleBySize(10)
                            return {
                                x = BD.mirroredUILayout()
                                    and inset + dialog_dimen.w
                                    or Screen:getWidth() - dialog_dimen.w - inset,
                                y = button_dimen.y,
                                h = button_dimen.h,
                            }
                        end,
                    }
                    UIManager:show(dialog)
                end
                overflow_button = add_header_action(
                    { "more_vertical", show_overflow_menu }, title_w - 2 * slot_w)
            end
            if self.title_bar.right_button then
                table.insert(header_buttons, self.title_bar.right_button)
            end
            self._zen_header_buttons = header_buttons

            -- Rebuild only the panel: the initial layout already used the
            -- selected fixed grid dimensions.
            self._zen_panel_only_rebuild = not self._zen_focus_enabled or stock_focus_layout
            self:updateLayout()
            self._zen_panel_only_rebuild = nil
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
        local zen_icon_size      = Screen:scaleBySize(24)  -- view-toggle (grid/single) icons
        local zen_skip_icon_size = Screen:scaleBySize(36)  -- skip-chapter chevron icons
        local zen_icon_pad_h = Screen:scaleBySize(20)  -- horizontal padding (wider buttons)
        local zen_icon_pad_v = Screen:scaleBySize(10)  -- vertical padding (taller buttons)
        local zen_panel_pad_v = Screen:scaleBySize(6)  -- panel vertical padding (between elements)
        local zen_panel_pad_btn = Screen:scaleBySize(12) -- gap above button group
        local zen_panel_pad_top = Screen:scaleBySize(6)   -- top padding (label to grid)
        local zen_panel_pad_bottom = Screen:scaleBySize(12)  -- extra bottom padding

        local function zen_measure_panel_h(nb_pages)
            local knob_r   = Screen:scaleBySize(16.5)  -- matches ZenSlider default
            local slider_h = knob_r * 2 + Screen:scaleBySize(6)
            -- Measure label height from a live TextWidget
            local tw = TextWidget:new{ text = "Wg",
                                       face = Font:getFace("cfont", 14),
                                       padding = 0 }
            local lh = tw:getSize().h
            tw:free()
            -- Button group height: max of view-toggle (with border) and skip buttons (borderless)
            local btn_toggle_h = zen_icon_size      + zen_icon_pad_v * 2 + Screen:scaleBySize(2) * 2
            local btn_skip_h   = zen_skip_icon_size + zen_icon_pad_v * 2
            local btn_h = math.max(btn_toggle_h, btn_skip_h)
            -- top_pad + icon row + (optional slider) + chapter label + bottom_pad
            -- Only include slider height and spacing if there's more than 1 page
            if nb_pages and nb_pages > 1 then
                return zen_panel_pad_top + zen_panel_pad_v + zen_panel_pad_btn + lh + slider_h + btn_h + zen_panel_pad_bottom
            else
                return zen_panel_pad_top + zen_panel_pad_btn + lh + btn_h + zen_panel_pad_bottom
            end
        end

        PageBrowserWidget.updateLayout = function(self)
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
            local zen_panel_h = zen_measure_panel_h(self.nb_pages or 1)

            -- When _zen_panel_only_rebuild is set (second call during init, no
            -- layout change needed), skip _orig_updateLayout entirely so the
            -- async tile rendering queue started by the first call is not
            -- cancelled and restarted, which caused ~11s delays on slow devices.
            local top_pad = Screen:scaleBySize(6)  -- grid-to-title gap; used below
            if self._zen_panel_only_rebuild then
                logger.dbg("panel-only rebuild, skipping _orig_updateLayout")
                self._zen_tile_size = nil
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
                logger.dbg("forcing cols="..nc.." rows="..nr)
                if ds then
                    _saved_ds_cols = ds:readSetting("page_browser_nb_cols")
                    _saved_ds_rows = ds:readSetting("page_browser_nb_rows")
                    logger.dbg("saved ds cols="..tostring(_saved_ds_cols).." rows="..tostring(_saved_ds_rows))
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

            logger.dbg("after orig nb_cols="..tostring(self.nb_cols).." nb_rows="..tostring(self.nb_rows).." nb_grid_items="..tostring(self.nb_grid_items))

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
                logger.dbg("restored ds cols="..tostring(_saved_ds_cols).." rows="..tostring(_saved_ds_rows))
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
            local slider_w   = math.floor(thumb_span * 0.95)

            local function chapter_title(pg)
                if not self.ui or not self.ui.toc then return "" end
                return self.ui.toc:getTocTitleByPage(pg) or ""
            end

            local label_face = Font:getFace("cfont", 18)
            local pad_v      = zen_panel_pad_v

            -- Use focus_page consistently so slider position doesn't jump when switching views
            local cp = self.focus_page or cur_page
            local chap_label = TextWidget:new{
                text      = chapter_title(visible_page_raw(self, cp)),
                face      = label_face,
                max_width = slider_w,
                padding   = 0,
            }

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
            local function directPaintSlider(sl, label, label_text)
                if not sl or not sl.dimen or not sl.dimen.x then return end
                sl:paintTo(Screen.bb, sl.dimen.x, sl.dimen.y)
                if label and label_text then
                    -- TextWidget doesn't set self.dimen in paintTo, so we
                    -- compute label position from the slider (which does).
                    -- Layout order: icon row → slider → pad_v → chapter label.
                    local lh = label:getSize().h
                    local label_y = sl.dimen.y + sl:getSize().h + pad_v
                    -- Erase the full slider_w row, then paint centred text.
                    Screen.bb:paintRect(sl.dimen.x, label_y, slider_w, lh,
                                        Blitbuffer.COLOR_WHITE)
                    label:setText(label_text)
                    local new_w = label:getSize().w
                    local label_x = sl.dimen.x + math.floor((slider_w - new_w) / 2)
                    label:paintTo(Screen.bb, label_x, label_y)
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
                local title_h = (pbw.title_bar and pbw.title_bar:getSize().h) or 0
                local gx = pbw.dimen.x or 0
                local gy = (pbw.dimen.y or 0) + title_h + Screen:scaleBySize(6)

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
                directPaintSlider(sl, clbl, chap_text)

                -- Single A2 refresh covering grid + label + slider
                -- (buttons are excluded via the tightened scrub_dimen).
                -- One call avoids the double-flash that two separate A2
                -- regions produce on e-ink, especially in single-page mode.
                UIManager:setDirty(nil, "fast", pbw._zen_scrub_dimen or pbw.dimen)
            end

            -- Deferred scrub dirty: fires the throttled setDirty at the end
            -- of the throttle window so the most recent state is displayed.
            self._zen_scrub_dirty_func = function()
                if not self._zen_scrubbing then return end
                self._zen_last_scrub_dirty = os.clock()
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
                                -- Paint grid placeholders + slider + label
                                -- directly to Screen.bb and push one A2 refresh.
                                directPaintScrub(v, chapter_title(visible_page_raw(self, v)))
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

            -- View-mode toggle buttons: single page / carousel / grid.
            -- Create a unified button group with divider and active state styling.
            local pbw = self

            local layout_mode = self._zen_layout_mode or "grid"

            local grid_slide_path = _icons_dir and utils.resolveIcon(_icons_dir, "grid_slide")
            local carousel_path   = utils.resolveIcon(_icons_dir, "coverflow")
            local grid_path       = _icons_dir and utils.resolveIcon(_icons_dir, "grid")
            local chevron_left_path  = resolve_stock_icon("chevron.left")
            local chevron_right_path = resolve_stock_icon("chevron.right")

            -- Create icon widgets with active state styling
            local icon_size      = zen_icon_size
            local skip_icon_size = zen_skip_icon_size
            local icon_pad_h = zen_icon_pad_h
            local icon_pad_v = zen_icon_pad_v

            local function make_layout_button(file_path, active)
                local icon = IconWidget:new{
                    file   = file_path,
                    width  = icon_size,
                    height = icon_size,
                    alpha  = not active,
                }
                if active then
                    icon:_render()
                    if icon._bb then
                        local bb_copy = icon._bb:copy()
                        bb_copy:invertRect(0, 0, bb_copy:getWidth(), bb_copy:getHeight())
                        icon._bb = bb_copy
                    end
                end
                return FrameContainer:new{
                    padding_top    = icon_pad_v,
                    padding_bottom = icon_pad_v,
                    padding_left   = icon_pad_h,
                    padding_right  = icon_pad_h,
                    bordersize     = 0,
                    focusable      = self._zen_focus_enabled,
                    focus_inner_border = true,
                    focus_border_size = Screen:scaleBySize(3),
                    focus_border_color = active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
                    background     = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
                    CenterContainer:new{
                        dimen = Geom:new{ w = icon_size, h = icon_size },
                        icon,
                    },
                }
            end

            local btn_view_frame = make_layout_button(
                grid_slide_path, layout_mode == "single")
            local btn_carousel_frame = make_layout_button(
                carousel_path, layout_mode == "carousel")
            local btn_grid_frame = make_layout_button(
                grid_path, layout_mode == "grid")

            -- Vertical divider
            local LineWidget = require("ui/widget/linewidget")
            local divider = LineWidget:new{
                dimen          = Geom:new{
                    w = Screen:scaleBySize(1),
                    h = icon_size + icon_pad_v * 2,
                },
                background     = Blitbuffer.COLOR_DARK_GRAY,
                direction      = "vert",
            }

            -- Unified button group
            local btn_group = HorizontalGroup:new{
                align = "center",
                btn_view_frame,
                divider,
                btn_carousel_frame,
                LineWidget:new{
                    dimen = Geom:new{
                        w = Screen:scaleBySize(1),
                        h = icon_size + icon_pad_v * 2,
                    },
                    background = Blitbuffer.COLOR_DARK_GRAY,
                    direction = "vert",
                },
                btn_grid_frame,
            }

            -- Wrap in frame with border and rounded corners
            local btn_row = FrameContainer:new{
                padding        = 0,
                margin         = 0,
                bordersize     = Screen:scaleBySize(2),
                background     = Blitbuffer.COLOR_WHITE,
                radius         = Screen:scaleBySize(4),
                btn_group,
            }
            WidgetResources.paintFrameBorderOnTop(btn_row)

            -- Skip chapter buttons (larger icons, no border)
            local function make_skip_btn(file_path)
                return FrameContainer:new{
                    padding_top    = icon_pad_v,
                    padding_bottom = icon_pad_v,
                    padding_left   = icon_pad_h,
                    padding_right  = icon_pad_h,
                    bordersize     = 0,
                    focusable     = self._zen_focus_enabled,
                    focus_inner_border = true,
                    focus_border_size = Screen:scaleBySize(3),
                    background     = Blitbuffer.COLOR_WHITE,
                    IconWidget:new{
                        file   = file_path,
                        width  = skip_icon_size,
                        height = skip_icon_size,
                    },
                }
            end
            local skip_left_btn  = make_skip_btn(chevron_left_path)
            local skip_right_btn = make_skip_btn(chevron_right_path)

            -- Switch callbacks
            local _switch_single = function()
                pbw._zen_layout_mode = "single"
                pbw._zen_nb_cols_override = 1
                pbw._zen_nb_rows_override = 1
                set_page_browser_layout("single")
                logger.dbg("switch to single page")
                pbw:updateLayout()
                UIManager:setDirty(pbw, function() return "partial", pbw.dimen end)
            end
            local _switch_carousel = function()
                pbw._zen_layout_mode = "carousel"
                pbw._zen_nb_cols_override = 3
                pbw._zen_nb_rows_override = 1
                set_page_browser_layout("carousel")
                logger.dbg("switch to carousel")
                pbw:updateLayout()
                UIManager:setDirty(pbw, function() return "partial", pbw.dimen end)
            end
            local _switch_grid = function()
                pbw._zen_layout_mode = "grid"
                pbw._zen_nb_cols_override = 3
                pbw._zen_nb_rows_override = 3
                set_page_browser_layout("grid")
                logger.dbg("switch to grid")
                pbw:updateLayout()
                UIManager:setDirty(pbw, function() return "partial", pbw.dimen end)
            end
            self._zen_switch_single = _switch_single
            self._zen_switch_carousel = _switch_carousel
            self._zen_switch_grid   = _switch_grid

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

            -- Store button group reference for tap handling
            self._zen_btn_group = btn_row
            self._zen_btn_view_frame = btn_view_frame
            self._zen_btn_carousel_frame = btn_carousel_frame
            self._zen_btn_grid_frame = btn_grid_frame
            self._zen_btn_skip_left = skip_left_btn
            self._zen_btn_skip_right = skip_right_btn

            -- Compute hit zones analytically from known panel layout.
            -- The button group is a unified widget with one zone per layout.
            -- Panel top Y (screen-absolute):
            local panel_abs_y = (self.dimen.y or 0) + self.dimen.h - zen_panel_h
            -- The navigation controls are the first content row in the panel.
            local btn_zone_y = panel_abs_y + zen_panel_pad_top

            -- btn_row is CenterContainer'd horizontally in grid_w
            local btn_row_sz = btn_row:getSize()
            local btn_row_w = btn_row_sz.w
            local btn_row_h = btn_row_sz.h
            local btn_origin_x = (self.dimen.x or 0) + math.floor((grid_w - btn_row_w) / 2)

            -- Split the unified group into three equal layout hit zones.
            local third_w = math.floor(btn_row_w / 3)

            self._zen_btn_view_zone = Geom:new{
                x = btn_origin_x,
                y = btn_zone_y,
                w = third_w,
                h = btn_row_h,
            }
            self._zen_btn_carousel_zone = Geom:new{
                x = btn_origin_x + third_w,
                y = btn_zone_y,
                w = third_w,
                h = btn_row_h,
            }
            self._zen_btn_grid_zone = Geom:new{
                x = btn_origin_x + 2 * third_w,
                y = btn_zone_y,
                w = btn_row_w - 2 * third_w,
                h = btn_row_h,
            }
            logger.dbg("btn_view_zone x="..self._zen_btn_view_zone.x.." y="..self._zen_btn_view_zone.y.." w="..self._zen_btn_view_zone.w.." h="..self._zen_btn_view_zone.h)
            logger.dbg("btn_carousel_zone x="..self._zen_btn_carousel_zone.x.." y="..self._zen_btn_carousel_zone.y.." w="..self._zen_btn_carousel_zone.w.." h="..self._zen_btn_carousel_zone.h)
            logger.dbg("btn_grid_zone x="..self._zen_btn_grid_zone.x.." y="..self._zen_btn_grid_zone.y.." w="..self._zen_btn_grid_zone.w.." h="..self._zen_btn_grid_zone.h)

            -- Skip buttons flanking the view-toggle group
            local skip_side_gap = Screen:scaleBySize(40)
            local skip_btn_sz   = skip_left_btn:getSize()
            local skip_btn_w    = skip_btn_sz.w
            local skip_btn_h    = skip_btn_sz.h
            local row_h         = math.max(btn_row_h, skip_btn_h)
            local vert_off_skip = math.floor((row_h - skip_btn_h) / 2)

            skip_left_btn.overlap_offset  = { skip_side_gap, vert_off_skip }
            skip_right_btn.overlap_offset = { grid_w - skip_side_gap - skip_btn_w, vert_off_skip }

            local btn_and_skip = OverlapGroup:new{
                dimen           = Geom:new{ w = grid_w, h = row_h },
                allow_mirroring = false,
                CenterContainer:new{
                    dimen = Geom:new{ w = grid_w, h = row_h },
                    btn_row,
                },
                skip_left_btn,
                skip_right_btn,
            }

            self._zen_btn_skip_left_zone = Geom:new{
                x = (self.dimen.x or 0) + skip_side_gap,
                y = btn_zone_y + vert_off_skip,
                w = skip_btn_w,
                h = skip_btn_h,
            }
            self._zen_btn_skip_right_zone = Geom:new{
                x = (self.dimen.x or 0) + grid_w - skip_side_gap - skip_btn_w,
                y = btn_zone_y + vert_off_skip,
                w = skip_btn_w,
                h = skip_btn_h,
            }

            -- Store panel height for onHold suppression.
            self._zen_panel_h = zen_panel_h

            -- The controls now sit above the slider. Keep the entire panel in
            -- the scrub refresh so the slider and chapter label update together.

            -- Panel spans full grid width, pinned to the absolute bottom of
            -- the screen via OverlapGroup offset (set below).  Height is the
            -- measured content height, not the (larger) native row_height.

            -- Build panel content dynamically based on whether slider should be shown
            local panel_content = {
                align = "center",
                VerticalSpan:new{ width = zen_panel_pad_top },
                btn_and_skip,
            }

            table.insert(panel_content, VerticalSpan:new{ width = zen_panel_pad_btn })

            -- Only add slider and its spacing if there's more than 1 page.
            if zen_slider then
                table.insert(panel_content, CenterContainer:new{
                    dimen = Geom:new{ w = grid_w, h = zen_slider:getSize().h },
                    zen_slider,
                })
                table.insert(panel_content, VerticalSpan:new{ width = pad_v })
            end

            table.insert(panel_content, CenterContainer:new{
                dimen = Geom:new{ w = grid_w, h = chap_label:getSize().h },
                chap_label,
            })
            table.insert(panel_content, VerticalSpan:new{ width = zen_panel_pad_bottom })

            local panel = FrameContainer:new{
                width      = grid_w,
                height     = zen_panel_h,
                padding    = 0,
                margin     = 0,
                bordersize = 0,
                background = Blitbuffer.COLOR_WHITE,
                VerticalGroup:new(panel_content),
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
                        self.title_bar,
                        VerticalSpan:new{ width = top_pad },
                        self.grid,
                    },
                    panel,
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
            local desired_focus_id = current_focus_id(self)
            logger.dbg("focus_page="..tostring(self.focus_page)
                .." cur_page="..tostring(self.cur_page)
                .." scrubbing="..tostring(self._zen_scrubbing)
                .." post_scrub="..tostring(self._zen_post_scrub)
                .." nb_grid_items="..tostring(self.nb_grid_items)
                .." nb_pages="..tostring(self.nb_pages))
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
                logger.dbg("clamped focus_page to "..tostring(self.focus_page))
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
                logger.dbg("first tile bitmap seen, size "
                    ..self._zen_tile_size.w.."x"..self._zen_tile_size.h)
            end
            -- During scrubbing and for one full repaint cycle after scrubbing
            -- ends, suppress per-tile display refreshes.  Without this, each
            -- async tile that loads fires its own hardware update, producing
            -- the multi-flash artifact on the panel area.
            -- _zen_post_scrub is cleared by the next paintTo call.
            local suppressed = (self._zen_scrubbing or self._zen_post_scrub) and do_refresh
            logger.dbg("idx="..tostring(grid_idx)
                .." page="..tostring(page)
                .." has_bitmap="..tostring(has_bitmap)
                .." do_refresh="..tostring(do_refresh)
                .." suppressed="..tostring(suppressed ~= nil and suppressed ~= false)
                .." scrubbing="..tostring(self._zen_scrubbing)
                .." post_scrub="..tostring(self._zen_post_scrub))
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

            if not (self.grid and self.focus_page) then return end

            local fp    = self.focus_page
            local shift = self.focus_page_shift or 0
            local np    = self.nb_pages or 1

            -- Grid top-left in blitbuffer coordinate space.
            -- OverlapGroup child 1 = VerticalGroup: title_bar → span(top_pad) → grid.
            local title_h = (self.title_bar and self.title_bar:getSize().h) or 0
            local gx      = x
            local gy      = y + title_h + Screen:scaleBySize(6) -- top_pad

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
            logger.dbg("onTap at "..ges.pos.x..","..ges.pos.y)
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
            -- 3. View-toggle buttons: fallback for taps before the first paintTo,
            --    when btn.dimen.x/y are still 0 so the button's own ges_events
            --    won't match.  After first paint, the IconButton's onTapIconButton
            --    fires the callback directly (children-first propagation).
            --    Use zone:contains() — GestureRange also uses contains() for
            --    matching, so zero-area tap points on a border stay inclusive.
            if self._zen_btn_view_zone
               and self._zen_btn_view_zone:contains(ges.pos) then
                logger.dbg("onTap → btn_view (single)")
                if self._zen_switch_single then self._zen_switch_single() end
                return true
            end
            if self._zen_btn_carousel_zone
               and self._zen_btn_carousel_zone:contains(ges.pos) then
                logger.dbg("onTap → btn_carousel")
                if self._zen_switch_carousel then self._zen_switch_carousel() end
                return true
            end
            if self._zen_btn_grid_zone
               and self._zen_btn_grid_zone:contains(ges.pos) then
                logger.dbg("onTap → btn_grid")
                if self._zen_switch_grid then self._zen_switch_grid() end
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
            elseif direction == "south" and ges.pos.y < Device.screen:getHeight() * 0.14 then
                local ok_rui, RUI = pcall(require, "apps/reader/readerui")
                if ok_rui and RUI and RUI.instance then
                    local reader_menu = RUI.instance.menu
                    if reader_menu and reader_menu.activation_menu ~= "tap" then
                        reader_menu:onShowMenu(reader_menu:_getTabIndexFromLocation(ges))
                        return true
                    end
                end
            end
            return true  -- swallow remaining north/south and anything else
        end

        -- Holds on the navigation chevrons skip chapters. Other holds in the
        -- bottom panel stay suppressed to avoid the native book-map-row popup.
        local _orig_onHold = PageBrowserWidget.onHold
        PageBrowserWidget.onHold = function(self, arg, ges)
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
                pbw:onPress()
                return true
            end
            return false
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

    -- -----------------------------------------------------------------------
    -- Open KOReader's native PageBrowserWidget (with ZenOS tweaks)
    -- -----------------------------------------------------------------------
    local function open_page_browser(ui, from_menu_hold, layout)
        local PageBrowserWidget = require("ui/widget/pagebrowserwidget")
        local previous_layout = layout and get_page_browser_layout()
        if layout then set_page_browser_layout(layout) end
        zen_patch_page_browser_widget()
        local browser = PageBrowserWidget:new{ ui = ui }
        browser._zen_ignore_opening_menu_key = from_menu_hold or nil
        UIManager:show(browser)
        if layout then
            return browser, function()
                set_page_browser_layout(previous_layout)
                browser:onClose()
            end
        end
        return browser
    end

    local function start_reader_tour(ui)
        local ok, tour = pcall(require, "common/quickstart/reader_tour")
        if ok then
            tour.start(_plugin_ref, ui, function(layout)
                return open_page_browser(ui, nil, layout)
            end)
        end
    end

    -- Patch ReaderMenu.initGesListener to register the swipe-up zone
    -- -----------------------------------------------------------------------
    local ReaderMenu = require("apps/reader/modules/readermenu")
    local _orig_initGesListener = ReaderMenu.initGesListener

    ReaderMenu._zen_start_reader_tour = function(self_rm)
        if type(self_rm.onCloseReaderMenu) == "function" then
            self_rm:onCloseReaderMenu()
        end
        UIManager:scheduleIn(0, function() start_reader_tour(self_rm.ui) end)
    end

    local _orig_reader_menu_onKeyPress = ReaderMenu.onKeyPress
    local _orig_reader_menu_onKeyRepeat = ReaderMenu.onKeyRepeat
    local _orig_reader_menu_onKeyRelease = ReaderMenu.onKeyRelease
    local MENU_HOLD_DELAY = 0.5

    ReaderMenu.onKeyPress = function(self_rm, key)
        if is_non_touch_device() and is_enabled() and key_matches_menu(key) then
            if not self_rm._zen_page_browser_menu_hold_fn then
                self_rm._zen_page_browser_menu_hold_fn = function()
                    self_rm._zen_page_browser_menu_hold_fn = nil
                    if is_enabled() then open_page_browser(self_rm.ui, true) end
                end
                UIManager:scheduleIn(MENU_HOLD_DELAY, self_rm._zen_page_browser_menu_hold_fn)
            end
            return true
        end
        return _orig_reader_menu_onKeyPress and _orig_reader_menu_onKeyPress(self_rm, key)
    end

    ReaderMenu.onKeyRepeat = function(self_rm, key)
        if is_non_touch_device() and is_enabled() and key_matches_menu(key) then
            return true
        end
        return _orig_reader_menu_onKeyRepeat and _orig_reader_menu_onKeyRepeat(self_rm, key)
    end

    ReaderMenu.onKeyRelease = function(self_rm, key)
        if is_non_touch_device() and key_matches_menu(key) then
            local hold_fn = self_rm._zen_page_browser_menu_hold_fn
            if hold_fn then
                UIManager:unschedule(hold_fn)
                self_rm._zen_page_browser_menu_hold_fn = nil
                if is_enabled() and type(self_rm.onKeyPressShowMenu) == "function" then
                    return self_rm:onKeyPressShowMenu(nil, key)
                end
            end
            return true
        end
        return _orig_reader_menu_onKeyRelease and _orig_reader_menu_onKeyRelease(self_rm, key)
    end

    local function register_page_browser_zone(ui)
        ui:registerTouchZones({
            {
                id          = "zen_page_browser_reader",
                ges         = "swipe",
                screen_zone = {
                    ratio_x = 0, ratio_y = 0.86, ratio_w = 1, ratio_h = 0.14,
                },
                -- Override the config-menu and page-turn swipe zones so our
                -- north-swipe wins.  We deliberately do NOT override the tap
                -- zones (readerconfigmenu_tap etc.) — those cause unintended
                -- pan/brightness-slider interference via the zone sort order.
                overrides = {
                    "readerconfigmenu_swipe",
                    "readerconfigmenu_ext_swipe",
                    "paging_swipe",
                    "rolling_swipe",
                },
                handler = function(ges)
                    if not is_enabled() then return end
                    if ges.direction == "north" then
                        open_page_browser(ui)
                        ui:handleEvent(Event:new("HandledAsSwipe"))
                        return true
                    end
                end,
            },
        })
    end

    ReaderMenu.initGesListener = function(self_rm)
        if _orig_initGesListener then
            _orig_initGesListener(self_rm)
        end
        register_page_browser_zone(self_rm.ui)
        UIManager:scheduleIn(0.5, function() start_reader_tour(self_rm.ui) end)
    end

    -- onReaderReady is aliased to initGesListener in KOReader; keep in sync
    ReaderMenu.onReaderReady = ReaderMenu.initGesListener

    -- If a book is already open when this patch is applied (feature toggled
    -- at runtime), register the zone immediately.
    local ok_rui, ReaderUI = pcall(require, "apps/reader/readerui")
    if ok_rui and ReaderUI and ReaderUI.instance then
        pcall(register_page_browser_zone, ReaderUI.instance)
    end

    -- -----------------------------------------------------------------------
    -- ZenOS customisations for fulltext search dialog
    -- -----------------------------------------------------------------------
    local ok_rs, ReaderSearch = pcall(require, "apps/reader/modules/readersearch")
    if ok_rs and ReaderSearch then
        local InputDialog = require("ui/widget/inputdialog")
        local Screen_s    = require("device").screen
        local ZenModalClose = require("common/ui/zen_modal_close")
        local _           = require("gettext")
        local logger_rs   = require("common/zen_logger").new("page_browser")

        local _orig_InputDialog_onTap = InputDialog.onTap

        local SEARCH_ICON = "\u{F002}"

        local function enable_search_dialog_close(dialog)
            local function close_dialog()
                UIManager:close(dialog)
                return true
            end

            dialog.onCloseDialog = close_dialog
            ZenModalClose.installDialog(dialog, close_dialog)

            -- The virtual keyboard otherwise consumes Back and only hides itself.
            local keyboard = dialog._input_widget and dialog._input_widget.keyboard
            local keyboard_back = keyboard and keyboard.key_events and keyboard.key_events.Close
            if keyboard_back then
                keyboard.key_events.Close = nil
                keyboard.key_events.ZenCloseSearchDialog = keyboard_back
                keyboard_back.event = "ZenCloseSearchDialog"
                keyboard.onZenCloseSearchDialog = close_dialog
            end
        end

        ReaderSearch.onShowFulltextSearchInput = function(self, search_string)
            self.input_dialog = InputDialog:new{
                title = _("Search Book"),
                width = math.floor(math.min(Screen_s:getWidth(), Screen_s:getHeight()) * 0.9),
                input = search_string
                    or self.last_search_text
                    or (self.ui.doc_settings
                        and self.ui.doc_settings:readSetting("fulltext_search_last_search_text")),
                buttons = {
                    {
                        {
                            text             = SEARCH_ICON .. " " .. _("Search"),
                            is_enter_default = true,
                            callback         = function()
                                self:searchCallback()
                            end,
                        },
                    },
                },
            }
            enable_search_dialog_close(self.input_dialog)
            -- Always case insensitive, whole-word via regex
            self.case_insensitive = true
            self._zen_whole_word = true
            self.check_button_case = { checked = false }
            self.check_button_regex = { checked = false }

            -- Tap outside = close keyboard + dialog together
            self.input_dialog.onTap = function(dialog_self, arg, ges)
                if dialog_self.deny_keyboard_hiding then return end
                if dialog_self:isKeyboardVisible() then
                    local kb = dialog_self._input_widget and dialog_self._input_widget.keyboard
                    if kb and kb.dimen
                       and ges.pos:notIntersectWith(kb.dimen)
                       and ges.pos:notIntersectWith(dialog_self.dialog_frame.dimen) then
                        dialog_self:onCloseKeyboard()
                        UIManager:close(dialog_self)
                        return true
                    end
                    return _orig_InputDialog_onTap(dialog_self, arg, ges)
                else
                    if ges.pos:notIntersectWith(dialog_self.dialog_frame.dimen) then
                        UIManager:close(dialog_self)
                        return true
                    end
                end
            end

            UIManager:show(self.input_dialog)
            self.input_dialog:onShowKeyboard()
        end

        -- Whole-word matching via \b word-boundary assertions.
        -- Note: \b is ASCII-only in ECMAScript/SRELL (matches [A-Za-z0-9_] boundaries),
        -- so it correctly handles the Latin-script case (e.g. "red" does not match "tired").
        -- Lookbehind/lookahead (?<!...) require SRELL 4+; older embedded SRELL versions
        -- silently ignore them, causing every pattern to match as a substring.
        local function make_whole_word_regex(text)
            local escaped = text:gsub("[%^%$%.%*%+%?%(%)%[%]%{%}%|\\]", "\\%0")
            return "\\b" .. escaped .. "\\b"
        end

        local function supports_regex_search(self)
            local document = self.ui and self.ui.document
            return document and type(document.checkRegex) == "function"
        end

        local function fixed_layout_whole_word(text)
            -- Kopt treats surrounding spaces as start/end word boundaries.
            return " " .. text .. " "
        end

        local _orig_rs_search = ReaderSearch.search
        local function regex_search_type(self, search_type)
            local source_type = search_type
            if type(source_type) ~= "table" then
                source_type = self.current_search_type or self.default_search_type
            end
            if type(source_type) ~= "table" then
                return true -- KOReader before search-type tables used a regex boolean.
            end
            local whole_word_type = {}
            for key, value in pairs(source_type) do
                whole_word_type[key] = value
            end
            whole_word_type.regex = true
            return whole_word_type
        end

        function ReaderSearch:search(pattern, origin, search_type, case_insensitive)
            if not is_substring_enabled() and supports_regex_search(self) then
                pattern = make_whole_word_regex(pattern)
                search_type = regex_search_type(self, search_type)
            elseif not is_substring_enabled() then
                pattern = fixed_layout_whole_word(pattern)
            end
            return _orig_rs_search(self, pattern, origin, search_type, case_insensitive)
        end

        local _orig_rs_findAllText = ReaderSearch.findAllText
        function ReaderSearch:findAllText(search_text)
            if not is_substring_enabled() and supports_regex_search(self) then
                search_text = make_whole_word_regex(search_text)
                if type(self.current_search_type) == "table" then
                    local saved_search_type = self.current_search_type
                    self.current_search_type = regex_search_type(self, saved_search_type)
                    local result = _orig_rs_findAllText(self, search_text)
                    self.current_search_type = saved_search_type
                    return result
                end
                self.use_regex = true
            elseif not is_substring_enabled() then
                search_text = fixed_layout_whole_word(search_text)
            end
            return _orig_rs_findAllText(self, search_text)
        end

        local function enable_search_results_focus(menu)
            if not supports_page_browser_focus() then return end

            menu.mergeTitleBarIntoLayout = function(menu_self)
                local title_layout = menu_self.title_bar
                    and menu_self.title_bar:generateHorizontalLayout() or {}
                for i, row in ipairs(title_layout) do
                    table.insert(menu_self.layout, i, row)
                end
                if menu_self.selected then
                    menu_self.selected.y = menu_self.selected.y + #title_layout
                end
            end

            local orig_on_key_press = menu.onKeyPress
            menu.onKeyPress = function(menu_self, key)
                if key and type(key.match) == "function" then
                    if key:match({ "Up" }) then
                        return menu_self:onFocusMove({ 0, -1 })
                    elseif key:match({ "Right" }) then
                        return menu_self:onFocusMove({ 1, 0 })
                    elseif key:match({ "Down" }) then
                        return menu_self:onFocusMove({ 0, 1 })
                    elseif key:match({ "Left" }) then
                        return menu_self:onFocusMove({ -1, 0 })
                    elseif key:match({ "Press" }) or key:match({ "Return" })
                            or key:match({ "Enter" }) then
                        return menu_self:onPress()
                    end
                end
                return orig_on_key_press and orig_on_key_press(menu_self, key)
            end

            local orig_on_key_repeat = menu.onKeyRepeat
            menu.onKeyRepeat = function(menu_self, key)
                if key and type(key.match) == "function" then
                    if key:match({ "Up" }) then
                        return menu_self:onFocusMove({ 0, -1 })
                    elseif key:match({ "Right" }) then
                        return menu_self:onFocusMove({ 1, 0 })
                    elseif key:match({ "Down" }) then
                        return menu_self:onFocusMove({ 0, 1 })
                    elseif key:match({ "Left" }) then
                        return menu_self:onFocusMove({ -1, 0 })
                    end
                end
                return orig_on_key_repeat and orig_on_key_repeat(menu_self, key)
            end

            menu:updateItems(1, true)
        end

        -- Patch onShowFindAllResults: fix reader-content ghosting at the bottom
        -- of the screen when search results are shown.
        --
        -- ROOT CAUSE: Menu:new{} runs while Screen:getHeight() is still reduced
        -- by the virtual keyboard (shown for our search InputDialog). This makes
        -- menu.dimen.h and the internal OverlapGroup dimen height equal to the
        -- keyboard-shrunk height (~1525 vs real 1696 on a Kobo). Menu:init()
        -- creates its FrameContainer WITHOUT an explicit height — so the FC's
        -- paintTo uses `self.height or my_size.h = nil or 1525 = 1525`, filling
        -- only 1525px of white background and leaving the bottom 171px untouched
        -- (showing through the reader content in the framebuffer).
        --
        -- By the time our wrapper runs (after UIManager:show(result_menu) returns),
        -- the keyboard has been dismissed and Screen:getHeight() is back to the
        -- real value. We patch menu.dimen.h (gesture hit range) and set an
        -- explicit menu[1].height (FrameContainer) so its background fill covers
        -- the full screen.  A flashui setDirty then schedules a full e-ink refresh.
        local _orig_onShowFindAllResults = ReaderSearch.onShowFindAllResults
        ReaderSearch.onShowFindAllResults = function(self, not_cached)
            -- Only apply whole-word filtering when substring mode is NOT enabled
            if not is_substring_enabled() and self._zen_whole_word and not_cached and self.findall_results then
                local filtered = {}
                for _i, item in ipairs(self.findall_results) do
                    local pre = item.matched_word_prefix or ""
                    local suf = item.matched_word_suffix or ""
                    if pre == "" and suf == "" then
                        table.insert(filtered, item)
                    end
                end
                self.findall_results = filtered
            end

            _orig_onShowFindAllResults(self, not_cached)
            local menu = self.result_menu
            if not menu or not UIManager:isWidgetShown(menu) then return end

            enable_search_results_focus(menu)

            local real_h = Screen_s:getHeight()

            -- Fix outer dimen so gesture hit-testing covers the full screen.
            if menu.dimen and menu.dimen.h < real_h then
                logger_rs.info("fixing menu height:", menu.dimen.h, "→", real_h)
                menu.dimen.h = real_h
            end

            -- Force an explicit height on the FrameContainer so its white
            -- background fill (container_height = self.height or my_size.h)
            -- extends to the full screen rather than stopping at the
            -- keyboard-shrunk OverlapGroup height.
            local fc = menu[1]
            if fc then
                fc.height = real_h
            end

            UIManager:setDirty(menu, "flashui")

            -- Extend close_callback to mark the reader view dirty after the
            -- results menu is dismissed.  Without this the clock overlay drawn
            -- by ReaderView.paintTo may not be repainted because the guard in
            -- that patch skips drawing while a non-reader widget is on top, and
            -- the subsequent UIManager repaint cycle can miss re-invoking paintTo.
            if menu.close_callback then
                local orig_close_cb = menu.close_callback
                menu.close_callback = function()
                    orig_close_cb()
                    if self.view then
                        UIManager:setDirty(self.view, "partial")
                    end
                end
            end
        end
    end

    -- -----------------------------------------------------------------------
    -- Primary intercept: patch ReaderConfig.onSwipeShowConfigMenu directly.
    -- More reliable than zone-override ordering since it does not depend on
    -- the dep-graph re-serialisation happening in the right order.
    -- -----------------------------------------------------------------------
    local function is_bottom_swipe_enabled()
        local features = _plugin_ref
            and _plugin_ref.config
            and _plugin_ref.config.features
        if type(features) ~= "table" then return false end
        if not (features.page_browser == true or features.reader_bottom_menu == true) then return false end
        if features.lockdown_mode == true then
            local lc = _plugin_ref.config.lockdown
            if type(lc) == "table" and lc.disable_bottom_menu_swipe then return false end
        end
        return true
    end

    local ok_rc, ReaderConfig = pcall(require, "apps/reader/modules/readerconfig")
    if ok_rc and ReaderConfig then
        local _orig_onSwipeShowConfigMenu = ReaderConfig.onSwipeShowConfigMenu
        ReaderConfig.onSwipeShowConfigMenu = function(self_rc, ges)
            if is_enabled() and ges.direction == "north" then
                open_page_browser(self_rc.ui)
                self_rc.ui:handleEvent(Event:new("HandledAsSwipe"))
                return true
            end
            -- suppress native config menu swipe when bottom swipe is disabled
            if not is_bottom_swipe_enabled() then return end
            if _orig_onSwipeShowConfigMenu then
                return _orig_onSwipeShowConfigMenu(self_rc, ges)
            end
        end

        -- suppress bottom tap opening the native config menu when Zen owns the zone
        local _orig_onTapShowConfigMenu = ReaderConfig.onTapShowConfigMenu
        ReaderConfig.onTapShowConfigMenu = function(self_rc)
            if is_bottom_swipe_enabled() then return end
            if _orig_onTapShowConfigMenu then
                return _orig_onTapShowConfigMenu(self_rc)
            end
        end
    end

end -- apply_page_browser

return apply_page_browser
