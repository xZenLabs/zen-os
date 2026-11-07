local M = {}
local _ = require("gettext")

function M.migrate(config)
    local legacy = config.annotation_viewer and config.annotation_viewer.tabs
    if not legacy then return false end
    config.page_browser = config.page_browser or {}
    config.page_browser.tabs = config.page_browser.tabs or {}
    for _i, id in ipairs({ "bookmarks", "highlights", "annotations" }) do
        if config.page_browser.tabs[id] == nil then config.page_browser.tabs[id] = legacy[id] end
    end
    config.annotation_viewer.tabs = nil
    return true
end

function M.get(config)
    M.migrate(config)
    config.page_browser = config.page_browser or {}
    local cfg = config.page_browser
    local defaults = require("config/defaults").page_browser
    cfg.tabs = cfg.tabs or {}
    for id, enabled in pairs(defaults.tabs) do
        if cfg.tabs[id] == nil then cfg.tabs[id] = enabled end
    end
    local order, seen, enabled_count = {}, {}, 0
    local function append(ids)
        for _i, id in ipairs(ids) do
            if defaults.tabs[id] ~= nil and not seen[id] then
                order[#order + 1], seen[id] = id, true
                if cfg.tabs[id] then enabled_count = enabled_count + 1 end
            end
        end
    end
    append(cfg.tab_order or {})
    append(defaults.tab_order)
    cfg.tab_order = order
    if enabled_count == 0 then cfg.tabs.browser = true end
    return cfg
end

function M.list(config, ui, include_disabled, extra_tab)
    local cfg = M.get(config)
    local paging = ui and ui.paging
    local labels = {
        browser = { "view_carousel_outline", _("Page browser") },
        aa = { paging and "appbar.contrast" or "font", paging and _("Contrast") or _("Font") },
        bookmarks = { "bookmark_outline", _("Bookmarks") },
        highlights = { "lookup_highlight", _("Highlights") },
        annotations = { "annotations", _("Annotations") },
        pins = { "pin", _("Pinned pages") },
        toc = { "toc", _("Chapters") },
        book_details = { "info", _("Book details") },
        book_switcher = { "history", _("Book switcher") },
    }
    local entries = {}
    for _i, id in ipairs(cfg.tab_order) do
        if include_disabled or cfg.tabs[id] or id == extra_tab then
            entries[#entries + 1] = { id = id, icon = labels[id][1], text = labels[id][2] }
        end
    end
    return entries
end

function M.show(config, plugin, ui)
    local cfg = M.get(config)
    local rows = {}
    for _i, entry in ipairs(M.list(config, ui, true)) do
        local id = entry.id
        local function toggle()
            if cfg.tabs[id] and #M.list(config, ui) == 1 then return end
            cfg.tabs[id] = not cfg.tabs[id]
            plugin:saveConfig()
        end
        local row = {
            text = entry.text, orig_item = id, sub_title = entry.text,
            checked_func = function() return cfg.tabs[id] end,
            callback = toggle,
        }
        if id == "book_switcher" then
            row.sub_item_table_func = function()
                return require("modules/settings/sections/app_launcher_settings").bookSwitcherItems()
            end
        elseif id == "book_details" then
            -- Row tap opens the library editor directly; checkmark still toggles the tab
            row._zen_settings_submenu = true
            row.checkmark_callback = toggle
            row.callback = function()
                require("modules/settings/sections/library_settings").showBookDetails(config, plugin)
            end
        end
        rows[#rows + 1] = row
    end
    return require("common/ui/zen_arrange_list").show{
        title = _("Tabs"), item_table = rows, plugin = plugin,
        callback = function()
            local order = {}
            for _i, row in ipairs(rows) do order[#order + 1] = row.orig_item end
            cfg.tab_order = order
            plugin:saveConfig()
        end,
    }
end

return M
