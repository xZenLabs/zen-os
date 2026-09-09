describe("home basic widgets", function()
    local created
    local date_stub

    local function geom_new(_, values)
        values = values or {}
        function values:contains(pos)
            return pos.x >= (self.x or 0) and pos.x < (self.x or 0) + (self.w or 0)
                and pos.y >= (self.y or 0) and pos.y < (self.y or 0) + (self.h or 0)
        end
        return values
    end

    local function widget_class(kind)
        return {
            new = function(_, values)
                values = values or {}
                values.kind = kind
                values.dimen = values.dimen or {
                    x = 0,
                    y = 0,
                    w = values.width or (type(values.text) == "string" and #values.text * 6 or 20),
                    h = values.height or (kind == "ui/widget/textboxwidget"
                        and type(values.text) == "string"
                        and (select(2, values.text:gsub("\n", "")) + 1) * 12 or 12),
                }
                values.getSize = values.getSize or function(self) return self.dimen end
                values.paintTo = values.paintTo or function(self, _bb, x, y)
                    self.painted = (self.painted or 0) + 1
                    self.paint_x, self.paint_y = x, y
                end
                values.free = values.free or function(self) self.freed = true end
                created[#created + 1] = values
                return values
            end,
        }
    end

    local function setup_widget_dependencies()
        created = {}
        ZenSpec.replace("common/ui/background", { tile_bg = function(color) return color end })
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_BLACK = "black",
            COLOR_DARK_GRAY = "darkgray",
            COLOR_GRAY_3 = "gray",
            COLOR_WHITE = "white",
        })
        ZenSpec.replace("device", {
            screen = {
                scaleBySize = function(_, value) return value end,
                getWidth = function() return 800 end,
                getHeight = function() return 600 end,
            },
        })
        ZenSpec.replace("ui/font", {
            getFace = function(_, name, size) return { name = name, size = size } end,
        })
        ZenSpec.replace("ui/geometry", { new = geom_new })
        for _i, name in ipairs({
            "ui/widget/container/framecontainer",
            "ui/widget/container/inputcontainer",
            "ui/widget/container/centercontainer",
            "ui/widget/horizontalgroup",
            "ui/widget/horizontalspan",
            "ui/widget/iconwidget",
            "ui/widget/linewidget",
            "ui/widget/textboxwidget",
            "ui/widget/textwidget",
        }) do
            ZenSpec.replace(name, widget_class(name))
        end
        ZenSpec.replace("common/utils", { resolveLocalIcon = function() return nil end })
        ZenSpec.replace("modules/filebrowser/patches/library_font", {
            getFontName = function() return "smallinfofont" end,
        })
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/gesturerange", widget_class("gesture"))
        ZenSpec.unload("common/widget_resources")
        ZenSpec.unload("common/date_format")
    end

    local function texts()
        local result = {}
        for _i, widget in ipairs(created) do
            if type(widget.text) == "string" then result[#result + 1] = widget.text end
        end
        return result
    end

    local function has_text(expected)
        for _i, value in ipairs(texts()) do
            if value == expected then return true end
        end
        return false
    end

    before_each(function()
        setup_widget_dependencies()
        _G.G_reader_settings = ZenSpec.memorySettings()
    end)

    after_each(function()
        if date_stub then date_stub:revert() end
        date_stub = nil
    end)

    it("renders a 24-hour clock and English long date and registers refresh", function()
        _G.G_reader_settings = ZenSpec.memorySettings({ language = "en_US" })
        date_stub = stub(os, "date")
        date_stub.on_call_with("%H:%M").returns("21:07")
        date_stub.on_call_with("*t").returns({ wday = 2, year = 2026, month = 1, day = 8 })
        date_stub.on_call_with("%B").returns("January")
        date_stub.on_call_with("%A").returns("Monday")
        ZenSpec.replace("datetime", {
            weekDays = { [2] = "Mon" },
            shortDayOfWeekToLongTranslation = { Mon = "Monday" },
            longMonthTranslation = { January = "January" },
        })
        ZenSpec.unload("modules/filebrowser/patches/home/widgets/datetime")
        local refresh
        local component = require("modules/filebrowser/patches/home/widgets/datetime")
        local widget = component.build({
            width = 500,
            height = 120,
            is_first_row = true,
            registerClockRefresh = function(callback) refresh = callback end,
        })

        assert.are.equal("datetime", component.id)
        assert.are.equal("sm", component.size)
        assert.are.equal(27, component.preferredHeight({ width = 500 }))
        assert.is_table(widget)
        assert.is_function(refresh)
        assert.is_true(refresh())
        assert.is_true(has_text("21:07"))
        assert.is_true(has_text("Monday, January 8"))
        local clock_size, date_size
        for _i, child in ipairs(created) do
            if child.text == "21:07" then
                clock_size = child.face.size
            elseif child.text == "Monday, January 8" then
                date_size = child.face.size
            end
        end
        assert.are.equal(36, clock_size)
        assert.are.equal(12, date_size)
    end)

    it("honors the twelve-hour clock setting and removes its leading zero", function()
        _G.G_reader_settings = ZenSpec.memorySettings({ twelve_hour_clock = true })
        date_stub = stub(os, "date")
        date_stub.on_call_with("%I:%M").returns("09:05")
        date_stub.on_call_with("*t").returns({ wday = 2, year = 2026, month = 1, day = 8 })
        date_stub.on_call_with("%B").returns("January")
        date_stub.on_call_with("%A").returns("Monday")
        ZenSpec.replace("datetime", {
            weekDays = { [2] = "Mon" },
            shortDayOfWeekToLongTranslation = { Mon = "Monday" },
            longMonthTranslation = { January = "January" },
        })
        ZenSpec.unload("modules/filebrowser/patches/home/widgets/datetime")
        require("modules/filebrowser/patches/home/widgets/datetime").build({
            width = 300, height = 60, is_first_row = false,
            module_cfg = { max_font_size = 52 },
        })

        assert.is_true(has_text("9:05"))
        local clock_size
        for _i, child in ipairs(created) do
            if child.text == "9:05" then
                clock_size = child.face.size
            end
        end
        assert.are.equal(52, clock_size)
    end)

    it("uses translated day-first grammar for Spanish dates", function()
        _G.G_reader_settings = ZenSpec.memorySettings({ language = "es" })
        ZenSpec.replace("gettext", function(text)
            if text == "%1, %2 %3" then return "%1, %3 de %2" end
            return text
        end)
        date_stub = stub(os, "date")
        date_stub.on_call_with("%H:%M").returns("21:07")
        date_stub.on_call_with("*t").returns({ wday = 6, year = 2026, month = 8, day = 15 })
        date_stub.on_call_with("%B").returns("August")
        date_stub.on_call_with("%A").returns("Friday")
        ZenSpec.replace("datetime", {
            weekDays = { [6] = "Fri" },
            shortDayOfWeekToLongTranslation = { Fri = "Viernes" },
            longMonthTranslation = { August = "Agosto" },
        })

        ZenSpec.unload("modules/filebrowser/patches/home/widgets/datetime")
        require("modules/filebrowser/patches/home/widgets/datetime").build({
            width = 300, height = 60,
        })
        assert.is_true(has_text("Viernes, 15 de agosto"))
    end)

    it("applies separate Date/time font faces and sizes", function()
        date_stub = stub(os, "date")
        date_stub.on_call_with("%H:%M").returns("21:07")
        date_stub.on_call_with("*t").returns({ wday = 2, year = 2026, month = 1, day = 8 })
        date_stub.on_call_with("%B").returns("January")
        ZenSpec.replace("datetime", {
            weekDays = { [2] = "Mon" },
            shortDayOfWeekToLongTranslation = { Mon = "Monday" },
            longMonthTranslation = { January = "January" },
        })
        ZenSpec.unload("modules/filebrowser/patches/home/widgets/datetime")
        require("modules/filebrowser/patches/home/widgets/datetime").build({
            width = 500,
            height = 120,
            module_cfg = {
                automatic_font_size = false,
                text_styles = {
                    time = { font_face = "TimeFace.ttf", font_size = 52 },
                    date = { font_face = "DateFace.ttf", font_size = 17 },
                },
            },
        })

        local time_face, date_face, rendered_date
        for _i, child in ipairs(created) do
            if child.text == "21:07" then time_face = child.face end
            if child.face and child.face.name == "DateFace.ttf" then
                date_face = child.face
                rendered_date = child.text
            end
        end
        assert.are.same({ name = "TimeFace.ttf", size = 52 }, time_face)
        assert.are.same({ name = "DateFace.ttf", size = 17 }, date_face)
        assert.are.equal("Monday, January 8", rendered_date)
    end)

    it("reports movable stats content bounds while aligning dividers to the text", function()
        ZenSpec.unload("modules/filebrowser/patches/home/widgets/stats_triplet")
        local component = require("modules/filebrowser/patches/home/widgets/stats_triplet")
        local content_bounds
        local ctx = {
            width = 600,
            height = 120,
            config = {
                font_size = 18,
                middle_stats_triplet = { "today_pages", "today_duration", "streak" },
            },
            module_cfg = { stat_style = "divider" },
            data = { stats = {} },
            setContentBounds = function(bounds) content_bounds = bounds end,
        }
        assert.are.equal(35, component.preferredHeight(ctx))
        local widget = component.build(ctx)

        local divider_heights = {}
        for _i, child in ipairs(created) do
            if child.kind == "ui/widget/linewidget" then
                divider_heights[#divider_heights + 1] = child.dimen.h
            end
        end
        assert.are.same({ 19, 19 }, divider_heights)
        assert.are.same({ 48, 71, -48, 49 }, {
            content_bounds.top,
            content_bounds.bottom,
            content_bounds.min_shift,
            content_bounds.max_shift,
        })
        local metric = widget[1][1][1][1][1]
        metric:paintTo(nil, 0, 0)
        local initial_y
        for i = #created, 1, -1 do
            if created[i].text == "Pages today" and created[i].paint_y then
                initial_y = created[i].paint_y
                break
            end
        end
        content_bounds.set_shift(7)
        metric:paintTo(nil, 0, 0)
        for i = #created, 1, -1 do
            if created[i].text == "Pages today" and created[i].paint_y then
                assert.are.equal(initial_y + 7, created[i].paint_y)
                break
            end
        end

        content_bounds = nil
        ctx.data.stats = {
            today_pages = 12345,
            today_duration = 360000,
            streak = 999,
        }
        component.build(ctx)
        assert.are.same({ 48, 71, -48, 49 }, {
            content_bounds.top,
            content_bounds.bottom,
            content_bounds.min_shift,
            content_bounds.max_shift,
        })
    end)

    it("auto-sizes stats text while preserving an exact manual size", function()
        ZenSpec.replace("ui/widget/textwidget", {
            new = function(_self, values)
                values.kind = "ui/widget/textwidget"
                values.dimen = {
                    w = #values.text * math.max(1, math.floor(values.face.size * 0.6)),
                    h = values.face.size,
                }
                values.getSize = function(self) return self.dimen end
                values.paintTo = function() end
                values.free = function() end
                created[#created + 1] = values
                return values
            end,
        })
        ZenSpec.unload("modules/filebrowser/patches/home/widgets/stats_triplet")
        local component = require("modules/filebrowser/patches/home/widgets/stats_triplet")
        local function rendered_label_size()
            for i = #created, 1, -1 do
                if created[i].text == "Pages today" then
                    return created[i].face.size
                end
            end
        end
        local ctx = {
            width = 600,
            height = 30,
            config = {
                font_size = 18,
                middle_stats_triplet = { "today_pages", "today_duration", "streak" },
            },
            module_cfg = {
                automatic_font_size = true,
                stat_style = "divider",
            },
            data = { stats = {} },
        }

        assert.are.equal(38, component.preferredHeight(ctx))
        ctx.height = 80
        component.build(ctx)
        assert.are.equal(10, rendered_label_size())

        created = {}
        ctx.height = 30
        component.build(ctx)
        assert.are.equal(10, rendered_label_size())

        created = {}
        ctx.module_cfg.automatic_font_size = false
        ctx.module_cfg.font_size = 18
        component.build(ctx)
        assert.are.equal(10, rendered_label_size())
    end)

    it("insets outlined stats cards to the shared home content width", function()
        ZenSpec.unload("modules/filebrowser/patches/home/widgets/stats_triplet")
        local component = require("modules/filebrowser/patches/home/widgets/stats_triplet")
        local ctx = {
            width = 600,
            height = 120,
            config = {
                font_size = 18,
                middle_stats_triplet = { "today_pages", "today_duration", "streak" },
            },
            module_cfg = { stat_style = "outline" },
            data = { stats = {} },
        }
        local widget = component.build(ctx)

        assert.are.equal(39, component.preferredHeight(ctx))

        local card_widths, inner_widths = {}, {}
        for _i, child in ipairs(created) do
            if child.kind == "ui/widget/container/framecontainer"
                    and child.bordersize == 2 then
                card_widths[#card_widths + 1] = child.width
                inner_widths[#inner_widths + 1] = child[1].dimen.w
                assert.are.equal(child.width,
                    child[1].dimen.w + child.padding * 2 + child.bordersize * 2)
            end
        end
        assert.are.same({ 177, 177, 177 }, card_widths)
        assert.are.same({ 173, 173, 173 }, inner_widths)
        assert.are.equal(600, widget.width)
    end)

    it("renders quote attribution and navigates with horizontal swipes", function()
        ZenSpec.unload("modules/filebrowser/patches/home/widgets/quotes")
        local previous, next_quote, opened_settings = 0, 0, 0
        local content_bounds
        local component = require("modules/filebrowser/patches/home/widgets/quotes")
        local widget = component.build({
            width = 400,
            height = 120,
            config = {
                font_size = 18,
                quotes = { show_author = true, show_title = true },
            },
            is_last_row = true,
            data = {
                getCurrentQuote = function()
                    return {
                        text = "Read deeply.",
                        author = "Zen Tester",
                        title = "The Test Book",
                    }
                end,
                prevQuote = function() previous = previous + 1 end,
                nextQuote = function() next_quote = next_quote + 1 end,
            },
            editMode = true,
            openWidgetSettings = function()
                opened_settings = opened_settings + 1
                return true
            end,
            setContentBounds = function(bounds) content_bounds = bounds end,
        })
        widget.dimen.x, widget.dimen.y = 10, 20

        assert.are.equal("quotes", component.id)
        assert.are.same({ units = 1.5 }, component.size)
        assert.is_true(widget:onTapQuote(nil, { pos = { x = 40, y = 40 } }))
        assert.is_true(widget:onSwipeQuote(nil, {
            pos = { x = 40, y = 40 },
            direction = "east",
        }))
        assert.is_true(widget:onSwipeQuote(nil, {
            pos = { x = 300, y = 40 },
            direction = "west",
        }))
        assert.are.same({ 1, 1 }, { previous, next_quote })
        assert.is_false(widget:onTapQuote(nil, { pos = { x = 700, y = 40 } }))
        assert.is_true(widget:onHoldQuote(nil, { pos = { x = 40, y = 40 } }))
        assert.are.equal(1, opened_settings)
        assert.is_true(has_text('"Read deeply."'))
        assert.is_true(has_text("\226\128\148 Zen Tester,  The Test Book"))
        for _i, child in ipairs(created) do
            if child.text == '"Read deeply."' then
                assert.are.equal(0.55, child.line_height)
                assert.are.equal(12, child.face.size)
            end
        end
        widget[1][1]:paintTo(nil, 0, 0)
        local quote_widget, author_widget
        for _i, child in ipairs(created) do
            if child.text == '"Read deeply."' then
                quote_widget = child
            elseif child.text == "\226\128\148 Zen Tester,  The Test Book" then
                author_widget = child
            end
        end
        assert.are.equal(48, quote_widget.paint_y)
        assert.are.equal(60, author_widget.paint_y)
        assert.are.same({ 0, 120, 0, 0, true }, {
            content_bounds.top,
            content_bounds.bottom,
            content_bounds.min_shift,
            content_bounds.max_shift,
            content_bounds.lock_shift,
        })
        content_bounds.set_shift(-7)
        widget[1][1]:paintTo(nil, 0, 0)
        assert.are.equal(48, quote_widget.paint_y)
        assert.are.equal(60, author_widget.paint_y)
    end)

    it("reports fixed quote bounds regardless of content length", function()
        ZenSpec.unload("modules/filebrowser/patches/home/widgets/quotes")
        local component = require("modules/filebrowser/patches/home/widgets/quotes")
        local function bounds_for(text)
            local bounds
            component.build({
                width = 400,
                height = 120,
                config = { quotes = { show_author = true } },
                data = {
                    getCurrentQuote = function()
                        return { text = text, author = "Zen Tester" }
                    end,
                },
                setContentBounds = function(value) bounds = value end,
            })
            return {
                bounds.top,
                bounds.bottom,
                bounds.min_shift,
                bounds.max_shift,
            }
        end

        assert.are.same({ 0, 120, 0, 0 }, bounds_for("Short."))
        assert.are.same({ 0, 120, 0, 0 }, bounds_for("First\nSecond\nThird"))
    end)

    it("gives the bottom quote row a content-independent fixed height", function()
        ZenSpec.unload("modules/filebrowser/patches/home/widgets/quotes")
        local component = require("modules/filebrowser/patches/home/widgets/quotes")
        local quote_text = "Short."
        local ctx = {
            width = 400,
            config = {
                quotes = {
                    automatic_font_size = true,
                    max_font_size = 14,
                    show_author = true,
                },
            },
            data = {
                getCurrentQuote = function()
                    return { text = quote_text, author = "Zen Tester" }
                end,
            },
        }

        assert.is_function(component.preferredHeight)
        assert.is_nil(component.preferredHeight(ctx))
        ctx.is_last_row = true
        ctx.row_count = 2
        assert.is_nil(component.preferredHeight(ctx))
        ctx.row_count = 3
        local short_height = component.preferredHeight(ctx)
        quote_text = "A much longer quote\nthat spans\nseveral lines\nand used to resize the row."
        assert.are.equal(short_height, component.preferredHeight(ctx))
        assert.are.equal(36, short_height)
    end)

    it("seeds automatic quote sizing in the default home preset", function()
        ZenSpec.unload("modules/filebrowser/patches/home/home_presets")
        local preset = require("modules/filebrowser/patches/home/home_presets").defaultHomePage()
        assert.are.equal(10, preset.rows.capacity_units)
        assert.are.equal(2, preset.rows.layout_schema_version)
        assert.is_true(preset.modules.datetime.automatic_font_size)
        assert.are.equal(36, preset.modules.datetime.max_font_size)
        assert.are.equal(36, preset.modules.datetime.text_styles.time.font_size)
        assert.are.equal(12, preset.modules.datetime.text_styles.date.font_size)
        assert.is_nil(preset.font_size)
        assert.are.equal(16, preset.modules.stats_triplet.font_size)
        assert.is_nil(preset.modules.stats_triplet.font_size_override)
        assert.is_true(preset.modules.stats_triplet.automatic_font_size)
        assert.are.equal(18, preset.modules.stats_triplet.max_font_size)
        assert.is_true(preset.quotes.automatic_font_size)
        assert.are.equal(14, preset.quotes.max_font_size)
        assert.are.equal(12, preset.quotes.font_size)
        assert.are.equal("daily", preset.quotes.rotation)
        assert.are.same({ default = true }, preset.quotes.sources)
        assert.is_true(preset.quotes.show_author)
        assert.is_true(preset.quotes.show_title)
    end)

    it("uses the full quote widget height before reducing automatic font size", function()
        local textbox_creations = 0
        local layout_perf
        ZenSpec.replace("ui/widget/textboxwidget", {
            new = function(_self, values)
                textbox_creations = textbox_creations + 1
                local line_count = values.text:sub(1, 3) == "\226\128\148" and 1 or 2
                if values.text == '"A mostly full first line with one word below"'
                        and values.face.size >= 13 then
                    line_count = 3
                end
                if values.text == "A" then line_count = 1 end
                if values.text == "A\nA\nA" then line_count = 3 end
                local line_height = values.line_height or 0.3
                local line_height_px = math.floor(
                    values.face.size * (1 + line_height) + 0.5
                )
                local natural_h = line_count * line_height_px
                values.dimen = {
                    w = values.width,
                    h = values.height or natural_h,
                }
                values.getSize = function(self) return self.dimen end
                values.paintTo = function() end
                values.free = function() end
                created[#created + 1] = values
                return values
            end,
        })
        ZenSpec.unload("modules/filebrowser/patches/home/widgets/quotes")
        local component = require("modules/filebrowser/patches/home/widgets/quotes")
        local ctx = {
            width = 400,
            height = 66,
            config = {
                quotes = {
                    automatic_font_size = true,
                    max_font_size = 16,
                    show_author = true,
                },
            },
            data = {
                getCurrentQuote = function()
                    return {
                        text = "A mostly full first line with one word below",
                        author = "Author",
                    }
                end,
                recordQuoteLayout = function(_, elapsed_ms, cache_hit, probes)
                    layout_perf = {
                        elapsed_ms = elapsed_ms,
                        cache_hit = cache_hit,
                        probes = probes,
                    }
                end,
            },
        }
        component.build(ctx)

        local found = false
        for _i, child in ipairs(created) do
            if child.text == '"A mostly full first line with one word below"'
                    and child.height then
                assert.are.equal(14, child.face.size)
                assert.are.equal(0.15, child.line_height)
                assert.are.equal(48, child.height)
                found = true
                break
            end
        end
        assert.is_true(found)
        assert.is_number(layout_perf.elapsed_ms)
        assert.is_false(layout_perf.cache_hit)
        assert.is_true(layout_perf.probes < 20)

        local first_build_creations = textbox_creations
        component.build(ctx)
        assert.are.equal(2, textbox_creations - first_build_creations)
        assert.is_true(layout_perf.cache_hit)
        assert.are.equal(0, layout_perf.probes)
    end)

    it("controls quote authors and titles independently", function()
        local function render_attribution(show_author, show_title)
            created = {}
            ZenSpec.unload("modules/filebrowser/patches/home/widgets/quotes")
            require("modules/filebrowser/patches/home/widgets/quotes").build({
                width = 400,
                height = 100,
                config = {
                    quotes = {
                        show_author = show_author,
                        show_title = show_title,
                    },
                },
                data = {
                    getCurrentQuote = function()
                        return {
                            text = "Read deeply.",
                            author = "Zen Tester",
                            title = "The Test Book",
                        }
                    end,
                },
            })
        end

        render_attribution(true, false)
        assert.is_true(has_text("\226\128\148 Zen Tester"))
        assert.is_false(has_text("\226\128\148 Zen Tester,  The Test Book"))

        render_attribution(false, true)
        assert.is_true(has_text("\226\128\148 The Test Book"))
        assert.is_false(has_text("\226\128\148 Zen Tester"))
    end)

    it("renders the empty-history quote fallback without an author", function()
        ZenSpec.unload("modules/filebrowser/patches/home/widgets/quotes")
        local component = require("modules/filebrowser/patches/home/widgets/quotes")
        component.build({
            width = 400,
            height = 100,
            config = { quotes = { show_author = true } },
            data = { getCurrentQuote = function() return nil end },
        })

        assert.is_true(has_text('"No quote available."'))
        assert.is_false(has_text("\226\128\148 "))
    end)

    it("opens annotation quotes when tapped", function()
        ZenSpec.unload("modules/filebrowser/patches/home/widgets/quotes")
        local opened
        local quote = {
            text = "Saved highlight",
            is_annotation = true,
            filepath = "/books/test.epub",
        }
        local component = require("modules/filebrowser/patches/home/widgets/quotes")
        local widget = component.build({
            width = 400,
            height = 100,
            config = { quotes = { show_author = true } },
            data = {
                getCurrentQuote = function() return quote end,
                openQuote = function(_, selected)
                    opened = selected
                    return true
                end,
            },
        })

        assert.is_true(widget:onTapQuote(nil, { pos = { x = 40, y = 40 } }))
        assert.are.equal(quote, opened)
    end)

    it("shows up to three quote lines when the widget has room", function()
        ZenSpec.unload("modules/filebrowser/patches/home/widgets/quotes")
        local component = require("modules/filebrowser/patches/home/widgets/quotes")
        local content_bounds
        local widget = component.build({
            width = 400,
            height = 120,
            config = { quotes = { show_author = false } },
            data = {
                getCurrentQuote = function()
                    return { text = "First\nSecond\nThird\nFourth", author = "" }
                end,
            },
            setContentBounds = function(bounds) content_bounds = bounds end,
        })
        widget[1][1]:paintTo(nil, 0, 0)

        for _i, child in ipairs(created) do
            if child.text == '"First\nSecond\nThird\nFourth"' and child.height then
                assert.are.equal(36, child.height)
                assert.are.equal(42, child.paint_y)
                assert.are.same({ 0, 120 }, {
                    content_bounds.top,
                    content_bounds.bottom,
                })
                return
            end
        end
        assert.fail("quote widget was not created")
    end)
end)
