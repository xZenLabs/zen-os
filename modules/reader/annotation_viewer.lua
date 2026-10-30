local Annotations = require("modules/reader/annotations")
local BookNote = require("modules/reader/book_note")
local Blitbuffer = require("ffi/blitbuffer")
local DateFormat = require("common/date_format")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LibraryFont = require("modules/filebrowser/patches/library_font")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local T = require("ffi/util").template
local TextBoxWidget = require("ui/widget/textboxwidget")
local TitleBar = require("ui/widget/titlebar")
local TitleStyle = require("common/ui/zen_title_style")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local util = require("util")
local utils = require("common/utils")
local _ = require("gettext")

local M = {}
local icons_dir = require("common/plugin_root") .. "/icons/"
local titles = { bookmarks = _("Bookmarks"), highlights = _("Highlights"), annotations = _("Annotations") }
local facets = { { "file", _("Books") }, { "chapter", _("Chapters") }, { "tags", _("Tags") },
    { "color", _("Color") }, { "style", _("Style") } }

local function message(text)
    UIManager:show(require("ui/widget/infomessage"):new{ text = text })
end

local function dialog(pbw, title, rows, anchor)
    local widget = require("common/ui/zen_anchored_menu").new{
        title = title, buttons = rows, anchor = anchor or pbw._zen_more_button.dimen, anchor_right = true, rows_per_page = 9,
    }
    UIManager:show(widget)
    return widget
end

local function settings(pbw)
    return pbw._zen_plugin.config.annotation_viewer or {}
end

local function page_text(record)
    return record.page_label ~= "" and T(_("Page %1"), record.page_label) or ""
end

local function highlight(pbw)
    return pbw.ui and pbw.ui.highlight or require("apps/reader/modules/readerhighlight")
end

function M.session(pbw)
    if not pbw._zen_annotations then
        pbw._zen_annotations = Annotations.new(pbw.ui)
        pbw._zen_annotations:refreshCurrent()
    end
    return pbw._zen_annotations
end

local function refresh(pbw, file)
    if pbw._zen_closed then return end
    M.session(pbw):refreshCurrent()
    if file and (not pbw.ui or file ~= pbw.ui.document.file) then M.session(pbw):refreshBook(file) end
    pbw:updateLayout()
    UIManager:setDirty(pbw, "ui")
end

local function edit_note(pbw, record)
    local file = record and record.file or pbw.ui.document.file
    BookNote.show(file, function() refresh(pbw, file) end)
end

local function native_action(pbw, record, action)
    local function run(ui)
        local index, annotation = Annotations.resolve(ui, record)
        if not index then message(_("This annotation is no longer available.")); return end
        if action == "goto" then
            if ui.link then ui.link:addCurrentLocationToStack() end
            ui.bookmark:gotoBookmark(annotation.page, annotation.pos0)
        elseif action == "note" then
            ui.bookmark:setBookmarkNote(index, nil, nil, function() refresh(pbw) end)
        elseif action == "style" then
            ui.highlight:editHighlightStyle(index)
        elseif action == "color" then
            ui.highlight:editHighlightColor(index)
        elseif action == "delete" then
            ui.bookmark:removeItem(annotation, index)
            refresh(pbw)
        end
        if action == "style" or action == "color" then
            local selector = UIManager:getTopmostVisibleWidget()
            local on_close = selector.onCloseWidget
            selector.onCloseWidget = function(self, ...)
                local result = on_close(self, ...)
                UIManager:nextTick(function() refresh(pbw) end)
                return result
            end
        end
    end
    if not pbw.ui or record.file ~= pbw.ui.document.file then
        if require("libs/libkoreader-lfs").attributes(record.file, "mode") ~= "file" then
            message(_("This book is no longer available.")); return
        end
        pbw:onClose(true)
        if pbw.ui then
            pbw.ui:switchDocument(record.file, nil, run)
        else
            require("apps/reader/readerui"):showReader(record.file, nil, nil, nil, run)
        end
    else
        if action == "goto" then pbw:onClose(true) end
        run(pbw.ui)
    end
end

function M.showDetails(pbw, record)
    local viewer
    local function close() UIManager:close(viewer) end
    local function action(name)
        close()
        if record.kind == "note" then
            if name == "note" then edit_note(pbw, record) end
        else
            native_action(pbw, record, name)
        end
    end
    local rows = {}
    if record.kind ~= "note" then
        rows[#rows + 1] = {{ text = _("Go to"), callback = function() action("goto") end }}
    end
    rows[#rows + 1] = {{ text = record.note ~= "" and _("Edit note") or _("Add note"),
        callback = function() action("note") end }}
    if record.kind == "highlight" then
        rows[#rows + 1] = {{ text = _("Edit"), id = "edit", callback = function()
            local edit
            local function select(name) UIManager:close(edit); action(name) end
            edit = dialog(pbw, _("Edit"), {
                {{ text = _("Color"), callback = function() select("color") end }},
                {{ text = _("Style"), callback = function() select("style") end }},
            }, viewer.button_table:getButtonById("edit").dimen)
        end }}
    end
    rows[#rows + 1] = {
        { text = _("Delete"), callback = function()
            UIManager:show(require("ui/widget/confirmbox"):new{
                text = _("Delete this annotation?"), ok_text = _("Delete"), ok_callback = function()
                    if record.kind == "note" then
                        local deleted, err = BookNote.delete(record.file, record.note)
                        if not deleted then message(_("Could not save book note.") .. "\n" .. tostring(err)); return end
                        close()
                        refresh(pbw, record.file)
                    else
                        action("delete")
                    end
                end,
            })
        end },
    }
    if record.kind == "note" then rows[#rows][2] = { text = _("Close"), callback = close } end
    local details = { DateFormat.formatISODate(record.datetime), record.author,
        record.kind ~= "bookmark" and record.chapter or "", page_text(record) }
    local present = {}
    for _i, value in ipairs(details) do if value ~= "" then present[#present + 1] = value end end
    viewer = require("ui/widget/textviewer"):new{
        title = record.kind == "note" and _("Book note") or record.title,
        show_menu = false,
        text = table.concat({ record.title, table.concat(present, " · "), "", record.text, "", record.note }, "\n"),
        buttons_table = rows, close_callback = function() refresh(pbw) end,
    }
    -- Native TextViewer adds an empty focus row when its menu icon is hidden.
    local layout = viewer.button_table.layout
    if layout and layout[1] and #layout[1] == 0 then
        table.remove(layout, 1)
        viewer.button_table:refocusWidget()
    end
    UIManager:show(viewer)
end

local Row = InputContainer:extend{}

function Row:init()
    self.ges_events = {
        Select = { GestureRange:new{ ges = "tap", range = self.dimen } },
        SelectHold = { GestureRange:new{ ges = "hold", range = self.dimen } },
    }
end

function Row:onSelect() self.callback(); return true end
Row.onSelectHold = Row.onSelect
Row.onTapSelect = Row.onSelect

function Row:onFocus() self.focused = true; return true end
function Row:onUnfocus() self.focused = nil; return true end

function Row:paintTo(bb, x, y)
    InputContainer.paintTo(self, bb, x, y)
    if self.decoration and self.quote then
        local quote = self.quote.dimen
        local line_h = self.quote.line_height_px
        local lines = math.min(#self.quote.vertical_string_list, self.quote.lines_per_page)
        for line = 1, lines do
            local line_y = quote.y + line * line_h - Screen:scaleBySize(2)
            if self.decoration == "strikeout" then line_y = line_y - math.floor(line_h / 2) end
            local line_width = self.quote.vertical_string_list[line].width or quote.w
            bb:paintRect(quote.x, line_y, math.min(quote.w, line_width), Screen:scaleBySize(1), Blitbuffer.COLOR_BLACK)
        end
    end
    if self.top_border then bb:paintRect(x, y, self.dimen.w, 1, Blitbuffer.COLOR_LIGHT_GRAY) end
    bb:paintRect(x, y + self.dimen.h - 1, self.dimen.w, 1, Blitbuffer.COLOR_LIGHT_GRAY)
    if self.focused then bb:paintBorder(x, y, self.dimen.w, self.dimen.h, 2, Blitbuffer.COLOR_BLACK) end
end

local function make_row(pbw, record, dimen, font_size, quote_lines, note_lines)
    local padding = Screen:scaleBySize(12)
    local group = VerticalGroup:new{ align = "left" }
    local row = Row:new{ dimen = dimen:copy(), callback = function() M.showDetails(pbw, record) end }
    local width = dimen.w - padding * 2
    local budget = dimen.h - padding * 2
    local function add(text, size, lines, options)
        if text == "" or budget < size then return end
        options = options or {}
        local icon_size = options.bookmark and Screen:scaleBySize(size) or 0
        local box = TextBoxWidget:new{
            text = text, width = width - (options.inset or 0) * 2 - (options.bookmark and icon_size + padding / 2 or 0),
            face = LibraryFont.getFace(size), height = math.min(budget, math.ceil(Screen:scaleBySize(size) * 1.4) * lines),
            height_adjust = true, height_overflow_show_ellipsis = true,
            fgcolor = options.foreground or Blitbuffer.COLOR_BLACK,
            bgcolor = options.background or Blitbuffer.COLOR_WHITE,
        }
        budget = budget - box:getSize().h - (options.inset or 0) * 2 - padding / 2
        if options.quote then row.quote = box end
        local content = box
        if options.bookmark then
            content = HorizontalGroup:new{
                IconWidget:new{ file = utils.resolveLocalIcon(icons_dir, "bookmark"), width = icon_size, height = icon_size },
                HorizontalSpan:new{ width = padding / 2 }, box,
            }
        end
        group[#group + 1] = FrameContainer:new{
            padding = options.inset or 0, bordersize = 0,
            background = options.background or Blitbuffer.COLOR_WHITE, content,
        }
        group[#group + 1] = VerticalSpan:new{ width = padding / 2 }
    end
    local cfg = settings(pbw)
    local fields = cfg.details or {}
    local all_books = M.session(pbw).scope == "all"
    local function visible(field)
        local mode = fields[field]
        if field == "book" or field == "author" then
            return mode == "show" or ((mode == nil or mode == "auto") and all_books)
        end
        if field == "tags" then return mode == true end
        return mode ~= false
    end
    local is_bookmark = record.kind == "bookmark"
    if not is_bookmark and visible("book") then add(record.title, font_size, 1) end
    local location = {}
    if visible("chapter") and record.chapter ~= "" then
        location[#location + 1] = record.chapter
    end
    if visible("page") and record.page_label ~= "" then location[#location + 1] = page_text(record) end
    if is_bookmark and visible("book") then table.insert(location, 1, record.title) end
    local text = table.concat(location, " · "):gsub("%s+", " ")
    if is_bookmark and text == "" then text = _("Bookmark") end
    add(text, font_size, 1, { bookmark = is_bookmark })
    local details = {}
    if visible("date") and record.datetime ~= "" then
        details[#details + 1] = DateFormat.formatISODate(record.datetime)
    end
    if visible("author") and record.author ~= "" then details[#details + 1] = record.author end
    if visible("tags") then
        for _i, tag in ipairs(record.tags) do details[#details + 1] = tag end
    end
    add(table.concat(details, " · "), font_size, 1)
    if not is_bookmark then
        local background, foreground = Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
        if record.style == "invert" then
            background, foreground = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
        elseif record.style == "lighten" then
            background = highlight(pbw):getHighlightColor(record.color) or Blitbuffer.COLOR_LIGHT_GRAY
        end
        row.decoration = (record.style == "underscore" or record.style == "strikeout") and record.style or nil
        add(record.text, font_size, quote_lines,
            { background = background, foreground = foreground, quote = true, inset = padding / 2 })
        add(record.note, font_size, note_lines,
            { foreground = record.kind == "note" and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY })
    end
    row.dimen.h = math.min(dimen.h, math.max(Screen:scaleBySize(48), group:getSize().h + padding * 2))
    row[1] = FrameContainer:new{ width = dimen.w, height = row.dimen.h, padding = padding, bordersize = 0, group }
    return row
end

function M.build(pbw, kind, width, height)
    local session = M.session(pbw)
    session:refreshCurrent()
    local items = {}
    for i, record in ipairs(session:items(kind)) do items[i] = { text = "", record = record } end
    local cfg = settings(pbw)
    local limits = ({ short = { 2, 1 }, standard = { 4, 2 }, long = { 8, 4 } })[cfg.preview_length or "standard"] or { 4, 2 }
    local font_size = tonumber(pbw._zen_plugin.config.page_browser.bookmarks_font_size) or 18
    font_size = math.max(10, math.min(40, font_size))
    local props = pbw.ui and pbw.ui.doc_props or {}
    local book_title = props.display_title or props.title or pbw.ui and pbw.ui.document.file:match("([^/]+)$")
    local summary = { session.scope == "all" and _("All books") or book_title }
    if session.query ~= "" then summary[#summary + 1] = session.query end
    for _i, facet in ipairs(facets) do
        local filter = session.filters[facet[1]]
        if filter and (next(filter.include) or next(filter.exclude)) then summary[#summary + 1] = facet[2] end
    end
    if next(session.text_filters) then summary[#summary + 1] = _("Text") end
    if session.loading then summary[#summary + 1] = _("Loading…") end
    local title_bar = TitleBar:new{
        width = width, title = titles[kind] .. " (" .. #items .. ")", align = "left",
        subtitle = table.concat(summary, " · "), title_face = TitleStyle.getTitleFace(),
        subtitle_face = LibraryFont.getFace(20),
        left_icon = pbw._zen_standalone and utils.resolveLocalIcon(icons_dir, "quick_search") or nil,
        left_icon_tap_callback = function() M.showSearch(pbw) end,
        right_icon = utils.resolveLocalIcon(icons_dir, pbw._zen_standalone and "close_light" or "quick_search"),
        right_icon_tap_callback = function()
            if pbw._zen_standalone then pbw:onClose() else M.showSearch(pbw) end
        end,
    }
    if pbw._zen_standalone then
        local search, close = title_bar.left_button, title_bar.right_button
        local more = require("common/ui/zen_icon_button"):new{
            file = utils.resolveLocalIcon(icons_dir, "more_vertical"),
            width = close.width, height = close.height, padding = close.padding,
            padding_bottom = close.padding_bottom, show_parent = pbw,
            overlap_offset = { width - 2 * (close.width + 2 * close.padding), 0 },
            callback = function() M.showMenu(pbw) end,
        }
        close.padding_left = close.padding
        close:free(); close:init()
        table.insert(title_bar, more)
        title_bar.generateHorizontalLayout = function() return {{ search, more, close }} end
        title_bar.generateVerticalLayout = function() return {{ search }, { more }, { close }} end
        pbw._zen_more_button = more
    end
    title_bar.subtitle_widget.fgcolor = Blitbuffer.COLOR_BLACK
    local StyledMenu = Menu:extend{}
    function StyledMenu:mergeTitleBarIntoLayout()
        if pbw._zen_standalone then return Menu.mergeTitleBarIntoLayout(self) end
        table.insert(self.layout, 1, { self.title_bar.right_button })
        self.selected.y = self.selected.y + 1
    end
    session.row_heights = session.row_heights or {}
    function StyledMenu:setupItemHeights()
        local pages, page, used = {}, {}, 0
        local key = table.concat({ self.inner_dimen.w, self.available_height, font_size,
            cfg.preview_length or "standard", session.scope, kind }, ":")
        for i, item in ipairs(self.item_table) do
            if not item.height then
                local record = item.record
                local identity = record.annotation or record.file
                local stamp = { key, record.text, record.note, record.title, record.author,
                    record.chapter, record.page_label, record.datetime, table.concat(record.tags, " · ") }
                local cached = session.row_heights[identity]
                if not cached or not util.tableEquals(cached.stamp, stamp) then
                    local probe = make_row(pbw, record,
                        Geom:new{ w = self.inner_dimen.w, h = self.available_height }, font_size, limits[1], limits[2])
                    cached = { stamp = stamp, height = probe.dimen.h }
                    session.row_heights[identity] = cached
                    probe:free()
                end
                item.height = cached.height
            end
            if used + item.height > self.available_height and #page > 0 then
                pages[#pages + 1], page, used = page, {}, 0
            end
            page[#page + 1], used = i, used + item.height
        end
        pages[#pages + 1] = page
        self.page_items = pages
    end
    local menu = LibraryFont.withMenuFaces(function()
        return StyledMenu:new{
            name = "page_browser_annotations", width = width, height = height, custom_title_bar = title_bar,
            item_table = items, is_borderless = true, is_popout = false, is_enable_shortcut = false,
            show_parent = pbw, items_font_size = font_size, items_max_lines = limits[1] + limits[2] + 2,
        }
    end)
    local update_items = menu.updateItems
    menu.updateItems = function(self, ...)
        update_items(self, ...)
        for index, old in ipairs(self.item_group) do
            local item = self.item_table[old.idx]
            if item then
                local row = make_row(pbw, item.record, old.dimen, font_size, limits[1], limits[2])
                row.idx = old.idx
                row.top_border = index == 1
                self.item_group[index] = row
                for _i, widgets in ipairs(self.layout) do
                    for i, widget in ipairs(widgets) do if widget == old then widgets[i] = row end end
                end
                old:free()
            end
        end
        self.item_group:resetLayout()
        session.pages[kind] = self.page
        pbw:_zenRebuildFocusLayout()
    end
    menu.onMenuSelect = function(_self, item) M.showDetails(pbw, item.record); return true end
    menu.onMenuHold = menu.onMenuSelect
    menu.onClose = function() return pbw:onClose() end
    menu.onCloseAllMenus = menu.onClose
    menu.page = math.min(session.pages[kind] or 1, menu.page_num)
    menu:updateItems(1, true)
    return menu
end

function M.showSearch(pbw)
    local session = M.session(pbw)
    local input
    input = require("ui/widget/inputdialog"):new{
        title = _("Search annotations"), input = session.query,
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(input) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                session.query = input:getInputText()
                session.pages = {}
                UIManager:close(input)
                refresh(pbw)
            end },
        }},
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

local function show_facet(pbw, key, title, mode)
    local session = M.session(pbw)
    local filter = session.filters[key] or { include = {}, exclude = {} }
    session.filters[key] = filter
    local candidates = {}
    for _i, record in ipairs(session:allRecords()) do
        local values = type(record[key]) == "table" and record[key] or { record[key] }
        for _j, value in ipairs(values) do
            if value ~= "" then
                local label = key == "file" and record.title or value
                if key == "color" then label = highlight(pbw):getHighlightColorString(value) end
                if key == "style" then label = highlight(pbw):getHighlightStyleString(value) end
                candidates[value] = label
            end
        end
    end
    local options = {}
    for value, label in pairs(candidates) do options[#options + 1] = { value = value, label = label } end
    table.sort(options, function(a, b) return a.label < b.label end)
    local rows, picker = {}, nil
    rows[1] = {
        { text = _("Include") .. (mode == "include" and " ✓" or ""), callback = function()
            UIManager:close(picker); show_facet(pbw, key, title, "include")
        end },
        { text = _("Exclude") .. (mode == "exclude" and " ✓" or ""), callback = function()
            UIManager:close(picker); show_facet(pbw, key, title, "exclude")
        end },
    }
    for _i, option in ipairs(options) do
        rows[#rows + 1] = {{ text = (filter[mode][option.value] and "✓ " or "") .. option.label,
            callback = function()
                filter[mode][option.value] = not filter[mode][option.value] or nil
                filter[mode == "include" and "exclude" or "include"][option.value] = nil
                session.pages = {}
                UIManager:close(picker)
                refresh(pbw)
                show_facet(pbw, key, title, mode)
            end }}
    end
    rows[#rows + 1] = {{ text = _("Done"), callback = function() UIManager:close(picker) end }}
    picker = dialog(pbw, title, rows)
end

local function show_text_rule(pbw, field, mode, draft)
    local session = M.session(pbw)
    local rules = session.text_filters[field] or {}
    local original = draft or rules[mode] or { text = "", mode = "all", case_sensitive = false }
    local rule = { text = original.text, mode = original.mode, case_sensitive = original.case_sensitive }
    local input
    local function reopen()
        rule.text = input:getInputText()
        UIManager:close(input)
        show_text_rule(pbw, field, mode, rule)
    end
    input = require("ui/widget/inputdialog"):new{
        title = (field == "text" and _("Highlighted text") or _("Note text")) .. " · "
            .. (mode == "include" and _("Include") or _("Exclude")), input = rule.text,
        buttons = {
            {
                { text = ({ all = _("All words"), any = _("Any word"), phrase = _("Phrase") })[rule.mode], callback = function()
                    rule.mode = ({ all = "any", any = "phrase", phrase = "all" })[rule.mode]
                    reopen()
                end },
                { text = _("Case sensitive") .. (rule.case_sensitive and " ✓" or ""), callback = function()
                    rule.case_sensitive = not rule.case_sensitive
                    reopen()
                end },
            },
            {
                { text = _("Cancel"), id = "close", callback = function() UIManager:close(input) end },
                { text = _("Apply"), is_enter_default = true, callback = function()
                    rule.text = input:getInputText()
                    rules[mode] = util.trim(rule.text) ~= "" and rule or nil
                    session.text_filters[field] = next(rules) and rules or nil
                    session.pages = {}
                    UIManager:close(input)
                    refresh(pbw)
                end },
            },
        },
    }
    UIManager:show(input)
    input:onShowKeyboard()
end

function M.showFilters(pbw)
    local session = M.session(pbw)
    local rows, filters = {}, nil
    local function launch(callback) return function() UIManager:close(filters); callback() end end
    rows[#rows + 1] = {{ text = session.scope == "all" and _("All books") or _("This book"), enabled = pbw.ui ~= nil,
        callback = launch(function()
        session.scope = session.scope == "all" and "current" or "all"
        session.pages = {}
        if session.scope == "all" then
            session:loadAll(function() if Annotations.kinds[pbw._zen_active_tab] then refresh(pbw) end end)
        end
        refresh(pbw)
    end) }}
    for _i, facet in ipairs(facets) do
        rows[#rows + 1] = {{ text = facet[2], callback = launch(function()
            show_facet(pbw, facet[1], facet[2], "include")
        end) }}
    end
    rows[#rows + 1] = {{ text = _("Text"), callback = launch(function()
        local text_dialog, text_rows = nil, {}
        for _i, field in ipairs({ { "text", _("Highlighted text") }, { "note", _("Note text") } }) do
            text_rows[#text_rows + 1] = {
                { text = field[2] .. " · " .. _("Include"), callback = function()
                    UIManager:close(text_dialog); show_text_rule(pbw, field[1], "include")
                end },
                { text = _("Exclude"), callback = function()
                    UIManager:close(text_dialog); show_text_rule(pbw, field[1], "exclude")
                end },
            }
        end
        text_dialog = dialog(pbw, _("Text"), text_rows)
    end) }}
    rows[#rows + 1] = {{ text = _("Clear filters"), callback = launch(function()
        session.query, session.filters, session.text_filters, session.pages = "", {}, {}, {}
        refresh(pbw)
    end) }}
    filters = dialog(pbw, _("Filter"), rows)
end

local function show_sort(pbw)
    local session = M.session(pbw)
    local sort_dialog
    local function set_sort(mode, reverse)
        session.sort, session.reverse, session.pages = mode, reverse, {}
        UIManager:close(sort_dialog); refresh(pbw)
    end
    sort_dialog = dialog(pbw, _("Sort"), {
        {{ text = _("Position") .. (session.sort == "page" and " ✓" or ""),
            callback = function() set_sort("page", false) end }},
        {{ text = _("Date") .. (session.sort == "date" and " ✓" or ""),
            callback = function() set_sort("date", false) end }},
        {{ text = _("Reverse order") .. (session.reverse and " ✓" or ""),
            callback = function() set_sort(session.sort, not session.reverse) end }},
    })
end

function M.showMenu(pbw)
    local menu
    local function launch(callback) return function() UIManager:close(menu); callback() end end
    local rows = {
        {{ text = _("New note"), icon = utils.resolveIcon(icons_dir, "plus"), enabled = pbw.ui ~= nil,
            callback = launch(function() edit_note(pbw) end) }},
        {{ text = _("Filter"), icon = utils.resolveIcon(icons_dir, "filter"),
            callback = launch(function() M.showFilters(pbw) end) }},
        {{ text = _("Sort"), icon = utils.resolveIcon(icons_dir, "sort"),
            callback = launch(function() show_sort(pbw) end) }},
        {{ text = _("Settings"), icon = utils.resolveIcon(icons_dir, "quicksettings"),
            callback = launch(function()
                pbw:onClose()
                require("modules/settings/zen_settings_page").show(pbw._zen_plugin, {
                    path = { { key = "text", value = _("Reader") }, { key = "text", value = _("Annotation viewer") } },
                })
            end) }},
    }
    menu = dialog(pbw, _("Annotations"), rows)
end

function M.show(plugin, ui, kind)
    local viewer = InputContainer:new{
        ui = ui, _zen_plugin = plugin, _zen_active_tab = kind or "annotations", _zen_standalone = true,
        covers_fullscreen = true, dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
    }
    function viewer:_zenRebuildFocusLayout() end -- The embedded Menu owns keyboard focus.
    function viewer:updateLayout()
        if self[1] then self[1]:free() end
        self[1] = M.build(self, self._zen_active_tab, self.dimen.w, self.dimen.h)
        self._zen_content_panel = self[1]
    end
    function viewer:onClose()
        self._zen_closed = true
        M.session(self):close()
        UIManager:close(self)
        UIManager:setDirty(nil, "ui")
        return true
    end
    viewer:updateLayout()
    UIManager:show(viewer)
    if not ui then M.session(viewer):loadAll(function() refresh(viewer) end) end
    return viewer
end

return M
