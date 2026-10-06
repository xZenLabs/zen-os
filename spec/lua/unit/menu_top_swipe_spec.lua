describe("top menu tap handling", function()
    local Device
    local FileManager
    local FileManagerMenu
    local Menu
    local ReaderMenu
    local TopMenu
    local original_uimanager

    local function point(x, y)
        return {
            x = x,
            y = y,
            intersectWith = function(self, dimen)
                return self.x >= dimen.x and self.x < dimen.x + dimen.w
                    and self.y >= dimen.y and self.y < dimen.y + dimen.h
            end,
        }
    end

    before_each(function()
        original_uimanager = package.loaded["ui/uimanager"]
        Device = {
            screen = {
                getHeight = function() return 1000 end,
                getWidth = function() return 1000 end,
                scaleBySize = function(_self, value) return value end,
            },
        }
        FileManager = {
            instance = {
                menu = {
                    activation_menu = "tap",
                    _getTabIndexFromLocation = function() return 1 end,
                    onShowMenu = function(self)
                        self.shown = (self.shown or 0) + 1
                    end,
                },
            },
        }
        Menu = {
            init = function() end,
            onSwipe = function() end,
        }
        local function native_menu()
            return {
                onShowMenu = function() return true end,
                onTapShowMenu = function(self)
                    self.shown = (self.shown or 0) + 1
                    return true
                end,
            }
        end
        ReaderMenu = native_menu()
        FileManagerMenu = native_menu()
        ZenSpec.replace("device", Device)
        ZenSpec.replace("ui/widget/menu", Menu)
        ZenSpec.replace("apps/reader/modules/readermenu", ReaderMenu)
        ZenSpec.replace("apps/filemanager/filemanagermenu", FileManagerMenu)
        ZenSpec.replace("apps/filemanager/filemanager", FileManager)
        ZenSpec.replace("apps/reader/readerui", {})
        ZenSpec.replace("ui/gesturerange", { new = function(_self, opts) return opts end })
        ZenSpec.unload("modules/global/patches/menu_top_swipe")
        TopMenu = require("modules/global/patches/menu_top_swipe")
        TopMenu.apply()
    end)

    after_each(function()
        ZenSpec.unload("modules/global/patches/menu_top_swipe")
        ZenSpec.unload("device")
        ZenSpec.unload("ui/widget/menu")
        ZenSpec.unload("apps/reader/modules/readermenu")
        ZenSpec.unload("apps/filemanager/filemanagermenu")
        ZenSpec.unload("apps/filemanager/filemanager")
        ZenSpec.unload("apps/reader/readerui")
        ZenSpec.unload("ui/gesturerange")
        package.loaded["ui/uimanager"] = original_uimanager
    end)

    it("still opens the KOReader menu from the unoccupied top area", function()
        local settings = {
            name = "zen_settings",
            title_bar = {
                close_button = { dimen = { x = 0, y = 0, w = 50, h = 50 } },
            },
        }

        assert.are.equal(70, TopMenu.getTapHeight())
        assert.is_true(Menu.onTap(settings, nil, { pos = point(100, 69) }))
        assert.is_nil(Menu.onTap(settings, nil, { pos = point(100, 70) }))
        assert.are.equal(1, FileManager.instance.menu.shown)
    end)

    it("limits native reader and file browser menu taps to the top 7%", function()
        for _i, menu_class in ipairs({ ReaderMenu, FileManagerMenu }) do
            local menu = setmetatable({}, { __index = menu_class })
            assert.is_true(menu:onTapShowMenu({ pos = point(500, 69) }))
            assert.is_nil(menu:onTapShowMenu({ pos = point(500, 70) }))
            assert.is_nil(menu:onTapShowMenu({ pos = point(500, 150) }))
            assert.are.equal(1, menu.shown)
        end
    end)

    it("keeps reopened menus dismissible without leaving an older panel behind", function()
        local windows = {}
        ZenSpec.replace("ui/uimanager", {
            show = function(_self, widget) windows[widget] = true end,
            close = function(_self, widget) windows[widget] = nil end,
        })
        for _i, menu_class in ipairs({ ReaderMenu, FileManagerMenu }) do
            menu_class.onShowMenu = function(self, tab_index, do_not_show)
                local container = {{ last_index = tab_index }}
                container[1].closeMenu = function()
                    if self.menu_container then
                        require("ui/uimanager"):close(self.menu_container)
                        self.menu_container = nil
                    end
                end
                self.menu_container = container
                if not do_not_show then require("ui/uimanager"):show(container) end
                return true
            end
        end
        TopMenu.apply()

        for _i, menu_class in ipairs({ ReaderMenu, FileManagerMenu }) do
            local menu = setmetatable({}, { __index = menu_class })
            assert.is_true(menu:onShowMenu(1))
            local first = menu.menu_container
            assert.is_true(menu:onShowMenu(2))
            local second = menu.menu_container
            assert.are.equal(2, second[1].last_index)
            assert.is_nil(windows[first])
            assert.is_true(windows[second])
            second[1]:closeMenu()
            assert.are.same({}, windows)
            assert.is_nil(menu.menu_container)

            assert.is_true(menu:onShowMenu(nil, true))
            local hidden = menu.menu_container
            assert.are.same({}, windows)
            assert.is_true(menu:onShowMenu(1))
            assert.is_nil(windows[hidden])
            menu.menu_container[1]:closeMenu()
            assert.are.same({}, windows)
        end
    end)

    it("eats taps above and between right-side header controls", function()
        local title_bar = {
            action_button = {
                dimen = { x = 800, y = 50, w = 40, h = 40 },
                image = { dimen = { x = 808, y = 58, w = 24, h = 24 } },
            },
            close_button = {
                dimen = { x = 900, y = 50, w = 40, h = 40 },
                image = { dimen = { x = 908, y = 58, w = 24, h = 24 } },
            },
        }

        assert.is_false(TopMenu.isInsideHeaderControl(title_bar, point(820, 10)))
        assert.is_true(TopMenu.handleTap(title_bar, { pos = point(820, 10) }))
        assert.is_true(TopMenu.handleTap(title_bar, { pos = point(860, 10) }))
        assert.is_nil(FileManager.instance.menu.shown)
        assert.is_true(TopMenu.isInsideHeaderControl(title_bar, point(820, 70)))
    end)

    it("preserves expanded header-button hitboxes", function()
        local title_bar = {
            close_button = {
                dimen = { x = 900, y = 50, w = 56, h = 64 },
                image = { dimen = { x = 916, y = 62, w = 28, h = 28 } },
            },
        }

        assert.is_true(TopMenu.isInsideHeaderControl(title_bar, point(904, 108)))
    end)

    it("opens the KOReader menu from an unoccupied top-center tap", function()
        local title_bar = {
            action_button = { dimen = { x = 800, y = 50, w = 40, h = 40 } },
            close_button = { dimen = { x = 900, y = 50, w = 40, h = 40 } },
        }

        assert.is_true(TopMenu.handleTap(title_bar, { pos = point(500, 10) }))
        assert.are.equal(1, FileManager.instance.menu.shown)
    end)
end)
