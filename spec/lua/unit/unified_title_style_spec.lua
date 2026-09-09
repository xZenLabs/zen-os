describe("Unified Zen title style", function()
    local saved_modules
    local original_defaults
    local module_names = {
        "ffi/blitbuffer",
        "device",
        "ui/size",
        "common/ui/icon_menu_item",
        "common/ui/zen_title_style",
        "ui/widget/titlebar",
        "modules/global/patches/unified_title_style",
    }

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(module_names) do
            saved_modules[name] = package.loaded[name] or false
        end
        original_defaults = _G.G_defaults
    end)

    after_each(function()
        _G.G_defaults = original_defaults
        for _i, name in ipairs(module_names) do
            package.loaded[name] = saved_modules[name] or nil
        end
    end)

    it("exposes the arrange-list header geometry", function()
        ZenSpec.replace("ffi/blitbuffer", { COLOR_LIGHT_GRAY = "light_gray" })
        ZenSpec.replace("device", {
            screen = { scaleBySize = function(_self, value) return value end },
        })
        ZenSpec.replace("ui/size", {
            padding = { default = 8, fullscreen = 2, large = 20 },
        })
        ZenSpec.replace("common/ui/icon_menu_item", {
            SETTINGS_ICON_WIDTH = 62,
            getSettingsIconGap = function() return 8 end,
            getSettingsLeftPadding = function() return 22 end,
            getSettingsFace = function() return { name = "settings_title" } end,
        })
        _G.G_defaults = {
            readSetting = function(_self, key)
                if key == "DGENERIC_ICON_SIZE" then return 40 end
            end,
        }
        ZenSpec.unload("common/ui/zen_title_style")
        local style = require("common/ui/zen_title_style")

        assert.are.equal(28, style.ICON_SIZE)
        assert.are.equal(44, style.BUTTON_SIZE)
        assert.are.equal(58, style.HEADER_HEIGHT)
        assert.are.equal(39, style.getLeadingIconX(0))
        assert.are.equal(92, style.getTitleX(0))
        assert.are.equal(544, style.getTrailingIconX(600, 0))
        assert.are.equal(0.7, style.getStockIconSizeRatio())
        assert.are.equal("settings_title", style.getTitleFace().name)
    end)

    it("styles full-width KOReader title bars but leaves modal bars alone", function()
        local TitleBar = {
            init = function(self)
                self.title_widget = {}
                return "initialized"
            end,
        }
        ZenSpec.replace("device", {
            screen = { getWidth = function() return 600 end },
        })
        ZenSpec.replace("ui/widget/titlebar", TitleBar)
        ZenSpec.replace("common/ui/zen_title_style", {
            applyToStockTitleBar = function(title_bar)
                title_bar.zen_styled = true
                title_bar.title_face = "settings_title"
                title_bar.left_icon_size_ratio = 0.7
                title_bar.right_icon_size_ratio = 0.7
                title_bar.button_padding = 8
            end,
        })
        ZenSpec.unload("modules/global/patches/unified_title_style")
        require("modules/global/patches/unified_title_style")()

        local full = { width = 600 }
        assert.are.equal("initialized", TitleBar.init(full))
        assert.is_true(full.zen_styled)
        assert.is_true(full.title_widget.bold)

        local modal = { width = 500, title_face = "custom" }
        TitleBar.init(modal)
        assert.is_nil(modal.zen_styled)
        assert.are.equal("custom", modal.title_face)
        assert.is_nil(modal.title_widget.bold)
    end)
end)
