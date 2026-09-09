local _ = require("gettext")

local M = {}
local active = false

local RETRY_DELAY = 0.1
local MAX_RETRIES = 20

local ZEN_MODE_TEXT = table.concat({
    _("Zen Mode is enabled. KOReader menus are hidden."),
    _("Disable Zen Mode with this icon to adjust KOReader settings that aren’t available in Zen Settings."),
    _("This does not disable ZenOS—it only shows or hides KOReader’s menus."),
}, "\n\n")
local ZEN_SETTINGS_TEXT = _("This is Zen Settings. ZenOS settings/updates and common KOReader settings live here.")

local function valid_dimen(dimen)
    return type(dimen) == "table"
        and type(dimen.x) == "number" and type(dimen.y) == "number"
        and type(dimen.w) == "number" and dimen.w > 0
        and type(dimen.h) == "number" and dimen.h > 0
end

local function tab_index(tabs, id)
    for i, tab in ipairs(tabs or {}) do
        if tab.id == id then return i end
    end
end

local function zen_button_dimen(touch_menu)
    local refs = touch_menu and touch_menu._zen_panel_refs
    for _i, ref in ipairs(refs and refs.buttons or {}) do
        if ref.id == "zen" then
            local dimen = ref.widget and ref.widget.dimen
            return valid_dimen(dimen) and dimen or nil
        end
    end
end

local function zen_settings_dimen(touch_menu)
    local index = tab_index(touch_menu and touch_menu.tab_item_table, "zen_ui")
    local icon = index and touch_menu.bar and touch_menu.bar.icon_widgets
        and touch_menu.bar.icon_widgets[index]
    local image_dimen = icon and icon.image and icon.image.dimen
    if valid_dimen(image_dimen) then return image_dimen end
    local dimen = icon and icon.dimen
    return valid_dimen(dimen) and dimen or nil
end

local function switch_to_quicksettings(touch_menu, index)
    local icon = touch_menu and touch_menu.bar and touch_menu.bar.icon_widgets
        and touch_menu.bar.icon_widgets[index]
    if icon and type(icon.callback) == "function" then
        icon.callback()
        return true
    end
    if touch_menu and type(touch_menu.switchMenuTab) == "function" then
        touch_menu:switchMenuTab(index)
        return true
    end
    return false
end

function M.start(plugin)
    local meta = plugin and plugin.config and plugin.config._meta
    if type(meta) ~= "table" or meta.quickstart_menu_tour_pending ~= true or active then
        return false
    end

    local menu = plugin.ui and plugin.ui.menu
    if not (menu and type(menu.onShowMenu) == "function") then return false end
    if type(menu.tab_item_table) ~= "table" and type(menu.setUpdateItemTable) == "function" then
        menu:setUpdateItemTable()
    end
    local quicksettings_index = tab_index(menu.tab_item_table, "quicksettings")
    if not quicksettings_index then return false end

    local UIManager = require("ui/uimanager")
    local menu_container = menu.menu_container
    local menu_is_open = menu_container and type(UIManager.isWidgetShown) == "function"
        and UIManager:isWidgetShown(menu_container)
    if menu_is_open then
        if not switch_to_quicksettings(menu_container[1], quicksettings_index) then return false end
    else
        menu:onShowMenu(quicksettings_index)
        local touch_menu = menu.menu_container and menu.menu_container[1]
        if touch_menu and touch_menu.cur_tab ~= quicksettings_index
                and not switch_to_quicksettings(touch_menu, quicksettings_index) then
            return false
        end
    end

    active = true
    UIManager:forceRePaint()
    local retries = 0
    local function show_when_ready()
        local touch_menu = menu.menu_container and menu.menu_container[1]
        local zen_target = zen_button_dimen(touch_menu)
        local settings_target = zen_settings_dimen(touch_menu)
        if zen_target and settings_target then
            local Coachmark = require("common/quickstart/menu_coachmark")
            UIManager:show(Coachmark:new{
                steps = {
                    {
                        text = ZEN_MODE_TEXT,
                        target = zen_target,
                    },
                    {
                        text = ZEN_SETTINGS_TEXT,
                        target = settings_target,
                    },
                },
                on_complete = function()
                    meta.quickstart_menu_tour_pending = false
                    plugin:saveConfig()
                    active = false
                    if type(touch_menu.updateItems) == "function" then
                        touch_menu:updateItems(1)
                    end
                end,
                on_cancel = function()
                    active = false
                    UIManager:scheduleIn(0.5, function() M.start(plugin) end)
                end,
            })
            return
        end

        retries = retries + 1
        if retries < MAX_RETRIES then
            UIManager:scheduleIn(RETRY_DELAY, show_when_ready)
        else
            active = false
        end
    end
    UIManager:scheduleIn(RETRY_DELAY, show_when_ready)
    return true
end

return M
