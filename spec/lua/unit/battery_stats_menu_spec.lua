describe("standalone battery stats", function()
    it("opens the Battery root in the Zen settings page", function()
        local names = {
            "modules/settings/battery_stats_menu", "modules/settings/zen_settings_page",
            "common/battery_stats", "datetime",
        }
        local originals = {}
        for _i, name in ipairs(names) do originals[name] = package.loaded[name] end
        local shown_plugin, shown_options
        local page = {}
        ZenSpec.replace("common/battery_stats", {
            snapshot = function() return { samples = 0 } end,
        })
        ZenSpec.replace("datetime", { secondsToClockDuration = function() return "0s" end })
        ZenSpec.replace("modules/settings/zen_settings_page", {
            show = function(plugin, options)
                shown_plugin, shown_options = plugin, options
                return page
            end,
        })
        ZenSpec.unload("modules/settings/battery_stats_menu")

        local plugin = {}
        assert.are.equal(page, require("modules/settings/battery_stats_menu").open(plugin))
        assert.are.equal(plugin, shown_plugin)
        assert.are.equal("Battery", shown_options.title)
        assert.are.equal("Health", shown_options.root_items[1].text)
        assert.are.equal("Usage", shown_options.root_items[2].text)
        assert.are.equal("Charging", shown_options.root_items[3].text)

        for _i, name in ipairs(names) do package.loaded[name] = originals[name] end
    end)

    it("shows an archive failure and leaves the menu unchanged", function()
        local names = {
            "modules/settings/battery_stats_menu", "common/battery_stats", "datetime",
            "ui/uimanager", "ui/widget/confirmbox", "ui/widget/infomessage",
        }
        local originals = {}
        for _i, name in ipairs(names) do originals[name] = package.loaded[name] end
        local shown, updates = nil, 0
        ZenSpec.replace("common/battery_stats", {
            snapshot = function() return { samples = 12 } end,
            reset = function() return false end,
        })
        ZenSpec.replace("datetime", { secondsToClockDuration = function() return "0s" end })
        ZenSpec.replace("ui/uimanager", { show = function(_, dialog) shown = dialog end })
        for _i, name in ipairs({ "ui/widget/confirmbox", "ui/widget/infomessage" }) do
            ZenSpec.replace(name, { new = function(_, options) return options end })
        end
        ZenSpec.unload("modules/settings/battery_stats_menu")
        local items = require("modules/settings/battery_stats_menu").buildItems()
        local settings_items = items[#items].sub_item_table
        local menu = {
            item_table = settings_items,
            updateItems = function() updates = updates + 1 end,
        }
        settings_items[2].callback(menu)
        shown.ok_callback()
        assert.are.equal("Could not save battery history. The log was kept.", shown.text)
        assert.are.equal(0, updates)
        assert.are.equal(settings_items, menu.item_table)
        assert.are.equal("Tracked samples: 12", settings_items[1].text)
        for _i, name in ipairs(names) do package.loaded[name] = originals[name] end
    end)
end)
