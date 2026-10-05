describe("Extras settings", function()
    it("toggles Zen OPDS and custom icons on their parent rows", function()
        local originals = {}
        local function replace(name, module)
            originals[name] = { value = package.loaded[name] }
            ZenSpec.replace(name, module)
        end
        replace("gettext", function(text) return text end)
        replace("device", {})
        replace("ffi/util", {})
        replace("common/icon_packs", {})
        replace("modules/filebrowser/patches/rakuyomi", { is_available = function() return true end })
        replace("modules/settings/sections/global_settings", { build_extras_items = function() return {} end })
        replace("modules/settings/sections/stats_settings", { build = function() return { text = "Stats" } end })
        replace("modules/settings/zenpm_installer", { detect_assets = function() return false end })
        replace("common/inline_icon_map", { settings_opds = "opds-icon", custom_icons = "custom-icons" })
        replace("common/ui/icon_menu_item", {
            decorate = function(item, glyph)
                item.icon_glyph = glyph
                return item
            end,
        })
        replace("modules/settings/sections/extras_settings", false)
        local ok, err = pcall(function()
            local saved, updates, restart_prompts = 0, 0, 0
            local config = { features = {}, opds = { large_covers = true } }
            local items = require("modules/settings/sections/extras_settings").build({
                config = config,
                plugin = { saveConfig = function() saved = saved + 1 end },
                settings_apply = { prompt_restart = function() restart_prompts = restart_prompts + 1 end },
            })
            local opds = items[2]
            local rakuyomi = items[3]
            assert.are.equal("Rakuyomi", rakuyomi.text)
            assert.are.equal("tab_manga.svg", rakuyomi.icon_file:match("([^/]+)$"))
            assert.is_nil(rakuyomi.icon_glyph)
            assert.are.equal("Zen OPDS", opds.text)
            assert.are.equal("opds-icon", opds.icon_glyph)
            assert.are.equal(opds.callback, opds.checkmark_callback)
            assert.is_true(opds.checked_func())
            assert.are.equal(2, #opds.sub_item_table)
            local display_modes = opds.sub_item_table[1]
            assert.are.equal("Display mode", display_modes.text)
            assert.are.equal(3, #display_modes.sub_item_table)
            local large_covers = opds.sub_item_table[2]
            assert.are.equal("Prefer large covers", large_covers.text)
            assert.are.equal(large_covers.callback, large_covers.checkmark_callback)
            assert.is_true(large_covers.checked_func())

            local menu = { updateItems = function() updates = updates + 1 end }
            opds.checkmark_callback(menu)
            assert.is_false(config.features.zen_opds)
            assert.is_false(opds.checked_func())
            opds.checkmark_callback(menu)
            assert.is_true(config.features.zen_opds)
            assert.is_true(opds.checked_func())
            assert.are.equal(2, saved)
            assert.are.equal(2, updates)
            assert.are.equal(2, restart_prompts)

            local classic = display_modes.sub_item_table[3]
            assert.are.equal("Classic", classic.text)
            classic.callback(menu)
            assert.are.equal("classic", config.opds.display_mode)
            assert.is_true(classic.checked_func())
            assert.are.equal(3, saved)
            assert.are.equal(3, updates)
            assert.are.equal(2, restart_prompts)

            local custom_icons = items[#items]
            assert.are.equal("Custom icons", custom_icons.text)
            assert.are.equal("custom-icons", custom_icons.icon_glyph)
            assert.are.equal(custom_icons.callback, custom_icons.checkmark_callback)
            assert.is_false(custom_icons.checked_func())
            assert.are.equal(1, #custom_icons.sub_item_table)
            local pack = custom_icons.sub_item_table[1]
            assert.are.equal(custom_icons.icon_glyph, pack.icon_glyph)
            assert.is_function(pack.text_func)
            assert.is_function(pack.sub_item_table_func)
            assert.is_false(pack.enabled_func())

            custom_icons.checkmark_callback(menu)
            assert.is_true(config.features.custom_icons_enabled)
            assert.is_true(custom_icons.checked_func())
            assert.is_true(pack.enabled_func())
            custom_icons.checkmark_callback(menu)
            assert.is_false(config.features.custom_icons_enabled)
            assert.is_false(custom_icons.checked_func())
            assert.is_false(pack.enabled_func())
            assert.are.equal(5, saved)
            assert.are.equal(5, updates)
            assert.are.equal(4, restart_prompts)
        end)
        for name, original in pairs(originals) do package.loaded[name] = original.value end
        assert.is_true(ok, err)
    end)
end)
