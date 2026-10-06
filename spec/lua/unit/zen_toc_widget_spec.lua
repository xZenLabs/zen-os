describe("Zen TOC hardware focus", function()
    local ZenTocWidget
    local close_calls
    local dirty_calls
    local back_icon
    local close_icon
    local title_spec
    local font_calls
    local text_specs
    local saved_feedback

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
        saved_feedback = package.loaded["common/ui/button_feedback"]
        ZenSpec.replace("common/ui/button_feedback", { flashButton = function() end })
        close_calls = 0
        dirty_calls = 0
        back_icon = nil
        close_icon = nil
        title_spec = nil
        font_calls = {}
        text_specs = {}
        ZenSpec.replace("gettext", function(text)
            if text == "Table of contents" then return "Translated contents" end
            if text == "No table of contents available." then return "Translated empty TOC" end
            return text
        end)
        ZenSpec.replace("device", {
            screen = {
                getWidth = function() return 600 end,
                getHeight = function() return 260 end,
                scaleBySize = function(_self, value) return value end,
            },
            hasKeys = function() return true end,
            hasDPad = function() return true end,
            hasKeyboard = function() return false end,
            input = {
                group = { Back = "Back", PgBack = "PgBack", PgFwd = "PgFwd" },
            },
        })
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_BLACK = "black",
            COLOR_DARK_GRAY = "dark_gray",
            COLOR_LIGHT_GRAY = "light_gray",
            COLOR_WHITE = "white",
            gray = function(value) return value end,
        })
        ZenSpec.replace("ui/font", {
            getFace = function(_, name, size, index)
                table.insert(font_calls, { name = name, size = size, index = index })
                return { name = name, size = size, index = index }
            end,
        })
        ZenSpec.replace("document/credocument", {})
        ZenSpec.unload("ui/geometry")
        ZenSpec.replace("ui/widget/container/inputcontainer", input_container())
        ZenSpec.replace("datastorage", { getDataDir = function() return "/koreader" end })
        ZenSpec.replace("common/utils", {
            resolveLocalIcon = function(_, name) return "/icons/" .. name .. ".svg" end,
        })
        ZenSpec.replace("ui/widget/iconwidget", {
            new = function(_self, values)
                if values.file == "/icons/chevron.left.svg" then back_icon = values end
                if values.file == "/icons/close.svg" then close_icon = values end
                values.paintTo = function(self, _bb, x)
                    self.paint_x = x
                end
                values.free = function() end
                return values
            end,
        })
        ZenSpec.replace("ui/widget/textwidget", {
            new = function(_self, values)
                table.insert(text_specs, values)
                if values.text == "Translated contents" then title_spec = values end
                values.getSize = function() return { w = 80, h = 20 } end
                values.paintTo = function(self, _bb, x)
                    self.paint_x = x
                end
                values.free = function() end
                return values
            end,
        })
        ZenSpec.replace("ui/uimanager", {
            close = function() close_calls = close_calls + 1 end,
            setDirty = function() dirty_calls = dirty_calls + 1 end,
        })
        ZenSpec.replace("common/ui/zen_pager", {
            PN_FOOTER_H = 40,
            FOOTER_H = 20,
            CHEV_W = 50,
            CHEV_HIT_W = 80,
            flashChevron = function() end,
            getStyle = function() return "page_number" end,
            getCenteredFooterY = function(_list_bottom, footer_top) return footer_top end,
            getHoldSkip = function() return 10 end,
            getPageNumberZone = function(x, y, footer_x, footer_y, footer_w, footer_h, available_bottom)
                local hit_bottom = math.min(footer_y + footer_h + 24, available_bottom)
                if x < footer_x or x >= footer_x + footer_w
                        or y < footer_y or y >= hit_bottom then
                    return nil
                end
                if x < footer_x + 80 then return "left" end
                if x >= footer_x + footer_w - 80 then return "right" end
                if y < footer_y + footer_h then return "center" end
            end,
            paint = function() end,
            setPlugin = function() end,
        })
        ZenSpec.replace("common/ui/zen_title_style", {
            ICON_SIZE = 28,
            BUTTON_SIZE = 44,
            BUTTON_PADDING = 8,
            LEFT_PADDING = 4,
            RIGHT_PADDING = 20,
            ROW_HEIGHT = 44,
            VERTICAL_PADDING = 6,
            DIVIDER_HEIGHT = 2,
            DIVIDER_COLOR = "light_gray",
            HEADER_CONTENT_HEIGHT = 56,
            HEADER_HEIGHT = 58,
            getTitleFace = function() return { name = "settings_title" } end,
            getLeadingIconX = function(origin) return (origin or 0) + 12 end,
            getTitleX = function(origin) return (origin or 0) + 54 end,
            getTrailingIconX = function(width, origin)
                return (origin or 0) + width - 20 - 8 - 28
            end,
        })
        ZenSpec.replace("modules/filebrowser/patches/library_font", {
            getFace = function(size)
                return require("ui/font"):getFace("LibraryFont", size)
            end,
        })
        ZenSpec.unload("common/reader_font")
        ZenSpec.unload("modules/reader/zen_toc_widget")
        ZenTocWidget = require("modules/reader/zen_toc_widget")
    end)

    after_each(function()
        package.loaded["common/ui/button_feedback"] = saved_feedback
        ZenSpec.unload("modules/reader/zen_toc_widget")
        ZenSpec.unload("modules/filebrowser/patches/library_font")
        ZenSpec.unload("common/reader_font")
        ZenSpec.unload("datastorage")
        ZenSpec.unload("common/utils")
    end)

    local function new_widget(on_goto, close_all_callback)
        local toc = {}
        for i = 1, 8 do
            toc[i] = { title = "Section " .. i, page = i * 10, depth = 1 }
        end
        return ZenTocWidget:new{
            ui = {
                toc = { toc = toc },
                font = { font_face = "ReaderFont" },
                document = { configurable = { font_size = 21 } },
            },
            focus_page = 1,
            on_goto = on_goto,
            close_all_callback = close_all_callback,
        }
    end

    local function key(name)
        return {
            match = function(_self, sequence) return sequence[1] == name end,
        }
    end

    it("moves from Back through every visible section and footer button", function()
        local widget = new_widget()
        assert.are.equal("back", widget._zen_focus_area)
        assert.are.equal("Back", widget.key_events.Close[1][1])
        assert.are.equal("PgFwd", widget.key_events.TocPageDown[1][1])

        assert.is_true(widget:onKeyPress(key("Right")))
        assert.are.equal("close", widget._zen_focus_area)
        assert.is_true(widget:onKeyPress(key("Left")))
        assert.are.equal("back", widget._zen_focus_area)

        assert.is_true(widget:onKeyPress(key("Down")))
        assert.are.equal("entry", widget._zen_focus_area)
        local first = widget._zen_focus_entry_idx
        assert.is_true(widget:onKeyPress(key("Down")))
        assert.are.equal(first + 1, widget._zen_focus_entry_idx)
        assert.is_true(widget:onKeyPress(key("Down")))
        assert.are.equal(first + 2, widget._zen_focus_entry_idx)
        assert.is_true(widget:onKeyPress(key("Down")))
        assert.are.equal("footer", widget._zen_focus_area)
        assert.are.equal("left", widget._zen_footer_side)

        assert.is_true(widget:onKeyPress(key("Right")))
        assert.are.equal("right", widget._zen_footer_side)
        assert.is_true(widget:onKeyPress(key("Press")))
        assert.are.equal(2, widget._toc_page)
        assert.is_true(widget:onKeyPress(key("Up")))
        assert.are.equal("entry", widget._zen_focus_area)
    end)

    it("opens a focused section and pages with hardware page-turn events", function()
        local selected_page
        local widget = new_widget(function(page) selected_page = page end)

        assert.is_true(widget:onTocPage(1))
        assert.are.equal(2, widget._toc_page)
        assert.is_true(widget:onKeyPress(key("Down")))
        assert.are.equal("entry", widget._zen_focus_area)
        local entry = widget._entries[widget._zen_focus_entry_idx]
        assert.is_true(widget:onKeyPress(key("Return")))
        assert.are.equal(entry.page, selected_page)
        assert.are.equal(1, close_calls)
        assert.is_true(dirty_calls > 0)
    end)

    it("aligns its title, back icon, and close icon with the header", function()
        local widget = new_widget()
        widget:paintTo({ paintRect = function() end }, 0, 0)

        assert.are.equal("settings_title", title_spec.face.name)
        assert.are.equal(54, title_spec.paint_x)
        assert.are.equal(28, back_icon.width)
        assert.are.equal(12, back_icon.paint_x)
        assert.are.equal(28, close_icon.width)
        assert.are.equal(544, close_icon.paint_x)
    end)

    it("treats a tap on the title text as Back", function()
        local parent_closes = 0
        local widget = new_widget(nil, function() parent_closes = parent_closes + 1 end)
        widget:paintTo({ paintRect = function() end }, 0, 0)
        local hit = widget._title_hit

        assert.is_true(widget:_onTap({
            pos = { x = hit.x + 1, y = hit.y + 1 },
        }))
        assert.are.equal(1, close_calls)
        assert.are.equal(0, parent_closes)
    end)

    it("localizes the title and empty state", function()
        local widget = ZenTocWidget:new{
            ui = {
                toc = { toc = {} },
                font = { font_face = "ReaderFont" },
                document = { configurable = { font_size = 21 } },
            },
        }
        widget:paintTo({ paintRect = function() end }, 0, 0)

        assert.are.equal("Translated contents", title_spec.text)
        local found_empty
        for _i, spec in ipairs(text_specs) do
            if spec.text == "Translated empty TOC" then found_empty = true end
        end
        assert.is_true(found_empty)
    end)

    it("replaces PDF placeholder titles with KOReader's resolved chapter title", function()
        local toc = {
            toc = {
                { title = "---", page = 5, depth = 1 },
                { title = "", page = 10, depth = 1 },
                { title = "Chapter ten", page = 10, depth = 2 },
            },
            getTocTitleByPage = function(_self, page)
                if page == 5 then return "Resolved chapter" end
                return ""
            end,
        }
        local widget = ZenTocWidget:new{
            ui = {
                toc = toc,
                font = { font_face = "ReaderFont" },
                document = { configurable = { font_size = 21 } },
            },
        }

        assert.are.equal(2, #widget._entries)
        assert.are.equal("Resolved chapter", widget._entries[1].title)
        assert.are.equal("Chapter ten", widget._entries[2].title)
    end)

    it("closes itself and the page browser from the top-right X", function()
        local parent_closes = 0
        local widget = new_widget(nil, function() parent_closes = parent_closes + 1 end)

        assert.is_true(widget:_onTap({ pos = { x = 550, y = 10 } }))
        assert.are.equal(1, close_calls)
        assert.are.equal(1, parent_closes)
    end)

    it("uses the library face and size for TOC entries", function()
        local widget = new_widget()
        widget:paintTo({ paintRect = function() end }, 0, 0)

        assert.same({ name = "LibraryFont", size = 21, index = nil }, font_calls[1])
    end)

    it("uses the configured TOC font size", function()
        ZenTocWidget:new{
            font_size = 26,
            ui = {
                toc = { toc = {} },
                document = { configurable = { font_size = 21 } },
            },
        }

        assert.same({ name = "LibraryFont", size = 26, index = nil }, font_calls[1])
    end)

    it("uses the active PDF reader font size for TOC text", function()
        ZenTocWidget:new{
            ui = {
                toc = { toc = {} },
                document = {
                    configurable = { font_size = 1 },
                    reflowable_font_size = 30,
                },
            },
        }

        assert.same({ name = "LibraryFont", size = 30, index = nil }, font_calls[1])
    end)

    it("converts the PDF scale when its active reader font size is unavailable", function()
        ZenTocWidget:new{
            ui = {
                toc = { toc = {} },
                document = {
                    configurable = { font_size = 1 },
                    convertKoptToReflowableFontSize = function(_self, scale)
                        return scale * 22
                    end,
                },
            },
        }

        assert.same({ name = "LibraryFont", size = 22, index = nil }, font_calls[1])
    end)
end)
