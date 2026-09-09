local Blitbuffer = require("ffi/blitbuffer")
local Geom = require("ui/geometry")
local Screen = require("device").screen
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local ImageWidget = require("ui/widget/imagewidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Widget = require("ui/widget/widget")
local Font = require("ui/font")
local CoverUtils = require("common/cover_utils")
local RenderCache = require("common/cover_render_cache")

local M = {}
M.BORDER_SIZE = CoverUtils.BORDER_SIZE

function M.get_empty_message(source)
    return CoverUtils.getEmptyPlaceholderText(source)
end

local function get_uniform_ratio()
    return CoverUtils.getRatio()
end

function M.uniform_height_for_width(width)
    width = math.max(1, tonumber(width) or 1)
    return math.max(1, math.floor(width / get_uniform_ratio()))
end

local function calc_uniform_dims(max_w, max_h)
    local ratio = get_uniform_ratio()
    if max_h * ratio <= max_w then
        return math.floor(max_h * ratio), max_h
    end
    return max_w, math.floor(max_w / ratio)
end

local function rounded_enabled()
    local plug = rawget(_G, "__ZEN_UI_PLUGIN")
    if plug and type(plug.config) == "table"
       and type(plug.config.features) == "table"
    then
        return plug.config.features.browser_cover_rounded_corners == true
    end
    local cfg = require("config/manager").get()
    return type(cfg) == "table"
        and type(cfg.features) == "table"
        and cfg.features.browser_cover_rounded_corners == true
end
M.rounded_enabled = rounded_enabled

-- The four r-by-r corners are packed side-by-side in one small snapshot.
local function paint_corner_masks(bb, tx, ty, tw, th, r, snap, snap_r)
    for j = 0, r - 1 do
        local inner = math.sqrt(r * r - (r - j) * (r - j))
        local cut = math.ceil(r - inner)
        if cut > 0 then
            bb:blitFrom(snap, tx, ty + j, 0, j, cut, 1)
            bb:blitFrom(snap, tx + tw - cut, ty + j,
                snap_r * 2 - cut, j, cut, 1)
            bb:blitFrom(snap, tx, ty + th - 1 - j,
                snap_r * 2, snap_r - 1 - j, cut, 1)
            bb:blitFrom(snap, tx + tw - cut, ty + th - 1 - j,
                snap_r * 4 - cut, snap_r - 1 - j, cut, 1)
        end
    end
end

local function paint_corner_border_arcs(bb, tx, ty, tw, th, r, bsz, color)
    local r_outer = r
    local r_inner = r - bsz
    for j = 0, r - 1 do
        for c = 0, r - 1 do
            local dx = r - c - 0.5
            local dy = r - j - 0.5
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist >= r_inner and dist <= r_outer then
                bb:paintRect(tx + c, ty + j, 1, 1, color)
                bb:paintRect(tx + tw - 1 - c, ty + j, 1, 1, color)
                bb:paintRect(tx + c, ty + th - 1 - j, 1, 1, color)
                bb:paintRect(tx + tw - 1 - c, ty + th - 1 - j, 1, 1, color)
            end
        end
    end
end

local function paint_rect_border(bb, tx, ty, tw, th, bsz, color)
    for i = 0, bsz - 1 do
        bb:paintRect(tx + i, ty, 1, th, color)
        bb:paintRect(tx + tw - 1 - i, ty, 1, th, color)
        bb:paintRect(tx, ty + i, tw, 1, color)
        bb:paintRect(tx, ty + th - 1 - i, tw, 1, color)
    end
end

local function paint_rounded_border_edges(bb, tx, ty, tw, th, r, bsz, color)
    local x1 = tx + r
    local x2 = tx + tw - r
    local y1 = ty + r
    local y2 = ty + th - r
    if x2 > x1 then
        for i = 0, bsz - 1 do
            bb:paintRect(x1, ty + i, x2 - x1, 1, color)
            bb:paintRect(x1, ty + th - 1 - i, x2 - x1, 1, color)
        end
    end
    if y2 > y1 then
        for i = 0, bsz - 1 do
            bb:paintRect(tx + i, y1, 1, y2 - y1, color)
            bb:paintRect(tx + tw - 1 - i, y1, 1, y2 - y1, color)
        end
    end
end

local function apply_cover_border(frame)
    local orig_paintTo = frame.paintTo
    if type(orig_paintTo) ~= "function" then return end
    local base_radius = Screen:scaleBySize(8)
    frame.paintTo = function(self, bb, x, y)
        local rounded = rounded_enabled()
        -- For rounded corners we need the background that sits *behind* the
        -- cover so the corner cut-outs can reveal it. Snapshot the target rect
        -- before the cover paints over it.
        local snap, snap_r
        if rounded then
            local w, h = self:getSize().w, self:getSize().h
            if w and h and w > 0 and h > 0 then
                snap_r = math.min(base_radius, math.floor((math.min(w, h) - 1) / 2))
                if snap_r >= 2 then
                    snap = Blitbuffer.new(snap_r * 4, snap_r, bb:getType())
                    snap:blitFrom(bb, 0, 0, x, y, snap_r, snap_r)
                    snap:blitFrom(bb, snap_r, 0, x + w - snap_r, y, snap_r, snap_r)
                    snap:blitFrom(bb, snap_r * 2, 0, x, y + h - snap_r, snap_r, snap_r)
                    snap:blitFrom(bb, snap_r * 3, 0,
                        x + w - snap_r, y + h - snap_r, snap_r, snap_r)
                end
            end
        end
        orig_paintTo(self, bb, x, y)
        local d = self.dimen
        if not (d and d.w and d.h and d.w > 0 and d.h > 0) then
            if snap then snap:free() end
            return
        end
        local tx, ty, tw, th = d.x, d.y, d.w, d.h
        local bsz = math.max(1, self.bordersize or 0)
        local border_color = self._zen_cover_border_color or Blitbuffer.COLOR_BLACK
        if not rounded then
            paint_rect_border(bb, tx, ty, tw, th, bsz, border_color)
            return
        end
        local max_r = math.floor((math.min(tw, th) - 1) / 2)
        local r = math.min(base_radius, max_r)
        if r < 2 or not snap then
            paint_rect_border(bb, tx, ty, tw, th, bsz, border_color)
            if snap then snap:free() end
            return
        end
        paint_corner_masks(bb, tx, ty, tw, th, r, snap, snap_r)
        paint_rounded_border_edges(bb, tx, ty, tw, th, r, bsz, border_color)
        paint_corner_border_arcs(bb, tx, ty, tw, th, r, bsz, border_color)
        snap:free()
    end
end

function M.decorate_cover_frame(frame)
    if not frame or frame._zen_cover_frame_decorated then return frame end
    frame._zen_cover_frame_decorated = true
    if (frame.bordersize or 0) > 0 then
        apply_cover_border(frame)
    end
    return frame
end

function M.set_dimmed_border(frame, dimmed)
    if frame then
        frame._zen_cover_border_color = dimmed and Blitbuffer.COLOR_GRAY_6 or nil
    end
end

local function release_shared_on_free(widget, cache_key, cover_bb)
    if not widget or not cache_key or type(RenderCache.releaseShared) ~= "function" then return end
    local original_free = widget.free
    local released = false
    widget.free = function(self, ...)
        local result = original_free(self, ...)
        if not released then
            released = true
            RenderCache:releaseShared(cache_key, cover_bb)
        end
        return result
    end
end

local function free_bitmap(bb)
    if bb and bb.free then pcall(bb.free, bb) end
end

-- Avoid an ImageWidget rescale when a decoded buffer differs from its target
-- only because two cover paths rounded the same aspect ratio differently.
local function image_dims(bb, target_w, target_h)
    if not bb then return target_w, target_h end
    local ok, width, height = pcall(function()
        return bb:getWidth(), bb:getHeight()
    end)
    if ok and width and height
            and math.abs(width - target_w) <= 1
            and math.abs(height - target_h) <= 1 then
        return width, height
    end
    return target_w, target_h
end

function M.make_cover_widget(book, max_w, max_h, opts)
    opts = opts or {}
    local border = tonumber(opts.border) or M.BORDER_SIZE
    local bg = opts.background or Blitbuffer.COLOR_LIGHT_GRAY
    local target_w, target_h
    local source_w, source_h
    if opts.uniform == false and book then
        source_w, source_h = tonumber(book.cover_w), tonumber(book.cover_h)
        if (not source_w or source_w <= 0 or not source_h or source_h <= 0)
                and book.cover_bb then
            local ok, width, height = pcall(function()
                return book.cover_bb:getWidth(), book.cover_bb:getHeight()
            end)
            if ok then source_w, source_h = width, height end
        end
    end
    local preserve_aspect = source_w and source_w > 0 and source_h and source_h > 0
    if preserve_aspect then
        target_w, target_h = CoverUtils.fitDims(max_w, max_h, source_w, source_h)
    else
        target_w, target_h = calc_uniform_dims(max_w, max_h)
    end
    if preserve_aspect then
        target_w, target_h = math.max(1, target_w), math.max(1, target_h)
    else
        if target_w < 18 then target_w = 18 end
        if target_h < 28 then target_h = 28 end
    end

    local child
    local cover_bb
    local cache_owned = false
    local cache_key
    local needs_hydration = false
    if book and book.has_real_cover == true and book.path then
        cover_bb = RenderCache:getShared(book.path, target_w, target_h)
        cache_owned = cover_bb ~= nil
        cache_key = cache_owned and book.path or nil
        if not cover_bb and type(RenderCache.get) == "function" then
            cover_bb = RenderCache:get(book.path, target_w, target_h)
        end
        if cover_bb and book.cover_bb then
            free_bitmap(book.cover_bb)
            book.cover_bb = nil
        end
    end
    if not cover_bb and book and book.cover_bb then
        cover_bb = book.cover_bb
        book.cover_bb = nil
        if book.path then
            cover_bb, cache_owned = RenderCache:renderShared(
                book.path, cover_bb, target_w, target_h)
            cache_key = cache_owned and book.path or nil
        end
    end
    if cover_bb then
        local image_w, image_h = image_dims(cover_bb, target_w, target_h)
        child = ImageWidget:new{
            image = cover_bb,
            image_disposable = not cache_owned,
            width = image_w,
            height = image_h,
            scale_factor = 1,
        }
        if cache_owned then release_shared_on_free(child, cache_key, cover_bb) end
    elseif book and book.is_cover_pending then
        needs_hydration = true
        local generated = { CoverUtils.genCoverShared(
            "zen-cover-pending", target_w, target_h, true,
            { title = "", authors = "", title_only = true }
        ) }
        local fallback, fallback_w, fallback_h = generated[1], generated[2], generated[3]
        local shared, generated_key = generated[4], generated[5]
        if fallback then
            child = ImageWidget:new{
                image = fallback,
                image_disposable = not shared,
                width = fallback_w or target_w,
                height = fallback_h or target_h,
                scale_factor = 1,
            }
            if shared then release_shared_on_free(child, generated_key, fallback) end
        end
    elseif book and book.is_empty_placeholder then
        local generated = { CoverUtils.genCoverShared(
            "zen-empty-placeholder", target_w, target_h, true,
            { title = "", authors = "", title_only = true }
        ) }
        local fake_cover, shared, generated_key = generated[1], generated[4], generated[5]
        if fake_cover then
            child = ImageWidget:new{
                image = fake_cover,
                image_disposable = not shared,
                width = target_w,
                height = target_h,
                scale_factor = 1,
            }
            if shared then release_shared_on_free(child, generated_key, fake_cover) end
        end
    elseif book and type(book.path) == "string" and book.path ~= "" then
        local generated = { CoverUtils.genCoverShared(
            book.path, target_w, target_h, nil, book.bookinfo) }
        local fake_cover, shared, generated_key = generated[1], generated[4], generated[5]
        if fake_cover then
            child = ImageWidget:new{
                image = fake_cover,
                image_disposable = not shared,
                width = target_w,
                height = target_h,
                scale_factor = 1,
            }
            if shared then release_shared_on_free(child, generated_key, fake_cover) end
        end
    end
    if not child then
        child = Widget:new{
            dimen = Geom:new{ w = target_w, h = target_h },
        }
    end

    local frame = FrameContainer:new{
        width = target_w,
        height = target_h,
        padding = 0,
        bordersize = border,
        background = bg,
        CenterContainer:new{
            dimen = Geom:new{ w = target_w, h = target_h },
            child,
        },
    }

    if type(opts.decorate) == "function" then
        opts.decorate(frame)
    end
    return M.decorate_cover_frame(frame), target_w, target_h, needs_hydration
end

function M.make_empty_cover_widget(source, max_w, max_h, opts)
    local message = TextBoxWidget:new{
        text = M.get_empty_message(source),
        face = Font:getFace("smallinfofont", Screen:scaleBySize(10)),
        width = max_w,
        alignment = "center",
        alignment_strict = true,
        height_adjust = true,
    }
    local message_h = message:getSize().h
    local gap = math.max(2, Screen:scaleBySize(4))
    local cover, cover_w, cover_h = M.make_empty_placeholder_cover(
        max_w, math.max(1, max_h - message_h - gap), opts
    )

    return VerticalGroup:new{
        CenterContainer:new{
            dimen = Geom:new{ w = max_w, h = cover_h },
            cover,
        },
        VerticalSpan:new{ width = gap },
        CenterContainer:new{
            dimen = Geom:new{ w = max_w, h = message_h },
            message,
        },
    }, cover_w, cover_h + gap + message_h
end

function M.make_empty_placeholder_cover(max_w, max_h, opts)
    return M.make_cover_widget({ is_empty_placeholder = true }, max_w, max_h, opts)
end

return M
