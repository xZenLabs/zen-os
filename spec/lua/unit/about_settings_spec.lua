describe("About settings", function()
    local quickstart_spec
    local scheduled
    local tour_starts
    local language_item, time_item
    local original_util
    local disk_usage, ram_usage, cpu_info, stats_reads

    before_each(function()
        quickstart_spec = nil
        scheduled = {}
        tour_starts = 0
        language_item = { text = "Language", sub_item_table = {} }
        time_item = { text = "Time and date", sub_item_table = {} }
        original_util = package.loaded.util
        stats_reads = 0
        disk_usage = { total = 32000000000, used = 8000000000, available = 24000000000 }
        ram_usage = { total = 500000000, used = 300000000, available = 200000000 }
        cpu_info = { model = "i.MX 6", cores = 2,
            current_min_khz = 396000, current_max_khz = 792000, max_khz = 1000000 }
        ZenSpec.replace("util", {
            getFriendlySize = function(bytes)
                if not bytes then return nil end
                if bytes >= 1000000000 then return string.format("%.1f GB", bytes / 1000000000) end
                return string.format("%.1f MB", bytes / 1000000)
            end,
        })

        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ffi/util", {
            template = function(text, value)
                return (text:gsub("%%1", tostring(value)))
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
            get_device_disk_usage = function() stats_reads = stats_reads + 1; return disk_usage end,
            get_device_ram_usage = function() stats_reads = stats_reads + 1; return ram_usage end,
            get_device_cpu_info = function() stats_reads = stats_reads + 1; return cpu_info end,
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
        package.loaded.util = original_util
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
        assert.are.equal(9, #device_items)
        assert.are.equal("Language", device_items[8].text)
        assert.are.equal(language_item.sub_item_table, device_items[8].sub_item_table)
        assert.are.equal("language", device_items[8].icon_glyph)
        assert.are.equal(time_item, device_items[9])
        assert.are.equal("tbr", device_items[9].icon_glyph)
        assert.are.same({ "ZenOS: 1.0.0", "Device", "Setup Guide", "Report a Bug" }, {
            items[1].text_func(), items[2].text, items[3].text, items[4].text,
        })
    end)

    it("reads stats on demand and refreshes root totals and submenu details", function()
        local device_items = require("modules/settings/sections/about_settings").build({
            config = {}, plugin = {},
        })[2].sub_item_table
        assert.are.equal(0, stats_reads)
        assert.are.same({ "Storage", "RAM", "CPU" }, {
            device_items[5].text, device_items[6].text, device_items[7].text,
        })
        assert.are.same({ "settings_storage", "settings_ram", "settings_cpu" }, {
            device_items[5].icon_glyph, device_items[6].icon_glyph, device_items[7].icon_glyph,
        })
        assert.are.same({ "32.0 GB", "500.0 MB", "1.00 GHz" }, {
            device_items[5].mandatory_func(), device_items[6].mandatory_func(), device_items[7].mandatory_func(),
        })
        local disk = device_items[5].sub_item_table_func()
        assert.are.same({ "Remaining: 24.0 GB", "Used: 8.0 GB", "Total: 32.0 GB" }, {
            disk[1].text, disk[2].text, disk[3].text,
        })
        local ram = device_items[6].sub_item_table_func()
        assert.are.same({ "Available: 200.0 MB", "Used: 300.0 MB", "Total: 500.0 MB" }, {
            ram[1].text, ram[2].text, ram[3].text,
        })
        local cpu = device_items[7].sub_item_table_func()
        assert.are.same({ "CPU: i.MX 6", "Cores: 2", "Current clock: 0.40–0.79 GHz", "Maximum clock: 1.00 GHz" }, {
            cpu[1].text, cpu[2].text, cpu[3].text, cpu[4].text,
        })
        assert.are.equal(6, stats_reads)
        assert.is_true(disk[1].keep_menu_open)
        disk_usage.available = 16000000000
        assert.are.equal("Remaining: 16.0 GB", device_items[5].sub_item_table_func()[1].text)
        cpu_info.current_max_khz = cpu_info.current_min_khz
        assert.are.equal("Current clock: 0.40 GHz", device_items[7].sub_item_table_func()[3].text)
        disk_usage.total = 64000000000
        ram_usage.total = 1000000000
        cpu_info.max_khz = 1200000
        assert.are.same({ "64.0 GB", "1.0 GB", "1.20 GHz" }, {
            device_items[5].mandatory_func(), device_items[6].mandatory_func(), device_items[7].mandatory_func(),
        })
    end)

    it("shows unavailable system stats without closing the page", function()
        disk_usage, ram_usage, cpu_info = nil, nil, {}
        local device_items = require("modules/settings/sections/about_settings").build({
            config = {}, plugin = {},
        })[2].sub_item_table
        assert.are.same({ "—", "—", "—" }, {
            device_items[5].mandatory_func(), device_items[6].mandatory_func(), device_items[7].mandatory_func(),
        })
        assert.are.equal("Remaining: —", device_items[5].sub_item_table_func()[1].text)
        assert.are.equal("Used: —", device_items[6].sub_item_table_func()[2].text)
        local cpu = device_items[7].sub_item_table_func()
        assert.are.same({ "CPU: —", "Cores: —", "Current clock: —", "Maximum clock: —" }, {
            cpu[1].text, cpu[2].text, cpu[3].text, cpu[4].text,
        })
        assert.is_true(cpu[3].keep_menu_open)
    end)
end)
