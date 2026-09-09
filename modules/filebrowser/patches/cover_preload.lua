-- Measure cover-page work and warm adjacent pages in bounded idle chunks.
local function apply_cover_preload()
    local CoverMenu = require("covermenu")
    if CoverMenu.__zen_cover_preload_patched then return end
    CoverMenu.__zen_cover_preload_patched = true

    local BookInfoManager = require("bookinfomanager")
    local Device = require("device")
    local FileChooser = require("ui/widget/filechooser")
    local Geom = require("ui/geometry")
    local Menu = require("ui/widget/menu")
    local UIManager = require("ui/uimanager")
    local book_status = require("common/book_status")
    local cache = require("common/cover_decode_cache")
    local render_cache = require("common/cover_render_cache")
    local memory_policy = require("common/memory_policy")
    local CoverUtils = require("common/cover_utils")
    local FolderCoverFiles = require("common/folder_cover_files")
    local FolderCover = require("modules/filebrowser/folder_cover")
    local zen_logger = require("common/zen_logger")
    local logger = zen_logger.new("cover_preload")
    local now = zen_logger.now
    local ok_dbg, dbg = pcall(require, "dbg")
    local measurements_enabled = ok_dbg and dbg and dbg.is_on == true

    memory_policy.applyCoverBudgets(render_cache, cache)

    local PRELOAD_DELAY_S = 0.35
    local PRELOAD_TICK_S = 0.05
    local PRELOAD_CHUNK = 4
    local PRELOAD_BUDGET_S = 0.03
    local PRELOAD_LOOKAHEAD_PAGES = 1
    local STATUS_PRELOAD_DELAY_S = 0.05
    local STATUS_PRELOAD_CHUNK = 4
    local STATUS_PRELOAD_BUDGET_S = 0.015
    local PAGE_WARM_MAX_FILES = tonumber(CoverUtils.MAX_FILES_PER_PAGE) or 12
    local PAGE_WARM_CPU_BUDGET_S = 0.2
    local PAGE_WARM_COOLDOWN_S = 0.25
    local HIDDEN_FOLDER_PREWARM_RETRY_S = 0.5
    local HIDDEN_FOLDER_PREWARM_MAX_RETRIES = 6
    local HYDRATE_CHUNK = 4
    local HYDRATE_BUDGET_S = 0.04
    local COVER_POLL_S = 0.4
    local COVER_POLL_SETTLE_LIMIT = 5
    local EXTRACTION_DEBOUNCE_S = 0.15

    local function get_upvalue(fn, name)
        if type(fn) ~= "function" then return nil end
        for index = 1, 128 do
            local upvalue_name, value = debug.getupvalue(fn, index)
            if not upvalue_name then break end
            if upvalue_name == name then return value end
        end
    end

    -- Keep page-build and tile-paint timing separate: page updates include the
    -- former, while e-ink refresh traces make the latter visible to the user.
    local function install_tile_measurements()
        local ok, MosaicMenu = pcall(require, "mosaicmenu")
        if not ok then return end
        local stock_item = get_upvalue(MosaicMenu._updateItemsBuildUI, "MosaicMenuItem")
        local zen_item = MosaicMenu._zen_mosaic_item_class
        local function patch_item(MosaicMenuItem)
            if not MosaicMenuItem or MosaicMenuItem._zen_cover_measure_patched then return end
            MosaicMenuItem._zen_cover_measure_patched = true

            local original_update = MosaicMenuItem.update
            function MosaicMenuItem:update(...)
                local measure = self.menu and self.menu._zen_cover_build_measure
                if not measure then return original_update(self, ...) end
                local started_at = now()
                local result = original_update(self, ...)
                measure.tile_count = measure.tile_count + 1
                measure.tile_ms = measure.tile_ms + (now() - started_at) * 1000
                return result
            end

            local original_paintTo = MosaicMenuItem.paintTo
            function MosaicMenuItem:paintTo(bb, x, y)
                local measure = self.menu and self.menu._zen_cover_paint_measure
                if not measure then return original_paintTo(self, bb, x, y) end
                local started_at = now()
                local result = original_paintTo(self, bb, x, y)
                measure.tile_count = measure.tile_count + 1
                measure.tile_ms = measure.tile_ms + (now() - started_at) * 1000
                if not measure.first_logged then
                    measure.first_logged = true
                    local input_to_first_tile_ms = measure.input_started_at
                        and (now() - measure.input_started_at) * 1000 or 0
                    logger.measure("Cover first tile painted", measure.tile_ms,
                        "page=", measure.page,
                        "has_cover=", self._has_cover_image == true,
                        "page_turn_direction=", measure.direction or "none",
                        "input_to_first_tile_ms=",
                            math.floor(input_to_first_tile_ms * 10 + 0.5) / 10)
                end
                if not measure.logged and measure.tile_count >= measure.expected then
                    measure.logged = true
                    local input_to_last_tile_ms = measure.input_started_at
                        and (now() - measure.input_started_at) * 1000 or 0
                    logger.measure("Cover page painted", measure.tile_ms,
                        "page=", measure.page,
                        "tiles=", measure.tile_count,
                        "wall_ms=", math.floor((now() - measure.started_at) * 1000 + 0.5),
                        "page_turn_direction=", measure.direction or "none",
                        "input_to_last_tile_ms=", math.floor(input_to_last_tile_ms * 10 + 0.5) / 10)
                end
                return result
            end
        end
        patch_item(stock_item)
        patch_item(zen_item)
    end

    if measurements_enabled then install_tile_measurements() end

    local function delta(after, before, key)
        return (after[key] or 0) - (before[key] or 0)
    end

    local function is_extracting()
        return type(BookInfoManager.isExtractingInBackground) == "function"
            and BookInfoManager:isExtractingInBackground()
    end

    local function hidden_home_bootstrap(menu)
        return rawget(_G, "__ZEN_UI_HIDDEN_HOME_BOOTSTRAP") == true
            or (menu and menu._zen_hidden_home_startup == true)
            or (menu and menu.show_parent
                and menu.show_parent._zen_hidden_home_startup == true)
    end

    local function home_covers_filemanager(menu)
        local parent = menu and menu.show_parent
        if parent and parent.invisible == true then return true end
        local stack = UIManager._window_stack
        if not parent or type(stack) ~= "table" then return false end
        local parent_index
        for index = 1, #stack do
            local widget = stack[index] and stack[index].widget
            if widget == parent or widget == menu then parent_index = index end
        end
        if not parent_index then return false end
        for index = parent_index + 1, #stack do
            local widget = stack[index] and stack[index].widget
            if widget and (widget.name == "home"
                    or widget._zen_navbar_tab_id == "home"
                    or widget._zen_home_show_status_bar ~= nil) then
                return true
            end
        end
        return false
    end

    local function fullscreen_overlay_covers_filemanager(menu)
        local parent = menu and menu.show_parent
        local stack = UIManager._window_stack
        if not parent or type(stack) ~= "table" then return false end
        local parent_index
        for index = 1, #stack do
            local widget = stack[index] and stack[index].widget
            if widget == parent or widget == menu then parent_index = index end
        end
        if not parent_index then return false end
        for index = parent_index + 1, #stack do
            local widget = stack[index] and stack[index].widget
            if widget and widget.covers_fullscreen then return true end
        end
        return false
    end

    local function cover_work_block_reason(menu)
        if hidden_home_bootstrap(menu) then return "hidden_home_startup" end
        if rawget(_G, "__ZEN_UI_SUPPRESS_FILEMANAGER_COVERS") == true then
            return "covers_suppressed"
        end
        if home_covers_filemanager(menu) then return "hidden_under_home" end
    end

    -- Polling may re-cache pre-extraction metadata while the child is running.
    local function reconcile_completed_extraction()
        if is_extracting() then return false end
        local files = BookInfoManager._zen_cover_extract_active
        if type(files) ~= "table" then return false end
        BookInfoManager._zen_cover_extract_active = nil
        local ready_paths = BookInfoManager._zen_cover_extract_ready_paths or {}
        BookInfoManager._zen_cover_extract_ready_paths = nil
        local preserved = 0
        for index = 1, #files do
            local path = files[index] and files[index].filepath
            if path then
                -- The visible poll can consume a completed DB row before the
                -- subprocess watcher observes that the batch has stopped. The
                -- launch already invalidated every path, so a decoded entry now
                -- is the final cover and must survive this late reconciliation.
                if ready_paths[path] == true
                        and type(cache.has) == "function" and cache:has(path) then
                    preserved = preserved + 1
                else
                    cache:drop(path)
                    render_cache:drop(path)
                end
            end
        end
        if type(BookInfoManager.closeDbConnection) == "function" then
            BookInfoManager:closeDbConnection()
        end
        logger.measure("Cover extraction reconciled", 0,
            "files=", #files,
            "preserved=", preserved)
        return true
    end

    -- CoverBrowser kills its active subprocess whenever a new page requests
    -- covers. Keep the active batch intact and retain only the newest pending
    -- page, so fast paging cannot turn normal navigation into failed attempts.
    local function serialize_extraction()
        if BookInfoManager.__zen_cover_extraction_queue_patched
                or type(BookInfoManager.extractInBackground) ~= "function" then
            return
        end
        BookInfoManager.__zen_cover_extraction_queue_patched = true
        local original_extract = BookInfoManager.extractInBackground
        local original_terminate = BookInfoManager.terminateBackgroundJobs
        if type(BookInfoManager.subprocesses_collect_interval) == "number" then
            BookInfoManager.subprocesses_collect_interval = math.min(
                BookInfoManager.subprocesses_collect_interval,
                COVER_POLL_S
            )
        end

        local function copy_files(files)
            local copied = {}
            for index = 1, #(files or {}) do
                local item = files[index]
                if item and item.filepath then
                    copied[#copied + 1] = {
                        filepath = item.filepath,
                        cover_specs = item.cover_specs,
                    }
                end
            end
            return copied
        end

        local function watch_queue()
            if BookInfoManager._zen_cover_extract_watch then return end
            local watch
            watch = function()
                if BookInfoManager._zen_cover_extract_watch ~= watch then return end
                if is_extracting() then
                    UIManager:scheduleIn(COVER_POLL_S, watch)
                    return
                end
                reconcile_completed_extraction()
                BookInfoManager._zen_cover_extract_watch = nil
                local pending = BookInfoManager._zen_cover_extract_pending
                BookInfoManager._zen_cover_extract_pending = nil
                if not pending then return end
                logger.measure("Cover extraction dequeued", 0,
                    "files=", #pending)
                local launched = original_extract(BookInfoManager, pending)
                if launched then
                    BookInfoManager._zen_cover_extract_active = pending
                    BookInfoManager._zen_cover_extract_ready_paths = {}
                    watch_queue()
                end
            end
            BookInfoManager._zen_cover_extract_watch = watch
            UIManager:scheduleIn(COVER_POLL_S, watch)
        end

        function BookInfoManager:extractInBackground(files, ...)
            local copied = copy_files(files)
            if #copied == 0 then return original_extract(self, files, ...) end
            if is_extracting() then
                self._zen_cover_extract_pending = copied
                logger.measure("Cover extraction queued", 0,
                    "files=", #copied,
                    "replaces_pending=", 1)
                watch_queue()
                return true
            end
            reconcile_completed_extraction()
            local launched = original_extract(self, copied, ...)
            if launched then
                self._zen_cover_extract_active = copied
                self._zen_cover_extract_ready_paths = {}
                watch_queue()
            end
            return launched
        end

        if type(original_terminate) == "function" then
            function BookInfoManager:terminateBackgroundJobs(...)
                self._zen_cover_extract_pending = nil
                return original_terminate(self, ...)
            end
        end
    end

    serialize_extraction()

    local cancel_cover_page_warm
    local cancel_hidden_folder_prewarm

    local function cancel(menu)
        if menu._zen_cover_status_preload_fn then
            UIManager:unschedule(menu._zen_cover_status_preload_fn)
            menu._zen_cover_status_preload_fn = nil
        end
        menu._zen_cover_status_preload_state = nil
        menu._zen_cover_status_preload_jobs = nil
        if menu._zen_cover_preload_fn then
            UIManager:unschedule(menu._zen_cover_preload_fn)
            menu._zen_cover_preload_fn = nil
        end
        menu._zen_cover_preload_jobs = nil
    end

    local function clear_hydration_items(items)
        for _i, item in ipairs(items or {}) do
            item._zen_cover_hydration_queued = nil
            item._zen_cover_hydration_kind = nil
        end
    end

    local function next_hydration_tick(fn)
        local schedule = UIManager.tickAfterNext or UIManager.nextTick
        if type(schedule) == "function" then
            schedule(UIManager, fn)
        else
            UIManager:scheduleIn(0.001, fn)
        end
    end

    local function cancel_hydration(menu)
        if cancel_hidden_folder_prewarm then
            cancel_hidden_folder_prewarm(menu, "hydration_cancelled", "discard")
        end
        if menu._zen_cover_hydrate_fn then
            UIManager:unschedule(menu._zen_cover_hydrate_fn)
            menu._zen_cover_hydrate_fn = nil
        end
        clear_hydration_items(menu._zen_cover_hydration_active_items)
        clear_hydration_items(menu._zen_cover_hydration_items)
        clear_hydration_items(menu._zen_cover_suspended_hydration_items)
        menu._zen_cover_hydration_active_items = nil
        menu._zen_cover_hydration_items = {}
        menu._zen_cover_suspended_hydration_items = nil
        menu._zen_cover_suspended_hydration_generation = nil
        menu._zen_cover_collecting_reveal = nil
        menu._zen_cover_reveal = nil
        menu._zen_cover_pending_refresh = nil
    end

    local function suspend_hydration(menu, jobs, generation, refresh_region)
        if menu._zen_cover_hydrate_fn then
            UIManager:unschedule(menu._zen_cover_hydrate_fn)
            menu._zen_cover_hydrate_fn = nil
        end
        local suspended = menu._zen_cover_suspended_hydration_items
        if menu._zen_cover_suspended_hydration_generation ~= generation
                or type(suspended) ~= "table" then
            clear_hydration_items(suspended)
            suspended = {}
        end
        local active = jobs or menu._zen_cover_hydration_active_items or {}
        if active ~= suspended then
            for index = 1, #active do suspended[#suspended + 1] = active[index] end
        end
        local queued = menu._zen_cover_hydration_items or {}
        for index = 1, #queued do suspended[#suspended + 1] = queued[index] end
        menu._zen_cover_hydration_active_items = nil
        menu._zen_cover_hydration_items = {}
        menu._zen_cover_suspended_hydration_items = suspended
        menu._zen_cover_suspended_hydration_generation = generation
        if refresh_region then
            local pending = menu._zen_cover_pending_refresh
            menu._zen_cover_pending_refresh = pending
                and pending:combine(refresh_region) or refresh_region
        end
    end

    local function clear_suspended_extraction_launch(menu)
        local suspended = menu._zen_cover_suspended_extract_launch
        if suspended and suspended.resume_fn then
            UIManager:unschedule(suspended.resume_fn)
        end
        menu._zen_cover_suspended_extract_launch = nil
    end

    local function cancel_extraction_launch(menu)
        if menu._zen_cover_extract_delay_fn then
            UIManager:unschedule(menu._zen_cover_extract_delay_fn)
            menu._zen_cover_extract_delay_fn = nil
        end
        clear_suspended_extraction_launch(menu)
    end

    -- CoverBrowser starts its extraction from nextTick and kills any existing
    -- batch first. A swipe through several pages therefore used to kill each
    -- batch before it could finish. Delay only that launch callback, coalescing
    -- rapid page changes into one batch for the page where the user stops.
    local function defer_extraction_launch(menu, original, ...)
        local original_nextTick = UIManager.nextTick
        UIManager.nextTick = function(ui, fn, ...)
            local args = { ... }
            return original_nextTick(ui, function()
                local queued_at = now()
                if menu._zen_cover_extract_delay_fn then
                    UIManager:unschedule(menu._zen_cover_extract_delay_fn)
                end
                clear_suspended_extraction_launch(menu)
                local launch = {
                    fn = fn,
                    args = args,
                    queued_at = queued_at,
                    generation = menu._zen_cover_hydration_generation,
                }
                local delayed
                delayed = function()
                    if menu._zen_cover_extract_delay_fn ~= delayed then return end
                    menu._zen_cover_extract_delay_fn = nil
                    if menu._zen_cover_hydration_generation ~= launch.generation then
                        logger.measure("Cover extraction skipped", 0,
                            "page=", menu.page,
                            "reason=superseded")
                        return
                    end
                    local block_reason = cover_work_block_reason(menu)
                    if block_reason == "hidden_under_home" then
                        launch.suspended_at = now()
                        menu._zen_cover_suspended_extract_launch = launch
                        logger.measure("Cover extraction suspended", 0,
                            "page=", menu.page,
                            "generation=", launch.generation,
                            "debounce_ms=",
                                math.floor((launch.suspended_at - queued_at) * 1000 + 0.5),
                            "reason=hidden_under_home")
                        return
                    elseif block_reason then
                        logger.measure("Cover extraction skipped", 0,
                            "page=", menu.page,
                            "reason=" .. block_reason)
                        return
                    end
                    logger.measure("Cover extraction launched", 0,
                        "page=", menu.page,
                        "debounce_ms=", math.floor((now() - queued_at) * 1000 + 0.5))
                    fn(unpack(args))
                end
                menu._zen_cover_extract_delay_fn = delayed
                UIManager:scheduleIn(EXTRACTION_DEBOUNCE_S, delayed)
            end, ...)
        end
        local results = { pcall(original, menu, ...) }
        UIManager.nextTick = original_nextTick
        if not results[1] then error(results[2]) end
        table.remove(results, 1)
        return unpack(results)
    end

    local function resume_suspended_extraction_launch(menu, generation)
        local launch = menu._zen_cover_suspended_extract_launch
        if type(launch) ~= "table" then return false end
        if launch.generation ~= generation then
            clear_suspended_extraction_launch(menu)
            return false
        end
        if launch.resume_fn then return true end

        local resume
        resume = function()
            if menu._zen_cover_suspended_extract_launch ~= launch
                    or launch.resume_fn ~= resume then
                return
            end
            launch.resume_fn = nil
            if menu._zen_cover_hydration_generation ~= launch.generation then
                menu._zen_cover_suspended_extract_launch = nil
                logger.measure("Cover extraction skipped", 0,
                    "page=", menu.page,
                    "reason=superseded")
                return
            end
            local block_reason = cover_work_block_reason(menu)
            if block_reason == "hidden_under_home" then
                logger.measure("Cover extraction suspended", 0,
                    "page=", menu.page,
                    "generation=", launch.generation,
                    "reason=hidden_under_home")
                return
            end
            menu._zen_cover_suspended_extract_launch = nil
            if block_reason then
                logger.measure("Cover extraction skipped", 0,
                    "page=", menu.page,
                    "reason=" .. block_reason)
                return
            end
            logger.measure("Cover extraction launched", 0,
                "page=", menu.page,
                "generation=", launch.generation,
                "debounce_ms=", math.floor((now() - launch.queued_at) * 1000 + 0.5),
                "resumed=", true,
                "suspended_ms=", launch.suspended_at
                    and math.floor((now() - launch.suspended_at) * 1000 + 0.5) or 0)
            launch.fn(unpack(launch.args))
        end
        launch.resume_fn = resume
        next_hydration_tick(resume)
        return true
    end

    local function valid_region(region)
        return region and tonumber(region.w) and tonumber(region.h)
            and region.w > 0 and region.h > 0
    end

    local function copy_region(region)
        if not valid_region(region) then return nil end
        return Geom:new{
            x = tonumber(region.x) or 0,
            y = tonumber(region.y) or 0,
            w = region.w,
            h = region.h,
        }
    end

    local function grid_refresh_region(menu)
        local total = #(menu.item_table or {})
        local perpage = tonumber(menu.perpage)
        local page = tonumber(menu.page)
        if total == 0 or not perpage or perpage < 1 or not page then return nil end
        local visible = math.max(0, math.min(perpage, total - (page - 1) * perpage))
        if visible == 0 then return nil end
        local dimen = menu.dimen
        local title = menu.title_bar and menu.title_bar.dimen
        if not valid_region(dimen) then return nil end
        local x = tonumber(dimen.x) or 0
        local y = (tonumber(dimen.y) or 0) + (title and tonumber(title.h) or 0)
        local bottom = (tonumber(dimen.y) or 0) + dimen.h
        if y >= bottom then return nil end
        local height = bottom - y
        local item_height = tonumber(menu.item_height)
        local columns = math.max(1, tonumber(menu.nb_cols) or 1)
        local margin = math.max(0, tonumber(menu.item_margin) or 0)
        if item_height and item_height > 0 then
            local rows = math.ceil(visible / columns)
            height = math.min(height, rows * item_height + (rows + 1) * margin)
        elseif valid_region(menu.inner_dimen) then
            height = math.min(height, menu.inner_dimen.h)
        end
        return Geom:new{ x = x, y = y, w = dimen.w, h = height }
    end

    local function pagination_refresh_region(menu)
        if (tonumber(menu.page_num) or 1) <= 1 then return nil end
        local page_info = menu.page_info
        local page_dimen = page_info and page_info.dimen
        local region = page_dimen and tonumber(page_dimen.x) and tonumber(page_dimen.y)
            and copy_region(page_dimen) or nil
        if region then return region end
        if not (page_info and type(page_info.getSize) == "function"
                and valid_region(menu.dimen)) then
            return nil
        end
        local ok, size = pcall(page_info.getSize, page_info)
        if not ok or not valid_region(size) then return nil end
        return Geom:new{
            x = tonumber(menu.dimen.x) or 0,
            y = (tonumber(menu.dimen.y) or 0) + menu.dimen.h - size.h,
            w = menu.dimen.w,
            h = size.h,
        }
    end

    local function page_refresh_region(menu, previous_grid)
        local grid = grid_refresh_region(menu)
        local region = copy_region(previous_grid)
        if grid then region = region and region:combine(grid) or grid end
        local pagination = pagination_refresh_region(menu)
        if pagination then region = region and region:combine(pagination) or pagination end
        return region, grid
    end

    local function call_with_scoped_dirty(menu, region, reveal, fn, ...)
        local args = { ... }
        local original_setDirty = UIManager.setDirty
        local scoped = false
        UIManager.setDirty = function(ui, widget, refreshtype, refreshregion, refreshdither)
            if widget == menu.show_parent then
                if not scoped and region and type(refreshtype) == "function" then
                    scoped = true
                    local original_refresh = refreshtype
                    refreshtype = function()
                        local refresh = { original_refresh() }
                        return refresh[1], region, refresh[3]
                    end
                end
                if reveal then
                    reveal.dirty_calls[#reveal.dirty_calls + 1] = {
                        refreshtype = refreshtype,
                        refreshregion = refreshregion,
                        refreshdither = refreshdither,
                    }
                    return
                end
            end
            return original_setDirty(ui, widget, refreshtype, refreshregion, refreshdither)
        end
        local results = { pcall(fn, unpack(args)) }
        UIManager.setDirty = original_setDirty
        if not results[1] then error(results[2]) end
        table.remove(results, 1)
        return unpack(results)
    end

    local refresh_mode_priority = {
        fast = 1,
        partial = 2,
        ui = 3,
        flashui = 4,
        full = 5,
    }

    local function flush_reveal(menu, reveal, reason, hydrated, failed)
        if menu._zen_cover_reveal ~= reveal
                or menu._zen_cover_hydration_generation ~= reveal.generation then
            return false
        end
        menu._zen_cover_reveal = nil
        local refresh_mode
        local refresh_region
        local refresh_dither = false
        local full_region = false
        for _i, call in ipairs(reveal.dirty_calls) do
            local mode = call.refreshtype
            local region = call.refreshregion
            local dither = call.refreshdither
            if type(mode) == "function" then
                mode, region, dither = mode()
            end
            if not refresh_mode
                    or (refresh_mode_priority[mode] or 0)
                        > (refresh_mode_priority[refresh_mode] or 0) then
                refresh_mode = mode
            end
            if region == nil then
                full_region = true
            elseif not full_region then
                refresh_region = refresh_region and refresh_region:combine(region) or region
            end
            refresh_dither = refresh_dither or dither == true
        end
        local combined_refresh = #reveal.dirty_calls > 0 and menu.show_parent ~= nil
            and not fullscreen_overlay_covers_filemanager(menu)
        if combined_refresh then
            if hydrated > 0 then menu.show_parent.dithered = true end
            local final_region = copy_region(reveal.refresh_region)
            if not final_region and not full_region then final_region = refresh_region end
            UIManager:setDirty(menu.show_parent, function()
                return refresh_mode or "ui", final_region,
                    refresh_dither or hydrated > 0
            end)
        end
        local revealed_at = now()
        menu._zen_cover_initial_reveal_at = revealed_at
        menu._zen_cover_initial_reveal_generation = reveal.generation
        local input_to_reveal_ms = reveal.input_started_at
            and (revealed_at - reveal.input_started_at) * 1000 or 0
        logger.measure("Cover page revealed", (now() - reveal.started_at) * 1000,
            "page=", reveal.page,
            "reason=", reason,
            "queued=", reveal.queued or 0,
            "hydrated=", hydrated,
            "fallbacks=", #(menu.items_to_update or {}) + failed,
            "wall_ms=", math.floor((now() - reveal.started_at) * 1000 + 0.5),
            "input_to_reveal_submit_ms=",
                math.floor(input_to_reveal_ms * 10 + 0.5) / 10,
            "combined_refresh=", combined_refresh)
        return combined_refresh
    end

    local function item_refresh_region(item)
        local region = item and (item.refresh_dimen
            or (item[1] and item[1].dimen)
            or item.dimen)
        return copy_region(region)
    end

    local function sort_hydration_jobs(jobs)
        local ordered = {}
        for index = 1, #jobs do
            local region = item_refresh_region(jobs[index])
            ordered[index] = {
                item = jobs[index],
                index = index,
                x = region and region.x,
                y = region and region.y,
            }
        end
        table.sort(ordered, function(left, right)
            if left.y and right.y and left.y ~= right.y then return left.y < right.y end
            if left.y and not right.y then return true end
            if right.y and not left.y then return false end
            if left.x and right.x and left.x ~= right.x then return left.x < right.x end
            return left.index < right.index
        end)
        for index = 1, #ordered do jobs[index] = ordered[index].item end
    end

    local function submit_hydration_refresh(menu, generation, region, hydrated, failed)
        if not (region and menu.show_parent)
                or menu._zen_cover_hydration_generation ~= generation
                or cover_work_block_reason(menu)
                or fullscreen_overlay_covers_filemanager(menu) then
            return false
        end
        -- Extraction waves are accumulated before this point; never add a
        -- second e-ink refresh for the same visible page generation.
        if menu._zen_cover_refresh_submitted_generation == generation then
            logger.measure("Cover hydration refresh skipped", 0,
                "page=", menu.page,
                "generation=", generation,
                "reason=already_submitted")
            return false
        end
        menu._zen_cover_refresh_submitted_generation = generation
        if hydrated > 0 then menu.show_parent.dithered = true end
        local full_color_refresh = hydrated > 0
            and Device.hasColorScreen and Device:hasColorScreen()
        local refresh_region = region
        if full_color_refresh then refresh_region = nil end
        UIManager:setDirty(menu.show_parent, function()
            local refreshtype = BookInfoManager:getSetting("flash_ui_cover_images")
                and "flashui" or "ui"
            return refreshtype, refresh_region, hydrated > 0
        end)
        local full_area = menu.dimen and menu.dimen.w and menu.dimen.h
            and menu.dimen.w * menu.dimen.h or 0
        local region_pct = full_color_refresh and 100 or full_area > 0
            and math.floor(region.w * region.h * 1000 / full_area + 0.5) / 10 or 100
        local revealed_at = menu._zen_cover_initial_reveal_generation == generation
            and menu._zen_cover_initial_reveal_at or nil
        logger.measure("Cover hydration refresh submitted", 0,
            "page=", menu.page,
            "generation=", generation,
            "hydrated=", hydrated,
            "failed=", failed,
            "region_pct=", region_pct,
            "reveal_to_refresh_ms=", revealed_at
                and math.floor((now() - revealed_at) * 1000 + 0.5) or -1)
        return true
    end

    local function schedule_hydration(menu, supplied_jobs)
        if menu._zen_cover_collecting_reveal then return end
        if menu._zen_cover_hydrate_fn then return end
        local jobs = supplied_jobs or menu._zen_cover_hydration_items
        if type(jobs) ~= "table" or #jobs == 0 then
            return
        end
        if not supplied_jobs then menu._zen_cover_hydration_items = {} end
        local initial_batch = supplied_jobs ~= nil
        local generation = menu._zen_cover_hydration_generation
        local block_reason = cover_work_block_reason(menu)
        if block_reason then
            suspend_hydration(menu, jobs, generation)
            logger.measure("Cover hydration skipped", 0,
                "reason=" .. block_reason, "page=", menu.page)
            return
        end
        sort_hydration_jobs(jobs)
        local started_at = now()
        local work_ms = 0
        local hydrated = 0
        local failed = 0
        local chunks = 0
        local refresh_region
        local before = cache:stats()
        local before_render = render_cache:stats()
        local step
        step = function()
            if menu._zen_cover_hydrate_fn ~= step
                    or menu._zen_cover_hydration_generation ~= generation then
                return
            end
            local current_block_reason = cover_work_block_reason(menu)
            if current_block_reason then
                suspend_hydration(menu, jobs, generation, refresh_region)
                logger.measure("Cover hydration skipped", work_ms,
                    "reason=" .. current_block_reason, "page=", menu.page,
                    "wall_ms=", math.floor((now() - started_at) * 1000 + 0.5))
                return
            end
            if menu._zen_cover_poll_action and not initial_batch then
                UIManager:scheduleIn(COVER_POLL_S, step)
                return
            end
            local chunk_started_at = now()
            local processed = 0
            while #jobs > 0 and processed < HYDRATE_CHUNK
                    and (processed == 0 or now() - chunk_started_at < HYDRATE_BUDGET_S) do
                local item = table.remove(jobs, 1)
                processed = processed + 1
                local hydration_kind = item._zen_cover_hydration_kind
                local hydrating_folder = hydration_kind == "folder"
                item._zen_cover_hydration_queued = nil
                item._zen_cover_hydration_kind = nil
                if item.menu == menu then
                    if hydrating_folder then
                        item._zen_folder_hydrating = true
                    else
                        item._zen_cover_hydrating = true
                    end
                    local ok, hydrate_err = pcall(item.update, item)
                    item._zen_folder_hydrating = nil
                    item._zen_cover_hydrating = nil
                    if ok and item._has_cover_image then
                        hydrated = hydrated + 1
                        local region = item_refresh_region(item)
                        if region then
                            refresh_region = refresh_region
                                and refresh_region:combine(region) or region
                        end
                    else
                        failed = failed + 1
                        if not ok then
                            logger.warn("Cover hydration failed",
                                tostring(item.filepath), tostring(hydrate_err))
                        end
                    end
                end
                if hydrating_folder then break end
            end
            chunks = chunks + 1
            work_ms = work_ms + (now() - chunk_started_at) * 1000
            if #jobs > 0 then
                next_hydration_tick(step)
                return
            end
            local queued = menu._zen_cover_hydration_items or {}
            if #queued > 0 then
                menu._zen_cover_hydration_items = {}
                for index = 1, #queued do jobs[#jobs + 1] = queued[index] end
                sort_hydration_jobs(jobs)
                next_hydration_tick(step)
                return
            end
            menu._zen_cover_hydrate_fn = nil
            menu._zen_cover_hydration_active_items = nil
            local after = cache:stats()
            local after_render = render_cache:stats()
            logger.measure("Cover hydration completed", work_ms,
                "page=", menu.page,
                "hydrated=", hydrated,
                "failed=", failed,
                "chunks=", chunks,
                "full_reads=", delta(after, before, "full_reads"),
                "decode_reads=", delta(after, before, "decode_reads"),
                "render_cache_hits=", delta(after_render, before_render, "hits"),
                "render_shared_hits=", delta(after_render, before_render, "shared_hits"),
                "render_exact_copy_hits=",
                    delta(after_render, before_render, "exact_copy_hits"),
                "render_resized_hits=", delta(after_render, before_render, "resized_hits"),
                "wall_ms=", math.floor((now() - started_at) * 1000 + 0.5))
            local pending_region = copy_region(menu._zen_cover_pending_refresh)
            menu._zen_cover_pending_refresh = nil
            if pending_region then
                refresh_region = refresh_region
                    and refresh_region:combine(pending_region) or pending_region
            end
            if refresh_region and menu._zen_cover_poll_action then
                menu._zen_cover_pending_refresh = refresh_region
                logger.measure("Cover hydration refresh deferred", 0,
                    "page=", menu.page,
                    "generation=", generation,
                    "hydrated=", hydrated,
                    "failed=", failed,
                    "reason=extraction_pending")
            else
                local submitted = submit_hydration_refresh(
                    menu, generation, refresh_region, hydrated, failed)
                if not submitted and refresh_region
                        and cover_work_block_reason(menu)
                        and menu._zen_cover_hydration_generation == generation then
                    menu._zen_cover_pending_refresh = refresh_region
                end
            end
        end
        menu._zen_cover_hydration_active_items = jobs
        menu._zen_cover_hydrate_fn = step
        next_hydration_tick(step)
    end

    local function preserve_hidden_folder_jobs(menu, state)
        local jobs = state.jobs or {}
        local retry_jobs = state.retry_jobs or {}
        if menu._zen_cover_hydration_generation ~= state.generation then
            clear_hydration_items(jobs)
            clear_hydration_items(retry_jobs)
            return 0
        end
        local remaining = #jobs + #retry_jobs
        if remaining == 0 then return 0 end
        local suspended = menu._zen_cover_suspended_hydration_items
        if menu._zen_cover_suspended_hydration_generation ~= state.generation
                or type(suspended) ~= "table" then
            clear_hydration_items(suspended)
            suspended = {}
        end
        for index = 1, #jobs do suspended[#suspended + 1] = jobs[index] end
        for index = 1, #retry_jobs do suspended[#suspended + 1] = retry_jobs[index] end
        menu._zen_cover_suspended_hydration_items = suspended
        menu._zen_cover_suspended_hydration_generation = state.generation
        return remaining
    end

    local function discard_hidden_folder_jobs(menu, state)
        clear_hydration_items(state and state.jobs)
        clear_hydration_items(state and state.retry_jobs)
        clear_hydration_items(menu._zen_cover_suspended_hydration_items)
        menu._zen_cover_suspended_hydration_items = nil
        menu._zen_cover_suspended_hydration_generation = nil
        menu._zen_cover_pending_refresh = nil
    end

    cancel_hidden_folder_prewarm = function(menu, reason, mode)
        local state = menu and menu._zen_hidden_folder_prewarm_state
        if not menu then return false end
        mode = mode == "discard" and "discard" or "preserve"
        if type(state) ~= "table" then
            if mode == "discard" then discard_hidden_folder_jobs(menu) end
            return false
        end
        if state.step then UIManager:unschedule(state.step) end
        menu._zen_hidden_folder_prewarm_state = nil
        local remaining
        if mode == "discard" then
            remaining = #state.jobs + #(state.retry_jobs or {})
            discard_hidden_folder_jobs(menu, state)
        else
            remaining = preserve_hidden_folder_jobs(menu, state)
        end
        logger.measure("Hidden folder cover prewarm cancelled", state.work_s * 1000,
            "page=", menu.page,
            "jobs=", state.total,
            "processed=", state.processed,
            "remaining=", remaining,
            "warmed=", state.warmed,
            "failed=", state.failed,
            "deferrals=", state.deferrals,
            "mode=", mode,
            "reason=", reason or "cancelled",
            "wall_ms=", math.floor((now() - state.started_at) * 1000 + 0.5))
        return true
    end

    local function hidden_folder_prewarm_block_reason(menu, state)
        if menu._zen_cover_hydration_generation ~= state.generation then
            return "generation_changed"
        end
        if not hidden_home_bootstrap(menu) then return "not_hidden" end
        if Device.screen_saver_mode == true then return "screen_saver" end
        if rawget(_G, "__ZEN_UI_SUPPRESS_FILEMANAGER_COVERS") == true then
            return "covers_suppressed"
        end
        if menu.no_refresh_covers == true then return "refresh_suppressed" end
        if menu.cover_specs == false or menu._do_cover_images == false then
            return "covers_disabled"
        end
        if is_extracting() then return "background_extraction" end
        local profile = memory_policy.applyCoverBudgets(render_cache, cache)
        if not memory_policy.canPreload(profile) then
            return "memory_" .. tostring(profile.pressure)
        end
        local ok, safe = pcall(state.guard)
        if not ok or safe ~= true then return "home_not_top" end
    end

    local function retryable_hidden_folder_block(reason)
        return reason == "background_extraction" or reason == "home_not_top"
            or reason == "covers_suppressed"
            or (type(reason) == "string" and reason:sub(1, 7) == "memory_")
    end

    local function start_hidden_folder_prewarm(menu, guard)
        if type(guard) ~= "function" then return false, "guard_missing" end
        if menu._zen_cover_hydrate_fn then return false, "hydration_active" end
        if menu._zen_hidden_folder_prewarm_state then
            return false, "already_running"
        end
        local generation = menu._zen_cover_hydration_generation
        local suspended = menu._zen_cover_suspended_hydration_items
        if type(suspended) ~= "table" or #suspended == 0
                or menu._zen_cover_suspended_hydration_generation ~= generation then
            return false, "no_folder_jobs"
        end
        local jobs = {}
        local retained = {}
        for _i, item in ipairs(suspended) do
            if item._zen_cover_hydration_kind == "folder" then
                jobs[#jobs + 1] = item
            else
                retained[#retained + 1] = item
            end
        end
        if #jobs == 0 then return false, "no_folder_jobs" end
        local state = {
            generation = generation,
            guard = guard,
            jobs = jobs,
            total = #jobs,
            started_at = now(),
            work_s = 0,
            burst_work_s = 0,
            bursts = 1,
            deferrals = 0,
            processed = 0,
            warmed = 0,
            failed = 0,
            retry_jobs = {},
            suppressed_dirty = 0,
        }
        local block_reason = hidden_folder_prewarm_block_reason(menu, state)
        if block_reason and not retryable_hidden_folder_block(block_reason) then
            return false, block_reason
        end
        menu._zen_cover_suspended_hydration_items = #retained > 0 and retained or nil
        menu._zen_cover_suspended_hydration_generation = #retained > 0
            and generation or nil
        sort_hydration_jobs(jobs)

        local step
        step = function()
            if menu._zen_hidden_folder_prewarm_state ~= state then return end
            local reason = hidden_folder_prewarm_block_reason(menu, state)
            if reason then
                if retryable_hidden_folder_block(reason)
                        and state.deferrals < HIDDEN_FOLDER_PREWARM_MAX_RETRIES then
                    state.deferrals = state.deferrals + 1
                    logger.measure("Hidden folder cover prewarm deferred", state.work_s * 1000,
                        "page=", menu.page,
                        "remaining=", #jobs + #state.retry_jobs,
                        "retry=", state.deferrals,
                        "max_retries=", HIDDEN_FOLDER_PREWARM_MAX_RETRIES,
                        "reason=", reason)
                    UIManager:scheduleIn(HIDDEN_FOLDER_PREWARM_RETRY_S, step)
                else
                    local mode = reason == "generation_changed" and "discard" or "preserve"
                    cancel_hidden_folder_prewarm(menu, reason, mode)
                end
                return
            end

            local item = table.remove(jobs, 1)
            local started_at = now()
            item._zen_cover_hydration_queued = nil
            item._zen_cover_hydration_kind = nil
            local ok, hydrate_err = false, "stale item"
            if item.menu == menu then
                item._zen_folder_hydrating = true
                local original_set_dirty = UIManager.setDirty
                UIManager.setDirty = function()
                    state.suppressed_dirty = state.suppressed_dirty + 1
                end
                ok, hydrate_err = pcall(item.update, item)
                UIManager.setDirty = original_set_dirty
                item._zen_folder_hydrating = nil
            end
            local elapsed_s = now() - started_at
            state.work_s = state.work_s + elapsed_s
            state.burst_work_s = state.burst_work_s + elapsed_s
            state.processed = state.processed + 1
            if ok and item._has_cover_image then
                state.warmed = state.warmed + 1
                if menu.show_parent then menu.show_parent.dithered = true end
            else
                state.failed = state.failed + 1
                item._zen_cover_hydration_queued = true
                item._zen_cover_hydration_kind = "folder"
                state.retry_jobs[#state.retry_jobs + 1] = item
                if not ok then
                    logger.warn("Hidden folder cover prewarm failed",
                        tostring(item.filepath), tostring(hydrate_err))
                end
            end

            if #jobs == 0 then
                menu._zen_hidden_folder_prewarm_state = nil
                local unresolved = preserve_hidden_folder_jobs(menu, state)
                logger.measure("Hidden folder cover prewarm completed", state.work_s * 1000,
                    "page=", menu.page,
                    "jobs=", state.total,
                    "warmed=", state.warmed,
                    "failed=", state.failed,
                    "unresolved=", unresolved,
                    "bursts=", state.bursts,
                    "deferrals=", state.deferrals,
                    "suppressed_dirty=", state.suppressed_dirty,
                    "wall_ms=", math.floor((now() - state.started_at) * 1000 + 0.5))
            elseif state.burst_work_s >= PAGE_WARM_CPU_BUDGET_S then
                state.burst_work_s = 0
                state.bursts = state.bursts + 1
                UIManager:scheduleIn(PAGE_WARM_COOLDOWN_S, step)
            else
                UIManager:scheduleIn(PRELOAD_TICK_S, step)
            end
        end
        state.step = step
        menu._zen_hidden_folder_prewarm_state = state
        local delay = block_reason and HIDDEN_FOLDER_PREWARM_RETRY_S or PRELOAD_TICK_S
        if block_reason then state.deferrals = 1 end
        UIManager:scheduleIn(delay, step)
        logger.measure("Hidden folder cover prewarm started", 0,
            "page=", menu.page,
            "generation=", generation,
            "jobs=", state.total,
            "retained=", #retained,
            "deferred_reason=", block_reason or "none")
        return true, state.total
    end

    CoverMenu._zen_start_hidden_folder_prewarm = start_hidden_folder_prewarm
    FileChooser._zen_start_hidden_folder_prewarm = start_hidden_folder_prewarm
    CoverMenu._zen_cancel_hidden_folder_prewarm = cancel_hidden_folder_prewarm
    FileChooser._zen_cancel_hidden_folder_prewarm = cancel_hidden_folder_prewarm

    -- CoverMenu only checks its extraction batch once a second. Polling at the
    -- same initial cadence as Bookshelf makes each committed cover visible
    -- promptly, without changing extraction order or adding a second process.
    local function release_cover_poll(menu, poll)
        UIManager:unschedule(poll)
        if menu._zen_cover_poll_action ~= poll then return end
        if menu.items_update_action == poll then
            menu.items_update_action = menu._zen_cover_poll_original
        end
        menu._zen_cover_poll_action = nil
        menu._zen_cover_poll_original = nil
        menu._zen_cover_poll_generation = nil
    end

    local function accelerate_cover_poll(menu)
        if cover_work_block_reason(menu) then return end
        local original = menu.items_update_action
        local generation = menu._zen_cover_hydration_generation
        local active_poll = menu._zen_cover_poll_action
        if active_poll then
            if original == active_poll
                    and menu._zen_cover_poll_generation == generation then
                return
            end
            if original == active_poll then
                original = menu._zen_cover_poll_original
            end
            release_cover_poll(menu, active_poll)
        end
        if type(original) ~= "function" then return end

        UIManager:unschedule(original)
        local settle_polls = 0
        local poll
        poll = function()
            if menu._zen_cover_poll_action ~= poll
                    or menu.items_update_action ~= poll
                    or menu._zen_cover_hydration_generation ~= generation then
                release_cover_poll(menu, poll)
                return
            end
            local block_reason = cover_work_block_reason(menu)
            if block_reason then
                release_cover_poll(menu, poll)
                if menu._zen_cover_hydrate_fn then
                    suspend_hydration(menu, nil, generation)
                end
                logger.measure("Cover extraction poll stopped", 0,
                    "reason=" .. block_reason,
                    "page=", menu.page)
                return
            end
            local before = #(menu.items_to_update or {})
            local before_items = {}
            for index = 1, before do
                local item = menu.items_to_update[index]
                if item then before_items[item] = item_refresh_region(item) end
            end
            local started_at = now()
            if not is_extracting() then reconcile_completed_extraction() end
            local original_setDirty = UIManager.setDirty
            local held_paint = false
            UIManager.setDirty = function(ui, widget, ...)
                if widget == menu.show_parent then
                    held_paint = true
                    return
                end
                return original_setDirty(ui, widget, ...)
            end
            local poll_result = { pcall(original) }
            UIManager.setDirty = original_setDirty
            if not poll_result[1] then error(poll_result[2]) end
            schedule_hydration(menu)
            local remaining = #(menu.items_to_update or {})
            local remaining_items = {}
            for index = 1, remaining do
                remaining_items[menu.items_to_update[index]] = true
            end
            local changed_region
            for item, region in pairs(before_items) do
                if not remaining_items[item] then
                    local path = item.filepath
                    local active = BookInfoManager._zen_cover_extract_active
                    if path and type(active) == "table" then
                        local ready_paths = BookInfoManager._zen_cover_extract_ready_paths
                        if type(ready_paths) ~= "table" then
                            ready_paths = {}
                            BookInfoManager._zen_cover_extract_ready_paths = ready_paths
                        end
                        ready_paths[path] = true
                    end
                    if region then
                        changed_region = changed_region
                            and changed_region:combine(region) or region
                    end
                end
            end
            UIManager:unschedule(poll)
            if before ~= remaining then
                logger.measure("Cover extraction poll", (now() - started_at) * 1000,
                    "page=", menu.page,
                    "updated=", before - remaining,
                    "remaining=", remaining)
            end
            if held_paint and changed_region then
                local pending = copy_region(menu._zen_cover_pending_refresh)
                menu._zen_cover_pending_refresh = pending
                    and pending:combine(changed_region) or changed_region
            end
            local still_extracting = is_extracting()
            if remaining > 0 and not still_extracting then
                settle_polls = remaining < before and 0 or settle_polls + 1
            else
                settle_polls = 0
            end
            local keep_polling = menu.items_update_action == poll and remaining > 0
                and (still_extracting or settle_polls < COVER_POLL_SETTLE_LIMIT)
            local hydration_pending = menu._zen_cover_hydrate_fn ~= nil
                or #(menu._zen_cover_hydration_items or {}) > 0
            if menu._zen_cover_pending_refresh and not hydration_pending
                    and (remaining == 0 or not keep_polling) then
                local region = copy_region(menu._zen_cover_pending_refresh)
                menu._zen_cover_pending_refresh = nil
                submit_hydration_refresh(
                    menu, generation, region, before - remaining, 0)
            end
            if keep_polling then
                UIManager:scheduleIn(COVER_POLL_S, poll)
            else
                if remaining > 0 and settle_polls >= COVER_POLL_SETTLE_LIMIT then
                    logger.measure("Cover extraction poll stopped", 0,
                        "reason=settle_timeout",
                        "page=", menu.page,
                        "remaining=", remaining)
                end
                release_cover_poll(menu, poll)
            end
        end
        menu._zen_cover_poll_action = poll
        menu._zen_cover_poll_original = original
        menu._zen_cover_poll_generation = generation
        menu.items_update_action = poll
        UIManager:scheduleIn(COVER_POLL_S, poll)
    end

    local function add_path(jobs, seen, path, width, height, render_width, render_height,
            final_render, preserve_aspect)
        if not path or path == "" then
            return
        end
        local existing = seen[path]
        if existing then
            if final_render then existing.final_render = true end
            if preserve_aspect then existing.preserve_aspect = true end
            return
        end
        local job = {
            path = path,
            width = width,
            height = height,
            render_width = render_width,
            render_height = render_height,
            final_render = final_render == true,
            preserve_aspect = preserve_aspect == true,
        }
        seen[path] = job
        jobs[#jobs + 1] = job
    end

    local function cover_job_specs(menu, allow_layout_fallback)
        local specs = menu.display_mode_type == "mosaic"
            and menu._zen_file_cover_specs or menu.cover_specs
        if type(specs) ~= "table" then specs = menu.cover_specs end
        local width = type(specs) == "table" and tonumber(specs.max_cover_w)
        local height = type(specs) == "table" and tonumber(specs.max_cover_h)
        if allow_layout_fallback and (not width or width < 1 or not height or height < 1) then
            local border = tonumber(CoverUtils.BORDER_SIZE) or 2
            width = (tonumber(menu.item_width) or 0) - 2 * border
            height = (tonumber(menu.item_height) or 0) - 2 * border
            local config = require("config/manager").get()
            local features = type(config) == "table" and config.features or nil
            specs = {
                uniform = type(features) == "table"
                    and features.browser_cover_mosaic_uniform == true,
            }
        end
        if not width or width < 1 or not height or height < 1 then return end
        local render_width, render_height = width, height
        if specs.uniform == true then
            render_width, render_height = CoverUtils.calcDims(width, height)
        end
        return width, height, render_width, render_height, specs.uniform == false
    end

    local function add_folder_jobs(menu, item, jobs, gallery_jobs, seen,
            folder_mode, folder_max_covers, width, height,
            render_width, render_height, preserve_aspect, max_jobs,
            deferred_stack_jobs)
        if folder_max_covers <= 0 or not FolderCover.isSupported(item, menu) then return end
        if max_jobs and #jobs + #gallery_jobs >= max_jobs then return end
        local virtual = item._zen_files or item.series_items or item.is_series_group
            or (menu and menu._zen_coll_list and item.name)
        if not virtual and type(item.path) == "string"
                and FolderCoverFiles.has(item.path, folder_mode) then
            return
        end
        local entries, physical, count, descriptor_cache_hit, enumeration_ms,
            descriptor_exact =
            FolderCover.previewEntries(menu, item, folder_max_covers)
        if folder_mode == "gallery" and #entries > 1 then
            gallery_jobs[#gallery_jobs + 1] = {
                kind = "gallery",
                menu = menu,
                entry = item,
                entries = entries,
                physical = physical,
                count = count,
                descriptor_cache_hit = descriptor_cache_hit,
                enumeration_ms = enumeration_ms,
                descriptor_exact = descriptor_exact,
                menu_text = item.text or item.title,
                width = width,
                height = height,
                uniform = not preserve_aspect,
                cover_specs = {
                    max_cover_w = width,
                    max_cover_h = height,
                    uniform = not preserve_aspect,
                },
            }
            return
        end
        local full_size_preview = folder_mode == "normal" or folder_mode == "stack"
            or #entries == 1
        for entry_index = 1, #entries do
            if max_jobs and #jobs + #gallery_jobs >= max_jobs then break end
            local grouped_item = entries[entry_index]
            local path = type(grouped_item) == "table"
                and (grouped_item.path or grouped_item.file) or grouped_item
            local folder_w, folder_h = CoverUtils.getFolderPreviewBounds(
                folder_mode, width, height, #entries, entry_index)
            local job_width = folder_w or width
            local job_height = folder_h or height
            local folder_render_w = folder_w or render_width
            local folder_render_h = folder_h or render_height
            local job = {
                path = path,
                width = job_width,
                height = job_height,
                render_width = folder_render_w,
                render_height = folder_render_h,
                final_render = full_size_preview,
                preserve_aspect = full_size_preview and preserve_aspect,
            }
            if folder_mode == "stack" and entry_index > 1
                    and type(deferred_stack_jobs) == "table" then
                deferred_stack_jobs[#deferred_stack_jobs + 1] = job
            else
                add_path(jobs, seen, job.path, job.width, job.height,
                    job.render_width, job.render_height,
                    job.final_render, job.preserve_aspect)
            end
        end
    end

    local function collect_jobs(menu, direction)
        local items = menu.item_table
        local perpage = tonumber(menu.perpage)
        local page = tonumber(menu.page)
        local width, height, render_width, render_height, preserve_aspect =
            cover_job_specs(menu)
        if type(items) ~= "table" or not perpage or perpage < 1 or not page then
            return {}, {}, {}
        end
        if not width or width < 1 or not height or height < 1 then
            return {}, {}, {}
        end
        local page_count = tonumber(menu.page_num) or math.max(1, math.ceil(#items / perpage))
        local folder_mode, folder_max_covers = CoverUtils.getMode()
        local jobs = {}
        local gallery_jobs = {}
        local status_jobs = {}
        local seen = {}
        local status_seen = {}
        local target_pages = {}
        for page_offset = 1, PRELOAD_LOOKAHEAD_PAGES do
            local target_page = page + direction * page_offset
            if target_page < 1 or target_page > page_count then break end
            target_pages[#target_pages + 1] = target_page
            local first = (target_page - 1) * perpage + 1
            local last = math.min(#items, first + perpage - 1)
            for index = first, last do
                local item = items[index]
                if type(item) == "table" then
                    local is_file = item.is_file or item.file
                        or (item.attr and item.attr.mode == "file")
                    if is_file then
                        local path = item.path or item.file
                        add_path(jobs, seen, path,
                            width, height, render_width, render_height, true, preserve_aspect)
                        if path and path ~= "" and not status_seen[path] then
                            status_seen[path] = true
                            status_jobs[#status_jobs + 1] = path
                        end
                    end
                    if not is_file then
                        add_folder_jobs(menu, item, jobs, gallery_jobs, seen,
                            folder_mode, folder_max_covers, width, height,
                            render_width, render_height, preserve_aspect)
                    end
                end
            end
        end
        for _i, job in ipairs(gallery_jobs) do jobs[#jobs + 1] = job end
        return jobs, target_pages, status_jobs
    end

    local function finish_status_preload(menu, state, message, reason)
        if menu._zen_cover_status_preload_state ~= state then return false end
        if state.step then UIManager:unschedule(state.step) end
        menu._zen_cover_status_preload_state = nil
        menu._zen_cover_status_preload_fn = nil
        menu._zen_cover_status_preload_jobs = nil
        logger.measure(message, state.work_ms,
            "target_page=", state.target_page,
            "status_jobs=", state.total,
            "warmed=", state.warmed,
            "failed=", state.failed,
            "remaining=", #state.jobs,
            "reason=", reason,
            "wall_ms=", math.floor((now() - state.started_at) * 1000 + 0.5))
        return true
    end

    local function status_preload_block_reason(menu)
        local reason = cover_work_block_reason(menu)
        if reason then return reason end
        if Device.screen_saver_mode == true then return "screen_saver" end
        if menu.no_refresh_covers == true or menu.cover_specs == false
                or menu._do_cover_images == false then
            return "covers_disabled"
        end
        local profile = memory_policy.applyCoverBudgets(render_cache, cache)
        if not memory_policy.canPreload(profile) then
            return "memory_" .. tostring(profile.pressure)
        end
        if is_extracting() then return "background_extraction" end
    end

    local function schedule_status_preload(menu, jobs, target_page)
        if type(jobs) ~= "table" or #jobs == 0 then return false end
        local reason = status_preload_block_reason(menu)
        if reason then
            logger.measure("Cover status preload skipped", 0,
                "target_page=", target_page,
                "status_jobs=", #jobs,
                "reason=", reason)
            return false
        end
        local state = {
            jobs = jobs,
            total = #jobs,
            target_page = target_page,
            started_at = now(),
            work_ms = 0,
            warmed = 0,
            failed = 0,
        }
        local step
        step = function()
            if menu._zen_cover_status_preload_state ~= state
                    or menu._zen_cover_status_preload_fn ~= step then return end
            local current_reason = status_preload_block_reason(menu)
            if current_reason then
                finish_status_preload(
                    menu, state, "Cover status preload skipped", current_reason)
                return
            end
            local chunk_started_at = now()
            local deadline = chunk_started_at + STATUS_PRELOAD_BUDGET_S
            local processed = 0
            while processed < STATUS_PRELOAD_CHUNK and #state.jobs > 0
                    and (processed == 0 or now() < deadline) do
                local path = table.remove(state.jobs, 1)
                processed = processed + 1
                local ok = pcall(book_status.getFileStatusData, path)
                if ok then
                    state.warmed = state.warmed + 1
                else
                    state.failed = state.failed + 1
                end
            end
            state.work_ms = state.work_ms + (now() - chunk_started_at) * 1000
            if #state.jobs > 0 then
                UIManager:scheduleIn(PRELOAD_TICK_S, step)
                return
            end
            finish_status_preload(
                menu, state, "Cover status preload completed", "completed")
        end
        state.step = step
        menu._zen_cover_status_preload_state = state
        menu._zen_cover_status_preload_fn = step
        menu._zen_cover_status_preload_jobs = jobs
        UIManager:scheduleIn(STATUS_PRELOAD_DELAY_S, step)
        return true
    end

    local function free_bitmap(bb)
        if bb and type(bb.free) == "function" then pcall(bb.free, bb) end
    end

    local function touch_cached_render(path, width, height)
        if type(render_cache.touchReusable) == "function" then
            return render_cache:touchReusable(path, width, height)
        end
        return (type(render_cache.hasReusable) == "function"
                and render_cache:hasReusable(path, width, height))
            or (type(render_cache.hasExact) == "function"
                and render_cache:hasExact(path, width, height))
    end

    local function warm_job(job, outcomes)
        if job.kind == "gallery" then
            local ok, warmed, cached = pcall(FolderCover.warmGallery,
                job.menu, job.entry, job.menu_text, job.width, job.height, {
                    cover_specs = job.cover_specs,
                    uniform = job.uniform,
                    entries = job.entries,
                    physical = job.physical,
                    count = job.count,
                    descriptor_cache_hit = job.descriptor_cache_hit,
                    enumeration_ms = job.enumeration_ms,
                    descriptor_exact = job.descriptor_exact,
                })
            if not ok then
                outcomes.failed = outcomes.failed + 1
            elseif warmed then
                outcomes.gallery_warmed = outcomes.gallery_warmed + 1
            elseif cached then
                outcomes.gallery_cached = outcomes.gallery_cached + 1
            else
                outcomes.failed = outcomes.failed + 1
            end
            return
        end
        if job.final_render and not job.preserve_aspect
                and touch_cached_render(job.path, job.render_width, job.render_height) then
            outcomes.final_render_cached = outcomes.final_render_cached + 1
            return
        end
        local decoded_cached = cache:has(job.path)
        local previous = rawget(_G, "__ZEN_COVER_PRELOAD_ACTIVE")
        _G.__ZEN_COVER_PRELOAD_ACTIVE = true
        local ok_info, info = pcall(BookInfoManager.getBookInfo,
            BookInfoManager, job.path, true)
        _G.__ZEN_COVER_PRELOAD_ACTIVE = previous

        local has_real_cover = ok_info and info and info.cover_bb
            and info.has_cover and not info.ignore_cover
        if not job.final_render and has_real_cover then
            if decoded_cached then
                outcomes.decoded_cached = outcomes.decoded_cached + 1
            else
                outcomes.decoded_warmed = outcomes.decoded_warmed + 1
            end
            if info and info.cover_bb then
                free_bitmap(info.cover_bb)
                info.cover_bb = nil
            end
            return
        end
        if has_real_cover then
            if decoded_cached then
                outcomes.decoded_cached = outcomes.decoded_cached + 1
            else
                outcomes.decoded_warmed = outcomes.decoded_warmed + 1
            end
            local source = info.cover_bb
            info.cover_bb = nil
            local render_width, render_height = job.render_width, job.render_height
            if job.preserve_aspect then
                local source_w, source_h = tonumber(info.cover_w), tonumber(info.cover_h)
                if not source_w or source_w <= 0 or not source_h or source_h <= 0 then
                    local ok, width, height = pcall(function()
                        return source:getWidth(), source:getHeight()
                    end)
                    if ok then source_w, source_h = width, height end
                end
                render_width, render_height = CoverUtils.fitDims(
                    job.width, job.height, source_w, source_h)
            end
            local before = render_cache:stats()
            local ok_render, final, cache_owned = pcall(render_cache.renderShared, render_cache,
                job.path, source, render_width, render_height)
            local after = render_cache:stats()
            if ok_render and final and cache_owned then
                if type(render_cache.releaseShared) == "function" then
                    render_cache:releaseShared(job.path, final)
                end
                if delta(after, before, "puts") > 0 then
                    outcomes.final_render_warmed = outcomes.final_render_warmed + 1
                elseif delta(after, before, "hits") > 0 then
                    outcomes.final_render_cached = outcomes.final_render_cached + 1
                else
                    outcomes.failed = outcomes.failed + 1
                end
                return
            end
            if ok_render and final then free_bitmap(final) end
            outcomes.failed = outcomes.failed + 1
            return
        end

        if info and info.cover_bb then
            free_bitmap(info.cover_bb)
            info.cover_bb = nil
        end
        local before = render_cache:stats()
        local generated_result = { pcall(CoverUtils.genCoverShared,
            job.path, job.width, job.height, nil, info or false) }
        local ok_generated = generated_result[1]
        local generated = generated_result[2]
        local cache_owned = generated_result[5]
        local cache_key = generated_result[6]
        local after = render_cache:stats()
        if ok_generated and generated and cache_owned then
            if type(render_cache.releaseShared) == "function" then
                render_cache:releaseShared(cache_key, generated)
            end
            if delta(after, before, "puts") > 0 then
                outcomes.generated_warmed = outcomes.generated_warmed + 1
            elseif delta(after, before, "hits") > 0 then
                outcomes.generated_cached = outcomes.generated_cached + 1
            else
                outcomes.failed = outcomes.failed + 1
            end
            return
        end
        if ok_generated and generated then free_bitmap(generated) end
        outcomes.failed = outcomes.failed + 1
    end

    local function collect_cover_page_jobs(menu, items, page)
        local perpage = tonumber(menu.perpage)
        page = tonumber(page)
        local width, height, render_width, render_height, preserve_aspect =
            cover_job_specs(menu, true)
        if type(items) ~= "table" or not perpage or perpage < 1
                or not page or page < 1 or page % 1 ~= 0 or not width then
            return {}
        end
        local first = (page - 1) * perpage + 1
        local last = math.min(#items, first + perpage - 1)
        local folder_mode, folder_max_covers = CoverUtils.getMode()
        local jobs, gallery_jobs, seen, deferred_stack_jobs = {}, {}, {}, {}
        for index = first, last do
            local item = items[index]
            if type(item) == "table" then
                local is_file = item.is_file or item.file
                    or (item.attr and item.attr.mode == "file")
                if is_file then
                    add_path(jobs, seen, item.path or item.file,
                        width, height, render_width, render_height, true, preserve_aspect)
                else
                    add_folder_jobs(menu, item, jobs, gallery_jobs, seen,
                        folder_mode, folder_max_covers, width, height,
                        render_width, render_height, preserve_aspect,
                        PAGE_WARM_MAX_FILES, deferred_stack_jobs)
                end
                if #jobs + #gallery_jobs >= PAGE_WARM_MAX_FILES then break end
            end
        end
        for _i, job in ipairs(gallery_jobs) do jobs[#jobs + 1] = job end
        for _i, job in ipairs(deferred_stack_jobs) do
            if #jobs >= PAGE_WARM_MAX_FILES then break end
            add_path(jobs, seen, job.path, job.width, job.height,
                job.render_width, job.render_height,
                job.final_render, job.preserve_aspect)
        end
        return jobs
    end

    local function page_warm_outcomes()
        return {
            decoded_warmed = 0,
            decoded_cached = 0,
            final_render_warmed = 0,
            final_render_cached = 0,
            generated_warmed = 0,
            generated_cached = 0,
            gallery_warmed = 0,
            gallery_cached = 0,
            failed = 0,
        }
    end

    local function page_warm_total(outcomes, suffix)
        return (outcomes["final_render_" .. suffix] or 0)
            + (outcomes["generated_" .. suffix] or 0)
            + (outcomes["gallery_" .. suffix] or 0)
    end

    local function finish_cover_page_warm(menu, state, message, reason)
        if menu._zen_cover_page_warm_state ~= state then return false end
        if state.step then UIManager:unschedule(state.step) end
        menu._zen_cover_page_warm_state = nil
        menu._zen_cover_page_warm_fn = nil
        local outcomes = state.outcomes
        logger.measure(message, state.work_s * 1000,
            "page=", state.page,
            "cover_jobs=", state.total,
            "processed=", state.total - #state.jobs,
            "remaining=", #state.jobs,
            "warmed=", page_warm_total(outcomes, "warmed"),
            "already_cached=", page_warm_total(outcomes, "cached"),
            "failed=", outcomes.failed,
            "bursts=", state.bursts,
            "reason=", reason,
            "wall_ms=", math.floor((now() - state.started_at) * 1000 + 0.5))
        if reason == "completed" and type(state.on_complete) == "function" then
            local ok, err = pcall(state.on_complete, menu, state.page)
            if not ok then
                logger.warn("Cover page idle warm completion failed", tostring(err))
            end
        end
        return true
    end

    cancel_cover_page_warm = function(menu, reason)
        local state = menu and menu._zen_cover_page_warm_state
        if type(state) ~= "table" then return false end
        return finish_cover_page_warm(
            menu, state, "Cover page idle warm cancelled", reason or "cancelled")
    end

    local function warm_cover_page(menu, items, page, on_complete)
        if menu._zen_needs_full_listing ~= true then return false, "listing_visible" end
        if not home_covers_filemanager(menu) then return false, "not_hidden" end
        if Device.screen_saver_mode == true then return false, "screen_saver" end
        if rawget(_G, "__ZEN_UI_SUPPRESS_FILEMANAGER_COVERS") == true
                or menu.no_refresh_covers == true or menu.cover_specs == false
                or menu._do_cover_images == false then
            return false, "covers_suppressed"
        end
        local jobs = collect_cover_page_jobs(menu, items, page)
        if #jobs == 0 then return false, "no_files" end
        local profile = memory_policy.applyCoverBudgets(render_cache, cache)
        if not memory_policy.canPreload(profile) then
            return false, "memory_" .. tostring(profile.pressure)
        end
        if is_extracting() then return false, "background_extraction" end

        cancel_cover_page_warm(menu, "replaced")
        cancel(menu)
        local state = {
            jobs = jobs,
            total = #jobs,
            page = page,
            started_at = now(),
            work_s = 0,
            burst_work_s = 0,
            bursts = 1,
            outcomes = page_warm_outcomes(),
            on_complete = on_complete,
        }
        local step
        step = function()
            if menu._zen_cover_page_warm_state ~= state
                    or menu._zen_cover_page_warm_fn ~= step then return end
            local reason
            if menu._zen_needs_full_listing ~= true then
                reason = "listing_visible"
            elseif not home_covers_filemanager(menu) then
                reason = "not_hidden"
            elseif Device.screen_saver_mode == true then
                reason = "screen_saver"
            elseif rawget(_G, "__ZEN_UI_SUPPRESS_FILEMANAGER_COVERS") == true then
                reason = "covers_suppressed"
            elseif menu._zen_cover_hydrate_fn then
                reason = "hydration_active"
            else
                local current_profile = memory_policy.applyCoverBudgets(render_cache, cache)
                if not memory_policy.canPreload(current_profile) then
                    reason = "memory_" .. tostring(current_profile.pressure)
                elseif is_extracting() then
                    reason = "background_extraction"
                end
            end
            if reason then
                finish_cover_page_warm(
                    menu, state, "Cover page idle warm cancelled", reason)
                return
            end

            local job = table.remove(state.jobs, 1)
            local started_at = now()
            warm_job(job, state.outcomes)
            local elapsed_s = now() - started_at
            state.work_s = state.work_s + elapsed_s
            state.burst_work_s = state.burst_work_s + elapsed_s
            if #state.jobs == 0 then
                finish_cover_page_warm(
                    menu, state, "Cover page idle warm completed", "completed")
            elseif state.burst_work_s >= PAGE_WARM_CPU_BUDGET_S then
                state.burst_work_s = 0
                state.bursts = state.bursts + 1
                UIManager:scheduleIn(PAGE_WARM_COOLDOWN_S, step)
            else
                UIManager:scheduleIn(PRELOAD_TICK_S, step)
            end
        end
        state.step = step
        menu._zen_cover_page_warm_state = state
        menu._zen_cover_page_warm_fn = step
        UIManager:scheduleIn(PRELOAD_TICK_S, step)
        return true
    end

    CoverMenu._zen_warm_cover_page = warm_cover_page
    FileChooser._zen_warm_cover_page = warm_cover_page
    CoverMenu._zen_cancel_warm_cover_page = cancel_cover_page_warm
    FileChooser._zen_cancel_warm_cover_page = cancel_cover_page_warm

    local function schedule(menu, memory_profile)
        cancel(menu)
        local block_reason = cover_work_block_reason(menu)
        if block_reason then
            logger.measure("Cover preload skipped", 0,
                "reason=" .. block_reason, "page=", menu.page)
            return
        end
        if menu.no_refresh_covers == true or menu.cover_specs == false
                or menu._do_cover_images == false then
            return
        end
        local direction = menu._zen_cover_preload_direction or 1
        menu._zen_cover_preload_direction = nil
        local jobs, target_pages, status_jobs = collect_jobs(menu, direction)
        if #jobs == 0 and #status_jobs == 0 then return end
        local target_page = target_pages[1]
        schedule_status_preload(menu, status_jobs, target_page)
        if #jobs == 0 then return end
        local cover_w, cover_h = jobs[1].width, jobs[1].height
        local cover_jobs = #jobs
        local already_final = 0
        local already_generated = 0
        local already_gallery = 0
        local pending = {}
        local hydration_active = menu._zen_cover_hydrate_fn ~= nil
        for _i, job in ipairs(jobs) do
            local cached_job = false
            if not hydration_active and job.kind == "gallery"
                    and type(FolderCover.isGalleryCached) == "function" then
                cached_job = FolderCover.isGalleryCached(
                    job.menu, job.entry, job.menu_text, job.width, job.height, {
                        entries = job.entries,
                        uniform = job.uniform,
                    })
                if cached_job then already_gallery = already_gallery + 1 end
            elseif not hydration_active and job.final_render and not job.preserve_aspect
                    and touch_cached_render(
                        job.path, job.render_width, job.render_height) then
                cached_job = true
                already_final = already_final + 1
            elseif not hydration_active
                    and type(CoverUtils.hasCachedGeneratedCover) == "function" then
                local metadata = type(cache.getFreshMetadata) == "function"
                    and cache:getFreshMetadata(job.path, now(), 30) or nil
                if type(metadata) == "table" and metadata.cover_fetched
                        and (not metadata.has_cover or metadata.ignore_cover) then
                    cached_job = CoverUtils.hasCachedGeneratedCover(
                        job.path, job.width, job.height, nil, metadata)
                    if cached_job then already_generated = already_generated + 1 end
                end
            end
            if not cached_job then pending[#pending + 1] = job end
        end
        jobs = pending
        local already_cached = already_final + already_generated + already_gallery
        if #jobs == 0 then
            logger.measure("Cover preload completed", 0,
                "target_page=", target_page,
                "lookahead_pages=", #target_pages,
                "cover_jobs=", cover_jobs,
                "cover_w=", cover_w,
                "cover_h=", cover_h,
                "warmed=", 0,
                "already_cached=", already_cached,
                "decoded_warmed=", 0,
                "decoded_cached=", 0,
                "final_render_warmed=", 0,
                "final_render_cached=", already_final,
                "generated_warmed=", 0,
                "generated_cached=", already_generated,
                "gallery_warmed=", 0,
                "gallery_cached=", already_gallery,
                "failed=", 0,
                "wall_ms=", 0)
            return
        end
        memory_profile = memory_profile
            or memory_policy.applyCoverBudgets(render_cache, cache)
        if not memory_policy.canPreload(memory_profile) then
            logger.measure("Cover preload skipped", 0,
                "reason=memory_" .. tostring(memory_profile.pressure),
                "target_page=", target_page,
                "lookahead_pages=", #target_pages,
                "cover_jobs=", cover_jobs,
                "queued=", #jobs)
            return
        end
        if is_extracting() then
            logger.measure("Cover preload skipped", 0,
                "reason=background_extraction",
                "target_page=", target_page,
                "lookahead_pages=", #target_pages,
                "cover_jobs=", cover_jobs,
                "queued=", #jobs)
            return
        end

        menu._zen_cover_preload_jobs = jobs
        local started_at = now()
        local before_render = render_cache:stats()
        local work_ms = 0
        local outcomes = {
            decoded_warmed = 0,
            decoded_cached = 0,
            final_render_warmed = 0,
            final_render_cached = already_final,
            generated_warmed = 0,
            generated_cached = already_generated,
            gallery_warmed = 0,
            gallery_cached = already_gallery,
            failed = 0,
        }

        local step
        step = function()
            if menu._zen_cover_preload_fn ~= step then return end
            local current_block_reason = cover_work_block_reason(menu)
            if current_block_reason then
                menu._zen_cover_preload_fn = nil
                menu._zen_cover_preload_jobs = nil
                logger.measure("Cover preload skipped", work_ms,
                    "reason=" .. current_block_reason,
                    "target_page=", target_page,
                    "lookahead_pages=", #target_pages,
                    "cover_jobs=", cover_jobs,
                    "queued=", #jobs,
                    "wall_ms=", math.floor((now() - started_at) * 1000 + 0.5))
                return
            end
            if menu._zen_cover_hydrate_fn then
                UIManager:scheduleIn(PRELOAD_TICK_S, step)
                return
            end
            local current_memory = memory_policy.applyCoverBudgets(render_cache, cache)
            if not memory_policy.canPreload(current_memory) then
                menu._zen_cover_preload_fn = nil
                menu._zen_cover_preload_jobs = nil
                logger.measure("Cover preload skipped", work_ms,
                    "reason=memory_" .. tostring(current_memory.pressure),
                    "target_page=", target_page,
                    "lookahead_pages=", #target_pages,
                    "cover_jobs=", cover_jobs,
                    "queued=", #jobs,
                    "wall_ms=", math.floor((now() - started_at) * 1000 + 0.5))
                return
            end
            if is_extracting() then
                menu._zen_cover_preload_fn = nil
                menu._zen_cover_preload_jobs = nil
                logger.measure("Cover preload skipped", work_ms,
                    "reason=background_extraction_after_delay",
                    "target_page=", target_page,
                    "lookahead_pages=", #target_pages,
                    "cover_jobs=", cover_jobs,
                    "queued=", #jobs,
                    "wall_ms=", math.floor((now() - started_at) * 1000 + 0.5))
                return
            end
            local chunk_started_at = now()
            local deadline = chunk_started_at + PRELOAD_BUDGET_S
            local processed = 0
            while processed < PRELOAD_CHUNK and #jobs > 0
                    and (processed == 0 or now() < deadline) do
                local job = table.remove(jobs, 1)
                processed = processed + 1
                warm_job(job, outcomes)
            end
            work_ms = work_ms + (now() - chunk_started_at) * 1000
            if #jobs > 0 then
                UIManager:scheduleIn(PRELOAD_TICK_S, step)
                return
            end
            menu._zen_cover_preload_fn = nil
            menu._zen_cover_preload_jobs = nil
            local after_render = render_cache:stats()
            logger.measure("Cover preload completed", work_ms,
                "target_page=", target_page,
                "lookahead_pages=", #target_pages,
                "cover_jobs=", cover_jobs,
                "cover_w=", cover_w,
                "cover_h=", cover_h,
                "warmed=", outcomes.final_render_warmed + outcomes.generated_warmed
                    + outcomes.gallery_warmed,
                "already_cached=", outcomes.final_render_cached + outcomes.generated_cached
                    + outcomes.gallery_cached,
                "decoded_warmed=", outcomes.decoded_warmed,
                "decoded_cached=", outcomes.decoded_cached,
                "final_render_warmed=", outcomes.final_render_warmed,
                "final_render_cached=", outcomes.final_render_cached,
                "generated_warmed=", outcomes.generated_warmed,
                "generated_cached=", outcomes.generated_cached,
                "gallery_warmed=", outcomes.gallery_warmed,
                "gallery_cached=", outcomes.gallery_cached,
                "failed=", outcomes.failed,
                "render_shared_hits=", delta(after_render, before_render, "shared_hits"),
                "render_exact_copy_hits=",
                    delta(after_render, before_render, "exact_copy_hits"),
                "render_resized_hits=", delta(after_render, before_render, "resized_hits"),
                "wall_ms=", math.floor((now() - started_at) * 1000 + 0.5))
        end
        menu._zen_cover_preload_fn = step
        UIManager:scheduleIn(PRELOAD_DELAY_S, step)
    end

    local function resume_visible_cover_work(menu)
        local block_reason = cover_work_block_reason(menu)
        if block_reason then
            if block_reason ~= "hidden_under_home" then
                cancel_extraction_launch(menu)
            end
            logger.measure("Cover work resume skipped", 0,
                "page=", menu.page,
                "reason=" .. block_reason)
            return false
        end
        cancel_hidden_folder_prewarm(menu, "library_reveal", "preserve")
        local generation = menu._zen_cover_hydration_generation
        local suspended = menu._zen_cover_suspended_hydration_items
        local suspended_generation = menu._zen_cover_suspended_hydration_generation
        menu._zen_cover_suspended_hydration_items = nil
        menu._zen_cover_suspended_hydration_generation = nil
        local resumed = 0
        if type(suspended) == "table" and suspended_generation == generation then
            resumed = #suspended
            if resumed > 0 then schedule_hydration(menu, suspended) end
        else
            clear_hydration_items(suspended)
        end
        local extraction_launch_resumed = resume_suspended_extraction_launch(menu, generation)
        local extraction_pending = #(menu.items_to_update or {}) > 0
        if extraction_pending then accelerate_cover_poll(menu) end
        if resumed == 0 and not extraction_pending and menu._zen_cover_pending_refresh then
            local region = copy_region(menu._zen_cover_pending_refresh)
            menu._zen_cover_pending_refresh = nil
            submit_hydration_refresh(menu, generation, region, 0, 0)
        end
        schedule(menu)
        logger.measure("Cover work resumed", 0,
            "page=", menu.page,
            "generation=", generation,
            "hydration_jobs=", resumed,
            "extraction_pending=", extraction_pending,
            "extraction_launch_resumed=", extraction_launch_resumed)
        return resumed > 0 or extraction_pending or extraction_launch_resumed
    end

    local function measured_updateItems(menu, original, ...)
        if menu._zen_cover_measure_active then return original(menu, ...) end
        cancel_cover_page_warm(menu, "page_update")
        cancel(menu)
        cancel_hydration(menu)
        cancel_extraction_launch(menu)
        menu._zen_cover_hydration_generation =
            (menu._zen_cover_hydration_generation or 0) + 1
        menu._zen_request_cover_hydration = schedule_hydration
        menu._zen_resume_visible_cover_work = resume_visible_cover_work
        menu._zen_start_hidden_folder_prewarm = start_hidden_folder_prewarm
        menu._zen_cancel_hidden_folder_prewarm = cancel_hidden_folder_prewarm
        local turn_measure = measurements_enabled and menu._zen_cover_turn_measure or nil
        menu._zen_cover_turn_measure = nil
        local reveal
        if menu.display_mode_type == "mosaic" and menu.show_parent
                and not cover_work_block_reason(menu) then
            reveal = {
                generation = menu._zen_cover_hydration_generation,
                page = menu.page,
                started_at = now(),
                input_started_at = turn_measure and turn_measure.started_at,
                dirty_calls = {},
                queued = 0,
            }
            menu._zen_cover_reveal = reveal
            menu._zen_cover_collecting_reveal = reveal
        end
        menu._zen_cover_measure_active = true
        if measurements_enabled then
            menu._zen_cover_build_measure = {
                tile_count = 0,
                tile_ms = 0,
                metadata_ms = 0,
                status_ms = 0,
                stable_page_sidecar_opens = 0,
                stable_page_booklist_reads = 0,
                cover_widget_ms = 0,
                pending_fallback_ms = 0,
            }
            menu._zen_folder_build_measure = {
                builds = 0,
                descriptor_hits = 0,
                candidates = 0,
                enumeration_ms = 0,
                explicit_ms = 0,
                collect_ms = 0,
                draw_ms = 0,
                composite_hits = 0,
                composite_builds = 0,
            }
        end
        local memory_profile = memory_policy.applyCoverBudgets(render_cache, cache)
        local before = measurements_enabled and cache:stats() or nil
        local before_render = measurements_enabled and render_cache:stats() or nil
        local started_at = measurements_enabled and now() or nil
        if menu.display_mode_type == "mosaic" then
            menu._zen_file_cover_specs = nil
        end
        local previous_grid = copy_region(menu._zen_cover_last_grid_region)
        local refresh_region = menu._zen_cover_turn_active
            and page_refresh_region(menu, previous_grid) or nil
        local result
        if refresh_region or reveal then
            result = call_with_scoped_dirty(
                menu, refresh_region, reveal, defer_extraction_launch, menu, original, ...)
        else
            result = defer_extraction_launch(menu, original, ...)
        end
        local resolved_region, current_grid = page_refresh_region(menu, previous_grid)
        menu._zen_cover_last_grid_region = current_grid
        if menu._zen_cover_turn_active then refresh_region = resolved_region end
        if reveal and menu._zen_cover_turn_active then
            reveal.refresh_region = resolved_region
        end
        if refresh_region then
            local full_area = menu.dimen and menu.dimen.w and menu.dimen.h
                and menu.dimen.w * menu.dimen.h or 0
            menu._zen_cover_refresh_region_pct = full_area > 0
                and math.floor(refresh_region.w * refresh_region.h * 1000
                    / full_area + 0.5) / 10 or 100
        else
            menu._zen_cover_refresh_region_pct = 100
        end
        if menu._zen_cover_collecting_reveal == reveal then
            menu._zen_cover_collecting_reveal = nil
        end
        local initial_jobs
        local initial_queued = 0
        if reveal then
            initial_jobs = menu._zen_cover_hydration_items or {}
            menu._zen_cover_hydration_items = {}
            initial_queued = #initial_jobs
            reveal.queued = initial_queued
            if #reveal.dirty_calls == 0 then
                menu._zen_cover_reveal = nil
                reveal = nil
            end
        end
        local function begin_initial_reveal()
            if not initial_jobs then return end
            if reveal then
                local reason = menu._zen_cover_direct_jump_active and "immediate_jump"
                    or (menu._zen_cover_turn_active and "immediate_turn" or "immediate")
                flush_reveal(menu, reveal, reason, 0, 0)
            end
            if #initial_jobs > 0 then
                schedule_hydration(menu, initial_jobs)
            end
        end
        if not cover_work_block_reason(menu) then accelerate_cover_poll(menu) end
        menu._zen_cover_measure_active = nil
        if not measurements_enabled then
            begin_initial_reveal()
            schedule(menu, memory_profile)
            return result
        end

        local elapsed_ms = (now() - started_at) * 1000
        local after = cache:stats()
        local after_render = render_cache:stats()
        local build_measure = menu._zen_cover_build_measure
        menu._zen_cover_build_measure = nil
        local folder_measure = menu._zen_folder_build_measure
        menu._zen_folder_build_measure = nil
        local hits = delta(after, before, "hits")
        local misses = delta(after, before, "misses")
        local requests = hits + misses
        local hit_rate = requests > 0 and math.floor(hits * 1000 / requests + 0.5) / 10 or 0
        local perpage = tonumber(menu.perpage) or 0
        local first = ((tonumber(menu.page) or 1) - 1) * perpage + 1
        local visible = math.max(0, math.min(perpage, #(menu.item_table or {}) - first + 1))
        menu._zen_cover_paint_measure = {
            expected = visible,
            page = menu.page,
            started_at = now(),
            input_started_at = turn_measure and turn_measure.started_at,
            direction = turn_measure and turn_measure.direction,
            tile_count = 0,
            tile_ms = 0,
        }
        local input_to_update_ms = turn_measure
            and (now() - turn_measure.started_at) * 1000 or 0
        local file_specs = menu._zen_file_cover_specs
        local suspended_hydration =
            menu._zen_cover_suspended_hydration_generation
                == menu._zen_cover_hydration_generation
            and #(menu._zen_cover_suspended_hydration_items or {}) or 0
        local queued_hydration = initial_queued
            + #(menu._zen_cover_hydration_items or {}) + suspended_hydration
        local folder_hydration = 0
        local function count_folder_jobs(items)
            for _i, item in ipairs(items or {}) do
                if item._zen_cover_hydration_kind == "folder" then
                    folder_hydration = folder_hydration + 1
                end
            end
        end
        count_folder_jobs(initial_jobs)
        count_folder_jobs(menu._zen_cover_hydration_items)
        if suspended_hydration > 0 then
            count_folder_jobs(menu._zen_cover_suspended_hydration_items)
        end
        logger.measure("Cover page updated", elapsed_ms,
            "mode=", tostring(menu.display_mode_type),
            "page=", tostring(menu.page),
            "visible_items=", visible,
            "total_items=", #(menu.item_table or {}),
            "cache_hits=", hits,
            "cache_misses=", misses,
            "hit_rate_pct=", hit_rate,
            "avoided_decompressions=", hits,
            "avoided_db_reads=", delta(after, before, "fast_hits"),
            "metadata_cache_hits=", delta(after, before, "metadata_hits"),
            "hydration_queued=", queued_hydration,
            "folder_hydration_queued=", folder_hydration,
            "book_hydration_queued=", queued_hydration - folder_hydration,
            "full_reads=", delta(after, before, "full_reads"),
            "decode_reads=", delta(after, before, "decode_reads"),
            "decode_ms=", math.floor(delta(after, before, "decode_read_ms") * 10 + 0.5) / 10,
            "validation_ms=", math.floor(delta(after, before, "validation_ms") * 10 + 0.5) / 10,
            "tile_builds=", build_measure.tile_count,
            "tile_build_ms=", math.floor(build_measure.tile_ms * 10 + 0.5) / 10,
            "metadata_ms=", math.floor((build_measure.metadata_ms or 0) * 10 + 0.5) / 10,
            "status_ms=", math.floor((build_measure.status_ms or 0) * 10 + 0.5) / 10,
            "stable_page_sidecar_opens=", build_measure.stable_page_sidecar_opens or 0,
            "stable_page_booklist_reads=", build_measure.stable_page_booklist_reads or 0,
            "cover_widget_ms=",
                math.floor((build_measure.cover_widget_ms or 0) * 10 + 0.5) / 10,
            "pending_fallback_ms=",
                math.floor((build_measure.pending_fallback_ms or 0) * 10 + 0.5) / 10,
            "folder_builds=", folder_measure.builds,
            "folder_descriptor_hits=", folder_measure.descriptor_hits,
            "folder_candidates=", folder_measure.candidates,
            "folder_enumeration_ms=",
                math.floor(folder_measure.enumeration_ms * 10 + 0.5) / 10,
            "folder_explicit_ms=",
                math.floor(folder_measure.explicit_ms * 10 + 0.5) / 10,
            "folder_collect_ms=",
                math.floor(folder_measure.collect_ms * 10 + 0.5) / 10,
            "folder_draw_ms=", math.floor(folder_measure.draw_ms * 10 + 0.5) / 10,
            "folder_composite_hits=", folder_measure.composite_hits,
            "folder_composite_builds=", folder_measure.composite_builds,
            "render_cache_hits=", delta(after_render, before_render, "hits"),
            "render_cache_misses=", delta(after_render, before_render, "misses"),
            "render_shared_hits=", delta(after_render, before_render, "shared_hits"),
            "render_exact_copy_hits=",
                delta(after_render, before_render, "exact_copy_hits"),
            "render_resized_hits=", delta(after_render, before_render, "resized_hits"),
            "render_cache_mb=", math.floor((after_render.bytes or 0) / 1024 / 1024 * 10 + 0.5) / 10,
            "cache_mb=", math.floor((after.bytes or 0) / 1024 / 1024 * 10 + 0.5) / 10,
            "memory_pressure=", memory_profile.pressure,
            "memory_available_mb=", memory_profile.available_bytes
                and math.floor(memory_profile.available_bytes / 1024 / 1024 + 0.5) or -1,
            "render_budget_mb=",
                math.floor((after_render.byte_budget or 0) / 1024 / 1024 * 10 + 0.5) / 10,
            "decode_budget_mb=",
                math.floor((after.byte_budget or 0) / 1024 / 1024 * 10 + 0.5) / 10,
            "cover_w=", type(file_specs) == "table" and file_specs.max_cover_w or 0,
            "cover_h=", type(file_specs) == "table" and file_specs.max_cover_h or 0,
            "refresh_region_pct=", menu._zen_cover_refresh_region_pct,
            "page_turn_direction=", turn_measure and turn_measure.direction or "none",
            "input_to_update_ms=", math.floor(input_to_update_ms * 10 + 0.5) / 10)
        begin_initial_reveal()
        schedule(menu, memory_profile)
        return result
    end

    local original_updateItems = CoverMenu.updateItems
    CoverMenu.updateItems = function(menu, ...)
        return measured_updateItems(menu, original_updateItems, ...)
    end

    local original_filechooser_updateItems = FileChooser.updateItems
    if original_filechooser_updateItems ~= original_updateItems then
        FileChooser.updateItems = function(menu, ...)
            if menu._updateItemsBuildUI and menu.display_mode_type then
                return measured_updateItems(menu, original_filechooser_updateItems, ...)
            end
            return original_filechooser_updateItems(menu, ...)
        end
    else
        FileChooser.updateItems = CoverMenu.updateItems
    end

    local function patch_page_turn(owner, method, direction, label)
        local marker = "__zen_cover_preload_" .. method .. "_patched"
        if rawget(owner, marker) or type(owner[method]) ~= "function" then return end
        owner[marker] = true
        local original = owner[method]
        owner[method] = function(menu, ...)
            if menu._zen_cover_turn_active then return original(menu, ...) end
            menu._zen_cover_turn_active = true
            menu._zen_cover_preload_direction = direction
            local turn_measure
            if measurements_enabled then
                turn_measure = { direction = label, started_at = now() }
                menu._zen_cover_turn_measure = turn_measure
            end
            local result = original(menu, ...)
            if turn_measure and menu._zen_cover_turn_measure == turn_measure then
                menu._zen_cover_turn_measure = nil
            end
            menu._zen_cover_turn_active = nil
            return result
        end
    end
    patch_page_turn(Menu, "onNextPage", 1, "next")
    patch_page_turn(Menu, "onPrevPage", -1, "previous")
    patch_page_turn(CoverMenu, "onNextPage", 1, "next")
    patch_page_turn(CoverMenu, "onPrevPage", -1, "previous")
    patch_page_turn(FileChooser, "onNextPage", 1, "next")
    patch_page_turn(FileChooser, "onPrevPage", -1, "previous")

    local function patch_goto_page(owner)
        local marker = "__zen_cover_preload_onGotoPage_patched"
        if rawget(owner, marker) or type(owner.onGotoPage) ~= "function" then return end
        owner[marker] = true
        local original = owner.onGotoPage
        owner.onGotoPage = function(menu, page, ...)
            if menu._zen_cover_turn_active then return original(menu, page, ...) end
            local current = tonumber(menu.page)
            local target = tonumber(page)
            if not current or not target or current == target then
                return original(menu, page, ...)
            end
            local direction = target > current and 1 or -1
            local label = direction > 0 and "jump_forward" or "jump_backward"
            menu._zen_cover_turn_active = true
            menu._zen_cover_direct_jump_active = true
            menu._zen_cover_preload_direction = direction
            local turn_measure
            if measurements_enabled then
                turn_measure = { direction = label, started_at = now() }
                menu._zen_cover_turn_measure = turn_measure
            end
            local result = original(menu, page, ...)
            if turn_measure and menu._zen_cover_turn_measure == turn_measure then
                menu._zen_cover_turn_measure = nil
            end
            menu._zen_cover_direct_jump_active = nil
            menu._zen_cover_turn_active = nil
            return result
        end
    end
    patch_goto_page(Menu)
    patch_goto_page(CoverMenu)
    patch_goto_page(FileChooser)

    local original_onCloseWidget = CoverMenu.onCloseWidget
    local function onCloseWidget(menu, ...)
        cancel_cover_page_warm(menu, "menu_closed")
        cancel(menu)
        cancel_hydration(menu)
        if menu._zen_cover_poll_action then
            release_cover_poll(menu, menu._zen_cover_poll_action)
        end
        menu._zen_request_cover_hydration = nil
        menu._zen_resume_visible_cover_work = nil
        menu._zen_start_hidden_folder_prewarm = nil
        menu._zen_cancel_hidden_folder_prewarm = nil
        cancel_extraction_launch(menu)
        return original_onCloseWidget(menu, ...)
    end
    CoverMenu.onCloseWidget = onCloseWidget
    if FileChooser.onCloseWidget == original_onCloseWidget then
        FileChooser.onCloseWidget = onCloseWidget
    end
end

return apply_cover_preload
