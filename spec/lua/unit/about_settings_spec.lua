describe("About settings", function()
    local quickstart_spec
    local scheduled
    local time_setting
    local tour_starts

    before_each(function()
        quickstart_spec = nil
        scheduled = {}
        time_setting = { text = "Time and date", sub_item_table = {} }
        tour_starts = 0

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
        ZenSpec.replace("modules/settings/sections/advanced_settings", {
            build = function() return {} end,
        })
        ZenSpec.replace("ui/elements/common_settings_menu_table", {
            time = time_setting,
        })
        ZenSpec.replace("common/inline_icon_map", setmetatable({}, {
            __index = function(_self, key) return key end,
        }))
        ZenSpec.replace("common/ui/icon_menu_item", {
            decorate = function() end,
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
        assert.are.equal(1, saves)
        assert.are.equal(1, #scheduled)
        assert.are.equal(0.35, scheduled[1].delay)

        scheduled[1].callback()
        assert.are.equal(1, tour_starts)
    end)

    it("reuses KOReader's time and date menu", function()
        local items = require("modules/settings/sections/about_settings").build({
            config = {},
            plugin = {},
        })

        assert.are.equal(time_setting, items[5])
    end)
end)
