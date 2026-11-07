local Blitbuffer = require("ffi/blitbuffer")
local Screen = require("device").screen
local Size = require("ui/size")
local IconItem = require("common/ui/icon_menu_item")

local M = {}

M.ICON_BASE_SIZE = 28
M.ICON_SIZE = Screen:scaleBySize(M.ICON_BASE_SIZE)
M.BUTTON_PADDING = Screen:scaleBySize(8)
M.BUTTON_SIZE = M.ICON_SIZE + 2 * M.BUTTON_PADDING
M.LEADING_WIDTH = IconItem.SETTINGS_ICON_WIDTH
M.TITLE_LEADING_PADDING = IconItem.getSettingsIconGap()
M.LEFT_PADDING = IconItem.getSettingsLeftPadding()
M.RIGHT_PADDING = Size.padding.large
M.ACTION_FONT_SIZE = 18
M.ACTION_PADDING_H = Size.padding.default
M.TRAILING_GAP = Screen:scaleBySize(4)
M.ROW_HEIGHT = math.max(M.BUTTON_SIZE, Screen:scaleBySize(42))
M.VERTICAL_PADDING = Screen:scaleBySize(6)
M.DIVIDER_HEIGHT = Screen:scaleBySize(2)
M.DIVIDER_COLOR = Blitbuffer.COLOR_LIGHT_GRAY
M.HEADER_CONTENT_HEIGHT = M.VERTICAL_PADDING * 2 + M.ROW_HEIGHT
M.HEADER_HEIGHT = M.HEADER_CONTENT_HEIGHT + M.DIVIDER_HEIGHT

function M.getTitleFace()
    return IconItem.getSettingsFace()
end

function M.getLeadingIconX(origin_x)
    return (origin_x or 0) + M.LEFT_PADDING
        + math.floor((M.LEADING_WIDTH - M.BUTTON_SIZE) / 2) + M.BUTTON_PADDING
end

function M.getTitleX(origin_x)
    return (origin_x or 0) + M.LEFT_PADDING + M.LEADING_WIDTH
        + M.TITLE_LEADING_PADDING
end

function M.getTrailingIconX(width, origin_x)
    return (origin_x or 0) + width - M.RIGHT_PADDING - M.BUTTON_PADDING - M.ICON_SIZE
end

function M.getStockIconSizeRatio()
    local defaults = rawget(_G, "G_defaults")
    local generic_size = defaults and type(defaults.readSetting) == "function"
        and tonumber(defaults:readSetting("DGENERIC_ICON_SIZE")) or nil
    return M.ICON_BASE_SIZE / (generic_size or 32)
end

-- Stock TitleBar aligns the title baseline with its icons; center the whole text block on them instead.
function M.centerStockTitle(title_bar)
    local button = title_bar.left_button or title_bar.right_button
    if not button then return end
    local icon_h = button.height
    local group = title_bar.title_group
    local text_h = group:getSize().h - group[1]:getSize().h
    local padding = math.max(0, math.floor(title_bar.button_padding + (icon_h - text_h) / 2))
    if padding ~= group[1]:getSize().h then
        title_bar.title_top_padding = padding
        title_bar:clear()
        title_bar:init()
    end
    -- Text taller than the icon box: lower the icons instead.
    local icon_top = padding + math.floor((text_h - icon_h) / 2)
    if icon_top <= title_bar.button_padding then return end
    for _k, icon in pairs({ title_bar.left_button, title_bar.right_button }) do
        icon.padding_top = icon_top
        icon.button:resetLayout()
        icon:update()
    end
end

function M.applyToStockTitleBar(title_bar)
    title_bar.title_face = M.getTitleFace()
    title_bar.left_icon_size_ratio = M.getStockIconSizeRatio()
    title_bar.right_icon_size_ratio = title_bar.left_icon_size_ratio
    title_bar.button_padding = M.BUTTON_PADDING
end

return M
