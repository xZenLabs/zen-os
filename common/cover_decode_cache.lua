-- Byte-bounded cache for decoded CoverBrowser thumbnails.
local M = {
    DEFAULT_BYTE_BUDGET = 6 * 1024 * 1024,
    MAX_METADATA_ENTRIES = 256,
    _byte_budget = 6 * 1024 * 1024,
    _bytes = 0,
    _clock = 0,
    _entries = {},
    _metadata_entries = {},
    _metadata_count = 0,
    _hits = 0,
    _misses = 0,
    _evictions = 0,
    _puts = 0,
    _full_reads = 0,
    _full_read_ms = 0,
    _decode_reads = 0,
    _decode_read_ms = 0,
    _validation_reads = 0,
    _validation_ms = 0,
    _lookup_ms = 0,
    _preload_reads = 0,
    _fast_hits = 0,
    _metadata_hits = 0,
    _metadata_puts = 0,
    _metadata_evictions = 0,
}

local function bb_bytes(bb)
    if not bb then return 0 end
    local ok, bytes = pcall(function()
        local height = (bb.getHeight and bb:getHeight()) or tonumber(bb.h) or 0
        local stride = tonumber(bb.stride)
        if stride then return stride * height end
        local width = (bb.getWidth and bb:getWidth()) or tonumber(bb.w) or 0
        local bpp = (bb.getBpp and bb:getBpp()) or 8
        return width * height * math.ceil(bpp / 8)
    end)
    return ok and bytes or 0
end

local function free_bb(bb)
    if bb and bb.free then pcall(bb.free, bb) end
end

local function copy_bb(bb)
    if not (bb and bb.copy) then return nil end
    local ok, copy = pcall(bb.copy, bb)
    return ok and copy or nil
end

local function copy_metadata(info)
    if type(info) ~= "table" then return nil end
    local copy = {}
    for key, value in pairs(info) do
        if key ~= "cover_bb" then copy[key] = value end
    end
    return copy
end

local function copy_entry(self, entry, fast)
    local bb = copy_bb(entry.bb)
    if not bb then return nil end
    self._clock = self._clock + 1
    entry.touched = self._clock
    self._hits = self._hits + 1
    if fast then self._fast_hits = self._fast_hits + 1 end
    return bb
end

function M:_dropMetadata(key, evicted)
    if not self._metadata_entries[key] then return end
    self._metadata_entries[key] = nil
    self._metadata_count = self._metadata_count - 1
    if evicted then self._metadata_evictions = self._metadata_evictions + 1 end
end

-- Evicts the least-recent quarter at once so inserts do not rescan every entry.
function M:_makeMetadataRoom()
    local max = self.MAX_METADATA_ENTRIES
    if self._metadata_count < max then return end
    local entries = {}
    for key, entry in pairs(self._metadata_entries) do
        entries[#entries + 1] = { key = key, touched = entry.touched }
    end
    table.sort(entries, function(a, b) return a.touched < b.touched end)
    local target = math.max(0, max - math.max(1, math.floor(max / 4)))
    for index = 1, #entries - target do
        self:_dropMetadata(entries[index].key, true)
    end
end

function M:_drop(key, evicted)
    local entry = self._entries[key]
    if not entry then return end
    self._entries[key] = nil
    self._bytes = math.max(0, self._bytes - entry.bytes)
    if evicted and entry.metadata then
        self:putMetadata(key, entry.metadata, entry.validated_at)
    end
    free_bb(entry.bb)
    if evicted then self._evictions = self._evictions + 1 end
end

function M:_makeRoom(bytes)
    while self._bytes + bytes > self._byte_budget do
        local oldest_key
        local oldest_touch
        for key, entry in pairs(self._entries) do
            if not oldest_touch or entry.touched < oldest_touch then
                oldest_key = key
                oldest_touch = entry.touched
            end
        end
        if not oldest_key then break end
        self:_drop(oldest_key, true)
    end
end

function M:has(key)
    return key ~= nil and self._entries[key] ~= nil
end

-- Returns a caller-owned copy. Cache entries are never shared with ImageWidget,
-- which may free its source buffer when the widget is released.
function M:get(key, signature, metadata, validated_at)
    local entry = key and self._entries[key]
    if not entry then
        self._misses = self._misses + 1
        return nil
    end
    if entry.signature ~= signature then
        self:_drop(key)
        self._misses = self._misses + 1
        return nil
    end
    local copy = copy_entry(self, entry, false)
    if not copy then
        self:_drop(key)
        self._misses = self._misses + 1
        return nil
    end
    if metadata then entry.metadata = copy_metadata(metadata) end
    if validated_at then entry.validated_at = validated_at end
    return copy
end

-- Returns a complete caller-owned bookinfo without touching SQLite while the
-- cached metadata is still inside its bounded validation window.
function M:getFresh(key, current_time, max_age)
    local entry = key and self._entries[key]
    if not entry or not entry.metadata or not entry.validated_at
            or current_time - entry.validated_at > max_age then
        return nil
    end
    local bb = copy_entry(self, entry, true)
    if not bb then
        self:_drop(key)
        return nil
    end
    local info = copy_metadata(entry.metadata)
    info.cover_bb = bb
    return info
end

-- Returns metadata without copying the cached cover bitmap.
function M:getFreshMetadata(key, current_time, max_age)
    local entry = key and (self._entries[key] or self._metadata_entries[key])
    if not entry or not entry.metadata or not entry.validated_at
            or current_time - entry.validated_at > max_age then
        return nil
    end
    self._clock = self._clock + 1
    entry.touched = self._clock
    self._metadata_hits = self._metadata_hits + 1
    return copy_metadata(entry.metadata)
end

-- Keeps metadata for generated covers without retaining a decoded bitmap.
function M:putMetadata(key, metadata, validated_at)
    if not key or type(metadata) ~= "table" then return false end
    local cover_entry = self._entries[key]
    if cover_entry then
        cover_entry.metadata = copy_metadata(metadata)
        cover_entry.validated_at = validated_at
        self._clock = self._clock + 1
        cover_entry.touched = self._clock
        return true
    end
    if not self._metadata_entries[key] then
        self:_makeMetadataRoom()
        self._metadata_count = self._metadata_count + 1
    end
    self._clock = self._clock + 1
    self._metadata_entries[key] = {
        metadata = copy_metadata(metadata),
        validated_at = validated_at,
        touched = self._clock,
    }
    self._metadata_puts = self._metadata_puts + 1
    return true
end

-- Stores a private copy so callers retain normal ownership of the source bb.
function M:put(key, signature, bb, metadata, validated_at)
    if not key or not bb then return false end
    local bytes = bb_bytes(bb)
    if bytes <= 0 or bytes > self._byte_budget then
        return false
    end
    self:_drop(key)
    self:_dropMetadata(key)
    self:_makeRoom(bytes)
    local copy = copy_bb(bb)
    if not copy then return false end
    bytes = bb_bytes(copy)
    if bytes <= 0 or bytes > self._byte_budget then
        free_bb(copy)
        return false
    end
    self:_makeRoom(bytes)
    self._clock = self._clock + 1
    self._entries[key] = {
        bb = copy,
        bytes = bytes,
        signature = signature,
        metadata = copy_metadata(metadata),
        validated_at = validated_at,
        touched = self._clock,
    }
    self._bytes = self._bytes + bytes
    self._puts = self._puts + 1
    return true
end

function M:recordMiss()
    self._misses = self._misses + 1
end

function M:recordLookup(elapsed_ms)
    self._lookup_ms = self._lookup_ms + (tonumber(elapsed_ms) or 0)
end

function M:recordValidation(elapsed_ms)
    self._validation_reads = self._validation_reads + 1
    self._validation_ms = self._validation_ms + (tonumber(elapsed_ms) or 0)
end

function M:recordFullRead(elapsed_ms, decoded, preloaded)
    elapsed_ms = tonumber(elapsed_ms) or 0
    self._full_reads = self._full_reads + 1
    self._full_read_ms = self._full_read_ms + elapsed_ms
    if decoded then
        self._decode_reads = self._decode_reads + 1
        self._decode_read_ms = self._decode_read_ms + elapsed_ms
    end
    if preloaded then self._preload_reads = self._preload_reads + 1 end
end

function M:drop(key)
    self:_drop(key)
    self:_dropMetadata(key)
end

function M:clear()
    local keys = {}
    for key in pairs(self._entries) do keys[#keys + 1] = key end
    for _i, key in ipairs(keys) do self:_drop(key) end
    self._metadata_entries = {}
    self._metadata_count = 0
    self._clock = 0
    self._hits = 0
    self._misses = 0
    self._evictions = 0
    self._puts = 0
    self._full_reads = 0
    self._full_read_ms = 0
    self._decode_reads = 0
    self._decode_read_ms = 0
    self._validation_reads = 0
    self._validation_ms = 0
    self._lookup_ms = 0
    self._preload_reads = 0
    self._fast_hits = 0
    self._metadata_hits = 0
    self._metadata_puts = 0
    self._metadata_evictions = 0
end

function M:setByteBudget(bytes)
    bytes = tonumber(bytes)
    if not bytes or bytes < 0 then return false end
    self._byte_budget = math.floor(bytes)
    self:_makeRoom(0)
    return true
end

function M:stats()
    local count = 0
    for _key in pairs(self._entries) do count = count + 1 end
    return {
        bytes = self._bytes,
        byte_budget = self._byte_budget,
        count = count,
        hits = self._hits,
        misses = self._misses,
        evictions = self._evictions,
        puts = self._puts,
        full_reads = self._full_reads,
        full_read_ms = self._full_read_ms,
        decode_reads = self._decode_reads,
        decode_read_ms = self._decode_read_ms,
        validation_reads = self._validation_reads,
        validation_ms = self._validation_ms,
        lookup_ms = self._lookup_ms,
        preload_reads = self._preload_reads,
        fast_hits = self._fast_hits,
        metadata_hits = self._metadata_hits,
        metadata_count = self._metadata_count,
        metadata_puts = self._metadata_puts,
        metadata_evictions = self._metadata_evictions,
    }
end

return M
