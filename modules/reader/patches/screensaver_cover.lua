local function apply_screensaver_cover()
    -- When a book has no cover (or the user hasn't set a screensaver folder),
    -- KOReader falls back to "resources/koreader.png".  Replace that with the
    -- ZenOS logo so the device shows our branding instead.

    -- Resolve both SVG variants from this file's path at apply-time.
    local _icons_dir
    do
        local root = require("common/plugin_root")
        if root then
            local lfs = require("libs/libkoreader-lfs")
            local p = root .. "/icons/zen_cover.svg"
            if lfs.attributes(p, "mode") == "file" then
                _icons_dir = root .. "/icons/"
            end
        end
    end

    if not _icons_dir then return end

    -- Patch when KOReader first shows a screensaver.
    require("common/on_require").whenLoaded("ui/screensaver", function()
        local utils = require("common/utils")
        local Screensaver = require("ui/screensaver")
        if Screensaver._zen_cover_patched then return end
        Screensaver._zen_cover_patched = true
        local orig_setup = Screensaver.setup

        function Screensaver:setup(event, event_message)
            orig_setup(self, event, event_message)
            if self.image_file == "resources/koreader.png" then
                -- Choose logo variant based on the background fill setting:
                -- black background → white logo; white/none → dark logo.
                local bg = G_reader_settings:readSetting("screensaver_img_background")
                if bg == "black" then
                    self.image_file = utils.resolveLocalIcon(_icons_dir, "zen_cover_light")
                        or (_icons_dir .. "zen_cover_light.svg")
                else
                    self.image_file = utils.resolveLocalIcon(_icons_dir, "zen_cover")
                        or (_icons_dir .. "zen_cover.svg")
                end
            end
        end
    end)
end

return apply_screensaver_cover
