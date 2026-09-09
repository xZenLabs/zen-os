
-- ZenOS: Register all plugin icons into KOReader's icon cache at startup.
-- Copies SVGs to the user icons dir so they resolve on cold starts too.

local utils = require("common/utils")

local _plugin_root = require("common/plugin_root")

if _plugin_root then
    utils.registerPluginIcons(_plugin_root .. "/icons/", {
        -- App / settings UI
        ["zen_settings"]        = "zen_ui.svg",
        ["quicksettings"]       = "quicksettings.svg",
        ["zenos"]               = "zen_ui.svg",
        ["zenos_light"]         = "zen_ui_light.svg",
        ["zenos_update"]        = "zen_ui_update.svg",
        ["zen_ui"]              = "zen_ui.svg",
        ["zen_ui_light"]        = "zen_ui_light.svg",
        ["zen_ui_update"]       = "zen_ui_update.svg",
        ["library"]             = "library.svg",
        ["app_launcher"]        = "app_launcher.svg",
        ["lightning"]           = "lightning.svg",
        ["folder"]              = "folder.svg",
        ["folder_open"]         = "folder_open.svg",
        -- Navbar tab icons (needed so the menu-bar shortcut icon, which tracks
        -- the navbar's default tab, can resolve any of them by name).
        ["home"]                = "home.svg",
        ["tab_folder"]          = "tab_folder.svg",
        ["tab_manga"]           = "tab_manga.svg",
        ["tab_news"]            = "tab_news.svg",
        ["tab_history"]         = "tab_history.svg",
        ["tab_collections"]     = "tab_collections.svg",
        ["tab_authors"]         = "tab_authors.svg",
        ["tab_series"]          = "tab_series.svg",
        ["tab_tags"]            = "tab_tags.svg",
        ["tab_translate"]       = "tab_translate.svg",
        ["tab_to_be_read"]      = "tab_to_be_read.svg",
        -- Highlight / lookup popup (shared by highlight_menu + dict_quick_lookup)
        ["lookup.highlight"]    = "lookup_highlight.svg",
        ["lookup.extend"]       = "lookup_extend.svg",
        ["lookup.ai"]           = "lookup_ai.svg",
        ["lookup.vocab"]        = "lookup_vocab.svg",
        ["lookup.vocab_remove"] = "lookup_vocab_remove.svg",
        ["lookup.dictionary"]   = "lookup_dictionary.svg",
        ["lookup.search"]       = "lookup_search.svg",
        ["lookup.translate"]    = "lookup_translate.svg",
        ["lookup.wikipedia"]    = "lookup_wikipedia.svg",
    }, true)
end
