return function()
    local plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    local config = plugin.config
    if not config._meta.end_book_default_applied then
        G_reader_settings:saveSetting("end_document_action", "zen_end_book")
        if G_reader_settings:readSetting("end_document_auto_mark") == nil then
            G_reader_settings:saveSetting("end_document_auto_mark", true)
        end
        config._meta.end_book_default_applied = true
        plugin:saveConfig()
    end

    local ReaderStatus = require("apps/reader/modules/readerstatus")
    if ReaderStatus._zen_end_book then return end
    ReaderStatus._zen_end_book = true
    local UIManager = require("ui/uimanager")
    local original = ReaderStatus.onEndOfBook
    function ReaderStatus:onEndOfBook(...)
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
    local items = require("ui/elements/common_settings_menu_table").document_end_action.sub_item_table
    table.insert(items, 2, {
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
