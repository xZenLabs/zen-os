describe("status bar settings", function()
    local original_modules
    local config
    local saves

    local function replace(name, module)
        original_modules[name] = { value = package.loaded[name] }
        ZenSpec.replace(name, module)
    end

    local function item_text(item)
        return item.text or (item.text_func and item.text_func())
    end

    local function find_item(items, text)
        for _i, item in ipairs(items) do
            if item_text(item) == text then return item end
        end
    end

    before_each(function()
        original_modules = {}
        saves = {}
        config = {
            features = { status_bar = true },
            status_bar = {
                custom_text = "",
                left_order = { "time", "custom_text" },
                center_order = {},
                right_order = { "wifi", "battery" },
            },
        }
        replace("gettext", setmetatable({
            pgettext = function(_context, text) return text end,
        }, {
            __call = function(_self, text) return text end,
        }))
        replace("ui/uimanager", {})
        replace("device", { model = "KOReader" })
        replace("modules/settings/zen_settings_utils", {
            make_enable_feature_item = function() return { text = "Enable custom status bar" } end,
        })
        replace("common/constants", { SEPARATOR_PRESETS = {} })
        replace("common/inline_icon_map", { settings_status = "settings" })
        replace("common/ui/icon_menu_item", {
            decorate = function(item) return item end,
        })
        replace("common/bluetooth", { isAvailable = function() return false end })
        replace("common/date_format", {
            format = function(format)
                return ({
                    short = "08/08/26",
                    long = "August 8th",
                })[format or "long"]
            end,
        })
        ZenSpec.unload("modules/settings/sections/library_settings/status_bar_settings")
    end)

    after_each(function()
        for name, saved in pairs(original_modules) do package.loaded[name] = saved.value end
        ZenSpec.unload("modules/settings/sections/library_settings/status_bar_settings")
    end)

    it("adds Date to status slots and provides a persisted format submenu", function()
        local page = require("modules/settings/sections/library_settings/status_bar_settings").build({
            config = config,
            save_and_apply = function(feature) saves[#saves + 1] = feature end,
        })

        local left = find_item(page.sub_item_table, "Left items")
        local date = find_item(left.sub_item_table, "Date")
        assert.is_table(date)
        assert.is_nil(find_item(page.sub_item_table, "Date: 08/08/26"))

        assert.is_function(date.checkmark_callback)
        assert.is_false(date.checked_func())
        assert.are.equal("08/08/26", date.sub_item_table[1].text_func())
        assert.are.equal("August 8th", date.sub_item_table[2].text_func())
        assert.is_true(date.sub_item_table[1].checked_func())

        date.checkmark_callback()
        assert.are.same({ "time", "date", "custom_text" }, config.status_bar.left_order)
        assert.is_true(date.checked_func())

        date.sub_item_table[2].callback()
        assert.are.equal("long", config.status_bar.date_format)
        assert.is_true(date.sub_item_table[2].checked_func())
        assert.are.same({ "status_bar", "status_bar" }, saves)
    end)

    it("toggles the status bar from its expandable parent row", function()
        local page = require("modules/settings/sections/library_settings/status_bar_settings").build({
            config = config,
            save_and_apply = function(feature) saves[#saves + 1] = feature end,
        })

        assert.is_true(page.checked_func())
        assert.is_function(page.checkmark_callback)
        assert.is_nil(find_item(page.sub_item_table, "Enable custom status bar"))

        page.checkmark_callback()

        assert.is_true(config.features.status_bar)
        assert.are.same({}, config.status_bar.left_order)
        assert.are.same({}, config.status_bar.center_order)
        assert.are.same({}, config.status_bar.right_order)
        assert.is_false(page.checked_func())
        assert.are.same({ "status_bar" }, saves)

        page.checkmark_callback()

        assert.are.same({ "time" }, config.status_bar.left_order)
        assert.are.same({}, config.status_bar.center_order)
        assert.are.same({ "wifi", "battery" }, config.status_bar.right_order)
        assert.is_true(page.checked_func())
    end)

    it("adds a persisted hide-when-off option to the Wi-Fi submenu", function()
        local page = require("modules/settings/sections/library_settings/status_bar_settings").build({
            config = config,
            save_and_apply = function(feature) saves[#saves + 1] = feature end,
        })

        local right = find_item(page.sub_item_table, "Right items")
        local wifi = find_item(right.sub_item_table, "Wi-Fi")
        local hide_when_off = find_item(wifi.sub_item_table, "Hide when off")

        assert.is_function(wifi.checkmark_callback)
        assert.is_true(wifi.checked_func())
        assert.is_false(hide_when_off.checked_func())

        hide_when_off.callback()
        assert.is_true(config.status_bar.wifi_hide_when_off)
        assert.is_true(hide_when_off.checked_func())
        assert.are.same({ "status_bar" }, saves)
    end)
end)
