describe("reader bottom swipe", function()
    local BottomSwipe = require("common/reader_bottom_swipe")

    it("preserves legacy settings and lets an explicit choice override them", function()
        for _i, case in ipairs({
            { {}, "none" },
            { { reader_bottom_menu = true }, "koreader" },
            { { page_browser = true }, "page_browser" },
            { { page_browser = true, reader_bottom_menu = true }, "page_browser" },
        }) do
            local config = { features = case[1] }
            assert.are.equal(case[2], BottomSwipe.getMode(config))
            for _j, mode in ipairs({ "koreader", "page_browser", "none", "custom" }) do
                config.reader_bottom_swipe = { mode = mode,
                    entries = { { type = "action", action = { show_menu = true } } } }
                assert.are.equal(mode, BottomSwipe.getMode(config))
                assert.are.equal(mode ~= "none", BottomSwipe.isEnabled(config))
                config.features.lockdown_mode = true
                config.lockdown = { disable_bottom_menu_swipe = true }
                assert.is_false(BottomSwipe.isEnabled(config))
                config.features.lockdown_mode = false
            end
        end
    end)

    it("opens reader controls when selected", function()
        local config = { features = {}, reader_bottom_swipe = { mode = "reader_controls" } }
        assert.are.equal("reader_controls", BottomSwipe.getMode(config))
        assert.is_true(BottomSwipe.isEnabled(config))
    end)

    it("requires a usable target before treating Custom as selected", function()
        local config = { features = { reader_bottom_menu = true }, reader_bottom_swipe = { mode = "custom" } }
        assert.are.equal("none", BottomSwipe.getMode(config))
        local cfg = config.reader_bottom_swipe
        cfg.entries = {}
        assert.is_false(BottomSwipe.hasTarget(config))
        for _i, entry in ipairs({
            {}, { type = "action" }, { type = "action", action = {} },
            { type = "action", action = { settings = { name = "Empty" } } },
            { type = "quick_setting", quick_setting_id = "" },
            { type = "plugin", plugin = { key = "test" } },
            { type = "koreader_menu", koreader_menu = {} },
            { type = "action", action = { show_menu = true }, enabled = false },
        }) do
            cfg.entries[1] = entry
            assert.is_false(BottomSwipe.hasTarget(config))
            assert.are.equal("none", BottomSwipe.getMode(config))
            assert.is_false(BottomSwipe.isEnabled(config))
        end
        for _i, entry in ipairs({
            { type = "action", action = { show_menu = true } },
            { type = "quick_setting", quick_setting_id = "wifi" },
            { type = "plugin", plugin = { key = "test", method = "open" } },
            { type = "koreader_menu", koreader_menu = { id = "status_bar" } },
        }) do
            cfg.entries[1] = entry
            assert.is_true(BottomSwipe.hasTarget(config))
            assert.are.equal("custom", BottomSwipe.getMode(config))
            assert.is_true(BottomSwipe.isEnabled(config))
        end
    end)

    it("runs launcher actions, plugins, menus, and controls without an open touch menu", function()
        local executed, scope, closed = {}, nil, 0
        local original_controls = rawget(_G, "__ZEN_UI_QUICK_SETTINGS")
        finally(function() _G.__ZEN_UI_QUICK_SETTINGS = original_controls end)
        ZenSpec.replace("ui/uimanager", {
            nextTick = function(_self, callback) callback() end,
            show = function() error("unexpected unavailable action") end,
        })
        ZenSpec.replace("common/settings_transition", { close = function() closed = closed + 1 end })
        ZenSpec.replace("dispatcher", { execute = function(_self, action) executed.action = action end })
        ZenSpec.replace("modules/menu/app_launcher/plugin_scan", {
            resolve = function(key, method)
                return function() executed.plugin = { key, method } end
            end,
        })
        ZenSpec.replace("modules/menu/app_launcher/native_menu", {
            resolve = function(id, context)
                scope = context
                return function() executed.menu = id end
            end,
        })
        _G.__ZEN_UI_QUICK_SETTINGS = { activate = function(id, menu)
            assert.is_nil(menu)
            executed.control = id
            return true
        end }
        ZenSpec.unload("modules/menu/app_launcher/entry_action")
        local activate = require("modules/menu/app_launcher/entry_action")
        local action = { show_menu = true }
        assert.is_true(activate({ type = "action", action = action }, nil, {}, "reader"))
        assert.is_true(activate({ type = "plugin", plugin = { key = "test", method = "open" } }, nil, {}, "reader"))
        assert.is_true(activate({ type = "koreader_menu", koreader_menu = { id = "status_bar" } }, nil, {}, "reader"))
        assert.is_true(activate({ type = "quick_setting", quick_setting_id = "wifi" }, nil, {}, "reader"))
        assert.are.equal(action, executed.action)
        assert.are.same({ "test", "open" }, executed.plugin)
        assert.are.equal("status_bar", executed.menu)
        assert.are.equal("reader", scope)
        assert.are.equal("wifi", executed.control)
        assert.are.equal(3, closed)
        assert.is_false(activate({ enabled = false }, nil, {}, "reader"))
    end)
end)
