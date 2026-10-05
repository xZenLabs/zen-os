describe("stable page statistics", function()
    local saved_plugin, saved_settings

    before_each(function()
        saved_plugin, saved_settings = _G.__ZEN_UI_PLUGIN, G_reader_settings
        _G.__ZEN_UI_PLUGIN = nil
        ZenSpec.unload("modules/reader/patches/stable_page_statistics")
    end)

    after_each(function()
        _G.__ZEN_UI_PLUGIN, _G.G_reader_settings = saved_plugin, saved_settings
    end)

    it("freezes finished books once for fresh and existing installs while preserving later choices", function()
        for _i, initial in ipairs({ {}, { statistics = {
            freeze_finished_books = false, is_enabled = false, min_sec = 12, max_sec = 90,
        } } }) do
            local defaults = { freeze_finished_books = false, is_enabled = true, min_sec = 5, max_sec = 120 }
            local expected = initial.statistics or defaults
            local Statistics = {
                name = "statistics", settings_key = "statistics", default_settings = defaults,
                insertDB = function() end,
            }
            ZenSpec.replace("pluginloader", { loadPlugins = function() return { Statistics } end })
            _G.G_reader_settings = ZenSpec.memorySettings(initial)
            local saves = 0
            local plugin = { config = { _meta = {} }, saveConfig = function() saves = saves + 1 end }
            _G.__ZEN_UI_PLUGIN = plugin
            local apply = require("modules/reader/patches/stable_page_statistics")

            apply()
            local settings = G_reader_settings:readSetting("statistics")
            assert.is_table(settings)
            assert.is_true(settings.freeze_finished_books)
            assert.equals(expected.is_enabled, settings.is_enabled)
            assert.equals(expected.min_sec, settings.min_sec)
            assert.equals(expected.max_sec, settings.max_sec)
            assert.is_true(plugin.config._meta.statistics_freeze_finished_default_applied)

            settings.freeze_finished_books = false
            Statistics._zen_stable_page_stats = nil -- Simulate the next KOReader session.
            ZenSpec.unload("modules/reader/patches/stable_page_statistics")
            require("modules/reader/patches/stable_page_statistics")()
            assert.is_false(settings.freeze_finished_books)
            assert.equals(1, saves)
        end
    end)

    it("uses the active page-map count as KOReader's statistics target", function()
        local inserted_pagecount
        local Statistics = {
            name = "statistics",
            insertDB = function(_self, pagecount)
                inserted_pagecount = pagecount
            end,
        }
        ZenSpec.replace("pluginloader", {
            loadPlugins = function() return { Statistics } end,
        })
        require("modules/reader/patches/stable_page_statistics")()

        local use_labels = true
        local stats = setmetatable({
            ui = {
                pagemap = {
                    wantsPageLabels = function() return use_labels end,
                    getCurrentPageLabel = function() return "12", 12, 321 end,
                },
            },
        }, { __index = Statistics })

        stats:insertDB(654)
        assert.are.equal(321, inserted_pagecount)

        use_labels = false
        stats:insertDB(654)
        assert.are.equal(654, inserted_pagecount)
    end)

    it("keeps averages and time estimates in the database page unit", function()
        local Statistics = {
            name = "statistics",
            insertDB = function() end,
            initData = function(self) self.data.pages = 1000 end,
            onPageUpdate = function(self)
                self.mem_read_pages = 10
                self.mem_read_time = 200
            end,
            getTimeForPages = function(_self, pages) return pages end,
        }
        ZenSpec.replace("pluginloader", {
            loadPlugins = function() return { Statistics } end,
        })
        require("modules/reader/patches/stable_page_statistics")()

        local stats = setmetatable({
            id_curr_book = 1,
            is_doc_not_frozen = true,
            data = { pages = 1000, _zen_statistics_page_count = 300 },
            book_read_pages = 30,
            book_read_time = 1800,
        }, { __index = Statistics })

        stats:initData()
        assert.are.equal(300, stats._zen_statistics_page_count)
        assert.are.equal(30, stats:getTimeForPages(100))

        stats:onPageUpdate(2)
        assert.is_true(math.abs(stats.avg_time - 2000 / 33) < 0.001)
    end)

    it("uses stable positions inside KOReader's current-book calculations", function()
        local inserted_pagecount
        local Statistics = {
            name = "statistics",
            insertDB = function(_self, pagecount)
                inserted_pagecount = pagecount
            end,
            getCurrentStat = function(self)
                self:insertDB()
                self.data.pages = self.document:getPageCount()
                return {
                    current = self.ui:getCurrentPage(),
                    total = self.data.pages,
                }
            end,
        }
        ZenSpec.replace("pluginloader", {
            loadPlugins = function() return { Statistics } end,
        })
        require("modules/reader/patches/stable_page_statistics")()

        local document = { getPageCount = function() return 1000 end }
        local ui = {
            getCurrentPage = function() return 500 end,
            pagemap = {
                wantsPageLabels = function() return true end,
                getCurrentPageLabel = function() return "150", 150, 300 end,
            },
        }
        local stats = setmetatable({
            id_curr_book = 1,
            is_doc_not_frozen = true,
            data = { pages = 1000 },
            document = document,
            ui = ui,
        }, { __index = Statistics })

        assert.are.same({ current = 150, total = 300 }, stats:getCurrentStat())
        assert.are.equal(300, inserted_pagecount)
        assert.are.equal(1000, stats.data.pages)
        assert.are.equal(1000, document:getPageCount())
        assert.are.equal(500, ui:getCurrentPage())
    end)
end)
