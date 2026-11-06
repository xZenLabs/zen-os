-- Themable inline glyphs: maps NerdFont glyphs to bundled SVGs resolved through icon packs.
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local TextWidget = require("ui/widget/textwidget")

local Screen = Device.screen

local M = {}

-- inline_icon_map key -> bundled SVG (resolved via icon packs) for settings rows and button dialogs
M.SVG = {
    action = "settings_lightning_bolt", archive = "settings_archive_outline",
    arrow_left = "settings_chevron_left", arrow_right = "settings_chevron_right",
    authors = "settings_account_outline", battery = "settings_battery_70",
    bluetooth_on = "settings_bluetooth", book_switcher = "settings_history",
    bottom_swipe = "settings_gesture_swipe_up", calendar = "settings_calendar_month_outline",
    chapter_time_format = "settings_draw_pen", clear = "settings_restore",
    connect = "settings_link", copy = "settings_content_copy", custom_icons = "settings_image_multiple_outline",
    cut = "settings_content_cut", delete = "settings_delete_outline", details = "info",
    display = "settings_eye_outline", divider = "settings_division",
    double_tap = "settings_gesture_double_tap", download = "settings_download",
    edit = "settings_square_edit_outline", enable = "settings_play",
    end_book = "settings_book_check", fav_add = "settings_star",
    fav_remove = "settings_star_outline", filename = "settings_file_outline", filter = "filter",
    finished = "settings_check", flip_lh_rh = "settings_reflect_horizontal",
    folder_open = "settings_folder_open_outline", font = "font",
    hide_reader_actions = "settings_eye_off", history = "settings_history",
    icon = "settings_image_filter_hdr", incognito = "settings_incognito",
    keyboard = "settings_keyboard", keywords = "settings_tag_multiple_outline",
    koreader_file_browser = "settings_file_cabinet", koreader_menu = "settings_menu",
    koreader_navigation = "settings_book_outline",
    koreader_typesetting = "settings_file_document_outline",
    label = "settings_tag", language = "settings_translate",
    more = "settings_dots_horizontal", more_vertical = "more_vertical",
    move = "settings_cursor_move", navbar_styling = "settings_palette",
    navbar_tabs = "settings_table_row", new_folder = "settings_folder_plus_outline",
    on_hold = "settings_pause", open_menu = "settings_gesture_swipe_down",
    page_browser = "view_carousel_outline", paste = "settings_content_paste",
    plugin = "settings_power_plug", read_status = "bookmark_outline",
    reader_flash_cbz = "settings_flash",
    reader_status_bar_margins = "settings_format_horizontal_align_center",
    reader_themes = "settings_brush", reading = "settings_book_open_variant",
    refresh = "settings_refresh", rename = "settings_pencil_outline", restart = "settings_restart",
    restore_library_location = "settings_backup_restore", save = "settings_content_save",
    schedule_brightness = "settings_weather_sunny", schedule_night = "settings_weather_night",
    schedule_warmth = "settings_thermometer_lines", search = "settings_magnify",
    select = "settings_selection", send = "settings_send",
    series = "settings_book_multiple_outline",
    settings = "settings_cog", settings_about = "info", settings_accent = "settings_brush",
    settings_advanced = "settings_tools", settings_background = "settings_wallpaper",
    settings_bug = "settings_bug", settings_covers = "settings_book_cog_outline",
    settings_cpu = "settings_chip", settings_device = "tablet",
    settings_folder_name = "settings_tag_outline", settings_folders = "settings_folder_outline",
    settings_global = "settings_view_quilt", settings_home = "settings_home_variant",
    settings_home_folder = "settings_folder_home_outline", settings_launcher = "settings_dots_grid",
    settings_layout = "settings_grid_large", settings_library = "settings_bookshelf",
    settings_lockdown = "settings_lock", settings_menu_blur = "settings_blur",
    settings_navbar = "settings_dock_bottom", settings_opds = "settings_cloud_download_outline",
    settings_quick = "settings_toggle_switch", settings_ram = "settings_memory",
    settings_reader = "settings_book_open_variant", settings_scroll = "settings_pan_horizontal",
    settings_setup = "settings_clipboard_play_outline", settings_sleep = "settings_sleep",
    settings_stats = "settings_chart_line", settings_status = "settings_drag_horizontal_variant",
    settings_storage = "settings_harddisk", settings_subfolders = "settings_file_tree",
    settings_underline = "settings_format_underline", skip_forward = "skip_right",
    sort = "settings_sort_variant", sort_asc = "settings_sort_alphabetical_ascending",
    sort_desc = "settings_sort_alphabetical_descending", status = "settings_book",
    sync = "settings_sync", tbr = "settings_clock_outline",
    title = "settings_sort_alphabetical_variant", upgrade = "settings_arrow_up_circle_outline",
    view_basic = "settings_format_list_bulleted", view_list = "settings_view_list_outline",
    view_mosaic = "settings_view_grid_outline", wallpaper = "settings_wallpaper",
    widgets = "settings_widgets", wifi_off = "settings_wifi_off", wifi_on = "settings_wifi",
}

function M.iconPath(name)
    local root = name and require("common/plugin_root")
    return root and require("common/utils").resolveIcon(root .. "/icons/", name)
end

local glyph_svg
local function svg_name(glyph)
    if not glyph_svg then
        glyph_svg = {}
        local glyphs = require("common/inline_icon_map")
        for key, svg in pairs(M.SVG) do
            if glyphs[key] then glyph_svg[glyphs[key]] = svg end
        end
    end
    return glyph and glyph_svg[glyph]
end

-- Icon packs load at startup, so resolved paths are cached per glyph.
local glyph_paths = {}
function M.path(glyph)
    if not glyph then return end
    local path = glyph_paths[glyph]
    if path == nil then
        path = M.iconPath(svg_name(glyph)) or false
        glyph_paths[glyph] = path
    end
    return path or nil
end

local ICON_COLUMN_WIDTH = Screen:scaleBySize(30)
local BUTTON_ICON_GAP = Screen:scaleBySize(8)

-- One UTF-8 char followed by two spaces, e.g. "<glyph>  Label".
local function split_inline_icon(text)
    local glyph, label = text:match("^([%z\1-\127\194-\244][\128-\191]*)  (.*)$")
    if glyph then return glyph, label end
    return nil, text
end

-- Mapped "Label  <glyph>" suffix (submenu arrows).
local function split_trailing_icon(text)
    local label, glyph = text:match("^(.-)  ([\194-\244][\128-\191]*)$")
    if glyph and M.path(glyph) then return label, glyph end
    return text
end

local function svg(file, size, dim)
    return IconWidget:new{ file = file, width = size, height = size, dim = dim }
end

-- Moves a leading "<glyph>  " into an aligned icon column; mapped glyphs render as themable SVGs.
function M.alignButtonIcons(dialog)
    local button_rows = dialog and dialog.buttontable and dialog.buttontable.buttons_layout
    if type(button_rows) ~= "table" then return dialog end

    for _i, row in ipairs(button_rows) do
        for _j, button in ipairs(row) do
            local old_label = button.label_widget
            local label_container = button.label_container
            local display_text = button.text
                and (button.checked_func and button:getDisplayText() or button.text)
            local glyph, label = split_inline_icon(display_text or "")
            -- Centered plain buttons (Cancel/OK rows) keep their stock layout.
            if display_text and old_label and label_container and label_container.dimen
                    and (glyph or button.align == "left") then
                local label_text, trailing = split_trailing_icon(label)
                local face = old_label.face
                local fgcolor = old_label.fgcolor
                local bold = old_label.bold
                local dim = button.enabled == false
                local icon_size = math.min(face.size or ICON_COLUMN_WIDTH, ICON_COLUMN_WIDTH)
                local trailing_file = trailing and M.path(trailing)
                local label_width = math.max(1, label_container.dimen.w - ICON_COLUMN_WIDTH
                    - BUTTON_ICON_GAP - (trailing_file and icon_size + BUTTON_ICON_GAP or 0))
                local file = M.path(glyph)
                local icon_widget = file and svg(file, icon_size, dim)
                    or glyph and TextWidget:new{
                        text = glyph,
                        face = face,
                        fgcolor = fgcolor,
                        bold = bold,
                    } or HorizontalSpan:new{ width = 0 }
                local text_widget = TextWidget:new{
                    text = label_text,
                    lang = button.lang,
                    max_width = label_width,
                    face = face,
                    fgcolor = fgcolor,
                    bold = bold,
                }

                old_label:free()
                button.label_widget = text_widget
                local group = HorizontalGroup:new{
                    align = "center",
                    CenterContainer:new{
                        dimen = Geom:new{ w = ICON_COLUMN_WIDTH, h = label_container.dimen.h },
                        icon_widget,
                    },
                    HorizontalSpan:new{ width = BUTTON_ICON_GAP },
                    text_widget,
                }
                if trailing_file then
                    group[4] = HorizontalSpan:new{ width = BUTTON_ICON_GAP }
                    group[5] = svg(trailing_file, icon_size, dim)
                end
                label_container[1] = group
            end
        end
    end
    return dialog
end

local function has_icon_buttons(dialog)
    local rows = dialog.buttontable and dialog.buttontable.buttons_layout
    for _i, row in ipairs(type(rows) == "table" and rows or {}) do
        for _j, button in ipairs(row) do
            if button.text and svg_name((split_inline_icon(button.text))) then return true end
        end
    end
    return false
end

-- Applies alignButtonIcons to every ButtonDialog whose buttons lead with a mapped glyph.
function M.install()
    local ButtonDialog = require("ui/widget/buttondialog")
    if ButtonDialog._zen_glyph_icons then return end
    ButtonDialog._zen_glyph_icons = true
    local orig_init = ButtonDialog.init
    function ButtonDialog:init(...)
        local result = orig_init(self, ...)
        if has_icon_buttons(self) then M.alignButtonIcons(self) end
        return result
    end
end

return M
