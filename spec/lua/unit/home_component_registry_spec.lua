describe("home component registry", function()
    local module_names = {
        "datetime",
        "featured",
        "stats_triplet",
        "reading_goals",
        "strip",
        "quotes",
    }
    local module_sizes = {
        datetime = "xs",
        featured = { units = 3.5 },
        stats_triplet = "xs",
        reading_goals = "xs",
        strip = { units = 2.5 },
        quotes = { units = 1.5 },
    }

    before_each(function()
        ZenSpec.unload("modules/filebrowser/patches/home/components/registry")
        for _i, id in ipairs(module_names) do
            ZenSpec.replace("modules/filebrowser/patches/home/widgets/" .. id, {
                id = id,
                label = id .. " widget",
                size = module_sizes[id],
                build = function() return id end,
            })
        end
    end)

    after_each(function()
        _G.__ZENOS_REGISTER_HOME_ITEM = nil
        _G.__ZENOS_UNREGISTER_HOME_ITEM = nil
        _G.__ZEN_UI_REGISTER_HOME_ITEM = nil
        _G.__ZEN_UI_UNREGISTER_HOME_ITEM = nil
    end)

    it("loads every built-in home widget in its stable order", function()
        local Registry = require("modules/filebrowser/patches/home/components/registry")
        local ids = {}
        for _i, component in ipairs(Registry.list()) do
            ids[#ids + 1] = component.id
            assert.is_function(component.build)
        end
        assert.are.same(module_names, ids)
    end)

    it("normalizes duplicate, missing, and dormant row settings", function()
        local Registry = require("modules/filebrowser/patches/home/components/registry")
        local rows = Registry.normalizeRows({
            order = { "quotes", "quotes", "external_missing" },
            enabled = { quotes = true, dormant = true },
            max_rows = 99,
        }, { "datetime", "featured" }, { datetime = true })

        assert.is_nil(rows.max_rows)
        assert.are.equal(10, rows.capacity_units)
        assert.are.same({
            "quotes", "external_missing", "datetime", "featured",
            "stats_triplet", "reading_goals",
            "strip", "dormant",
        }, rows.order)
        assert.is_true(rows.enabled.quotes)
        assert.is_true(rows.enabled.dormant)
        assert.is_false(rows.enabled.featured)
    end)

    it("registers external widgets, refreshes, and rejects built-in overrides", function()
        local Registry = require("modules/filebrowser/patches/home/components/registry")
        local refreshes = 0
        Registry.setRefreshCallback(function() refreshes = refreshes + 1 end)
        Registry.install()

        assert.are.equal(_G.__ZEN_UI_REGISTER_HOME_ITEM, _G.__ZENOS_REGISTER_HOME_ITEM)
        assert.are.equal(_G.__ZEN_UI_UNREGISTER_HOME_ITEM, _G.__ZENOS_UNREGISTER_HOME_ITEM)

        assert.is_false(_G.__ZEN_UI_REGISTER_HOME_ITEM("quotes", function() end))
        assert.is_false(_G.__ZEN_UI_REGISTER_HOME_ITEM("invalid", "not a function"))
        assert.is_true(_G.__ZENOS_REGISTER_HOME_ITEM("weather", function() return "sunny" end, {
            label = "Weather",
            size = "m",
        }))
        assert.are.equal("Weather", Registry.get("weather").label)
        assert.are.equal(3, Registry.sizeUnits(Registry.get("weather")))
        assert.are.equal("sunny", Registry.get("weather").build())
        assert.are.equal(1, refreshes)

        _G.__ZENOS_UNREGISTER_HOME_ITEM("weather")
        assert.is_nil(Registry.get("weather"))
        assert.are.equal(2, refreshes)
    end)

    it("maps widget sizes to the 10-unit grid", function()
        local Registry = require("modules/filebrowser/patches/home/components/registry")
        assert.are.equal(1, Registry.sizeUnits(Registry.get("datetime")))
        assert.are.equal(1, Registry.sizeUnits(Registry.get("stats_triplet")))
        assert.are.equal(1.5, Registry.sizeUnits(Registry.get("quotes")))
        assert.are.equal(2.5, Registry.sizeUnits(Registry.get("strip")))
        assert.are.equal(3.5, Registry.sizeUnits(Registry.get("featured")))
        assert.are.equal(5, Registry.sizeUnits(
            Registry.get("strip"), { two_rows = true }
        ))
        assert.are.equal(10, Registry.sizeUnits({ size = "xl" }))
        assert.are.equal(4, Registry.sizeUnits({
            size = { preferred_pct = 0.36 },
        }))
        assert.are.equal(8.5, Registry.totalUnits({
            featured = true,
            stats_triplet = true,
            strip = true,
            quotes = true,
        }))
        assert.are.same({ 3.5, 1, 4, 1.5 }, Registry.layoutUnits({
            Registry.get("featured"),
            Registry.get("stats_triplet"),
            Registry.get("strip"),
            Registry.get("quotes"),
        }))
        assert.are.same({ 1, 4, 1 }, Registry.layoutUnits({
            Registry.get("datetime"),
            Registry.get("featured"),
            Registry.get("stats_triplet"),
        }))
        assert.are.same({ 4, 4 }, Registry.layoutUnits({
            Registry.get("featured"),
            Registry.get("strip"),
        }))
        assert.are.same({ 1 }, Registry.layoutUnits({ Registry.get("stats_triplet") }))
        assert.are.same({ 4, 6 }, Registry.layoutUnits({
            setmetatable({ _home_units = 3.5 }, {
                __index = Registry.get("featured"),
            }),
            setmetatable({ _home_units = 5 }, {
                __index = Registry.get("strip"),
            }),
        }))
        assert.are.same({ 394, 596 }, Registry.gridHeights({ 4, 6 }, 1000, 10))
    end)

    it("adds layout capacity on tall screens without shrinking other devices", function()
        local Registry = require("modules/filebrowser/patches/home/components/registry")

        assert.are.equal(10, Registry.capacityUnits(1080, 1440))
        assert.are.equal(17, Registry.capacityUnits(1080, 2400))
        assert.are.equal(17, Registry.capacityUnits(2400, 1080))
        assert.are.equal(16, Registry.capacityUnits(1080, 2340))
        assert.are.equal(16, Registry.capacityUnits(2340, 1080))
        assert.are.equal(20, Registry.capacityUnits(100, 1000))
        assert.are.equal(10, Registry.capacityUnits(0, 1000))
        ZenSpec.replace("device", { screen = {
            getWidth = function() return 2340 end,
            getHeight = function() return 1080 end,
        } })
        assert.are.equal(16, Registry.capacityUnits())

        local units = Registry.layoutUnits({
            Registry.get("datetime"),
            Registry.get("featured"),
            Registry.get("stats_triplet"),
            Registry.get("reading_goals"),
            Registry.get("strip"),
            Registry.get("quotes"),
        }, 17)
        assert.are.equal(6, #units)
        assert.are.same({ 1, 3.5, 1, 1, 2.5, 1.5 }, units)
        local heights = Registry.gridHeights(units, 2400, 10, 17)
        local occupied = (#heights - 1) * 10
        for _i, height in ipairs(heights) do occupied = occupied + height end
        assert.are.equal(2400, occupied)
        assert.are.equal(13, Registry.totalUnits({
            datetime = true,
            featured = true,
            stats_triplet = true,
            reading_goals = true,
            strip = true,
            quotes = true,
        }, {
            strip = { two_rows = true },
        }))
    end)

    it("keeps an existing five-widget phone layout within the grid", function()
        local Registry = require("modules/filebrowser/patches/home/components/registry")
        local units = Registry.layoutUnits({
            Registry.get("featured"),
            Registry.get("strip"),
            Registry.get("quotes"),
            Registry.get("reading_goals"),
            Registry.get("stats_triplet"),
        })

        assert.are.same({ 3.5, 3, 1.5, 1, 1 }, units)
        assert.are.equal(9.5, Registry.totalUnits({
            featured = true,
            strip = true,
            quotes = true,
            reading_goals = true,
            stats_triplet = true,
        }))
    end)

    it("compacts oversized saved layouts instead of dropping a widget", function()
        local Registry = require("modules/filebrowser/patches/home/components/registry")
        local units = Registry.layoutUnits({
            Registry.get("featured"),
            Registry.get("stats_triplet"),
            Registry.get("datetime"),
            Registry.get("strip"),
            Registry.get("quotes"),
        })
        local total = 0
        for _i, units_for_widget in ipairs(units) do
            total = total + units_for_widget
            assert.is_true(units_for_widget > 0)
        end

        assert.are.equal(5, #units)
        assert.are.equal(10, total)
    end)

    it("fits the Bookshelf featured and two-row strip widgets", function()
        ZenSpec.unload("modules/filebrowser/patches/home/home_presets")
        local presets = require("modules/filebrowser/patches/home/home_presets").getBuiltinPresets()
        local bookshelf = presets[2].home_page
        local Registry = require("modules/filebrowser/patches/home/components/registry")

        assert.is_true(bookshelf.modules.strip.two_rows)
        assert.is_true(bookshelf.modules.strip.controls.enabled)
        assert.is_true(Registry.totalUnits(
            bookshelf.rows.enabled,
            bookshelf.modules
        ) <= Registry.CAPACITY_UNITS)
        assert.are.same({ 4, 6 }, Registry.layoutUnits({
            setmetatable({ _home_units = 3.5 }, {
                __index = Registry.get("featured"),
            }),
            setmetatable({ _home_units = 5 }, {
                __index = Registry.get("strip"),
            }),
        }))
    end)

    it("fills the 10-track grid with equal widget gaps", function()
        local Registry = require("modules/filebrowser/patches/home/components/registry")
        local heights = Registry.gridHeights({ 4, 1, 3, 2 }, 1000, 10)

        assert.are.same({ 394, 91, 293, 192 }, heights)
        assert.are.equal(1000,
            heights[1] + heights[2] + heights[3] + heights[4] + 30)
        assert.are.same({ 1003 }, Registry.gridHeights({ 10 }, 1003, 10))
        assert.are.equal(0,
            1000 - Registry.gridHeights({ 4, 3 }, 1000, 10)[1]
                - Registry.gridHeights({ 4, 3 }, 1000, 10)[2] - 10)
        assert.are.same({ 344, 91, 343, 192 },
            Registry.gridHeights({ 3.5, 1, 3.5, 2 }, 1000, 10))
        assert.are.same({ 344, 242, 192, 91, 91 },
            Registry.gridHeights({ 3.5, 2.5, 2, 1, 1 }, 1000, 10))
    end)

    it("redistributes height a width-limited widget cannot use", function()
        local Registry = require("modules/filebrowser/patches/home/components/registry")

        assert.are.same({ 320, 120, 540 }, Registry.gridHeights(
            { 3, 2, 5 }, 1000, 10, 10, { nil, 120, nil }))
        assert.are.same({ 690, 300 }, Registry.gridHeights(
            { 2, 2 }, 1000, 10, 10, { nil, 300 }))
    end)

    it("fills unused grid tracks across the visible widgets", function()
        local Registry = require("modules/filebrowser/patches/home/components/registry")

        assert.are.same({ 567, 423 }, Registry.gridHeights(
            { 4, 3 }, 1000, 10, 10))
    end)

    it("equalizes visible gaps within each widget's available slack", function()
        local Registry = require("modules/filebrowser/patches/home/components/registry")
        local items = {
            { row_y = 0, top = 0, bottom = 100, min_shift = -10, max_shift = 10 },
            { row_y = 165, top = 0, bottom = 100, min_shift = -20, max_shift = 20 },
            { row_y = 298, top = 0, bottom = 100, min_shift = -20, max_shift = 20 },
            { row_y = 465, top = 0, bottom = 100, min_shift = -8, max_shift = 80 },
        }
        local shifts = Registry.equalSpacingShifts(items)
        local gaps = {}
        for i = 1, #items - 1 do
            gaps[i] = items[i + 1].row_y + items[i + 1].top + shifts[i + 1]
                - items[i].row_y - items[i].bottom - shifts[i]
        end

        assert.are.equal(4, #shifts)
        assert.are.equal(gaps[1], gaps[2])
        assert.are.equal(gaps[2], gaps[3])
        for i, shift in ipairs(shifts) do
            assert.is_true(shift >= items[i].min_shift)
            assert.is_true(shift <= items[i].max_shift)
        end
    end)

    it("spreads widgets evenly between matching visual edge insets", function()
        local Registry = require("modules/filebrowser/patches/home/components/registry")
        local items = {
            { row_y = 10, top = 10, bottom = 110, min_shift = 0, max_shift = 0 },
            { row_y = 250, top = 20, bottom = 120, min_shift = -100, max_shift = 100 },
            { row_y = 500, top = 10, bottom = 110, min_shift = -100, max_shift = 200 },
        }
        local body_h = 721
        local top_inset = items[1].row_y + items[1].top
        local bottom = body_h - top_inset
        local shifts = Registry.equalSpacingShifts(items, { bottom = bottom })
        local first_gap = items[2].row_y + items[2].top + shifts[2]
            - items[1].row_y - items[1].bottom - shifts[1]
        local second_gap = items[3].row_y + items[3].top + shifts[3]
            - items[2].row_y - items[2].bottom - shifts[2]

        assert.are.same({ 0, 40, 91 }, shifts)
        assert.are.same({ 190, 191 }, { first_gap, second_gap })
        assert.are.equal(bottom,
            items[3].row_y + items[3].bottom + shifts[3])
        assert.are.equal(top_inset,
            body_h - items[3].row_y - items[3].bottom - shifts[3])
    end)

    it("drops the bottom anchor rather than overlapping widgets", function()
        local Registry = require("modules/filebrowser/patches/home/components/registry")
        local items = {
            { row_y = 0, top = 0, bottom = 100, min_shift = 0, max_shift = 0 },
            { row_y = 130, top = 0, bottom = 100, min_shift = 0, max_shift = 0 },
            { row_y = 260, top = 0, bottom = 100, min_shift = -100, max_shift = 100 },
        }

        assert.are.same({ 0, 0, 0 },
            Registry.equalSpacingShifts(items, { bottom = 200 }))
    end)

    it("equalizes gaps when content is taller than its row", function()
        local Registry = require("modules/filebrowser/patches/home/components/registry")
        local items = {
            { row_y = 0, top = 0, bottom = 100, min_shift = 0, max_shift = 20 },
            { row_y = 150, top = 6, bottom = 128, min_shift = -6, max_shift = -28 },
            { row_y = 280, top = 0, bottom = 100, min_shift = -20, max_shift = 20 },
        }
        local shifts = Registry.equalSpacingShifts(items)
        local first_gap = items[2].row_y + items[2].top + shifts[2]
            - items[1].row_y - items[1].bottom - shifts[1]
        local second_gap = items[3].row_y + items[3].top + shifts[3]
            - items[2].row_y - items[2].bottom - shifts[2]

        assert.are.equal(3, #shifts)
        assert.are.equal(first_gap, second_gap)
        assert.is_true(shifts[2] >= -28)
        assert.is_true(shifts[2] <= -6)
    end)

    it("returns the closest spacing when fixed content prevents equality", function()
        local Registry = require("modules/filebrowser/patches/home/components/registry")
        local shifts = Registry.equalSpacingShifts({
            { row_y = 0, top = 0, bottom = 100, min_shift = 0, max_shift = 0 },
            { row_y = 120, top = 0, bottom = 100, min_shift = 0, max_shift = 0 },
            { row_y = 280, top = 0, bottom = 100, min_shift = 0, max_shift = 0 },
        })

        assert.are.same({ 0, 0, 0 }, shifts)
    end)
end)
