describe("automatic series grouping patch", function()
    local FileChooser
    local TitleBar
    local metadata
    local original_select_calls
    local cached_rows
    local doc_props_lookups
    local directory_prefetches
    local original_refresh_calls
    local statuses

    local function item(path, title, access)
        return {
            text = title,
            path = path,
            is_file = true,
            attr = { mode = "file", access = access },
        }
    end

    local function chooser()
        return setmetatable({
            path = "/library",
            page = 2,
            perpage = 10,
            path_items = { ["/library"] = 3 },
            getCollate = function() return { can_collate_mixed = false }, "natural" end,
            getSortingFunction = function()
                return function(a, b) return (a.text or "") < (b.text or "") end
            end,
            switchItemTable = FileChooser.switchItemTable,
        }, { __index = FileChooser })
    end

    before_each(function()
        metadata = {}
        original_select_calls = 0
        cached_rows = {}
        doc_props_lookups = 0
        directory_prefetches = 0
        original_refresh_calls = 0
        statuses = {}
        G_reader_settings = ZenSpec.memorySettings({
            reverse_collate = false,
            collate_mixed = false,
            home_dir = "/library",
        })
        _G.__ZEN_UI_PLUGIN = {
            config = {
                features = { automatic_series_grouping = true, hide_grouped_series = false },
                browser_cover_badges = { dim_finished_books = false },
            },
        }
        _G.__ZEN_FOLDER_SORT = nil
        _G.__ZEN_FOLDER_DISPLAY_MODE = nil

        FileChooser = {
            updateItems = function() return "updated" end,
            onMenuSelect = function()
                original_select_calls = original_select_calls + 1
                return "selected"
            end,
            onFolderUp = function() return "folder-up" end,
            changeToPath = function(self, path)
                self.changed_to = path
                if self._test_parent_items then
                    self.page = 1
                    self:switchItemTable(nil, self._test_parent_items)
                end
                return "changed"
            end,
            refreshPath = function(self)
                original_refresh_calls = original_refresh_calls + 1
                if self._test_refresh_items then
                    self.page = 1
                    self:switchItemTable(nil, self._test_refresh_items)
                end
            end,
            goHome = function() return "home" end,
            switchItemTable = function(self, _title, new_items, itemnumber, itemmatch, subtitle)
                self.item_table = new_items
                self.switched_itemnumber = itemnumber
                self.switched_itemmatch = itemmatch
                self.subtitle = subtitle
                return "switched"
            end,
        }
        TitleBar = { setSubTitle = function(self, subtitle) self.subtitle = subtitle end }

        ZenSpec.replace("ui/widget/filechooser", FileChooser)
        ZenSpec.replace("ui/widget/titlebar", TitleBar)
        ZenSpec.replace("ui/bidi", {
            mirroredUILayout = function() return false end,
            ltr = function(value) return value end,
        })
        ZenSpec.replace("device", { home_dir = "/library" })
        ZenSpec.replace("common/zen_logger", {
            new = function()
                return { info = function() end, warn = function() end }
            end,
        })
        ZenSpec.replace("util", {
            splitFilePathName = function(path)
                return assert(path:match("^(.*)/([^/]+)$"))
            end,
        })
        ZenSpec.replace("bookinfomanager", {
            -- Mirrors ljsqlite3: closing a connection closes every statement it prepared.
            openDbConnection = function(self)
                if self.db_conn then return end
                local conn = {}
                conn.prepare = function()
                    directory_prefetches = directory_prefetches + 1
                    local position = 0
                    return {
                        bind = function(stmt, directory)
                            assert(not conn.closed, "object is closed")
                            stmt.directory = directory
                            position = 0
                        end,
                        step = function()
                            position = position + 1
                            return cached_rows[position]
                        end,
                        close = function(stmt) stmt.closed = true end,
                    }
                end
                self.db_conn = conn
            end,
            closeDbConnection = function(self)
                if self.db_conn then self.db_conn.closed = true end
                self.db_conn = nil
            end,
            getDocProps = function(_, path)
                doc_props_lookups = doc_props_lookups + 1
                return metadata[path]
            end,
        })
        ZenSpec.replace("common/book_status", {
            getDisplayStatusFromFile = function(path) return statuses[path] or "new" end,
        })
        ZenSpec.replace("apps/filemanager/filemanager", {
            instance = { _updateStatusBar = function(self) self.updated = true end },
        })

        ZenSpec.unload("modules/filebrowser/patches/automatic_series_grouping")
        require("modules/filebrowser/patches/automatic_series_grouping")()
    end)

    after_each(function()
        _G.__ZEN_UI_PLUGIN = nil
        _G.__ZEN_FOLDER_SORT = nil
        _G.__ZEN_FOLDER_DISPLAY_MODE = nil
        _G.__ZEN_SERIES_EXIT = nil
    end)

    it("groups repeated metadata series and orders books by series index", function()
        local first = item("/library/B.epub", "B")
        local second = item("/library/A.epub", "A")
        local loose = item("/library/Loose.epub", "Loose")
        metadata[first.path] = { series = "Saga", series_index = 2 }
        metadata[second.path] = { series = "Saga", series_index = 1 }
        metadata[loose.path] = { title = "Loose" }
        local fc = chooser()

        FileChooser.switchItemTable(fc, nil, { first, second, loose })

        assert.are.equal(2, #fc.item_table)
        local group = fc.item_table[1]
        assert.is_true(group.is_series_group)
        assert.are.equal("Saga", group.text)
        assert.are.equal("2 \u{F016}", group.mandatory)
        assert.are.same({ second, first }, group.series_items)
        assert.are.equal(loose, fc.item_table[2])
    end)

    it("opens virtual members in the same canonical order as their folder cover", function()
        local members = {
            item("/library/Four.epub", "Four"),
            item("/library/One.epub", "One"),
            item("/library/Three.epub", "Three"),
            item("/library/Two.epub", "Two"),
        }
        local loose = item("/library/Loose.epub", "Loose")
        for _i, member in ipairs(members) do
            metadata[member.path] = { series = "Saga" }
        end
        metadata[loose.path] = { title = "Loose" }
        local fc = chooser()

        FileChooser.switchItemTable(fc, nil, {
            members[1], members[2], members[3], members[4], loose,
        })
        local group = fc.item_table[1]
        local canonical = {
            group.series_items[1], group.series_items[2],
            group.series_items[3], group.series_items[4],
        }
        FileChooser.onMenuSelect(fc, group)

        assert.are.same(canonical, {
            fc.item_table[2], fc.item_table[3],
            fc.item_table[4], fc.item_table[5],
        })
    end)

    it("uses a deterministic path tie-break for equal override sort keys", function()
        local zulu = item("/library/Zulu.epub", "Zulu")
        local alpha = item("/library/Alpha.epub", "Alpha")
        local loose = item("/library/Loose.epub", "Loose")
        metadata[zulu.path] = { series = "Saga" }
        metadata[alpha.path] = { series = "Saga" }
        metadata[loose.path] = { title = "Loose" }
        _G.__ZEN_FOLDER_SORT = {
            get = function() return { collate = "title", reverse = false } end,
        }
        local equal_title = {
            item_func = function(member)
                member.doc_props = { display_title = "Same title" }
            end,
        }
        local fc = chooser()
        fc.getCollate = function(self)
            if self._zen_sort_override then return equal_title, "title" end
            return { can_collate_mixed = false }, "natural"
        end
        fc.getSortingFunction = function(_self, _collate, _reverse)
            return function() return false end
        end

        FileChooser.switchItemTable(fc, nil, { zulu, alpha, loose })

        assert.are.same({ alpha, zulu }, fc.item_table[1].series_items)
    end)

    it("uses the newest member when sorting virtual folders by recently read", function()
        local saga_early = item("/library/Saga-1.epub", "Saga 1", 10)
        local other_recent = item("/library/Other-1.epub", "Other 1", 50)
        local saga_latest = item("/library/Saga-2.epub", "Saga 2", 100)
        local other_early = item("/library/Other-2.epub", "Other 2", 40)
        metadata[saga_early.path] = { series = "Saga", series_index = 1 }
        metadata[saga_latest.path] = { series = "Saga", series_index = 2 }
        metadata[other_recent.path] = { series = "Other", series_index = 1 }
        metadata[other_early.path] = { series = "Other", series_index = 2 }
        local fc = chooser()
        fc.getCollate = function() return { can_collate_mixed = false }, "access" end
        fc.getSortingFunction = function()
            return function(a, b)
                return (a.attr.access or 0) > (b.attr.access or 0)
            end
        end

        FileChooser.switchItemTable(fc, nil, {
            saga_early, other_recent, saga_latest, other_early,
        })

        assert.are.equal("Saga", fc.item_table[1].text)
        assert.are.equal(100, fc.item_table[1].attr.access)
    end)

    it("groups Series-A from the CoverBrowser directory metadata cache", function()
        local alpha = item("/library/Series-A/01 - Alpha.epub", "01 - Alpha")
        local no_cover = item("/library/Series-A/02 - No Cover.epub", "02 - No Cover")
        local finale = item("/library/Series-A/03 - Finale.epub", "03 - Finale")
        local loose = item("/library/Series-A/Loose.epub", "Loose")
        cached_rows = {
            { "/library/Series-A/", "01 - Alpha.epub", nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, 101, "Alpha", "Zen Author", "Series A", 1, "en", "" },
            { "/library/Series-A/", "02 - No Cover.epub", nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, 102, "No Cover", "Zen Author", "Series A", 2, "en", "" },
            { "/library/Series-A/", "03 - Finale.epub", nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, 103, "Finale", "Zen Author", "Series A", 3, "en", "" },
            { "/library/Series-A/", "Loose.epub", nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, 104, "Loose", "Zen Author", nil, nil, "en", "" },
        }
        local fc = chooser()
        alpha.doc_props = { title = "Alpha", series = "Series A", series_index = 1 }

        local items = { alpha, finale, loose, no_cover }
        FileChooser.switchItemTable(fc, nil, items)

        assert.are.equal(2, #fc.item_table)
        local group = fc.item_table[1]
        assert.are.equal("Series A", group.text)
        assert.are.same({ alpha, no_cover, finale }, group.series_items)
        assert.are.equal("Alpha", alpha.doc_props.title)
        assert.are.equal("Zen Author", finale.doc_props.authors)
        assert.are.equal(0, doc_props_lookups)
        assert.are.equal(1, directory_prefetches)

        FileChooser.switchItemTable(fc, nil, items)
        assert.are.same({ alpha, no_cover, finale }, fc.item_table[1].series_items)
        assert.are.equal(1, directory_prefetches)
        assert.are.equal(0, doc_props_lookups)
    end)

    it("keeps batch metadata after CoverBrowser closes the database connection", function()
        cached_rows = {
            { "/library/Series-A/", "01 - Alpha.epub", nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, 101, "Alpha", "Zen Author", "Series A", 1, "en", "" },
            { "/library/Series-A/", "02 - Beta.epub", nil, nil, nil, nil, nil, nil,
                nil, nil, nil, nil, 102, "Beta", "Zen Author", "Series A", 2, "en", "" },
        }
        local function fresh_items()
            return { item("/library/Series-A/01 - Alpha.epub", "01 - Alpha"),
                item("/library/Series-A/02 - Beta.epub", "02 - Beta") }
        end
        local BookInfoManager = require("bookinfomanager")
        FileChooser.switchItemTable(chooser(), nil, fresh_items())
        BookInfoManager:closeDbConnection() -- KOReader does this before every extraction
        FileChooser.switchItemTable(chooser(), nil, fresh_items())

        assert.are.equal(2, directory_prefetches)
        assert.are.equal(0, doc_props_lookups)
    end)

    it("does not create a redundant group when every book belongs to one series", function()
        local first = item("/library/One.epub", "One")
        local second = item("/library/Two.epub", "Two")
        metadata[first.path] = { series = "Only", series_index = 1 }
        metadata[second.path] = { series = "Only", series_index = 2 }
        local fc = chooser()

        FileChooser.switchItemTable(fc, nil, { first, second })

        assert.are.same({ first, second }, fc.item_table)
    end)

    it("hides a series group when none of its books match the status filter", function()
        local first = item("/library/One.epub", "One")
        local second = item("/library/Two.epub", "Two")
        local reading = item("/library/Reading.epub", "Reading")
        metadata[first.path] = { series = "Finished", series_index = 1 }
        metadata[second.path] = { series = "Finished", series_index = 2 }
        statuses[first.path] = "complete"
        statuses[second.path] = "complete"
        statuses[reading.path] = "reading"
        FileChooser.show_filter = { status = { reading = true } }
        local fc = chooser()

        FileChooser.switchItemTable(fc, nil, { first, second, reading })

        assert.are.same({ reading }, fc.item_table)
    end)

    it("hides multi-book grouped series while retaining loose and single-series books", function()
        local first = item("/library/One.epub", "One")
        local second = item("/library/Two.epub", "Two")
        local single = item("/library/Single.epub", "Single")
        local loose = item("/library/Loose.epub", "Loose")
        local folder = { text = "Folder", path = "/library/Folder", is_directory = true,
            attr = { mode = "directory" } }
        local up = { text = "..", is_go_up = true, is_directory = true,
            attr = { mode = "directory" } }
        metadata[first.path] = { series = "Saga", series_index = 1 }
        metadata[second.path] = { series = "Saga", series_index = 2 }
        metadata[single.path] = { series = "Solo", series_index = 1 }
        _G.__ZEN_UI_PLUGIN.config.features.hide_grouped_series = true
        local fc = chooser()

        FileChooser.switchItemTable(fc, nil, { up, first, second, single, loose, folder })

        assert.are.equal(4, #fc.item_table)
        local visible = {}
        for _i, entry in ipairs(fc.item_table) do visible[entry] = true end
        assert.is_true(visible[loose])
        assert.is_true(visible[folder])
        assert.is_true(visible[single])
        assert.is_true(visible[up])
    end)

    it("hides the only series in a folder", function()
        local first = item("/library/One.epub", "One")
        local second = item("/library/Two.epub", "Two")
        metadata[first.path] = { series = "Only", series_index = 1 }
        metadata[second.path] = { series = "Only", series_index = 2 }
        _G.__ZEN_UI_PLUGIN.config.features.hide_grouped_series = true
        local fc = chooser()

        FileChooser.switchItemTable(fc, nil, { first, second })

        assert.are.same({}, fc.item_table)
    end)

    it("does not add virtual folders to path picker dialogs", function()
        local first = item("/library/One.epub", "One")
        local second = item("/library/Two.epub", "Two")
        local loose = item("/library/Loose.epub", "Loose")
        metadata[first.path] = { series = "Saga", series_index = 1 }
        metadata[second.path] = { series = "Saga", series_index = 2 }
        local fc = chooser()
        fc.select_file = true
        fc.select_directory = false

        FileChooser.switchItemTable(fc, nil, { first, second, loose })

        assert.are.same({ first, second, loose }, fc.item_table)
        assert.is_nil(fc.item_table[1].is_series_group)
    end)

    it("opens a virtual series folder and returns to its parent", function()
        local first = item("/library/One.epub", "One")
        local second = item("/library/Two.epub", "Two")
        local loose = item("/library/Loose.epub", "Loose")
        metadata[first.path] = { series = "Saga", series_index = 1 }
        metadata[second.path] = { series = "Saga", series_index = 2 }
        local fc = chooser()
        FileChooser.switchItemTable(fc, nil, { first, second, loose })
        local group = fc.item_table[1]

        assert.is_true(FileChooser.onMenuSelect(fc, group))
        assert.is_true(fc.item_table.is_in_series_view)
        assert.are.equal("/library", fc.item_table.parent_path)
        assert.is_true(fc.item_table[1].is_go_up)
        assert.are.same({ first, second }, { fc.item_table[2], fc.item_table[3] })
        assert.are.equal("Saga", fc.subtitle)
        assert.are.equal(0, original_select_calls)

        assert.is_true(FileChooser.onFolderUp(fc))
        assert.are.equal("/library", fc.changed_to)
    end)

    it("preserves the parent page while reordering an open virtual folder", function()
        local first = item("/library/One.epub", "One")
        local second = item("/library/Two.epub", "Two")
        local loose = item("/library/Loose.epub", "Loose")
        metadata[first.path] = { series = "Saga", series_index = 1 }
        metadata[second.path] = { series = "Saga", series_index = 2 }
        metadata[loose.path] = { title = "Loose" }
        local parent_items = { first, second, loose }
        local fc = chooser()
        fc.page = 4
        fc.perpage = 9
        fc.path_items["/library"] = 28
        FileChooser.switchItemTable(fc, nil, parent_items)
        local group = fc.item_table[1]
        FileChooser.onMenuSelect(fc, group)

        fc.page = 2
        fc.perpage = 3
        fc._test_parent_items = parent_items
        assert.is_true(fc:_zen_resort_series_group(group, true))
        assert.are.equal(2, fc.page)

        assert.is_true(FileChooser.onFolderUp(fc))
        assert.are.equal(4, fc.page)
        assert.are.equal(-1, fc.switched_itemnumber)
        assert.are.equal("/library", fc.changed_to)
    end)

    it("preserves the captured parent page across a virtual refresh and reopen", function()
        local first = item("/library/One.epub", "One")
        local second = item("/library/Two.epub", "Two")
        local loose = item("/library/Loose.epub", "Loose")
        metadata[first.path] = { series = "Saga", series_index = 1 }
        metadata[second.path] = { series = "Saga", series_index = 2 }
        metadata[loose.path] = { title = "Loose" }
        local parent_items = { first, second, loose }
        local fc = chooser()
        fc.page = 4
        FileChooser.switchItemTable(fc, nil, parent_items)
        FileChooser.onMenuSelect(fc, fc.item_table[1])
        fc._test_refresh_items = parent_items
        fc._test_parent_items = parent_items

        FileChooser.refreshPath(fc)
        assert.is_true(fc.item_table.is_in_series_view)
        assert.is_true(FileChooser.onFolderUp(fc))

        assert.are.equal(4, fc.page)
        assert.are.equal("/library", fc.changed_to)
    end)

    it("clears virtual state when refresh dissolves the series group", function()
        local first = item("/library/One.epub", "One")
        local second = item("/library/Two.epub", "Two")
        local loose = item("/library/Loose.epub", "Loose")
        metadata[first.path] = { series = "Saga", series_index = 1 }
        metadata[second.path] = { series = "Saga", series_index = 2 }
        metadata[loose.path] = { title = "Loose" }
        local fc = chooser()
        FileChooser.switchItemTable(fc, nil, { first, second, loose })
        FileChooser.onMenuSelect(fc, fc.item_table[1])
        fc._test_refresh_items = { loose }
        local file_manager = require("apps/filemanager/filemanager").instance
        file_manager.updated = nil

        FileChooser.refreshPath(fc)
        local title_bar = {}
        TitleBar.setSubTitle(title_bar, "Library")

        assert.are.same({ loose }, fc.item_table)
        assert.are.equal("Library", title_bar.subtitle)
        assert.is_true(file_manager.updated)
    end)

    it("leaves ordinary selection and disabled grouping to KOReader", function()
        local fc = chooser()
        local cache_clear_calls = 0
        fc._zen_clear_item_table_cache = function()
            cache_clear_calls = cache_clear_calls + 1
        end
        local ordinary = item("/library/Plain.epub", "Plain")
        assert.are.equal("selected", FileChooser.onMenuSelect(fc, ordinary))
        assert.are.equal(1, original_select_calls)

        _G.__ZEN_UI_PLUGIN.config.features.automatic_series_grouping = false
        metadata[ordinary.path] = { series = "Saga", series_index = 1 }
        FileChooser.switchItemTable(fc, nil, { ordinary })
        assert.are.same({ ordinary }, fc.item_table)

        FileChooser.refreshPath(fc)
        assert.are.equal(1, original_refresh_calls)
        assert.are.equal(0, cache_clear_calls)
    end)
end)
