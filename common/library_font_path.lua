local _ = require("gettext")
local plugin_root = require("common/plugin_root") or ""

local M = {}

M.BUNDLED_DEFAULT = "fonts/hyperreadable/Hyperreadable-Regular.ttf"
M.FAMILIES = { "hyperreadable", "libron", "readerly" }
local NERD_FONT = "SymbolsNerdFont-Regular.ttf"

-- Families copied into KOReader's fonts dir; others resolve to the plugin copy.
local fontdir
local installed = {}

local plugin_dirs = {
    ["zen_ui.koplugin"] = true,
    ["zenos.koplugin"] = true,
}
local current_plugin_dir = plugin_root:match("([^/]+)$")
if current_plugin_dir then plugin_dirs[current_plugin_dir] = true end

function M.resolve(font_face)
    if type(font_face) ~= "string" or font_face:sub(1, 6) ~= "fonts/" then return font_face end
    if installed[font_face:match("^fonts/([^/]+)/")] then
        return fontdir .. font_face:sub(6)
    end
    if plugin_root ~= "" then return plugin_root .. "/" .. font_face end
    return font_face
end

function M.toConfig(font_face)
    if type(font_face) ~= "string" or font_face == "" then return font_face end
    if font_face:sub(1, 6) == "fonts/" then return font_face end
    if fontdir and font_face:sub(1, #fontdir + 1) == fontdir .. "/" then
        local relative = font_face:sub(#fontdir + 2)
        if installed[relative:match("^([^/]+)/")] then return "fonts/" .. relative end
    end

    local root_prefix = plugin_root ~= "" and plugin_root .. "/" or nil
    if root_prefix and font_face:sub(1, #root_prefix) == root_prefix then
        local relative = font_face:sub(#root_prefix + 1)
        if relative:sub(1, 6) == "fonts/" then return relative end
    end

    for plugin_dir in pairs(plugin_dirs) do
        local escaped_dir = plugin_dir:gsub("([^%w])", "%%%1")
        local relative = font_face:match("/" .. escaped_dir .. "/(fonts/.+)$")
        if relative then return relative end
    end
    return font_face
end

local function copy_file(src, dst)
    local fin = io.open(src, "rb")
    if not fin then return false end
    local tmp = dst .. ".tmp"
    local fout = io.open(tmp, "wb")
    local ok = fout ~= nil
    while ok do
        local chunk = fin:read(65536)
        if not chunk then break end
        ok = fout:write(chunk) ~= nil
    end
    fin:close()
    if fout then fout:close() end
    ok = ok and os.rename(tmp, dst)
    if not ok then os.remove(tmp) end
    return ok and true or false
end

-- true = files copied, false = already current, nil = copy failed.
local function install_family(lfs, src_dir, dst_dir)
    if lfs.attributes(dst_dir, "mode") ~= "directory" and not lfs.mkdir(dst_dir) then return nil end
    local ok_dir, iter, dir_obj = pcall(lfs.dir, src_dir)
    if not ok_dir then return nil end
    local copied = false
    for file in iter, dir_obj do
        if file:sub(1, 1) ~= "." and file:lower():match("%.ttf$") then
            local src, dst = src_dir .. "/" .. file, dst_dir .. "/" .. file
            if lfs.attributes(dst, "size") ~= lfs.attributes(src, "size") then
                if not copy_file(src, dst) then return nil end
                copied = true
            end
        end
    end
    return copied
end

-- Copies bundled families into KOReader's fonts dir so later startups load them natively.
-- Returns paths newly added to FontList (need fontnames/CRE registration).
function M.installBundled(FontList)
    local added = {}
    if plugin_root == "" or type(FontList.fontdir) ~= "string" then return added end
    local lfs = require("libs/libkoreader-lfs")
    fontdir = FontList.fontdir
    local known = {}
    for _i, path in ipairs(FontList.fontlist) do known[path] = true end
    local mark = {}
    for _i, family in ipairs(M.FAMILIES) do
        local src_dir = plugin_root .. "/fonts/" .. family
        local copied = install_family(lfs, src_dir, fontdir .. "/" .. family)
        installed[family] = copied ~= nil
        local scan_dir = copied == nil and src_dir or (copied and fontdir .. "/" .. family)
        if scan_dir then pcall(FontList._readList, FontList, scan_dir, mark) end
    end
    -- _readList appends unconditionally; drop duplicates in place.
    local list, seen, n = FontList.fontlist, {}, 0
    for i = 1, #list do
        local path = list[i]
        list[i] = nil
        if not seen[path] then
            seen[path] = true
            n = n + 1
            list[n] = path
        end
    end
    for path in pairs(mark) do
        if not known[path] and FontList.fontinfo[path] then added[path] = true end
    end
    return added
end

function M.registerFontAliases(Font, FontList)
    if plugin_root == "" then return end
    local font_dir = require("ffi/util").realpath(FontList.fontdir)
    if not font_dir then return end
    -- Stable KOReader prepends fontdir even to absolute and ./ paths.
    local prefix = string.rep("../", select(2, font_dir:gsub("[^/]+", "")))
    local bundled_prefix = plugin_root .. "/fonts/"
    local global_prefix = FontList.fontdir .. "/"
    for _i, path in ipairs(FontList:getFontList()) do
        if path:sub(1, #bundled_prefix) == bundled_prefix then
            Font.fontmap[path] = prefix .. path:sub(2)
        elseif path:sub(1, #global_prefix) == global_prefix
                and installed[path:match("^([^/]+)/", #global_prefix + 1)] then
            local relative = path:sub(#global_prefix + 1)
            Font.fontmap[path] = relative
            -- Plugin paths resolved before install (or stored) must load the copy.
            Font.fontmap[bundled_prefix .. relative] = relative
        end
    end
    Font.fontmap[NERD_FONT] = prefix .. bundled_prefix:sub(2) .. NERD_FONT
end

local function default_font()
    return require("config/defaults").library_font.font_face
end

function M.resolveConfigured(font_face)
    if font_face == "default" then font_face = default_font() end
    return M.resolve(font_face)
end

function M.nameText(cfg, FontChooser)
    if cfg.font_face == "default" then return _("default") end
    return FontChooser.getFontNameText(M.resolveConfigured(cfg.font_face)) or cfg.font_face
end

function M.findRegistered(font_face)
    local ok_font, Font = pcall(require, "ui/font")
    local mapped_face = ok_font and Font.fontmap and Font.fontmap[font_face] or font_face
    local ok_list, FontList = pcall(require, "fontlist")
    if not ok_list or type(FontList.fontinfo) ~= "table" then return nil end
    if FontList.fontinfo[mapped_face] then return mapped_face end
    if type(font_face) ~= "string" or font_face:find("/", 1, true)
            or font_face:find("\\", 1, true) then
        return nil
    end

    local filename = type(mapped_face) == "string" and mapped_face:match("([^/]+)$")
    local matched_file
    for file in pairs(FontList.fontinfo) do
        if filename and file:sub(-#filename - 1) == "/" .. filename
                and (not matched_file or file < matched_file) then
            matched_file = file
        end
    end
    return matched_file
end

function M.pickerDefault(FontChooser)
    local default_face = default_font()
    local default_file = M.resolveConfigured(default_face)
    if type(FontChooser.isFontRegistered) ~= "function"
            or FontChooser.isFontRegistered(default_file) then
        return default_face, default_file
    end
    local registered_default = M.findRegistered(default_file)
    if registered_default then return default_face, registered_default end
    return "default", M.findRegistered("cfont")
end

function M.ensureConfig(config)
    if type(config.library_font) ~= "table" then
        config.library_font = {}
    end
    if type(config.library_font.font_face) ~= "string" or config.library_font.font_face == "" then
        config.library_font.font_face = default_font()
    end
    local font_size = tonumber(config.library_font.font_size)
    if not font_size then
        config.library_font.font_size = 18
    else
        config.library_font.font_size = math.max(10, math.min(40, math.floor(font_size + 0.5)))
    end
    return config.library_font
end

return M
