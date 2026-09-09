describe("global sleep settings", function()
    local module_names = {
        "gettext",
        "ui/uimanager",
        "device",
        "datastorage",
        "ui/widget/confirmbox",
        "common/restart",
        "config/preset_store",
        "modules/settings/zen_settings_utils",
        "common/inline_icon_map",
        "common/ui/icon_menu_item",
        "common/plugin_root",
        "libs/libkoreader-lfs",
        "ui/screensaver",
        "ui/widget/pathchooser",
        "document/documentregistry",
        "util",
        "apps/reader/readerui",
        "apps/filemanager/filemanager",
    }
    local originals
    local original_dofile

    before_each(function()
        originals = {}
        for _i, name in ipairs(module_names) do originals[name] = package.loaded[name] end
        original_dofile = dofile

        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/uimanager", {})
        ZenSpec.replace("device", {})
        ZenSpec.replace("datastorage", {
            getFullDataDir = function() return "/koreader" end,
        })
        ZenSpec.replace("ui/widget/confirmbox", {})
        ZenSpec.replace("common/restart", {})
        ZenSpec.replace("config/preset_store", {})
        ZenSpec.replace("modules/settings/zen_settings_utils", {})
        ZenSpec.replace("common/inline_icon_map", {})
        ZenSpec.replace("common/ui/icon_menu_item", {})
        ZenSpec.replace("common/plugin_root", "/missing")
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function() return nil end,
        })
        ZenSpec.replace("apps/reader/readerui", {})
        ZenSpec.replace("apps/filemanager/filemanager", {})
        G_reader_settings:reset()
        ZenSpec.unload("modules/settings/sections/global_settings")
    end)

    after_each(function()
        ZenSpec.unload("modules/settings/sections/global_settings")
        for _i, name in ipairs(module_names) do package.loaded[name] = originals[name] end
        _G.dofile = original_dofile
        G_reader_settings:reset()
    end)

    it("uses the screensavers directory as the custom image default and Home", function()
        local chooser
        local home_path
        local stock_callback = function() end
        ZenSpec.replace("ui/screensaver", { chooseFile = stock_callback })
        ZenSpec.replace("ui/widget/pathchooser", {
            new = function(_self, values) return values end,
        })
        ZenSpec.replace("document/documentregistry", {
            hasProvider = function(_, filename) return filename:sub(-4) == ".png" end,
        })
        ZenSpec.replace("util", {
            splitFilePathName = function(path) return path:match("(.*/)(.*)") end,
        })
        package.loaded["ui/uimanager"].show = function(_, widget) chooser = widget end
        _G.dofile = function()
            return {{
                sub_item_table = {{
                    sub_item_table = {{ callback = stock_callback }},
                }},
            }}
        end

        local items = require("modules/settings/sections/global_settings").build({
            config = {},
            plugin = {},
        })
        local sleep_items = items[5].sub_item_table_func()
        local custom_image = sleep_items[1].sub_item_table[1].sub_item_table[1]
        assert.are_not.equal(stock_callback, custom_image.callback)

        custom_image.callback()
        assert.are.equal("/koreader/resources/screensavers", chooser.path)
        assert.is_true(chooser.file_filter("cover.png"))
        assert.is_false(chooser.file_filter("cover.txt"))
        assert.is_true(chooser.goHome({
            changeToPath = function(_, path) home_path = path end,
        }))
        assert.are.equal("/koreader/resources/screensavers", home_path)
        chooser.onConfirm("/koreader/resources/screensavers/cover.png")
        assert.are.equal("/koreader/resources/screensavers/cover.png",
            G_reader_settings:readSetting("screensaver_document_cover"))
    end)
end)
