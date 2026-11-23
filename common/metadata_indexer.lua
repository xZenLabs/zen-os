-- Indexes library books missing from CoverBrowser's cache. Stock only extracts the
-- pages listed in the file browser, so metadata tabs never see books added while
-- the Library tab goes unused.
local UIManager = require("ui/uimanager")
local paths = require("common/paths")
local logger = require("common/zen_logger").new("metadata_indexer")

local M = {}

local START_DELAY_S = 1 -- after the opening view's first paint; skips quick tab hops
local POLL_S = 1
local BATCH_SIZE = 8 -- page covers queue behind the running batch, so keep it short
local REFRESH_EVERY = 48 -- books between view refreshes on a large backlog
local MAX_PASSES = 4 -- upstream gives up on a book after 3 failed tries

local run

local function missing_books(manager)
    manager:openDbConnection()
    local rows = manager.db_conn:exec(
        "SELECT directory || filename FROM bookinfo WHERE in_progress = 0")
    local indexed = {}
    for _i, path in ipairs(rows and rows[1] or {}) do
        indexed[paths.normPath(path)] = true
    end
    local missing = {}
    for _i, path in ipairs(require("common/tbr_index").getInventoryPaths()) do
        if not indexed[paths.normPath(path)] then
            missing[#missing + 1] = { filepath = path } -- no cover_specs: metadata only
        end
    end
    return missing
end

local function refresh(state)
    if state.unrefreshed == 0 then return end
    state.unrefreshed = 0
    state.on_indexed()
end

local function finish(state)
    run = nil
    refresh(state)
end

local function step()
    local state = run
    if not state then return end
    if not state.is_wanted() then
        run = nil
        return
    end
    local manager = state.manager
    -- Never launch over a running batch: upstream would kill it, ZenOS would queue us
    -- in place of the visible page's covers.
    if manager:isExtractingInBackground() then
        UIManager:scheduleIn(POLL_S, step)
        return
    end
    if #state.queue == 0 then
        if state.passes == MAX_PASSES then return finish(state) end
        state.passes = state.passes + 1
        -- Re-read after each pass: a crashed subprocess skips the rest of its batch.
        local ok, missing = pcall(missing_books, manager)
        if not ok then
            logger.warn("missing-book query failed:", missing)
            return finish(state)
        end
        if #missing == 0 then return finish(state) end
        state.queue = missing
    elseif state.unrefreshed >= REFRESH_EVERY then
        refresh(state)
    end
    local batch = {}
    for _i = 1, math.min(BATCH_SIZE, #state.queue) do
        batch[#batch + 1] = table.remove(state.queue)
    end
    if not manager:extractInBackground(batch) then return finish(state) end
    state.unrefreshed = state.unrefreshed + #batch
    UIManager:scheduleIn(POLL_S, step)
end

-- is_wanted() gates every batch; on_indexed() runs once new books are in the cache.
function M.start(is_wanted, on_indexed)
    if run then
        run.is_wanted, run.on_indexed = is_wanted, on_indexed
        return
    end
    local ok, manager = pcall(require, "bookinfomanager")
    if not ok or type(manager.extractInBackground) ~= "function" then return end
    local state = {
        manager = manager,
        is_wanted = is_wanted,
        on_indexed = on_indexed,
        queue = {},
        passes = 0,
        unrefreshed = 0,
    }
    run = state
    UIManager:scheduleIn(START_DELAY_S, function()
        if run ~= state then return end
        if not state.is_wanted() then
            run = nil
            return
        end
        -- Reuses the TBR inventory; a first scan runs in slices.
        require("common/tbr_index").scheduleAudit(nil, function()
            if run == state then step() end
        end)
    end)
end

return M
