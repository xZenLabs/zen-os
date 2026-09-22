describe("Zen scroll bar", function()
    local Menu
    local shown
    local painted_y
    local page_turns
    local centered_content_bottom
    local saved_modules

    local module_names = {
        "gettext",
        "ffi/blitbuffer",
        "device",
        "ui/geometry",
        "ui/widget/menu",
        "ui/size",
        "ui/uimanager",
        "common/ui/zen_pager",
        "common/ui/zen_dialog",
        "common/ui/zen_scroll_bar",
    }

    local function find_zone(menu, id)
        for _i, zone in ipairs(menu._zen_page_number_zones) do
            if zone.id == id then return zone end
        end
    end

    local function new_menu(name, values)
        local menu = {
            name = name,
            page = 1,
            page_num = 3,
            dimen = { x = 0, y = 0, w = 600, h = 800 },
        }
        for key, value in pairs(values or {}) do
            menu[key] = value
        end
        setmetatable(menu, { __index = Menu })
        Menu.init(menu)
        return menu
    end

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(module_names) do
            saved_modules[name] = package.loaded[name] or false
        end
        shown = nil
        painted_y = nil
        page_turns = {}
        centered_content_bottom = nil
        Menu = {
            init = function(self)
                self.page_info = { resetLayout = function() end }
                self.page_info_text = { tap_input = {}, hold_input = {} }
                self.page_return_arrow = {}
            end,
            registerTouchZones = function() end,
            _recalculateDimen = function() end,
            onPrevPage = function(self)
                page_turns[#page_turns + 1] = { "previous", self.page }
            end,
            onNextPage = function(self)
                page_turns[#page_turns + 1] = { "next", self.page }
            end,
        }
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ffi/blitbuffer", { COLOR_WHITE = "white" })
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
            },
        })
        ZenSpec.replace("ui/geometry", { new = function(_self, values) return values end })
        ZenSpec.replace("ui/widget/menu", Menu)
        ZenSpec.replace("ui/size", {
            line = { thin = 1 },
            padding = { small = 4, large = 10 },
        })
        ZenSpec.replace("ui/uimanager", {
            show = function(_self, widget) shown = widget end,
            close = function() end,
        })
        ZenSpec.replace("common/ui/zen_pager", {
            CHEV_W = 40,
            CHEV_HIT_W = 72,
            FOOTER_H = 32,
            PN_FOOTER_H = 40,
            setPlugin = function() end,
            getFooterGeometry = function() return 24, 552 end,
            getChevronHitWidth = function() return 72 end,
            getChevronHitBottom = function(y, h, available_bottom)
                return math.min(y + h + 24, available_bottom)
            end,
            getCenteredFooterY = function(content_bottom, footer_y, footer_h, should_center)
                centered_content_bottom = content_bottom
                if should_center then return 700 end
                return footer_y
            end,
            getStyle = function() return "page_number" end,
            getHoldSkip = function() return "10" end,
            paint = function(_bb, _x, y) painted_y = y end,
        })
        ZenSpec.replace("common/ui/zen_dialog", function(options)
            options.onShowKeyboard = function() end
            return options
        end)
        ZenSpec.unload("common/ui/zen_scroll_bar")
        require("common/ui/zen_scroll_bar")()
    end)

    after_each(function()
        ZenSpec.unload("common/ui/zen_scroll_bar")
        for _i, name in ipairs(module_names) do
            package.loaded[name] = saved_modules[name] or nil
        end
    end)

    it("does not open the go-to-page dialog from Zen settings", function()
        local settings = new_menu("zen_settings")
        local center_tap = find_zone(settings, "zen_pn_center_tap")

        assert.is_nil(settings.page_info_text.tap_input)
        assert.is_nil(settings.page_info_text.hold_input)
        assert.is_true(center_tap.handler())
        assert.is_nil(shown)
    end)

    it("keeps the go-to-page dialog in other paginated menus", function()
        local filemanager = new_menu("filemanager")
        local center_tap = find_zone(filemanager, "zen_pn_center_tap")
        local network_switcher = new_menu("network_switcher")

        assert.is_true(center_tap.handler())
        assert.are.equal("Go to page", shown.title)
        assert.is_table(network_switcher._zen_page_number_zones)
    end)

    it("keeps List and Mosaic Authors pagination at the same height", function()
        local list = new_menu("authors", {
            covers_fullscreen = true,
            is_borderless = true,
            title_bar_fm_style = true,
            display_mode_type = "list",
            item_group = {
                getSize = function() return { h = 520 } end,
            },
        })
        local mosaic = new_menu("authors", {
            covers_fullscreen = true,
            is_borderless = true,
            title_bar_fm_style = true,
            display_mode_type = "mosaic",
            item_margin = 10,
            item_group = {
                getSize = function() return { h = 320 } end,
            },
        })

        local list_area_y = list.dimen.h - list.page_info:getSize().h
        list.page_info.paintTo(nil, nil, 0, list_area_y)
        local list_y = painted_y
        local mosaic_area_y = mosaic.dimen.h - mosaic.page_info:getSize().h
        mosaic.page_info.paintTo(nil, nil, 0, mosaic_area_y)

        assert.are.equal(54, list.page_info:getSize().h)
        assert.are.equal(54, mosaic.page_info:getSize().h)
        assert.are.equal(750, list_y)
        assert.are.equal(list_y, painted_y)
    end)

    it("centers file-manager pagination in the space below the library grid", function()
        local filemanager = new_menu("filemanager", {
            display_mode_type = "mosaic",
            perpage = 12,
            item_dimen = { h = 100 },
            item_height = 100,
            item_margin = 10,
            nb_rows = 3,
            title_bar = { getHeight = function() return 20 end },
        })

        local area_y = filemanager.dimen.h - filemanager.page_info:getSize().h
        filemanager.page_info.paintTo(nil, nil, 0, area_y)

        assert.are.equal(360, centered_content_bottom)
        assert.are.equal(698, painted_y)
        assert.are.equal(694 / 800,
            find_zone(filemanager, "zen_pn_left_tap").screen_zone.ratio_y)
    end)

    it("uses list geometry after switching the library from mosaic mode", function()
        local filemanager = new_menu("filemanager", {
            display_mode_type = "list",
            perpage = 10,
            files_per_page = 10,
            item_dimen = { h = 50 },
            item_height = 50,
            item_margin = 10,
            nb_rows = 3,
        })

        filemanager.page_info.paintTo(nil, nil, 0, 746)

        assert.are.equal(511, centered_content_bottom)
    end)

    it("uses hitboxes wider than the visible chevron slots", function()
        local authors = new_menu("authors", {
            covers_fullscreen = true,
            is_borderless = true,
            title_bar_fm_style = true,
        })
        local left = find_zone(authors, "zen_pn_left_tap")
        local right = find_zone(authors, "zen_pn_right_tap")
        local center = find_zone(authors, "zen_pn_center_tap")

        assert.are.equal(72 / 600, left.screen_zone.ratio_w)
        assert.are.equal((24 + 552 - 72) / 600, right.screen_zone.ratio_x)
        assert.are.equal((24 + 72) / 600, center.screen_zone.ratio_x)
        assert.are.equal((552 - 144) / 600, center.screen_zone.ratio_w)
        assert.are.equal(746 / 800, left.screen_zone.ratio_y)
        assert.are.equal(54 / 800, left.screen_zone.ratio_h)
    end)

    it("extends only chevron hitboxes a short distance below a raised footer", function()
        local settings = new_menu("zen_settings")
        settings.page_info.paintTo(nil, nil, 0, 700)

        local left = find_zone(settings, "zen_pn_left_tap")
        local center = find_zone(settings, "zen_pn_center_tap")
        local right_hold = find_zone(settings, "zen_pn_right_hold")
        assert.are.equal(78 / 800, left.screen_zone.ratio_h)
        assert.are.equal(54 / 800, center.screen_zone.ratio_h)
        assert.are.equal(54 / 800, right_hold.screen_zone.ratio_h)
    end)

    it("stops enlarged chevron hitboxes before a navbar", function()
        local authors = new_menu("authors", {
            covers_fullscreen = true,
            is_borderless = true,
            title_bar_fm_style = true,
            _zen_navbar_height = 60,
        })
        authors.page_info.paintTo(nil, nil, 0, 686)

        local left = find_zone(authors, "zen_pn_left_tap")
        assert.are.equal(54 / 800, left.screen_zone.ratio_h)
    end)

    it("routes adjacent chevrons through directional page handlers", function()
        local authors = new_menu("authors", {
            covers_fullscreen = true,
            is_borderless = true,
            title_bar_fm_style = true,
        })

        assert.is_true(find_zone(authors, "zen_pn_left_tap").handler())
        assert.is_true(find_zone(authors, "zen_pn_right_tap").handler())

        assert.are.same({
            { "previous", 1 },
            { "next", 1 },
        }, page_turns)
    end)
end)
