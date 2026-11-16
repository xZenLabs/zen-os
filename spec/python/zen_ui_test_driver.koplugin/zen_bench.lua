-- In-process benchmark harness. Mirrors the kindle_benchmark measurement contract
-- (github.com/d1-m4ss/kindle_benchmark, SCENARIOS.md); raw samples only, Python aggregates.
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local PluginLoader = require("pluginloader")
local ffi = require("ffi")
local ffiUtil = require("ffi/util")
local rapidjson = require("rapidjson")
local time = require("ui/time")
local Screen = require("device").screen

pcall(ffi.cdef, [[
    struct zen_bench_rusage {
        struct { long tv_sec; int tv_usec; } ru_utime;
        struct { long tv_sec; int tv_usec; } ru_stime;
        long ru_maxrss; long ru_ixrss; long ru_idrss; long ru_isrss;
        long ru_minflt; long ru_majflt; long ru_nswap; long ru_inblock;
        long ru_oublock; long ru_msgsnd; long ru_msgrcv; long ru_nsignals;
        long ru_nvcsw; long ru_nivcsw;
    };
    int getrusage(int who, struct zen_bench_rusage *usage);
]])

local env = os.getenv
local SETTLE = tonumber(env("ZEN_UI_BENCH_SETTLE")) or 2
local WARMUPS = tonumber(env("ZEN_UI_BENCH_WARMUP")) or 2
local MEASURES = tonumber(env("ZEN_UI_BENCH_MEASURE")) or 10
local PAGING_CAP = 30

local function ms(delta) return time.to_us(delta) / 1000.0 end
local function realpath(path) return path and ffiUtil.realpath(path) or path end
local function shown(widget) return widget ~= nil and UIManager:isWidgetShown(widget) end

local function top_widget()
    local stack = UIManager._window_stack or {}
    local entry = stack[#stack]
    return entry and (entry.widget or entry)
end

local function on_stack(widget)
    for _i, entry in ipairs(UIManager._window_stack or {}) do
        if (entry.widget or entry) == widget then return true end
    end
    return false
end

local function memory(force_gc)
    local natural = collectgarbage("count")
    if force_gc then collectgarbage("collect") end
    local usage = ffi.new("struct zen_bench_rusage")
    ffi.C.getrusage(0, usage)
    return {
        natural_lua_heap_kb = natural,
        forced_gc_live_heap_kb = collectgarbage("count"),
        rss_peak_kib = tonumber(usage.ru_maxrss) / (jit.os == "OSX" and 1024 or 1),
    }
end

local function marker(name)
    io.stdout:write("\n[" .. name .. "]\n")
    io.stdout:flush()
end

-- ZenOS adapter -------------------------------------------------------------

local function filemanager()
    local FM = require("apps/filemanager/filemanager").instance
    return FM, FM and FM.file_chooser
end

local function zen_plugin()
    return PluginLoader:getPluginInstance("zenos") or PluginLoader:getPluginInstance("zen_ui")
end

local function zen_home()
    local plugin = zen_plugin()
    return plugin and require("common/shared_state").get(plugin, "home")
end

local function home_on_top()
    local home = zen_home()
    return home ~= nil and type(home.isActiveOnTop) == "function" and home.isActiveOnTop() == true
end

local function open_tab(id)
    local open = rawget(_G, "__ZEN_UI_NAVBAR_OPEN_TAB")
    if type(open) ~= "function" then error("ZenOS navbar open_tab unavailable") end
    open(id)
end

local function page_info(chooser)
    if not chooser or type(chooser.item_table) ~= "table" then return nil end
    local page = tonumber(chooser.page) or 1
    local perpage = tonumber(chooser.perpage) or #chooser.item_table
    if perpage < 1 then perpage = #chooser.item_table end
    local first = (page - 1) * perpage + 1
    local parts = {}
    for i = first, math.min(#chooser.item_table, first + perpage - 1) do
        local item = chooser.item_table[i]
        parts[#parts + 1] = tostring(type(item) == "table" and (item.path or item.file or item.text) or i)
    end
    return {
        page = page,
        total_pages = tonumber(chooser.page_num) or 1,
        per_page = perpage,
        visible_count = #parts,
        signature = table.concat(parts, "\31"),
    }
end

local function ok(details)
    details = details or {}
    details.success = true
    return details
end
local function fail(reason) return { success = false, reason = reason } end
local function unsupported(reason) return { success = false, unsupported = true, reason = reason } end
local function deferred(verify) return { pending = true, verify = verify } end

local Adapter = {}
Adapter.__index = Adapter

function Adapter:new(root)
    return setmetatable({ root = realpath(root) }, self)
end

function Adapter:on_library(path)
    local fm, chooser = filemanager()
    local top = top_widget()
    return fm ~= nil and shown(fm) and (top == fm or top == fm.show_parent) and not home_on_top()
        and chooser ~= nil and realpath(chooser.path) == (path or self.root)
end

-- Ensure the library is on top at root without a rebuild the action did not ask for.
function Adapter:ensure_library()
    if self:on_library() then return end
    if zen_plugin() then open_tab("books") end
    local fm, chooser = filemanager()
    if fm and chooser and realpath(chooser.path) ~= self.root then fm:reinit(self.root) end
end

function Adapter:startup_ready()
    if home_on_top() then return ok({ screen = "zen_home" }) end
    local fm = filemanager()
    if shown(fm) then return ok({ screen = "filemanager" }) end
    return fail("ZenOS startup UI is not active on top")
end

function Adapter:start_to_home()
    if not zen_plugin() then return unsupported("Stock KOReader has no Home screen") end
    if home_on_top() then return fail("Already at ZenOS home") end
    open_tab("home")
    return deferred(function()
        return home_on_top() and ok({ expected_refresh = true }) or fail("ZenOS home is not active on top")
    end)
end

function Adapter:library_verify(extra)
    local fm, chooser = filemanager()
    local info = page_info(chooser)
    if shown(fm) and chooser and realpath(chooser.path) == self.root and info and info.visible_count > 0 then
        local out = extra or {}
        out.expected_refresh = true
        out.visible_count_after = info.visible_count
        out.total_pages = info.total_pages
        return ok(out)
    end
    return fail("Library is not visible at the target root with loaded items")
end

function Adapter:home_to_library()
    if not zen_plugin() then
        filemanager():reinit(self.root)
        return deferred(function() return self:library_verify() end)
    end
    if self:on_library() then return fail("Already at ZenOS library") end
    open_tab("books")
    local fm, chooser = filemanager()
    if fm and chooser and realpath(chooser.path) ~= self.root then fm:reinit(self.root) end
    return deferred(function() return self:library_verify() end)
end

function Adapter:library_first_render()
    self:ensure_library()
    filemanager():reinit(self.root)
    return deferred(function() return self:library_verify() end)
end

function Adapter:goto_page(page)
    local _fm, chooser = filemanager()
    if not chooser then return false end
    chooser:onGotoPage(page)
    return true
end

function Adapter:page_info()
    local _fm, chooser = filemanager()
    return page_info(chooser)
end

function Adapter:page_transition(from_page, to_page)
    local fm, chooser = filemanager()
    local before = page_info(chooser)
    if not before then return fail("FileChooser is unavailable") end
    if before.page ~= from_page then
        return fail(("Precondition failed: page %d ~= %d"):format(before.page, from_page))
    end
    if math.abs(to_page - from_page) ~= 1 then return fail("Transition must move exactly one page") end
    if to_page < 1 or to_page > before.total_pages then
        return unsupported("Transition would wrap past the library bounds")
    end
    if before.visible_count == 0 then return fail("Precondition failed: empty page") end
    if to_page > from_page then chooser:onNextPage() else chooser:onPrevPage() end
    return deferred(function()
        local fm_after, chooser_after = filemanager()
        local after = page_info(chooser_after)
        if not after or not shown(fm_after) then return fail("Library not visible after page turn") end
        if after.page ~= to_page then
            return fail(("Page mismatch: got %d, expected %d"):format(after.page, to_page))
        end
        if after.visible_count == 0 then return fail("Postcondition failed: empty page") end
        if after.signature == before.signature then return fail("Visible signature did not change") end
        return ok({
            page_before = before.page, page_after = after.page,
            visible_count_before = before.visible_count, visible_count_after = after.visible_count,
            total_pages = after.total_pages, top_widget = tostring(top_widget() and top_widget().name),
            measured_widget_on_stack = on_stack(fm), expected_refresh = true,
        })
    end)
end

function Adapter:change_path(path)
    local _fm, chooser = filemanager()
    if not chooser then return fail("FileChooser is unavailable") end
    chooser:changeToPath(path)
    return deferred(function()
        local fm_after, chooser_after = filemanager()
        if shown(fm_after) and chooser_after and realpath(chooser_after.path) == realpath(path)
                and type(chooser_after.item_table) == "table" then
            return ok({ path = path, expected_refresh = true })
        end
        return fail("Library path postcondition failed for " .. tostring(path))
    end)
end

function Adapter:folder_enter(folder)
    if not folder then return unsupported("No deterministic subfolder exists") end
    self:ensure_library()
    return self:change_path(folder)
end

function Adapter:folder_back()
    return self:change_path(self.root)
end

function Adapter:change_sort_mode()
    self:ensure_library()
    local fm, chooser = filemanager()
    local before_mode = G_reader_settings:readSetting("collate", "strcoll")
    local before = page_info(chooser)
    local after_mode = before_mode == "size" and "strcoll" or "size"
    fm:onSetSortBy(after_mode)
    fm:onSetReverseSorting(not G_reader_settings:isTrue("reverse_collate"))
    return deferred(function()
        local fm_after, chooser_after = filemanager()
        local after = page_info(chooser_after)
        if shown(fm_after) and G_reader_settings:readSetting("collate") == after_mode and after
                and (after.signature ~= before.signature or #chooser_after.item_table <= 1
                    or not before.signature:find("%.epub")) then
            return ok({ sort_before = before_mode, sort_after = after_mode, expected_refresh = true })
        end
        return fail("Sort setting or visible order did not change")
    end)
end

function Adapter:open_book(path)
    if not path then return unsupported("Deterministic target book is missing") end
    local ReaderUI = require("apps/reader/readerui")
    ReaderUI:showReader(path)
    return deferred(function()
        local reader = ReaderUI.instance
        if shown(reader) and reader.document and reader.view
                and realpath(reader.document.file) == realpath(path) then
            return ok({ expected_refresh = true })
        end
        return fail("Target ReaderUI is not active")
    end)
end

function Adapter:close_book()
    local ReaderUI = require("apps/reader/readerui")
    if not shown(ReaderUI.instance) then return fail("No active ReaderUI") end
    ReaderUI.instance:onHome()
    return deferred(function()
        local top = top_widget()
        if ReaderUI.instance == nil and shown(top) then return ok({ expected_refresh = true }) end
        return fail("Reader did not close back to the library")
    end)
end

local function reader_page()
    local reader = require("apps/reader/readerui").instance
    local state = reader and reader.view and reader.view.state
    return reader, state and state.page or (reader and reader.document and reader.document:getCurrentPage())
end

function Adapter:reader_page_turn()
    local reader, before = reader_page()
    if not reader or not reader.document then return fail("ReaderUI is not active") end
    local navigator = reader.paging or reader.rolling
    if not (navigator and navigator.onGotoViewRel) then return unsupported("Relative page turn unavailable") end
    navigator:onGotoViewRel(1)
    return deferred(function()
        local active, after = reader_page()
        if active == reader and before ~= nil and after ~= nil and after ~= before then
            return ok({ page_before = before, page_after = after, expected_refresh = true })
        end
        return fail("Reader page did not change")
    end)
end

local function quick_settings_container()
    local fm = filemanager()
    return fm and fm.menu and fm.menu.menu_container
end

function Adapter:open_quick_settings()
    self:ensure_library()
    local fm = filemanager()
    if not (fm and fm.menu) then return unsupported("FileManager menu unavailable") end
    fm.menu:onShowMenu()
    return deferred(function()
        local container = quick_settings_container()
        return container and shown(container) and top_widget() == container
            and ok({ expected_refresh = true }) or fail("Quick settings is not the top widget")
    end)
end

function Adapter:close_quick_settings()
    local container = quick_settings_container()
    if not container then return fail("No quick settings to close") end
    filemanager().menu:onCloseFileManagerMenu()
    return deferred(function()
        return not shown(container) and shown(filemanager())
            and ok({ expected_refresh = true }) or fail("Quick settings did not close")
    end)
end

-- Harness ---------------------------------------------------------------------

local Bench = {}

function Bench.start()
    if rawget(_G, "__ZEN_UI_BENCH_RUNNING") then return end
    rawset(_G, "__ZEN_UI_BENCH_RUNNING", true)
    local init_fts = time.monotonic()
    local runner = coroutine.create(function() Bench.run(init_fts) end)
    local function step()
        local resumed, err = coroutine.resume(runner)
        if not resumed then
            io.stderr:write("zen_bench failed: " .. tostring(err) .. "\n")
            marker("BENCHMARK_FAILED")
            UIManager:quit(1)
        elseif coroutine.status(runner) ~= "dead" then
            UIManager:nextTick(step)
        end
    end
    UIManager:nextTick(step)
end

local function settle(ticks)
    for _i = 1, ticks or SETTLE do coroutine.yield() end
end

local function read_targets()
    local path = env("ZEN_UI_BENCH_TARGETS")
    local file = path and io.open(path, "r")
    if not file then return {} end
    local decoded = rapidjson.decode(file:read("*a"))
    file:close()
    return decoded or {}
end

-- Wraps refresh entry points; captures only while `rec.active`.
local function install_recorder()
    local rec = { active = false }
    function rec.reset()
        rec.set_dirty_calls, rec.refresh_count, rec.full, rec.partial = 0, 0, 0, 0
        rec.requests, rec.actual = {}, {}
    end
    rec.reset()
    local function record(x, y, w, h, kind, full)
        rec.refresh_count = rec.refresh_count + 1
        if full then rec.full = rec.full + 1 else rec.partial = rec.partial + 1 end
        rec.requests[#rec.requests + 1] = { x, y, w, h, kind, full }
    end
    local set_dirty = UIManager.setDirty
    UIManager.setDirty = function(manager, widget, refresh_type, region, dither)
        if rec.active then
            rec.set_dirty_calls = rec.set_dirty_calls + 1
            local full = region == nil or refresh_type == "full"
            local r = region or {}
            record(r.x or 0, r.y or 0, r.w or Screen:getWidth(), r.h or Screen:getHeight(),
                type(refresh_type) == "string" and refresh_type or "deferred", full)
        end
        return set_dirty(manager, widget, refresh_type, region, dither)
    end
    local refresh_ui = Screen.refreshUI
    if type(refresh_ui) == "function" then
        Screen.refreshUI = function(screen, x, y, w, h, ...)
            if rec.active then
                record(x or 0, y or 0, w or screen:getWidth(), h or screen:getHeight(), "direct_refresh", x == nil)
            end
            return refresh_ui(screen, x, y, w, h, ...)
        end
    end
    local refresh_full_imp = Screen.refreshFullImp
    if type(refresh_full_imp) == "function" then
        Screen.refreshFullImp = function(screen, x, y, w, h, ...)
            if rec.active then
                local bx, by, bw, bh = (screen.full_bb or screen.bb):getBoundedRect(x, y, w, h)
                rec.actual[#rec.actual + 1] = { bx, by, bw, bh }
            end
            return refresh_full_imp(screen, x, y, w, h, ...)
        end
    end
    return rec
end

-- Timestamp of the first repaint that drew the library chooser in its final state.
local function install_paint_observer(clock)
    local repaint = UIManager._repaint
    local frames
    UIManager._repaint = function(manager, ...)
        if not frames then return repaint(manager, ...) end
        local _fm, target = filemanager()
        local own = target and rawget(target, "paintTo")
        local paint = target and target.paintTo
        local painted = false
        if paint then
            target.paintTo = function(widget, ...)
                if widget == target then painted = true end
                return paint(widget, ...)
            end
        end
        local result = { n = 0 }
        local function keep(...) result = { n = select("#", ...), ... } end
        keep(pcall(repaint, manager, ...))
        if target then target.paintTo = own end
        if not result[1] then error(result[2], 0) end
        if painted and #frames < 64 then
            local info = page_info(target)
            frames[#frames + 1] = { owner = target, page = target.page, sig = info and info.signature, at = clock() }
        end
        return unpack(result, 2, result.n)
    end
    local observer = {}
    function observer.begin() frames = {} end
    function observer.first()
        local _fm, target = filemanager()
        local info = page_info(target)
        for _i, frame in ipairs(frames or {}) do
            if frame.owner == target and frame.page == target.page and info and frame.sig == info.signature then
                return frame.at
            end
        end
    end
    function observer.stop() frames = nil end
    return observer
end

local function framebuffer_hasher()
    local loaded, Hashoir = pcall(require, "ffi/hashoir")
    if not loaded then return function() end end
    local created, hasher = pcall(Hashoir.new, Hashoir)
    if not created then return function() end end
    return function()
        local bb = Screen.bb
        if not (bb and bb.data and bb.stride and bb.h) then return nil end
        hasher:reset()
        hasher:update(bb.data, bb.stride * bb.h)
        return hasher:hexdigest()
    end
end

function Bench.run(init_fts)
    local profile = env("ZEN_UI_BENCH_PROFILE") or "warm"
    local targets = read_targets()
    local adapter = Adapter:new(env("ZEN_UI_BENCH_LIBRARY") or G_reader_settings:readSetting("home_dir"))
    local rec = install_recorder()
    local paint = install_paint_observer(time.monotonic)
    local frame_hash = framebuffer_hasher()
    local jitp = env("ZEN_UI_BENCH_JITP")
    local profiler = jitp and require("zen_bench_profiler")
    local scenario
    local results = {
        schema_version = 1,
        profile = profile,
        library_dir = adapter.root,
        settle_ticks = SETTLE,
        iterations_warmup = WARMUPS,
        iterations_measured = MEASURES,
        screen = { w = Screen:getWidth(), h = Screen:getHeight(), dpi = Screen:getDPI() },
        variant = zen_plugin() and "zenos" or "stock",
        memory_checkpoints = {},
        scenarios = {},
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }

    local function invoke(action)
        local cpu = os.clock()
        local called, result = pcall(action)
        local cpu_ms = (os.clock() - cpu) * 1000
        if not called then return fail("Action exception: " .. tostring(result)), cpu_ms end
        if type(result) == "table" and result.pending then
            settle()
            local verified, out = pcall(result.verify)
            return verified and out or fail("Verification exception: " .. tostring(out)), cpu_ms
        end
        return result, cpu_ms
    end

    local function measured(action, instrumented)
        local before = memory(false)
        rec.reset()
        rec.active = instrumented ~= false
        local t0 = time.monotonic()
        paint.begin()
        if profiler and scenario == jitp then profiler.start() end
        local result, cpu_ms = invoke(action)
        local elapsed = ms(time.monotonic() - t0)
        if profiler then profiler.stop() end
        local first_paint = paint.first()
        paint.stop()
        rec.active = false
        if type(result) ~= "table" then return { status = "FAILED", reason = "No structured result" } end
        if result.unsupported then return { status = "UNSUPPORTED", reason = result.reason } end
        if not result.success then return { status = "FAILED", reason = result.reason } end
        if result.expected_refresh and instrumented ~= false and rec.refresh_count == 0 then
            return { status = "FAILED", reason = "State changed but no natural refresh was requested" }
        end
        local after = memory(false)
        result.success, result.expected_refresh = nil, nil
        return {
            status = "PASS",
            wall_time_ms = elapsed,
            action_cpu_ms = cpu_ms,
            first_content_paint_ms = first_paint and ms(first_paint - t0) or nil,
            natural_lua_heap_kb = after.natural_lua_heap_kb,
            lua_heap_delta_kb = after.natural_lua_heap_kb - before.natural_lua_heap_kb,
            rss_peak_kib = after.rss_peak_kib,
            set_dirty_calls = rec.set_dirty_calls,
            refresh_count = rec.refresh_count,
            full_refreshes = rec.full,
            partial_refreshes = rec.partial,
            refresh_requests = rec.requests,
            actual_refreshes = rec.actual,
            framebuffer_hash = frame_hash(),
            evidence = result,
        }
    end

    local function prepare(reset)
        if reset then invoke(reset) settle(1) end
    end

    local function execute(name, action, reset, warmups, measures, instrumented)
        scenario = name
        for _i = 1, warmups or WARMUPS do
            prepare(reset)
            measured(action, instrumented)
        end
        local iterations = {}
        for _i = 1, measures or MEASURES do
            prepare(reset)
            iterations[#iterations + 1] = measured(action, instrumented)
        end
        results.scenarios[name] = { kind = "repeated", iterations = iterations }
        return iterations
    end

    local function skip(name, status, reason, extra)
        local entry = extra or {}
        entry.kind, entry.status, entry.reason, entry.iterations = entry.kind or "paging", status, reason, {}
        results.scenarios[name] = entry
    end

    local function sequential_paging(name)
        scenario = name
        adapter:goto_page(1)
        settle()
        local info = adapter:page_info()
        local total = info and info.total_pages or 1
        if total < 2 then return skip(name, "UNSUPPORTED", "Library has only one page", { total_pages = total }) end
        if info.page ~= 1 then return skip(name, "FAILED", "Could not reach page 1", { total_pages = total }) end
        local requested = math.min(PAGING_CAP, total - 1)
        local iterations = {}
        for from = 1, requested do
            local iteration = measured(function() return adapter:page_transition(from, from + 1) end)
            iterations[#iterations + 1] = iteration
            if iteration.status ~= "PASS" then break end
        end
        results.scenarios[name] = {
            kind = "paging", iterations = iterations, total_pages = total,
            requested_transitions = requested, per_page = info.per_page,
        }
    end

    local function cached_paging(name)
        scenario = name
        adapter:goto_page(1)
        settle()
        local info = adapter:page_info()
        local total = info and info.total_pages or 1
        if total < 2 then return skip(name, "UNSUPPORTED", "Library has fewer than 2 pages", { total_pages = total }) end
        for _i, step in ipairs({ { 1, 2 }, { 2, 1 } }) do
            local warm = invoke(function() return adapter:page_transition(step[1], step[2]) end)
            settle(1)
            if not warm.success then
                return skip(name, "FAILED", "Cached paging warm-up failed: " .. tostring(warm.reason))
            end
        end
        local iterations = {}
        for index = 1, PAGING_CAP do
            local from = index % 2 == 1 and 1 or 2
            local iteration = measured(function() return adapter:page_transition(from, 3 - from) end)
            iterations[#iterations + 1] = iteration
            if iteration.status ~= "PASS" then break end
        end
        results.scenarios[name] = {
            kind = "paging", iterations = iterations, total_pages = total,
            requested_transitions = PAGING_CAP, per_page = info.per_page,
        }
    end

    local function repeated_nav()
        local transitions = 10
        adapter:goto_page(1)
        settle()
        execute("repeated_nav", function()
            for _i = 1, transitions / 2 do
                for _j, step in ipairs({ { 1, 2 }, { 2, 1 } }) do
                    local result = invoke(function() return adapter:page_transition(step[1], step[2]) end)
                    if not result.success then return result end
                end
            end
            return ok({ transitions = transitions, expected_refresh = true })
        end, function() return adapter:goto_page(1) end, 1, 2)
    end

    -- Paging runs in the library root unless it is too small and a fuller leaf exists.
    local function in_paging_root(fn)
        local leaf = targets.paging_root
        if leaf then
            adapter:ensure_library()
            invoke(function() return adapter:change_path(leaf) end)
            settle()
        end
        fn()
        if leaf then
            invoke(function() return adapter:folder_back() end)
            settle()
        end
    end

    local function rotating(list)
        local index = 0
        return function()
            if #list == 0 then return nil end
            index = index % #list + 1
            return list[index]
        end
    end
    local next_book = rotating(targets.books or {})
    local next_folder = rotating(targets.folders or {})

    -- Startup readiness: the usual settle, then at most two more ticks.
    settle()
    local ready = adapter:startup_ready()
    for _i = 1, 2 do
        if ready.success then break end
        settle(1)
        ready = adapter:startup_ready()
    end
    results.startup_ready = ready
    if ready.success then
        results.internal_harness_to_ui_ready_ms = ms(time.monotonic() - init_fts)
        marker("BENCHMARK_UI_READY")
        if profiler then profiler.stop() end
    end
    results.memory_checkpoints.post_init_idle = memory(true)

    if not ready.success then
        results.run_status, results.failure_reason = "FAILED", "Startup UI readiness failed"
    elseif profile == "startup" then
        execute("home_to_library", function() return adapter:home_to_library() end, nil, 0, 1)
        local render = execute("library_first_render", function() return adapter:library_first_render() end, nil, 0, 1)
        if render[1].status == "PASS" then marker("BENCHMARK_LIBRARY_READY") end
        results.memory_checkpoints.post_library_render_idle = memory(true)
        results.run_status = render[1].status == "PASS" and "PASS" or "FAILED"
    else
        execute("start_to_home", function() return adapter:start_to_home() end,
            function() return adapter:home_to_library() end)
        execute("home_to_library", function() return adapter:home_to_library() end,
            function() return adapter:start_to_home() end)
        local render = execute("library_first_render", function() return adapter:library_first_render() end)
        if render[#render].status == "PASS" then marker("BENCHMARK_LIBRARY_READY") end
        results.memory_checkpoints.post_library_render_idle = memory(true)
        results.paging_root = targets.paging_root
        in_paging_root(function()
            sequential_paging("library_sequential_paging")
            cached_paging("library_cached_paging")
        end)
        if (targets.folders or {})[1] then
            local folder
            execute("library_folder_enter", function() return adapter:folder_enter(folder) end,
                function() folder = next_folder() return adapter:folder_back() end)
            execute("library_folder_back", function() return adapter:folder_back() end,
                function() return adapter:folder_enter(next_folder()) end)
        else
            for _i, name in ipairs({ "library_folder_enter", "library_folder_back" }) do
                skip(name, "UNSUPPORTED", "Corpus has no subfolder", { kind = "repeated" })
            end
        end
        execute("change_sort_mode", function() return adapter:change_sort_mode() end)
        if (targets.books or {})[1] then
            local book
            local function pick() book = next_book() end
            local function close() return adapter:close_book() end
            execute("open_book_minimal", function() return adapter:open_book(book) end,
                function() pick() return close() end, nil, nil, false)
            execute("open_book", function() return adapter:open_book(book) end,
                function() pick() return close() end)
            if targets.reader_book then
                execute("reader_page_turn", function() return adapter:reader_page_turn() end,
                    function()
                        local reader = require("apps/reader/readerui").instance
                        if reader and reader.document and realpath(reader.document.file) == realpath(targets.reader_book) then
                            return
                        end
                        if reader then invoke(close) settle(1) end
                        return adapter:open_book(targets.reader_book)
                    end, 0)
            end
            execute("close_book", close, function() return adapter:open_book(next_book()) end)
        end
        execute("open_quick_settings", function() return adapter:open_quick_settings() end,
            function() return adapter:close_quick_settings() end)
        execute("close_quick_settings", function() return adapter:close_quick_settings() end,
            function() return adapter:open_quick_settings() end)
        in_paging_root(repeated_nav)
        results.memory_checkpoints.post_stress_idle = memory(true)
        results.run_status = "PASS"
    end

    local output = env("ZEN_UI_BENCH_OUTPUT")
    if output then
        local file = assert(io.open(output, "w"))
        file:write(rapidjson.encode(results))
        file:close()
    end
    if profiler and output then profiler.write(output .. ".folded") end
    marker("BENCHMARK_COMPLETE")
    UIManager:broadcastEvent(Event:new("Close"))
    UIManager:nextTick(function() UIManager:quit() end)
end

return Bench
