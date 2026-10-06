local function apply_reader_flash_cbz()
    local ReaderView = require("apps/reader/modules/readerview")
    local UIManager = require("ui/uimanager")
    local plugin = rawget(_G, "__ZEN_UI_PLUGIN")

    local orig_onPageUpdate = ReaderView.onPageUpdate
    ReaderView.onPageUpdate = function(self, new_page_no, ...)
        local page_changed = self.state.page ~= new_page_no
        local result = orig_onPageUpdate(self, new_page_no, ...)
        local features = plugin and plugin.config and plugin.config.features
        if page_changed and features and features.reader_flash_cbz == true
                and self.document.file:lower():sub(-4) == ".cbz" then
            UIManager:setDirty(self.dialog, "full")
        end
        return result
    end
end

return apply_reader_flash_cbz
