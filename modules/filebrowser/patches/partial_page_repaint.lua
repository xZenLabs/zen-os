local function apply_partial_page_repaint()
    -- On e-ink displays, navigating to a page whose item count is less than
    -- `perpage` leaves ghost images from the previous page in the now-empty
    -- item slots.  A full-waveform e-ink refresh clears them.
    --
    -- When coverbrowser is active it replaces FileChooser.updateItems with
    -- CoverMenu.updateItems at the class level, bypassing Menu.updateItems
    -- entirely.  We therefore hook both entry points:
    --   1. FileChooser.updateItems  – classic mode (and as a backstop)
    --   2. CoverMenu.updateItems    – mosaic / detailed-list mode
    --
    -- A shared `pending` flag prevents a double repaint if both hooks happen
    -- to fire in the same update cycle.

    local FileChooser = require("ui/widget/filechooser")
    local UIManager   = require("ui/uimanager")
    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")

    local pending = false

    local function is_enabled()
        local features = zen_plugin and zen_plugin.config and zen_plugin.config.features
        return type(features) == "table" and features.partial_page_repaint == true
    end

    local function schedule_repaint(self)
        if not is_enabled() or self.items_max_lines then return end
        -- Skip transient overlay choosers (e.g. MoveChooser) that shouldn't
        -- trigger a forced full repaint when their item count < perpage.
        if self._zen_no_forced_repaint then return end
        local total   = #(self.item_table or {})
        if total == 0 then return end
        local perpage = self.perpage
        if not perpage or perpage <= 0 then return end
        local page          = self.page or 1
        local items_on_page = math.max(0, math.min(perpage, total - (page - 1) * perpage))
        local short_page = items_on_page > 0 and items_on_page < perpage
        if short_page and not pending then
            pending = true
            local widget = self
            local generation = self._zen_cover_hydration_generation
            UIManager:nextTick(function()
                pending = false
                if not is_enabled() or widget._zen_no_forced_repaint or (widget.page or 1) ~= page
                        or widget._zen_cover_hydration_generation ~= generation then return end
                UIManager:setDirty(nil, "full")
                UIManager:forceRePaint()
            end)
        end
    end

    -- 1. FileChooser class-level hook (classic mode, no coverbrowser).
    --    Also acts as a catch-all in case coverbrowser restores the original.
    if not FileChooser._zen_partial_page_patched then
        FileChooser._zen_partial_page_patched = true
        local orig = FileChooser.updateItems
        FileChooser.updateItems = function(self, ...)
            orig(self, ...)
            schedule_repaint(self)
        end
    end

    -- 2. CoverMenu hook (mosaic / detailed-list mode).
    --    Coverbrowser assigns CoverMenu.updateItems to FileChooser.updateItems
    --    at the class level, overwriting hook #1.  Wrapping CoverMenu directly
    --    means we stay in the call chain regardless of swapping order.
    local ok, CoverMenu = pcall(require, "covermenu")
    if ok and type(CoverMenu) == "table"
       and type(CoverMenu.updateItems) == "function"
       and not CoverMenu._zen_partial_page_patched then
        CoverMenu._zen_partial_page_patched = true
        local orig = CoverMenu.updateItems
        CoverMenu.updateItems = function(self, ...)
            orig(self, ...)
            schedule_repaint(self)
        end
    end
end

return apply_partial_page_repaint
