describe("page browser tabs", function()
    local Tabs
    before_each(function()
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.unload("modules/reader/page_browser_tabs")
        Tabs = require("modules/reader/page_browser_tabs")
    end)

    local function ids(entries)
        local result = {}
        for _i, entry in ipairs(entries) do result[#result + 1] = entry.id end
        return result
    end

    it("defaults to separate bookmarks and highlights and adapts the controls tab to the book", function()
        assert.same({ "browser", "aa", "bookmarks", "highlights", "toc" }, ids(Tabs.list({})))
        local entries = Tabs.list({}, { paging = {} }, true)
        assert.are.equal(9, #entries)
        assert.are.equal("pins", entries[7].id)
        assert.are.equal("pin", entries[7].icon)
        assert.are.equal("book_details", entries[8].id)
        assert.are.equal("Book details", entries[8].text)
        assert.are.equal("Contrast", entries[2].text)
        assert.are.equal("appbar.contrast", entries[2].icon)
        assert.are.equal("bookmark_outline", entries[3].icon)
        assert.are.equal("annotations", entries[6].icon)
        assert.are.equal("Font", Tabs.list({}, { rolling = {} })[2].text)
        assert.are.equal("font", Tabs.list({}, { rolling = {} })[2].icon)
    end)

    it("keeps saved order, skips disabled tabs, and repairs unknown or empty orders", function()
        local config = { page_browser = { tab_order = { "highlights", "unknown", "aa", "aa", "annotations" },
            tabs = { highlights = false, aa = false, annotations = true } } }
        assert.same({ "annotations", "browser", "bookmarks", "toc" }, ids(Tabs.list(config)))
        assert.same({ "highlights", "aa", "annotations", "browser", "bookmarks", "toc", "pins", "book_details",
            "book_switcher" },
            config.page_browser.tab_order)
        for id in pairs(config.page_browser.tabs) do config.page_browser.tabs[id] = false end
        assert.same({ "browser" }, ids(Tabs.list(config)))
    end)

    it("migrates old annotation choices without replacing newer page-browser choices", function()
        local config = { annotation_viewer = { tabs = { bookmarks = true, highlights = true, annotations = false } },
            page_browser = { tabs = { bookmarks = false } } }
        assert.is_true(Tabs.migrate(config))
        assert.is_nil(config.annotation_viewer.tabs)
        assert.same({ "browser", "aa", "highlights", "toc" }, ids(Tabs.list(config)))
        assert.is_false(Tabs.migrate(config))
    end)

    it("uses the Zen arrange list to save ordering and visibility and retain one enabled tab", function()
        local arrange, saves = nil, 0
        ZenSpec.replace("common/ui/zen_arrange_list", { show = function(options) arrange = options end })
        local config = {}
        Tabs.show(config, { saveConfig = function() saves = saves + 1 end }, {})
        assert.are.equal("Tabs", arrange.title)
        local rows = arrange.item_table
        assert.are.equal(9, #rows)
        assert.is_false(rows[7].checked_func())
        assert.is_false(rows[8].checked_func())
        assert.are.equal("Book switcher", rows[9].text)
        assert.is_false(rows[9].checked_func())
        assert.is_false(rows[6].checked_func())
        rows[6].callback()
        assert.is_true(rows[6].checked_func())
        local annotations = table.remove(rows, 6)
        table.insert(rows, 1, annotations)
        arrange.callback()
        assert.are.equal("annotations", Tabs.list(config)[1].id)
        for _i = 2, #rows do if rows[_i].checked_func() then rows[_i].callback() end end
        assert.same({ "annotations" }, ids(Tabs.list(config)))
        annotations.callback()
        assert.is_true(annotations.checked_func())
        assert.are.equal(7, saves)
    end)

    it("enables and reorders the optional book details tab", function()
        local config = { page_browser = { tab_order = { "book_details" }, tabs = { book_details = true } } }
        local entries = Tabs.list(config)
        assert.are.equal("book_details", entries[1].id)
        assert.are.equal("info", entries[1].icon)
        assert.same({ "book_details", "browser", "aa", "bookmarks", "highlights", "toc" }, ids(entries))
    end)

    it("includes a dispatcher target without saving a disabled tab as enabled", function()
        local config = {}
        assert.same({ "browser", "aa", "bookmarks", "highlights", "toc", "annotations" },
            ids(Tabs.list(config, nil, false, "annotations")))
        assert.is_false(config.page_browser.tabs.annotations)
        assert.same({ "browser", "aa", "bookmarks", "highlights", "toc" }, ids(Tabs.list(config)))
    end)

    it("keeps the book switcher off by default and supports enabling, ordering, and targeting it", function()
        local config = {}
        assert.is_false(Tabs.get(config).tabs.book_switcher)
        assert.same({ "browser", "aa", "bookmarks", "highlights", "toc", "book_switcher" },
            ids(Tabs.list(config, nil, false, "book_switcher")))
        assert.is_false(config.page_browser.tabs.book_switcher)
        config.page_browser.tabs.book_switcher = true
        config.page_browser.tab_order = { "book_switcher" }
        local entries = Tabs.list(config)
        assert.are.equal("book_switcher", entries[1].id)
        assert.are.equal("Book switcher", entries[1].text)
        assert.are.equal("history", entries[1].icon)
    end)
end)
