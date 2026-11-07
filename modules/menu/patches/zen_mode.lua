local function apply_zen_mode()
    local FileManagerMenu = require("apps/filemanager/filemanagermenu")

    if FileManagerMenu._zen_mode_patched then return end

    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")

    local function is_enabled()
        local features = zen_plugin and zen_plugin.config and zen_plugin.config.features
        return type(features) == "table" and features.zen_mode == true
    end

    -- Zen mode keeps only Zen's own tabs; KOReader and plugin tabs (e.g. Ink Away) are hidden.
    local keep_ids = {
        quicksettings = true,
        zen_ui = true,
        zen_library_home = true,
        app_launcher = true,
    }

    local function should_keep_tab(tab)
        return not is_enabled() or type(tab) ~= "table" or keep_ids[tab.id] == true
    end

    local menu_instances = setmetatable({}, { __mode = "k" })

    local function tab_index(tab_item_table, target)
        for index, tab in ipairs(tab_item_table) do
            if tab == target then return index end
        end
    end

    local function hide_blocked_tabs(self)
        local tab_item_table = self.tab_item_table
        if type(tab_item_table) ~= "table" then return end

        local removed = self._zen_mode_removed_tabs
        if type(removed) ~= "table" then
            removed = {}
            self._zen_mode_removed_tabs = removed
        end
        local known = {}
        for _i, entry in ipairs(removed) do known[entry.tab] = true end

        local snapshot = {}
        for _i, tab in ipairs(tab_item_table) do snapshot[#snapshot + 1] = tab end
        for index, tab in ipairs(snapshot) do
            -- Zen's library tab permanently replaces KOReader's file-manager tab.
            if not should_keep_tab(tab) and not known[tab] and tab.id ~= "filemanager" then
                local before
                for next_index = index + 1, #snapshot do
                    if should_keep_tab(snapshot[next_index]) then
                        before = snapshot[next_index]
                        break
                    end
                end
                removed[#removed + 1] = { tab = tab, before = before }
                known[tab] = true
            end
        end

        for index = #tab_item_table, 1, -1 do
            if not should_keep_tab(tab_item_table[index]) then
                table.remove(tab_item_table, index)
            end
        end
    end

    local function restore_blocked_tabs(self)
        local tab_item_table = self.tab_item_table
        local removed = self._zen_mode_removed_tabs
        if type(tab_item_table) ~= "table" or type(removed) ~= "table" then return end

        for _i, entry in ipairs(removed) do
            if not tab_index(tab_item_table, entry.tab) then
                local before_index = entry.before and tab_index(tab_item_table, entry.before)
                if before_index then
                    table.insert(tab_item_table, before_index, entry.tab)
                else
                    table.insert(tab_item_table, entry.tab)
                end
            end
        end
        self._zen_mode_removed_tabs = nil
    end

    local function sync_menu(self)
        if not self then return end
        menu_instances[self] = true
        if is_enabled() then
            hide_blocked_tabs(self)
        else
            restore_blocked_tabs(self)
        end
    end

    local function refresh_menus()
        for menu in pairs(menu_instances) do sync_menu(menu) end
    end

    -- Ensure menu_items has the required top-level key before the original
    -- setUpdateItemTable runs, otherwise MenuSorter:sort crashes at
    -- ipairs(menu_table["KOMenu:menu_buttons"]) when it is nil.
    local function ensure_menu_items(self)
        if type(self.menu_items) ~= "table" then
            self.menu_items = {}
        end
        if not self.menu_items["KOMenu:menu_buttons"] then
            self.menu_items["KOMenu:menu_buttons"] = {}
        end
    end

    local orig_fm_setUpdateItemTable = FileManagerMenu.setUpdateItemTable
    FileManagerMenu.setUpdateItemTable = function(self)
        ensure_menu_items(self)
        orig_fm_setUpdateItemTable(self)
        self._zen_mode_removed_tabs = nil
        sync_menu(self)
    end

    local orig_fm_onShowMenu = FileManagerMenu.onShowMenu
    FileManagerMenu.onShowMenu = function(self, ...)
        if self.tab_item_table == nil then self:setUpdateItemTable() end
        sync_menu(self)
        return orig_fm_onShowMenu(self, ...)
    end

    -- ReaderMenu/ReaderConfig patches wait for ReaderUI.
    require("common/on_require").whenLoaded("apps/reader/readerui", function()
        local ReaderMenu = require("apps/reader/modules/readermenu")
        if ReaderMenu._zen_mode_patched then return end
        ReaderMenu._zen_mode_patched = true

        local orig_reader_setUpdateItemTable = ReaderMenu.setUpdateItemTable
        ReaderMenu.setUpdateItemTable = function(self)
            ensure_menu_items(self)
            orig_reader_setUpdateItemTable(self)
            self._zen_mode_removed_tabs = nil
            sync_menu(self)
        end

        local orig_reader_onShowMenu = ReaderMenu.onShowMenu
        ReaderMenu.onShowMenu = function(self, ...)
            if self.tab_item_table == nil then self:setUpdateItemTable() end
            sync_menu(self)
            return orig_reader_onShowMenu(self, ...)
        end

        local ReaderConfig = require("apps/reader/modules/readerconfig")
        local orig_onShowConfigMenu = ReaderConfig.onShowConfigMenu
        ReaderConfig.onShowConfigMenu = function(self, force)
            if force ~= true and is_enabled() then
                local features = zen_plugin and zen_plugin.config and zen_plugin.config.features
                if not (type(features) == "table" and features.reader_bottom_menu == true) then
                    return
                end
            end
            return orig_onShowConfigMenu(self)
        end
    end)

    FileManagerMenu._zen_mode_patched = true
    require("common/shared_state").register(zen_plugin, {
        refreshZenModeMenus = refresh_menus,
    })

    local active_menu = zen_plugin and zen_plugin.ui and zen_plugin.ui.menu
    if active_menu then sync_menu(active_menu) end
end

return apply_zen_mode
