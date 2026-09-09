local _ = require("gettext")

local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local restart = require("common/restart")
local SharedState = require("common/shared_state")

local M = {}
local active_plugin

local PATCH_MODULES = {
    navbar = "modules/filebrowser/patches/navbar",
    quick_settings = "modules/menu/patches/quick_settings",
    app_launcher = "modules/menu/patches/app_launcher",
    zen_mode = "modules/menu/patches/zen_mode",
    status_bar = "modules/filebrowser/patches/status_bar",
    disable_top_menu_swipe_zones = "modules/menu/patches/disable_top_menu_swipe_zones",
    browser_hide_underline = "modules/filebrowser/patches/browser_hide_underline",
    browser_hide_up_folder = "modules/filebrowser/patches/browser_hide_up_folder",
    automatic_series_grouping = "modules/filebrowser/patches/automatic_series_grouping",
    reader_top_status_bar = "modules/reader/patches/reader_top_status_bar",
    reader_themes = "modules/reader/patches/reader_themes",
}

local RESTART_REQUIRED = {
    browser_hide_underline = true,
}

local APPLY_MODE = {
    navbar = "filemanager_layout",
    quick_settings = "menu_refresh",
    app_launcher = "menu_refresh",
    zen_mode = "zen_mode",
    status_bar = "filemanager_reinit",
    disable_top_menu_swipe_zones = "menu_refresh",
    browser_hide_up_folder = "filemanager_refresh",
    automatic_series_grouping = "filemanager_refresh",
    reader_top_status_bar = "reader_refresh",
    reader_themes = "reader_themes",
}

local RUNTIME_PATCHES = rawget(_G, "__ZEN_UI_RUNTIME_PATCHES")
if type(RUNTIME_PATCHES) ~= "table" then
    RUNTIME_PATCHES = {}
    _G.__ZEN_UI_RUNTIME_PATCHES = RUNTIME_PATCHES
end

local function with_plugin(plugin, fn)
    local prev_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    _G.__ZEN_UI_PLUGIN = plugin
    local ok, err = pcall(fn)
    _G.__ZEN_UI_PLUGIN = prev_plugin
    return ok, err
end

local function ensure_patch_loaded(plugin, feature)
    if RUNTIME_PATCHES[feature] then
        return true
    end

    local module_name = PATCH_MODULES[feature]
    if not module_name then
        return true
    end

    local ok_require, patch_fn = pcall(require, module_name)
    if not ok_require or type(patch_fn) ~= "function" then
        return false
    end

    local ok_apply = with_plugin(plugin, patch_fn)
    if ok_apply then
        RUNTIME_PATCHES[feature] = true
    end

    return ok_apply
end

local function get_shared(plugin, key)
    return SharedState.get(plugin, key)
end

M.get_shared = get_shared

local function prompt_restart()
    UIManager:show(ConfirmBox:new{
        text = _("This change requires a restart to take effect."),
        ok_text = _("Restart now"),
        cancel_text = _("Later"),
        ok_callback = function()
            restart.request()
        end,
    })
end

local function apply_filemanager_layout()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    local fm = ok and FileManager and FileManager.instance
    if fm and fm.setupLayout then
        fm:setupLayout()
        UIManager:setDirty(fm, "ui")
    end
end

local function apply_navbar_refresh()
    local plugin = active_plugin or rawget(_G, "__ZEN_UI_PLUGIN")
    local home = get_shared(plugin, "home")
    if home and type(home.invalidateNavbar) == "function" then
        home.invalidateNavbar()
    end
    local reinject = rawget(_G, "__ZEN_UI_REINJECT_NAVBARS")
        or rawget(_G, "__ZEN_UI_REINJECT_FM_NAVBAR")
    if type(reinject) == "function" then
        reinject()
    else
        apply_filemanager_layout()
    end
end

local function apply_filemanager_reinit()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    local fm = ok and FileManager and FileManager.instance
    if fm and fm.reinit then
        fm:reinit()
        UIManager:setDirty(FileManager.instance or fm, "full")
        UIManager:scheduleIn(0, function()
            local current = FileManager.instance or fm
            UIManager:setDirty(current, "full")
            UIManager:forceRePaint()
        end)
    end
end

local function rebuild_active_home()
    local plugin = active_plugin or rawget(_G, "__ZEN_UI_PLUGIN")
    local home = get_shared(plugin, "home")
    if home and home.rebuildActive then
        home.rebuildActive()
    end
end

local function apply_tbr_refresh()
    UIManager:setDirty(nil, "full")
    UIManager:forceRePaint()
end

local function apply_filemanager_refresh()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    local fm = ok and FileManager and FileManager.instance
    if fm and fm.file_chooser and fm.file_chooser.refreshPath then
        fm.file_chooser:refreshPath()
        UIManager:setDirty(fm, "ui")
    end
end

local function apply_menu_refresh()
    UIManager:setDirty("all", "ui")
end

local function apply_zen_mode()
    local refresh = get_shared(active_plugin, "refreshZenModeMenus")
    if type(refresh) == "function" then refresh() end
    apply_menu_refresh()
end

local function apply_reader_refresh()
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local reader = ok and ReaderUI and ReaderUI.instance
    if reader then
        local typeset = reader.typeset
        if typeset and typeset.unscaled_margins
                and type(typeset.onSetPageMargins) == "function" then
            typeset:onSetPageMargins(typeset.unscaled_margins)
        end
        UIManager:setDirty(reader, "ui")
    end
end

local function apply_reader_themes()
    require("common/reader_themes").applyCurrent(active_plugin)
end

-- Deferred to avoid resetting the menu to page 1 while it's still open.
local DISRUPTIVE_MODES = {
    filemanager_layout  = true,
    filemanager_reinit  = true,
    filemanager_refresh = true,
    navbar_refresh      = true,
}

local deferred_applies      = {}
local deferred_poll_active  = false
local deferred_poll_retries = 0
local DEFERRED_MAX_RETRIES  = 40 -- 10 s at 0.25 s intervals

-- True when a settings menu that owns the FileManager is open.
local function is_filemanager_menu_open()
    if rawget(_G, "__ZEN_UI_SETTINGS_PAGE") then return true end
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok or not FileManager or not FileManager.instance then return false end
    local fm = FileManager.instance
    local menu = fm.menu
    if not menu then return false end
    local menu_container = menu.menu_container
    local stack = UIManager._window_stack
    if not stack then return menu_container ~= nil end
    for _i, entry in ipairs(stack) do
        local widget = entry and entry.widget
        if widget == menu or (menu_container and widget == menu_container) then return true end
    end
    return false
end

local function run_apply_mode_now(mode)
    if mode == "filemanager_layout" then
        apply_filemanager_layout()
    elseif mode == "filemanager_reinit" then
        apply_filemanager_reinit()
        UIManager:scheduleIn(0, rebuild_active_home)
    elseif mode == "filemanager_refresh" then
        apply_filemanager_refresh()
    elseif mode == "navbar_refresh" then
        apply_navbar_refresh()
    elseif mode == "tbr_refresh" then
        apply_tbr_refresh()
    elseif mode == "menu_refresh" then
        apply_menu_refresh()
    elseif mode == "zen_mode" then
        apply_zen_mode()
    elseif mode == "reader_refresh" then
        apply_reader_refresh()
    elseif mode == "reader_themes" then
        apply_reader_themes()
    end
end

local function flush_deferred_now()
    deferred_poll_active = false
    deferred_poll_retries = 0
    local pending = deferred_applies
    deferred_applies = {}
    local navbar_refresh = pending.navbar_refresh
    pending.navbar_refresh = nil
    for mode, _mode in pairs(pending) do
        run_apply_mode_now(mode)
    end
    if navbar_refresh then run_apply_mode_now("navbar_refresh") end
end

-- Polls at 0.25 s intervals until the menu closes, then applies deferred modes.
local function flush_deferred()
    deferred_poll_active = false
    if rawget(_G, "__ZEN_UI_SETTINGS_PAGE") then return end
    if is_filemanager_menu_open() and deferred_poll_retries < DEFERRED_MAX_RETRIES then
        deferred_poll_retries = deferred_poll_retries + 1
        deferred_poll_active = true
        UIManager:scheduleIn(0.25, flush_deferred)
        return
    end
    flush_deferred_now()
end

local function queue_deferred_apply(mode)
    deferred_applies[mode] = true
    if rawget(_G, "__ZEN_UI_SETTINGS_PAGE") then return end
    if not deferred_poll_active then
        deferred_poll_active  = true
        deferred_poll_retries = 0
        UIManager:scheduleIn(0.25, flush_deferred)
    end
end

local function install_touchmenu_close_flush()
    local ok, TouchMenu = pcall(require, "ui/widget/touchmenu")
    if not ok or not TouchMenu or TouchMenu._zen_settings_apply_close_flush then return end
    TouchMenu._zen_settings_apply_close_flush = true
    local orig_onCloseWidget = TouchMenu.onCloseWidget
    function TouchMenu:onCloseWidget(...)
        if orig_onCloseWidget then orig_onCloseWidget(self, ...) end
        if next(deferred_applies) == nil then return end
        if rawget(_G, "__ZEN_UI_SETTINGS_PAGE") then return end
        UIManager:scheduleIn(0, flush_deferred_now)
    end
end

install_touchmenu_close_flush()

local function run_apply_mode(mode)
    if DISRUPTIVE_MODES[mode] and is_filemanager_menu_open() then
        queue_deferred_apply(mode)
        return
    end
    run_apply_mode_now(mode)
end

function M.apply_feature_toggle(plugin, feature, enabled)
    active_plugin = plugin or active_plugin
    if feature == "reader_top_status_bar" and enabled then
        require("common/reader_status_bar").disableKoreaderAltStatusBar()
    end
    if RESTART_REQUIRED[feature] then
        prompt_restart()
        return
    end

    if enabled and not ensure_patch_loaded(plugin, feature) then
        prompt_restart()
        return
    end

    local mode = APPLY_MODE[feature]
    if mode then
        run_apply_mode(mode)
    end
end

M.prompt_restart = prompt_restart

function M.set_plugin(plugin)
    active_plugin = plugin or active_plugin
end

-- Trigger a file manager reinit (deferred while the touch menu is open).
-- Use this when a setting changes the footer height (e.g. scroll bar style).
function M.reinit_filemanager()
    run_apply_mode("filemanager_reinit")
end

-- Queue a file manager reinit for the next TouchMenu close.
-- Use this from TouchMenu callbacks that change footer/navbar height.
function M.reinit_filemanager_on_menu_close()
    queue_deferred_apply("filemanager_reinit")
end

-- Queue navbar reinjection until the active settings menu closes.
function M.refresh_navbar_on_menu_close()
    queue_deferred_apply("navbar_refresh")
end

-- Repaint shared TBR surfaces only after the settings overlay closes.
function M.refresh_tbr_on_menu_close()
    queue_deferred_apply("tbr_refresh")
end

-- ZenSettingsPage calls this after it has been closed. TouchMenu has its own
-- close hook above.
function M.flush_deferred_on_settings_close()
    if next(deferred_applies) == nil then return end
    UIManager:nextTick(flush_deferred_now)
end

return M
