describe("Zen TOC hardware focus", function()
    local ZenTocWidget
    local close_calls
    local close_request
    local dirty_calls
    local back_icon
    local close_icon
    local fold_icons
    local title_spec
    local font_calls
    local text_specs
    local saved_feedback
    local feedback_region

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
        feedback_region = nil
        ZenSpec.replace("common/ui/button_feedback", {
            flashButton = function(region) feedback_region = region end,
            paddedRegion = function(region)
                return require("ui/geometry"):new{
                    x = region.x - 4, y = region.y - 4, w = region.w + 8, h = region.h + 8,
                }
            end,
        })
        close_calls = 0
        close_request = nil
        dirty_calls = 0
        back_icon = nil
        close_icon = nil
        fold_icons = {}
        title_spec = nil
        font_calls = {}
        text_specs = {}
        ZenSpec.replace("gettext", function(text)
            if text == "Chapters" then return "Translated contents" end
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
            COLOR_GRAY_5 = "gray_5",
            COLOR_LIGHT_GRAY = "light_gray",
            COLOR_WHITE = "white",
            gray = function(value) return value end,
            isColor8 = function() return true end,
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
            resolveIcon = function(_, name) return "/active-icons/" .. name .. ".svg" end,
        })
        ZenSpec.replace("ui/widget/iconwidget", {
            new = function(_self, values)
                if values.file:match("/chevron.left.svg$") then back_icon = values end
                if values.file:match("/close.svg$") then close_icon = values end
                if values.file:match("/control%.") then table.insert(fold_icons, values) end
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
            close = function(_self, widget, mode, region)
                close_calls = close_calls + 1
                close_request = { widget = widget, mode = mode, region = region }
            end,
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

    local function new_widget(on_goto, close_all_callback, show_back)
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
            show_back = show_back,
            on_goto = on_goto,
            close_all_callback = close_all_callback,
        }
    end

    local function fake_bb(calls)
        local bb = {}
        for _i, name in ipairs({ "paintRect", "invertRect", "paintBorder", "paintRoundedRect" }) do
            bb[name] = function(_bb, ...)
                if calls then table.insert(calls, { name, ... }) end
            end
        end
        return bb
    end

    local function key(name)
        return {
            match = function(_self, sequence) return sequence[1] == name end,
        }
    end

    it("moves from Back through every visible section and footer button", function()
        local widget = new_widget(nil, nil, true)
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

    it("centers its title and aligns its back and close icons with the header", function()
        local widget = new_widget(nil, nil, true)
        widget:paintTo(fake_bb(), 0, 0)

        assert.are.equal("settings_title", title_spec.face.name)
        assert.are.equal(260, title_spec.paint_x)
        assert.are.equal(28, back_icon.width)
        assert.are.equal(12, back_icon.paint_x)
        assert.are.equal(28, close_icon.width)
        assert.are.equal(544, close_icon.paint_x)
    end)

    it("uses the active titlebar icons and standard close feedback bounds", function()
        local widget = new_widget(nil, nil, false)
        local focus_backgrounds = 0
        local bb = fake_bb()
        bb.paintRect = function(_bb, _x, _y, _w, _h, color)
            if color == "black" then focus_backgrounds = focus_backgrounds + 1 end
        end
        widget:paintTo(bb, 0, 0)

        assert.are.equal("/active-icons/close.svg", close_icon.file)
        assert.are.equal(28, close_icon.width)
        assert.is_true(close_icon.invert)
        assert.are.equal(0, focus_backgrounds)
        assert.is_true(widget:_onTap{ pos = { x = 560, y = 20 } })
        assert.are.same({ x = 540, y = 10, w = 36, h = 36 }, feedback_region)
    end)

    it("hides Back and skips its focus and touch target in a standalone TOC", function()
        local widget = new_widget()
        assert.are.equal("close", widget._zen_focus_area)
        widget:paintTo(fake_bb(), 0, 0)
        assert.is_nil(back_icon)
        assert.is_not_nil(close_icon)
        widget:_moveFocus(0, 1)
        assert.are.equal("entry", widget._zen_focus_area)
        widget:_moveFocus(0, -1)
        assert.are.equal("close", widget._zen_focus_area)
        widget:_onTap({ pos = { x = widget._L.back_x + 1, y = widget._L.back_y + 1 } })
        assert.are.equal(0, close_calls)
    end)

    it("treats a tap on the title text as Back", function()
        local parent_closes = 0
        local widget = new_widget(nil, function() parent_closes = parent_closes + 1 end)
        widget:paintTo(fake_bb(), 0, 0)
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
        widget:paintTo(fake_bb(), 0, 0)

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

    it("opens on the reader's current chapter page and marks it active", function()
        local toc = {}
        for i = 1, 20 do toc[i] = { title = "Section " .. i, page = i * 10, depth = 1 } end
        local widget = ZenTocWidget:new{
            ui = {
                toc = { toc = toc },
                font = { font_face = "ReaderFont" },
                document = { configurable = { font_size = 21 } },
                getCurrentPage = function() return 175 end,
            },
        }
        assert.are.equal(17, widget._active_entry_idx)
        local first, last = widget:_visibleEntryBounds()
        assert.is_true(first <= 17 and 17 <= last)
        assert.is_true(widget._toc_page > 1)
    end)

    it("marks no chapter when the reader is before the first entry", function()
        assert.is_nil(ZenTocWidget.getCurrentIndex({ { page = 10 }, { page = 20 } }, 3))
        assert.are.equal(2, ZenTocWidget.getCurrentIndex({ { page = 10 }, { page = 20 } }, 20))
    end)

    it("shares normalized TOC entries with embedded panels after loading the contents", function()
        local toc = {
            fillToc = function(self)
                self.toc = {
                    { title = " First \xE2\x80\x8Bchapter ", page = 1, depth = 2 },
                    { title = "Second title", page = 1, depth = 1 },
                    { title = "Deep", page = 2, depth = 4 },
                }
            end,
        }
        local entries = ZenTocWidget.getEntries({ toc = toc })
        assert.are.equal(2, #entries)
        assert.is_true(entries.nested)
        local first = entries[1]
        assert.are.same({ idx = 1, title = "First chapter · Second title", page = 1, page_label = "1", depth = 1,
            has_children = true }, first)
        assert.are.same({ idx = 2, title = "Deep", page = 2, page_label = "2", depth = 4, parent = first }, entries[2])
    end)

    it("keeps a deeper same-page heading as a subheading and merges its same-page siblings", function()
        local entries = ZenTocWidget.getEntries({ toc = { toc = {
            { title = "Prologue", page = 2, depth = 1 },
            { title = "1: Prologue", page = 2, depth = 2 },
            { title = "Arc", page = 4, depth = 1 },
            { title = "Arc", page = 4, depth = 2 },
            { title = "2: Arc", page = 4, depth = 2 },
            { title = "3: Short", page = 4, depth = 2 },
        } } })
        local titles = {}
        for i, e in ipairs(entries) do titles[i] = e.title end
        assert.are.same({ "Prologue", "1: Prologue", "Arc", "2: Arc · 3: Short" }, titles)
        assert.are.same({ entries[1], entries[3] }, { entries[2].parent, entries[4].parent })
        assert.are.equal(2, ZenTocWidget.getCurrentIndex(entries, 2))
    end)

    it("counts chapter pages in page-map labels when the reader shows them", function()
        local labels = { a = "iv", b = "12", c = "30" }
        local indexes = { iv = 4, ["12"] = 12, ["30"] = 30 }
        local entries = ZenTocWidget.getEntries({
            toc = { toc = {
                { title = "Front", page = 1, depth = 1, xpointer = "a" },
                { title = "One", page = 20, depth = 1, xpointer = "b" },
                { title = "Two", page = 50, depth = 1, xpointer = "c" },
                { title = "Unmapped", page = 70, depth = 1 },
            } },
            pagemap = {
                wantsPageLabels = function() return true end,
                getXPointerPageLabel = function(_self, xp, clean) return clean and labels[xp]:upper() or labels[xp] end,
                getPageLabelProps = function(_self, label)
                    if label == nil then return 60 end
                    return indexes[label:lower()], 999
                end,
            },
        })
        assert.are.same({ "iv", "12", "30", "70" }, { entries[1].page_label, entries[2].page_label,
            entries[3].page_label, entries[4].page_label })
        -- Count beside a page-map label is in book pages; chapters without a label get no count.
        assert.are.same({ 8, 18 }, { entries[1].page_count, entries[2].page_count })
        assert.is_nil(entries[3].page_count)
        assert.is_nil(entries[4].page_count)
    end)

    it("closes itself and the page browser from the top-right X", function()
        local parent_closes = 0
        local widget = new_widget(nil, function() parent_closes = parent_closes + 1 end)

        assert.is_true(widget:_onTap({ pos = { x = 550, y = 10 } }))
        assert.are.equal(1, close_calls)
        assert.are.equal(1, parent_closes)
    end)

    it("refreshes the whole screen when Back or X dismisses a standalone TOC", function()
        for _i, x in ipairs({ 20, 550 }) do
            local widget = new_widget(function() error("dismissal must not navigate") end, nil, true)

            assert.is_true(widget:_onTap({ pos = { x = x, y = 10 } }))
            assert.are.equal(widget, close_request.widget)
            assert.are.equal("ui", close_request.mode)
            assert.are.same({ x = 0, y = 0, w = 600, h = 260 }, close_request.region)
        end
        assert.are.equal(2, close_calls)
    end)

    it("uses the library face and size for TOC entries", function()
        local widget = new_widget()
        widget:paintTo(fake_bb(), 0, 0)

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

    local function reading_widget(current_page, stats)
        local toc = {}
        for i = 1, 8 do toc[i] = { title = "Section " .. i, page = i * 10, depth = 1 } end
        return ZenTocWidget:new{
            ui = {
                toc = { toc = toc },
                document = { configurable = { font_size = 21 }, getPageCount = function() return 95 end },
                getCurrentPage = function() return current_page end,
                statistics = stats,
            },
        }
    end

    it("outlines the current chapter with its page progress and reading time left", function()
        local widget = reading_widget(25, { settings = { is_enabled = true }, avg_time = 60 })
        assert.are.same({ done = 6, total = 10, time = "4 min left" }, widget._progress)
        assert.are.same({ 1, 2 }, { widget:_visibleEntryBounds() })

        local calls, counts, texts = {}, {}, {}
        widget:paintTo(fake_bb(calls), 0, 0)
        for _i, call in ipairs(calls) do counts[call[1]] = (counts[call[1]] or 0) + 1 end
        for _i, spec in ipairs(text_specs) do texts[spec.text] = spec end
        assert.is_true(texts["Section 2"].bold)
        assert.is_not_nil(texts["Page 6 of 10"])
        assert.is_not_nil(texts["4 min left"])
        assert.are.equal("gray_5", texts["Section 1"].fgcolor)
        assert.are.equal("black", texts["Page 6 of 10"].fgcolor)
        assert.are.equal("black", texts["4 min left"].fgcolor)
        -- Card and bar track are outlined; read dot and bar fill are solid.
        assert.are.equal(2, counts.paintBorder)
        assert.are.equal(2, counts.paintRoundedRect)
    end)

    it("rings unread chapters when the reader is before the first entry", function()
        local calls, rings = {}, 0
        new_widget():paintTo(fake_bb(calls), 0, 0)
        for _i, call in ipairs(calls) do
            assert.are_not.equal("paintRoundedRect", call[1])
            if call[1] == "paintBorder" then
                rings = rings + 1
                assert.are.equal("black", call[7])
            end
        end
        assert.are.equal(3, rings)
    end)

    it("hit-tests rows by their painted heights", function()
        local selected
        local widget = reading_widget(25)
        widget.on_goto = function(page) selected = page end
        local card_bottom = widget._L.list_y + widget._style.row_h + widget._style.current_h
        assert.is_true(widget:_onTap({ pos = { x = 300, y = card_bottom - 1 } }))
        assert.are.equal(20, selected)
    end)

    it("measures the last chapter to the end of the book and skips time without statistics", function()
        local ui = { document = { getPageCount = function() return 95 end } }
        assert.are.same({ done = 6, total = 16 },
            ZenTocWidget.getChapterProgress(ui, { { page = 10 }, { page = 80 } }, 2, 85))
    end)

    local function nested_widget(current_page, show_page_counts)
        return ZenTocWidget:new{
            ui = {
                toc = { toc = {
                    { title = "Part 1", page = 1, depth = 1 },
                    { title = "Chapter 1", page = 10, depth = 2 },
                    { title = "Chapter 2", page = 20, depth = 2 },
                    { title = "Part 2", page = 30, depth = 1 },
                    { title = "Chapter 3", page = 40, depth = 2 },
                    { title = "Chapter 4", page = 50, depth = 2 },
                } },
                document = { configurable = { font_size = 21 }, getPageCount = function() return 95 end },
                getCurrentPage = function() return current_page end,
            },
            show_page_counts = show_page_counts,
        }
    end

    local function visible_titles(widget)
        local titles = {}
        for i, entry in ipairs(widget._entries) do titles[i] = entry.title end
        return titles
    end

    it("shows top-level chapters plus the subchapters of the one being read", function()
        local widget = nested_widget(45)
        assert.are.same({ "Part 1", "Part 2", "Chapter 3", "Chapter 4" }, visible_titles(widget))
        assert.are.equal(3, widget._active_entry_idx)
        assert.are.same({ done = 6, total = 10 }, widget._progress)
        local counts = {}
        for i, entry in ipairs(widget._all) do counts[i] = entry.page_count end
        assert.are.same({ 29, 10, 10, 66, 10, 46 }, counts)
        assert.are.equal(widget._all[4], widget._all[5].parent)

        widget:paintTo(fake_bb(), 0, 0)
        -- Page 2 holds the current card and Chapter 4: leaves keep the column but draw no arrow.
        assert.are.equal(2, widget._toc_page)
        assert.are.same({}, fold_icons)
        widget:_gotoTocPage(1)
        widget:paintTo(fake_bb(), 0, 0)
        -- Part 2 holds the current chapter, so it starts unfolded; both parts are read, so arrows are dimmed.
        assert.are.same({ "/active-icons/control.expand.svg", "/active-icons/control.collapse.svg" },
            { fold_icons[1].file, fold_icons[2].file })
        assert.are.equal(14, fold_icons[1].width)
        assert.is_true(fold_icons[1].dim)
        assert.is_true(fold_icons[2].dim)

        fold_icons = {}
        nested_widget(5):paintTo(fake_bb(), 0, 0)
        assert.are.same({ "/active-icons/control.expand.svg", "/active-icons/control.expand.svg" },
            { fold_icons[1].file, fold_icons[2].file })
        assert.is_falsy(fold_icons[1].dim) -- current
        assert.is_falsy(fold_icons[2].dim) -- unread
    end)

    it("folds from the arrow column or D-pad and keeps the toggled row on screen", function()
        local selected
        local widget = nested_widget(45)
        widget.on_goto = function(page) selected = page end
        widget:_gotoTocPage(1)
        local L, style = widget._L, widget._style
        local hit = ZenTocWidget.foldHitWidth(style, widget:_row(1, 1))
        assert.are.equal(20 + 14 + 10 + 9 + 12, hit)

        assert.is_true(widget:_onTap({ pos = { x = hit - 1, y = L.list_y + 5 } }))
        assert.are.same({ "Part 1", "Chapter 1", "Chapter 2", "Part 2", "Chapter 3", "Chapter 4" },
            visible_titles(widget))
        assert.are.equal(1, widget._toc_page)
        assert.are.equal(0, close_calls)
        assert.is_nil(selected)
        fold_icons = {}
        widget:paintTo(fake_bb(), 0, 0)
        assert.are.equal("/active-icons/control.collapse.svg", fold_icons[1].file)
        assert.are.equal(1, #fold_icons)

        -- Tapping a leaf's dot area navigates; tapping a parent's title navigates too.
        assert.is_true(widget:_onTap({ pos = { x = hit - 1, y = L.list_y + style.row_h + 5 } }))
        assert.are.equal(10, selected)
        assert.is_true(widget:_onTap({ pos = { x = hit + 1, y = L.list_y + 5 } }))
        assert.are.equal(1, selected)

        widget:_setFocus("entry", 1)
        assert.is_true(widget:onKeyPress(key("Left")))
        assert.are.same({ "Part 1", "Part 2", "Chapter 3", "Chapter 4" }, visible_titles(widget))
        assert.are.equal(1, widget._zen_focus_entry_idx)
        assert.is_true(widget:onKeyPress(key("Left")))
        assert.are.equal(4, #widget._entries)
        assert.is_true(widget:onKeyPress(key("Right")))
        assert.are.equal(6, #widget._entries)
        assert.are.equal("entry", widget._zen_focus_area)

        -- Folding the chapter being read marks its parent as current.
        widget:_setFocus("entry", 4)
        assert.is_true(widget:onKeyPress(key("Left")))
        assert.are.same({ "Part 1", "Chapter 1", "Chapter 2", "Part 2" }, visible_titles(widget))
        assert.are.equal(4, widget._active_entry_idx)
        assert.are.same({ done = 16, total = 66 }, widget._progress)
    end)

    it("appends chapter page counts to titles only when enabled", function()
        local widget = nested_widget(45, true)
        widget:paintTo(fake_bb(), 0, 0)
        local texts = {}
        for _i, spec in ipairs(text_specs) do texts[spec.text] = spec end
        assert.is_true(texts["Chapter 3"].bold)
        assert.is_falsy(texts["(10)"].bold)
        assert.is_not_nil(texts["(46)"])
        assert.are.equal(texts["Chapter 4"].fgcolor, texts["(46)"].fgcolor)
        assert.is_true(texts["(46)"].max_width == nil)

        text_specs = {}
        nested_widget(45):paintTo(fake_bb(), 0, 0)
        for _i, spec in ipairs(text_specs) do assert.is_nil(spec.text:match("^%(%d+%)$")) end
    end)
end)
