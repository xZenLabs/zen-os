local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local ButtonFeedback = require("common/ui/button_feedback")
local CenterContainer = require("ui/widget/container/centercontainer")
local ColorIconWidget = require("common/ui/color_icon_widget")
local Device = require("device")
local Event = require("ui/event")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Preview = require("modules/reader/page_browser_preview")
local References = require("modules/reader/references")
local ReaderThemes = require("common/reader_themes")
local ScrollHtmlWidget = require("ui/widget/scrollhtmlwidget")
local Size = require("ui/size")
local TopMenu = require("modules/global/patches/menu_top_swipe")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ZenPager = require("common/ui/zen_pager")
local _ = require("gettext")
local time = require("ui/time")
local T = require("ffi/util").template
local Screen = Device.screen
local utils = require("common/utils")
local icons_dir = require("common/plugin_root") .. "/icons/"
local stock_icons_dir = require("libs/libkoreader-lfs").currentdir() .. "/resources/icons/mdlight/"

local PinImage = ImageWidget:extend{ alpha = true }
function PinImage:_render()
    local x, y = self.center_x_ratio, self.center_y_ratio
    ImageWidget._render(self)
    -- Smaller images can pan through the spare space until their edges meet the viewport.
    self._max_off_center_x_ratio = math.abs(self.width - self._bb_w) / (2 * self._bb_w)
    self._max_off_center_y_ratio = math.abs(self.height - self._bb_h) / (2 * self._bb_h)
    self.center_x_ratio = math.max(0.5 - self._max_off_center_x_ratio, math.min(x, 0.5 + self._max_off_center_x_ratio))
    self.center_y_ratio = math.max(0.5 - self._max_off_center_y_ratio, math.min(y, 0.5 + self._max_off_center_y_ratio))
    self._offset_x = math.floor(self.center_x_ratio * self._bb_w - self.width / 2)
    self._offset_y = math.floor(self.center_y_ratio * self._bb_h - self.height / 2)
end

function PinImage:panBy(x, y)
    local center_x, center_y = ImageWidget.panBy(self, x, y)
    self.drawer:saveImageSettings()
    return center_x, center_y
end

function PinImage:paintTo(bb, x, y)
    if not self.corner_radius then return ImageWidget.paintTo(self, bb, x, y) end
    local radius = self.corner_radius
    local corner_x = self.dock_left and x + self.width - radius or x
    local top = bb:viewport(corner_x, y, radius, radius):copy()
    local bottom = bb:viewport(corner_x, y + self.height - radius, radius, radius):copy()
    ImageWidget.paintTo(self, bb, x, y)
    -- Keep the preview's two undocked corners and border above the image.
    for row = 0, radius - 1 do
        local dy = radius - row - 0.5
        local cut = math.ceil(radius - math.sqrt(radius * radius - dy * dy))
        local offset = self.dock_left and radius - cut or 0
        bb:blitFrom(top, corner_x + offset, y + row, offset, row, cut, 1)
        bb:blitFrom(bottom, corner_x + offset, y + self.height - row - 1, offset, radius - row - 1, cut, 1)
    end
    top:free()
    bottom:free()
end

local function paintControlBackground(bb, x, y, width, height)
    local radius = ButtonFeedback.getRadius()
    bb:paintRoundedRect(x, y, width, height, Blitbuffer.COLOR_WHITE, radius)
    bb:paintBorder(x, y, width, height, Screen:scaleBySize(1), Blitbuffer.COLOR_BLACK, radius, false)
end

local PinPager = HorizontalGroup:extend{ allow_mirroring = false }
function PinPager:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local arrow_width = self[1]:getSize().w
    local drawer = self.drawer
    if drawer.full_image then
        paintControlBackground(bb, x, y, arrow_width, self.dimen.h)
        paintControlBackground(bb, x + self.dimen.w - arrow_width, y, arrow_width, self.dimen.h)
        local dots_width = self.dimen.w - 2 * arrow_width
        if #drawer.pins <= 20 then
            dots_width = math.min(dots_width, Screen:scaleBySize(6) * (2 * #drawer.pins - 1) + 2 * drawer.padding)
        end
        self.dots_dimen = Geom:new{ x = x + math.floor((self.dimen.w - dots_width) / 2),
            y = y + math.floor((self.dimen.h - drawer.bar_height) / 2), w = dots_width, h = drawer.bar_height }
        paintControlBackground(bb, self.dots_dimen.x, self.dots_dimen.y, dots_width, drawer.bar_height)
    end
    HorizontalGroup.paintTo(self, bb, x, y)
    ZenPager.paint(bb, x + arrow_width, y, self.dimen.w - 2 * arrow_width, self.dimen.h,
        self.drawer.pin_index, #self.drawer.pins,
        "dots", nil, Screen:scaleBySize(6))
end

local Drawer = FocusManager:extend{
    name = "zen_reference_drawer", covers_footer = true, disable_double_tap = true,
    alpha = 0.3, -- Repaint the background before blending the shadow.
}

function Drawer:new(spec)
    local instance = self:extend(spec)
    local ok, err = pcall(function() instance:_init(); instance:init() end)
    if not ok then instance:free(); error(err, 0) end
    return instance
end

function Drawer:init()
    self.show_parent = self.ui
    self.ui._zen_references = self.ui._zen_references or {}
    local state = self.ui._zen_references
    if state.drawer then state.drawer:onClose() end
    self.dimen = Screen:getSize()
    self.landscape = self.dimen.w > self.dimen.h
    self.side_margin = self.footnote and Screen:scaleBySize(8) or 0
    self.width = (self.landscape and math.floor(self.dimen.w / 2) or self.dimen.w) - 2 * self.side_margin
    self.height = self.landscape and self.dimen.h or math.floor(self.dimen.h * 0.4)
    if not self.footnote then
        self.width, self.height = math.floor(self.dimen.w * 0.7), math.floor(self.dimen.h * 0.7)
    end
    self.bar_height = Screen:scaleBySize(28)
    self.pager_height = not self.footnote and #self.pins > 1 and Screen:scaleBySize(32) or 0
    self.padding = Screen:scaleBySize(8)
    self.header_gap = self.footnote and 0 or Screen:scaleBySize(8)
    self.right_padding = Screen:scaleBySize(2)
    self.top_padding = Screen:scaleBySize(self.footnote and 16 or 4)
    self.bottom_padding = Screen:scaleBySize(self.footnote and 8 or 2)
    self.border_size = Screen:scaleBySize(2)
    self.shadow_size = Screen:scaleBySize(4)
    self.background = ReaderThemes.getBackgroundColor(self.plugin)
    if not self.background then
        local color = G_reader_settings:readSetting("cre_background_color")
        self.background = color and Blitbuffer.colorFromString(string.format("#%06x", color)) or Blitbuffer.COLOR_WHITE
        if color and ReaderThemes.isDarkMode() then self.background = self.background:invert() end
    end
    self.foreground = ReaderThemes.getTextColor(self.plugin) or Blitbuffer.COLOR_BLACK
    self.body_width = self.width - self.padding - self.right_padding - 2 * self.border_size
    local vertical_inset = self.top_padding + self.bottom_padding + 2 * self.border_size
    self.body_height = self.height - vertical_inset
        - (self.footnote and 0 or self.bar_height + self.header_gap + self.pager_height)
    self.layout = {}
    if self.footnote then
        local source = self.footnote.htmlwidget
        local background = string.format("#%02x%02x%02x", self.background:getR(), self.background:getG(), self.background:getB())
        local scroll_bar, scroll_span = Screen:scaleBySize(4), Screen:scaleBySize(4)
        -- Replace stock doc-aligned left margin so both text edges sit equally inset.
        local inset = Screen:scaleBySize(14)
        local base_css = source.css .. string.format("\n@page { margin: 0 %dpx 0 %dpx; }",
            inset - self.right_padding - scroll_bar - scroll_span, inset - self.padding)
        local css = base_css .. string.format(
            "\n@page { background-color: %s; }\nhtml, body { background-color: %s !important; }"
                .. "\nbody, body * { color: #%02x%02x%02x !important; }",
            background, background,
            self.foreground:getR(), self.foreground:getG(), self.foreground:getB())
        self.htmlwidget = ScrollHtmlWidget:new{
            html_body = source.html_body, is_xhtml = source.is_xhtml, css = base_css,
            default_font_size = source.default_font_size,
            width = self.body_width, height = self.body_height,
            scroll_bar_width = scroll_bar, text_scroll_span = scroll_span,
            dialog = self, highlight_text_selection = source.highlight_text_selection,
        }
        -- A painted page background fills MuPDF's bounding box, so measure first.
        local short = not self.landscape and self.htmlwidget:getSinglePageHeight()
        if short then
            -- Used bbox stops at glyph ink; pad for last-line descent so relayout stays one page.
            short = short + math.ceil(source.default_font_size * 0.5)
            self.height = math.min(self.height,
                math.max(math.ceil(2 * source.default_font_size * 1.3), short) + vertical_inset)
            self.body_height = self.height - vertical_inset
        end
        if short or background ~= "#ffffff" or self.foreground ~= Blitbuffer.COLOR_BLACK then
            self.htmlwidget:free()
            self.htmlwidget.height = self.body_height
            self.htmlwidget.css = css
            self.htmlwidget:init()
        end
        self.htmlwidget.v_scroll_bar.bordercolor = self.foreground
        self.htmlwidget.v_scroll_bar.rectcolor = self.foreground
        self.htmlwidget.onTapScrollText = function() return false end
        if state.footnote and state.footnote.xpointer == self.link.xpointer and state.ratio then
            self.htmlwidget:scrollToRatio(state.ratio)
        else state.ratio = nil end
        local link = {}
        for key, value in pairs(self.link) do link[key] = value end
        state.footnote = link
        self.content = self.htmlwidget
    else
        self:renderPage()
    end
    self:buildLayout()
    if not self.footnote then self.selected = { x = 1, y = 1 } end
    self.key_events.Close = {{ Device.input.group.Back }}
    self.key_events.Press = {{ "Press" }, { "Return" }, { "Enter" }}
    self.key_events.NextReferencePage = {{ Device.input.group.PgFwd }}
    self.key_events.PreviousReferencePage = {{ Device.input.group.PgBack }}
    self.ges_events = { TapClose = { GestureRange:new{ ges = "tap", range = self.dimen } } }
    self.ges_events.EdgeSwipe = { GestureRange:new{ ges = "swipe",
        range = function() return Geom:new{ x = self.frame.dimen.x, y = self.frame.dimen.y,
            w = self.frame.dimen.w, h = self.top_padding + self.border_size } end } }
    for _i, name in ipairs({ "Swipe", "Pan", "PanRelease", "Pinch", "Spread" }) do
        local gesture = ({ Swipe = "swipe", Pan = "pan", PanRelease = "pan_release",
            Pinch = "pinch", Spread = "spread" })[name]
        self.ges_events[name] = { GestureRange:new{ ges = gesture,
            range = function() return self.content.dimen end } }
    end
    if not self.footnote then self.ges_events.Swipe[1].range = self.dimen end
    self.ges_events.PanRelease[1].range = self.dimen -- Finish drags released outside the preview.
    if self.footnote and self.footnote.ges_events then
        for _i, name in ipairs({ "HoldStartText", "HoldPanText", "HoldReleaseText" }) do
            self.ges_events[name] = self.footnote.ges_events[name]
        end
        self.footnote:free()
        self.footnote[1] = nil
        self.footnote.htmlwidget = self.htmlwidget
        -- Swallow the second tap of an accidental double tap on the link.
        self.tap_guard_until = time.now() + time.ms(G_reader_settings:readSetting("ges_double_tap_interval_ms") or 300)
    end
    state.drawer = self
end

function Drawer:button(text, callback, width, icon, rotation, align, padding)
    padding = Screen:scaleBySize(padding or 4)
    local icon_size = self.bar_height - 2 * padding
    local button = Button:new{ text = text, icon = icon, icon_rotation_angle = rotation, callback = callback, width = width,
        icon_width = icon_size, icon_height = icon_size,
        height = icon_size, align = align or "center", bordersize = 0, padding = padding, text_font_size = 16,
        text_font_bold = false, show_parent = self }
    button.frame.background = self.background
    if self.full_image then
        button.frame.background = Blitbuffer.COLOR_WHITE
        button.frame.radius = ButtonFeedback.getRadius()
        local paint_frame = button.frame.paintTo
        function button.frame:paintTo(bb, x, y)
            paint_frame(self, bb, x, y)
            local size = self:getSize()
            bb:paintBorder(x, y, size.w, size.h, Screen:scaleBySize(1), Blitbuffer.COLOR_BLACK, self.radius, false)
        end
    end
    if icon then
        button.label_widget:free()
        button.label_widget = ColorIconWidget:new{ icon = icon, rotation_angle = rotation,
            width = button.icon_width, height = button.icon_height, alpha = true }
        button.label_container[1] = button.label_widget
    end
    button.label_widget.fgcolor = self.foreground
    return button
end

function Drawer:buildLayout()
    self.pager = nil
    self.zoom_button = nil
    self.zoom_in_button, self.zoom_out_button = nil, nil
    self.layout = {{ self.content }}
    local left = not self.footnote and self.plugin.config.reader_pins.side == "left"
    local body = Geom:new{ w = self.body_width, h = self.body_height }
    if self.full_image then
        body = VerticalSpan:new{ width = self.body_height }
    elseif self.htmlwidget then
        body = CenterContainer:new{ dimen = body, self.content }
    else
        self.content.overlap_offset = { -self.padding - (left and self.border_size or 0), 0 }
        body = OverlapGroup:new{ dimen = body, allow_mirroring = false, self.content }
    end
    local contents = VerticalGroup:new{ align = "center", body }
    if not self.footnote then
        self.menu_button = self:button(nil, function() self:showMenu() end, self.bar_height,
            utils.resolveLocalIcon(icons_dir, "more_vertical"), nil, nil, 2)
        if not self.htmlwidget then
            self.zoom_button = self:button(nil, function() self:zoom(nil, not self.full_image) end, self.bar_height,
                utils.resolveLocalIcon(icons_dir, self.full_image and "fullscreen_exit" or "fullscreen"))
        end
        self.close_button = self:button(nil, function() self:onClose() end, self.bar_height,
            utils.resolveLocalIcon(stock_icons_dir, "chevron.up"), 180)
        local right = { self.zoom_button, self.close_button }
        if not self.zoom_button then table.remove(right, 1) end
        local menu_gap = self.full_image and self.padding or 0 -- Bordered pills need a gap.
        local buttons_width = self.bar_height * (#right + 1) + self.padding * (#right - 1) + menu_gap
        local left_span = math.floor((self.body_width - buttons_width - self.padding + self.right_padding) / 2)
        self.page_button = self:button(T(_("Page %1"), References.pageLabel(self.ui, self.page)),
            function() self:onExpand() end, left_span, nil, nil, "left")
        self.page_button.enabled = self.page ~= self.ui:getCurrentPage()
        local icon_size, gap = Screen:scaleBySize(16), Screen:scaleBySize(6)
        local label = self.page_button.label_widget
        label:setMaxWidth(left_span - icon_size - gap - 2 * self.page_button.padding_h)
        local icon = ColorIconWidget:new{ icon = utils.resolveLocalIcon(icons_dir, "pin"),
            width = icon_size, height = icon_size, alpha = true, fgcolor = self.foreground }
        self.page_button.label_container[1] = HorizontalGroup:new{ allow_mirroring = false,
            icon, HorizontalSpan:new{ width = gap }, label,
        }
        left_span = self.page_button.label_container[1]:getSize().w + 2 * self.page_button.padding_h
        self.page_button.width = left_span
        self.page_button.dimen.w = left_span
        self.page_button.label_container.dimen.w = left_span - 2 * self.page_button.padding_h
        table.insert(contents, 1, VerticalSpan:new{ width = self.header_gap })
        -- Page, menu | zoom, close.
        local header = { allow_mirroring = false, self.page_button, HorizontalSpan:new{ width = menu_gap }, self.menu_button,
            HorizontalSpan:new{ width = self.body_width - left_span - buttons_width - (self.padding - self.right_padding) } }
        self.layout = {{ self.page_button, self.menu_button }, { self.content }}
        for i, button in ipairs(right) do
            if i > 1 then header[#header + 1] = HorizontalSpan:new{ width = self.padding } end
            header[#header + 1] = button
            table.insert(self.layout[1], button)
        end
        header[#header + 1] = HorizontalSpan:new{ width = self.padding - self.right_padding }
        table.insert(contents, 1, HorizontalGroup:new(header))
        if self.pager_height > 0 then
            self.pager = PinPager:new{ drawer = self,
                dimen = Geom:new{ w = self.body_width, h = self.pager_height },
                ColorIconWidget:new{ icon = utils.resolveLocalIcon(stock_icons_dir, "chevron.left"),
                    width = self.pager_height, height = self.pager_height, alpha = true, fgcolor = self.foreground },
                HorizontalSpan:new{ width = self.body_width - 2 * self.pager_height },
                ColorIconWidget:new{ icon = utils.resolveLocalIcon(stock_icons_dir, "chevron.right"),
                    width = self.pager_height, height = self.pager_height, alpha = true, fgcolor = self.foreground },
            }
            contents[#contents + 1] = self.pager
        end
    end
    if self.full_image then
        self.zoom_out_button = self:button(nil, function() self:zoom(0.8) end, self.bar_height,
            utils.resolveLocalIcon(icons_dir, "zoom_out"))
        self.zoom_in_button = self:button(nil, function() self:zoom(1.25) end, self.bar_height,
            utils.resolveLocalIcon(icons_dir, "zoom_in"))
        local zoom_controls = VerticalGroup:new{ align = "center",
            self.zoom_in_button, VerticalSpan:new{ width = self.padding }, self.zoom_out_button }
        local overlay_height = self.height - self.top_padding - self.bottom_padding - 2 * self.border_size
        zoom_controls.overlap_offset = {
            self.body_width - zoom_controls:getSize().w - (self.padding - self.right_padding),
            self.bar_height + 2 * self.padding,
        }
        self.layout[#self.layout + 1] = { self.zoom_in_button }
        self.layout[#self.layout + 1] = { self.zoom_out_button }
        self.content.overlap_offset = { -self.padding - (left and self.border_size or 0), -self.top_padding }
        contents = OverlapGroup:new{ dimen = Geom:new{ w = self.body_width, h = overlay_height },
            allow_mirroring = false, self.content, contents, zoom_controls }
    end
    if self.selected then
        self.selected.y = math.min(self.selected.y, #self.layout)
        self.selected.x = math.min(self.selected.x, #self.layout[self.selected.y])
    end
    -- Hide the docked corners and border beyond the screen edge.
    local extension = self.footnote and 0 or Size.radius.window + self.border_size
    self.frame = FrameContainer:new{
        padding = self.padding, padding_top = self.top_padding, margin = 0,
        padding_bottom = self.bottom_padding,
        padding_left = self.padding + (left and extension or 0),
        padding_right = self.right_padding + (left and 0 or extension), allow_mirroring = false,
        bordersize = self.border_size, radius = Size.radius.window, color = self.foreground,
        background = self.background,
        -- Extend footnote bottom corners and border below the screen.
        height = self.height + (self.footnote and Size.radius.window + self.border_size or 0),
        overlap_offset = { left and -extension
                or (not self.footnote or self.landscape) and self.dimen.w - self.width - self.side_margin or self.side_margin,
            self.footnote and self.landscape and 0 or self.dimen.h - self.height }, contents,
    }
    local size = self.frame:getSize()
    self.refresh_dimen = Geom:new{
        x = self.frame.overlap_offset[1] - self.shadow_size,
        y = self.frame.overlap_offset[2] - self.shadow_size,
        w = size.w + 2 * self.shadow_size,
        h = self.frame.height + 2 * self.shadow_size,
    }:intersect(self.dimen)
    self[1] = OverlapGroup:new{ dimen = self.dimen, allow_mirroring = false, self.frame }
end

function Drawer:paintTo(bb, x, y)
    local frame, shadow, opacity = self.frame, self.shadow_size, self.alpha
    local width, height = frame:getSize().w, frame.height
    local radius = frame.radius + frame.bordersize
    local fx, fy = x + frame.overlap_offset[1], y + frame.overlap_offset[2]
    local shade = Screen.night_mode and bb.lightenRect or bb.darkenRect
    -- Blend only the narrow perimeter; the opaque frame covers the inner corner pixels.
    shade(bb, fx + radius, fy - shadow, width - 2 * radius, shadow, opacity)
    shade(bb, fx + radius, fy + height, width - 2 * radius, shadow, opacity)
    shade(bb, fx - shadow, fy + radius, shadow, height - 2 * radius, opacity)
    shade(bb, fx + width, fy + radius, shadow, height - 2 * radius, opacity)
    local outer_radius = radius + shadow
    for row = 0, outer_radius - 1 do
        local dy = outer_radius - row - 0.5
        local cut = math.ceil(outer_radius - math.sqrt(outer_radius * outer_radius - dy * dy))
        local span = outer_radius - cut
        shade(bb, fx - shadow + cut, fy - shadow + row, span, 1, opacity)
        shade(bb, fx + width - radius, fy - shadow + row, span, 1, opacity)
        shade(bb, fx - shadow + cut, fy + height + shadow - row - 1, span, 1, opacity)
        shade(bb, fx + width - radius, fy + height + shadow - row - 1, span, 1, opacity)
    end
    FocusManager.paintTo(self, bb, x, y)
end

function Drawer:onEdgeSwipe(_arg, ges)
    if ges.direction == "north" then return self:onExpand() end
    if ges.direction == "south" then return self:onClose() end
    return true
end

function Drawer:renderImage(factor, x, y)
    local height = self.full_image and self.height - 2 * self.border_size or self.body_height
    local width_scale, height_scale = self.image_width / self.preview.bb:getWidth(), height / self.preview.bb:getHeight()
    self.fit_scale = math.min(width_scale, height_scale)
    local full_scale = math.max(width_scale, height_scale)
    local base_scale = self.full_image and full_scale or self.fit_scale
    local scale = factor and self.scale * factor or base_scale * self.image_settings.image_zoom
    self.scale = math.max(self.fit_scale, math.min(math.max(4, full_scale), scale))
    self.content = PinImage:new{ drawer = self, image = self.preview.bb, image_disposable = false,
        width = self.image_width, height = height, scale_factor = self.scale,
        center_x_ratio = x or 0.5, center_y_ratio = y or 0.5,
        corner_radius = self.full_image and Size.radius.window or nil,
        dock_left = self.plugin.config.reader_pins.side == "left",
        original_in_nightmode = self.preview.original_image or false }
    return self.scale / base_scale
end

function Drawer:renderPage()
    self.full_image = nil
    local image = self.pins[self.pin_index].image
    if self.ui.rolling and not image then
        local html, css, size = require("modules/reader/pin_settings").content(
            self.ui, self.page, self.plugin.config.reader_pins, self.background, self.foreground)
        if html then
            self.htmlwidget = ScrollHtmlWidget:new{
                html_body = html, css = css, is_xhtml = true, default_font_size = size,
                width = self.body_width, height = self.body_height, dialog = self,
                scroll_bar_width = Screen:scaleBySize(4), text_scroll_span = Screen:scaleBySize(4),
            }
            self.htmlwidget.onTapScrollText = function(widget, _arg, ges)
                if require("ui/bidi").flipIfMirroredUILayout(ges.pos.x < widget.dimen.x + widget.dimen.w / 2) then
                    widget:onScrollUp()
                else widget:onScrollDown() end
                return true
            end
            self.htmlwidget.onScrollText = function(_widget, arg, ges) return self:onSwipe(arg, ges) end
            self.htmlwidget.key_events = {}
            self.htmlwidget.v_scroll_bar.bordercolor = self.foreground
            self.htmlwidget.v_scroll_bar.rectcolor = self.foreground
            self.htmlwidget.v_scroll_bar.height = self.body_height - Screen:scaleBySize(8)
            self.htmlwidget[1]:resetLayout()
            self.htmlwidget[1]:getSize()
            self.content = self.htmlwidget
            return
        end
    end
    self.preview = self.preview or Preview:new{
        ui = self.ui, page = self.page, width = Screen:getWidth(), height = Screen:getHeight(),
        fit_page = true,
    }
    self.preview:setPage(self.page)
    self.preview.image_xpointer = image
    self.preview:render()
    self.image_width = self.width - self.border_size
    self.image_location = self.ui.rolling and self.pins[self.pin_index].location or self.page
    local images = self.ui.doc_settings:readSetting("zen_pinned_image_settings") or {}
    self.image_settings = images[self.image_location] or { image_full = false, image_zoom = 1 }
    self.full_image = self.image_settings.image_full
    self:renderImage(nil, self.image_settings.center_x_ratio, self.image_settings.center_y_ratio)
end

function Drawer:changePage(step)
    if self.footnote then
        if step > 0 then self.htmlwidget:onScrollDown() else self.htmlwidget:onScrollUp() end
        return true
    end
    local index = (self.pin_index - 1 + step) % #self.pins + 1
    if index == self.pin_index then return true end
    self:free()
    self.pin_index, self.page = index, self.pins[index].page
    self:renderPage()
    self:buildLayout()
    self.ui.doc_settings:saveSetting("zen_last_pinned_page", self.ui.rolling and self.pins[index].location or self.page)
    UIManager:setDirty(self, "ui", self.refresh_dimen)
    return true
end

function Drawer:onNextReferencePage() return self:changePage(1) end
function Drawer:onPreviousReferencePage() return self:changePage(-1) end

function Drawer:saveImageSettings()
    local settings = self.image_settings
    settings.center_x_ratio, settings.center_y_ratio = self.content.center_x_ratio, self.content.center_y_ratio
    local images = self.ui.doc_settings:readSetting("zen_pinned_image_settings") or {}
    images[self.image_location] = settings
    self.ui.doc_settings:saveSetting("zen_pinned_image_settings", images)
end

function Drawer:zoom(factor, full)
    if self.htmlwidget then return true end
    local x, y = self.content.center_x_ratio, self.content.center_y_ratio
    self.content:free()
    local settings = self.image_settings
    if not factor then self.full_image = full; settings.image_zoom = 1 end
    settings.image_full = self.full_image == true
    settings.image_zoom = self:renderImage(factor, factor and x or nil, factor and y or nil)
    self:saveImageSettings()
    self[1]:free()
    self:buildLayout()
    UIManager:setDirty(self, "ui", self.refresh_dimen)
    return true
end

function Drawer:onSpread() return self:zoom(1.25) end
function Drawer:onPinch() return self:zoom(0.8) end

function Drawer:onPan(_arg, ges)
    self.pan = ges.relative
    return true
end

function Drawer:onPanRelease()
    if not self.htmlwidget and self.pan then self.content:panBy(-self.pan.x, -self.pan.y) end
    self.pan = nil
    return true
end

function Drawer:onSwipe(_arg, ges)
    if not self.frame.dimen:contains(ges.pos) then return TopMenu.handleSwipe(ges) end
    if not self.footnote and ges.direction == "south"
            and ges.pos.y < self.frame.dimen.y + self.frame.dimen.h * 0.07 then
        return self:onClose()
    end
    if not self.htmlwidget and self.scale > self.fit_scale then
        local distance = ges.distance or self.body_height * 0.8
        local x = ges.direction:find("west", 1, true) and 1 or ges.direction:find("east", 1, true) and -1 or 0
        local y = ges.direction:find("north", 1, true) and 1 or ges.direction:find("south", 1, true) and -1 or 0
        if x ~= 0 and y ~= 0 then distance = distance / math.sqrt(2) end
        self.content:panBy(x * distance, y * distance)
        return true
    end
    if ges.direction == "west" then return self:onNextReferencePage() end
    if ges.direction == "east" then return self:onPreviousReferencePage() end
    if self.htmlwidget then
        if ges.direction == "north" then self.htmlwidget:onScrollDown() else self.htmlwidget:onScrollUp() end
    else
        self.content:panBy(0, ges.direction == "north" and self.body_height * 0.8 or -self.body_height * 0.8)
    end
    return true
end

function Drawer:onTapClose(_arg, ges)
    if self.tap_guard_until and time.now() < self.tap_guard_until then return true end
    if not self.frame.dimen:contains(ges.pos) then
        if not self.footnote and TopMenu.handleTap(nil, ges) then return true end
        return self:onClose()
    end
    if self.pager and self.pager.dimen:contains(ges.pos) then
        local dimen = self.pager.dimen
        return self:changePage(ges.pos.x < dimen.x + dimen.w / 2 and -1 or 1)
    end
    if self.content.dimen:contains(ges.pos) then
        if self.footnote then return self:onExpand() end
        if not self.htmlwidget then self:showImage() end
    end
    return true
end

function Drawer:showImage()
    local viewer = require("ui/widget/imageviewer"):new{
        -- Own copy: rotation closes the drawer and frees preview.bb under the viewer.
        image = self.preview.bb:copy(), image_disposable = true, fullscreen = true, with_title_bar = false,
    }
    viewer.onTap = function(image_viewer) image_viewer:onClose(); return true end
    UIManager:show(viewer)
end

function Drawer:onExpand()
    if self.footnote then self.footnote.follow_callback(); return true end
    if self.page == self.ui:getCurrentPage() then return true end
    self:onClose()
    self.ui.link:addCurrentLocationToStack()
    self.ui:handleEvent(Event:new("GotoPage", self.page))
    return true
end

function Drawer:onShow()
    UIManager:setDirty(self, "ui", self.refresh_dimen)
end

function Drawer:onClose()
    UIManager:close(self)
    return true
end

function Drawer:getScrollRatio()
    local html = self.htmlwidget and self.htmlwidget.htmlbox_widget
    return html and (html.page_number - 1) / html.page_count
end

function Drawer:onCloseWidget()
    if self.closed then return end
    self.closed = true
    local state = self.ui._zen_references
    if state then
        if self.footnote then state.ratio = self:getScrollRatio() end
        if state.drawer == self then state.drawer = nil end
    end
    if self.footnote and self.footnote.close_callback then
        self.footnote.close_callback(self.landscape and nil or self.height)
    end
    UIManager:setDirty(self.ui, "ui", self.refresh_dimen)
    self:free()
end

function Drawer:free()
    if self[1] then self[1]:free(); self[1] = nil
    elseif self.htmlwidget then self.htmlwidget:free() end
    if self.preview then self.preview:free() end
    self.htmlwidget = nil
end

function Drawer:reload()
    if self.closed then return end
    self:free()
    self:renderPage()
    self:buildLayout()
    UIManager:setDirty(self, "ui", self.refresh_dimen)
end

function Drawer:showMenu()
    local dialog
    local rows = {}
    local function add(item)
        rows[#rows + 1] = {{ text = item.text, enabled = item.enabled,
            checked_func = item.checked_func, callback = function()
                UIManager:close(dialog)
                item.callback()
            end }}
    end
    add{ text = _("Remove pin"), callback = function()
        References.setPin(self.ui, self.page, true)
        local index = self.pin_index
        self:onClose()
        References.openPinned(self.ui, index)
    end }
    add{ text = _("Settings"), callback = function()
        self:onClose()
        require("modules/settings/zen_settings_page").show(self.plugin, {
            path = { { key = "text", value = _("Reader") },
                { key = "text", value = _("Footnotes and pinned pages") },
                { key = "text", value = _("Pinned page options") } },
        })
    end }
    dialog = require("common/ui/zen_anchored_menu").new{
        anchor = function() return self.menu_button.dimen, true end, buttons = rows,
    }
    dialog._zen_pin_menu = true
    UIManager:show(dialog)
end

return Drawer
