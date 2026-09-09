local PAGE_COUNT_KEY = "_zen_statistics_page_count"

local function raw_page_count(stats)
    local count = tonumber(stats.data and stats.data.pages)
    local document = stats.document or stats.ui and stats.ui.document
    if not count and document and type(document.getPageCount) == "function" then
        count = tonumber(document:getPageCount())
    end
    return count and count > 0 and count or nil
end

local function stable_page_position(stats)
    local pagemap = stats.ui and stats.ui.pagemap
    if not (pagemap and type(pagemap.wantsPageLabels) == "function"
            and type(pagemap.getCurrentPageLabel) == "function") then
        return nil, nil
    end
    if not pagemap:wantsPageLabels() then return nil, nil end
    local current, count = select(2, pagemap:getCurrentPageLabel())
    current, count = tonumber(current), tonumber(count)
    return current, count and count > 0 and count or nil
end

local function stable_page_count(stats)
    return select(2, stable_page_position(stats))
end

local function statistics_page_count(stats)
    local count = tonumber(stats[PAGE_COUNT_KEY])
        or tonumber(stats.data and stats.data[PAGE_COUNT_KEY])
    return count and count > 0 and count or raw_page_count(stats)
end

local function pages_in_statistics_units(stats, pages)
    pages = tonumber(pages)
    local raw_count = raw_page_count(stats)
    local stats_count = statistics_page_count(stats)
    if not (pages and raw_count and stats_count) then return pages end
    return pages * stats_count / raw_count
end

return function()
    local ok_loader, PluginLoader = pcall(require, "pluginloader")
    if not ok_loader or type(PluginLoader.loadPlugins) ~= "function" then return end

    local Statistics
    for _i, plugin_class in ipairs(PluginLoader:loadPlugins() or {}) do
        if plugin_class.name == "statistics" then
            Statistics = plugin_class
            break
        end
    end
    if not Statistics or Statistics._zen_stable_page_stats
            or type(Statistics.insertDB) ~= "function" then return end
    Statistics._zen_stable_page_stats = true
    Statistics._zenPagesInStatisticsUnits = pages_in_statistics_units

    local original_insertDB = Statistics.insertDB
    Statistics.insertDB = function(self, updated_pagecount)
        local target_count = stable_page_count(self) or updated_pagecount
        local result = original_insertDB(self, target_count)
        if self.id_curr_book and self.is_doc_not_frozen then
            target_count = tonumber(target_count)
            target_count = target_count and target_count > 0 and target_count
                or raw_page_count(self)
            self[PAGE_COUNT_KEY] = target_count
            if type(self.data) == "table" then
                self.data[PAGE_COUNT_KEY] = target_count
            end
        end
        return result
    end

    if type(Statistics.initData) == "function" then
        local original_initData = Statistics.initData
        Statistics.initData = function(self, ...)
            local result = original_initData(self, ...)
            self[PAGE_COUNT_KEY] = statistics_page_count(self)
            return result
        end
    end

    if type(Statistics.onPageUpdate) == "function" then
        local original_onPageUpdate = Statistics.onPageUpdate
        Statistics.onPageUpdate = function(self, ...)
            local result = original_onPageUpdate(self, ...)
            local raw_count = raw_page_count(self)
            local stats_count = statistics_page_count(self)
            if raw_count and stats_count and raw_count ~= stats_count then
                -- ponytail: pending pages are proportional until the next DB flush supplies exact totals.
                local pages = (tonumber(self.book_read_pages) or 0)
                    + (tonumber(self.mem_read_pages) or 0) * stats_count / raw_count
                if pages > 0 then
                    self.avg_time = ((tonumber(self.book_read_time) or 0)
                        + (tonumber(self.mem_read_time) or 0)) / pages
                end
            end
            return result
        end
    end

    if type(Statistics.getTimeForPages) == "function" then
        local original_getTimeForPages = Statistics.getTimeForPages
        Statistics.getTimeForPages = function(self, pages)
            return original_getTimeForPages(self,
                pages_in_statistics_units(self, pages))
        end
    end

    if type(Statistics.getCurrentStat) == "function" then
        local original_getCurrentStat = Statistics.getCurrentStat
        Statistics.getCurrentStat = function(self, ...)
            local current, count = stable_page_position(self)
            local document = self.document
            local ui = self.ui
            if not (current and count and type(document) == "table"
                    and type(ui) == "table") then
                return original_getCurrentStat(self, ...)
            end

            local saved_document_get_page_count = rawget(document, "getPageCount")
            local saved_ui_get_current_page = rawget(ui, "getCurrentPage")
            local saved_data_pages = self.data and self.data.pages
            document.getPageCount = function() return count end
            ui.getCurrentPage = function() return current end
            local ok, result = pcall(original_getCurrentStat, self, ...)
            document.getPageCount = saved_document_get_page_count
            ui.getCurrentPage = saved_ui_get_current_page
            if self.data then self.data.pages = saved_data_pages end
            if not ok then error(result) end
            return result
        end
    end
end
