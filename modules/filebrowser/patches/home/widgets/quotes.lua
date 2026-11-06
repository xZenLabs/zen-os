local Background = require("common/ui/background")
local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local RenderText = require("ui/rendertext")
local TextBoxWidget = require("ui/widget/textboxwidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange = require("ui/gesturerange")
local WidgetResources = require("common/widget_resources")
local _ = require("gettext")

local AUTOMATIC_MIN_LINE_HEIGHT = 0.1
local QUOTE_LINE_HEIGHT = 0.55
local LAYOUT_CACHE_MAX = 32
local layout_cache = { values = {}, order = {} }

local function text_ink_bounds(widget)
    local size = widget:getSize()
    local line_height = widget:getLineHeight()
    local line_count = math.max(1, math.floor((size.h - 1) / line_height) + 1)
    local metrics = RenderText:sizeUtf8Text(
        0, false, widget.face, widget.text, true, widget.bold)
    local baseline = widget:getBaseline()
    return math.max(0, baseline - metrics.y_top), math.min(
        size.h, baseline + (line_count - 1) * line_height + metrics.y_bottom)
end

local function get_cached_layout(key)
    return layout_cache.values[key]
end

local function cache_layout(key, value)
    if not layout_cache.values[key] then
        layout_cache.order[#layout_cache.order + 1] = key
    end
    layout_cache.values[key] = value
    while #layout_cache.order > LAYOUT_CACHE_MAX do
        layout_cache.values[table.remove(layout_cache.order, 1)] = nil
    end
end

local function get_quote(ctx)
    local data = type(ctx) == "table" and ctx.data or nil
    local q = data and type(data.getCurrentQuote) == "function"
        and data:getCurrentQuote() or nil
    if q then return q end
    return { text = _("No quote available."), author = "" }
end

local function quote_content(ctx)
    local quote = get_quote(ctx)
    local config = type(ctx.config) == "table" and ctx.config or {}
    local quotes = type(config.quotes) == "table" and config.quotes or {}
    local show_author = quotes.show_author ~= false
    local show_title = quotes.show_title ~= false
    local attribution_parts = {}
    if show_author and quote.author and quote.author ~= "" then
        attribution_parts[#attribution_parts + 1] = quote.author
    end
    if show_title and quote.title and quote.title ~= "" then
        attribution_parts[#attribution_parts + 1] = quote.title
    end
    if quote.page_label and quotes.show_page ~= false then
        attribution_parts[#attribution_parts + 1] = string.format(_("Page %s"), quote.page_label)
    end
    local attribution = table.concat(attribution_parts, ",  ")
    if attribution == "" and show_author
            and (not quote.author or quote.author == "")
            and (not quote.title or quote.title == "") then
        attribution = quote.attribution or ""
    end
    return quote, quotes, quote.is_empty and quote.text or '"' .. (quote.text or "") .. '"', attribution
end

local function configured_quote_font_size(quotes)
    local quote_font_size = quotes.font_size
    return math.max(4, math.min(32, tonumber(quote_font_size) or 12))
end

local function max_quote_font_size(quotes)
    return math.max(4, math.min(32, tonumber(quotes.max_font_size) or 14))
end

local function reserves_attribution(quotes)
    return quotes.show_author ~= false or quotes.show_title ~= false
end

local function author_face(quote_font_size)
    return Font:getFace("smallinfofont",
        Device.screen:scaleBySize(math.max(6, math.floor(quote_font_size * 9 / 10))))
end

local function probe_text(values)
    local probe = TextBoxWidget:new(values)
    local h = probe:getSize().h or 0
    local ink_top, ink_bottom = text_ink_bounds(probe)
    WidgetResources.free(probe)
    return { h = h, ink_top = ink_top, ink_bottom = ink_bottom }
end

-- Bounds of a fixed reference layout, so quote length never moves neighboring rows.
local function slot_bounds(quotes, content_w, height, inner_h)
    local automatic = quotes.automatic_font_size == true
    local font_size = automatic and max_quote_font_size(quotes)
        or configured_quote_font_size(quotes)
    local reserve_author = reserves_attribution(quotes)
    local key = table.concat({
        "slot", tostring(content_w), tostring(height), tostring(inner_h),
        tostring(automatic), tostring(font_size), tostring(reserve_author),
    }, "\30")
    local cached = get_cached_layout(key)
    if cached then return cached, 0 end

    local face = Font:getFace("smallinfofont", Device.screen:scaleBySize(font_size))
    local line_height = automatic and AUTOMATIC_MIN_LINE_HEIGHT or QUOTE_LINE_HEIGHT
    local line = probe_text{ text = "A", width = content_w, face = face, line_height = line_height }
    local probes = 1
    local author_h, bottom_inset = 0, line.h - line.ink_bottom
    if reserve_author then
        local author = probe_text{
            text = "\226\128\148 A",
            width = content_w,
            face = author_face(font_size),
            alignment = "center",
        }
        probes = probes + 1
        author_h, bottom_inset = author.h, author.h - author.ink_bottom
    end
    local quote_h = math.max(10, inner_h - author_h)
    if not automatic then
        quote_h = math.min(quote_h, probe_text{
            text = "A\nA\nA", width = content_w, face = face, line_height = line_height,
        }.h)
        probes = probes + 1
    end
    local slot_h = quote_h + author_h
    local slot_top = math.floor((height - slot_h) / 2)
    local bounds = {
        top = slot_top + line.ink_top,
        bottom = slot_top + slot_h - bottom_inset,
    }
    cache_layout(key, bounds)
    return bounds, probes
end

local function largest_fitting(minimum, maximum, fits)
    if fits(maximum) then return maximum end
    local best = minimum
    local low, high = minimum, maximum - 1
    while low <= high do
        local middle = math.floor((low + high) / 2)
        if fits(middle) then
            best = middle
            low = middle + 1
        else
            high = middle - 1
        end
    end
    return best
end

local function preferred_height(ctx)
    ctx = type(ctx) == "table" and ctx or {}
    if ctx.is_last_row ~= true or (tonumber(ctx.row_count) or 0) < 3 then return nil end
    local config = type(ctx.config) == "table" and ctx.config or {}
    local quotes = type(config.quotes) == "table" and config.quotes or {}
    local Screen = Device.screen
    local automatic_font_size = quotes.automatic_font_size == true
    local quote_font_size = automatic_font_size and max_quote_font_size(quotes)
        or configured_quote_font_size(quotes)
    local padding = Screen:scaleBySize(8)
    local vertical_padding = automatic_font_size and 0 or Screen:scaleBySize(4)
    local content_w = math.max(30, (tonumber(ctx.width) or Screen:getWidth()) - padding * 2)
    local quote_face = Font:getFace("smallinfofont", Screen:scaleBySize(quote_font_size))
    local quote_probe = TextBoxWidget:new{
        text = "A\nA",
        width = content_w,
        face = quote_face,
        line_height = QUOTE_LINE_HEIGHT,
    }
    local quote_h = quote_probe:getSize().h or 0
    WidgetResources.free(quote_probe)
    local author_h = 0
    if reserves_attribution(quotes) then
        local author_probe = TextBoxWidget:new{
            text = "\226\128\148 A",
            width = content_w,
            face = author_face(quote_font_size),
            alignment = "center",
        }
        author_h = author_probe:getSize().h or 0
        WidgetResources.free(author_probe)
    end
    return math.max(20, quote_h + author_h + vertical_padding * 2)
end

return {
    id = "quotes",
    label = _("Quotes"),
    size = { units = 1.5 },
    preferredHeight = preferred_height,
    build = function(ctx)
        local width = ctx.width
        local height = ctx.height
        local quote, quotes, first_text, first_attribution = quote_content(ctx)
        local automatic_font_size = quotes.automatic_font_size == true
        local Screen = Device.screen
        local padding = Screen:scaleBySize(8)
        local vertical_padding = automatic_font_size and 0 or Screen:scaleBySize(4)
        local content_w = math.max(30, width - padding * 2)
        local inner_h = math.max(20, height - vertical_padding * 2)
        -- Slot bounds ignore the quote text, so swapped quotes keep the row's alignment.
        local visual_shift = 0
        local slot_probes = 0
        if type(ctx.setContentBounds) == "function" then
            local slot
            slot, slot_probes = slot_bounds(quotes, content_w, height, inner_h)
            ctx.setContentBounds{
                top = slot.top,
                bottom = slot.bottom,
                min_shift = -slot.top,
                max_shift = height - slot.bottom,
                set_shift = function(shift) visual_shift = shift end,
            }
        end

        local function layout_content(quote_text, attribution)
            local layout_started_at = os.clock()
            local layout_probes = slot_probes
            slot_probes = 0
            local quote_font_size = configured_quote_font_size(quotes)

            local function measure_height(values)
                layout_probes = layout_probes + 1
                local probe = TextBoxWidget:new(values)
                local measured_h = probe:getSize().h or 0
                WidgetResources.free(probe)
                return measured_h
            end

            local quote_line_height = QUOTE_LINE_HEIGHT
            local layout_key = table.concat({
                quote_text, attribution, tostring(content_w), tostring(inner_h),
                tostring(automatic_font_size), tostring(quote_font_size),
                tostring(quotes.max_font_size),
            }, "\30")
            local cached_layout = get_cached_layout(layout_key)
            local layout_cache_hit = cached_layout ~= nil
            if cached_layout then
                quote_font_size = cached_layout.quote_font_size
                quote_line_height = cached_layout.quote_line_height
            elseif automatic_font_size then
                local max_font_size = max_quote_font_size(quotes)
                local font_measurements = {}
                local function font_fits(candidate)
                    local measured = font_measurements[candidate]
                    if measured then return measured.fits end
                    local candidate_face = Font:getFace(
                        "smallinfofont", Screen:scaleBySize(candidate)
                    )
                    local author_h = 0
                    if attribution ~= "" then
                        author_h = measure_height{
                            text = "\226\128\148 " .. attribution,
                            width = content_w,
                            face = author_face(candidate),
                            alignment = "center",
                        }
                    end
                    local quote_h = measure_height{
                        text = quote_text,
                        width = content_w,
                        face = candidate_face,
                        alignment = "center",
                        line_height = AUTOMATIC_MIN_LINE_HEIGHT,
                    }
                    measured = {
                        author_h = author_h,
                        face = candidate_face,
                        fits = quote_h + author_h <= inner_h,
                        quote_h = quote_h,
                    }
                    font_measurements[candidate] = measured
                    return measured.fits
                end

                quote_font_size = largest_fitting(4, max_font_size, font_fits)
                local chosen = font_measurements[quote_font_size]
                local min_line_height_step = AUTOMATIC_MIN_LINE_HEIGHT * 20
                local function line_height_fits(step)
                    if step == min_line_height_step then return chosen.fits end
                    return measure_height{
                        text = quote_text,
                        width = content_w,
                        face = chosen.face,
                        alignment = "center",
                        line_height = step / 20,
                    } + chosen.author_h <= inner_h
                end
                quote_line_height = largest_fitting(
                    min_line_height_step, 11, line_height_fits) / 20
            end

            local quote_face = Font:getFace("smallinfofont", Screen:scaleBySize(quote_font_size))
            local attribution_face = author_face(quote_font_size)
            local two_quote_lines_h
            local three_quote_lines_h
            local quote_line_h
            local natural_quote_h
            local author_h
            if cached_layout then
                two_quote_lines_h = cached_layout.two_quote_lines_h
                three_quote_lines_h = cached_layout.three_quote_lines_h
                quote_line_h = cached_layout.quote_line_h
                natural_quote_h = cached_layout.natural_quote_h
                author_h = cached_layout.author_h
            else
                two_quote_lines_h = measure_height{
                    text = "A\nA",
                    width = content_w,
                    face = quote_face,
                    line_height = quote_line_height,
                }
                three_quote_lines_h = measure_height{
                    text = "A\nA\nA",
                    width = content_w,
                    face = quote_face,
                    line_height = quote_line_height,
                }
                quote_line_h = measure_height{
                    text = "A",
                    width = content_w,
                    face = quote_face,
                    line_height = quote_line_height,
                }
                natural_quote_h = measure_height{
                    text = quote_text,
                    width = content_w,
                    face = quote_face,
                    line_height = quote_line_height,
                }
                author_h = 0
                if attribution ~= "" then
                    author_h = measure_height{
                        text = "\226\128\148 " .. attribution,
                        width = content_w,
                        face = attribution_face,
                        alignment = "center",
                    }
                end
                cache_layout(layout_key, {
                    quote_font_size = quote_font_size,
                    quote_line_height = quote_line_height,
                    two_quote_lines_h = two_quote_lines_h,
                    three_quote_lines_h = three_quote_lines_h,
                    quote_line_h = quote_line_h,
                    natural_quote_h = natural_quote_h,
                    author_h = author_h,
                })
            end
            local author_gap = 0
            local max_quote_h = math.max(10, inner_h - author_h - author_gap)
            local quote_h
            if automatic_font_size then
                quote_h = math.min(natural_quote_h, max_quote_h)
            else
                quote_h = math.min(natural_quote_h, three_quote_lines_h, max_quote_h)
            end
            local line_height_target = 2
            if natural_quote_h > two_quote_lines_h and quote_h < three_quote_lines_h
                    and quote_h >= quote_face.size * 3 then
                line_height_target = 3
            end
            if not automatic_font_size and natural_quote_h > quote_line_h
                    and quote_h < (line_height_target == 3
                    and three_quote_lines_h or two_quote_lines_h) then
                quote_line_height = math.max(0, math.min(
                    quote_line_height,
                    math.floor(quote_h / line_height_target) / math.max(1, quote_face.size or 1) - 1
                ))
            end
            local quote_widget = TextBoxWidget:new{
                text = quote_text,
                width = content_w,
                height = quote_h,
                face = quote_face,
                alignment = "center",
                line_height = quote_line_height,
                height_overflow_show_ellipsis = true,
            }
            local quote_size = quote_widget:getSize()
            local author_widget

            if attribution ~= "" then
                author_widget = TextBoxWidget:new{
                    text = "\226\128\148 " .. attribution,
                    width = content_w,
                    face = attribution_face,
                    alignment = "center",
                    fgcolor = Blitbuffer.COLOR_BLACK,
                    height_overflow_show_ellipsis = true,
                }
            end
            local author_size = author_widget and author_widget:getSize() or nil
            local quote_height = quote_size.h or 0
            local content_h = quote_height
            if author_widget then
                content_h = content_h + author_gap + (author_size.h or 0)
            end
            local available_h = math.max(0, height - content_h)
            local content_top = math.floor(available_h / 2)
            local content = WidgetResources.managedPaintWidget{
                dimen = Geom:new{ w = width, h = height },
                resources = { quote_widget, author_widget },
                paintTo = function(_self, bb, x, y)
                    local quote_x = x + math.floor((width - content_w) / 2)
                    local quote_y = y + content_top + visual_shift
                    quote_widget:paintTo(bb, quote_x, quote_y)
                    if author_widget then
                        local author_x = x + math.floor((width - content_w) / 2)
                        local author_y = quote_y + quote_height + author_gap
                        author_widget:paintTo(bb, author_x, author_y)
                    end
                end,
                free = function()
                    quote_widget = nil
                    author_widget = nil
                end,
            }
            if ctx.data and type(ctx.data.recordQuoteLayout) == "function" then
                ctx.data:recordQuoteLayout(
                    (os.clock() - layout_started_at) * 1000,
                    layout_cache_hit,
                    layout_probes
                )
            end
            return content
        end

        local body = FrameContainer:new{
            width = width,
            height = height,
            padding = 0,
            bordersize = 0,
            background = Background.tile_bg(Blitbuffer.COLOR_WHITE),
            layout_content(first_text, first_attribution),
        }

        -- Swap only this row's content; Home rebuilds everything when it can't repaint one row.
        local function step_quote(method)
            local data = ctx.data
            if not (data and data[method]) then return end
            local refresh
            if type(ctx.refreshRow) == "function" then
                refresh = function()
                    local next_quote, _quotes, text, attribution = quote_content(ctx)
                    quote = next_quote
                    local old = body[1]
                    body[1] = layout_content(text, attribution)
                    WidgetResources.free(old)
                    local dimen = body.dimen
                    ctx.refreshRow(dimen and Geom:new{
                        x = dimen.x,
                        y = dimen.y + math.min(0, visual_shift),
                        w = dimen.w,
                        h = dimen.h + math.abs(visual_shift),
                    })
                end
            end
            data[method](data, refresh)
        end

        local tap = InputContainer:new{
            dimen = Geom:new{ w = width, h = height },
            ges_events = {
                TapQuote = {
                    GestureRange:new{ ges = "tap", range = Geom:new{
                        x = 0, y = 0,
                        w = Screen:getWidth(), h = Screen:getHeight(),
                    } },
                },
                HoldQuote = {
                    GestureRange:new{ ges = "hold", range = Geom:new{
                        x = 0, y = 0,
                        w = Screen:getWidth(), h = Screen:getHeight(),
                    } },
                },
                SwipeQuote = {
                    GestureRange:new{ ges = "swipe", range = Geom:new{
                        x = 0, y = 0,
                        w = Screen:getWidth(), h = Screen:getHeight(),
                    } },
                },
            },
        }
        tap.onTapQuote = function(tap_self, _arg, ges)
            if not tap_self.dimen or not ges or not ges.pos then
                return false
            end
            if ctx.openTopMenu and ctx.openTopMenu(ges) then
                return true
            end
            if not tap_self.dimen:contains(ges.pos) then
                return false
            end
            if quote.is_annotation and ctx.data.openQuote then
                return ctx.data:openQuote(quote)
            end
            return true
        end
        tap.onSwipeQuote = function(tap_self, _arg, ges)
            if not (tap_self.dimen and ges and ges.pos and tap_self.dimen:contains(ges.pos)) then
                return false
            end
            if ges.direction == "west" then
                step_quote("nextQuote")
                return true
            elseif ges.direction == "east" then
                step_quote("prevQuote")
                return true
            end
            return false
        end
        tap.onHoldQuote = function(tap_self, _arg, ges)
            if not (tap_self.dimen and ges and ges.pos and tap_self.dimen:contains(ges.pos)) then
                return false
            end
            if ctx.editMode and ctx.openWidgetSettings then
                return ctx.openWidgetSettings()
            end
            return false
        end
        tap[1] = body
        return tap
    end,
}
