describe("reader book details", function()
    local shown
    local widget_spec
    local book_stats_result
    local book_stats_error
    local queried_fields
    local fallback_average
    local fallback_pages
    local fallback_read_time
    local fallback_path
    local home_tag
    local library_tag
    local saved_shared_state
    local saved_dispatch_action
    local home_tag_result

    before_each(function()
        shown = nil
        widget_spec = nil
        book_stats_result = {}
        book_stats_error = nil
        queried_fields = {}
        fallback_average = nil
        fallback_pages = nil
        fallback_read_time = nil
        fallback_path = nil
        home_tag = nil
        library_tag = nil
        home_tag_result = true
        saved_shared_state = package.loaded["common/shared_state"] or false
        saved_dispatch_action = package.loaded["common/dispatch_action"] or false
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("device", {
            screen = {
                getHeight = function() return 800 end,
            },
        })
        ZenSpec.replace("ui/font", {
            sizemap = { cfont = 20 },
        })
        ZenSpec.replace("ui/uimanager", {
            show = function(_, widget) shown = widget end,
        })
        ZenSpec.replace("common/cover_utils", {
            getRatio = function() return 2 / 3 end,
            makeCover = function(_path, _chooser, opts)
                assert.are.equal(160, opts.width)
                assert.are.equal(240, opts.height)
                return {}, 120, 180, "single", "real_cover"
            end,
        })
        ZenSpec.replace("modules/filebrowser/patches/library_font", {
            getFace = function(size) return { name = "LibraryFont", size = size } end,
        })
        ZenSpec.replace("common/reader_font", {
            getInfo = function() return { size = 21 } end,
        })
        ZenSpec.replace("common/utils", {
            formatPageCount = function(pages) return pages .. " pages" end,
            getStablePageCount = function() return nil end,
        })
        ZenSpec.replace("util", {
            htmlToPlainTextIfHtml = function(text) return text:gsub("<.->", "") end,
        })
        ZenSpec.replace("ui/language", {
            getLanguageName = function(_, code)
                return code == "en" and "English" or code
            end,
        })
        ZenSpec.replace("ui/widget/booklist", {
            getBookRatingString = function(rating) return "rating " .. rating end,
        })
        ZenSpec.replace("modules/reader/book_info_widget", {
            new = function(_, spec)
                widget_spec = spec
                return spec
            end,
        })
        ZenSpec.replace("common/db_stats", {
            queryBookDetails = function(_stats, fields)
                queried_fields[#queried_fields + 1] = fields
                if book_stats_error then error(book_stats_error) end
                return book_stats_result
            end,
            queryBookAveragePageTime = function(path)
                fallback_path = path
                return fallback_average, fallback_pages, fallback_read_time
            end,
        })
        ZenSpec.replace("common/shared_state", {
            get = function()
                return {
                    showTagInStrip = function(tag)
                        home_tag = tag
                        return home_tag_result
                    end,
                }
            end,
        })
        ZenSpec.replace("common/dispatch_action", {
            onShowZenUITag = function(_plugin, tag)
                library_tag = tag
                return true
            end,
        })
        ZenSpec.unload("modules/reader/book_details")
    end)

    after_each(function()
        ZenSpec.unload("modules/reader/book_details")
        package.loaded["common/shared_state"] = saved_shared_state or nil
        package.loaded["common/dispatch_action"] = saved_dispatch_action or nil
    end)

    local function reader_ui()
        local settings = {
            summary = { rating = 4, note = "" },
            annotations = { {}, {} },
            pagemap_use_page_labels = true,
            pagemap_doc_pages = 300,
            doc_pages = 240,
            percent_finished = 0.2,
        }
        return {
            document = {
                file = "/books/test.epub",
                getCurrentPage = function() return 42 end,
                getPageCount = function() return 100 end,
            },
            view = { footer = { percent_finished = 0.425, pageno = 42, pages = 100 } },
            doc_props = {
                title = "Test title",
                authors = "Test author",
                series = "Test series",
                series_index = 2,
                keywords = "First tag; Second tag",
                language = "en",
                description = "<p>Test description</p>",
            },
            doc_settings = {
                readSetting = function(_, key) return settings[key] end,
            },
            annotation = { annotations = { {}, {} } },
        }
    end

    it("builds the full details screen with live progress and stable pages", function()
        local BookDetails = require("modules/reader/book_details")
        local spec = BookDetails.buildSpec(reader_ui(), {
            config = { features = { browser_cover_rounded_corners = true } },
        })

        assert.are.equal("Book details", spec.title)
        assert.is_nil(spec.progress)
        assert.are.equal("Test title", spec.details[1].text)
        assert.are.equal("Test author", spec.details[2].text)
        assert.are.equal("Test series #2", spec.details[3].text)
        assert.are.equal("First tag, Second tag", spec.details[4].text)
        assert.are.equal("title", spec.details[1].style)
        assert.are.equal("author", spec.details[2].style)
        assert.are.equal("tags", spec.details[4].style)
        assert.are.equal("page", spec.details[8].style)
        assert.are.equal("English", spec.details[5].text)
        assert.are.equal("rating 4", spec.details[6].text)
        assert.are.equal("2 Annotations", spec.details[7].text)
        assert.are.equal("Page 128 of 300", spec.details[8].text)
        assert.are.equal("progress", spec.details[9].style)
        assert.are.equal(0.425, spec.details[9].progress)
        assert.are.equal(300, spec.details[9].pages)
        assert.are.equal("Test description", spec.description)
        assert.are.equal(120, spec.cover_width)
        assert.are.equal(180, spec.cover_height)
        assert.is_true(spec.rounded_cover)
        assert.are.equal(21, spec.text_face.size)
        assert.are.equal(19, spec.text_faces.author.size)
        assert.are.equal(19, spec.text_faces.tags.size)
        assert.are.equal(19, spec.text_faces.page.size)
        assert.are.equal(19, spec.text_faces.secondary.size)
        assert.are.equal(0, #queried_fields)
    end)

    it("applies every optional fullscreen visibility setting", function()
        local BookDetails = require("modules/reader/book_details")
        local spec = BookDetails.buildSpec(reader_ui(), {
            config = { book_details = {
                authors = false,
                series = false,
                tags = false,
                language = false,
                rating = false,
                annotations = false,
                note = false,
                pages = false,
                progress = false,
                description = false,
            } },
        })

        assert.are.equal(1, #spec.details)
        assert.are.equal("Test title", spec.details[1].text)
        assert.is_not_nil(spec.cover)
        assert.is_false(spec.show_description)
        assert.are.equal("", spec.description)
    end)

    it("opens tag buttons in the current library context", function()
        local BookDetails = require("modules/reader/book_details")

        local opts = { config = { book_details = { navigate_to_tag = true } } }
        local library_spec = BookDetails.buildSpec(reader_ui(), opts)
        library_spec.tag_callback("First tag")
        assert.are.equal("First tag", library_tag)

        opts.home_context = true
        local home_spec = BookDetails.buildSpec(reader_ui(), opts)
        home_spec.tag_callback("Second tag")
        assert.are.equal("Second tag", home_tag)

        home_tag_result = false
        home_spec.tag_callback("Fallback tag")
        assert.are.equal("Fallback tag", library_tag)
    end)

    it("uses the configured metadata order", function()
        local BookDetails = require("modules/reader/book_details")
        local spec = BookDetails.buildSpec(reader_ui(), {
            config = { book_details = {
                order = { "progress", "pages", "language", "tags", "authors", "series" },
            } },
        })

        assert.are.equal("progress", spec.details[2].style)
        assert.are.equal("Page 128 of 300", spec.details[3].text)
        assert.are.equal("English", spec.details[4].text)
        assert.are.equal("First tag, Second tag", spec.details[5].text)
        assert.are.equal("Test author", spec.details[6].text)
        assert.are.equal("Test series #2", spec.details[7].text)
    end)

    it("shows optional read and remaining times in the configured order", function()
        local ui = reader_ui()
        ui.statistics = { avg_time = 75 }
        book_stats_result = { read_time = 7260 }
        local BookDetails = require("modules/reader/book_details")
        local spec = BookDetails.buildSpec(ui, {
            config = { book_details = {
                order = { "time_remaining", "read_time" },
                read_time = true,
                time_remaining = true,
            } },
        })

        assert.are.equal("Read: 2h 1m / Remaining: 1h 12m", spec.details[2].text)
        assert.are.same({ read_time = true, time_remaining = true }, queried_fields[1])
    end)

    it("omits annotations metadata when there are no annotations", function()
        local ui = reader_ui()
        ui.annotation.annotations = {}
        local BookDetails = require("modules/reader/book_details")
        local spec = BookDetails.buildSpec(ui)

        for _i, detail in ipairs(spec.details) do
            assert.are_not.equal("0 Annotations", detail.text)
        end
    end)

    it("shows the shared BookInfoWidget and derives progress from live pages", function()
        local ui = reader_ui()
        ui.view.footer.percent_finished = nil
        local BookDetails = require("modules/reader/book_details")

        assert.is_true(BookDetails.show(ui))
        assert.are.equal(widget_spec, shown)
        assert.are.equal("Page 126 of 300", widget_spec.details[8].text)
        assert.are.equal(0.42, widget_spec.details[9].progress)
    end)

    it("builds file-manager details with reading times and an optional edit action", function()
        local edit_callback = function() end
        ZenSpec.replace("bookinfomanager", {
            getBookInfo = function(_, path, get_cover)
                assert.are.equal("/books/library.epub", path)
                assert.is_false(get_cover)
                return {
                    title = "Library title",
                    authors = "Library author",
                    description = "Library description",
                    pages = 200,
                }
            end,
        })
        ZenSpec.replace("docsettings", {
            open = function(_, path)
                assert.are.equal("/books/library.epub", path)
                return {
                    readSetting = function(_, key)
                        if key == "percent_finished" then return 0.25 end
                    end,
                }
            end,
        })
        local BookDetails = require("modules/reader/book_details")
        fallback_average = 60
        fallback_pages = 200
        fallback_read_time = 3720

        assert.is_true(BookDetails.showFile("/books/library.epub", {
            config = { book_details = {
                order = { "read_time", "time_remaining", "authors", "pages", "progress" },
                read_time = true,
                time_remaining = true,
            } },
            edit_callback = edit_callback,
        }))
        assert.are.equal("Library title", widget_spec.details[1].text)
        assert.are.equal("Read: 1h 2m / Remaining: 2h 30m",
            widget_spec.details[2].text)
        assert.are.equal("Library author", widget_spec.details[3].text)
        assert.are.equal("Library description", widget_spec.description)
        assert.are.equal("Page 50 of 200", widget_spec.details[4].text)
        assert.are.equal(0.25, widget_spec.details[5].progress)
        assert.are.equal("/books/library.epub", fallback_path)
        assert.are.equal(edit_callback, widget_spec.edit_callback)
    end)

    it("prefers live page-map labels for the current page line", function()
        local ui = reader_ui()
        ui.pagemap = {
            wantsPageLabels = function() return true end,
            getCurrentPageLabel = function() return "xii" end,
            getLastPageLabel = function() return "300" end,
        }
        local BookDetails = require("modules/reader/book_details")
        local summary = BookDetails.getSummary(ui)

        assert.are.equal("xii", summary.current_page)
        assert.are.equal("300", summary.page_total)
        assert.are.equal("Page xii of 300", summary.page_text)
    end)

    it("reports live reading times and today's stats for the launcher", function()
        local ui = reader_ui()
        ui.statistics = { avg_time = 75 }
        book_stats_result = {
            read_time = 7260,
            time_today = 1800,
            pages_today = 12,
        }
        local BookDetails = require("modules/reader/book_details")
        local time_left, read_time, today_duration, today_pages =
            BookDetails.getReadingTimes(ui, {
                read_time = true,
                time_remaining = true,
                time_today = true,
                pages_today = true,
            })

        assert.are.equal(4350, time_left)
        assert.are.equal(7260, read_time)
        assert.are.equal(1800, today_duration)
        assert.are.equal(12, today_pages)
        assert.are.same({
            read_time = true,
            time_remaining = true,
            time_today = true,
            pages_today = true,
        }, queried_fields[1])

        local skipped_time_left, skipped_read_time, skipped_duration, skipped_pages =
            BookDetails.getReadingTimes(ui)
        assert.are.equal(4350, skipped_time_left)
        assert.are.equal(7260, skipped_read_time)
        assert.is_nil(skipped_duration)
        assert.is_nil(skipped_pages)
        assert.are.same({ read_time = true, time_remaining = true }, queried_fields[2])
    end)

    it("converts rendered pages left into the statistics page unit", function()
        local ui = reader_ui()
        ui.statistics = {
            avg_time = 60,
            _zenPagesInStatisticsUnits = function(_stats, pages)
                return pages * 0.3
            end,
        }
        local BookDetails = require("modules/reader/book_details")

        local time_left = BookDetails.getReadingTimes(ui, {
            time_remaining = true,
        })

        assert.are.equal(1044, time_left)
    end)

    it("uses the database page unit with the fallback average", function()
        local ui = reader_ui()
        fallback_average = 60
        fallback_pages = 300
        local BookDetails = require("modules/reader/book_details")

        local time_left = BookDetails.getReadingTimes(ui, {
            time_remaining = true,
        })

        assert.are.equal(10440, time_left)
    end)

    it("omits reading times when statistics are unavailable", function()
        local BookDetails = require("modules/reader/book_details")
        local time_left, read_time, today_duration, today_pages =
            BookDetails.getReadingTimes(reader_ui())

        assert.is_nil(time_left)
        assert.is_nil(read_time)
        assert.is_nil(today_duration)
        assert.is_nil(today_pages)
    end)

    it("keeps available time remaining when the statistics query fails", function()
        local ui = reader_ui()
        ui.statistics = { avg_time = 75 }
        book_stats_error = "statistics unavailable"
        local BookDetails = require("modules/reader/book_details")
        local time_left, read_time, today_duration, today_pages =
            BookDetails.getReadingTimes(ui, {
                read_time = true,
                time_remaining = true,
                time_today = true,
                pages_today = true,
            })

        assert.are.equal(4350, time_left)
        assert.is_nil(read_time)
        assert.is_nil(today_duration)
        assert.is_nil(today_pages)
    end)

    it("rejects invalid reading statistics", function()
        local ui = reader_ui()
        ui.statistics = { avg_time = math.huge }
        book_stats_result = {
            read_time = -1,
            time_today = math.huge,
            pages_today = -1,
        }
        local BookDetails = require("modules/reader/book_details")
        local time_left, read_time, today_duration, today_pages =
            BookDetails.getReadingTimes(ui, {
                read_time = true,
                time_remaining = true,
                time_today = true,
                pages_today = true,
            })

        assert.is_nil(time_left)
        assert.is_nil(read_time)
        assert.is_nil(today_duration)
        assert.is_nil(today_pages)
    end)

    it("does nothing when no reader book is open", function()
        local BookDetails = require("modules/reader/book_details")
        assert.is_false(BookDetails.show({}))
        assert.is_nil(shown)
    end)

    it("does nothing when the file path is missing", function()
        local BookDetails = require("modules/reader/book_details")
        assert.is_false(BookDetails.showFile(nil))
        assert.is_nil(shown)
    end)
end)
