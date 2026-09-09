describe("unified Home featured configuration", function()
    before_each(function()
        ZenSpec.unload("modules/filebrowser/patches/home/home_presets")
    end)

    it("uses recently read as the unified default", function()
        local Presets = require("modules/filebrowser/patches/home/home_presets")
        local page = Presets.defaultHomePage()

        assert.are.same({ "datetime", "featured", "stats_triplet", "reading_goals", "strip", "quotes" },
            page.rows.order)
        assert.is_true(page.rows.enabled.featured)
        assert.are.same({ kind = "recent" }, page.modules.featured.default_source)
        assert.is_nil(page.modules.featured.show_module_title)
        assert.is_true(page.modules.featured.show_author)
        assert.is_true(page.modules.featured.show_series)
        assert.is_true(page.modules.featured.show_progress)
        assert.is_true(page.modules.featured.show_status_bar)
        assert.is_false(page.modules.featured.wrap_description_text)
        assert.is_false(page.modules.featured.justify_description_text)
        assert.is_false(page.modules.featured.format_description_html)
        assert.is_nil(page.modules.featured_recent)
        assert.is_nil(page.modules.featured_custom)
        assert.is_nil(page.modules.featured_tbr)
    end)

    it("migrates the selected source while keeping recently read appearance settings", function()
        local Presets = require("modules/filebrowser/patches/home/home_presets")
        local recent_styles = {
            title = { font_face = "Bookerly", font_size = 19, bold = false },
            author = { font_face = "Noto Sans", font_size = 13, bold = true },
            series = { font_face = "default", font_size = 10, bold = true },
            description = { font_face = "default", font_size = 21, bold = false },
            progress = { font_face = "default", font_size = 12, bold = true },
        }
        local page = {
            rows = {
                order = { "quotes", "featured_tbr", "featured_recent", "featured_custom" },
                enabled = {
                    quotes = true,
                    featured_tbr = true,
                    featured_recent = false,
                    featured_custom = false,
                },
            },
            modules = {
                featured_recent = {
                    interactive = false,
                    order = "reverse",
                    progress_meta = { left = "time_left", right = "percent" },
                    show_description = false,
                    show_module_title = true,
                    show_status_bar = false,
                    status_bar_bold_text = false,
                    status_bar_show_bottom_border = false,
                    text_styles = recent_styles,
                },
                featured_custom = { path = "/library/picked.epub" },
                featured_tbr = {
                    text_styles = {
                        title = { font_face = "Wrong font", font_size = 8, bold = true },
                    },
                },
            },
        }

        assert.is_true(Presets.normalizeFeaturedConfig(page))
        assert.are.same({ "quotes", "featured" }, page.rows.order)
        assert.is_true(page.rows.enabled.featured)
        assert.are.same({ kind = "to_be_read" }, page.modules.featured.default_source)
        assert.are.same(recent_styles, page.modules.featured.text_styles)
        assert.is_nil(page.modules.featured.order)
        assert.is_false(page.modules.featured.interactive)
        assert.is_true(page.modules.featured.show_author)
        assert.is_true(page.modules.featured.show_series)
        assert.is_true(page.modules.featured.show_progress)
        assert.is_false(page.modules.featured.wrap_description_text)
        assert.is_false(page.modules.featured.justify_description_text)
        assert.is_false(page.modules.featured.format_description_html)
        assert.are.equal("/library/picked.epub", page.modules.featured.path)
        assert.is_nil(page.modules.featured_recent)
        assert.is_nil(page.modules.featured_custom)
        assert.is_nil(page.modules.featured_tbr)
        assert.is_false(Presets.normalizeFeaturedConfig(page))
    end)

    it("preserves the opt-in description wrapping setting", function()
        local Presets = require("modules/filebrowser/patches/home/home_presets")
        local page = {
            rows = { order = { "featured" }, enabled = { featured = true } },
            modules = { featured = { wrap_description_text = true } },
        }

        assert.is_true(Presets.normalizeFeaturedConfig(page))
        assert.is_true(page.modules.featured.wrap_description_text)
        assert.is_false(Presets.normalizeFeaturedConfig(page))
    end)

    it("preserves a custom featured selection", function()
        local Presets = require("modules/filebrowser/patches/home/home_presets")
        local page = {
            rows = {
                order = { "featured_recent", "featured_custom", "featured_tbr" },
                enabled = { featured_custom = true },
            },
            modules = {
                featured_recent = {},
                featured_custom = { path = "/library/custom.epub" },
                featured_tbr = {},
            },
        }

        assert.is_true(Presets.normalizeFeaturedConfig(page))
        assert.are.same({ kind = "custom" }, page.modules.featured.default_source)
        assert.are.equal("/library/custom.epub", page.modules.featured.path)
    end)

    it("removes the obsolete featured cover-layout setting", function()
        local Presets = require("modules/filebrowser/patches/home/home_presets")
        local page = {
            rows = { order = { "featured" }, enabled = { featured = true } },
            modules = { featured = { cover_layout = "top_left_wrap" } },
        }

        assert.is_true(Presets.normalizeFeaturedConfig(page))
        assert.is_nil(page.modules.featured.cover_layout)
        assert.is_false(Presets.normalizeFeaturedConfig(page))
    end)
end)
