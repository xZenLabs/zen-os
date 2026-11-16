require("ffi/loadlib")
describe("ZenOS brand migration", function()
    local BrandMigration
    local lfs
    local test_root
    local plugins_dir
    local settings_dir
    local fake_lua_settings
    local original_logger
    local migration_logs

    local function path(parent, child)
        return parent .. "/" .. child
    end

    local function write_file(filename, contents)
        local file = assert(io.open(filename, "w"))
        assert(file:write(contents or "fixture"))
        file:close()
    end

    local function read_file(filename)
        local file = assert(io.open(filename, "r"))
        local contents = assert(file:read("*a"))
        file:close()
        return contents
    end

    local function serialize(value)
        local kind = type(value)
        if kind == "string" then return string.format("%q", value) end
        if kind == "number" or kind == "boolean" then return tostring(value) end
        if kind ~= "table" then return "nil" end
        local fields = { "{" }
        for key, item in pairs(value) do
            fields[#fields + 1] = "[" .. serialize(key) .. "]="
                .. serialize(item) .. ","
        end
        fields[#fields + 1] = "}"
        return table.concat(fields)
    end

    local function entry_mode(filename)
        if type(lfs.symlinkattributes) == "function" then
            return lfs.symlinkattributes(filename, "mode")
        end
        return lfs.attributes(filename, "mode")
    end

    local function remove_tree(filename)
        local mode = entry_mode(filename)
        if mode == "file" or mode == "link" then
            os.remove(filename)
            return
        end
        if mode ~= "directory" then return end
        for entry in lfs.dir(filename) do
            if entry ~= "." and entry ~= ".." then
                remove_tree(path(filename, entry))
            end
        end
        lfs.rmdir(filename)
    end

    local function mkdir(filename)
        assert.is_true(lfs.mkdir(filename) == true
            or lfs.attributes(filename, "mode") == "directory")
        return filename
    end

    local function capture_log(level, ...)
        local fields = { level }
        for index = 1, select("#", ...) do
            fields[#fields + 1] = tostring(select(index, ...))
        end
        migration_logs[#migration_logs + 1] = table.concat(fields, " ")
    end

    local function find_result_log(status)
        local needle = "status=" .. status
        for _i, message in ipairs(migration_logs) do
            if message:find("ZenOS: [migration] result", 1, true)
                    and message:find(needle, 1, true) then
                return message
            end
        end
    end

    local function migration_options(plugin_root, g_settings, extra)
        local options = {
            plugin_root = plugin_root,
            settings_dir = settings_dir,
            lfs = lfs,
            g_settings = g_settings or ZenSpec.memorySettings(),
            lua_settings = fake_lua_settings,
            -- Keep the runtime's real plugins dir out of root-conflict probes.
            default_plugin_path = path(test_root, "missing-default-plugins"),
        }
        for key, value in pairs(extra or {}) do options[key] = value end
        return options
    end

    before_each(function()
        lfs = require("libs/libkoreader-lfs")
        original_logger = package.loaded.logger
        migration_logs = {}
        package.loaded.logger = {
            dbg = function(...) capture_log("dbg", ...) end,
            info = function(...) capture_log("info", ...) end,
            warn = function(...) capture_log("warn", ...) end,
            err = function(...) capture_log("err", ...) end,
        }
        ZenSpec.unload("common/brand_migration")
        BrandMigration = require("common/brand_migration")
        fake_lua_settings = {
            open = function(_self, filename)
                fake_lua_settings.open_count = fake_lua_settings.open_count + 1
                local ok, data = pcall(dofile, filename)
                if not ok or type(data) ~= "table" then
                    ok, data = pcall(dofile, filename .. ".old")
                end
                local settings = {
                    data = ok and type(data) == "table" and data or {},
                    file = filename,
                }
                function settings:readSetting(key) return self.data[key] end
                function settings:saveSetting(key, value) self.data[key] = value end
                function settings:delSetting(key) self.data[key] = nil end
                function settings:backup()
                    if fake_lua_settings.rotate_on_flush
                            and not fake_lua_settings.rotated[filename]
                            and not filename:match("%.old$")
                            and lfs.attributes(filename, "mode") == "file" then
                        assert(os.rename(filename, filename .. ".old"))
                        fake_lua_settings.rotated[filename] = true
                    end
                end
                function settings:flush()
                    local failure = fake_lua_settings.flush_failures[filename]
                    if failure == "silent" then return true end
                    if failure then return false end
                    self:backup()
                    write_file(filename, "return " .. serialize(self.data) .. "\n")
                    return true
                end
                return settings
            end,
            open_count = 0,
            rotate_on_flush = false,
            rotated = {},
            flush_failures = {},
        }
        test_root = os.tmpname()
        os.remove(test_root)
        mkdir(test_root)
        plugins_dir = mkdir(path(test_root, "plugins"))
        settings_dir = mkdir(path(test_root, "settings"))
        _G.__ZENOS_BRAND_MIGRATION_NOTICE = nil
        _G.__ZENOS_PLUGIN_ROOT_GUARD = nil
    end)

    after_each(function()
        package.loaded.logger = original_logger
        remove_tree(test_root)
        _G.__ZENOS_BRAND_MIGRATION_NOTICE = nil
        _G.__ZENOS_PLUGIN_ROOT_GUARD = nil
    end)

    it("derives metadata identity from the installed plugin directory", function()
        local metadata_source = read_file(path(ZenSpec.root, "_meta.lua"))
        local legacy_plugin = mkdir(path(plugins_dir, "zen_ui.koplugin"))
        local current_plugin = mkdir(path(plugins_dir, "zenos.koplugin"))
        write_file(path(legacy_plugin, "_meta.lua"), metadata_source)
        write_file(path(current_plugin, "_meta.lua"), metadata_source)

        local legacy = dofile(path(legacy_plugin, "_meta.lua"))
        local current = dofile(path(current_plugin, "_meta.lua"))

        assert.are.equal("zen_ui", legacy.name)
        assert.are.equal("zenos", current.name)
        assert.are.equal("ZenOS", legacy.fullname)
        assert.are.equal("ZenOS", current.fullname)
    end)

    it("aliases legacy runtime lookups to the canonical live instance", function()
        local plugin = { ui = {} }
        local plugin_loader = {
            loaded_plugins = {},
        }

        local loader_aliased, ui_aliased =
            BrandMigration.installLegacyRuntimeAliases(plugin, {
                plugin_loader = plugin_loader,
            })

        assert.is_true(loader_aliased)
        assert.is_true(ui_aliased)
        assert.are.equal(plugin, plugin_loader.loaded_plugins.zen_ui)
        assert.are.equal(plugin, plugin.ui.zen_ui)

        local unrelated_current = {}
        local unrelated = {}
        plugin_loader.loaded_plugins.zenos = unrelated_current
        plugin_loader.loaded_plugins.zen_ui = unrelated
        plugin.ui.zen_ui = unrelated
        BrandMigration.installLegacyRuntimeAliases(plugin, {
            plugin_loader = plugin_loader,
        })
        assert.are.equal(unrelated_current, plugin_loader.loaded_plugins.zenos)
        assert.are.equal(unrelated, plugin_loader.loaded_plugins.zen_ui)
        assert.are.equal(unrelated, plugin.ui.zen_ui)
    end)

    it("does not turn an empty fresh config into migrated settings", function()
        local current_plugin = mkdir(path(plugins_dir, "zenos.koplugin"))
        local current_settings = mkdir(path(settings_dir, "ZenOS"))
        local config_path = path(current_settings, "config.lua")
        write_file(config_path, "return {}\n")

        local result = BrandMigration.detectStartup(
            nil, migration_options(current_plugin))

        assert.are.equal("current", result.status)
        assert.are.same({}, dofile(config_path))
    end)

    it("parses a marked config once and hands it to its owner", function()
        local current_plugin = mkdir(path(plugins_dir, "zenos.koplugin"))
        local current_settings = mkdir(path(settings_dir, "ZenOS"))
        local config_path = path(current_settings, "config.lua")
        write_file(config_path, "return { _meta = { zenos_brand_migration_v1 = true } }\n")
        local opens = 0
        local LuaSettings = require("luasettings")
        local counting = setmetatable({
            open = function(self, file)
                opens = opens + 1
                return LuaSettings.open(self, file)
            end,
        }, { __index = LuaSettings })
        local saved = package.loaded.luasettings
        package.loaded.luasettings = counting
        local ok, err = pcall(function()
            local options = migration_options(current_plugin)
            options.lua_settings = nil
            assert.are.equal("current", BrandMigration.detectStartup(nil, options).status)
            assert.are.equal(1, opens)
            assert.is_true(BrandMigration.readConfigData(config_path)._meta.zenos_brand_migration_v1)
            local settings = BrandMigration.takeConfigSettings(config_path)
            assert.are.equal(1, opens)
            assert.are.equal(config_path, settings.file)
            assert.is_nil(BrandMigration.takeConfigSettings(config_path))
            assert.are.equal("table", type(BrandMigration.preparedSettings(settings_dir)))
            assert.is_nil(BrandMigration.preparedSettings(settings_dir))
        end)
        package.loaded.luasettings = saved
        assert(ok, err)
    end)

    it("defers the legacy directory rename until plugin init", function()
        local legacy_plugin = mkdir(path(plugins_dir, "zen_ui.koplugin"))
        local legacy_settings = mkdir(path(settings_dir, "Zen UI"))
        write_file(path(legacy_plugin, "_meta.lua"), "return {}")
        write_file(path(legacy_settings, "unknown.txt"), "preserve me")

        local result = BrandMigration.detectStartup(
            nil, migration_options(legacy_plugin))

        assert.is_true(result.pending)
        assert.are.equal("directory", lfs.attributes(legacy_plugin, "mode"))
        assert.are.equal("file", lfs.attributes(
            path(legacy_plugin, "_meta.lua"), "mode"))
        assert.are.equal("directory", lfs.attributes(legacy_settings, "mode"))
        assert.is_nil(lfs.attributes(path(plugins_dir, "zenos.koplugin"), "mode"))
        assert.is_nil(lfs.attributes(path(settings_dir, "ZenOS"), "mode"))
        assert.are.equal(0, fake_lua_settings.open_count)
    end)

    it("copies settings for ZenOS and preserves the Zen UI rollback snapshot", function()
        local legacy_plugin = mkdir(path(plugins_dir, "zen_ui.koplugin"))
        local legacy_settings = mkdir(path(settings_dir, "Zen UI"))
        local current_plugin = path(plugins_dir, "zenos.koplugin")
        write_file(path(legacy_plugin, "_meta.lua"), "return {}")
        write_file(path(legacy_settings, "unknown.txt"), "preserve me")
        write_file(path(legacy_settings, "config.lua"), string.format(
            "return { library_font = { font_face = %q } }\n",
            legacy_plugin .. "/fonts/Regular.ttf"))
        local reader_fixture = [[
return {
    active_preset = "(Zen UI) Chapter Time + %",
    settings = {
        reader_footer_custom_text = "Zen UI",
        footer = { text_font_face = __FONT_PATH__ },
    },
    presets = {
        ["(Zen UI) Chapter Time + %"] = {
            name = "(Zen UI) Chapter Time + %",
            reader_footer_custom_text = "Zen UI",
        },
        custom = {
            name = "custom",
            reader_footer_custom_text = "Zen UI",
        },
    },
}
]]
        reader_fixture = reader_fixture:gsub(
            "__FONT_PATH__", string.format("%q", legacy_plugin .. "/fonts/SemiBold.ttf"))
        write_file(path(legacy_settings, "reader.lua"), reader_fixture)
        local global_path = path(test_root, "settings.reader.lua")
        write_file(global_path, string.format([[
return {
    plugins_disabled = { zen_ui = false },
    footer = { text_font_face = %q },
    reader_footer_custom_text = "Zen UI",
}
]], legacy_plugin .. "/fonts/SemiBold.ttf"))
        local g_settings = fake_lua_settings:open(global_path)
        fake_lua_settings.rotate_on_flush = true

        local pending = BrandMigration.detectStartup(
            nil, migration_options(legacy_plugin, g_settings))
        local result = BrandMigration.performPending(pending)

        assert.are.equal("migrated", result.status)
        assert.is_true(result.restart)
        assert.is_true(result.plugin_renamed)
        assert.is_true(result.settings.copied)
        assert.is_true(result.settings.legacy_preserved)
        assert.is_true(result.disabled_state_transferred)
        assert.is_true(result.disabled_state_saved)
        assert.is_true(result.persisted_paths_saved)
        assert.is_true(result.persisted_global_changed)
        assert.is_true(result.persisted_files_changed > 0)
        assert.is_true(result.snapshot_attempted)
        assert.is_true(result.legacy_settings_snapshot_created)
        assert.is_true(result.legacy_settings_preserved)
        local result_log = assert(find_result_log("migrated"))
        assert.is_truthy(result_log:find("info ", 1, true))
        assert.is_truthy(result_log:find("plugin_renamed=true", 1, true))
        assert.is_truthy(result_log:find("settings_renamed=n/a", 1, true))
        assert.is_truthy(result_log:find("settings_copied=true", 1, true))
        assert.is_truthy(result_log:find("legacy_preserved=true", 1, true))
        assert.is_truthy(result_log:find("disabled_saved=true", 1, true))
        assert.is_truthy(result_log:find("paths_saved=true", 1, true))
        assert.is_truthy(result_log:find("snapshot=created", 1, true))
        assert.is_truthy(result_log:find("restart=true", 1, true))
        assert.is_nil(lfs.attributes(legacy_plugin, "mode"))
        assert.are.equal("directory", lfs.attributes(current_plugin, "mode"))
        local current_settings = path(settings_dir, "ZenOS")
        assert.are.equal("preserve me",
            read_file(path(current_settings, "unknown.txt")))
        assert.are.equal("preserve me",
            read_file(path(legacy_settings, "unknown.txt")))

        local legacy_config = dofile(path(legacy_settings, "config.lua"))
        assert.are.equal(legacy_plugin .. "/fonts/Regular.ttf",
            legacy_config.library_font.font_face)
        assert.is_nil(legacy_config._meta)
        local legacy_reader = dofile(path(legacy_settings, "reader.lua"))
        assert.are.equal("(Zen UI) Chapter Time + %",
            legacy_reader.active_preset)
        assert.are.equal(legacy_plugin .. "/fonts/SemiBold.ttf",
            legacy_reader.settings.footer.text_font_face)

        local config = dofile(path(current_settings, "config.lua"))
        assert.are.equal(current_plugin .. "/fonts/Regular.ttf",
            config.library_font.font_face)
        assert.is_true(config._meta.zenos_brand_migration_v1)
        local reader = dofile(path(current_settings, "reader.lua"))
        assert.are.equal("(ZenOS) Chapter Time + %", reader.active_preset)
        assert.is_nil(reader.presets["(Zen UI) Chapter Time + %"])
        assert.are.equal("ZenOS",
            reader.presets["(ZenOS) Chapter Time + %"].reader_footer_custom_text)
        assert.are.equal("Zen UI", reader.presets.custom.reader_footer_custom_text)
        assert.are.equal(current_plugin .. "/fonts/SemiBold.ttf",
            g_settings:readSetting("footer").text_font_face)
        assert.are.equal("ZenOS",
            g_settings:readSetting("reader_footer_custom_text"))
        assert.is_nil(g_settings:readSetting("plugins_disabled").zen_ui)
        assert.is_false(g_settings:readSetting("plugins_disabled").zenos)
        local config_backup = dofile(path(current_settings, "config.lua.old"))
        assert.are.equal(current_plugin .. "/fonts/Regular.ttf",
            config_backup.library_font.font_face)
        assert.is_nil(config_backup._meta and
            config_backup._meta.zenos_brand_migration_v1)
        local reader_backup = dofile(path(current_settings, "reader.lua.old"))
        assert.are.equal("(ZenOS) Chapter Time + %", reader_backup.active_preset)
        assert.are.equal(current_plugin .. "/fonts/SemiBold.ttf",
            reader_backup.settings.footer.text_font_face)
        local global_backup = dofile(global_path .. ".old")
        assert.is_nil(global_backup.plugins_disabled.zen_ui)
        assert.is_false(global_backup.plugins_disabled.zenos)
        assert.are.equal(current_plugin .. "/fonts/SemiBold.ttf",
            global_backup.footer.text_font_face)
        assert.are.equal("ZenOS", global_backup.reader_footer_custom_text)

        write_file(path(current_settings, "reader.lua"), "corrupt")
        local recovered_reader = fake_lua_settings:open(
            path(current_settings, "reader.lua")).data
        assert.are.equal("(ZenOS) Chapter Time + %",
            recovered_reader.active_preset)
        write_file(global_path, "corrupt")
        local recovered_global = fake_lua_settings:open(global_path).data
        assert.are.equal(current_plugin .. "/fonts/SemiBold.ttf",
            recovered_global.footer.text_font_face)

        local open_count = fake_lua_settings.open_count
        BrandMigration.rewritePersistedPaths(
            current_settings, legacy_plugin, current_plugin,
            migration_options(current_plugin, g_settings))
        assert.are.equal(open_count + 1, fake_lua_settings.open_count)
    end)

    it("rolls the settings directory back when the plugin rename fails", function()
        local legacy_plugin = mkdir(path(plugins_dir, "zen_ui.koplugin"))
        local legacy_settings = mkdir(path(settings_dir, "Zen UI"))
        write_file(path(legacy_settings, "config.lua"), "return { preserved = true }")
        local options = migration_options(legacy_plugin, nil, {
            rename = function(from_path, to_path)
                if from_path == legacy_plugin then return nil, "injected failure" end
                return os.rename(from_path, to_path)
            end,
        })

        local pending = BrandMigration.detectStartup(nil, options)
        local result = BrandMigration.performPending(pending)

        assert.are.equal("plugin_rename_failed", result.status)
        assert.is_false(result.plugin_renamed)
        assert.is_true(result.settings_rollback_attempted)
        assert.is_true(result.settings_rollback_succeeded)
        local result_log = assert(find_result_log("plugin_rename_failed"))
        assert.is_truthy(result_log:find("warn ", 1, true))
        assert.is_truthy(result_log:find("plugin_renamed=false", 1, true))
        assert.is_truthy(result_log:find("rollback=succeeded", 1, true))
        assert.is_truthy(result_log:find("restart=false", 1, true))
        assert.are.equal("directory", lfs.attributes(legacy_plugin, "mode"))
        assert.are.equal("directory", lfs.attributes(legacy_settings, "mode"))
        assert.are.equal(true, dofile(path(legacy_settings, "config.lua")).preserved)
        assert.is_nil(lfs.attributes(path(plugins_dir, "zenos.koplugin"), "mode"))
        assert.is_nil(lfs.attributes(path(settings_dir, "ZenOS"), "mode"))
    end)

    it("does not overwrite duplicate plugin or non-empty settings directories", function()
        local legacy_plugin = mkdir(path(plugins_dir, "zen_ui.koplugin"))
        mkdir(path(plugins_dir, "zenos.koplugin"))
        local legacy_settings = mkdir(path(settings_dir, "Zen UI"))
        local current_settings = mkdir(path(settings_dir, "ZenOS"))
        write_file(path(legacy_settings, "legacy.txt"), "legacy")
        write_file(path(current_settings, "current.txt"), "current")

        local result = BrandMigration.detectStartup(
            nil, migration_options(legacy_plugin))

        assert.are.equal("plugin_conflict", result.status)
        assert.is_true(result.inert)
        assert.are.equal("legacy", read_file(path(legacy_settings, "legacy.txt")))
        assert.are.equal("current", read_file(path(current_settings, "current.txt")))

        remove_tree(path(plugins_dir, "zenos.koplugin"))
        local pending = BrandMigration.detectStartup(
            nil, migration_options(legacy_plugin))
        local settings_result = BrandMigration.performPending(pending)
        assert.are.equal("settings_conflict", settings_result.status)
        assert.are.equal("directory", lfs.attributes(legacy_plugin, "mode"))
    end)

    it("guards plugin copies loaded from different plugin roots", function()
        local first_parent = mkdir(path(test_root, "first_plugins"))
        local second_parent = mkdir(path(test_root, "second_plugins"))
        local legacy_plugin = mkdir(path(first_parent, "zen_ui.koplugin"))
        local current_plugin = mkdir(path(second_parent, "zenos.koplugin"))

        local current = BrandMigration.detectStartup(
            nil, migration_options(current_plugin))
        assert.is_true(current.proceed)
        local legacy = BrandMigration.detectStartup(
            nil, migration_options(legacy_plugin))
        assert.are.equal("plugin_conflict", legacy.status)

        local rechecked = BrandMigration.checkRootConflict(current)
        assert.are.equal("plugin_conflict", rechecked.status)
        assert.is_true(rechecked.inert)
        assert.are.equal("directory", lfs.attributes(legacy_plugin, "mode"))
        assert.are.equal("directory", lfs.attributes(current_plugin, "mode"))
    end)

    it("discovers cross-parent duplicates before mutating real settings", function()
        local first_parent = mkdir(path(test_root, "first_plugins"))
        local second_parent = mkdir(path(test_root, "second_plugins"))
        local legacy_plugin = mkdir(path(first_parent, "zen_ui.koplugin"))
        local current_plugin = mkdir(path(second_parent, "zenos.koplugin"))
        local legacy_settings = mkdir(path(settings_dir, "Zen UI"))
        local config_path = path(legacy_settings, "config.lua")
        local config_contents = string.format(
            "return { fixture = %q, font = %q }\n",
            "unchanged", legacy_plugin .. "/fonts/Regular.ttf")
        write_file(config_path, config_contents)
        local g_settings = ZenSpec.memorySettings({
            plugins_disabled = { zen_ui = true },
            extra_plugin_paths = { first_parent },
        })

        local result = BrandMigration.detectStartup(nil,
            migration_options(current_plugin, g_settings))

        assert.are.equal("plugin_conflict", result.status)
        assert.is_true(result.inert)
        assert.is_nil(result.pending)
        assert.are.same({ legacy_plugin, current_plugin }, result.conflict_paths)
        assert.are.equal(config_contents, read_file(config_path))
        assert.are.equal("directory", lfs.attributes(legacy_settings, "mode"))
        assert.is_nil(lfs.attributes(path(settings_dir, "ZenOS"), "mode"))
        assert.are.equal("directory", lfs.attributes(legacy_plugin, "mode"))
        assert.are.equal("directory", lfs.attributes(current_plugin, "mode"))
        local disabled = g_settings:readSetting("plugins_disabled")
        assert.is_true(disabled.zen_ui)
        assert.is_nil(disabled.zenos)
    end)

    it("probes configured lookup paths instead of rescanning plugin dirs", function()
        local first_parent = mkdir(path(test_root, "first_plugins"))
        local second_parent = mkdir(path(test_root, "second_plugins"))
        local legacy_plugin = mkdir(path(first_parent, "zen_ui.koplugin"))
        local current_plugin = mkdir(path(second_parent, "zenos.koplugin"))
        local g_settings = ZenSpec.memorySettings({
            extra_plugin_paths = { first_parent, second_parent },
        })
        local discover_calls = 0
        local plugin_loader = {
            _discover = function() discover_calls = discover_calls + 1 end,
        }

        local result = BrandMigration.detectStartup(nil,
            migration_options(current_plugin, g_settings, {
                plugin_loader = plugin_loader,
                default_plugin_path = path(test_root, "missing-default-plugins"),
            }))

        assert.are.equal(0, discover_calls)
        assert.are.equal("plugin_conflict", result.status)
        assert.are.same({ legacy_plugin, current_plugin }, result.conflict_paths)
    end)

    it("replaces an empty ZenOS directory with a copy of the legacy tree", function()
        local legacy_settings = mkdir(path(settings_dir, "Zen UI"))
        local current_settings = mkdir(path(settings_dir, "ZenOS"))
        write_file(path(legacy_settings, "config.lua"), "return { migrated = true }")

        local result = BrandMigration.prepareSettings(settings_dir, { lfs = lfs })

        assert.are.equal("migrated", result.status)
        assert.is_true(result.copied)
        assert.are.equal("directory", lfs.attributes(legacy_settings, "mode"))
        assert.are.equal(true, dofile(path(current_settings, "config.lua")).migrated)
        assert.are.equal(true, dofile(path(legacy_settings, "config.lua")).migrated)
    end)

    it("finishes reader branding after an interrupted partial migration", function()
        local current_settings = mkdir(path(settings_dir, "ZenOS"))
        local legacy_plugin = path(plugins_dir, "zen_ui.koplugin")
        local current_plugin = path(plugins_dir, "zenos.koplugin")
        write_file(path(current_settings, "config.lua"), "return { _meta = {} }")
        write_file(path(current_settings, "reader.lua"), [[
return {
    active_preset = "(ZenOS) Chapter Time + %",
    settings = { reader_footer_custom_text = "Zen UI" },
    presets = {
        ["(ZenOS) Chapter Time + %"] = {
            name = "(ZenOS) Chapter Time + %",
            reader_footer_custom_text = "Zen UI",
        },
        custom = { name = "custom", reader_footer_custom_text = "Zen UI" },
    },
}
]])
        local g_settings = ZenSpec.memorySettings({
            reader_footer_custom_text = "Zen UI",
        })

        BrandMigration.rewritePersistedPaths(
            current_settings, legacy_plugin, current_plugin,
            migration_options(current_plugin, g_settings))

        local reader = dofile(path(current_settings, "reader.lua"))
        assert.are.equal("ZenOS", reader.settings.reader_footer_custom_text)
        assert.are.equal("ZenOS",
            reader.presets["(ZenOS) Chapter Time + %"].reader_footer_custom_text)
        assert.are.equal("Zen UI", reader.presets.custom.reader_footer_custom_text)
        assert.are.equal("ZenOS",
            g_settings:readSetting("reader_footer_custom_text"))
    end)

    it("preserves colliding reader presets under a deterministic deletable name", function()
        local current_settings = mkdir(path(settings_dir, "ZenOS"))
        local legacy_plugin = path(plugins_dir, "zen_ui.koplugin")
        local current_plugin = path(plugins_dir, "zenos.koplugin")
        write_file(path(current_settings, "config.lua"), "return { _meta = {} }")
        write_file(path(current_settings, "reader.lua"), [[
return {
    active_preset = "(Zen UI) Chapter Time + %",
    presets = {
        ["(Zen UI) Chapter Time + %"] = {
            name = "(Zen UI) Chapter Time + %",
            builtin = true,
            marker = "legacy",
            reader_footer_custom_text = "Zen UI",
        },
        ["(ZenOS) Chapter Time + %"] = {
            name = "(ZenOS) Chapter Time + %",
            builtin = true,
            marker = "current",
            reader_footer_custom_text = "ZenOS",
        },
    },
}
]])

        local saved = select(3, BrandMigration.rewritePersistedPaths(
                current_settings, legacy_plugin, current_plugin,
                migration_options(current_plugin, nil, { force = true })))

        assert.is_true(saved)
        local reader = dofile(path(current_settings, "reader.lua"))
        local migrated_name = "(ZenOS) Chapter Time + % (migrated from Zen UI)"
        assert.is_nil(reader.presets["(Zen UI) Chapter Time + %"])
        assert.are.equal("current",
            reader.presets["(ZenOS) Chapter Time + %"].marker)
        assert.are.equal("legacy", reader.presets[migrated_name].marker)
        assert.are.equal(migrated_name, reader.presets[migrated_name].name)
        assert.is_false(reader.presets[migrated_name].builtin)
        assert.are.equal(migrated_name, reader.active_preset)
    end)

    it("moves generic rewritten-key collisions without overwriting either value", function()
        local legacy_root = path(plugins_dir, "zen_ui.koplugin")
        local current_root = path(plugins_dir, "zenos.koplugin")
        local legacy_key = legacy_root .. "/fonts/Regular.ttf"
        local current_key = current_root .. "/fonts/Regular.ttf"
        local values = {
            [legacy_key] = { marker = "legacy" },
            [current_key] = { marker = "current" },
        }

        assert.is_true(BrandMigration.rewriteTablePaths(
            values, legacy_root, current_root))

        local migrated_key = current_key .. " (migrated from " .. legacy_key .. ")"
        assert.is_nil(values[legacy_key])
        assert.are.equal("current", values[current_key].marker)
        assert.are.equal("legacy", values[migrated_key].marker)
    end)

    it("keeps the legacy settings tree after a copy failure", function()
        local legacy_settings = mkdir(path(settings_dir, "Zen UI"))
        write_file(path(legacy_settings, "config.lua"), "return { preserved = true }")

        local result = BrandMigration.prepareSettings(settings_dir, {
            lfs = lfs,
            copy_file = function() return false, "injected failure" end,
        })

        assert.is_false(result.ok)
        assert.are.equal("settings_copy_failed", result.status)
        assert.are.equal(legacy_settings, result.root)
        assert.are.equal(true, dofile(path(result.root, "config.lua")).preserved)
        assert.is_nil(lfs.attributes(path(settings_dir, "ZenOS"), "mode"))
    end)

    it("copies a valid legacy settings symlink without changing its target", function()
        if type(lfs.link) ~= "function" then return pending("lfs.link unavailable") end
        local legacy_plugin = mkdir(path(plugins_dir, "zen_ui.koplugin"))
        local outside = mkdir(path(test_root, "external-settings"))
        local legacy_settings = path(settings_dir, "Zen UI")
        local current_settings = path(settings_dir, "ZenOS")
        write_file(path(outside, "config.lua"), "return { preserved = true }")
        assert.is_true(lfs.link(outside, legacy_settings, true))

        local pending_result = BrandMigration.detectStartup(
            nil, migration_options(legacy_plugin))
        local result = BrandMigration.performPending(pending_result)

        assert.are.equal("migrated", result.status)
        assert.is_true(result.legacy_settings_preserved)
        assert.are.equal("directory", lfs.symlinkattributes(current_settings, "mode"))
        assert.are.equal("link", lfs.symlinkattributes(legacy_settings, "mode"))
        assert.are.equal(outside, lfs.symlinkattributes(legacy_settings, "target"))
        assert.are.equal(true, dofile(path(current_settings, "config.lua")).preserved)

        local prepared = BrandMigration.prepareSettings(settings_dir, { lfs = lfs })
        assert.are.equal("current", prepared.status)
        assert.is_true(prepared.legacy_preserved)

        BrandMigration.removeSettings({ settings_dir = settings_dir, lfs = lfs })
        assert.are.equal("file", lfs.attributes(path(outside, "config.lua"), "mode"))
    end)

    it("does not overwrite a broken settings destination symlink", function()
        if type(lfs.link) ~= "function" then return pending("lfs.link unavailable") end
        local legacy_settings = mkdir(path(settings_dir, "Zen UI"))
        local destination = path(settings_dir, "ZenOS")
        write_file(path(legacy_settings, "config.lua"), "return { preserved = true }")
        assert.is_true(lfs.link(path(test_root, "missing"), destination, true))

        local result = BrandMigration.prepareSettings(settings_dir, { lfs = lfs })

        assert.are.equal("settings_destination_invalid", result.status)
        assert.are.equal("directory", lfs.attributes(legacy_settings, "mode"))
        assert.are.equal("link", lfs.symlinkattributes(destination, "mode"))
    end)

    it("accepts a valid current settings symlink and rejects non-directory links", function()
        if type(lfs.link) ~= "function" then return pending("lfs.link unavailable") end
        local outside = mkdir(path(test_root, "current-settings"))
        local current = path(settings_dir, "ZenOS")
        local legacy = path(settings_dir, "Zen UI")
        assert.is_true(lfs.link(outside, current, true))

        local valid = BrandMigration.prepareSettings(settings_dir, { lfs = lfs })
        assert.are.equal("current", valid.status)
        assert.are.equal(current, valid.root)

        os.remove(current)
        local file_target = path(test_root, "not-a-directory")
        write_file(file_target, "file")
        assert.is_true(lfs.link(file_target, legacy, true))
        local invalid = BrandMigration.prepareSettings(settings_dir, { lfs = lfs })
        assert.are.equal("legacy_settings_invalid", invalid.status)
    end)

    it("materializes an old downgrade alias as a legacy settings snapshot", function()
        if type(lfs.link) ~= "function" then return pending("lfs.link unavailable") end
        local current_plugin = mkdir(path(plugins_dir, "zenos.koplugin"))
        local current_settings = mkdir(path(settings_dir, "ZenOS"))
        local current_font = "fonts/hyperreadable/Hyperreadable-Regular.ttf"
        write_file(path(current_settings, "config.lua"), string.format(
            "return { _meta = { zenos_brand_migration_v1 = true }, "
                .. "library_font = { font_face = %q } }", current_font))
        local legacy_settings = path(settings_dir, "Zen UI")
        assert.is_true(lfs.link("ZenOS", legacy_settings, true))

        local result = BrandMigration.detectStartup(
            nil, migration_options(current_plugin))

        assert.are.equal("current", result.status)
        assert.is_true(result.proceed)
        assert.is_true(result.legacy_settings_snapshot_materialized)
        assert.are.equal("directory", lfs.symlinkattributes(legacy_settings, "mode"))
        assert.are.equal("default",
            dofile(path(legacy_settings, "config.lua")).library_font.font_face)
        assert.are.equal(current_font,
            dofile(path(current_settings, "config.lua")).library_font.font_face)
        local result_log = assert(find_result_log("current"))
        assert.is_truthy(result_log:find("info ", 1, true))
        assert.is_truthy(result_log:find("snapshot=materialized", 1, true))

        local repeated = BrandMigration.detectStartup(
            nil, migration_options(current_plugin))
        assert.is_true(repeated.legacy_settings_preserved)
        assert.is_false(repeated.legacy_settings_snapshot_materialized)
    end)

    it("preserves disabled intent on a canonical manual replacement", function()
        local current_plugin = mkdir(path(plugins_dir, "zenos.koplugin"))
        local g_settings = ZenSpec.memorySettings({
            plugins_disabled = { zen_ui = true },
        })

        local result = BrandMigration.detectStartup(
            nil, migration_options(current_plugin, g_settings))

        assert.are.equal("disabled_state_migrated", result.status)
        assert.is_true(result.inert)
        assert.is_true(result.restart)
        assert.is_nil(g_settings:readSetting("plugins_disabled").zen_ui)
        assert.is_true(g_settings:readSetting("plugins_disabled").zenos)
    end)

    it("does not report migration success when rewritten settings cannot be saved", function()
        local legacy_plugin = mkdir(path(plugins_dir, "zen_ui.koplugin"))
        local legacy_settings = mkdir(path(settings_dir, "Zen UI"))
        local current_plugin = path(plugins_dir, "zenos.koplugin")
        local current_settings = path(settings_dir, "ZenOS")
        write_file(path(legacy_settings, "config.lua"), string.format(
            "return { font = %q }", legacy_plugin .. "/fonts/Regular.ttf"))
        fake_lua_settings.flush_failures[path(current_settings, "config.lua")] = "silent"

        local pending_result = BrandMigration.detectStartup(
            nil, migration_options(legacy_plugin))
        local result = BrandMigration.performPending(pending_result)

        assert.are.equal("migration_save_failed", result.status)
        assert.is_true(result.inert)
        assert.is_nil(result.restart)
        assert.is_true(result.plugin_renamed)
        assert.is_true(result.disabled_state_saved)
        assert.is_false(result.persisted_paths_saved)
        assert.is_false(result.snapshot_attempted == true)
        local result_log = assert(find_result_log("migration_save_failed"))
        assert.is_truthy(result_log:find("warn ", 1, true))
        assert.is_truthy(result_log:find("plugin_renamed=true", 1, true))
        assert.is_truthy(result_log:find("disabled_saved=true", 1, true))
        assert.is_truthy(result_log:find("paths_saved=false", 1, true))
        assert.is_truthy(result_log:find("snapshot=not_attempted", 1, true))
        assert.is_truthy(result_log:find("restart=false", 1, true))
        assert.are.equal(legacy_plugin .. "/fonts/Regular.ttf",
            dofile(path(current_settings, "config.lua")).font)
        assert.are.equal("directory", lfs.attributes(current_plugin, "mode"))
    end)

    it("reports a failed global path save through the settings API", function()
        local legacy_plugin = path(plugins_dir, "zen_ui.koplugin")
        local current_plugin = path(plugins_dir, "zenos.koplugin")
        local footer = {
            text_font_face = legacy_plugin .. "/fonts/SemiBold.ttf",
        }
        local g_settings = {
            readSetting = function(_self, key)
                if key == "footer" then return footer end
            end,
            saveSetting = function() return false end,
            flush = function() return true end,
        }

        local saved = select(3, BrandMigration.rewritePersistedPaths(
            path(settings_dir, "ZenOS"), legacy_plugin, current_plugin, {
                force = true,
                g_settings = g_settings,
                lfs = lfs,
                lua_settings = fake_lua_settings,
        }))

        assert.is_false(saved)
    end)

    it("does not report disabled-state migration success when its flush fails", function()
        local current_plugin = mkdir(path(plugins_dir, "zenos.koplugin"))
        mkdir(path(settings_dir, "ZenOS"))
        local g_settings = ZenSpec.memorySettings({
            plugins_disabled = { zen_ui = true },
        })
        g_settings.flush = function() return false end

        local result = BrandMigration.detectStartup(
            nil, migration_options(current_plugin, g_settings))

        assert.are.equal("migration_save_failed", result.status)
        assert.is_true(result.inert)
        assert.is_nil(result.restart)
        assert.is_false(result.disabled_state_saved)
        assert.is_true(result.persisted_paths_saved)
        assert.is_nil(lfs.symlinkattributes(
            path(settings_dir, "Zen UI"), "mode"))
    end)

    it("removes settings symlinks without traversing their targets", function()
        if type(lfs.link) ~= "function" then return pending("lfs.link unavailable") end
        local current_settings = mkdir(path(settings_dir, "ZenOS"))
        local outside = mkdir(path(test_root, "outside"))
        local outside_file = path(outside, "keep.txt")
        write_file(outside_file, "keep")
        assert.is_true(lfs.link(outside, path(current_settings, "linked"), true))

        assert.is_true(BrandMigration.removeSettings({
            settings_dir = settings_dir,
            lfs = lfs,
        }))

        assert.are.equal("file", lfs.attributes(outside_file, "mode"))
        assert.is_nil(lfs.attributes(current_settings, "mode"))
    end)

    it("shares complete settings cleanup with inert plugin instances", function()
        local legacy_settings = mkdir(path(settings_dir, "Zen UI"))
        local current_settings = mkdir(path(settings_dir, "ZenOS"))
        write_file(path(legacy_settings, "legacy.txt"), "legacy")
        write_file(path(current_settings, "current.txt"), "current")
        local data_dir = mkdir(path(test_root, "data"))
        local patches_dir = mkdir(path(data_dir, "patches"))
        write_file(path(patches_dir, "2-zen-ui-suppress-startup-alerts.lua"), "remove")
        write_file(path(patches_dir, "7-zenos-extra.lua"), "remove")
        write_file(path(patches_dir, "8-unrelated.lua"), "keep")
        local stored_settings = {
            zen_ui_config = { enabled = true },
            zen_ui_folder_sort = { ["/books"] = "title" },
            zen_ui_folder_display_mode = { ["/books"] = "mosaic_image" },
            zen_ui_just_updated = "3.0.0",
            zen_ui_last_update_check = 42,
            zen_ui_update_available = true,
            zen_ui_latest_version = "3.1.0",
            zen_ui_update_dl_url = "https://example.invalid/update.zip",
            zen_ui_update_sha256 = "sha256",
            zen_ui_update_channel = "beta",
            zen_ui_update_auto_check = true,
            zen_tags_global_collate = "title",
            zen_tags_global_reverse = true,
            zen_tags_global_custom = "legacy",
            zen_authors_reverse = true,
            zen_series_reverse = true,
            zen_authors_display_mode = "list_image_meta",
            zen_tags_detail_collate_fiction = "title",
            zen_series_detail_reverse_fiction = true,
            zen_page_browser_layout = "grid",
            uniform_cover_ratio = "3:4",
            opds_default_url = "https://catalog.example",
            substring_search = true,
            folder_gallery_mode = "mosaic_image",
            unrelated = true,
        }
        local flushes = 0
        local g_settings = {
            data = stored_settings,
            readSetting = function(_self, key) return stored_settings[key] end,
            delSetting = function(_self, key) stored_settings[key] = nil end,
            flush = function()
                flushes = flushes + 1
                return true
            end,
        }

        assert.is_true(BrandMigration.deletePluginSettings({
            settings_dir = settings_dir,
            data_dir = data_dir,
            g_settings = g_settings,
            lfs = lfs,
        }))

        assert.is_nil(entry_mode(legacy_settings))
        assert.is_nil(entry_mode(current_settings))
        assert.is_nil(g_settings:readSetting("zen_ui_config"))
        assert.is_nil(g_settings:readSetting("zen_ui_folder_sort"))
        assert.is_nil(g_settings:readSetting("zen_ui_folder_display_mode"))
        for _i, key in ipairs({
            "zen_ui_just_updated",
            "zen_ui_last_update_check",
            "zen_ui_update_available",
            "zen_ui_latest_version",
            "zen_ui_update_dl_url",
            "zen_ui_update_sha256",
            "zen_ui_update_channel",
            "zen_ui_update_auto_check",
            "zen_tags_global_collate",
            "zen_tags_global_reverse",
            "zen_tags_global_custom",
            "zen_authors_reverse",
            "zen_series_reverse",
            "zen_authors_display_mode",
            "zen_tags_detail_collate_fiction",
            "zen_series_detail_reverse_fiction",
            "zen_page_browser_layout",
            "uniform_cover_ratio",
            "opds_default_url",
        }) do
            assert.is_nil(g_settings:readSetting(key), key)
        end
        assert.is_true(g_settings:readSetting("substring_search"))
        assert.are.equal("mosaic_image",
            g_settings:readSetting("folder_gallery_mode"))
        assert.is_true(g_settings:readSetting("unrelated"))
        assert.are.equal(1, flushes)
        assert.is_nil(entry_mode(path(patches_dir,
            "2-zen-ui-suppress-startup-alerts.lua")))
        assert.is_nil(entry_mode(path(patches_dir, "7-zenos-extra.lua")))
        assert.are.equal("file", entry_mode(path(patches_dir, "8-unrelated.lua")))
    end)
end)
