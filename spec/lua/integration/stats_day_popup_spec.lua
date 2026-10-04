describe("stats day popup page buttons", function()
    local saved_modules
    local shown_dialog
    local dirty_parent
    local books
    local ScrollableContainer

    local Widget = {}
    function Widget:extend(values)
        return setmetatable(values or {}, { __index = self })
    end
    function Widget:new(values)
        local widget = self:extend(values)
        widget.ges_events = {}
        if widget.init then widget:init() end
        return widget
    end
    function Widget:getSize()
        return self.dimen or { w = self.width or 100, h = self.height or 20 }
    end

    local function upvalue(fn, target)
        for index = 1, 64 do
            local name, value = debug.getupvalue(fn, index)
            if not name then break end
            if name == target then return value end
        end
        error("Missing upvalue: " .. target)
    end

    before_each(function()
        saved_modules = {}
        for name, value in pairs(package.loaded) do saved_modules[name] = value end
        shown_dialog, dirty_parent = nil, nil
        books = {}
        for i = 1, 8 do
            books[i] = { title = "Book " .. i, duration = 600, pages = 10 }
        end
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
                scaleBySize = function(_self, value) return value end,
            },
            input = { group = { PgBack = { "LPgBack" }, PgFwd = { "LPgFwd" } } },
            hasKeys = function() return true end,
            isTouchDevice = function() return true end,
        })
        ZenSpec.replace("ui/uimanager", {
            show = function(_self, dialog) shown_dialog = dialog end,
            setDirty = function(_self, parent) dirty_parent = parent end,
        })
        ZenSpec.replace("ui/bidi", { mirroredUILayout = function() return false end })
        ZenSpec.replace("ui/font", { getFace = function() return {} end })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("datetime", { secondsToDate = function() return "Today" end })
        ZenSpec.replace("ffi/blitbuffer", { COLOR_BLACK = 0, COLOR_WHITE = 1 })
        ZenSpec.replace("optmath", { round = function(value) return math.floor(value + 0.5) end })
        for _i, name in ipairs({
            "ui/geometry", "ui/gesturerange", "ui/widget/container/inputcontainer",
            "ui/widget/container/centercontainer", "ui/widget/container/framecontainer",
            "ui/widget/container/leftcontainer", "ui/widget/horizontalgroup",
            "ui/widget/horizontalspan", "ui/widget/iconwidget", "ui/widget/linewidget",
            "ui/widget/textboxwidget", "ui/widget/textwidget", "ui/widget/titlebar",
            "ui/widget/verticalspan",
        }) do
            ZenSpec.replace(name, Widget)
        end
        ZenSpec.replace("ui/widget/verticalgroup", Widget:extend{
            getSize = function(self)
                local height = 0
                for _i, child in ipairs(self) do height = height + child:getSize().h end
                return { w = 100, h = height }
            end,
        })
        local scrollbar = Widget:extend{ set = function() end }
        ZenSpec.replace("ui/widget/verticalscrollbar", scrollbar)
        ZenSpec.replace("ui/widget/horizontalscrollbar", scrollbar)
        ScrollableContainer = assert(loadfile("frontend/ui/widget/container/scrollablecontainer.lua"))()
        ZenSpec.replace("ui/widget/container/scrollablecontainer", ScrollableContainer)
        ZenSpec.replace("ui/widget/buttondialog", Widget:extend{
            addWidget = function(self, widget) self[#self + 1] = widget end,
            _onPageScrollToRow = function() error("Cards have no button rows") end,
        })
        ZenSpec.replace("common/ui/background", { tile_bg = function(color) return color end })
        ZenSpec.replace("common/db_stats", { queryBooksForPeriod = function() return books end })
        ZenSpec.replace("common/utils", { resolveLocalIcon = function() end })
        ZenSpec.replace("common/shared_state", { registerLoader = function() end })
        ZenSpec.replace("common/ui/zen_modal_close", {
            installTitleBar = function() end,
            addToFocusLayout = function() end,
        })
        for _i, name in ipairs({
            "pluginloader", "modules/filebrowser/patches/standalone_page",
            "common/db_library", "common/db_bookinfo", "common/widget_resources",
            "common/ui/zen_line_graph", "modules/filebrowser/patches/stats_settings",
            "config/preset_store", "modules/filebrowser/patches/home/widgets/reading_goals",
            "common/inline_icon_map",
        }) do
            ZenSpec.replace(name, {})
        end
        ZenSpec.unload("modules/filebrowser/patches/stats_page")
    end)

    after_each(function()
        for name in pairs(package.loaded) do
            if not saved_modules[name] then package.loaded[name] = nil end
        end
        for name, value in pairs(saved_modules) do package.loaded[name] = value end
    end)

    local function open_popup()
        local StatsPage = require("modules/filebrowser/patches/stats_page")
        local build_content = upvalue(StatsPage.create, "buildContent")
        upvalue(build_content, "showCalendarDaySummary")(nil, os.time(), "divider")
        local scroll = shown_dialog.cropping_widget
        scroll:initState()
        return scroll
    end

    it("scrolls down and up without trying to focus nonexistent button rows", function()
        local scroll = open_popup()
        assert.is_true(scroll._is_scrollable)
        assert.are.same({ { { "LPgFwd" } } }, scroll.key_events.ScrollPageDown)
        assert.are.same({ { { "LPgBack" } } }, scroll.key_events.ScrollPageUp)
        assert.is_true(scroll:onScrollPageUp())
        assert.are.equal(0, scroll:getScrolledOffset().y)
        assert.is_true(scroll:onScrollPageDown())
        assert.is_true(scroll:getScrolledOffset().y > 0)
        assert.is_true(scroll:onScrollPageUp())
        assert.are.equal(0, scroll:getScrolledOffset().y)
        assert.are.equal(shown_dialog, dirty_parent)
        scroll:scrollToRatio(nil, 1)
        assert.are.equal(scroll._max_scroll_offset_y, scroll:getScrolledOffset().y)
    end)

    it("leaves a day that fits in the popup unscrolled", function()
        books = { books[1] }
        local scroll = open_popup()
        assert.is_false(scroll._is_scrollable)
        assert.is_false(scroll:onScrollPageDown())
        assert.is_false(scroll:onScrollPageUp())
        assert.are.equal(0, scroll:getScrolledOffset().y)
    end)
end)
