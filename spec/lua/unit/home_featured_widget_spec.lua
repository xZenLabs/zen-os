describe("home featured widget", function()
    local created
    local cover_calls
    local description_split
    local empty_sources
    local cover_ratio
    local html_content

    local function widget_class(kind)
        return {
            new = function(_, values)
                values = values or {}
                values.kind = kind
                local width = values.width
                local height = values.height
                if not width or not height then
                    local child_w, child_h = 0, 0
                    for _i, child in ipairs(values) do
                        local size = child.getSize and child:getSize() or child.dimen or {}
                        child_w = child_w + (size.w or 0)
                        child_h = math.max(child_h, size.h or 0)
                    end
                    width = width or (values.text and #values.text * 6) or child_w
                    height = height or child_h
                end
                values.dimen = values.dimen or { x = 0, y = 0, w = width or 1, h = height or 12 }
                values.getSize = values.getSize or function(self) return self.dimen end
                values.free = values.free or function(self) self.freed = true end
                if kind == "ui/widget/textboxwidget" and description_split
                        and values.text == description_split.text
                        and values.width == description_split.width
                        and values.height
                        and values.height_overflow_show_ellipsis == nil then
                    description_split.used = true
                    description_split.probe_line_height = values.line_height
                    description_split.probe_height = values.height
                    description_split.probe_heights = description_split.probe_heights or {}
                    table.insert(description_split.probe_heights, values.height)
                    local upper_end = description_split.upper_end
                    local lower_start = description_split.lower_start
                    if description_split.min_height
                            and values.height < description_split.min_height then
                        upper_end = description_split.short_upper_end
                        lower_start = description_split.short_lower_start
                    end
                    values.lines_per_page = 1
                    values.vertical_string_list = {
                        { offset = 1, end_offset = upper_end },
                        { offset = lower_start, end_offset = #values.text },
                    }
                end
                created[#created + 1] = values
                return values
            end,
        }
    end

    before_each(function()
        created = {}
        cover_calls = {}
        description_split = nil
        empty_sources = {}
        cover_ratio = 2 / 3
        html_content = nil
        rawset(_G, "__ZEN_UI_SET_OPENING_BANNER_COVER", nil)
        ZenSpec.replace("common/ui/background", { tile_bg = function(color) return color end })
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_BLACK = "black", COLOR_GRAY_5 = "gray5",
            COLOR_LIGHT_GRAY = "lightgray", COLOR_WHITE = "white",
        })
        ZenSpec.replace("ui/geometry", {
            new = function(_, values)
                function values:contains(pos)
                    return pos.x >= (self.x or 0) and pos.x < (self.x or 0) + self.w
                        and pos.y >= (self.y or 0) and pos.y < (self.y or 0) + self.h
                end
                return values
            end,
        })
        for _i, name in ipairs({
            "ui/widget/horizontalgroup", "ui/widget/horizontalspan",
            "ui/widget/textboxwidget", "ui/widget/textwidget",
            "ui/widget/verticalgroup", "ui/widget/verticalspan",
            "ui/widget/container/centercontainer", "ui/widget/container/framecontainer",
            "ui/widget/container/inputcontainer", "ui/widget/container/topcontainer",
        }) do
            ZenSpec.replace(name, widget_class(name))
        end
        ZenSpec.replace("ui/widget/htmlboxwidget", {
            new = function(_self, values)
                local widget = widget_class("ui/widget/htmlboxwidget"):new(values)
                widget.setContent = function(_widget, body, css, font_size)
                    html_content = { body = body, css = css, font_size = font_size }
                end
                return widget
            end,
        })
        ZenSpec.replace("ui/gesturerange", widget_class("gesture"))
        ZenSpec.replace("device", {
            screen = {
                scaleBySize = function(_, value) return value end,
                getWidth = function() return 800 end,
                getHeight = function() return 600 end,
            },
            isTouchDevice = function() return false end,
        })
        ZenSpec.replace("ui/font", {
            getFace = function(_, name, size) return { name = name, size = size or 12 } end,
        })
        ZenSpec.replace("util", {
            htmlToPlainTextIfHtml = function(text) return text:gsub("<.->", "") end,
            splitToChars = function(text)
                local chars = {}
                for char in text:gmatch(".") do chars[#chars + 1] = char end
                return chars
            end,
        })
        ZenSpec.replace("common/utils", { formatPageCount = function(pages) return pages .. " pages" end })
        ZenSpec.replace("modules/filebrowser/patches/library_font", {
            getFontName = function() return "LibraryFont" end,
            getScale = function() error("home widget used library font size") end,
            scaleValue = function() error("home widget used library font size") end,
        })
        ZenSpec.replace("modules/filebrowser/patches/home/widgets/cover_common", {
            uniform_height_for_width = function(width)
                return math.floor(width / cover_ratio)
            end,
            make_cover_widget = function(book, max_w, max_h, opts)
                cover_calls[#cover_calls + 1] = { book = book, max_w = max_w, max_h = max_h, opts = opts }
                local width, height
                if max_h * cover_ratio <= max_w then
                    width, height = math.floor(max_h * cover_ratio), max_h
                else
                    width, height = max_w, math.floor(max_w / cover_ratio)
                end
                local cover = widget_class("cover"):new{ width = width, height = height }
                return cover, width, height
            end,
            make_empty_cover_widget = function(source, max_w, max_h, opts)
                empty_sources[#empty_sources + 1] = source
                cover_calls[#cover_calls + 1] = {
                    book = { is_empty_placeholder = true },
                    max_w = max_w,
                    max_h = max_h,
                    opts = opts,
                }
                local cover = widget_class("cover"):new{ width = 90, height = 135 }
                return cover, 90, 135
            end,
        })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.unload("common/widget_resources")
        ZenSpec.unload("common/ui/book_progress")
        ZenSpec.unload("modules/filebrowser/patches/home/widgets/featured")
        ZenSpec.unload("modules/filebrowser/patches/home/widgets/featured_common")
    end)

    local function has_text(expected)
        for _i, widget in ipairs(created) do
            if widget.text == expected then return true end
        end
        return false
    end

    local function text_widget(expected)
        for _i, widget in ipairs(created) do
            if widget.kind == "ui/widget/textboxwidget" and widget.text == expected then return widget end
        end
    end

    local function progress_bar_width(left_text, right_text)
        for _i, widget in ipairs(created) do
            if widget.kind == "ui/widget/horizontalgroup"
                    and widget[1] and widget[1].text == left_text
                    and widget[5] and widget[5].text == right_text then
                return widget[3] and widget[3].dimen and widget[3].dimen.w
            end
        end
    end

    local function progress_bar_height(left_text, right_text)
        for _i, widget in ipairs(created) do
            if widget.kind == "ui/widget/horizontalgroup"
                    and widget[1] and widget[1].text == left_text
                    and widget[5] and widget[5].text == right_text then
                return widget[3] and widget[3].dimen and widget[3].dimen.h
            end
        end
    end

    it("renders the recent book cover, title, author, and description", function()
        local opened
        local actions
        local book = {
            path = "/library/alpha.epub",
            title = "Alpha",
            authors = "Zen Author",
            series = "Zen Chronicles",
            series_index = 3,
            description = "<p>A deterministic description.</p>",
            status = "reading",
            percent = 0.25,
            pages = 120,
        }
        local Featured = require("modules/filebrowser/patches/home/widgets/featured_common")
        local FeaturedComponent = require("modules/filebrowser/patches/home/widgets/featured")
        assert.are.same({ units = 3.5 }, Featured.SIZE)
        assert.are.equal(369, FeaturedComponent.preferredHeight{ width = 600, module_cfg = {} })
        cover_ratio = 3 / 4
        assert.are.equal(330, FeaturedComponent.preferredHeight{ width = 600, module_cfg = {} })
        cover_ratio = 2 / 3
        assert.is_nil(FeaturedComponent.preferredHeight{
            width = 600,
            module_cfg = { wrap_description_text = true },
        })
        assert.are.equal(369, FeaturedComponent.preferredHeight{
            width = 600,
            module_cfg = { wrap_description_text = true },
            data = { getFeaturedBook = function() return nil end },
        })
        assert.is_nil(FeaturedComponent.preferredHeight{
            width = 600,
            module_cfg = { wrap_description_text = true },
            data = { getFeaturedBook = function(_self, _source, _order, metadata_only)
                assert.is_true(metadata_only)
                return { description = "Description that may overflow." }
            end },
        })
        assert.are.equal(369, FeaturedComponent.preferredHeight{
            width = 600,
            module_cfg = {
                wrap_description_text = true,
                show_description = false,
            },
        })
        local widget = Featured.build({
            width = 600,
            height = 220,
            face_label = { size = 12 },
            module_cfg = { show_description = true, progress_meta = { left = "percent", right = "total_pages" } },
            data = { getFeaturedBook = function(_, source) assert.are.equal("recently_read", source); return book end },
            setWidgetActions = function(value) actions = value end,
            openBook = function(path) opened = path end,
        }, "recently_read")

        assert.is_table(widget)
        assert.are.equal("ui/widget/container/centercontainer", widget[1].kind)
        assert.are.equal("ui/widget/container/topcontainer", widget[1][1].kind)
        assert.are.equal(1, #cover_calls)
        assert.are.equal(book, cover_calls[1].book)
        assert.is_true(has_text("Alpha"))
        assert.equals("LibraryFont", text_widget("Alpha").face.name)
        assert.is_true(has_text("Zen Author"))
        assert.is_true(has_text("Zen Chronicles #3"))
        assert.is_true(text_widget("Zen Chronicles #3").face.size < text_widget("Zen Author").face.size)
        assert.is_true(has_text("A deterministic description."))
        assert.equals(16, text_widget("A deterministic description.").face.size)
        assert.is_true(text_widget("A deterministic description.").width < 600 - 8 * 2)
        for _i, text in ipairs({ "Alpha", "Zen Author", "Zen Chronicles #3", "A deterministic description." }) do
            local text_box = text_widget(text)
            assert.equals("left", text_box.alignment)
            assert.is_true(text_box.alignment_strict)
        end
        assert.is_true(has_text("25%"))
        assert.is_true(has_text("120 pages"))
        assert.is_true(actions.activate())
        assert.are.equal(book.path, opened)
    end)

    it("caps the cover width and keeps the default layout at cover height", function()
        local Featured = require("modules/filebrowser/patches/home/widgets/featured_common")
        local content_bounds
        Featured.build({
            width = 600,
            height = 600,
            module_cfg = {},
            data = {
                getFeaturedBook = function()
                    return { path = "/library/alpha.epub", title = "Alpha", status = "new" }
                end,
            },
            setContentBounds = function(bounds) content_bounds = bounds end,
        }, "recently_read")

        local content_w = 600 - 8 * 2
        local gap = math.max(4, math.floor(content_w * 0.025))
        assert.are.equal(math.floor((content_w - gap) * 0.40), cover_calls[1].max_w)

        local cover_w = math.floor((content_w - gap) * 0.40)
        local detail_w = content_w - cover_w - gap
        local detail_h = math.floor(cover_w * 3 / 2)
        local detail
        for _i, widget in ipairs(created) do
            if widget.kind == "ui/widget/container/framecontainer"
                    and widget.width == detail_w then
                detail = widget
            end
        end
        assert.is_table(detail)
        assert.are.equal(detail_h, detail.height)
        assert.is_true(content_bounds.bottom < 600)
    end)

    it("keeps the same top inset across featured row heights", function()
        local Featured = require("modules/filebrowser/patches/home/widgets/featured_common")
        local tops = {}
        for _i, height in ipairs({ 220, 600 }) do
            Featured.build({
                width = 600,
                height = height,
                module_cfg = {},
                data = {
                    getFeaturedBook = function()
                        return { path = "/library/alpha.epub", title = "Alpha", status = "new" }
                    end,
                },
                setContentBounds = function(bounds)
                    tops[#tops + 1] = bounds.top
                end,
            }, "recently_read")
        end

        assert.are.same({ 12, 12 }, tops)
    end)

    it("wraps actual description overflow below the cover when enabled", function()
        local description = "Upper text fascinating science.\nLower continuation fills the remaining width."
        description_split = {
            text = description,
            width = 342,
            min_height = 317,
            short_upper_end = 10,
            short_lower_start = 12,
            upper_end = 31,
            lower_start = 32,
        }
        local Featured = require("modules/filebrowser/patches/home/widgets/featured_common")
        Featured.build({
            width = 600,
            height = 600,
            module_cfg = {
                wrap_description_text = true,
                progress_meta = { left = "percent", right = "total_pages" },
            },
            data = {
                getFeaturedBook = function()
                    return {
                        path = "/library/alpha.epub",
                        title = "Alpha",
                        description = description,
                        status = "reading",
                        percent = 0.25,
                        pages = 120,
                    }
                end,
            },
        }, "recently_read")

        local top_row
        for _i, widget in ipairs(created) do
            if widget.kind == "ui/widget/horizontalgroup"
                    and widget[1] and widget[1].kind == "cover" then
                top_row = widget
            end
        end
        assert.is_table(top_row)
        assert.is_true(description_split.used)
        assert.is_nil(description_split.probe_line_height)
        assert.are.same({ 299, 317 }, description_split.probe_heights)
        assert.are.equal(342, text_widget("Upper text fascinating science.").width)
        assert.are.equal(584, text_widget("Lower continuation fills the remaining width.").width)
        assert.are.equal(212, text_widget("Lower continuation fills the remaining width.").height)
        assert.are.equal(490, progress_bar_width("25%", "120 pages"))
        assert.are.equal(7, progress_bar_height("25%", "120 pages"))
    end)

    it("keeps the description and progress beside the cover by default", function()
        local description = "Upper text fascinating science. Lower continuation fills the remaining width."
        description_split = {
            text = description,
            width = 342,
            upper_end = 31,
            lower_start = 32,
        }
        local Featured = require("modules/filebrowser/patches/home/widgets/featured_common")
        Featured.build({
            width = 600,
            height = 600,
            module_cfg = {
                progress_meta = { left = "percent", right = "total_pages" },
            },
            data = {
                getFeaturedBook = function()
                    return {
                        path = "/library/alpha.epub",
                        title = "Alpha",
                        description = description,
                        status = "reading",
                        percent = 0.25,
                        pages = 120,
                    }
                end,
            },
        }, "recently_read")

        assert.is_nil(description_split.used)
        assert.are.equal(342, text_widget(description).width)
        assert.are.equal(258, progress_bar_width("25%", "120 pages"))
    end)

    it("keeps an enabled fitting description and progress beside the cover", function()
        local Featured = require("modules/filebrowser/patches/home/widgets/featured_common")
        Featured.build({
            width = 600,
            height = 600,
            module_cfg = {
                wrap_description_text = true,
                progress_meta = { left = "percent", right = "total_pages" },
            },
            data = {
                getFeaturedBook = function()
                    return {
                        path = "/library/alpha.epub",
                        title = "Alpha",
                        description = "Short description.",
                        status = "reading",
                        percent = 0.25,
                        pages = 120,
                    }
                end,
            },
        }, "recently_read")

        assert.are.equal(342, text_widget("Short description.").width)
        assert.are.equal(258, progress_bar_width("25%", "120 pages"))
    end)

    it("applies the configured series text style independently", function()
        local Featured = require("modules/filebrowser/patches/home/widgets/featured_common")
        Featured.build({
            width = 600,
            height = 220,
            face_label = { size = 12 },
            module_cfg = {
                text_styles = {
                    series = { font_face = "SeriesFont", font_size = 14, bold = true },
                },
            },
            data = {
                getFeaturedBook = function()
                    return {
                        path = "/library/alpha.epub",
                        title = "Alpha",
                        authors = "Zen Author",
                        series = "Zen Chronicles",
                        series_index = 3,
                        status = "new",
                    }
                end,
            },
        }, "recently_read")

        local series = text_widget("Zen Chronicles #3")
        assert.is_table(series)
        assert.equals("SeriesFont", series.face.name)
        assert.is_true(series.bold)
    end)

    it("hides author and series independently", function()
        local Featured = require("modules/filebrowser/patches/home/widgets/featured_common")
        Featured.build({
            width = 600,
            height = 220,
            module_cfg = { show_author = false, show_series = false },
            data = {
                getFeaturedBook = function()
                    return {
                        path = "/library/alpha.epub",
                        title = "Alpha",
                        authors = "Zen Author",
                        series = "Zen Chronicles",
                        series_index = 3,
                        status = "new",
                    }
                end,
            },
        }, "recently_read")

        assert.is_false(has_text("Zen Author"))
        assert.is_false(has_text("Zen Chronicles #3"))
    end)

    it("justifies plain descriptions", function()
        local Featured = require("modules/filebrowser/patches/home/widgets/featured_common")
        Featured.build({
            width = 600,
            height = 220,
            module_cfg = { justify_description_text = true },
            data = {
                getFeaturedBook = function()
                    return {
                        path = "/library/alpha.epub",
                        title = "Alpha",
                        description = "A justified description.",
                        status = "new",
                    }
                end,
            },
        }, "recently_read")

        assert.is_true(text_widget("A justified description.").justified)
    end)

    it("renders wrapped description HTML intact when enabled", function()
        description_split = {
            text = "A formatted description.",
            width = 342,
            upper_end = 5,
            lower_start = 7,
        }
        local Featured = require("modules/filebrowser/patches/home/widgets/featured_common")
        Featured.build({
            width = 600,
            height = 600,
            module_cfg = {
                format_description_html = true,
                justify_description_text = true,
                wrap_description_text = true,
                text_styles = {
                    description = { font_face = "/fonts/Description.ttf", font_size = 16 },
                },
            },
            data = {
                getFeaturedBook = function()
                    return {
                        path = "/library/alpha.epub",
                        title = "Alpha",
                        description = "<p>A <strong>formatted</strong> description.</p>",
                        status = "new",
                    }
                end,
            },
        }, "recently_read")

        assert.is_true(description_split.used)
        assert.are.equal("<p>A <strong>formatted</strong> description.</p>", html_content.body)
        assert.matches("/fonts/Description%.ttf", html_content.css)
        assert.matches("text%-align: justify", html_content.css)
        assert.are.equal(16, html_content.font_size)
    end)

    it("uses the configured unified source", function()
        local requested_source
        local Featured = require("modules/filebrowser/patches/home/widgets/featured_common")
        Featured.build({
            width = 600,
            height = 220,
            module_cfg = { default_source = { kind = "to_be_read" } },
            data = {
                getFeaturedBook = function(_, source)
                    requested_source = source
                    return nil
                end,
            },
        })

        assert.are.equal("to_be_read", requested_source)
        assert.are.same({ "to_be_read" }, empty_sources)
    end)

    it("applies the configured progress-label text style", function()
        local Featured = require("modules/filebrowser/patches/home/widgets/featured_common")
        Featured.build({
            width = 600,
            height = 220,
            module_cfg = {
                progress_meta = { left = "percent", right = "total_pages" },
                text_styles = {
                    progress = { font_face = "ProgressFont", font_size = 12, bold = true },
                },
            },
            data = {
                getFeaturedBook = function()
                    return {
                        path = "/library/alpha.epub",
                        title = "Alpha",
                        status = "reading",
                        percent = 0.25,
                        pages = 120,
                    }
                end,
            },
        }, "recently_read")

        local labels = 0
        for _i, widget in ipairs(created) do
            if widget.text == "25%" or widget.text == "120 pages" then
                labels = labels + 1
                assert.equals("ProgressFont", widget.face.name)
                assert.equals(8, widget.face.size)
                assert.is_true(widget.bold)
            end
        end
        assert.equals(2, labels)
    end)

    it("hides the complete progress row when disabled", function()
        local Featured = require("modules/filebrowser/patches/home/widgets/featured_common")
        Featured.build({
            width = 600,
            height = 220,
            module_cfg = {
                show_progress = false,
                progress_meta = { left = "percent", right = "total_pages" },
            },
            data = {
                getFeaturedBook = function()
                    return {
                        path = "/library/alpha.epub",
                        title = "Alpha",
                        status = "reading",
                        percent = 0.25,
                        pages = 120,
                    }
                end,
            },
        }, "recently_read")

        assert.is_false(has_text("25%"))
        assert.is_false(has_text("120 pages"))
        assert.is_nil(progress_bar_width("25%", "120 pages"))
    end)

    it("supplies the featured cover before opening its book", function()
        local captured_cover
        rawset(_G, "__ZEN_UI_SET_OPENING_BANNER_COVER", function(cover)
            captured_cover = cover
        end)
        local book = { path = "/library/alpha.epub", title = "Alpha" }
        local actions
        local Featured = require("modules/filebrowser/patches/home/widgets/featured_common")
        Featured.build({
            width = 600,
            height = 220,
            face_label = { size = 12 },
            module_cfg = {},
            data = { getFeaturedBook = function() return book end },
            setWidgetActions = function(value) actions = value end,
            openBook = function() end,
        }, "recently_read")

        assert.is_true(actions.activate())
        assert.are.equal(cover_calls[1].book, book)
        assert.is_not_nil(captured_cover)
    end)

    it("renders an empty recent-history state", function()
        local Featured = require("modules/filebrowser/patches/home/widgets/featured_common")
        local widget = Featured.build({
            width = 500,
            height = 180,
            face_label = { size = 12 },
            module_cfg = {},
            data = { getFeaturedBook = function() return nil end },
        }, "recently_read")

        assert.is_table(widget)
        assert.are.same({ "recently_read" }, empty_sources)
        assert.are.equal(1, #cover_calls)
    end)
end)
