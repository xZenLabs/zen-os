local function apply_reader_footer_time_format()
    --[[
        Displays "time to chapter" in the selected Zen format.
        Patches ReaderFooter.textGeneratorMap.chapter_time_to_read.
    --]]

    local ReaderFooter = require("apps/reader/modules/readerfooter")
    local _ = require("gettext")
    local T = require("ffi/util").template

    local orig_chapter_time_to_read = ReaderFooter.textGeneratorMap.chapter_time_to_read

    -- Capture at apply time (while __ZEN_UI_PLUGIN is set); fall back to
    -- re-reading the global for late callers (same pattern as reader_top_status_bar.lua).
    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")

    local function get_time_format()
        local plugin = zen_plugin or rawget(_G, "__ZEN_UI_PLUGIN")
        local rf_config = plugin and plugin.config and plugin.config.reader_footer
        if type(rf_config) ~= "table" then return "number" end
        local format = rf_config.chapter_time_format
        if format == "full" or format == "compact" or format == "number"
                or format == "koreader" then
            return format
        end
        return rf_config.verbose_chapter_time == true and "full" or "number"
    end

    local function format_short_duration(total_minutes)
        if total_minutes < 1 then return T(_("< %1m"), 1) end
        local hours = math.floor(total_minutes / 60)
        local minutes = total_minutes % 60
        if hours == 0 then return T(_("%1m"), minutes) end
        if minutes == 0 then return T(_("%1h"), hours) end
        return T(_("%1h %2m"), hours, minutes)
    end

    ReaderFooter.textGeneratorMap.chapter_time_to_read = function(footer)
        if get_time_format() == "koreader" then
            return orig_chapter_time_to_read(footer)
        end
        local stats = footer.ui.statistics
        -- avg_time > 0 also rules out NaN (NaN > 0 is false in LuaJIT)
        if stats and stats.settings and stats.settings.is_enabled
                and stats.avg_time and stats.avg_time > 0 then
            local left = footer.ui.toc:getChapterPagesLeft(footer.pageno, true)
                       or footer.ui.document:getTotalPagesLeft(footer.pageno)
            if left and left > 0 then
                if type(stats._zenPagesInStatisticsUnits) == "function" then
                    left = stats:_zenPagesInStatisticsUnits(left)
                end
                local total_minutes = math.floor(left * stats.avg_time / 60)
                -- Use non-breaking spaces (\u{00A0}) so compact mode's
                -- gsub("%s", hair-space) in genAllFooterText doesn't convert
                -- them. This preserves the true text width for dynamic filler
                -- layout calculation.
                local nbsp = "\u{00A0}"
                -- A leading hair-space (\u{200A}) provides minimal visual
                -- separation from the preceding item (e.g. page numbers)
                -- without doubling the visible gap the separator already
                -- supplies. It is narrower than \u{00A0} and is not an
                -- ASCII space, so the compact_items gsub leaves it alone.
                local hair = "\u{200A}"
                local minutes = total_minutes < 1 and "< 1" or tostring(total_minutes)
                local format = get_time_format()
                if format == "number" then
                    return hair .. format_short_duration(total_minutes)
                end
                local template = format == "compact"
                    and _("%1 min left") or _("%1 min left in chapter")
                return hair .. T(template, minutes):gsub(" ", nbsp)
            end
        end
        return ""
    end
end

return apply_reader_footer_time_format
