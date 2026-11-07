describe("floating book notes", function()
    local Note, root, modules, sync_ok
    local lfs = require("libs/libkoreader-lfs")

    before_each(function()
        root = os.tmpname()
        os.remove(root)
        assert(lfs.mkdir(root))
        modules = {}
        for _i, name in ipairs({ "docsettings", "ffi/util", "modules/reader/book_note" }) do
            modules[name] = package.loaded[name] or false
        end
        ZenSpec.replace("docsettings", {
            findSidecarFile = function() return root .. "/metadata.epub.lua" end,
            getSidecarDir = function() error("must use the existing sidecar location") end,
            removeSidecarDir = function(path) lfs.rmdir(path) end,
        })
        sync_ok = true
        ZenSpec.replace("ffi/util", {
            fsyncOpenedFile = function() return sync_ok end,
            fsyncDirectory = function() return true end,
        })
        ZenSpec.unload("modules/reader/book_note")
        Note = require("modules/reader/book_note")
    end)

    after_each(function()
        os.remove(root .. "/zen-note.txt")
        os.remove(root .. "/zen-note.txt.zen-write")
        lfs.rmdir(root)
        for name, module in pairs(modules) do package.loaded[name] = module or nil end
    end)

    it("creates one plain UTF-8 multiline note in the book's existing sidecar", function()
        assert.are.equal("", Note.read("book.epub"))
        local text = "Pensées\n\nUnattached to a page. 中文"
        assert.is_true(Note.save("book.epub", text, ""))
        assert.are.equal(root .. "/zen-note.txt", Note.path("book.epub"))
        assert.are.equal(text, Note.read("book.epub"))
        assert.is_nil(lfs.attributes(root .. "/zen-note.txt.zen-write"))
        assert.is_true(Note.save("book.epub", text .. "\nMore", text))
        assert.are.equal(text .. "\nMore", Note.read("book.epub"))
    end)

    it("preserves the saved note on a failed sync and rejects outside edits", function()
        assert(Note.save("book.epub", "original"))
        sync_ok = false
        assert.is_nil(Note.save("book.epub", "replacement", "original"))
        assert.are.equal("original", Note.read("book.epub"))
        sync_ok = true
        assert.is_nil(Note.save("book.epub", "replacement", "stale"))
        assert.is_nil(Note.delete("book.epub", "stale"))
        assert.are.equal("original", Note.read("book.epub"))
        assert.is_true(Note.delete("book.epub", "original"))
        assert.are.equal("", Note.read("book.epub"))
    end)

    it("rejects a non-regular note and does not overwrite a staged file", function()
        assert(lfs.mkdir(root .. "/zen-note.txt"))
        assert.is_nil(Note.read("book.epub"))
        assert.is_nil(Note.save("book.epub", "text"))
        assert(lfs.rmdir(root .. "/zen-note.txt"))
        local stage = assert(io.open(root .. "/zen-note.txt.zen-write", "wb"))
        stage:write("recovery data"); stage:close()
        assert.is_nil(Note.save("book.epub", "text"))
        assert.are.equal("", Note.read("book.epub"))
    end)

    it("copies and moves notes with the book without overwriting destination notes", function()
        local doc = package.loaded.docsettings
        local destination = root .. "/moved.epub"
        local book = assert(io.open(destination, "wb")); book:close()
        assert(lfs.mkdir(root .. "/moved.sdr"))
        doc.findSidecarFile = function(_self, file)
            return file == destination and root .. "/moved.sdr/metadata.epub.lua" or root .. "/metadata.epub.lua"
        end
        doc.updateLocation = function() return true end
        Note.install()
        assert(Note.save("book.epub", "original"))
        assert.is_true(doc.updateLocation("book.epub", destination, true))
        assert.are.equal("original", Note.read(destination))
        assert.are.equal("original", Note.read("book.epub"))
        assert(Note.save(destination, "destination"))
        doc.updateLocation("book.epub", destination)
        assert.are.equal("destination", Note.read(destination))
        assert.are.equal("original", Note.read("book.epub"))
        assert(Note.delete(destination))
        doc.updateLocation("book.epub", destination)
        assert.are.equal("original", Note.read(destination))
        assert.are.equal("", Note.read("book.epub"))
        assert(Note.delete(destination))
        os.remove(destination)
        lfs.rmdir(root .. "/moved.sdr")
    end)
end)
