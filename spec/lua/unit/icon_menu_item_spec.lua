describe("icon menu item fonts", function()
    local saved_modules
    local saved_icon_item
    local dependencies = {
        "ffi/blitbuffer",
        "ui/widget/container/bottomcontainer",
        "ui/widget/container/centercontainer",
        "ui/widget/checkmark",
        "device",
        "ui/font",
        "ui/widget/container/framecontainer",
        "ui/geometry",
        "ui/widget/horizontalgroup",
        "ui/widget/horizontalspan",
        "ui/widget/iconwidget",
        "ui/widget/container/leftcontainer",
        "ui/widget/linewidget",
        "ui/widget/overlapgroup",
        "ui/widget/radiomark",
        "ui/widget/container/rightcontainer",
        "ui/size",
        "ui/widget/textwidget",
        "ui/widget/container/underlinecontainer",
        "ui/widget/verticalgroup",
        "common/ui/zen_toggle",
        "ui/widget/menu",
        "ui/widget/touchmenu",
        "ui/uimanager",
        "common/ui/button_feedback",
    }

    before_each(function()
        saved_modules = {}
        saved_icon_item = package.loaded["common/ui/icon_menu_item"] or false
        for _i, name in ipairs(dependencies) do
            saved_modules[name] = package.loaded[name] or false
            ZenSpec.replace(name, {})
        end
        package.loaded.device.screen = {
            scaleBySize = function(_self, value) return value end,
        }
        ZenSpec.unload("common/ui/icon_menu_item")
    end)

    after_each(function()
        if saved_icon_item == false then
            package.loaded["common/ui/icon_menu_item"] = nil
        else
            package.loaded["common/ui/icon_menu_item"] = saved_icon_item
        end
        for name, original in pairs(saved_modules) do
            package.loaded[name] = original == false and nil or original
        end
    end)

    it("uses a native menu row's requested font face", function()
        local IconItem = require("common/ui/icon_menu_item")
        local system_face = { name = "system", orig_size = 20 }
        local own_face = { name = "Font A", orig_size = 20 }
        local requested_size
        IconItem.getSettingsFace = function() return system_face end

        local face = IconItem.getItemFace({
            font_func = function(size)
                requested_size = size
                return own_face
            end,
        })

        assert.are.equal(20, requested_size)
        assert.are.equal(own_face, face)
        assert.are.equal(system_face, IconItem.getItemFace({
            font_func = function() end,
        }))
    end)

    it("uses shared rounded feedback for settings taps and holds while preserving stock rows", function()
        local saved_settings = G_reader_settings
        finally(function() _G.G_reader_settings = saved_settings end)
        local events, flash_disabled = {}, false
        _G.G_reader_settings = { isFalse = function() return flash_disabled end }
        local MenuItem = {
            init = function() end,
            onTapSelect = function() return "stock tap" end,
            onHoldSelect = function() return "stock hold" end,
            getGesPosition = function() return { x = 0.75, y = 0.25 } end,
        }
        local Menu = package.loaded["ui/widget/menu"]
        Menu.updateItems = function() return MenuItem end
        package.loaded["ui/widget/touchmenu"]._zen_icon_item_patched = true
        package.loaded["ui/uimanager"].forceRePaint = function() events[#events + 1] = "refresh" end
        local region = { x = 10, y = 20, w = 100, h = 40 }
        package.loaded["common/ui/button_feedback"].flash = function(dimen)
            assert.are.equal(region, dimen)
            if not flash_disabled then events[#events + 1] = "rounded flash" end
        end
        require("common/ui/icon_menu_item").installMenuPatch()
        local row = setmetatable({
            entry = { _zen_settings_row = true }, [1] = { dimen = region },
            item_frame = { invert = true }, menu = {},
        }, { __index = MenuItem })
        for handler, callback in pairs({ onTapSelect = "onMenuSelect", onHoldSelect = "onMenuHold" }) do
            row.menu[callback] = function(_self, entry, pos)
                assert.are.equal(row.entry, entry)
                assert.are.same({ x = 0.75, y = 0.25 }, pos)
                events[#events + 1] = callback
            end
            for _i, disabled in ipairs({ false, true }) do
                events, flash_disabled = {}, disabled
                assert.is_true(row[handler](row, nil, { pos = { x = 85, y = 30 } }))
                assert.are.same(disabled and { callback }
                    or { "rounded flash", callback, "refresh" }, events)
                assert.is_true(row.item_frame.invert)
            end
        end
        row.entry._zen_settings_row = false
        assert.are.equal("stock tap", row:onTapSelect())
        assert.are.equal("stock hold", row:onHoldSelect())
        row.entry._zen_settings_row = true
        row[1].dimen, events = nil, {}
        assert.is_nil(row:onTapSelect())
        assert.is_nil(row:onHoldSelect())
        assert.are.same({}, events)
    end)
end)
