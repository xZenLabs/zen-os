local logger = require("common/zen_logger").new("home_page")
local author_sort = require("common/author_sort")
local title_sort = require("common/title_sort")
local ConfigManager = require("config/manager")
local book_status = require("common/book_status")
local Blitbuffer = require("ffi/blitbuffer")
local DecodeCache = require("common/cover_decode_cache")
local RenderCache = require("common/cover_render_cache")
local HomeQuotes = require("modules/filebrowser/patches/home/home_quotes")
local HomePresets = require("modules/filebrowser/patches/home/home_presets")
local LanguageName = require("common/language_name")
local MemoryPolicy = require("common/memory_policy")
local ReadingGoals = require("common/reading_goals")
local PresetStore = require("config/preset_store")
local Registry = require("modules/filebrowser/patches/home/components/registry")
local StandalonePage = require("modules/filebrowser/patches/standalone_page")
local SharedState = require("common/shared_state")
local utils = require("common/utils")
local WidgetResources = require("common/widget_resources")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local now = require("common/zen_logger").now

local M = {}
local DEFAULT_GOALS_FONT_SIZE = 11
local DEFAULT_STATS_FONT_SIZE = 18
local DEFAULT_STATS_MAX_FONT_SIZE = 18
local MAX_STATS_FONT_SIZE = 64
local DEFAULT_DATETIME_FONT_SIZES = { time = 48, date = 18 }

-- When a library background image is configured, home module frames must be
-- transparent (nil fill) instead of opaque COLOR_WHITE, or they paint over the
-- background painted behind the page. Returns the fill color to use.
local Background = require("common/ui/background")
local function home_frame_bg()
    return Background.tile_bg(Blitbuffer.COLOR_WHITE)
end

local _home_menu = nil
local _home_inject_navbar = nil
local _zen_shared = nil
local _zen_plugin = nil
local _home_book_cache = {}
local _home_book_cache_order = {}
local _home_book_cache_bytes = 0
local _home_book_cache_byte_budget = MemoryPolicy.homeByteBudget()
local _home_dataset_cache = nil
local _home_dataset_generation = 0
local _home_strip_page_state = nil
local HOME_BOOK_CACHE_MAX = 32
local HOME_DATASET_TTL = 120
local HOME_STRIP_MAX_BOOKS = 40
local HOME_STATS_TTL = 60
local _home_stats_cache = { key = nil, value = nil, expires_at = 0 }

local function copy_home_strip_pages(state)
    local copy = {}
    for key, offset in pairs(type(state) == "table" and state or {}) do
        offset = tonumber(offset)
        if type(key) == "string" and offset then copy[key] = offset end
    end
    return copy
end

local function copy_home_strip_state(state)
    local source = type(state) == "table" and state.source or nil
    if type(source) ~= "table" or type(source.kind) ~= "string"
            or source.kind == "" then
        return nil
    end
    local copy = { source = { kind = source.kind } }
    if source.value ~= nil then copy.source.value = source.value end
    if type(source.paths) == "table" then
        copy.source.paths = utils.deepcopy(source.paths)
    end
    local drill = source.drill
    if type(drill) == "table" and type(drill.label) == "string" then
        copy.source.drill = { label = drill.label }
        if type(drill.files) == "table" then
            copy.source.drill.files = utils.deepcopy(drill.files)
        end
    end
    if type(state.active_id) == "string" then
        copy.active_id = state.active_id
    end
    return copy
end

local function save_home_strip_state(dcfg, state)
    if type(dcfg) ~= "table" then return false end
    local remembered = copy_home_strip_state(state)
    if not remembered then return false end
    if remembered.source.drill then
        remembered.source.drill.files = nil
    end
    dcfg.strip_memory = remembered
    return PresetStore.saveSettings("home", dcfg)
end

local function home_is_on_top(menu)
    if menu == nil then return false end
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return false end
    for index = #stack, 1, -1 do
        local widget = stack[index] and stack[index].widget
        if widget and not widget.toast then
            return rawequal(widget, menu)
        end
    end
    return false
end

local function mark_home_rebuild_needed(refresh_stats, reload_config)
    local menu = _home_menu
    if not menu or menu._zen_home_closing then return end
    menu._zen_home_needs_rebuild = true
    if refresh_stats == true then menu._zen_home_refresh_stats = true end
    if reload_config == true then menu._zen_home_reload_config = true end
end

local home_close_hook_installed = false
local function install_home_close_hook()
    if home_close_hook_installed or type(UIManager.close) ~= "function" then return end
    home_close_hook_installed = true
    local orig_close = UIManager.close
    UIManager.close = function(self, widget, ...)
        local result = orig_close(self, widget, ...)
        local menu = _home_menu
        if menu and menu._zen_home_needs_repaint
                and not menu._zen_home_closing
                and menu._zen_home_suspended ~= true
                and home_is_on_top(menu) then
            local resumed = type(menu._zen_home_resume) == "function"
                and menu:_zen_home_resume()
            if not resumed then
                menu._zen_home_needs_repaint = nil
                self:setDirty(menu, "ui")
            end
        end
        return result
    end
end

local function request_home_repaint(menu, refresh)
    if not menu or menu._zen_home_closing then return false end
    if not rawequal(menu, _home_menu) or menu._zen_home_suspended == true
            or not home_is_on_top(menu) then
        menu._zen_home_needs_repaint = true
        install_home_close_hook()
        return false
    end
    menu._zen_home_needs_repaint = nil
    UIManager:setDirty(menu, refresh)
    return true
end

local function new_home_dataset()
    _home_dataset_generation = _home_dataset_generation + 1
    return {
        generation = _home_dataset_generation,
        expires_at = os.time() + HOME_DATASET_TTL,
        effective_status = {},
        status_data = {},
        favorite = {},
        ordered_paths = {},
        strip_paths = {},
    }
end

local function get_home_dataset()
    if not _home_dataset_cache or os.time() >= _home_dataset_cache.expires_at then
        _home_dataset_cache = new_home_dataset()
    end
    return _home_dataset_cache
end

local function clear_home_dataset_derived(dataset)
    if not dataset then return end
    dataset.ordered_paths = {}
    dataset.strip_paths = {}
    dataset.tbr = nil
end

local function invalidate_home_dataset_path(path, history_changed)
    if type(path) ~= "string" or path == "" then return end
    local dataset = _home_dataset_cache
    if not dataset then return end
    dataset.generation = dataset.generation + 1
    dataset.effective_status[path] = nil
    dataset.status_data[path] = nil
    dataset.favorite[path] = nil
    if history_changed then dataset.history = nil end
    clear_home_dataset_derived(dataset)
end

local function invalidate_home_library_dataset()
    local loaded_index = package.loaded["common/tbr_index"]
    if loaded_index and type(loaded_index.invalidateAudit) == "function" then
        loaded_index.invalidateAudit()
    elseif loaded_index and type(loaded_index.cancelAudit) == "function" then
        loaded_index.cancelAudit()
    end
    local dataset = _home_dataset_cache
    if dataset then
        dataset.generation = dataset.generation + 1
        dataset.tbr_audit_requested = nil
        clear_home_dataset_derived(dataset)
    end
end

local function free_cached_book(book)
    if book and book.cover_bb and book.cover_bb.free then
        pcall(function() book.cover_bb:free() end)
        book.cover_bb = nil
    end
end

local function clone_cached_book(book, include_internal, include_cover)
    if type(book) ~= "table" then return nil end
    local out = {}
    for k, v in pairs(book) do
        if k ~= "cover_bb" and (include_internal or k:sub(1, 5) ~= "_zen_") then
            out[k] = v
        end
    end
    if include_cover ~= false and book.cover_bb and book.cover_bb.copy then
        local ok, cover_bb = pcall(book.cover_bb.copy, book.cover_bb)
        if ok then out.cover_bb = cover_bb end
    end
    return out
end

local function get_home_book_cache_key(path)
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    local file_mtime = ok_lfs and lfs.attributes(path, "modification") or 0
    local sidecar_mtime = 0
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if ok_lfs and ok_ds and DocSettings and type(DocSettings.findSidecarFile) == "function" then
        local ok_sidecar, sidecar_file = pcall(DocSettings.findSidecarFile, DocSettings, path)
        if ok_sidecar and sidecar_file then
            sidecar_mtime = lfs.attributes(sidecar_file, "modification") or 0
        end
    end
    return table.concat({
        path,
        tostring(file_mtime or 0),
        tostring(sidecar_mtime or 0),
    }, "|")
end

local function invalidate_home_book_cache(path)
    if type(path) ~= "string" or path == "" then return end
    if type(book_status.invalidate) == "function" then book_status.invalidate(path) end
    local prefix = path .. "|"
    for key, book in pairs(_home_book_cache) do
        if key:sub(1, #prefix) == prefix then
            _home_book_cache_bytes = math.max(
                0, _home_book_cache_bytes - (book._zen_cache_bytes or 0))
            free_cached_book(book)
            _home_book_cache[key] = nil
        end
    end
    for i = #_home_book_cache_order, 1, -1 do
        if _home_book_cache_order[i]:sub(1, #prefix) == prefix then
            table.remove(_home_book_cache_order, i)
        end
    end
end

local function remove_home_book_cache_entry(key)
    local book = key and _home_book_cache[key]
    if not book then return end
    _home_book_cache[key] = nil
    _home_book_cache_bytes = math.max(
        0, _home_book_cache_bytes - (book._zen_cache_bytes or 0))
    free_cached_book(book)
end

local function trim_home_book_cache()
    while #_home_book_cache_order > HOME_BOOK_CACHE_MAX
            or _home_book_cache_bytes > _home_book_cache_byte_budget do
        local evict = table.remove(_home_book_cache_order, 1)
        if not evict then break end
        remove_home_book_cache_entry(evict)
    end
end

local function cache_home_book(key, book)
    remove_home_book_cache_entry(key)
    for i = #_home_book_cache_order, 1, -1 do
        if _home_book_cache_order[i] == key then
            table.remove(_home_book_cache_order, i)
        end
    end
    local expected_bytes = MemoryPolicy.bitmapBytes(book.cover_bb)
    if expected_bytes > _home_book_cache_byte_budget then return end
    while #_home_book_cache_order >= HOME_BOOK_CACHE_MAX
            or _home_book_cache_bytes + expected_bytes > _home_book_cache_byte_budget do
        local evict = table.remove(_home_book_cache_order, 1)
        if not evict then break end
        remove_home_book_cache_entry(evict)
    end
    local cached = clone_cached_book(book, true)
    cached._zen_cache_bytes = MemoryPolicy.bitmapBytes(cached.cover_bb)
    if cached._zen_cache_bytes > _home_book_cache_byte_budget then
        free_cached_book(cached)
        return
    end
    _home_book_cache[key] = cached
    _home_book_cache_bytes = _home_book_cache_bytes + cached._zen_cache_bytes
    _home_book_cache_order[#_home_book_cache_order + 1] = key
    trim_home_book_cache()
end

-- Default extraction bounds before layout supplies a cover's actual size.
local function home_cover_specs()
    local Screen = require("device").screen
    local short_side = math.min(Screen:getWidth(), Screen:getHeight())
    local long_side = math.max(Screen:getWidth(), Screen:getHeight())
    return { max_cover_w = math.floor(short_side / 3), max_cover_h = math.floor(long_side / 3) }
end

-- cover_sizetag stores the native (original) image dimensions, e.g. "600x900".
-- cover_w/cover_h are the actual cached bitmap size after scaling to fit whatever
-- spec was used at extraction time. To decide whether a larger home-screen spec
-- would produce a bigger result: compute what getCachedCoverSize would yield at
-- our spec, then compare that against what is currently cached.
local function home_cover_too_small(bi, specs)
    if not bi.cover_w or not bi.cover_h then return true end
    local img_w, img_h = tostring(bi.cover_sizetag or ""):match("(%d+)x(%d+)")
    if not img_w then return true end
    img_w, img_h = tonumber(img_w), tonumber(img_h)
    local max_w, max_h = specs.max_cover_w, specs.max_cover_h
    local target_w, target_h
    if img_w > max_w or img_h > max_h then
        local scale = math.min(max_w / img_w, max_h / img_h)
        target_w = math.floor(img_w * scale)
        target_h = math.floor(img_h * scale)
    else
        target_w, target_h = img_w, img_h
    end
    return target_w > bi.cover_w or target_h > bi.cover_h
end

local _pending_cover_upgrade_paths = {}
local _cover_upgrade_scheduled = false
local _cover_upgrade_consumers = {}
-- Paths currently being processed by an extractInBackground() subprocess we
-- launched. A book mid-extraction still reads as "invalid" from the DB (its
-- row isn't written until its turn in the batch completes), so a rebuild that
-- runs while a batch is still in flight must not re-queue books already in
-- that batch -- extractInBackground() unconditionally kills any previous
-- subprocess before starting a new one, so requeuing one slow book partway
-- through a batch was terminating the whole batch and orphaning the rest.
local _inflight_cover_upgrade_paths = {}

-- Takes everything queued in _pending_cover_upgrade_paths and launches a
-- single extractInBackground() batch at each path's requested cover size, then
-- polls until each path's extraction completes (or the subprocess dies),
-- invalidating that book's home-cache entry and notifying the consumers as
-- results land.
local function flush_cover_upgrade_queue()
    _cover_upgrade_scheduled = false
    local pending = _pending_cover_upgrade_paths
    local paths = {}
    for path in pairs(pending) do
        paths[#paths + 1] = path
    end
    _pending_cover_upgrade_paths = {}
    if #paths == 0 then return end

    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok_bim or not BookInfoManager then
        logger.warn("bookinfomanager require failed, cannot upgrade covers")
        for _i, path in ipairs(paths) do _cover_upgrade_consumers[path] = nil end
        return
    end

    -- CoverBrowser owns a single extraction subprocess. Do not let a delayed
    -- home-screen upgrade cancel the file browser's in-flight page batch after
    -- the user has navigated away; those unresolved rows otherwise keep their
    -- loading placeholder until a manual page change creates a new batch.
    if not M.isActiveOnTop() then
        for _i, path in ipairs(paths) do
            invalidate_home_book_cache(path)
            _cover_upgrade_consumers[path] = nil
        end
        mark_home_rebuild_needed(false, false)
        return
    end
    if BookInfoManager:isExtractingInBackground() then
        for _i, path in ipairs(paths) do
            _pending_cover_upgrade_paths[path] = pending[path]
        end
        _cover_upgrade_scheduled = true
        require("ui/uimanager"):scheduleIn(1, flush_cover_upgrade_queue)
        return
    end

    local files = {}
    for _i, path in ipairs(paths) do
        files[#files + 1] = { filepath = path, cover_specs = pending[path] }
        _inflight_cover_upgrade_paths[path] = true
    end

    local launched = BookInfoManager:extractInBackground(files)
    if not launched then
        for _i, path in ipairs(paths) do
            _inflight_cover_upgrade_paths[path] = nil
            _cover_upgrade_consumers[path] = nil
        end
        return
    end

    local waiting = {}
    for _i, path in ipairs(paths) do
        waiting[path] = true
    end
    local needs_full_rebuild = false

    -- Poll per-path completion (mirrors covermenu.lua's items_update_action)
    -- rather than waiting for the whole subprocess to exit: a single batch can
    -- contain several books, and if one of them crashes the subprocess, the
    -- books already extracted before the crash must still get picked up
    -- instead of being stuck waiting on the ones that never finished.
    local function poll()
        local is_still_extracting = BookInfoManager:isExtractingInBackground()
        for path in pairs(waiting) do
            local bi = BookInfoManager:getBookInfo(path, false)
            if bi and bi.cover_fetched then
                waiting[path] = nil
                _inflight_cover_upgrade_paths[path] = nil
                invalidate_home_book_cache(path)
                local consumers = _cover_upgrade_consumers[path]
                _cover_upgrade_consumers[path] = nil
                if consumers and consumers.full then needs_full_rebuild = true end
                if consumers and consumers.strip then
                    if M.isActiveOnTop()
                            and _home_menu and _home_menu._zen_home_notify_strip_cover then
                        _home_menu:_zen_home_notify_strip_cover(path)
                    else
                        mark_home_rebuild_needed(false, false)
                    end
                end
            end
        end
        if next(waiting) and is_still_extracting then
            UIManager:scheduleIn(1, poll)
        else
            -- Either fully done, or the subprocess is gone and some paths
            -- never got their turn (crashed/killed). Release those so a
            -- future visit to the home screen can requeue and retry them.
            for path in pairs(waiting) do
                _inflight_cover_upgrade_paths[path] = nil
                _cover_upgrade_consumers[path] = nil
            end
            if needs_full_rebuild and M.isActiveOnTop()
                    and _home_menu and _home_menu._home_rebuild then
                _home_menu:_home_rebuild()
            elseif needs_full_rebuild then
                mark_home_rebuild_needed(false, false)
            end
        end
    end
    UIManager:scheduleIn(1, poll)
end

-- Merge queued size requests without restarting an in-flight extraction.
local function queue_cover_upgrade(path, consumer, specs)
    if type(path) ~= "string" or path == "" then return end
    local consumers = _cover_upgrade_consumers[path]
    if not consumers then
        consumers = {}
        _cover_upgrade_consumers[path] = consumers
    end
    consumers[consumer == "strip" and "strip" or "full"] = true
    if _inflight_cover_upgrade_paths[path] then return end
    specs = specs or home_cover_specs()
    local queued = _pending_cover_upgrade_paths[path]
    if queued then
        queued.max_cover_w = math.max(queued.max_cover_w, specs.max_cover_w)
        queued.max_cover_h = math.max(queued.max_cover_h, specs.max_cover_h)
    else
        _pending_cover_upgrade_paths[path] = specs
    end
    if not _cover_upgrade_scheduled then
        _cover_upgrade_scheduled = true
        require("ui/uimanager"):scheduleIn(0.3, flush_cover_upgrade_queue)
    end
end

local function refresh_shared_state()
    if _zen_plugin then
        _zen_shared = SharedState.restore(_zen_plugin) or _zen_shared
    end
    return _zen_shared
end

local DEFAULT_ROW_ORDER = {
    "datetime",
    "featured",
    "stats_triplet",
    "reading_goals",
    "strip",
    "quotes",
}

local DEFAULT_ROW_ENABLED = {
    featured = true,
    quotes = true,
    stats_triplet = true,
    strip = true,
}

local DEFAULT_FEATURED_PROGRESS_META = {
    left = "percent",
    right = "total_pages",
}

local FEATURED_TEXT_STYLE_DEFAULTS = {
    title = { font_face = "default", font_size = 11, bold = true },
    author = { font_face = "default", font_size = 9, bold = false },
    series = { font_face = "default", font_size = 7, bold = false },
    description = { font_face = "default", font_size = 16, bold = false },
    progress = { font_face = "default", font_size = 7, bold = false },
}

local function normalize_order(order)
    if order == "reverse" then return "reverse" end
    return "default"
end

local function ensure_featured_text_style(mcfg, key)
    if type(mcfg.text_styles) ~= "table" then mcfg.text_styles = {} end
    local defaults = FEATURED_TEXT_STYLE_DEFAULTS[key]
    if type(defaults) ~= "table" then return nil end
    if type(mcfg.text_styles[key]) ~= "table" then mcfg.text_styles[key] = {} end
    local style = mcfg.text_styles[key]
    if type(style.font_face) ~= "string" or style.font_face == "" then
        style.font_face = defaults.font_face
    end
    local size = tonumber(style.font_size)
    if not size then
        style.font_size = defaults.font_size
    else
        style.font_size = math.max(6, math.min(40, math.floor(size + 0.5)))
    end
    if style.bold == nil then
        style.bold = defaults.bold
    else
        style.bold = style.bold == true
    end
    return style
end

local function ensure_featured_text_styles(mcfg)
    for key, defaults in pairs(FEATURED_TEXT_STYLE_DEFAULTS) do
        if defaults then ensure_featured_text_style(mcfg, key) end
    end
end

local function ensure_module_cfg(dcfg, module_id)
    if type(dcfg.modules) ~= "table" then dcfg.modules = {} end
    if type(dcfg.modules[module_id]) ~= "table" then dcfg.modules[module_id] = {} end
    local mcfg = dcfg.modules[module_id]
    mcfg.show_module_title = nil
    return mcfg
end

local function ensure_featured_module_cfg(dcfg, module_id)
    local mcfg = ensure_module_cfg(dcfg, module_id)
    mcfg.order = normalize_order(mcfg.order)
    if mcfg.show_author == nil then mcfg.show_author = true end
    if mcfg.show_series == nil then mcfg.show_series = true end
    if mcfg.show_description == nil then mcfg.show_description = true end
    if mcfg.show_progress == nil then mcfg.show_progress = true end
    if mcfg.wrap_description_text == nil then mcfg.wrap_description_text = false end
    if mcfg.justify_description_text == nil then mcfg.justify_description_text = false end
    if mcfg.format_description_html == nil then mcfg.format_description_html = false end
    if mcfg.interactive == nil then mcfg.interactive = true end
    if mcfg.show_status_bar == nil then mcfg.show_status_bar = false end
    if mcfg.status_bar_show_bottom_border == nil then mcfg.status_bar_show_bottom_border = true end
    if mcfg.status_bar_bold_text == nil then mcfg.status_bar_bold_text = true end
    ensure_featured_text_styles(mcfg)
    if type(mcfg.progress_meta) ~= "table" then mcfg.progress_meta = {} end
    if mcfg.progress_meta.left == nil and mcfg.progress_meta.right == nil then
        for key, side in pairs(mcfg.progress_meta) do
            if side == "left" and mcfg.progress_meta.left == nil then
                mcfg.progress_meta.left = key
            elseif side == "right" and mcfg.progress_meta.right == nil then
                mcfg.progress_meta.right = key
            end
        end
    end
    for side, metric in pairs(DEFAULT_FEATURED_PROGRESS_META) do
        if mcfg.progress_meta[side] ~= "total_pages"
                and mcfg.progress_meta[side] ~= "current_total"
                and mcfg.progress_meta[side] ~= "percent"
                and mcfg.progress_meta[side] ~= "time_left"
                and mcfg.progress_meta[side] ~= "off" then
            mcfg.progress_meta[side] = metric
        end
    end
    return mcfg
end

local function ensure_strip_module_cfg(dcfg)
    local mcfg = ensure_module_cfg(dcfg, "strip")
    mcfg.order = normalize_order(mcfg.order)
    if mcfg.interactive == nil then mcfg.interactive = true end
    if mcfg.two_rows == nil then mcfg.two_rows = false end
    if type(mcfg.count) ~= "number" then mcfg.count = mcfg.two_rows and 8 or 4 end
    if mcfg.two_rows then
        if mcfg.count < 2 then mcfg.count = 2 end
        if mcfg.count > 10 then mcfg.count = 10 end
    else
        if mcfg.count < 3 then mcfg.count = 3 end
        if mcfg.count > 5 then mcfg.count = 5 end
    end
    if mcfg.show_strip_titles == nil then mcfg.show_strip_titles = false end
    if mcfg.center_books == nil then mcfg.center_books = false end
    return mcfg
end

local function ensure_home_widget_cfg(dcfg)
    local datetime = ensure_module_cfg(dcfg, "datetime")
    datetime.automatic_font_size = datetime.automatic_font_size ~= false
    if type(datetime.text_styles) ~= "table" then datetime.text_styles = {} end
    for key, default_size in pairs(DEFAULT_DATETIME_FONT_SIZES) do
        if type(datetime.text_styles[key]) ~= "table" then
            datetime.text_styles[key] = {}
        end
        local style = datetime.text_styles[key]
        if type(style.font_face) ~= "string" or style.font_face == "" then
            style.font_face = "default"
        end
        local minimum = key == "time" and 8 or 6
        local maximum = key == "time" and 160 or 80
        style.font_size = math.max(minimum, math.min(
            maximum, math.floor((tonumber(style.font_size) or default_size) + 0.5)
        ))
    end
    local featured = ensure_featured_module_cfg(dcfg, "featured")
    if type(featured.default_source) ~= "table" then
        featured.default_source = { kind = "recent" }
    end
    if type(featured.path) ~= "string" then featured.path = nil end
    local stats_triplet = ensure_module_cfg(dcfg, "stats_triplet")
    if stats_triplet.stat_style ~= "outline" and stats_triplet.stat_style ~= "none" then
        stats_triplet.stat_style = "divider"
    end
    local stats_font_size = tonumber(stats_triplet.font_size)
        or tonumber(stats_triplet.font_scale) and DEFAULT_STATS_FONT_SIZE * stats_triplet.font_scale / 100
    local stats_font_override = stats_triplet.font_size_override == true
    stats_triplet.font_size = stats_font_size
        and (stats_font_override or stats_font_size ~= DEFAULT_STATS_FONT_SIZE)
        and math.max(8, math.min(MAX_STATS_FONT_SIZE, math.floor(stats_font_size + 0.5))) or nil
    stats_triplet.font_size_override = stats_triplet.font_size and true or nil
    stats_triplet.automatic_font_size = stats_triplet.automatic_font_size ~= false
    stats_triplet.max_font_size = math.max(8, math.min(MAX_STATS_FONT_SIZE, math.floor(
        (tonumber(stats_triplet.max_font_size) or DEFAULT_STATS_MAX_FONT_SIZE) + 0.5
    )))
    stats_triplet.max_font_size_override = nil
    stats_triplet.font_scale = nil
    local reading_goals = ensure_module_cfg(dcfg, "reading_goals")
    local goals_font_size = tonumber(reading_goals.font_size)
    local goals_font_override = reading_goals.font_size_override == true
    reading_goals.font_size = goals_font_size and (goals_font_override or goals_font_size ~= DEFAULT_GOALS_FONT_SIZE)
        and math.max(8, math.min(32, math.floor(goals_font_size + 0.5))) or nil
    reading_goals.font_size_override = reading_goals.font_size and true or nil
    ensure_module_cfg(dcfg, "quotes")
    ensure_strip_module_cfg(dcfg)
end

local function load_zen_config()
    if _zen_plugin and type(_zen_plugin.config) == "table" then
        return _zen_plugin.config
    end
    local ok, cfg = pcall(ConfigManager.load)
    if ok and type(cfg) == "table" then
        return cfg
    end
end

local function ensure_home_cfg()
    local dcfg = PresetStore.getSettings("home")
    if type(dcfg) ~= "table" or next(dcfg) == nil then
        dcfg = HomePresets.defaultHomePage()
    end
    HomePresets.ensurePresetState(dcfg)
    HomePresets.normalizeFeaturedConfig(dcfg)
    HomePresets.normalizeStripConfig(dcfg)
    if type(HomePresets.normalizeLayoutGrid) == "function" then
        HomePresets.normalizeLayoutGrid(dcfg)
    end

    dcfg.rows = Registry.normalizeRows(dcfg.rows, DEFAULT_ROW_ORDER, DEFAULT_ROW_ENABLED)

    if dcfg.show_status_bar == nil then dcfg.show_status_bar = true end
    dcfg.edit_mode = dcfg.edit_mode == true
    dcfg.font_size = nil
    dcfg.font_size_override = nil

    if type(dcfg.middle_stats_triplet) ~= "table" then
        dcfg.middle_stats_triplet = { "today_pages", "today_duration", "streak" }
    end

    dcfg.goals = ReadingGoals.normalize(dcfg.goals)

    if type(dcfg.quotes) ~= "table" then dcfg.quotes = {} end
    if dcfg.quotes.show_author == nil then dcfg.quotes.show_author = true end
    if dcfg.quotes.show_title == nil then dcfg.quotes.show_title = true end
    if type(dcfg.quotes.sources) ~= "table" then
        dcfg.quotes.sources = { default = true }
    end
    if dcfg.quotes.rotation ~= "refresh" then dcfg.quotes.rotation = "daily" end
    dcfg.quotes.automatic_font_size = dcfg.quotes.automatic_font_size == true
    dcfg.quotes.max_font_size = math.max(
        4, math.min(32, tonumber(dcfg.quotes.max_font_size) or 14)
    )
    dcfg.quotes.use_home_font_size = nil
    local quote_font_size = tonumber(dcfg.quotes.font_size)
    local quote_font_override = dcfg.quotes.font_size_override == true
    if quote_font_size == 18 and not quote_font_override then quote_font_size = nil end
    dcfg.quotes.font_size = quote_font_size and (quote_font_override or quote_font_size ~= 12)
        and math.max(4, math.min(32, math.floor(quote_font_size + 0.5))) or nil
    dcfg.quotes.font_size_override = dcfg.quotes.font_size and true or nil

    -- Per-widget home settings.
    for _i, comp in ipairs(Registry.list()) do
        ensure_module_cfg(dcfg, comp.id)
    end
    ensure_home_widget_cfg(dcfg)

    return dcfg
end

local function resolve_rows(dcfg)
    local rows_cfg = dcfg.rows or {}
    local order = rows_cfg.order or DEFAULT_ROW_ORDER
    local enabled = rows_cfg.enabled or {}
    local modules = type(dcfg.modules) == "table" and dcfg.modules or {}

    local seen = {}
    local out = {}
    local selected_count = 0

    local function try_push(id)
        if seen[id] then return end
        if enabled[id] ~= true then return end
        seen[id] = true
        selected_count = selected_count + 1
        local comp = Registry.get(id)
        if not comp then return end
        local units = Registry.sizeUnits and Registry.sizeUnits(comp, modules[id]) or 2
        table.insert(out, setmetatable({ _home_units = units }, { __index = comp }))
    end

    for _i, id in ipairs(order) do
        try_push(id)
    end

    for _i, comp in ipairs(Registry.list()) do
        try_push(comp.id)
    end

    if #out == 0 and selected_count == 0 then
        for _i, id in ipairs(DEFAULT_ROW_ORDER) do
            if DEFAULT_ROW_ENABLED[id] then
                local comp = Registry.get(id)
                local units = comp and (Registry.sizeUnits
                    and Registry.sizeUnits(comp, modules[id]) or 2) or 0
                if comp then
                    table.insert(out, setmetatable(
                        { _home_units = units }, { __index = comp }
                    ))
                end
            end
        end
    end

    return out
end

local function collect_stats_fields(rows, dcfg)
    local fields = {}
    local needs_stats = false

    local function add(name)
        fields[name] = true
        needs_stats = true
    end

    for _i, comp in ipairs(rows or {}) do
        local id = comp and comp.id
        if id == "stats_triplet" then
            local triplet = dcfg.middle_stats_triplet or { "today_pages", "today_duration", "streak" }
            local added = false
            for _j, field in ipairs(triplet) do
                if field == "today_pages" or field == "today_duration"
                        or field == "week_pages" or field == "week_duration"
                        or field == "streak" then
                    add(field)
                    added = true
                else
                    add("today_pages")
                    added = true
                end
            end
            if not added then add("today_pages") end
        elseif id == "reading_goals" then
            local goals = dcfg.goals or {}
            local metrics = type(goals.metrics) == "table" and goals.metrics or {}
            local periods = type(goals.periods) == "table" and goals.periods
                or { goals.period == "weekly" and "weekly" or "daily" }
            for _j, period in ipairs(periods) do
                add(period == "weekly" and "week_pages"
                    or period == "monthly" and "month_pages"
                    or period == "yearly" and "year_pages" or "today_pages")
                add(period == "weekly" and "week_duration"
                    or period == "monthly" and "month_duration"
                    or period == "yearly" and "year_duration" or "today_duration")
                if metrics[period] == "books" then
                    if period == "monthly" then
                        add("finished_this_month")
                    elseif period == "yearly" then
                        add("finished_this_year")
                    end
                end
            end
        end
    end

    if not needs_stats then return nil end
    return fields
end

local function stats_fields_key(fields)
    if type(fields) ~= "table" then return "" end
    local order = {
        "today_pages", "today_duration", "week_pages", "week_duration",
        "month_pages", "month_duration",
        "year_pages", "year_duration", "finished_this_month", "finished_this_year", "streak",
    }
    local out = {}
    for _i, key in ipairs(order) do
        if fields[key] then out[#out + 1] = key end
    end
    return table.concat(out, ",")
end

local function build_data_provider(cfg, dcfg, strip_page_state)
    local provider = {}
    local dataset = get_home_dataset()
    local cover_badges = type(cfg) == "table" and type(cfg.browser_cover_badges) == "table"
        and cfg.browser_cover_badges or {}
    local wants_favorite_badge = cover_badges.show_favorite_badge == true
    local stats_cached = nil
    local stats_cached_key = nil
    local strip_offsets = copy_home_strip_pages(strip_page_state)
    local book_cache_hits = 0
    local book_cache_misses = 0
    local book_lookup_ms = 0
    local quote_select_ms = 0
    local quote_annotation_ms = 0
    local quote_annotation_books = 0
    local quote_annotation_cache_hits = 0
    local quote_annotation_cache_misses = 0
    local quote_sidecar_cache_hits = 0
    local quote_sidecar_cache_misses = 0
    local quote_state_writes = 0
    local quote_layout_ms = 0
    local quote_layout_cache_hits = 0
    local quote_layout_cache_misses = 0
    local quote_layout_probes = 0
    local tbr_index
    local tbr_index_checked = false
    local current_quote

    local function is_widget_visible(widget_id)
        if type(widget_id) ~= "string" or widget_id == "" then return false end
        for _i, comp in ipairs(resolve_rows(dcfg or {})) do
            if comp.id == widget_id then return true end
        end
        return false
    end

    local function featured_widget_for_source(source)
        local mcfg = dcfg and dcfg.modules and dcfg.modules.featured or {}
        local configured = HomePresets.featuredSourceKey(mcfg.default_source)
        local requested = source == "currently_reading" and "recently_read" or source
        if requested == configured then return "featured" end
    end

    local function get_stats(fields)
        if stats_cached then return stats_cached end
        local key = stats_fields_key(fields)
        if _home_stats_cache.value and _home_stats_cache.key == key
                and os.time() < _home_stats_cache.expires_at then
            stats_cached = _home_stats_cache.value
            return stats_cached
        end
        local ok_stats, StatsDB = pcall(require, "common/db_stats")
        if ok_stats and StatsDB and type(StatsDB.queryHomeStats) == "function" then
            stats_cached = StatsDB.queryHomeStats(fields) or {}
        elseif ok_stats and StatsDB and type(StatsDB.queryStats) == "function" then
            stats_cached = StatsDB.queryStats() or {}
        else
            stats_cached = {}
        end
        _home_stats_cache.key = key
        _home_stats_cache.value = stats_cached
        _home_stats_cache.expires_at = os.time() + HOME_STATS_TTL
        if fields and (fields.finished_this_month or fields.finished_this_year) then
            local ok_library, LibraryDB = pcall(require, "common/db_library")
            local counts = ok_library and LibraryDB and LibraryDB.getBookCounts
                and LibraryDB.getBookCounts() or {}
            stats_cached.finished_this_month = fields.finished_this_month
                and (counts.finished_this_month or 0) or 0
            stats_cached.finished_this_year = fields.finished_this_year
                and (counts.finished_this_year or 0) or 0
        end
        return stats_cached
    end

    local function get_history()
        if dataset.history then
            return dataset.history
        end
        dataset.history = {}
        local ok_rh, ReadHistory = pcall(require, "readhistory")
        if not ok_rh or not ReadHistory then
            return dataset.history
        end

        if type(ReadHistory.reload) == "function" then
            pcall(ReadHistory.reload, ReadHistory, false)
        end

        local hist = ReadHistory.hist or {}
        local lfs = require("libs/libkoreader-lfs")
        local paths = require("common/paths")
        local function is_rakuyomi_history_path(path)
            if path:lower():sub(-4) ~= ".cbz" then return false end
            local Rakuyomi = rawget(_G, "__ZEN_UI_RAKUYOMI")
            if not (type(Rakuyomi) == "table"
                    and type(Rakuyomi.isChapterFile) == "function") then
                return false
            end
            local ok_chapter, is_chapter = pcall(Rakuyomi.isChapterFile, path)
            return ok_chapter and is_chapter == true
        end

        for _i, entry in ipairs(hist) do
            local raw_path = entry and entry.file
            local path = type(raw_path) == "string" and paths.normPath(raw_path) or nil
            if path ~= nil
                and path ~= ""
                and lfs.attributes(path, "mode") == "file"
                and (paths.isInHomeDir(path) or is_rakuyomi_history_path(path)) then
                table.insert(dataset.history, path)
                if #dataset.history >= HOME_STRIP_MAX_BOOKS then break end
            end
        end

        return dataset.history
    end

    local function populate_time_left(book)
        if not book or book._zen_time_left_loaded then return end
        book._zen_time_left_loaded = true
        if not book._zen_has_sidecar then return end

        local ok_stats, StatsDB = pcall(require, "common/db_stats")
        if not (ok_stats and StatsDB and type(StatsDB.queryBookAveragePageTime) == "function") then
            return
        end
        local avg_time, db_pages = StatsDB.queryBookAveragePageTime(
            book.path, book._zen_partial_md5_checksum)
        local db_total_pages = tonumber(db_pages)
        local total_pages = db_total_pages and db_total_pages > 0 and db_total_pages
            or tonumber(book._zen_time_left_pages)
        local current_page = book.current_page
        if total_pages and book.percent_finished then
            current_page = math.floor(total_pages * book.percent_finished + 0.5)
            if book.percent_finished > 0 and current_page < 1 then current_page = 1 end
            if current_page > total_pages then current_page = total_pages end
        end
        if avg_time and avg_time > 0 and total_pages and current_page
                and current_page < total_pages then
            book.time_left_secs = math.floor((total_pages - current_page) * avg_time)
        end
    end

    local function bookinfo_without_cover(info)
        if type(info) ~= "table" then return false end
        local copy = {}
        for key, value in pairs(info) do
            if key ~= "cover_bb" then copy[key] = value end
        end
        return copy
    end

    local function compact_status_data(data)
        if type(data) ~= "table" then return nil end
        local compact = {
            status = data.status,
            percent_finished = data.percent_finished,
            effective_status = data.effective_status,
            pages = data.pages,
            has_sidecar = data.been_opened == true,
        }
        local doc = data.doc_settings
        if not doc then return compact end
        compact.has_sidecar = true
        local stats = doc:readSetting("stats")
        compact.pages = compact.pages or (stats and stats.pages)
        compact.partial_md5_checksum = doc:readSetting("partial_md5_checksum")
        if doc:readSetting("pagemap_use_page_labels") == true then
            compact.stable_current_label = doc:readSetting("pagemap_current_page_label")
            compact.stable_last_label = doc:readSetting("pagemap_last_page_label")
            compact.stable_pages = tonumber(doc:readSetting("pagemap_doc_pages"))
                or tonumber(compact.stable_last_label)
            compact.stable_current_page = tonumber(compact.stable_current_label)
            if not compact.stable_current_page and compact.stable_pages
                    and compact.percent_finished then
                compact.stable_current_page = math.floor(
                    compact.stable_pages * compact.percent_finished + 0.5)
            end
            if compact.stable_current_page and compact.stable_pages then
                if compact.percent_finished and compact.percent_finished > 0
                        and compact.stable_current_page < 1 then
                    compact.stable_current_page = 1
                end
                if compact.stable_current_page > compact.stable_pages then
                    compact.stable_current_page = compact.stable_pages
                end
            end
        end
        return compact
    end

    local function get_book(path, need_time_left, metadata_only)
        if not path then return nil end
        local started_at = os.clock()
        local cache_key = get_home_book_cache_key(path)
        local cached = _home_book_cache[cache_key]
        if cached and (metadata_only or cached._zen_cover_loaded ~= false) then
            book_cache_hits = book_cache_hits + 1
            if need_time_left then populate_time_left(cached) end
            book_lookup_ms = book_lookup_ms + (os.clock() - started_at) * 1000
            return clone_cached_book(cached, false, not metadata_only)
        elseif cached then
            remove_home_book_cache_entry(cache_key)
            for i = #_home_book_cache_order, 1, -1 do
                if _home_book_cache_order[i] == cache_key then
                    table.remove(_home_book_cache_order, i)
                end
            end
        end
        book_cache_misses = book_cache_misses + 1
        local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
        local cover_bb, title, authors, series, series_index, pages, description
        local book_info
        local has_real_cover = false
        local cover_pending = false
        local cover_loaded = metadata_only ~= true
        if ok_bim and BookInfoManager then
            local bi
            if metadata_only and type(DecodeCache.getFreshMetadata) == "function" then
                bi = DecodeCache:getFreshMetadata(path, now(), 30)
            end
            bi = bi or BookInfoManager:getBookInfo(path, not metadata_only)
            book_info = bi
            if bi then
                title = bi.title
                authors = bi.authors
                series = bi.series
                series_index = bi.series_index
                pages = bi.pages
                description = bi.description
            end
            local ok_rakuyomi, Rakuyomi = pcall(require, "modules/filebrowser/patches/rakuyomi")
            local metadata = ok_rakuyomi and type(Rakuyomi.getMetadata) == "function"
                and Rakuyomi.getMetadata(path) or nil
            if metadata then
                title = metadata.title or title
                authors = metadata.authors or authors
                series = metadata.series or series
                series_index = metadata.series_index or series_index
                description = metadata.description or description
                if bi and type(BookInfoManager.setBookInfoProperties) == "function" then
                    pcall(BookInfoManager.setBookInfoProperties,
                        BookInfoManager, path, metadata)
                end
            end
            has_real_cover = not not (bi and bi.cover_fetched and bi.has_cover
                and not bi.ignore_cover)
            cover_pending = has_real_cover
                or not not (bi and not bi.cover_fetched and not bi.ignore_cover)
            cover_loaded = not metadata_only
            if metadata_only and bi and bi.cover_bb then
                bi.cover_bb:free()
                bi.cover_bb = nil
            end
            if not metadata_only and bi and bi.cover_bb and has_real_cover then
                cover_bb = bi.cover_bb:copy()
                bi.cover_bb:free()
                bi.cover_bb = nil
                -- Cached cover may be too small (e.g. extracted for a small
                -- list row); queue a background re-extraction at full size
                -- and use today's (possibly upscaled) cover in the meantime.
                if home_cover_too_small(bi, home_cover_specs()) then
                    queue_cover_upgrade(path, "full")
                end
            elseif not metadata_only and bi and (bi.cover_fetched or bi.ignore_cover) then -- luacheck: ignore 542
                if bi.cover_bb then bi.cover_bb:free() end
                bi.cover_bb = nil
                -- Extraction was already tried and found no usable cover (or the
                -- user chose to ignore it): nothing to gain from retrying.
            elseif not metadata_only then
                if bi and bi.cover_bb then bi.cover_bb:free() end
                if bi then bi.cover_bb = nil end
                -- Never extracted at all (fresh cache, or only metadata was ever
                -- fetched): queue a first extraction at home-screen size instead
                -- of waiting for the file browser to stumble onto this book.
                queue_cover_upgrade(path, "full")
            elseif cover_pending and not has_real_cover then
                queue_cover_upgrade(path, "strip")
            end
        end
        local time_left_pages = pages

        local pct = nil
        local status = nil
        local current_page = nil
        local stable_pages = nil
        local stable_current_page = nil
        local stable_current_label = nil
        local stable_last_label = nil
        local doc_settings = nil
        local status_data
        local partial_md5_checksum = nil
        if metadata_only then
            status_data = dataset.status_data[path]
            if not status_data then
                local BookList = package.loaded["ui/widget/booklist"]
                if BookList and type(BookList.hasBookInfoCache) == "function"
                        and BookList.hasBookInfoCache(path) then
                    status_data = compact_status_data(BookList.getBookInfo(path))
                    dataset.status_data[path] = status_data
                end
            end
            if status_data then
                pct = status_data.percent_finished
                status = status_data.status
                time_left_pages = status_data.pages or time_left_pages
                if not pages then pages = status_data.pages end
                stable_pages = status_data.stable_pages
                stable_current_page = status_data.stable_current_page
                stable_current_label = status_data.stable_current_label
                stable_last_label = status_data.stable_last_label
                partial_md5_checksum = status_data.partial_md5_checksum
            end
        else
            local ok_ds, DocSettings = pcall(require, "docsettings")
            if ok_ds and DocSettings and DocSettings:hasSidecarFile(path) then
                local ok_doc, doc = pcall(DocSettings.open, DocSettings, path)
                if ok_doc then doc_settings = doc end
            end
        end
        if doc_settings then
            pct = doc_settings:readSetting("percent_finished")
            local summary = doc_settings:readSetting("summary")
            status = summary and summary.status
            local stats = doc_settings:readSetting("stats")
            if not time_left_pages then
                time_left_pages = stats and stats.pages
            end
            if not pages then pages = time_left_pages end
            local total_pages = tonumber(time_left_pages)
            if total_pages and pct then
                current_page = math.floor(total_pages * pct + 0.5)
                if pct > 0 and current_page < 1 then current_page = 1 end
                if current_page > total_pages then current_page = total_pages end
            end
            partial_md5_checksum = doc_settings:readSetting("partial_md5_checksum")
            if doc_settings:readSetting("pagemap_use_page_labels") == true then
                stable_current_label = doc_settings:readSetting("pagemap_current_page_label")
                stable_last_label = doc_settings:readSetting("pagemap_last_page_label")
                stable_pages = tonumber(doc_settings:readSetting("pagemap_doc_pages"))
                    or tonumber(stable_last_label)
                stable_current_page = tonumber(stable_current_label)
                if not stable_current_page and stable_pages and pct then
                    stable_current_page = math.floor(stable_pages * pct + 0.5)
                end
                if stable_current_page and stable_pages then
                    if pct and pct > 0 and stable_current_page < 1 then stable_current_page = 1 end
                    if stable_current_page > stable_pages then stable_current_page = stable_pages end
                end
            end
        elseif pct then
            local total_pages = tonumber(time_left_pages)
            if total_pages then
                current_page = math.floor(total_pages * pct + 0.5)
                if pct > 0 and current_page < 1 then current_page = 1 end
                if current_page > total_pages then current_page = total_pages end
            end
        end
        pages = stable_pages or utils.getStablePageCount(
            path, pages or time_left_pages, {
                doc_settings = doc_settings,
                sidecar_checked = true,
                book_info = book_info,
                book_info_checked = true,
            })
        local computed_status
        if metadata_only then
            computed_status = status_data and status_data.effective_status
                or book_status.getEffectiveStatus(status, pct)
        else
            computed_status = book_status.getComputedStatus(
                path, status, pct, doc_settings
            )
        end
        local display_status = book_status.getDisplayStatus
            and book_status.getDisplayStatus(path, computed_status) or computed_status

        if not title or title == "" then
            title = (path:match("([^/]+)$") or path):gsub("%.[^%.]+$", "")
        end

        local book = {
            path = path,
            title = title,
            authors = authors or "",
            series = series,
            series_index = tonumber(series_index),
            cover_bb = cover_bb,
            cover_w = book_info and tonumber(book_info.cover_w) or nil,
            cover_h = book_info and tonumber(book_info.cover_h) or nil,
            has_real_cover = has_real_cover,
            is_cover_pending = metadata_only and cover_pending or nil,
            bookinfo = bookinfo_without_cover(book_info),
            percent = pct or 0,
            percent_finished = pct,
            status = display_status,
            pages = pages,
            current_page = current_page,
            time_left_secs = nil,
            stable_pages = stable_pages or pages,
            stable_current_page = stable_current_page,
            stable_current_label = stable_current_label,
            stable_last_label = stable_last_label,
            description = description,
            _zen_has_sidecar = doc_settings ~= nil
                or status_data and status_data.has_sidecar == true,
            _zen_partial_md5_checksum = partial_md5_checksum,
            _zen_time_left_pages = time_left_pages,
            _zen_cover_loaded = cover_loaded,
        }
        if need_time_left then populate_time_left(book) end
        cache_home_book(cache_key, book)
        book_lookup_ms = book_lookup_ms + (os.clock() - started_at) * 1000
        return book
    end

    local function get_tbr_index()
        if tbr_index_checked then return tbr_index end
        tbr_index_checked = true
        local ok_index, index = pcall(require, "common/tbr_index")
        if ok_index and index then tbr_index = index end
        return tbr_index
    end

    local function tbr_sort_options(order_key, exclude_featured)
        local group_view = cfg and cfg.group_view or {}
        local detail_collate = group_view.detail_collate or {}
        local detail_reverse = group_view.detail_reverse or {}
        local collate_tbl = detail_collate.to_be_read or {}
        local reverse_tbl = detail_reverse.to_be_read or {}
        local reverse = reverse_tbl.to_be_read == true
        if normalize_order(order_key) == "reverse" then reverse = not reverse end
        local options = {
            collate = collate_tbl.to_be_read or "title",
            reverse = reverse,
            include_new = book_status.includeNewInTBREnabled(),
        }
        local index = get_tbr_index()
        if exclude_featured and index
                and is_widget_visible(featured_widget_for_source("to_be_read")) then
            local featured = index.getPage(0, 1, {
                collate = options.collate,
                reverse = reverse_tbl.to_be_read == true,
                include_new = options.include_new,
            })
            options.exclude_path = featured[1]
        end
        return options
    end

    local function get_tbr_paths(limit)
        local max_books = math.min(HOME_STRIP_MAX_BOOKS,
            math.max(1, math.floor(tonumber(limit) or HOME_STRIP_MAX_BOOKS)))
        local index = get_tbr_index()
        if index then
            local current_revision = index.getRevision()
            if dataset.tbr and dataset.tbr_revision == current_revision
                    and dataset.tbr_limit == max_books then
                return dataset.tbr
            end
            dataset.tbr = index.getPage(0, max_books, tbr_sort_options("default", false))
            dataset.tbr_revision = index.getRevision()
            dataset.tbr_limit = max_books
            return dataset.tbr
        end
        dataset.tbr = {}
        return dataset.tbr
    end

    local function get_effective_status(path)
        local cached = dataset.effective_status[path]
        if cached then return cached end
        local loaded_status = type(book_status.getFileStatusData) == "function"
            and book_status.getFileStatusData(path) or nil
        local status = loaded_status and loaded_status.effective_status
            or book_status.getEffectiveStatusFromFile(path)
        dataset.status_data[path] = compact_status_data(loaded_status)
        dataset.effective_status[path] = status
        return status
    end

    local function get_favorite(path)
        local cached = dataset.favorite[path]
        if cached ~= nil then return cached end
        local ok_rc, ReadCollection = pcall(require, "readcollection")
        cached = ok_rc and ReadCollection
            and ReadCollection:isFileInCollections(path, true) == true or false
        dataset.favorite[path] = cached
        return cached
    end

    local function get_paths_by_statuses(statuses, limit)
        local hist = get_history()
        local out = {}
        for _i, path in ipairs(hist) do
            local eff = get_effective_status(path)
            if statuses[eff] then
                table.insert(out, path)
                if #out >= limit then break end
            end
        end
        return out
    end

    local function get_paths_by_status(status_key, limit)
        return get_paths_by_statuses({ [status_key] = true }, limit)
    end

    local function append_unique_paths(dst, src, limit, include_path)
        if type(src) ~= "table" then return end
        local seen = {}
        for _i, path in ipairs(dst) do
            if type(path) == "string" and path ~= "" then
                seen[path] = true
            end
        end
        for _i, path in ipairs(src) do
            if type(path) == "string" and path ~= "" and not seen[path]
                    and (not include_path or include_path(path)) then
                seen[path] = true
                table.insert(dst, path)
                if #dst >= limit then break end
            end
        end
    end

    local function reverse_copy(paths)
        local out = {}
        for i = #paths, 1, -1 do
            out[#out + 1] = paths[i]
        end
        return out
    end

    local function copy_paths(paths)
        local out = {}
        for i = 1, #(paths or {}) do
            out[i] = paths[i]
        end
        return out
    end

    local function collect_paths_for_source(source_key, limit, opts)
        opts = type(opts) == "table" and opts or {}
        local source = source_key
        if source ~= "custom_featured"
                and source ~= "custom_strip"
                and source ~= "currently_reading"
                and source ~= "to_be_read"
                and source ~= "favorites"
                and source ~= "tag" then
            source = "recently_read"
        end
        local lim = math.min(HOME_STRIP_MAX_BOOKS,
            math.max(1, math.floor(tonumber(limit) or HOME_STRIP_MAX_BOOKS)))
        if source == "custom_featured" then
            local mcfg = dcfg and dcfg.modules and dcfg.modules.featured or {}
            local path = type(mcfg.path) == "string" and mcfg.path or nil
            return path and { path } or {}
        end
        if source == "custom_strip" then
            local mcfg = dcfg and dcfg.modules and dcfg.modules.strip or {}
            local sources = type(mcfg.sources) == "table" and mcfg.sources or {}
            local custom = type(sources.custom) == "table" and sources.custom or {}
            local legacy = dcfg and dcfg.modules and dcfg.modules.strip_custom or {}
            local paths = type(custom.paths) == "table" and custom.paths
                or type(legacy.paths) == "table" and legacy.paths or {}
            local out = {}
            for _i, path in ipairs(paths) do
                if type(path) == "string" and path ~= "" then
                    out[#out + 1] = path
                    if #out >= lim then break end
                end
            end
            return out
        end
        if source == "tag" then
            local ok_db, db = pcall(require, "common/db_bookinfo")
            local files = ok_db and db and type(db.getTagBooks) == "function"
                and db.getTagBooks(opts.tag) or {}
            local out = {}
            for _i, path in ipairs(files) do
                out[#out + 1] = path
                if #out >= lim then break end
            end
            return out
        end
        if source == "currently_reading" then
            return get_paths_by_status("reading", lim)
        end
        if source == "favorites" then
            local ok_collection, ReadCollection = pcall(require, "readcollection")
            if not ok_collection or not ReadCollection then return {} end
            local name = ReadCollection.default_collection_name
            local collection = name and ReadCollection.coll and ReadCollection.coll[name]
            if type(collection) ~= "table" then return {} end
            local entries = {}
            for _key, entry in pairs(collection) do
                if type(entry) == "table" and type(entry.file) == "string"
                        and entry.file ~= "" then
                    entries[#entries + 1] = entry
                end
            end
            table.sort(entries, function(a, b)
                local ao = tonumber(a.order) or 0
                local bo = tonumber(b.order) or 0
                if ao == bo then return a.file < b.file end
                return ao < bo
            end)
            local out = {}
            for _i, entry in ipairs(entries) do
                out[#out + 1] = entry.file
                if #out >= lim then break end
            end
            return out
        end
        if source == "to_be_read" then
            local tbr = get_tbr_paths(lim)
            local out = {}
            for _i, path in ipairs(tbr) do
                table.insert(out, path)
                if #out >= lim then break end
            end
            return out
        end
        local statuses = { reading = true }
        if opts.filter_unread ~= true then statuses.new = true end
        if opts.filter_tbr ~= true then statuses.abandoned = true end
        if opts.filter_finished ~= true then statuses.complete = true end
        local recent = get_paths_by_statuses(statuses, lim)
        if opts.reverse_sections == true then
            return reverse_copy(recent)
        end
        return recent
    end

    local function is_recent_source(source)
        return source ~= "custom_featured"
            and source ~= "custom_strip"
            and source ~= "currently_reading"
            and source ~= "to_be_read"
            and source ~= "favorites"
            and source ~= "tag"
    end

    local function get_ordered_paths(source, limit, order_key, opts)
        local reverse = normalize_order(order_key) == "reverse"
        local cache_key = table.concat({
            tostring(source),
            reverse and "reverse" or "default",
            opts and opts.filter_unread == true and "unread" or "",
            opts and opts.filter_tbr == true and "tbr" or "",
            opts and opts.filter_finished == true and "finished" or "",
            opts and opts.tag or "",
            opts and opts.path or "",
        }, "\0")
        local cached = dataset.ordered_paths[cache_key]
        if cached then
            if limit and #cached > limit then
                local limited = {}
                for i = 1, limit do limited[i] = cached[i] end
                return limited
            end
            return cached
        end
        local collect_opts = {}
        for key, value in pairs(opts or {}) do
            collect_opts[key] = value
        end
        if reverse and is_recent_source(source) then
            collect_opts.reverse_sections = true
        end

        local paths = collect_paths_for_source(source, HOME_STRIP_MAX_BOOKS, collect_opts)
        if reverse and not is_recent_source(source)
                and source ~= "custom_featured" and source ~= "custom_strip" then
            paths = reverse_copy(paths)
        end
        dataset.ordered_paths[cache_key] = paths
        if limit and #paths > limit then
            local limited = {}
            for i = 1, limit do limited[i] = paths[i] end
            return limited
        end
        return paths
    end

    function provider:getFeaturedBook(source_key, order_key, metadata_only)
        local path
        local used_index = false
        if source_key == "to_be_read" then
            local index = get_tbr_index()
            if index then
                used_index = true
                local indexed_paths = index.getPage(0, 1,
                    tbr_sort_options(order_key, false))
                path = indexed_paths[1]
            end
        end
        if not used_index then
            local ordered_paths = get_ordered_paths(source_key, 1, order_key)
            path = ordered_paths[1]
        end
        local featured_cfg = dcfg and dcfg.modules and dcfg.modules.featured or {}
        local progress_meta = featured_cfg.progress_meta or {}
        metadata_only = metadata_only == true
        local need_time_left = not metadata_only
            and (progress_meta.left == "time_left" or progress_meta.right == "time_left")
        return get_book(path, need_time_left, metadata_only)
    end

    local function strip_page_offset(total, count, offset, page_delta)
        if total < 1 then return 0 end
        local page_size = math.max(1, math.floor(tonumber(count) or 4))
        local pages = math.ceil(total / page_size)
        local current = (tonumber(offset) or 0) % total
        local page = math.floor(current / page_size)
        page = (page + math.floor(tonumber(page_delta) or 0)) % pages
        return page * page_size
    end

    local function get_strip_paths(source_key, count, order_key, component_id)
        local n = tonumber(count) or 5
        if n < 1 then n = 1 end
        local source = source_key
        if source ~= "custom_strip" and source ~= "currently_reading"
                and source ~= "to_be_read" and source ~= "favorites"
                and source ~= "tag" then
            source = "recently_read"
        end
        local mcfg = dcfg and dcfg.modules and dcfg.modules[component_id] or {}
        if component_id == "strip" then
            local sources = type(mcfg.sources) == "table" and mcfg.sources or {}
            local recent = type(sources.recent) == "table" and sources.recent or {}
            local tag = type(sources.tag) == "table" and sources.tag or {}
            mcfg = {
                filter_unread = recent.filter_unread,
                filter_tbr = recent.filter_tbr,
                filter_finished = recent.filter_finished,
                tag = tag.tag,
            }
        end
        local strip_cache_key = table.concat({
            tostring(component_id or source),
            source,
            normalize_order(order_key),
            tostring(n),
            mcfg.filter_unread == true and "unread" or "",
            mcfg.filter_tbr == true and "tbr" or "",
            mcfg.filter_finished == true and "finished" or "",
            mcfg.tag or "",
        }, "\0")
        local cached = dataset.strip_paths[strip_cache_key]
        if cached then return source, cached, n end
        local paths = copy_paths(get_ordered_paths(source, nil, order_key, {
            filter_unread = source == "recently_read" and mcfg.filter_unread == true,
            filter_tbr = source == "recently_read" and mcfg.filter_tbr == true,
            filter_finished = source == "recently_read" and mcfg.filter_finished == true,
            tag = source == "tag" and mcfg.tag or nil,
        }))

        -- Keep strip distinct from featured only when that featured widget is visible.
        local featured_widget_id = featured_widget_for_source(source)
        local should_dedupe_featured = source ~= "custom_strip" and source ~= "tag"
            and is_widget_visible(featured_widget_id)
        if should_dedupe_featured and #paths > 0 then
            local featured_source = source == "currently_reading" and "recently_read" or source
            local featured_paths = get_ordered_paths(featured_source, nil, order_key)
            local featured_path = featured_paths[1]
            if featured_path and featured_path ~= "" then
                local filtered = {}
                for _i, path in ipairs(paths) do
                    if path ~= featured_path then
                        filtered[#filtered + 1] = path
                    end
                end
                paths = filtered
            end
        end

        -- Keep strip density stable: when a source has too few items, backfill
        -- with recent valid history so the row can still show 3-5 covers.
        if source == "currently_reading" and #paths < n then
            append_unique_paths(paths, get_history(), n)
        end

        dataset.strip_paths[strip_cache_key] = paths
        return source, paths, n
    end

    function provider:getBooksForStripPage(source_key, count, order_key, component_id, page_delta)
        if source_key == "to_be_read" then
            local index = get_tbr_index()
            if index then
                local n = tonumber(count) or 4
                if n < 1 then n = 1 end
                local options = tbr_sort_options(order_key, true)
                local total = math.min(index.getCount(options), HOME_STRIP_MAX_BOOKS)
                local offset_key = tostring(component_id or source_key)
                    .. ":" .. source_key .. ":" .. normalize_order(order_key)
                local offset = strip_page_offset(
                    total, n, strip_offsets[offset_key], page_delta)
                local paths = index.getPage(offset, n, options)
                local component_cfg = dcfg and dcfg.modules and dcfg.modules[component_id] or {}
                local resolve_favorite = wants_favorite_badge
                    and component_cfg.show_badges == true
                local books = {}
                for _i, path in ipairs(paths) do
                    local book = get_book(path, false, true)
                    if book then
                        if resolve_favorite then book.is_fav = get_favorite(path) end
                        books[#books + 1] = book
                    end
                end
                return books, total > n or index.isAuditRunning()
            end
        end
        local source, paths, n = get_strip_paths(source_key, count, order_key, component_id)
        local component_cfg = dcfg and dcfg.modules and dcfg.modules[component_id] or {}
        local resolve_favorite = wants_favorite_badge and component_cfg.show_badges == true

        local offset_key = tostring(component_id or source) .. ":" .. source .. ":" .. normalize_order(order_key)
        local offset = strip_page_offset(#paths, n, strip_offsets[offset_key], page_delta)

        local books = {}
        for i = offset + 1, math.min(offset + n, #paths) do
            local path = paths[i]
            local book = get_book(path, false, true)
            if book then
                if resolve_favorite then
                    book.is_fav = get_favorite(path)
                end
                table.insert(books, book)
                if #books >= n then break end
            end
        end
        return books, #paths > n
    end

    function provider:getBooksForStrip(source_key, count, order_key, component_id)
        return self:getBooksForStripPage(source_key, count, order_key, component_id, 0)
    end

    local function collection_files(name)
        local ok_collection, ReadCollection = pcall(require, "readcollection")
        if not ok_collection or not ReadCollection or type(name) ~= "string" then return {} end
        local collection = ReadCollection.coll and ReadCollection.coll[name]
        if type(collection) ~= "table" then return {} end
        local entries = {}
        for _key, entry in pairs(collection) do
            if type(entry) == "table" and type(entry.file) == "string"
                    and entry.file ~= "" then
                entries[#entries + 1] = entry
            end
        end
        table.sort(entries, function(a, b)
            local ao = tonumber(a.order) or 0
            local bo = tonumber(b.order) or 0
            if ao == bo then return a.file < b.file end
            return ao < bo
        end)
        local files = {}
        for _i, entry in ipairs(entries) do files[#files + 1] = entry.file end
        return files
    end

    local function folder_files(path)
        if type(path) ~= "string" or path == "" then return {} end
        local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
        if not ok_lfs or lfs.attributes(path, "mode") ~= "directory" then return {} end
        local FileManager = require("apps/filemanager/filemanager")
        local chooser = FileManager.instance and FileManager.instance.file_chooser
        if not (chooser and type(chooser.genItemTableFromPath) == "function") then return {} end
        local ok_items, items = pcall(chooser.genItemTableFromPath, chooser, path)
        if not ok_items or type(items) ~= "table" then return {} end
        local DocumentRegistry = require("document/documentregistry")
        local files = {}
        for _i, item in ipairs(items) do
            local item_path = item and (item.path or item.file)
            local is_file = item and (item.is_file == true
                or type(item.attr) == "table" and item.attr.mode == "file")
            if is_file and type(item_path) == "string" then
                local ok_supported, supported = pcall(
                    DocumentRegistry.hasProvider, DocumentRegistry, item_path)
                if ok_supported and supported then files[#files + 1] = item_path end
            end
        end
        return files
    end

    local function source_groups(kind)
        if kind == "collections" then
            local ok_collection, ReadCollection = pcall(require, "readcollection")
            local groups = {}
            if ok_collection and ReadCollection and type(ReadCollection.coll) == "table" then
                for name in pairs(ReadCollection.coll) do
                    local files = collection_files(name)
                    if #files > 0 then
                        groups[#groups + 1] = { label = name, files = files }
                    end
                end
                table.sort(groups, function(a, b) return a.label < b.label end)
            end
            return groups
        end
        local ok_db, db = pcall(require, "common/db_bookinfo")
        if not ok_db or not db then return {} end
        local raw_groups
        if kind == "authors" and type(db.getGroupedByAuthor) == "function" then
            raw_groups = db.getGroupedByAuthor()
        elseif kind == "series" and type(db.getGroupedBySeries) == "function" then
            raw_groups = db.getGroupedBySeries()
        elseif kind == "languages" and type(db.getGroupedByLanguage) == "function" then
            raw_groups = db.getGroupedByLanguage()
        elseif kind == "tags" and type(db.getGroupedByTags) == "function" then
            raw_groups = db.getGroupedByTags()
        end
        local groups = {}
        for _i, group in ipairs(raw_groups or {}) do
            local files = group.files
            if kind == "series" then
                files = {}
                for _j, item in ipairs(group.items or {}) do
                    if type(item.file) == "string" then files[#files + 1] = item.file end
                end
            end
            local label = group.author or group.series or group.language or group.tag
            if kind == "languages" then
                label = LanguageName.get(label)
            end
            if type(label) == "string" and type(files) == "table" and #files > 0 then
                groups[#groups + 1] = { label = label, files = files }
            end
        end
        local group_view = type(cfg.group_view) == "table" and cfg.group_view or {}
        if kind == "authors" and #groups > 1 then
            local collate = author_sort.normalize(group_view.authors_collate)
            table.sort(groups, function(a, b)
                return author_sort.less(a.label, b.label, collate)
            end)
            local reverse = type(group_view.group_reverse) == "table"
                and group_view.group_reverse.authors == true
            if reverse then groups = reverse_copy(groups) end
        elseif (kind == "series" or kind == "languages" or kind == "tags")
                and #groups > 1 then
            local collate = type(group_view.group_collate) == "table"
                and group_view.group_collate[kind] or "title"
            local natural = collate == "title_natural"
            table.sort(groups, function(a, b)
                return title_sort.less(a.label, b.label, natural)
            end)
            local reverse = type(group_view.group_reverse) == "table"
                and group_view.group_reverse[kind] == true
            if reverse then groups = reverse_copy(groups) end
        end
        return groups
    end

    local function resolve_drill_files(request)
        local drill = type(request) == "table" and request.drill or nil
        if type(drill) ~= "table" then return nil end
        if type(drill.files) == "table" then return drill.files end
        for _i, group in ipairs(source_groups(request.kind)) do
            if group.label == drill.label then
                drill.files = copy_paths(group.files)
                return drill.files
            end
        end
        drill.files = {}
        return drill.files
    end

    local function descriptor_key(request, order_key)
        local drill = type(request.drill) == "table" and request.drill.label or ""
        return table.concat({
            "strip", tostring(request.kind), tostring(request.value or ""),
            tostring(drill), normalize_order(order_key),
        }, ":")
    end

    local function paginate(values, request, count, order_key, component_id, page_delta)
        local n = math.max(1, tonumber(count) or 4)
        local key = tostring(component_id or "strip") .. ":" .. descriptor_key(request, order_key)
        local offset = strip_page_offset(#values, n, strip_offsets[key], page_delta)
        local page = {}
        for i = offset + 1, math.min(offset + n, #values) do
            page[#page + 1] = values[i]
        end
        return page, #values > n, key
    end

    local function descriptor_paths(request)
        if request.kind == "favorites" then
            local ok_collection, ReadCollection = pcall(require, "readcollection")
            return ok_collection and ReadCollection
                and collection_files(ReadCollection.default_collection_name) or {}
        end
        if request.kind == "tag" then
            local ok_db, db = pcall(require, "common/db_bookinfo")
            return ok_db and db and type(db.getTagBooks) == "function"
                and db.getTagBooks(request.value) or {}
        end
        if request.kind == "custom" then
            if type(request.paths) == "table" then return copy_paths(request.paths) end
            local strip = dcfg and dcfg.modules and dcfg.modules.strip or {}
            local sources = type(strip.sources) == "table" and strip.sources or {}
            local custom = type(sources.custom) == "table" and sources.custom or {}
            return copy_paths(custom.paths)
        end
    end

    function provider:getStripItemsForPage(request, count, order_key, component_id, page_delta)
        request = type(request) == "table" and request or { kind = "recent" }
        local kind = request.kind or "recent"
        if type(request.drill) == "table" then
            local paths = copy_paths(resolve_drill_files(request))
            if normalize_order(order_key) == "reverse" then paths = reverse_copy(paths) end
            local page, adjacent = paginate(
                paths, request, count, order_key, component_id, page_delta)
            local books = {}
            for _i, path in ipairs(page) do
                local book = get_book(path, false, true)
                if book then books[#books + 1] = book end
            end
            return books, adjacent
        end
        if kind == "authors" or kind == "series" or kind == "languages"
                or kind == "tags"
                or kind == "collections" then
            local groups = source_groups(kind)
            if normalize_order(order_key) == "reverse" then groups = reverse_copy(groups) end
            local page, adjacent = paginate(
                groups, request, count, order_key, component_id, page_delta)
            local items = {}
            for _i, group in ipairs(page) do
                local book = get_book(group.files[1], false, true)
                if book then
                    book.is_group = true
                    book.group_kind = kind
                    book.group_label = group.label
                    book.group_count = #group.files
                    book.group_files = group.files
                    items[#items + 1] = book
                end
            end
            return items, adjacent
        end
        if kind == "folder" then
            local paths = folder_files(request.value)
            local page, adjacent = paginate(
                paths, request, count, order_key, component_id, page_delta)
            local books = {}
            for _i, path in ipairs(page) do
                local book = get_book(path, false, true)
                if book then books[#books + 1] = book end
            end
            return books, adjacent
        end
        if kind == "favorites" or kind == "tag" or kind == "custom" then
            local paths = descriptor_paths(request)
            if normalize_order(order_key) == "reverse" then paths = reverse_copy(paths) end
            local page, adjacent = paginate(
                paths, request, count, order_key, component_id, page_delta)
            local books = {}
            for _i, path in ipairs(page) do
                local book = get_book(path, false, true)
                if book then books[#books + 1] = book end
            end
            return books, adjacent
        end
        local source = kind == "to_be_read" and "to_be_read" or "recently_read"
        return self:getBooksForStripPage(
            source, count, order_key, component_id, page_delta)
    end

    function provider:shiftStripItems(request, count, order_key, direction, component_id, refresh)
        request = type(request) == "table" and request or { kind = "recent" }
        if request.kind == "recent" or request.kind == "to_be_read" then
            local source = request.kind == "to_be_read" and "to_be_read"
                or "recently_read"
            return self:shiftStrip(source, count, order_key, direction, component_id, refresh)
        end
        local values = request.drill and resolve_drill_files(request)
            or request.kind == "folder" and folder_files(request.value)
            or descriptor_paths(request)
            or source_groups(request.kind)
        local n = math.max(1, tonumber(count) or 4)
        if type(values) ~= "table" or #values <= n then return false end
        local key = tostring(component_id or "strip") .. ":" .. descriptor_key(request, order_key)
        strip_offsets[key] = strip_page_offset(
            #values, n, strip_offsets[key], direction == "previous" and -1 or 1)
        if type(refresh) == "function" then refresh() end
        return true
    end

    function provider:shiftStrip(source_key, count, order_key, direction, component_id, refresh)
        if source_key == "to_be_read" then
            local index = get_tbr_index()
            if index then
                local n = tonumber(count) or 4
                if n < 1 then n = 1 end
                local options = tbr_sort_options(order_key, true)
                local total = math.min(index.getCount(options), HOME_STRIP_MAX_BOOKS)
                if total <= n then return false end
                local offset_key = tostring(component_id or source_key)
                    .. ":" .. source_key .. ":" .. normalize_order(order_key)
                strip_offsets[offset_key] = strip_page_offset(
                    total, n, strip_offsets[offset_key],
                    direction == "previous" and -1 or 1)
                if type(refresh) == "function" then refresh() end
                return true
            end
        end
        local source, paths, n = get_strip_paths(source_key, count, order_key, component_id)
        if #paths <= n then return false end
        local offset_key = tostring(component_id or source) .. ":" .. source .. ":" .. normalize_order(order_key)
        strip_offsets[offset_key] = strip_page_offset(
            #paths, n, strip_offsets[offset_key], direction == "previous" and -1 or 1)
        if type(refresh) == "function" then
            refresh()
        elseif _home_menu and _home_menu._home_rebuild then
            _home_menu:_home_rebuild()
        end
        return true
    end

    function provider:isStripCoverWorkBusy()
        local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
        return ok_bim and BookInfoManager
            and type(BookInfoManager.isExtractingInBackground) == "function"
            and BookInfoManager:isExtractingInBackground() or false
    end

    function provider:warmStripCover(book, width, height)
        local path = type(book) == "table" and book.path or nil
        width, height = tonumber(width), tonumber(height)
        if type(path) ~= "string" or path == "" or not width or width < 1
                or not height or height < 1 then
            return "failed"
        end
        if type(RenderCache.hasReusable) == "function"
                and RenderCache:hasReusable(path, width, height) then
            return "cached"
        end

        local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
        if not ok_bim or not BookInfoManager then return "failed" end
        local metadata = type(DecodeCache.getFreshMetadata) == "function"
            and DecodeCache:getFreshMetadata(path, now(), 30) or nil
        metadata = metadata or BookInfoManager:getBookInfo(path, false)
        if not metadata then return "failed" end
        local specs = { max_cover_w = width, max_cover_h = height }
        if not metadata.cover_fetched then
            queue_cover_upgrade(path, "strip", specs)
            return "pending"
        end
        if not metadata.has_cover or metadata.ignore_cover then
            invalidate_home_book_cache(path)
            return "ready"
        end
        if type(BookInfoManager.isCachedCoverInvalid) == "function"
                and BookInfoManager.isCachedCoverInvalid(metadata, specs) then
            queue_cover_upgrade(path, "strip", specs)
            return "pending"
        end

        local info = BookInfoManager:getBookInfo(path, true)
        if not info then return "failed" end
        local source = info.cover_bb
        info.cover_bb = nil
        if not info.cover_fetched then
            if source and source.free then pcall(source.free, source) end
            queue_cover_upgrade(path, "strip", specs)
            return "pending"
        end
        if not info.has_cover or info.ignore_cover then
            if source and source.free then pcall(source.free, source) end
            invalidate_home_book_cache(path)
            return "ready"
        end
        if not source then return "failed" end

        local final, cache_owned = RenderCache:renderShared(path, source, width, height)
        if not final then return "failed" end
        if cache_owned then
            RenderCache:releaseShared(path, final)
            return "warmed"
        end
        if final.free then pcall(final.free, final) end
        return "failed"
    end

    function provider:resetStripPages()
        local changed = false
        for offset_key, offset in pairs(strip_offsets) do
            if tonumber(offset) ~= 0 then
                changed = true
            end
            strip_offsets[offset_key] = nil
        end
        return changed
    end

    function provider:getStripPageState()
        return copy_home_strip_pages(strip_offsets)
    end

    function provider:getCurrentQuote()
        if current_quote then return current_quote end
        local quote_cfg = dcfg.quotes or {}
        local rotation = quote_cfg.rotation == "refresh" and "refresh" or "daily"
        local started_at = os.clock()
        local perf
        current_quote, perf = HomeQuotes.selectQuote(quote_cfg, rotation)
        quote_select_ms = quote_select_ms + (os.clock() - started_at) * 1000
        if type(perf) == "table" then
            quote_annotation_ms = quote_annotation_ms + (tonumber(perf.annotation_ms) or 0)
            quote_annotation_books = quote_annotation_books
                + (tonumber(perf.annotation_books) or 0)
            quote_annotation_cache_hits = quote_annotation_cache_hits
                + (tonumber(perf.annotation_cache_hits) or 0)
            quote_annotation_cache_misses = quote_annotation_cache_misses
                + (tonumber(perf.annotation_cache_misses) or 0)
            quote_sidecar_cache_hits = quote_sidecar_cache_hits
                + (tonumber(perf.sidecar_cache_hits) or 0)
            quote_sidecar_cache_misses = quote_sidecar_cache_misses
                + (tonumber(perf.sidecar_cache_misses) or 0)
            quote_state_writes = quote_state_writes + (tonumber(perf.state_writes) or 0)
        end
        return current_quote
    end

    function provider:recordQuoteLayout(elapsed_ms, cache_hit, probes)
        quote_layout_ms = quote_layout_ms + (tonumber(elapsed_ms) or 0)
        quote_layout_probes = quote_layout_probes + (tonumber(probes) or 0)
        if cache_hit then
            quote_layout_cache_hits = quote_layout_cache_hits + 1
        else
            quote_layout_cache_misses = quote_layout_cache_misses + 1
        end
    end

    function provider:clearQuote()
        current_quote = nil
    end

    local function step_quote(delta)
        local quote_cfg = dcfg.quotes or {}
        current_quote = HomeQuotes.stepQuote(quote_cfg, delta)
        if not current_quote then return end
        if _home_menu and _home_menu._home_rebuild then
            _home_menu:_home_rebuild()
        end
    end

    function provider:nextQuote()
        step_quote(1)
    end

    function provider:prevQuote()
        step_quote(-1)
    end

    function provider:openQuote(quote)
        if not (quote and quote.is_annotation and quote.filepath) then return false end
        local filepath, pos0, page = quote.filepath, quote.pos0, quote.page
        local filename = filepath:match("([^/\\]+)$") or filepath

        local function open()
            UIManager:nextTick(function()
                local FileManager = require("apps/filemanager/filemanager")
                local filemanagerutil = require("apps/filemanager/filemanagerutil")
                local fm = FileManager.instance
                if filemanagerutil.openFile then
                    filemanagerutil.openFile(fm, filepath)
                elseif fm and type(fm.openFile) == "function" then
                    fm:openFile(filepath)
                else
                    local ReaderUI = require("apps/reader/readerui")
                    ReaderUI:showReader(filepath)
                end
                if pos0 or page then
                    UIManager:scheduleIn(0.5, function()
                        local reader = package.loaded["apps/reader/readerui"]
                        local instance = reader and reader.instance
                        if not instance then return end
                        local Event = require("ui/event")
                        if pos0 then
                            instance:handleEvent(Event:new("GotoXPointer", pos0))
                        elseif page then
                            instance:handleEvent(Event:new("GotoPage", tonumber(page) or page))
                        end
                    end)
                end
            end)
        end

        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:nextTick(function()
            UIManager:show(ConfirmBox:new{
                text = _("Open this file?") .. "\n\n" .. filename,
                ok_text = _("Open"),
                cancel_text = _("Cancel"),
                ok_callback = open,
            })
        end)
        return true
    end

    provider.stats = {}

    function provider:prepareStats(rows, force)
        local fields = collect_stats_fields(rows, dcfg)
        local key = stats_fields_key(fields)
        if key == "" then
            stats_cached = {}
            stats_cached_key = key
            self.stats = stats_cached
            return self.stats
        end
        if force or key ~= stats_cached_key then
            stats_cached = nil
            stats_cached_key = key
            if force and _home_stats_cache.key == key then
                _home_stats_cache.value = nil
                _home_stats_cache.expires_at = 0
            end
        end
        self.stats = get_stats(fields)
        return self.stats
    end

    function provider:refreshStats(rows)
        return self:prepareStats(rows, true)
    end

    function provider:getStats(rows)
        return self:prepareStats(rows, false)
    end

    function provider:clearStats()
        stats_cached = nil
        stats_cached_key = nil
        self.stats = {}
        return self.stats
    end

    function provider:resetPerformanceStats()
        book_cache_hits = 0
        book_cache_misses = 0
        book_lookup_ms = 0
        quote_select_ms = 0
        quote_annotation_ms = 0
        quote_annotation_books = 0
        quote_annotation_cache_hits = 0
        quote_annotation_cache_misses = 0
        quote_sidecar_cache_hits = 0
        quote_sidecar_cache_misses = 0
        quote_state_writes = 0
        quote_layout_ms = 0
        quote_layout_cache_hits = 0
        quote_layout_cache_misses = 0
        quote_layout_probes = 0
    end

    function provider:getPerformanceStats()
        return {
            book_cache_hits = book_cache_hits,
            book_cache_misses = book_cache_misses,
            book_lookup_ms = math.floor(book_lookup_ms + 0.5),
            quote_select_ms = math.floor(quote_select_ms * 10 + 0.5) / 10,
            quote_annotation_ms = math.floor(quote_annotation_ms * 10 + 0.5) / 10,
            quote_annotation_books = quote_annotation_books,
            quote_annotation_cache_hits = quote_annotation_cache_hits,
            quote_annotation_cache_misses = quote_annotation_cache_misses,
            quote_sidecar_cache_hits = quote_sidecar_cache_hits,
            quote_sidecar_cache_misses = quote_sidecar_cache_misses,
            quote_state_writes = quote_state_writes,
            quote_layout_ms = math.floor(quote_layout_ms * 10 + 0.5) / 10,
            quote_layout_cache_hits = quote_layout_cache_hits,
            quote_layout_cache_misses = quote_layout_cache_misses,
            quote_layout_probes = quote_layout_probes,
            dataset_generation = dataset.generation,
        }
    end

    return provider
end

local function compute_row_heights(rows, body_h, row_gap, capacity, width, modules, config, data)
    local specs = {}
    local row_count = #rows
    local unit_counts = Registry.layoutUnits and Registry.layoutUnits(rows, capacity) or {}
    if #unit_counts == 0 then
        for _i, comp in ipairs(rows) do
            unit_counts[#unit_counts + 1] = tonumber(comp._home_units) or 2
        end
    end
    local max_heights = {}
    modules = type(modules) == "table" and modules or {}
    for i, comp in ipairs(rows) do
        if type(comp.preferredHeight) == "function" then
            local ok, preferred = pcall(comp.preferredHeight, {
                width = width,
                module_cfg = modules[comp.id],
                config = config,
                data = data,
                is_last_row = i == row_count,
                row_count = row_count,
            })
            if ok and tonumber(preferred) then max_heights[i] = preferred end
        end
    end
    if row_count >= 3 then
        local has_flexible_middle = false
        for i = 2, row_count - 1 do
            if not max_heights[i] then has_flexible_middle = true; break end
        end
        if not has_flexible_middle then
            -- Keep one middle row flexible so capped outer rows do not leave trailing space.
            max_heights[math.floor((row_count + 1) / 2)] = nil
        end
    end
    local has_flexible_row = false
    for i = 1, row_count do
        if not max_heights[i] then has_flexible_row = true; break end
    end
    if not has_flexible_row then
        for i, comp in ipairs(rows) do
            if comp.id == "stats_triplet" then
                max_heights[i] = nil
                break
            end
        end
    end
    local heights = Registry.gridHeights(
        unit_counts, body_h, row_gap, capacity, max_heights)
    for i, height in ipairs(heights) do
        specs[i] = { units = unit_counts[i], h = height }
    end
    return specs
end

local function paint_focus_rect(bb, x, y, w, h, color)
    if not (bb and x and y and w and h and w > 2 and h > 2) then return end
    local t = 2
    color = color or Blitbuffer.COLOR_BLACK
    for i = 0, t - 1 do
        bb:paintRect(x + i, y + i, w - i * 2, 1, color)
        bb:paintRect(x + i, y + h - 1 - i, w - i * 2, 1, color)
        bb:paintRect(x + i, y + i, 1, h - i * 2, color)
        bb:paintRect(x + w - 1 - i, y + i, 1, h - i * 2, color)
    end
end

local function sort_home_focus_targets(menu)
    local targets = menu and menu._zen_home_focus_targets
    if type(targets) ~= "table" then return end
    table.sort(targets, function(a, b)
        local ar = tonumber(a.row_order) or 0
        local br = tonumber(b.row_order) or 0
        if ar ~= br then return ar < br end
        local ac = tonumber(a.col) or 0
        local bc = tonumber(b.col) or 0
        if ac ~= bc then return ac < bc end
        return (tonumber(a.seq) or 0) < (tonumber(b.seq) or 0)
    end)
    for i, target in ipairs(targets) do
        target.index = i
    end
end

local function register_home_focus_target(menu, target)
    if not (menu and type(target) == "table") then return target end
    menu._zen_home_focus_targets = menu._zen_home_focus_targets or {}
    menu._zen_home_focus_seq = (menu._zen_home_focus_seq or 0) + 1
    target.seq = menu._zen_home_focus_seq
    target.id = target.id or target.seq
    target.key = target.key or ("target:" .. tostring(target.id))
    table.insert(menu._zen_home_focus_targets, target)
    return target
end

local function wrap_home_focus_target(menu, target, widget, defer_registration)
    if not (menu and target and widget) then return widget end
    local FrameContainer = require("ui/widget/container/framecontainer")
    local size = widget.getSize and widget:getSize() or nil
    local width = tonumber(target.width) or (size and size.w) or 1
    local height = tonumber(target.height) or (size and size.h) or 1
    target.width = width
    target.height = height
    if not defer_registration then
        register_home_focus_target(menu, target)
    end

    local frame = FrameContainer:new{
        width = width,
        height = height,
        padding = 0,
        bordersize = 0,
        background = home_frame_bg(),
        widget,
    }
    local orig_paintTo = frame.paintTo
    frame.paintTo = function(self, bb, x, y)
        orig_paintTo(self, bb, x, y)
        if menu._zen_home_focus_id == target.id then
            paint_focus_rect(
                bb, x, y, self:getSize().w, self:getSize().h, target.focus_color)
        end
    end
    target.widget = frame
    return frame
end

local function find_home_focus_index(menu, key)
    if not (menu and key and type(menu._zen_home_focus_targets) == "table") then return nil end
    for i, target in ipairs(menu._zen_home_focus_targets) do
        if target.key == key then return i end
    end
end

local function set_home_focus(menu, index)
    local targets = menu and menu._zen_home_focus_targets
    if type(targets) ~= "table" or #targets == 0 then return false end
    if index < 1 then index = 1 end
    if index > #targets then index = #targets end
    local target = targets[index]
    if not target then return false end
    menu._zen_home_focus_suspended = false
    menu._zen_home_focus_index = index
    menu._zen_home_focus_id = target.id
    menu._zen_home_focus_key = target.key
    require("ui/uimanager"):setDirty(menu, "ui")
    return true
end

local function clear_home_focus(menu, suspended)
    if not menu then return end
    menu._zen_home_focus_index = nil
    menu._zen_home_focus_id = nil
    menu._zen_home_focus_suspended = suspended == true
    require("ui/uimanager"):setDirty(menu, "ui")
end

local function get_home_focus_target(menu)
    local targets = menu and menu._zen_home_focus_targets
    local index = menu and menu._zen_home_focus_index
    if type(targets) ~= "table" or type(index) ~= "number" then return nil end
    return targets[index]
end

local function move_home_focus(menu, dx, dy)
    local targets = menu and menu._zen_home_focus_targets
    if type(targets) ~= "table" or #targets == 0 then return false end
    if menu._zen_home_focus_suspended then return false end
    local current = get_home_focus_target(menu)
    if not current then
        return set_home_focus(menu, dy and dy < 0 and #targets or 1)
    end

    local best_i, best_score
    local cur_row = tonumber(current.row_order) or 0
    local cur_col = tonumber(current.col) or 0
    if dy and dy ~= 0 then
        for i, target in ipairs(targets) do
            local row = tonumber(target.row_order) or 0
            if (dy > 0 and row > cur_row) or (dy < 0 and row < cur_row) then
                local col = tonumber(target.col) or 0
                local score = math.abs(col - cur_col) + math.abs(row - cur_row) * 100
                if not best_score or score < best_score then
                    best_i, best_score = i, score
                end
            end
        end
    elseif dx and dx ~= 0 then
        for i, target in ipairs(targets) do
            local row = tonumber(target.row_order) or 0
            local col = tonumber(target.col) or 0
            if row == cur_row and ((dx > 0 and col > cur_col) or (dx < 0 and col < cur_col)) then
                local score = math.abs(col - cur_col)
                if not best_score or score < best_score then
                    best_i, best_score = i, score
                end
            end
        end
        if not best_i then
            best_i = current.index + dx
            if best_i < 1 or best_i > #targets then best_i = nil end
        end
    end
    if best_i then return set_home_focus(menu, best_i) end
    return false
end

local function activate_home_focus(menu)
    local target = get_home_focus_target(menu)
    if not target then return false end
    if type(target.activate) == "function" then
        target.activate()
    end
    return true
end

local function context_home_focus(menu)
    local target = get_home_focus_target(menu)
    if not target then return false end
    if type(target.context) == "function" then
        target.context()
    end
    return true
end

local HOME_CONFIRM_KEYS = { "Press", "Return", "Enter" }

local function home_key_matches(key, name)
    if key == name then return true end
    return type(key) == "table" and type(key.match) == "function"
        and key:match({ name }) == true
end

local function home_confirm_key_name(key)
    for _i, name in ipairs(HOME_CONFIRM_KEYS) do
        if home_key_matches(key, name) then return name end
    end
end

local function install_home_key_handlers(menu)
    if not menu or menu._zen_home_key_patched then return end
    menu._zen_home_key_patched = true
    local HOLD_DELAY = 0.4
    local hold_fn = nil
    local hold_key = nil

    local function cancel_hold()
        if hold_fn then
            UIManager:unschedule(hold_fn)
            hold_fn = nil
            hold_key = nil
            return true
        end
        hold_key = nil
        return false
    end

    local function start_hold(m, key)
        cancel_hold()
        hold_key = key
        hold_fn = function()
            hold_fn = nil
            context_home_focus(m)
        end
        UIManager:scheduleIn(HOLD_DELAY, hold_fn)
    end

    local function home_move_or_focus(m, dx, dy)
        if move_home_focus(m, dx, dy) then return true end
        return false
    end

    local function delegate_to_navbar(m, callback, ...)
        local handled = callback and callback(m, ...)
        if handled then
            clear_home_focus(m, true)
        end
        return handled
    end

    local orig_next_page = menu.onNextPage
    function menu:onNextPage(...)
        local handler = self._zen_home_strip_page_handler
        if type(handler) == "function" then
            handler("next")
            return true
        end
        return orig_next_page and orig_next_page(self, ...)
    end

    local orig_prev_page = menu.onPrevPage
    function menu:onPrevPage(...)
        local handler = self._zen_home_strip_page_handler
        if type(handler) == "function" then
            handler("previous")
            return true
        end
        return orig_prev_page and orig_prev_page(self, ...)
    end

    menu.key_events = menu.key_events or {}
    menu.key_events.LeftButtonTap = {
        { "Menu" },
        event = "ZenHomeContext",
    }
    menu.key_events.ZenHomeContext = {
        { "Menu" },
        event = "ZenHomeContext",
    }
    menu.key_events.ZenNavbarConfirm = {
        { "Press" },
        { "Return" },
        { "Enter" },
        event = "ZenNavbarConfirm",
    }

    function menu:onZenHomeContext()
        local fm = require("apps/filemanager/filemanager").instance
        local fm_menu = fm and fm.menu
        if fm_menu and type(fm_menu.onShowMenu) == "function" then
            return fm_menu:onShowMenu()
        end
        return false
    end

    local orig_left = menu.onZenNavbarFocusLeft
    function menu:onZenNavbarFocusLeft()
        if self._zen_home_focus_suspended then
            return orig_left and orig_left(self)
        end
        if home_move_or_focus(self, -1, 0) then return true end
        return delegate_to_navbar(self, orig_left)
    end

    local orig_right = menu.onZenNavbarFocusRight
    function menu:onZenNavbarFocusRight()
        if self._zen_home_focus_suspended then
            return orig_right and orig_right(self)
        end
        if home_move_or_focus(self, 1, 0) then return true end
        return delegate_to_navbar(self, orig_right)
    end

    local orig_up = menu.onZenNavbarFocusUp
    function menu:onZenNavbarFocusUp()
        if self._zen_home_focus_suspended then
            local handled = orig_up and orig_up(self)
            if handled then
                self._zen_home_focus_suspended = false
                return set_home_focus(self, #(self._zen_home_focus_targets or {}))
            end
            return handled
        end
        if home_move_or_focus(self, 0, -1) then return true end
        return delegate_to_navbar(self, orig_up)
    end

    local orig_down = menu.onZenNavbarFocusDown
    function menu:onZenNavbarFocusDown()
        if self._zen_home_focus_suspended then
            return orig_down and orig_down(self)
        end
        if home_move_or_focus(self, 0, 1) then return true end
        return delegate_to_navbar(self, orig_down)
    end

    local orig_confirm = menu.onZenNavbarConfirm
    function menu:onZenNavbarConfirm()
        if self._zen_home_focus_suspended then
            return orig_confirm and orig_confirm(self)
        end
        if get_home_focus_target(self) then
            start_hold(self, true)
            return true
        end
        return orig_confirm and orig_confirm(self)
    end

    local orig_focus_move = menu.onFocusMove
    menu.onFocusMove = function(m, args)
        local dx = args and args[1] or 0
        local dy = args and args[2] or 0
        if m._zen_home_focus_suspended and dy == -1 then
            local handled = orig_focus_move and orig_focus_move(m, args)
            if handled then
                m._zen_home_focus_suspended = false
                return set_home_focus(m, #(m._zen_home_focus_targets or {}))
            end
            return handled
        end
        if not m._zen_home_focus_suspended and home_move_or_focus(m, dx, dy) then return true end
        local handled = orig_focus_move and orig_focus_move(m, args)
        if handled and dy == 1 then clear_home_focus(m, true) end
        return handled
    end

    local orig_key_press = menu.onKeyPress
    menu.onKeyPress = function(m, key)
        if m._zen_home_focus_suspended and home_key_matches(key, "Up") then
            local handled = orig_key_press and orig_key_press(m, key)
            if handled then
                m._zen_home_focus_suspended = false
                return set_home_focus(m, #(m._zen_home_focus_targets or {}))
            end
            return handled
        end
        if home_key_matches(key, "Left")
                and home_move_or_focus(m, -1, 0) then return true end
        if home_key_matches(key, "Right")
                and home_move_or_focus(m, 1, 0) then return true end
        if home_key_matches(key, "Up")
                and home_move_or_focus(m, 0, -1) then return true end
        if home_key_matches(key, "Down")
                and home_move_or_focus(m, 0, 1) then return true end
        local confirm_key = home_confirm_key_name(key)
        if confirm_key and get_home_focus_target(m) then
            start_hold(m, confirm_key)
            return true
        end
        local handled = orig_key_press and orig_key_press(m, key)
        if handled and home_key_matches(key, "Down") then
            clear_home_focus(m, true)
        end
        return handled
    end

    local orig_key_release = menu.onKeyRelease
    menu.onKeyRelease = function(m, key)
        local confirm_key = home_confirm_key_name(key)
        if confirm_key and hold_key
                and (hold_key == true or hold_key == confirm_key) then
            local activate = cancel_hold()
            if activate then activate_home_focus(m) end
            return true
        end
        return orig_key_release and orig_key_release(m, key)
    end
end

local function build_home_content(menu, zen_config, dcfg, rows, data_provider)
    local Device = require("device")
    local Screen = Device.screen
    local Geom = require("ui/geometry")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local Font = require("ui/font")
    local GestureRange = require("ui/gesturerange")
    local prev_focus_key = menu._zen_home_focus_key
    menu._zen_home_focus_targets = {}
    menu._zen_home_focus_seq = 0
    menu._zen_home_focus_index = nil
    menu._zen_home_focus_id = nil
    local strip_cover_listeners = {}
    menu._zen_home_strip_cover_listeners = strip_cover_listeners
    function menu:_zen_home_notify_strip_cover(path)
        local listeners = self._zen_home_strip_cover_listeners or {}
        for _i, listener in ipairs(listeners) do
            if type(listener) == "function" then pcall(listener, path) end
        end
    end

    local function register_strip_cover_listener(listener)
        if type(listener) ~= "function" then return function() end end
        strip_cover_listeners[#strip_cover_listeners + 1] = listener
        local registered = true
        return function()
            if not registered then return end
            registered = false
            for i = #strip_cover_listeners, 1, -1 do
                if strip_cover_listeners[i] == listener then
                    table.remove(strip_cover_listeners, i)
                    break
                end
            end
        end
    end

    local function register_strip_page_handler(handler)
        if type(handler) ~= "function" then return function() end end
        menu._zen_home_strip_page_handler = handler
        return function()
            if rawequal(menu._zen_home_strip_page_handler, handler) then
                menu._zen_home_strip_page_handler = nil
            end
        end
    end

    local show_status_bar = dcfg.show_status_bar ~= false
    local tb = menu.title_bar
    local tb_h = show_status_bar and tb and tb:getSize().h or 0
    local menu_h = menu.height or (menu.inner_dimen and menu.inner_dimen.h or menu.dimen.h)
    local body_h = menu_h - tb_h
    local navbar_h = tonumber(rawget(_G, "__ZEN_UI_NAVBAR_HEIGHT")) or 0
    local hard_body_h = Screen:getHeight() - tb_h - navbar_h
    if hard_body_h < 1 then hard_body_h = Screen:getHeight() - tb_h end
    if body_h < 1 then body_h = hard_body_h end
    if body_h > hard_body_h then body_h = hard_body_h end
    local body_w = menu.inner_dimen and menu.inner_dimen.w or Screen:getWidth()
    local side_pad = math.max(2, math.min(Screen:scaleBySize(8), math.floor(body_w * 0.025)))
    if side_pad * 2 >= body_w then
        side_pad = math.max(0, math.floor(body_w * 0.04))
    end
    local content_w = math.max(1, body_w - side_pad * 2)
    local right_pad = math.max(0, body_w - content_w - side_pad)
    local standard_gap = math.max(4, Screen:scaleBySize(8))
    local capacity = type(Registry.capacityUnits) == "function"
        and Registry.capacityUnits(Screen:getWidth(), Screen:getHeight())
        or tonumber(Registry.CAPACITY_UNITS) or 10
    local max_page_pad = math.max(0, math.floor((body_h - capacity) / 2))
    local page_pad = math.min(math.max(3, Screen:scaleBySize(4)), max_page_pad)
    local layout_h = math.max(1, body_h - page_pad * 2)
    local max_grid_gap = capacity > 1
        and math.max(0, math.floor((layout_h - capacity) / (capacity - 1))) or 0
    local row_gap = math.min(standard_gap, max_grid_gap)
    local row_heights = compute_row_heights(
        rows, layout_h, row_gap, capacity, content_w, dcfg.modules, dcfg, data_provider)
    menu._zen_home_page_padding = page_pad
    menu._zen_home_row_gap = row_gap
    menu._zen_home_capacity_units = capacity

    local face_title = Font:getFace("smallinfofont", Screen:scaleBySize(24))
    local face_value = Font:getFace("smallinfofont", Screen:scaleBySize(20))
    local face_label = Font:getFace("smallinfofont", Screen:scaleBySize(16))
    local FileManager = require("apps/filemanager/filemanager")
    local filemanagerutil = require("apps/filemanager/filemanagerutil")

    local function open_book(path)
        if not path then return end
        _G.__ZEN_UI_LIBRARY_SOURCE_TAB = "home"
        local fm = FileManager.instance
        if filemanagerutil.openFile then
            filemanagerutil.openFile(fm, path)
        elseif fm and type(fm.openFile) == "function" then
            fm:openFile(path)
        end
    end

    local function show_book_context_menu(path, source, component_id)
        if type(path) ~= "string" or path == "" then return false end
        local fm = FileManager.instance
        local fc = fm and fm.file_chooser
        if not (fc and type(fc.showFileDialog) == "function") then return false end
        local explicit_collection
        local ok_index, index = pcall(require, "common/tbr_index")
        if source ~= "to_be_read" or not ok_index then index = nil end
        if index and type(index.isExplicit) == "function" and index.isExplicit(path) then
            explicit_collection = index.collectionName()
        end
        fc:showFileDialog({
            path = path,
            is_file = true,
            _zen_home_context = true,
            _zen_disable_select = true,
            _zen_is_history = source == "recently_read",
            _zen_collection_name = explicit_collection,
            _zen_widget_settings = dcfg.edit_mode == true and function()
                return require("modules/settings/sections/library_settings/home_settings")
                    .openWidgetSettings(component_id, _zen_plugin)
            end or nil,
            _zen_after_status_change = function(changed_path)
                invalidate_home_book_cache(changed_path)
                invalidate_home_dataset_path(changed_path, false)
                M.rebuildActive()
            end,
        })
        return true
    end

    local function open_widget_settings(id)
        if dcfg.edit_mode ~= true then return false end
        return require("modules/settings/sections/library_settings/home_settings")
            .openWidgetSettings(id, _zen_plugin)
    end

    local function add_widget_settings_hold(widget, id, width, height)
        if dcfg.edit_mode ~= true then return widget end
        local tap = InputContainer:new{
            dimen = Geom:new{ w = width, h = height },
            ges_events = {
                HoldWidgetSettings = {
                    GestureRange:new{ ges = "hold", range = Geom:new{
                        x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight(),
                    } },
                },
            },
        }
        tap.onHoldWidgetSettings = function(tap_self, _arg, ges)
            if not (tap_self.dimen and ges and ges.pos and tap_self.dimen:contains(ges.pos)) then
                return false
            end
            return open_widget_settings(id)
        end
        tap[1] = widget
        return tap
    end

    local function shift_strip(source_key, count, order_key, direction, component_id, _two_rows, refresh)
        if type(source_key) == "table" and data_provider
                and type(data_provider.shiftStripItems) == "function" then
            return data_provider:shiftStripItems(
                source_key, count, order_key, direction, component_id, refresh)
        end
        if not (data_provider and type(data_provider.shiftStrip) == "function") then return false end
        return data_provider:shiftStrip(source_key, count, order_key, direction, component_id, refresh)
    end

    local function clear_strip_focus_targets(component_id)
        local targets = menu._zen_home_focus_targets
        if type(targets) ~= "table" then return end
        for i = #targets, 1, -1 do
            if targets[i].component_id == component_id then
                table.remove(targets, i)
            end
        end
    end

    local function prepare_home_focus_target(target, widget, component_id, row_focus_base)
        if not target then return widget end
        target.component_id = component_id
        target.row_order = tonumber(target.row_order)
            or row_focus_base + (tonumber(target.subrow) or 1)
        target.col = tonumber(target.col) or 1
        target.key = target.key
            or (component_id .. ":" .. tostring(target.row_order) .. ":" .. tostring(target.col))
        return wrap_home_focus_target(menu, target, widget, true)
    end

    local function activate_strip_focus_targets(component_id, targets)
        clear_strip_focus_targets(component_id)
        for _i, target in ipairs(targets or {}) do
            register_home_focus_target(menu, target)
        end
    end

    local function refresh_strip(dimen)
        sort_home_focus_targets(menu)
        local restore_i = find_home_focus_index(menu, menu._zen_home_focus_key)
        if restore_i then
            set_home_focus(menu, restore_i)
        else
            menu._zen_home_focus_index = nil
            menu._zen_home_focus_id = nil
        end
        request_home_repaint(menu, function()
            return "ui", dimen, menu.dithered
        end)
    end

    local top_tap_zone_h = math.max(1, math.floor(Screen:getHeight() * 0.05))
    local function open_top_menu(ges)
        if not (ges and ges.pos and ges.pos.y < top_tap_zone_h) then return false end
        local fm = FileManager.instance
        local fm_menu = fm and fm.menu
        if fm_menu and fm_menu.activation_menu ~= "swipe" then
            fm_menu:onShowMenu(fm_menu:_getTabIndexFromLocation(ges))
            return true
        end
        return false
    end

    local children = { align = "left" }
    local used_h = 0
    local top_pad = page_pad
    local visual_rows = {}
    menu._zen_home_visual_gaps = {}
    menu._zen_home_bottom_visual_inset = nil
    menu._zen_home_clock_refreshers = {}
    if top_pad > 0 then
        table.insert(children, VerticalSpan:new{ width = top_pad })
        used_h = used_h + top_pad
    end

    for i, comp in ipairs(rows) do
        local row_y = used_h
        local content_bounds
        local h = row_heights[i] and row_heights[i].h or 120
        local module_cfg = type(dcfg.modules) == "table" and dcfg.modules[comp.id] or nil
        local row_focus_base = i * 10
        local row_focus_actions = {}
        local content_h = h
        if content_h < 1 then content_h = 1 end
        local row_ctx = {
            width = content_w,
            height = content_h,
            menu = menu,
            config = dcfg,
            zen_config = zen_config,
            data = data_provider,
            openBook = open_book,
            showBookMenu = function(path, source)
                return show_book_context_menu(path, source, comp.id)
            end,
            showStripGroupMenu = function(book)
                if type(book) ~= "table" then return false end
                local group_view = _zen_shared and _zen_shared.group_view
                    or SharedState.get(_zen_plugin, "group_view")
                if not (group_view and type(group_view.showGroupContextMenu) == "function") then
                    return false
                end
                return group_view.showGroupContextMenu(
                    book.group_label or "", book.group_files or {}, book.group_kind,
                    nil, { hide_actions = true })
            end,
            rememberStripState = function(state)
                return save_home_strip_state(dcfg, state)
            end,
            editMode = dcfg.edit_mode == true,
            openWidgetSettings = function()
                return open_widget_settings(comp.id)
            end,
            shiftStrip = shift_strip,
            openTopMenu = open_top_menu,
            buildStatusRow = _zen_shared and _zen_shared.buildStatusRow,
            registerClockRefresh = function(refresh)
                if type(refresh) == "function" then
                    table.insert(menu._zen_home_clock_refreshers, refresh)
                end
            end,
            setWidgetActions = function(actions)
                row_focus_actions = type(actions) == "table" and actions or {}
            end,
            setContentBounds = function(bounds)
                if type(bounds) == "table"
                        and type(bounds.set_shift) == "function" then
                    content_bounds = bounds
                end
            end,
            registerHomeFocusTarget = function(target, widget)
                if not target then return widget end
                target.component_id = comp.id
                target.row_order = tonumber(target.row_order) or row_focus_base + (tonumber(target.subrow) or 1)
                target.col = tonumber(target.col) or 1
                target.key = target.key or (comp.id .. ":" .. tostring(target.row_order) .. ":" .. tostring(target.col))
                return wrap_home_focus_target(menu, target, widget)
            end,
            prepareHomeFocusTarget = function(target, widget)
                return prepare_home_focus_target(target, widget, comp.id, row_focus_base)
            end,
            activateStripFocusTargets = function(targets)
                activate_strip_focus_targets(comp.id, targets)
            end,
            clearStripFocusTargets = clear_strip_focus_targets,
            registerStripPageHandler = register_strip_page_handler,
            refreshStrip = refresh_strip,
            registerStripCoverListener = register_strip_cover_listener,
            face_title = face_title,
            face_value = face_value,
            face_label = face_label,
            component_id = comp.id,
            module_cfg = module_cfg,
            row_gap_above = i > 1 and row_gap or 0,
            is_first_row = i == 1,
            is_last_row = i == #rows,
        }
        local component_started_at = os.clock()
        local ok_widget, widget = pcall(comp.build, row_ctx)
        menu._zen_home_component_ms = menu._zen_home_component_ms or {}
        menu._zen_home_component_ms[comp.id] =
            math.floor((os.clock() - component_started_at) * 10000 + 0.5) / 10
        if ok_widget and widget then
            local final_widget = widget
            if comp.id ~= "featured" and comp.id ~= "strip"
                    and comp.id ~= "quotes" and comp.id ~= "reading_goals" then
                final_widget = add_widget_settings_hold(final_widget, comp.id, content_w, h)
            end
            final_widget = wrap_home_focus_target(menu, {
                key = "widget:" .. tostring(comp.id),
                row_order = row_focus_base,
                col = 0,
                width = content_w,
                height = h,
                activate = row_focus_actions.activate,
                context = row_focus_actions.context,
            }, final_widget)
            table.insert(children, FrameContainer:new{
                width = content_w,
                height = h,
                padding = 0,
                bordersize = 0,
                background = home_frame_bg(),
                final_widget,
            })
            if content_bounds then
                content_bounds.row_y = row_y
                if i == 1 then
                    content_bounds.min_shift = 0
                    content_bounds.max_shift = 0
                elseif content_bounds.lock_shift ~= true then
                    -- Borrow surrounding blank space when internal slack is too small.
                    local slack = i == #rows and row_gap * 3 or row_gap
                    content_bounds.min_shift = (content_bounds.min_shift or 0) - slack
                    content_bounds.max_shift = (content_bounds.max_shift or 0) + slack
                else
                    content_bounds.min_shift = tonumber(content_bounds.min_shift) or 0
                    content_bounds.max_shift = content_bounds.min_shift
                end
                visual_rows[i] = content_bounds
            end
            used_h = used_h + h
        else
            logger.warn("failed to build component:", comp.id, widget)
        end
        if row_gap > 0 and i < #rows then
            table.insert(children, VerticalSpan:new{ width = row_gap })
            used_h = used_h + row_gap
        end
    end

    local top_visual_inset = page_pad
    if visual_rows[1] then
        top_visual_inset = math.max(0,
            (visual_rows[1].row_y or 0) + (visual_rows[1].top or 0))
    end
    menu._zen_home_top_visual_inset = top_visual_inset
    local run = {}
    local function apply_visual_run(anchor_bottom)
        if #run > 1 then
            local bottom_anchor_offset = anchor_bottom
                and math.max(0, tonumber(run[#run].bottom_anchor_offset) or 0) or 0
            local spacing_options = anchor_bottom and {
                bottom = body_h - top_visual_inset - bottom_anchor_offset,
            } or nil
            local shifts = Registry.equalSpacingShifts(run, spacing_options)
            for i, shift in ipairs(shifts) do
                run[i].set_shift(shift)
            end
            if #shifts == #run then
                for i = 1, #run - 1 do
                    menu._zen_home_visual_gaps[#menu._zen_home_visual_gaps + 1] =
                        run[i + 1].row_y + run[i + 1].top + shifts[i + 1]
                        - run[i].row_y - run[i].bottom - shifts[i]
                end
                if anchor_bottom then
                    local last = run[#run]
                    menu._zen_home_bottom_visual_inset = body_h
                        - last.row_y - last.bottom - shifts[#shifts]
                end
            end
        end
        run = {}
    end
    for i = 1, #rows do
        if visual_rows[i] then
            run[#run + 1] = visual_rows[i]
        else
            apply_visual_run(false)
        end
    end
    apply_visual_run(true)

    if used_h < body_h then
        table.insert(children, VerticalSpan:new{ width = body_h - used_h })
    end

    sort_home_focus_targets(menu)
    local restore_i = find_home_focus_index(menu, prev_focus_key)
    if restore_i then
        set_home_focus(menu, restore_i)
    end

    return HorizontalGroup:new{
        HorizontalSpan:new{ width = side_pad },
        FrameContainer:new{
            width = content_w,
            height = body_h,
            padding = 0,
            bordersize = 0,
            background = home_frame_bg(),
            VerticalGroup:new(children),
        },
        HorizontalSpan:new{ width = right_pad },
    }
end

local function rows_have_clock_refreshers(rows, dcfg)
    local modules = type(dcfg) == "table" and type(dcfg.modules) == "table" and dcfg.modules or {}
    for _i, comp in ipairs(rows or {}) do
        if comp.id == "datetime" then
            return true
        end
        if comp.id == "featured" then
            local mcfg = modules[comp.id]
            if type(mcfg) == "table" and mcfg.show_status_bar == true then
                return true
            end
        end
    end
    return false
end

-- Stats (today/streak/week) and the daily quote both depend on the current
-- date and go stale after a wakeup that crossed midnight.
local function rows_have_date_dependent(rows)
    for _i, comp in ipairs(rows or {}) do
        if comp.id == "stats_triplet" or comp.id == "reading_goals"
                or comp.id == "quotes" then
            return true
        end
    end
    return false
end

local function rows_have_component(rows, component_id)
    for _i, comp in ipairs(rows or {}) do
        if comp.id == component_id then return true end
    end
    return false
end

local function home_shell_is_compatible(menu, dcfg)
    if not (menu and type(dcfg) == "table") then return false end
    local show_status_bar = dcfg.show_status_bar ~= false
    if menu._zen_home_show_status_bar ~= show_status_bar then return false end
    if not show_status_bar then
        local has_clock_refreshers = rows_have_clock_refreshers(resolve_rows(dcfg), dcfg)
        if menu._zen_home_has_clock_refreshers ~= has_clock_refreshers then return false end
    end
    return true
end

local function consume_last_read_file()
    local last_read_file = rawget(_G, "__ZEN_UI_LAST_READ_FILE")
    if not last_read_file then return false end
    _G.__ZEN_UI_LAST_READ_FILE = nil
    invalidate_home_book_cache(last_read_file)
    invalidate_home_dataset_path(last_read_file, true)
    pcall(function()
        require("common/tbr_index").refreshPath(last_read_file)
    end)
    return true
end

function M.showHomeView(injectNavbar)
    M.setCoverCacheBudget(MemoryPolicy.homeByteBudget())
    if _home_menu and not _home_menu._zen_home_closing then
        return _home_menu, false
    end
    refresh_shared_state()
    _home_inject_navbar = injectNavbar
    consume_last_read_file()
    local cfg = load_zen_config()
    if type(cfg) ~= "table" then return end
    local dcfg = ensure_home_cfg()
    local show_status_bar = dcfg.show_status_bar ~= false
    local Screen = require("device").screen

    local menu = StandalonePage.create_menu{
        name = "home",
        title = " ",
        no_title = not show_status_bar,
        block_filemanager_horizontal_swipe = true,
    }
    StandalonePage.prepare_shell(menu)
    menu._zen_home_strip_runtime = copy_home_strip_state(dcfg.strip_memory)

    local createStatusRow = _zen_shared and _zen_shared.createStatusRow
    local createStatusRowCustomBack = _zen_shared and _zen_shared.createStatusRowCustomBack
    local repaintTitleBar = _zen_shared and _zen_shared.repaintTitleBar
    if show_status_bar then
        StandalonePage.apply_status_row(menu, {
            createStatusRow = createStatusRow,
            createStatusRowCustomBack = createStatusRowCustomBack,
            repaintTitleBar = repaintTitleBar,
        })
    end
    menu._zen_home_show_status_bar = show_status_bar
    menu._zen_home_screen_width = Screen:getWidth()
    menu._zen_home_screen_height = Screen:getHeight()

    local rows = resolve_rows(dcfg)
    menu._zen_home_has_strip = rows_have_component(rows, "strip")
    local data_provider = build_data_provider(cfg, dcfg, _home_strip_page_state)
    local function remember_strip_pages()
        if data_provider and type(data_provider.getStripPageState) == "function" then
            _home_strip_page_state = data_provider:getStripPageState()
        end
    end
    local provider_dataset_expires_at = _home_dataset_cache and _home_dataset_cache.expires_at
    local has_clock_refreshers = rows_have_clock_refreshers(rows, dcfg)
    local has_date_dependent = rows_have_date_dependent(rows)
    menu._zen_home_has_clock_refreshers = has_clock_refreshers

    local function rebuild(refresh_stats)
        local started_at = os.clock()
        local stats_started_at = started_at
        if data_provider and type(data_provider.resetPerformanceStats) == "function" then
            data_provider:resetPerformanceStats()
        end
        if data_provider then
            if type(data_provider.prepareStats) == "function" then
                data_provider:prepareStats(rows, refresh_stats == true)
            elseif refresh_stats and type(data_provider.refreshStats) == "function" then
                data_provider:refreshStats(rows)
            end
        end
        local stats_ms = (os.clock() - stats_started_at) * 1000
        menu._zen_home_component_ms = {}
        local build_started_at = os.clock()
        local content = build_home_content(menu, cfg, dcfg, rows, data_provider)
        local build_ms = (os.clock() - build_started_at) * 1000
        provider_dataset_expires_at = _home_dataset_cache
            and _home_dataset_cache.expires_at
        local mount_started_at = os.clock()
        StandalonePage.mount_body(menu, content)
        local mount_ms = (os.clock() - mount_started_at) * 1000
        menu._zen_home_built_day = os.date("%Y-%j")
        menu._zen_home_needs_rebuild = nil
        menu._zen_home_refresh_stats = nil
        menu._zen_home_reload_config = nil
        request_home_repaint(menu, "ui")
        local perf = data_provider and data_provider.getPerformanceStats
            and data_provider:getPerformanceStats() or {}
        local component_times = {}
        for _i, comp in ipairs(rows) do
            component_times[#component_times + 1] = tostring(comp.id) .. ":"
                .. tostring(menu._zen_home_component_ms[comp.id] or 0)
        end
        local book_cache = string.format("%d/%d",
            perf.book_cache_hits or 0, perf.book_cache_misses or 0)
        local quote_ms = string.format("select:%.1f,annotation:%.1f,layout:%.1f",
            perf.quote_select_ms or 0,
            perf.quote_annotation_ms or 0,
            perf.quote_layout_ms or 0)
        local quote_cache = string.format(
            "annotation:%d/%d,sidecar:%d/%d,layout:%d/%d",
            perf.quote_annotation_cache_hits or 0,
            perf.quote_annotation_cache_misses or 0,
            perf.quote_sidecar_cache_hits or 0,
            perf.quote_sidecar_cache_misses or 0,
            perf.quote_layout_cache_hits or 0,
            perf.quote_layout_cache_misses or 0)
        local quote_work = string.format("books:%d,writes:%d,probes:%d",
            perf.quote_annotation_books or 0,
            perf.quote_state_writes or 0,
            perf.quote_layout_probes or 0)
        local home_ms = string.format("stats:%.1f,build:%.1f,mount:%.1f",
            stats_ms, build_ms, mount_ms)
        logger.perf("Home content rebuild completed", (os.clock() - started_at) * 1000,
            "rows=", #rows,
            "book_cache_hm=", book_cache,
            "book_lookup_ms=", perf.book_lookup_ms or 0,
            "quote_ms=", quote_ms,
            "quote_cache_hm=", quote_cache,
            "quote_work=", quote_work,
            "home_ms=", home_ms,
            "component_ms=", table.concat(component_times, ","),
            "dataset_generation=", perf.dataset_generation or 0)
    end

    function menu:_zen_home_refresh_clock_widgets(suppress_repaint)
        if self._zen_home_closing then return end
        local refreshed = 0
        for _i, refresh in ipairs(self._zen_home_clock_refreshers or {}) do
            if type(refresh) == "function" then
                local ok, did_refresh = pcall(refresh)
                if ok and did_refresh then
                    refreshed = refreshed + 1
                elseif not ok then
                    logger.warn("embedded clock refresh failed:", tostring(did_refresh))
                end
            end
        end
        if refreshed > 0 and suppress_repaint ~= true then
            request_home_repaint(self, "ui")
        end
    end

    local function refresh_home_clock_widgets_if_top()
        if menu._zen_home_closing or not rawequal(_home_menu, menu) then return end
        if not home_is_on_top(menu) then return end
        if menu._zen_home_refresh_clock_widgets then
            menu:_zen_home_refresh_clock_widgets()
        end
    end

    -- Date-dependent content (stats, daily quote) goes stale after a wakeup
    -- that crossed midnight. Force a stats re-query + rebuild when the home
    -- page is on top.
    local function refresh_home_date_dependent_if_top()
        if menu._zen_home_closing or not rawequal(_home_menu, menu) then return end
        if not home_is_on_top(menu) then return end
        if menu._zen_home_built_day == os.date("%Y-%j") then return end
        if menu._home_rebuild then menu:_home_rebuild(true) end
    end

    if show_status_bar then
        local status_refresh = menu._zen_status_refresh
        menu._zen_status_refresh = function(self, ...)
            local target = type(self) == "table" and self or menu
            if status_refresh then
                status_refresh(target, ...)
            end
            if target and target._zen_home_refresh_clock_widgets then
                target:_zen_home_refresh_clock_widgets(...)
            end
        end
    else
        menu._zen_status_refresh = nil
    end
    if not show_status_bar and has_clock_refreshers then
        -- Featured embedded status bar drives its own minute heartbeat via this
        -- bind. Flag it so the FileManager dispatcher skips clock-tick refreshes
        -- (avoids a double refresh) while still serving event-driven refreshes
        -- like Wi-Fi toggle / TouchMenu close.
        menu._zen_status_clock_bound = true
        pcall(function()
            require("common/clock_timer").bind(menu, function(target)
                if target and target._zen_home_refresh_clock_widgets then
                    target:_zen_home_refresh_clock_widgets()
                end
            end)
        end)
    end

    local resume_refreshes_clock = not show_status_bar and has_clock_refreshers
    if resume_refreshes_clock or has_date_dependent then
        local orig_onResume = menu.onResume
        function menu:onResume(...)
            local result
            if orig_onResume then
                result = orig_onResume(self, ...)
            end
            if resume_refreshes_clock then
                UIManager:scheduleIn(0.5, refresh_home_clock_widgets_if_top)
                UIManager:scheduleIn(1.5, refresh_home_clock_widgets_if_top)
            end
            if has_date_dependent then
                UIManager:scheduleIn(0.5, refresh_home_date_dependent_if_top)
            end
            return result
        end
    end

    if not show_status_bar and has_clock_refreshers then
        -- Charging events arrive in pairs during USB negotiation (NotCharging ->
        -- Charging) within a few seconds. Debounce into one refresh 1.5 s after
        -- the last event so an embedded featured status bar shows the charging
        -- indicator without waiting for the next minute clock tick.
        local charging_refresh_timer = nil
        local function scheduleChargingRefresh()
            if charging_refresh_timer then
                UIManager:unschedule(charging_refresh_timer)
            end
            charging_refresh_timer = function()
                charging_refresh_timer = nil
                refresh_home_clock_widgets_if_top()
            end
            UIManager:scheduleIn(1.5, charging_refresh_timer)
        end

        local function hookCharging(event_name)
            local orig = menu[event_name]
            menu[event_name] = function(self, ...)
                local result
                if orig then result = orig(self, ...) end
                scheduleChargingRefresh()
                return result
            end
        end
        hookCharging("onCharging")
        hookCharging("onNotCharging")

        -- Wifi state changes: refresh so an embedded featured status bar updates
        -- its wifi indicator without waiting for the next minute clock tick.
        local function hookNetwork(event_name)
            local orig = menu[event_name]
            menu[event_name] = function(self, ...)
                local result
                if orig then result = orig(self, ...) end
                refresh_home_clock_widgets_if_top()
                return result
            end
        end
        hookNetwork("onNetworkConnected")
        hookNetwork("onNetworkDisconnected")

        local orig_onSuspend = menu.onSuspend
        function menu:onSuspend(...)
            if charging_refresh_timer then
                UIManager:unschedule(charging_refresh_timer)
                charging_refresh_timer = nil
            end
            if orig_onSuspend then return orig_onSuspend(self, ...) end
        end
    end

    function menu:_home_rebuild(refresh_stats, reload_config)
        if self._zen_home_closing then return false end
        if self._zen_home_suspended == true or not home_is_on_top(self) then
            self._zen_home_needs_rebuild = true
            if refresh_stats == true then self._zen_home_refresh_stats = true end
            if reload_config == true then self._zen_home_reload_config = true end
            return false
        end
        refresh_shared_state()
        if reload_config == true then
            remember_strip_pages()
            local next_cfg = load_zen_config()
            if type(next_cfg) == "table" then
                cfg = next_cfg
                dcfg = ensure_home_cfg()
                self._zen_home_strip_runtime = copy_home_strip_state(dcfg.strip_memory)
                _home_dataset_cache = new_home_dataset()
                data_provider = build_data_provider(cfg, dcfg, _home_strip_page_state)
                provider_dataset_expires_at = _home_dataset_cache
                    and _home_dataset_cache.expires_at
            end
        end
        rows = resolve_rows(dcfg)
        self._zen_home_has_strip = rows_have_component(rows, "strip")
        has_clock_refreshers = rows_have_clock_refreshers(rows, dcfg)
        has_date_dependent = rows_have_date_dependent(rows)
        self._zen_home_has_clock_refreshers = has_clock_refreshers
        rebuild(refresh_stats == true)
        return true
    end

    function menu:_zen_home_resume()
        if self._zen_home_closing then return false, "closing" end
        if not home_is_on_top(self) then return false, "not_top" end
        if self._zen_home_screen_width ~= Screen:getWidth()
                or self._zen_home_screen_height ~= Screen:getHeight() then
            return false, "geometry_changed"
        end

        local reload_config = self._zen_home_reload_config == true
        if reload_config then
            local next_cfg = load_zen_config()
            if type(next_cfg) ~= "table" then return false, "config_unavailable" end
            local next_dcfg = ensure_home_cfg()
            if not home_shell_is_compatible(self, next_dcfg) then
                return false, "layout_changed"
            end
        end

        local started_at = now()
        local hidden_started_at = self._zen_home_suspended_at
        local was_suspended = self._zen_home_suspended == true
        local reasons = {}
        local current_time = os.time()
        local day_changed = has_date_dependent
            and self._zen_home_built_day ~= os.date("%Y-%j")
        local last_read_changed = consume_last_read_file()
        local dataset_expired = provider_dataset_expires_at ~= nil
            and current_time >= provider_dataset_expires_at
        local stats_fields = collect_stats_fields(rows, dcfg)
        local stats_expired = stats_fields_key(stats_fields) ~= ""
            and _home_stats_cache.value ~= nil
            and current_time >= _home_stats_cache.expires_at
        local quote_refresh = was_suspended
            and rows_have_component(rows, "quotes")
            and type(dcfg.quotes) == "table"
            and dcfg.quotes.rotation == "refresh"

        if reload_config then reasons[#reasons + 1] = "config" end
        if self._zen_home_needs_rebuild == true then reasons[#reasons + 1] = "stale" end
        if last_read_changed then reasons[#reasons + 1] = "last_read" end
        if dataset_expired then reasons[#reasons + 1] = "dataset" end
        if stats_expired then reasons[#reasons + 1] = "stats" end
        if day_changed then reasons[#reasons + 1] = "day" end
        if quote_refresh then reasons[#reasons + 1] = "quote" end

        if dataset_expired and not reload_config then
            remember_strip_pages()
            _home_dataset_cache = new_home_dataset()
            data_provider = build_data_provider(cfg, dcfg, _home_strip_page_state)
            provider_dataset_expires_at = _home_dataset_cache
                and _home_dataset_cache.expires_at
        end
        if (day_changed or quote_refresh) and data_provider
                and type(data_provider.clearQuote) == "function" then
            data_provider:clearQuote()
        end

        local needs_rebuild = reload_config
            or self._zen_home_needs_rebuild == true
            or last_read_changed or dataset_expired or stats_expired
            or day_changed or quote_refresh
        local refresh_stats = reload_config
            or self._zen_home_refresh_stats == true
            or stats_expired or day_changed
        self._zen_home_suspended = nil
        self._zen_home_suspended_at = nil

        local rebuilt = false
        if needs_rebuild then
            rebuilt = self:_home_rebuild(refresh_stats, reload_config) == true
        end
        if self._zen_status_refresh then
            self:_zen_status_refresh(true)
        elseif has_clock_refreshers and self._zen_home_refresh_clock_widgets then
            self:_zen_home_refresh_clock_widgets(true)
        end
        if not rebuilt then request_home_repaint(self, "ui") end

        logger.measure("Home retained view resumed", (now() - started_at) * 1000,
            "rebuilt=", tostring(rebuilt),
            "reason=", #reasons > 0 and table.concat(reasons, ",") or "reused",
            "hidden_ms=", hidden_started_at
                and math.floor((now() - hidden_started_at) * 1000 + 0.5) or 0)
        return true, rebuilt and "rebuilt" or "reused"
    end

    function menu:_zen_home_reset_strip_pages()
        if self._zen_home_closing or not data_provider
                or type(data_provider.resetStripPages) ~= "function" then
            return false
        end
        if not data_provider:resetStripPages() then return false end
        remember_strip_pages()
        self:_home_rebuild()
        return true
    end

    menu.close_callback = function()
        if menu._zen_home_closing then return end
        menu._zen_home_closing = true
        if rawequal(_home_menu, menu) then
            _home_menu = nil
        end
        UIManager:close(menu)
    end
    menu._zen_library_bg_reopen = function()
        return M.showHomeView(_home_inject_navbar) ~= nil
    end

    local orig_onCloseWidget = menu.onCloseWidget
    function menu:onCloseWidget(...)
        remember_strip_pages()
        self._zen_home_closing = true
        self._zen_home_strip_cover_listeners = {}
        if rawequal(_home_menu, self) then
            _home_menu = nil
        end
        if data_provider and type(data_provider.cancelTBRIndexAudit) == "function" then
            data_provider:cancelTBRIndexAudit()
        end
        pcall(function()
            require("common/clock_timer").unbind(self)
        end)
        if self.item_group and type(self.item_group.free) == "function" then
            WidgetResources.free(self.item_group)
            while #self.item_group > 0 do table.remove(self.item_group) end
        end
        if orig_onCloseWidget then
            return orig_onCloseWidget(self, ...)
        end
    end

    _home_menu = menu

    if injectNavbar then
        injectNavbar(menu, "home")
    end
    install_home_key_handlers(menu)

    UIManager:show(menu)
    UIManager:nextTick(function()
        rebuild(true)
        if menu._zen_status_refresh then
            menu:_zen_status_refresh()
        end
    end)
    return menu, true
end

function M.getActivePage()
    return _home_menu and (_home_menu.page or 1)
end

function M.getActiveWidgets()
    return _home_menu and { _home_menu } or {}
end

function M.suspendActive()
    local menu = _home_menu
    if not menu or menu._zen_home_closing then return false end
    menu._zen_home_focus_index = nil
    menu._zen_home_focus_id = nil
    menu._zen_home_focus_key = nil
    menu._zen_home_focus_suspended = nil
    if menu._zen_home_suspended ~= true then
        menu._zen_home_suspended = true
        menu._zen_home_suspended_at = now()
    end
    if UIManager._dirty then UIManager._dirty[menu] = nil end
    return true
end

function M.resumeActive()
    local menu = _home_menu
    if not menu or menu._zen_home_closing
            or type(menu._zen_home_resume) ~= "function" then
        return false, "missing"
    end
    if not home_is_on_top(menu) then return false, "not_top" end
    if menu._zen_navbar_refresh_pending == true then
        menu._zen_navbar_refresh_pending = nil
        if type(menu._zen_reinject_navbar) == "function"
                and menu:_zen_reinject_navbar() == "reopened" then
            return true, "rebuilt"
        end
    end
    return menu:_zen_home_resume()
end

function M.invalidateNavbar()
    local menu = _home_menu
    if not menu or menu._zen_home_closing
            or type(menu._zen_reinject_navbar) ~= "function" then
        return false
    end
    menu._zen_navbar_refresh_pending = true
    return true
end

function M.setCoverCacheBudget(bytes)
    bytes = tonumber(bytes)
    if not bytes or bytes < 0 then return false end
    _home_book_cache_byte_budget = math.floor(bytes)
    if _home_book_cache_byte_budget == 0 then
        for _i, key in ipairs(_home_book_cache_order) do
            remove_home_book_cache_entry(key)
        end
        _home_book_cache_order = {}
    else
        trim_home_book_cache()
    end
    return true
end

function M.getCoverCacheStats()
    return {
        bytes = _home_book_cache_bytes,
        byte_budget = _home_book_cache_byte_budget,
        count = #_home_book_cache_order,
    }
end

function M.invalidateBookCache(path, history_changed)
    invalidate_home_book_cache(path)
    invalidate_home_dataset_path(path, history_changed == true)
    pcall(function()
        require("common/tbr_index").refreshPath(path)
    end)
end

function M.invalidateLibraryCache()
    invalidate_home_library_dataset()
end

function M.invalidateTBRCache()
    local dataset = _home_dataset_cache
    if dataset then
        dataset.generation = dataset.generation + 1
        dataset.tbr_revision = nil
        dataset.tbr = nil
        dataset.ordered_paths = {}
        dataset.strip_paths = {}
    end
    M.rebuildActive()
end

function M.rebuildActive()
    if _home_menu and _home_menu._home_rebuild then
        if _home_menu._zen_home_suspended == true
                or not home_is_on_top(_home_menu) then
            mark_home_rebuild_needed(true, true)
            request_home_repaint(_home_menu, "ui")
            return true
        end
        local cfg = load_zen_config()
        local dcfg = type(cfg) == "table" and ensure_home_cfg() or nil
        if dcfg and not home_shell_is_compatible(_home_menu, dcfg) then
            local old_menu = _home_menu
            _home_menu = nil
            old_menu._zen_home_closing = true
            UIManager:close(old_menu)
            M.showHomeView(_home_inject_navbar)
            return true
        end
        _home_menu:_home_rebuild(true, true)
        return true
    end
    return false
end

function M.showTagInStrip(tag)
    if type(tag) ~= "string" or tag == "" or not _home_menu
            or _home_menu._zen_home_has_strip ~= true then return false end
    local state = { source = { kind = "tag", value = tag } }
    _home_menu._zen_home_strip_runtime = state
    _home_strip_page_state = nil
    save_home_strip_state(ensure_home_cfg(), state)
    return M.rebuildActive()
end

function M.resetStripPages()
    if not (M.isActiveOnTop() and _home_menu and _home_menu._zen_home_reset_strip_pages) then
        return false
    end
    return _home_menu:_zen_home_reset_strip_pages()
end

function M.refreshDateDependentActive()
    if not (M.isActiveOnTop() and _home_menu and _home_menu._home_rebuild) then
        return false
    end
    local cfg = load_zen_config()
    local dcfg = type(cfg) == "table" and ensure_home_cfg() or nil
    if not dcfg or not rows_have_date_dependent(resolve_rows(dcfg)) then
        return false
    end
    _home_menu:_home_rebuild(true)
    return true
end

function M.hasActive()
    return _home_menu ~= nil
end

function M.isActiveOnTop()
    if not _home_menu then return false end
    return home_is_on_top(_home_menu)
end

function M.closeAll()
    local menu = _home_menu
    if menu then
        _home_menu = nil
        if not menu._zen_home_closing then
            menu._zen_home_closing = true
            UIManager:close(menu)
        end
    end
end

Registry.setRefreshCallback(M.rebuildActive)
MemoryPolicy.registerHomeCache(M)

local function register_home_api(zen_plugin)
    if not zen_plugin or type(zen_plugin.config) ~= "table" then return end
    _zen_shared = SharedState.register(zen_plugin, { home = M })
    _zen_plugin = zen_plugin
end

SharedState.registerLoader("home", register_home_api)

return function()
    register_home_api(rawget(_G, "__ZEN_UI_PLUGIN"))
end
