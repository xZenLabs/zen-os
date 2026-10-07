local defaults = require("config/defaults").browser_list_item_layout
local M = {}

function M.order(config)
    local order, seen = {}, {}
    local function append(items)
        for _i, id in ipairs(items) do
            if defaults.show[id] ~= nil and not seen[id] then
                seen[id] = true
                order[#order + 1] = id
            end
        end
    end
    append(config and config.order or {})
    append(defaults.order)
    return order
end

function M.enabled(config, id)
    local value = config and config.show and config.show[id]
    if value == nil then return defaults.show[id] == true end
    return value == true
end

return M
