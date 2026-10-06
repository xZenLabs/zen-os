require("ffi/loadlib")
local TitleSort = require("common/title_sort")

describe("title sort", function()
    local original_language

    before_each(function()
        original_language = G_reader_settings:readSetting("language")
    end)

    after_each(function()
        G_reader_settings:saveSetting("language", original_language)
    end)

    it("moves supported leading articles without changing other titles", function()
        assert.are.equal("Left Hand of Darkness", TitleSort.key("The Left Hand of Darkness"))
        assert.are.equal("Archive", TitleSort.key("An Archive"))
        assert.are.equal("A-Frame", TitleSort.key("A-Frame"))
        assert.are.equal("123", TitleSort.key("  123"))
    end)

    it("sorts article-free keys lexically or naturally", function()
        local titles = { "The Volume 10", "Volume 2", "An Alpha" }
        table.sort(titles, function(a, b) return TitleSort.less(a, b, false) end)
        assert.are.same({ "An Alpha", "The Volume 10", "Volume 2" }, titles)

        table.sort(titles, function(a, b) return TitleSort.less(a, b, true) end)
        assert.are.same({ "An Alpha", "Volume 2", "The Volume 10" }, titles)
    end)

    it("moves Spanish titles under the word after their article", function()
        G_reader_settings:saveSetting("language", "es_ES")

        assert.are.equal("blues de Beale Street", TitleSort.key("El blues de Beale Street"))
        assert.are.equal("castillo", TitleSort.key("El castillo"))
    end)

    it("sorts Latin diacritics by their base letters in both title modes", function()
        for _i, natural in ipairs({ false, true }) do
            local titles = { "Zulu", "The Ținut", "Čapek", "Delta", "Éclair" }
            table.sort(titles, function(a, b) return TitleSort.less(a, b, natural) end)
            assert.are.same({ "Čapek", "Delta", "Éclair", "The Ținut", "Zulu" }, titles)
            assert.is_true(TitleSort.less("C\u{030C}apek", "Delta", natural))
            assert.is_true(TitleSort.less("ȚÎNUT", "Zulu", natural))
            assert.is_false(TitleSort.less("Čapek", "Čapek", natural))
        end
        assert.is_true(TitleSort.less("Épisode 2", "Episode 10", true))
        assert.is_true(TitleSort.less("Épisode 10", "Episode 2", false))
    end)
end)
