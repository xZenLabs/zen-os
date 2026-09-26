local function apply_book_double_tap()
    local BookOpenTap = require("common/book_open_tap")
    local Cover = require("common/cover_utils")
    local WidgetResources = require("common/widget_resources")

    local function book_path(widget)
        local entry = widget and widget.entry
        if type(entry) ~= "table" then return nil end
        local is_file = widget._zen_is_book == true
            or entry.is_file == true
            or type(entry.file) == "string"
            or (type(entry.attr) == "table" and entry.attr.mode == "file")
        if not is_file then return nil end
        return entry.path or entry.file or entry.filepath or widget.filepath
    end

    local function is_select_mode(widget)
        local menu = widget and widget.menu
        local manager = menu and menu._manager
        if manager and manager.selected_files ~= nil then return true end
        local ui = menu and menu.ui
        if ui and ui.selected_files ~= nil then return true end

        local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
        local file_manager = ok and FileManager and FileManager.instance
        return file_manager and file_manager.selected_files ~= nil or false
    end

    local function patch_item_class(ItemClass)
        if type(ItemClass) ~= "table" or ItemClass._zen_book_double_tap_patched
                or type(ItemClass.onTapSelect) ~= "function" then
            return
        end
        ItemClass._zen_book_double_tap_patched = true

        local original_onTapSelect = ItemClass.onTapSelect
        function ItemClass:onTapSelect(arg, ges, ...)
            if not ges or ges.time == nil then
                BookOpenTap.reset()
                return original_onTapSelect(self, arg, ges, ...)
            end
            local path = book_path(self)
            if not path or is_select_mode(self) then
                BookOpenTap.reset()
                return original_onTapSelect(self, arg, ges, ...)
            end
            if not BookOpenTap.shouldOpen(path, ges.time, function()
                if not is_select_mode(self) then self:onHoldSelect(arg, ges) end
            end) then return true end
            return original_onTapSelect(self, arg, ges, ...)
        end
        local original_onHoldSelect = ItemClass.onHoldSelect
        if original_onHoldSelect then
            function ItemClass:onHoldSelect(...)
                BookOpenTap.reset()
                return original_onHoldSelect(self, ...)
            end
        end
        WidgetResources.wrapFree(ItemClass, BookOpenTap.reset)
    end

    local Menu = require("ui/widget/menu")
    patch_item_class(Cover.getUpvalue(Menu.updateItems, "MenuItem"))

    local ok_list, ListMenu = pcall(require, "listmenu")
    if ok_list and ListMenu then
        patch_item_class(Cover.getUpvalue(ListMenu._updateItemsBuildUI, "ListMenuItem"))
    end

    local ok_mosaic, MosaicMenu = pcall(require, "mosaicmenu")
    if ok_mosaic and MosaicMenu then
        patch_item_class(MosaicMenu._zen_mosaic_item_class)
    end
end

return apply_book_double_tap
