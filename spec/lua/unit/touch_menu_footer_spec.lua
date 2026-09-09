require("ffi/loadlib")

describe("TouchMenu footer", function()
    local original_defaults
    local original_modules
    local module_names = {
        "common/plugin_root",
        "common/utils",
        "device",
        "ui/geometry",
        "ui/gesturerange",
        "ui/widget/container/horizontalgroup",
        "ui/widget/container/inputcontainer",
        "ui/widget/iconwidget",
        "ui/widget/touchmenu",
        "modules/menu/patches/touch_menu_footer",
    }

    before_each(function()
        original_defaults = _G.G_defaults
        original_modules = {}
        for _i, name in ipairs(module_names) do
            original_modules[name] = package.loaded[name] or false
        end
    end)

    after_each(function()
        _G.G_defaults = original_defaults
        for _i, name in ipairs(module_names) do
            package.loaded[name] = original_modules[name] or nil
        end
    end)

    it("resolves the large chevron through the active icon pack", function()
        local resolved
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
            end,
        }
        _G.G_defaults = { readSetting = function() return 40 end }
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
        ZenSpec.replace("ui/geometry", { new = function(_self, values) return values end })
        ZenSpec.replace("ui/gesturerange", { new = function(_self, values) return values end })
        ZenSpec.replace("ui/widget/container/horizontalgroup", {
            new = function(_self, values) return values end,
        })
        ZenSpec.replace("ui/widget/container/inputcontainer", InputContainer)
        ZenSpec.replace("ui/widget/iconwidget", {
            new = function(_self, values) return values end,
        })
        ZenSpec.replace("ui/widget/touchmenu", TouchMenu)
        ZenSpec.unload("modules/menu/patches/touch_menu_footer")

        require("modules/menu/patches/touch_menu_footer")()
        local menu = setmetatable({}, { __index = TouchMenu })
        menu:init()

        assert.are.same({ "/plugin/icons/", "large_chevron_up" }, resolved)
        assert.are.equal("/pack/large_chevron_up.svg", menu.footer[2][1].image.file)
        assert.are.equal(80, menu.footer[2][1].image.width)
        assert.is_true(menu.footer[3][1] == menu.page_info)
    end)
end)
