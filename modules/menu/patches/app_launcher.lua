        local function apply_app_launcher()
    local Blitbuffer = require("ffi/blitbuffer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local Device = require("device")
    local Font = require("ui/font")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local IconWidget = require("ui/widget/iconwidget")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local TextWidget = require("ui/widget/textwidget")
    local UIManager = require("ui/uimanager")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local _ = require("gettext")

    local Dispatcher = require("dispatcher")
    local ActionFilter = require("modules/menu/app_launcher/action_filter")
    local Model = require("modules/menu/app_launcher/model")
    local NativeMenu = require("modules/menu/app_launcher/native_menu")
    local PluginScan = require("modules/menu/app_launcher/plugin_scan")
    local BookDetailsPage = require("modules/menu/app_launcher/book_details_page")
    local BookSwitcherPage = require("modules/menu/app_launcher/book_switcher_page")
    local PagePlan = require("modules/menu/app_launcher/page_plan")
    local ButtonLabelWidth = require("common/ui/button_label_width")
    local ButtonModel = require("common/nav_button_model")
    local ZenButton = require("common/ui/zen_button")
    local SettingsTransition = require("common/settings_transition")
    local utils = require("common/utils")
    local library_font = require("modules/filebrowser/patches/library_font")

    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    if not zen_plugin or type(zen_plugin.config) ~= "table" then
        return
    end
    require("modules/menu/patches/touch_menu_panel").install(zen_plugin)

    local Screen = Device.screen
    local _icons_dir
    do
        local root = require("common/plugin_root")
        if root then _icons_dir = root .. "/icons/" end
    end

    local function is_enabled()
        local features = zen_plugin.config and zen_plugin.config.features
        return type(features) == "table" and features.app_launcher == true
    end

    local DEFAULT_ENTRY_ICON = "lightning"
    local DEFAULT_FOLDER_ICON = "folder_open"

    local function icon_spec(name)
        local icon_name = (type(name) == "string" and name ~= "") and name or "app_launcher"
        local icon_path = _icons_dir and utils.resolveIcon(_icons_dir, icon_name)
        return icon_path, icon_name
    end

    local LauncherCell = InputContainer:extend{}
    local EmptyActionButton = InputContainer:extend{}

    function LauncherCell:init()
        self.dimen = self.dimen or Geom:new{ w = self.width, h = self.height }
        self.ges_events = {
            TapSelect = {
                GestureRange:new{ ges = "tap", range = self.dimen },
            },
        }
    end

    function LauncherCell:paintTo(bb, x, y)
        self.dimen.x = x
        self.dimen.y = y
        self[1]:paintTo(bb, x, y)
    end

    function LauncherCell:onTapSelect()
        if self.callback then
            self.callback()
        end
        return true
    end

    function LauncherCell:onFocus()
        self.frame.invert = true
        if self.dimen then UIManager:setDirty(nil, "fast", self.dimen) end
        return true
    end

    function LauncherCell:onUnfocus()
        self.frame.invert = false
        if self.dimen then UIManager:setDirty(nil, "fast", self.dimen) end
        return true
    end

    function EmptyActionButton:init()
        self.dimen = self.dimen or Geom:new{ w = self.width, h = self.height }
        self.ges_events = {
            TapSelect = {
                GestureRange:new{ ges = "tap", range = self.dimen },
            },
        }
    end

    function EmptyActionButton:paintTo(bb, x, y)
        self.dimen.x = x
        self.dimen.y = y
        ZenButton.paintFilled(bb, x, y, self.width, self.height, self.text, self.font_size, self.radius)
        if self.invert then
            bb:invertRect(x, y, self.width, self.height)
        end
    end

    function EmptyActionButton:onTapSelect()
        if self.callback then
            self.callback()
        end
        return true
    end

    function EmptyActionButton:onFocus()
        self.invert = true
        if self.dimen then UIManager:setDirty(nil, "fast", self.dimen) end
        return true
    end

    function EmptyActionButton:onUnfocus()
        self.invert = false
        if self.dimen then UIManager:setDirty(nil, "fast", self.dimen) end
        return true
    end

    local function make_cell(opts)
        local icon_path, icon_name = icon_spec(opts.icon)
        local icon_size = opts.icon_size
        local rendered_icon_size = math.floor(
            icon_size * utils.iconOpticalScale(opts.icon) + 0.5)
        local circle_size = opts.circle_size
        local circle_border = opts.circle_border
        local active = opts.active == true
        local label_face = opts.label_face
        local fg = opts.dim and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK
        local show_label = opts.show_label ~= false
        local icon = IconWidget:new{
            file = icon_path or nil,
            icon = icon_path and nil or icon_name,
            width = rendered_icon_size,
            height = rendered_icon_size,
            alpha = not active,
        }
        if active then
            icon:_render()
            if icon._bb then
                local bb_copy = icon._bb:copy()
                bb_copy:invertRect(0, 0, bb_copy:getWidth(), bb_copy:getHeight())
                icon._bb = bb_copy
            end
        end
        local border = active and 0 or circle_border
        local icon_circle = FrameContainer:new{
            width = circle_size,
            height = circle_size,
            padding = 0,
            bordersize = border,
            radius = math.floor(circle_size / 2),
            background = active and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{
                    w = circle_size - border * 2,
                    h = circle_size - border * 2,
                },
                icon,
            },
        }
        local content_items = {
            align = "center",
            icon_circle,
        }
        if show_label then
            local label_max_width = ButtonLabelWidth.maxWidth(opts.cell_w, opts.label_side_padding)
            local label = TextWidget:new{
                text = opts.label,
                face = label_face,
                fgcolor = fg,
                max_width = label_max_width,
            }
            table.insert(content_items, 1, VerticalSpan:new{ width = opts.pad })
            content_items[#content_items + 1] = VerticalSpan:new{ width = Screen:scaleBySize(4) }
            content_items[#content_items + 1] = label
        end
        local content = VerticalGroup:new(content_items)
        local frame = FrameContainer:new{
            width = opts.cell_w,
            height = opts.cell_h,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            padding = 0,
            CenterContainer:new{
                dimen = Geom:new{ w = opts.cell_w, h = opts.cell_h },
                content,
            },
        }
        local cell = LauncherCell:new{
            width = opts.cell_w,
            height = opts.cell_h,
            dimen = Geom:new{ w = opts.cell_w, h = opts.cell_h },
            callback = opts.callback,
            frame = frame,
            frame,
        }
        return cell
    end

    local function current_entries(touch_menu)
        local cfg = Model.ensure(zen_plugin.config)
        local folder_id = touch_menu._app_launcher_folder_id
        if folder_id then
            local folder = select(3, Model.find_by_id(cfg.entries, folder_id))
            if folder and folder.type == "folder" then
                return folder.children or {}, folder
            end
            touch_menu._app_launcher_folder_id = nil
        end
        return cfg.entries, nil
    end

    local function show_unavailable()
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{ text = _("Launcher entry is unavailable") })
    end

    local function open_app_launcher_settings(touch_menu, open_buttons)
        if touch_menu and type(touch_menu.closeMenu) == "function" then
            touch_menu:closeMenu()
        end
        UIManager:nextTick(function()
            local path = {
                { key = "_zen_settings_root", value = "launcher" },
            }
            if open_buttons then
                path[#path + 1] = { key = "_zen_launcher_buttons", value = true }
            end
            require("modules/settings/zen_settings_page").show(zen_plugin, { path = path })
        end)
    end

    local function is_library_launcher(touch_menu)
        return touch_menu
            and type(touch_menu.item_table) == "table"
            and touch_menu.item_table._zen_app_launcher_library == true
    end

    local function entry_hidden_in_context(entry, touch_menu, cfg)
        return type(entry) == "table"
            and entry.type == "action"
            and cfg.hide_reader_actions_in_library == true
            and is_library_launcher(touch_menu)
            and ActionFilter.has_reader_action(Dispatcher, entry.action)
    end

    local function activate_entry(touch_menu, entry)
        if not entry then return end
        if entry.enabled == false then return end
        local cfg = Model.ensure(zen_plugin.config)
        if entry_hidden_in_context(entry, touch_menu, cfg) then return end
        if entry._app_back then
            touch_menu._app_launcher_folder_id = nil
            touch_menu._app_launcher_page = 1
            touch_menu:updateItems(1)
            return
        end
        if entry.type == "folder" then
            touch_menu._app_launcher_folder_id = entry.id
            touch_menu._app_launcher_page = 1
            touch_menu:updateItems(1)
            return
        end
        if entry.type == "action" then
            touch_menu:closeMenu()
            SettingsTransition.close()
            UIManager:nextTick(function()
                if type(entry.action) == "table" and next(entry.action) then
                    Dispatcher:execute(entry.action)
                end
            end)
            return
        end
        if entry.type == "folder_shortcut" or entry.type == "tag" then
            touch_menu:closeMenu()
            SettingsTransition.close()
            UIManager:nextTick(function()
                ButtonModel.execute(entry, zen_plugin)
            end)
            return
        end
        if entry.type == "quick_setting" then
            local controls = rawget(_G, "__ZEN_UI_QUICK_SETTINGS")
            if not (controls and controls.activate and controls.activate(entry.quick_setting_id, touch_menu)) then
                show_unavailable()
            end
            return
        end
        if entry.type == "plugin" and type(entry.plugin) == "table" then
            local launch = PluginScan.resolve(entry.plugin.key, entry.plugin.method)
            if not launch then
                show_unavailable()
                return
            end
            touch_menu:closeMenu()
            SettingsTransition.close()
            UIManager:nextTick(function()
                pcall(launch)
            end)
            return
        end
        if entry.type == "koreader_menu" and type(entry.koreader_menu) == "table" then
            local launch = NativeMenu.resolve(entry.koreader_menu.id, "active")
            if not launch then
                show_unavailable()
                return
            end
            touch_menu:closeMenu()
            SettingsTransition.close()
            UIManager:nextTick(function()
                pcall(launch)
            end)
        end
    end

    local function open_book_from_switcher(touch_menu, path, release_cover)
        if type(release_cover) == "function" then release_cover() end
        touch_menu:closeMenu()
        SettingsTransition.close()
        UIManager:nextTick(function()
            local ReaderUI = require("apps/reader/readerui")
            local FileManager = require("apps/filemanager/filemanager")
            local filemanagerutil = require("apps/filemanager/filemanagerutil")
            local ui = ReaderUI.instance or FileManager.instance
            if ui and type(filemanagerutil.openFile) == "function" then
                filemanagerutil.openFile(ui, path)
            else
                ReaderUI:showReader(path)
            end
        end)
    end

    local function current_reader(touch_menu)
        if is_library_launcher(touch_menu) then return nil end
        local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
        return ok_reader and ReaderUI.instance or nil
    end

    local function current_reader_path(touch_menu)
        local reader = current_reader(touch_menu)
        return reader and reader.document and reader.document.file or nil
    end

    local function open_current_book_details(touch_menu, reader)
        if not reader then return end
        touch_menu:closeMenu()
        SettingsTransition.close()
        UIManager:nextTick(function()
            require("modules/reader/book_details").show(
                reader, { config = zen_plugin.config, plugin = zen_plugin })
        end)
    end

    local function entry_available(entry, touch_menu, cfg)
        if entry_hidden_in_context(entry, touch_menu, cfg) then return false end
        if entry.type == "action" then
            return ActionFilter.has_registered_action(Dispatcher, entry.action)
        end
        if entry.type == "quick_setting" then
            local controls = rawget(_G, "__ZEN_UI_QUICK_SETTINGS")
            return controls and controls.has and controls.has(entry.quick_setting_id)
        end
        if entry.type == "koreader_menu" then
            local menu = entry.koreader_menu
            return type(menu) == "table" and NativeMenu.exists(menu.id, "active")
        end
        if entry.type ~= "plugin" then return true end
        local plugin = entry.plugin
        return type(plugin) == "table" and PluginScan.exists(plugin.key, plugin.method)
    end

    local function entry_active(entry)
        if entry.type == "quick_setting" then
            local controls = rawget(_G, "__ZEN_UI_QUICK_SETTINGS")
            return controls and controls.isActive and controls.isActive(entry.quick_setting_id)
        end
        if entry.type == "action" then
            return require("common/dispatch_action").isActionActive(entry.action, zen_plugin)
        end
        return false
    end

    local function entry_disabled(entry)
        if entry.type ~= "quick_setting" then return false end
        local controls = rawget(_G, "__ZEN_UI_QUICK_SETTINGS")
        return controls and controls.isDisabled and controls.isDisabled(entry.quick_setting_id)
    end

    local function create_panel(touch_menu)
        local entries, folder = current_entries(touch_menu)
        local cfg = Model.ensure(zen_plugin.config)
        local show_labels = cfg.show_labels ~= false
        local panel_width = touch_menu.item_width
        local pad = Screen:scaleBySize(8)
        local inner_w = panel_width - pad * 2
        local min_cell_w = Screen:scaleBySize(96)
        local cols = math.max(2, math.floor(inner_w / min_cell_w))
        local cell_h = Screen:scaleBySize(92)
        local row_gap = Screen:scaleBySize(8)
        local circle_size = Screen:scaleBySize(64)
        local icon_size = math.floor(circle_size * 0.5)
        local circle_border = Screen:scaleBySize(2)
        local label_size = Font.sizemap and Font.sizemap["xx_smallinfofont"] or 18
        local label_face = library_font.getFace(label_size)
        local label_side_padding = Screen:scaleBySize(ButtonLabelWidth.SIDE_PADDING)
        local rows = {}
        local row_counts = {}
        local row_widths = {}
        local layout_rows = {}
        local refs = { buttons = {}, layout_rows = layout_rows }
        local visible = {}

        if folder then
            visible[#visible + 1] = {
                id = "__back",
                label = _("Back"),
                icon = "chevron.left",
                _app_back = true,
            }
        end
        for _i, entry in ipairs(Model.enabled_entries(entries)) do
            if not entry_hidden_in_context(entry, touch_menu, cfg) then
                visible[#visible + 1] = entry
            end
        end

        -- Group visible entries into rows, honoring row-break marker entries
        -- as well as the column count. A break entry doesn't render a cell
        -- itself -- it just forces the next entry to start a new row.
        local all_rows = {}
        do
            local current_row
            local force_break = false
            for _i, entry in ipairs(visible) do
                if entry.type == "break" then
                    force_break = true
                else
                    if not current_row or #current_row >= cols or force_break then
                        current_row = {}
                        all_rows[#all_rows + 1] = current_row
                    end
                    current_row[#current_row + 1] = entry
                    force_break = false
                end
            end
        end

        -- Size every cell off the longest row (across all pages) so a short,
        -- forced-break row doesn't stretch its icons wider than a full row.
        local max_row_len = 0
        for _i, row in ipairs(all_rows) do
            if #row > max_row_len then max_row_len = #row end
        end
        local uniform_cell_w = ButtonLabelWidth.equalCellWidth(inner_w, max_row_len)

        -- Pagination: slice the grid so it never overflows the space a normal
        -- menu would use (bar + items area + footer). The footer up arrow then
        -- always stays on screen, matching KOReader's stock menu height.
        local cell_total_h = cell_h + row_gap
        local screen_h = (touch_menu.screen_size and touch_menu.screen_size.h) or Screen:getHeight()
        local menu_height = touch_menu.height
            and math.min(touch_menu.height, screen_h)
            or screen_h
        local bar_h = (touch_menu.bar and touch_menu.bar:getSize().h) or 0
        local footer_h = (touch_menu.footer and touch_menu.footer:getSize().h) or 0
        local footer_margin_h = (touch_menu.footer_top_margin and touch_menu.footer_top_margin:getSize().h) or 0
        local panel_height = math.max(1, menu_height - bar_h - footer_h - footer_margin_h)
        local items_height = math.max(1, panel_height - pad * 2)
        local rows_per_page = math.max(1, math.floor(items_height / cell_total_h) - 1)
        local button_page_num = math.ceil(#all_rows / rows_per_page)
        local page_plan = folder and PagePlan.build(math.max(1, button_page_num), {}, true)
            or PagePlan.build(button_page_num, cfg, is_library_launcher(touch_menu))
        local page_num = #page_plan
        local page = touch_menu._app_launcher_page or 1
        if page > page_num then page = page_num end
        if page < 1 then page = 1 end
        touch_menu._app_launcher_page = page
        refs.page = page
        refs.page_num = page_num

        local function set_page_refs()
            refs.goto_page = function(nb)
                if page_num <= 1 then return false end
                if nb > page_num then nb = 1 elseif nb < 1 then nb = page_num end
                if nb == page then return false end
                touch_menu._app_launcher_page = nb
                touch_menu:updateItems(1)
                return true
            end
            touch_menu._zen_panel_refs = refs
        end

        local page_spec = page_plan[page] or { kind = "buttons", index = 1 }
        local is_switcher_page = page_spec.kind == "book_switcher"
        local is_book_details_page = page_spec.kind == "book_details"
        local button_page = page_spec.index or 1

        local page_rows = {}
        if page_spec.kind == "buttons" and #all_rows > 0 then
            local start_idx = (button_page - 1) * rows_per_page + 1
            local end_idx = math.min(start_idx + rows_per_page - 1, #all_rows)
            for i = start_idx, end_idx do
                page_rows[#page_rows + 1] = all_rows[i]
            end
        end

        if is_switcher_page then
            local panel, switcher_refs = BookSwitcherPage.build{
                width = panel_width,
                height = panel_height,
                config = zen_plugin.config,
                exclude_path = current_reader_path(touch_menu),
                open_book = function(path, _cover, release_cover)
                    open_book_from_switcher(touch_menu, path, release_cover)
                end,
            }
            refs.buttons = switcher_refs.buttons
            refs.layout_rows = switcher_refs.layout_rows
            set_page_refs()
            return panel
        end

        if is_book_details_page then
            local reader = current_reader(touch_menu)
            local panel, details_refs = BookDetailsPage.build{
                width = panel_width,
                height = panel_height,
                config = zen_plugin.config,
                launcher_config = cfg,
                ui = reader,
                open_details = function()
                    open_current_book_details(touch_menu, reader)
                end,
            }
            refs.buttons = details_refs.buttons
            refs.layout_rows = details_refs.layout_rows
            set_page_refs()
            return panel
        end

        if #visible == 0 then
            local button_w = math.min(inner_w, Screen:scaleBySize(190))
            local button_h = Screen:scaleBySize(46)
            local add_button = EmptyActionButton:new{
                width = button_w,
                height = button_h,
                dimen = Geom:new{ w = button_w, h = button_h },
                text = _("Add buttons"),
                font_size = Font.sizemap and Font.sizemap["smallinfofont"] or 22,
                radius = Screen:scaleBySize(10),
                callback = function()
                    open_app_launcher_settings(touch_menu, true)
                end,
            }
            layout_rows[#layout_rows + 1] = { add_button }
            refs.buttons[#refs.buttons + 1] = {
                widget = add_button,
                callback = function()
                    add_button.callback()
                end,
            }
            set_page_refs()
            return VerticalGroup:new{
                align = "center",
                VerticalSpan:new{ width = Screen:scaleBySize(16) },
                TextWidget:new{
                    text = _("Launcher"),
                    face = library_font.getFace(Font.sizemap and Font.sizemap["smallinfofont"] or 22),
                },
                VerticalSpan:new{ width = Screen:scaleBySize(12) },
                CenterContainer:new{
                    dimen = Geom:new{ w = panel_width, h = button_h },
                    add_button,
                },
                VerticalSpan:new{ width = Screen:scaleBySize(20) },
            }
        end

        local panel = VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = pad },
        }

        for _i, row_entries in ipairs(page_rows) do
            rows[#rows + 1] = HorizontalGroup:new{ align = "top" }
            row_counts[#rows] = 0
            row_widths[#rows] = uniform_cell_w
            layout_rows[#layout_rows + 1] = {}
            for _j, entry in ipairs(row_entries) do
                row_counts[#rows] = row_counts[#rows] + 1
                local dim = not entry._app_back
                    and (not entry_available(entry, touch_menu, cfg) or entry_disabled(entry))
                local cell = make_cell{
                    cell_w = row_widths[#rows] or uniform_cell_w,
                    cell_h = cell_h,
                    pad = pad,
                    icon_size = icon_size,
                    circle_size = circle_size,
                    circle_border = circle_border,
                    label_face = label_face,
                    label_side_padding = label_side_padding,
                    label = Model.display_label(entry),
                    show_label = show_labels,
                    icon = entry.icon or (entry.type == "folder" and DEFAULT_FOLDER_ICON or DEFAULT_ENTRY_ICON),
                    dim = dim,
                    active = not dim and entry_active(entry),
                    callback = not dim and function()
                        activate_entry(touch_menu, entry)
                    end or nil,
                }
                rows[#rows][#rows[#rows] + 1] = cell
                layout_rows[#layout_rows][#layout_rows[#layout_rows] + 1] = cell
                local quick_setting_id = entry.quick_setting_id
                local controls = entry.type == "quick_setting"
                    and quick_setting_id == "zenfm"
                    and rawget(_G, "__ZEN_UI_QUICK_SETTINGS") or nil
                refs.buttons[#refs.buttons + 1] = {
                    widget = cell,
                    callback = cell.callback and function()
                        cell.callback()
                    end or nil,
                    hold_callback = not dim and controls and type(controls.hold) == "function"
                        and function()
                            return controls.hold(quick_setting_id, touch_menu)
                        end or nil,
                }
            end
        end

        for _i, row in ipairs(rows) do
            local used = (row_counts[_i] or 0) * (row_widths[_i] or uniform_cell_w)
            local lead = math.max(pad, math.floor((panel_width - used) / 2))
            local trail = panel_width - used - lead
            table.insert(row, 1, HorizontalSpan:new{ width = lead })
            row[#row + 1] = HorizontalSpan:new{ width = math.max(0, trail) }
            panel[#panel + 1] = row
            if _i < #rows then
                panel[#panel + 1] = VerticalSpan:new{ width = row_gap }
            end
        end
        panel[#panel + 1] = VerticalSpan:new{ width = pad }
        set_page_refs()
        return panel
    end

    rawset(_G, "__ZEN_UI_BUILD_APP_LAUNCHER_PREVIEW", function(item_width)
        return create_panel{
            item_width = item_width,
            closeMenu = function() end,
            updateItems = function() end,
        }
    end)

    local function make_app_launcher_tab(library_context)
        return {
            id = "app_launcher",
            icon = "app_launcher",
            remember = true,
            panel = create_panel,
            _zen_app_launcher_library = library_context == true,
        }
    end

    local function find_tab(tab_table, id)
        for i, tab in ipairs(tab_table or {}) do
            if tab.id == id then return i end
        end
    end

    local function sync_tab(menu_self, library_context)
        if type(menu_self.tab_item_table) ~= "table" then return end
        local existing = find_tab(menu_self.tab_item_table, "app_launcher")
        if not is_enabled() then
            if existing then
                table.remove(menu_self.tab_item_table, existing)
            end
            return
        end
        if existing then
            menu_self.tab_item_table[existing]._zen_app_launcher_library = library_context == true
            return
        end
        local zen_pos = find_tab(menu_self.tab_item_table, "zen_ui")
        local qs_pos = find_tab(menu_self.tab_item_table, "quicksettings")
        table.insert(menu_self.tab_item_table,
            zen_pos and (zen_pos + 1) or qs_pos and (qs_pos + 1) or 1,
            make_app_launcher_tab(library_context))
    end

    local function patch_menu_class(menu_class, library_context)
        if not menu_class or menu_class.__zen_app_launcher_tab_patched then return end
        menu_class.__zen_app_launcher_tab_patched = true
        local orig_sut = menu_class.setUpdateItemTable
        menu_class.setUpdateItemTable = function(self)
            orig_sut(self)
            sync_tab(self, library_context)
        end
        local orig_onShowMenu = menu_class.onShowMenu
        if type(orig_onShowMenu) == "function" then
            menu_class.onShowMenu = function(self, ...)
                sync_tab(self, library_context)
                return orig_onShowMenu(self, ...)
            end
        end
    end

    local ok_fm, FileManagerMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if ok_fm then patch_menu_class(FileManagerMenu, true) end
    local ok_rm, ReaderMenu = pcall(require, "apps/reader/modules/readermenu")
    if ok_rm then patch_menu_class(ReaderMenu, false) end

    local TouchMenu = require("ui/widget/touchmenu")
    if not TouchMenu.__zen_app_launcher_open_first_patched then
        TouchMenu.__zen_app_launcher_open_first_patched = true
        local orig_init = TouchMenu.init
        TouchMenu.init = function(self, ...)
            self._app_launcher_page = 1
            if is_enabled() and Model.ensure().open_first == true then
                local index = find_tab(self.tab_item_table, "app_launcher")
                if index then self.last_index = index end
            end
            return orig_init(self, ...)
        end
    end
    if not TouchMenu.__zen_app_launcher_back_patched then
        TouchMenu.__zen_app_launcher_back_patched = true
        local function reset_folder(self, refresh)
            if not self._app_launcher_folder_id then return false end
            self._app_launcher_folder_id = nil
            self._app_launcher_page = 1
            if refresh and self.updateItems then
                self:updateItems(1)
            end
            return true
        end

        local function leave_folder(self)
            if self.item_table and self.item_table.id == "app_launcher" then
                return reset_folder(self, true)
            end
            return false
        end

        local orig_switchMenuTab = TouchMenu.switchMenuTab
        TouchMenu.switchMenuTab = function(self, tab_num, ...)
            local current_is_launcher = self.item_table and self.item_table.id == "app_launcher"
            local next_tab = type(self.tab_item_table) == "table" and self.tab_item_table[tab_num] or nil
            if current_is_launcher and (not next_tab or next_tab.id ~= "app_launcher") then
                reset_folder(self, false)
                self._app_launcher_page = 1
            end
            return orig_switchMenuTab(self, tab_num, ...)
        end

        local orig_onCloseWidget = TouchMenu.onCloseWidget
        TouchMenu.onCloseWidget = function(self, ...)
            reset_folder(self, false)
            self._app_launcher_page = 1
            if orig_onCloseWidget then
                return orig_onCloseWidget(self, ...)
            end
        end

        local orig_onClose = TouchMenu.onClose
        TouchMenu.onClose = function(self, ...)
            if self.item_table and self.item_table.id == "app_launcher" then
                reset_folder(self, false)
                self._app_launcher_page = 1
            end
            if orig_onClose then
                return orig_onClose(self, ...)
            end
            return false
        end

        local orig_onBack = TouchMenu.onBack
        TouchMenu.onBack = function(self, ...)
            if leave_folder(self) then
                return true
            end
            return orig_onBack(self, ...)
        end

        local orig_onFocusMove = TouchMenu.onFocusMove
        TouchMenu.onFocusMove = function(self, args)
            local dx = type(args) == "table" and args[1] or 0
            if dx < 0 and self.selected and self.selected.x == 1 and leave_folder(self) then
                return true
            end
            return orig_onFocusMove(self, args)
        end
    end
end

return apply_app_launcher
