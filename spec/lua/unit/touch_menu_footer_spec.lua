require("ffi/loadlib")

describe("TouchMenu footer", function()
    local original_defaults
    local original_modules
    local original_plugin
    local module_names = {
        "apps/reader/readerui",
        "common/plugin_root",
        "common/ui/hatching",
        "common/utils",
        "device",
        "ffi/blitbuffer",
        "ui/geometry",
        "ui/gesturerange",
        "ui/uimanager",
        "ui/widget/container/horizontalgroup",
        "ui/widget/container/inputcontainer",
        "ui/widget/iconwidget",
        "ui/widget/touchmenu",
        "modules/menu/patches/touch_menu_footer",
    }

    before_each(function()
        original_defaults = _G.G_defaults
        original_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        original_modules = {}
        for _i, name in ipairs(module_names) do
            original_modules[name] = package.loaded[name] or false
        end
    end)

    after_each(function()
        _G.G_defaults = original_defaults
        _G.__ZEN_UI_PLUGIN = original_plugin
        for _i, name in ipairs(module_names) do
            package.loaded[name] = original_modules[name] or nil
        end
    end)

    it("redesigns the footer and optionally hatches the full screen behind the menu", function()
        local resolved
        local hatch_args
        local paint_order = {}
        local refresh
        local InputContainer = {}
        function InputContainer:extend(definition)
            definition.__index = definition
            return setmetatable(definition, { __index = self })
        end
        function InputContainer:new(values)
            values.ges_events = {}
            setmetatable(values, { __index = self })
            values:init()
            return values
        end

        local TouchMenu = {
            init = function(self)
                self.page_info = { id = "pagination" }
                self.footer = {{}, {}, {}}
                self.dimen = { h = 300 }
                self.screen_size = { w = 600, h = 800 }
                self.is_fresh = true
            end,
            paintTo = function()
                paint_order[#paint_order + 1] = "menu"
                return "painted"
            end,
        }
        _G.G_defaults = { readSetting = function() return 40 end }
        _G.__ZEN_UI_PLUGIN = {
            config = { quick_settings = { background_hatching = true } },
        }
        ZenSpec.replace("common/plugin_root", "/plugin")
        ZenSpec.replace("common/utils", {
            resolveIcon = function(directory, name)
                resolved = { directory, name }
                return "/pack/large_chevron_up.svg"
            end,
        })
        ZenSpec.replace("device", {
            screen = { scaleBySize = function(_self, value) return value end },
        })
        ZenSpec.replace("ffi/blitbuffer", { COLOR_BLACK = "black" })
        ZenSpec.replace("ui/geometry", { new = function(_self, values) return values end })
        ZenSpec.replace("ui/gesturerange", { new = function(_self, values) return values end })
        ZenSpec.replace("ui/uimanager", {
            setDirty = function(_self, widget, refreshtype)
                refresh = { widget = widget, refreshtype = refreshtype }
            end,
        })
        ZenSpec.replace("ui/widget/container/horizontalgroup", {
            new = function(_self, values) return values end,
        })
        ZenSpec.replace("ui/widget/container/inputcontainer", InputContainer)
        ZenSpec.replace("ui/widget/iconwidget", {
            new = function(_self, values) return values end,
        })
        ZenSpec.replace("ui/widget/touchmenu", TouchMenu)
        ZenSpec.unload("common/ui/hatching")
        ZenSpec.unload("modules/menu/patches/touch_menu_footer")

        require("modules/menu/patches/touch_menu_footer")()
        local menu = setmetatable({}, { __index = TouchMenu })
        menu:init()

        assert.are.same({ "/plugin/icons/", "large_chevron_up" }, resolved)
        assert.are.equal("/pack/large_chevron_up.svg", menu.footer[2][1].image.file)
        assert.are.equal(80, menu.footer[2][1].image.width)
        assert.is_true(menu.footer[3][1] == menu.page_info)
        menu:onShow()
        assert.is_false(menu.is_fresh)
        assert.is_nil(refresh.widget)
        assert.are.equal("ui", refresh.refreshtype)

        local result = menu:paintTo({
            hatchRect = function(_self, ...)
                paint_order[#paint_order + 1] = "hatch"
                hatch_args = { ... }
            end,
        }, 0, 0)
        assert.are.equal("painted", result)
        assert.are.same({ "hatch", "menu" }, paint_order)
        assert.are.same({ 0, 300, 600, 500, 2, "black", 0.4 }, hatch_args)

        ZenSpec.replace("apps/reader/readerui", {
            instance = { config = { config_dialog = {{
                contentRange = function() return { y = 300 } end,
            }} } },
        })
        hatch_args = nil
        menu:paintTo({
            hatchRect = function(_self, ...)
                hatch_args = { ... }
            end,
        }, 0, 0)
        assert.is_nil(hatch_args)

        _G.__ZEN_UI_PLUGIN.config.quick_settings.background_hatching = false
        paint_order = {}
        hatch_args = nil
        refresh = nil
        menu:onShow()
        menu:paintTo({ hatchRect = function() hatch_args = {} end }, 0, 0)
        assert.are.same({ "menu" }, paint_order)
        assert.is_nil(hatch_args)
        assert.is_nil(refresh)
    end)
end)
