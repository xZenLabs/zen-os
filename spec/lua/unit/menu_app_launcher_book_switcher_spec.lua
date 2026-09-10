describe("app launcher book switcher page", function()
    local originals

    local function replace(name, module)
        if originals[name] == nil then
            originals[name] = package.loaded[name] == nil and false or package.loaded[name]
        end
        package.loaded[name] = module
    end

    local function widget_class(kind, created)
        local class = {}
        class.__index = class

        function class:extend(values)
            values = values or {}
            values.__index = values
            return setmetatable(values, { __index = self })
        end

        function class:new(values)
            values = values or {}
            values.kind = kind
            values.dimen = values.dimen or {
                x = 0,
                y = 0,
                w = values.width or 1,
                h = values.height or 1,
            }
            values.getSize = values.getSize or function(widget)
                if widget.text then return { w = #widget.text * 6, h = 12 } end
                return widget.dimen
            end
            values.paintTo = values.paintTo or function() end
            values.free = values.free or function() end
            setmetatable(values, { __index = self })
            if created then created[#created + 1] = values end
            if values.init then values:init() end
            return values
        end

        return class
    end

    before_each(function()
        originals = {}
        ZenSpec.unload("modules/menu/app_launcher/book_switcher_page")
        ZenSpec.unload("modules/menu/app_launcher/store")
        rawset(_G, "__ZEN_UI_SET_OPENING_BANNER_COVER", nil)
        rawset(_G, "__ZEN_UI_CANCEL_OPENING_BANNER", nil)
    end)

    after_each(function()
        rawset(_G, "__ZEN_UI_SET_OPENING_BANNER_COVER", nil)
        rawset(_G, "__ZEN_UI_CANCEL_OPENING_BANNER", nil)
        ZenSpec.unload("modules/menu/app_launcher/book_switcher_page")
        ZenSpec.unload("modules/menu/app_launcher/store")
        for name, original in pairs(originals) do
            package.loaded[name] = original == false and nil or original
        end
    end)

    it("places the optional page from page order and honors reader-only visibility", function()
        local Page = require("modules/menu/app_launcher/book_switcher_page")
        local cfg = {
            show_book_switcher = true,
            page_order = { "buttons", "book_switcher", "book_details" },
        }

        assert.are.equal(3, Page.pagePosition(cfg, false, 2))
        cfg.page_order = { "book_switcher", "buttons", "book_details" }
        assert.are.equal(1, Page.pagePosition(cfg, false, 2))
        cfg.book_switcher_reader_only = true
        assert.is_nil(Page.pagePosition(cfg, true, 2))
        assert.are.equal(1, Page.pagePosition(cfg, false, 2))
        cfg.show_book_switcher = false
        assert.is_nil(Page.pagePosition(cfg, false, 2))
    end)

    it("maps the library cover renderer settings onto the page", function()
        local Page = require("modules/menu/app_launcher/book_switcher_page")
        assert.are.same({ uniform = true, show_title = true, show_author = false },
            Page.rendererOptions({
                features = { browser_cover_mosaic_uniform = true },
                mosaic_title_strip = { show_title = true, show_author = false },
            }))
        assert.are.same({ uniform = false, show_title = false, show_author = true },
            Page.rendererOptions({
                features = { browser_cover_mosaic_uniform = false },
                mosaic_title_strip = { show_author = true },
            }))
    end)

    it("defaults and normalizes the recent page settings", function()
        local settings_file = { data = {} }
        function settings_file:flush() self.flushed = true end
        replace("luasettings", {
            open = function(_, path)
                assert.are.equal("/settings/app_launcher.lua", path)
                return settings_file
            end,
        })
        replace("config/preset_store", { rootDir = function() return "/settings" end })

        local Store = require("modules/menu/app_launcher/store")
        local cfg = Store.load()
        assert.is_false(cfg.show_book_switcher)
        assert.is_false(cfg.book_switcher_reader_only)
        assert.is_false(cfg.show_book_details)
        assert.are.same({ "book_details", "book_switcher", "buttons" }, cfg.page_order)
        assert.are.same({
            "read_time", "time_remaining", "pages_today", "time_today", "pages", "progress",
        }, cfg.book_details_order)
        assert.are.same({
            read_time = true,
            time_remaining = true,
            pages_today = false,
            time_today = false,
            pages = true,
            progress = true,
        }, cfg.book_details_enabled)

        cfg.show_book_switcher = true
        cfg.book_switcher_first = true
        cfg.book_switcher_reader_only = true
        cfg.show_book_details = true
        cfg.book_details_first = true
        cfg.page_order = { "buttons", "unknown", "buttons" }
        cfg.book_details_order = { "pages", "unknown", "pages", "read_time" }
        cfg.book_details_enabled = {
            read_time = false,
            time_remaining = "invalid",
            pages = false,
            unknown = false,
        }
        Store.save(cfg)
        assert.is_true(settings_file.flushed)
        assert.is_true(settings_file.data.show_book_switcher)
        assert.is_true(settings_file.data.book_switcher_reader_only)
        assert.is_true(settings_file.data.show_book_details)
        assert.is_nil(settings_file.data.book_switcher_first)
        assert.is_nil(settings_file.data.book_details_first)
        assert.are.same({ "buttons", "book_details", "book_switcher" },
            settings_file.data.page_order)
        assert.are.same({
            "pages", "read_time", "time_remaining", "pages_today", "time_today", "progress",
        }, settings_file.data.book_details_order)
        assert.are.same({
            read_time = false,
            time_remaining = true,
            pages_today = false,
            time_today = false,
            pages = false,
            progress = true,
        }, settings_file.data.book_details_enabled)
        assert.is_nil(settings_file.data.book_details_enabled.unknown)
    end)

    it("migrates the removed first-page preference into page order", function()
        local settings_file = {
            data = {
                entries = {},
                show_book_switcher = true,
                book_switcher_first = true,
            },
        }
        function settings_file:flush() end
        replace("luasettings", { open = function() return settings_file end })
        replace("config/preset_store", { rootDir = function() return "/settings" end })

        local cfg = require("modules/menu/app_launcher/store").load()
        assert.are.same({ "book_switcher", "buttons", "book_details" }, cfg.page_order)
        assert.is_nil(cfg.book_switcher_first)
    end)

    it("loads four non-image library and Kindle alternatives with cover metadata", function()
        local reload_args
        local freed = 0
        local copied = 0
        local function cover()
            return {
                copy = function()
                    copied = copied + 1
                    return { copied = true }
                end,
                free = function() freed = freed + 1 end,
            }
        end
        replace("readhistory", {
            hist = {
                { file = "/downloads/outside.epub" },
                { file = "/books/cover.JPEG" },
                { file = "/kindle/cache.epub" },
                { file = "/books/one.epub" },
                { file = "/books/missing.epub" },
                { file = "/books/one.epub" },
                { file = "/additional/two.cbz" },
                { file = "/books/three.pdf" },
                { file = "/books/four.epub" },
                { file = "/books/five.epub" },
            },
            reload = function(_, value) reload_args = value end,
        })
        replace("libs/libkoreader-lfs", {
            attributes = function(path)
                if path == "/books/missing.epub" or path == "/kindle/cache.epub" then
                    return nil
                end
                return "file"
            end,
        })
        replace("common/paths", {
            isInHomeDir = function(path)
                return path:sub(1, 7) == "/books/"
                    or path:sub(1, 12) == "/additional/"
            end,
        })
        replace("bookinfomanager", {
            getBookInfo = function(_, path, with_cover)
                assert.is_true(with_cover)
                return {
                    title = path:match("([^/]+)"),
                    authors = "Author",
                    cover_fetched = true,
                    has_cover = true,
                    cover_w = 400,
                    cover_h = 600,
                    cover_bb = cover(),
                }
            end,
        })
        replace("modules/filebrowser/patches/rakuyomi", {
            getMetadata = function(path)
                if path == "/additional/two.cbz" then return { title = "Chapter Two" } end
            end,
        })
        replace("modules/filebrowser/patches/kindle_virtual_library", {
            isBookPath = function(path) return path == "/kindle/cache.epub" end,
        })

        local Page = require("modules/menu/app_launcher/book_switcher_page")
        local books = Page.loadBooks(4, "/books/one.epub")

        assert.is_false(reload_args)
        assert.are.same({
            "/kindle/cache.epub", "/additional/two.cbz", "/books/three.pdf", "/books/four.epub",
        }, { books[1].path, books[2].path, books[3].path, books[4].path })
        assert.are.equal("Chapter Two", books[2].title)
        assert.are.same({ copied = true }, books[1].cover_bb)
        assert.are.equal(4, copied)
        assert.are.equal(4, freed)
    end)

    it("ties the opening banner to the selected cover", function()
        local created = {}
        local cover_options = {}
        local banner_cover
        local banner_released
        local opened
        local InputContainer = widget_class("input", created)
        local names = {
            "ui/widget/container/centercontainer",
            "ui/widget/horizontalgroup",
            "ui/widget/horizontalspan",
            "ui/widget/textboxwidget",
            "ui/widget/textwidget",
            "ui/widget/verticalgroup",
        }
        for _i, name in ipairs(names) do replace(name, widget_class(name, created)) end
        replace("ui/widget/container/inputcontainer", InputContainer)
        replace("ui/geometry", { new = function(_, values) return values end })
        replace("ui/gesturerange", widget_class("gesture"))
        replace("ffi/blitbuffer", {
            COLOR_BLACK = "black",
            COLOR_WHITE = "white",
            COLOR_LIGHT_GRAY = "lightgray",
        })
        replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
                scaleBySize = function(_, value) return value end,
            },
        })
        replace("ui/font", {
            getFace = function(_, name, size) return { name = name, size = size } end,
        })
        replace("ui/uimanager", { setDirty = function() end })
        replace("modules/filebrowser/patches/library_font", {
            getFace = function(size) return { size = size } end,
            scaleValue = function(value) return value end,
        })
        replace("modules/filebrowser/patches/home/widgets/cover_common", {
            BORDER_SIZE = 2,
            make_cover_widget = function(book, width, height, options)
                cover_options[#cover_options + 1] = {
                    book = book,
                    width = width,
                    height = height,
                    options = options,
                }
                return widget_class("cover"):new{ width = width, height = height }
            end,
        })
        replace("gettext", function(text) return text end)
        rawset(_G, "__ZEN_UI_SET_OPENING_BANNER_COVER", function(cover)
            banner_cover = cover
            return true
        end)
        rawset(_G, "__ZEN_UI_CANCEL_OPENING_BANNER", function(suppress_next_open)
            banner_released = suppress_next_open
        end)

        local books = {
            { path = "/books/one.epub", title = "One", authors = "First" },
            { path = "/books/two.epub", title = "Two", authors = "Second" },
            { path = "/books/three.epub", title = "Three", authors = "Third" },
            { path = "/books/four.epub", title = "Four", authors = "Fourth" },
        }
        local Page = require("modules/menu/app_launcher/book_switcher_page")
        local panel, refs = Page.build({
            width = 600,
            height = 500,
            books = books,
            config = {
                features = { browser_cover_mosaic_uniform = false },
                mosaic_title_strip = { show_title = true, show_author = true },
            },
            open_book = function(path, cover, release_cover)
                release_cover()
                opened = {
                    path = path,
                    cover = cover,
                    banner = banner_cover,
                    released = banner_released,
                }
            end,
        })

        assert.is_table(panel)
        assert.are.equal(16, panel[1].width)
        assert.are.equal(4, #refs.buttons)
        assert.are.equal(4, #refs.layout_rows[1])
        assert.is_false(cover_options[1].options.uniform)
        assert.are.equal(144, refs.buttons[1].widget.width)
        assert.are.equal(140, cover_options[1].width)
        assert.are.equal(196, cover_options[1].height)
        assert.are.equal(232, refs.buttons[1].widget.height)
        assert.is_true(cover_options[1].height <= refs.buttons[1].widget[1][1].dimen.h)
        refs.buttons[2].callback()
        assert.are.equal(books[2].path, opened.path)
        assert.are.equal(opened.cover, opened.banner)
        assert.is_true(opened.released)
    end)
end)
