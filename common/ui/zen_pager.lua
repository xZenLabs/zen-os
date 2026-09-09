-- common/zen_pager.lua
-- Shared page-indicator rendering used by zen_scroll_bar and zen_icon_picker.
-- All visual constants and config accessors live here; callers only paint.

local Blitbuffer = require("ffi/blitbuffer")
local Font       = require("ui/font")
local IconWidget = require("ui/widget/iconwidget")
local RenderText = require("ui/rendertext")
local Screen     = require("device").screen
local library_font = require("modules/filebrowser/patches/library_font")

local M = {}

-- Plugin reference captured via setPlugin() at apply time.
-- __ZEN_UI_PLUGIN is only set during run_feature; it's nil at paint time.
local _plugin = nil

function M.setPlugin(p)
    _plugin = p
end

-- Scaled constants (exported so callers can size tap zones and reservations).
M.BAR_H       = Screen:scaleBySize(5)
M.DOT_DIAM    = Screen:scaleBySize(10)
M.DOT_GAP     = Screen:scaleBySize(12)
M.BAR_PAD     = Screen:scaleBySize(5)
M.CHEV_W      = Screen:scaleBySize(60)
M.CHEV_HIT_W  = Screen:scaleBySize(96)
M.CHEV_HIT_PAD_BOTTOM = Screen:scaleBySize(24)
M.PN_ICON_SZ  = Screen:scaleBySize(36)
M.FOOTER_H    = math.max(M.BAR_H, M.DOT_DIAM) + M.BAR_PAD * 2
M.PN_FOOTER_H = math.max(M.FOOTER_H, M.PN_ICON_SZ + Screen:scaleBySize(6))
M.FOOTER_WIDTH_PCT = 0.92

local TRACK_COLOR = Blitbuffer.COLOR_LIGHT_GRAY
local THUMB_COLOR = Blitbuffer.COLOR_BLACK
local DOT_INACT   = Blitbuffer.COLOR_DARK_GRAY

local _pn_face, _pn_face_key
local _icon_l, _icon_r  -- lazy: only created when page_number style is first painted

local function get_pn_face()
    local base = Font.sizemap and Font.sizemap["xx_smallinfofont"] or 18
    local key = library_font.getFontName() .. ":" .. tostring(base)
    if _pn_face_key ~= key or not _pn_face then
        _pn_face = library_font.getFace(base)
        _pn_face_key = key
    end
    return _pn_face
end

local function get_pn_icons()
    if not _icon_l then
        _icon_l = IconWidget:new{ icon = "chevron.left",  width = M.PN_ICON_SZ, height = M.PN_ICON_SZ, alpha = true }
        _icon_r = IconWidget:new{ icon = "chevron.right", width = M.PN_ICON_SZ, height = M.PN_ICON_SZ, alpha = true }
    end
    return _icon_l, _icon_r
end

local function get_plugin()
    return _plugin or rawget(_G, "__ZEN_UI_PLUGIN")
end

-- Config accessors -- read live so style changes take effect on next repaint.

function M.getStyle()
    local p = get_plugin()
    if p and type(p.config) == "table" and type(p.config.zen_scroll_bar) == "table" then
        local s = p.config.zen_scroll_bar.style
        if s == "dots" or s == "bar" or s == "page_number" then return s end
    end
    return "page_number"
end

function M.getPageFormat()
    local p = get_plugin()
    if p and type(p.config) == "table" and type(p.config.zen_scroll_bar) == "table" then
        return p.config.zen_scroll_bar.page_number_format or "current"
    end
    return "current"
end

function M.getHoldSkip()
    local p = get_plugin()
    if p and type(p.config) == "table" and type(p.config.zen_scroll_bar) == "table" then
        return p.config.zen_scroll_bar.hold_skip or "10"
    end
    return "10"
end

function M.getCenteredFooterY(content_bottom, footer_y, footer_h, should_center)
    if not should_center
            or type(content_bottom) ~= "number"
            or type(footer_y) ~= "number"
            or type(footer_h) ~= "number" then
        return footer_y
    end
    local gap_h = footer_y + footer_h - content_bottom
    if gap_h > footer_h then
        return content_bottom + math.floor((gap_h - footer_h) / 2)
    end
    return footer_y
end

function M.getFooterGeometry(container_x, container_w)
    local width = math.floor(container_w * M.FOOTER_WIDTH_PCT)
    return container_x + math.floor((container_w - width) / 2), width
end

function M.getChevronHitWidth(footer_w)
    return math.min(footer_w / 2, M.CHEV_HIT_W or M.CHEV_W)
end

function M.getChevronHitBottom(footer_y, footer_h, available_bottom)
    local footer_bottom = footer_y + footer_h
    local hit_bottom = footer_bottom + M.CHEV_HIT_PAD_BOTTOM
    return math.max(footer_bottom, math.min(hit_bottom, available_bottom or hit_bottom))
end

-- Side hitboxes may extend below the painted footer; the center never does.
function M.getPageNumberZone(x, y, footer_x, footer_y, footer_w, footer_h, available_bottom)
    local footer_bottom = footer_y + footer_h
    local hit_bottom = M.getChevronHitBottom(footer_y, footer_h, available_bottom)
    if x < footer_x or x >= footer_x + footer_w
            or y < footer_y or y >= hit_bottom then
        return nil
    end
    local chevron_w = M.getChevronHitWidth(footer_w)
    if x < footer_x + chevron_w then return "left" end
    if x >= footer_x + footer_w - chevron_w then return "right" end
    if y < footer_bottom then return "center" end
end

-- Filled pill (stadium) shape via scanline paintRect.
function M.paintPill(bb, px, py, pw, ph, color)
    if pw <= 0 or ph <= 0 then return end
    local r = math.min(pw, ph) / 2.0
    for row = 0, ph - 1 do
        local dy    = (row + 0.5) - (ph * 0.5)
        local inset = 0
        if math.abs(dy) < r then
            inset = math.ceil(r - math.sqrt(r * r - dy * dy))
        end
        local rw = pw - 2 * inset
        if rw > 0 then bb:paintRect(px + inset, py + row, rw, 1, color) end
    end
end

-- Paint the page indicator at absolute screen position (x, y).
--   x, y      : top-left of the reserved footer strip
--   w         : available width
--   h         : reserved strip height (used for vertical centering)
--   cur_page,
--   total_pages : pagination state
-- No-ops silently when total_pages <= 1.
function M.paint(bb, x, y, w, h, cur_page, total_pages, force_style, mirrored)
    if total_pages <= 1 then return end
    local style = force_style or M.getStyle()

    if style == "dots" and total_pages <= 20 then
        local diam = M.DOT_DIAM
        local step = diam + M.DOT_GAP
        if step * total_pages - M.DOT_GAP > w then
            step = math.max(2, math.floor(w / total_pages))
            diam = math.max(1, step - 1)
        end
        local dots_w  = step * (total_pages - 1) + diam
        local start_x = x + math.floor((w - dots_w) / 2)
        local dot_y   = y + math.floor((h - diam) / 2)
        for i = 1, total_pages do
            local color = (i == cur_page) and THUMB_COLOR or DOT_INACT
            M.paintPill(bb, start_x + (i - 1) * step, dot_y, diam, diam, color)
        end

    elseif style == "page_number" then
        local pn_face  = get_pn_face()
        local fmt      = M.getPageFormat()
        local text_str = fmt == "total"
            and (tostring(cur_page) .. " / " .. tostring(total_pages))
            or  tostring(cur_page)
        local text_w   = RenderText:sizeUtf8Text(0, 9999, pn_face, text_str, true, false).x
        local face_h   = pn_face.bb_size or pn_face.size or Screen:scaleBySize(10)
        local base_y   = y + math.floor(h / 2 + face_h * 0.25)
        local inner_w  = w - M.CHEV_W * 2
        local text_x   = x + M.CHEV_W + math.floor((inner_w - text_w) / 2)
        RenderText:renderUtf8Text(bb, text_x, base_y, pn_face, text_str, false, false, THUMB_COLOR)
        local icon_y = y + math.floor((h - M.PN_ICON_SZ) / 2)
        local il, ir = get_pn_icons()
        if mirrored then il, ir = ir, il end
        il:paintTo(bb, x + math.floor((M.CHEV_W - M.PN_ICON_SZ) / 2), icon_y)
        ir:paintTo(bb, x + w - M.CHEV_W + math.floor((M.CHEV_W - M.PN_ICON_SZ) / 2), icon_y)

    else -- "bar" (default)
        M.paintPill(bb, x, y + M.BAR_PAD, w, M.BAR_H, TRACK_COLOR)
        local thumb_w = math.max(M.BAR_H * 2, math.floor(w / total_pages))
        thumb_w       = math.min(thumb_w, w)
        local travel  = w - thumb_w
        local pct     = (cur_page - 1) / math.max(1, total_pages - 1)
        local thumb_x = x + math.floor(pct * travel)
        M.paintPill(bb, thumb_x, y + M.BAR_PAD, thumb_w, M.BAR_H, THUMB_COLOR)
    end
end

return M
