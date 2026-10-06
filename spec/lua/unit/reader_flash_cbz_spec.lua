describe("CBZ page-turn refresh", function()
    local saved_view, saved_paging, saved_manager, saved_plugin

    before_each(function()
        saved_view = package.loaded["apps/reader/modules/readerview"]
        saved_paging = package.loaded["apps/reader/modules/readerpaging"]
        saved_manager = package.loaded["ui/uimanager"]
        saved_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    end)

    after_each(function()
        package.loaded["apps/reader/modules/readerview"] = saved_view
        package.loaded["apps/reader/modules/readerpaging"] = saved_paging
        package.loaded["ui/uimanager"] = saved_manager
        _G.__ZEN_UI_PLUGIN = saved_plugin
        ZenSpec.unload("modules/reader/patches/reader_flash_cbz")
    end)

    it("flashes changed CBZ pages only while enabled and preserves stock page updates", function()
        local refreshes, updates = {}, 0
        local ReaderView = {
            onPageUpdate = function(self, page, mode)
                assert.are.equal("scrolling", mode)
                self.state.page = page
                updates = updates + 1
                return "stock"
            end,
        }
        local view = setmetatable({
            state = { page = 1 },
            document = { file = "/books/comic.cbz" },
            dialog = {},
        }, { __index = ReaderView })
        ZenSpec.replace("apps/reader/modules/readerview", ReaderView)
        ZenSpec.replace("apps/reader/modules/readerpaging", { onGotoViewRel = function() end })
        ZenSpec.replace("ui/uimanager", {
            setDirty = function(_self, widget, mode)
                assert.are.equal(view.dialog, widget)
                assert.are.equal("full", mode)
                refreshes[#refreshes + 1] = view.state.page
            end,
        })
        local plugin = { config = { features = {} } }
        _G.__ZEN_UI_PLUGIN = plugin
        ZenSpec.unload("modules/reader/patches/reader_flash_cbz")
        require("modules/reader/patches/reader_flash_cbz")()
        _G.__ZEN_UI_PLUGIN = nil

        assert.are.equal("stock", view:onPageUpdate(2, "scrolling"))
        assert.are.equal(0, #refreshes)
        plugin.config.features.reader_flash_cbz = true
        view:onPageUpdate(3, "scrolling")
        view:onPageUpdate(3, "scrolling")
        view:onPageUpdate(2, "scrolling")
        view.document.file = "/books/COMIC.CBZ"
        view:onPageUpdate(1, "scrolling")
        assert.same({ 3, 2, 1 }, refreshes)

        for _i, file in ipairs({ "book.pdf", "book.epub", "comic.cbz.zip", "comiccbz" }) do
            view.document.file = file
            view:onPageUpdate(view.state.page + 1, "scrolling")
        end
        plugin.config = { features = { reader_flash_cbz = false } }
        view.document.file = "/books/comic.cbz"
        view:onPageUpdate(6, "scrolling")
        assert.same({ 3, 2, 1 }, refreshes)
        assert.are.equal(10, updates)
    end)

    it("flashes both width-fit taps in paged and scrolling modes", function()
        local refreshes = 0
        local ReaderView = {
            onPageUpdate = function(self, page) self.state.page = page end,
        }
        local ReaderPaging = {
            onGotoViewRel = function(self, diff, key)
                assert.are.equal("key", key)
                self.position = self.position + diff
                if self.position == 2 or self.position < 0 then
                    self.current_page = self.current_page + diff
                    self.position = diff > 0 and 0 or 1
                    self.view:onPageUpdate(self.current_page)
                end
                return "stock"
            end,
        }
        ZenSpec.replace("apps/reader/modules/readerview", ReaderView)
        ZenSpec.replace("apps/reader/modules/readerpaging", ReaderPaging)
        ZenSpec.replace("ui/uimanager", {
            setDirty = function(_self, _widget, mode)
                assert.are.equal("full", mode)
                refreshes = refreshes + 1
            end,
        })
        local plugin = { config = { features = { reader_flash_cbz = true } } }
        _G.__ZEN_UI_PLUGIN = plugin
        ZenSpec.unload("modules/reader/patches/reader_flash_cbz")
        require("modules/reader/patches/reader_flash_cbz")()

        for _i, scrolling in ipairs({ false, true }) do
            local view = setmetatable({
                state = { page = 1 },
                page_scroll = scrolling,
                document = { file = "/books/comic.cbz" },
                dialog = {},
            }, { __index = ReaderView })
            local paging = setmetatable({
                view = view, current_page = 1, position = 0,
            }, { __index = ReaderPaging })
            refreshes = 0

            assert.are.equal("stock", paging:onGotoViewRel(1, "key"))
            assert.are.equal(1, view.state.page)
            assert.are.equal(1, refreshes)
            paging:onGotoViewRel(1, "key")
            assert.are.equal(2, view.state.page)
            assert.are.equal(2, refreshes)
            paging:onGotoViewRel(-1, "key")
            paging:onGotoViewRel(-1, "key")
            assert.are.equal(1, view.state.page)
            assert.are.equal(4, refreshes)

            plugin.config.features.reader_flash_cbz = false
            paging:onGotoViewRel(1, "key")
            assert.are.equal(4, refreshes)
            plugin.config.features.reader_flash_cbz = true
            view.document.file = "/books/book.pdf"
            paging:onGotoViewRel(-1, "key")
            assert.are.equal(4, refreshes)
        end
    end)
end)
