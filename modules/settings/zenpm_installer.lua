-- Installs the ZenPM KOReader plugin from its signed GitHub release asset.

local _ = require("gettext")
local Archiver = require("ffi/archiver")
local json = require("json")
local logger = require("common/zen_logger").new("zenpm_installer")
local PLUGIN_ROOT = require("common/plugin_root")

local M = {}

local RELEASE_URL = "https://api.github.com/repos/xZenLabs/zen-pm/releases/latest"
local RELEASE_REPO_PATH = "/xzenlabs/zen-pm"
local DOWNLOAD_TIMEOUT = 60
local DOWNLOAD_HOSTS = {
    ["github.com"] = true,
    ["objects.githubusercontent.com"] = true,
    ["release-assets.githubusercontent.com"] = true,
    ["github-releases.githubusercontent.com"] = true,
}

local function call_device_bool(device, name)
    if not device or type(device[name]) ~= "function" then return false end
    local ok, value = pcall(device[name], device)
    if ok then return value == true end
    ok, value = pcall(device[name])
    return ok and value == true
end

--- Return the ZenPM asset filename templates for the supplied platform facts.
function M.select_assets(device, jit_os, jit_arch)
    local plugin_template
    local is_eink_reader = call_device_bool(device, "hasEinkScreen")
    if is_eink_reader and (jit_arch == "arm64" or jit_arch == "aarch64") then
        plugin_template = "ZenPM-koreader-linux-%s.zip"
    elseif is_eink_reader then
        plugin_template = "ZenPM-koreader-ereader-%s.zip"
    elseif jit_os == "OSX" or jit_os == "Darwin" then
        plugin_template = "ZenPM-koreader-macos-%s.zip"
    elseif jit_os == "Linux" then
        plugin_template = "ZenPM-koreader-linux-%s.zip"
    else
        plugin_template = "ZenPM-koreader-ereader-%s.zip"
    end
    return plugin_template
end

function M.asset_prefix(template)
    if type(template) ~= "string" then return nil end
    return template:match("^(.-)%%s")
end

function M.detect_assets()
    local device = require("device")
    return M.select_assets(
        device,
        type(jit) == "table" and jit.os or nil,
        type(jit) == "table" and jit.arch or nil
    )
end

local function parse_url(url)
    if type(url) ~= "string" then return nil end
    local scheme, host, path = url:match("^(https?)://([^/%?#]+)([^#]*)$")
    if not scheme or not host then return nil end
    return scheme:lower(), host:lower(), path == "" and "/" or path
end

local function resolve_redirect_url(base_url, location)
    if type(location) ~= "string" or location == "" then return nil end
    if location:match("^https?://") then return location end
    local scheme, host, path = parse_url(base_url)
    if not scheme or not host or not path then return nil end
    if location:sub(1, 1) == "/" then return scheme .. "://" .. host .. location end
    local parent = path:match("^(.*)/") or "/"
    return scheme .. "://" .. host .. parent .. location
end

local function is_release_url(url)
    local scheme, host, path = parse_url(url)
    if scheme ~= "https" or host ~= "api.github.com" then return false end
    path = path:match("^[^%?#]+") or path
    return path == "/repos/xZenLabs/zen-pm/releases/latest"
        or path:match("^/repositories/%d+/releases/latest$") ~= nil
end

function M.is_valid_asset_url(url, asset_name)
    local scheme, host, path = parse_url(url)
    if scheme ~= "https" or not DOWNLOAD_HOSTS[host] then return false end
    if host ~= "github.com" then return true end
    path = (path:match("^[^%?#]+") or path):lower()
    local expected = "/" .. asset_name:lower()
    return path:sub(-#expected) == expected
        and path:find(RELEASE_REPO_PATH .. "/releases/download/", 1, true) == 1
end

local function get_release()
    local ok_https, https = pcall(require, "ssl.https")
    local ok_ltn, ltn12 = pcall(require, "ltn12")
    if not ok_https or not ok_ltn then return nil, "HTTPS support is unavailable." end

    local function request(url, depth)
        if depth > 5 or not is_release_url(url) then return nil, "Invalid release URL." end
        local body = {}
        local _, code, headers = https.request{
            url = url,
            headers = { ["User-Agent"] = "zenos.koplugin" },
            redirect = false,
            sink = ltn12.sink.table(body),
        }
        if (code == 301 or code == 302 or code == 307 or code == 308) and headers and headers.location then
            local next_url = resolve_redirect_url(url, headers.location)
            return request(next_url, depth + 1)
        end
        if code ~= 200 then return nil, "GitHub returned HTTP " .. tostring(code) .. "." end
        return table.concat(body)
    end

    local body, err = request(RELEASE_URL, 0)
    if not body then return nil, err end
    local ok, release = pcall(json.decode, body)
    if not ok or type(release) ~= "table" then return nil, "Invalid release metadata." end
    return release
end

local function release_asset(release, name_prefix)
    if type(release.assets) ~= "table" then return nil end
    local normalized_prefix = type(name_prefix) == "string" and name_prefix:lower() or ""
    for _i, asset in ipairs(release.assets) do
        local name = type(asset) == "table" and asset.name
        local normalized_name = type(name) == "string" and name:lower() or ""
        local prefix_match = normalized_name:sub(1, #normalized_prefix) == normalized_prefix
        local zip_match = normalized_name:sub(-4) == ".zip"
        local valid_url = prefix_match and M.is_valid_asset_url(asset.browser_download_url, name)
        local valid_digest = type(asset) == "table" and type(asset.digest) == "string"
        if prefix_match then
            logger.info(
                "release asset name=", tostring(name),
                " zip_match=", tostring(zip_match),
                " valid_url=", tostring(valid_url),
                " has_digest=", tostring(valid_digest)
            )
        end
        if prefix_match and zip_match and valid_url and valid_digest then
            local sha = asset.digest:match("^sha256:([0-9a-fA-F]+)$")
            if sha and #sha == 64 then
                return { name = asset.name, url = asset.browser_download_url, sha256 = sha:lower() }
            end
        end
    end
end

local function compute_sha256(path)
    local ok_sha, sha2 = pcall(require, "ffi/sha2")
    if not ok_sha or not sha2 or not sha2.sha256 then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local append = sha2.sha256()
    while true do
        local chunk = f:read(64 * 1024)
        if not chunk then break end
        append(chunk)
    end
    f:close()
    local ok, digest = pcall(append)
    return ok and type(digest) == "string" and digest:lower() or nil
end

local function download(asset, destination)
    local ok_https, https = pcall(require, "ssl.https")
    local ok_ltn, ltn12 = pcall(require, "ltn12")
    if not ok_https or not ok_ltn then return false, "HTTPS support is unavailable." end

    local url = asset.url
    for _i = 1, 5 do
        if not M.is_valid_asset_url(url, asset.name) then return false, "Untrusted download URL." end
        local _, code, headers = https.request{
            url = url,
            method = "HEAD",
            headers = { ["User-Agent"] = "zenos.koplugin" },
            sink = ltn12.sink.null(),
        }
        if (code == 301 or code == 302 or code == 307 or code == 308) and headers and headers.location then
            url = resolve_redirect_url(url, headers.location)
        else
            break
        end
    end
    if not M.is_valid_asset_url(url, asset.name) then return false, "Untrusted download URL." end

    local f, err = io.open(destination, "wb")
    if not f then return false, err end
    local _, code = https.request{
        url = url,
        headers = { ["User-Agent"] = "zenos.koplugin" },
        sink = ltn12.sink.file(f),
    }
    pcall(f.close, f)
    if code ~= 200 then
        os.remove(destination)
        return false, "GitHub returned HTTP " .. tostring(code) .. "."
    end
    if compute_sha256(destination) ~= asset.sha256 then
        os.remove(destination)
        return false, "Checksum verification failed."
    end
    return true
end

local function shell_ok(command)
    local result, how, code = os.execute(command)
    return result == true or result == 0 or (result ~= nil and how == "exit" and code == 0)
end

local function path_exists(path)
    return shell_ok(string.format("test -e %q", path))
end

local function remove_tree(path)
    return shell_ok(string.format("rm -rf %q", path))
end

local function move_path(source, destination)
    return shell_ok(string.format("mv %q %q", source, destination))
end

local function valid_zip(zip_path)
    local reader = Archiver.Reader:new()
    if not reader:open(zip_path) then return false end
    local saw_root = false
    for entry in reader:iterate() do
        local path = entry.path or ""
        if path == "" or path:sub(1, 1) == "/" or path:sub(1, 1) == "\\" then
            reader:close()
            return false
        end
        for part in path:gmatch("[^/\\]+") do
            if part == ".." then reader:close(); return false end
        end
        if path == "zenpm.koplugin" or path:sub(1, #"zenpm.koplugin/") == "zenpm.koplugin/" then
            saw_root = true
        else
            reader:close()
            return false
        end
    end
    local err = reader.err
    reader:close()
    return saw_root and not err
end

local function extract_zip(zip_path, destination)
    local reader = Archiver.Reader:new()
    if not reader:open(zip_path) then return false end
    for entry in reader:iterate() do
        if (entry.mode ~= "file" and entry.mode ~= "directory")
            or not reader:extractToPath(entry.path, destination .. "/" .. entry.path) then
            reader:close()
            return false
        end
    end
    local err = reader.err
    reader:close()
    return not err
end

local function valid_plugin_tree(path)
    return path_exists(path .. "/_meta.lua") and path_exists(path .. "/main.lua")
end

local function install_asset(asset, plugins_dir, zip_path)
    local stage_dir = plugins_dir .. "/.zenpm_install_stage"
    local staged = stage_dir .. "/zenpm.koplugin"
    local active = plugins_dir .. "/zenpm.koplugin"
    local backup = plugins_dir .. "/zenpm.koplugin.backup"

    logger.info("install start asset=", asset.name, " plugins_dir=", plugins_dir)
    remove_tree(stage_dir)
    remove_tree(backup)
    if not valid_zip(zip_path) then
        logger.warn("package validation failed asset=", asset.name)
        os.remove(zip_path)
        return false, "Invalid ZenPM package."
    end
    if not shell_ok(string.format("mkdir -p %q", stage_dir)) or not extract_zip(zip_path, stage_dir)
        or not valid_plugin_tree(staged) then
        logger.warn("staged package validation failed")
        remove_tree(stage_dir)
        os.remove(zip_path)
        return false, "Could not unpack ZenPM."
    end
    if path_exists(active) and not move_path(active, backup) then
        logger.warn("existing plugin backup failed path=", active)
        remove_tree(stage_dir)
        os.remove(zip_path)
        return false, "Could not back up the existing ZenPM plugin."
    end
    if not move_path(staged, active) then
        logger.warn("staged plugin activation failed path=", active)
        if path_exists(backup) then move_path(backup, active) end
        remove_tree(stage_dir)
        os.remove(zip_path)
        return false, "Could not activate ZenPM."
    end
    remove_tree(stage_dir)
    remove_tree(backup)
    os.remove(zip_path)
    logger.info("install completed asset=", asset.name)
    return true
end

local function restart_koreader()
    require("common/restart").request()
end

local function show_install_prompt(plugin)
    local ConfirmBox = require("ui/widget/confirmbox")
    local UIManager = require("ui/uimanager")
    local plugin_template = M.detect_assets()
    logger.info("install requested asset_template=", plugin_template)
    UIManager:show(ConfirmBox:new{
        text = _("Are you sure you want to install the ZenPM plugin?"),
        ok_text = _("Install"),
        ok_callback = function()
            local ZenScreen = require("common/ui/zen_screen")
            local Trapper = require("ui/trapper")
            local screen = ZenScreen:new{
                title = _("ZenPM"),
                subtitle = _("Downloading ZenPM") .. "...",
                button = false,
                dismissable = false,
            }
            UIManager:show(screen)
            UIManager:forceRePaint()
            UIManager:nextTick(function()
                Trapper:wrap(function()
                    local co = coroutine.running()
                    local timed_out = false
                    screen._on_button_action = function()
                        coroutine.resume(co, false)
                    end
                    screen:update{ button = _("Cancel") }
                    UIManager:forceRePaint()
                    local timeout_cb = function()
                        timed_out = true
                        coroutine.resume(co, false)
                    end
                    UIManager:scheduleIn(DOWNLOAD_TIMEOUT, timeout_cb)

                    logger.info("fetching latest ZenPM release")
                    local asset_prefix = M.asset_prefix(plugin_template)
                    local root = PLUGIN_ROOT or (plugin and plugin.path) or ""
                    local plugins_dir = root:match("^(.*)/[^/]+$") or root
                    local zip_path = plugins_dir .. "/.zenpm_download.zip"
                    os.remove(zip_path)
                    local completed, ok, err, asset = Trapper:dismissableRunInSubprocess(function()
                        local release, err = get_release()
                        if not release then return false, err end
                        local selected = release_asset(release, asset_prefix)
                        if not selected then return false end
                        local downloaded, download_err = download(selected, zip_path)
                        return downloaded, download_err, selected
                    end, screen)
                    UIManager:unschedule(timeout_cb)
                    screen._on_button_action = nil
                    if not completed then
                        os.remove(zip_path)
                        if timed_out then
                            screen:update{ subtitle = _("Timeout"), button = _("OK"), dismissable = true }
                        else
                            screen:onClose()
                        end
                        return
                    end
                    if not asset then
                        if err then
                            screen:update{ subtitle = err, button = _("OK"), dismissable = true }
                        else
                            logger.warn("no matching release asset prefix=", asset_prefix)
                            screen:update{ subtitle = _("No ZenPM package is available for this device."), button = _("OK"), dismissable = true }
                        end
                        return
                    end
                    logger.info("selected release asset=", asset.name)
                    if not ok then
                        os.remove(zip_path)
                        logger.warn("download failed: ", tostring(err))
                        screen:update{ subtitle = err or _("Could not install ZenPM."), button = _("OK"), dismissable = true }
                        return
                    end
                    logger.info("download verified asset=", asset.name)
                    screen:update{ subtitle = _("Installing ZenPM") .. "...", button = false }
                    UIManager:forceRePaint()
                    ok, err = install_asset(asset, plugins_dir, zip_path)
                    if not ok then
                        logger.warn("install failed: ", tostring(err))
                        screen:update{ subtitle = err or _("Could not install ZenPM."), button = _("OK"), dismissable = true }
                        return
                    end
                    local subtitle = _("ZenPM has been installed. Restart KOReader to use it.")
                        .. "\n\n" .. _("A launcher button has been added for ZenPM.")
                    screen:update{
                        subtitle = subtitle,
                        button = _("Restart now"),
                        later_button = _("Later"),
                        dismissable = true,
                    }
                    screen._on_button_action = restart_koreader
                end)
            end)
        end,
    })
end

function M.prompt_install(plugin)
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr and not NetworkMgr:isWifiOn() then
        NetworkMgr:runWhenOnline(function() show_install_prompt(plugin) end)
    else
        show_install_prompt(plugin)
    end
end

function M.build_item(plugin)
    return {
        text = _("Install ZenPM"),
        help_text = _("Download and install the Zen Package Manager for this device."),
        keep_menu_open = true,
        callback = function() M.prompt_install(plugin) end,
    }
end

return M
