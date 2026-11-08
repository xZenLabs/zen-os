-- Night mode: lighten highlights keep their day color and dark text instead of inverting with the page,
-- unless highlight_lookup.night_invert is on (stock behavior).
local function intersect(a, b)
    local x0, y0 = math.max(a.x, b.x), math.max(a.y, b.y)
    local x1, y1 = math.min(a.x + a.w, b.x + b.w), math.min(a.y + a.h, b.y + b.h)
    if x1 > x0 and y1 > y0 then return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 } end
end

-- Parts of rect not covered by any of the (disjoint) done rects.
local function uncovered(rect, done)
    local parts = { rect }
    for _i, d in ipairs(done) do
        local rest = {}
        for _j, p in ipairs(parts) do
            local o = intersect(p, d)
            if not o then
                rest[#rest + 1] = p
            else
                if o.y > p.y then rest[#rest + 1] = { x = p.x, y = p.y, w = p.w, h = o.y - p.y } end
                if o.y + o.h < p.y + p.h then
                    rest[#rest + 1] = { x = p.x, y = o.y + o.h, w = p.w, h = p.y + p.h - o.y - o.h }
                end
                if o.x > p.x then rest[#rest + 1] = { x = p.x, y = o.y, w = o.x - p.x, h = o.h } end
                if o.x + o.w < p.x + p.w then
                    rest[#rest + 1] = { x = o.x + o.w, y = o.y, w = p.x + p.w - o.x - o.w, h = o.h }
                end
            end
        end
        parts = rest
    end
    return parts
end

local function apply_night_highlights()
    local ReaderView = require("apps/reader/modules/readerview")
    if ReaderView._zen_night_highlights then return end
    ReaderView._zen_night_highlights = true
    local Blitbuffer = require("ffi/blitbuffer")
    local ReaderHighlight = require("apps/reader/modules/readerhighlight")
    local Screen = require("device").screen
    local plugin = rawget(_G, "__ZEN_UI_PLUGIN")

    -- Day-color highlights apply only in night mode with night_invert off.
    local function keep_day()
        if not Screen.night_mode then return false end
        local lookup = plugin and plugin.config and plugin.config.highlight_lookup
        return not (type(lookup) == "table" and lookup.night_invert == true)
    end

    -- CRe paints its selection under black text; in night mode draw it as a highlight instead.
    local orig_setSelectionColor = ReaderHighlight.setSelectionColor
    if orig_setSelectionColor then
        ReaderHighlight.setSelectionColor = function(self, ...)
            local result = orig_setSelectionColor(self, ...)
            self._zen_selection_night = keep_day()
            if self._zen_selection_night and not self.ui.paging then
                self.document._document:setStringProperty("crengine.highlight.selection.color", "#FFFFFF")
            end
            return result
        end
    end

    -- Rects already drawn in day colors this pass; overlaps must not be inverted twice.
    local done = {}

    local orig_paintTo = ReaderView.paintTo
    ReaderView.paintTo = function(self, ...)
        done = {}
        local hl = orig_setSelectionColor and self.ui.rolling and self.ui.highlight
        if not hl then return orig_paintTo(self, ...) end
        -- Night mode can flip without DeviceListener (e.g. schedules).
        local day = keep_day()
        if hl._zen_selection_night ~= day then hl:setSelectionColor() end
        local handles = hl._zen_highlight_handles
        local selected = handles and not handles.index and (handles.draft or handles.item) or hl.selected_text
        local selection = day and selected and selected.sboxes
        if not selection or next(self.highlight.temp) then return orig_paintTo(self, ...) end
        local temp = self.highlight.temp
        self.highlight.temp = { selection }
        local ok, result = pcall(orig_paintTo, self, ...)
        self.highlight.temp = temp
        if not ok then error(result, 0) end
        return result
    end

    local orig_drawSavedHighlight = ReaderView.drawSavedHighlight
    ReaderView.drawSavedHighlight = function(self, ...)
        done = {}
        return orig_drawSavedHighlight(self, ...)
    end

    local orig_drawHighlightRect = ReaderView.drawHighlightRect
    ReaderView.drawHighlightRect = function(self, bb, x, y, rect, drawer, color, draw_note_mark)
        if drawer ~= "lighten" or not keep_day() then
            return orig_drawHighlightRect(self, bb, x, y, rect, drawer, color, draw_note_mark)
        end
        local box = { x = rect.x, y = rect.y, w = rect.w, h = rect.h }
        local pct = G_reader_settings:readSetting("highlight_height_pct")
        if pct ~= nil then
            box.h = math.floor(rect.h * pct / 100)
            box.y = rect.y + math.ceil((rect.h - box.h) / 2)
        end
        -- Side marks sit outside the box and keep stock night colors.
        local side_mark = draw_note_mark ~= nil and self.highlight.note_mark ~= "underline"
        local mark = draw_note_mark
        if side_mark then mark = nil end
        local fresh = uncovered(box, done)
        if bb:getInverse() == 1 then
            -- Software night mode: highlight raw day pixels, shown as-is.
            for _i, r in ipairs(fresh) do bb:invertRect(r.x, r.y, r.w, r.h) end
            bb:setInverse(0)
            local ok, err = pcall(orig_drawHighlightRect, self, bb, x, y, rect, drawer, color, mark)
            bb:setInverse(1)
            if not ok then error(err, 0) end
        else
            -- Display inverts: restore overlaps to day pixels, highlight, then pre-invert.
            for _i, d in ipairs(done) do
                local o = intersect(box, d)
                if o then bb:invertRect(o.x, o.y, o.w, o.h) end
            end
            orig_drawHighlightRect(self, bb, x, y, rect, drawer, color, mark)
            bb:invertRect(box.x, box.y, box.w, box.h)
        end
        for _i, r in ipairs(fresh) do done[#done + 1] = r end
        if side_mark then orig_drawHighlightRect(self, bb, x, y, rect, nil, color, draw_note_mark) end
    end

    -- Color swatches come night-inverted so they show true; flip labels (and grays) to match the page.
    local ok_selector, ButtonSelector = pcall(require, "ui/widget/buttonselector")
    if ok_selector then
        local orig_init = ButtonSelector.init
        ButtonSelector.init = function(self, ...)
            local result = orig_init(self, ...)
            if not keep_day() then return result end
            for i, value in ipairs(self.values or {}) do
                local swatch = value[3] or self.bg_colors and self.bg_colors[i]
                local button = swatch and self:getButtonById(value[2])
                if button and button.label_widget then
                    if Blitbuffer.isColor8(swatch) then button[1].background = swatch:invert() end
                    button.label_widget.fgcolor = Blitbuffer.COLOR_WHITE
                end
            end
            return result
        end
    end
end

return apply_night_highlights
