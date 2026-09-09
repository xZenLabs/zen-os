require("ffi/loadlib")

local Archiver = require("ffi/archiver")
local Epub = require("modules/filebrowser/metadata/epub")
local ffi = require("ffi")
local ffiutil = require("ffi/util")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

pcall(ffi.cdef, "int chmod(const char *path, mode_t mode);")

local CONTAINER = [[<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]]

local OPF = [[<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:identifier id="book-id" opf:scheme="ISBN">978-0-441-01359-3</dc:identifier>
    <dc:identifier id="vendor-id">vendor:untouched</dc:identifier>
    <dc:title>Old Title</dc:title>
    <dc:creator id="creator-1" opf:role="aut">Old Author</dc:creator>
    <dc:creator id="editor-1" opf:role="edt">Preserved Editor</dc:creator>
    <dc:creator id="narrator-1">Preserved Narrator</dc:creator>
    <dc:subject>Fantasy</dc:subject>
    <dc:language>en</dc:language>
    <dc:publisher>Old House</dc:publisher>
    <dc:description>Old description.</dc:description>
    <meta name="calibre:series" content="Old Series"/>
    <meta name="calibre:series_index" content="3"/>
    <meta property="belongs-to-collection" id="series-id">Old Series</meta>
    <meta refines="#series-id" property="collection-type">series</meta>
    <meta refines="#series-id" property="group-position">3</meta>
    <meta property="belongs-to-collection" id="set-id">Boxed Set</meta>
    <meta refines="#set-id" property="collection-type">set</meta>
    <meta refines="#narrator-1" property="role" scheme="marc:relators">nrt</meta>
    <meta property="dcterms:modified">2024-01-01T00:00:00Z</meta>
  </metadata>
  <manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
  <spine><itemref idref="chapter"/></spine>
</package>]]

local function remove_tree(path)
    local attr = lfs.symlinkattributes(path)
    if not attr then return end
    if attr.mode ~= "directory" then
        os.remove(path)
        return
    end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then remove_tree(path .. "/" .. entry) end
    end
    lfs.rmdir(path)
end

local function make_epub(path, opf, container, extra_path)
    local writer = Archiver.Writer:new()
    assert.is_true(writer:open(path, "epub"))
    assert.is_true(writer:setZipCompression("store"))
    assert.is_true(writer:addFileFromMemory("mimetype", "application/epub+zip"))
    assert.is_true(writer:setZipCompression("deflate"))
    assert.is_true(writer:addFileFromMemory("META-INF/container.xml", container or CONTAINER))
    assert.is_true(writer:addFileFromMemory("OEBPS/content.opf", opf or OPF))
    assert.is_true(writer:addFileFromMemory("OEBPS/chapter.xhtml", "<html><body>untouched</body></html>"))
    if extra_path then assert.is_true(writer:addFileFromMemory(extra_path, "unsafe")) end
    writer:close()
end

local function archive_entries(path)
    local reader = Archiver.Reader:new()
    assert.is_true(reader:open(path))
    local entries = {}
    local contents = {}
    for entry in reader:iterate() do
        if entry.mode == "file" then
            entries[#entries + 1] = entry.path
            contents[entry.path] = assert(reader:extractToMemory(entry.path))
        end
    end
    reader:close()
    return entries, contents
end

local function write_json(path, value)
    local file = assert(io.open(path, "wb"))
    assert(file:write(json.encode(value)))
    file:close()
end

local function write_bytes(path, value)
    local file = assert(io.open(path, "wb"))
    assert(file:write(value))
    file:close()
end

local function read_bytes(path)
    local file = assert(io.open(path, "rb"))
    local value = assert(file:read("*a"))
    file:close()
    return value
end

local function sidecar_update(target, value)
    local stage = target .. ".zen-metadata.new"
    os.remove(stage)
    os.remove(target .. ".zen-metadata.old")
    if value ~= nil then write_bytes(stage, value) end
    return {
        target = target,
        stage = stage,
        old = target .. ".zen-metadata.old",
        delete = value == nil,
        had_target = lfs.attributes(target, "mode") == "file",
    }
end

local function book_sidecar(book_path)
    local directory = book_path:match("^(.*)%.[^./]+$") .. ".sdr"
    if not lfs.attributes(directory) then assert.is_true(lfs.mkdir(directory)) end
    return directory .. "/custom_metadata.lua"
end

describe("embedded EPUB metadata", function()
    local test_root
    local path
    local rename_path = os.rename
    local remove_path = os.remove
    local time = os.time
    local ffi_os = ffi.os
    local fsync_directory = ffiutil.fsyncDirectory
    local fsync_opened_file = ffiutil.fsyncOpenedFile
    local saved_docsettings
    local saved_reader_settings

    local function install_hash_docsettings()
        local storage = test_root .. "/hashdocsettings"
        assert.is_true(util.makePath(storage))
        local cache = {}
        package.loaded.docsettings = {
            getSidecarFilename = function(book)
                return "metadata." .. (book:match(".*%.(.+)") or "_") .. ".lua"
            end,
            getSidecarStorage = function(location)
                return location == "hash" and storage or nil
            end,
            getSidecarDir = function(_self, book, location)
                if location == "hash" then
                    local hash = cache[book]
                    if not hash then
                        hash = assert(util.partialMD5(book))
                        cache[book] = hash
                    end
                    return storage .. "/" .. hash:sub(1, 2) .. "/" .. hash .. ".sdr"
                end
                local base = book:match("(.*)%.") or book
                return location == "dir" and storage .. base .. ".sdr" or base .. ".sdr"
            end,
        }
        return storage, cache
    end

    local function hash_sidecar(storage, book)
        local hash = assert(util.partialMD5(book))
        return storage .. "/" .. hash:sub(1, 2) .. "/" .. hash .. ".sdr", hash
    end

    before_each(function()
        test_root = os.tmpname()
        os.remove(test_root)
        assert.is_true(lfs.mkdir(test_root))
        path = test_root .. "/book.epub"
        make_epub(path)
        saved_docsettings = package.loaded.docsettings
        saved_reader_settings = rawget(_G, "G_reader_settings")
    end)

    after_each(function()
        rawset(os, "rename", rename_path)
        rawset(os, "remove", remove_path)
        rawset(os, "time", time)
        rawset(ffi, "os", ffi_os)
        rawset(ffiutil, "fsyncDirectory", fsync_directory)
        rawset(ffiutil, "fsyncOpenedFile", fsync_opened_file)
        package.loaded.docsettings = saved_docsettings
        rawset(_G, "G_reader_settings", saved_reader_settings)
        remove_tree(test_root)
    end)

    it("reads the normalized embedded fields", function()
        local metadata = assert(Epub.read(path))
        assert.are.equal("Old Title", metadata.title)
        assert.are.same({ "Old Author" }, metadata.authors)
        assert.are.equal("Old Series", metadata.series_name)
        assert.are.equal("3", metadata.series_index)
        assert.are.same({ "Fantasy" }, metadata.genres)
        assert.are.equal("en", metadata.language)
        assert.are.equal("Old House", metadata.publisher)
        assert.are.equal("Old description.", metadata.description)
        assert.are.equal("9780441013593", metadata.isbn)
    end)

    it("edits and restores EPUBs whose mimetype entry is not first", function()
        local entries, contents = archive_entries(path)
        for _i, compression in ipairs({ "store", "deflate" }) do
            local writer = Archiver.Writer:new()
            assert.is_true(writer:open(path, "epub"))
            assert.is_true(writer:setZipCompression("deflate"))
            for _j, entry in ipairs(entries) do
                if entry ~= "mimetype" then
                    assert.is_true(writer:addFileFromMemory(entry, contents[entry]))
                end
            end
            assert.is_true(writer:setZipCompression(compression))
            assert.is_true(writer:addFileFromMemory("mimetype", contents.mimetype))
            writer:close()
            local original = read_bytes(path)

            assert.are.equal("Old Title", assert(Epub.read(path)).title)
            assert.is_true(Epub.write(path, { title = "Old Title" }))
            assert.are.equal(original, read_bytes(path))
            assert.is_true(Epub.write(path, { title = "New Title" }))
            assert.are.equal("New Title", assert(Epub.read(path)).title)
            local rewritten = read_bytes(path)
            assert.are.equal("\0\0", rewritten:sub(9, 10))
            assert.are.equal("mimetype", rewritten:sub(31, 38))
            local saved_entries, saved_contents = archive_entries(path)
            assert.same(entries, saved_entries)
            for entry, content in pairs(contents) do
                if entry ~= "OEBPS/content.opf" then
                    assert.are.equal(content, saved_contents[entry])
                end
            end
            assert.is_true(Epub.canRestore(path))
            assert.are.equal(original, read_bytes(Epub.backupPath(path)))
            assert.same({}, assert(Epub.restore(path)))
            assert.are.equal(original, read_bytes(path))
            assert.are.equal("Old Title", assert(Epub.read(path)).title)
        end
    end)

    it("rewrites metadata, preserves unknown content, and restores both directions", function()
        local old_snapshot = { title = "Sidecar title", authors = { "Sidecar author" } }
        assert.is_true(Epub.write(path, {
            title = "New Title",
            authors = { "New Author", "Second Author" },
            series_name = "New Series",
            series_index = "1.5",
            genres = { "Science Fiction", "Adventure" },
            language = "fr",
            publisher = "New House",
            description = "New <plain> description & notes.",
            isbn = "9780441013593",
        }, { sidecar_snapshot = old_snapshot }))

        local metadata = assert(Epub.read(path))
        assert.are.equal("New Title", metadata.title)
        assert.are.same({ "New Author", "Second Author" }, metadata.authors)
        assert.are.equal("New Series", metadata.series_name)
        assert.are.equal("1.5", metadata.series_index)
        assert.are.same({ "Science Fiction", "Adventure" }, metadata.genres)
        assert.are.equal("fr", metadata.language)
        assert.are.equal("New House", metadata.publisher)
        assert.are.equal("New <plain> description & notes.", metadata.description)
        assert.is_true(Epub.canRestore(path))

        local entries, contents = archive_entries(path)
        assert.are.same({
            "mimetype",
            "META-INF/container.xml",
            "OEBPS/content.opf",
            "OEBPS/chapter.xhtml",
        }, entries)
        assert.matches("vendor:untouched", contents["OEBPS/content.opf"], 1, true)
        assert.matches("dcterms:modified", contents["OEBPS/content.opf"], 1, true)
        assert.matches(">Boxed Set</meta>", contents["OEBPS/content.opf"], 1, true)
        assert.matches('id="creator-1"', contents["OEBPS/content.opf"], 1, true)
        assert.matches('opf:role="aut"', contents["OEBPS/content.opf"], 1, true)
        assert.matches("Preserved Editor", contents["OEBPS/content.opf"], 1, true)
        assert.matches("Preserved Narrator", contents["OEBPS/content.opf"], 1, true)
        assert.matches(">nrt</meta>", contents["OEBPS/content.opf"], 1, true)

        local restored = assert(Epub.restore(path, {
            sidecar_snapshot = { title = "New sidecar title" },
        }))
        assert.are.same(old_snapshot, restored)
        assert.are.equal("Old Title", assert(Epub.read(path)).title)

        local redo_snapshot = assert(Epub.restore(path, { sidecar_snapshot = old_snapshot }))
        assert.are.same({ title = "New sidecar title" }, redo_snapshot)
        assert.are.equal("New Title", assert(Epub.read(path)).title)
    end)

    it("moves the complete hash sidecar identity and preserves restore toggles", function()
        local timestamp = time() + 2
        rawset(os, "time", function() return timestamp end)
        local storage = install_hash_docsettings()
        local old_dir, old_hash = hash_sidecar(storage, path)
        assert.is_true(util.makePath(old_dir .. "/cache"))
        write_bytes(old_dir .. "/metadata.epub.lua", "return { doc_path = "
            .. string.format("%q", path) .. ", partial_md5_checksum = "
            .. string.format("%q", old_hash) .. ", percent_finished = 0.42 }\n")
        write_bytes(old_dir .. "/custom_metadata.lua", "return { custom_props = {} }\n")
        write_bytes(old_dir .. "/cover.jpg", "cover bytes")
        write_bytes(old_dir .. "/cache/page.bin", "cached page")
        local old_metadata = read_bytes(old_dir .. "/metadata.epub.lua")

        assert.is_true(Epub.write(path, { title = "Hash-migrated" }))
        local new_dir, new_hash = hash_sidecar(storage, path)
        assert.are_not.equal(old_hash, new_hash)
        assert.are.equal("cover bytes", read_bytes(new_dir .. "/cover.jpg"))
        assert.are.equal("cached page", read_bytes(new_dir .. "/cache/page.bin"))
        local migrated = assert(dofile(new_dir .. "/metadata.epub.lua"))
        assert.are.equal(0.42, migrated.percent_finished)
        assert.are.equal(new_hash, migrated.partial_md5_checksum)
        assert.are.equal(path, migrated.doc_path)
        assert.are.equal("cover bytes", read_bytes(old_dir .. "/cover.jpg"))

        local changed_old = assert(dofile(old_dir .. "/metadata.epub.lua"))
        changed_old.percent_finished = 0.99
        write_bytes(old_dir .. "/metadata.epub.lua", "return "
            .. require("dump")(changed_old, nil, true) .. "\n")
        local collided_restore, restore_err = Epub.restore(path)
        assert.is_nil(collided_restore)
        assert.matches("destination hash sidecar", restore_err, 1, true)
        assert.are.equal("Hash-migrated", assert(Epub.read(path)).title)
        write_bytes(old_dir .. "/metadata.epub.lua", old_metadata)

        migrated.percent_finished = 0.84
        write_bytes(new_dir .. "/metadata.epub.lua", "return "
            .. require("dump")(migrated, nil, true) .. "\n")
        assert.same({}, assert(Epub.restore(path)))
        local restored_dir, restored_hash = hash_sidecar(storage, path)
        assert.are.equal(old_dir, restored_dir)
        local restored = assert(dofile(restored_dir .. "/metadata.epub.lua"))
        assert.are.equal(0.84, restored.percent_finished)
        assert.are.equal(restored_hash, restored.partial_md5_checksum)

        local companion_path = path .. ".zen-metadata.bak.json"
        local companion = assert(json.decode(read_bytes(companion_path)))
        local owned_hash = companion.book_hash
        companion.book_hash = nil
        write_json(companion_path, companion)
        local collision_dir
        local collided, collision_err = Epub.write(path, { title = "Hash-migrated" }, {
            prepare_sidecar = function()
                collision_dir = hash_sidecar(storage, path .. ".zen-metadata.tmp")
                assert.is_true(util.makePath(collision_dir))
                return true
            end,
        })
        assert.is_nil(collided)
        assert.matches("destination hash sidecar", collision_err, 1, true)
        assert.are.equal("Old Title", assert(Epub.read(path)).title)
        if collision_dir ~= new_dir then remove_tree(collision_dir) end
        companion.book_hash = owned_hash
        write_json(companion_path, companion)
        assert.is_true(Epub.write(path, { title = "Hash-migrated" }))
        local repeated_dir, repeated_hash = hash_sidecar(storage, path)
        local repeated = assert(dofile(repeated_dir .. "/metadata.epub.lua"))
        assert.are.equal(0.84, repeated.percent_finished)
        assert.are.equal(repeated_hash, repeated.partial_md5_checksum)
    end)

    it("moves a cover-only hash sidecar without metadata files", function()
        local storage = install_hash_docsettings()
        local old_dir = hash_sidecar(storage, path)
        assert.is_true(util.makePath(old_dir))
        write_bytes(old_dir .. "/cover.png", "cover only")

        assert.is_true(Epub.write(path, { title = "Cover-only migration" }))
        local new_dir = hash_sidecar(storage, path)
        assert.are_not.equal(old_dir, new_dir)
        assert.are.equal("cover only", read_bytes(new_dir .. "/cover.png"))
        assert.is_nil(lfs.attributes(new_dir .. "/custom_metadata.lua"))
        assert.is_nil(lfs.attributes(new_dir .. "/metadata.epub.lua"))
    end)

    it("moves a progress-only hash sidecar after preference changes to doc", function()
        local storage = install_hash_docsettings()
        rawset(_G, "G_reader_settings", {
            readSetting = function(_self, key)
                return key == "document_metadata_folder" and "doc" or nil
            end,
        })
        local old_dir, old_hash = hash_sidecar(storage, path)
        assert.is_true(util.makePath(old_dir))
        write_bytes(old_dir .. "/metadata.epub.lua", "return { doc_path = "
            .. string.format("%q", path) .. ", partial_md5_checksum = "
            .. string.format("%q", old_hash) .. ", percent_finished = 0.61 }\n")

        assert.is_true(Epub.write(path, { title = "Progress-only migration" }))
        local new_dir, new_hash = hash_sidecar(storage, path)
        assert.are_not.equal(old_dir, new_dir)
        local migrated = assert(dofile(new_dir .. "/metadata.epub.lua"))
        assert.are.equal(0.61, migrated.percent_finished)
        assert.are.equal(new_hash, migrated.partial_md5_checksum)
        assert.are.equal(path, migrated.doc_path)
        assert.is_nil(lfs.attributes(new_dir .. "/custom_metadata.lua"))
    end)

    it("recovers a prepared hash-directory marker after the live EPUB changed", function()
        local storage = install_hash_docsettings()
        local old_dir = hash_sidecar(storage, path)
        assert.is_true(util.makePath(old_dir))
        write_bytes(old_dir .. "/metadata.epub.lua", "return { percent_finished = 0.42 }\n")

        local marker_renames = 0
        rawset(os, "rename", function(source, destination)
            if source == path .. ".zen-metadata.txn.new"
                    and destination == path .. ".zen-metadata.txn" then
                marker_renames = marker_renames + 1
                if marker_renames == 2 then error("simulated crash") end
            end
            return rename_path(source, destination)
        end)
        assert.has_error(function()
            Epub.write(path, { title = "Interrupted hash edit" })
        end, "simulated crash")
        rawset(os, "rename", rename_path)

        package.loaded.docsettings = nil
        install_hash_docsettings()
        assert.are.equal("Old Title", assert(Epub.read(path)).title)
        local recovered_dir = hash_sidecar(storage, path)
        assert.are.equal(0.42,
            assert(dofile(recovered_dir .. "/metadata.epub.lua")).percent_finished)
        assert.is_nil(lfs.attributes(path .. ".zen-metadata.txn"))
    end)

    it("rolls the backup to the immediately previous EPUB", function()
        assert.is_true(Epub.write(path, { title = "First" }, {
            sidecar_snapshot = { title = "old" },
        }))
        assert.is_true(Epub.write(path, { title = "Second" }, {
            sidecar_snapshot = { title = "first" },
        }))

        local snapshot = assert(Epub.restore(path, {
            sidecar_snapshot = { title = "second" },
        }))
        assert.are.same({ title = "first" }, snapshot)
        assert.are.equal("First", assert(Epub.read(path)).title)
    end)

    it("removes the retained backup after a successful no-backup write", function()
        assert.is_true(Epub.write(path, { title = "No retained backup" }, {
            keep_backup = false,
        }))

        assert.are.equal("No retained backup", assert(Epub.read(path)).title)
        assert.is_false(Epub.canRestore(path))
        assert.is_nil(lfs.attributes(path .. ".zen-metadata.bak"))
        assert.is_nil(lfs.attributes(path .. ".zen-metadata.bak.json"))
    end)

    it("rejects read-only books and preserves restrictive file modes", function()
        assert.are.equal(0, ffi.C.chmod(path, 384))
        assert.is_true(Epub.write(path, { title = "Private" }))
        assert.are.equal("rw-------", lfs.attributes(path, "permissions"))
        assert.are.equal("rw-------",
            lfs.attributes(path .. ".zen-metadata.bak", "permissions"))

        assert.are.equal(0, ffi.C.chmod(path, 292))
        local ok, err = Epub.write(path, { title = "Must not change" })
        assert.is_nil(ok)
        assert.matches("not writable", err, 1, true)
        assert.are.equal("Private", assert(Epub.read(path)).title)
    end)

    it("rolls back the EPUB and prior backup when a sidecar update fails", function()
        assert.is_true(Epub.write(path, { title = "First" }, {
            sidecar_snapshot = { state = "old" },
        }))
        local target = book_sidecar(path)
        write_bytes(target, "old sidecar")
        local update = sidecar_update(target, "new sidecar")
        local original_rename = os.rename
        rawset(os, "rename", function(source, destination)
            if source == update.stage then return nil, "sidecar_write_failed" end
            return original_rename(source, destination)
        end)
        local ok, err = Epub.write(path, { title = "Second" }, {
            sidecar_snapshot = { state = "first" },
            prepare_sidecar = function() return true, update end,
        })
        rawset(os, "rename", original_rename)
        assert.is_nil(ok)
        assert.are.equal("sidecar_write_failed", err)
        assert.are.equal("First", assert(Epub.read(path)).title)
        assert.are.equal("old sidecar", read_bytes(target))
        assert.is_nil(lfs.attributes(update.old))
        assert.is_nil(lfs.attributes(update.stage))

        local snapshot = assert(Epub.restore(path, {
            sidecar_snapshot = { state = "first" },
        }))
        assert.are.same({ state = "old" }, snapshot)
        assert.are.equal("Old Title", assert(Epub.read(path)).title)
    end)

    it("rolls back a restore when its sidecar update fails", function()
        assert.is_true(Epub.write(path, { title = "New" }, {
            sidecar_snapshot = { state = "old" },
        }))
        local target = book_sidecar(path)
        write_bytes(target, "new sidecar")
        local update = sidecar_update(target, "old sidecar")
        local original_rename = os.rename
        rawset(os, "rename", function(source, destination)
            if source == update.stage then return nil, "sidecar_write_failed" end
            return original_rename(source, destination)
        end)
        local ok, err = Epub.restore(path, {
            sidecar_snapshot = { state = "new" },
            prepare_sidecar = function() return true, update end,
        })
        rawset(os, "rename", original_rename)
        assert.is_nil(ok)
        assert.are.equal("sidecar_write_failed", err)
        assert.are.equal("New", assert(Epub.read(path)).title)
        assert.are.equal("new sidecar", read_bytes(target))

        local snapshot = assert(Epub.restore(path, {
            sidecar_snapshot = { state = "new" },
        }))
        assert.are.same({ state = "old" }, snapshot)
        assert.are.equal("Old Title", assert(Epub.read(path)).title)
    end)

    it("syncs restored backup state before removing a rollback marker", function()
        local target = book_sidecar(path)
        write_bytes(target, "old sidecar")
        local update = sidecar_update(target, "new sidecar")
        local events = {}
        rawset(ffiutil, "fsyncDirectory", function(directory)
            events[#events + 1] = "sync:" .. directory
            return fsync_directory(directory)
        end)
        rawset(os, "remove", function(target_path)
            if target_path == path .. ".zen-metadata.txn" then
                events[#events + 1] = "remove-marker"
            elseif target_path == path .. ".zen-metadata.tmp" then
                events[#events + 1] = "remove-stage"
            end
            return remove_path(target_path)
        end)
        rawset(os, "rename", function(source, destination)
            if source == update.stage then return nil, "sidecar_write_failed" end
            return rename_path(source, destination)
        end)

        local ok = Epub.write(path, { title = "Must roll back" }, {
            sidecar_snapshot = {},
            prepare_sidecar = function() return true, update end,
        })
        assert.is_nil(ok)
        rawset(os, "rename", rename_path)
        local marker_index, stage_index
        for index, event in ipairs(events) do
            if event == "remove-marker" then marker_index = index break end
        end
        for index, event in ipairs(events) do
            if event == "remove-stage" then stage_index = index break end
        end
        assert.is_number(marker_index)
        assert.is_number(stage_index)
        assert.are.equal("sync:" .. test_root, events[marker_index - 1])
        assert.are.equal("sync:" .. test_root, events[marker_index + 1])
        assert.is_true(marker_index < stage_index)
        assert.are.equal("Old Title", assert(Epub.read(path)).title)
        assert.are.equal("old sidecar", read_bytes(target))
    end)

    it("reports success after recovering an ambiguously synced commit", function()
        local marker_renames = 0
        local fail_next_sync = false
        rawset(os, "rename", function(source, destination)
            local ok, err = rename_path(source, destination)
            if ok and source == path .. ".zen-metadata.txn.new"
                    and destination == path .. ".zen-metadata.txn" then
                marker_renames = marker_renames + 1
                if marker_renames == 3 then fail_next_sync = true end
            end
            return ok, err
        end)
        rawset(ffiutil, "fsyncDirectory", function(directory)
            if fail_next_sync then
                fail_next_sync = false
                return false, "committed_sync_failed"
            end
            return fsync_directory(directory)
        end)

        local ok, err = Epub.write(path, { title = "Durably committed" })
        rawset(os, "rename", rename_path)
        assert.is_true(ok)
        assert.is_nil(err)
        assert.are.equal("Durably committed", assert(Epub.read(path)).title)
        assert.is_nil(lfs.attributes(path .. ".zen-metadata.txn"))
        assert.is_true(Epub.canRestore(path))
    end)

    it("reports success after retrying committed backup cleanup", function()
        assert.is_true(Epub.write(path, { title = "First commit" }))
        local failed_once = false
        rawset(os, "remove", function(target_path)
            if not failed_once and target_path == path .. ".zen-metadata.bak.old" then
                failed_once = true
                return nil, "cleanup_failed"
            end
            return remove_path(target_path)
        end)

        assert.is_true(Epub.write(path, { title = "Second commit" }))
        rawset(os, "remove", remove_path)
        assert.is_true(failed_once)
        assert.are.equal("Second commit", assert(Epub.read(path)).title)
        assert.same({}, assert(Epub.restore(path)))
        assert.are.equal("First commit", assert(Epub.read(path)).title)
    end)

    it("reports success after an ambiguous committed-marker deletion sync", function()
        local fail_next_sync = false
        rawset(os, "remove", function(target_path)
            local ok, err = remove_path(target_path)
            if ok and target_path == path .. ".zen-metadata.txn" then
                fail_next_sync = true
            end
            return ok, err
        end)
        rawset(ffiutil, "fsyncDirectory", function(directory)
            if fail_next_sync then
                fail_next_sync = false
                return false, "marker_delete_sync_failed"
            end
            return fsync_directory(directory)
        end)

        assert.is_true(Epub.write(path, { title = "Committed after marker cleanup" }))
        rawset(os, "remove", remove_path)
        assert.are.equal("Committed after marker cleanup", assert(Epub.read(path)).title)
        assert.is_true(Epub.canRestore(path))
    end)

    it("recovers interrupted EPUB and sidecar replacement together", function()
        assert.is_true(Epub.write(path, { title = "Uncommitted" }, {
            sidecar_snapshot = { state = "old" },
        }))
        local target = book_sidecar(path)
        local update = sidecar_update(target, nil)
        update.had_target = true
        write_bytes(update.old, "old sidecar")
        write_json(path .. ".zen-metadata.txn", {
            version = 1,
            operation = "write",
            phase = "replaced",
            had_backup = false,
            had_companion = false,
            sidecar = update,
        })

        assert.are.equal("Old Title", assert(Epub.read(path)).title)
        assert.are.equal("old sidecar", read_bytes(target))
        assert.is_nil(lfs.attributes(update.old))
        assert.is_false(Epub.canRestore(path))

        assert.is_true(Epub.write(path, { title = "Uncommitted creation" }, {
            sidecar_snapshot = { state = "old" },
        }))
        update = sidecar_update(target, "created sidecar")
        update.had_target = false
        os.remove(target)
        assert(os.rename(update.stage, target))
        write_json(path .. ".zen-metadata.txn", {
            version = 1,
            operation = "write",
            phase = "replaced",
            had_backup = false,
            had_companion = false,
            sidecar = update,
        })
        assert.are.equal("Old Title", assert(Epub.read(path)).title)
        assert.is_nil(lfs.attributes(target))
        assert.is_nil(lfs.attributes(update.stage))
        assert.is_nil(lfs.attributes(update.old))
    end)

    it("rejects unsupported recovery markers before mutating the EPUB", function()
        assert.is_true(Epub.write(path, { title = "Current" }))
        local current = read_bytes(path)
        write_json(path .. ".zen-metadata.txn", {
            version = 999,
            operation = "write",
            phase = "replaced",
            had_backup = true,
            had_companion = true,
        })

        local metadata, err = Epub.read(path)
        assert.is_nil(metadata)
        assert.matches("unsupported EPUB metadata recovery marker", err, 1, true)
        assert.are.equal(current, read_bytes(path))
    end)

    it("rejects recovery markers targeting another sidecar", function()
        assert.is_true(Epub.write(path, { title = "Current" }))
        local current = read_bytes(path)
        local victim_dir = test_root .. "/victim"
        assert.is_true(lfs.mkdir(victim_dir))
        local victim = victim_dir .. "/custom_metadata.lua"
        write_bytes(victim, "protected")
        local update = sidecar_update(victim, "forged")
        write_json(path .. ".zen-metadata.txn", {
            version = 1,
            operation = "write",
            phase = "replaced",
            had_backup = true,
            had_companion = true,
            sidecar = update,
        })

        local metadata, err = Epub.read(path)
        assert.is_nil(metadata)
        assert.matches("does not belong to this EPUB", err, 1, true)
        assert.are.equal(current, read_bytes(path))
        assert.are.equal("protected", read_bytes(victim))
        assert.are.equal("forged", read_bytes(update.stage))
    end)

    it("rejects a rolled-back marker with an unbound hash directory", function()
        local storage = install_hash_docsettings()
        local source = hash_sidecar(storage, path)
        assert.is_true(util.makePath(source))
        local target = storage .. "/ff/ffffffffffffffffffffffffffffffff.sdr"
        assert.is_true(util.makePath(target))
        write_bytes(target .. "/cover.jpg", "protected")
        local owner = require("ffi/sha2").md5(ffiutil.realpath(path) or path)
        local prefix = target .. ".zen-metadata." .. owner
        write_json(path .. ".zen-metadata.txn", {
            version = 1,
            operation = "write",
            phase = "rolled_back_file",
            had_backup = false,
            had_companion = false,
            sidecar = {
                kind = "directory",
                source = source,
                target = target,
                stage = prefix .. ".new",
                old = prefix .. ".old",
                had_target = true,
            },
        })

        local metadata, err = Epub.read(path)
        assert.is_nil(metadata)
        assert.matches("does not belong to this EPUB", err, 1, true)
        assert.are.equal("protected", read_bytes(target .. "/cover.jpg"))
        assert.is_not_nil(lfs.attributes(path .. ".zen-metadata.txn"))
    end)

    it("does not replace the EPUB when its staged data cannot be synced", function()
        local calls = 0
        rawset(ffiutil, "fsyncOpenedFile", function(...)
            calls = calls + 1
            if calls == 1 then return false, "stage_sync_failed" end
            return fsync_opened_file(...)
        end)

        local ok, err = Epub.write(path, { title = "Unsafe" })
        assert.is_nil(ok)
        assert.are.equal("stage_sync_failed", err)
        assert.are.equal("Old Title", assert(Epub.read(path)).title)
    end)

    it("rolls back when a transaction directory cannot be synced", function()
        local failed = false
        rawset(ffiutil, "fsyncDirectory", function(...)
            if not failed then
                failed = true
                return false, "directory_sync_failed"
            end
            return fsync_directory(...)
        end)

        local ok, err = Epub.write(path, { title = "Unsafe" })
        assert.is_nil(ok)
        assert.are.equal("directory_sync_failed", err)
        assert.are.equal("Old Title", assert(Epub.read(path)).title)
        assert.is_nil(lfs.attributes(path .. ".zen-metadata.txn"))
    end)

    it("backs up a supplied sidecar snapshot even when embedded fields are unchanged", function()
        assert.is_true(Epub.write(path, { title = "First" }, {
            sidecar_snapshot = { title = "old" },
        }))
        assert.is_true(Epub.write(path, { title = "First" }, {
            sidecar_snapshot = { title = "current" },
        }))

        local snapshot = assert(Epub.restore(path, {
            sidecar_snapshot = { title = "after" },
        }))
        assert.are.same({ title = "current" }, snapshot)
        assert.are.equal("First", assert(Epub.read(path)).title)
    end)

    it("rejects a backup whose sidecar snapshot is missing", function()
        assert.is_true(Epub.write(path, { title = "Changed" }, {
            sidecar_snapshot = { title = "old override" },
        }))
        assert(os.remove(path .. ".zen-metadata.bak.json"))

        local restorable, can_err = Epub.canRestore(path)
        assert.is_false(restorable)
        assert.matches("state is missing", can_err, 1, true)
        local restored, restore_err = Epub.restore(path, {
            sidecar_snapshot = { title = "current override" },
        })
        assert.is_nil(restored)
        assert.matches("state is missing", restore_err, 1, true)
        assert.are.equal("Changed", assert(Epub.read(path)).title)
    end)

    it("clears selected fields without deleting non-series collections", function()
        assert.is_true(Epub.write(path, {
            authors = {},
            genres = {},
            series_name = "",
            language = "",
            publisher = "",
            description = "",
        }))
        local metadata = assert(Epub.read(path))
        assert.are.same({}, metadata.authors)
        assert.are.same({}, metadata.genres)
        assert.is_nil(metadata.series_name)
        assert.is_nil(metadata.language)
        assert.is_nil(metadata.publisher)
        assert.is_nil(metadata.description)
        local contents = select(2, archive_entries(path))
        assert.matches(">Boxed Set</meta>", contents["OEBPS/content.opf"], 1, true)
        assert.matches('property="collection-type">set<', contents["OEBPS/content.opf"], 1, true)
        assert.matches("Preserved Editor", contents["OEBPS/content.opf"], 1, true)
        assert.matches("Preserved Narrator", contents["OEBPS/content.opf"], 1, true)
    end)

    it("uses Calibre series metadata without EPUB 3 refinements in EPUB 2", function()
        local epub2 = test_root .. "/epub2.epub"
        local opf2 = OPF:gsub('version="3.0"', 'version="2.0"')
            :gsub('%s*<meta property="belongs%-to%-collection" id="series%-id">.-</meta>', "")
            :gsub('%s*<meta refines="#series%-id" property="collection%-type">.-</meta>', "")
            :gsub('%s*<meta refines="#series%-id" property="group%-position">.-</meta>', "")
            :gsub('%s*<meta property="belongs%-to%-collection" id="set%-id">.-</meta>', "")
            :gsub('%s*<meta refines="#set%-id" property="collection%-type">.-</meta>', "")
        make_epub(epub2, opf2)
        assert.is_true(Epub.write(epub2, {
            series_name = "EPUB Two Series",
            series_index = "4",
        }))
        local contents = select(2, archive_entries(epub2))
        assert.matches('name="calibre:series"', contents["OEBPS/content.opf"], 1, true)
        assert.not_matches('property="belongs-to-collection"',
            contents["OEBPS/content.opf"], 1, true)
    end)

    it("clears untyped EPUB 3 series fallbacks", function()
        local fallback = test_root .. "/fallback.epub"
        local opf = OPF
            :gsub('%s*<meta name="calibre:series"[^>]*/>', "")
            :gsub('%s*<meta name="calibre:series_index"[^>]*/>', "")
            :gsub('%s*<meta property="belongs%-to%-collection" id="series%-id">.-</meta>', "")
            :gsub('%s*<meta refines="#series%-id" property="collection%-type">.-</meta>', "")
            :gsub('%s*<meta refines="#series%-id" property="group%-position">.-</meta>', "")
            :gsub("</metadata>",
                '<meta property="belongs-to-collection" id="legacy-series">Legacy Series</meta>'
                    .. '<meta property="belongs-to-collection" id="unrelated-collection">'
                    .. 'Unrelated Collection</meta>'
                    .. '<meta refines="#unrelated-collection" property="group-position">7</meta>'
                    .. "</metadata>")
        make_epub(fallback, opf)
        assert.are.equal("Legacy Series", assert(Epub.read(fallback)).series_name)

        assert.is_true(Epub.write(fallback, {
            series_name = "",
            series_index = "",
        }))
        assert.are.equal("Unrelated Collection", assert(Epub.read(fallback)).series_name)
        local contents = select(2, archive_entries(fallback))
        assert.not_matches("Legacy Series", contents["OEBPS/content.opf"], 1, true)
        assert.matches("Unrelated Collection", contents["OEBPS/content.opf"], 1, true)
        assert.matches('refines="#unrelated-collection"',
            contents["OEBPS/content.opf"], 1, true)
        assert.matches("Boxed Set", contents["OEBPS/content.opf"], 1, true)
    end)

    it("preserves the OPF prefix on newly inserted series metadata", function()
        local prefixed = test_root .. "/prefixed.epub"
        local opf = [[<?xml version="1.0" encoding="utf-8"?>
<opf:package xmlns:opf="http://www.idpf.org/2007/opf"
    xmlns:dc="http://purl.org/dc/elements/1.1/" version="3.0">
  <opf:metadata>
    <dc:title>Prefixed</dc:title>
    <dc:creator>Author</dc:creator>
    <dc:language>en</dc:language>
  </opf:metadata>
  <opf:manifest><opf:item id="chapter" href="chapter.xhtml"
      media-type="application/xhtml+xml"/></opf:manifest>
  <opf:spine><opf:itemref idref="chapter"/></opf:spine>
</opf:package>]]
        make_epub(prefixed, opf)
        assert.is_true(Epub.write(prefixed, {
            series_name = "Prefixed Series",
            series_index = "2",
        }))
        assert.are.equal("Prefixed Series", assert(Epub.read(prefixed)).series_name)
        local contents = select(2, archive_entries(prefixed))
        assert.matches('<opf:meta name="calibre:series"',
            contents["OEBPS/content.opf"], 1, true)
        assert.matches('<opf:meta property="belongs-to-collection"',
            contents["OEBPS/content.opf"], 1, true)
    end)

    it("does not move the live EPUB aside during Windows replacement", function()
        rawset(ffi, "os", "Windows")
        local moved_live = false
        rawset(os, "rename", function(source, destination)
            if source == path then moved_live = true end
            if lfs.symlinkattributes(destination) then
                return nil, "destination exists"
            end
            return rename_path(source, destination)
        end)

        assert.is_true(Epub.write(path, { title = "Windows-safe" }, {
            sidecar_snapshot = {},
        }))
        assert.are.equal("Windows-safe", assert(Epub.read(path)).title)
        assert.are.same({}, assert(Epub.restore(path, {
            sidecar_snapshot = {},
        })))
        assert.are.equal("Old Title", assert(Epub.read(path)).title)
        assert.is_false(moved_live)
        assert.is_nil(lfs.attributes(path .. ".zen-metadata.live-old"))
        assert.is_nil(lfs.attributes(path .. ".zen-metadata.txn.old"))
    end)

    it("recovers a Windows rollback interrupted after restoring the live file", function()
        rawset(ffi, "os", "Windows")
        local target = book_sidecar(path)
        write_bytes(target, "old sidecar")
        local update = sidecar_update(target, "new sidecar")
        local marker_renames = 0
        local function windows_rename(source, destination)
            if lfs.symlinkattributes(destination) then
                return nil, "destination exists"
            end
            return rename_path(source, destination)
        end
        rawset(os, "rename", function(source, destination)
            if source == update.stage then return nil, "sidecar_write_failed" end
            if source == path .. ".zen-metadata.txn.new"
                    and destination == path .. ".zen-metadata.txn" then
                marker_renames = marker_renames + 1
                if marker_renames == 3 then error("simulated rollback crash") end
            end
            return windows_rename(source, destination)
        end)

        assert.has_error(function()
            Epub.write(path, { title = "Interrupted Windows edit" }, {
                sidecar_snapshot = {},
                prepare_sidecar = function() return true, update end,
            })
        end, "simulated rollback crash")
        rawset(os, "rename", windows_rename)
        assert.are.equal("Old Title", assert(Epub.read(path)).title)
        assert.are.equal("old sidecar", read_bytes(target))
        assert.is_nil(lfs.attributes(path .. ".zen-metadata.live-old"))
        assert.is_nil(lfs.attributes(path .. ".zen-metadata.txn"))
    end)

    it("preserves untouched HTML description content", function()
        local html = test_root .. "/html-description.epub"
        make_epub(html, (OPF:gsub("Old description%.",
            "&lt;p&gt;Original &lt;b&gt;markup&lt;/b&gt;.&lt;/p&gt;")))
        assert.is_true(Epub.write(html, { title = "Changed title" }))
        assert.are.equal("<p>Original <b>markup</b>.</p>",
            assert(Epub.read(html)).description)
    end)

    it("rejects invalid ISBNs and removing the package identifier", function()
        local ok, err = Epub.write(path, { isbn = "not an isbn" })
        assert.is_nil(ok)
        assert.matches("valid ISBN", err, 1, true)
        assert.are.equal("Old Title", assert(Epub.read(path)).title)

        ok, err = Epub.write(path, { isbn = "" })
        assert.is_nil(ok)
        assert.matches("unique identifier", err, 1, true)
        assert.are.equal("9780441013593", assert(Epub.read(path)).isbn)
    end)

    it("rejects multi-rendition containers without touching the source", function()
        local multi = CONTAINER:gsub("</rootfiles>",
            '<rootfile full-path="OEBPS/other.opf" media-type="application/oebps-package+xml"/>'
                .. "</rootfiles>")
        make_epub(test_root .. "/multi.epub", OPF, multi)
        local ok, err = Epub.write(test_root .. "/multi.epub", { title = "Nope" })
        assert.is_nil(ok)
        assert.matches("one package document", err, 1, true)
    end)

    it("rejects unsafe archive member paths without touching the source", function()
        local unsafe = test_root .. "/unsafe.epub"
        make_epub(unsafe, OPF, CONTAINER, "OEBPS/../escape.xhtml")
        local ok, err = Epub.write(unsafe, { title = "Nope" })
        assert.is_nil(ok)
        assert.matches("unsafe archive entry path", err, 1, true)
    end)
end)
