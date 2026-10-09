describe("device system statistics", function()
    local originals, settings, files, disk_usage, disk_path, Utils
    local module_names = { "device", "util", "datastorage", "ui/uimanager", "modules/settings/zen_settings_utils" }

    before_each(function()
        originals = {}
        for _i, name in ipairs(module_names) do originals[name] = package.loaded[name] end
        settings = G_reader_settings
        G_reader_settings = ZenSpec.memorySettings{ home_dir = "/external/books" }
        files = {}
        disk_usage = { total = 32000, used = 8000, available = 23000 }
        disk_path = nil
        ZenSpec.replace("device", { home_dir = "/mnt/onboard" })
        ZenSpec.replace("datastorage", { getFullDataDir = function() return "/data/koreader" end })
        ZenSpec.replace("ui/uimanager", {})
        ZenSpec.replace("util", {
            diskUsage = function(path) disk_path = path; return disk_usage end,
            readFromFile = function(path)
                if files[path] then return files[path] end
                return nil, "File not found"
            end,
        })
        ZenSpec.unload("modules/settings/zen_settings_utils")
        Utils = require("modules/settings/zen_settings_utils")
    end)

    after_each(function()
        for _i, name in ipairs(module_names) do package.loaded[name] = originals[name] end
        G_reader_settings = settings
    end)

    it("uses the device storage volume independently of the library folder", function()
        assert.are.same({ total = 32000, used = 8000, available = 23000 }, Utils.get_device_disk_usage())
        assert.are.equal("/mnt/onboard", disk_path)
        package.loaded.device.home_dir = nil
        Utils.get_device_disk_usage()
        assert.are.equal("/data/koreader", disk_path)
    end)

    it("supports older disk APIs and handles missing storage", function()
        disk_usage.available = nil
        assert.are.equal(24000, Utils.get_device_disk_usage().available)
        disk_usage = { total = nil, used = nil, available = nil }
        assert.is_nil(Utils.get_device_disk_usage())
        disk_usage = { total = 0, used = 0 }
        assert.is_nil(Utils.get_device_disk_usage())
        package.loaded.util.diskUsage = function() error("unavailable") end
        assert.is_nil(Utils.get_device_disk_usage())
    end)

    it("reports system RAM without an artificial allocation reserve", function()
        files["/proc/meminfo"] = "MemTotal: 1024000 kB\nMemFree: 1000 kB\nMemAvailable: 768000 kB\nCached: 100000 kB\n"
        assert.are.same({ total = 1024000 * 1024, used = 256000 * 1024, available = 768000 * 1024 },
            Utils.get_device_ram_usage())
    end)

    it("estimates available RAM on older kernels and rejects incomplete memory data", function()
        files["/proc/meminfo"] = "MemTotal: 1024 kB\nMemFree: 128 kB\nBuffers: 64 kB\nCached: 256 kB\n"
        assert.are.same({ total = 1024 * 1024, used = 576 * 1024, available = 448 * 1024 },
            Utils.get_device_ram_usage())
        files["/proc/meminfo"] = "MemTotal: 1024 kB\nMemAvailable: 2048 kB\n"
        assert.are.equal(0, Utils.get_device_ram_usage().used)
        files["/proc/meminfo"] = "MemTotal: 1024 kB\n"
        assert.is_nil(Utils.get_device_ram_usage())
        files["/proc/meminfo"] = nil
        assert.is_nil(Utils.get_device_ram_usage())
    end)

    it("counts offline cores and reports the frequency range across CPU clusters", function()
        files["/proc/cpuinfo"] = "processor\t: 0\nmodel name\t: ARMv7 Processor rev 10 (v7l)\nHardware\t: i.MX 6\n"
        files["/sys/devices/system/cpu/present"] = "0-1,4-5\n"
        files["/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq"] = "396000\n"
        files["/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq"] = "1000000\n"
        files["/sys/devices/system/cpu/cpu4/cpufreq/cpuinfo_cur_freq"] = "1200000\n"
        files["/sys/devices/system/cpu/cpu4/cpufreq/scaling_cur_freq"] = "1400000\n"
        files["/sys/devices/system/cpu/cpu4/cpufreq/cpuinfo_max_freq"] = "1800000\n"
        assert.are.same({ model = "i.MX 6", cores = 4,
            current_min_khz = 396000, current_max_khz = 1200000, max_khz = 1800000 }, Utils.get_device_cpu_info())
    end)

    it("falls back to proc CPU details when cpufreq is unavailable", function()
        files["/proc/cpuinfo"] = "processor : 0\nmodel name : Test CPU\ncpu MHz : 2400.5\n\nprocessor : 1\n"
        assert.are.same({ model = "Test CPU", cores = 2,
            current_min_khz = 2400500, current_max_khz = 2400500 }, Utils.get_device_cpu_info())
        files["/proc/cpuinfo"] = "Processor : ARMv7\nHardware : i.MX 6\nprocessor : 0\n"
        assert.are.same({ model = "i.MX 6", cores = 1 }, Utils.get_device_cpu_info())
        files["/proc/cpuinfo"] = nil
        assert.are.same({}, Utils.get_device_cpu_info())
    end)
end)
