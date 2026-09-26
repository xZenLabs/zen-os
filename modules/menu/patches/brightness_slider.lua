-- One Controls slider for brightness and, when available, warmth.

local Blitbuffer      = require("ffi/blitbuffer")
local Button          = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local IconWidget      = require("ui/widget/iconwidget")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local ZenSlider       = require("common/ui/zen_slider")
local library_font    = require("modules/filebrowser/patches/library_font")
local utils           = require("common/utils")
local WidgetResources = require("common/widget_resources")
local _               = require("gettext")
local Screen          = Device.screen

local function build_brightness_slider(touch_menu, opts)
    local powerd = opts.powerd
    local refs = opts.refs
    local show_parent = touch_menu.show_parent
    local show_fl = opts.show_frontlight ~= false
    local show_nl = opts.show_warmth == true and opts.unified ~= false
    local fl = show_fl and {
        min = 0,
        hardware_min = powerd.fl_min or 0,
        max = powerd.fl_max,
        cur = powerd:frontlightIntensity(),
    }
    local nl = show_nl and {
        min = powerd.fl_warmth_min,
        max = powerd.fl_warmth_max,
        cur = powerd:toNativeWarmth(powerd:frontlightWarmth()),
    }
    local mode = show_fl and "brightness" or "warmth"
    local selected = fl or nl
    local labels = { brightness = _("Brightness") .. ": ", warmth = _("Warmth") .. ": " }

    local prefix = TextWidget:new{ text = labels[mode], face = opts.medium_font }
    local prefix_width = prefix:getSize().w
    if fl and nl then
        local sample = TextWidget:new{ text = labels.warmth, face = opts.medium_font }
        prefix_width = math.max(prefix_width, sample:getSize().w)
        sample:free()
    end
    local number = TextWidget:new{ text = tostring(selected.cur), face = opts.medium_font }
    local max_value = math.max(fl and fl.max or 0, nl and nl.max or 0)
    local sample = TextWidget:new{ text = tostring(max_value), face = opts.medium_font }
    local number_width = math.max(number:getSize().w, sample:getSize().w)
    sample:free()
    local label_h = math.max(prefix:getSize().h, number:getSize().h)
    local label_width = prefix_width + number_width
    local number_box = LeftContainer:new{ dimen = Geom:new{ w = number_width, h = label_h }, number }
    local label = HorizontalGroup:new{
        CenterContainer:new{ dimen = Geom:new{ w = prefix_width, h = label_h }, prefix },
        number_box,
    }

    local progress = ZenSlider:new{
        width = opts.slider_width,
        value = selected.cur,
        value_min = selected.min,
        value_max = selected.max,
        show_parent = show_parent,
    }

    if fl then
        fl.prev_non_min = fl.cur > fl.min and fl.cur or math.min(fl.max, fl.min + 1)
    end

    local function setSelected(value)
        if mode == "brightness" then
            if value ~= fl.min and value == fl.cur then return end
            value = math.max(fl.min, math.min(fl.max, value))
            if value > 0 then value = math.max(fl.hardware_min, value) end
            if value <= 0 and type(powerd.turnOffFrontlight) == "function" then
                powerd:turnOffFrontlight()
            else
                powerd:setIntensity(value)
                if type(powerd.isFrontlightOff) == "function"
                        and powerd:isFrontlightOff()
                        and type(powerd.turnOnFrontlight) == "function" then
                    powerd:turnOnFrontlight()
                end
            end
            if type(powerd.updateResumeFrontlightState) == "function" then
                powerd:updateResumeFrontlightState()
            end
        else
            if value == nl.cur then return end
            value = math.max(nl.min, math.min(nl.max, value))
            powerd:setWarmth(powerd:fromNativeWarmth(value))
        end
        selected.cur = value
        if mode == "brightness" and value > fl.min then fl.prev_non_min = value end
        progress:setValue(value)
        number:setText(tostring(value))
        UIManager:setDirty(show_parent, "ui", touch_menu.dimen)
    end

    progress.on_drag_start = function()
        if mode == "brightness" then
            fl.dragging = true
            if fl.cur > fl.min then fl.prev_non_min = fl.cur end
        end
    end
    progress.on_drag_end = function()
        if mode == "brightness" then
            fl.dragging = false
            if fl.cur > fl.min then fl.prev_non_min = fl.cur end
        end
    end

    progress.on_change = function(value)
        if mode == "brightness" then
            powerd:setIntensity(value)
            fl.cur = value
            if value > fl.min and not fl.dragging then fl.prev_non_min = value end
        else
            powerd:setWarmth(powerd:fromNativeWarmth(value))
            nl.cur = value
        end
        if progress._dragging then
            progress:paintTo(Screen.bb, progress.dimen.x, progress.dimen.y)
            local number_x, label_y = number_box.dimen.x, number_box.dimen.y
            Screen.bb:paintRect(number_x, label_y, number_width, label_h, Blitbuffer.COLOR_WHITE)
            number:setText(tostring(value))
            number:paintTo(Screen.bb, number_x, label_y)
            local dirty_x = math.min(progress.dimen.x, number_x)
            UIManager:setDirty(nil, "fast", Geom:new{
                x = dirty_x,
                y = label_y,
                w = math.max(progress.dimen.x + progress.dimen.w, number_x + number_width) - dirty_x,
                h = progress.dimen.y + progress.dimen.h - label_y,
            })
        else
            number:setText(tostring(value))
            UIManager:setDirty(show_parent, "ui", touch_menu.dimen)
        end
    end

    local function adjust_button(text, callback, hold_callback)
        return Button:new{
            text = text,
            text_font_face = library_font.getFontName(),
            text_font_size = opts.small_btn_size,
            text_font_bold = false,
            width = opts.small_btn_width,
            height = progress:getSize().h,
            bordersize = 0,
            show_parent = show_parent,
            callback = callback,
            hold_callback = hold_callback,
        }
    end
    local minus = adjust_button("−", function() setSelected(selected.cur - 1) end,
        function() setSelected(0) end)
    local plus = adjust_button("＋", function()
        setSelected(mode == "brightness" and selected.cur == fl.min
            and fl.prev_non_min or selected.cur + 1)
    end)
    local row = HorizontalGroup:new{
        align = "center",
        minus,
        HorizontalSpan:new{ width = opts.slider_gap },
        progress,
        HorizontalSpan:new{ width = opts.slider_gap },
        plus,
    }

    refs.fl_progress = fl and progress or nil
    refs.nl_progress = nl and progress or nil
    refs.fl_state = fl
    refs.nl_state = nl
    refs.setBrightness = fl and function(value)
        if mode == "brightness" then setSelected(value) end
    end or nil
    refs.setWarmth = nl and function(value)
        if mode == "warmth" then setSelected(value) end
    end or nil
    table.insert(refs.sliders, { slider = progress })

    local group = VerticalGroup:new{ align = "center" }
    table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(10) })
    local label_row

    if fl and nl then
        local src = debug.getinfo(1, "S").source or ""
        local root = src:sub(1, 1) == "@" and src:sub(2):match("^(.*)/modules/")
        local _icons_dir = root and root .. "/icons/"
        local icon_size = Screen:scaleBySize(24)
        local pad_v = Screen:scaleBySize(4)

        local function mode_button(icon_name, active)
            return FrameContainer:new{
                padding_top = pad_v,
                padding_bottom = pad_v,
                padding_left = Screen:scaleBySize(20),
                padding_right = Screen:scaleBySize(20),
                bordersize = 0,
                background = Blitbuffer.COLOR_WHITE,
                invert = active,
                IconWidget:new{
                    file = utils.resolveLocalIcon(_icons_dir, icon_name),
                    width = icon_size,
                    height = icon_size,
                },
            }
        end

        local brightness_button = mode_button("brightness", true)
        local warmth_button = mode_button("warmth", false)
        local divider = LineWidget:new{
            dimen = Geom:new{ w = Screen:scaleBySize(1), h = icon_size + pad_v * 2 },
            background = Blitbuffer.COLOR_DARK_GRAY,
            direction = "vert",
        }
        local switch = FrameContainer:new{
            padding = 0,
            margin = 0,
            bordersize = Screen:scaleBySize(2),
            background = Blitbuffer.COLOR_WHITE,
            radius = Screen:scaleBySize(4),
            HorizontalGroup:new{ align = "center", brightness_button, divider, warmth_button },
        }
        WidgetResources.paintFrameBorderOnTop(switch)
        if opts.centered then
            table.insert(group, switch)
            table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(10) })
            label_row = CenterContainer:new{ dimen = Geom:new{ w = opts.inner_width, h = label_h }, label }
        else
            label_row = HorizontalGroup:new{
                align = "center",
                label,
                HorizontalSpan:new{ width = math.max(0, opts.inner_width - label_width - switch:getSize().w) },
                switch,
            }
        end

        local function selectMode(next_mode)
            if mode == next_mode then return end
            mode = next_mode
            selected = mode == "brightness" and fl or nl
            selected.cur = mode == "brightness" and powerd:frontlightIntensity()
                or powerd:toNativeWarmth(powerd:frontlightWarmth())
            if mode == "brightness" and selected.cur > fl.min then
                fl.prev_non_min = selected.cur
            end
            progress.value_min = selected.min
            progress.value_max = selected.max
            progress:setValue(selected.cur)
            prefix:setText(labels[mode])
            number:setText(tostring(selected.cur))
            brightness_button.invert = mode == "brightness"
            warmth_button.invert = mode == "warmth"
            UIManager:setDirty(show_parent, "ui", touch_menu.dimen)
        end
        table.insert(refs.toggles, {
            toggle = brightness_button,
            callback = function() selectMode("brightness") end,
        })
        table.insert(refs.toggles, {
            toggle = warmth_button,
            callback = function() selectMode("warmth") end,
        })
    else
        label_row = CenterContainer:new{ dimen = Geom:new{ w = opts.inner_width, h = label_h }, label }
    end

    table.insert(group, label_row)
    table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(10) })
    table.insert(group, row)
    table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(10) })
    return group
end

return build_brightness_slider
