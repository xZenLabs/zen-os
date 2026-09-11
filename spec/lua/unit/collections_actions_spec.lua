describe("ZenOS collection actions", function()
    local SortFixtures = require("sort_fixtures")
    local FileManagerCollection
    local collection_fixture
    local collection_manager
    local file_dialog_args
    local shown_dialog
    local collection_writes
    local tbr_collection_name
    local shared_collections
    local renamed
    local removed
    local saved_modules
    local replaced_modules = {
        "gettext",
        "common/zen_logger",
        "common/inline_icon_map",
        "common/cover_utils",
        "modules/filebrowser/patches/library_font",
        "common/ui/background",
        "common/shared_state",
        "common/tbr_index",
        "readcollection",
        "apps/filemanager/filemanagercollection",
        "apps/filemanager/filemanager",
        "ui/widget/menu",
        "ui/widget/buttondialog",
        "ui/uimanager",
        "ui/widget/booklist",
        "device",
    }

    local function install_collections_patch()
        file_dialog_args = nil
        shown_dialog = nil
        collection_writes = 0
        tbr_collection_name = "To Be Read"
        shared_collections = nil
        collection_fixture = SortFixtures.new()
        renamed = {}
        removed = {}

        FileManagerCollection = {
            onShowColl = function() end,
            onShowCollList = function(self)
                self.coll_list = {}
            end,
            updateCollListItemTable = function() end,
            renameCollection = function(_self, item)
                renamed[#renamed + 1] = item.name
            end,
            removeCollection = function(_self, item)
                removed[#removed + 1] = item.name
            end,
        }
        collection_manager = setmetatable({}, { __index = FileManagerCollection })

        ZenSpec.replace("gettext", function(text) return text end)
        ZenSpec.replace("common/zen_logger", {
            new = function()
                return { dbg = function() end }
            end,
        })
        ZenSpec.replace("common/inline_icon_map", {
            rename = "rename",
            delete = "delete",
            filename = "filename",
            arrow_right = ">",
        })
        ZenSpec.replace("common/cover_utils", {})
        ZenSpec.replace("modules/filebrowser/patches/library_font", {
            scaleValue = function(value) return value end,
            getFontName = function() return "sans" end,
        })
        ZenSpec.replace("common/ui/background", { applyToMenu = function() end })
        ZenSpec.replace("common/shared_state", {
            get = function() end,
            register = function(_plugin, entries)
                shared_collections = entries.collections
            end,
        })
        ZenSpec.replace("common/tbr_index", {
            collectionName = function() return tbr_collection_name end,
        })
        local reading_entries = {}
        for _i, entry in ipairs(collection_fixture.entries) do
            reading_entries[entry.file] = entry
        end
        ZenSpec.replace("readcollection", {
            default_collection_name = "favorites",
            coll = {
                favorites = {},
                ["To Be Read"] = {},
                Reading = reading_entries,
            },
            coll_settings = {
                favorites = {},
                ["To Be Read"] = {},
                Reading = {},
            },
            write = function()
                collection_writes = collection_writes + 1
            end,
        })
        ZenSpec.replace("apps/filemanager/filemanagercollection", FileManagerCollection)
        ZenSpec.replace("apps/filemanager/filemanager", {
            instance = {
                collections = collection_manager,
                bookinfo = {
                    getDocProps = function(_self, path)
                        return collection_fixture.metadata[path]
                    end,
                },
                file_chooser = {
                    showFileDialog = function(_self, args)
                        file_dialog_args = args
                    end,
                },
            },
        })
        ZenSpec.replace("ui/widget/menu", { init = function() end })
        ZenSpec.replace("ui/widget/buttondialog", {
            new = function(_self, spec) return spec end,
        })
        ZenSpec.replace("ui/uimanager", {
            close = function() end,
            show = function(_self, widget) shown_dialog = widget end,
            setDirty = function() end,
        })
        ZenSpec.replace("ui/widget/booklist", {
            collates = SortFixtures.collates(collection_fixture.metadata),
        })
        ZenSpec.replace("device", { isTouchDevice = function() return false end })

        _G.__ZEN_UI_PLUGIN = { config = { features = { collections = true } } }
        ZenSpec.unload("modules/filebrowser/patches/collections")
        require("modules/filebrowser/patches/collections")()
        collection_manager:onShowCollList()
    end

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(replaced_modules) do
            saved_modules[name] = package.loaded[name] or false
        end
        install_collections_patch()
    end)

    after_each(function()
        _G.__ZEN_UI_PLUGIN = nil
        ZenSpec.unload("modules/filebrowser/patches/collections")
        for _i, name in ipairs(replaced_modules) do
            package.loaded[name] = saved_modules[name] or nil
        end
    end)

    it("allows rename but omits delete for To Be Read", function()
        assert.is_true(collection_manager.coll_list:onMenuHold({ name = "To Be Read" }))
        assert.are.equal(1, #file_dialog_args._zen_prepend_buttons)
        assert.is_truthy(file_dialog_args._zen_prepend_buttons[1][1].text:find(
            "Rename", 1, true))
        assert.are.equal(1, #file_dialog_args._zen_extra_buttons)
        assert.is_truthy(file_dialog_args._zen_extra_buttons[1][1].text:find(
            "Connect folders", 1, true))

        collection_manager.booklist_menu = { path = "To Be Read" }
        collection_manager.setCollate = function(self)
            self.set_collate_calls = (self.set_collate_calls or 0) + 1
        end
        collection_manager.updateItemTable = function(self)
            self.update_item_calls = (self.update_item_calls or 0) + 1
        end
        assert.is_true(shared_collections.refreshTBRCollection())
        assert.are.equal(1, collection_manager.set_collate_calls)
        assert.are.equal(1, collection_manager.update_item_calls)
    end)

    it("retains rename and delete actions for ordinary collections", function()
        assert.is_true(collection_manager.coll_list:onMenuHold({ name = "Reading" }))
        assert.are.equal(1, #file_dialog_args._zen_prepend_buttons)
        assert.are.equal(2, #file_dialog_args._zen_extra_buttons)
        assert.is_truthy(file_dialog_args._zen_prepend_buttons[1][1].text:find(
            "Rename", 1, true))
        assert.is_truthy(file_dialog_args._zen_extra_buttons[2][1].text:find(
            "Delete collection", 1, true))
    end)

    it("keeps a renamed To Be Read collection protected from deletion", function()
        tbr_collection_name = "Later"
        assert.is_true(collection_manager.coll_list:onMenuHold({ name = "Later" }))
        assert.are.equal(1, #file_dialog_args._zen_prepend_buttons)
        assert.are.equal(1, #file_dialog_args._zen_extra_buttons)

        collection_manager:renameCollection({ name = "Later" })
        collection_manager:removeCollection({ name = "Later" })
        assert.are.same({ "Later" }, renamed)
        assert.are.same({}, removed)
    end)

    it("offers and saves filename sorting for collections", function()
        assert.is_true(collection_manager.coll_list:onMenuHold({ name = "Reading" }))
        file_dialog_args._zen_sort_cb()

        assert.are.equal("Sort collection by", shown_dialog.title)
        assert.are.equal(">", shown_dialog.buttons[8][1].text:sub(-1))
        local filename_button
        for _i, row in ipairs(shown_dialog.buttons) do
            local button = row[1]
            if button and button.text and button.text:find("Filename", 1, true) then
                filename_button = button
                break
            end
        end
        assert.is_table(filename_button)
        filename_button.callback()

        assert.are.equal("strcoll", package.loaded.readcollection.coll_settings.Reading.collate)
        assert.are.equal(1, collection_writes)
    end)

    it("applies every collection sort method in forward and reverse order", function()
        local ReadCollection = package.loaded.readcollection
        local methods = {
            "title", "title_natural", "strcoll", "authors", "series", "access", "keywords",
        }
        for _i, method in ipairs(methods) do
            for _j, reverse in ipairs({ false, true }) do
                ReadCollection.coll_settings.Reading.collate = method
                ReadCollection.coll_settings.Reading.collate_reverse = reverse or nil
                assert.is_true(collection_manager.coll_list:onMenuHold({ name = "Reading" }))
                local expected = reverse and SortFixtures.reversed(collection_fixture.expected[method])
                    or collection_fixture.expected[method]
                assert.are.same(expected, file_dialog_args._zen_group_files,
                    method .. " reverse=" .. tostring(reverse))
            end
        end
    end)

    it("allows direct rename but rejects delete calls for To Be Read", function()
        collection_manager:renameCollection({ name = "To Be Read" })
        collection_manager:removeCollection({ name = "To Be Read" })
        collection_manager:renameCollection({ name = "Reading" })
        collection_manager:removeCollection({ name = "Reading" })

        assert.are.same({ "To Be Read", "Reading" }, renamed)
        assert.are.same({ "Reading" }, removed)
    end)
end)
