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

    it("uses a plugin menu when the ZenPM plugin instance has no path or launch method", function()
        local opened = false
        ZenSpec.replace("pluginloader", {
            loaded_plugins = {
                marked = {
                    addToMainMenu = function(_self, menu)
                        menu.marked = {
                            text = "Marked menu",
                            callback = function() opened = true end,
                        }
                    end,
                },
            },
            loadPlugins = function()
                return { { name = "marked" } }
            end,
        })
        ZenSpec.unload("modules/menu/app_launcher/plugin_scan")

        local PluginScan = require("modules/menu/app_launcher/plugin_scan")
        local zenpm = PluginScan.scanZenPM({
            { id = "package-id", install_path = plugin_dir },
        })
        assert.are.equal(1, #zenpm)
        assert.are.equal("marked", zenpm[1].key)
        assert.are.equal("Marked menu", zenpm[1].title)
        assert.are.equal(PluginScan.SENTINEL, zenpm[1].method)
        assert.are.equal("package-id", zenpm[1].zenpm_package_id)
        assert.is_function(PluginScan.resolve(zenpm[1].key, zenpm[1].method))
        PluginScan.resolve(zenpm[1].key, zenpm[1].method)()
        assert.is_true(opened)
    end)

    it("loads current plugin items on launch and supplies their refresh function", function()
        local items = {{ text = "Reading" }}
        local shown
        local saved_host = package.loaded["modules/menu/app_launcher/menu_host"]
        finally(function()
            package.loaded["modules/menu/app_launcher/menu_host"] = saved_host
        end)
        ZenSpec.replace("modules/menu/app_launcher/menu_host", {
            show = function(opts) shown = opts; return true end,
        })
        package.loaded.pluginloader.loaded_plugins.marked.addToMainMenu = function(_self, menu)
            menu.marked = {
                text = "Profiles", sub_item_table_func = function() return items end,
            }
        end
        local PluginScan = require("modules/menu/app_launcher/plugin_scan")
        local launch = PluginScan.resolve("marked", PluginScan.SUBMENU)
        items = {{ text = "Bedtime" }}
        assert.is_true(launch())
        assert.are.equal(items, shown.item_table)
        items = {{ text = "New" }}
        assert.are.equal(items, shown.refresh_func())
        assert.is_true(launch())
        assert.are.equal(items, shown.item_table)
    end)

    it("runs the plugin menu entry's hold callback on long press", function()
        local held, closes, entry = {}, 0, nil
        local touch_menu = { closeMenu = function() closes = closes + 1 end }
        package.loaded.pluginloader.loaded_plugins.marked.addToMainMenu = function(_self, menu)
            menu.marked = entry
        end
        local PluginScan = require("modules/menu/app_launcher/plugin_scan")
        local plugin = { key = "marked", method = "open" }

        entry = { text = "Marked", callback = function() error("tapped") end }
        assert.is_false(PluginScan.hold(plugin, touch_menu))

        entry.hold_callback = function(menu, item) held[#held + 1] = { menu = menu, item = item } end
        assert.is_true(PluginScan.hold(plugin, touch_menu))
        assert.are.equal(touch_menu, held[1].menu)
        assert.are.equal(entry, held[1].item)
        assert.are.equal(0, closes)

        entry.hold_keep_menu_open = false
        entry.hold_callback_func = function() return function() held[#held + 1] = "func" end end
        assert.is_true(PluginScan.hold(plugin, touch_menu))
        assert.are.equal("func", held[2])
        assert.are.equal(1, closes)
        assert.is_true(PluginScan.hold(plugin))

        entry.hold_callback_func = function() error("broken") end
        assert.is_false(PluginScan.hold(plugin, touch_menu))
        assert.is_false(PluginScan.hold({ key = "manual" }, touch_menu))
        assert.is_false(PluginScan.hold({ key = "missing" }, touch_menu))
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
