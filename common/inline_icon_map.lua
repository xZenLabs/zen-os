-- common/inline_icon_map.lua
-- Centralized NerdFont (Symbols Only) inline glyph map.
-- Rendered via SymbolsNerdFont-Regular.ttf (registered as fallback in main.lua).
-- Codepoints verified from existing usages in context_menu.lua, collections.lua,
-- opds.lua, status_bar.lua, etc. Uses \u{} escapes throughout (same as codebase).
--
-- Usage:
--   local icons = require("common/inline_icon_map")
--   text = icons.eye .. "  " .. _("View")

return {
    -- file operations (context_menu.lua)
    delete       = "\u{F0156}",  -- mdi-delete
    rename       = "\u{F0CB6}",  -- mdi-rename-box
    move         = "\u{F01BE}",  -- mdi-folder-move
    copy         = "\u{F018F}",  -- mdi-content-copy
    cut          = "\u{F0190}",  -- mdi-content-cut
    paste        = "\u{F0192}",  -- mdi-content-paste
    save         = "\u{F0193}",  -- mdi-content-save
    select       = "\u{F0489}",  -- mdi-cursor-default-click
    new_folder   = "\u{F0B9D}",  -- mdi-folder-plus
    folder_open  = "\u{F07C}",   -- mdi-folder-open
    connect      = "\u{F0337}",  -- mdi-link-variant

    -- view modes (context_menu.lua)
    view_mosaic  = "\u{F11D9}",  -- mdi-view-module
    view_list    = "\u{F148B}",  -- mdi-view-list
    view_basic   = "\u{F0279}",  -- mdi-format-list-bulleted
    display      = "\u{F06D0}",  -- mdi-monitor
    eye          = "\u{F0208}",  -- mdi-eye
    divider      = "\u{F01D4}",  -- mdi-format-vertical-align-center

    -- sorting (context_menu.lua)
    sort         = "\u{F04BF}",  -- mdi-sort
    sort_asc     = "\u{F15D}",   -- mdi-sort-ascending
    sort_desc    = "\u{F15E}",   -- mdi-sort-descending
    clear        = "\u{F099B}",  -- mdi-close-circle

    -- favourites (context_menu.lua)
    fav_add      = "\u{F04CE}",  -- mdi-star
    fav_remove   = "\u{F04D2}",  -- mdi-star-outlined

    -- read status (context_menu.lua)
    read_status  = "\u{F00C0}",  -- bookmark
    status       = "\u{F00BA}",  -- mdi-book-open-blank-variant (unread)
    reading      = "\u{F14F7}",  -- mdi-book-open
    book_switcher = "\u{F0F58}",
    tbr          = "\u{F0150}",  -- mdi-clock (to-be-read)
    on_hold      = "\u{F03E4}",
    finished     = "\u{F012C}",  -- mdi-check-circle

    -- metadata sort keys (context_menu.lua / collections.lua)
    title        = "\u{F04BB}",  -- mdi-format-title
    filename     = "\u{F0224}",
    authors      = "\u{F0013}",  -- mdi-account
    series       = "\u{F0436}",  -- mdi-library-books
    language     = "\u{F05CA}",  -- mdi-translate
    history      = "\u{F02DA}",  -- mdi-history
    keywords     = "\u{F12F7}",  -- mdi-tag-multiple

    -- details / info (context_menu.lua / opds.lua)
    details      = "\u{F05A}",  -- mdi-information
    edit         = "\u{F090C}",  -- mdi-pencil
    label        = "\u{F04F9}",
    icon         = "\u{F02F5}",
    plugin       = "\u{F06A5}",
    action       = "\u{F140B}",
    settings       = "\u{F0493}",

    -- network / sync (opds.lua)
    search       = "\u{F0349}",  -- mdi-magnify
    sync         = "\u{F04E6}",  -- mdi-sync
    download     = "\u{F01DA}",  -- mdi-download
    add          = "\u{F067}",   -- nf-fa-plus
    filter       = "\u{F0233}",  -- mdi-filter-variant
    refresh      = "\u{F0450}",  -- mdi-refresh

    -- status bar (status_bar.lua)
    wifi_on      = "\u{ECA8}",   -- nf-md-wifi
    wifi_off     = "\u{ECA9}",   -- nf-md-wifi-off
    bluetooth_on = "\u{F293}",  -- nf-fa-bluetooth
    incognito    = "\u{F05F9}", -- mdi-incognito
    ram          = "\u{EA5A}",   -- nf-cod-chip
    disk         = "\u{F0A0}",   -- mdi-harddisk

    -- screenshot dialog
    wallpaper    = "\u{F05DA}",  -- mdi-wallpaper
    send         = "\u{F048A}",  -- mdi-send

    -- ZenOS settings root
    settings_launcher = "\u{F15FC}",
    settings_quick    = "\u{f0521}",
    settings_library  = "\u{F125F}",
    settings_home     = "\u{F02DE}",
    settings_reader   = "\u{F14F7}",
    vocabulary        = "\u{F1349}",
    settings_about    = "\u{F064E}",
    widgets           = "\u{F072C}",
    settings_global   = "\u{F484}",
    settings_status   = "\u{F12F0}",
    reader_themes     = "\u{F03D8}",
    settings_folders  = "\u{F0256}",
    settings_covers   = "\u{F168B}",  -- mdi-view-module
    settings_scroll   = "\u{F0BB8}",
    settings_layout   = "\u{F0758}",
    settings_background = "\u{F0E09}",
    settings_home_folder = "\u{F10B6}",
    settings_navbar   = "\u{F10A9}",
    navbar_tabs       = "\u{F0837}",
    navbar_styling    = "\u{F03D8}",
    settings_stats    = "\u{F012A}",
    calendar          = "\u{F073}",  -- nf-fa-calendar
    settings_opds     = "\u{F0B7D}",
    settings_sleep    = "\u{F04B2}",
    schedule_brightness = "\u{F0599}",
    schedule_night    = "\u{F0594}",  -- mdi-weather-night
    schedule_warmth   = "\u{F0510}",
    flip_lh_rh        = "\u{F0A0E}",
    settings_lockdown = "\u{F033E}",
    settings_device   = "\u{F04F7}",
    settings_setup    = "\u{F0C5A}",
    settings_bug      = "\u{F00E4}",
    settings_advanced = "\u{F1064}",

    -- book status actions (book_status.lua)
    restart      = "\u{F0709}",  -- mdi-restart
    next_book    = "\u{f0054}",   -- nf-md-arrow-right

    -- misc
    update       = "\u{F01B}",   -- nf-fa-cloud-download
    disable      = "\u{F04DB}",
    downgrade    = "\u{F0CDC}",
    upgrade      = "\u{F0CE2}",
    enable       = "\u{F040A}",
    chapter_time_format = "\u{F19B9}",
    bottom_swipe = "\u{F0740}",
    page_browser = "\u{F0570}",
    restore_library_location = "\u{F006F}",
    hide_reader_actions = "\u{F0209}",
    remove       = "\u{F0374}",
    check        = "\u{2713}",   -- plain checkmark
    arrow_left   = "\u{F0141}",  -- mdi-chevron-left
    arrow_right  = "\u{F0142}",  -- mdi-chevron-right
    go           = "\u{F124}",   -- nf-fa-location-arrow
    open_menu    = "\u{F073D}",  -- mdi-menu-open
    koreader_menu = "\u{F035C}",  -- mdi-menu
    bullet       = "\u{2022}",   -- bullet point
}
