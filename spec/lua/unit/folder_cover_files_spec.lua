describe("managed folder cover files", function()
    local FolderCoverFiles
    local config
    local files
    local mutations
    local realpaths
    local save_calls
    local save_fails
    local original_plugin
    local original_rename
    local original_remove

    local function add_file(path, size)
        files[path] = { mode = "file", size = size or 10 }
    end

    local function direct_names(folder)
        local prefix = folder:sub(-1) == "/" and folder or folder .. "/"
        local names = {}
        for path in pairs(files) do
            if path:sub(1, #prefix) == prefix then
                local name = path:sub(#prefix + 1)
                if name ~= "" and not name:find("/", 1, true) then
                    names[#names + 1] = name
                end
            end
        end
        table.sort(names)
        return names
    end

    before_each(function()
        config = { folder_cover_paths = {} }
        files = {
            ["/library/folder"] = { mode = "directory" },
            ["/source"] = { mode = "directory" },
        }
        mutations = {}
        realpaths = {}
        save_calls = {}
        save_fails = false
        original_plugin = rawget(_G, "__ZEN_UI_PLUGIN")
        _G.__ZEN_UI_PLUGIN = nil
        original_rename = os.rename
        original_remove = os.remove

        ZenSpec.replace("libs/libkoreader-lfs", {
            attributes = function(path, field)
                local attr = files[path]
                return field and attr and attr[field] or attr
            end,
            dir = function(folder)
                local names = direct_names(folder)
                local index = 0
                return function()
                    index = index + 1
                    return names[index]
                end
            end,
        })
        ZenSpec.replace("ffi/util", {
            realpath = function(path)
                return realpaths[path] or path
            end,
            copyFile = function()
                mutations[#mutations + 1] = "copy"
                error("folder cover references must not copy files")
            end,
        })
        ZenSpec.replace("config/manager", {
            get = function() return config end,
            load = function() return config end,
            save = function(saved)
                save_calls[#save_calls + 1] = saved
                if save_fails then return nil, "save failed" end
                return true
            end,
        })
        rawset(os, "rename", function()
            mutations[#mutations + 1] = "rename"
            error("folder cover references must not rename files")
        end)
        rawset(os, "remove", function()
            mutations[#mutations + 1] = "remove"
            error("folder cover references must not remove files")
        end)

        ZenSpec.unload("common/folder_cover_files")
        FolderCoverFiles = require("common/folder_cover_files")
    end)

    after_each(function()
        rawset(os, "rename", original_rename)
        rawset(os, "remove", original_remove)
        _G.__ZEN_UI_PLUGIN = original_plugin
        ZenSpec.unload("common/folder_cover_files")
    end)

    it("matches only exact managed image names case-insensitively", function()
        local managed = {
            "cover.jpg", ".cover.JPEG", "COVER1.jpg", "cover2.jpeg",
            "Cover3.jpg", "COVER4.JPG",
        }
        for _i, name in ipairs(managed) do
            assert.is_true(FolderCoverFiles.isManaged(name), name)
        end

        local unmanaged = {
            "cover5.jpg", "cover10.jpg", "mycover.jpg", "cover-old.jpg",
            "cover.svg", "cover.epub", "cover", "/folder/cover.jpg",
            "COVER1.png", "cover2.WEBP",
            "Cover3.gif",
        }
        for _i, name in ipairs(unmanaged) do
            assert.is_false(FolderCoverFiles.isManaged(name), name)
        end
    end)

    it("uses one slot for normal mode and four for gallery and stack", function()
        assert.are.equal(1, FolderCoverFiles.slotCount("normal"))
        assert.are.equal(4, FolderCoverFiles.slotCount("gallery"))
        assert.are.equal(4, FolderCoverFiles.slotCount("stack"))
        assert.are.equal(0, FolderCoverFiles.slotCount("none"))
    end)

    it("accepts JPG and JPEG extensions case-insensitively", function()
        assert.is_true(FolderCoverFiles.isSupportedImage("poster.jpg"))
        assert.is_true(FolderCoverFiles.isSupportedImage("poster.JPG"))
        assert.is_true(FolderCoverFiles.isSupportedImage("poster.jpeg"))
        assert.is_true(FolderCoverFiles.isSupportedImage("poster.JPEG"))
        assert.is_false(FolderCoverFiles.isSupportedImage("poster.png"))
        assert.is_false(FolderCoverFiles.isSupportedImage("poster.webp"))
        assert.is_false(FolderCoverFiles.isSupportedImage("poster.gif"))
        assert.is_false(FolderCoverFiles.isSupportedImage("poster.svg"))
        assert.is_false(FolderCoverFiles.isSupportedImage("book.epub"))
    end)

    it("finds sparse multi-cover slots with legacy slot-one priority", function()
        add_file("/library/folder/cover.jpg")
        add_file("/library/folder/.cover.JPG")
        add_file("/library/folder/COVER1.JPG")
        add_file("/library/folder/cover2.jpg")
        add_file("/library/folder/cover4.JPG")

        local gallery = FolderCoverFiles.find("/library/folder", "gallery")
        assert.are.equal("/library/folder/COVER1.JPG", gallery[1])
        assert.are.equal("/library/folder/cover2.jpg", gallery[2])
        assert.is_nil(gallery[3])
        assert.are.equal("/library/folder/cover4.JPG", gallery[4])
        assert.is_true(FolderCoverFiles.has("/library/folder", "gallery"))

        local normal = FolderCoverFiles.find("/library/folder", "normal")
        assert.are.equal("/library/folder/cover.jpg", normal[1])
    end)

    it("finds an uppercase JPEG extension", function()
        add_file("/library/folder/COVER.JPEG")

        assert.are.equal("/library/folder/COVER.JPEG",
            FolderCoverFiles.find("/library/folder", "normal")[1])
    end)

    it("reports folders without managed covers", function()
        add_file("/library/folder/poster.jpg")
        files["/library/folder/cover.jpg"] = { mode = "directory" }

        assert.is_false(FolderCoverFiles.has("/library/folder", "normal"))
        assert.are.same({}, FolderCoverFiles.find("/missing", "gallery"))
        assert.is_false(FolderCoverFiles.has("/library/folder", "none"))
    end)

    it("persists canonical source references without mutating folder files", function()
        add_file("/source/Chosen.JPG", 42)
        add_file("/library/folder/cover.jpg", 9)
        add_file("/library/folder/cover1.JPG", 9)
        add_file("/library/folder/.cover.jpg", 9)
        add_file("/library/folder/cover2.jpg", 9)
        realpaths["/alias/folder"] = "/library/folder"
        realpaths["/alias/Chosen.JPG"] = "/source/Chosen.JPG"
        local names_before = direct_names("/library/folder")

        local selected = assert(FolderCoverFiles.set(
            "/alias/folder/", "gallery", 1, "/alias/Chosen.JPG"))

        assert.are.equal("/source/Chosen.JPG", selected)
        assert.are.same({ [1] = "/source/Chosen.JPG" },
            config.folder_cover_paths["/library/folder"])
        assert.are.same({ config }, save_calls)
        assert.are.same(names_before, direct_names("/library/folder"))
        assert.are.same({}, mutations)
    end)

    it("keeps configured sparse slots authoritative over manual covers", function()
        add_file("/source/first.jpg", 31)
        add_file("/source/fourth.JPG", 32)
        add_file("/library/folder/cover1.jpg", 9)
        add_file("/library/folder/cover2.jpg", 9)
        add_file("/library/folder/cover3.jpg", 9)
        add_file("/library/folder/cover4.jpg", 9)
        config.folder_cover_paths["/library/folder"] = {
            [1] = "/source/first.jpg",
            [2] = "/source/missing.jpg",
            [4] = "/source/fourth.JPG",
        }

        local covers = FolderCoverFiles.find("/library/folder", "gallery")

        assert.are.equal("/source/first.jpg", covers[1])
        assert.is_nil(covers[2])
        assert.is_nil(covers[3])
        assert.are.equal("/source/fourth.JPG", covers[4])
        assert.is_true(FolderCoverFiles.has("/library/folder", "gallery"))
        assert.are.equal("/source/first.jpg",
            FolderCoverFiles.find("/library/folder", "normal")[1])
    end)

    it("returns no explicit covers when configured references are stale or unsupported", function()
        add_file("/source/legacy.png", 9)
        add_file("/library/folder/cover.jpg", 9)
        add_file("/library/folder/cover2.jpg", 9)
        config.folder_cover_paths["/library/folder"] = {
            [1] = "/source/legacy.png",
            [2] = "/source/also-missing.jpg",
        }

        assert.are.same({}, FolderCoverFiles.find("/library/folder", "gallery"))
        assert.is_false(FolderCoverFiles.has("/library/folder", "gallery"))
        assert.is_table(files["/library/folder/cover.jpg"])
        assert.is_table(files["/library/folder/cover2.jpg"])
    end)

    it("preserves other slots when saving a higher configured slot", function()
        add_file("/source/first.jpg", 41)
        add_file("/source/fourth.jpg", 42)
        config.folder_cover_paths["/library/folder"] = {
            [1] = "/source/first.jpg",
        }

        local selected = assert(FolderCoverFiles.set(
            "/library/folder", "stack", 4, "/source/fourth.jpg"))

        assert.are.equal("/source/fourth.jpg", selected)
        assert.are.same({
            [1] = "/source/first.jpg",
            [4] = "/source/fourth.jpg",
        }, config.folder_cover_paths["/library/folder"])
        assert.are.same({}, mutations)
    end)

    it("clears one configured slot without changing the others or source files", function()
        add_file("/source/first.jpg", 41)
        add_file("/source/third.jpg", 42)
        config.folder_cover_paths["/library/folder"] = {
            [1] = "/source/first.jpg",
            [3] = "/source/third.jpg",
        }

        assert.is_true(FolderCoverFiles.clear(
            "/library/folder", "gallery", 3))

        assert.are.same({ [1] = "/source/first.jpg" },
            config.folder_cover_paths["/library/folder"])
        assert.are.equal("/source/first.jpg",
            FolderCoverFiles.find("/library/folder", "gallery")[1])
        assert.is_table(files["/source/third.jpg"])
        assert.are.same({}, mutations)
    end)

    it("keeps an empty tombstone so a cleared manual cover does not reappear", function()
        add_file("/library/folder/cover.jpg", 41)

        assert.is_true(FolderCoverFiles.clear(
            "/library/folder", "normal", 1))

        assert.are.same({}, config.folder_cover_paths["/library/folder"])
        assert.are.same({}, FolderCoverFiles.find("/library/folder", "normal"))
        assert.is_table(files["/library/folder/cover.jpg"])
        assert.are.same({}, mutations)
    end)

    it("preserves gallery-only manual slots when clearing in normal mode", function()
        add_file("/library/folder/cover.jpg", 41)
        add_file("/library/folder/cover2.jpg", 42)
        add_file("/library/folder/cover4.jpg", 43)

        assert.is_true(FolderCoverFiles.clear(
            "/library/folder", "normal", 1))

        assert.are.same({
            [2] = "/library/folder/cover2.jpg",
            [4] = "/library/folder/cover4.jpg",
        }, config.folder_cover_paths["/library/folder"])
        assert.are.same({}, FolderCoverFiles.find("/library/folder", "normal"))
        local gallery = FolderCoverFiles.find("/library/folder", "gallery")
        assert.is_nil(gallery[1])
        assert.are.equal("/library/folder/cover2.jpg", gallery[2])
        assert.are.equal("/library/folder/cover4.jpg", gallery[4])
        assert.are.same({}, mutations)
    end)

    it("preserves other manual slots when clearing one of them", function()
        add_file("/library/folder/cover1.jpg", 41)
        add_file("/library/folder/cover2.jpg", 42)

        assert.is_true(FolderCoverFiles.clear(
            "/library/folder", "gallery", 2))

        assert.are.same({
            [1] = "/library/folder/cover1.jpg",
        }, config.folder_cover_paths["/library/folder"])
        local covers = FolderCoverFiles.find("/library/folder", "gallery")
        assert.are.equal("/library/folder/cover1.jpg", covers[1])
        assert.is_nil(covers[2])
        assert.is_table(files["/library/folder/cover2.jpg"])
        assert.are.same({}, mutations)
    end)

    it("rolls back a configured slot when saving fails", function()
        add_file("/source/old.jpg", 41)
        add_file("/source/new.jpg", 42)
        config.folder_cover_paths["/library/folder"] = {
            [1] = "/source/old.jpg",
        }
        save_fails = true

        local selected, err = FolderCoverFiles.set(
            "/library/folder", "gallery", 1, "/source/new.jpg")

        assert.is_nil(selected)
        assert.are.equal("save_failed", err)
        assert.are.equal("/source/old.jpg",
            config.folder_cover_paths["/library/folder"][1])
        assert.are.same({}, mutations)

        config.folder_cover_paths["/library/folder"] = {}
        selected, err = FolderCoverFiles.set(
            "/library/folder", "gallery", 1, "/source/new.jpg")
        assert.is_nil(selected)
        assert.are.equal("save_failed", err)
        assert.are.same({}, config.folder_cover_paths["/library/folder"])
    end)

    it("rolls back clearing exactly when saving fails", function()
        add_file("/source/first.jpg", 41)
        add_file("/source/third.jpg", 42)
        local original_slots = {
            [1] = "/source/first.jpg",
            [3] = "/source/third.jpg",
        }
        config.folder_cover_paths["/library/folder"] = original_slots
        save_fails = true

        local cleared, err = FolderCoverFiles.clear(
            "/library/folder", "gallery", 3)

        assert.is_nil(cleared)
        assert.are.equal("save_failed", err)
        assert.are.equal(original_slots,
            config.folder_cover_paths["/library/folder"])
        assert.are.same({
            [1] = "/source/first.jpg",
            [3] = "/source/third.jpg",
        }, original_slots)
        assert.are.same({}, mutations)

        config.folder_cover_paths = {}
        add_file("/library/folder/cover.jpg", 43)
        cleared, err = FolderCoverFiles.clear(
            "/library/folder", "normal", 1)
        assert.is_nil(cleared)
        assert.are.equal("save_failed", err)
        assert.is_nil(config.folder_cover_paths["/library/folder"])
        assert.are.same({}, mutations)
    end)

    it("rejects invalid slots, folders, and sources before saving", function()
        add_file("/source/chosen.bmp", 42)
        add_file("/source/chosen.jpeg", 42)
        add_file("/source/chosen.png", 42)
        add_file("/source/chosen.webp", 42)
        add_file("/source/chosen.gif", 42)
        add_file("/source/empty.jpg", 0)

        assert.are.same({ nil, "invalid_slot" }, {
            FolderCoverFiles.set("/library/folder", "normal", 2, "/source/empty.jpg"),
        })
        assert.are.same({ nil, "invalid_folder" }, {
            FolderCoverFiles.set("/missing", "normal", 1, "/source/empty.jpg"),
        })
        assert.are.same({ nil, "unsupported_source" }, {
            FolderCoverFiles.set("/library/folder", "normal", 1, "/source/chosen.bmp"),
        })
        for _i, extension in ipairs({ "png", "webp", "gif" }) do
            assert.are.same({ nil, "unsupported_source" }, {
                FolderCoverFiles.set("/library/folder", "normal", 1,
                    "/source/chosen." .. extension),
            })
        end
        assert.are.same({ nil, "invalid_source" }, {
            FolderCoverFiles.set("/library/folder", "normal", 1, "/source/empty.jpg"),
        })
        assert.are.same({ nil, "invalid_slot" }, {
            FolderCoverFiles.clear("/library/folder", "normal", 2),
        })
        assert.are.same({ nil, "invalid_folder" }, {
            FolderCoverFiles.clear("/missing", "normal", 1),
        })
        assert.are.equal(0, #save_calls)
        assert.are.same({}, config.folder_cover_paths)
        assert.are.same({}, mutations)
    end)
end)
