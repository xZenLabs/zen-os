describe("metadata match ranking", function()
    local Match

    before_each(function()
        ZenSpec.unload("modules/filebrowser/metadata/match")
        Match = require("modules/filebrowser/metadata/match")
    end)

    it("prefers the searched book over derivative titles listed first", function()
        local works = {
            {
                id = 1,
                title = "Summary and Analysis of Project Hail Mary by Andy Weir",
                authors = { "Good Reads Publishing" },
            },
            { id = 2, title = "Project Hail Mary: Study Guide", authors = { "Andy Weir" } },
            { id = 3, title = "Project Hail Mary", authors = { "Someone Else" } },
            { id = 4, title = "PROJECT HAIL MARY", authors = { "Weir, Andy" } },
        }

        local best, confident = Match.best(works, {
            title = "Project Hail Mary",
            authors = { "Andy Weir" },
        })

        assert.are.equal(4, best.id)
        assert.is_true(confident)
    end)

    it("ranks the author above an exact title and accepts subtitles", function()
        local works = {
            { id = 1, title = "The Stand", authors = { "Other Writer" } },
            { id = 2, title = "The Stand: Complete & Uncut", authors = { "Stephen King" } },
        }

        local best, confident = Match.best(works, { title = "The Stand", author = "Stephen King" })

        assert.are.equal(2, best.id)
        assert.is_true(confident)

        best, confident = Match.best(works, { title = "The Stand (Uncut Edition)" })

        assert.are.equal(1, best.id)
        assert.is_true(confident)
    end)

    it("keeps provider order and reports no confidence when nothing fits", function()
        local works = {
            { id = 1, title = "Summary of Dune by Frank Herbert", authors = { "Guides" } },
            { id = 2, title = "Unrelated" },
            { id = 3, title = "Dune's Legacy", authors = { "Guides" } },
        }

        local best, confident = Match.best(works, { title = "Dune", author = "Frank Herbert" })

        assert.are.equal(1, best.id)
        assert.is_false(confident)

        best, confident = Match.best({ works[2], works[3] }, { title = "Dune" })

        assert.are.equal(2, best.id)
        assert.is_false(confident)
        assert.is_nil((Match.best({}, { title = "Dune" })))
    end)
end)
