local DataStorage = require("datastorage")
local Device = require("device")
local lfs = require("libs/libkoreader-lfs")
local sqlite3 = require("lua-ljsqlite3/init")
local logger = require("common/zen_logger").new("docprops_cache")

local M = {}
local DB_PATH = DataStorage:getSettingsDir() .. "/docprops_cache.sqlite"
local db
local verified -- quick_check + schema ran on this file this process
local in_operation

function M.close()
    if db then db:close() end
    db = nil
end

local function open_db()
    if db then return db end
    if verified and not lfs.attributes(DB_PATH, "mode") then verified = nil end
    db = sqlite3.open(DB_PATH)
    -- Full-file scan once per process; the handle is reopened on every UI swap.
    if not verified then
        local check = db:exec("PRAGMA quick_check(1)")[1][1]
        if check ~= "ok" then error("ljsqlite3[corrupt] " .. tostring(check)) end
    end
    local mode = Device:canUseWAL() and "WAL" or "TRUNCATE"
    mode = db:exec("PRAGMA journal_mode = " .. mode)[1][1]
    -- WAL/NORMAL keeps a rebuildable cache consistent without syncing every insert.
    db:exec("PRAGMA synchronous = " .. (mode == "wal" and "NORMAL" or "FULL"))
    db:exec("PRAGMA temp_store = MEMORY; PRAGMA cache_size = -2000;")
    if verified then return db end
    db:exec([[
        CREATE TABLE IF NOT EXISTS doc_props_cache (
            cache_key TEXT PRIMARY KEY,
            props TEXT,
            created_at INTEGER
        );
        CREATE TABLE IF NOT EXISTS zen_doc_status_cache (
            path TEXT PRIMARY KEY,
            signature TEXT NOT NULL,
            home_root TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT '',
            percent_finished REAL NOT NULL DEFAULT -1,
            effective_status TEXT NOT NULL DEFAULT 'new',
            sort_title TEXT NOT NULL DEFAULT '',
            series_index REAL NOT NULL DEFAULT -1,
            access_time INTEGER NOT NULL DEFAULT 0,
            updated_at INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS zen_doc_status_home_tbr
            ON zen_doc_status_cache(home_root, status, effective_status);
    ]])
    verified = true
    return db
end

local function preserve_corrupt_db()
    M.close() -- Both cache users must release the same handle before renaming.
    verified = nil
    local base = DB_PATH .. ".corrupt-" .. os.date("%Y%m%d-%H%M%S")
    local backup, index = base, 0
    while lfs.attributes(backup) do
        index = index + 1
        backup = base .. "-" .. index
    end
    assert(lfs.mkdir(backup))
    local moved = {}
    for _i, suffix in ipairs({ "", "-journal", "-wal", "-shm" }) do
        local source = DB_PATH .. suffix
        if lfs.attributes(source) then
            local target = backup .. "/docprops_cache.sqlite" .. suffix
            local ok, err = os.rename(source, target)
            if not ok then
                for i = #moved, 1, -1 do
                    local restored, restore_err = os.rename(moved[i].target, moved[i].source)
                    if not restored then logger.warn("Cannot restore cache backup:", restore_err) end
                end
                lfs.rmdir(backup)
                error("Cannot preserve corrupt cache: " .. tostring(err))
            end
            moved[#moved + 1] = { source = source, target = target }
        end
    end
    logger.warn("Corrupt cache preserved; rebuilding:", backup)
    return backup
end

local function attempt(callback)
    in_operation = true
    local ok, result = pcall(function() return callback(open_db()) end)
    in_operation = nil
    return ok, result
end

function M.withDB(callback)
    -- Let the enclosing transaction recover and retry all its operations together.
    if in_operation then return callback(db) end
    local ok, result = attempt(callback)
    if ok then return result end
    local message = tostring(result)
    local corrupt = message:find("ljsqlite3[corrupt]", 1, true)
        or message:find("ljsqlite3[notadb]", 1, true)
    if corrupt then
        logger.warn("Cache corruption detected:", result)
        ok, result = pcall(function()
            local backup = preserve_corrupt_db()
            open_db()
            logger.info("Cache rebuilt:", DB_PATH, "backup:", backup)
        end)
        if ok then
            ok, result = attempt(callback)
            if ok then return result end
            if not tostring(result):find("ljsqlite3[", 1, true) then error(result) end
        end
    elseif not message:find("ljsqlite3[", 1, true) then
        error(result)
    end
    local closed, close_err = pcall(M.close)
    if not closed then logger.warn("Cannot close cache:", close_err) end
    logger.warn(corrupt and "Cache recovery failed:" or "Cache operation failed:", DB_PATH, result)
    error(result, 0)
end

return M
