describe("Kindle launcher installation", function()
    local lfs = require("libs/libkoreader-lfs")
    local original_db, original_pending, original_launcher, original_storage, original_sqlite, original_config
    local Launcher, root, destination, recorded, config, saved

    local function write(path, contents)
        local file = assert(io.open(path, "wb"))
        assert(file:write(contents))
        assert(file:close())
    end

    local function read(path)
        local file = assert(io.open(path, "rb"))
        local contents = file:read("*a")
        file:close()
        return contents
    end

    before_each(function()
        original_db = package.loaded["common/db_connection"]
        original_pending = package.loaded["modules/menu/app_launcher/zenpm_pending"]
        original_launcher = package.loaded["common/kindle_launcher"]
        original_storage = package.loaded["datastorage"]
        original_sqlite = package.loaded["lua-ljsqlite3/init"]
        original_config = package.loaded["config/manager"]
        recorded = nil
        config, saved = { _meta = {} }, nil
        ZenSpec.replace("config/manager", {
            get = function() return config end,
            save = function(value)
                saved = value._meta.kindle_launcher_added
                return true
            end,
        })
        ZenSpec.replace("common/db_connection", {
            isAvailable = function() return false end,
            open = function(path)
                assert.are.equal("/zenpm.sqlite3", path)
                return {
                    exec = function() end,
                    prepare = function(_self, sql)
                        assert.is_truthy(sql:find("INSERT INTO installed_packages", 1, true))
                        return {
                            bind = function(self, ...)
                                recorded = { ... }
                                return self
                            end,
                            step = function() end,
                            close = function() end,
                        }
                    end,
                    close = function() end,
                }
            end,
        })
        ZenSpec.replace("modules/menu/app_launcher/zenpm_pending", {
            paths = function() return { "/zenpm.sqlite3" } end,
        })
        ZenSpec.unload("common/kindle_launcher")
        Launcher = require("common/kindle_launcher")

        root = os.tmpname()
        os.remove(root)
        assert(lfs.mkdir(root))
        assert(lfs.mkdir(root .. "/kindle-launcher"))
        destination = root .. "/ZenReader.sh"
    end)

    after_each(function()
        package.loaded["common/db_connection"] = original_db
        package.loaded["modules/menu/app_launcher/zenpm_pending"] = original_pending
        package.loaded["common/kindle_launcher"] = original_launcher
        package.loaded["datastorage"] = original_storage
        package.loaded["lua-ljsqlite3/init"] = original_sqlite
        package.loaded["config/manager"] = original_config
        os.remove(destination)
        os.remove(destination .. ".zenos-tmp")
        os.remove(root .. "/kindle-launcher/ZenReader.sh")
        lfs.rmdir(root .. "/ZenPM/state")
        lfs.rmdir(root .. "/ZenPM")
        lfs.rmdir(root .. "/kindle-launcher")
        lfs.rmdir(root)
    end)

    it("copies a missing script and records its installed version", function()
        local bundled = "#!/bin/sh\n# Version: 1.1.0\necho new\n"
        write(root .. "/kindle-launcher/ZenReader.sh", bundled)
        assert.is_true(Launcher.install(root, destination))
        assert.are.equal(bundled, read(destination))
        assert.are.same({ "zen-reader", "ZenOS Launcher", "1.1.0", "ZenLabs", destination },
            { unpack(recorded, 1, 5) })
        assert.is_true(saved)
    end)

    it("updates an older script on the first installation", function()
        local bundled = "#!/bin/sh\n# Version: 1.1.0\necho new\n"
        write(root .. "/kindle-launcher/ZenReader.sh", bundled)
        write(destination, "#!/bin/sh\n# Version: 1.0.0\necho old\n")
        assert.is_true(Launcher.install(root, destination))
        assert.are.equal(bundled, read(destination))
    end)

    it("does not reinstall or register a removed launcher after restarting", function()
        write(root .. "/kindle-launcher/ZenReader.sh", "#!/bin/sh\n# Version: 1.1.0\n")
        assert.is_true(Launcher.install(root, destination))
        assert.is_true(saved)

        assert(os.remove(destination))
        config = { _meta = { kindle_launcher_added = saved } }
        recorded = nil
        ZenSpec.unload("common/kindle_launcher")
        Launcher = require("common/kindle_launcher")

        assert.is_true(Launcher.install(root, destination))
        assert.is_nil(lfs.attributes(destination, "mode"))
        assert.is_nil(recorded)
    end)

    it("preserves a newer ZenPM install", function()
        write(root .. "/kindle-launcher/ZenReader.sh", "#!/bin/sh\n# Version: 1.1.0\n")
        local newer = "#!/bin/sh\n# Version: 1.2.0\n"
        write(destination, newer)
        assert.is_true(Launcher.install(root, destination))
        assert.are.equal(newer, read(destination))
        assert.are.equal("1.2.0", recorded[3])
    end)

    it("preserves an existing script at the bundled version", function()
        write(root .. "/kindle-launcher/ZenReader.sh", "#!/bin/sh\n# Version: 1.1.0\necho bundled\n")
        local current = "#!/bin/sh\n# Version: 1.1.0\necho customized\n"
        write(destination, current)
        assert.is_true(Launcher.install(root, destination))
        assert.are.equal(current, read(destination))
        assert.are.equal("1.1.0", recorded[3])
        assert.is_true(saved)
    end)

    it("does not mark an installation when copying fails", function()
        write(root .. "/kindle-launcher/ZenReader.sh", "#!/bin/sh\n# Version: 1.1.0\n")
        assert.is_false(Launcher.install(root, root .. "/missing/ZenReader.sh"))
        assert.is_nil(recorded)
        assert.is_nil(saved)
    end)

    it("prepares ZenPM's database before its first launch", function()
        local schema
        assert(lfs.mkdir(root .. "/ZenPM"))
        ZenSpec.replace("datastorage", { getSettingsDir = function() return root end })
        ZenSpec.replace("lua-ljsqlite3/init", {
            open = function(path)
                assert.are.equal(root .. "/ZenPM/state/zenpm.sqlite3", path)
                return {
                    exec = function(_self, sql) schema = sql end,
                    close = function() end,
                }
            end,
        })
        write(root .. "/kindle-launcher/ZenReader.sh", "#!/bin/sh\n# Version: 1.1.0\n")

        assert.is_true(Launcher.install(root, destination))
        assert.is_truthy(schema:find("CREATE TABLE IF NOT EXISTS installed_packages", 1, true))
        assert.are.equal("directory", lfs.attributes(root .. "/ZenPM/state", "mode"))
        assert.are.equal("zen-reader", recorded[1])
    end)
end)
