-- Standard ZenOS logger; adapts KOReader's logger backend.
local M = {}

local _logger
local _original = {}
local _enabled = {}
local _installed = false
local _plugin_root
local _now

local LEVELS = { "dbg", "info", "warn", "err" }
M.SLOW_THRESHOLD_MS = 500

local function get_plugin_root()
    if _plugin_root ~= nil then return _plugin_root end
    local source = debug.getinfo(1, "S").source or ""
    _plugin_root = source:match("^@(.+)/common/zen_logger%.lua$") or false
    return _plugin_root
end

local function feature_from_source(source)
    local root = get_plugin_root()
    if type(source) ~= "string" or source:sub(1, 1) ~= "@" or not root then
        return nil
    end
    local path = source:sub(2)
    if path:sub(1, #root) ~= root then return nil end
    return path:match("([^/]+)%.lua$")
end

local function strip_legacy_prefix(message)
    message = message:gsub("^%[?[Zz]en[Oo][Ss]%]?[%s:]*", "")
    message = message:gsub("^%[?[Zz]en[Uu][Ii]%]?[%s:]*", "")
    message = message:gsub("^%[?[Zz]en[ _%-][Uu][Ii]%]?[%s:]*", "")
    message = message:gsub("^%b[]:%s*", "")
    message = message:gsub("^ZenUpdater:%s*", "")
    message = message:gsub("^ZenBugReporter:%s*", "")
    message = message:gsub("^ZenScreen:%s*", "")
    message = message:gsub("^ZenHeader:%s*", "")
    message = message:gsub("^zen%-coll:%s*", "")
    return message
end

local function emit(level, feature, args)
    if not _enabled[level] then return end
    if type(args[1]) == "string" then
        args[1] = string.format("ZenOS: [%s] %s", feature, strip_legacy_prefix(args[1]))
    else
        table.insert(args, 1, string.format("ZenOS: [%s]", feature))
    end
    return _original[level](unpack(args))
end

local function emit_performance(feature, message, elapsed_ms, ...)
    elapsed_ms = math.floor((tonumber(elapsed_ms) or 0) + 0.5)
    local level = elapsed_ms >= M.SLOW_THRESHOLD_MS and "warn" or "dbg"
    if not _enabled[level] then return end
    local args = { message }
    for i = 1, select("#", ...) do
        args[#args + 1] = select(i, ...)
    end
    args[#args + 1] = "elapsed_ms="
    args[#args + 1] = elapsed_ms
    if elapsed_ms >= M.SLOW_THRESHOLD_MS then
        args[1] = "SLOW: " .. tostring(message)
        args[#args + 1] = "slow_threshold_ms="
        args[#args + 1] = M.SLOW_THRESHOLD_MS
        return emit(level, feature, args)
    end
    return emit(level, feature, args)
end

local function emit_measurement(feature, message, elapsed_ms, ...)
    if not _enabled.dbg then return end
    elapsed_ms = math.floor((tonumber(elapsed_ms) or 0) * 10 + 0.5) / 10
    local args = { "PERF: " .. tostring(message) }
    for i = 1, select("#", ...) do
        args[#args + 1] = select(i, ...)
    end
    args[#args + 1] = "elapsed_ms="
    args[#args + 1] = elapsed_ms
    return emit("dbg", feature, args)
end

function M.now()
    if not _now then
        local ok, socket = pcall(require, "socket")
        _now = ok and socket and type(socket.gettime) == "function"
            and socket.gettime or os.clock
    end
    return _now()
end

function M.install()
    if _installed then return _logger end

    _logger = require("logger")
    local levels = _logger.levels or { dbg = 1, info = 2, warn = 3, err = 4 }
    local function set_enabled(active_level)
        active_level = levels[active_level] or tonumber(active_level)
        if not active_level then
            for _i, level in ipairs(LEVELS) do
                local info = debug.getinfo(_logger[level], "u")
                _enabled[level] = not info or info.nups > 0
            end
            return
        end
        for _i, level in ipairs(LEVELS) do
            _enabled[level] = (levels[level] or math.huge) >= active_level
        end
    end
    set_enabled(_logger.level)
    local function wrap(level)
        return function(...)
            if not _enabled[level] then return end
            local source = debug.getinfo(2, "S").source
            local feature = feature_from_source(source)
            if feature then
                return emit(level, feature, { ... })
            end
            return _original[level](...)
        end
    end
    local function wrap_levels(active_level)
        set_enabled(active_level)
        for _i, level in ipairs(LEVELS) do
            _original[level] = _logger[level]
            _logger[level] = wrap(level)
        end
    end
    wrap_levels()
    if type(_logger.setLevel) == "function" then
        local original_set_level = _logger.setLevel
        _logger.setLevel = function(self, active_level, ...)
            local result = original_set_level(self, active_level, ...)
            wrap_levels(active_level)
            return result
        end
    end
    _installed = true
    return _logger
end

function M.new(feature)
    M.install()
    feature = feature or "unknown"
    local logger = {}
    local function method(level)
        return function(...)
            if not _enabled[level] then return end
            local source = debug.getinfo(2, "S").source
            return emit(level, feature_from_source(source) or feature, { ... })
        end
    end
    for _i, level in ipairs(LEVELS) do
        logger[level] = method(level)
    end
    logger.perf = function(message, elapsed_ms, ...)
        local level = (tonumber(elapsed_ms) or 0) >= M.SLOW_THRESHOLD_MS
            and "warn" or "dbg"
        if not _enabled[level] then return end
        local source = debug.getinfo(2, "S").source
        return emit_performance(feature_from_source(source) or feature, message, elapsed_ms, ...)
    end
    logger.measure = function(message, elapsed_ms, ...)
        if not _enabled.dbg then return end
        local source = debug.getinfo(2, "S").source
        return emit_measurement(feature_from_source(source) or feature, message, elapsed_ms, ...)
    end
    return logger
end

return M
