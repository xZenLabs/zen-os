local lfs = require("lfs")
local function walk(path, out)
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local full = path .. "/" .. entry
            local attr = lfs.attributes(full)
            if attr.mode == "directory" then
                walk(full, out)
            elseif entry:sub(-4) == ".lua" then
                out[#out + 1] = full:sub(#ZenSpec.root + 2)
            end
        end
    end
end

describe("runtime test manifest", function()
    it("classifies every production Lua module", function()
        local manifest = {}
        local file = assert(io.open(ZenSpec.root .. "/spec/runtime-modules.txt", "r"))
        for line in file:lines() do
            local path, layer = line:match("^(.-)|([%a_]+)$")
            assert.is_truthy(path and layer, "invalid runtime manifest entry: " .. line)
            manifest[path] = layer
        end
        file:close()
        local files = { "main.lua", "_meta.lua" }
        walk(ZenSpec.root .. "/common", files)
        walk(ZenSpec.root .. "/config", files)
        walk(ZenSpec.root .. "/modules", files)
        for _i, path in ipairs(files) do
            assert.is_truthy(manifest[path], "unclassified runtime module: " .. path)
            manifest[path] = nil
        end
        local stale = next(manifest)
        assert.is_nil(stale, "manifest entry has no runtime module: " .. tostring(stale))
    end)
end)
