describe("home data and book caches", function()
    local doc_open_count
    local history_reload_count
    local status_lookup_count
    local stable_contexts
    local favorite_lookup_count
    local history_items
    local book_info_reads
    local stats_query_count
    local top_menu_count

    before_each(function()
        _G.__ZEN_UI_LAST_READ_FILE = nil
        doc_open_count = 0
        history_reload_count = 0
        status_lookup_count = 0
        stable_contexts = {}
        favorite_lookup_count = 0
        book_info_reads = 0
        stats_query_count = 0
        top_menu_count = 0
        history_items = { { file = "/library/alpha.epub" } }

        ZenSpec.replace("config/manager", { get = function() return {} end })
        ZenSpec.replace("ffi/blitbuffer", { COLOR_WHITE = "white", COLOR_BLACK = "black" })
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 900 end,
            },
        })
        ZenSpec.replace("apps/filemanager/filemanager", {
            instance = {
                menu = {
                    onShowMenu = function()
                        top_menu_count = top_menu_count + 1
                        return true
                    end,
                },
            },
        })
        ZenSpec.replace("ui/uimanager", {
            nextTick = function(_self, callback) callback() end,
            scheduleIn = function() end,
        })
        ZenSpec.replace("modules/filebrowser/patches/home/home_quotes", {})
        ZenSpec.replace("modules/filebrowser/patches/home/home_presets", {
            featuredSourceKey = function(source)
                local kind = type(source) == "table" and source.kind or source
                if kind == "custom" then return "custom_featured" end
                if kind == "to_be_read" then return "to_be_read" end
                return "recently_read"
            end,
        })
        ZenSpec.replace("common/reading_goals", {})
        ZenSpec.replace("common/db_stats", {
            queryHomeStats = function()
                stats_query_count = stats_query_count + 1
                return { today_pages = 12 }
            end,
        })
        ZenSpec.replace("config/preset_store", {})
        ZenSpec.replace("modules/filebrowser/patches/home/components/registry", {
            get = function(id) return { id = id } end,
            list = function() return {} end,
            setRefreshCallback = function() end,
        })
        ZenSpec.replace("modules/filebrowser/patches/standalone_page", {})
        ZenSpec.replace("common/shared_state", {
            register = function() return {} end,
            registerLoader = function() end,
        })
        ZenSpec.replace("common/title_sort", {
            key = function(value) return tostring(value) end,
            less = function(first, second)
                return tostring(first) < tostring(second)
            end,
        })
        ZenSpec.replace("common/widget_resources", {})
        ZenSpec.replace("common/ui/background", { tile_bg = function(color) return color end })
        ZenSpec.replace("common/cover_decode_cache", {
            getFreshMetadata = function() end,
        })
        ZenSpec.replace("common/cover_render_cache", {
            hasExact = function() return false end,
            renderShared = function(_self, _path, source) return source, true end,
            releaseShared = function() return true end,
        })

        local doc = {
            readSetting = function(_, key)
                if key == "percent_finished" then return 0.25 end
                if key == "summary" then return { status = "reading" } end
                if key == "stats" then return { pages = 400 } end
            end,
        }
        ZenSpec.replace("docsettings", {
            findSidecarFile = function(_, path) return path .. ".sdr/metadata.lua" end,
            hasSidecarFile = function() return true end,
            open = function()
                doc_open_count = doc_open_count + 1
                return doc
            end,
        })
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function(_path, key)
                if key == "mode" then return "file" end
                if key == "modification" then return 1 end
                return { mode = "file", modification = 1 }
            end,
        })
        ZenSpec.replace("bookinfomanager", {
            getBookInfo = function()
                book_info_reads = book_info_reads + 1
                return {
                    title = "Alpha", authors = "Author", pages = 400,
                    cover_fetched = true, ignore_cover = true,
                }
            end,
        })
        ZenSpec.replace("modules/filebrowser/patches/rakuyomi", {
            getMetadata = function() end,
        })
        ZenSpec.replace("readhistory", {
            hist = history_items,
            reload = function() history_reload_count = history_reload_count + 1 end,
        })
        ZenSpec.replace("readcollection", {
            isFileInCollections = function()
                favorite_lookup_count = favorite_lookup_count + 1
                return true
            end,
        })
        ZenSpec.replace("common/paths", {
            getHomeDir = function() return "/library" end,
            normPath = function(path) return path end,
            isInHomeDir = function() return true end,
        })
        ZenSpec.replace("common/book_status", {
            isImageFile = function() return false end,
            includeNewInTBREnabled = function() return false end,
            getEffectiveStatus = function(status, percent_finished)
                if status then return status end
                return percent_finished and "reading" or "new"
            end,
            getComputedStatus = function() return "reading" end,
            getDisplayStatus = function(_path, status) return status end,
            getFileStatusData = function(path)
                status_lookup_count = status_lookup_count + 1
                local doc_settings = require("docsettings"):open(path)
                return {
                    status = "reading",
                    percent_finished = 0.25,
                    effective_status = "reading",
                    doc_settings = doc_settings,
                }
            end,
            getEffectiveStatusFromFile = function()
                status_lookup_count = status_lookup_count + 1
                return "reading"
            end,
        })
        ZenSpec.replace("common/tbr_index", {
            refreshPath = function() end,
        })
        ZenSpec.replace("common/utils", {
            getStablePageCount = function(_path, fallback, context)
                stable_contexts[#stable_contexts + 1] = context
                return fallback
            end,
        })
        ZenSpec.unload("common/memory_policy")
        ZenSpec.unload("modules/filebrowser/patches/home_page")
    end)

    after_each(function()
        _G.__ZEN_UI_LAST_READ_FILE = nil
    end)

    local function get_home_module(apply)
        for i = 1, 20 do
            local name, value = debug.getupvalue(apply, i)
            if not name then break end
            if name == "register_home_api" then
                for j = 1, 20 do
                    local child_name, child_value = debug.getupvalue(value, j)
                    if not child_name then break end
                    if child_name == "M" then return child_value end
                end
            end
        end
        error("home module upvalue not found")
    end

    local function get_build_data_provider(Home)
        for i = 1, 80 do
            local name, value = debug.getupvalue(Home.showHomeView, i)
            if not name then break end
            if name == "build_data_provider" then return value end
        end
        error("build_data_provider upvalue not found")
    end

    local function get_request_home_repaint(Home)
        for i = 1, 80 do
            local name, value = debug.getupvalue(Home.showHomeView, i)
            if not name then break end
            if name == "request_home_repaint" then return value end
        end
        error("request_home_repaint upvalue not found")
    end

    local function get_install_home_key_handlers(Home)
        for i = 1, 80 do
            local name, value = debug.getupvalue(Home.showHomeView, i)
            if not name then break end
            if name == "install_home_key_handlers" then return value end
        end
        error("install_home_key_handlers upvalue not found")
    end

    local function set_home_menu(Home, menu)
        for i = 1, 40 do
            local name = debug.getupvalue(Home.isActiveOnTop, i)
            if not name then break end
            if name == "_home_menu" then
                debug.setupvalue(Home.isActiveOnTop, i, menu)
                return
            end
        end
        error("home menu upvalue not found")
    end

    it("focuses every strip control and activates it with OK or Enter", function()
        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local install_home_key_handlers = get_install_home_key_handlers(Home)
        local activated = {}
        local contexted = {}
        local targets = {}
        for index, name in ipairs({ "recent", "to_be_read", "books", "search" }) do
            targets[index] = {
                id = index,
                index = index,
                key = "strip-control:" .. name,
                row_order = 10,
                col = index,
                activate = function()
                    activated[#activated + 1] = name
                    return true
                end,
                context = function()
                    contexted[#contexted + 1] = name
                    return true
                end,
            }
        end
        local pending
        local UIManager = require("ui/uimanager")
        UIManager.setDirty = function() end
        UIManager.scheduleIn = function(_self, _delay, callback)
            pending = callback
        end
        UIManager.unschedule = function(_self, callback)
            if pending == callback then pending = nil end
        end
        local menu = { _zen_home_focus_targets = targets }
        install_home_key_handlers(menu)

        assert.are.same({ "Menu" }, menu.key_events.ZenHomeContext[1])
        assert.is_true(menu:onZenHomeContext())
        assert.are.equal(1, top_menu_count)
        assert.are.same({ "Enter" }, menu.key_events.ZenNavbarConfirm[3])
        assert.is_true(menu:onZenNavbarFocusRight())
        assert.are.equal("strip-control:recent", menu._zen_home_focus_key)
        assert.is_true(menu:onZenNavbarConfirm())

        local function key(name)
            return {
                match = function(_self, sequence) return sequence[1] == name end,
            }
        end
        assert.is_true(menu:onKeyRelease(key("Press")))
        assert.is_true(menu:onKeyPress(key("Right")))
        assert.are.equal("strip-control:to_be_read", menu._zen_home_focus_key)
        assert.is_true(menu:onKeyPress(key("Enter")))
        assert.is_true(menu:onKeyRelease(key("Enter")))

        assert.is_true(menu:onFocusMove({ 1, 0 }))
        assert.are.equal("strip-control:books", menu._zen_home_focus_key)
        assert.is_true(menu:onZenNavbarConfirm())
        assert.is_function(pending)
        pending()
        assert.are.same({ "books" }, contexted)
        assert.is_true(menu:onKeyRelease(key("Enter")))
        assert.is_true(menu:onKeyPress("Right"))
        assert.are.equal("strip-control:search", menu._zen_home_focus_key)
        assert.is_true(menu:onKeyPress("Press"))
        assert.is_true(menu:onKeyRelease("Press"))
        assert.are.same({ "recent", "to_be_read", "search" }, activated)
    end)

    it("routes physical page turns to the active book strip", function()
        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local install_home_key_handlers = get_install_home_key_handlers(Home)
        local fallback = {}
        local menu = {
            onNextPage = function()
                fallback[#fallback + 1] = "next"
                return "next fallback"
            end,
            onPrevPage = function()
                fallback[#fallback + 1] = "previous"
                return "previous fallback"
            end,
        }
        install_home_key_handlers(menu)

        assert.are.equal("next fallback", menu:onNextPage())
        assert.are.equal("previous fallback", menu:onPrevPage())
        assert.are.same({ "next", "previous" }, fallback)

        local shifted = {}
        menu._zen_home_strip_page_handler = function(direction)
            shifted[#shifted + 1] = direction
            return false
        end
        assert.is_true(menu:onNextPage())
        assert.is_true(menu:onPrevPage())
        assert.are.same({ "next", "previous" }, shifted)
        assert.are.same({ "next", "previous" }, fallback)
    end)

    it("reports quote selection and layout work separately", function()
        ZenSpec.replace("modules/filebrowser/patches/home/home_quotes", {
            selectQuote = function()
                return { text = "Measured quote" }, {
                    annotation_ms = 12.3,
                    annotation_books = 23,
                    annotation_cache_hits = 0,
                    annotation_cache_misses = 1,
                    sidecar_cache_hits = 4,
                    sidecar_cache_misses = 2,
                    state_writes = 1,
                }
            end,
        })
        ZenSpec.unload("modules/filebrowser/patches/home_page")
        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local provider = get_build_data_provider(Home)({}, { quotes = {} })
        provider:resetPerformanceStats()

        assert.are.equal("Measured quote", provider:getCurrentQuote().text)
        provider:recordQuoteLayout(45.6, false, 9)
        local perf = provider:getPerformanceStats()

        assert.is_number(perf.quote_select_ms)
        assert.are.equal(12.3, perf.quote_annotation_ms)
        assert.are.equal(23, perf.quote_annotation_books)
        assert.are.equal(0, perf.quote_annotation_cache_hits)
        assert.are.equal(1, perf.quote_annotation_cache_misses)
        assert.are.equal(4, perf.quote_sidecar_cache_hits)
        assert.are.equal(2, perf.quote_sidecar_cache_misses)
        assert.are.equal(1, perf.quote_state_writes)
        assert.are.equal(45.6, perf.quote_layout_ms)
        assert.are.equal(0, perf.quote_layout_cache_hits)
        assert.are.equal(1, perf.quote_layout_cache_misses)
        assert.are.equal(9, perf.quote_layout_probes)
    end)

    it("reuses history/status data across providers and opens one sidecar per book miss", function()
        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local build_data_provider = get_build_data_provider(Home)
        local cfg = { browser_cover_badges = {} }
        local dcfg = {
            rows = {
                order = { "strip_recent" },
                enabled = { strip_recent = true },
                max_rows = 1,
            },
            modules = { strip_recent = {} },
        }

        local first = build_data_provider(cfg, dcfg)
        local second = build_data_provider(cfg, dcfg)
        assert.are.equal(1, #first:getBooksForStrip("recently_read", 4, "default", "strip_recent"))
        assert.are.equal(1, #second:getBooksForStrip("recently_read", 4, "default", "strip_recent"))

        assert.are.equal(1, history_reload_count)
        assert.are.equal(1, status_lookup_count)
        assert.are.equal(1, doc_open_count)
        assert.are.equal(1, #stable_contexts)
        assert.is_true(stable_contexts[1].sidecar_checked)
        assert.is_nil(stable_contexts[1].doc_settings)
        assert.is_true(stable_contexts[1].book_info_checked)
        assert.is_table(stable_contexts[1].book_info)
        assert.are.equal(0, favorite_lookup_count)

        table.remove(history_items, 1)
        Home.invalidateBookCache("/library/alpha.epub", true)
        local after_removal = build_data_provider(cfg, dcfg)
        assert.are.equal(0,
            #after_removal:getBooksForStrip("recently_read", 4, "default", "strip_recent"))
        assert.are.equal(2, history_reload_count)
    end)

    it("normalizes Android history paths before validating the file", function()
        history_items[1].file = "/sdcard/alpha.epub"
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function(path, key)
                if path ~= "/storage/emulated/0/alpha.epub" then return nil end
                if key == "mode" then return "file" end
                if key == "modification" then return 1 end
                return { mode = "file", modification = 1 }
            end,
        })
        ZenSpec.replace("common/paths", {
            getHomeDir = function() return "/storage/emulated/0" end,
            normPath = function(path)
                return path:gsub("^/sdcard/", "/storage/emulated/0/")
            end,
            isInHomeDir = function(path)
                return path:sub(1, 20) == "/storage/emulated/0/"
            end,
        })

        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local provider = get_build_data_provider(Home)({ browser_cover_badges = {} }, {
            rows = {
                order = { "featured" },
                enabled = { featured = true },
                max_rows = 1,
            },
            modules = { featured = { default_source = { kind = "recent" } } },
        })

        assert.are.equal("/storage/emulated/0/alpha.epub",
            provider:getFeaturedBook("recently_read", "default").path)
    end)

    it("reuses matching Home stats across provider rebuilds", function()
        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local build_data_provider = get_build_data_provider(Home)
        local dcfg = {
            middle_stats_triplet = { "today_pages", "today_duration", "streak" },
            modules = {},
        }
        local rows = { { id = "stats_triplet" } }
        local first = build_data_provider({ browser_cover_badges = {} }, dcfg)
        local second = build_data_provider({ browser_cover_badges = {} }, dcfg)

        assert.are.equal(12, first:prepareStats(rows).today_pages)
        assert.are.equal(12, second:prepareStats(rows).today_pages)
        assert.are.equal(1, stats_query_count)

        second:prepareStats(rows, true)
        assert.are.equal(2, stats_query_count)
    end)

    it("keeps strip cache entries metadata-only and clears them for Reader", function()
        local full_cover_reads = 0
        local function cover()
            local bb = { stride = 6, h = 1, freed = false }
            function bb:getHeight() return self.h end
            function bb:copy() return cover() end
            function bb:free() self.freed = true end
            return bb
        end
        require("bookinfomanager").getBookInfo = function(_self, _path, get_cover)
            book_info_reads = book_info_reads + 1
            if get_cover then full_cover_reads = full_cover_reads + 1 end
            return {
                title = "Book",
                authors = "Author",
                cover_fetched = true,
                has_cover = true,
                cover_sizetag = "300x400",
                cover_w = 300,
                cover_h = 400,
                cover_bb = cover(),
            }
        end
        history_items[2] = { file = "/library/beta.epub" }

        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        Home.setCoverCacheBudget(10)
        local provider = get_build_data_provider(Home)({ browser_cover_badges = {} }, {
            rows = {
                order = { "strip_recent" },
                enabled = { strip_recent = true },
                max_rows = 1,
            },
            modules = { strip_recent = {} },
        })

        provider:getBooksForStrip("recently_read", 2, "default", "strip_recent")
        local stats = Home.getCoverCacheStats()
        assert.are.equal(0, stats.bytes)
        assert.are.equal(2, stats.count)
        assert.are.equal(2, book_info_reads)
        assert.are.equal(0, full_cover_reads)

        provider:getBooksForStrip("recently_read", 2, "default", "strip_recent")
        assert.are.equal(2, book_info_reads)
        assert.are.equal(0, full_cover_reads)

        Home.setCoverCacheBudget(0)
        stats = Home.getCoverCacheStats()
        assert.are.equal(0, stats.bytes)
        assert.are.equal(0, stats.count)
    end)

    it("warms a strip cover only from scheduled cover work", function()
        local full_cover_reads = 0
        local rendered
        local released
        require("bookinfomanager").getBookInfo = function(_self, _path, get_cover)
            book_info_reads = book_info_reads + 1
            local info = {
                title = "Alpha",
                authors = "Author",
                cover_fetched = true,
                has_cover = true,
                cover_w = 300,
                cover_h = 450,
            }
            if get_cover then
                full_cover_reads = full_cover_reads + 1
                info.cover_bb = { free = function() end }
            end
            return info
        end
        local RenderCache = require("common/cover_render_cache")
        RenderCache.renderShared = function(_self, path, source, width, height)
            rendered = { path = path, source = source, width = width, height = height }
            return source, true
        end
        RenderCache.releaseShared = function(_self, path, bb)
            released = { path = path, bb = bb }
            return true
        end

        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local provider = get_build_data_provider(Home)({ browser_cover_badges = {} }, {
            rows = {
                order = { "strip_recent" },
                enabled = { strip_recent = true },
                max_rows = 1,
            },
            modules = { strip_recent = {} },
        })

        local book = provider:getBooksForStrip(
            "recently_read", 4, "default", "strip_recent")[1]
        assert.is_true(book.has_real_cover)
        assert.is_true(book.is_cover_pending)
        assert.is_nil(book.cover_bb)
        assert.are.equal(0, full_cover_reads)

        assert.are.equal("warmed", provider:warmStripCover(book, 100, 150))
        assert.are.equal(1, full_cover_reads)
        assert.are.same({
            path = "/library/alpha.epub",
            source = rendered.source,
            width = 100,
            height = 150,
        }, rendered)
        assert.are.same({ path = "/library/alpha.epub", bb = rendered.source }, released)
    end)

    for _i, fetched in ipairs({ false, true }) do
        it("hydrates a " .. (fetched and "cached" or "new") .. " landscape cover after one size upgrade", function()
            local scheduled, extracted, rendered = {}, {}, {}
            local busy = true
            local cover_w, cover_h = 100, 150
            local cover_fetched = fetched
            local screen = require("device").screen
            screen.getWidth = function() return 900 end
            screen.getHeight = function() return 600 end
            local UIManager = require("ui/uimanager")
            UIManager.scheduleIn = function(_self, delay, callback)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end
            local function fitted_size(specs)
                local scale = math.min(specs.max_cover_w / 600, specs.max_cover_h / 900)
                return math.floor(600 * scale + 0.5), math.floor(900 * scale + 0.5)
            end
            local BookInfoManager = require("bookinfomanager")
            BookInfoManager.getBookInfo = function(_self, _path, get_cover)
                return {
                    title = "Alpha", cover_fetched = cover_fetched, has_cover = true,
                    cover_w = cover_w, cover_h = cover_h, cover_sizetag = "600x900",
                    cover_bb = get_cover and { free = function() end } or nil,
                }
            end
            BookInfoManager.isCachedCoverInvalid = function(info, specs)
                local width, height = fitted_size(specs)
                return width > info.cover_w or height > info.cover_h
            end
            BookInfoManager.isExtractingInBackground = function() return busy end
            BookInfoManager.extractInBackground = function(_self, files)
                extracted[#extracted + 1] = files
                cover_w, cover_h = fitted_size(files[1].cover_specs)
                cover_fetched = true
                return true
            end
            require("common/cover_render_cache").renderShared = function(_self, _path, source, width, height)
                rendered[#rendered + 1] = { width, height }
                return source, true
            end
            local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
            local notified = {}
            local menu = {
                _zen_home_notify_strip_cover = function(_self, path)
                    notified[#notified + 1] = path
                end,
            }
            set_home_menu(Home, menu)
            UIManager._window_stack = { { widget = menu } }
            local provider = get_build_data_provider(Home)({ browser_cover_badges = {} }, {
                rows = { enabled = { strip = true } }, modules = {},
            })
            local book = provider:getBooksForStrip("recently_read", 4, "default", "strip")[1]

            assert.are.equal("pending", provider:warmStripCover(book, 200, 360))
            assert.are.equal(1, #scheduled)
            table.remove(scheduled, 1).callback()
            assert.are.equal(0, #extracted)
            assert.are.equal(1, #scheduled)

            -- A second consumer needs more width while extraction is deferred.
            assert.are.equal("pending", provider:warmStripCover(book, 240, 320))
            busy = false
            table.remove(scheduled, 1).callback()
            table.remove(scheduled, 1).callback()

            assert.are.same({ "/library/alpha.epub" }, notified)
            assert.are.equal("warmed", provider:warmStripCover(book, 204, 307))
            assert.are.equal("warmed", provider:warmStripCover(book, 200, 360))
            assert.are.equal("warmed", provider:warmStripCover(book, 240, 320))
            assert.are.same({ { 204, 307 }, { 200, 360 }, { 240, 320 } }, rendered)
            assert.are.equal(1, #extracted)
            assert.are.equal(0, #scheduled)
        end)
    end

    it("notifies strip listeners without rebuilding Home for each extracted cover", function()
        local scheduled = {}
        local extraction_started = false
        local screen = require("device").screen
        screen.getWidth = function() return 900 end
        screen.getHeight = function() return 600 end
        local UIManager = require("ui/uimanager")
        UIManager.scheduleIn = function(_self, delay, callback)
            scheduled[#scheduled + 1] = { delay = delay, callback = callback }
        end
        require("bookinfomanager").getBookInfo = function()
            return {
                title = "Alpha",
                cover_fetched = extraction_started,
                has_cover = extraction_started,
                cover_w = 300,
                cover_h = 450,
            }
        end
        require("bookinfomanager").isExtractingInBackground = function()
            return extraction_started
        end
        require("bookinfomanager").extractInBackground = function(_self, files)
            assert.are.equal("/library/alpha.epub", files[1].filepath)
            assert.are.same({ max_cover_w = 200, max_cover_h = 300 }, files[1].cover_specs)
            extraction_started = true
            return true
        end

        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local notified = {}
        local rebuilds = 0
        local menu = {
            _zen_home_notify_strip_cover = function(_self, path)
                notified[#notified + 1] = path
            end,
            _home_rebuild = function() rebuilds = rebuilds + 1 end,
        }
        set_home_menu(Home, menu)
        UIManager._window_stack = { { widget = menu } }
        local provider = get_build_data_provider(Home)({ browser_cover_badges = {} }, {
            rows = {
                order = { "strip_recent" },
                enabled = { strip_recent = true },
                max_rows = 1,
            },
            modules = { strip_recent = {} },
        })

        provider:getBooksForStrip("recently_read", 4, "default", "strip_recent")
        assert.are.equal(0.3, scheduled[1].delay)
        table.remove(scheduled, 1).callback()
        assert.are.equal(1, scheduled[1].delay)
        table.remove(scheduled, 1).callback()

        assert.are.same({ "/library/alpha.epub" }, notified)
        assert.are.equal(0, rebuilds)
    end)

    it("coalesces featured cover extraction into one batch-completion rebuild", function()
        local scheduled = {}
        local extraction_started = false
        local UIManager = require("ui/uimanager")
        UIManager.scheduleIn = function(_self, delay, callback)
            scheduled[#scheduled + 1] = { delay = delay, callback = callback }
        end
        require("bookinfomanager").getBookInfo = function()
            return {
                title = "Alpha",
                cover_fetched = extraction_started,
                has_cover = extraction_started,
                cover_w = 300,
                cover_h = 450,
            }
        end
        require("bookinfomanager").isExtractingInBackground = function()
            return extraction_started
        end
        require("bookinfomanager").extractInBackground = function()
            extraction_started = true
            return true
        end

        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local notifications = 0
        local rebuilds = 0
        local menu = {
            _zen_home_notify_strip_cover = function()
                notifications = notifications + 1
            end,
            _home_rebuild = function() rebuilds = rebuilds + 1 end,
        }
        set_home_menu(Home, menu)
        UIManager._window_stack = { { widget = menu } }
        local provider = get_build_data_provider(Home)({ browser_cover_badges = {} }, {
            rows = {
                order = { "featured" },
                enabled = { featured = true },
                max_rows = 1,
            },
            modules = { featured = { default_source = { kind = "recent" } } },
        })

        provider:getFeaturedBook("recently_read", "default")
        table.remove(scheduled, 1).callback()
        table.remove(scheduled, 1).callback()

        assert.are.equal(0, notifications)
        assert.are.equal(1, rebuilds)
    end)

    it("loads a tag strip from the tag index without consulting reading history", function()
        local requested_tag
        ZenSpec.replace("common/db_bookinfo", {
            getTagBooks = function(tag)
                requested_tag = tag
                return { "/library/alpha.epub" }
            end,
        })
        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local build_data_provider = get_build_data_provider(Home)
        local provider = build_data_provider({ browser_cover_badges = {} }, {
            rows = {
                order = { "strip_tag" },
                enabled = { strip_tag = true },
                max_rows = 1,
            },
            modules = { strip_tag = { tag = "Science" } },
        })

        local books = provider:getBooksForStrip("tag", 4, "default", "strip_tag")

        assert.are.equal("Science", requested_tag)
        assert.are.equal("/library/alpha.epub", books[1].path)
        assert.are.equal(0, history_reload_count)
        assert.are.equal(0, doc_open_count)
    end)

    it("loads a custom strip as metadata-only without opening sidecars", function()
        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local provider = get_build_data_provider(Home)({ browser_cover_badges = {} }, {
            rows = {
                order = { "strip_custom" },
                enabled = { strip_custom = true },
                max_rows = 1,
            },
            modules = {
                strip_custom = { paths = { "/library/alpha.epub" } },
            },
        })

        local books = provider:getBooksForStrip(
            "custom_strip", 4, "default", "strip_custom")

        assert.are.equal("/library/alpha.epub", books[1].path)
        assert.are.equal(0, doc_open_count)
    end)

    it("caps recent strip candidates at 40 without a library fallback walk", function()
        for i = #history_items, 1, -1 do
            table.remove(history_items, i)
        end
        for i = 1, 45 do
            history_items[#history_items + 1] = {
                file = string.format("/library/book-%02d.epub", i),
            }
        end
        ZenSpec.replace("common/book_walker", {
            walk = function()
                error("Recent strips must not walk the library")
            end,
        })
        ZenSpec.unload("modules/filebrowser/patches/home_page")
        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local build_data_provider = get_build_data_provider(Home)
        local provider = build_data_provider({ browser_cover_badges = {} }, {
            rows = {
                order = { "strip_recent" },
                enabled = { strip_recent = true },
                max_rows = 1,
            },
            modules = { strip_recent = {} },
        })

        local books = provider:getBooksForStripPage(
            "recently_read", 4, "default", "strip_recent", 10)

        assert.are.equal("/library/book-01.epub", books[1].path)
        assert.are.equal(40, status_lookup_count)
    end)

    it("requests only visible TBR rows from the persistent index", function()
        local indexed = {
            "/library/tbr-1.epub", "/library/tbr-2.epub", "/library/tbr-3.epub",
            "/library/tbr-4.epub", "/library/tbr-5.epub", "/library/tbr-6.epub",
        }
        local page_calls = {}
        local all_calls = 0
        ZenSpec.replace("common/tbr_index", {
            refreshPath = function() end,
            getRevision = function() return 1 end,
            getCount = function() return #indexed end,
            getPage = function(offset, limit)
                page_calls[#page_calls + 1] = { offset = offset, limit = limit }
                local out = {}
                for index = offset + 1, math.min(#indexed, offset + limit) do
                    out[#out + 1] = indexed[index]
                end
                return out, #indexed
            end,
            getAll = function()
                all_calls = all_calls + 1
                return indexed
            end,
            isAuditRunning = function() return false end,
            scheduleAudit = function() return true end,
            cancelAudit = function() end,
        })
        ZenSpec.replace("common/db_bookinfo", {
            getTBRIndexCandidates = function() return {} end,
        })
        ZenSpec.replace("ui/uimanager", {
            nextTick = function(_self, fn) fn() end,
            scheduleIn = function() end,
        })
        ZenSpec.unload("modules/filebrowser/patches/home_page")

        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local build_data_provider = get_build_data_provider(Home)
        local provider = build_data_provider({
            browser_cover_badges = {},
            group_view = {
                detail_collate = { to_be_read = { to_be_read = "title" } },
                detail_reverse = { to_be_read = { to_be_read = false } },
            },
        }, {
            rows = {
                order = { "strip_tbr" },
                enabled = { strip_tbr = true },
                max_rows = 1,
            },
            modules = { strip_tbr = {} },
        })

        local featured = provider:getFeaturedBook("to_be_read", "default")
        local first = provider:getBooksForStripPage(
            "to_be_read", 4, "default", "strip_tbr", 0)
        local adjacent = provider:getBooksForStripPage(
            "to_be_read", 4, "default", "strip_tbr", 1)

        assert.are.equal("/library/tbr-1.epub", featured.path)
        assert.are.equal("/library/tbr-1.epub", first[1].path)
        assert.are.equal("/library/tbr-2.epub", first[2].path)
        assert.are.equal("/library/tbr-4.epub", first[4].path)
        assert.are.equal("/library/tbr-5.epub", adjacent[1].path)
        assert.are.equal("/library/tbr-6.epub", adjacent[2].path)
        assert.are.equal(2, #adjacent)
        assert.are.same({
            { offset = 0, limit = 1 },
            { offset = 0, limit = 4 },
            { offset = 4, limit = 4 },
        }, page_calls)
        assert.are.equal(0, all_calls)
        assert.are.equal(1, doc_open_count)
    end)

    it("caps TBR strip pages to the first 40 indexed books", function()
        local indexed = {}
        for i = 1, 45 do
            indexed[#indexed + 1] = string.format("/library/tbr-%02d.epub", i)
        end
        ZenSpec.replace("common/tbr_index", {
            refreshPath = function() end,
            getCount = function() return #indexed end,
            getPage = function(offset, limit)
                local out = {}
                for i = offset + 1, math.min(#indexed, offset + limit) do
                    out[#out + 1] = indexed[i]
                end
                return out
            end,
            isAuditRunning = function() return false end,
            scheduleAudit = function() return true end,
            cancelAudit = function() end,
        })
        ZenSpec.replace("common/db_bookinfo", {
            getTBRIndexCandidates = function() return {} end,
        })
        ZenSpec.replace("ui/uimanager", {
            nextTick = function(_, fn) fn() end,
            scheduleIn = function() end,
        })
        ZenSpec.unload("modules/filebrowser/patches/home_page")

        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local build_data_provider = get_build_data_provider(Home)
        local provider = build_data_provider({
            browser_cover_badges = {},
            group_view = {
                detail_collate = { to_be_read = { to_be_read = "title" } },
                detail_reverse = { to_be_read = { to_be_read = false } },
            },
        }, {
            rows = {
                order = { "strip_tbr" },
                enabled = { strip_tbr = true },
                max_rows = 1,
            },
            modules = { strip_tbr = {} },
        })

        local books = provider:getBooksForStripPage(
            "to_be_read", 2, "default", "strip_tbr", 20)

        assert.are.equal("/library/tbr-01.epub", books[1].path)
    end)

    it("resolves favorite state only for strips that display badges", function()
        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local build_data_provider = get_build_data_provider(Home)
        local cfg = { browser_cover_badges = { show_favorite_badge = true } }
        local dcfg = {
            rows = {
                order = { "strip_recent" },
                enabled = { strip_recent = true },
                max_rows = 1,
            },
            modules = { strip_recent = { show_badges = true } },
        }

        local provider = build_data_provider(cfg, dcfg)
        local books = provider:getBooksForStrip("recently_read", 4, "default", "strip_recent")
        assert.is_true(books[1].is_fav)
        assert.are.equal(1, favorite_lookup_count)
    end)

    it("suspends retained Home without rebuilding it in the background", function()
        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local UIManager = require("ui/uimanager")
        local rebuilds = 0
        local resumes = 0
        local menu = {
            _zen_home_focus_index = 2,
            _zen_home_focus_id = "stats_triplet",
            _zen_home_focus_key = "widget:stats_triplet",
            _zen_home_focus_suspended = true,
            _home_rebuild = function() rebuilds = rebuilds + 1 end,
            _zen_home_resume = function(self)
                resumes = resumes + 1
                self._zen_home_suspended = nil
                return true, "reused"
            end,
        }
        set_home_menu(Home, menu)
        UIManager._window_stack = { { widget = menu } }
        UIManager._dirty = { [menu] = "ui" }

        assert.is_true(Home.suspendActive())
        assert.is_true(menu._zen_home_suspended)
        assert.is_nil(menu._zen_home_focus_index)
        assert.is_nil(menu._zen_home_focus_id)
        assert.is_nil(menu._zen_home_focus_key)
        assert.is_nil(menu._zen_home_focus_suspended)
        assert.is_nil(UIManager._dirty[menu])
        assert.is_true(Home.rebuildActive())
        assert.are.equal(0, rebuilds)
        assert.is_true(menu._zen_home_needs_rebuild)
        assert.is_true(menu._zen_home_refresh_stats)
        assert.is_true(menu._zen_home_reload_config)

        assert.are.same({ true, "reused" }, { Home.resumeActive() })
        assert.are.equal(1, resumes)
    end)

    it("declines tag-strip navigation when Home has no book strip", function()
        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        set_home_menu(Home, { _zen_home_has_strip = false })

        assert.is_false(Home.showTagInStrip("Science"))
    end)

    it("refreshes a stale retained navbar before resuming Home", function()
        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local UIManager = require("ui/uimanager")
        local order = {}
        local menu = {
            _zen_reinject_navbar = function()
                order[#order + 1] = "navbar"
            end,
            _zen_home_resume = function()
                order[#order + 1] = "resume"
                return true, "reused"
            end,
        }
        set_home_menu(Home, menu)
        UIManager._window_stack = { { widget = menu } }

        assert.is_true(Home.invalidateNavbar())
        assert.is_true(menu._zen_navbar_refresh_pending)
        assert.are.same({ true, "reused" }, { Home.resumeActive() })
        assert.are.same({ "navbar", "resume" }, order)
        assert.is_nil(menu._zen_navbar_refresh_pending)
    end)

    it("rebuilds an invalidated TBR strip after its settings overlay closes", function()
        local dirtied = {}
        local UIManager = {
            _window_stack = {},
            nextTick = function(_self, callback) callback() end,
            scheduleIn = function() end,
            setDirty = function(_self, widget, refresh)
                dirtied[#dirtied + 1] = { widget = widget, refresh = refresh }
            end,
            close = function(self, widget)
                for index = #self._window_stack, 1, -1 do
                    if self._window_stack[index].widget == widget then
                        table.remove(self._window_stack, index)
                        break
                    end
                end
            end,
        }
        ZenSpec.replace("ui/uimanager", UIManager)
        ZenSpec.unload("modules/filebrowser/patches/home_page")

        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local rebuilds = 0
        local resumes = 0
        local home = {
            _home_rebuild = function(self)
                rebuilds = rebuilds + 1
                self._zen_home_needs_rebuild = nil
                self._zen_home_reload_config = nil
            end,
            _zen_home_resume = function(self)
                resumes = resumes + 1
                self._zen_home_needs_repaint = nil
                self:_home_rebuild()
                UIManager:setDirty(self, "ui")
                return true, "rebuilt"
            end,
        }
        local settings = {}
        set_home_menu(Home, home)
        UIManager._window_stack = {
            { widget = home },
            { widget = settings },
        }

        Home.invalidateTBRCache()
        assert.are.equal(0, rebuilds)
        assert.is_true(home._zen_home_needs_rebuild)
        assert.is_true(home._zen_home_reload_config)
        assert.is_true(home._zen_home_needs_repaint)

        UIManager:close(settings)
        assert.are.equal(1, resumes)
        assert.are.equal(1, rebuilds)
        assert.are.same({ { widget = home, refresh = "ui" } }, dirtied)
    end)

    it("repaints Home after the last generic startup overlay closes", function()
        local closed = {}
        local dirtied = {}
        local UIManager = {
            _window_stack = {},
            nextTick = function(_self, callback) callback() end,
            scheduleIn = function() end,
            setDirty = function(_self, widget, refresh, region)
                dirtied[#dirtied + 1] = {
                    widget = widget,
                    refresh = refresh,
                    region = region,
                }
            end,
            close = function(self, widget, refresh, region)
                closed[#closed + 1] = {
                    widget = widget,
                    refresh = refresh,
                    region = region,
                }
                for index = #self._window_stack, 1, -1 do
                    if self._window_stack[index].widget == widget then
                        table.remove(self._window_stack, index)
                        break
                    end
                end
                return "closed"
            end,
        }
        ZenSpec.replace("ui/uimanager", UIManager)
        ZenSpec.unload("modules/filebrowser/patches/home_page")

        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local request_home_repaint = get_request_home_repaint(Home)
        local resumes = 0
        local home = {
            _zen_home_resume = function(self)
                resumes = resumes + 1
                self._zen_home_needs_repaint = nil
                UIManager:setDirty(self, "ui")
                return true, "rebuilt"
            end,
        }
        local first_overlay = { invisible = true }
        local last_overlay = {}
        local passive_helper = { toast = true, invisible = true }
        local notification = { toast = true }
        local close_region = {}
        set_home_menu(Home, home)
        UIManager._window_stack = {
            { widget = home },
            { widget = first_overlay },
            { widget = last_overlay },
            { widget = passive_helper },
            { widget = notification },
        }

        assert.is_false(request_home_repaint(home, "partial"))
        assert.is_true(home._zen_home_needs_repaint)
        assert.are.equal("closed",
            UIManager:close(last_overlay, "flashui", close_region))
        assert.are.same({}, dirtied)

        assert.are.equal("closed",
            UIManager:close(first_overlay, "flashui", close_region))
        assert.are.same({
            { widget = last_overlay, refresh = "flashui", region = close_region },
            { widget = first_overlay, refresh = "flashui", region = close_region },
        }, closed)
        assert.are.same({
            { widget = home, refresh = "ui" },
        }, dirtied)
        assert.are.equal(1, resumes)
        assert.is_true(Home.isActiveOnTop())
        assert.are.equal(passive_helper, UIManager._window_stack[2].widget)
        assert.are.equal(notification, UIManager._window_stack[3].widget)
        assert.is_nil(home._zen_home_needs_repaint)
    end)

    it("does not reveal suspended or replaced Home views", function()
        local dirtied = {}
        local UIManager = {
            _window_stack = {},
            nextTick = function(_self, callback) callback() end,
            scheduleIn = function() end,
            setDirty = function(_self, widget, refresh)
                dirtied[#dirtied + 1] = { widget = widget, refresh = refresh }
            end,
            close = function(self, widget)
                for index = #self._window_stack, 1, -1 do
                    if self._window_stack[index].widget == widget then
                        table.remove(self._window_stack, index)
                        break
                    end
                end
            end,
        }
        ZenSpec.replace("ui/uimanager", UIManager)
        ZenSpec.unload("modules/filebrowser/patches/home_page")

        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local request_home_repaint = get_request_home_repaint(Home)
        local suspended_home = { _zen_home_suspended = true }
        local blocker = {}
        set_home_menu(Home, suspended_home)
        UIManager._window_stack = {
            { widget = suspended_home },
            { widget = blocker },
        }

        assert.is_false(request_home_repaint(suspended_home, "ui"))
        UIManager:close(blocker)
        assert.are.same({}, dirtied)
        assert.is_true(suspended_home._zen_home_needs_repaint)

        local replacement = {}
        local replacement_blocker = {}
        set_home_menu(Home, replacement)
        UIManager._window_stack = {
            { widget = suspended_home },
            { widget = replacement_blocker },
        }
        UIManager:close(replacement_blocker)
        assert.are.same({}, dirtied)
    end)

    it("requires retained Home to be raised before resuming it", function()
        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local UIManager = require("ui/uimanager")
        local menu = {
            _home_rebuild = function() end,
            _zen_home_resume = function() return true, "reused" end,
        }
        set_home_menu(Home, menu)
        UIManager._window_stack = { { widget = {} } }

        assert.are.same({ false, "not_top" }, { Home.resumeActive() })
        UIManager._window_stack[#UIManager._window_stack + 1] = { widget = menu }
        assert.are.same({ true, "reused" }, { Home.resumeActive() })
    end)

    it("defers queued Home cover work after Home is hidden", function()
        local scheduled = {}
        local extraction_calls = 0
        local UIManager = require("ui/uimanager")
        UIManager.scheduleIn = function(_self, delay, callback)
            scheduled[#scheduled + 1] = { delay = delay, callback = callback }
        end
        require("bookinfomanager").getBookInfo = function()
            return {
                title = "Alpha",
                cover_fetched = false,
                has_cover = false,
            }
        end
        require("bookinfomanager").isExtractingInBackground = function() return false end
        require("bookinfomanager").extractInBackground = function()
            extraction_calls = extraction_calls + 1
            return true
        end

        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local menu = { _home_rebuild = function() end }
        set_home_menu(Home, menu)
        UIManager._window_stack = { { widget = menu } }
        local provider = get_build_data_provider(Home)({ browser_cover_badges = {} }, {
            rows = {
                order = { "featured" },
                enabled = { featured = true },
                max_rows = 1,
            },
            modules = { featured = { default_source = { kind = "recent" } } },
        })

        provider:getFeaturedBook("recently_read", "default")
        assert.are.equal(0.3, scheduled[1].delay)
        UIManager._window_stack = { { widget = {} } }
        table.remove(scheduled, 1).callback()

        assert.are.equal(0, extraction_calls)
        assert.is_true(menu._zen_home_needs_rebuild)
    end)

    it("loads Favorites as a first-class strip source", function()
        ZenSpec.replace("readcollection", {
            default_collection_name = "favorites",
            coll = {
                favorites = {
                    a = { file = "/library/alpha.epub", order = 2 },
                    b = { file = "/library/beta.epub", order = 1 },
                },
            },
            coll_settings = {},
        })
        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local provider = get_build_data_provider(Home)({ browser_cover_badges = {} }, {
            rows = { order = { "strip" }, enabled = { strip = true } },
            modules = { strip = {} },
        })

        local books, adjacent = provider:getStripItemsForPage(
            { kind = "favorites" }, 1, "default", "strip", 0)
        assert.are.equal("/library/beta.epub", books[1].path)
        assert.is_true(adjacent)
    end)

    it("keeps the final strip page partial before wrapping", function()
        local favorites = {}
        for i = 1, 6 do
            favorites[tostring(i)] = {
                file = "/library/book-" .. tostring(i) .. ".epub",
                order = i,
            }
        end
        ZenSpec.replace("readcollection", {
            default_collection_name = "favorites",
            coll = { favorites = favorites },
            coll_settings = {},
        })
        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local provider = get_build_data_provider(Home)({ browser_cover_badges = {} }, {
            rows = { order = { "strip" }, enabled = { strip = true } },
            modules = { strip = {} },
        })
        local source = { kind = "favorites" }

        assert.is_true(provider:shiftStripItems(source, 4, "default", "next", "strip"))
        local partial = provider:getStripItemsForPage(source, 4, "default", "strip", 0)
        assert.are.same({ "/library/book-5.epub", "/library/book-6.epub" }, {
            partial[1].path,
            partial[2].path,
        })
        assert.are.equal(2, #partial)

        assert.is_true(provider:shiftStripItems(source, 4, "default", "next", "strip"))
        local restarted = provider:getStripItemsForPage(source, 4, "default", "strip", 0)
        assert.are.same({
            "/library/book-1.epub",
            "/library/book-2.epub",
            "/library/book-3.epub",
            "/library/book-4.epub",
        }, {
            restarted[1].path,
            restarted[2].path,
            restarted[3].path,
            restarted[4].path,
        })
    end)

    it("keeps the final recent strip page partial before wrapping", function()
        for i = #history_items, 1, -1 do
            table.remove(history_items, i)
        end
        for i = 1, 6 do
            history_items[#history_items + 1] = {
                file = "/library/recent-" .. tostring(i) .. ".epub",
            }
        end
        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local provider = get_build_data_provider(Home)({ browser_cover_badges = {} }, {
            rows = { order = { "strip_recent" }, enabled = { strip_recent = true } },
            modules = { strip_recent = {} },
        })

        assert.is_true(provider:shiftStrip(
            "recently_read", 4, "default", "next", "strip_recent"))
        local partial = provider:getBooksForStripPage(
            "recently_read", 4, "default", "strip_recent", 0)
        assert.are.same({ "/library/recent-5.epub", "/library/recent-6.epub" }, {
            partial[1].path,
            partial[2].path,
        })
        assert.are.equal(2, #partial)

        assert.is_true(provider:shiftStrip(
            "recently_read", 4, "default", "next", "strip_recent"))
        local restarted = provider:getBooksForStripPage(
            "recently_read", 4, "default", "strip_recent", 0)
        assert.are.same({
            "/library/recent-1.epub",
            "/library/recent-2.epub",
            "/library/recent-3.epub",
            "/library/recent-4.epub",
        }, {
            restarted[1].path,
            restarted[2].path,
            restarted[3].path,
            restarted[4].path,
        })
    end)

    it("restores the active strip page across provider rebuilds", function()
        ZenSpec.replace("readcollection", {
            default_collection_name = "favorites",
            coll = {
                favorites = {
                    a = { file = "/library/alpha.epub", order = 2 },
                    b = { file = "/library/beta.epub", order = 1 },
                },
            },
            coll_settings = {},
        })
        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local build_data_provider = get_build_data_provider(Home)
        local dcfg = {
            rows = { order = { "strip" }, enabled = { strip = true } },
            modules = { strip = {} },
        }
        local first = build_data_provider({ browser_cover_badges = {} }, dcfg)

        assert.is_true(first:shiftStripItems(
            { kind = "favorites" }, 1, "default", "next", "strip"))
        local restored = build_data_provider(
            { browser_cover_badges = {} }, dcfg, first:getStripPageState())
        local books = restored:getStripItemsForPage(
            { kind = "favorites" }, 1, "default", "strip", 0)

        assert.are.equal("/library/alpha.epub", books[1].path)
    end)

    it("restores a collection drill from its remembered label", function()
        ZenSpec.replace("readcollection", {
            coll = {
                Adventure = {
                    a = { file = "/library/alpha.epub", order = 1 },
                    b = { file = "/library/beta.epub", order = 2 },
                },
            },
            coll_settings = {},
        })
        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local provider = get_build_data_provider(Home)({ browser_cover_badges = {} }, {
            rows = { order = { "strip" }, enabled = { strip = true } },
            modules = { strip = {} },
        })

        local books = provider:getStripItemsForPage({
            kind = "collections",
            drill = { label = "Adventure" },
        }, 4, "default", "strip", 0)

        assert.are.equal(2, #books)
        assert.are.equal("/library/alpha.epub", books[1].path)
    end)

    it("sorts Authors strip stacks like the Authors page", function()
        ZenSpec.replace("common/db_bookinfo", {
            getGroupedByAuthor = function()
                return {
                    { author = "Aaron Zulu", files = { "/library/alpha.epub" } },
                    { author = "Zoe Alpha", files = { "/library/beta.epub" } },
                }
            end,
        })
        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local cfg = {
            browser_cover_badges = {},
            group_view = {
                authors_collate = "authors_last",
                group_reverse = { authors = false },
            },
        }
        local provider = get_build_data_provider(Home)(cfg, {
            rows = { order = { "strip" }, enabled = { strip = true } },
            modules = { strip = {} },
        })

        local groups = provider:getStripItemsForPage(
            { kind = "authors" }, 4, "default", "strip", 0)

        assert.are.same({ "Zoe Alpha", "Aaron Zulu" }, {
            groups[1].group_label,
            groups[2].group_label,
        })

        cfg.group_view.group_reverse.authors = true
        groups = provider:getStripItemsForPage(
            { kind = "authors" }, 4, "default", "strip", 0)
        assert.are.same({ "Aaron Zulu", "Zoe Alpha" }, {
            groups[1].group_label,
            groups[2].group_label,
        })
    end)

    it("returns tag stacks and drills into their books", function()
        ZenSpec.replace("common/db_bookinfo", {
            getGroupedByTags = function()
                return {{
                    tag = "Science",
                    files = { "/library/alpha.epub", "/library/beta.epub" },
                }}
            end,
        })
        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local provider = get_build_data_provider(Home)({ browser_cover_badges = {} }, {
            rows = { order = { "strip" }, enabled = { strip = true } },
            modules = { strip = {} },
        })

        local groups = provider:getStripItemsForPage(
            { kind = "tags" }, 4, "default", "strip", 0)
        assert.is_true(groups[1].is_group)
        assert.are.equal("Science", groups[1].group_label)
        assert.are.equal(2, groups[1].group_count)

        local books = provider:getStripItemsForPage({
            kind = "tags",
            drill = { label = "Science" },
        }, 4, "default", "strip", 0)
        assert.are.equal(2, #books)
        assert.is_nil(books[1].is_group)
    end)

    it("returns language stacks and drills into their books", function()
        ZenSpec.replace("common/db_bookinfo", {
            getGroupedByLanguage = function()
                return {{
                    language = "en",
                    files = { "/library/alpha.epub", "/library/beta.epub" },
                }}
            end,
        })
        local Home = get_home_module(require("modules/filebrowser/patches/home_page"))
        local provider = get_build_data_provider(Home)({ browser_cover_badges = {} }, {
            rows = { order = { "strip" }, enabled = { strip = true } },
            modules = { strip = {} },
        })

        local groups = provider:getStripItemsForPage(
            { kind = "languages" }, 4, "default", "strip", 0)
        assert.is_true(groups[1].is_group)
        assert.are.equal("English", groups[1].group_label)
        assert.are.equal(2, groups[1].group_count)

        local books = provider:getStripItemsForPage({
            kind = "languages",
            drill = { label = "English" },
        }, 4, "default", "strip", 0)
        assert.are.equal(2, #books)
        assert.is_nil(books[1].is_group)
    end)

end)
