local _ = require("gettext")

local M = {}
local active = false

local RETRY_DELAY = 0.1
local MAX_RETRIES = 20

local function valid_dimen(dimen)
    return type(dimen) == "table"
        and type(dimen.x) == "number" and type(dimen.y) == "number"
        and type(dimen.w) == "number" and dimen.w > 0
        and type(dimen.h) == "number" and dimen.h > 0
end

local function button_dimen(button)
    local dimen = button and button.image and button.image.dimen
    return valid_dimen(dimen) and dimen or nil
end

local function layout_buttons_dimen(browser)
    local group = browser and browser._zen_btn_group
    if valid_dimen(group and group.dimen) then return group.dimen end
    local first = browser and browser._zen_btn_view_zone
    local last = browser and browser._zen_btn_grid_zone
    if not (valid_dimen(first) and valid_dimen(last)) then return nil end
    return {
        x = first.x,
        y = math.min(first.y, last.y),
        w = last.x + last.w - first.x,
        h = math.max(first.y + first.h, last.y + last.h) - math.min(first.y, last.y),
    }
end

local function wait_until_ready(get_target, callback, on_failure)
    local UIManager = require("ui/uimanager")
    local retries = 0
    local function check()
        local target = get_target()
        if target then
            callback(target)
            return
        end
        retries = retries + 1
        if retries < MAX_RETRIES then
            UIManager:scheduleIn(RETRY_DELAY, check)
        else
            on_failure()
        end
    end
    UIManager:scheduleIn(RETRY_DELAY, check)
end

function M.start(plugin, ui, open_page_browser)
    local meta = plugin and plugin.config and plugin.config._meta
    if type(meta) ~= "table" or meta.quickstart_reader_tour_pending ~= true
            or active or type(open_page_browser) ~= "function" then
        return false
    end

    local UIManager = require("ui/uimanager")
    local Coachmark = require("common/quickstart/menu_coachmark")
    active = true

    local close_page_browser
    local show_layout_step
    local function show_browser_steps(browser)
        wait_until_ready(function()
            local buttons = browser and browser._zen_reader_tour_targets
            local targets = {}
            for i = 1, 3 do
                targets[i] = button_dimen(buttons and buttons[i])
                if not targets[i] then return nil end
            end
            return targets
        end, function(targets)
            UIManager:show(Coachmark:new{
                steps = {
                    { text = _("Reader menu"), target = targets[1] },
                    { text = _("Bookmarks"), target = targets[2] },
                    { text = _("Table of contents"), target = targets[3] },
                },
                on_complete = function()
                    if type(browser._zen_switch_grid) ~= "function" then
                        active = false
                        return
                    end
                    browser._zen_switch_grid()
                    UIManager:forceRePaint()
                    show_layout_step(browser)
                end,
                on_cancel = function() show_browser_steps(browser) end,
            })
        end, function() active = false end)
    end

    show_layout_step = function(browser)
        wait_until_ready(function() return layout_buttons_dimen(browser) end, function(target)
            UIManager:show(Coachmark:new{
                steps = {{
                    text = _("Change page browser view to single, coverflow, or grid"),
                    target = target,
                    unhatched = browser._zen_grid_dimen,
                }},
                on_complete = function()
                    meta.quickstart_reader_tour_pending = false
                    plugin:saveConfig()
                    if close_page_browser then close_page_browser() end
                    active = false
                end,
                on_cancel = function() show_layout_step(browser) end,
            })
        end, function() active = false end)
    end

    UIManager:show(Coachmark:new{
        steps = {{
            text = _("Swipe up to open the Page Browser"),
            position = "bottom",
        }},
        on_complete = function()
            local browser
            browser, close_page_browser = open_page_browser("carousel")
            if not browser then
                active = false
                return
            end
            UIManager:forceRePaint()
            show_browser_steps(browser)
        end,
        on_cancel = function()
            active = false
            UIManager:scheduleIn(0.5, function() M.start(plugin, ui, open_page_browser) end)
        end,
    })
    return true
end

return M
