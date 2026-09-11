describe("Quickstart reader tour", function()
    local shown, scheduled, plugin, browser, opened_layout, grid_switches, browser_closes

    local function run_next(delay)
        local task = table.remove(scheduled, 1)
        assert.is_table(task)
        assert.are.equal(delay, task.delay)
        task.callback()
    end

    before_each(function()
        shown = {}
        scheduled = {}
        opened_layout = nil
        grid_switches = 0
        browser_closes = 0

        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/uimanager", {
            show = function(_self, widget) shown[#shown + 1] = widget end,
            scheduleIn = function(_self, delay, callback)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end,
            forceRePaint = function() end,
        })
        ZenSpec.replace("common/quickstart/menu_coachmark", {
            new = function(_self, spec) return spec end,
        })

        local function button(x)
            return { image = { dimen = { x = x, y = 20, w = 32, h = 32 } } }
        end
        browser = {
            _zen_reader_tour_targets = { button(210), button(270), button(330) },
            _zen_btn_group = { dimen = { x = 205, y = 704, w = 180, h = 48 } },
            _zen_grid_dimen = { x = 0, y = 70, w = 600, h = 590 },
            _zen_btn_view_zone = { x = 190, y = 700, w = 70, h = 48 },
            _zen_btn_grid_zone = { x = 330, y = 700, w = 70, h = 48 },
            _zen_switch_grid = function() grid_switches = grid_switches + 1 end,
        }
        plugin = {
            config = { _meta = {
                quickstart_menu_tour_pending = false,
                quickstart_reader_tour_pending = true,
            } },
            saveConfig = function(self) self.save_calls = (self.save_calls or 0) + 1 end,
        }
        ZenSpec.unload("common/quickstart/reader_tour")
    end)

    after_each(function()
        ZenSpec.unload("common/quickstart/reader_tour")
    end)

    it("runs independently through reader, header, and layout coachmarks", function()
        local started = require("common/quickstart/reader_tour").start(
            plugin, {}, function(layout)
                opened_layout = layout
                return browser, function() browser_closes = browser_closes + 1 end
            end)

        assert.is_true(started)
        assert.are.equal("Swipe up to open the Page Browser", shown[1].steps[1].text)
        assert.are.equal("bottom", shown[1].steps[1].position)
        assert.is_nil(shown[1].steps[1].target)

        shown[1].on_complete()
        assert.are.equal("carousel", opened_layout)
        assert.is_true(plugin.config._meta.quickstart_reader_tour_pending)
        run_next(0.1)

        assert.are.equal(3, #shown[2].steps)
        assert.are.equal("Reader menu", shown[2].steps[1].text)
        assert.are.equal("Bookmarks", shown[2].steps[2].text)
        assert.are.equal("Table of contents", shown[2].steps[3].text)
        assert.are.equal(browser._zen_reader_tour_targets[2].image.dimen,
            shown[2].steps[2].target)

        shown[2].on_complete()
        assert.are.equal(1, grid_switches)
        run_next(0.1)

        assert.are.equal("Change page browser view to single, coverflow, or grid",
            shown[3].steps[1].text)
        assert.are.equal(browser._zen_btn_group.dimen, shown[3].steps[1].target)
        assert.are.equal(browser._zen_grid_dimen, shown[3].steps[1].unhatched)
        assert.is_true(plugin.config._meta.quickstart_reader_tour_pending)

        shown[3].on_complete()
        assert.is_false(plugin.config._meta.quickstart_reader_tour_pending)
        assert.is_false(plugin.config._meta.quickstart_menu_tour_pending)
        assert.are.equal(1, plugin.save_calls)
        assert.are.equal(1, browser_closes)
    end)
end)
