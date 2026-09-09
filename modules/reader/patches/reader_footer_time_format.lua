local function apply_reader_footer_time_format()
    --[[
        Displays "time to chapter" in the selected Zen format.
        Patches ReaderFooter.textGeneratorMap.chapter_time_to_read.
    --]]

    local ReaderFooter = require("apps/reader/modules/readerfooter")
    local _ = require("gettext")
    local T = require("ffi/util").template

    local orig_chapter_time_to_read = ReaderFooter.textGeneratorMap.chapter_time_to_read
    local orig_filler = ReaderFooter.textGeneratorMap.dynamic_filler

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

    -- The dynamic_filler formula adds separator_width back to compensate for the
    -- merged separator, which can push the total over max_width by ~1 space,
    -- causing TextWidget to truncate adjacent items with "...". By removing 6
    -- extra spaces (approx 30px), we guarantee it fits safely without truncation.
    -- Only trim for the longer text formats.
    --
    -- Named local so we can reference it in the genAllFooterText patch below.
    local zen_filler_wrapper = function(footer)
        local text, merge, is_filler = orig_filler(footer)
        local format = get_time_format()
        if (format == "full" or format == "compact")
                and type(text) == "string" and #text > 0 then
            local ct = ReaderFooter.textGeneratorMap.chapter_time_to_read(footer)
            if ct and ct ~= "" then
                if #text > 8 then
                    text = text:sub(1, -7) -- removes 6 spaces
                else
                    text = text:sub(1, 1)  -- fallback to 1 space
                end
            end
        end
        return text, merge, is_filler
    end

    -- On cold/restart start, footerTextGenerators may hold orig_filler while
    -- footerTextGeneratorMap.dynamic_filler is already zen_filler_wrapper.
    -- The skip-by-reference check in genAllFooterText then fails, causing
    -- infinite recursion. Lazily fix up the stale entry on first call.
    local orig_genAllFooterText = ReaderFooter.genAllFooterText
    ReaderFooter.genAllFooterText = function(self, skip_gen)
        if skip_gen == zen_filler_wrapper and self.footerTextGenerators then
            for i, gen in ipairs(self.footerTextGenerators) do
                if gen == orig_filler then
                    self.footerTextGenerators[i] = zen_filler_wrapper
                end
            end
        end
        return orig_genAllFooterText(self, skip_gen)
    end

    ReaderFooter.textGeneratorMap.dynamic_filler = zen_filler_wrapper

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
