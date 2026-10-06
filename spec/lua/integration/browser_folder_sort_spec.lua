describe("browser folder sort patch", function()
    local SortFixtures = require("sort_fixtures")
    local FileChooser
    local config
    local fixture

    before_each(function()
        config = { folder_sort = {} }
        fixture = SortFixtures.new()
        FileChooser = {
            collates = SortFixtures.collates(fixture.metadata),
            getCollate = function(self)
                local collate_id = self.global_collate or "strcoll"
                return self.collates[collate_id], collate_id
            end,
            getSortingFunction = function(_, collate, reverse)
                local less = collate.init_sort_func()
                if reverse then return function(a, b) return less(b, a) end end
                return less
            end,
            genItemTableFromPath = function(self)
                local items = SortFixtures.copy_entries(fixture.entries)
                local collate = self:getCollate()
                if collate.item_func then
                    for _i, item in ipairs(items) do collate.item_func(item, {}) end
                end
                table.sort(items, self:getSortingFunction(collate, self.global_reverse == true))
                return items
            end,
        }
        ZenSpec.replace("ui/widget/filechooser", FileChooser)
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("config/manager", {
            get = function() return config end,
            load = function() return config end,
            save = function(value) config = value end,
        })
        ZenSpec.replace("ffi/util", { realpath = function(path) return path end })
        ZenSpec.replace("common/history_index", {
            load = function() return {} end,
            maxDescendantTimes = function() return {} end,
        })
        ZenSpec.replace("common/paths", {
            normPath = function(path) return path end,
            getHomeDir = function() return "/library" end,
        })
        ZenSpec.unload("modules/filebrowser/patches/browser_folder_sort")
        require("modules/filebrowser/patches/browser_folder_sort")()
    end)

    it("persists normalized overrides and applies reverse sorting outside home", function()
        local api = assert(_G.__ZEN_FOLDER_SORT)
        api.set("/library/folder/", "title", true)
        assert.are.same({ collate = "title", reverse = true }, api.get("/library/folder"))
        local items = FileChooser:genItemTableFromPath("/library/folder")
        assert.are.same(SortFixtures.reversed(fixture.expected.title),
            SortFixtures.paths_from_entries(items))
        api.clear("/library/folder")
        assert.is_nil(api.get("/library/folder"))
    end)

    it("never applies an override to the configured home directory", function()
        local api = assert(_G.__ZEN_FOLDER_SORT)
        api.set("/library", "title", true)
        local items = FileChooser:genItemTableFromPath("/library")
        assert.are.same(fixture.expected.strcoll, SortFixtures.paths_from_entries(items))
    end)

    it("applies accented title ordering in both directions through per-folder overrides", function()
        require("ffi/loadlib")
        ZenSpec.replace("ui/widget/booklist", { collates = FileChooser.collates })
        ZenSpec.unload("modules/filebrowser/patches/add_sort_title_natural")
        require("modules/filebrowser/patches/add_sort_title_natural")()
        fixture.metadata[fixture.paths.zeta].display_title = "Čapek 10"
        fixture.metadata[fixture.paths.alpha].display_title = "The Čapek 2"
        fixture.metadata[fixture.paths.middle].display_title = "Ținut"
        fixture.metadata[fixture.paths.beta].display_title = "Zulu"
        local ui = { bookinfo = {
            getDocProps = function(_self, path) return fixture.metadata[path] end,
        } }
        local item_func = FileChooser.collates.title_natural.item_func
        FileChooser.collates.title_natural.item_func = function(item) item_func(item, ui) end
        local expected = {
            title = { fixture.paths.zeta, fixture.paths.alpha, fixture.paths.middle, fixture.paths.beta },
            title_natural = { fixture.paths.alpha, fixture.paths.zeta, fixture.paths.middle, fixture.paths.beta },
        }
        for mode, order in pairs(expected) do
            for _i, reverse in ipairs({ false, true }) do
                _G.__ZEN_FOLDER_SORT.set("/library/folder", mode, reverse)
                local items = FileChooser:genItemTableFromPath("/library/folder")
                assert.are.same(reverse and SortFixtures.reversed(order) or order,
                    SortFixtures.paths_from_entries(items))
            end
        end
    end)

    it("uses a deterministic path tie-break inside an overridden folder", function()
        FileChooser._zen_sort_override = { collate = "title", reverse = false }
        local sorting = FileChooser:getSortingFunction(FileChooser.collates.title, false)
        local alpha = {
            text = "Same", path = "/library/folder/Alpha.epub",
            doc_props = { display_title = "Same" },
        }
        local zulu = {
            text = "Same", path = "/library/folder/Zulu.epub",
            doc_props = { display_title = "Same" },
        }

        assert.is_true(sorting(alpha, zulu))
        assert.is_false(sorting(zulu, alpha))
    end)

    it("sorts date added by change time with safe fallbacks and stable ties", function()
        local collate = FileChooser.collates.date_added
        local items = {
            { path = "/books/unknown.epub" },
            { path = "/books/new.epub", attr = { change = 300, modification = 10 } },
            { path = "/books/b.epub", attr = { change = 100, modification = 400 } },
            { path = "/books/legacy.epub", attr = { modification = 200 } },
            { path = "/books/a.epub", attr = { change = 100 } },
        }
        local sorting = FileChooser:getSortingFunction(collate, false)

        table.sort(items, sorting)

        assert.are.same({
            "/books/new.epub", "/books/legacy.epub", "/books/a.epub",
            "/books/b.epub", "/books/unknown.epub",
        }, SortFixtures.paths_from_entries(items))
        assert.is_false(sorting(items[1], items[1]))
        assert.is_true(collate.can_collate_mixed)
    end)

    it("applies every library sort method in forward and reverse order", function()
        local methods = { "strcoll", "title", "title_natural", "authors", "series", "access", "date_added" }
        for _i, method in ipairs(methods) do
            for _j, reverse in ipairs({ false, true }) do
                FileChooser.global_collate = method
                FileChooser.global_reverse = reverse
                local items = FileChooser:genItemTableFromPath("/library")
                local expected = reverse and SortFixtures.reversed(fixture.expected[method])
                    or fixture.expected[method]
                assert.are.same(expected, SortFixtures.paths_from_entries(items),
                    method .. " reverse=" .. tostring(reverse))
            end
        end
    end)

    it("applies every folder sort method in forward and reverse order", function()
        local api = assert(_G.__ZEN_FOLDER_SORT)
        local methods = { "strcoll", "title", "title_natural", "authors", "series", "access", "date_added" }
        for _i, method in ipairs(methods) do
            for _j, reverse in ipairs({ false, true }) do
                api.set("/library/folder", method, reverse)
                local items = FileChooser:genItemTableFromPath("/library/folder")
                local expected = reverse and SortFixtures.reversed(fixture.expected[method])
                    or fixture.expected[method]
                assert.are.same(expected, SortFixtures.paths_from_entries(items),
                    method .. " reverse=" .. tostring(reverse))
            end
        end
    end)
end)
