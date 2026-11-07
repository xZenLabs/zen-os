local M = {}
local cached_hex, cached_opacity, cached_night_mode, cached_color

local function get_config(config)
    local plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    local manager = package.loaded["config/manager"]
    return config or plugin and plugin.config or manager and manager.get and manager.get()
end

function M.isSupported()
    local Screen = require("device").screen
    -- Color panels with color rendering off render accents as gray.
    if Screen.isColorEnabled then return Screen:isColorEnabled() or false end
    return Screen.isColorScreen and Screen:isColorScreen() or false
end

local function accent_prefix(config, night_mode)
    if night_mode == nil then
        night_mode = config and config.accent_night_enabled == true and require("device").screen.night_mode
    end
    return night_mode and "accent_night_" or "accent_"
end

function M.hex(config, night_mode)
    config = get_config(config)
    local hex = config and config[accent_prefix(config, night_mode) .. "color"]
    return type(hex) == "string" and hex:match("^#%x%x%x%x%x%x$")
        and hex:upper() or "#000000"
end

function M.opacity(config, night_mode)
    config = get_config(config)
    local opacity = tonumber(config and config[accent_prefix(config, night_mode) .. "opacity"]) or 100
    return math.max(0, math.min(100, math.floor(opacity + 0.5)))
end

function M.isEnabled(config)
    if not M.isSupported() then return false end
    config = get_config(config)
    return not (config and config.accent_enabled == false)
        and (M.hex(config) ~= "#000000" or M.opacity(config) < 100)
end

function M.color(config)
    local Blitbuffer = require("ffi/blitbuffer")
    if not M.isEnabled(config) then return Blitbuffer.COLOR_BLACK end
    local hex = M.hex(config)
    local opacity = M.opacity(config)
    local night_mode = require("device").screen.night_mode
    if hex ~= cached_hex or opacity ~= cached_opacity or night_mode ~= cached_night_mode then
        cached_hex, cached_opacity, cached_night_mode = hex, opacity, night_mode
        cached_color = Blitbuffer.ColorRGB32(tonumber(hex:sub(2, 3), 16),
            tonumber(hex:sub(4, 5), 16), tonumber(hex:sub(6, 7), 16), 255)
        -- Keep the chosen hue when KOReader inverts the screen at night.
        if night_mode and hex ~= "#000000" then cached_color = cached_color:invert() end
        if opacity < 100 then
            local background = Blitbuffer.COLOR_WHITE:getColorRGB32()
            background:blend(cached_color, math.floor(opacity * 255 / 100 + 0.5))
            cached_color = background
        end
    end
    return cached_color
end

function M.foreground(config)
    local Blitbuffer = require("ffi/blitbuffer")
    if not M.isEnabled(config) then return Blitbuffer.COLOR_WHITE end
    local function linear(value)
        value = value / 255
        return value <= 0.04045 and value / 12.92 or ((value + 0.055) / 1.055) ^ 2.4
    end
    local color = M.color(config):getColorRGB32()
    local luminance = 0.2126 * linear(color.r) + 0.7152 * linear(color.g) + 0.0722 * linear(color.b)
    return luminance > 0.179 and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE
end

function M.navbarColor(config, key, default)
    local navbar = config.navbar or {}
    local c = type(navbar[key]) == "table" and navbar[key] or default
    if key == "filled_outline_color" then return c end
    if not M.isSupported() then
        -- Monochrome ignores the accent: defaults render black, manual colors still apply.
        if c[1] == default[1] and c[2] == default[2] and c[3] == default[3] then return { 0, 0, 0 } end
        return c
    end
    if navbar.active_tab_use_accent ~= false and config.accent_enabled ~= false then
        local color = M.color(config)
        if require("device").screen.night_mode and M.isEnabled(config) then color = color:invert() end
        return { color:getR(), color:getG(), color:getB() }, true
    end
    return c
end

local function invert_icon(bb, straight_alpha)
    bb = bb:copy()
    if straight_alpha then
        bb:invertRect(0, 0, bb:getWidth(), bb:getHeight())
    else
        -- MuPDF stores premultiplied RGB, so inversion must preserve alpha.
        local Blitbuffer = require("ffi/blitbuffer")
        for y = 0, bb:getHeight() - 1 do
            for x = 0, bb:getWidth() - 1 do
                local c = bb:getPixel(x, y):getColorRGB32()
                bb:setPixel(x, y, Blitbuffer.ColorRGB32(
                    c.alpha - c.r, c.alpha - c.g, c.alpha - c.b, c.alpha))
            end
        end
    end
    return bb
end

-- Two-generation LRU of inverted icon bbs; evicted bbs are left to the FFI finalizer
-- since live widgets may still reference them.
local INVERTED_MAX = 48
local inverted, inverted_old, inverted_n = {}, {}, 0

function M.styleIcon(icon, active)
    local Blitbuffer = require("ffi/blitbuffer")
    icon.alpha = true
    if not (active and M.foreground() == Blitbuffer.COLOR_WHITE) then return end
    icon:_render()
    local bb = icon._bb
    if not bb then return end
    if not icon.file then
        icon._bb, icon._bb_disposable = invert_icon(bb, icon._is_straight_alpha), true
        return
    end
    local key = table.concat({ icon.file, bb:getWidth(), bb:getHeight(), icon.rotation_angle or 0,
        icon._is_straight_alpha and 1 or 0 }, "|")
    local styled = inverted[key]
    if not styled then
        styled = inverted_old[key] or invert_icon(bb, icon._is_straight_alpha)
        if inverted_n >= INVERTED_MAX then inverted_old, inverted, inverted_n = inverted, {}, 0 end
        inverted[key], inverted_n = styled, inverted_n + 1
    end
    if icon._bb_disposable and bb.free then bb:free() end
    -- Shared cached bb: IconWidget:free must not release it.
    icon._bb, icon._bb_disposable = styled, false
end

function M.styleButton(button, icon, active)
    M.styleIcon(icon, active)
    if not active then return end
    button.background = M.color()
    local Screen = require("device").screen
    local night_mode = Screen.night_mode
    local paint = button.paintTo
    function button:paintTo(bb, x, y)
        if night_mode ~= Screen.night_mode then
            self.background = M.color()
            icon:free()
            M.styleIcon(icon, true)
            night_mode = Screen.night_mode
        end
        return paint(self, bb, x, y)
    end
end

return M
