local M = {}

function M.hasItems(config)
    config = config or {}
    return #(config.left_order or {}) > 0 or #(config.center_order or {}) > 0
        or #(config.right_order or {}) > 0
end

local function get_registry()
    local registry = rawget(_G, "__ZEN_UI_STATUS_ITEMS")
    if type(registry) ~= "table" then
        registry = {}
        rawset(_G, "__ZEN_UI_STATUS_ITEMS", registry)
    end
    return registry
end

local function refresh()
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local file_manager = FileManager and FileManager.instance
    if file_manager and type(file_manager._updateStatusBar) == "function" then
        pcall(file_manager._updateStatusBar, file_manager)
    end
end

function M.get(key)
    return get_registry()[key]
end

-- fetch returns icon[, label][, color]; nil icon still renders a non-empty label.
function M.register(key, fetch, opts)
    if type(key) ~= "string" or key == "" or type(fetch) ~= "function" then
        return false
    end
    opts = type(opts) == "table" and opts or {}
    local side = opts.side
    if side ~= "left" and side ~= "center" and side ~= "right" then
        side = "right"
    end
    get_registry()[key] = {
        fetch = fetch,
        label = type(opts.label) == "string" and opts.label or key,
        side = side,
    }
    refresh()
    return true
end

function M.unregister(key)
    get_registry()[key] = nil
    refresh()
end

function M.install()
    rawset(_G, "__ZENOS_REGISTER_STATUS_ITEM", M.register)
    rawset(_G, "__ZENOS_UNREGISTER_STATUS_ITEM", M.unregister)
    rawset(_G, "__ZEN_UI_REGISTER_STATUS_ITEM", M.register)
    rawset(_G, "__ZEN_UI_UNREGISTER_STATUS_ITEM", M.unregister)
end

return M
