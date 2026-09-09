describe("book details", function()
    local BookInfoWidget
    local image_specs
    local top_taps
    local top_swipes
    local description_swipes
    local description_line_scroll
    local description_page_up
    local description_page_down
    local close_calls
    local saved_modules
    local icon_specs
    local text_specs
    local progress_specs
    local progress_frees
    local full_text_message
    local zen_button_calls
    local horizontal_swipes

    local dependency_names = {
        "gettext",
        "device",
        "datastorage",
        "ffi/blitbuffer",
        "ui/font",
        "ui/geometry",
        "ui/uimanager",
        "ui/widget/container/inputcontainer",
        "ui/widget/container/scrollablecontainer",
        "ui/widget/iconwidget",
        "ui/widget/imagewidget",
        "ui/widget/scrolltextwidget",
        "ui/widget/textwidget",
        "common/inline_icon_map",
        "common/cover_utils",
        "common/ui/book_progress",
        "common/ui/truncated_text_message",
        "common/ui/zen_button",
        "common/ui/zen_title_style",
        "common/utils",
        "modules/global/patches/menu_top_swipe",
    }

    local function input_container()
        local InputContainer = {}

        function InputContainer:extend(prototype)
            prototype = prototype or {}
            prototype.__index = prototype
            return setmetatable(prototype, { __index = self })
        end

        function InputContainer:new(values)
            values = values or {}
            setmetatable(values, { __index = self })
            values:init()
            return values
        end

        function InputContainer:registerTouchZones(zones)
            self.touch_zones = zones
        end

        return InputContainer
    end

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(dependency_names) do
            saved_modules[name] = package.loaded[name] or false
        end
        image_specs = {}
        top_taps = 0
        top_swipes = 0
        description_swipes = 0
        description_line_scroll = 0
        description_page_up = 0
        description_page_down = 0
        close_calls = 0
        icon_specs = {}
        text_specs = {}
        progress_specs = {}
        progress_frees = 0
        full_text_message = nil
        zen_button_calls = {}
        horizontal_swipes = 0

        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 800 end,
                scaleBySize = function(_self, value) return value end,
            },
            hasKeys = function() return false end,
        })
        ZenSpec.replace("datastorage", { getDataDir = function() return "/koreader" end })
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_BLACK = "black",
            COLOR_LIGHT_GRAY = "light_gray",
            COLOR_WHITE = "white",
        })
        ZenSpec.replace("ui/font", {
            getFace = function(_self, name, size)
                return { name = name, orig_size = size }
            end,
        })
        ZenSpec.replace("ui/geometry", { new = function(_self, values) return values end })
        ZenSpec.replace("ui/uimanager", {
            close = function() close_calls = close_calls + 1 end,
            setDirty = function() end,
        })
        ZenSpec.replace("ui/widget/container/inputcontainer", input_container())
        ZenSpec.replace("ui/widget/container/scrollablecontainer", {
            new = function(_self, values)
                local content = values[1]
                values.getSize = function(self) return self.dimen end
                values.paintTo = function(self, bb, x, y)
                    self.dimen.x, self.dimen.y = x, y
                    content:paintTo(bb, x - (self._scroll_offset_x or 0), y)
                end
                values.onScrollableSwipe = function(self, _arg, _ges)
                    if content.dimen.w <= self.dimen.w then return false end
                    horizontal_swipes = horizontal_swipes + 1
                    self._scroll_offset_x = 20
                    return true
                end
                values.onScrollablePan = function(self)
                    self._scrolling = true
                    return true
                end
                values.onScrollablePanRelease = function(self)
                    self._scrolling = false
                    return true
                end
                values.initState = function(self)
                    self._h_scroll_bar = { enable = true }
                end
                values.onCloseWidget = function() end
                values.free = function() end
                return values
            end,
        })
        ZenSpec.replace("ui/widget/iconwidget", {
            new = function(_self, values)
                icon_specs[#icon_specs + 1] = values
                values.getSize = function(self) return { w = self.width, h = self.height } end
                values.paintTo = function(self, _bb, x, y)
                    self.paint_x = x
                    self.paint_y = y
                end
                values.free = function() end
                return values
            end,
        })
        ZenSpec.replace("ui/widget/imagewidget", {
            new = function(_self, values)
                image_specs[#image_specs + 1] = values
                values.paintTo = function() end
                values.free = function() end
                return values
            end,
        })
        ZenSpec.replace("ui/widget/scrolltextwidget", {
            new = function(_self, values)
                values.paintTo = function() end
                values.free = function() end
                values.onTapScrollText = function() end
                values.onScrollText = function()
                    description_swipes = description_swipes + 1
                end
                values.onPanText = function() end
                values.onPanReleaseText = function() end
                values.text_widget = {
                    virtual_line_num = 1,
                    scrollLines = function(scroll_widget, lines)
                        description_line_scroll = description_line_scroll + lines
                        scroll_widget.virtual_line_num = math.max(
                            1, scroll_widget.virtual_line_num + lines)
                    end,
                }
                values.updateScrollBar = function() end
                values.onScrollUp = function()
                    description_page_up = description_page_up + 1
                end
                values.onScrollDown = function()
                    description_page_down = description_page_down + 1
                end
                return values
            end,
        })
        ZenSpec.replace("ui/widget/textwidget", {
            new = function(_self, values)
                text_specs[#text_specs + 1] = values
                values.getSize = function() return { w = 100, h = 20 } end
                values.isTruncated = function()
                    return values.max_width ~= nil and #tostring(values.text or "") > 40
                end
                values.paintTo = function(self, _bb, x, y)
                    self.paint_x = x
                    self.paint_y = y
                end
                values.free = function() end
                return values
            end,
        })
        ZenSpec.replace("common/inline_icon_map", { edit = "edit-icon" })
        ZenSpec.replace("common/cover_utils", { BORDER_SIZE = 1 })
        ZenSpec.replace("common/ui/book_progress", {
            build = function(values)
                progress_specs[#progress_specs + 1] = values
                return {
                    getSize = function() return { w = values.width, h = 14 } end,
                    paintTo = function(self, _bb, x, y)
                        self.paint_x, self.paint_y = x, y
                    end,
                    free = function() progress_frees = progress_frees + 1 end,
                }
            end,
        })
        ZenSpec.replace("common/ui/truncated_text_message", {
            showMetadata = function(text, anchor)
                full_text_message = { text = text, anchor = anchor }
            end,
        })
        ZenSpec.replace("common/ui/zen_button", {
            paintFilled = function(_bb, x, y, w, h, text, font_size)
                zen_button_calls[#zen_button_calls + 1] = {
                    kind = "filled", x = x, y = y, w = w, h = h,
                    text = text, font_size = font_size,
                }
            end,
            paintOutlined = function(_bb, x, y, w, h, text, font_size)
                zen_button_calls[#zen_button_calls + 1] = {
                    kind = "outlined", x = x, y = y, w = w, h = h,
                    text = text, font_size = font_size,
                }
            end,
        })
        ZenSpec.replace("common/ui/zen_title_style", {
            ICON_BASE_SIZE = 28,
            ICON_SIZE = 28,
            BUTTON_SIZE = 44,
            LEFT_PADDING = 22,
            RIGHT_PADDING = 20,
            ACTION_FONT_SIZE = 18,
            ACTION_PADDING_H = 8,
            TRAILING_GAP = 4,
            ROW_HEIGHT = 44,
            VERTICAL_PADDING = 6,
            DIVIDER_HEIGHT = 2,
            DIVIDER_COLOR = "light_gray",
            HEADER_CONTENT_HEIGHT = 56,
            HEADER_HEIGHT = 58,
            BUTTON_PADDING = 8,
            getTitleFace = function() return { name = "settings_title" } end,
            getLeadingIconX = function(origin) return (origin or 0) + 39 end,
            getTitleX = function(origin) return (origin or 0) + 92 end,
            getTrailingIconX = function(width, origin)
                return (origin or 0) + width - 20 - 8 - 28
            end,
        })
        ZenSpec.replace("common/utils", {
            resolveLocalIcon = function(_, name) return "/icons/" .. name .. ".svg" end,
        })
        ZenSpec.replace("modules/global/patches/menu_top_swipe", {
            handleTap = function()
                top_taps = top_taps + 1
                return true
            end,
            handleSwipe = function()
                top_swipes = top_swipes + 1
                return true
            end,
        })
        ZenSpec.unload("modules/reader/book_info_widget")
        BookInfoWidget = require("modules/reader/book_info_widget")
    end)

    after_each(function()
        ZenSpec.unload("modules/reader/book_info_widget")
        for _i, name in ipairs(dependency_names) do
            package.loaded[name] = saved_modules[name] or nil
        end
    end)

    local function new_widget(close_all_callback)
        return BookInfoWidget:new{
            cover = {},
            cover_width = 120,
            cover_height = 180,
            description = "Description",
            close_all_callback = close_all_callback,
        }
    end

    it("keeps the cover colors correct in night mode", function()
        new_widget()

        assert.are.equal(true, image_specs[1].original_in_nightmode)
    end)

    it("does not render a description heading", function()
        new_widget()

        assert.are.equal(1, #text_specs)
        assert.are.equal("Book details", text_specs[1].text)
    end)

    it("uses the full metadata row before truncating with ellipses", function()
        local widget = BookInfoWidget:new{
            cover = {},
            cover_width = 120,
            cover_height = 180,
            description = "Description",
            details = {
                { text = "Title", style = "title", bold = true },
                { text = "Author", style = "author" },
                { text = "Series", style = "secondary" },
                { text = "Tags", style = "tags" },
            },
        }
        local specs = {}
        for _i, values in ipairs(text_specs) do
            if values.max_width then specs[values.text] = values end
        end

        for _i, text in ipairs({ "Title", "Author", "Series", "Tags" }) do
            assert.are.equal(600 - widget._L.pad,
                widget._L.details_x + specs[text].max_width)
            assert.is_true(specs[text].truncate_with_ellipsis)
            assert.are.equal(0, specs[text].padding)
        end
        assert.are.equal(4, #widget._detail_widgets)
    end)

    it("renders every tag as an outlined button on one scrollable row and opens it", function()
        local opened_tag
        local widget = BookInfoWidget:new{
            description = "Description",
            details = {
                { text = "Title", style = "title", bold = true },
                {
                    style = "tag_buttons",
                    tags = {
                        "First", "Second", "Third", "Fourth", "Fifth", "Sixth",
                        "Seventh", "Eighth", "Ninth", "Tenth", "Eleventh",
                    },
                    gap_before = 3,
                },
            },
            tag_callback = function(tag) opened_tag = tag end,
        }
        widget:paintTo({
            paintRect = function() end,
            paintBorder = function() end,
        }, 0, 0)

        assert.are.equal(11, #zen_button_calls)
        for _i, call in ipairs(zen_button_calls) do
            assert.are.equal("outlined", call.kind)
        end
        assert.are.equal(31, widget._detail_widgets[2].h)
        assert.is_false(widget._tag_scroll._h_scroll_bar.enable)
        assert.are.equal(zen_button_calls[1].y, zen_button_calls[2].y)
        assert.are.equal(zen_button_calls[1].y, zen_button_calls[11].y)

        assert.is_true(widget:_onSwipe({
            direction = "west",
            pos = { x = widget._tag_scroll.dimen.x, y = widget._tag_scroll.dimen.y },
        }))
        assert.are.equal(1, horizontal_swipes)

        widget:paintTo({ paintRect = function() end, paintBorder = function() end }, 0, 0)
        local second = widget._tag_buttons[2].dimen
        assert.is_true(widget:_onTap({ pos = { x = second.x, y = second.y } }))
        assert.are.equal("Second", opened_tag)
        assert.are.equal(1, close_calls)
        assert.are.equal(0, top_taps)
    end)

    it("shows the full value when tapping truncated metadata only", function()
        local full_text = "A metadata value long enough to be truncated on one line"
        local widget = BookInfoWidget:new{
            description = "Description",
            details = {
                { text = "Short value", style = "title" },
                { text = full_text, style = "tags" },
            },
        }
        widget:paintTo({
            paintRect = function() end,
            paintBorder = function() end,
        }, 0, 0)

        local tap_zone
        for _i, zone in ipairs(widget.touch_zones) do
            if zone.id == "zen_book_info_tap" then tap_zone = zone end
            assert.is_not.equal("zen_book_info_hold", zone.id)
        end
        assert.is_table(tap_zone)
        assert.are.equal("tap", tap_zone.ges)
        local short = widget._detail_widgets[1]
        assert.is_false(short.truncated)
        assert.is_true(tap_zone.handler({
            pos = { x = widget._L.details_x, y = short.widget.paint_y },
        }))
        assert.is_nil(full_text_message)

        local truncated = widget._detail_widgets[2]
        assert.is_true(truncated.truncated)
        assert.is_true(tap_zone.handler({
            pos = { x = truncated.dimen.x, y = truncated.dimen.y },
        }))
        assert.are.equal(full_text, full_text_message.text)
        assert.are.equal(truncated.dimen, full_text_message.anchor)
    end)

    it("reserves half the screen without dropping page number or progress", function()
        local details = { { text = "Page 128 of 300", style = "page" } }
        for index = 1, 12 do
            details[#details + 1] = { text = "Metadata " .. index, style = "secondary" }
        end
        local widget = BookInfoWidget:new{
            cover = {},
            cover_width = 120,
            cover_height = 240,
            description = "Description",
            details = details,
            progress = 0.425,
            progress_pages = 300,
        }

        assert.are.equal(400, widget._L.description_min_h)
        assert.is_true(widget._L.description_h >= 400)
        assert.is_true(widget._L.description_y + widget._L.description_h <= 784)
        assert.are.equal(240, widget._L.cover_h)
        assert.is_true(widget._L.header_h >= widget._L.cover_h)
        assert.is_true(widget._L.header_h <= 281)

        widget:paintTo({
            paintRect = function() end,
            paintBorder = function() end,
        }, 0, 0)
        local page_spec
        for _i, values in ipairs(text_specs) do
            if values.text == "Page 128 of 300" then page_spec = values end
        end
        assert.is_number(page_spec.paint_y)
        assert.is_number(widget._progress_widget.paint_y)
        assert.is_true(widget._progress_widget.paint_y + widget._progress_h
            <= widget._L.description_divider_y)
    end)

    it("renders page and progress in their configured order", function()
        local widget = BookInfoWidget:new{
            cover = {},
            cover_width = 120,
            cover_height = 180,
            description = "Description",
            details = {
                { text = "Title", style = "title", bold = true },
                {
                    style = "progress",
                    progress = 0.425,
                    pages = 300,
                    right_text = "",
                    gap_before = 3,
                },
                { text = "Page 128 of 300", style = "page" },
            },
            text_faces = { secondary = { name = "secondary" } },
        }
        widget:paintTo({
            paintRect = function() end,
            paintBorder = function() end,
        }, 0, 0)

        assert.are.equal(0.425, progress_specs[1].ratio)
        assert.are.equal(300, progress_specs[1].pages)
        assert.are.equal("", progress_specs[1].right_text)
        assert.are.equal("secondary", progress_specs[1].face.name)
        assert.is_nil(widget._progress_widget)
        assert.are.equal(widget._L.body_y, widget._detail_widgets[1].widget.paint_y)
        assert.is_true(widget._detail_widgets[2].widget.paint_y
            > widget._detail_widgets[1].widget.paint_y)
        assert.is_true(widget._detail_widgets[3].widget.paint_y
            > widget._detail_widgets[2].widget.paint_y)
        widget:onClose()
        assert.are.equal(1, progress_frees)
    end)

    it("aligns its title, back icon, and close icon with the header", function()
        local widget = new_widget()
        widget:paintTo({
            paintRect = function() end,
            paintBorder = function() end,
        }, 0, 0)

        local title_spec
        for _i, spec in ipairs(text_specs) do
            if spec.face and spec.face.name == "settings_title" then title_spec = spec end
        end
        assert.are.equal("settings_title", title_spec.face.name)
        assert.are.equal(92, title_spec.paint_x)
        assert.are.equal(28, icon_specs[1].width)
        assert.are.equal(39, icon_specs[1].paint_x)
        assert.are.equal("/icons/close.svg", icon_specs[2].file)
        assert.are.equal(544, icon_specs[2].paint_x)
    end)

    it("shows Edit beside close only when an edit callback is provided", function()
        local edits = 0
        local edited_widget
        local widget = BookInfoWidget:new{
            description = "Description",
            edit_callback = function(current_widget)
                edits = edits + 1
                edited_widget = current_widget
            end,
        }
        widget:paintTo({
            paintRect = function() end,
            paintBorder = function() end,
        }, 0, 0)

        assert.are.equal("edit-icon  Edit", widget._edit_widget.text)
        assert.are.equal("cfont", widget._edit_widget.face.name)
        assert.are.equal(22, widget._edit_widget.face.orig_size)
        assert.is_true(widget._edit_widget.bold)
        assert.are.equal("outlined", zen_button_calls[1].kind)
        assert.are.equal(32, zen_button_calls[1].h)
        assert.are.equal(22, zen_button_calls[1].font_size)
        widget._zen_focus_enabled = true
        widget._zen_focus_area = "edit"
        widget:paintTo({
            paintRect = function() end,
            paintBorder = function() end,
        }, 0, 0)
        assert.are.equal("filled", zen_button_calls[2].kind)
        widget._zen_focus_area = "back"
        widget:paintTo({
            paintRect = function() end,
            paintBorder = function() end,
        }, 0, 0)
        assert.are.equal("outlined", zen_button_calls[3].kind)
        assert.are.equal(widget._L.close_all_x,
            widget._L.edit_x + widget._L.edit_w + widget._L.edit_close_gap)
        assert.is_true(widget:_onTap({
            pos = { x = widget._L.edit_x + 1, y = 10 },
        }))
        assert.are.equal(0, close_calls)
        assert.are.equal(1, edits)
        assert.are.equal(widget, edited_widget)

        local reader_widget = new_widget()
        assert.is_nil(reader_widget._edit_widget)
    end)

    it("closes itself and the page browser from the top-right X", function()
        local parent_closes = 0
        local widget = new_widget(function() parent_closes = parent_closes + 1 end)

        assert.is_true(widget:_onTap({ pos = { x = 550, y = 10 } }))
        assert.are.equal(1, close_calls)
        assert.are.equal(1, parent_closes)
        assert.are.equal(0, top_taps)
    end)

    it("closes from both the back button and title before opening the top menu", function()
        local widget = new_widget()

        assert.is_true(widget:_onTap({ pos = { x = 1, y = 10 } }))
        assert.are.equal(1, close_calls)
        assert.are.equal(0, top_taps)

        assert.is_true(widget:_onTap({
            pos = { x = widget._L.title_x + 1, y = 10 },
        }))
        assert.are.equal(2, close_calls)
        assert.are.equal(0, top_taps)
    end)

    it("opens the KOReader menu from an unoccupied top tap", function()
        local widget = new_widget()

        assert.is_true(widget:_onTap({ pos = { x = 300, y = 10 } }))
        assert.are.equal(1, top_taps)
    end)

    it("opens the KOReader menu from a top south swipe without blocking description scrolling", function()
        local widget = new_widget()

        assert.is_true(widget:_onSwipe({ direction = "south", pos = { x = 300, y = 10 } }))
        assert.are.equal(1, top_swipes)
        assert.are.equal(0, description_swipes)

        assert.is_true(widget:_onSwipe({ direction = "south", pos = { x = 300, y = 400 } }))
        assert.are.equal(1, top_swipes)
        assert.are.equal(1, description_swipes)
    end)

    it("focuses Back, scrolls the description, and handles hardware page turns", function()
        local device = require("device")
        device.hasKeys = function() return true end
        device.hasDPad = function() return true end
        device.hasKeyboard = function() return false end
        device.input = {
            group = { Back = "Back", PgBack = "PgBack", PgFwd = "PgFwd" },
        }
        local widget = new_widget()
        local function key(name)
            return {
                match = function(_self, sequence) return sequence[1] == name end,
            }
        end

        assert.are.equal("back", widget._zen_focus_area)
        assert.are.equal("Back", widget.key_events.Close[1][1])
        assert.are.equal("PgFwd", widget.key_events.BookInfoPageDown[1][1])

        assert.is_true(widget:onKeyPress(key("Right")))
        assert.are.equal("close", widget._zen_focus_area)
        assert.is_true(widget:onKeyPress(key("Left")))
        assert.are.equal("back", widget._zen_focus_area)

        assert.is_true(widget:onKeyPress(key("Down")))
        assert.are.equal("description", widget._zen_focus_area)
        assert.is_true(widget:onKeyPress(key("Down")))
        assert.are.equal(1, description_line_scroll)
        assert.is_true(widget:onKeyPress(key("Up")))
        assert.are.equal(0, description_line_scroll)
        assert.are.equal("description", widget._zen_focus_area)

        assert.is_true(widget:onBookInfoPage(1))
        assert.is_true(widget:onBookInfoPage(-1))
        assert.are.equal(1, description_page_down)
        assert.are.equal(1, description_page_up)

        assert.is_true(widget:onKeyPress(key("Up")))
        assert.are.equal("back", widget._zen_focus_area)
        assert.is_true(widget:onKeyPress(key("Press")))
        assert.are.equal(1, close_calls)
    end)
end)
