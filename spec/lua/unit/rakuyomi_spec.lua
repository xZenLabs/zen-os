describe("Rakuyomi availability", function()
    local original_filemanager
    local original_bookinfomanager
    local original_documentregistry
    local original_cbz_document

    before_each(function()
        original_filemanager = package.loaded["apps/filemanager/filemanager"]
        original_bookinfomanager = package.loaded.bookinfomanager
        original_documentregistry = package.loaded["document/documentregistry"]
        original_cbz_document = package.loaded["extensions/CbzDocument"]
        ZenSpec.unload("modules/filebrowser/patches/rakuyomi")
    end)

    after_each(function()
        package.loaded["apps/filemanager/filemanager"] = original_filemanager
        package.loaded.bookinfomanager = original_bookinfomanager
        package.loaded["document/documentregistry"] = original_documentregistry
        package.loaded["extensions/CbzDocument"] = original_cbz_document
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
