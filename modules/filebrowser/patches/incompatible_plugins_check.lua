-- incompatible_plugins_check.lua
-- Detects incompatible plugins and user patches.
-- Two categories:
--   MANUAL_BLOCK  -- ZenOS cannot auto-fix these. User is informed and init is halted.
--   AUTO_DISABLE  -- ZenOS disables plugins/patches and prompts restart.

-- Returns the plugin directory for an already-loaded sentinel module.
local function get_dir_from_loaded(sentinel)
    local mod = package.loaded[sentinel]
    if not mod then return nil end
    local src
    if type(mod) == "table" then
        for _k, v in pairs(mod) do
            if type(v) == "function" then
                local info = debug.getinfo(v, "S")
                src = info and info.source
                break
            end
        end
    elseif type(mod) == "function" then
        local info = debug.getinfo(mod, "S")
        src = info and info.source
    end
    if src and src:sub(1, 1) == "@" then
        local dir = src:sub(2):match("^(.*)/[^/]+%.lua$")
        return dir and (dir .. "/")
    end
end

-- e.g. "/path/to/appearance.koplugin/lib/" -> "appearance"
local function get_folder_key(dir)
    if not dir then return nil end
    return dir:match("^.*/([^/]+)%.koplugin/")
end

local function plugin_folder_exists(folder_key)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return false end

    local paths = { "plugins" }
    local extra_paths = G_reader_settings:readSetting("extra_plugin_paths")
    if type(extra_paths) == "string" then extra_paths = { extra_paths } end
    if type(extra_paths) == "table" then
        for _i, path in ipairs(extra_paths) do
            paths[#paths + 1] = path
        end
    end

    for _i, path in ipairs(paths) do
        if type(path) == "string" then
            path = path:gsub("/+$", "")
            if lfs.attributes(path .. "/" .. folder_key .. ".koplugin", "mode") == "directory" then
                return true
            end
        end
    end
    return false
end

local function any_zen_frontlight_automation_enabled()
    local plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    local features = plugin and plugin.config and plugin.config.features
    if type(features) ~= "table" then return false end
    local config = plugin.config
    local brightness = config and config.brightness_schedule
    local warmth = config and config.warmth_schedule
    return features.brightness_schedule == true
        or features.warmth_schedule     == true
        or features.night_mode_schedule == true
        or type(brightness) == "table" and brightness.use_mode_values == true
        or type(warmth) == "table" and warmth.use_mode_values == true
end

-- Project: Title loads this unique module before checking its requirements,
-- including when it self-disables because CoverBrowser is enabled.
local function is_pt_detected()
    return package.loaded["ptutil"] ~= nil
end

-- Plugins that ZenOS will auto-disable (writes plugins_disabled, requires restart).
local AUTO_DISABLE = {
    {
        sentinel = "sui_core",
        label = "Simple UI",
        fallback_key = "simpleui",
        folder_key = "simpleui",
    },
    {
        sentinel = "modules/vos",
        label = "Visual Overhaul Suite (VOS)",
        fallback_key = "vos",
        folder_key = "vos",
    },
    {
        sentinel = "quickmenu",
        label = "QuickMenu",
        fallback_key = "quickmenu",
        folder_key = "quickmenu",
    },
    {
        sentinel = "lib/setting",
        label = "Appearance",
        fallback_key = "appearance",
        folder_key = "appearance",
        expected_folder_key = "appearance",
    },
    {
        sentinel = "burrow_util",
        label = "Burrow",
        fallback_key = "burrow",
        folder_key = "burrow",
    },
    {
        sentinel = "qui_utils",
        label = "QuickUI",
        fallback_key = "quickui",
        folder_key = "quickui",
    },
    {
        sentinel = "readermenuredesign_installer",
        label = "Reader Menu Redesign",
        fallback_key = "zzz-readermenuredesign",
        folder_key = "zzz-readermenuredesign",
    },
}

local AUTO_DISABLE_PATCHES = {
    "2---stretched-covers.lua",
    "2--disable-all-CB-widgets.lua",
    "2--disable-all-PT-widgets.lua",
    "2--rounded-covers.lua",
    "2--stretched-rounded-covers.lua",
    "2-navbar-vos.lua",
    "2-new-collections-star.lua",
    "2-new-progress-bar-colored.lua",
    "2-new-progress-bar.lua",
    "2-pages-badge.lua",
    "2-percent-badge.lua",
    "2-rounded-folder-covers.lua",
    "2-series-indicator.lua",
    "20-faded-finished-books.lua",
    "2-quick-settings.lua",
    "2-automatic-book-series.lua",
    "2-ui-font.lua",
    "2-custom-navbar.lua",
    "2-page-scrubber.lua",
    "2-browser-double-tap.lua",
    "2-browser-hide-underline.lua",
    "2-browser-up-folder.lua",
    "2-coverimage-eink-optimize.lua",
    "2-disable-top-menu-zones.lua",
    "2-filemanager-titlebar.lua",
    "2-menu-size.lua",
    "2-new-status-icons.lua",
    "2-screensaver-chapter.lua",
    "2-screensaver-cover.lua",
    "2-series-badge-numbered.lua",
    "2-statusbar-better-compact.lua",
    "2-statusbar-cycle-presets.lua",
}

local function apply_incompatible_plugins_check()
    local logger = require("common/zen_logger").new("incompatible_plugins_check")

    -- Manual-block check: inform user and halt init without touching anything.
    if is_pt_detected() then
        logger.warn("Incompatible plugins or patches detected")
        local UIManager = require("ui/uimanager")
        UIManager:scheduleIn(0.5, function()
            local _ = require("gettext")
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = _("Project: Title is not compatible with ZenOS.")
                    .. "\n\n" .. _("Please delete the Project: Title plugin from your plugins folder and restart KOReader."),
                show_icon = false,
            })
        end)
        return true
    end
    if not G_reader_settings then
        logger.warn("Incompatible plugin check could not run")
        return false
    end

    local disabled_list = G_reader_settings:readSetting("plugins_disabled")
    if type(disabled_list) ~= "table" then disabled_list = {} end

    local needs_restart = false
    local incompatibility_detected = false
    local disabled_labels = {}

    for _i, entry in ipairs(AUTO_DISABLE) do
        local sentinel_loaded = package.loaded[entry.sentinel] ~= nil
        local folder_installed = entry.folder_key and plugin_folder_exists(entry.folder_key)
        local folder_enabled = folder_installed and disabled_list[entry.folder_key] == nil
        if sentinel_loaded or folder_enabled then
            local dir = get_dir_from_loaded(entry.sentinel)
            local folder_key = folder_enabled and entry.folder_key or get_folder_key(dir)
            if entry.expected_folder_key and folder_key ~= entry.expected_folder_key then
                logger.dbg("Compatibility state", entry.label,
                    "| loaded=false | source=" .. tostring(dir))
            else
                incompatibility_detected = true
                folder_key = folder_key or entry.folder_key or entry.fallback_key
                local already_disabled = disabled_list[folder_key] ~= nil
                logger.dbg("Compatibility state", entry.label,
                    "| loaded=" .. tostring(sentinel_loaded),
                    "| installed=" .. tostring(folder_installed),
                    "| folder_key=" .. tostring(folder_key),
                    "| already_disabled=" .. tostring(already_disabled))
                if already_disabled then
                    -- In disabled_list but still loaded: bad state, force restart.
                    logger.dbg(entry.label, "is disabled but still loaded; forcing restart")
                    disabled_labels[#disabled_labels + 1] = entry.label
                    needs_restart = true
                else
                    logger.dbg("Disabling", entry.label, "| key=" .. folder_key)
                    disabled_list[folder_key] = true
                    disabled_labels[#disabled_labels + 1] = entry.label
                    needs_restart = true
                end
            end
        end
    end

    local ok_userpatch, userpatch = pcall(require, "userpatch")
    local execution_status = ok_userpatch and userpatch and userpatch.execution_status
    if type(execution_status) == "table" then
        local patches_enabled = type(userpatch.arePatchesDisabled) ~= "function"
            or not userpatch.arePatchesDisabled()
        local patch_dir = require("datastorage"):getDataDir() .. "/patches"
        local lfs = require("libs/libkoreader-lfs")
        for _i, filename in ipairs(AUTO_DISABLE_PATCHES) do
            local source = patch_dir .. "/" .. filename
            local installed_and_enabled = patches_enabled
                and lfs.attributes(source, "mode") == "file"
            if execution_status[filename] ~= nil or installed_and_enabled then
                incompatibility_detected = true
                if os.rename(source, source .. ".disabled") then
                    logger.dbg("Disabling incompatible user patch", filename)
                    disabled_labels[#disabled_labels + 1] = filename
                    needs_restart = true
                else
                    logger.dbg("Unable to disable incompatible user patch", filename)
                end
            end
        end
    end

    -- Disable autowarmth when Zen controls a schedule or mode value (they conflict).
    if package.loaded["suntime"] ~= nil and disabled_list["autowarmth"] == nil
            and any_zen_frontlight_automation_enabled() then
        incompatibility_detected = true
        local dir = get_dir_from_loaded("suntime")
        local folder_key = get_folder_key(dir) or "autowarmth"
        logger.dbg("Disabling autowarmth | key=" .. folder_key)
        disabled_list[folder_key] = true
        disabled_labels[#disabled_labels + 1] = "Auto warmth and night mode"
        needs_restart = true
    end

    if incompatibility_detected then
        logger.warn("Incompatible plugins or patches detected")
    else
        logger.info("No incompatible plugins or patches detected")
    end

    if not needs_restart then return false end

    G_reader_settings:saveSetting("plugins_disabled", disabled_list)
    G_reader_settings:flush()

    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(0.5, function()
        local _ = require("gettext")
        local ConfirmBox = require("ui/widget/confirmbox")
        local Event = require("ui/event")
        UIManager:show(ConfirmBox:new{
            text         = _("Incompatible plugins and patches have been disabled:") .. "\n" .. table.concat(disabled_labels, "\n"),
            dismissable  = false,
            no_ok_button = true,
            cancel_text  = _("Restart now"),
            cancel_callback = function()
                UIManager:broadcastEvent(Event:new("Restart"))
            end,
        })
    end)
    return true
end

return apply_incompatible_plugins_check
