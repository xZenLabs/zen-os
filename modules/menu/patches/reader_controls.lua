local Settings = require("modules/menu/reader_controls/settings")
local Buttons = require("modules/menu/reader_controls/buttons")
local Menus = require("modules/menu/reader_controls/menus")
local _ = require("gettext")

return function(plugin)
    plugin = plugin or rawget(_G, "__ZEN_UI_PLUGIN")
    if not plugin then return end
    local ReaderMenu = require("apps/reader/modules/readermenu")
    if ReaderMenu._zen_reader_controls then return end
    ReaderMenu._zen_reader_controls = true
    require("modules/menu/patches/touch_menu_panel").install(plugin)
    require("modules/menu/reader_controls/profiles").install(plugin)
    -- Theme selection can enable themes while a book is open.
    require("modules/reader/patches/reader_themes")()

    local Device = require("device")
    local Screen = Device.screen
    local UIManager = require("ui/uimanager")
    local Button = require("ui/widget/button")
    local CheckButton = require("ui/widget/checkbutton")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local Widget = require("ui/widget/widget")
    local Pager = require("common/ui/zen_pager")
    local util = require("util")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local RightContainer = require("ui/widget/container/rightcontainer")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local TextWidget = require("ui/widget/textwidget")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local LineWidget = require("ui/widget/linewidget")
    local Geom = require("ui/geometry")
    local BD = require("ui/bidi")
    local Blitbuffer = require("ffi/blitbuffer")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local ZenSlider = require("common/ui/zen_slider")
    local Accent = require("common/ui/accent")
    local ZenIconButton = require("common/ui/zen_icon_button")
    local ZenActionButton = require("common/ui/zen_action_button")
    local ZenTabBar = require("common/ui/zen_tab_bar")
    local StepButton = require("common/ui/slider_step_button")
    local utils = require("common/utils")
    local root = require("common/plugin_root")
    local icons_dir = root and root .. "/icons/"
    local thin_icons = icons_dir and icons_dir .. "reader_controls/"
    local stock_icons = require("libs/libkoreader-lfs").currentdir() .. "/resources/icons/mdlight/"

    local function reader()
        return require("apps/reader/readerui").instance
    end

    local function launch(tm, callback)
        tm:closeMenu()
        require("common/settings_transition").close()
        UIManager:nextTick(callback)
    end

    local function direct_action(tm, id)
        local ui = reader()
        launch(tm, function()
            if id == "toc" then
                UIManager:show(require("modules/reader/zen_toc_widget"):new{
                    ui = ui, show_back = false, on_goto = function(page)
                        if ui.link then ui.link:addCurrentLocationToStack() end
                        ui:handleEvent(require("ui/event"):new("GotoPage", page))
                    end,
                })
            elseif id == "search" then
                ui.search:onShowFulltextSearchInput()
            elseif id == "vocabulary" then
                ui:handleEvent(require("ui/event"):new("ShowVocabBuilder"))
            elseif id == "page_browser" then
                ui:handleEvent(require("ui/event"):new("ShowPageBrowser"))
            elseif id == "koreader_menu" then
                ui.config:onShowConfigMenu(true)
            elseif id == "bookmarks" then
                require("modules/reader/annotation_viewer").show(plugin, ui, "bookmarks")
            end
        end)
    end

    local function content(tm, state, ui, section)
        section = section or state.section
        local rows, options = {}, Settings.options(ui)
        local function action(text, callback, checked, hold)
            rows[#rows + 1] = { text = text, callback = callback, checked = checked, hold = hold }
        end
        local function chooser(items, name)
            local key, count = name .. "_page", 8
            local pages = math.max(1, math.ceil(#items / count))
            state[key] = math.max(1, math.min(pages, state[key] or 1))
            state[name .. "_pages"] = pages
            local function move(delta)
                state[key] = (state[key] - 1 + delta) % pages + 1
                tm:updateItems(1)
            end
            state[name .. "_move"] = pages > 1 and move or nil
            for start = (state[key] - 1) * count + 1, math.min(#items, state[key] * count), 2 do
                local pair = {}
                for index = start, math.min(start + 1, #items) do
                    local item = items[index]
                    pair[#pair + 1] = item
                end
                rows[#rows + 1] = { pair = pair, chooser = name }
            end
            if pages > 1 then
                rows[#rows + 1] = { pager = { page = state[key], pages = pages,
                    previous = function() move(-1) end, next = function() move(1) end } }
            end
        end
        local function changed(name, value)
            if tm.onReaderSettingChanged and tm._zen_panel_refs then
                -- Replace freed thumbnails before a button forces an immediate repaint.
                tm:onReaderSettingChanged(name, value)
            end
        end
        local function apply(name, value, preview)
            if name == "trim_page" and (value == 0 or value == 2) then
                launch(tm, function() Settings.apply(ui, name, value) end)
                return
            end
            Settings.apply(ui, name, value)
            changed(name, value)
            if not preview then
                UIManager:nextTick(function() if tm._zen_panel_refs then tm:updateItems(1) end end)
            end
        end
        local function option(name, slider, label_override)
            local opt = options[name]
            if not Settings.available(ui, opt) then return end
            local value = ui.document.configurable[name]
            local label = label_override or Settings.label(ui, opt)
            local function hold()
                local names = { name }
                if name == "t_page_margin" and Settings.syncedMargins(ui) then
                    names[2] = "b_page_margin"
                end
                Menus.defaults(ui, names)
            end
            local more = (opt.more_options or ({ font_size = true, font_base_weight = true,
                font_gamma = true, contrast = true, word_spacing = true, word_expansion = true })[name]) and function(widget)
                    require("modules/menu/reader_controls/details").show(ui, name, apply,
                        function() if tm._zen_panel_refs then tm:updateItems(1) end end, widget.dimen)
                end
            local spec = slider and Settings.slider(ui, name, tm._reader_controls_embedded and 7 or nil)
            if spec then
                rows[#rows + 1] = { slider = spec, text = label, name = name, apply = apply, changed = changed,
                    hold = name ~= "font_size" and hold or nil, more = more }
            elseif name == "visible_pages" then
                rows[#rows + 1] = { text = label, name = name, toggle = value == opt.values[2], hold = hold,
                    callback = function() apply(name, value == opt.values[2] and opt.values[1] or opt.values[2]) end }
            elseif opt.values then
                rows[#rows + 1] = { presets = opt, text = label, name = name, apply = apply, more = more, hold = hold }
            else
                action(label .. ": " .. Settings.valueText(ui, opt, value), function()
                    local items = {}
                    for _i, val in ipairs(opt.values or {}) do
                        local choice = val
                        items[#items + 1] = {
                            text = Settings.valueText(ui, opt, val),
                            callback = function(menu)
                                apply(name, choice)
                                menu:closeMenu()
                            end,
                        }
                    end
                    require("common/ui/zen_arrange_list").show{
                        title = label, item_table = items, menu_mode = true, allow_arrange = false,
                    }
                end, nil, hold)
                rows[#rows].name = name
            end
        end
        if section == "font" or section == "contrast" then
            if ui.font then
                action(ui.font.font_face, function(_menu, widget)
                    Menus.fontFamily(ui, widget.dimen, function()
                        changed("font_face", ui.font.font_face)
                        tm:updateItems(1)
                    end)
                end)
                rows[#rows].name, rows[#rows].title = "font_face", _("Font family")
                rows[#rows].more = function(widget)
                    require("modules/menu/reader_controls/details").show(ui, "font_face", apply,
                        function() if tm._zen_panel_refs then tm:updateItems(1) end end, widget.dimen)
                end
            end
            if Settings.group(ui) == "copt" then
                option("font_size", true)
                option("font_base_weight", true, _("Weight"))
                option("line_spacing", true)
                option("word_spacing")
                option("word_expansion")
                option("font_gamma", true)
                option("font_hinting")
                option("font_kerning")
                option("embedded_css")
                option("embedded_fonts")
            else
                option("contrast", true)
                option("white_threshold", true)
                option("saturation", true)
                option("hw_dithering")
                option("sw_dithering")
                -- Remaining night mode, reflow and injected options follow.
                local placed = { contrast = true, white_threshold = true, saturation = true, hw_dithering = true,
                    sw_dithering = true, page_opt = true, background_cleanup = true }
                local panel = Settings.panel(ui, "appbar.contrast")
                for _i, opt in ipairs(panel and panel.options or {}) do
                    if not placed[opt.name] then option(opt.name, opt.buttonprogress) end
                end
                option("nightmode_document")
                option("font_size", true)
            end
        elseif section == "page" then
            if Settings.group(ui) == "copt" then
                option("h_page_margins", true, _("Left/Right"))
                local synced = Settings.syncedMargins(ui)
                option("t_page_margin", true, synced and _("Top/Bottom") or _("Top"))
                if not synced then option("b_page_margin", true, _("Bottom")) end
                -- View mode and two columns merged: Page / Continuous / Two column.
                if Settings.available(ui, options.view_mode) then
                    local conf = ui.document.configurable
                    local columns = options.visible_pages ~= nil
                    rows[#rows + 1] = { text = Settings.label(ui, options.view_mode), name = "view_mode",
                        presets = { values = columns and { 1, 2, 3 } or { 1, 2 },
                            toggle = { _("Page"), _("Continuous"), _("Two column") } },
                        selected = conf.view_mode == 1 and 2 or columns and conf.visible_pages == 2 and 3 or 1,
                        hold = function() Menus.defaults(ui, columns and { "view_mode", "visible_pages" } or { "view_mode" }) end,
                        apply = function(_name, choice)
                            if choice == 2 or not columns then return apply("view_mode", choice == 2 and 1 or 0) end
                            if conf.view_mode == 1 then Settings.apply(ui, "view_mode", 0) end
                            apply("visible_pages", choice == 3 and 2 or 1)
                        end }
                end
                option("rakuyomi_view_mode")
            else
                option("page_margin", true)
                option("page_scroll")
                option("rakuyomi_view_mode")
                option("auto_straighten", false, _("Straighten"))
                option("line_spacing", true)
                option("max_columns")
            end
        elseif section == "document" then
            option("zoom_mode_genus")
            option("zoom_mode_type")
            option("trim_page", false, _("Crop"))
            option("page_opt")
            option("background_cleanup")
            for _i, name in ipairs({ "zoom_direction", "zoom_range_number", "zoom_factor" }) do
                option(name, name == "zoom_factor")
            end
            if Settings.available(ui, options.zoom_overlap_h) or Settings.available(ui, options.zoom_overlap_v) then
                rows[#rows + 1] = { heading = _("Overlap") }
                option("zoom_overlap_h", true, _("Horizontal"))
                option("zoom_overlap_v", true, _("Vertical"))
            end
        elseif section == "profiles" then
            action(_("Defaults"), function() Menus.defaults(ui) end)
            if ui.profiles then
                action(_("Include reader theme"), function() state.include_theme = not state.include_theme; tm:updateItems(1) end)
                rows[#rows].toggle = state.include_theme
                action(_("Save current reader settings"), function() Menus.saveProfile(ui, plugin, state.include_theme) end)
                local names = {}
                for name in pairs(ui.profiles.data) do names[#names + 1] = name end
                table.sort(names)
                for _i, name in ipairs(names) do
                    local profile_name = name
                    local snapshot = ui.profiles.data[name].settings and ui.profiles.data[name].settings.zen_reader
                    if not snapshot or snapshot.group == Settings.group(ui) then
                        action(name, function()
                            launch(tm, function() ui.profiles:onProfileExecute(profile_name, { qm_show = false }) end)
                        end, nil, function() Menus.profileMenu(ui, plugin, profile_name, state.include_theme) end)
                    end
                end
                action(_("Manage profiles"), function()
                    require("common/ui/zen_arrange_list").show{ title = _("Profiles"), menu_mode = true,
                        allow_arrange = false, item_table = ui.profiles:getSubMenuItems() }
                end)
            else
                action(_("Enable KOReader's Profiles plugin to save reader profiles."), function() end)
            end
        elseif section == "themes" then
            local themes = Menus.themeRows(ui, plugin, function()
                if tm._reader_controls_embedded then changed("reader_theme") end
                tm:updateItems(1)
            end)
            local settings = table.remove(themes)
            if not tm._reader_controls_embedded then rows[1] = settings end
            for _i, theme in ipairs(themes) do theme.theme_choice = true end
            if tm._reader_controls_embedded then
                for i = 1, #themes, 2 do rows[#rows + 1] = { pair = { themes[i], themes[i + 1] } } end
            else
                chooser(themes, "themes")
            end
        end
        return rows
    end

    local Dots = Widget:extend{}
    function Dots:paintTo(bb, x, y)
        Pager.paint(bb, x, y, self.dimen.w, self.dimen.h, self.page, self.pages, "dots", nil, self.dot_size)
    end

    local WidgetContainer = require("ui/widget/container/widgetcontainer")
    local SliderWidget = WidgetContainer:extend{}
    function SliderWidget:getSize() return self.slider:getSize() end
    function SliderWidget:paintTo(bb, x, y) self.slider:paintTo(bb, x, y) end
    local SliderRow = InputContainer:extend{}
    function SliderRow:propagateEvent(event)
        if event.handler == "onFocus" or event.handler == "onUnfocus" then return false end
        return InputContainer.propagateEvent(self, event)
    end
    function SliderRow:onFocus() self._focused = true; self[1].invert = true; UIManager:setDirty(nil, "ui", self.dimen); return true end
    function SliderRow:onUnfocus() self._focused = false; self[1].invert = false; UIManager:setDirty(nil, "ui", self.dimen); return true end
    function SliderRow:onKeyPress(key)
        if not self._focused then return false end
        local delta = key:match({ "Left" }) and -1 or key:match({ "Right" }) and 1
        if delta then
            self.step(delta)
            return true
        end
        return false
    end

    local function build_panel(tm)
        local ui = tm.ui or reader()
        if not ui then return VerticalGroup:new{} end
        local state = tm._reader_controls_state
        if not state then
            state = { page = 1, button_page = 1, include_theme = true }
            tm._reader_controls_state = state
        end
        local embedded = tm._reader_controls_embedded
        local w, pad = tm.item_width, Screen:scaleBySize(embedded and 12 or 8)
        local refs = { buttons = {}, sliders = {}, headings = {}, layout_rows = {}, swipe_zones = {},
            footer_top_margin = VerticalSpan:new{ width = 0 } }
        tm._zen_panel_refs = refs
        local panel = VerticalGroup:new{ align = "left" }
        local function track(widget, callback, hold, layout)
            refs.buttons[#refs.buttons + 1] = { widget = widget, callback = callback, hold_callback = hold }
            layout[#layout + 1] = widget
            return widget
        end
        local function control_icon(icon_name)
            local path = utils.resolveIcon(icons_dir, icon_name)
                or utils.resolveLocalIcon(icons_dir, icon_name)
                or utils.resolveLocalIcon(icons_dir, "lightning")
            -- Thin-stroke variant unless an icon pack/custom icon overrides the bundled one.
            if path and path == utils.resolveLocalIcon(icons_dir, icon_name) then
                path = utils.resolveLocalIcon(thin_icons, icon_name) or path
            end
            return path
        end
        local function icon_button(name, callback, layout, icon_size, button_size)
            local down = name == "chevron.down"
            local directory = name == "more_vertical" and icons_dir or stock_icons
            local icon_name = down and "chevron.up" or name
            icon_size = icon_size or Screen:scaleBySize(28)
            local widget
            local activate = function() callback(widget) end
            widget = ZenIconButton:new{
                file = utils.resolveIcon(directory, icon_name) or utils.resolveLocalIcon(directory, icon_name),
                icon_rotation_angle = down and 180 or nil,
                width = icon_size, height = icon_size,
                padding = ((button_size or Screen:scaleBySize(40)) - icon_size) / 2, callback = activate,
            }
            return track(widget, activate, nil, layout)
        end
        local function button(item, width, layout, label_width)
            local widget, button_widget
            local callback = function() if item.callback then item.callback(tm, button_widget) end end
            local font_pad = pad
            width = width - font_pad * 2
            local setting_title = not item.zen_button and item.title and TextWidget:new{
                text = item.title, face = Font:getFace("x_smallinfofont") }
            local title_width = setting_title and (label_width or setting_title:getSize().w) or 0
            if setting_title then setting_title:setMaxWidth(title_width) end
            local more = item.more and icon_button("more_vertical", item.more, {},
                setting_title and setting_title:getSize().h)
            if more then
                more._reader_setting = item.name .. "_more"
                width = width - more:getSize().w
            end
            if item.zen_button or item.name == "font_face" then
                local label = TextWidget:new{ text = item.text, face = Font:getFace("cfont", 18), bold = true }
                local button_width = math.min(width - (setting_title and title_width + pad or 0),
                    label:getSize().w + pad * 4)
                label:free()
                widget = ZenActionButton:new{ text = item.text, width = button_width, height = Screen:scaleBySize(40),
                    font_size = 18, callback = callback, outlined = item.name == "font_face" or item.outlined,
                    radius = item.name == "font_face" and Screen:scaleBySize(4) or nil }
            elseif item.radio then
                widget = CheckButton:new{ text = item.text, width = width, radio = true,
                    checked = item.checked, face = item.face or Font:getFace("x_smallinfofont"),
                    single_line = item.theme_choice, padding = 0, margin = 0,
                    callback = callback, parent = tm, show_parent = tm }
            else
                widget = Button:new{ text = (item.checked and "✓ " or "") .. item.text,
                    max_width = width - (setting_title and title_width + pad or 0),
                    height = Screen:scaleBySize(40),
                    text_font_face = state.section == "profiles" and "x_smallinfofont" or "cfont",
                    text_font_size = state.section == "profiles" and Font.sizemap.x_smallinfofont or 18,
                    align = "left",
                    text_font_bold = item.checked == true, bordersize = 0, padding = 0,
                    callback = callback, hold_callback = item.hold }
            end
            button_widget = widget
            if item.face and widget.label_widget then
                widget.label_widget:free()
                widget.label_widget.face = item.face
            end
            widget._reader_setting = item.name
            widget._reader_theme_choice = item.theme_choice == true
            track(widget, callback, item.hold, layout)
            if more then layout[#layout + 1] = more end
            if item.zen_button then
                local button_width = widget:getSize().w
                local title = item.title and TextWidget:new{ text = item.title,
                    face = Font:getFace("x_smallinfofont"), bold = true, max_width = width - button_width - pad }
                widget = HorizontalGroup:new{ align = "center",
                    LeftContainer:new{ dimen = Geom:new{ w = width - button_width, h = widget:getSize().h },
                        title or HorizontalSpan:new{ width = 0 } }, widget }
            elseif item.theme_choice then
                widget = LeftContainer:new{ dimen = Geom:new{ w = width, h = Screen:scaleBySize(40) }, widget }
            else
                local title = setting_title and (embedded and LeftContainer or RightContainer):new{
                    dimen = Geom:new{ w = title_width, h = widget:getSize().h }, setting_title }
                local right = RightContainer:new{ dimen = Geom:new{
                    w = width - title_width, h = widget:getSize().h }, widget }
                widget = title and HorizontalGroup:new{ align = "center", title, right } or right
            end
            if more then widget = HorizontalGroup:new{ align = "center", widget, more } end
            local pad_v = item.zen_button and pad / 2 or item.name == "font_face" and pad / 4 or 0
            return FrameContainer:new{ bordersize = 0, padding = 0, padding_left = pad, padding_right = pad,
                padding_top = pad_v, padding_bottom = pad_v, widget }
        end
        local entries = tm._reader_controls_embedded and {} or Buttons.visible(plugin.config, Settings.group(ui))
        local direct = { toc = true, bookmarks = true, search = true, vocabulary = true,
            page_browser = true, koreader_menu = true }
        local sections, first_section = {}
        for _i, entry in ipairs(entries) do
            if entry.type == "reader_control" and not direct[entry.control] then
                sections[entry.control] = true
                first_section = first_section or entry.control
            end
        end
        if not sections[state.section] and not tm._reader_controls_embedded then state.section = first_section end
        local header_widgets = {}
        if not tm._reader_controls_embedded then
            local show_chevrons = Buttons.ensure(plugin.config).show_page_chevrons
            local inner_w = w - pad * 2
            local cols = math.max(1, math.floor(inner_w / Screen:scaleBySize(64)))
            local arrows = show_chevrons and #entries > cols
            if arrows then cols = math.max(1, math.floor((inner_w - Screen:scaleBySize(112)) / Screen:scaleBySize(64))) end
            local pages = math.max(1, math.ceil(#entries / cols))
            state.button_page = math.max(1, math.min(state.button_page, pages))
            local function header_move(delta)
                state.button_page = (state.button_page - 1 + delta) % pages + 1
                tm:updateItems(1)
            end
            local icons, visible_entries, header_layout = {}, {}, {}
            if arrows then icons[1] = utils.resolveLocalIcon(stock_icons, "chevron.left") end
            for i = (state.button_page - 1) * cols + 1, math.min(#entries, state.button_page * cols) do
                local entry = entries[i]
                icons[#icons + 1] = control_icon(Buttons.icon(entry) or "lightning")
                visible_entries[#visible_entries + 1] = entry
            end
            if arrows then icons[#icons + 1] = utils.resolveLocalIcon(stock_icons, "chevron.right") end
            local tab_bar
            if #icons > 0 then
                tab_bar = getmetatable(tm.bar):new{
                    width = tm.width, icons = icons, show_parent = tm,
                    menu = { layout = {}, switchMenuTab = function() end },
                }
                local icon_group = tab_bar.bar_icon_group
                for i = #icon_group, 1, -1 do icon_group[i] = nil end
                tab_bar.icon_seps[#icons] = nil
                local separator_width = tab_bar.icon_seps[1] and tab_bar.icon_seps[1]:getSize().w or 0
                local available = tm.width - separator_width * (#icons - 1)
                for i, cell in ipairs(tab_bar.icon_widgets) do
                    local start = math.floor(available * (i - 1) / #icons)
                    local width = math.floor(available * i / #icons) - start
                    local padding = (width - cell.image:getSize().w) / 2
                    cell.padding_left, cell.padding_right = math.floor(padding), math.ceil(padding)
                    cell:update()
                    cell.horizontal_group:resetLayout()
                    cell.button:resetLayout()
                    icon_group[#icon_group + 1] = cell
                    if i < #icons then icon_group[#icon_group + 1] = tab_bar.icon_seps[i] end
                    start = start + separator_width * (i - 1)
                    cell.callback = function()
                        local x = BD.mirroredUILayout() and tm.width - start - width or start
                        tab_bar.bar_sep.empty_segments = {{ s = x, e = x + width }}
                        for j, separator in ipairs(tab_bar.icon_seps) do
                            separator.style = (j == i - 1 or j == i) and "solid" or "none"
                        end
                    end
                end
                icon_group:resetLayout()
                local group = tab_bar[1][1]
                -- Bottom tabs open into the panel above them.
                group[1], group[2] = group[2], group[1]
                group:resetLayout()
                tab_bar.bar_sep.empty_segments = nil
                for _i, separator in ipairs(tab_bar.icon_seps) do separator.style = "none" end
                refs.tab_bar = tab_bar
            end
            local function page_arrow(index, delta)
                local cell = tab_bar.icon_widgets[index]
                cell.callback = function() header_move(delta) end
                cell._reader_button_page = delta < 0 and "previous" or "next"
                track(cell, cell.callback, nil, header_layout)
            end
            if arrows then page_arrow(1, -1) end
            for i, entry in ipairs(visible_entries) do
                local cell = tab_bar.icon_widgets[i + (arrows and 1 or 0)]
                local select = cell.callback
                local function activate()
                    select()
                    if entry.type ~= "reader_control" then
                        require("modules/menu/app_launcher/entry_action")(entry, tm, plugin, "reader")
                    elseif direct[entry.control] then direct_action(tm, entry.control)
                    else state.section = entry.control; state.page = 1; tm:updateItems(1) end
                end
                if entry.control ~= nil and state.section == entry.control then select() end
                cell.callback, cell.text = activate, entry.label
                cell.dimen = cell.dimen or cell:getSize():copy()
                cell.image.dimen = cell.image.dimen or cell.image:getSize():copy()
                cell._reader_control_id = entry.control or entry.id
                track(cell, activate, nil, header_layout)
            end
            if arrows then page_arrow(#icons, 1) end
            for _i, widget in ipairs(header_layout) do header_widgets[widget] = true end
            refs.bottom_tabs = tab_bar or VerticalSpan:new{ width = 0 }
            refs.swipe_zones[#refs.swipe_zones + 1] = { widget = refs.bottom_tabs, move = header_move }
            refs.tab_layout = header_layout
            refs.button_page, refs.button_pages = state.button_page, pages
        end
        local height = math.min(tm.height or Screen:getHeight(), Screen:getHeight())
        local footer_padding = tm._reader_controls_embedded and (tm.padding_bottom or 0) or 0
        local function size(widget) return widget and widget:getSize().h or 0 end
        local section_layout, section_gap, pager_height = {}, 0, Screen:scaleBySize(40)
        if tm._reader_controls_embedded then
            local group = Settings.group(ui)
            refs.section_order = group == "copt" and { "font", "page", "themes" }
                or { "contrast", "page", "document" }
            if not util.arrayContains(refs.section_order, state.section) then state.section = refs.section_order[1] end
            state.section_pages = state.section_pages or {}
            refs.select_section = function(section)
                if section == state.section or not util.arrayContains(refs.section_order, section) then return end
                state.section_pages[state.section] = state.page
                state.section, state.page = section, state.section_pages[section] or 1
                tm:updateItems(1)
            end
            local names = { font = _("Font"), contrast = _("Contrast"),
                page = group == "copt" and _("Layout") or _("Page"), document = _("Document"), themes = _("Themes") }
            local items, selected = {}, 1
            for i, section in ipairs(refs.section_order) do
                if section == state.section then selected = i end
                items[i] = { text = names[section], callback = function() refs.select_section(section) end }
            end
            refs.section_tabs = ZenTabBar:new{ items = items, selected = selected,
                max_width = w - pad * 2, cell_height = Screen:scaleBySize(32), font_size = 18,
                padding_h = Screen:scaleBySize(8), focusable = true }
            for i, cell in ipairs(refs.section_tabs.cells) do
                cell._reader_section = refs.section_order[i]
                track(cell, cell.callback, nil, section_layout)
                header_widgets[cell] = true
            end
            section_gap, pager_height = Screen:scaleBySize(4), Screen:scaleBySize(32)
        end
        local settings_page = state.section ~= "themes" and state.section ~= "profiles"
            and state.section ~= "book_info" and state.section ~= "book_switcher"
        local budget = math.max(Screen:scaleBySize(70), height - size(refs.bottom_tabs) - size(tm.footer)
            - (embedded and pager_height + size(refs.section_tabs) + section_gap or settings_page and pager_height or 0)
            - footer_padding - size(refs.footer_top_margin) - panel:getSize().h)
        if state.section == "book_info" or state.section == "book_switcher" then
            local opts = {
                width = w, height = budget, config = plugin.config,
                launcher_config = require("modules/menu/app_launcher/model").ensure(), ui = ui,
                book_info = require("modules/menu/reader_controls/book_info").ensure(plugin.config),
                open_details = function()
                    launch(tm, function()
                        require("modules/reader/book_details").show(ui, { config = plugin.config, plugin = plugin })
                    end)
                end,
            }
            local details, detail_refs
            if state.section == "book_switcher" then
                opts.plugin = plugin
                opts.close = function() tm:closeMenu() end
                opts.refresh = function() tm:updateItems(1) end
                details, detail_refs = require("modules/menu/app_launcher/book_switcher_page").buildReader(opts)
            else
                opts.actions = {}
                for _i, id in ipairs({ "search", "bookmarks", "toc" }) do
                    opts.actions[#opts.actions + 1] = { id = id, icon = control_icon(Buttons.icon{
                        type = "reader_control", control = id }), callback = function() direct_action(tm, id) end }
                end
                details, detail_refs = require("modules/menu/reader_controls/book_info_card").build(opts)
            end
            panel[#panel + 1] = details
            for _i, ref in ipairs(detail_refs.buttons) do refs.buttons[#refs.buttons + 1] = ref end
            for _i, row in ipairs(detail_refs.layout_rows) do refs.layout_rows[#refs.layout_rows + 1] = row end
            refs.page, refs.page_num = 1, 1
            panel:resetLayout()
            return LeftContainer:new{ dimen = Geom:new{ w = w, h = panel:getSize().h }, panel }
        end
        local descriptors, widgets = content(tm, state, ui), {}
        local side, gap = embedded and Screen:scaleBySize(40) or StepButton.width, Screen:scaleBySize(4)
        local more_width, label_width, value_width = 0, 0, 0
        for _i, row in ipairs(descriptors) do
            if row.title or row.slider or row.presets or row.toggle ~= nil or state.section == "profiles" then
                row.label = TextWidget:new{ text = row.title or row.text .. (row.slider and not embedded and ": " or ""),
                    face = Font:getFace("x_smallinfofont") }
                local number_width = 0
                if row.slider then
                    local spec = row.slider
                    local text = Settings.valueText(ui, spec.option, ui.document.configurable[row.name])
                    row.number = TextWidget:new{ text = text, face = row.label.face }
                    number_width = row.number:getSize().w
                    local function measure(sample)
                        row.number:setText(sample)
                        number_width = math.max(number_width, row.number:getSize().w)
                    end
                    for _j, index in ipairs({ spec.value_min, spec.value_max, math.max(spec.value_min, spec.value_max - 1) }) do
                        measure(Settings.valueText(ui, spec.option, spec.decode(index)))
                    end
                    for _j, value in ipairs(spec.option.values or {}) do
                        local position = spec.position(value)
                        if position >= spec.value_min and position <= spec.value_max then
                            measure(Settings.valueText(ui, spec.option, value))
                        end
                    end
                    row.number:setText(text)
                    row.number_box = LeftContainer:new{ dimen = Geom:new{ w = number_width,
                        h = math.max(row.label:getSize().h, row.number:getSize().h) },
                        allow_mirroring = false, RightContainer:new{
                            dimen = Geom:new{ w = number_width, h = row.number:getSize().h },
                            allow_mirroring = false, row.number } }
                    value_width = math.max(value_width, number_width)
                end
                label_width = math.max(label_width, row.label:getSize().w + (embedded and 0 or number_width))
                if row.more then more_width = Screen:scaleBySize(40) end
                if not (row.slider or row.presets or row.toggle ~= nil) then
                    row.label:free()
                    row.label = nil
                end
            end
        end
        local value_space = embedded and value_width + gap or 0
        local available = w - pad * 3 - side * 2 - gap * 2 - more_width - value_space
        label_width = math.min(label_width, math.max(0, available - Screen:scaleBySize(90)))
        -- Long (translated) labels wrap instead of squeezing every control in the section.
        if embedded then label_width = math.min(label_width, math.floor((w - pad * 2) / 3)) end
        local slider_width = available - label_width
        local controls_width = slider_width + side * 2 + gap * 2
        local step_insets = {}
        for i, text in ipairs({ "−", "＋" }) do
            local step = StepButton:new{ text = text, width = side }
            local inset = (step:getSize().w - step.label_widget:getSize().w) / 2
            step_insets[i] = i == 1 and math.floor(inset) or math.ceil(inset)
            step:free()
        end
        local function setting_row(row, controls, layout, fill)
            local label = row.label
            if embedded then
                local line_h = label:getSize().h
                if label:getSize().w > label_width then
                    local text, face = label.text, label.face
                    label:free()
                    label = TextBoxWidget:new{ text = text, face = face, width = label_width }
                    row.label = label
                end
                local row_height = math.max(Screen:scaleBySize(40), controls:getSize().h, label:getSize().h)
                local title = LeftContainer:new{ dimen = Geom:new{ w = label_width, h = row_height }, label }
                local line = HorizontalGroup:new{ align = "center", title,
                    HorizontalSpan:new{ width = pad }, controls }
                -- fill: controls already span the value/more columns.
                if value_space > 0 and not fill then
                    line[#line + 1] = HorizontalSpan:new{ width = gap }
                    if row.number_box then
                        row.number_box.dimen.w = value_width
                        row.number_box[1].dimen.w = value_width
                        line[#line + 1] = row.number_box
                    else
                        line[#line + 1] = HorizontalSpan:new{ width = value_width }
                    end
                end
                if more_width > 0 and (row.more or not fill) then
                    line[#line + 1] = row.more and icon_button("more_vertical", row.more, layout,
                        line_h) or HorizontalSpan:new{ width = more_width }
                    if row.more then layout[#layout]._reader_setting = row.name .. "_more" end
                end
                return FrameContainer:new{ bordersize = 0, padding = 0,
                    padding_left = pad, padding_right = pad, line }, title
            end
            local number_width = row.number_box and row.number_box:getSize().w or 0
            local inline = label:getSize().w + number_width <= label_width
            label:setMaxWidth((inline and label_width or w - pad * 2) - number_width)
            local label_group = row.number_box and HorizontalGroup:new{ label, row.number_box } or label
            local title = RightContainer:new{ dimen = Geom:new{ w = inline and label_width or w - pad * 2,
                h = math.max(label_group:getSize().h, controls:getSize().h) }, label_group }
            local line
            if inline then
                line = HorizontalGroup:new{ align = "center", title, HorizontalSpan:new{ width = pad }, controls }
            else
                line = VerticalGroup:new{ align = "left", title,
                    RightContainer:new{ dimen = Geom:new{ w = w - pad * 2, h = controls:getSize().h }, controls } }
            end
            return FrameContainer:new{ bordersize = 0, padding = 0, padding_left = pad, padding_right = pad,
                padding_top = row.slider and 0 or pad, padding_bottom = row.slider and 0 or pad, line }, title
        end
        local function tab_row(row, items, selected, layout, icons)
            local fill = embedded and value_space + (row.more and 0 or more_width) or 0
            local selection = ZenTabBar:new{ items = items, selected = selected,
                width = controls_width - step_insets[1] - step_insets[2] + fill,
                icon_size = Screen:scaleBySize(32), font_size = 16, padding_h = Screen:scaleBySize(4),
                cell_height = Screen:scaleBySize(embedded and 36 or (icons and 48 or 32)), focusable = true }
            for i, cell in ipairs(selection.cells) do
                cell._reader_setting = (row.name or row.text) .. "_" .. i
                track(cell, cell.callback, row.hold, layout)
            end
            local controls = HorizontalGroup:new{ HorizontalSpan:new{ width = step_insets[1] }, selection,
                HorizontalSpan:new{ width = step_insets[2] } }
            if row.more and not embedded then
                controls[#controls + 1] = icon_button("more_vertical", row.more, layout, row.label:getSize().h)
                layout[#layout]._reader_setting = row.name .. "_more"
            elseif more_width > 0 and not embedded then
                controls[#controls + 1] = HorizontalSpan:new{ width = more_width }
            end
            return setting_row(row, controls, layout, embedded)
        end
        for _i, row in ipairs(descriptors) do
            local layout, widget = {}
            if row.slider then
                local spec = row.slider
                local label = row.label
                local slider = ZenSlider:new{ width = slider_width, value = spec.value,
                    value_min = spec.value_min, value_max = spec.value_max, default_value = spec.default_value,
                    fractional_value = true }
                local last, pending, dragging = slider:getValue(), false, false
                local function commit(preview)
                    if slider:getValue() == last then return end
                    last = slider:getValue()
                    if preview and slider._dragging then
                        local value = spec.decode(last)
                        Settings.preview(ui, row.name, value)
                        row.changed(row.name, value)
                    else
                        row.apply(row.name, spec.decode(last), preview)
                    end
                end
                local function preview()
                    pending = false
                    commit(true)
                end
                local function cancel()
                    UIManager:unschedule(preview)
                    pending = false
                end
                local function advance_step(delta)
                    local current = ui.document.configurable[row.name]
                    local value = spec.advance(current, delta)
                    if type(value) == "table" and util.tableEquals(value, current) or value == current then return end
                    row.apply(row.name, value)
                end
                slider.on_drag_start = function() dragging = true end
                slider.on_change = function(value)
                    row.number:setText(Settings.valueText(ui, spec.option, spec.decode(value)))
                    if slider._dragging then
                        dragging = true
                        slider.hide_knob = false
                        if widget and widget.dimen then
                            slider:paintTo(Screen.bb, slider.dimen.x, slider.dimen.y)
                            local cell = row.number_box.dimen
                            Screen.bb:paintRect(cell.x, cell.y, cell.w, cell.h, Blitbuffer.COLOR_WHITE)
                            row.number_box:paintTo(Screen.bb, cell.x, cell.y)
                            if widget._focused then
                                Screen.bb:invertRect(slider.dimen.x, slider.dimen.y, slider.dimen.w, slider.dimen.h)
                                Screen.bb:invertRect(cell.x, cell.y, cell.w, cell.h)
                            end
                            local colored = Accent.isEnabled(plugin.config)
                            UIManager:setDirty(nil, colored and "ui" or "fast", slider:dirtyDimen():combine(cell), colored)
                        end
                        if not pending then
                            pending = true
                            -- CRE previews re-layout the book; throttle them harder than paged docs.
                            UIManager:scheduleIn(ui.rolling and 0.5 or 0.15, preview)
                        end
                    else
                        UIManager:setDirty(tm, "ui", widget and widget.dimen or slider.dimen)
                        commit(dragging)
                    end
                end
                slider.on_drag_end = function()
                    cancel()
                    commit(true)
                    dragging = false
                    UIManager:nextTick(function() if tm._zen_panel_refs == refs then tm:updateItems(1) end end)
                end
                local track_row = HorizontalGroup:new{}
                for _step, delta in ipairs({ -1, 1 }) do
                    local step = StepButton:new{ text = delta < 0 and "−" or "＋", width = side, height = slider:getSize().h,
                        padding_v = embedded and 0 or nil,
                        show_parent = tm,
                        callback = function() advance_step(delta) end }
                    step._reader_setting = row.name .. (delta < 0 and "_decrease" or "_increase")
                    track(step, step.callback, nil, layout)
                    track_row[#track_row + 1] = step
                    if delta < 0 then
                        track_row[#track_row + 1] = HorizontalSpan:new{ width = gap }
                        track_row[#track_row + 1] = SliderWidget:new{ slider = slider }
                        track_row[#track_row + 1] = HorizontalSpan:new{ width = gap }
                    end
                end
                if row.more and not embedded then
                    track_row[#track_row + 1] = icon_button("more_vertical", row.more, layout, label:getSize().h)
                    layout[#layout]._reader_setting = row.name .. "_more"
                elseif more_width > 0 and not embedded then
                    track_row[#track_row + 1] = HorizontalSpan:new{ width = more_width }
                end
                local wrapper, label_box = setting_row(row, track_row, layout)
                widget = SliderRow:new{ slider = slider, step = advance_step, _reader_setting = row.name,
                    label = row.label, label_box = label_box, number = row.number, number_box = row.number_box, wrapper }
                track(widget, nil, row.hold, layout)
                refs.sliders[#refs.sliders + 1] = { slider = slider, cancel = cancel }
            elseif row.presets then
                local items, selected = {}, nil
                for i, value in ipairs(row.presets.values) do
                    local current = ui.document.configurable[row.name]
                    if type(value) == "table" and util.tableEquals(value, current) or value == current then selected = i end
                    local icon = row.presets.item_icons and row.presets.item_icons[i]
                    items[i] = { text = (row.presets.toggle or row.presets.labels or {})[i]
                            or Settings.valueText(ui, row.presets, value),
                        icon = icon and (utils.resolveIcon(stock_icons, icon) or utils.resolveLocalIcon(stock_icons, icon)),
                        callback = function() row.apply(row.name, value) end }
                end
                widget = tab_row(row, items, row.selected or selected, layout, row.presets.item_icons ~= nil)
            elseif row.toggle ~= nil then
                local items = {}
                for i, text in ipairs({ _("Off"), _("On") }) do
                    local on = i == 2
                    items[i] = { text = text, callback = function() if on ~= row.toggle then row.callback() end end }
                end
                widget = tab_row(row, items, row.toggle and 2 or 1, layout)
            elseif row.pager then
                local pager = row.pager
                local previous = icon_button("chevron.left", pager.previous, layout)
                local next_button = icon_button("chevron.right", pager.next, layout)
                widget = HorizontalGroup:new{
                    previous,
                    Dots:new{ dimen = Geom:new{ w = w - previous:getSize().w - next_button:getSize().w,
                        h = Screen:scaleBySize(40) }, page = pager.page, pages = pager.pages },
                    next_button,
                }
            elseif row.heading then
                widget = FrameContainer:new{ bordersize = 0, padding = 0, padding_left = pad, padding_right = pad,
                    padding_top = pad / 2, padding_bottom = pad / 2,
                    TextWidget:new{ text = row.heading, face = Font:getFace("x_smallinfofont"), bold = true } }
                refs.headings[row.heading] = widget
            elseif row.pair then
                widget = HorizontalGroup:new{}
                for _j, item in ipairs(row.pair) do widget[#widget + 1] = button(item, math.floor(w / 2), layout) end
                if row.chooser then
                    widget = InputContainer:new{ widget }
                    refs.swipe_zones[#refs.swipe_zones + 1] = { widget = widget,
                        move = function(delta)
                            local move = state[row.chooser .. "_move"]
                            if move then move(delta) end
                        end }
                end
            else widget = button(row, state.section == "profiles" and label_width + pad * 2 or w, layout, label_width) end
            widgets[#widgets + 1] = { widget = widget, layout = layout, height = widget:getSize().h }
        end
        local divider_h = Screen:scaleBySize(1)
        local divider_padding = tm._reader_controls_embedded and Screen:scaleBySize(1.5) or 0
        local body_pages, used = { {} }, 0
        for _i, item in ipairs(widgets) do
            -- Divider padding is respread below, so only the line counts toward fit.
            if used > 0 and (settings_page and #body_pages[#body_pages] == 3
                    or used + divider_h + item.height > budget) then
                body_pages[#body_pages + 1] = {}; used = 0
            end
            local page = body_pages[#body_pages]
            page[#page + 1] = item
            used = used + (used > 0 and divider_h or 0) + item.height
        end
        state.page = math.max(1, math.min(state.page, #body_pages))
        local visible_items = body_pages[state.page]
        if embedded and #visible_items > 0 then
            -- Spread rows into spare pager space without changing pagination.
            local spare = budget - #visible_items * divider_h
            for _i, item in ipairs(visible_items) do spare = spare - item.height end
            divider_padding = math.max(0, math.min(divider_padding + Screen:scaleBySize(2),
                math.floor(spare / (#visible_items * 2 - 1))))
        end
        -- Only painted controls participate in gesture hit testing.
        for page_index, page_items in ipairs(body_pages) do
            if page_index ~= state.page then
                for _i, item in ipairs(page_items) do item.widget:free() end
            end
        end
        panel:resetLayout()
        if embedded then
            panel[#panel + 1] = VerticalSpan:new{ width = divider_h + divider_padding }
        end
        local visible = {}
        for _i, item in ipairs(visible_items) do
            if divider_h > 0 and _i > 1 then
                panel[#panel + 1] = FrameContainer:new{ bordersize = 0, padding = 0,
                    padding_top = divider_padding, padding_bottom = divider_padding,
                    LineWidget:new{ dimen = Geom:new{ w = w, h = divider_h },
                        background = Blitbuffer.COLOR_LIGHT_GRAY } }
            end
            panel[#panel + 1] = item.widget
            refs.layout_rows[#refs.layout_rows + 1] = item.layout
            for _j, widget in ipairs(item.layout) do visible[widget] = true end
        end
        for i = #refs.buttons, 1, -1 do
            local item = refs.buttons[i]
            if not header_widgets[item.widget] and not visible[item.widget] then table.remove(refs.buttons, i) end
        end
        for i = #refs.sliders, 1, -1 do
            local found = false
            for widget in pairs(visible) do if widget.slider == refs.sliders[i].slider then found = true; break end end
            if not found then table.remove(refs.sliders, i) end
        end
        refs.page, refs.page_num = state.page, #body_pages
        refs.goto_page = function(page)
            state.page = (page - 1) % #body_pages + 1
            tm:updateItems(1)
        end
        local pager_layout = {}
        if #body_pages > 1 then
            local previous = icon_button("chevron.left", function() refs.goto_page(state.page - 1) end,
                pager_layout, Screen:scaleBySize(28), pager_height)
            local next_button = icon_button("chevron.right", function() refs.goto_page(state.page + 1) end,
                pager_layout, Screen:scaleBySize(28), pager_height)
            refs.pager = LeftContainer:new{ dimen = Geom:new{ w = w, h = pager_height },
                HorizontalGroup:new{ HorizontalSpan:new{ width = pad }, previous,
                    Dots:new{ dimen = Geom:new{ w = w - pad * 2 - previous:getSize().w - next_button:getSize().w,
                        h = pager_height }, page = state.page, pages = #body_pages,
                        dot_size = Screen:scaleBySize(8) }, next_button, HorizontalSpan:new{ width = pad } } }
        end
        if tm._reader_controls_embedded then
            panel:resetLayout()
            panel[#panel + 1] = VerticalSpan:new{
                width = math.max(0, height - footer_padding - size(refs.pager)
                    - refs.section_tabs:getSize().h - section_gap - panel:getSize().h),
            }
            if refs.pager then panel[#panel + 1] = refs.pager end
            panel[#panel + 1] = VerticalSpan:new{ width = section_gap }
            panel[#panel + 1] = CenterContainer:new{ dimen = Geom:new{ w = w, h = refs.section_tabs:getSize().h },
                refs.section_tabs }
            panel[#panel + 1] = VerticalSpan:new{ width = footer_padding }
            refs.layout_rows[#refs.layout_rows + 1] = pager_layout
            refs.layout_rows[#refs.layout_rows + 1] = section_layout
        elseif refs.pager then
            panel[#panel + 1] = refs.pager
            refs.layout_rows[#refs.layout_rows + 1] = pager_layout
        end
        for i = #refs.swipe_zones, 2, -1 do
            local painted = false
            for _j, item in ipairs(body_pages[state.page]) do
                if item.widget == refs.swipe_zones[i].widget then painted = true; break end
            end
            if not painted then table.remove(refs.swipe_zones, i) end
        end
        panel:resetLayout()
        return LeftContainer:new{ dimen = Geom:new{ w = w, h = panel:getSize().h }, panel }
    end

    local FocusManager = require("ui/widget/focusmanager")
    local GestureRange = require("ui/gesturerange")
    local PanelGestures = require("modules/menu/patches/touch_menu_panel")
    local EmbeddedPanel = FocusManager:extend{ _reader_controls_embedded = true }
    function EmbeddedPanel:init()
        self.item_width = self.width
        self.dimen = Geom:new{ w = self.width, h = self.height }
        self.ges_events = {}
        for name, gesture in pairs({ Tap = "tap", Hold = "hold", Swipe = "swipe", Pan = "pan",
                PanRelease = "pan_release", MultiSwipe = "multiswipe" }) do
            self.ges_events[name] = { GestureRange:new{ ges = gesture, range = self.dimen } }
        end
        self:updateItems()
    end
    function EmbeddedPanel:updateItems()
        for _i, ref in ipairs(self._zen_panel_refs and self._zen_panel_refs.sliders or {}) do ref.cancel() end
        local previous = self[1]
        if previous then previous:free() end
        self[1] = build_panel(self)
        self.layout = {}
        for _i, row in ipairs(self._zen_panel_refs.layout_rows) do
            if #row > 0 then self.layout[#self.layout + 1] = row end
        end
        self.dimen.h = self[1]:getSize().h
        if previous then
            -- Panel region only; a height change relayouts the parent via on_layout_changed.
            UIManager:setDirty(self.show_parent or self, "ui", self.dimen.x and self.dimen or nil)
            if self.on_layout_changed then self.on_layout_changed() end
        end
    end
    function EmbeddedPanel:onReaderSettingChanged(name, value)
        if self.on_change then self.on_change(name, value) end
    end
    function EmbeddedPanel:onTap(_arg, gesture)
        return PanelGestures.handlePanelGesture(self, gesture, false)
    end
    function EmbeddedPanel:onHold(_arg, gesture)
        if not gesture then return FocusManager.onHold(self) end
        return PanelGestures.handlePanelGesture(self, gesture, true)
    end
    function EmbeddedPanel:onSwipe(_arg, gesture)
        if not self.dimen:contains(gesture.pos) then return end
        for _i, ref in ipairs(self._zen_panel_refs.sliders) do
            if ref.slider:handleSwipe(gesture, self.show_parent, self.dimen) then return true end
        end
        local delta = gesture.direction == "west" and 1 or gesture.direction == "east" and -1
        if delta then self._zen_panel_refs.goto_page(self._zen_panel_refs.page + delta) end
        return true
    end
    function EmbeddedPanel:onPan(_arg, gesture)
        for _i, ref in ipairs(self._zen_panel_refs.sliders) do
            if ref.slider:handlePan(gesture) then return true end
        end
    end
    function EmbeddedPanel:onPanRelease(_arg, gesture)
        for _i, ref in ipairs(self._zen_panel_refs.sliders) do
            if ref.slider:handlePanRelease(gesture, self.show_parent, self.dimen) then return true end
        end
    end
    function EmbeddedPanel:onMultiSwipe(_arg, gesture)
        for _i, ref in ipairs(self._zen_panel_refs.sliders) do
            if ref.slider:handleMultiSwipe(gesture, self.show_parent, self.dimen) then return true end
        end
        return true
    end
    function EmbeddedPanel:closeMenu()
        if self.close_callback then self.close_callback() end
    end
    function EmbeddedPanel:free()
        for _i, ref in ipairs(self._zen_panel_refs and self._zen_panel_refs.sliders or {}) do ref.cancel() end
        self._zen_panel_refs = nil
        FocusManager.free(self)
    end
    function ReaderMenu:createZenReaderControlsPanel(options)
        options._reader_controls_state = options.state
        return EmbeddedPanel:new(options)
    end

    local TouchMenu = require("ui/widget/touchmenu")
    local paint = TouchMenu.paintTo
    function TouchMenu:paintTo(bb, x, y)
        if self.item_table and self.item_table.id == "reader_controls" then
            y = y + Screen:getHeight() - self.dimen.h
        end
        return paint(self, bb, x, y)
    end
    local on_swipe = TouchMenu.onSwipe
    function TouchMenu:onSwipe(arg, gesture)
        if self.item_table and self.item_table.id == "reader_controls" then
            if gesture.direction == "south" then
                if not self._zen_panel_locked then self:closeMenu() end
                return true
            elseif gesture.direction == "north" then
                return true
            end
            local delta = gesture.direction == "west" and 1 or gesture.direction == "east" and -1
            if delta then
                for _i, zone in ipairs(self._zen_panel_refs and self._zen_panel_refs.swipe_zones or {}) do
                    if zone.widget.dimen and gesture.pos:intersectWith(zone.widget.dimen) then
                        if not self._zen_panel_locked then zone.move(delta) end
                        return true
                    end
                end
                for _i, ref in ipairs(self._zen_panel_refs and self._zen_panel_refs.sliders or {}) do
                    if ref.slider._dragging or ref.slider:hitTest(gesture.pos) then
                        return on_swipe(self, arg, gesture)
                    end
                end
                local refs = self._zen_panel_refs
                if not self._zen_panel_locked and refs and refs.goto_page then
                    refs.goto_page(refs.page + delta)
                end
                return true
            end
        end
        return on_swipe(self, arg, gesture)
    end
    function ReaderMenu:onShowReaderControls()
        if self.menu_container then self:onCloseReaderMenu() end
        if self.ui.keyselection then self.ui.keyselection:stopHighlightIndicator(true) end
        self.ui:handleEvent(require("ui/event"):new("CloseConfigMenu"))
        local container = CenterContainer:new{ show_parent = self.ui, ignore = "height", dimen = Screen:getSize() }
        local menu = TouchMenu:new{
            width = Screen:getWidth(), show_parent = container,
            tab_item_table = {{ id = "reader_controls", panel = build_panel, remember = false,
                icon = utils.resolveLocalIcon(icons_dir, "font") }},
        }
        -- Closing the bottom menu must preserve the top menu's remembered tab.
        menu.last_index = self.last_tab_index
        menu.close_callback = function() self:onCloseReaderMenu() end
        container[1] = menu
        self.menu_container = container
        UIManager:show(container)
        return true
    end
    local set_dimensions = ReaderMenu.onSetDimensions
    function ReaderMenu:onSetDimensions(dimen)
        if self.menu_container and self.menu_container[1].item_table.id == "reader_controls" then
            self:onShowReaderControls()
            self:initGesListener()
            return
        end
        return set_dimensions(self, dimen)
    end
end
