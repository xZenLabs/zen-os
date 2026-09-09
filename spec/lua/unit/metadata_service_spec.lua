describe("metadata service", function()
    local Service
    local lfs = require("libs/libkoreader-lfs")
    local saved = {}
    local test_root
    local dependencies = {
        "apps/reader/readerui", "bookinfomanager", "common/cover_utils", "device",
        "docsettings", "ffi/util", "modules/filebrowser/metadata/epub",
        "ui/event", "ui/uimanager",
    }

    setup(function()
        Service = require("modules/filebrowser/metadata/service")
    end)

    local function remove_tree(path)
        local attr = lfs.symlinkattributes(path)
        if not attr then return end
        if attr.mode ~= "directory" then os.remove(path) return end
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then remove_tree(path .. "/" .. entry) end
        end
        lfs.rmdir(path)
    end

    local function mock_docsettings(stored, with_file, root)
        local directory = (root or test_root) .. "/book.sdr"
        assert.is_true(lfs.mkdir(directory))
        local target = directory .. "/custom_metadata.lua"
        if with_file then
            local file = assert(io.open(target, "wb"))
            assert(file:write("return {}\n"))
            file:close()
        end
        local settings = {
            data = stored,
            sidecar_file = with_file and target or nil,
            readSetting = function(self, key, fallback)
                return self.data[key] == nil and fallback or self.data[key]
            end,
            saveSetting = function(self, key, value) self.data[key] = value end,
            getCustomLocationCandidates = function() return { directory } end,
        }
        ZenSpec.replace("docsettings", {
            findCustomMetadataFile = function()
                return lfs.attributes(target, "mode") == "file" and target or nil
            end,
            openSettingsFile = function(_path)
                settings.sidecar_file = lfs.attributes(target, "mode") == "file"
                    and target or nil
                return settings
            end,
        })
        return settings, target
    end

    before_each(function()
        for _i, name in ipairs(dependencies) do saved[name] = package.loaded[name] or false end
        test_root = os.tmpname()
        os.remove(test_root)
        assert.is_true(lfs.mkdir(test_root))
    end)

    after_each(function()
        rawset(_G, "zen_metadata_injected", nil)
        for name, module in pairs(saved) do package.loaded[name] = module or nil end
        saved = {}
        remove_tree(test_root)
    end)

    it("normalizes scalar and list metadata", function()
        local draft = Service.normalize({
            title = "  A Book  ",
            authors = "Ada\r\nBob\n",
            series = "  Saga ",
            series_index = 2,
            keywords = { " Fantasy ", "", "Adventure" },
            language = " en ",
        })
        assert.same("A Book", draft.title)
        assert.same({ "Ada", "Bob" }, draft.authors)
        assert.same("Saga", draft.series_name)
        assert.same("2", draft.series_index)
        assert.same({ "Fantasy", "Adventure" }, draft.genres)
        assert.same("en", draft.language)
    end)

    it("validates EPUB-required fields and numeric series positions", function()
        local base = { title = "Book", language = "en", series_index = "1.5" }
        assert.is_table(Service.validate("book.epub", base))
        assert.same("missing_title", select(2,
            Service.validate("book.epub", { language = "en" })))
        assert.same("missing_language", select(2,
            Service.validate("book.epub", { title = "Book" })))
        assert.same("invalid_series_index", select(2,
            Service.validate("book.pdf", { series_index = "second" })))
    end)

    it("recognizes EPUB suffixes case-insensitively", function()
        assert.is_true(Service.isEpub("book.EPUB"))
        assert.is_false(Service.isEpub("book.pdf"))
    end)

    it("moves a restorable EPUB backup with a filename change", function()
        local source = test_root .. "/old.epub"
        local destination = test_root .. "/new.epub"
        local backup = assert(io.open(source .. ".zen-metadata.bak", "wb"))
        assert(backup:write("backup"))
        backup:close()
        local snapshot = assert(io.open(source .. ".zen-metadata.bak.json", "wb"))
        assert(snapshot:write("{}"))
        snapshot:close()

        local ok, moved = Service.moveEpubBackup(source, destination)

        assert.is_true(ok)
        assert.is_true(moved)
        assert.is_nil(lfs.symlinkattributes(source .. ".zen-metadata.bak"))
        assert.are.equal("file", lfs.attributes(destination .. ".zen-metadata.bak", "mode"))
        assert.are.equal("file", lfs.attributes(destination .. ".zen-metadata.bak.json", "mode"))
    end)

    it("refuses to edit the open book through a path alias", function()
        local file = test_root .. "/book.epub"
        local source = assert(io.open(file, "wb"))
        assert(source:write("fixture"))
        source:close()
        ZenSpec.replace("apps/reader/readerui", {
            instance = { document = { file = test_root .. "/alias.epub" } },
        })
        ZenSpec.replace("ffi/util", {
            realpath = function() return file end,
        })

        local draft, err = Service.load(file)
        assert.is_nil(draft)
        assert.are.equal("open_book", err)
    end)

    it("writes one sidecar while preserving unrelated overrides and empty clears", function()
        local stored = {
            custom_props = { unrelated = "keep" },
            doc_props = { title = "Original", authors = "Ada", language = "en" },
        }
        local cached = {
            title = "Original", authors = "Ada", language = "en",
            pages = 12, directory = "/books/", filename = "book.pdf",
            has_meta = "Y",
        }
        local events = {}
        local target = select(2, mock_docsettings(stored, true))
        ZenSpec.replace("apps/reader/readerui", { instance = nil })
        ZenSpec.replace("bookinfomanager", {
            getBookInfo = function() return cached end,
            setBookInfoProperties = function(_self, _file, props)
                for key, value in pairs(props) do
                    cached[key] = value == false and nil or value
                end
            end,
        })
        ZenSpec.replace("ui/event", { new = function(_self, name) return name end })
        ZenSpec.replace("ui/uimanager", {
            broadcastEvent = function(_self, event) events[#events + 1] = event end,
        })

        assert.is_true(Service.save("/books/book.pdf", {
            title = "",
            authors = { "Ada", "Bob" },
            language = "en",
        }))
        assert.same("", stored.custom_props.title)
        assert.same("Ada\nBob", stored.custom_props.authors)
        assert.same("keep", stored.custom_props.unrelated)
        assert.is_nil(stored.custom_props.language)
        local saved_sidecar = assert(dofile(target))
        assert.same("", saved_sidecar.custom_props.title)
        assert.same("keep", saved_sidecar.custom_props.unrelated)
        assert.same("", cached.title)
        assert.same("Ada\nBob", cached.authors)
        assert.same("Y", cached.has_meta)
        assert.is_false(cached.ignore_meta)
        assert.same({ "BookMetadataChanged" }, events)
        assert.is_nil(lfs.attributes(target .. ".zen-metadata.new"))
        assert.is_nil(lfs.attributes(target .. ".zen-metadata.old"))
    end)

    it("creates a missing book-info row before applying PDF overrides", function()
        local cached
        local extracted = 0
        local events = {}
        ZenSpec.replace("bookinfomanager", {
            getBookInfo = function() return cached end,
            extractBookInfo = function()
                extracted = extracted + 1
                cached = { in_progress = 0, unsupported = "not readable" }
                return false
            end,
            setBookInfoProperties = function(_self, _file, props)
                if not cached then return end
                for key, value in pairs(props) do
                    cached[key] = value == false and nil or value
                end
            end,
        })
        ZenSpec.replace("ui/event", { new = function(_self, name) return name end })
        ZenSpec.replace("ui/uimanager", {
            broadcastEvent = function(_self, event) events[#events + 1] = event end,
        })

        Service.invalidate("/books/xflate.pdf", {
            title = "Custom PDF title",
            authors = "Custom Author",
        })

        assert.are.equal(1, extracted)
        assert.are.equal("Custom PDF title", cached.title)
        assert.are.equal("Custom Author", cached.authors)
        assert.same({ "BookMetadataChanged" }, events)
    end)

    it("syncs every newly created sidecar ancestor before committing", function()
        local file = test_root .. "/book.pdf"
        local source = assert(io.open(file, "wb"))
        assert(source:write("%PDF fixture"))
        source:close()
        local directory = test_root .. "/metadata/aa/book.sdr"
        local target = directory .. "/custom_metadata.lua"
        local settings = {
            data = {},
            readSetting = function(self, key, fallback)
                return self.data[key] == nil and fallback or self.data[key]
            end,
            saveSetting = function(self, key, value) self.data[key] = value end,
            getCustomLocationCandidates = function() return { directory } end,
        }
        ZenSpec.replace("docsettings", {
            findCustomMetadataFile = function() return nil end,
            getSidecarDir = function() return directory end,
            openSettingsFile = function() return settings end,
        })
        ZenSpec.replace("apps/reader/readerui", { instance = nil })
        ZenSpec.replace("bookinfomanager", {
            getBookInfo = function()
                return {
                    title = "Original", pages = 12,
                    directory = "/books/", filename = "book.pdf",
                }
            end,
        })
        ZenSpec.replace("ui/event", { new = function(_self, name) return name end })
        ZenSpec.replace("ui/uimanager", { broadcastEvent = function() end })
        local actual_ffiutil = require("ffi/util")
        local synced = {}
        ZenSpec.replace("ffi/util", {
            dirname = actual_ffiutil.dirname,
            fsyncOpenedFile = actual_ffiutil.fsyncOpenedFile,
            fsyncDirectory = function(path)
                synced[path] = true
                return actual_ffiutil.fsyncDirectory(path)
            end,
        })

        assert.is_true(Service.save(file, { title = "Changed" }))
        assert.is_true(synced[test_root])
        assert.is_true(synced[test_root .. "/metadata"])
        assert.is_true(synced[test_root .. "/metadata/aa"])
        assert.is_true(synced[directory])
        local saved_sidecar = assert(dofile(target))
        assert.are.equal("Changed", saved_sidecar.custom_props.title)
        assert.are.equal(12, saved_sidecar.doc_props.pages)
        assert.is_nil(saved_sidecar.doc_props.directory)
    end)

    it("does not execute newline characters from a sidecar path", function()
        local malicious_root = test_root
            .. "/safe\nrawset(_G, \"zen_metadata_injected\", true)\n--"
        assert.is_true(lfs.mkdir(malicious_root))
        local stored = { doc_props = { title = "Original" } }
        local target = select(2, mock_docsettings(stored, false, malicious_root))
        ZenSpec.replace("apps/reader/readerui", { instance = nil })
        ZenSpec.replace("bookinfomanager", {
            getBookInfo = function() return { title = "Original" } end,
        })
        ZenSpec.replace("ui/event", { new = function(_self, name) return name end })
        ZenSpec.replace("ui/uimanager", { broadcastEvent = function() end })

        assert.is_true(Service.save("/books/book.pdf", { title = "Changed" }))
        assert.is_nil(rawget(_G, "zen_metadata_injected"))
        assert.are.equal("Changed", assert(dofile(target)).custom_props.title)
    end)

    it("recovers an interrupted sidecar from a previous metadata location", function()
        local file = test_root .. "/book.pdf"
        local source = assert(io.open(file, "wb"))
        assert(source:write("%PDF fixture"))
        source:close()
        local current_dir = test_root .. "/current.sdr"
        local previous_dir = test_root .. "/previous.sdr"
        assert.is_true(lfs.mkdir(current_dir))
        assert.is_true(lfs.mkdir(previous_dir))
        local target = previous_dir .. "/custom_metadata.lua"
        local old = assert(io.open(target .. ".zen-metadata.old", "wb"))
        assert(old:write("return { custom_props = { title = \"Recovered\" }, "
            .. "doc_props = { title = \"Original\" } }\n"))
        old:close()

        ZenSpec.replace("apps/reader/readerui", { instance = nil })
        ZenSpec.replace("docsettings", {
            findCustomMetadataFile = function()
                return lfs.attributes(target, "mode") == "file" and target or nil
            end,
            getSidecarDir = function(_self, _file, location)
                return location == "doc" and previous_dir or current_dir
            end,
            openSettingsFile = function(path)
                local data = path and dofile(path) or {}
                return {
                    data = data,
                    sidecar_file = path,
                    readSetting = function(self, key, fallback)
                        return self.data[key] == nil and fallback or self.data[key]
                    end,
                    getCustomLocationCandidates = function()
                        return { current_dir }
                    end,
                }
            end,
        })

        local draft = assert(Service.load(file))
        assert.are.equal("Recovered", draft.title)
        assert.are.equal("file", lfs.attributes(target, "mode"))
        assert.is_nil(lfs.attributes(target .. ".zen-metadata.old"))
    end)

    it("keeps ISBN lookup-only when embedding EPUB metadata", function()
        local written
        ZenSpec.replace("apps/reader/readerui", { instance = nil })
        mock_docsettings({}, false)
        ZenSpec.replace("modules/filebrowser/metadata/epub", {
            read = function()
                return { title = "Original", language = "en", isbn = "9780441013593" }
            end,
            write = function(_file, draft, options)
                written = draft
                if options.after_replace then
                    assert.is_true(options.after_replace({
                        title = "Changed",
                        authors = {},
                        genres = {},
                        language = "en",
                    }))
                end
                return true
            end,
        })
        ZenSpec.replace("bookinfomanager", {
            deleteBookInfo = function() end,
        })
        ZenSpec.replace("ui/event", { new = function(_self, name) return name end })
        ZenSpec.replace("ui/uimanager", { broadcastEvent = function() end })

        assert.is_true(Service.save("/books/book.epub", {
            title = "Changed",
            language = "en",
            isbn = "9780441013593",
        }))
        assert.are.equal("Changed", written.title)
        assert.is_nil(written.isbn)
    end)

    it("drops KOReader's stale hash cache after an EPUB replacement", function()
        local file = test_root .. "/book.epub"
        local source = assert(io.open(file, "wb"))
        assert(source:write("old EPUB bytes"))
        source:close()
        local storage = test_root .. "/hashdocsettings"
        assert.is_true(lfs.mkdir(storage))
        local doc_hash_cache = {}
        local settings = {
            data = {},
            readSetting = function(self, key, fallback)
                return self.data[key] == nil and fallback or self.data[key]
            end,
            getCustomLocationCandidates = function() return {} end,
        }
        local DocSettings = {
            getSidecarStorage = function(location)
                return location == "hash" and storage or nil
            end,
            getSidecarDir = function(_self, book, location)
                if location ~= "hash" then
                    return (book:match("(.*)%.") or book) .. ".sdr"
                end
                local hash = doc_hash_cache[book]
                if not hash then
                    hash = assert(require("util").partialMD5(book))
                    doc_hash_cache[book] = hash
                end
                return storage .. "/" .. hash:sub(1, 2) .. "/" .. hash .. ".sdr"
            end,
            findCustomMetadataFile = function() return nil end,
            openSettingsFile = function() return settings end,
        }
        ZenSpec.replace("docsettings", DocSettings)
        ZenSpec.replace("apps/reader/readerui", { instance = nil })
        ZenSpec.replace("modules/filebrowser/metadata/epub", {
            read = function()
                return { title = "Original", authors = {}, genres = {}, language = "en" }
            end,
            write = function(_file, _draft, _options)
                local output = assert(io.open(file, "wb"))
                assert(output:write("new and different EPUB bytes"))
                output:close()
                return true
            end,
        })
        ZenSpec.replace("bookinfomanager", { deleteBookInfo = function() end })
        ZenSpec.replace("ui/event", { new = function(_self, name) return name end })
        ZenSpec.replace("ui/uimanager", { broadcastEvent = function() end })

        local old_dir = DocSettings:getSidecarDir(file, "hash")
        assert.is_true(Service.save(file, { title = "Changed", language = "en" }))
        local new_dir = DocSettings:getSidecarDir(file, "hash")
        assert.are_not.equal(old_dir, new_dir)
        local hash = assert(require("util").partialMD5(file))
        assert.matches("/" .. hash:sub(1, 2) .. "/" .. hash .. "%.sdr$", new_dir)
    end)

    it("refreshes embedded sidecar bases while preserving unrelated properties", function()
        local stored = {
            custom_props = { title = "Old override", unrelated = "keep" },
            doc_props = { title = "Old embedded", pages = 321, unrelated_base = "keep" },
        }
        mock_docsettings(stored, true)
        ZenSpec.replace("apps/reader/readerui", { instance = nil })
        ZenSpec.replace("modules/filebrowser/metadata/epub", {
            read = function()
                return { title = "Old embedded", language = "en", publisher = "Old House" }
            end,
            write = function(_file, _draft, options)
                local prepared = options.prepare_sidecar({
                    title = "New embedded",
                    authors = {},
                    genres = {},
                    language = "fr",
                    publisher = "New House",
                })
                assert.is_true(prepared)
                return true
            end,
        })
        ZenSpec.replace("bookinfomanager", { deleteBookInfo = function() end })
        ZenSpec.replace("ui/event", { new = function(_self, name) return name end })
        ZenSpec.replace("ui/uimanager", { broadcastEvent = function() end })

        assert.is_true(Service.save("/books/book.epub", {
            title = "New embedded",
            language = "fr",
            publisher = "New House",
        }))
        assert.is_nil(stored.custom_props.title)
        assert.are.equal("keep", stored.custom_props.unrelated)
        assert.are.equal("New embedded", stored.doc_props.title)
        assert.are.equal("fr", stored.doc_props.language)
        assert.are.equal("New House", stored.doc_props.publisher)
        assert.are.equal(321, stored.doc_props.pages)
        assert.are.equal("keep", stored.doc_props.unrelated_base)
    end)

    it("does not rewrite untouched EPUB description markup", function()
        local raw_description = "<p>Original <b>markup</b>.</p>"
        local displayed = Service.normalize({ description = raw_description }).description
        local written
        ZenSpec.replace("apps/reader/readerui", { instance = nil })
        mock_docsettings({}, false)
        ZenSpec.replace("modules/filebrowser/metadata/epub", {
            read = function()
                return {
                    title = "Original",
                    authors = { "Ada" },
                    genres = {},
                    language = "en",
                    description = raw_description,
                }
            end,
            write = function(_file, draft, options)
                written = draft
                assert.is_true(options.prepare_sidecar({
                    title = "Changed",
                    authors = { "Ada" },
                    genres = {},
                    language = "en",
                    description = raw_description,
                }))
                return true
            end,
        })
        ZenSpec.replace("bookinfomanager", { deleteBookInfo = function() end })
        ZenSpec.replace("ui/event", { new = function(_self, name) return name end })
        ZenSpec.replace("ui/uimanager", { broadcastEvent = function() end })

        assert.is_true(Service.save("/books/book.epub", {
            title = "Changed",
            authors = { "Ada" },
            genres = {},
            language = "en",
            description = displayed,
        }))
        assert.are.equal("Changed", written.title)
        assert.is_nil(written.description)
    end)

    it("embeds an untouched custom description without stripping its markup", function()
        local raw_description = "<p>Plain</p>"
        local stored = {
            custom_props = { description = raw_description },
            doc_props = { title = "Original", language = "en", description = "Plain" },
        }
        mock_docsettings(stored, true)
        local written
        ZenSpec.replace("apps/reader/readerui", { instance = nil })
        ZenSpec.replace("modules/filebrowser/metadata/epub", {
            read = function()
                return { title = "Original", language = "en", description = "Plain" }
            end,
            write = function(_file, draft, options)
                written = draft
                assert.is_true(options.prepare_sidecar({
                    title = "Changed",
                    authors = {},
                    genres = {},
                    language = "en",
                    description = raw_description,
                }))
                return true
            end,
        })
        ZenSpec.replace("bookinfomanager", { deleteBookInfo = function() end })
        ZenSpec.replace("ui/event", { new = function(_self, name) return name end })
        ZenSpec.replace("ui/uimanager", { broadcastEvent = function() end })

        assert.is_true(Service.save("/books/book.epub", {
            title = "Changed",
            language = "en",
            description = Service.normalize({ description = raw_description }).description,
        }))
        assert.are.equal(raw_description, written.description)
    end)

    it("swaps the current sidecar snapshot when restoring an EPUB", function()
        local stored = {
            custom_props = { title = "Current override", unrelated = "keep" },
            doc_props = { title = "Current embedded", language = "en" },
        }
        mock_docsettings(stored, true)
        local read_count = 0
        local restore_options
        ZenSpec.replace("apps/reader/readerui", { instance = nil })
        ZenSpec.replace("modules/filebrowser/metadata/epub", {
            read = function()
                read_count = read_count + 1
                return read_count == 1
                    and { title = "Current embedded", language = "en" }
                    or { title = "Prior embedded", language = "en" }
            end,
            restore = function(_file, options)
                restore_options = options
                local snapshot = {
                    props = {
                        title = { present = true, value = "Prior override" },
                    },
                    doc_props = { title = "Prior embedded", language = "en" },
                }
                local ok, err = options.prepare_sidecar({
                    title = "Prior embedded",
                    language = "en",
                }, snapshot)
                if not ok then return nil, err end
                return snapshot
            end,
        })
        ZenSpec.replace("bookinfomanager", { deleteBookInfo = function() end })
        ZenSpec.replace("ui/event", { new = function(_self, name) return name end })
        ZenSpec.replace("ui/uimanager", { broadcastEvent = function() end })

        assert.is_true(Service.restore("/books/book.epub"))
        assert.is_true(restore_options.sidecar_snapshot.props.title.present)
        assert.are.equal("Current override",
            restore_options.sidecar_snapshot.props.title.value)
        assert.are.equal("Prior override", stored.custom_props.title)
        assert.are.equal("keep", stored.custom_props.unrelated)
        assert.are.equal("Prior embedded", stored.doc_props.title)
    end)

    it("rebuilds missing book details before refreshing the library", function()
        local extracted
        ZenSpec.replace("device", { screen = { getHeight = function() return 800 end } })
        ZenSpec.replace("common/cover_utils", { getRatio = function() return 2 / 3 end })
        ZenSpec.replace("bookinfomanager", {
            getBookInfo = function() return nil end,
            extractBookInfo = function(_self, file, cover_specs)
                extracted = { file = file, cover_specs = cover_specs }
                return true
            end,
        })
        local changed
        local chooser = {
            path = "/books",
            changeToPath = function(_self, path)
                assert.is_table(extracted)
                changed = path
            end,
        }

        Service.refreshLibrary({ file_chooser = chooser }, "/books/book.epub")

        assert.are.equal("/books/book.epub", extracted.file)
        assert.is_true(extracted.cover_specs.max_cover_w > 0)
        assert.is_true(extracted.cover_specs.max_cover_h > 0)
        assert.are.equal("/books", changed)
    end)
end)
