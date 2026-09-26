-- common/cover_utils.lua
-- Shared cover handling for filebrowser patches

local Blitbuffer = require("ffi/blitbuffer")
local library_font = require("modules/filebrowser/patches/library_font")
local TextBoxWidget = require("ui/widget/textboxwidget")
local RenderText = require("ui/rendertext")
local BD = require("ui/bidi")
local _ = require("gettext")
local DecodeCache = require("common/cover_decode_cache")
local RenderCache = require("common/cover_render_cache")
local FolderCoverFiles = require("common/folder_cover_files")
local lfs = require("libs/libkoreader-lfs")
local plugin_root = require("common/plugin_root")
local now = require("common/zen_logger").now

local CoverUtils = {}
do
    local ok, Device = pcall(require, "device")
    local screen = ok and Device and Device.screen
    local scaled = screen and type(screen.scaleBySize) == "function"
        and screen:scaleBySize(1)
    CoverUtils.BORDER_SIZE = scaled or 2
end
local ORNATE_FRAME_PATH = plugin_root and plugin_root .. "/images/ornate-cover-frame.svg" or nil
local ORNATE_FRAME_CACHE_KEY = (ORNATE_FRAME_PATH or "ornate-cover-frame") .. "\30background-v7"

-- Max list items per page that still render legible covers. Above this,
-- covers get too narrow for text. Enforced regardless of where the
-- setting was changed (zen UI, KOReader's coverbrowser, legacy saves).
CoverUtils.MAX_FILES_PER_PAGE = 12

-- Read files_per_page, clamp to MAX, and self-heal the persisted setting
-- if it was saved too high (e.g. by KOReader's own spinner). Returns the
-- clamped value, or nil if unset (let ListMenu compute its default).
function CoverUtils.getFilesPerPage()
    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok then return nil end
    local v = BookInfoManager:getSetting("files_per_page")
    if not v then return nil end
    if v > CoverUtils.MAX_FILES_PER_PAGE then
        v = CoverUtils.MAX_FILES_PER_PAGE
        BookInfoManager:saveSetting("files_per_page", v)
        local ok_fc, FileChooser = pcall(require, "ui/widget/filechooser")
        if ok_fc and FileChooser then FileChooser.files_per_page = v end
        -- Also clamp the live file_chooser instance if one already exists,
        -- so an in-flight render uses the capped value (not its own stale field).
        local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
        local fm = ok_fm and FM and FM.instance
        if fm and fm.file_chooser then fm.file_chooser.files_per_page = v end
    end
    return v
end

-- ============================================================
-- Helper: get_upvalue
-- ============================================================

function CoverUtils.getUpvalue(fn, name)
    if type(fn) ~= "function" then return nil end
    for i = 1, 64 do
        local upname, value = debug.getupvalue(fn, i)
        if not upname then break end
        if upname == name then return value end
    end
end

-- ============================================================
-- Cover mode (gallery / stack / normal)
-- ============================================================

function CoverUtils.getMode()
    local p = rawget(_G, "__ZEN_UI_PLUGIN")
    local cfg = (type(p) == "table" and type(p.config) == "table" and p.config)
        or require("config/manager").get()
    local fbc = type(cfg) == "table" and cfg.browser_folder_cover or nil
    local mode = type(fbc) == "table" and fbc.cover_mode or "normal"
    if mode == "gallery" then
        return "gallery", 4, true
    elseif mode == "stack" then
        return "stack", 4, true
    elseif mode == "none" then
        return "none", 0, false
    else
        return "normal", 1, false
    end
end

-- ============================================================
-- Cover ratio from settings (e.g., "2:3")
-- ============================================================

function CoverUtils.getRatio()
    local plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    local cfg = type(plugin) == "table" and plugin.config
        or require("config/manager").get()
    local ratio_str = type(cfg) == "table" and cfg.uniform_cover_ratio or "2:3"
    local num, den = ratio_str:match("(%d+):(%d+)")
    return (tonumber(num) or 2) / (tonumber(den) or 3)
end

-- ============================================================
-- Calculate portrait dimensions from max_w and max_h
-- ============================================================

function CoverUtils.calcDims(max_w, max_h)
    local ratio = CoverUtils.getRatio()
    if max_h * ratio <= max_w then
        return math.floor(max_h * ratio), max_h
    else
        return max_w, math.floor(max_w / ratio)
    end
end

function CoverUtils.getFolderPreviewBounds(mode, max_w, max_h, cover_count, slot)
    max_w, max_h = tonumber(max_w), tonumber(max_h)
    if not max_w or max_w < 1 or not max_h or max_h < 1 then return nil end
    local portrait_w, portrait_h = CoverUtils.calcDims(max_w, max_h)
    if mode == "gallery" and (tonumber(cover_count) or 0) > 1 then
        slot = tonumber(slot) or 1
        local left_w = math.floor((portrait_w - 1) / 2)
        local top_h = math.floor((portrait_h - 1) / 2)
        local cell_w = (slot == 2 or slot == 4) and portrait_w - 1 - left_w or left_w
        local cell_h = slot > 2 and portrait_h - 1 - top_h or top_h
        return math.max(1, cell_w), math.max(1, cell_h)
    end
    if mode == "stack" and (tonumber(cover_count) or 0) > 1 then
        local book_w = math.max(1, math.floor(portrait_w * 0.72))
        local book_h = math.max(1, math.floor(book_w * portrait_h / portrait_w))
        return book_w, book_h
    end
    return portrait_w, portrait_h
end

function CoverUtils.fitDims(max_w, max_h, source_w, source_h)
    source_w, source_h = tonumber(source_w), tonumber(source_h)
    if not source_w or source_w <= 0 or not source_h or source_h <= 0 then
        return CoverUtils.calcDims(max_w, max_h)
    end
    local scale = math.min(max_w / source_w, max_h / source_h)
    return math.max(1, math.floor(source_w * scale + 0.5)),
        math.max(1, math.floor(source_h * scale + 0.5))
end

function CoverUtils.getEmptyPlaceholderText(source)
    if source == "recently_read" then
        return _("Start reading a book to fill this space.")
    elseif source == "to_be_read" then
        return _("No TBR books found")
    elseif source == "custom_featured" or source == "custom_strip" then
        return _("No books found in the selected folder")
    end
    return _("No books found")
end

-- ============================================================
-- Generate placeholder cover from file path
-- ============================================================

local function ornate_background(width, height, paper)
    local cache_key = ORNATE_FRAME_CACHE_KEY
    local cached = RenderCache:get(cache_key, width, height)
    if cached then return cached end

    local background = Blitbuffer.new(width, height, Blitbuffer.TYPE_BBRGB32)
    background:paintRect(0, 0, width, height, paper)

    if ORNATE_FRAME_PATH and width >= 24 and height >= 36 then
        local ok_module, RenderImage = pcall(require, "ui/renderimage")
        local source_height = math.max(1, math.floor(width * 1.5 + 0.5))
        local ok_render, ornament, straight_alpha
        if ok_module then
            ok_render, ornament, straight_alpha = pcall(
                RenderImage.renderSVGImageFile, RenderImage,
                ORNATE_FRAME_PATH, width, source_height
            )
        end
        if ok_render and ornament then
            if source_height ~= height then
                local scaled = ornament:scale(width, height)
                ornament:free()
                ornament = scaled
            end
            if straight_alpha then
                background:alphablitFrom(ornament, 0, 0)
            else
                background:pmulalphablitFrom(ornament, 0, 0)
            end
            ornament:free()
        end
    end

    RenderCache:put(cache_key, width, height, background)
    return background
end

local function placeholder_cache_key(filepath, width, height, title, authors)
    local font_name = type(library_font.getFontName) == "function" and library_font.getFontName() or "cfont"
    local font_size = type(library_font.getBaseSize) == "function" and library_font.getBaseSize() or 18
    return table.concat({
        tostring(filepath), tostring(width), tostring(height), title, authors,
        tostring(font_name), tostring(font_size),
    }, "\30") .. "\30placeholder-v21"
end

local function generated_cover_spec(filepath, target_w, target_h, no_fallback, metadata)
    local width, height
    if target_w and target_h then
        width, height = CoverUtils.calcDims(target_w, target_h)
    elseif target_w then
        width, height = CoverUtils.calcDims(target_w, 9999)
    else
        width, height = CoverUtils.calcDims(9999, target_h or 300)
    end

    local title = ""
    local authors = ""
    local bookinfo_found = false
    local bookinfo = metadata
    if metadata == nil then
        local ok, BookInfoManager = pcall(require, "bookinfomanager")
        if ok then bookinfo = BookInfoManager:getBookInfo(filepath, false) end
    end
    if type(bookinfo) == "table" and not bookinfo.ignore_meta then
        bookinfo_found = true
        title = bookinfo.title or ""
        authors = bookinfo.authors or ""
        if authors:find("\n") then authors = authors:match("^([^\n]+)") end
    end

    if title == "" and not no_fallback then
        local fname = filepath:match("([^/]+)$") or ""
        title = fname:gsub("/$", ""):gsub("%.[^%.]+$", "")
    end

    if type(metadata) == "table" and metadata.title_only == true then
        authors = ""
    elseif not no_fallback then
        if title == "" then title = _("Unknown") end
        if authors == "" then authors = _("Unknown Author") end
    elseif bookinfo_found and authors == "" then
        authors = _("Unknown Author")
    end

    return placeholder_cache_key(filepath, width, height, title, authors),
        width, height, title, authors
end

local function paint_text_without_background(widget, bb, x, y, ink)
    local size = widget:getSize()
    local mask = widget._bb
    if mask and type(mask.invert) == "function" and type(bb.colorblitFrom) == "function" then
        mask:invert()
        bb:colorblitFrom(mask, x, y, 0, 0, size.w, size.h, ink)
    else
        widget:paintTo(bb, x, y)
    end
end

local function finish_generated(cache_key, final_bb, width, height, shared)
    if shared then
        local cached, cache_owned = RenderCache:putShared(
            cache_key, width, height, final_bb)
        return cached, width, height, cache_owned, cache_key
    end
    RenderCache:put(cache_key, width, height, final_bb)
    return final_bb, width, height
end

local function gen_cover(filepath, target_w, target_h, no_fallback, metadata, shared, cached_only)
    local cache_key, width, height, title, authors = generated_cover_spec(
        filepath, target_w, target_h, no_fallback, metadata)
    local cached
    if shared then
        cached = RenderCache:getShared(cache_key, width, height)
    else
        cached = RenderCache:get(cache_key, width, height)
    end
    if cached then return cached, width, height, shared == true, cache_key end
    if cached_only then return nil, width, height, false, cache_key end

    local paper = Blitbuffer.COLOR_WHITE
    local ink = Blitbuffer.COLOR_BLACK
    local final_bb = ornate_background(width, height, paper)

    local divider_y = math.floor(height * 0.61)
    local title_top = math.floor(height * 0.22)
    local title_area_h = math.max(1, divider_y - title_top - math.floor(height * 0.08))
    local author_top = divider_y + math.floor(height * 0.08)
    local author_area_h = math.max(1, math.floor(height * 0.16))
    local max_text_width = width - math.max(16, math.floor(width * 0.20))

    if max_text_width < 1 or title_area_h < 1 or author_area_h < 1 then
        return finish_generated(cache_key, final_bb, width, height, shared)
    end

    -- Title widget (skip when no text available)
    local title_font_size = library_font.scaleValue(20)
    local min_title_font = library_font.scaleValue(10)
    local title_widget = nil

    while title ~= "" and title_font_size >= min_title_font do
        if title_widget then title_widget:free() end
        local face = library_font.getFace(title_font_size)
        title_widget = TextBoxWidget:new{
            text = title,
            face = face,
            width = max_text_width,
            alignment = "center",
            bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
            bgcolor = Blitbuffer.COLOR_WHITE,
        }
        if title_widget:getSize().h <= title_area_h then break end
        title_font_size = title_font_size - 1
    end

    if title_widget and title_widget:getSize().h > title_area_h then
        local face = library_font.getFace(min_title_font)
        -- Ellipsis fallback re-runs makeLine with (width - ellipsis_width);
        -- skip it when too narrow or makeLine gets non-positive width.
        if max_text_width > RenderText:getEllipsisWidth(face) then
            title_widget:free()
            title_widget = TextBoxWidget:new{
                text = title,
                face = face,
                width = max_text_width,
                alignment = "center",
                bold = true,
                fgcolor = Blitbuffer.COLOR_BLACK,
                bgcolor = Blitbuffer.COLOR_WHITE,
                height = title_area_h,
                height_adjust = true,
                height_overflow_show_ellipsis = true,
            }
        end
    end
    if title_widget then title_widget.handleEvent = function() return false end end

    -- Author widget (skip when no text available)
    local authors_font_size = library_font.scaleValue(16)
    local min_authors_font = library_font.scaleValue(6)
    local authors_widget = nil

    while authors ~= "" and authors_font_size >= min_authors_font do
        if authors_widget then authors_widget:free() end
        local face = library_font.getFace(authors_font_size)
        authors_widget = TextBoxWidget:new{
            text = authors,
            face = face,
            width = max_text_width,
            alignment = "center",
            fgcolor = Blitbuffer.COLOR_BLACK,
            bgcolor = Blitbuffer.COLOR_WHITE,
        }
        if authors_widget:getSize().h <= author_area_h then break end
        authors_font_size = authors_font_size - 1
    end

    if authors_widget and authors_widget:getSize().h > author_area_h then
        local face = library_font.getFace(min_authors_font)
        if max_text_width > RenderText:getEllipsisWidth(face) then
            authors_widget:free()
            authors_widget = TextBoxWidget:new{
                text = authors,
                face = face,
                width = max_text_width,
                alignment = "center",
                fgcolor = Blitbuffer.COLOR_BLACK,
                bgcolor = Blitbuffer.COLOR_WHITE,
                height = author_area_h,
                height_adjust = true,
                height_overflow_show_ellipsis = true,
            }
        end
    end
    if authors_widget then
        authors_widget.handleEvent = function() return false end
    end

    -- Paint
    if title_widget then
        local title_y = title_top + math.floor((title_area_h - title_widget:getSize().h) / 2)
        paint_text_without_background(
            title_widget, final_bb,
            math.max(0, (width - title_widget:getSize().w) / 2), title_y, ink
        )
        title_widget:free()
    end

    if authors_widget then
        local authors_y = author_top + math.floor((author_area_h - authors_widget:getSize().h) / 2)
        paint_text_without_background(
            authors_widget, final_bb,
            math.max(0, (width - authors_widget:getSize().w) / 2), authors_y, ink
        )
        authors_widget:free()
    end

    return finish_generated(cache_key, final_bb, width, height, shared)
end

function CoverUtils.genCover(filepath, target_w, target_h, no_fallback, metadata)
    return gen_cover(filepath, target_w, target_h, no_fallback, metadata, false)
end

function CoverUtils.getCachedGeneratedCover(filepath, target_w, target_h, no_fallback, metadata)
    return gen_cover(filepath, target_w, target_h, no_fallback, metadata, false, true)
end

function CoverUtils.hasCachedGeneratedCover(filepath, target_w, target_h, no_fallback, metadata)
    local cache_key, width, height = generated_cover_spec(
        filepath, target_w, target_h, no_fallback, metadata)
    if type(RenderCache.touchExact) == "function" then
        return RenderCache:touchExact(cache_key, width, height)
    end
    return RenderCache:hasExact(cache_key, width, height)
end

-- Returns an immutable leased bitmap and its cache key when the budget allows.
function CoverUtils.genCoverShared(filepath, target_w, target_h, no_fallback, metadata)
    return gen_cover(filepath, target_w, target_h, no_fallback, metadata, true)
end

-- ============================================================
-- Render a real cover with the same scale-and-crop policy as library and Home.
-- ============================================================

function CoverUtils.scaleCover(cover_bb, _src_w, _src_h, target_w, target_h, cache_key)
    if not cover_bb then return nil end
    return RenderCache:render(cache_key or tostring(cover_bb), cover_bb, target_w, target_h)
end
-- ============================================================
-- Explicit cover file detection and loading
-- ============================================================

function CoverUtils.loadExplicitCover(path, max_w, max_h)
    max_w, max_h = tonumber(max_w), tonumber(max_h)
    if not max_w or max_w < 1 or not max_h or max_h < 1 then
        max_w, max_h = nil, nil
    end
    local ok_attr, attr = pcall(lfs.attributes, path)
    local signature = ok_attr and type(attr) == "table" and attr.mode == "file"
        and table.concat({
            tostring(attr.modification), tostring(attr.change), tostring(attr.size),
        }, "\31") or nil
    local key = table.concat({
        "zen-explicit", tostring(path), tostring(max_w), tostring(max_h),
    }, "\31")
    local bb = signature and type(DecodeCache.get) == "function"
        and DecodeCache:get(key, signature) or nil
    if not bb then
        local RenderImage = require("ui/renderimage")
        local ok, decoded = pcall(function()
            return RenderImage:renderImageFile(path, false)
        end)
        if not ok or not decoded then return nil end
        bb = decoded
        if max_w and max_h then
            local width, height = bb:getWidth(), bb:getHeight()
            local scale = math.min(1, math.max(max_w / width, max_h / height))
            if scale < 1 then
                local ok_scale, scaled = pcall(RenderImage.scaleBlitBuffer,
                    RenderImage, bb, math.ceil(width * scale), math.ceil(height * scale))
                if ok_scale and scaled then bb = scaled end
            end
        end
        if signature and type(DecodeCache.put) == "function" then
            DecodeCache:put(key, signature, bb)
        end
    end
    return {
        data = bb,
        w = bb:getWidth(),
        h = bb:getHeight(),
        alpha = true,
    }
end

function CoverUtils.loadExplicitCovers(path, mode, max_w, max_h)
    local files = FolderCoverFiles.find(path, mode)
    if not next(files) then return nil, false end

    local result = {}
    for i = 1, 4 do
        if files[i] then
            local cover = CoverUtils.loadExplicitCover(files[i], max_w, max_h)
            if cover then table.insert(result, cover) end
        end
    end
    return #result > 0 and result or nil, true
end

-- ============================================================
-- Collect covers from directory
-- ============================================================

function CoverUtils.collect(dir_path, chooser, max_covers, _need_copy, entries, cover_specs,
        cover_offset, cached_only)
    local covers = {}
    local needs_hydration = false

    if not entries then
        if not chooser then return covers end
        -- Reuse the browser pipeline so cover order matches the opened folder.
        if type(chooser.genItemTableFromPath) == "function" then
            local was_collecting = chooser._zen_folder_cover_collect
            chooser._zen_folder_cover_collect = true
            local ok, item_table = pcall(chooser.genItemTableFromPath, chooser, dir_path)
            chooser._zen_folder_cover_collect = was_collecting
            if ok and type(item_table) == "table" then
                entries = item_table
            end
        end

        if not entries then
            local G = rawget(_G, "G_reader_settings")
            local collate = G and G:readSetting("collate") or "strcoll"
            local ok, iter, dir_obj = pcall(lfs.dir, dir_path)
            if not ok then return covers end
            local doc_exts = { epub=1, pdf=1, djvu=1, cbz=1, cbr=1, mobi=1, azw3=1, fb2=1, txt=1, rtf=1, html=1, chm=1, zip=1, kpub=1, epub3=1 }
            local files = {}
            for f in iter, dir_obj do
                if f:sub(1,1) ~= "." then
                    local ext = (f:match("%.([^%.]+)$") or ""):lower()
                    if doc_exts[ext] then
                        table.insert(files, { name = f, path = dir_path .. "/" .. f })
                    end
                end
            end

            if collate == "access" or collate == "modification" or collate == "creation" then
                local time_field = collate
                if time_field == "creation" then time_field = "modification" end -- lfs doesn't have creation, fallback to mod
                for _i, item in ipairs(files) do
                    local fattr = lfs.attributes(item.path)
                    item.time = fattr and fattr[time_field] or 0
                end
                local rev = G:isTrue("reverse_collate")
                table.sort(files, function(a, b)
                    if a.time == b.time then return a.name:lower() < b.name:lower() end
                    if rev then return a.time < b.time else return a.time > b.time end
                end)
            else
                local rev = G:isTrue("reverse_collate")
                table.sort(files, function(a, b)
                    if rev then return a.name:lower() > b.name:lower() else return a.name:lower() < b.name:lower() end
                end)
            end

            entries = {}
            for i = 1, math.min(#files, max_covers * 2) do
                table.insert(entries, { is_file = true, file = files[i].path })
            end
        end
    end

    if not entries then return covers end

    local ok, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok then return covers end

    local mode = CoverUtils.getMode()
    cover_offset = tonumber(cover_offset) or 0
    local expected_count = cover_offset + math.min(max_covers, #entries)
    local function enabled(value)
        return value == true or value == "Y" or value == 1
    end
    local function has_real_cover(info)
        return type(info) == "table" and enabled(info.cover_fetched)
            and enabled(info.has_cover) and not enabled(info.ignore_cover)
    end

    for entry_index, entry in ipairs(entries) do
        if (entry.is_file or entry.file) and #covers < max_covers then
            local fpath = entry.path or entry.file
            local _fname = (fpath:match("([^/]+)$") or ""):lower()
            if not FolderCoverFiles.isManaged(_fname) then
                local preview_w, preview_h
                if type(cover_specs) == "table" then
                    preview_w, preview_h = CoverUtils.getFolderPreviewBounds(
                        mode, cover_specs.max_cover_w, cover_specs.max_cover_h,
                        expected_count, cover_offset + entry_index)
                end
                local preview_specs = preview_w and preview_h and {
                    max_cover_w = preview_w,
                    max_cover_h = preview_h,
                } or cover_specs
                local cached_cover
                if cached_only and mode == "normal" and preview_w and preview_h
                        and type(cover_specs) == "table" and cover_specs.uniform ~= false then
                    cached_cover = RenderCache:get(fpath, preview_w, preview_h)
                    if cached_cover then
                        table.insert(covers, {
                            data = cached_cover,
                            w = preview_w,
                            h = preview_h,
                        })
                    end
                end
                local bookinfo
                local invalid = false
                if not cached_cover then
                    bookinfo = type(DecodeCache.getFreshMetadata) == "function"
                        and DecodeCache:getFreshMetadata(fpath, now(), 30) or nil
                    invalid = has_real_cover(bookinfo) and type(preview_specs) == "table"
                        and type(BookInfoManager.isCachedCoverInvalid) == "function"
                        and BookInfoManager.isCachedCoverInvalid(bookinfo, preview_specs)
                    if has_real_cover(bookinfo) and not invalid and preview_w and preview_h then
                        local cached_w, cached_h
                        if cover_specs.uniform == false then
                            cached_w, cached_h = CoverUtils.fitDims(
                                preview_w, preview_h, bookinfo.cover_w, bookinfo.cover_h)
                        elseif mode == "normal" then
                            cached_w, cached_h = preview_w, preview_h
                        else
                            cached_w, cached_h = CoverUtils.calcDims(preview_w, preview_h)
                        end
                        cached_cover = RenderCache:get(fpath, cached_w, cached_h)
                        if cached_cover then
                            table.insert(covers, {
                                data = cached_cover,
                                w = cached_w,
                                h = cached_h,
                            })
                        end
                    end
                end
                if not cached_cover and cached_only then
                    if bookinfo and not invalid and enabled(bookinfo.cover_fetched)
                            and not has_real_cover(bookinfo) then
                        local metadata = bookinfo or entry.doc_props
                        local cover_bb, pw, ph = CoverUtils.getCachedGeneratedCover(
                            fpath, preview_w or 200, preview_h or 300, nil, metadata)
                        if cover_bb then
                            table.insert(covers, { data = cover_bb, w = pw, h = ph })
                        else
                            needs_hydration = true
                            break
                        end
                    else
                        needs_hydration = true
                        break
                    end
                elseif not cached_cover then
                    if not bookinfo or invalid or has_real_cover(bookinfo)
                            or not enabled(bookinfo.cover_fetched) then
                        bookinfo = BookInfoManager:getBookInfo(fpath, true)
                    end
                end
                if not cached_only and not cached_cover and bookinfo and bookinfo.cover_bb
                        and has_real_cover(bookinfo) then
                    local cover_bb = bookinfo.cover_bb
                    bookinfo.cover_bb = nil
                    table.insert(covers, {
                        data = cover_bb,
                        w = bookinfo.cover_w,
                        h = bookinfo.cover_h,
                        cache_key = fpath,
                    })
                elseif not cached_only and not cached_cover and bookinfo then
                    if bookinfo and bookinfo.cover_bb then bookinfo.cover_bb:free() end
                    local metadata = bookinfo or entry.doc_props
                    local cover_bb, pw, ph = CoverUtils.genCover(
                        fpath, preview_w or 200, preview_h or 300, nil, metadata)
                    if cover_bb then
                        table.insert(covers, { data = cover_bb, w = pw, h = ph })
                    end
                end
            end
        end
    end

    return covers, needs_hydration
end

-- ============================================================
-- DRAWING FUNCTIONS
-- ============================================================

-- FrameContainer bg for covers: gray on eink (dark mode inverts once -> dark gray);
-- white on LCD/non-eink where color inversion doesn't apply.
local function coverBg()
    local ok, Device = pcall(require, "device")
    if ok and not Device:hasEinkScreen() then
        return Blitbuffer.COLOR_WHITE
    end
    return Blitbuffer.COLOR_LIGHT_GRAY
end

local function previewCover(cover, max_w, max_h, uniform, ImageWidget)
    if type(cover) ~= "table" or cover.data == nil then cover = { data = cover } end
    local source_w, source_h = tonumber(cover.w), tonumber(cover.h)
    if not source_w or source_w <= 0 or not source_h or source_h <= 0 then
        local ok, width, height = pcall(function()
            return cover.data:getWidth(), cover.data:getHeight()
        end)
        if ok then source_w, source_h = width, height end
    end

    local width, height, scale_factor
    if uniform == false then
        width, height = CoverUtils.fitDims(max_w, max_h, source_w, source_h)
        scale_factor = 0
    else
        width, height = CoverUtils.calcDims(max_w, max_h)
        if source_w and source_w > 0 and source_h and source_h > 0 then
            scale_factor = math.max(width / source_w, height / source_h)
        end
    end
    if cover.cache_key then
        cover.data = RenderCache:render(cover.cache_key, cover.data, width, height)
        source_w, source_h = width, height
    end
    if source_w == width and source_h == height then
        scale_factor = 1
    end
    return ImageWidget:new{
        image = cover.data,
        image_disposable = true,
        alpha = cover.alpha == true,
        width = width,
        height = height,
        scale_factor = scale_factor,
    }, width, height
end

function CoverUtils.galleryCacheKey(identity, entries, portrait_w, portrait_h, uniform)
    if not identity or type(entries) ~= "table" then return nil end
    local parts = {
        "zen-gallery-v1", tostring(identity), tostring(portrait_w), tostring(portrait_h),
        tostring(uniform ~= false), tostring(CoverUtils.getRatio()),
        tostring(library_font.getFontName()), tostring(library_font.getBaseSize()),
    }
    for index = 1, math.min(4, #entries) do
        local entry = entries[index]
        local path = type(entry) == "table" and (entry.path or entry.file) or entry
        if not path then return nil end
        local metadata = type(DecodeCache.getFreshMetadata) == "function"
            and DecodeCache:getFreshMetadata(path, now(), 30) or nil
        if type(metadata) ~= "table" then return nil end
        parts[#parts + 1] = table.concat({
            tostring(path), tostring(metadata.filesize), tostring(metadata.filemtime),
            tostring(metadata.cover_fetched), tostring(metadata.has_cover),
            tostring(metadata.cover_sizetag), tostring(metadata.ignore_cover),
            tostring(metadata.ignore_meta),
            tostring(metadata.cover_w), tostring(metadata.cover_h),
            tostring(metadata.title), tostring(metadata.authors),
        }, "\30")
    end
    return table.concat(parts, "\31")
end

local gallery_rect_cache = { values = {}, order = {} }
local GalleryImageWidget

local function rememberGalleryRects(cache_key, rects)
    if not cache_key then return end
    if not gallery_rect_cache.values[cache_key] then
        gallery_rect_cache.order[#gallery_rect_cache.order + 1] = cache_key
    end
    gallery_rect_cache.values[cache_key] = rects
    while #gallery_rect_cache.order > 64 do
        gallery_rect_cache.values[table.remove(gallery_rect_cache.order, 1)] = nil
    end
end

local function galleryFrame(image_bb, portrait_w, portrait_h, border, bg, cover_rects)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    if not GalleryImageWidget then
        local ImageWidget = require("ui/widget/imagewidget")
        local Screen = require("device").screen
        GalleryImageWidget = ImageWidget:extend{}
        function GalleryImageWidget:paintTo(bb, x, y)
            if self.hide then return end
            ImageWidget.paintTo(self, bb, x, y)
            if not Screen.night_mode then return end
            for _i, rect in ipairs(self.cover_rects or {}) do
                bb:invertRect(x + rect.x, y + rect.y, rect.w, rect.h)
            end
        end
    end
    local dimen = { w = portrait_w + 2 * border, h = portrait_h + 2 * border }
    return FrameContainer:new{
        padding = 0,
        bordersize = border,
        width = dimen.w,
        height = dimen.h,
        background = bg,
        CenterContainer:new{
            dimen = { w = portrait_w, h = portrait_h },
            GalleryImageWidget:new{
                image = image_bb,
                image_disposable = true,
                width = portrait_w,
                height = portrait_h,
                scale_factor = 1,
                original_in_nightmode = false,
                cover_rects = cover_rects,
            },
        },
        overlap_align = "center",
    }
end

function CoverUtils.getCachedGallery(cache_key, portrait_w, portrait_h, border, bg_fn)
    if not cache_key then return nil end
    local cached = RenderCache:get(cache_key, portrait_w, portrait_h)
    if not cached then return nil end
    local bg = bg_fn and bg_fn() or coverBg()
    return galleryFrame(cached, portrait_w, portrait_h, border, bg,
        gallery_rect_cache.values[cache_key])
end

function CoverUtils.hasCachedGallery(cache_key, portrait_w, portrait_h)
    if not cache_key then return false end
    if type(RenderCache.touchExact) == "function" then
        return RenderCache:touchExact(cache_key, portrait_w, portrait_h)
    end
    return type(RenderCache.hasExact) == "function"
        and RenderCache:hasExact(cache_key, portrait_w, portrait_h) or false
end

function CoverUtils.drawGallery(covers, portrait_w, portrait_h, border, bg_fn, uniform,
        cache_key)
    local bg = bg_fn and bg_fn() or coverBg()
    if not bg_fn then
        for _i, cover in ipairs(covers) do
            if cover.alpha == true then
                bg = Blitbuffer.COLOR_LIGHT_GRAY
                break
            end
        end
    end
    local cached = CoverUtils.getCachedGallery(
        cache_key, portrait_w, portrait_h, border, bg_fn)
    if cached then
        for index = 1, #covers do
            local data = covers[index] and covers[index].data
            if data and type(data.free) == "function" then pcall(data.free, data) end
        end
        return cached, true, false
    end
    local sep = 1
    local half_w = math.floor((portrait_w - sep) / 2)
    local half_w2 = portrait_w - sep - half_w
    local half_h = math.floor((portrait_h - sep) / 2)
    local half_h2 = portrait_h - sep - half_h
    local cell_dims = {
        { w = half_w,  h = half_h  },
        { w = half_w2, h = half_h  },
        { w = half_w,  h = half_h2 },
        { w = half_w2, h = half_h2 },
    }

    local CenterContainer = require("ui/widget/container/centercontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local ImageWidget = require("ui/widget/imagewidget")
    local LineWidget = require("ui/widget/linewidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")

    local cells = {}
    local cover_rects = {}
    local cell_origins = {
        { x = 0, y = 0 },
        { x = half_w + sep, y = 0 },
        { x = 0, y = half_h + sep },
        { x = half_w + sep, y = half_h + sep },
    }
    for i = 1, 4 do
        local c = covers[i]
        local cd = cell_dims[i]
        if c then
            local image, image_w, image_h = previewCover(
                c, cd.w, cd.h, uniform, ImageWidget)
            image.original_in_nightmode = false
            cover_rects[#cover_rects + 1] = {
                x = cell_origins[i].x + math.floor((cd.w - image_w) / 2),
                y = cell_origins[i].y + math.floor((cd.h - image_h) / 2),
                w = image_w,
                h = image_h,
            }
            cells[i] = CenterContainer:new{
                dimen = { w = cd.w, h = cd.h },
                image,
            }
        else
            cells[i] = CenterContainer:new{
                dimen = { w = cd.w, h = cd.h },
                VerticalSpan:new{ width = 1 },
            }
        end
    end

    local dimen = { w = portrait_w + 2 * border, h = portrait_h + 2 * border }
    local inner = CenterContainer:new{
        dimen = { w = portrait_w, h = portrait_h },
        VerticalGroup:new{
            HorizontalGroup:new{
                cells[1],
                LineWidget:new{
                    background = Blitbuffer.COLOR_WHITE,
                    dimen = { w = sep, h = half_h },
                },
                cells[2],
            },
            LineWidget:new{
                background = Blitbuffer.COLOR_WHITE,
                dimen = { w = portrait_w, h = sep },
            },
            HorizontalGroup:new{
                cells[3],
                LineWidget:new{
                    background = Blitbuffer.COLOR_WHITE,
                    dimen = { w = sep, h = half_h2 },
                },
                cells[4],
            },
        },
    }
    local ok_buffer, composite = pcall(
        Blitbuffer.new, portrait_w, portrait_h, Blitbuffer.TYPE_BBRGB32)
    local ok_paint = false
    if ok_buffer and composite then
        composite:paintRect(0, 0, portrait_w, portrait_h, bg)
        ok_paint = pcall(inner.paintTo, inner, composite, 0, 0)
    end
    if not ok_paint then
        if composite and type(composite.free) == "function" then composite:free() end
        return FrameContainer:new{
            padding = 0,
            bordersize = border,
            width = dimen.w,
            height = dimen.h,
            background = bg,
            inner,
            overlap_align = "center",
        }, false, false
    end
    inner:free()
    local stored = false
    if cache_key then
        RenderCache:put(cache_key, portrait_w, portrait_h, composite)
        stored = type(RenderCache.hasExact) == "function"
            and RenderCache:hasExact(cache_key, portrait_w, portrait_h) or false
        if stored then rememberGalleryRects(cache_key, cover_rects) end
    end
    return galleryFrame(
        composite, portrait_w, portrait_h, border, bg, cover_rects), false, stored
end

function CoverUtils.drawStack(covers, portrait_w, portrait_h, border, bg_fn, uniform)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local ImageWidget = require("ui/widget/imagewidget")
    local OverlapGroup = require("ui/widget/overlapgroup")
    local VerticalSpan = require("ui/widget/verticalspan")

    local stack_count = #covers
    local dimen = { w = portrait_w + 2 * border, h = portrait_h + 2 * border }
    if stack_count == 0 then
        return FrameContainer:new{
            padding = 0,
            bordersize = border,
            width = dimen.w,
            height = dimen.h,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = { w = portrait_w, h = portrait_h },
                VerticalSpan:new{ width = 1 },
            },
            overlap_align = "center",
        }
    end

    -- A single cover uses the same sizing policy as an opened book.
    if stack_count == 1 then
        local image, image_w, image_h = previewCover(
            covers[1], portrait_w, portrait_h, uniform, ImageWidget)
        local frame_w, frame_h = image_w + 2 * border, image_h + 2 * border
        return FrameContainer:new{
            padding = 0,
            bordersize = border,
            width = frame_w,
            height = frame_h,
            background = covers[1].alpha == true
                and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = { w = image_w, h = image_h },
                image,
            },
            overlap_align = "center",
        }
    end

    -- Multi-book stack via OverlapGroup: each ImageWidget handles night mode at
    -- paint time, so the bg (FrameContainer white) and covers update immediately
    -- on night mode toggle without needing a page turn.
    local book_width  = math.floor(portrait_w * 0.72)
    local book_height = math.floor(book_width * (portrait_h / portrait_w))
    local base_x = math.floor((portrait_w - book_width) / 2)
    local base_y = math.floor((portrait_h - book_height) / 2)
    local step_x = math.floor(base_x / 2)
    local step_y = math.floor(base_y / 2)

    local n = math.min(stack_count, 4)
    local offsets
    if n == 2 then
        offsets = { { x = step_x, y = -step_y }, { x = -step_x, y = step_y } }
    elseif n == 3 then
        offsets = { { x = step_x, y = -step_y }, { x = 0, y = 0 }, { x = -step_x, y = step_y } }
    else
        -- 4 covers: outer pair at ±step, inner pair at ±step/3.
        local s3x = math.floor(step_x / 3)
        local s3y = math.floor(step_y / 3)
        offsets = {
            { x =  step_x, y = -step_y },
            { x =  s3x,    y = -s3y    },
            { x = -s3x,    y =  s3y    },
            { x = -step_x, y =  step_y },
        }
    end

    -- Insert children back-to-front: index 1 = bottom layer (painted first by OverlapGroup).
    local children = {}
    for i = n, 1, -1 do
        local cover = covers[i]
        local off = offsets[n - i + 1] or { x = 0, y = 0 }
        local image, image_w, image_h = previewCover(
            cover, book_width, book_height, uniform, ImageWidget)
        local frame_w, frame_h = image_w + 2 * border, image_h + 2 * border
        table.insert(children, FrameContainer:new{
            padding = 0,
            bordersize = border,
            width = frame_w,
            height = frame_h,
            background = cover.alpha == true
                and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
            overlap_offset = {
                math.floor((portrait_w - frame_w) / 2) + off.x,
                math.floor((portrait_h - frame_h) / 2) + off.y,
            },
            image,
        })
    end

    return FrameContainer:new{
        padding = 0,
        bordersize = border,
        width = dimen.w,
        height = dimen.h,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = { w = portrait_w, h = portrait_h },
            OverlapGroup:new{
                dimen = { w = portrait_w, h = portrait_h },
                allow_mirroring = false, -- don't flip manually-computed pixel offsets for RTL
                table.unpack(children),
            },
        },
        overlap_align = "center",
    }
end

function CoverUtils.drawNoImage(folder_name, portrait_w, portrait_h, border)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local ImageWidget = require("ui/widget/imagewidget")

    local bg = Blitbuffer.COLOR_WHITE
    local final_bb = CoverUtils.genCover(
        "zen-folder-placeholder:" .. folder_name,
        portrait_w,
        portrait_h,
        true,
        { title = folder_name, authors = "", title_only = true }
    )

    local dimen = { w = portrait_w + 2 * border, h = portrait_h + 2 * border }

    return FrameContainer:new{
        padding = 0,
        bordersize = border,
        width = dimen.w,
        height = dimen.h,
        background = bg,
        CenterContainer:new{
            dimen = { w = portrait_w, h = portrait_h },
            ImageWidget:new{
                image = final_bb,
                image_disposable = true,
                width = portrait_w,
                height = portrait_h,
                original_in_nightmode = true,
            },
        },
        overlap_align = "center",
    }
end

function CoverUtils.drawSingle(cover, portrait_w, portrait_h, border, uniform)
    local CenterContainer = require("ui/widget/container/centercontainer")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local ImageWidget = require("ui/widget/imagewidget")

    local image, image_w, image_h = previewCover(
        cover, portrait_w, portrait_h, uniform, ImageWidget)
    local bg = Blitbuffer.COLOR_LIGHT_GRAY
    local dimen = { w = image_w + 2 * border, h = image_h + 2 * border }

    return FrameContainer:new{
        padding = 0,
        bordersize = border,
        width = dimen.w,
        height = dimen.h,
        background = bg,
        CenterContainer:new{
            dimen = { w = image_w, h = image_h },
            image,
        },
        overlap_align = "center",
    }
end

-- ============================================================
-- UNIFIED ENTRY POINT
-- ============================================================

function CoverUtils.makeCover(path, chooser, options)
    options = options or {}

    -- Handle single book file
    if not options.is_folder then
        local ok, BookInfoManager = pcall(require, "bookinfomanager")

        local target_w = options.width or 200
        local target_h = options.height or 300

        -- Always use calcDims to get correct dimensions
        local final_w, final_h = CoverUtils.calcDims(target_w, target_h)

        if ok then
            local bookinfo = BookInfoManager:getBookInfo(path, true)

                if bookinfo and bookinfo.cover_bb and bookinfo.has_cover
                        and bookinfo.cover_fetched and not bookinfo.ignore_cover then
                local scaled_bb = CoverUtils.scaleCover(
                    bookinfo.cover_bb, bookinfo.cover_w, bookinfo.cover_h,
                    final_w, final_h, path)
                if scaled_bb then
                    return scaled_bb, final_w, final_h, "single", "real_cover"
                end
            end
        end

        local cover_bb = CoverUtils.genCover(path, final_w, final_h)
        return cover_bb, final_w, final_h, "single", "placeholder"
    end

    -- Handle folder
    local mode, max_covers, need_copy = CoverUtils.getMode()
    if options.max_covers then max_covers = options.max_covers end

    -- "none" mode: skip cover collection, show name-only placeholder immediately
    if mode == "none" then
        local fname = options.folder_name or (path:match("([^/]+)/?$") or path):gsub("/$", "")
        fname = BD.directory(fname)
        local border = CoverUtils.BORDER_SIZE
        local portrait_w, portrait_h = CoverUtils.calcDims(options.max_w or 200, options.max_h or 300)
        return CoverUtils.drawNoImage(fname, portrait_w, portrait_h, border), mode, "empty_folder", nil
    end

    local covers = options.covers_data
    local has_explicit = false
    if not covers or #covers == 0 then
        -- Auto-detect explicit cover image files (cover.jpg, cover1.jpg, etc.)
        covers, has_explicit = CoverUtils.loadExplicitCovers(
            path, mode, options.max_w or 200, options.max_h or 300)
    end
    if not has_explicit and (not covers or #covers == 0) then
        covers = CoverUtils.collect(path, chooser, max_covers, need_copy)
    end
    covers = covers or {}

    local folder_name = options.folder_name or (path:match("([^/]+)/?$") or path):gsub("/$", "")
    folder_name = BD.directory(folder_name)

    local border = CoverUtils.BORDER_SIZE
    local max_w = options.max_w or 200
    local max_h = options.max_h or 300

    local portrait_w, portrait_h = CoverUtils.calcDims(max_w, max_h)

    local cover_widget

    if #covers > 0 then
        if #covers == 1 then
            cover_widget = CoverUtils.drawSingle(
                covers[1], portrait_w, portrait_h, border, options.uniform)
        elseif mode == "gallery" then
            cover_widget = CoverUtils.drawGallery(
                covers, portrait_w, portrait_h, border, nil, options.uniform)
        elseif mode == "stack" then
            cover_widget = CoverUtils.drawStack(
                covers, portrait_w, portrait_h, border, nil, options.uniform)
        else
            cover_widget = CoverUtils.drawSingle(
                covers[1], portrait_w, portrait_h, border, options.uniform)
        end
        return cover_widget, mode, "folder_covers", covers
    end

    cover_widget = CoverUtils.drawNoImage(folder_name, portrait_w, portrait_h, border)
    return cover_widget, mode, "empty_folder", nil
end

return CoverUtils
