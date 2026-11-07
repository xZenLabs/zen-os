local Blitbuffer = require("ffi/blitbuffer")
local BD = require("ui/bidi")
local Device = require("device")
local Event = require("ui/event")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local time = require("ui/time")
local util = require("util")
local Viewport = require("modules/reader/highlight_viewport")
local Screen = Device.screen

local Handles = {}
Handles.__index = Handles

function Handles.suppressReaderTaps(highlight)
    highlight._zen_highlight_tap_until = time.now() + time.ms(600)
end

local function samePosition(a, b)
    if type(a) ~= "table" then return a == b end
    return type(b) == "table" and a.page == b.page and a.x == b.x and a.y == b.y
end

function Handles:positions(item)
    if self.highlight.ui.paging and self.highlight.ui.document:comparePositions(item.pos0, item.pos1) < 0 then
        return item.pos1, item.pos0
    end
    return item.pos0, item.pos1
end

function Handles.available(highlight, index)
    local ui = highlight.ui
    local item = index and ui and ui.annotation.annotations[index] or highlight.selected_text
    local doc = ui and ui.document
    return Device:isTouchDevice() and item ~= nil and not item.text_edited
        and doc ~= nil and type(doc.getWordFromPosition) == "function"
        and type(doc.getTextFromPositions) == "function"
        and (ui.rolling and type(item.pos0) == "string" and type(item.pos1) == "string"
                and type(doc.compareXPointers) == "function"
            or ui.paging and type(item.pos0) == "table" and type(doc.comparePositions) == "function")
end

function Handles:boxes()
    local h, item = self.highlight, self.draft or self.item
    if h.ui.rolling then
        return h.ui.document:getScreenBoxesFromPositions(item.pos0, item.pos1, true)
    end
    local boxes = {}
    for _i, page in ipairs(h.view:getCurrentPageList()) do
        local part = item.ext and item.ext[page] or item.pos0.page == page and item
        local page_boxes = part and h.ui.document:getPageBoxesFromPositions(page, part.pos0, part.pos1)
        for _j, box in ipairs(page_boxes or {}) do
            local rect = h.view:pageToScreenTransform(page, box)
            if rect then
                boxes[#boxes + 1] = { x = rect.x, y = rect.y, w = rect.w, h = rect.h, page = page }
            end
        end
    end
    return boxes
end

function Handles:geometry()
    local h, item = self.highlight, self.draft or self.item
    local boxes = self:boxes()
    local pos0, pos1 = self:positions(item)
    local handles = {}
    if not boxes or #boxes == 0 then return handles end
    local r = Screen:scaleBySize(5)
    local top, bottom = Viewport.bounds(h)
    for side = 0, 1 do
        local box = side == 0 and boxes[1] or boxes[#boxes]
        local endpoint = side == 0 and pos0 or pos1
        local visible
        if h.ui.rolling then
            local y = h.ui.document:getScreenPositionFromXPointer(endpoint)
            visible = y and y >= top and y < bottom
                and (h.view.view_mode == "scroll" or h.ui.document:isXPointerInCurrentPage(endpoint))
        else
            visible = box.page == endpoint.page
        end
        if visible and box.y + box.h > top and box.y < bottom then
            local x = side == 0 and box.x or box.x + box.w
            if h.ui.rolling then
                local endpoint_x = select(2, h.ui.document:getScreenPositionFromXPointer(endpoint))
                if endpoint_x then
                    x = math.abs(endpoint_x - box.x) < math.abs(endpoint_x - box.x - box.w)
                        and box.x or box.x + box.w
                end
            end
            handles[side] = {
                x = math.max(r, math.min(h.screen_w - r, x)),
                y = math.max(top + r, math.min(bottom - r, side == 0 and box.y - r or box.y + box.h + r)),
                top = box.y, height = box.h, radius = r,
            }
        end
    end
    return handles
end

function Handles:paintTo(bb)
    local color = require("common/reader_themes").getTextColor(rawget(_G, "__ZEN_UI_PLUGIN"))
        or Blitbuffer.COLOR_BLACK
    local paint = Blitbuffer.isColor8(color) and bb.paintRect or bb.paintRectRGB32
    local circle = Blitbuffer.isColor8(color) and bb.paintRoundedRect or bb.paintRoundedRectRGB32
    for _side, knob in pairs(self:geometry()) do
        local x, y, r = math.floor(knob.x), math.floor(knob.y), knob.radius
        paint(bb, x - 1, knob.top, Screen:scaleBySize(2), knob.height, color)
        circle(bb, x - r, y - r, 2 * r, 2 * r, color, r)
    end
end

function Handles:hitTest(pos)
    if not pos then return end
    local menu = self.dialog.movable and self.dialog.movable.dimen
    if #self.dialog.buttons > 0 and menu and Geom:new{ x = pos.x, y = pos.y }:intersectWith(menu) then return end
    local target = Screen:scaleBySize(64)
    local nearest, distance
    for side, knob in pairs(self:geometry()) do
        local d = (pos.x - knob.x) ^ 2 + (pos.y - knob.y) ^ 2
        if d <= target ^ 2 and (not distance or d < distance) then
            nearest, distance = side, d
        end
    end
    return nearest
end

function Handles:dirtyRegion()
    local boxes = self:boxes() or {}
    local region = #boxes > 0 and Geom.boundingBox(boxes)
    local pad = Screen:scaleBySize(12)
    if region then
        return Geom:new{ x = math.max(0, region.x - pad), y = math.max(0, region.y - pad),
            w = math.min(self.highlight.screen_w, region.x + region.w + pad) - math.max(0, region.x - pad),
            h = math.min(self.highlight.screen_h, region.y + region.h + pad) - math.max(0, region.y - pad) }
    end
end

function Handles:refresh(old_region, normal)
    local h = self.highlight
    if h.ui.paging and not self.index then
        local item = self.draft or self.item
        h.view.highlight.temp = {}
        for _i, page in ipairs(h.view:getCurrentPageList()) do
            local part = item.ext and item.ext[page] or item.pos0.page == page and item
            if part then
                h.view.highlight.temp[page] = h.ui.document:getPageBoxesFromPositions(page, part.pos0, part.pos1)
            end
        end
    elseif self.index then
        h.view:resetHighlightBoxesCache({ self.item, self.draft or self.item })
    end
    local region = self:dirtyRegion()
    if old_region and region then region = old_region:combine(region) end
    local colored = Screen:isColorEnabled()
    UIManager:setDirty(h.dialog, (normal or colored) and "ui" or "fast", region, colored)
end

function Handles:begin(side, pos)
    self.side = side
    self.draft = util.tableDeepCopy(self.item)
    self.before = util.tableDeepCopy(self.item)
    self.draft.pos0, self.draft.pos1 = self:positions(self.draft)
    self.initial_pos0, self.initial_pos1 = self.draft.pos0, self.draft.pos1
    self.dragging = true
    local knob = self:geometry()[side]
    -- Keep the finger's grab offset while mapping the knob back to its text line.
    self.offset_x = knob and pos.x - knob.x or 0
    self.offset_y = knob and pos.y - (knob.top + knob.height / 2) or 0
    self.corner_armed, self.corner_entered = false, false
    self:corner(pos)
    UIManager:setDirty(self.highlight.dialog, "ui")
end

function Handles:pdfSelection(pos0, pos1)
    local h, doc = self.highlight, self.highlight.ui.document
    local reflow = doc.configurable.text_wrap
    doc.configurable.text_wrap = 0
    local ok, selection = pcall(function()
        if pos0.page == pos1.page then return doc:getTextFromPositions(pos0, pos1) end
        local ext, texts = {}, {}
        for page = pos0.page, pos1.page do
            local boxes = doc:getTextBoxes(page)
            if not boxes or #boxes == 0 then return end
            local part = h:getExtendedHighlightPage(pos0, pos1, page)
            if not part.pboxes or #part.pboxes == 0 then return end
            ext[page], texts[#texts + 1] = part, part.text
        end
        return { pos0 = pos0, pos1 = pos1, ext = ext, text = table.concat(texts, "\n") }
    end)
    doc.configurable.text_wrap = reflow
    if not ok then error(selection) end
    if selection and (selection.ext or selection.pboxes and #selection.pboxes > 0) then return selection end
end

function Handles:move(pos)
    local h, doc, draft = self.highlight, self.highlight.ui.document, self.draft
    self.last_pos = { x = pos.x, y = pos.y }
    local top, bottom = Viewport.bounds(h)
    local point = Geom:new{ x = math.max(0, math.min(h.screen_w - 1, pos.x - self.offset_x)),
        y = math.max(top, math.min(bottom - 1, pos.y - self.offset_y)) }
    local page_pos = h.view:screenToPageTransform(point)
    if not page_pos then return end
    local word = doc:getWordFromPosition(page_pos, true)
    if not word and h.ui.rolling and doc.getNearestWordAndBoxFromPosition then
        word = doc:getNearestWordAndBoxFromPosition(page_pos, 0)
    end
    if not word then return end
    local pos0, pos1 = draft.pos0, draft.pos1
    if h.ui.rolling then
        if self.side == 0 then pos0 = word.pos0 else pos1 = word.pos1 end
        if not pos0 or not pos1 then return end
        local order = doc:compareXPointers(pos0, pos1)
        if not order then return end
        if order <= 0 then
            if self.side == 0 then pos0 = doc:getPrevVisibleWordStart(draft.pos1)
            else pos1 = doc:getNextVisibleWordEnd(draft.pos0) end
            if not pos0 or not pos1 or doc:compareXPointers(pos0, pos1) ~= 1 then return end
        end
    else
        local endpoint = word.pos
        if not endpoint or not word.pbox then return end
        endpoint = util.tableDeepCopy(endpoint)
        endpoint.x, endpoint.y = word.pbox.x + word.pbox.w / 2, word.pbox.y + word.pbox.h / 2
        if self.side == 0 then pos0 = endpoint else pos1 = endpoint end
        if doc:comparePositions(pos0, pos1) < 0 then
            if self.side == 0 then pos0 = pos1 else pos1 = pos0 end
        end
    end
    if samePosition(pos0, draft.pos0) and samePosition(pos1, draft.pos1) then return end
    local old_region = self:dirtyRegion()
    if h.ui.rolling then
        draft.pos0, draft.pos1 = pos0, pos1
        draft.text = doc:getTextFromXPointers(pos0, pos1, not self.index)
        draft.sboxes = doc:getScreenBoxesFromPositions(pos0, pos1, true)
    else
        local selection = self:pdfSelection(pos0, pos1)
        if not selection then return end
        draft.pos0, draft.pos1 = selection.pos0, selection.pos1
        draft.text, draft.pboxes, draft.ext = selection.text, selection.pboxes, selection.ext
    end
    self:refresh(old_region)
end

function Handles:corner(pos)
    local h = self.highlight
    if h.allow_corner_scroll == false then return false end
    local mirrored = BD.mirroredUILayout()
    if h.view.inverse_reading_order then mirrored = not mirrored end
    local previous_x = mirrored and pos.x > 7/8*h.screen_w or not mirrored and pos.x < 1/8*h.screen_w
    local next_x = mirrored and pos.x < 1/8*h.screen_w or not mirrored and pos.x > 7/8*h.screen_w
    local direction = previous_x and pos.y < 1/8*h.screen_h and -1
        or next_x and pos.y > 7/8*h.screen_h and 1
    if not direction then
        self.corner_armed, self.corner_entered = true, false
        if self.corner_state then self.corner_state.was_in_some_corner = false end
        return false
    end
    if not self.corner_armed then return false end
    if self.corner_entered then return true end
    self.corner_entered = true
    local ui, doc = h.ui, h.ui.document
    if ui.rolling then
        if not self.corner_state then
            local fixed = self.side == 0 and self.initial_pos1 or self.initial_pos0
            local y, x = doc:getScreenPositionFromXPointer(fixed)
            self.corner_state = setmetatable({
                hold_pos = Geom:new{ x = x, y = y, page = doc:getCurrentPage() },
                selected_text_start_xpointer = fixed,
                allow_hold_pan_corner_scroll = true,
                was_in_some_corner = false,
                _resetHoldTimer = function() end,
            }, {
                __index = h,
                __newindex = function(state, key, value)
                    -- ReaderView must see the native restore guard during the mode switch.
                    if key == "restore_page_mode_func" then h[key] = value
                    else rawset(state, key, value) end
                end,
            })
        end
        self.corner_state:onHoldPan(nil, { pos = Geom:new{ x = pos.x, y = pos.y } })
        doc:getTextFromXPointers(self.draft.pos0, self.draft.pos1, not self.index)
    else
        local page = ui.paging.current_page
        if direction < 0 and page <= 1 or direction > 0 and page >= doc:getPageCount() then return true end
        ui.paging:onGotoViewRel(direction)
    end
    self:refresh(nil, true)
    return true
end

function Handles:finish()
    self.dragging = false
    local h, draft = self.highlight, self.draft
    local changed = not samePosition(draft.pos0, self.initial_pos0) or not samePosition(draft.pos1, self.initial_pos1)
    if self.index and changed then
        local doc = h.ui.document
        draft.text = util.cleanupSelectedText(draft.text)
        draft.page = h.ui.rolling and draft.pos0 or draft.pos0.page
        draft.pageno = h.ui.rolling and doc:getPageFromXPointer(draft.pos0) or draft.page
        draft.chapter = h.ui.toc:getTocTitleByPage(draft.page)
        draft.pageref = h.ui.annotation:getPageRef(draft.page, draft.pageno)
        if h.ui.rolling and doc.getEPubCFIRangeFromXPointers then
            draft.epubcfi = doc:getEPubCFIRangeFromXPointers(draft.pos0, draft.pos1)
        end
        h:writePdfAnnotation("delete", self.before)
        h:writePdfAnnotation("save", draft)
        for key in pairs(self.item) do self.item[key] = nil end
        for key, value in pairs(draft) do self.item[key] = value end
        if h.selected_text then h.selected_text = util.tableDeepCopy(self.item) end
        h.ui:handleEvent(Event:new("AnnotationsModified", { self.item, self.before }))
    elseif not self.index then
        draft._zen_resized = changed or draft._zen_resized
        h.selected_text = draft
        self.item = draft
        h.is_word_selection = false
        h.selected_text_start_xpointer = h.ui.rolling and draft.pos0 or nil
    end
    self.draft = nil
    self:refresh(nil, true)
    self.reopening = not self.index
    UIManager:close(self.dialog)
    self.reopen()
end

function Handles:gesture(ges)
    local kind = ges.ges
    if kind == "touch" then
        self.candidate = self:hitTest(ges.pos)
        self.touch_pos = ges.pos and { x = ges.pos.x, y = ges.pos.y }
        return self.candidate ~= nil
    elseif kind == "pan" or kind == "hold_pan" or kind == "hold" then
        if not self.dragging then
            local start = self.touch_pos or ges.start_pos or ges.pos
            local side = self.candidate
            if side == nil then side = self:hitTest(start) end
            if side == nil then return false end
            self:begin(side, start)
        end
        self.last_pos = { x = ges.pos.x, y = ges.pos.y }
        if not self:corner(ges.pos) then self:move(ges.pos) end
        return true
    elseif kind == "pan_release" or kind == "hold_release" or kind == "swipe" or kind == "multiswipe" then
        if kind == "swipe" and ges.end_pos and not self.dragging then
            local side = self:hitTest(ges.pos)
            if side == nil then return false end
            self:begin(side, ges.pos)
        end
        if not self.dragging then return false end
        local final_pos = kind == "swipe" and ges.end_pos
            or (kind == "pan_release" or kind == "hold_release") and ges.pos
        if final_pos and not self.corner_entered then self:move(final_pos) end
        self:finish()
        return true
    elseif kind == "tap" then
        self.touch_pos, self.candidate = nil, nil
        return self:hitTest(ges.pos) ~= nil
    end
    return false
end

function Handles:close()
    if self.closed then return end
    self.closed = true
    local h = self.highlight
    Handles.suppressReaderTaps(h)
    if not self.reopening and h.restore_page_mode_func then
        h.restore_page_mode_func()
        h.restore_page_mode_func = nil
    end
    if self.original_draw then h.view.drawSavedHighlight = self.original_draw end
    if self.index then h.view:resetHighlightBoxesCache() end
    if h.highlight_dialog == self.dialog then h.highlight_dialog = nil end
    if h._zen_highlight_handles == self then h._zen_highlight_handles = nil end
    self.dragging, self.draft = false, nil
    UIManager:setDirty(h.dialog, "ui")
end

function Handles.attach(highlight, dialog, index, reopen)
    if not Handles.available(highlight, index) then return end
    if highlight._zen_highlight_handles then highlight._zen_highlight_handles:close() end
    local self = setmetatable({ highlight = highlight, dialog = dialog, index = index, reopen = reopen,
        item = index and highlight.ui.annotation.annotations[index] or highlight.selected_text }, Handles)
    if next(self:geometry()) == nil then return end
    highlight._zen_highlight_handles = self
    if index then
        self.original_draw = highlight.view.drawSavedHighlight
        highlight.view.drawSavedHighlight = function(view, ...)
            if not self.dragging then return self.original_draw(view, ...) end
            local annotations = highlight.ui.annotation.annotations
            local original = annotations[index]
            annotations[index] = self.draft
            local ok, result = pcall(self.original_draw, view, ...)
            annotations[index] = original
            if not ok then error(result) end
            return result
        end
    end
    local paint, handle, close = dialog.paintTo, dialog.handleEvent, dialog.onCloseWidget
    if dialog.movable then
        dialog.movable.anchor = function()
            local boxes = self:boxes()
            local region = boxes and Geom.boundingBox(boxes)
            if not region then return { y = highlight.screen_h / 2 } end
            local pad = Screen:scaleBySize(14)
            local above = region.y - pad
            local below = highlight.screen_h - region.y - region.h - pad
            return { x = math.floor((highlight.screen_w - dialog:getContentSize().w) / 2),
                y = above, w = 0, h = region.h + 2 * pad }, below >= above
        end
    end
    dialog.paintTo = function(widget, bb, ...)
        if not self.dragging and #widget.buttons > 0 then paint(widget, bb, ...) end
        self:paintTo(bb)
    end
    dialog.handleEvent = function(widget, event)
        if event.handler == "onGesture" and self:gesture(event.args[1]) then return true end
        if event.handler == "onGesture" and event.args[1].ges == "tap" and #widget.buttons == 0 then
            return widget:onClose()
        end
        if event.handler == "onSetDimensions" or event.handler == "onCloseDocument" then
            UIManager:close(widget)
            return false
        end
        if self.dragging and (event.handler == "onKeyPress" or event.handler == "onClose") then
            self:close()
            if not self.index then highlight:clear() end
            UIManager:close(widget)
            return true
        end
        return handle(widget, event)
    end
    dialog.onCloseWidget = function(widget, ...)
        self:close()
        if close then return close(widget, ...) end
    end
    UIManager:setDirty(highlight.dialog, "ui", self:dirtyRegion())
    return self
end

return Handles
