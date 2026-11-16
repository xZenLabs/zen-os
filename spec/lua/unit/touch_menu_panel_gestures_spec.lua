describe("TouchMenu panel gestures", function()
    local TouchMenu
    local existing_menu
    local original_modules

    local module_names = {
        "ffi/blitbuffer",
        "ffi/util",
        "device",
        "gettext",
        "optmath",
        "ui/event",
        "ui/geometry",
        "ui/gesturerange",
        "ui/uimanager",
        "ui/widget/focusmanager",
        "ui/widget/touchmenu",
        "common/shared_state",
        "common/ui/zen_slider",
        "common/ui/button_feedback",
        "modules/menu/patches/touch_menu_panel",
    }

    local function new_menu()
        local menu = setmetatable({}, { __index = TouchMenu })
        menu:init()
        return menu
    end

    local function pan_registration_count(menu)
        local count = 0
        for _name, sequence in pairs(menu.ges_events) do
            for _i, range in ipairs(sequence) do
                if range.ges == "pan" then count = count + 1 end
            end
        end
        return count
    end

    before_each(function()
        original_modules = {}
        for _i, name in ipairs(module_names) do
            original_modules[name] = package.loaded[name] or false
        end

        TouchMenu = {
            init = function(self)
                self.screen_size = { w = 600, h = 800 }
                self.dimen = { x = 0, y = 0, w = 600, h = 400 }
                self.ges_events = {
                    Pan = {{ ges = "pan", range = self.dimen }},
                    Swipe = {{ ges = "swipe", range = self.dimen }},
                }
                self.bar = { icon_widgets = {} }
            end,
            updateItems = function(self)
                self.stock_updates = (self.stock_updates or 0) + 1
            end,
            onPan = function(self)
                self.stock_pans = (self.stock_pans or 0) + 1
                return true
            end,
            onSwipe = function(self, arg, ges)
                self.stock_swipes = (self.stock_swipes or 0) + 1
                if ges.direction == "north" then self.closed = true end
                return true
            end,
            onMultiSwipe = function() end,
            onTapCloseAllMenus = function() end,
            onSetRotationMode = function() end,
            onSetDimensions = function() end,
            onScreenResize = function() end,
            onCloseWidget = function() end,
            onPrevPage = function() end,
            onNextPage = function() end,
            switchMenuTab = function(self) self.stock_switches = (self.stock_switches or 0) + 1 end,
        }
        existing_menu = new_menu()

        ZenSpec.replace("ffi/blitbuffer", {})
        ZenSpec.replace("ffi/util", { template = function(text) return text end })
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
                scaleBySize = function(_self, value) return value end,
            },
        })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("optmath", { round = function(value) return math.floor(value + 0.5) end })
        ZenSpec.replace("ui/event", { new = function(_self, name) return { name = name } end })
        ZenSpec.replace("ui/geometry", {
            new = function(_self, values) return values end,
        })
        ZenSpec.replace("ui/gesturerange", {
            new = function(_self, values) return values end,
        })
        ZenSpec.replace("ui/uimanager", {
            scheduleIn = function() end,
            setDirty = function() end,
        })
        ZenSpec.replace("ui/widget/focusmanager", { NOT_FOCUS = 0 })
        ZenSpec.replace("ui/widget/touchmenu", TouchMenu)
        ZenSpec.replace("common/shared_state", { get = function() end })
        ZenSpec.replace("common/ui/button_feedback", { flashButton = function() end })
        ZenSpec.unload("common/ui/zen_slider")
        ZenSpec.unload("modules/menu/patches/touch_menu_panel")
        require("modules/menu/patches/touch_menu_panel").install({})
    end)

    after_each(function()
        for _i, name in ipairs(module_names) do
            package.loaded[name] = original_modules[name] or nil
        end
    end)

    local function controls_menu()
        local menu = new_menu()
        local slider = require("common/ui/zen_slider"):new{
            width = 300, value = 50, value_min = 0, value_max = 100,
        }
        slider.dimen.x, slider.dimen.y = 20, 100
        menu.item_table = { id = "quicksettings", panel = true }
        menu._zen_panel_refs = { sliders = {{ slider = slider }} }
        return menu, slider
    end

    it("resets an active panel without running native switching callbacks", function()
        local menu, slider = controls_menu()
        local tab = menu.item_table
        menu.tab_item_table, menu.cur_tab = { tab }, 1
        menu.updateItems = function(self, page) self.reset_page = page end
        local changed = true
        menu._zen_panel_refs.reset = function() return changed end
        menu:switchMenuTab(1)
        assert.is_nil(menu.stock_switches)
        assert.are.equal(1, menu.reset_page)
        assert.are.equal(50, slider:getValue())
        changed, menu.reset_page = false, nil
        menu:switchMenuTab(1)
        assert.is_nil(menu.reset_page)
        menu.tab_item_table[2] = {}
        menu:switchMenuTab(2)
        assert.are.equal(1, menu.stock_switches)
    end)

    it("cancels pending slider previews when a panel closes or rebuilds", function()
        local menu = controls_menu()
        local canceled = 0
        menu._zen_panel_refs.sliders[1].cancel = function() canceled = canceled + 1 end
        menu.item_table = {}
        menu:updateItems(1)
        assert.are.equal(1, canceled)
        menu._zen_panel_refs = { sliders = {{ cancel = function() canceled = canceled + 1 end }} }
        menu:onCloseWidget()
        assert.are.equal(2, canceled)
        assert.is_nil(menu._zen_panel_refs)
    end)

    it("returns an active native tab to its first page or root without switching callbacks", function()
        local menu = new_menu()
        local tab = {}
        menu.tab_item_table, menu.cur_tab, menu.item_table, menu.page = { tab }, 1, tab, 2
        menu.updateItems = function(self, page) self.reset_page = page; self.page = page end
        menu:switchMenuTab(1)
        assert.are.equal(1, menu.reset_page)
        assert.is_nil(menu.stock_switches)
        menu.reset_page = nil
        menu:switchMenuTab(1)
        assert.is_nil(menu.reset_page)
        menu.item_table, menu.item_table_stack = {}, { tab }
        menu:switchMenuTab(1)
        assert.are.equal(tab, menu.item_table)
        assert.are.same({}, menu.item_table_stack)
        assert.is_nil(menu.stock_switches)
    end)

    it("closes controls on an upward swipe without changing a slider or activating a button", function()
        local menu, slider = controls_menu()
        menu._zen_panel_refs.buttons = {{
            widget = { dimen = {} },
            callback = function() error("swipe must not activate a button") end,
        }}
        local ges = { direction = "north", pos = { x = 300, intersectWith = function() return true end } }

        assert.is_true(menu:onSwipe(nil, ges))
        assert.is_true(menu.closed)
        assert.are.equal(1, menu.stock_swipes)
        assert.are.equal(50, slider:getValue())
    end)

    it("keeps controls locked against swipes while opening", function()
        local menu, slider = controls_menu()
        menu._zen_panel_locked = true
        local pos = { x = 170, intersectWith = function() return true end }

        assert.is_true(menu:onSwipe(nil, { direction = "north", pos = pos }))
        assert.is_true(menu:onSwipe(nil, { direction = "east", distance = 50, pos = pos }))
        assert.is_nil(menu.closed)
        assert.is_nil(menu.stock_swipes)
        assert.are.equal(50, slider:getValue())
    end)

    it("keeps horizontal slider swipes in controls", function()
        local menu, slider = controls_menu()
        local ges = {
            direction = "east", distance = 50,
            pos = { x = 170, intersectWith = function() return true end },
        }

        assert.is_true(menu:onSwipe(nil, ges))
        assert.is_true(slider:getValue() > 50)
        assert.is_nil(menu.closed)
        assert.is_nil(menu.stock_swipes)
    end)

    it("activates panel buttons and toggles without flashing", function()
        local menu, events = new_menu(), {}
        local region = { x = 20, y = 30, w = 40, h = 40 }
        require("common/ui/button_feedback").flashButton = function() error("panel must not flash") end
        local callback = function() events[#events + 1] = "callback" end
        menu.item_table = { panel = true }
        menu._zen_panel_refs = { buttons = {{ widget = { dimen = region }, callback = callback }} }
        local ges = { pos = { intersectWith = function() return true end } }
        assert.is_true(menu:onTapCloseAllMenus(nil, ges))
        assert.are.same({ "callback" }, events)
        events = {}
        menu._zen_panel_refs = { toggles = {{ toggle = { dimen = region }, callback = callback }} }
        assert.is_true(menu:onTapCloseAllMenus(nil, ges))
        assert.are.same({ "callback" }, events)
    end)

    it("repairs a TouchMenu created before the patch is installed", function()
        existing_menu.item_table = {}
        existing_menu:updateItems()

        assert.are.equal("PanCloseAllMenus", existing_menu.ges_events.Pan.event)
        assert.is_true(existing_menu.ges_events.Pan[1].range == existing_menu.dimen)
        assert.is_table(existing_menu.ges_events.PanReleaseCloseAllMenus)
        assert.is_nil(existing_menu.ges_events.PanCloseAllMenus)
        assert.are.equal(1, pan_registration_count(existing_menu))
    end)

    it("preserves tap feedback on every top menu tab, including Home", function()
        existing_menu.item_table = {}
        existing_menu.tab_item_table = {
            { id = "app_launcher", panel = true },
            { id = "quicksettings", panel = true },
            { id = "reader_controls", panel = true },
            { id = "settings" },
            { id = "zen_library_home", remember = false },
        }
        existing_menu.bar.icon_widgets = {
            { allow_flash = true }, { allow_flash = true }, { allow_flash = true },
            { allow_flash = true }, { allow_flash = true },
        }

        existing_menu:updateItems()

        for _i, button in ipairs(existing_menu.bar.icon_widgets) do
            assert.is_true(button.allow_flash)
        end
    end)

    it("routes the sole pan registration to sliders and preserves stock fallback", function()
        local slider_pans = 0
        local menu = new_menu()
        assert.are.equal(1, pan_registration_count(menu))
        assert.are.equal("PanCloseAllMenus", menu.ges_events.Pan.event)
        menu:init()
        assert.are.equal(1, pan_registration_count(menu))
        assert.are.equal("PanCloseAllMenus", menu.ges_events.Pan.event)

        menu.item_table = { panel = true }
        menu._zen_panel_refs = {
            sliders = {{
                slider = {
                    handlePan = function()
                        slider_pans = slider_pans + 1
                        return true
                    end,
                },
            }},
        }
        assert.is_true(menu:onPanCloseAllMenus(nil, { direction = "west" }))
        assert.is_true(menu:onPanCloseAllMenus(nil, { direction = "east" }))
        assert.are.equal(2, slider_pans)
        assert.is_nil(menu.stock_pans)

        menu.item_table = {}
        menu._zen_panel_refs = nil
        assert.is_true(menu:onPanCloseAllMenus(nil, { mousewheel_direction = true }))
        assert.are.equal(1, menu.stock_pans)
    end)

    it("keeps launcher pagination cycling and omits the Reader controls footer", function()
        local enabled = {}
        local menu = new_menu()
        local page = 1
        menu.item_group = {
            clear = function(self) for i = #self, 1, -1 do self[i] = nil end end,
            getSize = function() return { h = 400 } end,
        }
        menu.footer_top_margin = {}
        menu.footer = { { dimen = { h = 58 } }, resetLayout = function() end }
        menu.page_info_text = { setText = function() end }
        menu.page_info = { resetLayout = function() end }
        menu.page_info_left_chev = {
            showHide = function() end,
            enableDisable = function(_self, value) enabled.left = value end,
        }
        menu.page_info_right_chev = {
            showHide = function() end,
            enableDisable = function(_self, value) enabled.right = value end,
        }
        menu.width, menu.bordersize, menu.padding, menu.cur_tab = 600, 0, 0, 1
        menu.dimen = {
            h = 400,
            copy = function(self) return { h = self.h } end,
        }
        menu.moveFocusTo = function() end
        menu.item_table = {
            id = "app_launcher",
            panel = function(self)
                self._zen_panel_refs = { page = page, page_num = 3 }
                if self.item_table.id == "reader_controls" then
                    self._zen_panel_refs.bottom_tabs = {}
                    self._zen_panel_refs.tab_layout = {}
                end
                return {}
            end,
        }

        menu:updateItems()
        assert.are.same({ left = true, right = true }, enabled)
        assert.are.equal(58, menu.footer[1].dimen.h)
        menu.item_table.id = "reader_controls"
        menu:updateItems()
        assert.are.equal(58, menu.footer[1].dimen.h)
        assert.are.same({ left = false, right = true }, enabled)
        local footer_visible, pagination_visible = false, false
        for _i, widget in ipairs(menu.item_group) do
            footer_visible = footer_visible or widget == menu.footer
            pagination_visible = pagination_visible or widget == menu.page_info
        end
        assert.is_false(footer_visible)
        assert.is_true(pagination_visible)
        menu.item_table.id = "app_launcher"
        page = 3
        menu:updateItems()
        assert.are.same({ left = true, right = true }, enabled)
        assert.are.equal(58, menu.footer[1].dimen.h)
    end)

    it("clears underlying text with color refreshes only when the accent is enabled", function()
        local Device = require("device")
        local screen = Device.screen
        local config = { accent_color = "#204080" }
        require("modules/menu/patches/touch_menu_panel").install({ config = config })
        local menu = new_menu()
        local region = { x = 0, y = 0, w = 600, h = 400 }
        menu.dimen = {
            h = 400,
            copy = function() return { h = 400, combine = function() return region end } end,
        }
        menu.item_group = { clear = function() end, getSize = function() return { h = 400 } end }
        menu.footer_top_margin, menu.footer = {}, {}
        menu.page_info_text = { setText = function() end }
        menu.page_info_left_chev = { showHide = function() end, enableDisable = function() end }
        menu.page_info_right_chev = menu.page_info_left_chev
        menu.width, menu.bordersize, menu.padding, menu.cur_tab = 600, 0, 0, 1
        menu.moveFocusTo = function() end
        menu.item_table = { panel = {} }
        menu._zen_panel_refs = {}
        local refresh
        local UIManager = require("ui/uimanager")
        UIManager.setDirty = function(_self, _owner, callback) refresh = callback end

        for _i, case in ipairs({
            { true, "#204080", true, "full", false },
            { true, "#204080", false, "ui", false },
            { true, "#204080", false, "ui", false, true },
            { true, "#204080", false, "partial", true, true, true },
            { true, "#204080", true, "full", false, true },
            { true, "#204080", true, "full", true, true, true },
            { true, "#204080", false, "ui", false, false, false, true },
            { true, "#204080", false, "partial", true, false, true, true },
            { true, "#204080", true, "full", false, false, false, true },
            { true, "#204080", true, "full", true, false, true, true },
            { true, "#000000", true, "flashui", false },
            { true, "#000000", false, "ui", false },
            { false, "#204080", true, "flashui", false },
            { false, "#204080", false, "ui", false },
        }) do
            screen.isColorScreen = function() return case[1] end
            Device.isKindle = function() return case[6] == true end
            Device.isKobo = function() return case[8] == true end
            screen.night_mode = case[7] == true
            config.accent_color, menu.is_fresh = case[2], case[3]
            menu:updateItems()
            if case[1] and case[2] ~= "#000000" then menu.is_fresh = false end -- Background hatching clears it in onShow.
            local mode, refreshed, dither = refresh()
            assert.are.equal(case[4], mode)
            assert.are.equal(region, refreshed)
            assert.are.equal(case[5], dither)
            assert.is_false(menu.is_fresh)
        end

        screen.night_mode = false
        local launcher = { id = "app_launcher", panel = {} }
        local controls = { id = "quicksettings", panel = {} }
        for _i, case in ipairs({
            { true, "#204080", "partial", true },
            { true, "#000000", "ui", false },
            { false, "#204080", "ui", false },
        }) do
            screen.isColorScreen = function() return case[1] end
            config.accent_color = case[2]
            for _j, height in ipairs({ 300, 600, 700 }) do
                menu.item_table = launcher
                menu.item_group.getSize = function() return { h = 600 } end
                menu:updateItems()
                local mode, refreshed, dither = refresh()
                assert.are.equal(case[3], mode)
                assert.are.equal(region, refreshed)
                assert.are.equal(case[4], dither)

                menu:updateItems()
                assert.are.equal("ui", refresh())

                menu.item_table = controls
                menu.item_group.getSize = function() return { h = height } end
                menu:updateItems()
                mode, refreshed, dither = refresh()
                assert.are.equal(case[3], mode)
                assert.are.equal(region, refreshed)
                assert.are.equal(case[4], dither)

                menu:updateItems()
                assert.are.equal("ui", refresh())
            end
        end

        -- Section and page swaps inside one panel tab use a dithered partial, no flash.
        screen.isColorScreen = function() return true end
        config.accent_color = "#204080"
        local view, view_page = "font", 1
        menu.item_table = { id = "reader_controls", panel = function(self)
            self._zen_panel_refs = { view = view, view_page = view_page }
            return {}
        end }
        menu:updateItems()
        refresh()
        for _i, case in ipairs({ { "font", 1, "ui", false }, { "page", 1, "partial", true },
                { "page", 2, "partial", true }, { "page", 2, "ui", false } }) do
            view, view_page = case[1], case[2]
            menu:updateItems()
            local mode, _region, dither = refresh()
            assert.are.equal(case[3], mode)
            assert.are.equal(case[4], dither)
        end
        config.accent_color = "#000000"
        view = "themes"
        menu:updateItems()
        assert.are.equal("ui", refresh())
    end)
end)
