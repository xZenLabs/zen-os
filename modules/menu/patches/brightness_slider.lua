-- Brightness (frontlight) slider section for the Quick Settings panel.
-- Returns a populated VerticalGroup and registers slider/toggle refs.
--
-- Usage:
--   local build_brightness_slider = require("modules/menu/patches/brightness_slider")
--   local group = build_brightness_slider(touch_menu, {
--       inner_width, slider_width, small_btn_width, toggle_width, slider_gap,
--       medium_font, small_btn_font, powerd, refs,
--   })

local Blitbuffer      = require("ffi/blitbuffer")
local Button          = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local ZenSlider       = require("common/ui/zen_slider")
local library_font    = require("modules/filebrowser/patches/library_font")
local _               = require("gettext")
local Screen          = Device.screen

local function build_brightness_slider(touch_menu, opts)
    local inner_width     = opts.inner_width
    local slider_width    = opts.slider_width
    local small_btn_width = opts.small_btn_width
    local slider_gap      = opts.slider_gap
    local medium_font     = opts.medium_font
    local small_btn_size  = opts.small_btn_size
    local powerd          = opts.powerd
    local refs            = opts.refs
    local show_parent     = touch_menu.show_parent

    local fl = {
        min = 0,
        hardware_min = powerd.fl_min or 0,
        max = powerd.fl_max,
        cur = powerd:frontlightIntensity(),
    }

    -- Split label: static prefix + fixed-width number box so the prefix
    -- never shifts when the number changes width (e.g. 9 → 10).
    local fl_prefix_text = _("Brightness") .. ": "
    local fl_drag_prefix = TextWidget:new{ text = fl_prefix_text, face = medium_font }
    local fl_drag_prefix_w = fl_drag_prefix:getSize().w
    local fl_drag_num = TextWidget:new{ text = tostring(fl.cur), face = medium_font }
    local fl_max_num_sample = TextWidget:new{ text = tostring(fl.max), face = medium_font }
    local fl_drag_max_num_w = fl_max_num_sample:getSize().w
    fl_max_num_sample:free()
    local fl_drag_ref_w = fl_drag_prefix_w + fl_drag_max_num_w
    local fl_label_h = fl_drag_prefix:getSize().h
    local fl_num_box = LeftContainer:new{
        dimen = Geom:new{ w = fl_drag_max_num_w, h = fl_label_h },
        fl_drag_num,
    }
    local fl_label_group = HorizontalGroup:new{
        fl_drag_prefix,
        fl_num_box,
    }

    local fl_progress = ZenSlider:new{
        width     = slider_width,
        value     = fl.cur,
        value_min = fl.min,
        value_max = fl.max,
        show_parent = show_parent,
    }
    local fl_button_height = fl_progress:getSize().h

    local fl_minus = Button:new{
        text           = "−",
        text_font_face = library_font.getFontName(),
        text_font_size = small_btn_size,
        text_font_bold = false,
        width          = small_btn_width,
        height         = fl_button_height,
        bordersize     = 0,
        show_parent    = show_parent,
        callback       = function() end, -- placeholder, wired below
    }

    local fl_label_fn = nil
    local fl_row  -- forward-declare for on_change closure

    local function setBrightness(intensity)
        if intensity ~= fl.min and intensity == fl.cur then return end
        intensity = math.max(fl.min, math.min(fl.max, intensity))
        if intensity > 0 then intensity = math.max(fl.hardware_min, intensity) end
        if intensity <= 0 and type(powerd.turnOffFrontlight) == "function" then
            powerd:turnOffFrontlight()
        else
            powerd:setIntensity(intensity)
            if type(powerd.isFrontlightOff) == "function"
                    and powerd:isFrontlightOff()
                    and type(powerd.turnOnFrontlight) == "function" then
                powerd:turnOnFrontlight()
            end
        end
        if type(powerd.updateResumeFrontlightState) == "function" then
            powerd:updateResumeFrontlightState()
        end
        fl.cur = intensity
        if fl.cur > fl.min then fl.prev_non_min = fl.cur end
        if fl_label_fn then UIManager:unschedule(fl_label_fn) ; fl_label_fn = nil end
        fl_progress:setValue(fl.cur)
        fl_drag_num:setText(tostring(fl.cur))
        UIManager:setDirty(show_parent, "ui", touch_menu.dimen)
    end

    fl.prev_non_min = fl.cur > fl.min and fl.cur or math.min(fl.max, fl.min + 1)
    fl_progress.on_drag_start = function()
        fl.dragging = true
        if fl.cur > fl.min then fl.prev_non_min = fl.cur end
    end
    fl_progress.on_drag_end = function()
        fl.dragging = false
        if fl.cur > fl.min then fl.prev_non_min = fl.cur end
    end

    -- During drag: paint directly to Screen.bb and push A2 refresh via
    -- setDirty(nil) — bypasses the widget tree entirely, so no competing
    -- GL16 from other widgets can cause flicker.  A2 completes in ~60ms
    -- and renders the pure B/W slider content without ghosting.
    -- On release / tap: full menu GL16 refresh to update label + slider.
    fl_progress.on_change = function(v)
        powerd:setIntensity(v)
        fl.cur = v
        if fl.cur > fl.min and not fl.dragging then fl.prev_non_min = fl.cur end
        if fl_progress._dragging then
            fl_progress:paintTo(Screen.bb, fl_progress.dimen.x, fl_progress.dimen.y)
            -- Only repaint the number — prefix is static in the framebuffer.
            local row_gap_h = Screen:scaleBySize(10)
            local lh = fl_drag_prefix:getSize().h
            local row_h = fl_row and fl_row:getSize().h or fl_progress.dimen.h
            local row_top = fl_progress.dimen.y - math.floor((row_h - fl_progress.dimen.h) / 2)
            local label_y = row_top - row_gap_h - lh
            local sx = fl_progress.dimen.x
            local sw = fl_progress.dimen.w
            local num_x = sx + math.floor((sw - fl_drag_ref_w) / 2) + fl_drag_prefix_w
            Screen.bb:paintRect(num_x, label_y, fl_drag_max_num_w, lh, Blitbuffer.COLOR_WHITE)
            fl_drag_num:setText(tostring(fl.cur))
            fl_drag_num:paintTo(Screen.bb, num_x, label_y)
            -- Single A2 covering label + slider (two back-to-back A2 calls
            -- can race on Kobo, causing the second refresh to be dropped).
            UIManager:setDirty(nil, "fast", Geom:new{
                x = fl_progress.dimen.x,
                y = label_y,
                w = fl_progress.dimen.w,
                h = fl_progress.dimen.y + fl_progress.dimen.h - label_y,
            })
        else
            if fl_label_fn then UIManager:unschedule(fl_label_fn) ; fl_label_fn = nil end
            fl_drag_num:setText(tostring(fl.cur))
            UIManager:setDirty(show_parent, "ui", touch_menu.dimen)
        end
    end

    fl_minus.callback = function() setBrightness(fl.cur - 1) end
    fl_minus.hold_callback = function() setBrightness(0) end
    local fl_plus = Button:new{
        text           = "＋",
        text_font_face = library_font.getFontName(),
        text_font_size = small_btn_size,
        text_font_bold = false,
        width          = small_btn_width,
        height         = fl_button_height,
        bordersize     = 0,
        show_parent    = show_parent,
        callback       = function() setBrightness(fl.cur > fl.min and fl.cur + 1 or fl.prev_non_min) end,
    }

    local row_gap = VerticalSpan:new{ width = Screen:scaleBySize(10) }

    local fl_cap_row = CenterContainer:new{
        dimen = Geom:new{ w = inner_width, h = fl_label_h },
        fl_label_group,
    }
    fl_row = HorizontalGroup:new{
        align = "center",
        fl_minus,
        HorizontalSpan:new{ width = slider_gap },
        fl_progress,
        HorizontalSpan:new{ width = slider_gap },
        fl_plus,
    }

    refs.fl_progress   = fl_progress
    refs.fl_state      = fl
    refs.setBrightness = setBrightness
    table.insert(refs.sliders, { slider = fl_progress })

    local section_pad = VerticalSpan:new{ width = Screen:scaleBySize(10) }
    local group = VerticalGroup:new{ align = "center" }
    table.insert(group, section_pad)
    table.insert(group, fl_cap_row)
    table.insert(group, row_gap)
    table.insert(group, fl_row)
    table.insert(group, section_pad)
    return group
end

return build_brightness_slider
