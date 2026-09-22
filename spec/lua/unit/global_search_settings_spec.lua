describe("global search settings", function()
    local module_names = {
        "gettext",
        "ui/uimanager",
        "device",
        "ui/widget/confirmbox",
        "common/restart",
        "config/preset_store",
        "modules/settings/zen_settings_utils",
        "common/inline_icon_map",
        "common/ui/icon_menu_item",
        "common/plugin_root",
        "libs/libkoreader-lfs",
    }
    local originals

    before_each(function()
        originals = {}
        for _i, name in ipairs(module_names) do originals[name] = package.loaded[name] end

        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/uimanager", {})
        ZenSpec.replace("device", {})
        ZenSpec.replace("ui/widget/confirmbox", {})
        ZenSpec.replace("common/restart", {})
        ZenSpec.replace("config/preset_store", {})
        ZenSpec.replace("modules/settings/zen_settings_utils", {})
        ZenSpec.replace("common/inline_icon_map", { keyboard = "keyboard-icon" })
        ZenSpec.replace("common/ui/icon_menu_item", {
            decorate = function(item, glyph)
                item.icon_glyph = glyph
                return item
            end,
        })
        ZenSpec.replace("common/plugin_root", "/missing")
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function() return nil end,
        })
        ZenSpec.unload("modules/settings/sections/global_settings")
    end)

    after_each(function()
        ZenSpec.unload("modules/settings/sections/global_settings")
        for _i, name in ipairs(module_names) do package.loaded[name] = originals[name] end
    end)

    it("defaults Zen Search on and prompts for restart when toggled", function()
        local saved, restart_prompts = 0, 0
        local config = { features = {} }
        local items = require("modules/settings/sections/global_settings").build_extras_items({
            config = config,
            plugin = { saveConfig = function() saved = saved + 1 end },
            settings_apply = {
                prompt_restart = function() restart_prompts = restart_prompts + 1 end,
            },
        })
        local search_toggle = items[1].sub_item_table[1]

        assert.are.equal("Enable Zen Search", search_toggle.text)
        assert.is_true(search_toggle.checked_func())
        search_toggle.callback()
        assert.is_false(search_toggle.checked_func())
        assert.is_false(items[1].sub_item_table[2].enabled_func())
        assert.are.equal(1, saved)
        assert.are.equal(1, restart_prompts)
    end)

    it("defaults Zen Keyboard on and prompts for restart when toggled", function()
        local saved, restart_prompts = 0, 0
        local config = { features = {} }
        local items = require("modules/settings/sections/global_settings").build_extras_items({
            config = config,
            plugin = { saveConfig = function() saved = saved + 1 end },
            settings_apply = {
                prompt_restart = function() restart_prompts = restart_prompts + 1 end,
            },
        })
        local keyboard_toggle
        for _i, item in ipairs(items) do
            if item.text == "Zen Keyboard" then keyboard_toggle = item end
        end

        assert.is_not_nil(keyboard_toggle)
        assert.are.equal("keyboard-icon", keyboard_toggle.icon_glyph)
        assert.is_true(keyboard_toggle.checked_func())
        keyboard_toggle.callback()
        assert.is_false(keyboard_toggle.checked_func())
        assert.are.equal(1, saved)
        assert.are.equal(1, restart_prompts)
    end)
end)
