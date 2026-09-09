-- Normalized ReadHistory helpers shared by library sorting patches.
local M = {}

local function parent_path(path)
    local parent = path:match("^(.*)/[^/]+$")
    if parent == "" then return "/" end
    return parent
end

-- Reload once and retain both the original and normalized path mappings.  The
-- caller supplies normalization because FileChooser patches have slightly
-- different compatibility fallbacks for realpath().
function M.load(normalize_path)
    local index = { by_raw_path = {}, by_normalized_path = {}, entries = {} }
    local ok_history, ReadHistory = pcall(require, "readhistory")
    if not ok_history or not ReadHistory then return index end

    pcall(ReadHistory.reload, ReadHistory, false)
    for _i, entry in ipairs(ReadHistory.hist or {}) do
        local raw_path = entry and entry.file
        local time = entry and tonumber(entry.time)
        if type(raw_path) == "string" and raw_path ~= "" and time then
            local normalized_path = normalize_path(raw_path)
            index.by_raw_path[raw_path] = time
            if normalized_path then
                index.by_normalized_path[normalized_path] = time
                index.entries[#index.entries + 1] = {
                    path = normalized_path,
                    time = time,
                }
            end
        end
    end
    return index
end

function M.fileTime(index, path, normalize_path)
    if not (index and type(path) == "string") then return nil end
    local time = index.by_raw_path[path]
    if time or next(index.by_normalized_path) == nil then return time end
    local normalized_path = normalize_path(path)
    return normalized_path and index.by_normalized_path[normalized_path]
end

-- Returns the maximum history timestamp for each requested directory.  Walking
-- file ancestors is equivalent to the previous descendant-prefix test, without
-- comparing every history entry against every visible directory.
function M.maxDescendantTimes(index, directories)
    local wanted = {}
    local result = {}
    for _i, path in ipairs(directories or {}) do
        if type(path) == "string" and path ~= "" then wanted[path] = true end
    end
    if next(wanted) == nil then return result end

    for _i, entry in ipairs(index and index.entries or {}) do
        local path = parent_path(entry.path)
        while path do
            -- Keep the previous prefix semantics: a root directory was tested
            -- against "//" and therefore never received a descendant timestamp.
            if path ~= "/" and wanted[path] then
                result[path] = math.max(result[path] or 0, entry.time)
            end
            if path == "/" then break end
            path = parent_path(path)
        end
    end
    return result
end

return M
