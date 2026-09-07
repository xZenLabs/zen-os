-- Full-screen paginated single-select list picker.

local function showMenuPicker(opts)
    local _          = require("gettext")
    local BD         = require("ui/bidi")
    local Device     = require("device")
    local Screen     = Device.screen
    local Geom       = require("ui/geometry")
    local Blitbuffer = require("ffi/blitbuffer")
    local Font       = require("ui/font")
    local Size       = require("ui/size")
    local UIManager  = require("ui/uimanager")
    local FocusManager = require("ui/widget/focusmanager")
    local ImageWidget = require("ui/widget/imagewidget")
    local IW         = require("ui/widget/iconwidget")
    local TW         = require("ui/widget/textwidget")
    local pager      = require("common/ui/zen_pager")
    local TitleStyle = require("common/ui/zen_title_style")
    local TruncatedTextMessage = require("common/ui/truncated_text_message")

    opts = opts or {}
    local items = type(opts.items) == "table" and opts.items or {}
    local footer_buttons = type(opts.footer_buttons) == "table" and opts.footer_buttons or {}
    local footer_under_header = #footer_buttons > 0
        and opts.footer_buttons_under_header == true
    local footer_button_count = math.min(footer_under_header and 3 or 2, #footer_buttons)
    local has_footer_buttons = footer_button_count > 0
    local title_action_callback = type(opts.title_action_callback) == "function"
        and opts.title_action_callback or nil
    local has_title_action = title_action_callback ~= nil
        and type(opts.title_action_icon) == "string"
        and opts.title_action_icon ~= ""
    local black_text = opts.black_text == true
    local ZenButton = has_footer_buttons and require("common/ui/zen_button") or nil
    local on_select = type(opts.on_select) == "function" and opts.on_select or function() end
    local back_hold_callback = opts.back_hold_callback
    if type(back_hold_callback) ~= "function" then
        local settings_page = rawget(_G, "__ZEN_UI_SETTINGS_PAGE")
        if settings_page and settings_page.backToRootMenu then
            back_hold_callback = function()
                return settings_page:backToRootMenu()
            end
        end
    end

    local pad      = Size.padding.default
    local span     = Size.span.vertical_default
    local row_pad  = Screen:scaleBySize(12)
    local has_secondary, has_images
    local base_row_h, row_h, row_face, secondary_face
    local image_h, image_w, image_gap
    local indent_step = Screen:scaleBySize(16)
    local footer_button_h = has_footer_buttons and Screen:scaleBySize(32) or 0
    local footer_gap = has_footer_buttons and Screen:scaleBySize(6) or 0
    local footer_area_h = has_footer_buttons and (
        footer_under_header
            and footer_button_count * footer_button_h
                + math.max(0, footer_button_count - 1) * footer_gap
                + 2 * Screen:scaleBySize(5)
            or footer_button_h + 2 * Screen:scaleBySize(5)
    ) or 0
    local bar_area_h = has_footer_buttons and 0 or pager.PN_FOOTER_H
    local divider_h = TitleStyle.DIVIDER_HEIGHT
    local header_h = math.max(0, tonumber(opts.header_height) or 0)

    local back_sz  = TitleStyle.ICON_SIZE
    local mirrored = BD.mirroredUILayout()
    local back_iw  = IW:new{
        icon = mirrored and "chevron.right" or "chevron.left",
        width = back_sz,
        height = back_sz,
    }
    local title_action_iw = has_title_action and IW:new{
        file = opts.title_action_icon,
        width = back_sz,
        height = back_sz,
    } or nil

    local sw, sh, content_w, title_text_w
    local content_x, list_x, list_h, rows_per_page, page_h, bar_y, total_pages
    local title_action_button_x, title_action_icon_x
    local footer_button_rects = {}
    local title_x = TitleStyle.getTitleX(0)
    local title_h = TitleStyle.ROW_HEIGHT
    local title_block_h = TitleStyle.HEADER_HEIGHT
    local divider_y = TitleStyle.HEADER_CONTENT_HEIGHT
    local list_y = title_block_h + header_h
        + (footer_under_header and footer_area_h or 0)
    local cur_page = 1

    local function updateGeometry()
        has_secondary = false
        has_images = false
        for _i, item in ipairs(items) do
            if type(item.secondary_text) == "string" and item.secondary_text ~= "" then
                has_secondary = true
            end
            if type(item.image_file) == "string" and item.image_file ~= "" then
                has_images = true
            end
        end
        base_row_h = Screen:scaleBySize((has_secondary or has_images) and 64 or 48)
        row_h = base_row_h
        row_face = Font:getFace("cfont", has_secondary and 21 or 24)
        secondary_face = has_secondary and Font:getFace("smallinfofont", 16) or nil
        image_gap = has_images and Screen:scaleBySize(10) or 0
        sw, sh = Screen:getWidth(), Screen:getHeight()
        content_w = sw - 2 * pad
        title_text_w = sw - title_x - TitleStyle.RIGHT_PADDING
            - (has_title_action and TitleStyle.BUTTON_SIZE or 0)
        if has_title_action then
            title_action_button_x = mirrored and TitleStyle.LEFT_PADDING
                or sw - TitleStyle.RIGHT_PADDING - TitleStyle.BUTTON_SIZE
            title_action_icon_x = title_action_button_x + TitleStyle.BUTTON_PADDING
        end
        content_x = pad
        list_x = content_x
        local overhead = list_y + pad + span + bar_area_h
            + (footer_under_header and 0 or footer_area_h)
        list_h = math.max(base_row_h, sh - overhead)
        rows_per_page = math.max(1, math.floor(list_h / base_row_h))
        local requested_rows = math.floor(tonumber(opts.rows_per_page) or 0)
        if requested_rows > 0 then
            rows_per_page = math.min(rows_per_page, requested_rows)
            row_h = math.max(base_row_h, math.floor(list_h / rows_per_page))
        else
            row_h = base_row_h
        end
        image_h = has_images and math.max(1, row_h - Screen:scaleBySize(8)) or 0
        image_w = has_images and math.max(1, math.floor(image_h * 2 / 3)) or 0
        page_h = rows_per_page * row_h
        if bar_area_h > 0 then
            bar_y = pager.getCenteredFooterY(
                list_y + page_h,
                sh - pad - bar_area_h,
                bar_area_h,
                true
            )
        else
            bar_y = sh
        end
        total_pages = math.max(1, math.ceil(math.max(#items, 1) / rows_per_page))
        cur_page = math.max(1, math.min(cur_page, total_pages))
        footer_button_rects = {}
        if has_footer_buttons then
            if footer_under_header then
                local preview_gap = Screen:scaleBySize(20)
                local preview_w = math.max(1,
                    math.floor((sw * 0.75 - preview_gap) / 2))
                local button_w = math.min(Screen:scaleBySize(210), preview_w)
                local new_column_center = sw / 2 + (preview_w + preview_gap) / 2
                local base_x = math.floor(new_column_center - button_w / 2)
                local button_y = title_block_h + header_h + Screen:scaleBySize(5)
                for item_index = 1, footer_button_count do
                    footer_button_rects[item_index] = {
                        x = base_x,
                        y = button_y + (item_index - 1) * (footer_button_h + footer_gap),
                        w = button_w,
                        h = footer_button_h,
                    }
                end
            else
                local button_w = math.min(Screen:scaleBySize(210),
                    math.floor((content_w - footer_gap * (footer_button_count - 1))
                        / footer_button_count))
                local buttons_w = button_w * footer_button_count
                    + footer_gap * (footer_button_count - 1)
                local base_x = math.floor((sw - buttons_w) / 2)
                local button_y = sh - Screen:scaleBySize(5) - footer_button_h
                for physical_index = 1, footer_button_count do
                    local item_index = mirrored
                        and footer_button_count - physical_index + 1 or physical_index
                    footer_button_rects[item_index] = {
                        x = base_x + (physical_index - 1) * (button_w + footer_gap),
                        y = button_y,
                        w = button_w,
                        h = footer_button_h,
                    }
                end
            end
        end
    end

    updateGeometry()
    local title_tw = TW:new{
        text  = opts.title or _("Choose item"),
        face  = TitleStyle.getTitleFace(),
        bold  = true,
        max_width = title_text_w,
    }
    local title_text_h = title_tw:getSize().h

    local dialog
    local closed = false
    local selected_idx = #items > 0 and not footer_under_header and 1 or nil
    local footer_selected_idx = has_footer_buttons
        and (footer_under_header or not selected_idx) and 1 or nil
    local back_focused = not selected_idx and not footer_selected_idx
    local title_action_focused = false
    local row_truncated = {}

    local function itemText(item)
        return type(item.text) == "string" and item.text or tostring(item.text or "")
    end

    local function itemSecondaryText(item)
        return type(item.secondary_text) == "string" and item.secondary_text or ""
    end

    local function rowAt(gx, gy)
        if gx < list_x or gx >= list_x + content_w
                or gy < list_y or gy >= list_y + page_h then
            return
        end
        local row_i = math.floor((gy - list_y) / row_h)
        local idx = (cur_page - 1) * rows_per_page + row_i + 1
        if items[idx] then return idx, row_i end
    end

    local function footerButtonAt(gx, gy)
        for item_index = 1, footer_button_count do
            local rect = footer_button_rects[item_index]
            if rect and gx >= rect.x and gx < rect.x + rect.w
                    and gy >= rect.y and gy < rect.y + rect.h then
                return item_index
            end
        end
    end

    local function closeDialog(item)
        if closed then return end
        closed = true
        UIManager:close(dialog, "ui")
        UIManager:forceRePaint()
        if type(opts.on_close) == "function" then opts.on_close(item) end
    end

    local function backToSettingsRoot()
        closeDialog()
        if back_hold_callback then back_hold_callback() end
        return true
    end

    local function goToPage(page)
        if page < 1 or page > total_pages then return end
        cur_page = page
        UIManager:setDirty(dialog, function() return "ui", dialog.dimen end)
    end

    local function selectItem(item)
        if not item then return true end
        if item.keep_open ~= true then closeDialog(item) end
        UIManager:nextTick(function()
            local ok_select, err = xpcall(function()
                on_select(item)
            end, debug.traceback)
            if not ok_select then
                require("common/zen_logger").new("zen_menu_picker").warn("Selection failed:", err)
            end
        end)
        return true
    end

    local function selectTitleAction()
        if not has_title_action then return true end
        if opts.title_action_keep_open ~= true then closeDialog() end
        UIManager:nextTick(function()
            local ok_select, err = xpcall(title_action_callback, debug.traceback)
            if not ok_select then
                require("common/zen_logger").new("zen_menu_picker").warn(
                    "Title action failed:", err)
            end
        end)
        return true
    end

    local function moveSelection(diff)
        if title_action_focused then
            if diff > 0 and (#items > 0 or has_footer_buttons) then
                title_action_focused = false
                if footer_under_header then
                    footer_selected_idx = 1
                elseif #items > 0 then
                    selected_idx = 1
                    goToPage(1)
                else
                    footer_selected_idx = 1
                end
                UIManager:setDirty(dialog, function() return "ui", dialog.dimen end)
            end
            return true
        end
        if back_focused then
            if diff > 0 and (#items > 0 or has_footer_buttons) then
                back_focused = false
                if footer_under_header then
                    footer_selected_idx = 1
                elseif #items > 0 then
                    selected_idx = 1
                    goToPage(1)
                else
                    footer_selected_idx = 1
                    UIManager:setDirty(dialog, function() return "ui", dialog.dimen end)
                end
            end
            return true
        end
        if footer_selected_idx then
            if footer_under_header and diff > 0 then
                if footer_selected_idx < footer_button_count then
                    footer_selected_idx = footer_selected_idx + 1
                elseif #items > 0 then
                    footer_selected_idx = nil
                    selected_idx = 1
                    goToPage(1)
                end
                UIManager:setDirty(dialog, function() return "ui", dialog.dimen end)
                return true
            elseif footer_under_header and diff < 0 and footer_selected_idx > 1 then
                footer_selected_idx = footer_selected_idx - 1
                UIManager:setDirty(dialog, function() return "ui", dialog.dimen end)
                return true
            end
            if diff < 0 then
                footer_selected_idx = nil
                if footer_under_header then
                    back_focused = true
                    UIManager:setDirty(dialog, function() return "ui", dialog.dimen end)
                elseif #items > 0 then
                    selected_idx = #items
                    goToPage(total_pages)
                else
                    back_focused = true
                    UIManager:setDirty(dialog, function() return "ui", dialog.dimen end)
                end
            end
            return true
        end
        if not selected_idx then return true end
        if diff < 0 and selected_idx == 1 then
            if footer_under_header then
                selected_idx = nil
                footer_selected_idx = footer_button_count
            else
                back_focused = true
            end
            UIManager:setDirty(dialog, function() return "ui", dialog.dimen end)
            return true
        end
        if diff > 0 and selected_idx == #items and has_footer_buttons then
            selected_idx = nil
            footer_selected_idx = 1
            UIManager:setDirty(dialog, function() return "ui", dialog.dimen end)
            return true
        end
        selected_idx = ((selected_idx - 1 + diff) % #items) + 1
        goToPage(math.ceil(selected_idx / rows_per_page))
        return true
    end

    local function changePage(diff)
        if total_pages <= 1 or not selected_idx then return true end
        local row_i = (selected_idx - 1) % rows_per_page
        local page = ((cur_page - 1 + diff) % total_pages) + 1
        local first = (page - 1) * rows_per_page + 1
        selected_idx = math.min(first + row_i, #items)
        goToPage(page)
        return true
    end

    local function canUsePageNumber()
        return bar_area_h > 0 and total_pages > 1
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

    local Picker = FocusManager:extend{ covers_fullscreen = true }

    function Picker:init()
        self:_init()
        self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
        if Device:hasKeys() then
            self.key_events.CancelOrClose = { { Device.input.group.Back } }
            self.key_events.MenuPickerPrevPage = { { Device.input.group.PgBack }, event = "MenuPickerPage", args = -1 }
            self.key_events.MenuPickerPageForward = { { Device.input.group.PgFwd }, event = "MenuPickerPage", args = 1 }
            if not Device:hasDPad() then
                self.key_events.MenuPickerUp = { { "Up" }, event = "MenuPickerMove", args = -1 }
                self.key_events.MenuPickerDown = { { "Down" }, event = "MenuPickerMove", args = 1 }
                self.key_events.MenuPickerPreviousPage = {
                    { "Left" }, event = "MenuPickerPage", args = mirrored and 1 or -1,
                }
                self.key_events.MenuPickerNextPage = {
                    { "Right" }, event = "MenuPickerPage", args = mirrored and -1 or 1,
                }
                self.key_events.MenuPickerSelect = { { "Press" }, event = "MenuPickerSelect" }
            end
        end
        self:registerTouchZones({
            {
                id          = "zen_menu_picker_tap",
                ges         = "tap",
                screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
                handler     = function(ges)
                    local gx, gy = ges.pos.x, ges.pos.y
                    local back_x = mirrored
                        and sw - TitleStyle.LEFT_PADDING - TitleStyle.BUTTON_SIZE
                        or TitleStyle.LEFT_PADDING
                    if gx >= back_x and gx < back_x + TitleStyle.BUTTON_SIZE
                       and gy >= 0 and gy < TitleStyle.HEADER_CONTENT_HEIGHT then
                        closeDialog()
                        return true
                    end
                    if has_title_action
                            and gx >= title_action_button_x
                            and gx < title_action_button_x + TitleStyle.BUTTON_SIZE
                            and gy >= 0 and gy < TitleStyle.HEADER_CONTENT_HEIGHT then
                        return selectTitleAction()
                    end
                    if gy >= 0 and gy < TitleStyle.HEADER_CONTENT_HEIGHT then
                        closeDialog()
                        return true
                    end
                    local footer_index = footerButtonAt(gx, gy)
                    if footer_index then
                        selectItem(footer_buttons[footer_index])
                        return true
                    end
                    if handlePageNumberTap(gx, gy) then return true end
                    if header_h > 0 and gy >= title_block_h
                            and gy < title_block_h + header_h then
                        if type(opts.on_header_tap) == "function" then
                            opts.on_header_tap(gx, gy - title_block_h, sw, header_h)
                        end
                        return true
                    end
                    local idx = rowAt(gx, gy)
                    if idx then selectItem(items[idx]) end
                    return true
                end,
            },
            {
                id          = "zen_menu_picker_hold",
                ges         = "hold",
                screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
                handler     = function(ges)
                    local gx, gy = ges.pos.x, ges.pos.y
                    if gx >= 0 and gx < sw
                            and gy >= 0 and gy < TitleStyle.HEADER_CONTENT_HEIGHT then
                        return backToSettingsRoot()
                    end
                    if handlePageNumberHold(gx, gy) then return true end
                    local idx, row_i = rowAt(gx, gy)
                    if idx and row_truncated[idx] then
                        local detail = itemText(items[idx])
                        local secondary = itemSecondaryText(items[idx])
                        if secondary ~= "" then detail = detail .. "\n" .. secondary end
                        TruncatedTextMessage.show(detail, {
                            y = (dialog.dimen.y or 0) + list_y + row_i * row_h,
                            h = row_h,
                        })
                        return true
                    end
                    return false
                end,
            },
            {
                id          = "zen_menu_picker_swipe",
                ges         = "swipe",
                screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
                handler     = function(ges)
                    local direction = BD.flipDirectionIfMirroredUILayout(ges.direction)
                    if direction == "west" then
                        changePage(1)
                    elseif direction == "east" then
                        changePage(-1)
                    end
                    return true
                end,
            },
        })
    end

    function Picker:onCancelOrClose()
        closeDialog()
        return true
    end

    function Picker:addItems(batch, next_title)
        if closed or type(batch) ~= "table" then return false end
        for _i, item in ipairs(batch) do items[#items + 1] = item end
        updateGeometry()
        if selected_idx and not back_focused then
            local first = (cur_page - 1) * rows_per_page + 1
            local last = math.min(#items, first + rows_per_page - 1)
            if selected_idx < first or selected_idx > last then selected_idx = first end
        end
        if next_title ~= nil then title_tw:setText(next_title) end
        title_tw:setMaxWidth(title_text_w)
        title_text_h = title_tw:getSize().h
        row_truncated = {}
        UIManager:setDirty(self, "ui")
        return true
    end

    function Picker:onMenuPickerMove(diff)
        return moveSelection(diff)
    end

    function Picker:onMenuPickerPage(diff)
        return changePage(diff)
    end

    function Picker:onFocusMove(args)
        local dx = args and args[1] or 0
        local dy = args and args[2] or 0
        if dy ~= 0 then return moveSelection(dy) end
        local toward_action = mirrored and -1 or 1
        if back_focused then
            if has_title_action and dx == toward_action then
                back_focused = false
                title_action_focused = true
                UIManager:setDirty(dialog, function() return "ui", dialog.dimen end)
            end
            return true
        end
        if title_action_focused then
            if dx == -toward_action then
                title_action_focused = false
                back_focused = true
                UIManager:setDirty(dialog, function() return "ui", dialog.dimen end)
            end
            return true
        end
        if footer_selected_idx and dx ~= 0 then
            if footer_under_header then return true end
            if mirrored then dx = -dx end
            footer_selected_idx = ((footer_selected_idx - 1 + dx)
                % footer_button_count) + 1
            UIManager:setDirty(dialog, function() return "ui", dialog.dimen end)
            return true
        end
        if dx ~= 0 and mirrored then dx = -dx end
        if dx ~= 0 then return changePage(dx) end
        return true
    end

    function Picker:onScreenResize()
        local page = cur_page
        updateGeometry()
        cur_page = math.max(1, math.min(page, total_pages))
        if selected_idx and not back_focused then
            local first = (cur_page - 1) * rows_per_page + 1
            local last = math.min(#items, first + rows_per_page - 1)
            if selected_idx < first or selected_idx > last then selected_idx = first end
        end
        title_tw:setMaxWidth(title_text_w)
        title_text_h = title_tw:getSize().h
        self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
        self:updateTouchZonesOnScreenResize(self.dimen)
        row_truncated = {}
        UIManager:setDirty(self, "ui")
        return false
    end

    function Picker:onPress()
        if back_focused then
            closeDialog()
            return true
        end
        if title_action_focused then return selectTitleAction() end
        if footer_selected_idx then
            return selectItem(footer_buttons[footer_selected_idx])
        end
        return selectItem(selected_idx and items[selected_idx])
    end

    function Picker:onMenuPickerSelect()
        return self:onPress()
    end

    function Picker:paintTo(bb, x, y)
        self.dimen.x = x
        self.dimen.y = y
        bb:paintRect(0, 0, sw, sh, Blitbuffer.COLOR_WHITE)

        back_iw.invert = back_focused
        local back_x = mirrored
            and sw - TitleStyle.getLeadingIconX(0) - back_sz
            or TitleStyle.getLeadingIconX(0)
        back_iw:paintTo(bb, back_x,
            TitleStyle.VERTICAL_PADDING + math.floor((title_h - back_sz) / 2))
        if title_action_iw then
            title_action_iw.invert = title_action_focused
            title_action_iw:paintTo(bb, title_action_icon_x,
                TitleStyle.VERTICAL_PADDING + math.floor((title_h - back_sz) / 2))
        end
        local title_paint_x = mirrored
            and sw - title_x - title_tw:getSize().w
            or title_x
        title_tw:paintTo(bb, title_paint_x,
            TitleStyle.VERTICAL_PADDING + math.floor((title_h - title_text_h) / 2))
        bb:paintRect(0, divider_y, sw, divider_h, TitleStyle.DIVIDER_COLOR)
        if header_h > 0 and type(opts.paint_header) == "function" then
            opts.paint_header(bb, 0, title_block_h, sw, header_h)
            if opts.hide_header_divider ~= true then
                bb:paintRect(0, title_block_h + header_h - divider_h,
                    sw, divider_h, TitleStyle.DIVIDER_COLOR)
            end
        end

        local first = (cur_page - 1) * rows_per_page + 1
        local last = math.min(#items, first + rows_per_page - 1)
        for idx = first, last do
            local row_i = idx - first
            local row_y = list_y + row_i * row_h
            local item = items[idx]
            local text = itemText(item)
            local secondary = itemSecondaryText(item)
            local text_indent = math.max(0, tonumber(item.indent_level) or 0) * indent_step
            local leading_width = has_images and image_w + image_gap or 0
            local selected = not back_focused
                and (not Device:isTouchDevice() or Device:hasDPad() or Device:hasKeyboard())
                and idx == selected_idx
            if selected then
                bb:paintRect(list_x, row_y, content_w, row_h,
                    black_text and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_BLACK)
            end
            local tw = TW:new{
                text      = text,
                face      = row_face,
                bold      = item.bold == true,
                max_width = content_w - row_pad * 2 - text_indent - leading_width,
                padding   = 0,
                fgcolor   = black_text and Blitbuffer.COLOR_BLACK
                    or (selected and Blitbuffer.COLOR_WHITE or nil),
            }
            local secondary_tw
            if secondary ~= "" then
                secondary_tw = TW:new{
                    text = secondary,
                    face = secondary_face,
                    max_width = content_w - row_pad * 2 - text_indent - leading_width,
                    padding = 0,
                    fgcolor = black_text and Blitbuffer.COLOR_BLACK
                        or (selected and Blitbuffer.COLOR_WHITE
                            or Blitbuffer.COLOR_DARK_GRAY),
                }
            end
            row_truncated[idx] = tw:isTruncated()
                or (secondary_tw and secondary_tw:isTruncated()) or false
            local sz = tw:getSize()
            if secondary_tw then
                local secondary_sz = secondary_tw:getSize()
                local group_h = sz.h + secondary_sz.h
                local text_y = row_y + math.floor((row_h - group_h) / 2)
                local text_x = mirrored
                    and list_x + content_w - row_pad - text_indent - leading_width - sz.w
                    or list_x + row_pad + text_indent + leading_width
                local secondary_x = mirrored
                    and list_x + content_w - row_pad - text_indent
                        - leading_width - secondary_sz.w
                    or list_x + row_pad + text_indent + leading_width
                tw:paintTo(bb, text_x, text_y)
                secondary_tw:paintTo(bb, secondary_x, text_y + sz.h)
                secondary_tw:free()
            else
                local text_x = mirrored
                    and list_x + content_w - row_pad - text_indent - leading_width - sz.w
                    or list_x + row_pad + text_indent + leading_width
                tw:paintTo(bb, text_x,
                    row_y + math.floor((row_h - sz.h) / 2))
            end
            if has_images and type(item.image_file) == "string"
                    and item.image_file ~= "" then
                local image = ImageWidget:new{
                    file = item.image_file,
                    file_do_cache = false,
                    width = image_w,
                    height = image_h,
                    scale_factor = 0,
                    original_in_nightmode = true,
                }
                local image_x = mirrored
                    and list_x + content_w - row_pad - image_w
                    or list_x + row_pad
                image:paintTo(bb, image_x,
                    row_y + math.floor((row_h - image_h) / 2))
                image:free()
            end
            tw:free()
            bb:paintRect(list_x, row_y + row_h - 1, content_w, 1, Blitbuffer.COLOR_LIGHT_GRAY)
        end

        if has_footer_buttons then
            local show_focus = not Device:isTouchDevice()
                or Device:hasDPad() or Device:hasKeyboard()
            for item_index = 1, footer_button_count do
                local item = footer_buttons[item_index]
                local rect = footer_button_rects[item_index]
                local filled = item.filled == true
                if show_focus and item_index == footer_selected_idx then filled = not filled end
                local max_text_width = math.max(1, rect.w - Screen:scaleBySize(12))
                if filled then
                    ZenButton.paintFilled(bb, rect.x, rect.y, rect.w, rect.h,
                        itemText(item), 16, Screen:scaleBySize(8), max_text_width)
                else
                    ZenButton.paintOutlined(bb, rect.x, rect.y, rect.w, rect.h,
                        itemText(item), 16, Screen:scaleBySize(8),
                        Screen:scaleBySize(1), max_text_width)
                end
            end
        else
            pager.paint(bb, content_x, bar_y, content_w, bar_area_h,
                cur_page, total_pages, "page_number", mirrored)
        end
    end

    dialog = Picker:new{}
    UIManager:show(dialog, "full")
    return dialog
end

return showMenuPicker
