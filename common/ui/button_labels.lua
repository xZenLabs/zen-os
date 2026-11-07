local M = {}

function M.prepare(buttons, width)
    local Screen = require("device").screen
    local Size = require("ui/size")
    local Font = require("ui/font")
    local TextWidget = require("ui/widget/textwidget")
    width = width or math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9)
        - 2 * (Size.border.window + Size.padding.button)
    local rows = {}
    for _i, row in ipairs(buttons) do
        local needed, labelled = Screen:scaleBySize(48), false
        for _j, spec in ipairs(row) do
            if spec.text and spec.icon then
                labelled = true
                spec.font_size, spec.font_bold = 16, false
                spec.icon_width, spec.icon_height = Screen:scaleBySize(20), Screen:scaleBySize(20)
                spec.height, spec.avoid_text_truncation = Screen:scaleBySize(32), false
                local label = TextWidget:new{ text = spec.text, face = Font:getFace("cfont", spec.font_size), bold = false }
                needed = math.max(needed, label:getSize().w + spec.icon_width
                    + Screen:scaleBySize(6) + 2 * Size.padding.button + Size.line.medium)
                label:free()
            end
        end
        local columns = labelled and math.max(1, math.floor(width / needed)) or #row
        for i = 1, #row, math.max(1, columns) do
            local next_row = {}
            for j = i, math.min(i + columns - 1, #row) do next_row[#next_row + 1] = row[j] end
            rows[#rows + 1] = next_row
        end
    end
    return rows
end

function M.alignIcon(icon, label)
    local size = label:getSize()
    local text = label:getFittedText()
    local bounds = require("ui/rendertext"):sizeUtf8Text(0, false, label.face, text, true, label.bold)
    -- Align with the visible letters, excluding the font's extra line spacing.
    local offset = math.floor(label:getBaseline() + (bounds.y_bottom - bounds.y_top - size.h) / 2 + 0.5)
    local paint = icon.paintTo
    icon.paintTo = function(widget, bb, x, y) return paint(widget, bb, x, y + offset) end
end

function M.applyButton(button, spec, icon_size, gap)
    local Screen = require("device").screen
    icon_size, gap = icon_size or Screen:scaleBySize(20), gap or Screen:scaleBySize(6)
    local padding = spec.padding_h or button.frame.padding_left
    local width = button.dimen.w - padding * 2
    button.frame.padding_left, button.frame.padding_right = padding, padding
    button.label_widget:setMaxWidth(math.max(1, width - icon_size - gap))
    if button.label_icon then button.label_icon:free() end
    button.label_icon = require("ui/widget/iconwidget"):new{
        icon = spec.icon, width = icon_size, height = icon_size, dim = button.enabled == false,
    }
    M.alignIcon(button.label_icon, button.label_widget)
    button.label_container.dimen.w = width
    button.label_container[1] = require("ui/widget/horizontalgroup"):new{
        button.label_icon, require("ui/widget/horizontalspan"):new{ width = gap }, button.label_widget,
    }
end

function M.apply(button_table, buttons, icon_size, gap)
    -- Native buttons choose text or an icon; keep their input handling and show both.
    for i, row in ipairs(button_table.buttons_layout) do
        for j, button in ipairs(row) do
            local spec = buttons[i][j]
            if spec.text and spec.icon then M.applyButton(button, spec, icon_size, gap) end
        end
    end
end

return M
