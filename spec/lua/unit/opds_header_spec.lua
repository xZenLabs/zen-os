describe("OPDS header", function()
    local Browser, closed, existing_files, inventory_paths, menu_opened, returned, saved, searched
    local scheduled, subprocess_runs, trapper_wraps, unscheduled
    local process_done, spawn_failed, pipe_size, pipe_bytes, pipe_reads, fd_closes, terminated, standby
    local native_ffi, native_util
    local NetworkMgr, catalog_requests, next_pages, connection_requests, connection_callback, network_notices
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

        Browser = {
            getPageNumber = function() return 1 end,
            mergeTitleBarIntoLayout = function() end,
            updatePageInfo = function() end,
            parseFeed = function() end,
            genItemTableFromCatalog = function(self) return self.catalog_items or {} end,
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
        ZenSpec.replace("opdsparser", { parse = function() return {} end })
        ZenSpec.replace("common/cover_utils", {
            BORDER_SIZE = 1,
            getRatio = function() return 2 / 3 end,
        })
        ZenSpec.replace("common/utils", {
            resolveLocalIcon = function(dir, name) return dir .. name .. ".svg" end,
        })
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

    it("keeps back, search, and close together in a focusable header row", function()
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
        assert.are.equal(3, #buttons)
        assert.are.equal("back", buttons[1]._zen_opds_focus_id)
        assert.are.equal("search", buttons[2]._zen_opds_focus_id)
        assert.are.equal("close", buttons[3]._zen_opds_focus_id)
        assert.are.equal("/zen-ui/icons/tab_left.svg", buttons[1].file)
        assert.are.equal("/zen-ui/icons/quick_search.svg", buttons[2].file)
        assert.are.equal("/zen-ui/icons/close.svg", buttons[3].file)
        assert.are.equal("chevron.left", browser.title_bar.left_icon)
        assert.are.equal("close", browser.title_bar.right_icon)
        assert.are.equal("left", buttons[1].overlap_align)
        assert.are.equal("right", buttons[3].overlap_align)
        assert.is_true(browser.layout[1] == buttons)
        assert.is_true(browser.layout[2][1] == browser.item)
        assert.are.same({ x = 1, y = 2 }, browser.selected)

        buttons[1].callback()
        buttons[2].callback()
        buttons[3].callback()
        assert.are.equal(1, returned)
        assert.are.equal(1, searched)
        assert.are.equal(1, closed)

        browser:updateCatalog("/next")
        assert.are.equal(3, #browser.layout[1])
        assert.are.equal("back", browser.layout[1][1]._zen_opds_focus_id)
        assert.are.equal("search", browser.layout[1][2]._zen_opds_focus_id)
        assert.are.equal("close", browser.layout[1][3]._zen_opds_focus_id)
        assert.are.equal("chevron.left", browser.title_bar.left_icon)
        assert.are.equal("close", browser.title_bar.right_icon)
        assert.is_true(browser.layout[2][1] == browser.item)

        browser.search_url = nil
        browser:updateCatalog("/without-search")
        assert.are.equal("menu", browser.layout[1][2]._zen_opds_focus_id)
        browser.layout[1][2].callback()
        assert.are.equal(1, menu_opened)

        -- appendCatalog changes the title, which rebuilds TitleBar without fix_buttons.
        browser.title_bar:clear()
        browser.title_bar:init()
        assert.are.equal("chevron.left", browser.title_bar.left_button.icon)
        assert.are.equal("close", browser.title_bar.right_button.icon)
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
        browser._zen_opds_header_buttons[2].callback()

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
