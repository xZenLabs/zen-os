describe("TOC tree", function()
    local TocTree = require("modules/reader/toc_tree")

    local function tree()
        return TocTree.link({
            { title = "Part 1", depth = 1 }, { title = "Chapter 1", depth = 2 }, { title = "Section 1.1", depth = 3 },
            { title = "Chapter 2", depth = 2 }, { title = "Part 2", depth = 1 }, { title = "Orphan", depth = 3 },
        }, { 1, 10, 12, 20, 30, 40 }, 51)
    end

    local function titles(entries)
        local names = {}
        for i, e in ipairs(entries) do names[i] = e.title end
        return names
    end

    it("links parents and measures chapters to the next entry at their depth or above", function()
        local t = tree()
        assert.is_true(t.nested)
        assert.are.same({ 1, 2, 3, 4, 5, 6 }, { t[1].idx, t[2].idx, t[3].idx, t[4].idx, t[5].idx, t[6].idx })
        assert.are.same({ t[1], t[2], t[1], t[5] }, { t[2].parent, t[3].parent, t[4].parent, t[6].parent })
        assert.is_nil(t[1].parent)
        assert.is_nil(t[5].parent)
        assert.are.same({ true, true, true }, { t[1].has_children, t[2].has_children, t[5].has_children })
        assert.is_nil(t[3].has_children)
        assert.is_nil(t[4].has_children)
        assert.are.same({ 29, 10, 8, 10, 21, 11 }, { t[1].page_count, t[2].page_count, t[3].page_count,
            t[4].page_count, t[5].page_count, t[6].page_count })
    end)

    it("leaves flat lists unlinked and skips counts without positions", function()
        local flat = TocTree.link({ { depth = 1 }, { depth = 1 }, { depth = 1 } }, { 5, nil, 9 }, nil)
        assert.is_nil(flat.nested)
        assert.is_nil(flat[1].parent)
        assert.is_nil(flat[1].has_children)
        assert.is_nil(flat[1].page_count) -- next entry has no position
        assert.are.equal(1, TocTree.link({ { depth = 1 }, { depth = 1 } }, { 9, 5 }, nil)[1].page_count)
        assert.is_nil(flat[3].page_count) -- no book end
        assert.is_nil(TocTree.foldState(flat[1], {}, flat.nested))
    end)

    it("shows the top level plus the current chapter's ancestors and refolds descendants on collapse", function()
        local t = tree()
        local expanded = TocTree.initialFolding(t[3])
        assert.is_true(expanded[t[1]])
        assert.is_true(expanded[t[2]])
        assert.are.same({ "Part 1", "Chapter 1", "Section 1.1", "Chapter 2", "Part 2" },
            titles(TocTree.visible(t, expanded)))
        assert.are.same({ "Part 1", "Part 2" }, titles(TocTree.visible(t, TocTree.initialFolding(t[5]))))
        assert.are.same({}, TocTree.initialFolding(nil))

        TocTree.toggle(t, t[5], expanded)
        assert.are.same({ "Part 1", "Chapter 1", "Section 1.1", "Chapter 2", "Part 2", "Orphan" },
            titles(TocTree.visible(t, expanded)))
        TocTree.toggle(t, t[1], expanded)
        assert.are.same({ "Part 1", "Part 2", "Orphan" }, titles(TocTree.visible(t, expanded)))
        assert.is_nil(expanded[t[2]])
        TocTree.toggle(t, t[1], expanded)
        assert.are.same({ "Part 1", "Chapter 1", "Chapter 2", "Part 2", "Orphan" },
            titles(TocTree.visible(t, expanded)))
        assert.are.same({ "expanded", "collapsed", "leaf" }, { TocTree.foldState(t[1], expanded, t.nested),
            TocTree.foldState(t[2], expanded, t.nested), TocTree.foldState(t[3], expanded, t.nested) })
    end)

    it("formats page counts only when enabled and reads the page browser setting", function()
        local t = tree()
        assert.are.equal("(29)", TocTree.countText(t[1], true))
        assert.is_nil(TocTree.countText(t[1], false))
        assert.is_nil(TocTree.countText({}, true))
        assert.is_true(TocTree.showsCounts({ config = { page_browser = { toc_show_page_counts = true } } }))
        assert.is_false(TocTree.showsCounts({ config = { page_browser = {} } }))
        assert.is_false(TocTree.showsCounts({ config = {} }))
        assert.is_false(TocTree.showsCounts(nil))
    end)
end)
