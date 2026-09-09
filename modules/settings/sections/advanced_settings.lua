-- settings/sections/advanced.lua
-- Advanced / developer settings items for ZenOS.
-- Receives ctx: { plugin, config, save_and_apply, settings_apply }

local _ = require("gettext")
local UIManager = require("ui/uimanager")
local utils = require("modules/settings/zen_settings_utils")
local paths = require("common/paths")

local M = {}

function M.build(ctx)
    local config = ctx.config
    local plugin = ctx.plugin
    local settings_apply = ctx.settings_apply

    local items = {}

    table.insert(items, {
        text = _("Extract metadata"),
        help_text = _("Extract and cache book metadata and cover images for books in the current directory. Requires CoverBrowser plugin."),
        callback = function()
            local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
            if not ok_bim or not BookInfoManager then return end
            local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
            local fc = ok_fm and FileManager and FileManager.instance
                and FileManager.instance.file_chooser
            if not fc then return end
            local Trapper = require("ui/trapper")
            Trapper:wrap(function()
                BookInfoManager:extractBooksInDirectory(fc.path, fc.cover_specs)
            end)
        end,
        keep_menu_open = true,
    })

    table.insert(items, {
        text = _("Partial pages refresh"),
        checked_func = function()
            return config.features.partial_page_repaint == true
        end,
        callback = function()
            config.features.partial_page_repaint = config.features.partial_page_repaint ~= true
            plugin:saveConfig()
            settings_apply.prompt_restart()
        end,
    })

    table.insert(items, {
        text = _("Require double tap to open books"),
        help_text = _("When enabled, tap the same book twice in rapid succession to open it. Keyboard controls are unchanged."),
        checked_func = function()
            return type(config.developer) == "table"
                and config.developer.double_tap_to_open_books == true
        end,
        callback = function()
            if type(config.developer) ~= "table" then config.developer = {} end
            config.developer.double_tap_to_open_books =
                config.developer.double_tap_to_open_books ~= true
            plugin:saveConfig()
        end,
    })

    table.insert(items, {
        text = _("Show hidden files"),
        checked_func = function()
            return type(config.developer) == "table"
                and config.developer.show_hidden_outside_home == true
        end,
        callback = function()
            if type(config.developer) ~= "table" then
                config.developer = {}
            end
            local enabling = config.developer.show_hidden_outside_home ~= true
            config.developer.show_hidden_outside_home = enabling
            plugin:saveConfig()

            if enabling then
                local current_dir = utils.get_current_dir()
                local is_outside_home = not paths.isInHomeDir(current_dir)
                G_reader_settings:saveSetting("show_hidden", is_outside_home)
                G_reader_settings:saveSetting("show_unsupported", is_outside_home)
            else
                G_reader_settings:saveSetting("show_hidden", false)
                G_reader_settings:saveSetting("show_unsupported", false)
                local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
                local fm = ok and FileManager and FileManager.instance
                if fm and fm.file_chooser then
                    fm.file_chooser.show_hidden = false
                    fm.file_chooser.show_unsupported = false
                    fm.file_chooser:refreshPath()
                end
            end

            UIManager:nextTick(function()
                settings_apply.prompt_restart()
            end)
        end,
        keep_menu_open = true,
    })

    table.insert(items, {
        text = _("Debug logging"),
        help_text = _("Enable KOReader verbose debug logging. Logs are written to koreader.log. Takes effect immediately."),
        checked_func = function()
            return G_reader_settings:isTrue("debug")
                and G_reader_settings:isTrue("debug_verbose")
        end,
        callback = function()
            local dbg = require("dbg")
            local enabling = not (G_reader_settings:isTrue("debug")
                and G_reader_settings:isTrue("debug_verbose"))
            if enabling then
                G_reader_settings:makeTrue("debug")
                G_reader_settings:makeTrue("debug_verbose")
                dbg:turnOn()
                dbg:setVerbose(true)
            else
                G_reader_settings:makeFalse("debug")
                G_reader_settings:makeFalse("debug_verbose")
                dbg:setVerbose(false)
                dbg:turnOff()
            end
        end,
        keep_menu_open = true,
    })

    table.insert(items, {
        text = _("Clear all gestures"),
        callback = function()
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text = _("Set all gestures to pass-through? Top-right corner in reader will be kept as Toggle bookmark."),
                ok_text = _("Clear"),
                ok_callback = function()
                    local ok_ds, DataStorage = pcall(require, "datastorage")
                    local ok_ls, LuaSettings = pcall(require, "luasettings")
                    if not ok_ds or not ok_ls then return end
                    local gestures_path = DataStorage:getSettingsDir() .. "/gestures.lua"
                    local settings = LuaSettings:open(gestures_path)
                    for _i, section in ipairs({ "gesture_fm", "gesture_reader" }) do
                        if type(settings.data[section]) == "table" then
                            for k in pairs(settings.data[section]) do
                                settings.data[section][k] = nil
                            end
                        else
                            settings.data[section] = {}
                        end
                    end
                    settings.data.gesture_reader.tap_top_right_corner = { toggle_bookmark = true }
                    settings:flush()
                    settings_apply.prompt_restart()
                end,
            })
        end,
        keep_menu_open = true,
    })

    table.insert(items, {
        text = _("Plugin management"),
        sub_item_table_func = function()
            local ok, PluginLoader = pcall(require, "pluginloader")
            if ok and PluginLoader and type(PluginLoader.genPluginManagerSubItem) == "function" then
                return PluginLoader:genPluginManagerSubItem()
            end
            return {}
        end,
    })

    do
        local ok, patch_item = pcall(dofile, "frontend/ui/elements/patch_management.lua")
        if ok and type(patch_item) == "table" then
            table.insert(items, patch_item)
        end
    end

    return items
end

return M
