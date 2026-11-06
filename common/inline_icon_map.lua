-- Inline glyphs from KOReader's bundled nerdfonts/symbols.ttf (Font.fallbacks).
-- Settings rows and aligned button dialogs swap mapped glyphs for SVGs (glyph_icons.SVG);
-- keep codepoints unique per SVG so that reverse lookup stays unambiguous.
--
-- Usage:
--   local icons = require("common/inline_icon_map")
--   text = icons.eye .. "  " .. _("View")

return {
    -- file operations
    delete       = "\u{E855}",
    rename       = "\u{EAEA}",
    move         = "\u{E8B5}",
    copy         = "\u{E88E}",
    cut          = "\u{E88F}",
    paste        = "\u{E891}",
    save         = "\u{E892}",
    select       = "\u{EB88}",
    new_folder   = "\u{E956}",
    folder_open  = "\u{F07C}",
    folder_up    = "\u{EE6E}",
    archive      = "\u{F19C}",
    connect      = "\u{EA36}",

    -- KOReader FileChooser item counts (parsed from item.mandatory)
    file_count   = "\u{F016}",
    folder_count = "\u{F114}",

    -- view modes
    view_mosaic  = "\u{EC6F}",
    view_list    = "\u{EC71}",
    view_basic   = "\u{E978}",
    display      = "\u{EDCE}",
    divider      = "\u{E8D3}",

    -- sorting
    sort         = "\u{EBBE}",
    sort_asc     = "\u{F15D}",
    sort_desc    = "\u{F15E}",
    clear        = "\u{E23C}",

    -- favourites
    fav_add      = "\u{EBCD}",
    fav_remove   = "\u{EBD1}",
    favorite     = "\u{2606}",

    -- read status
    read_status  = "\u{E7BF}",
    status       = "\u{E7B9}",
    reading      = "\u{E7BD}",
    book_switcher = "\u{E9D9}",
    tbr          = "\u{E84F}",
    on_hold      = "\u{EAE3}",
    finished     = "\u{E82B}",

    -- metadata sort keys
    title        = "\u{EBBA}",
    font         = "\u{F031}",
    filename     = "\u{E923}",
    authors      = "\u{E712}",
    series       = "\u{E7BA}",
    language     = "\u{ECC9}",
    history      = "\u{E9D9}",
    keywords     = "\u{EBFA}",

    -- details / actions
    details      = "\u{E9FC}",
    edit         = "\u{EAEC}",
    label        = "\u{EBF8}",
    icon         = "\u{E9F4}",
    custom_icons = "\u{E9F8}",
    plugin       = "\u{EDA3}",
    action       = "\u{EDD3}",
    more         = "\u{E8D7}",
    more_vertical = "\u{E8D8}",
    settings     = "\u{F013}",

    -- network / sync
    add          = "\u{F067}",
    search       = "\u{EA48}",
    sync         = "\u{EBE5}",
    download     = "\u{E8D9}",
    filter       = "\u{E932}",
    refresh      = "\u{EB4F}",
    skip_forward = "\u{EBAC}",

    -- status bar
    wifi_on      = "\u{ECA8}",
    wifi_off     = "\u{ECA9}",
    bluetooth_on = "\u{F293}",
    incognito    = "\u{ECF8}",

    -- screenshot dialog
    wallpaper    = "\u{ECD9}",
    send         = "\u{EB89}",

    -- ZenOS settings
    settings_launcher = "\u{E73A}",
    settings_quick    = "\u{EC20}",
    settings_library  = "\u{EA30}",
    settings_home     = "\u{E9DD}",
    settings_reader   = "\u{E7BD}",
    settings_about    = "\u{E9FC}",
    widgets           = "\u{EE2A}",
    settings_global   = "\u{EC73}",
    settings_status   = "\u{E8DB}",
    battery           = "\u{E77F}",
    reader_themes     = "\u{E7E2}",
    reader_status_bar_margins = "\u{ED1D}",
    reader_flash_cbz  = "\u{E940}",
    end_book          = "\u{E7C0}",
    settings_folders  = "\u{E955}",
    settings_folder_name = "\u{EBFB}",
    settings_covers   = "\u{E9E9}",
    settings_scroll   = "\u{EBE0}",
    settings_layout   = "\u{EE56}",
    settings_subfolders = "\u{ED44}",
    settings_underline = "\u{E986}",
    settings_background = "\u{E9E8}",
    settings_accent   = "\u{E7E2}",
    settings_menu_blur = "\u{E7B4}",
    settings_home_folder = "\u{ED9F}",
    settings_navbar   = "\u{EDF9}",
    navbar_tabs       = "\u{EF35}",
    navbar_styling    = "\u{EAD7}",
    settings_stats    = "\u{E829}",
    calendar          = "\u{F073}",
    settings_opds     = "\u{E861}",
    settings_sleep    = "\u{EBB1}",
    keyboard          = "\u{EA0B}",
    schedule_brightness = "\u{EC98}",
    schedule_night    = "\u{EC93}",
    schedule_warmth   = "\u{EC0F}",
    flip_lh_rh        = "\u{E946}",
    settings_lockdown = "\u{EA3D}",
    settings_device   = "\u{EBF6}",
    settings_storage  = "\u{E9C9}",
    settings_ram      = "\u{EA5A}",
    settings_cpu      = "\u{E266}",
    settings_setup    = "\u{E84C}",
    settings_bug      = "\u{E7E3}",
    settings_advanced = "\u{E20F}",

    -- misc
    restart      = "\u{EE07}",
    upgrade      = "\u{E75F}",
    enable       = "\u{EB09}",
    chapter_time_format = "\u{EAE9}",
    bottom_swipe = "\u{EE3E}",
    page_browser = "\u{EC6B}",
    restore_library_location = "\u{E76E}",
    hide_reader_actions = "\u{E908}",
    check        = "\u{2713}",
    arrow_left   = "\u{E840}",
    arrow_right  = "\u{E841}",
    arrow_up     = "\u{F062}",
    go           = "\u{F124}",
    open_menu    = "\u{EE3B}",
    double_tap   = "\u{EE3A}",
    koreader_menu = "\u{EA5B}",
    koreader_file_browser = "\u{E954}",
    koreader_navigation = "\u{E7BE}",
    koreader_typesetting = "\u{E918}",
}
