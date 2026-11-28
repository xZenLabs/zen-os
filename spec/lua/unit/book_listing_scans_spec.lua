-- Every place ZenOS reads a folder's entries (lfs.dir, BookWalker.walk) is
-- classified here. Book sources' books without a file (a catalog's books
-- not downloaded yet, see common/book_sources.lua) are only listed, counted
-- and shown on covers where a scan asks BookSources.booksWithoutFile, so a
-- new scan that lists or counts books and doesn't ask would silently leave
-- them out. Adding a scan to a file not listed here fails this spec: if it
-- lists, counts or shows books, ask booksWithoutFile (for the folders it
-- read, with the files it found as `present`) and classify the file "asks";
-- otherwise classify it "not_books" and say what it reads.

local SCANS = {
    -- Scans that list, count or show books, and ask the book sources.
    ["modules/filebrowser/patches/browser_flat_view_compat.lua"] = {
        kind = "asks", why = "folder listings and counts, ZenOS's flat view" },
    ["modules/filebrowser/folder_cover.lua"] = {
        kind = "asks", why = "folder covers: count, cover images, all finished" },
    ["modules/filebrowser/patches/context_menu_file_dialog.lua"] = {
        kind = "asks", why = "a folder's book count in its long-press dialog; also a "
            .. "fallback cover list without a file chooser and an empty-folder check after a move" },

    -- Book scans that don't ask yet, and why that's acceptable for now.
    ["common/cover_utils.lua"] = {
        kind = "gap", why = "folder cover images when there is no file chooser to list the "
            .. "folder (the usual path goes through genItemTableFromPath, which asks)" },
    ["common/tbr_index.lua"] = {
        kind = "gap", why = "To Be Read's folder scope: whether books without a file belong "
            .. "there is undecided (collections in To Be Read already include owned books)" },

    -- Not book listings.
    ["common/book_walker.lua"] = { kind = "not_books", why = "the walker itself; its callers are listed" },
    ["common/brand_migration.lua"] = { kind = "not_books", why = "settings folders when migrating" },
    ["common/folder_cover_files.lua"] = { kind = "not_books", why = "a folder's own cover image files" },
    ["common/hid_keys.lua"] = { kind = "not_books", why = "input devices" },
    ["common/icon_packs.lua"] = { kind = "not_books", why = "icon pack folders" },
    ["common/library_font_path.lua"] = { kind = "not_books", why = "font files" },
    ["common/opds_cover_cache.lua"] = { kind = "not_books", why = "its cache folder" },
    ["common/quickstart/quickstart_pages.lua"] = { kind = "not_books", why = "quickstart images" },
    ["common/utils.lua"] = { kind = "not_books", why = "SVG icon folders" },
    ["modules/filebrowser/metadata/epub.lua"] = { kind = "not_books", why = "an EPUB's unpacked contents" },
    ["modules/filebrowser/patches/browser_item_table_cache.lua"] = {
        kind = "not_books", why = "folder dates for sorting folders, and the listing cache's signature" },
    ["modules/filebrowser/patches/browser_show_hidden.lua"] = {
        kind = "not_books", why = "mentions lfs.dir in a comment only" },
    ["modules/filebrowser/patches/context_menu.lua"] = {
        kind = "not_books", why = "subfolders for the move-to-folder picker" },
    ["modules/filebrowser/patches/home/home_quotes.lua"] = { kind = "not_books", why = "quote files" },
    ["modules/filebrowser/patches/incompatible_plugins_check.lua"] = { kind = "not_books", why = "plugin folders" },
    ["modules/filebrowser/patches/kindle_virtual_library.lua"] = {
        kind = "not_books", why = "Kindle thumbnails (Kindle books have files)" },
    ["modules/filebrowser/patches/navbar.lua"] = { kind = "not_books", why = "folder modification times" },
    ["modules/menu/app_launcher/plugin_scan.lua"] = { kind = "not_books", why = "plugin folders" },
}

local function read(path)
    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()
    return text
end

local function source_files()
    local root = ZenSpec.root
    local pipe = assert(io.popen('find "' .. root .. '/common" "' .. root .. '/modules" -name "*.lua" -type f'))
    local files = {}
    for line in pipe:lines() do
        local relative = line:sub(#root + 2)
        if not relative:find("/vendor/", 1, true) then files[#files + 1] = relative end
    end
    pipe:close()
    table.sort(files)
    return files
end

local function scans_folders(text)
    return text:find("lfs%d*%.dir") ~= nil or text:find("BookWalker%.walk") ~= nil
end

describe("folder scans and book sources", function()
    local files

    setup(function()
        files = {}
        for _i, relative in ipairs(source_files()) do
            files[relative] = read(ZenSpec.root .. "/" .. relative)
        end
    end)

    it("finds ZenOS's source files", function()
        assert.is_truthy(files["common/book_sources.lua"])
    end)

    it("classifies every file that reads folders", function()
        local unclassified = {}
        for relative, text in pairs(files) do
            if scans_folders(text) and not SCANS[relative] then unclassified[#unclassified + 1] = relative end
        end
        table.sort(unclassified)
        assert.are.same({}, unclassified,
            "New folder scans: if they list, count or show books, ask "
            .. "BookSources.booksWithoutFile; then classify them in this spec")
    end)

    it("has scans that list books ask the book sources", function()
        for relative, scan in pairs(SCANS) do
            if scan.kind == "asks" then
                assert.is_truthy(files[relative] and files[relative]:find("booksWithoutFile", 1, true),
                    relative .. " no longer asks BookSources.booksWithoutFile")
            end
        end
    end)

    it("lists only files that still read folders, each with a reason", function()
        for relative, scan in pairs(SCANS) do
            assert.is_truthy(files[relative], relative .. " is gone: remove it from this spec")
            assert.is_truthy(scans_folders(files[relative]),
                relative .. " no longer reads folders: remove it from this spec")
            assert.is_truthy(scan.kind == "asks" or scan.kind == "gap" or scan.kind == "not_books")
            assert.is_truthy(type(scan.why) == "string" and scan.why ~= "")
        end
    end)
end)
