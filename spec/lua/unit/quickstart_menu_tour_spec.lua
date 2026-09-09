describe("Quickstart menu tour", function()
    local saved_modules
    local scheduled
    local shown
    local coachmark_specs
    local gettext_inputs
    local menu
    local touch_menu
    local zen_dimen
    local zen_settings_dimen
    local plugin

    local module_names = {
        "apps/filemanager/filemanager",
        "common/quickstart/menu_coachmark",
        "common/quickstart/menu_tour",
        "gettext",
        "ui/uimanager",
    }

    local function run_next_scheduled()
        local task = table.remove(scheduled, 1)
        assert.is_table(task)
        assert.are.equal(0.1, task.delay)
        task.callback()
    end

    local function run_until_shown()
        for _i = 1, 10 do
            if #shown > 0 then return end
            run_next_scheduled()
        end
        assert.fail("menu tour coachmark was not shown")
    end

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(module_names) do
            saved_modules[name] = package.loaded[name]
        end

        scheduled = {}
        shown = {}
        coachmark_specs = {}
        gettext_inputs = {}

        ZenSpec.replace("gettext", function(text)
            gettext_inputs[#gettext_inputs + 1] = text
            return text
        end)
        ZenSpec.replace("ui/uimanager", {
            scheduleIn = function(_self, delay, callback)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end,
            show = function(_self, widget)
                shown[#shown + 1] = widget
            end,
            forceRePaint = function() end,
        })

        local Coachmark = {}
        function Coachmark:new(spec)
            coachmark_specs[#coachmark_specs + 1] = spec
            return spec
        end
        ZenSpec.replace("common/quickstart/menu_coachmark", Coachmark)

        zen_dimen = { w = 64, h = 64 }
        zen_settings_dimen = { w = 48, h = 48 }
        local other_button_dimen = { x = 18, y = 90, w = 64, h = 64 }
        local other_tab_dimen = { x = 20, y = 10, w = 48, h = 48 }
        local quicksettings_tab_dimen = { x = 500, y = 10, w = 48, h = 48 }

        touch_menu = {
            updateItems = function(self, page)
                self.updated_page = page
            end,
            _zen_panel_refs = {
                buttons = {
                    { id = "sleep", widget = { dimen = other_button_dimen } },
                    { id = "zen", widget = { dimen = zen_dimen } },
                    { id = "wifi", widget = { dimen = { x = 170, y = 90, w = 64, h = 64 } } },
                },
            },
            bar = {
                icon_widgets = {
                    { dimen = other_tab_dimen },
                    {
                        dimen = { x = 390, y = 4, w = 104, h = 60 },
                        image = { dimen = zen_settings_dimen },
                    },
                    { dimen = quicksettings_tab_dimen },
                },
            },
        }

        local tabs = {
            { id = "history" },
            { id = "zen_ui" },
            { id = "quicksettings" },
        }
        menu = {
            setUpdateItemTable = function(self)
                self.set_update_calls = (self.set_update_calls or 0) + 1
                self.tab_item_table = tabs
            end,
            onShowMenu = function(self, tab_index)
                self.show_calls = (self.show_calls or 0) + 1
                self.opened_tab_index = tab_index
                touch_menu.tab_item_table = self.tab_item_table
                touch_menu.cur_tab = tab_index
                self.menu_container = { touch_menu }
            end,
        }

        plugin = {
            config = {
                _meta = { quickstart_menu_tour_pending = true },
            },
            ui = { menu = menu },
            saveConfig = function(self)
                self.save_calls = (self.save_calls or 0) + 1
            end,
        }
        ZenSpec.replace("apps/filemanager/filemanager", { instance = { menu = menu } })
        ZenSpec.unload("common/quickstart/menu_tour")
    end)

    after_each(function()
        ZenSpec.unload("common/quickstart/menu_tour")
        for _i, name in ipairs(module_names) do
            package.loaded[name] = saved_modules[name]
        end
    end)

    it("waits for painted reordered targets and builds the two exact steps", function()
        require("common/quickstart/menu_tour").start(plugin)

        assert.are.equal(1, menu.set_update_calls)
        assert.are.equal(1, menu.show_calls)
        assert.are.equal(3, menu.opened_tab_index)
        assert.are.equal(0, #shown)
        assert.are.equal(1, #scheduled)

        run_next_scheduled()
        assert.are.equal(0, #shown)
        assert.are.equal(1, #scheduled)

        zen_dimen.x, zen_dimen.y = 94, 90
        zen_settings_dimen.x, zen_settings_dimen.y = 418, 10
        run_until_shown()

        assert.are.equal(1, #coachmark_specs)
        assert.are.equal(coachmark_specs[1], shown[1])
        assert.are.same({
            "Zen Mode is enabled. KOReader menus are hidden.",
            "Disable Zen Mode with this icon to adjust KOReader settings that aren’t available in Zen Settings.",
            "This does not disable ZenOS—it only shows or hides KOReader’s menus.",
            "This is Zen Settings. ZenOS settings/updates and common KOReader settings live here.",
        }, gettext_inputs)
        assert.are.equal(2, #shown[1].steps)
        assert.are.same({
            text = "Zen Mode is enabled. KOReader menus are hidden.\n\n"
                .. "Disable Zen Mode with this icon to adjust KOReader settings "
                .. "that aren’t available in Zen Settings.\n\nThis does not disable "
                .. "ZenOS—it only shows or hides KOReader’s menus.",
            target = zen_dimen,
        }, shown[1].steps[1])
        assert.are.same({
            text = "This is Zen Settings. ZenOS settings/updates and common KOReader settings live here.",
            target = zen_settings_dimen,
        }, shown[1].steps[2])
    end)

    it("clears the pending marker and saves when the coachmark completes", function()
        zen_dimen.x, zen_dimen.y = 94, 90
        zen_settings_dimen.x, zen_settings_dimen.y = 418, 10

        require("common/quickstart/menu_tour").start(plugin)
        run_until_shown()
        shown[1].on_complete()

        assert.is_false(plugin.config._meta.quickstart_menu_tour_pending)
        assert.are.equal(1, plugin.save_calls)
        assert.are.equal(1, touch_menu.updated_page)

        local scheduled_before = #scheduled
        local shown_before = #shown
        local menu_shows_before = menu.show_calls
        require("common/quickstart/menu_tour").start(plugin)

        assert.are.equal(scheduled_before, #scheduled)
        assert.are.equal(shown_before, #shown)
        assert.are.equal(menu_shows_before, menu.show_calls)
        assert.are.equal(1, plugin.save_calls)
    end)

    it("reuses an already-open menu instead of stacking another container", function()
        menu:setUpdateItemTable()
        menu.menu_container = { touch_menu }
        touch_menu.tab_item_table = menu.tab_item_table
        local quicksettings_switches = 0
        touch_menu.bar.icon_widgets[3].callback = function()
            quicksettings_switches = quicksettings_switches + 1
            touch_menu.cur_tab = 3
        end
        package.loaded["ui/uimanager"].isWidgetShown = function(_self, widget)
            return widget == menu.menu_container
        end

        require("common/quickstart/menu_tour").start(plugin)

        assert.are.equal(1, quicksettings_switches)
        assert.is_nil(menu.show_calls)
        assert.are.equal(1, #scheduled)
    end)

    it("forces Controls when the Launcher overrides the requested opening tab", function()
        local controls_switches = 0
        menu.onShowMenu = function(self, tab_index)
            self.show_calls = (self.show_calls or 0) + 1
            self.opened_tab_index = tab_index
            touch_menu.tab_item_table = self.tab_item_table
            touch_menu.cur_tab = 1
            touch_menu.switchMenuTab = function(t_self, index)
                controls_switches = controls_switches + 1
                t_self.cur_tab = index
            end
            self.menu_container = { touch_menu }
        end

        require("common/quickstart/menu_tour").start(plugin)

        assert.are.equal(3, menu.opened_tab_index)
        assert.are.equal(1, controls_switches)
        assert.are.equal(3, touch_menu.cur_tab)
        assert.are.equal(1, #scheduled)
    end)

    it("keeps the tour pending and schedules a retry when the coachmark is cancelled", function()
        zen_dimen.x, zen_dimen.y = 94, 90
        zen_settings_dimen.x, zen_settings_dimen.y = 418, 10

        require("common/quickstart/menu_tour").start(plugin)
        run_until_shown()
        shown[1].on_cancel()

        assert.is_true(plugin.config._meta.quickstart_menu_tour_pending)
        assert.is_nil(plugin.save_calls)
        assert.are.equal(1, #scheduled)
        assert.are.equal(0.5, scheduled[1].delay)
    end)

    it("does nothing unless the pending marker is exactly true", function()
        plugin.config._meta.quickstart_menu_tour_pending = nil

        require("common/quickstart/menu_tour").start(plugin)

        assert.is_nil(menu.set_update_calls)
        assert.is_nil(menu.show_calls)
        assert.are.equal(0, #scheduled)
        assert.are.equal(0, #shown)
        assert.is_nil(plugin.save_calls)
    end)
end)
