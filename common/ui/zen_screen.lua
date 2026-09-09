-- common/zen_screen.lua
-- Fullscreen update / splash screen.
--
-- Shows the ZenOS logo centered with an optional title at the top and an
-- optional action button at the bottom. Tap or swipe anywhere to dismiss.
--
-- Usage:
--   local ZenScreen = require("common/zen_screen")
--   UIManager:show(ZenScreen:new{
--       title    = "ZenOS updated to v1.2.3",  -- nil hides the title bar
--       button   = "Get Started",               -- nil -> default label; false -> no button
--       on_close = function() ... end,
--   })

local InputContainer = require("ui/widget/container/inputcontainer")
local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local Input          = require("device/input")
local TextBoxWidget  = require("ui/widget/textboxwidget")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local ZenButton      = require("common/ui/zen_button")
local TitleStyle     = require("common/ui/zen_title_style")
local Screen         = Device.screen
local _              = require("gettext")
local ok_stw, ScrollTextWidget = pcall(require, "ui/widget/scrolltextwidget")

local logger           = require("common/zen_logger").new("zen_screen")
local ok_iw, ImageWidget = pcall(require, "ui/widget/imagewidget")
if not ok_iw then ImageWidget = nil end

local _plugin_root = require("common/plugin_root") or ""
local TITLE_FONT_SIZE = 28

local ZenScreen = InputContainer:extend{
    covers_fullscreen = true,
    title             = nil,   -- string shown in top bar; nil hides the title bar entirely
    title_icon        = false, -- force inline Zen icon to the left of title text
    hide_logo         = false, -- hide the large center logo while keeping the rest of the layout
    subtitle          = nil,   -- string rendered above the icon (e.g. "Updated to v1.2.3")
    changelog         = nil,   -- array of strings; when set, logo shrinks to make room for a bullet list
    scroll_text       = nil,   -- long-form changelog text rendered in a scrollable view
    button            = nil,   -- button label string; nil -> "Get Started"; false -> no button
    later_button      = nil,   -- optional outlined secondary button to the left; tapping closes
    on_close          = nil,
    dismissable       = true,  -- when false, swipe/tap-outside won't close the screen
    _on_button_action = nil,   -- if set, button tap calls this instead of onClose
}

function ZenScreen:_computeLayout()
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    local PAD        = Screen:scaleBySize(20)
    local TITLE_H    = self.title and TitleStyle.HEADER_CONTENT_HEIGHT or 0
    local SEP_H      = 0
    -- Subtitle band grows to fit wrapped text so long strings don't run off-page.
    local SUBTITLE_H = 0
    if self.subtitle then
        local box = TextBoxWidget:new{
            text      = self.subtitle,
            face      = Font:getFace("cfont", 22),
            width     = sw - PAD * 2,
            alignment = "center",
        }
        SUBTITLE_H = box:getSize().h + Screen:scaleBySize(12)
        box:free()
    end
    local BTN_H      = Screen:scaleBySize(80)
    self._L = {
        sw         = sw,
        sh         = sh,
        pad        = PAD,
        title_h    = TITLE_H,
        sep_h      = SEP_H,
        subtitle_h = SUBTITLE_H,
        btn_h      = BTN_H,
        -- Content area starts below subtitle, ends above button bar.
        content_y  = TITLE_H + SEP_H + SUBTITLE_H,
        content_h  = sh - TITLE_H - SEP_H - SUBTITLE_H - BTN_H,
        btn_y      = sh - BTN_H,
    }
end

function ZenScreen:_normalizeButtonFocus()
    if self._button_focus == "primary" and self.button ~= false then return end
    if self._button_focus == "later" and self.later_button then return end
    self._button_focus = self.button ~= false and "primary"
        or (self.later_button and "later" or nil)
end

function ZenScreen:_moveButtonFocus()
    self:_normalizeButtonFocus()
    if not self._button_focus then return true end
    local next_button = self._button_focus
    if self.button ~= false and self.later_button then
        next_button = self._button_focus == "primary" and "later" or "primary"
    end
    local needs_repaint = not self._button_focus_visible or next_button ~= self._button_focus
    self._button_focus = next_button
    self._button_focus_visible = true
    if needs_repaint then
        UIManager:setDirty(self, function() return "fast", self.dimen end)
    end
    return true
end

function ZenScreen:_activateButton(button)
    if button == "later" and self.later_button then
        self:onClose()
    elseif button == "primary" and self.button ~= false then
        if self._on_button_action then
            self._on_button_action()
        else
            self:onClose()
        end
    elseif self.dismissable then
        self:onClose()
    end
    return true
end

function ZenScreen:init()
    logger.info("init title=", self.title)
    local sw = Screen:getWidth()
    local sh = Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = sw, h = sh }
    self:_computeLayout()
    self._btn_rect = nil
    self._scroll_text_w = nil
    self._scroll_rect = nil
    self._scroll_text_cache = nil
    self._scroll_w = nil
    self._scroll_h = nil
    self._scroll_top_line_num = nil
    self._button_focus_visible = Device:hasDPad() and not Device:isTouchDevice()
    self:_normalizeButtonFocus()

    self:registerTouchZones({
        {
            id          = "zs_swipe",
            ges         = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler     = function(ges) return self:_onSwipe(ges) end,
        },
        {
            id          = "zs_tap",
            ges         = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler     = function(ges) return self:_onTap(ges) end,
        },
    })

    -- Physical key bindings (only registered when device has keys)
    if Device:hasKeys() then
        self.key_events = {
            ZsConfirm = {
                { "Press" },
                event = "ZsConfirm",
            },
            ZsConfirmPgFwd = {
                { Input.group.PgFwd },
                event = "ZsPrimary",
            },
            ZsDismiss = {
                { Input.group.PgBack },
                event = "ZsDismiss",
            },
            ZsCancelOrClose = {
                { Input.group.Back },
                { "Home" },
                event = "ZsCancelOrClose",
            },
            ZsFocusNext = {
                { "Right" },
                { "Tab" },
                event = "ZsFocusNext",
            },
            ZsFocusPrevious = {
                { "Left" },
                { "Shift", "Tab" },
                event = "ZsFocusPrevious",
            },
        }
    end
end

function ZenScreen:_free_scroll_widget()
    if self._scroll_text_w and type(self._scroll_text_w.free) == "function" then
        pcall(self._scroll_text_w.free, self._scroll_text_w, false)
    end
    self._scroll_text_w = nil
    self._scroll_text_cache = nil
    self._scroll_w = nil
    self._scroll_h = nil
end

function ZenScreen:_ensure_scroll_widget(width, height)
    if not ok_stw then return end
    local text = type(self.scroll_text) == "string" and self.scroll_text or ""
    if text == "" then
        self:_free_scroll_widget()
        return
    end
    local needs_new = self._scroll_text_w == nil
        or self._scroll_text_cache ~= text
        or self._scroll_w ~= width
        or self._scroll_h ~= height
    if not needs_new then return end
    self:_free_scroll_widget()
    self._scroll_text_cache = text
    self._scroll_w = width
    self._scroll_h = height
    self._scroll_text_w = ScrollTextWidget:new{
        text      = text,
        top_line_num = self._scroll_top_line_num,
        face      = Font:getFace("cfont", 17),
        fgcolor   = Blitbuffer.COLOR_BLACK,
        width     = width,
        height    = height,
        dialog    = self,
        alignment = "left",
        justified = false,
        -- onShow owns the initial refresh.
        for_measurement_only = true,
        updateScrollBar = function(widget, is_partial)
            if not Device.hasColorScreen or not Device:hasColorScreen() then
                return ScrollTextWidget.updateScrollBar(widget, is_partial)
            end
            local for_measurement_only = widget.for_measurement_only
            widget.for_measurement_only = true
            ScrollTextWidget.updateScrollBar(widget, is_partial)
            widget.for_measurement_only = for_measurement_only
            if not for_measurement_only then
                UIManager:setDirty(self, function() return "fast", self.dimen end)
            end
        end,
    }
    self._scroll_text_w.for_measurement_only = false
    self._scroll_text_w.text_widget.for_measurement_only = false
    self._scroll_top_line_num = nil
end

function ZenScreen:_point_in_rect(point, rect)
    return rect
        and point.x >= rect.x and point.x < rect.x + rect.w
        and point.y >= rect.y and point.y < rect.y + rect.h
end

-- Enter: activate the focused button (or dismiss if there are no buttons).
function ZenScreen:onZsConfirm()
    self:_normalizeButtonFocus()
    return self:_activateButton(self._button_focus)
end

-- PgFwd retains its existing primary-action shortcut.
function ZenScreen:onZsPrimary()
    return self:_activateButton("primary")
end

-- PgBack: activate "Later" / dismiss
function ZenScreen:onZsDismiss()
    if self.dismissable then
        self:onClose()
    end
    return true
end

function ZenScreen:onZsCancelOrClose()
    if self.dismissable then
        self:onClose()
    elseif self.button ~= false then
        self:_activateButton("primary")
    end
    return true
end

function ZenScreen:onZsFocusNext()
    return self:_moveButtonFocus()
end

function ZenScreen:onZsFocusPrevious()
    return self:_moveButtonFocus()
end

function ZenScreen:paintTo(bb, x, y)
    local L = self._L

    -- Measure changelog first so we know if the title bar needs an inline icon.
    local content_y = y + L.content_y
    local content_h = L.content_h
    local cl_x      = x + L.pad
    local cl_w      = L.sw - L.pad * 2
    local SEP_PX    = Screen:scaleBySize(8)
    local HDR_GAP   = Screen:scaleBySize(6)
    local ITEM_GAP  = Screen:scaleBySize(4)
    local MIN_LOGO  = Screen:scaleBySize(140)
    local MAX_LOGO  = math.floor(math.min(L.sw, L.sh) * 0.55)

    local item_widgets = {}
    local hdr_tw, hdr_h
    local logo_h = self.hide_logo and 0 or content_h

    -- Measure the changelog array (when present) to decide between the
    -- logo+bullets layout and the scrollable fallback. The bullets fit
    -- alongside a large centered logo only if the leftover logo space stays
    -- above MIN_LOGO; otherwise we fall back to the scroll view.
    local fits_with_logo = false
    local candidate_logo_h = logo_h
    if self.changelog and #self.changelog > 0 then
        hdr_tw = TextWidget:new{
            text    = _("What's New"),
            face    = Font:getFace("cfont", 18),
            bold    = true,
            padding = 0,
        }
        hdr_h = hdr_tw:getSize().h

        local items_h = 0
        for _i, item in ipairs(self.changelog) do
            local b_tw = TextBoxWidget:new{
                text      = "\u{2022} " .. item,
                face      = Font:getFace("cfont", 17),
                width     = cl_w,
                alignment = "left",
            }
            local bh = b_tw:getSize().h
            table.insert(item_widgets, { widget = b_tw, h = bh })
            items_h = items_h + bh + ITEM_GAP
        end

        local cl_total = 1 + SEP_PX + hdr_h + HDR_GAP + items_h + SEP_PX
        candidate_logo_h = self.hide_logo and 0 or math.max(0, content_h - cl_total)
        local logo_candidate = math.floor(math.min(L.sw - L.pad * 2, candidate_logo_h - L.pad * 2))
        fits_with_logo = self.hide_logo or logo_candidate >= MIN_LOGO
    end

    -- Scroll view kicks in only when an explicit scroll_text was supplied and
    -- the changelog won't fit beside the logo. Without scroll_text we keep the
    -- legacy behavior: drop the big logo and let the bullets fill the content.
    local has_scroll = type(self.scroll_text) == "string" and self.scroll_text ~= ""
    local use_scroll_text = has_scroll and (hdr_tw == nil or not fits_with_logo)

    self._show_title_icon = false
    if use_scroll_text then
        -- Discard the measured bullet widgets; the scroll view renders instead.
        for _i, entry in ipairs(item_widgets) do entry.widget:free() end
        item_widgets = {}
        if hdr_tw then hdr_tw:free(); hdr_tw = nil end
        logo_h = 0
        self._show_title_icon = true  -- big logo hidden, brand via title bar
    elseif hdr_tw ~= nil then
        logo_h = candidate_logo_h
        if not fits_with_logo then
            -- No scroll fallback available: hide big logo, brand via title bar.
            logo_h = 0
            self._show_title_icon = true
        end
    end

    local has_cl = hdr_tw ~= nil

    bb:paintRect(x, y, L.sw, L.sh, Blitbuffer.COLOR_WHITE)

    -- Title bar. When the logo is hidden by a long changelog, render a small
    -- inline icon to the left of the title at text-height so it adds no height.
    if self.title and L.title_h > 0 then
        local tw = TextWidget:new{
            text    = self.title,
            face    = Font:getFace("cfont", TITLE_FONT_SIZE),
            bold    = true,
            padding = 0,
        }
        local tsz = tw:getSize()
        local show_inline_icon = self.title_icon == true or self._show_title_icon
        local icon_gap = TitleStyle.TITLE_LEADING_PADDING
        local icon_sz  = show_inline_icon and TitleStyle.ICON_SIZE or 0
        local total_w  = tsz.w + (show_inline_icon and (icon_sz + icon_gap) or 0)
        local base_x   = x + math.floor((L.sw - total_w) / 2)
        local text_y   = y + TitleStyle.VERTICAL_PADDING
            + math.floor((TitleStyle.ROW_HEIGHT - tsz.h) / 2)
        local icon_y   = y + TitleStyle.VERTICAL_PADDING
            + math.floor((TitleStyle.ROW_HEIGHT - icon_sz) / 2)

        if show_inline_icon and ImageWidget and _plugin_root ~= "" then
            pcall(function()
                local iw = ImageWidget:new{
                    file   = _plugin_root .. "/icons/zen_ui.svg",
                    width  = icon_sz,
                    height = icon_sz,
                    alpha  = true,
                }
                iw:paintTo(bb, base_x, icon_y)
                iw:free()
                if Screen.night_mode then
                    bb:invertRect(base_x, icon_y, icon_sz, icon_sz)
                end
            end)
        end

        tw:paintTo(bb, base_x + (show_inline_icon and (icon_sz + icon_gap) or 0), text_y)
        tw:free()
    end

    -- Subtitle above icon (wraps to fit width so long strings don't run off-page).
    if self.subtitle and L.subtitle_h > 0 then
        local sub_y = y + L.title_h + L.sep_h
        local sw2 = TextBoxWidget:new{
            text      = self.subtitle,
            face      = Font:getFace("cfont", 22),
            width     = L.sw - L.pad * 2,
            alignment = "center",
        }
        local ssz = sw2:getSize()
        sw2:paintTo(bb,
            x + L.pad,
            sub_y + math.floor((L.subtitle_h - ssz.h) / 2))
        sw2:free()
    end

    -- Logo (hidden when changelog consumes too much space).
    if not use_scroll_text and not self.hide_logo and ImageWidget and _plugin_root ~= "" then
        local logo    = _plugin_root .. "/icons/zen_ui.svg"
        local available_logo_sz = has_cl
            and math.floor(math.min(L.sw - L.pad * 2, logo_h - L.pad * 2))
            or  math.floor(math.min(L.sw - L.pad * 4, logo_h - L.pad * 4) * 0.75)
        local logo_sz = math.min(available_logo_sz, MAX_LOGO)
        if logo_sz > 0 then
            pcall(function()
                local iw = ImageWidget:new{
                    file   = logo,
                    width  = logo_sz,
                    height = logo_sz,
                    alpha  = true,
                }
                local isz = iw:getSize()
                local lx = x + math.floor((L.sw - isz.w) / 2)
                local ly = content_y + math.floor((logo_h - isz.h) / 2)
                iw:paintTo(bb, lx, ly)
                iw:free()
                if Screen.night_mode then
                    bb:invertRect(lx, ly, isz.w, isz.h)
                end
            end)
        end
    end

    -- Paint changelog below the logo region.
    if hdr_tw then
        local cl_y = content_y + logo_h
        bb:paintRect(x + L.pad, cl_y, cl_w, 1, Blitbuffer.COLOR_LIGHT_GRAY)
        cl_y = cl_y + 1 + SEP_PX
        hdr_tw:paintTo(bb, cl_x, cl_y)
        hdr_tw:free()
        cl_y = cl_y + hdr_h + HDR_GAP
        for _i, entry in ipairs(item_widgets) do
            entry.widget:paintTo(bb, cl_x, cl_y)
            entry.widget:free()
            cl_y = cl_y + entry.h + ITEM_GAP
        end
    else
        for _i, entry in ipairs(item_widgets) do entry.widget:free() end
    end

    self._scroll_rect = nil
    if use_scroll_text then
        local scroll_pad = Screen:scaleBySize(4)
        local scroll_x = x + L.pad
        local scroll_y = content_y + scroll_pad
        local scroll_w = cl_w
        local scroll_h = math.max(Screen:scaleBySize(40), content_h - scroll_pad * 2)
        self:_ensure_scroll_widget(scroll_w, scroll_h)
        if self._scroll_text_w then
            self._scroll_text_w:paintTo(bb, scroll_x, scroll_y)
            self._scroll_rect = {
                x = scroll_x,
                y = scroll_y,
                w = scroll_w,
                h = scroll_h,
            }
        end
    end

    -- Button(s)
    self._btn_rect       = nil
    self._later_btn_rect = nil
    if (self.button ~= false or self.later_button) and L.btn_h > 0 then
        local btn_h    = Screen:scaleBySize(54)
        local corner_r = Screen:scaleBySize(10)
        local btn_y    = y + L.btn_y + math.floor((L.btn_h - btn_h) / 2)

        if self.button == false and self.later_button then
            -- Later-only: single centered outlined button.
            local bw        = Screen:scaleBySize(2)
            local btn_w     = Screen:scaleBySize(240)
            local btn_x     = x + math.floor((L.sw - btn_w) / 2)
            local later_lbl = (type(self.later_button) == "string" and self.later_button ~= "")
                and self.later_button or _("Later")
            self._later_btn_rect = ZenButton.paintOutlined(
                bb, btn_x, btn_y, btn_w, btn_h, later_lbl, 22, corner_r, bw)
        elseif self.later_button then
            -- Two buttons: outlined "Later" left, filled primary right.
            local gap    = Screen:scaleBySize(16)
            local btn_w  = Screen:scaleBySize(200)
            local base_x = x + math.floor((L.sw - btn_w * 2 - gap) / 2)
            local bw     = Screen:scaleBySize(2)  -- outline border thickness

            -- Outlined Later button
            local lbx       = base_x
            local later_lbl = (type(self.later_button) == "string" and self.later_button ~= "")
                and self.later_button or _("Later")
            self._later_btn_rect = ZenButton.paintOutlined(
                bb, lbx, btn_y, btn_w, btn_h, later_lbl, 22, corner_r, bw)

            -- Filled primary button
            local pbx      = base_x + btn_w + gap
            local prim_lbl = (type(self.button) == "string" and self.button ~= "")
                and self.button or _("Get Started")
            self._btn_rect = ZenButton.paintFilled(
                bb, pbx, btn_y, btn_w, btn_h, prim_lbl, 22, corner_r)
        else
            -- Single centered filled button.
            local lbl   = (type(self.button) == "string" and self.button ~= "")
                and self.button or _("Get Started")
            local btn_w = Screen:scaleBySize(240)
            local btn_x = x + math.floor((L.sw - btn_w) / 2)
            self._btn_rect = ZenButton.paintFilled(
                bb, btn_x, btn_y, btn_w, btn_h, lbl, 22, corner_r)
        end
    end
    self:_normalizeButtonFocus()
    if self._button_focus_visible then
        local focus_rect = self._button_focus == "later"
            and self._later_btn_rect or self._btn_rect
        if focus_rect then
            bb:invertRect(focus_rect.x, focus_rect.y, focus_rect.w, focus_rect.h)
        end
    end
end

function ZenScreen:_onSwipe(ges)
    if self._scroll_text_w and self:_point_in_rect(ges.pos, self._scroll_rect) then
        self._scroll_text_w:onScrollText(nil, ges)
        return true
    end
    if self.dismissable then self:onClose() end
    return true
end

function ZenScreen:_onTap(ges)
    local p  = ges.pos
    local L  = self._L
    local br = self._btn_rect
    local lr = self._later_btn_rect

    -- Later button: always dismisses
    if lr and p.x >= lr.x and p.x < lr.x + lr.w
           and p.y >= lr.y and p.y < lr.y + lr.h then
        return self:_activateButton("later")
    end

    -- Primary button: call action override if set, otherwise close
    if br and p.x >= br.x and p.x < br.x + br.w
           and p.y >= br.y and p.y < br.y + br.h then
        return self:_activateButton("primary")
    end

    if self._scroll_text_w and self:_point_in_rect(p, self._scroll_rect) then
        self._scroll_text_w:onTapScrollText(nil, ges)
        return true
    end

    -- Bottom nav area: only close if dismissable
    if L.btn_h > 0 and p.y >= L.btn_y then
        if self.dismissable then self:onClose() end
        return true
    end

    return true
end

--- Mutate subtitle/button/later_button/dismissable and repaint without closing/reopening.
function ZenScreen:update(opts)
    local text_changed = false
    if opts.subtitle ~= nil then self.subtitle = opts.subtitle end
    if opts.title ~= nil then self.title = opts.title end
    if opts.title_icon ~= nil then self.title_icon = opts.title_icon end
    if opts.hide_logo ~= nil then self.hide_logo = opts.hide_logo end
    if opts.changelog ~= nil then self.changelog = opts.changelog end
    if opts.scroll_text ~= nil then
        self.scroll_text = opts.scroll_text
        text_changed = true
    end
    if opts.button ~= nil then self.button = opts.button end
    if opts.later_button ~= nil then self.later_button = opts.later_button end
    if opts.dismissable ~= nil then self.dismissable = opts.dismissable end
    if opts.on_button ~= nil then self._on_button_action = opts.on_button end
    self:_normalizeButtonFocus()
    if text_changed then
        if opts.preserve_scroll and self._scroll_text_w
            and self._scroll_text_w.text_widget
            and self._scroll_text_w.text_widget.virtual_line_num then
            self._scroll_top_line_num = self._scroll_text_w.text_widget.virtual_line_num
        else
            self._scroll_top_line_num = nil
        end
        self:_free_scroll_widget()
    end
    self:_computeLayout()
    UIManager:setDirty(self, function()
        return "partial", self.dimen
    end)
end

function ZenScreen:onShow()
    logger.info("onShow dimen=", self.dimen)
    UIManager:setDirty(self, function()
        return "flashui", self.dimen
    end)
end

function ZenScreen:onClose()
    self:_free_scroll_widget()
    UIManager:setDirty(nil, "full")
    UIManager:close(self)
    -- Block filebrowser taps briefly so the dismiss gesture doesn't open a file.
    _G.__ZEN_QUICKSTART_JUST_CLOSED = true
    UIManager:scheduleIn(1.5, function() _G.__ZEN_QUICKSTART_JUST_CLOSED = nil end)
    package.loaded["common/zen_screen"] = nil
    if self.on_close then
        self.on_close()
    end
end

return ZenScreen
