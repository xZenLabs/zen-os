describe("config manager folder-path migration", function()
    local Manager
    local settings_file
    local stores
    local written_settings
    local write_error
    local google_key_ensures

    local function reload_manager(language)
        _G.G_reader_settings = ZenSpec.memorySettings(language and { language = language } or {})
        ZenSpec.unload("config/defaults")
        ZenSpec.unload("config/manager")
        Manager = require("config/manager")
    end

    before_each(function()
        settings_file = { data = {}, flush = function() end }
        written_settings = nil
        write_error = nil
        google_key_ensures = 0
        stores = {
            home = { settings = {}, presets = {} },
            reader = { settings = {}, presets = {} },
        }
        ZenSpec.replace("luasettings", { open = function() return settings_file end })
        ZenSpec.replace("util", {
            tableDeepCopy = function(value) return value end,
            writeToFile = function(data, path)
                if write_error then return nil, write_error end
                written_settings = "-- " .. path .. "\nreturn " .. data .. "\n"
                return true
            end,
            readFromFile = function()
                return written_settings
            end,
        })
        ZenSpec.replace("config/preset_store", {
            rootDir = function() return "/tmp/zen-ui-spec" end,
            getSettings = function() return {} end,
            saveSettings = function() return true end,
            loadStore = function(kind) return stores[kind] or { settings = {}, presets = {} } end,
            saveStore = function(kind, store)
                stores[kind] = store
                return true
            end,
            migrateStores = function() return false end,
        })
        ZenSpec.replace("config/hardcover_token", {
            ensureFile = function() return false end,
        })
        ZenSpec.replace("config/google_books_key", {
            ensureFile = function()
                google_key_ensures = google_key_ensures + 1
                return false
            end,
        })
        ZenSpec.replace("modules/filebrowser/patches/home/home_presets", {
            DEFAULT_PRESET_NAME = "Zen Default",
            BOOKSHELF_PRESET_NAME = "Bookshelf",
            applyMosaicTitlesToStrips = function() end,
            defaultHomePage = function() return { quotes = { font_size = 12 } } end,
            normalizeStripConfig = function() return false end,
        })
        ZenSpec.replace("modules/filebrowser/patches/home/home_quotes", {
            ensureFile = function() return false end,
        })
        reload_manager()
    end)

    it("loads complete defaults for a fresh install", function()
        local config = Manager.load()

        assert.is_true(config.features.navbar)
        assert.is_true(config.features.quick_settings)
        assert.is_true(config.features.app_launcher)
        assert.is_true(config.features.zen_mode)
        assert.is_true(config.features.status_bar)
        assert.are.equal("90", config.quick_settings.rotate_action)
        assert.are.equal("", config.quick_settings.gyro_label)
        assert.are.equal("quick_rotate", config.quick_settings.gyro_icon)
        assert.are.equal("number", config.reader_footer.chapter_time_format)
        assert.is_false(config.reader_top_status_bar.wifi_hide_when_off)
        assert.are.equal(18, config.page_browser.toc_font_size)
        assert.are.equal(18, config.page_browser.bookmarks_font_size)
        assert.are.same({}, config.folder_cover_paths)
        assert.is_true(config.search.substring)
        assert.is_true(config.metadata.hardcover_enabled)
        assert.is_true(config.metadata.google_books_enabled)
        assert.is_true(config.metadata.open_library_enabled)
        assert.is_true(config.metadata.hardcover_auto_match)
        assert.is_false(config.metadata.epub_backup)
        assert.are.equal(1, google_key_ensures)
        assert.is_false(config._meta.quickstart_shown_for_version)
    end)

    it("fills missing defaults without sharing them or replacing saved arrays", function()
        settings_file.data = { navbar = { order = { "home" } }, folder_cover_paths = {} }
        local defaults = require("config/defaults")
        local config = Manager.load()
        assert.are.same({ "home" }, config.navbar.order)
        assert.are.same({}, config.folder_cover_paths)
        assert.is_true(config.features.navbar)
        config.features.navbar = false
        assert.is_true(defaults.features.navbar)
        assert.are.equal(config, Manager.load())
        assert.is_false(config.features.navbar)
    end)

    it("reports a verified settings write failure", function()
        settings_file.file = "/tmp/zen-ui-spec/config.lua"
        settings_file.backup = function() return false end
        write_error = "disk full"

        local saved, err = Manager.save({ folder_cover_paths = {} }, true)

        assert.is_nil(saved)
        assert.are.equal("disk full", err)
        assert.is_nil(Manager.get())
    end)

    it("accepts a verified settings write only after reading it back", function()
        settings_file.file = "/tmp/zen-ui-spec/config.lua"
        settings_file.backup = function() return false end
        local config = { folder_cover_paths = {} }

        assert.is_true(Manager.save(config, true))
        assert.are.equal(config, Manager.get())
    end)

    it("migrates verbose chapter time settings to display formats", function()
        settings_file.data = {
            reader_footer = { verbose_chapter_time = true },
        }
        stores.reader.settings = { verbose_chapter_time = false }
        stores.reader.presets = {
            Full = { verbose_chapter_time = true },
            Legacy = { zen = { verbose_chapter_time = false } },
        }

        local config = Manager.load()

        assert.are.equal("full", config.reader_footer.chapter_time_format)
        assert.is_nil(config.reader_footer.verbose_chapter_time)
        assert.are.equal("number", stores.reader.settings.chapter_time_format)
        assert.is_nil(stores.reader.settings.verbose_chapter_time)
        assert.are.equal("full", stores.reader.presets.Full.chapter_time_format)
        assert.is_nil(stores.reader.presets.Full.verbose_chapter_time)
        assert.are.equal("number", stores.reader.presets.Legacy.chapter_time_format)
        assert.is_nil(stores.reader.presets.Legacy.zen)
    end)

    it("preserves the KOReader chapter time format", function()
        settings_file.data = {
            reader_footer = { chapter_time_format = "koreader" },
        }
        stores.reader.settings = { chapter_time_format = "koreader" }

        local config = Manager.load()

        assert.are.equal("koreader", config.reader_footer.chapter_time_format)
        assert.are.equal("koreader", stores.reader.settings.chapter_time_format)
    end)

    it("preserves an existing rotate action", function()
        settings_file.data = {
            quick_settings = { rotate_action = "cycle" },
        }

        local config = Manager.load()

        assert.are.equal("cycle", config.quick_settings.rotate_action)
    end)

    it("migrates a disabled status bar to empty item lists", function()
        settings_file.data = {
            features = { status_bar = false },
            status_bar = {
                left_order = { "time" },
                center_order = { "date" },
                right_order = { "wifi", "battery" },
            },
        }

        local config = Manager.load()

        assert.is_true(config.features.status_bar)
        assert.are.same({}, config.status_bar.left_order)
        assert.are.same({}, config.status_bar.center_order)
        assert.are.same({}, config.status_bar.right_order)
    end)

    it("recovers the sparse config created by the fresh-install merge bug", function()
        settings_file.data = {
            _meta = {
                schema_version = 1,
                zenos_brand_migration_v1 = true,
                quickstart_shown_for_version = "pre-quickstart",
                quickstart_completed = true,
            },
            features = {},
            navbar = { default_tab = "books" },
            quick_settings = { button_order = { "wifi" } },
        }

        local config = Manager.load()

        assert.is_true(config.features.navbar)
        assert.is_true(config.features.quick_settings)
        assert.is_true(config.features.app_launcher)
        assert.is_true(config.features.zen_mode)
        assert.is_true(config.features.status_bar)
        assert.are.equal("books", config.navbar.default_tab)
        assert.are.same({ "wifi" }, config.quick_settings.button_order)
        assert.is_false(config._meta.quickstart_shown_for_version)
        assert.is_false(config._meta.quickstart_completed)
    end)

    it("keeps JPG and JPEG folder-cover references while preserving clear tombstones", function()
        settings_file.data = {
            folder_cover_paths = {
                ["/library/mixed"] = {
                    [1] = "/images/first.jpg",
                    [2] = "/images/second.JPG",
                    [3] = "/images/legacy.jpeg",
                    [4] = "/images/legacy.png",
                },
                ["/library/unsupported"] = {
                    [1] = "/images/legacy.webp",
                    [2] = "/images/legacy.gif",
                },
                ["/library/cleared"] = {},
            },
        }

        local config = Manager.load()

        assert.are.same({
            [1] = "/images/first.jpg",
            [2] = "/images/second.JPG",
            [3] = "/images/legacy.jpeg",
        }, config.folder_cover_paths["/library/mixed"])
        assert.is_nil(config.folder_cover_paths["/library/unsupported"])
        assert.are.same({}, config.folder_cover_paths["/library/cleared"])
    end)

    it("moves path settings and rewrites cover references for a renamed subtree", function()
        Manager.save({
            folder_sort = {
                ["/library/old"] = { collate = "title", reverse = true },
                ["/library/old/nested"] = { collate = "access", reverse = false },
            },
            folder_display_mode = {
                ["/library/old"] = "mosaic",
                ["/unrelated"] = "list",
            },
            folder_cover_paths = {
                ["/library/old"] = {
                    [1] = "/library/old/art/first.jpg",
                    [3] = "/shared/third.jpg",
                },
                ["/library/old/nested"] = {
                    [2] = "/library/old/nested/second.jpg",
                },
                ["/library/other"] = {
                    [1] = "/library/old/shared.jpg",
                },
                ["/unrelated"] = {
                    [1] = "/elsewhere/poster.jpg",
                },
            },
        })
        assert.is_true(Manager.moveFolderPathSettings("/library/old/", "/library/new"))
        local config = Manager.get()
        assert.is_nil(config.folder_sort["/library/old"])
        assert.are.same({ collate = "title", reverse = true }, config.folder_sort["/library/new"])
        assert.are.same({ collate = "access", reverse = false }, config.folder_sort["/library/new/nested"])
        assert.are.equal("mosaic", config.folder_display_mode["/library/new"])
        assert.are.equal("list", config.folder_display_mode["/unrelated"])
        assert.is_nil(config.folder_cover_paths["/library/old"])
        assert.is_nil(config.folder_cover_paths["/library/old/nested"])
        assert.are.same({
            [1] = "/library/new/art/first.jpg",
            [3] = "/shared/third.jpg",
        }, config.folder_cover_paths["/library/new"])
        assert.are.same({
            [2] = "/library/new/nested/second.jpg",
        }, config.folder_cover_paths["/library/new/nested"])
        assert.are.equal("/library/new/shared.jpg",
            config.folder_cover_paths["/library/other"][1])
        assert.are.equal("/elsewhere/poster.jpg",
            config.folder_cover_paths["/unrelated"][1])
    end)

    it("does not rewrite identical normalized paths", function()
        Manager.save({ folder_sort = { ["/library/same"] = { collate = "title" } } })
        assert.is_false(Manager.moveFolderPathSettings("/library/same/", "/library/same"))
    end)

    it("rewrites a cover reference when its image file moves", function()
        Manager.save({
            folder_cover_paths = {
                ["/library/series"] = {
                    [1] = "/images/old.jpg",
                    [2] = "/images/other.jpg",
                },
            },
        })

        assert.is_true(Manager.movePathSettings(
            "/images/old.jpg", "/artwork/new.jpg"))
        assert.are.same({
            [1] = "/artwork/new.jpg",
            [2] = "/images/other.jpg",
        }, Manager.get().folder_cover_paths["/library/series"])
    end)

    it("migrates missing and legacy quote font sizes to 12", function()
        stores.home = {
            settings = {
                font_size = 18,
                font_size_override = true,
                quotes = {
                    day_seed = 123,
                    font_size = 18,
                    manual_index = 4,
                    use_home_font_size = true,
                },
            },
            presets = {
                missing = { quotes = {} },
                explicit = { quotes = { font_size = 18, font_size_override = true } },
            },
        }

        Manager.load()

        assert.is_nil(stores.home.settings.font_size)
        assert.is_nil(stores.home.settings.font_size_override)
        assert.are.equal(12, stores.home.settings.quotes.font_size)
        assert.is_nil(stores.home.settings.quotes.use_home_font_size)
        assert.is_true(stores.home.settings.quotes.automatic_font_size)
        assert.are.equal(14, stores.home.settings.quotes.max_font_size)
        assert.are.equal("daily", stores.home.settings.quotes.rotation)
        assert.are.same({ default = true }, stores.home.settings.quotes.sources)
        assert.is_nil(stores.home.settings.quotes.day_seed)
        assert.is_nil(stores.home.settings.quotes.manual_index)
        assert.are.equal(12, stores.home.presets.missing.quotes.font_size)
        assert.is_true(stores.home.presets.missing.quotes.automatic_font_size)
        assert.are.equal(14, stores.home.presets.missing.quotes.max_font_size)
        assert.are.equal(18, stores.home.presets.explicit.quotes.font_size)
    end)

    it("enables strip controls for an existing active Bookshelf preset", function()
        stores.home = {
            active_preset = "Bookshelf",
            settings = {
                active_preset = "Bookshelf",
                modules = { strip = { controls = { enabled = false } } },
            },
            presets = {},
        }

        Manager.load()

        assert.is_true(stores.home.settings.modules.strip.controls.enabled)
    end)

    it("enables strip controls for an existing active Zen Default preset", function()
        stores.home = {
            active_preset = "Zen Default",
            settings = {
                active_preset = "Zen Default",
                modules = { strip = { controls = { enabled = false } } },
            },
            presets = {},
        }

        Manager.load()

        assert.is_true(stores.home.settings.modules.strip.controls.enabled)
    end)

    it("removes obsolete folder-cover lifecycle settings", function()
        settings_file.data = {
            features = { browser_folder_cover = true },
            browser_folder_cover = { crop_to_fit = false, cover_mode = "stack" },
            _meta = { gallery_mode_defaulted = true },
        }

        local config = Manager.load()

        assert.is_nil(config.features.browser_folder_cover)
        assert.is_nil(config.browser_folder_cover.crop_to_fit)
        assert.are.equal("stack", config.browser_folder_cover.cover_mode)
        assert.is_nil(config._meta.gallery_mode_defaulted)
    end)

    it("migrates the legacy Library default to bundled Hyperreadable once", function()
        settings_file.data = {
            library_font = { font_face = "default", font_size = 20 },
        }

        local config = Manager.load()
        local expected = "fonts/hyperreadable/Hyperreadable-Regular.ttf"

        assert.are.equal(expected, config.library_font.font_face)
        assert.are.equal(20, config.library_font.font_size)
        assert.is_true(config._meta.library_font_hyperreadable_default_migrated)

        config.library_font.font_face = "default"
        Manager.save(config)

        assert.are.equal("default", Manager.load().library_font.font_face)
    end)

    it("enables recognized lookup plugins once and preserves later choices", function()
        settings_file.data = {
            highlight_lookup = {
                show_xray = false,
                show_koassistant = false,
                show_ai_assistant = false,
            },
        }

        local config = Manager.load()

        assert.is_true(config.highlight_lookup.show_xray)
        assert.is_true(config.highlight_lookup.show_koassistant)
        assert.is_true(config.highlight_lookup.show_ai_assistant)
        assert.is_true(config._meta.lookup_plugin_items_default_migrated)

        config.highlight_lookup.show_xray = false
        config.highlight_lookup.show_koassistant = false
        config.highlight_lookup.show_ai_assistant = false
        Manager.save(config)

        config = Manager.load()
        assert.is_false(config.highlight_lookup.show_xray)
        assert.is_false(config.highlight_lookup.show_koassistant)
        assert.is_false(config.highlight_lookup.show_ai_assistant)
    end)

    it("preserves a custom Library font during the default migration", function()
        settings_file.data = {
            library_font = { font_face = "/fonts/Custom-Regular.ttf", font_size = 18 },
        }

        local config = Manager.load()

        assert.are.equal("/fonts/Custom-Regular.ttf", config.library_font.font_face)
        assert.is_true(config._meta.library_font_hyperreadable_default_migrated)
    end)

    it("makes bundled Library font paths portable across plugin locations", function()
        local copied_paths = {
            "/mnt/onboard/.adds/koreader/plugins/zen_ui.koplugin/fonts/Custom-Regular.ttf",
            "/storage/emulated/0/koreader/plugins/zenos.koplugin/fonts/Custom-Regular.ttf",
        }

        for _i, font_path in ipairs(copied_paths) do
            settings_file.data = {
                _meta = { library_font_hyperreadable_default_migrated = true },
                library_font = { font_face = font_path, font_size = 23 },
            }

            local config = Manager.load()

            assert.are.equal("fonts/Custom-Regular.ttf", config.library_font.font_face)
            assert.are.equal(23, config.library_font.font_size)
        end
    end)

    it("keeps the Library default for locales unsupported by bundled fonts", function()
        reload_manager("ja_JP")
        settings_file.data = {
            library_font = { font_face = "default", font_size = 20 },
        }

        local config = Manager.load()

        assert.are.equal("default", config.library_font.font_face)
        assert.are.equal(20, config.library_font.font_size)
        assert.is_true(config._meta.library_font_hyperreadable_default_migrated)
    end)

    it("resets the bundled Library font after switching to an unsupported locale", function()
        reload_manager("ja_JP")
        settings_file.data = {
            _meta = { library_font_hyperreadable_default_migrated = true },
            library_font = {
                font_face = (require("common/plugin_root") or "")
                    .. "/fonts/hyperreadable/Hyperreadable-Regular.ttf",
                font_size = 20,
            },
        }

        local config = Manager.load()

        assert.are.equal("default", config.library_font.font_face)
        assert.are.equal(20, config.library_font.font_size)
    end)

    it("migrates previously shown Quickstart guides as completed", function()
        settings_file.data = {
            _meta = { quickstart_shown_for_version = "2.5.0" },
        }

        local config = Manager.load()

        assert.is_true(config._meta.quickstart_completed)
    end)

    it("moves global search and page-browser layout into their Zen settings", function()
        settings_file.data = {
            reader_page_browser = { layout = "single" },
        }
        _G.G_reader_settings = ZenSpec.memorySettings({
            substring_search = false,
            zen_page_browser_layout = "grid",
        })

        local config = Manager.load()

        assert.is_false(config.search.substring)
        assert.is_nil(config.reader_page_browser)
        assert.are.equal("single", stores.reader.settings.page_browser_layout)
        assert.is_nil(G_reader_settings:readSetting("substring_search"))
        assert.is_nil(G_reader_settings:readSetting("zen_page_browser_layout"))
    end)

    it("moves Zen-owned globals into the dedicated config", function()
        _G.G_reader_settings = ZenSpec.memorySettings({
            uniform_cover_ratio = "3:4",
            opds_default_url = "https://catalog.example",
            zen_series_display_mode = "mosaic_text",
            zen_series_reverse = true,
            zen_tags_global_collate = "access",
            zen_tags_global_reverse = true,
            zen_series_detail_collate_Saga = "title",
            zen_series_detail_reverse_Saga = true,
        })

        local config = Manager.load()

        assert.are.equal("3:4", config.uniform_cover_ratio)
        assert.are.equal("https://catalog.example", config.opds.default_url)
        assert.are.equal("mosaic_text", config.group_view.display_mode.series)
        assert.is_true(config.group_view.group_reverse.series)
        assert.are.equal("access", config.group_view.tags_global.collate)
        assert.is_true(config.group_view.tags_global.reverse)
        assert.are.equal("title", config.group_view.detail_collate.series.Saga)
        assert.is_true(config.group_view.detail_reverse.series.Saga)
        for _i, key in ipairs({
            "uniform_cover_ratio", "opds_default_url",
            "zen_series_display_mode", "zen_series_reverse",
            "zen_tags_global_collate", "zen_tags_global_reverse",
            "zen_series_detail_collate_Saga", "zen_series_detail_reverse_Saga",
        }) do
            assert.is_nil(G_reader_settings:readSetting(key), key)
        end
    end)

    it("preserves the carousel page-browser layout", function()
        stores.reader.settings.page_browser_layout = "carousel"

        Manager.load()

        assert.are.equal("carousel", stores.reader.settings.page_browser_layout)
    end)
end)
