local Background = require("common/ui/background")
local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local InputContainer = require("ui/widget/container/inputcontainer")
local TopContainer = require("ui/widget/container/topcontainer")
local GestureRange = require("ui/gesturerange")
local Device = require("device")
local Font = require("ui/font")
local util = require("util")
local zen_utils = require("common/utils")
local WidgetResources = require("common/widget_resources")
local BookOpenTap = require("common/book_open_tap")
local BookProgress = require("common/ui/book_progress")
local cover_common = require("modules/filebrowser/patches/home/widgets/cover_common")
local HomePresets = require("modules/filebrowser/patches/home/home_presets")
local library_font = require("modules/filebrowser/patches/library_font")
local _ = require("gettext")

local M = {}
M.SIZE = { units = 3.5 }

local COVER_WIDTH_SHARE = 0.40

function M.preferred_height(outer_width, module_cfg, data)
    module_cfg = type(module_cfg) == "table" and module_cfg or {}
    if module_cfg.wrap_description_text == true
            and module_cfg.show_description ~= false then
        if not (data and type(data.getFeaturedBook) == "function") then return nil end
        local source = HomePresets.featuredSourceKey(module_cfg.default_source)
        local book = data:getFeaturedBook(source, "default", true)
        local description = type(book) == "table" and type(book.description) == "string"
            and util.htmlToPlainTextIfHtml(book.description) or ""
        if description:gsub("^%s+", ""):gsub("%s+$", "") ~= "" then return nil end
    end
    local Screen = Device.screen
    outer_width = math.max(1, tonumber(outer_width) or Screen:getWidth())
    local padding = Screen:scaleBySize(8)
    local width = math.max(1, outer_width - padding * 2)
    local gap = math.max(4, math.floor(width * 0.025))
    local cover_w = math.max(1,
        math.floor(math.max(1, width - gap) * COVER_WIDTH_SHARE))
    local cover_h = cover_common.uniform_height_for_width(cover_w)
    local base_h = math.max(1, Screen:scaleBySize(4)) + cover_h
    local bottom_pad = math.max(3, math.floor(base_h * 0.02))
    bottom_pad = math.max(3, math.floor((base_h + bottom_pad) * 0.02))
    return padding * 2 + base_h + bottom_pad
end

local function time_unit(unit)
    if type(_) == "table" and type(_.pgettext) == "function" then
        return _.pgettext("Time", unit)
    end
    return _(unit)
end

local DEFAULT_TEXT_STYLES = {
    title = { font_face = "default", font_size = 11, bold = true },
    author = { font_face = "default", font_size = 9, bold = false },
    series = { font_face = "default", font_size = 7, bold = false },
    description = { font_face = "default", font_size = 16, bold = false },
    progress = { font_face = "default", font_size = 7, bold = false },
}

local function clamp(v, min_v, max_v)
    if v < min_v then return min_v end
    if v > max_v then return max_v end
    return v
end

local function text_style(module_cfg, key)
    local defaults = DEFAULT_TEXT_STYLES[key]
    local styles = type(module_cfg.text_styles) == "table" and module_cfg.text_styles or {}
    local style = type(styles[key]) == "table" and styles[key] or {}
    local size = tonumber(style.font_size) or defaults.font_size
    return {
        font_face = type(style.font_face) == "string" and style.font_face ~= "" and style.font_face or defaults.font_face,
        font_size = clamp(math.floor(size + 0.5), 6, 40),
        bold = style.bold == nil and defaults.bold or style.bold == true,
    }
end

local function get_text_face(style, size, default_font_name)
    local font_name = style.font_face == "default" and (default_font_name or library_font.getFontName()) or style.font_face
    return Font:getFace(font_name, size)
end

local function set_opening_banner_cover(cover)
    local set_cover = rawget(_G, "__ZEN_UI_SET_OPENING_BANNER_COVER")
    if type(set_cover) == "function" then set_cover(cover) end
end

local function fmt_duration(secs)
    secs = math.floor(tonumber(secs) or 0)
    if secs <= 0 then return "" end
    local hours = math.floor(secs / 3600)
    local mins = math.floor((secs % 3600) / 60)
    if hours > 0 then
        return tostring(hours) .. time_unit("h") .. " "
            .. tostring(mins) .. time_unit("m")
    end
    return tostring(math.max(1, mins)) .. time_unit("m")
end

local function format_series(book)
    local series = type(book.series) == "string" and book.series:gsub("^%s*(.-)%s*$", "%1") or ""
    if series == "" then return "" end
    local index = tonumber(book.series_index)
    if not index then return series end
    local index_text = index == math.floor(index)
        and tostring(math.floor(index)) or string.format("%.10g", index)
    return series .. " #" .. index_text
end

local function split_text_for_box(text, face, bold, justified, width, height)
    if text == "" or height <= 0 then return "", text end
    local probe = TextBoxWidget:new{
        text = text,
        width = width,
        height = height,
        face = face,
        bold = bold,
        justified = justified,
        alignment = "left",
        alignment_strict = true,
    }
    local lines = probe.vertical_string_list
    local visible_lines = tonumber(probe.lines_per_page) or 0
    local next_line = type(lines) == "table" and lines[visible_lines + 1] or nil
    if not next_line or not next_line.offset then
        WidgetResources.free(probe)
        return text, ""
    end

    local last_line = lines[visible_lines]
    local upper_end = last_line and tonumber(last_line.end_offset) or 0
    local lower_start = tonumber(next_line.offset)
    local chars = util.splitToChars(text)
    WidgetResources.free(probe)
    if upper_end < 1 or not lower_start or lower_start > #chars then
        return "", text
    end
    return table.concat(chars, "", 1, upper_end),
        table.concat(chars, "", lower_start, #chars)
end

local function build_progress_text(book, pct, progress_meta)
    progress_meta = type(progress_meta) == "table" and progress_meta or {}
    local left = {}
    local right = {}
    local total_pages = tonumber(book.stable_pages) or tonumber(book.pages)
    local current_page = tonumber(book.stable_current_page) or tonumber(book.current_page)
    local stable_current_label = type(book.stable_current_label) == "string"
        and book.stable_current_label ~= "" and book.stable_current_label or nil
    local stable_last_label = type(book.stable_last_label) == "string"
        and book.stable_last_label ~= "" and book.stable_last_label or nil
    local current_label = stable_current_label or (current_page and tostring(current_page))
    local total_label = stable_last_label or (total_pages and tostring(total_pages))
    local time_left = fmt_duration(book.time_left_secs)
    local entries = {
        total_pages = total_pages and zen_utils.formatPageCount(total_pages, true) or "",
        current_total = total_label and current_label and (tostring(current_label) .. " / " .. tostring(total_label)) or "",
        percent = tostring(pct) .. "%",
        time_left = time_left ~= "" and string.format(_("%s left"), time_left) or "",
    }
    local order = { "total_pages", "current_total", "percent", "time_left" }
    for _i, key in ipairs(order) do
        local text = entries[key]
        if text and text ~= "" then
            if progress_meta.left == key then
                left[#left + 1] = text
            end
            if progress_meta.right == key then
                right[#right + 1] = text
            end
        end
    end
    return table.concat(left, "  \194\183  "), table.concat(right, "  \194\183  ")
end

function M.build(ctx, source_key)
    local outer_width = ctx.width
    local outer_height = ctx.height
    local Screen = Device.screen
    local padding = Screen:scaleBySize(8)
    local width = math.max(1, outer_width - padding * 2)
    local height = math.max(1, outer_height - padding * 2)
    local module_cfg = type(ctx.module_cfg) == "table" and ctx.module_cfg or {}
    local interactive = module_cfg.interactive ~= false
    local source = source_key or HomePresets.featuredSourceKey(module_cfg.default_source)
    local book = ctx.data:getFeaturedBook(source, "default")
    local show_description = module_cfg.show_description ~= false
    local format_description_html = module_cfg.format_description_html == true
    local justify_description_text = module_cfg.justify_description_text == true
    local show_status_bar = module_cfg.show_status_bar == true and type(ctx.buildStatusRow) == "function"
    local cover_widget, cover_w, cover_actual_h

    local col_top_pad = math.max(1, Screen:scaleBySize(4))
    local col_bottom_pad = math.max(3, math.floor(height * 0.02))
    local gap = math.max(4, math.floor(width * 0.025))

    if not book then
        local empty_cover = cover_common.make_empty_cover_widget(
            source, width, height,
            { border = cover_common.BORDER_SIZE, background = Blitbuffer.COLOR_LIGHT_GRAY }
        )
        local empty_size = empty_cover:getSize()
        local empty_top = math.floor(math.max(0, outer_height - (empty_size.h or outer_height)) / 2)
        local visual_shift = 0
        local empty_container = CenterContainer:new{
            dimen = Geom:new{ w = outer_width, h = outer_height },
            empty_cover,
        }
        local original_empty_paint = empty_container.paintTo
        empty_container.paintTo = function(self, bb, x, y)
            return original_empty_paint(self, bb, x, y + visual_shift)
        end
        if type(ctx.setContentBounds) == "function" then
            ctx.setContentBounds{
                top = empty_top,
                bottom = empty_top + (empty_size.h or outer_height),
                min_shift = -empty_top,
                max_shift = outer_height - empty_top - (empty_size.h or outer_height),
                set_shift = function(shift) visual_shift = shift end,
            }
        end
        return FrameContainer:new{
            width = outer_width,
            height = outer_height,
            padding = 0,
            bordersize = 0,
            background = Background.tile_bg(Blitbuffer.COLOR_WHITE),
            empty_container,
        }
    end

    if type(ctx.setWidgetActions) == "function" then
        ctx.setWidgetActions{
            activate = function()
                set_opening_banner_cover(cover_widget)
                ctx.openBook(book.path)
                return true
            end,
            context = function()
                if ctx.showBookMenu then return ctx.showBookMenu(book.path, source) end
                return false
            end,
        }
    end

    -- The assigned height is an upper bound; normal details stop at cover height.
    local col_h = math.max(1, height - col_top_pad - col_bottom_pad)

    -- Reserve at least 60% of the usable row width for book details.
    local columns_w = math.max(1, width - gap)
    local cover_max_w = math.max(1, math.floor(columns_w * COVER_WIDTH_SHARE))
    cover_widget, cover_w, cover_actual_h = cover_common.make_cover_widget(
        book, cover_max_w, col_h,
        { border = cover_common.BORDER_SIZE, background = Blitbuffer.COLOR_LIGHT_GRAY }
    )
    local cover_col_w = math.max(1, cover_w or cover_max_w)
    gap = math.min(gap, math.max(0, width - cover_col_w - 1))
    local text_w = math.max(1, width - cover_col_w - gap)

    -- Fonts
    local scale = clamp(math.max(1, cover_actual_h or col_h) / 300, 0.55, 1.28)
    local title_style = text_style(module_cfg, "title")
    local author_style = text_style(module_cfg, "author")
    local series_style = text_style(module_cfg, "series")
    local description_style = text_style(module_cfg, "description")
    local progress_style = text_style(module_cfg, "progress")
    local title_face = get_text_face(title_style, Screen:scaleBySize(math.floor(title_style.font_size * scale + 0.5)))
    local meta_face = get_text_face(author_style, Screen:scaleBySize(math.floor(author_style.font_size * scale + 0.5)))
    local series_face = get_text_face(series_style, Screen:scaleBySize(math.floor(series_style.font_size * scale + 0.5)))
    local stats_face = get_text_face(progress_style,
        Screen:scaleBySize(math.floor(progress_style.font_size * scale + 0.5)), "smallinfofont")
    local desc_face = get_text_face(description_style, description_style.font_size)
    local raw_description = type(book.description) == "string" and book.description or ""
    local desc_text = util.htmlToPlainTextIfHtml(raw_description)
    desc_text = desc_text:gsub("^%s+", ""):gsub("%s+$", "")
    local desc_line_h_probe = TextBoxWidget:new{
        text = "A\nA",
        width = text_w,
        face = desc_face,
        bold = description_style.bold == true,
    }
    local desc_line_h = math.max(1, math.ceil(desc_line_h_probe:getSize().h / 2))
    WidgetResources.free(desc_line_h_probe)
    local v_pad = math.max(2, math.floor(col_h * 0.02))

    -- Optional status bar (top of right column)
    local status_opts = {
        padding = 0,
        font_name = "xx_smallinfofont",
        font_size_delta = -2,
        row_height = 14,
        bold_text = module_cfg.status_bar_bold_text ~= false,
        show_bottom_border = module_cfg.status_bar_show_bottom_border ~= false,
    }
    local function build_status_widget()
        return show_status_bar and ctx.buildStatusRow(text_w, status_opts) or nil
    end
    local status_widget = build_status_widget()
    local status_h = status_widget and (status_widget:getSize().h or 0) or 0
    local status_gap = status_h > 0 and math.max(1, math.floor(col_h * 0.015)) or 0

    -- Progress metrics; row width is chosen after overflow is measured.
    local is_tbr = book.status == "tbr"
    local show_progress = module_cfg.show_progress ~= false
    local progress_percent = (book.status == "new" or is_tbr) and 0 or book.percent
    if book.status ~= "new" and not is_tbr
            and book.stable_current_page and book.stable_pages and book.stable_pages > 0 then
        progress_percent = book.stable_current_page / book.stable_pages
    end
    local pct = math.floor((progress_percent or 0) * 100 + 0.5)
    local left_progress_text, right_progress_text = "", ""
    if book.status ~= "new" and not is_tbr then
        left_progress_text, right_progress_text =
            build_progress_text(book, pct, module_cfg.progress_meta)
    end
    local has_progress_text = left_progress_text ~= "" or right_progress_text ~= ""
    local cover_h = math.max(1, cover_actual_h or col_h)
    local progress_h = math.max(1, math.floor(cover_h * 0.022))
    local stats_text_h = 0
    if has_progress_text then
        local stats_probe = TextWidget:new{ text = "A", face = stats_face }
        stats_text_h = (stats_probe:getSize().h or 8)
        WidgetResources.free(stats_probe)
    end
    local bar_h = math.max(progress_h, stats_text_h)
    local has_progress = show_progress and bar_h > 0
        and book.status ~= "new" and not is_tbr
    local bottom_h = has_progress and bar_h or 0

    local function build_progress_row(progress_w)
        if not has_progress then return nil end
        if has_progress_text then
            return BookProgress.build{
                ratio = progress_percent,
                width = progress_w,
                bar_height = progress_h,
                face = stats_face,
                bold = progress_style.bold == true,
                gap = math.max(4, math.floor(progress_w * 0.02)),
                left_text = left_progress_text,
                right_text = right_progress_text,
            }
        end
        return BookProgress.bar(progress_percent, progress_w, progress_h)
    end

    -- Title: up to 2 lines before truncating
    local title_line_h = math.max(1, math.floor((tonumber(title_face.size) or 12) * 1.05 + 0.5))
    local author_line_h = math.max(1, math.floor((tonumber(meta_face.size) or 10) * 1.05 + 0.5))
    local series_line_h = math.max(1, math.floor((tonumber(series_face.size) or 8) * 1.05 + 0.5))
    local probe = TextWidget:new{ text = book.title or "", face = title_face, bold = title_style.bold == true }
    local title_needs_2_lines = probe:getSize().w > text_w
    WidgetResources.free(probe)
    local title_h = title_line_h * (title_needs_2_lines and 2 or 1)

    local author_text = (book.authors or ""):gsub("%s*\n%s*", ", "):gsub("%s+", " ")
    local has_author = module_cfg.show_author ~= false and author_text ~= ""
    local series_text = format_series(book)
    local has_series = module_cfg.show_series ~= false and series_text ~= ""
    local author_h = 0
    if has_author then
        local author_probe = TextWidget:new{ text = author_text, face = meta_face, bold = author_style.bold == true }
        local lines = not has_series and author_probe:getSize().w > text_w and 2 or 1
        WidgetResources.free(author_probe)
        author_h = author_line_h * lines
    end
    local series_h = has_series and series_line_h or 0
    local title_author_gap = (has_author or has_series) and math.max(1, Screen:scaleBySize(1)) or 0
    local author_series_gap = has_author and has_series and math.max(1, Screen:scaleBySize(1)) or 0

    -- Build top block widgets first so we can measure actual heights
    local top_items = {}
    local top_budget = math.max(0, cover_h - bottom_h)

    if status_widget and status_h > 0 then
        if top_budget >= status_h then
            local status_slot = FrameContainer:new{
                width = text_w,
                height = status_h,
                padding = 0,
                bordersize = 0,
                background = Background.tile_bg(Blitbuffer.COLOR_WHITE),
                status_widget,
            }
            if type(ctx.registerClockRefresh) == "function" then
                ctx.registerClockRefresh(function()
                    local next_widget = build_status_widget()
                    if not next_widget then return false end
                    WidgetResources.replaceChild(status_slot, 1, next_widget)
                    return true
                end)
            end
            table.insert(top_items, status_slot)
            if status_gap > 0 then
                table.insert(top_items, VerticalSpan:new{ width = status_gap })
            end
            top_budget = top_budget - status_h - status_gap
        end
    end

    -- Clamp title and metadata to remaining budget
    if title_h + title_author_gap + author_h + author_series_gap + series_h > top_budget then
        if has_author and top_budget >= author_line_h then
            if top_budget < title_h + title_author_gap + author_h + author_series_gap + series_h then
                author_h = author_line_h
            end
            title_h = math.min(title_h, math.max(0,
                top_budget - title_author_gap - author_h - author_series_gap - series_h))
        else
            author_h = 0
            author_series_gap = 0
            title_h = math.min(title_h,
                math.max(0, top_budget - title_author_gap - series_h))
        end
    end
    if title_h + title_author_gap + author_h + author_series_gap + series_h > top_budget then
        series_h = 0
        author_series_gap = 0
        title_h = math.min(title_h, math.max(0, top_budget - title_author_gap - author_h))
    end
    if title_h <= 0 or (author_h <= 0 and series_h <= 0) then title_author_gap = 0 end

    if title_h > 0 then
        table.insert(top_items, TextBoxWidget:new{
            text = book.title or "",
            width = text_w,
            height = title_h,
            face = title_face,
            bold = title_style.bold == true,
            alignment = "left",
            alignment_strict = true,
            line_height = 0,
            height_overflow_show_ellipsis = true,
        })
    end
    if title_author_gap > 0 then
        table.insert(top_items, VerticalSpan:new{ width = title_author_gap })
    end
    if has_author and author_h > 0 then
        table.insert(top_items, TextBoxWidget:new{
            text = author_text,
            width = text_w,
            height = author_h,
            face = meta_face,
            bold = author_style.bold == true,
            alignment = "left",
            alignment_strict = true,
            line_height = 0,
            fgcolor = Blitbuffer.COLOR_BLACK,
            height_overflow_show_ellipsis = true,
        })
    end
    if author_series_gap > 0 and series_h > 0 then
        table.insert(top_items, VerticalSpan:new{ width = author_series_gap })
    end
    if has_series and series_h > 0 then
        table.insert(top_items, TextBoxWidget:new{
            text = series_text,
            width = text_w,
            height = series_h,
            face = series_face,
            bold = series_style.bold == true,
            alignment = "left",
            alignment_strict = true,
            line_height = 0,
            fgcolor = Blitbuffer.COLOR_BLACK,
            height_overflow_show_ellipsis = true,
        })
    end

    -- Measure actual rendered top height (TextBoxWidget snaps to line boundaries)
    local actual_top_h = 0
    for _i, w in ipairs(top_items) do
        actual_top_h = actual_top_h + w:getSize().h
    end
    local flow_description = false
    local flow_upper_text, flow_lower_text = "", ""
    local side_desc_h = 0
    local lower_room = col_h - cover_h - bottom_h
    -- Detect overflow in the compact layout, then reflow into the freed progress space.
    if module_cfg.wrap_description_text == true
            and show_description and desc_text ~= ""
            and lower_room >= desc_line_h then
        local compact_side_available = math.max(
            0, cover_h - actual_top_h - bottom_h - v_pad * 2)
        local compact_side_desc_h =
            math.floor(compact_side_available / desc_line_h) * desc_line_h
        local overflow_text = desc_text
        if compact_side_desc_h > 0 then
            flow_upper_text, overflow_text = split_text_for_box(
                desc_text, desc_face, description_style.bold == true,
                justify_description_text, text_w, compact_side_desc_h)
        end
        flow_description = overflow_text:gsub("^%s+", "") ~= ""
        if flow_description then
            local side_available = math.max(
                0, cover_h - actual_top_h - v_pad)
            side_desc_h = math.floor(side_available / desc_line_h) * desc_line_h
            if side_desc_h > 0 then
                flow_upper_text, flow_lower_text = split_text_for_box(
                    desc_text, desc_face, description_style.bold == true,
                    justify_description_text, text_w, side_desc_h)
            else
                flow_lower_text = desc_text
            end
            flow_lower_text = flow_lower_text:gsub("^%s+", "")
            if format_description_html then
                flow_upper_text, flow_lower_text, side_desc_h = "", desc_text, 0
            end
        end
    end
    local progress_w = flow_description and width or text_w
    local progress_row = build_progress_row(progress_w)
    local actual_bottom_h = progress_row and progress_row:getSize().h or 0
    local detail_bottom_h = flow_description and 0 or actual_bottom_h
    local spacer_h = math.max(0, cover_h - actual_top_h - detail_bottom_h)

    local function description_widget(text, box_w, box_h, ellipsis)
        if format_description_html then
            local ok_html, HtmlBoxWidget = pcall(require, "ui/widget/htmlboxwidget")
            if ok_html then
                local html_widget = HtmlBoxWidget:new{
                    dimen = Geom:new{ w = box_w, h = box_h },
                }
                local align = justify_description_text and "justify" or "left"
                local bold = description_style.bold == true and "font-weight: bold;" or ""
                local font_file = description_style.font_face == "default"
                    and library_font.getFontName() or description_style.font_face
                local page_css = "@page { margin: 0; }"
                if font_file:find("/", 1, true) then
                    font_file = font_file:gsub("'", "\\'")
                    page_css = string.format([[
@font-face { font-family: 'ZenDescription'; src: url('%s'); }
@page { margin: 0; font-family: 'ZenDescription'; }
]], font_file)
                end
                html_widget:setContent(raw_description, string.format([[
%s
body { margin: 0; padding: 0; color: #000; line-height: 1.3; text-align: %s !important; %s }
p { margin: 0; }
]], page_css, align, bold), Screen:scaleBySize(description_style.font_size))
                return html_widget
            end
        end
        return TextBoxWidget:new{
            text = text,
            width = box_w,
            height = box_h,
            face = desc_face,
            bold = description_style.bold == true,
            justified = justify_description_text,
            alignment = "left",
            alignment_strict = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            height_overflow_show_ellipsis = ellipsis,
        }
    end

    local body
    if flow_description then
        local upper_desc_h = side_desc_h
        local lower_slot_h = math.max(0, col_h - cover_h - actual_bottom_h)
        local wrap_gap = math.max(4, Screen:scaleBySize(8))
        local lower_desc_h = math.max(0, lower_slot_h - wrap_gap)
        local upper_text, lower_text = flow_upper_text, flow_lower_text

        local side_children = { align = "left" }
        for _i, w in ipairs(top_items) do
            table.insert(side_children, w)
        end
        if upper_text ~= "" and upper_desc_h > 0 then
            local upper_desc = description_widget(
                upper_text, text_w, upper_desc_h, lower_desc_h <= 0)
            local after = math.max(0, spacer_h - v_pad - upper_desc:getSize().h)
            table.insert(side_children, VerticalSpan:new{ width = v_pad })
            table.insert(side_children, upper_desc)
            if after > 0 then
                table.insert(side_children, VerticalSpan:new{ width = after })
            end
        elseif spacer_h > 0 then
            table.insert(side_children, VerticalSpan:new{ width = spacer_h })
        end

        local side_detail = FrameContainer:new{
            width = text_w,
            height = cover_h,
            padding = 0,
            bordersize = 0,
            background = Background.tile_bg(Blitbuffer.COLOR_WHITE),
            VerticalGroup:new(side_children),
        }
        local flow_children = {
            align = "left",
            HorizontalGroup:new{
                align = "top",
                cover_widget,
                HorizontalSpan:new{ width = gap },
                side_detail,
            },
        }
        if lower_text ~= "" and lower_desc_h > 0 then
            local lower_desc = description_widget(
                lower_text, width, lower_desc_h, true)
            local after = math.max(0,
                lower_slot_h - wrap_gap - lower_desc:getSize().h)
            table.insert(flow_children, VerticalSpan:new{ width = wrap_gap })
            table.insert(flow_children, lower_desc)
            if after > 0 then
                table.insert(flow_children, VerticalSpan:new{ width = after })
            end
        elseif lower_slot_h > 0 then
            table.insert(flow_children, VerticalSpan:new{ width = lower_slot_h })
        end
        if progress_row then table.insert(flow_children, progress_row) end
        body = VerticalGroup:new(flow_children)
    else
        local desc_available = math.max(0, spacer_h - v_pad * 2)
        local can_show_desc = show_description and desc_text ~= ""
            and desc_available >= desc_line_h
        local desc_h = can_show_desc
            and math.floor(desc_available / desc_line_h) * desc_line_h or 0
        local detail_children = { align = "left" }
        for _i, w in ipairs(top_items) do
            table.insert(detail_children, w)
        end
        if can_show_desc and desc_h > 0 then
            local desc_widget = description_widget(desc_text, text_w, desc_h, true)
            local after = math.max(0, spacer_h - v_pad - desc_widget:getSize().h)
            table.insert(detail_children, VerticalSpan:new{ width = v_pad })
            table.insert(detail_children, desc_widget)
            if after > 0 then
                table.insert(detail_children, VerticalSpan:new{ width = after })
            end
        elseif spacer_h > 0 then
            table.insert(detail_children, VerticalSpan:new{ width = spacer_h })
        end
        if progress_row then table.insert(detail_children, progress_row) end

        local detail = FrameContainer:new{
            width = text_w,
            height = cover_h,
            padding = 0,
            bordersize = 0,
            background = Background.tile_bg(Blitbuffer.COLOR_WHITE),
            VerticalGroup:new(detail_children),
        }
        body = HorizontalGroup:new{
            align = "top",
            cover_widget,
            HorizontalSpan:new{ width = gap },
            detail,
        }
    end

    local visual_group = VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = col_top_pad },
        body,
    }
    local visual_size = visual_group:getSize()
    local visual_shift = 0
    local content_container = TopContainer:new{
        dimen = Geom:new{ w = width, h = height },
        visual_group,
    }
    local original_content_paint = content_container.paintTo
    content_container.paintTo = function(self, bb, x, y)
        return original_content_paint(self, bb, x, y + visual_shift)
    end
    if type(ctx.setContentBounds) == "function" then
        local outer_top = math.floor(math.max(0, outer_height - height) / 2)
        local visual_top = outer_top + col_top_pad
        local visual_bottom = outer_top + (visual_size.h or height)
        ctx.setContentBounds{
            top = visual_top,
            bottom = visual_bottom,
            min_shift = -visual_top,
            max_shift = outer_height - visual_bottom,
            set_shift = function(shift) visual_shift = shift end,
        }
    end

    local frame = FrameContainer:new{
        width = outer_width,
        height = outer_height,
        padding = 0,
        bordersize = 0,
        background = Background.tile_bg(Blitbuffer.COLOR_WHITE),
        CenterContainer:new{
            dimen = Geom:new{ w = outer_width, h = outer_height },
            content_container,
        },
    }

    if not Device:isTouchDevice() or not interactive then
        return frame
    end
    local tap = InputContainer:new{
        dimen = Geom:new{ w = outer_width, h = outer_height },
        ges_events = {
            TapFeatured = {
                GestureRange:new{ ges = "tap", range = Geom:new{
                    x = 0, y = 0,
                    w = Screen:getWidth(), h = Screen:getHeight(),
                } },
            },
            HoldFeatured = {
                GestureRange:new{ ges = "hold", range = Geom:new{
                    x = 0, y = 0,
                    w = Screen:getWidth(), h = Screen:getHeight(),
                } },
            },
        },
    }
    tap.onTapFeatured = function(tap_self, _arg, ges)
        if not tap_self.dimen or not ges or not ges.pos then return false end
        if ctx.openTopMenu and ctx.openTopMenu(ges) then return true end
        if not tap_self.dimen:contains(ges.pos) then return false end
        if ges.time ~= nil and not BookOpenTap.shouldOpen(book.path, ges.time) then return true end
        set_opening_banner_cover(cover_widget)
        ctx.openBook(book.path)
        return true
    end
    tap.onHoldFeatured = function(tap_self, _arg, ges)
        if not tap_self.dimen or not ges or not ges.pos then return false end
        if not tap_self.dimen:contains(ges.pos) then return false end
        if ctx.showBookMenu then return ctx.showBookMenu(book.path) end
        return false
    end
    tap[1] = frame
    return tap
end

return M
