local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local Hatching = require("common/ui/hatching")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local UIManager = require("ui/uimanager")

local Screen = Device.screen

local MenuCoachmark = InputContainer:extend{
    modal = true,
    steps = nil,
    on_complete = nil,
    on_cancel = nil,
}

local function valid_dimen(dimen)
    return type(dimen) == "table"
        and type(dimen.x) == "number" and type(dimen.y) == "number"
        and type(dimen.w) == "number" and dimen.w > 0
        and type(dimen.h) == "number" and dimen.h > 0
end

function MenuCoachmark:init()
    assert(type(self.steps) == "table" and #self.steps > 0, "coachmark steps required")

    self._step = 1
    self.dimen = Geom:new{
        x = 0,
        y = 0,
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }
    self.ges_events.TapAdvance = {
        GestureRange:new{ ges = "tap", range = self.dimen },
    }
    if Device:hasKeys() then
        self.key_events.Advance = {
            { Device.input.group.Any },
        }
    end
    self:_buildCallout()
end

function MenuCoachmark:_targetDimen()
    local target = self.steps[self._step] and self.steps[self._step].target
    if type(target) == "function" then target = target() end
    if type(target) == "table" and target.dimen then target = target.dimen end
    return valid_dimen(target) and target or nil
end

function MenuCoachmark:_buildCallout()
    if self._callout then self._callout:free() end

    local sw = self.dimen.w
    local sh = self.dimen.h
    local margin = Screen:scaleBySize(24)
    local padding = Size.padding.large
    local border = Size.border.window
    local outer_width = math.min(math.floor(sw * 0.82), sw - margin * 2)
    local text_width = math.max(1, outer_width - (padding + border) * 2)
    local text = self.steps[self._step].text or ""

    self._callout = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        color = Blitbuffer.COLOR_BLACK,
        radius = Size.radius.window,
        bordersize = border,
        padding = padding,
        TextBoxWidget:new{
            text = text,
            face = Font:getFace("infofont"),
            width = text_width,
            alignment = "left",
        },
    }

    local size = self._callout:getSize()
    local target = self:_targetDimen()
    local highlight = target and self:_highlightDimen(target)
    local target_gap = Screen:scaleBySize(4)
    local x = highlight
        and math.floor(highlight.x + (highlight.w - size.w) / 2)
        or math.floor((sw - size.w) / 2)
    x = math.max(margin, math.min(x, sw - size.w - margin))
    local y = math.floor((sh - size.h) / 2)
    if highlight then
        local below = highlight.y + highlight.h + target_gap
        local above = highlight.y - target_gap - size.h
        if below + size.h <= sh - margin then
            y = below
        elseif above >= margin then
            y = above
        elseif sh - margin - highlight.y - highlight.h >= highlight.y - margin then
            y = math.min(below, sh - size.h - margin)
        else
            y = math.max(margin, above)
        end
    end
    y = math.max(margin, math.min(y, sh - size.h - margin))

    self._callout_dimen = Geom:new{ x = x, y = y, w = size.w, h = size.h }
end

function MenuCoachmark:_highlightDimen(target)
    target = target or self:_targetDimen()
    if not target then return nil end
    local pad = Screen:scaleBySize(14)
    return Geom:new{
        x = math.max(0, target.x - pad),
        y = math.max(0, target.y - pad),
        w = math.min(self.dimen.w, target.x + target.w + pad) - math.max(0, target.x - pad),
        h = math.min(self.dimen.h, target.y + target.h + pad) - math.max(0, target.y - pad),
    }
end

function MenuCoachmark:_visibleArea()
    return self.dimen
end

function MenuCoachmark:getVisibleArea()
    return self:_visibleArea()
end

function MenuCoachmark:_paintBackdrop(bb, cutout)
    local function hatch(x, y, w, h)
        Hatching.paint(bb, x, y, w, h)
    end

    if not cutout then
        hatch(self.dimen.x, self.dimen.y, self.dimen.w, self.dimen.h)
        return
    end

    local right = cutout.x + cutout.w
    local bottom = cutout.y + cutout.h
    hatch(self.dimen.x, self.dimen.y, self.dimen.w, cutout.y - self.dimen.y)
    hatch(self.dimen.x, bottom, self.dimen.w, self.dimen.y + self.dimen.h - bottom)
    hatch(self.dimen.x, cutout.y, cutout.x - self.dimen.x, cutout.h)
    hatch(right, cutout.y, self.dimen.x + self.dimen.w - right, cutout.h)
end

function MenuCoachmark:paintTo(bb)
    local target = self:_targetDimen()
    local highlight = self:_highlightDimen()
    self:_paintBackdrop(bb, highlight)
    if target then
        local pad = Screen:scaleBySize(10)
        local halo = math.max(3, Screen:scaleBySize(4))
        local border = math.max(4, Screen:scaleBySize(6))
        local x = target.x - pad
        local y = target.y - pad
        local w = target.w + pad * 2
        local h = target.h + pad * 2
        bb:paintBorder(x - halo, y - halo, w + halo * 2, h + halo * 2,
            halo, Blitbuffer.COLOR_WHITE)
        bb:paintBorder(x, y, w, h, border, Blitbuffer.COLOR_BLACK)
    end
    self._callout:paintTo(bb, self._callout_dimen.x, self._callout_dimen.y)
end

function MenuCoachmark:_advance()
    if self._step < #self.steps then
        self._step = self._step + 1
        self:_buildCallout()
        UIManager:setDirty("all", function() return "ui", self.dimen end)
    else
        self._finished = true
        UIManager:close(self)
    end
    return true
end

function MenuCoachmark:onTapAdvance()
    return self:_advance()
end

function MenuCoachmark:onAdvance()
    return self:_advance()
end

function MenuCoachmark:onShow()
    UIManager:setDirty(self, function() return "ui", self:_visibleArea() end)
    return true
end

function MenuCoachmark:onCloseWidget()
    local dirty = self:_visibleArea()
    if self._callout then
        self._callout:free()
        self._callout = nil
    end
    UIManager:setDirty(nil, function() return "ui", dirty end)
    local callback = self._finished and self.on_complete or self.on_cancel
    self.on_complete = nil
    self.on_cancel = nil
    if callback then
        callback()
    end
end

function MenuCoachmark:_cancelForResize()
    if self._closing then return true end
    self._closing = true
    UIManager:close(self)
    return true
end

function MenuCoachmark:onSetDimensions()
    return self:_cancelForResize()
end

function MenuCoachmark:onScreenResize()
    return self:_cancelForResize()
end

return MenuCoachmark
