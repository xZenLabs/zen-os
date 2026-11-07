-- Shared LRU of final-size cover bitmaps used by mosaic, list, and Home.
local Blitbuffer = require("ffi/blitbuffer")
local RenderImage

local M = {
    DEFAULT_BYTE_BUDGET = 24 * 1024 * 1024,
    _byte_budget = 24 * 1024 * 1024,
    _bytes = 0,
    _clock = 0,
    _entries = {},
    _retired = {},
    _hits = 0,
    _shared_hits = 0,
    _exact_copy_hits = 0,
    _resized_hits = 0,
    _misses = 0,
    _puts = 0,
    _evictions = 0,
}

local function bytes(bb)
    if not bb then return 0 end
    local stride = tonumber(bb.stride)
    local height = (bb.getHeight and bb:getHeight()) or tonumber(bb.h) or 0
    return stride and stride * height or 0
end

local function free(bb)
    if bb and bb.free then pcall(bb.free, bb) end
end

local function path_key(path)
    return tostring(path)
end

local function exact_key(path, width, height)
    return table.concat({ path_key(path), tostring(width), tostring(height) }, "\31")
end

local function same_aspect(width_a, height_a, width_b, height_b)
    if height_a < 1 or height_b < 1 then return false end
    local rounding_tolerance = math.max(width_a, height_a, width_b, height_b)
    return math.abs(width_a * height_b - width_b * height_a) <= rounding_tolerance
end

local function is_reusable(entry, width, height)
    return entry ~= nil and entry.width >= width and entry.height >= height
        and same_aspect(entry.width, entry.height, width, height)
end

local function find_reusable(self, path, width, height)
    local wanted_path = path_key(path)
    local wanted_key = exact_key(path, width, height)
    local exact = self._entries[wanted_key]
    if exact then return exact, wanted_key end
    local best
    local best_area
    local best_key
    for cache_key, entry in pairs(self._entries) do
        if entry.path_key == wanted_path and is_reusable(entry, width, height) then
            local area = entry.width * entry.height
            if not best_area or area < best_area then
                best, best_area, best_key = entry, area, cache_key
            end
        end
    end
    return best, best_key
end

-- Takes ownership of source and returns an exact-size crop.
local function resize(source, width, height)
    local ok_dims, src_w, src_h = pcall(function()
        return source:getWidth(), source:getHeight()
    end)
    if not ok_dims or not src_w or not src_h then
        free(source)
        return nil
    end
    if src_w == width and src_h == height then return source end
    local scale = math.max(width / src_w, height / src_h)
    local scaled_w = math.max(width, math.ceil(src_w * scale))
    local scaled_h = math.max(height, math.ceil(src_h * scale))
    local scaled = source
    if scaled_w ~= src_w or scaled_h ~= src_h then
        RenderImage = RenderImage or require("ui/renderimage")
        local ok_scale, resized = pcall(
            RenderImage.scaleBlitBuffer, RenderImage,
            source, scaled_w, scaled_h, true
        )
        if not ok_scale or not resized then
            free(source)
            return nil
        end
        scaled = resized
    end
    local ok_out, out = pcall(Blitbuffer.new, width, height, scaled:getType())
    if not ok_out or not out then
        free(scaled)
        return nil
    end
    local ok_blit = pcall(out.blitFrom, out, scaled, 0, 0,
        math.floor((scaled_w - width) / 2),
        math.floor((scaled_h - height) / 2), width, height)
    free(scaled)
    if not ok_blit then
        free(out)
        return nil
    end
    return out
end

function M:_drop(cache_key, evicted)
    local entry = self._entries[cache_key]
    if not entry then return true end
    self._entries[cache_key] = nil
    if (entry.refs or 0) > 0 then
        entry.cache_key = cache_key
        self._retired[#self._retired + 1] = entry
        if evicted then self._evictions = self._evictions + 1 end
        return true
    end
    self._bytes = math.max(0, self._bytes - entry.bytes)
    free(entry.bb)
    if evicted then self._evictions = self._evictions + 1 end
    return true
end

function M:_makeRoom(needed)
    while self._bytes + needed > self._byte_budget do
        local oldest_key
        local oldest_touch
        for cache_key, entry in pairs(self._entries) do
            if (entry.refs or 0) == 0
                    and (not oldest_touch or entry.touch < oldest_touch) then
                oldest_key, oldest_touch = cache_key, entry.touch
            end
        end
        if not oldest_key then break end
        self:_drop(oldest_key, true)
    end
    return self._bytes + needed <= self._byte_budget
end

function M:get(path, width, height)
    local entry, cache_key = find_reusable(self, path, width, height)
    if not is_reusable(entry, width, height) then
        self._misses = self._misses + 1
        return nil
    end
    local ok, copy = pcall(entry.bb.copy, entry.bb)
    if not ok or not copy then
        self._misses = self._misses + 1
        return nil
    end
    local resized = resize(copy, width, height)
    if not resized then
        self:_drop(cache_key, true)
        self._misses = self._misses + 1
        return nil
    end
    self._clock = self._clock + 1
    entry.touch = self._clock
    self._hits = self._hits + 1
    if entry.width == width and entry.height == height then
        self._exact_copy_hits = self._exact_copy_hits + 1
    else
        self._resized_hits = self._resized_hits + 1
        -- Keep the first cross-layout resize so Home and Library can each hit
        -- their exact size on subsequent renders, within the same byte budget.
        self:put(path, width, height, resized)
    end
    return resized
end

function M:hasReusable(path, width, height)
    return find_reusable(self, path, width, height) ~= nil
end

function M:hasExact(path, width, height)
    return self._entries[exact_key(path, width, height)] ~= nil
end

function M:touchExact(path, width, height)
    local entry = self._entries[exact_key(path, width, height)]
    if not entry then return false end
    self._clock = self._clock + 1
    entry.touch = self._clock
    return true
end

function M:touchReusable(path, width, height)
    local entry = find_reusable(self, path, width, height)
    if not is_reusable(entry, width, height) then return false end
    self._clock = self._clock + 1
    entry.touch = self._clock
    return true
end

-- Returns an immutable cache-owned bitmap. Callers must keep it
-- non-disposable, never modify it, and pair the lease with releaseShared().
function M:getShared(path, width, height)
    local entry = self._entries[exact_key(path, width, height)]
    if not entry then
        self._misses = self._misses + 1
        return nil
    end
    self._clock = self._clock + 1
    entry.touch = self._clock
    self._hits = self._hits + 1
    self._shared_hits = self._shared_hits + 1
    entry.refs = (entry.refs or 0) + 1
    return entry.bb
end

function M:releaseShared(path, bb)
    local wanted_path = path_key(path)
    for _cache_key, entry in pairs(self._entries) do
        if entry.path_key == wanted_path and entry.bb == bb and (entry.refs or 0) > 0 then
            entry.refs = entry.refs - 1
            return true
        end
    end
    for index = #self._retired, 1, -1 do
        local entry = self._retired[index]
        if entry.path_key == wanted_path and entry.bb == bb and (entry.refs or 0) > 0 then
            entry.refs = entry.refs - 1
            if entry.refs == 0 then
                table.remove(self._retired, index)
                self._bytes = math.max(0, self._bytes - entry.bytes)
                free(entry.bb)
            end
            return true
        end
    end
    return false
end

-- Releases a getShared() lease once, when the widget holding it is freed.
-- `cache_key` upvalue name is read by the test driver.
function M:releaseOnFree(widget, cache_key, bb)
    if not widget or not cache_key then return end
    local original_free = widget.free
    widget.free = function(w, ...)
        local result = original_free(w, ...)
        if cache_key then
            self:releaseShared(cache_key, bb)
            cache_key = nil
        end
        return result
    end
end

function M:put(path, width, height, bb)
    if not path or not bb then return nil end
    local cache_key = exact_key(path, width, height)
    local existing = self._entries[cache_key]
    if existing then
        self._clock = self._clock + 1
        existing.touch = self._clock
        return bb
    end
    local size = bytes(bb)
    if size <= 0 or size > self._byte_budget then
        return nil
    end
    if not self:_drop(cache_key) or not self:_makeRoom(size) then return bb end
    local ok, stored = pcall(bb.copy, bb)
    if not ok or not stored then return nil end
    size = bytes(stored)
    if size <= 0 or size > self._byte_budget then
        free(stored)
        return nil
    end
    if not self:_makeRoom(size) then
        free(stored)
        return bb
    end
    self._clock = self._clock + 1
    self._entries[cache_key] = {
        bb = stored,
        bytes = size,
        path_key = path_key(path),
        touch = self._clock,
        width = width,
        height = height,
    }
    self._bytes = self._bytes + size
    self._puts = self._puts + 1
    return bb
end

-- Takes ownership of bb when it can be retained. The returned bitmap is
-- cache-owned when the second return value is true. That lease must be released.
function M:putShared(path, width, height, bb)
    if not path or not bb then return nil, false end
    local size = bytes(bb)
    if size <= 0 or size > self._byte_budget then
        return bb, false
    end
    local cache_key = exact_key(path, width, height)
    if not self:_drop(cache_key) or not self:_makeRoom(size) then
        return bb, false
    end
    self._clock = self._clock + 1
    self._entries[cache_key] = {
        bb = bb,
        bytes = size,
        path_key = path_key(path),
        touch = self._clock,
        width = width,
        height = height,
        refs = 1,
    }
    self._bytes = self._bytes + size
    self._puts = self._puts + 1
    return bb, true
end

-- Takes ownership of source. On success the returned bitmap is cache-owned and
-- leased; when the cache cannot retain it, the bitmap remains caller-owned.
function M:renderShared(path, source, width, height)
    local cached = self:getShared(path, width, height)
    if cached then
        free(source)
        return cached, true
    end
    if not source or width < 1 or height < 1 then return nil, false end
    local out = resize(source, width, height)
    if not out then return nil, false end
    return self:putShared(path, width, height, out)
end

-- Takes ownership of source. The returned bitmap is caller-owned.
function M:render(path, source, width, height)
    local cached = self:get(path, width, height)
    if cached then
        free(source)
        return cached
    end
    if not source or width < 1 or height < 1 then return nil end
    local out = resize(source, width, height)
    if not out then return nil end
    self:put(path, width, height, out)
    return out
end

function M:setByteBudget(value)
    value = tonumber(value)
    if not value or value < 1 then return false end
    self._byte_budget = math.floor(value)
    self:_makeRoom(0)
    return true
end

function M:drop(path)
    local wanted_path = path_key(path)
    local keys = {}
    for cache_key, entry in pairs(self._entries) do
        if entry.path_key == wanted_path then keys[#keys + 1] = cache_key end
    end
    for _i, cache_key in ipairs(keys) do self:_drop(cache_key) end
    return true
end

function M:clear()
    local keys = {}
    for cache_key in pairs(self._entries) do keys[#keys + 1] = cache_key end
    for _i, cache_key in ipairs(keys) do self:_drop(cache_key) end
    self._clock, self._hits, self._shared_hits, self._misses = 0, 0, 0, 0
    self._exact_copy_hits, self._resized_hits = 0, 0
    self._puts, self._evictions = 0, 0
end

function M:stats()
    return {
        bytes = self._bytes,
        byte_budget = self._byte_budget,
        hits = self._hits,
        shared_hits = self._shared_hits,
        exact_copy_hits = self._exact_copy_hits,
        resized_hits = self._resized_hits,
        misses = self._misses,
        puts = self._puts,
        evictions = self._evictions,
    }
end

return M
