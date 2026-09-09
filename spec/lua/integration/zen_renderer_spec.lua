describe("Zen renderer", function()
    local MosaicMenu
    local stock_created
    local cover_requests
    local cover_books
    local book_info_requests
    local fresh_metadata
    local render_exact
    local render_reusable
    local folder_requests
    local painted_text
    local native_progress_paints
    local native_progress
    local banner_labels
    local banner_sizes
    local background_menus
    local calc_dimensions
    local folder_name_labels
    local textbox_line_height

    local function class(base)
        local out = {}
        out.__index = out
        setmetatable(out, { __index = base })
        function out:extend(values)
            local child = class(self)
            for key, value in pairs(values or {}) do child[key] = value end
            return child
        end
        function out:new(values)
            values = values or {}
            setmetatable(values, self)
            if values.init then values:init() end
            return values
        end
        function out:paintTo() end
        function out:free() end
        return out
    end

    before_each(function()
        stock_created = 0
        cover_requests = {}
        cover_books = {}
        book_info_requests = {}
        fresh_metadata = nil
        render_exact = false
        render_reusable = false
        folder_requests = {}
        painted_text = {}
        native_progress_paints = 0
        native_progress = nil
        banner_labels = {}
        banner_sizes = {}
        background_menus = {}
        folder_name_labels = {}
        textbox_line_height = 8
        calc_dimensions = function(width, height) return width, height end
        local MosaicMenuItem = class()
        function MosaicMenuItem:new(values)
            stock_created = stock_created + 1
            values.bookinfo_found = true
            values.is_directory = true
            return values
        end
        local function stock_builder()
            return MosaicMenuItem
        end
        MosaicMenu = { _updateItemsBuildUI = stock_builder }
        ZenSpec.replace("mosaicmenu", MosaicMenu)
        ZenSpec.replace("bookinfomanager", {
            getBookInfo = function(_self, path, get_cover)
                book_info_requests[#book_info_requests + 1] = {
                    path = path, get_cover = get_cover,
                }
            end,
            isCachedCoverInvalid = function() return false end,
        })
        ZenSpec.replace("device", {
            screen = {
                scaleBySize = function(_self, value) return value end,
            },
        })
        ZenSpec.replace("ui/font", { getFace = function() return {} end })
        ZenSpec.replace("ui/bidi", {
            mirroredUILayout = function() return false end,
            directory = function(text) return text end,
        })
        ZenSpec.replace("ui/geometry", { new = function(_self, values) return values end })
        ZenSpec.replace("ui/gesturerange", { new = function(_self, values) return values end })
        ZenSpec.replace("ui/widget/imagewidget", class())
        ZenSpec.replace("ui/widget/container/inputcontainer", class())
        local function widget_class(kind)
            local Widget = class()
            function Widget:new(values)
                values.kind = kind
                return values
            end
            return Widget
        end
        ZenSpec.replace("ui/widget/container/centercontainer", widget_class("center"))
        ZenSpec.replace("ui/widget/container/alphacontainer", widget_class())
        ZenSpec.replace("ui/widget/container/bottomcontainer", widget_class("bottom"))
        ZenSpec.replace("ui/widget/container/framecontainer", widget_class())
        local WidgetContainer = class()
        function WidgetContainer:getSize() return self.dimen end
        ZenSpec.replace("ui/widget/container/widgetcontainer", WidgetContainer)
        ZenSpec.replace("ui/widget/horizontalgroup", widget_class())
        ZenSpec.replace("ui/widget/horizontalspan", widget_class())
        ZenSpec.replace("ui/widget/container/leftcontainer", widget_class())
        ZenSpec.replace("ui/widget/overlapgroup", widget_class())
        ZenSpec.replace("ui/widget/textwidget", {
            new = function(_self, values)
                values.getSize = function(self)
                    return { w = #tostring(self.text or "") * 5, h = 8 }
                end
                values.paintTo = function(self)
                    painted_text[#painted_text + 1] = self.text
                end
                values.free = function() end
                return values
            end,
        })
        ZenSpec.replace("ui/widget/textboxwidget", {
            new = function(_self, values)
                if values.height then
                    folder_name_labels[#folder_name_labels + 1] = values
                end
                values.dimen = {}
                local text_length = #(values.text or "")
                local line_count = text_length > 100 and 3 or (text_length > 18 and 2 or 1)
                values.vertical_string_list = {}
                for line = 1, line_count do
                    values.vertical_string_list[line] = {}
                end
                values.getLineHeight = function() return textbox_line_height end
                if values.height then
                    if values.height < textbox_line_height then
                        values.height = textbox_line_height
                    end
                    values.lines_per_page = math.floor(values.height / textbox_line_height)
                    if values.height_adjust then
                        values.height = values.lines_per_page * textbox_line_height
                        if line_count < values.lines_per_page then
                            values.height = line_count * textbox_line_height
                        end
                    end
                end
                values._updateLayout = function(self)
                    self._bb = { getHeight = function() return 8 end }
                end
                values.free = function() end
                return values
            end,
        })
        ZenSpec.replace("ui/widget/container/underlinecontainer", widget_class())
        ZenSpec.replace("ui/widget/verticalgroup", widget_class())
        ZenSpec.replace("ui/widget/verticalspan", widget_class())
        ZenSpec.replace("ui/size", { border = { thin = 1, default = 1 }, padding = { tiny = 1 }, line = { focus_indicator = 1 } })
        ZenSpec.replace("ui/widget/menu", { getMenuText = function(entry) return entry.title end })
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_BLACK = 0,
            COLOR_WHITE = 1,
            TYPE_BB8 = 1,
            Color8A = function(value, alpha) return { value = value, alpha = alpha } end,
            Color8 = function(value) return { value = value } end,
            new = function(width, height, buffer_type)
                local buffer = { width = width, height = height, buffer_type = buffer_type, rects = {} }
                function buffer:paintRect(x, y, rect_w, rect_h, color)
                    table.insert(self.rects, {
                        x = x, y = y, width = rect_w, height = rect_h, color = color,
                    })
                end
                function buffer:fill() end
                function buffer:blitFrom() end
                function buffer:invertRect() end
                function buffer:getWidth() return self.width end
                function buffer:getHeight() return self.height end
                function buffer:free() end
                return buffer
            end,
        })
        ZenSpec.replace("common/cover_render_cache", {
            hasExact = function() return render_exact end,
            hasReusable = function() return render_reusable or render_exact end,
            render = function() return nil end,
            drop = function() end,
        })
        ZenSpec.replace("common/cover_decode_cache", {
            getFreshMetadata = function() return fresh_metadata end,
        })
        ZenSpec.replace("ui/widget/progresswidget", {
            new = function(_self, values)
                native_progress = values
                values.setPercentage = function(self, percentage) self.percentage = percentage end
                values.paintTo = function() native_progress_paints = native_progress_paints + 1 end
                return values
            end,
        })
        ZenSpec.replace("common/ui/corner_banner", {
            paint = function(_bb, _left, _right, _top, _height, span, thick, label)
                banner_labels[#banner_labels + 1] = label
                banner_sizes[#banner_sizes + 1] = { span = span, thick = thick }
            end,
        })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("common/book_status", {
            getFileStatusData = function()
                return { effective_status = "new", sidecar_checked = true }
            end,
            getEffectiveStatus = function(status) return status end,
        })
        ZenSpec.replace("common/cover_utils", {
            BORDER_SIZE = 2,
            getRatio = function() return 2 / 3 end,
            calcDims = function(width, height) return calc_dimensions(width, height) end,
        })
        ZenSpec.replace("modules/filebrowser/patches/home/widgets/cover_common", {
            BORDER_SIZE = 2,
            make_cover_widget = function(book, width, height, options)
                cover_books[#cover_books + 1] = book
                cover_requests[#cover_requests + 1] = {
                    width = width,
                    height = height,
                    options = options,
                }
                return { dimen = { w = 66, h = 99 } }
            end,
            set_dimmed_border = function(frame, dimmed)
                frame._zen_cover_border_color = dimmed and 6 or nil
            end,
        })
        ZenSpec.unload("modules/filebrowser/folder_cover")
        local shared_folder_overlay =
            require("modules/filebrowser/folder_cover").overlayName
        ZenSpec.replace("modules/filebrowser/folder_cover", {
            isBook = function(entry)
                return entry.is_file == true or type(entry.file) == "string"
                    or (entry.attr and entry.attr.mode == "file")
            end,
            isSupported = function(entry, menu)
                return entry.is_file == true or type(entry.file) == "string"
                    or (entry.attr and entry.attr.mode == "file")
                    or entry.is_go_up or entry.is_series_group or entry.series_items
                    or entry._zen_files or entry._zen_empty_placeholder
                    or (menu._zen_coll_list and entry.name)
                    or ((menu.name == "filemanager" or menu._zen_renderer)
                        and (entry.is_directory or (entry.attr and entry.attr.mode == "directory")))
            end,
            build = function(menu, entry, text, width, height, options)
                folder_requests[#folder_requests + 1] = {
                    menu = menu, entry = entry, text = text, options = options,
                }
                local pending = entry.cold_folder == true and options.cached_only == true
                return {
                    frame = {
                        dimen = { w = width, h = height },
                        getSize = function()
                            return { w = width - 20, h = height - 20 }
                        end,
                    },
                    count = entry.count or 2,
                    title = text,
                    cover_count = options.load_covers and not pending and 1 or 0,
                    needs_hydration = pending,
                    mode = "gallery",
                }
            end,
            overlayName = shared_folder_overlay,
            paintDecorations = function() end,
            allBooksFinished = function(_menu, entry)
                return entry.all_finished == true
            end,
        })
        ZenSpec.replace("common/ui/background", {
            library_path = function() return "" end,
            paintScreenRegion = function() return false end,
            applyToMenu = function(menu)
                background_menus[#background_menus + 1] = menu
            end,
        })
        ZenSpec.replace("common/utils", {
            formatPageCount = function(pages) return pages .. " p." end,
            getStablePageCount = function(_path, pages) return pages end,
            getBadgeColor = function() return 2 end,
            getBadgeInset = function(radius) return math.floor(radius * 0.4) end,
            getBadgeScale = function(config)
                return config.browser_cover_badges.badge_size == "extra_large" and 1.5 or 1
            end,
        })
        ZenSpec.replace("modules/filebrowser/patches/library_font", {
            getFontName = function() return "cfont" end,
            getBaseSize = function() return 18 end,
            getFace = function(size) return { size = size } end,
            scaleValue = function(value) return value end,
        })
        ZenSpec.replace("ui/widget/filechooser", { _updateItemsBuildUI = stock_builder })
        _G.G_reader_settings = {
            readSetting = function() return "2:3" end,
        }
        _G.__ZEN_UI_PLUGIN = {
            config = { features = { browser_cover_mosaic_uniform = true } },
        }
        ZenSpec.unload("modules/filebrowser/patches/zen_renderer")
    end)

    it("uses Zen tiles for books, folders, and virtual groups", function()
        require("modules/filebrowser/patches/zen_renderer")()
        local menu = {
            name = "filemanager",
            _zen_coll_list = true,
            item_table = {
                { title = "Book", is_file = true, path = "/book.epub" },
                { title = "Folder/", path = "/folder", attr = { mode = "directory" } },
                { title = "Series", is_series_group = true, series_items = {} },
                { title = "Author", _zen_files = { "/book.epub" } },
                { title = "Favorites", name = "favorites" },
                { title = "Unknown" },
            },
            item_group = {}, layout = {}, items_to_update = {}, page = 1,
            perpage = 6, nb_cols = 6, item_margin = 1, item_width = 100,
            item_height = 150, item_dimen = { copy = function() return {} end },
            inner_dimen = { w = 620 }, _do_cover_images = true,
        }

        MosaicMenu._updateItemsBuildUI(menu)

        assert.is_not_nil(MosaicMenu._zen_mosaic_item_class)
        assert.are.equal(1, stock_created)
        assert.are.equal(1, #menu.items_to_update)
        assert.are.equal(4, #folder_requests)
        assert.is_true(folder_requests[1].options.uniform)
        assert.is_true(folder_requests[1].options.cover_specs.uniform)
        assert.are.same({ width = 96, height = 144, options = {
            border = 2, uniform = true,
        } }, cover_requests[1])
        local found_stock_item = false
        for index = 1, 128 do
            local name = debug.getupvalue(MosaicMenu._updateItemsBuildUI, index)
            if name == "MosaicMenuItem" then
                found_stock_item = true
                break
            end
        end
        assert.is_true(found_stock_item)
    end)

    it("dims only folders whose books are all finished", function()
        _G.__ZEN_UI_PLUGIN.config.browser_cover_badges = { dim_finished_books = true }
        require("modules/filebrowser/patches/zen_renderer")()
        local menu = {
            name = "filemanager",
            item_table = {
                {
                    title = "Finished/", path = "/finished", all_finished = true,
                    attr = { mode = "directory" },
                },
                {
                    title = "Mixed/", path = "/mixed",
                    attr = { mode = "directory" },
                },
            },
            item_group = {}, layout = {}, items_to_update = {}, page = 1,
            perpage = 2, nb_cols = 2, item_margin = 1, item_width = 100,
            item_height = 150, item_dimen = { copy = function() return {} end },
            inner_dimen = { w = 220 }, _do_cover_images = true,
        }

        MosaicMenu._updateItemsBuildUI(menu)
        local finished = menu.layout[1][1]
        local mixed = menu.layout[1][2]
        finished._zen_cover_frame.dimen.x = 0
        finished._zen_cover_frame.dimen.y = 0
        mixed._zen_cover_frame.dimen.x = 0
        mixed._zen_cover_frame.dimen.y = 0
        local dimmed = 0
        local bb = {
            paintRect = function() end,
            lightenRect = function() dimmed = dimmed + 1 end,
        }
        finished:paintTo(bb, 0, 0)
        mixed:paintTo(bb, 0, 0)

        assert.are.equal("complete", finished._zen_effective_status)
        assert.are.equal(6, finished._zen_cover_frame._zen_cover_border_color)
        assert.is_nil(mixed._zen_cover_frame._zen_cover_border_color)
        assert.are.equal(1, dimmed)
    end)

    it("uses an exact shared real cover without requesting the decoded blob", function()
        render_exact = true
        fresh_metadata = {
            title = "Cached",
            cover_fetched = "Y",
            has_cover = "Y",
            cover_w = 600,
            cover_h = 900,
        }
        require("modules/filebrowser/patches/zen_renderer")()
        local menu = {
            name = "filemanager",
            item_table = { { title = "Cached", is_file = true, path = "/cached.epub" } },
            item_group = {}, layout = {}, items_to_update = {}, page = 1,
            perpage = 1, nb_cols = 2, item_margin = 1, item_width = 100,
            item_height = 150, item_dimen = { copy = function() return {} end },
            inner_dimen = { w = 110 }, _do_cover_images = true,
        }

        MosaicMenu._updateItemsBuildUI(menu)

        assert.are.same({}, book_info_requests)
        assert.is_true(cover_books[1].has_real_cover)
        assert.is_nil(cover_books[1].cover_bb)
    end)

    it("uses a larger Home render without deferring Library hydration", function()
        render_reusable = true
        fresh_metadata = {
            title = "Cached",
            cover_fetched = "Y",
            has_cover = "Y",
            cover_w = 600,
            cover_h = 900,
        }
        require("modules/filebrowser/patches/zen_renderer")()
        local menu = {
            name = "filemanager",
            item_table = { { title = "Cached", is_file = true, path = "/cached.epub" } },
            item_group = {}, layout = {}, items_to_update = {}, page = 1,
            perpage = 1, nb_cols = 2, item_margin = 1, item_width = 100,
            item_height = 150, item_dimen = { copy = function() return {} end },
            inner_dimen = { w = 110 }, _do_cover_images = true,
        }

        MosaicMenu._updateItemsBuildUI(menu)

        assert.are.same({}, book_info_requests)
        assert.is_true(cover_books[1].has_real_cover)
        assert.is_false(cover_books[1].is_cover_pending)
        assert.are.equal(0, #(menu._zen_cover_hydration_items or {}))
    end)

    it("uses fresh no-cover metadata without repeating a full book-info read", function()
        fresh_metadata = {
            title = "Placeholder",
            authors = "Author",
            cover_fetched = "Y",
            has_cover = false,
        }
        require("modules/filebrowser/patches/zen_renderer")()
        local menu = {
            name = "filemanager",
            item_table = {
                { title = "Placeholder", is_file = true, path = "/placeholder.epub" },
            },
            item_group = {}, layout = {}, items_to_update = {}, page = 1,
            perpage = 1, nb_cols = 2, item_margin = 1, item_width = 100,
            item_height = 150, item_dimen = { copy = function() return {} end },
            inner_dimen = { w = 110 }, _do_cover_images = true,
        }

        MosaicMenu._updateItemsBuildUI(menu)

        assert.are.same({}, book_info_requests)
        assert.are.equal(fresh_metadata, cover_books[1].bookinfo)
        assert.is_false(cover_books[1].has_real_cover)
    end)

    it("defers cold cover blobs and reuses metadata state during hydration", function()
        local cover_reads = {}
        local status_reads = 0
        local metadata = {
            title = "Deferred",
            cover_fetched = "Y",
            has_cover = "Y",
            cover_w = 600,
            cover_h = 900,
        }
        ZenSpec.replace("bookinfomanager", {
            getBookInfo = function(_self, _path, get_cover)
                cover_reads[#cover_reads + 1] = get_cover == true
                if not get_cover then return metadata end
                return {
                    title = metadata.title,
                    cover_fetched = "Y",
                    has_cover = "Y",
                    cover_w = 600,
                    cover_h = 900,
                    cover_bb = { free = function() end },
                }
            end,
            isCachedCoverInvalid = function() return false end,
        })
        ZenSpec.replace("common/book_status", {
            getFileStatusData = function()
                status_reads = status_reads + 1
                return { effective_status = "new", sidecar_checked = true }
            end,
        })
        ZenSpec.unload("modules/filebrowser/patches/zen_renderer")
        require("modules/filebrowser/patches/zen_renderer")()
        local menu = {
            name = "filemanager",
            item_table = { { title = "Deferred", is_file = true, path = "/deferred.epub" } },
            item_group = {}, layout = {}, items_to_update = {}, page = 1,
            perpage = 1, nb_cols = 2, item_margin = 1, item_width = 100,
            item_height = 150, item_dimen = { copy = function() return {} end },
            inner_dimen = { w = 110 }, _do_cover_images = true,
        }

        MosaicMenu._updateItemsBuildUI(menu)
        local item = menu.layout[1][1]

        assert.are.same({ false }, cover_reads)
        assert.are.equal(0, #menu.items_to_update)
        assert.are.equal(1, #menu._zen_cover_hydration_items)
        assert.is_true(cover_books[1].is_cover_pending)
        assert.are.equal(1, status_reads)

        fresh_metadata = metadata
        item._zen_cover_hydration_queued = nil
        item._zen_cover_hydrating = true
        item._underline_container[1].free = function() end
        item:update()
        item._zen_cover_hydrating = nil

        assert.are.same({ false, true }, cover_reads)
        assert.is_true(item._has_cover_image)
        assert.is_false(cover_books[#cover_books].is_cover_pending)
        assert.are.equal(1, status_reads)
    end)

    it("uses cached-only folder previews during the initial page pass", function()
        require("modules/filebrowser/patches/zen_renderer")()
        local menu = {
            name = "filemanager",
            item_table = {
                { title = "Folder/", path = "/folder", attr = { mode = "directory" } },
            },
            item_group = {}, layout = {}, items_to_update = {}, page = 1,
            perpage = 1, nb_cols = 2, item_margin = 1, item_width = 100,
            item_height = 150, item_dimen = { copy = function() return {} end },
            inner_dimen = { w = 110 }, _do_cover_images = true,
        }

        MosaicMenu._updateItemsBuildUI(menu)
        local item = menu.layout[1][1]

        assert.is_true(folder_requests[1].options.load_covers)
        assert.is_true(folder_requests[1].options.cached_only)
        assert.is_nil(folder_requests[1].options.load_descriptor)
        assert.is_true(item._has_cover_image)
        assert.are.equal(0, #(menu._zen_cover_hydration_items or {}))
    end)

    it("queues a cold folder and loads it only during folder hydration", function()
        require("modules/filebrowser/patches/zen_renderer")()
        local menu = {
            name = "filemanager",
            item_table = {
                {
                    title = "Folder/", path = "/folder", cold_folder = true,
                    attr = { mode = "directory" },
                },
            },
            item_group = {}, layout = {}, items_to_update = {}, page = 1,
            perpage = 1, nb_cols = 2, item_margin = 1, item_width = 100,
            item_height = 150, item_dimen = { copy = function() return {} end },
            inner_dimen = { w = 110 }, _do_cover_images = true,
        }

        MosaicMenu._updateItemsBuildUI(menu)
        local item = menu.layout[1][1]

        assert.is_false(item._has_cover_image)
        assert.are.equal(1, #menu._zen_cover_hydration_items)
        assert.are.equal("folder", item._zen_cover_hydration_kind)
        assert.is_true(folder_requests[1].options.cached_only)

        item._zen_cover_hydration_queued = nil
        item._zen_cover_hydration_kind = nil
        item._zen_folder_hydrating = true
        item._underline_container[1].free = function() end
        item:update()
        item._zen_folder_hydrating = nil

        assert.is_false(folder_requests[2].options.cached_only)
        assert.is_true(item._has_cover_image)
    end)

    it("keeps folder previews in the initial pass after preloading", function()
        require("modules/filebrowser/patches/zen_renderer")()
        local menu = {
            name = "filemanager",
            item_table = {
                { title = "Folder/", path = "/folder", attr = { mode = "directory" } },
            },
            item_group = {}, layout = {}, items_to_update = {}, page = 1,
            perpage = 1, nb_cols = 2, item_margin = 1, item_width = 100,
            item_height = 150, item_dimen = { copy = function() return {} end },
            inner_dimen = { w = 110 }, _do_cover_images = true,
        }

        MosaicMenu._updateItemsBuildUI(menu)
        local item = menu.layout[1][1]

        assert.is_true(folder_requests[1].options.load_covers)
        assert.is_true(item._has_cover_image)
        assert.are.equal(0, #(menu._zen_cover_hydration_items or {}))
    end)

    it("uses non-uniform sizing for group previews when configured", function()
        _G.__ZEN_UI_PLUGIN.config.features.browser_cover_mosaic_uniform = false
        calc_dimensions = function() return 64, 96 end
        require("modules/filebrowser/patches/zen_renderer")()
        local menu = {
            name = "authors",
            item_table = { { title = "Author", _zen_files = { "/book.epub" } } },
            item_group = {}, layout = {}, items_to_update = {}, page = 1,
            perpage = 1, nb_cols = 2, item_margin = 1, item_width = 100,
            item_height = 150, item_dimen = { copy = function() return {} end },
            inner_dimen = { w = 110 }, _do_cover_images = true,
        }

        MosaicMenu._updateItemsBuildUI(menu)

        assert.is_false(folder_requests[1].options.uniform)
        assert.is_false(folder_requests[1].options.cover_specs.uniform)
        assert.are.equal(96, folder_requests[1].options.cover_specs.max_cover_w)
        assert.are.equal(146, folder_requests[1].options.cover_specs.max_cover_h)
    end)

    it("uses Zen folder tiles and the library background for opted-in choosers", function()
        require("modules/filebrowser/patches/zen_renderer")()
        local menu = {
            _zen_renderer = true,
            item_table = {
                { title = "Destination", path = "/destination", is_directory = true },
            },
            item_group = {}, layout = {}, items_to_update = {}, page = 1,
            perpage = 1, nb_cols = 2, item_margin = 1, item_width = 100,
            item_height = 150, item_dimen = { copy = function() return {} end },
            inner_dimen = { w = 110 }, _do_cover_images = false,
        }

        MosaicMenu._updateItemsBuildUI(menu)

        assert.are.equal(0, stock_created)
        assert.are.equal(1, #folder_requests)
        assert.is_false(folder_requests[1].options.load_covers)
        assert.are.same({ menu }, background_menus)
    end)

    it("bounds two-line folder name labels to their cover when title strips are off", function()
        _G.__ZEN_UI_PLUGIN.config.browser_folder_cover = { name_opaque = true }
        _G.__ZEN_UI_PLUGIN.config.features.browser_cover_rounded_corners = true
        require("modules/filebrowser/patches/zen_renderer")()
        local function folder_menu(title)
            return {
                name = "filemanager",
                item_table = {
                    {
                        title = title or string.rep("Long folder name ", 12),
                        path = "/folder",
                        attr = { mode = "directory" },
                    },
                },
                item_group = {}, layout = {}, items_to_update = {}, page = 1,
                perpage = 1, nb_cols = 2, item_margin = 1, item_width = 100,
                item_height = 150, item_dimen = { copy = function() return {} end },
                inner_dimen = { w = 110 }, _do_cover_images = true,
            }
        end
        local menu = folder_menu()

        MosaicMenu._updateItemsBuildUI(menu)

        assert.are.equal(1, #folder_name_labels)
        local item = menu.layout[1][1]
        local overlay = item._underline_container[1][1]
        local label_container = overlay[2][1]
        local label_widget = label_container[1]
        local label_strip = label_widget[1]
        local cover_size = item._zen_cover_frame:getSize()
        assert.are.equal(cover_size.w - 14, folder_name_labels[1].width)
        assert.are.equal(cover_size.w, label_container.dimen.w)
        assert.are.equal(cover_size.h, label_container.dimen.h)
        assert.are.equal("bottom", label_container.kind)
        assert.are.equal(cover_size.w, label_strip.dimen.w)
        assert.are.equal(20, label_strip.dimen.h)
        assert.are.equal(8, label_strip.radius)
        assert.are.equal(0xFF, label_strip.alpha)
        assert.are.same({ value = 0xFF }, label_strip.strip.background_mask.rects[1].color)
        local strip_paints = {}
        label_strip:paintTo({
            colorblitFromRGB32 = function(_self, mask, _x, _y, _offset_x, _offset_y,
                    _width, _height, color)
                strip_paints[#strip_paints + 1] = { mask = mask, color = color }
            end,
        }, 0, 0)
        assert.are.same({
            { mask = label_strip.strip.background_mask, color = 1 },
            { mask = label_strip.strip.border_mask, color = 0 },
        }, strip_paints)
        assert.are.equal(folder_name_labels[1], label_widget[2][1])
        assert.are.equal("center", folder_name_labels[1].alignment)
        assert.is_true(folder_name_labels[1].height_adjust)
        assert.is_true(folder_name_labels[1].height_overflow_show_ellipsis)
        assert.are.equal(16, folder_name_labels[1].height)
        assert.are.equal(0, folder_name_labels[1].fgcolor)
        local text_target = {}
        function text_target:colorblitFromRGB32(mask, x, y, _offset_x, _offset_y, width, height, color)
            self.mask, self.x, self.y = mask, x, y
            self.width, self.height, self.color = width, height, color
        end
        folder_name_labels[1]:paintTo(text_target, 3, 4)
        assert.are.equal(3, text_target.x)
        assert.are.equal(4, text_target.y)
        assert.are.equal(0, text_target.color)

        textbox_line_height = 12
        local two_line_menu = folder_menu("folder1234567891011")
        MosaicMenu._updateItemsBuildUI(two_line_menu)
        local two_line_label = folder_name_labels[#folder_name_labels]
        assert.are.equal(19, two_line_label.face.size)
        assert.are.equal(2, #two_line_label.vertical_string_list)
        assert.are.equal(2, two_line_label.lines_per_page)
        assert.are.equal(24, two_line_label.height)

        _G.__ZEN_UI_PLUGIN.config.browser_folder_cover.name_opaque = false
        local translucent_menu = folder_menu()
        MosaicMenu._updateItemsBuildUI(translucent_menu)
        local translucent_overlay = translucent_menu.layout[1][1]._underline_container[1][1]
        local translucent_strip = translucent_overlay[2][1][1][1]

        assert.are.equal(math.floor(0.75 * 0xFF + 0.5), translucent_strip.alpha)
        assert.are.same({ value = math.floor(0.75 * 0xFF + 0.5) },
            translucent_strip.strip.background_mask.rects[1].color)

        local short_menu = folder_menu("Short")
        MosaicMenu._updateItemsBuildUI(short_menu)
        local short_overlay = short_menu.layout[1][1]._underline_container[1][1]
        local short_strip = short_overlay[2][1][1][1]
        assert.are.equal(translucent_strip.dimen.h, short_strip.dimen.h)
        assert.are.equal(translucent_strip.strip, short_strip.strip)

        _G.__ZEN_UI_PLUGIN.config.browser_folder_cover.name_centered = true
        local centered_menu = folder_menu("Centered")
        MosaicMenu._updateItemsBuildUI(centered_menu)
        local centered_overlay = centered_menu.layout[1][1]._underline_container[1][1]
        assert.are.equal("center", centered_overlay[2][1].kind)
    end)

    it("supplies the rendered book cover before opening a Zen mosaic tile", function()
        require("modules/filebrowser/patches/zen_renderer")()
        local captured_cover
        local selected_entry
        rawset(_G, "__ZEN_UI_SET_OPENING_BANNER_COVER", function(cover)
            captured_cover = cover
        end)
        local cover = { dimen = { x = 20, y = 30, w = 80, h = 120 } }
        local entry = { path = "/book.epub" }
        local item = setmetatable({
            _zen_cover_frame = cover,
            _zen_is_book = true,
            entry = entry,
            menu = { onMenuSelect = function(_, selected) selected_entry = selected end },
        }, { __index = MosaicMenu._zen_mosaic_item_class })

        assert.is_true(item:onTapSelect())
        assert.are.equal(cover, captured_cover)
        assert.are.equal(entry, selected_entry)

        captured_cover = nil
        item.menu.select_file = true
        item.menu.select_directory = false
        assert.is_true(item:onTapSelect())
        assert.is_nil(captured_cover)

        captured_cover = nil
        item._zen_is_book = false
        assert.is_true(item:onTapSelect())
        assert.is_nil(captured_cover)
    end)

    it("does not prepare an opening banner while selection mode is active", function()
        ZenSpec.replace("apps/filemanager/filemanager", {
            instance = { selected_files = {} },
        })
        require("modules/filebrowser/patches/zen_renderer")()
        local captured_cover
        rawset(_G, "__ZEN_UI_SET_OPENING_BANNER_COVER", function(cover)
            captured_cover = cover
        end)
        local cover = { dimen = { x = 20, y = 30, w = 80, h = 120 } }
        local entry = { path = "/book.epub" }
        local item = setmetatable({
            _zen_cover_frame = cover,
            _zen_is_book = true,
            entry = entry,
            menu = { onMenuSelect = function() end },
        }, { __index = MosaicMenu._zen_mosaic_item_class })

        assert.is_true(item:onTapSelect())
        assert.is_nil(captured_cover)
    end)

    it("queues cover extraction for metadata-only and undersized cached covers", function()
        local mode = "metadata_only"
        local freed = 0
        ZenSpec.replace("bookinfomanager", {
            getBookInfo = function()
                if mode == "metadata_only" then
                    return { pages = 120, cover_fetched = false, has_cover = false }
                end
                return {
                    pages = 120,
                    cover_fetched = true,
                    has_cover = true,
                    cover_bb = { free = function() freed = freed + 1 end },
                }
            end,
            isCachedCoverInvalid = function() return mode == "undersized" end,
        })
        _G.__ZEN_UI_PLUGIN.config.browser_page_count = { show_page_count = true }
        ZenSpec.unload("modules/filebrowser/patches/zen_renderer")
        require("modules/filebrowser/patches/zen_renderer")()

        local function build()
            local menu = {
                item_table = { { title = "Book", is_file = true, path = "/book.epub" } },
                item_group = {}, layout = {}, items_to_update = {}, page = 1,
                perpage = 1, nb_cols = 2, item_margin = 1, item_width = 100,
                item_height = 150, item_dimen = { copy = function() return {} end },
                inner_dimen = { w = 110 }, _do_cover_images = true,
            }
            MosaicMenu._updateItemsBuildUI(menu)
            return menu
        end

        local metadata_menu = build()
        assert.are.equal(1, #metadata_menu.items_to_update)
        assert.is_false(metadata_menu.layout[1][1].bookinfo_found)
        assert.are.equal("120 p.", metadata_menu.layout[1][1]._zen_page_label)

        mode = "undersized"
        local undersized_menu = build()
        assert.are.equal(1, #undersized_menu.items_to_update)
        assert.is_false(undersized_menu.layout[1][1].bookinfo_found)
        assert.are.equal("120 p.", undersized_menu.layout[1][1]._zen_page_label)
        assert.are.equal(1, freed)
    end)

    it("dims selected mosaic book covers", function()
        ZenSpec.replace("bookinfomanager", {
            getBookInfo = function()
                return { cover_fetched = true, has_cover = false }
            end,
            isCachedCoverInvalid = function() return false end,
        })
        ZenSpec.unload("modules/filebrowser/patches/zen_renderer")
        require("modules/filebrowser/patches/zen_renderer")()
        local menu = {
            item_table = { { title = "Book", is_file = true, path = "/book.epub", dim = true } },
            item_group = {}, layout = {}, items_to_update = {}, page = 1,
            perpage = 1, nb_cols = 2, item_margin = 1, item_width = 100,
            item_height = 150, item_dimen = { copy = function() return {} end },
            inner_dimen = { w = 110 }, _do_cover_images = true,
        }

        MosaicMenu._updateItemsBuildUI(menu)

        assert.is_true(menu.layout[1][1]._zen_cover_frame.dim)
    end)

    it("paints status, page, and series badges at the configured scale", function()
        require("modules/filebrowser/patches/zen_renderer")()
        _G.__ZEN_UI_PLUGIN.config.browser_cover_badges = {
            show_mosaic_progress = true,
            show_native_progress_bar = true,
            show_favorite_badge = true,
            badge_size = "compact",
        }
        _G.__ZEN_UI_PLUGIN.config.browser_page_count = { show_page_count = true }
        _G.__ZEN_UI_PLUGIN.config.browser_series_badge = { show_series_badge = true }
        local item_class = MosaicMenu._zen_mosaic_item_class
        local item = setmetatable({
            _zen_cover_frame = { dimen = { x = 0, y = 0, w = 100, h = 150 }, bordersize = 1 },
            _zen_effective_status = "reading",
            percent_finished = 0.456,
            _zen_is_fav = true,
            _zen_page_label = "120 p.",
            _zen_series_label = "#2",
            _zen_is_book = true,
            filepath = "/book.epub",
        }, { __index = item_class })
        local compact = {}
        local rounded_progress
        local bb = {
            paintRectRGB32 = function(_self, x, y, width, height)
                compact[#compact + 1] = { x = x, y = y, width = width, height = height }
            end,
            paintRect = function() end,
            paintRoundedRect = function(_self, _x, _y, width, height, _color, radius)
                rounded_progress = { width = width, height = height, radius = radius }
            end,
        }

        item:paintTo(bb, 0, 0)

        assert.is_true(#compact > 0)
        assert.is_true(table.concat(painted_text, " "):find("46%%") ~= nil)
        assert.is_true(table.concat(painted_text, " "):find("120 p%.") ~= nil)
        assert.is_true(table.concat(painted_text, " "):find("#2") ~= nil)
        assert.is_true(table.concat(painted_text, " "):find("☆") ~= nil)
        assert.are.equal(1, native_progress_paints)
        assert.are.equal(4, native_progress.radius)
        assert.are.same({ width = 39, height = 4, radius = 2 }, rounded_progress)

        _G.__ZEN_UI_PLUGIN.config.browser_cover_badges.show_native_progress_bar = false
        item:paintTo(bb, 0, 0)
        assert.are.equal(1, native_progress_paints)

        _G.__ZEN_UI_PLUGIN.config.browser_cover_badges.show_native_progress_bar = true
        _G.__ZEN_UI_PLUGIN.config.browser_cover_badges.badge_size = "extra_large"
        local large = {}
        bb.paintRectRGB32 = function(_self, x, y, width, height)
            large[#large + 1] = { x = x, y = y, width = width, height = height }
        end
        item:paintTo(bb, 0, 0)

        local function widest(calls)
            local width = 0
            for _i, call in ipairs(calls) do width = math.max(width, call.width) end
            return width
        end
        assert.is_true(widest(large) > widest(compact))
    end)

    it("resolves metadata during update and performs no metadata reads during paint", function()
        local metadata_allowed = true
        local calls = {
            bookinfo = 0, sidecar_check = 0, sidecar_open = 0,
            sidecar_read = 0, booklist = 0, favorite = 0, stat = 0,
        }
        local function metadata_call(key)
            assert.is_true(metadata_allowed, key .. " metadata read during paint")
            calls[key] = calls[key] + 1
        end
        ZenSpec.replace("bookinfomanager", {
            getBookInfo = function()
                metadata_call("bookinfo")
                return {
                    series_index = 4,
                    cover_fetched = true,
                    has_cover = false,
                }
            end,
            isCachedCoverInvalid = function() return false end,
        })
        local doc_values = {
            summary = { status = "reading" },
            percent_finished = 0.25,
            zen_new_mtime = 200,
            pagemap_use_page_labels = false,
            doc_pages = 999,
        }
        local doc = {
            readSetting = function(_self, key)
                metadata_call("sidecar_read")
                return doc_values[key]
            end,
        }
        ZenSpec.replace("docsettings", {
            hasSidecarFile = function()
                metadata_call("sidecar_check")
                return true
            end,
            open = function()
                metadata_call("sidecar_open")
                return doc
            end,
            findSidecarFile = function() return "/book.sdr/metadata.lua" end,
        })
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function(path, attribute)
                metadata_call("stat")
                local values = path == "/book.epub"
                    and { mode = "file", modification = 200 }
                    or { mode = "file", modification = 150 }
                return attribute and values[attribute] or values
            end,
        })
        ZenSpec.replace("ui/widget/booklist", {
            getBookInfo = function()
                metadata_call("booklist")
                return { pages = 999 }
            end,
        })
        ZenSpec.replace("gettext", setmetatable({
            pgettext = function(_context, text) return text end,
        }, {
            __call = function(_self, text) return text end,
        }))
        ZenSpec.replace("readcollection", {
            isFileInCollection = function(_self, _path, collection)
                metadata_call("favorite")
                return collection == "favorites"
            end,
        })
        _G.__ZEN_UI_PLUGIN.config.browser_cover_badges = {
            show_mosaic_progress = true,
            show_favorite_badge = true,
        }
        _G.__ZEN_UI_PLUGIN.config.browser_page_count = { show_page_count = true }
        _G.__ZEN_UI_PLUGIN.config.browser_series_badge = { show_series_badge = true }
        ZenSpec.unload("common/book_status")
        ZenSpec.unload("common/utils")
        ZenSpec.unload("modules/filebrowser/patches/zen_renderer")
        require("modules/filebrowser/patches/zen_renderer")()
        local menu = {
            item_table = { { title = "Book", is_file = true, path = "/book.epub" } },
            item_group = {}, layout = {}, items_to_update = {}, page = 1,
            perpage = 1, nb_cols = 2, item_margin = 1, item_width = 100,
            item_height = 150, item_dimen = { copy = function() return {} end },
            inner_dimen = { w = 110 }, _do_cover_images = true,
        }
        MosaicMenu._updateItemsBuildUI(menu)
        local item = menu.layout[1][1]
        local before_paint = {}
        for key, value in pairs(calls) do before_paint[key] = value end
        metadata_allowed = false
        item._zen_cover_frame.dimen.x = 0
        item._zen_cover_frame.dimen.y = 0
        item:paintTo({
            paintRectRGB32 = function() end,
            paintRect = function() end,
        }, 0, 0)

        assert.are.same(before_paint, calls)
        assert.matches("999", item._zen_page_label)
        assert.are.equal("#4", item._zen_series_label)
        assert.is_true(item._zen_is_fav)
        assert.are.equal(1, calls.favorite)
        assert.are.equal(1, calls.sidecar_open)
        assert.are.equal(0, calls.booklist)
    end)

    it("honors finished dimming and the new-banner setting", function()
        require("modules/filebrowser/patches/zen_renderer")()
        _G.__ZEN_UI_PLUGIN.config.browser_cover_badges = { dim_finished_books = true }
        local item_class = MosaicMenu._zen_mosaic_item_class
        local item = setmetatable({
            _zen_cover_frame = { dimen = { x = 0, y = 0, w = 100, h = 150 }, bordersize = 1 },
            _zen_effective_status = "complete",
            _zen_is_book = true,
            width = 320,
            height = 400,
        }, { __index = item_class })
        local dimmed = 0
        local bb = {
            paintRectRGB32 = function() end,
            paintRect = function() end,
            lightenRect = function() dimmed = dimmed + 1 end,
        }

        item:paintTo(bb, 0, 0)
        assert.are.equal(1, dimmed)
        assert.are.equal(6, item._zen_cover_frame._zen_cover_border_color)

        _G.__ZEN_UI_PLUGIN.config.browser_cover_badges = { show_new_banner = true }
        item._zen_effective_status = "new"
        item:paintTo(bb, 0, 0)
        assert.is_nil(item._zen_cover_frame._zen_cover_border_color)
        assert.are.same({ "New" }, banner_labels)
        assert.are.same({ { span = 100, thick = 35 } }, banner_sizes)
    end)

    it("shows keyboard focus while idle underlines are hidden", function()
        require("modules/filebrowser/patches/zen_renderer")()
        local item = setmetatable({ _underline_container = {} }, {
            __index = MosaicMenu._zen_mosaic_item_class,
        })

        item:onFocus()
        assert.are.equal(0, item._underline_container.color)

        _G.__ZEN_UI_PLUGIN.config.features.browser_hide_underline = true
        item:onFocus()
        assert.are.equal(0, item._underline_container.color)
        item:onUnfocus()
        assert.are.equal(1, item._underline_container.color)
    end)
end)
