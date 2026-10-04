describe("partial page repaint", function()
    local original_modules
    local original_plugin, plugin
    local module_names = {
        "common/ui/background",
        "covermenu",
        "modules/filebrowser/patches/partial_page_repaint",
        "ui/uimanager",
        "ui/widget/filechooser",
    }

    before_each(function()
        original_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        plugin = { config = { features = { partial_page_repaint = true } } }
        _G.__ZEN_UI_PLUGIN = plugin
        original_modules = {}
        for _i, name in ipairs(module_names) do
            original_modules[name] = package.loaded[name]
        end
    end)

    after_each(function()
        _G.__ZEN_UI_PLUGIN = original_plugin
        for _i, name in ipairs(module_names) do
            package.loaded[name] = original_modules[name]
        end
    end)

    it("toggles both repaint hooks live and cancels queued flashes when disabled", function()
        local scheduled = {}
        local repaint_calls = 0
        local FileChooser = { updateItems = function() end }
        local CoverMenu = { updateItems = function() end }
        ZenSpec.replace("ui/widget/filechooser", FileChooser)
        ZenSpec.replace("covermenu", CoverMenu)
        ZenSpec.replace("ui/uimanager", {
            nextTick = function(_self, callback) scheduled[#scheduled + 1] = callback end,
            setDirty = function() end,
            forceRePaint = function() repaint_calls = repaint_calls + 1 end,
        })
        plugin.config.features.partial_page_repaint = false
        ZenSpec.unload("modules/filebrowser/patches/partial_page_repaint")
        require("modules/filebrowser/patches/partial_page_repaint")()
        local chooser = { item_table = { 1, 2, 3 }, page = 2, perpage = 2 }

        for _i, menu in ipairs({ FileChooser, CoverMenu }) do
            local scheduled_before = #scheduled
            menu.updateItems(chooser)
            assert.are.equal(scheduled_before, #scheduled)

            plugin.config.features.partial_page_repaint = true
            menu.updateItems(chooser)
            assert.are.equal(scheduled_before + 1, #scheduled)
            plugin.config.features.partial_page_repaint = false
            scheduled[#scheduled]()
            assert.are.equal(_i - 1, repaint_calls)

            plugin.config.features.partial_page_repaint = true
            menu.updateItems(chooser)
            assert.are.equal(scheduled_before + 2, #scheduled)
            scheduled[#scheduled]()
            assert.are.equal(_i, repaint_calls)

            plugin.config.features.partial_page_repaint = false
            menu.updateItems(chooser)
            assert.are.equal(scheduled_before + 2, #scheduled)
        end
    end)

    it("skips a short-page flash after navigation supersedes it", function()
        local scheduled = {}
        local dirty_calls = 0
        local FileChooser = { updateItems = function() end }
        ZenSpec.replace("ui/widget/filechooser", FileChooser)
        ZenSpec.replace("covermenu", {})
        ZenSpec.replace("ui/uimanager", {
            nextTick = function(_self, callback) scheduled[#scheduled + 1] = callback end,
            setDirty = function() dirty_calls = dirty_calls + 1 end,
            forceRePaint = function() error("superseded page repainted") end,
        })
        ZenSpec.unload("modules/filebrowser/patches/partial_page_repaint")
        require("modules/filebrowser/patches/partial_page_repaint")()
        local chooser = {
            item_table = { 1, 2, 3 }, page = 2, perpage = 2,
            _zen_cover_hydration_generation = 1,
        }

        FileChooser.updateItems(chooser)
        chooser.page = 1
        FileChooser.updateItems(chooser)
        scheduled[1]()
        assert.are.equal(0, dirty_calls)

        chooser.page = 2
        FileChooser.updateItems(chooser)
        chooser._zen_cover_hydration_generation = 2
        scheduled[2]()
        assert.are.equal(0, dirty_calls)
    end)

    it("repaints only short pages when a library background is active", function()
        local scheduled = {}
        local dirty_calls = 0
        local repaint_calls = 0
        local FileChooser = { updateItems = function() end }
        ZenSpec.replace("ui/widget/filechooser", FileChooser)
        ZenSpec.replace("covermenu", {})
        ZenSpec.replace("common/ui/background", {
            library_active = function() return true end,
        })
        ZenSpec.replace("ui/uimanager", {
            nextTick = function(_self, callback) scheduled[#scheduled + 1] = callback end,
            setDirty = function(_self, widget, mode)
                assert.is_nil(widget)
                assert.are.equal("full", mode)
                dirty_calls = dirty_calls + 1
            end,
            forceRePaint = function() repaint_calls = repaint_calls + 1 end,
        })
        ZenSpec.unload("modules/filebrowser/patches/partial_page_repaint")
        require("modules/filebrowser/patches/partial_page_repaint")()

        local chooser = {
            item_table = { 1, 2, 3, 4 },
            page = 2,
            perpage = 2,
        }
        setmetatable(chooser, { __index = FileChooser })
        chooser:updateItems()
        assert.are.equal(0, #scheduled)

        chooser.item_table = { 1, 2, 3 }
        chooser:updateItems()
        assert.are.equal(1, #scheduled)
        scheduled[1]()
        assert.are.equal(1, dirty_calls)
        assert.are.equal(1, repaint_calls)
    end)
end)
