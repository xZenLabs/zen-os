describe("highlight submenu items", function()
    local Items
    before_each(function()
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.unload("modules/reader/highlight_menu_items")
        Items = require("modules/reader/highlight_menu_items")
    end)

    it("keeps upstream callbacks and bindings while hiding arrows by default", function()
        local buttons = { {}, {} }
        for i = 1, 10 do
            table.insert(buttons[i <= 6 and 1 or 2], { text = tostring(i), callback = function() return i end,
                key_bindings = { "key" .. i } })
        end
        local rows = Items.arrange(buttons, { submenu_order = { "note", "details", "note", "unknown" } }, true)
        assert.are.equal(1, #rows)
        assert.are.equal(5, #rows[1])
        assert.are.equal(buttons[1][4], rows[1][1])
        assert.same({ "key4" }, rows[1][1].key_bindings)
        assert.are.equal(4, rows[1][1].callback())
        assert.are.equal("zen_highlight_delete", rows[1][4].id)
        assert.are.equal("zen_highlight_more", rows[1][5].id)
    end)

    it("restores arrows when handles are unavailable and allows explicit arrow ordering", function()
        local settings = { submenu_order = { "end_next", "style" }, submenu_enabled = { style = false, end_next = true } }
        assert.is_true(Items.isEnabled(settings, "end_next", true))
        assert.is_false(Items.isEnabled(settings, "style", true))
        assert.is_false(Items.isEnabled(settings, "start_prev", true))
        assert.is_true(Items.isEnabled(settings, "start_prev", false))
        assert.are.equal("end_next", Items.getOrder(settings)[1])
    end)

    it("allows an empty menu and preserves unfamiliar upstream layouts", function()
        local settings = { submenu_enabled = {} }
        local buttons = { {}, {} }
        for _i, id in ipairs(Items.order) do settings.submenu_enabled[id] = false end
        for i = 1, 10 do
            table.insert(buttons[i <= 6 and 1 or 2], { text = tostring(i) })
        end
        assert.same({}, Items.arrange(buttons, settings, true))
        local other = {{ { text = "new action" } }}
        assert.are.equal(other, Items.arrange(other, settings, true))
    end)

    it("replaces the highlight actions with themeable icon paths", function()
        local buttons = { {}, {} }
        for i = 1, 10 do table.insert(buttons[i <= 6 and 1 or 2], { text = tostring(i) }) end
        local rows = Items.arrange(buttons, {}, true, {
            style = "/icons/font.svg", color = "/icons/paint_palette.svg", note = "/icons/edit.svg",
            delete = "/icons/trash.svg", more = "/icons/more_vertical.svg",
        })
        for i, name in ipairs({ "font", "paint_palette", "edit", "trash", "more_vertical" }) do
            assert.are.equal("/icons/" .. name .. ".svg", rows[1][i].icon)
            assert.is_nil(rows[1][i].text)
        end
        assert.are.equal("/icons/trash.svg", rows[1][4].icon)
        assert.is_nil(rows[1][4].text)
        assert.are.equal("/icons/more_vertical.svg", rows[1][5].icon)
        assert.is_nil(rows[1][5].text)
        assert.is_nil(Items.labels().details)
    end)

    it("updates legacy ordering while preserving other custom positions and visibility", function()
        local settings = { submenu_order = { "more", "note", "details", "delete", "color", "style" },
            submenu_enabled = { details = true, color = false } }
        assert.same({ "note", "color", "style", "start_prev", "start_next", "end_prev", "end_next", "delete", "more" },
            Items.getOrder(settings))
        assert.is_false(Items.isEnabled(settings, "color", true))
    end)

    it("keeps action names beside icons when labels are enabled", function()
        local buttons = { {}, {} }
        for i = 1, 10 do table.insert(buttons[i <= 6 and 1 or 2], { text = tostring(i) }) end
        local rows = Items.arrange(buttons, { show_labels = true }, true, { style = "/style.svg", color = "/color.svg" })
        assert.equals("Style", rows[1][1].text)
        assert.equals("Color", rows[1][2].text)
        assert.equals("/style.svg", rows[1][1].icon)
    end)

    it("shrinks icon rows while retaining label sizes and text-only plugin actions", function()
        local device = package.loaded["device"]
        ZenSpec.replace("device", { screen = { scaleBySize = function(_self, size) return size * 2 end } })
        local buttons = {{ { icon = "/pin.svg" },
            { text = "Remove pin", icon = "/pin_remove.svg", icon_width = 40, icon_height = 40, font_size = 16 },
            { text = "Plugin", height = 60 } }}
        Items.compact(buttons)
        assert.same({ 64, 64, 64 }, { buttons[1][1].height, buttons[1][1].icon_width, buttons[1][1].icon_height })
        assert.same({ 56, 40, 40, 16 }, { buttons[1][2].height, buttons[1][2].icon_width,
            buttons[1][2].icon_height, buttons[1][2].font_size })
        assert.equals(60, buttons[1][3].height)
        package.loaded["device"] = device
    end)
end)
