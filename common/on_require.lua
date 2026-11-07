-- Defers class patches until KOReader first requires the patched module, so
local logger = require("common/zen_logger").new("on_require")

local M = {}
local pending = {}

-- Resolve through every searcher after preload, so custom KOReader loaders still apply.
local function load_module(name)
    local searchers = package.loaders
    local errors = {}
    for i = 2, #searchers do
        local loader, extra = searchers[i](name)
        if type(loader) == "function" then return loader(name, extra) end
        if type(loader) == "string" then errors[#errors + 1] = loader end
    end
    error(("module '%s' not found:%s"):format(name, table.concat(errors)), 2)
end

function M.whenLoaded(name, fn)
    if package.loaded[name] then return fn() end
    local queue = pending[name]
    if not queue then
        queue = {}
        pending[name] = queue
        package.preload[name] = function()
            package.preload[name] = nil
            local module = load_module(name)
            package.loaded[name] = module
            pending[name] = nil
            for _i, callback in ipairs(queue) do
                local ok, err = pcall(callback)
                if not ok then logger.warn("Deferred patch failed", name, err) end
            end
            return module
        end
    end
    queue[#queue + 1] = fn
end

return M
