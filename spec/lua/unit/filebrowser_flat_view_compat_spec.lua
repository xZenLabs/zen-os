describe("filebrowser flat view compatibility patch", function()
    local FileChooser
    local config
    local walked
    local original_calls
    local reader_data
    local scheduled
    local active_chooser
    local FileManager
    local unsafe_home

    before_each(function()
        config = { browser_flat_view = { enabled = true } }
        walked = {}
        original_calls = 0
        scheduled = {}
        active_chooser = {
            path = "/library",
            refreshPath = function(self) self.refresh_count = (self.refresh_count or 0) + 1 end,
        }
        unsafe_home = false
        reader_data = { show_flat_view = true }
        _G.G_reader_settings = {
            isTrue = function(_, key) return reader_data[key] == true end,
            saveSetting = function(_, key, value) reader_data[key] = value end,
        }

        FileChooser = {
            getPathList = function(_, _path, _collate, dirs, files)
                original_calls = original_calls + 1
                table.insert(dirs, "original-dir")
                table.insert(files, "original-file")
                return "original"
            end,
        }
        ZenSpec.replace("ui/widget/filechooser", FileChooser)
        ZenSpec.replace("ffi/util", { realpath = function(path) return path end })
        ZenSpec.replace("common/paths", {
            isInHomeDir = function(path)
                return path == "/library" or path:sub(1, 9) == "/library/"
            end,
            hasUnsafeFlatViewHomeRoot = function() return unsafe_home end,
        })
        ZenSpec.replace("config/manager", { get = function() return config end })
        ZenSpec.replace("ui/uimanager", {
            scheduleIn = function(_, delay, callback)
                table.insert(scheduled, { delay = delay, callback = callback })
            end,
        })
        FileManager = { instance = { file_chooser = active_chooser } }
        ZenSpec.replace("apps/filemanager/filemanager", FileManager)
        ZenSpec.replace("common/book_walker", {
            walk = function(path, options)
                walked.path = path
                walked.include_hidden = options.include_hidden
                walked.koreader_result = options.on_dir("koreader")
                walked.books_result = options.on_dir("Books")
                if options.on_scan_dir then
                    options.on_scan_dir(path, { mode = "directory", modification = 1 })
                    options.on_scan_dir("/library/Empty", { mode = "directory", modification = 2 })
                end
                options.on_file("Alpha.epub", "/library/Series/Alpha.epub",
                    { mode = "file", size = 10 }, 1, "/library/Series")
                options.on_file("notes.txt", "/library/Notes/notes.txt",
                    { mode = "file", size = 5 }, 1, "/library/Notes")
            end,
        })

        ZenSpec.unload("modules/filebrowser/patches/browser_flat_view_compat")
        require("modules/filebrowser/patches/browser_flat_view_compat")()
    end)

    it("rebuilds the eligible startup listing after installing the patch", function()
        assert.are.equal(1, #scheduled)
        assert.are.equal(0.1, scheduled[1].delay)
        scheduled[1].callback()
        assert.are.equal(1, active_chooser.refresh_count)
        assert.are.equal(1, #scheduled)

        active_chooser.path = "/outside"
        scheduled[1].callback()
        assert.are.equal(1, active_chooser.refresh_count)
        assert.are.equal(1, #scheduled)

        active_chooser.path = "/library"
        unsafe_home = true
        scheduled[1].callback()
        assert.are.equal(1, active_chooser.refresh_count)
        assert.are.equal(1, #scheduled)
    end)

    it("retries until the active file chooser becomes available", function()
        FileManager.instance = nil
        scheduled[1].callback()
        assert.are.equal(2, #scheduled)
        assert.are.equal(0.1, scheduled[2].delay)

        FileManager.instance = { file_chooser = active_chooser }
        scheduled[2].callback()
        assert.are.equal(1, active_chooser.refresh_count)
        assert.are.equal(2, #scheduled)
    end)

    it("stops polling after twenty attempts when FileManager stays unavailable", function()
        FileManager.instance = nil
        local index = 1
        while scheduled[index] do
            scheduled[index].callback()
            index = index + 1
        end

        assert.are.equal(20, #scheduled)
        assert.is_nil(active_chooser.refresh_count)
    end)

    it("recursively returns supported files from subfolders without directories", function()
        local chooser = {
            name = "filemanager",
            show_hidden = true,
            show_dir = function(_, name) return name == "Books" end,
            show_file = function(_, name) return name:match("%.epub$") ~= nil end,
            getListItem = function(_, parent_path, name, fullpath, attributes, collate)
                return {
                    parent_path = parent_path,
                    text = name,
                    path = fullpath,
                    attr = attributes,
                    collate = collate,
                }
            end,
        }
        local dirs, files = {}, {}

        FileChooser.getPathList(chooser, "/library", "natural", dirs, files)

        assert.are.equal("/library", walked.path)
        assert.is_true(walked.include_hidden)
        assert.is_false(walked.koreader_result)
        assert.is_true(walked.books_result)
        assert.are.same({}, dirs)
        assert.are.equal(1, #files)
        assert.are.same({
            parent_path = "/library/Series",
            text = "Alpha.epub",
            path = "/library/Series/Alpha.epub",
            attr = { mode = "file", size = 10 },
            collate = "natural",
        }, files[1])
        assert.are.equal(0, original_calls)
        assert.are.same({
            ["/library"] = { mode = "directory", modification = 1 },
            ["/library/Empty"] = { mode = "directory", modification = 2 },
        }, chooser._zen_flat_view_directories)
    end)

    it("uses boolean placeholders when no collation is requested", function()
        local chooser = {
            name = "filemanager",
            show_dir = function() return true end,
            show_file = function(_, name) return name:match("%.epub$") ~= nil end,
            getListItem = function() error("getListItem should not be called") end,
        }
        local dirs, files = {}, {}

        FileChooser.getPathList(chooser, "/library", nil, dirs, files)

        assert.are.same({}, dirs)
        assert.are.same({ true }, files)
        assert.is_false(walked.include_hidden)
    end)

    describe("book sources' books without a file", function()
        local asked

        before_each(function()
            asked = nil
            ZenSpec.replace("common/book_sources", {
                booksWithoutFile = function(folders, present)
                    asked = { folders = folders, present = present }
                    return {
                        { file = "/library/Series/Cloud.epub", name = "Cloud.epub", folder = "/library/Series",
                          attr = { mode = "file", size = 3 } },
                        { file = "/library/Series/.hidden.epub", name = ".hidden.epub",
                          folder = "/library/Series", attr = { mode = "file" } },
                        { file = "/library/Series/skip.pdf", name = "skip.pdf",
                          folder = "/library/Series", attr = { mode = "file" } },
                    }
                end,
            })
        end)

        after_each(function()
            ZenSpec.unload("common/book_sources")
        end)

        local function chooser(hidden)
            return {
                name = "filemanager",
                show_hidden = hidden,
                show_dir = function() return true end,
                show_file = function(_, name) return name:match("%.epub$") ~= nil end,
                getListItem = function(_, parent_path, name, fullpath, attributes)
                    return { parent_path = parent_path, text = name, path = fullpath, attr = attributes }
                end,
            }
        end

        it("lists them after the files, through the browser's filters", function()
            local dirs, files = {}, {}
            FileChooser.getPathList(chooser(false), "/library", "natural", dirs, files)

            assert.are.same({ ["/library"] = true, ["/library/Empty"] = true }, asked.folders)
            assert.is_true(asked.present["/library/Series/Alpha.epub"])
            assert.is_true(asked.present["/library/Notes/notes.txt"])
            assert.are.equal(2, #files)
            assert.are.same({
                parent_path = "/library/Series", text = "Cloud.epub",
                path = "/library/Series/Cloud.epub", attr = { mode = "file", size = 3 },
            }, files[2])
        end)

        it("counts them as true, and lists hidden ones only when hidden files show", function()
            local files = {}
            FileChooser.getPathList(chooser(false), "/library", nil, {}, files)
            assert.are.same({ true, true }, files)

            files = {}
            FileChooser.getPathList(chooser(true), "/library", nil, {}, files)
            assert.are.same({ true, true, true }, files)
        end)

        it("knows the folders walked when only counting", function()
            FileChooser.getPathList(chooser(false), "/library", nil, {}, {})
            assert.is_true(asked.folders["/library/Empty"])
        end)

        it("keeps listing files when the book sources fail", function()
            ZenSpec.replace("common/book_sources", {
                booksWithoutFile = function() error("source failed") end,
            })
            local files = {}
            FileChooser.getPathList(chooser(false), "/library", nil, {}, files)
            assert.are.same({ true }, files)
        end)
    end)

    describe("library sources' books in a folder's listing", function()
        local asked

        before_each(function()
            asked = {}
            ZenSpec.replace("common/book_sources", {
                booksWithoutFile = function(folders, present)
                    asked[#asked + 1] = { folders = folders, present = present }
                    return {
                        { file = "/outside/Cloud.epub", name = "Cloud.epub", folder = "/outside",
                          attr = { mode = "file", size = 3 } },
                    }
                end,
                docProps = function(path) return { title = "Cloud", display_title = "Cloud", path = path } end,
            })
        end)

        after_each(function()
            ZenSpec.unload("common/book_sources")
        end)

        local function chooser(name)
            return {
                name = name or "filemanager",
                show_file = function() return true end,
                getListItem = function(_, parent_path, item_name, fullpath, attributes)
                    return { parent_path = parent_path, text = item_name, path = fullpath, attr = attributes }
                end,
            }
        end

        it("adds them after KOReader's files, with their metadata", function()
            local dirs, files = {}, {}
            assert.are.equal("original",
                FileChooser.getPathList(chooser(), "/outside/", "natural", dirs, files))
            assert.are.equal(1, original_calls)
            assert.are.equal(2, #files)
            assert.are.same({
                parent_path = "/outside", text = "Cloud.epub", path = "/outside/Cloud.epub",
                attr = { mode = "file", size = 3 },
                doc_props = { title = "Cloud", display_title = "Cloud", path = "/outside/Cloud.epub" },
            }, files[2])
            assert.is_true(asked[1].folders["/outside"])
            assert.are.same({}, asked[1].present) -- "original-file" isn't an item
        end)

        it("counts them as true without knowing the files present", function()
            local files = {}
            FileChooser.getPathList(chooser(), "/outside", nil, {}, files)
            assert.are.same({ "original-file", true }, files)
            assert.is_nil(asked[1].present)
        end)

        it("counts one that is also a file in the folder once", function()
            local lfs = require("libs/libkoreader-lfs")
            local dir = os.tmpname()
            os.remove(dir)
            assert(lfs.mkdir(dir))
            local handle = assert(io.open(dir .. "/Cloud.epub", "w"))
            handle:close()
            ZenSpec.replace("common/book_sources", {
                booksWithoutFile = function()
                    return {
                        { file = dir .. "/Cloud.epub", name = "Cloud.epub", folder = dir,
                          attr = { mode = "file" } },
                        { file = dir .. "/Other.epub", name = "Other.epub", folder = dir,
                          attr = { mode = "file" } },
                    }
                end,
            })
            local ok, err = pcall(function()
                local files = {}
                FileChooser.getPathList(chooser(), dir, nil, {}, files)
                assert.are.same({ "original-file", true }, files, "Other.epub only")
            end)
            os.remove(dir .. "/Cloud.epub")
            lfs.rmdir(dir)
            assert(ok, err)
        end)

        it("leaves other file choosers alone", function()
            local files = {}
            FileChooser.getPathList(chooser("pathchooser"), "/outside", "natural", {}, files)
            assert.are.same({ "original-file" }, files)
            assert.are.equal(0, #asked)
        end)
    end)

    it("delegates outside home and when Zen flat view is disabled", function()
        local chooser = { name = "filemanager" }
        local dirs, files = {}, {}

        assert.are.equal("original",
            FileChooser.getPathList(chooser, "/outside", nil, dirs, files))
        config.browser_flat_view.enabled = false
        assert.are.equal("original",
            FileChooser.getPathList(chooser, "/library", nil, dirs, files))

        assert.are.equal(2, original_calls)
        assert.are.same({ "original-dir", "original-dir" }, dirs)
        assert.are.same({ "original-file", "original-file" }, files)
    end)

    it("delegates for non-library choosers such as PathChooser", function()
        local dirs, files = {}, {}

        assert.are.equal("original",
            FileChooser.getPathList({ select_directory = false }, "/library", nil, dirs, files))

        assert.are.equal(1, original_calls)
        assert.is_nil(walked.path)
    end)
end)
