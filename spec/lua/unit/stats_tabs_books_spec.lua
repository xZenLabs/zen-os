describe("stats tabs books", function()
    local Books

    before_each(function()
        ZenSpec.unload("modules/filebrowser/patches/stats_tabs/books")
        Books = require("modules/filebrowser/patches/stats_tabs/books")
    end)

    -- four top level TOC entries of 200 standard pages each
    local function four_parts()
        local entries = {}
        for i, title in ipairs({ "The Hunt", "The Feast", "The Ball", "The Fall" }) do
            entries[i] = { title = title, pos = (i - 1) * 200 * 2400 }
        end
        return { total = 4 * 200 * 2400, entries = entries }
    end

    it("keeps a novel with named parts as one book", function()
        assert.is_nil(Books.omnibusParts(four_parts(), "The Butcher's Masquerade", 2400))
    end)

    it("splits a book whose title names a collection", function()
        local parts = Books.omnibusParts(four_parts(), "The Dungeon Omnibus", 2400)
        assert.are.equal(4, #parts)
        assert.are.equal("The Hunt", parts[1].title)
    end)
end)
