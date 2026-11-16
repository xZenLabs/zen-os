-- modules/filebrowser/patches/library_background.lua
-- Paints the configured library background image behind the file browser.
-- The hook lives on FileManager because FileChooser and its root frame are
-- rebuilt during navigation and menu refreshes.

local function apply_library_background()
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok_fm or type(FileManager) ~= "table" then return end
    if FileManager._zen_bg_patched then return end
    FileManager._zen_bg_patched = true

    local Device = require("device")
    local Background = require("common/ui/background")
    local UIManager = require("ui/uimanager")
    local WidgetContainer = require("ui/widget/container/widgetcontainer")
    local Screen = Device.screen
    local zen_plugin = rawget(_G, "__ZEN_UI_PLUGIN")

    local function background_path()
        return Background.library_path(zen_plugin)
    end

    local function clear_backgrounds(fm)
        if not fm then return end
        Background.clearWhiteBackgrounds(fm[1], 14)
        if fm.file_chooser then
            Background.clearWhiteBackgrounds(fm.file_chooser, 14)
        end
    end

    local function is_active()
        return background_path() ~= ""
    end

    local function find_active_library_surface(fm)
        local stack = UIManager._window_stack
        if type(stack) ~= "table" then return end
        for index = #stack, 1, -1 do
            local widget = stack[index] and stack[index].widget
            local is_filemanager = widget
                and (widget == fm or widget == fm.show_parent)
            if is_filemanager or (widget and (widget._zen_navbar_tab_id
                    or widget._zen_bg_applied)) then
                for upper = index + 1, #stack do
                    local blocker = stack[upper] and stack[upper].widget
                    if blocker and not blocker.invisible
                            and not blocker.modal and not blocker.toast then
                        return
                    end
                end
                return widget, is_filemanager,
                    not is_filemanager and widget._zen_navbar_tab_id or nil
            end
        end
    end

    local function close_library_view(widget)
        if type(widget.close_callback) == "function" then
            widget.close_callback()
        elseif type(widget.onClose) == "function" then
            widget:onClose()
        else
            UIManager:close(widget)
        end
    end

    local function close_zen_library_views(fm)
        local stack = UIManager._window_stack
        if type(stack) ~= "table" then return end
        local to_close = {}
        for index = #stack, 1, -1 do
            local widget = stack[index] and stack[index].widget
            if widget and widget ~= fm and widget ~= fm.show_parent
                    and (widget._zen_navbar_tab_id or widget._zen_bg_applied) then
                to_close[#to_close + 1] = widget
            end
        end
        for _i, widget in ipairs(to_close) do
            local shown = false
            for index = #stack, 1, -1 do
                if stack[index] and stack[index].widget == widget then
                    shown = true
                    break
                end
            end
            if shown then close_library_view(widget) end
        end
    end

    Background.setMissingLibraryBackgroundHandler(function()
        local fm = FileManager.instance
        if not fm then return false end
        local surface, is_filemanager, tab_id = find_active_library_surface(fm)
        if not surface then return false end
        local reopen = surface._zen_library_bg_reopen
        if type(reopen) ~= "function" then
            local open_tab = rawget(_G, "__ZEN_UI_NAVBAR_OPEN_TAB")
            if tab_id and type(open_tab) == "function" then
                reopen = function() return open_tab(tab_id) end
            end
        end
        if not is_filemanager and type(reopen) ~= "function" then
            return false
        end
        local page = tonumber(surface.page)

        close_zen_library_views(fm)
        if type(fm.reinit) == "function" then
            fm:reinit()
        end
        if is_filemanager then
            UIManager:setDirty(fm.show_parent or fm, "ui")
            return true
        end
        if reopen() ~= true then return false end
        if page and page > 1 then
            local reopened = find_active_library_surface(fm)
            if reopened and reopened ~= surface and type(reopened.updateItems) == "function" then
                reopened.page = page
                reopened:updateItems()
            end
        end
        return true
    end)

    local ok_tbw, TextBoxWidget = pcall(require, "ui/widget/textboxwidget")
    if ok_tbw and TextBoxWidget and not TextBoxWidget._zen_bg_patched then
        local Blitbuffer = require("ffi/blitbuffer")
        local orig_textbox_paintTo = TextBoxWidget.paintTo
        TextBoxWidget._zen_bg_patched = true
        TextBoxWidget.paintTo = function(tbw_self, bb, x, y)
            if not (is_active() and Background.isWhite(tbw_self.bgcolor)) then
                return orig_textbox_paintTo(tbw_self, bb, x, y)
            end
            if not tbw_self._bb then
                tbw_self:_updateLayout()
            end
            if not tbw_self._bb then
                return orig_textbox_paintTo(tbw_self, bb, x, y)
            end
            tbw_self.dimen.x, tbw_self.dimen.y = x, y
            local w = tbw_self.width
            local h = tbw_self._bb:getHeight()
            if not tbw_self._zen_bg_tmp_bb
                    or tbw_self._zen_bg_tmp_bb:getWidth() ~= w
                    or tbw_self._zen_bg_tmp_bb:getHeight() ~= h then
                if tbw_self._zen_bg_tmp_bb then
                    tbw_self._zen_bg_tmp_bb:free()
                end
                tbw_self._zen_bg_tmp_bb = Blitbuffer.new(w, h, Blitbuffer.TYPE_BB8)
            end
            local tmp = tbw_self._zen_bg_tmp_bb
            tmp:fill(Blitbuffer.COLOR_WHITE)
            tmp:blitFrom(tbw_self._bb, 0, 0, 0, 0, w, h)
            tmp:invertRect(0, 0, w, h)
            bb:colorblitFromRGB32(tmp, x, y, 0, 0, w, h,
                tbw_self.fgcolor or Blitbuffer.COLOR_BLACK)
        end

        local orig_textbox_free = TextBoxWidget.free
        TextBoxWidget.free = function(tbw_self, ...)
            if tbw_self._zen_bg_tmp_bb then
                tbw_self._zen_bg_tmp_bb:free()
                tbw_self._zen_bg_tmp_bb = nil
            end
            if orig_textbox_free then
                return orig_textbox_free(tbw_self, ...)
            end
        end
    end

    local ok_iw, IconWidget = pcall(require, "ui/widget/iconwidget")
    if ok_iw and IconWidget and not IconWidget._zen_bg_patched then
        local orig_icon_init = IconWidget.init
        IconWidget._zen_bg_patched = true
        IconWidget.init = function(iw_self, ...)
            orig_icon_init(iw_self, ...)
            if is_active() and iw_self.alpha == nil then
                iw_self.alpha = true
                iw_self.original_in_nightmode = false
            end
        end
    end

    local ok_uc, UnderlineContainer = pcall(require, "ui/widget/container/underlinecontainer")
    if ok_uc and UnderlineContainer and not UnderlineContainer._zen_bg_patched then
        local Geom = require("ui/geometry")
        local orig_underline_paintTo = UnderlineContainer.paintTo
        UnderlineContainer._zen_bg_patched = true
        UnderlineContainer.paintTo = function(uc_self, bb, x, y)
            if not (is_active() and Background.isWhite(uc_self.color)) then
                return orig_underline_paintTo(uc_self, bb, x, y)
            end
            local container_size = uc_self:getSize()
            if not uc_self.dimen then
                uc_self.dimen = Geom:new{
                    x = x, y = y,
                    w = container_size.w,
                    h = container_size.h,
                }
            else
                uc_self.dimen.x = x
                uc_self.dimen.y = y
            end
            local content_size = uc_self[1]:getSize()
            local p_y = y
            if uc_self.vertical_align == "center" then
                p_y = math.floor((container_size.h - content_size.h) / 2) + y
            elseif uc_self.vertical_align == "bottom" then
                p_y = (container_size.h - content_size.h) + y
            end
            uc_self[1]:paintTo(bb, x, p_y)
        end
    end

    local orig_setupLayout = FileManager.setupLayout
    function FileManager:setupLayout(...)
        -- Paint hooks use a memoized path; re-check the file whenever the library is shown.
        Background.invalidateLibraryPath()
        local ret = orig_setupLayout(self, ...)
        if is_active() then clear_backgrounds(self) end
        return ret
    end

    local orig_onResume = FileManager.onResume
    function FileManager:onResume(...)
        Background.invalidateLibraryPath()
        if orig_onResume then return orig_onResume(self, ...) end
    end

    local orig_paintTo = FileManager.paintTo
    function FileManager:paintTo(bb, x, y)
        local path = background_path()
        if path ~= "" then
            clear_backgrounds(self)
            Background.paintScreenRegion(bb, 0, 0, 0, 0,
                Screen:getWidth(), Screen:getHeight(), path)
        end
        if orig_paintTo then
            return orig_paintTo(self, bb, x, y)
        end
        return WidgetContainer.paintTo(self, bb, x, y)
    end
end

return apply_library_background
