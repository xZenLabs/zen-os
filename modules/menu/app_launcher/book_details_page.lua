local M = {}

local DEFAULT_DETAIL_ORDER = {
    "read_time", "time_remaining", "pages_today", "time_today", "pages", "progress",
}
local DEFAULT_DETAIL_ENABLED = {
    read_time = true,
    time_remaining = true,
    pages_today = false,
    time_today = false,
    pages = true,
    progress = true,
}

local function launcher_config(config)
    return type(config) == "table" and config or {}
end

function M.isEnabled(config, library_context)
    return library_context ~= true
        and launcher_config(config).show_book_details == true
end

function M.rendererOptions(config)
    config = type(config) == "table" and config or {}
    local features = type(config.features) == "table" and config.features or {}
    return { uniform = features.browser_cover_mosaic_uniform == true }
end

local function load_cover(book, width, height)
    if not (book and book.path) then return end
    local ok_cover, Cover = pcall(require, "common/cover_utils")
    if not ok_cover or type(Cover.makeCover) ~= "function" then return end
    local cover = { Cover.makeCover(book.path, nil, {
        is_folder = false,
        width = width,
        height = height,
        need_copy = true,
    }) }
    book.cover_bb = cover[1]
    book.cover_w = cover[2]
    book.cover_h = cover[3]
    book.has_real_cover = cover[5] == "real_cover"
end

local function time_unit(gettext, unit)
    if type(gettext) == "table" and type(gettext.pgettext) == "function" then
        return gettext.pgettext("Time", unit)
    end
    return gettext(unit)
end

local function format_duration(gettext, seconds)
    seconds = math.floor(tonumber(seconds) or 0)
    if seconds <= 0 then return "0" .. time_unit(gettext, "m") end
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if hours > 0 then
        return hours .. time_unit(gettext, "h") .. " "
            .. minutes .. time_unit(gettext, "m")
    end
    return math.max(1, minutes) .. time_unit(gettext, "m")
end

function M.build(opts)
    opts = opts or {}
    local Blitbuffer = require("ffi/blitbuffer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Device = require("device")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local TextWidget = require("ui/widget/textwidget")
    local UIManager = require("ui/uimanager")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local BookProgress = require("common/ui/book_progress")
    local BookDetails = require("modules/reader/book_details")
    local BookSwitcherPage = require("modules/menu/app_launcher/book_switcher_page")
    local TruncatedTextMessage = require("common/ui/truncated_text_message")
    local cover_common = require("modules/filebrowser/patches/home/widgets/cover_common")
    local library_font = require("modules/filebrowser/patches/library_font")
    local _ = require("gettext")

    local Screen = Device.screen
    local width = math.max(1, tonumber(opts.width) or Screen:getWidth())
    local height = math.max(1, tonumber(opts.height) or Screen:getHeight())
    local layout = BookSwitcherPage.layout{
        width = width, height = height, config = opts.config,
    }
    local detail_config = type(opts.launcher_config) == "table"
        and opts.launcher_config or {}
    local detail_order = type(detail_config.book_details_order) == "table"
        and detail_config.book_details_order or DEFAULT_DETAIL_ORDER
    local detail_enabled = type(detail_config.book_details_enabled) == "table"
        and detail_config.book_details_enabled or DEFAULT_DETAIL_ENABLED
    local function is_detail_enabled(id)
        if type(detail_enabled[id]) == "boolean" then return detail_enabled[id] end
        return DEFAULT_DETAIL_ENABLED[id] == true
    end
    local padding = layout.padding
    local inner_w = layout.inner_w
    local book = opts.book or BookDetails.getSummary(opts.ui)
    local reading_fields = {
        read_time = is_detail_enabled("read_time"),
        time_remaining = is_detail_enabled("time_remaining"),
        pages_today = is_detail_enabled("pages_today"),
        time_today = is_detail_enabled("time_today"),
    }
    local needs_reading_times = reading_fields.read_time or reading_fields.time_remaining
        or reading_fields.pages_today or reading_fields.time_today
    if book and opts.ui and needs_reading_times
            and type(BookDetails.getReadingTimes) == "function" then
        book.time_left_secs, book.read_time_secs,
            book.time_today_secs, book.pages_today = BookDetails.getReadingTimes(
                opts.ui, reading_fields)
    end
    local refs = { buttons = {}, layout_rows = {} }

    if not book then
        local message = TextBoxWidget:new{
            text = _("Book details"),
            face = Font:getFace("smallinfofont", Screen:scaleBySize(18)),
            width = math.max(1, inner_w - padding * 2),
            alignment = "center",
            alignment_strict = true,
            height_adjust = true,
        }
        return CenterContainer:new{ dimen = Geom:new{ w = width, h = height }, message }, refs
    end

    local gap = math.max(6, Screen:scaleBySize(18))
    local cover_max_w = layout.cover_max_w
    local cover_max_h = layout.cover_max_h
    if not book.cover_bb then load_cover(book, cover_max_w, cover_max_h) end
    local cover, cover_w = cover_common.make_cover_widget(
        book, cover_max_w, cover_max_h, {
            border = cover_common.BORDER_SIZE,
            background = Blitbuffer.COLOR_LIGHT_GRAY,
            uniform = M.rendererOptions(opts.config).uniform,
        })
    local text_w = math.max(1, inner_w - cover_w - gap)
    local title_face = library_font.getFace(library_font.scaleValue(22))
    local metadata_face = library_font.getFace(library_font.scaleValue(19))
    local FullText = InputContainer:extend{}
    function FullText:init()
        local size = self[1]:getSize()
        self.dimen = Geom:new{ w = size.w, h = size.h }
        self.ges_events = {
            TapFullText = { GestureRange:new{ ges = "tap", range = self.dimen } },
        }
    end
    function FullText:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        self[1]:paintTo(bb, x, y)
    end
    function FullText:onTapFullText()
        TruncatedTextMessage.showMetadata(self.full_text, self.dimen)
        return true
    end
    local function one_line(text, face, bold)
        local full_text = tostring(text or ""):gsub("%s*\n%s*", " ")
        local text_widget = TextWidget:new{
            text = full_text,
            face = face,
            bold = bold == true,
            max_width = text_w,
            truncate_with_ellipsis = true,
            padding = 0,
        }
        if not text_widget:isTruncated() then return text_widget end
        return FullText:new{ full_text = full_text, text_widget }
    end
    local title = one_line(book.title, title_face, true)
    local details = VerticalGroup:new{
        align = "left",
        HorizontalSpan:new{ width = text_w },
        title,
    }
    local metadata_gap = Screen:scaleBySize(6)
    local function add_metadata(text)
        if text and text ~= "" then
            details[#details + 1] = VerticalSpan:new{ width = metadata_gap }
            details[#details + 1] = one_line(text, metadata_face)
        end
    end
    if book.authors and book.authors ~= "" then
        add_metadata(book.authors:gsub("%s*\n%s*", ", "))
    end
    add_metadata(book.series)
    add_metadata(book.genres)
    local bottom_details = VerticalGroup:new{ align = "left" }
    local function add_bottom_text(text)
        if not (text and text ~= "") then return end
        bottom_details[#bottom_details + 1] = VerticalSpan:new{ width = metadata_gap }
        bottom_details[#bottom_details + 1] = one_line(text, metadata_face)
    end
    local function detail_text(id)
        if id == "read_time" and book.read_time_secs ~= nil then
            return string.format(_("Read: %s"), format_duration(_, book.read_time_secs))
        elseif id == "time_remaining" and book.time_left_secs ~= nil then
            return string.format(_("Remaining: %s"), format_duration(_, book.time_left_secs))
        elseif id == "pages_today" and book.pages_today ~= nil then
            return string.format("%s: %s", _("Pages today"), tostring(book.pages_today))
        elseif id == "time_today" and book.time_today_secs ~= nil then
            return string.format("%s: %s", _("Read today"),
                format_duration(_, book.time_today_secs))
        elseif id == "pages" then
            return book.page_text
        end
    end
    local function paired_detail_text(id, next_id)
        if ((id == "read_time" and next_id == "time_remaining")
                or (id == "time_remaining" and next_id == "read_time"))
                and book.read_time_secs ~= nil and book.time_left_secs ~= nil then
            return detail_text("read_time") .. " / " .. detail_text("time_remaining")
        elseif ((id == "time_today" and next_id == "pages_today")
                or (id == "pages_today" and next_id == "time_today"))
                and book.time_today_secs ~= nil and book.pages_today ~= nil then
            return string.format("%s: %s / %s %s", _("Today"),
                format_duration(_, book.time_today_secs),
                tostring(book.pages_today), _("pages"))
        end
    end
    local skip_next = false
    for _i, id in ipairs(detail_order) do
        if skip_next then
            skip_next = false
        elseif is_detail_enabled(id) then
            if id == "progress" then
                local progress = BookProgress.build{
                    ratio = book.progress,
                    pages = book.pages,
                    right_text = "",
                    width = text_w,
                    bar_height = math.max(2, Screen:scaleBySize(7)),
                    face = metadata_face,
                }
                if progress then
                    bottom_details[#bottom_details + 1] = VerticalSpan:new{
                        width = Screen:scaleBySize(18),
                    }
                    bottom_details[#bottom_details + 1] = progress
                end
            else
                local next_id = detail_order[_i + 1]
                local paired_text = is_detail_enabled(next_id)
                    and paired_detail_text(id, next_id)
                add_bottom_text(paired_text or detail_text(id))
                skip_next = paired_text ~= nil
            end
        end
    end

    local details_h = details:getSize().h
    local bottom_h = bottom_details:getSize().h
    local content_h = math.max(layout.cover_area_h, details_h + bottom_h)
    local middle_h = content_h - details_h - bottom_h
    local detail_column = VerticalGroup:new{ align = "left", details }
    if middle_h > 0 then
        detail_column[#detail_column + 1] = VerticalSpan:new{ width = middle_h }
    end
    if bottom_h > 0 then detail_column[#detail_column + 1] = bottom_details end
    local cell_h = content_h + layout.strip_h
    local detail_row = HorizontalGroup:new{
        align = "center",
        CenterContainer:new{ dimen = Geom:new{ w = cover_w, h = content_h }, cover },
        HorizontalSpan:new{ width = gap },
        CenterContainer:new{
            dimen = Geom:new{ w = text_w, h = content_h },
            ignore_if_over = "height",
            detail_column,
        },
    }
    local content = VerticalGroup:new{ align = "center", detail_row }
    if layout.strip_h > 0 then
        content[#content + 1] = VerticalSpan:new{ width = layout.strip_h }
    end

    local DetailsCell = InputContainer:extend{}
    function DetailsCell:init()
        self.dimen = self.dimen or Geom:new{ w = self.width, h = self.height }
        self.ges_events = {
            TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
        }
    end
    function DetailsCell:paintTo(bb, x, y)
        self.dimen.x, self.dimen.y = x, y
        self[1]:paintTo(bb, x, y)
        if self.focused then
            local line = math.max(1, Screen:scaleBySize(2))
            bb:paintRect(x, y + self.height - line, self.width, line,
                Blitbuffer.COLOR_BLACK)
        end
    end
    function DetailsCell:onTapSelect()
        if self.callback then self.callback() end
        return true
    end
    function DetailsCell:onFocus()
        self.focused = true
        UIManager:setDirty(nil, "fast", self.dimen)
        return true
    end
    function DetailsCell:onUnfocus()
        self.focused = false
        UIManager:setDirty(nil, "fast", self.dimen)
        return true
    end

    local callback = function()
        if type(opts.open_details) == "function" then opts.open_details() end
    end
    local cell = DetailsCell:new{
        width = inner_w,
        height = cell_h,
        dimen = Geom:new{ w = inner_w, h = cell_h },
        callback = callback,
        content,
    }
    refs.buttons[1] = { widget = cell, callback = callback }
    refs.layout_rows[1] = { cell }

    return VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = layout.top_padding },
        CenterContainer:new{ dimen = Geom:new{ w = width, h = cell_h }, cell },
        VerticalSpan:new{ width = padding },
    }, refs
end

return M
