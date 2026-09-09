describe("reader book status", function()
    local dependencies = {
        "modules/reader/patches/book_status",
        "ui/widget/bookstatuswidget",
        "apps/reader/modules/readerstatus",
        "common/book_status",
        "common/library_navigation",
        "common/plugin_root",
        "common/ui/zen_icon_button",
        "common/utils",
        "gettext",
        "libs/libkoreader-lfs",
        "ui/size",
        "device",
        "ui/uimanager",
        "ui/widget/button",
        "ui/widget/container/centercontainer",
        "ui/event",
        "ui/geometry",
        "ui/widget/horizontalgroup",
        "ui/widget/horizontalspan",
        "ui/widget/textboxwidget",
        "ui/widget/verticalgroup",
        "ui/widget/verticalspan",
    }
    local saved_modules
    local saved_defaults
    local saved_reader_settings
    local BookStatusWidget
    local ReaderStatus
    local invalidated
    local next_file_opens
    local library_opens
    local closed
    local icon_buttons
    local buttons
    local horizontal_groups
    local horizontal_spans
    local rate_widths
    local screen_mode
    local screen_width
    local screen_height
    local saved_default_tab_icon
    local top_widget
    local broadcast_events
    local close_widget_calls

    local function widget_class()
        return {
            new = function(_, values)
                values = values or {}
                values.getSize = values.getSize or function(self)
                    return {
                        w = self.dimen and self.dimen.w or self.width or 0,
                        h = self.dimen and self.dimen.h or self.height or 20,
                    }
                end
                return values
            end,
        }
    end

    local function sized_widget(height)
        return { getSize = function() return { w = 0, h = height } end }
    end

    local function make_status()
        return {
            key_events = {},
            layout = {},
            selected = { x = 1, y = 1 },
            padding = 15,
            ui = {
                document = {},
                doc_settings = { flush = function() end },
                status = {
                    onOpenNextOrPreviousFileInFolder = function()
                        next_file_opens = next_file_opens + 1
                    end,
                },
            },
            genHeader = function()
                return {
                    { width = 30 },
                    getSize = function(self)
                        return { w = 0, h = self[1].width + 20 }
                    end,
                    resetLayout = function() end,
                }
            end,
            generateRateGroup = function()
                return {}
            end,
            genBookInfoGroup = function(self)
                local group = self:generateRateGroup(screen_width, 60, 0)
                self.generated_rate_group = group
                return sized_widget(276)
            end,
            genSummaryGroup = function(self)
                self.note_widget = {
                    text = "note",
                    width = 100,
                    height = 120,
                    line_height_px = 20,
                    getSize = function(note)
                        return { w = note.width, h = note.height }
                    end,
                    free = function(note) note.freed = true end,
                }
                self.original_note_widget = self.note_widget
                self.note_frame = {
                    self.note_widget,
                    getSize = function(frame)
                        return { w = 120, h = frame[1]:getSize().h + 20 }
                    end,
                }
                return {
                    { getSize = function() return { w = 0, h = 5 } end },
                    {
                        dimen = { h = 160 },
                        getSize = function(container)
                            return { w = 0, h = container.dimen.h }
                        end,
                    },
                    getSize = function(summary)
                        return { w = 0, h = summary[1]:getSize().h + summary[2]:getSize().h }
                    end,
                    resetLayout = function() end,
                }
            end,
            genStatisticsGroup = function()
                return sized_widget(60)
            end,
            generateSwitchGroup = function()
                return sized_widget(105)
            end,
        }
    end

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(dependencies) do
            saved_modules[name] = package.loaded[name] or false
        end
        saved_defaults = _G.G_defaults
        saved_reader_settings = _G.G_reader_settings
        next_file_opens = 0
        library_opens = 0
        closed = 0
        icon_buttons = {}
        buttons = {}
        horizontal_groups = {}
        horizontal_spans = {}
        rate_widths = {}
        screen_mode = "portrait"
        screen_width = 400
        screen_height = 800
        invalidated = {}
        top_widget = nil
        broadcast_events = {}
        close_widget_calls = 0
        saved_default_tab_icon = rawget(_G, "__ZEN_UI_NAVBAR_DEFAULT_TAB_ICON")

        BookStatusWidget = {
            generateRateGroup = function(self, width)
                rate_widths[#rate_widths + 1] = width
                self.layout[1] = { { id = "star" } }
                return {}
            end,
            onChangeBookStatus = function(self)
                self.changed_status = true
                return true
            end,
            onCloseWidget = function()
                close_widget_calls = close_widget_calls + 1
            end,
        }
        BookStatusWidget.__index = BookStatusWidget
        ReaderStatus = {
            markBook = function(self)
                self.marked = true
                return true
            end,
            onEndOfBook = function(self)
                top_widget = setmetatable({
                    ui = self.ui,
                    summary = self.summary,
                }, BookStatusWidget)
                return true
            end,
        }
        ZenSpec.replace("ui/widget/bookstatuswidget", BookStatusWidget)
        ZenSpec.replace("apps/reader/modules/readerstatus", ReaderStatus)
        ZenSpec.replace("common/book_status", {
            invalidate = function(file) invalidated[#invalidated + 1] = file end,
        })
        ZenSpec.replace("common/library_navigation", {
            showFromReader = function()
                library_opens = library_opens + 1
            end,
        })
        ZenSpec.replace("common/plugin_root", "/plugin")
        ZenSpec.replace("common/utils", {
            getUserIconsDir = function() return "/user-icons/" end,
            resolveIcon = function(icons_dir, name)
                if icons_dir == "/plugin/icons/" and (name == "home" or name == "library") then
                    return icons_dir .. name .. ".svg"
                end
            end,
            resolveLocalIcon = function(icons_dir, name)
                if icons_dir == "/koreader/resources/icons/mdlight/" then
                    return icons_dir .. name .. ".svg"
                end
            end,
        })
        ZenSpec.replace("libs/libkoreader-lfs", {
            currentdir = function() return "/koreader" end,
        })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/size", {
            padding = { default = 8 },
            span = { vertical_default = 4 },
        })
        ZenSpec.replace("device", {
            screen = {
                getScreenMode = function() return screen_mode end,
                getWidth = function() return screen_width end,
                getHeight = function() return screen_height end,
                scaleBySize = function(_, value) return math.ceil(value) end,
            },
            input = { group = { PgFwd = { "PgFwd" } } },
            hasKeys = function() return true end,
        })
        ZenSpec.replace("ui/uimanager", {
            close = function() closed = closed + 1 end,
            scheduleIn = function(_, _, callback) callback() end,
            getTopmostVisibleWidget = function() return top_widget end,
            broadcastEvent = function(_, event)
                broadcast_events[#broadcast_events + 1] = event.name
            end,
        })
        ZenSpec.replace("common/ui/zen_icon_button", {
            new = function(_, values)
                values.getSize = function(self)
                    local padding = self.padding or 0
                    return {
                        w = (self.width or 0) + padding * 2,
                        h = (self.height or 20) + padding * 2,
                    }
                end
                icon_buttons[#icon_buttons + 1] = values
                return values
            end,
        })
        ZenSpec.replace("ui/widget/button", {
            new = function(_, values)
                values.getSize = function(self)
                    return { w = self.width or 0, h = self.height or 20 }
                end
                buttons[#buttons + 1] = values
                return values
            end,
        })
        ZenSpec.replace("ui/widget/container/centercontainer", widget_class())
        ZenSpec.replace("ui/widget/horizontalgroup", {
            new = function(_, values)
                values = values or {}
                values.getSize = values.getSize or function(self)
                    return { w = self.width or 0, h = self.height or 20 }
                end
                horizontal_groups[#horizontal_groups + 1] = values
                return values
            end,
        })
        ZenSpec.replace("ui/widget/horizontalspan", {
            new = function(_, values)
                values = values or {}
                values.getSize = values.getSize or function(self)
                    return { w = self.width or 0, h = 0 }
                end
                horizontal_spans[#horizontal_spans + 1] = values
                return values
            end,
        })
        ZenSpec.replace("ui/widget/textboxwidget", {
            new = function(_, values)
                values.line_height_px = 20
                values.getSize = function(note)
                    return { w = note.width, h = note.height }
                end
                values.free = function(note) note.freed = true end
                return values
            end,
        })
        ZenSpec.replace("ui/widget/verticalgroup", {
            new = function(_, values)
                values = values or {}
                values.getSize = function(group)
                    local height = 0
                    for _i, child in ipairs(group) do
                        if child.getSize then height = height + child:getSize().h end
                    end
                    return { w = 0, h = height }
                end
                values.resetLayout = function() end
                return values
            end,
        })
        ZenSpec.replace("ui/widget/verticalspan", {
            new = function(_, values)
                values.getSize = function(span) return { w = 0, h = span.width } end
                return values
            end,
        })
        ZenSpec.replace("ui/event", { new = function(_, name) return { name = name } end })
        ZenSpec.replace("ui/geometry", { new = function(_, values) return values end })

        _G.G_defaults = { readSetting = function() return 24 end }
        _G.G_reader_settings = ZenSpec.memorySettings()
    end)

    after_each(function()
        _G.G_defaults = saved_defaults
        _G.G_reader_settings = saved_reader_settings
        rawset(_G, "__ZEN_UI_NAVBAR_DEFAULT_TAB_ICON", saved_default_tab_icon)
        for _i, name in ipairs(dependencies) do
            package.loaded[name] = saved_modules[name] or nil
        end
    end)

    it("adds the header and restart controls to hardware focus navigation", function()
        G_reader_settings:saveSetting("collate", "natural")
        rawset(_G, "__ZEN_UI_NAVBAR_DEFAULT_TAB_ICON", function() return "home" end)
        require("modules/reader/patches/book_status")()
        local status = make_status()

        BookStatusWidget.getStatusContent(status, 400)

        assert.are.equal("/koreader/resources/icons/mdlight/chevron.left.svg", icon_buttons[1].file)
        assert.are.equal("/plugin/icons/home.svg", icon_buttons[2].file)
        assert.same({ icon_buttons[1], icon_buttons[2] }, status.layout[1])
        assert.same({ buttons[1] }, status.layout[2])
        assert.are.equal("Restart Book", buttons[1].text)
        assert.are.equal(3, status.selected.y)
    end)

    it("fits the content to the screen and shrinks the review only when needed", function()
        require("modules/reader/patches/book_status")()
        local status = make_status()

        local content = BookStatusWidget.getStatusContent(status, 400)

        assert.are.equal(800, content:getSize().h)
        assert.same({ 29, 29, 29 }, {
            content[3][1].width,
            content[5][1].width,
            content[7][1].width,
        })
        assert.is_nil(status.original_note_widget.freed)

        screen_height = 650
        status = make_status()
        content = BookStatusWidget.getStatusContent(status, 400)

        assert.are.equal(650, content:getSize().h)
        assert.are.equal(57, status.note_widget.height)
        assert.is_true(status.original_note_widget.freed)
    end)

    it("opens the next sequential file on page-forward from book status", function()
        G_reader_settings:saveSetting("collate", "natural")
        require("modules/reader/patches/book_status")()
        local status = make_status()

        BookStatusWidget.getStatusContent(status, 400)

        assert.is_not_nil(status.key_events.ZenOpenNextFile)
        assert.is_nil(status.key_events.ZenGoLibrary)
        assert.is_true(status:onZenOpenNextFile())
        assert.are.equal(1, next_file_opens)
        assert.are.equal(1, closed)
        assert.are.equal(0, library_opens)
    end)

    it("keeps page-forward at the library fallback for non-sequential collation", function()
        G_reader_settings:saveSetting("collate", "access")
        require("modules/reader/patches/book_status")()
        local status = make_status()

        BookStatusWidget.getStatusContent(status, 400)

        assert.is_nil(status.key_events.ZenOpenNextFile)
        assert.is_not_nil(status.key_events.ZenGoLibrary)
        assert.is_true(status:onZenGoLibrary())
        assert.are.equal(0, next_file_opens)
        assert.are.equal(1, closed)
        assert.are.equal(1, library_opens)
    end)

    it("keeps landscape actions beside the stars and inside the safe header width", function()
        screen_mode = "landscape"
        screen_width = 800
        G_reader_settings:saveSetting("collate", "access")
        require("modules/reader/patches/book_status")()
        local status = make_status()

        BookStatusWidget.getStatusContent(status, screen_width)

        assert.are.equal(345, buttons[1].width)
        assert.are.equal(275, rate_widths[1])
        assert.same(buttons[1], horizontal_groups[2][1])
        assert.are.equal(698, horizontal_spans[1].width)
        assert.are.equal(-6, status.generated_rate_group[1].width)
        assert.are.equal(6, status.generated_rate_group[3].width)
    end)

    it("invalidates cached status after reader and status-widget writes", function()
        require("modules/reader/patches/book_status")()
        local reader_status = { document = { file = "/books/end.epub" } }
        local status_widget = make_status()
        status_widget.ui.document.file = "/books/manual.epub"

        assert.is_true(ReaderStatus.markBook(reader_status, true))
        assert.is_true(BookStatusWidget.onChangeBookStatus(status_widget, { "reading" }, 1))

        assert.is_true(reader_status.marked)
        assert.is_true(status_widget.changed_status)
        assert.same({ "/books/end.epub", "/books/manual.epub" }, invalidated)
    end)

    it("pushes finished end-of-book progress only when automatic KOSync is configured", function()
        require("modules/reader/patches/book_status")()
        local settings = {
            auto_sync = true,
            username = "reader",
            userkey = "key",
        }
        local reader_status = {
            ui = { kosync = { settings = settings } },
            summary = { status = "complete" },
        }

        assert.is_true(ReaderStatus.onEndOfBook(reader_status))
        top_widget:onCloseWidget()
        assert.same({ "KOSyncPushProgress" }, broadcast_events)

        reader_status.summary = { status = "reading" }
        ReaderStatus.onEndOfBook(reader_status)
        top_widget:onCloseWidget()
        settings.auto_sync = false
        reader_status.summary = { status = "complete" }
        ReaderStatus.onEndOfBook(reader_status)
        top_widget:onCloseWidget()

        assert.same({ "KOSyncPushProgress" }, broadcast_events)
        assert.are.equal(3, close_widget_calls)
    end)
end)
