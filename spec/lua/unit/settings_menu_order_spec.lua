describe("settings menu organization", function()
    it("groups interface and device settings with and without Bluetooth", function()
        local originals = {}
        local function replace(name, value)
            originals[name] = { value = package.loaded[name] }
            ZenSpec.replace(name, value)
        end
        local function items(labels)
            local result = {}
            for _i, label in ipairs(labels) do result[#result + 1] = { text = label } end
            return result
        end
        local function labels(item_table)
            local result = {}
            for _i, item in ipairs(item_table) do result[#result + 1] = item.text end
            return result
        end
        local has_bluetooth, double_tap_item
        local language_item = { text = "Language", sub_item_table = {} }
        local time_item = { text = "Time and date", sub_item_table = {} }

        replace("gettext", function(text) return text end)
        local shown_dialog, reset_calls, menu_updates, has_current_capacity, missing_stats, is_charging
        replace("ui/uimanager", { show = function(_, dialog) shown_dialog = dialog end })
        replace("ui/widget/confirmbox", { new = function(_, dialog) return dialog end })
        replace("common/shutdown", {})
        replace("modules/settings/zen_settings_apply", {})
        replace("modules/settings/zen_updater", {
            init_banner = function() end,
            build_update_available_action = function() end,
        })
        replace("common/battery_stats", {
            snapshot = function()
                if missing_stats == "none" then return nil end
                if missing_stats == "partial" then return { samples = 0 } end
                local overall = reset_calls == 0 and 0.5 or nil
                return { level = 80, charging = is_charging, overall = overall, awake = 1, asleep = 0.1,
                    awake_time = 7200, asleep_time = 14400,
                    current_mah = has_current_capacity and 600 or nil,
                    full_mah = 1200, design_mah = 1600, health = 75, remaining = 125100,
                    charge_rate = 20, charge_gain = 40, time_to_full = 3600, full_charge_time = 7200, since_full_charge = 14400,
                    since_charge = 3600, samples = reset_calls > 0 and 0 or 24 }
            end,
            reset = function() reset_calls = reset_calls + 1 end,
        })
        replace("datetime", { secondsToClockDuration = function(format, seconds, without_seconds, with_days)
            assert.are.equal("letters", format)
            assert.is_true(without_seconds)
            assert.is_true(with_days)
            return ({
                [7200] = "2h\u{2009}0m",
                [14400] = "4h\u{2009}0m",
                [125100] = "1d\u{2009}10h\u{2009}45m",
                [3600] = "1h\u{2009}0m",
            })[seconds]
        end })
        local interface_icon = require("common/inline_icon_map").settings_global
        assert.are.equal("\u{F0574}", interface_icon)
        assert.are.equal("\u{F0080}", require("common/inline_icon_map").battery)
        replace("common/inline_icon_map", {
            settings = "gear", settings_global = interface_icon, battery = "battery_icon",
        })
        replace("common/ui/icon_menu_item", {
            installMenuPatch = function() end,
            decorate = function(item, glyph)
                item.icon_glyph = glyph
                return item
            end,
        })
        replace("device", {})
        replace("ui/network/manager", {})
        replace("ui/event", {})
        replace("modules/menu/bluetooth/bluetooth", {
            isAvailable = function() return has_bluetooth end,
        })
        replace("ui/language", {
            getLangMenuTable = function() return language_item end,
        })
        replace("ui/elements/common_settings_menu_table", { time = time_item })
        replace("modules/settings/zen_settings_utils", false)
        for _i, section in ipairs({
            "library_settings/home_settings", "library_settings/navbar_settings",
            "app_launcher_settings",
        }) do
            replace("modules/settings/sections/" .. section, { build = function() return {} end })
        end
        replace("modules/settings/sections/menu_settings", {
            build = function()
                return { sub_item_table = items({ "Blur menu background" }) }
            end,
        })
        local font_item, wallpaper_item, status_bar_item
        replace("modules/settings/sections/library_settings", {
            build = function()
                font_item = {
                    text = "Font",
                    text_func = function() return "Font: Hyperreadable, 24" end,
                    sub_item_table = items({ "Font size", "Font", "Reset font" }),
                }
                wallpaper_item = { text = "Wallpaper" }
                status_bar_item = { text = "Status bar", sub_item_table = items({ "Left items", "Right items" }) }
                return { { text = "Original control" }, font_item, wallpaper_item, status_bar_item }
            end,
        })
        for _i, section in ipairs({ "reader_settings", "updates_settings" }) do
            replace("modules/settings/sections/" .. section, {
                build = function() return items({ "Original control" }) end,
            })
        end
        replace("modules/settings/sections/extras_settings", {
            build = function()
                return items({ "Stats", "Install ZenPM", "Zen OPDS", "Rakuyomi", "Schedules", "Sleep", "Zen Search", "Lockdown mode", "Zen Keyboard", "Custom icons" })
            end,
        })
        replace("modules/settings/sections/advanced_settings", {
            build = function()
                local result = items({ "Original control", "Double tap to open books" })
                double_tap_item = result[2]
                return result
            end,
        })
        replace("modules/settings/sections/about_settings", {
            build = function()
                return items({ "Version", "Device", "Setup Guide", "Report a Bug" })
            end,
        })

        local original_builder = package.loaded["modules/settings/zen_settings"]
        ZenSpec.unload("modules/settings/zen_settings")
        local builder = require("modules/settings/zen_settings")
        for _i, available in ipairs({ false, true }) do
            reset_calls, menu_updates, has_current_capacity, missing_stats = 0, 0, true, nil
            is_charging = false
            has_bluetooth = available
            local root = builder.build({ config = { features = {} } }).sub_item_table
            assert.are.same({ "Home", "Library", "Reader", "Interface", "Extras", "General", "KOReader", "About" }, labels(root))
            assert.is_function(root[7].sub_item_table_func)
            assert.are.equal("koreader.png", root[7].icon_file:match("([^/]+)$"))
            assert.is_nil(root[7].icon_glyph)
            local interface = root[4].sub_item_table
            assert.are.equal("interface", root[4]._zen_settings_root)
            assert.are.equal(interface_icon, root[4].icon_glyph)
            assert.are.same({ "Controls", "Launcher", "Navbar", "Status bar", "Font", "Zen Keyboard", "Wallpaper", "Custom icons", "Blur menu background", "Zen Search" }, labels(interface))
            assert.are.equal("launcher", interface[2]._zen_settings_root)
            assert.are.equal(status_bar_item, interface[4])
            assert.are.same({ "Left items", "Right items" }, labels(interface[4].sub_item_table))
            assert.are.equal(font_item, interface[5])
            assert.are.equal(wallpaper_item, interface[7])
            assert.are.equal("Font: Hyperreadable, 24", interface[5].text_func())
            assert.are.same({ "Font size", "Font", "Reset font" }, labels(interface[5].sub_item_table))
            assert.are.equal("gear", root[6].icon_glyph)
            local general = root[6].sub_item_table
            local expected = { "Wi-Fi", "Schedules", "Sleep", "Battery", "Language", "Time and date", "Advanced", "Updates" }
            if available then table.insert(expected, 2, "Bluetooth") end
            assert.are.same(expected, labels(general))
            local battery_item = general[available and 5 or 4]
            assert.are.equal("battery_icon", battery_item.icon_glyph)
            local battery = battery_item.sub_item_table_func()
            assert.are.same({ "Health", "Usage", "Charging", "Estimated battery life", "Settings" }, labels(battery))
            assert.are.equal("75%", battery[1].mandatory)
            assert.are.equal("0.50%/h", battery[2].mandatory)
            assert.is_nil(battery[3].mandatory)
            assert.are.equal("1d 10h 45m", battery[4].mandatory)
            local health = battery[1].sub_item_table
            local usage = battery[2].sub_item_table
            local charging = battery[3].sub_item_table
            local settings = battery[5].sub_item_table
            assert.are.equal("Battery health: 75%", health[1].text)
            assert.are.equal("Current charge: 80%", health[2].text)
            assert.are.equal("Current capacity: 600 mAh", health[3].text)
            has_current_capacity = false
            assert.are.equal("Current capacity: -",
                battery_item.sub_item_table_func()[1].sub_item_table[3].text)
            has_current_capacity = true
            assert.are.equal("Full capacity: 1200 mAh", health[4].text)
            assert.are.equal("Design capacity: 1600 mAh", health[5].text)
            assert.are.same({ "Previous charge, per hour: 20.00%/h", "Previous charge, total: 40%",
                "Total time to full charge: 2h 0m", "Time since last charge: 1h 0m",
                "Time since last full charge: 4h 0m" }, labels(charging))
            is_charging = true
            local active_charging = battery_item.sub_item_table_func()[3]
            assert.are.equal("1h 0m", active_charging.mandatory)
            assert.are.same({ "Estimated time to complete charge: 1h 0m", "Previous charge, per hour: 20.00%/h",
                "Previous charge, total: 40%",
                "Total time to full charge: 2h 0m", "Time since last charge: Charging",
                "Time since last full charge: 4h 0m" }, labels(active_charging.sub_item_table))
            is_charging = false
            assert.are.equal("Used per hour: 0.50%/h", usage[1].text)
            assert.are.equal("While asleep: 0.10%/h", usage[3].text)
            assert.are.equal("Screen on time: 2h 0m", usage[4].text)
            assert.are.equal("Screen off time: 4h 0m", usage[5].text)
            assert.are.equal("Tracked samples: 24", settings[1].text)
            assert.are.equal("Reset battery log", settings[2].text)
            local battery_menu = { item_table = settings,
                updateItems = function() menu_updates = menu_updates + 1 end }
            settings[2].callback(battery_menu)
            assert.are.equal("Reset battery log?", shown_dialog.text)
            shown_dialog.ok_callback()
            assert.are.equal(menu_updates, reset_calls)
            assert.are.equal("Tracked samples: 0", battery_menu.item_table[1].text)
            assert.are.equal("-", battery[2].mandatory)
            missing_stats = "partial"
            local missing_rows = battery_item.sub_item_table_func()
            assert.are.equal("-", missing_rows[1].mandatory)
            assert.are.equal("-", missing_rows[2].mandatory)
            assert.are.equal("Battery health: -", missing_rows[1].sub_item_table[1].text)
            assert.are.equal("Current charge: -", missing_rows[1].sub_item_table[2].text)
            assert.is_nil(missing_rows[3].mandatory)
            assert.are.same({ "Previous charge, per hour: -", "Previous charge, total: -",
                "Total time to full charge: -", "Time since last charge: -",
                "Time since last full charge: -" }, labels(missing_rows[3].sub_item_table))
            assert.are.equal("Used per hour: -", missing_rows[2].sub_item_table[1].text)
            missing_stats = "none"
            assert.are.same({ "-" }, labels(battery_item.sub_item_table_func()))
            assert.are.equal("Wi-Fi", general[1].text)
            assert.are.equal(language_item.sub_item_table, general[#general - 3].sub_item_table)
            assert.are.equal(time_item, general[#general - 2])
            if available then assert.are.equal("Bluetooth", general[2].text) end
            assert.are.same({ "Original control" }, labels(general[#general - 1].sub_item_table))
            assert.are.same({ "Original control" }, labels(general[#general].sub_item_table))
            assert.are.same({ "Original control", "Double tap to open books" }, labels(root[2].sub_item_table))
            assert.are.equal(double_tap_item, root[2].sub_item_table[#root[2].sub_item_table])
            assert.are.same({ "Version", "Device", "Setup Guide", "Report a Bug", "Quit KOReader" }, labels(root[8].sub_item_table))
            assert.are.same({ "Install ZenPM", "Zen OPDS", "Stats", "Rakuyomi", "Lockdown mode" }, labels(root[5].sub_item_table))
        end
        package.loaded["modules/settings/zen_settings"] = original_builder
        for name, original in pairs(originals) do package.loaded[name] = original.value end
    end)
end)
