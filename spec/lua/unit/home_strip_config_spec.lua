describe("unified Home strip configuration", function()
    before_each(function()
        ZenSpec.unload("modules/filebrowser/patches/home/home_presets")
    end)

    local function legacy_page(enabled, order, modules)
        return {
            rows = { enabled = enabled or {}, order = order or {} },
            modules = modules or {},
        }
    end

    it("bookends the default Strip controls with page buttons", function()
        local Presets = require("modules/filebrowser/patches/home/home_presets")
        local strip = Presets.defaultHomePage().modules.strip

        assert.are.equal(3, strip.strip_schema_version)
        assert.is_true(strip.controls.enabled)
        assert.are.same({
            "page_left", "recent", "search", "tags", "page_right",
        }, strip.controls.order)
        for _i, id in ipairs(strip.controls.order) do
            assert.is_true(strip.controls.show_buttons[id])
        end
        assert.is_nil(strip.controls.show_buttons.to_be_read)
    end)

    it("keeps the unified strip disabled when no legacy strip was enabled", function()
        local page = legacy_page({}, { "strip_recent", "quotes" }, {
            strip_recent = { count = 5 },
            strip_tbr = {},
        })
        local Presets = require("modules/filebrowser/patches/home/home_presets")

        assert.is_true(Presets.normalizeStripConfig(page))
        assert.are.same({ "strip", "quotes" }, page.rows.order)
        assert.is_false(page.rows.enabled.strip)
        assert.is_false(page.modules.strip.controls.enabled)
        assert.is_nil(page.modules.strip_recent)
    end)

    it("uses the one enabled legacy strip as the default without controls", function()
        local page = legacy_page({ strip_recent = true }, { "strip_recent" }, {
            strip_recent = {
                count = 5, filter_unread = true,
                filter_tbr = true, filter_finished = false,
            },
            strip_custom = { paths = { "/books/one.epub" } },
            strip_tag = { tag = "Science" },
        })
        local Presets = require("modules/filebrowser/patches/home/home_presets")

        Presets.normalizeStripConfig(page)
        local strip = page.modules.strip
        assert.are.same({ kind = "recent" }, strip.default_source)
        assert.are.equal(5, strip.count)
        assert.is_true(strip.sources.recent.filter_unread)
        assert.is_true(strip.sources.recent.filter_tbr)
        assert.are.same({ "/books/one.epub" }, strip.sources.custom.paths)
        assert.are.equal("Science", strip.sources.tag.tag)
        assert.is_false(strip.controls.enabled)
    end)

    it("turns multiple enabled legacy strips into ordered source buttons", function()
        local page = legacy_page({
            strip_tag = true, strip_custom = true, strip_tbr = true,
        }, { "quotes", "strip_tag", "strip_custom", "strip_tbr" }, {
            strip_tag = { tag = "Fantasy", show_badges = true },
            strip_custom = { paths = { "/books/custom.epub" } },
            strip_tbr = {},
        })
        local Presets = require("modules/filebrowser/patches/home/home_presets")

        Presets.normalizeStripConfig(page)
        local strip = page.modules.strip
        assert.are.same({ kind = "tag", value = "Fantasy" }, strip.default_source)
        assert.is_true(strip.show_badges)
        assert.is_true(strip.controls.enabled)
        assert.are.equal(4, #strip.controls.order)
        assert.are.equal("tag", strip.controls.custom_buttons[1].type)
        assert.are.equal("custom_source", strip.controls.custom_buttons[2].type)
        assert.are.equal("to_be_read", strip.controls.order[3])
        assert.are.equal("search", strip.controls.order[4])
        assert.is_true(strip.controls.show_buttons.search)
    end)

    it("normalizes the seven-button limit and accepts Favorites as a source", function()
        local Presets = require("modules/filebrowser/patches/home/home_presets")
        local page = Presets.defaultHomePage()
        page.modules.strip.default_source = { kind = "favorites" }
        page.modules.strip.controls.enabled = false
        page.modules.strip.controls.order = {
            "recent", "favorites", "to_be_read", "authors", "series",
            "tags", "collections", "books", "search", "recent",
        }
        page.modules.strip.controls.show_buttons = {
            recent = true, favorites = true, to_be_read = true, authors = true,
            series = true, tags = true, collections = true, books = true,
        }

        assert.is_true(Presets.normalizeStripConfig(page))
        assert.are.same({ kind = "favorites" }, page.modules.strip.default_source)
        assert.is_false(page.modules.strip.controls.show_buttons.books)
        assert.are.equal(9, #page.modules.strip.controls.order)
    end)

    it("uses the first visible source tab as the controls default", function()
        local Presets = require("modules/filebrowser/patches/home/home_presets")
        local page = Presets.defaultHomePage()
        local strip = page.modules.strip
        strip.default_source = { kind = "recent" }
        strip.controls.enabled = true
        strip.controls.order = { "page_left", "to_be_read", "favorites", "recent" }
        strip.controls.show_buttons = {
            page_left = true, to_be_read = false, favorites = true, recent = true,
        }

        assert.is_true(Presets.normalizeStripConfig(page))
        assert.are.same({ kind = "favorites" }, strip.default_source)
    end)

    it("adds configurable Search to older custom strip controls", function()
        local Presets = require("modules/filebrowser/patches/home/home_presets")
        local page = Presets.defaultHomePage()
        local controls = page.modules.strip.controls
        page.modules.strip.strip_schema_version = 1
        controls.order = { "recent", "to_be_read" }
        controls.show_buttons.recent = true
        controls.show_buttons.search = nil

        assert.is_true(Presets.normalizeStripConfig(page))
        assert.are.equal(3, page.modules.strip.strip_schema_version)
        assert.are.same({ "recent", "to_be_read", "search" }, controls.order)
        assert.is_true(controls.show_buttons.search)
    end)

    it("migrates the previous default controls to page bookends", function()
        local Presets = require("modules/filebrowser/patches/home/home_presets")
        local page = Presets.defaultHomePage()
        local controls = page.modules.strip.controls
        page.modules.strip.strip_schema_version = 2
        controls.order = { "recent", "to_be_read", "tags", "search" }
        controls.show_buttons = {
            recent = true, to_be_read = true, tags = true, search = true,
        }

        assert.is_true(Presets.normalizeStripConfig(page))
        assert.are.equal(3, page.modules.strip.strip_schema_version)
        assert.are.same({
            "page_left", "recent", "search", "tags", "page_right",
        }, controls.order)
        assert.is_true(controls.show_buttons.recent)
        assert.is_nil(controls.show_buttons.to_be_read)
        assert.is_true(controls.show_buttons.page_left)
        assert.is_true(controls.show_buttons.page_right)
    end)

    it("keeps Search removed after the strip schema is current", function()
        local Presets = require("modules/filebrowser/patches/home/home_presets")
        local page = Presets.defaultHomePage()
        local controls = page.modules.strip.controls
        controls.order = { "recent", "to_be_read", "tags" }
        controls.show_buttons.search = nil

        assert.is_false(Presets.normalizeStripConfig(page))
        assert.are.same({ "recent", "to_be_read", "tags" }, controls.order)
        assert.is_nil(controls.show_buttons.search)
    end)

    it("adds the default strip control text style to existing presets", function()
        local Presets = require("modules/filebrowser/patches/home/home_presets")
        local page = Presets.defaultHomePage()
        page.modules.strip.controls.text_style = nil

        assert.is_true(Presets.normalizeStripConfig(page))
        assert.are.same({
            font_face = "default",
            font_size = 10,
            bold = false,
        }, page.modules.strip.controls.text_style)
    end)

    it("migrates the legacy Genres control label to Tags", function()
        local Presets = require("modules/filebrowser/patches/home/home_presets")
        local page = Presets.defaultHomePage()
        page.modules.strip.controls.labels.tags = "Genres"

        assert.is_true(Presets.normalizeStripConfig(page))
        assert.is_nil(page.modules.strip.controls.labels.tags)
    end)

    it("keeps all Tags as a strip source", function()
        local Presets = require("modules/filebrowser/patches/home/home_presets")
        local page = Presets.defaultHomePage()
        page.modules.strip.default_source = { kind = "tags" }
        page.modules.strip.controls.enabled = false

        assert.is_false(Presets.normalizeStripConfig(page))
        assert.are.same({ kind = "tags" }, page.modules.strip.default_source)
    end)

    it("keeps a valid status as a strip source", function()
        local Presets = require("modules/filebrowser/patches/home/home_presets")
        local page = Presets.defaultHomePage()
        page.modules.strip.default_source = { kind = "status", value = "complete" }
        page.modules.strip.controls.enabled = false

        assert.is_false(Presets.normalizeStripConfig(page))
        assert.same({ kind = "status", value = "complete" },
            page.modules.strip.default_source)
    end)

    it("keeps at least one valid tab visible", function()
        local Presets = require("modules/filebrowser/patches/home/home_presets")
        local page = Presets.defaultHomePage()
        page.modules.strip.controls.order = { "missing", "favorites", "recent" }
        page.modules.strip.controls.show_buttons = {
            missing = true, favorites = false, recent = false,
        }

        assert.is_true(Presets.normalizeStripConfig(page))
        assert.are.same({ "favorites", "recent" }, page.modules.strip.controls.order)
        assert.is_true(page.modules.strip.controls.show_buttons.favorites)
        assert.is_false(page.modules.strip.controls.show_buttons.recent)
    end)

    it("silently migrates legacy five-row layouts without revealing hidden widgets", function()
        local Presets = require("modules/filebrowser/patches/home/home_presets")
        local page = {
            rows = {
                max_rows = 5,
                order = {
                    "featured", "strip", "quotes", "reading_goals",
                    "stats_triplet", "datetime",
                },
                enabled = {
                    featured = true, strip = true, quotes = true,
                    reading_goals = true, stats_triplet = true, datetime = true,
                },
            },
        }

        assert.is_true(Presets.normalizeLayoutGrid(page))
        assert.is_nil(page.rows.max_rows)
        assert.are.equal(10, page.rows.capacity_units)
        assert.are.equal(2, page.rows.layout_schema_version)
        assert.is_nil(page.rows.layout_notice_pending)
        assert.is_true(page.rows.enabled.stats_triplet)
        assert.is_false(page.rows.enabled.datetime)
        assert.is_false(Presets.normalizeLayoutGrid(page))
    end)

    it("preserves all selections from the first spacing-grid version", function()
        local Presets = require("modules/filebrowser/patches/home/home_presets")
        local page = {
            rows = {
                capacity_units = 10,
                order = { "featured", "strip", "quotes", "reading_goals", "stats_triplet" },
                enabled = {
                    featured = true, strip = true, quotes = true,
                    reading_goals = true, stats_triplet = true,
                },
            },
        }

        assert.is_true(Presets.normalizeLayoutGrid(page))
        assert.is_true(page.rows.enabled.featured)
        assert.is_true(page.rows.enabled.strip)
        assert.is_true(page.rows.enabled.quotes)
        assert.is_true(page.rows.enabled.reading_goals)
        assert.is_true(page.rows.enabled.stats_triplet)
        assert.is_nil(page.rows.layout_notice_pending)
    end)

    it("clears a queued layout notice from prior versions", function()
        local Presets = require("modules/filebrowser/patches/home/home_presets")
        local page = {
            rows = {
                layout_schema_version = 2,
                layout_notice_pending = true,
            },
        }

        assert.is_true(Presets.normalizeLayoutGrid(page))
        assert.is_nil(page.rows.layout_notice_pending)
        assert.is_false(Presets.normalizeLayoutGrid(page))
    end)
end)
