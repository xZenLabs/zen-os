local ConfigManager = require("config/manager")
local author_sort = require("common/author_sort")
local book_status = require("common/book_status")
local HistoryIndex = require("common/history_index")
local icons = require("common/inline_icon_map")
local submenu_arrow = icons.arrow_right
local LanguageName = require("common/language_name")
local paths = require("common/paths")
local StandalonePage = require("modules/filebrowser/patches/standalone_page")
local SharedState = require("common/shared_state")
local title_sort = require("common/title_sort")
local zen_utils = require("common/utils")

local M = {}

-- Active group view menus (so we can refresh them)
local _authors_menu = nil
local _series_menu  = nil
local _languages_menu = nil
local _tbr_menu     = nil
local _tags_menu    = nil
-- Detail view menus layered on top of the group menu
local _detail_menus = {}

local function get_root_menu(tab_id)
    if tab_id == "authors" then return _authors_menu end
    if tab_id == "series" then return _series_menu end
    if tab_id == "languages" then return _languages_menu end
    if tab_id == "tags" then return _tags_menu end
    if tab_id == "to_be_read" then return _tbr_menu end
end

local function clear_root_menu(tab_id, menu)
    if tab_id == "authors" and _authors_menu == menu then
        _authors_menu = nil
    elseif tab_id == "series" and _series_menu == menu then
        _series_menu = nil
    elseif tab_id == "languages" and _languages_menu == menu then
        _languages_menu = nil
    elseif tab_id == "tags" and _tags_menu == menu then
        _tags_menu = nil
    elseif tab_id == "to_be_read" and _tbr_menu == menu then
        _tbr_menu = nil
    end
end

local root_show_methods = {
    authors = "showAuthorsView",
    series = "showSeriesView",
    languages = "showLanguagesView",
    tags = "showTagsView",
    to_be_read = "showTBRView",
}

local function reopen_root_view(tab_id, injectNavbar)
    local fn = M[root_show_methods[tab_id]]
    return type(fn) == "function" and fn(injectNavbar) ~= nil
end

local function remove_detail_menu(menu)
    for i = #_detail_menus, 1, -1 do
        if _detail_menus[i] == menu then
            table.remove(_detail_menus, i)
            return
        end
    end
end

-- Set during apply (called at init while __ZEN_UI_PLUGIN is set)
local _zen_shared    = nil
local _zen_plugin    = nil  -- captured at init; __ZEN_UI_PLUGIN is cleared after init

local function refresh_shared_state()
    if _zen_plugin then
        _zen_shared = SharedState.restore(_zen_plugin) or _zen_shared
    end
    return _zen_shared
end

local function load_zen_config()
    if _zen_plugin and type(_zen_plugin.config) == "table" then
        return _zen_plugin.config
    end
    local ok, cfg = pcall(ConfigManager.load)
    if ok and type(cfg) == "table" then
        return cfg
    end
end

local function save_zen_config(cfg)
    if type(cfg) ~= "table" then return end
    if _zen_plugin and _zen_plugin.config == cfg and type(_zen_plugin.saveConfig) == "function" then
        _zen_plugin:saveConfig()
        return
    end
    pcall(ConfigManager.save, cfg)
    if _zen_plugin and type(_zen_plugin.config) == "table" then
        _zen_plugin.config = cfg
    end
end

local function rebuild_home()
    if not _zen_plugin then return end
    local home = SharedState.get(_zen_plugin, "home")
    if home and type(home.rebuildActive) == "function" then
        home.rebuildActive()
    end
end

local function get_display_mode(tab_id, group_name, fallback)
    local cfg = load_zen_config()
    local group_view = cfg and cfg.group_view
    local detail_display_mode = group_view and group_view.detail_display_mode
    local tab_detail = detail_display_mode and detail_display_mode[tab_id]
    local stored = group_name and tab_detail and tab_detail[group_name]
    if type(stored) == "string" and stored ~= "" then
        return stored
    end
    local display_mode = group_view and group_view.display_mode
    stored = display_mode and display_mode[tab_id]
    if type(stored) == "string" and stored ~= "" then
        return stored
    end
    return fallback
end

local function set_display_mode(tab_id, group_name, mode)
    if type(mode) ~= "string" or mode == "" then return end
    local cfg = load_zen_config()
    if type(cfg) ~= "table" then return end
    if type(cfg.group_view) ~= "table" then cfg.group_view = {} end
    if group_name then
        if type(cfg.group_view.detail_display_mode) ~= "table" then
            cfg.group_view.detail_display_mode = {}
        end
        if type(cfg.group_view.detail_display_mode[tab_id]) ~= "table" then
            cfg.group_view.detail_display_mode[tab_id] = {}
        end
        cfg.group_view.detail_display_mode[tab_id][group_name] = mode
    else
        if type(cfg.group_view.display_mode) ~= "table" then cfg.group_view.display_mode = {} end
        cfg.group_view.display_mode[tab_id] = mode
    end
    save_zen_config(cfg)
end

local function get_detail_collate(tab_id, group_name, fallback)
    local cfg = load_zen_config()
    local group_view = cfg and cfg.group_view
    local detail_collate = group_view and group_view.detail_collate
    local tab_collate = detail_collate and detail_collate[tab_id]
    local stored = tab_collate and tab_collate[group_name]
    if type(stored) == "string" and stored ~= "" then
        return stored
    end
    return fallback
end

local function set_detail_collate(tab_id, group_name, collate)
    if type(collate) ~= "string" or collate == "" then return end
    local cfg = load_zen_config()
    if type(cfg) ~= "table" then return end
    if type(cfg.group_view) ~= "table" then cfg.group_view = {} end
    if type(cfg.group_view.detail_collate) ~= "table" then cfg.group_view.detail_collate = {} end
    if type(cfg.group_view.detail_collate[tab_id]) ~= "table" then
        cfg.group_view.detail_collate[tab_id] = {}
    end
    cfg.group_view.detail_collate[tab_id][group_name] = collate
    save_zen_config(cfg)
end

local function get_group_reverse(tab_id)
    local cfg = load_zen_config()
    local group_view = cfg and cfg.group_view
    local group_reverse = group_view and group_view.group_reverse
    local stored = group_reverse and group_reverse[tab_id]
    if stored ~= nil then
        return stored == true
    end
    return false
end

local function set_group_reverse(tab_id, reverse)
    if tab_id ~= "authors" and tab_id ~= "series"
            and tab_id ~= "languages" and tab_id ~= "tags" then return end
    local cfg = load_zen_config()
    if type(cfg) ~= "table" then return end
    if type(cfg.group_view) ~= "table" then cfg.group_view = {} end
    if type(cfg.group_view.group_reverse) ~= "table" then
        cfg.group_view.group_reverse = {}
    end
    cfg.group_view.group_reverse[tab_id] = reverse == true
    save_zen_config(cfg)
    rebuild_home()
end

local function get_authors_collate()
    local cfg = load_zen_config()
    local stored = cfg and cfg.group_view and cfg.group_view.authors_collate
    return author_sort.normalize(stored)
end

local function set_authors_collate(collate)
    if not author_sort.isMode(collate) then return end
    local cfg = load_zen_config()
    if type(cfg) ~= "table" then return end
    if type(cfg.group_view) ~= "table" then cfg.group_view = {} end
    cfg.group_view.authors_collate = collate
    save_zen_config(cfg)
    rebuild_home()
end

local function get_group_collate(tab_id)
    local cfg = load_zen_config()
    local group_collate = cfg and cfg.group_view and cfg.group_view.group_collate
    return group_collate and group_collate[tab_id] == "title_natural"
        and "title_natural" or "title"
end

local function set_group_collate(tab_id, collate)
    if tab_id ~= "series" and tab_id ~= "languages" and tab_id ~= "tags" then return end
    if collate ~= "title" and collate ~= "title_natural" then return end
    local cfg = load_zen_config()
    if type(cfg) ~= "table" then return end
    if type(cfg.group_view) ~= "table" then cfg.group_view = {} end
    if type(cfg.group_view.group_collate) ~= "table" then
        cfg.group_view.group_collate = {}
    end
    cfg.group_view.group_collate[tab_id] = collate
    save_zen_config(cfg)
    rebuild_home()
end

local function get_tags_global_collate()
    local cfg = load_zen_config()
    local group_view = cfg and cfg.group_view
    local tags_global = group_view and group_view.tags_global
    local stored = tags_global and tags_global.collate
    if type(stored) == "string" and stored ~= "" then
        return stored
    end
    return "title"
end

local function is_tags_global_reverse()
    local cfg = load_zen_config()
    local group_view = cfg and cfg.group_view
    local tags_global = group_view and group_view.tags_global
    if tags_global and tags_global.reverse ~= nil then
        return tags_global.reverse == true
    end
    return false
end

local function get_detail_reverse(tab_id, group_name, fallback)
    local cfg = load_zen_config()
    local group_view = cfg and cfg.group_view
    local detail_reverse = group_view and group_view.detail_reverse
    local tab_reverse = detail_reverse and detail_reverse[tab_id]
    local stored = tab_reverse and tab_reverse[group_name]
    if stored ~= nil then
        return stored == true
    end
    return fallback == true
end

local function set_detail_reverse(tab_id, group_name, reverse)
    local cfg = load_zen_config()
    if type(cfg) ~= "table" then return end
    if type(cfg.group_view) ~= "table" then cfg.group_view = {} end
    if type(cfg.group_view.detail_reverse) ~= "table" then
        cfg.group_view.detail_reverse = {}
    end
    if type(cfg.group_view.detail_reverse[tab_id]) ~= "table" then
        cfg.group_view.detail_reverse[tab_id] = {}
    end
    if reverse then
        cfg.group_view.detail_reverse[tab_id][group_name] = true
    else
        cfg.group_view.detail_reverse[tab_id][group_name] = nil
    end
    save_zen_config(cfg)
end

-- True when up-folder items should be shown (mirrors browser_hide_up_folder config).
local function should_show_up_folder()
    local p = _zen_plugin or rawget(_G, "__ZEN_UI_PLUGIN")
    if not p or type(p.config) ~= "table" then return true end
    local features = p.config.features
    -- Feature not enabled -> default KOReader behaviour: show up folder.
    if type(features) ~= "table" or not features.browser_hide_up_folder then return true end
    local cfg = p.config.browser_hide_up_folder
    -- Feature enabled; default is hide=true. Only show when explicitly set to false.
    return type(cfg) == "table" and cfg.hide_up_folder == false
end

-------------------------------------------------------------------------------
-- setup_display_mode: mirror fi CoverMenu/MosaicMenu/ListMenu onto menu
-- Returns "mosaic", "list", or "classic"
-------------------------------------------------------------------------------
local function setup_display_mode(menu, is_group_view, tab_id, group_name)
    local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
    if not ok_bim then
        menu.display_mode_type = "classic"
        return "classic"
    end
    local display_mode
    if tab_id then
        display_mode = get_display_mode(tab_id, group_name, "list_image_meta")
    else
        display_mode = BookInfoManager:getSetting("filemanager_display_mode")
    end
    if is_group_view then
        menu._zen_group_view = true
    end

    if not display_mode then
        menu.display_mode_type = "classic"
        return "classic"
    end

    local ok_cm, CoverMenu = pcall(require, "covermenu")
    if not ok_cm then
        menu.display_mode_type = "classic"
        return "classic"
    end

    local display_mode_type = display_mode:gsub("_.*", "")  -- "mosaic" or "list"

    menu.updateItems   = CoverMenu.updateItems
    menu.onCloseWidget = rawget(menu, "onCloseWidget") or CoverMenu.onCloseWidget

    menu.nb_cols_portrait  = BookInfoManager:getSetting("nb_cols_portrait")  or 3
    menu.nb_rows_portrait  = BookInfoManager:getSetting("nb_rows_portrait")  or 3
    menu.nb_cols_landscape = BookInfoManager:getSetting("nb_cols_landscape") or 4
    menu.nb_rows_landscape = BookInfoManager:getSetting("nb_rows_landscape") or 2
    menu.files_per_page    = require("common/cover_utils").getFilesPerPage()
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

    -- Provide proper getBookInfo for badge support
    if not menu.getBookInfo then
        if is_group_view then
            menu.getBookInfo = function() return {} end
        else
            -- Return reading status (percent_finished, status, been_opened) from sidecar.
            -- Called as menu.getBookInfo(filepath) — dot syntax, ONE arg only.
            menu.getBookInfo = function(file_path)
                if not file_path then return {} end
                local pages = zen_utils.getStablePageCount(file_path)
                local ok_ds, DocSettings = pcall(require, "docsettings")
                if not ok_ds then return { pages = pages } end
                if not DocSettings:hasSidecarFile(file_path) then return { pages = pages } end
                local ok2, doc = pcall(DocSettings.open, DocSettings, file_path)
                if not ok2 or not doc then return { pages = pages } end
                local summary = doc:readSetting("summary")
                local stats   = doc:readSetting("stats")
                pages = pages or zen_utils.getStablePageCount(file_path, stats and stats.pages)
                return {
                    been_opened      = true,
                    percent_finished = doc:readSetting("percent_finished"),
                    status           = summary and summary.status,
                    pages            = pages,
                }
            end
        end
    end
    if not menu.resetBookInfoCache then
        menu.resetBookInfoCache = function() end
    end

    return display_mode_type
end

-- clean_nav: suppress back arrow, inject status bar row, set display mode
-- back_callback: optional function for the status bar back chevron
-------------------------------------------------------------------------------
local function clean_nav(menu, tab_label, back_callback)
    if not menu then return end

    menu._do_center_partial_rows = false
    StandalonePage.hide_page_arrow(menu)
    StandalonePage.suppress_page_info_tap(menu)

    local createStatusRow = _zen_shared and _zen_shared.createStatusRow
    local createStatusRowCB = _zen_shared and _zen_shared.createStatusRowCustomBack
    local repaintTitleBar = _zen_shared and _zen_shared.repaintTitleBar
    StandalonePage.apply_status_row(menu, {
        createStatusRow = createStatusRow,
        createStatusRowCustomBack = createStatusRowCB,
        repaintTitleBar = repaintTitleBar,
        label = tab_label,
        back_callback = back_callback,
    })
end

-------------------------------------------------------------------------------
-- build_group_item_table: convert db_bookinfo groups to Menu item_table entries
-- data_type: "authors" or "series"
-- groups: output of db_bookinfo.getGroupedByAuthor() / getGroupedBySeries()
-------------------------------------------------------------------------------
local function group_empty_message(data_type)
    local _ = require("gettext")
    return ({
        authors = _("No books with author metadata found"),
        series = _("No books with series metadata found"),
        languages = _("No books with language metadata found"),
        tags = _("No books with tags metadata found"),
        to_be_read = _("No TBR books found"),
    })[data_type] or _("No books found")
end

local function build_group_item_table(groups, data_type)
    local empty_message = group_empty_message(data_type)
    local items = {}
    for _i, group in ipairs(groups) do
        local files
        if data_type == "authors" or data_type == "languages" or data_type == "tags" then
            files = group.files
        else
            -- series items: extract file paths in order
            files = {}
            for _j, item in ipairs(group.items) do
                table.insert(files, item.file)
            end
        end
        local display = group.author or group.series or group.language or group.tag or "?"
        if data_type == "languages" then display = LanguageName.get(display) end
        display = tostring(display):gsub("\n", ", ")
        local count = #files
        table.insert(items, {
            text        = display,
            mandatory   = tostring(count) .. " \u{F016}",
            _zen_files  = files,
            _zen_type   = data_type,
            _zen_group  = (data_type == "series") and group or nil,
        })
    end

    if #items > 1 then
        if data_type == "authors" then
            local collate = get_authors_collate()
            table.sort(items, function(a, b)
                return author_sort.less(a.text, b.text, collate)
            end)
        elseif data_type == "series" or data_type == "languages" or data_type == "tags" then
            local natural = get_group_collate(data_type) == "title_natural"
            table.sort(items, function(a, b)
                return title_sort.less(a.text, b.text, natural)
            end)
        end
    end
    if #items == 0 then
        table.insert(items, {
            text                    = empty_message,
            dim                     = true,
            callback                = function() end,
            _zen_empty_placeholder  = true,
        })
    end

    -- Apply reverse sort if enabled.
    if (data_type == "authors" or data_type == "series"
            or data_type == "languages" or data_type == "tags")
            and get_group_reverse(data_type) and #items > 0 then
        -- Reverse the array (skip the placeholder)
        if items[1].text ~= empty_message then
            local reversed = {}
            for i = #items, 1, -1 do
                table.insert(reversed, items[i])
            end
            items = reversed
        end
    end

    return items
end

-- Forward declaration so showDisplayModeDialog can reference showGroupView.
local showGroupView

-------------------------------------------------------------------------------
-- showDisplayModeDialog: show display mode selection dialog
-- menu: optional Menu instance to refresh after mode change
-------------------------------------------------------------------------------
local function showDisplayModeDialog(menu, tab_id, group_name)
    local _ = require("gettext")
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")

    local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
    local fm = ok_fm and FM and FM.instance
    local ok_bim, bim = pcall(require, "bookinfomanager")
    local cur_mode
    if tab_id then
        cur_mode = get_display_mode(tab_id, group_name, "list_image_meta")
    elseif ok_bim and bim then
        local ok3, m = pcall(function()
            return bim:getSetting("filemanager_display_mode")
        end)
        if ok3 then cur_mode = m end
    end

    local function apply_mode(mode)
        if tab_id then
            set_display_mode(tab_id, group_name, mode)
        else
            -- Use FM:onSetDisplayMode to update CoverBrowser state and save to BIM.
            local via_fm = false
            if fm and type(fm.onSetDisplayMode) == "function" then
                via_fm = pcall(fm.onSetDisplayMode, fm, mode)
            end
            if not via_fm and ok_bim and bim then
                pcall(bim.saveSetting, bim, "filemanager_display_mode", mode)
            end
        end

        -- Rebuild in-place: swap methods for the new mode, then redraw once.
        local function _rebuild_menu(m, is_group, t_id, detail_group)
            local new_mode_type = setup_display_mode(m, is_group, t_id, detail_group)
            if new_mode_type ~= "mosaic" and new_mode_type ~= "list" then
                -- Classic mode: restore base Menu methods
                local Menu_class = require("ui/widget/menu")
                m.updateItems         = Menu_class.updateItems
                m._updateItemsBuildUI = nil
                m._recalculateDimen   = nil
                m.display_mode_type   = nil
            end
            m:updateItems()
        end
        if menu and (not group_name or menu._zen_group_name == group_name) then
            _rebuild_menu(menu, menu._zen_group_view or false, tab_id, group_name)
        end
        -- Rebuild an open root menu when the change came from elsewhere.
        if tab_id and not group_name then
            local root_menu = get_root_menu(tab_id)
            if root_menu and root_menu ~= menu then
                _rebuild_menu(root_menu, true, tab_id)
            end
        end
    end

    local view_dialog
    local function viewBtn(label, icon, mode)
        local active = cur_mode == mode
        return {{
            text     = icon .. "  " .. label .. (active and "  \u{2713}" or ""),
            align    = "left",
            enabled  = not active,
            callback = function()
                UIManager:close(view_dialog)
                apply_mode(mode)
            end,
        }}
    end

    view_dialog = ButtonDialog:new{
        title       = _("Display mode"),
        title_align = "center",
        buttons     = {
            viewBtn(_("Mosaic"),          "\u{F00A}", "mosaic_image"),
            viewBtn(_("List (detailed)"), "\u{F03A}", "list_image_meta"),
            viewBtn(_("List (basic)"),    "\u{F0CA}", "list_image_filename"),
        },
    }
    UIManager:show(view_dialog)
end


-------------------------------------------------------------------------------
-- showGroupSortDialog: show sort dialog for a group view
-- tab_id: "authors" | "series" | "languages" | "tags"
-- menu: the Menu instance to refresh after sort change
-------------------------------------------------------------------------------
local function showGroupSortDialog(tab_id, menu)
    local _ = require("gettext")
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")
    local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
    local fm = ok_fm and FM and FM.instance
    if not fm then return end

    local title = tab_id == "authors" and _("Sort authors")
        or tab_id == "languages" and _("Sort languages")
        or tab_id == "tags" and _("Tags") or _("Sort series")

    local function rebuild()
        if not menu then return end
        local ok, db = pcall(require, "common/db_bookinfo")
        if not ok then return end
        local groups
        if tab_id == "authors" then
            groups = db.getGroupedByAuthor()
        elseif tab_id == "languages" then
            groups = db.getGroupedByLanguage()
        elseif tab_id == "tags" then
            groups = db.getGroupedByTags()
        else
            groups = db.getGroupedBySeries()
        end
        menu.item_table = build_group_item_table(groups, tab_id)
        menu:updateItems()
    end

    if tab_id == "authors" then
        local current = get_authors_collate()
        local current_reverse = get_group_reverse(tab_id)
        local sort_dialog
        local buttons = author_sort.modeButtons(current, _, function(collate)
            UIManager:close(sort_dialog)
            set_authors_collate(collate)
            rebuild()
        end)
        buttons[#buttons + 1] = {{
            text = "\u{F0DC}  " .. _("Order") .. "  " .. submenu_arrow,
            align = "left",
            callback = function()
                UIManager:close(sort_dialog)
                fm.file_chooser:showSortOrderDialog({
                    title = title,
                    current_reverse = current_reverse,
                    on_select = function(reverse)
                        set_group_reverse(tab_id, reverse)
                        rebuild()
                    end,
                })
            end,
        }}
        sort_dialog = ButtonDialog:new{
            title = title,
            title_align = "center",
            buttons = buttons,
        }
        UIManager:show(sort_dialog)
        return
    end

    local current = get_group_collate(tab_id)
    local current_reverse = get_group_reverse(tab_id)
    local sort_dialog
    local buttons = {}
    local options = {
        { key = "title", text = "\u{F031}  " .. _("Title") },
        { key = "title_natural", text = "\u{F04BB}  " .. _("Title natural") },
    }
    for _i, option in ipairs(options) do
        local active = current == option.key
        buttons[#buttons + 1] = {{
            text = option.text .. (active and "  \u{2713}" or ""),
            align = "left",
            enabled = not active,
            callback = function()
                UIManager:close(sort_dialog)
                set_group_collate(tab_id, option.key)
                rebuild()
            end,
        }}
    end
    buttons[#buttons + 1] = {{
        text = "\u{F0DC}  " .. _("Order") .. "  " .. submenu_arrow,
        align = "left",
        callback = function()
            UIManager:close(sort_dialog)
            fm.file_chooser:showSortOrderDialog({
                title = title,
                current_reverse = current_reverse,
                on_select = function(reverse)
                    set_group_reverse(tab_id, reverse)
                    rebuild()
                end,
            })
        end,
    }}
    sort_dialog = ButtonDialog:new{
        title = title,
        title_align = "center",
        buttons = buttons,
    }
    UIManager:show(sort_dialog)
end

-------------------------------------------------------------------------------
-- sortDetailFiles: sort files array by collate field and reverse flag
-- Returns sorted array of file paths
-------------------------------------------------------------------------------
local function sortDetailFiles(files, collate, reverse)
    if not files or #files == 0 then return files end

    -- Batch-load the metadata for the whole library with one cached query
    -- (db_bookinfo.getLightMetadata) instead of issuing one SQL statement per
    -- file via BookInfoManager:getBookInfo.
    local meta_map
    if collate == "title" or collate == "title_natural"
        or collate == "series_index" or collate == "series" then
        local ok_db, db = pcall(require, "common/db_bookinfo")
        if ok_db and type(db.getLightMetadata) == "function" then
            meta_map = db.getLightMetadata()
        end
    end

    -- Build sortable array with metadata
    local items = {}
    local normalize_path = paths.normPath
    local history = collate == "access" and HistoryIndex.load(normalize_path) or nil
    for _i, fpath in ipairs(files) do
        local meta = meta_map and (meta_map[fpath] or meta_map[normalize_path(fpath)])
        local sort_key

        if collate == "title" or collate == "title_natural" then
            sort_key = (meta and meta.title) or fpath:match("([^/]+)$") or fpath
        elseif collate == "series_index" then
            -- Numeric; books without an index sort last.
            sort_key = (meta and tonumber(meta.series_index)) or math.huge
        elseif collate == "series" then
            sort_key = (meta and meta.series) or ""
        elseif collate == "access" then
            local lfs = require("libs/libkoreader-lfs")
            sort_key = HistoryIndex.fileTime(history, fpath, normalize_path)
                or lfs.attributes(fpath, "access") or 0
        else
            sort_key = fpath:match("([^/]+)$") or fpath
        end

        table.insert(items, { path = fpath, key = sort_key })
    end

    -- Sort by key
    if collate ~= "title_natural" then
        table.sort(items, function(a, b)
            if collate == "series_index" or collate == "access" then
                -- Numeric comparison; for access higher = more recent so invert.
                local a_n = type(a.key) == "number" and a.key or 0
                local b_n = type(b.key) == "number" and b.key or 0
                if collate == "access" then
                    if reverse then return a_n < b_n else return a_n > b_n end
                else
                    if reverse then return a_n > b_n else return a_n < b_n end
                end
            else
                local a_key = collate == "title" and title_sort.key(a.key) or tostring(a.key)
                local b_key = collate == "title" and title_sort.key(b.key) or tostring(b.key)
                local a_lower = a_key:lower()
                local b_lower = b_key:lower()
                if reverse then return a_lower > b_lower else return a_lower < b_lower end
            end
        end)
    else
        local BookList = require("ui/widget/booklist")
        local sort_func = BookList.collates.title_natural.init_sort_func()

        table.sort(items, function(a, b)
            local first, second = a, b
            if reverse then first, second = second, first end
            return sort_func(
                { doc_props = { display_title = first.key } },
                { doc_props = { display_title = second.key } })
        end)
    end

    -- Extract sorted paths
    local sorted = {}
    for _i, item in ipairs(items) do
        table.insert(sorted, item.path)
    end

    return sorted
end

-- Filter a file list to only those matching FileChooser.show_filter.status.
-- Returns the original list unchanged when no filter is active.
local function apply_status_filter(files)
    local ok_fc, FileChooser = pcall(require, "ui/widget/filechooser")
    if not ok_fc then return files end
    local status_filter = FileChooser.show_filter and FileChooser.show_filter.status
    if not status_filter then return files end
    local filtered = {}
    local get_status = book_status.getDisplayStatusFromFile
        or book_status.getEffectiveStatusFromFile
    for _i, fpath in ipairs(files) do
        local display_status = get_status(fpath)
        if status_filter[display_status] then
            table.insert(filtered, fpath)
        end
    end
    return filtered
end

-------------------------------------------------------------------------------
-- showDetailSortDialog: show sort options dialog for detail view
-- group_name: the author or series name
-- tab_id: "authors" | "series"
-- menu: the Menu instance to refresh after sort change
-- files: list of file paths
-------------------------------------------------------------------------------
local function showDetailSortDialog(group_name, tab_id, menu, files, reload_files)
    local _ = require("gettext")
    local ButtonDialog = require("ui/widget/buttondialog")
    local UIManager = require("ui/uimanager")

    local default_collate
    if tab_id == "series" then
        default_collate = "series_index"
    elseif tab_id == "tags" then
        default_collate = get_tags_global_collate()
    else
        default_collate = "title"
    end
    local cur_collate = get_detail_collate(tab_id, group_name, default_collate)
    local reverse_fallback = tab_id == "tags" and is_tags_global_reverse() or false
    local cur_reverse = get_detail_reverse(tab_id, group_name, reverse_fallback)

    local SORT_OPTIONS = {
        { key = "series_index",  text = "\u{F0CB}  " .. _("Series number") },
        { key = "title",         text = "\u{F031}  " .. _("Title") },
        { key = "title_natural", text = "\u{F04BB}  " .. _("Title natural") },
        { key = "strcoll",       text = icons.filename .. "  " .. _("Filename") },
        { key = "access",        text = "\u{F073}  " .. _("Recently read") },
    }

    local function rebuildMenu(collate, reverse)
        if not (menu and files) then return end

        local sorted_files = reload_files and reload_files(collate, reverse)
            or sortDetailFiles(files, collate, reverse)
        if tab_id ~= "status" then
            sorted_files = apply_status_filter(sorted_files)
        end

        local lfs_mod  = require("libs/libkoreader-lfs")
        local util_mod = require("util")
        local book_items = {}
        for _i, fpath in ipairs(sorted_files) do
            local fname = fpath:match("([^/]+)$") or fpath
            local display = fname:gsub("%.[^%.]+$", "")
            local attr = lfs_mod.attributes(fpath)

            table.insert(book_items, {
                text      = display,
                path      = fpath,
                filepath  = fpath,
                is_file   = true,
                mandatory = attr and util_mod.getFriendlySize(attr.size or 0) or "",
            })
        end

        if should_show_up_folder() then
            table.insert(book_items, 1, { text = "\u{2B06} ..", is_go_up = true, mandatory = "" })
        end

        menu.item_table = book_items
        menu:updateItems()
    end

    local sort_dialog
    local sort_buttons = {}

    -- Add collate field options
    for _i, opt in ipairs(SORT_OPTIONS) do
        local is_active = cur_collate == opt.key
        table.insert(sort_buttons, {{
            text     = opt.text .. (is_active and "  \u{2713}" or ""),
            align    = "left",
            enabled  = not is_active,
            callback = function()
                set_detail_collate(tab_id, group_name, opt.key)
                UIManager:close(sort_dialog)
                rebuildMenu(opt.key, cur_reverse)
            end,
        }})
    end

    -- Order submenu
    table.insert(sort_buttons, {{
        text     = "\u{F0DC}  " .. _("Order") .. "  " .. submenu_arrow,
        align    = "left",
        callback = function()
            UIManager:close(sort_dialog)
            local order_dialog
            local order_buttons = {
                {{
                    text     = "\u{F15D}  " .. _("Ascending") .. (not cur_reverse and "  \u{2713}" or ""),
                    align    = "left",
                    enabled  = cur_reverse,
                    callback = function()
                        set_detail_reverse(tab_id, group_name, false)
                        UIManager:close(order_dialog)
                        rebuildMenu(cur_collate, false)
                    end,
                }},
                {{
                    text     = "\u{F15E}  " .. _("Descending") .. (cur_reverse and "  \u{2713}" or ""),
                    align    = "left",
                    enabled  = not cur_reverse,
                    callback = function()
                        set_detail_reverse(tab_id, group_name, true)
                        UIManager:close(order_dialog)
                        rebuildMenu(cur_collate, true)
                    end,
                }},
            }
            order_dialog = ButtonDialog:new{
                title       = _("Sort order"),
                title_align = "center",
                buttons     = order_buttons,
            }
            UIManager:show(order_dialog)
        end,
    }})

    sort_dialog = ButtonDialog:new{
        title       = _("Sort books by"),
        title_align = "center",
        buttons     = sort_buttons,
    }
    UIManager:show(sort_dialog)
end

-------------------------------------------------------------------------------
-- show_file_dialog_with_refresh: call fc:showFileDialog(item) but also
-- refresh menu_self after a status change (which triggers fc:refreshPath).
-- One-shot wrapper: restores the original after first call or on next refresh.
-------------------------------------------------------------------------------
local function show_file_dialog_with_refresh(fc, menu_self, item)
    local orig = fc.refreshPath
    fc.refreshPath = function(self2, ...)
        fc.refreshPath = orig  -- restore before doing anything
        orig(self2, ...)
        local UIManager2 = require("ui/uimanager")
        local is_shown
        if type(UIManager2.isShown) == "function" then
            is_shown = UIManager2:isShown(menu_self)
        else
            -- Fallback for older KOReader: scan window stack directly
            is_shown = false
            if type(UIManager2._window_stack) == "table" then
                for _i, entry in ipairs(UIManager2._window_stack) do
                    if entry.widget == menu_self then is_shown = true; break end
                end
            end
        end
        if is_shown then
            menu_self:updateItems()
        end
    end
    fc:showFileDialog(item)
end

local function get_file_manager()
    local FileManager = require("apps/filemanager/filemanager")
    return FileManager.instance
end

local function is_file_selected(path)
    local file_manager = get_file_manager()
    return file_manager and file_manager.selected_files
        and file_manager.selected_files[path] == true or nil
end

local function toggle_file_selection(menu, item)
    local file_manager = get_file_manager()
    if not (file_manager and file_manager.selected_files ~= nil and item.path) then
        return false
    end
    item.dim = not item.dim and true or nil
    file_manager.selected_files[item.path] = item.dim
    menu:updateItems()
    return true
end

local function show_select_mode_menu()
    local file_manager = get_file_manager()
    if file_manager and file_manager.selected_files ~= nil
            and type(file_manager.onShowPlusMenu) == "function" then
        file_manager:onShowPlusMenu()
        return true
    end
    return false
end

-------------------------------------------------------------------------------
-- showDetailView: book list for one author/series group
-- Called from onMenuSelect on the group list menu
-------------------------------------------------------------------------------
local function showDetailView(group_item, injectNavbar, tab_id, navbar_tab_id)
    local _ = require("gettext")
    local UIManager = require("ui/uimanager")

    local files      = type(group_item._zen_load_files) == "function"
        and group_item._zen_load_files() or group_item._zen_files or {}
    local group_name = group_item.text or ""
    local detail_name
    if tab_id == "authors" then
        detail_name = "authors_detail"
    elseif tab_id == "languages" then
        detail_name = "languages_detail"
    elseif tab_id == "tags" then
        detail_name = "tags_detail"
    elseif tab_id == "series" then
        detail_name = "series_detail"
    else
        detail_name = tab_id .. "_detail"
    end
    for _i, active_menu in ipairs(_detail_menus) do
        if active_menu.name == detail_name then
            return active_menu, false
        end
    end

    -- Get sort settings for this group
    -- Series defaults to series_index; tags fall back to the global tags sort setting;
    -- authors default to title.
    local default_collate
    if tab_id == "series" then
        default_collate = "series_index"
    elseif tab_id == "tags" then
        default_collate = get_tags_global_collate()
    else
        default_collate = "title"
    end
    local cur_collate = get_detail_collate(tab_id, group_name, default_collate)
    local reverse_fallback = tab_id == "tags" and is_tags_global_reverse() or false
    local cur_reverse = get_detail_reverse(tab_id, group_name, reverse_fallback)

    -- Sort files based on current settings
    local sorted_files = sortDetailFiles(files, cur_collate, cur_reverse)
    if tab_id ~= "status" then
        sorted_files = apply_status_filter(sorted_files)
    end

    -- Build menu items from sorted files
    local lfs_mod  = require("libs/libkoreader-lfs")
    local util_mod = require("util")
    local book_items = {}
    for _i, fpath in ipairs(sorted_files) do
        local fname = fpath:match("([^/]+)$") or fpath
        local display = fname:gsub("%.[^%.]+$", "")
        local attr = lfs_mod.attributes(fpath)
        table.insert(book_items, {
            text      = display,
            path      = fpath,
            filepath  = fpath,
            is_file   = true,
            dim       = is_file_selected(fpath),
            mandatory = attr and util_mod.getFriendlySize(attr.size or 0) or "",
        })
    end
    if #book_items == 0 then
        table.insert(book_items, {
            text                   = group_empty_message(tab_id),
            dim                    = true,
            callback               = function() end,
            _zen_empty_placeholder = true,
        })
    end
    if should_show_up_folder() then
        table.insert(book_items, 1, { text = "\u{2B06} ..", is_go_up = true, mandatory = "" })
    end

    local detail_menu
    detail_menu = StandalonePage.create_menu{
        name = detail_name,
        title = group_name,
        item_table = book_items,
        onMenuSelect = function(menu_self, item)
            if item.is_go_up then
                if menu_self.close_callback then menu_self.close_callback()
                else UIManager:close(menu_self) end
                return
            end
            if item.path then
                if toggle_file_selection(menu_self, item) then return end
                local fm = get_file_manager()
                local fmu = require("apps/filemanager/filemanagerutil")
                if fmu.openFile then
                    fmu.openFile(fm, item.path)
                elseif fm then
                    fm:openFile(item.path)
                end
            end
        end,
        onMenuHold = function(menu_self, item)
            if show_select_mode_menu() then return true end
            if not item.path then return end
            local fm = get_file_manager()
            if fm and fm.file_chooser and fm.file_chooser.showFileDialog then
                show_file_dialog_with_refresh(fm.file_chooser, menu_self, {
                    path = item.path,
                    is_file = true,
                    text = item.text,
                    _zen_select_cb = function()
                        return toggle_file_selection(menu_self, item)
                    end,
                    _zen_after_status_change = group_item._zen_load_files and function(path)
                        fm.file_chooser:refreshPath(path)
                        detail_menu.close_callback()
                        showDetailView(group_item, injectNavbar, tab_id, navbar_tab_id)
                    end or nil,
                })
            end
        end,
        updateItems = function() end,
    }
    StandalonePage.prepare_shell(detail_menu)

    -- Install this group's display mode (mosaic/list/classic)
    local mode_type = setup_display_mode(detail_menu, false, tab_id, group_name)
    if mode_type == "classic" or not mode_type then
        local Menu_class = require("ui/widget/menu")
        detail_menu.updateItems = Menu_class.updateItems
    end

    table.insert(_detail_menus, detail_menu)
    detail_menu._zen_group_name = group_name
    detail_menu._zen_tab_id     = tab_id
    detail_menu.close_callback = function()
        UIManager:close(detail_menu)
        remove_detail_menu(detail_menu)
    end
    local orig_detail_on_close_widget = detail_menu.onCloseWidget
    function detail_menu:onCloseWidget(...)
        remove_detail_menu(self)
        if orig_detail_on_close_widget then
            return orig_detail_on_close_widget(self, ...)
        end
    end

    -- Close the parent group menu too (used by navbar tap to unwind the full stack)
    detail_menu._zen_close_stack = function()
        local parent
        if tab_id == "authors" then
            parent = _authors_menu
        elseif tab_id == "languages" then
            parent = _languages_menu
        elseif tab_id == "tags" then
            parent = _tags_menu
        elseif tab_id == "series" then
            parent = _series_menu
        end
        if parent then
            UIManager:close(parent)
            if tab_id == "authors" then _authors_menu = nil
            elseif tab_id == "languages" then _languages_menu = nil
            elseif tab_id == "tags" then _tags_menu = nil
            elseif tab_id == "series" then _series_menu = nil end
        end
    end

    local back_to_group = function() UIManager:close(detail_menu) end
    clean_nav(detail_menu, group_name, back_to_group)

    if injectNavbar then
        injectNavbar(detail_menu, navbar_tab_id or tab_id)
    end
    if not navbar_tab_id or navbar_tab_id == tab_id then
        detail_menu._zen_library_bg_reopen = function()
            if not reopen_root_view(tab_id, injectNavbar) then return false end
            return M.restoreDetail(group_name, tab_id, injectNavbar) ~= nil
        end
    end

    -- Add blank-space hold gesture handler for context menu
    local Device3 = require("device")
    if Device3:isTouchDevice() then
        local GestureRange2 = require("ui/gesturerange")
        local Geom2         = require("ui/geometry")
        if not detail_menu.ges_events then
            detail_menu.ges_events = {}
        end
        detail_menu.ges_events.ZenDetailBlankHold = {
            GestureRange2:new{
                ges   = "hold",
                range = Geom2:new{
                    x = 0, y = 0,
                    w = Device3.screen:getWidth(),
                    h = Device3.screen:getHeight(),
                },
            },
        }
        function detail_menu:onZenDetailBlankHold(arg, ges)
            if show_select_mode_menu() then return true end
            local fm = get_file_manager()
            if fm and fm.file_chooser and fm.file_chooser.showFileDialog then
                fm.file_chooser:showFileDialog({
                    _zen_group_files       = sorted_files,
                    _zen_group_name        = group_name,
                    _zen_is_folder_view    = tab_id ~= "status",
                    _zen_sort_cb           = function()
                        showDetailSortDialog(group_name, tab_id, self, files)
                    end,
                    _zen_display_cb        = function()
                        showDisplayModeDialog(self, tab_id, group_name)
                    end,
                    _zen_filter_refresh_cb = function()
                        -- Rebuild item_table with new filter: close and reopen.
                        UIManager:close(detail_menu)
                        showDetailView(group_item, injectNavbar, tab_id, navbar_tab_id)
                    end,
                })
            end
            return true
        end
    end
    UIManager:show(detail_menu)
    UIManager:nextTick(function()
        -- Restore page if returning from reader (detail view was open)
        local dstate = rawget(_G, "__ZEN_UI_LIBRARY_STATE")
        if dstate and dstate.detail_group == group_name then
            detail_menu.page = dstate.detail_page or 1
            _G.__ZEN_UI_LIBRARY_STATE = nil
        end
        detail_menu:updateItems()
        -- Re-inject status row after updateItems (it may reset title_group).
        local createSR2   = _zen_shared and _zen_shared.createStatusRowCustomBack
        local repaintTB2  = _zen_shared and _zen_shared.repaintTitleBar
        local tb2 = detail_menu.title_bar
        if tb2 and createSR2 and tb2.title_group and #tb2.title_group >= 2 then
            tb2.title_group[2] = createSR2(back_to_group, group_name)
            tb2.title_group:resetLayout()
            if repaintTB2 then repaintTB2(tb2) end
        end
    end)
    return detail_menu, true
end

-------------------------------------------------------------------------------
-- showGroupView: shared group-list menu builder for authors and series
-- tab_id: "authors" | "series"
-- injectNavbar: the injectStandaloneNavbar function from navbar.lua
-- groups: pre-loaded data from db_bookinfo
-------------------------------------------------------------------------------
function M.showGroupContextMenu(group_name, files, tab_id, menu, options)
    if show_select_mode_menu() then return true end
    if type(group_name) ~= "string" or type(files) ~= "table" then return false end
    local fm = get_file_manager()
    if not (fm and fm.file_chooser and fm.file_chooser.showFileDialog) then
        return false
    end
    local hide_actions = type(options) == "table" and options.hide_actions == true
    fm.file_chooser:showFileDialog({
        _zen_group_files = files,
        _zen_group_name = group_name,
        _zen_sort_cb = not hide_actions and function()
            showDetailSortDialog(group_name, tab_id, nil, files)
        end or nil,
        _zen_display_cb = not hide_actions and function()
            showDisplayModeDialog(menu, tab_id, group_name)
        end or nil,
    })
    return true
end

function M.showSourceContextMenu(tab_id, menu, options)
    if show_select_mode_menu() then return true end
    options = type(options) == "table" and options or {}
    local fm = get_file_manager()
    if not (fm and fm.file_chooser and fm.file_chooser.showFileDialog) then
        return false
    end

    local _ = require("gettext")
    if tab_id == "to_be_read" then
        local files = options.files
        if type(files) ~= "table" then
            local ok_index, tbr_index = pcall(require, "common/tbr_index")
            if not ok_index or type(tbr_index.getAll) ~= "function" then return false end
            files = tbr_index.getAll({
                include_new = book_status.includeNewInTBREnabled(),
                collate = get_detail_collate(tab_id, tab_id, "title"),
                reverse = get_detail_reverse(tab_id, tab_id, false),
            })
            files = apply_status_filter(files)
        end
        local count = tonumber(options.item_count) or #files
        fm.file_chooser:showFileDialog({
            _zen_group_files = files,
            _zen_group_name = _("To Be Read"),
            _zen_group_subtitle = count == 1 and _("1 book")
                or (tostring(count) .. " " .. _("books")),
            _zen_sort_cb = options.sort_cb or function()
                showDetailSortDialog(tab_id, tab_id, menu, files)
            end,
            _zen_display_cb = function()
                showDisplayModeDialog(menu, tab_id)
            end,
        })
        return true
    end

    if tab_id ~= "authors" and tab_id ~= "series"
            and tab_id ~= "languages" and tab_id ~= "tags" then
        return false
    end
    local label = tab_id == "authors" and _("Authors")
        or tab_id == "languages" and _("Languages")
        or tab_id == "tags" and _("Tags") or _("Series")
    local count = tonumber(options.item_count)
    if not count then
        local ok_db, db = pcall(require, "common/db_bookinfo")
        if not ok_db or not db then return false end
        local groups = tab_id == "authors" and db.getGroupedByAuthor()
            or tab_id == "languages" and db.getGroupedByLanguage()
            or tab_id == "tags" and db.getGroupedByTags()
            or db.getGroupedBySeries()
        count = type(groups) == "table" and #groups or 0
    end
    local subtitle
    if tab_id == "authors" then
        subtitle = count == 1 and _("1 author")
            or (tostring(count) .. " " .. _("authors"))
    elseif tab_id == "languages" then
        subtitle = count == 1 and _("1 language")
            or (tostring(count) .. " " .. _("languages"))
    elseif tab_id == "tags" then
        subtitle = count == 1 and _("1 tag")
            or (tostring(count) .. " " .. _("tags"))
    else
        subtitle = count == 1 and _("1 series")
            or (tostring(count) .. " " .. _("series"))
    end
    fm.file_chooser:showFileDialog({
        _zen_group_files = {},
        _zen_group_name = label,
        _zen_group_subtitle = subtitle,
        _zen_sort_cb = function() showGroupSortDialog(tab_id, menu) end,
        _zen_display_cb = function() showDisplayModeDialog(menu, tab_id) end,
    })
    return true
end

showGroupView = function(tab_id, injectNavbar, groups)
    local active_menu = get_root_menu(tab_id)
    if active_menu then return active_menu, false end
    local _ = require("gettext")
    local UIManager = require("ui/uimanager")

    local title
    if tab_id == "authors" then
        title = _("Authors")
    elseif tab_id == "languages" then
        title = _("Languages")
    elseif tab_id == "tags" then
        title = _("Tags")
    else
        title = _("Series")
    end
    local item_table = build_group_item_table(groups, tab_id)
    -- No up-folder at the root group list level.

    local menu = StandalonePage.create_menu{
        name = tab_id,
        title = title,
        item_table = item_table,
        onMenuSelect = function(menu_self, item)
            if item.is_go_up then
                if menu_self.close_callback then menu_self.close_callback()
                else UIManager:close(menu_self) end
                return
            end
            if item._zen_files then
                showDetailView(item, injectNavbar, tab_id)
            end
        end,
        onMenuHold = function(menu_self, item)
            if item._zen_files then
                return M.showGroupContextMenu(
                    item.text, item._zen_files, tab_id, menu_self)
            end
            return show_select_mode_menu()
        end,
        updateItems = function() end,
    }
    StandalonePage.prepare_shell(menu)

    -- Install display mode (mosaic/list) and set _zen_group_view sentinel
    local mode_type = setup_display_mode(menu, true, tab_id)
    -- For classic mode (no CoverBrowser), restore the base updateItems
    if mode_type == "classic" or not mode_type then
        local Menu_class = require("ui/widget/menu")
        menu.updateItems = Menu_class.updateItems
    end

    menu.close_callback = function()
        UIManager:close(menu)
        clear_root_menu(tab_id, menu)
    end
    menu._zen_library_bg_reopen = function()
        return reopen_root_view(tab_id, injectNavbar)
    end
    local orig_group_on_close_widget = menu.onCloseWidget
    function menu:onCloseWidget(...)
        clear_root_menu(tab_id, self)
        if orig_group_on_close_widget then
            return orig_group_on_close_widget(self, ...)
        end
    end

    clean_nav(menu, title)

    if injectNavbar then
        injectNavbar(menu, tab_id)
    end

    if tab_id == "authors" then
        _authors_menu = menu
    elseif tab_id == "languages" then
        _languages_menu = menu
    elseif tab_id == "tags" then
        _tags_menu = menu
    else
        _series_menu = menu
    end

    -- Add blank-space hold gesture handler for context menu
    local Device2 = require("device")
    if Device2:isTouchDevice() then
        local GestureRange = require("ui/gesturerange")
        local Geom         = require("ui/geometry")
        if not menu.ges_events then
            menu.ges_events = {}
        end
        menu.ges_events.ZenGroupBlankHold = {
            GestureRange:new{
                ges   = "hold",
                range = Geom:new{
                    x = 0, y = 0,
                    w = Device2.screen:getWidth(),
                    h = Device2.screen:getHeight(),
                },
            },
        }
        function menu:onZenGroupBlankHold(arg, ges)
            return M.showSourceContextMenu(tab_id, self, {
                item_count = self.item_table and #self.item_table or 0,
            })
        end
    end

    UIManager:show(menu)
    -- updateItems was stubbed during Menu:new to skip the premature init-time call.
    -- Trigger the real render now via nextTick, after the menu has been dimensioned.
    UIManager:nextTick(function()
        -- Restore page if returning from reader
        local state = rawget(_G, "__ZEN_UI_LIBRARY_STATE")
        local restore_detail = state and state.tab == tab_id and state.detail_group
        if state and state.tab == tab_id then
            menu.page = state.page or 1
        end
        if not restore_detail then
            _G.__ZEN_UI_LIBRARY_STATE = nil
        end
        menu:updateItems()
        -- Re-inject status row after updateItems (it may reset title_group).
        local createSR2 = _zen_shared and _zen_shared.createStatusRow
        local repaintTB2 = _zen_shared and _zen_shared.repaintTitleBar
        local tb2 = menu.title_bar
        if tb2 and createSR2 and tb2.title_group and #tb2.title_group >= 2 then
            local FileManager2 = require("apps/filemanager/filemanager")
            tb2.title_group[2] = createSR2(nil, FileManager2.instance)
            tb2.title_group:resetLayout()
            if repaintTB2 then repaintTB2(tb2) end
        end
        -- Re-open the specific group folder that was open before reader.
        -- Guard: showFiles post-hook may have already opened it synchronously.
        if restore_detail then
            local detail_name = state.detail_group
            local already_open = false
            for _i, dm in ipairs(_detail_menus) do
                if dm._zen_group_name == detail_name then already_open = true; break end
            end
            if not already_open then
                UIManager:nextTick(function()
                    for _i, item in ipairs(item_table) do
                        if item.text == detail_name and item._zen_files then
                            showDetailView(item, injectNavbar, tab_id)
                            break
                        end
                    end
                end)
            end
        end
    end)
    return menu, true
end

-------------------------------------------------------------------------------
-- Public API called by navbar.lua tab callbacks
-------------------------------------------------------------------------------
function M.showAuthorsView(injectNavbar)
    if _authors_menu then return _authors_menu, false end
    refresh_shared_state()
    local ok, db = pcall(require, "common/db_bookinfo")
    if not ok then return end
    local groups = db.getGroupedByAuthor()
    return showGroupView("authors", injectNavbar, groups)
end

function M.showSeriesView(injectNavbar)
    if _series_menu then return _series_menu, false end
    refresh_shared_state()
    local ok, db = pcall(require, "common/db_bookinfo")
    if not ok then return end
    local groups = db.getGroupedBySeries()
    return showGroupView("series", injectNavbar, groups)
end

function M.showLanguagesView(injectNavbar)
    if _languages_menu then return _languages_menu, false end
    refresh_shared_state()
    local ok, db = pcall(require, "common/db_bookinfo")
    if not ok then return end
    local groups = db.getGroupedByLanguage()
    return showGroupView("languages", injectNavbar, groups)
end

function M.showTagsView(injectNavbar)
    if _tags_menu then return _tags_menu, false end
    refresh_shared_state()
    local ok, db = pcall(require, "common/db_bookinfo")
    if not ok then return end
    local groups = db.getGroupedByTags()
    return showGroupView("tags", injectNavbar, groups)
end

-- Opens one tag directly, for custom navbar tabs that target a specific tag.
function M.showTagDetail(tag_name, injectNavbar, navbar_tab_id)
    if type(tag_name) ~= "string" or tag_name == "" then return end
    refresh_shared_state()
    local ok, db = pcall(require, "common/db_bookinfo")
    if not ok then return end
    local files = type(db.getTagBooks) == "function" and db.getTagBooks(tag_name) or {}
    return showDetailView(
        { text = tag_name, _zen_files = files }, injectNavbar, "tags", navbar_tab_id)
end

function M.showStatusView(status, label, injectNavbar, navbar_tab_id)
    if type(status) ~= "string" or status == "" then return end
    refresh_shared_state()
    local ok, index = pcall(require, "common/tbr_index")
    if not ok or type(index.getByStatuses) ~= "function" then return end
    return showDetailView({
        text = label or status,
        _zen_load_files = function()
            return index.getByStatuses({ [status] = true })
        end,
    }, injectNavbar, "status", navbar_tab_id)
end

-------------------------------------------------------------------------------
-- M.showTBRView: flat view of the To Be Read collection plus optional new books
-------------------------------------------------------------------------------
function M.showTBRView(injectNavbar)
    local _          = require("gettext")
    local UIManager  = require("ui/uimanager")
    if _tbr_menu then
        if UIManager:isWidgetShown(_tbr_menu) then return _tbr_menu, false end
        _tbr_menu = nil
    end
    refresh_shared_state()

    local tab_id     = "to_be_read"
    local SORT_GROUP = "to_be_read"
    local group_name = _("To Be Read")

    local cur_collate = get_detail_collate(tab_id, SORT_GROUP, "title")
    local cur_reverse = get_detail_reverse(tab_id, SORT_GROUP, false)

    local ok_index, tbr_index = pcall(require, "common/tbr_index")
    if not ok_index or type(tbr_index.getAll) ~= "function" then return end

    local function loadFiles()
        local loaded = tbr_index.getAll({
            include_new = book_status.includeNewInTBREnabled(),
            collate = cur_collate,
            reverse = cur_reverse,
        })
        return apply_status_filter(loaded)
    end

    local files = loadFiles()
    local menu
    local buildItems

    local function refreshCollectionView()
        cur_collate = get_detail_collate(tab_id, SORT_GROUP, "title")
        cur_reverse = get_detail_reverse(tab_id, SORT_GROUP, false)
        tbr_index.collectionChanged(tbr_index.collectionName())
        files = loadFiles()
        if menu then
            local refreshed = buildItems(files)
            if should_show_up_folder() then
                table.insert(refreshed, 1,
                    { text = "\u{2B06} ..", is_go_up = true, mandatory = "" })
            end
            menu.item_table = refreshed
            menu:updateItems()
        end
    end

    buildItems = function(flist)
        local lfs_mod  = require("libs/libkoreader-lfs")
        local util_mod = require("util")
        local items = {}
        for _i, fpath in ipairs(flist) do
            local fname   = fpath:match("([^/]+)$") or fpath
            local display = fname:gsub("%.[^%.]+$", "")
            local attr = lfs_mod.attributes(fpath)
            table.insert(items, {
                text      = display,
                path      = fpath,
                filepath  = fpath,
                is_file   = true,
                dim       = is_file_selected(fpath),
                mandatory = attr and util_mod.getFriendlySize(attr.size or 0) or "",
                _zen_collection_name = tbr_index.isExplicit(fpath)
                    and tbr_index.collectionName() or nil,
                _zen_collection_refresh = refreshCollectionView,
            })
        end
        if #items == 0 then
            table.insert(items, {
                text                   = group_empty_message(tab_id),
                dim                    = true,
                callback               = function() end,
                _zen_empty_placeholder = true,
            })
        end
        return items
    end

    local items = buildItems(files)
    if should_show_up_folder() then
        table.insert(items, 1, { text = "\u{2B06} ..", is_go_up = true, mandatory = "" })
    end

    menu = StandalonePage.create_menu{
        name = "to_be_read",
        title = group_name,
        item_table = items,
        onMenuSelect = function(menu_self, item)
            if item.is_go_up then
                if menu_self.close_callback then menu_self.close_callback()
                else UIManager:close(menu_self) end
                return
            end
            if item.path then
                if toggle_file_selection(menu_self, item) then return end
                local fm = get_file_manager()
                local fmu = require("apps/filemanager/filemanagerutil")
                if fmu.openFile then
                    fmu.openFile(fm, item.path)
                elseif fm then
                    fm:openFile(item.path)
                end
            end
        end,
        onMenuHold = function(menu_self, item)
            if show_select_mode_menu() then return true end
            if not item.path then return end
            local fm = get_file_manager()
            if fm and fm.file_chooser and fm.file_chooser.showFileDialog then
                show_file_dialog_with_refresh(fm.file_chooser, menu_self, {
                    path    = item.path,
                    is_file = true,
                    text    = item.text,
                    _zen_select_cb = function()
                        return toggle_file_selection(menu_self, item)
                    end,
                    _zen_collection_name = item._zen_collection_name,
                    _zen_collection_refresh = item._zen_collection_refresh,
                })
            end
        end,
        updateItems = function() end,
    }
    StandalonePage.prepare_shell(menu)

    -- Tag TBR as a library menu for Zen's renderer and preload pipeline.
    menu._zen_tab_id = tab_id
    menu._zen_tbr_refresh = refreshCollectionView

    local mode_type = setup_display_mode(menu, true, tab_id)
    if mode_type == "classic" or not mode_type then
        local Menu_class = require("ui/widget/menu")
        menu.updateItems = Menu_class.updateItems
    end

    menu.close_callback = function()
        UIManager:close(menu)
        clear_root_menu(tab_id, menu)
    end
    menu._zen_library_bg_reopen = function()
        return reopen_root_view(tab_id, injectNavbar)
    end
    local orig_tbr_on_close_widget = menu.onCloseWidget
    function menu:onCloseWidget(...)
        clear_root_menu(tab_id, self)
        if orig_tbr_on_close_widget then
            return orig_tbr_on_close_widget(self, ...)
        end
    end

    clean_nav(menu, group_name)

    if injectNavbar then
        injectNavbar(menu, tab_id)
    end

    _tbr_menu = menu

    local Device_tbr = require("device")
    if Device_tbr:isTouchDevice() then
        local GestureRange_tbr = require("ui/gesturerange")
        local Geom_tbr         = require("ui/geometry")
        if not menu.ges_events then
            menu.ges_events = {}
        end
        menu.ges_events.ZenTBRBlankHold = {
            GestureRange_tbr:new{
                ges   = "hold",
                range = Geom_tbr:new{
                    x = 0, y = 0,
                    w = Device_tbr.screen:getWidth(),
                    h = Device_tbr.screen:getHeight(),
                },
            },
        }
        function menu:onZenTBRBlankHold(arg, ges)
            return M.showSourceContextMenu(tab_id, self, {
                files = files,
                item_count = self.item_table and #self.item_table or 0,
                sort_cb = function()
                    showDetailSortDialog(SORT_GROUP, tab_id, self, files,
                        function(collate, reverse)
                            cur_collate, cur_reverse = collate, reverse
                            files = loadFiles()
                            return files
                        end)
                end,
            })
        end
    end

    UIManager:show(menu)
    UIManager:nextTick(function()
        -- Restore page if returning from reader
        local state = rawget(_G, "__ZEN_UI_LIBRARY_STATE")
        if state and state.tab == "to_be_read" and state.page and state.page > 1 then
            menu.page = state.page
            _G.__ZEN_UI_LIBRARY_STATE = nil
        end
        menu:updateItems()
        local createSR2  = _zen_shared and _zen_shared.createStatusRow
        local repaintTB2 = _zen_shared and _zen_shared.repaintTitleBar
        local tb2 = menu.title_bar
        if tb2 and createSR2 and tb2.title_group and #tb2.title_group >= 2 then
            local FileManager2 = require("apps/filemanager/filemanager")
            tb2.title_group[2] = createSR2(nil, FileManager2.instance)
            tb2.title_group:resetLayout()
            if repaintTB2 then repaintTB2(tb2) end
        end
    end)
    return menu, true
end

function M.refreshTBRView()
    local UIManager = require("ui/uimanager")
    if not (_tbr_menu and UIManager:isWidgetShown(_tbr_menu)
            and type(_tbr_menu._zen_tbr_refresh) == "function") then
        _tbr_menu = nil
        return false
    end
    _tbr_menu._zen_tbr_refresh()
    return true
end

-- Open a detail view synchronously by group name (used by navbar.showFiles post-hook).
-- Called after showGroupView so the root group menu is already set.
function M.restoreDetail(group_name, tab_id, injectNavbar_fn)
    refresh_shared_state()
    local menu
    if tab_id == "authors" then
        menu = _authors_menu
    elseif tab_id == "languages" then
        menu = _languages_menu
    elseif tab_id == "tags" then
        menu = _tags_menu
    else
        menu = _series_menu
    end
    if not menu or not menu.item_table then return end
    for _i, item in ipairs(menu.item_table) do
        if item.text == group_name and item._zen_files then
            return showDetailView(item, injectNavbar_fn, tab_id)
        end
    end
end

-- Return the top-most open detail view info (group name, tab, page)
function M.getActiveDetail()
    if #_detail_menus > 0 then
        local m = _detail_menus[#_detail_menus]
        return { group_name = m._zen_group_name, tab_id = m._zen_tab_id, page = m.page or 1 }
    end
end

-- Return the current page of a group menu (for state save on reader open)
function M.getActivePage(tab_id)
    if tab_id == "authors" and _authors_menu then
        return _authors_menu.page
    elseif tab_id == "series" and _series_menu then
        return _series_menu.page
    elseif tab_id == "languages" and _languages_menu then
        return _languages_menu.page
    elseif tab_id == "to_be_read" and _tbr_menu then
        return _tbr_menu.page
    elseif tab_id == "tags" and _tags_menu then
        return _tags_menu.page
    end
end

-- Close all open group/detail menus to prevent UIManager stack pollution
function M.closeAll()
    local UIManager2 = require("ui/uimanager")
    for _i, m in ipairs(_detail_menus) do
        UIManager2:close(m)
    end
    _detail_menus = {}
    if _authors_menu then UIManager2:close(_authors_menu); _authors_menu = nil end
    if _series_menu  then UIManager2:close(_series_menu);  _series_menu  = nil end
    if _languages_menu then UIManager2:close(_languages_menu); _languages_menu = nil end
    if _tbr_menu     then UIManager2:close(_tbr_menu);     _tbr_menu     = nil end
    if _tags_menu    then UIManager2:close(_tags_menu);    _tags_menu    = nil end
end

local function register_group_view_api(zen_plugin)
    if not zen_plugin or type(zen_plugin.config) ~= "table" then return end
    _zen_shared  = SharedState.register(zen_plugin, { group_view = M })
    _zen_plugin  = zen_plugin  -- keep reference; __ZEN_UI_PLUGIN is cleared after init
end

SharedState.registerLoader("group_view", register_group_view_api)

return function()
    register_group_view_api(rawget(_G, "__ZEN_UI_PLUGIN"))
end
