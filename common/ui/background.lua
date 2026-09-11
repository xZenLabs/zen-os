-- common/ui/background.lua
-- Cover-fit background image painter shared by the library file browser and the
-- standalone Zen pages (Home, Group view, Stats). "Cover" = scale the image to
-- fill the target rect, keeping aspect ratio and cropping the overflow, centered.
--
-- ImageWidget's built-in scale_factor == 0 means "contain" (best fit, letterbox),
-- so we compute the cover scale_factor ourselves and let ImageWidget's offset
-- logic center-crop the oversized blitbuffer down to width x height.

local Device = require("device")
local Blitbuffer = require("ffi/blitbuffer")
local logger = require("common/zen_logger").new("background")
local _ = require("gettext")
local Screen = Device.screen

local ok_iw, ImageWidget = pcall(require, "ui/widget/imagewidget")
if not ok_iw then ImageWidget = nil end

local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
if not ok_lfs then lfs = nil end

local M = {}

-- Cache the constructed cover-fit ImageWidget keyed by "path|w|h".
local _cache = {}
local _buffer_cache = {}
local _missing_recovery_handler
local _missing_recovery_pending = false
local _missing_recovery_running = false
local _missing_notice_pending = false
local _missing_work_scheduled = false

local function run_missing_background_work()
    _missing_work_scheduled = false
    if _missing_recovery_pending and type(_missing_recovery_handler) == "function" then
        _missing_recovery_running = true
        local ok, recovered = pcall(_missing_recovery_handler)
        _missing_recovery_running = false
        if ok and recovered ~= false then
            _missing_recovery_pending = false
        elseif not ok then
            logger.warn("missing library background recovery failed:", tostring(recovered))
        end
    end
    if not _missing_notice_pending then return end
    _missing_notice_pending = false
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    local ok_notification, Notification = pcall(require, "ui/widget/notification")
    if ok_ui and ok_notification and type(UIManager.show) == "function"
            and type(Notification.new) == "function" then
        local notice = Notification:new{
            text = _("Library background was disabled because the image file was not found."),
        }
        local orig_on_close_widget = notice.onCloseWidget
        function notice:onCloseWidget(...)
            local result
            if orig_on_close_widget then
                result = orig_on_close_widget(self, ...)
            end
            -- Home may finish rebuilding while this toast is on top.
            local function repaint_rebuilt_surface()
                if type(UIManager.setDirty) == "function" then
                    UIManager:setDirty("all", "full")
                end
            end
            if type(UIManager.nextTick) == "function" then
                UIManager:nextTick(repaint_rebuilt_surface)
            else
                repaint_rebuilt_surface()
            end
            return result
        end
        UIManager:show(notice)
    end
end

local function schedule_missing_background_work()
    if _missing_work_scheduled or _missing_recovery_running
            or not (_missing_recovery_pending or _missing_notice_pending) then
        return
    end
    if not _missing_notice_pending and type(_missing_recovery_handler) ~= "function" then
        return
    end
    local ok_ui, UIManager = pcall(require, "ui/uimanager")
    if ok_ui and type(UIManager.nextTick) == "function" then
        _missing_work_scheduled = true
        UIManager:nextTick(run_missing_background_work)
    else
        run_missing_background_work()
    end
end

local function file_exists(path)
    if type(path) ~= "string" or path == "" then return false end
    if not lfs then return true end  -- can't check; assume present
    return lfs.attributes(path, "mode") == "file"
end

local function disable_missing_library_background(plugin, cfg, bg, path)
    bg.enabled = false
    if plugin and plugin.config == cfg and type(plugin.saveConfig) == "function" then
        pcall(plugin.saveConfig, plugin)
    else
        local ok_config, ConfigManager = pcall(require, "config/manager")
        if ok_config and type(ConfigManager.save) == "function" then
            pcall(ConfigManager.save, cfg)
        end
    end
    M.clearCache()
    logger.warn("disabled missing library background", path)
    _missing_recovery_pending = true
    _missing_notice_pending = true
    schedule_missing_background_work()
end

function M.setMissingLibraryBackgroundHandler(handler)
    _missing_recovery_handler = type(handler) == "function" and handler or nil
    schedule_missing_background_work()
end

local function is_supported_image_path(path)
    if type(path) ~= "string" then return false end
    local lower = path:lower()
    return lower:sub(-4) == ".jpg" or lower:sub(-5) == ".jpeg"
        or lower:sub(-4) == ".png"
end

M.isSupportedImagePath = is_supported_image_path

-- Native (unscaled) image dimensions, or nil on failure.
local function native_size(path)
    if not ImageWidget then return nil end
    local probe = ImageWidget:new{ file = path, scale_factor = 1, file_do_cache = false }
    local ok = pcall(function() probe:getSize() end)
    local w = ok and probe._img_w or nil
    local h = ok and probe._img_h or nil
    pcall(function() probe:free() end)
    if w and h and w > 0 and h > 0 then return w, h end
    return nil
end

-- Validate that a path can be used as a background image. Returns (true) on
-- success, or (false, reason_code) on failure. "Can be used" means: it's a
-- JPG/JPEG/PNG, the file exists, and the decoder can read its size. The caller
-- maps reason_code to a translated message.
function M.validateImage(path)
    if type(path) ~= "string" or path == "" then
        return false, "none"
    end
    if not is_supported_image_path(path) then
        return false, "unsupported"
    end
    if not file_exists(path) then
        return false, "missing"
    end
    if not ImageWidget then
        return false, "no_decoder"
    end
    local w, h = native_size(path)
    if not w or not h then
        return false, "decode_failed"
    end
    return true
end

-- Build (or fetch cached) a cover-fit ImageWidget for the given rect.
local function get_widget(path, w, h)
    if not ImageWidget or w <= 0 or h <= 0 or not file_exists(path) then
        return nil
    end
    local key = string.format("%s|%d|%d", path, w, h)
    local cached = _cache[key]
    if cached then return cached end

    local img_w, img_h = native_size(path)
    if not img_w then return nil end

    -- Cover: scale so the image fully covers the rect (max of the two ratios).
    local scale = math.max(w / img_w, h / img_h)
    local iw = ImageWidget:new{
        file = path,
        width = w,
        height = h,
        scale_factor = scale,
        center_x_ratio = 0.5,
        center_y_ratio = 0.5,
        file_do_cache = false,
        alpha = true,
    }
    _cache[key] = iw
    return iw
end

-- Paint the background image filling (x, y, w, h). No-op if path empty/missing.
function M.paint(bb, x, y, w, h, path)
    if not bb or type(path) ~= "string" or path == "" then return false end
    local painted = false
    local ok, err = pcall(function()
        local iw = get_widget(path, w, h)
        if not iw then return end
        iw:paintTo(bb, x, y)
        if Screen.night_mode then
            bb:invertRect(x, y, w, h)
        end
        painted = true
    end)
    if not ok then
        logger.warn("paint failed for", tostring(path), tostring(err))
    end
    return ok and painted
end

local function get_screen_buffer(path, w, h, bb_type)
    if not ImageWidget or not file_exists(path) or w <= 0 or h <= 0 then
        return nil
    end
    local night_key = Screen.night_mode and "night" or "day"
    local opacity = M.library_opacity()
    local key = string.format("%s|%d|%d|%s|%s|%d", path, w, h,
        tostring(bb_type), night_key, opacity)
    local cached = _buffer_cache[key]
    if cached then return cached end

    local out
    local ok = pcall(function()
        out = Blitbuffer.new(w, h, bb_type or Screen.bb:getType())
        out:fill(Blitbuffer.COLOR_WHITE)
        local iw = get_widget(path, w, h)
        if not iw then error("no background widget") end
        iw:paintTo(out, 0, 0)
        if Screen.night_mode then
            out:invertRect(0, 0, w, h)
        end
        if opacity < 100 then
            local fade = 1 - opacity / 100
            if Screen.night_mode then
                out:darkenRect(0, 0, w, h, fade)
            else
                out:lightenRect(0, 0, w, h, fade)
            end
        end
    end)
    if not ok or not out then
        if out then pcall(function() out:free() end) end
        return nil
    end
    _buffer_cache[key] = out
    return out
end

function M.paintScreenRegion(bb, dst_x, dst_y, src_x, src_y, w, h, path)
    if not bb or type(path) ~= "string" or path == "" then return false end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local src = get_screen_buffer(path, sw, sh, bb:getType())
    if not src then return false end

    local sx = math.max(0, src_x)
    local sy = math.max(0, src_y)
    local dx = dst_x + (sx - src_x)
    local dy = dst_y + (sy - src_y)
    local copy_w = math.min(w - (sx - src_x), sw - sx)
    local copy_h = math.min(h - (sy - src_y), sh - sy)
    if copy_w <= 0 or copy_h <= 0 then return false end
    bb:blitFrom(src, dx, dy, sx, sy, copy_w, copy_h)
    return true
end

local function is_white(value)
    if not value then return false end
    local ok, same = pcall(function()
        return value == Blitbuffer.COLOR_WHITE
    end)
    return ok and same == true
end

M.isWhite = is_white

function M.clearWhiteBackgrounds(widget, max_depth)
    max_depth = max_depth or 12

    local function walk(w, depth)
        if type(w) ~= "table" or depth > max_depth then return end
        if is_white(w.background) and not w._zen_keep_background then
            w.background = nil
        end
        for i = 1, #w do
            walk(w[i], depth + 1)
        end
    end

    walk(widget, 0)
end

-- Render the image cover-fit into a freshly allocated blitbuffer of size w x h.
-- Caller owns the returned bb and must free it. Returns nil on failure.
function M.renderToBuffer(path, w, h)
    if not ImageWidget or not file_exists(path) or w <= 0 or h <= 0 then
        return nil
    end
    local out
    local ok = pcall(function()
        out = Blitbuffer.new(w, h, Screen.bb:getType())
        out:fill(Blitbuffer.COLOR_WHITE)
        local img_w, img_h = native_size(path)
        if not img_w then error("no native size") end
        local scale = math.max(w / img_w, h / img_h)
        local iw = ImageWidget:new{
            file = path,
            width = w,
            height = h,
            scale_factor = scale,
            center_x_ratio = 0.5,
            center_y_ratio = 0.5,
            file_do_cache = false,
            alpha = true,
        }
        iw:paintTo(out, 0, 0)
        iw:free()
    end)
    if not ok or not out then
        if out then pcall(function() out:free() end) end
        return nil
    end
    return out
end

-- True when a library background image is configured. Home/standalone widget
-- tiles use this to switch their opaque fill to nil (transparent) so the
-- background painted behind the page shows through.
local function library_config(plugin)
    plugin = plugin or rawget(_G, "__ZEN_UI_PLUGIN")
    local cfg = plugin and plugin.config
    if type(cfg) ~= "table" then
        local ok, loaded = pcall(function()
            local ConfigManager = require("config/manager")
            return ConfigManager.get() or ConfigManager.load()
        end)
        cfg = ok and loaded or nil
    end
    return cfg, plugin
end

function M.library_opacity(plugin)
    local cfg = library_config(plugin)
    local bg = type(cfg) == "table" and cfg.library_background
    local opacity = type(bg) == "table" and tonumber(bg.opacity) or 100
    return math.max(0, math.min(100, math.floor(opacity + 0.5)))
end

function M.library_path(plugin)
    schedule_missing_background_work()
    local cfg, resolved_plugin = library_config(plugin)
    local bg = type(cfg) == "table" and cfg.library_background
    local path = type(bg) == "table" and type(bg.path) == "string" and bg.path or ""
    if type(bg) == "table" and bg.enabled == true
            and is_supported_image_path(path) then
        if not file_exists(path) then
            disable_missing_library_background(resolved_plugin, cfg, bg, path)
            return ""
        end
        return path
    end
    return ""
end

function M.library_active()
    return M.library_path() ~= ""
end

-- Fill color for a home/standalone tile: nil (transparent) when a background
-- image is active, otherwise the supplied opaque default (COLOR_WHITE).
function M.tile_bg(default)
    local active = M.library_active()
    if active then return nil end
    return default
end

function M.applyToMenu(menu, max_depth)
    if not menu or menu._zen_bg_applied then return end
    menu._zen_bg_applied = true
    max_depth = max_depth or 14

    local orig_paintTo = menu.paintTo
    function menu:paintTo(bb, x, y)
        local path = M.library_path()
        if path ~= "" then
            -- Menu:updateItems may rebuild self[1] with opaque white fills.
            M.clearWhiteBackgrounds(self[1], max_depth)
            if self.dimen then
                M.paintScreenRegion(bb, 0, 0, 0, 0,
                    self.dimen.w, self.dimen.h, path)
            else
                M.paintScreenRegion(bb, 0, 0, 0, 0,
                    Screen:getWidth(), Screen:getHeight(), path)
            end
        end
        if orig_paintTo then
            return orig_paintTo(self, bb, x, y)
        end
    end
end

-- Drop all cached widgets (call when the configured path changes).
function M.clearCache()
    for k, iw in pairs(_cache) do
        pcall(function() iw:free() end)
        _cache[k] = nil
    end
    for k, cached_bb in pairs(_buffer_cache) do
        pcall(function() cached_bb:free() end)
        _buffer_cache[k] = nil
    end
end

return M
