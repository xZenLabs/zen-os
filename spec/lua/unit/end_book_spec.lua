describe("end of book", function()
    local saved, settings, plugin, status, shown, native_calls, menu, top
    local names = {
        "modules/reader/patches/end_book", "modules/reader/end_book_data",
        "modules/reader/end_book", "apps/reader/modules/readerstatus", "ui/uimanager",
        "ui/quickstart", "ui/elements/common_settings_menu_table", "datetime",
    }

    before_each(function()
        saved = {}
        for _i, name in ipairs(names) do
            saved[name] = { package.loaded[name], _G[name] }
            ZenSpec.unload(name)
        end
        settings = G_reader_settings
        _G.G_reader_settings = ZenSpec.memorySettings()
        plugin = { config = { _meta = {} }, saves = 0 }
        function plugin:saveConfig() self.saves = self.saves + 1 end
        _G.__ZEN_UI_PLUGIN = plugin
        shown, native_calls, top = 0, 0, nil
        status = { onEndOfBook = function() native_calls = native_calls + 1 end }
        menu = { document_end_action = { sub_item_table = { { text = "Auto mark" } } } }
        ZenSpec.replace("apps/reader/modules/readerstatus", status)
        ZenSpec.replace("ui/uimanager", { getTopmostVisibleWidget = function() return top end })
        ZenSpec.replace("ui/quickstart", { quickstart_filename = "/quickstart.epub" })
        ZenSpec.replace("ui/elements/common_settings_menu_table", menu)
        ZenSpec.replace("modules/reader/end_book", { show = function() shown = shown + 1 end })
        ZenSpec.replace("datetime", { secondsToClockDuration = function(_format, seconds) return tostring(seconds) end })
    end)

    after_each(function()
        _G.G_reader_settings = settings
        _G.__ZEN_UI_PLUGIN = nil
        for _i, name in ipairs(names) do
            package.loaded[name], _G[name] = saved[name][1], saved[name][2]
        end
    end)

    it("sets the default once and preserves subsequent native choices after reloading", function()
        local apply = require("modules/reader/patches/end_book")
        apply()
        assert.are.equal("zen_end_book", G_reader_settings:readSetting("end_document_action"))
        assert.is_true(G_reader_settings:readSetting("end_document_auto_mark"))
        assert.are.equal(1, plugin.saves)
        G_reader_settings:saveSetting("end_document_action", "nothing")
        G_reader_settings:saveSetting("end_document_auto_mark", false)
        ZenSpec.unload("modules/reader/patches/end_book")
        require("modules/reader/patches/end_book")()
        assert.are.equal("nothing", G_reader_settings:readSetting("end_document_action"))
        assert.is_false(G_reader_settings:readSetting("end_document_auto_mark"))
        assert.are.equal(1, plugin.saves)
        assert.are.equal(2, #menu.document_end_action.sub_item_table)
        status:onEndOfBook()
        assert.are.equal(1, native_calls)
        assert.are.equal(0, shown)
        menu.document_end_action.sub_item_table[2].callback()
        status:onEndOfBook()
        assert.are.equal(1, shown)
        top = { name = "zen_end_book" }
        status:onEndOfBook()
        assert.are.equal(1, shown)
        top = nil
        G_reader_settings:saveSetting("lastfile", "/quickstart.epub")
        status:onEndOfBook()
        assert.are.equal(1, shown)
    end)

    it("does not change an explicit auto-mark preference on first initialization", function()
        G_reader_settings:saveSetting("end_document_auto_mark", false)
        require("modules/reader/patches/end_book")()
        assert.is_false(G_reader_settings:readSetting("end_document_auto_mark"))
    end)

    it("uses only current-book statistics and handles missing or empty records", function()
        local Data = require("modules/reader/end_book_data")
        assert.same({}, Data.stats(nil))
        local statistics = { getStatsBookStatus = function() return { days = 3, time = 7200, pages = 80 } end }
        assert.same({ book_days = "3", book_duration = "7200", book_page_minutes = "1.5",
            book_daily_minutes = "40.0" }, Data.stats(statistics))
        statistics.getStatsBookStatus = function() return { days = 0, time = 0, pages = 0 } end
        assert.same({ book_days = "0", book_duration = "0" }, Data.stats(statistics))
    end)

    it("includes highlight notes and display page labels without exporting xpointers as pages", function()
        local Data = require("modules/reader/end_book_data")
        local updated = false
        local ui = {
            doc_props = { title = "Book" },
            annotation = {
                updatePageNumbers = function() updated = true end,
                annotations = {
                    { page = "/xp/1", pageno = 7, text = "Quote", note = "Note", drawer = "lighten" },
                    { page = "/xp/2", text = "Page bookmark" },
                },
            },
            bookmark = { getBookmarkPageString = function() return "iv" end },
        }
        local quotes = Data.quotes(ui)
        assert.is_true(updated)
        assert.are.equal(1, #quotes)
        assert.are.equal("Quote\n\nNote", quotes[1].text)
        assert.are.equal("iv", quotes[1].page_label)
        assert.are.equal("/xp/1", quotes[1].page)
    end)

    it("selects sequels numerically and only recommends other series already started", function()
        local Data = require("modules/reader/end_book_data")
        local function group(name, files)
            local items = {}
            for index, file in ipairs(files) do items[index] = { file = file, series_index = index } end
            return { series = name, items = items }
        end
        local states = { current = "complete", sequel = "complete", a = "complete", b = "reading",
            c = "complete", d = "complete", e = "complete" }
        local recommendations = Data.recommendations("current", {
            authors = "A\nB", series = "Main", series_index = 1,
        }, {
            { author = "A", files = { "current", "sequel" } },
            { author = "B", files = { "sequel", "another" } },
            { author = "Other", files = { "unrelated" } },
        }, {
            group("Main", { "current", "sequel", "third" }),
            group("Reading", { "a", "b", "later" }),
            group("Started", { "c", "next" }),
            group("Done", { "d", "e" }),
            group("Unstarted", { "new1", "new2" }),
        }, function(file) return states[file] end)
        assert.same({ author = { "sequel", "another" }, next_series = { "third" },
            other_series = { "b", "next" } }, recommendations)
    end)
end)
