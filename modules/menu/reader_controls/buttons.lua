local _ = require("gettext")
local M = {}
local MAX_CONTROLS = 8
local ICONS = {
    font = "font",
    contrast = "appbar.contrast",
    page = "page",
    document = "document",
    book_info = "info",
    toc = "toc",
    bookmarks = "bookmark_outline",
    search = "quick_search",
    profiles = "profiles",
    themes = "settings_brush",
    vocabulary = "tab_vocab",
    page_browser = "coverflow",
    koreader_menu = "koreader",
    book_switcher = "history",
}

local function supports(entry, group)
    return (entry.control ~= "document" or group == "kopt")
        and (entry.control ~= "themes" or group == "copt")
        and (entry.control ~= "font" or group == "copt")
        and (entry.control ~= "contrast" or group == "kopt")
end

function M.defaults()
    local entries = {
        { "font", _("Font") },
        { "contrast", _("Contrast") },
        { "page", _("Page") },
        { "document", _("Document") },
        { "book_info", _("Book info") },
        { "toc", _("Chapters"), false },
        { "bookmarks", _("Bookmarks"), false },
        { "search", _("Search"), false },
        { "profiles", _("Profiles"), false },
        { "themes", _("Themes") },
        { "vocabulary", _("Vocabulary builder"), false },
        { "page_browser", _("Page Browser"), false },
        { "koreader_menu", _("KOReader reader menu"), false },
        { "book_switcher", _("Book switcher") },
    }
    local buttons = {}
    for _i, entry in ipairs(entries) do
        buttons[#buttons + 1] = { id = "reader_" .. entry[1], type = "reader_control",
            control = entry[1], label = entry[2], enabled = entry[3] }
    end
    return buttons
end

function M.icon(entry)
    if entry.type == "reader_control" then return entry.icon_override or ICONS[entry.control] end
    return entry.icon
end

function M.setIcon(entry, name)
    if entry.type == "reader_control" then
        entry.icon_override = name ~= ICONS[entry.control] and name or nil
    else
        entry.icon = name
    end
end

function M.ensure(config)
    local cfg = config.reader_controls or { entries = {}, next_id = 0 }
    config.reader_controls = cfg
    if cfg.show_page_chevrons == nil then cfg.show_page_chevrons = not require("device"):isTouchDevice() end
    if not cfg.buttons_initialized then
        local entries = M.defaults()
        for _i, entry in ipairs(cfg.entries or {}) do entries[#entries + 1] = entry end
        cfg.entries = entries
        cfg.buttons_initialized = true
    end
    if not cfg.annotations_merged then
        local position, has_search
        for i = #cfg.entries, 1, -1 do
            local entry = cfg.entries[i]
            if entry.type == "reader_control" and entry.control == "highlights" then
                table.remove(cfg.entries, i)
                position = i
            elseif entry.type == "reader_control" and entry.control == "search" then has_search = true end
        end
        if not has_search then
            for _i, entry in ipairs(M.defaults()) do
                if entry.control == "search" then
                    table.insert(cfg.entries, position or #cfg.entries + 1, entry)
                    break
                end
            end
        end
        cfg.annotations_merged = true
    end
    if not cfg.contrast_split then
        local font, position, has_contrast
        for i, entry in ipairs(cfg.entries) do
            if entry.type == "reader_control" then
                if entry.control == "font" then font, position = entry, i + 1 end
                if entry.control == "contrast" then has_contrast = true end
            end
        end
        if not has_contrast then
            for _i, entry in ipairs(M.defaults()) do
                if entry.control == "contrast" then
                    entry.enabled = font and font.enabled
                    if not font then entry.enabled = false end
                    if font and font.label ~= _("Font") then entry.label = font.label end
                    if font then entry.icon_override = font.icon_override end
                    table.insert(cfg.entries, position or 1, entry)
                    break
                end
            end
        end
        cfg.contrast_split = true
    end
    if not cfg.menu_buttons_added then
        local present = {}
        for _i, entry in ipairs(cfg.entries) do
            if entry.control then present[entry.control] = true end
        end
        for _i, entry in ipairs(M.defaults()) do
            if (entry.control == "vocabulary" or entry.control == "page_browser" or entry.control == "koreader_menu")
                    and not present[entry.control] then
                cfg.entries[#cfg.entries + 1] = entry
            end
        end
        cfg.menu_buttons_added = true
    end
    if not cfg.book_switcher_added then
        local present = false
        for _i, entry in ipairs(cfg.entries) do
            if entry.type == "reader_control" and entry.control == "book_switcher" then present = true end
        end
        if not present then
            for _i, entry in ipairs(M.defaults()) do
                if entry.control == "book_switcher" then cfg.entries[#cfg.entries + 1] = entry; break end
            end
        end
        cfg.book_switcher_added = true
    end
    if not cfg.book_info_actions then
        -- Search, Bookmarks and TOC live in the Book info card, which opens first; their buttons default off.
        local moved, book_info = { search = true, bookmarks = true, toc = true }
        for i = #cfg.entries, 1, -1 do
            local entry = cfg.entries[i]
            if entry.type == "reader_control" and moved[entry.control] then
                entry.enabled = false
            elseif entry.type == "reader_control" and entry.control == "book_info" then
                book_info = table.remove(cfg.entries, i)
            end
        end
        if book_info then table.insert(cfg.entries, 1, book_info) end
        cfg.book_info_actions = true
    end
    for _i, entry in ipairs(cfg.entries) do
        if entry.type == "reader_control" and entry.control == "profiles" and entry.enabled == nil then entry.enabled = false end
    end
    return cfg
end

function M.visible(config, group)
    local entries = {}
    for _i, entry in ipairs(M.ensure(config).entries) do
        if entry.enabled ~= false and supports(entry, group) then
            entries[#entries + 1] = entry
            if #entries == MAX_CONTROLS then break end
        end
    end
    return entries
end

function M.canEnable(config, entry)
    for _i, group in ipairs({ "copt", "kopt" }) do
        if supports(entry, group) and #M.visible(config, group) >= MAX_CONTROLS then return false end
    end
    return true
end

return M
