local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local M = {}

function M.items(ui, plugin, refresh)
    local settings = plugin.config.reader_pins
    local function save()
        plugin:saveConfig()
        if refresh then refresh() end
    end
    return {
        {
            text = _("Use book font in popups"),
            enabled = ui.rolling ~= nil,
            checked_func = function() return settings.use_book_font end,
            callback = function() settings.use_book_font = not settings.use_book_font; save() end,
        },
        {
            text = _("Font size"),
            enabled = ui.rolling ~= nil,
            keep_menu_open = true,
            callback = function()
                local function show(absolute)
                    local spin
                    spin = require("ui/widget/spinwidget"):new{
                        title_text = _("Font size"),
                        value = absolute and (settings.font_size or ui.document.configurable.font_size)
                            or settings.relative_font_size,
                        value_min = absolute and 12 or -10, value_max = absolute and 72 or 10,
                        precision = absolute and "%d" or "%+d",
                        ok_text = _("Set font size"),
                        callback = function(widget)
                            settings.font_size = absolute and widget.value or nil
                            if not absolute then settings.relative_font_size = widget.value end
                            save()
                        end,
                        extra_text = absolute and _("Set a relative font size instead")
                            or _("Set an absolute font size instead"),
                        extra_callback = function() UIManager:close(spin); show(not absolute) end,
                    }
                    UIManager:show(spin)
                end
                show(settings.font_size ~= nil)
            end,
        },
        {
            text = _("Justify text in popups"),
            enabled = ui.rolling ~= nil,
            checked_func = function() return settings.justify end,
            callback = function() settings.justify = not settings.justify; save() end,
        },
        {
            text = _("Position"),
            sub_item_table = {
                {
                    text = _("Left"),
                    radio = true,
                    checked_func = function() return settings.side == "left" end,
                    callback = function() settings.side = "left"; save() end,
                },
                {
                    text = _("Right"),
                    radio = true,
                    checked_func = function() return settings.side ~= "left" end,
                    callback = function() settings.side = "right"; save() end,
                },
            },
        },
        {
            text = _("Image minimap"),
            checked_func = function() return settings.minimap end,
            callback = function() settings.minimap = not settings.minimap; save() end,
        },
    }
end

function M.content(ui, page, settings, background, foreground)
    local document = ui.document
    local first = document:getPageXPointer(page)
    local last = page < document:getPageCount() and document:getPageXPointer(page + 1)
    local html, css_files
    if last then
        html, css_files = document:getHTMLFromXPointers(first, last, 0x7001, true)
    end
    if not html then
        html, css_files = document:getHTMLFromXPointer(first, 0x7001, true)
    end
    assert(html, "No text at pinned page")
    local inline_css = ""
    html = html:gsub("<stylesheet[^>]*>(.-)</stylesheet>", function(stylesheet)
        inline_css = inline_css .. stylesheet .. "\n"
        return ""
    end)
    -- CRe keeps illustrations and their embedded resources intact in image previews.
    if html:find("<[iI][mM][gG][%s/>]") or html:find("<[sS][vV][gG][%s/>]") then return end
    -- MuPDF draws extra lines above anchors, just as in native footnote popups.
    html = html:gsub([[(<[^>]* )[iI][dD]=]], [[%1disabledID=]])
    local function color(value)
        return string.format("#%02x%02x%02x", value:getR(), value:getG(), value:getB())
    end
    -- Match CRe's book defaults before applying publisher styles.
    local css = "p { text-indent: 1.2em; margin-top: 0; margin-bottom: 0; }\n"
        .. "h1, h2, h3, h4, h5, h6 { margin-top: 0.7em; margin-bottom: 0.5em; }\n"
    if document.configurable.embedded_css ~= 0 then
        for _i, path in ipairs(css_files or {}) do
            local stylesheet = document:getDocumentFileContent(path)
            if stylesheet then css = css .. stylesheet .. "\n" end
        end
        css = css .. inline_css
    end
    local font_family, line_height = "sans-serif", 1.2
    if settings.use_book_font and ui.font then
        local cre = require("document/credocument"):engineInit()
        local seen = {}
        for i = 1, 4 do
            local path, face_index = cre.getFontFaceFilenameAndFaceIndex(ui.font.font_face, i >= 3, i % 2 == 0)
            if path and not seen[path] then
                seen[path] = true
                if i == 1 then
                    local face = require("ui/font"):getFace(path, document.configurable.font_size, face_index)
                    if face then line_height = math.floor(face.ftsize:getHeightAndAscender() + 0.5) / face.size end
                end
                css = css .. string.format(
                    " @font-face { font-family: ZenPinFont; src: url('%s'); font-weight: %s; font-style: %s; }",
                    path, i >= 3 and "bold" or "normal", i % 2 == 0 and "italic" or "normal")
            end
        end
        font_family = "ZenPinFont"
    end
    local margins = document:getPageMargins()
    css = css .. string.format(
        "@page { margin: 0 %gpx 0 %gpx; background-color: %s; }"
        .. " body { margin: 0; font-family: %s; line-height: %.3f; text-align: %s; }"
        .. " body, body * { color: %s !important; } img { max-width: 100%%; }",
        margins.right / 2, margins.left / 2, color(background), font_family,
        line_height * (document.configurable.line_spacing or 100) / 100,
        settings.justify and "justify" or "left", color(foreground))
    local size = settings.font_size and Screen:scaleBySize(settings.font_size)
        or Screen:scaleBySize(document.configurable.font_size) + settings.relative_font_size
    return html, css, math.max(8, size)
end

return M
