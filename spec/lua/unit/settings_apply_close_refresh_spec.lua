describe("settings apply close refresh", function()
    local saved_modules, saved_globals
    local dependencies = {
        "gettext", "ui/uimanager", "ui/widget/confirmbox", "common/restart",
        "common/shared_state", "ui/widget/touchmenu", "apps/filemanager/filemanager",
        "modules/settings/zen_settings_apply",
    }
    local globals = {
        "G_reader_settings", "__ZEN_UI_SETTINGS_PAGE", "__ZEN_UI_REINJECT_NAVBARS",
        "__ZEN_UI_REINJECT_FM_NAVBAR", "__ZEN_UI_RUNTIME_PATCHES",
    }
    local events, ticks

    before_each(function()
        saved_modules, saved_globals = {}, {}
        for _i, name in ipairs(dependencies) do saved_modules[name] = package.loaded[name] end
        for _i, name in ipairs(globals) do saved_globals[name] = rawget(_G, name) end
        events, ticks = {}, {}
        _G.G_reader_settings = ZenSpec.memorySettings({})
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/uimanager", {
            setDirty = function(_self, widget, mode)
                events[#events + 1] = "dirty:" .. tostring(widget and widget.id or widget) .. ":" .. mode
            end,
            forceRePaint = function() events[#events + 1] = "repaint" end,
            nextTick = function(_self, callback) ticks[#ticks + 1] = callback end,
            scheduleIn = function(_self, _delay, callback) ticks[#ticks + 1] = callback end,
        })
        ZenSpec.replace("ui/widget/confirmbox", { new = function(_self, values) return values end })
        ZenSpec.replace("common/restart", {})
        ZenSpec.replace("common/shared_state", { get = function() end })
        ZenSpec.replace("ui/widget/touchmenu", {})
        ZenSpec.replace("apps/filemanager/filemanager", {
            instance = { id = "fm", reinit = function() events[#events + 1] = "reinit" end },
        })
        _G.__ZEN_UI_REINJECT_NAVBARS = function(skip_fm)
            events[#events + 1] = "navbars:" .. tostring(skip_fm)
        end
        _G.__ZEN_UI_REINJECT_FM_NAVBAR = function() events[#events + 1] = "fm_navbar" end
        ZenSpec.unload("modules/settings/zen_settings_apply")
    end)

    after_each(function()
        for _i, name in ipairs(dependencies) do package.loaded[name] = saved_modules[name] end
        for _i, name in ipairs(globals) do _G[name] = saved_globals[name] end
    end)

    it("issues one full refresh when a reinit and navbar refresh flush together", function()
        local apply = require("modules/settings/zen_settings_apply")
        _G.__ZEN_UI_SETTINGS_PAGE = {}
        apply.reinit_filemanager()
        apply.refresh_navbar_on_menu_close()
        assert.is_true(apply.pending_full_refresh())
        _G.__ZEN_UI_SETTINGS_PAGE = nil
        apply.flush_deferred_on_settings_close()
        while #ticks > 0 do table.remove(ticks, 1)() end
        assert.are.same({ "reinit", "dirty:fm:full", "navbars:true" }, events)
        assert.is_false(apply.pending_full_refresh())
    end)

    it("keeps the FM navbar reinjection when no reinit is pending", function()
        local apply = require("modules/settings/zen_settings_apply")
        _G.__ZEN_UI_SETTINGS_PAGE = {}
        apply.refresh_navbar_on_menu_close()
        assert.is_false(apply.pending_full_refresh())
        _G.__ZEN_UI_SETTINGS_PAGE = nil
        apply.flush_deferred_on_settings_close()
        while #ticks > 0 do table.remove(ticks, 1)() end
        assert.are.same({ "navbars:nil" }, events)
    end)
end)
