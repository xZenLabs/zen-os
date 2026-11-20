describe("connection alerts", function()
    local originals, plugin_global, shown, UIManager, Alerts, developer
    local names = { "gettext", "ui/uimanager", "modules/global/patches/connection_alerts" }

    before_each(function()
        originals = {}
        for _i, name in ipairs(names) do originals[name] = package.loaded[name] end
        plugin_global = rawget(_G, "__ZEN_UI_PLUGIN")
        shown, developer = {}, {}
        UIManager = { show = function(_self, widget, mode) shown[#shown + 1] = { widget.text, mode } end }
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/uimanager", UIManager)
        ZenSpec.unload("modules/global/patches/connection_alerts")
        Alerts = require("modules/global/patches/connection_alerts")
        _G.__ZEN_UI_PLUGIN = { config = { developer = developer } }
        Alerts.apply()
        _G.__ZEN_UI_PLUGIN = nil
    end)

    after_each(function()
        for _i, name in ipairs(names) do package.loaded[name] = originals[name] end
        _G.__ZEN_UI_PLUGIN = plugin_global
    end)

    it("shows every notice until the setting is on, and follows it live", function()
        assert.is_false(Alerts.hidden())
        UIManager:show({ text = "Keyboard connected" }, "ui")
        assert.same({ { "Keyboard connected", "ui" } }, shown)

        developer.hide_connection_alerts = true
        assert.is_true(Alerts.hidden())
        UIManager:show({ text = "Keyboard connected" })
        assert.are.equal(1, #shown)
    end)

    it("hides KOReader's routine notices and nothing else", function()
        developer.hide_connection_alerts = true
        for _i, text in ipairs({
            "Keyboard connected", "Keyboard disconnected",
            "Turning on Wi-Fi…", "Turning off Wi-Fi…", "Wi-Fi off.",
        }) do
            UIManager:show({ text = text })
        end
        assert.are.equal(0, #shown)

        UIManager:show({ text = "Error connecting to the network" })
        UIManager:show({ text = "Error opening keyboard:\nEBUSY" })
        UIManager:show({})
        assert.are.equal(3, #shown)
    end)

    it("wraps UIManager once across repeated applies", function()
        local wrapped = UIManager.show
        Alerts.apply()
        assert.are.equal(wrapped, UIManager.show)
    end)
end)
