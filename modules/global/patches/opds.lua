-- ZenOS OPDS browser enhancements, applied on the first OPDSBrowser:init so the
-- large patch body (patches/opds_browser) stays off the boot path.

local function apply_opds()
    local ok_opds, OPDSBrowser = pcall(require, "opdsbrowser")
    if not ok_opds or type(OPDSBrowser) ~= "table" then return end
    if OPDSBrowser._zen_opds_patched or OPDSBrowser._zen_opds_deferred then return end
    OPDSBrowser._zen_opds_deferred = true

    local plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    local orig_init = OPDSBrowser.init
    OPDSBrowser.init = function(self, ...)
        -- Restore first so the body wraps the real init.
        OPDSBrowser.init = orig_init
        local prev_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        _G.__ZEN_UI_PLUGIN = plugin or prev_plugin
        local ok, err = pcall(require("modules/global/patches/opds_browser"))
        _G.__ZEN_UI_PLUGIN = prev_plugin
        if not ok then
            require("common/zen_logger").new("opds").warn("global patch failed", "opds", err)
        end
        return OPDSBrowser.init(self, ...)
    end
end

return apply_opds
