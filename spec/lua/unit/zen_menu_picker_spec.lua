describe("Zen menu picker", function()
    local saved_modules
    local shown
    local selected
    local device_has_dpad
    local device_has_keyboard
    local device_is_touch
    local back_inverted
    local closed
    local pager_x
    local pager_y
    local pager_w
    local pager_page
    local row_font_size
    local text_widgets
    local back_icon
    local back_paint_x
    local truncated_text
    local mirrored
    local screen_w
    local screen_h
    local pager_mirrored
    local touch_resize_dimen
    local image_widgets

    local module_names = {
        "gettext",
        "ui/bidi",
        "device",
        "ui/geometry",
        "ffi/blitbuffer",
        "ui/font",
        "ui/size",
        "ui/uimanager",
        "ui/widget/infomessage",
        "ui/widget/focusmanager",
        "ui/widget/imagewidget",
        "ui/widget/iconwidget",
        "ui/widget/textwidget",
        "common/ui/zen_pager",
        "common/ui/zen_title_style",
        "common/ui/truncated_text_message",
        "common/ui/zen_button",
        "common/ui/zen_menu_picker",
    }

    local function focus_manager()
        local FocusManager = {}

        function FocusManager:extend(definition)
            definition = definition or {}
            setmetatable(definition, { __index = self })
            return definition
        end

        function FocusManager:new(values)
            values = values or {}
            setmetatable(values, { __index = self })
            values:init()
            return values
        end

        function FocusManager:_init()
            self.key_events = {
                FocusDown = { { "Down" }, event = "FocusMove", args = { 0, 1 } },
                Press = { { "Press" }, event = "Press" },
            }
        end

        function FocusManager:registerTouchZones(zones) self.touch_zones = zones end
        function FocusManager:updateTouchZonesOnScreenResize(dimen) touch_resize_dimen = dimen end

        return FocusManager
    end

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(module_names) do
            saved_modules[name] = package.loaded[name] or false
        end
        shown = nil
        selected = nil
        device_has_dpad = true
        device_has_keyboard = false
        device_is_touch = false
        back_inverted = nil
        closed = 0
        pager_x = nil
        pager_y = nil
        pager_w = nil
        pager_page = nil
        row_font_size = nil
        text_widgets = {}
        back_icon = nil
        back_paint_x = nil
        truncated_text = nil
        mirrored = false
        screen_w = 600
        screen_h = 800
        pager_mirrored = nil
        touch_resize_dimen = nil
        image_widgets = {}

        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/bidi", {
            mirroredUILayout = function() return mirrored end,
            flipDirectionIfMirroredUILayout = function(direction)
                if not mirrored then return direction end
                if direction == "west" then return "east" end
                if direction == "east" then return "west" end
                return direction
            end,
        })
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return screen_w end,
                getHeight = function() return screen_h end,
                scaleBySize = function(_, value) return value end,
            },
            input = { group = { Back = { "Back" }, PgBack = { "PgBack" }, PgFwd = { "PgFwd" } } },
            hasKeys = function() return true end,
            hasDPad = function() return device_has_dpad end,
            hasKeyboard = function() return device_has_keyboard end,
            isTouchDevice = function() return device_is_touch end,
        })
        ZenSpec.replace("ui/geometry", { new = function(_, values) return values end })
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_BLACK = "black",
            COLOR_DARK_GRAY = "dark_gray",
            COLOR_LIGHT_GRAY = "light_gray",
            COLOR_WHITE = "white",
        })
        ZenSpec.replace("ui/font", {
            getFace = function(_self, _name, size)
                if size then row_font_size = size end
                return {}
            end,
        })
        ZenSpec.replace("ui/size", {
            line = { thick = 1 },
            padding = { default = 10, large = 20, small = 4 },
            span = { vertical_default = 4 },
        })
        ZenSpec.replace("ui/uimanager", {
            show = function(_, widget) shown = widget end,
            close = function() closed = closed + 1 end,
            forceRePaint = function() end,
            nextTick = function(_, callback) callback() end,
            setDirty = function() end,
        })
        ZenSpec.replace("ui/widget/infomessage", {
            new = function(_self, options)
                options.movable = {}
                return options
            end,
        })
        ZenSpec.replace("ui/widget/focusmanager", focus_manager())
        ZenSpec.replace("ui/widget/iconwidget", {
            new = function(_, values)
                back_icon = values
                values.paintTo = function(self, _bb, x)
                    back_inverted = self.invert
                    back_paint_x = x
                end
                return values
            end,
        })
        ZenSpec.replace("ui/widget/imagewidget", {
            new = function(_self, values)
                values.paintTo = function(self, _bb, x, y)
                    self.paint_x, self.paint_y = x, y
                end
                values.free = function() end
                image_widgets[#image_widgets + 1] = values
                return values
            end,
        })
        ZenSpec.replace("ui/widget/textwidget", {
            new = function(_, values)
                values.getSize = function() return { w = 100, h = 20 } end
                values.setText = function(self, text) self.text = text end
                values.setMaxWidth = function(self, width) self.max_width = width end
                values.isTruncated = function(self) return self.text == truncated_text end
                values.paintTo = function(self, _bb, x) self.paint_x = x end
                values.free = function() end
                text_widgets[#text_widgets + 1] = values
                return values
            end,
        })
        ZenSpec.replace("common/ui/zen_pager", {
            CHEV_W = 20,
            CHEV_HIT_W = 40,
            PN_FOOTER_H = 30,
            getHoldSkip = function() return "ends" end,
            getCenteredFooterY = function(content_bottom, footer_y, footer_h)
                local gap_h = footer_y + footer_h - content_bottom
                return content_bottom + math.floor((gap_h - footer_h) / 2)
            end,
            getPageNumberZone = function(x, y, footer_x, footer_y, footer_w, footer_h, available_bottom)
                local hit_bottom = math.min(footer_y + footer_h + 24, available_bottom)
                if x < footer_x or x >= footer_x + footer_w
                        or y < footer_y or y >= hit_bottom then
                    return nil
                end
                if x < footer_x + 40 then return "left" end
                if x >= footer_x + footer_w - 40 then return "right" end
                if y < footer_y + footer_h then return "center" end
            end,
            paint = function(_bb, x, y, w, _h, cur_page, _total_pages, _style, is_mirrored)
                pager_x = x
                pager_y = y
                pager_w = w
                pager_page = cur_page
                pager_mirrored = is_mirrored
            end,
        })
        ZenSpec.replace("common/ui/zen_title_style", {
            ICON_SIZE = 28,
            BUTTON_PADDING = 8,
            BUTTON_SIZE = 44,
            LEFT_PADDING = 22,
            RIGHT_PADDING = 20,
            ROW_HEIGHT = 44,
            VERTICAL_PADDING = 6,
            DIVIDER_HEIGHT = 2,
            DIVIDER_COLOR = "light_gray",
            HEADER_CONTENT_HEIGHT = 56,
            HEADER_HEIGHT = 58,
            getTitleFace = function() return { name = "settings_title" } end,
            getLeadingIconX = function(origin) return (origin or 0) + 39 end,
            getTitleX = function(origin) return (origin or 0) + 92 end,
        })
        ZenSpec.unload("common/ui/truncated_text_message")
        ZenSpec.unload("common/ui/zen_button")
        ZenSpec.unload("common/ui/zen_menu_picker")
    end)

    after_each(function()
        for _i, name in ipairs(module_names) do
            package.loaded[name] = saved_modules[name] or nil
        end
    end)

    it("uses D-pad focus movement to select an item", function()
        require("common/ui/zen_menu_picker"){
            title = "Choose plugin menu",
            items = {
                { text = "First" },
                { text = "Second" },
            },
            on_select = function(item) selected = item.text end,
        }

        assert.is_not_nil(shown.key_events.FocusDown)
        assert.is_nil(shown.key_events.MenuPickerDown)
        assert.is_true(shown:onFocusMove({ 0, 1 }))
        assert.is_true(shown:onPress())
        assert.are.equal("Second", selected)
    end)

    it("keeps requested actions open until Back", function()
        local picker = require("common/ui/zen_menu_picker"){
            items = { { text = "Find cover", keep_open = true } },
            on_select = function(item) selected = item.text end,
        }

        assert.are.equal(shown, picker)
        assert.is_true(shown:onPress())
        assert.are.equal("Find cover", selected)
        assert.are.equal(0, closed)
        assert.is_true(shown:onCancelOrClose())
        assert.are.equal(1, closed)
    end)

    it("shows focus when a touchscreen device has a keyboard", function()
        device_has_dpad = false
        device_has_keyboard = true
        device_is_touch = true
        require("common/ui/zen_menu_picker"){
            items = { { text = "Plugin" } },
        }

        local painted = {}
        shown:paintTo({
            paintRect = function(_, _x, _y, _w, _h, color)
                painted[#painted + 1] = color
            end,
        }, 0, 0)

        assert.is_true(table.concat(painted, ","):find("black", 1, true) ~= nil)
    end)

    it("uses larger text for picker rows", function()
        require("common/ui/zen_menu_picker"){
            items = { { text = "Plugin" } },
        }

        assert.are.equal(24, row_font_size)
    end)

    it("renders optional secondary row text", function()
        require("common/ui/zen_menu_picker"){
            items = { { text = "Edition", secondary_text = "Paperback · English" } },
        }

        shown:paintTo({ paintRect = function() end }, 0, 0)
        assert.are.equal("Edition", text_widgets[2].text)
        assert.are.equal("Paperback · English", text_widgets[3].text)
        assert.are.equal("white", text_widgets[3].fgcolor)
    end)

    it("renders an optional image preview and reports the selected item on close", function()
        local closed_item
        local item = {
            text = "Paperback",
            secondary_text = "Orbit · English",
            image_file = "/tmp/cover.jpg",
        }
        require("common/ui/zen_menu_picker"){
            items = { item },
            on_close = function(selected_item) closed_item = selected_item end,
        }

        shown:paintTo({ paintRect = function() end }, 0, 0)
        assert.are.equal("/tmp/cover.jpg", image_widgets[1].file)
        assert.are.equal(22, image_widgets[1].paint_x)
        assert.are.equal(69, text_widgets[2].paint_x)
        assert.is_true(shown:onPress())
        assert.are.equal(item, closed_item)
    end)

    it("places an optional preview above its rows", function()
        local painted_header
        local tapped_header
        require("common/ui/zen_menu_picker"){
            items = { { text = "Choose image" } },
            header_height = 100,
            paint_header = function(_bb, x, y, width, height)
                painted_header = { x, y, width, height }
            end,
            on_header_tap = function(x, y, width, height)
                tapped_header = { x, y, width, height }
            end,
            on_select = function(item) selected = item.text end,
        }

        shown:paintTo({ paintRect = function() end }, 0, 0)
        assert.are.same({ 0, 58, 600, 100 }, painted_header)
        assert.is_true(shown.touch_zones[1].handler({ pos = { x = 100, y = 100 } }))
        assert.are.same({ 100, 42, 600, 100 }, tapped_header)
        assert.is_nil(selected)
        assert.is_true(shown.touch_zones[1].handler({ pos = { x = 100, y = 168 } }))
        assert.are.equal("Choose image", selected)
    end)

    it("renders and activates optional footer buttons", function()
        device_has_dpad = false
        device_is_touch = true
        require("common/ui/zen_menu_picker"){
            footer_buttons = {
                { text = "Choose image", keep_open = true },
                { text = "Find metadata", keep_open = true, filled = true },
            },
            on_select = function(item) selected = item.text end,
        }

        shown:paintTo({ paintRect = function() end }, 0, 0)
        assert.is_nil(pager_y)
        assert.is_true(shown.touch_zones[1].handler({ pos = { x = 100, y = 770 } }))
        assert.are.equal("Choose image", selected)
        assert.is_true(shown.touch_zones[1].handler({ pos = { x = 400, y = 770 } }))
        assert.are.equal("Find metadata", selected)
        assert.are.equal(0, closed)
    end)

    it("stacks footer buttons under the right preview column", function()
        device_has_dpad = false
        device_is_touch = true
        require("common/ui/zen_menu_picker"){
            header_height = 100,
            paint_header = function() end,
            hide_header_divider = true,
            footer_buttons_under_header = true,
            footer_buttons = {
                { text = "Choose image", keep_open = true },
                { text = "Find metadata", keep_open = true, filled = true },
                { text = "Clear" },
            },
            on_select = function(item) selected = item.text end,
        }

        local dividers = {}
        shown:paintTo({
            paintRect = function(_bb, _x, _y, _w, h, color)
                if h == 2 then dividers[#dividers + 1] = color end
            end,
        }, 0, 0)
        assert.are.same({ "light_gray" }, dividers)
        assert.is_true(shown.touch_zones[1].handler({ pos = { x = 400, y = 170 } }))
        assert.are.equal("Choose image", selected)
        assert.is_true(shown.touch_zones[1].handler({ pos = { x = 400, y = 205 } }))
        assert.are.equal("Find metadata", selected)
        assert.is_true(shown.touch_zones[1].handler({ pos = { x = 400, y = 245 } }))
        assert.are.equal("Clear", selected)
    end)

    it("closes when its title text is tapped", function()
        require("common/ui/zen_menu_picker"){
            title = "Cover",
            items = { { text = "Item" } },
        }

        assert.is_true(shown.touch_zones[1].handler({ pos = { x = 160, y = 20 } }))
        assert.are.equal(1, closed)
    end)

    it("runs an optional trailing title action", function()
        local searched = false
        require("common/ui/zen_menu_picker"){
            title = "Hardcover results",
            items = { { text = "Book" } },
            title_action_icon = "/icons/search.svg",
            title_action_callback = function() searched = true end,
        }

        assert.are.equal("/icons/search.svg", back_icon.file)
        assert.is_nil(back_icon.icon)
        assert.is_true(shown.touch_zones[1].handler({ pos = { x = 560, y = 20 } }))
        assert.is_true(searched)
        assert.are.equal(1, closed)
    end)

    it("can keep the picker open for a trailing title action", function()
        local searched = false
        require("common/ui/zen_menu_picker"){
            items = { { text = "Book" } },
            title_action_icon = "/icons/search.svg",
            title_action_keep_open = true,
            title_action_callback = function() searched = true end,
        }

        assert.is_true(shown.touch_zones[1].handler({ pos = { x = 560, y = 20 } }))
        assert.is_true(searched)
        assert.are.equal(0, closed)
    end)

    it("keeps primary and secondary result text black", function()
        require("common/ui/zen_menu_picker"){
            items = { { text = "Book", secondary_text = "Author" } },
            black_text = true,
        }

        shown:paintTo({ paintRect = function() end }, 0, 0)
        assert.are.equal("black", text_widgets[2].fgcolor)
        assert.are.equal("black", text_widgets[3].fgcolor)
    end)

    it("caps result pages at the requested row count", function()
        local items = {}
        for item_index = 1, 6 do
            items[item_index] = { text = "Item " .. tostring(item_index) }
        end
        require("common/ui/zen_menu_picker"){ items = items, rows_per_page = 5 }

        shown:onMenuPickerPage(1)
        shown:paintTo({ paintRect = function() end }, 0, 0)
        assert.are.equal(2, pager_page)
    end)

    it("appends rows and updates a live title only while open", function()
        local picker = require("common/ui/zen_menu_picker"){
            title = "Metadata results · 2 / 3 still loading",
            items = { { text = "First", secondary_text = "Hardcover" } },
            rows_per_page = 5,
        }
        local batch = {}
        for item_index = 2, 6 do
            batch[#batch + 1] = {
                text = "Result " .. tostring(item_index),
                secondary_text = "Provider",
            }
        end

        assert.is_true(picker:addItems(batch, "Metadata results · 1 / 3 still loading"))
        assert.are.equal("Metadata results · 1 / 3 still loading", text_widgets[1].text)
        picker:onMenuPickerPage(1)
        picker:paintTo({ paintRect = function() end }, 0, 0)
        assert.are.equal(2, pager_page)
        picker:onCancelOrClose()
        assert.is_false(picker:addItems({}, "Late update"))
        assert.are.equal("Metadata results · 1 / 3 still loading", text_widgets[1].text)
    end)

    it("keeps the current emulator page during a live row refresh", function()
        device_is_touch = true
        device_has_dpad = true
        local items = {}
        for item_index = 1, 11 do
            items[item_index] = { text = "Item " .. tostring(item_index) }
        end
        local picker = require("common/ui/zen_menu_picker"){
            items = items,
            rows_per_page = 5,
        }

        picker:paintTo({ paintRect = function() end }, 0, 0)
        picker.touch_zones[1].handler({ pos = { x = 580, y = pager_y + 1 } })
        picker:paintTo({ paintRect = function() end }, 0, 0)
        assert.are.equal(2, pager_page)

        items[1].image_file = "/covers/1.jpg"
        assert.is_true(picker:addItems({}))
        picker:paintTo({ paintRect = function() end }, 0, 0)
        assert.are.equal(2, pager_page)
    end)

    it("expands requested cover rows to fill the page", function()
        local items = {}
        for item_index = 1, 5 do
            items[item_index] = {
                text = "Cover " .. tostring(item_index),
                image_file = "/covers/" .. tostring(item_index) .. ".jpg",
            }
        end
        require("common/ui/zen_menu_picker"){
            items = items,
            rows_per_page = 5,
            on_select = function(item) selected = item.text end,
        }

        shown:paintTo({ paintRect = function() end }, 0, 0)
        assert.is_true(image_widgets[1].height > 100)
        assert.is_true(shown.touch_zones[1].handler({ pos = { x = 100, y = 700 } }))
        assert.are.equal("Cover 5", selected)
    end)

    it("matches the arrange-list header divider", function()
        require("common/ui/zen_menu_picker"){
            items = { { text = "Plugin" } },
        }
        local dividers = {}
        shown:paintTo({
            paintRect = function(_bb, _x, _y, _w, h, color)
                if h == 2 then dividers[#dividers + 1] = color end
            end,
        }, 0, 0)

        assert.are.same({ "light_gray" }, dividers)
    end)

    it("aligns its title and back icon with the arrange-list header", function()
        require("common/ui/zen_menu_picker"){
            title = "Choose plugin menu",
            items = { { text = "Plugin" } },
        }
        shown:paintTo({ paintRect = function() end }, 0, 0)

        assert.are.equal(28, back_icon.width)
        assert.are.equal(39, back_paint_x)
        assert.are.equal("settings_title", text_widgets[1].face.name)
        assert.are.equal(92, text_widgets[1].paint_x)
    end)

    it("mirrors its header, rows, pager, and back hitbox in RTL", function()
        mirrored = true
        require("common/ui/zen_menu_picker"){
            title = "Choose plugin menu",
            items = { { text = "Plugin" } },
        }
        shown:paintTo({ paintRect = function() end }, 0, 0)

        assert.are.equal("chevron.right", back_icon.icon)
        assert.are.equal(533, back_paint_x)
        assert.are.equal(408, text_widgets[1].paint_x)
        assert.are.equal(478, text_widgets[2].paint_x)
        assert.is_true(pager_mirrored)
        assert.is_true(shown.touch_zones[1].handler({ pos = { x = 570, y = 20 } }))
        assert.are.equal(1, closed)
    end)

    it("flips horizontal page navigation in RTL", function()
        mirrored = true
        local items = {}
        for item_index = 1, 15 do
            items[item_index] = { text = "Item " .. tostring(item_index) }
        end
        require("common/ui/zen_menu_picker"){ items = items }
        shown:onMenuPickerPage(1)

        assert.is_true(shown:onFocusMove({ 1, 0 }))
        shown:paintTo({ paintRect = function() end }, 0, 0)
        assert.are.equal(1, pager_page)

        shown:onMenuPickerPage(1)
        assert.is_true(shown.touch_zones[3].handler({ direction = "west" }))
        shown:paintTo({ paintRect = function() end }, 0, 0)
        assert.are.equal(1, pager_page)
    end)

    it("flips keyboard-only arrow paging in RTL", function()
        mirrored = true
        device_has_dpad = false
        device_has_keyboard = true
        require("common/ui/zen_menu_picker"){ items = { { text = "Plugin" } } }

        assert.are.equal(1, shown.key_events.MenuPickerPreviousPage.args)
        assert.are.equal(-1, shown.key_events.MenuPickerNextPage.args)
    end)

    it("bolds root rows and indents nested rows", function()
        require("common/ui/zen_menu_picker"){
            items = {
                { text = "Settings", bold = true, indent_level = 0 },
                { text = "Network", indent_level = 1 },
            },
        }

        shown:paintTo({ paintRect = function() end }, 0, 0)
        local root_row = text_widgets[2]
        local nested_row = text_widgets[3]
        assert.is_true(root_row.bold)
        assert.is_false(nested_row.bold)
        assert.are.equal(16, nested_row.paint_x - root_row.paint_x)
    end)

    it("shows full truncated row text on hold", function()
        local full_text = "A plugin menu label too long for its row"
        truncated_text = full_text
        require("common/ui/zen_menu_picker"){
            items = { { text = full_text } },
        }
        local picker = shown
        picker:paintTo({ paintRect = function() end }, 0, 0)

        assert.is_true(picker.touch_zones[2].handler({ pos = { x = 100, y = 70 } }))
        assert.are.equal(full_text, shown.text)
        assert.is_false(shown.show_icon)
        assert.are.same({ y = 54, h = 56 }, shown.movable.anchor)
    end)

    it("focuses and activates the back chevron from the first item", function()
        require("common/ui/zen_menu_picker"){
            items = { { text = "Plugin" } },
        }

        assert.is_true(shown:onFocusMove({ 0, -1 }))
        local painted = {}
        shown:paintTo({
            paintRect = function(_, _x, _y, _w, _h, color)
                painted[#painted + 1] = color
            end,
        }, 0, 0)
        assert.is_true(back_inverted)
        assert.is_nil(table.concat(painted, ","):find("black", 1, true))
        assert.is_true(shown:onFocusMove({ 0, 1 }))
        painted = {}
        shown:paintTo({
            paintRect = function(_, _x, _y, _w, _h, color)
                painted[#painted + 1] = color
            end,
        }, 0, 0)
        assert.is_false(back_inverted)
        assert.is_true(table.concat(painted, ","):find("black", 1, true) ~= nil)
        assert.is_true(shown:onFocusMove({ 0, -1 }))
        assert.is_true(shown:onPress())
        assert.are.equal(1, closed)
    end)

    it("uses its supplied root callback when its header is held", function()
        local root_returns = 0
        local fallback_returns = 0
        _G.__ZEN_UI_SETTINGS_PAGE = {
            backToRootMenu = function() fallback_returns = fallback_returns + 1 end,
        }
        require("ui/uimanager").close = function()
            closed = closed + 1
            _G.__ZEN_UI_SETTINGS_PAGE = nil
        end
        require("common/ui/zen_menu_picker"){
            items = { { text = "Plugin" } },
            back_hold_callback = function() root_returns = root_returns + 1 end,
        }

        assert.is_true(shown.touch_zones[2].handler({ pos = { x = 30, y = 20 } }))
        assert.are.equal(1, closed)
        assert.are.equal(1, root_returns)
        assert.are.equal(0, fallback_returns)
        _G.__ZEN_UI_SETTINGS_PAGE = nil
    end)

    it("captures the settings page before closing the picker", function()
        local root_returns = 0
        _G.__ZEN_UI_SETTINGS_PAGE = {
            backToRootMenu = function() root_returns = root_returns + 1 end,
        }
        require("ui/uimanager").close = function()
            closed = closed + 1
            _G.__ZEN_UI_SETTINGS_PAGE = nil
        end
        require("common/ui/zen_menu_picker"){
            items = { { text = "Plugin" } },
        }

        assert.is_true(shown.touch_zones[2].handler({ pos = { x = 30, y = 20 } }))
        assert.are.equal(1, closed)
        assert.are.equal(1, root_returns)
    end)

    it("keeps a centered pager at the same height on every page", function()
        local items = {}
        for item_index = 1, 15 do
            items[item_index] = { text = "Item " .. tostring(item_index) }
        end
        require("common/ui/zen_menu_picker"){ items = items }

        shown:paintTo({ paintRect = function() end }, 0, 0)
        local first_page_y = pager_y
        shown:onMenuPickerPage(1)
        shown:paintTo({ paintRect = function() end }, 0, 0)

        assert.are.equal(10, pager_x)
        assert.are.equal(745, first_page_y)
        assert.are.equal(580, pager_w)
        assert.are.equal(first_page_y, pager_y)
    end)

    it("preserves its page and refreshes geometry on rotation", function()
        local items = {}
        for item_index = 1, 30 do
            items[item_index] = { text = "Item " .. tostring(item_index) }
        end
        require("common/ui/zen_menu_picker"){ items = items }
        shown:onMenuPickerPage(1)
        screen_w = 800
        screen_h = 600

        assert.is_false(shown:onScreenResize())
        shown:paintTo({ paintRect = function() end }, 0, 0)

        assert.is_true(shown.covers_fullscreen)
        assert.are.same({ x = 0, y = 0, w = 800, h = 600 }, shown.dimen)
        assert.are.equal(shown.dimen, touch_resize_dimen)
        assert.are.equal(2, pager_page)
        assert.are.equal(780, pager_w)
        assert.are.equal(688, text_widgets[1].max_width)
    end)

    it("accepts wider chevron taps briefly below the painted footer", function()
        local items = {}
        for item_index = 1, 15 do
            items[item_index] = { text = "Item " .. tostring(item_index) }
        end
        require("common/ui/zen_menu_picker"){ items = items }
        local tap = shown.touch_zones[1].handler

        assert.is_true(tap({ pos = { x = 40, y = 790 } }))
        shown:paintTo({ paintRect = function() end }, 0, 0)
        assert.are.equal(2, pager_page)
        assert.is_true(tap({ pos = { x = 300, y = 790 } }))
        assert.is_true(tap({ pos = { x = 40, y = 799 } }))
        shown:paintTo({ paintRect = function() end }, 0, 0)
        assert.are.equal(2, pager_page)
    end)
end)
