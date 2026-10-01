local _ = require("gettext")
local M = {}

function M.stats(statistics)
    local summary = statistics and statistics:getStatsBookStatus()
    if not summary then return {} end
    local days, seconds, pages = summary.days or 0, summary.time or 0, summary.pages or 0
    return {
        book_days = tostring(days),
        book_duration = require("datetime").secondsToClockDuration("letters", seconds, false),
        book_page_minutes = pages > 0 and string.format("%.1f", seconds / pages / 60) or nil,
        book_daily_minutes = days > 0 and string.format("%.1f", seconds / days / 60) or nil,
    }
end

function M.quotes(ui)
    local annotation = ui.annotation
    if annotation then annotation:updatePageNumbers() end
    local items = annotation and annotation.annotations or ui.doc_settings:readSetting("annotations") or {}
    local quotes = {}
    for _i, item in ipairs(items) do
        if item.drawer and type(item.text) == "string" and item.text ~= "" then
            local page_label = ui.bookmark:getBookmarkPageString(item.page)
            quotes[#quotes + 1] = {
                text = item.text .. (item.note and item.note ~= "" and "\n\n" .. item.note or ""),
                title = ui.doc_props.title,
                page_label = tostring(page_label or item.pageno or ""),
                page = item.page,
                pos0 = item.pos0,
                is_annotation = true,
            }
        end
    end
    return quotes
end

-- Group queries already exclude missing files and books outside the library.
function M.recommendations(file, book, author_groups, series_groups, get_status)
    local result = { author = {}, next_series = {}, other_series = {} }
    local authors, seen = {}, {}
    for author in (book.authors or ""):gmatch("[^\n]+") do
        authors[author:match("^%s*(.-)%s*$")] = true
    end
    for _i, group in ipairs(author_groups) do
        local matches = false
        for author in group.author:gmatch("[^\n]+") do
            if authors[author:match("^%s*(.-)%s*$")] then matches = true; break end
        end
        if matches then
            for _j, path in ipairs(group.files) do
                if path ~= file and not seen[path] then
                    result.author[#result.author + 1] = path
                    seen[path] = true
                end
            end
        end
    end
    local statuses = {}
    local function status(path)
        if statuses[path] == nil then statuses[path] = get_status(path) or "new" end
        return statuses[path]
    end
    for _i, group in ipairs(series_groups) do
        local current_index = tonumber(book.series_index)
        local current_position, last_finished, reading
        for index, item in ipairs(group.items) do
            if item.file == file then current_position = index end
        end
        if group.series == book.series then
            for index, item in ipairs(group.items) do
                local follows = current_index and tonumber(item.series_index)
                    and tonumber(item.series_index) > current_index
                    or not current_index and current_position and index > current_position
                if item.file ~= file and follows and status(item.file) ~= "complete" then
                    result.next_series[1] = item.file
                    break
                end
            end
        else
            for index, item in ipairs(group.items) do
                local value = status(item.file)
                if value == "reading" and not reading then reading = item.file end
                if value == "complete" then last_finished = index end
            end
            local next_book = reading
            if not next_book and last_finished then
                for index = last_finished + 1, #group.items do
                    local path = group.items[index].file
                    if status(path) ~= "complete" and status(path) ~= "abandoned" then
                        next_book = path
                        break
                    end
                end
            end
            if next_book and next_book ~= file then
                result.other_series[#result.other_series + 1] = next_book
            end
        end
    end
    return result
end

function M.new(ui, plugin, config, refresh, close)
    require("modules/filebrowser/patches/home_page")
    local Home = require("common/shared_state").get(plugin, "home")
    local data = Home.newDataProvider(plugin.config, config)
    local file = ui.document.file
    Home.invalidateBookCache(file)
    local book = data:getBook(file) or { path = file }
    if not book.cover_bb then
        book.cover_bb = require("apps/filemanager/filemanagerbookinfo"):getCoverImage(ui.document)
        book.has_real_cover = book.cover_bb ~= nil
    end
    local props = ui.doc_props
    book.title = props.title or book.title
    book.authors = props.authors or book.authors
    book.series = props.series or book.series
    book.series_index = props.series_index or book.series_index
    local summary = ui.doc_settings:readSetting("summary") or {}
    local percent, pages, current_label, last_label = require("modules/reader/book_details").getProgress(ui)
    book.pages = pages
    book.current_page = ui:getCurrentPage()
    book.percent = percent or 0
    book.stable_pages = nil
    book.stable_current_page = nil
    book.stable_current_label = current_label and tostring(current_label)
    book.stable_last_label = last_label and tostring(last_label)
    book.bookinfo = { title = book.title, authors = book.authors }
    book.description = summary.status == "complete" and _("Finished reading") or _("End of book")
    if summary.status == "complete" and summary.modified then
        book.description = book.description .. "\n" .. string.format(_("Finished on %s"), summary.modified)
    end
    function data:getFeaturedBook()
        local copy = {}
        for key, value in pairs(book) do copy[key] = value end
        if book.cover_bb then copy.cover_bb = book.cover_bb:copy() end
        return copy
    end
    data.stats = M.stats(ui.statistics)
    local quotes = M.quotes(ui)
    local quote_index = 1
    function data:getCurrentQuote()
        return quotes[quote_index] or { text = _("No highlights in this book."), is_empty = true }
    end
    function data:nextQuote()
        if #quotes > 0 then quote_index = quote_index % #quotes + 1; refresh() end
    end
    function data:prevQuote()
        if #quotes > 0 then quote_index = (quote_index - 2) % #quotes + 1; refresh() end
    end
    function data:openQuote(quote)
        close()
        ui.bookmark:gotoBookmark(quote.page, quote.pos0)
        return true
    end
    local recommendations
    function data:getRecommendations()
        if not recommendations then
            local db = require("common/db_bookinfo")
            recommendations = M.recommendations(file, book, db.getGroupedByAuthor(),
                db.getGroupedBySeries(), require("common/book_status").getEffectiveStatusFromFile)
        end
        return recommendations
    end
    function data:free()
        if book.cover_bb then book.cover_bb:free(); book.cover_bb = nil end
    end
    return data
end

return M
