local Device = require("device")
local Font = require("ui/font")
local UIManager = require("ui/uimanager")
local Cover = require("common/cover_utils")
local LanguageName = require("common/language_name")
local LibraryFont = require("modules/filebrowser/patches/library_font")
local ReaderFont = require("common/reader_font")
local utils = require("common/utils")
local T = require("ffi/util").template
local _ = require("gettext")

local M = {}
local BOOK_DETAIL_ORDER = {
    "authors", "series", "tags", "language", "rating", "annotations", "note",
    "pages", "progress", "read_time", "time_remaining",
}

local function normalize_detail_order(order)
    local normalized, seen, valid = {}, {}, {}
    for _i, id in ipairs(BOOK_DETAIL_ORDER) do valid[id] = true end
    for _i, id in ipairs(type(order) == "table" and order or {}) do
        if valid[id] and not seen[id] then
            normalized[#normalized + 1], seen[id] = id, true
        end
    end
    for _i, id in ipairs(BOOK_DETAIL_ORDER) do
        if not seen[id] then normalized[#normalized + 1] = id end
    end
    return normalized
end

local function read_setting(settings, key)
    if not (settings and type(settings.readSetting) == "function") then return nil end
    local ok, value = pcall(settings.readSetting, settings, key)
    return ok and value or nil
end

local function positive_number(value)
    value = tonumber(value)
    return value and value > 0 and value or nil
end

local function nonnegative_number(value)
    value = tonumber(value)
    return value and value >= 0 and value < math.huge and value or nil
end

local function is_present(text)
    if text == nil then return false end
    text = tostring(text):match("^%s*(.-)%s*$")
    return text ~= "" and text:lower() ~= "n/a"
end

local function current_page_info(ui)
    local footer = ui and ui.view and ui.view.footer
    local document = ui and ui.document
    local current = footer and positive_number(footer.pageno)
    local total = footer and positive_number(footer.pages)
    if not current and document and type(document.getCurrentPage) == "function" then
        local ok, value = pcall(document.getCurrentPage, document)
        if ok then current = positive_number(value) end
    end
    if not total and document and type(document.getPageCount) == "function" then
        local ok, value = pcall(document.getPageCount, document)
        if ok then total = positive_number(value) end
    end
    return current, total
end

local function page_map_labels(ui, settings)
    local pagemap = ui and ui.pagemap
    local uses_labels = read_setting(settings, "pagemap_use_page_labels") == true
    if pagemap and type(pagemap.wantsPageLabels) == "function" then
        local ok, value = pcall(pagemap.wantsPageLabels, pagemap)
        if ok and value then uses_labels = true end
    end
    if not uses_labels then return nil, nil end

    local current, total
    if pagemap and type(pagemap.getCurrentPageLabel) == "function" then
        local ok, value = pcall(pagemap.getCurrentPageLabel, pagemap, true)
        if ok and is_present(value) then current = value end
    end
    if pagemap and type(pagemap.getLastPageLabel) == "function" then
        local ok, value = pcall(pagemap.getLastPageLabel, pagemap, true)
        if ok and is_present(value) then total = value end
    end
    current = current or read_setting(settings, "pagemap_current_page_label")
    total = total or read_setting(settings, "pagemap_last_page_label")
    return is_present(current) and current or nil, is_present(total) and total or nil
end

local function format_series(series, index)
    if not is_present(series) then return nil end
    series = tostring(series)
    index = tonumber(index)
    if not index then return series end
    local index_text = index == math.floor(index)
        and tostring(math.floor(index)) or string.format("%.10g", index)
    return series .. " #" .. index_text
end

local function format_genres(keywords)
    if not is_present(keywords) then return nil end
    return tostring(keywords)
        :gsub("%s*[\n;]%s*", ", ")
        :gsub("%s+\xC2\xB7%s+", ", ")
        :gsub("^,%s*", ""):gsub(",%s*$", "")
end

local function split_tags(keywords)
    local formatted = format_genres(keywords)
    if not formatted then return {} end
    local tags = {}
    local seen = {}
    for tag in formatted:gmatch("[^,]+") do
        tag = tag:match("^%s*(.-)%s*$")
        if tag ~= "" and not seen[tag] then
            tags[#tags + 1] = tag
            seen[tag] = true
        end
    end
    return tags
end

function M.formatPageText(current, total)
    if not (is_present(current) and is_present(total)) then return nil end
    return T(_("Page %1 of %2"), tostring(current), tostring(total))
end

function M.getProgress(ui)
    local settings = ui and ui.doc_settings
    local footer = ui and ui.view and ui.view.footer
    local ratio = footer and tonumber(footer.percent_finished)
    if ratio == nil and footer and type(footer.getBookProgress) == "function" then
        local ok, value = pcall(footer.getBookProgress, footer)
        if ok then ratio = tonumber(value) end
    end
    local current, document_pages = current_page_info(ui)
    if ratio == nil and current and document_pages then ratio = current / document_pages end
    if ratio == nil then ratio = tonumber(read_setting(settings, "percent_finished")) end
    if ratio ~= nil then
        if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end
    end

    local pages
    if read_setting(settings, "pagemap_use_page_labels") == true then
        pages = positive_number(read_setting(settings, "pagemap_doc_pages"))
            or positive_number(read_setting(settings, "pagemap_last_page_label"))
    end
    pages = pages
        or positive_number(read_setting(settings, "doc_pages"))
        or positive_number(ui and ui.doc_props and ui.doc_props.pages)
        or document_pages
    if not pages and ui and ui.document and ui.document.file then
        pages = positive_number(utils.getStablePageCount(
            ui.document.file, nil, { doc_settings = settings, sidecar_checked = true }))
    end
    local page_current, page_total = page_map_labels(ui, settings)
    page_total = page_total or pages
    if not page_current then
        page_current = current
        if pages and ratio and (not page_current or pages ~= document_pages) then
            page_current = math.floor(pages * ratio + 0.5)
            if ratio > 0 and page_current < 1 then page_current = 1 end
            if page_current > pages then page_current = pages end
        end
    end
    return ratio, pages, page_current, page_total
end

function M.getReadingTimes(ui, requested)
    requested = type(requested) == "table" and requested
        or { read_time = true, time_remaining = true }
    local stats = ui and ui.statistics
    local ok_db, StatsDB = pcall(require, "common/db_stats")
    if not ok_db or type(StatsDB.queryBookDetails) ~= "function" then
        return nil, nil, nil, nil
    end
    local result
    if type(stats) == "table" then
        local ok, queried = pcall(StatsDB.queryBookDetails, stats, requested)
        if ok and type(queried) == "table" then result = queried end
    end
    result = result or {}

    local read_time = requested.read_time == true
        and nonnegative_number(result.read_time) or nil
    local avg_time = type(stats) == "table" and tonumber(stats.avg_time) or nil
    local db_pages
    if (requested.read_time == true and read_time == nil)
            or (requested.time_remaining == true
                and not (avg_time and avg_time > 0 and avg_time < math.huge)) then
        local file = ui and ui.document and ui.document.file
        if file and type(StatsDB.queryBookAveragePageTime) == "function" then
            local ok, fallback_avg, fallback_pages, fallback_read = pcall(
                StatsDB.queryBookAveragePageTime, file)
            if ok then
                avg_time = tonumber(fallback_avg) or avg_time
                db_pages = positive_number(fallback_pages)
                if requested.read_time == true and read_time == nil then
                    read_time = nonnegative_number(fallback_read)
                end
            end
        end
    end

    local time_left
    local current_page, total_pages = current_page_info(ui)
    if not (current_page and total_pages) then
        local ratio, pages, derived_current, derived_total = M.getProgress(ui)
        total_pages = total_pages or derived_total or db_pages or pages
        current_page = current_page or derived_current
        if not current_page and ratio and total_pages then
            current_page = math.floor(total_pages * ratio + 0.5)
        end
    end
    if requested.time_remaining == true
            and avg_time and avg_time > 0 and avg_time < math.huge
            and current_page and total_pages and current_page <= total_pages then
        local pages_left = total_pages - current_page
        if db_pages and total_pages > 0 then
            pages_left = pages_left * db_pages / total_pages
        elseif type(stats) == "table"
                and type(stats._zenPagesInStatisticsUnits) == "function" then
            pages_left = stats:_zenPagesInStatisticsUnits(pages_left)
        end
        time_left = math.floor(pages_left * avg_time + 0.5)
    end

    local today_duration = requested.time_today == true
        and nonnegative_number(result.time_today) or nil
    local today_pages = requested.pages_today == true
        and nonnegative_number(result.pages_today) or nil
    return time_left, read_time, today_duration, today_pages
end

local function time_unit(unit)
    if type(_) == "table" and type(_.pgettext) == "function" then
        return _.pgettext("Time", unit)
    end
    return _(unit)
end

function M.formatDuration(seconds)
    seconds = math.floor(tonumber(seconds) or 0)
    if seconds <= 0 then return "0" .. time_unit("m") end
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    if hours > 0 then
        return hours .. time_unit("h") .. " " .. minutes .. time_unit("m")
    end
    return math.max(1, minutes) .. time_unit("m")
end

function M.getSummary(ui)
    local file = ui and ui.document and ui.document.file
    if not file then return nil end
    local props = type(ui.doc_props) == "table" and ui.doc_props or {}
    local ratio, pages, current_page, page_total = M.getProgress(ui)
    return {
        path = file,
        title = is_present(props.title) and props.title or file:match("([^/]+)$"),
        authors = is_present(props.authors) and props.authors or "",
        series = format_series(props.series, props.series_index),
        genres = format_genres(props.keywords),
        tags = split_tags(props.keywords),
        pages = pages,
        current_page = current_page,
        page_total = page_total,
        page_text = M.formatPageText(current_page, page_total),
        progress = ratio,
        bookinfo = props,
    }
end

local function rounded_covers_enabled(config)
    config = type(config) == "table" and config
        or rawget(_G, "__ZEN_UI_PLUGIN") and rawget(_G, "__ZEN_UI_PLUGIN").config
    return type(config) == "table" and type(config.features) == "table"
        and config.features.browser_cover_rounded_corners == true
end

function M.buildSpec(ui, opts)
    opts = opts or {}
    local summary = M.getSummary(ui)
    if not summary then return nil end

    local config = type(opts.config) == "table" and opts.config or {}
    local visibility = type(config.book_details) == "table" and config.book_details or {}
    local navigate_tags = visibility.navigate_to_tag == true
    local function enabled(id)
        if type(visibility[id]) == "boolean" then return visibility[id] end
        return id ~= "read_time" and id ~= "time_remaining"
    end

    local file = summary.path
    local props = type(ui.doc_props) == "table" and ui.doc_props or {}
    local settings = ui.doc_settings
    local book_summary = read_setting(settings, "summary")
    if type(book_summary) ~= "table" then book_summary = {} end
    local annotations = ui.annotation and ui.annotation.annotations
    if type(annotations) ~= "table" then
        annotations = read_setting(settings, "annotations")
    end
    local description = enabled("description") and props.description or nil
    if description then
        local ok_util, util = pcall(require, "util")
        if ok_util and util.htmlToPlainTextIfHtml then
            description = util.htmlToPlainTextIfHtml(description)
        end
    end

    local details = {}
    local function add_detail(text, style, bold, gap_before)
        if is_present(text) then
            details[#details + 1] = {
                text = tostring(text),
                style = style,
                bold = bold,
                gap_before = gap_before,
            }
        end
    end

    local function add_rating()
        if not enabled("rating") then return end
        local rating = book_summary.rating
        local numeric_rating = tonumber(rating)
        if (not numeric_rating or numeric_rating > 0) and is_present(rating) then
            local ok_list, BookList = pcall(require, "ui/widget/booklist")
            local rating_text = ok_list and BookList and BookList.getBookRatingString
                and BookList.getBookRatingString(rating) or rating
            add_detail(rating_text, "secondary", false, 3)
        end
    end
    local annotation_count = type(annotations) == "table" and #annotations or 0
    local time_left, read_time
    if enabled("read_time") or enabled("time_remaining") then
        time_left, read_time = M.getReadingTimes(ui, {
            read_time = enabled("read_time"),
            time_remaining = enabled("time_remaining"),
        })
    end
    local detail_builders = {
        authors = function()
            if enabled("authors") then add_detail(summary.authors, "author", false, 2) end
        end,
        series = function()
            if enabled("series") then add_detail(summary.series, "secondary", false, 2) end
        end,
        tags = function()
            if not enabled("tags") then return end
            if navigate_tags and #summary.tags > 0 then
                details[#details + 1] = {
                    style = "tag_buttons",
                    tags = summary.tags,
                    gap_before = 3,
                }
            else
                add_detail(summary.genres, "tags", false, 3)
            end
        end,
        language = function()
            if enabled("language") then
                add_detail(LanguageName.get(props.language), "secondary", false, 3)
            end
        end,
        rating = add_rating,
        annotations = function()
            if enabled("annotations") and annotation_count > 0 then
                add_detail(tostring(annotation_count) .. " " .. _("Annotations"),
                    "secondary", false, 3)
            end
        end,
        note = function()
            if enabled("note") then add_detail(book_summary.note, "secondary", false, 3) end
        end,
        pages = function()
            if enabled("pages") then add_detail(summary.page_text, "page", false, 3) end
        end,
        progress = function()
            if enabled("progress") and tonumber(summary.progress) then
                details[#details + 1] = {
                    style = "progress",
                    progress = summary.progress,
                    pages = summary.pages,
                    right_text = "",
                    gap_before = 3,
                }
            end
        end,
        read_time = function()
            if enabled("read_time") and read_time ~= nil then
                add_detail(string.format(_("Read: %s"), M.formatDuration(read_time)),
                    "secondary", false, 3)
            end
        end,
        time_remaining = function()
            if enabled("time_remaining") and time_left ~= nil then
                add_detail(string.format(_("Remaining: %s"), M.formatDuration(time_left)),
                    "secondary", false, 3)
            end
        end,
    }

    add_detail(summary.title, "title", true)
    local order = normalize_detail_order(visibility.order)
    local skip_next = false
    for index, id in ipairs(order) do
        if skip_next then
            skip_next = false
        else
            local next_id = order[index + 1]
            local paired_times = ((id == "read_time" and next_id == "time_remaining")
                    or (id == "time_remaining" and next_id == "read_time"))
                and enabled(id) and enabled(next_id)
                and read_time ~= nil and time_left ~= nil
            if paired_times then
                add_detail(string.format(_("Read: %s"), M.formatDuration(read_time))
                    .. " / " .. string.format(_("Remaining: %s"),
                        M.formatDuration(time_left)), "secondary", false, 3)
                skip_next = true
            else
                detail_builders[id]()
            end
        end
    end

    local reader_font_size = ReaderFont.getInfo(ui,
        (Font.sizemap and Font.sizemap.cfont) or 16).size
    local library_face = LibraryFont.getFace(reader_font_size)
    local metadata_face = LibraryFont.getFace(math.max(1,
        math.floor(reader_font_size * 18 / 20 + 0.5)))
    local text_faces = {
        title = library_face,
        author = metadata_face,
        tags = metadata_face,
        page = metadata_face,
        secondary = metadata_face,
    }

    local cover_bb, cover_w, cover_h, cover_kind
    if Cover and Cover.makeCover then
        local target_h = math.floor(Device.screen:getHeight() * 0.30)
        local target_w = math.floor(target_h * Cover.getRatio())
        local cover = { Cover.makeCover(file, nil, {
            is_folder = false,
            width = target_w,
            height = target_h,
            need_copy = true,
        }) }
        cover_bb, cover_w, cover_h, cover_kind = cover[1], cover[2], cover[3], cover[5]
        if cover_bb and cover_kind ~= "real_cover" and cover_bb.copy then
            cover_bb = cover_bb:copy()
        end
    end

    local function show_cover_fullscreen()
        local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
        if not ok_bim then return end
        local bookinfo = BookInfoManager:getBookInfo(file, true)
        if not bookinfo or not bookinfo.cover_bb or not bookinfo.has_cover
                or bookinfo.ignore_cover then return end
        local ImageViewer = require("ui/widget/imageviewer")
        local viewer = ImageViewer:new{
            image = bookinfo.cover_bb,
            image_disposable = false,
            fullscreen = true,
            with_title_bar = false,
        }
        viewer.onTap = function(viewer_self)
            viewer_self:onClose()
            return true
        end
        UIManager:show(viewer)
    end

    local tag_callback
    if navigate_tags then
        tag_callback = function(tag)
            local plugin = opts.plugin
            if opts.home_context == true then
                local ok_shared, SharedState = pcall(require, "common/shared_state")
                local home = ok_shared and SharedState.get(plugin, "home") or nil
                if home and type(home.showTagInStrip) == "function"
                        and home.showTagInStrip(tag) then return true end
            end
            return require("common/dispatch_action").onShowZenUITag(plugin, tag)
        end
    end

    return {
        title = _("Book details"),
        details = details,
        description = description or "",
        show_description = enabled("description"),
        tag_callback = tag_callback,
        cover = cover_bb,
        cover_width = cover_w,
        cover_height = cover_h,
        cover_tap_callback = show_cover_fullscreen,
        rounded_cover = rounded_covers_enabled(opts.config),
        text_face = library_face,
        text_size = reader_font_size,
        text_faces = text_faces,
        edit_callback = opts.edit_callback,
        close_all_callback = opts.close_all_callback,
    }
end

function M.show(ui, opts)
    local spec = M.buildSpec(ui, opts)
    if not spec then return false end
    local BookInfoWidget = require("modules/reader/book_info_widget")
    UIManager:show(BookInfoWidget:new(spec))
    return true
end

function M.showFile(file, opts)
    if type(file) ~= "string" or file == "" then return false end

    local props = {}
    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if ok_bim and BookInfoManager and type(BookInfoManager.getBookInfo) == "function" then
        local ok_info, bookinfo = pcall(BookInfoManager.getBookInfo,
            BookInfoManager, file, false)
        if ok_info and type(bookinfo) == "table" and not bookinfo.ignore_meta then
            props = bookinfo
        end
    end

    local doc_settings
    local ok_settings, DocSettings = pcall(require, "docsettings")
    if ok_settings and DocSettings and type(DocSettings.open) == "function" then
        local ok_open, settings = pcall(DocSettings.open, DocSettings, file)
        if ok_open then doc_settings = settings end
    end

    return M.show({
        document = { file = file },
        doc_props = props,
        doc_settings = doc_settings,
    }, opts)
end

return M
