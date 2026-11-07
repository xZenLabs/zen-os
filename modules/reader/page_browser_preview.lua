local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Screen = require("device").screen
local Size = require("ui/size")
local Widget = require("ui/widget/widget")

local Preview = Widget:extend{}

function Preview:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
end

function Preview:invalidate()
    if self.bb then self.bb:free(); self.bb = nil end
    self.original_image = nil
end

function Preview:setPage(page)
    if self.page == page then return end
    self.page = page
    self:invalidate()
end

function Preview:render()
    local ui, page = self.ui, self.page
    local document = ui.document
    local width, height = self.width, self.height
    local saved_pos = ui.rolling and document:getCurrentPos()
    local state = {}
    for key, value in pairs(ui.view.state) do state[key] = value end
    state.page = page
    local view = setmetatable({ state = state }, { __index = ui.view })
    if self.fit_page and ui.paging then
        local size = document:getPageDimensions(page, 1, state.rotation)
        state.zoom = math.min(self.width / size.w, self.height / size.h)
        width, height = math.floor(size.w * state.zoom), math.floor(size.h * state.zoom)
        state.offset = { x = 0, y = 0 }
        view.dimen = Geom:new{ w = width, h = height }
        view.visible_area = Geom:new{ x = 0, y = 0, w = width, h = height }
        view.page_scroll = false
    end
    local bb = Blitbuffer.new(width, height, self.bb_type or Screen.bb:getType())
    local ok, err = pcall(function()
        bb:fill(ui.view.outer_page_color or Blitbuffer.COLOR_WHITE)
        view:drawPageSurround(bb, 0, 0)
        if ui.rolling then view:drawPageView(bb, 0, 0)
        else view:drawSinglePage(bb, 0, 0) end
        if view.highlight_visible then
            view.highlight = setmetatable({ page_boxes = {} }, { __index = ui.view.highlight })
            view:drawSavedHighlight(bb, 0, 0)
        end
        if self.fit_page and ui.rolling then
            local first = self.image_xpointer or document:getPageXPointer(page)
            local last = self.image_xpointer or document:getPageXPointer(page + 1)
            if not last or last == "" then
                local range = document._document:getTextFromPositions(0, 0, self.width - 1, self.height - 1,
                    false, false, true)
                first, last = range and range.pos0, range and range.pos1
            end
            local boxes = first and last and document._document:getWordBoxesFromPositions(first, last, true, true) or {}
            local left, top, right, bottom = self.width, self.height, 0, 0
            for _i, box in ipairs(boxes or {}) do
                left, top = math.min(left, box.x0), math.min(top, box.y0)
                right, bottom = math.max(right, box.x1), math.max(bottom, box.y1)
            end
            left, top = math.max(0, left), math.max(0, top)
            right, bottom = math.min(self.width, right), math.min(self.height, bottom)
            if right > left and bottom > top then
                local text = document._drawn_images_count == 1 and document:getTextFromXPointers(first, last, false)
                local image = (self.image_xpointer or text and not text:find("%S")) and document:getImageFromPosition{
                    x = (left + right) / 2, y = (top + bottom) / 2,
                }
                local cropped = image or bb:viewport(left, top, right - left, bottom - top):copy()
                bb:free()
                bb = cropped
                self.original_image = image and true or false
            end
        end
    end)
    if saved_pos then document:gotoPos(saved_pos) end
    if not ok then bb:free(); error(err, 0) end
    self.bb = bb
end

function Preview:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if not self.bb then self:render() end
    bb:blitFrom(self.bb, x, y, 0, 0, self.width, self.height)
    if self.focused then
        bb:paintBorder(x, y + self.top, self.width, self.height - self.top - self.bottom,
            Size.border.thick, Blitbuffer.COLOR_BLACK)
    end
end

function Preview:onFocus()
    self.focused = true
    return true
end

function Preview:onUnfocus()
    self.focused = false
    return true
end

Preview.free = Preview.invalidate

return Preview
