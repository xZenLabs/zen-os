local function apply_reader_flash_cbz()
    local ReaderView = require("apps/reader/modules/readerview")
    local ReaderPaging = require("apps/reader/modules/readerpaging")
    local UIManager = require("ui/uimanager")
    local plugin = rawget(_G, "__ZEN_UI_PLUGIN")

    local function flash_cbz(view)
        local features = plugin and plugin.config and plugin.config.features
        if features and features.reader_flash_cbz == true
                and view.document.file:lower():sub(-4) == ".cbz" then
            UIManager:setDirty(view.dialog, "full")
        end
    end

    local orig_onPageUpdate = ReaderView.onPageUpdate
    ReaderView.onPageUpdate = function(self, new_page_no, ...)
        local page_changed = self.state.page ~= new_page_no
        local result = orig_onPageUpdate(self, new_page_no, ...)
        if page_changed then flash_cbz(self) end
        return result
    end

    local orig_onGotoViewRel = ReaderPaging.onGotoViewRel
    ReaderPaging.onGotoViewRel = function(self, ...)
        local page = self.current_page
        local result = orig_onGotoViewRel(self, ...)
        -- Same-page advances do not emit PageUpdate.
        if result and self.current_page == page then flash_cbz(self.view) end
        return result
    end
end

return apply_reader_flash_cbz
