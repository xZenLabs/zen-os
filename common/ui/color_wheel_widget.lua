-- Adapted from appearance.koplugin colorwheelwidget.lua (GPL-3.0).
-- Source revision: 9f180d842d7055a3821bbf141ab3e0fd6da73fd8
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ReaderThemes = require("common/reader_themes")
local ZenButton = require("common/ui/zen_button")
local SolidCircle = require("common/ui/zen_solid_circle")
local ZenSlider = require("common/ui/zen_slider")
local Font = require("ui/font")
local _ = require("gettext")
local Screen = Device.screen

local ColorWheelWidget = FocusManager:extend {
    covers_fullscreen    = true,
    is_borderless        = true,
    title_text           = _("Color picker"),
    width                = nil,
    width_factor         = 0.6,

    hue                  = 0, -- 0..360
    saturation           = 1,
    value                = 1,

    invert_in_night_mode = true,

    draw_scale           = 0.5,

    ok_text              = _("Apply"),

    callback             = nil,
    cancel_callback      = nil,
    close_callback       = nil,
}

local function hsvToRgb(h, s, v)
    local c = v * s
    local x = c * (1 - math.abs((h / 60) % 2 - 1))
    local m = v - c
    local r, g, b
    if h < 60 then
        r, g, b = c, x, 0
    elseif h < 120 then
        r, g, b = x, c, 0
    elseif h < 180 then
        r, g, b = 0, c, x
    elseif h < 240 then
        r, g, b = 0, x, c
    elseif h < 300 then
        r, g, b = x, 0, c
    else
        r, g, b = c, 0, x
    end
    return
        math.floor((r + m) * 255 + 0.5),
        math.floor((g + m) * 255 + 0.5),
        math.floor((b + m) * 255 + 0.5)
end

local _wheel_cache      = {}
local _wheel_cache_keys = {} -- insertion-order list for LRU eviction
local MAX_CACHE_ENTRIES = 8

local function getWheelCache(draw_radius)
    if _wheel_cache[draw_radius] then
        return _wheel_cache[draw_radius]
    end

    if #_wheel_cache_keys >= MAX_CACHE_ENTRIES then
        local oldest = table.remove(_wheel_cache_keys, 1)
        _wheel_cache[oldest] = nil
    end

    local r2    = draw_radius * draw_radius
    local hue_t = {}
    local sat_t = {}
    local idx   = 0

    for py = -draw_radius, draw_radius do
        for px = -draw_radius, draw_radius do
            idx = idx + 1
            local dist2 = px * px + py * py
            if dist2 <= r2 then
                hue_t[idx] = (math.deg(math.atan2(py, px)) + 360) % 360
                sat_t[idx] = math.sqrt(dist2) / draw_radius
            else
                sat_t[idx] = -1
            end
        end
    end

    local cache = { hue = hue_t, sat = sat_t }
    _wheel_cache[draw_radius] = cache
    table.insert(_wheel_cache_keys, draw_radius)
    return cache
end

local ColorWheel = WidgetContainer:extend {
    radius               = 0,
    hue                  = 0,
    saturation           = 1,
    value                = 1,
    invert_in_night_mode = true,
    draw_scale           = 0.5,
    _needs_redraw        = true,
    _last_val            = nil,
    _cached_buf          = nil,
}

function ColorWheel:init()
    self.radius      = math.floor(self.dimen.w / 2)
    self.dimen       = Geom:new { x = 0, y = 0, w = self.dimen.w, h = self.dimen.h }
    self.night_mode  = self.invert_in_night_mode and Screen.night_mode
    self.draw_radius = math.max(1, math.floor(self.radius * self.draw_scale))
    getWheelCache(self.draw_radius)
    self._needs_redraw = true
end

function ColorWheel:free()
    if self._cached_buf then
        self._cached_buf:free()
        self._cached_buf = nil
    end
end

function ColorWheel:_renderToBuffer(x, y)
    local dr      = self.draw_radius
    local side    = dr * 2 + 1
    local buf     = Blitbuffer.new(side, side, Blitbuffer.TYPE_BBRGB32)
    local bgcolor = Screen.bb:getPixel(x - 1, y - 1)
    buf:paintRectRGB32(0, 0, side, side, bgcolor)

    local cache       = getWheelCache(dr)
    local hue_t       = cache.hue
    local sat_t       = cache.sat
    local v           = self.value
    local nm          = self.night_mode
    local idx         = 0

    local bordercolor = Blitbuffer.COLOR_BLACK
    for py = -dr, dr do
        for px = -dr, dr do
            idx = idx + 1
            local s = sat_t[idx]
            if s >= 0 then
                if sat_t[idx] >= 1 - Size.border.window / dr then
                    buf:setPixel(dr + 1 + px, dr + 1 + py, bordercolor)
                else -- Draw colors
                    local r, g, b = hsvToRgb(hue_t[idx], s, v)
                    if nm then r, g, b = 255 - r, 255 - g, 255 - b end
                    buf:setPixel(dr + 1 + px, dr + 1 + py,
                        Blitbuffer.ColorRGB32(r, g, b, 0xFF))
                end
            end
        end
    end

    if self._cached_buf then
        self._cached_buf:free()
    end
    self._cached_buf   = buf
    self._last_val     = v
    self._needs_redraw = false
end

function ColorWheel:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y

    if self._needs_redraw or self._last_val ~= self.value then
        self:_renderToBuffer(x, y)
    end

    local disp_side = self.radius * 2

    if self.draw_scale < 1.0 then
        local scaled = self._cached_buf:scale(disp_side, disp_side)
        bb:blitFrom(scaled, x, y, 0, 0, disp_side, disp_side)
        scaled:free()
    else
        bb:blitFrom(self._cached_buf, x, y, 0, 0, disp_side, disp_side)
    end

    local cx    = x + self.radius
    local cy    = y + self.radius
    local sel_x = cx + math.floor(math.cos(math.rad(self.hue)) * self.saturation * self.radius + 0.5)
    local sel_y = cy + math.floor(math.sin(math.rad(self.hue)) * self.saturation * self.radius + 0.5)

    local outer_radius = Screen:scaleBySize(6)
    local inner_radius = Screen:scaleBySize(4)
    for py = -outer_radius, outer_radius do
        for px = -outer_radius, outer_radius do
            local d = px * px + py * py
            if d <= outer_radius * outer_radius then
                bb:setPixelClamped(sel_x + px, sel_y + py, Blitbuffer.COLOR_WHITE)
            end
            if d <= inner_radius * inner_radius then
                bb:setPixelClamped(sel_x + px, sel_y + py, Blitbuffer.COLOR_BLACK)
            end
        end
    end
end

function ColorWheel:updateColor(ges_pos)
    if not self.dimen then return false end

    local cx    = self.dimen.x + self.radius
    local cy    = self.dimen.y + self.radius
    local dx    = ges_pos.x - cx
    local dy    = ges_pos.y - cy
    local dist2 = dx * dx + dy * dy

    if dist2 > self.radius * self.radius then return false end

    self.hue        = (math.deg(math.atan2(dy, dx)) + 360) % 360
    self.saturation = math.min(1, math.sqrt(dist2) / self.radius)

    if self.update_callback then
        self.update_callback()
    end
    return true
end

local function makeLivePreview(parent, preview_size)
    local LivePreview = SolidCircle:extend {
        width = preview_size,
        height = preview_size,
        bordersize = Size.border.thick,
    }
    function LivePreview:paintTo(bb, x, y)
        local r, g, b = hsvToRgb(parent.hue, parent.saturation, parent.value)
        local nm = parent.invert_in_night_mode
            and G_reader_settings:isTrue("night_mode")
        if nm then r, g, b = 255 - r, 255 - g, 255 - b end
        self.background = Blitbuffer.ColorRGB32(r, g, b, 0xFF)
        SolidCircle.paintTo(self, bb, x, y)
    end

    return LivePreview:new {}
end

local function makeLiveHexLabel(parent, face)
    local sample = TextWidget:new { text = "#FFFFFF", face = face }
    local size = sample:getSize()
    sample:free()
    local LiveHex = WidgetContainer:extend {
        dimen = Geom:new {
            w = math.max(Screen:scaleBySize(160), size.w + Screen:scaleBySize(32)),
            h = size.h,
        },
        _last_text = "",
        _tw = nil,
    }
    function LiveHex:paintTo(bb, x, y)
        local r, g, b = hsvToRgb(parent.hue, parent.saturation, parent.value)
        local txt = string.format("#%02X%02X%02X", r, g, b)
        if txt ~= self._last_text or not self._tw then
            if self._tw then self._tw:free() end
            self._tw = TextWidget:new { text = txt, face = face }
            self._last_text = txt
        end
        local text_size = self._tw:getSize()
        self._tw:paintTo(bb, x + math.floor((self.dimen.w - text_size.w) / 2), y)
    end
    function LiveHex:free()
        if self._tw then
            self._tw:free()
            self._tw = nil
        end
    end

    return LiveHex:new {}
end

function ColorWheelWidget:init()
    self.screen_width     = Screen:getWidth()
    self.screen_height    = Screen:getHeight()
    self.medium_font_face = Font:getFace("ffont")
    self.hex_font_face    = Font:getFace("infofont", 20)
    self.dimen            = Geom:new {
        x = 0, y = 0, w = self.screen_width, h = self.screen_height,
    }

    local hue, saturation, value = ReaderThemes.colorToHsv(self.hex)
    if hue then
        self.hue, self.saturation, self.value = hue, saturation, value
    end

    if not self.width then
        self.width = math.floor(
            math.min(self.screen_width, self.screen_height) * self.width_factor
        )
    end

    if Device:isTouchDevice() then
        self.ges_events = {
            TapColorWheel = {
                GestureRange:new {
                    ges   = "tap",
                    range = Geom:new { x = 0, y = 0,
                        w = self.screen_width, h = self.screen_height }
                }
            },
            PanColorWheel = {
                GestureRange:new {
                    ges   = "pan",
                    range = Geom:new { x = 0, y = 0,
                        w = self.screen_width, h = self.screen_height }
                }
            },
            PanReleaseColorWheel = {
                GestureRange:new {
                    ges   = "pan_release",
                    range = Geom:new { x = 0, y = 0,
                        w = self.screen_width, h = self.screen_height }
                }
            },
            SwipeColorWheel = {
                GestureRange:new {
                    ges   = "swipe",
                    range = Geom:new { x = 0, y = 0,
                        w = self.screen_width, h = self.screen_height }
                }
            },
        }
    end
    if Device:hasKeys() then
        self.key_events.CancelOrClose = { { Device.input.group.Back } }
    end

    self:update()
end

function ColorWheelWidget:_freeChildren()
    if self[1] then
        self[1]:free()
        self[1] = nil
    else
        if self.color_wheel then self.color_wheel:free() end
        if self._live_hex then self._live_hex:free() end
    end
    self.color_wheel = nil
    self._live_hex = nil
    self._hex_frame = nil
    self.brightness_slider = nil
end

function ColorWheelWidget:onCloseWidget()
    self:_freeChildren()
end

function ColorWheelWidget:setHex(hex)
    local hue, saturation, value = ReaderThemes.colorToHsv(hex)
    if not hue then return false end
    self.hue, self.saturation, self.value = hue, saturation, value
    self:update()
    return true
end

function ColorWheelWidget:showHexInput()
    local InputDialog = require("ui/widget/inputdialog")
    local r, g, b = hsvToRgb(self.hue, self.saturation, self.value)
    local dlg
    dlg = InputDialog:new {
        title = self.title_text,
        input = string.format("#%02X%02X%02X", r, g, b),
        input_hint = "#ffffff",
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dlg) end,
            },
            {
                text = _("Set"),
                is_enter_default = true,
                callback = function()
                    if not self:setHex(dlg:getInputText()) then return end
                    UIManager:close(dlg)
                end,
            },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function ColorWheelWidget:update()
    self:_freeChildren()

    local pad = Size.padding.large
    local small_gap = Screen:scaleBySize(8)
    local title_bar = TitleBar:new {
        width            = self.screen_width,
        title            = self.title_text,
        with_bottom_line = true,
        close_button     = true,
        close_callback   = function() self:onCancel() end,
        show_parent      = self,
    }

    local value_label = TextWidget:new {
        text = _("Brightness") .. ": " .. math.floor(self.value * 100 + 0.5) .. "%",
        face = self.medium_font_face,
    }
    local button_width = Screen:scaleBySize(44)
    local slider_width = math.max(1, self.width - 2 * button_width - 4 * small_gap)
    local brightness_slider = ZenSlider:new {
        width     = slider_width,
        value     = math.floor(self.value * 100 + 0.5),
        value_min = 0,
        value_max = 100,
    }
    local apply_height = Size.item.height_large
    local fixed_height = title_bar:getSize().h + value_label:getSize().h
        + brightness_slider:getSize().h + apply_height + 4 * pad
        + small_gap + Size.padding.default
    local wheel_size = math.min(self.width - 2 * pad,
        math.max(Screen:scaleBySize(80), math.floor((self.screen_height - fixed_height) / 1.25)))
    local preview_size = math.floor(wheel_size / 6)

    self.color_wheel    = ColorWheel:new {
        dimen                = Geom:new { w = wheel_size, h = wheel_size },
        hue                  = self.hue,
        saturation           = self.saturation,
        value                = self.value,
        invert_in_night_mode = self.invert_in_night_mode,
        draw_scale           = self.draw_scale,
    }

    self._live_preview  = makeLivePreview(self, preview_size)
    self._live_hex      = makeLiveHexLabel(self, self.hex_font_face)
    self._hex_frame     = FrameContainer:new {
        bordersize = Size.border.button,
        radius     = Size.radius.button,
        margin     = 0,
        padding    = Size.padding.button,
        self._live_hex,
    }
    local function set_brightness(value)
        brightness_slider:setValue(value)
        self.value = brightness_slider:getValue() / 100
        self.color_wheel.value = self.value
        self.color_wheel._needs_redraw = true
        value_label:setText(_("Brightness") .. ": " .. brightness_slider:getValue() .. "%")
        UIManager:setDirty(self, "ui")
    end
    brightness_slider.on_change = set_brightness

    local value_minus = Button:new {
        text           = "−",
        text_font_face = "infofont",
        text_font_size = 22,
        text_font_bold = false,
        width          = button_width,
        height         = brightness_slider:getSize().h,
        bordersize     = 0,
        show_parent    = self,
        callback       = function() set_brightness(brightness_slider:getValue() - 1) end,
    }

    local value_plus = Button:new {
        text           = "＋",
        text_font_face = "infofont",
        text_font_size = 22,
        text_font_bold = false,
        width          = button_width,
        height         = brightness_slider:getSize().h,
        bordersize     = 0,
        show_parent    = self,
        callback       = function() set_brightness(brightness_slider:getValue() + 1) end,
    }

    local slider_group = HorizontalGroup:new {
        align = "center",
        value_minus,
        HorizontalSpan:new { width = small_gap },
        brightness_slider,
        HorizontalSpan:new { width = small_gap },
        value_plus,
    }

    local preview_group = HorizontalGroup:new {
        align = "center",
        self._live_preview,
        HorizontalSpan:new { width = Size.padding.large },
        self._hex_frame,
    }
    local ok_button = Button:new {
        text        = self.ok_text,
        width       = self.width - 2 * pad,
        height      = apply_height,
        bordersize  = 0,
        padding     = 0,
        show_parent = self,
        callback    = function() self:onApply() end,
    }
    ok_button.paintTo = function(button, bb, x, y)
        button.dimen.x, button.dimen.y = x, y
        ZenButton.paintFilled(bb, x, y, button.dimen.w, button.dimen.h,
            button.text, button.text_font_size)
    end
    ok_button._doFeedbackHighlight = function() end
    ok_button._undoFeedbackHighlight = function() end

    self.brightness_slider = brightness_slider
    self.layout = { { value_minus, value_plus }, { ok_button } }

    local vgroup = VerticalGroup:new {
        align = "center",
        title_bar,
        VerticalSpan:new { width = pad },
        CenterContainer:new {
            dimen = Geom:new {
                w = self.screen_width,
                h = value_label:getSize().h,
            },
            value_label,
        },
        VerticalSpan:new { width = small_gap },
        CenterContainer:new {
            dimen = Geom:new {
                w = self.screen_width,
                h = brightness_slider:getSize().h,
            },
            slider_group,
        },
        VerticalSpan:new { width = pad },
        CenterContainer:new {
            dimen = Geom:new {
                w = self.screen_width,
                h = wheel_size,
            },
            self.color_wheel,
        },
        VerticalSpan:new { width = pad },
        CenterContainer:new {
            dimen = Geom:new {
                w = self.screen_width,
                h = preview_size,
            },
            preview_group,
        },
        VerticalSpan:new { width = pad },
        CenterContainer:new {
            dimen = Geom:new { w = self.screen_width, h = apply_height },
            ok_button,
        },
        VerticalSpan:new { width = Size.padding.default },
    }

    self[1] = vgroup

    UIManager:setDirty(self, "ui")
end

function ColorWheelWidget:paintTo(bb, x, y)
    bb:paintRect(x, y, self.screen_width, self.screen_height, Blitbuffer.COLOR_WHITE)
    FocusManager.paintTo(self, bb, x, y)
end

function ColorWheelWidget:onTapColorWheel(arg, ges_ev)
    if self._hex_frame and self._hex_frame.dimen
            and ges_ev.pos:intersectWith(self._hex_frame.dimen) then
        self:showHexInput()
        return true
    end
    if self.brightness_slider and self.brightness_slider:handleTap(ges_ev) then
        return true
    end
    if not self.color_wheel or not self.color_wheel.dimen then return true end

    if ges_ev.pos:intersectWith(self.color_wheel.dimen) then
        if self.color_wheel:updateColor(ges_ev.pos) then
            self.hue        = self.color_wheel.hue
            self.saturation = self.color_wheel.saturation
            UIManager:setDirty(self, "ui")
        end
        return true
    end
    return true
end

function ColorWheelWidget:onPanColorWheel(arg, ges_ev)
    if self.brightness_slider and self.brightness_slider:handlePan(ges_ev) then
        return true
    end
    if not self.color_wheel or not self.color_wheel.dimen then return false end

    if ges_ev.pos:intersectWith(self.color_wheel.dimen) then
        if self.color_wheel:updateColor(ges_ev.pos) then
            self.hue        = self.color_wheel.hue
            self.saturation = self.color_wheel.saturation

            self._pan_tick  = (self._pan_tick or 0) + 1
            local mode      = (self._pan_tick % 8 == 0) and "ui" or "fast"

            UIManager:setDirty(self, mode)
        end
        return true
    end
    return false
end

function ColorWheelWidget:onPanReleaseColorWheel(arg, ges_ev)
    if self.brightness_slider
            and self.brightness_slider:handlePanRelease(ges_ev, self, self.dimen) then
        return true
    end
    if not self.color_wheel or not self.color_wheel.dimen then return false end

    if ges_ev.pos:intersectWith(self.color_wheel.dimen) then
        self:update() -- rebuilds widget tree with final hue/sat; does "ui" dirty
        return true
    end
    return false
end

function ColorWheelWidget:onSwipeColorWheel(arg, ges_ev)
    if self.brightness_slider then
        return self.brightness_slider:handleSwipe(ges_ev, self, self.dimen)
    end
    return false
end

function ColorWheelWidget:onApply()
    UIManager:close(self)
    if self.callback then
        local r, g, b = hsvToRgb(self.hue, self.saturation, self.value)
        self.callback(string.format("#%02X%02X%02X", r, g, b))
    end
    if self.close_callback then self.close_callback() end
    return true
end

function ColorWheelWidget:onCancel()
    UIManager:close(self)
    if self.cancel_callback then self.cancel_callback() end
    if self.close_callback then self.close_callback() end
    return true
end

function ColorWheelWidget:onCancelOrClose()
    return self:onCancel()
end

function ColorWheelWidget:onShow()
    UIManager:setDirty(self, "ui", nil, true)
    return true
end

return ColorWheelWidget
