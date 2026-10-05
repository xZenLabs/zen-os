local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local TopContainer = require("ui/widget/container/topcontainer")
local UIManager = require("ui/uimanager")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local IconButton = require("common/ui/zen_icon_button")
local SharedState = require("common/shared_state")
local ClockTimer = require("common/clock_timer")
local WidgetResources = require("common/widget_resources")
local utils = require("common/utils")
local Data = require("modules/reader/end_book_data")
local Registry = require("modules/filebrowser/patches/home/components/registry")
local _ = require("gettext")

local EndBook = FocusManager:extend{ name = "zen_end_book", covers_fullscreen = true }
local WIDGETS = { stats_triplet = true, featured = true, quotes = true, strip = true }
local _icons_dir = require("common/plugin_root") .. "/icons/"
local _stock_icons_dir = require("libs/libkoreader-lfs").currentdir() .. "/resources/icons/mdlight/"

local function resolve_icon(name)
    if type(name) == "string" and name:sub(1, 1) == "/" then return name end
    local pack_dir = require("common/icon_packs").getActivePackDirectory()
    return utils.resolveLocalIcon(pack_dir and pack_dir .. "/", name)
        or utils.resolveLocalIcon(_icons_dir, name)
        or utils.resolveLocalIcon(utils.getUserIconsDir(), name)
        or utils.resolveLocalIcon(_stock_icons_dir, name)
end

function EndBook:init()
    self.top_menu = self.ui and self.ui.menu
        or require("apps/filemanager/filemanager").instance.menu
    self.data = Data.new(self.ui, self.plugin,
        self.plugin.config.end_book, function() self:rebuild() end, function() self:onClose() end)
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.Library = { { Device.input.group.PgFwd } }
        self.key_events.PreviousQuote = { { Device.input.group.PgBack } }
        self.key_events.Menu = { { "Menu" } }
    end
    self:rebuild()
    self._zen_status_clock_bound = true
    ClockTimer.bind(self, function(page)
        if UIManager:getTopmostVisibleWidget() == page then page:_zen_status_refresh() end
    end)
end

function EndBook:onPreviousQuote()
    self.data:prevQuote()
    return true
end

function EndBook:onSetDimensions()
    self:rebuild()
    return true
end

function EndBook:leave(options)
    local ui, plugin = self.ui, self.plugin
    if ui and options.target_tab == "books"
            and require("common/library_navigation").restoreEnabled(plugin) then
        options = {}
    end
    self:onClose()
    UIManager:nextTick(function()
        if ui then
            require("common/library_navigation").showFromReader(ui, plugin, options)
        elseif options.force_default then
            _G.__ZEN_UI_NAVBAR_OPEN_DEFAULT_TAB()
        else
            _G.__ZEN_UI_NAVBAR_OPEN_TAB(options.open_home and "home" or options.target_tab)
        end
    end)
end

function EndBook:onLibrary()
    self:leave({ target_tab = "books" })
    return true
end

function EndBook:openBook(path)
    if self.preview or path == self.data.file then return self:showCover(path) end
    local ui = self.ui
    self:onClose()
    UIManager:nextTick(function()
        require("apps/filemanager/filemanagerutil").openFile(ui, path)
    end)
end

function EndBook:showCover(path)
    local book = path and path ~= self.data.file and self.data:getBook(path) or self.data:getFeaturedBook()
    if not book then return true end
    if not book.cover_bb then return true end
    local viewer = require("ui/widget/imageviewer"):new{
        image = book.cover_bb, image_disposable = true, fullscreen = true, with_title_bar = false,
    }
    viewer.onTap = function(image_viewer) image_viewer:onClose(); return true end
    UIManager:show(viewer)
    return true
end

function EndBook:refreshBookMenu(path)
    if self.closed then return end
    local home = SharedState.get(self.plugin, "home")
    home.invalidateBookCache(path or self._book_menu_path)
    home.invalidateLibraryCache()
    self.data:invalidateRecommendations()
    self:rebuild()
end

function EndBook:showBookMenu(path, source)
    local FileManager = require("apps/filemanager/filemanager")
    if not self._book_menu_owner then
        local ui = self.ui or FileManager.instance
        local refresh = function() self:refreshBookMenu() end
        self._book_menu_owner = setmetatable({
            bookinfo = ui.bookinfo, document = ui.document,
            file_chooser = { refreshPath = refresh, updateItems = refresh },
            onRefresh = refresh,
        }, { __index = FileManager })
        self._book_menu_owner:setupZenContextMenu()
    end
    self._book_menu_path = path
    local chooser = self._book_menu_owner.file_chooser
    chooser.path = require("ffi/util").dirname(path)
    local collection
    if source == "to_be_read" then
        local index = require("common/tbr_index")
        if index.isExplicit(path) then collection = index.collectionName() end
    end
    local refresh = function() self:refreshBookMenu(path) end
    return chooser:showFileDialog{
        path = path, is_file = true, _zen_home_context = true, _zen_disable_select = true,
        _zen_hide_edit = true,
        _zen_is_history = source == "recently_read", _zen_collection_name = collection,
        _zen_after_status_change = refresh,
        _zen_collection_refresh = refresh,
        _zen_after_history_change = refresh,
        _zen_widget_settings = self.plugin.config.end_book.edit_mode ~= false and function()
            return require("modules/settings/sections/end_book_settings").openWidgetSettings("strip", self.plugin)
        end or nil,
    }
end

function EndBook:onMenu()
    self.top_menu:onShowMenu()
    return true
end

function EndBook:onMenuTap(_arg, gesture)
    if self.top_menu.activation_menu == "swipe" then return end
    self.top_menu:onShowMenu(self.top_menu:_getTabIndexFromLocation(gesture))
    return true
end

function EndBook:onMenuSwipe(_arg, gesture)
    if gesture.direction ~= "south" or self.top_menu.activation_menu == "tap" then return end
    self.top_menu:onShowMenu(self.top_menu:_getTabIndexFromLocation(gesture))
    return true
end

function EndBook:handleEvent(event)
    if event.handler == "onGesture" and event.args[1].ges ~= "hold"
            and self:onGesture(event.args[1]) then return true end
    return FocusManager.handleEvent(self, event)
end

function EndBook:onHoldWidgetSettings(_arg, gesture)
    if self.plugin.config.end_book.edit_mode == false or not (gesture and gesture.pos) then return false end
    for _i, row in ipairs(self.widget_rows) do
        if row.dimen:contains(gesture.pos) then
            return require("modules/settings/sections/end_book_settings").openWidgetSettings(row.id, self.plugin)
        end
    end
    return false
end

function EndBook:prepareFocusTarget(target, widget)
    local frame = FrameContainer:new{
        width = target.width, height = target.height, padding = 0, bordersize = 0, widget,
    }
    frame.onFocus = function(focused) focused.invert = true; return true end
    frame.onUnfocus = function(focused) focused.invert = false; return true end
    frame.onGesture = function(focused, gesture)
        if Device:isTouchDevice() or not focused.dimen:contains(gesture.pos) then return end
        if gesture.ges == "tap" then return target.activate() end
        if gesture.ges == "hold" and target.context then return target.context() end
    end
    target.widget = frame
    return frame
end

function EndBook:isActionAvailable(action)
    if action.destination then return true end
    if self.preview or not self.ui then return false end
    if action.id == "archive" then
        return require("common/archive_actions").canArchive(self.data.file)
    end
    if action.id == "restart" then return true end
    local collate = G_reader_settings:readSetting("collate")
    return collate ~= "access" and collate ~= "date"
end

function EndBook:onFeaturedAction(action)
    if not self:isActionAvailable(action) then return true end
    if action.destination then
        self:leave(action.destination)
    elseif action.id == "archive" then
        require("common/archive_actions").markCompleteAndArchive(self.ui.status, self)
    elseif action.id == "next_file" then
        local ui = self.ui
        ui.doc_settings:flush()
        self:onClose()
        UIManager:nextTick(function() ui.status:onOpenNextOrPreviousFileInFolder() end)
    elseif action.id == "restart" then
        self.ui.doc_settings:flush()
        self:onClose()
        UIManager:nextTick(function() UIManager:broadcastEvent(require("ui/event"):new("GotoPage", 1)) end)
    end
    return true
end

function EndBook:buildNavigationRow(width, height, max_height)
    local Screen = Device.screen
    local config = self.plugin.config.end_book.modules.featured
    local entries = Data.featuredActions(config)
    self.featured_navigation_buttons, self.featured_navigation_labels = {}, {}
    self.featured_navigation_row = nil
    if #entries == 0 then return end
    local configured_size = config.navigation_icon_size or 0
    local requested_size = configured_size > 0 and configured_size or math.floor(G_defaults:readSetting("DGENERIC_ICON_SIZE") * 1.25 + 0.5)
    local padding = math.min(Screen:scaleBySize(5), math.max(0, math.floor(height * 0.02)))
    local max_cell_width = math.max(1, math.floor(width / #entries))
    local labels, label_height = {}, 0
    local style = config.text_styles.navigation
    if config.show_navigation_labels ~= false then
        local size = math.max(1, math.min(style.font_size, math.floor(height * 0.1)))
        local font = style.font_face == "default" and require("modules/filebrowser/patches/library_font").getFontName() or style.font_face
        for index, entry in ipairs(entries) do
            labels[index] = TextWidget:new{
                text = entry.label, padding = 0, max_width = max_cell_width,
                face = require("ui/font"):getFace(font, size), bold = style.bold == true,
            }
            label_height = math.max(label_height, labels[index]:getSize().h)
        end
    end
    local icon_height = (max_height or math.floor(height * 0.45)) - label_height - padding * 2
    if max_height then icon_height = math.max(Screen:scaleBySize(8), icon_height) end
    local size = math.max(1, math.floor(math.min(Screen:scaleBySize(requested_size),
        max_cell_width - padding * 2, icon_height)))
    local cells, total_width = {}, 0
    self.featured_navigation_buttons = {}
    self.featured_navigation_labels = labels
    for index, entry in ipairs(entries) do
        local enabled = self:isActionAvailable(entry)
        local button = IconButton:new{
            file = resolve_icon(config.navigation_icons and config.navigation_icons[entry.id] or entry.icon),
            width = size, height = size, padding = padding, enabled = enabled,
            show_parent = self, allow_flash = false, callback = function() self:onFeaturedAction(entry) end,
        }
        button.image.dim = not enabled
        self.featured_navigation_buttons[#self.featured_navigation_buttons + 1] = button
        local label = labels[index]
        if label and not enabled then label.fgcolor = Blitbuffer.COLOR_DARK_GRAY end
        local cell_width = math.max(button:getSize().w, label and label:getSize().w or 0)
        cells[index] = CenterContainer:new{
            dimen = Geom:new{ w = cell_width, h = button:getSize().h + (label and label:getSize().h or 0) },
            VerticalGroup:new{ align = "center", button, label },
        }
        total_width = total_width + cell_width
    end
    local remaining = math.max(0, width - total_width)
    local row = HorizontalGroup:new{ align = "top" }
    for index, cell in ipairs(cells) do
        row[#row + 1] = #cells == 1 and CenterContainer:new{
            dimen = Geom:new{ w = width, h = cell:getSize().h }, cell,
        } or cell
        if index < #cells then
            row[#row + 1] = HorizontalSpan:new{
                width = math.floor(remaining * index / (#cells - 1)) - math.floor(remaining * (index - 1) / (#cells - 1)),
            }
        end
    end
    self.featured_navigation_row = row
    return row
end

function EndBook:buildStatusHeader()
    local header, back = SharedState.get(self.plugin, "createStatusRowCustomBack")(function() self:onClose() end)
    back.show_parent = self
    self.back_button = back
    self.layout[1] = { back }
    return header
end

function EndBook:_zen_status_refresh()
    if self.closed then return end
    local header = self:buildStatusHeader()
    if header:getSize().h ~= self.header_widget:getSize().h then
        header:free()
        self:rebuild()
        return
    end
    local region = self.header_widget.dimen
    WidgetResources.replaceChild(self.header_widget, 1, header)
    self.header_widget.dimen = region
    UIManager:setDirty(self, "ui", region)
end

function EndBook:rebuild()
    if self.closed then return end
    if self[1] then self[1]:free() end
    local Screen = Device.screen
    local width, height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ w = width, h = height }
    local config = utils.deepcopy(self.plugin.config.end_book)
    config.quotes.automatic_font_size = true
    config.modules.stats_triplet.automatic_font_size = true
    config.modules.featured = Data.featuredConfig(self.plugin)
    local margin = math.max(2, math.min(Screen:scaleBySize(8), math.floor(width * 0.025)))
    local gap = math.max(4, Screen:scaleBySize(8))
    local content_w = width - margin * 2
    self.layout = {}
    self.featured_navigation_buttons, self.featured_navigation_labels, self.featured_navigation_row = {}, {}, nil
    local header = self:buildStatusHeader()
    local header_h = header:getSize().h
    self.header_widget = FrameContainer:new{
        width = width, height = header_h, padding = 0, bordersize = 0, header,
    }
    local back_hitbox_w = Screen:scaleBySize(60)
    self.ges_events = {
        MenuTap = { GestureRange:new{ ges = "tap", range = Geom:new{
            x = back_hitbox_w, y = 0, w = width - back_hitbox_w,
            h = math.max(header_h + margin, height * 0.07),
        } } },
        MenuSwipe = { GestureRange:new{ ges = "swipe", range = Geom:new{ x = 0, y = 0, w = width, h = height * 0.14 } } },
        HoldWidgetSettings = { GestureRange:new{ ges = "hold", range = Geom:new{ x = 0, y = 0, w = width, h = height } } },
    }
    local recommendations = self.data:getRecommendations()
    local strip_config
    strip_config, self.source = Data.stripConfig(recommendations, self.source, config, self.data.authors)
    config.modules.strip = strip_config
    local controls_h = strip_config and strip_config.controls.enabled
        and Screen:scaleBySize(require("modules/filebrowser/patches/home/widgets/strip_common").CONTROLS_HEIGHT) or 0
    local rows, seen = {}, {}
    local strip_index
    for _i, id in ipairs(config.rows.order) do
        local widget = Registry.get(id)
        if widget and WIDGETS[id] and not seen[id] and config.rows.enabled[id]
                and (id ~= "strip" or strip_config)
                and (id ~= "quotes" or not self.data:getCurrentQuote().is_empty) then
            seen[id] = true
            local units = Data.WIDGET_UNITS[id] or Registry.sizeUnits(widget, config.modules[id])
            rows[#rows + 1] = setmetatable({
                size = Data.WIDGET_UNITS[id] and { units = units } or widget.size,
                _home_units = units,
            }, { __index = widget })
            if id == "strip" then
                rows[#rows].preferredHeight = function(ctx) return widget.preferredHeight(ctx) - controls_h end
            end
            if id == "strip" then strip_index = #rows end
        end
    end
    local available = math.max(1, height - header_h - margin * 2 - gap)
    local capacity = Registry.capacityUnits(width, height)
    if not strip_index then controls_h = 0 end
    -- Reserve strip controls before allocating space to covers and text.
    local heights = SharedState.get(self.plugin, "home").computeRowHeights(
        rows, available - controls_h, gap, capacity, content_w, config.modules, config, self.data)
    if strip_index then heights[strip_index].h = heights[strip_index].h + controls_h end
    local body = VerticalGroup:new{ align = "left" }
    self.widget_rows = {}
    local row_y = margin + header_h + gap
    for index, widget in ipairs(rows) do
        local id = widget.id
        local row_height = heights[index].h
        local ctx = {
            width = content_w, height = row_height,
            row_gap_above = index > 1 and gap or 0,
            is_first_row = index == 1, is_last_row = index == #rows,
            component_id = id, menu = self, config = config, zen_config = self.plugin.config,
            module_cfg = config.modules[id], data = self.data,
            empty_message = _("No books to show."),
            openBook = function(path) self:openBook(path) end,
            shiftStrip = function(source, count, order, direction, component_id, _two_rows, refresh)
                return self.data:shiftStripItems(source, count, order, direction, component_id, refresh)
            end,
            buildStatusRow = SharedState.get(self.plugin, "buildStatusRow"),
            openTopMenu = function(gesture)
                if gesture and gesture.pos and gesture.pos.y < height * 0.07 then
                    return self:onMenuTap(nil, gesture)
                end
                return false
            end,
        }
        if id == "strip" then
            ctx.module_cfg = strip_config
            ctx.showBookMenu = function(path, source) return self:showBookMenu(path, source) end
            ctx.skipOpeningBanner = true
            if self.preview then ctx.openCover = function(path) return self:showCover(path) end end
            if not self._zen_home_strip_runtime or self._zen_home_strip_runtime.active_id ~= self.source then
                self._zen_home_strip_runtime = {
                    source = utils.deepcopy(strip_config.default_source), active_id = self.source,
                }
            end
            ctx.rememberStripState = function(state) self.source = state.active_id end
            ctx.prepareHomeFocusTarget = function(target, item) return self:prepareFocusTarget(target, item) end
            ctx.registerHomeFocusTarget = ctx.prepareHomeFocusTarget
            local focus_base = #self.layout
            ctx.activateStripFocusTargets = function(targets)
                local focus_rows = {}
                for _i, target in ipairs(targets) do
                    local row_index = (target.subrow or 1) + (strip_config.controls.enabled == true and 1 or 0)
                    focus_rows[row_index] = focus_rows[row_index] or {}
                    local row = focus_rows[row_index]
                    row[#row + 1] = target.widget
                end
                for row_index, row in ipairs(focus_rows) do self.layout[focus_base + row_index] = row end
            end
        elseif id == "featured" then
            ctx.fitToBounds = true
            ctx.showBookStatus = true
            ctx.openCover = function() return self:showCover() end
            ctx.buildNavigationRow = function(nav_width, nav_height, max_height)
                return self:buildNavigationRow(nav_width, nav_height, max_height)
            end
        end
        local content = widget.build(ctx)
        if id == "featured" and #self.featured_navigation_buttons > 0 then
            self.layout[#self.layout + 1] = self.featured_navigation_buttons
        end
        if index > 1 then
            body[#body + 1] = VerticalSpan:new{ width = gap }
            row_y = row_y + gap
        end
        self.widget_rows[#self.widget_rows + 1] = {
            id = id, dimen = Geom:new{ x = margin, y = row_y, w = content_w, h = row_height },
        }
        row_y = row_y + row_height
        body[#body + 1] = content
    end
    self.body_widget = TopContainer:new{
        dimen = Geom:new{ w = content_w, h = available }, body,
    }
    self[1] = FrameContainer:new{
        width = width, height = height, padding = 0, bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            self.header_widget, VerticalSpan:new{ width = gap },
            FrameContainer:new{
                width = width, padding = margin, bordersize = 0, self.body_widget,
            },
        },
    }
    self.selected = { x = 1, y = 1 }
    UIManager:setDirty(self, "ui")
end

EndBook._home_rebuild = EndBook.rebuild

function EndBook:onClose()
    UIManager:close(self)
    return true
end

EndBook.onCloseAll = EndBook.onClose

function EndBook:onCloseWidget()
    self.closed = true
    ClockTimer.unbind(self)
    local kosync = not self.preview and self.ui and self.ui.kosync
    local settings = kosync and kosync.settings
    local summary = self.ui and self.ui.doc_settings:readSetting("summary") or {}
    if summary.status == "complete" and settings and settings.auto_sync
            and settings.username and settings.userkey then
        UIManager:broadcastEvent(require("ui/event"):new("KOSyncPushProgress"))
    end
    self:free()
    self.data:free()
    UIManager:setDirty(nil, "ui")
end

function EndBook.show(ui, plugin, preview)
    if not preview and (not ui or not ui.document) then return end
    if not preview and (ui.doc_settings:readSetting("summary") or {}).status ~= "complete" then
        ui.status:markBook(true)
        ui.doc_settings:flush()
    end
    local page = EndBook:new{ ui = ui, plugin = plugin, preview = preview }
    UIManager:show(page, "full")
    return page
end

return EndBook
