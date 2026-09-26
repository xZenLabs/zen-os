describe("Advanced settings", function()
    before_each(function()
        _G.G_reader_settings = ZenSpec.memorySettings()
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/uimanager", {
            show = function() end,
        })
        ZenSpec.replace("modules/settings/zen_settings_utils", {})
        ZenSpec.replace("common/paths", {})
        ZenSpec.unload("modules/settings/sections/advanced_settings")
    end)

    it("does not expose the old Reader margins action", function()
        local items = require("modules/settings/sections/advanced_settings").build({
            config = { features = {}, developer = {} },
            plugin = { saveConfig = function() end },
            settings_apply = { prompt_restart = function() end },
        })
        for _i, item in ipairs(items) do
            assert.are_not.equal("Enable ZenOS Reader margins", item.text)
        end
    end)

    it("keeps settings open when clearing gestures", function()
        local items = require("modules/settings/sections/advanced_settings").build({
            config = { features = {}, developer = {} },
            plugin = { saveConfig = function() end },
            settings_apply = { prompt_restart = function() end },
        })
        local clear_gestures
        for _i, item in ipairs(items) do
            if item.text == "Clear all gestures" then
                clear_gestures = item
                break
            end
        end

        assert.is_true(clear_gestures.keep_menu_open)
    end)

    it("toggles double-tap book opening", function()
        local saved = 0
        local config = { features = {}, developer = {} }
        local items = require("modules/settings/sections/advanced_settings").build({
            config = config,
            plugin = { saveConfig = function() saved = saved + 1 end },
            settings_apply = { prompt_restart = function() end },
        })
        local double_tap_item
        for _i, item in ipairs(items) do
            if item.text == "Require double tap to open books" then
                double_tap_item = item
                break
            end
        end

        assert.is_table(double_tap_item)
        assert.is_false(double_tap_item.checked_func())
        double_tap_item.checkmark_callback()
        assert.is_true(double_tap_item.checked_func())
        assert.are.equal(1, saved)

        local single_tap_item = double_tap_item.sub_item_table[1]
        assert.are.equal("Single tap to open context menu", single_tap_item.text)
        assert.is_true(single_tap_item.enabled_func())
        assert.is_false(single_tap_item.checked_func())
        single_tap_item.callback()
        assert.is_true(single_tap_item.checked_func())
        assert.are.equal(2, saved)
        double_tap_item.checkmark_callback()
        assert.is_false(single_tap_item.enabled_func())
        assert.are.equal(3, saved)
    end)

    it("enables modal dragging only after an explicit toggle", function()
        local saved, restart_prompts = 0, 0
        local config = { features = {}, developer = {} }
        local items = require("modules/settings/sections/advanced_settings").build({
            config = config,
            plugin = { saveConfig = function() saved = saved + 1 end },
            settings_apply = {
                prompt_restart = function() restart_prompts = restart_prompts + 1 end,
            },
        })
        local drag_item
        for _i, item in ipairs(items) do
            if item.text == "Allow dragging reader modals" then drag_item = item end
        end

        assert.is_false(drag_item.checked_func())
        drag_item.callback()
        assert.is_true(drag_item.checked_func())
        assert.are.equal(1, saved)
        assert.are.equal(1, restart_prompts)
    end)

    it("applies verbose debug logging immediately", function()
        local calls = {}
        G_reader_settings.makeTrue = function(self, key) self:saveSetting(key, true) end
        G_reader_settings.makeFalse = function(self, key) self:saveSetting(key, false) end
        ZenSpec.replace("dbg", {
            turnOn = function() calls[#calls + 1] = "on" end,
            turnOff = function() calls[#calls + 1] = "off" end,
            setVerbose = function(_self, enabled)
                calls[#calls + 1] = enabled and "verbose" or "quiet"
            end,
        })
        local items = require("modules/settings/sections/advanced_settings").build({
            config = { features = {}, developer = {} },
            plugin = { saveConfig = function() end },
            settings_apply = { prompt_restart = function() end },
        })
        local debug_item
        for _i, item in ipairs(items) do
            if item.text == "Debug logging" then debug_item = item end
        end

        debug_item.callback()
        assert.is_true(debug_item.checked_func())
        assert.same({ "on", "verbose" }, calls)

        debug_item.callback()
        assert.is_false(debug_item.checked_func())
        assert.same({ "on", "verbose", "quiet", "off" }, calls)
    end)
end)
