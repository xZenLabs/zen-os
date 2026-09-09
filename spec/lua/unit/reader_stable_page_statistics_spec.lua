describe("stable page statistics", function()
    before_each(function()
        ZenSpec.unload("modules/reader/patches/stable_page_statistics")
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
