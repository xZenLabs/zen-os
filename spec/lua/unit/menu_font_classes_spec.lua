describe("menu font item classes", function()
    local saved
    local names = {
        "common/zen_logger", "ui/font", "modules/filebrowser/patches/library_font",
        "ui/widget/touchmenu", "ui/widget/menu", "ui/widget/button", "ui/widget/confirmbox",
        "ui/widget/multiconfirmbox", "ui/widget/infomessage", "ui/widget/inputdialog",
        "ui/widget/buttondialog", "modules/global/patches/menu_font",
    }

    before_each(function()
        saved = {}
        for _i, name in ipairs(names) do saved[name] = package.loaded[name] or false end
        ZenSpec.replace("common/zen_logger", { new = function() return { dbg = function() end } end })
        ZenSpec.replace("ui/font", {
            fontmap = { cfont = "NotoSans-Regular.ttf", ffont = "NotoSans-Bold.ttf" },
            getFace = function(_self, name, size) return { name = name, orig_size = size } end,
        })
        ZenSpec.replace("modules/filebrowser/patches/library_font", {
            getFontName = function() return "Custom-Regular.ttf" end,
        })
        for _i, name in ipairs({ "ui/widget/button", "ui/widget/confirmbox", "ui/widget/multiconfirmbox",
                "ui/widget/infomessage", "ui/widget/inputdialog", "ui/widget/buttondialog" }) do
            ZenSpec.replace(name, {})
        end
        ZenSpec.unload("modules/global/patches/menu_font")
    end)

    after_each(function()
        for _i, name in ipairs(names) do package.loaded[name] = saved[name] or nil end
    end)

    it("patches item classes once at install without wrapping updateItems", function()
        local TouchMenuItem = { face = { orig_size = 20 } }
        local MenuItem = { font = "smallinfofont", infont = "infont" }
        local inner = function() return TouchMenuItem end
        local touch_update = function() return inner() end -- reached through a wrapper
        local menu_update = function() return MenuItem end
        ZenSpec.replace("ui/widget/touchmenu", { updateItems = touch_update })
        ZenSpec.replace("ui/widget/menu", { updateItems = menu_update })

        require("modules/global/patches/menu_font")()

        assert.are.equal(touch_update, package.loaded["ui/widget/touchmenu"].updateItems)
        assert.are.equal(menu_update, package.loaded["ui/widget/menu"].updateItems)
        assert.are.same({ name = "smallinfofont", orig_size = 20 }, TouchMenuItem.face)
        assert.are.equal("Custom-Regular.ttf", MenuItem.font)
        assert.are.equal("Custom-Regular.ttf", MenuItem.infont)
    end)

    it("falls back to a one-shot class patch when the item class is unreachable", function()
        local ItemClass = { font = "smallinfofont" }
        ItemClass.__index = ItemClass
        local builds = 0
        local Menu = {
            updateItems = function(self)
                builds = builds + 1
                self.item_group = { setmetatable({ face = {} }, ItemClass) }
            end,
        }
        ZenSpec.replace("ui/widget/touchmenu", { updateItems = function() end })
        ZenSpec.replace("ui/widget/menu", Menu)

        require("modules/global/patches/menu_font")()
        Menu.updateItems({})
        assert.are.equal(2, builds)
        assert.are.equal("Custom-Regular.ttf", ItemClass.font)
        Menu.updateItems({})
        assert.are.equal(3, builds) -- later menus build once
    end)
end)
