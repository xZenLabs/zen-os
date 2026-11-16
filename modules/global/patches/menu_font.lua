-- menu_font.lua
-- Applies the user's custom library font family to ALL KOReader UI text by
-- rewriting Font.fontmap — the global mapping from named faces ("cfont",
-- "smallinfofont", "infofont", "ffont", etc.) to TTF files.  Every call to
-- Font:getFace() anywhere in KOReader then automatically resolves to our font.
-- For widgets that may already be loaded before this patch runs (e.g. Button),
-- we also override their class-level defaults.
--
-- Approach adapted from sebdelsol/KOReader.patches (2--ui-font.lua).

local function apply_menu_font()
    local logger = require("common/zen_logger").new("menu_font")
    local Font = require("ui/font")
    local library_font = require("modules/filebrowser/patches/library_font")
    local font_name = library_font.getFontName()

    logger.dbg("library_font.getFontName() =", font_name)

    if font_name == "cfont" then
        logger.dbg("font_name is cfont, no-op")
        return
    end

    -- ---- Derive bold variant ----
    local bold_name = font_name:gsub("%-Regular%.", "-Bold.", 1)
    if bold_name == font_name then
        bold_name = font_name:gsub("%.ttf", "-Bold.ttf", 1)
    end
    logger.dbg("bold_name =", bold_name)

    -- ---- Determine default KOReader regular / bold TTFs ----
    local def_regular = Font.fontmap and Font.fontmap["cfont"] or "NotoSans-Regular.ttf"
    local def_bold    = Font.fontmap and Font.fontmap["ffont"] or "NotoSans-Bold.ttf"
    logger.dbg("def_regular =", def_regular, "def_bold =", def_bold)

    -- ---- Rewrite Font.fontmap ----
    if Font.fontmap and font_name ~= def_regular then
        local count = 0
        for name, file in pairs(Font.fontmap) do
            if file == def_regular then
                Font.fontmap[name] = font_name
                count = count + 1
            elseif file == def_bold then
                Font.fontmap[name] = bold_name
                count = count + 1
            end
        end
        logger.dbg("fontmap entries rewritten:", count)
        logger.dbg("after rewrite fontmap['smallinfofont'] =", Font.fontmap["smallinfofont"])
        logger.dbg("after rewrite fontmap['cfont'] =", Font.fontmap["cfont"])
    else
        logger.dbg("fontmap skip — fontmap=", Font.fontmap ~= nil, "same_regular=", font_name == def_regular)
    end

    -- ---- Re-patch already-loaded local classes ----
    -- TouchMenuItem / MenuItem are module locals loaded before this patch, so
    -- their class faces are stale. Patch them once via updateItems' upvalues
    -- (followed through earlier wrappers).
    local find_class = require("common/utils").findUpvalueTable

    local function patch_touch_item(cls)
        cls.face = Font:getFace("smallinfofont", cls.face.orig_size or 18)
    end
    local function patch_menu_item(cls)
        cls.font = font_name
        cls.infont = font_name
    end

    -- Fallback when the class isn't reachable: grab it from the first built
    -- instance, patch once, rebuild that menu.
    local function wrap_once(Widget, accept, patch)
        local orig_updateItems = Widget.updateItems
        local done = false
        Widget.updateItems = function(self, ...)
            orig_updateItems(self, ...)
            if done then return end
            for _i = 1, #self.item_group do
                local widget = self.item_group[_i]
                local cls = type(widget) == "table" and accept(widget) and getmetatable(widget)
                if cls then
                    done = true
                    patch(cls)
                    return orig_updateItems(self, ...)
                end
            end
        end
    end

    local ok_tm, TouchMenu = pcall(require, "ui/widget/touchmenu")
    if ok_tm and TouchMenu and not TouchMenu.__zen_patched then
        TouchMenu.__zen_patched = true
        local TouchMenuItem = find_class(TouchMenu.updateItems, "TouchMenuItem")
        if TouchMenuItem and TouchMenuItem.face then
            patch_touch_item(TouchMenuItem)
        else
            logger.dbg("TouchMenuItem not found; using updateItems fallback")
            wrap_once(TouchMenu, function(w) return w.item and w.face end, patch_touch_item)
        end
    end

    local ok_m, Menu = pcall(require, "ui/widget/menu")
    if ok_m and Menu and not Menu.__zen_patched then
        Menu.__zen_patched = true
        local MenuItem = find_class(Menu.updateItems, "MenuItem")
        if MenuItem and MenuItem.font then
            patch_menu_item(MenuItem)
        else
            logger.dbg("MenuItem not found; using updateItems fallback")
            wrap_once(Menu, function(w) return w.face end, patch_menu_item)
        end
    end

    -- ---- Per-widget overrides for modules already loaded ----
    -- These widgets may have been require()d before our fontmap rewrite;
    -- their class-level face properties hold stale Font:getFace() results.
    -- Override them so new instances built after this point use our font.

    local ok_btn, Button = pcall(require, "ui/widget/button")
    if ok_btn and Button then
        Button.text_font_face = font_name
    end

    if ok_tm and TouchMenu and TouchMenu.fface then
        local orig_size = TouchMenu.fface.orig_size or 24
        TouchMenu.fface = Font:getFace(font_name, orig_size)
    end

    local ok_cb, ConfirmBox = pcall(require, "ui/widget/confirmbox")
    if ok_cb and ConfirmBox and ConfirmBox.face then
        local orig_size = ConfirmBox.face.orig_size or 22
        ConfirmBox.face = Font:getFace(font_name, orig_size)
    end

    local ok_mcb, MultiConfirmBox = pcall(require, "ui/widget/multiconfirmbox")
    if ok_mcb and MultiConfirmBox and MultiConfirmBox.face then
        local orig_size = MultiConfirmBox.face.orig_size or 22
        MultiConfirmBox.face = Font:getFace(font_name, orig_size)
    end

    local ok_im, InfoMessage = pcall(require, "ui/widget/infomessage")
    if ok_im and InfoMessage then
        local def_face = Font:getFace("infofont")
        local orig_size = def_face.orig_size or 22
        InfoMessage.face = Font:getFace(font_name, orig_size)
    end

    local ok_id, InputDialog = pcall(require, "ui/widget/inputdialog")
    if ok_id and InputDialog and InputDialog.input_face then
        local orig_size = InputDialog.input_face.orig_size or 16
        InputDialog.input_face = Font:getFace(font_name, orig_size)
    end

    local ok_bd, ButtonDialog = pcall(require, "ui/widget/buttondialog")
    if ok_bd and ButtonDialog then
        if ButtonDialog.title_face then
            local orig_size = ButtonDialog.title_face.orig_size or 20
            ButtonDialog.title_face = Font:getFace(font_name, orig_size)
        end
        if ButtonDialog.info_face then
            local orig_size = ButtonDialog.info_face.orig_size or 22
            ButtonDialog.info_face = Font:getFace(font_name, orig_size)
        end
    end
end

return apply_menu_font
