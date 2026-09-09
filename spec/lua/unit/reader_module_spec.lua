describe("reader module initialization", function()
    local patch_names = {
        "library_navigation",
        "page_browser",
        "stable_page_statistics",
        "opening_banner",
        "book_status",
        "status_on_open",
        "screensaver_cover",
        "reader_footer",
        "reader_footer_time_format",
        "reader_footer_cbz_hide",
        "margin_hold_guard",
        "bookmarks",
        "highlight_names",
        "dict_quick_lookup",
        "highlight_menu",
        "reader_top_status_bar",
        "reader_themes",
    }

    local function prepare_patches(calls, failing_name)
        for _i, name in ipairs(patch_names) do
            ZenSpec.replace("modules/reader/patches/" .. name, function()
                calls[#calls + 1] = name
                if name == failing_name then error("failed " .. name) end
                assert.is_table(_G.__ZEN_UI_PLUGIN)
            end)
        end
        ZenSpec.unload("modules/reader/reader")
        return require("modules/reader/reader")
    end

    before_each(function()
        _G.__ZEN_UI_PLUGIN = nil
        _G.__ZEN_UI_RUNTIME_PATCHES = nil
    end)

    after_each(function()
        _G.__ZEN_UI_PLUGIN = nil
        _G.__ZEN_UI_RUNTIME_PATCHES = nil
    end)

    it("applies core patches once and skips the disabled optional status bar", function()
        local calls = {}
        local Reader = prepare_patches(calls)
        local logger = { dbg = function() end, warn = function() end }
        local plugin = { config = { features = { reader_top_status_bar = false } } }

        assert.is_true(Reader.init(logger, plugin))
        assert.same({
            "library_navigation",
            "page_browser",
            "stable_page_statistics",
            "opening_banner",
            "book_status",
            "status_on_open",
            "screensaver_cover",
            "reader_footer",
            "reader_footer_time_format",
            "reader_footer_cbz_hide",
            "margin_hold_guard",
            "bookmarks",
            "highlight_names",
            "dict_quick_lookup",
            "highlight_menu",
        }, calls)
        assert.is_nil(_G.__ZEN_UI_PLUGIN)
        assert.is_nil(_G.__ZEN_UI_RUNTIME_PATCHES.reader_top_status_bar)

        assert.is_true(Reader.init(logger, plugin))
        assert.are.equal(15, #calls)
    end)

    it("records a successfully enabled runtime status-bar patch", function()
        local calls = {}
        local Reader = prepare_patches(calls)
        local logger = { dbg = function() end, warn = function() end }
        local plugin = { config = { features = { reader_top_status_bar = true } } }

        Reader.init(logger, plugin)
        assert.are.equal("reader_top_status_bar", calls[#calls])
        assert.is_true(_G.__ZEN_UI_RUNTIME_PATCHES.reader_top_status_bar)
    end)

    it("does not load themes when disabled and records the enabled theme patch", function()
        local calls = {}
        local Reader = prepare_patches(calls)
        local logger = { dbg = function() end, warn = function() end }

        Reader.init(logger, { config = { features = { reader_themes = false } } })
        assert.is_nil(_G.__ZEN_UI_RUNTIME_PATCHES.reader_themes)
        local theme_loaded = false
        for _i, name in ipairs(calls) do
            if name == "reader_themes" then theme_loaded = true end
        end
        assert.is_false(theme_loaded)

        calls = {}
        Reader = prepare_patches(calls)
        Reader.init(logger, { config = { features = { reader_themes = true } } })
        assert.are.equal("reader_themes", calls[#calls])
        assert.is_true(_G.__ZEN_UI_RUNTIME_PATCHES.reader_themes)
    end)

    it("isolates a failed patch, restores the prior plugin, and continues initialization", function()
        local calls, warnings = {}, {}
        local Reader = prepare_patches(calls, "book_status")
        local logger = {
            dbg = function() end,
            warn = function(...)
                warnings[#warnings + 1] = { ... }
            end,
        }
        local previous = { marker = "previous" }
        _G.__ZEN_UI_PLUGIN = previous

        assert.is_true(Reader.init(logger, { config = { features = {} } }))
        assert.are.equal(previous, _G.__ZEN_UI_PLUGIN)
        assert.are.equal("status_on_open", calls[6])
        assert.are.equal(1, #warnings)
        assert.are.equal("grouped reader feature failed", warnings[1][1])
        assert.are.equal("book_status", warnings[1][2])
        assert.matches("failed book_status", warnings[1][3])
    end)
end)
