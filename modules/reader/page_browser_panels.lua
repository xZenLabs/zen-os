local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local TitleBar = require("ui/widget/titlebar")
local LibraryFont = require("modules/filebrowser/patches/library_font")
local ReaderFont = require("common/reader_font")
local TitleStyle = require("common/ui/zen_title_style")
local _ = require("gettext")

local M = {}

local function toc_items(pbw)
    local ZenTocWidget = require("modules/reader/zen_toc_widget")
    local entries = ZenTocWidget.getEntries(pbw.ui)
    local page = ZenTocWidget.getCurrentPage(pbw.ui)
    local current = ZenTocWidget.getCurrentIndex(entries, page)
    local items = {}
    for i, entry in ipairs(entries) do
        items[i] = {
            text = string.rep("  ", math.max(0, entry.depth - 1)) .. entry.title,
            mandatory = entry.page_label,
            page = entry.page,
            entry = entry,
            -- Not `state`: MenuItem renders entry.state as a widget.
            toc_state = ZenTocWidget.getRowState(i, current),
        }
    end
    -- Menu opens on the page holding item_table.current.
    items.current = current
    if current then items[current].progress = ZenTocWidget.getChapterProgress(pbw.ui, entries, current, page) end
    return items
end

-- Custom-painted TOC row; replaces MenuItem so both TOC views share one look.
local TocRow = InputContainer:extend{}

function TocRow:init()
    self.ges_events = { TapSelect = { GestureRange:new{ ges = "tap", range = self.dimen } } }
end

function TocRow:onTapSelect() return self.menu:onMenuSelect(self.item) end
function TocRow:onFocus() self.focused = true; return true end
function TocRow:onUnfocus() self.focused = nil; return true end

function TocRow:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    require("modules/reader/zen_toc_widget").paintRow(bb, x, y, self.dimen.w, self.dimen.h, self.style, self.row)
    if self.focused then bb:invertRect(x, y + 1, self.dimen.w, self.dimen.h - 1) end
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
        align = "center",
        title_face = TitleStyle.getTitleFace(),
    }
    local style = require("modules/reader/zen_toc_widget").getRowStyle(font_size)
    local TocMenu = Menu:extend{}
    -- items_max_lines routes paging through here; the current chapter card is taller.
    function TocMenu:setupItemHeights()
        for _i, item in ipairs(self.item_table) do
            item.height = item.toc_state == "current" and style.current_h or style.row_h
        end
        self.page_items = require("modules/reader/zen_toc_widget").paginate(#self.item_table,
            self.available_height, function(i) return self.item_table[i].height end)
    end
    function TocMenu:updateItems(...)
        Menu.updateItems(self, ...)
        for index, old in ipairs(self.item_group) do
            local item = self.item_table[old.idx]
            local prev = self.item_table[old.idx - 1]
            local row = TocRow:new{
                dimen = old.dimen:copy(), menu = self, item = item, style = style, idx = old.idx,
                row = {
                    entry = item.entry, state = item.toc_state, progress = item.progress,
                    separator = index > 1 and item.toc_state ~= "current" and prev.toc_state ~= "current",
                },
            }
            self.item_group[index] = row
            for _i, widgets in ipairs(self.layout) do
                for i, widget in ipairs(widgets) do if widget == old then widgets[i] = row end end
            end
            old:free()
        end
        self.item_group:resetLayout()
    end
    local menu = LibraryFont.withMenuFaces(function()
        return TocMenu:new{
            name = "page_browser_toc",
            width = width,
            height = height,
            custom_title_bar = title_bar,
            item_table = items,
            is_borderless = true,
            is_popout = false,
            is_enable_shortcut = false,
            show_parent = pbw,
            items_max_lines = 1,
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
