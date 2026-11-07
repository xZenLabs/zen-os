local _ = require("gettext")

local M = {}
local active = false

function M.start(plugin, ui, open_page_browser)
    local meta = plugin and plugin.config and plugin.config._meta
    if type(meta) ~= "table" or meta.quickstart_reader_tour_pending ~= true
            or active or type(open_page_browser) ~= "function" then
        return false
    end

    local UIManager = require("ui/uimanager")
    local Coachmark = require("common/quickstart/menu_coachmark")
    active = true
    -- One-shot: clear as soon as shown
    meta.quickstart_reader_tour_pending = false
    plugin:saveConfig()

    UIManager:show(Coachmark:new{
        steps = {{
            text = _("Swipe up to open the Page Browser"),
            position = "bottom",
            swipe_up = true,
        }},
        on_complete = function()
            active = false
            open_page_browser()
        end,
        on_cancel = function() active = false end,
    })
    return true
end

return M
