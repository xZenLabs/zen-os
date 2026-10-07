local _ = require("gettext")
local plugin_root = require("common/plugin_root") or ""

local M = {}

M.BUNDLED_DEFAULT = "fonts/hyperreadable/Hyperreadable-Regular.ttf"

local plugin_dirs = {
    ["zen_ui.koplugin"] = true,
    ["zenos.koplugin"] = true,
}
local current_plugin_dir = plugin_root:match("([^/]+)$")
if current_plugin_dir then plugin_dirs[current_plugin_dir] = true end

function M.resolve(font_face)
    if type(font_face) == "string"
            and font_face:sub(1, 6) == "fonts/"
            and plugin_root ~= "" then
        return plugin_root .. "/" .. font_face
    end
    return font_face
end

function M.toConfig(font_face)
    if type(font_face) ~= "string" or font_face == "" then return font_face end
    if font_face:sub(1, 6) == "fonts/" then return font_face end

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

function M.registerFontAliases(Font, FontList)
    if plugin_root == "" then return end
    local font_dir = require("ffi/util").realpath(FontList.fontdir)
    if not font_dir then return end
    local depth = select(2, font_dir:gsub("[^/]+", ""))
    local prefix = string.rep("../", depth)
    local bundled_prefix = plugin_root .. "/fonts/"
    for _i, path in ipairs(FontList:getFontList()) do
        if path:sub(1, #bundled_prefix) == bundled_prefix then
            -- Stable KOReader prepends fontdir even to absolute paths.
            Font.fontmap[path] = prefix .. path:sub(2)
        end
    end
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
