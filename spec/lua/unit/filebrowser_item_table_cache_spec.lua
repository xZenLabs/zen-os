describe("file browser item-table cache", function()
    local FileChooser
    local generated
    local saved_modules
    local saved_settings
    local saved_plugin
    local collate_mode
    local mixed
    local setting_values
    local history_times
    local descendant_times
    local source_items
    local directory_mtime
    local directory_entries
    local directory_mtimes
    local persisted_store
    local scheduled
    local filename_wrap
    local directory_wrap
    local home_invalidations
    local fake_now
    local attributes_calls

    local module_names = {
        "common/cover_utils",
        "ui/widget/container/alphacontainer", "ui/bidi", "ffi/blitbuffer",
        "ui/widget/container/bottomcontainer", "ui/widget/container/centercontainer",
        "device", "ui/widget/filechooser", "ui/widget/container/framecontainer",
        "ui/widget/horizontalgroup", "ui/widget/horizontalspan", "ui/widget/imagewidget",
        "ui/widget/container/leftcontainer", "ui/widget/linewidget",
        "ui/widget/overlapgroup", "ui/widget/container/rightcontainer", "ui/size",
        "ui/widget/textboxwidget", "ui/widget/textwidget", "ui/widget/container/topcontainer",
        "ui/widget/verticalgroup", "ui/widget/verticalspan", "ffi/util",
        "libs/libkoreader-lfs", "common/history_index", "common/zen_logger",
        "common/paths", "modules/filebrowser/patches/library_font", "common/utils",
        "gettext", "apps/filemanager/filemanager", "luasettings",
        "config/preset_store", "ui/uimanager", "version",
        "common/shared_state",
    }

    local function new_filechooser_class()
        return {
            collates = {
                title = { id = "title" },
                access = {
                    id = "access",
                    can_collate_mixed = true,
                    mandatory_func = function() return "2026-08-01 12:00" end,
                },
            },
            getCollate = function(self)
                return self.collates[collate_mode], collate_mode
            end,
            getMenuItemMandatory = function(_self, item, collate)
                return collate.mandatory_func(item)
            end,
            getListItem = function(self, _dirpath, filename, fullpath, attributes)
                return {
                    text = filename, path = fullpath, attr = attributes,
                    dim = self.ui and self.ui.selected_files[fullpath],
                }
            end,
            genItemTableFromPath = function(_self, path)
                generated[path] = (generated[path] or 0) + 1
                return source_items[path] or { { path = path } }
            end,
        }
    end

    local function apply_new_filechooser()
        FileChooser = new_filechooser_class()
        ZenSpec.replace("ui/widget/filechooser", FileChooser)
        ZenSpec.unload("modules/filebrowser/patches/browser_item_table_cache")
        require("modules/filebrowser/patches/browser_item_table_cache")()
        return setmetatable({ name = "filemanager" }, { __index = FileChooser })
    end

    local function run_scheduled()
        while #scheduled > 0 do
            local pending = scheduled
            scheduled = {}
            for _i, callback in ipairs(pending) do callback() end
        end
    end

    before_each(function()
        generated = {}
        collate_mode = "title"
        mixed = false
        setting_values = {}
        history_times = {}
        descendant_times = {}
        source_items = {}
        directory_mtime = 1
        directory_entries = {}
        directory_mtimes = {}
        persisted_store = {
            data = {},
            flush = function(self) self.flushed = (self.flushed or 0) + 1 end,
        }
        scheduled = {}
        filename_wrap = function(text) return text end
        directory_wrap = function(text) return text end
        home_invalidations = {}
        fake_now = 0
        attributes_calls = 0
        saved_modules = {}
        for _i, name in ipairs(module_names) do
            saved_modules[name] = package.loaded[name]
        end
        saved_settings = _G.G_reader_settings
        saved_plugin = _G.__ZEN_UI_PLUGIN

        FileChooser = new_filechooser_class()
        ZenSpec.replace("common/cover_utils", { BORDER_SIZE = 2 })
        for _i, name in ipairs({
            "ui/widget/container/alphacontainer", "ui/bidi", "ffi/blitbuffer",
            "ui/widget/container/bottomcontainer", "ui/widget/container/centercontainer",
            "ui/widget/container/framecontainer", "ui/widget/horizontalgroup",
            "ui/widget/horizontalspan", "ui/widget/imagewidget", "ui/widget/container/leftcontainer",
            "ui/widget/linewidget", "ui/widget/overlapgroup", "ui/widget/container/rightcontainer",
            "ui/widget/textboxwidget", "ui/widget/textwidget", "ui/widget/container/topcontainer",
            "ui/widget/verticalgroup", "ui/widget/verticalspan", "common/utils",
        }) do
            ZenSpec.replace(name, {})
        end
        ZenSpec.replace("device", { screen = { scaleBySize = function(_, value) return value end } })
        ZenSpec.replace("ui/widget/filechooser", FileChooser)
        ZenSpec.replace("ui/size", { line = { medium = 1 } })
        ZenSpec.replace("ffi/util", { realpath = function(path) return path end })
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function(path, field)
                attributes_calls = attributes_calls + 1
                local mode = path:match("%.[^/]+$") and "file" or "directory"
                local attr = {
                    mode = mode,
                    modification = directory_mtimes[path] or directory_mtime,
                    change = directory_mtimes[path] or directory_mtime,
                    size = 1,
                    ino = 1,
                }
                return field and attr[field] or attr
            end,
            dir = function(path)
                local entries = { ".", ".." }
                for _i, child in ipairs(directory_entries[path] or {}) do
                    entries[#entries + 1] = child
                end
                local index = 0
                return function()
                    index = index + 1
                    return entries[index]
                end
            end,
        })
        ZenSpec.replace("ui/bidi", { filename = filename_wrap, directory = directory_wrap })
        ZenSpec.replace("common/history_index", {
            load = function() return history_times end,
            fileTime = function(index, path) return index[path] end,
            maxDescendantTimes = function() return descendant_times end,
        })
        ZenSpec.replace("common/zen_logger", {
            now = function() return fake_now end,
            new = function()
                return { measure = function() end, dbg = function() end, warn = function() end }
            end,
        })
        ZenSpec.replace("common/paths", {
            getHomeDir = function() return "/library" end,
            normPath = function(path) return path end,
        })
        ZenSpec.replace("common/shared_state", {
            get = function(_plugin, key)
                if key ~= "home" then return end
                return {
                    invalidateBookCache = function(path, history_changed)
                        home_invalidations[#home_invalidations + 1] = {
                            path = path,
                            history_changed = history_changed,
                        }
                    end,
                }
            end,
        })
        ZenSpec.replace("modules/filebrowser/patches/library_font", {})
        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("apps/filemanager/filemanager", { setupLayout = function() end })
        ZenSpec.replace("luasettings", {
            open = function() return persisted_store end,
        })
        ZenSpec.replace("config/preset_store", {
            rootDir = function() return "/settings/ZenOS" end,
        })
        ZenSpec.replace("ui/uimanager", {
            scheduleIn = function(_self, _delay, callback)
                scheduled[#scheduled + 1] = callback
            end,
            unschedule = function(_self, callback)
                for index = #scheduled, 1, -1 do
                    if scheduled[index] == callback then table.remove(scheduled, index) end
                end
            end,
        })
        ZenSpec.replace("version", { version = "test-koreader" })
        _G.G_reader_settings = {
            readSetting = function(_, key, default)
                if key == "collate" then return collate_mode end
                if setting_values[key] ~= nil then return setting_values[key] end
                return default
            end,
            isTrue = function(_, key)
                if key == "collate_mixed" then return mixed end
                return setting_values[key] == true
            end,
        }
        _G.__ZEN_UI_PLUGIN = {
            version = "test-plugin",
            config = {
                features = { browser_hide_up_folder = true, zen_mode = true },
                browser_hide_up_folder = { hide_up_folder = true, lock_home_folder = "zen" },
            },
        }
        ZenSpec.unload("modules/filebrowser/patches/browser_item_table_cache")
        require("modules/filebrowser/patches/browser_item_table_cache")()
    end)

    after_each(function()
        if FileChooser and FileChooser._zen_cancel_item_table_cache_persist then
            FileChooser:_zen_cancel_item_table_cache_persist()
        end
        ZenSpec.unload("modules/filebrowser/patches/browser_item_table_cache")
        _G.__ZEN_UI_DEFER_FILEMANAGER_LISTING = nil
        _G.__ZEN_UI_LAST_READ_FILE = nil
        for _i, name in ipairs(module_names) do
            package.loaded[name] = saved_modules[name]
        end
        _G.G_reader_settings = saved_settings
        _G.__ZEN_UI_PLUGIN = saved_plugin
    end)

    it("rebuilds item selection state when scanning an unchanged file", function()
        local chooser = setmetatable({
            name = "filemanager", ui = { selected_files = {} },
        }, { __index = FileChooser })
        local attr = { mode = "file", modification = 1 }
        local first = chooser:getListItem("/library", "a.epub", "/library/a.epub", attr,
            FileChooser.collates.title)
        chooser.ui.selected_files["/library/a.epub"] = true
        local second = chooser:getListItem("/library", "a.epub", "/library/a.epub", attr,
            FileChooser.collates.title)
        assert.is_nil(first.dim)
        assert.is_true(second.dim)
    end)

    it("keeps the library root cached while a child folder is open", function()
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })

        chooser:genItemTableFromPath("/library")
        chooser:genItemTableFromPath("/library/series")
        chooser:genItemTableFromPath("/library")

        assert.are.equal(1, generated["/library"])
        assert.are.equal(1, generated["/library/series"])
    end)

    it("refreshes a parent listing when a child folder changes", function()
        directory_mtimes["/library"] = 1
        directory_mtimes["/library/series"] = 1
        source_items["/library"] = {
            {
                text = "series/", path = "/library/series",
                mandatory = "1 \xef\x80\x96", attr = { mode = "directory", modification = 1 },
            },
        }
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })

        local before = chooser:genItemTableFromPath("/library")
        assert.are.equal("1 \xef\x80\x96", before[1].mandatory)

        -- Within the child-validation window the cached listing is reused...
        local quick = chooser:genItemTableFromPath("/library")
        assert.are.equal(1, generated["/library"])
        assert.are.equal(before, quick)

        -- ...and the next full validation detects the changed child folder.
        fake_now = fake_now + 10
        directory_mtimes["/library/series"] = 2
        source_items["/library"] = {
            {
                text = "series/", path = "/library/series",
                mandatory = "2 \xef\x80\x96", attr = { mode = "directory", modification = 2 },
            },
        }
        local after = chooser:genItemTableFromPath("/library")

        assert.are.equal("2 \xef\x80\x96", after[1].mandatory)
        assert.are.equal(2, generated["/library"])
    end)

    it("returns a synthetic empty list only during hidden Home bootstrap", function()
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })
        _G.__ZEN_UI_DEFER_FILEMANAGER_LISTING = { path = "/library" }

        local deferred = chooser:genItemTableFromPath("/library")
        assert.are.same({}, deferred)
        assert.is_nil(generated["/library"])

        _G.__ZEN_UI_DEFER_FILEMANAGER_LISTING = nil
        local materialized = chooser:genItemTableFromPath("/library")
        assert.are.equal(1, #materialized)
        assert.are.equal(1, generated["/library"])
    end)

    it("refreshes cached folders when up-folder visibility changes", function()
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })

        chooser:genItemTableFromPath("/library/series")
        _G.__ZEN_UI_PLUGIN.config.browser_hide_up_folder.hide_up_folder = false
        chooser:genItemTableFromPath("/library/series")

        assert.are.equal(2, generated["/library/series"])
    end)

    it("refreshes cached folders when series visibility changes", function()
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })

        chooser:genItemTableFromPath("/library")
        _G.__ZEN_UI_PLUGIN.config.features.hide_grouped_series = true
        chooser:genItemTableFromPath("/library")
        _G.__ZEN_UI_PLUGIN.config.features.automatic_series_grouping = false
        chooser:genItemTableFromPath("/library")

        assert.are.equal(3, generated["/library"])
    end)

    it("keys listings by stock parent-folder and hold-directory settings", function()
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })

        chooser:genItemTableFromPath("/library/series")
        setting_values.show_parent_folder = false
        chooser:genItemTableFromPath("/library/series")
        chooser.show_current_dir_for_hold = true
        chooser:genItemTableFromPath("/library/series")

        assert.are.equal(3, generated["/library/series"])
    end)

    it("promotes a folder when one of its descendant books is read", function()
        collate_mode = "access"
        mixed = true
        source_items["/library"] = {
            {
                text = "Earlier/", path = "/library/Earlier",
                mandatory = "1 \xef\x80\x96", attr = { mode = "directory", modification = 1 },
            },
            {
                text = "Later/", path = "/library/Later",
                mandatory = "2 \xef\x80\x96", attr = { mode = "directory", modification = 1 },
            },
        }
        descendant_times = {
            ["/library/Earlier"] = 20,
            ["/library/Later"] = 10,
        }
        directory_mtimes["/library/Earlier"] = 1
        directory_mtimes["/library/Later"] = 1
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })

        local before = chooser:genItemTableFromPath("/library")
        assert.are.equal("Earlier/", before[1].text)
        assert.are.equal("1 \xef\x80\x96", before[1].mandatory)

        descendant_times["/library/Later"] = 30
        directory_mtime = 2
        _G.__ZEN_UI_LAST_READ_FILE = "/library/Later/book.epub"
        local stat_base = attributes_calls
        local after = chooser:genItemTableFromPath("/library")

        -- The refresh re-sorts without scanning the child directories again
        -- (only the root signature for the cache key).
        assert.are.equal(1, attributes_calls - stat_base)
        assert.are.equal("Later/", after[1].text)
        assert.are.equal("2 \xef\x80\x96", after[1].mandatory)
        assert.are.equal(1, generated["/library"])
        assert.are.same({ {
            path = "/library/Later/book.epub",
            history_changed = true,
        } }, home_invalidations)
        assert.is_nil(_G.__ZEN_UI_LAST_READ_FILE)
    end)

    it("sorts access collate oldest-first when reverse collate is enabled", function()
        collate_mode = "access"
        mixed = true
        setting_values["reverse_collate"] = true
        source_items["/library"] = {
            {
                text = "Old/", path = "/library/Old",
                mandatory = "1 \xef\x80\x96", attr = { mode = "directory", modification = 1 },
            },
            {
                text = "New/", path = "/library/New",
                mandatory = "2 \xef\x80\x96", attr = { mode = "directory", modification = 1 },
            },
        }
        descendant_times = {
            ["/library/Old"] = 10,
            ["/library/New"] = 20,
        }
        directory_mtimes["/library/Old"] = 1
        directory_mtimes["/library/New"] = 1
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })

        local result = chooser:genItemTableFromPath("/library")
        assert.are.equal("Old/", result[1].text)
        assert.are.equal("New/", result[2].text)

        -- Memory-hit refresh re-applies the order without regenerating.
        local second = chooser:genItemTableFromPath("/library")
        assert.are.equal(1, generated["/library"])
        assert.are.equal("Old/", second[1].text)
        assert.are.equal("New/", second[2].text)
    end)

    it("restores a scalar-only listing snapshot in a fresh cache instance", function()
        source_items["/library"] = {
            {
                text = "Book.epub", path = "/library/Book.epub",
                attr = { mode = "file", modification = 7, size = 12 },
                is_file = true, bidi_wrap_func = filename_wrap,
            },
        }
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })

        chooser:genItemTableFromPath("/library")
        run_scheduled()
        assert.are.equal(1, generated["/library"])
        local saved = persisted_store.data.values["/library"].table[1]
        assert.is_nil(saved.bidi_wrap_func)
        assert.are.same({ mode = "file", modification = 7, size = 12 }, saved.attr)

        local restored_chooser = apply_new_filechooser()
        local restored = restored_chooser:genItemTableFromPath("/library")
        assert.are.equal(1, generated["/library"])
        assert.are.equal(filename_wrap, restored[1].bidi_wrap_func)
        assert.are.equal("disk_hit",
            restored_chooser._zen_last_item_table_cache_result.cache)
    end)

    it("rejects stale and incompatible persisted snapshots", function()
        source_items["/library"] = {
            { text = "Book.epub", path = "/library/Book.epub", is_file = true },
        }
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })
        chooser:genItemTableFromPath("/library")
        run_scheduled()

        directory_mtime = 2
        local stale_chooser = apply_new_filechooser()
        stale_chooser:genItemTableFromPath("/library")
        assert.are.equal(2, generated["/library"])
        run_scheduled()

        _G.__ZEN_UI_PLUGIN.version = "next-plugin"
        local incompatible_chooser = apply_new_filechooser()
        incompatible_chooser:genItemTableFromPath("/library")
        assert.are.equal(3, generated["/library"])
        assert.are.equal("miss",
            incompatible_chooser._zen_last_item_table_cache_result.cache)
    end)

    it("rejects a persisted root when a depth-two directory changed", function()
        directory_entries["/library"] = { "series" }
        directory_entries["/library/series"] = { "volume" }
        directory_entries["/library/series/volume"] = { "Book.epub" }
        directory_mtimes["/library"] = 1
        directory_mtimes["/library/series"] = 1
        directory_mtimes["/library/series/volume"] = 1
        source_items["/library"] = {
            {
                text = "series/", path = "/library/series",
                attr = { mode = "directory", modification = 1 },
            },
        }
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })
        chooser:genItemTableFromPath("/library")
        run_scheduled()

        directory_mtimes["/library/series/volume"] = 2
        local restored_chooser = apply_new_filechooser()
        restored_chooser:genItemTableFromPath("/library")

        assert.are.equal(2, generated["/library"])
        assert.are.equal("miss", restored_chooser._zen_last_item_table_cache_result.cache)
    end)

    it("keeps a root-validated snapshot when the tree exceeds signature bounds", function()
        directory_entries["/library"] = {}
        for index = 1, 257 do
            directory_entries["/library"][index] = "folder" .. index
        end
        source_items["/library"] = {
            { text = "Book.epub", path = "/library/Book.epub", is_file = true },
        }
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })

        chooser:genItemTableFromPath("/library")
        run_scheduled()

        local saved = persisted_store.data.values["/library"]
        assert.is_not_nil(saved)
        assert.are.equal("root", saved.tree_signature_mode)
        assert.are.equal(1, #persisted_store.data.order)

        local restored_chooser = apply_new_filechooser()
        local restored = restored_chooser:genItemTableFromPath("/library")
        assert.are.equal(1, #restored)
        assert.are.equal(1, generated["/library"])
        assert.are.equal("disk_hit",
            restored_chooser._zen_last_item_table_cache_result.cache)
    end)

    it("rejects a root-validated snapshot when the root changes", function()
        directory_entries["/library"] = {}
        for index = 1, 257 do
            directory_entries["/library"][index] = "folder" .. index
        end
        source_items["/library"] = {
            { text = "Book.epub", path = "/library/Book.epub", is_file = true },
        }
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })
        chooser:genItemTableFromPath("/library")
        run_scheduled()

        directory_mtime = 2
        local restored_chooser = apply_new_filechooser()
        restored_chooser:genItemTableFromPath("/library")

        assert.are.equal(2, generated["/library"])
        assert.are.equal("miss", restored_chooser._zen_last_item_table_cache_result.cache)
    end)

    it("rejects a root-only snapshot for recursive flat view", function()
        directory_entries["/library"] = {}
        for index = 1, 257 do
            directory_entries["/library"][index] = "folder" .. index
        end
        source_items["/library"] = {
            { text = "Book.epub", path = "/library/Book.epub", is_file = true },
        }
        local chooser = setmetatable({
            name = "filemanager",
            show_flat_view = true,
        }, { __index = FileChooser })

        chooser:genItemTableFromPath("/library")
        run_scheduled()

        assert.is_nil(persisted_store.data.values["/library"])
        assert.are.equal(0, #persisted_store.data.order)
    end)

    it("ignores sidecar directories while building a full tree signature", function()
        directory_entries["/library"] = { "series" }
        for index = 1, 300 do
            directory_entries["/library"][#directory_entries["/library"] + 1] =
                "Book" .. index .. ".sdr"
        end
        source_items["/library"] = {
            { text = "Book.epub", path = "/library/Book.epub", is_file = true },
        }
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })

        chooser:genItemTableFromPath("/library")
        run_scheduled()

        local saved = persisted_store.data.values["/library"]
        assert.is_not_nil(saved)
        assert.are.equal("full", saved.tree_signature_mode)

        local restored_chooser = apply_new_filechooser()
        restored_chooser:genItemTableFromPath("/library")
        assert.are.equal(1, generated["/library"])
        assert.are.equal("disk_hit",
            restored_chooser._zen_last_item_table_cache_result.cache)
        assert.are.equal("full",
            restored_chooser._zen_last_item_table_cache_result.signature_mode)
    end)

    it("does not restore or write snapshots while a status filter is active", function()
        source_items["/library"] = {
            { text = "All.epub", path = "/library/All.epub", is_file = true },
        }
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })
        chooser:genItemTableFromPath("/library")
        run_scheduled()

        source_items["/library"] = {
            { text = "Reading.epub", path = "/library/Reading.epub", is_file = true },
        }
        local filtered_chooser = apply_new_filechooser()
        FileChooser.show_filter = { status = { reading = true } }
        local filtered = filtered_chooser:genItemTableFromPath("/library")
        run_scheduled()

        assert.are.equal(2, generated["/library"])
        assert.are.equal("Reading.epub", filtered[1].text)
        assert.are.equal("miss", filtered_chooser._zen_last_item_table_cache_result.cache)
        assert.are.equal("All.epub", persisted_store.data.values["/library"].table[1].text)
    end)

    it("does not persist item tables containing runtime objects", function()
        source_items["/library"] = {
            {
                text = "Book.epub", path = "/library/Book.epub", is_file = true,
                callback = function() end,
            },
        }
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })

        chooser:genItemTableFromPath("/library")
        run_scheduled()

        assert.is_nil(persisted_store.data.values)
        assert.are.equal(1, generated["/library"])
    end)

    it("warms only the item table and reports whether the listing was reused", function()
        source_items["/library"] = {
            { text = "Book.epub", path = "/library/Book.epub", is_file = true },
        }
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })

        local first, first_detail = chooser:_zen_warm_item_table("/library")
        local second, second_detail = chooser:_zen_warm_item_table("/library")

        assert.are.equal(1, #first)
        assert.are.equal(1, #second)
        assert.are.equal("miss", first_detail.cache)
        assert.are.equal("memory_hit", second_detail.cache)
        assert.are.equal(1, generated["/library"])
    end)

    it("hands a warmed listing to the next generation exactly once", function()
        source_items["/library"] = {
            { text = "Book.epub", path = "/library/Book.epub", is_file = true },
        }
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })
        local warmed = chooser:_zen_warm_item_table("/library")

        assert.is_true(chooser:_zen_prepare_item_table("/library", warmed))
        local prepared = chooser:genItemTableFromPath("/library")
        assert.is_true(rawequal(warmed, prepared))
        assert.are.equal("prepared", chooser._zen_last_item_table_cache_result.cache)
        assert.is_nil(chooser._zen_prepared_item_table)

        local cached = chooser:genItemTableFromPath("/library")
        assert.is_true(rawequal(warmed, cached))
        assert.are.equal("memory_hit", chooser._zen_last_item_table_cache_result.cache)
        assert.are.equal(1, generated["/library"])
    end)

    it("rejects a prepared listing when its generation key changes", function()
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })
        local warmed = chooser:_zen_warm_item_table("/library")
        assert.is_true(chooser:_zen_prepare_item_table("/library", warmed))

        mixed = true
        chooser:genItemTableFromPath("/library")

        assert.are.equal("miss", chooser._zen_last_item_table_cache_result.cache)
        assert.are.equal(2, generated["/library"])
        assert.is_nil(chooser._zen_prepared_item_table)
    end)

    it("clears a matching prepared listing during path invalidation", function()
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })
        local warmed = chooser:_zen_warm_item_table("/library")
        assert.is_true(chooser:_zen_prepare_item_table("/library", warmed))

        assert.is_true(chooser:_zen_invalidate_item_table_path("/library"))
        assert.is_nil(chooser._zen_prepared_item_table)
        chooser:genItemTableFromPath("/library")
        assert.are.equal(2, generated["/library"])
    end)

    it("invalidates only the requested listing snapshot", function()
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })
        chooser:_zen_warm_item_table("/library")
        chooser:_zen_warm_item_table("/library/series")

        assert.is_true(chooser:_zen_invalidate_item_table_path("/library"))
        chooser:_zen_warm_item_table("/library")
        chooser:_zen_warm_item_table("/library/series")

        assert.are.equal(2, generated["/library"])
        assert.are.equal(1, generated["/library/series"])
    end)

    it("debounces snapshot writes and cancels them before cleanup", function()
        local chooser = setmetatable({ name = "filemanager" }, { __index = FileChooser })
        chooser:genItemTableFromPath("/library")
        chooser:_zen_clear_item_table_cache()
        chooser:_zen_clear_item_table_cache()

        assert.are.equal(1, #scheduled)
        assert.is_nil(persisted_store.flushed)
        chooser:_zen_cancel_item_table_cache_persist()
        persisted_store.data = { removed = true }
        run_scheduled()

        assert.is_nil(persisted_store.flushed)
        assert.are.same({ removed = true }, persisted_store.data)
    end)
end)
