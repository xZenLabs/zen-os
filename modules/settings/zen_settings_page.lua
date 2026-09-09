local BD = require("ui/bidi")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local Utf8Proc = require("ffi/utf8proc")
local util = require("util")
local _ = require("gettext")

local ArrangeState = require("common/arrange_state")
local I18n = require("common/i18n")
local IconItem = require("common/ui/icon_menu_item")
local SettingsTitleBar = require("common/ui/zen_settings_titlebar")
local TruncatedTextMessage = require("common/ui/truncated_text_message")
local TopMenu = require("modules/global/patches/menu_top_swipe")

local M = {}
local active_page
local resume_state
local pending_arrange_resume
local restoring_arrange_resume
local arrange_open_context
local RESUME_TTL_SECONDS = 6

IconItem.installMenuPatch()

local function install_modal_keyboard_dismissal()
    local InputDialog = require("ui/widget/inputdialog")
    if InputDialog._zen_settings_keyboard_dismissal then return end
    InputDialog._zen_settings_keyboard_dismissal = true
    local orig_init = InputDialog.init
    InputDialog.init = function(self, ...)
        if rawget(_G, "__ZEN_UI_SETTINGS_PAGE") then
            local original_enter_callback = self.enter_callback
            self.enter_callback = function()
                if self:isKeyboardVisible() then
                    self:onCloseKeyboard()
                    if self._input_widget and self._input_widget.unfocus then
                        self._input_widget:unfocus()
                    end
                    return true
                end
                if original_enter_callback then return original_enter_callback() end
                for _i, button_row in ipairs(self.buttons or {}) do
                    for _j, button in ipairs(button_row) do
                        if button.is_enter_default and type(button.callback) == "function" then
                            return button.callback()
                        end
                    end
                end
            end
        end
        return orig_init(self, ...)
    end
end

local function copy_array(items)
    local copy = {}
    for i, item in ipairs(items or {}) do copy[i] = item end
    return copy
end

local function copy_resume_path(path)
    local copy = {}
    for i, step in ipairs(path or {}) do
        copy[i] = {
            text = step.text,
            occurrence = step.occurrence,
        }
    end
    return copy
end

local function item_text(item)
    if type(item) ~= "table" then return "" end
    local text
    if type(item.text_func) == "function" then
        local ok, value = pcall(item.text_func)
        if ok then text = value end
    else
        text = item.text
    end
    text = type(text) == "string" and text or ""
    return ArrangeState.stripSubmenuCaret(text)
end

local function resume_selector(items, item, text)
    local occurrence = 0
    for _i, sibling in ipairs(items or {}) do
        if item_text(sibling) == text then occurrence = occurrence + 1 end
        if sibling == item then break end
    end
    return {
        text = text,
        occurrence = occurrence,
    }
end

local function normalized(text)
    text = type(text) == "string" and text or ""
    return Utf8Proc.lowercase(util.fixUtf8(text, "?"))
end

local function enabled(item)
    if item.enabled == false then return false end
    if type(item.enabled_func) == "function" then
        return item.enabled_func() ~= false
    end
    return true
end

local function visible(item)
    return type(item.show_func) ~= "function" or item.show_func()
end

local function visible_items(items)
    local filtered
    for index, item in ipairs(items or {}) do
        if visible(item) then
            if filtered then filtered[#filtered + 1] = item end
        elseif not filtered then
            filtered = {}
            for previous = 1, index - 1 do filtered[#filtered + 1] = items[previous] end
        end
    end
    if not filtered then return items end
    for key, value in pairs(items) do
        if type(key) ~= "number" then filtered[key] = value end
    end
    return filtered
end

local function item_dimen(page, item)
    for _i, row in ipairs(page.item_group or {}) do
        if row.entry == item then
            local container = row._underline_container or row[1]
            if container and container.dimen then return container.dimen end
        end
    end
end

local function callback_for(item)
    if type(item.callback_func) == "function" then
        return item.callback_func()
    end
    return item.callback
end

local function has_declared_submenu(item, display_text)
    if item.sub_item_table ~= nil or type(item.sub_item_table_func) == "function" then
        return true
    end
    local raw_text
    if type(item.text_func) == "function" then
        local ok, value = pcall(item.text_func)
        if ok then raw_text = value end
    else
        raw_text = item.text
    end
    return (type(raw_text) == "string"
        and ArrangeState.stripSubmenuCaret(raw_text) ~= raw_text)
        or item._zen_settings_submenu == true
        or (display_text and item.sub_title ~= nil)
end

local ZenSettingsPage = Menu:extend{}

function ZenSettingsPage:_resolveSubItems(item)
    if type(item.sub_item_table_func) == "function" then
        local ok, items = pcall(item.sub_item_table_func, self)
        if ok and type(items) == "table" then return visible_items(items) end
        return nil
    end
    return type(item.sub_item_table) == "table"
        and visible_items(item.sub_item_table) or nil
end

function ZenSettingsPage:_currentTitle()
    return self.item_table and self.item_table._zen_title or self.title or _("Settings")
end

function ZenSettingsPage:_prepareItems()
    local caret = BD.mirroredUILayout() and "chevron.left" or "chevron.right"
    for _i, item in ipairs(self.item_table or {}) do
        if type(item) == "table" then
            local text = item_text(item)
            item._zen_settings_row = true
            item._zen_display_text = text
            item._zen_has_submenu = has_declared_submenu(item, text)
                or (item._zen_search_result
                    and type(item._zen_search_result.open_callback) == "function")
            item._zen_caret_icon = caret
        end
    end
end

function ZenSettingsPage:_ensureCurrentTitle()
    if type(self.item_table) ~= "table" then return end
    local depth = #self.item_table_stack
    if not self.item_table._zen_title then
        if depth > (self._title_stack_depth or 0) and self._pending_navigation_title then
            self.item_table._zen_title = self._pending_navigation_title
        else
            self.item_table._zen_title = self._displayed_title or self.title or _("Settings")
        end
    end
    self._displayed_title = self.item_table._zen_title
    self._title_stack_depth = depth
end

function ZenSettingsPage:_syncHeader()
    if not self.title_bar then return end
    local at_root = #self.item_table_stack == 0
    self.title_bar:setState(self:_currentTitle(), not at_root, true)
end

function ZenSettingsPage:_focusSearchInput()
    local input = self.title_bar and self.title_bar.search_input
    if input and not self:_focusHeaderControl(input) and not input.focused then input:focus() end
end

function ZenSettingsPage:_focusHeaderControl(control)
    if not (control and self.getFocusableWidgetXY and self.moveFocusTo) then return false end
    local x, y = self:getFocusableWidgetXY(control)
    if not (x and y) then return false end
    return self:moveFocusTo(x, y)
end

function ZenSettingsPage:_isHeaderFocused()
    local focused = self.getFocusItem and self:getFocusItem()
    local title_bar = self.title_bar
    return title_bar and title_bar.containsFocus
        and title_bar:containsFocus(focused) or false
end

function ZenSettingsPage:_refreshHeaderFocus(control)
    self:updateItems(nil, true)
    return self:_focusHeaderControl(control)
end

function ZenSettingsPage:_closeSearchPill()
    if self._search_active then self:_leaveSearch(true) end
    local title_bar = self.title_bar
    if title_bar and title_bar:collapseSearch() then
        self:_refreshHeaderFocus(title_bar.search_button)
    end
    return true
end

function ZenSettingsPage:openKoreaderMenu()
    return TopMenu.open()
end

function ZenSettingsPage:init()
    self.name = "zen_settings"
    self.title = self.title or _("Settings")
    local initial_items = self.item_table or {}
    self.item_table = visible_items(initial_items)
    if self._root_items == initial_items then self._root_items = self.item_table end
    self.item_table._zen_title = self.title
    self.width = Device.screen:getWidth()
    self.height = Device.screen:getHeight()
    self.is_borderless = true
    self.is_popout = false
    self.covers_fullscreen = true
    self.linesize = require("ui/size").line.thin
    self.line_color = require("ffi/blitbuffer").COLOR_LIGHT_GRAY
    self._search_index = nil
    self._search_active = false
    self._closed = false
    self.item_table_stack = {}
    self._resume_path = {}
    self._title_stack_depth = 0
    self._displayed_title = self.title
    self.is_enable_shortcut = false

    self.custom_title_bar = SettingsTitleBar:new{
        width = self.width,
        title = self.title,
        title_full_width = true,
        back_visible = false,
        search_visible = true,
        show_parent = self,
        back_callback = function() self:backToUpperMenu() end,
        back_hold_callback = function() self:backToRootMenu() end,
        close_callback = function() self:closeMenu() end,
        search_callback = function(query) self:_onSearchChanged(query) end,
        search_opened_callback = function(input) self:_refreshHeaderFocus(input) end,
        search_input_exit_callback = function()
            self:_focusHeaderControl(self.title_bar and self.title_bar.close_button)
        end,
        search_close_callback = function() return self:_closeSearchPill() end,
        plugin = self.plugin,
    }
    if self._initial_resume_path then
        self:_restoreResumePath(self._initial_resume_path, true)
        self._initial_item_table_stack = self.item_table_stack
    end
    Menu.init(self)
    self.key_events = self.key_events or {}
    self.key_events.SelectByShortCut = nil
    if Device.hasFewKeys and Device:hasFewKeys() then
        self.key_events.Close = { { "Back" } }
        self.key_events.Right = nil
        self.key_events.ZenSettingsFocusLeft = { { "Left" } }
        self.key_events.ZenSettingsFocusRight = { { "Right" } }
    end
    _G.__ZEN_UI_SETTINGS_PAGE = self
end

function ZenSettingsPage:updateItems(...)
    if self._closed then return end
    if self._initial_item_table_stack then
        self.item_table_stack = self._initial_item_table_stack
        self._initial_item_table_stack = nil
    end
    self:_ensureCurrentTitle()
    self:_prepareItems()
    self:_syncHeader()
    return Menu.updateItems(self, ...)
end

function ZenSettingsPage:mergeTitleBarIntoLayout()
    local title_bar = self.title_bar
    if title_bar and title_bar.installFocusLayout then
        title_bar:installFocusLayout(self)
    end
end

function ZenSettingsPage:onZenSettingsFocusLeft()
    if self:_isHeaderFocused() then return self:onFocusMove({ -1, 0 }) end
    return self:backToUpperMenu()
end

function ZenSettingsPage:onZenSettingsFocusRight()
    if self:_isHeaderFocused() then return self:onFocusMove({ 1, 0 }) end
    return Menu.onRight(self)
end

function ZenSettingsPage:handleEvent(event)
    if event.handler == "onGesture" then
        local gesture = event.args[1]
        for _i, zone in ipairs(self._zen_page_number_zones or {}) do
            local registered = self._zones and self._zones[zone.id]
            if registered and registered.gs_range:match(gesture) then
                if registered.handler(gesture) then return true end
            end
        end
    end
    return Menu.handleEvent(self, event)
end

function ZenSettingsPage:onTap(arg, ges_ev)
    if TopMenu.isNearHeaderControl(self.title_bar, ges_ev and ges_ev.pos) then return true end
    if Menu.onTap then return Menu.onTap(self, arg, ges_ev) end
end

function ZenSettingsPage:onSwipe(arg, ges_ev)
    if Menu.onSwipe then return Menu.onSwipe(self, arg, ges_ev) end
end

function ZenSettingsPage:_recalculateDimen(no_recalculate_dimen)
    local requested_page = self.page or 1
    Menu._recalculateDimen(self, no_recalculate_dimen)
    if not (self.available_height and self.item_dimen) then return end

    local row_height = IconItem.getSettingsRowHeight()
    self.perpage = math.max(1, math.floor(self.available_height / row_height))
    self.font_size = IconItem.getSettingsFontSize()
    self.item_dimen.h = row_height
    self.page_num = self:getPageNumber(#self.item_table)
    self.page = math.min(requested_page, self.page_num)
end

function ZenSettingsPage:_resumeSelector(item)
    local text = item_text(item)
    return resume_selector(self.item_table, item, text)
end

function ZenSettingsPage:_findResumeItem(step)
    if type(step) ~= "table" or type(step.text) ~= "string" then return nil end
    local occurrence = 0
    for _i, item in ipairs(self.item_table or {}) do
        if item_text(item) == step.text then
            occurrence = occurrence + 1
            if occurrence == (step.occurrence or 1) then return item end
        end
    end
end

function ZenSettingsPage:_restoreResumePath(path, defer_update)
    for _i, step in ipairs(path or {}) do
        local item = self:_findResumeItem(step)
        local items = item and self:_resolveSubItems(item)
        if not items or not self:_openSubmenu(item, items, true) then
            if not defer_update then self:updateItems(1) end
            return false
        end
    end
    if not defer_update then self:updateItems(1) end
    return true
end

function ZenSettingsPage:_activateResumeSelector(selector)
    local item = self:_findResumeItem(selector)
    if not item then return false end
    self:onMenuSelect(item)
    return true
end

function ZenSettingsPage:_openSubmenu(item, items, defer_update)
    if type(items) ~= "table" or #items == 0 then return false end
    self:_leaveSearch(false)
    if self.title_bar and self.title_bar.collapseSearch then
        self.title_bar:collapseSearch()
    end
    self.item_table._zen_title = self:_currentTitle()
    table.insert(self.item_table_stack, self.item_table)
    self._resume_path[#self._resume_path + 1] = self:_resumeSelector(item)
    items._zen_title = item.sub_title or item_text(item)
    self.parent_id = nil
    self.item_table = items
    self.page = 1
    if not defer_update then self:updateItems(1) end
    return true
end

function ZenSettingsPage:onMenuSelect(item, pos)
    if item._zen_search_result then
        self:_openSearchResult(item._zen_search_result)
        return true
    end
    if not enabled(item) then return true end
    self._pending_navigation_title = item.sub_title or item_text(item)

    local bounds = item._zen_settings_control_bounds
    if type(item.checkmark_callback) == "function" and type(pos) == "table"
            and type(pos.x) == "number" and type(bounds) == "table"
            and pos.x >= bounds.left and pos.x <= bounds.right then
        item.checkmark_callback()
        self._search_index = nil
        self:updateItems()
        return true
    end

    local sub_items = self:_resolveSubItems(item)
    if sub_items then
        self:_openSubmenu(item, sub_items)
        return true
    end

    local callback = callback_for(item)
    if type(callback) == "function" then
        arrange_open_context = { opener = self:_resumeSelector(item) }
        callback(self)
        arrange_open_context = nil
        self._search_index = nil
        if self._closed then return true end
        if item.checked ~= nil or type(item.checked_func) == "function" then
            if not item.check_callback_updates_menu and not item.check_callback_closes_menu then
                self:updateItems()
            end
        elseif not item.keep_menu_open then
            self:closeMenu()
        end
    end
    return true
end

function ZenSettingsPage:onMenuHold(item)
    if not enabled(item) then return true end
    local hold_callback = type(item.hold_callback_func) == "function"
        and item.hold_callback_func() or item.hold_callback
    if type(hold_callback) == "function" then
        if item.hold_keep_menu_open == false then self:closeMenu() end
        arrange_open_context = { opener = self:_resumeSelector(item) }
        hold_callback(self, item)
        arrange_open_context = nil
        return true
    end
    local help_text = type(item.help_text_func) == "function"
        and item.help_text_func(self) or item.help_text
    if help_text then
        UIManager:show(InfoMessage:new{ text = help_text })
        return true
    end
    if item._zen_settings_text_truncated then
        TruncatedTextMessage.show(
            item._zen_display_text or item_text(item),
            item_dimen(self, item)
        )
    end
    return true
end

function ZenSettingsPage:backToRootMenu()
    self:_leaveSearch(false)
    if self.title_bar and self.title_bar.collapseSearch then
        self.title_bar:collapseSearch()
    end
    if #self.item_table_stack == 0 and self.item_table == self._root_items then
        return true
    end
    self.item_table_stack = {}
    self._resume_path = {}
    self.item_table = self._root_items
    self.parent_id = nil
    self._pending_navigation_title = nil
    self.itemnumber = 1
    self.page = 1
    self:updateItems(1)
    return true
end

function ZenSettingsPage:backToUpperMenu(no_close)
    if self._search_active then
        self:_leaveSearch(true)
        return true
    end
    if #self.item_table_stack == 0 then
        if not no_close then self:closeMenu() end
        return true
    end
    local parent = table.remove(self.item_table_stack)
    table.remove(self._resume_path)
    local parent_title = parent._zen_title
    if parent.needs_refresh and type(parent.refresh_func) == "function" then
        parent = parent.refresh_func() or parent
    end
    parent._zen_title = parent._zen_title or parent_title
    self.item_table = parent
    self.parent_id = nil
    self._pending_navigation_title = nil
    self:updateItems(1)
    return true
end

function ZenSettingsPage:onClose()
    return self:backToUpperMenu()
end

function ZenSettingsPage:onExit()
    return self:closeMenu()
end

function ZenSettingsPage:onLeftButtonTap()
    return self:openKoreaderMenu()
end

function ZenSettingsPage:onCloseAllMenus()
    self:closeMenu()
    return true
end

function ZenSettingsPage:_rememberResume()
    if self._resume_recorded then return end
    self._resume_recorded = true
    resume_state = {
        closed_at = os.time(),
        path = copy_resume_path(self._resume_path),
        arrange = pending_arrange_resume and {
            opener = pending_arrange_resume.opener,
            path = copy_array(pending_arrange_resume.path),
        } or nil,
    }
    pending_arrange_resume = nil
end

function ZenSettingsPage:_flushDeferredSettingsApplies()
    if self._deferred_settings_applies_flushed then return end
    self._deferred_settings_applies_flushed = true
    local ok, settings_apply = pcall(require, "modules/settings/zen_settings_apply")
    if ok and type(settings_apply.flush_deferred_on_settings_close) == "function" then
        settings_apply.flush_deferred_on_settings_close()
    end
end

function ZenSettingsPage:closeMenu()
    if self._closed then return true end
    self:_rememberResume()
    self._closed = true
    if self._deferred_arrange_parent then
        self._deferred_arrange_parent = nil
        self.invisible = false
    end
    if self.title_bar and self.title_bar.clearStatusRefresh then
        self.title_bar:clearStatusRefresh()
    end
    if active_page == self then active_page = nil end
    if rawget(_G, "__ZEN_UI_SETTINGS_PAGE") == self then
        _G.__ZEN_UI_SETTINGS_PAGE = nil
    end
    UIManager:close(self)
    self:_flushDeferredSettingsApplies()
    return true
end

function ZenSettingsPage:onCloseWidget()
    self:_rememberResume()
    if self._deferred_arrange_parent then
        self._deferred_arrange_parent = nil
        self.invisible = false
    end
    if self.title_bar and self.title_bar.clearStatusRefresh then
        self.title_bar:clearStatusRefresh()
    end
    if active_page == self then active_page = nil end
    if rawget(_G, "__ZEN_UI_SETTINGS_PAGE") == self then
        _G.__ZEN_UI_SETTINGS_PAGE = nil
    end
    self:_flushDeferredSettingsApplies()
    return Menu.onCloseWidget(self)
end

function ZenSettingsPage:_buildSearchIndex()
    if self._search_index then return self._search_index end
    local index = {}
    local seen = {}

    local function add_virtual_items(provider, levels, owner_title)
        if type(provider) ~= "function" then return end
        local ok, items = pcall(provider, self)
        if not ok or type(items) ~= "table" then return end
        for _i, item in ipairs(items) do
            local label = item_text(item)
            if visible(item) and label ~= ""
                    and type(item._zen_search_open) == "function" then
                local crumbs = {}
                for i = 2, #levels do crumbs[#crumbs + 1] = levels[i].title end
                if not item._zen_search_breadcrumb and owner_title and owner_title ~= "" then
                    crumbs[#crumbs + 1] = owner_title
                end
                local breadcrumb = item._zen_search_breadcrumb or table.concat(crumbs, " › ")
                local help_text = item.help_text
                index[#index + 1] = {
                    item = item,
                    label = label,
                    breadcrumb = breadcrumb,
                    open_callback = item._zen_search_open,
                    haystack = normalized(table.concat({
                        label,
                        breadcrumb,
                        type(help_text) == "string" and help_text or "",
                    }, " ")),
                }
            end
        end
    end

    local function walk(items, levels, depth)
        if depth > 12 or seen[items] then return end
        seen[items] = true
        for item_index, item in ipairs(items or {}) do
            if type(item) == "table" then
                local label = item_text(item)
                if label ~= "" then
                    local crumbs = {}
                    for i = 2, #levels do crumbs[#crumbs + 1] = levels[i].title end
                    local breadcrumb = table.concat(crumbs, " › ")
                    local help_text = item.help_text
                    local sub_items = self:_resolveSubItems(item)
                    index[#index + 1] = {
                        item = item,
                        index = item_index,
                        label = label,
                        breadcrumb = breadcrumb,
                        levels = copy_array(levels),
                        sub_items = sub_items,
                        haystack = normalized(table.concat({
                            label,
                            breadcrumb,
                            type(help_text) == "string" and help_text or "",
                        }, " ")),
                    }
                    if sub_items and #sub_items > 0 then
                        sub_items._zen_title = item.sub_title or label
                        local child_levels = copy_array(levels)
                        child_levels[#child_levels + 1] = {
                            title = sub_items._zen_title,
                            items = sub_items,
                            selector = resume_selector(items, item, label),
                        }
                        walk(sub_items, child_levels, depth + 1)
                    end
                    add_virtual_items(item._zen_search_items_func, levels, label)
                end
            end
        end
    end

    walk(self._root_items, {{ title = _("Settings"), items = self._root_items }}, 1)
    self._search_index = index
    return index
end

function ZenSettingsPage:_searchResults(query)
    local results = { _zen_title = self:_currentTitle(), _zen_search_results = true }
    local needle = normalized(query)
    for _i, entry in ipairs(self:_buildSearchIndex()) do
        if entry.haystack:find(needle, 1, true) then
            local source = entry.item
            results[#results + 1] = {
                text = entry.label,
                icon_glyph = source.icon_glyph,
                icon_width = source.icon_width,
                radio = source.radio,
                checked = source.checked,
                checked_func = source.checked_func,
                enabled = source.enabled,
                enabled_func = source.enabled_func,
                _zen_settings_row = true,
                _zen_display_text = entry.label,
                _zen_settings_breadcrumb = entry.breadcrumb,
                _zen_has_submenu = entry.sub_items ~= nil or entry.open_callback ~= nil,
                _zen_search_result = entry,
            }
        end
    end
    return results
end

function ZenSettingsPage:_onSearchChanged(query)
    query = type(query) == "string" and query:match("^%s*(.-)%s*$") or ""
    if query == "" then
        self:_leaveSearch(true)
        return
    end
    if not self._search_active then
        self._search_active = true
        self._search_snapshot = {
            item_table = self.item_table,
            item_table_stack = copy_array(self.item_table_stack),
        }
    end
    self.item_table = self:_searchResults(query)
    self:updateItems(1)
    self:_focusSearchInput()
end

function ZenSettingsPage:_leaveSearch(restore)
    if not self._search_active then return end
    local snapshot = self._search_snapshot
    self._search_active = false
    self._search_snapshot = nil
    self.title_bar:setQuery("")
    if restore and snapshot then
        self.item_table = snapshot.item_table
        self.item_table_stack = snapshot.item_table_stack
        self:updateItems(1)
        self:_focusSearchInput()
    end
end

function ZenSettingsPage:_setPath(levels, current_items)
    self.item_table_stack = {}
    self._resume_path = {}
    for i = 1, #levels - 1 do
        self.item_table_stack[#self.item_table_stack + 1] = levels[i].items
    end
    for i = 2, #levels do
        if levels[i].selector then
            self._resume_path[#self._resume_path + 1] = levels[i].selector
        end
    end
    self.item_table = current_items
    self.parent_id = nil
end

function ZenSettingsPage:_openSearchResult(entry)
    if type(entry.open_callback) == "function" then
        self:_leaveSearch(true)
        if self.title_bar and self.title_bar.collapseSearch then
            self.title_bar:collapseSearch()
        end
        entry.open_callback()
        return
    end
    self:_leaveSearch(false)
    if self.title_bar and self.title_bar.collapseSearch then
        self.title_bar:collapseSearch()
    end
    local levels = entry.levels
    local sub_items = entry.sub_items
    if sub_items and #sub_items > 0 then
        self:_setPath(levels, levels[#levels].items)
        table.insert(self.item_table_stack, self.item_table)
        self._resume_path[#self._resume_path + 1] = self:_resumeSelector(entry.item)
        self.item_table = sub_items
        self:updateItems(1)
        return
    end

    self:_setPath(levels, levels[#levels].items)
    self.itemnumber = entry.index
    self.page = self:getPageNumber(entry.index)
    self:updateItems(1)
    if has_declared_submenu(entry.item, entry.label) then
        UIManager:nextTick(function()
            if not self._closed then self:onMenuSelect(entry.item) end
        end)
    end
end

function ZenSettingsPage:openPath(markers)
    for _i, marker in ipairs(markers or {}) do
        local found
        for _j, item in ipairs(self.item_table or {}) do
            if item[marker.key] == marker.value then
                found = item
                break
            end
        end
        if not found then return false end
        local sub_items = self:_resolveSubItems(found)
        if sub_items then
            self:_openSubmenu(found, sub_items)
        else
            self:onMenuSelect(found)
        end
    end
    return true
end

local function schedule_open_path(page, path, reset_to_root)
    if type(path) ~= "table" or #path == 0 then return end
    UIManager:nextTick(function()
        if page._closed then return end
        if reset_to_root then
            page:_leaveSearch(false)
            if page.title_bar and page.title_bar.collapseSearch then
                page.title_bar:collapseSearch()
            end
            page.item_table_stack = {}
            page._resume_path = {}
            page.item_table = page._root_items
            page:updateItems(1)
        end
        page:openPath(path)
    end)
end

function M.show(plugin, opts)
    opts = opts or {}
    if active_page and not active_page._closed then
        schedule_open_path(active_page, opts.path, true)
        return active_page
    end
    install_modal_keyboard_dismissal()
    local resume
    if resume_state then
        local age = os.time() - resume_state.closed_at
        if age >= 0 and age <= RESUME_TTL_SECONDS and not opts.path then
            resume = resume_state
        end
        resume_state = nil
    end
    pending_arrange_resume = nil
    restoring_arrange_resume = resume and resume.arrange or nil
    arrange_open_context = nil
    I18n.refresh()
    local root_items = require("modules/settings/zen_settings").build(plugin).sub_item_table
    root_items._zen_title = _("Settings")
    local page = ZenSettingsPage:new{
        title = _("Settings"),
        item_table = root_items,
        _root_items = root_items,
        _initial_resume_path = resume and resume.path or nil,
        plugin = plugin,
    }
    if resume and resume.arrange then
        page.invisible = true
        page._deferred_arrange_resume = true
    end
    active_page = page
    UIManager:show(page)
    if resume and resume.arrange then
        UIManager:nextTick(function()
            if page._closed then return end
            page:_activateResumeSelector(resume.arrange.opener)
            restoring_arrange_resume = nil
            arrange_open_context = nil
            if page._deferred_arrange_resume then
                page._deferred_arrange_resume = nil
                page.invisible = false
                UIManager:setDirty(page, "ui")
            end
        end)
    else
        schedule_open_path(page, opts.path, false)
    end
    return page
end

function M.closeActive()
    local stack = UIManager._window_stack
    local deepest_arrange_resume = pending_arrange_resume
    if type(stack) == "table" then
        for index = #stack, 1, -1 do
            local widget = stack[index] and stack[index].widget
            if active_page and widget == active_page then break end
            if widget and type(widget._zen_arrange_close_all) == "function" then
                widget:_zen_arrange_close_all()
                if pending_arrange_resume and (not deepest_arrange_resume
                        or #pending_arrange_resume.path > #deepest_arrange_resume.path) then
                    deepest_arrange_resume = pending_arrange_resume
                end
            end
        end
    end
    pending_arrange_resume = deepest_arrange_resume
    if not active_page and resume_state and deepest_arrange_resume then
        resume_state.closed_at = os.time()
        resume_state.arrange = deepest_arrange_resume
    end
    if active_page then active_page:closeMenu() end
    return true
end

function M.searchActive(query)
    if not active_page or active_page._closed then
        local plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        if not plugin then return false end
        active_page = M.show(plugin)
    end
    active_page.title_bar:setQuery(query)
    active_page:_onSearchChanged(query)
    return true
end

function M.claimArrangeRoute()
    if restoring_arrange_resume then
        local resume = restoring_arrange_resume
        restoring_arrange_resume = nil
        arrange_open_context = nil
        if active_page and active_page._deferred_arrange_resume then
            active_page._deferred_arrange_resume = nil
            active_page._deferred_arrange_parent = true
            resume.deferred_parent = active_page
        end
        return resume
    end
    if not arrange_open_context then return nil end
    local resume = {
        opener = arrange_open_context.opener,
        path = {},
    }
    arrange_open_context = nil
    return resume
end

function M.noteArrangeRoute(resume)
    if type(resume) ~= "table" or type(resume.opener) ~= "table" then return end
    local arrange = {
        opener = {
            text = resume.opener.text,
            occurrence = resume.opener.occurrence,
        },
        path = copy_array(resume.path),
    }
    pending_arrange_resume = arrange
    if (not active_page or active_page._closed) and resume_state
            and os.time() - resume_state.closed_at <= RESUME_TTL_SECONDS then
        resume_state.arrange = arrange
    end
end

function M.rememberStandaloneArrangeRoute(path, opener_text, arrange_path)
    if rawget(_G, "__ZEN_UI_SETTINGS_PAGE") or type(path) ~= "table"
            or type(opener_text) ~= "string" then
        return false
    end
    resume_state = {
        closed_at = os.time(),
        path = copy_resume_path(path),
        arrange = {
            opener = { text = opener_text, occurrence = 1 },
            path = copy_array(arrange_path),
        },
    }
    return true, resume_state.arrange
end

M.Page = ZenSettingsPage

return M
