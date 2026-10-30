local Menu = require("ui/widget/menu")
local TitleBar = require("ui/widget/titlebar")
local Screen = require("device").screen
local LibraryFont = require("modules/filebrowser/patches/library_font")
local ReaderFont = require("common/reader_font")
local TitleStyle = require("common/ui/zen_title_style")
local _ = require("gettext")

local M = {}

local function toc_items(pbw)
    local ZenTocWidget = require("modules/reader/zen_toc_widget")
    local entries = ZenTocWidget.getEntries(pbw.ui)
    local items = {}
    for i, entry in ipairs(entries) do
        items[i] = {
            text = string.rep("  ", math.max(0, entry.depth - 1)) .. entry.title,
            mandatory = entry.page_label,
            page = entry.page,
        }
    end
    -- Menu opens on the page holding item_table.current and bolds it.
    items.current = ZenTocWidget.getCurrentIndex(entries, ZenTocWidget.getCurrentPage(pbw.ui))
    if items.current then items[items.current].bold = true end
    return items
end

function M.build(pbw, kind, width, height, on_navigate)
    if kind == "book_switcher" then
        local panel = require("modules/menu/app_launcher/book_switcher_page").buildReader{
            ui = pbw.ui, plugin = pbw._zen_plugin, width = width, height = height, fill = true,
            close = function() pbw:onClose() end,
            refresh = function() pbw:updateLayout(); require("ui/uimanager"):setDirty(pbw, "ui") end,
        }
        return require("ui/widget/container/centercontainer"):new{
            dimen = require("ui/geometry"):new{ w = width, h = height },
            layout = panel.layout, panel,
        }
    end
    if kind == "book_details" then
        local spec = require("modules/reader/book_details").buildSpec(pbw.ui, {
            config = pbw._zen_plugin.config, plugin = pbw._zen_plugin,
        })
        spec.width, spec.height, spec.show_title, spec.show_parent = width, height, false, pbw
        local panel = require("modules/reader/book_info_widget"):new(spec)
        panel.layout = { { panel } }
        panel.onClose = function() return pbw:onClose() end
        panel.onCloseWidget = panel.free
        return panel
    end
    if kind ~= "toc" then
        return require("modules/reader/annotation_viewer").build(pbw, kind, width, height)
    end
    local items = toc_items(pbw)
    local plugin = pbw._zen_plugin
    local config = plugin and plugin.config and plugin.config.page_browser
    local font_size = config and tonumber(config.toc_font_size)
    if not font_size or font_size < 10 or font_size > 40 then
        font_size = ReaderFont.getInfo(pbw.ui, 18).size
    end
    local title_bar = TitleBar:new{
        width = width,
        title = _("Table of contents"),
        align = "left",
        title_face = TitleStyle.getTitleFace(),
    }
    local menu = LibraryFont.withMenuFaces(function()
        return Menu:new{
            name = "page_browser_toc",
            width = width,
            height = height,
            custom_title_bar = title_bar,
            item_table = items,
            is_borderless = true,
            is_popout = false,
            is_enable_shortcut = false,
            show_parent = pbw,
            items_per_page = math.max(1, math.floor(
                (height - title_bar:getHeight() - Screen:scaleBySize(48))
                / math.max(Screen:scaleBySize(48), font_size * 1.6)
            )),
            items_font_size = font_size,
            items_mandatory_font_size = font_size,
        }
    end)
    local update_items = menu.updateItems
    menu.updateItems = function(self, ...)
        local args = { ... }
        local result = LibraryFont.withMenuFaces(function() return update_items(self, unpack(args)) end)
        pbw:_zenRebuildFocusLayout()
        return result
    end
    menu.onClose = function() return pbw:onClose() end
    menu.onCloseAllMenus = menu.onClose
    menu.onMenuSelect = function(self, item)
        if item.select_enabled ~= false then
            on_navigate(item.page, item)
        end
        return true
    end
    return menu
end

return M
