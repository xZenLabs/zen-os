-- settings/zen_bugreporter.lua
-- "Report a Bug" flow: reads crash.log, uploads it via the Worker,
-- prompts for title/description, then POSTs a GitHub issue with a log link.
-- Falls back to inline log if upload fails.
-- Rate-limited to 3 successful submissions per 30 minutes.

local JSON = require("json")
local _ = require("gettext")
local logger = require("common/zen_logger").new("zen_bugreporter")
local UIManager = require("ui/uimanager")
local restart = require("common/restart")
local zen_utils = require("common/utils")
local updater = require("modules/settings/zen_updater")

local PROXY_URL       = "https://zen-reporter.misty-mud-afb2.workers.dev/"
local UPLOAD_URL = PROXY_URL .. "upload"
local MAX_CRASH_LOG = 60000
local MAX_TITLE     = 500
local MAX_BODY      = 65536

local M = {}

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------


--- POST JSON to url. Returns http_code, response_body_str.
local function https_post_json(url, payload_str)
    local ok_ssl, https = pcall(require, "ssl.https")
    local ok_ltn, ltn12 = pcall(require, "ltn12")
    if not ok_ssl or not ok_ltn then
        return nil, "ssl.https / ltn12 not available"
    end

    local resp = {}
    local _, code = https.request{
        url    = url,
        method = "POST",
        headers = {
            ["User-Agent"]     = "zenos.koplugin",
            ["Content-Type"]   = "application/json",
            ["Content-Length"] = tostring(#payload_str),
        },
        source = ltn12.source.string(payload_str),
        sink   = ltn12.sink.table(resp),
    }
    return code, table.concat(resp)
end

--- Upload crash log to the Worker. Returns public URL string or nil on failure.
local function upload_crash_log(log_data)
    local payload = JSON.encode({ log = log_data })
    local code, resp = https_post_json(UPLOAD_URL, payload)
    if code == 200 or code == 201 then
        return resp and resp:match('"url"%s*:%s*"([^"]+)"')
    end
    logger.warn("upload failed, code:", tostring(code))
    return nil
end

--- Read the full content of a file. Returns string or nil.
local function read_file_content(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return (data and data ~= "") and data or nil
end

-- ---------------------------------------------------------------------------
-- Issue body builder (mirrors the existing bug_report.md template)
-- ---------------------------------------------------------------------------

-- log_url: public link (preferred); if nil, embeds crash_log inline as fallback.
local function build_issue_body(description, system_info, crash_log, github_username, log_url)
    local parts = {}

    parts[#parts+1] = "**Describe the bug**"
    parts[#parts+1] = (description ~= "" and description or "_No description provided._")
    parts[#parts+1] = ""

    parts[#parts+1] = "**Environment**"
    parts[#parts+1] = system_info
    parts[#parts+1] = ""

    if log_url then
        parts[#parts+1] = "**Crash log:** [crash.log](" .. log_url .. ")"
    elseif crash_log then
        -- Collapsible inline fallback when upload was unavailable.
        parts[#parts+1] = "<details>"
        parts[#parts+1] = "<summary>crash.log</summary>"
        parts[#parts+1] = ""
        parts[#parts+1] = "```"
        parts[#parts+1] = crash_log
        parts[#parts+1] = "```"
        parts[#parts+1] = "</details>"
    else
        parts[#parts+1] = "**Crash log:** _crash.log not found_"
    end
    parts[#parts+1] = ""
    if github_username and github_username ~= "" then
        parts[#parts+1] = "**Reported by:** @" .. github_username
        parts[#parts+1] = ""
    end
    parts[#parts+1] = "_Submitted via ZenOS in-app bug reporter._"

    return table.concat(parts, "\n")
end

-- ---------------------------------------------------------------------------
-- Network submission
-- ---------------------------------------------------------------------------

local function submit_issue(title, body, version)
    local labels = { "bug" }
    if updater.get_channel() == "beta" or version:find("-alpha", 1, true) then
        labels[#labels + 1] = "beta"
    end
    local payload = JSON.encode({ title = title, body = body, labels = labels })

    logger.dbg("POSTing to proxy:", PROXY_URL)
    local code, resp = https_post_json(PROXY_URL, payload)
    logger.dbg("response code:", code)

    if code == 201 then
        local url = resp and resp:match('"url"%s*:%s*"([^"]+)"')
        return url or "https://github.com/xZenLabs/zen-os/issues"
    elseif code == 429 then
        return nil, _("Too many requests. Please try again later.")
    else
        local msg = "HTTP " .. tostring(code)
        local gh_msg = resp and resp:match('"message"%s*:%s*"([^"]+)"')
        if gh_msg then msg = msg .. " - " .. gh_msg end
        return nil, msg
    end
end

-- ---------------------------------------------------------------------------
-- Public: show_dialog
-- ---------------------------------------------------------------------------

function M.show_dialog(ctx)
    local isolation_notice = _("Before reporting, please disable other plugins and patches to see if this is actually a ZenOS issue.")
    -- Require debug logging to be on so crash.log is useful.
    if not (G_reader_settings
            and G_reader_settings:isTrue("debug")
            and G_reader_settings:isTrue("debug_verbose")) then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text        = _("Debug logging must be enabled to submit bug reports.")
                       .. "\n\n"
                       .. _("Enabling debug logging, restart required. Please reproduce the issue, then submit the report.")
                       .. "\n\n" .. isolation_notice,
            ok_text     = _("Restart now"),
            cancel_text = _("Cancel"),
            ok_callback = function()
                G_reader_settings:saveSetting("debug", true)
                G_reader_settings:saveSetting("debug_verbose", true)
                G_reader_settings:flush()
                restart.request()
            end,
        })
        return
    end

    -- Network check
    local ok_nm, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_nm and NetworkMgr and type(NetworkMgr.isOnline) == "function" then
        if not NetworkMgr:isOnline() then
            local InfoMessage = require("ui/widget/infomessage")
            UIManager:show(InfoMessage:new{
                text = _("No network connection. Please connect to Wi-Fi and try again."),
            })
            return
        end
    end

    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text    = isolation_notice .. "\n\n"
               .. _("crash.log will be embedded in a public GitHub issue. It may contain file paths and book titles.") .. ("\n\n") .. ("Continue?"),
        ok_text = _("Continue"),
        ok_callback = function()
            M._ask_title(ctx)
        end,
    })
end

function M._ask_title(ctx)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title       = _("Bug report title"),
        description = _("A short summary of what went wrong"),
        input       = "",
        input_hint  = _("Brief description of the bug"),
        buttons = {{
            {
                text = _("Cancel"),
                id   = "close",
                callback = function() UIManager:close(dlg) end,
            },
            {
                text             = _("Next"),
                is_enter_default = true,
                callback = function()
                    local title = dlg:getInputText()
                    if not title or title:match("^%s*$") then return end
                    title = title:match("^%s*(.-)%s*$")
                    UIManager:close(dlg)
                    M._ask_description(ctx, title)
                end,
            },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function M._ask_description(ctx, bug_title)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title       = _("Bug description (optional)"),
        description = _("Steps to reproduce, expected vs. actual behavior"),
        input       = "",
        input_type  = "text",
        buttons = {{
            {
                text = _("Cancel"),
                id   = "close",
                callback = function() UIManager:close(dlg) end,
            },
            {
                text             = _("Submit"),
                is_enter_default = true,
                callback = function()
                    local desc = dlg:getInputText() or ""
                    desc = desc:match("^%s*(.-)%s*$") or ""
                    UIManager:close(dlg)
                    M._ask_github(ctx, bug_title, desc)
                end,
            },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function M._ask_github(ctx, bug_title, description)
    local InputDialog = require("ui/widget/inputdialog")
    local dlg
    dlg = InputDialog:new{
        title       = _("GitHub username (optional)"),
        description = _("Enter your GitHub username to be tagged in the issue"),
        input       = "",
        input_hint  = _("username"),
        buttons = {{
            {
                text = _("Skip"),
                id   = "close",
                callback = function()
                    UIManager:close(dlg)
                    M._do_submit(ctx, bug_title, description, "")
                end,
            },
            {
                text             = _("Submit"),
                is_enter_default = true,
                callback = function()
                    local username = dlg:getInputText() or ""
                    username = username:match("^%s*(.-)%s*$") or ""
                    -- Strip leading @ if user typed it
                    username = username:match("^@?(.*)$") or ""
                    UIManager:close(dlg)
                    M._do_submit(ctx, bug_title, description, username)
                end,
            },
        }},
    }
    UIManager:show(dlg)
    dlg:onShowKeyboard()
end

function M._do_submit(ctx, bug_title, description, github_username)
    local InfoMessage = require("ui/widget/infomessage")

    -- Let the notice paint before starting the blocking network work.
    local spinner = InfoMessage:new{ text = _("Submitting report…") }
    UIManager:show(spinner)

    UIManager:tickAfterNext(function()
        -- Gather system info.
        local ok_u, sutils = pcall(require, "modules/settings/zen_settings_utils")
        local plugin = ctx and ctx.plugin
        local zen_ver  = ok_u and sutils.get_plugin_version(plugin)  or "?"
        local ko_ver   = ok_u and sutils.get_koreader_version()       or "?"
        local device   = ok_u and sutils.get_device_model_name()      or "?"
        local firmware = ok_u and sutils.get_device_firmware_display() or "?"
        local language = ok_u and sutils.get_device_language()        or "?"
        local system_info = "- ZenOS: " .. zen_ver
                         .. "\n- KOReader: " .. ko_ver
                         .. "\n- Device: " .. device
                         .. (firmware ~= "n/a" and ("\n- Firmware: " .. firmware) or "")
                         .. "\n- Language: " .. language

        local ok_android, android = pcall(require, "android")
        if ok_android and type(android.dumpLogs) == "function" then
            local dump_ok, dump_err = pcall(android.dumpLogs)
            if not dump_ok then
                logger.warn("Android log dump failed:", tostring(dump_err))
            end
        end

        -- Read crash.log from the KOReader data directory.
        local ok_ds, DataStorage = pcall(require, "datastorage")
        local data_dir = ok_ds and DataStorage:getDataDir() or nil
        local crash_log_full = data_dir and read_file_content(data_dir .. "/crash.log")

        -- Upload the full log; only truncate if upload fails and we need inline embedding.
        local log_url = crash_log_full and upload_crash_log(crash_log_full)
        local crash_log_inline
        if not log_url and crash_log_full then
            if #crash_log_full > MAX_CRASH_LOG then
                crash_log_inline = "[truncated - showing last " .. MAX_CRASH_LOG .. " chars of " .. #crash_log_full .. " total]\n"
                                 .. zen_utils.utf8SafeSuffix(crash_log_full, MAX_CRASH_LOG)
            else
                crash_log_inline = crash_log_full
            end
        end

        local issue_title = zen_utils.truncateUtf8Bytes("[BUG] " .. bug_title, MAX_TITLE + 6)
        local issue_body  = build_issue_body(description, system_info, crash_log_inline, github_username, log_url)
        if #issue_body > MAX_BODY then
            issue_body = zen_utils.truncateUtf8Bytes(issue_body, MAX_BODY, "\n...[truncated]")
        end

        local issue_url, err = submit_issue(issue_title, issue_body, zen_ver)

        UIManager:close(spinner)

        if issue_url then
            local ConfirmBox = require("ui/widget/confirmbox")
            UIManager:show(ConfirmBox:new{
                text          = _("Bug report submitted!") .. "\n\n" .. issue_url,
                no_ok_button  = true,
                cancel_text   = _("OK"),
            })
        else
            UIManager:show(InfoMessage:new{
                text = _("Failed to submit report: ") .. (err or "unknown error"),
            })
        end
    end)
end

return M
