-- Loads the data for the Stats tabs: KOReader's statistics database, the book
-- sidecars and (optionally) zen_stats_legacy.lua with books finished before
-- the statistics plugin was used. Returns the table built by data.lua.

local logger = require("common/zen_logger").new("stats_source")

local M = {}

local function open_fetch()
    local DBConn = require("common/db_connection")
    local conn, err = DBConn.open(DBConn.getStatsDbPath())
    if not conn then return nil, nil, err end
    local function fetch(sql)
        local res, nrow = conn:exec(sql)
        local rows = {}
        if not res then return rows end
        local ncol = #res
        nrow = tonumber(nrow) or (res[1] and #res[1]) or 0
        for i = 1, nrow do
            local row = {}
            for c = 1, ncol do
                local v = res[c][i]
                if type(v) == "cdata" then v = tonumber(v) end
                row[c] = v
            end
            rows[i] = row
        end
        return rows
    end
    return fetch, function() pcall(conn.close, conn) end
end

local function load_legacy()
    local legacy
    pcall(function()
        local DataStorage = require("datastorage")
        local path = DataStorage:getSettingsDir() .. "/zen_stats_legacy.lua"
        local f = io.open(path, "r")
        if not f then return end
        f:close()
        local ok, t = pcall(dofile, path)
        if ok and type(t) == "table" then legacy = t end
    end)
    return legacy
end

--- opts.omnibus: count each work of an omnibus volume as a book (default true).
--- Returns the statistics table, or nil and an error message.
function M.load(opts)
    opts = opts or {}
    local StatsDB = require("common/db_stats")
    if StatsDB.flushPendingStats then pcall(StatsDB.flushPendingStats) end
    local fetch, close, err = open_fetch()
    if not fetch then return nil, err end
    local Books = require("modules/filebrowser/patches/stats_tabs/books")
    local Data = require("modules/filebrowser/patches/stats_tabs/data")
    local meta = Books.scan()
    pcall(Books.estimatePages, meta)
    if opts.omnibus ~= false then
        local ok_o, res = pcall(Books.detectOmnibus, meta)
        if not ok_o then logger.warn("omnibus detection failed:", res) end
    end
    local ok, S = pcall(Data.compute, fetch, meta, os.time(), load_legacy())
    close()
    if not ok then
        logger.warn("compute failed:", S)
        return nil, tostring(S)
    end
    return S
end

return M
