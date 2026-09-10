local Background = require("common/ui/background")
local Blitbuffer = require("ffi/blitbuffer")
local CornerBanner = require("common/ui/corner_banner")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local FrameContainer = require("ui/widget/container/framecontainer")
local CenterContainer = require("ui/widget/container/centercontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local TopContainer = require("ui/widget/container/topcontainer")
local TextWidget = require("ui/widget/textwidget")
local TextBoxWidget = require("ui/widget/textboxwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local GestureRange = require("ui/gesturerange")
local OverlapGroup = require("ui/widget/overlapgroup")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local cover_common = require("modules/filebrowser/patches/home/widgets/cover_common")
local CoverUtils = require("common/cover_utils")
local FolderCover = require("modules/filebrowser/folder_cover")
local library_font = require("modules/filebrowser/patches/library_font")
local Font = require("ui/font")
local Device = require("device")
local MemoryPolicy = require("common/memory_policy")
local utils = require("common/utils")
local WidgetResources = require("common/widget_resources")
local BookOpenTap = require("common/book_open_tap")
local ButtonModel = require("common/nav_button_model")
local _ = require("gettext")
local logger = require("common/zen_logger").new("home_strip")

local M = {}
M.SIZE = { units = 2.5 }
local HYDRATE_DELAY_S = 0.05
local COVER_POLL_S = 0.4
local PRELOAD_DELAY_S = 0.35
local PRELOAD_TICK_S = 0.05
local PRELOAD_CHUNK = 4
local PRELOAD_BUDGET_S = 0.03
local MIN_RESPONSIVE_COVER_W = 100

local function cover_height_for_width(width)
    local ratio = type(CoverUtils.getRatio) == "function"
        and tonumber(CoverUtils.getRatio()) or 2 / 3
    return math.max(1, math.floor(width / math.max(0.1, ratio)))
end

local function responsive_per_row(width)
    local Screen = Device.screen
    local min_gap = math.max(6, math.min(
        Screen:scaleBySize(14), math.floor(width * 0.018)))
    local target_cover_w = math.max(24, Screen:scaleBySize(MIN_RESPONSIVE_COVER_W))
    return math.max(3, math.min(5,
        math.floor((width + min_gap) / (target_cover_w + min_gap))))
end

function M.max_books_for_width(outer_width, two_rows)
    local Screen = Device.screen
    outer_width = math.max(1, math.floor(tonumber(outer_width) or 1))
    local width = math.max(1, outer_width - Screen:scaleBySize(8) * 2)
    return responsive_per_row(width) * (two_rows == true and 2 or 1)
end

local function strip_layout_metrics(outer_width, module_cfg)
    outer_width = math.max(1, math.floor(tonumber(outer_width) or 1))
    module_cfg = type(module_cfg) == "table" and module_cfg or {}
    local Screen = Device.screen
    local controls = type(module_cfg.controls) == "table" and module_cfg.controls or {}
    local controls_enabled = controls.enabled == true
    local controls_height = controls_enabled and Screen:scaleBySize(30) or 0
    local controls_gap = controls_enabled and math.max(12, Screen:scaleBySize(18)) or 0
    local controls_top_gap = controls_gap
    local padding = Screen:scaleBySize(8)
    local width = math.max(1, outer_width - padding * 2)
    local two_rows = module_cfg.two_rows == true
    local vertical_padding = two_rows and 0 or math.max(2, Screen:scaleBySize(4))
    local count = tonumber(module_cfg.count) or (two_rows and 8 or 4)
    if two_rows then
        if count < 2 then count = 2 end
        if count > 10 then count = 10 end
    else
        if count < 3 then count = 3 end
        if count > 5 then count = 5 end
    end
    local rows = two_rows and 2 or 1
    count = math.min(count, responsive_per_row(width) * rows)
    local per_row = two_rows and math.ceil(count / 2) or count
    local strip_title_face = library_font.getFace(16)
    local title_h = 0
    local title_gap = 0
    if module_cfg.show_strip_titles == true then
        local probe = TextBoxWidget:new{
            text = "Ag",
            width = width,
            face = strip_title_face,
            bold = true,
        }
        title_h = probe:getSize().h
        WidgetResources.free(probe)
        if title_h < 1 then title_h = math.max(14, Screen:scaleBySize(12)) end
        title_gap = math.max(1, Screen:scaleBySize(2))
    end
    local row_gap = two_rows and math.max(3, Screen:scaleBySize(10)) or 0
    local screen_w = tonumber(Screen:getWidth()) or outer_width
    local screen_h = tonumber(Screen:getHeight()) or outer_width
    local short_side = math.max(1, math.min(screen_w, screen_h))
    local phone_shaped = math.max(screen_w, screen_h) / short_side >= 1.6
    return {
        controls_enabled = controls_enabled,
        controls_height = controls_height,
        controls_gap = controls_gap,
        controls_top_gap = controls_top_gap,
        padding = padding,
        vertical_padding = vertical_padding,
        width = width,
        two_rows = two_rows,
        count = count,
        rows = rows,
        per_row = per_row,
        row_gap = row_gap,
        row_top_pad = two_rows and 0 or math.max(4, Screen:scaleBySize(4)),
        row_bottom_pad = two_rows and 0 or math.max(4, Screen:scaleBySize(4)),
        row_inner_bottom_pad = two_rows and math.max(2, Screen:scaleBySize(4)) or 0,
        strip_title_face = strip_title_face,
        title_h = title_h,
        title_gap = title_gap,
        phone_shaped = phone_shaped,
    }
end

function M.preferred_height(outer_width, module_cfg)
    local metrics = strip_layout_metrics(outer_width, module_cfg)
    local Screen = Device.screen
    local min_gap = math.max(6, math.min(
        Screen:scaleBySize(14), math.floor(metrics.width * 0.018)))
    local cover_w = math.max(24, math.floor(
        (metrics.width - min_gap * (metrics.per_row - 1)) / metrics.per_row))
    local cover_h = math.max(28, cover_height_for_width(cover_w))
    return metrics.controls_top_gap + metrics.controls_height + metrics.controls_gap
        + metrics.vertical_padding * 2
        + metrics.row_top_pad + metrics.row_bottom_pad
        + metrics.rows * (cover_h + metrics.title_gap + metrics.title_h)
        + math.max(0, metrics.rows - 1)
            * (metrics.row_gap + metrics.row_inner_bottom_pad)
end

local function set_opening_banner_cover(cover)
    local set_cover = rawget(_G, "__ZEN_UI_SET_OPENING_BANNER_COVER")
    if type(set_cover) == "function" then set_cover(cover) end
end

-- ── Strip badge helpers ───────────────────────────────────────────────────────

local function get_zen_config(plugin)
    if plugin and type(plugin.config) == "table" then
        return plugin.config
    end
    local global_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    if global_plugin and type(global_plugin.config) == "table" then
        return global_plugin.config
    end
    local ok, ConfigManager = pcall(require, "config/manager")
    if ok and ConfigManager and type(ConfigManager.get) == "function" then
        return ConfigManager.get()
    end
end

local function paintPentagon(bb, bx, by, bw, bh, color)
    local rect_h = math.floor(bh * 30 / 42)
    local tip_h  = bh - rect_h
    bb:paintRectRGB32(bx, by, bw, rect_h, color)
    for row = 0, tip_h - 1 do
        local frac = (row + 1) / tip_h
        local rw   = math.max(2, math.floor(bw * (1 - frac)))
        local rx   = bx + math.floor((bw - rw) / 2)
        bb:paintRectRGB32(rx, by + rect_h + row, rw, 1, color)
    end
end

local function paintCheck(bb, bx, by, bw, bh, color)
    local tk = math.max(2, math.floor(math.min(bw, bh) / 8))
    local function drawLine(x0, y0, x1, y1)
        local steps = math.max(math.abs(x1 - x0), math.abs(y1 - y0))
        if steps == 0 then steps = 1 end
        for i = 0, steps do
            local t = i / steps
            bb:paintRectRGB32(math.floor(x0 + t*(x1-x0)), math.floor(y0 + t*(y1-y0)), tk, tk, color)
        end
    end
    local lx0 = bx + math.floor(bw * 0.08); local ly0 = by + math.floor(bh * 0.62)
    local lx1 = bx + math.floor(bw * 0.30); local ly1 = by + math.floor(bh * 0.82)
    drawLine(lx0, ly0, lx1, ly1)
    drawLine(lx1, ly1, bx + math.floor(bw * 0.82), by + math.floor(bh * 0.18))
end

local function paintCircle(bb, cx, cy, r, color)
    for row = -r, r do
        local hw = math.floor(math.sqrt(math.max(0, r*r - row*row)))
        if hw > 0 then bb:paintRectRGB32(cx - hw, cy + row, 2*hw, 1, color) end
    end
end

local function paintPill(bb, bx, by, bw, bh, color)
    local r = bh / 2
    for row = 0, bh - 1 do
        local dy = math.abs(row + 0.5 - r)
        local dx = math.sqrt(math.max(0, r*r - dy*dy))
        local x0 = math.ceil(bx + r - dx)
        local x1 = math.floor(bx + bw - r + dx)
        local w  = x1 - x0
        if w > 0 then bb:paintRectRGB32(x0, by + row, w, 1, color) end
    end
end

-- Wraps a cover FrameContainer paintTo to draw library-style decorations.
-- Metadata and collection state must be resolved before this paint path.
local function apply_strip_cover_decorations(frame, book, config, show_badges)
    local orig_paintTo = frame.paintTo
    if type(orig_paintTo) ~= "function" then return end

    -- per-item cache (lives on closure, one per cover widget)
    local _cached_pct_tw, _cached_pct_str, _cached_pct_fs, _cached_pct_dark
    local _cached_pause_tw, _cached_pause_icon, _cached_pause_fs, _cached_pause_dark
    local _cached_pages_tw, _cached_pages_str, _cached_pages_fs, _cached_pages_dark
    local _cached_series_tw, _cached_series_idx, _cached_series_fs, _cached_series_dark
    local _cached_fav_mark, _cached_fav_size, _cached_fav_dark

    local function get_fav_mark(size, is_dark)
        if _cached_fav_mark and _cached_fav_size == size and _cached_fav_dark == is_dark then
            return _cached_fav_mark
        end
        WidgetResources.free(_cached_fav_mark)
        _cached_fav_mark = TextWidget:new{
            text    = "\u{2606}",
            face    = Font:getFace("cfont", math.max(6, math.floor(size * 0.45))),
            fgcolor = is_dark and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK,
            padding = 0,
        }
        _cached_fav_size = size
        _cached_fav_dark = is_dark
        return _cached_fav_mark
    end

    local function free_badge_cache()
        WidgetResources.free(_cached_pct_tw)
        WidgetResources.free(_cached_pause_tw)
        WidgetResources.free(_cached_pages_tw)
        WidgetResources.free(_cached_series_tw)
        WidgetResources.free(_cached_fav_mark)
        _cached_pct_tw, _cached_pause_tw, _cached_pages_tw, _cached_series_tw, _cached_fav_mark = nil, nil, nil, nil, nil
    end

    WidgetResources.wrapFree(frame, free_badge_cache)

    frame.paintTo = function(self, bb, x, y)
        orig_paintTo(self, bb, x, y)

        local d = self.dimen
        if not (d and d.w and d.h and d.w > 0 and d.h > 0) then return end

        local border = self.bordersize or 0
        local cover_badges = type(config) == "table" and type(config.browser_cover_badges) == "table"
            and config.browser_cover_badges or {}
        local dim_finished = cover_badges.dim_finished_books == true
            and book.status == "complete"
        cover_common.set_dimmed_border(self, dim_finished)

        local cov_w = d.w - 2 * border
        local cov_h = d.h - 2 * border
        if cov_w <= 0 or cov_h <= 0 then return end
        if dim_finished then
            bb:lightenRect(x + border, y + border, cov_w, cov_h, 0.4)
        end
        if not show_badges then return end

        local badge_col   = utils.getBadgeColor(config)
        local badge_fg    = utils.getBadgeTextColor(config)
        local outline     = badge_fg
        local is_dark     = utils.isBadgeDark(config)
        local badge_scale = utils.getBadgeScale(config)
        local show_favorite = cover_badges.show_favorite_badge == true
        local show_new = cover_badges.show_new_banner == true
        local show_progress = cover_badges.show_mosaic_progress == true
        local show_pages = type(config) == "table"
            and type(config.browser_page_count) == "table"
            and config.browser_page_count.show_page_count == true
        local show_series = type(config) == "table"
            and type(config.browser_series_badge) == "table"
            and config.browser_series_badge.show_series_badge == true

        local ScreenDev = Device.screen
        local base_sz   = math.floor(math.max(ScreenDev:scaleBySize(20),
                            math.floor(d.w * 0.14)) * badge_scale)

        -- favorite: top-left circle with star
        if show_favorite and book.is_fav == true then
            local r      = math.floor(base_sz * 0.45)
            local inset  = utils.getBadgeInset(r)
            local cx     = x + border + r + inset
            local cy     = y + border + r + inset
            paintCircle(bb, cx, cy, r + 2, outline)
            paintCircle(bb, cx, cy, r,     badge_col)
            local mark = get_fav_mark(r * 2, is_dark)
            local msz  = mark:getSize()
            mark:paintTo(bb, cx - math.ceil(msz.w/2), cy - math.ceil(msz.h/2))
        end

        -- progress/status: top-right pentagon
        local pct    = type(book.percent) == "number" and book.percent or 0
        local status = book.status
        local is_new = status == "new"
        local do_check = status == "complete" and not dim_finished
        local do_tbr = (status == "tbr")
        local do_pause = (status == "abandoned")
        local do_pct   = not is_new and not do_check and not do_tbr and not do_pause and pct > 0

        if show_progress and (do_check or do_tbr or do_pause or do_pct) then
            local bw  = math.floor(base_sz * 1.2)
            local bh  = math.floor(base_sz * 1.1)
            local bdg_x = x + d.w - bw - math.floor(bw * 0.25)
            local bdg_y = y + 2
            paintPentagon(bb, bdg_x - 2, bdg_y - 2, bw + 4, bh + 4, outline)
            paintPentagon(bb, bdg_x,     bdg_y,     bw,     bh,     badge_col)
            bb:paintRect(bdg_x - 2, bdg_y - 2, bw + 4, math.max(1, border), self.color or Blitbuffer.COLOR_BLACK)

            local rect_h = math.floor(bh * 30 / 42)
            local pad_x  = math.floor(bw * 0.12)
            local pad_y  = math.floor(rect_h * 0.15)
            local icon_x = bdg_x + pad_x
            local icon_y = bdg_y + pad_y
            local icon_w = bw - 2 * pad_x
            local icon_h = rect_h - 2 * pad_y

            if do_check then
                local sq   = math.min(icon_w, icon_h)
                paintCheck(bb, icon_x + math.floor((icon_w-sq)/2),
                               icon_y + math.floor((icon_h-sq)/2), sq, sq, badge_fg)
            elseif do_tbr or do_pause then
                local fs = math.max(7, math.floor(base_sz * 0.40))
                local icon = do_tbr and "\u{F0150}" or "\u{F03E4}"
                if not _cached_pause_tw or _cached_pause_icon ~= icon
                        or _cached_pause_fs ~= fs or _cached_pause_dark ~= is_dark then
                    WidgetResources.free(_cached_pause_tw)
                    _cached_pause_tw   = TextWidget:new{
                        text = icon,
                        face = Font:getFace("cfont", fs),
                        fgcolor = badge_fg,
                        padding = 0,
                    }
                    _cached_pause_icon = icon
                    _cached_pause_fs   = fs
                    _cached_pause_dark = is_dark
                end
                local tsz = _cached_pause_tw:getSize()
                _cached_pause_tw:paintTo(bb, bdg_x + math.floor((bw-tsz.w)/2), bdg_y + math.floor((rect_h-tsz.h)/2))
            else
                local pct_str = math.floor(100 * pct) .. "%"
                local fs = math.max(7, math.floor(base_sz * 0.24))
                if not _cached_pct_tw or _cached_pct_str ~= pct_str or _cached_pct_fs ~= fs or _cached_pct_dark ~= is_dark then
                    WidgetResources.free(_cached_pct_tw)
                    _cached_pct_tw   = TextWidget:new{ text=pct_str, face=Font:getFace("cfont",fs), bold=true, fgcolor=badge_fg, padding=0 }
                    _cached_pct_str  = pct_str
                    _cached_pct_fs   = fs
                    _cached_pct_dark = is_dark
                end
                local tsz = _cached_pct_tw:getSize()
                _cached_pct_tw:paintTo(bb, bdg_x + math.floor((bw-tsz.w)/2), bdg_y + math.floor((rect_h-tsz.h)/2))
            end
        end

        -- page count: bottom-left pill
        local pages = tonumber(book.stable_pages) or tonumber(book.pages)
        if show_pages and pages and pages > 0 then
            local page_str = utils.formatPageCount(pages)
            local fs = math.max(7, math.floor(base_sz * 0.24))
            if not _cached_pages_tw or _cached_pages_str ~= page_str or _cached_pages_fs ~= fs or _cached_pages_dark ~= is_dark then
                WidgetResources.free(_cached_pages_tw)
                _cached_pages_tw   = TextWidget:new{ text=page_str, face=Font:getFace("cfont",fs), bold=true, fgcolor=badge_fg, padding=0 }
                _cached_pages_str  = page_str
                _cached_pages_fs   = fs
                _cached_pages_dark = is_dark
            end
            local tsz   = _cached_pages_tw:getSize()
            local bh    = math.floor(base_sz * 0.85)
            local h_pad = math.floor(base_sz * 0.12)
            local bw    = tsz.w + 2 * h_pad
            local inset = utils.getBadgeInset(math.floor(bh / 2))
            local bx    = x + inset
            local by    = y + d.h - bh - inset
            paintPill(bb, bx - 2, by - 2, bw + 4, bh + 4, outline)
            paintPill(bb, bx,     by,     bw,     bh,     badge_col)
            _cached_pages_tw:paintTo(bb, bx + math.floor((bw-tsz.w)/2), by + math.floor((bh-tsz.h)/2))
        end

        -- series: bottom-right circle
        if show_series then
            local series_idx = tonumber(book.series_index)
            if series_idx and series_idx > 0 then
                local idx_str
                if series_idx == math.floor(series_idx) then
                    idx_str = "#" .. tostring(math.floor(series_idx))
                else
                    idx_str = "#" .. string.format("%.1f", series_idx)
                end
                local r    = math.floor(base_sz / 2)
                local fs   = math.max(7, math.floor(base_sz * 0.26))
                if not _cached_series_tw or _cached_series_idx ~= series_idx or _cached_series_fs ~= fs or _cached_series_dark ~= is_dark then
                    WidgetResources.free(_cached_series_tw)
                    local inner_w = math.floor(r * 1.30)
                    local function make_tw(label, sz)
                        return TextWidget:new{ text=label, face=Font:getFace("cfont",sz), bold=true, fgcolor=badge_fg, padding=0 }
                    end
                    local tw = make_tw(idx_str, fs)
                    if tw:getSize().w > inner_w then
                        WidgetResources.free(tw)
                        local no_hash = idx_str:sub(1,1) == "#" and idx_str:sub(2) or idx_str
                        local tw2 = make_tw(no_hash, fs)
                        if tw2:getSize().w <= inner_w then
                            tw = tw2
                        else
                            WidgetResources.free(tw2)
                            local sz = fs
                            while sz > 7 do
                                local t = make_tw(no_hash, sz)
                                if t:getSize().w <= inner_w then tw = t; break end
                                WidgetResources.free(t)
                                sz = sz - 1
                            end
                            if not tw then tw = make_tw(no_hash, 7) end
                        end
                    end
                    _cached_series_tw   = tw
                    _cached_series_idx  = series_idx
                    _cached_series_fs   = fs
                    _cached_series_dark = is_dark
                end
                local inset = utils.getBadgeInset(r)
                local cx = x + d.w - r - inset
                local cy = y + d.h - r - inset
                paintCircle(bb, cx, cy, r + 2, outline)
                paintCircle(bb, cx, cy, r,     badge_col)
                local tsz = _cached_series_tw:getSize()
                _cached_series_tw:paintTo(bb, cx - math.floor(tsz.w/2), cy - math.floor(tsz.h/2))
            end
        end

        if show_new and is_new then
            local span = math.floor(base_sz * 2.5)
            local band_thick = math.floor(span * 0.35)
            local font_size = math.max(6, math.floor(base_sz * 0.25))
            CornerBanner.paint(
                bb, x, x + d.w, y, d.h,
                span, band_thick, _("New"), font_size, badge_col, badge_fg
            )
            if border > 0 then
                local border_color = self.bordercolor or Blitbuffer.COLOR_BLACK
                bb:paintRect(x, y, d.w, border, border_color)
                bb:paintRect(x + d.w - border, y, border, d.h, border_color)
            end
        end
    end
end

function M.build_strip(ctx, source_key)
    local outer_width = ctx.width
    local total_outer_height = ctx.height
    local Screen = Device.screen
    local module_cfg = type(ctx.module_cfg) == "table" and ctx.module_cfg or {}
    local metrics = strip_layout_metrics(outer_width, module_cfg)
    local controls_cfg = type(module_cfg.controls) == "table" and module_cfg.controls or {}
    local controls_enabled = metrics.controls_enabled
    local controls_height = metrics.controls_height
    local controls_gap = metrics.controls_gap
    local controls_top_gap = metrics.controls_top_gap
    local controls_and_gap = controls_height + controls_gap
    local outer_height = math.max(1, total_outer_height - controls_and_gap)
    local width = metrics.width
    local height = math.max(
        1, outer_height - metrics.vertical_padding * 2 - controls_top_gap)
    local runtime = ctx.menu and ctx.menu._zen_home_strip_runtime
    local runtime_created = false
    local function default_source()
        if controls_enabled then
            local first_source = ButtonModel.firstVisibleSource(controls_cfg)
            if first_source then return utils.deepcopy(first_source) end
        end
        local configured = type(module_cfg.default_source) == "table"
            and module_cfg.default_source or { kind = "recent" }
        if configured.kind == "kindle" and not ButtonModel.isAvailable("kindle") then
            return { kind = "recent" }
        end
        return utils.deepcopy(configured)
    end
    if type(runtime) ~= "table" then
        runtime = { source = default_source() }
        if source_key then
            runtime.source = { kind = source_key == "recently_read" and "recent"
                or source_key == "custom_strip" and "custom" or source_key }
        end
        if ctx.menu then ctx.menu._zen_home_strip_runtime = runtime end
        runtime_created = true
    end
    local source = runtime.source or { kind = "recent" }
    if type(source) ~= "table" then source = { kind = "recent" } end
    local source_name = source.kind == "recent" and "recently_read"
        or source.kind == "custom" and "custom_strip" or source.kind
    local order = module_cfg.order or "default"
    local two_rows = metrics.two_rows
    -- Keep the painted cover borders inside the controls inset.
    local cover_row_width = math.max(1, width - cover_common.BORDER_SIZE * 2)
    local per_row = metrics.per_row
    local count = metrics.count
    local wants_strip_titles = module_cfg.show_strip_titles == true
    local show_badges = module_cfg.show_badges == true
    local strip_config = type(ctx.zen_config) == "table" and ctx.zen_config
        or get_zen_config(rawget(_G, "__ZEN_UI_PLUGIN")) or {}
    local cover_badges = type(strip_config.browser_cover_badges) == "table"
        and strip_config.browser_cover_badges or {}
    local decorate_covers = show_badges or cover_badges.dim_finished_books == true
    local center_books = module_cfg.center_books == true
    local interactive = module_cfg.interactive ~= false
    local page_cache = {}
    local has_adjacent_pages = false
    local hydration_failed_paths = {}
    local visual_shift = 0
    local controls_visual_top = 0

    local function get_page_books(page_delta)
        if type(ctx.data.getStripItemsForPage) == "function" then
            local books, has_adjacent = ctx.data:getStripItemsForPage(
                source, count, order, ctx.component_id, page_delta)
            has_adjacent_pages = has_adjacent == true
            return books
        end
        if type(ctx.data.getBooksForStripPage) == "function" then
            local books, has_adjacent = ctx.data:getBooksForStripPage(
                source_name, count, order, ctx.component_id, page_delta)
            has_adjacent_pages = has_adjacent == true
            return books
        end
        if page_delta == 0 then
            return ctx.data:getBooksForStrip(source_name, count, order, ctx.component_id)
        end
        return nil
    end

    local function rebuild_home()
        if ctx.menu and type(ctx.menu._home_rebuild) == "function" then
            runtime._locked_visual_shift = tonumber(runtime._visual_shift) or 0
            ctx.menu:_home_rebuild()
            return true
        end
        return false
    end

    local function reset_strip_pages()
        if type(ctx.data.resetStripPages) == "function" then
            ctx.data:resetStripPages()
        end
    end

    local function descriptors_match(a, b)
        return type(a) == "table" and type(b) == "table"
            and a.kind == b.kind and a.value == b.value
    end

    local function parent_descriptor_matches(descriptor, current_source)
        return type(descriptor) == "table" and type(current_source) == "table"
            and descriptor.kind == "tags" and current_source.kind == "tag"
    end

    local function visible_source_entry(id)
        local entry = controls_cfg.show_buttons and controls_cfg.show_buttons[id]
            and ButtonModel.find(controls_cfg, id) or nil
        return entry and ButtonModel.isAvailable(entry) and entry or nil
    end

    local function find_source_control(parent_match)
        for _i, id in ipairs(controls_cfg.order or {}) do
            local entry = visible_source_entry(id)
            local descriptor = entry and ButtonModel.sourceDescriptor(entry)
            local matches = parent_match and parent_descriptor_matches(descriptor, source)
                or not parent_match and descriptors_match(descriptor, source)
            if matches then return id end
        end
    end

    local runtime_repaired = false
    if runtime.active_id ~= nil then
        local entry = visible_source_entry(runtime.active_id)
        local descriptor = entry and ButtonModel.sourceDescriptor(entry)
        if not descriptors_match(descriptor, source)
                and not parent_descriptor_matches(descriptor, source) then
            runtime.active_id = nil
            source = default_source()
            runtime.source = source
            source_name = source.kind == "recent" and "recently_read"
                or source.kind == "custom" and "custom_strip" or source.kind
            runtime_repaired = true
        end
    end
    if runtime.active_id == nil then
        runtime.active_id = find_source_control(false) or find_source_control(true)
    end

    local function remember_strip_state()
        if type(ctx.rememberStripState) == "function" then
            ctx.rememberStripState(runtime)
        end
    end

    if runtime_created or runtime_repaired then
        remember_strip_state()
    end

    local active_group = source.drill and source.drill.label or nil
    if active_group == nil and source.kind == "tag" and runtime.active_id == "tags" then
        active_group = source.value
    end

    ctx.openStripGroup = function(book)
        if type(book) ~= "table" or book.is_group ~= true then return false end
        reset_strip_pages()
        source.drill = {
            label = book.group_label,
            files = utils.deepcopy(book.group_files or {}),
        }
        runtime.source = source
        remember_strip_state()
        return rebuild_home()
    end

    local shift_strip_page
    local controls_widget
    local control_targets = {}
    if controls_enabled then
        local config = get_zen_config(rawget(_G, "__ZEN_UI_PLUGIN")) or {}
        local features = type(config.features) == "table" and config.features or {}
        local StripControls = require(
            "modules/filebrowser/patches/home/widgets/strip_controls")
        controls_widget, control_targets = StripControls.build{
            width = width,
            height = controls_height,
            controls = controls_cfg,
            rounded = features.browser_cover_rounded_corners == true,
            active_id = runtime.active_id,
            active_group = active_group,
            prepare_focus = ctx.prepareHomeFocusTarget,
            on_source = function(entry)
                if runtime.active_id == entry.id then
                    if source.drill then
                        reset_strip_pages()
                        source.drill = nil
                        runtime.source = source
                        remember_strip_state()
                        return rebuild_home()
                    end
                    return true
                end
                local descriptor = ButtonModel.sourceDescriptor(entry)
                if not descriptor then return false end
                reset_strip_pages()
                runtime.source = utils.deepcopy(descriptor)
                runtime.active_id = entry.id
                remember_strip_state()
                return rebuild_home()
            end,
            on_action = function(entry)
                if entry.id == "page_left" or entry.id == "page_right" then
                    local direction = entry.id == "page_left" and "previous" or "next"
                    return type(shift_strip_page) == "function"
                        and shift_strip_page(direction) or false
                end
                return ButtonModel.execute(entry)
            end,
            on_hold = ctx.editMode == true and function()
                return type(ctx.openWidgetSettings) == "function"
                    and ctx.openWidgetSettings() == true
            end or nil,
        }
    end

    local function add_control_targets(targets)
        if #control_targets == 0 then return targets end
        local combined = {}
        for _i, target in ipairs(control_targets) do combined[#combined + 1] = target end
        for _i, target in ipairs(targets or {}) do combined[#combined + 1] = target end
        return combined
    end

    local function set_visual_bounds(page_delta, visual_top, visual_bottom)
        local base_shift = controls_enabled and controls_top_gap - visual_top or 0
        local adjusted_top = visual_top + base_shift
        if page_delta ~= 0 then return base_shift, adjusted_top end
        controls_visual_top = adjusted_top
        if type(ctx.setContentBounds) == "function" then
            local group_bottom = controls_and_gap + visual_bottom + base_shift
            local locked_shift = tonumber(runtime._locked_visual_shift)
            if locked_shift then
                local natural_max = total_outer_height - group_bottom
                locked_shift = math.min(natural_max, locked_shift)
            end
            ctx.setContentBounds{
                top = adjusted_top,
                bottom = group_bottom,
                min_shift = locked_shift or -adjusted_top,
                max_shift = locked_shift or total_outer_height - group_bottom,
                lock_shift = locked_shift ~= nil,
                bottom_anchor_offset = controls_enabled
                    and math.max(0, tonumber(ctx.row_gap_above) or 0) or 0,
                set_shift = function(shift)
                    visual_shift = shift
                    runtime._visual_shift = shift
                    runtime._locked_visual_shift = nil
                end,
            }
        end
        return base_shift, adjusted_top
    end

    local function build_frame(page_delta, supplied_books)
        local started_at = os.clock()
        local show_strip_titles = wants_strip_titles
        local books = supplied_books or get_page_books(page_delta or 0) or {}
        local cover_plans = {}
        if #books == 0 then
        local empty_cover, cover_w, cover_h = cover_common.make_empty_placeholder_cover(
            width, height,
            { border = cover_common.BORDER_SIZE, background = Blitbuffer.COLOR_LIGHT_GRAY }
        )
        local gap = math.max(4, Screen:scaleBySize(8))
        local message_w = math.max(1, width - cover_w - gap)
        local empty_message = TextBoxWidget:new{
            text = cover_common.get_empty_message(source_name),
            face = Font:getFace("smallinfofont", Screen:scaleBySize(10)),
            width = message_w,
            alignment = "left",
            alignment_strict = true,
            height_adjust = true,
        }
        local empty_row = HorizontalGroup:new{
            empty_cover,
            HorizontalSpan:new{ width = gap },
            CenterContainer:new{
                dimen = Geom:new{ w = message_w, h = cover_h },
                empty_message,
            },
        }
        local empty_top = math.floor(math.max(0, outer_height - cover_h) / 2)
        local empty_container = CenterContainer:new{
            dimen = Geom:new{ w = outer_width, h = outer_height },
            empty_row,
        }
        local empty_base_shift, empty_controls_top = set_visual_bounds(
            page_delta, empty_top, empty_top + cover_h)
        local original_empty_paint = empty_container.paintTo
        empty_container.paintTo = function(self, bb, x, y)
            return original_empty_paint(
                self, bb, x, y + empty_base_shift + visual_shift)
        end
        local empty_frame = FrameContainer:new{
            width = outer_width,
            height = outer_height,
            padding = 0,
            bordersize = 0,
            background = Background.tile_bg(Blitbuffer.COLOR_WHITE),
            empty_container,
        }
        logger.perf("strip frame built", (os.clock() - started_at) * 1000,
            "component=", ctx.component_id or source,
            "page_delta=", page_delta or 0,
            "books=", 0)
            return empty_frame, add_control_targets({}), {}, books, cover_plans,
                empty_controls_top
        end

    local num_rows = metrics.rows
    local row_gap = metrics.row_gap
    local row_top_pad = metrics.row_top_pad
    local row_bottom_pad = metrics.row_bottom_pad
    local row_inner_bottom_pad = metrics.row_inner_bottom_pad
    local strip_title_face = metrics.strip_title_face
    -- Measure the real rendered single-line height: TextBoxWidget renders at
    -- round((1+line_height)*face.size) and bumps a too-small height up to that,
    -- so a guessed title_h underreserves and the title overflows into the navbar.
    local title_h = show_strip_titles and metrics.title_h or 0
    local title_gap = show_strip_titles and metrics.title_gap or 0
    -- cover_common floors cover height at 28px, so a row never shrinks below it.
    local MIN_COVER_H = 28

    local row_books = {}
    for r = 1, num_rows do
        row_books[r] = {}
    end
    for i, book in ipairs(books) do
        local r = math.ceil(i / per_row)
        if r <= num_rows then
            table.insert(row_books[r], book)
        end
    end
    local visible_rows = 0
    for r = 1, num_rows do
        if #row_books[r] > 0 then
            visible_rows = visible_rows + 1
        end
    end
    if visible_rows < 1 then visible_rows = 1 end
    local layout_rows = two_rows and num_rows or visible_rows
    local fixed_h = row_top_pad
        + row_bottom_pad
        + math.max(0, layout_rows - 1) * row_gap
        + math.max(0, layout_rows - 1) * row_inner_bottom_pad
    local avail_h = height - fixed_h
    -- Covers can't shrink below MIN_COVER_H; if titles won't also fit within `height`,
    -- drop them so the strip never overflows downward into the navbar (2-row / rotation).
    if show_strip_titles
            and avail_h < layout_rows * (MIN_COVER_H + title_gap + title_h) then
        show_strip_titles = false
        title_h = 0
        title_gap = 0
    end
    local per_row_budget = math.floor(
        (avail_h - layout_rows * (title_h + title_gap)) / layout_rows)
    local max_cover_h_per_row = math.max(1, math.min(MIN_COVER_H, per_row_budget))
    if per_row_budget > MIN_COVER_H then max_cover_h_per_row = per_row_budget end
    local page_focus_targets = {}
    local hydration_jobs = {}

    local function build_group_cover(book, max_cover_w, cover_h)
        local config = type(ctx.zen_config) == "table" and ctx.zen_config
            or get_zen_config(rawget(_G, "__ZEN_UI_PLUGIN")) or {}
        local features = type(config.features) == "table" and config.features or {}
        local uniform = features.browser_cover_mosaic_uniform == true
        -- Match book-cover bounds; spine lines paint outside this box.
        local target_w, target_h = CoverUtils.calcDims(max_cover_w, cover_h)
        local entry = {
            _zen_files = book.group_files or {},
            text = book.group_label,
            mandatory = book.group_count,
        }
        local specs = {
            max_cover_w = target_w,
            max_cover_h = target_h,
            uniform = uniform,
        }
        local result = FolderCover.build(
            ctx.menu or {}, entry, book.group_label, target_w, target_h, {
                cached_only = true,
                cover_specs = specs,
                uniform = uniform,
            })
        local frame = result.frame
        local frame_size = type(frame.getSize) == "function" and frame:getSize()
            or frame.dimen or { w = target_w, h = target_h }
        local cover = CenterContainer:new{
            dimen = Geom:new{ w = target_w, h = target_h },
            frame,
        }
        cover = FolderCover.overlayName(cover, {
            width = target_w,
            height = target_h,
            title = result.title,
            strip_height = show_strip_titles and title_h or 0,
            cover_dimen = frame_size,
            config = config,
        })
        cover = FolderCover.decorateWidget(cover, frame, result.count, config)
        local job
        if result.needs_hydration then
            local members = {}
            local entries = type(result.entries) == "table" and result.entries or {}
            for index, member in ipairs(entries) do
                local path = member.path or member.file
                if type(path) == "string" and path ~= "" then
                    local member_w, member_h = CoverUtils.getFolderPreviewBounds(
                        result.mode, target_w, target_h, #entries, index)
                    members[#members + 1] = {
                        book = { path = path },
                        path = path,
                        width = member_w or target_w,
                        height = member_h or target_h,
                    }
                end
            end
            job = {
                folder_entry = entry,
                title = result.title,
                path = table.concat({
                    "group", tostring(book.group_kind), tostring(book.group_label),
                }, "\30"),
                width = target_w,
                height = target_h,
                cover_specs = specs,
                uniform = uniform,
                cover_count = result.cover_count or 0,
                members = members,
            }
        end
        return cover, target_w, target_h, job
    end

    local function build_row_widget(row_list, row_num)
        local n = #row_list
        local row_capacity = per_row
        local center_short_row = center_books and n <= 3
        local left_align_partial = not center_short_row and n < per_row
        local min_gap = math.max(6, math.min(Screen:scaleBySize(14), math.floor(width * 0.018)))
        local max_cover_w = math.max(24, math.floor(
            (cover_row_width - min_gap * (row_capacity - 1)) / row_capacity))
        local cover_h = math.min(
            max_cover_h_per_row, cover_height_for_width(max_cover_w))
        if cover_h < 1 then cover_h = max_cover_h_per_row end

        local items = {}
        local covers_w = 0
        local row_h = 0
        for _i, book in ipairs(row_list) do
            local cover, cover_w, rendered_cover_h, hydration_job
            if book.is_group == true then
                cover, cover_w, rendered_cover_h, hydration_job =
                    build_group_cover(book, max_cover_w, cover_h)
            else
                local needs_hydration
                cover, cover_w, rendered_cover_h, needs_hydration =
                    cover_common.make_cover_widget(
                        book,
                        max_cover_w,
                        cover_h,
                        {
                            border = cover_common.BORDER_SIZE,
                            background = Blitbuffer.COLOR_LIGHT_GRAY,
                            decorate = decorate_covers and function(frame)
                                apply_strip_cover_decorations(
                                    frame, book, strip_config, show_badges)
                            end or nil,
                        }
                    )
                if needs_hydration and not hydration_failed_paths[book.path] then
                    hydration_job = {
                        book = book,
                        path = book.path,
                        width = cover_w or max_cover_w,
                        height = rendered_cover_h or cover_h,
                    }
                end
            end
            cover_w = cover_w or max_cover_w
            local cover_size = cover.getSize and cover:getSize() or nil
            local actual_cover_h = rendered_cover_h or (cover_size and cover_size.h) or cover_h
            cover_plans[#cover_plans + 1] = {
                width = cover_w,
                height = actual_cover_h,
            }
            if hydration_job and not hydration_failed_paths[hydration_job.path] then
                hydration_jobs[#hydration_jobs + 1] = hydration_job
            end
            local item_h = show_strip_titles and (actual_cover_h + title_gap + title_h) or actual_cover_h
            if item_h > row_h then row_h = item_h end
            covers_w = covers_w + cover_w
            items[#items + 1] = {
                book = book,
                cover = cover,
                w = cover_w,
                cover_h = actual_cover_h,
                h = item_h,
            }
        end

        local gap = 0
        local extra_gap_px = 0
        if #items > 1 then
            local gap_slots = left_align_partial and math.max(1, row_capacity - 1) or (#items - 1)
            local avg_cover_w = math.floor(covers_w / #items)
            local cover_slots_w = left_align_partial and (avg_cover_w * row_capacity) or covers_w
            local available_gap = center_short_row
                and (min_gap * gap_slots)
                or math.max(
                    min_gap * gap_slots,
                    cover_row_width - cover_slots_w)
            gap = math.floor(available_gap / gap_slots)
            local fill_available_width = true
            if metrics.phone_shaped then
                local phone_gap = math.max(min_gap, math.min(
                    Screen:scaleBySize(24), math.floor(width * 0.045)))
                if gap > phone_gap then fill_available_width = false end
                gap = math.min(gap, phone_gap)
            end
            if fill_available_width and not center_short_row then
                extra_gap_px = math.max(0, available_gap - gap * gap_slots)
            end
        end

        local row = HorizontalGroup:new{ align = "center" }
        for idx, item in ipairs(items) do
            local book = item.book
            local item_w = item.w
            local path = book.path

            local content
            if show_strip_titles and title_h > 0 then
                content = VerticalGroup:new{
                    align = "center",
                    CenterContainer:new{
                        dimen = Geom:new{ w = item_w, h = item.cover_h },
                        item.cover,
                    },
                    VerticalSpan:new{ width = title_gap },
                    TextBoxWidget:new{
                        text = book.is_group == true
                            and ((book.group_label or "") .. " ("
                                .. tostring(book.group_count or 0) .. ")")
                            or book.title or "",
                        width = item_w,
                        height = title_h,
                        face = strip_title_face,
                        bold = true,
                        alignment = "center",
                        fgcolor = Blitbuffer.COLOR_BLACK,
                        height_overflow_show_ellipsis = true,
                    },
                }
            else
                content = CenterContainer:new{ dimen = Geom:new{ w = item_w, h = item.cover_h }, item.cover }
            end

            local item_widget = content
            if interactive and Device:isTouchDevice() then
                local tap = InputContainer:new{
                    dimen = Geom:new{ w = item_w, h = item.h },
                    ges_events = {
                        TapCover = {
                            GestureRange:new{ ges = "tap", range = Geom:new{
                                x = 0, y = 0,
                                w = Screen:getWidth(), h = Screen:getHeight(),
                            } },
                        },
                        HoldCover = {
                            GestureRange:new{ ges = "hold", range = Geom:new{
                                x = 0, y = 0,
                                w = Screen:getWidth(), h = Screen:getHeight(),
                            } },
                        },
                    },
                }
                tap.onTapCover = function(tap_self, _, ges)
                    if not tap_self.dimen or not ges or not ges.pos then return false end
                    if ctx.openTopMenu and ctx.openTopMenu(ges) then return true end
                    if not tap_self.dimen:contains(ges.pos) then return false end
                    if book.is_group == true then
                        if type(ctx.openStripGroup) == "function" then ctx.openStripGroup(book) end
                        return true
                    end
                    if ges.time ~= nil and not BookOpenTap.shouldOpen(path, ges.time) then return true end
                    set_opening_banner_cover(item.cover)
                    ctx.openBook(path)
                    return true
                end
                tap.onHoldCover = function(tap_self, _, ges)
                    if not tap_self.dimen or not ges or not ges.pos then return false end
                    if not tap_self.dimen:contains(ges.pos) then return false end
                    if book.is_group == true then
                        if type(ctx.showStripGroupMenu) == "function" then
                            return ctx.showStripGroupMenu(book)
                        end
                        return false
                    end
                    if ctx.showBookMenu then return ctx.showBookMenu(path, source_name) end
                    return false
                end
                tap[1] = content
                item_widget = tap
            end
            if interactive and type(ctx.registerHomeFocusTarget) == "function" then
                local target = {
                    key = (book.is_group == true and "group:" or "book:")
                        .. tostring(book.group_label or path),
                    subrow = row_num or 1,
                    col = idx,
                    width = item_w,
                    height = item.h,
                    activate = function()
                        if book.is_group == true then
                            if type(ctx.openStripGroup) == "function" then
                                return ctx.openStripGroup(book)
                            end
                            return false
                        end
                        set_opening_banner_cover(item.cover)
                        ctx.openBook(path)
                        return true
                    end,
                    context = function()
                        if book.is_group == true then
                            if type(ctx.showStripGroupMenu) == "function" then
                                return ctx.showStripGroupMenu(book)
                            end
                            return false
                        end
                        if ctx.showBookMenu then return ctx.showBookMenu(path, source_name) end
                        return false
                    end,
                }
                if type(ctx.prepareHomeFocusTarget) == "function" then
                    item_widget = ctx.prepareHomeFocusTarget(target, item_widget)
                    page_focus_targets[#page_focus_targets + 1] = target
                else
                    item_widget = ctx.registerHomeFocusTarget(target, item_widget)
                end
            end

            table.insert(row, item_widget)
            if idx < #items then
                local gap_w = gap
                if extra_gap_px > 0 then
                    gap_w = gap_w + 1
                    extra_gap_px = extra_gap_px - 1
                end
                table.insert(row, HorizontalSpan:new{ width = gap_w })
            end
        end

        return row, row_h
    end

    local vgroup = VerticalGroup:new{}
    table.insert(vgroup, VerticalSpan:new{ width = row_top_pad })
    local total_row_h = 0
    for r = 1, num_rows do
        if #row_books[r] > 0 then
            local row_widget, row_h = build_row_widget(row_books[r], r)
            total_row_h = total_row_h + row_h
            local container = not (center_books and #row_books[r] <= 3)
                and LeftContainer or CenterContainer
            table.insert(vgroup, container:new{
                dimen = Geom:new{ w = cover_row_width, h = row_h },
                row_widget,
            })
            if r < num_rows and #row_books[r + 1] > 0 then
                if row_inner_bottom_pad > 0 then
                    table.insert(vgroup, VerticalSpan:new{ width = row_inner_bottom_pad })
                end
                table.insert(vgroup, VerticalSpan:new{ width = row_gap })
            end
        end
    end
    table.insert(vgroup, VerticalSpan:new{ width = row_bottom_pad })

    local visual_size = vgroup:getSize()
    local inner_slack = math.max(0, height - (visual_size.h or height))
    local sparse_two_rows = two_rows and visible_rows < num_rows
    local inner_top = sparse_two_rows and 0 or math.floor(inner_slack / 2)
    local ContentContainer = sparse_two_rows and TopContainer or CenterContainer
    local content_container = ContentContainer:new{
        dimen = Geom:new{ w = width, h = height },
        vgroup,
    }
    local content_base_shift = 0
    local original_content_paint = content_container.paintTo
    content_container.paintTo = function(self, bb, x, y)
        return original_content_paint(
            self, bb, x, y + content_base_shift + visual_shift)
    end
    local outer_top = math.floor(math.max(0, outer_height - height) / 2)
    local visible_bottom = row_top_pad + total_row_h
        + math.max(0, visible_rows - 1) * (row_gap + row_inner_bottom_pad)
    local visual_top = outer_top + inner_top + row_top_pad
    local visual_bottom = outer_top + inner_top + visible_bottom
    if sparse_two_rows then
        visual_bottom = visual_top + height
    end
    local controls_top
    content_base_shift, controls_top = set_visual_bounds(
        page_delta, visual_top, visual_bottom)

    local frame = FrameContainer:new{
        width = outer_width,
        height = outer_height,
        padding = 0,
        bordersize = 0,
        background = Background.tile_bg(Blitbuffer.COLOR_WHITE),
        CenterContainer:new{
            dimen = Geom:new{ w = outer_width, h = outer_height },
            content_container,
        },
    }

    logger.perf("strip frame built", (os.clock() - started_at) * 1000,
        "component=", ctx.component_id or source,
        "page_delta=", page_delta or 0,
        "books=", #books)
        return frame, add_control_targets(page_focus_targets), hydration_jobs,
            books, cover_plans, controls_top
    end

    local frame, initial_targets, initial_jobs, initial_books, initial_plans,
        initial_controls_top = build_frame(0)
    if type(ctx.activateStripFocusTargets) == "function" then
        ctx.activateStripFocusTargets(initial_targets)
    end

    local can_swipe = interactive and Device:isTouchDevice()
    local swipe = InputContainer:new{
        dimen = Geom:new{ w = outer_width, h = outer_height },
        ges_events = can_swipe and {
            SwipeStrip = {
                GestureRange:new{ ges = "swipe", range = Geom:new{
                    x = 0, y = 0,
                    w = Screen:getWidth(), h = Screen:getHeight(),
                } },
            },
        } or {},
    }
    local repaint_widget = swipe
    local UIManager = require("ui/uimanager")
    local closed = false
    local visible_hydrate_fn
    local prewarm_fn
    local prewarm_direction = 1
    local swap_sequence = 0

    local function repaint_strip()
        if not ctx.refreshStrip then
            UIManager:setDirty(ctx.menu, "ui")
            return
        end
        local dimen = repaint_widget.dimen
        local shift = tonumber(visual_shift) or 0
        if dimen and shift ~= 0 then
            dimen = Geom:new{
                x = dimen.x,
                y = dimen.y + math.min(0, shift),
                w = dimen.w,
                h = dimen.h + math.abs(shift),
            }
        end
        ctx.refreshStrip(dimen)
    end

    local function new_entry(cached_frame, targets, jobs, books, plans, controls_top)
        return {
            frame = cached_frame,
            targets = targets or {},
            jobs = jobs or {},
            books = books or {},
            plans = plans or {},
            controls_top = controls_top,
            freed = false,
        }
    end

    page_cache[0] = new_entry(
        frame, initial_targets, initial_jobs, initial_books, initial_plans,
        initial_controls_top)

    local function free_entry(entry)
        if not entry or entry.freed then return end
        entry.freed = true
        WidgetResources.free(entry.frame)
        entry.frame = nil
        entry.targets = nil
        entry.jobs = nil
        entry.books = nil
        entry.plans = nil
        entry.controls_top = nil
    end

    local function build_entry(page_delta, books)
        local cached_frame, targets, jobs, loaded_books, plans, controls_top =
            build_frame(page_delta, books)
        return new_entry(cached_frame, targets, jobs, loaded_books, plans, controls_top)
    end

    local function activate_entry(entry)
        if type(entry.controls_top) == "number" then
            controls_visual_top = entry.controls_top
        end
        swipe[1] = entry.frame
        if swipe.resetLayout then swipe:resetLayout() end
        if type(ctx.activateStripFocusTargets) == "function" then
            ctx.activateStripFocusTargets(entry.targets)
        elseif ctx.clearStripFocusTargets then
            ctx.clearStripFocusTargets(ctx.component_id)
        end
    end

    local function replace_entry(page_delta, replacement, repaint)
        local previous = page_cache[page_delta]
        page_cache[page_delta] = replacement
        if page_delta == 0 then
            activate_entry(replacement)
            if repaint then repaint_strip() end
        end
        if previous and previous ~= replacement then free_entry(previous) end
    end

    local function cancel_visible_hydration(reason)
        if not visible_hydrate_fn then return end
        UIManager:unschedule(visible_hydrate_fn)
        visible_hydrate_fn = nil
        logger.perf("strip cover hydration cancelled", 0,
            "component=", ctx.component_id or source,
            "reason=", reason or "stale")
    end

    local function cancel_prewarm(reason)
        if not prewarm_fn then return end
        UIManager:unschedule(prewarm_fn)
        prewarm_fn = nil
        logger.perf("strip page prewarm cancelled", 0,
            "component=", ctx.component_id or source,
            "reason=", reason or "stale")
    end

    local function warm_job(job)
        if job.folder_entry then
            if type(ctx.data.warmStripCover) == "function" then
                local members_pending = false
                for _i, member in ipairs(job.members or {}) do
                    if ctx.data:warmStripCover(
                            member.book, member.width, member.height) == "pending" then
                        members_pending = true
                    end
                end
                if members_pending then return "pending" end
            end
            local result = FolderCover.build(
                ctx.menu or {}, job.folder_entry, job.title, job.width, job.height, {
                    cached_only = false,
                    cover_specs = job.cover_specs,
                    uniform = job.uniform,
                    decorate = false,
                })
            local previous_count = job.cover_count or 0
            job.cover_count = result.cover_count or 0
            local pending = result.needs_hydration == true
            WidgetResources.free(result.frame)
            if job.cover_count > previous_count or not pending then return "warmed" end
            return "pending"
        end
        if type(ctx.data.warmStripCover) ~= "function" then return "failed" end
        return ctx.data:warmStripCover(job.book, job.width, job.height)
    end

    local schedule_prewarm
    local schedule_visible_hydration
    schedule_visible_hydration = function(delay)
        if closed or visible_hydrate_fn then return end
        local entry = page_cache[0]
        if not entry or entry.freed or #(entry.jobs or {}) == 0 then return end
        local step
        step = function()
            if visible_hydrate_fn ~= step then return end
            visible_hydrate_fn = nil
            if closed or page_cache[0] ~= entry or entry.freed then return end
            local started_at = os.clock()
            local pending = {}
            local cached, warmed, ready, failed = 0, 0, 0, 0
            for _i, job in ipairs(entry.jobs or {}) do
                local outcome = warm_job(job)
                if outcome == "cached" then
                    cached = cached + 1
                elseif outcome == "warmed" then
                    warmed = warmed + 1
                elseif outcome == "ready" then
                    ready = ready + 1
                elseif outcome == "pending" then
                    pending[#pending + 1] = job
                else
                    failed = failed + 1
                    hydration_failed_paths[job.path] = true
                end
            end
            entry.jobs = pending
            local completed = cached + warmed + ready
            if completed > 0 then
                local replacement = build_entry(0)
                replace_entry(0, replacement, true)
                entry = replacement
            end
            logger.perf("strip cover hydration completed", (os.clock() - started_at) * 1000,
                "component=", ctx.component_id or source,
                "cached=", cached,
                "warmed=", warmed,
                "ready=", ready,
                "pending=", #pending,
                "failed=", failed,
                "partial_repaint=", completed > 0 and 1 or 0)
            if #pending > 0 then
                schedule_visible_hydration(COVER_POLL_S)
            else
                schedule_prewarm(PRELOAD_DELAY_S)
            end
        end
        visible_hydrate_fn = step
        UIManager:scheduleIn(delay or HYDRATE_DELAY_S, step)
    end

    schedule_prewarm = function(delay)
        if closed or prewarm_fn or not has_adjacent_pages
                or (type(ctx.data.getStripItemsForPage) ~= "function"
                    and type(ctx.data.getBooksForStripPage) ~= "function") then
            return
        end
        local page_delta = prewarm_direction
        local started_at = os.clock()
        local work_ms = 0
        local cached, warmed, ready, failed = 0, 0, 0, 0
        local step
        step = function()
            if prewarm_fn ~= step then return end
            if closed then prewarm_fn = nil; return end
            if not MemoryPolicy.canPreload(MemoryPolicy.getProfile()) then
                prewarm_fn = nil
                logger.perf("strip page prewarm skipped", work_ms,
                    "component=", ctx.component_id or source,
                    "page_delta=", page_delta,
                    "reason=memory_pressure")
                return
            end
            if type(ctx.data.isStripCoverWorkBusy) == "function"
                    and ctx.data:isStripCoverWorkBusy() then
                prewarm_fn = nil
                logger.perf("strip page prewarm skipped", work_ms,
                    "component=", ctx.component_id or source,
                    "page_delta=", page_delta,
                    "reason=background_extraction")
                return
            end
            local current = page_cache[0]
            if visible_hydrate_fn or (current and #(current.jobs or {}) > 0) then
                prewarm_fn = nil
                logger.perf("strip page prewarm skipped", work_ms,
                    "component=", ctx.component_id or source,
                    "page_delta=", page_delta,
                    "reason=visible_hydration")
                return
            end
            local entry = page_cache[page_delta]
            if not entry then
                local books = get_page_books(page_delta) or {}
                local plans = current and current.plans or {}
                local jobs = {}
                for index, book in ipairs(books) do
                    local plan = plans[index] or plans[#plans]
                    if plan and book.is_cover_pending == true
                            and not hydration_failed_paths[book.path] then
                        jobs[#jobs + 1] = {
                            book = book,
                            path = book.path,
                            width = plan.width,
                            height = plan.height,
                        }
                    end
                end
                entry = new_entry(nil, {}, jobs, books, {})
                page_cache[page_delta] = entry
            end
            if #(entry.jobs or {}) == 0 then
                prewarm_fn = nil
                logger.perf("strip page prewarmed", work_ms,
                    "component=", ctx.component_id or source,
                    "page_delta=", page_delta,
                    "cached=", cached,
                    "warmed=", warmed,
                    "ready=", ready,
                    "failed=", failed,
                    "wall_ms=", math.floor((os.clock() - started_at) * 1000 + 0.5))
                return
            end

            local chunk_started_at = os.clock()
            local deadline = chunk_started_at + PRELOAD_BUDGET_S
            local pending = {}
            local processed = 0
            while #entry.jobs > 0 and processed < PRELOAD_CHUNK
                    and (processed == 0 or os.clock() < deadline) do
                local job = table.remove(entry.jobs, 1)
                processed = processed + 1
                local outcome = warm_job(job)
                if outcome == "cached" then
                    cached = cached + 1
                elseif outcome == "warmed" then
                    warmed = warmed + 1
                elseif outcome == "ready" then
                    ready = ready + 1
                elseif outcome == "pending" then
                    pending[#pending + 1] = job
                else
                    failed = failed + 1
                    hydration_failed_paths[job.path] = true
                end
            end
            for _i, job in ipairs(pending) do entry.jobs[#entry.jobs + 1] = job end
            work_ms = work_ms + (os.clock() - chunk_started_at) * 1000

            if #entry.jobs > 0 then
                if #pending == processed then
                    prewarm_fn = nil
                    logger.perf("strip page prewarm skipped", work_ms,
                        "component=", ctx.component_id or source,
                        "page_delta=", page_delta,
                        "reason=cover_pending",
                        "queued=", #entry.jobs)
                else
                    UIManager:scheduleIn(PRELOAD_TICK_S, step)
                end
                return
            end

            prewarm_fn = nil
            logger.perf("strip page prewarmed", work_ms,
                "component=", ctx.component_id or source,
                "page_delta=", page_delta,
                "cached=", cached,
                "warmed=", warmed,
                "ready=", ready,
                "failed=", failed,
                "wall_ms=", math.floor((os.clock() - started_at) * 1000 + 0.5))
        end
        prewarm_fn = step
        UIManager:scheduleIn(delay or PRELOAD_DELAY_S, step)
    end

    local function refresh_strip(swipe_self, direction, gesture_started_at)
        cancel_visible_hydration("swipe")
        cancel_prewarm("swipe")
        local replacement_delta = direction == "next" and 1 or -1
        local replacement = page_cache[replacement_delta]
        local cache_hit = replacement ~= nil and replacement.frame ~= nil
        if replacement and not replacement.frame then
            local lazy_entry = replacement
            replacement = build_entry(replacement_delta, lazy_entry.books)
            free_entry(lazy_entry)
        elseif not replacement then
            replacement = build_entry(0)
        end

        local evicted
        if direction == "next" then
            evicted = page_cache[-1]
            page_cache[-1] = page_cache[0]
            page_cache[0] = replacement
            page_cache[1] = nil
        else
            evicted = page_cache[1]
            page_cache[1] = page_cache[0]
            page_cache[0] = replacement
            page_cache[-1] = nil
        end
        activate_entry(replacement)
        free_entry(evicted)

        swap_sequence = swap_sequence + 1
        local swapped_at = os.clock()
        swipe_self._zen_pending_strip_paint = {
            sequence = swap_sequence,
            gesture_started_at = gesture_started_at,
            swapped_at = swapped_at,
        }
        logger.perf("strip page swapped", (swapped_at - gesture_started_at) * 1000,
            "component=", ctx.component_id or source,
            "sequence=", swap_sequence,
            "direction=", direction,
            "cache_hit=", cache_hit and 1 or 0)
        repaint_strip()
        prewarm_direction = direction == "next" and 1 or -1
        schedule_visible_hydration(HYDRATE_DELAY_S)
        schedule_prewarm(PRELOAD_DELAY_S)
    end

    shift_strip_page = function(direction)
        if not ctx.shiftStrip then return false end
        local gesture_started_at = os.clock()
        return ctx.shiftStrip(
            source, count, order, direction, ctx.component_id, two_rows, function()
                refresh_strip(swipe, direction, gesture_started_at)
            end) == true
    end

    local unregister_page_handler
    if interactive and type(ctx.registerStripPageHandler) == "function" then
        unregister_page_handler = ctx.registerStripPageHandler(shift_strip_page)
    end

    if can_swipe then
        swipe.onSwipeStrip = function(swipe_self, _, ges)
            if not swipe_self.dimen or not ges or not ges.pos then return false end
            if not swipe_self.dimen:contains(ges.pos) then return false end
            if ges.direction == "west" then
                shift_strip_page("next")
                return true
            elseif ges.direction == "east" then
                shift_strip_page("previous")
                return true
            end
            return false
        end
    end
    swipe[1] = frame

    local function job_contains_path(job, path)
        if job.path == path then return true end
        for _i, member in ipairs(job.members or {}) do
            if member.path == path then return true end
        end
        return false
    end

    local unregister_cover_listener
    if type(ctx.registerStripCoverListener) == "function" then
        unregister_cover_listener = ctx.registerStripCoverListener(function(path)
            hydration_failed_paths[path] = nil
            local current = page_cache[0]
            for _i, job in ipairs(current and current.jobs or {}) do
                if job_contains_path(job, path) then
                    cancel_visible_hydration("cover_ready")
                    schedule_visible_hydration(0)
                    return
                end
            end
            local future = page_cache[prewarm_direction]
            for _i, job in ipairs(future and future.jobs or {}) do
                if job_contains_path(job, path) then
                    cancel_prewarm("cover_ready")
                    schedule_prewarm(PRELOAD_TICK_S)
                    return
                end
            end
        end)
    end

    local orig_paintTo = swipe.paintTo
    local first_paint = true
    if type(orig_paintTo) == "function" then
        swipe.paintTo = function(self, bb, x, y)
            local started_at = os.clock()
            orig_paintTo(self, bb, x, y)
            local painted_at = os.clock()
            local pending = self._zen_pending_strip_paint
            if first_paint or pending then
                logger.perf("strip page painted", (painted_at - started_at) * 1000,
                    "component=", ctx.component_id or source,
                    "sequence=", pending and pending.sequence or 0,
                    "swap_to_paint_ms=", pending
                        and math.floor((painted_at - pending.swapped_at) * 1000 + 0.5) or 0,
                    "gesture_to_paint_ms=", pending
                        and math.floor((painted_at - pending.gesture_started_at) * 1000 + 0.5) or 0)
                self._zen_pending_strip_paint = nil
            end
            if first_paint then
                first_paint = false
                schedule_visible_hydration(HYDRATE_DELAY_S)
                schedule_prewarm(PRELOAD_DELAY_S)
            end
        end
    end

    WidgetResources.wrapFree(swipe, function()
        closed = true
        cancel_visible_hydration("widget_close")
        cancel_prewarm("widget_close")
        if unregister_page_handler then unregister_page_handler() end
        if unregister_cover_listener then unregister_cover_listener() end
        for page_delta, entry in pairs(page_cache) do
            if not rawequal(entry.frame, swipe[1]) then
                free_entry(entry)
            end
            page_cache[page_delta] = nil
        end
    end)
    if not controls_widget then return swipe end
    local controls_container = CenterContainer:new{
        dimen = Geom:new{ w = outer_width, h = controls_height },
        controls_widget,
    }
    local original_controls_paint = controls_container.paintTo
    controls_container.paintTo = function(self, bb, x, y)
        return original_controls_paint(
            self, bb, x, y + controls_visual_top + visual_shift)
    end
    local strip_widget = FrameContainer:new{
        width = outer_width,
        height = total_outer_height,
        padding = 0,
        bordersize = 0,
        background = Background.tile_bg(Blitbuffer.COLOR_WHITE),
        OverlapGroup:new{
            dimen = Geom:new{ w = outer_width, h = total_outer_height },
            VerticalGroup:new{
                VerticalSpan:new{ width = controls_and_gap },
                swipe,
            },
            controls_container,
        },
    }
    repaint_widget = strip_widget
    return strip_widget
end

return M
