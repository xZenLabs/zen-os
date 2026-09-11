describe("bundled font language support", function()
    local FontLanguage = require("common/font_language")

    local function supports(language)
        return FontLanguage.supportsBundledFonts(ZenSpec.memorySettings({ language = language }))
    end

    it("accepts supported Latin-script locale variants", function()
        assert.is_true(supports("en_US.UTF-8"))
        assert.is_true(supports("de_DE"))
        assert.is_true(supports("ku_TR"))
        assert.is_true(supports("pt_BR"))
    end)

    it("rejects locales unsupported by the bundled fonts", function()
        assert.is_false(supports("ru_RU"))
        assert.is_false(supports("zh_CN"))
        assert.is_false(supports("ja_JP"))
        assert.is_false(supports("vi_VN"))
        assert.is_false(supports("ga_IE"))
    end)

    it("identifies languages supported by whole-word search", function()
        local function supports_search(language)
            return FontLanguage.supportsWholeWordSearch(
                ZenSpec.memorySettings({ language = language }))
        end

        assert.is_true(supports_search("en_US"))
        assert.is_true(supports_search("fr"))
        assert.is_false(supports_search("vi_VN"))
        assert.is_false(supports_search("id"))
        assert.is_false(supports_search("ru_RU"))
        assert.is_false(supports_search("zh_CN"))
        assert.is_false(supports_search("ja"))
    end)
end)
