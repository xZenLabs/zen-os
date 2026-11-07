describe("ZenOS legacy main lifecycle", function()
    local lfs
    local test_root
    local legacy_plugin
    local current_plugin
    local legacy_settings
    local current_settings
    local original_package_path
    local original_reader_settings
    local original_notice
    local original_root_guard
    local saved_modules
    local saved_preloads

    local isolated_modules = {
        "common/brand_migration",
        "common/zen_logger",
        "config/manager",
        "modules/registry",
        "modules/filebrowser/patches/home/components/registry",
        "modules/settings/zen_updater",
    }
    local mocked_modules = {
        "datastorage",
        "logger",
        "pluginloader",
        "ui/widget/container/widgetcontainer",
        "ui/widget/infomessage",
        "ui/event",
        "ui/uimanager",
    }

    local function join(parent, child)
        return parent .. "/" .. child
    end

    local function mkdir(path)
        assert.is_true(lfs.mkdir(path) == true
            or lfs.attributes(path, "mode") == "directory")
        return path
    end

    local function copy_file(from_path, to_path)
        local source = assert(io.open(from_path, "rb"))
        local contents = assert(source:read("*a"))
        source:close()
        local destination = assert(io.open(to_path, "wb"))
        assert(destination:write(contents))
        destination:close()
    end

    local function write_file(path, contents)
        local file = assert(io.open(path, "wb"))
        assert(file:write(contents))
        file:close()
    end

    local function entry_mode(path)
        if type(lfs.symlinkattributes) == "function" then
            return lfs.symlinkattributes(path, "mode")
        end
        return lfs.attributes(path, "mode")
    end

    local function remove_tree(path)
        local mode = entry_mode(path)
        if mode == "file" or mode == "link" then
            os.remove(path)
            return
        end
        if mode ~= "directory" then return end
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                remove_tree(join(path, entry))
            end
        end
        lfs.rmdir(path)
    end

    before_each(function()
        lfs = require("libs/libkoreader-lfs")
        test_root = os.tmpname()
        os.remove(test_root)
        mkdir(test_root)
        local plugins_dir = mkdir(join(test_root, "plugins"))
        local settings_dir = mkdir(join(test_root, "settings"))
        legacy_plugin = mkdir(join(plugins_dir, "zen_ui.koplugin"))
        current_plugin = join(plugins_dir, "zenos.koplugin")
        legacy_settings = mkdir(join(settings_dir, "Zen UI"))
        current_settings = join(settings_dir, "ZenOS")
        mkdir(join(legacy_plugin, "common"))
        copy_file(join(ZenSpec.root, "main.lua"), join(legacy_plugin, "main.lua"))
        copy_file(join(ZenSpec.root, "common/brand_migration.lua"),
            join(legacy_plugin, "common/brand_migration.lua"))
        write_file(join(legacy_plugin, "_meta.lua"), "return {}\n")
        write_file(join(legacy_settings, "unknown.txt"), "preserved")

        original_package_path = package.path
        package.path = legacy_plugin .. "/?.lua;" .. original_package_path
        original_reader_settings = _G.G_reader_settings
        original_notice = rawget(_G, "__ZENOS_BRAND_MIGRATION_NOTICE")
        original_root_guard = rawget(_G, "__ZENOS_PLUGIN_ROOT_GUARD")
        _G.G_reader_settings = ZenSpec.memorySettings()
        _G.__ZENOS_BRAND_MIGRATION_NOTICE = nil
        _G.__ZENOS_PLUGIN_ROOT_GUARD = nil

        saved_modules = {}
        saved_preloads = {}
        for _i, name in ipairs(isolated_modules) do
            saved_modules[name] = package.loaded[name]
            saved_preloads[name] = package.preload[name]
            package.loaded[name] = nil
        end
        for _i, name in ipairs(mocked_modules) do
            saved_modules[name] = package.loaded[name]
            saved_preloads[name] = package.preload[name]
        end
        package.loaded.pluginloader = {}
        -- Hide the runtime's real plugins dir from root-conflict probes.
        saved_modules["libs/libkoreader-lfs"] = lfs
        local runtime_plugins = lfs.currentdir() .. "/plugins/"
        local function hidden(path)
            return type(path) == "string" and path:sub(1, #runtime_plugins) == runtime_plugins
        end
        package.loaded["libs/libkoreader-lfs"] = setmetatable({
            attributes = function(path, ...)
                if hidden(path) then return nil end
                return lfs.attributes(path, ...)
            end,
            symlinkattributes = function(path, ...)
                if hidden(path) then return nil end
                return lfs.symlinkattributes(path, ...)
            end,
        }, { __index = lfs })
    end)

    after_each(function()
        package.path = original_package_path
        package.loaded["libs/libkoreader-lfs"] = saved_modules["libs/libkoreader-lfs"]
        for _i, name in ipairs(isolated_modules) do
            package.loaded[name] = saved_modules[name]
            package.preload[name] = saved_preloads[name]
        end
        for _i, name in ipairs(mocked_modules) do
            package.loaded[name] = saved_modules[name]
            package.preload[name] = saved_preloads[name]
        end
        _G.G_reader_settings = original_reader_settings
        _G.__ZENOS_BRAND_MIGRATION_NOTICE = original_notice
        _G.__ZENOS_PLUGIN_ROOT_GUARD = original_root_guard
        remove_tree(test_root)
    end)

    it("renames only when the inert legacy plugin is initialized", function()
        local normal_loads = {}
        for _i, name in ipairs(isolated_modules) do
            if name ~= "common/brand_migration" then
                local module_name = name
                package.preload[module_name] = function()
                    normal_loads[#normal_loads + 1] = module_name
                    error("normal startup module loaded: " .. module_name)
                end
            end
        end

        local shown
        local scheduled
        local restarted
        package.loaded.datastorage = {
            getSettingsDir = function()
                return join(test_root, "settings")
            end,
        }
        package.loaded.logger = {
            dbg = function() end,
            info = function() end,
            warn = function() end,
            err = function() end,
        }
        package.loaded["ui/widget/container/widgetcontainer"] = {
            extend = function(self, definition)
                definition.__index = definition
                return setmetatable(definition, { __index = self })
            end,
        }
        package.loaded["ui/widget/infomessage"] = {
            new = function(_self, attributes) return attributes end,
        }
        package.loaded["ui/event"] = {
            new = function(_self, name) return { name = name } end,
        }
        package.loaded["ui/uimanager"] = {
            show = function(_self, widget) shown = widget end,
            tickAfterNext = function(_self, callback) scheduled = callback end,
            broadcastEvent = function(_self, event) restarted = event end,
        }

        local plugin = assert(dofile(join(legacy_plugin, "main.lua")))

        assert.are.equal("zen_ui", plugin.name)
        assert.are.same({}, normal_loads)
        assert.are.equal("directory", lfs.attributes(legacy_plugin, "mode"))
        assert.are.equal("directory", lfs.attributes(legacy_settings, "mode"))
        assert.is_nil(lfs.attributes(current_plugin, "mode"))
        assert.is_nil(lfs.attributes(current_settings, "mode"))

        plugin:init()

        assert.are.same({}, normal_loads)
        assert.is_nil(lfs.attributes(legacy_plugin, "mode"))
        assert.are.equal("directory", lfs.symlinkattributes(legacy_settings, "mode"))
        assert.are.equal("file", lfs.attributes(
            join(legacy_settings, "unknown.txt"), "mode"))
        assert.are.equal("directory", lfs.attributes(current_plugin, "mode"))
        assert.are.equal("directory", lfs.attributes(current_settings, "mode"))
        assert.are.equal("file", lfs.attributes(
            join(current_settings, "unknown.txt"), "mode"))
        assert.is_truthy(shown and shown.text:match("upgrade complete"))
        assert.are.equal("function", type(scheduled))

        scheduled()
        assert.are.equal("Restart", restarted and restarted.name)
    end)

    it("uses complete settings cleanup while the migration plugin is inert", function()
        local data_dir = mkdir(join(test_root, "data"))
        local patches_dir = mkdir(join(data_dir, "patches"))
        local patch_path = join(patches_dir,
            "2-zen-ui-suppress-startup-alerts.lua")
        write_file(patch_path, "return true")
        _G.G_reader_settings = ZenSpec.memorySettings({
            zen_ui_config = { enabled = true },
            zen_ui_folder_sort = { ["/books"] = "title" },
            zen_ui_update_channel = "beta",
            zen_tags_detail_reverse_fiction = true,
            zen_page_browser_layout = "grid",
            substring_search = true,
        })
        _G.G_reader_settings.flush = function() return true end
        package.loaded.datastorage = {
            getSettingsDir = function() return join(test_root, "settings") end,
            getDataDir = function() return data_dir end,
        }
        package.loaded.logger = {
            dbg = function() end,
            info = function() end,
            warn = function() end,
            err = function() end,
        }
        package.loaded["ui/widget/container/widgetcontainer"] = {
            extend = function(self, definition)
                definition.__index = definition
                return setmetatable(definition, { __index = self })
            end,
        }

        local plugin = assert(dofile(join(legacy_plugin, "main.lua")))
        assert.is_true(plugin:deletePluginSettings())

        assert.is_nil(entry_mode(legacy_settings))
        assert.is_nil(_G.G_reader_settings:readSetting("zen_ui_config"))
        assert.is_nil(_G.G_reader_settings:readSetting("zen_ui_folder_sort"))
        assert.is_nil(_G.G_reader_settings:readSetting("zen_ui_update_channel"))
        assert.is_nil(_G.G_reader_settings:readSetting(
            "zen_tags_detail_reverse_fiction"))
        assert.is_nil(_G.G_reader_settings:readSetting("zen_page_browser_layout"))
        assert.is_true(_G.G_reader_settings:readSetting("substring_search"))
        assert.is_nil(entry_mode(patch_path))
    end)

    it("shows a failure notice without scheduling restart after a save failure", function()
        local shown
        local scheduled
        package.loaded["ui/widget/infomessage"] = {
            new = function(_self, attributes) return attributes end,
        }
        package.loaded["ui/uimanager"] = {
            show = function(_self, widget) shown = widget end,
            tickAfterNext = function(_self, callback) scheduled = callback end,
        }

        require("common/brand_migration").notify({
            inert = true,
            status = "migration_save_failed",
        })

        assert.is_truthy(shown and shown.text:match("could not save"))
        assert.is_nil(scheduled)
    end)
end)
