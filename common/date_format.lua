local BaseUtil = require("ffi/util")
local _ = require("gettext")

local M = {}

local LOWERCASE_MONTH_LANGUAGES = {
    es = true, fr = true, it = true, nl = true, pt = true, ro = true,
}

local MONTH_FIRST_LOCALES = {
    c = true, en = true, en_us = true, posix = true,
}

local function current_locale()
    local settings = rawget(_G, "G_reader_settings")
    local language = settings and settings.readSetting
        and settings:readSetting("language") or "en"
    local locale = tostring(language):match("^[^%.@]+") or "en"
    return locale:gsub("-", "_"):lower()
end

local function current_language()
    return current_locale():match("^[a-z]+") or "en"
end

local function date_value(format, timestamp)
    if timestamp ~= nil then return os.date(format, timestamp) end
    return os.date(format)
end

local function translated_parts(timestamp)
    local datetime = require("datetime")
    local date = date_value("*t", timestamp)
    local month_name = date_value("%B", timestamp)
    local month = datetime.longMonthTranslation[month_name] or month_name
    if LOWERCASE_MONTH_LANGUAGES[current_language()] then
        month = month:gsub("^%u", string.lower)
    end
    return datetime, date, month
end

local function ordinal_day(day)
    local suffix = "th"
    local last_two = day % 100
    if last_two < 11 or last_two > 13 then
        local last = day % 10
        if last == 1 then
            suffix = "st"
        elseif last == 2 then
            suffix = "nd"
        elseif last == 3 then
            suffix = "rd"
        end
    end
    return tostring(day) .. suffix
end

local function without_weekday(month, day)
    -- Reuse the home widget's localized grammar, then remove its marked weekday.
    local marker = "\1"
    local text = BaseUtil.template(_("%1, %2 %3"), marker, month, day)
        :gsub("（" .. marker .. "）", "")
        :gsub(marker, "")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
        :gsub("^[,;:]+%s*", "")
        :gsub("^，%s*", "")
        :gsub("%s*[,;:]+$", "")
        :gsub("%s*，$", "")
    return text
end

function M.format(format, timestamp)
    if format == "short" then
        local date = date_value("*t", timestamp)
        if MONTH_FIRST_LOCALES[current_locale()] then
            return string.format("%02d/%02d/%02d", date.month, date.day, date.year % 100)
        end
        return string.format("%02d/%02d/%02d", date.day, date.month, date.year % 100)
    end

    local date, month = select(2, translated_parts(timestamp))
    local day = current_language() == "en" and ordinal_day(date.day) or tostring(date.day)
    return without_weekday(month, day)
end

function M.formatLongWithWeekday(timestamp)
    local datetime, date, month = translated_parts(timestamp)
    local weekday = datetime.shortDayOfWeekToLongTranslation[datetime.weekDays[date.wday]]
        or date_value("%A", timestamp)
    return BaseUtil.template(_("%1, %2 %3"), weekday, month, tostring(date.day))
end

function M.formatISODate(value)
    local year, month, day = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
    year, month, day = tonumber(year), tonumber(month), tonumber(day)
    if not year or month < 1 or month > 12 or day < 1 or day > 31 then return value end
    local timestamp = os.time{ year = year, month = month, day = day, hour = 12 }
    local date, translated_month = select(2, translated_parts(timestamp))
    local month_name = date_value("%B", timestamp)
    local date_month = _.pgettext("Date month", month_name)
    if date_month ~= month_name then translated_month = date_month end
    -- Translators: month name, day, year; reorder and add local date separators.
    return BaseUtil.template(_("%1 %2 %3"), translated_month, tostring(date.day), tostring(date.year))
end

return M
