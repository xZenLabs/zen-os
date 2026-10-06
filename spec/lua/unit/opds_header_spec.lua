describe("OPDS header", function()
    local Browser, closed, existing_files, inventory_paths, menu_opened, returned, saved, searched
    local scheduled, subprocess_runs, trapper_wraps, unscheduled
    local process_done, spawn_failed, pipe_size, pipe_bytes, pipe_reads, fd_closes, terminated, standby
    local native_ffi, native_util
    local NetworkMgr, catalog_requests, next_pages, connection_requests, connection_callback, network_notices
    local cover_bytes, cleared_scope
    local originals = {}
    local replaced = {
        "opdsbrowser", "ui/bidi", "ffi/blitbuffer",
        "ui/widget/container/centercontainer", "ui/font",
        "ui/widget/container/framecontainer", "ui/geometry", "ui/gesturerange",
        "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/widget/imagewidget",
        "ui/widget/container/inputcontainer", "ui/widget/linewidget", "ui/widget/menu",
        "ui/size", "ui/widget/textboxwidget", "ui/widget/textwidget",
        "ui/widget/container/topcontainer", "ui/uimanager", "ui/widget/verticalgroup",
        "ui/widget/verticalspan", "common/ui/zen_icon_button",
        "common/ui/zen_modal_close", "common/zen_logger", "device", "opdsparser",
        "common/cover_utils", "common/utils", "common/plugin_root", "common/tbr_index",
        "libs/libkoreader-lfs", "ui/renderimage", "ui/trapper", "ffi", "ffi/util",
        "ui/network/manager", "ui/widget/infomessage", "gettext",
        "common/opds_cover_cache", "json",
        "socket.http", "ltn12", "socketutil",
        "common/reader_themes", "apps/reader/readerui",
        "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/widget/container/leftcontainer",
        "ui/widget/notification", "opdspse", "ui/widget/textviewer", "socket.url", "util",
    }

    local function get_upvalue(fn, target)
        for index = 1, 60 do
            local name, value = debug.getupvalue(fn, index)
            if not name then break end
            if name == target then return value end
        end
    end

    local function widget_class()
        local class = {}
        function class:extend(values)
            values = values or {}
            values.extend = self.extend
            values.new = function(cls, spec)
                spec = spec or {}
                return setmetatable(spec, { __index = cls })
            end
            return setmetatable(values, { __index = self })
        end
        function class:new(values) return values or {} end
        function class:paintTo() end
        return class
    end

    local function generated_button(side, callback, icon)
        return {
            side = side,
            icon = icon,
            width = 24,
            height = 24,
            padding = 4,
            callback = callback,
            free = function(self) self.freed = true end,
        }
    end

    local function new_title_bar()
        local title_bar = {
            width = 320,
            title_h_padding = 4,
            button_padding = 4,
            left_icon = "menu",
            right_icon = "close",
        }
        function title_bar:clear()
            for i = #self, 1, -1 do self[i] = nil end
        end
        function title_bar:init()
            self.left_button = generated_button("left", self.left_icon_tap_callback, self.left_icon)
            self.right_button = generated_button("right", self.right_icon_tap_callback, self.right_icon)
            self[1] = self.left_button
            self[2] = self.right_button
        end
        title_bar:init()
        return title_bar
    end

    before_each(function()
        for _i, name in ipairs(replaced) do originals[name] = package.loaded[name] end
        native_ffi, native_util = require("ffi"), require("ffi/util")
        closed, menu_opened, returned, saved, searched = 0, 0, 0, 0, 0
        scheduled, subprocess_runs, trapper_wraps = {}, 0, 0
        unscheduled = {}
        process_done, spawn_failed, pipe_size, pipe_bytes = true, false, 11, "image-bytes"
        pipe_reads, fd_closes, terminated, standby = 0, 0, 0, 0
        catalog_requests, next_pages, connection_requests, connection_callback, network_notices = {}, 0, 0, nil, {}
        NetworkMgr = {
            connected = true,
            isConnected = function(self) return self.connected end,
            runWhenConnected = function(self, callback)
                connection_requests = connection_requests + 1
                if self.connected then return callback() end
                connection_callback = callback
            end,
        }
        existing_files = {}
        inventory_paths = {}
        cover_bytes, cleared_scope = {}, nil
        local CoverCache = {
            scope = function(creds)
                return creds and (creds.url or "") .. (creds.username or "") .. (creds.password or "") or ""
            end,
            key = function(url, creds)
                return (creds and creds.username or "") .. url
            end,
            get = function(key) return cover_bytes[key] end,
            put = function(key, bytes) cover_bytes[key] = bytes end,
            remove = function(key) cover_bytes[key] = nil end,
            clear = function(creds) cleared_scope = creds end,
        }
        ZenSpec.replace("common/opds_cover_cache", CoverCache)
        ZenSpec.replace("json", { decode = function(feed)
            if feed == "{}" then return { metadata = { title = "JSON catalog" } } end
            error("Invalid JSON")
        end })

        Browser = {
            getPageNumber = function() return 1 end,
            mergeTitleBarIntoLayout = function() end,
            updatePageInfo = function() end,
            parseFeed = function() end,
            genItemTableFromCatalog = function(self) return self.catalog_items or {} end,
            genItemTableFromCatalog2 = function(self, catalog)
                self.catalog_title = catalog.metadata.title
                self.search_url = "/next-search"
                self.facet_groups = { next_page = {} }
                return self.catalog_items or {}
            end,
            editCatalogFromInput = function() end,
        }
        Browser.getFileName = function(self, item)
            local identity = (item.author and item.author .. " - " or "") .. item.title
            return self.root_catalog_raw_names and nil or identity, identity
        end
        Browser.getFiletype = function(item) return item.filetype end
        Browser.getLocalDownloadPath = function(_, filename, filetype)
            return "/downloads/" .. filename .. "." .. filetype
        end
        Browser.init = function(self)
            self.paths = self.paths or {}
            self.title_bar = new_title_bar()
            self.layout = { { self.title_bar.left_button }, { self.title_bar.right_button }, { self.item } }
            self.selected = { x = 1, y = 3 }
        end
        Browser.updateCatalog = function(self, url, paths_updated)
            catalog_requests[#catalog_requests + 1] = { url = url, paths_updated = paths_updated }
            self.layout = { { self.item } }
            self.selected = { x = 1, y = 1 }
            self:mergeTitleBarIntoLayout()
        end
        Browser.onMenuSelect = function(self, item)
            self.stock_selected = item
            if not (item.acquisitions and item.acquisitions[1]) and item.idx ~= 1 then
                NetworkMgr:runWhenConnected(function() self:updateCatalog(item.url) end)
            end
            return true
        end
        Browser.onNextPage = function() next_pages = next_pages + 1; return true end

        local Base = widget_class()
        local Menu = {
            onCloseWidget = function() end,
            updatePageInfo = function() end,
            onNextPage = function() next_pages = next_pages + 1; return true end,
        }
        ZenSpec.replace("opdsbrowser", Browser)
        ZenSpec.replace("ui/bidi", { mirroredUILayout = function() return false end })
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_BLACK = 0, COLOR_DARK_GRAY = 1, COLOR_GRAY = 2,
            COLOR_LIGHT_GRAY = 3, COLOR_WHITE = 4,
        })
        for _i, name in ipairs({
            "ui/widget/container/centercontainer", "ui/widget/container/framecontainer",
            "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/widget/imagewidget",
            "ui/widget/linewidget", "ui/widget/textboxwidget", "ui/widget/textwidget",
            "ui/widget/container/topcontainer", "ui/widget/verticalgroup", "ui/widget/verticalspan",
        }) do
            ZenSpec.replace(name, Base)
        end
        ZenSpec.replace("ui/font", { getFace = function() return {} end })
        ZenSpec.replace("ui/geometry", Base)
        ZenSpec.replace("ui/gesturerange", Base)
        ZenSpec.replace("ui/widget/container/inputcontainer", Base)
        ZenSpec.replace("ui/widget/menu", Menu)
        ZenSpec.replace("ui/size", {
            padding = { small = 4, default = 4, button = 4 },
            margin = { default = 4 }, border = { window = 1 }, line = { medium = 1 },
        })
        ZenSpec.replace("ui/uimanager", {
            close = function() closed = closed + 1 end,
            nextTick = function(_, callback) callback() end,
            scheduleIn = function(_, delay, callback)
                scheduled[#scheduled + 1] = { delay = delay, callback = callback }
            end,
            unschedule = function(_, callback) unscheduled[callback] = true end,
            setDirty = function() end,
            show = function(_, widget)
                assert.are.equal("Error connecting to the network", widget.text)
                network_notices[#network_notices + 1] = widget
            end,
            preventStandby = function() standby = standby + 1 end,
            allowStandby = function() standby = standby - 1 end,
        })
        ZenSpec.replace("ui/network/manager", NetworkMgr)
        ZenSpec.replace("common/reader_themes", { isActiveInReader = function() return false end })
        ZenSpec.replace("ui/widget/infomessage", Base)
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ffi", {
            C = { close = function() fd_closes = fd_closes + 1 end },
        })
        ZenSpec.replace("ffi/util", {
            runInSubProcess = function(_, with_pipe)
                assert.is_true(with_pipe)
                subprocess_runs = subprocess_runs + 1
                if spawn_failed then return false, "fork failed" end
                return subprocess_runs, 10
            end,
            isSubProcessDone = function() return process_done end,
            getNonBlockingReadSize = function() return pipe_size end,
            readAllFromFD = function()
                assert.is_true(process_done or pipe_size > 0)
                pipe_reads = pipe_reads + 1
                fd_closes = fd_closes + 1
                return pipe_bytes
            end,
            terminateSubProcess = function() terminated = terminated + 1 end,
        })
        ZenSpec.replace("ui/trapper", {
            isWrapped = function() return false end,
            wrap = function(_, callback)
                trapper_wraps = trapper_wraps + 1
                callback()
            end,
            dismissableRunInSubprocess = function()
                subprocess_runs = subprocess_runs + 1
                return true, "image-bytes"
            end,
        })
        ZenSpec.replace("ui/renderimage", {
            renderImageData = function()
                return { free = function(self) self.freed = true end }
            end,
        })
        ZenSpec.replace("common/ui/zen_icon_button", {
            new = function(_, spec)
                spec.image = { dimen = {} }
                spec.handleEvent = function(self, event)
                    self.focused = event and event.name == "Focus" or false
                    return true
                end
                return spec
            end,
        })
        ZenSpec.replace("common/ui/zen_modal_close", { installDialog = function() end })
        ZenSpec.replace("common/zen_logger", {
            new = function() return { dbg = function() end, warn = function() end } end,
        })
        ZenSpec.replace("device", {
            screen = {
                scaleBySize = function(_, value) return value end,
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
            },
            hasKeys = function() return true end,
        })
        ZenSpec.replace("opdsparser", { parse = function(_, feed) return { body = feed } end })
        ZenSpec.replace("common/cover_utils", {
            BORDER_SIZE = 1,
            getRatio = function() return 2 / 3 end,
            calcDims = function(w, h) return math.floor(math.min(w, h * 2 / 3)), h end,
        })
        ZenSpec.replace("common/utils", setmetatable({
            resolveLocalIcon = function(dir, name) return dir .. name .. ".svg" end,
        }, { __index = dofile(ZenSpec.root .. "/common/utils.lua") }))
        ZenSpec.replace("common/plugin_root", "/zen-ui")
        ZenSpec.replace("common/tbr_index", {
            getInventoryPaths = function() return inventory_paths end,
        })
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function(path) return existing_files[path] end,
        })
        ZenSpec.unload("modules/global/patches/opds")
        _G.G_reader_settings = ZenSpec.memorySettings()
        _G.__ZEN_UI_PLUGIN = {
            config = { opds = {} },
            saveConfig = function() saved = saved + 1 end,
        }
        require("modules/global/patches/opds")()
    end)

    after_each(function()
        ZenSpec.unload("modules/global/patches/opds")
        _G.__ZEN_UI_PLUGIN = nil
        for _i, name in ipairs(replaced) do package.loaded[name] = originals[name] end
    end)

    it("keeps back, refresh, search, and close together in a focusable header row", function()
        local browser = setmetatable({
            paths = { { url = "/catalog" } },
            search_url = "/search",
            item = { name = "book" },
            servers = {},
            onReturn = function() returned = returned + 1 end,
            searchCatalog = function() searched = searched + 1 end,
            showOPDSMenu = function() menu_opened = menu_opened + 1 end,
            onCloseAllMenus = function() closed = closed + 1 end,
        }, { __index = Browser })

        browser:init()
        local buttons = browser._zen_opds_header_buttons
        assert.are.equal(4, #buttons)
        assert.are.equal("back", buttons[1]._zen_opds_focus_id)
        assert.are.equal("refresh", buttons[2]._zen_opds_focus_id)
        assert.are.equal("search", buttons[3]._zen_opds_focus_id)
        assert.are.equal("close", buttons[4]._zen_opds_focus_id)
        assert.are.equal("/zen-ui/icons/tab_left.svg", buttons[1].file)
        assert.are.equal("/zen-ui/icons/quick_sync.svg", buttons[2].file)
        assert.are.equal("/zen-ui/icons/quick_search.svg", buttons[3].file)
        assert.are.equal("/zen-ui/icons/close.svg", buttons[4].file)
        assert.are.equal("chevron.left", browser.title_bar.left_icon)
        assert.are.equal("close", browser.title_bar.right_icon)
        assert.are.equal("left", buttons[1].overlap_align)
        assert.are.equal("right", buttons[4].overlap_align)
        assert.is_true(browser.layout[1] == buttons)
        assert.is_true(browser.layout[2][1] == browser.item)
        assert.are.same({ x = 1, y = 2 }, browser.selected)

        buttons[1].callback()
        buttons[3].callback()
        buttons[4].callback()
        assert.are.equal(1, returned)
        assert.are.equal(1, searched)
        assert.are.equal(1, closed)

        browser:updateCatalog("/next")
        assert.are.equal(4, #browser.layout[1])
        assert.are.equal("back", browser.layout[1][1]._zen_opds_focus_id)
        assert.are.equal("refresh", browser.layout[1][2]._zen_opds_focus_id)
        assert.are.equal("search", browser.layout[1][3]._zen_opds_focus_id)
        assert.are.equal("close", browser.layout[1][4]._zen_opds_focus_id)
        assert.are.equal("chevron.left", browser.title_bar.left_icon)
        assert.are.equal("close", browser.title_bar.right_icon)
        assert.is_true(browser.layout[2][1] == browser.item)

        browser.search_url = nil
        browser:updateCatalog("/without-search")
        assert.are.equal("menu", browser.layout[1][3]._zen_opds_focus_id)
        browser.layout[1][3].callback()
        assert.are.equal(1, menu_opened)

        -- appendCatalog changes the title, which rebuilds TitleBar without fix_buttons.
        browser.title_bar:clear()
        browser.title_bar:init()
        assert.are.equal("chevron.left", browser.title_bar.left_button.icon)
        assert.are.equal("close", browser.title_bar.right_button.icon)
        browser:mergeTitleBarIntoLayout()
        assert.are.equal(4, #browser._zen_opds_header_buttons)
        assert.are.equal("refresh", browser.layout[1][2]._zen_opds_focus_id)
        assert.are.equal("/zen-ui/icons/quick_sync.svg", browser.layout[1][2].file)
    end)

    it("fetches fresh catalogs without conditional validators and supports OPDS 2", function()
        local requests = {}
        local browser = setmetatable({
            fetchFeed = function(_self, url, headers_only, headers)
                requests[#requests + 1] = { url = url, headers_only = headers_only, headers = headers }
                return url == "/json" and "{}" or "<feed>" .. #requests .. "</feed>"
            end,
        }, { __index = Browser })
        assert.are.equal("<feed>1</feed>", browser:parseFeed("/catalog").body)
        assert.are.equal("<feed>2</feed>", browser:parseFeed("/catalog").body)
        local catalog = browser:parseFeed("/json")
        assert.is_true(catalog.is_opds2)
        assert.are.equal("JSON catalog", catalog.metadata.title)
        for _i, request in ipairs(requests) do
            assert.is_false(request.headers_only)
            assert.are.same({ ["Cache-Control"] = "no-cache", Pragma = "no-cache" }, request.headers)
        end
    end)

    it("rescans the current catalog, invalidates its covers, and preserves its path", function()
        local cleared_items, stopped = 0, 0
        local browser = setmetatable({
            paths = { { url = "https://server.test/opds" }, { url = "https://server.test/books" } },
            item_table = {},
            item_group = { clear = function() cleared_items = cleared_items + 1 end },
            root_catalog_username = "user", root_catalog_password = "secret",
            _zen_prefetched_feed = { url = "/next", body = "stale" },
            _zen_halt = function() stopped = stopped + 1 end,
        }, { __index = Browser })
        browser:init()
        browser._zen_prefetched_feed = { url = "/next", body = "stale" }
        browser._zen_opds_library_filenames = { stale = true }
        browser._zen_opds_header_buttons[2].callback()
        assert.are.equal(1, stopped)
        assert.are.equal(0, cleared_items)
        assert.is_true(browser._zen_reload_covers)
        assert.are.same({ url = "https://server.test/opds", username = "user", password = "secret" }, cleared_scope)
        assert.are.equal("https://server.test/books", catalog_requests[1].url)
        assert.is_true(catalog_requests[1].paths_updated)
        assert.are.equal(2, #browser.paths)
        assert.is_nil(browser._zen_prefetched_feed)
        assert.is_nil(browser._zen_opds_library_filenames)
    end)

    it("flashes the underlying screen when the browser closes", function()
        local refreshes = {}
        package.loaded["ui/uimanager"].setDirty = function(_self, widget, mode, region)
            refreshes[#refreshes + 1] = { widget, mode, region }
        end
        local browser = setmetatable({ item_table = {} }, { __index = Browser })

        browser:onCloseWidget()

        assert.is_true(browser._zen_opds_closed)
        assert.are.same({ { "all", "full" } }, refreshes)
    end)

    it("clears the themed reader after OPDS is removed from the screen", function()
        local UIManager = require("ui/uimanager")
        local Screen = require("device").screen
        Screen.waveform_full, Screen.waveform_flashnight = 2, 8
        local reader = { document = {} }
        ZenSpec.replace("apps/reader/readerui", { instance = reader })
        ZenSpec.unload("common/reader_themes")
        local plugin = _G.__ZEN_UI_PLUGIN
        plugin.config.features = { reader_themes = true }
        plugin.config.reader_themes = { dark_mode = "dark_graphite", light_mode = "light_tan" }
        local callback, flashes = nil, 0
        UIManager.nextTick = function(_self, action) callback = action end
        UIManager.forceRePaint = function()
            flashes = flashes + 1
            assert.are.equal(Screen.night_mode and 2 or 8, Screen.waveform_flashnight)
            assert.are.equal(reader, UIManager._window_stack[#UIManager._window_stack].widget)
        end

        for _i, dark_mode in ipairs({ false, true }) do
            Screen.night_mode = dark_mode
            G_reader_settings:saveSetting("night_mode", dark_mode)
            local browser = setmetatable({ item_table = {} }, { __index = Browser })
            UIManager._window_stack = { { widget = reader }, { widget = browser } }
            local before_close = flashes
            browser:onCloseWidget()
            assert.are.equal(before_close, flashes)
            assert.is_function(callback)
            UIManager._window_stack = { { widget = reader } }
            callback()
            assert.are.equal(before_close + 1, flashes)
            assert.are.equal(8, Screen.waveform_flashnight)
            assert.are.equal(dark_mode, Screen.night_mode)
        end
    end)

    it("reuses persisted covers after closing and decodes them at the requested size", function()
        local start_cover_queue = get_upvalue(Browser.updateItems, "start_cover_queue")
        local entry = { cover_url = "https://example.test/cached.jpg" }
        local updated = 0
        local item = { entry = entry, cover_w = 80, cover_h = 120,
            widget = { update = function() updated = updated + 1 end } }
        local halt = start_cover_queue({ item })
        scheduled[1].callback()
        scheduled[2].callback()
        assert.are.equal("image-bytes", cover_bytes[entry.cover_url])
        local old_bb = entry.cover_bb
        local browser = setmetatable({ item_table = { entry }, _zen_halt = halt }, { __index = Browser })
        browser:onCloseWidget()
        assert.is_true(old_bb.freed)
        assert.is_nil(entry.cover_bb)

        local width, height
        package.loaded["ui/renderimage"].renderImageData = function(_self, _bytes, _length, _animated, w, h)
            width, height = w, h
            return { free = function() end }
        end
        item.cover_w, item.cover_h = 160, 240
        halt = start_cover_queue({ item })
        scheduled[#scheduled].callback()
        halt()
        assert.are.equal(160, width)
        assert.are.equal(240, height)
        assert.are.equal(1, subprocess_runs)
        assert.are.equal(2, updated)
        assert.are.equal(0, standby)
    end)

    it("warms exactly the next local page without repainting it", function()
        local warm_next_page = get_upvalue(Browser.updateItems, "warm_next_page")
        local start_cover_queue = get_upvalue(Browser.updateItems, "start_cover_queue")
        local browser = { page = 1, perpage = 2, _zen_cover_size = { w = 80, h = 120 }, item_table = {} }
        for index = 1, 6 do browser.item_table[index] = { cover_url = "https://example.test/" .. index } end
        local queue, keep = {}, {}
        warm_next_page(browser, queue, keep)
        assert.are.equal(2, #queue)
        assert.are.equal(browser.item_table[3], queue[1].entry)
        assert.are.equal(browser.item_table[4], queue[2].entry)
        local halt = start_cover_queue(queue)
        scheduled[1].callback()
        scheduled[2].callback()
        scheduled[3].callback()
        halt()
        assert.is_truthy(browser.item_table[3].cover_bb)
        assert.is_truthy(browser.item_table[4].cover_bb)
        assert.is_nil(browser.item_table[5].cover_bb)
        assert.are.equal(2, subprocess_runs)
        assert.are.equal(0, standby)
    end)

    it("prefetches one remote feed and its next-page covers without changing the visible catalog", function()
        local warm_next_page = get_upvalue(Browser.updateItems, "warm_next_page")
        local start_cover_queue = get_upvalue(Browser.updateItems, "start_cover_queue")
        local browser = setmetatable({
            page = 1, perpage = 2, _zen_cover_size = { w = 80, h = 120 },
            catalog_title = "Visible", search_url = "/visible-search", facet_groups = { visible = {} },
            item_table = { {}, {}, hrefs = { next = "/next" } },
            catalog_items = {
                { title = "Next 1", thumbnail = "https://example.test/next-1", acquisitions = {{}} },
                { title = "Next 2", thumbnail = "https://example.test/next-2", acquisitions = {{}} },
                { title = "Later", thumbnail = "https://example.test/later", acquisitions = {{}} },
            },
        }, { __index = Browser })
        local queue, keep = {}, {}
        warm_next_page(browser, queue, keep)
        assert.are.equal(1, #queue)
        pipe_bytes, pipe_size = "{}", 2
        local halt = start_cover_queue(queue)
        scheduled[1].callback()
        scheduled[2].callback()
        assert.are.equal(3, #queue)
        assert.are.equal("Visible", browser.catalog_title)
        assert.are.equal("/visible-search", browser.search_url)
        assert.are.same({ visible = {} }, browser.facet_groups)
        assert.are.equal(2, #browser.item_table)
        pipe_bytes, pipe_size = "image-bytes", 11
        scheduled[3].callback()
        scheduled[4].callback()
        halt()
        assert.is_truthy(cover_bytes["https://example.test/next-1"])
        assert.is_truthy(cover_bytes["https://example.test/next-2"])
        assert.is_nil(cover_bytes["https://example.test/later"])
        browser.fetchFeed = function() error("Prefetched feed should be used once") end
        assert.is_true(browser:parseFeed("/next").is_opds2)
        assert.is_nil(browser._zen_prefetched_feed)
    end)

    it("does not start background prefetching while offline", function()
        NetworkMgr.connected = false
        local warm_next_page = get_upvalue(Browser.updateItems, "warm_next_page")
        local start_cover_queue = get_upvalue(Browser.updateItems, "start_cover_queue")
        local browser = { page = 1, perpage = 2, _zen_cover_size = { w = 80, h = 120 },
            item_table = { {}, {}, hrefs = { next = "/next" } } }
        local queue = {}
        warm_next_page(browser, queue, {})
        assert.are.equal(0, #queue)
        local halt = start_cover_queue({{
            entry = { cover_url = "https://example.test/offline" }, cover_w = 80, cover_h = 120,
        }})
        scheduled[1].callback()
        halt()
        assert.are.equal(0, subprocess_runs)
        assert.are.equal(0, connection_requests)
        assert.are.equal(0, standby)
    end)

    it("uses warmed bitmaps immediately on a page turn and retires the previous page", function()
        local entries = {}
        for index = 1, 18 do
            local url = "https://example.test/cover-" .. index
            entries[index] = { title = "Book " .. index, cover_url = url }
            cover_bytes[url] = "image-bytes"
        end
        local browser = setmetatable({
            paths = {{ url = "https://example.test/opds" }}, page = 1, item_table = entries,
            inner_dimen = { w = 600, h = 800 },
            item_group = { clear = function(self) for index = #self, 1, -1 do self[index] = nil end end },
            page_info = { resetLayout = function() end },
            return_button = { resetLayout = function() end },
            content_group = { resetLayout = function() end },
            moveFocusTo = function(self, x, y) self.selected = { x = x, y = y } end,
        }, { __index = Browser })
        browser:init()
        browser.title_bar.getHeight = function() return 30 end
        browser:updateItems()
        assert.are.equal(9, browser.perpage)
        assert.is_truthy(entries[1].cover_bb)
        assert.is_nil(entries[10].cover_bb)
        scheduled[#scheduled].callback()
        local previous_bb, warmed_bb = entries[1].cover_bb, entries[10].cover_bb
        assert.is_truthy(warmed_bb)
        browser.page = 2
        browser:updateItems()
        assert.are.equal(warmed_bb, entries[10].cover_bb)
        assert.is_false(warmed_bb.freed == true)
        assert.is_true(previous_bb.freed)
        assert.is_nil(entries[1].cover_bb)
        assert.are.equal(0, subprocess_runs)
        browser:onCloseWidget()
        assert.is_true(warmed_bb.freed)
    end)

    it("keeps credentials on their origin, including redirects, and fetches fresh feeds", function()
        local start_cover_queue = get_upvalue(Browser.updateItems, "start_cover_queue")
        local fetch_bytes = get_upvalue(start_cover_queue, "fetch_bytes")
        local requests, redirects = {}, true
        local function sink(chunks)
            return function(bytes) if bytes then chunks[#chunks + 1] = bytes end; return 1 end
        end
        ZenSpec.replace("ltn12", { sink = { table = sink } })
        ZenSpec.replace("socketutil", {
            set_timeout = function(_self, block, total)
                assert.are.equal(5, block)
                assert.are.equal(10, total)
            end,
            reset_timeout = function() end,
            table_sink = sink,
        })
        ZenSpec.replace("socket.http", { request = function(request)
            requests[#requests + 1] = request
            assert.is_false(request.redirect)
            if redirects and #requests == 1 then
                return 1, 302, { location = "https://cdn.test/cover.jpg" }
            end
            request.sink("fresh bytes")
            return 1, 200, {}
        end })
        local creds = { url = "https://server.test:443/opds", username = "user", password = "secret" }
        assert.are.equal("fresh bytes", fetch_bytes("https://server.test/cover.jpg", creds))
        assert.are.equal("user", requests[1].user)
        assert.are.equal("secret", requests[1].password)
        assert.is_nil(requests[2].user)
        assert.is_nil(requests[2].password)
        redirects = false
        assert.are.equal("fresh bytes", fetch_bytes("https://server.test/next", creds, true))
        assert.are.equal("no-cache", requests[3].headers["Cache-Control"])
        assert.are.equal("no-cache", requests[3].headers.Pragma)
        assert.are.equal("application/opds+json, application/atom+xml", requests[3].headers.Accept)
        assert.are.equal("user", requests[3].user)
        assert.are.equal("fresh bytes", fetch_bytes("https://server.test:444/next", creds, true))
        assert.is_nil(requests[4].user)
    end)

    it("remembers existing downloads by their generated filename", function()
        existing_files["/downloads/Author - Book.epub"] = {
            mode = "file", size = 123,
        }
        local browser = setmetatable({
            catalog_items = {{
                title = "Book",
                author = "Author",
                acquisitions = {{ href = "https://example.test/book", filetype = "epub" }},
            }},
        }, { __index = Browser })

        local items = browser:genItemTableFromCatalog({}, "https://example.test/feed")
        assert.is_true(items[1]._zen_opds_downloaded)
        assert.is_true(_G.__ZEN_UI_PLUGIN.config.opds.downloaded["Author - Book"])
        assert.are.equal(1, saved)

        existing_files["/downloads/Author - Book.epub"] = nil
        browser.catalog_items = {{
            title = "Book",
            author = "Author",
            acquisitions = {{ href = "https://example.test/book", filetype = "epub" }},
        }}
        items = browser:genItemTableFromCatalog({}, "https://example.test/feed")
        assert.is_true(items[1]._zen_opds_downloaded)
        assert.are.equal(1, saved)
    end)

    it("finds an existing download anywhere in the Zen home directories", function()
        inventory_paths = { "/extra-library/series/Author - Book.epub" }
        local browser = setmetatable({
            catalog_items = {{
                title = "Book",
                author = "Author",
                acquisitions = {{ href = "https://example.test/book", filetype = "epub" }},
            }},
        }, { __index = Browser })

        local items = browser:genItemTableFromCatalog({}, "https://example.test/feed")
        assert.is_true(items[1]._zen_opds_downloaded)
        assert.is_true(_G.__ZEN_UI_PLUGIN.config.opds.downloaded["Author - Book"])
        assert.are.equal(1, saved)
    end)

    it("respects rounded cover corners in the book popup for images and placeholders", function()
        local FrameContainer = package.loaded["ui/widget/container/framecontainer"]
        for _i, name in ipairs({
            "ui/widget/buttondialog", "ui/widget/confirmbox", "ui/widget/container/leftcontainer",
            "ui/widget/notification", "opdspse", "ui/widget/textviewer", "socket.url", "util",
        }) do
            ZenSpec.replace(name, FrameContainer)
        end
        package.loaded["ui/uimanager"].show = function() end
        function FrameContainer:paintTo(bb, x, y)
            self.dimen = { w = 82, h = 122 }
            bb:paintRect(x, y, 82, 122, 0)
            bb:paintRect(x + 1, y + 1, 80, 120, 3)
        end

        local browser = setmetatable({}, { __index = Browser })
        for _i, has_cover in ipairs({ false, true }) do
            local item = { title = "Book", acquisitions = {}, cover_bb = has_cover and {} or nil }
            browser:showDownloads(item)
            local cover = browser.download_dialog._added_widgets[1][1][1]
            setmetatable(cover, { __index = FrameContainer })
            assert.are.equal(item.cover_bb, cover[1].image)
            if has_cover then assert.is_false(cover[1].image_disposable) end

            for _j, rounded in ipairs({ false, true, false }) do
                _G.__ZEN_UI_PLUGIN.config.features = { browser_cover_rounded_corners = rounded }
                local pixels = {}
                local bb = { paintRect = function(_self, x, y, w, h, color)
                    for py = y, y + h - 1 do
                        for px = x, x + w - 1 do
                            assert.is_true(px >= 30 and px < 112 and py >= 40 and py < 162)
                            pixels[py * 1000 + px] = color
                        end
                    end
                end }
                cover:paintTo(bb, 30, 40)
                for _k, corner in ipairs({ {30, 40}, {111, 40}, {30, 161}, {111, 161} }) do
                    assert.are.equal(rounded and 4 or 0, pixels[corner[2] * 1000 + corner[1]])
                end
                assert.are.equal(0, pixels[40 * 1000 + 71])
                assert.are.equal(0, pixels[100 * 1000 + 30])
                assert.are.equal(rounded and 0 or 3, pixels[42 * 1000 + 32])
                assert.are.equal(3, pixels[100 * 1000 + 71])
            end
        end
    end)

    it("paints a top-right circle and finished check only for downloaded covers in both layouts", function()
        local classes = {
            get_upvalue(Browser.updateItems, "OPDSItem"),
            get_upvalue(Browser.updateItems, "OPDSMosaicItem"),
        }
        for _i, class in ipairs(classes) do
            for _j, rounded in ipairs({ false, true }) do
                _G.__ZEN_UI_PLUGIN.config.features = { browser_cover_rounded_corners = rounded }
                local item = class:new{
                    entry = {}, cover_w = 100, cover_h = 150,
                    cell_w = 140, cell_h = 200, strip_h = 20,
                    _zen_cover_widget = { dimen = { x = 50, y = 55 } },
                }
                local pixels, dimmed = {}, false
                local bb = {
                    paintRect = function() end,
                    lightenRect = function() dimmed = true end,
                    paintRectRGB32 = function(_self, x, y, width, height, color)
                        assert.is_true(dimmed)
                        for py = y, y + height - 1 do
                            for px = x, x + width - 1 do
                                assert.is_true(px >= 124 and px <= 147 and py >= 58 and py <= 80)
                                pixels[py * 1000 + px] = color
                            end
                        end
                    end,
                }
                item:paintTo(bb, 30, 40)
                assert.are.same({}, pixels)
                assert.is_false(dimmed)

                item.entry._zen_opds_downloaded = true
                item:paintTo(bb, 30, 40)
                assert.are.equal(4, pixels[58 * 1000 + 136]) -- White outline.
                assert.are.equal(0, pixels[69 * 1000 + 127]) -- Black circle.
                assert.are.equal(4, pixels[69 * 1000 + 136]) -- White checkmark.
            end
        end
    end)

    it("waits for Wi-Fi startup before retrying the selected catalog", function()
        for _i, flag in ipairs({ "pending_connection", "pending_connectivity_check" }) do
            NetworkMgr.connected = false
            NetworkMgr[flag] = true
            local browser = setmetatable({}, { __index = Browser })
            browser:init()
            local requested = #catalog_requests
            local connections = connection_requests
            browser:onMenuSelect({ idx = 2, url = "/catalog-" .. flag })
            local wait = scheduled[#scheduled].callback
            wait()
            assert.are.equal(requested, #catalog_requests)
            assert.are.equal(connections, connection_requests)
            assert.are.equal(0, #network_notices)

            NetworkMgr[flag] = false -- Address/gateway readiness can lag behind the startup flag.
            wait()
            assert.are.equal(requested, #catalog_requests)
            NetworkMgr.connected = true
            wait()
            wait()
            assert.are.equal(requested + 1, #catalog_requests)
            assert.are.equal("/catalog-" .. flag, catalog_requests[#catalog_requests].url)
            assert.is_nil(browser._zen_network_wait)
        end
    end)

    it("waits for the default catalog and preserves its credentials", function()
        NetworkMgr.connected, NetworkMgr.pending_connection = false, true
        _G.__ZEN_UI_PLUGIN.config.opds.default_url = "/default"
        local browser = setmetatable({ servers = {{
            url = "/default", title = "Server", username = "user", password = "secret",
        }} }, { __index = Browser })
        browser:init()
        assert.are.equal(0, #catalog_requests)
        assert.are.equal(0, connection_requests)
        NetworkMgr.connected = true
        scheduled[1].callback()
        assert.are.equal("/default", catalog_requests[1].url)
        assert.are.equal("user", browser.root_catalog_username)
        assert.are.equal("secret", browser.root_catalog_password)
    end)

    it("replaces an old queued catalog request and cancels it on close", function()
        NetworkMgr.connected, NetworkMgr.pending_connection = false, true
        local browser = setmetatable({ item_table = {} }, { __index = Browser })
        browser:init()
        browser:updateCatalog("/first")
        local first = scheduled[1].callback
        browser:updateCatalog("/second", true)
        local second = scheduled[2].callback
        assert.is_true(unscheduled[first])
        NetworkMgr.connected = true
        first()
        second()
        assert.are.equal(1, #catalog_requests)
        assert.are.equal("/second", catalog_requests[1].url)
        assert.is_true(catalog_requests[1].paths_updated)

        NetworkMgr.connected = false
        browser:updateCatalog("/closed")
        local pending = scheduled[#scheduled].callback
        browser:onCloseWidget()
        NetworkMgr.connected = true
        pending()
        assert.is_true(unscheduled[pending])
        assert.are.equal(1, #catalog_requests)
    end)

    it("uses native Wi-Fi setup while protecting its callback from later requests", function()
        NetworkMgr.connected = false
        local browser = setmetatable({ item_table = {} }, { __index = Browser })
        browser:init()
        browser:updateCatalog("/first")
        local original_callback = connection_callback
        assert.are.equal(1, connection_requests)
        assert.are.equal(0, #scheduled)
        NetworkMgr.pending_connection = true
        browser:updateCatalog("/second")
        NetworkMgr.connected = true
        original_callback()
        assert.are.equal(0, #catalog_requests)
        scheduled[1].callback()
        assert.are.equal("/second", catalog_requests[1].url)

        NetworkMgr.connected, NetworkMgr.pending_connection = false, false
        browser:updateCatalog("/closed")
        browser:onCloseWidget()
        NetworkMgr.connected = true
        connection_callback()
        assert.are.equal(1, #catalog_requests)
    end)

    it("waits before fetching the next catalog page but keeps local pages available", function()
        NetworkMgr.connected, NetworkMgr.pending_connection = false, true
        local browser = setmetatable({ item_table = { hrefs = { next = "/next" } } }, { __index = Browser })
        browser:init()
        browser:onNextPage()
        assert.are.equal(0, next_pages)
        NetworkMgr.connected = true
        scheduled[1].callback()
        assert.are.equal(1, next_pages)
        NetworkMgr.connected = false
        browser.item_table.hrefs.next = nil
        browser:onNextPage()
        browser:onMenuSelect({ idx = 1 })
        local book = { acquisitions = {{ href = "/book" }} }
        browser:onMenuSelect(book)
        assert.are.equal(2, next_pages)
        assert.are.equal(book, browser.stock_selected)
        assert.are.equal(0, connection_requests)
    end)

    it("turns to an already loaded page without fetching another remote page", function()
        NetworkMgr.connected, NetworkMgr.pending_connection = false, true
        local browser = setmetatable({
            page = 1, page_num = 3, item_table = { hrefs = { next = "/next" } },
        }, { __index = Browser })
        browser:init()
        browser:onNextPage()
        assert.are.equal(1, next_pages)
        assert.are.equal(0, #scheduled)
        assert.are.equal(0, connection_requests)
        browser:onNextPage(true)
        assert.are.equal(1, next_pages)
        assert.are.equal(1, #scheduled)
        NetworkMgr.connected = true
        scheduled[1].callback()
        assert.are.equal(2, next_pages)
    end)

    it("stops waiting after 45 seconds without restarting Wi-Fi or contacting the server", function()
        NetworkMgr.connected, NetworkMgr.pending_connection = false, true
        local browser = setmetatable({}, { __index = Browser })
        browser:init()
        browser:updateCatalog("/timeout")
        for _i = 1, 90 do
            assert.are.equal(0.5, scheduled[#scheduled].delay)
            scheduled[#scheduled].callback()
        end
        assert.are.equal(0, #catalog_requests)
        assert.are.equal(0, connection_requests)
        assert.are.equal(1, #network_notices)
        assert.is_nil(browser._zen_network_wait)
        scheduled[#scheduled].callback()
        assert.are.equal(1, #network_notices)
    end)

    it("loads covers through a subprocess and keeps only the visible page cache", function()
        local start_cover_queue = get_upvalue(Browser.updateItems, "start_cover_queue")
        local prune_cover_cache = get_upvalue(Browser.updateItems, "prune_cover_cache")
        local cover_cache = get_upvalue(start_cover_queue, "_cover_cache")
        local updated = 0
        local entry = { cover_url = "https://example.test/current.jpg" }

        start_cover_queue({{
            entry = entry,
            widget = { update = function() updated = updated + 1 end },
            cover_w = 80,
            cover_h = 120,
        }})
        scheduled[1].callback()
        assert.are.equal(0, updated)
        scheduled[2].callback()

        assert.are.equal(0, trapper_wraps)
        assert.are.equal(1, subprocess_runs)
        assert.are.equal(1, updated)
        assert.are.equal(1, fd_closes)
        assert.are.equal(0, standby)
        assert.is_table(entry.cover_bb)

        local stale = { free = function(self) self.freed = true end }
        local stale_entry = {
            cover_url = "https://example.test/stale.jpg",
            cover_bb = stale,
        }
        cover_cache[stale_entry.cover_url] = { bb = stale }
        prune_cover_cache({ [entry.cover_url] = true }, { entry, stale_entry })

        assert.is_true(stale.freed)
        assert.is_nil(stale_entry.cover_bb)
        assert.are.equal(entry.cover_bb, cover_cache[entry.cover_url].bb)
    end)

    it("leaves header taps available while a slow cover is downloading", function()
        process_done, pipe_size = false, 0
        local start_cover_queue = get_upvalue(Browser.updateItems, "start_cover_queue")
        local updated = 0
        local entry = { cover_url = "https://example.test/slow.jpg" }
        local browser = setmetatable({
            paths = {{ url = "/catalog" }},
            search_url = "/search",
            onReturn = function() returned = returned + 1 end,
            searchCatalog = function() searched = searched + 1 end,
        }, { __index = Browser })
        browser:init()
        local halt = start_cover_queue({{
            entry = entry,
            widget = { update = function() updated = updated + 1 end },
            cover_w = 80, cover_h = 120,
        }})
        scheduled[1].callback()
        scheduled[2].callback()
        browser._zen_opds_header_buttons[1].callback()
        browser._zen_opds_header_buttons[3].callback()

        assert.are.equal(0, trapper_wraps)
        assert.are.equal(0, pipe_reads)
        assert.are.equal(0, updated)
        assert.are.equal(1, returned)
        assert.are.equal(1, searched)
        assert.are.equal(1, standby)

        pipe_size = #pipe_bytes -- The child can still be writing a cover larger than the pipe.
        scheduled[3].callback()
        assert.are.equal(1, updated)
        assert.are.equal(1, pipe_reads)
        assert.are.equal(0, standby)
        process_done = true
        scheduled[4].callback() -- Reap the child after its output was read.
        halt()
    end)

    it("cancels pending covers on close without repainting stale widgets", function()
        process_done, pipe_size = false, 0
        local start_cover_queue = get_upvalue(Browser.updateItems, "start_cover_queue")
        local cover_cache = get_upvalue(start_cover_queue, "_cover_cache")
        local updated = 0
        local entry = { cover_url = "https://example.test/cancelled.jpg" }
        local browser = setmetatable({ item_table = { entry } }, { __index = Browser })
        browser._zen_halt = start_cover_queue({{
            entry = entry,
            widget = { update = function() updated = updated + 1 end },
            cover_w = 80, cover_h = 120,
        }})
        scheduled[1].callback()
        local poll = scheduled[2].callback
        browser:onCloseWidget()
        poll() -- Even an already queued callback must ignore the closed page.

        assert.is_true(unscheduled[poll])
        assert.are.equal(1, terminated)
        assert.are.equal(1, fd_closes)
        assert.are.equal(0, standby)
        assert.are.equal(0, updated)
        assert.are.equal(0, pipe_reads)
        assert.is_nil(cover_cache[entry.cover_url])
        assert.is_nil(browser._zen_halt)
        process_done = true
        scheduled[3].callback()
    end)

    it("can cancel before the first cover worker starts", function()
        local start_cover_queue = get_upvalue(Browser.updateItems, "start_cover_queue")
        local halt = start_cover_queue({{
            entry = { cover_url = "https://example.test/not-started.jpg" },
        }})
        halt()
        scheduled[1].callback()
        assert.are.equal(0, subprocess_runs)
        assert.are.equal(0, standby)
    end)

    it("reads a large cover from a real background process after a slow fetch", function()
        local start_cover_queue = get_upvalue(Browser.updateItems, "start_cover_queue")
        local worker_util = get_upvalue(start_cover_queue, "FFIUtil")
        for name in pairs(worker_util) do worker_util[name] = native_util[name] end
        worker_util.writeToFD = native_util.writeToFD
        package.loaded.ffi.C.close = native_ffi.C.close
        local bytes = string.rep("cover", 128 * 1024)
        for index = 1, 60 do
            local name = debug.getupvalue(start_cover_queue, index)
            if name == "fetch_bytes" then
                debug.setupvalue(start_cover_queue, index, function()
                    native_util.usleep(200000)
                    return bytes
                end)
                break
            end
        end
        local updated, received = 0, nil
        local entry = { cover_url = "https://example.test/large.jpg" }
        package.loaded["ui/renderimage"].renderImageData = function(_, data)
            received = data
            return { free = function() end }
        end
        local halt = start_cover_queue({{
            entry = entry,
            widget = { update = function() updated = updated + 1 end },
            cover_w = 80, cover_h = 120,
        }})
        scheduled[1].callback()
        local poll = scheduled[2].callback
        poll()
        assert.are.equal(0, updated)
        assert.are.equal(1, standby)
        for _i = 1, 20 do
            native_util.usleep(50000)
            poll()
            if updated > 0 then break end
        end
        halt()
        assert.are.equal(1, updated)
        assert.are.equal(#bytes, received and #received)
        assert.are.equal(bytes, received)
        assert.are.equal(0, standby)
    end)

    it("skips failed workers and empty responses without holding standby", function()
        local start_cover_queue = get_upvalue(Browser.updateItems, "start_cover_queue")
        local cover_cache = get_upvalue(start_cover_queue, "_cover_cache")
        local updated = 0
        for _i, failure in ipairs({ "fork", "http" }) do
            spawn_failed = failure == "fork"
            pipe_bytes, pipe_size = "", 0
            local entry = { cover_url = "https://example.test/" .. failure .. ".jpg" }
            start_cover_queue({{
                entry = entry,
                widget = { update = function() updated = updated + 1 end },
                cover_w = 80, cover_h = 120,
            }})
            scheduled[#scheduled].callback()
            if not spawn_failed then scheduled[#scheduled].callback() end
            assert.is_true(cover_cache[entry.cover_url].failed)
            assert.is_nil(entry.cover_bb)
            assert.are.equal(0, standby)
        end
        assert.are.equal(0, updated)
        assert.are.equal(2, subprocess_runs)
    end)
end)
