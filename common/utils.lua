local M = {}

local OPTICAL_ICON_SCALES = {
    zenfm = 1.25,
    zenpm = 1.25,
    zen_ui = 1.25,
}

function M.iconOpticalScale(name)
    if type(name) ~= "string" then return 1 end
    local filename = name:match("([^/]+)$") or name
    local stem = filename:gsub("%.[^.]+$", "")
    return OPTICAL_ICON_SCALES[stem] or 1
end

local function utf8_char_count(text)
    local count = 0
    for _pos in tostring(text):gmatch("()[%z\1-\127\194-\244][\128-\191]*") do
        count = count + 1
    end
    return count
end

local function utf8_prefix(text, max_chars)
    if max_chars <= 0 then return "" end
    local count = 0
    for pos in tostring(text):gmatch("()[%z\1-\127\194-\244][\128-\191]*") do
        count = count + 1
        if count > max_chars then
            return text:sub(1, pos - 1)
        end
    end
    return text
end

--- Truncate by UTF-8 codepoint count without splitting a multibyte character.
--- max_chars includes the ellipsis length.
function M.truncateUtf8(text, max_chars, ellipsis)
    if type(text) ~= "string" then return text end
    max_chars = math.floor(tonumber(max_chars) or 0)
    if max_chars <= 0 then return "" end
    ellipsis = ellipsis or "..."
    if utf8_char_count(text) <= max_chars then return text end
    local keep = max_chars - utf8_char_count(ellipsis)
    if keep <= 0 then return utf8_prefix(ellipsis, max_chars) end
    return utf8_prefix(text, keep) .. ellipsis
end

local function is_utf8_continuation(byte)
    return byte and byte >= 0x80 and byte <= 0xBF
end

--- Truncate to a byte budget while keeping valid UTF-8 boundaries.
--- suffix is included in max_bytes.
function M.truncateUtf8Bytes(text, max_bytes, suffix)
    if type(text) ~= "string" then return text end
    max_bytes = math.floor(tonumber(max_bytes) or 0)
    if max_bytes <= 0 then return "" end
    suffix = suffix or ""
    if #text <= max_bytes then return text end
    local keep = max_bytes - #suffix
    if keep <= 0 then return suffix:sub(1, max_bytes) end
    while keep > 0 and is_utf8_continuation(text:byte(keep + 1)) do
        keep = keep - 1
    end
    return text:sub(1, keep) .. suffix
end

--- Return a suffix within max_bytes without starting inside a UTF-8 sequence.
function M.utf8SafeSuffix(text, max_bytes)
    if type(text) ~= "string" then return text end
    max_bytes = math.floor(tonumber(max_bytes) or 0)
    if max_bytes <= 0 then return "" end
    if #text <= max_bytes then return text end
    local start = #text - max_bytes + 1
    while start <= #text and is_utf8_continuation(text:byte(start)) do
        start = start + 1
    end
    return text:sub(start)
end

function M.deepcopy(value)
    if type(value) ~= "table" then
        return value
    end

    local result = {}
    for k, v in pairs(value) do
        result[M.deepcopy(k)] = M.deepcopy(v)
    end
    return result
end

function M.controlReplacesMenuTab(config, id)
    local features = config and config.features
    local controls = config and config.quick_settings
    local buttons = type(controls) == "table" and controls.show_buttons
    local tour_pending = config and config._meta
        and config._meta.quickstart_menu_tour_pending == true
    return not tour_pending and type(features) == "table" and features.quick_settings == true
        and type(buttons) == "table" and buttons[id] == true
end

-- Returns true when t is a sequential array (no holes, integer keys from 1).
local function _is_array(t)
    local n = 0
    for _k in pairs(t) do n = n + 1 end
    return n > 0 and n == #t
end

function M.deepmerge(dst, src)
    if type(dst) ~= "table" or type(src) ~= "table" then
        return src
    end

    -- Never merge into an existing array: arrays are treated as opaque values.
    -- An empty table inherits src's shape because Lua cannot identify it alone.
    if _is_array(dst) or (next(dst) == nil and _is_array(src)) then
        return dst
    end

    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            M.deepmerge(dst[k], v)
        elseif dst[k] == nil then
            dst[k] = M.deepcopy(v)
        end
    end

    return dst
end

function M.set_at_path(tbl, path, value)
    local node = tbl
    for i = 1, #path - 1 do
        local key = path[i]
        if type(node[key]) ~= "table" then
            node[key] = {}
        end
        node = node[key]
    end
    node[path[#path]] = value
end

--- Resolve an icon name to an absolute file path (checks .svg then .png).
--- @param icons_dir string  absolute path ending with "/"
--- @param name      string  icon name without extension
--- @return          string|nil
function M.resolveLocalIcon(icons_dir, name)
    if not icons_dir or not name then return nil end
    local lfs = require("libs/libkoreader-lfs")
    for _i, ext in ipairs({ ".svg", ".png" }) do
        local p = icons_dir .. name .. ext
        if lfs.attributes(p, "mode") == "file" then return p end
    end
    return nil
end

--- Absolute path (with trailing slash) to KOReader's user icons directory.
function M.getUserIconsDir()
    local ok, DataStorage = pcall(require, "datastorage")
    if not ok or not DataStorage then return nil end
    return DataStorage:getDataDir() .. "/icons/"
end

--- Copy the selected default-tab icon into KOReader's user icons dir.
--- Existing user icons are left untouched so a user's override always wins.
function M.copyDefaultCustomTabIcon(plugin_icons_dir, navbar)
    if type(navbar) ~= "table" or type(navbar.default_tab) ~= "string" then
        return false
    end

    local icon_name = navbar.default_tab == "folder" and navbar.folder_icon or nil
    if type(navbar.custom_tabs) == "table" then
        for _i, tab in ipairs(navbar.custom_tabs) do
            if type(tab) == "table" and tab.id == navbar.default_tab then
                icon_name = tab.icon
                break
            end
        end
    end
    if type(icon_name) ~= "string" or not icon_name:match("^[%w._-]+$") then
        return false
    end

    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    local user_dir = M.getUserIconsDir()
    if not ok or not lfs or not user_dir then return false end
    if M.resolveLocalIcon(user_dir, icon_name) then return true end

    local source
    if plugin_icons_dir then
        source = M.resolveLocalIcon(plugin_icons_dir, icon_name)
    end
    if not source then
        source = M.resolveLocalIcon(lfs.currentdir() .. "/resources/icons/mdlight/", icon_name)
    end
    if not source then return false end

    local parent_dir = user_dir:sub(1, -2)
    if lfs.attributes(parent_dir, "mode") ~= "directory" and not lfs.mkdir(parent_dir) then
        return false
    end
    local ext = source:match("(%.[^./]+)$") or ".svg"
    local ok_copy, ffiutil = pcall(require, "ffi/util")
    if not ok_copy or not ffiutil then return false end
    return ffiutil.copyFile(source, user_dir .. icon_name .. ext) == true
end

local _custom_icons_enabled
function M.isCustomIconsEnabled()
    if _custom_icons_enabled ~= nil then return _custom_icons_enabled end
    _custom_icons_enabled = false
    pcall(function()
        local ConfigManager = require("config/manager")
        local cfg = ConfigManager.load()
        if cfg and cfg.features and cfg.features.custom_icons_enabled == true then
            _custom_icons_enabled = true
        end
    end)
    return _custom_icons_enabled
end

--- Resolve an icon from the active pack or loose icons, then bundled icons.
--- @param plugin_icons_dir string  absolute path ending with "/"
--- @param name             string  icon name without extension
--- @return                 string|nil
function M.resolveIcon(plugin_icons_dir, name)
    if not plugin_icons_dir or not name then return nil end
    local ok_packs, icon_packs = pcall(require, "common/icon_packs")
    if ok_packs and icon_packs then
        return icon_packs.resolve(name, plugin_icons_dir)
    end
    if M.isCustomIconsEnabled() then
        local user_dir = M.getUserIconsDir()
        if user_dir then
            local p = M.resolveLocalIcon(user_dir, name)
            if p then return p end
        end
    end
    return M.resolveLocalIcon(plugin_icons_dir, name)
end

--- Register plugin icons so short names resolve via IconWidget at runtime.
--- Optionally copies files to the user icons dir for cold-start resolution.
---
--- @param icons_dir        string   absolute path to the plugin icons dir, ending with "/"
--- @param icons            table    { [icon_name] = "filename.ext", ... }
--- @param copy_to_user_dir boolean  also copy files to DataStorage icons dir
function M.registerPluginIcons(icons_dir, icons, copy_to_user_dir)
    if not icons_dir or type(icons) ~= "table" then return end
    pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        local user_icons_dir = M.isCustomIconsEnabled() and M.getUserIconsDir() or nil

        if copy_to_user_dir then
            pcall(function()
                local DataStorage = require("datastorage")
                local ffiutil = require("ffi/util")
                local dest_icons_dir = DataStorage:getDataDir() .. "/icons"
                if lfs.attributes(dest_icons_dir, "mode") ~= "directory" then
                    lfs.mkdir(dest_icons_dir)
                end
                for name, filename in pairs(icons) do
                    -- Use icon short-name as dest so ICONS_DIRS lookup finds it by name
                    local ext = filename:match("%.[^%.]+$") or ".svg"
                    local dst = dest_icons_dir .. "/" .. name .. ext
                    if lfs.attributes(dst, "mode") ~= "file" then
                        local src = icons_dir .. filename
                        if lfs.attributes(src, "mode") == "file" then
                            ffiutil.copyFile(src, dst)
                        end
                    end
                end
            end)
        end

        -- Inject into IconWidget's runtime upvalue caches
        local iw = require("ui/widget/iconwidget")
        local iw_init = rawget(iw, "init")
        if type(iw_init) ~= "function" then return end
        local icons_path, icons_dirs
        for i = 1, 64 do
            local uname, uval = debug.getupvalue(iw_init, i)
            if uname == nil then break end
            if uname == "ICONS_PATH" and type(uval) == "table" then
                icons_path = uval
            elseif uname == "ICONS_DIRS" and type(uval) == "table" then
                icons_dirs = uval
            end
            if icons_path and icons_dirs then break end
        end
        -- Ensure user icons dir is in ICONS_DIRS (may have been absent at widget load time)
        if icons_dirs and copy_to_user_dir then
            pcall(function()
                local DataStorage = require("datastorage")
                local user_dir = DataStorage:getDataDir() .. "/icons"
                local found = false
                for _i, d in ipairs(icons_dirs) do
                    if d == user_dir then found = true; break end
                end
                if not found then table.insert(icons_dirs, 1, user_dir) end
            end)
        end
        if not icons_path then return end
        for name, filename in pairs(icons) do
            if not icons_path[name] then
                local user_p = user_icons_dir and M.resolveLocalIcon(user_icons_dir, name) or nil
                if user_p then
                    icons_path[name] = user_p
                else
                    local p = icons_dir .. filename
                    if lfs.attributes(p, "mode") == "file" then
                        icons_path[name] = p
                    end
                end
            end
        end
    end)
end

--- Override built-in KOReader icons by name at runtime (does not modify disk).
--- @param overrides table  map of icon_name → absolute replacement path
--- @param prefer_user_icon boolean|nil  allow a loose user icon to take precedence
function M.overrideIcons(overrides, prefer_user_icon)
    local lfs = require("libs/libkoreader-lfs")
    local user_icons_dir = prefer_user_icon ~= false and M.isCustomIconsEnabled()
        and M.getUserIconsDir() or nil
    local valid = {}
    for name, path in pairs(overrides) do
        local user_p = user_icons_dir and M.resolveLocalIcon(user_icons_dir, name) or nil
        local chosen = user_p or path
        if lfs.attributes(chosen, "mode") == "file" then
            valid[name] = chosen
        end
    end
    if not next(valid) then return end

    local iw = require("ui/widget/iconwidget")
    local orig_init = iw.init
    function iw:init()
        orig_init(self)
        if valid[self.icon] then
            self.file = valid[self.icon]
        end
    end
end

local __ = require("gettext")

--- Localised page-count label (abbreviated or full word form).
--- @param pages number
--- @param long  boolean|nil  true for full form ("pages"), false for short ("p.")
--- @return string
function M.formatPageCount(pages, long)
    local label = long and __("pages") or __("p.")
    return tostring(pages) .. "\u{00A0}" .. label
end

--- Resolve the stable page count, optionally reusing metadata already read by
--- the caller. context fields: doc_settings, sidecar_checked, book_info, and
--- book_info_checked.
function M.getStablePageCount(filepath, fallback, context)
    if type(filepath) ~= "string" or filepath == "" then
        return fallback
    end

    context = type(context) == "table" and context or {}
    local trace = type(context.trace) == "table" and context.trace or nil
    local function trace_read(key)
        if trace then trace[key] = (tonumber(trace[key]) or 0) + 1 end
    end
    local doc = context.doc_settings
    if not doc and context.sidecar_checked ~= true then
        local ok_ds, DocSettings = pcall(require, "docsettings")
        if ok_ds and DocSettings and DocSettings:hasSidecarFile(filepath) then
            trace_read("sidecar_opens")
            local ok_doc, opened_doc = pcall(DocSettings.open, DocSettings, filepath)
            if ok_doc then doc = opened_doc end
        end
    end
    local function read_doc_number(key)
        if not (doc and type(doc.readSetting) == "function") then return nil end
        local value = tonumber(doc:readSetting(key))
        return value and value > 0 and value or nil
    end

    if doc and doc:readSetting("pagemap_use_page_labels") == true then
        local pages = read_doc_number("pagemap_doc_pages")
            or read_doc_number("pagemap_last_page_label")
        if pages and pages > 0 then return pages end
    end

    local pages = read_doc_number("doc_pages")
    if not pages and doc and type(doc.readSetting) == "function" then
        local stats = doc:readSetting("stats")
        pages = type(stats) == "table" and tonumber(stats.pages) or nil
    end
    if pages and pages > 0 then return pages end

    local book = context.book_info
    pages = type(book) == "table" and tonumber(book.pages) or nil
    if pages and pages > 0 then return pages end

    fallback = tonumber(fallback)
    if fallback and fallback > 0 then return fallback end

    if type(book) ~= "table" and context.book_info_checked ~= true then
        local ok_bl, BookList = pcall(require, "ui/widget/booklist")
        if ok_bl and BookList then
            trace_read("booklist_reads")
            local ok_book, loaded_book = pcall(BookList.getBookInfo, filepath)
            if ok_book then book = loaded_book end
        end
    end
    pages = book and tonumber(book.pages)
    if pages and pages > 0 then return pages end
    return nil
end

--- Scale multiplier for mosaic cover badge sizes (compact=1.0, normal=1.10, large=1.20).
--- Returns the corner inset for badge positioning (same value for all 4 corners).
--- Changing the factor here moves all badges in/out uniformly.
--- @param r number  the badge radius (or half-height for pill badges)
--- @return number
function M.getBadgeInset(r)
    return math.floor(r * 0.40)
end

function M.paintBadgeCircle(bb, cx, cy, radius, color)
    for row = -radius, radius do
        local half = math.floor(math.sqrt(math.max(0, radius * radius - row * row)))
        if half > 0 then bb:paintRectRGB32(cx - half, cy + row, 2 * half, 1, color) end
    end
end

function M.paintBadgeCheck(bb, x, y, width, height, color)
    local thickness = math.max(2, math.floor(math.min(width, height) / 8))
    local function line(x0, y0, x1, y1)
        local steps = math.max(math.abs(x1 - x0), math.abs(y1 - y0))
        if steps == 0 then steps = 1 end
        for step = 0, steps do
            local t = step / steps
            bb:paintRectRGB32(math.floor(x0 + t * (x1 - x0)),
                math.floor(y0 + t * (y1 - y0)), thickness, thickness, color)
        end
    end
    local lx0, ly0 = x + math.floor(width * 0.08), y + math.floor(height * 0.62)
    local lx1, ly1 = x + math.floor(width * 0.30), y + math.floor(height * 0.82)
    line(lx0, ly0, lx1, ly1)
    line(lx1, ly1, x + math.floor(width * 0.82), y + math.floor(height * 0.18))
end

--- @param config table|nil  the plugin config table (p.config)
--- @return number
function M.getBadgeScale(config)
    local sz = type(config) == "table"
        and type(config.browser_cover_badges) == "table"
        and config.browser_cover_badges.badge_size
    if sz == "extra_large" then return 1.50 end
    if sz == "large"       then return 1.20 end
    if sz == "normal"      then return 1.10 end
    return 1.0
end

local function get_badge_rgb(config)
    local c = type(config) == "table"
        and type(config.browser_cover_badges) == "table"
        and config.browser_cover_badges.badge_color
    if type(c) == "table" then
        local r = math.max(0, math.min(255, tonumber(c[1] or c.r) or 0))
        local g = math.max(0, math.min(255, tonumber(c[2] or c.g) or 0))
        local b = math.max(0, math.min(255, tonumber(c[3] or c.b) or 0))
        return r, g, b
    end
end

--- Returns the configured badge background color, or COLOR_LIGHT_GRAY if not set.
--- @param config table|nil  the plugin config table (p.config)
--- @return userdata  Blitbuffer color
function M.getBadgeColor(config)
    local Blitbuffer = require("ffi/blitbuffer")
    local r, g, b = get_badge_rgb(config)
    if r then
        return Blitbuffer.ColorRGB32(r, g, b, 255)
    end
    return Blitbuffer.COLOR_BLACK
end

--- True when badge fill should use white contrast text/outline.
--- Mirrors the file-browser badge patches: default/black is dark; custom colors use black.
function M.isBadgeDark(config)
    local r, g, b = get_badge_rgb(config)
    return r == nil or (r == 0 and g == 0 and b == 0)
end

--- Returns the foreground color for text/icons drawn inside a badge.
--- White when the badge fill is black (0,0,0), black otherwise.
function M.getBadgeTextColor(config)
    local Blitbuffer = require("ffi/blitbuffer")
    if M.isBadgeDark(config) then
        return Blitbuffer.COLOR_WHITE
    end
    return Blitbuffer.COLOR_BLACK
end

--- Return a canonical UI label without changing compatibility icon IDs.
function M.getIconDisplayName(name)
    return name == "zen_ui" and "ZenOS" or name
end

--- Build the combined {name, file} icon list for the icon picker.
--- Sources are ordered by the active pack resolution precedence.
--- @param plugin_root string   absolute path to the plugin root (no trailing slash)
--- @param excluded    table|nil  set of icon name strings to skip in the plugin group
--- @return table  list of {name=string, file=string}
function M.getIconPickerList(plugin_root, excluded)
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if not ok or not lfs then return {} end
    local seen = {}
    local all  = {}
    local function addDir(dir, filter, allow)
        if not dir then return end
        dir = dir:match("^(.*[^/])/*$") or dir  -- strip trailing slash
        if lfs.attributes(dir, "mode") ~= "directory" then return end
        local entries = {}
        for f in lfs.dir(dir) do
            if f:match("%.svg$") and not f:match("%.bak%.svg$") then
                local name = f:sub(1, -5)
                if not seen[name] and (not filter or not filter[name])
                        and (not allow or allow(name)) then
                    entries[#entries + 1] = { name = name, file = dir .. "/" .. f }
                end
            end
        end
        table.sort(entries, function(a, b) return a.name < b.name end)
        for _i, item in ipairs(entries) do
            seen[item.name] = true
            all[#all + 1] = item
        end
    end
    local icon_packs = require("common/icon_packs")
    local dirs = icon_packs.getPickerDirectories(plugin_root)
    local active_pack_dir = icon_packs.getActivePackDirectory()
    for _i, dir in ipairs(dirs) do
        addDir(
            dir,
            dir == (plugin_root and plugin_root .. "/icons") and excluded or nil,
            dir == active_pack_dir and icon_packs.isPackPickerIconAllowed or nil)
    end
    return all
end

function M.stripZenPrefix(text)
    if type(text) ~= "string" then return text end
    text = text:gsub("^ZenOS%s*[:%-]%s*", "")
    return text:gsub("^Zen UI%s*[:%-]%s*", "")
end

--- Suggest an icon from the picker directories. A preferred icon is accepted by
--- filename only when that name exists in those directories.
function M.suggestIcon(plugin_root, label, fallback, strip_zen_prefix, preferred)
    local text = type(label) == "string" and label or ""
    if strip_zen_prefix then text = M.stripZenPrefix(text) end
    local needle = text:lower():gsub("[^%w]", "")
    if #needle < 3 then return fallback or "lightning" end
    local best, best_score
    local tokens = {}
    for token in text:lower():gmatch("[%w]+") do
        if #token >= 3 then tokens[#tokens + 1] = token end
    end
    local preferred_name
    if type(preferred) == "string" then
        local filename = preferred:match("([^/\\]+)$") or preferred
        preferred_name = filename:match("^(.*)%.[Ss][Vv][Gg]$")
            or filename:match("^(.*)%.[Pp][Nn][Gg]$")
            or filename:match("^[%w._-]+$") and filename
    end
    local picker_items = M.getIconPickerList(plugin_root)
    if preferred_name then
        for _i, item in ipairs(picker_items) do
            if item.name == preferred_name then return item.name end
        end
    end
    for _i, item in ipairs(picker_items) do
        local name = item.name:lower():gsub("[^%w]", "")
        local score
        if name == needle then
            score = 3
        elseif name:find(needle, 1, true) then
            score = 2
        elseif needle:find(name, 1, true) then
            score = 1
        end
        if not score then
            local token_score
            for _j, token in ipairs(tokens) do
                if name:find(token, 1, true) and (not token_score or #token > token_score) then
                    token_score = #token
                end
            end
            score = token_score and token_score / 100 or nil
        end
        if score and (not best_score or score > best_score) then
            best, best_score = item.name, score
        end
    end
    return best or fallback or "lightning"
end

-- Close all UIManager window-stack entries above `anchor_widget`.
-- Collects first to avoid mutating the stack during iteration.
function M.closeWidgetsAbove(anchor_widget)
    local UIManager = require("ui/uimanager")
    local stack = UIManager._window_stack
    if not stack or not anchor_widget then return end
    local to_close = {}
    for i = #stack, 1, -1 do
        local entry = stack[i]
        if not entry or entry.widget == anchor_widget then break end
        table.insert(to_close, entry.widget)
    end
    for _i, w in ipairs(to_close) do UIManager:close(w) end
end

return M
