local _ = require("gettext")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")

local M = {}

-- opts.action replaces the KOReader restart, e.g. with a device reboot.
function M.request(opts)
    opts = opts or {}
    if opts.show_notice ~= false then
        UIManager:show(InfoMessage:new{
            text = _("Restarting") .. "...",
        })
    end
    UIManager:tickAfterNext(opts.action or function()
        UIManager:broadcastEvent(Event:new("Restart"))
    end)
end

return M
