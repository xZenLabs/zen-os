describe("Rakuyomi availability", function()
    local original_filemanager
    local original_bookinfomanager
    local original_documentregistry
    local original_cbz_document
    local original_bookinfo
    local original_docsettings

    before_each(function()
        original_filemanager = package.loaded["apps/filemanager/filemanager"]
        original_bookinfomanager = package.loaded.bookinfomanager
        original_documentregistry = package.loaded["document/documentregistry"]
        original_cbz_document = package.loaded["extensions/CbzDocument"]
        original_bookinfo = package.loaded["apps/filemanager/filemanagerbookinfo"]
        original_docsettings = package.loaded.docsettings
        ZenSpec.replace("apps/filemanager/filemanagerbookinfo", { getCoverImage = function() end })
        ZenSpec.replace("docsettings", { findCustomCoverFile = function() end })
        ZenSpec.unload("modules/filebrowser/patches/rakuyomi")
    end)

    after_each(function()
        package.loaded["apps/filemanager/filemanager"] = original_filemanager
        package.loaded.bookinfomanager = original_bookinfomanager
        package.loaded["document/documentregistry"] = original_documentregistry
        package.loaded["extensions/CbzDocument"] = original_cbz_document
        package.loaded["apps/filemanager/filemanagerbookinfo"] = original_bookinfo
        package.loaded.docsettings = original_docsettings
        ZenSpec.unload("modules/filebrowser/patches/rakuyomi")
    end)

    it("exports the availability API used by ZenOS initialization", function()
        package.loaded["apps/filemanager/filemanager"] = {
            instance = { rakuyomi = {} },
        }

        local Rakuyomi = require("modules/filebrowser/patches/rakuyomi")

        assert.is_table(Rakuyomi)
        assert.is_function(Rakuyomi.is_available)
        assert.is_true(Rakuyomi.is_available())
    end)

    it("uses Rakuyomi's CBZ reader only for chapter metadata extraction", function()
        local default_provider = {}
        local cbz_provider = {}
        local DocumentRegistry = {
            getProvider = function() return default_provider end,
        }
        local seen_provider
        local BookInfoManager = {
            extractBookInfo = function(_, filepath)
                seen_provider = DocumentRegistry:getProvider(filepath)
                return true
            end,
            getBookInfo = function() return { title = "Cached" } end,
            deleteBookInfo = function() end,
        }
        ZenSpec.replace("bookinfomanager", BookInfoManager)
        ZenSpec.replace("document/documentregistry", DocumentRegistry)
        ZenSpec.replace("extensions/CbzDocument", cbz_provider)

        local Rakuyomi = require("modules/filebrowser/patches/rakuyomi")
        Rakuyomi.isChapterFile = function(path)
            return path == "/library/chapter.cbz"
        end

        assert.is_true(Rakuyomi.installMetadataIntegration())
        assert.is_true(BookInfoManager:extractBookInfo("/library/chapter.cbz"))
        assert.is_true(rawequal(cbz_provider, seen_provider))
        assert.is_true(rawequal(default_provider, DocumentRegistry:getProvider("/library/book.cbz")))

        assert.is_true(BookInfoManager:extractBookInfo("/library/book.cbz"))
        assert.is_true(rawequal(default_provider, seen_provider))
    end)

    it("reads and caches the metadata fields needed by home widgets", function()
        local reads = 0
        ZenSpec.replace("extensions/CbzDocument", {
            _getComicBookInfoJSONFromBinary = function(_, path)
                reads = reads + 1
                assert.is_nil(path)
                return "metadata"
            end,
            _parseMetadata = function(_, json)
                assert.equals("metadata", json)
                return {
                    title = "Chapter title",
                    author = "Manga Author",
                    series = "Manga Series",
                    series_index = "4.5",
                    notes = "Chapter description",
                }
            end,
        })

        local Rakuyomi = require("modules/filebrowser/patches/rakuyomi")
        Rakuyomi.isChapterFile = function() return true end

        local metadata = Rakuyomi.getMetadata("/library/chapter.cbz")
        assert.are.same({
            title = "Chapter title",
            authors = "Manga Author",
            series = "Manga Series",
            series_index = 4.5,
            description = "Chapter description",
        }, metadata)
        assert.is_true(rawequal(metadata, Rakuyomi.getMetadata("/library/chapter.cbz")))
        assert.equals(1, reads)
        assert.is_nil(Rakuyomi.getMetadata("/library/chapter.epub"))
    end)

    it("restores provider lookup when Rakuyomi metadata extraction fails", function()
        local original_get_provider = function() return "default" end
        local DocumentRegistry = { getProvider = original_get_provider }
        local BookInfoManager = {
            extractBookInfo = function(_, filepath)
                DocumentRegistry:getProvider(filepath)
                error("broken CBZ")
            end,
        }
        ZenSpec.replace("bookinfomanager", BookInfoManager)
        ZenSpec.replace("document/documentregistry", DocumentRegistry)
        ZenSpec.replace("extensions/CbzDocument", {})

        local Rakuyomi = require("modules/filebrowser/patches/rakuyomi")
        Rakuyomi.isChapterFile = function() return true end
        assert.is_true(Rakuyomi.installMetadataIntegration())

        local ok, err = pcall(BookInfoManager.extractBookInfo,
            BookInfoManager, "/library/chapter.cbz")
        assert.is_false(ok)
        assert.matches("broken CBZ", err, 1, true)
        assert.is_true(rawequal(original_get_provider, DocumentRegistry.getProvider))
    end)

    it("drops a legacy title-less cache row once so it can be re-extracted", function()
        local deletes = 0
        local BookInfoManager = {
            extractBookInfo = function() return true end,
            getBookInfo = function() return { title = nil, has_meta = "Y" } end,
            deleteBookInfo = function() deletes = deletes + 1 end,
        }
        ZenSpec.replace("bookinfomanager", BookInfoManager)
        ZenSpec.replace("document/documentregistry", {
            getProvider = function() return {} end,
        })
        ZenSpec.replace("extensions/CbzDocument", {})

        local Rakuyomi = require("modules/filebrowser/patches/rakuyomi")
        Rakuyomi.isChapterFile = function() return true end
        assert.is_true(Rakuyomi.installMetadataIntegration())

        assert.is_nil(BookInfoManager:getBookInfo("/library/chapter.cbz"))
        assert.equals(1, deletes)
        assert.is_table(BookInfoManager:getBookInfo("/library/chapter.cbz"))
        assert.equals(1, deletes)
    end)
end)

describe("Rakuyomi series reading direction", function()
    local names = { "modules/filebrowser/patches/rakuyomi", "MangaReader", "Backend",
        "RakuyomiShared", "ui/trapper", "extensions/CbzDocument" }
    local saved, settings, Rakuyomi, MangaReader, Backend, callbacks, ui, series, initialized, received
    local viewers = { [0] = "DefaultViewer", "Rtl", "Ltr", "Vertical", "Scroll" }

    before_each(function()
        saved = {}
        for _i, name in ipairs(names) do saved[name] = package.loaded[name] end
        settings = G_reader_settings
        _G.G_reader_settings = ZenSpec.memorySettings()
        callbacks, received, initialized = {}, {}, true
        series = { id = "series", source = { id = "source" }, viewer = "Rtl", state_viewer = true }
        ui = {
            document = { file = "/library/chapter.cbz" },
            view = { inverse_reading_order = false, onToggleReadingOrder = function(self, rtl)
                self.inverse_reading_order = rtl
            end },
            registerPostInitCallback = function(_self, callback) callbacks[#callbacks + 1] = callback end,
        }
        Backend = {
            MangaViewerName = viewers,
            getBackend = function() end,
            getInitialized = function() return initialized end,
            getMangasInLibrary = function()
                return { type = "SUCCESS", body = {
                    { id = "series", source = { id = "other-source" }, viewer = "Ltr" }, series,
                } }
            end,
        }
        MangaReader = {
            initializeFromReaderUI = function() return "native init" end,
            show = function(self, options)
                received[#received + 1] = options
                local global = G_reader_settings:readSetting("rakuyomi_global_viewer")
                for id, name in pairs(viewers) do
                    if name == global or not global and name == options.viewer then self.viewer = id end
                end
                self:applyViewMode(ui)
                return "native show"
            end,
            applyViewMode = function(self, reader)
                if self.viewer ~= 0 then
                    reader.view:onToggleReadingOrder(self.viewer == 1 and not G_reader_settings:isTrue("rakuyomi_never_rtl"))
                end
                return "native view"
            end,
        }
        ZenSpec.replace("MangaReader", MangaReader)
        ZenSpec.replace("Backend", Backend)
        ZenSpec.replace("ui/trapper", { wrap = function(_self, callback) callback() end })
        ZenSpec.replace("extensions/CbzDocument", {})
        ZenSpec.replace("RakuyomiShared", { getOrigin = function()
            return { chapter_id = "chapter", manga_id = { source_id = "source", manga_id = "series" } }
        end })
        ZenSpec.unload("modules/filebrowser/patches/rakuyomi")
        Rakuyomi = require("modules/filebrowser/patches/rakuyomi")
        Rakuyomi.isChapterFile = function(file) return file == ui.document.file end
        Rakuyomi.installReadingDirectionPatch()
    end)

    after_each(function()
        _G.G_reader_settings = settings
        for _i, name in ipairs(names) do package.loaded[name] = saved[name] end
    end)

    it("restores the series viewer for placeholder lists across chapters and source identities", function()
        for _i, rtl in ipairs({ true, false }) do
            series.viewer = rtl and "Rtl" or "Ltr"
            assert.equals("native show", MangaReader:show({ viewer = "DefaultViewer", state_viewer = false,
                chapter = { id = tostring(_i), source_id = "source", manga_id = "series" } }))
            assert.equals(series.viewer, received[_i].viewer)
            assert.is_true(received[_i].state_viewer)
            assert.equals(rtl, ui.view.inverse_reading_order)
        end
    end)

    it("keeps explicit viewers, the global override, and never-RTL preferences", function()
        MangaReader:show({ viewer = "Ltr", state_viewer = true, chapter = {} })
        assert.is_false(ui.view.inverse_reading_order)
        G_reader_settings:saveSetting("rakuyomi_global_viewer", "Rtl")
        MangaReader:show({ viewer = "Ltr", state_viewer = true, chapter = {} })
        assert.is_true(ui.view.inverse_reading_order)
        G_reader_settings:saveSetting("rakuyomi_never_rtl", true)
        MangaReader:show({ viewer = "Rtl", state_viewer = true, chapter = {} })
        assert.is_false(ui.view.inverse_reading_order)
    end)

    it("uses a consistent global default instead of contradictory chapter sidecars", function()
        MangaReader.viewer = 0
        for _i, global in ipairs({ true, false }) do
            G_reader_settings:saveSetting("inverse_reading_order", global)
            ui.view.inverse_reading_order = not global
            assert.equals("native view", MangaReader:applyViewMode(ui))
            assert.equals(global, ui.view.inverse_reading_order)
        end
    end)

    it("applies series settings to direct Home/history opens after sidecar loading", function()
        assert.equals("native init", MangaReader:initializeFromReaderUI(ui))
        assert.equals(1, #callbacks)
        ui.view.inverse_reading_order = false
        callbacks[1]()
        assert.is_true(ui.view.inverse_reading_order)
        series.viewer = "Ltr"
        MangaReader:initializeFromReaderUI(ui)
        ui.view.inverse_reading_order = true
        callbacks[2]()
        assert.is_false(ui.view.inverse_reading_order)
    end)

    it("honors viewer preferences and abandons closed readers", function()
        G_reader_settings:saveSetting("rakuyomi_auto_viewer_mode", false)
        series.state_viewer = false
        MangaReader:initializeFromReaderUI(ui)
        callbacks[1]()
        assert.is_false(ui.view.inverse_reading_order)
        G_reader_settings:saveSetting("rakuyomi_global_viewer", "Rtl")
        callbacks[1]()
        assert.is_true(ui.view.inverse_reading_order)
        G_reader_settings:saveSetting("rakuyomi_global_viewer", "invalid")
        series.state_viewer = true
        series.viewer = "Ltr"
        callbacks[1]()
        assert.is_false(ui.view.inverse_reading_order)
        ui.document = nil
        callbacks[1]()
        initialized = false
        callbacks[1]()
    end)

    it("leaves ordinary books alone and installs only once", function()
        Rakuyomi.isChapterFile = function() return false end
        MangaReader:initializeFromReaderUI(ui)
        assert.equals(0, #callbacks)
        local show = MangaReader.show
        Rakuyomi.installReadingDirectionPatch()
        assert.equals(show, MangaReader.show)
    end)
end)

describe("Rakuyomi series covers", function()
    local lfs = require("libs/libkoreader-lfs")
    local json = require("rapidjson")
    local names = {
        "modules/filebrowser/patches/rakuyomi", "datastorage", "util", "bookinfomanager",
        "document/documentregistry", "apps/filemanager/filemanagerbookinfo", "docsettings", "common/cover_utils",
    }
    local saved, root, files, Rakuyomi, BookInfo, BookInfoManager, chapter, poster, custom_cover
    local readable, hidden, native_cover_reads, loads
    local manga_id = "a2c1d849-af05-4bbc-b2a7-866ebb10331f"

    local function write(path, bytes)
        local file = assert(io.open(path, "wb"))
        file:write(bytes)
        file:close()
        files[#files + 1] = path
    end

    local function write_chapter(path, comment)
        comment = type(comment) == "table" and json.encode(comment) or comment
        write(path, "PK\005\006" .. string.rep("\0", 16)
            .. string.char(#comment % 256, math.floor(#comment / 256)) .. comment)
    end

    before_each(function()
        saved, files = {}, {}
        for _i, name in ipairs(names) do saved[name] = package.loaded[name] end
        root = os.tmpname()
        os.remove(root)
        assert(lfs.mkdir(root))
        assert(lfs.mkdir(root .. "/downloads"))
        assert(lfs.mkdir(root .. "/downloads/.posters"))
        chapter = root .. "/chapter.cbz"
        poster = root .. "/downloads/.posters/H6KDG9Ic-3BUnR0hjGDIfYc20TsMnUm-hHe45_7H40U.jpg"
        write_chapter(chapter, { chapter_id = "chapter-1", source_id = "multi.mangadex", manga_id = manga_id })
        write(poster, "cached series artwork")
        readable, hidden, native_cover_reads, loads = true, false, 0, 0
        custom_cover = nil
        ZenSpec.replace("datastorage", { getFullDataDir = function() return root end })
        ZenSpec.replace("util", { readFromFile = function() return '{"storage_path":"downloads"}' end })
        ZenSpec.replace("docsettings", { findCustomCoverFile = function() return custom_cover end })
        BookInfo = { getCoverImage = function(_self, document, file, force_orig)
            return custom_cover or "first page", file or document and document.file, force_orig
        end }
        BookInfoManager = {
            extractBookInfo = function() return true end,
            deleteBookInfo = function() end,
            getBookInfo = function(_self, path, get_cover)
                if get_cover then native_cover_reads = native_cover_reads + 1 end
                return { title = "Chapter title", pages = 20, has_cover = "Y", cover_fetched = "Y",
                    cover_w = 100, cover_h = 150, cover_sizetag = "200x300",
                    ignore_cover = hidden and "Y" or nil, cover_bb = get_cover and "first page" or nil,
                    filepath = path }
            end,
        }
        ZenSpec.replace("apps/filemanager/filemanagerbookinfo", BookInfo)
        ZenSpec.replace("bookinfomanager", BookInfoManager)
        ZenSpec.replace("document/documentregistry", { getProvider = function() return {} end })
        ZenSpec.replace("common/cover_utils", { loadExplicitCover = function(path, max_w, max_h)
            assert.equals(poster, path)
            if max_w then assert.same({ 100, 150 }, { max_w, max_h }) end
            loads = loads + 1
            if readable then return { data = "series cover", w = max_w and 80 or 600, h = max_h or 900 } end
        end })
        ZenSpec.unload("modules/filebrowser/patches/rakuyomi")
        Rakuyomi = require("modules/filebrowser/patches/rakuyomi")
        assert.is_true(Rakuyomi.installMetadataIntegration())
    end)

    after_each(function()
        for _i, path in ipairs(files) do os.remove(path) end
        lfs.rmdir(root .. "/downloads/.posters")
        lfs.rmdir(root .. "/downloads")
        lfs.rmdir(root)
        for _i, name in ipairs(names) do package.loaded[name] = saved[name] end
    end)

    it("matches Rakuyomi's poster hash by source and series for all chapters", function()
        assert.equals(poster, Rakuyomi.getSeriesCoverPath(chapter))
        local second = root .. "/chapter-2.cbz"
        write_chapter(second, { chapter_id = "chapter-2", source_id = "multi.mangadex", manga_id = manga_id })
        assert.equals(poster, Rakuyomi.getSeriesCoverPath(second))
        local other = root .. "/other-source.cbz"
        write_chapter(other, { chapter_id = "chapter-1", source_id = "multi.mangafire", manga_id = manga_id })
        assert.is_nil(Rakuyomi.getSeriesCoverPath(other))
        os.remove(poster)
        assert.is_nil(Rakuyomi.getSeriesCoverPath(chapter))
        write(poster, "artwork downloaded later")
        assert.equals(poster, Rakuyomi.getSeriesCoverPath(chapter))
    end)

    it("rejects ordinary comics and malformed origins", function()
        assert.is_nil(Rakuyomi.getSeriesCoverPath(nil))
        assert.is_nil(Rakuyomi.getSeriesCoverPath(root .. "/book.epub"))
        for index, comment in ipairs({ "not json", "[]", '{"manga_id":false}',
                '{"chapter_id":"one","source_id":1,"manga_id":"two"}',
                '{"chapter_id":"one","manga_id":{"source_id":"source","manga_id":"two"}}' }) do
            local path = root .. "/ordinary-" .. index .. ".cbz"
            write_chapter(path, comment)
            assert.is_nil(Rakuyomi.getSeriesCoverPath(path))
            assert.equals("first page", BookInfo:getCoverImage(nil, path))
        end
        assert.equals(0, loads)
    end)

    it("uses series artwork in the shared cover API while preserving overrides and fallback", function()
        assert.equals("series cover", BookInfo:getCoverImage({ file = chapter }))
        assert.equals("series cover", BookInfo:getCoverImage(nil, chapter))
        assert.same({ "first page", chapter, true }, { BookInfo:getCoverImage(nil, chapter, true) })
        custom_cover = "custom artwork"
        assert.equals("custom artwork", BookInfo:getCoverImage(nil, chapter))
        custom_cover = nil
        readable = false
        assert.equals("first page", BookInfo:getCoverImage(nil, chapter))
        os.remove(poster)
        assert.equals("first page", BookInfo:getCoverImage(nil, chapter))
    end)

    it("replaces existing first-page thumbnails without decoding them or changing chapter metadata", function()
        assert.is_true(Rakuyomi.installMetadataIntegration())
        local metadata = BookInfoManager:getBookInfo(chapter, false)
        assert.is_nil(metadata.cover_bb)
        assert.equals(0, loads)
        local info = BookInfoManager:getBookInfo(chapter, true)
        assert.equals("series cover", info.cover_bb)
        assert.same({ 80, 150, "80x150", "Chapter title", 20 },
            { info.cover_w, info.cover_h, info.cover_sizetag, info.title, info.pages })
        assert.equals(0, native_cover_reads)
        custom_cover = "custom artwork"
        assert.equals("first page", BookInfoManager:getBookInfo(chapter, true).cover_bb)
        custom_cover = nil
        readable = false
        assert.equals("first page", BookInfoManager:getBookInfo(chapter, true).cover_bb)
        hidden = true
        assert.is_nil(BookInfoManager:getBookInfo(chapter, true).cover_bb)
        assert.equals(2, native_cover_reads)
    end)
end)

describe("Rakuyomi recent Home series", function()
    local names = { "modules/filebrowser/patches/rakuyomi", "apps/filemanager/filemanager", "pluginloader",
        "config/manager", "ChapterListing", "LibraryView", "Backend", "docsettings", "common/cover_utils",
        "utils/findLastRead", "utils/getChapterDisplayName", "RakuyomiShared", "apps/reader/readerui",
        "libs/libkoreader-lfs", "ui/uimanager", "MangaReader", "common/shared_state", "ui/trapper", "ErrorDialog" }
    local saved, Rakuyomi, config, listing, opened_callback, starts, resumes, initialized, errors, resumed_manga
    local saved_settings, queued, invalidated, native_opens
    local file = "/data/rakuyomi/tmpfs/chapter.cbz"
    local manga = { id = "series", source = { id = "source" }, title = "Series title",
        manga_cover = "file:///posters/series%20cover.jpg", viewer = "Rtl", state_viewer = true }
    local chapter = { id = "chapter", title = "Chapter title", chapter_num = 12.5 }

    before_each(function()
        saved, config, starts, resumes, initialized, errors = {}, {}, 0, 0, true, 0
        resumed_manga = nil
        saved_settings = G_reader_settings
        G_reader_settings = ZenSpec.memorySettings({ file_ask_to_open = true })
        queued, invalidated, native_opens = {}, {}, 0
        for _i, name in ipairs(names) do saved[name] = package.loaded[name] end
        ZenSpec.replace("apps/filemanager/filemanager", { instance = { rakuyomi = {
            showErrorDialog = function() errors = errors + 1 end,
        } } })
        ZenSpec.replace("pluginloader", {})
        ZenSpec.replace("apps/reader/readerui", { instance = { document = { file = file } } })
        ZenSpec.replace("libs/libkoreader-lfs", { attributes = function(path)
            if path == "/posters/series cover.jpg" then return "file" end
        end })
        ZenSpec.replace("config/manager", { get = function() return config end, save = function(value)
            assert.equals(config, value)
        end })
        ZenSpec.replace("utils/findLastRead", function(chapters) return chapters[1] end)
        ZenSpec.replace("utils/getChapterDisplayName", function(value)
            return "Ch. " .. value.chapter_num .. ' "' .. value.title .. '"'
        end)
        ZenSpec.replace("MangaReader", {})
        ZenSpec.replace("ui/uimanager", { nextTick = function(_self, callback) queued[#queued + 1] = callback end })
        ZenSpec.replace("common/shared_state", { get = function(_plugin, key)
            assert.equals("home", key)
            return { invalidateBookCache = function(path, history_changed)
                assert.is_true(history_changed)
                invalidated[#invalidated + 1] = path
            end }
        end })
        ZenSpec.replace("ui/trapper", { wrap = function(_self, callback) callback() end })
        ZenSpec.replace("ErrorDialog", { show = function() errors = errors + 1 end })
        local ChapterListing = { openChapterOnReader = function(_self, _chapter, _job, callback)
            native_opens = native_opens + 1
            opened_callback = callback
        end }
        function ChapterListing:new(options)
            options.chapters = { chapter }
            return setmetatable(options, { __index = self })
        end
        listing = setmetatable({ manga = manga }, { __index = ChapterListing })
        ZenSpec.replace("ChapterListing", ChapterListing)
        ZenSpec.replace("LibraryView", { _handleContinueReading = function(self, value)
            resumed_manga = value
            assert.is_true(self.hide_top_close)
            self:onClose(true)
            resumes = resumes + 1
        end })
        ZenSpec.replace("Backend", {
            getBackend = function() starts = starts + 1 end,
            getInitialized = function() return initialized end,
            getSettings = function()
                return { type = "SUCCESS", body = { chapter_sorting_mode = "descending", preload_chapters = 2 } }
            end,
        })
        ZenSpec.replace("docsettings", {
            hasSidecarFile = function() return true end,
            open = function(_self, path)
                assert.equals(file, path)
                return { readSetting = function(_doc, key)
                    if key == "percent_finished" then return 0.25 end
                    if key == "stats" then return { pages = 20 } end
                end }
            end,
        })
        ZenSpec.replace("common/cover_utils", { loadExplicitCover = function(path)
            assert.equals("/posters/series cover.jpg", path)
            return { data = "series cover", w = 200, h = 300 }
        end })
        ZenSpec.unload("modules/filebrowser/patches/rakuyomi")
        Rakuyomi = require("modules/filebrowser/patches/rakuyomi")
        Rakuyomi.getSeriesCoverPath = function() return "/posters/series cover.jpg" end
        Rakuyomi.installResumePatch()
    end)

    after_each(function()
        G_reader_settings = saved_settings
        for _i, name in ipairs(names) do package.loaded[name] = saved[name] end
    end)

    it("persists successful opens and renders series/chapter details without starting the backend", function()
        listing:openChapterOnReader(chapter)
        assert.is_nil(config.rakuyomi)
        opened_callback()
        local recent = Rakuyomi.getRecentSeries()[1]
        assert.equals(file, recent.file)
        assert.equals("Series title", recent.manga.title)
        local metadata = Rakuyomi.getRecentBook(recent, true)
        assert.equals('Ch. 12.5 "Chapter title"', metadata.chapter_label)
        assert.equals("Series title", metadata.title)
        assert.equals(5, metadata.current_page)
        assert.is_nil(metadata.cover_bb)
        assert.equals("series cover", Rakuyomi.getRecentBook(recent).cover_bb)
        listing.manga = { id = "series", source = { id = "source" }, title = "" }
        listing:openChapterOnReader({ id = "next", chapter_num = 13, file = file })
        opened_callback()
        assert.equals("Series title", Rakuyomi.getRecentSeries()[1].manga.title)
        ZenSpec.unload("modules/filebrowser/patches/rakuyomi")
        assert.equals(13, require("modules/filebrowser/patches/rakuyomi").getRecentSeries()[1].chapter.chapter_num)
        assert.equals(0, starts)
    end)

    it("delegates resume to Rakuyomi and preserves its startup failure handling", function()
        listing:openChapterOnReader(chapter)
        opened_callback()
        assert.is_false(Rakuyomi.resumeRecentSeries("/library/book.epub"))
        assert.equals(0, starts)
        assert.is_true(Rakuyomi.resumeRecentSeries(file))
        assert.equals(1, starts)
        assert.equals(1, resumes)
        assert.equals(manga, resumed_manga)
        initialized = false
        assert.is_true(Rakuyomi.resumeRecentSeries(file))
        assert.equals(1, errors)
        assert.equals(1, resumes)
    end)

    it("captures the new file after a deferred chapter switch and invalidates Home", function()
        listing:openChapterOnReader(chapter)
        opened_callback()
        local next_file = "/data/rakuyomi/downloads/next.cbz"
        local MangaReader = require("MangaReader")
        MangaReader.is_switching_document = true
        require("ui/uimanager"):nextTick(function()
            require("apps/reader/readerui").instance.document.file = next_file
            MangaReader.is_switching_document = false
        end)
        listing:openChapterOnReader({ id = "next", chapter_num = 13, title = "Next chapter" })
        opened_callback()
        assert.equals(12.5, Rakuyomi.getRecentSeries()[1].chapter.chapter_num)
        while #queued > 0 do table.remove(queued, 1)() end
        local recent = Rakuyomi.getRecentSeries()[1]
        assert.equals(next_file, recent.file)
        assert.equals(13, recent.chapter.chapter_num)
        assert.same({ file, next_file }, invalidated)
    end)

    it("opens directly from Home when KOReader's open confirmation is disabled", function()
        listing:openChapterOnReader(chapter)
        opened_callback()
        G_reader_settings:saveSetting("file_ask_to_open", false)
        assert.is_true(Rakuyomi.resumeRecentSeries(file))
        assert.equals(2, native_opens)
        assert.equals(0, resumes)
        assert.is_nil(G_reader_settings:readSetting("rakuyomi_skip_resume_confirm"))
        G_reader_settings:delSetting("file_ask_to_open")
        assert.is_true(Rakuyomi.resumeRecentSeries(file))
        assert.equals(3, native_opens)
        G_reader_settings:saveSetting("file_ask_to_open", true)
        assert.is_true(Rakuyomi.resumeRecentSeries(file))
        assert.equals(1, resumes)
        assert.equals(3, native_opens)
    end)

    it("reports settings failures before a direct Home resume", function()
        listing:openChapterOnReader(chapter)
        opened_callback()
        G_reader_settings:saveSetting("file_ask_to_open", false)
        require("Backend").getSettings = function() return { type = "ERROR", message = "settings unavailable" } end
        assert.is_true(Rakuyomi.resumeRecentSeries(file))
        assert.equals(1, errors)
        assert.equals(1, native_opens)
    end)

    it("keeps and resumes each series independently across sources and chapter changes", function()
        listing:openChapterOnReader(chapter)
        opened_callback()
        local second_file = "/data/rakuyomi/tmpfs/other.cbz"
        local second_manga = { id = "series", source = { id = "other-source" }, title = "Other series" }
        listing.manga = second_manga
        require("apps/reader/readerui").instance.document.file = second_file
        listing:openChapterOnReader({ id = "other-chapter", chapter_num = 7 })
        opened_callback()
        assert.equals(2, #Rakuyomi.getRecentSeries())
        assert.is_true(Rakuyomi.resumeRecentSeries(file))
        assert.equals(manga, resumed_manga)
        assert.is_true(Rakuyomi.resumeRecentSeries(second_file))
        assert.equals(second_manga, resumed_manga)
        listing.manga = { id = "series", source = { id = "source" }, title = "" }
        require("apps/reader/readerui").instance.document.file = file
        listing:openChapterOnReader({ id = "next-chapter", chapter_num = 13 })
        opened_callback()
        assert.equals(2, #Rakuyomi.getRecentSeries())
        assert.is_true(Rakuyomi.resumeRecentSeries(file))
        assert.equals("Series title", resumed_manga.title)
    end)

    it("seeds each series from its newest chapter history and sorts by last-read date", function()
        local other = "/data/rakuyomi/tmpfs/other.cbz"
        local older = "/data/rakuyomi/downloads/older.cbz"
        Rakuyomi.isChapterFile = function(path) return path:sub(-4) == ".cbz" end
        Rakuyomi.getMetadata = function(path)
            assert.is_not.equals(older, path)
            return { series = path == other and "Other series" or "Existing series",
                title = "Chapter title", series_index = 12.5 }
        end
        ZenSpec.replace("RakuyomiShared", { getOrigin = function(_self, path)
            return { chapter_id = path, manga_id = { source_id = "source",
                manga_id = path == other and "other-series" or "series" } }
        end })
        local series = Rakuyomi.getRecentSeries({ { file = "/library/book.epub", time = 200 },
            { file = other, time = 150 }, { file = file, time = 100 }, { file = older, time = 50 } })
        assert.equals(2, #series)
        assert.equals("Other series", series[1].manga.title)
        local recent = series[2]
        assert.equals("Existing series", recent.manga.title)
        assert.equals(12.5, recent.chapter.chapter_num)
        assert.equals(100, recent.time)
        series = Rakuyomi.getRecentSeries({ { file = file, time = 250 } })
        assert.equals("Existing series", series[1].manga.title)
        assert.equals(250, series[1].time)
        assert.equals(0, starts)
    end)

    it("preserves the previously saved single-series card", function()
        config.rakuyomi = { last_read_series = { file = file, time = 100, manga = manga, chapter = chapter } }
        local series = Rakuyomi.getRecentSeries()
        assert.equals(1, #series)
        assert.equals(file, series[1].file)
        assert.is_nil(config.rakuyomi.last_read_series)
    end)
end)

describe("Rakuyomi resume selection", function()
    local names = { "modules/filebrowser/patches/rakuyomi", "utils/findLastRead", "ChapterListing", "LibraryView" }
    local saved, Rakuyomi, ChapterListing, LibraryView, native_find

    before_each(function()
        saved = {}
        for _i, name in ipairs(names) do
            saved[name] = package.loaded[name]
            ZenSpec.unload(name)
        end
        native_find = function(chapters)
            for _i, chapter in ipairs(chapters) do
                if chapter.last_read or chapter.read then return chapter end
            end
            return chapters[#chapters]
        end
        local function chapter_resume()
            local findLastRead = native_find
            return function(self) return findLastRead(self.chapters) end
        end
        local function library_resume()
            local findLastRead = native_find
            return function(self)
                return (function() return findLastRead(self.chapters) end)()
            end
        end
        ChapterListing = {
            readContinue = chapter_resume(),
            openChapterOnReader = function(_self, chapter, job, on_opened)
                chapter.downloaded = true
                chapter.job = job
                if on_opened then on_opened("native return callback") end
                return "native result"
            end,
        }
        LibraryView = { _handleContinueReading = library_resume() }
        ZenSpec.replace("utils/findLastRead", native_find)
        ZenSpec.replace("ChapterListing", ChapterListing)
        ZenSpec.replace("LibraryView", LibraryView)
        Rakuyomi = require("modules/filebrowser/patches/rakuyomi")
    end)

    after_each(function()
        for _i, name in ipairs(names) do package.loaded[name] = saved[name] end
    end)

    it("resumes the newest timestamp from the chapter list and library regardless of chapter order", function()
        Rakuyomi.installResumePatch()
        local first = { id = "1", read = true, last_read = 100 }
        local second = { id = "2", read = true, last_read = 200 }
        local third = { id = "3", read = false, downloaded = true, last_read = 300 }
        for _i, chapters in ipairs({ { first, second, third }, { third, second, first } }) do
            local order = { chapters[1], chapters[2], chapters[3] }
            ChapterListing.chapters, LibraryView.chapters = chapters, chapters
            assert.equals(third, ChapterListing:readContinue())
            assert.equals(third, LibraryView:_handleContinueReading())
            assert.same(order, chapters)
        end
        first.last_read = 400
        assert.equals(first, LibraryView:_handleContinueReading())
    end)

    it("keeps Rakuyomi's fallback when chapters have no timestamps", function()
        Rakuyomi.installResumePatch()
        for _i, chapters in ipairs({ {}, { { id = "1" }, { id = "2" } }, { { read = true }, {} } }) do
            ChapterListing.chapters, LibraryView.chapters = chapters, chapters
            assert.equals(native_find(chapters), ChapterListing:readContinue())
            assert.equals(native_find(chapters), LibraryView:_handleContinueReading())
        end
    end)

    it("updates the live chapter timestamp after a native download opens and preserves its callback", function()
        Rakuyomi.installResumePatch()
        local first = { id = "1", last_read = 100 }
        local third = { id = "3" }
        ChapterListing.chapters = { first, third }
        local callback_arg
        local before = os.time()
        assert.equals("native result", ChapterListing:openChapterOnReader(third, "job", function(value)
            assert.is_true(third.last_read >= before)
            callback_arg = value
        end))
        assert.is_true(third.downloaded)
        assert.equals("job", third.job)
        assert.equals("native return callback", callback_arg)
        assert.equals(third, ChapterListing:readContinue())
    end)

    it("installs once and does not mark cancelled downloads as read", function()
        ChapterListing.openChapterOnReader = function() return "cancelled" end
        Rakuyomi.installResumePatch()
        local patched_find = package.loaded["utils/findLastRead"]
        local patched_open = ChapterListing.openChapterOnReader
        Rakuyomi.installResumePatch()
        assert.equals(patched_find, package.loaded["utils/findLastRead"])
        assert.equals(patched_open, ChapterListing.openChapterOnReader)
        local chapter = { id = "3" }
        assert.equals("cancelled", ChapterListing:openChapterOnReader(chapter))
        assert.is_nil(chapter.last_read)
    end)
end)

describe("Rakuyomi chapter end", function()
    local names = {
        "modules/filebrowser/patches/rakuyomi", "extensions/CbzDocument", "RakuyomiShared",
        "Backend", "ChapterListing", "LibraryView", "chapters/findNextChapter", "ErrorDialog", "ui/uimanager", "ui/trapper",
    }
    local saved, reader_settings, Rakuyomi, ui, backend, listing, next_chapter, queued, shown, errors
    local flushes, local_marks, backend_marks, opens, starts, options
    local path = "/library/chapter.cbz"

    before_each(function()
        saved = {}
        for _i, name in ipairs(names) do
            saved[name] = package.loaded[name]
            ZenSpec.unload(name)
        end
        reader_settings = G_reader_settings
        _G.G_reader_settings = ZenSpec.memorySettings({ end_document_auto_mark = true })
        queued, shown, errors = {}, {}, {}
        flushes, local_marks, backend_marks, opens, starts = 0, 0, 0, 0, 0
        next_chapter = { id = "next", chapter_num = 3, source_id = "source", manga_id = "manga" }
        local current = { id = "current", chapter_num = 2, source_id = "source", manga_id = "manga" }
        listing = {
            chapters = { next_chapter, current },
            openChapterOnReader = function(_self, chapter)
                assert.equals(next_chapter, chapter)
                opens = opens + 1
            end,
        }
        ui = {
            document = { file = path },
            status = { markBook = function(_self, complete)
                assert.is_true(complete)
                local_marks = local_marks + 1
            end },
            doc_settings = { flush = function() flushes = flushes + 1 end },
        }
        backend = {
            getBackend = function() starts = starts + 1 end,
            getInitialized = function() return true end,
            getLogs = function() return "startup failed" end,
            cachedMangaDetails = function()
                error("Chapter navigation must not require cached manga details")
            end,
            getSettings = function()
                return { type = "SUCCESS", body = { chapter_sorting_mode = "descending", preload_chapters = 2 } }
            end,
            markChapterAsRead = function(source_id, manga_id, chapter_id)
                assert.same({ "source", "manga", "current" }, { source_id, manga_id, chapter_id })
                backend_marks = backend_marks + 1
                return { type = "SUCCESS" }
            end,
        }
        ZenSpec.replace("Backend", backend)
        ZenSpec.replace("extensions/CbzDocument", {})
        ZenSpec.replace("RakuyomiShared", { getOrigin = function(_self, file)
            assert.equals(path, file)
            return { chapter_id = "current", manga_id = { source_id = "source", manga_id = "manga" } }
        end })
        ZenSpec.replace("ChapterListing", { new = function(_self, values)
            options = values
            return listing
        end })
        ZenSpec.replace("chapters/findNextChapter", function(chapters, chapter)
            assert.equals(listing.chapters, chapters)
            assert.equals(current, chapter)
            return next_chapter
        end)
        ZenSpec.replace("ErrorDialog", { show = function(_self, message) errors[#errors + 1] = message end })
        ZenSpec.replace("ui/uimanager", {
            nextTick = function(_self, callback) queued[#queued + 1] = callback end,
            show = function(_self, widget) shown[#shown + 1] = widget end,
        })
        ZenSpec.replace("ui/trapper", { wrap = function(_self, callback) callback() end })
        Rakuyomi = require("modules/filebrowser/patches/rakuyomi")
        Rakuyomi.isChapterFile = function(file) return file == path end
    end)

    after_each(function()
        _G.G_reader_settings = reader_settings
        for _i, name in ipairs(names) do package.loaded[name] = saved[name] end
    end)

    it("defers one chapter request and delegates ordering and downloads to Rakuyomi", function()
        assert.is_true(Rakuyomi.onEndOfBook(ui))
        assert.is_true(Rakuyomi.onEndOfBook(ui))
        assert.equals(1, #queued)
        assert.equals(1, flushes)
        assert.equals(1, local_marks)
        assert.equals(0, starts)
        queued[1]()
        assert.equals(1, opens)
        assert.equals(1, backend_marks)
        assert.is_true(listing.chapters[2].read)
        assert.equals("source", options.manga.source.id)
        assert.equals("manga", options.manga.id)
        assert.equals("DefaultViewer", options.manga.viewer)
        assert.is_false(options.manga.state_viewer)
        assert.equals("descending", options.chapter_sorting_mode)
        assert.equals(2, options.preload_count)
        assert.equals(0, #shown)
        assert.equals(0, #errors)
    end)

    it("shows the chapter list when there is no next chapter or the current chapter is missing", function()
        next_chapter = nil
        Rakuyomi.onEndOfBook(ui)
        queued[1]()
        assert.same({ listing }, shown)
        assert.equals(0, opens)
        listing.chapters = {}
        Rakuyomi.onEndOfBook(ui)
        queued[2]()
        assert.same({ listing, listing }, shown)
        assert.equals(1, backend_marks)
    end)

    it("preserves disk chapters when RAM downloads are enabled", function()
        listing.chapters[2].on_tmpfs = false
        backend.getSettings = function()
            return { type = "SUCCESS", body = { ram_storage_enabled = true } }
        end
        backend.revokeChapter = function() error("Disk chapters must not be revoked") end
        Rakuyomi.onEndOfBook(ui)
        queued[1]()
        assert.equals(1, opens)
        assert.equals(0, #errors)
    end)

    it("opens the next chapter even when manga details are not cached", function()
        backend.cachedMangaDetails = function()
            return { type = "ERROR", status = 404, message = "Requested item was not found" }
        end
        assert.is_true(Rakuyomi.onEndOfBook(ui))
        queued[1]()
        assert.equals(1, opens)
        assert.equals(0, #errors)
    end)

    it("returns from the borrowed chapter list to a freshly fetched Rakuyomi library", function()
        local library_options
        ZenSpec.replace("LibraryView", { fetchAndShow = function(_self, playlist, callback, values)
            assert.is_nil(playlist)
            assert.is_nil(callback)
            library_options = values
        end })
        Rakuyomi.onEndOfBook(ui)
        queued[1]()
        assert.is_function(listing.on_return_callback)
        listing.on_return_callback()
        assert.same({ hideTopClose = true, focus_manga_id = "manga", focus_manga_source_id = "source" },
            library_options)
    end)

    it("leaves ordinary comics and unsupported origin metadata to KOReader", function()
        assert.is_false(Rakuyomi.onEndOfBook(nil))
        ui.document.file = "/library/book.cbz"
        assert.is_false(Rakuyomi.onEndOfBook(ui))
        ui.document.file = path
        for _i, shared in ipairs({ {}, { getOrigin = function() return nil end } }) do
            ZenSpec.replace("RakuyomiShared", shared)
            assert.is_false(Rakuyomi.onEndOfBook(ui))
        end
        assert.equals(0, flushes)
        assert.equals(0, #queued)
    end)

    it("preserves KOReader's auto-mark preference", function()
        G_reader_settings:saveSetting("end_document_auto_mark", false)
        assert.is_true(Rakuyomi.onEndOfBook(ui))
        queued[1]()
        assert.equals(0, local_marks)
        assert.equals(1, flushes)
        assert.equals(1, backend_marks)
        assert.equals(1, opens)
    end)

    it("abandons a deferred request when the reader has closed or switched documents", function()
        for _i, document in ipairs({ false, { file = "/library/other.cbz" } }) do
            ui.document = { file = path }
            Rakuyomi.onEndOfBook(ui)
            ui.document = document or nil
            queued[#queued]()
            assert.is_nil(ui._zen_rakuyomi_next_pending)
        end
        assert.equals(0, starts)
        assert.equals(0, opens)
    end)

    it("keeps the current reader open and reports backend failures", function()
        for _i, stage in ipairs({ "getInitialized", "getSettings", "markChapterAsRead" }) do
            local original = backend[stage]
            backend[stage] = function()
                if stage == "getInitialized" then return false end
                return { type = "ERROR", message = stage .. " failed" }
            end
            Rakuyomi.onEndOfBook(ui)
            queued[#queued]()
            assert.equals(path, ui.document.file)
            assert.equals(stage == "getInitialized" and "startup failed" or stage .. " failed", errors[#errors])
            assert.is_nil(ui._zen_rakuyomi_next_pending)
            backend[stage] = original
        end
        assert.equals(0, opens)
        assert.equals(0, #shown)
    end)
end)

describe("Rakuyomi loading dialog cancellation", function()
    local names = { "modules/filebrowser/patches/rakuyomi", "LoadingDialog", "ui/widget/confirmbox" }
    local saved, Rakuyomi, LoadingDialog, BaseConfirmBox, cancels

    before_each(function()
        saved, cancels = {}, 0
        for _i, name in ipairs(names) do saved[name] = package.loaded[name] end
        BaseConfirmBox = { dismissable = true }
        function BaseConfirmBox:extend(values) return setmetatable(values, { __index = self }) end
        function BaseConfirmBox:new(values)
            local dialog = self:extend(values)
            if dialog.dismissable then dialog.tap_outside = dialog.cancel_callback end
            dialog.cancel_button = dialog.cancel_callback
            return dialog
        end
        local function native_dialogs()
            local ConfirmBox = BaseConfirmBox
            local function options()
                return {
                    no_ok_button = true,
                    cancel_callback = function() cancels = cancels + 1 end,
                }
            end
            return {
                showAndRun = function() return ConfirmBox:new(options()) end,
                showAndRunWithProgress = function()
                    local function create_dialog() return ConfirmBox:new(options()) end
                    return create_dialog(), create_dialog()
                end,
                simple = function() return ConfirmBox:new(options()) end,
            }
        end
        LoadingDialog = native_dialogs()
        ZenSpec.replace("LoadingDialog", LoadingDialog)
        ZenSpec.replace("ui/widget/confirmbox", BaseConfirmBox)
        ZenSpec.unload("modules/filebrowser/patches/rakuyomi")
        Rakuyomi = require("modules/filebrowser/patches/rakuyomi")
    end)

    after_each(function()
        for _i, name in ipairs(names) do package.loaded[name] = saved[name] end
    end)

    it("ignores outside taps while preserving Cancel on downloads and progress rebuilds", function()
        Rakuyomi.installLoadingDialogPatch()
        local progress, rebuilt = LoadingDialog:showAndRunWithProgress()
        for _i, dialog in ipairs({ LoadingDialog:showAndRun(), progress, rebuilt, LoadingDialog:simple() }) do
            assert.is_false(dialog.dismissable)
            if dialog.tap_outside then dialog.tap_outside() end
            assert.equals(_i - 1, cancels)
            dialog.cancel_button()
            assert.equals(_i, cancels)
        end
    end)

    it("preserves ordinary confirmations and installs only once", function()
        Rakuyomi.installLoadingDialogPatch()
        Rakuyomi.installLoadingDialogPatch()
        assert.is_false(LoadingDialog:showAndRun().dismissable)
        assert.is_true(BaseConfirmBox:new{}.dismissable)
    end)
end)

describe("Rakuyomi RAM chapter transitions", function()
    local names = { "modules/filebrowser/patches/rakuyomi", "ChapterListing", "MangaReader", "Backend",
        "RakuyomiShared", "apps/reader/readerui", "ui/uimanager", "ui/trapper", "datastorage", "util", "ErrorDialog",
        "LoadingDialog", "gettext+" }
    local saved, Rakuyomi, ChapterListing, MangaReader, ReaderUI, Backend, reader, queued, shown, errors, events, listing
    local closed, notice, native_ends, filemanager_available
    local current, next_chapter, open_handle, archive_present, origin_present, cancelled
    local file = "/data/custom/tmpfs/current.cbz"

    local function drain()
        while #queued > 0 do table.remove(queued, 1)() end
    end

    before_each(function()
        saved = {}
        for _i, name in ipairs(names) do saved[name] = package.loaded[name] end
        queued, shown, errors, events = {}, {}, {}, {}
        closed, notice, native_ends, filemanager_available = {}, { name = "loading_notice" }, 0, false
        open_handle, archive_present, origin_present, cancelled = true, true, true, false
        current = { id = "current", source_id = "source", manga_id = "series", on_tmpfs = false, file = file }
        next_chapter = { id = "next", source_id = "source", manga_id = "series" }
        reader = { document = { file = file } }
        ReaderUI = { instance = reader }
        MangaReader = {
            is_showing = true, chapter = current,
            onEndOfBook = function() native_ends = native_ends + 1; return "native end" end,
            closeReaderUi = function(self, callback)
                queued[#queued + 1] = function()
                    assert.same({ notice }, shown)
                    assert.same({}, closed)
                    assert.same({ "notice" }, events)
                    events[#events + 1] = "close"
                    open_handle = false
                    reader.document, ReaderUI.instance = nil, nil
                    filemanager_available = true
                    callback()
                    self.is_showing, self.chapter = false, nil
                    events[#events + 1] = "clean"
                end
            end,
        }
        Backend = { revokeChapter = function(source, manga, id, ram)
            assert.same({ "source", "series", "current", true }, { source, manga, id, ram })
            assert.is_false(open_handle)
            assert.same({}, closed)
            events[#events + 1] = "revoke"
            archive_present = false
            return { type = "SUCCESS" }
        end }
        ChapterListing = { openChapterOnReader = function(self, chapter, job, on_opened)
            events[#events + 1] = "download"
            if archive_present or open_handle then error("No space left on device") end
            if cancelled then return end
            assert.same({ next_chapter, "job" }, { chapter, job })
            assert.same({ notice }, shown)
            assert.same({ notice }, closed)
            assert.is_false(self.chapters[1].on_tmpfs)
            assert.is_false(self.chapters[1].downloaded)
            assert.is_nil(self.chapters[1].file)
            MangaReader.is_showing, MangaReader.chapter = true, chapter
            if on_opened then on_opened("native callback") end
            return "native open"
        end }
        listing = setmetatable({ chapters = { current, next_chapter }, preload_jobs = { current = "completed job" },
            updateItems = function(self)
                assert.is_false(archive_present)
                assert.is_nil(self.preload_jobs.current)
                assert.is_false(current.downloaded)
            end,
        }, { __index = ChapterListing })
        ZenSpec.replace("ChapterListing", ChapterListing)
        ZenSpec.replace("MangaReader", MangaReader)
        ZenSpec.replace("Backend", Backend)
        ZenSpec.replace("apps/reader/readerui", ReaderUI)
        ZenSpec.replace("RakuyomiShared", { getOrigin = function(_self, path)
            assert.equals(file, path)
            if origin_present then
                return { chapter_id = "current", manga_id = { source_id = "source", manga_id = "series" } }
            end
        end })
        ZenSpec.replace("ui/uimanager", {
            nextTick = function(_self, callback) queued[#queued + 1] = callback end,
            show = function(_self, widget) shown[#shown + 1] = widget end,
            close = function(_self, widget) closed[#closed + 1] = widget end,
            forceRePaint = function() events[#events + 1] = "notice" end,
        })
        ZenSpec.replace("LoadingDialog", { simple = function(_self, message)
            assert.equals("Loading next chapter...", message)
            assert.is_true(open_handle)
            assert.equals(reader, ReaderUI.instance)
            require("ui/uimanager"):show(notice)
            return notice
        end })
        ZenSpec.replace("gettext+", function(message) return message end)
        ZenSpec.replace("ui/trapper", { wrap = function(_self, callback) callback() end })
        ZenSpec.replace("datastorage", { getFullDataDir = function() return "/data" end })
        ZenSpec.replace("util", { readFromFile = function() return '{"storage_path":"custom/downloads"}' end })
        ZenSpec.replace("ErrorDialog", { show = function(_self, message) errors[#errors + 1] = message end })
        ZenSpec.unload("modules/filebrowser/patches/rakuyomi")
        Rakuyomi = require("modules/filebrowser/patches/rakuyomi")
        Rakuyomi.installChapterOpenPatch()
    end)

    after_each(function()
        for _i, name in ipairs(names) do package.loaded[name] = saved[name] end
    end)

    it("recognizes tmpfs chapter paths without reading archives or trusting chapter flags", function()
        for _i, path in ipairs({ file, "/data/custom/tmpfs/novel.epub", "/data/custom/tmpfs/missing.cbz" }) do
            assert.is_true(Rakuyomi.isTmpfsChapterFile(path))
        end
        for _i, path in ipairs({ false, "", "/data/custom/downloads/current.cbz", "/data/custom/tmpfs-copy/book.cbz",
                "/library/tmpfs/book.cbz", "/data/custom/tmpfs", "/data/custom/tmpfs/book.sdr/metadata.cbz.lua" }) do
            assert.is_false(Rakuyomi.isTmpfsChapterFile(path))
        end
    end)

    it("recognizes Rakuyomi's default tmpfs directory when storage is not customized", function()
        require("util").readFromFile = function() end
        assert.is_true(Rakuyomi.isTmpfsChapterFile("/data/rakuyomi/tmpfs/chapter.cbz"))
        assert.is_false(Rakuyomi.isTmpfsChapterFile(file))
        assert.is_false(Rakuyomi.isTmpfsChapterFile("/data/rakuyomi/downloads/chapter.cbz"))
    end)

    it("shows the next-chapter notice before closing RAM handles, cleanup, and download", function()
        local callback
        listing:openChapterOnReader(next_chapter, "job", function(value) callback = value end)
        assert.same({}, events)
        assert.equals(1, #queued)
        listing:openChapterOnReader(next_chapter, "job")
        assert.equals(1, #queued)
        table.remove(queued, 1)()
        assert.same({ "notice" }, events)
        listing:openChapterOnReader(next_chapter, "job")
        assert.equals(1, #queued)
        drain()
        assert.same({ "notice", "close", "clean", "revoke", "download" }, events)
        assert.equals("native callback", callback)
        assert.equals(next_chapter, MangaReader.chapter)
        assert.is_true(MangaReader.is_showing)
        assert.is_nil(Rakuyomi._chapter_handoff_pending)
    end)

    it("handles native next-chapter callbacks that already unlinked the current archive", function()
        archive_present, origin_present = false, false
        listing:openChapterOnReader(next_chapter, "job")
        drain()
        assert.same({ "notice", "close", "clean", "revoke", "download" }, events)
    end)

    it("also releases RAM for previous and manually selected chapters", function()
        next_chapter.id = "previous-or-selected"
        listing:openChapterOnReader(next_chapter, "job")
        drain()
        assert.equals("download", events[#events])
    end)

    it("keeps the file manager available when a download is cancelled", function()
        cancelled = true
        listing:openChapterOnReader(next_chapter, "job")
        drain()
        assert.same({ notice }, shown)
        assert.same({ notice }, closed)
        assert.is_true(filemanager_available)
        assert.is_false(MangaReader.is_showing)
        assert.is_nil(ReaderUI.instance)
    end)

    it("reports cleanup errors without starting another download", function()
        Backend.revokeChapter = function() return { type = "ERROR", message = "cleanup failed" } end
        listing:openChapterOnReader(next_chapter, "job")
        drain()
        assert.same({ "notice", "close", "clean" }, events)
        assert.same({ "cleanup failed" }, errors)
        assert.same({ notice }, shown)
        assert.same({ notice }, closed)
        assert.is_true(filemanager_available)
    end)

    it("routes Rakuyomi's priority end-of-book event through Zen", function()
        local handled = 0
        Rakuyomi.onEndOfBook = function(ui)
            assert.equals(reader, ui)
            handled = handled + 1
            listing:openChapterOnReader(next_chapter, "job")
            return true
        end
        assert.is_true(MangaReader:onEndOfBook())
        drain()
        assert.equals(1, handled)
        assert.equals(0, native_ends)
        assert.same({ "notice", "close", "clean", "revoke", "download" }, events)
    end)

    it("preserves native end-of-book handling when Zen cannot handle the document", function()
        Rakuyomi.onEndOfBook = function() return false end
        assert.equals("native end", MangaReader:onEndOfBook())
        assert.equals(1, native_ends)
        assert.equals(0, #queued)
    end)

    it("preserves native end-of-book handling for disk chapters", function()
        reader.document.file = "/data/custom/downloads/current.cbz"
        Rakuyomi.onEndOfBook = function() error("Disk chapters must retain their native handler") end
        assert.equals("native end", MangaReader:onEndOfBook())
        assert.equals(1, native_ends)
        assert.equals(0, #queued)
    end)

    it("abandons transitions if the reader closed or switched before the deferred close", function()
        listing:openChapterOnReader(next_chapter, "job")
        reader.document = { file = "/library/other.cbz" }
        drain()
        assert.same({}, events)
        assert.is_nil(reader._zen_rakuyomi_open_pending)
    end)

    it("preserves the native open path for disk chapters, the current chapter, and no reader", function()
        local opened = 0
        -- Reinstall over a simpler native function to assert delegation without the RAM-only contract.
        ChapterListing.openChapterOnReader = function() opened = opened + 1; return "native" end
        Rakuyomi._chapter_open_patched = nil
        Rakuyomi.installChapterOpenPatch()
        reader.document.file = "/data/custom/downloads/current.cbz"
        assert.equals("native", listing:openChapterOnReader(next_chapter))
        reader.document.file = file
        assert.equals("native", listing:openChapterOnReader(current))
        ReaderUI.instance = nil
        assert.equals("native", listing:openChapterOnReader(next_chapter))
        assert.equals(3, opened)
        assert.equals(0, #queued)
        local open = ChapterListing.openChapterOnReader
        Rakuyomi.installChapterOpenPatch()
        assert.equals(open, ChapterListing.openChapterOnReader)
    end)
end)
