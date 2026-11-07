-- Physical Home button support for KOReader's stock Cloud storage browser.
-- CloudStorage doesn't register a Home key handler by default, so pressing
-- Home there normally does nothing. Close the browser (regardless of folder
-- depth) and return to the default navbar tab underneath, matching the
-- behavior in the File Manager and other ZenOS library views.

local function patch_cloud_storage()
    local CloudStorage = require("apps/cloudstorage/cloudstorage")
    if CloudStorage._zen_home_patched then return end
    CloudStorage._zen_home_patched = true

    local Device = require("device")
    local UIManager = require("ui/uimanager")

    local orig_init = CloudStorage.init
    function CloudStorage:init()
        orig_init(self)
        if Device:hasKeys() then
            self.key_events = self.key_events or {}
            self.key_events.Home = { { "Home" } }
        end
    end

    function CloudStorage:onHome()
        UIManager:close(self)
        local open_default = rawget(_G, "__ZEN_UI_NAVBAR_OPEN_DEFAULT_TAB")
        if type(open_default) == "function" then
            open_default()
        end
        return true
    end
end

-- Patch when KOReader first opens Cloud storage.
local function apply_cloud_storage_home()
    require("common/on_require").whenLoaded("apps/cloudstorage/cloudstorage", patch_cloud_storage)
end

return apply_cloud_storage_home
