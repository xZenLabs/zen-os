describe("archive actions", function()
    local saved
    local moves
    local locations
    local shown
    local archive_path
    local source_in_archive
    local kindle_book

    before_each(function()
        ZenSpec.unload("common/archive_actions")
        saved = {
            archive_dir_path = "/archive/",
            library_archive_original_dirs = {},
        }
        moves = {}
        locations = {}
        shown = {}
        archive_path = "/archive"
        source_in_archive = false
        kindle_book = false
        _G.G_reader_settings = {
            readSetting = function(_, key)
                if key == "home_dir" then return "/library/" end
            end,
        }

        ZenSpec.replace("datastorage", {
            getSettingsDir = function() return "/settings" end,
        })
        ZenSpec.replace("docsettings", {
            updateLocation = function(source, destination)
                locations[#locations + 1] = { source, destination }
            end,
        })
        ZenSpec.replace("apps/filemanager/filemanager", {
            moveFile = function(_, source, destination)
                moves[#moves + 1] = { source, destination }
                return true
            end,
        })
        ZenSpec.replace("ui/widget/infomessage", {
            new = function(_, options) return options end,
        })
        ZenSpec.replace("ui/widget/confirmbox", {
            new = function(_, options) return options end,
        })
        ZenSpec.replace("luasettings", {
            open = function()
                return {
                    readSetting = function(_, key) return saved[key] end,
                    saveSetting = function(_, key, value) saved[key] = value end,
                    flush = function() end,
                }
            end,
        })
        ZenSpec.replace("ui/uimanager", {
            show = function(_, widget) shown[#shown + 1] = widget end,
            close = function() end,
            nextTick = function(_, fn) fn() end,
            setDirty = function() end,
        })
        ZenSpec.replace("ui/widget/pathchooser", {
            new = function(_, options) return options end,
        })
        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function(path, attribute)
                local modes = {
                    ["/archive/"] = "directory",
                    ["/library"] = "directory",
                    ["/library/"] = "directory",
                    ["/library/book.epub"] = "file",
                    ["/archive/book.epub"] = "file",
                }
                if path == "/archive/book.epub" and not source_in_archive
                        and #moves == 0 then
                    return nil
                end
                if path == "/library/book.epub" and source_in_archive
                        and #moves == 0 then
                    return nil
                end
                local mode = modes[path]
                return attribute and mode or (mode and { mode = mode })
            end,
        })
        ZenSpec.replace("common/paths", {
            getArchiveDir = function() return archive_path end,
            getHomeDir = function() return "/library" end,
            normPath = function(path) return path:gsub("//+", "/"):gsub("/$", "") end,
        })
        ZenSpec.replace("modules/filebrowser/patches/kindle_virtual_library", {
            isBookPath = function() return kindle_book end,
        })
        ZenSpec.replace("util", {
            splitFilePathName = function(path)
                return path:match("^(.-)([^/]+)$")
            end,
        })
        ZenSpec.replace("readhistory", {
            updateItem = function() end,
        })
        ZenSpec.replace("readcollection", {
            updateItem = function() end,
        })
    end)

    after_each(function()
        _G.G_reader_settings = nil
        _G.__ZEN_UI_ARCHIVE_LISTING_DIRTY = nil
        _G.__ZEN_UI_REFRESH_SETTINGS = nil
    end)

    it("moves a library book to the stock archive and remembers its folder", function()
        local ArchiveActions = require("common/archive_actions")
        local fm = {
            file_chooser = {},
            onRefresh = function() end,
        }
        local row = ArchiveActions.contextRow(
            fm, "/library/book.epub", true)

        assert.is_table(row)
        assert.are.equal("\u{F19C}  Archive", row[1].text)
        row[1].callback()
        assert.are.equal("Archive this book?", shown[1].text)
        assert.are.equal("Archive", shown[1].ok_text)
        assert.are.same({}, moves)
        shown[1].ok_callback()
        assert.are.same({
            { "/library/book.epub", "/archive/" },
        }, moves)
        assert.are.same({
            { "/library/book.epub", "/archive/book.epub" },
        }, locations)
        assert.are.equal(
            "/library/",
            saved.library_archive_original_dirs["/archive/book.epub"])
        assert.is_true(_G.__ZEN_UI_ARCHIVE_LISTING_DIRTY)
    end)

    it("hides archive actions for Kindle Library books", function()
        kindle_book = true
        local ArchiveActions = require("common/archive_actions")
        local fm = { file_chooser = {}, onRefresh = function() end }

        assert.is_nil(ArchiveActions.contextRow(fm, "/library/book.epub", true))
        assert.is_false(ArchiveActions.canArchive("/library/book.epub"))
    end)

    it("saves a newly chosen archive and requests a live settings refresh", function()
        archive_path = nil
        local refreshes = 0
        _G.__ZEN_UI_REFRESH_SETTINGS = function() refreshes = refreshes + 1 end
        local ArchiveActions = require("common/archive_actions")
        local fm = {
            file_chooser = {},
            onRefresh = function() end,
        }
        local row = ArchiveActions.contextRow(
            fm, "/library/book.epub", true)

        row[1].callback()
        shown[1].ok_callback()
        shown[2].onConfirm("/archive")

        assert.are.equal("/archive/", saved.archive_dir_path)
        assert.are.equal(1, refreshes)
    end)

    it("removes an archived book to the library root", function()
        source_in_archive = true
        saved.library_archive_original_dirs["/archive/book.epub"] = "/library/Series/"
        local ArchiveActions = require("common/archive_actions")
        local fm = {
            file_chooser = {},
            onRefresh = function() end,
        }
        local row = ArchiveActions.contextRow(
            fm, "/archive/book.epub", true)

        assert.are.equal("\u{F19C}  Remove from archive", row[1].text)
        row[1].callback()
        assert.are.equal("Remove this book from archive?", shown[1].text)
        assert.are.equal("Remove from archive", shown[1].ok_text)
        assert.are.same({}, moves)
        shown[1].ok_callback()
        assert.are.same({
            { "/archive/book.epub", "/library/" },
        }, moves)
        assert.are.same({
            { "/archive/book.epub", "/library/book.epub" },
        }, locations)
        assert.is_nil(saved.library_archive_original_dirs["/archive/book.epub"])
        assert.is_true(_G.__ZEN_UI_ARCHIVE_LISTING_DIRTY)
    end)

    it("archives an end-of-book EPUB after Reader closes and before navigation", function()
        local order = {}
        local ui = {
            document = { file = "/library/book.epub" },
            doc_settings = {
                flush = function() order[#order + 1] = "flush" end,
            },
        }
        local status = {
            ui = ui,
            document = ui.document,
            markBook = function(_, complete)
                assert.is_true(complete)
                order[#order + 1] = "complete"
            end,
        }
        local fm = require("apps/filemanager/filemanager")
        local move_file = fm.moveFile
        fm.moveFile = function(...)
            assert.is_nil(ui.document)
            order[#order + 1] = "move"
            return move_file(...)
        end
        ZenSpec.replace("common/library_navigation", {
            showFromReader = function(reader, _, options)
                assert.are.equal(ui, reader)
                assert.are.equal("/library/", options.target_folder)
                order[#order + 1] = "close"
                ui.document = nil
                options.after_close()
                order[#order + 1] = "open"
                assert.are.same({
                    { "/library/book.epub", "/archive/book.epub" },
                }, locations)
                assert.are.equal("/library/",
                    saved.library_archive_original_dirs["/archive/book.epub"])
            end,
        })
        local ArchiveActions = require("common/archive_actions")

        assert.is_true(ArchiveActions.markCompleteAndArchive(status, {}))
        shown[1].ok_callback()

        assert.are.same({ "complete", "flush", "close", "move", "open" }, order)
        assert.are.same({ { "/library/book.epub", "/archive/" } }, moves)
        assert.is_true(_G.__ZEN_UI_ARCHIVE_LISTING_DIRTY)
    end)

    it("returns to the source folder without archiving metadata if the move fails", function()
        local fm = require("apps/filemanager/filemanager")
        fm.moveFile = function() return false end
        local opened_folder
        ZenSpec.replace("common/library_navigation", {
            showFromReader = function(_, _, options)
                options.after_close()
                opened_folder = options.target_folder
            end,
        })
        local ui = {
            document = { file = "/library/book.epub" },
            doc_settings = { flush = function() end },
        }
        local status = {
            ui = ui,
            document = ui.document,
            markBook = function() end,
        }

        require("common/archive_actions").markCompleteAndArchive(status)
        shown[1].ok_callback()

        assert.are.equal("/library/", opened_folder)
        assert.are.equal("Failed to move book to archive.", shown[#shown].text)
        assert.are.same({}, locations)
        assert.is_nil(saved.library_archive_original_dirs["/archive/book.epub"])
        assert.is_nil(_G.__ZEN_UI_ARCHIVE_LISTING_DIRTY)
    end)
end)
