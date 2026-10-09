describe("Advanced settings", function()
    local original_icons, original_icon_item
    before_each(function()
        original_icons = package.loaded["common/inline_icon_map"]
        original_icon_item = package.loaded["common/ui/icon_menu_item"]
        ZenSpec.unload("common/inline_icon_map")
        ZenSpec.replace("common/ui/icon_menu_item", {
            decorate = function(item, glyph)
                item.icon_glyph = glyph
                return item
            end,
        })
        _G.G_reader_settings = ZenSpec.memorySettings()
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/uimanager", {
            show = function() end,
        })
        ZenSpec.replace("modules/settings/zen_settings_utils", {})
        ZenSpec.replace("common/paths", {})
        ZenSpec.unload("modules/settings/sections/advanced_settings")
    end)

    after_each(function()
        ZenSpec.unload("modules/settings/sections/advanced_settings")
        package.loaded["common/inline_icon_map"] = original_icons
        package.loaded["common/ui/icon_menu_item"] = original_icon_item
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

    it("keeps diagonal screen refresh when clearing configured or missing gestures", function()
        for _i, data in ipairs({
            {
                gesture_fm = {
                    short_diagonal_swipe = { full_refresh = true },
                    hold_top_right_corner = { refresh_content = true },
                },
                gesture_reader = {
                    short_diagonal_swipe = { full_refresh = true },
                    tap_top_right_corner = { history = true },
                    multiswipe_west_east = { previous_location = true },
                },
            },
            {},
        }) do
            local shown = {}
            local flushes, restart_prompts = 0, 0
            ZenSpec.replace("ui/uimanager", {
                show = function(_self, widget) shown[#shown + 1] = widget end,
            })
            ZenSpec.replace("ui/widget/confirmbox", {
                new = function(_self, widget) return widget end,
            })
            ZenSpec.replace("datastorage", { getSettingsDir = function() return "/settings" end })
            ZenSpec.replace("luasettings", {
                open = function(_self, path)
                    assert.are.equal("/settings/gestures.lua", path)
                    return { data = data, flush = function() flushes = flushes + 1 end }
                end,
            })
            ZenSpec.unload("modules/settings/sections/advanced_settings")
            local items = require("modules/settings/sections/advanced_settings").build({
                config = { features = {}, developer = {} },
                plugin = { saveConfig = function() end },
                settings_apply = {
                    prompt_restart = function() restart_prompts = restart_prompts + 1 end,
                },
            })
            for _j, item in ipairs(items) do
                if item.text == "Clear all gestures" then item.callback() end
            end

            assert.are.equal(1, #shown)
            shown[1].ok_callback()

            assert.same({ short_diagonal_swipe = { full_refresh = true } }, data.gesture_fm)
            assert.same({
                short_diagonal_swipe = { full_refresh = true },
                tap_top_right_corner = { toggle_bookmark = true },
            }, data.gesture_reader)
            assert.are.equal(1, flushes)
            assert.are.equal(1, restart_prompts)
            assert.are.equal(1, #shown)
        end
    end)

    it("toggles partial pages refresh without requesting a restart", function()
        local saved = 0
        local config = { features = { partial_page_repaint = false }, developer = {} }
        local items = require("modules/settings/sections/advanced_settings").build({
            config = config,
            plugin = { saveConfig = function() saved = saved + 1 end },
            settings_apply = { prompt_restart = function() error("unexpected restart prompt") end },
        })
        local refresh_item
        for _i, item in ipairs(items) do
            if item.text == "Partial pages refresh" then refresh_item = item end
        end

        assert.is_false(refresh_item.checked_func())
        refresh_item.callback()
        assert.is_true(refresh_item.checked_func())
        refresh_item.callback()
        assert.is_false(refresh_item.checked_func())
        assert.are.equal(2, saved)
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
