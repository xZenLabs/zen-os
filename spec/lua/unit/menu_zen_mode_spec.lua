describe("Zen mode menu patch", function()
    local FileManagerMenu
    local ReaderMenu
    local ReaderConfig
    local plugin
    local refresh_menus
    local active_menu
    local saved_modules
    local saved_plugin

    local dependencies = {
        "apps/filemanager/filemanagermenu",
        "apps/reader/modules/readermenu",
        "apps/reader/modules/readerconfig",
        "common/shared_state",
        "modules/menu/patches/zen_mode",
    }

    local function menu_class()
        return {
            setUpdateItemTable = function(self)
                self.tab_item_table = {
                    { id = "quicksettings" },
                    { id = "settings" },
                    { id = "search" },
                    { id = "reader" },
                    { id = "history" },
                    { id = "filemanager", icon = "appbar.filebrowser" },
                    { id = "zen_ui", icon = "_zen_settings_tab" },
                    { id = "zen_library_home", icon = "library" },
                }
            end,
            onShowMenu = function(self)
                self.shows = (self.shows or 0) + 1
            end,
        }
    end

    local function tab_ids(menu)
        local ids = {}
        for _i, tab in ipairs(menu.tab_item_table) do ids[#ids + 1] = tab.id end
        return ids
    end

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(dependencies) do saved_modules[name] = package.loaded[name] end
        saved_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        FileManagerMenu = menu_class()
        ReaderMenu = menu_class()
        ReaderConfig = {
            onShowConfigMenu = function(self)
                self.shows = (self.shows or 0) + 1
                return true
            end,
        }
        active_menu = setmetatable({}, { __index = FileManagerMenu })
        active_menu:setUpdateItemTable()
        plugin = {
            config = { features = { zen_mode = false } },
            ui = { menu = active_menu },
        }
        refresh_menus = nil

        ZenSpec.replace("apps/filemanager/filemanagermenu", FileManagerMenu)
        ZenSpec.replace("apps/reader/modules/readermenu", ReaderMenu)
        ZenSpec.replace("apps/reader/modules/readerconfig", ReaderConfig)
        ZenSpec.replace("common/shared_state", {
            register = function(_plugin, entries)
                refresh_menus = entries.refreshZenModeMenus
            end,
        })
        _G.__ZEN_UI_PLUGIN = plugin
        ZenSpec.unload("modules/menu/patches/zen_mode")
        require("modules/menu/patches/zen_mode")()
    end)

    after_each(function()
        _G.__ZEN_UI_PLUGIN = saved_plugin
        for _i, name in ipairs(dependencies) do
            package.loaded[name] = saved_modules[name]
        end
    end)

    it("removes and restores tabs live without rebuilding menu definitions", function()
        local menu = setmetatable({}, { __index = FileManagerMenu })
        menu:onShowMenu()
        assert.are.same({
            "quicksettings", "settings", "search", "reader", "history", "filemanager",
            "zen_ui", "zen_library_home",
        }, tab_ids(menu))

        plugin.config.features.zen_mode = true
        refresh_menus()
        assert.are.same({ "quicksettings", "history", "zen_ui", "zen_library_home" }, tab_ids(menu))

        plugin.config.features.zen_mode = false
        refresh_menus()
        assert.are.same({
            "quicksettings", "settings", "search", "reader", "history", "zen_ui", "zen_library_home",
        }, tab_ids(menu))
    end)

    it("filters the first tab table as soon as it is built", function()
        plugin.config.features.zen_mode = true
        local menu = setmetatable({}, { __index = FileManagerMenu })

        menu:setUpdateItemTable()

        assert.are.same({ "quicksettings", "history", "zen_ui", "zen_library_home" }, tab_ids(menu))
    end)

    it("refreshes a menu that was built before the patch loaded", function()
        plugin.config.features.zen_mode = true

        refresh_menus()

        assert.are.same({ "quicksettings", "history", "zen_ui", "zen_library_home" },
            tab_ids(active_menu))
    end)

    it("gates the reader config menu from the live setting", function()
        local config = setmetatable({}, { __index = ReaderConfig })

        assert.is_true(config:onShowConfigMenu())
        assert.are.equal(1, config.shows)

        plugin.config.features.zen_mode = true
        assert.is_nil(config:onShowConfigMenu())
        assert.are.equal(1, config.shows)

        plugin.config.features.reader_bottom_menu = true
        assert.is_true(config:onShowConfigMenu())
        assert.are.equal(2, config.shows)
    end)

    it("allows an explicit reader-controls request without enabling the bottom swipe", function()
        plugin.config.features.zen_mode = true
        plugin.config.features.reader_bottom_menu = false
        local config = setmetatable({}, { __index = ReaderConfig })
        assert.is_nil(config:onShowConfigMenu())
        assert.is_true(config:onShowConfigMenu(true))
        assert.are.equal(1, config.shows)
        assert.is_false(plugin.config.features.reader_bottom_menu)
        assert.is_nil(config:onShowConfigMenu())
    end)
end)
