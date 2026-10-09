return function()
    local plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    local config = plugin.config
    if not config._meta.end_book_action_migrated then
        local end_action = G_reader_settings:readSetting("end_document_action")
        if end_action == nil or end_action == "book_status" or end_action == "pop-up" then
            G_reader_settings:saveSetting("end_document_action", "zen_end_book")
        end
        if not config._meta.end_book_default_applied
                and G_reader_settings:readSetting("end_document_auto_mark") == nil then
            G_reader_settings:saveSetting("end_document_auto_mark", true)
        end
        config._meta.end_book_default_applied = true
        config._meta.end_book_action_migrated = true
        plugin:saveConfig()
    end

    local ReaderStatus = require("apps/reader/modules/readerstatus")
    if ReaderStatus._zen_end_book then return end
    ReaderStatus._zen_end_book = true
    local UIManager = require("ui/uimanager")
    local Rakuyomi = require("modules/filebrowser/patches/rakuyomi")
    local original = ReaderStatus.onEndOfBook
    function ReaderStatus:onEndOfBook(...)
        if Rakuyomi.onEndOfBook(self.ui) then return true end
        -- Let KOReader handle quickstart, haptics and the user's auto-mark choice.
        local result = original(self, ...)
        if G_reader_settings:readSetting("end_document_action") == "zen_end_book"
                and G_reader_settings:readSetting("lastfile")
                    ~= require("ui/quickstart").quickstart_filename then
            local top = UIManager:getTopmostVisibleWidget()
            if not top or top.name ~= "zen_end_book" then
                require("modules/reader/end_book").show(self.ui, plugin)
            end
        end
        return result
    end

    local _ = require("gettext")
    local MenuSorter = require("ui/menusorter")
    local mergeAndSort = MenuSorter.mergeAndSort
    function MenuSorter:mergeAndSort(prefix, menu_items, ...)
        -- KOReader rebuilds common settings with dofile() for each menu.
        local action = menu_items.document_end_action
        if action then
            table.insert(action.sub_item_table, 2, {
                text = _("Zen end of book"),
                radio = true,
                checked_func = function()
                    return G_reader_settings:readSetting("end_document_action") == "zen_end_book"
                end,
                callback = function()
                    G_reader_settings:saveSetting("end_document_action", "zen_end_book")
                end,
            })
        end
        return mergeAndSort(self, prefix, menu_items, ...)
    end
end
