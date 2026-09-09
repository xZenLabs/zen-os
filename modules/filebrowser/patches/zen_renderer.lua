-- Zen-owned book, folder, and virtual-group tiles for library mosaic views.
local function apply_zen_renderer()
    local MosaicMenu = require("mosaicmenu")
    if MosaicMenu._zen_renderer_patched then return end
    local plugin_ref = rawget(_G, "__ZEN_UI_PLUGIN")
    local stock_builder = MosaicMenu._updateItemsBuildUI
    if type(stock_builder) ~= "function" then return end

    local function get_upvalue(fn, name)
        for index = 1, 128 do
            local upvalue_name, value = debug.getupvalue(fn, index)
            if not upvalue_name then break end
            if upvalue_name == name then return value end
        end
    end

    -- Keep this name as an upvalue: Zen's existing mosaic patches continue to
    -- decorate CoverBrowser folder/group tiles without touching book tiles.
    local MosaicMenuItem = get_upvalue(stock_builder, "MosaicMenuItem")
    if not MosaicMenuItem then return end

    local Blitbuffer = require("ffi/blitbuffer")
    local BookInfoManager = require("bookinfomanager")
    local BD = require("ui/bidi")
    local Device = require("device")
    local Screen = Device.screen
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local Menu = require("ui/widget/menu")
    local TextWidget = require("ui/widget/textwidget")
    local UnderlineContainer = require("ui/widget/container/underlinecontainer")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local Size = require("ui/size")
    local CoverWidget = require("modules/filebrowser/patches/home/widgets/cover_common")
    local CoverUtils = require("common/cover_utils")
    local DecodeCache = require("common/cover_decode_cache")
    local RenderCache = require("common/cover_render_cache")
    local FolderCover = require("modules/filebrowser/folder_cover")
    local Background = require("common/ui/background")
    local book_status = require("common/book_status")
    local library_font = require("modules/filebrowser/patches/library_font")
    local utils = require("common/utils")
    local now = require("common/zen_logger").now
    local METADATA_TTL_S = 30

    local ZenMosaicItem = InputContainer:extend{
        entry = nil,
        text = nil,
        dimen = nil,
        bookinfo_found = false,
        is_directory = false,
    }

    local function plugin_config()
        local plugin = plugin_ref or rawget(_G, "__ZEN_UI_PLUGIN")
        return plugin and type(plugin.config) == "table" and plugin.config or {}
    end

    local function strip_options()
        local config = plugin_config().mosaic_title_strip or {}
        return config.show_title == true, config.show_author == true
    end

    local function covers_suppressed(menu)
        return (menu and menu.no_refresh_covers == true)
            or rawget(_G, "__ZEN_UI_SUPPRESS_FILEMANAGER_COVERS") == true
    end

    local function fresh_metadata(path)
        if type(DecodeCache.getFreshMetadata) == "function" then
            local cached = DecodeCache:getFreshMetadata(path, now(), METADATA_TTL_S)
            if cached then return cached end
        end
    end

    local function metadata_without_cover(path)
        local cached = fresh_metadata(path)
        if cached then return cached end
        return BookInfoManager:getBookInfo(path, false)
    end

    local function valid_real_cover(info, specs)
        if not info or not info.cover_fetched or not info.has_cover or info.ignore_cover then
            return false
        end
        return type(BookInfoManager.isCachedCoverInvalid) ~= "function"
            or not BookInfoManager.isCachedCoverInvalid(info, specs)
    end

    local function queue_cover_hydration(item, kind)
        if item._zen_cover_hydration_queued then return end
        local menu = item.menu
        if not menu then return end
        menu._zen_cover_hydration_items = menu._zen_cover_hydration_items or {}
        item._zen_cover_hydration_queued = true
        item._zen_cover_hydration_kind = kind or "book"
        menu._zen_cover_hydration_items[#menu._zen_cover_hydration_items + 1] = item
        if type(menu._zen_request_cover_hydration) == "function" then
            menu:_zen_request_cover_hydration()
        end
    end

    local function is_file_manager_select_mode()
        local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
        return ok and FileManager.instance and FileManager.instance.selected_files ~= nil
    end

    local function filename(path)
        return (path or ""):match("([^/]+)$") or ""
    end

    local function fallback_title(path)
        return filename(path):gsub("%.[^%.]+$", "")
    end

    local function cover_dimensions(width, height)
        local border = CoverWidget.BORDER_SIZE or 2
        local max_w = width - 2 * border
        local max_h = height - 2 * border
        local features = plugin_config().features or {}
        if features.browser_cover_mosaic_uniform ~= true then
            return math.max(1, max_w), math.max(1, max_h), border, false
        end
        local aspect = CoverUtils.getRatio()
        local target_w, target_h
        if max_w / max_h > aspect then
            target_h = max_h
            target_w = math.floor(max_h * aspect)
        else
            target_w = max_w
            target_h = math.floor(max_w / aspect)
        end
        return math.max(1, target_w), math.max(1, target_h), border, true
    end

    local strip_height_cache = {}
    local function strip_metrics(show_title, show_author)
        if not show_title and not show_author then return 0 end
        local key = table.concat({
            show_title and "title" or "",
            show_author and "author" or "",
            library_font.getFontName(),
            tostring(library_font.getBaseSize()),
        }, ":")
        if strip_height_cache[key] then return strip_height_cache[key] end
        local padding = Screen:scaleBySize(3)
        local gap = Screen:scaleBySize(2)
        local height = 2 * padding
        if show_title then
            local title = TextWidget:new{
                text = "Ag", face = library_font.getFace(library_font.scaleValue(16)),
                bold = true, padding = 0,
            }
            height = height + title:getSize().h
            title:free()
        end
        if show_title and show_author then height = height + gap end
        if show_author then
            local author = TextWidget:new{
                text = "Ag", face = library_font.getFace(library_font.scaleValue(13)),
                padding = 0,
            }
            height = height + author:getSize().h
            author:free()
        end
        strip_height_cache[key] = height
        return height
    end

    function ZenMosaicItem:init()
        self.filepath = self.entry.file or self.entry.path
        self.ges_events = {
            TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
            HoldSelect = { GestureRange:new{ ges = "hold", range = self.dimen } },
        }
        self._underline_container = UnderlineContainer:new{
            vertical_align = "top",
            padding = Size.padding.tiny,
            dimen = Geom:new{ w = self.width, h = self.height + Size.line.focus_indicator },
            linesize = Size.line.focus_indicator,
        }
        self[1] = self._underline_container
        self:update()
        self.init_done = true
    end

    local function folder_name_overlay(item, cover, content_h, title, strip_h, cover_dimen)
        return FolderCover.overlayName(cover, {
            width = item.width,
            height = content_h,
            title = title,
            strip_height = strip_h,
            cover_dimen = cover_dimen,
            config = plugin_config(),
        })
    end

    local function update_folder(item, show_title, show_author, strip_h, content_h)
        local hydrating_folder = item._zen_folder_hydrating == true
        local target_w, target_h, border, uniform = cover_dimensions(item.width, content_h)
        local max_w = math.max(1, item.width - 2 * border)
        local max_h = math.max(1, content_h - 2 * border)
        local specs = {
            max_cover_w = target_w,
            max_cover_h = target_h,
            uniform = uniform,
        }
        item.menu.cover_specs = item.do_cover_image and specs or false
        local wants_preview = item.do_cover_image and not covers_suppressed(item.menu)
        local result = FolderCover.build(item.menu, item.entry, item.text, max_w, max_h, {
            load_covers = wants_preview,
            cached_only = wants_preview and not hydrating_folder,
            allow_expensive = hydrating_folder,
            cover_specs = specs,
            uniform = uniform,
        })
        local perf = result.perf
        local measure = item.menu._zen_folder_build_measure
        if measure then
            measure.builds = measure.builds + 1
            if perf and perf.descriptor_cache_hit then
                measure.descriptor_hits = measure.descriptor_hits + 1
            end
            if perf then
                measure.candidates = measure.candidates + (perf.candidate_count or 0)
                measure.enumeration_ms = measure.enumeration_ms + (perf.enumeration_ms or 0)
                measure.explicit_ms = measure.explicit_ms + (perf.explicit_ms or 0)
                measure.collect_ms = measure.collect_ms + (perf.collect_ms or 0)
                measure.draw_ms = measure.draw_ms + (perf.draw_ms or 0)
                if perf.composite_cache_hit then
                    measure.composite_hits = measure.composite_hits + 1
                end
                if perf.composite_built then
                    measure.composite_builds = measure.composite_builds + 1
                end
            end
        end

        item.is_directory = true
        item.bookinfo_found = true
        item.file_deleted = item.entry.dim
        item._zen_is_book = false
        item._zen_tile_kind = item.entry.is_series_group and "series_group"
            or (item.entry._zen_files and "metadata_group")
            or (item.menu._zen_coll_list and item.entry.name and "collection")
            or (item.entry.is_go_up and "up")
            or (item.entry._zen_empty_placeholder and "empty_group")
            or "folder"
        item._zen_effective_status = item.entry._zen_effective_status
            or book_status.getEffectiveStatus(item.entry.status, item.entry.percent_finished)
        local badges = plugin_config().browser_cover_badges or {}
        if badges.dim_finished_books == true
                and item._zen_effective_status ~= "complete"
                and FolderCover.allBooksFinished(
                    item.menu, item.entry, result.entries, result.count) then
            item._zen_effective_status = "complete"
        end
        item._zen_folder_count = result.count > 0 and result.count or nil
        item._zen_folder_title = result.title
        item._zen_cover_frame = result.frame
        item._cover_frame = result.frame
        item._foldercover_processed = true
        result.frame.dim = item.file_deleted and true or nil
        item._has_cover_image = result.cover_count > 0
        if item._has_cover_image then item.menu._has_cover_images = true end
        if result.needs_hydration and not hydrating_folder then
            queue_cover_hydration(item, "folder")
        end

        local cover = CenterContainer:new{
            dimen = Geom:new{ w = item.width, h = content_h },
            result.frame,
        }
        local cover_size = type(result.frame.getSize) == "function"
            and result.frame:getSize() or result.frame.dimen
        cover = folder_name_overlay(item, cover, content_h, result.title, strip_h,
            cover_size)
        local content = VerticalGroup:new{ align = "center", cover }
        if strip_h > 0 and (show_title or show_author) then
            table.insert(content, CenterContainer:new{
                dimen = Geom:new{ w = item.width, h = strip_h },
                TextWidget:new{
                    text = BD.directory(result.title),
                    face = library_font.getFace(library_font.scaleValue(16)),
                    bold = true,
                    max_width = item.width - Screen:scaleBySize(12),
                    truncate_with_ellipsis = true,
                    padding = 0,
                    fgcolor = Blitbuffer.COLOR_BLACK,
                },
            })
        end
        if item._underline_container[1] then item._underline_container[1]:free() end
        item._underline_container[1] = content
    end

    function ZenMosaicItem:update()
        local build_measure = self.menu and self.menu._zen_cover_build_measure
        local function load_metadata()
            if not build_measure then return metadata_without_cover(self.filepath) end
            local started_at = now()
            local result = metadata_without_cover(self.filepath)
            build_measure.metadata_ms = (build_measure.metadata_ms or 0)
                + (now() - started_at) * 1000
            return result
        end
        local hydrating_cover = self._zen_cover_hydrating == true
        local preserve_metadata_state = hydrating_cover and self._zen_metadata_ready == true
        local show_title, show_author = strip_options()
        local strip_h = strip_metrics(show_title, show_author)
        local content_h = math.max(1, self.height - strip_h)
        local target_w, target_h, border, uniform = cover_dimensions(self.width, content_h)
        local specs = {
            max_cover_w = target_w,
            max_cover_h = target_h,
            uniform = uniform,
        }
        self.menu.cover_specs = self.do_cover_image and specs or false
        self.file_deleted = self.entry.dim
        self.is_directory = false
        self.bookinfo_found = false
        self._has_cover_image = false
        self.cover_specs = nil
        self._zen_cover_frame = nil
        self._cover_frame = nil
        if not preserve_metadata_state then
            self.status = nil
            self.percent_finished = nil
            self._zen_effective_status = nil
            self._zen_is_fav = false
            self._zen_page_label = nil
            self._zen_series_label = nil
            self._zen_metadata_ready = nil
        end
        self._zen_folder_count = nil
        self._zen_folder_title = nil
        self._foldercover_processed = nil
        self._zen_is_book = FolderCover.isBook(self.entry)

        if not self._zen_is_book then
            update_folder(self, show_title, show_author, strip_h, content_h)
            return
        end
        self._zen_tile_kind = "book"
        self.menu._zen_file_cover_specs = self.do_cover_image and specs or false

        local want_cover = self.do_cover_image and not covers_suppressed(self.menu)
        local metadata
        local info
        local cached_final = false
        local hydrate_later = false
        if want_cover and not self.file_deleted
                and type(RenderCache.hasReusable) == "function" then
            local render_w, render_h
            if uniform then
                render_w, render_h = CoverUtils.calcDims(target_w, target_h)
            else
                metadata = load_metadata()
                if valid_real_cover(metadata, specs)
                        and tonumber(metadata.cover_w) and tonumber(metadata.cover_h) then
                    render_w, render_h = CoverUtils.fitDims(
                        target_w, target_h, metadata.cover_w, metadata.cover_h)
                end
            end
            if render_w and render_h and RenderCache:hasReusable(
                    self.filepath, render_w, render_h) then
                metadata = metadata or load_metadata()
                if valid_real_cover(metadata, specs) then
                    info = metadata
                    cached_final = true
                elseif type(RenderCache.drop) == "function" then
                    RenderCache:drop(self.filepath)
                end
            end
        end
        if not info then
            metadata = metadata or load_metadata()
            if hydrating_cover and want_cover and not self.file_deleted
                    and valid_real_cover(metadata, specs) then
                metadata = BookInfoManager:getBookInfo(self.filepath, true)
            end
            info = metadata
            if info and want_cover and not info.ignore_cover and not self.file_deleted then
                if not info.cover_fetched then
                    info = nil
                elseif info.has_cover
                        and type(BookInfoManager.isCachedCoverInvalid) == "function"
                        and BookInfoManager.isCachedCoverInvalid(info, specs) then
                    if info.cover_bb then
                        info.cover_bb:free()
                        info.cover_bb = nil
                    end
                    if type(RenderCache.drop) == "function" then
                        RenderCache:drop(self.filepath)
                    end
                    info = nil
                elseif info.has_cover and not info.cover_bb then
                    hydrate_later = not hydrating_cover
                end
            end
        end
        local cover
        if metadata and not preserve_metadata_state then
            local status_started_at = build_measure and now()
            local status_data = book_status.getFileStatusData(self.filepath)
            self.status = status_data.status
            self.percent_finished = status_data.percent_finished
            self._zen_effective_status = status_data.display_status or status_data.effective_status
            local config = plugin_config()
            local badge = config.browser_cover_badges or {}
            local is_collection = self.menu.name == "collections" or self.menu._zen_coll_list
            if badge.show_favorite_badge == true and not is_collection then
                local ReadCollection = require("readcollection")
                local favorites = ReadCollection.default_collection_name or "favorites"
                self._zen_is_fav = ReadCollection:isFileInCollection(self.filepath, favorites)
            end
            if config.browser_page_count and config.browser_page_count.show_page_count then
                local page_count_trace = build_measure and {} or nil
                local pages = utils.getStablePageCount(self.filepath, metadata.pages, {
                    doc_settings = status_data.doc_settings,
                    sidecar_checked = status_data.sidecar_checked,
                    book_info = status_data.book_info,
                    book_info_checked = status_data.book_info ~= nil
                        or status_data.doc_settings ~= nil,
                    trace = page_count_trace,
                })
                if pages then self._zen_page_label = utils.formatPageCount(pages) end
                if build_measure then
                    build_measure.stable_page_sidecar_opens =
                        (build_measure.stable_page_sidecar_opens or 0)
                        + (page_count_trace.sidecar_opens or 0)
                    build_measure.stable_page_booklist_reads =
                        (build_measure.stable_page_booklist_reads or 0)
                        + (page_count_trace.booklist_reads or 0)
                end
            end
            if config.browser_series_badge and config.browser_series_badge.show_series_badge then
                local index = tonumber(metadata.series_index)
                if index then
                    self._zen_series_label = index == math.floor(index) and "#" .. math.floor(index)
                        or string.format("#%.1f", index)
                end
            end
            self._zen_metadata_ready = true
            if build_measure then
                build_measure.status_ms = (build_measure.status_ms or 0)
                    + (now() - status_started_at) * 1000
            end
        end
        if info then
            self.bookinfo_found = true
            self._has_cover_image = want_cover and info.has_cover
                and not info.ignore_cover and (cached_final or info.cover_bb ~= nil)
        else
            self.cover_specs = specs
        end

        -- Shared with Home and list mode so cover ownership, borders, and the
        -- final-render cache follow one path.
        local book = {
            path = self.filepath,
            cover_bb = self._has_cover_image and info.cover_bb or nil,
            cover_w = self._has_cover_image and info.cover_w or nil,
            cover_h = self._has_cover_image and info.cover_h or nil,
            has_real_cover = cached_final,
            is_cover_pending = hydrate_later,
            -- false is intentional: generated filename covers must not repeat
            -- the BookInfo lookup the tile already performed.
            bookinfo = metadata or false,
        }
        if metadata and metadata.cover_bb and not self._has_cover_image then
            metadata.cover_bb:free()
            metadata.cover_bb = nil
        end
        local cover_widget_started_at = build_measure and now()
        local frame = CoverWidget.make_cover_widget(book, target_w, target_h, {
            border = border,
            uniform = uniform,
        })
        if build_measure then
            local cover_widget_ms = (now() - cover_widget_started_at) * 1000
            build_measure.cover_widget_ms = (build_measure.cover_widget_ms or 0)
                + cover_widget_ms
            if hydrate_later then
                build_measure.pending_fallback_ms =
                    (build_measure.pending_fallback_ms or 0) + cover_widget_ms
            end
        end
        frame.dim = self.file_deleted and true or nil
        if metadata then metadata.cover_bb = nil end
        cover = CenterContainer:new{
            dimen = Geom:new{ w = self.width, h = content_h },
            frame,
        }
        self._zen_cover_frame = frame
        if self._has_cover_image then self.menu._has_cover_images = true end
        if hydrate_later then queue_cover_hydration(self) end

        local content = VerticalGroup:new{ align = "center", cover }
        if strip_h > 0 then
            local lines = VerticalGroup:new{ align = "center" }
            if show_title and metadata then
                table.insert(lines, TextWidget:new{
                    text = (not metadata.ignore_meta and metadata.title) or fallback_title(self.filepath),
                    face = library_font.getFace(library_font.scaleValue(16)),
                    bold = true,
                    max_width = self.width - Screen:scaleBySize(12),
                    truncate_with_ellipsis = true,
                    padding = 0,
                })
            end
            if show_author and metadata and metadata.authors then
                table.insert(lines, TextWidget:new{
                    text = metadata.authors:match("^[^\n]+") or metadata.authors,
                    face = library_font.getFace(library_font.scaleValue(13)),
                    max_width = self.width - Screen:scaleBySize(12),
                    truncate_with_ellipsis = true,
                    padding = 0,
                })
            end
            table.insert(content, CenterContainer:new{
                dimen = Geom:new{ w = self.width, h = strip_h },
                lines,
            })
        end
        if self._underline_container[1] then self._underline_container[1]:free() end
        self._underline_container[1] = content
    end

    function ZenMosaicItem:onFocus()
        self._underline_container.color = Blitbuffer.COLOR_BLACK
        return true
    end

    function ZenMosaicItem:onUnfocus()
        self._underline_container.color = Blitbuffer.COLOR_WHITE
        return true
    end

    function ZenMosaicItem:onTapSelect()
        if self._zen_is_book and not is_file_manager_select_mode()
                and self.menu.select_directory == nil and self.menu.select_file == nil then
            local set_cover = rawget(_G, "__ZEN_UI_SET_OPENING_BANNER_COVER")
            if type(set_cover) == "function" then set_cover(self._zen_cover_frame) end
        end
        self.menu:onMenuSelect(self.entry)
        return true
    end

    function ZenMosaicItem:onHoldSelect()
        self.menu:onMenuHold(self.entry)
        return true
    end

    local function paint_circle(bb, cx, cy, radius, color)
        for row = -radius, radius do
            local half = math.floor(math.sqrt(math.max(0, radius * radius - row * row)))
            if half > 0 then bb:paintRectRGB32(cx - half, cy + row, 2 * half, 1, color) end
        end
    end

    local function paint_pill(bb, x, y, width, height, color)
        local radius = height / 2
        for row = 0, height - 1 do
            local dy = math.abs(row + 0.5 - radius)
            local dx = math.sqrt(math.max(0, radius * radius - dy * dy))
            local x0 = math.ceil(x + radius - dx)
            local x1 = math.floor(x + width - radius + dx)
            if x1 > x0 then bb:paintRectRGB32(x0, y + row, x1 - x0, 1, color) end
        end
    end

    local function paint_pentagon(bb, x, y, width, height, color)
        local rect_h = math.floor(height * 30 / 42)
        bb:paintRectRGB32(x, y, width, rect_h, color)
        local tip_h = height - rect_h
        for row = 0, tip_h - 1 do
            local row_w = math.max(2, math.floor(width * (1 - (row + 1) / tip_h)))
            bb:paintRectRGB32(x + math.floor((width - row_w) / 2), y + rect_h + row, row_w, 1, color)
        end
    end

    local function paint_check(bb, x, y, width, height, color)
        local thickness = math.max(2, math.floor(math.min(width, height) / 8))
        local function line(x0, y0, x1, y1)
            local steps = math.max(math.abs(x1 - x0), math.abs(y1 - y0))
            if steps == 0 then steps = 1 end
            for step = 0, steps do
                local t = step / steps
                bb:paintRectRGB32(math.floor(x0 + t * (x1 - x0)),
                    math.floor(y0 + t * (y1 - y0)), thickness, thickness, color)
            end
        end
        local lx0, ly0 = x + math.floor(width * 0.08), y + math.floor(height * 0.62)
        local lx1, ly1 = x + math.floor(width * 0.30), y + math.floor(height * 0.82)
        line(lx0, ly0, lx1, ly1)
        line(lx1, ly1, x + math.floor(width * 0.82), y + math.floor(height * 0.18))
    end

    local function badge_colors(config)
        local badge = config.browser_cover_badges or {}
        local color = badge.badge_color
        local is_dark = color == nil or (type(color) == "table"
            and color[1] == 0 and color[2] == 0 and color[3] == 0)
        return utils.getBadgeColor(config), is_dark and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK
    end

    local function badge_size(frame, config)
        local base = math.max(Screen:scaleBySize(20), math.floor(frame.dimen.w * 0.14))
        return math.floor(base * utils.getBadgeScale(config))
    end

    local function banner_size(item, frame, config)
        local width = tonumber(item.width) or frame.dimen.w
        local height = tonumber(item.height) or frame.dimen.h
        local base = math.max(math.floor(math.min(width, height) / 8),
            math.floor(frame.dimen.w * 0.14))
        return math.floor(base * utils.getBadgeScale(config))
    end

    local function badge_text(item, key, text, size, color)
        local cached = item[key]
        if cached and (cached.text ~= text or cached.size ~= size or cached.color ~= color) then
            cached.widget:free()
            cached = nil
        end
        if not cached then
            cached = {
                text = text,
                size = size,
                color = color,
                widget = TextWidget:new{
                    text = text,
                    face = Font:getFace("cfont", size),
                    bold = true,
                    fgcolor = color,
                    padding = 0,
                },
            }
            item[key] = cached
        end
        return cached.widget
    end

    local function paint_page_badge(item, bb, text, config)
        local frame = item._zen_cover_frame
        if not frame or not frame.dimen then return end
        local size = badge_size(frame, config)
        local color, foreground = badge_colors(config)
        local widget = badge_text(item, "_zen_pages_badge", text, math.max(7, math.floor(size * 0.24)), foreground)
        local widget_size = widget:getSize()
        local height = math.floor(size * 0.85)
        local width = widget_size.w + 2 * math.floor(size * 0.12)
        local inset = utils.getBadgeInset(math.floor(height / 2))
        local x = frame.dimen.x + inset
        local y = frame.dimen.y + frame.dimen.h - height - inset
        paint_pill(bb, x - 2, y - 2, width + 4, height + 4, foreground)
        paint_pill(bb, x, y, width, height, color)
        widget:paintTo(bb, x + math.floor((width - widget_size.w) / 2),
            y + math.floor((height - widget_size.h) / 2))
    end

    local function paint_series_badge(item, bb, text, config)
        local frame = item._zen_cover_frame
        if not frame or not frame.dimen then return end
        local size = badge_size(frame, config)
        local radius = math.floor(size / 2)
        local color, foreground = badge_colors(config)
        local font_size = math.max(7, math.floor(size * 0.26))
        local widget = badge_text(item, "_zen_series_badge", text, font_size, foreground)
        while font_size > 7 and widget:getSize().w > math.floor(radius * 1.3) do
            font_size = font_size - 1
            widget = badge_text(item, "_zen_series_badge", text, font_size, foreground)
        end
        local widget_size = widget:getSize()
        local inset = utils.getBadgeInset(radius)
        local x = frame.dimen.x + frame.dimen.w - radius - inset
        local y = frame.dimen.y + frame.dimen.h - radius - inset
        paint_circle(bb, x, y, radius + 2, foreground)
        paint_circle(bb, x, y, radius, color)
        widget:paintTo(bb, x - math.floor(widget_size.w / 2), y - math.floor(widget_size.h / 2))
    end

    local function paint_progress_badge(item, bb, config)
        local badge = config.browser_cover_badges or {}
        if badge.show_mosaic_progress ~= true or not item._zen_effective_status then return end
        local effective_status = item._zen_effective_status
        local dim_finished = badge.dim_finished_books == true and effective_status == "complete"
        local is_new = effective_status == "new"
        local do_check = effective_status == "complete" and not dim_finished
        local do_tbr = effective_status == "tbr"
        local do_pause = effective_status == "abandoned"
        local do_pct = not is_new and not dim_finished and not do_check and not do_tbr and not do_pause
            and item.percent_finished ~= nil
        if not (do_check or do_tbr or do_pause or do_pct) then return end

        local frame = item._zen_cover_frame
        if not frame or not frame.dimen then return end
        local size = badge_size(frame, config)
        local width = math.floor(size * 1.2)
        local height = math.floor(size * 1.1)
        local color, foreground = badge_colors(config)
        local x = frame.dimen.x + frame.dimen.w - width - math.floor(width * 0.25)
        local y = frame.dimen.y + 2
        paint_pentagon(bb, x - 2, y - 2, width + 4, height + 4, foreground)
        paint_pentagon(bb, x, y, width, height, color)
        local border = math.max(1, frame.bordersize or 0)
        bb:paintRect(x - 2, y - 2, width + 4, border, Blitbuffer.COLOR_BLACK)

        local rect_h = math.floor(height * 30 / 42)
        if do_check then
            local padding = math.floor(width * 0.12)
            local icon_w = width - 2 * padding
            local icon_h = rect_h - 2 * math.floor(rect_h * 0.15)
            local square = math.min(icon_w, icon_h)
            paint_check(bb, x + padding + math.floor((icon_w - square) / 2),
                y + math.floor(rect_h * 0.15) + math.floor((icon_h - square) / 2), square, square, foreground)
            return
        end

        local text = do_tbr and "\u{F0150}"
            or (do_pause and "\u{F03E4}"
                or (math.floor(100 * item.percent_finished + 0.5) .. "%"))
        local font_size = (do_tbr or do_pause) and math.max(7, math.floor(size * 0.40))
            or math.max(7, math.floor(size * 0.24))
        local widget = badge_text(item, "_zen_progress_badge", text, font_size, foreground)
        local widget_size = widget:getSize()
        widget:paintTo(bb, x + math.floor((width - widget_size.w) / 2),
            y + math.floor((rect_h - widget_size.h) / 2))
    end

    local function paint_favorite_badge(item, bb, config)
        local badge = config.browser_cover_badges or {}
        if badge.show_favorite_badge ~= true or not item._zen_is_fav then return end
        local frame = item._zen_cover_frame
        if not frame or not frame.dimen then return end
        local size = badge_size(frame, config)
        local radius = math.floor(size * 0.45)
        local color, foreground = badge_colors(config)
        local inset = utils.getBadgeInset(radius)
        local x = BD.mirroredUILayout() and (frame.dimen.x + frame.dimen.w - radius - inset)
            or (frame.dimen.x + radius + inset)
        local y = frame.dimen.y + radius + inset
        paint_circle(bb, x, y, radius + 2, foreground)
        paint_circle(bb, x, y, radius, color)
        local widget = badge_text(item, "_zen_favorite_badge", "\u{2606}",
            math.max(6, math.floor(radius * 2 * 0.45)), foreground)
        local widget_size = widget:getSize()
        widget:paintTo(bb, x - math.ceil(widget_size.w / 2), y - math.ceil(widget_size.h / 2))
    end

    local function paint_native_progress(item, bb, config)
        local badge = config.browser_cover_badges or {}
        if badge.show_native_progress_bar ~= true or item.percent_finished == nil
                or item._zen_effective_status == "new" or item._zen_effective_status == "tbr"
                or item._zen_effective_status == "complete" then
            return
        end
        local frame = item._zen_cover_frame
        if not frame or not frame.dimen then return end
        local ProgressWidget = require("ui/widget/progresswidget")
        local height = Screen:scaleBySize(8)
        local margin = math.floor((badge_size(frame, config) - height) / 2)
        local width = math.max(1, frame.dimen.w - 2 * margin)
        local progress = item._zen_native_progress
        if not progress then
            progress = ProgressWidget:new{
                bgcolor = Blitbuffer.COLOR_WHITE,
                fillcolor = Blitbuffer.COLOR_BLACK,
                bordercolor = Blitbuffer.COLOR_BLACK,
                height = height,
                margin_h = Screen:scaleBySize(1),
                margin_v = Screen:scaleBySize(1),
                width = width,
                radius = math.floor(height / 2),
                bordersize = Size.border.default,
            }
            item._zen_native_progress = progress
        end
        progress.width = width
        progress.fillcolor = item._zen_effective_status == "abandoned"
            and Blitbuffer.COLOR_GRAY_6 or Blitbuffer.COLOR_BLACK
        progress:setPercentage(item.percent_finished)
        local x = frame.dimen.x + margin
        local y = frame.dimen.y + frame.dimen.h - badge_size(frame, config) + margin
        progress:paintTo(bb, x, y)

        if not bb.paintRoundedRect then return end
        local percentage = math.max(0, math.min(1, tonumber(progress.percentage) or 0))
        local fill_width = width - 2 * (progress.margin_h + progress.bordersize)
        local fill_height = height - 2 * (progress.margin_v + progress.bordersize)
        if percentage <= 0 or fill_width <= 0 or fill_height <= 0 then return end
        local fill_x = x + progress.margin_h + progress.bordersize
        local painted_width = math.ceil(fill_width * percentage)
        if BD.mirroredUILayout() then
            fill_x = fill_x + math.floor(fill_width * (1 - percentage))
        end
        bb:paintRect(fill_x, y + progress.margin_v + progress.bordersize,
            painted_width, fill_height, progress.bgcolor)
        bb:paintRoundedRect(fill_x, y + progress.margin_v + progress.bordersize,
            painted_width, fill_height, progress.fillcolor,
            math.floor(math.min(painted_width, fill_height) / 2))
    end

    local function paint_new_banner(item, bb, config)
        local badge = config.browser_cover_badges or {}
        if badge.show_new_banner ~= true or item._zen_effective_status ~= "new" then return end
        local frame = item._zen_cover_frame
        if not frame or not frame.dimen then return end
        local CornerBanner = require("common/ui/corner_banner")
        local _ = require("gettext")
        local size = banner_size(item, frame, config)
        local color, foreground = badge_colors(config)
        local span = math.floor(size * 2.5)
        CornerBanner.paint(bb, frame.dimen.x, frame.dimen.x + frame.dimen.w,
            frame.dimen.y, frame.dimen.h, span, math.floor(span * 0.35),
            _("New"), math.max(6, math.floor(size * 0.25)), color, foreground)
    end

    local function dim_finished_cover(item, bb, config)
        local badge = config.browser_cover_badges or {}
        if badge.dim_finished_books ~= true or item._zen_effective_status ~= "complete" then return end
        local frame = item._zen_cover_frame
        if not frame or not frame.dimen then return end
        local border = frame.bordersize or 0
        local width, height = frame.dimen.w - 2 * border, frame.dimen.h - 2 * border
        if width > 0 and height > 0 then
            bb:lightenRect(frame.dimen.x + border, frame.dimen.y + border, width, height, 0.4)
        end
    end

    function ZenMosaicItem:paintTo(bb, x, y)
        local menu = self.menu
        local config = plugin_config()
        local badges = config.browser_cover_badges or {}
        CoverWidget.set_dimmed_border(self._zen_cover_frame,
            badges.dim_finished_books == true
                and self._zen_effective_status == "complete")
        local is_library = menu and (menu.name == "filemanager" or menu.name == "history"
            or menu._zen_tab_id or menu._zen_coll_list or menu._zen_group_view
            or menu._zen_renderer == true)
        if is_library and self.width and self.height then
            local background_path = Background.library_path(plugin_ref)
            if background_path == "" or not Background.paintScreenRegion(bb, x, y,
                    x, y, self.width, self.height, background_path) then
                bb:paintRect(x, y, self.width, self.height, Blitbuffer.COLOR_WHITE)
            end
        end
        InputContainer.paintTo(self, bb, x, y)
        dim_finished_cover(self, bb, config)
        if not self._zen_is_book then
            FolderCover.paintDecorations(self, bb, config, x, y)
            return
        end
        paint_favorite_badge(self, bb, config)
        paint_native_progress(self, bb, config)
        paint_progress_badge(self, bb, config)
        if self._zen_page_label then paint_page_badge(self, bb, self._zen_page_label, config) end
        if self._zen_series_label then paint_series_badge(self, bb, self._zen_series_label, config) end
        paint_new_banner(self, bb, config)
    end

    function MosaicMenu:_updateItemsBuildUI()
        if self._zen_renderer == true then Background.applyToMenu(self) end
        local index_offset = (self.page - 1) * self.perpage
        local line_layout = {}
        local select_number
        for slot = 1, self.perpage do
            local index = index_offset + slot
            local entry = self.item_table[index]
            if not entry then break end
            if index == self.itemnumber then select_number = slot end
            local shortcut, shortcut_style
            if self.is_enable_shortcut then
                shortcut = self.item_shortcuts[slot]
                shortcut_style = (slot < 11 or slot > 20) and "square" or "grey_square"
            end
            if slot % self.nb_cols == 1 then
                if slot > 1 then table.insert(self.layout, line_layout) end
                line_layout = {}
                table.insert(self.item_group, VerticalSpan:new{ width = self.item_margin })
                local row = HorizontalGroup:new{}
                local container = self._do_center_partial_rows and CenterContainer or LeftContainer
                table.insert(self.item_group, container:new{
                    dimen = Geom:new{ w = self.inner_dimen.w, h = self.item_height },
                    row,
                })
                table.insert(row, HorizontalSpan:new{ width = self.item_margin })
                self._zen_mosaic_row = row
            end
            entry.idx = index
            local common = {
                height = self.item_height,
                width = self.item_width,
                entry = entry,
                text = Menu.getMenuText(entry),
                show_parent = self.show_parent,
                mandatory = entry.mandatory,
                dimen = self.item_dimen:copy(),
                shortcut = shortcut,
                shortcut_style = shortcut_style,
                menu = self,
                do_cover_image = self._do_cover_images,
                do_hint_opened = self._do_hint_opened,
            }
            -- Unknown MosaicMenu consumers retain the stock item class.
            local item = FolderCover.isSupported(entry, self) and ZenMosaicItem:new(common)
                or MosaicMenuItem:new(common)
            table.insert(self._zen_mosaic_row, item)
            table.insert(self._zen_mosaic_row, HorizontalSpan:new{ width = self.item_margin })
            table.insert(line_layout, item)
            if not item.bookinfo_found and not item.is_directory and not item.file_deleted then
                table.insert(self.items_to_update, item)
            end
        end
        if #line_layout > 0 then table.insert(self.layout, line_layout) end
        table.insert(self.item_group, VerticalSpan:new{ width = self.item_margin })
        self._zen_mosaic_row = nil
        return select_number
    end

    MosaicMenu._zen_renderer_patched = true
    MosaicMenu._zen_mosaic_item_class = ZenMosaicItem
    MosaicMenu._zen_mosaic_folder_item_class = ZenMosaicItem
    local ok, FileChooser = pcall(require, "ui/widget/filechooser")
    if ok and FileChooser and FileChooser._updateItemsBuildUI == stock_builder then
        FileChooser._updateItemsBuildUI = MosaicMenu._updateItemsBuildUI
    end
end

return apply_zen_renderer
