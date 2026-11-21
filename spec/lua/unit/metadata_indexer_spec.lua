describe("metadata indexer", function()
    local Indexer
    local tasks
    local inventory
    local indexed
    local batches
    local extracting
    local extraction_indexes
    local refreshes
    local wanted
    local saved_modules
    local replaced_modules = {
        "ui/uimanager",
        "common/paths",
        "common/tbr_index",
        "bookinfomanager",
    }

    local function run_tasks()
        while #tasks > 0 do table.remove(tasks, 1)() end
    end

    local function start()
        Indexer.start(function() return wanted end, function() refreshes = refreshes + 1 end)
    end

    before_each(function()
        saved_modules = {}
        for _i, name in ipairs(replaced_modules) do
            saved_modules[name] = package.loaded[name] or false
        end
        tasks, inventory, indexed, batches = {}, {}, {}, {}
        extracting, extraction_indexes, refreshes, wanted = false, true, 0, true

        ZenSpec.replace("ui/uimanager", {
            scheduleIn = function(_, _delay, task) tasks[#tasks + 1] = task end,
        })
        ZenSpec.replace("common/paths", {
            normPath = function(path) return (path:gsub("^/sdcard/", "/storage/emulated/0/")) end,
        })
        ZenSpec.replace("common/tbr_index", {
            scheduleAudit = function(_, on_complete) on_complete() end,
            getInventoryPaths = function() return inventory end,
        })
        ZenSpec.replace("bookinfomanager", {
            openDbConnection = function() end,
            db_conn = {
                exec = function()
                    if #indexed > 0 then return { indexed } end
                end,
            },
            isExtractingInBackground = function() return extracting end,
            extractInBackground = function(_, files)
                batches[#batches + 1] = files
                if extraction_indexes then
                    for _i, file in ipairs(files) do indexed[#indexed + 1] = file.filepath end
                end
                return true
            end,
        })
        ZenSpec.unload("common/metadata_indexer")
        Indexer = require("common/metadata_indexer")
    end)

    after_each(function()
        ZenSpec.unload("common/metadata_indexer")
        for _i, name in ipairs(replaced_modules) do
            package.loaded[name] = saved_modules[name] or nil
        end
    end)

    it("extracts only uncached books, metadata only, in short batches", function()
        for index = 1, 10 do
            inventory[index] = ("/storage/emulated/0/books/%02d.epub"):format(index)
        end
        indexed[1] = "/sdcard/books/01.epub"

        start()
        run_tasks()

        assert.are.equal(2, #batches)
        assert.are.equal(8, #batches[1])
        assert.are.equal(1, #batches[2])
        for _i, batch in ipairs(batches) do
            for _j, file in ipairs(batch) do
                assert.are_not.equal(inventory[1], file.filepath)
                assert.is_nil(file.cover_specs)
            end
        end
        assert.are.equal(1, refreshes)
    end)

    it("leaves a fully cached library alone", function()
        inventory[1] = "/books/a.epub"
        indexed[1] = "/books/a.epub"

        start()
        run_tasks()

        assert.are.equal(0, #batches)
        assert.are.equal(0, refreshes)
    end)

    it("waits for a running extraction instead of replacing it", function()
        inventory[1] = "/books/a.epub"
        extracting = true

        start()
        table.remove(tasks, 1)() -- start delay
        table.remove(tasks, 1)() -- poll
        assert.are.equal(0, #batches)

        extracting = false
        run_tasks()
        assert.are.equal(1, #batches)
        assert.are.equal(1, refreshes)
    end)

    it("stops once no view wants the result", function()
        inventory[1] = "/books/a.epub"
        wanted = false

        start()
        run_tasks()
        assert.are.equal(0, #batches)

        -- The previous run ended, so a later view starts a new one.
        wanted = true
        start()
        run_tasks()
        assert.are.equal(1, #batches)
    end)

    it("stops retrying books that never reach the cache", function()
        inventory[1] = "/books/broken.epub"
        extraction_indexes = false

        start()
        run_tasks()

        assert.are.equal(4, #batches)
        assert.are.equal(1, refreshes)
    end)
end)
