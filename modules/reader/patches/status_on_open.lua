local function apply_status_on_open()
    local plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    local ReaderUI = require("apps/reader/readerui")
    if ReaderUI._zen_new_status_on_open_patched then return end
    ReaderUI._zen_new_status_on_open_patched = true

    local book_status = require("common/book_status")
    local UIManager = require("ui/uimanager")
    local orig_onReaderReady = ReaderUI.onReaderReady

    -- Collection/index writes and the sidecar flush run after the first page paint.
    local function finishOpen(reader, doc_settings, file, was_tbr, status_changed)
        if was_tbr then
            pcall(function() require("common/tbr_index").setExplicit(file, false) end)
        end
        -- Skip once closed: closing already flushed the sidecar.
        if reader.document and reader.doc_settings == doc_settings then
            local acknowledged = book_status.acknowledgeNewVersion(doc_settings)
            if (status_changed or acknowledged) and type(doc_settings.flush) == "function" then
                doc_settings:flush()
            end
        end
        if file then
            pcall(function() require("common/tbr_index").refreshPath(file, doc_settings) end)
        end
    end

    function ReaderUI:onReaderReady(...)
        if orig_onReaderReady then
            orig_onReaderReady(self, ...)
        end
        local doc_settings = self.doc_settings
        local file = doc_settings and doc_settings.data and doc_settings.data.doc_path
        local summary = type(doc_settings and doc_settings.readSetting) == "function"
            and doc_settings:readSetting("summary") or {}
        local was_tbr = false
        if file then
            pcall(function()
                was_tbr = require("common/tbr_index").isExplicit(file)
            end)
        end
        local status_changed = was_tbr or summary.status == "abandoned"
        if status_changed then
            summary.status = "reading"
            require("apps/filemanager/filemanagerutil").saveSummary(doc_settings, summary)
            require("ui/widget/booklist").setBookInfoCacheProperty(file, "status", "reading")
            book_status.invalidate(file)
        end
        UIManager:nextTick(finishOpen, self, doc_settings, file, was_tbr, status_changed)
        local meta = plugin and plugin.config and plugin.config._meta
        if type(meta) == "table" and meta.reader_defaults_apply_on_next_open == true then
            local ok_defaults, applied = pcall(function()
                return require("common/reader_defaults").applyDeferredToReader(self)
            end)
            if ok_defaults and applied == true then
                meta.reader_defaults_apply_on_next_open = false
                plugin:saveConfig()
            end
        end
        if self.rolling and self.typeset and not doc_settings:isTrue("zen_vertical_margins_migrated") then
            -- Unset or already the user's default: a book opened after the migration, nothing to reset.
            local function current(key)
                local saved = doc_settings:readSetting(key)
                return saved == nil or saved == G_reader_settings:readSetting(key)
            end
            local ReaderDefaults = require("common/reader_defaults")
            if current("copt_t_page_margin") and current("copt_b_page_margin") then
                doc_settings:saveSetting("zen_vertical_margins_migrated", true)
            elseif ReaderDefaults.isZenPreset(require("config/preset_store").getActivePreset("reader")) then
                local configurable = self.document.configurable
                configurable.t_page_margin = ReaderDefaults.DEFAULT_VERTICAL_MARGIN
                configurable.b_page_margin = ReaderDefaults.DEFAULT_VERTICAL_MARGIN
                self.typeset:onSetPageTopAndBottomMargin({ configurable.t_page_margin, configurable.b_page_margin })
                doc_settings:saveSetting("zen_vertical_margins_migrated", true)
                self:saveSettings()
            end
        end
        -- Equal T/B margins default to synced once per book (later toggles stick); unequal ones never sync.
        if self.rolling and self.typeset then
            local configurable = self.document.configurable
            local equal = configurable.t_page_margin == configurable.b_page_margin
            if not equal or not doc_settings:isTrue("zen_margin_sync_defaulted") then
                configurable.sync_t_b_page_margins = equal and 1 or 0
                self.typeset.sync_t_b_page_margins = equal
                doc_settings:saveSetting("zen_margin_sync_defaulted", true)
            end
        end
    end
end

return apply_status_on_open
