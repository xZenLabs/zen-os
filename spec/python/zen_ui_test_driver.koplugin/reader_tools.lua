local UIManager = require("ui/uimanager")

local M = {}
local dictionary_requested = false

function M.button_state(button_table)
    local rows = {}
    for i, row in ipairs(button_table and button_table.buttons_layout or {}) do
        rows[i] = {}
        for j, button in ipairs(row) do
            local icon = button.label_icon or button.label_widget
            rows[i][j] = { id = button_table.buttons[i][j].id, text = button.text or "", icon = icon.file or "",
                icon_width = icon:getSize().w, width = button.dimen.w, height = button.dimen.h,
                content_width = button.label_container[1]:getSize().w }
        end
    end
    return rows
end

local function reader()
    return require("apps/reader/readerui").instance
end

local function is_visible(target)
    if not target then return false end
    for _i, window in ipairs(UIManager._window_stack or {}) do
        if window and window.widget == target then return true end
    end
    return false
end

local function find_widget(predicate)
    for index = #(UIManager._window_stack or {}), 1, -1 do
        local window = UIManager._window_stack[index]
        local widget = window and window.widget
        if widget and predicate(widget) then return widget end
    end
end

local function menu_anchor(widget)
    local anchor = widget._zen_anchor_source or widget.anchor
    return type(anchor) == "function" and anchor() or anchor
end

local function menu_rows(dialog)
    local rows = {}
    for _i, row in ipairs(dialog and dialog.buttontable.buttons_layout or {}) do
        local button = row[1]
        local label = button.label_container and button.label_container[1]
        rows[#rows + 1] = { text = button.text, align = button.align,
            icon = label and label[1] and label[1].file,
            padding_left = button.frame.padding_left, padding_right = button.frame.padding_right }
    end
    return rows
end

local function page_browser()
    return find_widget(function(widget)
        return type(widget._zen_switch_single) == "function"
            and type(widget._zen_switch_carousel) == "function"
            and type(widget._zen_switch_grid) == "function"
    end)
end

local function toc_overlay()
    return find_widget(function(widget)
        return type(widget._entries) == "table"
            and type(widget._gotoTocPage) == "function"
            and type(widget._moveFocus) == "function"
    end)
end

local function book_info_overlay()
    return find_widget(function(widget)
        return widget._description_widget ~= nil
            and widget._L and widget._L.description_h ~= nil
    end)
end

local function bookmark_menu()
    local ui = reader()
    local bookmark = ui and ui.bookmark
    local container = bookmark and bookmark.bookmark_menu
    return container and container[1], container
end

local function open_launcher_page(page)
    local ui = reader()
    local menu = ui and ui.menu
    if not menu then return false, "reader menu unavailable" end
    if menu.tab_item_table == nil and type(menu.setUpdateItemTable) == "function" then
        menu:setUpdateItemTable()
    end
    if type(menu.onShowMenu) == "function" then
        menu:onShowMenu()
    end
    local touch_menu = menu.menu_container and menu.menu_container[1]
    if not touch_menu then return false, "reader menu unavailable" end
    touch_menu._app_launcher_page = page
    for index, tab in ipairs(menu.tab_item_table or {}) do
        if tab.id == "app_launcher" then
            local icon = touch_menu.bar and touch_menu.bar.icon_widgets
                and touch_menu.bar.icon_widgets[index]
            if icon and type(icon.callback) == "function" then
                icon.callback()
                return true
            end
            if type(touch_menu.switchMenuTab) == "function" then
                touch_menu:switchMenuTab(index)
                return true
            end
        end
    end
    return false, "launcher tab unavailable"
end

local function find_control(widget, icon, seen, depth)
    if type(widget) ~= "table" or depth > 16 or seen[widget] then return end
    seen[widget] = true
    local file = widget.file
    local filename = type(file) == "string" and (file:match("([^/]+)$") or file) or ""
    local matches_icon = widget.icon == icon
        or (filename:sub(1, #icon) == icon and filename:sub(#icon + 1, #icon + 1) == ".")
    if matches_icon and type(widget.callback) == "function" then return widget end
    for _i, child in ipairs(widget) do
        local found = find_control(child, icon, seen, depth + 1)
        if found then return found end
    end
end

local function activate_icon(widget, icon)
    local control = find_control(widget, icon, {}, 0)
    if not control then return false end
    control.callback()
    return true
end

function M.page_browser_state()
    local browser = page_browser()
    if not browser then return nil end
    local top = UIManager:getTopmostVisibleWidget()
    local annotation_dialog = browser._zen_annotations and top.buttons and top.buttontable and top.movable and top
    local note_editor = browser._zen_annotations and top.allow_newline and top._input_widget and top
    local panel = browser._zen_content_panel
    local switcher_books = {}
    for _i, row in ipairs(panel and panel.layout or {}) do
        for _j, cell in ipairs(row) do
            if cell.book_path then switcher_books[#switcher_books + 1] = {
                path = cell.book_path, bounds = cell.dimen,
            } end
        end
    end
    local annotation_title = panel and panel.name == "page_browser_annotations" and panel.title_bar
    local button_labels = {}
    for _i, buttons in ipairs(top.buttons_table or note_editor and note_editor.buttons or {}) do
        local labels = {}
        for _j, button in ipairs(buttons) do labels[#labels + 1] = button.text end
        button_labels[#button_labels + 1] = labels
    end
    local annotation_rows, annotation_row_bounds, annotation_bookmarks = {}, {}, {}
    for _i, row in ipairs(annotation_title and panel.item_group or {}) do
        local blocks = {}
        for _j, frame in ipairs(row[1] and row[1][1] or {}) do
            local box = frame[1]
            if box and not box.text and box[3] and box[3].text then
                annotation_bookmarks[#annotation_bookmarks + 1] = {
                    icon = box[1].file, lines = #box[3].vertical_string_list, max_lines = box[3].lines_per_page,
                }
                box = box[3]
            end
            if box and box.text and box.face then
                blocks[#blocks + 1] = { text = box.text, size = box.face.orig_size,
                    black = box.fgcolor == require("ffi/blitbuffer").COLOR_BLACK }
            end
        end
        annotation_rows[#annotation_rows + 1] = blocks
        annotation_row_bounds[#annotation_row_bounds + 1] = row.dimen
    end
    local selected = browser.selected
    local row = selected and browser.layout and browser.layout[selected.y]
    local focused = row and row[selected.x]
    local header_icons, header_paths = {}, {}
    for _i, button in ipairs(browser._zen_header_buttons or {}) do
        header_icons[#header_icons + 1] = button.file and button.file:match("([^/]+)$") or button.icon
        header_paths[#header_paths + 1] = button.file
    end
    local layout_menu = find_widget(function(widget)
        return browser._zen_layout_button and menu_anchor(widget) == browser._zen_layout_button.dimen
            and widget.buttons and #widget.buttons == 3
    end)
    local layout_rows = menu_rows(layout_menu)
    local ready, preview_bounds = 0, {}
    for idx = 1, browser.nb_grid_items or 0 do
        local frame = browser.grid[idx]
        preview_bounds[idx] = { page = frame.page_idx, bounds = frame.dimen }
        local container = browser.grid[idx][1]
        if container and container[1] and container[1].is_page_thumbnail then
            ready = ready + 1
            preview_bounds[idx].image_bounds = container[1][1].dimen
        end
    end
    local focused_frame = browser.grid[(browser.focus_page_shift or 0) + 1]
    local focused_preview = focused_frame and focused_frame[1] and focused_frame[1][1]
    local full_preview = browser._zen_full_page_preview
    local more_menu = find_widget(function(widget)
        return browser._zen_more_button and menu_anchor(widget) == browser._zen_more_button.dimen and widget.buttons
    end)
    local annotation_items = {}
    for _i, item in ipairs(browser._zen_content_panel and browser._zen_content_panel.item_table or {}) do
        item = item.record or item
        if item.kind then annotation_items[#annotation_items + 1] = {
            kind = item.kind, file = item.file, text = item.text, note = item.note, color = item.color, style = item.style,
        } end
    end
    return {
        switcher_books = switcher_books,
        annotation_items = annotation_items,
        annotation_rows = annotation_rows,
        annotation_bookmarks = annotation_bookmarks,
        annotation_row_bounds = annotation_row_bounds,
        annotation_buttons = top.buttons_table and button_labels or nil,
        annotation_left_icon = top.titlebar and top.titlebar.left_button ~= nil,
        annotation_empty_focus_row = top.button_table and top.button_table.layout
            and top.button_table.layout[1] and #top.button_table.layout[1] == 0,
        annotation_scope = browser._zen_annotations and browser._zen_annotations.scope,
        annotation_loading = browser._zen_annotations and browser._zen_annotations.loading == true,
        annotation_dialog = annotation_dialog and { bounds = annotation_dialog.movable.dimen,
            rows = menu_rows(annotation_dialog), anchor = menu_anchor(annotation_dialog) } or nil,
        annotation_text = browser._zen_annotations and top.text or nil,
        annotation_subtitle = annotation_title and annotation_title.subtitle,
        annotation_subtitle_size = annotation_title and annotation_title.subtitle_widget.face.orig_size,
        annotation_subtitle_black = annotation_title and annotation_title.subtitle_widget.fgcolor
            == require("ffi/blitbuffer").COLOR_BLACK,
        annotation_search = annotation_title and annotation_title.right_button and {
            icon = annotation_title.right_button.image.file,
            bounds = annotation_title.right_button.image.dimen,
            title_bounds = {
                x = annotation_title.dimen.x + annotation_title.title_h_padding,
                y = annotation_title.dimen.y + annotation_title.title_group[1]:getSize().h,
                w = annotation_title.title_widget:getSize().w, h = annotation_title.title_widget:getSize().h,
            },
        } or nil,
        note_editor = note_editor and { bounds = note_editor.dialog_frame.dimen,
            available_height = note_editor[1].dimen.h, buttons = button_labels,
            scroll_buttons = note_editor.add_scroll_buttons, nav_bar = note_editor.add_nav_bar } or nil,
        layout = browser._zen_layout_mode,
        preview_ready = full_preview and full_preview.bb ~= nil or focused_preview and focused_preview.is_page_thumbnail == true,
        full_page = browser:_zenIsFullPage(),
        full_page_bounds = full_preview and full_preview.dimen,
        full_page_top = full_preview and full_preview.top,
        full_page_bottom = full_preview and full_preview.bottom,
        more_bounds = browser._zen_more_button.dimen,
        close_bounds = browser.title_bar.right_button.dimen,
        more_menu = more_menu and { text = more_menu.buttons[1][1].text,
            enabled = more_menu.buttontable.buttons_layout[1][1].enabled ~= false,
            bounds = more_menu.movable.dimen, rows = menu_rows(more_menu) },
        preview_id = tostring(browser.grid),
        preview_geometry = { w = browser.grid_width, h = browser.grid_height,
            item_w = browser.grid_item_width, item_h = browser.grid_item_height },
        preview_bounds = preview_bounds,
        header_height = browser.title_bar_h,
        header_tabs = browser._zen_tab_bar.dimen,
        status_bar = browser._zen_status_row and {
            bounds = browser._zen_status_row.dimen,
            instance = tostring(browser._zen_status_row),
            values = browser._zen_status_row._zen_status_item_values,
        },
        status_refresh_bound = browser._zen_status_clock_bound == true,
        edge_padding = browser._zen_header_top_padding,
        screen_width = browser.dimen.w,
        screen_height = browser.dimen.h,
        content_bottom = browser._zen_content_panel and browser._zen_content_panel.dimen.y
            + browser._zen_content_panel.dimen.h,
        book_info = panel and panel.show_title == false and {
            bounds = panel.dimen, title_bar = panel._title_widget ~= nil,
            body_y = panel._L.body_y, description = panel.description,
        } or nil,
        top_is_browser = UIManager._window_stack[#UIManager._window_stack].widget == browser,
        panel_height = browser._zen_panel_h,
        preview_divider = browser._zen_preview_divider and browser._zen_preview_divider.dimen,
        chapter_bounds = browser._zen_chapter_zone,
        previous_bounds = browser._zen_btn_skip_left_zone,
        next_bounds = browser._zen_btn_skip_right_zone,
        grid_bounds = browser._zen_layout_zone,
        search_bounds = browser._zen_search_zone,
        slider_bounds = browser._zen_slider and browser._zen_slider.dimen,
        active_tab = browser._zen_active_tab,
        page_actions_open = top.name == "page_browser_page_actions",
        page_action_buttons = top.name == "page_browser_page_actions" and M.button_state(top.buttontable) or nil,
        browser_buttons_visible = browser._zen_active_tab == "browser",
        content_items = #(panel and panel.item_table or {}),
        content_zen_scroll_bar = browser._zen_content_panel
            and browser._zen_content_panel._zen_page_number_zones ~= nil or false,
        aa_pages = browser._zen_active_tab == "aa" and browser._zen_row_panel._zen_panel_refs.page_num or nil,
        thumbnail_count = browser.nb_grid_items or 0,
        thumbnails_ready = ready,
        focus_page = browser.focus_page or browser.cur_page,
        preview_bookmarked = not not browser.bookmarked_pages[browser:_zenFocusedDocumentPage()],
        preview_bookmark_icon_width = browser.ui.view.dogear.icon:getSize().w,
        focused = focused and focused._zen_focus_id,
        controls = { "single", "carousel", "grid" },
        header_icons = header_icons,
        header_paths = header_paths,
        footer_icons = { grid = browser._zen_layout_button.file, search = browser._zen_search_button.file,
            previous = browser._zen_btn_skip_left.file, next = browser._zen_btn_skip_right.file },
        layout_menu = layout_menu and { count = #layout_menu.buttons, rows = layout_rows, anchor = menu_anchor(layout_menu),
            bounds = layout_menu.movable.dimen } or nil,
    }
end

function M.annotation_viewer_action(params)
    local ui = reader()
    local browser = page_browser() or find_widget(function(widget) return widget._zen_standalone end)
    if params.action == "dispatch" then
        require("dispatcher"):execute({ [params.name] = true })
        return true
    elseif params.action == "close" then
        browser:onClose()
        return true
    elseif params.action == "more" then
        require("modules/reader/annotation_viewer").showMenu(browser)
        return true
    elseif params.action == "open" then
        ui:switchDocument(params.file)
        return true
    elseif params.action == "seed" then
        local page = ui.rolling and ui.document:getXPointer() or ui:getCurrentPage()
        ui.annotation.annotations = {
            { page = page, datetime = "2026-10-18 12:00:00", text = "in First", chapter = "First" },
            { page = page, pos0 = page, pos1 = page, datetime = "2026-10-18 12:01:00",
                text = "A quiet highlighted thought", note = "Personal note", chapter = "First",
                drawer = "lighten", color = "yellow" },
            { page = page, pos0 = page, pos1 = page, datetime = "2026-10-18 12:02:00",
                text = "A second passage", chapter = "Second", drawer = "underscore", color = "red" },
        }
        if ui.paging then
            for _i, item in ipairs(ui.annotation.annotations) do
                if item.drawer then
                    item.pos0, item.pos1 = { page = page, x = 40, y = 40 }, { page = page, x = 120, y = 60 }
                    item.pboxes = { { x = 40, y = 40, w = 80, h = 20 } }
                end
            end
        end
        return true
    elseif params.action == "tab" then
        browser:_zenSelectTab(params.tab)
        return true
    elseif params.action == "search" then
        local title = browser._zen_content_panel.title_bar
        local button = browser._zen_standalone and title.left_button or title.right_button
        local bounds = button.image.dimen
        UIManager:sendEvent(require("ui/event"):new("Gesture", {
            ges = "tap", pos = require("ui/geometry"):new{
                x = bounds.x + bounds.w / 2, y = bounds.y + bounds.h / 2, w = 1, h = 1,
            },
        }))
        return true
    elseif params.action == "details" then
        browser._zen_content_panel:onMenuSelect(browser._zen_content_panel.item_table[params.index or 1])
        return true
    elseif params.action == "close_details" then
        local viewer = find_widget(function(widget) return widget.buttons_table and widget.titlebar end)
        if not viewer then return false, "details unavailable" end
        viewer.titlebar.right_button.callback()
        return true
    elseif params.action == "input" then
        local input = find_widget(function(widget) return type(widget.setInputText) == "function" end)
        if not input then return false, "input dialog unavailable" end
        input:setInputText(params.text)
        return true
    elseif params.action == "button" then
        for index = #UIManager._window_stack, 1, -1 do
            local widget = UIManager._window_stack[index].widget
            for _i, row in ipairs(widget.buttons_table or widget.buttons or {}) do
                for _j, button in ipairs(row) do
                    if button.text == params.text and button.callback then button.callback(); return true end
                end
            end
        end
        return false, "button unavailable: " .. tostring(params.text)
    end
    return false, "unknown annotation action"
end

function M.annotation_viewer_state()
    local viewer = find_widget(function(widget) return widget._zen_standalone end)
    if not viewer then return { ok = false } end
    local items = {}
    for _i, item in ipairs(viewer._zen_content_panel.item_table) do
        items[#items + 1] = { file = item.record.file, kind = item.record.kind }
    end
    return { ok = true, tab = viewer._zen_active_tab, scope = viewer._zen_annotations.scope, loading = viewer._zen_annotations.loading == true,
        items = items, search_icon = viewer._zen_content_panel.title_bar.left_button.image.file }
end

function M.page_browser_key(key)
    local browser = page_browser()
    if not browser then return false, "page browser unavailable" end
    local Event = require("ui/event")
    local Key = require("device/key")
    return browser:handleEvent(Event:new("KeyPress", Key:new(key, {}))) == true
end

function M.hardware_overlay_state()
    local ui = reader()
    local annotations = ui and ui.annotation and ui.annotation.annotations
    local style = require("common/ui/zen_title_style")
    local leading_bounds = { x = style.getLeadingIconX(0), y = style.VERTICAL_PADDING
        + math.floor((style.ROW_HEIGHT - style.ICON_SIZE) / 2), w = style.ICON_SIZE, h = style.ICON_SIZE }
    local toc = toc_overlay()
    if toc then
        return {
            kind = "toc",
            show_back = toc.show_back,
            focused = toc._zen_focus_area,
            entry = toc._zen_focus_entry_idx,
            footer = toc._zen_footer_side,
            leading_bounds = leading_bounds,
        }
    end
    local info = book_info_overlay()
    if info then
        return {
            kind = "book_info",
            focused = info._zen_focus_area,
            show_back = info.show_back ~= false, leading_bounds = leading_bounds,
            annotation_count = type(annotations) == "table" and #annotations or 0,
        }
    end
    local menu, container = bookmark_menu()
    if menu and is_visible(container) then
        local selected = menu.selected
        local row = selected and menu.layout and menu.layout[selected.y]
        local focused = row and row[selected.x]
        local title_bar = menu.title_bar
        local area = focused == (title_bar and title_bar.left_button) and "back"
            or focused == (title_bar and title_bar.right_button) and "close"
            or focused == (title_bar and title_bar.menu_button) and "menu"
            or focused and "bookmark" or nil
        return { kind = "bookmarks", focused = area, filtered = ui.bookmark.match_table ~= nil,
            show_back = title_bar and title_bar.left_button ~= nil, leading_bounds = leading_bounds }
    end
    local search = ui and ui.search and ui.search.input_dialog
    if is_visible(search) then return { kind = "search", title = search.title } end
end

function M.hardware_overlay_key(key)
    local menu, container = bookmark_menu()
    local target = toc_overlay() or book_info_overlay()
        or (menu and is_visible(container) and menu)
        or (reader() and reader().search and reader().search.input_dialog)
    if not target then return false, "hardware overlay unavailable" end
    local Event = require("ui/event")
    local Key = require("device/key")
    return target:handleEvent(Event:new("KeyPress", Key:new(key, {}))) == true
end

function M.overlay_state()
    local ui = reader()
    if not ui then return {} end
    local highlight_dialog = ui.highlight and ui.highlight.highlight_dialog
    local config_dialog = ui.config and ui.config.config_dialog
    local browser = page_browser()
    local highlight_visible = is_visible(highlight_dialog)
    local top_window = UIManager._window_stack
        and UIManager._window_stack[#UIManager._window_stack]
    local top_widget = top_window and top_window.widget
    local controls = {}
    if highlight_visible then
        local known = {
            dictionary = "lookup.dictionary",
            highlight = "lookup.highlight",
            search = "lookup.search",
            translate = "lookup.translate",
        }
        for name, icon in pairs(known) do
            if find_control(highlight_dialog, icon, {}, 0) then controls[#controls + 1] = name end
        end
        table.sort(controls)
    end
    return {
        page_browser = browser ~= nil,
        aa_menu = is_visible(config_dialog),
        vocabulary_builder = is_visible(ui.vocabbuilder and ui.vocabbuilder.widget),
        highlight_menu = highlight_visible,
        highlight_controls = controls,
        lookup_buttons = M.button_state(top_widget and top_widget.button_table),
        dictionary_menu = dictionary_requested
            and not highlight_visible
            and browser == nil
            and top_widget ~= nil
            and top_widget ~= ui
            and top_widget ~= config_dialog,
        dictionary_data_dir = ui.dictionary and ui.dictionary.data_dir or nil,
    }
end

local function seed_annotations()
    local ui = reader()
    local annotation = ui and ui.annotation
    local document = ui and ui.document
    if not (annotation and document) then return false, "annotations unavailable" end
    if type(annotation.annotations) ~= "table" then annotation.annotations = {} end
    local page = ui.rolling and document:getXPointer()
        or (type(document.getCurrentPage) == "function" and document:getCurrentPage())
    if page == nil then return false, "reader position unavailable" end
    local pageno = ui.rolling and document:getPageFromXPointer(page) or page
    while #annotation.annotations < 3 do
        local index = #annotation.annotations + 1
        annotation.annotations[#annotation.annotations + 1] = {
            datetime = "2026-06-17 21:" .. tostring(10 + index) .. ":00",
            note = "Showcase annotation " .. tostring(index),
            page = page,
            pageno = pageno,
        }
    end
    return true
end

function M.clear_page_bookmarks()
    local ui = reader()
    local annotation = ui and ui.annotation
    if type(annotation and annotation.annotations) ~= "table" then
        return false, "bookmarks unavailable"
    end

    local removed = false
    for index = #annotation.annotations, 1, -1 do
        if not annotation.annotations[index].drawer then
            table.remove(annotation.annotations, index)
            removed = true
        end
    end
    if not removed then return true end

    local bookmark = ui.bookmark
    if bookmark and type(bookmark.setDogearVisibility) == "function"
        and type(bookmark.getCurrentPageNumber) == "function" then
        bookmark:setDogearVisibility(bookmark:getCurrentPageNumber())
    end
    UIManager:setDirty(ui, "ui")
    return true
end

function M.launcher_state()
    local ui = reader()
    local menu = ui and ui.menu
    local container = menu and menu.menu_container
    local touch_menu = container and container[1]
    local refs = touch_menu and touch_menu._zen_panel_refs
    local buttons = {}
    for _i, row in ipairs(refs and refs.layout_rows or {}) do
        for _j, cell in ipairs(row) do
            if cell.frame then
                buttons[#buttons + 1] = { x = cell.dimen.x, y = cell.dimen.y, w = cell.dimen.w,
                    h = cell.dimen.h, circle = cell.frame[1][1][2]:getSize().w }
            end
        end
    end
    return {
        open = is_visible(container) and refs ~= nil and touch_menu.item_table
            and touch_menu.item_table.id == "app_launcher" or false,
        page = refs and refs.page or nil,
        page_num = refs and refs.page_num or nil,
        buttons = buttons,
    }
end

function M.reader_controls(params)
    local ui = reader()
    if not ui then return { ok = false, error = "reader unavailable" } end
    if params.guard_preview_buffers then
        local browser = page_browser()
        local paint = browser.paintTo
        browser.paintTo = function(widget, ...)
            for i = 1, widget.nb_grid_items or 0 do
                local frame = widget.grid[i][1][1]
                local image = frame and frame.is_page_thumbnail and frame[1]
                assert(not image or image.image:getAllocated() == 1, "Page browser painted a freed thumbnail")
            end
            return paint(widget, ...)
        end
    end
    local TextWidget = require("ui/widget/textwidget")
    if not TextWidget._zen_test_paint then
        local paint = TextWidget.paintTo
        TextWidget.paintTo = function(widget, bb, x, y)
            widget._zen_test_x = x
            return paint(widget, bb, x, y)
        end
        TextWidget._zen_test_paint = true
    end
    local PluginLoader = require("pluginloader")
    local plugin = PluginLoader:getPluginInstance("zenos") or PluginLoader:getPluginInstance("zen_ui")
    if not ui.menu.tab_item_table then ui.menu:setUpdateItemTable() end
    if params.action == "open" then
        ui.menu:onShowReaderControls()
    elseif params.action == "toc" then
        UIManager:show(require("modules/reader/zen_toc_widget"):new{ ui = ui })
    elseif params.action == "bookmarks" then
        ui.bookmark:onShowBookmark()
    elseif params.action == "book_info" then
        require("modules/reader/book_details").show(ui, { config = plugin.config, plugin = plugin })
    elseif params.action == "bottom_swipe" then
        plugin.config.reader_bottom_swipe.mode = "reader_controls"
        ui.config:onSwipeShowConfigMenu{ direction = "north" }
    end
    if params.action == "swipe_open" then ui.menu:onSwipeShowMenu{ direction = "south" } end
    local function active_controls()
        local browser = page_browser()
        return ui.menu.menu_container and ui.menu.menu_container[1]
            or browser and browser._zen_active_tab == "aa" and browser._zen_row_panel
    end
    local function font_menu()
        return find_widget(function(widget) return widget.title == "Font family" and widget.rows_per_page == 6 end)
    end
    local function setting_menu()
        return find_widget(function(widget) return widget._reader_setting and widget.buttons and widget.anchor end)
    end
    local tm = active_controls()
    if params.action == "choose" and tm then
        for _attempt = 1, (tm._zen_panel_refs and tm._zen_panel_refs.button_pages or 1) do
            local found, next_button
            for _page = 1, (tm._zen_panel_refs and tm._zen_panel_refs.page_num or 1) do
                for _i, ref in ipairs(tm._zen_panel_refs and tm._zen_panel_refs.buttons or {}) do
                    if ref.widget._reader_control_id == params.id or ref.widget._reader_setting == params.id
                            or ref.widget._reader_card_action == params.id
                            or ref.widget._reader_button_page == params.id
                            or ref.widget.book_path == params.id
                            or ref.widget.text == params.id then found = ref; break end
                    if ref.widget._reader_button_page == "next" then next_button = ref end
                end
                if found then break end
                if tm._zen_panel_refs.goto_page and tm._zen_panel_refs.page_num > 1 then
                    tm._zen_panel_refs.goto_page(tm._zen_panel_refs.page + 1)
                end
            end
            if found then
                if not found.widget.dimen then UIManager:forceRePaint() end
                local bounds = params.toggle and found.widget.toggle and found.widget.toggle.dimen or found.widget.dimen
                local gesture = { pos = require("ui/geometry"):new{
                    x = bounds.x + (params.tap and bounds.w / 2 or 1),
                    y = bounds.y + (params.tap and bounds.h / 2 or 1), w = 1, h = 1 } }
                if params.toggle or params.tap then (tm.onTapCloseAllMenus or tm.onTap)(tm, nil, gesture)
                elseif params.hold then (tm.onHoldCloseAllMenus or tm.onHold)(tm, nil, gesture)
                elseif found.callback then found.callback(tm) end
                break
            elseif next_button then next_button.callback(tm)
            elseif tm._zen_panel_refs and (tm._zen_panel_refs.button_pages or 1) > 1 then
                tm._zen_panel_refs.swipe_zones[1].move(1)
            end
        end
    elseif params.action == "pager" and tm and tm._zen_panel_refs.pager then
        local refs = tm._zen_panel_refs
        local layout = refs.layout_rows[#refs.layout_rows - (refs.section_tabs and 1 or 0)]
        local button = layout[params.direction == "previous" and 1 or 2]
        local bounds = button.dimen
        local tap = tm.onTapCloseAllMenus or tm.onTap
        tap(tm, nil, { pos = require("ui/geometry"):new{
            x = bounds.x + bounds.w / 2, y = bounds.y + bounds.h / 2, w = 1, h = 1 } })
    elseif params.action == "swipe" and tm then
        local zones = tm._zen_panel_refs.swipe_zones
        local bounds = params.zone == "settings" and tm._zen_panel_refs.pager.dimen
            or zones[(params.zone == "fonts" or params.zone == "themes") and 2 or 1].widget.dimen
        tm:handleEvent(require("ui/event"):new("Gesture", { ges = "swipe", direction = params.direction or "west",
            pos = require("ui/geometry"):new{ x = bounds.x + 10, y = bounds.y + 10, w = 1, h = 1 }, distance = 100 }))
    elseif params.action == "slider_swipe" and tm then
        local slider = tm._zen_panel_refs.sliders[1].slider
        tm:handleEvent(require("ui/event"):new("Gesture", { ges = "swipe", direction = "east",
            pos = require("ui/geometry"):new{ x = slider:_knobAbsX(), y = slider.dimen.y + 10, w = 1, h = 1 }, distance = 40 }))
    elseif params.action == "font_family" or params.action == "choose_font" then
        local dialog = font_menu()
        if not dialog and tm then
            for _i, ref in ipairs(tm._zen_panel_refs.buttons) do
                if ref.widget._reader_setting == "font_face" then ref.callback(tm); break end
            end
            dialog = font_menu()
        end
        if dialog and params.action == "choose_font" then
            local button = dialog.buttons[params.index or 1][1]
            if params.hold then button.hold_callback() else button.callback() end
        end
    elseif params.action == "font_menu" then
        local dialog = font_menu()
        if dialog then
            if params.close then UIManager:close(dialog)
            elseif params.scroll and dialog.cropping_widget then dialog.cropping_widget:_scrollBy(0, params.scroll) end
        end
    elseif params.action == "setting_menu" then
        local dialog = setting_menu()
        if not dialog then return { ok = false } end
        local settings = require("modules/menu/reader_controls/settings")
        local option = settings.options(ui)[dialog._reader_setting]
        local params_config = option and option.more_options_param or {}
        local function current()
            if dialog._reader_setting == "font_face" then return ui.font.font_face end
            if params_config.names then
                return { ui.document.configurable[params_config.names[1]], ui.document.configurable[params_config.names[2]] }
            end
            return ui.document.configurable[dialog._reader_setting]
        end
        local function press(text)
            for _i, row in ipairs(dialog.layout or {}) do
                for _j, button in ipairs(row) do
                    if button.text == text or button.text == "✓ " .. text then
                        if params.tap then
                            local bounds = button.dimen
                            dialog:handleEvent(require("ui/event"):new("Gesture", { ges = "tap",
                                pos = require("ui/geometry"):new{
                                    x = bounds.x + bounds.w / 2, y = bounds.y + bounds.h / 2, w = 1, h = 1 } }))
                        else
                            button.callback()
                        end
                        return
                    end
                end
            end
        end
        if params.button then press(params.button == "default" and "Reset" or params.button)
        elseif params.close then dialog:onClose() end
        dialog = setting_menu()
        if not dialog then return { ok = false } end
        UIManager:forceRePaint()
        local labels, positions = {}, {}
        for _i, row in ipairs(dialog.layout or {}) do
            for _j, button in ipairs(row) do
                local text = type(button.text) == "string" and button.text:gsub("^✓ ", "")
                if text == "Set as default" or text == "Reset" or text == "Sync" or text == "Back" then
                    labels[#labels + 1] = text
                    positions[text] = { x = button.dimen.x, y = button.dimen.y, w = button.dimen.w, h = button.dimen.h,
                        checked = button.text ~= text, enabled = button.enabled ~= false }
                end
            end
        end
        local value = current()
        local default = G_reader_settings:readSetting(settings.group(ui) .. "_" .. dialog._reader_setting)
        if default == nil and option then default = option.default_value end
        return { ok = true, buttons = labels, value = type(value) == "table" and value[params.right and 2 or 1] or value,
            positions = positions, bounds = dialog.movable.dimen, anchor = dialog._zen_anchor_source,
            left_value = type(value) == "table" and value[1] or nil,
            right_value = type(value) == "table" and value[2] or nil,
            paired = type(value) == "table" and (not params_config.names or not settings.syncedMargins(ui)),
            scrollable = dialog.cropping_widget ~= nil, default_value = default }
    elseif params.action == "inject_color_option" and tm then
        table.insert(require("modules/menu/reader_controls/settings").panel(ui, "appbar.contrast").options, {
            name = "zen_test_color", name_text = "Native test color", labels = { "None", "Light", "Strong" },
            values = { 2, 4, 8 }, default_value = 2,
        })
        ui.document.configurable.zen_test_color = 2
        tm:updateItems(1)
    elseif params.action == "dithering_option" and tm then
        local options = require("modules/menu/reader_controls/settings").options(ui)
        for _i, name in ipairs({ "hw_dithering", "sw_dithering" }) do options[name].show = name == params.name end
        tm:updateItems(1)
    elseif params.action == "inject_rakuyomi_option" and tm then
        table.insert(ui.config.options[1].options, {
            name = "rakuyomi_view_mode", name_text = "View Mode", event = "SetRakuViewMode",
            toggle = { "Default", "RTL", "LTR", "Vertical", "Scroll" }, values = { 0, 1, 2, 3, 4 },
            default_value = 0,
        })
        ui.document.configurable.rakuyomi_view_mode = 0
        tm:updateItems(1)
    elseif params.action == "buttons_next" and tm then
        local zone = tm._zen_panel_refs.swipe_zones[1]
        if zone then zone.move(1) end
    elseif params.action == "tab" and tm then
        if params.id == "reader_controls" then
            ui.menu:onShowReaderControls()
        else
            if tm.item_table.id == "reader_controls" then
                ui.menu:onCloseReaderMenu()
                ui.menu:onShowMenu()
            end
            tm = ui.menu.menu_container[1]
            for i, tab in ipairs(tm.tab_item_table) do
                if tab.id == params.id then tm.bar.icon_widgets[i].callback(); break end
            end
        end
    elseif params.action == "resize" then
        ui.menu:onSetDimensions(require("device").screen:getSize())
    elseif params.action == "edit_buttons" then
        local section = require("modules/settings/sections/reader_controls_settings").build{
            config = plugin.config, plugin = plugin,
            save_and_apply = function() plugin:saveConfig() end,
        }
        section.sub_item_table[1].callback()
    elseif params.action == "slider" and tm then
        local ref = tm._zen_panel_refs.sliders[params.index or 1]
        if ref then
            local slider = ref.slider
            slider._dragging = true
            slider:setValue(slider:getValue() + 1)
            slider.on_change(slider:getValue())
            slider._dragging = false
            slider.on_drag_end()
        end
    elseif params.action == "touch_slider" and tm then
        local slider = tm._zen_panel_refs.sliders[params.index or 1].slider
        local input, C = require("device").input, require("ffi").C
        local time = require("ui/time")
        local function absolute(code, value)
            input:handleTouchEv{ type = C.EV_ABS, code = code, value = math.floor(value) }
        end
        local function frame(x, tracking_id)
            absolute(C.ABS_MT_SLOT, input.main_finger_slot)
            if tracking_id then absolute(C.ABS_MT_TRACKING_ID, tracking_id) end
            absolute(C.ABS_MT_POSITION_X, x)
            absolute(C.ABS_MT_POSITION_Y, slider.dimen.y + slider.dimen.h / 2)
            local sec, usec = time.split_s_us(time.now())
            for _i, event in ipairs(input:handleTouchEv{
                type = C.EV_SYN, code = C.SYN_REPORT, time = { sec = sec, usec = usec },
            } or {}) do UIManager:sendEvent(event) end
        end
        if params.start then frame(slider:_knobAbsX(), 1) end
        frame(slider.dimen.x + slider:_valueToX(params.value or slider:getValue()), params.release and -1 or nil)
    elseif params.action == "drag_slider" and tm then
        local ref = tm._zen_panel_refs.sliders[params.index or 1]
        if ref then
            local slider = ref.slider
            local pos = require("ui/geometry"):new{ x = slider:_knobAbsX(), y = slider.dimen.y + slider.dimen.h / 2 }
            if not slider._dragging then slider:handlePan{ pos = pos, direction = "east" } end
            pos.x = slider.dimen.x + slider:_valueToX(params.value or slider:getValue() + 1)
            slider:handlePan{ pos = pos, direction = "east" }
            if params.release then slider:handlePanRelease{ pos = pos } end
        end
    elseif params.action == "close" and tm then
        tm:closeMenu()
    elseif params.action == "focus_slider" and tm then
        local target = tm._zen_panel_refs.sliders[1].slider
        for y, row in ipairs(tm.layout) do
            for x, widget in ipairs(row) do
                if widget.slider == target then tm:moveFocusTo(x, y); break end
            end
        end
    elseif params.action == "key" and tm then
        tm:handleEvent(require("ui/event"):new("KeyPress", require("device/key"):new(params.key, {})))
    elseif params.action == "switch_book" then
        require("apps/reader/readerui"):showReader(params.path)
        return { ok = true }
    elseif params.action == "paint" then
        UIManager:setDirty("all", "ui")
        UIManager:forceRePaint()
    elseif params.action == "windows" then
        return { ok = true, count = #UIManager._window_stack }
    elseif params.action == "real_tap" and tm then
        -- Dispatch through UIManager so child gesture handlers run as on device.
        UIManager:forceRePaint()
        local bounds
        for _i, row in ipairs(tm.layout or {}) do
            for _j, widget in ipairs(row) do
                if widget._reader_card_action == params.id or params.id == "book_info_card" and widget.onTapDetails then
                    bounds = widget.dimen
                end
            end
        end
        if not bounds then return { ok = false, error = "widget unavailable" } end
        UIManager:sendEvent(require("ui/event"):new("Gesture", { ges = "tap", time = require("ui/time").now(),
            pos = require("ui/geometry"):new{ x = bounds.x + (params.dx or math.floor(bounds.w / 2)),
                y = bounds.y + math.floor(bounds.h / 2), w = 0, h = 0 } }))
        return { ok = true }
    elseif params.action == "next_page" and tm then
        tm:onNextPage()
    elseif params.action == "setting" then
        require("modules/menu/reader_controls/settings").apply(ui, params.name, params.value)
    elseif params.action == "defaults" then
        require("modules/menu/reader_controls/settings").saveDefaults(ui, params.selected or {})
    elseif params.action == "capture" then
        ui.profiles.data[params.name] = require("modules/menu/reader_controls/profiles").capture(ui,
            plugin, params.name, true)
        ui.profiles.updated = true
        ui.profiles:onFlushSettings()
    elseif params.action == "apply_profile" then
        ui.profiles:onProfileExecute(params.name, { qm_show = false })
    elseif params.action == "theme" then
        require("common/reader_themes").restore(plugin, params.theme)
        ui:saveSettings()
    end
    tm = active_controls()
    local controls, labels, toggles, radios, font_count, header = {}, {}, {}, {}, 0, {}
    local bounds, selections, step_styles, zen_buttons, label_ends = {}, {}, {}, {}, {}
    local icons, outlined, title_heights, switcher_books, card_actions = {}, {}, {}, {}, {}
    local slider_bounds, slider_states, value_cells, theme_count, family_label, family_radius = {}, {}, {}, 0, nil, nil
    for _i, row in ipairs(tm and tm.layout or {}) do
        for _j, widget in ipairs(row) do
            if widget.book_path then switcher_books[#switcher_books + 1] = widget.book_path end
            if widget._reader_font_choice then font_count = font_count + 1 end
            if widget._reader_theme_choice then theme_count = theme_count + 1 end
            if widget._reader_setting == "font_face" then
                family_label, family_radius = widget.text, widget.radius
            end
            if widget._reader_control_id then header[#header + 1] = {
                id = widget._reader_control_id, x = widget.dimen.x, y = widget.dimen.y,
                w = widget.dimen.w, h = widget.dimen.h, label = widget.text } end
            if widget._reader_control_id then
                icons[widget._reader_control_id] = widget.image.file
            end
            if widget._reader_card_action then
                card_actions[#card_actions + 1] = widget._reader_card_action
                icons[widget._reader_card_action] = widget.image.file
            end
            if widget.label_box then
                labels[widget._reader_setting or widget.text] = widget.label.text .. (widget.number and widget.number.text or "")
            end
            local id = widget._reader_setting or widget._reader_button_page or widget.text
            local dimen = widget.dimen or widget.slider and widget[1].dimen
            if widget.slider then
                local spec = require("modules/menu/reader_controls/settings").slider(ui, id)
                local visible_presets = 0
                for _k, value in ipairs(spec.option.values or {}) do
                    local position = spec.position(value)
                    if position >= widget.slider.value_min and position <= widget.slider.value_max then
                        visible_presets = visible_presets + 1
                    end
                end
                slider_states[id] = { value = widget.slider:getValue(), minimum = widget.slider.value_min,
                    maximum = widget.slider.value_max,
                    knob_radius = widget.slider.knob_radius,
                    default_value = widget.slider.default_value, presets = spec.option.values, visible_presets = visible_presets,
                    dragging = widget.slider._dragging == true, knob_visible = not widget.slider.hide_knob,
                    instance = tostring(widget.slider) }
                if widget.number_box then
                    local cell = widget.number_box.dimen
                    value_cells[id] = { x = cell.x, y = cell.y, w = cell.w, h = cell.h,
                        text = widget.number.text, text_width = widget.number:getSize().w, text_x = widget.number._zen_test_x,
                        title = widget.label.text, title_x = widget.label_box.dimen.x,
                        title_width = widget.label:getSize().w }
                end
            end
            if id and dimen then
                bounds[id] = { x = dimen.x, y = dimen.y, w = dimen.w, h = dimen.h }
                if widget.selected ~= nil then selections[id] = widget.selected end
                if widget.selected ~= nil and widget[1][1].file then
                    icons[id] = widget[1][1].file
                    icons[id .. "_height"] = widget[1][1].height
                end
                if widget.slider then
                    local slider = widget.slider.dimen
                    slider_bounds[id] = { x = slider.x, y = slider.y, w = slider.w, h = slider.h }
                elseif widget.text == "−" or widget.text == "＋" then
                    local label = widget.label_widget:getSize()
                    step_styles[id] = { size = widget.text_font_size, face = widget.text_font_face,
                        bold = widget.text_font_bold, border = widget.bordersize, flash = widget.allow_flash,
                        glyph_x = dimen.x + math.floor((dimen.w - label.w) / 2),
                        glyph_w = label.w }
                elseif widget.paintTo == require("common/ui/zen_action_button").paintTo then
                    zen_buttons[id] = true
                    outlined[id] = widget.outlined == true
                end
                if widget.label_box then
                    label_ends[id] = widget.number_box and widget.number_box.dimen.x + widget.number_box.dimen.w
                        or widget.label_box.dimen.x + widget.label:getSize().w
                    title_heights[id] = widget.label:getSize().h
                end
            end
            if id and widget.image then
                icons[id] = widget.image.file
                icons[id .. "_height"] = widget.image.height
            end
            if widget.toggle then toggles[widget._reader_setting or widget.text] = widget.toggle:getValue() end
            if widget.radio then radios[widget.text] = widget.checked end
            if widget._reader_control_id or widget._reader_setting or widget.text then
                controls[#controls + 1] = widget._reader_control_id or widget._reader_setting or widget.text
            end
        end
    end
    local tabs = {}
    for _i, tab in ipairs(ui.menu.tab_item_table or {}) do
        tabs[#tabs + 1] = tab.id
    end
    local native_settings = require("modules/menu/reader_controls/settings")
    local options = native_settings.options(ui)
    local color_options = {}
    local color_panel = native_settings.panel(ui, "appbar.contrast")
    for _i, option in ipairs(color_panel and color_panel.options or {}) do
        color_options[#color_options + 1] = { name = option.name,
            available = native_settings.available(ui, option), slider = option.buttonprogress == true,
            values = option.values, labels = option.toggle or option.labels }
    end
    local headings = {}
    for text, widget in pairs(tm and tm._zen_panel_refs and tm._zen_panel_refs.headings or {}) do
        if widget.dimen then
            headings[text] = { x = widget.dimen.x, y = widget.dimen.y, w = widget.dimen.w,
                bold = widget[1].bold == true }
        end
    end
    local refs = tm and tm._zen_panel_refs
    local dividers, settings_row_bounds = {}, {}
    for _i, widget in ipairs(tm and tm._reader_controls_embedded and tm[1][1] or {}) do
        if widget == refs.pager or widget[1] == refs.section_tabs then break end
        local line = widget[1]
        local row_bounds = widget.dimen or line and line.dimen
        if line and widget.dimen and getmetatable(line) == require("ui/widget/linewidget") then
            dividers[#dividers + 1] = { x = widget.dimen.x + widget._padding_left,
                y = widget.dimen.y + widget._padding_top, width = line.dimen.w,
                height = line.dimen.h, spacing = widget.dimen.h - line.dimen.h,
                light_gray = line.background == require("ffi/blitbuffer").COLOR_LIGHT_GRAY }
        elseif row_bounds and getmetatable(widget) ~= require("ui/widget/verticalspan") then
            local size = widget:getSize()
            settings_row_bounds[#settings_row_bounds + 1] = { x = row_bounds.x, y = row_bounds.y, w = size.w, h = size.h }
        end
    end
    local pager = refs and refs.pager and refs.pager.dimen
    local pager_buttons = {}
    for _i, widget in ipairs(refs and refs.pager
            and refs.layout_rows[#refs.layout_rows - (refs.section_tabs and 1 or 0)] or {}) do
        pager_buttons[#pager_buttons + 1] = { x = widget.dimen.x, y = widget.dimen.y,
            w = widget.dimen.w, h = widget.dimen.h, icon_width = widget.width, icon_height = widget.height }
    end
    local subsection_labels = {}
    for _i, cell in ipairs(refs and refs.section_tabs and refs.section_tabs.cells or {}) do
        subsection_labels[#subsection_labels + 1] = cell.text
    end
    local bar = refs and refs.tab_bar
    local reader_tabs = {}
    for _i, cell in ipairs(bar and bar.icon_widgets or {}) do
        reader_tabs[#reader_tabs + 1] = { x = cell.dimen.x, w = cell.dimen.w }
    end
    local separators, footer_visible = {}, false
    for _i, separator in ipairs(bar and bar.icon_seps or {}) do separators[#separators + 1] = separator.style end
    for _i, widget in ipairs(tm and tm.item_group or {}) do footer_visible = footer_visible or widget == tm.footer end
    local family_menu = font_menu()
    local family_anchor = family_menu and menu_anchor(family_menu)
    return { ok = true, header = header, switcher_books = switcher_books, card_actions = card_actions,
        font_family_label = family_label,
        font_family_radius = family_radius,
        font_menu = family_menu and { open = true, count = #family_menu.buttons,
            scrollable = family_menu.cropping_widget ~= nil,
            scroll_y = family_menu.cropping_widget and family_menu.cropping_widget._scroll_offset_y,
            anchor = { x = family_anchor.x, y = family_anchor.y, w = family_anchor.w, h = family_anchor.h },
            bounds = family_menu.movable.dimen } or { open = false },
        native_reader_tabs = bar and getmetatable(bar) == getmetatable(tm.bar) or false,
        reader_tab_line_on_top = bar and bar[1][1][1] == bar.bar_sep or false,
        reader_tab_gap = bar and bar.bar_sep.empty_segments,
        reader_tab_bounds = reader_tabs,
        reader_tab_separators = separators,
        reader_status_row = refs and refs.status_row ~= nil or false,
        footer_visible = footer_visible,
        color_options = color_options,
        document_dithering = { hw_dithering = ui.document.hw_dithering, sw_dithering = ui.document.sw_dithering },
        saturation_available = native_settings.available(ui, options.saturation),
        white_threshold_available = native_settings.available(ui, options.white_threshold),
        active_tab = tm and (tm._reader_controls_embedded and "aa" or tm.item_table.id),
        settings_rows = refs and refs.layout_rows and #refs.layout_rows - (refs.section_tabs and 2 or refs.pager and 1 or 0),
        subsections = refs and refs.section_order,
        subsection_labels = subsection_labels,
        section_tabs = refs and refs.section_tabs and refs.section_tabs.dimen,
        section_tab_radius = refs and refs.section_tabs and refs.section_tabs.radius,
        settings_dividers = dividers,
        settings_row_bounds = settings_row_bounds,
        button_page = tm and tm._zen_panel_refs and tm._zen_panel_refs.button_page,
        button_pages = tm and tm._zen_panel_refs and tm._zen_panel_refs.button_pages,
        page_chevrons = plugin.config.reader_controls.show_page_chevrons,
        theme_page = tm and tm._reader_controls_state and tm._reader_controls_state.themes_page,
        theme_pages = tm and tm._reader_controls_state and tm._reader_controls_state.themes_pages,
        theme_count = theme_count, slider_bounds = slider_bounds, slider_states = slider_states, value_cells = value_cells,
        headings = headings,
        menu_bottom = tm and tm.dimen and tm.dimen.y + tm.dimen.h,
        menu_top = tm and tm.dimen and tm.dimen.y,
        screen_height = require("device").screen:getHeight(),
        screen_width = require("device").screen:getWidth(),
        footer_margin = tm and (refs and refs.footer_top_margin or tm.footer_top_margin)
            and (refs and refs.footer_top_margin or tm.footer_top_margin):getSize().h,
        native_footer_margin = tm and tm.footer_top_margin and tm.footer_top_margin:getSize().h,
        font_face = ui.font and ui.font.font_face,
        hatched_background = tm and tm._zen_hatched_background ~= nil or false,
        hatching_enabled = plugin.config.quick_settings.background_hatching,
        controls = controls, labels = labels, toggles = toggles, radios = radios, font_count = font_count,
        bounds = bounds, selections = selections, step_styles = step_styles, zen_buttons = zen_buttons, label_ends = label_ends,
        icons = icons, outlined = outlined, title_heights = title_heights,
        tabs = tabs, config = ui.document.configurable,
        menu_open = ui.menu.menu_container ~= nil,
        locked = tm and tm._zen_panel_locked,
        input_inhibited = require("device").input._abs_ev_handler ~= nil,
        pan_threshold = require("device").input.gesture_detector.PAN_THRESHOLD,
        section = tm and tm._reader_controls_state and tm._reader_controls_state.section,
        page_num = tm and tm._zen_panel_refs and tm._zen_panel_refs.page_num,
        page = refs and refs.page,
        pager = pager and { x = pager.x, y = pager.y, w = pager.w, h = pager.h },
        pager_buttons = pager_buttons,
        global_themes = plugin.config.reader_themes,
        theme = require("common/reader_themes").capture(plugin),
        default_size = G_reader_settings:readSetting("copt_font_size"),
        default_font = G_reader_settings:readSetting("cre_font"),
        default_margins = G_reader_settings:readSetting("copt_h_page_margins"),
        default_top = G_reader_settings:readSetting("copt_t_page_margin"),
        default_bottom = G_reader_settings:readSetting("copt_b_page_margin"),
        profile = params.name and ui.profiles and ui.profiles.data[params.name] }
end

local function tap_browser_widget(widget, gesture, direction)
    if not (widget and widget.dimen) then return false, "control unavailable" end
    local bounds = widget.dimen
    local screen_width = require("device").screen:getWidth()
    UIManager:sendEvent(require("ui/event"):new("Gesture", {
        ges = gesture or "tap", direction = direction or "south", distance = 4,
        pos = require("ui/geometry"):new{ x = (math.max(0, bounds.x) + math.min(screen_width, bounds.x + bounds.w)) / 2,
            y = bounds.y + bounds.h / 2, w = 1, h = 1 },
    }))
    return true
end

function M.activate(name)
    local ui = reader()
    if not (ui and ui.document) then return false, "reader unavailable" end
    if name == "seed_annotations" then return seed_annotations() end
    if name == "reader_menu" then
        local menu = ui.menu
        if not (menu and type(menu.onShowMenu) == "function") then
            return false, "reader menu unavailable"
        end
        menu:onShowMenu()
        return menu.menu_container ~= nil
    end
    if name == "launcher_book_switcher" then
        return open_launcher_page(2)
    end
    if name == "launcher_book_details" then
        return open_launcher_page(3)
    end
    if name == "launcher_book_details_fullscreen" then
        local opened, err = open_launcher_page(3)
        if not opened then return false, err end
        local menu = ui.menu
        local touch_menu = menu and menu.menu_container and menu.menu_container[1]
        local button = touch_menu and touch_menu._zen_panel_refs
            and touch_menu._zen_panel_refs.buttons and touch_menu._zen_panel_refs.buttons[1]
        if not (button and type(button.callback) == "function") then
            return false, "book details action unavailable"
        end
        button.callback()
        return true
    end
    if name == "page_browser" then
        local config = ui.config
        if not (config and type(config.onSwipeShowConfigMenu) == "function") then
            return false, "reader config unavailable"
        end
        return config:onSwipeShowConfigMenu({
            direction = "north",
            pos = { x = 1, y = require("device").screen:getHeight() - 1 },
        }) == true
    end
    local browser = page_browser()
    if name == "page_browser_controls" or name == "page_browser_toc" or name == "page_browser_bookmarks"
            or name == "page_browser_annotations" or name == "page_browser_book_details"
            or name == "page_browser_book_switcher" then
        if not browser then return false, "page browser unavailable" end
        local icons = { page_browser_controls = ui.paging and "appbar.contrast" or "font", page_browser_toc = "toc",
            page_browser_bookmarks = "bookmark_outline", page_browser_annotations = "annotations", page_browser_book_details = "info",
            page_browser_book_switcher = "history" }
        return tap_browser_widget(find_control(browser.title_bar, icons[name], {}, 0))
    elseif name == "page_browser_switch_book" then
        local panel = browser and browser._zen_active_tab == "book_switcher" and browser._zen_content_panel
        return tap_browser_widget(panel and panel.layout[1] and panel.layout[1][1])
    elseif name == "page_browser_search" then
        if not browser then return false, "page browser unavailable" end
        if browser._zen_active_tab ~= "browser" then return false, "page browser tab inactive" end
        return tap_browser_widget(browser._zen_search_button)
    elseif name == "page_browser_pages" then
        if not browser then return false, "page browser unavailable" end
        return tap_browser_widget(find_control(browser.title_bar, "view_carousel_outline", {}, 0))
    elseif name == "page_browser_layout_menu" then
        if not browser then return false, "page browser unavailable" end
        return tap_browser_widget(browser._zen_layout_button)
    elseif name == "page_browser_more" then
        if not browser then return false, "page browser unavailable" end
        return tap_browser_widget(browser._zen_more_button)
    elseif name == "page_browser_full_page" or name == "page_browser_reader_controls"
            or name == "page_browser_reader_settings" then
        if not browser then return false, "page browser unavailable" end
        local menu = find_widget(function(widget)
            return menu_anchor(widget) == browser._zen_more_button.dimen and widget.buttons
        end)
        local text = name == "page_browser_full_page" and "Show full page"
            or name == "page_browser_reader_controls" and "Reader controls" or "Settings"
        text = require("gettext")(text)
        for _i, row in ipairs(menu and menu.buttontable.buttons_layout or {}) do
            if row[1].text == text or row[1].text == text .. " ✓" then return tap_browser_widget(row[1]) end
        end
        return false, "menu entry unavailable"
    elseif name == "page_browser_font_next" or name == "page_browser_font_previous" then
        if not browser or browser._zen_active_tab ~= "aa" then return false, "font tab unavailable" end
        local refs = browser._zen_row_panel._zen_panel_refs
        local buttons = refs.layout_rows[#refs.layout_rows - 1]
        return tap_browser_widget(buttons[name == "page_browser_font_next" and 2 or 1])
    elseif name:match("^page_browser_section_") then
        if not browser or browser._zen_active_tab ~= "aa" then return false, "font tab unavailable" end
        local section = name:sub(#"page_browser_section_" + 1)
        local tabs = browser._zen_row_panel._zen_panel_refs.section_tabs
        for _i, cell in ipairs(tabs.cells) do
            if cell._reader_section == section then return tap_browser_widget(cell) end
        end
        return false, "section unavailable"
    elseif name == "page_browser_top_swipe" then
        if not browser then return false, "page browser unavailable" end
        -- Swipe down from the top edge, above the tabs; report whether the reader menu opened, then close it.
        tap_browser_widget({ dimen = { x = 0, y = 0, w = browser.dimen.w, h = 20 } }, "swipe")
        local opened = ui.menu.menu_container ~= nil
        if opened then ui.menu:onCloseReaderMenu() end
        return opened
    elseif name == "page_browser_tab_swipe" then
        if not browser then return false, "page browser unavailable" end
        return tap_browser_widget(browser._zen_tab_bar.cells[2], "swipe")
    elseif name == "page_browser_bookmark_page" or name == "page_browser_pin_page" then
        local dialog = UIManager:getTopmostVisibleWidget()
        if dialog.name ~= "page_browser_page_actions" then return false, "page actions unavailable" end
        return tap_browser_widget(dialog.buttontable.buttons_layout[1][name == "page_browser_bookmark_page" and 1 or 2])
    elseif name:match("^page_browser_preview_") then
        if not browser then return false, "page browser unavailable" end
        local action = name:sub(#"page_browser_preview_" + 1)
        local index = (browser.focus_page_shift or 0) + 1 + (action == "left" and -1 or action == "right" and 1 or 0)
        return tap_browser_widget(browser._zen_full_page_preview or browser.grid[index], action == "hold" and "hold"
            or action:match("^swipe") and "swipe" or "tap", action == "swipe_previous" and "east" or "west")
    elseif name == "page_browser_single" or name == "page_browser_carousel" or name == "page_browser_grid" then
        if not browser then return false, "page browser unavailable" end
        local mode = name:sub(#"page_browser_" + 1)
        local dialog = find_widget(function(widget)
            return menu_anchor(widget) == browser._zen_layout_button.dimen and widget.buttons and #widget.buttons == 3
        end)
        if dialog then dialog.buttons[mode == "single" and 1 or mode == "carousel" and 2 or 3][1].callback()
        else browser["_zen_switch_" .. mode]() end
        return true
    elseif name == "show_highlight_menu" then
        local highlight = ui.highlight
        if not (highlight and type(highlight.onShowHighlightMenu) == "function") then
            return false, "highlight unavailable"
        end
        highlight.hold_pos = { x = 10, y = 10 }
        highlight.selected_text = {
            text = "deterministic",
            pos0 = { page = 1, x = 10, y = 10 },
            pos1 = { page = 1, x = 80, y = 30 },
            sboxes = { { x = 10, y = 10, w = 70, h = 20 } },
        }
        highlight:onShowHighlightMenu()
        return is_visible(highlight.highlight_dialog)
    elseif name == "highlight_dictionary" then
        local highlight_dialog = ui.highlight and ui.highlight.highlight_dialog
        if not is_visible(highlight_dialog) then return false, "highlight menu unavailable" end
        dictionary_requested = activate_icon(highlight_dialog, "lookup.dictionary")
        return dictionary_requested
    elseif name == "lookup_vocabulary" then
        local lookup = find_widget(function(widget) return widget.button_table ~= nil end)
        local button = lookup and lookup.button_table:getButtonById("vocabulary")
        if not button then return false, "vocabulary button unavailable" end
        button.callback()
        return true
    end
    return false, "unknown reader control"
end

function M.reference_action(params)
    local ui = reader()
    if not ui then return { ok = false, error = "no reader" } end
    local References = require("modules/reader/references")
    local state = ui._zen_references
    local drawer = state and state.drawer
    -- Synthetic taps land instantly; skip the link double-tap guard.
    if drawer then drawer.tap_guard_until = nil end
    local browser = page_browser()
    local action = params.action
    local navigation_updates, top_menu_open
    if action == "close_book" then
        ui:onHome()
        return { ok = true, references = {} }
    elseif action == "pin" then
        References.pinButtons(ui, params.page)[1].callback()
    elseif action == "remove" then
        ui.gotopage:onPinPage(nil, true)
    elseif action == "open_pin" then References.openPinned(ui, params.index)
    elseif action == "top_menu" then
        ui.menu.activation_menu = params.activation or "swipe_tap"
        local bounds = browser and browser._zen_status_row and browser._zen_status_row.dimen
            or { x = 0, y = 0, w = ui.dimen.w, h = ui.dimen.h * 0.07 }
        tap_browser_widget({ dimen = bounds }, params.gesture)
        top_menu_open = ui.menu.menu_container ~= nil
        if top_menu_open then ui.menu.menu_container[1]:closeMenu() end
    elseif action == "hold_image" then
        local pos = require("ui/geometry"):new{ x = params.x or ui.dimen.w / 2, y = params.y or ui.dimen.h / 2 }
        ui:handleEvent(require("ui/event"):new("Gesture", { ges = "hold", pos = pos }))
        ui:handleEvent(require("ui/event"):new("Gesture", { ges = "hold_release", pos = pos }))
    elseif action == "image_view" then
        local dialog = ui.highlight.highlight_dialog
        if not dialog or dialog.name ~= "highlight_image_dialog" then return { ok = false, error = "Image menu missing" } end
        dialog.buttons[1][1].callback()
    elseif action == "dismiss_image_menu" then
        ui.highlight.highlight_dialog:handleEvent(require("ui/event"):new("Gesture", {
            ges = "tap", pos = require("ui/geometry"):new{ x = 1, y = 1 },
        }))
    elseif action == "close_image" or action == "tap_image" then
        local viewer = find_widget(function(widget) return getmetatable(widget) == require("ui/widget/imageviewer") end)
        if not viewer then return { ok = false, error = "Image viewer missing" } end
        if action == "tap_image" then
            viewer:handleEvent(require("ui/event"):new("Gesture", { ges = "tap",
                pos = require("ui/geometry"):new{ x = ui.dimen.w / 2, y = ui.dimen.h / 2 } }))
        else viewer:onClose() end
    elseif action == "footer_enabled" then
        local plugin = require("pluginloader"):getPluginInstance("zenos")
        plugin.config.reader_footer.status_bar_enabled = params.enabled
        local footer = ui.view.footer
        footer:applyFooterMode(params.enabled and footer.mode_list.page_progress or footer.mode_list.off)
        footer:refreshFooter(true, true)
    elseif action == "pin_preset" then
        local presets = require("modules/reader/patches/reader_footer_presets")
        ui.view.footer:loadPreset(require("util").tableDeepCopy(presets[params.index]))
    elseif action == "pin_menu" then drawer:showMenu()
    elseif action == "pin_popup_action" then
        local dialog = find_widget(function(widget) return widget._zen_pin_menu end)
        if not dialog then return { ok = false, error = "Pin popup menu missing" } end
        local found = false
        for _i, row in ipairs(dialog.buttons) do
            for _j, item in ipairs(row) do
                if item.text == params.text then item.callback(); found = true; break end
            end
        end
        if not found then return { ok = false, error = "Pin popup action missing" } end
    elseif action == "pin_font_size" then
        local spin = find_widget(function(widget) return widget.title_text == "Font size" end)
        if not spin then return { ok = false, error = "Font size control missing" } end
        if params.absolute then spin.extra_callback()
        else spin.value = params.value; spin.callback(spin); UIManager:close(spin) end
    elseif action == "pin_control" then
        local target = params.target
        local footer = ui.view.footer
        local bounds = target == "footer" and footer._zen_pin_dimen
            or target == "menu" and drawer.menu_button.dimen
            or target == "zoom" and drawer.zoom_button.dimen
            or target == "zoom_in" and drawer.zoom_in_button.dimen
            or target == "zoom_out" and drawer.zoom_out_button.dimen
            or drawer.pager.dimen
        local pos = require("ui/geometry"):new{
            x = bounds.x + bounds.w * (params.x_ratio or 0.5),
            y = bounds.y + bounds.h * (params.y_ratio or 0.5) }
        if target == "next" then pos.x = bounds.x + bounds.w - 2 end
        if target == "previous" then pos.x = bounds.x + 2 end
        local widget = target == "footer" and ui or drawer
        widget:handleEvent(require("ui/event"):new("Gesture", { ges = params.gesture or "tap", pos = pos }))
    elseif action == "open_note" then References.openFootnote(ui)
    elseif action == "close" then drawer:onClose()
    elseif action == "expand" then drawer:onExpand()
    elseif action == "check_pin_navigation" then
        local dirty, repaint = UIManager.setDirty, UIManager.widgetRepaint
        navigation_updates = 0
        UIManager.setDirty = function(manager, ...)
            navigation_updates = navigation_updates + 1
            return dirty(manager, ...)
        end
        UIManager.widgetRepaint = function(manager, ...)
            navigation_updates = navigation_updates + 1
            return repaint(manager, ...)
        end
        local ok, err = pcall(function()
            drawer.page_button:onTapSelectButton()
            drawer:onExpand()
        end)
        UIManager.setDirty, UIManager.widgetRepaint = dirty, repaint
        if not ok then error(err) end
    elseif action == "next" then drawer:onNextReferencePage()
    elseif action == "previous" then drawer:onPreviousReferencePage()
    elseif action == "zoom" then drawer:zoom(params.factor)
    elseif action == "scroll" then drawer.htmlwidget:scrollToRatio(params.ratio)
    elseif action == "goto" then
        ui.link:addCurrentLocationToStack()
        ui:handleEvent(require("ui/event"):new("GotoPage", params.page))
    elseif action == "jump" then
        ui:handleEvent(require("ui/event"):new("GotoPage", params.page))
    elseif action == "preview" or action == "browser_jump" then
        browser:updateFocusPage(params.page, false)
        if action == "browser_jump" then browser:_zenOpenFocusedPage() end
    elseif action == "toc_jump" then
        ui.toc:onShowToc()
        local item = ui.toc.toc[params.index or 2]
        if not item then return { ok = false, error = "TOC entry missing" } end
        ui.toc.toc_menu:onMenuSelect(item)
    elseif action == "turn" then
        ui:handleEvent(require("ui/event"):new("GotoViewRel", params.step or 1))
    elseif action == "return" then
        local bounds = ui._zen_return_button.dimen
        ui:handleEvent(require("ui/event"):new("Gesture", { ges = params.gesture or "tap", direction = params.direction,
            time = require("ui/time").now(), distance = require("device").screen:scaleBySize(50),
            pos = require("ui/geometry"):new{ x = bounds.x + bounds.w / 2, y = bounds.y + bounds.h / 2 } }))
    elseif action == "expire_return" then
        ui._zen_return_button.expire()
    elseif action == "suspend" then
        ui.link:onSuspend()
    elseif action == "header" then
        local plugin = require("pluginloader"):getPluginInstance("zenos")
        plugin.config.reader_top_status_bar.left_order = { "current_page", "wifi" }
        if params.right then plugin.config.reader_top_status_bar.right_order = { "battery_percent", "pin" } end
        if params.pin_side then
            plugin.config.reader_top_status_bar.left_order = { params.pin_side == "left" and "pin" or "current_page" }
            plugin.config.reader_top_status_bar.right_order = params.pin_side == "right" and { "pin" } or {}
        end
        if params.long_text then
            plugin.config.reader_top_status_bar.custom_text = string.rep("Long header text ", 50)
            plugin.config.reader_top_status_bar.left_order = {}
            plugin.config.reader_top_status_bar.right_order = { "custom_text", "pin" }
        end
        plugin.config.reader_top_status_bar.hide_in_cbz = false
        UIManager:setDirty(ui, "ui")
    elseif action == "footer_progress_only" or action == "footer_tap" or action == "footer_state" then
        local footer = ui.view.footer
        if params.preset then
            local presets = require("modules/reader/patches/reader_footer_presets")
            footer:loadPreset(require("util").tableDeepCopy(presets[params.preset]))
        elseif action == "footer_progress_only" then
            for _i, mode in ipairs(footer.mode_index) do footer.settings[mode] = false end
            footer.settings.disable_progress_bar = false
        end
        if params.settings then
            for key, value in pairs(params.settings) do footer.settings[key] = value end
            footer:updateFooterContainer()
            footer:set_has_no_mode()
            footer:updateFooterTextGenerator()
            if footer.has_no_mode then footer:applyFooterMode(footer.mode_list.page_progress) end
            footer:refreshFooter(true, true)
        end
        if action == "footer_tap" then
            local screen = require("device").screen
            UIManager:sendEvent(require("ui/event"):new("Gesture", { ges = "tap", time = require("ui/time").now(),
                pos = require("ui/geometry"):new{ x = screen:getWidth() / 2, y = screen:getHeight() - 5, w = 1, h = 1 } }))
        end
        local plugin = require("pluginloader"):getPluginInstance("zenos")
        return { ok = true, references = { footer_visible = ui.view.footer_visible, has_no_mode = footer.has_no_mode,
            mode_name = footer.mode_index[footer.mode],
            bar = footer.progress_bar.dimen and { x = footer.progress_bar.dimen.x, w = footer.progress_bar.dimen.w },
            pin = footer._zen_pin_dimen and { x = footer._zen_pin_dimen.x, w = footer._zen_pin_dimen.w },
            margins = { require("common/reader_status_bar").getHorizontalMargins(ui.document, 0, plugin) },
            screen_w = require("device").screen:getWidth(),
            zen_enabled = require("common/dispatch_action").isBottomStatusBarEnabled(plugin) } }
    elseif action == "header_refresh" then
        ui:onNetworkConnected()
    elseif action == "bookmark" then
        ui.bookmark:onToggleBookmark()
    elseif action == "line_spacing" then
        ui.font:onSetLineSpace(params.value)
    elseif action == "paint" then
        local ColorIcon = require("common/ui/color_icon_widget")
        local ColorText = require("common/ui/color_text_widget")
        local paint = ColorIcon.paintTo
        local paint_text = ColorText.paintTo
        ui.view._zen_test_header_pin = nil
        ui.view._zen_test_return_icon, ui.view._zen_test_return_text = nil, nil
        ColorIcon.paintTo = function(widget, bb, x, y)
            paint(widget, bb, x, y)
            local screen = require("device").screen
            if bb == screen.bb and widget.file:match("/pin%.svg$") and y < screen:getHeight() / 2 then
                local size = widget:getSize()
                ui.view._zen_test_header_pin = { icon = widget.file, x = x, y = y, w = size.w, h = size.h }
            end
            if bb == screen.bb and widget.file:match("/return%.svg$") then
                local size = widget:getSize()
                ui.view._zen_test_return_icon = { x = x, y = y, w = size.w, h = size.h }
            end
        end
        ColorText.paintTo = function(widget, bb, x, y)
            paint_text(widget, bb, x, y)
            local button = ui._zen_return_button
            if bb == require("device").screen.bb and button and button:isVisible() and widget.text == button.text then
                local size = widget:getSize()
                ui.view._zen_test_return_text = { x = x, y = y, w = size.w, h = size.h }
            end
        end
        UIManager:setDirty(ui, "ui")
        UIManager:forceRePaint()
        ColorIcon.paintTo = paint
        ColorText.paintTo = paint_text
    elseif action == "enabled" then
        local plugin = require("pluginloader"):getPluginInstance("zenos")
        plugin.config.features.reader_references = params.enabled
        if not params.enabled then References.clear(ui) end
    elseif action == "footnote" then
        local links = ui.document:getPageLinks() or {}
        local link = links[params.index or 1]
        if not link then return { ok = false, error = "no footnote link" } end
        ui.link:onGotoLink({ xpointer = link.section, a_xpointer = link.a_xpointer,
            from_xpointer = link.a_xpointer, link_y = link.start_y }, false,
            G_reader_settings:isTrue("footnote_link_in_popup"))
    elseif action == "gesture" then
        local bounds = params.target == "body" and drawer.content.dimen
            or params.target == "header" and drawer.page_button.dimen or drawer.frame.dimen
        local pos = require("ui/geometry"):new{ x = bounds.x + bounds.w * (params.x_ratio or 0.5), y = bounds.y + bounds.h / 2 }
        if params.target ~= "body" and params.target ~= "header" then
            pos.y = bounds.y + math.floor(drawer.top_padding / 2)
        end
        if params.y_ratio then pos.y = bounds.y + bounds.h * params.y_ratio end
        if params.target == "outside" then pos.x, pos.y = 1, ui.dimen.h * 0.2 end
        drawer:handleEvent(require("ui/event"):new("Gesture", { ges = params.gesture or "tap",
            pos = pos, direction = params.direction, distance = params.distance, relative = params.relative }))
    elseif action == "page_action" then
        for _i, button in ipairs(browser and browser._zen_page_actions and browser._zen_page_actions.buttons or {}) do
            if button._zen_focus_id == "reference:" .. params.id then
                browser:onTap(nil, { pos = require("ui/geometry"):new{
                    x = button.dimen.x + button.dimen.w / 2, y = button.dimen.y + button.dimen.h / 2 } })
                break
            end
        end
    elseif action == "focus_action" then
        for y, row in ipairs(browser.layout or {}) do
            for x, button in ipairs(row) do
                if button._zen_focus_id == "reference:" .. params.id then browser:moveFocusTo(x, y) end
            end
        end
    elseif action == "key" then
        drawer:handleEvent(require("ui/event"):new("KeyPress", require("device/key"):new(params.key, {})))
    elseif action == "pin_button" then
        local dialog = ui.highlight.highlight_dialog or find_widget(function(widget)
            return widget.name == "DictQuickLookup"
        end)
        if params.lookup then dialog = find_widget(function(widget)
            return not widget.is_wiki and widget.word ~= nil and widget.button_table ~= nil
        end) end
        local found = false
        for _i, row in ipairs(dialog and (dialog.buttons or dialog.button_table and dialog.button_table.buttons) or {}) do
            for _j, button in ipairs(row) do
                if button.id == "zen_pin" then button.callback(); found = true; break end
            end
        end
        if not found then return { ok = false, error = "Pin section missing" } end
    elseif action == "resize" then
        ui.view:onSetRotationMode(params.mode)
    elseif action == "night" then
        ui:handleEvent(require("ui/event"):new("ToggleNightMode"))
    end
    state = ui._zen_references
    drawer = state and state.drawer
    browser = page_browser()
    local actions = {}
    for _i, button in ipairs(browser and browser._zen_page_actions and browser._zen_page_actions.buttons or {}) do
        actions[#actions + 1] = { id = button._zen_focus_id, text = button.text, bounds = button.dimen,
            border = button.bordersize, label_height = button.label_widget:getSize().h,
            icon = button.label_icon and button.label_icon.file,
            icon_first = button.label_container[1][1] == button.label_icon,
            content_width = button.label_container[1]:getSize().w }
    end
    local pin_label = ui.view.footer._zen_pin_label
    local pin_icon_bounds = ui.view.footer._zen_pin_dimen and pin_label and pin_label[1].dimen
    local pin_count_size = pin_label and pin_label[3]:getSize()
    local pin_label_size = pin_label and pin_label:getSize()
    local footer = ui.view.footer
    local function footer_item_bounds(mode)
        if not footer.settings[mode] then return end
        local label = require("apps/reader/modules/readerfooter").textGeneratorMap[mode](footer)
        local start = label and footer.footer_text.text:find(label, 1, true)
        if not start and label and footer.settings.item_prefix == "compact_items" then
            label = label:gsub("%s", "\u{200A}")
            start = footer.footer_text.text:find(label, 1, true)
        end
        if start then
            local text = require("ui/widget/textwidget"):new{
                text = footer.footer_text.text:sub(1, start - 1),
                face = footer.footer_text_face, bold = footer.settings.text_font_bold,
            }
            local prefix_width = text:getSize().w
            text:setText(label)
            local size = text:getSize()
            text:free()
            return { x = footer.text_container.dimen.x + footer.text_container.dimen.w
                - footer.footer_text:getSize().w + prefix_width,
                y = footer.text_container.dimen.y, w = size.w, h = size.h }
        end
    end
    local footer_page = footer_item_bounds("page_progress")
    local pin_popup_buttons = {}
    local image_viewer = find_widget(function(widget) return getmetatable(widget) == require("ui/widget/imageviewer") end)
    local html = drawer and drawer.htmlwidget
    local scroll_bar = html and {
        x = html.dimen.x + html[1]._offsets[3].x,
        y = html.v_scroll_bar.touch_dimen and html.v_scroll_bar.touch_dimen.y or html.dimen.y,
        w = html.v_scroll_bar.width, h = html.v_scroll_bar.height,
    }
    local pin_popup = find_widget(function(widget) return widget._zen_pin_menu end)
    for _i, row in ipairs(pin_popup and pin_popup.buttons or {}) do
        for _j, item in ipairs(row) do pin_popup_buttons[#pin_popup_buttons + 1] = item.text end
    end
    return { ok = true, references = {
        page = ui:getCurrentPage(), page_count = ui.document:getPageCount(),
        navigation_updates = navigation_updates, top_menu_open = top_menu_open,
        footer_left_margin = require("common/reader_status_bar").getHorizontalMargins(ui.document,
            footer.horizontal_margin, require("pluginloader"):getPluginInstance("zenos")),
        location = ui.rolling and ui.document:getXPointer() or nil,
        pin = References.pinnedPage(ui), history = #(ui.link.location_stack or {}),
        pins = References.pins(ui), pin_locations = References.pinLocations(ui),
        footer_visible = ui.view.footer_visible,
        footer_bounds = footer.footer_content.dimen,
        footer_order = footer.settings.order,
        footer_left_text = footer._zen_left_text and footer._zen_left_text.text,
        footer_label = footer.footer_text.text,
        footer_page_center = footer_page and footer_page.x + footer_page.w / 2,
        footer_percentage = footer_item_bounds("percentage"),
        footer_pinned_pages = footer.settings.pinned_pages,
        footer_bar_width = ui.view.footer.progress_bar.width,
        pin_footer = ui.view.footer._zen_pin_dimen,
        pin_icon = ui.view.footer._zen_pin_label and ui.view.footer._zen_pin_label[1].file,
        pin_icon_bounds = pin_icon_bounds,
        pin_count_bounds = pin_icon_bounds and {
            x = pin_icon_bounds.x + pin_icon_bounds.w + pin_label[2].width,
            y = ui.view.footer._zen_pin_dimen.y + math.floor((ui.view.footer._zen_pin_dimen.h - pin_label_size.h) / 2)
                + math.floor((pin_label_size.h - pin_count_size.h) / 2),
            w = pin_count_size.w, h = pin_count_size.h,
        },
        pin_label_left = ui.view.footer._zen_pin_dimen and ui.view.footer._zen_pin_dimen.x,
        footer_text = { x = ui.view.footer.text_container.dimen.x, y = ui.view.footer.text_container.dimen.y,
            w = ui.view.footer.footer_text:getSize().w, h = ui.view.footer.footer_text:getSize().h },
        footer_progress = ui.view.footer.progress_bar.dimen,
        pin_anchor = ui.doc_settings:readSetting("pinned_page"),
        requested_anchor = ui.rolling and ui.document:getPageXPointer(3) or nil,
        annotations = #ui.annotation.annotations, last_footnote = state and state.footnote ~= nil or false,
        image_menu = ui.highlight.highlight_dialog ~= nil and ui.highlight.highlight_dialog.name == "highlight_image_dialog",
        image_buttons = M.button_state(ui.highlight.highlight_dialog and ui.highlight.highlight_dialog.buttontable),
        image_viewer = image_viewer ~= nil,
        image_viewer_fullscreen = image_viewer and image_viewer.fullscreen,
        selected_text = ui.highlight.selected_text ~= nil,
        browser_open = browser ~= nil, actions = actions,
        divider = browser and browser._zen_preview_divider and browser._zen_preview_divider.overlap_offset,
        panel_height = browser and browser._zen_panel_h,
        preview_bounds = browser and browser._zen_grid_dimen,
        divider_bounds = browser and browser._zen_preview_divider and browser._zen_preview_divider.dimen,
        screen = { w = require("device").screen:getWidth(), h = require("device").screen:getHeight() },
        double_tap_disabled = require("device").input.disable_double_tap,
        popup_enabled = G_reader_settings:isTrue("footnote_link_in_popup"),
        book_font = G_reader_settings:isTrue("footnote_popup_use_book_font"),
        reader_font_size = require("device").screen:scaleBySize(ui.document.configurable.font_size),
        reader_font = ui.font and ui.font.font_face,
        header_left = ui.view._zen_header_slots and ui.view._zen_header_slots.left,
        header_right = ui.view._zen_header_slots and ui.view._zen_header_slots.right,
        header_bounds = ui.view._zen_header_dimen,
        header_pin = ui.view._zen_test_header_pin,
        dogear = ui.view.dogear_visible and ui.view.dogear.icon.dimen,
        pin_menu = find_widget(function(widget) return widget.title == "Pin" and widget.buttons end) ~= nil,
        pin_popup_buttons = pin_popup_buttons,
        return_button = ui._zen_return_button and {
            visible = ui._zen_return_button:isVisible(), bounds = ui._zen_return_button.dimen,
            icon_bounds = ui.view._zen_test_return_icon, text_bounds = ui.view._zen_test_return_text,
            text = ui._zen_return_button.text, duration = ui._zen_return_button.duration,
            timer = ui._zen_return_button.expire and tostring(ui._zen_return_button.expire),
        },
        drawer = drawer and { pin_index = drawer.pin_index, pager = drawer.pager and drawer.pager.dimen,
            dots_background = drawer.pager and drawer.pager.dots_dimen,
            control_radius = drawer.menu_button and drawer.menu_button.frame.radius,
            feedback_radius = require("common/ui/button_feedback").getRadius(),
            full_image = drawer.full_image or false,
            pager_left = drawer.pager and { icon = drawer.pager[1].file, bounds = drawer.pager[1].dimen },
            pager_right = drawer.pager and { icon = drawer.pager[3].file, bounds = drawer.pager[3].dimen },
            scroll_bar = scroll_bar,
            page_label = drawer.page_button and drawer.page_button.dimen,
            page_label_text = drawer.page_button and drawer.page_button.text,
            page_icon = drawer.page_button and drawer.page_button.label_container[1][1].file,
            page_icon_bounds = drawer.page_button and drawer.page_button.label_container[1][1].dimen,
            page_label_content_width = drawer.page_button and drawer.page_button.label_container[1]:getSize().w,
            page_icon_first = drawer.page_button and drawer.page_button.label_container[1][3] == drawer.page_button.label_widget,
            menu = drawer.menu_button and drawer.menu_button.dimen,
            menu_icon = drawer.menu_button and drawer.menu_button.label_widget.file,
            menu_icon_bounds = drawer.menu_button and drawer.menu_button.label_widget.dimen,
            zoom = drawer.zoom_button and drawer.zoom_button.dimen,
            zoom_icon = drawer.zoom_button and drawer.zoom_button.label_widget.file,
            zoom_icon_bounds = drawer.zoom_button and drawer.zoom_button.label_widget.dimen,
            zoom_in = drawer.zoom_in_button and drawer.zoom_in_button.dimen,
            zoom_in_icon = drawer.zoom_in_button and drawer.zoom_in_button.label_widget.file,
            zoom_in_icon_bounds = drawer.zoom_in_button and drawer.zoom_in_button.label_widget.dimen,
            zoom_out = drawer.zoom_out_button and drawer.zoom_out_button.dimen,
            zoom_out_icon = drawer.zoom_out_button and drawer.zoom_out_button.label_widget.file,
            zoom_out_icon_bounds = drawer.zoom_out_button and drawer.zoom_out_button.label_widget.dimen,
            close_icon = drawer.close_button and drawer.close_button.label_widget.file,
            close = drawer.close_button and drawer.close_button.dimen, page = drawer.page, footnote = drawer.footnote ~= nil,
            bounds = drawer.frame.dimen, content = drawer.content.dimen, scale = drawer.scale,
            image = drawer.htmlwidget == nil,
            original_image = drawer.preview and drawer.preview.original_image or false,
            source_size = drawer.preview and drawer.preview.bb and {
                w = drawer.preview.bb:getWidth(), h = drawer.preview.bb:getHeight(),
            },
            image_view = drawer.preview and not drawer.htmlwidget and drawer.content._bb and {
                w = drawer.content:getCurrentWidth(), h = drawer.content:getCurrentHeight(),
                x = drawer.content._offset_x, y = drawer.content._offset_y,
            },
            center = { x = drawer.content.center_x_ratio, y = drawer.content.center_y_ratio },
            border = drawer.frame.bordersize, paint_height = drawer.frame.height, grabber = drawer.grabber ~= nil,
            radius = drawer.frame.radius, css = drawer.htmlwidget and drawer.htmlwidget.css,
            font_size = drawer.htmlwidget and drawer.htmlwidget.default_font_size,
            background = { drawer.background:getR(), drawer.background:getG(), drawer.background:getB() },
            foreground = { drawer.foreground:getR(), drawer.foreground:getG(), drawer.foreground:getB() },
            ratio = drawer:getScrollRatio(), closed = drawer.closed } or nil,
    } }
end

return M
