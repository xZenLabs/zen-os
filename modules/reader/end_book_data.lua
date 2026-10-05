local _ = require("gettext")
local M = {}
M.MAX_ACTIONS = 5
M.WIDGET_UNITS = { featured = 3.75 }
M.FEATURED_TEXT_STYLES = {
    title = { font_face = "default", font_size = 14, bold = true },
    author = { font_face = "default", font_size = 11, bold = false },
    series = { font_face = "default", font_size = 9, bold = false },
    progress = { font_face = "default", font_size = 9, bold = false },
    status = { font_face = "default", font_size = 11, bold = true },
    navigation = { font_face = "default", font_size = 15, bold = false },
}

function M.usedUnits(enabled, modules)
    local Registry = require("modules/filebrowser/patches/home/components/registry")
    local used = Registry.totalUnits(enabled, modules)
    for id, units in pairs(M.WIDGET_UNITS) do
        if enabled[id] then used = used + units - Registry.sizeUnits(Registry.get(id), modules[id]) end
    end
    return used
end

M.actions = {
    { id = "library", label = _("Library"), icon = "library", destination = { target_tab = "books" } },
    { id = "series", label = _("Series"), icon = "tab_series", destination = { target_tab = "series" } },
    { id = "to_be_read", label = _("To Be Read"), icon = "tab_to_be_read", destination = { target_tab = "to_be_read" } },
    { id = "home", label = _("Home"), icon = "home", destination = { open_home = true } },
    { id = "archive", label = _("Archive"), icon = "archive" },
    { id = "next_file", label = _("Open next file"), icon = "tab_right" },
    { id = "restart", label = _("Restart Book"), icon = "restart" },
}

function M.featuredActions(config)
    local result, seen = {}, {}
    local selected = config.navigation_actions or require("config/defaults").end_book.modules.featured.navigation_actions
    for _i, id in ipairs(selected) do
        for _j, entry in ipairs(M.actions) do
            if id == entry.id and not seen[id] then
                result[#result + 1] = entry
                seen[id] = true
                break
            end
        end
        if #result == M.MAX_ACTIONS then break end
    end
    return result
end

function M.featuredConfig(plugin)
    local config = plugin.config.end_book.modules.featured or {}
    local Presets = require("modules/filebrowser/patches/home/home_presets")
    local changed = false
    if config.use_home_settings ~= nil or not config.text_styles then
        if config.use_home_settings ~= false then
            local home = Presets.copy(require("config/preset_store").getSettings("home"))
            Presets.normalizeFeaturedConfig(home)
            home.modules.featured.show_status_bar = config.show_status_bar == true
            home.modules.featured.show_description = config.show_description == true
            home.modules.featured.navigation_icon_size = config.navigation_icon_size or 0
            home.modules.featured.show_navigation_labels = config.show_navigation_labels
            home.modules.featured.navigation_actions = Presets.copy(config.navigation_actions
                or require("config/defaults").end_book.modules.featured.navigation_actions)
            home.modules.featured.navigation_icons = Presets.copy(config.navigation_icons or {})
            config = home.modules.featured
        else
            Presets.normalizeFeaturedConfig({ modules = { featured = config } })
        end
        config.use_home_settings = nil
        changed = true
    end
    if not config.text_styles.status then
        -- Enlarge untouched defaults once; keep custom sizes.
        local home_styles = Presets.defaultHomePage().modules.featured.text_styles
        for key, defaults in pairs(M.FEATURED_TEXT_STYLES) do
            local style = config.text_styles[key]
            if not style then
                config.text_styles[key] = Presets.copy(defaults)
            elseif home_styles[key] and style.font_size == home_styles[key].font_size then
                style.font_size = defaults.font_size
            end
        end
        changed = true
    end
    if changed then
        plugin.config.end_book.modules.featured = config
        plugin:saveConfig()
    end
    local featured = Presets.copy(config)
    featured.show_status_bar, featured.show_description = false, false
    return featured
end

function M.stripConfig(recommendations, source, config, authors)
    local Presets = require("modules/filebrowser/patches/home/home_presets")
    local home = Presets.copy(require("config/preset_store").getSettings("home"))
    Presets.normalizeStripConfig(home)
    local utils = require("common/utils")
    local local_cfg = config and config.modules.strip or {}
    local strip = Presets.copy(local_cfg)
    utils.deepmerge(strip, require("config/defaults").end_book.modules.strip)
    strip.controls.text_style = strip.controls.text_style or Presets.copy(home.modules.strip.controls.text_style)
    home.modules.strip.controls = nil
    utils.deepmerge(strip, home.modules.strip)
    local controls = strip.controls
    local author_name = (authors or ""):match("^%s*(.-)%s*$"):gsub("%s*\n%s*", ", "):gsub("%s+", " ")
    for _i, entry in ipairs(require("modules/settings/sections/end_book_settings").sources) do
        local button = require("common/nav_button_model").find(controls, entry[1])
        if not button and controls.show_buttons[entry[1]] ~= nil then
            button = { id = entry[1], type = "custom_source", label = entry[2], paths = {} }
            controls.custom_buttons[#controls.custom_buttons + 1] = button
        end
        if button then
            if button.type == "custom_source" then
                if entry[1] == "author" then
                    button.label = author_name ~= "" and require("ffi/util").template(_("More by %1"), author_name)
                        or entry[2]
                end
                button.paths = recommendations and recommendations[entry[1]] or {}
            end
            if recommendations and (button.type == "custom_source" or entry[1] == "continue")
                    and #(recommendations[entry[1]] or {}) == 0 then
                controls.show_buttons[entry[1]] = false
            end
        end
    end
    if not recommendations then return strip end
    local ButtonModel = require("common/nav_button_model")
    local descriptor = source and controls.show_buttons[source]
        and ButtonModel.sourceDescriptor(ButtonModel.find(controls, source))
    if not descriptor then descriptor, source = ButtonModel.firstVisibleSource(controls) end
    if not descriptor then return nil end
    strip.default_source = descriptor
    return strip, source
end

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
    local realpath = require("ffi/util").realpath
    local current_file = realpath(file) or file
    local function is_current(path)
        return path == file or path == current_file or realpath(path) == current_file
    end
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
                if not seen[path] and not is_current(path) then
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
        if group.series == book.series then
            if not current_index then
                for index, item in ipairs(group.items) do
                    if is_current(item.file) then current_position = index; break end
                end
            end
            for index, item in ipairs(group.items) do
                local follows = current_index and tonumber(item.series_index)
                    and tonumber(item.series_index) > current_index
                    or not current_index and current_position and index > current_position
                if follows and not is_current(item.file) and status(item.file) ~= "complete" then
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
            if next_book and not is_current(next_book) then
                local files = {}
                for _j, item in ipairs(group.items) do files[#files + 1] = item.file end
                result.other_series[#result.other_series + 1] = { series = group.series, files = files }
            end
        end
    end
    return result
end

function M.new(ui, plugin, config, refresh, close)
    require("modules/filebrowser/patches/home_page")
    local Home = require("common/shared_state").get(plugin, "home")
    local data = Home.newDataProvider(plugin.config, config)
    local file = ui and ui.document.file or G_reader_settings:readSetting("lastfile")
    if file then Home.invalidateBookCache(file) end
    local book = file and (data:getBook(file) or { path = file }) or data:getFeaturedBook("recently_read")
    book = book or { title = _("No books to show.") }
    file = book.path
    data.file = file
    if file and not book.cover_bb then
        book.cover_bb = require("apps/filemanager/filemanagerbookinfo"):getCoverImage(ui and ui.document, file)
        book.has_real_cover = book.cover_bb ~= nil
    end
    local props = ui and ui.doc_props or {}
    book.title = props.title or book.title
    book.authors = props.authors or book.authors
    data.authors = book.authors
    book.series = props.series or book.series
    book.series_index = props.series_index or book.series_index
    if ui then
        local summary = ui.doc_settings:readSetting("summary") or {}
        book.status = summary.status or book.status
        local percent, pages, current_label, last_label = require("modules/reader/book_details").getProgress(ui)
        book.pages = pages
        book.current_page = ui:getCurrentPage()
        book.percent = percent or 0
        book.stable_pages = nil
        book.stable_current_page = nil
        book.stable_current_label = current_label and tostring(current_label)
        book.stable_last_label = last_label and tostring(last_label)
    end
    book.bookinfo = { title = book.title, authors = book.authors }
    function data:getFeaturedBook()
        local copy = {}
        for key, value in pairs(book) do copy[key] = value end
        if book.cover_bb then copy.cover_bb = book.cover_bb:copy() end
        return copy
    end
    data.stats = M.stats(ui and ui.statistics)
    local quotes = ui and M.quotes(ui) or {}
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
        if not ui then return true end
        close()
        ui.bookmark:gotoBookmark(quote.page, quote.pos0)
        return true
    end
    local recommendations
    function data:invalidateRecommendations()
        recommendations = nil
    end
    function data:getRecommendations()
        if not recommendations then
            local db = require("common/db_bookinfo")
            recommendations = file and M.recommendations(file, book, db.getGroupedByAuthor(),
                db.getGroupedBySeries(), require("common/book_status").getEffectiveStatusFromFile)
                or { author = {}, next_series = {}, other_series = {} }
        end
        local controls = plugin.config.end_book and plugin.config.end_book.modules.strip.controls
        if controls and controls.show_buttons.continue and recommendations.continue == nil then
            recommendations.continue = self:getContinuePaths()
        end
        return recommendations
    end
    function data:free()
        if book.cover_bb then book.cover_bb:free(); book.cover_bb = nil end
    end
    return data
end

return M
