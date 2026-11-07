local ButtonDialog = require("ui/widget/buttondialog")
local Geom = require("ui/geometry")
local Screen = require("device").screen

local M = {}

function M.new(options)
    local inset = Screen:scaleBySize(8)
    local max_width = Screen:getWidth() - inset * 2
    local min_width = Screen:scaleBySize(220)
    local icon_size, gap = Screen:scaleBySize(24), Screen:scaleBySize(12)
    if options.rows_per_page and #options.buttons > options.rows_per_page then
        max_width = max_width - require("ui/widget/container/scrollablecontainer"):getScrollbarWidth()
    end
    local dialog
    local function anchor()
        local source, prefers_pop_down = options.anchor
        if type(source) == "function" then source, prefers_pop_down = source() end
        if not source or not options.anchor_right then return source, prefers_pop_down end
        local width = dialog.movable[1]:getSize().w
        return Geom:new{
            x = source.x + source.w - width - inset,
            y = source.y, w = width, h = source.h,
        }, prefers_pop_down
    end
    for _i, row in ipairs(options.buttons) do
        for _j, button in ipairs(row) do
            button.align = button.align or "left"
            if button.text and button.icon then
                local Size = require("ui/size")
                local label = require("ui/widget/textwidget"):new{ text = button.text,
                    face = require("ui/font"):getFace(button.font_face or "cfont", button.font_size or 20),
                    bold = button.font_bold ~= false }
                min_width = math.max(min_width, label:getSize().w + icon_size + gap
                    + (button.padding_h or Size.padding.large) * 2
                    + Size.border.window * 2 + Size.padding.button * 2)
                label:free()
            end
        end
    end
    dialog = ButtonDialog:new{
        title = options.title, buttons = options.buttons, rows_per_page = options.rows_per_page,
        tap_close_callback = options.close_callback,
        width = math.min(options.width or max_width, max_width),
        shrink_unneeded_width = not options.width,
        shrink_min_width = math.min(min_width, max_width),
        anchor = options.anchor and anchor or nil,
        _zen_anchor_source = options.anchor,
    }
    require("common/ui/button_labels").apply(dialog.buttontable, options.buttons, icon_size, gap)
    local ensure_anchor = dialog.movable.ensureAnchor
    function dialog.movable:ensureAnchor(x, y)
        ensure_anchor(self, x, y)
        self._moved_offset_x = math.max(inset,
            math.min(x + self._moved_offset_x, Screen:getWidth() - self.dimen.w - inset)) - x
        self._moved_offset_y = math.max(inset,
            math.min(y + self._moved_offset_y, Screen:getHeight() - self.dimen.h - inset)) - y
    end
    return dialog
end

return M
