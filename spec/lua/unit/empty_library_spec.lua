describe("empty library shortcut", function()
    local saved_modules, saved_plugin
    local FileChooser, opened, painted
    local dependencies = {
        "ui/widget/filechooser", "ui/widget/button", "ui/widget/container/centercontainer",
        "ui/font", "ui/geometry", "ui/widget/textboxwidget", "ui/widget/verticalgroup",
        "ui/widget/verticalspan", "ui/size", "common/paths", "gettext",
        "common/ui/zen_button",
        "modules/settings/zen_settings_page", "modules/filebrowser/patches/empty_library",
    }

    local Widget = {
        new = function(_self, values)
            values.getSize = function(self) return self.dimen or { w = 600, h = 60 } end
            values.resetLayout = function() end
            return values
        end,
    }

    local function chooser(items, options)
        local instance = options or {}
        instance.name = instance.name or "filemanager"
        instance.path = instance.path or "/library"
        instance.width = 600
        if not instance.inner_dimen then
            instance.inner_dimen = { w = 600, h = 750 }
            instance.available_height = 700
        end
        instance.item_table = items
        instance.item_group = Widget:new{}
        instance.layout = {}
        return setmetatable(instance, { __index = FileChooser })
    end

    before_each(function()
        saved_modules = {}
        saved_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        _G.__ZEN_UI_PLUGIN = { config = {} }
        for _i, name in ipairs(dependencies) do
            saved_modules[name] = package.loaded[name] or false
        end
        FileChooser = {
            updatePageInfo = function(self, selected)
                self.stock_selected = selected
                return "stock"
            end,
        }
        ZenSpec.replace("ui/widget/filechooser", FileChooser)
        ZenSpec.replace("ui/widget/button", {
            new = function(_self, values)
                local button = Widget:new(values)
                button.dimen = { w = 200, h = 60 }
                button.frame = {}
                return button
            end,
        })
        for _i, name in ipairs({
            "ui/widget/container/centercontainer",
            "ui/widget/textboxwidget", "ui/widget/verticalgroup", "ui/widget/verticalspan",
        }) do ZenSpec.replace(name, Widget) end
        ZenSpec.replace("ui/geometry", { new = function(_self, values) return values end })
        ZenSpec.replace("ui/font", { getFace = function() return {} end })
        ZenSpec.replace("ui/size", { padding = { large = 10 } })
        ZenSpec.replace("common/paths", { isHomeRoot = function(path) return path == "/library" end })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("common/ui/zen_button", {
            paintFilled = function() painted = "filled" end,
            paintOutlined = function() painted = "outlined" end,
        })
        ZenSpec.replace("modules/settings/zen_settings_page", {
            show = function(plugin, opts) opened = { plugin = plugin, opts = opts } end,
        })
        opened = nil
        ZenSpec.unload("modules/filebrowser/patches/empty_library")
        require("modules/filebrowser/patches/empty_library")()
    end)

    after_each(function()
        _G.__ZEN_UI_PLUGIN = saved_plugin
        for _i, name in ipairs(dependencies) do
            package.loaded[name] = saved_modules[name] or nil
        end
    end)

    it("opens home-folder settings from an empty library in list and mosaic layouts", function()
        for _i, items in ipairs({ {}, { { is_go_up = true } } }) do
            for _j, mosaic in ipairs({ false, true }) do
                local menu = chooser(items, mosaic and {
                    inner_dimen = { w = 600, h = 750 }, others_height = 50,
                } or nil)
                assert.are.equal("stock", menu:updatePageInfo(1))
                assert.are.equal(1, menu.stock_selected)
                assert.are.equal(1, #menu.item_group)
                local content = menu.item_group[1][1]
                assert.are.equal("No books found", content[1].text)
                local button = menu.layout[1][1]
                assert.are.equal("Set home folder", button.text)
                assert.are.equal(button, content[3])
                button.frame:paintTo({}, 10, 20)
                assert.are.same({ x = 10, y = 20, w = 200, h = 60 }, button.frame.dimen)
                assert.are.equal("filled", painted)
                button.frame.invert = true
                button.frame:paintTo({}, 10, 20)
                assert.are.equal("outlined", painted)
                button.callback()
                assert.are.equal(_G.__ZEN_UI_PLUGIN, opened.plugin)
                assert.are.same({
                    { key = "_zen_settings_root", value = "library" },
                    { key = "text", value = "Folders" },
                    { key = "text", value = "Home folder" },
                }, opened.opts.path)
            end
        end
    end)

    it("keeps populated libraries, subfolders, and other choosers unchanged", function()
        for _i, menu in ipairs({
            chooser({ { is_file = true, path = "/library/book.epub" } }),
            chooser({ { path = "/library/books" } }),
            chooser({}, { path = "/library/empty" }),
            chooser({}, { name = "pathchooser" }),
        }) do
            menu:updatePageInfo()
            assert.are.equal(0, #menu.item_group)
            assert.are.equal(0, #menu.layout)
        end
    end)
end)
