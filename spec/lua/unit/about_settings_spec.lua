describe("About settings", function()
    local quickstart_spec
    local scheduled
    local tour_starts
    local language_item, time_item

    before_each(function()
        quickstart_spec = nil
        scheduled = {}
        tour_starts = 0
        language_item = { text = "Language", sub_item_table = {} }
        time_item = { text = "Time and date", sub_item_table = {} }

        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ffi/util", {
            template = function(text, value)
                return text:gsub("%%1", tostring(value))
            end,
        })
        ZenSpec.replace("ui/uimanager", {
            show = function(_self, widget) quickstart_spec = widget end,
            nextTick = function(_self, callback) callback() end,
            scheduleIn = function(_self, delay, callback)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end,
        })
        ZenSpec.replace("modules/settings/zen_settings_utils", {
            get_plugin_version = function() return "1.0.0" end,
            get_koreader_version = function() return "2026.08" end,
            get_device_model_name = function() return "Test device" end,
            get_device_firmware_display = function() return "Test firmware" end,
            get_device_ip_address = function() return nil end,
        })
        ZenSpec.replace("modules/settings/zen_bugreporter", {
            show_dialog = function() end,
        })
        ZenSpec.replace("ui/language", {
            getLangMenuTable = function() return language_item end,
        })
        ZenSpec.replace("ui/elements/common_settings_menu_table", { time = time_item })
        ZenSpec.replace("common/inline_icon_map", setmetatable({}, {
            __index = function(_self, key) return key end,
        }))
        ZenSpec.replace("common/ui/icon_menu_item", {
            decorate = function(item, icon) item.icon_glyph = icon; return item end,
        })
        ZenSpec.replace("common/quickstart/quickstart_screen", {
            new = function(_self, spec) return spec end,
        })
        ZenSpec.replace("common/quickstart/quickstart_pages", {
            build_install_pages = function() return { { title = "Setup" } } end,
        })
        ZenSpec.replace("common/quickstart/menu_tour", {
            start = function() tour_starts = tour_starts + 1 end,
        })
        ZenSpec.replace("apps/filemanager/filemanager", {})
        ZenSpec.unload("modules/settings/sections/about_settings")
    end)

    after_each(function()
        ZenSpec.unload("modules/settings/sections/about_settings")
    end)

    it("starts the menu coach after a manually launched Setup Guide closes", function()
        local config = { _meta = {} }
        local saves = 0
        local plugin = {
            saveConfig = function() saves = saves + 1 end,
        }
        local items = require("modules/settings/sections/about_settings").build({
            config = config,
            plugin = plugin,
        })

        items[3].callback()
        assert.is_table(quickstart_spec)
        quickstart_spec.on_close()

        assert.is_true(config._meta.quickstart_completed)
        assert.is_true(config._meta.quickstart_menu_tour_pending)
        assert.is_true(config._meta.quickstart_reader_tour_pending)
        assert.are.equal(1, saves)
        assert.are.equal(1, #scheduled)
        assert.are.equal(0.35, scheduled[1].delay)

        scheduled[1].callback()
        assert.are.equal(1, tour_starts)
    end)

    it("keeps device details, language, and time settings with About", function()
        local items = require("modules/settings/sections/about_settings").build({
            config = {},
            plugin = {},
        })

        local device_items = items[2].sub_item_table
        assert.are.equal(6, #device_items)
        assert.are.equal("Language", device_items[5].text)
        assert.are.equal(language_item.sub_item_table, device_items[5].sub_item_table)
        assert.are.equal("language", device_items[5].icon_glyph)
        assert.are.equal(time_item, device_items[6])
        assert.are.equal("tbr", device_items[6].icon_glyph)
        assert.are.same({ "ZenOS: 1.0.0", "Device", "Setup Guide", "Report a Bug" }, {
            items[1].text_func(), items[2].text, items[3].text, items[4].text,
        })
    end)
end)
