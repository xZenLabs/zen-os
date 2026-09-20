local function configured_name(ReaderHighlight, color_name)
    local plugin = rawget(ReaderHighlight, "_zen_ui_highlight_names_plugin")
    local lookup = plugin and plugin.config and plugin.config.highlight_lookup
    local names = type(lookup) == "table" and lookup.color_names
    local name = type(names) == "table" and names[color_name]
    if type(name) == "string" and name:match("%S") then return name end
end

local function configured_color(ReaderHighlight, color_name)
    local plugin = rawget(ReaderHighlight, "_zen_ui_highlight_names_plugin")
    local lookup = plugin and plugin.config and plugin.config.highlight_lookup
    local colors = type(lookup) == "table" and lookup.color_codes
    local color = type(colors) == "table" and colors[color_name]
    if type(color) == "string" and color:match("^#%x%x%x%x%x%x$") then return color end
end

local function invert_color(color)
    local r, g, b = color:match("^#(%x%x)(%x%x)(%x%x)$")
    return string.format("#%02x%02x%02x",
        255 - tonumber(r, 16), 255 - tonumber(g, 16), 255 - tonumber(b, 16))
end

local function is_night_mode()
    return G_reader_settings and type(G_reader_settings.isTrue) == "function"
        and G_reader_settings:isTrue("night_mode") == true
end

local function apply(plugin)
    local ReaderHighlight = require("apps/reader/modules/readerhighlight")
    ReaderHighlight._zen_ui_highlight_names_plugin =
        plugin or rawget(_G, "__ZEN_UI_PLUGIN")

    local original_names = rawget(ReaderHighlight, "_zen_ui_highlight_original_names")
    if type(original_names) ~= "table" then
        original_names = {}
        ReaderHighlight._zen_ui_highlight_original_names = original_names
    end

    local Blitbuffer = require("ffi/blitbuffer")
    local original_colors = rawget(ReaderHighlight, "_zen_ui_highlight_original_colors")
    if type(original_colors) ~= "table" then
        original_colors = {}
        ReaderHighlight._zen_ui_highlight_original_colors = original_colors
    end

    for _i, color in ipairs(ReaderHighlight.highlight_colors or {}) do
        local color_name = color[2]
        if original_names[color_name] == nil then original_names[color_name] = color[1] end
        color[1] = configured_name(ReaderHighlight, color_name) or original_names[color_name]
        if original_colors[color_name] == nil then
            original_colors[color_name] = Blitbuffer.HIGHLIGHT_COLORS[color_name] or false
        end
        Blitbuffer.HIGHLIGHT_COLORS[color_name] = configured_color(ReaderHighlight, color_name)
            or original_colors[color_name] or nil
    end

    if ReaderHighlight._zen_ui_highlight_names_patched then return end
    ReaderHighlight._zen_ui_highlight_names_patched = true

    local orig_get_string = ReaderHighlight.getHighlightColorString
    if type(orig_get_string) == "function" then
        ReaderHighlight.getHighlightColorString = function(self, color_name, force_orig, ...)
            if force_orig and original_names[color_name] then
                return original_names[color_name]
            end
            if not force_orig then
                local name = configured_name(ReaderHighlight, color_name)
                if name then return name end
            end
            return orig_get_string(self, color_name, force_orig, ...)
        end
    end

    local orig_get_list = ReaderHighlight.getHighlightColorList
    local orig_get_code = ReaderHighlight.getHighlightColorCode
    if type(orig_get_code) == "function" then
        ReaderHighlight.getHighlightColorCode = function(self, color_name, force_orig, honor_night_mode, ...)
            local color = not force_orig and configured_color(ReaderHighlight, color_name)
            if color then
                return honor_night_mode and is_night_mode() and invert_color(color) or color
            end
            return orig_get_code(self, color_name, force_orig, honor_night_mode, ...)
        end
    end

    local orig_get_color = ReaderHighlight.getHighlightColor
    if type(orig_get_color) == "function" then
        ReaderHighlight.getHighlightColor = function(self, color_name, force_orig, honor_night_mode, ...)
            local color = not force_orig and configured_color(ReaderHighlight, color_name)
            if color then
                if honor_night_mode and is_night_mode() then color = invert_color(color) end
                return Blitbuffer.colorFromString(color)
            end
            return orig_get_color(self, color_name, force_orig, honor_night_mode, ...)
        end
    end

    if type(orig_get_list) == "function" then
        ReaderHighlight.getHighlightColorList = function(self, ...)
            local colors = orig_get_list(self, ...)
            for _i, color in ipairs(colors or {}) do
                if type(color) == "table" then
                    color[1] = configured_name(ReaderHighlight, color[2]) or color[1]
                    if configured_color(ReaderHighlight, color[2])
                        and type(self.getHighlightColor) == "function" then
                        color[3] = self:getHighlightColor(color[2], false, true)
                    end
                end
            end
            return colors
        end
    end
end

return apply
