local Button = require("ui/widget/button")
local Screen = require("device").screen

local SliderStepButton = { width = Screen:scaleBySize(56) }

function SliderStepButton:new(opts)
    opts.width = opts.width or self.width
    opts.text_font_size = opts.text_font_size or Screen:scaleBySize(14)
    opts.text_font_face = require("modules/filebrowser/patches/library_font").getFontName()
    opts.text_font_bold, opts.bordersize, opts.allow_flash = false, 0, false
    return Button:new(opts)
end

return SliderStepButton
