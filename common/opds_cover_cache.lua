local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local md5 = require("ffi/sha2").md5
local util = require("util")

local M = { MAX_BYTES = 32 * 1024 * 1024, MAX_AGE = 24 * 60 * 60 }
local files, total, clock = nil, 0, 0
local directory

local function init()
    if files then return end
    directory = DataStorage:getDataDir() .. "/cache/zen-opds-covers"
    util.makePath(directory)
    files = {}
    if lfs.attributes(directory, "mode") ~= "directory" then return end
    for name in lfs.dir(directory) do
        if name:match("^%x+%-%x+%.img$") then
            local attr = lfs.attributes(directory .. "/" .. name)
            if attr and attr.mode == "file" then
                files[name] = { size = attr.size, saved = attr.modification, touch = attr.modification }
                total = total + attr.size
                clock = math.max(clock, attr.modification)
            end
        end
    end
end

function M.scope(creds)
    creds = creds or {}
    return md5(table.concat({ creds.url or "", creds.username or "", creds.password or "" }, "\0"))
end

function M.key(url, creds)
    return M.scope(creds) .. "-" .. md5(url) .. ".img"
end

function M.remove(key)
    init()
    local entry = files[key]
    if entry then total = total - entry.size; files[key] = nil end
    os.remove(directory .. "/" .. key)
end

local function trim()
    while total > M.MAX_BYTES do
        local oldest
        for key, entry in pairs(files) do
            if not oldest or entry.touch < files[oldest].touch then oldest = key end
        end
        if not oldest then break end
        M.remove(oldest)
    end
end

function M.get(key)
    init()
    trim()
    local entry = files[key]
    if not entry then return end
    if os.time() - entry.saved >= M.MAX_AGE then M.remove(key); return end
    local file = io.open(directory .. "/" .. key, "rb")
    if not file then M.remove(key); return end
    local bytes = file:read("*a")
    file:close()
    clock = clock + 1
    entry.touch = clock
    return bytes
end

function M.put(key, bytes)
    init()
    if #bytes == 0 or #bytes > 2 * 1024 * 1024 then return end
    local path = directory .. "/" .. key
    local file = io.open(path .. ".tmp", "wb")
    if not file then return end
    local wrote = file:write(bytes)
    local closed = file:close()
    if not wrote or not closed or not os.rename(path .. ".tmp", path) then
        os.remove(path .. ".tmp")
        return
    end
    total = total - (files[key] and files[key].size or 0) + #bytes
    clock = clock + 1
    files[key] = { size = #bytes, saved = os.time(), touch = clock }
    trim()
end

function M.clear(creds)
    init()
    local prefix = M.scope(creds) .. "-"
    for key in pairs(files) do
        if key:sub(1, #prefix) == prefix then M.remove(key) end
    end
end

return M
