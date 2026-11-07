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
