-- touch_menu_footer.lua
-- Redesigns the TouchMenu footer for all menu tabs:
--   LEFT slot   ← cleared.
--   CENTER slot ← wide button using icons/large_chevron_up.svg
--                 (2× icon width, same height). Goes up a level when
--                 in a sub-menu, or closes when at the top level.
--   RIGHT slot  ← pagination (page_info: chevrons + page text).
-- Applies to every TouchMenu instance (reader, file manager, all tabs).

local function apply_touch_menu_footer()
    local utils          = require("common/utils")
    local Device         = require("device")
    local Geom           = require("ui/geometry")
    local GestureRange   = require("ui/gesturerange")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local IconWidget     = require("ui/widget/iconwidget")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local Screen         = Device.screen

    local DGENERIC_ICON_SIZE = G_defaults:readSetting("DGENERIC_ICON_SIZE")

    -- Resolve the bundled icon through the active custom pack when available.
    local _icon_file
    do
        local root = require("common/plugin_root")
        if root then
            _icon_file = utils.resolveIcon(root .. "/icons/", "large_chevron_up")
        end
    end

    -- Minimal tappable icon widget.
    -- Uses file= so we can point at the plugin's own icons/ dir.
    -- GestureRange references self.dimen, which KOReader updates in-place
    -- after painting, so hit-testing works correctly at runtime.
    local TappableIcon = InputContainer:extend{}

    function TappableIcon:init()
        self.dimen = Geom:new{ w = self.width, h = self.height }
        self.image = IconWidget:new{
            file   = self.file,
            icon   = self.file and nil or self.icon_name,
            width  = self.width,
            height = self.height,
        }
        self[1] = self.image
        self.ges_events.TapSelect = {
            GestureRange:new{
                ges   = "tap",
                range = self.dimen,
            }
        }
    end

    function TappableIcon:onTapSelect()
        if self.callback then self.callback() end
        return true
    end

    local TouchMenu = require("ui/widget/touchmenu")
    local orig_init = TouchMenu.init

    function TouchMenu:init()
        orig_init(self)

        -- footer layout after orig_init:
        --   footer[1] = LeftContainer  { up_button (backToUpperMenu) }
        --   footer[2] = CenterContainer{ self.page_info              }
        --   footer[3] = RightContainer { self.device_info            }

        local icon_width  = Screen:scaleBySize(DGENERIC_ICON_SIZE)
        local icon_height = icon_width

        local close_btn = TappableIcon:new{
            file      = _icon_file,
            icon_name = "chevron.up",   -- fallback if file not found
            width     = icon_width * 2,
            height    = icon_height,
            callback  = function() self:backToUpperMenu() end,
        }

        -- Clear the LEFT slot.
        if self.footer and self.footer[1] then
            self.footer[1][1] = HorizontalGroup:new{}
        end

        -- Place the wide close button in the CENTER slot.
        if self.footer and self.footer[2] then
            self.footer[2][1] = close_btn
        end

        -- Move page_info (pagination) to the RIGHT slot.
        -- updateItems() still updates self.page_info_text / showHide() directly,
        -- so pagination display continues to work correctly.
        if self.footer and self.footer[3] then
            self.footer[3][1] = self.page_info
        end
    end
end

return apply_touch_menu_footer
