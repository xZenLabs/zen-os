describe("app launcher plugin scan", function()
    local plugin_dir
    local original_lfs
    local original_plugin_root

    before_each(function()
        plugin_dir = "/plugins/marked.koplugin"
        original_lfs = package.loaded["libs/libkoreader-lfs"]
        original_plugin_root = package.loaded["common/plugin_root"]

        ZenSpec.replace("pluginloader", {
            loaded_plugins = {
                marked = { path = plugin_dir .. "/", open = function() end },
                manual = { path = "/plugins/manual.koplugin", open = function() end },
            },
            loadPlugins = function()
                return { { name = "marked" }, { name = "manual" } }
            end,
        })
        ZenSpec.unload("modules/menu/app_launcher/plugin_scan")
    end)

    after_each(function()
        ZenSpec.unload("modules/menu/app_launcher/plugin_scan")
        ZenSpec.unload("pluginloader")
        package.loaded["libs/libkoreader-lfs"] = original_lfs
        package.loaded["common/plugin_root"] = original_plugin_root
    end)

    it("matches only launchable plugins with pending ZenPM database rows", function()
        local PluginScan = require("modules/menu/app_launcher/plugin_scan")
        local found = PluginScan.scan()
        assert.are.equal(2, #found)

        local zenpm = PluginScan.scanZenPM({
            { id = "package-id", install_path = plugin_dir },
        })
        assert.are.equal(1, #zenpm)
        assert.are.equal("marked", zenpm[1].key)
        assert.are.equal("package-id", zenpm[1].zenpm_package_id)
    end)

    it("matches absolute pending paths to KOReader-relative plugin paths", function()
        ZenSpec.replace("pluginloader", {
            loaded_plugins = {
                marked = {
                    path = "plugins/marked.koplugin/",
                    open = function() end,
                },
            },
            loadPlugins = function()
                return { { name = "marked" } }
            end,
        })
        ZenSpec.unload("modules/menu/app_launcher/plugin_scan")

        local zenpm = require("modules/menu/app_launcher/plugin_scan").scanZenPM({
            {
                id = "package-id",
                install_path = "/runtime/plugins/marked.koplugin",
            },
        })
        assert.are.equal(1, #zenpm)
        assert.are.equal("package-id", zenpm[1].zenpm_package_id)
    end)

    it("caches plugin directory names without reading metadata", function()
        local scans = 0
        ZenSpec.replace("common/plugin_root", "/plugins/zenos.koplugin")
        ZenSpec.replace("libs/libkoreader-lfs", {
            dir = function(path)
                scans = scans + 1
                local entries = path == "/plugins"
                    and { ".", "..", "localsend.koplugin", "zenos.koplugin", "notes" }
                    or { ".", ".." }
                local index = 0
                return function()
                    index = index + 1
                    return entries[index]
                end
            end,
            attributes = function(path)
                return path:sub(-9) == ".koplugin" and "directory" or nil
            end,
        })
        ZenSpec.unload("modules/menu/app_launcher/plugin_scan")

        local PluginScan = require("modules/menu/app_launcher/plugin_scan")
        local installed = PluginScan.installed()
        local first_scan_count = scans

        assert.are.same({ localsend = true, zenos = true }, installed)
        assert.are.equal(installed, PluginScan.installed())
        assert.are.equal(first_scan_count, scans)
    end)
end)
