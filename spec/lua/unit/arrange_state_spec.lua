local ArrangeState = require("common/arrange_state")

describe("arrange state", function()
    it("detects reorder, additions, and removals by stable item identity", function()
        local original = {
            { orig_item = { id = "books" } },
            { orig_item = { id = "home" } },
        }

        assert.is_false(ArrangeState.hasRearrangedItems(original, {
            { orig_item = { id = "books" } },
            { orig_item = { id = "home" } },
        }))
        assert.is_true(ArrangeState.hasRearrangedItems(original, {
            { orig_item = { id = "home" } },
            { orig_item = { id = "books" } },
        }))
        assert.is_true(ArrangeState.hasRearrangedItems(original, {
            { orig_item = { id = "books" } },
        }))
    end)

    it("preserves labels while removing submenu and value decorations", function()
        assert.are.equal("Tabs", ArrangeState.stripSubmenuCaret("Tabs \u{25B8}"))
        assert.are.equal("Tabs", ArrangeState.stripSubmenuCaret("Tabs >"))
        assert.are.equal("Clock", ArrangeState.stripValueSuffix("Clock: 24-hour"))
        assert.are.equal("Title", ArrangeState.stripValueSuffix("Title"))
    end)

    it("uses entry keys and display text when an item has no explicit id", function()
        assert.are.equal("quick", ArrangeState.itemOrderKey({ orig_entry = { key = "quick" } }))
        assert.are.equal("Display", ArrangeState.itemOrderKey({ text = "Display" }))
        assert.is_true(ArrangeState.hasRearrangedItems(
            { { text = "One" } },
            { { text = "Two" } }
        ))
    end)

    it("routes root taps to controls instead of arrange selection", function()
        local configurable = {
            checked_func = function() return true end,
            callback = function() end,
            sub_item_table_func = function() return {} end,
        }
        local toggle_only = {
            checked_func = function() return true end,
            callback = function() end,
        }

        assert.are.equal("toggle", ArrangeState.rootTapAction(configurable, true))
        assert.are.equal("submenu", ArrangeState.rootTapAction(configurable, false))
        assert.are.equal("callback", ArrangeState.rootTapAction(toggle_only, false))
        assert.are.equal("consume", ArrangeState.rootTapAction({}, false))
    end)

    it("uses a submenu checkmark callback for toggle activation", function()
        local active = false
        local submenu_opened = false
        local item = {
            checkmark_callback = function() active = not active end,
            callback = function() submenu_opened = true end,
        }

        assert.is_true(ArrangeState.toggleItem(item))
        assert.is_true(active)
        assert.is_false(submenu_opened)
    end)

    it("recognizes unmodified Enter keys for handle repeat suppression", function()
        local press = {
            match = function(_self, sequence) return sequence[1] == "Press" end,
        }
        local shifted_press = {
            match = function() return false end,
        }

        assert.are.equal("Press", ArrangeState.confirmKeyName("Press"))
        assert.are.equal("Return", ArrangeState.confirmKeyName("Return"))
        assert.are.equal("Press", ArrangeState.confirmKeyName(press))
        assert.is_nil(ArrangeState.confirmKeyName(shifted_press))
        assert.is_nil(ArrangeState.confirmKeyName("Down"))
    end)

    it("maps drag positions to visible rows and adjacent pages", function()
        assert.are.equal(1, ArrangeState.dragTargetIndex(1, 4, 10, 100, 50, 125))
        assert.are.equal(3, ArrangeState.dragTargetIndex(1, 4, 10, 100, 50, 225))
        assert.are.equal(5, ArrangeState.dragTargetIndex(1, 4, 10, 100, 50, 325))
        assert.are.equal(4, ArrangeState.dragTargetIndex(2, 4, 10, 100, 50, 75))
        assert.are.equal(10, ArrangeState.dragTargetIndex(3, 4, 10, 100, 50, 225))
        assert.is_nil(ArrangeState.dragTargetIndex(1, 4, 10, 100, 0, 125))
    end)

    it("recognizes only vertical page crossings", function()
        assert.are.equal(-1, ArrangeState.dragPageDirection(90, 100, 300))
        assert.are.equal(1, ArrangeState.dragPageDirection(300, 100, 300))
        assert.are.equal(0, ArrangeState.dragPageDirection(150, 100, 300))
        assert.are.equal(0, ArrangeState.dragPageDirection(nil, 100, 300))
    end)

    it("moves only table items to validated absolute positions", function()
        local items = { { text = "One" }, { text = "Two" }, { text = "Three" } }
        assert.is_true(ArrangeState.moveTableItem(items, 3, 1))
        assert.are.equal("Three", items[1].text)
        assert.are.equal("One", items[2].text)
        assert.are.equal("Two", items[3].text)

        local invalid = { { text = "One" }, 2 }
        assert.is_false(ArrangeState.moveTableItem(invalid, 2, 1))
        assert.are.equal(2, invalid[2])
    end)

    it("keeps pinned trailing items last", function()
        local items = {
            { text = "One" },
            { text = "Two" },
            { text = "Description", arrange_pinned_last = true },
        }
        local moved, target = ArrangeState.moveTableItem(items, 1, 3)

        assert.is_true(moved)
        assert.are.equal(2, target)
        assert.are.same({ "Two", "One", "Description" }, {
            items[1].text, items[2].text, items[3].text,
        })
        assert.is_false(ArrangeState.moveTableItem(items, 3, 1))
    end)
end)
