local logger = require("common/zen_logger").new("collections")
local icons  = require("common/inline_icon_map")
local submenu_arrow = icons.arrow_right
local Cover  = require("common/cover_utils")
local library_font = require("modules/filebrowser/patches/library_font")
local Background = require("common/ui/background")
local SharedState = require("common/shared_state")

logger.dbg("module loaded")

local function apply_collections()
    logger.dbg("apply_collections() called")

    local FileManagerCollection = require("apps/filemanager/filemanagercollection")
    local Menu = require("ui/widget/menu")

    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
    if not zen_plugin or type(zen_plugin.config) ~= "table" then
        return
    end

    local function is_enabled()
        local features = zen_plugin.config and zen_plugin.config.features
        return type(features) == "table" and features.collections == true
    end

    local function is_tbr_collection(item)
        local coll_name = type(item) == "table" and item.name or item
        return coll_name == require("common/tbr_index").collectionName()
    end

    local orig_removeCollection = FileManagerCollection.removeCollection
    function FileManagerCollection:removeCollection(item, ...)
        if is_enabled() and is_tbr_collection(item) then return end
        return orig_removeCollection(self, item, ...)
    end

    local function get_shared(key)
        return SharedState.get(zen_plugin, key)
    end

    local function should_match_statusbar_height()
        local features = zen_plugin.config and zen_plugin.config.features
        if type(features) ~= "table" or features.status_bar ~= true then
            return false
        end
        local sb_cfg = type(zen_plugin.config.status_bar) == "table"
            and zen_plugin.config.status_bar or {}
        local hide = sb_cfg.hide_browser_bar
        return hide == true or hide == nil
    end

    local VALID_DISPLAY_MODES = {
        mosaic_image = true,
        list_image_meta = true,
        list_image_filename = true,
    }

    local function get_coll_display_mode(coll_name)
        if coll_name then
            local ReadCollection = require("readcollection")
            local settings = ReadCollection.coll_settings[coll_name]
            local mode = settings and settings.zen_ui_display_mode
            if VALID_DISPLAY_MODES[mode] then return mode end
        end
        local gv = type(zen_plugin.config.group_view) == "table" and zen_plugin.config.group_view or {}
        local dm = type(gv.display_mode) == "table" and gv.display_mode or {}
        return dm.collections
    end

    local function set_coll_display_mode(mode, coll_name)
        if not VALID_DISPLAY_MODES[mode] then return end
        if coll_name then
            local ReadCollection = require("readcollection")
            local settings = ReadCollection.coll_settings[coll_name]
            if not settings then return end
            settings.zen_ui_display_mode = mode
            ReadCollection:write({ [coll_name] = true })
            return
        end
        if type(zen_plugin.config.group_view) ~= "table" then zen_plugin.config.group_view = {} end
        local gv = zen_plugin.config.group_view
        if type(gv.display_mode) ~= "table" then gv.display_mode = {} end
        gv.display_mode.collections = mode
        if type(zen_plugin.saveConfig) == "function" then zen_plugin:saveConfig() end
    end

    local function apply_button_group_font(button_rows, nominal_size)
        if type(button_rows) ~= "table" then return button_rows end
        local size = library_font.scaleValue(nominal_size or 20)
        for _i, row in ipairs(button_rows) do
            if type(row) == "table" then
                for _j, btn in ipairs(row) do
                    if type(btn) == "table" and type(btn.text) == "string" then
                        local face = btn.font_face or btn.text_font_face or library_font.getFontName()
                        local fsize = btn.font_size or btn.text_font_size or size
                        btn.font_face = face
                        btn.font_size = fsize
                        -- Keep legacy aliases for compatibility with non-ButtonTable paths.
                        btn.text_font_face = face
                        btn.text_font_size = fsize
                    end
                end
            end
        end
        return button_rows
    end

    ---------------------------------------------------------------------------
    -- Display mode setup
    ---------------------------------------------------------------------------
    local _coll_display_mode_override = nil
    local get_collection_files_in_cover_order

    local function setup_display_mode(menu)
        local BookInfoManager = require("bookinfomanager")
        local display_mode = _coll_display_mode_override
            or get_coll_display_mode()
        menu._zen_coll_list = true
        menu._zen_get_collection_files = get_collection_files_in_cover_order
        menu._zen_get_collection_title = function(name)
            local ReadCollection = require("readcollection")
            if name == ReadCollection.default_collection_name then
                return require("gettext")("Favorites")
            end
            return name
        end

        if not display_mode then
            display_mode = "mosaic"
        end

        local ok_cm, CoverMenu = pcall(require, "covermenu")
        if not ok_cm then return false end

        local display_mode_type = display_mode:gsub("_.*", "")

        menu.updateItems  = CoverMenu.updateItems
        menu.onCloseWidget = CoverMenu.onCloseWidget

        menu.nb_cols_portrait  = BookInfoManager:getSetting("nb_cols_portrait")  or 3
        menu.nb_rows_portrait  = BookInfoManager:getSetting("nb_rows_portrait")  or 3
        menu.nb_cols_landscape = BookInfoManager:getSetting("nb_cols_landscape") or 4
        menu.nb_rows_landscape = BookInfoManager:getSetting("nb_rows_landscape") or 2
        menu.files_per_page    = Cover.getFilesPerPage()
        menu.display_mode_type = display_mode_type

        if display_mode_type == "mosaic" then
            local ok_mm, MosaicMenu = pcall(require, "mosaicmenu")
            if not ok_mm then return false end
            menu._recalculateDimen    = MosaicMenu._recalculateDimen
            menu._updateItemsBuildUI  = MosaicMenu._updateItemsBuildUI
            menu._do_cover_images     = display_mode ~= "mosaic_text"
            menu._do_center_partial_rows = false
            menu._do_hint_opened      = false
        elseif display_mode_type == "list" then
            local ok_lm, ListMenu = pcall(require, "listmenu")
            if not ok_lm then return false end
            menu._recalculateDimen    = ListMenu._recalculateDimen
            menu._updateItemsBuildUI  = ListMenu._updateItemsBuildUI
            menu._do_cover_images     = display_mode ~= "list_only_meta"
            menu._do_filename_only    = display_mode == "list_image_filename"
        end

        if not menu.getBookInfo then
            menu.getBookInfo = function() return {} end
        end
        if not menu.resetBookInfoCache then
            menu.resetBookInfoCache = function() end
        end

        menu._coverbrowser_overridden = true

        return display_mode_type
    end

    get_collection_files_in_cover_order = function(coll_name)
        local ReadCollection = require("readcollection")
        local coll = ReadCollection.coll[coll_name]
        if type(coll) ~= "table" then return {} end

        local sorted = {}
        for _k, entry in pairs(coll) do
            if type(entry) == "table" and type(entry.file) == "string" and entry.file ~= "" then
                table.insert(sorted, {
                    file = entry.file,
                    text = entry.text,
                    order = entry.order,
                    attr = entry.attr,
                })
            end
        end

        local settings = ReadCollection.coll_settings[coll_name] or {}
        local collate_id = settings.collate
        local BookList = collate_id and require("ui/widget/booklist")
        local collate = BookList and BookList.collates[collate_id]
        local sorting_func

        if collate then
            local FileManager = require("apps/filemanager/filemanager")
            local ui = FileManager.instance
            if not ui then
                ui = require("apps/reader/readerui").instance
            end
            if collate.item_func then
                for _i, item in ipairs(sorted) do
                    collate.item_func(item, ui)
                end
            end
            sorting_func = collate.init_sort_func()
            if settings.collate_reverse then
                local unreversed = sorting_func
                sorting_func = function(a, b) return unreversed(b, a) end
            end
        else
            sorting_func = function(a, b)
                local a_order = tonumber(a.order) or 0
                local b_order = tonumber(b.order) or 0
                if a_order == b_order then
                    return (a.file or "") < (b.file or "")
                end
                return a_order < b_order
            end
        end
        table.sort(sorted, sorting_func)

        local files = {}
        for _i, entry in ipairs(sorted) do
            table.insert(files, entry.file)
        end
        return files
    end

    local function get_visible_files_from_menu(menu)
        if not (menu and type(menu.item_table) == "table") then return nil end

        local files = {}
        for _i, entry in ipairs(menu.item_table) do
            if type(entry) == "table" and not entry.is_go_up then
                local fpath = entry.file or entry.filepath or entry.path
                if type(fpath) == "string" and fpath ~= "" then
                    table.insert(files, fpath)
                end
            end
        end

        return #files > 0 and files or nil
    end

    ---------------------------------------------------------------------------
    -- Shared per-collection sort submenu
    ---------------------------------------------------------------------------
    local function show_coll_sort_submenu(coll_name, close_parent, on_sort_applied)
        local ReadCollection = require("readcollection")
        local ButtonDialog   = require("ui/widget/buttondialog")
        local UIManager_ss   = require("ui/uimanager")
        local _g             = require("gettext")

        close_parent()

        local sort_dialog
        local sort_buttons  = {}
        local coll_settings = ReadCollection.coll_settings[coll_name]
        local current       = coll_settings and coll_settings.collate

        local SORT_OPTIONS = {
            { key = "title",    text = "\u{F04BB}  " .. _g("Title")         },
            { key = "title_natural", text = "\u{F04BB}  " .. _g("Title natural") },
            { key = "strcoll",  text = icons.filename .. "  " .. _g("Filename") },
            { key = "authors",  text = "\u{F0013}  " .. _g("Authors")       },
            { key = "series",   text = "\u{F0436}  " .. _g("Series")        },
            { key = "access",   text = "\u{F02DA}  " .. _g("Recently read") },
            { key = "keywords", text = "\u{F12F7}  " .. _g("Keywords")      },
        }

        for _i, opt in ipairs(SORT_OPTIONS) do
            local is_active = current == opt.key
            table.insert(sort_buttons, {{
                text     = opt.text .. (is_active and "  \u{2713}" or ""),
                align    = "left",
                enabled  = not is_active,
                callback = function()
                    UIManager_ss:close(sort_dialog)
                    if coll_settings then
                        coll_settings.collate = opt.key
                        coll_settings.collate_reverse = nil
                        ReadCollection:write({ [coll_name] = true })
                    end
                    if on_sort_applied then on_sort_applied() end
                end,
            }})
        end
        table.insert(sort_buttons, {{
            text     = "\u{F04BF}  " .. _g("Order") .. "  " .. submenu_arrow,
            align    = "left",
            enabled  = current ~= nil,
            callback = function()
                UIManager_ss:close(sort_dialog)
                local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
                local fm = ok_fm and FM and FM.instance
                if not fm then return end
                local cur_rev = coll_settings and coll_settings.collate_reverse or false
                fm.file_chooser:showSortOrderDialog({
                    current_reverse = cur_rev,
                    on_select       = function(reverse)
                        coll_settings.collate_reverse = reverse or nil
                        ReadCollection:write({ [coll_name] = true })
                        if on_sort_applied then on_sort_applied() end
                    end,
                })
            end,
        }})
        if current then
            table.insert(sort_buttons, {})
            table.insert(sort_buttons, {{
                text = "\u{F099B}  " .. _g("Clear"),
                align = "left",
                callback = function()
                    UIManager_ss:close(sort_dialog)
                    local ordered = {}
                    for _i, file in ipairs(get_collection_files_in_cover_order(coll_name)) do
                        ordered[#ordered + 1] = { file = file }
                    end
                    ReadCollection:updateCollectionOrder(coll_name, ordered)
                    coll_settings.collate = nil
                    coll_settings.collate_reverse = nil
                    ReadCollection:write({ [coll_name] = true })
                    if on_sort_applied then on_sort_applied() end
                end,
            }})
        end
        sort_dialog = ButtonDialog:new{
            title       = _g("Sort collection by"),
            title_align = "center",
            buttons     = apply_button_group_font(sort_buttons),
        }
        UIManager_ss:show(sort_dialog)
    end

    ---------------------------------------------------------------------------
    -- Context menus
    ---------------------------------------------------------------------------
    local function show_coll_item_menu(fm_coll, item, coll_list)
        if not item then return false end
        local ReadCollection = require("readcollection")
        local ButtonDialog   = require("ui/widget/buttondialog")
        local UIManager_cm   = require("ui/uimanager")
        local _              = require("gettext")

        local coll_name    = item.name
        local is_favorites = coll_name == ReadCollection.default_collection_name
        local is_tbr       = is_tbr_collection(coll_name)
        local display_name = is_favorites and _("Favorites") or coll_name
        local files        = get_collection_files_in_cover_order(coll_name)
        local book_count   = #files

        local button_dialog
        local prepend_buttons = {}
        local extra_buttons = {}
        if not is_favorites then
            table.insert(prepend_buttons, {{
                text     = icons.rename .. "  " .. _("Rename"),
                align    = "left",
                callback = function()
                    local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
                    local fm = ok_fm and FM and FM.instance
                    if fm then UIManager_cm:close(fm.file_chooser.file_dialog) end
                    if button_dialog then UIManager_cm:close(button_dialog) end
                    fm_coll:renameCollection(item)
                end,
            }})
        end
        table.insert(extra_buttons, {{
            text     = "\u{F0337}  " .. _("Connect folders"),
            align    = "left",
            callback = function()
                local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
                local fm = ok_fm and FM and FM.instance
                if fm then UIManager_cm:close(fm.file_chooser.file_dialog) end
                if button_dialog then UIManager_cm:close(button_dialog) end
                fm_coll:showCollFolderList(item)
            end,
        }})
        if not is_favorites and not is_tbr then
            table.insert(extra_buttons, {{
                text     = icons.delete .. "  " .. _("Delete collection"),
                align    = "left",
                callback = function()
                    local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
                    local fm = ok_fm and FM and FM.instance
                    if fm then UIManager_cm:close(fm.file_chooser.file_dialog) end
                    if button_dialog then UIManager_cm:close(button_dialog) end
                    fm_coll:removeCollection(item)
                end,
            }})
        end

        local function reopen_collection_list()
            if fm_coll.coll_list then
                UIManager_cm:close(fm_coll.coll_list)
                fm_coll.coll_list = nil
            end
            fm_coll:onShowCollList()
        end

        local function showDisplaySubmenu()
            local cur_mode = get_coll_display_mode(coll_name)
            local view_dialog
            local function viewBtn(label, icon, mode)
                local active = cur_mode == mode
                return {{
                    text     = icon .. "  " .. label .. (active and "  \u{2713}" or ""),
                    align    = "left",
                    enabled  = not active,
                    callback = function()
                        UIManager_cm:close(view_dialog)
                        set_coll_display_mode(mode, coll_name)
                        reopen_collection_list()
                    end,
                }}
            end
            view_dialog = ButtonDialog:new{
                title       = _("Display mode"),
                title_align = "center",
                buttons     = apply_button_group_font({
                    viewBtn(_("Mosaic"),          "\u{F00A}", "mosaic_image"),
                    viewBtn(_("List (detailed)"), "\u{F03A}", "list_image_meta"),
                    viewBtn(_("List (basic)"),    "\u{F0CA}", "list_image_filename"),
                }),
            }
            UIManager_cm:show(view_dialog)
        end

        local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
        local fm = ok_fm and FM and FM.instance
        if fm and fm.file_chooser and fm.file_chooser.showFileDialog then
            fm.file_chooser:showFileDialog({
                _zen_group_files     = files,
                _zen_group_name      = display_name,
                _zen_group_subtitle  = book_count == 1 and _("1 book")
                                      or (tostring(book_count) .. " " .. _("books")),
                _zen_sort_cb         = function()
                    show_coll_sort_submenu(coll_name, function() end, reopen_collection_list)
                end,
                _zen_display_cb      = showDisplaySubmenu,
                _zen_prepend_buttons = prepend_buttons,
                _zen_extra_buttons   = extra_buttons,
            })
        else
            local buttons = {}
            for _i, row in ipairs(prepend_buttons) do table.insert(buttons, row) end
            table.insert(buttons, {{
                text     = "\u{F06D0}  " .. _("Display") .. "  " .. submenu_arrow,
                align    = "left",
                callback = function()
                    UIManager_cm:close(button_dialog)
                    showDisplaySubmenu()
                end,
            }})
            table.insert(buttons, {{
                text     = "\u{F04BF}  " .. _("Sort") .. "  " .. submenu_arrow,
                align    = "left",
                callback = function()
                    show_coll_sort_submenu(coll_name,
                        function() UIManager_cm:close(button_dialog) end,
                        reopen_collection_list)
                end,
            }})
            for _i, row in ipairs(extra_buttons) do table.insert(buttons, row) end
            button_dialog = ButtonDialog:new{ buttons = apply_button_group_font(buttons) }
            UIManager_cm:show(button_dialog)
        end
        return true
    end

    local function show_named_coll_blank_menu(fm_coll, menu, raw_coll_name, display_name, fav_navbar)
        local ft = zen_plugin and zen_plugin.config and zen_plugin.config.features
        local lc = zen_plugin and zen_plugin.config and zen_plugin.config.lockdown
        if type(ft) == "table" and ft.lockdown_mode == true
                and type(lc) == "table" and lc.disable_context_menu == true then
            return
        end

        local ButtonDialog   = require("ui/widget/buttondialog")
        local UIManager_nb   = require("ui/uimanager")
        local _              = require("gettext")

        local files = get_visible_files_from_menu(menu)
            or get_collection_files_in_cover_order(raw_coll_name)
        local book_count = #files

        local function reopen_collection()
            if menu then UIManager_nb:close(menu) end
            if fav_navbar then
                fm_coll:onShowColl(nil)
            else
                fm_coll:onShowColl(raw_coll_name)
            end
        end

        local function showDisplaySubmenu()
            local cur_mode = get_coll_display_mode(raw_coll_name)
            local function apply_mode(mode)
                set_coll_display_mode(mode, raw_coll_name)
            end
            local view_dialog
            local function viewBtn(label, icon, mode)
                local active = cur_mode == mode
                return {{
                    text     = icon .. "  " .. label .. (active and "  \u{2713}" or ""),
                    align    = "left",
                    enabled  = not active,
                    callback = function()
                        UIManager_nb:close(view_dialog)
                        apply_mode(mode)
                        reopen_collection()
                    end,
                }}
            end
            view_dialog = ButtonDialog:new{
                title       = _("Display mode"),
                title_align = "center",
                buttons     = apply_button_group_font({
                    viewBtn(_("Mosaic"),          "\u{F00A}", "mosaic_image"),
                    viewBtn(_("List (detailed)"), "\u{F03A}", "list_image_meta"),
                    viewBtn(_("List (basic)"),    "\u{F0CA}", "list_image_filename"),
                }),
            }
            UIManager_nb:show(view_dialog)
        end

        local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
        local fm = ok_fm and FM and FM.instance
        if fm and fm.file_chooser and fm.file_chooser.showFileDialog then
            fm.file_chooser:showFileDialog({
                _zen_group_files       = files,
                _zen_group_name        = display_name,
                _zen_group_subtitle    = book_count == 1 and _("1 book")
                                         or (tostring(book_count) .. " " .. _("books")),
                _zen_is_folder_view    = true,
                _zen_sort_cb           = function()
                    show_coll_sort_submenu(raw_coll_name, function() end, reopen_collection)
                end,
                _zen_display_cb        = showDisplaySubmenu,
                _zen_filter_refresh_cb = function()
                    reopen_collection()
                end,
            })
        else
            local button_dialog
            local buttons = {
                {{
                    text     = "\u{F04BF}  " .. _("Sort") .. "  " .. submenu_arrow,
                    align    = "left",
                    callback = function()
                        show_coll_sort_submenu(raw_coll_name,
                            function() UIManager_nb:close(button_dialog) end,
                            reopen_collection)
                    end,
                }},
                {{
                    text     = "\u{F06D0}  " .. _("Display") .. "  " .. submenu_arrow,
                    align    = "left",
                    callback = function()
                        UIManager_nb:close(button_dialog)
                        showDisplaySubmenu()
                    end,
                }},
            }
            button_dialog = ButtonDialog:new{ buttons = apply_button_group_font(buttons) }
            UIManager_nb:show(button_dialog)
        end
        return true
    end

    local function show_coll_blank_menu(fm_coll)
        local ft = zen_plugin and zen_plugin.config and zen_plugin.config.features
        local lc = zen_plugin and zen_plugin.config and zen_plugin.config.lockdown
        if type(ft) == "table" and ft.lockdown_mode == true
                and type(lc) == "table" and lc.disable_context_menu == true then
            return
        end
        local ButtonDialog = require("ui/widget/buttondialog")
        local UIManager_bm = require("ui/uimanager")
        local _            = require("gettext")

        local button_dialog

        local function showDisplaySubmenu()
            UIManager_bm:close(button_dialog)
            local cur_mode = get_coll_display_mode()
            local function apply_mode(mode)
                set_coll_display_mode(mode)
            end
            local view_dialog
            local function viewBtn(label, icon, mode)
                local active = cur_mode == mode
                return {{
                    text     = icon .. "  " .. label .. (active and "  \u{2713}" or ""),
                    align    = "left",
                    enabled  = not active,
                    callback = function()
                        UIManager_bm:close(view_dialog)
                        apply_mode(mode)
                        if fm_coll.coll_list then
                            UIManager_bm:close(fm_coll.coll_list)
                            fm_coll.coll_list = nil
                            fm_coll:onShowCollList()
                        end
                    end,
                }}
            end
            view_dialog = ButtonDialog:new{
                title       = _("Display mode"),
                title_align = "center",
                buttons     = apply_button_group_font({
                    viewBtn(_("Mosaic"),          "\u{F00A}", "mosaic_image"),
                    viewBtn(_("List (detailed)"), "\u{F03A}", "list_image_meta"),
                    viewBtn(_("List (basic)"),    "\u{F0CA}", "list_image_filename"),
                }),
            }
            UIManager_bm:show(view_dialog)
        end

        local buttons = {
            {{
                text     = "\u{F0B9D}  " .. _("New collection"),
                align    = "left",
                callback = function()
                    UIManager_bm:close(button_dialog)
                    fm_coll:addCollection()
                end,
            }},
            {{
                text     = "\u{F06D0}  " .. _("Display") .. "  " .. submenu_arrow,
                align    = "left",
                callback = showDisplaySubmenu,
            }},
            {{
                text     = "\u{F04BF}  " .. _("Arrange"),
                align    = "left",
                callback = function()
                    UIManager_bm:close(button_dialog)
                    fm_coll:sortCollections()
                end,
            }},
            {{
                text     = "\u{F0349}  " .. _("Search"),
                align    = "left",
                callback = function()
                    UIManager_bm:close(button_dialog)
                    fm_coll:onShowCollectionsSearchDialog()
                end,
            }},
        }
        button_dialog = ButtonDialog:new{
            buttons = apply_button_group_font(buttons),
        }
        UIManager_bm:show(button_dialog)
        return true
    end

    SharedState.register(zen_plugin, {
        collections = {
            showContextMenu = function(kind)
                local FileManager = require("apps/filemanager/filemanager")
                local fm_coll = FileManager.instance and FileManager.instance.collections
                if not fm_coll then return false end
                if kind == "collections" then
                    return show_coll_blank_menu(fm_coll) == true
                end
                if kind == "favorites" then
                    local ReadCollection = require("readcollection")
                    return show_named_coll_blank_menu(
                        fm_coll, nil, ReadCollection.default_collection_name,
                        require("gettext")("Favorites"), true) == true
                end
                return false
            end,
            refreshTBRCollection = function()
                local FileManager = require("apps/filemanager/filemanager")
                local fm_coll = FileManager.instance and FileManager.instance.collections
                local menu = fm_coll and fm_coll.booklist_menu
                if not (menu and is_tbr_collection(menu.path)) then return false end
                fm_coll:setCollate()
                fm_coll:updateItemTable()
                return true
            end,
        },
    })

    ---------------------------------------------------------------------------
    -- Flags set during show calls
    ---------------------------------------------------------------------------
    local _patching_coll_list  = false
    local _patching_named_coll = false

    ---------------------------------------------------------------------------
    -- Menu:init hook
    ---------------------------------------------------------------------------
    local orig_menu_init = Menu.init
    function Menu:init()
        local is_coll_menu = _patching_coll_list or _patching_named_coll
        local should_patch_titlebar = is_enabled() and should_match_statusbar_height()
            and (self.name == "collections" or is_coll_menu)
        if should_patch_titlebar then
            local TitleBar    = require("ui/widget/titlebar")
            local orig_tb_new = TitleBar.new
            TitleBar.new = function(cls, t)
                if type(t) == "table" then
                    t.subtitle                 = nil
                    t.subtitle_fullwidth       = nil
                    t.left_icon                = nil
                    t.left_icon_tap_callback   = nil
                    t.left_icon_hold_callback  = nil
                    t.right_icon               = nil
                    t.right_icon_tap_callback  = nil
                    t.right_icon_hold_callback = nil
                    t.close_callback           = nil
                    t.title_tap_callback       = nil
                    t.title_hold_callback      = nil
                    t.bottom_v_padding         = 0
                    t.title                    = " "
                end
                return orig_tb_new(cls, t)
            end
            orig_menu_init(self)
            TitleBar.new = orig_tb_new
        else
            orig_menu_init(self)
        end

        if is_enabled() and is_coll_menu then
            setup_display_mode(self)
        end
    end

    ---------------------------------------------------------------------------
    -- Shared: icon removal helper
    ---------------------------------------------------------------------------
    local function remove_from_overlap(group, widget)
        if not widget then return end
        for i = #group, 1, -1 do
            if rawequal(group[i], widget) then
                table.remove(group, i)
                return
            end
        end
    end

    ---------------------------------------------------------------------------
    -- clean_nav (unchanged)
    ---------------------------------------------------------------------------
    local function clean_nav(menu, collection_name, raw_coll_name, fm_coll)
        if not menu then return end
        Background.applyToMenu(menu)
        if fm_coll then
            menu._zen_library_bg_reopen = function()
                fm_coll:onShowColl(raw_coll_name)
                return fm_coll.booklist_menu ~= nil
            end
        end

        local UIManager_mod = require("ui/uimanager")

        local orig_onMenuHold = menu.onMenuHold
        menu.onMenuHold = function(self_menu, item, pos)
            local ft = zen_plugin and zen_plugin.config and zen_plugin.config.features
            local lc = zen_plugin and zen_plugin.config and zen_plugin.config.lockdown
            if type(ft) == "table" and ft.lockdown_mode == true
                    and type(lc) == "table" and lc.disable_context_menu == true then
                return true
            end
            local f = item and (item.file or item.path)
            if not f then
                if orig_onMenuHold then return orig_onMenuHold(self_menu, item, pos) end
                return
            end
            local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
            local fm = ok_fm and FM and FM.instance
            if fm and fm.file_chooser and fm.file_chooser.showFileDialog then
                fm.file_chooser:showFileDialog({
                    path     = f,
                    is_file  = true,
                    is_go_up = false,
                    _zen_collection_name    = raw_coll_name,
                    _zen_collection_refresh = function()
                        pcall(UIManager_mod.close, UIManager_mod, menu)
                        pcall(fm_coll.onShowColl, fm_coll, raw_coll_name)
                    end,
                })
                return true
            end
            if orig_onMenuHold then return orig_onMenuHold(self_menu, item, pos) end
        end

        if fm_coll then
            local Device         = require("device")
            if Device:isTouchDevice() then
                local GestureRange_g = require("ui/gesturerange")
                local Geom_g         = require("ui/geometry")
                if not menu.ges_events then menu.ges_events = {} end
                menu.ges_events.ZenNamedCollBlankHold = {
                    GestureRange_g:new{
                        ges   = "hold",
                        range = Geom_g:new{
                            x = 0, y = 0,
                            w = Device.screen:getWidth(),
                            h = Device.screen:getHeight(),
                        },
                    },
                }
                menu.onZenNamedCollBlankHold = function(self_arg, arg, ges)
                    if ges and ges.pos and menu.item_group then
                        for _i, iw in ipairs(menu.item_group) do
                            if iw.dimen and iw.dimen:contains(ges.pos) then
                                return false
                            end
                        end
                    end
                    return show_named_coll_blank_menu(fm_coll, menu, raw_coll_name, collection_name)
                end
            end
        end

        menu._do_center_partial_rows = false
        menu:updateItems(1, true)

        local arrow = menu.page_return_arrow
        if arrow then
            local Geom = require("ui/geometry")
            arrow:hide()
            arrow.show     = function() end
            arrow.showHide = function() end
            arrow.dimen    = Geom:new{ w = 0, h = 0 }
        end

        local tb = menu.title_bar
        if not tb then return end

        local createStatusRowCustomBack = get_shared("createStatusRowCustomBack")

        if createStatusRowCustomBack and tb.title_group and #tb.title_group >= 2 then
            local back_callback = menu.onReturn and function() menu.onReturn() end
                               or function() end

            local status_row = createStatusRowCustomBack(back_callback, collection_name)
            tb.title_group[2] = status_row
            tb.title_group:resetLayout()

            remove_from_overlap(tb, tb.left_button)
            remove_from_overlap(tb, tb.right_button)
            tb.has_left_icon  = false
            tb.has_right_icon = false

            local repaintTitleBar = get_shared("repaintTitleBar")
            menu._zen_status_refresh = function()
                if tb.title_group and #tb.title_group >= 2 then
                    tb.title_group[2] = createStatusRowCustomBack(back_callback, collection_name)
                    tb.title_group:resetLayout()
                    if repaintTitleBar then repaintTitleBar(tb) end
                end
            end
            UIManager_mod:setDirty(menu, "ui", tb.dimen)
        else
            remove_from_overlap(tb, tb.left_button)
            remove_from_overlap(tb, tb.right_button)
            tb.has_left_icon  = false
            tb.has_right_icon = false
        end
    end

    ---------------------------------------------------------------------------
    -- clean_nav_list (unchanged)
    ---------------------------------------------------------------------------
    local function clean_nav_list(menu, fm_coll)
        if not menu then return end
        Background.applyToMenu(menu)
        if fm_coll then
            menu._zen_library_bg_reopen = function()
                fm_coll:onShowCollList()
                return fm_coll.coll_list ~= nil
            end
        end

        local UIManager_mod = require("ui/uimanager")
        local Device        = require("device")

        local ft = zen_plugin and zen_plugin.config and zen_plugin.config.features
        local lc = zen_plugin and zen_plugin.config and zen_plugin.config.lockdown
        if type(ft) == "table" and ft.lockdown_mode == true
                and type(lc) == "table" and lc.disable_context_menu == true then
            menu.onMenuHold = function() return true end
        else
            menu.onMenuHold = function(menu_self, item)
                return show_coll_item_menu(fm_coll, item, menu)
            end
        end

        if Device:isTouchDevice() then
            local GestureRange_g = require("ui/gesturerange")
            local Geom_g         = require("ui/geometry")
            if not menu.ges_events then
                menu.ges_events = {}
            end
            menu.ges_events.ZenCollBlankHold = {
                GestureRange_g:new{
                    ges   = "hold",
                    range = Geom_g:new{
                        x = 0, y = 0,
                        w = Device.screen:getWidth(),
                        h = Device.screen:getHeight(),
                    },
                },
            }
            menu.onZenCollBlankHold = function(self_arg, arg, ges)
                if ges and ges.pos and menu.item_group then
                    for _i, iw in ipairs(menu.item_group) do
                        if iw.dimen and iw.dimen:contains(ges.pos) then
                            return false
                        end
                    end
                end
                return show_coll_blank_menu(fm_coll)
            end
        end

        local tb = menu.title_bar
        if not tb then return end

        local createStatusRow = get_shared("createStatusRow")

        if createStatusRow and tb.title_group and #tb.title_group >= 2 then
            local FileManager = require("apps/filemanager/filemanager")
            local status_row = createStatusRow(nil, FileManager.instance)
            tb.title_group[2] = status_row
            tb.title_group:resetLayout()

            remove_from_overlap(tb, tb.left_button)
            remove_from_overlap(tb, tb.right_button)
            tb.has_left_icon  = false
            tb.has_right_icon = false

            local repaintTitleBar = get_shared("repaintTitleBar")
            menu._zen_status_refresh = function()
                if tb.title_group and #tb.title_group >= 2 then
                    tb.title_group[2] = createStatusRow(nil, FileManager.instance)
                    tb.title_group:resetLayout()
                    if repaintTitleBar then repaintTitleBar(tb) end
                end
            end
            UIManager_mod:setDirty(menu, "ui", tb.dimen)
        else
            remove_from_overlap(tb, tb.left_button)
            remove_from_overlap(tb, tb.right_button)
            tb.has_left_icon  = false
            tb.has_right_icon = false
        end
    end

    ---------------------------------------------------------------------------
    -- Hook onShowColl
    ---------------------------------------------------------------------------
    local orig_onShowColl = FileManagerCollection.onShowColl
    function FileManagerCollection:onShowColl(collection_name)
        local ok, ReadCollection = pcall(require, "readcollection")
        local resolved_name = collection_name or (ok and ReadCollection.default_collection_name)
        local is_favorites = not ok
            or resolved_name == nil
            or (ok and resolved_name == ReadCollection.default_collection_name)

        if is_enabled() then
            _coll_display_mode_override = get_coll_display_mode(resolved_name)
            _patching_named_coll = true
        end
        orig_onShowColl(self, collection_name)
        _patching_named_coll = false
        _coll_display_mode_override = nil

        if not is_enabled() then return end

        if is_favorites and collection_name == nil then
            local menu = self.booklist_menu
            if menu and is_enabled() then
                Background.applyToMenu(menu)
                local _ = require("gettext")
                local fav_display = _("Favorites")
                local raw_fav = resolved_name
                local fm_coll = self
                local Device_fav = require("device")
                if Device_fav:isTouchDevice() then
                    local GestureRange_fav = require("ui/gesturerange")
                    local Geom_fav         = require("ui/geometry")
                    if not menu.ges_events then menu.ges_events = {} end
                    menu.ges_events.ZenNamedCollBlankHold = {
                        GestureRange_fav:new{
                            ges   = "hold",
                            range = Geom_fav:new{
                                x = 0, y = 0,
                                w = Device_fav.screen:getWidth(),
                                h = Device_fav.screen:getHeight(),
                            },
                        },
                    }
                    menu.onZenNamedCollBlankHold = function(self_arg, arg, ges)
                        if ges and ges.pos and menu.item_group then
                            for _i, iw in ipairs(menu.item_group) do
                                if iw.dimen and iw.dimen:contains(ges.pos) then
                                    return false
                                end
                            end
                        end
                        return show_named_coll_blank_menu(fm_coll, menu, raw_fav, fav_display, true)
                    end
                end
            end
            return
        end

        local display_name = resolved_name
        if is_favorites then
            local _ = require("gettext")
            display_name = _("Favorites")
        end

        clean_nav(self.booklist_menu, display_name, collection_name, self)
    end

    ---------------------------------------------------------------------------
    -- Prevent partial-row centering
    ---------------------------------------------------------------------------
    local orig_updateCollListItemTable = FileManagerCollection.updateCollListItemTable
    function FileManagerCollection:updateCollListItemTable(...)
        if is_enabled() and self.coll_list then
            self.coll_list._do_center_partial_rows = false
        end
        return orig_updateCollListItemTable(self, ...)
    end

    ---------------------------------------------------------------------------
    -- Hook onShowCollList
    ---------------------------------------------------------------------------
    local orig_onShowCollList = FileManagerCollection.onShowCollList
    function FileManagerCollection:onShowCollList(file_or_selected_collections, caller_callback, no_dialog)
        local is_browse = file_or_selected_collections == nil

        if is_browse and is_enabled() then
            _patching_coll_list = true
        end

        local result = orig_onShowCollList(self, file_or_selected_collections, caller_callback, no_dialog)
        _patching_coll_list = false

        if not is_enabled() then return result end
        if not is_browse then return result end
        if not self.coll_list then return result end

        clean_nav_list(self.coll_list, self)
        return result
    end

    ---------------------------------------------------------------------------
    -- Collections search patch (unchanged)
    ---------------------------------------------------------------------------
    local _orig_searchCollections = FileManagerCollection.searchCollections
    if _orig_searchCollections then
        local util_lower = require("util").stringLower

        local function is_word_byte(b)
            return (b >= 48 and b <= 57)
                or (b >= 65 and b <= 90)
                or (b >= 97 and b <= 122)
                or b == 95
                or b >= 128
        end

        local function find_whole_word(text, pattern)
            if #pattern == 0 then return false end
            local i = 1
            while true do
                local s, e = string.find(text, pattern, i, true)
                if not s then return false end
                local before_ok = (s == 1) or not is_word_byte(text:byte(s - 1))
                local after_ok  = (e == #text) or not is_word_byte(text:byte(e + 1))
                if before_ok and after_ok then return true end
                i = s + 1
            end
        end

        function FileManagerCollection:searchCollections(coll_name)
            local bookinfo = self.ui and self.ui.bookinfo
            if not bookinfo then
                return _orig_searchCollections(self, coll_name)
            end

            local orig_findInProps = bookinfo.findInProps
            bookinfo.findInProps = function(info, book_props, search_str, case_sensitive)
                local fold = not case_sensitive
                local needle = fold and util_lower(search_str) or search_str
                for _i, key in ipairs(info.props) do
                    if key ~= "description" then
                        local prop = book_props[key]
                        if prop then
                            if key == "series_index" then
                                prop = tostring(prop)
                            end
                            local haystack = fold and util_lower(prop) or prop
                            if find_whole_word(haystack, needle) then
                                return true
                            end
                        end
                    end
                end
            end

            local ok, err = pcall(_orig_searchCollections, self, coll_name)
            bookinfo.findInProps = orig_findInProps
            if not ok then
                logger.dbg("searchCollections error:", err)
            end
        end
    end

    logger.dbg("all hooks installed")
end

return apply_collections
