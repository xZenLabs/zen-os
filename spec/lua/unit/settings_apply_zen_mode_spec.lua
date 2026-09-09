describe("Zen mode settings apply", function()
    local saved_runtime_patches
    local saved_modules
    local saved_reader_settings

    local dependencies = {
        "gettext",
        "ui/event",
        "ui/uimanager",
        "ui/widget/confirmbox",
        "common/restart",
        "common/shared_state",
        "common/tbr_index",
        "ui/widget/touchmenu",
        "apps/reader/readerui",
        "modules/reader/patches/reader_top_status_bar",
        "modules/menu/patches/zen_mode",
        "modules/settings/zen_settings_apply",
    }

    before_each(function()
        saved_runtime_patches = rawget(_G, "__ZEN_UI_RUNTIME_PATCHES")
        saved_reader_settings = rawget(_G, "G_reader_settings")
        saved_modules = {}
        for _i, name in ipairs(dependencies) do saved_modules[name] = package.loaded[name] end
        _G.__ZEN_UI_RUNTIME_PATCHES = nil
        _G.G_reader_settings = ZenSpec.memorySettings({
            alt_status_bar = true,
            copt_status_line = 0,
        })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/event", {
            new = function(_, name, value)
                return { handler = "on" .. name, args = { value } }
            end,
        })
        ZenSpec.replace("ui/uimanager", {
            setDirty = function() end,
            forceRePaint = function() end,
            nextTick = function(_self, callback) callback() end,
        })
        ZenSpec.replace("ui/widget/confirmbox", {
            new = function(_self, values) return values end,
        })
        ZenSpec.replace("common/restart", {})
        ZenSpec.replace("ui/widget/touchmenu", {})
        ZenSpec.replace("apps/reader/readerui", { instance = nil })
        ZenSpec.unload("modules/settings/zen_settings_apply")
    end)

    after_each(function()
        _G.__ZEN_UI_RUNTIME_PATCHES = saved_runtime_patches
        _G.G_reader_settings = saved_reader_settings
        for _i, name in ipairs(dependencies) do package.loaded[name] = saved_modules[name] end
    end)

    it("loads and refreshes Zen mode without prompting for restart", function()
        local applies = 0
        local refreshes = 0
        local restart_prompts = 0
        local plugin = { config = { features = { zen_mode = true } } }
        ZenSpec.replace("common/shared_state", {
            register = function() end,
            get = function(_plugin, key)
                if key == "refreshZenModeMenus" then
                    return function() refreshes = refreshes + 1 end
                end
            end,
        })
        ZenSpec.replace("modules/menu/patches/zen_mode", function()
            applies = applies + 1
        end)
        package.loaded["ui/uimanager"].show = function()
            restart_prompts = restart_prompts + 1
        end

        require("modules/settings/zen_settings_apply").apply_feature_toggle(plugin, "zen_mode", true)

        assert.are.equal(1, applies)
        assert.are.equal(1, refreshes)
        assert.are.equal(0, restart_prompts)
    end)

    it("disables KOReader's alt status bar when enabling the Zen reader bar", function()
        local applied = 0
        local handled_event
        local margin_applies = 0
        local reader = {
            document = { configurable = { status_line = 0 } },
            rolling = {},
            typeset = {
                unscaled_margins = { 1, 2, 3, 4 },
                onSetPageMargins = function() margin_applies = margin_applies + 1 end,
            },
            handleEvent = function(_self, event) handled_event = event end,
        }
        package.loaded["apps/reader/readerui"].instance = reader
        ZenSpec.replace("modules/reader/patches/reader_top_status_bar", function()
            applied = applied + 1
        end)

        require("modules/settings/zen_settings_apply").apply_feature_toggle(
            { config = { features = { reader_top_status_bar = true } } },
            "reader_top_status_bar",
            true
        )

        assert.are.equal(1, applied)
        assert.are.equal(1, G_reader_settings:readSetting("copt_status_line"))
        assert.is_false(G_reader_settings:readSetting("alt_status_bar"))
        assert.are.equal(1, reader.document.configurable.status_line)
        assert.are.equal("onSetStatusLine", handled_event.handler)
        assert.are.equal(1, handled_event.args[1])
        assert.are.equal(1, margin_applies)
    end)

    it("defers navbar reinjection until the Zen settings page closes", function()
        local home_invalidations = 0
        local reinjections = 0
        local queued = {}
        local UIManager = require("ui/uimanager")
        UIManager.nextTick = function(_self, callback)
            queued[#queued + 1] = callback
        end
        _G.__ZEN_UI_SETTINGS_PAGE = {}
        _G.__ZEN_UI_REINJECT_NAVBARS = function()
            reinjections = reinjections + 1
        end
        ZenSpec.replace("common/shared_state", {
            get = function(_plugin, key)
                if key == "home" then
                    return {
                        invalidateNavbar = function()
                            home_invalidations = home_invalidations + 1
                        end,
                    }
                end
            end,
        })

        local settings_apply = require("modules/settings/zen_settings_apply")
        settings_apply.set_plugin({})
        settings_apply.refresh_navbar_on_menu_close()

        assert.are.equal(0, reinjections)
        assert.are.equal(0, home_invalidations)
        _G.__ZEN_UI_SETTINGS_PAGE = nil
        settings_apply.flush_deferred_on_settings_close()
        assert.are.equal(1, #queued)

        queued[1]()
        assert.are.equal(1, reinjections)
        assert.are.equal(1, home_invalidations)
        _G.__ZEN_UI_REINJECT_NAVBARS = nil
    end)

    it("repaints TBR surfaces only after settings closes", function()
        local repaints = 0
        local queued = {}
        local UIManager = require("ui/uimanager")
        UIManager.nextTick = function(_self, callback)
            queued[#queued + 1] = callback
        end
        UIManager.forceRePaint = function()
            repaints = repaints + 1
        end
        _G.__ZEN_UI_SETTINGS_PAGE = {}

        local settings_apply = require("modules/settings/zen_settings_apply")
        settings_apply.refresh_tbr_on_menu_close()

        assert.are.equal(0, repaints)
        require("ui/widget/touchmenu"):onCloseWidget()
        assert.are.equal(0, #queued)
        _G.__ZEN_UI_SETTINGS_PAGE = nil
        settings_apply.flush_deferred_on_settings_close()
        assert.are.equal(1, #queued)

        queued[1]()
        assert.are.equal(1, repaints)
    end)
end)
