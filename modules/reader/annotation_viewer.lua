local Annotations = require("modules/reader/annotations")
local BookNote = require("modules/reader/book_note")
local Blitbuffer = require("ffi/blitbuffer")
local ClockTimer = require("common/clock_timer")
local DateFormat = require("common/date_format")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GlyphIcons = require("common/ui/glyph_icons")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LibraryFont = require("modules/filebrowser/patches/library_font")
local Menu = require("ui/widget/menu")
local Screen = require("device").screen
local Size = require("ui/size")
local SolidCircle = require("common/ui/zen_solid_circle")
local T = require("ffi/util").template
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
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
local titles = { bookmarks = _("Bookmarks"), highlights = _("Highlights"), annotations = _("Annotations"),
    pins = _("Pinned pages") }
local facets = { { "kind", _("Type") }, { "file", _("Books") }, { "chapter", _("Chapters") }, { "tags", _("Tags") },
    { "color", _("Color") }, { "style", _("Style") } }
local kind_labels = { bookmark = _("Bookmark"), highlight = _("Highlight"), note = _("Book note"), pin = _("Pinned page") }
local markers = { bookmark = "bookmark", pin = "pin" }
local STATUS_INSET, STATUS_GAP = Screen:scaleBySize(6), Screen:scaleBySize(4)
local ROW_PADDING, ROW_SIDE = Screen:scaleBySize(12), Screen:scaleBySize(20)

local function message(text)
    UIManager:show(require("ui/widget/infomessage"):new{ text = text })
end

local function dialog(pbw, title, rows, anchor)
    local widget = require("common/ui/zen_anchored_menu").new{
        title = title, buttons = rows, anchor = anchor or pbw._zen_annotation_more.dimen, anchor_right = true,
        rows_per_page = 9,
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

local function color_label(pbw, record)
    -- Inverted highlights ignore their color.
    if record.kind ~= "highlight" or record.style == "invert" then return "" end
    return highlight(pbw):getHighlightColorString(record.color)
end

local function highlight_fill(pbw, record)
    -- Night-mode-aware color shows true; grays pre-invert to match the page.
    local color = highlight(pbw):getHighlightColor(record.color, false, true) or Blitbuffer.COLOR_LIGHT_GRAY
    if Screen.night_mode and Blitbuffer.isColor8(color) then color = color:invert() end
    return color
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
    -- updateLayout -> M.build re-reads the current book; no second note read here.
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
        if record.kind == "pin" then
            local pin = Annotations.resolvePin(ui, record)
            if not pin then message(_("This pinned page is no longer available.")); return end
            if action == "goto" then
                if ui.link then ui.link:addCurrentLocationToStack() end
                ui:handleEvent(require("ui/event"):new("GotoPage", pin.page))
            elseif action == "delete" then
                ui.gotopage:onPinPage(pin.page, true)
                refresh(pbw)
            end
            return
        end
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

-- Primary action first; `done` closes whatever offered them.
local function record_actions(pbw, record, anchor, done)
    local is_pin, is_note = record.kind == "pin", record.kind == "note"
    local function icon(name) return GlyphIcons.iconPath(GlyphIcons.SVG[name]) end
    local function run(name)
        return function()
            done()
            if not is_note then native_action(pbw, record, name)
            elseif name == "note" then edit_note(pbw, record) end
        end
    end
    local actions = {}
    if not is_note then actions[#actions + 1] = { text = _("Go to"), icon = icon("reading"), callback = run("goto") } end
    if not is_pin then
        local has_note = record.note ~= ""
        actions[#actions + 1] = { text = has_note and _("Edit note") or _("Add note"), callback = run("note"),
            icon = has_note and utils.resolveIcon(icons_dir, "annotations") or GlyphIcons.iconPath("settings_note_plus_outline") }
    end
    if record.kind == "highlight" then
        actions[#actions + 1] = { text = _("Edit"), icon = icon("edit"), callback = function()
            local edit
            local function select(name) return function() UIManager:close(edit); run(name)() end end
            edit = dialog(pbw, _("Edit"), {
                {{ text = _("Color"), icon = icon("reader_themes"), callback = select("color") }},
                {{ text = _("Style"), icon = icon("settings_underline"), callback = select("style") }},
            }, anchor)
        end }
    end
    actions[#actions + 1] = { text = is_pin and _("Remove pin") or _("Delete"),
        icon = is_pin and utils.resolveIcon(icons_dir, "pin_remove") or icon("delete"), callback = function()
        UIManager:show(require("ui/widget/confirmbox"):new{
            text = is_pin and _("Remove pinned page?") or _("Delete this annotation?"),
            ok_text = is_pin and _("Remove") or _("Delete"), ok_callback = function()
                if not is_note then return run("delete")() end
                local deleted, err = BookNote.delete(record.file, record.note)
                if not deleted then message(_("Could not save book note.") .. "\n" .. tostring(err)); return end
                done()
                refresh(pbw, record.file)
            end,
        })
    end }
    return actions
end

local function show_actions(pbw, record, actions, anchor)
    local menu
    local rows = {}
    for i, action in ipairs(actions) do
        rows[i] = {{ text = action.text, icon = action.icon,
            callback = function() UIManager:close(menu); action.callback() end }}
    end
    menu = dialog(pbw, kind_labels[record.kind], rows, anchor)
end

function M.showActions(pbw, record, anchor)
    show_actions(pbw, record, record_actions(pbw, record, anchor, function() end), anchor)
end

-- Overflow button left of the close icon.
local function add_more_button(viewer, callback)
    local title_bar, close = viewer.titlebar, viewer.titlebar.right_button
    close.padding_left = close.padding -- Stock widens the close tap zone over this slot.
    close:free(); close:init()
    local slot = close:getSize().w
    local more = require("common/ui/zen_icon_button"):new{
        file = utils.resolveLocalIcon(icons_dir, "more_vertical"), width = close.width, height = close.height,
        padding = close.padding, padding_top = close.padding_top, padding_bottom = close.padding_bottom,
        show_parent = viewer, overlap_offset = { title_bar.width - 2 * slot, 0 }, callback = callback,
    }
    table.insert(title_bar, more)
    title_bar.title_widget:setMaxWidth(title_bar.title_widget.max_width - slot)
    title_bar.inner_title_group:resetLayout()
    title_bar.title_group:resetLayout()
    -- Focus layout exists only on DPad devices; native TextViewer adds an empty row when its menu icon is hidden.
    local buttons = viewer.button_table
    if buttons.layout then
        if buttons.layout[1] and #buttons.layout[1] == 0 then table.remove(buttons.layout, 1) end
        table.insert(buttons.layout, 1, { more })
        buttons.selected.y = buttons.selected.y + 1
        buttons:refocusWidget()
    end
    return more
end

function M.showDetails(pbw, record)
    local viewer
    local function close() UIManager:close(viewer) end
    local function anchor() return viewer._zen_more.dimen end
    local actions = record_actions(pbw, record, anchor, close)
    local primary = table.remove(actions, 1)
    local details = { DateFormat.formatISODate(record.datetime), color_label(pbw, record), record.author,
        record.kind ~= "bookmark" and record.chapter or "", page_text(record) }
    local present = {}
    for _i, value in ipairs(details) do if value ~= "" then present[#present + 1] = value end end
    viewer = require("ui/widget/textviewer"):new{
        title = record.kind == "note" and _("Book note") or record.title,
        show_menu = false,
        text = table.concat({ record.title, table.concat(present, " | "), "", record.text, "", record.note }, "\n"),
        buttons_table = {{ { text = primary.text, callback = primary.callback } }}, close_callback = function() refresh(pbw) end,
    }
    viewer._zen_more = add_more_button(viewer, function() show_actions(pbw, record, actions, anchor) end)
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
function Row:onSelectHold()
    -- Menus drop down from the row's horizontal center line.
    local d = self.dimen
    local anchor = Geom:new{ x = d.x, y = d.y + math.floor(d.h / 2), w = d.w, h = 0 }
    self.hold_callback(function() return anchor, true end)
    return true
end
Row.onTapSelect = Row.onSelect

function Row:onFocus() self.focused = true; return true end
function Row:onUnfocus() self.focused = nil; return true end

function Row:paintTo(bb, x, y)
    InputContainer.paintTo(self, bb, x, y)
    if self.decoration and self.quote then
        local quote = self.quote.dimen
        local line_h = self.quote.line_height_px
        local lines = math.min(#self.quote.vertical_string_list, self.quote.lines_per_page)
        local color = self.decoration_color or Blitbuffer.COLOR_BLACK
        local paint = Blitbuffer.isColor8(color) and bb.paintRect or bb.paintRectRGB32
        for line = 1, lines do
            local line_y = quote.y + line * line_h - Screen:scaleBySize(2)
            if self.decoration == "strikeout" then line_y = line_y - math.floor(line_h / 2) end
            local line_width = self.quote.vertical_string_list[line].width or quote.w
            paint(bb, quote.x, line_y, math.min(quote.w, line_width), Screen:scaleBySize(1), color)
        end
    end
    if self.top_border then bb:paintRect(x, y, self.dimen.w, 1, Blitbuffer.COLOR_LIGHT_GRAY) end
    bb:paintRect(x, y + self.dimen.h - 1, self.dimen.w, 1, Blitbuffer.COLOR_LIGHT_GRAY)
    if self.focused then bb:paintBorder(x, y, self.dimen.w, self.dimen.h, 2, Blitbuffer.COLOR_BLACK) end
end

local function make_row(pbw, record, dimen, font_size, quote_lines, note_lines, compact)
    local padding = ROW_PADDING
    local group = VerticalGroup:new{ align = "left" }
    local row = Row:new{ dimen = dimen:copy(), callback = function() M.showDetails(pbw, record) end,
        hold_callback = function(anchor) M.showActions(pbw, record, anchor) end }
    local width = dimen.w - ROW_SIDE * 2
    local budget = dimen.h - padding * 2
    local function add(text, size, lines, options)
        if text == "" or lines < 1 or budget < size then return end
        options = options or {}
        local lead = options.icon or options.swatch
        local icon_size = lead and Screen:scaleBySize(size) or 0
        local box = TextBoxWidget:new{
            text = text, width = width - (options.inset or 0) * 2 - (lead and icon_size + padding / 2 or 0),
            face = LibraryFont.getFace(size), height = math.min(budget, math.ceil(Screen:scaleBySize(size) * 1.4) * lines),
            height_adjust = true, height_overflow_show_ellipsis = true,
            fgcolor = options.foreground or Blitbuffer.COLOR_BLACK,
            bgcolor = options.background or Blitbuffer.COLOR_WHITE,
        }
        budget = budget - box:getSize().h - (options.inset or 0) * 2 - padding / 2
        if options.quote then row.quote = box end
        local content = box
        if lead then
            content = HorizontalGroup:new{
                options.icon and IconWidget:new{ file = utils.resolveLocalIcon(icons_dir, options.icon), width = icon_size, height = icon_size }
                    -- Rounded swatch; border keeps light colors visible on grayscale screens.
                    or SolidCircle:new{ width = icon_size, background = options.swatch,
                        radius = math.floor(icon_size / 4), bordersize = Size.border.thin },
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
        return mode ~= false
    end
    local marker = markers[record.kind]
    if not marker and visible("book") then add(record.title, font_size, 1) end
    local location = {}
    if visible("chapter") and record.chapter ~= "" then
        location[#location + 1] = record.chapter
    end
    if visible("page") and record.page_label ~= "" then location[#location + 1] = page_text(record) end
    if marker and visible("book") then table.insert(location, 1, record.title) end
    local label = visible("label") and color_label(pbw, record) or ""
    if label ~= "" then table.insert(location, 1, label) end
    local text = table.concat(location, " | "):gsub("%s+", " ")
    if marker and text == "" then text = kind_labels[record.kind] end
    local swatch = record.kind == "highlight"
        and (record.style == "invert" and Blitbuffer.COLOR_BLACK or highlight_fill(pbw, record))
    add(text, font_size, 1, { icon = marker, swatch = swatch or nil })
    local details = {}
    if visible("date") and record.datetime ~= "" then
        details[#details + 1] = DateFormat.formatISODate(record.datetime)
    end
    if visible("author") and record.author ~= "" then details[#details + 1] = record.author end
    add(table.concat(details, " | "), font_size, compact and 0 or 1)
    if not marker then
        local background, foreground = Blitbuffer.COLOR_WHITE, Blitbuffer.COLOR_BLACK
        if record.style == "invert" then
            background, foreground = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
        elseif record.style == "lighten" then
            background = swatch
            if Screen.night_mode then foreground = Blitbuffer.COLOR_WHITE end
        end
        if record.style == "underscore" or record.style == "strikeout" then
            row.decoration = record.style
            -- Match ReaderView: grays draw black, colors pre-invert so night mode shows the true hue.
            local color = highlight(pbw):getHighlightColor(record.color)
            if color and not Blitbuffer.isColor8(color) then
                row.decoration_color = Screen.night_mode and color:invert() or color
            end
        end
        add(record.text, font_size, quote_lines,
            { background = background, foreground = foreground, quote = true, inset = padding / 2 })
        add(record.note, font_size, note_lines,
            { foreground = record.kind == "note" and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY })
    end
    row.dimen.h = math.min(dimen.h, math.max(Screen:scaleBySize(48), group:getSize().h + padding * 2))
    row[1] = FrameContainer:new{ width = dimen.w, height = row.dimen.h, padding = padding,
        padding_left = ROW_SIDE, padding_right = ROW_SIDE, bordersize = 0, group }
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
    local details = cfg.details or {}
    local summary = {}
    if session.scope == "all" then summary[1] = _("All books")
    elseif details.book ~= "hide" then summary[1] = book_title end
    if session.query ~= "" then summary[#summary + 1] = session.query end
    for _i, facet in ipairs(facets) do
        local filter = session.filters[facet[1]]
        if filter and (next(filter.include) or next(filter.exclude)) then summary[#summary + 1] = facet[2] end
    end
    if next(session.text_filters) then summary[#summary + 1] = _("Text") end
    if session.loading then summary[#summary + 1] = _("Loading…") end
    local standalone = pbw._zen_standalone
    local function show_menu() M.showMenu(pbw) end
    local title_bar = TitleBar:new{
        width = width, title = titles[kind] .. " (" .. #items .. ")", align = "center", zen_style = true,
        title_face = TitleStyle.getTitleFace(),
        -- Extra right-side buttons; keep centered text clear of them.
        title_h_padding = Size.padding.large + TitleStyle.BUTTON_SIZE * (standalone and 2 or 1),
        right_icon = utils.resolveLocalIcon(icons_dir, standalone and "close_light" or "more_vertical"),
        right_icon_tap_callback = standalone and function() pbw:onClose() end or show_menu,
    }
    TitleStyle.centerStockTitle(title_bar)
    local edge = title_bar.right_button
    edge.padding_left = edge.padding
    edge:free(); edge:init()
    -- Slots count leftwards from the edge button.
    local function add_button(icon, callback, slot)
        local button = require("common/ui/zen_icon_button"):new{
            file = utils.resolveLocalIcon(icons_dir, icon), width = edge.width, height = edge.height,
            padding = edge.padding, padding_top = edge.padding_top, padding_bottom = edge.padding_bottom,
            show_parent = pbw, overlap_offset = { width - slot * edge:getSize().w, 0 }, callback = callback,
        }
        table.insert(title_bar, button)
        return button
    end
    local more = standalone and add_button("more_vertical", show_menu, 2) or edge
    local search = add_button("quick_search", function() M.showSearch(pbw) end, standalone and 3 or 2)
    pbw._zen_annotation_more = more
    title_bar._zen_search = search
    local buttons = { search, more, standalone and edge or nil }
    title_bar.generateHorizontalLayout = function() return { buttons } end
    title_bar.generateVerticalLayout = function()
        local rows = {}
        for i, button in ipairs(buttons) do rows[i] = { button } end
        return rows
    end
    -- Book title and author sit under the header, left-aligned with row content.
    local function add_line(text, size, bold)
        if not text or text == "" then return end
        local line = TextWidget:new{
            text = text, face = LibraryFont.getFace(size), bold = bold,
            max_width = width - ROW_SIDE * 2, fgcolor = Blitbuffer.COLOR_BLACK,
            overlap_offset = { ROW_SIDE, title_bar.titlebar_height },
        }
        table.insert(title_bar, line)
        title_bar.titlebar_height = title_bar.titlebar_height + line:getSize().h
        return line
    end
    title_bar._zen_subtitle = add_line(table.concat(summary, " · "), 22, true)
    if session.scope ~= "all" and details.author ~= "hide" then
        title_bar._zen_author = add_line(props.authors and (props.authors:gsub("\n", ", ")), 18)
    end
    title_bar.titlebar_height = title_bar.titlebar_height + ROW_PADDING
    title_bar.dimen.h = title_bar.titlebar_height
    require("ui/widget/overlapgroup").init(title_bar) -- Resync cached size with dimen.
    local StyledMenu = Menu:extend{}
    function StyledMenu:mergeTitleBarIntoLayout()
        if pbw._zen_standalone then return Menu.mergeTitleBarIntoLayout(self) end
        table.insert(self.layout, 1, { search, more })
        self.selected.y = self.selected.y + 1
    end
    session.row_heights = session.row_heights or {}
    function StyledMenu:setupItemHeights()
        local pages, page, used = {}, {}, 0
        local key = table.concat({ self.inner_dimen.w, self.available_height, font_size,
            cfg.preview_length or "standard", session.scope, kind }, ":")
        local dimen = Geom:new{ w = self.inner_dimen.w, h = self.available_height }
        local function probe(record, quote_lines, note_lines, compact)
            local row = make_row(pbw, record, dimen, font_size, quote_lines, note_lines, compact)
            local h = row.dimen.h
            row:free()
            return h
        end
        for i, item in ipairs(self.item_table) do
            local record = item.record
            local identity = record.annotation or record.id or record.file
            local stamp = { key, record.text, record.note, record.title, record.author,
                record.chapter, record.page_label, record.datetime, table.concat(record.tags, " · ") }
            local cached = session.row_heights[identity]
            if not cached or not util.tableEquals(cached.stamp, stamp) then
                -- min: compact header plus one quote line, the smallest row worth clipping into leftover space.
                cached = { stamp = stamp, height = probe(record, limits[1], limits[2]), min = probe(record, 1, 0, true) }
                session.row_heights[identity] = cached
            end
            item.height, item.compact = cached.height, nil
            local room = self.available_height - used
            if item.height > room and #page > 0 then
                if cached.min <= room then
                    item.height, item.compact = room, true -- truncate into the gap instead of leaving it blank
                else
                    pages[#pages + 1], page, used = page, {}, 0
                end
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
                local row = make_row(pbw, item.record, old.dimen, font_size, limits[1], limits[2], item.compact)
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
                local label = key == "file" and record.title or key == "kind" and kind_labels[value] or value
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
        {{ text = _("Settings"), icon = GlyphIcons.iconPath(GlyphIcons.SVG.settings),
            callback = launch(function()
                pbw:onClose()
                require("modules/settings/zen_settings_page").show(pbw._zen_plugin, {
                    path = { { key = "text", value = _("Reader") }, { key = "text", value = _("Annotation viewer") } },
                })
            end) }},
    }
    menu = dialog(pbw, _("Annotations"), rows)
end

local function status_builder(plugin)
    local config = plugin and plugin.config
    if not (config and config.features and config.features.status_bar == true
            and require("common/status_bar_registry").hasItems(config.status_bar)) then return end
    local build = require("common/shared_state").get(plugin, "buildStatusRow")
    if type(build) ~= "function" then return end
    return function(width)
        return build(width, { row_height = 18, show_bottom_border = config.status_bar.show_bottom_border == true })
    end
end

function M.show(plugin, ui, kind)
    local viewer = InputContainer:new{
        ui = ui, _zen_plugin = plugin, _zen_active_tab = kind or "annotations", _zen_standalone = true,
        covers_fullscreen = true, dimen = Geom:new{ w = Screen:getWidth(), h = Screen:getHeight() },
    }
    local build_status = status_builder(plugin)
    local side = Size.padding.large
    function viewer:_zenRebuildFocusLayout() end -- The embedded Menu owns keyboard focus.
    function viewer:updateLayout()
        if self[1] then self[1]:free() end
        local width, height = self.dimen.w, self.dimen.h
        local group = VerticalGroup:new{ align = "left" }
        self._zen_status_row = build_status and build_status(width)
        if self._zen_status_row then
            group[1] = VerticalSpan:new{ width = STATUS_INSET }
            group[2] = self._zen_status_row
            group[3] = VerticalSpan:new{ width = STATUS_GAP }
            height = height - STATUS_INSET - self._zen_status_row:getSize().h - STATUS_GAP
        end
        self._zen_content_panel = M.build(self, self._zen_active_tab, width - side * 2, height)
        group[#group + 1] = FrameContainer:new{ padding = 0, padding_left = side, padding_right = side,
            bordersize = 0, self._zen_content_panel }
        self._zen_status_group = group
        self[1] = FrameContainer:new{ width = width, height = self.dimen.h, padding = 0, bordersize = 0,
            background = Blitbuffer.COLOR_WHITE, group }
    end
    function viewer:_zen_status_refresh()
        local previous = self._zen_status_row
        local top = UIManager._window_stack and UIManager._window_stack[#UIManager._window_stack]
        if self._zen_closed or not previous or not top or top.widget ~= self then return end
        local current = build_status(self.dimen.w)
        local regions = require("common/shared_state").get(plugin, "statusRowRefreshRegions")
        if regions and #regions(previous, current) == 0 then current:free(); return end
        self._zen_status_group[2], self._zen_status_row = current, current
        previous:free()
        local size = current:getSize()
        UIManager:setDirty(self, "ui", Geom:new{ x = 0, y = STATUS_INSET, w = size.w, h = size.h })
    end
    for _i, name in ipairs({ "onResume", "onNetworkConnected", "onNetworkDisconnected",
            "onNetworkStateChanged", "onCharging", "onNotCharging" }) do
        viewer[name] = viewer._zen_status_refresh
    end
    if build_status then ClockTimer.bind(viewer, function(target) target:_zen_status_refresh() end) end
    function viewer:onClose()
        self._zen_closed = true
        ClockTimer.unbind(self)
        M.session(self):close()
        UIManager:close(self)
        UIManager:setDirty(nil, "ui")
        return true
    end
    viewer:updateLayout()
    UIManager:show(viewer, "ui") -- Full-screen refresh; otherwise only the closing caller's region updates.
    if not ui then M.session(viewer):loadAll(function() refresh(viewer) end) end
    return viewer
end

return M
