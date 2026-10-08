require("ffi/loadlib")
local AuthorSort = require("common/author_sort")
local sort_key = require("common/sort_key")

describe("author sort", function()
    it("keeps compound surnames and honors explicit surname-first names", function()
        assert.are.equal("García Márquez", AuthorSort.key("Gabriel García Márquez", "authors_last"))
        assert.are.equal("Vargas Llosa", AuthorSort.key("Mario Vargas Llosa", "authors_last"))
        assert.are.equal("de la Cruz", AuthorSort.key("Juana de la Cruz", "authors_last"))
        assert.are.equal("Tolkien", AuthorSort.key("Tolkien, John Ronald Reuel", "authors_last"))
        assert.are.equal("García Márquez", AuthorSort.key("García Márquez, Gabriel", "authors_last"))
        assert.are.equal("Gabriel", AuthorSort.key("García Márquez, Gabriel", "authors"))
        assert.are.equal("Lovelace", AuthorSort.key("Ada Lovelace\nGrace Hopper", "authors_last"))
        assert.are.equal("Ada", AuthorSort.key("Ada Lovelace\nGrace Hopper", "authors"))
        assert.are.equal("Voltaire", AuthorSort.key("Voltaire", "authors_last"))
        assert.are.equal("", AuthorSort.key(nil, "authors_last"))
    end)

    it("sorts compound surnames and Latin diacritics by their base letters", function()
        local authors = {
            "Alice Klein", "Tatiana Țîbuleac", "Gabriel García Márquez",
            "Karel Čapek", "Jane Austen", "Octavia Butler", "Aaron Zulu",
        }
        table.sort(authors, function(a, b) return AuthorSort.less(a, b, "authors_last") end)
        assert.are.same({
            "Jane Austen", "Octavia Butler", "Karel Čapek", "Gabriel García Márquez",
            "Alice Klein", "Tatiana Țîbuleac", "Aaron Zulu",
        }, authors)
        assert.is_true(AuthorSort.less("Čestmír Novák", "David Brown", "authors"))
        assert.is_true(AuthorSort.less("Karel C\u{030C}apek", "Octavia Delta", "authors_last"))
        assert.is_false(AuthorSort.less("Karel Čapek", "Karel Čapek", "authors_last"))
    end)

    it("normalizes composed and combining Latin marks without stripping other scripts", function()
        assert.are.equal("capek tibuleac", sort_key("ČAPEK ȚÎBULEAC"))
        assert.are.equal("capek tibuleac", sort_key("C\u{030C}apek T\u{0326}i\u{0302}buleac"))
        assert.are.equal("a", sort_key("A\u{0302}\u{0323}"))
        assert.are.equal("a", sort_key("a\u{0301}\u{0301}"))
        assert.are.equal("й ё 中文", sort_key("Й Ё 中文"))
        assert.are.equal("broken \255", sort_key("Broken \255"))
        assert.are.equal("", sort_key(nil))
    end)

    it("caches author keys per sort and preserves first-name, last-name and full-name ties", function()
        local authors = { "Émile Zola", "Émile Čapek", "Austen, Jane", "Gabriel García Márquez", "Jane Austen" }
        local original_key = AuthorSort.key
        local calls = {}
        AuthorSort.key = function(value, mode)
            calls[value] = (calls[value] or 0) + 1
            return original_key(value, mode)
        end
        local ok, err = pcall(function()
            for _i, mode in ipairs({ "authors", "authors_last" }) do
                local expected, actual = { unpack(authors) }, { unpack(authors) }
                table.sort(expected, function(a, b) return AuthorSort.less(a, b, mode) end)
                calls = {}
                local compare = AuthorSort.comparator(mode)
                table.sort(actual, compare)
                table.sort(actual, compare)
                assert.are.same(expected, actual)
                for _j, author in ipairs(authors) do assert.are.equal(1, calls[author]) end
            end
        end)
        AuthorSort.key = original_key
        assert(ok, err)
    end)
end)
