describe("Quickstart reader tour", function()
    local shown, plugin, opens

    local function start()
        return require("common/quickstart/reader_tour").start(
            plugin, {}, function(layout)
                opens[#opens + 1] = { layout = layout }
            end)
    end

    before_each(function()
        shown = {}
        opens = {}

        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/uimanager", {
            show = function(_self, widget) shown[#shown + 1] = widget end,
            scheduleIn = function() end,
        })
        ZenSpec.replace("common/quickstart/menu_coachmark", {
            new = function(_self, spec) return spec end,
        })

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

    it("shows only the swipe coachmark and clears the flag when shown", function()
        assert.is_true(start())
        assert.are.equal(1, #shown)
        assert.are.equal(1, #shown[1].steps)
        assert.are.equal("Swipe up to open the Page Browser", shown[1].steps[1].text)
        assert.are.equal("bottom", shown[1].steps[1].position)
        assert.is_true(shown[1].steps[1].swipe_up)
        assert.is_nil(shown[1].steps[1].target)
        assert.is_false(plugin.config._meta.quickstart_reader_tour_pending)
        assert.is_false(plugin.config._meta.quickstart_menu_tour_pending)
        assert.are.equal(1, plugin.save_calls)

        shown[1].on_complete()
        assert.are.equal(1, #opens)
        assert.is_nil(opens[1].layout)
        assert.are.equal(1, #shown)
    end)

    it("does not reshow after cancel", function()
        assert.is_true(start())
        shown[1].on_cancel()
        assert.is_false(start())
        assert.are.equal(1, #shown)
        assert.are.equal(0, #opens)
    end)
end)
