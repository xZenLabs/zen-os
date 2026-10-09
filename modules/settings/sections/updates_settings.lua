-- settings/sections/updates_settings.lua
-- "Updates" root section: update checks, KOReader OTA, changelog, channel.
-- Receives ctx: { plugin, config, save_and_apply, settings_apply }

local _ = require("gettext")
local updater = require("modules/settings/zen_updater")

local M = {}

local function build_koreader_update_item()
    local ok_device, Device = pcall(require, "device")
    local has_ota = ok_device and Device and type(Device.hasOTAUpdates) == "function"
        and Device:hasOTAUpdates()
    if not has_ota then return nil end

    return {
        text = _("Update KOReader"),
        keep_menu_open = true,
        callback = function()
            local OTAManager = require("ui/otamanager")
            local NetworkMgr = require("ui/network/manager")
            NetworkMgr:runWhenConnected(function()
                OTAManager:fetchAndProcessUpdate()
            end)
        end,
    }
end

function M.build(ctx)
    local plugin = ctx.plugin
    local items = {
        updater.build_update_now_item(plugin),
        updater.build_changelog_item(),
        updater.build_channel_item(),
        updater.build_auto_check_item(),
    }
    local koreader_update_item = build_koreader_update_item()
    if koreader_update_item then
        table.insert(items, 2, koreader_update_item)
    end
    return items
end

return M
