-- Full-screen folder-cover slot picker.

local M = {}

function M.show(options)
    options = options or {}

    local Blitbuffer = require("ffi/blitbuffer")
    local BD = require("ui/bidi")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local CoverUtils = require("common/cover_utils")
    local CoverWidget = require("modules/filebrowser/patches/home/widgets/cover_common")
    local Device = require("device")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local Menu = require("ui/widget/menu")
    local OverlapGroup = require("ui/widget/overlapgroup")
    local RightContainer = require("ui/widget/container/rightcontainer")
    local Size = require("ui/size")
    local TextWidget = require("ui/widget/textwidget")
    local UIManager = require("ui/uimanager")
    local ZenButton = require("common/ui/zen_button")
    local _ = require("gettext")

    local Screen = Device.screen
    local slot_count = math.min(4, math.max(1,
        math.floor(tonumber(options.slot_count) or 1)))
    local covers = type(options.covers) == "table" and options.covers or {}
    local on_select = type(options.on_select) == "function"
        and options.on_select or function() end
    local on_clear = type(options.on_clear) == "function"
        and options.on_clear or function() end
    local ratio = math.max(0.1, tonumber(options.cover_ratio) or 2 / 3)
    local border = math.max(1, tonumber(options.border) or Size.border.default)
    local uniform = options.uniform ~= false
    local placeholder_face = Font:getFace("cfont", 28)
    local preview_max_w, preview_max_h, preview_outer_w, preview_outer_h
    local row_content_w, state_w
    local menu
    local items_per_page = 4
    local label_gap = Screen:scaleBySize(12)
    local bottom_gap = Screen:scaleBySize(16)
    local preview_shrink = Screen:scaleBySize(8)
    local clear_h = Screen:scaleBySize(46)
    local clear_font_size = Font.sizemap
        and Font.sizemap.smallinfofont or 22
    local clear_label = TextWidget:new{
        text = _("Clear"),
        face = Font:getFace("cfont", clear_font_size),
        bold = true,
    }
    local clear_w = math.max(Screen:scaleBySize(100),
        clear_label:getSize().w + 2 * Screen:scaleBySize(16))
    clear_label:free()

    local ZenClearButton = InputContainer:extend{}

    function ZenClearButton:init()
        self.dimen = Geom:new{ w = self.width, h = self.height }
        self.ges_events = {
            TapSelect = {
                GestureRange:new{ ges = "tap", range = self.dimen },
            },
        }
    end

    function ZenClearButton:paintTo(bb, x, y)
        self.dimen.x = x
        self.dimen.y = y
        local paint = self.enabled
            and ZenButton.paintFilled or ZenButton.paintOutlined
        paint(bb, x, y, self.width, self.height, self.text,
            self.font_size, self.radius)
    end

    function ZenClearButton:onTapSelect()
        if self.enabled and self.callback then
            require("common/ui/button_feedback").flashButton(self.dimen)
            self.callback()
        end
        return true
    end

    local RowState = InputContainer:extend{ kind = "row-state" }

    local function contains_point(dimen, pos)
        return dimen and pos
            and pos.x >= (dimen.x or 0)
            and pos.x < (dimen.x or 0) + (dimen.w or 0)
            and pos.y >= (dimen.y or 0)
            and pos.y < (dimen.y or 0) + (dimen.h or 0)
    end

    function RowState:init()
        self.tap_dimen = Geom:new{
            w = self.tap_width,
            h = self.reported_size.h,
        }
        self.ges_events = {
            TapSelect = {
                GestureRange:new{ ges = "tap", range = self.tap_dimen },
            },
        }
    end

    function RowState:getSize()
        return self.reported_size
    end

    function RowState:paintTo(bb, x, y)
        self.tap_dimen.x = x
        self.tap_dimen.y = y
        self[1]:paintTo(bb, x, y)
    end

    function RowState:onTapSelect()
        if self.callback then self.callback() end
        return true
    end

    local FolderCoverMenu = Menu:extend{}

    function FolderCoverMenu:_suppressPagination()
        if not self.page_info then return end
        self.page_info.dimen = Geom:new{ w = 0, h = 0 }
        self.page_info.getSize = function(page_info)
            return page_info.dimen
        end
        self.page_info.paintTo = function() end
        self.page_info.propagateEvent = function() return false end
        if self.page_info_text then
            self.page_info_text.tap_input = nil
            self.page_info_text.hold_input = nil
            self.page_info_text.call_hold_input_on_tap = false
        end
    end

    function FolderCoverMenu:_recalculateDimen(no_recalculate_dimen)
        Menu._recalculateDimen(self, no_recalculate_dimen)
        if not self.inner_dimen or not self.perpage then return end
        local top_height = self.title_bar and not self.no_title
            and self.title_bar:getHeight() or 0
        self.available_height = self.inner_dimen.h - top_height - bottom_gap
        self.item_dimen = Geom:new{
            x = 0,
            y = 0,
            w = self.inner_dimen.w,
            h = math.floor(self.available_height / self.perpage),
        }
        if self.items_max_lines then self:setupItemHeights() end
    end

    function FolderCoverMenu:updateItems(...)
        local result = Menu.updateItems(self, ...)
        if not self.item_group then return result end
        for _i, item in ipairs(self.item_group) do
            if item._underline_container then
                item._underline_container.color = Blitbuffer.COLOR_WHITE
                item.onFocus = function(row)
                    row._underline_container.color = Blitbuffer.COLOR_BLACK
                    return true
                end
                item.onUnfocus = function(row)
                    row._underline_container.color = Blitbuffer.COLOR_WHITE
                    return true
                end
            end
            item.onTapSelect = function(row)
                return self:onMenuSelect(row.entry)
            end
            item.onHoldSelect = function(row)
                return self:onMenuHold(row.entry)
            end
        end
        return result
    end

    function FolderCoverMenu:updatePageInfo(select_number)
        Menu.updatePageInfo(self, select_number)
        self:_suppressPagination()
    end

    function FolderCoverMenu:init()
        Menu.init(self)
        self.ges_events = self.ges_events or {}
        self.ges_events.FolderCoverTap = {
            GestureRange:new{ ges = "tap", range = self.dimen },
            event = "FolderCoverTap",
        }
        self.key_events.Press = nil
        self.key_events.FolderCoverSelect = {
            { "Press" },
            { "Return" },
            { "Enter" },
            event = "FolderCoverSelect",
        }
        self:_suppressPagination()
    end

    function FolderCoverMenu:onFolderCoverTap(_arg, ges)
        local pos = ges and ges.pos
        if not pos or not self.item_group then return false end
        for _i, row in ipairs(self.item_group) do
            local item = row.entry
            local clear_button = item and item.clear_button
            if clear_button and contains_point(clear_button.dimen, pos) then
                return clear_button:onTapSelect()
            end
            if item and contains_point(row.dimen, pos) then
                return self:onMenuSelect(item)
            end
        end
        return false
    end

    function FolderCoverMenu:onFolderCoverHold(_arg, ges)
        local pos = ges and ges.pos
        if not pos or not self.item_group then return false end
        for _i, row in ipairs(self.item_group) do
            local item = row.entry
            if item and contains_point(row.dimen, pos) then
                return self:onMenuHold(item)
            end
        end
        return false
    end

    function FolderCoverMenu:propagateEvent(event)
        if event and event.handler == "onGesture" and event.args then
            local ges = event.args[1]
            if ges and ges.ges == "tap"
                    and self:onFolderCoverTap(nil, ges) then
                return true
            end
            if ges and (ges.ges == "hold" or ges.ges == "hold_release")
                    and self:onFolderCoverHold(nil, ges) then
                return true
            end
        end
        return Menu.propagateEvent(self, event)
    end

    function FolderCoverMenu:onMenuSelect(item)
        if item and type(item.callback) == "function" then
            item.callback()
            return true
        end
        return Menu.onMenuSelect(self, item)
    end

    function FolderCoverMenu:onFolderCoverSelect()
        local focused = self:getFocusItem()
        local item = focused and focused.entry
        if not item then return false end
        return self:onMenuSelect(item)
    end

    local function positive_integer(value, fallback)
        value = math.floor(tonumber(value) or 0)
        return value > 0 and value or fallback
    end

    local function fit_ratio(max_w, max_h)
        if max_h * ratio <= max_w then
            return math.max(1, math.floor(max_h * ratio)), max_h
        end
        return max_w, math.max(1, math.floor(max_w / ratio))
    end

    local function update_geometry(row_height)
        local portrait = Screen:getWidth() <= Screen:getHeight()
        local cols = positive_integer(portrait and options.mosaic_cols_portrait
            or options.mosaic_cols_landscape, portrait and 3 or 4)

        local use_live_specs = options.mosaic_portrait == nil
            or options.mosaic_portrait == portrait
        local max_w = use_live_specs and tonumber(options.mosaic_cover_width) or nil
        local max_h = use_live_specs and tonumber(options.mosaic_cover_height) or nil
        if not max_w or max_w < 1 then
            local margin = Screen:scaleBySize(10)
            local tile_w = math.floor(
                (Screen:getWidth() - (cols + 1) * margin) / cols)
            max_w = tile_w - 2 * border
        end

        local row_width = menu and menu.item_dimen
            and tonumber(menu.item_dimen.w) or Screen:getWidth()
        local fullscreen_padding = tonumber(Size.padding
            and Size.padding.fullscreen) or Screen:scaleBySize(10)
        row_content_w = math.max(1, row_width - 2 * fullscreen_padding)
        local label_space = 0
        local label_face = Font:getFace("smallinfofont",
            menu and menu.font_size or clear_font_size)
        for slot = 1, slot_count do
            local label = TextWidget:new{
                text = _("Cover") .. " " .. tostring(slot),
                face = label_face,
            }
            label_space = math.max(label_space, label:getSize().w)
            label:free()
        end
        local cover_limit = row_content_w - clear_w - 2 * label_gap
            - label_space
        max_w = math.min(max_w, math.max(1, cover_limit - 2 * border))
        max_w = math.max(1, max_w - preview_shrink)

        local row_budget = math.max(1, math.floor(tonumber(row_height)
            or (Screen:getHeight() - Screen:scaleBySize(150)) / items_per_page))
        local linesize = menu and tonumber(menu.linesize)
            or tonumber(Size.line and Size.line.medium) or 0
        local height_limit = row_budget - 2 * linesize
            - Screen:scaleBySize(2) - 2 * border
        height_limit = math.max(1, height_limit)
        if not max_h or max_h < 1 then
            max_h = height_limit
        else
            max_h = math.min(max_h, height_limit)
        end
        max_h = math.max(1, max_h - preview_shrink)

        preview_max_w = math.max(1, math.floor(max_w))
        preview_max_h = math.max(1, math.floor(max_h))
        preview_outer_w = preview_max_w + 2 * border
        preview_outer_h = preview_max_h + 2 * border
        state_w = preview_outer_w + label_gap
    end

    local function make_preview(path)
        local frame
        if type(path) == "string" and path ~= "" then
            local cover = CoverUtils.loadExplicitCover(path)
            if cover then
                frame = CoverWidget.decorate_cover_frame(CoverUtils.drawSingle(
                    cover, preview_max_w, preview_max_h, border, uniform))
            end
        end
        if not frame then
            local empty_w, empty_h = fit_ratio(preview_max_w, preview_max_h)
            frame = CoverWidget.decorate_cover_frame(FrameContainer:new{
                padding = 0,
                bordersize = border,
                width = empty_w + 2 * border,
                height = empty_h + 2 * border,
                background = Blitbuffer.COLOR_LIGHT_GRAY,
                CenterContainer:new{
                    dimen = Geom:new{ w = empty_w, h = empty_h },
                    TextWidget:new{
                        text = "+",
                        face = placeholder_face,
                        bold = true,
                    },
                },
            })
        end
        return CenterContainer:new{
            dimen = Geom:new{ w = preview_outer_w, h = preview_outer_h },
            frame,
        }
    end

    local function make_state(path, clear_button, callback)
        return RowState:new{
            callback = callback,
            tap_width = row_content_w,
            reported_size = Geom:new{
                w = math.floor(row_content_w / 2),
                h = preview_outer_h,
            },
            OverlapGroup:new{
                allow_mirroring = true,
                dimen = Geom:new{ w = row_content_w, h = preview_outer_h },
                make_preview(path),
                RightContainer:new{
                    allow_mirroring = true,
                    dimen = Geom:new{
                        w = row_content_w,
                        h = preview_outer_h,
                    },
                    clear_button,
                },
            },
        }
    end

    local rebuild
    local function update_slot(slot, path)
        covers[slot] = path
        UIManager:nextTick(function()
            if not menu then return end
            rebuild(slot)
        end)
    end

    local function build_items()
        local items = {}
        for slot = 1, slot_count do
            local slot_index = slot
            local path = covers[slot_index]
            local has_cover = type(path) == "string" and path ~= ""
            local update_preview = function(selected_path)
                update_slot(slot_index, selected_path)
            end
            local select_cover = function()
                on_select(slot_index, update_preview)
            end
            local clear_button = ZenClearButton:new{
                text = _("Clear"),
                width = clear_w,
                height = clear_h,
                font_size = clear_font_size,
                radius = Screen:scaleBySize(10),
                enabled = has_cover,
                callback = function()
                    if covers[slot_index] then
                        on_clear(slot_index, update_preview)
                    end
                end,
            }
            items[slot] = {
                text = _("Cover") .. " " .. tostring(slot_index),
                state = make_state(path, clear_button, select_cover),
                preview_path = path,
                clear_button = clear_button,
                slot = slot_index,
                callback = select_cover,
                hold_callback = function()
                    if covers[slot_index] then
                        on_clear(slot_index, update_preview)
                    end
                end,
            }
        end
        return items
    end

    local function build_skeleton_items()
        local items = {}
        for slot = 1, slot_count do
            items[slot] = {
                text = _("Cover") .. " " .. tostring(slot),
                slot = slot,
            }
        end
        return items
    end

    rebuild = function(selected_slot)
        local items = build_items()
        if menu then
            menu.item_table = items
            selected_slot = selected_slot or 1
            menu.page = 1
            menu:updateItems(selected_slot, false)
        end
        return items
    end

    menu = FolderCoverMenu:new{
        name = "folder_cover_picker",
        title = options.title or _("Set folder cover"),
        subtitle = options.subtitle or (type(options.path) == "string"
            and BD.directory(filemanagerutil.abbreviate(options.path)) or nil),
        show_path = type(options.path) == "string",
        item_table = build_skeleton_items(),
        items_per_page = items_per_page,
        is_enable_shortcut = false,
        line_color = Blitbuffer.COLOR_WHITE,
        single_line = true,
        state_w = 0,
        is_borderless = true,
        is_popout = false,
        title_bar_fm_style = true,
        covers_fullscreen = true,
        _zen_no_forced_repaint = true,
    }
    update_geometry(menu.item_dimen and menu.item_dimen.h)
    menu.state_w = state_w
    menu.item_table = build_items()
    menu:updateItems(1, false)
    function menu:onMenuHold(item)
        if item and type(item.hold_callback) == "function" then
            item.hold_callback()
        end
        return true
    end
    local orig_on_screen_resize = menu.onScreenResize
    function menu:onScreenResize(dimen)
        if self.item_group and type(self.item_group.clear) == "function" then
            self.item_group:clear()
        end
        self.item_table = build_skeleton_items()
        self.items_per_page = items_per_page
        self.state_w = 0
        local result = orig_on_screen_resize(self, dimen)
        update_geometry(self.item_dimen and self.item_dimen.h)
        self.state_w = state_w
        self.item_table = build_items()
        self:updateItems(1, false)
        return result
    end
    UIManager:show(menu, "full")
    return menu
end

return M
