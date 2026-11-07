describe("annotation viewer settings", function()
    local saved, Settings, shown
    before_each(function()
        saved = {}
        for _i, name in ipairs({ "gettext", "ui/uimanager", "ui/widget/spinwidget", "common/plugin_root", "common/utils",
                "modules/settings/sections/annotation_settings" }) do
            saved[name] = package.loaded[name] or false
        end
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/uimanager", { show = function(_self, widget) shown = widget end })
        ZenSpec.replace("ui/widget/spinwidget", { new = function(_self, spec) return spec end })
        ZenSpec.replace("common/plugin_root", ZenSpec.root)
        ZenSpec.replace("common/utils", {
            resolveLocalIcon = function(dir, name) return dir .. name .. ".svg" end,
        })
        ZenSpec.unload("modules/settings/sections/annotation_settings")
        Settings = require("modules/settings/sections/annotation_settings")
    end)
    after_each(function()
        for name, module in pairs(saved) do package.loaded[name] = module or nil end
    end)

    it("persists detail choices and reuses the saved annotation text size", function()
        local config = { page_browser = { bookmarks_font_size = 23 } }
        local saves = 0
        local item = Settings.build({ config = config, plugin = {
            saveConfig = function() saves = saves + 1 end,
        } })
        assert.are.equal("bookmark", item.icon_name)
        local menu = item.sub_item_table
        assert.are.equal("Details", menu[1].text)
        local details = menu[1].sub_item_table
        assert.is_true(details[3].checked_func())
        assert.is_true(details[5].checked_func())
        details[5].callback()
        assert.is_false(config.annotation_viewer.details.date)
        details[1].sub_item_table[2].callback()
        assert.are.equal("show", config.annotation_viewer.details.book)
        menu[2].sub_item_table[3].callback()
        assert.are.equal("long", config.annotation_viewer.preview_length)
        assert.is_true(menu[3].keep_menu_open)
        menu[3].callback()
        assert.are.equal(23, shown.value)
        shown.callback({ value = 26 })
        assert.are.equal(26, config.page_browser.bookmarks_font_size)
        assert.are.equal(4, saves)
    end)
end)
