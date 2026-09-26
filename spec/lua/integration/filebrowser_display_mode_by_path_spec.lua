describe("filebrowser display mode by path patch", function()
    local BookInfoManager
    local FileChooser
    local FileManager
    local config
    local coverbrowser
    local persisted_mode
    local rendered_modes
    local mode_calls
    local save_count

    before_each(function()
        config = {}
        persisted_mode = "mosaic_image"
        rendered_modes = {}
        mode_calls = {}
        save_count = 0

        coverbrowser = {
            refreshFileManagerInstance = function() end,
            setDisplayMode = function(self, mode)
                table.insert(mode_calls, mode == nil and "classic" or mode)
                self.mode = mode
                persisted_mode = mode
            end,
        }
        FileManager = {
            instance = { coverbrowser = coverbrowser },
            onPathChanged = function(self, path) self.last_path = path end,
        }
        FileChooser = {
            changeToPath = function(self, path, focused_path)
                table.insert(rendered_modes,
                    coverbrowser.mode == nil and "classic" or coverbrowser.mode)
                if focused_path and self.focused_index then
                    self.page = math.ceil(self.focused_index / self.perpage)
                end
                self.path = path
                return "changed"
            end,
        }
        BookInfoManager = {
            getSetting = function(_, key)
                if key == "filemanager_display_mode" then return persisted_mode end
            end,
            saveSetting = function(_, key, value)
                if key == "filemanager_display_mode" then persisted_mode = value end
            end,
        }

        ZenSpec.replace("apps/filemanager/filemanager", FileManager)
        ZenSpec.replace("ui/widget/filechooser", FileChooser)
        ZenSpec.replace("bookinfomanager", BookInfoManager)
        ZenSpec.replace("config/manager", {
            get = function() return config end,
            load = function() return config end,
            save = function(value)
                config = value
                save_count = save_count + 1
            end,
        })
        ZenSpec.replace("ffi/util", {
            realpath = function(path)
                if path == "/library/.." then return "/" end
                return path
            end,
        })
        ZenSpec.replace("common/paths", {
            normPath = function(path) return path:gsub("//+", "/") end,
            isInThemedDir = function(path)
                return path == "/library" or path:sub(1, 9) == "/library/"
            end,
            isPrimaryHomeRoot = function(path) return path == "/library" end,
        })

        _G.__ZEN_FOLDER_DISPLAY_MODE = nil
        _G.__ZEN_PREFERRED_DISPLAY_MODE = nil
        ZenSpec.unload("modules/filebrowser/patches/browser_display_mode_by_path")
        require("modules/filebrowser/patches/browser_display_mode_by_path")()
    end)

    after_each(function()
        _G.__ZEN_FOLDER_DISPLAY_MODE = nil
        _G.__ZEN_PREFERRED_DISPLAY_MODE = nil
    end)

    it("persists only valid non-root folder overrides", function()
        local api = assert(_G.__ZEN_FOLDER_DISPLAY_MODE)

        api.set("/library/series///", "list_image_meta")
        assert.are.equal("list_image_meta", api.get("/library/series"))
        assert.are.equal(1, save_count)

        api.set("/library", "mosaic_image")
        api.set("/library/other", "classic")
        assert.is_nil(api.get("/library"))
        assert.is_nil(api.get("/library/other"))
        assert.are.equal(1, save_count)

        api.clear("/library/series")
        assert.is_nil(api.get("/library/series"))
        assert.are.equal(2, save_count)
        api.clear("/library/series")
        assert.are.equal(2, save_count)
    end)

    it("switches to classic before rendering outside home and restores before returning", function()
        local chooser = { name = "filemanager" }
        coverbrowser.mode = persisted_mode

        assert.are.equal("changed", FileChooser.changeToPath(chooser, "/outside"))
        assert.are.equal("classic", rendered_modes[1])
        assert.are.equal("mosaic_image", persisted_mode)
        assert.are.equal("mosaic_image", _G.__ZEN_PREFERRED_DISPLAY_MODE)

        FileChooser.changeToPath(chooser, "/library/books")
        assert.are.same({ "classic", "mosaic_image" }, mode_calls)
        assert.are.equal("mosaic_image", rendered_modes[2])
        assert.is_nil(_G.__ZEN_PREFERRED_DISPLAY_MODE)
        assert.are.equal("mosaic_image", _G.__ZEN_FOLDER_DISPLAY_MODE.current())
    end)

    it("applies a folder override without replacing the global preference", function()
        local api = assert(_G.__ZEN_FOLDER_DISPLAY_MODE)
        local chooser = { name = "filemanager" }
        api.set("/library/series", "list_image_filename")
        coverbrowser.mode = persisted_mode

        FileChooser.changeToPath(chooser, "/library/series")

        assert.are.equal("list_image_filename", rendered_modes[1])
        assert.are.equal("list_image_filename", coverbrowser.mode)
        assert.are.equal("mosaic_image", persisted_mode)
        assert.are.equal("list_image_filename", api.current())
    end)

    it("recalculates target layout before locating a folder on its parent page", function()
        local api = assert(_G.__ZEN_FOLDER_DISPLAY_MODE)
        local chooser = {
            name = "filemanager",
            page = 4,
            perpage = 9,
            focused_index = 32,
            _recalculateDimen = function(self)
                self.perpage = coverbrowser.mode == "mosaic_image" and 9 or 5
            end,
        }
        FileManager.instance.file_chooser = chooser
        api.set("/library/test1", "list_image_meta")
        coverbrowser.mode = persisted_mode

        FileChooser.changeToPath(chooser, "/library/test1")
        assert.are.equal(5, chooser.perpage)

        chooser.page = 1
        FileChooser.changeToPath(chooser, "/library", "/library/test1")

        assert.are.equal(9, chooser.perpage)
        assert.are.equal(4, chooser.page)
    end)

    it("resolves parent traversal before deciding whether a path is in home", function()
        local chooser = { name = "filemanager" }
        coverbrowser.mode = persisted_mode

        FileChooser.changeToPath(chooser, "/library/..")

        assert.are.equal("classic", rendered_modes[1])
        assert.are.equal("mosaic_image", _G.__ZEN_PREFERRED_DISPLAY_MODE)
    end)

    it("leaves non-filemanager choosers unchanged", function()
        coverbrowser.mode = "mosaic_image"

        FileChooser.changeToPath({ name = "move_chooser" }, "/outside")

        assert.are.equal("mosaic_image", rendered_modes[1])
        assert.is_nil(_G.__ZEN_PREFERRED_DISPLAY_MODE)
    end)
end)
