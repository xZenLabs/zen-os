local json = require("json")
local logger = require("common/zen_logger").new("metadata_http")

local M = {}
local USER_AGENT = "ZenOS metadata (https://github.com/xZenLabs/zen-os)"
local BLOCK_TIMEOUT = 6
local TOTAL_TIMEOUT = 12
local MAX_RESPONSE_BYTES = 2 * 1024 * 1024
local MAX_COVER_BYTES = 12 * 1024 * 1024
local ERROR_KINDS = {
    offline = true,
    unauthorized = true,
    forbidden = true,
    rate_limited = true,
    server = true,
    malformed = true,
    no_match = true,
    network = true,
}
local MODULE_CA_BUNDLE
do
    local source = debug.getinfo(1, "S").source or ""
    if source:sub(1, 1) == "@" then
        local directory = source:sub(2):match("^(.*[/\\])http%.lua$")
        if directory then MODULE_CA_BUNDLE = directory .. "ca-bundle.crt" end
    end
end

function M.failure(kind, status, retry_after)
    local err = { kind = kind }
    if status then err.status = status end
    if retry_after then err.retry_after = retry_after end
    return err
end

local function header_value(headers, wanted)
    if type(headers) ~= "table" then return nil end
    wanted = wanted:lower()
    for key, value in pairs(headers) do
        if type(key) == "string" and key:lower() == wanted then return value end
    end
end

local function ca_bundle(https)
    local candidates = {
        MODULE_CA_BUNDLE or "",
        "data/ca-bundle.crt",
        "./data/ca-bundle.crt",
        "/etc/ssl/certs/ca-certificates.crt",
        "/etc/ssl/cert.pem",
        "/etc/pki/tls/certs/ca-bundle.crt",
    }
    local info = type(https.request) == "function"
        and debug.getinfo(https.request, "S") or nil
    local source = info and info.source or ""
    if source:sub(1, 1) == "@" then
        local root = source:sub(2):match("^(.*[/\\])common[/\\]ssl[/\\]https%.lua$")
        if root then table.insert(candidates, 1, root .. "data/ca-bundle.crt") end
    end
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok_lfs then return nil end
    for _i, path in ipairs(candidates) do
        if lfs.attributes(path, "mode") == "file" then return path end
    end
end

local function hostname_matches(pattern, hostname)
    if type(pattern) ~= "string" or pattern:find("%z") then return false end
    pattern = pattern:lower()
    hostname = hostname:lower()
    if pattern == hostname then return true end
    if pattern:sub(1, 2) ~= "*." then return false end
    local suffix = pattern:sub(2)
    if hostname:sub(-#suffix) ~= suffix then return false end
    local label = hostname:sub(1, #hostname - #suffix)
    return label ~= "" and not label:find(".", 1, true)
end

local function certificate_matches(certificate, hostname)
    if type(certificate) ~= "userdata" and type(certificate) ~= "table" then
        return false
    end
    local ok, extensions = pcall(certificate.extensions, certificate)
    if not ok or type(extensions) ~= "table" then return false end
    local function find_dns(value)
        if type(value) ~= "table" then return false end
        for key, child in pairs(value) do
            if key == "dNSName" and type(child) == "table" then
                for _i, name in ipairs(child) do
                    if hostname_matches(name, hostname) then return true end
                end
            elseif type(child) == "table" and find_dns(child) then
                return true
            end
        end
        return false
    end
    return find_dns(extensions)
end

local function verified_create(https, cafile, expected_host)
    local base_create = https.tcp({
        protocol = "any",
        options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
        verify = { "peer", "fail_if_no_peer_cert" },
        cafile = cafile,
    })
    if type(base_create) ~= "function" then return nil end
    return function()
        local connection = base_create()
        if type(connection) ~= "table" or type(connection.connect) ~= "function" then
            return connection
        end
        local connect = connection.connect
        function connection:connect(host, port)
            local connected, err = connect(self, host, port)
            if not connected then return nil, err end
            local certificate = self.sock and self.sock:getpeercertificate()
            if host ~= expected_host or not certificate_matches(certificate, host) then
                pcall(self.close, self)
                return nil, "TLS hostname verification failed"
            end
            return connected
        end
        return connection
    end
end

local function connected()
    local ok_network, NetworkManager = pcall(require, "ui/network/manager")
    if not ok_network or not NetworkManager
            or type(NetworkManager.isConnected) ~= "function" then return true end
    local ok, value = pcall(NetworkManager.isConnected, NetworkManager)
    return not ok or value ~= false
end

local function dependencies()
    local ok_https, https = pcall(require, "ssl.https")
    local ok_http, http = pcall(require, "socket.http")
    local ok_ltn12, ltn12 = pcall(require, "ltn12")
    local ok_socketutil, socketutil = pcall(require, "socketutil")
    if not ok_https or not ok_http or not ok_ltn12 or not ok_socketutil
            or type(https.tcp) ~= "function"
            or type(http.request) ~= "function"
            or type(ltn12.source) ~= "table"
            or type(ltn12.source.string) ~= "function"
            or type(socketutil.set_timeout) ~= "function"
            or type(socketutil.reset_timeout) ~= "function" then
        return nil
    end
    return https, http, ltn12, socketutil
end

local function valid_origin(url, host)
    if type(url) ~= "string" or type(host) ~= "string" or host == ""
            or host:find("[^%w%.%-]") then return false end
    return url:sub(1, #host + 9) == "https://" .. host .. "/"
end

function M.request(options)
    if type(options) ~= "table"
            or not valid_origin(options.url, options.host) then
        return nil, M.failure("malformed")
    end
    if not connected() then return nil, M.failure("offline") end
    local https, http, ltn12, socketutil = dependencies()
    if not https then return nil, M.failure("network") end
    local cafile = ca_bundle(https)
    local create = cafile and verified_create(https, cafile, options.host)
    if not create then return nil, M.failure("network") end

    local headers = { ["User-Agent"] = USER_AGENT }
    for key, value in pairs(type(options.headers) == "table" and options.headers or {}) do
        headers[key] = value
    end
    local body = options.body
    local source
    if body ~= nil then
        if type(body) ~= "string" then return nil, M.failure("malformed") end
        headers["Content-Length"] = tostring(#body)
        local ok_source
        ok_source, source = pcall(ltn12.source.string, body)
        if not ok_source then return nil, M.failure("network") end
    end
    local chunks, bytes, oversized = {}, 0, false
    local function sink(chunk)
        if not chunk then return 1 end
        bytes = bytes + #chunk
        if bytes > MAX_RESPONSE_BYTES then
            oversized = true
            return nil, "metadata response too large"
        end
        chunks[#chunks + 1] = chunk
        return 1
    end
    if not pcall(socketutil.set_timeout, socketutil, BLOCK_TIMEOUT, TOTAL_TIMEOUT) then
        return nil, M.failure("network")
    end
    local ok_request, result, status, response_headers = pcall(http.request, {
        url = options.url,
        method = options.method or "GET",
        redirect = false,
        headers = headers,
        source = source,
        sink = sink,
        create = create,
    })
    pcall(socketutil.reset_timeout, socketutil)
    if oversized then return nil, M.failure("malformed") end
    if not ok_request or result == nil or tonumber(status) == nil then
        logger.warn("request failed host=", options.host)
        return nil, M.failure("network")
    end
    return {
        status = tonumber(status),
        headers = response_headers,
        body = table.concat(chunks),
    }
end

function M.transportFailure(err)
    if type(err) ~= "table" or not ERROR_KINDS[err.kind] then
        return M.failure("network")
    end
    return M.failure(err.kind, tonumber(err.status), tonumber(err.retry_after))
end

function M.decodeJson(response)
    if type(response) ~= "table" then return nil, M.failure("malformed") end
    local status = tonumber(response.status)
    if status == 401 then return nil, M.failure("unauthorized", status) end
    if status == 403 then return nil, M.failure("forbidden", status) end
    if status == 429 then
        return nil, M.failure("rate_limited", status,
            tonumber(header_value(response.headers, "retry-after")))
    end
    if status and status >= 500 and status <= 599 then
        return nil, M.failure("server", status)
    end
    if status == 400 then return nil, M.failure("malformed", status) end
    if not status or status < 200 or status > 299 then
        return nil, M.failure("network", status)
    end
    if type(response.body) ~= "string" or response.body == "" then
        return nil, M.failure("malformed", status)
    end
    local ok, decoded = pcall(json.decode, response.body)
    if not ok or type(decoded) ~= "table" then
        return nil, M.failure("malformed", status)
    end
    return decoded
end

function M.get(url, host, headers, transport, server_retries)
    if transport ~= nil and type(transport) ~= "function" then
        return nil, M.failure("malformed")
    end
    local function request()
        local ok, response, err = pcall(transport or function()
            return M.request{ url = url, host = host, headers = headers }
        end, url, headers)
        if not ok then return nil, M.failure("network") end
        if not response then return nil, M.transportFailure(err) end
        return response
    end
    local retries = math.max(0, math.floor(tonumber(server_retries) or 1))
    local retry_all_server_errors = server_retries ~= nil
    local response, err
    for attempt = 0, retries do
        response, err = request()
        local status = response and tonumber(response.status)
        local retryable = status == 503
            or (retry_all_server_errors and status and status >= 500 and status <= 599)
        if not retryable or attempt == retries then break end
        require("socket").sleep(1)
    end
    return response, err
end

function M.getJson(url, host, headers, transport)
    local response, err = M.get(url, host, headers, transport)
    if not response then return nil, err end
    return M.decodeJson(response)
end

local function default_download(url, destination, host, headers)
    if not connected() then return nil, M.failure("offline") end
    local https, http, ltn12, socketutil = dependencies()
    if not https or not ltn12 then return nil, M.failure("network") end
    local cafile = ca_bundle(https)
    local create = cafile and verified_create(https, cafile, host)
    if not create then return nil, M.failure("network") end
    local file = io.open(destination, "wb")
    if not file then return nil, M.failure("network") end
    local bytes, sink_error = 0, false
    local function sink(chunk)
        if not chunk then return 1 end
        bytes = bytes + #chunk
        if bytes > MAX_COVER_BYTES or not file:write(chunk) then
            sink_error = true
            return nil, "cover write failed"
        end
        return 1
    end
    local request_headers = { ["User-Agent"] = USER_AGENT }
    for key, value in pairs(type(headers) == "table" and headers or {}) do
        request_headers[key] = value
    end
    pcall(socketutil.set_timeout, socketutil, BLOCK_TIMEOUT, TOTAL_TIMEOUT)
    local ok, result, status = pcall(http.request, {
        url = url,
        method = "GET",
        redirect = false,
        headers = request_headers,
        sink = sink,
        create = create,
    })
    pcall(socketutil.reset_timeout, socketutil)
    pcall(file.close, file)
    status = tonumber(status)
    if not ok or result == nil or status ~= 200 or sink_error or bytes == 0 then
        os.remove(destination)
        if status == 429 then return nil, M.failure("rate_limited", status) end
        if status and status >= 500 then return nil, M.failure("server", status) end
        return nil, M.failure("network", status)
    end
    return destination
end

function M.download(url, destination, host, headers, transport)
    if not valid_origin(url, host) or type(destination) ~= "string" or destination == ""
            or (transport ~= nil and type(transport) ~= "function") then
        return nil, M.failure("malformed")
    end
    local ok, path, err = pcall(transport or default_download,
        url, destination, host, headers)
    if not ok then return nil, M.failure("network") end
    if not path then return nil, M.transportFailure(err) end
    return path
end

return M
