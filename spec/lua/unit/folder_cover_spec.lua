describe("shared folder cover provider", function()
    local calls
    local cover_mode

    local function install_lfs(entries_for_path, on_scan, on_yield)
        ZenSpec.replace("libs/libkoreader-lfs", {
            dir = function(path)
                if on_scan then on_scan(path) end
                local entries = entries_for_path(path)
                local names = { ".", ".." }
                for _i, entry in ipairs(entries) do names[#names + 1] = entry.name end
                local index = 0
                return function()
                    index = index + 1
                    local name = names[index]
                    if on_yield and name and name ~= "." and name ~= ".." then on_yield(name) end
                    return name
                end
            end,
            attributes = function(path, field)
                if field == "modification" then return 1 end
                local dir, name = path:match("^(.*)/([^/]+)$")
                for _i, entry in ipairs(entries_for_path(dir)) do
                    if entry.name == name then
                        local attr = {
                            mode = entry.mode or "file",
                            access = entry.access or 0,
                            modification = entry.modification or 0,
                            size = entry.size or 0,
                        }
                        return field and attr[field] or attr
                    end
                end
            end,
        })
        ZenSpec.unload("modules/filebrowser/folder_cover")
    end

    before_each(function()
        calls = { collect = {}, decorate = 0 }
        cover_mode = "gallery"
        _G.__ZEN_FOLDER_SORT = nil
        ZenSpec.replace("common/cover_utils", {
            BORDER_SIZE = 2,
            getMode = function()
                if cover_mode == "none" then return "none", 0, false end
                if cover_mode == "normal" then return "normal", 1, false end
                return cover_mode, 4, true
            end,
            calcDims = function(width, height) return width, height end,
            galleryCacheKey = function(...)
                calls.gallery_key_args = { ... }
                return calls.gallery_cache_key
            end,
            getCachedGallery = function(key)
                calls.gallery_cache_lookups = (calls.gallery_cache_lookups or 0) + 1
                calls.gallery_lookup_key = key
                return calls.cached_gallery
            end,
            hasCachedGallery = function(key, width, height)
                calls.gallery_cached_request = {
                    key = key, width = width, height = height,
                }
                return calls.gallery_cached == true
            end,
            loadExplicitCovers = function(path)
                calls.explicit = path
                return calls.explicit_covers or {}, calls.has_explicit == true
            end,
            collect = function(path, chooser, limit, need_copy, entries, specs,
                    cover_offset, cached_only)
                calls.collect[#calls.collect + 1] = {
                    path = path, chooser = chooser, limit = limit,
                    need_copy = need_copy, entries = entries, specs = specs,
                    cover_offset = cover_offset, cached_only = cached_only,
                }
                if calls.collect_cold and cached_only then return {}, true end
                if calls.collect_covers then
                    return calls.collect_covers, calls.collect_pending == true
                end
                return entries and #entries > 0 and { { data = "cover" } } or {},
                    calls.collect_pending == true
            end,
            drawGallery = function(covers, _width, _height, _border, _bg, uniform, cache_key)
                calls.uniform = uniform
                calls.draw_gallery_cache_key = cache_key
                return {
                    kind = "gallery",
                    covers = covers,
                    bordersize = 2,
                    free = function() calls.gallery_freed = true end,
                },
                    false, cache_key ~= nil
            end,
            drawStack = function(covers)
                calls.stack_covers = covers
                return { kind = "stack", bordersize = 2 }
            end,
            drawSingle = function(_cover, width, height, _border, uniform)
                calls.single = { width = width, height = height, uniform = uniform }
                return { kind = "single", bordersize = 2 }
            end,
            drawNoImage = function(title)
                return { kind = "placeholder", title = title, bordersize = 2 }
            end,
        })
        ZenSpec.replace("modules/filebrowser/patches/home/widgets/cover_common", {
            decorate_cover_frame = function(frame)
                calls.decorate = calls.decorate + 1
                frame.decorated = true
            end,
        })
        ZenSpec.unload("modules/filebrowser/folder_cover")
    end)

    after_each(function()
        _G.__ZEN_FOLDER_SORT = nil
        ZenSpec.unload("modules/filebrowser/folder_cover")
    end)

    it("classifies every Zen library entry while leaving unknown menus alone", function()
        local FolderCover = require("modules/filebrowser/folder_cover")
        local filemanager = { name = "filemanager" }

        assert.is_true(FolderCover.isSupported({ is_file = true }, filemanager))
        assert.is_true(FolderCover.isSupported({ attr = { mode = "directory" } }, filemanager))
        assert.is_true(FolderCover.isSupported({ series_items = {} }, {}))
        assert.is_true(FolderCover.isSupported({ _zen_files = {} }, {}))
        assert.is_true(FolderCover.isSupported({ is_go_up = true }, {}))
        assert.is_true(FolderCover.isSupported({ name = "Favorites" }, { _zen_coll_list = true }))
        assert.is_true(FolderCover.isSupported({ is_directory = true }, { _zen_renderer = true }))
        assert.is_false(FolderCover.isSupported({ text = "Unrelated" }, {}))
    end)

    it("uses Kindle books for the virtual folder count and covers", function()
        local scans = 0
        install_lfs(function()
            return { { name = "koreader-book.epub" } }
        end, function() scans = scans + 1 end)
        ZenSpec.replace("modules/filebrowser/patches/kindle_virtual_library", {
            getBookPaths = function()
                return { "/kindle/one.kfx", "/kindle/two.azw3" }
            end,
        })
        local FolderCover = require("modules/filebrowser/folder_cover")
        local entry = {
            path = "/library",
            attr = { mode = "directory" },
            is_kindle_library_folder = true,
        }
        local entries, physical, count = FolderCover.previewEntries(
            { name = "filemanager" }, entry, 4)

        assert.are.same({ "/kindle/one.kfx", "/kindle/two.azw3" }, {
            entries[1].path, entries[2].path,
        })
        assert.is_false(physical)
        assert.are.equal(2, count)
        local result = FolderCover.build(
            { name = "filemanager" }, entry, "Kindle Library/", 120, 180)
        assert.are.equal(2, result.count)
        assert.are.equal(1, result.cover_count)
        assert.are.equal(0, scans)
    end)

    it("keeps adaptive folder labels at a fixed overlay height", function()
        local created = {}
        local label_font_sizes = {}
        local next_mask_id = 0
        local function widget_class(kind)
            return {
                new = function(_self, values)
                    values = values or {}
                    values.kind = kind
                    created[#created + 1] = values
                    return values
                end,
            }
        end

        ZenSpec.replace("ffi/blitbuffer", {
            TYPE_BB8 = "bb8",
            COLOR_BLACK = "black",
            COLOR_WHITE = "white",
            Color8 = function(value) return value end,
            new = function(width, height)
                next_mask_id = next_mask_id + 1
                return {
                    id = next_mask_id,
                    width = width,
                    height = height,
                    fill = function() end,
                    paintRect = function() end,
                }
            end,
        })
        ZenSpec.replace("ui/bidi", { directory = function(text) return text end })
        ZenSpec.replace("ui/geometry", { new = function(_self, values) return values end })
        ZenSpec.replace("ui/widget/container/centercontainer", widget_class("center"))
        ZenSpec.replace("ui/widget/container/bottomcontainer", widget_class("bottom"))
        ZenSpec.replace("ui/widget/overlapgroup", widget_class("overlap"))
        ZenSpec.replace("ui/widget/container/widgetcontainer", {
            extend = function()
                local class = {}
                function class:new(values)
                    values = values or {}
                    values.kind = "label_strip"
                    created[#created + 1] = values
                    return setmetatable(values, { __index = class })
                end
                return class
            end,
        })
        ZenSpec.replace("ui/widget/textwidget", {
            new = function(_self, values)
                values.getSize = function() return { w = 6, h = 10 } end
                values.free = function() end
                return values
            end,
        })
        ZenSpec.replace("ui/widget/textboxwidget", {
            new = function(_self, values)
                values.vertical_string_list = values.text == "A longer folder label"
                    and (values.face.size > 14
                        and { "A", "longer", "folder" } or { "A", "longer" })
                    or { values.text }
                if values.height then
                    label_font_sizes[values.text] = values.face.size
                end
                values.getLineHeight = function() return values.face.size end
                values.getSize = function() return { w = values.width, h = values.height or 10 } end
                values.free = function() end
                return values
            end,
        })
        ZenSpec.replace("modules/filebrowser/patches/library_font", {
            getFace = function(size) return { size = size } end,
            getBaseSize = function() return 16 end,
            scaleValue = function(value) return value end,
        })
        ZenSpec.replace("device", {
            screen = { scaleBySize = function(_self, value) return value end },
        })
        ZenSpec.unload("modules/filebrowser/folder_cover")

        local config = {
            browser_folder_cover = { show_folder_name = true },
            features = { browser_cover_rounded_corners = true },
        }
        local FolderCover = require("modules/filebrowser/folder_cover")
        FolderCover.overlayName({}, {
            width = 80,
            height = 120,
            cover_dimen = { w = 80, h = 120 },
            title = "Fantasy",
            config = config,
        })
        FolderCover.overlayName({}, {
            width = 80,
            height = 120,
            cover_dimen = { w = 80, h = 120 },
            title = "A longer folder label",
            config = config,
        })
        assert.are.equal(17, label_font_sizes.Fantasy)
        assert.are.equal(14, label_font_sizes["A longer folder label"])

        local label_strips = {}
        for _i, widget in ipairs(created) do
            if widget.kind == "label_strip" then
                label_strips[#label_strips + 1] = widget
            end
        end
        assert.are.equal(2, #label_strips)
        assert.are.equal(label_strips[1].dimen.h, label_strips[2].dimen.h)
        local label_strip = label_strips[1]
        assert.is_table(label_strip)
        local painted_masks = {}
        local target = {
            colorblitFromRGB32 = function(_self, mask)
                painted_masks[#painted_masks + 1] = mask
            end,
        }
        label_strip:paintTo(target, 0, 0)
        local rounded_mask = painted_masks[1]
        assert.is_true(label_strip.radius > 0)

        config.features.browser_cover_rounded_corners = false
        label_strip:paintTo(target, 0, 0)
        assert.are.equal(0, label_strip.radius)
        assert.are_not.equal(rounded_mask, painted_masks[3])
    end)

    it("does not enumerate a physical folder when covers are suppressed", function()
        local FolderCover = require("modules/filebrowser/folder_cover")
        local enumerations = 0
        local menu = {
            name = "filemanager",
            genItemTableFromPath = function()
                enumerations = enumerations + 1
                return { { is_file = true, path = "/library/a.epub" } }
            end,
        }
        local result = FolderCover.build(menu, {
            path = "/library/folder", attr = { mode = "directory" },
            mandatory = "2 \xef\x84\x94 7 \xef\x80\x96",
        }, "Folder/", 80, 120, { load_covers = false })

        assert.are.equal(0, enumerations)
        assert.are.equal(0, #calls.collect)
        assert.are.equal(7, result.count)
        assert.are.equal("Folder", result.title)
        assert.are.equal("placeholder", result.frame.kind)
        assert.is_true(result.frame.decorated)
    end)

    it("does not enumerate a physical folder in folder-name-only mode", function()
        local FolderCover = require("modules/filebrowser/folder_cover")
        cover_mode = "none"
        local enumerations = 0
        local result = FolderCover.build({
            name = "filemanager",
            genItemTableFromPath = function()
                enumerations = enumerations + 1
                return {}
            end,
        }, {
            path = "/library/folder", attr = { mode = "directory" },
            mandatory = "4 books",
        }, "Folder/", 80, 120)

        assert.are.equal(0, enumerations)
        assert.are.equal(4, result.count)
        assert.are.equal("none", result.mode)
    end)

    it("orders a folder without constructing child FileChooser items", function()
        local scans = 0
        install_lfs(function()
            return {
                { name = "b.epub" },
                { name = "a.epub" },
                { name = "notes.bin" },
                { name = "nested", mode = "directory" },
            }
        end, function() scans = scans + 1 end)
        local FolderCover = require("modules/filebrowser/folder_cover")
        local menu = {
            name = "filemanager",
            genItemTableFromPath = function() error("child item table was constructed") end,
        }
        local specs = { max_cover_w = 80, max_cover_h = 120 }
        local result = FolderCover.build(menu, {
            path = "/library/folder", attr = { mode = "directory" },
        }, "Folder/", 80, 120, { cover_specs = specs })

        assert.are.equal(1, scans)
        assert.are.equal("/library/folder", calls.explicit)
        assert.are.equal(1, #calls.collect)
        assert.are.equal(2, #calls.collect[1].entries)
        assert.are.equal("/library/folder/a.epub", calls.collect[1].entries[1].path)
        assert.are.equal("/library/folder/b.epub", calls.collect[1].entries[2].path)
        assert.are.equal(specs, calls.collect[1].specs)
        assert.are.equal(2, result.count)
        assert.are.equal("single", result.frame.kind)
        assert.is_true(calls.single.uniform)
    end)

    it("renders one automatic cover as a single cover in gallery and stack modes", function()
        local FolderCover = require("modules/filebrowser/folder_cover")
        local entry = { _zen_files = { "/library/only.epub" } }

        for _i, mode in ipairs({ "gallery", "stack" }) do
            cover_mode = mode
            local result = FolderCover.build({}, entry, "Folder", 80, 120)

            assert.are.equal("single", result.frame.kind)
            assert.are.equal(1, result.cover_count)
            assert.are.same({ width = 80, height = 120, uniform = true }, calls.single)
        end
    end)

    it("keeps explicit covers authoritative instead of filling their empty slots", function()
        install_lfs(function(path)
            if path == "/library/folder" then
                return { { name = "a.epub" }, { name = "b.epub" } }
            end
            return {}
        end)
        calls.explicit_covers = { { data = "custom" } }
        calls.has_explicit = true
        local FolderCover = require("modules/filebrowser/folder_cover")

        local result = FolderCover.build({ name = "filemanager" }, {
            path = "/library/folder",
            attr = { mode = "directory" },
        }, "Folder", 80, 120)

        assert.are.equal(0, #calls.collect)
        assert.are.equal("single", result.frame.kind)
        assert.are.equal(1, result.cover_count)
    end)

    it("does not reuse book-based gallery composites for explicit covers", function()
        install_lfs(function() return {} end)
        calls.explicit_covers = { { data = "custom-1" }, { data = "custom-2" } }
        calls.has_explicit = true
        calls.gallery_cache_key = "book-gallery"
        local FolderCover = require("modules/filebrowser/folder_cover")

        local result = FolderCover.build({ name = "filemanager" }, {
            path = "/library/folder",
            attr = { mode = "directory" },
        }, "Folder", 80, 120)

        assert.are.equal("gallery", result.frame.kind)
        assert.is_nil(calls.draw_gallery_cache_key)
        assert.are.equal(0, #calls.collect)
    end)

    it("still uses the selected multi-cover renderer for multiple covers", function()
        local FolderCover = require("modules/filebrowser/folder_cover")
        calls.collect_covers = { { data = "one" }, { data = "two" } }

        cover_mode = "gallery"
        local gallery = FolderCover.build({}, {
            _zen_files = { "/library/a.epub", "/library/b.epub" },
        }, "Folder", 80, 120)
        assert.are.equal("gallery", gallery.frame.kind)

        cover_mode = "stack"
        local stack = FolderCover.build({}, {
            _zen_files = { "/library/a.epub", "/library/b.epub" },
        }, "Folder", 80, 120)
        assert.are.equal("stack", stack.frame.kind)
        assert.are.equal(2, #calls.stack_covers)
    end)

    it("counts scanned children instead of interpreting a date as the count", function()
        install_lfs(function()
            return {
                { name = "a.epub" },
                { name = "b.epub" },
                { name = "notes.bin" },
            }
        end)
        local FolderCover = require("modules/filebrowser/folder_cover")
        local result = FolderCover.build({ name = "filemanager" }, {
            path = "/library/folder",
            attr = { mode = "directory" },
            mandatory = "2026-08-01 12:00",
        }, "Folder", 80, 120)

        assert.are.equal(2, result.count)
    end)

    it("retains only the configured number of book candidates", function()
        local yielded = 0
        install_lfs(function()
            return {
                { name = "f.epub" }, { name = "e.epub" }, { name = "d.epub" },
                { name = "c.epub" }, { name = "b.epub" }, { name = "a.epub" },
            }
        end, nil, function() yielded = yielded + 1 end)
        local FolderCover = require("modules/filebrowser/folder_cover")
        local menu = {
            name = "filemanager",
            genItemTableFromPath = function() error("child item table was constructed") end,
        }
        local entry = {
            path = "/library/folder",
            attr = { mode = "directory" },
            mandatory = "6 \xef\x80\x96",
        }

        local gallery = FolderCover.build(menu, entry, "Folder", 80, 120)
        assert.are.equal(6, gallery.count)
        assert.are.equal(4, #gallery.entries)
        assert.are.equal("/library/folder/a.epub", gallery.entries[1].path)
        assert.are.equal(6, yielded)

        cover_mode = "normal"
        local single = FolderCover.build(menu, entry, "Folder", 80, 120)
        assert.are.equal(6, single.count)
        assert.are.equal(1, #single.entries)
        assert.are.equal(1, calls.collect[#calls.collect].limit)
    end)

    it("only marks a non-empty folder finished when every book is finished", function()
        local statuses = {
            ["/library/folder/a.epub"] = "complete",
            ["/library/folder/b.epub"] = "complete",
        }
        ZenSpec.replace("common/book_status", {
            getEffectiveStatus = function(status) return status end,
            getEffectiveStatusFromFile = function(path) return statuses[path] end,
        })
        install_lfs(function()
            return { { name = "a.epub" }, { name = "b.epub" } }
        end)
        local FolderCover = require("modules/filebrowser/folder_cover")
        local entry = {
            path = "/library/folder",
            attr = { mode = "directory" },
        }
        local preview = { { path = "/library/folder/a.epub" } }

        assert.is_true(FolderCover.allBooksFinished({}, entry, preview, 2))

        statuses["/library/folder/b.epub"] = "reading"
        assert.is_false(FolderCover.allBooksFinished({}, entry, preview, 2))
        assert.is_false(FolderCover.allBooksFinished({}, entry, {}, 0))
    end)

    it("retains one candidate in single mode when the parent supplied the count", function()
        local yielded = 0
        cover_mode = "normal"
        install_lfs(function()
            return {
                { name = "first.epub" }, { name = "second.epub" },
                { name = "third.epub" }, { name = "fourth.epub" },
            }
        end, nil, function() yielded = yielded + 1 end)
        local FolderCover = require("modules/filebrowser/folder_cover")
        local result = FolderCover.build({ name = "filemanager" }, {
            path = "/library/folder",
            attr = { mode = "directory" },
            mandatory = "4 \xef\x80\x96",
        }, "Folder", 80, 120)

        assert.are.equal(4, yielded)
        assert.are.equal(4, result.count)
        assert.are.equal(1, #result.entries)
        assert.are.equal(1, calls.collect[1].limit)
    end)

    it("shares candidate one across modes and adds only three gallery candidates", function()
        install_lfs(function()
            return {
                { name = "first.epub" }, { name = "second.epub" },
                { name = "third.epub" }, { name = "fourth.epub" },
            }
        end)
        local FolderCover = require("modules/filebrowser/folder_cover")
        local entry = {
            path = "/library/folder",
            attr = { mode = "directory" },
            mandatory = "4 books",
        }

        local single = FolderCover.previewEntries({}, entry, 1)
        local gallery = FolderCover.previewEntries({}, entry, 4)

        assert.are.equal("/library/folder/first.epub", single[1].path)
        assert.are.equal(single[1].path, gallery[1].path)
        assert.are.equal(4, #gallery)
    end)

    it("invalidates ordered descriptors when a folder sort is reversed", function()
        local reverse = false
        local scans = 0
        _G.__ZEN_FOLDER_SORT = {
            get = function()
                return { collate = "title", reverse = reverse }
            end,
        }
        ZenSpec.replace("common/db_bookinfo", {
            getLightMetadata = function()
                return {
                    ["/library/folder/a.epub"] = { title = "Alpha" },
                    ["/library/folder/z.epub"] = { title = "Zulu" },
                }
            end,
        })
        install_lfs(function()
            return { { name = "z.epub" }, { name = "a.epub" } }
        end, function() scans = scans + 1 end)
        local FolderCover = require("modules/filebrowser/folder_cover")
        local menu = {
            name = "filemanager",
            collates = {
                title = {
                    init_sort_func = function()
                        return function(a, b)
                            return a.doc_props.display_title < b.doc_props.display_title
                        end
                    end,
                },
            },
            getSortingFunction = function(_self, collate, sort_reverse)
                local less = collate.init_sort_func()
                if sort_reverse then
                    return function(a, b) return less(b, a) end
                end
                return less
            end,
        }
        local entry = {
            path = "/library/folder",
            attr = { mode = "directory" },
            mandatory = "2 books",
        }

        local ascending = FolderCover.previewEntries(menu, entry, 1)
        reverse = true
        local descending = FolderCover.previewEntries(menu, entry, 1)

        assert.are.equal("/library/folder/a.epub", ascending[1].path)
        assert.are.equal("/library/folder/z.epub", descending[1].path)
        assert.are.equal(2, scans)
    end)

    it("shares one history snapshot across folder descriptors", function()
        local history_loads = 0
        _G.__ZEN_FOLDER_SORT = {
            get = function() return { collate = "access", reverse = false } end,
        }
        ZenSpec.replace("readhistory", {
            hist = {
                { file = "/library/one/b.epub", time = 20 },
                { file = "/library/one/a.epub", time = 10 },
            },
            last_read_time = 1,
        })
        ZenSpec.replace("common/history_index", {
            load = function()
                history_loads = history_loads + 1
                return { marker = true }
            end,
            fileTime = function(_history, path)
                if path == "/library/one/b.epub" then return 20 end
                if path == "/library/one/a.epub" then return 10 end
            end,
        })
        install_lfs(function(path)
            if path == "/library/one" then
                return { { name = "a.epub" }, { name = "b.epub" } }
            end
            return { { name = "c.epub" } }
        end)
        local FolderCover = require("modules/filebrowser/folder_cover")
        local collate = {
            init_sort_func = function()
                return function(a, b) return a.attr.access > b.attr.access end
            end,
        }
        local menu = { name = "filemanager", collates = { access = collate } }

        local first = FolderCover.previewEntries(menu, {
            path = "/library/one", attr = { mode = "directory" },
        }, 1)
        FolderCover.previewEntries(menu, {
            path = "/library/two", attr = { mode = "directory" },
        }, 1)

        assert.are.equal("/library/one/b.epub", first[1].path)
        assert.are.equal(1, history_loads)
    end)

    it("defers expensive sort item hydration until the folder queue runs", function()
        local item_hydrations = 0
        _G.__ZEN_FOLDER_SORT = {
            get = function() return { collate = "rating", reverse = false } end,
        }
        install_lfs(function()
            return { { name = "b.epub" }, { name = "a.epub" } }
        end)
        local FolderCover = require("modules/filebrowser/folder_cover")
        local menu = {
            name = "filemanager",
            collates = {
                rating = {
                    item_func = function(item)
                        item_hydrations = item_hydrations + 1
                        item.rating = item.text == "b.epub" and 5 or 1
                        item.doc_props = { display_title = item.text }
                    end,
                    init_sort_func = function()
                        return function(a, b) return a.rating > b.rating end
                    end,
                },
            },
        }
        local entry = {
            path = "/library/folder", attr = { mode = "directory" },
        }

        local synchronous = FolderCover.previewEntries(menu, entry, 1)
        local hydrated = FolderCover.previewEntries(
            menu, entry, 1, { allow_expensive = true })

        assert.are.equal("/library/folder/a.epub", synchronous[1].path)
        assert.are.equal("/library/folder/b.epub", hydrated[1].path)
        assert.are.equal(2, item_hydrations)
    end)

    it("reuses bounded physical-folder descriptors until invalidated", function()
        local enumerations = 0
        install_lfs(function(path)
            return { { name = path:match("([^/]+)$") .. ".epub" } }
        end, function() enumerations = enumerations + 1 end)
        local FolderCover = require("modules/filebrowser/folder_cover")
        local menu = {
            name = "filemanager",
            genItemTableFromPath = function() error("child item table was constructed") end,
        }
        local entry = { path = "/library/folder", attr = { mode = "directory" } }

        FolderCover.build(menu, entry, "Folder/", 80, 120)
        local cached = FolderCover.build(menu, entry, "Folder/", 80, 120)

        assert.are.equal(1, enumerations)
        assert.is_true(cached.perf.descriptor_cache_hit)

        FolderCover.clear(entry.path)
        local rebuilt = FolderCover.build(menu, entry, "Folder/", 80, 120)
        assert.are.equal(2, enumerations)
        assert.is_false(rebuilt.perf.descriptor_cache_hit)
    end)

    it("evicts the oldest folder descriptor after 32 folders", function()
        local enumerations = 0
        install_lfs(function()
            return { { name = "book.epub" } }
        end, function() enumerations = enumerations + 1 end)
        local FolderCover = require("modules/filebrowser/folder_cover")
        local menu = {
            name = "filemanager",
            genItemTableFromPath = function() error("child item table was constructed") end,
        }
        for index = 1, 33 do
            FolderCover.build(menu, {
                path = "/library/folder-" .. index,
                attr = { mode = "directory" },
            }, "Folder", 80, 120)
        end

        local rebuilt = FolderCover.build(menu, {
            path = "/library/folder-1",
            attr = { mode = "directory" },
        }, "Folder", 80, 120)

        assert.are.equal(34, enumerations)
        assert.is_false(rebuilt.perf.descriptor_cache_hit)
    end)

    it("passes non-uniform sizing through to group previews", function()
        local FolderCover = require("modules/filebrowser/folder_cover")
        FolderCover.build({}, {
            _zen_files = { "/library/landscape.epub" },
        }, "Author", 80, 120, { uniform = false })

        assert.is_false(calls.single.uniform)
    end)

    it("reports cached-only folder previews that still need hydration", function()
        local FolderCover = require("modules/filebrowser/folder_cover")
        calls.collect_pending = true

        local result = FolderCover.build({}, {
            _zen_files = { "/library/cold.epub" },
        }, "Author", 80, 120, { cached_only = true })

        assert.is_true(calls.collect[1].cached_only)
        assert.is_true(result.needs_hydration)
        assert.are.equal(1, result.cover_count)
    end)

    it("hydrates cold physical and virtual folders through the shared provider", function()
        install_lfs(function(path)
            if path == "/library/folder" then return { { name = "inside.epub" } } end
            return {}
        end)
        local FolderCover = require("modules/filebrowser/folder_cover")
        calls.collect_cold = true
        local cases = {
            {
                title = "Physical",
                entry = {
                    path = "/library/folder",
                    attr = { mode = "directory" },
                    mandatory = "1 book",
                },
                member = "/library/folder/inside.epub",
                path = "/library/folder",
            },
            {
                title = "Virtual",
                entry = {
                    path = "/library/Series",
                    is_series_group = true,
                    series_items = {
                        { is_file = true, path = "/library/series-1.epub" },
                    },
                },
                member = "/library/series-1.epub",
            },
        }

        for _i, case in ipairs(cases) do
            local first_call = #calls.collect + 1
            local cold = FolderCover.build(
                { name = "filemanager" }, case.entry, case.title, 80, 120,
                { cached_only = true })
            local hydrated = FolderCover.build(
                { name = "filemanager" }, case.entry, case.title, 80, 120,
                { cached_only = false })

            assert.is_true(cold.needs_hydration)
            assert.are.equal(0, cold.cover_count)
            assert.are.equal("placeholder", cold.frame.kind)
            assert.is_false(hydrated.needs_hydration)
            assert.are.equal(1, hydrated.cover_count)
            assert.are.equal("single", hydrated.frame.kind)
            assert.is_true(calls.collect[first_call].cached_only)
            assert.is_false(calls.collect[first_call + 1].cached_only)
            assert.are.equal(case.path, calls.collect[first_call].path)
            assert.are.equal(case.member, calls.collect[first_call].entries[1].path)
        end
    end)

    it("reuses a complete gallery bitmap without loading its child covers", function()
        local FolderCover = require("modules/filebrowser/folder_cover")
        calls.gallery_cache_key = "gallery:key"
        calls.cached_gallery = { kind = "gallery", bordersize = 2 }

        local result = FolderCover.build({}, {
            _zen_files = { "/library/a.epub", "/library/b.epub" },
        }, "Author", 80, 120)

        assert.are.equal(0, #calls.collect)
        assert.are.equal("gallery:key", calls.gallery_lookup_key)
        assert.is_true(result.perf.composite_cache_hit)
        assert.are.equal(2, result.cover_count)
    end)

    it("checks a supplied gallery descriptor without loading child covers", function()
        local FolderCover = require("modules/filebrowser/folder_cover")
        calls.gallery_cache_key = "gallery:key"
        calls.gallery_cached = true

        assert.is_true(FolderCover.isGalleryCached({}, {
            _zen_files = { "/library/a.epub", "/library/b.epub" },
        }, "Author", 80, 120, {
            entries = {
                { path = "/library/a.epub" },
                { path = "/library/b.epub" },
            },
        }))
        assert.are.same({ key = "gallery:key", width = 80, height = 120 },
            calls.gallery_cached_request)
        assert.are.equal(0, #calls.collect)
    end)

    it("warms and releases a complete multi-cover gallery bitmap", function()
        local FolderCover = require("modules/filebrowser/folder_cover")
        calls.gallery_cache_key = "gallery:key"
        calls.cached_gallery = nil
        calls.collect_covers = { { data = "one" }, { data = "two" } }

        local warmed, cached = FolderCover.warmGallery({}, {
            _zen_files = { "/library/a.epub", "/library/b.epub" },
        }, "Author", 80, 120)

        assert.is_true(warmed)
        assert.is_false(cached)
        assert.is_true(calls.gallery_freed)
    end)

    it("gives a natural single preview the same full bounds as its child", function()
        local FolderCover = require("modules/filebrowser/folder_cover")
        cover_mode = "normal"
        FolderCover.build({}, {
            _zen_files = { "/library/tall.epub" },
        }, "Author", 80, 122, { uniform = false })

        assert.are.same({ width = 80, height = 122, uniform = false }, calls.single)
    end)

    it("keeps mosaic spine lines short and separated from the cover", function()
        ZenSpec.replace("device", {
            screen = { scaleBySize = function(_self, value) return math.floor(value + 0.5) end },
        })
        ZenSpec.replace("ffi/blitbuffer", { COLOR_GRAY_4 = 4, COLOR_BLACK = 0 })
        ZenSpec.replace("ui/size", { line = { medium = 2 } })
        ZenSpec.unload("modules/filebrowser/folder_cover")
        local FolderCover = require("modules/filebrowser/folder_cover")
        local rects = {}
        local bb = {
            paintRect = function(_self, x, y, width, height)
                rects[#rects + 1] = { x = x, y = y, width = width, height = height }
            end,
        }

        local orientation = FolderCover.paintSpines(bb, {
            dimen = { x = 30, y = 20, w = 100, h = 150 },
        }, 0, 0, { rounded = true })

        assert.are.equal("top", orientation)
        assert.are.same({
            { x = 37, y = 13, width = 86, height = 2 },
            { x = 35, y = 17, width = 89, height = 2 },
        }, rects)
        assert.are.equal(1, 20 - (rects[2].y + rects[2].height))
    end)

    it("moves spines left when the mosaic has no room above", function()
        ZenSpec.replace("device", {
            screen = { scaleBySize = function(_self, value) return math.floor(value + 0.5) end },
        })
        ZenSpec.replace("ffi/blitbuffer", { COLOR_GRAY_4 = 4, COLOR_BLACK = 0 })
        ZenSpec.replace("ui/size", { line = { medium = 2 } })
        ZenSpec.unload("modules/filebrowser/folder_cover")
        local FolderCover = require("modules/filebrowser/folder_cover")
        local rects = {}
        local bb = {
            paintRect = function(_self, x, y, width, height)
                rects[#rects + 1] = { x = x, y = y, width = width, height = height }
            end,
        }

        local orientation = FolderCover.paintSpines(bb, {
            dimen = { x = 30, y = 2, w = 100, h = 150 },
        }, 0, 0, { rounded = true })

        assert.are.equal("left", orientation)
        assert.are.same({
            { x = 23, y = 10, width = 2, height = 133 },
            { x = 27, y = 8, width = 2, height = 137 },
        }, rects)
        assert.are.equal(1, 30 - (rects[2].x + rects[2].width))
    end)

    it("matches mosaic spine proportions in list view", function()
        ZenSpec.replace("device", {
            screen = { scaleBySize = function(_self, value) return math.floor(value + 0.5) end },
        })
        ZenSpec.replace("ffi/blitbuffer", { COLOR_GRAY_4 = 4, COLOR_BLACK = 0 })
        ZenSpec.replace("ui/size", { line = { medium = 2 } })
        ZenSpec.unload("modules/filebrowser/folder_cover")
        local FolderCover = require("modules/filebrowser/folder_cover")
        local rects = {}
        local bb = {
            paintRect = function(_self, x, y, width, height)
                rects[#rects + 1] = { x = x, y = y, width = width, height = height }
            end,
        }

        FolderCover.paintSpines(bb, {
            dimen = { x = 30, y = 6, w = 60, h = 90 },
        }, 0, 0, {
            orientation = "left", rounded = true,
        })

        assert.are.same({
            { x = 23, y = 13, width = 2, height = 76 },
            { x = 27, y = 11, width = 2, height = 79 },
        }, rects)
    end)

    it("rounds spine line ends when supported by the blitbuffer", function()
        ZenSpec.replace("device", {
            screen = { scaleBySize = function(_self, value) return math.floor(value + 0.5) end },
        })
        ZenSpec.replace("ffi/blitbuffer", { COLOR_GRAY_4 = 4, COLOR_BLACK = 0 })
        ZenSpec.replace("ui/size", { line = { medium = 2 } })
        ZenSpec.unload("modules/filebrowser/folder_cover")
        local FolderCover = require("modules/filebrowser/folder_cover")
        local rounded = {}
        local bb = {
            paintRoundedRect = function(_self, x, y, width, height, _color, radius)
                rounded[#rounded + 1] = {
                    x = x, y = y, width = width, height = height, radius = radius,
                }
            end,
        }

        FolderCover.paintSpines(bb, {
            dimen = { x = 30, y = 6, w = 60, h = 90 },
        }, 0, 0, { orientation = "left", rounded = true })

        assert.are.same({
            { x = 23, y = 13, width = 2, height = 76, radius = 1 },
            { x = 27, y = 11, width = 2, height = 79, radius = 1 },
        }, rounded)
    end)

    it("shares rounded spine decoration with embedded folder widgets", function()
        local FolderCover = require("modules/filebrowser/folder_cover")
        local painted
        local original_paint_spines = FolderCover.paintSpines
        FolderCover.paintSpines = function(bb, frame, x, y, options)
            painted = { bb = bb, frame = frame, x = x, y = y, options = options }
        end
        local frame = { dimen = { x = 10, y = 20, w = 80, h = 120 } }
        local bb = {}

        FolderCover.paintDecorations({
            _zen_cover_frame = frame,
            _zen_folder_count = 2,
        }, bb, {
            browser_folder_cover = {
                show_spine_lines = true,
                show_item_count = false,
            },
            features = { browser_cover_rounded_corners = true },
        }, 3, 4)
        FolderCover.paintSpines = original_paint_spines

        assert.are.equal(bb, painted.bb)
        assert.are.equal(frame, painted.frame)
        assert.are.same({ x = 3, y = 4 }, { x = painted.x, y = painted.y })
        assert.is_true(painted.options.rounded)
    end)

    it("uses synthetic group and collection members without scanning paths", function()
        local FolderCover = require("modules/filebrowser/folder_cover")
        local menu = {
            _zen_coll_list = true,
            _zen_get_collection_files = function()
                return { "/library/b.epub", "/library/a.epub" }
            end,
            _zen_get_collection_title = function() return "Favorites" end,
            genItemTableFromPath = function() error("synthetic group scanned a path") end,
        }
        local result = FolderCover.build(menu, { name = "favorites" }, nil, 80, 120)

        assert.are.equal("Favorites", result.title)
        assert.are.equal(2, result.count)
        assert.is_nil(calls.collect[1].path)
        assert.are.equal("/library/b.epub", calls.collect[1].entries[1].path)
        assert.are.equal("/library/a.epub", calls.collect[1].entries[2].path)
    end)

    it("uses automatic-series members instead of scanning its synthetic path", function()
        local scans = 0
        install_lfs(function() return {} end, function() scans = scans + 1 end)
        local FolderCover = require("modules/filebrowser/folder_cover")
        local first = { is_file = true, path = "/library/saga-1.epub" }
        local second = { is_file = true, path = "/library/saga-2.epub" }
        local result = FolderCover.build({ name = "filemanager" }, {
            text = "Saga",
            path = "/library/Saga",
            is_file = false,
            is_directory = true,
            is_series_group = true,
            series_items = { first, second },
            attr = { mode = "directory" },
            mode = "directory",
        }, "Saga", 80, 120)

        assert.are.equal(0, scans)
        assert.are.equal(2, result.count)
        assert.are.same({ first, second }, result.entries)
        assert.is_nil(calls.collect[1].path)
        assert.are.equal("series\30/library/Saga", calls.gallery_key_args[1])
        assert.are.equal("single", result.frame.kind)
    end)

    it("counts all virtual members while retaining only preview candidates", function()
        local FolderCover = require("modules/filebrowser/folder_cover")
        local files = {}
        for index = 1, 6 do files[index] = "/library/book-" .. index .. ".epub" end

        local gallery = FolderCover.build({}, { _zen_files = files }, "Author", 80, 120)
        assert.are.equal(6, gallery.count)
        assert.are.equal(4, #gallery.entries)

        cover_mode = "normal"
        local single = FolderCover.build({}, { _zen_files = files }, "Author", 80, 120)
        assert.are.equal(6, single.count)
        assert.are.equal(1, #single.entries)
    end)

    it("does not sort collection members when cover loading is suppressed", function()
        local FolderCover = require("modules/filebrowser/folder_cover")
        local provider_calls = 0
        local menu = {
            _zen_coll_list = true,
            _zen_get_collection_files = function()
                provider_calls = provider_calls + 1
                return { "/library/a.epub" }
            end,
        }
        local result = FolderCover.build(menu, {
            name = "favorites", mandatory = "3 books",
        }, "Favorites", 80, 120, { load_covers = false })

        assert.are.equal(0, provider_calls)
        assert.are.equal(3, result.count)
    end)

    it("uses virtual-group size without building member descriptors when suppressed", function()
        local FolderCover = require("modules/filebrowser/folder_cover")
        local result = FolderCover.build({}, {
            _zen_files = { "/library/a.epub", "/library/b.epub" },
        }, "Author", 80, 120, { load_covers = false })

        assert.are.equal(2, result.count)
        assert.is_nil(result.entries)
        assert.are.equal(0, #calls.collect)
    end)

    it("preserves numeric collection counts when cover loading is suppressed", function()
        local FolderCover = require("modules/filebrowser/folder_cover")
        local result = FolderCover.build({ _zen_coll_list = true }, {
            name = "favorites", mandatory = 3,
        }, "Favorites", 80, 120, { load_covers = false })

        assert.are.equal(3, result.count)
    end)
end)
