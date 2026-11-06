local function apply_context_menu()
    --[[
        Replaces the long-hold file/folder context menu with a minimal layout.
        Always active; delegates to stock KOReader outside themed directories.
    ]]

    local BD           = require("ui/bidi")
    local ButtonDialog = require("ui/widget/buttondialog")
    local Device       = require("device")
    local FileChooser  = require("ui/widget/filechooser")
    local FileManager  = require("apps/filemanager/filemanager")
    local PathChooser  = require("ui/widget/pathchooser")
    local UIManager    = require("ui/uimanager")
    local getFullRefreshMode = require("common/ui/refresh")
    local _            = require("gettext")
    local C_           = _.pgettext
    local archive_actions = require("common/archive_actions")
    local book_status  = require("common/book_status")
    local ConfigManager = require("config/manager")
    local FolderCoverFiles = require("common/folder_cover_files")
    local BookWalker   = require("common/book_walker")
    local paths        = require("common/paths")
    local SharedState  = require("common/shared_state")
    local icons        = require("common/inline_icon_map")
    local submenu_arrow = icons.arrow_right
    local zen_plugin   = rawget(_G, "__ZEN_UI_PLUGIN")
    local Cover        = require("common/cover_utils")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local LeftContainer   = require("ui/widget/container/leftcontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local TextWidget      = require("ui/widget/textwidget")
    local Geom            = require("ui/geometry")
    local library_font    = require("modules/filebrowser/patches/library_font")

    local function archive_context_row(fm, file, is_file)
        local config = zen_plugin and zen_plugin.config
        local context_menu = type(config) == "table" and config.context_menu
        if type(context_menu) ~= "table" or context_menu.show_archive ~= true then return end
        return archive_actions.contextRow(fm, file, is_file)
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
                        btn.text_font_face = face
                        btn.text_font_size = fsize
                    end
                end
            end
        end
        return button_rows
    end

    local function new_context_menu_dialog(options)
        local dialog = ButtonDialog:new(options)
        local cover = options._zen_cover_widget
        -- Mono panels already show the cover cleanly; only color needs the extra flash.
        if cover and Device.screen:isColorScreen() then
            local orig_onShow = dialog.onShow
            function dialog:onShow()
                orig_onShow(self)
                -- Wait for the opening repaint so only the cover flashes.
                UIManager:tickAfterNext(function()
                    if UIManager:getTopmostVisibleWidget() == self then
                        UIManager:setDirty(nil, getFullRefreshMode(), cover.dimen, true)
                    end
                end)
            end
        end
        return dialog
    end

    -- Keep every PathChooser navigable above a locked home folder.
    if not PathChooser._zen_navigation_patched
            and type(PathChooser.genItemTableFromPath) == "function" then
        PathChooser._zen_navigation_patched = true
        local orig_pathchooser_gen_items = PathChooser.genItemTableFromPath

        function PathChooser:genItemTableFromPath(path)
            local items, readable = orig_pathchooser_gen_items(self, path)
            local parent = type(path) == "string" and require("ffi/util").dirname(path)
            if type(parent) ~= "string" or parent == path then
                return items, readable
            end
            for _i, item in ipairs(items) do
                if item.is_go_up then return items, readable end
            end
            table.insert(items, self.show_current_dir_for_hold and 2 or 1, {
                text = BD.mirroredUILayout() and BD.ltr("../ \u{2B06}") or "\u{2B06} ../",
                path = path .. "/..",
                is_go_up = true,
            })
            return items, readable
        end
    end

    -- Keep path-keyed settings and cover references aligned with successful moves.
    local orig_FileManager_moveFile = FileManager.moveFile
    FileManager.moveFile = function(self, from, to, ...)
        local ffiUtil = require("ffi/util")
        local lfs = require("libs/libkoreader-lfs")
        local source = ffiUtil.realpath(from) or from
        local source_is_directory = lfs.attributes(source, "mode") == "directory"
        local destination = to
        if lfs.attributes(to, "mode") == "directory" then
            destination = ffiUtil.joinPath(to, ffiUtil.basename(source))
        end

        local moved = orig_FileManager_moveFile(self, from, to, ...)
        if moved then
            destination = ffiUtil.realpath(destination) or destination
            pcall(ConfigManager.movePathSettings, source, destination)
            pcall(function()
                require("common/tbr_index").moveOrderPath(
                    source, destination, source_is_directory)
            end)
        end
        if moved then
            UIManager:nextTick(function()
                local plug = zen_plugin or rawget(_G, "__ZEN_UI_PLUGIN")
                local home = plug and SharedState.get(plug, "home")
                if home and type(home.invalidateBookCache) == "function" then
                    home.invalidateBookCache(from, true)
                end
                if home and type(home.invalidateLibraryCache) == "function" then
                    home.invalidateLibraryCache()
                end
            end)
        end
        return moved
    end

    -- MoveChooser
    local MoveChooser = PathChooser:extend{
        _zen_no_forced_repaint = true,
        _zen_renderer = true,
    }

    local function under_root(path, root)
        return type(root) == "string" and root:sub(1, 1) == "/"
            and (root == "/" or path == root
                or path:sub(1, #root + 1) == root .. "/")
    end

    local function in_move_roots(self, path)
        local ffiUtil = require("ffi/util")
        local real = path and ffiUtil.realpath(path)
        if not real then return false end
        local roots = self._zen_move_roots
        if not roots then
            roots = {}
            if self.home_root then
                roots[#roots + 1] = ffiUtil.realpath(self.home_root) or self.home_root
            end
            for _i, root in ipairs(self.extra_roots or {}) do
                roots[#roots + 1] = ffiUtil.realpath(root) or root
            end
            self._zen_move_roots = roots
        end
        for _i, root in ipairs(roots) do
            if under_root(real, root) then return true end
        end
        return false
    end

    function MoveChooser:changeToPath(path, ...)
        if in_move_roots(self, path) then
            return PathChooser.changeToPath(self, path, ...)
        end
    end

    function MoveChooser:genItemTableFromPath(path)
        local ffiUtil3 = require("ffi/util")
        local lfs3     = require("libs/libkoreader-lfs")
        local BD3      = require("ui/bidi")
        local root     = ffiUtil3.realpath(path) or path
        local MAX_DEPTH = 3
        local items    = {}
        local parent = ffiUtil3.dirname(root)
        if not in_move_roots(self, root) then return items, true end

        if parent and parent ~= root and in_move_roots(self, parent) then
            table.insert(items, {
                text = BD3.mirroredUILayout() and BD3.ltr("../ \u{2B06}") or "\u{2B06} ../",
                path = parent,
                is_go_up = true,
            })
        end

        if not self.src_dir or self.src_dir ~= root then
            table.insert(items, {
                text           = ffiUtil3.basename(root),
                path           = root,
                is_file        = false,
                is_directory   = true,
                bidi_wrap_func = BD3.directory,
                mandatory      = self:getMenuItemMandatory({ path = root }),
            })
        end

        local function scan(dir_path, depth, base, prefix, skip_set)
            base = base or root
            local ok3, iter3, dir_obj3 = pcall(lfs3.dir, dir_path)
            if not ok3 then return end
            local subdirs = {}
            for fname in iter3, dir_obj3 do
                if fname ~= "." and fname ~= ".."
                        and not fname:match("^%.")
                        and not BookWalker.shouldSkipDir(dir_path, fname)
                        and self:show_dir(fname) then
                    local fpath = dir_path == "/" and "/" .. fname
                        or dir_path .. "/" .. fname
                    if lfs3.attributes(fpath, "mode") == "directory" then
                        table.insert(subdirs, { name = fname, path = fpath })
                    end
                end
            end
            table.sort(subdirs, function(a, b) return a.name < b.name end)
            for _i, sub in ipairs(subdirs) do
                local sub_real = ffiUtil3.realpath(sub.path) or sub.path
                if in_move_roots(self, sub_real)
                        and not (skip_set and skip_set[sub_real]) then
                    local rel = sub.path:sub(#base + 2)
                    local display = prefix and (prefix .. "/" .. rel) or rel
                    table.insert(items, {
                        text           = display,
                        path           = sub.path,
                        is_file        = false,
                        is_directory   = true,
                        bidi_wrap_func = BD3.directory,
                        mandatory      = self:getMenuItemMandatory({ path = sub.path }),
                    })
                    if depth < MAX_DEPTH then
                        scan(sub.path, depth + 1, base, prefix, skip_set)
                    end
                end
            end
        end

        scan(root, 1)

        local home = self.home_root and ffiUtil3.realpath(self.home_root)
        if home and not under_root(root, home) then
            table.insert(items, {
                text           = _("Home") .. ": " .. ffiUtil3.basename(home),
                path           = home,
                is_go_up       = true,
                is_file        = false,
                is_directory   = true,
                bidi_wrap_func = BD3.directory,
                mandatory      = self:getMenuItemMandatory({ path = home }),
            })
        end

        if type(self.extra_roots) == "table" then
            local skip_set = { [root] = true }
            for _i, er_path in ipairs(self.extra_roots) do
                local er = ffiUtil3.realpath(er_path) or er_path
                skip_set[er] = true
            end

            for _i, er_path in ipairs(self.extra_roots) do
                local er = ffiUtil3.realpath(er_path) or er_path
                if er ~= root and in_move_roots(self, er) then
                    local er_name = ffiUtil3.basename(er)
                    if not self.src_dir or self.src_dir ~= er then
                        table.insert(items, {
                            text           = er_name,
                            path           = er,
                            is_file        = false,
                            is_directory   = true,
                            bidi_wrap_func = BD3.directory,
                            mandatory      = self:getMenuItemMandatory({ path = er }),
                        })
                    end
                    scan(er, 1, er, er_name, skip_set)
                end
            end
        end

        return items, true
    end

    function MoveChooser:onMenuSelect(item)
        local path = item and item.path
        if not path then return true end
        local ffiUtil2 = require("ffi/util")
        local real = ffiUtil2.realpath(path)
        if not in_move_roots(self, real) then return true end
        local lfs2 = require("libs/libkoreader-lfs")
        if lfs2.attributes(real, "mode") == "directory" then
            if item.is_go_up then
                self:changeToPath(real)
            else
                if self.onConfirm then self.onConfirm(real) end
                UIManager:close(self)
            end
        end
        return true
    end

    function MoveChooser:onMenuHold(item)
        local path = item and item.path
        if in_move_roots(self, path)
                and require("libs/libkoreader-lfs").attributes(path, "mode") == "directory" then
            self:changeToPath(path)
        end
        return true
    end

    function MoveChooser:init()
        self.height = Device.screen:getHeight()
        local CoverMenu = require("covermenu")
        local MosaicMenu = require("mosaicmenu")
        self.display_mode_type = "mosaic"
        self.updateItems = CoverMenu.updateItems
        self.onCloseWidget = CoverMenu.onCloseWidget
        self._recalculateDimen = MosaicMenu._recalculateDimen
        self._updateItemsBuildUI = MosaicMenu._updateItemsBuildUI
        self._do_cover_images = false
        self._do_center_partial_rows = false
        PathChooser.init(self)
        local tb = self.title_bar
        if tb and tb.has_left_icon then
            tb:clear()
            tb.left_icon = nil
            tb.has_left_icon = false
            tb.left_button = nil
            tb:init()
        end
        local close_icon = tb and tb.right_button and tb.right_button.image
        if close_icon then
            close_icon.alpha = true
            close_icon:free()
        end
    end

    local orig_setupLayout = FileManager.setupLayout

    if type(FileChooser.show_file) == "function" and not FileChooser._zen_status_filter_patched then
        local orig_show_file = FileChooser.show_file
        local orig_getList = FileChooser.getList
        FileChooser._zen_status_filter_patched = true

        function FileChooser:show_file(filename, fullpath)
            if self.name == "filemanager" and FolderCoverFiles.isManaged(filename) then
                return false
            end
            if self.name ~= "filemanager" then
                return orig_show_file(self, filename, fullpath)
            end

            local status_filter = FileChooser.show_filter and FileChooser.show_filter.status
            if not status_filter or fullpath == nil then
                return orig_show_file(self, filename, fullpath)
            end

            local saved_status_filter = FileChooser.show_filter.status
            FileChooser.show_filter.status = nil
            local ok_show, should_show = pcall(orig_show_file, self, filename, fullpath)
            FileChooser.show_filter.status = saved_status_filter
            if not ok_show or not should_show then
                return false
            end

            local display_status = book_status.getDisplayStatusFromFile(fullpath)
            return status_filter[display_status] and true or false
        end

        if type(orig_getList) == "function" then
            function FileChooser:getList(path, collate)
                local dirs, files, readable = orig_getList(self, path, collate)
                local status_filter = FileChooser.show_filter and FileChooser.show_filter.status
                if self.name == "filemanager" and collate and status_filter then
                    for index = #dirs, 1, -1 do
                        local mandatory = dirs[index] and dirs[index].mandatory
                        local count = type(mandatory) == "string"
                            and tonumber(mandatory:match("(%d+)%s*" .. icons.file_count))
                        if count == 0 then table.remove(dirs, index) end
                    end
                end
                return dirs, files, readable
            end
        end
    end

    local orig_copyFile = FileManager.copyFile
    local orig_cutFile = FileManager.cutFile
    function FileManager:copyFile(file)
        self._zen_selected_clipboard = nil
        return orig_copyFile(self, file)
    end
    function FileManager:cutFile(file)
        self._zen_selected_clipboard = nil
        return orig_cutFile(self, file)
    end

    local function selected_files_copy(files)
        local copy = {}
        local ffiUtil = require("ffi/util")
        for file, selected in pairs(files or {}) do
            if selected then copy[ffiUtil.realpath(file) or file] = true end
        end
        return copy
    end

    local function paste_selected_files(file_manager, folder)
        local pending = file_manager._zen_selected_clipboard
        if not pending or not next(pending.files) then return end
        if folder and require("libs/libkoreader-lfs").attributes(folder, "mode") == "file" then
            folder = require("ffi/util").dirname(folder)
        end
        local ConfirmBox = require("ui/widget/confirmbox")
        local CheckButton = require("ui/widget/checkbutton")
        local check_button
        local confirmbox = ConfirmBox:new{
            text = pending.cut and _("Move selected files?") or _("Copy selected files?"),
            ok_text = pending.cut and _("Move") or C_("File", "Copy"),
            ok_callback = function()
                local previous = file_manager.selected_files
                if not previous then file_manager:onToggleSelectMode() end
                file_manager.selected_files = selected_files_copy(pending.files)
                file_manager.cutfile = pending.cut
                file_manager:pasteSelectedFiles(check_button.checked, folder)
                pending.files = selected_files_copy(file_manager.selected_files)
                if not next(pending.files) then file_manager._zen_selected_clipboard = nil end
                if previous then
                    if not file_manager.selected_files then file_manager:onToggleSelectMode() end
                    file_manager.selected_files = previous
                    file_manager.file_chooser:refreshPath()
                elseif file_manager.selected_files then
                    file_manager:onToggleSelectMode(true)
                end
            end,
        }
        check_button = CheckButton:new{
            text = _("overwrite existing files"),
            checked = false,
            parent = confirmbox,
        }
        confirmbox:addWidget(check_button)
        UIManager:show(confirmbox)
    end
    FileManager.pasteSelectedFilesFromZenClipboard = paste_selected_files

    local function show_collection_picker(files, on_done)
        local ReadCollection = require("readcollection")
        local TBRIndex = require("common/tbr_index")
        local Menu = require("ui/widget/menu")
        local names = {}
        for name in pairs(ReadCollection.coll) do names[#names + 1] = name end
        table.sort(names, function(a, b)
            if a == ReadCollection.default_collection_name then return true end
            if b == ReadCollection.default_collection_name then return false end
            return a < b
        end)
        local items = {}
        for _i, name in ipairs(names) do
            local already_in = true
            for file in pairs(files) do
                if not ReadCollection:isFileInCollection(file, name) then
                    already_in = false
                    break
                end
            end
            items[#items + 1] = {
                text = (name == ReadCollection.default_collection_name and _("Favorites") or name)
                    .. (already_in and "  " .. icons.check or ""),
                mandatory = already_in and _("added") or nil,
                dim = already_in,
                _cn = name,
            }
        end
        local picker
        picker = Menu:new{
            title = _("Add to collection"),
            item_table = items,
            is_borderless = true,
            is_popout = false,
            onMenuSelect = function(_self_m, picked)
                if picked.dim then return true end
                UIManager:close(picker)
                if picked._cn == TBRIndex.collectionName() then
                    for file in pairs(files) do TBRIndex.setExplicit(file, true) end
                else
                    ReadCollection:addItemsMultiple(files, { [picked._cn] = true })
                    ReadCollection:write({ [picked._cn] = true })
                end
                pcall(TBRIndex.collectionChanged, picked._cn)
                if on_done then on_done() end
                return true
            end,
            close_callback = function() UIManager:close(picker) end,
        }
        UIManager:show(picker)
    end

    local function set_selected_status(files, status)
        local DocSettings = require("docsettings")
        local BookList = require("ui/widget/booklist")
        local filemanagerutil = require("apps/filemanager/filemanagerutil")
        local TBRIndex = require("common/tbr_index")
        for file in pairs(files) do
            if status == "tbr" then
                TBRIndex.setExplicit(file, true)
            else
                local doc_settings = DocSettings:open(file)
                local summary = doc_settings:readSetting("summary") or {}
                book_status.acknowledgeNewVersion(doc_settings)
                TBRIndex.setExplicit(file, false)
                summary.status = status
                if status == nil then
                    doc_settings:delSetting("percent_finished")
                    doc_settings:delSetting("last_page")
                    doc_settings:delSetting("last_xpointer")
                end
                filemanagerutil.saveSummary(doc_settings, summary)
                BookList.setBookInfoCacheProperty(file, "status", status)
                book_status.invalidate(file)
                TBRIndex.refreshPath(file, doc_settings)
                if status == nil then
                    local pages = BookList.book_info_cache and BookList.book_info_cache[file]
                        and BookList.book_info_cache[file].pages
                    BookList.setBookInfoCacheProperty(file, "been_opened", false)
                    if pages then BookList.book_info_cache[file].pages = pages end
                end
            end
        end
    end

    FileManager.setupLayout = function(self)
        orig_setupLayout(self)
        FileManager.setupZenContextMenu(self)
    end

    function FileManager:setupZenContextMenu()
        local file_chooser = self.file_chooser
        local file_manager = self
        local logger = require("common/zen_logger").new("context_menu")
        local ffiUtil_sel = require("ffi/util")

        local orig_showFileDialog = file_chooser.showFileDialog
        local orig_onFileSelect = file_chooser.onFileSelect

        local function show_selected_actions()
            local files = selected_files_copy(file_manager.selected_files)
            local items = {}
            for file in pairs(files) do
                items[#items + 1] = { path = file, is_file = true }
            end
            table.sort(items, function(a, b) return a.path < b.path end)
            local count = #items
            local title = count == 1 and _("1 file")
                or require("ffi/util").template(_("%1 files"), count)
            local enabled = count > 0
            local context_menu = zen_plugin and zen_plugin.config
                and zen_plugin.config.context_menu
            local allow_delete = context_menu and context_menu.allow_delete == true
            local action_dialog
            local function close_actions()
                UIManager:close(action_dialog)
            end
            local function stage_copy()
                close_actions()
                file_manager._zen_selected_clipboard = { files = files, cut = false }
                file_manager.clipboard = nil
                file_manager:onToggleSelectMode(true)
            end
            local function move_selected()
                close_actions()
                local cfg = ConfigManager.get()
                local extra_roots = type(cfg) == "table"
                    and type(cfg.additional_home_dirs) == "table"
                    and cfg.additional_home_dirs or nil
                local move_home_dir = paths.getHomeDir() or file_chooser.path
                UIManager:show(MoveChooser:new{
                    select_directory = true,
                    select_file = false,
                    show_files = true,
                    title = _("Move to…"),
                    path = move_home_dir,
                    home_root = move_home_dir,
                    extra_roots = extra_roots,
                    onConfirm = function(destination)
                        file_manager.cutfile = true
                        file_manager:pasteSelectedFiles(false, destination)
                    end,
                })
            end
            local function show_status_menu()
                close_actions()
                local status_dialog
                local statuses = {
                    { icons.status, _("Unread"), nil },
                    { icons.reading, _("Reading"), "reading" },
                    { icons.tbr, _("To Be Read"), "tbr" },
                    { icons.on_hold, _("On hold"), "abandoned" },
                    { icons.finished, _("Finished"), "complete" },
                }
                local rows = {}
                for _i, option in ipairs(statuses) do
                    rows[#rows + 1] = {{
                        text = option[1] .. "  " .. option[2],
                        align = "left",
                        callback = function()
                            UIManager:close(status_dialog)
                            set_selected_status(files, option[3])
                            file_chooser:refreshPath()
                        end,
                    }}
                end
                status_dialog = new_context_menu_dialog{
                    title = _("Read status"),
                    title_align = "center",
                    buttons = apply_button_group_font(rows),
                }
                UIManager:show(status_dialog)
            end
            local buttons = {
                {{
                    text = icons.copy .. "  " .. C_("File", "Copy"),
                    align = "left",
                    enabled = enabled,
                    callback = stage_copy,
                }},
                {{
                    text = icons.move .. "  " .. _("Move"),
                    align = "left",
                    enabled = enabled,
                    callback = move_selected,
                }},
                {{
                    text = icons.delete .. "  " .. _("Delete"),
                    align = "left",
                    enabled = enabled and allow_delete,
                    callback = function()
                        close_actions()
                        local ConfirmBox = require("ui/widget/confirmbox")
                        local confirmbox = ConfirmBox:new{
                            text = _("Delete selected files?\nIf you delete a file, it is permanently lost.") .. "\n",
                            ok_text = _("Delete"),
                            ok_callback = function()
                                file_manager:deleteSelectedFiles()
                            end,
                        }
                        file_manager.addMetadataArcCheckButton(confirmbox)
                        UIManager:show(confirmbox)
                    end,
                }},
                {{
                    text = icons.read_status .. "  " .. _("Read status") .. "  " .. submenu_arrow,
                    align = "left",
                    enabled = enabled,
                    callback = show_status_menu,
                }},
                {{
                    text = icons.fav_add .. "  " .. _("Add to collection") .. "  " .. submenu_arrow,
                    align = "left",
                    enabled = enabled,
                    callback = function()
                        close_actions()
                        show_collection_picker(files, function()
                            file_chooser:refreshPath()
                            -- Collection membership is per book; skip the full TBR library rescan.
                            local home = zen_plugin and SharedState.get(zen_plugin, "home")
                            if home and home.invalidateBookCache then
                                for file in pairs(files) do home.invalidateBookCache(file) end
                            end
                        end)
                    end,
                }},
                {{
                    text = icons.clear .. "  " .. _("Exit select mode"),
                    align = "left",
                    callback = function()
                        close_actions()
                        file_manager:onToggleSelectMode()
                    end,
                }},
            }
            local cover_h = Device.screen:scaleBySize(140)
            local cover_w = math.floor(cover_h * Cover.getRatio())
            local folder_cover = Cover.makeCover("zen-selected://", {
                genItemTableFromPath = function() return items end,
            }, {
                is_folder = true,
                max_w = cover_w,
                max_h = cover_h,
                folder_name = title,
            })
            local header
            if folder_cover then
                require("modules/filebrowser/patches/home/widgets/cover_common")
                    .decorate_cover_frame(folder_cover)
                local Size = require("ui/size")
                local dialog_w = math.floor(math.min(
                    Device.screen:getWidth(), Device.screen:getHeight()) * 0.9)
                local available_w = dialog_w - 2 * (Size.border.window + Size.padding.button)
                    - 2 * (Size.padding.default + Size.margin.default)
                local gap = Device.screen:scaleBySize(8)
                local text_w = math.max(available_w - cover_w - 2 * Cover.BORDER_SIZE - gap,
                    Device.screen:scaleBySize(60))
                header = LeftContainer:new{
                    dimen = Geom:new{ w = available_w, h = cover_h + 2 * Cover.BORDER_SIZE },
                    HorizontalGroup:new{
                        align = "center",
                        folder_cover,
                        HorizontalSpan:new{ width = gap },
                        VerticalGroup:new{
                            align = "left",
                            TextWidget:new{
                                text = title,
                                face = library_font.getFace(20),
                                bold = true,
                                max_width = text_w,
                            },
                        },
                    },
                }
            end
            action_dialog = new_context_menu_dialog{
                title = not header and title or nil,
                title_align = "center",
                buttons = apply_button_group_font(buttons),
                _added_widgets = header and { header } or nil,
                _zen_cover_widget = folder_cover,
            }
            UIManager:show(action_dialog)
        end

        file_manager.showSelectedFilesList = show_selected_actions

        file_manager.onShowPlusMenu = function()
            if file_manager.selected_files == nil then
                return FileManager.onShowPlusMenu(file_manager)
            end
            file_manager:showSelectedFilesList()
            return true
        end

        local function resolveItemKey(item)
            if type(item) ~= "table" then return nil end
            return item.path or item.file or item.filepath
        end

        local function normalizeItemKey(key)
            if type(key) ~= "string" or key == "" then return nil end
            return ffiUtil_sel.realpath(key) or key
        end

        local function keysMatch(a, b, a_norm)
            if not a or not b then return false end
            if a == b then return true end
            local an = a_norm or normalizeItemKey(a)
            if not an then return false end
            local bn = normalizeItemKey(b)
            return bn and an == bn or false
        end

        local function findVisibleWidgetByKey(self_fc, item_key)
            local item_norm = normalizeItemKey(item_key)

            local layout = self_fc and self_fc.layout
            if type(layout) == "table" then
                for r, row in ipairs(layout) do
                    if type(row) == "table" then
                        for c, w in ipairs(row) do
                            local entry = w and w.entry
                            local entry_key = resolveItemKey(entry)
                            if keysMatch(item_key, entry_key, item_norm) then
                                return w, "layout", r, c
                            end
                        end
                    end
                end
            end

            local ig = self_fc and self_fc.item_group
            if ig then
                for i, w in ipairs(ig) do
                    local entry = w and w.entry
                    local entry_key = resolveItemKey(entry)
                    if keysMatch(item_key, entry_key, item_norm) then
                        return w, "item_group", i, nil
                    end
                    if type(w) == "table" then
                        for j, child in ipairs(w) do
                            local child_entry = child and child.entry
                            local child_key = resolveItemKey(child_entry)
                            if keysMatch(item_key, child_key, item_norm) then
                                return child, "item_group_nested", i, j
                            end
                        end
                    end
                end
            end

            return nil, nil, nil, nil
        end

        if type(orig_onFileSelect) == "function" then
            file_chooser.onFileSelect = function(self_fc, item)
                logger.dbg("onFileSelect",
                    "select_mode=", tostring(file_manager.selected_files ~= nil),
                    "is_file=", tostring(item and item.is_file),
                    "path=", tostring(item and item.path),
                    "file=", tostring(item and item.file),
                    "filepath=", tostring(item and item.filepath),
                    "dim_before=", tostring(item and item.dim))

                if file_manager.selected_files then
                    local item_key = resolveItemKey(item)
                    if not item_key then
                        logger.dbg("onFileSelect", "no item key, fallback to original")
                        return orig_onFileSelect(self_fc, item)
                    end

                    local widget, source, i1, i2 = findVisibleWidgetByKey(self_fc, item_key)
                    logger.dbg("onFileSelect",
                        "item_key=", tostring(item_key),
                        "layout_rows=", tostring(self_fc and self_fc.layout and #self_fc.layout or 0),
                        "visible_items=", tostring(self_fc and self_fc.item_group and #self_fc.item_group or 0),
                        "matched_source=", tostring(source),
                        "idx1=", tostring(i1),
                        "idx2=", tostring(i2))

                    if not widget then
                        logger.dbg("onFileSelect", "no visible match, fallback to original (single toggle)")
                        local ret = orig_onFileSelect(self_fc, item)
                        logger.dbg("onFileSelect",
                            "fallback_return=", tostring(ret),
                            "dim_after_fallback=", tostring(item and item.dim),
                            "selected_after_fallback=", tostring(file_manager.selected_files[item_key]))
                        return ret
                    end

                    item.dim = not item.dim and true or nil
                    file_manager.selected_files[item_key] = item.dim
                    logger.dbg("onFileSelect",
                        "dim_after=", tostring(item.dim),
                        "selected_entry=", tostring(file_manager.selected_files[item_key]))

                    local entry = widget.entry
                    if entry then
                        entry.dim = item.dim
                        local entry_key = resolveItemKey(entry)
                        if entry_key and entry_key ~= item_key then
                            file_manager.selected_files[entry_key] = item.dim
                        end
                    end
                    widget.dim = item.dim

                    -- Keep mosaic covers intact; list rows need their selection styling rebuilt.
                    if widget._zen_cover_frame then
                        widget._zen_cover_frame.dim = nil
                    elseif type(widget.update) == "function" then
                        pcall(function() widget:update() end)
                    end

                    local d = (widget[1] and widget[1].dimen) or widget.dimen
                    if d then
                        local dirty_owner = self_fc.show_parent or self_fc
                        UIManager:setDirty(dirty_owner, function()
                            return "ui", d, dirty_owner.dithered
                        end)
                    end
                    logger.dbg("onFileSelect", "fast-path return true")
                    return true
                end
                local ret = orig_onFileSelect(self_fc, item)
                logger.dbg("onFileSelect",
                    "not_in_select_mode_return=", tostring(ret),
                    "dim_after=", tostring(item and item.dim))
                return ret
            end
        end

        file_chooser.showSortOrderDialog = function(self_fc, opts)
            local UIManager_sod    = require("ui/uimanager")
            local cur_rev          = opts.current_reverse or false
            local forward_text     = opts.forward_text or _("Ascending")
            local reverse_text     = opts.reverse_text or _("Descending")
            local order_dialog
            order_dialog = new_context_menu_dialog{
                title       = opts.title or _("Sort order"),
                title_align = "center",
                buttons     = {
                    {{
                        text     = icons.sort_asc .. "  " .. forward_text .. (not cur_rev and "  " .. icons.check or ""),
                        align    = "left",
                        enabled  = cur_rev,
                        callback = function()
                            UIManager_sod:close(order_dialog)
                            opts.on_select(false)
                        end,
                    }},
                    {{
                        text     = icons.sort_desc .. "  " .. reverse_text .. (cur_rev and "  " .. icons.check or ""),
                        align    = "left",
                        enabled  = not cur_rev,
                        callback = function()
                            UIManager_sod:close(order_dialog)
                            opts.on_select(true)
                        end,
                    }},
                },
            }
            UIManager_sod:show(order_dialog)
        end

        local file_dialog_ctx = {
            zen_plugin = zen_plugin,
            logger = logger,
            file_chooser = file_chooser,
            file_manager = file_manager,
            orig_showFileDialog = orig_showFileDialog,
            MoveChooser = MoveChooser,
            show_collection_picker = show_collection_picker,
            archive_context_row = archive_context_row,
            apply_button_group_font = apply_button_group_font,
            new_context_menu_dialog = new_context_menu_dialog,
        }
        file_chooser.showFileDialog = function(self_fc, item)
            return require("modules/filebrowser/patches/context_menu_file_dialog")(
                file_dialog_ctx, self_fc, item)
        end

        if Device:isTouchDevice() then
            local GestureRange_bh = require("ui/gesturerange")
            local Geom_bh = require("ui/geometry")
            if not file_chooser.ges_events then
                file_chooser.ges_events = {}
            end
            file_chooser.ges_events.ZenBlankHold = {
                GestureRange_bh:new{
                    ges = "hold",
                    range = Geom_bh:new{
                        x = 0, y = 0,
                        w = Device.screen:getWidth(),
                        h = Device.screen:getHeight(),
                    },
                },
            }
            file_chooser.onZenBlankHold = function(fc, arg, ges)
                local home_dir_bh = paths.getHomeDir()
                local cur_path_bh = fc.path or ""
                if home_dir_bh then
                    if not paths.isInThemedDir(cur_path_bh) then return false end
                end
                local ffiUtil_bh = require("ffi/util")
                local cur_real = ffiUtil_bh.realpath(cur_path_bh) or cur_path_bh
                fc:showFileDialog({
                    path = cur_real,
                    is_file = false,
                    is_go_up = false,
                    text = ffiUtil_bh.basename(cur_real),
                    bidi_wrap_func = BD.directory,
                    _is_current_dir = true,
                })
                return true
            end
        end
    end
end

return apply_context_menu
