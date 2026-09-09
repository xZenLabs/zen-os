-- Run the on-disk identity bridge before loading any normal Zen modules. The
-- legacy package returns an inert plugin for this boot, then restarts as ZenOS.
local BrandMigration = require("common/brand_migration")
local _brand_startup = BrandMigration.detectStartup(debug.getinfo(1, "S").source)
if _brand_startup.inert then
    local WidgetContainer = require("ui/widget/container/widgetcontainer")
    local BrandMigrationPlugin = WidgetContainer:extend{
        name = _brand_startup.plugin_dir == BrandMigration.PLUGIN_DIR
            and BrandMigration.PLUGIN_ID or BrandMigration.LEGACY_PLUGIN_ID,
        is_doc_only = false,
    }

    function BrandMigrationPlugin:init()
        _brand_startup = BrandMigration.performPending(_brand_startup)
        BrandMigration.notify(_brand_startup)
    end

    function BrandMigrationPlugin:deletePluginSettings()
        pcall(BrandMigration.deletePluginSettings)
        return true
    end

    return BrandMigrationPlugin
end

local ZenLogger = require("common/zen_logger")
local logger = ZenLogger.new("main")

-- This must happen before loading ZenOS modules: Simple UI installs a
-- conflicting common/i18n module during its own startup.
local _incompatible_plugins_restart_required = false
do
    logger.info("Checking incompatible plugins before startup")
    local ok_compat, incompatible_check = pcall(require,
        "modules/filebrowser/patches/incompatible_plugins_check")
    if not ok_compat then
        logger.warn("Incompatible-plugin check failed:", incompatible_check)
    elseif type(incompatible_check) == "function" then
        _incompatible_plugins_restart_required = incompatible_check()
    end
end

-- Install i18n before Zen modules capture gettext-backed labels.
local i18n
if _incompatible_plugins_restart_required then
    -- KOReader may still call onCloseWidget on this inert plugin instance.
    i18n = { install = function() end, refresh = function() end }
else
    i18n = require("common/i18n")
    i18n.install()
    require("common/status_bar_registry").install()
end

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

-- Early conflict detection: checked before any potentially interfering code
-- (font registration, icon injection) runs at module-load time.
-- ptutil is unique to ProjectTitle and is required at the top of its main.lua,
-- so it will be in package.loaded before our module-level code runs.
local _pt_active = package.loaded["ptutil"] ~= nil

local ConfigManager = require("config/manager")
local _startup_config = ConfigManager.load()
local registry = require("modules/registry")
local zen_settings_page = require("modules/settings/zen_settings_page")
require("modules/filebrowser/patches/home/components/registry").install()
local zen_updater   = require("modules/settings/zen_updater")
local paths         = require("common/paths")
local library_navigation = require("common/library_navigation")
local MarkdownText  = require("common/ui/markdown_text")

-- Absolute path to this plugin's root directory (shared module resolves relative paths).
local _plugin_root = require("common/plugin_root")

-- Preserve ZenOS's existing cache registration and navbar icon sync behavior.
require("common/inject_icons")
if _plugin_root then
    local utils = require("common/utils")
    -- Fixed Zen controls use private aliases that icon packs cannot name.
    local zen_icon = _plugin_root .. "/icons/zen_ui.svg"
    local zen_update_icon = _plugin_root .. "/icons/zen_ui_update.svg"
    utils.overrideIcons({
        ["notice-info"]      = zen_icon,
        ["notice-question"]  = zen_icon,
        ["_zen_settings_tab"] = zen_icon,
        ["_zen_update_tab"]   = zen_update_icon,
        ["_zen_quickstart"]   = zen_icon,
        ["_zen_quickstart_update"] = zen_update_icon,
    }, false)
    -- Register bundled fonts into KOReader's font system so they appear
    -- in all font pickers (FontChooser) across the UI.
    do
        local ok_fl, FontList = pcall(require, "fontlist")
        if ok_fl and FontList then
            FontList:getFontList()  -- ensure fontlist + fontinfo initialized
            -- Scan bundled fonts dir into fontlist/fontinfo for FontChooser.
            local mark = {}
            -- this will show an error about the symbols not being able to register for reader
            -- this is normal and can be ignored
            pcall(FontList._readList, FontList, _plugin_root .. "/fonts", mark)
            if next(mark) then
                -- Rebuild fontnames so FontChooser groups by family.
                local names = FontList.fontnames
                for path in pairs(mark) do
                    local coll = FontList.fontinfo[path]
                    if coll then
                        for _j, v in ipairs(coll) do
                            local nlist = names[v.name] or {}
                            names[v.name] = nlist
                            table.insert(nlist, v)
                        end
                    end
                end
                table.sort(FontList.fontlist)
            end
            -- SymbolsNerdFont also serves as glyph fallback for MDI icons.
            -- Skipped when ProjectTitle is active: crengine fails to register
            -- the font on some devices, causing a width=0 crash.
            if not _pt_active then
                local ok_font, Font = pcall(require, "ui/font")
                if ok_font and Font and Font.fallbacks then
                    pcall(table.insert, Font.fallbacks, "SymbolsNerdFont-Regular.ttf")
                end
            end
        end
    end
end

-- Custom packs are an additional first-priority layer over the existing loader.
require("common/icon_packs").initialize(_startup_config)

-- Holds the single plugin instance so the FileManagerMenu patch can reach it.
local _zen_plugin_ref = nil
-- Weak-keyed table of FileManagerMenu/ReaderMenu instances that have been patched,
-- so the on_update_found callback can rebuild their tab_item_table dynamically.
local _zen_menu_instances = setmetatable({}, { __mode = "k" })

local function refresh_home_date_dependent(plugin)
    local ok_shared, SharedState = pcall(require, "common/shared_state")
    local home = ok_shared and SharedState.get(plugin, "home") or nil
    if home and type(home.refreshDateDependentActive) == "function" then
        home.refreshDateDependentActive()
    end
end

local function build_update_changelog_scroll_text(items)
    return MarkdownText.format_list(_("What's New"), items)
end

-- Defensive nil-action guard: prevent UIManager:scheduleIn/nextTick(nil) crashes.
-- Installed once per process; logs a traceback so the real culprit can be identified.
-- Catches bugs in ZenOS *and* in KOReader sync plugins (which share the same UIManager).
if not rawget(_G, "__zen_ui_uimgr_guard") then
    _G.__zen_ui_uimgr_guard = true
    local ok_um, UIManager = pcall(require, "ui/uimanager")
    if ok_um and UIManager then
        local _orig_scheduleIn = UIManager.scheduleIn
        UIManager.scheduleIn = function(self, seconds, action, ...)
            if action == nil then
                logger.warn("UIManager:scheduleIn(nil) suppressed\n" ..
                    (debug and debug.traceback and debug.traceback("", 2) or ""))
                return
            end
            return _orig_scheduleIn(self, seconds, action, ...)
        end
        local _orig_nextTick = UIManager.nextTick
        UIManager.nextTick = function(self, action, ...)
            if action == nil then
                logger.warn("UIManager:nextTick(nil) suppressed\n" ..
                    (debug and debug.traceback and debug.traceback("", 2) or ""))
                return
            end
            return _orig_nextTick(self, action, ...)
        end
    end
end

local ZenUI = WidgetContainer:extend{
    name = "zenos",
    is_doc_only = false,
}

require("common/dispatch_action").install(ZenUI)

function ZenUI:saveConfig()
    ConfigManager.save(self.config)
end

local function is_enabled(config, path)
    if not path then
        return true
    end
    local node = config
    for _i, key in ipairs(path) do
        node = node and node[key]
    end
    return node == true
end

function ZenUI:_initModules()
    for _i, def in ipairs(registry) do
        if is_enabled(self.config, def.setting) then
            local started_at = os.clock()
            local ok, module = pcall(require, def.file)
            if ok and module and module.init then
                local loaded_ok = module.init(logger, self)
                if not loaded_ok then
                    logger.warn("Module failed to load", def.id)
                end
            else
                logger.warn("Module require failed", def.id)
            end
            logger.perf("Module initialization completed",
                (os.clock() - started_at) * 1000, "module=", def.id)
        end
    end
end

function ZenUI:init()
    local brand_state = BrandMigration.checkRootConflict(_brand_startup)
    if brand_state.inert then
        self._zenos_brand_inert = true
        BrandMigration.notify(brand_state)
        return
    end
    BrandMigration.installLegacyRuntimeAliases(self)
    local started_at = os.clock()
    if _incompatible_plugins_restart_required then
        logger.warn("ZenOS initialization skipped; restart required after disabling incompatible plugins")
        return
    end
    i18n.refresh()
    self.config = ConfigManager.load()
    if _plugin_root then
        require("common/utils").copyDefaultCustomTabIcon(
            _plugin_root .. "/icons/", self.config and self.config.navbar)
    end
    _G.__ZEN_UI_LIBRARY_FONT_CFG = self.config and self.config.library_font or nil
    _zen_plugin_ref = self
    for _i, integration in ipairs({
        { name = "ZenPM", method = "ensure_zenpm_launcher_entry" },
        { name = "ZenFM", method = "ensure_zenfm_launcher_entry" },
    }) do
        local ok, added_or_error = pcall(function()
            return require("modules/menu/app_launcher/model")[integration.method]()
        end)
        if not ok then
            logger.warn(integration.name .. " launcher integration failed:", added_or_error)
        elseif added_or_error then
            logger.info("Added " .. integration.name .. " to the launcher")
        end
    end
    require("ui/uimanager"):nextTick(function()
        local ok, added_or_error = pcall(function()
            return require("modules/menu/app_launcher/model").ensure_zenpm_plugin_entries()
        end)
        if not ok then
            logger.warn("ZenPM plugin launcher integration failed:", added_or_error)
        elseif added_or_error then
            logger.info("Added newly installed ZenPM plugins to the launcher")
        end
    end)
    self:onDispatcherRegisterActions()
    -- Initialize updater state; release metadata stays live-only.
    zen_updater.init_banner()

    -- Clamp persisted list items-per-page before any browser reads it,
    -- so covers stay legible regardless of where it was set (ZenOS,
    -- KOReader's coverbrowser, or a legacy save).
    pcall(function() require("common/cover_utils").getFilesPerPage() end)

    -- First-run: backup user's original screensaver settings as a preset.
    if not self.config._meta.screensaver_backup_created then
        local PresetStore = require("config/preset_store")
        local backup = {
            name = "backup",
            screensaver_type = G_reader_settings:readSetting("screensaver_type"),
            screensaver_message = G_reader_settings:readSetting("screensaver_message"),
            screensaver_show_message = G_reader_settings:isTrue("screensaver_show_message"),
            screensaver_img_background = G_reader_settings:readSetting("screensaver_img_background"),
            screensaver_document_cover = G_reader_settings:readSetting("screensaver_document_cover"),
            screensaver_stretch_images = G_reader_settings:isTrue("screensaver_stretch_images"),
            screensaver_stretch_limit_percentage = G_reader_settings:readSetting("screensaver_stretch_limit_percentage"),
        }
        PresetStore.save("screensaver", backup.name, backup)
        PresetStore.saveSettings("screensaver", backup)
        PresetStore.setActivePreset("screensaver", backup.name)
        self.config._meta.screensaver_backup_created = true
        self:saveConfig()
    end

    -- First-run: backup user's original footer settings as a preset.
    if not self.config._meta.footer_backup_created then
        local footer_settings = G_reader_settings:readSetting("footer")
        if footer_settings then
            local PresetStore = require("config/preset_store")
            local util = require("util")
            if type(self.config.reader_footer) ~= "table" then
                self.config.reader_footer = {}
            end
            local backup = {
                name = "Backup of Original",
                builtin = true,
                footer = util.tableDeepCopy(footer_settings),
                reader_footer_mode = G_reader_settings:readSetting("reader_footer_mode") or 1,
                reader_footer_custom_text = G_reader_settings:readSetting("reader_footer_custom_text") or "KOReader",
                reader_footer_custom_text_repetitions = G_reader_settings:readSetting("reader_footer_custom_text_repetitions") or 1,
            }
            PresetStore.save("reader", backup.name, backup)
            PresetStore.saveSettings("reader", backup)
            PresetStore.setActivePreset("reader", backup.name)
            self.config._meta.footer_backup_created = true
            self:saveConfig()
        end
    end

    -- First-run: default sort to recently read, mix files and folders.
    -- Always override: KOReader ships "title" as its own default, so guarding
    -- on readSetting() would silently skip this on a fresh install.
    if not self.config._meta.sort_defaults_applied then
        G_reader_settings:saveSetting("collate", "access")
        G_reader_settings:saveSetting("collate_mixed", true)
        self.config._meta.sort_defaults_applied = true
        self:saveConfig()
    end

    -- First-run: default portrait list mode to 5 items per page.
    if not self.config._meta.files_per_page_defaulted then
        local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
        if ok_bim then
            BookInfoManager:saveSetting("files_per_page", 5)
            local ok_fc, FileChooser = pcall(require, "ui/widget/filechooser")
            if ok_fc then
                FileChooser.files_per_page = 5
            end
        end
        self.config._meta.files_per_page_defaulted = true
        self:saveConfig()
    end

    self:_initModules()
    -- TBR is a normal KOReader collection; create it for standard pickers.
    pcall(function() require("common/tbr_index").ensureCollection() end)
    logger.perf("Core initialization completed", (os.clock() - started_at) * 1000)

    local function schedule_quickstart_menu_tour(delay)
        require("ui/uimanager"):scheduleIn(delay, function()
            local ok, tour = pcall(require, "common/quickstart/menu_tour")
            if ok then
                tour.start(self)
            else
                logger.warn("failed to load quickstart menu tour:", tour)
            end
        end)
    end

    -- -----------------------------------------------------------------------
    -- Quickstart / onboarding screen
    -- -----------------------------------------------------------------------
    do
        local function get_plugin_version()
            if _plugin_root then
                local ok, meta = pcall(dofile, _plugin_root .. "/_meta.lua")
                if ok and type(meta) == "table" and type(meta.version) == "string" then
                    return meta.version
                end
            end
            local ok, meta = pcall(require, "_meta")
            return (ok and type(meta) == "table" and type(meta.version) == "string")
                and meta.version or "0.0.0"
        end

        local current_ver = get_plugin_version()
        local shown_ver   = self.config._meta.quickstart_shown_for_version

        -- Normalize sentinel set by manager.lua for existing installs that
        -- predated the quickstart feature. Persisting current_ver prevents
        -- false-positive install and update screens on subsequent boots.
        if shown_ver == "pre-quickstart" then
            shown_ver = current_ver
            self.config._meta.quickstart_shown_for_version = current_ver
            self:saveConfig()
        end

        local updater_cfg = (type(self.config.updater) == "table") and self.config.updater or nil

        -- One-shot flag written by zen_updater before restart; takes priority
        -- over version comparison (handles pre-quickstart installs too).
        local just_updated_ver = updater_cfg and updater_cfg.just_updated_version or ""
        local from_updater = type(just_updated_ver) == "string" and just_updated_ver ~= ""
        if from_updater then
            self.config.updater.just_updated_version = ""
            self:saveConfig()
        end

        local pages_to_show
        local changelog_to_show
        local is_update = from_updater
            or (type(shown_ver) == "string" and shown_ver ~= current_ver)

        local update_channel = (type(self.config.updater) == "table"
            and self.config.updater.update_channel) or "stable"
        logger.info("current_ver=", current_ver,
            "shown_ver=", tostring(shown_ver),
            "just_updated_ver=", tostring(just_updated_ver),
            "from_updater=", from_updater,
            "is_update=", is_update,
            "channel=", update_channel)
        if shown_ver == false then
            local ok_pages, pages_mod = pcall(require, "common/quickstart/quickstart_pages")
            if ok_pages then
                pages_to_show = pages_mod.build_install_pages({
                    plugin = self,
                    config = self.config,
                })
            end
        elseif is_update then
            local ok_pages, pages_mod = pcall(require, "common/quickstart/quickstart_pages")
            if ok_pages then
                -- Strip beta suffix (e.g. "1.0.4-beta2" -> "1.0.4") for changelog lookup.
                local stable_ver = current_ver:match("^([%d%.]+)")
                pages_to_show     = pages_mod.UPDATE_PAGES[current_ver]
                changelog_to_show = pages_mod.CHANGELOGS and (
                    pages_mod.CHANGELOGS[current_ver] or pages_mod.CHANGELOGS[stable_ver])
            end
        end

        if shown_ver == false and pages_to_show and #pages_to_show > 0 then
            -- Persist before showing so a force-quit doesn't replay the screen.
            self.config._meta.quickstart_shown_for_version = current_ver
            self:saveConfig()

            require("ui/uimanager"):scheduleIn(0.5, function()
                local ok_qs, QuickstartScreen = pcall(require, "common/quickstart/quickstart_screen")
                if not ok_qs then return end
                require("ui/uimanager"):show(QuickstartScreen:new{
                    pages    = pages_to_show,
                    on_close = function()
                        self.config._meta.quickstart_completed = true
                        self.config._meta.quickstart_menu_tour_pending = true
                        self:saveConfig()
                        -- scheduleIn(0) lets UIManager finish the close-frame before
                        -- we force a full repaint and navbar reinject.
                        require("ui/uimanager"):scheduleIn(0, function()
                            if shown_ver == false then -- first install defaults
                                -- Disable CoverBrowser description hint (on by default).
                                local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
                                if ok_bim then
                                    pcall(BookInfoManager.saveSetting, BookInfoManager,
                                        "no_hint_description", true)
                                end
                                -- Disable auto-show bottom menu in reader.
                                G_reader_settings:makeFalse("show_bottom_menu")
                                -- Refresh file manager status bar with the chosen clock format.
                                local ok_fm2, FileManager2 = pcall(require, "apps/filemanager/filemanager")
                                local fm2 = ok_fm2 and FileManager2 and FileManager2.instance
                                if fm2 and type(fm2._updateStatusBar) == "function" then
                                    fm2:_updateStatusBar()
                                end
                            end
                            local reinject = _G.__ZEN_UI_REINJECT_FM_NAVBAR
                            if type(reinject) == "function" then
                                reinject()
                            else
                                -- fallback when navbar feature is disabled
                                local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
                                local fm = ok and FileManager and FileManager.instance
                                if fm and type(fm.onHome) == "function" then fm:onHome() end
                            end
                            -- Navigate to new home_dir if it was set during quickstart
                            -- (reinject only repaints; it doesn't change the FM path).
                            local ok_fm3, FM3 = pcall(require, "apps/filemanager/filemanager")
                            local fm3 = ok_fm3 and FM3 and FM3.instance
                            if fm3 and fm3.file_chooser then
                                local new_home = paths.getHomeDir()
                                if new_home and new_home ~= "" and new_home ~= fm3.file_chooser.path then
                                    fm3.file_chooser:changeToPath(new_home)
                                end
                            end
                            schedule_quickstart_menu_tour(0.35)
                        end)
                    end,
                })
            end)
        elseif is_update then
            -- Clear a stale banner left by a manual/external install.
            zen_updater.clear_update_state(self.config)

            -- Post-update: always show the ZenScreen splash, then chain UPDATE_PAGES if present.
            self.config._meta.quickstart_shown_for_version = current_ver
            self:saveConfig()
            logger.info("scheduling for version", current_ver, "pages_to_show=", pages_to_show and #pages_to_show or 0)
            require("ui/uimanager"):scheduleIn(0.5, function()
                logger.info("timer fired, requiring zen_screen")
                local ok_zs, ZenScreen = pcall(require, "common/ui/zen_screen")
                if not ok_zs then
                    logger.warn("failed to load zen_screen:", ZenScreen)
                    return
                end
                logger.info("showing ZenScreen")
                local T = require("ffi/util").template
                local UIManager = require("ui/uimanager")
                UIManager:forceRePaint()
                UIManager:show(ZenScreen:new{
                    title       = _("ZenOS"),
                    title_icon  = true,
                    subtitle    = T(_("Updated to %1"), "v" .. current_ver),
                    changelog   = (type(changelog_to_show) == "table" and #changelog_to_show > 0)
                        and changelog_to_show or nil,
                    scroll_text = build_update_changelog_scroll_text(changelog_to_show),
                    on_close    = function()
                        logger.info("closed, pages_to_show=", pages_to_show and #pages_to_show or 0)
                        if pages_to_show and #pages_to_show > 0 then
                            local ok_qs, QuickstartScreen = pcall(require, "common/quickstart/quickstart_screen")
                            if not ok_qs then
                                logger.warn("failed to load quickstart_screen:", QuickstartScreen)
                                return
                            end
                            logger.info("showing QuickstartScreen")
                            require("ui/uimanager"):show(QuickstartScreen:new{
                                pages = pages_to_show,
                            })
                        end
                    end,
                })
            end)
        end

        if shown_ver ~= false and not is_update
                and self.config._meta.quickstart_menu_tour_pending == true then
            schedule_quickstart_menu_tour(0.8)
        end
    end

    -- Inject ZenOS and Library tabs around Quick Settings.
    -- Patches setUpdateItemTable once per class so it persists across menu rebuilds.
    local function find_quicksettings_pos(tab_table)
        for i, tab in ipairs(tab_table) do
            for _i, field in ipairs({ "id", "name", "icon" }) do
                local v = tab[field]
                if type(v) == "string" then
                    local norm = v:lower():gsub("[%s_%-]+", "")
                    if norm == "quicksettings" then
                        return i
                    end
                end
            end
        end
        return nil
    end

    local function take_quicksettings_tab(tab_table)
        local qs_pos = find_quicksettings_pos(tab_table)
        if not qs_pos then return nil, nil end
        return qs_pos, table.remove(tab_table, qs_pos)
    end

    local function take_tab_by_id(tab_table, id)
        for i, tab in ipairs(tab_table) do
            if tab.id == id then
                return i, table.remove(tab_table, i)
            end
        end
        return nil, nil
    end

    local function zen_panel_hidden()
        local _cfg = _zen_plugin_ref and _zen_plugin_ref.config
        local _lc = _cfg and _cfg.lockdown
        local _ft = _cfg and _cfg.features
        return type(_lc) == "table" and _lc.disable_settings_panel == true
            and type(_ft) == "table" and _ft.lockdown_mode == true
    end

    local function flip_lh_rh_icons()
        local _cfg = _zen_plugin_ref and _zen_plugin_ref.config
        local _qs = _cfg and _cfg.quick_settings
        if type(_qs) == "table" and _qs.flip_lh_rh_icon ~= nil then
            return _qs.flip_lh_rh_icon == true
        end
        local _menu = _cfg and _cfg.menu
        return type(_menu) == "table" and _menu.flip_lh_rh_icons == true
    end

    local function library_home_icon()
        local get_default_tab_icon = rawget(_G, "__ZEN_UI_NAVBAR_DEFAULT_TAB_ICON")
        if type(get_default_tab_icon) == "function" then
            local icon = get_default_tab_icon()
            if type(icon) == "string" and icon ~= "" then
                return icon
            end
        end
        local _cfg = _zen_plugin_ref and _zen_plugin_ref.config
        local _menu = _cfg and _cfg.menu
        local icon = type(_menu) == "table" and _menu.library_home_icon
        return (type(icon) == "string" and icon ~= "") and icon or "library"
    end

    local function app_launcher_enabled()
        local _cfg = _zen_plugin_ref and _zen_plugin_ref.config
        local _ft = _cfg and _cfg.features
        return type(_ft) == "table" and _ft.app_launcher == true
    end

    local function make_zen_settings_tab(m_self)
        local tab = {
            id = "zen_ui",
            icon = zen_updater.has_update() and "_zen_update_tab" or "_zen_settings_tab",
            remember = false,
        }
        tab.callback = function()
            require("ui/uimanager"):scheduleIn(0, function()
                local UIManager = require("ui/uimanager")
                if m_self.menu_container then
                    UIManager:close(m_self.menu_container)
                    m_self.menu_container = nil
                end
                if _zen_plugin_ref then
                    zen_settings_page.show(_zen_plugin_ref)
                end
            end)
        end
        return tab
    end

    local function remove_zen_menu_tabs(m_self)
        for i = #m_self.tab_item_table, 1, -1 do
            local tab = m_self.tab_item_table[i]
            if tab == m_self._zen_tab_item or tab == m_self._zen_home_tab_item then
                table.remove(m_self.tab_item_table, i)
            end
        end
    end

    local function insert_zen_menu_tabs(m_self, panel_hidden)
        local qs_pos, qs_tab = take_quicksettings_tab(m_self.tab_item_table)
        local app_tab = select(2, take_tab_by_id(m_self.tab_item_table, "app_launcher"))
        if not app_launcher_enabled() then
            app_tab = nil
        end
        if qs_pos and not m_self._zen_qs_insert_pos then
            m_self._zen_qs_insert_pos = qs_pos
        end
        local insert_pos = m_self._zen_qs_insert_pos or qs_pos or 1
        insert_pos = math.min(insert_pos, #m_self.tab_item_table + 1)
        if flip_lh_rh_icons() then
            table.insert(m_self.tab_item_table, insert_pos, m_self._zen_home_tab_item)
            if not panel_hidden then
                table.insert(m_self.tab_item_table, insert_pos + 1, m_self._zen_tab_item)
            end
            if app_tab then
                table.insert(m_self.tab_item_table, app_tab)
            end
            if qs_tab then
                -- Last tab is pushed to far-right by TouchMenuBar's stretch spacer.
                table.insert(m_self.tab_item_table, qs_tab)
            end
        else
            if qs_tab then
                table.insert(m_self.tab_item_table, insert_pos, qs_tab)
            end
            local next_pos = qs_tab and (insert_pos + 1) or insert_pos
            if app_tab then
                table.insert(m_self.tab_item_table, next_pos, app_tab)
            end
            -- Keep Settings beside Library at the far right.
            if not panel_hidden then
                table.insert(m_self.tab_item_table, m_self._zen_tab_item)
            end
            -- Last tab is pushed to far-right by TouchMenuBar's stretch spacer.
            table.insert(m_self.tab_item_table, m_self._zen_home_tab_item)
        end
    end

    local function refresh_zen_menu_tabs(m_self)
        if type(m_self.tab_item_table) ~= "table" or not m_self._zen_home_tab_item then return end
        local panel_hidden = zen_panel_hidden()
        m_self._zen_home_tab_item.icon = library_home_icon()
        if not panel_hidden then
            if not m_self._zen_tab_item then
                m_self._zen_tab_item = make_zen_settings_tab(m_self)
            end
            m_self._zen_tab_item.icon = zen_updater.has_update()
                and "_zen_update_tab" or "_zen_settings_tab"
        end
        remove_zen_menu_tabs(m_self)
        insert_zen_menu_tabs(m_self, panel_hidden)
    end

    local function keep_tab_pair_right(touch_menu)
        local tabs = touch_menu.tab_item_table
        local bar = touch_menu.bar
        local group = bar and bar.bar_icon_group
        local icons = bar and bar.icon_widgets
        local count = type(tabs) == "table" and #tabs or 0
        if count < 2 or type(group) ~= "table" or type(icons) ~= "table" then
            return
        end
        local left_id = tabs[count - 1].id
        local right_id = tabs[count].id
        if not (left_id == "zen_ui" and right_id == "zen_library_home")
                and not (left_id == "app_launcher" and right_id == "quicksettings") then return end

        local left_pos
        local right_pos
        for i, widget in ipairs(group) do
            if widget == icons[count - 1] then
                left_pos = i
            elseif widget == icons[count] then
                right_pos = i
            end
        end
        if not left_pos or right_pos ~= left_pos + 4 then return end

        local stretch = table.remove(group, left_pos + 2)
        local stretch_sep = table.remove(group, left_pos + 2)
        table.insert(group, left_pos, stretch)
        table.insert(group, left_pos + 1, stretch_sep)
        if type(group.resetLayout) == "function" then group:resetLayout() end

        local BD = require("ui/bidi")
        local function sync_tab_borders(tab_index)
            local icon = icons[tab_index]
            local icon_pos
            local start_seg = 0
            for i, widget in ipairs(group) do
                if widget == icon then
                    icon_pos = i
                    break
                end
                start_seg = start_seg + widget:getSize().w
            end
            if not icon_pos then return end

            local end_seg = start_seg + icon:getSize().w
            if BD.mirroredUILayout() then
                start_seg, end_seg = bar.width - end_seg, bar.width - start_seg
            end
            bar.bar_sep.empty_segments = { { s = start_seg, e = end_seg } }

            local before = group[icon_pos - 1]
            local after = group[icon_pos + 1]
            for _i, sep in ipairs(bar.icon_seps) do
                sep.style = (sep == before or sep == after) and "solid" or "none"
            end
        end

        for _i, tab_index in ipairs({ count - 1, count }) do
            local icon = icons[tab_index]
            local orig_callback = icon.callback
            icon.callback = function(...)
                local result = orig_callback(...)
                sync_tab_borders(tab_index)
                return result
            end
        end
        if touch_menu.cur_tab == count - 1 or touch_menu.cur_tab == count then
            sync_tab_borders(touch_menu.cur_tab)
        end
    end

    local TouchMenu = require("ui/widget/touchmenu")
    if not TouchMenu.__zen_right_tabs_patched then
        TouchMenu.__zen_right_tabs_patched = true
        local orig_touch_menu_init = TouchMenu.init
        TouchMenu.init = function(t_self, ...)
            orig_touch_menu_init(t_self, ...)
            keep_tab_pair_right(t_self)
        end
    end

    local function inject_zen_tab(menu_class)
        if not menu_class or menu_class.__zen_ui_tab_patched then return end
        menu_class.__zen_ui_tab_patched = true
        local orig_sut = menu_class.setUpdateItemTable
        menu_class.setUpdateItemTable = function(m_self)
            orig_sut(m_self)
            if type(m_self.tab_item_table) ~= "table" or not _zen_plugin_ref then return end
            -- Remove KOReader's default filebrowser tab; our library tab replaces it.
            for i = #m_self.tab_item_table, 1, -1 do
                if m_self.tab_item_table[i].id == "filemanager" then
                    table.remove(m_self.tab_item_table, i)
                    break
                end
            end
            _zen_menu_instances[m_self] = true
            local _panel_hidden = zen_panel_hidden()
            if not _panel_hidden then
                m_self._zen_tab_item = make_zen_settings_tab(m_self)
            end
            local home_tab = { id = "zen_library_home", icon = library_home_icon(), remember = false }
            home_tab.callback = function()
                local ui = m_self.ui
                local was_tearing_down = ui and ui.tearing_down
                if ui and ui.document then ui.tearing_down = true end
                require("ui/uimanager"):scheduleIn(0, function()
                    local UIManager = require("ui/uimanager")
                    if m_self.menu_container then
                        UIManager:close(m_self.menu_container)
                        m_self.menu_container = nil
                    end
                    if ui and ui.document then ui.tearing_down = was_tearing_down end
                    if not ui then return end
                    if ui.document then
                        library_navigation.showFromReader(ui, _zen_plugin_ref)
                    else
                        local is_default_active = rawget(_G, "__ZEN_UI_NAVBAR_IS_DEFAULT_TAB_ACTIVE")
                        if type(is_default_active) == "function" and is_default_active() then
                            return
                        end
                        local fm = require("apps/filemanager/filemanager").instance
                        if fm then require("common/utils").closeWidgetsAbove(fm) end
                        local open_default = rawget(_G, "__ZEN_UI_NAVBAR_OPEN_DEFAULT_TAB")
                        if type(open_default) == "function" then
                            open_default()
                        else
                            local home_dir = require("common/paths").getHomeDir()
                            if fm and fm.file_chooser and home_dir then
                                fm.file_chooser.path_items[home_dir] = nil
                                fm.file_chooser:changeToPath(home_dir)
                            end
                        end
                    end
                end)
            end
            m_self._zen_home_tab_item = home_tab
            refresh_zen_menu_tabs(m_self)
        end
        -- Refresh the zen tab icon on every menu open so it reflects the
        -- current update state without needing a full tab_item_table rebuild.
        local orig_show = menu_class.onShowMenu
        if type(orig_show) == "function" then
            menu_class.onShowMenu = function(m_self, ...)
                refresh_zen_menu_tabs(m_self)
                return orig_show(m_self, ...)
            end
        end
    end

    local ok_fm, FileManagerMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if ok_fm then inject_zen_tab(FileManagerMenu) end

    local ok_rm, ReaderMenu = pcall(require, "apps/reader/modules/readermenu")
    if ok_rm then inject_zen_tab(ReaderMenu) end

    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- When the background check finds a new update, refresh the zen-tab icon
    -- on every known menu instance. We update the icon in place rather than
    -- forcing setUpdateItemTable to re-run, because KOReader's MenuSorter
    -- mutates self.menu_items during sorting (it nils out KOMenu:menu_buttons
    -- and every consumed leaf), so a second pass crashes in menusorter.lua at
    -- `ipairs(menu_table["KOMenu:menu_buttons"])`. The onShowMenu patch above
    -- also refreshes the icon, so this is just for the case where a menu
    -- instance already exists when the background check finishes.
    local update_icon = function()
        local icon = zen_updater.has_update() and "_zen_update_tab" or "_zen_settings_tab"
        for m_instance in pairs(_zen_menu_instances) do
            if m_instance._zen_tab_item then
                m_instance._zen_tab_item.icon = icon
            end
        end
    end
    zen_updater._on_update_found = update_icon

    -- Trigger background update check on fresh startup too, not only on resume.
    zen_updater.schedule_wakeup_check()

    -- Signal that ZenOS is loaded while retaining the legacy integration event.
    do
        local ok_um, UIManager = pcall(require, "ui/uimanager")
        local ok_ev, Event = pcall(require, "ui/event")
        if ok_um and ok_ev then
            UIManager:broadcastEvent(Event:new("ZenUIReady"))
            UIManager:broadcastEvent(Event:new("ZenOSReady"))
        end
    end
end

-- addToMainMenu is a no-op; tab injection is done via the FileManagerMenu patch.
function ZenUI:addToMainMenu(menu_items) -- luacheck: ignore
end

-- On resume: schedule a background update check (if due + network up).
-- Also called from init() so a fresh KOReader start triggers the same check.
function ZenUI:onResume()
    if self._zenos_brand_inert then return end
    zen_updater.schedule_wakeup_check()
    local ok_incognito, Incognito = pcall(require, "modules/global/patches/incognito_mode")
    if ok_incognito and type(Incognito.onResume) == "function" then
        Incognito.onResume(self)
    end
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(0.5, function()
        refresh_home_date_dependent(self)
    end)
    UIManager:scheduleIn(1.5, function()
        refresh_home_date_dependent(self)
    end)
end

local function invalidate_annotation_quotes(plugin)
    local ok_quotes, HomeQuotes = pcall(
        require, "modules/filebrowser/patches/home/home_quotes"
    )
    if ok_quotes and HomeQuotes and HomeQuotes.invalidateAnnotations then
        HomeQuotes.invalidateAnnotations()
    end
    refresh_home_date_dependent(plugin)
end

function ZenUI:onAnnotationsModified()
    if self._zenos_brand_inert then return end
    invalidate_annotation_quotes(self)
end

function ZenUI:onBookMetadataChanged()
    if self._zenos_brand_inert then return end
    pcall(function() require("common/tbr_index").invalidateStatusCache() end)
    local home = self._zen_shared and self._zen_shared.home
    if home and type(home.invalidateTBRCache) == "function" then
        home.invalidateTBRCache()
    end
end

function ZenUI:onCloseDocument()
    if self._zenos_brand_inert then return end
    invalidate_annotation_quotes(self)
end

-- On suspend: cancel the pending timer so checks don't run while asleep.
function ZenUI:onSuspend()
    if self._zenos_brand_inert then return end
    zen_updater.cancel_wakeup_check()
    local ok_incognito, Incognito = pcall(require, "modules/global/patches/incognito_mode")
    if ok_incognito and type(Incognito.onSuspend) == "function" then
        Incognito.onSuspend()
    end
end

local function close_zen_standalone_views(shared)
    if type(shared) ~= "table" then return end
    for _i, key in ipairs({ "group_view", "home" }) do
        local view = shared[key]
        if view and type(view.closeAll) == "function" then
            local ok, err = pcall(view.closeAll)
            if not ok then
                logger.warn("failed to close standalone view", key, err)
            end
        end
    end
end

local function cancel_item_table_cache_persist()
    local ok, FileChooser = pcall(require, "ui/widget/filechooser")
    if ok and FileChooser
            and type(FileChooser._zen_cancel_item_table_cache_persist) == "function" then
        FileChooser:_zen_cancel_item_table_cache_persist()
    end
end

function ZenUI:onCloseWidget()
    if self._zenos_brand_inert then return end
    cancel_item_table_cache_persist()
    close_zen_standalone_views(self._zen_shared)
end

-- KOReader PluginLoader calls this only when the user explicitly chooses
-- the "delete plugin settings" action during disable/uninstall.
function ZenUI:deletePluginSettings()
    zen_updater.cancel_wakeup_check()
    zen_updater._on_update_found = nil
    cancel_item_table_cache_persist()

    pcall(BrandMigration.deletePluginSettings)

    logger.info("deletePluginSettings completed")
    return true
end

return ZenUI
