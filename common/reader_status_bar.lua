local M = {}

function M.isMarginAlignmentEnabled(plugin)
    local features = plugin and plugin.config and plugin.config.features
    return features and features.reader_status_bar_margins == true or false
end

function M.getHorizontalMargins(document, fallback, plugin)
    if not M.isMarginAlignmentEnabled(plugin) then return fallback, fallback end
    if document and type(document.getPageMargins) == "function" then
        local margins = document:getPageMargins()
        return margins.left, margins.right
    end
    local margins = document and document.configurable and document.configurable.h_page_margins
    if not margins then return fallback, fallback end
    local Screen = require("device").screen
    return Screen:scaleBySize(margins[1]), Screen:scaleBySize(margins[2])
end

function M.disableKoreaderAltStatusBar(settings, reader)
    settings = settings or rawget(_G, "G_reader_settings")
    if settings and type(settings.saveSetting) == "function" then
        settings:saveSetting("copt_status_line", 1)
        settings:saveSetting("alt_status_bar", false)
    end

    if reader == nil then
        local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
        reader = ok_reader and ReaderUI and ReaderUI.instance
    end
    local configurable = reader and reader.document and reader.document.configurable
    if not (reader and reader.rolling and configurable) then return false end

    configurable.status_line = 1
    if type(reader.handleEvent) == "function" then
        local Event = require("ui/event")
        reader:handleEvent(Event:new("SetStatusLine", 1))
    elseif type(reader.rolling.onSetStatusLine) == "function" then
        reader.rolling:onSetStatusLine(1)
    end
    return true
end

return M
