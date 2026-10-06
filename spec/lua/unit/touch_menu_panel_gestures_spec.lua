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
            onSwipe = function() end,
            onMultiSwipe = function() end,
            onTapCloseAllMenus = function() end,
            onSetRotationMode = function() end,
            onSetDimensions = function() end,
            onScreenResize = function() end,
            onCloseWidget = function() end,
            onPrevPage = function() end,
            onNextPage = function() end,
        }
        existing_menu = new_menu()

        ZenSpec.replace("ffi/blitbuffer", {})
        ZenSpec.replace("ffi/util", { template = function(text) return text end })
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
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

    it("keeps launcher page controls enabled at both ends", function()
        local enabled = {}
        local menu = new_menu()
        local page = 1
        menu.item_group = {
            clear = function() end,
            getSize = function() return { h = 400 } end,
        }
        menu.footer_top_margin = {}
        menu.footer = {}
        menu.page_info_text = { setText = function() end }
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
                return {}
            end,
        }

        menu:updateItems()
        assert.are.same({ left = true, right = true }, enabled)
        page = 3
        menu:updateItems()
        assert.are.same({ left = true, right = true }, enabled)
    end)
end)
