local Blitbuffer = require("ffi/blitbuffer")
local Accent = require("common/ui/accent")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local ButtonLabelWidth = require("common/ui/button_label_width")
local ButtonFeedback = require("common/ui/button_feedback")
local utils = require("common/utils")
local Screen = Device.screen
local root = require("common/plugin_root")
local function icon_spec(name)
    name = type(name) == "string" and name ~= "" and name or "app_launcher"
    if type(name) == "string" and name:sub(1, 1) == "/" then return name end
    local path = root and utils.resolveIcon(root .. "/icons/", name)
    return path, name
end

local LauncherCell = InputContainer:extend{}

function LauncherCell:init()
    self.dimen = self.dimen or Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        TapSelect = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
    }
end

function LauncherCell:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    self[1]:paintTo(bb, x, y)
end

function LauncherCell:onTapSelect()
    if self.callback then
        self.callback()
    end
    return true
end

function LauncherCell:onFocus()
    self.frame.invert = true
    if self.dimen then UIManager:setDirty(nil, "fast", self.dimen) end
    return true
end

function LauncherCell:onUnfocus()
    self.frame.invert = false
    if self.dimen then UIManager:setDirty(nil, "fast", self.dimen) end
    return true
end

local function make_cell(opts)
    local icon_path, icon_name = icon_spec(opts.icon)
    local icon_size = opts.icon_size
    local rendered_icon_size = math.floor(
        icon_size * utils.iconOpticalScale(opts.icon) + 0.5)
    local circle_size = opts.circle_size
    local circle_border = opts.circle_border
    local active = opts.active == true and not opts.dimmed
    local label_face = opts.label_face
    local fg = opts.dim and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK
    local show_label = opts.show_label ~= false
    local icon = IconWidget:new{
        file = icon_path or nil,
        icon = icon_path and nil or icon_name,
        width = rendered_icon_size,
        height = rendered_icon_size,
        alpha = true,
    }
    local border = circle_border
    local icon_circle = FrameContainer:new{
        width = circle_size,
        height = circle_size,
        padding = 0,
        bordersize = border,
        radius = math.floor(circle_size / 2),
        background = opts.dimmed and Blitbuffer.COLOR_GRAY or Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{
                w = circle_size - border * 2,
                h = circle_size - border * 2,
            },
            icon,
        },
    }
    Accent.styleButton(icon_circle, icon, active)
    local content_items = {
        align = "center",
        icon_circle,
    }
    if show_label then
        local label_max_width = ButtonLabelWidth.maxWidth(opts.cell_w, opts.label_side_padding)
        local label = TextWidget:new{
            text = opts.label,
            face = label_face,
            fgcolor = fg,
            max_width = label_max_width,
        }
        table.insert(content_items, 1, VerticalSpan:new{ width = opts.pad })
        content_items[#content_items + 1] = VerticalSpan:new{ width = Screen:scaleBySize(4) }
        content_items[#content_items + 1] = label
    end
    local content = VerticalGroup:new(content_items)
    local frame = FrameContainer:new{
        width = opts.cell_w,
        height = opts.cell_h,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        padding = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = opts.cell_w, h = opts.cell_h },
            content,
        },
    }
    local cell = LauncherCell:new{
        width = opts.cell_w,
        height = opts.cell_h,
        dimen = Geom:new{ w = opts.cell_w, h = opts.cell_h },
        callback = opts.callback and function()
            ButtonFeedback.flash(icon_circle.dimen, icon_circle.radius)
            opts.callback()
        end or nil,
        frame = frame,
        frame,
    }
    return cell
end


return make_cell
