local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local ZenButton = require("common/ui/zen_button")

local ZenActionButton = InputContainer:extend{}

function ZenActionButton:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function ZenActionButton:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if self.outlined then
        ZenButton.paintOutlined(bb, x, y, self.width, self.height, self.text, self.font_size, self.radius, nil, self.width)
    else
        ZenButton.paintFilled(bb, x, y, self.width, self.height, self.text, self.font_size, self.radius, self.width)
    end
    if self.invert then bb:invertRect(x, y, self.width, self.height) end
end

function ZenActionButton:onTapSelect()
    if self.callback then self.callback() end
    return true
end

function ZenActionButton:onFocus()
    self.invert = true
    UIManager:setDirty(nil, "fast", self.dimen)
    return true
end

function ZenActionButton:onUnfocus()
    self.invert = false
    UIManager:setDirty(nil, "fast", self.dimen)
    return true
end

return ZenActionButton
