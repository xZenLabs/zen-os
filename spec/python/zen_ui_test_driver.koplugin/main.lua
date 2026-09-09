-- This companion plugin is copied only into the isolated test runtime.
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Event = require("ui/event")
local ffi = require("ffi")
local C = ffi.C
local rapidjson = require("rapidjson")
local UIManager = require("ui/uimanager")

local showcase_originals
local showcase_timestamp
local showcase_quote
local showcase_picker
local showcase_picker_wrapped
local metadata_showcase_editor

local function get_zen_plugin()
    local PluginLoader = require("pluginloader")
    return PluginLoader:getPluginInstance("zenos")
        or PluginLoader:getPluginInstance("zen_ui")
end

local SHOWCASE_NAVBARS = {
    default = {
        tab_order = { "home" },
        show_icons = true,
        show_labels = false,
    },
    library_home_icons = {
        tab_order = { "books", "home" },
        show_icons = true,
        show_labels = false,
    },
    regular = {
        tab_order = { "books", "authors", "series", "stats", "to_be_read", "home" },
        show_icons = true,
        show_labels = true,
    },
    zen_home_icons = {
        tab_order = { "books", "authors", "series", "stats", "to_be_read", "home" },
        show_icons = true,
        show_labels = false,
    },
    navbar_settings = {
        tab_order = {
            "books", "home", "to_be_read", "authors", "tags", "ct_showcase_folder",
        },
        show_icons = true,
        show_labels = false,
    },
    library_home_text = {
        tab_order = { "books", "home" },
        show_icons = false,
        show_labels = true,
    },
    icons_only = {
        tab_order = { "books", "authors", "series", "stats", "to_be_read", "home" },
        show_icons = true,
        show_labels = false,
    },
    text_only = {
        tab_order = { "books", "authors", "series", "stats", "to_be_read", "home" },
        show_icons = false,
        show_labels = true,
    },
    few_items = {
        tab_order = { "books", "stats", "home" },
        show_icons = true,
        show_labels = true,
    },
}

local function showcase_navbar_state()
    local zen_plugin = get_zen_plugin()
    local navbar = zen_plugin and zen_plugin.config and zen_plugin.config.navbar or {}
    return {
        tab_order = navbar.tab_order,
        show_icons = navbar.show_icons,
        show_labels = navbar.show_labels,
    }
end

local function configure_showcase_navbar(mode)
    local preset = SHOWCASE_NAVBARS[mode]
    if not preset then return false, "unknown showcase navbar: " .. tostring(mode) end
    local zen_plugin = get_zen_plugin()
    local navbar = zen_plugin and zen_plugin.config and zen_plugin.config.navbar
    if type(navbar) ~= "table" then return false, "navbar config unavailable" end
    if type(navbar.show_tabs) ~= "table" then navbar.show_tabs = {} end
    navbar.tab_order = {}
    for _i, id in ipairs(preset.tab_order) do
        navbar.tab_order[#navbar.tab_order + 1] = id
        navbar.show_tabs[id] = true
    end
    if mode == "navbar_settings" then
        navbar.custom_tabs = {{
            id = "ct_showcase_folder",
            type = "action",
            label = "Sci-Fi folder",
            label_auto = false,
            icon = "folder_open",
            action = {
                zen_ui_show_folder = G_reader_settings:readSetting("home_dir"),
            },
        }}
        navbar.show_tabs.authors = false
        navbar.show_tabs.tags = false
        navbar.show_tabs.ct_showcase_folder = false
    end
    navbar.show_icons = preset.show_icons
    navbar.show_labels = preset.show_labels
    local reinject = rawget(_G, "__ZEN_UI_REINJECT_FM_NAVBAR")
    if type(reinject) == "function" then reinject() end
    UIManager:setDirty(nil, "ui")
    return true
end

local function install_showcase_picker_tracker()
    if showcase_picker_wrapped then return true end
    local ok_picker, original_picker = pcall(require, "common/ui/zen_menu_picker")
    if not ok_picker then return false end
    showcase_picker_wrapped = true
    package.loaded["common/ui/zen_menu_picker"] = function(opts)
        local labels = {}
        local secondary_labels = {}
        for _i, item in ipairs(type(opts) == "table" and opts.items or {}) do
            labels[#labels + 1] = item.text
            secondary_labels[#secondary_labels + 1] = item.secondary_text or ""
        end
        showcase_picker = {
            title = type(opts) == "table" and opts.title or nil,
            labels = labels,
            secondary_labels = secondary_labels,
        }
        return original_picker(opts)
    end
    return true
end

local function configure_showcase(params)
    params = type(params) == "table" and params or {}
    if not showcase_originals then
        showcase_originals = {
            os_time = os.time,
            os_date = os.date,
        }
        rawset(os, "time", function(value)
            if value ~= nil then return showcase_originals.os_time(value) end
            return showcase_timestamp or showcase_originals.os_time()
        end)
        rawset(os, "date", function(format, value)
            if value == nil then value = showcase_timestamp end
            return showcase_originals.os_date(format, value)
        end)
    end
    showcase_timestamp = tonumber(params.timestamp)
        or tonumber(os.getenv("ZEN_UI_SHOWCASE_TIMESTAMP")) or showcase_timestamp
    install_showcase_picker_tracker()

    if params.quote ~= nil then
        if type(params.quote) ~= "string" or params.quote == "" then
            return false, "showcase quote must be a non-empty string"
        end
        showcase_quote = nil
        for _i, quote in ipairs(require("modules/filebrowser/patches/home/quote_list")) do
            if quote.text == params.quote then
                showcase_quote = quote
                break
            end
        end
        if not showcase_quote then
            return false, "showcase quote was not found in the default quote list"
        end
        local HomeQuotes = require("modules/filebrowser/patches/home/home_quotes")
        if not HomeQuotes._zen_showcase_select_quote then
            HomeQuotes._zen_showcase_select_quote = HomeQuotes.selectQuote
            HomeQuotes.selectQuote = function(config, rotation)
                if showcase_quote then return showcase_quote end
                return HomeQuotes._zen_showcase_select_quote(config, rotation)
            end
        end
    end

    local ok_device, Device = pcall(require, "device")
    if ok_device and Device then
        Device.hasKeyboard = function() return false end
        Device.hasDPad = function() return false end
    end
    local ok_filemanager, FileManager = pcall(require, "apps/filemanager/filemanager")
    local file_chooser = ok_filemanager and FileManager.instance and FileManager.instance.file_chooser
    if file_chooser then file_chooser.is_enable_shortcut = false end
    local powerd = ok_device and Device.getPowerDevice and Device:getPowerDevice()
    local battery = tonumber(params.battery)
        or tonumber(os.getenv("ZEN_UI_SHOWCASE_BATTERY")) or 82
    if powerd then
        powerd.getCapacity = function() return battery end
        powerd.getCapacityHW = function() return battery end
        powerd.isCharging = function() return false end
        powerd.isCharged = function() return false end
    end
    local ok_network, NetworkMgr = pcall(require, "ui/network/manager")
    if ok_network and NetworkMgr then
        NetworkMgr.isWifiOn = function() return params.wifi ~= false end
        NetworkMgr.isConnected = function() return params.wifi ~= false end
    end
    return true
end

local function show_lockdown_control()
    local PluginLoader = require("pluginloader")
    local plugin = PluginLoader:getPluginInstance("zenos")
        or PluginLoader:getPluginInstance("zen_ui")
    local quick_settings = plugin and plugin.config and plugin.config.quick_settings
    if type(quick_settings) ~= "table" then return false, "quick settings unavailable" end
    if type(quick_settings.show_buttons) ~= "table" then quick_settings.show_buttons = {} end
    quick_settings.show_buttons.lockdown = true
    if type(quick_settings.button_order) ~= "table" then quick_settings.button_order = {} end
    for _i, id in ipairs(quick_settings.button_order) do
        if id == "lockdown" then return true end
    end
    local order = {}
    for _i, id in ipairs(quick_settings.button_order) do
        order[#order + 1] = id
        if id == "zen" then order[#order + 1] = "lockdown" end
    end
    quick_settings.button_order = order
    return true
end

if os.getenv("ZEN_UI_SHOWCASE_TIMESTAMP") then configure_showcase({ wifi = true }) end

local original_set_dirty = UIManager.setDirty
UIManager.setDirty = function(self, widget, refresh_type, ...)
    if type(widget) == "table" and widget._zen_test_capture_refresh_modes
            and type(refresh_type) == "string" then
        local modes = widget._zen_test_refresh_modes or {}
        modes[#modes + 1] = refresh_type
        widget._zen_test_refresh_modes = modes
    end
    return original_set_dirty(self, widget, refresh_type, ...)
end

local function find_settings_row_style(widget, seen)
    if type(widget) ~= "table" then return nil end
    seen = seen or {}
    if seen[widget] then return nil end
    seen[widget] = true
    if type(widget._zen_settings_style) == "table" then
        return widget._zen_settings_style
    end
    for _i, child in ipairs(widget) do
        local style = find_settings_row_style(child, seen)
        if style then return style end
    end
end

local function find_descendant(widget, predicate, seen)
    if type(widget) ~= "table" then return nil end
    seen = seen or {}
    if seen[widget] then return nil end
    seen[widget] = true
    if predicate(widget) then return widget end
    for _i, child in ipairs(widget) do
        local found = find_descendant(child, predicate, seen)
        if found then return found end
    end
end

local function settings_row_alignment(rows)
    local alignment = {}
    local IconItem = require("common/ui/icon_menu_item")
    local Size = require("ui/size")
    for _i, row in ipairs(rows or {}) do
        local entry = row.entry or row.item
        if entry then
            local toggle = find_descendant(row, function(widget)
                return widget.dimen and widget._knob_r ~= nil and widget._border ~= nil
            end)
            local caret = find_descendant(row, function(widget)
                return widget.dimen and (widget.icon == "chevron.right"
                    or widget.icon == "chevron.left")
            end)
            if alignment.text_x == nil then
                local handle = row._zen_arrange_handle
                if handle and handle.dimen then
                    alignment.text_x = handle.dimen.x + handle.dimen.w
                        + Size.padding.default
                elseif row.entry then
                    alignment.text_x = Size.padding.large + Size.padding.fullscreen
                        + IconItem.SETTINGS_ICON_WIDTH + Size.padding.default
                end
            end
            if toggle and alignment.toggle_x == nil then
                alignment.toggle_x = toggle.dimen.x
                alignment.toggle_right = toggle.dimen.x + toggle.dimen.w
            end
            if caret and alignment.caret_x == nil then
                alignment.caret_x = caret.dimen.x
                alignment.caret_right = caret.dimen.x + caret.dimen.w
            end
        end
    end
    return alignment
end

local function settings_row_standard()
    local IconItem = require("common/ui/icon_menu_item")
    return {
        row_height = IconItem.getSettingsRowHeight(),
        font_size = IconItem.getSettingsFontSize(),
        icon_width = IconItem.SETTINGS_ICON_WIDTH,
        toggle_width = IconItem.SETTINGS_TOGGLE_WIDTH,
        toggle_height = IconItem.SETTINGS_TOGGLE_HEIGHT,
        caret_size = IconItem.SETTINGS_CARET_SIZE,
    }
end

local function is_arrange_widget(widget)
    return widget
        and type(widget._zen_menu_proxy) == "table"
        and type(widget._zen_arrange_close_all) == "function"
        and widget.title_bar ~= nil
end

local function active_arrange_widget()
    for index = #UIManager._window_stack, 1, -1 do
        local window = UIManager._window_stack[index]
        local widget = window and window.widget
        if is_arrange_widget(widget) then return widget end
    end
end

local function widget_height(widget)
    local size = widget and widget.getSize and widget:getSize()
    return size and size.h or 0
end

local function widget_y(widget)
    return widget and widget.dimen and widget.dimen.y or 0
end

local function filemanager_status_height()
    local FileManager = require("apps/filemanager/filemanager")
    local title_group = FileManager.instance and FileManager.instance.title_bar
        and FileManager.instance.title_bar.title_group
    return widget_height(title_group and title_group[2])
end

local function filemanager_status_y()
    local FileManager = require("apps/filemanager/filemanager")
    local title_group = FileManager.instance and FileManager.instance.title_bar
        and FileManager.instance.title_bar.title_group
    return widget_y(title_group and title_group[2])
end

local function focus_position(widget, target)
    if not (widget and target) then return nil end
    for row_i, row in ipairs(widget.layout or {}) do
        for column_i, control in ipairs(row) do
            if control == target then return column_i, row_i end
        end
    end
    return nil
end

local function is_focus_target(widget, target)
    return focus_position(widget, target) ~= nil
end

local function has_focus_feedback(control)
    if not (control and control.handleEvent) then return false end
    control:handleEvent(Event:new("Focus"))
    local focused = control.invert == true
        or control._focused == true
        or (control.inner_bordersize or 0) > 0
        or control.image and control.image.invert == true
        or control.frame and control.frame.invert == true
    control:handleEvent(Event:new("Unfocus"))
    return focused
end

local function is_keyboard_focused(widget, seen, depth)
    if type(widget) ~= "table" or depth > 32 then return false end
    seen = seen or {}
    if seen[widget] then return false end
    seen[widget] = true
    local underline = widget._underline_container
    if underline then
        local Blitbuffer = require("ffi/blitbuffer")
        if underline.focused == true or underline.color == Blitbuffer.COLOR_BLACK then
            return true
        end
    end
    for _i, child in ipairs(widget) do
        if is_keyboard_focused(child, seen, depth + 1) then return true end
    end
    return false
end

if ffi.os == "OSX" then
    ffi.cdef[[
struct zen_test_sockaddr_un {
    unsigned char sun_len;
    unsigned char sun_family;
    char sun_path[104];
};
]]
else
    ffi.cdef[[
struct zen_test_sockaddr_un { unsigned short sun_family; char sun_path[108]; };
]]
end
ffi.cdef[[
int socket(int domain, int type, int protocol);
int bind(int sockfd, const struct sockaddr *addr, unsigned int addrlen);
int listen(int sockfd, int backlog);
int accept(int sockfd, struct sockaddr *addr, unsigned int *addrlen);
int close(int fd);
long read(int fd, void *buf, unsigned long count);
long write(int fd, const void *buf, unsigned long count);
int unlink(const char *pathname);
int poll(struct pollfd *fds, unsigned long nfds, int timeout);
]]

local AF_UNIX = 1
local SOCK_STREAM = 1
local POLLIN = 1
local SOCKET_PATH_MAX = ffi.os == "OSX" and 104 or 108

local function widget_summary(widget, depth)
    if type(widget) ~= "table" or depth > 6 then return nil end
    local summary = { type = tostring(widget), children = {} }
    local size = widget.dimen
    if not size and type(widget.getSize) == "function" then
        local ok, value = pcall(widget.getSize, widget)
        if ok then size = value end
    end
    if type(size) == "table" then
        summary.x = size.x or 0
        summary.y = size.y or 0
        summary.width = size.w or size.width or 0
        summary.height = size.h or size.height or 0
    end
    if type(widget.text) == "string" then summary.text = widget.text end
    if type(widget.icon) == "string" then summary.icon = widget.icon end
    if type(widget.file) == "string" then summary.file = widget.file end
    for index, child in ipairs(widget) do
        if index > 64 then break end
        local described = widget_summary(child, depth + 1)
        if described then summary.children[#summary.children + 1] = described end
    end
    return summary
end

local function visible_ui()
    local windows = {}
    for index = #UIManager._window_stack, 1, -1 do
        local window = UIManager._window_stack[index]
        if window and window.widget then
            windows[#windows + 1] = widget_summary(window.widget, 0)
            if window.widget.covers_fullscreen then break end
        end
    end
    return { windows = windows }
end

local function collect_texts(widget, texts, seen, depth)
    if type(widget) ~= "table" or seen[widget] or depth > 64 then return end
    seen[widget] = true
    if type(widget.text) == "string" then texts[#texts + 1] = widget.text end
    local strip = widget._zen_strip_data
    if type(strip) == "table" then
        if type(strip.title) == "string" then texts[#texts + 1] = strip.title end
        if type(strip.authors) == "string" then texts[#texts + 1] = strip.authors end
    end
    for _i, child in ipairs(widget) do
        collect_texts(child, texts, seen, depth + 1)
    end
end

local count_image_widgets

local function collect_folder_widgets(widget, states, seen, depth)
    if type(widget) ~= "table" or seen[widget] or depth > 64 then return end
    seen[widget] = true
    local entry = widget.entry
    if type(entry) == "table" and not (entry.is_file or entry.file) and entry.path then
        states[#states + 1] = {
            path = entry.path,
            processed = widget._foldercover_processed == true,
            has_cover_frame = widget._cover_frame ~= nil,
        }
    end
    for _i, child in ipairs(widget) do
        collect_folder_widgets(child, states, seen, depth + 1)
    end
end

local function collect_visible_item_widgets(widget, states, seen, depth)
    if type(widget) ~= "table" or seen[widget] or depth > 64 then return end
    seen[widget] = true
    local entry = widget.entry
    local dimen = widget.dimen
    local path = type(entry) == "table" and (entry.path or entry.file)
    if type(path) == "string" and type(dimen) == "table"
            and dimen.x ~= nil and dimen.y ~= nil and dimen.w and dimen.h then
        local underline = widget._underline_container
        states[#states + 1] = {
            path = path,
            x = dimen.x,
            y = dimen.y,
            width = dimen.w,
            height = dimen.h,
            double_tap_patched = widget._zen_book_double_tap_patched == true,
            underline_visible = underline ~= nil
                and underline.color == require("ffi/blitbuffer").COLOR_BLACK,
        }
    end
    for _i, child in ipairs(widget) do
        collect_visible_item_widgets(child, states, seen, depth + 1)
    end
end

local function file_chooser_items()
    local FileManager = require("apps/filemanager/filemanager")
    local file_chooser = FileManager.instance and FileManager.instance.file_chooser
    if not file_chooser then return nil end
    local PluginLoader = require("pluginloader")
    local plugin = PluginLoader:getPluginInstance("zenos")
        or PluginLoader:getPluginInstance("zen_ui")
    local config = plugin and plugin.config or {}
    local status_bar = type(config.status_bar) == "table" and config.status_bar or {}
    local title_strip = type(config.mosaic_title_strip) == "table"
        and config.mosaic_title_strip or {}

    local items = {}
    for _i, item in ipairs(file_chooser.item_table or {}) do
        local props = type(item.doc_props) == "table" and item.doc_props or {}
        items[#items + 1] = {
            text = item.text,
            path = item.path or item.file,
            is_file = item.is_file == true,
            is_directory = item.is_directory == true
                or item.mode == "directory"
                or type(item.attr) == "table" and item.attr.mode == "directory",
            mandatory = item.mandatory,
            dim = item.dim,
            title = props.title or props.display_title,
            authors = props.authors,
            series = props.series,
            pages = props.pages,
        }
    end
    local visible_texts = {}
    collect_texts(file_chooser.item_group or file_chooser, visible_texts, {}, 0)
    local page_badges = {}
    for _row_i, row in ipairs(file_chooser.layout or {}) do
        for _column_i, widget in ipairs(row) do
            if type(widget._zen_page_label) == "string" then
                page_badges[#page_badges + 1] = widget._zen_page_label
            end
        end
    end
    local folder_widgets = {}
    collect_folder_widgets(file_chooser.item_group or file_chooser, folder_widgets, {}, 0)
    local visible_items = {}
    collect_visible_item_widgets(file_chooser.item_group or file_chooser, visible_items, {}, 0)
    local focused_item
    local focused_index = file_chooser.itemnumber or file_chooser.prev_itemnumber
    if focused_index and file_chooser.item_table then
        focused_item = file_chooser.item_table[focused_index]
    end
    local library_state = rawget(_G, "__ZEN_UI_LIBRARY_STATE")
    return {
        path = file_chooser.path,
        display_mode_type = file_chooser.display_mode_type or file_chooser.display_mode,
        page = file_chooser.page,
        page_count = file_chooser.page_num,
        items_per_page = file_chooser.perpage,
        itemnumber = file_chooser.itemnumber,
        previous_itemnumber = file_chooser.prev_itemnumber,
        focused_path = focused_item and (focused_item.path or focused_item.file),
        active_tab_label = rawget(_G, "__ZEN_UI_ACTIVE_TAB_LABEL"),
        saved_tab = type(library_state) == "table" and library_state.tab or nil,
        image_widget_count = count_image_widgets
            and count_image_widgets(file_chooser.item_group or file_chooser, {}, 0) or 0,
        item_widget_count = type(file_chooser.item_group) == "table" and #file_chooser.item_group or 0,
        items = items,
        page_badges = page_badges,
        folder_widgets = folder_widgets,
        visible_items = visible_items,
        visible_texts = visible_texts,
        status_bar = {
            center_item_count = type(status_bar.center_order) == "table"
                and #status_bar.center_order or 0,
            custom_height = filemanager_status_height(),
            hide_browser_bar = status_bar.hide_browser_bar == true,
        },
        mosaic_title_strip = {
            show_title = title_strip.show_title == true,
            show_author = title_strip.show_author == true,
        },
    }
end

local function tap_file_chooser_item(path)
    local FileManager = require("apps/filemanager/filemanager")
    local file_chooser = FileManager.instance and FileManager.instance.file_chooser
    if not file_chooser then return false, "file chooser unavailable" end
    local item = find_descendant(file_chooser.item_group or file_chooser, function(widget)
        local entry = widget.entry
        return type(entry) == "table" and (entry.path or entry.file) == path
            and type(widget.dimen) == "table" and widget.dimen.x ~= nil
            and type(widget.onTapSelect) == "function"
    end)
    if not item then return false, "visible item unavailable: " .. path end
    local dimen = item.dimen
    item:onTapSelect(nil, {
        pos = require("ui/geometry"):new{
            x = dimen.x + math.floor(dimen.w / 2),
            y = dimen.y + math.floor(dimen.h / 2),
            w = 0,
            h = 0,
        },
        time = require("ui/time").now(),
    })
    return true
end

local function file_chooser_cover_state()
    local FileManager = require("apps/filemanager/filemanager")
    local chooser = FileManager.instance and FileManager.instance.file_chooser
    if not chooser then return nil end
    local BookInfoManager = require("bookinfomanager")
    local files = 0
    local fetched = 0
    for _i, item in ipairs(chooser.item_table or {}) do
        local path = item.path or item.file
        if path and (item.is_file or item.file) then
            files = files + 1
            local info = BookInfoManager:getBookInfo(path, false)
            if info and info.cover_fetched then fetched = fetched + 1 end
        end
    end
    return { files = files, fetched = fetched }
end

local function open_book(path)
    local FileManager = require("apps/filemanager/filemanager")
    local file_chooser = FileManager.instance and FileManager.instance.file_chooser
    if not file_chooser or type(file_chooser.onFileSelect) ~= "function" then
        return false, "file chooser unavailable"
    end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and file_chooser.path ~= parent then
        file_chooser:changeToPath(parent)
    end
    local items = file_chooser.item_table or {}
    if parent and type(file_chooser.genItemTableFromPath) == "function" then
        items = file_chooser:genItemTableFromPath(parent)
    end
    for _i, item in ipairs(items) do
        if item.path == path and item.is_file == true then
            file_chooser:onFileSelect(item)
            return true
        end
    end
    local paths = {}
    for _i, item in ipairs(items) do
        if type(item.path) == "string" then paths[#paths + 1] = item.path end
    end
    return false, "book not found in file chooser: " .. table.concat(paths, ", ")
end

local function reader_state()
    local ReaderUI = require("apps/reader/readerui")
    local reader = ReaderUI.instance
    if not reader or not reader.document then return { open = false } end
    local page
    if type(reader.getCurrentPage) == "function" then
        local ok, value = pcall(reader.getCurrentPage, reader)
        if ok then page = value end
    end
    local visible_texts = {}
    collect_texts(reader, visible_texts, {}, 0)
    local library_state = rawget(_G, "__ZEN_UI_LIBRARY_STATE")
    local footer = reader.view and reader.view.footer
    local footer_settings = footer and footer.settings
    local PluginLoader = require("pluginloader")
    local plugin = PluginLoader:getPluginInstance("zenos")
        or PluginLoader:getPluginInstance("zen_ui")
    local meta = plugin and plugin.config and plugin.config._meta
    local active_preset
    local ok_store, PresetStore = pcall(require, "config/preset_store")
    if ok_store and type(PresetStore.getActivePreset) == "function" then
        active_preset = PresetStore.getActivePreset("reader")
    end
    return {
        open = true,
        file = reader.document.file,
        page = page,
        active_preset = active_preset,
        saved_tab = type(library_state) == "table" and library_state.tab or nil,
        saved_page = type(library_state) == "table" and library_state.page or nil,
        active_tab_label = rawget(_G, "__ZEN_UI_ACTIVE_TAB_LABEL"),
        footer_text = footer and footer.footer_text and footer.footer_text.text or nil,
        footer_time = footer_settings and footer_settings.time == true,
        footer_chapter_time = footer_settings
            and footer_settings.chapter_time_to_read == true,
        footer_book_title = footer_settings and footer_settings.book_title == true,
        footer_order_first = footer_settings and footer_settings.order
            and footer_settings.order[1] or nil,
        footer_order_second = footer_settings and footer_settings.order
            and footer_settings.order[2] or nil,
        reader_defaults_pending = type(meta) == "table"
            and meta.reader_defaults_apply_on_next_open == true,
        visible_texts = visible_texts,
    }
end

local function customize_reader_footer()
    local ReaderUI = require("apps/reader/readerui")
    local reader = ReaderUI.instance
    local footer = reader and reader.view and reader.view.footer
    if not (footer and type(footer.settings) == "table") then
        return false, "reader footer unavailable"
    end

    footer.settings.time = true
    footer.settings.chapter_time_to_read = false
    footer.settings.book_title = true
    footer.settings.order = { [0] = "off", "book_title", "time" }
    return true
end

local READER_STATUS_PRESETS = {
    default = {
        index = 5,
        name = "(ZenOS) L/C/R: Chapter Time | Page | %",
    },
    pages_bar_percent = {
        index = 6,
        name = "(ZenOS) Pages | Bar | %",
    },
}

local function ensure_reader_status_fonts(preset_key)
    local preset_spec = READER_STATUS_PRESETS[preset_key or "default"]
    if not preset_spec then
        return false, "unknown reader showcase preset: " .. tostring(preset_key)
    end
    local PluginLoader = require("pluginloader")
    local plugin = PluginLoader:getPluginInstance("zenos")
        or PluginLoader:getPluginInstance("zen_ui")
    if not (plugin and type(plugin.path) == "string" and type(plugin.config) == "table") then
        return false, "ZenOS plugin unavailable"
    end
    local applied = require("common/reader_defaults").apply(G_reader_settings, plugin.config)
    if applied ~= true then return false, "reader defaults unavailable" end
    local ReaderUI = require("apps/reader/readerui")
    local reader = ReaderUI.instance
    local footer = reader and reader.view and reader.view.footer
    if not footer then return false, "reader footer unavailable" end
    local expected = require("common/plugin_root")
        .. "/fonts/hyperreadable/Hyperreadable-SemiBold.ttf"
    local preset = require("util").tableDeepCopy(
        require("modules/reader/patches/reader_footer_presets")[preset_spec.index])
    if type(preset) ~= "table"
            or preset.name ~= preset_spec.name then
        return false, "reader showcase preset unavailable"
    end
    preset.footer.text_font_face = expected
    preset.footer.text_font_bold = false
    footer:loadPreset(preset)

    local top_config = plugin.config.reader_top_status_bar
    top_config.left_order = { "book_title" }
    top_config.center_order = {}
    top_config.right_order = { "chapter" }
    if type(plugin.config.reader_footer) ~= "table" then plugin.config.reader_footer = {} end
    plugin.config.reader_footer.chapter_time_format = "full"
    require("config/preset_store").setActivePreset("reader", preset.name)

    local top = plugin.config.reader_top_status_bar and plugin.config.reader_top_status_bar.font_face
    local bottom = footer and footer.settings and footer.settings.text_font_face
    if top ~= expected or bottom ~= expected then
        return false, string.format("reader status fonts did not apply (top=%s bottom=%s expected=%s)",
            tostring(top), tostring(bottom), expected)
    end
    UIManager:setDirty(reader, "ui")
    return true
end

local function ensure_reader_chapter_time()
    local ReaderUI = require("apps/reader/readerui")
    local reader = ReaderUI.instance
    local footer = reader and reader.view and reader.view.footer
    if not (reader and footer) then return false, "reader footer unavailable" end

    local stats = reader.statistics
    if type(stats) ~= "table" then
        stats = {}
        reader.statistics = stats
    end
    if type(stats.settings) ~= "table" then stats.settings = {} end
    stats.settings.is_enabled = true
    stats.avg_time = 60

    if type(footer.updateFooterTextGenerator) == "function" then
        footer:updateFooterTextGenerator()
    end
    if type(footer.refreshFooter) == "function" then footer:refreshFooter(true, true) end

    local text = footer.footer_text and footer.footer_text.text or ""
    if not text:find("chapter", 1, true) then
        return false, string.format("chapter ETA did not render (footer=%s)", text)
    end
    return true
end

local function goto_reader_page(page)
    local ReaderUI = require("apps/reader/readerui")
    local reader = ReaderUI.instance
    page = math.max(1, math.floor(tonumber(page) or 1))
    if not reader or not reader.document then return false, "reader unavailable" end
    local ok, handled = pcall(reader.handleEvent, reader, Event:new("GotoPage", page))
    if not ok then return false, handled end
    return handled ~= false
end

local function find_upvalue(fn, wanted)
    if type(fn) ~= "function" then return nil end
    for index = 1, 128 do
        local name, value = debug.getupvalue(fn, index)
        if not name then return nil end
        if name == wanted then return value end
    end
end

count_image_widgets = function(widget, seen, depth)
    if type(widget) ~= "table" or seen[widget] or depth > 64 then return 0 end
    seen[widget] = true
    local kind = tostring(widget):lower()
    local count = (widget.image ~= nil or kind:find("imagewidget", 1, true)) and 1 or 0
    for _i, child in ipairs(widget) do
        count = count + count_image_widgets(child, seen, depth + 1)
    end
    return count
end

local function active_home_menu()
    local apply_home = require("modules/filebrowser/patches/home_page")
    local register_home_api = find_upvalue(apply_home, "register_home_api")
    local Home = find_upvalue(register_home_api, "M")
    local menu = Home and find_upvalue(Home.hasActive, "_home_menu") or nil
    return Home, menu
end

local function find_quote_content_bounds(widget, seen, depth)
    if type(widget) ~= "table" or seen[widget] or depth > 64 then return nil end
    seen[widget] = true
    if type(widget.paintTo) == "function" then
        local quote_widget = find_upvalue(widget.paintTo, "quote_widget")
        local author_widget = find_upvalue(widget.paintTo, "author_widget")
        local quote_dimen = type(quote_widget) == "table" and quote_widget.dimen or nil
        if quote_dimen and type(quote_dimen.y) == "number"
                and type(quote_dimen.h) == "number" then
            local top = quote_dimen.y
            local bottom = quote_dimen.y + quote_dimen.h
            local author_dimen = type(author_widget) == "table" and author_widget.dimen or nil
            if author_dimen and type(author_dimen.y) == "number"
                    and type(author_dimen.h) == "number" then
                top = math.min(top, author_dimen.y)
                bottom = math.max(bottom, author_dimen.y + author_dimen.h)
            end
            return {
                top = top,
                bottom = bottom,
                text = quote_widget.text,
                author = type(author_widget) == "table" and author_widget.text or nil,
            }
        end
    end
    for _i, child in ipairs(widget) do
        local bounds = find_quote_content_bounds(child, seen, depth + 1)
        if bounds then return bounds end
    end
end

local function home_state()
    local Home, menu = active_home_menu()
    local visible_texts = {}
    if menu then collect_texts(menu, visible_texts, {}, 0) end
    local widget_ids = {}
    local widget_heights = {}
    local quote_content_bounds
    local book_paths = {}
    local strip_control_top
    local strip_control_count = 0
    for _i, target in ipairs(menu and menu._zen_home_focus_targets or {}) do
        local key = type(target.key) == "string" and target.key or ""
        local widget_id = key:match("^widget:(.+)$")
        local book_path = key:match("^book:(.+)$")
        if key:match("^strip%-control:") then
            strip_control_count = strip_control_count + 1
        end
        if widget_id then
            widget_ids[#widget_ids + 1] = widget_id
            widget_heights[widget_id] = target.height
            if widget_id == "quotes" then
                quote_content_bounds = find_quote_content_bounds(target.widget, {}, 0)
                local row_dimen = target.widget and target.widget.dimen
                local row_top = row_dimen and tonumber(row_dimen.y)
                local row_h = row_dimen and tonumber(row_dimen.h)
                local row_unpainted = #widget_ids > 1 and row_top == 0
                if quote_content_bounds and (not row_top or not row_h
                        or row_unpainted
                        or quote_content_bounds.bottom < row_top
                        or quote_content_bounds.top > row_top + row_h) then
                    quote_content_bounds = nil
                end
            end
        end
        if book_path then book_paths[#book_paths + 1] = book_path end
        local dimen = target.component_id == "strip"
            and target.widget and target.widget.dimen or nil
        if dimen and type(dimen.y) == "number" and type(dimen.h) == "number" then
            if key:match("^strip%-control:") then
                strip_control_top = math.min(strip_control_top or dimen.y, dimen.y)
            end
        end
    end
    return {
        active = Home and Home.hasActive() or false,
        on_top = Home and Home.isActiveOnTop() or false,
        page = Home and Home.getActivePage() or nil,
        active_tab_label = rawget(_G, "__ZEN_UI_ACTIVE_TAB_LABEL"),
        menu_name = menu and menu.name or nil,
        widget_ids = widget_ids,
        widget_heights = widget_heights,
        quote_content_bounds = quote_content_bounds,
        book_paths = book_paths,
        page_padding = menu and menu._zen_home_page_padding or 0,
        row_gap = menu and menu._zen_home_row_gap or 0,
        body_height = menu and menu.height or 0,
        top_visual_inset = menu and menu._zen_home_top_visual_inset or 0,
        bottom_visual_inset = menu and menu._zen_home_bottom_visual_inset or nil,
        strip_control_top = strip_control_top,
        strip_control_count = strip_control_count,
        visual_gaps = menu and menu._zen_home_visual_gaps or {},
        clock_refreshers = #(menu and menu._zen_home_clock_refreshers or {}),
        visible_texts = visible_texts,
        image_widget_count = menu and count_image_widgets(menu, {}, 0) or 0,
        navbar = showcase_navbar_state(),
    }
end

local function activate_home_target(key, action)
    local menu = select(2, active_home_menu())
    for _i, target in ipairs(menu and menu._zen_home_focus_targets or {}) do
        local callback = action == "context" and target.context or target.activate
        if target.key == key and type(callback) == "function" then
            local ok, activated = pcall(callback)
            return ok and activated == true, ok and nil or tostring(activated)
        end
    end
    return false, "home target unavailable"
end

local function navbar_state()
    local FileManager = require("apps/filemanager/filemanager")
    local chooser = FileManager.instance and FileManager.instance.file_chooser
    local stack = UIManager._window_stack
    local top = stack and stack[#stack]
    local widget = top and top.widget
    local stack_names = {}
    for _i, entry in ipairs(stack or {}) do
        local name = entry.widget and entry.widget.name
        if name then stack_names[#stack_names + 1] = name end
    end
    local visible_texts = {}
    if widget then collect_texts(widget, visible_texts, {}, 0) end
    return {
        active_tab_label = rawget(_G, "__ZEN_UI_ACTIVE_TAB_LABEL"),
        path = chooser and chooser.path or nil,
        display_mode_type = chooser and (chooser.display_mode_type or chooser.display_mode) or nil,
        top_name = widget and widget.name or nil,
        top_tab_id = widget and widget._zen_tab_id or nil,
        stack_names = stack_names,
        visible_texts = visible_texts,
        navbar = showcase_navbar_state(),
    }
end

local function tap_navbar_tab(label, tab_id, y_ratio)
    local stack = UIManager._window_stack
    if not (stack and stack[#stack] and stack[#stack].widget) then
        return false, "top widget unavailable"
    end

    local navbar
    local event_target
    local function find_navbar(widget, seen, depth)
        if type(widget) ~= "table" or seen[widget] or depth > 64 then return end
        seen[widget] = true
        if type(widget.onTapNavBar) == "function" then
            navbar = widget
            return
        end
        for _i, child in ipairs(widget) do
            find_navbar(child, seen, depth + 1)
            if navbar then return end
        end
    end
    for index = #stack, 1, -1 do
        local widget = stack[index].widget
        find_navbar(widget, {}, 0)
        if navbar then
            event_target = widget
            break
        end
    end
    if not navbar then return false, "navbar tab unavailable: " .. tostring(label) end

    local dimen = navbar.dimen
    if not tab_id or not dimen then
        return false, "navbar label geometry unavailable"
    end
    local probe_y = (dimen.y or 0) + math.floor((dimen.h or 1) / 2)
    local x
    for sample = 1, 64 do
        local probe_x = (dimen.x or 0)
            + math.floor((dimen.w or 1) * (sample - 0.5) / 64)
        if navbar:getTappedTabId(require("ui/geometry"):new{
            x = probe_x, y = probe_y, w = 0, h = 0,
        }) == tab_id then
            x = probe_x
            break
        end
    end
    if not x then return false, "navbar tab geometry unavailable: " .. tostring(tab_id) end
    local pos = {
        x = x,
        y = y_ratio and math.floor(require("device").screen:getHeight() * y_ratio)
            or (dimen.y or 0) + math.floor((dimen.h or 1) / 2),
        w = 0,
        h = 0,
    }
    return event_target:handleEvent(Event:new("Gesture", {
        ges = "tap",
        pos = require("ui/geometry"):new(pos),
    })) == true
end

local function cover_cache_comparison()
    local FileManager = require("apps/filemanager/filemanager")
    local chooser = FileManager.instance and FileManager.instance.file_chooser
    if not chooser then
        return nil, "file chooser unavailable"
    end
    local cache = require("common/cover_decode_cache")
    local path
    for _i, item in ipairs(chooser.item_table or {}) do
        local candidate = item.path or item.file
        if candidate and cache:has(candidate) then
            path = candidate
            break
        end
    end
    if not path then return nil, "no visible cached cover" end
    local BookInfoManager = require("bookinfomanager")
    local now = require("common/zen_logger").now
    local function delta(after, before)
        local result = {}
        for key, value in pairs(after) do
            if type(value) == "number" then
                result[key] = value - (before[key] or 0)
            end
        end
        return result
    end

    cache:drop(path)
    local before_cold = cache:stats()
    local cold_started_at = now()
    local info = BookInfoManager:getBookInfo(path, true)
    local cold_elapsed_ms = (now() - cold_started_at) * 1000
    if info and info.cover_bb then info.cover_bb:free() end
    local after_cold = cache:stats()

    local warm_started_at = now()
    info = BookInfoManager:getBookInfo(path, true)
    local warm_elapsed_ms = (now() - warm_started_at) * 1000
    if info and info.cover_bb then info.cover_bb:free() end
    local after_warm = cache:stats()
    return {
        path = path,
        cold = {
            elapsed_ms = cold_elapsed_ms,
            delta = delta(after_cold, before_cold),
        },
        warm = {
            elapsed_ms = warm_elapsed_ms,
            delta = delta(after_warm, after_cold),
        },
        total = after_warm,
    }
end

local function find_disabled_plugin(name)
    local PluginLoader = require("pluginloader")
    local disabled = select(2, PluginLoader:loadPlugins())
    for _i, plugin in ipairs(disabled or {}) do
        if plugin.name == name then return plugin end
    end
end

local function find_plugin_manager_item(plugin)
    local function find(items)
        for _i, item in ipairs(items or {}) do
            if item.text == plugin.fullname and type(item.checked_func) == "function"
                    and item.checked_func() == false then return item end
            if type(item.sub_item_table) == "table" then
                local nested = find(item.sub_item_table)
                if nested then return nested end
            end
        end
    end
    return find(require("pluginloader"):genPluginManagerSubItem())
end

local function legacy_plugin_manager_state()
    local plugin = find_disabled_plugin("zen_ui")
    if not plugin then
        return { ok = false, error = "disabled legacy plugin was not discovered" }
    end
    return {
        ok = true,
        name = plugin.name,
        fullname = plugin.fullname,
        path = plugin.path,
    }
end

local function enable_legacy_plugin()
    local plugin = find_disabled_plugin("zen_ui")
    if not plugin then
        return { ok = false, error = "disabled legacy plugin was not discovered" }
    end
    local item = find_plugin_manager_item(plugin)
    if not item then
        return { ok = false, error = "legacy plugin manager item was not found" }
    end

    local enable_label
    local enable_path
    if type(item.hold_callback) == "function" then
        item.hold_callback({ updateItems = function() end })
        local stack = UIManager._window_stack or {}
        local dialog = stack[#stack] and stack[#stack].widget
        local enable_button = dialog and dialog.buttons and dialog.buttons[1]
            and dialog.buttons[1][1]
        local expected_label = require("gettext")("Enable plugin")
        if not enable_button or enable_button.text ~= expected_label
                or type(enable_button.callback) ~= "function" then
            return { ok = false, error = "real Enable plugin callback was not found" }
        end
        enable_label = enable_button.text
        enable_path = "dialog"
        enable_button.callback()
    elseif type(item.callback) == "function" then
        enable_path = "toggle"
        item.callback()
    else
        return { ok = false, error = "legacy plugin manager callback was not found" }
    end

    local disabled = G_reader_settings:readSetting("plugins_disabled") or {}
    UIManager:scheduleIn(0.25, function()
        local windows = UIManager._window_stack or {}
        local prompt = windows[#windows] and windows[#windows].widget
        if prompt and type(prompt.ok_callback) == "function" then
            prompt.ok_callback()
        end
    end)
    return {
        ok = true,
        name = plugin.name,
        fullname = plugin.fullname,
        enable_label = enable_label,
        enable_path = enable_path,
        legacy_disabled_present = disabled.zen_ui ~= nil,
        legacy_disabled = disabled.zen_ui == true,
    }
end

local function brand_migration_state()
    local PluginLoader = require("pluginloader")
    local plugin = PluginLoader:getPluginInstance("zenos")
    local legacy_alias = PluginLoader:getPluginInstance("zen_ui")
    if not plugin then
        return { ok = false, error = "canonical ZenOS plugin is not loaded" }
    end
    local config = plugin.config or {}
    local settings_root = require("datastorage"):getSettingsDir() .. "/ZenOS"
    local ok_reader, reader = pcall(dofile, settings_root .. "/reader.lua")
    local ok_home, home = pcall(dofile, settings_root .. "/home.lua")
    if not ok_reader or type(reader) ~= "table"
            or not ok_home or type(home) ~= "table" then
        return { ok = false, error = "migrated setting files could not be loaded" }
    end
    local disabled = G_reader_settings:readSetting("plugins_disabled") or {}
    local footer = G_reader_settings:readSetting("footer") or {}
    local buttons = config.quick_settings and config.quick_settings.custom_buttons or {}
    local builtin = reader.presets and reader.presets["(ZenOS) Chapter Time + %"] or {}
    local custom = reader.presets and reader.presets.custom or {}
    return {
        ok = true,
        plugin_alias_same = legacy_alias == plugin,
        plugin_root = plugin.path,
        settings_root = settings_root,
        marker = config._meta and config._meta.zenos_brand_migration_v1 == true,
        fixture = config.migration_fixture,
        update_channel = config.updater and config.updater.update_channel,
        library_font = config.library_font and config.library_font.font_face,
        custom_button_label = buttons[1] and buttons[1].label,
        custom_button_icon = buttons[1] and buttons[1].icon,
        reader_active_preset = reader.active_preset,
        reader_has_legacy_preset = reader.presets
            and reader.presets["(Zen UI) Chapter Time + %"] ~= nil,
        reader_has_canonical_preset = reader.presets
            and reader.presets["(ZenOS) Chapter Time + %"] ~= nil,
        reader_builtin_footer = builtin.reader_footer_custom_text,
        reader_custom_footer = custom.reader_footer_custom_text,
        reader_footer_font = reader.settings and reader.settings.footer
            and reader.settings.footer.text_font_face,
        home_fixture = home.migration_fixture,
        home_path = home.fixture_path,
        global_footer_font = footer.text_font_face,
        global_reader_footer = G_reader_settings:readSetting("reader_footer_custom_text"),
        legacy_disabled_present = disabled.zen_ui ~= nil,
        canonical_disabled_present = disabled.zenos ~= nil,
        canonical_disabled = disabled.zenos == true,
        canonical_effectively_enabled = disabled.zenos ~= true,
    }
end

local function reset_showcase_ui(session)
    showcase_picker = nil
    local settings_page = rawget(_G, "__ZEN_UI_SETTINGS_PAGE")
    if settings_page and type(settings_page.onClose) == "function" then
        pcall(settings_page.onClose, settings_page)
    end
    pcall(function() require("modules/filebrowser/patches/stats_page").closeAll() end)
    local Home = select(1, active_home_menu())
    if Home and type(Home.closeAll) == "function" then pcall(Home.closeAll) end

    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    local menu = fm and fm.menu
    local touch_menu = menu and menu.menu_container and menu.menu_container[1]
    if touch_menu and type(touch_menu.closeMenu) == "function" then
        pcall(touch_menu.closeMenu, touch_menu)
    end

    local ok_reader, ReaderUI = pcall(require, "apps/reader/readerui")
    local reader = ok_reader and ReaderUI.instance or nil
    local base = session == "reader" and reader or fm
    for _i = 1, 24 do
        local stack = UIManager._window_stack or {}
        local top = stack[#stack] and stack[#stack].widget
        if not top or top == base then break end
        UIManager:close(top)
    end

    if session ~= "reader" then
        local open_tab = rawget(_G, "__ZEN_UI_NAVBAR_OPEN_TAB")
        if type(open_tab) == "function" then pcall(open_tab, "books") end
    end
    metadata_showcase_editor = nil
    return true
end

local function showcase_home(preset_name, simple)
    local HomePresets = require("modules/filebrowser/patches/home/home_presets")
    local PresetStore = require("config/preset_store")
    local settings = HomePresets.defaultHomePage()
    local active_preset
    if simple == true then
        settings.title = "Simple"
        settings.rows.order = { "datetime", "featured", "stats_triplet", "strip" }
        settings.rows.enabled = {
            datetime = true,
            featured = true,
            stats_triplet = true,
            strip = true,
        }
        settings.modules.featured.show_description = true
        settings.modules.featured.show_status_bar = false
        settings.modules.strip.count = 4
        settings.modules.strip.two_rows = false
        settings.modules.strip.default_source = { kind = "recent" }
        settings.modules.strip.controls.enabled = true
    else
        for _i, preset in ipairs(HomePresets.getBuiltinPresets()) do
            if preset.name == preset_name then
                HomePresets.applyHomePagePreset(settings, preset)
                active_preset = preset.name
                break
            end
        end
        if not active_preset then return false, "unknown Home preset: " .. tostring(preset_name) end
    end
    settings.active_preset = active_preset
    PresetStore.saveSettings("home", settings)
    PresetStore.setActivePreset("home", active_preset)
    local Home = select(1, active_home_menu())
    if Home and type(Home.closeAll) == "function" then Home.closeAll() end
    local open_tab = rawget(_G, "__ZEN_UI_NAVBAR_OPEN_TAB")
    if type(open_tab) ~= "function" or open_tab("home") ~= true then
        return false, "Home navbar callback unavailable"
    end
    return true
end

local function set_library_display_mode(mode)
    local allowed = {
        mosaic_image = true,
        list_image_meta = true,
    }
    if not allowed[mode] then return false, "unsupported display mode" end
    local FileManager = require("apps/filemanager/filemanager")
    local fm = FileManager.instance
    if not (fm and type(fm.onSetDisplayMode) == "function") then
        return false, "file manager display mode callback unavailable"
    end
    local ok, err = pcall(fm.onSetDisplayMode, fm, mode)
    if not ok then return false, tostring(err) end
    local open_tab = rawget(_G, "__ZEN_UI_NAVBAR_OPEN_TAB")
    if type(open_tab) == "function" then pcall(open_tab, "books") end
    return true
end

local function set_showcase_library_order(paths)
    if type(paths) ~= "table" or #paths == 0 then
        return false, "showcase library order is empty"
    end
    local FileManager = require("apps/filemanager/filemanager")
    local chooser = FileManager.instance and FileManager.instance.file_chooser
    if not (chooser and type(chooser.switchItemTable) == "function") then
        return false, "file chooser item callback unavailable"
    end
    local items_by_path = {}
    for _i, item in ipairs(chooser.item_table or {}) do
        local path = item.path or item.file
        if path then items_by_path[path] = item end
    end
    local ordered = {}
    local included = {}
    for _i, path in ipairs(paths) do
        if type(path) ~= "string" or path == "" then
            return false, "invalid showcase library path"
        end
        local item = items_by_path[path]
        if not item then return false, "showcase library item unavailable: " .. path end
        ordered[#ordered + 1] = item
        included[path] = true
    end
    for _i, item in ipairs(chooser.item_table or {}) do
        local path = item.path or item.file
        if not included[path] then ordered[#ordered + 1] = item end
    end
    chooser:switchItemTable(nil, ordered, 1)
    return true
end

local function open_file_context(path)
    local FileManager = require("apps/filemanager/filemanager")
    local chooser = FileManager.instance and FileManager.instance.file_chooser
    if not (chooser and type(chooser.showFileDialog) == "function") then
        return false, "file chooser context callback unavailable"
    end
    for _i, item in ipairs(chooser.item_table or {}) do
        if (item.path or item.file) == path then
            chooser:showFileDialog(item)
            return true
        end
    end
    return false, "context book is not in the current file chooser"
end

local function set_showcase_orientation(orientation)
    if orientation ~= "portrait" and orientation ~= "landscape" then
        return false, "unsupported showcase orientation"
    end
    local Screen = require("device").screen
    local want_landscape = orientation == "landscape"
    if (Screen:getWidth() > Screen:getHeight()) ~= want_landscape then
        local current = tonumber(Screen:getRotationMode()) or Screen.DEVICE_ROTATED_UPRIGHT
        local target = current % 2 == 0
            and Screen.DEVICE_ROTATED_CLOCKWISE or Screen.DEVICE_ROTATED_UPRIGHT
        local FileManager = require("apps/filemanager/filemanager")
        local fm = FileManager.instance
        if fm and type(fm.onSetRotationMode) == "function" then
            fm:onSetRotationMode(target)
        else
            Screen:setRotationMode(target)
            UIManager:onRotation()
        end
    end
    if (Screen:getWidth() > Screen:getHeight()) ~= want_landscape then
        return false, "showcase orientation did not change"
    end
    return true
end

local function metadata_showcase_state()
    local editor = metadata_showcase_editor
    if not editor then return nil end
    local fields = {}
    for _i, item in ipairs(editor.item_table or {}) do
        fields[#fields + 1] = item.text
    end
    local Screen = require("device").screen
    return {
        dirty = editor:isDirty(),
        title = editor.draft and editor.draft.title,
        authors = editor.draft and editor.draft.authors,
        edition_summary = editor.edition_summary,
        hardcover_text = editor:_hardcoverText(),
        open_with_text = editor._open_with_button and editor._open_with_button.text,
        restore_text = editor._restore_button and editor._restore_button.text,
        hardcover_filled = editor._hardcover_button
            and editor._hardcover_button._zen_filled == true,
        has_pending_cover = editor:getPendingCover() ~= nil,
        title_action = editor.title_bar and editor.title_bar.action
            and editor.title_bar.action.text or nil,
        title_action_zen = editor.title_bar and editor.title_bar.action
            and editor.title_bar.action.zen_button == true,
        title_action_font_size = editor.title_bar and editor.title_bar.action
            and editor.title_bar.action.text_font_size or nil,
        fields = fields,
        page_count = editor.page_num,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
    }
end

local function show_metadata_editor_fixture(orientation)
    reset_showcase_ui("general")
    local ok_orientation, err = set_showcase_orientation(orientation)
    if not ok_orientation then return false, err end
    local plugin_root = require("common/plugin_root")
    local current_cover = require("ui/renderimage"):renderImageFile(
        plugin_root .. "/images/quickstart/onboarding/library_covers.png", false)
    metadata_showcase_editor = require("modules/filebrowser/metadata_editor").show{
        file = "/fixture/The Strength of the Few.epub",
        is_epub = true,
        can_restore = true,
        current_cover = current_cover,
        metadata = {
            title = "The Strength of the Few",
            authors = { "James Islington" },
            language = "en",
            isbn = "9781982141197",
        },
        on_hardcover = function() end,
        on_open_with = function() end,
        on_cover = function(editor)
            require("common/ui/zen_menu_picker"){
                title = "Cover",
                items = {
                    { text = "Discard" },
                },
                footer_buttons = {
                    { text = "Choose image" },
                    { text = "Find metadata", filled = true },
                },
                footer_buttons_under_header = true,
                hide_header_divider = true,
                header_height = editor:getCoverComparisonHeight(),
                paint_header = function(bb, x, y, width, height)
                    editor:paintCoverComparison(bb, x, y, width, height)
                end,
                on_select = function() end,
            }
        end,
        on_rename = function() end,
        on_save = function() end,
        on_restore = function() end,
    }
    metadata_showcase_editor:applyHardcover({
        title = "The Strength of the Few",
        authors = { "James Islington" },
        series_name = "Hierarchy",
        series_index = "2",
        genres = { "Fantasy", "Epic fantasy" },
        language = "en",
        publisher = "Orbit",
        description = "The hierarchy is changing, and the cost of power has never been higher.",
    }, "Paperback, 2024 · Orbit")
    metadata_showcase_editor:setPendingCover(
        plugin_root .. "/images/quickstart/onboarding/library_list_full.png", false)
    metadata_showcase_editor.page = 1
    metadata_showcase_editor.itemnumber = 1
    metadata_showcase_editor:updateItems(nil, false)
    UIManager:forceRePaint()
    return true
end

local function show_metadata_cover_fixture()
    local ok, err = show_metadata_editor_fixture("portrait")
    if not ok then return false, err end
    metadata_showcase_editor:_editCover()
    UIManager:forceRePaint()
    return true
end

local function show_metadata_picker_fixture()
    reset_showcase_ui("general")
    local ok_orientation, err = set_showcase_orientation("portrait")
    if not ok_orientation then return false, err end
    if not install_showcase_picker_tracker() then
        return false, "showcase picker unavailable"
    end
    local plugin_root = require("common/plugin_root")
    require("common/ui/zen_menu_picker"){
        title = "Choose an edition",
        rows_per_page = 5,
        items = {
            {
                text = "Search again",
                secondary_text = "The Strength of the Few · James Islington",
            },
            {
                text = "Hardcover, 2025",
                secondary_text = "Orbit · English · 720 pages",
                image_file = plugin_root
                    .. "/images/quickstart/onboarding/library_covers.png",
            },
            {
                text = "Paperback, 2026",
                secondary_text = "Orbit · English · 736 pages",
                image_file = plugin_root
                    .. "/images/quickstart/onboarding/library_list_full.png",
            },
        },
        on_select = function() end,
    }
    UIManager:forceRePaint()
    return true
end

local function open_quickstart()
    local PluginLoader = require("pluginloader")
    local plugin = PluginLoader:getPluginInstance("zenos")
        or PluginLoader:getPluginInstance("zen_ui")
    if not plugin then return false, "ZenOS plugin unavailable" end
    local ok_screen, QuickstartScreen = pcall(
        require, "common/quickstart/quickstart_screen")
    local ok_pages, QuickstartPages = pcall(
        require, "common/quickstart/quickstart_pages")
    if not ok_screen or not ok_pages then return false, "Quickstart modules unavailable" end
    UIManager:show(QuickstartScreen:new{
        pages = QuickstartPages.build_install_pages({
            plugin = plugin,
            config = plugin.config,
        }),
        on_close = function() end,
    })
    return true
end

local function dimen_bounds(dimen)
    if not (dimen and tonumber(dimen.x) and tonumber(dimen.y)
            and tonumber(dimen.w) and tonumber(dimen.h)) then return nil end
    return { x = dimen.x, y = dimen.y, w = dimen.w, h = dimen.h }
end

local function union_bounds(first, second)
    if not first then return second end
    if not second then return first end
    local x = math.min(first.x, second.x)
    local y = math.min(first.y, second.y)
    local right = math.max(first.x + first.w, second.x + second.w)
    local bottom = math.max(first.y + first.h, second.y + second.h)
    return { x = x, y = y, w = right - x, h = bottom - y }
end

local function showcase_bounds(target, label)
    if target == "navbar" then
        local stack = UIManager._window_stack or {}
        for index = #stack, 1, -1 do
            local navbar = find_descendant(stack[index].widget, function(widget)
                return type(widget.onTapNavBar) == "function" and widget.dimen ~= nil
            end)
            if navbar then return dimen_bounds(navbar.dimen) end
        end
        return nil, "navbar bounds unavailable"
    end
    if target == "panel_button" then
        local FileManager = require("apps/filemanager/filemanager")
        local menu = FileManager.instance and FileManager.instance.menu
        local touch_menu = menu and menu.menu_container and menu.menu_container[1]
        local refs = touch_menu and touch_menu._zen_panel_refs
        local wanted_id = label == "Zen" and "zen"
            or label == "Lockdown" and "lockdown" or nil
        for _i, button in ipairs(refs and refs.buttons or {}) do
            if button.id == wanted_id then
                local bounds = dimen_bounds(button.widget and button.widget.dimen)
                local label_widget = find_descendant(touch_menu, function(widget)
                    return widget.text == label and widget.dimen ~= nil
                end)
                return union_bounds(bounds, dimen_bounds(label_widget and label_widget.dimen))
            end
        end
        return nil, "panel button bounds unavailable"
    end
    return nil, "unknown showcase bounds target"
end

local Driver = WidgetContainer:extend{}

function Driver:init()
    self.socket_path = os.getenv("ZEN_UI_TEST_SOCKET")
    self.testing = os.getenv("ZEN_UI_TESTING") == "1"
    if self.testing and self.socket_path and #self.socket_path < SOCKET_PATH_MAX then
        self:startServer()
    end
end

function Driver:startServer()
    pcall(C.unlink, self.socket_path)
    local fd = C.socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 then return end
    local address = ffi.new("struct zen_test_sockaddr_un")
    if ffi.os == "OSX" then address.sun_len = ffi.sizeof(address) end
    address.sun_family = AF_UNIX
    ffi.copy(address.sun_path, self.socket_path)
    if C.bind(fd, ffi.cast("struct sockaddr *", address), ffi.sizeof(address)) < 0
            or C.listen(fd, 4) < 0 then
        C.close(fd)
        return
    end
    self.server_fd = fd
    self:pollServer()
end

function Driver:reply(client, payload)
    local encoded = rapidjson.encode(payload) .. "\n"
    C.write(client, encoded, #encoded)
    C.close(client)
end

function Driver:handleCommand(command)
    local kind = command and command.type
    local params = command and command.params or {}
    if kind == "configure_showcase" then
        local ok, err = configure_showcase(params)
        return { ok = ok == true, error = err }
    end
    if kind == "reset_showcase_ui" then
        return { ok = reset_showcase_ui(params.session) == true }
    end
    if kind == "showcase_navbar" and type(params.mode) == "string" then
        local ok, err = configure_showcase_navbar(params.mode)
        return { ok = ok == true, error = err, navbar = showcase_navbar_state() }
    end
    if kind == "showcase_home" then
        local ok, err = showcase_home(params.preset, params.simple)
        return { ok = ok == true, error = err }
    end
    if kind == "set_library_display_mode" and type(params.mode) == "string" then
        local ok, err = set_library_display_mode(params.mode)
        return { ok = ok == true, error = err }
    end
    if kind == "showcase_library_order" then
        local ok, err = set_showcase_library_order(params.paths)
        return { ok = ok == true, error = err }
    end
    if kind == "showcase_lockdown_control" then
        local ok, err = show_lockdown_control()
        return { ok = ok == true, error = err }
    end
    if kind == "open_file_context" and type(params.path) == "string" then
        local ok, err = open_file_context(params.path)
        return { ok = ok == true, error = err }
    end
    if kind == "show_metadata_editor_fixture" then
        local ok, err = show_metadata_editor_fixture(params.orientation)
        return { ok = ok == true, error = err, metadata = metadata_showcase_state() }
    end
    if kind == "show_metadata_cover_fixture" then
        local ok, err = show_metadata_cover_fixture()
        return { ok = ok == true, error = err }
    end
    if kind == "show_metadata_picker_fixture" then
        local ok, err = show_metadata_picker_fixture()
        local Screen = require("device").screen
        return {
            ok = ok == true,
            error = err,
            picker = showcase_picker,
            width = Screen:getWidth(),
            height = Screen:getHeight(),
        }
    end
    if kind == "open_quickstart" then
        local ok, err = open_quickstart()
        return { ok = ok == true, error = err }
    end
    if kind == "showcase_bounds" and type(params.target) == "string" then
        local bounds, err = showcase_bounds(params.target, params.label)
        return { ok = bounds ~= nil, bounds = bounds, error = err }
    end
    if kind == "showcase_picker_state" then
        return { ok = true, picker = showcase_picker }
    end
    if kind == "visible_ui" then return { ok = true, ui = visible_ui() } end
    if kind == "plugin_loaded" and type(params.name) == "string" then
        local PluginLoader = require("pluginloader")
        return { ok = true, loaded = PluginLoader:isPluginLoaded(params.name) }
    end
    if kind == "legacy_plugin_manager_state" then
        return legacy_plugin_manager_state()
    end
    if kind == "enable_legacy_plugin" then
        return enable_legacy_plugin()
    end
    if kind == "brand_migration_state" then
        return brand_migration_state()
    end
    if kind == "file_chooser_items" then
        local state = file_chooser_items()
        return state and { ok = true, file_chooser = state }
            or { ok = false, error = "file chooser unavailable" }
    end
    if kind == "tap_file_chooser_item" and type(params.path) == "string" then
        local ok, err = tap_file_chooser_item(params.path)
        return { ok = ok == true, error = err }
    end
    if kind == "file_chooser_cover_state" then
        local state = file_chooser_cover_state()
        return state and { ok = true, covers = state }
            or { ok = false, error = "file chooser unavailable" }
    end
    if kind == "open_book" and type(params.path) == "string" then
        local ok, err = open_book(params.path)
        return { ok = ok, error = err }
    end
    if kind == "reader_state" then
        return { ok = true, reader = reader_state() }
    end
    if kind == "customize_reader_footer" then
        local ok, err = customize_reader_footer()
        return { ok = ok == true, error = err }
    end
    if kind == "ensure_reader_status_fonts" then
        local ok, err = ensure_reader_status_fonts(params.preset)
        return { ok = ok == true, error = err }
    end
    if kind == "ensure_reader_chapter_time" then
        local ok, err = ensure_reader_chapter_time()
        return { ok = ok == true, error = err }
    end
    if kind == "goto_reader_page" then
        local ok, err = goto_reader_page(params.page)
        return { ok = ok == true, error = err }
    end
    if kind == "clear_reader_bookmarks" then
        local ok, err = require("reader_tools").clear_page_bookmarks()
        return { ok = ok == true, error = err }
    end
    if kind == "page_browser_state" then
        local state = require("reader_tools").page_browser_state()
        return state and { ok = true, page_browser = state }
            or { ok = false, error = "page browser unavailable" }
    end
    if kind == "page_browser_key" and type(params.key) == "string" then
        local handled, err = require("reader_tools").page_browser_key(params.key)
        return { ok = handled == true, handled = handled == true, error = err }
    end
    if kind == "hardware_overlay_state" then
        local state = require("reader_tools").hardware_overlay_state()
        return state and { ok = true, overlay = state }
            or { ok = false, error = "hardware overlay unavailable" }
    end
    if kind == "hardware_overlay_key" and type(params.key) == "string" then
        local handled, err = require("reader_tools").hardware_overlay_key(params.key)
        return { ok = handled == true, handled = handled == true, error = err }
    end
    if kind == "reader_overlay_state" then
        return { ok = true, overlays = require("reader_tools").overlay_state() }
    end
    if kind == "reader_launcher_state" then
        return { ok = true, launcher = require("reader_tools").launcher_state() }
    end
    if kind == "activate_reader_control" and type(params.name) == "string" then
        local activated, err = require("reader_tools").activate(params.name)
        return { ok = activated == true, activated = activated == true, error = err }
    end
    if kind == "home_state" then
        return { ok = true, home = home_state() }
    end
    if kind == "activate_home_target" and type(params.key) == "string" then
        local activated, err = activate_home_target(params.key, params.action)
        return { ok = activated == true, activated = activated == true, error = err }
    end
    if kind == "menu_tab_layout" then
        local FileManager = require("apps/filemanager/filemanager")
        local menu = FileManager.instance and FileManager.instance.menu
        if not menu then return { ok = false, error = "file manager menu unavailable" } end
        if menu.tab_item_table == nil and type(menu.setUpdateItemTable) == "function" then
            menu:setUpdateItemTable()
        end
        if not menu.menu_container and type(menu.onShowMenu) == "function" then menu:onShowMenu() end

        local touch_menu = menu.menu_container and menu.menu_container[1]
        local bar = touch_menu and touch_menu.bar
        local group = bar and bar.bar_icon_group
        local tabs = {}
        local group_positions = {}
        local tab_segments = {}
        local group_offset = 0
        for group_index, widget in ipairs(group or {}) do
            for tab_index, icon in ipairs(bar.icon_widgets or {}) do
                if widget == icon then
                    group_positions[tab_index] = group_index
                    tab_segments[tab_index] = {
                        s = group_offset,
                        e = group_offset + widget:getSize().w,
                    }
                    break
                end
            end
            group_offset = group_offset + widget:getSize().w
        end
        for tab_index, tab in ipairs(menu.tab_item_table or {}) do
            tabs[tab_index] = tab.id
        end
        if type(params.tab_id) == "string" then
            for tab_index, tab_id in ipairs(tabs) do
                if tab_id == params.tab_id then
                    bar.icon_widgets[tab_index].callback()
                    break
                end
            end
        end

        local active_tab = touch_menu and tabs[touch_menu.cur_tab]
        local empty_segment = bar and bar.bar_sep and bar.bar_sep.empty_segments
            and bar.bar_sep.empty_segments[1]
        local solid_separator_positions = {}
        local icon_seps = bar and bar.icon_seps or {}
        for group_index, widget in ipairs(group or {}) do
            for _i, sep in ipairs(icon_seps) do
                if widget == sep and sep.style == "solid" then
                    table.insert(solid_separator_positions, group_index)
                    break
                end
            end
        end
        return {
            ok = touch_menu ~= nil,
            tabs = tabs,
            group_positions = group_positions,
            tab_segments = tab_segments,
            active_tab = active_tab,
            empty_segment = empty_segment,
            solid_separator_positions = solid_separator_positions,
        }
    end
    if kind == "set_open_confirmation" then
        G_reader_settings:saveSetting("file_ask_to_open", params.enabled == true)
        return { ok = true }
    end
    if kind == "activate_book_switcher" then
        local FileManager = require("apps/filemanager/filemanager")
        local menu = FileManager.instance and FileManager.instance.menu
        local touch_menu = menu and menu.menu_container and menu.menu_container[1]
        local refs = touch_menu and touch_menu._zen_panel_refs
        local index = math.max(1, math.floor(tonumber(params.index) or 1))
        local button = refs and refs.buttons and refs.buttons[index]
        if not button or type(button.callback) ~= "function" then
            return { ok = false, error = "book switcher button unavailable" }
        end
        button.callback()
        return { ok = true }
    end
    if kind == "activate_launcher_entry" then
        local FileManager = require("apps/filemanager/filemanager")
        local menu = FileManager.instance and FileManager.instance.menu
        local touch_menu = menu and menu.menu_container and menu.menu_container[1]
        local refs = touch_menu and touch_menu._zen_panel_refs
        local index = math.max(1, math.floor(tonumber(params.index) or 1))
        local button = refs and refs.buttons and refs.buttons[index]
        if not button or type(button.callback) ~= "function" then
            return { ok = false, error = "launcher entry unavailable" }
        end
        button.callback()
        return { ok = true }
    end
    if kind == "book_switcher_state" then
        local FileManager = require("apps/filemanager/filemanager")
        local menu = FileManager.instance and FileManager.instance.menu
        local touch_menu = menu and menu.menu_container and menu.menu_container[1]
        local refs = touch_menu and touch_menu._zen_panel_refs
        local covers = {}
        for _i, button in ipairs(refs and refs.buttons or {}) do
            local cell = button.widget
            local cover = cell and cell._zen_book_switcher_cover
            local cell_dimen = cell and cell.dimen
            local cover_dimen = cover and cover.dimen
            if cell_dimen and cover_dimen then
                covers[#covers + 1] = {
                    cell = {
                        x = cell_dimen.x,
                        y = cell_dimen.y,
                        w = cell_dimen.w,
                        h = cell_dimen.h,
                    },
                    cover = {
                        x = cover_dimen.x,
                        y = cover_dimen.y,
                        w = cover_dimen.w,
                        h = cover_dimen.h,
                    },
                }
            end
        end
        local opening_banner_count = 0
        local confirmation_open = false
        local prompt = require("gettext")("Open this file?")
        for _i, window in ipairs(UIManager._window_stack or {}) do
            local widget = window.widget
            if widget and widget._zen_opening_banner == true then
                opening_banner_count = opening_banner_count + 1
            end
            if widget and type(widget.text) == "string"
                    and widget.text:sub(1, #prompt) == prompt then
                confirmation_open = true
            end
        end
        return {
            ok = true,
            launcher_open = refs ~= nil and touch_menu.item_table
                and touch_menu.item_table.id == "app_launcher" or false,
            confirmation_open = confirmation_open,
            opening_banner_count = opening_banner_count,
            page = refs and refs.page or nil,
            page_num = refs and refs.page_num or nil,
            divider_bottom = touch_menu and touch_menu.bar and touch_menu.bar.dimen
                and touch_menu.bar.dimen.y + touch_menu.bar.dimen.h or nil,
            menu_height = touch_menu and touch_menu.dimen and touch_menu.dimen.h or nil,
            screen_height = require("device").screen:getHeight(),
            covers = covers,
        }
    end
    if kind == "set_language" and type(params.language) == "string" then
        G_reader_settings:saveSetting("language", params.language)
        local GetText = require("gettext")
        local result = GetText.changeLang(params.language)
        return { ok = result ~= false, language = GetText.current_lang }
    end
    if kind == "open_settings_page" then
        local FileManager = require("apps/filemanager/filemanager")
        local menu = FileManager.instance and FileManager.instance.menu
        if not menu then return { ok = false, error = "file manager menu unavailable" } end
        local item = menu._zen_tab_item
        if not item and type(menu.setUpdateItemTable) == "function" then
            menu:setUpdateItemTable()
            item = menu._zen_tab_item
        end
        if not (item and type(item.callback) == "function") then
            return { ok = false, error = "Zen settings tab unavailable" }
        end
        if not menu.menu_container and type(menu.onShowMenu) == "function" then
            menu:onShowMenu()
        end
        local touch_menu = menu.menu_container and menu.menu_container[1]
        local tab_index
        for i, tab in ipairs(menu.tab_item_table or {}) do
            if tab == item then
                tab_index = i
                break
            end
        end
        if touch_menu and tab_index and type(touch_menu.switchMenuTab) == "function" then
            touch_menu:switchMenuTab(tab_index)
        else
            item.callback()
        end
        return { ok = true }
    end
    if kind == "settings_page_state" then
        local page = rawget(_G, "__ZEN_UI_SETTINGS_PAGE")
        if not page then return { ok = false, error = "settings page unavailable" } end
        local first_row = page.item_group and page.item_group[1]
        local focus_frame = first_row and first_row.item_frame
        local left_zone = page._zones and page._zones.zen_pn_left_tap
        local right_zone = page._zones and page._zones.zen_pn_right_tap
        local left_range = left_zone and left_zone.gs_range and left_zone.gs_range.range
        local right_range = right_zone and right_zone.gs_range and right_zone.gs_range.range
        local labels = {}
        local items = {}
        for _i, item in ipairs(page.item_table or {}) do
            local label = item._zen_display_text or item.text or ""
            local checked
            if type(item.checked_func) == "function" then
                local ok_checked, value = pcall(item.checked_func)
                if ok_checked then checked = value == true end
            end
            labels[#labels + 1] = label
            items[#items + 1] = {
                label = label,
                breadcrumb = item._zen_settings_breadcrumb,
                radio = item.radio == true,
                checked = checked,
            }
        end
        return {
            ok = true,
            settings = {
                title = page.title_bar and page.title_bar.title,
                back_visible = page.title_bar and page.title_bar.back_visible == true,
                status_visible = page.title_bar and page.title_bar.status_widget ~= nil,
                status_height = widget_height(page.title_bar and page.title_bar.status_widget),
                status_spacer_height = widget_height(page.title_bar and page.title_bar._vertical_group
                    and page.title_bar._vertical_group[3]),
                status_y = widget_y(page.title_bar and page.title_bar.status_widget),
                status_identity = tostring(page.title_bar and page.title_bar.status_widget),
                page = page.page,
                page_count = page.page_num,
                pager_x = left_range and left_range.x,
                pager_y = right_range and right_range.y,
                pager_width = left_range and right_range
                    and right_range.x + right_range.w - left_range.x,
                screen_width = page.width,
                title_font_size = page.title_bar and page.title_bar.title_widget
                    and page.title_bar.title_widget.face.orig_size or nil,
                title_bold = page.title_bar and page.title_bar.title_widget
                    and page.title_bar.title_widget.bold == true or false,
                search_active = page._search_active == true,
                has_search_input = page.title_bar and page.title_bar.search_input ~= nil,
                has_search_button = page.title_bar and page.title_bar.search_button ~= nil,
                has_more = page.title_bar and page.title_bar.more_button ~= nil,
                search_text = page.title_bar and page.title_bar.search_input
                    and page.title_bar.search_input:getText() or "",
                search_focused = page.title_bar and page.title_bar.search_input
                    and page.title_bar.search_input.focused == true or false,
                search_keyboard_visible = page.title_bar and page.title_bar.search_input
                    and page.title_bar.search_input:isKeyboardVisible() or false,
                search_text_inset = page.title_bar and page.title_bar.search_frame
                    and page.title_bar.search_frame.dimen
                    and page.title_bar.search_input.dimen
                    and page.title_bar.search_input.dimen.x
                        + page.title_bar.search_input.padding
                        - page.title_bar.search_frame.dimen.x or 0,
                search_radius = page.title_bar and page.title_bar.search_frame
                    and page.title_bar.search_frame.radius or 0,
                shortcuts_enabled = page.is_enable_shortcut == true
                    or page.key_events and page.key_events.SelectByShortCut ~= nil,
                row_focusable = focus_frame and focus_frame.focusable == true,
                row_focus_border_size = focus_frame and focus_frame.focus_border_size,
                row_focus_inner_border = focus_frame and focus_frame.focus_inner_border == true,
                row_focus_feedback = has_focus_feedback(focus_frame),
                row_style = find_settings_row_style(page.item_group),
                row_alignment = settings_row_alignment(page.item_group),
                standard_style = settings_row_standard(),
                labels = labels,
                items = items,
            },
        }
    end
    if kind == "settings_page_footer_tap" then
        local page = rawget(_G, "__ZEN_UI_SETTINGS_PAGE")
        if not page then return { ok = false, error = "settings page unavailable" } end
        local pager = require("common/ui/zen_pager")
        local Screen = require("device").screen
        local Geom = require("ui/geometry")
        local width = Screen:getWidth()
        local height = Screen:getHeight()
        local bar_width = math.floor(width * 0.92)
        local bar_x = math.floor((width - bar_width) / 2)
        local zone = params.zone or "right"
        local x = bar_x + math.floor(bar_width / 2)
        if zone == "left" then
            x = bar_x + math.floor(pager.CHEV_W / 2)
        elseif zone == "right" then
            x = bar_x + bar_width - math.floor(pager.CHEV_W / 2)
        end
        local footer_height = pager.getStyle() == "page_number"
            and pager.PN_FOOTER_H or pager.FOOTER_H
        local pager_zone = page._zones and page._zones["zen_pn_" .. zone .. "_tap"]
        local pager_range = pager_zone and pager_zone.gs_range and pager_zone.gs_range.range
        local gesture = {
            ges = "tap",
            pos = Geom:new{
                x = x,
                y = pager_range
                    and pager_range.y + math.floor(pager_range.h / 2)
                    or height - math.floor(footer_height / 2),
                w = 0,
                h = 0,
            },
        }
        local handled = page:handleEvent(Event:new("Gesture", gesture))
        return {
            ok = handled == true,
            page = page.page,
            page_count = page.page_num,
        }
    end
    if kind == "settings_page_titlebar_tap" then
        local page = rawget(_G, "__ZEN_UI_SETTINGS_PAGE")
        local button = page and page.title_bar
            and page.title_bar[(params.button or "search") .. "_button"]
        if not (page and button and button.dimen) then
            return { ok = false, error = "settings titlebar button unavailable" }
        end
        local Geom = require("ui/geometry")
        local dimen = button.dimen
        local handled = page:handleEvent(Event:new("Gesture", {
            ges = "tap",
            pos = Geom:new{
                x = dimen.x + math.floor(dimen.w / 2),
                y = dimen.y + math.floor(dimen.h / 2),
                w = 0,
                h = 0,
            },
        }))
        return { ok = handled == true }
    end
    if kind == "settings_modal_enter_behavior" then
        if not rawget(_G, "__ZEN_UI_SETTINGS_PAGE") then
            return { ok = false, error = "settings page unavailable" }
        end
        local InputDialog = require("ui/widget/inputdialog")
        local submitted = false
        local dialog = InputDialog:new{
            title = "Keyboard test",
            buttons = {{
                {
                    text = "Set",
                    is_enter_default = true,
                    callback = function() submitted = true end,
                },
            }},
        }
        local input = dialog._input_widget
        local keyboard_closed = false
        local unfocused = false
        input.isKeyboardVisible = function() return true end
        input.onCloseKeyboard = function() keyboard_closed = true end
        input.unfocus = function() unfocused = true end
        local ok_enter, err = pcall(input.enter_callback)
        input:onCloseWidget()
        return {
            ok = ok_enter,
            error = ok_enter and nil or tostring(err),
            dismissed = keyboard_closed and unfocused,
            submitted = submitted,
        }
    end
    if kind == "settings_page_select" and type(params.label) == "string" then
        local page = rawget(_G, "__ZEN_UI_SETTINGS_PAGE")
        if not page then return { ok = false, error = "settings page unavailable" } end
        for _i, item in ipairs(page.item_table or {}) do
            local label = item._zen_display_text or item.text or ""
            if label == params.label then
                local ok_select, err = pcall(page.onMenuSelect, page, item)
                return { ok = ok_select, error = ok_select and nil or tostring(err) }
            end
        end
        return { ok = false, error = "settings item unavailable" }
    end
    if kind == "settings_page_back" then
        local page = rawget(_G, "__ZEN_UI_SETTINGS_PAGE")
        if not page then return { ok = false, error = "settings page unavailable" } end
        local ok_back, err = pcall(page.backToUpperMenu, page, true)
        return { ok = ok_back, error = ok_back and nil or tostring(err) }
    end
    if kind == "settings_page_search" and type(params.query) == "string" then
        local page = rawget(_G, "__ZEN_UI_SETTINGS_PAGE")
        if not page then return { ok = false, error = "settings page unavailable" } end
        local ok_search, err = pcall(page._onSearchChanged, page, params.query)
        return { ok = ok_search, error = ok_search and nil or tostring(err) }
    end
    if kind == "settings_page_type_search" and type(params.text) == "string" then
        local page = rawget(_G, "__ZEN_UI_SETTINGS_PAGE")
        local title_bar = page and page.title_bar
        local input = title_bar and title_bar.search_input
        if not input and title_bar and type(title_bar.openSearch) == "function" then
            title_bar:openSearch()
            input = title_bar.search_input
        end
        if not input then return { ok = false, error = "settings search unavailable" } end
        local ok_type, err = pcall(function()
            local dimen = title_bar.search_frame and title_bar.search_frame.dimen
            if title_bar.onTapSearch and dimen then
                title_bar:onTapSearch(nil, {
                    pos = {
                        x = dimen.x + math.floor(dimen.w / 2),
                        y = dimen.y + math.floor(dimen.h / 2),
                    },
                })
            else
                input:focus()
            end
            for character in params.text:gmatch(".") do
                UIManager:sendEvent(Event:new("TextInput", character))
            end
        end)
        return { ok = ok_type, error = ok_type and nil or tostring(err) }
    end
    if kind == "settings_page_submit_search" then
        local page = rawget(_G, "__ZEN_UI_SETTINGS_PAGE")
        local input = page and page.title_bar and page.title_bar.search_input
        if not input then return { ok = false, error = "settings search unavailable" } end
        local ok_submit, err = pcall(input.onTextInput, input, "\n")
        return { ok = ok_submit, error = ok_submit and nil or tostring(err) }
    end
    if kind == "settings_page_non_touch_search" then
        local page = rawget(_G, "__ZEN_UI_SETTINGS_PAGE")
        local title_bar = page and page.title_bar
        local search_button = title_bar and title_bar.search_button
        local button_x, button_y = focus_position(page, search_button)
        local initial_close_x, initial_close_y = focus_position(page, title_bar and title_bar.close_button)
        if not (title_bar and button_x and button_y and initial_close_x and initial_close_y) then
            return { ok = false, error = "settings search button unavailable" }
        end
        page.selected = { x = button_x, y = button_y }
        local search_button_focused = page.selected.x == button_x and page.selected.y == button_y
        page:onZenSettingsFocusRight()
        local close_focused_from_search = page.selected.x == initial_close_x
            and page.selected.y == initial_close_y
        page:onZenSettingsFocusLeft()
        local search_focused_from_close = page.selected.x == button_x and page.selected.y == button_y
        title_bar:openSearch()
        local input = title_bar.search_input
        local input_x, input_y = focus_position(page, input)
        local close_x, close_y = focus_position(page, title_bar.close_button)
        if not (input and input_x and input_y and close_x and close_y) then
            return { ok = false, error = "settings search input unavailable" }
        end
        local search_input_focused = input_x == page.selected.x and input_y == page.selected.y
        input.focused = true
        input.charpos = #(input.charlist or {}) + 1
        local exited = input:onKeyPress({ Right = true })
        local close_focused = page.selected.x == close_x and page.selected.y == close_y
        title_bar:setQuery("term")
        page:_onSearchChanged("term")
        title_bar.close_button.callback()
        local collapsed_search_x, collapsed_search_y = focus_position(page, title_bar.search_button)
        return {
            ok = true,
            search_button_focused = search_button_focused,
            close_focused_from_search = close_focused_from_search,
            search_focused_from_close = search_focused_from_close,
            search_input_focused = search_input_focused,
            exited = exited == true,
            close_focused = close_focused,
            search_input_focused_after_exit = input.focused == true,
            search_closed = title_bar.search_input == nil and title_bar.query == ""
                and page._search_active == false,
            search_button_focused_after_close = page.selected.x == collapsed_search_x
                and page.selected.y == collapsed_search_y,
        }
    end
    if kind == "arrange_page_state" then
        local widget = active_arrange_widget()
        local title_bar = widget and widget.title_bar
        if not title_bar then
            return { ok = false, error = "arrange page unavailable" }
        end
        local labels = {}
        local checked = {}
        local submenu_indices = {}
        for item_i, item in ipairs(widget.item_table or {}) do
            local label = item._zen_arrange_base_text or item.text or ""
            if type(item.text_func) == "function" then
                local ok_text, value = pcall(item.text_func)
                if ok_text and type(value) == "string" then label = value end
            end
            labels[#labels + 1] = label
            local value = false
            if type(item.checked_func) == "function" then
                local ok_checked, is_checked = pcall(item.checked_func)
                if ok_checked then value = is_checked == true end
            end
            checked[#checked + 1] = value
            if type(item.sub_item_table) == "table"
                    or type(item.sub_item_table_func) == "function" then
                submenu_indices[#submenu_indices + 1] = item_i
            end
        end
        local first_row = widget.main_content and widget.main_content[2]
        local focus_frame = first_row and first_row[1] and first_row[1][1]
        local focused = widget.getFocusItem and widget:getFocusItem()
        local drop_refresh_modes = widget._zen_test_refresh_modes
        widget._zen_test_capture_refresh_modes = false
        local handle_focus_visible = false
        for _row_i, row in ipairs(widget.main_content or {}) do
            local handle = row._zen_arrange_handle
            if handle and (handle.invert == true or handle._focused == true
                    or (handle.inner_bordersize or 0) > 0) then
                handle_focus_visible = true
                break
            end
        end
        return {
            ok = true,
            arrange = {
                title = title_bar.title,
                back_visible = title_bar.back_button ~= nil,
                has_search = title_bar.search_input ~= nil,
                has_more = title_bar.more_button ~= nil,
                has_close = title_bar.close_button ~= nil,
                has_action = title_bar.action_button ~= nil,
                status_visible = title_bar.status_widget ~= nil,
                status_height = widget_height(title_bar.status_widget),
                status_y = widget_y(title_bar.status_widget),
                status_identity = tostring(title_bar.status_widget),
                filemanager_status_height = filemanager_status_height(),
                filemanager_status_y = filemanager_status_y(),
                marked = widget.marked,
                handle_focused = focused and focused._zen_arrange_handle == true,
                handle_focus_visible = handle_focus_visible,
                item_focused = focused and focused._zen_arrange_content == true,
                toggle_focused = focused and focused._zen_arrange_toggle == true,
                focused_index = focused and focused.index,
                handle_active = widget._zen_handle_active == true,
                dragging = widget._zen_dragging == true,
                item_drag_hold_pending = widget._zen_item_drag_hold ~= nil,
                item_drag_hold_delay = widget._zen_item_drag_hold_delay,
                drag_unfocus_pending = widget._zen_drag_unfocus ~= nil,
                drop_refresh_modes = drop_refresh_modes,
                handle_visible = first_row and first_row._zen_arrange_handle ~= nil,
                item_focusable = first_row
                    and is_focus_target(widget, first_row._zen_arrange_content_focus),
                toggle_focusable = first_row
                    and is_focus_target(widget, first_row._zen_arrange_toggle_focus),
                toggle_focus_border_size = first_row
                    and first_row._zen_arrange_toggle_focus
                    and first_row._zen_arrange_toggle_focus.focus_border_size,
                toggle_focus_feedback = first_row
                    and has_focus_feedback(first_row._zen_arrange_toggle_focus),
                page_count = widget.pages,
                items_per_page = widget.items_per_page,
                pagination_visible = widget.page_info
                    and widget.page_info._zen_arrange_footer_visible == true,
                footer_cancel_hidden = widget.footer_cancel
                    and widget.footer_cancel.skip_paint == true,
                footer_first_hidden = widget.footer_first_up
                    and widget.footer_first_up.skip_paint == true,
                footer_last_hidden = widget.footer_last_down
                    and widget.footer_last_down.skip_paint == true,
                footer_ok_hidden = widget.footer_ok
                    and widget.footer_ok.skip_paint == true,
                row_focusable = focus_frame and focus_frame.focusable == true,
                row_focus_border_size = focus_frame and focus_frame.focus_border_size,
                row_focus_inner_border = focus_frame and focus_frame.focus_inner_border == true,
                row_focus_feedback = has_focus_feedback(focus_frame),
                action_focusable = is_focus_target(widget, title_bar.action_button),
                close_focusable = is_focus_target(widget, title_bar.close_button),
                action_focus_feedback = has_focus_feedback(title_bar.action_button),
                close_focus_feedback = has_focus_feedback(title_bar.close_button),
                row_style = find_settings_row_style(widget.main_content),
                row_alignment = settings_row_alignment(widget.main_content),
                standard_style = settings_row_standard(),
                labels = labels,
                checked = checked,
                submenu_indices = submenu_indices,
            },
        }
    end
    if kind == "arrange_page_focus_header" then
        local widget = active_arrange_widget()
        local title_bar = widget and widget.title_bar
        local controls = title_bar and title_bar.generateHorizontalLayout
            and title_bar:generateHorizontalLayout()[1]
        local back_x, back_y = focus_position(widget, title_bar and title_bar.back_button)
        local action_x, action_y = focus_position(widget, title_bar and title_bar.action_button)
        local close_x, close_y = focus_position(widget, title_bar and title_bar.close_button)
        if not (back_x and action_x and close_x and controls) then
            return { ok = false, error = "arrange header controls unavailable" }
        end
        widget.selected = { x = back_x, y = back_y }
        widget:onZenArrangeOpenSubmenu()
        local action_focused = widget.selected.x == action_x and widget.selected.y == action_y
        widget:onZenArrangeOpenSubmenu()
        local close_focused = widget.selected.x == close_x and widget.selected.y == close_y
        title_bar.close_button:handleEvent(Event:new("Unfocus"))
        widget.selected = { x = 1, y = back_y + 1 }
        return { ok = true, action_focused = action_focused, close_focused = close_focused }
    end
    if kind == "arrange_page_key" then
        local widget = active_arrange_widget()
        if not widget then return { ok = false, error = "arrange page unavailable" } end
        local Key = require("device/key")
        local event_name = params.phase == "release" and "KeyRelease"
            or params.phase == "repeat" and "KeyRepeat"
            or "KeyPress"
        local handled = widget:handleEvent(Event:new(
            event_name,
            Key:new(params.key or "Press", {})
        ))
        return { ok = handled == true, marked = widget.marked }
    end
    if kind == "arrange_page_menu" then
        local widget = active_arrange_widget()
        if not widget then return { ok = false, error = "arrange page unavailable" } end
        local FileManager = require("apps/filemanager/filemanager")
        local menu = FileManager.instance and FileManager.instance.menu
        local Key = require("device/key")
        local handled = widget:handleEvent(Event:new(
            "KeyPress",
            Key:new("Menu", {})
        ))
        local menu_open = menu and menu.menu_container ~= nil
        if menu_open and params.close_menu == true
                and type(menu.onCloseFileManagerMenu) == "function" then
            menu:onCloseFileManagerMenu()
        end
        return {
            ok = handled == true,
            marked = widget.marked,
            handle_active = widget._zen_handle_active == true,
            menu_open = menu_open,
        }
    end
    if kind == "arrange_page_drag" then
        local widget = active_arrange_widget()
        if not widget then return { ok = false, error = "arrange page unavailable" } end
        if params.track_refresh_modes == true then
            widget._zen_test_refresh_modes = {}
            widget._zen_test_capture_refresh_modes = true
        end
        local rows = {}
        for _i, row in ipairs(widget.main_content or {}) do
            if row._zen_arrange_handle and row._zen_arrange_handle.dimen then
                rows[#rows + 1] = row
            end
        end
        local from_row = rows[tonumber(params.from) or 1]
        local to_row = rows[tonumber(params.to) or 2]
        if not from_row or (not to_row and not params.edge) then
            return { ok = false, error = "arrange handles unavailable" }
        end
        local Geom = require("ui/geometry")
        local function center(dimen)
            return Geom:new{
                x = dimen.x + math.floor(dimen.w / 2),
                y = dimen.y + math.floor(dimen.h / 2),
                w = 0,
                h = 0,
            }
        end
        local from_pos = center(params.start_area == "row"
            and from_row.dimen or from_row._zen_arrange_handle.dimen)
        local to_pos = to_row and center(params.start_area == "row"
            and to_row.dimen or to_row._zen_arrange_handle.dimen)
            or from_pos:copy()
        if params.edge == "left" then
            to_pos = from_pos:copy()
            to_pos.x = widget.dimen.x
        elseif params.edge == "right" then
            to_pos = from_pos:copy()
            to_pos.x = widget.dimen.x + widget.dimen.w - 1
        elseif params.edge == "up" then
            to_pos.y = rows[1]._zen_arrange_handle.dimen.y - 1
        elseif params.edge == "down" then
            local last = rows[#rows]._zen_arrange_handle.dimen
            to_pos.y = last.y + last.h
        end
        local relative = Geom:new{
            x = to_pos.x - from_pos.x,
            y = to_pos.y - from_pos.y,
            w = 0,
            h = 0,
        }
        local started
        local moved = true
        if params.start_gesture == "touch" then
            started = widget:handleEvent(Event:new("Gesture", {
                ges = "touch",
                pos = from_pos,
            }))
        elseif params.start_gesture == "continue" then
            started = widget._zen_dragging == true
            moved = started and widget:handleEvent(Event:new("Gesture", {
                ges = "pan",
                pos = to_pos,
                start_pos = from_pos,
                relative = relative,
            })) or false
        elseif params.start_gesture == "hold" then
            if params.touch_first == true then
                widget:handleEvent(Event:new("Gesture", {
                    ges = "touch",
                    pos = from_pos,
                }))
            end
            started = widget:handleEvent(Event:new("Gesture", {
                ges = "hold",
                pos = from_pos,
            }))
            if params.edge or to_pos.x ~= from_pos.x or to_pos.y ~= from_pos.y then
                moved = widget:handleEvent(Event:new("Gesture", {
                    ges = "hold_pan",
                    pos = to_pos,
                    start_pos = from_pos,
                    relative = relative,
                }))
            end
        elseif params.edge then
            started = widget:handleEvent(Event:new("Gesture", {
                ges = "pan",
                pos = to_pos,
                start_pos = from_pos,
                relative = relative,
            }))
        else
            started = widget:handleEvent(Event:new("Gesture", {
                ges = "pan",
                pos = from_pos,
            }))
            moved = widget:handleEvent(Event:new("Gesture", {
                ges = "pan",
                pos = to_pos,
                start_pos = from_pos,
                relative = relative,
            }))
        end
        local released = true
        if params.release_gesture == "swipe" then
            released = widget:handleEvent(Event:new("Gesture", {
                ges = "swipe",
                direction = to_pos.y >= from_pos.y and "south" or "north",
                pos = from_pos,
                end_pos = to_pos,
                start_pos = from_pos,
                relative = relative,
            }))
        elseif params.release ~= false then
            released = widget:handleEvent(Event:new("Gesture", {
                ges = params.start_gesture == "hold" and "hold_release" or "pan_release",
                pos = to_pos,
                start_pos = from_pos,
                relative = relative,
            }))
        end
        if params.focus_without_unfocus == true then
            local focused = widget.getFocusItem and widget:getFocusItem()
            if focused then focused.onUnfocus = false end
        end
        return {
            ok = started == true and moved == true and released == true,
            marked = widget.marked,
            page = widget.show_page,
            dragging = widget._zen_dragging == true,
            item_drag_hold_pending = widget._zen_item_drag_hold ~= nil,
            item_drag_hold_delay = widget._zen_item_drag_hold_delay,
            drag_unfocus_pending = widget._zen_drag_unfocus ~= nil,
        }
    end
    if kind == "arrange_page_turn" then
        local widget = active_arrange_widget()
        if not widget then return { ok = false, error = "arrange page unavailable" } end
        if params.direction == "previous" then
            widget:onPrevPage()
        else
            widget:onNextPage()
        end
        return {
            ok = true,
            marked = widget.marked,
            page = widget.show_page,
            dragging = widget._zen_dragging == true,
            handle_active = widget._zen_handle_active == true,
        }
    end
    if kind == "arrange_page_select" then
        local widget = active_arrange_widget()
        local index = tonumber(params.index) or 1
        if not widget then return { ok = false, error = "arrange page unavailable" } end
        for _i, row in ipairs(widget.main_content or {}) do
            if row.index == index and type(row.onTap) == "function" then
                local handled = row:onTap(nil, {})
                return { ok = handled == true }
            end
        end
        return { ok = false, error = "arrange row unavailable" }
    end
    if kind == "arrange_page_back" then
        local widget = active_arrange_widget()
        local button = widget and widget.title_bar and widget.title_bar.back_button
        if not (button and type(button.callback) == "function") then
            return { ok = false, error = "arrange back unavailable" }
        end
        button.callback()
        return { ok = true }
    end
    if kind == "arrange_page_hardware_back" then
        local widget = active_arrange_widget()
        if not widget then
            return { ok = false, error = "arrange page unavailable" }
        end
        local Key = require("device/key")
        local handled = widget:handleEvent(Event:new(
            "KeyPress",
            Key:new("Back", {})
        ))
        return { ok = handled == true }
    end
    if kind == "arrange_page_close_button" then
        local widget = active_arrange_widget()
        local button = widget and widget.title_bar and widget.title_bar.close_button
        if not (button and type(button.callback) == "function") then
            return { ok = false, error = "arrange close unavailable" }
        end
        button.callback()
        return { ok = true }
    end
    if kind == "arrange_page_go_to" then
        local widget = active_arrange_widget()
        local page = tonumber(params.page)
        if not (widget and page and page >= 1 and page <= widget.pages) then
            return { ok = false, error = "arrange page unavailable" }
        end
        widget:onGoToPage(page)
        return { ok = true, page = widget.show_page }
    end
    if kind == "arrange_page_top_tap" then
        local widget = active_arrange_widget()
        if not widget then return { ok = false, error = "arrange page unavailable" } end
        local Device = require("device")
        local Geom = require("ui/geometry")
        local FileManager = require("apps/filemanager/filemanager")
        local menu = FileManager.instance and FileManager.instance.menu
        local gesture = {
            ges = "tap",
            pos = Geom:new{
                x = math.floor(Device.screen:getWidth() * (tonumber(params.x_ratio) or 0.5)),
                y = math.floor(Device.screen:getHeight() * (tonumber(params.y_ratio) or 0.01)),
                w = 0,
                h = 0,
            },
        }
        local handled = widget:handleEvent(Event:new("Gesture", gesture))
        local current = active_arrange_widget()
        local menu_open = menu and menu.menu_container ~= nil
        if menu_open and params.close_menu == true
                and type(menu.onCloseFileManagerMenu) == "function" then
            menu:onCloseFileManagerMenu()
        end
        return {
            ok = handled == true,
            same_widget = current == widget,
            marked = current and current.marked,
            title = current and current.title_bar and current.title_bar.title,
            menu_open = menu_open,
        }
    end
    if kind == "arrange_page_top_swipe" then
        local widget = active_arrange_widget()
        if not widget then return { ok = false, error = "arrange page unavailable" } end
        local Device = require("device")
        local Geom = require("ui/geometry")
        local FileManager = require("apps/filemanager/filemanager")
        local menu = FileManager.instance and FileManager.instance.menu
        local pos = Geom:new{
            x = math.floor(Device.screen:getWidth() * 0.5),
            y = math.floor(Device.screen:getHeight() * 0.01),
            w = 0,
            h = 0,
        }
        local handled = widget:handleEvent(Event:new("Gesture", {
            ges = "swipe",
            direction = "south",
            pos = pos,
            start_pos = pos,
        }))
        local menu_open = menu and menu.menu_container ~= nil
        if menu_open and params.close_menu == true
                and type(menu.onCloseFileManagerMenu) == "function" then
            menu:onCloseFileManagerMenu()
        end
        return {
            ok = handled == true,
            marked = widget.marked,
            dragging = widget._zen_dragging == true,
            menu_open = menu_open,
        }
    end
    if kind == "arrange_page_action" then
        local widget = active_arrange_widget()
        local title_bar = widget and widget.title_bar
        local button = title_bar and title_bar.action_button
        if not (button and type(button.callback) == "function") then
            return { ok = false, error = "arrange action unavailable" }
        end
        button.callback()
        return { ok = true }
    end
    if kind == "arrange_page_search" and type(params.query) == "string" then
        local widget = active_arrange_widget()
        local title_bar = widget and widget.title_bar
        if not (title_bar and type(title_bar.search_callback) == "function") then
            return { ok = false, error = "arrange search unavailable" }
        end
        title_bar.search_callback(params.query)
        return { ok = true }
    end
    if kind == "close_arrange_page" then
        local widget = active_arrange_widget()
        if not widget then return { ok = false, error = "arrange page unavailable" } end
        if type(widget._zen_arrange_close_all) == "function" then
            widget:_zen_arrange_close_all()
        else
            UIManager:close(widget)
        end
        return { ok = true }
    end
    if kind == "refresh_clock" then
        require("common/clock_timer").refreshNow()
        return { ok = true }
    end
    if kind == "close_settings_page" then
        local page = rawget(_G, "__ZEN_UI_SETTINGS_PAGE")
        if not page then return { ok = false, error = "settings page unavailable" } end
        page:closeMenu()
        return { ok = true }
    end
    if kind == "zen_settings_stack_state" then
        local arrange_count = 0
        for index = #UIManager._window_stack, 1, -1 do
            local widget = UIManager._window_stack[index].widget
            if is_arrange_widget(widget) then
                arrange_count = arrange_count + 1
            end
        end
        return {
            ok = true,
            settings_open = rawget(_G, "__ZEN_UI_SETTINGS_PAGE") ~= nil,
            arrange_count = arrange_count,
        }
    end
    if kind == "custom_action_state" then
        local settings_page = rawget(_G, "__ZEN_UI_SETTINGS_PAGE")
        local plugin = settings_page and settings_page.plugin
        if not plugin then
            local loader = require("pluginloader")
            local ok_plugin, loaded = pcall(loader.getPluginInstance, loader, "zenos")
            if ok_plugin then plugin = loaded end
        end
        local config = plugin and plugin.config or {}
        local buttons = config.quick_settings and config.quick_settings.custom_buttons or {}
        local actions = {}
        for _i, button in ipairs(buttons) do
            actions[#actions + 1] = {
                id = button.id,
                label = button.label,
                history = type(button.action) == "table" and button.action.history ~= nil,
                filebrowser = type(button.action) == "table"
                    and button.action.filemanager ~= nil,
            }
        end
        return { ok = true, actions = actions }
    end
    if kind == "native_menu_state" and type(params.id) == "string" then
        local scope = type(params.scope) == "string" and params.scope or "active"
        local NativeMenu = require("modules/menu/app_launcher/native_menu")
        local items = NativeMenu.scan(scope)
        local controls = rawget(_G, "__ZEN_UI_QUICK_SETTINGS")
        local ids = {}
        for _i, item in ipairs(items) do ids[#ids + 1] = item.id end
        return {
            ok = true,
            exists = NativeMenu.exists(params.id, scope),
            ids = ids,
            control_present = controls and controls.has
                and controls.has(params.control_id or "") == true,
            control_disabled = controls and controls.isDisabled
                and controls.isDisabled(params.control_id or "") == true,
        }
    end
    if kind == "activate_custom_control" and type(params.id) == "string" then
        local controls = rawget(_G, "__ZEN_UI_QUICK_SETTINGS")
        if not (controls and type(controls.activate) == "function") then
            return { ok = false, error = "controls unavailable" }
        end
        local host = {
            item_table = { panel = true },
            closeMenu = function() end,
            updateItems = function() end,
        }
        return { ok = controls.activate(params.id, host) == true }
    end
    if kind == "open_koreader_history" then
        local FileManager = require("apps/filemanager/filemanager")
        local fm = FileManager.instance
        local history = fm and fm.history
        local menu_items = {}
        if history and type(history.addToMainMenu) == "function" then
            history:addToMainMenu(menu_items)
        end
        local item = menu_items.history
        if not (item and type(item.callback) == "function") then
            return { ok = false, error = "history menu item unavailable" }
        end
        item.callback()
        return { ok = true }
    end
    if kind == "history_state" then
        local FileManager = require("apps/filemanager/filemanager")
        local fm = FileManager.instance
        return {
            ok = true,
            open = fm and fm.history and fm.history.booklist_menu ~= nil,
            settings_open = rawget(_G, "__ZEN_UI_SETTINGS_PAGE") ~= nil,
        }
    end
    if kind == "close_history" then
        local FileManager = require("apps/filemanager/filemanager")
        local history = FileManager.instance and FileManager.instance.history
        local menu = history and history.booklist_menu
        if not menu then return { ok = false, error = "history unavailable" } end
        menu:onCloseAllMenus()
        return { ok = true }
    end
    if kind == "open_widget_settings" and type(params.id) == "string" then
        local module_name = params.page == "stats"
            and "modules/settings/sections/stats_settings"
            or "modules/settings/sections/library_settings/home_settings"
        local ok_call, opened = pcall(function()
            local plugin = params.page == "stats" and nil
                or require("modules/filebrowser/patches/home_page")
            local register_home_api = type(plugin) == "function"
                and find_upvalue(plugin, "register_home_api") or nil
            return require(module_name).openWidgetSettings(
                params.id,
                register_home_api and find_upvalue(register_home_api, "_zen_plugin") or nil
            )
        end)
        return {
            ok = ok_call and opened == true,
            opened = ok_call and opened == true,
            error = ok_call and nil or tostring(opened),
        }
    end
    if kind == "navbar_state" then
        return { ok = true, navbar = navbar_state() }
    end
    if kind == "navbar_key" and type(params.key) == "string" then
        local stack = UIManager._window_stack
        local top = stack and stack[#stack]
        local target = top and top.widget
        local FileManager = require("apps/filemanager/filemanager")
        local chooser = FileManager.instance and FileManager.instance.file_chooser
        if not (target and target._zen_navbar_key_patched) then target = chooser end
        if not target then return { ok = false, error = "navbar owner unavailable" } end
        local Key = require("device/key")
        local count = math.max(1, math.min(math.floor(tonumber(params.count) or 1), 64))
        local handled = false
        for _i = 1, count do
            if target:handleEvent(Event:new("KeyPress", Key:new(params.key, {}))) then
                handled = true
            end
        end
        local fm_menu = FileManager.instance and FileManager.instance.menu
        local menu_open = fm_menu and fm_menu.menu_container ~= nil
        if menu_open and params.close_menu == true
                and type(fm_menu.onCloseFileManagerMenu) == "function" then
            fm_menu:onCloseFileManagerMenu()
        end
        local selected = target.selected
        local row = selected and target.layout and target.layout[selected.y]
        local focused_widget = row and row[selected.x]
        return {
            ok = handled,
            target = target == chooser and "file_chooser" or "standalone",
            menu_open = menu_open,
            home_focus_key = target._zen_home_focus_key,
            focus_x = selected and selected.x or nil,
            focus_y = selected and selected.y or nil,
            content_focused = is_keyboard_focused(focused_widget, {}, 0),
        }
    end
    if kind == "activate_navbar_tab" and type(params.id) == "string" then
        local allowed = {
            books = true, folder = true, home = true, authors = true, series = true,
            tags = true, to_be_read = true, stats = true,
        }
        local open_tab = rawget(_G, "__ZEN_UI_NAVBAR_OPEN_TAB")
        if not allowed[params.id] and params.id:sub(1, 3) ~= "ct_" then
            return { ok = false, error = "navbar tab is not allowed" }
        end
        if type(open_tab) ~= "function" then
            return { ok = false, error = "navbar callback unavailable" }
        end
        return { ok = open_tab(params.id) == true }
    end
    if kind == "tap_navbar_tab" and type(params.label) == "string" then
        local ok, err = tap_navbar_tab(
            params.label,
            type(params.id) == "string" and params.id or nil,
            tonumber(params.y_ratio)
        )
        return { ok = ok == true, error = err }
    end
    if kind == "race_home_to_books" then
        local open_tab = rawget(_G, "__ZEN_UI_NAVBAR_OPEN_TAB")
        if type(open_tab) ~= "function" or open_tab("home") ~= true then
            return { ok = false, error = "Home tab unavailable" }
        end
        UIManager:scheduleIn(0.05, function() open_tab("books") end)
        return { ok = true }
    end
    if kind == "reader_menu_home" then
        local ReaderUI = require("apps/reader/readerui")
        local reader = ReaderUI.instance
        local menu = reader and reader.menu
        if not reader or not reader.document or not menu then
            return { ok = false, error = "reader unavailable" }
        end
        if type(menu.setUpdateItemTable) == "function" then
            menu:setUpdateItemTable()
        end
        local home_item = menu._zen_home_tab_item
        if not home_item or type(home_item.callback) ~= "function" then
            return { ok = false, error = "Zen library Home menu item unavailable" }
        end
        home_item.callback()
        return { ok = true }
    end
    if kind == "file_chooser_next_page" then
        local FileManager = require("apps/filemanager/filemanager")
        local chooser = FileManager.instance and FileManager.instance.file_chooser
        if not chooser or type(chooser.onNextPage) ~= "function" then
            return { ok = false, error = "file chooser unavailable" }
        end
        chooser:onNextPage()
        return { ok = true, page = chooser.page }
    end
    if kind == "cover_cache_stats" then
        return { ok = true, stats = require("common/cover_decode_cache"):stats() }
    end
    if kind == "cover_cache_comparison" then
        local result, err = cover_cache_comparison()
        return result and { ok = true, measurement = result }
            or { ok = false, error = err }
    end
    if kind == "checkpoint" then return { ok = true, name = params.name } end
    if kind == "screenshot" and type(params.output) == "string" then
        local ok, Device = pcall(require, "device")
        if ok and Device and Device.screen and Device.screen.shot then
            local saved = pcall(Device.screen.shot, Device.screen, params.output)
            return { ok = saved }
        end
        return { ok = false, error = "screen capture unavailable" }
    end
    return { ok = false, error = "unknown command" }
end

function Driver:pollServer()
    if not self.server_fd then return end
    local pollfd = ffi.new("struct pollfd")
    pollfd.fd = self.server_fd
    pollfd.events = POLLIN
    if C.poll(pollfd, 1, 0) > 0 then
        local client = C.accept(self.server_fd, nil, nil)
        if client >= 0 then
            local buffer = ffi.new("char[65536]")
            local count = C.read(client, buffer, 65535)
            if count > 0 then
                local ok, command = pcall(rapidjson.decode, ffi.string(buffer, count))
                self:reply(client, ok and self:handleCommand(command) or {
                    ok = false,
                    error = "invalid JSON",
                })
            else
                C.close(client)
            end
        end
    end
    UIManager:scheduleIn(0.1, function() self:pollServer() end)
end

function Driver:onClose()
    if self.server_fd then C.close(self.server_fd) end
    self.server_fd = nil
    if self.socket_path then pcall(C.unlink, self.socket_path) end
end

return Driver
