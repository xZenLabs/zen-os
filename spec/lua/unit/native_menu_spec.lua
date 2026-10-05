describe("native KOReader menu shortcuts", function()
    local reader_menu
    local filemanager_menu
    local shown

    before_each(function()
        shown = nil
        reader_menu = {
            tab_item_table = {
                {
                    id = "typeset",
                    {
                        id = "style_tweaks",
                        text_func = function() return "Style tweaks (2)" end,
                        sub_item_table = {{ text = "Pages", callback = function() end }},
                    },
                    { id = "reader_leaf", text = "Leaf", callback = function() end },
                },
                {
                    id = "tools",
                    { id = "plugin_orphan", text = "Plugin menu", sub_item_table = {{}} },
                },
                { id = "zen_ui", sub_item_table = {{}} },
            },
        }
        filemanager_menu = {
            tab_item_table = {
                {
                    id = "setting",
                    {
                        id = "network",
                        text = "Network",
                        sub_item_table_func = function()
                            return {{ text = "Wi-Fi", callback = function() end }}
                        end,
                    },
                },
                { id = "tools", { id = "plugin_management", text = "Plugins", sub_item_table = {{}} } },
            },
        }

        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/elements/reader_menu_order", {
            ["KOMenu:menu_buttons"] = { "typeset", "tools" },
            typeset = { "style_tweaks", "reader_leaf" },
            tools = { "plugin_management" },
        })
        ZenSpec.replace("ui/elements/filemanager_menu_order", {
            ["KOMenu:menu_buttons"] = { "setting", "tools" },
            setting = { "network" },
            network = { "network_wifi" },
            tools = { "plugin_management" },
        })
        ZenSpec.replace("apps/reader/readerui", { instance = { menu = reader_menu } })
        ZenSpec.replace("apps/filemanager/filemanager", { instance = { menu = filemanager_menu } })
        ZenSpec.replace("modules/menu/app_launcher/menu_host", {
            show = function(opts) shown = opts end,
        })
        ZenSpec.unload("modules/menu/app_launcher/native_menu")
    end)

    it("lists stable submenu containers as a visual hierarchy", function()
        local found = require("modules/menu/app_launcher/native_menu").scan("reader")

        assert.are.same({
            { id = "typeset", title = "Typesetting", text = "Typesetting", bold = true, indent_level = 0 },
            { id = "style_tweaks", title = "Style tweaks (2)", text = "Style tweaks (2)", bold = false, indent_level = 1 },
            { id = "tools", title = "Tools", text = "Tools", bold = true, indent_level = 0 },
        }, found)
    end)

    it("filters a reader catalog to file-manager-safe IDs when no file manager is live", function()
        package.loaded["apps/filemanager/filemanager"].instance = nil
        table.insert(reader_menu.tab_item_table, 2, {
            id = "setting",
            { id = "network", text = "Network", sub_item_table = {{ text = "Wi-Fi" }} },
        })

        local found = require("modules/menu/app_launcher/native_menu").scan("filemanager")

        assert.are.same({
            { id = "setting", title = "Settings", text = "Settings", bold = true, indent_level = 0 },
            { id = "network", title = "Network", text = "Network", bold = false, indent_level = 1 },
            { id = "tools", title = "Tools", text = "Tools", bold = true, indent_level = 0 },
        }, found)
    end)

    it("discovers native tabs hidden by Zen Mode", function()
        local native_tabs = filemanager_menu.tab_item_table
        filemanager_menu.tab_item_table = { { id = "zen_ui", sub_item_table = {{}} } }
        filemanager_menu._zen_mode_removed_tabs = {
            { tab = native_tabs[1] },
            { tab = native_tabs[2] },
        }

        local NativeMenu = require("modules/menu/app_launcher/native_menu")
        local found = NativeMenu.scan("filemanager")

        assert.are.same({
            { id = "setting", title = "Settings", text = "Settings", bold = true, indent_level = 0 },
            { id = "network", title = "Network", text = "Network", bold = false, indent_level = 1 },
            { id = "tools", title = "Tools", text = "Tools", bold = true, indent_level = 0 },
            { id = "plugin_management", title = "Plugins", text = "Plugins", bold = false, indent_level = 1 },
        }, found)
        assert.is_true(NativeMenu.exists("network", "filemanager"))
    end)

    it("resolves fresh dynamic submenu contents through the shared menu host", function()
        local NativeMenu = require("modules/menu/app_launcher/native_menu")
        local launch = NativeMenu.resolve("network", "filemanager")

        assert.is_function(launch)
        assert.is_true(launch())
        assert.are.equal("Network", shown.title)
        assert.are.equal("Wi-Fi", shown.item_table[1].text)
    end)

    it("adapts shared IDs and rejects targets missing from the requested context", function()
        local NativeMenu = require("modules/menu/app_launcher/native_menu")

        assert.is_true(NativeMenu.exists("tools", "reader"))
        assert.is_true(NativeMenu.exists("tools", "filemanager"))
        assert.is_true(NativeMenu.exists("style_tweaks", "reader"))
        assert.is_false(NativeMenu.exists("style_tweaks", "filemanager"))
        assert.is_nil(NativeMenu.resolve("plugin_orphan", "reader"))
    end)

    it("exposes native roots and plugin descendants while excluding injected tabs", function()
        local original = package.loaded["modules/settings/koreader_settings"]
        ZenSpec.replace("modules/settings/koreader_settings", {
            install = function() end,
            copyItems = function(items) return items end,
        })
        local NativeMenu = require("modules/menu/app_launcher/native_menu")
        local roots = NativeMenu.settingsItems("active")
        assert.are.equal("typeset", roots[1].id)
        assert.are.equal("tools", roots[2].id)
        assert.are.equal(2, #roots)
        assert.are.equal("plugin_orphan", roots[2].sub_item_table_func()[1].id)
        assert.is_true(NativeMenu.isSettingsOwner(reader_menu))
        reader_menu.tab_item_table[#reader_menu.tab_item_table + 1] = {
            id = "plugin_tab", text = "Plugin tab", { text = "Plugin option" },
        }
        roots = NativeMenu.settingsItems("active")
        assert.are.equal("Plugin tab", roots[3].text)
        assert.are.equal("Plugin option", roots[3].sub_item_table_func()[1].text)
        package.loaded["apps/reader/readerui"].instance = nil
        roots = NativeMenu.settingsItems("active")
        assert.are.equal("setting", roots[1].id)
        assert.is_true(NativeMenu.isSettingsOwner(filemanager_menu))
        assert.is_false(NativeMenu.isSettingsOwner(reader_menu))
        package.loaded["modules/settings/koreader_settings"] = original
    end)

    it("initializes a missing menu once and restores hidden tabs in their original position", function()
        local original = package.loaded["modules/settings/koreader_settings"]
        ZenSpec.replace("modules/settings/koreader_settings", { install = function() end })
        package.loaded["apps/reader/readerui"].instance = nil
        local initialized = 0
        filemanager_menu.tab_item_table = nil
        function filemanager_menu:setUpdateItemTable()
            initialized = initialized + 1
            local tools = { id = "tools" }
            self.tab_item_table = { tools }
            self._zen_mode_removed_tabs = { { tab = { id = "setting" }, before = tools } }
        end
        local NativeMenu = require("modules/menu/app_launcher/native_menu")
        assert.are.equal("setting", NativeMenu.settingsItems()[1].id)
        assert.are.equal("tools", NativeMenu.settingsItems()[2].id)
        assert.are.equal(1, initialized)
        assert.are.equal(1, #filemanager_menu.tab_item_table)
        package.loaded["modules/settings/koreader_settings"] = original
    end)

    it("copies a selected native setting in reader and library contexts", function()
        local original = package.loaded["modules/settings/koreader_settings"]
        finally(function() package.loaded["modules/settings/koreader_settings"] = original end)
        local copied, owner, setting
        ZenSpec.replace("modules/settings/koreader_settings", {
            install = function() end,
            copyItems = function(items, menu, is_setting)
                copied, owner, setting = items, menu, is_setting
                return items
            end,
        })
        local NativeMenu = require("modules/menu/app_launcher/native_menu")
        assert.equals(reader_menu.tab_item_table[1][1], NativeMenu.settingsItems("active", "style_tweaks")[1])
        assert.equals(reader_menu, owner)
        assert.is_true(setting)
        package.loaded["apps/reader/readerui"].instance = nil
        assert.equals(filemanager_menu.tab_item_table[1][1], NativeMenu.settingsItems("active", "network")[1])
        assert.equals(filemanager_menu, owner)
        assert.is_true(setting)
        assert.same({}, NativeMenu.settingsItems("active", "missing"))
        assert.same({}, copied)
    end)
end)
