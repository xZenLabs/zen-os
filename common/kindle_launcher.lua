local DBConnection = require("common/db_connection")
local Pending = require("modules/menu/app_launcher/zenpm_pending")
local lfs = require("libs/libkoreader-lfs")
local logger = require("common/zen_logger").new("kindle_launcher")

local M = {}

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local contents = file:read("*a")
    file:close()
    return contents
end

local function version(contents)
    return contents and contents:match("# Version: (%d+%.%d+%.%d+)")
end

local function newer(candidate, current)
    local c1, c2, c3 = candidate:match("^(%d+)%.(%d+)%.(%d+)$")
    local o1, o2, o3 = current:match("^(%d+)%.(%d+)%.(%d+)$")
    c1, c2, c3 = tonumber(c1), tonumber(c2), tonumber(c3)
    o1, o2, o3 = tonumber(o1), tonumber(o2), tonumber(o3)
    return c1 > o1 or (c1 == o1 and (c2 > o2 or (c2 == o2 and c3 > o3)))
end

local function write_atomic(path, contents)
    local temp = path .. ".zenos-tmp"
    local file, err = io.open(temp, "wb")
    if not file then return false, err end
    local written, write_err = file:write(contents)
    local closed, close_err = file:close()
    if not written or not closed then
        os.remove(temp)
        return false, write_err or close_err
    end
    local renamed, rename_err = os.rename(temp, path)
    if not renamed then os.remove(temp) end
    return renamed, rename_err
end

local function ensure_zenpm_database(home, state_dir, path)
    if lfs.attributes(home, "mode") ~= "directory" or DBConnection.isAvailable(path) then return end
    if not lfs.attributes(state_dir, "mode") and not lfs.mkdir(state_dir) then
        logger.warn("Could not create ZenPM state directory:", state_dir)
        return
    end
    local ok, err = pcall(function()
        local conn = require("lua-ljsqlite3/init").open(path)
        local created, failure = pcall(conn.exec, conn, [[
            CREATE TABLE IF NOT EXISTS installed_packages (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, version TEXT NOT NULL,
                repo TEXT NOT NULL, asset TEXT NOT NULL DEFAULT '',
                asset_arch TEXT NOT NULL DEFAULT '', install_path TEXT NOT NULL DEFAULT '',
                launcher_add_pending INTEGER NOT NULL DEFAULT 0,
                update_ignored INTEGER NOT NULL DEFAULT 0,
                update_ignored_version TEXT NOT NULL DEFAULT '', installed_at TEXT NOT NULL
            )
        ]])
        conn:close()
        assert(created, failure)
    end)
    if not ok then logger.warn("Could not initialize ZenPM database:", path, err) end
end

local function record_installed(path, installed_version, destination)
    local conn, err = DBConnection.open(path)
    if not conn then return false, err end
    local stmt
    local ok, failure = pcall(function()
        conn:exec("PRAGMA busy_timeout = 1000")
        stmt = assert(conn:prepare([[
            INSERT INTO installed_packages (id, name, version, repo, install_path, installed_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name, version = excluded.version,
                repo = excluded.repo, install_path = excluded.install_path,
                installed_at = excluded.installed_at
            WHERE installed_packages.version <> excluded.version
                OR installed_packages.install_path <> excluded.install_path
        ]]))
        stmt:bind("zen-reader", "ZenOS Launcher", installed_version, "ZenLabs",
            destination, os.date("!%Y-%m-%dT%H:%M:%SZ")):step()
    end)
    if stmt then pcall(stmt.close, stmt) end
    pcall(conn.close, conn)
    return ok, failure
end

function M.install(plugin_root, destination)
    local ConfigManager = require("config/manager")
    local config = ConfigManager.get() or ConfigManager.load()
    if config._meta.kindle_launcher_added == true then return true end

    local bundled = read_file(plugin_root .. "/kindle-launcher/ZenReader.sh")
    if not bundled then return true end
    local bundled_version = version(bundled)
    if not bundled_version then return false, "Bundled launcher is missing or has no version" end

    local current = read_file(destination)
    if not current and lfs.attributes(destination, "mode") then
        return false, "Could not read existing launcher"
    end
    local installed_version = version(current)
    if current and not installed_version then
        return false, "Existing launcher has no version"
    end
    if not current or newer(bundled_version, installed_version) then
        local copied, err = write_atomic(destination, bundled)
        if not copied then return false, err end
        installed_version = bundled_version
    end

    local zenpm_home = require("datastorage"):getSettingsDir() .. "/ZenPM"
    ensure_zenpm_database(zenpm_home, zenpm_home .. "/state",
        zenpm_home .. "/state/zenpm.sqlite3")
    ensure_zenpm_database("/mnt/us/ZenPM", "/mnt/us/.ZenPM",
        "/mnt/us/.ZenPM/zenpm.sqlite3")
    for _i, path in ipairs(Pending.paths()) do
        local ok, err = record_installed(path, installed_version, destination)
        if not ok then logger.warn("Could not mark ZenOS Launcher installed in ZenPM:", path, err) end
    end
    config._meta.kindle_launcher_added = true
    return ConfigManager.save(config)
end

return M
