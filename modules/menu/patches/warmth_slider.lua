-- Warmth (natural light) slider section for the Quick Settings panel.
-- Returns a populated VerticalGroup and registers slider/toggle refs.
-- The caller is responsible for checking Device:hasNaturalLight() before calling.
--
-- Usage:
--   local build_warmth_slider = require("modules/menu/patches/warmth_slider")
--   if config.show_warmth and Device:hasNaturalLight() then
--       warmth_group = build_warmth_slider(touch_menu, { ... })
--   end

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

local function build_warmth_slider(touch_menu, opts)
    local inner_width     = opts.inner_width
    local slider_width    = opts.slider_width
    local small_btn_width = opts.small_btn_width
    local slider_gap      = opts.slider_gap
    local medium_font     = opts.medium_font
    local small_btn_size  = opts.small_btn_size
    local powerd          = opts.powerd
    local refs            = opts.refs
    local show_parent     = touch_menu.show_parent

    local nl = {
        min = powerd.fl_warmth_min,
        max = powerd.fl_warmth_max,
        cur = powerd:toNativeWarmth(powerd:frontlightWarmth()),
    }

    -- Split label: static prefix + fixed-width number box so the prefix
    -- never shifts when the number changes width (e.g. 9 → 10).
    local nl_prefix_text = _("Warmth") .. ": "
    local nl_drag_prefix = TextWidget:new{ text = nl_prefix_text, face = medium_font }
    local nl_drag_prefix_w = nl_drag_prefix:getSize().w
    local nl_drag_num = TextWidget:new{ text = tostring(nl.cur), face = medium_font }
    local nl_max_num_sample = TextWidget:new{ text = tostring(nl.max), face = medium_font }
    local nl_drag_max_num_w = nl_max_num_sample:getSize().w
    nl_max_num_sample:free()
    local nl_drag_ref_w = nl_drag_prefix_w + nl_drag_max_num_w
    local nl_label_h = nl_drag_prefix:getSize().h
    local nl_num_box = LeftContainer:new{
        dimen = Geom:new{ w = nl_drag_max_num_w, h = nl_label_h },
        nl_drag_num,
    }
    local nl_label_group = HorizontalGroup:new{
        nl_drag_prefix,
        nl_num_box,
    }

    local nl_progress = ZenSlider:new{
        width     = slider_width,
        value     = nl.cur,
        value_min = nl.min,
        value_max = nl.max,
        show_parent = show_parent,
    }
    local nl_button_height = nl_progress:getSize().h

    local nl_label_fn = nil
    local nl_row  -- forward-declare for on_change closure

    local function setWarmth(warmth)
        if warmth == nl.cur then return end
        warmth = math.max(nl.min, math.min(nl.max, warmth))
        powerd:setWarmth(powerd:fromNativeWarmth(warmth))
        nl.cur = warmth
        if nl.cur > nl.min then nl.prev_non_min = nl.cur end
        if nl_label_fn then UIManager:unschedule(nl_label_fn) ; nl_label_fn = nil end
        nl_progress:setValue(nl.cur)
        nl_drag_num:setText(tostring(nl.cur))
        UIManager:setDirty(show_parent, "ui", touch_menu.dimen)
    end

    nl.prev_non_min = nl.cur > nl.min and nl.cur or math.min(nl.max, nl.min + 1)

    -- During drag: paint directly to Screen.bb and push A2 refresh via
    -- setDirty(nil) — bypasses the widget tree entirely, so no competing
    -- GL16 from other widgets can cause flicker.
    -- On release / tap: full menu GL16 refresh to update label + slider.
    nl_progress.on_change = function(v)
        powerd:setWarmth(powerd:fromNativeWarmth(v))
        nl.cur = v
        if nl.cur > nl.min then nl.prev_non_min = nl.cur end
        if nl_progress._dragging then
            nl_progress:paintTo(Screen.bb, nl_progress.dimen.x, nl_progress.dimen.y)
            -- Only repaint the number — prefix is static in the framebuffer.
            local row_gap_h = Screen:scaleBySize(10)
            local lh = nl_drag_prefix:getSize().h
            local row_h = nl_row and nl_row:getSize().h or nl_progress.dimen.h
            local row_top = nl_progress.dimen.y - math.floor((row_h - nl_progress.dimen.h) / 2)
            local label_y = row_top - row_gap_h - lh
            local sx = nl_progress.dimen.x
            local sw = nl_progress.dimen.w
            local num_x = sx + math.floor((sw - nl_drag_ref_w) / 2) + nl_drag_prefix_w
            Screen.bb:paintRect(num_x, label_y, nl_drag_max_num_w, lh, Blitbuffer.COLOR_WHITE)
            nl_drag_num:setText(tostring(nl.cur))
            nl_drag_num:paintTo(Screen.bb, num_x, label_y)
            -- Single A2 covering label + slider (two back-to-back A2 calls
            -- can race on Kobo, causing the second refresh to be dropped).
            UIManager:setDirty(nil, "fast", Geom:new{
                x = nl_progress.dimen.x,
                y = label_y,
                w = nl_progress.dimen.w,
                h = nl_progress.dimen.y + nl_progress.dimen.h - label_y,
            })
        else
            if nl_label_fn then UIManager:unschedule(nl_label_fn) ; nl_label_fn = nil end
            nl_drag_num:setText(tostring(nl.cur))
            UIManager:setDirty(show_parent, "ui", touch_menu.dimen)
        end
    end

    local nl_minus = Button:new{
        text           = "−",
        text_font_face = library_font.getFontName(),
        text_font_size = small_btn_size,
        text_font_bold = false,
        width          = small_btn_width,
        height         = nl_button_height,
        bordersize     = 0,
        show_parent    = show_parent,
        allow_flash    = false,
        callback       = function() setWarmth(nl.cur - 1) end,
        hold_callback  = function() setWarmth(0) end,
    }
    local nl_plus = Button:new{
        text           = "＋",
        text_font_face = library_font.getFontName(),
        text_font_size = small_btn_size,
        text_font_bold = false,
        width          = small_btn_width,
        height         = nl_button_height,
        bordersize     = 0,
        show_parent    = show_parent,
        allow_flash    = false,
        callback       = function() setWarmth(nl.cur + 1) end,
    }

    local row_gap = VerticalSpan:new{ width = Screen:scaleBySize(10) }

    local nl_cap_row = CenterContainer:new{
        dimen = Geom:new{ w = inner_width, h = nl_label_h },
        nl_label_group,
    }
    nl_row = HorizontalGroup:new{
        align = "center",
        nl_minus,
        HorizontalSpan:new{ width = slider_gap },
        nl_progress,
        HorizontalSpan:new{ width = slider_gap },
        nl_plus,
    }

    refs.nl_progress = nl_progress
    refs.nl_state    = nl
    refs.setWarmth   = setWarmth
    table.insert(refs.sliders, { slider = nl_progress })

    local group = VerticalGroup:new{ align = "center" }
    table.insert(group, VerticalSpan:new{ width = Screen:scaleBySize(14) })
    table.insert(group, nl_cap_row)
    table.insert(group, row_gap)
    table.insert(group, nl_row)
    return group
end

return build_warmth_slider
