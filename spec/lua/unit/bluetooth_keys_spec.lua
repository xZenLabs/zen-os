describe("Bluetooth button mapping", function()
    local originals, quick_settings, shown, lists, pending, refreshes, bindings, pickers
    local device = { address = "11:22:33:44:55:66", name = "Page turner" }

    before_each(function()
        originals = {}
        for _i, name in ipairs({
            "device", "dispatcher", "ui/widget/infomessage", "ui/uimanager", "common/ui/zen_arrange_list",
            "common/dispatcher_menu", "common/ui/glyph_icons", "common/hid_keys", "common/inline_icon_map",
            "common/library_destination", "common/ui/icon_menu_item", "common/ui/zen_menu_picker",
            "common/plugin_root", "ffi/util", "gettext", "modules/menu/bluetooth_keys",
        }) do originals[name] = package.loaded[name] or false end
        quick_settings = rawget(_G, "__ZEN_UI_QUICK_SETTINGS")
        shown, lists, pending, refreshes, bindings, pickers = {}, {}, nil, 0, {}, {}
        ZenSpec.replace("device", { hasKeys = function() return false end })
        ZenSpec.replace("dispatcher", {})
        ZenSpec.replace("ui/widget/infomessage", { new = function(_self, spec) return spec end })
        ZenSpec.replace("ui/uimanager", {
            show = function(_self, widget) shown[#shown + 1] = widget end,
            close = function() end,
        })
        ZenSpec.replace("common/ui/zen_arrange_list", { show = function(opts)
            lists[#lists + 1] = opts
            return { _zen_menu_proxy = { updateItems = function() refreshes = refreshes + 1 end } }
        end })
        ZenSpec.replace("common/dispatcher_menu", {
            addSubMenu = function(_dispatcher, _caller, items) items[1] = { text = "Nothing" } end,
            wrap = function() end,
        })
        ZenSpec.replace("common/ui/glyph_icons", { path = function() end, iconPath = function() end })
        ZenSpec.replace("common/library_destination", {})
        ZenSpec.replace("common/ui/icon_menu_item", { decorate = function(item, glyph)
            item.icon_glyph = glyph
            return item
        end })
        ZenSpec.replace("common/ui/zen_menu_picker", function(opts) pickers[#pickers + 1] = opts end)
        ZenSpec.replace("common/plugin_root", "/zen")
        ZenSpec.replace("common/hid_keys", {
            SCREENS = { "reader", "library" }, COMMON = { reader = {}, library = {} },
            list = function() return bindings end,
            add = function(_address, code) return { code = code } end,
            save = function() end, rescan = function() end, stopCapture = function() end,
            capture = function(done) pending = done end,
            assign = function(_address, binding, screen, field, value) binding[screen] = { field, value } end,
            label = function(binding, screen)
                local assigned = binding[screen]
                if assigned then return assigned[2].label, assigned[2].type end
            end,
        })
        ZenSpec.replace("common/inline_icon_map", {})
        ZenSpec.replace("ffi/util", { template = function(text, value)
            return (text:gsub("%%1", tostring(value)))
        end })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.unload("modules/menu/bluetooth_keys")
    end)

    after_each(function()
        for name, module in pairs(originals) do package.loaded[name] = module or nil end
        rawset(_G, "__ZEN_UI_QUICK_SETTINGS", quick_settings)
    end)

    it("waits for a tap on Map a button unless asked to capture right away", function()
        local Mapping = require("modules/menu/bluetooth_keys")
        Mapping.show(device, {})
        assert.are.equal("Map a button", lists[1].item_table[1].text)
        assert.is_nil(pending)
        assert.are.same({}, shown)

        Mapping.show(device, {}, true)
        assert.are.equal("Page turner", lists[2].title)
        assert.are.equal("Press a button on Page turner…", shown[1].text)
        pending(304)
        assert.are.same({}, bindings) -- a draft until it is assigned
        assert.are.equal(0, refreshes)
        assert.are.equal("Button 304", lists[3].title)

        local control = lists[3].item_table[1].sub_item_table[2]
        rawset(_G, "__ZEN_UI_QUICK_SETTINGS", { getItems = function() return { { id = "wifi", label = "Wi-Fi" } } end })
        control.callback()
        pickers[1].on_select(pickers[1].items[1])
        assert.are.equal(1, refreshes) -- the list behind shows the new button
    end)

    it("offers the Controls choices per screen, library destinations in the library only", function()
        local function texts(items)
            local out = {}
            for _i, item in ipairs(items) do out[#out + 1] = item.text or item.text_func() end
            return out
        end
        bindings[1] = { code = 304 }
        rawset(_G, "__ZEN_UI_QUICK_SETTINGS", { getItems = function()
            return { { id = "wifi", label = "Wi-Fi" } }
        end })
        local Mapping = require("modules/menu/bluetooth_keys")
        Mapping.show(device, {})
        lists[1].item_table[2].callback()
        local reader, library = lists[2].item_table[1], lists[2].item_table[2]
        assert.are.equal("Reader: (none)", reader.text_func())
        assert.are.same({ "Common actions", "Control", "Action", "Plugin Menu", "KOReader menu" },
            texts(reader.sub_item_table))
        assert.are.same({ "Common actions", "Control", "Action", "Folder", "Specific tag", "Plugin Menu",
            "KOReader menu" }, texts(library.sub_item_table))
        assert.are.equal("/zen/icons/koreader.png", reader.sub_item_table[5].icon_file)
        for _i, item in ipairs(library.sub_item_table) do assert.is_true(item._zen_arrange_no_caret) end

        local updates = 0
        reader.sub_item_table[2].callback({ updateItems = function() updates = updates + 1 end })
        assert.are.equal("Choose control", pickers[1].title)
        pickers[1].on_select(pickers[1].items[1])
        assert.are.same({ "entries", { type = "quick_setting", quick_setting_id = "wifi", label = "Wi-Fi" } },
            bindings[1].reader)
        assert.are.equal(1, updates)
        assert.are.equal("Reader: Wi-Fi", reader.text_func())
        assert.are.equal("Control: Wi-Fi", reader.sub_item_table[2].text_func())
        assert.are.equal("Action", reader.sub_item_table[3].text_func())
    end)
end)
