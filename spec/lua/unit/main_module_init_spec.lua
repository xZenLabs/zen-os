describe("ZenOS module initialization", function()
    it("continues after module load and initialization failures", function()
        local calls, warnings = {}, {}
        local icons_initialized, update_icon_resolved = false, false
        local registry = {
            { id = "missing", file = "missing-provider" },
            { id = "broken", file = "broken-provider" },
            { id = "disabled", file = "disabled-provider" },
            { id = "reader", file = "reader-module" },
        }
        local function noop() end
        local modules = {
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
        local chunk = assert(loadfile(ZenSpec.root .. "/main.lua"))
        setfenv(chunk, setmetatable({
            _G = { __zen_ui_uimgr_guard = true },
            require = function(name)
                if name == "missing-provider" then error("provider module missing") end
                if name == "common/plugin_root" then return ZenSpec.root end
                if name == "fontlist" then return false end
                return modules[name] or {}
            end,
        }, { __index = _G }))
        local plugin = chunk()
        assert.is_true(update_icon_resolved)
        plugin.config = {}
        plugin:_initModules()

        assert.same({ plugin }, calls)
        assert.equals(3, #warnings)
        assert.equals("broken", warnings[2][2])
        assert.matches("third-party startup failed", warnings[2][3], 1, true)
    end)
end)
