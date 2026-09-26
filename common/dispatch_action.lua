local _ = require("gettext")

local M = {}
local _plugin
local zen_action_active

local function feature_enabled(key, plugin)
    local active_plugin = plugin or _plugin
    local features = active_plugin and active_plugin.config and active_plugin.config.features
    return type(features) == "table" and features[key] == true
end

local function save_config(plugin)
    if plugin and type(plugin.saveConfig) == "function" then
        plugin:saveConfig()
    end
end

local function get_reader()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    return ok and ReaderUI and ReaderUI.instance or nil
end

local function refresh_reader()
    local reader = get_reader()
    if reader then
        require("ui/uimanager"):setDirty(reader, "ui")
    end
end

local function refresh_incognito_indicators()
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    local file_manager = ok_fm and FileManager and FileManager.instance
    local UIManager = require("ui/uimanager")
    local refreshed = false
    local stack = UIManager._window_stack
    for i = type(stack) == "table" and #stack or 0, 1, -1 do
        local widget = stack[i] and stack[i].widget
        if widget and type(widget._zen_status_refresh) == "function" then
            pcall(widget._zen_status_refresh, widget)
            refreshed = true
            break
        elseif widget and type(widget._zen_home_refresh_clock_widgets) == "function" then
            pcall(widget._zen_home_refresh_clock_widgets, widget)
            refreshed = true
            break
        elseif widget == file_manager and type(file_manager._updateStatusBar) == "function" then
            pcall(file_manager._updateStatusBar, file_manager)
            refreshed = true
            break
        end
    end
    if not refreshed and file_manager and type(file_manager._updateStatusBar) == "function" then
        pcall(file_manager._updateStatusBar, file_manager)
    end
    refresh_reader()
end

local function open_navbar_tab(tab_id)
    local open = rawget(_G, "__ZEN_UI_NAVBAR_OPEN_TAB")
    if type(open) ~= "function" then return false end
    return open(tab_id) ~= false
end

local group_view_show = {
    authors = "showAuthorsView",
    series = "showSeriesView",
    tags = "showTagsView",
}

local function tab_fallback(plugin, tab_id)
    local ok_shared, SharedState = pcall(require, "common/shared_state")
    if not ok_shared then return false end
    if tab_id == "home" then
        local home = SharedState.get(plugin, "home")
        if home and type(home.showHomeView) == "function" then
            home.showHomeView()
            return true
        end
        return false
    end
    local fn_name = group_view_show[tab_id]
    if not fn_name then return false end
    local gv = SharedState.get(plugin, "group_view")
    if not (gv and type(gv[fn_name]) == "function") then return false end
    gv[fn_name](nil)
    return true
end

local function show_tab_from_filemanager(plugin, tab_id)
    if tab_id == "home" then
        local ok_shared, SharedState = pcall(require, "common/shared_state")
        local home = ok_shared and SharedState.get(plugin, "home") or nil
        if home and type(home.isActiveOnTop) == "function" and home.isActiveOnTop() then
            return true
        end
    end
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    local fm = ok_fm and FileManager and FileManager.instance
    if fm then
        require("common/utils").closeWidgetsAbove(fm)
    end
    if open_navbar_tab(tab_id) then return true end
    return tab_fallback(plugin, tab_id)
end

local function show_zen_tab(plugin, tab_id, opts)
    opts = opts or {}
    if not opts.open_home then opts.target_tab = tab_id end
    local reader = get_reader()
    if reader and reader.document then
        return require("common/library_navigation").showFromReader(reader, plugin, opts)
    end
    return show_tab_from_filemanager(plugin, tab_id)
end

local function show_library_from_filemanager()
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    local fm = ok_fm and FileManager and FileManager.instance
    if fm then require("common/utils").closeWidgetsAbove(fm) end

    local open_default = rawget(_G, "__ZEN_UI_NAVBAR_OPEN_DEFAULT_TAB")
    if type(open_default) == "function" then
        open_default()
        return true
    end

    local home_dir = require("common/paths").getHomeDir()
    if fm and fm.file_chooser and home_dir then
        fm.file_chooser.path_items[home_dir] = nil
        fm.file_chooser:changeToPath(home_dir)
        return true
    end
    return false
end

local function show_library(plugin)
    local reader = get_reader()
    if reader and reader.document then
        return require("common/library_navigation").showFromReader(reader, plugin)
    end
    return show_library_from_filemanager()
end

local function show_folder_from_filemanager(folder)
    if type(folder) ~= "string" or folder == "" then return false end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(folder, "mode") ~= "directory" then
        require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
            text = _("ZenOS: folder not found: ") .. folder,
        })
        return false
    end
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    local fm = ok_fm and FileManager and FileManager.instance
    if not fm or not fm.file_chooser then return false end
    local open_folder = rawget(_G, "__ZEN_UI_NAVBAR_OPEN_FOLDER")
    if type(open_folder) == "function" then return open_folder(folder) == true end
    require("common/utils").closeWidgetsAbove(fm)
    local paths = require("common/paths")
    local direct_archive = paths.isArchiveRoot(folder)
    fm.file_chooser._zen_direct_archive_root = direct_archive and paths.getArchiveDir() or nil
    fm.file_chooser._zen_opening_archive_root = direct_archive or nil
    fm.file_chooser:changeToPath(folder)
    return true
end

local function show_zen_folder(plugin, folder)
    if type(folder) ~= "string" or folder == "" then
        require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
            text = _("ZenOS: no folder set for this action."),
        })
        return false
    end
    local reader = get_reader()
    if reader and reader.document then
        return require("common/library_navigation").showFromReader(reader, plugin, { target_folder = folder })
    end
    return show_folder_from_filemanager(folder)
end

local function show_tag_from_filemanager(plugin, tag)
    if type(tag) ~= "string" or tag == "" then return false end
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    local fm = ok_fm and FileManager and FileManager.instance
    if fm then require("common/utils").closeWidgetsAbove(fm) end
    local open_tag = rawget(_G, "__ZEN_UI_NAVBAR_OPEN_TAG")
    if type(open_tag) == "function" then return open_tag(tag) == true end
    local ok_shared, SharedState = pcall(require, "common/shared_state")
    local GroupView = ok_shared and SharedState.get(plugin, "group_view") or nil
    if GroupView and type(GroupView.showTagDetail) == "function" then
        GroupView.showTagDetail(tag)
        return true
    end
    return false
end

local function show_zen_tag(plugin, tag)
    if type(tag) ~= "string" or tag == "" then return false end
    local reader = get_reader()
    if reader and reader.document then
        return require("common/library_navigation").showFromReader(
            reader, plugin, { target_tag = tag })
    end
    return show_tag_from_filemanager(plugin, tag)
end

local function apply_top_status_bar(plugin, enabled)
    local apply = require("modules/settings/zen_settings_apply")
    apply.apply_feature_toggle(plugin, "reader_top_status_bar", enabled)
end

local function is_top_status_bar_enabled(plugin)
    local features = plugin and plugin.config and plugin.config.features
    return type(features) == "table" and features.reader_top_status_bar == true
end

local function set_top_status_bar(plugin, enabled)
    local features = plugin and plugin.config and plugin.config.features
    if type(features) ~= "table" then return false end
    if features.reader_top_status_bar == enabled then
        refresh_reader()
        return true
    end
    features.reader_top_status_bar = enabled
    save_config(plugin)
    apply_top_status_bar(plugin, enabled)
    return true
end

local function get_footer()
    local reader = get_reader()
    return reader and reader.view and reader.view.footer or nil
end

local function is_bottom_status_bar_visible(plugin)
    local footer = get_footer()
    local live_visible = footer and footer.view and footer.view.footer_visible
    if type(live_visible) == "boolean" then return live_visible end
    local active_plugin = plugin or _plugin
    local plugin_config = active_plugin and active_plugin.config
    if type(plugin_config) ~= "table" then return false end
    local reader_footer = plugin_config.reader_footer
    return type(reader_footer) ~= "table" or reader_footer.status_bar_enabled ~= false
end

local function fallback_footer_mode(footer)
    if not footer or type(footer.mode_list) ~= "table" then return 1 end
    return footer.mode_list.page_progress or 1
end

local function set_bottom_status_bar(plugin, enabled)
    local footer = get_footer()
    if not footer then return false end

    local plugin_config = plugin and plugin.config or nil
    local reader_footer
    if plugin_config then
        if type(plugin_config.reader_footer) ~= "table" then
            plugin_config.reader_footer = {}
        end
        reader_footer = plugin_config.reader_footer
        reader_footer.status_bar_enabled = enabled
    end
    local mode_list = footer.mode_list or {}
    local off_mode = mode_list.off or 0
    if enabled then
        local last_mode = reader_footer and reader_footer.last_status_bar_mode
        if type(last_mode) ~= "number" or last_mode == off_mode then
            last_mode = G_reader_settings:readSetting("reader_footer_mode")
        end
        if type(last_mode) ~= "number" or last_mode == off_mode then
            last_mode = fallback_footer_mode(footer)
        end
        footer:applyFooterMode(last_mode)
        G_reader_settings:saveSetting("reader_footer_mode", last_mode)
    else
        if reader_footer and type(footer.mode) == "number" and footer.mode ~= off_mode then
            reader_footer.last_status_bar_mode = footer.mode
        end
        footer:applyFooterMode(off_mode)
        G_reader_settings:saveSetting("reader_footer_mode", off_mode)
    end
    if reader_footer then save_config(plugin) end

    footer:refreshFooter(true, true)
    if type(footer.rescheduleFooterAutoRefreshIfNeeded) == "function" then
        footer:rescheduleFooterAutoRefreshIfNeeded()
    end
    return true
end

zen_action_active = {
    zen_ui_toggle_zen_mode = function(plugin)
        return feature_enabled("zen_mode", plugin)
    end,
    zen_ui_toggle_lockdown_mode = function(plugin)
        return feature_enabled("lockdown_mode", plugin)
    end,
    zen_ui_toggle_incognito_mode = function(plugin)
        return feature_enabled("incognito_mode", plugin)
    end,
    zen_ui_toggle_reader_top_status_bar = function(plugin)
        return is_top_status_bar_enabled(plugin or _plugin)
    end,
    zen_ui_toggle_reader_themes = function(plugin)
        return feature_enabled("reader_themes", plugin or _plugin)
    end,
    zen_ui_toggle_reader_bottom_status_bar = function(plugin)
        return is_bottom_status_bar_visible(plugin or _plugin)
    end,
    zen_ui_toggle_reader_status_bars = function(plugin)
        local active_plugin = plugin or _plugin
        return is_top_status_bar_enabled(active_plugin)
            or is_bottom_status_bar_visible(active_plugin)
    end,
}

-- Combines KOReader's built-in pull-then-push progress sync (previously the
-- "Sync" quick settings button) into a single bindable action.
local function sync_reading_progress()
    local NetworkMgr = require("ui/network/manager")
    local UIManager = require("ui/uimanager")
    local Event = require("ui/event")
    NetworkMgr:runWhenOnline(function()
        UIManager:broadcastEvent(Event:new("KOSyncPullProgress"))
        -- Push after a short delay to let the pull complete first.
        UIManager:scheduleIn(1, function()
            UIManager:broadcastEvent(Event:new("KOSyncPushProgress"))
        end)
    end)
    return true
end

local function show_zen_toc(plugin)
    local reader = get_reader()
    if not (reader and reader.document and reader.toc) then return false end
    if type(reader.toc.toc) ~= "table" or #reader.toc.toc == 0 then
        require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
            text = _("No table of contents available."),
        })
        return true
    end

    local ZenTocWidget = require("modules/reader/zen_toc_widget")
    ZenTocWidget.set_plugin(plugin)

    local focus_page = 1
    if type(reader.getCurrentPage) == "function" then
        local ok, page = pcall(reader.getCurrentPage, reader)
        if ok and type(page) == "number" then
            focus_page = page
        end
    end

    require("ui/uimanager"):show(ZenTocWidget:new{
        ui = reader,
        focus_page = focus_page,
        on_goto = function(page)
            if reader.link then
                reader.link:addCurrentLocationToStack()
            end
            reader:handleEvent(require("ui/event"):new("GotoPage", page))
        end,
    })
    return true
end

local _folder_picker_patched = false

-- Render a per-action folder picker for zen_ui_show_folder. The default Dispatcher
-- menu only builds fixed radio lists for category="string", so we wrap _addItem to
-- append a PathChooser-backed entry to the General section. The chosen path is stored
-- in location[settings].zen_ui_show_folder, i.e. per gesture/profile instance.
local function patch_folder_picker_menu(Dispatcher)
    if _folder_picker_patched then return end
    _folder_picker_patched = true
    local util = require("util")
    local UIManager = require("ui/uimanager")
    local ACTION = "zen_ui_show_folder"

    local orig_addItem = Dispatcher._addItem
    Dispatcher._addItem = function(self, caller, menu, location, settings, section)
        orig_addItem(self, caller, menu, location, settings, section)
        if section ~= "general" then return end

        local function stored_folder()
            return location[settings] ~= nil and location[settings][ACTION] or nil
        end

        table.insert(menu, {
            text_func = function()
                local folder = stored_folder()
                if type(folder) == "string" and folder ~= "" then
                    local name = select(2, util.splitFilePathName(folder))
                    return _("ZenOS: Open folder") .. ": " .. name
                end
                return _("ZenOS: Open folder")
            end,
            checked_func = function()
                return stored_folder() ~= nil
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local PathChooser = require("ui/widget/pathchooser")
                local folder = stored_folder()
                local start_path = (type(folder) == "string" and folder ~= "") and folder
                    or G_reader_settings:readSetting("lastdir") or "/"
                UIManager:show(PathChooser:new{
                    select_file = false,
                    show_files = false,
                    path = start_path,
                    onConfirm = function(dir_path)
                        if location[settings] == nil then location[settings] = {} end
                        location[settings][ACTION] = dir_path
                        Dispatcher._addToOrder(location, settings, ACTION)
                        caller.updated = true
                        if touchmenu_instance then touchmenu_instance:updateItems() end
                    end,
                })
            end,
            hold_callback = function(touchmenu_instance)
                if location[settings] ~= nil and location[settings][ACTION] ~= nil then
                    location[settings][ACTION] = nil
                    Dispatcher._removeFromOrder(location, settings, ACTION)
                    caller.updated = true
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end
            end,
        })
    end
end

function M.onDispatcherRegisterActions()
    local Dispatcher = require("dispatcher")
    Dispatcher:registerAction("zen_ui_toggle_zen_mode", {
        category = "none",
        event = "ToggleZenMode",
        title = _("ZenOS: Toggle Zen Mode"),
        general = true,
        active_func = zen_action_active.zen_ui_toggle_zen_mode,
    })
    Dispatcher:registerAction("zen_ui_toggle_lockdown_mode", {
        category = "none",
        event = "ToggleLockdownMode",
        title = _("ZenOS: Toggle Lockdown Mode"),
        general = true,
        active_func = zen_action_active.zen_ui_toggle_lockdown_mode,
    })
    Dispatcher:registerAction("zen_ui_toggle_incognito_mode", {
        category = "none",
        event = "ToggleIncognitoMode",
        title = _("ZenOS: Toggle Incognito Mode"),
        general = true,
        active_func = zen_action_active.zen_ui_toggle_incognito_mode,
    })
    Dispatcher:registerAction("zen_ui_toggle_reader_top_status_bar", {
        category = "none",
        event = "ToggleReaderTopStatusBar",
        title = _("ZenOS: Toggle top reader status bar"),
        reader = true,
        active_func = zen_action_active.zen_ui_toggle_reader_top_status_bar,
    })
    Dispatcher:registerAction("zen_ui_toggle_reader_themes", {
        category = "none",
        event = "ToggleReaderThemes",
        title = _("ZenOS: Toggle reader themes"),
        reader = true,
        active_func = zen_action_active.zen_ui_toggle_reader_themes,
    })
    Dispatcher:registerAction("zen_ui_toggle_reader_bottom_status_bar", {
        category = "none",
        event = "ToggleReaderBottomStatusBar",
        title = _("ZenOS: Toggle bottom reader status bar"),
        reader = true,
        active_func = zen_action_active.zen_ui_toggle_reader_bottom_status_bar,
    })
    Dispatcher:registerAction("zen_ui_toggle_reader_status_bars", {
        category = "none",
        event = "ToggleReaderStatusBars",
        title = _("ZenOS: Toggle reader status bars"),
        reader = true,
        active_func = zen_action_active.zen_ui_toggle_reader_status_bars,
    })
    Dispatcher:registerAction("zen_ui_show_toc", {
        category = "none",
        event = "ShowZenUIToc",
        title = _("ZenOS: Table of contents"),
        reader = true,
    })
    Dispatcher:registerAction("zen_ui_show_home", {
        category = "none",
        event = "ShowZenUIHome",
        title = _("ZenOS: Home"),
        general = true,
    })
    Dispatcher:registerAction("zen_ui_show_library", {
        category = "none",
        event = "ShowZenUILibrary",
        title = _("ZenOS: Library"),
        general = true,
    })
    Dispatcher:registerAction("zen_ui_show_authors", {
        category = "none",
        event = "ShowZenUIAuthors",
        title = _("ZenOS: Authors"),
        general = true,
    })
    Dispatcher:registerAction("zen_ui_show_series", {
        category = "none",
        event = "ShowZenUISeries",
        title = _("ZenOS: Series"),
        general = true,
    })
    Dispatcher:registerAction("zen_ui_show_tags", {
        category = "none",
        event = "ShowZenUITags",
        title = _("ZenOS: Tags"),
        general = true,
    })
    Dispatcher:registerAction("zen_ui_show_stats", {
        category = "none",
        event = "ShowZenUIStats",
        title = _("ZenOS: Stats"),
        general = true,
    })
    -- Folder action stores its target path per-gesture (category="string" passes the
    -- stored value to the event). No section flag: the default menu loop skips it, so
    -- our _addItem patch renders a PathChooser in the General section instead of a fixed
    -- radio list. Per-gesture storage means each new action starts with no folder and
    -- users can bind several actions to different folders. Execution isn't gated on the
    -- section flag, so the action still fires in reader and file-browser contexts.
    Dispatcher:registerAction("zen_ui_show_folder", {
        category = "string",
        event = "ShowZenUIFolder",
        title = _("ZenOS: Open folder"),
        args = {},
        toggle = {},
        zen_folder_picker = true,
    })
    Dispatcher:registerAction("zen_ui_kosync_sync", {
        category = "none",
        event = "ZenUIKOSyncSync",
        title = _("ZenOS: Sync progress (pull + push)"),
        general = true,
    })
    patch_folder_picker_menu(Dispatcher)
end

function M.onToggleZenMode(plugin)
    local features = plugin and plugin.config and plugin.config.features
    if type(features) ~= "table" then return false end
    if features.lockdown_mode == true and features.zen_mode == true then
        return true
    end
    features.zen_mode = not features.zen_mode
    save_config(plugin)
    require("modules/settings/zen_settings_apply").apply_feature_toggle(
        plugin, "zen_mode", features.zen_mode)
    require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
        text = features.zen_mode and _("Zen Mode: Enabled") or _("Zen Mode: Disabled"),
        timeout = 2,
    })
    return true
end

function M.isActionActive(actions, plugin)
    if type(actions) ~= "table" then return false end
    local action_name
    for key, value in pairs(actions) do
        if key ~= "settings" then
            local name = type(key) == "number" and value or key
            if type(name) == "string" then
                if action_name then return false end
                action_name = name
            end
        end
    end
    local active_func = action_name and zen_action_active[action_name]
    if type(active_func) ~= "function" then return false end
    local ok, active = pcall(active_func, plugin)
    return ok and active == true
end

function M.onToggleLockdownMode(plugin)
    local features = plugin and plugin.config and plugin.config.features
    if type(features) ~= "table" then return false end
    local enabling = not features.lockdown_mode
    features.lockdown_mode = enabling
    if enabling then features.zen_mode = true end
    local ok_lm, lockdown_mod = pcall(require, "modules/global/patches/lockdown_mode")
    if ok_lm and type(lockdown_mod) == "table" then
        lockdown_mod.apply_magnify_layout(plugin, enabling)
    end
    save_config(plugin)
    require("modules/settings/zen_settings_apply").prompt_restart()
    return true
end

function M.setIncognitoMode(plugin, enabled, opts)
    local features = plugin and plugin.config and plugin.config.features
    if type(features) ~= "table" then return false end
    enabled = enabled == true
    if features.incognito_mode == enabled then return true end
    local ok_guard, guard = pcall(require, "modules/global/patches/incognito_mode")
    if enabled and ok_guard and type(guard.beforeEnable) == "function" then
        guard.beforeEnable(plugin)
    end
    features.incognito_mode = enabled
    if enabled and ok_guard and type(guard.afterEnable) == "function" then
        guard.afterEnable(plugin)
    elseif not enabled and ok_guard and type(guard.afterDisable) == "function" then
        guard.afterDisable(plugin)
    end
    save_config(plugin)
    refresh_incognito_indicators()
    opts = type(opts) == "table" and opts or {}
    require("ui/uimanager"):show(require("ui/widget/infomessage"):new{
        text = opts.timed_out and _("Incognito mode timed out")
            or enabled and _("Incognito mode enabled") or _("Incognito mode disabled"),
        timeout = 3,
    })
    return true
end

function M.onToggleIncognitoMode(plugin)
    local features = plugin and plugin.config and plugin.config.features
    if type(features) ~= "table" then return false end
    return M.setIncognitoMode(plugin, features.incognito_mode ~= true)
end

function M.onToggleReaderTopStatusBar(plugin)
    return set_top_status_bar(plugin, not is_top_status_bar_enabled(plugin))
end

function M.onToggleReaderThemes(plugin)
    local features = plugin and plugin.config and plugin.config.features
    if type(features) ~= "table" then return false end
    features.reader_themes = features.reader_themes ~= true
    save_config(plugin)
    local settings_apply = require("modules/settings/zen_settings_apply")
    settings_apply.apply_feature_toggle(plugin, "reader_themes", features.reader_themes)
    return true
end

M.isBottomStatusBarVisible = is_bottom_status_bar_visible
M.setBottomStatusBar = set_bottom_status_bar

function M.onToggleReaderBottomStatusBar(plugin)
    return set_bottom_status_bar(plugin, not is_bottom_status_bar_visible(plugin))
end

function M.onToggleReaderStatusBars(plugin)
    local enable = not (is_top_status_bar_enabled(plugin)
        or is_bottom_status_bar_visible(plugin))
    local top_ok = set_top_status_bar(plugin, enable)
    local bottom_ok = set_bottom_status_bar(plugin, enable)
    return top_ok or bottom_ok
end

function M.onShowZenUIHome(plugin)
    return show_zen_tab(plugin, "home", { open_home = true })
end

function M.onShowZenUILibrary(plugin)
    return show_library(plugin)
end

function M.onShowZenUIAuthors(plugin)
    return show_zen_tab(plugin, "authors")
end

function M.onShowZenUISeries(plugin)
    return show_zen_tab(plugin, "series")
end

function M.onShowZenUITags(plugin)
    return show_zen_tab(plugin, "tags")
end

function M.onShowZenUITag(plugin, tag)
    return show_zen_tag(plugin, tag)
end

function M.onShowZenUIStats(plugin)
    return show_zen_tab(plugin, "stats")
end

function M.onShowZenUIFolder(plugin, folder)
    -- category="string": Dispatcher passes the per-action stored folder path as arg.
    return show_zen_folder(plugin, folder)
end

function M.onZenUIKOSyncSync()
    return sync_reading_progress()
end

function M.onShowZenUIToc(plugin)
    return show_zen_toc(plugin)
end

function M.install(target)
    _plugin = target
    target.onDispatcherRegisterActions = M.onDispatcherRegisterActions
    target.onToggleZenMode = M.onToggleZenMode
    target.onToggleLockdownMode = M.onToggleLockdownMode
    target.onToggleIncognitoMode = M.onToggleIncognitoMode
    target.onToggleReaderTopStatusBar = M.onToggleReaderTopStatusBar
    target.onToggleReaderThemes = M.onToggleReaderThemes
    target.onToggleReaderBottomStatusBar = M.onToggleReaderBottomStatusBar
    target.onToggleReaderStatusBars = M.onToggleReaderStatusBars
    target.onShowZenUIHome = M.onShowZenUIHome
    target.onShowZenUILibrary = M.onShowZenUILibrary
    target.onShowZenUIAuthors = M.onShowZenUIAuthors
    target.onShowZenUISeries = M.onShowZenUISeries
    target.onShowZenUITags = M.onShowZenUITags
    target.onShowZenUITag = M.onShowZenUITag
    target.onShowZenUIStats = M.onShowZenUIStats
    target.onShowZenUIFolder = M.onShowZenUIFolder
    target.onZenUIKOSyncSync = M.onZenUIKOSyncSync
    target.onShowZenUIToc = M.onShowZenUIToc
end

return M
