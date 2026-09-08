local function apply_context_menu()
    --[[
        Replaces the long-hold file/folder context menu with a minimal layout.
        Always active; delegates to stock KOReader outside home_dir.
    ]]

    local BD           = require("ui/bidi")
    local ButtonDialog = require("ui/widget/buttondialog")
    local Device       = require("device")
    local FileChooser  = require("ui/widget/filechooser")
    local FileManager  = require("apps/filemanager/filemanager")
    local PathChooser  = require("ui/widget/pathchooser")
    local UIManager    = require("ui/uimanager")
    local _            = require("gettext")
    local C_           = _.pgettext
    local book_status  = require("common/book_status")
    local ConfigManager = require("config/manager")
    local FolderCoverFiles = require("common/folder_cover_files")
    local FolderCoverPicker = require("common/ui/folder_cover_picker")
    local paths        = require("common/paths")
    local SharedState  = require("common/shared_state")
    local icons        = require("common/inline_icon_map")
    local submenu_arrow = icons.arrow_right
    local zen_plugin   = rawget(_G, "__ZEN_UI_PLUGIN")
    local Cover        = require("common/cover_utils")
    local VerticalGroup   = require("ui/widget/verticalgroup")
    local VerticalSpan    = require("ui/widget/verticalspan")
    local LeftContainer   = require("ui/widget/container/leftcontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local FrameContainer  = require("ui/widget/container/framecontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan  = require("ui/widget/horizontalspan")
    local TextWidget      = require("ui/widget/textwidget")
    local Geom            = require("ui/geometry")
    local Blitbuffer      = require("ffi/blitbuffer")
    local library_font    = require("modules/filebrowser/patches/library_font")

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

    local CONTEXT_ICON_COLUMN_WIDTH = Device.screen:scaleBySize(30)
    local CONTEXT_ICON_GAP = Device.screen:scaleBySize(8)

    local function split_inline_icon(text)
        local first_byte = text:byte(1)
        if not first_byte then return nil, text end

        local char_len
        if first_byte < 0x80 then
            char_len = 1
        elseif first_byte < 0xE0 then
            char_len = 2
        elseif first_byte < 0xF0 then
            char_len = 3
        else
            char_len = 4
        end

        local suffix = text:sub(char_len + 1)
        if suffix:sub(1, 2) ~= "  " then return nil, text end
        return text:sub(1, char_len), suffix:sub(3)
    end

    local function align_button_dialog_icons(dialog)
        local button_rows = dialog and dialog.buttontable and dialog.buttontable.buttons_layout
        if type(button_rows) ~= "table" then return dialog end

        for _i, row in ipairs(button_rows) do
            for _j, button in ipairs(row) do
                local old_label = button.label_widget
                local label_container = button.label_container
                if button.text and old_label and label_container and label_container.dimen then
                    local display_text = button.checked_func and button:getDisplayText() or button.text
                    local glyph, label = split_inline_icon(display_text)
                    local face = old_label.face
                    local fgcolor = old_label.fgcolor
                    local bold = old_label.bold
                    local label_width = math.max(1, label_container.dimen.w
                        - CONTEXT_ICON_COLUMN_WIDTH - CONTEXT_ICON_GAP)
                    local icon_widget = glyph and TextWidget:new{
                        text = glyph,
                        face = face,
                        fgcolor = fgcolor,
                        bold = bold,
                    } or HorizontalSpan:new{ width = 0 }
                    local text_widget = TextWidget:new{
                        text = label,
                        lang = button.lang,
                        max_width = label_width,
                        face = face,
                        fgcolor = fgcolor,
                        bold = bold,
                    }

                    old_label:free()
                    button.label_widget = text_widget
                    label_container[1] = HorizontalGroup:new{
                        align = "center",
                        CenterContainer:new{
                            dimen = Geom:new{
                                w = CONTEXT_ICON_COLUMN_WIDTH,
                                h = label_container.dimen.h,
                            },
                            icon_widget,
                        },
                        HorizontalSpan:new{ width = CONTEXT_ICON_GAP },
                        text_widget,
                    }
                end
            end
        end
        return dialog
    end

    local function new_context_menu_dialog(options)
        return align_button_dialog_icons(ButtonDialog:new(options))
    end

    -- Keep every PathChooser navigable above a locked home folder.
    if not PathChooser._zen_navigation_patched
            and type(PathChooser.genItemTableFromPath) == "function" then
        PathChooser._zen_navigation_patched = true
        local orig_pathchooser_gen_items = PathChooser.genItemTableFromPath

        function PathChooser:genItemTableFromPath(path)
            local items = orig_pathchooser_gen_items(self, path)
            local parent = type(path) == "string" and require("ffi/util").dirname(path)
            if type(parent) ~= "string" or parent == path then
                return items
            end
            for _i, item in ipairs(items) do
                if item.is_go_up then return items end
            end
            table.insert(items, self.show_current_dir_for_hold and 2 or 1, {
                text = BD.mirroredUILayout() and BD.ltr("../ \u{2B06}") or "\u{2B06} ../",
                path = path .. "/..",
                is_go_up = true,
            })
            return items
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

    function MoveChooser:genItemTableFromPath(path)
        local ffiUtil3 = require("ffi/util")
        local lfs3     = require("libs/libkoreader-lfs")
        local BD3      = require("ui/bidi")
        local root     = ffiUtil3.realpath(path) or path
        local MAX_DEPTH = 3
        local items    = {}

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
                        and self:show_dir(fname) then
                    local fpath = dir_path .. "/" .. fname
                    if lfs3.attributes(fpath, "mode") == "directory" then
                        table.insert(subdirs, { name = fname, path = fpath })
                    end
                end
            end
            table.sort(subdirs, function(a, b) return a.name < b.name end)
            for _i, sub in ipairs(subdirs) do
                local sub_real = ffiUtil3.realpath(sub.path) or sub.path
                if not (skip_set and skip_set[sub_real]) then
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

        if type(self.extra_roots) == "table" then
            local skip_set = { [root] = true }
            for _i, er_path in ipairs(self.extra_roots) do
                local er = ffiUtil3.realpath(er_path) or er_path
                skip_set[er] = true
            end

            for _i, er_path in ipairs(self.extra_roots) do
                local er = ffiUtil3.realpath(er_path) or er_path
                if er ~= root then
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

        return items
    end

    function MoveChooser:onMenuSelect(item)
        local path = item and item.path
        if not path then return true end
        local ffiUtil2 = require("ffi/util")
        local real = ffiUtil2.realpath(path)
        if not real then return true end
        local lfs2 = require("libs/libkoreader-lfs")
        if lfs2.attributes(real, "mode") == "directory" then
            if self.onConfirm then self.onConfirm(real) end
            UIManager:close(self)
        end
        return true
    end

    function MoveChooser:onMenuHold() return true end

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
    end

    FileManager.setupLayout = function(self)
        orig_setupLayout(self)

        local file_chooser = self.file_chooser
        local file_manager = self
        local logger = require("common/zen_logger").new("context_menu")
        local ffiUtil_sel = require("ffi/util")

        local orig_showFileDialog = file_chooser.showFileDialog
        local orig_onFileSelect = file_chooser.onFileSelect

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

                    -- List layout bakes the dim/selection state into its widget
                    -- subtree at update() time (listmenu.lua: self.file_deleted =
                    -- self.entry.dim), unlike mosaic which reads self.dim live in
                    -- paintTo. Without re-running update() the list repaints its
                    -- stale tree, so the highlight only appears after a page turn
                    -- rebuilds all items. Re-baking one item is cheaper than the
                    -- stock full updateItems(1, true).
                    if type(widget.update) == "function" then
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
            local _sod             = require("gettext")
            local cur_rev          = opts.current_reverse or false
            local forward_text     = opts.forward_text or _sod("Ascending")
            local reverse_text     = opts.reverse_text or _sod("Descending")
            local order_dialog
            order_dialog = new_context_menu_dialog{
                title       = opts.title or _sod("Sort order"),
                title_align = "center",
                buttons     = {
                    {{
                        text     = "\u{F15D}  " .. forward_text .. (not cur_rev and "  \u{2713}" or ""),
                        align    = "left",
                        enabled  = cur_rev,
                        callback = function()
                            UIManager_sod:close(order_dialog)
                            opts.on_select(false)
                        end,
                    }},
                    {{
                        text     = "\u{F15E}  " .. reverse_text .. (cur_rev and "  \u{2713}" or ""),
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

        file_chooser.showFileDialog = function(self_fc, item)
            if item.is_go_up then return end

            if zen_plugin then
                local features = zen_plugin.config and zen_plugin.config.features
                local lc = zen_plugin.config and zen_plugin.config.lockdown
                if type(features) == "table" and features.lockdown_mode == true
                        and type(lc) == "table" and lc.disable_context_menu == true then
                    return  -- suppress context menu entirely in lockdown
                end
            end

            -- True when the held item is the folder currently being viewed
            -- (blank-hold), false when holding a sub-folder from its parent list.
            -- Captured before the series-view reassignment below overwrites item.
            local is_current_view = item._is_current_dir == true
            if item._is_current_dir
                    and self_fc.item_table
                    and self_fc.item_table.is_in_series_view
                    and self_fc.item_table._zen_series_group_item then
                item = self_fc.item_table._zen_series_group_item
            end
            local is_virtual_folder = item.is_series_group == true

            -- Group context menu (authors/series views)
            if item._zen_group_files then
                local group_files = item._zen_group_files
                local group_name  = item._zen_group_name or ""
                local sort_cb     = item._zen_sort_cb
                local display_cb  = item._zen_display_cb
                local Screen   = Device.screen
                local SizeR    = require("ui/size")
                local border   = Cover.BORDER_SIZE
                local gap      = Screen:scaleBySize(8)
                local dlg_w    = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9)
                local avail_w  = dlg_w - 2 * (SizeR.border.window + SizeR.padding.button)
                                        - 2 * (SizeR.padding.default + SizeR.margin.default)

                -- Calculate cover dimensions respecting uniform_cover_ratio
                local ratio = Cover.getRatio()
                local cover_max_h = Screen:scaleBySize(140)
                local cover_max_w = math.floor(cover_max_h * ratio)

                -- Build fake chooser for group files
                local fake_chooser = {
                    genItemTableFromPath = function()
                        local entries = {}
                        for _i, fpath in ipairs(group_files) do
                            table.insert(entries, { path = fpath, is_file = true })
                        end
                        return entries
                    end
                }

                -- Use unified makeCover for folder (gallery mode)
                local cover_widget = Cover.makeCover(group_name, fake_chooser, {
                    is_folder = true,
                    max_w = cover_max_w,
                    max_h = cover_max_h,
                    folder_name = group_name,
                })

                local framed_gallery = cover_widget or FrameContainer:new{
                    padding    = 0,
                    bordersize = border,
                    width      = cover_max_w + 2 * border,
                    height     = cover_max_h + 2 * border,
                    background = Blitbuffer.COLOR_LIGHT_GRAY,
                    CenterContainer:new{
                        dimen = Geom:new{ w = cover_max_w, h = cover_max_h },
                        VerticalSpan:new{ width = 1 },
                    },
                }

                -- Apply rounded corners
                local plug = zen_plugin or rawget(_G, "__ZEN_UI_PLUGIN")
                if plug and type(plug.config) == "table"
                    and type(plug.config.features) == "table"
                    and plug.config.features.browser_cover_rounded_corners == true then
                    local r = Screen:scaleBySize(6)
                    local r_inner = r - border
                    local orig_pt = framed_gallery.paintTo
                    framed_gallery.paintTo = function(frame_self, bb, x, y)
                        orig_pt(frame_self, bb, x, y)
                        if not (frame_self.dimen and frame_self.dimen.x) then return end
                        local tx, ty = frame_self.dimen.x, frame_self.dimen.y
                        local tw, th = frame_self.dimen.w, frame_self.dimen.h
                        local wh = Blitbuffer.COLOR_WHITE
                        local blk = Blitbuffer.COLOR_BLACK
                        for j = 0, r - 1 do
                            local inner = math.sqrt(r * r - (r - j) * (r - j))
                            local cut = math.ceil(r - inner)
                            if cut > 0 then
                                bb:paintRect(tx, ty + j, cut, 1, wh)
                                bb:paintRect(tx + tw - cut, ty + j, cut, 1, wh)
                                bb:paintRect(tx, ty + th - 1 - j, cut, 1, wh)
                                bb:paintRect(tx + tw - cut, ty + th - 1 - j, cut, 1, wh)
                            end
                        end
                        for j = 0, r - 1 do
                            for c = 0, r - 1 do
                                local dx, dy = r - c - 0.5, r - j - 0.5
                                local dist = math.sqrt(dx * dx + dy * dy)
                                if dist >= r_inner and dist <= r then
                                    bb:paintRect(tx + c, ty + j, 1, 1, blk)
                                    bb:paintRect(tx + tw - 1 - c, ty + j, 1, 1, blk)
                                    bb:paintRect(tx + c, ty + th - 1 - j, 1, 1, blk)
                                    bb:paintRect(tx + tw - 1 - c, ty + th - 1 - j, 1, 1, blk)
                                end
                            end
                        end
                    end
                end

                local framed_h = cover_max_h + 2 * border
                local text_col_w = math.max(avail_w - cover_max_w - 2 * border - gap, Screen:scaleBySize(60))
                local n_files = #group_files
                local subtitle = item._zen_group_subtitle
                    or (n_files == 1 and _("1 book") or (tostring(n_files) .. " " .. _("books")))
                local vstack = VerticalGroup:new{ align = "left" }
                table.insert(vstack, TextWidget:new{
                    text = BD.auto(group_name),
                    face = library_font.getFace(20),
                    bold = true,
                    max_width = text_col_w,
                })
                table.insert(vstack, VerticalSpan:new{ width = Screen:scaleBySize(2) })
                table.insert(vstack, TextWidget:new{
                    text = subtitle,
                    face = library_font.getFace(17),
                    max_width = text_col_w,
                })

                local header_widget = LeftContainer:new{
                    dimen = Geom:new{ w = avail_w, h = framed_h },
                    HorizontalGroup:new{
                        align = "center",
                        framed_gallery,
                        HorizontalSpan:new{ width = gap },
                        vstack,
                    },
                }

                local buttons = {}
                if item._zen_prepend_buttons then
                    for _i, row in ipairs(item._zen_prepend_buttons) do
                        table.insert(buttons, row)
                    end
                end
                if display_cb then
                    table.insert(buttons, {{
                        text = "\u{F06D0}  " .. _("Display") .. "  " .. submenu_arrow,
                        align = "left",
                        callback = function()
                            UIManager:close(self_fc.file_dialog)
                            display_cb()
                        end,
                    }})
                end
                if sort_cb then
                    table.insert(buttons, {{
                        text = "\u{F04BF}  " .. _("Sort") .. "  " .. submenu_arrow,
                        align = "left",
                        callback = function()
                            UIManager:close(self_fc.file_dialog)
                            sort_cb()
                        end,
                    }})
                end

                local function showGroupFilterDialog()
                    local cur_st = FileChooser.show_filter and FileChooser.show_filter.status
                    local is_all = cur_st == nil
                    local filter_dialog
                    local function setGlobalFilter(new_status)
                        if not FileChooser.show_filter then FileChooser.show_filter = {} end
                        FileChooser.show_filter.status = new_status
                        local gs = rawget(_G, "G_reader_settings")
                        if gs then
                            gs:saveSetting("show_filter", FileChooser.show_filter)
                            pcall(gs.flush, gs)
                        end
                        self_fc:refreshPath()
                        if item._zen_filter_refresh_cb then item._zen_filter_refresh_cb() end
                    end
                    local STATUS_OPTS = {
                        { key = "new", icon = icons.status, label = _("Unread") },
                        { key = "reading", icon = icons.reading, label = _("Reading") },
                        { key = "tbr", icon = icons.tbr, label = _("To Be Read") },
                        { key = "abandoned", icon = icons.on_hold, label = _("On hold") },
                        { key = "complete", icon = icons.finished, label = _("Finished") },
                    }
                    local fbts = {}
                    table.insert(fbts, {{
                        text = _("All") .. (is_all and "  " .. icons.check or ""),
                        align = "left",
                        enabled = not is_all,
                        callback = function()
                            UIManager:close(filter_dialog)
                            setGlobalFilter(nil)
                        end,
                    }})
                    for _i, st in ipairs(STATUS_OPTS) do
                        local is_active = cur_st and cur_st[st.key] == true
                        table.insert(fbts, {{
                            text = st.icon .. "  " .. st.label
                                .. (is_active and "  " .. icons.check or ""),
                            align = "left",
                            callback = function()
                                UIManager:close(filter_dialog)
                                local new_st = {}
                                if cur_st then
                                    for _k, v in pairs(cur_st) do new_st[_k] = v end
                                end
                                if new_st[st.key] then new_st[st.key] = nil
                                else new_st[st.key] = true end
                                local n = 0
                                for _k, v in pairs(new_st) do if v then n = n + 1 end end
                                if n == 0 or n == #STATUS_OPTS then setGlobalFilter(nil)
                                else setGlobalFilter(new_st) end
                                UIManager:nextTick(showGroupFilterDialog)
                            end,
                        }})
                    end
                    filter_dialog = new_context_menu_dialog{
                        title = _("Filter by status"),
                        title_align = "center",
                        buttons = apply_button_group_font(fbts),
                    }
                    UIManager:show(filter_dialog)
                end

                if item._zen_is_folder_view then
                    local n_gf = 0
                    if FileChooser.show_filter and FileChooser.show_filter.status then
                        for _k, v in pairs(FileChooser.show_filter.status) do
                            if v then n_gf = n_gf + 1 end
                        end
                    end
                    table.insert(buttons, {{
                        text = icons.filter .. "  " .. _("Filter")
                            .. (n_gf > 0 and " (" .. n_gf .. ")" or "")
                            .. "  " .. submenu_arrow,
                        align = "left",
                        callback = function()
                            UIManager:close(self_fc.file_dialog)
                            UIManager:nextTick(showGroupFilterDialog)
                        end,
                    }})
                end

                if item._zen_extra_buttons then
                    for _i, row in ipairs(item._zen_extra_buttons) do
                        table.insert(buttons, row)
                    end
                end

                self_fc.file_dialog = new_context_menu_dialog{
                    buttons = apply_button_group_font(buttons),
                    _added_widgets = { header_widget },
                }
                UIManager:show(self_fc.file_dialog)
                return true
            end

            local home_dir = paths.getHomeDir()
            local cur_path = self_fc.path or ""
            if home_dir and not item._zen_collection_name and not item._zen_home_context then
                if not paths.isInHomeDir(cur_path) then
                    return orig_showFileDialog(self_fc, item)
                end
            end

            local file               = item.path
            local is_file            = item.is_file
            local is_not_parent_folder = not item.is_go_up
            local is_home_dir = (not is_file) and paths.isHomeRoot(file)
            -- Only the primary library root uses global sort/display; additional
            -- home dirs behave like ordinary folders with per-folder overrides.
            local is_primary_home = (not is_file) and paths.isPrimaryHomeRoot(file)

            local function close_dialog()
                UIManager:close(self_fc.file_dialog)
            end

            local function refresh()
                UIManager:nextTick(function()
                    self_fc:refreshPath()
                end)
            end

            local function invalidate_home_book()
                local home = zen_plugin and SharedState.get(zen_plugin, "home")
                if home and type(home.invalidateBookCache) == "function" then
                    home.invalidateBookCache(file)
                end
                if home and type(home.rebuildActive) == "function" then
                    home.rebuildActive()
                end
            end

            local function refresh_book_info()
                local ok_bim, BookInfoManager = pcall(require, "bookinfomanager")
                if not ok_bim then return end
                BookInfoManager:deleteBookInfo(file)
                invalidate_home_book()
                if self_fc.filemanager_menu then
                    self_fc.filemanager_menu.files_updated = true
                end
                refresh()
            end

            local function refresh_after_sort_change(folder_path)
                if not folder_path then
                    if self_fc._zen_clear_item_table_cache then
                        self_fc:_zen_clear_item_table_cache()
                    end
                    if self_fc.clearSortingCache then self_fc:clearSortingCache() end
                    self_fc:refreshPath()
                    return
                end

                if is_virtual_folder
                        and type(self_fc._zen_resort_series_group) == "function"
                        and self_fc:_zen_resort_series_group(item, is_current_view) then
                    if not is_current_view and type(self_fc.updateItems) == "function" then
                        self_fc:updateItems()
                    end
                    return
                end

                if self_fc._zen_invalidate_item_table_path then
                    self_fc:_zen_invalidate_item_table_path(folder_path)
                else
                    local ok_folder, FolderCover = pcall(
                        require, "modules/filebrowser/folder_cover")
                    if ok_folder and type(FolderCover.clear) == "function" then
                        FolderCover.clear(folder_path)
                    end
                end
                if self_fc.clearSortingCache then self_fc:clearSortingCache() end
                if is_current_view then
                    self_fc:refreshPath()
                elseif type(self_fc.updateItems) == "function" then
                    self_fc:updateItems()
                end
            end

            local function refresh_after_folder_cover_change(folder_path)
                UIManager:nextTick(function()
                    refresh_after_sort_change(folder_path)
                    local plug = zen_plugin or rawget(_G, "__ZEN_UI_PLUGIN")
                    local home = plug and SharedState.get(plug, "home")
                    if home and type(home.invalidateLibraryCache) == "function" then
                        home.invalidateLibraryCache()
                    end
                    if home and type(home.rebuildActive) == "function" then
                        home.rebuildActive()
                    end
                end)
            end

            local dialog_title, dialog_cover_widget

            local function showCoverFullscreen(cover_path)
                local ok2, bim2 = pcall(require, "bookinfomanager")
                if not ok2 then return end
                local bi2 = bim2:getBookInfo(cover_path, true)
                if not bi2 or not bi2.cover_bb or not bi2.has_cover
                    or bi2.ignore_cover then return end
                local ImageViewer = require("ui/widget/imageviewer")
                local iv = ImageViewer:new{
                    image = bi2.cover_bb,
                    image_disposable = false,
                    fullscreen = true,
                    with_title_bar = false,
                }
                iv.onTap = function(iv_self)
                    iv_self:onClose()
                    return true
                end
                UIManager:show(iv)
            end

            do
                local Screen = Device.screen
                local SizeR = require("ui/size")
                local border = Cover.BORDER_SIZE
                local gap = Screen:scaleBySize(8)
                local dlg_w = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.9)
                local avail_w = dlg_w - 2 * (SizeR.border.window + SizeR.padding.button)
                                       - 2 * (SizeR.padding.default + SizeR.margin.default)

                -- Calculate cover dimensions respecting uniform_cover_ratio
                local ratio = Cover.getRatio()
                local cover_max_h = Screen:scaleBySize(140)
                local cover_max_w = math.floor(cover_max_h * ratio)

                local function _zen_apply_rounded_cover(frame_widget, bsz)
                    local plug = zen_plugin or rawget(_G, "__ZEN_UI_PLUGIN")
                    if not (plug
                        and type(plug.config) == "table"
                        and type(plug.config.features) == "table"
                        and plug.config.features.browser_cover_rounded_corners == true)
                    then
                        return
                    end
                    local r = Screen:scaleBySize(6)
                    local r_inner = r - bsz
                    local orig_pt = frame_widget.paintTo
                    frame_widget.paintTo = function(frame_self, bb, x, y)
                        orig_pt(frame_self, bb, x, y)
                        if not (frame_self.dimen and frame_self.dimen.x) then return end
                        local tx, ty = frame_self.dimen.x, frame_self.dimen.y
                        local tw, th = frame_self.dimen.w, frame_self.dimen.h
                        local Blitbuffer_rc = require("ffi/blitbuffer")
                        local wh = Blitbuffer_rc.COLOR_WHITE
                        local blk = Blitbuffer_rc.COLOR_BLACK
                        for j = 0, r - 1 do
                            local inner = math.sqrt(r * r - (r - j) * (r - j))
                            local cut = math.ceil(r - inner)
                            if cut > 0 then
                                bb:paintRect(tx, ty + j, cut, 1, wh)
                                bb:paintRect(tx + tw - cut, ty + j, cut, 1, wh)
                                bb:paintRect(tx, ty + th - 1 - j, cut, 1, wh)
                                bb:paintRect(tx + tw - cut, ty + th - 1 - j, cut, 1, wh)
                            end
                        end
                        for j = 0, r - 1 do
                            for c = 0, r - 1 do
                                local dx = r - c - 0.5
                                local dy = r - j - 0.5
                                local dist = math.sqrt(dx * dx + dy * dy)
                                if dist >= r_inner and dist <= r then
                                    bb:paintRect(tx + c, ty + j, 1, 1, blk)
                                    bb:paintRect(tx + tw - 1 - c, ty + j, 1, 1, blk)
                                    bb:paintRect(tx + c, ty + th - 1 - j, 1, 1, blk)
                                    bb:paintRect(tx + tw - 1 - c, ty + th - 1 - j, 1, 1, blk)
                                end
                            end
                        end
                    end
                end

                local function makeSideBySide(cover_bb, src_w, src_h, sf, title_str, authors_str, series_str_arg, tags_str_arg, pages_str_arg, on_cover_tap)
                    local rendered_w = math.floor(src_w * sf)
                    local rendered_h = math.floor(src_h * sf)
                    local framed_h = rendered_h + 2 * border
                    local text_col_w = math.max(avail_w - rendered_w - 2 * border - gap,
                                                 Screen:scaleBySize(60))
                    local ImageWidget = require("ui/widget/imagewidget")
                    local fs_title = 20
                    local fs_authors = 17
                    local fs_tags = 14
                    local vstack = VerticalGroup:new{ align = "left" }
                    if title_str then
                        table.insert(vstack, TextWidget:new{
                            text = title_str,
                            face = library_font.getFace(fs_title),
                            bold = true,
                            max_width = text_col_w,
                        })
                    end
                    if authors_str then
                        table.insert(vstack, VerticalSpan:new{ width = Screen:scaleBySize(2) })
                        table.insert(vstack, TextWidget:new{
                            text = authors_str,
                            face = library_font.getFace(fs_authors),
                            max_width = text_col_w,
                        })
                    end
                    if series_str_arg then
                        table.insert(vstack, VerticalSpan:new{ width = Screen:scaleBySize(2) })
                        table.insert(vstack, TextWidget:new{
                            text = series_str_arg,
                            face = library_font.getFace(fs_authors),
                            fgcolor = Blitbuffer.COLOR_GRAY_3,
                            max_width = text_col_w,
                        })
                    end
                    if tags_str_arg and tags_str_arg ~= "" then
                        table.insert(vstack, VerticalSpan:new{ width = Screen:scaleBySize(3) })
                        table.insert(vstack, TextWidget:new{
                            text = tags_str_arg,
                            face = library_font.getFace(fs_tags),
                            fgcolor = Blitbuffer.COLOR_GRAY_3,
                            max_width = text_col_w,
                        })
                    end
                    if pages_str_arg then
                        table.insert(vstack, VerticalSpan:new{ width = Screen:scaleBySize(3) })
                        table.insert(vstack, TextWidget:new{
                            text = pages_str_arg,
                            face = library_font.getFace(fs_tags),
                            fgcolor = Blitbuffer.COLOR_GRAY_3,
                            max_width = text_col_w,
                        })
                    end
                    local cover_frame = FrameContainer:new{
                        padding = 0,
                        bordersize = border,
                        ImageWidget:new{
                            image = cover_bb,
                            image_disposable = true,
                            scale_factor = sf,
                        },
                    }
                    _zen_apply_rounded_cover(cover_frame, border)
                    local cover_component
                    if on_cover_tap then
                        local InputContainer2 = require("ui/widget/container/inputcontainer")
                        local GestureRange2 = require("ui/gesturerange")
                        local cw = rendered_w + 2 * border
                        local wrapper = InputContainer2:new{
                            dimen = Geom:new{ w = cw, h = framed_h },
                            ges_events = {
                                TapCover = {
                                    GestureRange2:new{
                                        ges = "tap",
                                        range = Geom:new{
                                            x = 0, y = 0,
                                            w = Screen:getWidth(),
                                            h = Screen:getHeight(),
                                        },
                                    },
                                },
                            },
                        }
                        wrapper.onTapCover = function(wrapper_self, _arg, ges)
                            if not wrapper_self.dimen or not ges or not ges.pos then
                                return false
                            end
                            if not wrapper_self.dimen:contains(ges.pos) then
                                return false
                            end
                            on_cover_tap()
                            return true
                        end
                        wrapper[1] = cover_frame
                        cover_component = wrapper
                    else
                        cover_component = cover_frame
                    end
                    return LeftContainer:new{
                        dimen = Geom:new{ w = avail_w, h = framed_h },
                        HorizontalGroup:new{
                            align = "center",
                            cover_component,
                            HorizontalSpan:new{ width = gap },
                            vstack,
                        },
                    }
                end

                local pages_str
                if is_file then
                    local ok, BookInfoManager = pcall(require, "bookinfomanager")
                    local title_str, authors_str, tags_str_local, series_str_local
                    if ok then
                        local bookinfo = BookInfoManager:getBookInfo(file, true)
                        if bookinfo then
                            if not bookinfo.ignore_meta then
                                if bookinfo.title then
                                    title_str = BD.auto(bookinfo.title)
                                    authors_str = bookinfo.authors and BD.auto(bookinfo.authors:gsub("\n", ", ")) or nil
                                end
                                if bookinfo.series then
                                    local s = BD.auto(bookinfo.series)
                                    local index = tonumber(bookinfo.series_index)
                                    series_str_local = index and string.format("%s #%.4g", s, index) or s
                                end
                                if bookinfo.keywords and bookinfo.keywords ~= "" then
                                    tags_str_local = bookinfo.keywords
                                        :gsub("%s*[\n;]%s*", ", ")
                                        :gsub("%s+\xC2\xB7%s+", ", ")
                                        :gsub("^,%s*", ""):gsub(",%s*$", "")
                                end
                                local n_pages = tonumber(bookinfo.pages)
                                if not (n_pages and n_pages > 0) then
                                    local ok_ds, DocSettings = pcall(require, "docsettings")
                                    if ok_ds then
                                        pcall(function()
                                            local ds = DocSettings:open(file)
                                            local p = tonumber(ds:readSetting("doc_pages"))
                                            if p and p > 0 then n_pages = p end
                                        end)
                                    end
                                end
                                if n_pages and n_pages > 0 then
                                    pages_str = n_pages .. " " .. _("pages")
                                end
                            end
                            -- Use unified makeCover for single book (with proper scaling)
                            local cover_bb, w, h = Cover.makeCover(file, nil, {
                                is_folder = false,
                                width = cover_max_w,
                                height = cover_max_h,
                            })

                            if cover_bb then
                                -- cover_bb is already scaled to target dimensions, so sf = 1.0
                                dialog_cover_widget = makeSideBySide(
                                    cover_bb, w, h, 1.0,
                                    title_str or BD.filename(file:match("([^/]+)$")),
                                    authors_str,
                                    series_str_local,
                                    tags_str_local,
                                    pages_str,
                                    function() showCoverFullscreen(file) end)
                            end
                        end
                    end
                    local text_str
                    if title_str then
                        text_str = title_str
                        if authors_str then text_str = text_str .. "\n" .. authors_str end
                        if series_str_local then text_str = text_str .. "\n" .. series_str_local end
                    end
                    dialog_title = text_str or BD.filename(file:match("([^/]+)$"))
                else
                    -- folder
                    local is_series_group = is_virtual_folder
                    local name = is_series_group
                        and (item.text or item._zen_group_name or file)
                        or (file:match("([^/]+)/?$") or file):gsub("/$", "")
                    local folder_name_str = BD.directory(name)
                    local lfs = require("libs/libkoreader-lfs")
                    local DocReg = require("document/documentregistry")

                    -- Use real FileChooser so cover order/scope matches the browser
                    local _fm = require("apps/filemanager/filemanager")
                    local _cover_chooser
                    if is_series_group then
                        _cover_chooser = {
                            genItemTableFromPath = function()
                                local entries = {}
                                for _i, series_item in ipairs(item.series_items or {}) do
                                    local series_path = series_item and (series_item.path or series_item.file)
                                    if series_path and not series_item.is_go_up then
                                        table.insert(entries, {
                                            path = series_path,
                                            is_file = true,
                                        })
                                    end
                                end
                                return entries
                            end
                        }
                    else
                        _cover_chooser = _fm.instance and _fm.instance.file_chooser
                    end
                    if not _cover_chooser then
                        -- Fallback: non-recursive immediate-dir listing
                        _cover_chooser = {
                            genItemTableFromPath = function(_, dir)
                                local entries = {}
                                local ok_d, it, obj = pcall(lfs.dir, dir)
                                if ok_d then
                                    for fname in it, obj do
                                        if fname ~= "." and fname ~= ".." then
                                            local fpath = dir .. "/" .. fname
                                            if lfs.attributes(fpath, "mode") == "file"
                                                    and DocReg:hasProvider(fpath) then
                                                table.insert(entries, { path = fpath, is_file = true })
                                            end
                                        end
                                    end
                                end
                                table.sort(entries, function(a, b) return (a.path or "") < (b.path or "") end)
                                return entries
                            end
                        }
                    end

                    -- Use unified makeCover for folder, including virtual series folders.
                    local cover_path = is_series_group
                        and ("zen-series://" .. folder_name_str)
                        or file
                    local cover_widget = Cover.makeCover(cover_path, _cover_chooser, {
                        is_folder = true,
                        max_w = cover_max_w,
                        max_h = cover_max_h,
                        folder_name = folder_name_str,
                    })

                    -- Apply rounded corners
                    if cover_widget and _zen_apply_rounded_cover then
                        _zen_apply_rounded_cover(cover_widget, border)
                    end

                    if cover_widget then
                        -- Count books recursively for the display label
                        local n_books = 0
                        if is_series_group then
                            for _i, series_item in ipairs(item.series_items or {}) do
                                if series_item and not series_item.is_go_up
                                        and (series_item.is_file or series_item.path or series_item.file) then
                                    n_books = n_books + 1
                                end
                            end
                        else
                            local function _cnt(dir, depth)
                                if depth > 5 then return end
                                local ok_d, it, obj = pcall(lfs.dir, dir)
                                if not ok_d then return end
                                for fname in it, obj do
                                    if fname ~= "." and fname ~= ".." and not fname:match("^%.") then
                                        local fpath = dir .. "/" .. fname
                                        local fmode = lfs.attributes(fpath, "mode")
                                        if fmode == "file" and DocReg:hasProvider(fpath) then
                                            n_books = n_books + 1
                                        elseif fmode == "directory" then
                                            _cnt(fpath, depth + 1)
                                        end
                                    end
                                end
                            end
                            _cnt(file, 0)
                        end
                        local folder_count_str = n_books > 0
                            and (n_books == 1 and _("1 book") or (tostring(n_books) .. " " .. _("books")))
                            or nil
                        local virtual_folder_str = is_series_group and _("Virtual folder") or nil
                        dialog_title = folder_name_str
                        if folder_count_str then
                            dialog_title = dialog_title .. "\n" .. folder_count_str
                        end
                        if virtual_folder_str then
                            dialog_title = dialog_title .. "\n" .. virtual_folder_str
                        end

                        local framed_h = cover_max_h + 2 * border
                        local text_col_w = math.max(avail_w - cover_max_w - 2 * border - gap, Screen:scaleBySize(60))
                        local vstack = VerticalGroup:new{ align = "left" }
                        table.insert(vstack, TextWidget:new{
                            text = folder_name_str,
                            face = library_font.getFace(20),
                            bold = true,
                            max_width = text_col_w,
                        })
                        if folder_count_str then
                            table.insert(vstack, VerticalSpan:new{ width = Screen:scaleBySize(2) })
                            table.insert(vstack, TextWidget:new{
                                text = folder_count_str,
                                face = library_font.getFace(17),
                                max_width = text_col_w,
                            })
                        end
                        if virtual_folder_str then
                            table.insert(vstack, VerticalSpan:new{ width = Screen:scaleBySize(2) })
                            table.insert(vstack, TextWidget:new{
                                text = virtual_folder_str,
                                face = library_font.getFace(14),
                                fgcolor = Blitbuffer.COLOR_GRAY_3,
                                max_width = text_col_w,
                            })
                        end

                        dialog_cover_widget = LeftContainer:new{
                            dimen = Geom:new{ w = avail_w, h = framed_h },
                            HorizontalGroup:new{
                                align = "center",
                                cover_widget,
                                HorizontalSpan:new{ width = gap },
                                vstack,
                            },
                        }
                    end
                end

                -- Placeholder cover (when no cover widget yet)
                if not dialog_cover_widget then
                    local Blitbuffer2 = require("ffi/blitbuffer")
                    local CenterContainer2 = require("ui/widget/container/centercontainer")
                    local FrameContainer2 = require("ui/widget/container/framecontainer")
                    local Geom2 = require("ui/geometry")
                    local HorizontalGroup2 = require("ui/widget/horizontalgroup")
                    local HorizontalSpan2 = require("ui/widget/horizontalspan")
                    local LeftContainer2 = require("ui/widget/container/leftcontainer")
                    local ImageWidget2 = require("ui/widget/imagewidget")
                    local TextWidget2 = require("ui/widget/textwidget")
                    local VerticalGroup2 = require("ui/widget/verticalgroup")
                    local VerticalSpan2 = require("ui/widget/verticalspan")

                    local ph_w = cover_max_w
                    local ph_h = math.floor(ph_w / ratio)  -- Respect ratio
                    local framed_h = ph_h + 2 * border

                    local final_bb = Cover.genCover(file, ph_w, ph_h)

                    local cover_img = ImageWidget2:new{
                        image = final_bb,
                        width = ph_w,
                        height = ph_h,
                    }

                    local ph_frame = FrameContainer2:new{
                        padding = 0,
                        bordersize = border,
                        width = ph_w + 2 * border,
                        height = ph_h + 2 * border,
                        background = Blitbuffer2.COLOR_WHITE,
                        CenterContainer2:new{
                            dimen = Geom2:new{ w = ph_w, h = ph_h },
                            cover_img,
                        },
                    }

                    local function apply_rounded(widget, bsz)
                        local plug = zen_plugin or rawget(_G, "__ZEN_UI_PLUGIN")
                        if not (plug and type(plug.config) == "table"
                            and type(plug.config.features) == "table"
                            and plug.config.features.browser_cover_rounded_corners == true)
                        then
                            return
                        end
                        local r = Screen:scaleBySize(6)
                        local r_inner = r - bsz
                        local orig_pt = widget.paintTo
                        widget.paintTo = function(widget_self, bb, x, y)
                            orig_pt(widget_self, bb, x, y)
                            if not (widget_self.dimen and widget_self.dimen.x) then return end
                            local tx, ty = widget_self.dimen.x, widget_self.dimen.y
                            local tw, th = widget_self.dimen.w, widget_self.dimen.h
                            local wh = Blitbuffer2.COLOR_WHITE
                            local blk = Blitbuffer2.COLOR_BLACK
                            for j = 0, r - 1 do
                                local inner = math.sqrt(r * r - (r - j) * (r - j))
                                local cut = math.ceil(r - inner)
                                if cut > 0 then
                                    bb:paintRect(tx, ty + j, cut, 1, wh)
                                    bb:paintRect(tx + tw - cut, ty + j, cut, 1, wh)
                                    bb:paintRect(tx, ty + th - 1 - j, cut, 1, wh)
                                    bb:paintRect(tx + tw - cut, ty + th - 1 - j, cut, 1, wh)
                                end
                            end
                            for j = 0, r - 1 do
                                for c = 0, r - 1 do
                                    local dx = r - c - 0.5
                                    local dy = r - j - 0.5
                                    local dist = math.sqrt(dx * dx + dy * dy)
                                    if dist >= r_inner and dist <= r then
                                        bb:paintRect(tx + c, ty + j, 1, 1, blk)
                                        bb:paintRect(tx + tw - 1 - c, ty + j, 1, 1, blk)
                                        bb:paintRect(tx + c, ty + th - 1 - j, 1, 1, blk)
                                        bb:paintRect(tx + tw - 1 - c, ty + th - 1 - j, 1, 1, blk)
                                    end
                                end
                            end
                        end
                    end
                    apply_rounded(ph_frame, border)

                    local text_col_w = math.max(
                        avail_w - ph_w - 2 * border - gap,
                        Screen:scaleBySize(60))
                    local vstack = VerticalGroup2:new{ align = "left" }

                    local title_line, sub_line = dialog_title, nil
                    if dialog_title then
                        local nl = dialog_title:find("\n")
                        if nl then
                            title_line = dialog_title:sub(1, nl - 1)
                            sub_line = dialog_title:sub(nl + 1)
                        end
                    end

                    if title_line then
                        table.insert(vstack, TextWidget2:new{
                            text = title_line,
                            face = library_font.getFace(20),
                            bold = true,
                            max_width = text_col_w,
                        })
                    end
                    if sub_line then
                        table.insert(vstack, VerticalSpan2:new{ width = Screen:scaleBySize(2) })
                        table.insert(vstack, TextWidget2:new{
                            text = sub_line,
                            face = library_font.getFace(17),
                            max_width = text_col_w,
                        })
                    end
                    if pages_str then
                        table.insert(vstack, VerticalSpan2:new{ width = Screen:scaleBySize(3) })
                        table.insert(vstack, TextWidget2:new{
                            text = pages_str,
                            face = library_font.getFace(14),
                            fgcolor = Blitbuffer2.COLOR_GRAY_3,
                            max_width = text_col_w,
                        })
                    end

                    dialog_cover_widget = LeftContainer2:new{
                        dimen = Geom2:new{ w = avail_w, h = framed_h },
                        HorizontalGroup2:new{
                            align = "center",
                            ph_frame,
                            HorizontalSpan2:new{ width = gap },
                            vstack,
                        },
                    }
                end
            end

            -- Edit submenu
            local function showEditSubmenu()
                if is_virtual_folder then return end
                close_dialog()
                local edit_dialog
                local has_selected_files = file_manager.selected_files
                    and next(file_manager.selected_files) ~= nil

                local function showSelectedFilesPasteDialog()
                    local action_dialog
                    local function paste_selected(cutfile)
                        UIManager:close(action_dialog)
                        file_manager.cutfile = cutfile
                        file_manager:showCopyMoveSelectedFilesDialog(function() end, file)
                    end
                    action_dialog = new_context_menu_dialog{
                        title = _("Paste selected files"),
                        title_align = "center",
                        buttons = apply_button_group_font({{
                            {
                                text = icons.copy .. "  " .. C_("File", "Copy"),
                                align = "left",
                                callback = function() paste_selected(false) end,
                            },
                            {
                                text = icons.move .. "  " .. _("Move"),
                                align = "left",
                                callback = function() paste_selected(true) end,
                            },
                        }}),
                    }
                    UIManager:show(action_dialog)
                end

                local function paste()
                    UIManager:close(edit_dialog)
                    if file_manager.clipboard then
                        file_manager:pasteFileFromClipboard(file)
                    elseif has_selected_files then
                        showSelectedFilesPasteDialog()
                    end
                end

                local function showFolderCoverDialog()
                    UIManager:close(edit_dialog)
                    local mode = Cover.getMode()
                    local slot_count = FolderCoverFiles.slotCount(mode)
                    if slot_count < 1 then return end

                    local existing = FolderCoverFiles.find(file, mode) or {}
                    local DocumentRegistry = require("document/documentregistry")
                    local active_config = zen_plugin and zen_plugin.config
                        or ConfigManager.get() or {}
                    local features = type(active_config.features) == "table"
                        and active_config.features or {}
                    local mosaic_specs
                    if self_fc.display_mode_type == "mosaic" then
                        mosaic_specs = self_fc._zen_file_cover_specs
                        if type(mosaic_specs) ~= "table" then
                            mosaic_specs = self_fc.cover_specs
                        end
                        if type(mosaic_specs) ~= "table" then mosaic_specs = nil end
                    end
                    local mosaic_uniform = features.browser_cover_mosaic_uniform == true
                    if mosaic_specs and type(mosaic_specs.uniform) == "boolean" then
                        mosaic_uniform = mosaic_specs.uniform
                    end
                    local mosaic_portrait
                    if mosaic_specs then
                        mosaic_portrait = Device.screen:getWidth()
                            <= Device.screen:getHeight()
                    end
                    FolderCoverPicker.show{
                        title = _("Set folder cover"),
                        path = file,
                        slot_count = slot_count,
                        covers = existing,
                        cover_ratio = Cover.getRatio(),
                        border = Cover.BORDER_SIZE,
                        uniform = mosaic_uniform,
                        mosaic_cover_width = mosaic_specs
                            and mosaic_specs.max_cover_w or nil,
                        mosaic_cover_height = mosaic_specs
                            and mosaic_specs.max_cover_h or nil,
                        mosaic_portrait = mosaic_portrait,
                        mosaic_cols_portrait = self_fc.nb_cols_portrait,
                        mosaic_rows_portrait = self_fc.nb_rows_portrait,
                        mosaic_cols_landscape = self_fc.nb_cols_landscape,
                        mosaic_rows_landscape = self_fc.nb_rows_landscape,
                        on_select = function(slot, update_preview)
                            UIManager:show(PathChooser:new{
                                select_directory = false,
                                select_file = true,
                                show_files = true,
                                path = file,
                                file_filter = function(filename)
                                    return FolderCoverFiles.isSupportedImage(filename)
                                        and DocumentRegistry:isImageFile(filename)
                                end,
                                onConfirm = function(source)
                                    local selected_path, err = FolderCoverFiles.set(
                                        file, mode, slot, source)
                                    if not selected_path then
                                        logger.warn("Failed to set folder cover",
                                            "folder=", file, "slot=", slot,
                                            "error=", tostring(err or "unknown"))
                                        local InfoMessage = require("ui/widget/infomessage")
                                        UIManager:show(InfoMessage:new{
                                            text = _("Failed to set folder cover."),
                                        })
                                        return
                                    end
                                    update_preview(selected_path)
                                    refresh_after_folder_cover_change(file)
                                end,
                            }, "full")
                        end,
                        on_clear = function(slot, update_preview)
                            local cleared, err = FolderCoverFiles.clear(
                                file, mode, slot)
                            if not cleared then
                                logger.warn("Failed to clear folder cover",
                                    "folder=", file, "slot=", slot,
                                    "error=", tostring(err or "unknown"))
                                local InfoMessage = require("ui/widget/infomessage")
                                UIManager:show(InfoMessage:new{
                                    text = _("Failed to clear folder cover."),
                                })
                                return
                            end
                            update_preview(nil)
                            refresh_after_folder_cover_change(file)
                        end,
                    }
                end

                if is_home_dir then
                    edit_dialog = new_context_menu_dialog{
                        buttons = apply_button_group_font({
                            {{
                                text = "\u{F0192}  " .. C_("File", "Paste"),
                                align = "left",
                                enabled = (file_manager.clipboard or has_selected_files) and true or false,
                                callback = paste,
                            }},
                        }),
                    }
                    UIManager:show(edit_dialog)
                    return
                end

                local edit_buttons = {
                    {
                        {
                            text = "\u{F0190}  " .. _("Cut"),
                            align = "left",
                            enabled = is_not_parent_folder,
                            callback = function()
                                UIManager:close(edit_dialog)
                                file_manager:cutFile(file)
                            end,
                        },
                    },
                    {
                        {
                            text = "\u{F018F}  " .. C_("File", "Copy"),
                            align = "left",
                            enabled = is_not_parent_folder,
                            callback = function()
                                UIManager:close(edit_dialog)
                                file_manager:copyFile(file)
                            end,
                        },
                    },
                    {
                        {
                            text = "\u{F0192}  " .. C_("File", "Paste"),
                            align = "left",
                            enabled = (file_manager.clipboard or has_selected_files) and true or false,
                            callback = paste,
                        },
                    },
                }
                if not item._zen_collection_name and not item._zen_disable_select then
                    table.insert(edit_buttons, 1, {
                        {
                            text = "\u{F0489}  " .. _("Select"),
                            align = "left",
                            callback = function()
                                UIManager:close(edit_dialog)
                                file_manager:onToggleSelectMode()
                                if type(item._zen_select_cb) == "function" then
                                    item._zen_select_cb()
                                elseif is_file and type(self_fc.onFileSelect) == "function" then
                                    self_fc:onFileSelect(item)
                                end
                            end,
                        },
                    })
                end
                if is_file then
                    table.insert(edit_buttons, {
                        {
                            text = icons.refresh .. "  " .. _("Refresh"),
                            align = "left",
                            callback = function()
                                UIManager:close(edit_dialog)
                                refresh_book_info()
                            end,
                        },
                    })
                else
                    local mode = Cover.getMode()
                    if FolderCoverFiles.slotCount(mode) > 0 then
                        table.insert(edit_buttons, {
                            {
                                text = icons.settings_covers .. "  " .. _("Set folder cover")
                                    .. "  " .. submenu_arrow,
                                align = "left",
                                callback = showFolderCoverDialog,
                            },
                        })
                    end
                end

                if is_file then
                    table.insert(edit_buttons, {
                        {
                            text = icons.edit .. "  " .. _("Edit metadata"),
                            align = "left",
                            callback = function()
                                UIManager:close(edit_dialog)
                                local bookinfo = file_manager.bookinfo
                                if not bookinfo.showFromBookDetails then
                                    bookinfo:show(file)
                                    return
                                end
                                local function refresh_metadata(updated_file)
                                    file = updated_file or file
                                    require("modules/filebrowser/metadata/service")
                                        .refreshLibrary(file_manager, file)
                                end
                                bookinfo:showFromBookDetails(file, nil, {
                                    on_renamed = refresh_metadata,
                                    on_saved = refresh_metadata,
                                    on_restored = refresh_metadata,
                                })
                            end,
                        },
                    })
                end

                local allow_delete = zen_plugin
                    and type(zen_plugin.config) == "table"
                    and type(zen_plugin.config.context_menu) == "table"
                    and zen_plugin.config.context_menu.allow_delete == true
                if allow_delete then
                    table.insert(edit_buttons, {
                        {
                            text = "\u{F0156}  " .. _("Delete"),
                            align = "left",
                            enabled = is_not_parent_folder,
                            callback = function()
                                UIManager:close(edit_dialog)
                                file_manager:showDeleteFileDialog(file, refresh)
                            end,
                        },
                    })
                end

                edit_dialog = new_context_menu_dialog{
                    buttons = apply_button_group_font(edit_buttons),
                }
                UIManager:show(edit_dialog)
            end

            -- Main dialog buttons
            local buttons = {}

            if is_file and is_not_parent_folder then
                table.insert(buttons, {
                    {
                        text = icons.details .. "  " .. _("Details"),
                        align = "left",
                        callback = function()
                            close_dialog()
                            require("modules/reader/book_details").showFile(file, {
                                config = zen_plugin and zen_plugin.config,
                                plugin = zen_plugin,
                                home_context = item._zen_home_context == true,
                            })
                        end,
                    },
                })
            end

            if not is_file and is_not_parent_folder and not is_home_dir and not is_virtual_folder then
                table.insert(buttons, {
                    {
                        text = "\u{F0CB6}  " .. _("Rename"),
                        align = "left",
                        callback = function()
                            close_dialog()
                            file_manager:showRenameFileDialog(file, is_file)
                        end,
                    },
                })
            end

            if item._is_current_dir then
                table.insert(buttons, {
                    {
                        text = "\u{F0B9D}  " .. _("New folder"),
                        align = "left",
                        callback = function()
                            close_dialog()
                            file_manager:createFolder()
                        end,
                    },
                })
            end

            if is_file and is_not_parent_folder and not item._zen_home_context then
                table.insert(buttons, {
                    {
                        text = "\u{F01BE}  " .. _("Move"),
                        align = "left",
                        callback = function()
                            close_dialog()
                            local ffiUtil = require("ffi/util")
                            local DocSettings = require("docsettings")
                            local ReadHistory = require("readhistory")
                            local ReadCollection = require("readcollection")
                            local lfs = require("libs/libkoreader-lfs")
                            local src = ffiUtil.realpath(file)
                            if not src then return end
                            local move_home_dir = paths.getHomeDir()
                                or file_chooser.path
                            if not move_home_dir then return end
                            local src_dir = ffiUtil.realpath(ffiUtil.dirname(src))
                            local _zen_cfg = require("config/manager").get()
                            local _extra = type(_zen_cfg) == "table"
                                and type(_zen_cfg.additional_home_dirs) == "table"
                                and _zen_cfg.additional_home_dirs or nil
                            local chooser = MoveChooser:new{
                                select_directory = true,
                                select_file = false,
                                show_files = true,
                                title = _("Move to…"),
                                path = move_home_dir,
                                src_dir = src_dir,
                                extra_roots = _extra,
                                onConfirm = function(dest_dir_real)
                                    local name = ffiUtil.basename(src)
                                    local dest_file = ffiUtil.joinPath(dest_dir_real, name)
                                    if lfs.attributes(dest_file) then
                                        local InfoMessage = require("ui/widget/infomessage")
                                        UIManager:show(InfoMessage:new{
                                            text = _("An item with that name already exists."),
                                            icon = "notice-warning",
                                        })
                                        return
                                    end
                                    if file_manager:moveFile(src, dest_dir_real) then
                                        if is_file then
                                            DocSettings.updateLocation(src, dest_file)
                                            ReadHistory:updateItem(src, dest_file)
                                            ReadCollection:updateItem(src, dest_file)
                                            local ok_bim2, bim2 = pcall(require, "bookinfomanager")
                                            if ok_bim2 and bim2 then
                                                local new_dir = ffiUtil.realpath(dest_dir_real)
                                                if new_dir then
                                                    pcall(bim2.setBookInfoProperties, bim2, src,
                                                        { directory = new_dir .. "/" })
                                                end
                                            end
                                        else
                                            ReadHistory:updateItemsByPath(src, dest_file)
                                            ReadCollection:updateItemsByPath(src, dest_file)
                                        end
                                        local real_cur = ffiUtil.realpath(file_chooser.path)
                                        local real_home = ffiUtil.realpath(home_dir)
                                        local at_home = real_cur == real_home
                                        local n = 0
                                        if not at_home then
                                            local ok3, iter3, dir3 = pcall(lfs.dir, file_chooser.path)
                                            if ok3 then
                                                for f3 in iter3, dir3 do
                                                    if f3 ~= "." and f3 ~= ".." then n = n + 1 end
                                                end
                                            end
                                        end
                                        if not at_home and n == 0 then
                                            UIManager:nextTick(function()
                                                file_chooser:changeToPath(home_dir)
                                            end)
                                        else
                                            refresh()
                                        end
                                    else
                                        local InfoMessage = require("ui/widget/infomessage")
                                        UIManager:show(InfoMessage:new{
                                            text = _("Move failed."),
                                            icon = "notice-warning",
                                        })
                                    end
                                end,
                            }
                            UIManager:show(chooser)
                        end,
                    },
                })
            end


            if is_file then
                local ReadCollection = require("readcollection")

                if item._zen_collection_name then
                    local coll_name = item._zen_collection_name
                    table.insert(buttons, {
                        {
                            text = "\u{F04D2}  " .. _("Remove from collection"),
                            align = "left",
                            callback = function()
                                close_dialog()
                                ReadCollection:removeItem(file, coll_name)
                                ReadCollection:write({ [coll_name] = true })
                                pcall(function()
                                    require("common/tbr_index").collectionChanged(coll_name)
                                end)
                                invalidate_home_book()
                                if item._zen_collection_refresh then
                                    UIManager:nextTick(item._zen_collection_refresh)
                                end
                            end,
                        },
                    })
                end

                if not item._zen_collection_name then
                    table.insert(buttons, {
                        {
                            text = "\u{F04CE}  " .. _("Add to collection") .. "  " .. submenu_arrow,
                            align = "left",
                            callback = function()
                                close_dialog()
                                local Menu_cp = require("ui/widget/menu")
                                local default_coll = ReadCollection.default_collection_name
                                local all_colls = {}
                                for cn, _v in pairs(ReadCollection.coll) do
                                    table.insert(all_colls, cn)
                                end
                                table.sort(all_colls, function(a, b)
                                    if a == default_coll then return true end
                                    if b == default_coll then return false end
                                    return a < b
                                end)
                                local items = {}
                                for _i, cn in ipairs(all_colls) do
                                    local display = cn == default_coll and _("Favorites") or cn
                                    local already_in = ReadCollection:isFileInCollection(file, cn)
                                    table.insert(items, {
                                        text = display .. (already_in and "  \u{2713}" or ""),
                                        mandatory = already_in and _("added") or nil,
                                        dim = already_in,
                                        _cn = cn,
                                    })
                                end
                                local coll_picker
                                coll_picker = Menu_cp:new{
                                    title = _("Add to collection"),
                                    item_table = items,
                                    is_borderless = true,
                                    is_popout = false,
                                    onMenuSelect = function(self_m, item_m)
                                        if item_m.dim then return true end
                                        UIManager:close(coll_picker)
                                        local TBRIndex = require("common/tbr_index")
                                        if item_m._cn == TBRIndex.collectionName() then
                                            TBRIndex.setExplicit(file, true)
                                        else
                                            ReadCollection:addItem(file, item_m._cn)
                                            ReadCollection:write({ [item_m._cn] = true })
                                        end
                                        pcall(function()
                                            TBRIndex.collectionChanged(item_m._cn)
                                        end)
                                        if item._zen_collection_refresh then
                                            UIManager:nextTick(item._zen_collection_refresh)
                                        end
                                        UIManager:nextTick(invalidate_home_book)
                                        return true
                                    end,
                                    close_callback = function()
                                        UIManager:close(coll_picker)
                                    end,
                                }
                                UIManager:show(coll_picker)
                            end,
                        },
                    })
                end
            end

            if is_file and is_not_parent_folder then
                table.insert(buttons, {
                    {
                        text = icons.read_status .. "  " .. _("Read status") .. "  " .. submenu_arrow,
                        align = "left",
                        callback = function()
                            close_dialog()
                            local filemanagerutil = require("apps/filemanager/filemanagerutil")
                            local BookList = require("ui/widget/booklist")
                            local DocSettings = require("docsettings")
                            local doc_settings = DocSettings:open(file)
                            local summary = doc_settings:readSetting("summary") or {}
                            local current_status = summary.status
                            local is_unread = not current_status or current_status == ""
                            local status_dialog
                            local is_explicit_tbr = false
                            pcall(function()
                                is_explicit_tbr = require("common/tbr_index").isExplicit(file)
                            end)

                            local function removeFromTBR()
                                pcall(function()
                                    require("common/tbr_index").setExplicit(file, false)
                                end)
                            end

                            local function setStatus(to_status)
                                book_status.acknowledgeNewVersion(doc_settings)
                                removeFromTBR()
                                if to_status == nil then
                                    summary.status = nil
                                    doc_settings:delSetting("percent_finished")
                                    doc_settings:delSetting("last_page")
                                    doc_settings:delSetting("last_xpointer")
                                else
                                    summary.status = to_status
                                end
                                filemanagerutil.saveSummary(doc_settings, summary)
                                BookList.setBookInfoCacheProperty(file, "status", to_status)
                                book_status.invalidate(file)
                                pcall(function()
                                    require("common/tbr_index").refreshPath(file, doc_settings)
                                end)
                                if to_status == nil then
                                    -- Snapshot pages before reset: setBookInfoCacheProperty("been_opened", false)
                                    -- replaces the whole cache entry with {been_opened=false}, losing pages.
                                    local saved_pages = BookList.book_info_cache
                                        and BookList.book_info_cache[file]
                                        and BookList.book_info_cache[file].pages
                                    BookList.setBookInfoCacheProperty(file, "been_opened", false)
                                    if saved_pages then
                                        BookList.book_info_cache[file].pages = saved_pages
                                    end
                                end
                                UIManager:close(status_dialog)
                                if type(item._zen_after_status_change) == "function" then
                                    UIManager:nextTick(function()
                                        item._zen_after_status_change(file)
                                    end)
                                else
                                    refresh()
                                end
                            end

                            local function setTBR()
                                pcall(function()
                                    require("common/tbr_index").setExplicit(file, true)
                                end)
                                UIManager:close(status_dialog)
                                if type(item._zen_after_status_change) == "function" then
                                    UIManager:nextTick(function()
                                        item._zen_after_status_change(file)
                                    end)
                                else
                                    refresh()
                                end
                            end

                            local function statusBtn(icon, label, to_status)
                                local is_cur = (to_status == "tbr" and is_explicit_tbr)
                                    or (not is_explicit_tbr and ((to_status == nil and is_unread)
                                        or (to_status ~= nil and current_status == to_status)))
                                return {{
                                    text = icon .. "  " .. label .. (is_cur and "  \u{2713}" or ""),
                                    align = "left",
                                    enabled = not is_cur,
                                    callback = function()
                                        if to_status == "tbr" then setTBR()
                                        else setStatus(to_status) end
                                    end,
                                }}
                            end

                            status_dialog = new_context_menu_dialog{
                                title = _("Read status"),
                                title_align = "center",
                                buttons = apply_button_group_font({
                                    statusBtn(icons.status, _("Unread"), nil),
                                    statusBtn(icons.reading, _("Reading"), "reading"),
                                    statusBtn(icons.tbr, _("To Be Read"), "tbr"),
                                    statusBtn(icons.on_hold, _("On hold"), "abandoned"),
                                    statusBtn(icons.finished, _("Finished"), "complete"),
                                }),
                            }
                            UIManager:show(status_dialog)
                        end,
                    },
                })
            end

            if is_file and is_not_parent_folder and item._zen_home_context then
                table.insert(buttons, {
                    {
                        text = icons.refresh .. "  " .. _("Refresh"),
                        align = "left",
                        callback = function()
                            close_dialog()
                            refresh_book_info()
                        end,
                    },
                })
            end

            if is_virtual_folder or (not is_file and is_not_parent_folder) then
                local function showViewSubmenu()
                    close_dialog()
                    local ok_fm, FM = pcall(require, "apps/filemanager/filemanager")
                    local fm = ok_fm and FM and FM.instance
                    local ok_bim, bim = pcall(require, "bookinfomanager")
                    local fdm_api = rawget(_G, "__ZEN_FOLDER_DISPLAY_MODE")
                    local ffiUtil_view = require("ffi/util")
                    local display_folder = (is_virtual_folder and item._zen_sort_key) or file
                    local real_folder = ffiUtil_view.realpath(display_folder) or display_folder
                    local folder_override = (not is_primary_home) and fdm_api
                        and fdm_api.get(real_folder) or nil
                    local cur_mode
                    if folder_override then
                        cur_mode = folder_override
                    elseif is_virtual_folder and fdm_api
                            and type(fdm_api.current) == "function" then
                        cur_mode = fdm_api.current()
                    end
                    if not cur_mode and ok_bim and bim then
                        local ok3, m = pcall(function()
                            return bim:getSetting("filemanager_display_mode")
                        end)
                        if ok3 then cur_mode = m end
                    end
                    local function apply_mode(mode)
                        if not is_primary_home and fdm_api then
                            fdm_api.set(real_folder, mode)
                            -- Only re-render the live view when the override is for
                            -- the folder currently open. Holding a sub-folder from
                            -- its parent stores the override; it applies on entry.
                            if is_current_view and type(fdm_api.apply) == "function" then
                                fdm_api.apply(real_folder)
                                refresh()
                            end
                        elseif fm and type(fm.onSetDisplayMode) == "function" then
                            pcall(fm.onSetDisplayMode, fm, mode)
                        elseif ok_bim and bim then
                            pcall(bim.saveSetting, bim, "filemanager_display_mode", mode)
                        end
                    end
                    local view_dialog
                    local function viewBtn(label, icon, mode)
                        local active = cur_mode == mode
                        return {{
                            text = icon .. "  " .. label .. (active and "  \u{2713}" or ""),
                            align = "left",
                            enabled = not active,
                            callback = function()
                                UIManager:close(view_dialog)
                                apply_mode(mode)
                            end,
                        }}
                    end
                    view_dialog = new_context_menu_dialog{
                        title = _("Display mode"),
                        title_align = "center",
                        buttons = apply_button_group_font({
                            viewBtn(_("Mosaic"), "\u{F11D9}", "mosaic_image"),
                            viewBtn(_("List (detailed)"), "\u{F148B}", "list_image_meta"),
                            viewBtn(_("List (basic)"), "\u{F0279}", "list_image_filename"),
                        }),
                    }
                    UIManager:show(view_dialog)
                end

                table.insert(buttons, {
                    {
                        text = "\u{F06D0}  " .. _("Display") .. "  " .. submenu_arrow,
                        align = "left",
                        callback = showViewSubmenu,
                    },
                })
            end

            if not is_file and is_not_parent_folder then
                local SORT_OPTIONS = {
                    { key = "title", text = "\u{F031}  " .. _("Title") },
                    { key = "title_natural", text = "\u{F04BB}  " .. _("Title natural") },
                    { key = "strcoll", text = icons.filename .. "  " .. _("Filename") },
                    { key = "authors", text = "\u{F0013}  " .. _("Authors") },
                    { key = "series", text = "\u{F0436}  " .. _("Series") },
                    { key = "access", text = "\u{F02DA}  " .. _("Recently read") },
                }

                if is_primary_home then
                    local g_sort = rawget(_G, "G_reader_settings")
                    if g_sort then
                        table.insert(buttons, {
                            {
                                text = "\u{F04BF}  " .. _("Sort library") .. "  " .. submenu_arrow,
                                align = "left",
                                callback = function()
                                    close_dialog()
                                    local sort_dialog
                                    local sort_buttons = {}
                                    local cur = g_sort:readSetting("collate", "strcoll")
                                    local cur_reverse = g_sort:isTrue("reverse_collate")
                                    for _i, opt in ipairs(SORT_OPTIONS) do
                                        local is_active = cur == opt.key
                                        table.insert(sort_buttons, {{
                                            text = opt.text .. (is_active and "  \u{2713}" or ""),
                                            align = "left",
                                            enabled = not is_active,
                                            callback = function()
                                                g_sort:saveSetting("collate", opt.key)
                                                UIManager:close(sort_dialog)
                                                refresh_after_sort_change()
                                            end,
                                        }})
                                    end
                                    table.insert(sort_buttons, {{
                                        text = "\u{F04BF}  " .. _("Order") .. "  " .. submenu_arrow,
                                        align = "left",
                                        callback = function()
                                            UIManager:close(sort_dialog)
                                            self_fc:showSortOrderDialog({
                                                current_reverse = cur_reverse,
                                                on_select = function(reverse)
                                                    if reverse then
                                                        g_sort:saveSetting("reverse_collate", true)
                                                    else
                                                        g_sort:delSetting("reverse_collate")
                                                    end
                                                    refresh_after_sort_change()
                                                end,
                                            })
                                        end,
                                    }})
                                    sort_dialog = new_context_menu_dialog{
                                        title = _("Sort library by"),
                                        title_align = "center",
                                        buttons = apply_button_group_font(sort_buttons),
                                    }
                                    UIManager:show(sort_dialog)
                                end,
                            },
                        })
                    end
                else
                    local fsd_api = rawget(_G, "__ZEN_FOLDER_SORT")
                    if fsd_api then
                        local ffiUtil_fsd = require("ffi/util")
                        local real_folder = (is_virtual_folder and item._zen_sort_key)
                            or ffiUtil_fsd.realpath(file)
                            or file

                        table.insert(buttons, {
                            {
                                text = "\u{F04BF}  " .. _("Sort folder") .. "  " .. submenu_arrow,
                                align = "left",
                                callback = function()
                                    close_dialog()
                                    local sort_dialog
                                    local sort_buttons = {}
                                    local current_override = fsd_api.get(real_folder)
                                    local cur_collate = current_override and current_override.collate
                                    local cur_reverse = current_override and current_override.reverse or false
                                    for _i, opt in ipairs(SORT_OPTIONS) do
                                        local is_active = cur_collate == opt.key
                                        table.insert(sort_buttons, {{
                                            text = opt.text .. (is_active and "  \u{2713}" or ""),
                                            align = "left",
                                            enabled = not is_active,
                                            callback = function()
                                                fsd_api.set(real_folder, opt.key, cur_reverse)
                                                UIManager:close(sort_dialog)
                                                refresh_after_sort_change(real_folder)
                                            end,
                                        }})
                                    end
                                    table.insert(sort_buttons, {{
                                        text = "\u{F04BF}  " .. _("Order") .. "  " .. submenu_arrow,
                                        align = "left",
                                        callback = function()
                                            UIManager:close(sort_dialog)
                                            self_fc:showSortOrderDialog({
                                                current_reverse = cur_reverse,
                                                on_select = function(reverse)
                                                    if cur_collate then
                                                        fsd_api.set(real_folder, cur_collate, reverse)
                                                        refresh_after_sort_change(real_folder)
                                                    end
                                                end,
                                            })
                                        end,
                                    }})
                                    if current_override then
                                        table.insert(sort_buttons, {})
                                        table.insert(sort_buttons, {{
                                            text = "\u{F099B}  " .. _("Clear"),
                                            align = "left",
                                            callback = function()
                                                fsd_api.clear(real_folder)
                                                UIManager:close(sort_dialog)
                                                refresh_after_sort_change(real_folder)
                                            end,
                                        }})
                                    end
                                    sort_dialog = new_context_menu_dialog{
                                        title = _("Sort folder by"),
                                        title_align = "center",
                                        buttons = apply_button_group_font(sort_buttons),
                                    }
                                    UIManager:show(sort_dialog)
                                end,
                            },
                        })
                    end
                end
            end

            if item._is_current_dir then
                local function showFilterDialog()
                    local cur_st = FileChooser.show_filter and FileChooser.show_filter.status
                    local is_all = cur_st == nil
                    local filter_dialog

                    local function setFilter(new_status)
                        FileChooser.show_filter.status = new_status
                        local gs = rawget(_G, "G_reader_settings")
                        if gs then
                            gs:saveSetting("show_filter", FileChooser.show_filter)
                            pcall(gs.flush, gs)
                        end
                        self_fc:refreshPath()
                    end

                    local STATUS_OPTS = {
                        { key = "new", icon = icons.status, label = _("Unread") },
                        { key = "reading", icon = icons.reading, label = _("Reading") },
                        { key = "tbr", icon = icons.tbr, label = _("To Be Read") },
                        { key = "abandoned", icon = icons.on_hold, label = _("On hold") },
                        { key = "complete", icon = icons.finished, label = _("Finished") },
                    }

                    local fbts = {}
                    table.insert(fbts, {{
                        text = _("All") .. (is_all and "  " .. icons.check or ""),
                        align = "left",
                        enabled = not is_all,
                        callback = function()
                            UIManager:close(filter_dialog)
                            setFilter(nil)
                        end,
                    }})
                    for _i, st in ipairs(STATUS_OPTS) do
                        local is_active = cur_st and cur_st[st.key] == true
                        table.insert(fbts, {{
                            text = st.icon .. "  " .. st.label .. (is_active and "  " .. icons.check or ""),
                            align = "left",
                            callback = function()
                                UIManager:close(filter_dialog)
                                local new_st = {}
                                if cur_st then
                                    for k, v in pairs(cur_st) do new_st[k] = v end
                                end
                                if new_st[st.key] then
                                    new_st[st.key] = nil
                                else
                                    new_st[st.key] = true
                                end
                                local n = 0
                                for _k, v in pairs(new_st) do if v then n = n + 1 end end
                                if n == 0 or n == #STATUS_OPTS then setFilter(nil)
                                else setFilter(new_st) end
                                UIManager:nextTick(showFilterDialog)
                            end,
                        }})
                    end

                    filter_dialog = new_context_menu_dialog{
                        title = _("Filter by status"),
                        title_align = "center",
                        buttons = apply_button_group_font(fbts),
                    }
                    UIManager:show(filter_dialog)
                end

                local n_active = 0
                if FileChooser.show_filter and FileChooser.show_filter.status then
                    for _k, v in pairs(FileChooser.show_filter.status) do
                        if v then n_active = n_active + 1 end
                    end
                end
                table.insert(buttons, {
                    {
                        text = icons.filter .. "  " .. _("Filter")
                            .. (n_active > 0 and " (" .. n_active .. ")" or "")
                            .. "  " .. submenu_arrow,
                        align = "left",
                        callback = function()
                            close_dialog()
                            UIManager:nextTick(showFilterDialog)
                        end,
                    },
                })
            end

            if not is_virtual_folder then
                table.insert(buttons, {
                    {
                        text = "\u{F090C}  " .. _("Edit") .. "  " .. submenu_arrow,
                        align = "left",
                        callback = showEditSubmenu,
                    },
                })
            end

            if item._zen_extra_buttons then
                for _i, row in ipairs(item._zen_extra_buttons) do
                    table.insert(buttons, row)
                end
            end

            if is_file and item._zen_is_history then
                table.insert(buttons, {
                    {
                        text = icons.delete .. "  " .. _("Remove from history"),
                        align = "left",
                        callback = function()
                            close_dialog()
                            local ConfirmBox = require("ui/widget/confirmbox")
                            UIManager:show(ConfirmBox:new{
                                text = _("Remove this book from history?"),
                                ok_text = _("Remove"),
                                ok_callback = function()
                                    local ReadHistory = require("readhistory")
                                    ReadHistory:removeItemByPath(file)
                                    local plug = zen_plugin or rawget(_G, "__ZEN_UI_PLUGIN")
                                    local home = plug and SharedState.get(plug, "home")
                                    if home and home.rebuildActive then
                                        UIManager:nextTick(function()
                                            if type(home.invalidateBookCache) == "function" then
                                                home.invalidateBookCache(file, true)
                                            end
                                            home.rebuildActive()
                                        end)
                                    end
                                end,
                            })
                        end,
                    },
                })
            end

            local dlg_title = dialog_cover_widget and "" or dialog_title
            if type(item._zen_widget_settings) == "function" then
                table.insert(buttons, {
                    {
                        text = icons.settings .. "  " .. _("Widget settings"),
                        align = "left",
                        callback = function()
                            close_dialog()
                            UIManager:nextTick(item._zen_widget_settings)
                        end,
                    },
                })
            end
            self_fc.file_dialog = new_context_menu_dialog{
                title = dlg_title ~= "" and dlg_title or nil,
                title_align = "center",
                buttons = apply_button_group_font(buttons),
                _added_widgets = dialog_cover_widget and { dialog_cover_widget } or nil,
            }
            UIManager:show(self_fc.file_dialog)
            return true
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
                    if not paths.isInHomeDir(cur_path_bh) then return false end
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
