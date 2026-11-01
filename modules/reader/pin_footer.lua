local Blitbuffer = require("ffi/blitbuffer")
local ButtonLabels = require("common/ui/button_labels")
local ColorIconWidget = require("common/ui/color_icon_widget")
local ColorTextWidget = require("common/ui/color_text_widget")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local References = require("modules/reader/references")
local ReaderStatusBar = require("common/reader_status_bar")
local ReaderThemes = require("common/reader_themes")
local Screen = Device.screen
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local utils = require("common/utils")
local _ = require("gettext")
local icons_dir = require("common/plugin_root") .. "/icons/"

local M = {}
local plugin
local MONO_SCALE = 0.875

local function controlSize(size)
    return Screen:scaleBySize(size * (Device:hasColorScreen() and 1 or MONO_SCALE))
end

function M.visible(footer)
    if footer.settings.pinned_pages == false then return false end
    if not References.enabled(footer.ui) then return false end
    return #References.pinLocations(footer.ui) > (footer.view.footer_visible and 0 or 1)
end

function M.width(footer)
    if not M.visible(footer) then return 0 end
    local count = #References.pinLocations(footer.ui)
    local face = footer.footer_text_face or Font:getFace("cfont", footer.settings.text_font_size)
    if footer._zen_pin_count ~= count or footer._zen_pin_face ~= face
            or footer._zen_pin_bold ~= footer.settings.text_font_bold then
        if footer._zen_pin_label then footer._zen_pin_label:free() end
        local size = controlSize(16)
        footer._zen_pin_label = HorizontalGroup:new{ allow_mirroring = false,
            ColorIconWidget:new{ icon = utils.resolveLocalIcon(icons_dir, "pin"),
                width = size, height = size, alpha = true },
            HorizontalSpan:new{ width = controlSize(3) },
            ColorTextWidget:new{ text = tostring(count), face = face,
                bold = footer.settings.text_font_bold, padding = 0, invert_night_mode = false },
        }
        ButtonLabels.alignIcon(footer._zen_pin_label[1], footer._zen_pin_label[3])
        footer._zen_pin_height = footer._zen_pin_label:getSize().h + 2 * controlSize(3)
        footer._zen_pin_count, footer._zen_pin_face = count, face
        footer._zen_pin_bold = footer.settings.text_font_bold
    end
    -- Leave room for the footer container's centering margin.
    return footer._zen_pin_label:getSize().w + controlSize(22) + footer.horizontal_margin
end

function M.height(footer)
    if M.width(footer) == 0 then return footer.height end
    return math.max(footer.height, footer._zen_pin_height)
end

local function centered(footer)
    local settings = footer.settings
    return settings.align == "center"
        and not (settings.all_at_once and (settings.dynamic_filler or settings.dynamic_filler2))
        and (settings.disable_progress_bar or settings.progress_bar_position ~= "alongside")
end

local function inside_right(footer)
    local settings = footer.settings
    -- No text items: KOReader zeroes text_width, so the inline pin reservation is dropped.
    return settings.all_at_once and not footer.has_no_mode and (settings.dynamic_filler or settings.dynamic_filler2
        or not settings.disable_progress_bar and settings.progress_bar_position == "alongside")
end

local function box_width(footer)
    return footer._zen_pin_label:getSize().w + 2 * controlSize(9)
end

-- Bare alongside bar: end it a short gap before the box instead of a margin plus reservation.
local function reserved_width(footer, width)
    local settings = footer.settings
    if width == 0 or not footer.has_no_mode or settings.disable_progress_bar
            or settings.progress_bar_position ~= "alongside" then return width end
    return box_width(footer) + Screen:scaleBySize(8)
end

local function paint_label(footer, bb, right, y, height, background)
    local width = M.width(footer)
    if width == 0 then return end
    local label = footer._zen_pin_label
    local color = ReaderThemes.getTextColor(plugin)
        or footer.footer_text and footer.footer_text.fgcolor or Blitbuffer.COLOR_BLACK
    label[1].fgcolor, label[3].fgcolor = color, color
    local size = label:getSize()
    y = y + math.floor((height - footer._zen_pin_height) / 2)
    height = footer._zen_pin_height
    y = math.min(y, Screen:getHeight() - math.max(footer.bottom_padding, Screen:scaleBySize(1)) - height)
    local padding = controlSize(9)
    local box_w = box_width(footer)
    local left = right - box_w
    if background then bb:paintRect(left, y, box_w, height, background) end
    bb:paintBorder(left, y, box_w, height, controlSize(1), color,
        controlSize(7), G_reader_settings:nilOrTrue("anti_alias_ui"))
    label:paintTo(bb, left + padding, y + math.floor((height - size.h) / 2))
    footer._zen_pin_dimen = Geom:new{ x = left, y = y, w = box_w, h = height }
end

function M.apply()
    plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    local Footer = require("apps/reader/modules/readerfooter")
    if Footer._zen_pins_patched then return end
    Footer._zen_pins_patched = true
    local get_height = Footer.getHeight
    Footer.getHeight = function(self, ...)
        if self.footer_container then
            local height = M.height(self)
            if self.footer_container.dimen.h ~= height then
                self.footer_container.dimen.h = height
                self.vertical_frame:resetLayout()
            end
        end
        return get_height(self, ...)
    end
    local update_container = Footer.updateFooterContainer
    Footer.updateFooterContainer = function(self, ...)
        local result = update_container(self, ...)
        local container = self.footer_container
        container.dimen.h = M.height(self)
        local paint = container.paintTo
        container.paintTo = function(widget, bb, x, y)
            local width = M.width(self)
            local full_width = widget.dimen.w
            local inline = inside_right(self)
            local is_centered = not inline and centered(self)
            widget.dimen.w = full_width - (inline and 0 or is_centered and 2 * width or reserved_width(self, width))
            paint(widget, bb, x + (is_centered and width or 0), y)
            widget.dimen.w = full_width
            local right = x + full_width - self.horizontal_margin
            if inline and self._zen_pin_right_inset then
                right = right - self._zen_pin_right_inset
            end
            paint_label(self, bb, right, y, widget.dimen.h)
        end
        return result
    end
    local update = Footer._updateFooterText
    Footer._updateFooterText = function(self, ...)
        if not self.view.footer_visible and not select(1, ...) and not select(2, ...) then
            return update(self, ...)
        end
        local width = M.width(self)
        local screen_width = self._saved_screen_width
        self._zen_pin_inline = width > 0 and inside_right(self)
        self._zen_pin_right_inset = nil
        self._zen_pin_reserved_width = width
        self._zen_pin_box_width = width > 0 and box_width(self) or nil
        if width > 0 and screen_width and not self._zen_pin_inline then
            self._saved_screen_width = screen_width - (centered(self) and 2 * width or reserved_width(self, width))
        end
        local generator = self.genFooterText
        if width > 0 and self._zen_pin_inline then self.genFooterText = self.genAllFooterText end
        local result = update(self, ...)
        self.genFooterText = generator
        self._saved_screen_width = screen_width
        self._zen_pin_reserved_width, self._zen_pin_box_width = nil, nil
        -- On hide KOReader refreshes only the new, pin-less height; clear the full old footer.
        local painted = self._zen_painted_dimen
        if painted and not self.view.footer_visible then
            self._zen_painted_dimen = nil
            UIManager:setDirty(self.view.dialog, "ui", painted)
        end
        return result
    end
    local paint = Footer.paintTo
    Footer.paintTo = function(self, bb, x, y)
        self._zen_pin_dimen = nil
        local height = self:getHeight()
        if self.footer_content and self.footer_content.dimen then self.footer_content.dimen.h = height end
        local result = paint(self, bb, x, y)
        local dimen = self.footer_content and self.footer_content.dimen
        if bb == Screen.bb and dimen then
            self._zen_painted_dimen = Geom:new{ x = dimen.x, y = dimen.y, w = dimen.w, h = dimen.h }
        end
        return result
    end
    local close = Footer.onCloseWidget
    Footer.onCloseWidget = function(self, ...)
        if self._zen_pin_label then self._zen_pin_label:free(); self._zen_pin_label = nil end
        return close(self, ...)
    end
    local View = require("apps/reader/modules/readerview")
    local paint_view = View.paintTo
    View.paintTo = function(self, bb, x, y)
        paint_view(self, bb, x, y)
        if bb ~= Screen.bb then return end
        if self.footer_visible then return end
        local footer = self.footer
        footer._zen_pin_dimen = nil
        if not M.visible(footer) then return end
        local right = select(2, ReaderStatusBar.getHorizontalMargins(self.ui.document, footer.horizontal_margin, plugin))
        if inside_right(footer) and footer._zen_pin_right_inset then
            right = right + footer._zen_pin_right_inset
        end
        local height = M.height(footer)
        local top = y + Screen:getHeight() - footer.bottom_padding - height
        if not footer.settings.disable_progress_bar and footer.settings.progress_bar_position == "below" then
            local bar_height = footer.settings.progress_style_thin and footer.settings.progress_style_thin_height
                or footer.settings.progress_style_thick_height
            top = top - Screen:scaleBySize(bar_height) - Size.span.vertical_default
        end
        paint_label(footer, bb, x + Screen:getWidth() - right, top, height,
            ReaderThemes.getBackgroundColor(plugin) or Blitbuffer.COLOR_WHITE)
    end
end

function M.attach(ui)
    local overrides = { "readerfooter_tap", "readerfooter_hold", "readerlink_tap", "readerhighlight_tap",
        "tap_forward", "tap_backward", "readermenu_tap", "readermenu_ext_tap" }
    for id, zone in pairs(ui._zones or {}) do
        if zone.def.ges == "tap" or zone.def.ges == "hold" then overrides[#overrides + 1] = id end
    end
    local function hit(ges)
        local footer = ui.view.footer
        local box = footer._zen_pin_dimen
        return M.visible(footer) and box
            and ges.pos.x >= box.x - box.w * 0.1 and ges.pos.x < box.x + box.w * 1.1
            and ges.pos.y >= box.y - box.h * 0.1 and ges.pos.y < box.y + box.h * 1.1
    end
    local function menu()
        local dialog
        local rows = {}
        for _i, item in ipairs(References.pinButtons(ui, ui:getCurrentPage(), function() UIManager:close(dialog) end)) do
            rows[#rows + 1] = { item }
        end
        dialog = require("ui/widget/buttondialog"):new{ title = _("Pin"), buttons = rows }
        UIManager:show(dialog)
    end
    local zones = {}
    for _i, gesture in ipairs({ "tap", "hold" }) do
        zones[#zones + 1] = { id = "zen_pin_" .. gesture, ges = gesture,
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 }, overrides = overrides,
            handler = function(ges)
                if not hit(ges) then return false end
                if gesture == "hold" or not References.pinnedPage(ui) then menu()
                else References.openPinned(ui) end
                return true
            end,
        }
    end
    ui:registerTouchZones(zones)
end

return M
