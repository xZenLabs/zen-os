local icons = require("common/inline_icon_map")
local function apply_history()
    local FileManagerHistory = require("apps/filemanager/filemanagerhistory")
    local Menu = require("ui/widget/menu")
    local Background = require("common/ui/background")
    local SharedState = require("common/shared_state")
    local SettingsTransition = require("common/settings_transition")
    local _ = require("gettext")

    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    if not zen_plugin or type(zen_plugin.config) ~= "table" then
        return
    end

    local function is_enabled()
        local features = zen_plugin.config and zen_plugin.config.features
        return type(features) == "table" and features.history == true
    end

    local function get_shared(key)
        return SharedState.get(zen_plugin, key)
    end

    -- Returns true when status_bar is enabled AND hide_browser_bar is true
    -- (matching what status_bar.lua does when creating the filebrowser titlebar).
    -- In that mode the filebrowser has a minimal-height TitleBar, and we must
    -- give history the exact same height so covers line up.
    local function should_match_statusbar_height()
        local features = zen_plugin.config and zen_plugin.config.features
        if type(features) ~= "table" or features.status_bar ~= true then
            return false
        end
        local sb_cfg = type(zen_plugin.config.status_bar) == "table"
            and zen_plugin.config.status_bar or {}
        -- Default for hide_browser_bar is true (matches status_bar config_default)
        local hide = sb_cfg.hide_browser_bar
        return hide == true or hide == nil
    end

    local function get_hist_display_mode()
        local gv = type(zen_plugin.config.group_view) == "table" and zen_plugin.config.group_view or {}
        local dm = type(gv.display_mode) == "table" and gv.display_mode or {}
        return dm.history
    end

    local function set_hist_display_mode(mode)
        if type(zen_plugin.config.group_view) ~= "table" then zen_plugin.config.group_view = {} end
        local gv = zen_plugin.config.group_view
        if type(gv.display_mode) ~= "table" then gv.display_mode = {} end
        gv.display_mode.history = mode
        if type(zen_plugin.saveConfig) == "function" then zen_plugin:saveConfig() end
    end

    -- Hook Menu:init() so the history BookList TitleBar is created with the
    -- same minimal height as the filebrowser TitleBar (status_bar + hide_browser_bar
    -- case).  This makes others_height equal in both views so the first cover
    -- row appears at the same Y position — covers "line up" when switching tabs.
    local orig_menu_init = Menu.init
    function Menu:init()
        if self.name == "history" and is_enabled() and should_match_statusbar_height() then
            local TitleBar   = require("ui/widget/titlebar")
            local orig_tb_new = TitleBar.new
            TitleBar.new = function(cls, t)
                if type(t) == "table" then
                    t.subtitle                = nil
                    t.subtitle_fullwidth      = nil
                    t.left_icon               = nil
                    t.left_icon_tap_callback  = nil
                    t.left_icon_hold_callback = nil
                    t.right_icon              = nil
                    t.right_icon_tap_callback  = nil
                    t.right_icon_hold_callback = nil
                    t.close_callback          = nil
                    t.title_tap_callback      = nil
                    t.title_hold_callback     = nil
                    t.bottom_v_padding        = 0
                    t.title                   = " "
                end
                return orig_tb_new(cls, t)
            end
            orig_menu_init(self)
            TitleBar.new = orig_tb_new
        else
            orig_menu_init(self)
        end
    end

    local function show_hist_blank_menu(hist_mgr, hist_menu)
        local ft = zen_plugin and zen_plugin.config and zen_plugin.config.features
        local lc = zen_plugin and zen_plugin.config and zen_plugin.config.lockdown
        if type(ft) == "table" and ft.lockdown_mode == true
                and type(lc) == "table" and lc.disable_context_menu == true then
            return
        end
        local ButtonDialog_hm = require("ui/widget/buttondialog")
        local UIManager_hm    = require("ui/uimanager")
        local cur_mode = get_hist_display_mode()
        local function apply_mode(mode)
            set_hist_display_mode(mode)
            -- Sync to BIM via KOReader's CoverBrowser API so the history view re-opens correctly
            local cb = hist_mgr.ui and hist_mgr.ui.coverbrowser
            if cb and type(cb.setupWidgetDisplayMode) == "function" then
                pcall(cb.setupWidgetDisplayMode, "history", mode)
            end
            if hist_menu then UIManager_hm:close(hist_menu) end
            UIManager_hm:nextTick(function()
                hist_mgr:onShowHist()
            end)
        end
        local view_dialog
        local function viewBtn(label, icon, mode)
            local active = cur_mode == mode
            return {{
                text     = icon .. "  " .. label .. (active and "  " .. icons.check or ""),
                align    = "left",
                enabled  = not active,
                callback = function()
                    UIManager_hm:close(view_dialog)
                    apply_mode(mode)
                end,
            }}
        end
        view_dialog = ButtonDialog_hm:new{
            title       = _("Display mode"),
            title_align = "center",
            buttons     = {
                viewBtn(_("Mosaic"),          icons.view_mosaic, "mosaic_image"),
                viewBtn(_("List (detailed)"), icons.view_list, "list_image_meta"),
                viewBtn(_("List (basic)"),    icons.view_basic, "list_image_filename"),
            },
        }
        UIManager_hm:show(view_dialog)
        return true
    end

    SharedState.register(zen_plugin, {
        history = {
            showContextMenu = function()
                local FileManager = require("apps/filemanager/filemanager")
                local hist_mgr = FileManager.instance and FileManager.instance.history
                if not hist_mgr then return false end
                return show_hist_blank_menu(hist_mgr, hist_mgr.booklist_menu) == true
            end,
        },
    })

    local function clean_nav(menu, hist_mgr, search_info)
        if not menu then return end
        Background.applyToMenu(menu)
        if hist_mgr then
            menu._zen_library_bg_reopen = function()
                hist_mgr:onShowHist(search_info)
                return hist_mgr.booklist_menu ~= nil
            end
        end

        -- === Fix partial-row left-alignment ===
        menu._do_center_partial_rows = false
        menu:updateItems(1, true)

        -- Blank-space hold: open history display mode menu
        if hist_mgr then
            local Device_h = require("device")
            if Device_h:isTouchDevice() then
                local GestureRange_h = require("ui/gesturerange")
                local Geom_h         = require("ui/geometry")
                if not menu.ges_events then menu.ges_events = {} end
                menu.ges_events.ZenHistBlankHold = {
                    GestureRange_h:new{
                        ges   = "hold",
                        range = Geom_h:new{
                            x = 0, y = 0,
                            w = Device_h.screen:getWidth(),
                            h = Device_h.screen:getHeight(),
                        },
                    },
                }
                menu.onZenHistBlankHold = function()
                    return show_hist_blank_menu(hist_mgr, menu)
                end
            end
        end

        -- === Permanently suppress the back-arrow button ===
        local arrow = menu.page_return_arrow
        if arrow then
            local Geom = require("ui/geometry")
            arrow:hide()
            arrow.show     = function() end
            arrow.showHide = function() end
            arrow.dimen    = Geom:new{ w = 0, h = 0 }
        end

        local tb = menu.title_bar
        if not tb then return end

        -- === Title-bar content ===
        local createStatusRow = get_shared("createStatusRow")

        if createStatusRow and tb.title_group and #tb.title_group >= 2 then
            local FileManager = require("apps/filemanager/filemanager")

            tb.title_group[2] = createStatusRow(nil, FileManager.instance, _("History"))
            tb.title_group:resetLayout()

            local function remove_from_overlap(group, widget)
                if not widget then return end
                for i = #group, 1, -1 do
                    if rawequal(group[i], widget) then
                        table.remove(group, i)
                        return
                    end
                end
            end
            remove_from_overlap(tb, tb.left_button)
            remove_from_overlap(tb, tb.right_button)
            tb.has_left_icon  = false
            tb.has_right_icon = false

            -- Periodic and event-driven refresh (charging, wifi, clock tick, etc.)
            local repaintTitleBar = get_shared("repaintTitleBar")
            menu._zen_status_refresh = function()
                if tb.title_group and #tb.title_group >= 2 then
                    tb.title_group[2] = createStatusRow(nil, FileManager.instance, _("History"))
                    tb.title_group:resetLayout()
                    if repaintTitleBar then repaintTitleBar(tb) end
                end
            end

            -- Initial paint
            if repaintTitleBar then repaintTitleBar(tb) end
        else
            -- Fallback when status_bar is not active: swap hamburger → history icon.
            if tb.setLeftIcon then tb:setLeftIcon("history") end
        end
    end

    -- Prevent centering on *subsequent* updateItemTable calls (refreshes, page
    -- turns).
    local orig_updateItemTable = FileManagerHistory.updateItemTable
    function FileManagerHistory:updateItemTable(...)
        if is_enabled() and self.booklist_menu then
            self.booklist_menu._do_center_partial_rows = false
        end
        return orig_updateItemTable(self, ...)
    end

    local orig_onShowHist = FileManagerHistory.onShowHist
    function FileManagerHistory:onShowHist(search_info)
        SettingsTransition.close()
        if is_enabled() then
            -- Sync display mode from zen_ui_config to BIM before CoverBrowser reads it
            local mode = get_hist_display_mode()
            if mode then
                local cb = self.ui and self.ui.coverbrowser
                if cb and type(cb.setupWidgetDisplayMode) == "function" then
                    pcall(cb.setupWidgetDisplayMode, "history", mode)
                end
            end
        end
        orig_onShowHist(self, search_info)
        if not is_enabled() then return end
        clean_nav(self.booklist_menu, self, search_info)
    end

    -- Replace the default hold dialog with the zen context menu.
    -- onMenuHold is called with `self` = booklist_menu, `self._manager` = FileManagerHistory.
    local orig_onMenuHold = FileManagerHistory.onMenuHold
    function FileManagerHistory:onMenuHold(item)
        if not is_enabled() then
            return orig_onMenuHold(self, item)
        end
        local fm = require("apps/filemanager/filemanager").instance
        if fm and fm.file_chooser and fm.file_chooser.showFileDialog then
            local hist_mgr = self._manager
            local function do_remove()
                local fc = fm.file_chooser
                if fc.file_dialog then
                    require("ui/uimanager"):close(fc.file_dialog)
                    fc.file_dialog = nil
                end
                -- index only valid with no active filter/search
                local index = item.idx
                if hist_mgr and (hist_mgr.search_string
                        or hist_mgr.selected_collections
                        or hist_mgr.filter ~= "all") then
                    index = nil
                end
                require("readhistory"):removeItem(item, index)
                if hist_mgr then hist_mgr:updateItemTable() end
            end
            fm.file_chooser:showFileDialog({
                path     = item.file,
                is_file  = true,
                is_go_up = false,
                text     = item.text,
                _zen_disable_select = true,
                _zen_extra_buttons = {
                    {{
                        text     = icons.delete .. "  " .. _("Remove from history"),
                        align    = "left",
                        callback = do_remove,
                    }},
                },
            })
            return true
        end
        return orig_onMenuHold(self, item)
    end

end

return apply_history
