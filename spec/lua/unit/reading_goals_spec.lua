describe("reading goals settings", function()
    before_each(function()
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("ui/uimanager", { show = function() end })
        ZenSpec.unload("common/reading_goals")
    end)

    it("migrates a legacy goal and keeps every selected period", function()
        local Goals = require("common/reading_goals")
        local goals = Goals.normalize({
            metric = "time",
            period = "weekly",
            periods = { "daily", "monthly", "yearly", "monthly", "invalid" },
        })

        assert.are.same({ "daily", "monthly", "yearly" }, goals.periods)
        assert.are.equal("time", goals.metric)
        assert.are.equal(900, goals.monthly_pages_target)
        assert.are.equal(1000, goals.yearly_time_target_min)
        assert.are.equal(1, goals.monthly_books_target)
        assert.are.equal(12, goals.yearly_books_target)
        assert.are.equal("time", goals.metrics.monthly)

        local legacy = Goals.normalize({ period = "weekly" })
        assert.are.same({ "weekly" }, legacy.periods)
    end)

    it("offers each goal period as a submenu with its own metric and targets", function()
        local Goals = require("common/reading_goals")
        local items = Goals.settingsItems({ periods = { "daily" } }, function() end)

        assert.are.equal("Daily", items[1].text)
        assert.are.equal("Weekly", items[2].text)
        assert.are.equal("Monthly", items[3].text)
        assert.are.equal("Yearly", items[4].text)
        local daily = items[1].sub_item_table_func()
        assert.are.equal("Show goal", daily[1].text)
        assert.are.equal("Pages", daily[2].text)
        assert.are.equal("Time", daily[3].text)
        assert.are.equal("Daily pages goal: 30", daily[4].text_func())
        assert.are.equal("Daily time goal (min): 30", daily[5].text_func())

        local monthly = items[3].sub_item_table_func()
        assert.are.equal("Books", monthly[4].text)
        assert.are.equal("Monthly books goal: 1", monthly[7].text_func())
    end)

    it("shares one CBZ/CBR exclusion toggle", function()
        local Goals = require("common/reading_goals")
        local goals = { periods = { "daily" } }
        local saves = 0
        local item = Goals.settingsItems(goals, function() saves = saves + 1 end)[5]

        assert.are.equal("Exclude CBZ/CBR files", item.text)
        assert.is_false(item.checked_func())
        item.callback()
        assert.is_true(goals.exclude_cbz_cbr)
        assert.is_true(item.checked_func())
        assert.are.equal(1, saves)
    end)

    it("refreshes every target label after changing its value", function()
        local shown
        ZenSpec.replace("ui/uimanager", {
            show = function(_self, widget) shown = widget end,
        })
        ZenSpec.replace("ui/widget/spinwidget", {
            new = function(_self, widget) return widget end,
        })
        ZenSpec.unload("common/reading_goals")

        local Goals = require("common/reading_goals")
        local items = Goals.settingsItems({ periods = { "daily" } }, function() end)
        local update_count = 0
        local touchmenu = {
            updateItems = function() update_count = update_count + 1 end,
        }
        local target_indexes = {
            { 4, 5 },
            { 4, 5 },
            { 5, 6, 7 },
            { 5, 6, 7 },
        }

        for period_index, indexes in ipairs(target_indexes) do
            local period_items = items[period_index].sub_item_table_func()
            for _i, target_index in ipairs(indexes) do
                local target_item = period_items[target_index]
                target_item.callback(touchmenu)
                shown.callback({ value = 7 })
                assert.matches(": 7$", target_item.text_func())
            end
        end

        assert.are.equal(10, update_count)
    end)
end)

describe("reading goals widget", function()
    local created
    local shown

    local function widget_class(kind)
        return {
            new = function(_, values)
                values = values or {}
                values.kind = kind
                values.dimen = values.dimen or {
                    w = values.width or (type(values.text) == "string" and #values.text * 6 or 20),
                    h = values.height or 10,
                }
                values.getSize = values.getSize or function(self) return self.dimen end
                values.getBaseline = values.getBaseline or function(self)
                    return math.floor(((self.face and self.face.size) or 10) * 0.75)
                end
                created[#created + 1] = values
                return values
            end,
        }
    end

    before_each(function()
        created = {}
        shown = nil
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("common/ui/background", { tile_bg = function(color) return color end })
        ZenSpec.replace("ffi/blitbuffer", {
            COLOR_GRAY_3 = "gray3", COLOR_GRAY_5 = "gray5",
            COLOR_LIGHT_GRAY = "lightgray", COLOR_WHITE = "white",
        })
        ZenSpec.replace("ui/geometry", {
            new = function(_, values)
                function values:contains(pos)
                    return pos.x >= (self.x or 0) and pos.x < (self.x or 0) + (self.w or 0)
                        and pos.y >= (self.y or 0) and pos.y < (self.y or 0) + (self.h or 0)
                end
                return values
            end,
        })
        ZenSpec.replace("ui/font", { getFace = function(_, name, size) return { name = name, size = size } end })
        ZenSpec.replace("ui/rendertext", {
            sizeUtf8Text = function(_, _x, _width, face)
                return {
                    y_top = math.floor((face.size or 10) * 0.6),
                    y_bottom = math.max(1, math.floor((face.size or 10) * 0.15)),
                }
            end,
        })
        ZenSpec.replace("device", { screen = {
            scaleBySize = function(_, value) return value end,
            getWidth = function() return 800 end,
            getHeight = function() return 600 end,
        } })
        ZenSpec.replace("common/widget_resources", { free = function() end })
        ZenSpec.replace("common/ui/zen_modal_close", {
            installTitleBar = function(title_bar, _parent, callback)
                title_bar.right_button = {
                    file = "/zen-ui/icons/close.svg",
                    callback = callback,
                }
                return title_bar.right_button
            end,
            addToFocusLayout = function() end,
        })
        ZenSpec.replace("ui/uimanager", { show = function(_self, widget) shown = widget end })
        for _i, name in ipairs({
            "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/widget/textwidget",
            "ui/widget/container/framecontainer", "ui/widget/container/centercontainer",
            "ui/widget/container/leftcontainer", "ui/widget/container/rightcontainer",
            "ui/widget/verticalgroup", "ui/widget/verticalspan",
            "ui/widget/container/inputcontainer",
            "ui/widget/container/scrollablecontainer", "ui/widget/titlebar",
        }) do
            ZenSpec.replace(name, widget_class(name))
        end
        ZenSpec.replace("ui/gesturerange", widget_class("ui/gesturerange"))
        ZenSpec.replace("ui/widget/container/scrollablecontainer", {
            getScrollbarWidth = function() return 0 end,
            new = function(_, values)
                values.getSize = values.getSize or function() return values.dimen end
                return values
            end,
        })
        ZenSpec.replace("ui/widget/buttondialog", {
            new = function(_, values)
                values.widgets = {}
                values.ges_events = {}
                function values:addWidget(widget) self.widgets[#self.widgets + 1] = widget end
                return values
            end,
        })
        ZenSpec.unload("modules/filebrowser/patches/home/widgets/reading_goals")
    end)

    it("stacks every selected goal period", function()
        local widget = require("modules/filebrowser/patches/home/widgets/reading_goals")
        assert.are.equal("xs", widget.size)
        local opened_settings = 0
        local goal_widget = widget.build({
            width = 600,
            height = 160,
            config = {
                goals = {
                    periods = { "daily", "weekly", "monthly", "yearly" },
                    metrics = { daily = "pages", weekly = "time", monthly = "pages", yearly = "time" },
                },
            },
            module_cfg = { font_size = 14 },
            data = { stats = {
                today_pages = 1, week_pages = 2, month_pages = 3, year_pages = 4,
                year_duration = 240,
            } },
            editMode = true,
            openWidgetSettings = function()
                opened_settings = opened_settings + 1
                return true
            end,
        })

        local found = {}
        for _i, item in ipairs(created) do
            if item.text then found[item.text] = true end
        end
        assert.is_true(found["Daily"])
        assert.is_true(found["Weekly"])
        assert.is_true(found["Monthly"])
        assert.is_true(found["Yearly"])
        assert.is_true(found["1 / 30 pages (3%)"])
        assert.is_true(found["4 / 1000 min (0%)"])
        local row_gaps = 0
        for _i, item in ipairs(created) do
            if item.kind == "ui/widget/verticalspan" and item.width == 2 then
                row_gaps = row_gaps + 1
            end
        end
        assert.are.equal(3, row_gaps)

        goal_widget.dimen.x, goal_widget.dimen.y = 0, 0
        assert.is_true(goal_widget:onTapReadingGoals(nil, { pos = { x = 20, y = 20 } }))
        assert.is_true(goal_widget:onHoldReadingGoals(nil, { pos = { x = 20, y = 20 } }))
        assert.are.equal(1, opened_settings)
        assert.are.equal("Reading goals", shown.widgets[1].title)
        assert.is_nil(shown.widgets[1].left_button)
        assert.are.equal("/zen-ui/icons/close.svg", shown.widgets[1].right_button.file)
        local popup_texts = {}
        for _i, item in ipairs(created) do
            if item.text then popup_texts[item.text] = true end
        end
        assert.is_true(popup_texts[string.format("Daily goal (%s)", os.date("%B %d"))])
        assert.is_true(popup_texts[string.format("Monthly goal (%s)", os.date("%B"))])
        assert.is_true(popup_texts[string.format("Yearly goal (%s)", os.date("%Y"))])
    end)

    it("caps its configured font size", function()
        local widget = require("modules/filebrowser/patches/home/widgets/reading_goals")
        widget.build({
            width = 600,
            height = 160,
            config = { font_size = 18, goals = { periods = { "daily" } } },
            module_cfg = { font_size = 20 },
            data = { stats = { today_pages = 1 } },
        })

        for _i, item in ipairs(created) do
            if item.text == "Daily" and item.face and item.face.size == 16 then return end
        end
        assert.fail("Reading goals did not cap its configured font size")
    end)

    it("keeps larger text by tightening multi-goal row spacing", function()
        ZenSpec.replace("ui/widget/textwidget", {
            new = function(_, values)
                values.kind = "ui/widget/textwidget"
                values.dimen = {
                    w = type(values.text) == "string" and #values.text * 6 or 20,
                    h = values.face.size,
                }
                function values:getSize() return self.dimen end
                function values:getBaseline() return math.floor(self.face.size * 0.75) end
                created[#created + 1] = values
                return values
            end,
        })
        ZenSpec.unload("modules/filebrowser/patches/home/widgets/reading_goals")
        local widget = require("modules/filebrowser/patches/home/widgets/reading_goals")
        widget.build({
            width = 600,
            height = 36,
            config = { goals = { periods = { "daily", "weekly", "monthly" } } },
            module_cfg = { font_size = 12 },
            data = { stats = { today_pages = 1 } },
        })

        for _i, item in ipairs(created) do
            if item.text == "Daily" and item.face.size == 12 then return end
        end
        assert.fail("Reading goals unnecessarily reduced the multi-goal font size")
    end)

    it("truncates narrow rows without shrinking below ten points", function()
        local widget = require("modules/filebrowser/patches/home/widgets/reading_goals")
        widget.build({
            width = 120,
            height = 120,
            config = { goals = { periods = { "daily", "weekly", "monthly" } } },
            module_cfg = { font_size = 8 },
            data = { stats = { today_pages = 1 } },
        })

        for _i, item in ipairs(created) do
            if item.text == "1 / 30 pages (3%)" then
                assert.are.equal(10, item.face.size)
                assert.is_true(item.truncate_with_ellipsis)
                assert.is_true(item.max_width > 0)
                return
            end
        end
        assert.fail("Reading goals value was not rendered")
    end)

    it("uses the eleven-point 3.3 default font size", function()
        local widget = require("modules/filebrowser/patches/home/widgets/reading_goals")
        widget.build({
            width = 600,
            height = 160,
            config = { font_size = 18, goals = { periods = { "daily" } } },
            data = { stats = { today_pages = 1 } },
        })

        for _i, item in ipairs(created) do
            if item.text == "Daily" and item.face and item.face.size == 11 then return end
        end
        assert.fail("Reading goals did not use its eleven-point default font size")
    end)

    it("shows completed books for monthly and yearly goals", function()
        local widget = require("modules/filebrowser/patches/home/widgets/reading_goals")
        widget.build({
            width = 600,
            height = 160,
            config = {
                goals = {
                    periods = { "monthly", "yearly" },
                    metrics = { monthly = "books", yearly = "books" },
                    monthly_books_target = 2,
                    yearly_books_target = 12,
                },
            },
            data = { stats = { finished_this_month = 1, finished_this_year = 8 } },
        })

        local found = {}
        for _i, item in ipairs(created) do
            if item.text then found[item.text] = true end
        end
        assert.is_true(found["1 / 2 Books (50%)"])
        assert.is_true(found["8 / 12 Books (67%)"])
    end)
end)
