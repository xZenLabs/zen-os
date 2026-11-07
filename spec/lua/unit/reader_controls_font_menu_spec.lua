describe("reader font family menu", function()
    local Menus, reader, anchor, shown, calls, original, has_layout
    local modules = { "modules/menu/reader_controls/menus", "modules/menu/reader_controls/settings",
        "modules/menu/reader_controls/profiles", "common/reader_themes", "ui/uimanager",
        "ui/widget/confirmbox", "ui/widget/buttondialog", "device",
        "ui/widget/container/scrollablecontainer", "ui/geometry", "common/ui/zen_anchored_menu",
        "util", "gettext" }

    before_each(function()
        original, calls, has_layout = {}, {}, true
        for _i, name in ipairs(modules) do original[name] = package.loaded[name] end
        ZenSpec.replace("modules/menu/reader_controls/settings", {})
        ZenSpec.replace("modules/menu/reader_controls/profiles", {})
        ZenSpec.replace("common/reader_themes", {})
        ZenSpec.replace("ui/widget/confirmbox", {})
        ZenSpec.replace("util", {})
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/widget/container/scrollablecontainer", {
            new = function(_self, options) return options end,
            getScrollbarWidth = function() return 6 end,
        })
        ZenSpec.replace("ui/geometry", { new = function(_self, options) return options end })
        ZenSpec.replace("device", { screen = {
            getWidth = function() return 600 end, getHeight = function() return 800 end,
            scaleBySize = function(_self, size) return size end,
        } })
        ZenSpec.replace("ui/uimanager", {
            show = function(_self, dialog) shown = dialog end,
            close = function(_self, dialog) calls[#calls + 1] = { "close", dialog } end,
        })
        ZenSpec.replace("ui/widget/buttondialog", { new = function(_self, options)
            options.layout = has_layout and options.buttons or nil
            options.moveFocusTo = function(self, x, y) self.focused = { x, y } end
            local grid = {}
            for i = 1, #options.buttons do grid[i] = { top = (i - 1) * 40, bottom = i * 40 - 1 } end
            options.buttontable = { buttons_layout = {},
                setupGridScrollBehaviour = function(self) self.scroll_setup = true end,
                getStepScrollGrid = function() return grid end,
                getSize = function() return { w = options.width - 10 } end,
            }
            options.movable = {{ { resetLayout = function(self) self.reset = true end } }}
            for i = 1, #options.buttons do
                options.buttontable.buttons_layout[i] = {{ label_widget = {
                    free = function(self) self.freed = true end,
                } }}
            end
            return options
        end })
        anchor = { x = 20, y = 500, w = 550, h = 40 }
        reader = { font = { font_face = "Current", onSaveSettings = function() calls[#calls + 1] = "save" end } }
        reader.font.setupFaceMenuTable = function(self)
            calls[#calls + 1] = "setup"
            self.face_table = { { text = "Native menu option" } }
            for _i, name in ipairs({ "First", "Current", "Last" }) do
                self.face_table[#self.face_table + 1] = {
                    menu_item_id = name, text_func = function() return name end,
                    checked_func = function() return name == self.font_face end,
                    font_func = function(size) return { orig_font = name .. ".ttc", size = size, faceindex = _i } end,
                    callback = function() self.font_face = name; calls[#calls + 1] = name end,
                    hold_callback = function(dialog) calls[#calls + 1] = { "hold", name, dialog } end,
                }
            end
        end
        ZenSpec.unload("modules/menu/reader_controls/menus")
        ZenSpec.unload("common/ui/zen_anchored_menu")
        Menus = require("modules/menu/reader_controls/menus")
    end)

    after_each(function()
        for _i, name in ipairs(modules) do package.loaded[name] = original[name] end
    end)

    it("anchors the native font choices to the family button and selects the current font", function()
        local dialog = Menus.fontFamily(reader, anchor, function() end)
        assert.are.equal(dialog, shown)
        assert.are.equal(anchor, dialog.anchor())
        assert.are.equal(584, dialog.width)
        assert.is_true(dialog.shrink_unneeded_width)
        assert.are.equal(220, dialog.shrink_min_width)
        assert.are.equal(3, #dialog.buttons)
        assert.are.equal("✓ Current", dialog.buttons[2][1].text)
        assert.are.same({ 1, 2 }, dialog.focused)
    end)

    it("uses six larger rows and each native font face, including its collection index", function()
        local dialog = Menus.fontFamily(reader, anchor, function() end)
        assert.are.equal(6, dialog.rows_per_page)
        for i, row in ipairs(dialog.buttons) do
            assert.are.equal(24, row[1].font_size)
            assert.is_false(row[1].font_bold)
            local label = dialog.buttontable.buttons_layout[i][1].label_widget
            assert.is_true(label.freed)
            assert.are.equal(row[1].font_face, label.face.orig_font)
            assert.are.equal(24, label.face.size)
            assert.are.equal(i, label.face.faceindex)
        end
    end)

    it("applies and saves the selected native face before refreshing its preview", function()
        local dialog = Menus.fontFamily(reader, anchor, function() calls[#calls + 1] = "preview" end)
        calls = {}
        dialog.buttons[3][1].callback()
        assert.are.equal("Last", reader.font.font_face)
        assert.are.same({ { "close", dialog }, "Last", "save", "preview" }, calls)
    end)

    it("caps the popup at six rows when a small installed font list would otherwise fit on screen", function()
        reader.font:setupFaceMenuTable()
        for i = 1, 4 do reader.font.face_table[#reader.font.face_table + 1] = reader.font.face_table[2] end
        local dialog = Menus.fontFamily(reader, anchor, function() end)
        assert.are.equal(7, #dialog.buttons)
        assert.is_true(dialog.buttontable.scroll_setup)
        assert.are.equal(240, dialog.cropping_widget.dimen.h)
        assert.are.equal(dialog.buttontable:getSize().w + 6, dialog.cropping_widget.dimen.w)
        assert.are.equal(dialog, dialog.cropping_widget.show_parent)
        assert.are.equal(dialog.buttontable, dialog.cropping_widget[1])
        assert.are.equal(dialog.cropping_widget, dialog.movable[1][1][3])
        assert.is_true(dialog.movable[1][1].reset)
    end)

    it("opens on touch-only devices without a keyboard focus layout", function()
        has_layout = false
        local dialog = Menus.fontFamily(reader, anchor, function() end)
        assert.are.equal(dialog, shown)
    end)

    it("keeps native hold defaults and rebuilds stale font choices", function()
        reader.font.face_table = { needs_refresh = true }
        local dialog = Menus.fontFamily(reader, anchor, function() end)
        dialog.buttons[1][1].hold_callback()
        assert.are.same({ "setup", { "hold", "First", dialog } }, calls)
        dialog:updateItems()
        assert.are.equal(anchor, shown.anchor())
        assert.are.equal(3, #shown.buttons)
    end)
end)
