describe("ZenOS module initialization", function()
    local function noop() end

    -- main.lua over stubbed modules; anything not listed loads as an empty table.
    local function load_main(modules, env)
        local chunk = assert(loadfile(ZenSpec.root .. "/main.lua"))
        env = env or {}
        env._G = { __zen_ui_uimgr_guard = true }
        env.require = function(name)
            if name == "missing-provider" then error("provider module missing") end
            if name == "common/plugin_root" then return ZenSpec.root end
            if name == "fontlist" then return false end
            return modules[name] or {}
        end
        setfenv(chunk, setmetatable(env, { __index = _G }))
        return chunk()
    end

    it("continues after module load and initialization failures", function()
        local calls, warnings = {}, {}
        local battery_changes, rescans = 0, 0
        local icons_initialized, update_icon_resolved = false, false
        local registry = {
            { id = "missing", file = "missing-provider" },
            { id = "broken", file = "broken-provider" },
            { id = "disabled", file = "disabled-provider" },
            { id = "reader", file = "reader-module" },
        }
        local modules = {
            ["common/battery_stats"] = { bluetoothChanged = function() battery_changes = battery_changes + 1 end },
            ["common/hid_keys"] = { rescanSoon = function() rescans = rescans + 1 end },
            ["common/brand_migration"] = { detectStartup = function() return {} end },
            ["modules/filebrowser/patches/incompatible_plugins_check"] = function() return false end,
            ["common/zen_logger"] = { new = function() return {
                info = noop, perf = noop, warn = function(...) warnings[#warnings + 1] = { ... } end,
            } end },
            ["common/i18n"] = { install = noop },
            ["common/status_bar_registry"] = { install = noop },
            ["ui/widget/container/widgetcontainer"] = { extend = function(_self, spec) return spec end },
            ["config/manager"] = { load = function() return {} end },
            ["modules/registry"] = registry,
            ["modules/filebrowser/patches/home/components/registry"] = {
                install = function() assert.is_true(icons_initialized) end,
            },
            ["common/icon_packs"] = { initialize = function() icons_initialized = true end },
            ["common/ui/glyph_icons"] = { install = noop },
            ["common/utils"] = {
                overrideIcons = noop,
                resolveIcon = function(dir, name)
                    assert.is_true(icons_initialized)
                    assert.equals(ZenSpec.root .. "/icons/", dir)
                    assert.equals("zen_ui_update", name)
                    update_icon_resolved = true
                    return "/icons/zen/selected/zen_ui_update.svg"
                end,
            },
            ["common/dispatch_action"] = { install = noop },
            ["broken-provider"] = { init = function() error("third-party startup failed") end },
            ["disabled-provider"] = { init = function() return false end },
            ["reader-module"] = { init = function(_logger, plugin)
                calls[#calls + 1] = plugin
                return true
            end },
        }
        local plugin = load_main(modules)
        plugin:onBluetoothStateChanged()
        assert.equals(1, battery_changes)
        assert.equals(1, rescans)
        plugin._zenos_brand_inert = true
        plugin:onBluetoothStateChanged()
        assert.equals(1, battery_changes)
        assert.equals(1, rescans)
        plugin._zenos_brand_inert = nil
        assert.is_true(update_icon_resolved)
        plugin.config = {}
        plugin:_initModules()

        assert.same({ plugin }, calls)
        assert.equals(3, #warnings)
        assert.equals("broken", warnings[2][2])
        assert.matches("third-party startup failed", warnings[2][3], 1, true)
    end)

    it("undoes the Kindle HID system changes with the plugin settings, after its files are gone", function()
        local purged, torn_down, deleted = false, 0, 0
        local function loaded(module)
            return setmetatable(module, { __index = function() return noop end })
        end
        local stubs = setmetatable({
            ["common/brand_migration"] = {
                detectStartup = function() return {} end,
                deletePluginSettings = function() deleted = deleted + 1 end,
            },
            ["ui/widget/container/widgetcontainer"] = { extend = function(_self, spec) return spec end },
            ["config/manager"] = { load = function() return {} end },
            ["modules/menu/bluetooth_adapters/kindle_hid"] = {
                teardown = function() torn_down = torn_down + 1; return true end,
            },
        }, { __index = function(_stubs, name)
            assert.is_false(purged, "required after the plugin was deleted: " .. name)
            return loaded({ new = function() return loaded({}) end })
        end })
        local plugin = load_main(stubs, { G_reader_settings = { readSetting = noop } })
        -- KOReader deletes the plugin before the hook: a late require would find nothing.
        for name in pairs(stubs) do stubs[name] = nil end
        purged = true
        assert.is_true(plugin:deletePluginSettings())
        assert.same({ 1, 1 }, { torn_down, deleted })
    end)
end)
