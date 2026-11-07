local Blitbuffer = require("ffi/blitbuffer")
local ButtonLabels = require("common/ui/button_labels")
local ColorIconWidget = require("common/ui/color_icon_widget")
local ColorTextWidget = require("common/ui/color_text_widget")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ReaderThemes = require("common/reader_themes")
local ReaderStatusBar = require("common/reader_status_bar")
local References = require("modules/reader/references")
local Screen = Device.screen
local Size = require("ui/size")
local UIManager = require("ui/uimanager")
local Widget = require("ui/widget/widget")
local _ = require("gettext")
local T = require("ffi/util").template
local utils = require("common/utils")
local icons_dir = require("common/plugin_root") .. "/icons/"

local ReturnButton = Widget:extend{ duration = 10 }

function ReturnButton:isVisible()
    return self.visible == true and not not References.enabled(self.ui)
end

function ReturnButton:refresh()
    UIManager:setDirty(self.ui, function() return "ui", self.dimen end)
end

local tracking -- button whose tab touch is being followed

function ReturnButton:hide(refresh)
    -- Drop the module-level touch reference so a closed ReaderUI can be collected.
    if tracking == self then tracking, self.touch = nil, nil end
    if self.pending_callback then UIManager:unschedule(self.pending_callback); self.pending_callback = nil end
    if self.expire then UIManager:unschedule(self.expire); self.expire = nil end
    local visible = self.visible
    self.visible, self.location = false, nil
    if visible and refresh ~= false then self:refresh() end
end

function ReturnButton:queue(location)
    if self.pending_callback then UIManager:unschedule(self.pending_callback) end
    self.pending_callback = function()
        self.pending_callback = nil
        if not References.enabled(self.ui) or self.ui.link:compareLocationToCurrent(location) then return end
        self:hide(false)
        self.visible, self.location = true, location
        self.expire = function() self:hide() end
        UIManager:scheduleIn(self.duration, self.expire)
        self:refresh()
    end
    -- History is saved before navigation; inspect the destination after it settles.
    UIManager:nextTick(self.pending_callback)
end

function ReturnButton:paintTo(bb, x, y)
    if bb ~= Screen.bb or not self:isVisible() then return end
    local top = UIManager:getTopmostVisibleWidget()
    if top ~= self.ui and top ~= self.ui.show_parent and (not top or top.show_parent ~= self.ui) then return end
    local page = References.locationPage(self.ui, self.location)
    if not page then return end
    self.text = T(_("Return to page %1"), References.pageLabel(self.ui, page))
    local foreground = ReaderThemes.getTextColor(self.plugin) or Blitbuffer.COLOR_BLACK
    local icon_size, gap = Screen:scaleBySize(16), Screen:scaleBySize(4)
    local padding, border = Screen:scaleBySize(10), Screen:scaleBySize(1)
    local vertical_padding = Screen:scaleBySize(Device:hasColorScreen() and 6 or 4)
    local footer = self.ui.view.footer
    local label = ColorTextWidget:new{
        text = self.text,
        face = footer.footer_text_face or Font:getFace("cfont", footer.settings.text_font_size),
        bold = footer.settings.text_font_bold, fgcolor = foreground, invert_night_mode = false,
        max_width = math.floor(Screen:getWidth() * 0.48) - 2 * (padding + border) - icon_size - gap,
    }
    local icon = ColorIconWidget:new{ icon = utils.resolveLocalIcon(icons_dir, "return"),
        width = icon_size, height = icon_size, alpha = true, fgcolor = foreground }
    ButtonLabels.alignIcon(icon, label)
    local frame = FrameContainer:new{
        bordersize = border, margin = 0, radius = Size.radius.window,
        padding_left = padding, padding_right = padding,
        padding_top = vertical_padding, padding_bottom = vertical_padding + Size.radius.window,
        background = ReaderThemes.getBackgroundColor(self.plugin) or Blitbuffer.COLOR_WHITE,
        color = foreground, HorizontalGroup:new{ allow_mirroring = false,
            icon,
            HorizontalSpan:new{ width = gap }, label,
        },
    }
    local left = ReaderStatusBar.getHorizontalMargins(self.ui.document, footer.horizontal_margin, self.plugin)
    frame:paintTo(bb, x + left, y + Screen:getHeight() - frame:getSize().h + frame.radius)
    self.dimen = frame.dimen
    frame:free()
end

local function extend(touch, x, y)
    touch.down, touch.up = math.max(touch.down, y - touch.y), math.max(touch.up, touch.y - y)
    touch.left, touch.right = math.max(touch.left, touch.x - x), math.max(touch.right, x - touch.x)
end

-- Sub-pan-threshold movement never becomes a gesture and lift points drift, so sample raw contacts.
local function trackContacts()
    local detector = Device.input and Device.input.gesture_detector
    if not detector or detector._zen_return_feed then return end
    local feed = detector.feedEvent
    detector._zen_return_feed = feed
    detector.feedEvent = function(self, tevs)
        local touch = tracking and tracking.touch
        if touch then
            for _i, tev in ipairs(tevs) do
                if tev.x and tev.y then extend(touch, tev.x, tev.y) end
            end
        end
        return feed(self, tevs)
    end
end

function ReturnButton:onTouch(ges)
    local armed = self:isVisible() and self.dimen and self.dimen:contains(ges.pos)
    self.touch = armed and { x = ges.pos.x, y = ges.pos.y, down = 0, up = 0, left = 0, right = 0 } or nil
    tracking = armed and self or nil
    return false
end

-- Recessed bezels leave little travel, so any mostly-down or mostly-left nudge counts.
local function isDismissDrag(touch, pos)
    extend(touch, pos.x, pos.y)
    local away = math.max(touch.down, touch.left)
    return away >= Screen:scaleBySize(3) and away > touch.up and away > touch.right
end

function ReturnButton:onTap(ges)
    local touch = self.touch
    self.touch, tracking = nil, nil
    if not self:isVisible() or not self.dimen then return false end
    if touch and isDismissDrag(touch, ges.pos) then
        self:hide()
        return true
    end
    if not self.dimen:contains(ges.pos) then return false end
    require("common/ui/button_feedback").flashButton(self.dimen)
    self:hide(false)
    References.goBack(self.ui)
    return true
end

-- Swipes start above the tab, so accept its column from well above it down to the screen edge.
function ReturnButton:swipeHit(pos)
    local box, pad = self.dimen, Screen:scaleBySize(24)
    return pos.x >= box.x - pad and pos.x < box.x + box.w + pad
        and pos.y >= box.y - Screen:getHeight() * 0.15
end

-- West stays on the tab itself so page-turn swipes nearby are untouched.
function ReturnButton:onSwipe(ges)
    if not self:isVisible() or not self.dimen then return false end
    if not ((ges.direction == "south" and self:swipeHit(ges.pos))
        or (ges.direction == "west" and self.dimen:contains(ges.pos))) then return false end
    self:hide()
    return true
end

function ReturnButton.attach(ui, plugin)
    if ui._zen_return_button then return end
    local button = ReturnButton:new{ ui = ui, plugin = plugin }
    ui._zen_return_button = button
    trackContacts()
    local ReaderView = require("apps/reader/modules/readerview")
    -- Keep the overlay above class patches, including a status bar enabled later.
    ui.view.paintTo = function(view, bb, x, y)
        if bb == Screen.bb and button.location and ui.link:compareLocationToCurrent(button.location) then button:hide(false) end
        ReaderView.paintTo(view, bb, x, y)
        button:paintTo(bb, x, y)
    end
    local overrides = { "readerlink_tap", "readerhighlight_tap", "readermenu_tap", "readermenu_ext_tap",
        "tap_top_left_corner", "tap_forward", "tap_backward" }
    local swipe_overrides, touch_overrides = {}, {}
    for id, zone in pairs(ui._zones or {}) do
        if zone.def.ges == "tap" then overrides[#overrides + 1] = id
        elseif zone.def.ges == "swipe" then swipe_overrides[#swipe_overrides + 1] = id
        elseif zone.def.ges == "touch" then touch_overrides[#touch_overrides + 1] = id end
    end
    ui:registerTouchZones{{ id = "zen_reference_return", ges = "tap",
        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 }, overrides = overrides,
        handler = function(ges) return button:onTap(ges) end,
    }, { id = "zen_reference_return_swipe", ges = "swipe",
        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 }, overrides = swipe_overrides,
        handler = function(ges) return button:onSwipe(ges) end,
    }, { id = "zen_reference_return_touch", ges = "touch",
        screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 }, overrides = touch_overrides,
        handler = function(ges) return button:onTouch(ges) end,
    }}
end

return ReturnButton
