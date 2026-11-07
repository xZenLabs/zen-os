describe("Zen anchored menus", function()
    local Menu, original, native_left, native_top
    local modules = { "common/ui/zen_anchored_menu", "common/ui/button_labels", "ui/widget/buttondialog", "ui/geometry",
        "device", "ui/widget/container/scrollablecontainer", "ui/size", "ui/font", "ui/widget/textwidget",
        "ui/widget/iconwidget", "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/rendertext" }

    before_each(function()
        original = {}
        for _i, name in ipairs(modules) do original[name] = package.loaded[name] end
        ZenSpec.replace("device", { screen = {
            getWidth = function() return 600 end, getHeight = function() return 800 end,
            scaleBySize = function(_self, size) return size end,
        } })
        ZenSpec.replace("ui/geometry", { new = function(_self, options) return options end })
        ZenSpec.replace("ui/widget/container/scrollablecontainer", {
            getScrollbarWidth = function() return 6 end,
        })
        ZenSpec.replace("ui/size", { padding = { large = 10, button = 6 }, border = { window = 2 }, line = { medium = 1 } })
        ZenSpec.replace("ui/font", { getFace = function() return {} end })
        ZenSpec.replace("ui/rendertext", { sizeUtf8Text = function() return { y_top = 12, y_bottom = 4 } end })
        ZenSpec.replace("ui/widget/textwidget", { new = function(_self, options)
            options.getSize = function() return { w = #options.text * 10, h = 20 } end
            options.getFittedText = function(self) return self.text end
            options.getBaseline = function() return 14 end
            options.setMaxWidth = function(self, width) self.max_width = width end
            options.free = function() end
            return options
        end })
        for _i, name in ipairs({ "ui/widget/iconwidget", "ui/widget/horizontalgroup", "ui/widget/horizontalspan" }) do
            ZenSpec.replace(name, { new = function(_self, options)
                options.file = options.file or options.icon
                options.free = function() end
                return options
            end })
        end
        native_left, native_top = 20, 30
        ZenSpec.replace("ui/widget/buttondialog", { new = function(_self, options)
            options.buttontable = { buttons_layout = {} }
            for i, row in ipairs(options.buttons) do
                local layout = {}
                for j, button in ipairs(row) do
                    layout[j] = { dimen = { w = options.shrink_min_width },
                        frame = { padding_left = 10, padding_right = 10 },
                        label_container = { dimen = { w = options.shrink_min_width - 20 } },
                        label_widget = require("ui/widget/textwidget"):new{ text = button.text or "" } }
                end
                options.buttontable.buttons_layout[i] = layout
            end
            options.movable = {
                { getSize = function() return { w = 180, h = 120 } end },
                dimen = { w = 180, h = 120 },
                ensureAnchor = function(self, x, y)
                    self._moved_offset_x = native_left - x
                    self._moved_offset_y = native_top - y
                end,
            }
            return options
        end })
        ZenSpec.unload("common/ui/zen_anchored_menu")
        Menu = require("common/ui/zen_anchored_menu")
    end)

    after_each(function()
        for _i, name in ipairs(modules) do package.loaded[name] = original[name] end
    end)

    it("uses native content shrinking and left aligned rows without changing callbacks", function()
        local callback = function() end
        local dialog = Menu.new{ buttons = { { { text = "A longer option", callback = callback } } } }
        assert.are.equal(584, dialog.width)
        assert.is_true(dialog.shrink_unneeded_width)
        assert.are.equal(220, dialog.shrink_min_width)
        assert.are.equal("left", dialog.buttons[1][1].align)
        assert.are.equal(callback, dialog.buttons[1][1].callback)
    end)

    it("preserves dismiss callbacks for reader setting menus", function()
        local close = function() end
        local dialog = Menu.new{ buttons = {{ { text = "Reset" } }}, close_callback = close }
        assert.are.equal(close, dialog.tap_close_callback)
    end)

    it("anchors to the right of the button using actual compact content width", function()
        local source = { x = 550, y = 20, w = 40, h = 40 }
        local dialog = Menu.new{ buttons = {}, anchor = function() return source, true end, anchor_right = true }
        local anchor, prefers_pop_down = dialog.anchor()
        assert.are.same({ x = 402, y = 20, w = 180, h = 40 }, anchor)
        assert.is_true(prefers_pop_down)
        assert.are.same({ x = 550, y = 20, w = 40, h = 40 }, source)
    end)

    it("keeps native anchor placement inset from every screen edge", function()
        local dialog = Menu.new{ buttons = {}, anchor = { x = 0, y = 0, w = 40, h = 40 } }
        native_left, native_top = 0, 0
        dialog.movable:ensureAnchor(100, 200)
        assert.are.equal(8, 100 + dialog.movable._moved_offset_x)
        assert.are.equal(8, 200 + dialog.movable._moved_offset_y)
        native_left, native_top = 420, 680
        dialog.movable:ensureAnchor(100, 200)
        assert.are.equal(412, 100 + dialog.movable._moved_offset_x)
        assert.are.equal(672, 200 + dialog.movable._moved_offset_y)
        native_left, native_top = 200, 300
        dialog.movable:ensureAnchor(100, 200)
        assert.are.equal(200, 100 + dialog.movable._moved_offset_x)
        assert.are.equal(300, 200 + dialog.movable._moved_offset_y)
    end)

    it("accepts measured icon row widths and reserves room for a scrolling list", function()
        local dialog = Menu.new{ buttons = {}, width = 300 }
        assert.are.equal(300, dialog.width)
        assert.is_false(dialog.shrink_unneeded_width)
        dialog = Menu.new{ buttons = {}, width = 900 }
        assert.are.equal(584, dialog.width)
        dialog = Menu.new{ buttons = { {}, {}, {}, {}, {}, {}, {} }, rows_per_page = 6 }
        assert.are.equal(578, dialog.width)
        assert.are.equal(6, dialog.rows_per_page)
    end)

    it("fits themed icons beside left aligned labels while preserving row padding", function()
        local text = "A long translated reader controls label"
        local dialog = Menu.new{ buttons = {{ { text = text, icon = "/custom/controls.svg", padding_h = 16 } }} }
        assert.is_true(dialog.shrink_min_width >= #text * 10 + 24 + 12 + 32)
        local button = dialog.buttontable.buttons_layout[1][1]
        assert.are.equal(16, button.frame.padding_left)
        assert.are.equal(16, button.frame.padding_right)
        assert.are.equal("/custom/controls.svg", button.label_container[1][1].file)
        assert.are.equal(24, button.label_container[1][1].width)
        assert.are.equal(12, button.label_container[1][2].width)
        assert.are.equal(button.label_widget, button.label_container[1][3])
        assert.are.equal(button.dimen.w - 32 - 24 - 12, button.label_widget.max_width)
    end)

    it("wraps labelled action rows to fit while keeping callbacks and smaller icons", function()
        local Labels = require("common/ui/button_labels")
        local callback = function() end
        local buttons = {{
            { text = "Style", icon = "/style.svg", callback = callback },
            { text = "Color", icon = "/color.svg" },
            { text = "Translate", icon = "/translate.svg" },
        }, { { text = "Pin" } }}
        local rows = Labels.prepare(buttons, 300)
        assert.equals(3, #rows)
        assert.equals(2, #rows[1])
        assert.equals(1, #rows[2])
        assert.equals(callback, rows[1][1].callback)
        assert.equals(20, rows[1][1].icon_width)
        assert.equals(16, rows[1][1].font_size)
        assert.equals("Pin", rows[3][1].text)
        assert.equals(1, #Labels.prepare({ buttons[1] }, 900))
    end)
end)
