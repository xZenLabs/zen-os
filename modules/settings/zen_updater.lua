-- settings/zen_updater.lua
-- Checks the GitHub releases API for a newer ZenOS version, downloads the
-- matching plugin asset, unpacks it in-place, and prompts for a KOReader restart.

local _ = require("gettext")
local Archiver = require("ffi/archiver")
local json = require("json")
local logger = require("common/zen_logger").new("zen_updater")
local ConfigManager = require("config/manager")
local icons = require("common/inline_icon_map")
local IconItem = require("common/ui/icon_menu_item")
local MarkdownText = require("common/ui/markdown_text")

local GITHUB_OWNER = "xZenLabs"
local GITHUB_REPO = "zen-os"
local GITHUB_RELEASES_URL = string.format(
    "https://api.github.com/repos/%s/%s/releases",
    GITHUB_OWNER,
    GITHUB_REPO
)
local TRUSTED_RELEASE_REPOS = {
    [string.format("/%s/%s", GITHUB_OWNER, GITHUB_REPO):lower()] = true,
}

local TRUSTED_DL_HOSTS = {
    ["github.com"] = true,
    ["objects.githubusercontent.com"] = true,
    ["release-assets.githubusercontent.com"] = true,
    ["github-releases.githubusercontent.com"] = true,
}

-- Resolve the plugin root directory from this file's own path so the module
-- works regardless of where KOReader is installed.
local PLUGIN_ROOT = require("common/plugin_root")
local CANONICAL_PLUGIN_NAME = "zenos.koplugin"
local LEGACY_PLUGIN_NAME = "zen_ui.koplugin"
local CURRENT_PLUGIN_NAME = PLUGIN_ROOT:gsub("/+$", ""):match("([^/]+)$")
    or CANONICAL_PLUGIN_NAME
local RELEASE_ASSET_NAME = CURRENT_PLUGIN_NAME == LEGACY_PLUGIN_NAME
    and (LEGACY_PLUGIN_NAME .. ".zip")
    or (CANONICAL_PLUGIN_NAME .. ".zip")
local USER_AGENT = CANONICAL_PLUGIN_NAME

local M = {}

M._has_update       = false
M._latest_ver       = nil   -- latest version string without leading "v"
M._dl_url           = nil   -- download URL for the selected plugin asset
M._latest_sha256    = nil   -- expected SHA-256 digest for the selected plugin asset
M._latest_notes     = nil   -- markdown changelog body for the selected latest release
M._last_error       = nil   -- last update-check error message for UI
M._banner_loaded    = false -- true after init_banner() has run
M._wakeup_timer     = nil   -- pending UIManager scheduled function (for unschedule)
M._check_cancelled  = false -- set to true by cancel_wakeup_check to abort mid-poll
M._on_update_found  = nil   -- optional callback fired when background check detects a new update

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

--- Parse major/minor/patch integers from version strings like "v1.2.3",
--- "1.2.3", or "1.2.3-beta1". Returns nums + a boolean for pre-release and
--- the trailing integer from the pre-release label (e.g. 3 for "beta3") so
--- that "1.2.1-beta3" compares greater than "1.2.1-beta2".
local function parse_semver(v)
    v = (v or ""):match("^v?(.+)$") or ""
    local base = v:match("^([%d%.]+)") or ""
    local pre_str = v:match("^[%d%.]+[-+](.+)$") or ""
    local is_pre = pre_str ~= ""
    local pre_num = tonumber(pre_str:match("(%d+)$")) or 0
    local maj, min, pat = base:match("^(%d+)%.(%d+)%.?(%d*)$")
    return tonumber(maj) or 0, tonumber(min) or 0, tonumber(pat) or 0, is_pre, pre_num
end

local function semver_base(v)
    local maj, min, pat = parse_semver(v)
    return string.format("%d.%d.%d", maj, min, pat)
end

--- Returns true when version string a is strictly greater than b.
--- Stable "1.2.3" > pre-release "1.2.3-beta1" per semver precedence rules.
--- Among pre-releases with the same base, compares trailing number (beta3 > beta2).
local function semver_gt(a, b)
    local a1, a2, a3, a_pre, a_pn = parse_semver(a)
    local b1, b2, b3, b_pre, b_pn = parse_semver(b)
    if a1 ~= b1 then return a1 > b1 end
    if a2 ~= b2 then return a2 > b2 end
    if a3 ~= b3 then return a3 > b3 end
    -- same numbers: stable beats pre-release
    if a_pre ~= b_pre then return not a_pre end
    -- both pre-release: compare trailing number (e.g. beta3 > beta2)
    if a_pre then return a_pn > b_pn end
    return false
end

local function semver_eq(a, b)
    return (not semver_gt(a, b)) and (not semver_gt(b, a))
end

local function shell_result_ok(rc, how, code)
    if rc == true then
        return true
    elseif type(rc) == "number" then
        return rc == 0
    end
    return rc ~= nil and how == "exit" and code == 0
end

--- Read the current plugin version from _meta.lua.
local function get_current_version()
    local ok, meta = pcall(dofile, PLUGIN_ROOT .. "/_meta.lua")
    if ok and type(meta) == "table" and meta.version then
        return meta.version
    end
    return "0.0.0"
end

local function parse_url(url)
    if type(url) ~= "string" then return nil end
    local scheme, host, path = url:match("^(https?)://([^/%?#]+)([^#]*)$")
    if not scheme or not host then return nil end
    if path == "" then path = "/" end
    return scheme:lower(), host:lower(), path
end

local function is_valid_sha256_digest(sha)
    return type(sha) == "string" and sha:match("^[0-9a-fA-F]+$") ~= nil and #sha == 64
end

local function parse_sha256_digest(digest)
    if type(digest) ~= "string" then return nil end
    local sha = digest:match("^sha256:([0-9a-fA-F]+)$")
        or digest:match("^([0-9a-fA-F]+)$")
    if not is_valid_sha256_digest(sha) then return nil end
    return sha:lower()
end

--- Validate release asset origin URL before use.
local function is_valid_asset_url(url)
    local scheme, host, path = parse_url(url)
    if not scheme or scheme ~= "https" then return false end
    if not TRUSTED_DL_HOSTS[host] then return false end
    if not path then return false end
    if host == "github.com" then
        -- parse_url includes query string in path; strip query/fragment for filename checks.
        local asset_path = path:match("^([^%?#]+)") or path
        local normalized_path = asset_path:lower()
        local asset_suffix = ("/" .. RELEASE_ASSET_NAME):lower()
        local repo_path = normalized_path:match("^(/[^/]+/[^/]+)/releases/download/")
        if not repo_path or not TRUSTED_RELEASE_REPOS[repo_path] then return false end
        if normalized_path:sub(-#asset_suffix) ~= asset_suffix then return false end
    end
    return true
end

local function parse_release_api_url(url)
    local scheme, host, path = parse_url(url)
    if scheme ~= "https" or host ~= "api.github.com" or not path then return nil, false end
    local api_path = path:match("^([^%?#]+)") or path
    local owner, repo, release_id = api_path:match("^/repos/([^/]+)/([^/]+)/releases/?(%d*)$")
    if owner and repo then
        return string.format("/%s/%s", owner, repo):lower(), release_id == ""
    end
    if api_path:match("^/repositories/%d+/releases$") then
        return nil, true
    end
    return nil, false
end

local function resolve_redirect_url(base_url, location)
    if type(location) ~= "string" or location == "" then return nil end
    if location:match("^https?://") then return location end
    local scheme, host, base_path = parse_url(base_url)
    if not scheme or not host or not base_path then return nil end
    if location:sub(1, 1) == "/" then
        return string.format("%s://%s%s", scheme, host, location)
    end
    local base_dir = base_path:match("^(.*)/") or "/"
    if base_dir == "" then base_dir = "/" end
    return string.format("%s://%s%s%s", scheme, host, base_dir, location)
end

--- Get plugin asset metadata from a decoded release object.
local function get_asset_info(release)
    if not release or type(release.assets) ~= "table" then
        return nil, "missing_assets_table"
    end
    local canonical_repo = parse_release_api_url(release.url)
    if canonical_repo then
        TRUSTED_RELEASE_REPOS[canonical_repo] = true
    end
    for _i, asset in ipairs(release.assets) do
        if asset.name == RELEASE_ASSET_NAME then
            if is_valid_asset_url(asset.browser_download_url) then
                return {
                    url = asset.browser_download_url,
                    sha256 = parse_sha256_digest(asset.digest),
                }, nil
            end
            logger.warn(
                "rejected asset URL tag=",
                tostring(release.tag_name),
                "url=",
                tostring(asset.browser_download_url)
            )
            return nil, "invalid_asset_url"
        end
    end
    return nil, "missing_named_asset"
end

local function normalize_release_notes(notes)
    if type(notes) ~= "string" then
        return _("No changelog provided.")
    end
    notes = notes:gsub("\r\n", "\n"):gsub("\r", "\n")
    notes = notes:gsub("^%s+", ""):gsub("%s+$", "")
    if notes == "" then
        return _("No changelog provided.")
    end
    return notes
end

local function normalize_whats_changed_line(line)
    local heading = line:match("^%s*##%s*(.-)%s*$")
    if not heading then
        return nil
    end
    local lower = heading:lower()
    if lower == "what's changed" or lower == "what’s changed" then
        return "## " .. _("What's changed")
    end
    return nil
end

local function render_release_text(entry)
    local label = entry.version ~= "" and ("v" .. entry.version) or (entry.tag or _("unknown"))
    local lines = {}
    local notes = normalize_release_notes(entry.notes)
    for raw in (notes .. "\n"):gmatch("(.-)\n") do
        local line = raw:gsub("\r", "")
        local normalized = normalize_whats_changed_line(line)
        lines[#lines + 1] = normalized or line
    end
    return MarkdownText.bold(label) .. "\n"
        .. MarkdownText.render_fragment(table.concat(lines, "\n"))
end

local function sort_entries_most_recent(entries)
    table.sort(entries, function(a, b)
        local a_time = type(a.release_time) == "string" and a.release_time or ""
        local b_time = type(b.release_time) == "string" and b.release_time or ""
        if a_time ~= b_time then
            return a_time > b_time
        end
        local a_idx = tonumber(a.source_index) or 0
        local b_idx = tonumber(b.source_index) or 0
        return a_idx < b_idx
    end)
end

--- Decode a releases list JSON body into installable release entries.
local function parse_release_entries(body)
    local ok, releases = pcall(json.decode, body)
    if not ok or type(releases) ~= "table" then
        logger.warn("JSON decode failed")
        return nil
    end
    local decoded_count = #releases
    if decoded_count == 0 then
        if type(releases.message) == "string" then
            logger.warn(
                "releases API returned non-list payload message=",
                releases.message,
                "status=",
                tostring(releases.status)
            )
        else
            logger.warn("decoded releases list is empty")
        end
    end
    local entries = {}
    local drop_missing_assets_table = 0
    local drop_missing_named_asset = 0
    local drop_invalid_asset_url = 0
    for _i, release in ipairs(releases) do
        local asset, reason = get_asset_info(release)
        if asset then
            local tag = release.tag_name
            table.insert(entries, {
                tag = tag,
                version = tag and (tag:match("^v?(.+)$") or tag) or "",
                url = asset.url,
                sha256 = asset.sha256,
                prerelease = release.prerelease == true,
                notes = normalize_release_notes(release.body),
                release_time = release.published_at or release.created_at or "",
                source_index = _i,
            })
        elseif reason == "missing_assets_table" then
            drop_missing_assets_table = drop_missing_assets_table + 1
        elseif reason == "missing_named_asset" then
            drop_missing_named_asset = drop_missing_named_asset + 1
        elseif reason == "invalid_asset_url" then
            drop_invalid_asset_url = drop_invalid_asset_url + 1
        end
    end
    sort_entries_most_recent(entries)
    logger.dbg(
        "parse_release_entries total=",
        decoded_count,
        "accepted=",
        #entries,
        "drop_missing_assets_table=",
        drop_missing_assets_table,
        "drop_missing_named_asset=",
        drop_missing_named_asset,
        "drop_invalid_asset_url=",
        drop_invalid_asset_url
    )
    return entries
end

--- Filter installable entries by channel. Stable: releases only.
--- Beta: releases + beta prereleases, preferring stable for the same M.m.p base.
local function is_beta_release(entry)
    return not entry.prerelease or entry.version:match("%-beta%d*$") ~= nil
end

local function filter_entries_for_channel(entries, channel)
    local filtered = {}
    if channel == "stable" then
        local skipped_prerelease = 0
        for _i, entry in ipairs(entries) do
            if not entry.prerelease then
                table.insert(filtered, entry)
            else
                skipped_prerelease = skipped_prerelease + 1
            end
        end
        logger.dbg(
            "filter channel=stable in=",
            #entries,
            "out=",
            #filtered,
            "skipped_prerelease=",
            skipped_prerelease
        )
        return filtered
    end

    local base_index = {}
    local replaced_with_stable = 0
    for _i, entry in ipairs(entries) do
        if is_beta_release(entry) then
            local base = semver_base(entry.tag)
            local idx = base_index[base]
            if not idx then
                table.insert(filtered, entry)
                base_index[base] = #filtered
            else
                local existing = filtered[idx]
                if existing.prerelease and not entry.prerelease then
                    filtered[idx] = entry
                    replaced_with_stable = replaced_with_stable + 1
                end
            end
        end
    end
    logger.dbg(
        "filter channel=beta in=",
        #entries,
        "out=",
        #filtered,
        "replaced_with_stable=",
        replaced_with_stable
    )
    return filtered
end

-- Changelog should show all channel entries in chronological order without
-- collapsing prerelease/stable siblings that share the same semver base.
local function filter_changelog_entries_for_channel(entries, channel)
    if channel == "stable" then
        local stable = {}
        for _i, entry in ipairs(entries) do
            if not entry.prerelease then
                table.insert(stable, entry)
            end
        end
        logger.dbg(
            "changelog stable filter in=",
            #entries,
            "out=",
            #stable
        )
        return stable
    end

    local beta = {}
    for _i, entry in ipairs(entries) do
        if is_beta_release(entry) then
            table.insert(beta, entry)
        end
    end
    logger.dbg("changelog beta filter in=", #entries, "out=", #beta)
    return beta
end

--- Best-effort HTTPS GET; returns the response body string or nil.
--- Uses ssl.https (LuaSec, bundled with KOReader). Blocking -- use only
--- for user-initiated checks.
local function https_get(url, depth)
    depth = depth or 0
    local is_release_list = select(2, parse_release_api_url(url))
    if depth > 5 or not is_release_list then
        logger.warn("rejected releases API URL", url)
        return nil
    end
    local ok_ssl, https = pcall(require, "ssl.https")
    local ok_ltn, ltn12 = pcall(require, "ltn12")
    if not ok_ssl or not ok_ltn then
        logger.warn("ssl.https or ltn12 not available")
        return nil
    end

    logger.dbg("GET", url)
    local body = {}
    local ok_req, req_err = pcall(function()
        local _, code, headers, status = https.request{
            url     = url,
            headers = { ["User-Agent"] = USER_AGENT },
            redirect = false,
            sink    = ltn12.sink.table(body),
        }
        if (code == 301 or code == 302 or code == 307 or code == 308)
            and headers and headers.location then
            local next_url = resolve_redirect_url(url, headers.location)
            local is_next_release_list = select(2, parse_release_api_url(next_url))
            if not is_next_release_list then
                logger.warn("rejected releases API redirect", tostring(headers.location))
                body = nil
                return
            end
            body = https_get(next_url, depth + 1)
            return
        end
        -- code can be a string error message on Kobo (e.g. "connection refused")
        if code ~= 200 then
            local body_text = table.concat(body)
            local snippet = body_text:sub(1, 200)
            logger.warn(
                "https_get non-200 code=",
                tostring(code),
                "status=",
                tostring(status),
                "location=",
                tostring(headers and headers.location),
                "body=",
                snippet
            )
            body = nil
        end
    end)
    if not ok_req then
        logger.warn("https_get error:", req_err)
        return nil
    end
    if not body then return nil end
    if type(body) == "string" then return body end
    return table.concat(body)
end

--- Download a file via HTTPS to dest_path, following up to 5 redirects.
--- Returns true on success, or false + error message on failure.
local function read_sha_from_command(cmd)
    local pipe = io.popen(cmd)
    if not pipe then return nil end
    local out = pipe:read("*a") or ""
    pcall(pipe.close, pipe)
    for token in out:gmatch("([0-9a-fA-F]+)") do
        if #token == 64 then
            return token:lower()
        end
    end
    return nil
end

-- Pure-Lua SHA-256 via KOReader's bundled ffi/sha2 (no external tools needed).
local function compute_sha256_native(path)
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
    local ok_digest, digest = pcall(append)
    if not ok_digest or type(digest) ~= "string" then return nil end
    return digest:lower()
end

local function compute_sha256(path)
    local native = compute_sha256_native(path)
    if native then return native end
    local q = string.format("%q", path)
    return read_sha_from_command("shasum -a 256 " .. q .. " 2>/dev/null")
        or read_sha_from_command("sha256sum " .. q .. " 2>/dev/null")
        or read_sha_from_command("openssl dgst -sha256 " .. q .. " 2>/dev/null")
end

local function https_download(url, dest_path, expected_sha256, depth)
    depth = depth or 0
    if depth > 5 then return false, "too many redirects" end
    if not is_valid_asset_url(url) then
        return false, "untrusted origin url"
    end
    if not is_valid_sha256_digest(expected_sha256) then
        return false, "missing sha256 digest"
    end

    local ok_ssl, https = pcall(require, "ssl.https")
    local ok_ltn, ltn12 = pcall(require, "ltn12")
    if not ok_ssl or not ok_ltn then
        return false, "ssl.https not available"
    end

    -- Resolve any redirect chain via HEAD requests (avoids writing partial data).
    local resolved_url = url
    for _attempt = 1, 5 do
        if not is_valid_asset_url(resolved_url) then
            return false, "untrusted redirect origin"
        end
        local _, r_code, r_headers = https.request{
            url     = resolved_url,
            method  = "HEAD",
            headers = { ["User-Agent"] = USER_AGENT },
            sink    = ltn12.sink.null(),
        }
        if (r_code == 301 or r_code == 302 or r_code == 307 or r_code == 308)
            and r_headers and r_headers.location then
            local next_url = resolve_redirect_url(resolved_url, r_headers.location)
            if not next_url or not is_valid_asset_url(next_url) then
                return false, "untrusted redirect origin"
            end
            resolved_url = next_url
        else
            break
        end
    end

    if not is_valid_asset_url(resolved_url) then
        return false, "untrusted download origin"
    end

    -- Perform the actual download.
    local f, ferr = io.open(dest_path, "wb")
    if not f then return false, ferr end

    local _, dl_code = https.request{
        url     = resolved_url,
        headers = { ["User-Agent"] = USER_AGENT },
        sink    = ltn12.sink.file(f),
    }
    -- ltn12.sink.file closes f on EOF; pcall guards against double-close.
    pcall(f.close, f)

    if dl_code ~= 200 then
        os.remove(dest_path)
        return false, "HTTP " .. tostring(dl_code)
    end

    local actual_sha256 = compute_sha256(dest_path)
    if not actual_sha256 then
        os.remove(dest_path)
        return false, "sha256 tool unavailable"
    end
    if actual_sha256 ~= expected_sha256:lower() then
        os.remove(dest_path)
        return false, "sha256 mismatch"
    end

    return true
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

local CHECK_INTERVAL        = 24 * 3600  -- seconds between automatic checks
local NET_SETTLE_DELAY      = 15         -- seconds after resume before first network attempt
local NET_RETRY_DELAY       = 2 * 60    -- seconds to wait before retrying when no network
local NET_ERROR_BASE_DELAY  = 30         -- first retry delay (s) after API failure; doubles each retry
local NET_ERROR_MAX_RETRIES = 2          -- max error retries: 30s, 60s
local INSTALL_TIMEOUT       = 120        -- max seconds for download + apply
local UP_KEY_JUST_UPDATED = "just_updated_version"
local UP_KEY_TIME         = "last_update_check"
local UP_KEY_AVAIL        = "update_available"
local UP_KEY_CHANNEL      = "update_channel"
local UP_KEY_AUTO         = "update_auto_check"

local function load_updater_config()
    local ok, cfg = pcall(ConfigManager.load)
    if not ok or type(cfg) ~= "table" then
        return nil, nil
    end
    if type(cfg.updater) ~= "table" then
        cfg.updater = {}
    end
    return cfg, cfg.updater
end

local function save_updater_config(cfg)
    if type(cfg) ~= "table" then return end
    pcall(ConfigManager.save, cfg)
end

local function clear_release_details()
    M._latest_ver = nil
    M._dl_url     = nil
    M._latest_sha256 = nil
    M._latest_notes = nil
end

local function reset_release_state()
    M._has_update = false
    clear_release_details()
end

local function clear_persisted_release_state(updater)
    if type(updater) ~= "table" then return end
    updater.latest_version = nil
    updater.update_dl_url = nil
    updater.update_sha256 = nil
end

--- Returns true when the 24h check interval has elapsed since the last check.
local function is_check_due()
    local updater = select(2, load_updater_config())
    local now = os.time()
    local last = updater and updater[UP_KEY_TIME] or 0
    local last_num = type(last) == "number" and last or 0
    return now - last_num >= CHECK_INTERVAL
end

local function get_channel()
    local updater = select(2, load_updater_config())
    local ch = updater and updater[UP_KEY_CHANNEL]
    if ch == "beta" then return "beta" end
    return "stable"
end

local function is_auto_check_enabled()
    local updater = select(2, load_updater_config())
    if not updater then return true end
    return updater[UP_KEY_AUTO] ~= false
end

local function persist_state(now)
    local cfg, updater = load_updater_config()
    if not updater then return end
    updater[UP_KEY_TIME]  = now
    updater[UP_KEY_AVAIL] = M._has_update == true
    clear_persisted_release_state(updater)
    save_updater_config(cfg)
end

--- Clear all persisted update state after an install or version-change acknowledgement.
local function clear_update_state(cfg)
    reset_release_state()
    M._last_error = nil
    local updater
    if type(cfg) == "table" then
        if type(cfg.updater) ~= "table" then
            cfg.updater = {}
        end
        updater = cfg.updater
    else
        cfg, updater = load_updater_config()
    end
    if not updater then return end
    updater[UP_KEY_AVAIL] = false
    clear_persisted_release_state(updater)
    save_updater_config(cfg)
end

--- Acknowledge a version change detected outside ZenOS's updater.
function M.clear_update_state(cfg)
    clear_update_state(cfg)
end

--- Perform an actual network check; returns true on success.
local function do_network_check()
    local channel = get_channel()
    local current = get_current_version()
    clear_release_details()
    M._last_error = nil
    logger.dbg("do_network_check channel=", channel, "current=", current)

    local body = https_get(GITHUB_RELEASES_URL .. "?per_page=100")
    if not body then
        logger.warn("no response from releases API")
        local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
        if ok_nm and NetworkMgr and not NetworkMgr:isWifiOn() then
            M._last_error = _("Network unavailable.")
        else
            M._last_error = _("Could not reach update server.")
        end
        return false
    end

    local entries = parse_release_entries(body)
    if not entries then
        M._last_error = _("Could not get release from update server.")
        return false
    end

    local channel_entries = filter_entries_for_channel(entries, channel)
    local selected
    for _i, entry in ipairs(channel_entries) do
        if is_valid_sha256_digest(entry.sha256) then
            selected = entry
            break
        end
    end

    if not selected then
        logger.warn("no eligible tag with digest for channel", channel)
        reset_release_state()
        M._last_error = _("Release metadata is invalid or incomplete.")
        return false
    end

    M._latest_ver = selected.version
    M._dl_url     = selected.url
    M._latest_sha256 = selected.sha256
    M._latest_notes = selected.notes
    M._has_update = semver_gt(selected.tag, current)
    M._last_error = nil
    logger.dbg("latest=", M._latest_ver, "has_update=", tostring(M._has_update))
    return true
end

local function ensure_selected_release_details(force_live)
    if not force_live and M._latest_ver and M._latest_notes and is_valid_asset_url(M._dl_url)
        and is_valid_sha256_digest(M._latest_sha256) then
        return true
    end
    return do_network_check()
end

local function load_bundled_changelog_entries(channel)
    local ok, changelog = pcall(require, "config/changelog")
    if not ok or type(changelog) ~= "table" then
        logger.warn("could not load bundled changelog")
        return {}
    end

    local entries = {}
    for version, items in pairs(changelog) do
        if type(version) == "string" and type(items) == "table" then
            local lines = {}
            for _i, item in ipairs(items) do
                if type(item) == "string" and item ~= "" then
                    lines[#lines + 1] = "- " .. item
                end
            end
            if #lines > 0 then
                entries[#entries + 1] = {
                    tag = "v" .. version,
                    version = version,
                    prerelease = select(4, parse_semver(version)),
                    notes = table.concat(lines, "\n"),
                }
            end
        end
    end
    table.sort(entries, function(a, b)
        return semver_gt(a.version, b.version)
    end)
    local filtered = filter_changelog_entries_for_channel(entries, channel)
    logger.dbg(
        "bundled changelog entries channel=",
        tostring(channel),
        "total=",
        #entries,
        "shown=",
        #filtered
    )
    return filtered
end

local function build_changelog_text(entries, count)
    local shown = math.min(count, #entries)
    local blocks = {}
    for _i = 1, shown do
        local entry = entries[_i]
        blocks[#blocks + 1] = render_release_text(entry)
    end
    local text = table.concat(blocks, "\n\n")
    if text == "" then
        text = _("No changelog provided.")
    else
        text = MarkdownText.PTF_HEADER .. text
    end
    return text, shown < #entries
end

local function build_single_release_scroll_text(notes, version)
    local text = render_release_text({
        version = type(version) == "string" and version or "",
        notes = normalize_release_notes(notes),
    })
    if text == "" then
        text = _("No changelog provided.")
    else
        text = MarkdownText.PTF_HEADER .. text
    end
    return text
end

local function call_device_bool(name)
    local ok_dev, Device = pcall(require, "device")
    if not ok_dev or not Device or type(Device[name]) ~= "function" then
        return false
    end
    local ok, value = pcall(Device[name], Device)
    if ok then return value == true end
    ok, value = pcall(Device[name])
    return ok and value == true
end

local function is_sdl_wayland_desktop()
    if os.getenv("WAYLAND_DISPLAY") == nil and os.getenv("SDL_VIDEODRIVER") ~= "wayland" then
        return false
    end
    if type(jit) == "table" and jit.os ~= "Linux" and jit.os ~= "BSD" and jit.os ~= "POSIX" then
        return false
    end
    return call_device_bool("isSDL") or call_device_bool("isDesktop")
end

local function dismissable_or_in_process(Trapper, task, trap_widget, task_returns_simple_string, quiet)
    if is_sdl_wayland_desktop() then
        if not quiet then
            logger.warn("running update task in-process on SDL/Wayland to avoid EGL fork crash")
        end
        return true, task()
    end
    return Trapper:dismissableRunInSubprocess(task, trap_widget, task_returns_simple_string)
end

local function run_without_updater_logs(fn)
    local dbg, info, warn, err = logger.dbg, logger.info, logger.warn, logger.err
    local function discard() end
    logger.dbg, logger.info, logger.warn, logger.err = discard, discard, discard, discard
    local ok, a, b, c, d, e, f, g = pcall(fn)
    logger.dbg, logger.info, logger.warn, logger.err = dbg, info, warn, err
    if not ok then error(a, 0) end
    return a, b, c, d, e, f, g
end

--- Run do_network_check() in a non-blocking subprocess via Trapper.
--- On SDL/Wayland desktop this falls back to an in-process call because
--- forking with live EGL state can abort inside egl-wayland.
--- setup_fn(co) -- optional; called with the coroutine so the caller can wire
---                  a cancel button via coroutine.resume(co, false).
--- on_done(net_ok) -- called when the subprocess completes.
--- on_cancelled()  -- called when dismissed before completion; may be nil.
local function network_check_async(trap_widget, setup_fn, on_done, on_cancelled, quiet)
    local Trapper = require("ui/trapper")
    Trapper:wrap(function()
        local co = coroutine.running()
        if setup_fn then setup_fn(co) end
        local completed, net_ok, has_upd, latest_ver, dl_url, latest_sha256, latest_notes, last_error =
            dismissable_or_in_process(Trapper, function()
                local function check()
                    local ok = do_network_check()
                    return ok, M._has_update, M._latest_ver, M._dl_url, M._latest_sha256, M._latest_notes, M._last_error
                end
                if quiet then return run_without_updater_logs(check) end
                return check()
            end, trap_widget, nil, quiet)
        if completed and net_ok then
            M._has_update = has_upd
            M._latest_ver = latest_ver
            M._dl_url     = dl_url
            M._latest_sha256 = latest_sha256
            M._latest_notes = latest_notes
        end
        -- On the subprocess path, do_network_check() mutates child state, so
        -- copy the returned status back into the parent.
        if completed then
            M._last_error = last_error
        end
        if not completed then
            if on_cancelled then on_cancelled() end
        else
            on_done(net_ok)
        end
    end)
end

--- Load persisted banner state once per session; never makes network calls.
--- Called from zen_settings.lua; release metadata is intentionally live-only.
function M.init_banner()
    if M._banner_loaded then return end
    M._banner_loaded = true
    local cfg, updater = load_updater_config()
    if updater then
        M._has_update = updater[UP_KEY_AVAIL] == true
        clear_release_details()
        clear_persisted_release_state(updater)
        save_updater_config(cfg)
    end
end

--- Cancel any pending background wakeup check.
function M.cancel_wakeup_check()
    M._check_cancelled = true
    local ok_um, UIManager = pcall(require, "ui/uimanager")
    if ok_um and UIManager and M._wakeup_timer then
        UIManager:unschedule(M._wakeup_timer)
    end
    M._wakeup_timer = nil
end

--- Schedule a background update check on device resume.
--- Waits NET_SETTLE_DELAY seconds for the network to reconnect, then runs a
--- blocking HTTPS check inside a UIManager timer (not on the resume handler itself).
--- If no network, retries once after NET_RETRY_DELAY, then gives up.
--- If network is up but the API call fails, retries with exponential backoff
--- (NET_ERROR_BASE_DELAY doubling each attempt, up to NET_ERROR_MAX_RETRIES).
--- Cancelled on suspend so nothing fires while asleep.
function M.schedule_wakeup_check()
    M.cancel_wakeup_check()  -- reset on every resume
    if not is_auto_check_enabled() then
        logger.info("automatic update check status=disabled")
        return
    end
    M._check_cancelled = false
    if not is_check_due() then
        logger.info("automatic update check status=skipped reason=interval")
        return
    end

    local ok_um, UIManager = pcall(require, "ui/uimanager")
    if not ok_um or not UIManager then
        logger.warn("automatic update check status=failed reason=uimanager_unavailable")
        return
    end

    local function has_network()
        local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
        return ok_nm and NetworkMgr and NetworkMgr:isWifiOn()
    end

    -- Run the network check; on failure retry with exponential backoff.
    -- Uses a subprocess so the UI thread is never blocked.
    local function run_check_with_retry(retry_count, error_delay)
        if M._check_cancelled then return end
        network_check_async(
            nil,  -- invisible trap: taps pass through normally
            nil,
            function(net_ok)
                if M._check_cancelled then return end
                if net_ok then
                    persist_state(os.time())
                    M._banner_loaded = true
                    logger.info("automatic update check status=ok has_update=", tostring(M._has_update), "latest=", tostring(M._latest_ver))
                    if M._has_update and type(M._on_update_found) == "function" then
                        M._on_update_found()
                    end
                elseif retry_count < NET_ERROR_MAX_RETRIES then
                    local next_count = retry_count + 1
                    local next_delay = error_delay * 2
                    local function error_retry()
                        M._wakeup_timer = nil
                        run_check_with_retry(next_count, next_delay)
                    end
                    M._wakeup_timer = error_retry
                    UIManager:scheduleIn(error_delay, error_retry)
                else
                    logger.warn("automatic update check status=failed attempts=", NET_ERROR_MAX_RETRIES + 1, "error=", tostring(M._last_error))
                end
            end,
            nil,
            true
        )
    end

    -- Deferred so the HTTPS call never blocks the onResume/init handler directly.
    local function attempt()
        M._wakeup_timer = nil
        if M._check_cancelled then return end
        local net_up = has_network()
        if not net_up then
            -- No network after settle delay -- retry once after NET_RETRY_DELAY.
            local function retry_check()
                M._wakeup_timer = nil
                if M._check_cancelled then return end
                local retry_net = has_network()
                if not retry_net then
                    logger.info("automatic update check status=skipped reason=network_unavailable")
                    return
                end
                run_check_with_retry(0, NET_ERROR_BASE_DELAY)
            end
            M._wakeup_timer = retry_check
            UIManager:scheduleIn(NET_RETRY_DELAY, retry_check)
            return
        end
        run_check_with_retry(0, NET_ERROR_BASE_DELAY)
    end

    M._wakeup_timer = attempt
    UIManager:scheduleIn(NET_SETTLE_DELAY, attempt)
end

--- Check for updates with a live network request.
--- Returns "ok" (live check succeeded) or "error" (network failure).
function M.check_for_update()
    local now = os.time()
    logger.dbg("check_for_update live now=", now)
    if not do_network_check() then
        logger.warn("live check failed")
        clear_release_details()
        return "error"
    end

    persist_state(now)
    return "ok"
end

--- Returns true when a newer release has been detected.
function M.has_update()
    return M._has_update == true
end

--- Returns the latest release version string (without leading "v"), or nil.
function M.latest_version()
    return M._latest_ver
end

local function run_shell_ok(cmd, label)
    logger.dbg("shell start", label or "", cmd)
    local rc, how, code = os.execute(cmd)
    local ok = shell_result_ok(rc, how, code)
    logger.dbg("shell done", label or "", "ok=", tostring(ok), "rc=", tostring(rc), "how=", tostring(how), "code=", tostring(code))
    return ok
end

local function path_exists(path)
    return run_shell_ok(string.format("test -e %q", path))
end

local function path_is_dir(path)
    return run_shell_ok(string.format("test -d %q", path))
end

local function path_is_readable_file(path)
    return run_shell_ok(string.format("test -r %q", path))
end

local function get_file_size_bytes(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = tonumber(f:seek("end"))
    f:close()
    return size
end

local function collect_zip_entries(zip_path)
    local reader = Archiver.Reader:new()
    if not reader:open(zip_path) then
        logger.warn("archive open failed:", tostring(reader.err))
        return nil
    end

    local entries = {}
    for entry in reader:iterate() do
        entries[#entries + 1] = entry.path
    end
    local read_error = reader.err
    reader:close()

    if read_error then
        logger.warn("archive listing failed:", tostring(read_error))
        return nil
    end
    if #entries == 0 then
        logger.warn("archive contains no entries")
        return nil
    end

    logger.dbg("zip list parsed method=ffi_archiver entry_count=", #entries)
    return entries
end

local function check_zip_integrity(zip_path)
    logger.dbg(
        "check_zip_integrity zip_path=",
        zip_path,
        "exists=",
        tostring(path_exists(zip_path)),
        "size_bytes=",
        tostring(get_file_size_bytes(zip_path))
    )

    local entries = collect_zip_entries(zip_path)
    if entries then
        logger.dbg("zip integrity ffi/archiver passed")
        return true
    end
    logger.warn("zip integrity ffi/archiver failed")
    return false
end

local function is_unsafe_zip_entry(entry)
    if entry == "" or entry:sub(1, 1) == "/" or entry:sub(1, 1) == "\\" then
        return true
    end
    for component in entry:gmatch("[^/\\]+") do
        if component == ".." then
            return true
        end
    end
    return false
end

local function validate_zip_layout(zip_path, plugin_name)
    logger.dbg("validate_zip_layout zip=", zip_path, "plugin_name=", plugin_name)
    local entries = collect_zip_entries(zip_path)
    if not entries then
        logger.warn("validate_zip_layout failed to list zip entries")
        return false, "zip list failed"
    end

    local prefix = plugin_name .. "/"
    local saw_prefix = false
    local entry_count = #entries
    local sample_entries = {}
    for _i, entry in ipairs(entries) do
        if #sample_entries < 8 then
            sample_entries[#sample_entries + 1] = entry
        end
        if is_unsafe_zip_entry(entry) then
            logger.warn("validate_zip_layout unsafe entry:", entry)
            return false, "unsafe zip entry path"
        end
        if entry == plugin_name or entry:sub(1, #prefix) == prefix then
            saw_prefix = true
        else
            logger.warn("validate_zip_layout unexpected root entry:", entry)
            return false, "unexpected zip root"
        end
    end

    if not saw_prefix then
        logger.warn(
            "validate_zip_layout missing plugin root expected=",
            plugin_name,
            "entry_count=",
            entry_count,
            "sample=",
            table.concat(sample_entries, " | ")
        )
        return false, "zip missing plugin root"
    end
    logger.dbg(
        "validate_zip_layout ok expected=",
        plugin_name,
        "entry_count=",
        entry_count,
        "sample=",
        table.concat(sample_entries, " | ")
    )
    return true
end

local function extract_zip_with_archiver(zip_path, destination)
    local reader = Archiver.Reader:new()
    if not reader:open(zip_path) then
        return false, reader.err or "archive open failed"
    end

    local extracted = 0
    for entry in reader:iterate() do
        if entry.mode ~= "file" and entry.mode ~= "directory" then
            reader:close()
            return false, "unsupported archive entry type: " .. tostring(entry.mode)
        end
        if not reader:extractToPath(entry.path, destination .. "/" .. entry.path) then
            local extract_error = reader.err or ("failed to extract " .. entry.path)
            reader:close()
            return false, extract_error
        end
        extracted = extracted + 1
    end

    local read_error = reader.err
    reader:close()
    if read_error then
        return false, read_error
    end
    if extracted == 0 then
        return false, "archive contains no entries"
    end
    return true
end

local function validate_plugin_tree(root)
    logger.dbg("validate_plugin_tree root=", root)
    if not path_is_dir(root) then
        logger.warn("validate_plugin_tree missing dir:", root)
        return false, "plugin folder missing"
    end
    local required = {
        "_meta.lua",
        "main.lua",
        "common/ui/zen_screen.lua",
        "modules/settings/zen_updater.lua",
    }
    for _i, rel in ipairs(required) do
        if not path_is_readable_file(root .. "/" .. rel) then
            logger.warn("validate_plugin_tree missing required file:", root .. "/" .. rel)
            return false, "missing " .. rel
        end
    end
    logger.dbg("validate_plugin_tree ok root=", root)
    return true
end

local function prepare_plugins_dir_writable(plugins_dir)
    logger.dbg("prepare_plugins_dir_writable dir=", plugins_dir)
    local probe = plugins_dir .. "/.zenos_update_write_probe"
    local f = io.open(probe, "wb")
    if not f then
        logger.warn("plugins dir write probe open failed path=", probe)
        return false
    end
    f:write("ok")
    f:close()
    os.remove(probe)
    logger.dbg("prepare_plugins_dir_writable ok")
    return true
end

local function safe_remove_tree(path)
    return run_shell_ok(string.format("rm -rf %q", path), "remove_tree")
end

local function safe_rename(src, dst)
    return run_shell_ok(string.format("mv %q %q", src, dst), "rename")
end

--- Download, unpack, and reboot using an existing ZenScreen for all UI feedback.
local function _do_install(screen, plugin_root, plugins_dir)
    local UIManager = require("ui/uimanager")
    local Trapper   = require("ui/trapper")
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")

    local function has_network()
        return ok_nm and NetworkMgr and NetworkMgr:isWifiOn()
    end

    logger.info("install begin plugin_root=", plugin_root, "plugins_dir=", plugins_dir)

    logger.dbg("install refreshing release metadata")
    if not do_network_check() then
        logger.warn("install abort live metadata refresh failed")
        screen:update{
            subtitle    = M._last_error or _("Could not reach update server. Check your internet connection."),
            button      = _("OK"),
            dismissable = true,
        }
        return
    end
    persist_state(os.time())
    if not M._has_update then
        logger.warn("install abort no newer release after refresh")
        screen:update{ subtitle = _("ZenOS is up to date."), button = _("OK"), dismissable = true }
        return
    end
    if not is_valid_asset_url(M._dl_url) then
        logger.warn("install abort invalid dl url:", tostring(M._dl_url))
        screen:update{ subtitle = _("No update asset found."), button = _("OK"), dismissable = true }
        return
    end
    if not is_valid_sha256_digest(M._latest_sha256) then
        logger.warn("install abort invalid/missing sha256")
        screen:update{ subtitle = _("Update failed: missing checksum."), button = _("OK"), dismissable = true }
        return
    end

    if not has_network() then
        logger.warn("install abort no network")
        screen:update{ subtitle = _("Update failed: network connection lost."), button = _("OK"), dismissable = true }
        return
    end

    local zip_path = plugins_dir .. "/zenos_update.zip"
    local plugin_name = plugin_root:match("([^/]+)$") or CURRENT_PLUGIN_NAME
    local active_dir = plugins_dir .. "/" .. plugin_name
    local backup_dir = plugins_dir .. "/" .. plugin_name .. ".backup"
    local stage_parent = plugins_dir .. "/.zenos_update_stage"
    local staged_dir = stage_parent .. "/" .. plugin_name
    logger.dbg(
        "install paths active=", active_dir,
        " backup=", backup_dir,
        " stage_parent=", stage_parent,
        " staged=", staged_dir,
        " zip=", zip_path
    )

    local function fail_with(msg)
        logger.warn("install fail:", msg)
        screen:update{ subtitle = msg, button = _("OK"), dismissable = true }
    end

    local function rollback_active_from_backup()
        logger.warn("rollback start from backup")
        -- Remove partial active tree before restoring backup.
        if path_exists(active_dir) then
            logger.dbg("rollback removing partial active:", active_dir)
            safe_remove_tree(active_dir)
        end
        local ok_restore = safe_rename(backup_dir, active_dir)
        logger.warn("rollback done ok=", tostring(ok_restore))
        return ok_restore
    end

    -- Trapper:wrap() runs the function as a coroutine so UIManager stays alive.
    Trapper:wrap(function()
        local co = coroutine.running()
        local timed_out = false
        local cancelled = false

        -- Show Cancel button now that co is available to receive the abort signal.
        -- Passing screen as trap_widget keeps ZenScreen on top (no invisible TrapWidget
        -- is stacked above it), so taps reach _on_button_action normally.
        screen._on_button_action = function()
            cancelled = true
            coroutine.resume(co, false)
        end
        screen:update{ button = _("Cancel"), later_button = false, dismissable = false }
        UIManager:forceRePaint()

        local timeout_cb = function()
            timed_out = true
            coroutine.resume(co, false)
        end
        UIManager:scheduleIn(INSTALL_TIMEOUT, timeout_cb)

        local completed, ok, err = dismissable_or_in_process(Trapper, function()
            return https_download(M._dl_url, zip_path, M._latest_sha256)
        end, screen)
        logger.dbg("download task result completed=", tostring(completed), "ok=", tostring(ok), "err=", tostring(err))

        UIManager:unschedule(timeout_cb)
        screen._on_button_action = nil  -- prevent stale cancel action on subsequent button states

        if not completed then
            os.remove(zip_path)
            if cancelled then
                screen:onClose()
            elseif timed_out then
                screen:update{ subtitle = _("Update failed: timed out."), button = _("OK"), dismissable = true }
            elseif not has_network() then
                screen:update{ subtitle = _("Update failed: network connection lost."), button = _("OK"), dismissable = true }
            else
                screen:update{ subtitle = _("Update cancelled."), button = _("OK"), dismissable = true }
            end
            return
        end

        if not ok then
            if not has_network() then
                screen:update{ subtitle = _("Update failed: network connection lost."), button = _("OK"), dismissable = true }
            else
                screen:update{ subtitle = _("Download failed: ") .. (err or _("unknown error")), button = _("OK"), dismissable = true }
            end
            return
        end

        logger.dbg(
            "download artifact ready zip=",
            zip_path,
            "exists=",
            tostring(path_exists(zip_path)),
            "size_bytes=",
            tostring(get_file_size_bytes(zip_path))
        )

        -- Preflight checks before touching the active plugin folder.
        logger.dbg("preflight start")
        if not prepare_plugins_dir_writable(plugins_dir) then
            os.remove(zip_path)
            fail_with(_("Update failed: plugin directory is not writable."))
            return
        end

        if not check_zip_integrity(zip_path) then
            os.remove(zip_path)
            fail_with(_("Update failed: corrupted update package."))
            return
        end

        local zip_ok, zip_reason = validate_zip_layout(zip_path, plugin_name)
        if not zip_ok then
            os.remove(zip_path)
            logger.warn("rejected update zip layout:", tostring(zip_reason))
            fail_with(_("Update failed: invalid package layout."))
            return
        end
        logger.dbg("preflight checks passed")

        screen:update{ subtitle = _("Installing") .. "...", button = false }
        UIManager:forceRePaint()
        logger.dbg("install staging begin")

        -- Clean stale leftovers from previous interrupted updates.
        safe_remove_tree(stage_parent)

        if not path_exists(active_dir) and path_exists(backup_dir) then
            logger.warn("active folder missing; restoring from backup before update")
            if not safe_rename(backup_dir, active_dir) then
                os.remove(zip_path)
                fail_with(_("Update failed: could not restore previous plugin backup."))
                return
            end
        end

        safe_remove_tree(backup_dir)

        if not run_shell_ok(string.format("mkdir -p %q", stage_parent), "mkdir_stage_parent") then
            os.remove(zip_path)
            fail_with(_("Update failed: could not prepare staging area."))
            return
        end

        local unpack_ok, unpack_reason = extract_zip_with_archiver(zip_path, stage_parent)
        if not unpack_ok then
            logger.warn("ffi/archiver extraction failed:", tostring(unpack_reason))
            safe_remove_tree(stage_parent)
            os.remove(zip_path)
            fail_with(_("Update failed: could not unpack update package."))
            return
        end

        local staged_ok, staged_reason = validate_plugin_tree(staged_dir)
        if not staged_ok then
            logger.warn("staged validation failed:", tostring(staged_reason))
            safe_remove_tree(stage_parent)
            os.remove(zip_path)
            fail_with(_("Update failed: staged plugin validation failed."))
            return
        end

        if not path_exists(active_dir) then
            logger.warn("install active dir missing before backup rename:", active_dir)
            safe_remove_tree(stage_parent)
            os.remove(zip_path)
            fail_with(_("Update failed: active plugin folder not found."))
            return
        end

        logger.dbg("swap start moving active to backup")
        if not safe_rename(active_dir, backup_dir) then
            safe_remove_tree(stage_parent)
            os.remove(zip_path)
            fail_with(_("Update failed: could not create backup."))
            return
        end

        logger.dbg("swap activating staged plugin")
        if not safe_rename(staged_dir, active_dir) then
            logger.warn("activation rename failed, attempting rollback")
            safe_remove_tree(stage_parent)
            os.remove(zip_path)
            if rollback_active_from_backup() then
                fail_with(_("Update failed: could not activate new version."))
            else
                fail_with(_("Update failed and rollback failed."))
            end
            return
        end

        safe_remove_tree(stage_parent)

        local active_ok, active_reason = validate_plugin_tree(active_dir)
        if not active_ok then
            logger.warn("post-swap validation failed:", tostring(active_reason))
            os.remove(zip_path)
            if rollback_active_from_backup() then
                fail_with(_("Update failed: new version is invalid."))
            else
                fail_with(_("Update failed and rollback failed."))
            end
            return
        end

        safe_remove_tree(backup_dir)
        os.remove(zip_path)
        logger.info("install transaction completed successfully")

        local installed_version = M._latest_ver or ""
        clear_update_state()
        local cfg2, updater2 = load_updater_config()
        if updater2 then
            updater2[UP_KEY_JUST_UPDATED] = installed_version
            save_updater_config(cfg2)
        end

        screen:update{ subtitle = _("Restarting") .. "..." }
        UIManager:forceRePaint()
        require("common/restart").request{ show_notice = false }
    end)
end

--- Show the ZenScreen update UI for a known-available update and run the install.
--- Called from both the settings banner and the About > Update ZenOS item.
local function _show_update_screen_and_install(plugin)
    local UIManager = require("ui/uimanager")
    local ZenScreen = require("common/ui/zen_screen")

    local plugin_root = PLUGIN_ROOT
        or (plugin and type(plugin.path) == "string" and plugin.path ~= "" and plugin.path)
        or ""
    local plugins_dir = plugin_root:match("^(.*)/[^/]+$") or plugin_root

    if not ensure_selected_release_details(true) then
        UIManager:show(ZenScreen:new{
            title       = _("ZenOS"),
            subtitle    = M._last_error or _("Could not reach update server. Check your internet connection."),
            button      = _("OK"),
            dismissable = true,
        })
        return
    end
    persist_state(os.time())

    if not M._has_update then
        local current = get_current_version()
        local subtitle
        if M._latest_ver and semver_eq(M._latest_ver, current) then
            subtitle = _("ZenOS is up to date.")
        elseif M._latest_ver and semver_gt(current, M._latest_ver) then
            subtitle = _("Installed version is newer than the latest release.")
        else
            subtitle = M._last_error or _("Could not determine update status.")
        end
        UIManager:show(ZenScreen:new{
            title       = _("ZenOS"),
            subtitle    = subtitle,
            button      = _("OK"),
            dismissable = true,
        })
        return
    end

    local ver_label   = M._latest_ver and ("v" .. M._latest_ver) or _("latest")
    local changelog_text = build_single_release_scroll_text(M._latest_notes, M._latest_ver)

    local screen
    screen = ZenScreen:new{
        title        = _("ZenOS"),
        title_icon   = true,
        subtitle     = _("Update available: ") .. ver_label,
        scroll_text  = changelog_text,
        hide_logo    = true,
        button       = _("Update now"),
        later_button = _("Later"),
        dismissable  = true,
    }
    screen._on_button_action = function()
        local progress_screen = ZenScreen:new{
            title        = _("ZenOS"),
            subtitle     = _("Downloading") .. "...",
            button       = false,
            later_button = false,
            dismissable  = false,
        }
        UIManager:close(screen)
        UIManager:show(progress_screen)
        UIManager:forceRePaint()
        UIManager:scheduleIn(0.1, function()
            _do_install(progress_screen, plugin_root, plugins_dir)
        end)
    end
    UIManager:show(screen)
end

--- Download the latest plugin asset, unpack it over the plugin directory, and
--- prompt the user to restart KOReader.
function M.run_update(plugin)
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr and not NetworkMgr:isWifiOn() then
        NetworkMgr:runWhenOnline(function() _show_update_screen_and_install(plugin) end)
    else
        _show_update_screen_and_install(plugin)
    end
end

--- Returns a menu item for the top of the ZenOS settings page when an update
--- is available, or nil when no update has been detected.
function M.build_update_available_item(plugin)
    if not M._has_update then return nil end
    return IconItem.decorate({
        _zen_update_banner = true,  -- marker so root_items.callback can remove it
        text          = _("Update available"),
        keep_menu_open = true,
        callback      = function()
            M.run_update(plugin)
        end,
    }, icons.update)
end

--- Returns the "Update ZenOS" menu item for the Updates section.
--- When a newer version has already been detected the text changes to reflect
--- the pending update and tapping it launches the download flow directly.
function M.build_update_now_item(plugin)
    return {
        text_func = function()
            if M._has_update then
                return "\u{F01B} " .. _("Update available")
            end
            return _("Update ZenOS")
        end,
        keep_menu_open = true,
        callback = function()
            local UIManager  = require("ui/uimanager")
            local ZenScreen  = require("common/ui/zen_screen")
            local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")

            -- Force this check to go to the network; keep any persisted banner
            -- until the live check says otherwise.
            clear_release_details()
            local cfg, updater = load_updater_config()
            if updater then
                updater[UP_KEY_TIME] = 0
                clear_persisted_release_state(updater)
                save_updater_config(cfg)
            end

            local function run_check()
                local screen
                screen = ZenScreen:new{
                    subtitle     = _("Checking for updates") .. "...",
                    button       = _("Cancel"),
                    later_button = false,
                    dismissable  = false,
                }
                UIManager:show(screen)
                UIManager:forceRePaint()
                UIManager:scheduleIn(0.1, function()
                    network_check_async(
                        screen,
                        function(co)
                            screen._on_button_action = function()
                                screen._on_button_action = nil
                                coroutine.resume(co, false)
                            end
                        end,
                        function(net_ok)
                            screen._on_button_action = nil
                            if net_ok then
                                persist_state(os.time())
                            else
                                clear_release_details()
                            end
                            if not net_ok then
                                screen:update{
                                    subtitle    = M._last_error or _("Could not reach update server. Check your internet connection."),
                                    button      = _("OK"),
                                    dismissable = true,
                                }
                            elseif M._has_update then
                                screen:update{ dismissable = true }
                                UIManager:close(screen)
                                _show_update_screen_and_install(plugin)
                            else
                                local current = get_current_version()
                                if M._latest_ver and semver_eq(M._latest_ver, current) then
                                    screen:update{
                                        subtitle    = _("ZenOS is up to date."),
                                        button      = _("OK"),
                                        dismissable = true,
                                    }
                                elseif M._latest_ver and semver_gt(current, M._latest_ver) then
                                    screen:update{
                                        subtitle    = _("Installed version is newer than the latest release."),
                                        button      = _("OK"),
                                        dismissable = true,
                                    }
                                else
                                    screen:update{
                                        subtitle    = M._last_error or _("Could not determine update status."),
                                        button      = _("OK"),
                                        dismissable = true,
                                    }
                                end
                            end
                        end,
                        function()
                            screen._on_button_action = nil
                            screen:onClose()
                        end
                    )
                end)
            end

            if ok_nm and NetworkMgr and not NetworkMgr:isWifiOn() then
                NetworkMgr:runWhenOnline(run_check)
            else
                run_check()
            end
        end,
    }
end

--- Returns a menu item that opens a scrollable release changelog viewer.
function M.build_changelog_item()
    return {
        text = _("Changelog"),
        keep_menu_open = true,
        callback = function()
            local UIManager = require("ui/uimanager")
            local ZenScreen = require("common/ui/zen_screen")
            local channel = get_channel()
            local entries = load_bundled_changelog_entries(channel)
            local shown = 5
            local text, has_more = build_changelog_text(entries, shown)
            local screen
            local function refresh_text()
                text, has_more = build_changelog_text(entries, shown)
                screen._on_button_action = nil
                screen:update{
                    scroll_text = text,
                    button = has_more and _("Load more") or false,
                    later_button = _("Close"),
                    dismissable = true,
                    preserve_scroll = true,
                }
                if has_more then
                    screen._on_button_action = function()
                        shown = math.min(shown + 5, #entries)
                        refresh_text()
                    end
                end
            end

            screen = ZenScreen:new{
                title        = _("Changelog"),
                title_icon   = true,
                scroll_text  = text,
                button       = has_more and _("Load more") or false,
                later_button = _("Close"),
                dismissable  = true,
            }
            if has_more then
                screen._on_button_action = function()
                    shown = math.min(shown + 5, #entries)
                    refresh_text()
                end
            end
            UIManager:show(screen)
        end,
    }
end

--- Returns the active update channel: "stable" (default) or "beta".
function M.get_channel()
    return get_channel()
end

--- Returns true when background update checks are enabled.
function M.is_auto_check_enabled()
    return is_auto_check_enabled()
end

--- Enable or disable automatic background update checks.
function M.set_auto_check_enabled(enabled)
    local cfg, updater = load_updater_config()
    if not updater then return end
    local on = enabled ~= false
    updater[UP_KEY_AUTO] = on
    save_updater_config(cfg)
    if on then
        M.schedule_wakeup_check()
    else
        M.cancel_wakeup_check()
    end
end

--- Set the update channel and reset cached state so the next check uses it.
function M.set_channel(ch)
    local cfg, updater = load_updater_config()
    if not updater then return end
    updater[UP_KEY_CHANNEL] = ch == "beta" and "beta" or "stable"
    -- Drop in-memory release details so the next check goes to the network.
    M._has_update = false
    M._latest_ver = nil
    M._dl_url     = nil
    M._latest_sha256 = nil
    M._latest_notes = nil
    updater[UP_KEY_TIME] = 0
    save_updater_config(cfg)
end

--- Returns a radio-style "Update channel" sub-menu item for the Updates section.
function M.build_channel_item()
    return {
        text = _("Update channel"),
        sub_item_table = {
            {
                text = _("Stable"),
                checked_func = function() return get_channel() == "stable" end,
                callback = function() M.set_channel("stable") end,
            },
            {
                text = _("Beta"),
                checked_func = function() return get_channel() == "beta" end,
                callback = function() M.set_channel("beta") end,
            },
        },
    }
end

--- Returns a checkbox item to toggle automatic background checks.
function M.build_auto_check_item()
    return {
        text = _("Check for updates automatically"),
        checked_func = function()
            return is_auto_check_enabled()
        end,
        callback = function()
            M.set_auto_check_enabled(not is_auto_check_enabled())
        end,
        keep_menu_open = true,
    }
end

return M
