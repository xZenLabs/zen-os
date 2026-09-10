local M = {}
local BookOpenTap = require("common/book_open_tap")
local BookStatus = require("common/book_status")
local paths = require("common/paths")

M.BOOK_COUNT = 4

local function launcher_config(config)
    return type(config) == "table" and config or {}
end

function M.isEnabled(config, library_context)
    local cfg = launcher_config(config)
    return cfg.show_book_switcher == true
        and not (library_context == true and cfg.book_switcher_reader_only == true)
end

function M.pagePosition(config, library_context, button_page_count)
    if not M.isEnabled(config, library_context) then return nil end
    local plan = require("modules/menu/app_launcher/page_plan").build(
        button_page_count, config, library_context)
    for index, page in ipairs(plan) do
        if page.kind == "book_switcher" then return index end
    end
end

function M.rendererOptions(config)
    config = type(config) == "table" and config or {}
    local features = type(config.features) == "table" and config.features or {}
    local title_strip = type(config.mosaic_title_strip) == "table"
        and config.mosaic_title_strip or {}
    return {
        uniform = features.browser_cover_mosaic_uniform == true,
        show_title = title_strip.show_title == true,
        show_author = title_strip.show_author == true,
    }
end

function M.layout(opts)
    opts = opts or {}
    local Device = require("device")
    local TextWidget = require("ui/widget/textwidget")
    local cover_common = require("modules/filebrowser/patches/home/widgets/cover_common")
    local library_font = require("modules/filebrowser/patches/library_font")
    local Screen = Device.screen
    local width = math.max(1, tonumber(opts.width) or Screen:getWidth())
    local height = math.max(1, tonumber(opts.height) or Screen:getHeight())
    local padding = math.max(4, Screen:scaleBySize(8))
    local top_padding = padding + Screen:scaleBySize(8)
    local gap = math.max(2, Screen:scaleBySize(2))
    local inner_w = math.max(1, width - padding * 2)
    local max_content_h = math.max(1, height - top_padding - padding)
    local cell_w = math.max(24,
        math.floor((inner_w - gap * (M.BOOK_COUNT - 1)) / M.BOOK_COUNT))
    local render = M.rendererOptions(opts.config)
    local title_face = library_font.getFace(library_font.scaleValue(16))
    local author_face = library_font.getFace(library_font.scaleValue(13))
    local strip_padding = Screen:scaleBySize(3)
    local line_gap = Screen:scaleBySize(2)
    local strip_h = 0
    if render.show_title then
        local probe = TextWidget:new{
            text = "Ag", face = title_face, bold = true, padding = 0,
        }
        strip_h = strip_h + probe:getSize().h
        probe:free()
    end
    if render.show_title and render.show_author then strip_h = strip_h + line_gap end
    if render.show_author then
        local probe = TextWidget:new{ text = "Ag", face = author_face, padding = 0 }
        strip_h = strip_h + probe:getSize().h
        probe:free()
    end
    if strip_h > 0 then strip_h = strip_h + strip_padding * 2 end
    local cover_area_h = math.min(
        math.max(1, max_content_h - strip_h), Screen:scaleBySize(200))
    local cover_border = cover_common.BORDER_SIZE
    return {
        width = width,
        height = height,
        padding = padding,
        top_padding = top_padding,
        gap = gap,
        inner_w = inner_w,
        cell_w = cell_w,
        cell_h = cover_area_h + strip_h,
        cover_area_h = cover_area_h,
        cover_border = cover_border,
        cover_max_w = math.max(18, cell_w - cover_border * 2),
        cover_max_h = math.max(28, cover_area_h - cover_border * 2),
        render = render,
        title_face = title_face,
        author_face = author_face,
        strip_padding = strip_padding,
        line_gap = line_gap,
        strip_h = strip_h,
    }
end

local function fallback_title(path)
    local filename = (path or ""):match("([^/\\]+)$") or path or ""
    return filename:gsub("%.[^%.]+$", "")
end

local function metadata_without_cover(info)
    if type(info) ~= "table" then return false end
    local copy = {}
    for key, value in pairs(info) do
        if key ~= "cover_bb" then copy[key] = value end
    end
    return copy
end

local function rakuyomi_metadata(path)
    local ok_rakuyomi, Rakuyomi = pcall(require, "modules/filebrowser/patches/rakuyomi")
    if not ok_rakuyomi or type(Rakuyomi.getMetadata) ~= "function" then return nil end
    local ok_metadata, metadata = pcall(Rakuyomi.getMetadata, path)
    return ok_metadata and metadata or nil
end

local function load_book(path, BookInfoManager)
    local info
    if BookInfoManager and type(BookInfoManager.getBookInfo) == "function" then
        local ok_info, loaded = pcall(BookInfoManager.getBookInfo, BookInfoManager, path, true)
        if ok_info then info = loaded end
    end

    local metadata = metadata_without_cover(info)
    local title = info and not info.ignore_meta and info.title or nil
    local authors = info and not info.ignore_meta and info.authors or nil
    local external = rakuyomi_metadata(path)
    if external then
        if metadata == false then metadata = {} end
        title = external.title or title
        authors = external.authors or authors
        for key, value in pairs(external) do
            if key ~= "cover_bb" and value ~= nil then metadata[key] = value end
        end
    end

    local has_real_cover = info and info.cover_fetched and info.has_cover
        and not info.ignore_cover or false
    local cover_bb
    if info and info.cover_bb then
        if has_real_cover and type(info.cover_bb.copy) == "function" then
            cover_bb = info.cover_bb:copy()
        end
        if type(info.cover_bb.free) == "function" then info.cover_bb:free() end
        info.cover_bb = nil
    end

    return {
        path = path,
        title = title and title ~= "" and title or fallback_title(path),
        authors = authors or "",
        cover_bb = cover_bb,
        cover_w = info and tonumber(info.cover_w) or nil,
        cover_h = info and tonumber(info.cover_h) or nil,
        has_real_cover = has_real_cover,
        bookinfo = metadata,
    }
end

function M.loadBooks(limit, exclude_path)
    local count = math.min(M.BOOK_COUNT, math.max(1, math.floor(tonumber(limit) or M.BOOK_COUNT)))
    local ok_history, ReadHistory = pcall(require, "readhistory")
    if not ok_history or not ReadHistory then return {} end
    if type(ReadHistory.reload) == "function" then
        pcall(ReadHistory.reload, ReadHistory, false)
    end

    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok_bim then BookInfoManager = nil end
    local ok_kindle, Kindle = pcall(
        require, "modules/filebrowser/patches/kindle_virtual_library")
    local books = {}
    local seen = {}
    for _i, entry in ipairs(ReadHistory.hist or {}) do
        local path = entry and entry.file
        local in_library = type(path) == "string" and paths.isInHomeDir(path)
        local is_kindle = false
        if not in_library and ok_kindle and type(Kindle.isBookPath) == "function" then
            is_kindle = Kindle.isBookPath(path)
            in_library = is_kindle
        end
        local is_file = type(path) == "string" and path ~= ""
            and in_library
            and not BookStatus.isImageFile(path)
            and (is_kindle or not ok_lfs or lfs.attributes(path, "mode") == "file")
        if is_file and path ~= exclude_path and not seen[path] then
            seen[path] = true
            books[#books + 1] = load_book(path, BookInfoManager)
            if #books >= count then break end
        end
    end
    return books
end

function M.build(opts)
    opts = opts or {}
    local Blitbuffer = require("ffi/blitbuffer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Device = require("device")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local TextWidget = require("ui/widget/textwidget")
    local UIManager = require("ui/uimanager")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local _ = require("gettext")
    local cover_common = require("modules/filebrowser/patches/home/widgets/cover_common")

    local Screen = Device.screen
    local width = math.max(1, tonumber(opts.width) or Screen:getWidth())
    local height = math.max(1, tonumber(opts.height) or Screen:getHeight())
    local layout = M.layout{ width = width, height = height, config = opts.config }
    local padding = layout.padding
    local top_padding = layout.top_padding
    local gap = layout.gap
    local inner_w = layout.inner_w
    local cell_w = layout.cell_w
    local render = layout.render
    local books = type(opts.books) == "table" and opts.books
        or M.loadBooks(M.BOOK_COUNT, opts.exclude_path)
    local refs = { buttons = {}, layout_rows = {} }

    if #books == 0 then
        local message = TextBoxWidget:new{
            text = _("No books to switch to"),
            face = Font:getFace("smallinfofont", Screen:scaleBySize(18)),
            width = math.max(1, inner_w - padding * 2),
            alignment = "center",
            alignment_strict = true,
            height_adjust = true,
        }
        local message_h = math.max(Screen:scaleBySize(56), message:getSize().h)
        return VerticalGroup:new{
            align = "center",
            VerticalSpan:new{ width = padding },
            CenterContainer:new{ dimen = Geom:new{ w = width, h = message_h }, message },
            VerticalSpan:new{ width = padding },
        }, refs
    end

    local title_face = layout.title_face
    local author_face = layout.author_face
    local strip_h = layout.strip_h
    local cover_area_h = layout.cover_area_h
    local cover_border = layout.cover_border
    local cover_max_w = layout.cover_max_w
    local cover_max_h = layout.cover_max_h
    local cell_h = layout.cell_h

    local BookCell = InputContainer:extend{}

    function BookCell:init()
        self.dimen = self.dimen or Geom:new{ w = self.width, h = self.height }
        self.ges_events = {
            TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } },
        }
    end

    function BookCell:paintTo(bb, x, y)
        self.dimen.x = x
        self.dimen.y = y
        self[1]:paintTo(bb, x, y)
        if self.focused then
            local line = math.max(1, Screen:scaleBySize(2))
            bb:paintRect(x, y + self.height - line, self.width, line, Blitbuffer.COLOR_BLACK)
        end
    end

    function BookCell:onTapSelect(_arg, ges)
        if ges and ges.time ~= nil
                and not BookOpenTap.shouldOpen(self.book_path, ges.time) then return true end
        if self.callback then self.callback() end
        return true
    end

    function BookCell:onFocus()
        self.focused = true
        UIManager:setDirty(nil, "fast", self.dimen)
        return true
    end

    function BookCell:onUnfocus()
        self.focused = false
        UIManager:setDirty(nil, "fast", self.dimen)
        return true
    end

    local row = HorizontalGroup:new{ align = "center" }
    local layout_row = {}
    for index, book in ipairs(books) do
        local cover = cover_common.make_cover_widget(
            book, cover_max_w, cover_max_h, {
                border = cover_border,
                background = Blitbuffer.COLOR_LIGHT_GRAY,
                uniform = render.uniform,
            })
        local lines = VerticalGroup:new{ align = "center" }
        if render.show_title then
            lines[#lines + 1] = TextWidget:new{
                text = book.title or fallback_title(book.path),
                face = title_face,
                bold = true,
                max_width = math.max(1, cell_w - Screen:scaleBySize(12)),
                truncate_with_ellipsis = true,
                padding = 0,
            }
        end
        if render.show_author and book.authors and book.authors ~= "" then
            lines[#lines + 1] = TextWidget:new{
                text = book.authors:match("^[^\n]+") or book.authors,
                face = author_face,
                max_width = math.max(1, cell_w - Screen:scaleBySize(12)),
                truncate_with_ellipsis = true,
                padding = 0,
            }
        end
        local content = VerticalGroup:new{
            align = "center",
            CenterContainer:new{
                dimen = Geom:new{ w = cell_w, h = cover_area_h },
                cover,
            },
        }
        if strip_h > 0 then
            content[#content + 1] = CenterContainer:new{
                dimen = Geom:new{ w = cell_w, h = strip_h },
                lines,
            }
        end
        local callback = function()
            local set_cover = rawget(_G, "__ZEN_UI_SET_OPENING_BANNER_COVER")
            local banner_prepared = type(set_cover) == "function" and set_cover(cover) == true
            if type(opts.open_book) == "function" then
                opts.open_book(book.path, cover, function()
                    if banner_prepared then
                        local cancel_banner = rawget(_G, "__ZEN_UI_CANCEL_OPENING_BANNER")
                        if type(cancel_banner) == "function" then cancel_banner(true) end
                    end
                end)
            end
        end
        local cell = BookCell:new{
            width = cell_w,
            height = cell_h,
            dimen = Geom:new{ w = cell_w, h = cell_h },
            callback = callback,
            book_path = book.path,
            content,
        }
        cell._zen_book_switcher_cover = cover
        row[#row + 1] = cell
        layout_row[#layout_row + 1] = cell
        refs.buttons[#refs.buttons + 1] = { widget = cell, callback = callback }
        if index < #books then row[#row + 1] = HorizontalSpan:new{ width = gap } end
    end
    refs.layout_rows[1] = layout_row

    return VerticalGroup:new{
        align = "center",
        VerticalSpan:new{ width = top_padding },
        CenterContainer:new{ dimen = Geom:new{ w = width, h = cell_h }, row },
        VerticalSpan:new{ width = padding },
    }, refs
end

return M
