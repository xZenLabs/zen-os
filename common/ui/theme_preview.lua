-- Rounded reader-theme swatch showing sample text in the theme's colors.
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local ColorTextWidget = require("common/ui/color_text_widget")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local ReaderThemes = require("common/reader_themes")
local Screen = require("device").screen
local Size = require("ui/size")

local M = {}

-- opts: { plugin, key, theme?, width, height, face, radius? }; nil when colors are invalid.
function M.new(opts)
    local text_color, background_color = ReaderThemes.getPreviewColors(opts.plugin, opts.key, opts.theme)
    if not (text_color and background_color) then return nil end
    local padding = Screen:scaleBySize(4)
    local border = Size.border.thin
    local inner_w = math.max(1, opts.width - 2 * (padding + border))
    local inner_h = math.max(1, opts.height - 2 * (padding + border))
    return FrameContainer:new{
        width = opts.width,
        height = opts.height,
        padding = padding,
        margin = 0,
        bordersize = border,
        -- Defaults to the Zen button radius, clamped for short swatches.
        radius = math.min(opts.radius or Screen:scaleBySize(10), math.floor(opts.height / 2) - border),
        color = Blitbuffer.COLOR_DARK_GRAY,
        background = background_color,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            ColorTextWidget:new{
                text = "Aa Bb 123",
                max_width = inner_w,
                face = opts.face,
                fgcolor = text_color,
            },
        },
    }
end

return M
