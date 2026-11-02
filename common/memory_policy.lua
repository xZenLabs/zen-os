local ok_util, util = pcall(require, "util")
if not ok_util then util = {} end

local M = {}

local MIB = 1024 * 1024
local DEFAULT_COVER_BUDGET = 30 * MIB
local MIN_COVER_BUDGET = 4 * MIB
local MAX_COVER_BUDGET = 128 * MIB
local DEFAULT_HOME_BUDGET = 6 * MIB
local MIN_HOME_BUDGET = 512 * 1024
local MAX_HOME_BUDGET = 6 * MIB
local COVER_TOTAL_FRACTION = 0.05
local COVER_AVAILABLE_FRACTION = 0.10
local LOW_MEMORY_TOTAL = 256 * MIB
local LOW_AVAILABLE_FRACTION = 0.25
local CRITICAL_AVAILABLE_FRACTION = 0.20

local last_pressure = "normal"
local home_cache_api

local function clamp(value, minimum, maximum)
    return math.max(minimum, math.min(maximum, value))
end

-- /proc/meminfo is parsed at most once per second; background loops poll every 50 ms.
local mem_read_at, mem_available, mem_total
local function read_memory()
    if type(util.calcFreeMem) ~= "function" then return nil, nil end
    local now = os.time()
    if mem_read_at == now then return mem_available, mem_total end
    local ok, available, total = pcall(util.calcFreeMem)
    available, total = tonumber(available), tonumber(total)
    if not ok or not available or not total or available < 0 or total < 1 then
        available, total = nil, nil
    end
    mem_read_at, mem_available, mem_total = now, available, total
    return available, total
end

function M.getProfile()
    local available, total = read_memory()
    local cover_budget = DEFAULT_COVER_BUDGET
    local home_budget = DEFAULT_HOME_BUDGET
    local pressure = "normal"
    local available_fraction

    if total then
        cover_budget = clamp(math.floor(math.min(
            total * COVER_TOTAL_FRACTION,
            available * COVER_AVAILABLE_FRACTION
        )), MIN_COVER_BUDGET, MAX_COVER_BUDGET)
        home_budget = clamp(math.floor(total * 0.01), MIN_HOME_BUDGET, MAX_HOME_BUDGET)
        available_fraction = available / total
        if available_fraction < CRITICAL_AVAILABLE_FRACTION then
            pressure = "critical"
        elseif available_fraction < LOW_AVAILABLE_FRACTION then
            pressure = "low"
        end
    end

    local render_budget = math.floor(cover_budget * 0.8)
    return {
        available_bytes = available,
        total_bytes = total,
        available_fraction = available_fraction,
        pressure = pressure,
        low_memory = total ~= nil and total <= LOW_MEMORY_TOTAL,
        cover_bytes = cover_budget,
        render_bytes = render_budget,
        decode_bytes = cover_budget - render_budget,
        home_bytes = home_budget,
    }
end

local function set_budget(cache, bytes)
    if cache and type(cache.setByteBudget) == "function" then
        cache:setByteBudget(math.max(0, math.floor(bytes)))
    end
end

local function apply_loaded_home_budget(profile, mode)
    if not (home_cache_api and type(home_cache_api.setCoverCacheBudget) == "function") then return end
    local budget = profile.home_bytes
    if mode == "reader" then
        budget = 0
    elseif profile.pressure == "critical" then
        budget = math.floor(budget / 2)
    end
    home_cache_api.setCoverCacheBudget(budget)
end

function M.registerHomeCache(api)
    home_cache_api = api
end

function M.applyCoverBudgets(render_cache, decode_cache, profile)
    profile = profile or M.getProfile()
    local factor = profile.pressure == "critical" and 0.5 or 1
    set_budget(render_cache, profile.render_bytes * factor)
    set_budget(decode_cache, profile.decode_bytes * factor)
    apply_loaded_home_budget(profile)
    if profile.pressure == "critical" and last_pressure ~= "critical" then
        collectgarbage()
        collectgarbage()
    end
    last_pressure = profile.pressure
    return profile
end

function M.homeByteBudget(profile)
    profile = profile or M.getProfile()
    if profile.pressure == "critical" then
        return math.floor(profile.home_bytes / 2)
    end
    return profile.home_bytes
end

function M.canPreload(profile)
    profile = profile or M.getProfile()
    return profile.pressure == "normal"
end

function M.canPrewarmGroups(profile)
    profile = profile or M.getProfile()
    return profile.pressure == "normal" and not profile.low_memory
end

function M.limitGroupCache(profile)
    profile = profile or M.getProfile()
    return profile.low_memory or profile.pressure ~= "normal"
end

function M.bitmapBytes(bb)
    if not bb then return 0 end
    local ok, bytes = pcall(function()
        local height = (bb.getHeight and bb:getHeight()) or tonumber(bb.h) or 0
        local stride = tonumber(bb.stride)
        if stride then return stride * height end
        local width = (bb.getWidth and bb:getWidth()) or tonumber(bb.w) or 0
        local bpp = (bb.getBpp and bb:getBpp()) or 8
        return width * height * math.ceil(bpp / 8)
    end)
    return ok and math.max(0, tonumber(bytes) or 0) or 0
end

function M.releaseForReader()
    local profile = M.getProfile()
    local render_cache = package.loaded["common/cover_render_cache"]
    local decode_cache = package.loaded["common/cover_decode_cache"]
    set_budget(render_cache, math.floor(profile.render_bytes / 4))
    set_budget(decode_cache, 0)
    apply_loaded_home_budget(profile, "reader")

    if M.limitGroupCache(profile) then
        local db_bookinfo = package.loaded["common/db_bookinfo"]
        if db_bookinfo and type(db_bookinfo.invalidate) == "function" then
            db_bookinfo.invalidate()
        end
    end

    collectgarbage()
    collectgarbage()
end

return M
