-- common/zen_icon_picker.lua
-- Full-screen horizontally-paginating icon grid picker.
-- Swipe west/east to change pages; footer mirrors the shared pages scrollbar.
--
-- Usage:
--   local showIconPickerDialog = require("common/ui/zen_icon_picker")
--   showIconPickerDialog(icons_list, current_icon, function(name) ... end)
--   Each item in icons_list is {name=string, file=string_or_nil}.
--   file=nil means render via KOReader icon name; otherwise use the absolute path.

local function showIconPickerDialog(icons_list, current_icon, on_select)
    local icon_utils = require("common/utils")
    local function displayName(item)
        return (icon_utils.getIconDisplayName(item.name)
            :gsub("^quick_", ""):gsub("^tab_", ""):gsub("^lookup_", ""))
    end
    table.sort(icons_list, function(a, b)
        return displayName(a):lower() < displayName(b):lower()
    end)

    local _          = require("gettext")
    local Device     = require("device")
    local Screen     = Device.screen
    local Geom       = require("ui/geometry")
    local Blitbuffer = require("ffi/blitbuffer")
    local Font       = require("ui/font")
    local Size       = require("ui/size")
    local UIManager  = require("ui/uimanager")
    local FocusManager = require("ui/widget/focusmanager")
    local CC         = require("ui/widget/container/centercontainer")
    local FC         = require("ui/widget/container/framecontainer")
    local VG         = require("ui/widget/verticalgroup")
    local HG         = require("ui/widget/horizontalgroup")
    local IW         = require("ui/widget/iconwidget")
    local TW         = require("ui/widget/textwidget")
    local pager      = require("common/ui/zen_pager")
    local TitleStyle = require("common/ui/zen_title_style")

    local sw, sh   = Screen:getWidth(), Screen:getHeight()
    local icon_sz  = Screen:scaleBySize(42)
    local label_size = math.max(Screen:scaleBySize(8),
        (Font.sizemap and Font.sizemap["xx_smallinfofont"] or Screen:scaleBySize(18))
        - Screen:scaleBySize(2))
    local label_face = Font:getFace("smallinfofont", label_size)
    local label_probe = TW:new{ text = "Wg", face = label_face, padding = 0 }
    local label_h  = label_probe:getSize().h
    label_probe:free()
    local cell_pad = Screen:scaleBySize(4)
    local max_cell_brd = Screen:scaleBySize(2)
    local pad      = Size.padding.default
    local span     = Size.span.vertical_default

    -- Always reserve the tallest bar style height so the layout never resizes on style changes.
    local bar_area_h = pager.PN_FOOTER_H

    -- Close button.
    local close_sz  = TitleStyle.ICON_SIZE
    local close_iw  = IW:new{ icon = "close", width = close_sz, height = close_sz }

    local content_w = sw - 2 * pad
    local cols      = math.max(4, math.floor(content_w / Screen:scaleBySize(78)))
    local cell_w    = math.floor(content_w / cols)
    local cell_h    = icon_sz + label_h + cell_pad * 2 + max_cell_brd * 2
    local label_max_w = cell_w - cell_pad * 2 - max_cell_brd * 2

    -- Title on the left, close icon on the right.
    local title_x = TitleStyle.getTitleX(0)
    local close_slot_x = sw - TitleStyle.RIGHT_PADDING - TitleStyle.BUTTON_SIZE
    local title_text_w = math.max(1, close_slot_x - title_x)
    local title_tw = TW:new{
        text  = _("Select icon"),
        face  = TitleStyle.getTitleFace(),
        bold  = true,
        width = title_text_w,
    }
    local title_text_h = title_tw:getSize().h
    local title_h      = TitleStyle.ROW_HEIGHT

    -- Fit as many rows as possible within the available vertical space.
    local overhead      = TitleStyle.HEADER_HEIGHT + pad + span + span + bar_area_h
    local max_grid_h    = math.max(cell_h, sh - overhead)
    local rows_per_page = math.max(1, math.floor(max_grid_h / cell_h))
    local grid_h        = rows_per_page * cell_h
    local per_page      = cols * rows_per_page
    local total_pages   = math.max(1, math.ceil(math.max(#icons_list, 1) / per_page))

    local selected_idx
    if #icons_list > 0 then
        selected_idx = 1
        for i, item in ipairs(icons_list) do
            if item.name == current_icon then
                selected_idx = i
                break
            end
        end
    end
    local show_focus = not Device:isTouchDevice() or Device:hasDPad() or Device:hasKeyboard()
    local focus_area = selected_idx and "grid" or "close"
    local footer_side = "left"
    local cur_page = show_focus and selected_idx
        and math.ceil(selected_idx / per_page) or 1

    -- Pre-build one VG per page (painted directly; no ScrollableContainer needed).
    local page_vgs = {}
    local cell_frames = {}
    for p = 1, total_pages do
        local pv      = VG:new{ align = "left" }
        local start_i = (p - 1) * per_page + 1
        local row_g
        for offset = 0, per_page - 1 do
            local i = start_i + offset
            if i > #icons_list then break end
            if offset % cols == 0 then
                row_g = HG:new{ align = "top" }
                table.insert(pv, row_g)
            end
            local item      = icons_list[i]
            local name      = item.name
            local is_sel    = (current_icon == name)
            local short     = icon_utils.getIconDisplayName(name)
                :gsub("^quick_", ""):gsub("^tab_", ""):gsub("^lookup_", "")
            -- bordersize is added on top of content by FC.getSize(), so subtract it
            -- from the CC inner dimen so each FC reports exactly cell_w to HG.
            local cell_brd = is_sel and Screen:scaleBySize(2) or Screen:scaleBySize(1)
            local cell_frame = FC:new{
                width      = cell_w,
                height     = cell_h,
                bordersize = cell_brd,
                color      = is_sel and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY,
                background = is_sel and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
                padding    = cell_pad,
                CC:new{
                    dimen = Geom:new{ w = cell_w - cell_pad*2 - 2*cell_brd, h = cell_h - cell_pad*2 - 2*cell_brd },
                    VG:new{
                        align = "center",
                        IW:new{ file = item.file or nil, icon = item.file and nil or name, width = icon_sz, height = icon_sz, alpha = true },
                        TW:new{
                            text      = short,
                            face      = label_face,
                            max_width = label_max_w,
                            padding   = 0,
                        },
                    },
                },
            }
            table.insert(row_g, cell_frame)
            cell_frames[i] = cell_frame
        end
        page_vgs[p] = pv
    end

    local content_x = pad
    local grid_x    = content_x
    local grid_y    = TitleStyle.HEADER_HEIGHT + span
    local bar_y = pager.getCenteredFooterY(
        grid_y + grid_h,
        sh - pad - bar_area_h,
        bar_area_h,
        true
    )

    local function paintBar(bb)
        pager.paint(bb, content_x, bar_y, content_w, bar_area_h, cur_page, total_pages, "page_number")
    end

    -- forward ref so gesture handlers can close the dialog before it's assigned.
    local dialog
    local closed = false

    local function closeDialog()
        if closed then return end
        closed = true
        UIManager:close(dialog, "ui")
        UIManager:forceRePaint()
    end

    local function goToPage(p)
        if p < 1 or p > total_pages then return end
        cur_page = p
        local first = (p - 1) * per_page + 1
        local last = math.min(#icons_list, first + per_page - 1)
        if (focus_area == "grid" or focus_area == "close") and selected_idx
                and (selected_idx < first or selected_idx > last) then
            selected_idx = first
        end
        UIManager:setDirty(dialog, function() return "ui", dialog.dimen end)
    end

    local function selectIcon(idx)
        local item = idx and icons_list[idx]
        if not item then return true end
        closeDialog()
        UIManager:nextTick(function()
            local ok_select, err = xpcall(function()
                on_select(item.name)
            end, debug.traceback)
            if not ok_select then
                require("common/zen_logger").new("zen_icon_picker").warn("Selection failed:", err)
            end
        end)
        return true
    end

    local function pageBounds(page)
        local first = (page - 1) * per_page + 1
        return first, math.min(#icons_list, first + per_page - 1)
    end

    local function changePage(diff)
        if total_pages <= 1 then return true end
        local old_first = (cur_page - 1) * per_page + 1
        local offset = selected_idx and selected_idx - old_first or 0
        local page = ((cur_page - 1 + diff) % total_pages) + 1
        if focus_area == "grid" or focus_area == "close" then
            local first, last = pageBounds(page)
            selected_idx = math.min(first + offset, last)
        end
        goToPage(page)
        return true
    end

    local function focusGridFromFooter()
        local first, last = pageBounds(cur_page)
        if last < first then return true end
        local last_row = first + math.floor((last - first) / cols) * cols
        selected_idx = footer_side == "left" and last_row or last
        focus_area = "grid"
        goToPage(cur_page)
        return true
    end

    local function moveGridFocus(dx, dy)
        local first, last = pageBounds(cur_page)
        local offset = selected_idx - first
        local row = math.floor(offset / cols)
        local col = offset % cols

        if dy < 0 then
            if row == 0 then
                focus_area = "close"
            else
                selected_idx = selected_idx - cols
            end
        elseif dy > 0 then
            local next_idx = selected_idx + cols
            if next_idx <= last then
                selected_idx = next_idx
            elseif total_pages > 1 then
                focus_area = "footer"
                footer_side = col < cols / 2 and "left" or "right"
            end
        elseif dx < 0 and col > 0 then
            selected_idx = selected_idx - 1
        elseif dx > 0 and col < cols - 1 and selected_idx < last then
            selected_idx = selected_idx + 1
        end
        goToPage(cur_page)
        return true
    end

    local function moveFocus(dx, dy)
        if focus_area == "close" then
            if dy > 0 and selected_idx then focus_area = "grid" end
            goToPage(cur_page)
            return true
        end
        if focus_area == "footer" then
            if dy < 0 then return focusGridFromFooter() end
            if dx < 0 then
                footer_side = "left"
            elseif dx > 0 then
                footer_side = "right"
            end
            goToPage(cur_page)
            return true
        end
        return moveGridFocus(dx, dy)
    end

    local function canUsePageNumber()
        return total_pages > 1
    end

    local function pageNumberZone(gx, gy, extend_down)
        if not canUsePageNumber() then return nil end
        return pager.getPageNumberZone(
            gx, gy, content_x, bar_y, content_w, bar_area_h,
            extend_down and sh or bar_y + bar_area_h
        )
    end

    local function handlePageNumberTap(gx, gy)
        local zone = pageNumberZone(gx, gy, true)
        if not zone then return false end
        pager.flashChevron(zone, content_x, bar_y, content_w, bar_area_h)
        if zone == "left" then
            goToPage(cur_page > 1 and cur_page - 1 or total_pages)
        elseif zone == "right" then
            goToPage(cur_page < total_pages and cur_page + 1 or 1)
        end
        return true
    end

    local function handlePageNumberHold(gx, gy)
        local zone = pageNumberZone(gx, gy, false)
        if not zone then return false end
        if zone == "left" then
            local skip = pager.getHoldSkip()
            goToPage(skip == "ends" and 1 or math.max(1, cur_page - (tonumber(skip) or 10)))
            return true
        elseif zone == "right" then
            local skip = pager.getHoldSkip()
            goToPage(skip == "ends" and total_pages or math.min(total_pages, cur_page + (tonumber(skip) or 10)))
            return true
        end
        return true
    end

    local PickerDlg = FocusManager:extend{}

    function PickerDlg:init()
        self:_init()
        self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
        if Device:hasKeys() then
            self.key_events.CancelOrClose = { { Device.input.group.Back } }
            self.key_events.IconPickerPrevPage = { { Device.input.group.PgBack }, event = "IconPickerPage", args = -1 }
            self.key_events.IconPickerNextPage = { { Device.input.group.PgFwd }, event = "IconPickerPage", args = 1 }
            if not Device:hasDPad() then
                self.key_events.IconPickerUp = { { "Up" }, event = "IconPickerUp" }
                self.key_events.IconPickerDown = { { "Down" }, event = "IconPickerDown" }
                self.key_events.IconPickerLeft = { { "Left" }, event = "IconPickerLeft" }
                self.key_events.IconPickerRight = { { "Right" }, event = "IconPickerRight" }
                self.key_events.IconPickerSelect = { { "Press" }, event = "IconPickerSelect" }
            end
        end
        self:registerTouchZones({
            {
                id          = "picker_tap",
                ges         = "tap",
                screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
                handler     = function(ges)
                    local gx, gy = ges.pos.x, ges.pos.y
                    if gx >= close_slot_x
                       and gx < close_slot_x + TitleStyle.BUTTON_SIZE
                       and gy >= 0 and gy < TitleStyle.HEADER_CONTENT_HEIGHT then
                        require("common/ui/button_feedback").flashButton(close_iw.dimen)
                        closeDialog()
                        return true
                    end
                    if handlePageNumberTap(gx, gy) then
                        return true
                    end
                    -- Grid cells.
                    local grid_geom = Geom:new{
                        x = grid_x, y = grid_y,
                        w = cols * cell_w, h = rows_per_page * cell_h,
                    }
                    if ges.pos:intersectWith(grid_geom) then
                        local col_i = math.floor((gx - grid_x) / cell_w)
                        local row_i = math.floor((gy - grid_y) / cell_h)
                        local idx   = (cur_page - 1) * per_page + row_i * cols + col_i + 1
                        if idx >= 1 and idx <= #icons_list then
                            selectIcon(idx)
                        end
                    end
                    return true
                end,
            },
            {
                id          = "picker_page_number_hold",
                ges         = "hold",
                screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
                handler     = function(ges)
                    if handlePageNumberHold(ges.pos.x, ges.pos.y) then
                        return true
                    end
                    return false
                end,
            },
            {
                id          = "picker_swipe",
                ges         = "swipe",
                screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
                handler     = function(ges)
                    local dir = ges.direction
                    if dir == "west" then
                        goToPage(cur_page + 1)
                    elseif dir == "east" then
                        goToPage(cur_page - 1)
                    else
                        closeDialog()
                    end
                    return true
                end,
            },
        })
    end

    function PickerDlg:onCancelOrClose()
        closeDialog()
        return true
    end

    function PickerDlg:onIconPickerPage(diff)
        return changePage(diff)
    end

    function PickerDlg:onFocusMove(args)
        return moveFocus(args and args[1] or 0, args and args[2] or 0)
    end

    function PickerDlg:onIconPickerUp()
        return moveFocus(0, -1)
    end

    function PickerDlg:onIconPickerDown()
        return moveFocus(0, 1)
    end

    function PickerDlg:onIconPickerLeft()
        return moveFocus(-1, 0)
    end

    function PickerDlg:onIconPickerRight()
        return moveFocus(1, 0)
    end

    function PickerDlg:onPress()
        if focus_area == "close" then
            require("common/ui/button_feedback").flashButton(close_iw.dimen)
            closeDialog()
            return true
        end
        if focus_area == "footer" then
            return changePage(footer_side == "left" and -1 or 1)
        end
        return selectIcon(selected_idx)
    end

    function PickerDlg:onIconPickerSelect()
        return self:onPress()
    end

    function PickerDlg:paintTo(bb, x, y)
        self.dimen.x = x
        self.dimen.y = y
        bb:paintRect(0, 0, sw, sh, Blitbuffer.COLOR_WHITE)
        local focused_frame = show_focus and focus_area == "grid" and cell_frames[selected_idx] or nil
        if self._focused_frame and self._focused_frame ~= focused_frame then
            self._focused_frame.invert = false
        end
        if focused_frame then focused_frame.invert = true end
        self._focused_frame = focused_frame

        close_iw.invert = show_focus and focus_area == "close"
        close_iw:paintTo(bb, TitleStyle.getTrailingIconX(sw, 0),
            TitleStyle.VERTICAL_PADDING + math.floor((title_h - close_sz) / 2))
        title_tw:paintTo(bb, title_x,
            TitleStyle.VERTICAL_PADDING + math.floor((title_h - title_text_h) / 2))
        bb:paintRect(0, TitleStyle.HEADER_CONTENT_HEIGHT, sw,
            TitleStyle.DIVIDER_HEIGHT, TitleStyle.DIVIDER_COLOR)
        -- Current page grid.
        page_vgs[cur_page]:paintTo(bb, grid_x, grid_y)
        -- Page indicator bar.
        paintBar(bb)
        if show_focus and focus_area == "footer" and total_pages > 1 then
            local footer_x = footer_side == "left"
                and content_x or content_x + content_w - pager.CHEV_W
            bb:invertRect(footer_x, bar_y, pager.CHEV_W, bar_area_h)
        end
    end

    dialog = PickerDlg:new{}
    UIManager:show(dialog, "full")
end

return showIconPickerDialog
