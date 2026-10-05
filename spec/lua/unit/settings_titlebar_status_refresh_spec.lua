describe("settings title bar", function()
    local SettingsTitleBar
    local saved_modules
    local saved_reader_settings
    local scheduled
    local unscheduled

    local dependency_names = {
        "ffi/blitbuffer",
        "ui/widget/button",
        "ui/widget/container/centercontainer",
        "device",
        "ui/widget/container/framecontainer",
        "ui/geometry",
        "ui/gesturerange",
        "ui/widget/horizontalgroup",
        "ui/widget/horizontalspan",
        "ui/widget/iconbutton",
        "ui/widget/container/inputcontainer",
        "ui/widget/inputtext",
        "ui/widget/container/leftcontainer",
        "ui/widget/linewidget",
        "ui/widget/overlapgroup",
        "ui/size",
        "ui/widget/textwidget",
        "ui/uimanager",
        "ui/widget/verticalgroup",
        "ui/widget/verticalspan",
        "common/clock_timer",
        "common/shared_state",
        "common/ui/icon_menu_item",
        "common/ui/zen_icon_button",
        "common/ui/zen_solid_circle",
        "common/ui/zen_button",
        "common/ui/zen_toggle",
        "common/ui/zen_settings_titlebar",
        "common/ui/zen_title_style",
        "common/widget_resources",
        "common/utils",
        "common/plugin_root",
        "gettext",
        "apps/filemanager/filemanager",
    }

    before_each(function()
        saved_modules = {}
        saved_reader_settings = G_reader_settings
        scheduled = {}
        unscheduled = {}
        for _i, name in ipairs(dependency_names) do
            saved_modules[name] = package.loaded[name] or false
        end

        for _i, name in ipairs(dependency_names) do
            ZenSpec.replace(name, {})
        end
        ZenSpec.replace("ui/widget/container/inputcontainer", {
            extend = function(_self, prototype)
                prototype.__index = prototype
                return prototype
            end,
        })
        ZenSpec.replace("device", { screen = {} })
        ZenSpec.replace("ui/uimanager", {
            scheduleIn = function(_self, delay, callback)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end,
            unschedule = function(_self, callback)
                unscheduled[#unscheduled + 1] = callback
            end,
        })
        ZenSpec.replace("common/clock_timer", { unbind = function() end })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.unload("ui/geometry")
        ZenSpec.unload("ui/gesturerange")
        ZenSpec.unload("apps/filemanager/filemanager")
        ZenSpec.unload("common/ui/zen_settings_titlebar")
        ZenSpec.unload("common/ui/zen_toggle")
        SettingsTitleBar = require("common/ui/zen_settings_titlebar")
    end)

    after_each(function()
        G_reader_settings = saved_reader_settings
        for _i, name in ipairs(dependency_names) do
            package.loaded[name] = saved_modules[name] or nil
        end
    end)

    local function make_title_bar()
        local refreshes = 0
        local owner = {}
        local title_bar = { show_parent = owner }
        owner._zen_status_title_bar = title_bar
        owner._zen_status_refresh = function()
            refreshes = refreshes + 1
        end
        package.loaded["ui/uimanager"]._window_stack = { { widget = owner } }
        return title_bar, function() return refreshes end, owner
    end

    local function init_title_bar(options)
        local function new_widget(widget_class, spec)
            spec.getSize = function(self)
                return self.dimen or { w = self.width or 40, h = self.height or 40 }
            end
            if widget_class == package.loaded["ui/widget/button"] then
                spec.label_container = { dimen = {
                    w = (spec.width or 40) - 2 * (spec.padding or spec.padding_h or 0),
                    h = spec.height,
                } }
            end
            return spec
        end
        for _i, name in ipairs(dependency_names) do
            if name:find("^ui/widget/") or name == "common/ui/zen_icon_button"
                    or name == "common/ui/zen_solid_circle" then
                package.loaded[name].new = new_widget
            end
        end
        local screen = package.loaded["device"].screen
        screen.getWidth = function() return 600 end
        screen.scaleBySize = function(_self, size) return size end
        local style = package.loaded["common/ui/zen_title_style"]
        style.ICON_SIZE, style.BUTTON_PADDING, style.BUTTON_SIZE = 28, 8, 44
        style.LEADING_WIDTH, style.TITLE_LEADING_PADDING = 44, 8
        style.LEFT_PADDING, style.RIGHT_PADDING, style.TRAILING_GAP = 12, 12, 4
        style.ROW_HEIGHT, style.VERTICAL_PADDING, style.DIVIDER_HEIGHT = 44, 6, 2
        style.getTitleFace = function() return {} end
        local icon_item = package.loaded["common/ui/icon_menu_item"]
        icon_item.SETTINGS_TOGGLE_WIDTH, icon_item.SETTINGS_TOGGLE_HEIGHT = 50, 25
        package.loaded["common/widget_resources"].free = function() end
        package.loaded["common/utils"].resolveLocalIcon = function() return "/zen/icon.svg" end
        package.loaded["common/utils"].resolveIcon = function() return "/zen/icon.svg" end
        package.loaded["common/plugin_root"] = "/zen"
        options.ges_events = {}
        local title_bar = setmetatable(options, SettingsTitleBar)
        title_bar:init()
        return title_bar
    end

    it("enables native tap feedback on each actionable header icon", function()
        local title_bar = init_title_bar({
            title = "Settings", back_visible = true,
            action = { file = "/zen/refresh.svg", callback = function() end },
        })

        for _i, button in ipairs({ title_bar.back_button, title_bar.action_button,
                title_bar.search_button, title_bar.close_button }) do
            assert.is_true(button.allow_flash)
        end
        assert.is_false(title_bar.root_icon.allow_flash)
    end)

    it("highlights styled header actions and restores their appearance and focus", function()
        local UIManager = require("ui/uimanager")
        local ZenButton = require("common/ui/zen_button")
        local painted = {}
        ZenButton.paintFilled = function() painted[#painted + 1] = "filled" end
        ZenButton.paintOutlined = function() painted[#painted + 1] = "outlined" end
        UIManager.widgetRepaint = function(_self, widget, x, y) widget:paintTo({}, x, y) end
        UIManager.setDirty = function(_self, owner, mode, dimen)
            assert.is_nil(owner)
            assert.are.equal("fast", mode)
            assert.are.equal(80, dimen.w)
        end
        package.loaded["ui/size"].padding = { small = 4, default = 8 }

        for _i, filled in ipairs({ false, true }) do
            local title_bar = init_title_bar({
                title = "Settings", search_visible = false,
                action = { text = "Update", zen_button = true, filled = filled },
            })
            local button = title_bar.action_button
            button.dimen = { x = 10, y = 20, w = 80, h = 40 }
            for _j, focused in ipairs({ false, true }) do
                button._zen_focused = focused
                button:paintTo({}, 10, 20)
                local idle = painted[#painted]
                button:_doFeedbackHighlight()
                assert.are_not.equal(idle, painted[#painted])
                button:_undoFeedbackHighlight()
                assert.are.equal(idle, painted[#painted])
                assert.are.equal(filled, button._zen_filled)
                assert.are.equal(focused, button._zen_focused)
            end
        end
    end)

    it("waits for typing to pause before searching settings", function()
        local queries = {}
        local text = ""
        package.loaded["ui/size"].padding = { small = 4 }
        local title_bar = init_title_bar({
            title = "Settings", search_expanded = true,
            search_callback = function(query) queries[#queries + 1] = query end,
        })
        title_bar.search_input.getText = function() return text end
        title_bar.search_input.setText = function(_self, value) text = value end

        text = "f"
        title_bar.search_input.edit_callback(true)
        local first = scheduled[1].callback
        text = "fo"
        title_bar.search_input.edit_callback(true)

        assert.are.equal(first, unscheduled[1])
        assert.are.equal(0.15, scheduled[2].delay)
        scheduled[2].callback()
        assert.same({ "fo" }, queries)

        text = "foo"
        title_bar.search_input.edit_callback(true)
        title_bar:setQuery("other")
        assert.are.equal(scheduled[3].callback, unscheduled[2])
        assert.same({ "fo" }, queries)
    end)

    it("omits hidden close controls and their space, and shows them by default", function()
        local closed = false
        local title_bar = init_title_bar({
            title = "Wi-Fi networks", title_full_width = true,
            back_visible = true, search_visible = false, close_visible = false,
            action = { file = "/zen/refresh.svg" },
            close_callback = function() closed = true end,
        })

        local title_width = title_bar._title_max_width
        assert.is_nil(title_bar.close_button)
        assert.are.same({ title_bar.back_button, title_bar.action_button },
            title_bar:generateHorizontalLayout()[1])

        title_bar.close_visible = nil
        title_bar:init()
        assert.is_truthy(title_bar.close_button)
        assert.are.equal(title_bar.close_button, title_bar._header_row[#title_bar._header_row][1])
        assert.are.equal(title_width - 48, title_bar._title_max_width)
        assert.are.same({ title_bar.back_button, title_bar.action_button, title_bar.close_button },
            title_bar:generateHorizontalLayout()[1])
        title_bar.close_button.callback()
        assert.is_true(closed)
    end)

    it("places a live Zen toggle beside the action and includes it in keyboard focus", function()
        local enabled = true
        local title_bar = init_title_bar({
            title = "Wi-Fi networks", title_full_width = true,
            back_visible = true, search_visible = false, close_visible = false,
            action = { file = "/zen/refresh.svg" },
        })
        local title_width = title_bar._title_max_width
        title_bar.toggle = {
            value_func = function() return enabled end,
            callback = function() enabled = not enabled end,
        }
        title_bar:init()

        local button = title_bar.toggle_button
        local toggle = button.label_widget
        assert.are.equal(toggle, button.label_container[1])
        assert.are.same({ w = 50, h = 28 }, button.label_container.dimen)
        assert.are.equal(title_width - button:getSize().w - 4, title_bar._title_max_width)
        assert.are.same({ title_bar.back_button, title_bar.action_button, button },
            title_bar:generateHorizontalLayout()[1])
        assert.are.equal(button, title_bar._header_row[#title_bar._header_row])
        assert.is_true(toggle:getValue())
        button.callback()
        assert.is_false(toggle:getValue())
        enabled = true
        assert.is_true(toggle:getValue())

        title_bar.close_visible = true
        title_bar:init()
        assert.are.equal(title_bar.close_button, title_bar._header_row[#title_bar._header_row][1])
        assert.are.equal(title_bar.toggle_button, title_bar._header_row[#title_bar._header_row - 2])
        assert.are.equal(title_bar.action_button, title_bar._header_row[#title_bar._header_row - 4])
        assert.are.same({ title_bar.back_button, title_bar.action_button,
            title_bar.toggle_button, title_bar.close_button }, title_bar:generateHorizontalLayout()[1])
    end)

    it("uses one back hitbox across the chevron, gap, and title", function()
        local taps, holds = 0, 0
        local title_bar = init_title_bar({
            title = "Library", back_visible = true, search_visible = false,
            back_callback = function() taps = taps + 1 end,
            back_hold_callback = function() holds = holds + 1 end,
        })
        G_reader_settings = { isFalse = function() return true end }
        local Geom = require("ui/geometry")
        title_bar.back_button.dimen = Geom:new{ x = 20, y = 20, w = 44, h = 44 }
        title_bar.title_container.dimen = Geom:new{ x = 72, y = 20, w = 150, h = 44 }
        title_bar.title_widget.getSize = function() return { w = 100, h = 24 } end
        local tap_range = title_bar.ges_events.TapBackTitle[1]
        for _i, x in ipairs({ 24, 68, 110 }) do
            assert.is_true(tap_range:match({ ges = "tap", pos = Geom:new{ x = x, y = 40 } }))
            assert.is_true(title_bar:onTapBackTitle())
        end
        assert.are.equal(3, taps)
        assert.is_false(tap_range:match({ ges = "tap", pos = Geom:new{ x = 173, y = 40 } }))
        assert.is_false(tap_range:match({ ges = "tap", pos = Geom:new{ x = 68, y = 19 } }))
        assert.is_true(title_bar.ges_events.HoldBackTitle[1]:match({
            ges = "hold", pos = Geom:new{ x = 68, y = 40 },
        }))
        assert.is_true(title_bar:onHoldBackTitle())
        assert.are.equal(1, holds)

        title_bar.back_visible = false
        assert.is_false(tap_range:match({ ges = "tap", pos = Geom:new{ x = 68, y = 40 } }))
        assert.is_false(title_bar:onTapBackTitle())
        assert.is_false(title_bar:onHoldBackTitle())
        assert.are.equal(3, taps)
        assert.are.equal(1, holds)
    end)

    it("flashes the back chevron and title in one rounded box before navigating", function()
        local UIManager = require("ui/uimanager")
        local screen = require("device").screen
        local Blitbuffer = require("ffi/blitbuffer")
        local Geom = require("ui/geometry")
        local paints, events = {}, {}
        Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE = "black", "white"
        screen.bb = { paintRoundedRect = function(_self, x, y, w, h, color, radius)
            paints[#paints + 1] = { x, y, w, h, color, radius }
        end }
        local title_bar
        title_bar = init_title_bar({
            title = "Library", back_visible = true, search_visible = false,
            back_callback = function()
                events[#events + 1] = "back"
                assert.are.equal("black", title_bar.title_widget.fgcolor)
                assert.is_false(title_bar.back_button.image.invert)
            end,
        })
        title_bar.back_button.dimen = Geom:new{ x = 20, y = 20, w = 44, h = 44 }
        title_bar.back_button.image = { invert = false }
        title_bar.title_container.dimen = Geom:new{ x = 72, y = 20, w = 150, h = 44 }
        title_bar.title_widget.getSize = function() return { w = 100, h = 24 } end
        title_bar.title_widget.fgcolor = "black"
        UIManager.widgetRepaint = function(_self, widget)
            events[#events + 1] = widget == title_bar.back_button and "icon" or "title"
        end
        UIManager.setDirty = function(_self, owner, mode, dimen)
            assert.is_nil(owner)
            assert.are.equal("fast", mode)
            assert.are.same({ x = 20, y = 20, w = 152, h = 44 }, dimen)
        end
        UIManager.forceRePaint = function() events[#events + 1] = "refresh" end
        UIManager.yieldToEPDC = function()
            events[#events + 1] = "yield"
            assert.are.equal("white", title_bar.title_widget.fgcolor)
            assert.is_true(title_bar.back_button.image.invert)
        end
        local flash_ui_disabled = false
        G_reader_settings = { isFalse = function(_self, key)
            assert.are.equal("flash_ui", key)
            return flash_ui_disabled
        end }

        assert.is_true(title_bar:onTapBackTitle())
        assert.are.same({
            { 20, 20, 152, 44, "black", 8 },
            { 20, 20, 152, 44, "white", 8 },
        }, paints)
        assert.are.same({ "icon", "title", "refresh", "yield", "icon", "title",
            "back", "refresh" }, events)

        paints, events = {}, {}
        flash_ui_disabled = true
        assert.is_true(title_bar.back_button:onTapIconButton())
        assert.are.same({}, paints)
        assert.are.same({ "back" }, events)
    end)

    it("refreshes when the network connects, disconnects, or finishes changing", function()
        local title_bar, refreshes = make_title_bar()

        SettingsTitleBar.onNetworkConnected(title_bar)
        SettingsTitleBar.onNetworkDisconnected(title_bar)
        SettingsTitleBar.onNetworkStateChanged(title_bar)

        assert.are.equal(3, refreshes())
    end)

    it("rebuilds a covered settings status row before it is painted again", function()
        local title_bar, refreshes, owner = make_title_bar()
        local UIManager = require("ui/uimanager")
        local InputContainer = require("ui/widget/container/inputcontainer")
        local painted, builds = {}, 0
        local changing = true
        title_bar.width = 600
        title_bar.status_widget = { solid_wifi = false }
        title_bar._vertical_group = { [2] = title_bar.status_widget }
        title_bar[1] = { getSize = function() return { w = 600, h = 80 } end }
        title_bar.status_factory = function()
            builds = builds + 1
            return { solid_wifi = not changing }
        end
        setmetatable(title_bar, SettingsTitleBar)
        require("common/widget_resources").replaceChild = function(container, index, widget)
            container[index] = widget
        end
        InputContainer.paintTo = function(self)
            painted[#painted + 1] = self.status_widget.solid_wifi
        end
        ZenSpec.replace("apps/filemanager/filemanager", {
            instance = { _updateStatusBar = function() end },
        })
        UIManager._window_stack = { { widget = owner }, { widget = { covers_fullscreen = true } } }

        changing = false
        title_bar:onNetworkConnected()
        title_bar:onNetworkStateChanged()
        assert.are.equal(0, refreshes())
        assert.are.equal(0, builds)

        table.remove(UIManager._window_stack)
        local paint = SettingsTitleBar.paintTo or InputContainer.paintTo
        paint(title_bar)
        paint(title_bar)
        assert.are.same({ true, true }, painted)
        assert.are.equal(1, builds)

        title_bar:onNetworkDisconnected()
        title_bar:refreshStatus()
        paint(title_bar)
        assert.are.equal(2, builds)
    end)

    it("debounces charging changes and cancels the timer when cleared", function()
        local title_bar, refreshes, owner = make_title_bar()

        SettingsTitleBar.onCharging(title_bar)
        local first_callback = scheduled[1].callback
        SettingsTitleBar.onNotCharging(title_bar)

        assert.are.equal(2, #scheduled)
        assert.are.equal(1.5, scheduled[2].delay)
        assert.are.equal(first_callback, unscheduled[1])

        scheduled[2].callback()
        assert.are.equal(1, refreshes())

        SettingsTitleBar.onCharging(title_bar)
        local pending_callback = scheduled[3].callback
        SettingsTitleBar.clearStatusRefresh(title_bar)

        assert.are.equal(pending_callback, unscheduled[2])
        assert.is_nil(title_bar._zen_status_charging_refresh_timer)
        assert.is_nil(owner._zen_status_refresh)
    end)

    it("leaves device events to the active file manager dispatcher", function()
        local title_bar, refreshes = make_title_bar()
        ZenSpec.replace("apps/filemanager/filemanager", {
            instance = { _updateStatusBar = function() end },
        })

        SettingsTitleBar.onNetworkConnected(title_bar)
        SettingsTitleBar.onNetworkStateChanged(title_bar)
        SettingsTitleBar.onCharging(title_bar)

        assert.are.equal(0, refreshes())
        assert.are.equal(0, #scheduled)
    end)
end)
