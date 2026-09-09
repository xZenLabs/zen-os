-- settings/sections/global.lua
-- Global / device-wide settings: schedules and sleep screen.
-- Receives ctx: { plugin, config, save_and_apply }

local _ = require("gettext")
local UIManager = require("ui/uimanager")
local Device = require("device")
local ConfirmBox = require("ui/widget/confirmbox")
local restart = require("common/restart")
local PresetStore = require("config/preset_store")
local utils = require("modules/settings/zen_settings_utils")
local icons = require("common/inline_icon_map")
local IconItem = require("common/ui/icon_menu_item")

-- Disables the built-in autowarmth plugin if it's running, then prompts restart.
-- Uses the same dialog style as incompatible_plugins_check.
local function disable_autowarmth()
    if not package.loaded["suntime"] then return end
    if not G_reader_settings then return end
    local disabled_list = G_reader_settings:readSetting("plugins_disabled")
    if type(disabled_list) ~= "table" then disabled_list = {} end
    if disabled_list["autowarmth"] ~= nil then return end  -- already disabled
    -- Resolve plugin dir from the sentinel module's source path.
    local dir
    local mod = package.loaded["suntime"]
    if type(mod) == "table" then
        for _k, v in pairs(mod) do
            if type(v) == "function" then
                local info = debug.getinfo(v, "S")
                local src = info and info.source
                if src and src:sub(1, 1) == "@" then
                    local d = src:sub(2):match("^(.*)/[^/]+%.lua$")
                    if d then dir = d .. "/" end
                end
                break
            end
        end
    end
    disabled_list["autowarmth"] = dir or "autowarmth"
    G_reader_settings:saveSetting("plugins_disabled", disabled_list)
    G_reader_settings:flush()
    UIManager:scheduleIn(0.5, function()
        UIManager:show(ConfirmBox:new{
            text         = _("Incompatible plugins have been disabled:") .. "\nAuto warmth and night mode",
            dismissable  = false,
            no_ok_button = true,
            cancel_text  = _("Restart now"),
            cancel_callback = function()
                restart.request()
            end,
        })
    end)
end

local M = {}

local function choose_sleep_screen_image()
    local images_dir = require("datastorage"):getFullDataDir() .. "/resources/screensavers"
    local current_path = G_reader_settings:readSetting("screensaver_document_cover")
    local path = images_dir
    if type(current_path) == "string" and current_path ~= "" then
        local current_dir = select(1, require("util").splitFilePathName(current_path))
        if current_dir ~= "" then path = current_dir end
    end
    local PathChooser = require("ui/widget/pathchooser")
    UIManager:show(PathChooser:new{
        select_directory = false,
        select_file = true,
        show_files = true,
        file_filter = function(filename)
            return require("document/documentregistry"):hasProvider(filename)
        end,
        path = path,
        goHome = function(chooser)
            chooser:changeToPath(images_dir)
            return true
        end,
        onConfirm = function(file_path)
            G_reader_settings:saveSetting("screensaver_document_cover", file_path)
        end,
    })
end

local function install_sleep_screen_image_picker(items)
    local stock_callback = require("ui/screensaver").chooseFile
    local function replace(item_table)
        for _i, item in ipairs(item_table) do
            if type(item) == "table" then
                if item.callback == stock_callback then
                    item.callback = choose_sleep_screen_image
                    return true
                end
                if type(item.sub_item_table) == "table" and replace(item.sub_item_table) then
                    return true
                end
            end
        end
        return false
    end
    replace(items)
end

function M.build(ctx)
    local config = ctx.config
    local plugin = ctx.plugin

    local function mode_value_label(mode, setting)
        return mode .. " " .. setting:lower()
    end

    local function mode_pair_label(setting)
        return _("Light mode") .. " / " .. _("Dark mode") .. " " .. setting:lower()
    end

    -- -------------------------------------------------------------------------
    -- Schedule helpers
    -- -------------------------------------------------------------------------

    local function get_night_schedule_config()
        if type(config.night_mode_schedule) ~= "table" then
            config.night_mode_schedule = {}
        end
        local cfg = config.night_mode_schedule
        return {
            night_on_h  = tonumber(cfg.night_on_h)  or 22,
            night_on_m  = tonumber(cfg.night_on_m)  or 0,
            night_off_h = tonumber(cfg.night_off_h) or 7,
            night_off_m = tonumber(cfg.night_off_m) or 0,
        }
    end

    local function trigger_night_schedule_reschedule()
        local sched = rawget(_G, "__ZEN_UI_NIGHT_SCHEDULE")
        if sched and type(sched.reschedule) == "function" then
            sched.reschedule()
        end
    end

    local function get_warmth_schedule_config()
        if type(config.warmth_schedule) ~= "table" then
            config.warmth_schedule = {}
        end
        local cfg = config.warmth_schedule
        return {
            day_h       = tonumber(cfg.day_h)       or 7,
            day_m       = tonumber(cfg.day_m)       or 0,
            day_value   = tonumber(cfg.day_value)   or 3,
            night_h     = tonumber(cfg.night_h)     or 20,
            night_m     = tonumber(cfg.night_m)     or 0,
            night_value = tonumber(cfg.night_value) or 8,
            use_mode_values = cfg.use_mode_values == true,
        }
    end

    local function trigger_warmth_schedule_reschedule()
        local sched = rawget(_G, "__ZEN_UI_WARMTH_SCHEDULE")
        if sched and type(sched.reschedule) == "function" then
            sched.reschedule()
        end
    end

    local function get_brightness_schedule_config()
        if type(config.brightness_schedule) ~= "table" then
            config.brightness_schedule = {}
        end
        local cfg = config.brightness_schedule
        return {
            day_h       = tonumber(cfg.day_h)       or 7,
            day_m       = tonumber(cfg.day_m)       or 0,
            day_value   = tonumber(cfg.day_value)   or 20,
            night_h     = tonumber(cfg.night_h)     or 20,
            night_m     = tonumber(cfg.night_m)     or 0,
            night_value = tonumber(cfg.night_value) or 5,
            use_mode_values = cfg.use_mode_values == true,
        }
    end

    local function trigger_brightness_schedule_reschedule()
        local sched = rawget(_G, "__ZEN_UI_BRIGHTNESS_SCHEDULE")
        if sched and type(sched.reschedule) == "function" then
            sched.reschedule()
        end
    end

    -- -------------------------------------------------------------------------
    -- Sleep screen helpers
    -- -------------------------------------------------------------------------

    local _icons_dir
    do
        local root = require("common/plugin_root")
        if root then
            local lfs = require("libs/libkoreader-lfs")
            if lfs.attributes(root .. "/icons/zen_ui.svg", "mode") == "file" then
                _icons_dir = root .. "/icons/"
            end
        end
    end

    local builtin_presets = {}
    if _icons_dir then
        local ok_bp, bp_mod = pcall(require, "config/screensaver_presets")
        if ok_bp and bp_mod and type(bp_mod.get) == "function" then
            builtin_presets = bp_mod.get(_icons_dir)
        end
    end

    local function get_all_presets()
        local user = PresetStore.list("screensaver")
        local all = {}
        for _i, p in ipairs(builtin_presets) do table.insert(all, p) end
        for _i, p in ipairs(user) do table.insert(all, p) end
        return all
    end

    local function capture_sleep_screen_state()
        return {
            screensaver_type = G_reader_settings:readSetting("screensaver_type"),
            screensaver_message = G_reader_settings:readSetting("screensaver_message"),
            screensaver_show_message = G_reader_settings:isTrue("screensaver_show_message"),
            screensaver_img_background = G_reader_settings:readSetting("screensaver_img_background"),
            screensaver_document_cover = G_reader_settings:readSetting("screensaver_document_cover"),
            screensaver_stretch_images = G_reader_settings:isTrue("screensaver_stretch_images"),
            screensaver_stretch_limit_percentage = G_reader_settings:readSetting("screensaver_stretch_limit_percentage"),
        }
    end

    local function apply_sleep_screen_preset(preset)
        if type(preset) ~= "table" then return end
        if preset.screensaver_type then
            G_reader_settings:saveSetting("screensaver_type", preset.screensaver_type)
        end
        if preset.screensaver_message ~= nil then
            G_reader_settings:saveSetting("screensaver_message", preset.screensaver_message)
        end
        if preset.screensaver_show_message ~= nil then
            if preset.screensaver_show_message then
                G_reader_settings:makeTrue("screensaver_show_message")
            else
                G_reader_settings:makeFalse("screensaver_show_message")
            end
        end
        if preset.screensaver_img_background then
            G_reader_settings:saveSetting("screensaver_img_background", preset.screensaver_img_background)
        end
        if preset.screensaver_document_cover ~= nil then
            G_reader_settings:saveSetting("screensaver_document_cover", preset.screensaver_document_cover)
        end
        -- "cover" type uses the last book; stale document_cover paths are irrelevant.
        if preset.screensaver_type == "cover" then
            G_reader_settings:delSetting("screensaver_document_cover")
        end
        if preset.screensaver_stretch_images ~= nil then
            if preset.screensaver_stretch_images then
                G_reader_settings:makeTrue("screensaver_stretch_images")
            else
                G_reader_settings:makeFalse("screensaver_stretch_images")
            end
        end
        if preset.screensaver_stretch_limit_percentage ~= nil then
            G_reader_settings:saveSetting(
                "screensaver_stretch_limit_percentage",
                preset.screensaver_stretch_limit_percentage)
        end
        PresetStore.saveSettings("screensaver", capture_sleep_screen_state())
    end

    local function build_preset_items()
        local all = get_all_presets()
        local preset_items = {}

        table.insert(preset_items, {
            text = _("Save current settings as preset"),
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local InputDialog = require("ui/widget/inputdialog")
                local dlg
                dlg = InputDialog:new{
                    title = _("Preset name"),
                    input = "",
                    buttons = {{
                        {
                            text = _("Cancel"),
                            id = "close",
                            callback = function() UIManager:close(dlg) end,
                        },
                        {
                            text = _("Save"),
                            is_enter_default = true,
                            callback = function()
                                local name = dlg:getInputText()
                                if not name or name:match("^%s*$") then return end
                                name = name:match("^%s*(.-)%s*$")
                                UIManager:close(dlg)
                                local state = capture_sleep_screen_state()
                                PresetStore.save("screensaver", name, state)
                                PresetStore.saveSettings("screensaver", state)
                                PresetStore.setActivePreset("screensaver", name)
                                if touchmenu_instance then
                                    touchmenu_instance.item_table = build_preset_items()
                                    touchmenu_instance:updateItems()
                                end
                            end,
                        },
                    }},
                }
                UIManager:show(dlg)
                dlg:onShowKeyboard()
            end,
            separator = #all > 0,
        })

        for i, preset in ipairs(all) do
            local pname = preset.name
            local is_builtin = preset.builtin == true
            local is_last = (i == #all)
            table.insert(preset_items, {
                text_func = function()
                    local active = PresetStore.getActivePreset("screensaver")
                    local prefix = (active == pname) and "\u{2713} " or ""
                    return prefix .. pname
                end,
                callback = function(touchmenu_instance)
                    apply_sleep_screen_preset(preset)
                    PresetStore.setActivePreset("screensaver", pname)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
                hold_callback = not is_builtin and function(touchmenu_instance)
                    UIManager:show(ConfirmBox:new{
                        text = _("Delete preset?") .. "\n\n" .. pname,
                        ok_text = _("Delete"),
                        ok_callback = function()
                            PresetStore.delete("screensaver", pname)
                            if PresetStore.getActivePreset("screensaver") == pname then
                                PresetStore.setActivePreset("screensaver", nil)
                            end
                            if touchmenu_instance then
                                touchmenu_instance.item_table = build_preset_items()
                                touchmenu_instance:updateItems()
                            end
                        end,
                    })
                end or nil,
                separator = is_last
                    or (is_builtin and all[i + 1] ~= nil and not all[i + 1].builtin),
            })
        end

        return preset_items
    end

    -- -------------------------------------------------------------------------
    -- Build items
    -- -------------------------------------------------------------------------

    local items = {}

    -- Search section
    table.insert(items, {
        text = _("Search"),
        sub_item_table = {
            {
                text = _("Match whole words"),
                help_text = _("When enabled, search matches whole words only. When disabled, substring matching is used (e.g., 'fish' matches 'fishing')."),
                checked_func = function()
                    return type(config.search) == "table" and config.search.substring == false
                end,
                callback = function()
                    if type(config.search) ~= "table" then config.search = {} end
                    config.search.substring = config.search.substring == false
                    plugin:saveConfig()
                end,
            },
        },
    })

    -- Night mode schedule
    table.insert(items, {
        text = _("Night mode schedule"),
        sub_item_table = {
            {
                text = _("Enable night mode schedule"),
                checked_func = function()
                    return config.features.night_mode_schedule == true
                end,
                callback = function()
                    config.features.night_mode_schedule =
                        config.features.night_mode_schedule ~= true
                    plugin:saveConfig()
                    trigger_night_schedule_reschedule()
                    if config.features.night_mode_schedule then
                        disable_autowarmth()
                    end
                end,
            },
            {
                text_func = function()
                    local cfg = get_night_schedule_config()
                    return _("Night mode on: ") .. utils.fmt_time(cfg.night_on_h, cfg.night_on_m)
                end,
                enabled_func = function()
                    return config.features.night_mode_schedule == true
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local cfg = get_night_schedule_config()
                    utils.show_time_picker(_("Night mode on time"),
                        cfg.night_on_h, cfg.night_on_m,
                        function(h, m)
                            if type(config.night_mode_schedule) ~= "table" then
                                config.night_mode_schedule = {}
                            end
                            config.night_mode_schedule.night_on_h = h
                            config.night_mode_schedule.night_on_m = m
                            plugin:saveConfig()
                            trigger_night_schedule_reschedule()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end)
                end,
            },
            {
                text_func = function()
                    local cfg = get_night_schedule_config()
                    return _("Night mode off: ") .. utils.fmt_time(cfg.night_off_h, cfg.night_off_m)
                end,
                enabled_func = function()
                    return config.features.night_mode_schedule == true
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local cfg = get_night_schedule_config()
                    utils.show_time_picker(_("Night mode off time"),
                        cfg.night_off_h, cfg.night_off_m,
                        function(h, m)
                            if type(config.night_mode_schedule) ~= "table" then
                                config.night_mode_schedule = {}
                            end
                            config.night_mode_schedule.night_off_h = h
                            config.night_mode_schedule.night_off_m = m
                            plugin:saveConfig()
                            trigger_night_schedule_reschedule()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end)
                end,
            },
        },
    })

    -- Brightness
    table.insert(items, {
        text = _("Brightness"),
        sub_item_table = {
            {
                text = _("Enable brightness schedule"),
                checked_func = function()
                    return config.features.brightness_schedule == true
                end,
                callback = function()
                    config.features.brightness_schedule =
                        config.features.brightness_schedule ~= true
                    get_brightness_schedule_config()
                    config.brightness_schedule.use_mode_values = false
                    plugin:saveConfig()
                    trigger_brightness_schedule_reschedule()
                    if config.features.brightness_schedule then
                        disable_autowarmth()
                    end
                end,
            },
            {
                text = mode_pair_label(_("Brightness")),
                checked_func = function()
                    return get_brightness_schedule_config().use_mode_values
                end,
                callback = function()
                    local cfg = get_brightness_schedule_config()
                    config.brightness_schedule.use_mode_values = not cfg.use_mode_values
                    if config.brightness_schedule.use_mode_values then
                        config.features.brightness_schedule = false
                    end
                    plugin:saveConfig()
                    trigger_brightness_schedule_reschedule()
                    if config.brightness_schedule.use_mode_values then
                        disable_autowarmth()
                    end
                end,
            },
            {
                text_func = function()
                    local cfg = get_brightness_schedule_config()
                    return _("Day brightness time: ") .. utils.fmt_time(cfg.day_h, cfg.day_m)
                end,
                enabled_func = function()
                    return config.features.brightness_schedule == true
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local cfg = get_brightness_schedule_config()
                    utils.show_time_picker(_("Day brightness time"), cfg.day_h, cfg.day_m,
                        function(h, m)
                            if type(config.brightness_schedule) ~= "table" then
                                config.brightness_schedule = {}
                            end
                            config.brightness_schedule.day_h = h
                            config.brightness_schedule.day_m = m
                            plugin:saveConfig()
                            trigger_brightness_schedule_reschedule()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end)
                end,
            },
            {
                text_func = function()
                    local cfg = get_brightness_schedule_config()
                    if config.features.brightness_schedule == true then
                        return _("Day brightness: ") .. cfg.day_value
                    end
                    return mode_value_label(_("Light mode"), _("Brightness"))
                        .. ": " .. cfg.day_value
                end,
                enabled_func = function()
                    local cfg = get_brightness_schedule_config()
                    return config.features.brightness_schedule == true or cfg.use_mode_values
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local cfg = get_brightness_schedule_config()
                    local powerd = Device.powerd
                    local title = config.features.brightness_schedule == true
                        and _("Day brightness")
                        or mode_value_label(_("Light mode"), _("Brightness"))
                    utils.show_value_picker(title, cfg.day_value,
                        function(v)
                            if type(config.brightness_schedule) ~= "table" then
                                config.brightness_schedule = {}
                            end
                            config.brightness_schedule.day_value = v
                            plugin:saveConfig()
                            trigger_brightness_schedule_reschedule()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end, 0, powerd.fl_max)
                end,
            },
            {
                text_func = function()
                    local cfg = get_brightness_schedule_config()
                    return _("Night brightness time: ") .. utils.fmt_time(cfg.night_h, cfg.night_m)
                end,
                enabled_func = function()
                    return config.features.brightness_schedule == true
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local cfg = get_brightness_schedule_config()
                    utils.show_time_picker(_("Night brightness time"), cfg.night_h, cfg.night_m,
                        function(h, m)
                            if type(config.brightness_schedule) ~= "table" then
                                config.brightness_schedule = {}
                            end
                            config.brightness_schedule.night_h = h
                            config.brightness_schedule.night_m = m
                            plugin:saveConfig()
                            trigger_brightness_schedule_reschedule()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end)
                end,
            },
            {
                text_func = function()
                    local cfg = get_brightness_schedule_config()
                    if config.features.brightness_schedule == true then
                        return _("Night brightness: ") .. cfg.night_value
                    end
                    return mode_value_label(_("Dark mode"), _("Brightness"))
                        .. ": " .. cfg.night_value
                end,
                enabled_func = function()
                    local cfg = get_brightness_schedule_config()
                    return config.features.brightness_schedule == true or cfg.use_mode_values
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local cfg = get_brightness_schedule_config()
                    local powerd = Device.powerd
                    local title = config.features.brightness_schedule == true
                        and _("Night brightness")
                        or mode_value_label(_("Dark mode"), _("Brightness"))
                    utils.show_value_picker(title, cfg.night_value,
                        function(v)
                            if type(config.brightness_schedule) ~= "table" then
                                config.brightness_schedule = {}
                            end
                            config.brightness_schedule.night_value = v
                            plugin:saveConfig()
                            trigger_brightness_schedule_reschedule()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end, 0, powerd.fl_max)
                end,
            },
        },
    })

    -- Warmth
    table.insert(items, {
        text = _("Warmth"),
        enabled_func = function() return Device:hasNaturalLight() end,
        sub_item_table = {
            {
                text = _("Enable warmth schedule"),
                checked_func = function()
                    return config.features.warmth_schedule == true
                end,
                callback = function()
                    config.features.warmth_schedule = config.features.warmth_schedule ~= true
                    get_warmth_schedule_config()
                    config.warmth_schedule.use_mode_values = false
                    plugin:saveConfig()
                    trigger_warmth_schedule_reschedule()
                    if config.features.warmth_schedule then
                        disable_autowarmth()
                    end
                end,
            },
            {
                text = mode_pair_label(_("Warmth")),
                checked_func = function()
                    return get_warmth_schedule_config().use_mode_values
                end,
                callback = function()
                    local cfg = get_warmth_schedule_config()
                    config.warmth_schedule.use_mode_values = not cfg.use_mode_values
                    if config.warmth_schedule.use_mode_values then
                        config.features.warmth_schedule = false
                    end
                    plugin:saveConfig()
                    trigger_warmth_schedule_reschedule()
                    if config.warmth_schedule.use_mode_values then
                        disable_autowarmth()
                    end
                end,
            },
            {
                text_func = function()
                    local cfg = get_warmth_schedule_config()
                    return _("Day warmth time: ") .. utils.fmt_time(cfg.day_h, cfg.day_m)
                end,
                enabled_func = function()
                    return config.features.warmth_schedule == true
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local cfg = get_warmth_schedule_config()
                    utils.show_time_picker(_("Day warmth time"), cfg.day_h, cfg.day_m,
                        function(h, m)
                            if type(config.warmth_schedule) ~= "table" then
                                config.warmth_schedule = {}
                            end
                            config.warmth_schedule.day_h = h
                            config.warmth_schedule.day_m = m
                            plugin:saveConfig()
                            trigger_warmth_schedule_reschedule()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end)
                end,
            },
            {
                text_func = function()
                    local cfg = get_warmth_schedule_config()
                    if config.features.warmth_schedule == true then
                        return _("Day warmth: ") .. cfg.day_value
                    end
                    return mode_value_label(_("Light mode"), _("Warmth"))
                        .. ": " .. cfg.day_value
                end,
                enabled_func = function()
                    local cfg = get_warmth_schedule_config()
                    return config.features.warmth_schedule == true or cfg.use_mode_values
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local cfg = get_warmth_schedule_config()
                    local powerd = Device.powerd
                    local title = config.features.warmth_schedule == true
                        and _("Day warmth")
                        or mode_value_label(_("Light mode"), _("Warmth"))
                    utils.show_value_picker(title, cfg.day_value,
                        function(v)
                            if type(config.warmth_schedule) ~= "table" then
                                config.warmth_schedule = {}
                            end
                            config.warmth_schedule.day_value = v
                            plugin:saveConfig()
                            trigger_warmth_schedule_reschedule()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end, powerd.fl_warmth_min, powerd.fl_warmth_max)
                end,
            },
            {
                text_func = function()
                    local cfg = get_warmth_schedule_config()
                    return _("Night warmth time: ") .. utils.fmt_time(cfg.night_h, cfg.night_m)
                end,
                enabled_func = function()
                    return config.features.warmth_schedule == true
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local cfg = get_warmth_schedule_config()
                    utils.show_time_picker(_("Night warmth time"), cfg.night_h, cfg.night_m,
                        function(h, m)
                            if type(config.warmth_schedule) ~= "table" then
                                config.warmth_schedule = {}
                            end
                            config.warmth_schedule.night_h = h
                            config.warmth_schedule.night_m = m
                            plugin:saveConfig()
                            trigger_warmth_schedule_reschedule()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end)
                end,
            },
            {
                text_func = function()
                    local cfg = get_warmth_schedule_config()
                    if config.features.warmth_schedule == true then
                        return _("Night warmth: ") .. cfg.night_value
                    end
                    return mode_value_label(_("Dark mode"), _("Warmth"))
                        .. ": " .. cfg.night_value
                end,
                enabled_func = function()
                    local cfg = get_warmth_schedule_config()
                    return config.features.warmth_schedule == true or cfg.use_mode_values
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    local cfg = get_warmth_schedule_config()
                    local powerd = Device.powerd
                    local title = config.features.warmth_schedule == true
                        and _("Night warmth")
                        or mode_value_label(_("Dark mode"), _("Warmth"))
                    utils.show_value_picker(title, cfg.night_value,
                        function(v)
                            if type(config.warmth_schedule) ~= "table" then
                                config.warmth_schedule = {}
                            end
                            config.warmth_schedule.night_value = v
                            plugin:saveConfig()
                            trigger_warmth_schedule_reschedule()
                            if touchmenu_instance then touchmenu_instance:updateItems() end
                        end, powerd.fl_warmth_min, powerd.fl_warmth_max)
                end,
            },
        },
    })

    -- Sleep
    table.insert(items, {
        text = _("Sleep"),
        enabled_func = function()
            local ok, Dev = pcall(require, "device")
            return ok and Dev and type(Dev.supportsScreensaver) == "function"
                and Dev:supportsScreensaver()
        end,
        sub_item_table_func = function()
            local ok, screen_items = pcall(dofile, "frontend/ui/elements/screensaver_menu.lua")
            local sub = (ok and type(screen_items) == "table") and screen_items or {}
            if ok then install_sleep_screen_image_picker(sub) end
            table.insert(sub, {
                text = _("Presets"),
                sub_item_table_func = build_preset_items,
            })
            -- find current UI instance to access plugin instances
            local ok_r, ReaderUI = pcall(require, "apps/reader/readerui")
            local ok_f, FileManager = pcall(require, "apps/filemanager/filemanager")
            local ui = (ok_r and ReaderUI and ReaderUI.instance)
                     or (ok_f and FileManager and FileManager.instance)
            -- Automatic dimmer (autodim.koplugin)
            if ui and ui.autodim and type(ui.autodim.getAutoDimMenu) == "function" then
                local autodim_item = ui.autodim:getAutoDimMenu()
                if autodim_item then table.insert(sub, autodim_item) end
            end
            -- Automatic suspend (autosuspend.koplugin)
            if ui and ui.autosuspend and type(ui.autosuspend.addToMainMenu) == "function" then
                local menu_items = {}
                ui.autosuspend:addToMainMenu(menu_items)
                local suspend_sub = {}
                for _i, key in ipairs({ "autosuspend", "autoshutdown", "autostandby" }) do
                    if menu_items[key] then table.insert(suspend_sub, menu_items[key]) end
                end
                if #suspend_sub > 0 then
                    table.insert(sub, {
                        text = _("Automatic suspend"),
                        sub_item_table = suspend_sub,
                    })
                end
            end
            return sub
        end,
    })

    -- Lockdown mode
    table.insert(items, {
        text = _("Lockdown mode"),
        sub_item_table = {
            {
                text = _("Magnify UI"),
                checked_func = function()
                    return config.lockdown and config.lockdown.magnify_ui == true
                end,
                callback = function()
                    if type(config.lockdown) ~= "table" then config.lockdown = {} end
                    config.lockdown.magnify_ui = not config.lockdown.magnify_ui
                    plugin:saveConfig()
                end,
            },
            {
                text = _("Library"),
                sub_item_table = {
                    {
                        text = _("Disable context menu"),
                        checked_func = function()
                            return config.lockdown and config.lockdown.disable_context_menu == true
                        end,
                        callback = function()
                            if type(config.lockdown) ~= "table" then config.lockdown = {} end
                            config.lockdown.disable_context_menu = not config.lockdown.disable_context_menu
                            plugin:saveConfig()
                        end,
                    },
                },
            },
            {
                text = _("Controls"),
                sub_item_table = {
                    {
                        text = _("Require hold to toggle buttons"),
                        checked_func = function()
                            return config.lockdown and config.lockdown.require_hold_in_qs == true
                        end,
                        callback = function()
                            if type(config.lockdown) ~= "table" then config.lockdown = {} end
                            config.lockdown.require_hold_in_qs = not config.lockdown.require_hold_in_qs
                            plugin:saveConfig()
                        end,
                    },
                    {
                        text = _("Disable settings panel"),
                        checked_func = function()
                            return config.lockdown and config.lockdown.disable_settings_panel == true
                        end,
                        callback = function()
                            if type(config.lockdown) ~= "table" then config.lockdown = {} end
                            config.lockdown.disable_settings_panel = not config.lockdown.disable_settings_panel
                            plugin:saveConfig()
                        end,
                    },
                },
            },
            {
                text = _("Reader"),
                sub_item_table = {
                    {
                        text = _("Disable bottom menu swipe"),
                        checked_func = function()
                            return config.lockdown and config.lockdown.disable_bottom_menu_swipe == true
                        end,
                        callback = function()
                            if type(config.lockdown) ~= "table" then config.lockdown = {} end
                            config.lockdown.disable_bottom_menu_swipe = not config.lockdown.disable_bottom_menu_swipe
                            plugin:saveConfig()
                        end,
                    },
                    {
                        text = _("Disable multi-word selection"),
                        checked_func = function()
                            return config.lockdown and config.lockdown.disable_word_selection == true
                        end,
                        callback = function()
                            if type(config.lockdown) ~= "table" then config.lockdown = {} end
                            config.lockdown.disable_word_selection = not config.lockdown.disable_word_selection
                            plugin:saveConfig()
                        end,
                    },
                    {
                        text = _("Disable word search on hold"),
                        checked_func = function()
                            return config.lockdown and config.lockdown.disable_hold_search == true
                        end,
                        callback = function()
                            if type(config.lockdown) ~= "table" then config.lockdown = {} end
                            config.lockdown.disable_hold_search = not config.lockdown.disable_hold_search
                            plugin:saveConfig()
                        end,
                    },
                },
            },
        },
    })

    return items
end

function M.build_extras_items(ctx)
    local global_items = M.build(ctx)
    local search_item = global_items[1]
    local night_schedule_item = global_items[2]
    local brightness_schedule_item = global_items[3]
    local warmth_schedule_item = global_items[4]
    local sleep_item = global_items[5]
    local lockdown_item = global_items[6]

    IconItem.decorate(night_schedule_item, icons.schedule_night)
    IconItem.decorate(brightness_schedule_item, icons.schedule_brightness)
    IconItem.decorate(warmth_schedule_item, icons.schedule_warmth)
    IconItem.decorate(sleep_item, icons.settings_sleep)

    local items = {
        search_item,
        {
            text = _("Schedules"),
            sub_item_table = {
                brightness_schedule_item,
                night_schedule_item,
                warmth_schedule_item,
            },
        },
        sleep_item,
        lockdown_item,
    }
    IconItem.decorate(items[1], icons.search)
    IconItem.decorate(items[2], icons.tbr)
    IconItem.decorate(items[4], icons.settings_lockdown)
    return items
end

return M
