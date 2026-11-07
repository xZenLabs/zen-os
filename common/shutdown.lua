local logger = require("common/zen_logger").new("shutdown")
local SharedState = require("common/shared_state")

local M = {}

function M.closeStandaloneViews(plugin)
    if type(plugin) ~= "table" then return end
    for _i, key in ipairs({ "group_view", "home", "stats" }) do
        local view = SharedState.get(plugin, key)
        if view and type(view.closeAll) == "function" then
            local ok, err = pcall(view.closeAll, true)
            if not ok then
                logger.warn("failed to close standalone view before shutdown", key, err)
            end
        end
    end
end

function M.broadcastExit(plugin)
    M.closeStandaloneViews(plugin)
    require("ui/uimanager"):broadcastEvent(require("ui/event"):new("Exit"))
end

return M
