local Viewport = {}

function Viewport.isScrolling(view)
    local highlight = view.ui and view.ui.highlight
    return view.view_mode == "scroll" and highlight and highlight.restore_page_mode_func ~= nil
end

function Viewport.bounds(highlight)
    local doc = highlight.ui.document
    if highlight.ui.rolling and doc.getPageMargins
            and (highlight.view.view_mode == "page" or Viewport.isScrolling(highlight.view)) then
        local margins = doc:getPageMargins()
        local top, bottom = margins.top + doc:getHeaderHeight(), highlight.screen_h - margins.bottom
        if highlight.view and Viewport.isScrolling(highlight.view) then
            local position = doc:getCurrentPos()
            local cached = highlight._zen_highlight_viewport
            if cached and cached.position == position and cached.margin_top == top and cached.margin_bottom == bottom then
                return cached.top, cached.bottom
            end
            cached = { position = position, margin_top = top, margin_bottom = bottom }
            -- Scroll mode ignores vertical margins; keep only complete text lines inside them.
            for _i, edge in ipairs({ top, bottom }) do
                local line = doc:getTextFromPositions({ x = margins.left, y = edge },
                    { x = highlight.screen_w - margins.right - 1, y = edge }, true)
                for _j, box in ipairs(line and line.sboxes or {}) do
                    if box.y < edge and box.y + box.h > edge then
                        if _i == 1 then top = math.max(top, box.y + box.h)
                        else bottom = math.min(bottom, box.y) end
                    end
                end
            end
            local controller = highlight._zen_highlight_handles
            local item = controller and (controller.draft or controller.item) or highlight.selected_text
            -- Geometry queries replace CRe's selection even when drawing is disabled.
            if item then doc:getTextFromXPointers(item.pos0, item.pos1, not (controller and controller.index)) end
            cached.top, cached.bottom = top, bottom
            highlight._zen_highlight_viewport = cached
        end
        return top, bottom
    end
    return 0, highlight.screen_h
end

function Viewport.paintMargins(view, bb, x, y)
    if not Viewport.isScrolling(view) then return end
    local top, bottom = Viewport.bounds(view.ui.highlight)
    local color = view.document.buffer:getPixel(0, 0)
    local paint = require("ffi/blitbuffer").isColor8(color) and bb.paintRect or bb.paintRectRGB32
    paint(bb, x, y, view.dimen.w, top, color)
    paint(bb, x, y + bottom, view.dimen.w, view.dimen.h - bottom, color)
    if view.footer_visible then view.footer:paintTo(bb, x, y) end
end

return Viewport
