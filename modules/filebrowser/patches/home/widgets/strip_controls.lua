local Background = require("common/ui/background")
local Blitbuffer = require("ffi/blitbuffer")
local ButtonModel = require("common/nav_button_model")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local TextWidget = require("ui/widget/textwidget")
local WidgetResources = require("common/widget_resources")
local icons = require("common/inline_icon_map")
local library_font = require("modules/filebrowser/patches/library_font")

local M = {}

local COMPACT_IDS = { page_left = true, page_right = true }

local function is_icon_entry(entry)
    return entry.id == "search" or COMPACT_IDS[entry.id] == true
end

local function visible_entries(controls)
    local entries = {}
    local seen = {}
    for _i, id in ipairs(controls.order or {}) do
        if #entries >= 7 then break end
        local entry = not seen[id] and controls.show_buttons[id] == true
            and ButtonModel.find(controls, id) or nil
        if entry and ButtonModel.isAvailable(entry) then
            entries[#entries + 1] = entry
            seen[id] = true
        end
    end
    return entries
end

local function control_text_style(controls)
    local configured = type(controls.text_style) == "table" and controls.text_style or {}
    local font_face = type(configured.font_face) == "string"
        and configured.font_face ~= "" and configured.font_face or "default"
    local font_size = math.max(6, math.min(24, math.floor(
        (tonumber(configured.font_size) or 10) + 0.5)))
    return {
        font_face = font_face,
        font_size = font_size,
        bold = configured.bold == true,
    }
end

local function get_control_face(style, size)
    if style.font_face == "default" then return library_font.getFace(size) end
    return Font:getFace(style.font_face, size) or library_font.getFace(size)
end

local function fit_face(labels, width, style, maximum, minimum)
    local size = maximum or Device.screen:scaleBySize(10)
    minimum = minimum or Device.screen:scaleBySize(7)
    while size > minimum do
        local face = get_control_face(style, size)
        local fits = true
        for _i, label in ipairs(labels) do
            local probe = TextWidget:new{ text = label, face = face, bold = style.bold }
            local needed = probe:getSize().w
            WidgetResources.free(probe)
            if needed > width - Device.screen:scaleBySize(6) then
                fits = false
                break
            end
        end
        if fits then return face end
        size = size - 1
    end
    return get_control_face(style, minimum)
end

local function hitbox_contains(dimen, pos, padding)
    if not (dimen and pos) then return false end
    local left = (dimen.x or 0) - (padding.left or 0)
    local top = (dimen.y or 0) - (padding.top or 0)
    local right = (dimen.x or 0) + dimen.w + (padding.right or 0)
    local bottom = (dimen.y or 0) + dimen.h + (padding.bottom or 0)
    return pos.x >= left and pos.x < right and pos.y >= top and pos.y < bottom
end

local function control_widget(content, width, height, tap_callback, hold_callback, hit_padding)
    if not Device:isTouchDevice() then return content end
    local ges_events = {
        TapStripControl = {
            GestureRange:new{ ges = "tap", range = Geom:new{
                x = 0, y = 0, w = Device.screen:getWidth(), h = Device.screen:getHeight(),
            } },
        },
    }
    if type(hold_callback) == "function" then
        ges_events.HoldStripControl = {
            GestureRange:new{ ges = "hold", range = Geom:new{
                x = 0, y = 0, w = Device.screen:getWidth(), h = Device.screen:getHeight(),
            } },
        }
    end
    local input = InputContainer:new{
        dimen = Geom:new{ w = width, h = height },
        ges_events = ges_events,
    }
    input.onTapStripControl = function(self, _arg, ges)
        if not (ges and hitbox_contains(self.dimen, ges.pos, hit_padding)) then
            return false
        end
        tap_callback()
        return true
    end
    if type(hold_callback) == "function" then
        input.onHoldStripControl = function(self, _arg, ges)
            if not (ges and hitbox_contains(self.dimen, ges.pos, hit_padding)) then
                return false
            end
            return hold_callback() == true
        end
    end
    input[1] = content
    return input
end

function M.build(opts)
    local controls = opts.controls
    local entries = visible_entries(controls)
    local height = opts.height
    local border_size = math.max(2, Device.screen:scaleBySize(1))
    local inner_width = math.max(1, opts.width - border_size * 2)
    local inner_height = math.max(1, height - border_size * 2)
    local divider_size = math.max(1, Device.screen:scaleBySize(1))
    local divider_width = math.max(0, #entries - 1) * divider_size
    local compact_count = 0
    for _i, entry in ipairs(entries) do
        if COMPACT_IDS[entry.id] then
            compact_count = compact_count + 1
        end
    end
    local flexible_count = #entries - compact_count
    local compact_width = math.min(
        inner_height + Device.screen:scaleBySize(24), inner_width)
    local flexible_width = math.max(0,
        inner_width - compact_width * compact_count - divider_width)
    local labels = {}
    for _i, entry in ipairs(entries) do
        if not is_icon_entry(entry) then
            labels[#labels + 1] = ButtonModel.label(controls, entry)
        end
    end
    local text_style = control_text_style(controls)
    local fit_width = flexible_count > 0
        and math.floor(flexible_width / flexible_count) or 1
    local face = fit_face(labels, math.max(1, fit_width), text_style,
        Device.screen:scaleBySize(text_style.font_size))
    local flexible_cell_width = flexible_count > 0
        and math.floor(flexible_width / flexible_count) or 0
    local flexible_remainder = flexible_width - flexible_cell_width * flexible_count
    local row = HorizontalGroup:new{ align = "center" }
    local targets = {}
    local radius = opts.rounded == true and Device.screen:scaleBySize(4) or 0
    local side_padding = Device.screen:scaleBySize(4)
    local vertical_hit_padding = Device.screen:scaleBySize(3)
    local edge_hit_padding = Device.screen:scaleBySize(4)
    local label_index = 0
    local flexible_index = 0

    for index, entry in ipairs(entries) do
        local icon_entry = is_icon_entry(entry)
        if not icon_entry then label_index = label_index + 1 end
        if not COMPACT_IDS[entry.id] then flexible_index = flexible_index + 1 end
        local cell_width = COMPACT_IDS[entry.id] and compact_width or flexible_cell_width
            + (flexible_index <= flexible_remainder and 1 or 0)
        local active = entry.id == opts.active_id
        local content
        if icon_entry then
            local icon = entry.id == "page_left" and icons.arrow_left
                or entry.id == "page_right" and icons.arrow_right or icons.search
            content = CenterContainer:new{
                dimen = Geom:new{ w = cell_width, h = inner_height },
                TextWidget:new{
                    text = icon,
                    face = Font:getFace("smallinfofont", Device.screen:scaleBySize(14)),
                    padding = 0,
                },
            }
        else
            local label = entry.id == opts.active_id and opts.active_group
                or labels[label_index]
            local label_face = face
            if entry.id == opts.active_id and opts.active_group then
                local base_size = face.orig_size or face.size or Device.screen:scaleBySize(10)
                label_face = fit_face({ label }, cell_width, text_style, base_size,
                    math.max(Device.screen:scaleBySize(7), base_size - 1))
            end
            content = FrameContainer:new{
                width = cell_width,
                height = inner_height,
                padding = 0,
                bordersize = 0,
                background = active and Blitbuffer.COLOR_BLACK
                    or Background.tile_bg(Blitbuffer.COLOR_WHITE),
                CenterContainer:new{
                    dimen = Geom:new{ w = cell_width, h = inner_height },
                    TextWidget:new{
                        text = label,
                        face = label_face,
                        bold = text_style.bold,
                        padding = 0,
                        max_width = math.max(1, cell_width - side_padding * 2),
                        truncate_with_ellipsis = true,
                        fgcolor = active and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
                    },
                },
            }
        end
        local activate = function()
            if ButtonModel.isSource(entry) then
                return opts.on_source(entry)
            end
            return opts.on_action(entry)
        end
        local context = type(opts.on_hold) == "function" and function()
            return opts.on_hold(entry)
        end or nil
        local widget = control_widget(
            content, cell_width, inner_height, activate, context, {
                top = vertical_hit_padding,
                bottom = vertical_hit_padding,
                left = index == 1 and edge_hit_padding or 0,
                right = index == #entries and edge_hit_padding or 0,
            })
        if type(opts.prepare_focus) == "function" then
            local target = {
                key = "strip-control:" .. tostring(entry.id),
                subrow = 0,
                col = index,
                width = cell_width,
                height = inner_height,
                focus_color = active and Blitbuffer.COLOR_WHITE
                    or Blitbuffer.COLOR_BLACK,
                activate = activate,
                context = context,
            }
            widget = opts.prepare_focus(target, widget)
            targets[#targets + 1] = target
        end
        row[#row + 1] = widget
        if index < #entries then
            row[#row + 1] = LineWidget:new{
                dimen = Geom:new{ w = divider_size, h = inner_height },
                background = Blitbuffer.COLOR_BLACK,
            }
        end
    end
    local outer = FrameContainer:new{
        width = opts.width,
        height = height,
        padding = 0,
        bordersize = border_size,
        color = Blitbuffer.COLOR_BLACK,
        radius = radius,
        background = Background.tile_bg(Blitbuffer.COLOR_WHITE),
        row,
    }
    return WidgetResources.paintFrameBorderOnTop(outer), targets
end

return M
