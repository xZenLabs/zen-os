local logger = require("common/zen_logger").new("optional_provider")
local M = {}

local function invoke(source, method, ...)
    local provider = type(source) == "string" and require(source) or source
    if type(provider) == "table" and type(provider[method]) == "function" then
        return provider[method](...)
    end
end

function M.call(source, method, ...)
    local ok, result = pcall(invoke, source, method, ...)
    if ok then return result end
    logger.warn("Optional provider call failed", tostring(source), method, result)
end

return M
