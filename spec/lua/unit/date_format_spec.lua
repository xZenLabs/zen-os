describe("date format", function()
    local date_stub
    local original_datetime
    local original_gettext
    local original_settings

    local function install_date(day, month, year, month_name, weekday)
        date_stub = stub(os, "date")
        date_stub.on_call_with("*t").returns({
            day = day, month = month, year = year, wday = 7,
        })
        date_stub.on_call_with("%B").returns(month_name)
        date_stub.on_call_with("%A").returns(weekday or "Saturday")
    end

    local function load_formatter(language, template, translated_month, year_template, date_month)
        _G.G_reader_settings = ZenSpec.memorySettings({ language = language })
        ZenSpec.replace("gettext", setmetatable({ pgettext = function(_context, text)
            return date_month or text
        end }, { __call = function(_self, text)
            if text == "%1, %2 %3" then return template or text end
            if text == "%1 %2 %3" then return year_template or text end
            return text
        end }))
        ZenSpec.replace("datetime", {
            weekDays = { [7] = "Sat" },
            shortDayOfWeekToLongTranslation = { Sat = "Saturday" },
            longMonthTranslation = { August = translated_month or "August", October = translated_month or "October" },
        })
        ZenSpec.unload("common/date_format")
        return require("common/date_format")
    end

    before_each(function()
        original_datetime = package.loaded["datetime"]
        original_gettext = package.loaded["gettext"]
        original_settings = rawget(_G, "G_reader_settings")
    end)

    after_each(function()
        if date_stub then date_stub:revert() end
        date_stub = nil
        ZenSpec.unload("common/date_format")
        package.loaded["datetime"] = original_datetime
        package.loaded["gettext"] = original_gettext
        _G.G_reader_settings = original_settings
    end)

    it("uses month-first short dates for KOReader English", function()
        install_date(23, 8, 2026, "August")
        local formatter = load_formatter("C")

        assert.are.equal("08/23/26", formatter.format("short"))
    end)

    it("uses day-first short dates for other locales", function()
        install_date(23, 8, 2026, "August")
        local formatter = load_formatter("en_GB")

        assert.are.equal("23/08/26", formatter.format("short"))
    end)

    it("adds English ordinal suffixes to the long format", function()
        install_date(8, 8, 2026, "August")
        local formatter = load_formatter("en_US")

        assert.are.equal("August 8th", formatter.format("long"))
        assert.are.equal("Saturday, August 8", formatter.formatLongWithWeekday())
    end)

    it("uses the existing translated date grammar for Spanish", function()
        install_date(15, 8, 2026, "August")
        local formatter = load_formatter("es", "%1, %3 de %2", "Agosto")

        assert.are.equal("15 de agosto", formatter.format("long"))
    end)

    it("removes trailing weekday punctuation in Chinese", function()
        install_date(8, 8, 2026, "August")
        local formatter = load_formatter("zh_CN", "%2%3日，%1", "八月")

        assert.are.equal("八月8日", formatter.format("long"))
    end)

    it("removes the empty weekday parentheses in Japanese", function()
        install_date(8, 8, 2026, "August")
        local formatter = load_formatter("ja", "%2%3日（%1）", "8月")

        assert.are.equal("8月8日", formatter.format("long"))
    end)

    it("formats annotation dates with a year and no time or ordinal", function()
        local formatter = load_formatter("en")
        assert.are.equal("October 18 2026", formatter.formatISODate("2026-10-18 23:59:00"))
    end)

    it("uses Spanish grammar and lowercase month names for annotation dates", function()
        local formatter = load_formatter("es", nil, "Octubre", "%2 de %1 %3")
        assert.are.equal("18 de octubre 2026", formatter.formatISODate("2026-10-18 00:00:00"))
    end)

    it("puts the year first in Chinese annotation dates", function()
        local formatter = load_formatter("zh_CN", nil, "十月", "%3年%1%2日")
        assert.are.equal("2026年十月18日", formatter.formatISODate("2026-10-18 12:00:00"))
    end)

    it("uses inflected month translations where date grammar needs them", function()
        local formatter = load_formatter("ru", nil, "Октябрь", "%2 %1 %3", "октября")
        assert.are.equal("18 октября 2026", formatter.formatISODate("2026-10-18 12:00:00"))
    end)

    it("preserves missing or unrecognized dates", function()
        local formatter = load_formatter("en")
        for _i, value in ipairs({ "", "unknown", "2026-13-18", "2026-10-00" }) do
            assert.are.equal(value, formatter.formatISODate(value))
        end
    end)
end)
