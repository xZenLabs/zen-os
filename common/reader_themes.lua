local UIManager = require("ui/uimanager")

local M = {}

M.BUILTIN_THEMES = {
    dark_warm_gray = {
        text = "#dcdccc",
        background = "#1f1f1f",
    },
    dark_graphite = {
        text = "#d0d0d0",
        background = "#252525",
    },
    light_sepia = {
        text = "#3f3524",
        background = "#f3ead2",
    },
    light_tan = {
        text = "#473b2d",
        background = "#e8dcc5",
    },
}

local CSS_START = "/* zen_ui_reader_themes:start */"
local CSS_END = "/* zen_ui_reader_themes:end */"
local function is_enabled(plugin)
    local features = plugin and plugin.config and plugin.config.features
    return type(features) == "table" and features.reader_themes == true
end

local function is_dark_mode()
    if not (G_reader_settings and type(G_reader_settings.isTrue) == "function") then
        return false
    end
    return G_reader_settings:isTrue("night_mode") == true
end

local function normalize_color(value)
    if type(value) ~= "string" then return nil end
    value = value:lower()
    if value:match("^#%x%x%x$") then
        local r, g, b = value:sub(2, 2), value:sub(3, 3), value:sub(4, 4)
        return "#" .. r .. r .. g .. g .. b .. b
    end
    return value:match("^#%x%x%x%x%x%x$") and value or nil
end

local function color_to_hsv(value)
    local color = normalize_color(value)
    if not color then return end
    local r = tonumber(color:sub(2, 3), 16) / 255
    local g = tonumber(color:sub(4, 5), 16) / 255
    local b = tonumber(color:sub(6, 7), 16) / 255
    local max = math.max(r, g, b)
    local min = math.min(r, g, b)
    local delta = max - min
    local hue = 0
    if delta > 0 then
        if max == r then
            hue = 60 * (((g - b) / delta) % 6)
        elseif max == g then
            hue = 60 * (((b - r) / delta) + 2)
        else
            hue = 60 * (((r - g) / delta) + 4)
        end
    end
    return hue, max == 0 and 0 or delta / max, max
end

local function valid_color(value)
    return normalize_color(value) ~= nil
end

local function display_color(value)
    local color = normalize_color(value)
    if not color or not is_dark_mode() then return color end
    return string.format("#%06x", 0xffffff - tonumber(color:sub(2), 16))
end

local function blitbuffer_color(value)
    local color = display_color(value)
    if not color then return nil end
    local r = tonumber(color:sub(2, 3), 16)
    local g = tonumber(color:sub(4, 5), 16)
    local b = tonumber(color:sub(6, 7), 16)
    return require("ffi/blitbuffer").ColorRGB32(r, g, b, 0xFF)
end

local function theme_for(plugin, dark_mode)
    if not is_enabled(plugin) then return nil end
    local config = plugin and plugin.config
    local themes = config and config.reader_themes
    if dark_mode == nil then dark_mode = is_dark_mode() end
    local fallback = dark_mode and "dark_warm_gray" or "default"
    local key = type(themes) == "table" and themes[dark_mode and "dark_mode" or "light_mode"]
    key = key or fallback
    if M.BUILTIN_THEMES[key] then return M.BUILTIN_THEMES[key] end
    local custom = type(themes) == "table" and themes.custom
    local theme = type(custom) == "table" and custom[key]
    if not (type(theme) == "table" and valid_color(theme.text) and valid_color(theme.background)) then
        return nil
    end
    return theme
end

local function without_zen_css(css)
    if type(css) ~= "string" then return "" end
    local start = css:find(CSS_START, 1, true)
    return start and css:sub(1, start - 1) or css
end

function M.appendCss(plugin, css)
    local base = without_zen_css(css)
    if not is_enabled(plugin) then return base end

    local theme = theme_for(plugin)
    if not theme then return base end
    local background = display_color(theme.background)
    local text = display_color(theme.text)
    return base .. "\n" .. CSS_START .. "\n"
        .. "html, body { background-color: " .. background .. " !important; }\n"
        .. "body, body * { color: " .. text .. " !important; }\n"
        .. CSS_END
end

function M.applyBackground(reader, plugin)
    local document = reader and reader.document
    if not (document and type(document.setBackgroundColor) == "function") then return false end

    local theme = theme_for(plugin)
    if theme then
        document:setBackgroundColor(tonumber(display_color(theme.background):sub(2), 16))
    elseif G_reader_settings and type(G_reader_settings.has) == "function"
        and G_reader_settings:has("cre_background_color") then
        document:setBackgroundColor(G_reader_settings:readSetting("cre_background_color"))
    else
        document:setBackgroundColor(nil)
    end
    return true
end

function M.getTextColor(plugin)
    local theme = theme_for(plugin)
    return theme and blitbuffer_color(theme.text) or nil
end

function M.getBackgroundColor(plugin)
    local theme = theme_for(plugin)
    return theme and blitbuffer_color(theme.background) or nil
end

function M.applyFont(reader, plugin)
    local document = reader and reader.document
    if not (document and type(document.setFontFace) == "function") then return false end
    local theme = theme_for(plugin)
    local face = theme and theme.font_face
    if type(face) ~= "string" or face == "default" then return false end
    document:setFontFace(face)
    return true
end

function M.applyFooterColors(footer, plugin)
    if not footer then return false end
    local Blitbuffer = require("ffi/blitbuffer")
    local text_color = M.getTextColor(plugin)
    if footer.footer_content then
        if text_color then
            footer.footer_content.background = false
        else
            footer.footer_content.background = Blitbuffer.COLOR_WHITE
        end
    end
    if footer.footer_text then
        footer.footer_text.fgcolor = text_color or Blitbuffer.COLOR_BLACK
    end
    if footer._zen_left_text then
        footer._zen_left_text.fgcolor = text_color or Blitbuffer.COLOR_BLACK
    end
    return true
end

function M.applyCurrent(plugin)
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local reader = ok and ReaderUI and ReaderUI.instance
    if not reader then return false end
    if not (reader.typeset and reader.document) then return false end
    if type(reader.document.setStyleSheet) ~= "function" then return false end

    local typeset = reader.typeset
    local styletweak = reader.styletweak
    if type(typeset.css) == "string" and styletweak
        and type(styletweak.getCssText) == "function" then
        reader.document:setStyleSheet(typeset.css, M.appendCss(plugin, styletweak:getCssText()))
    elseif type(typeset.onApplyStyleSheet) == "function" then
        reader.typeset:onApplyStyleSheet()
    end
    if type(reader.document.resetCallCache) == "function" then
        reader.document:resetCallCache()
    end
    if type(reader.document.resetBufferCache) == "function" then
        reader.document:resetBufferCache()
    end
    M.applyFont(reader, plugin)
    if type(reader.handleEvent) == "function" then
        local Event = require("ui/event")
        reader:handleEvent(Event:new("UpdatePos"))
    end
    M.applyBackground(reader, plugin)
    local footer = reader.view and reader.view.footer
    if M.applyFooterColors(footer, plugin) and type(footer.refreshFooter) == "function" then
        footer:refreshFooter(true, true)
    end
    UIManager:setDirty(reader, "full")
    return true
end

function M.isEnabled(plugin)
    return is_enabled(plugin)
end

function M.isValidColor(value)
    return valid_color(value)
end

function M.normalizeColor(value)
    return normalize_color(value)
end

function M.colorToHsv(value)
    return color_to_hsv(value)
end

function M.isActive(plugin)
    return theme_for(plugin) ~= nil
end

function M.isActiveInReader(plugin, dark_mode)
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local reader = ok and ReaderUI and ReaderUI.instance
    local active
    if dark_mode == nil then
        active = M.isActive(plugin)
    else
        active = M.isActiveForMode(plugin, dark_mode)
    end
    return reader and reader.document and active or false
end

function M.isActiveForMode(plugin, dark_mode)
    return theme_for(plugin, dark_mode) ~= nil
end

function M.isDarkMode()
    return is_dark_mode()
end

function M.getTheme(plugin)
    return theme_for(plugin)
end

return M
