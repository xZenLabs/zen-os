local Blitbuffer = require("ffi/blitbuffer")
local ButtonTable = require("ui/widget/buttontable")
local Device = require("device")
local FocusManager = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetResources = require("common/widget_resources")
local Settings = require("modules/settings/sections/end_book_settings")
local Registry = require("modules/filebrowser/patches/home/components/registry")
local _ = require("gettext")

local EndBook = FocusManager:extend{ name = "zen_end_book", covers_fullscreen = true }
local MIN_HEIGHT = { stats_triplet = 65, featured = 180, quotes = 100, strip = 190 }

function EndBook:init()
    self.source = self.plugin.config.end_book.strip_source
    self.data = require("modules/reader/end_book_data").new(self.ui, self.plugin,
        self.plugin.config.end_book, function() self:rebuild() end, function() self:onClose() end)
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.Library = { { Device.input.group.PgFwd } }
        self.key_events.PreviousQuote = { { Device.input.group.PgBack } }
    end
    self:rebuild()
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
    self:onClose()
    UIManager:nextTick(function()
        require("common/library_navigation").showFromReader(ui, plugin, options)
    end)
end

function EndBook:onLibrary()
    self:leave({ target_tab = "books" })
    return true
end

function EndBook:openBook(path)
    local ui = self.ui
    self:onClose()
    UIManager:nextTick(function()
        require("apps/filemanager/filemanagerutil").openFile(ui, path)
    end)
end

function EndBook:chooseBook(paths)
    local Menu = require("ui/widget/menu")
    local items, menu = {}
    for _i, path in ipairs(paths) do
        local book = self.data:getBook(path, true)
        items[#items + 1] = {
            text = book and book.title or path:match("([^/]+)$"),
            callback = function() UIManager:close(menu); self:openBook(path) end,
        }
    end
    menu = Menu:new{ title = _("Book strip"), item_table = items, is_popout = true }
    UIManager:show(menu)
end

function EndBook:rebuild()
    if self.closed then return end
    if self.cropping_widget then self.cropping_widget:onCloseWidget() end
    if self[1] then self[1]:free() end
    local Screen = Device.screen
    local width, height = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ w = width, h = height }
    local config = self.plugin.config.end_book
    local scroll_offset = self.cropping_widget and self.cropping_widget:getScrolledOffset()
    local margin, gap = Screen:scaleBySize(10), Screen:scaleBySize(8)
    local content_w = width - margin * 2
    self.layout = {}
    local function buttons(entries, focus, row_width)
        local row = ButtonTable:new{
            width = row_width or content_w, buttons = { entries }, show_parent = self,
        }
        if focus ~= false then
            self.layout[#self.layout + 1] = row.buttons_layout[1]
        end
        return row
    end
    local header = buttons({
        { text = _("Back"), callback = function() self:onClose() end },
        { text = _("Highlights"), callback = function()
            self:onClose()
            self.ui.bookmark:onShowBookmark()
        end },
        { text = _("Widgets"), callback = function()
            Settings.showWidgets(self.plugin, function()
                self.source = self.plugin.config.end_book.strip_source
                self:rebuild()
            end)
        end },
    })
    local footer = buttons({
        { text = _("Library"), callback = function() self:onLibrary() end },
        { text = _("To Be Read"), callback = function() self:leave({ target_tab = "to_be_read" }) end },
        { text = _("Home"), callback = function() self:leave({ open_home = true }) end },
        { text = _("Book status"), callback = function()
            self:onClose()
            self.ui.status:onShowBookStatus()
        end },
    }, false)
    local rows, units, minimums = {}, {}, {}
    local minimum, total_units = 0, 0
    for _i, id in ipairs(config.rows.order) do
        local widget = Registry.get(id)
        if widget and MIN_HEIGHT[id] and config.rows.enabled[id] then
            rows[#rows + 1] = widget
            local unit = Registry.baseSizeUnits(widget)
            units[#units + 1] = unit
            total_units = total_units + unit
            local min_height = Screen:scaleBySize(MIN_HEIGHT[id])
            minimums[#minimums + 1] = min_height
            minimum = minimum + min_height
        end
    end
    local available = math.max(1, height - header:getSize().h - footer:getSize().h - margin * 2 - gap * 2)
    local extra = math.max(0, available - minimum - math.max(0, #rows - 1) * gap)
    local body = VerticalGroup:new{ align = "left" }
    for index, widget in ipairs(rows) do
        local id = widget.id
        local row_height = minimums[index] + math.floor(extra * units[index] / total_units)
        local ctx = {
            width = content_w - 2, height = row_height - 2,
            component_id = id, menu = self, config = config, zen_config = self.plugin.config,
            module_cfg = config.modules[id], data = self.data,
            empty_message = _("No books to show."),
            openBook = function(path) self:openBook(path) end,
            shiftStrip = function(source, count, order, direction, component_id, _two_rows, refresh)
                return self.data:shiftStripItems(source, count, order, direction, component_id, refresh)
            end,
        }
        local content
        if id == "strip" then
            local recommendations = self.data:getRecommendations()
            local source_buttons = {}
            for _i, source in ipairs(Settings.sources) do
                source_buttons[#source_buttons + 1] = {
                    text = source[2],
                    checked_func = function() return self.source == source[1] end,
                    callback = function()
                        self.source = source[1]
                        self.data:resetStripPages()
                        self:rebuild()
                        if not Device:isTouchDevice() then self:chooseBook(recommendations[self.source]) end
                    end,
                }
            end
            local controls = buttons(source_buttons, true, ctx.width)
            self._zen_home_strip_runtime = { source = { kind = "custom", paths = recommendations[self.source] or {} } }
            ctx.height = ctx.height - controls:getSize().h
            content = VerticalGroup:new{ controls, widget.build(ctx) }
        else
            content = widget.build(ctx)
        end
        if index > 1 then body[#body + 1] = VerticalSpan:new{ width = gap } end
        body[#body + 1] = WidgetResources.paintFrameBorderOnTop(FrameContainer:new{
            padding = 0, bordersize = 1, radius = Screen:scaleBySize(6),
            color = Blitbuffer.COLOR_GRAY, background = Blitbuffer.COLOR_WHITE,
            content,
        })
    end
    self.layout[#self.layout + 1] = footer.buttons_layout[1]
    self.cropping_widget = ScrollableContainer:new{
        dimen = Geom:new{ w = content_w, h = available }, show_parent = self, body,
    }
    self.cropping_widget:setScrolledOffset(scroll_offset)
    self[1] = FrameContainer:new{
        width = width, height = height, padding = margin, bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            header, VerticalSpan:new{ width = gap }, self.cropping_widget,
            VerticalSpan:new{ width = gap }, footer,
        },
    }
    self.selected = { x = 1, y = 1 }
    UIManager:setDirty(self, "ui")
end

function EndBook:onClose()
    UIManager:close(self)
    return true
end

EndBook.onCloseAll = EndBook.onClose

function EndBook:onCloseWidget()
    self.closed = true
    local kosync = self.ui.kosync
    local settings = kosync and kosync.settings
    local summary = self.ui.doc_settings:readSetting("summary") or {}
    if summary.status == "complete" and settings and settings.auto_sync
            and settings.username and settings.userkey then
        UIManager:broadcastEvent(require("ui/event"):new("KOSyncPushProgress"))
    end
    self:free()
    self.data:free()
    UIManager:setDirty(nil, "ui")
end

function EndBook.show(ui, plugin)
    if not ui or not ui.document then return end
    local page = EndBook:new{ ui = ui, plugin = plugin }
    UIManager:show(page, "full")
    return page
end

return EndBook
